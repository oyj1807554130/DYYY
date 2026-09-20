//
//  DYYYXGProbe.xm
//  XG网络探针 v1 —— 纯观察探针
//
//  只 hook + 记录，绝不修改请求，绝不调用签名类。
//  功能：
//    1. 枚举 TTNet 候选类（NSClassFromString 探测 + class_copyMethodList 导出方法名）
//    2. 对 TTNetworkManager 动态 MSHookMessageEx 挂 hook（运行时校验方法编码签名，
//       仅挂 返回值 v/@ 且参数全为对象类型、0~3 参数 的实例方法，最多 3 个），
//       记录方法名/URL/headers key/签名头存在性/时间戳
//    3. 日志追加写 Documents/dyyy_probe.log，同 URL 去重（只记一次+计数），总条数上限 100
//
//  开关：DYYYXGProbeEnabled（默认关）。%ctor 时若已开启则启动；
//  运行中拨开关（NSUserDefaultsDidChangeNotification）也会启动。启动幂等，不会重复 hook。
//  hook 安装后常驻，但记录前实时查开关：关=完全静默（原样转发）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <stdlib.h>

static NSString *const kXGProbeEnabledKey = @"DYYYXGProbeEnabled";
static NSString *const kXGProbeLogFileName = @"Documents/dyyy_probe.log";

static const unsigned int kXGMaxMethodsPerClass = 80;   // 每类枚举方法名上限
static const unsigned int kXGMaxHookCount = 3;          // 最多挂钩方法数
static const unsigned int kXGMaxHookArgs = 3;           // 只挂 0~3 个对象参数的方法
static const NSInteger kXGMaxLogEntries = 100;          // 日志总条数上限

// ===== 共享锁（dispatch_once 初始化，避免 @synchronized(nil) 失效） =====
static NSObject *XGLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSObject alloc] init]; });
    return lock;
}

// ===== 日志追加写（不复用 dyyyDeliverProbeLog：那是覆盖写+复制剪贴板，不适合高频追加） =====
static void XGAppendLog(NSString *text) {
    @try {
        if (text.length == 0) return;
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:kXGProbeLogFileName];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) return;
        if (![fm fileExistsAtPath:path]) {
            [fm createFileAtPath:path contents:data attributes:nil];
            return;
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return;
        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh closeFile];
    } @catch (NSException *e) {}
}

// ===== 时间戳 =====
static NSString *XGTimestamp(void) {
    @try {
        NSDate *now = [NSDate date];
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm:ss";
        return [NSString stringWithFormat:@"%@ (%.0f)", [fmt stringFromDate:now], [now timeIntervalSince1970]];
    } @catch (NSException *e) {
        return @"?";
    }
}

// ===== 尽力从对象里挖 URL（NSString://、NSURL、字典 url 键、KVC 常见属性） =====
static NSString *XGURLFromObject(id obj, NSInteger depth) {
    if (!obj || depth > 2) return nil;
    @try {
        if ([obj isKindOfClass:[NSURL class]]) return [(NSURL *)obj absoluteString];
        if ([obj isKindOfClass:[NSString class]]) {
            NSString *s = (NSString *)obj;
            if (s.length > 0 && [s.lowercaseString containsString:@"://"]) return s;
            return nil;
        }
        if ([obj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = (NSDictionary *)obj;
            NSArray *keys = @[@"url", @"URL", @"URLString", @"urlString", @"originalURL", @"requestURL"];
            for (NSString *k in keys) {
                id v = [d objectForKey:k];
                if ([v isKindOfClass:[NSURL class]]) return [(NSURL *)v absoluteString];
                if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
            }
            return nil;
        }
        // 其他对象：探测常见属性选择器再 KVC 取值（值为 NSURL 或 NSString）
        NSArray *selNames = @[@"URL", @"url", @"urlString", @"URLString", @"originalURL", @"requestURL", @"absoluteString"];
        for (NSString *k in selNames) {
            if (![obj respondsToSelector:NSSelectorFromString(k)]) continue;
            @try {
                id v = [obj valueForKey:k];
                if ([v isKindOfClass:[NSURL class]]) return [(NSURL *)v absoluteString];
                if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
            } @catch (NSException *e) {}
        }
    } @catch (NSException *e) {}
    return nil;
}

// ===== 尽力从对象里挖 headers 全部 key =====
static NSArray *XGHeaderKeysFromObject(id obj) {
    if (!obj) return nil;
    @try {
        if ([obj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = (NSDictionary *)obj;
            if (d.count == 0) return nil;
            return [d allKeys];
        }
        NSArray *selNames = @[@"headers", @"allHTTPHeaderFields", @"HTTPHeaderFields"];
        for (NSString *k in selNames) {
            if (![obj respondsToSelector:NSSelectorFromString(k)]) continue;
            @try {
                id v = [obj valueForKey:k];
                if ([v isKindOfClass:[NSDictionary class]] && [(NSDictionary *)v count] > 0) {
                    return [(NSDictionary *)v allKeys];
                }
            } @catch (NSException *e) {}
        }
    } @catch (NSException *e) {}
    return nil;
}

// ===== URL 截断到前 300 字符（不用 MIN 宏，手动判断；防 UTF-16 代理对截半） =====
static NSString *XGTruncateURL(NSString *url) {
    if (!url) return @"(未取到)";
    if (url.length <= 300) return url;
    NSUInteger cut = 300;
    unichar c = [url characterAtIndex:cut - 1];
    if (c >= 0xD800 && c <= 0xDBFF) cut = cut - 1;
    return [NSString stringWithFormat:@"%@...", [url substringToIndex:cut]];
}

// ===== 签名头存在性检测（只检查，绝不触碰签名类） =====
static NSString *XGSignatureMarkers(NSString *url, NSArray *headerKeys) {
    NSMutableString *head = [NSMutableString string];
    if (headerKeys) {
        for (NSString *k in headerKeys) {
            [head appendFormat:@"%@ ", k.lowercaseString];
        }
    }
    NSString *haystack = [NSString stringWithFormat:@"%@ %@", url ?: @"", head];
    NSArray *markers = @[@"x-argus", @"x-gorgon", @"x-khronos", @"x-ladon", @"x-tt-trace-id"];
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *m in markers) {
        if ([haystack containsString:m]) [found addObject:m];
    }
    if (found.count == 0) return @"(未检出签名头)";
    return [NSString stringWithFormat:@"命中:%@", [found componentsJoinedByString:@","]];
}

// ===== 去重表与计数器 =====
static NSMutableDictionary *sXGURLCounts = nil;
static NSInteger sXGEntryCount = 0;

static BOOL XGMilestoneHit(NSInteger n) {
    NSArray *milestones = @[@5, @10, @25, @50, @100, @250, @500, @1000];
    for (NSNumber *m in milestones) {
        if ([m integerValue] == n) return YES;
    }
    return NO;
}

// ===== 记录一次 hook 调用（实时查开关；去重；限条数） =====
static void XGLogCall(id self, SEL _cmd, id a1, id a2, id a3, unsigned int argc) {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kXGProbeEnabledKey]) return;

    @synchronized (XGLock()) {
        if (sXGEntryCount >= kXGMaxLogEntries) return;
        if (!sXGURLCounts) sXGURLCounts = [[NSMutableDictionary alloc] init];

        // 尽力找 URL：先参数后 self
        NSString *url = nil;
        if (argc >= 1) url = XGURLFromObject(a1, 2);
        if (!url && argc >= 2) url = XGURLFromObject(a2, 2);
        if (!url && argc >= 3) url = XGURLFromObject(a3, 2);
        if (!url) url = XGURLFromObject(self, 1);

        // headers keys：先参数后 self
        NSArray *hkeys = nil;
        if (argc >= 1) hkeys = XGHeaderKeysFromObject(a1);
        if (!hkeys && argc >= 2) hkeys = XGHeaderKeysFromObject(a2);
        if (!hkeys && argc >= 3) hkeys = XGHeaderKeysFromObject(a3);
        if (!hkeys) hkeys = XGHeaderKeysFromObject(self);

        // 同 URL 去重：只记一次 + 计数；里程碑次数补一行
        NSString *key = url ?: @"(无URL)";
        NSNumber *seen = sXGURLCounts[key];
        if (seen) {
            NSInteger n = [seen integerValue] + 1;
            sXGURLCounts[key] = @(n);
            if (XGMilestoneHit(n) && sXGEntryCount < kXGMaxLogEntries) {
                sXGEntryCount = sXGEntryCount + 1;
                XGAppendLog([NSString stringWithFormat:@"[请求·去重] %@ 已第 %ld 次调用 %@\n", key, (long)n, NSStringFromSelector(_cmd)]);
            }
            return;
        }
        sXGURLCounts[key] = @1;
        sXGEntryCount = sXGEntryCount + 1;

        NSString *clsName = @"?";
        @try { clsName = NSStringFromClass([self class]); } @catch (NSException *e) {}
        NSString *selName = NSStringFromSelector(_cmd);

        NSMutableString *entry = [NSMutableString string];
        [entry appendFormat:@"[请求] %@ -%@ 参数%lu个\n", clsName, selName, (unsigned long)argc];
        [entry appendFormat:@"    URL: %@\n", XGTruncateURL(url)];
        if (hkeys && hkeys.count > 0) {
            [entry appendFormat:@"    headers(%lu): %@\n", (unsigned long)hkeys.count, [hkeys componentsJoinedByString:@", "]];
        } else {
            [entry appendFormat:@"    headers: (未取到)\n"];
        }
        [entry appendFormat:@"    签名头: %@\n", XGSignatureMarkers(url, hkeys)];
        [entry appendFormat:@"    时间: %@\n", XGTimestamp()];
        XGAppendLog(entry);
    }
}

// ===== orig 查找表：SEL -> 原 IMP 指针 =====
static NSValue *XGOrigForSEL(SEL sel) {
    @synchronized (XGLock()) {
        static NSMutableDictionary *table = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ table = [[NSMutableDictionary alloc] init]; });
        return table[[NSValue valueWithPointer:sel]];
    }
}

static void XGOrigSetForSEL(SEL sel, void *orig) {
    @synchronized (XGLock()) {
        static NSMutableDictionary *table = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ table = [[NSMutableDictionary alloc] init]; });
        table[[NSValue valueWithPointer:sel]] = [NSValue valueWithPointer:orig];
    }
}

// ===== 8 个形状匹配的 hook 函数（void/id 返回 × 0~3 个对象参数），先记录再转发 =====
static void XGHookV0(id self, SEL _cmd) {
    XGLogCall(self, _cmd, nil, nil, nil, 0);
    void (*orig)(id, SEL) = (void (*)(id, SEL))XGOrigForSEL(_cmd).pointerValue;
    if (orig) orig(self, _cmd);
}
static void XGHookV1(id self, SEL _cmd, id a1) {
    XGLogCall(self, _cmd, a1, nil, nil, 1);
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))XGOrigForSEL(_cmd).pointerValue;
    if (orig) orig(self, _cmd, a1);
}
static void XGHookV2(id self, SEL _cmd, id a1, id a2) {
    XGLogCall(self, _cmd, a1, a2, nil, 2);
    void (*orig)(id, SEL, id, id) = (void (*)(id, SEL, id, id))XGOrigForSEL(_cmd).pointerValue;
    if (orig) orig(self, _cmd, a1, a2);
}
static void XGHookV3(id self, SEL _cmd, id a1, id a2, id a3) {
    XGLogCall(self, _cmd, a1, a2, a3, 3);
    void (*orig)(id, SEL, id, id, id) = (void (*)(id, SEL, id, id, id))XGOrigForSEL(_cmd).pointerValue;
    if (orig) orig(self, _cmd, a1, a2, a3);
}
static id XGHookR0(id self, SEL _cmd) {
    XGLogCall(self, _cmd, nil, nil, nil, 0);
    id (*orig)(id, SEL) = (id (*)(id, SEL))XGOrigForSEL(_cmd).pointerValue;
    if (orig) return orig(self, _cmd);
    return nil;
}
static id XGHookR1(id self, SEL _cmd, id a1) {
    XGLogCall(self, _cmd, a1, nil, nil, 1);
    id (*orig)(id, SEL, id) = (id (*)(id, SEL, id))XGOrigForSEL(_cmd).pointerValue;
    if (orig) return orig(self, _cmd, a1);
    return nil;
}
static id XGHookR2(id self, SEL _cmd, id a1, id a2) {
    XGLogCall(self, _cmd, a1, a2, nil, 2);
    id (*orig)(id, SEL, id, id) = (id (*)(id, SEL, id, id))XGOrigForSEL(_cmd).pointerValue;
    if (orig) return orig(self, _cmd, a1, a2);
    return nil;
}
static id XGHookR3(id self, SEL _cmd, id a1, id a2, id a3) {
    XGLogCall(self, _cmd, a1, a2, a3, 3);
    id (*orig)(id, SEL, id, id, id) = (id (*)(id, SEL, id, id, id))XGOrigForSEL(_cmd).pointerValue;
    if (orig) return orig(self, _cmd, a1, a2, a3);
    return nil;
}

// ===== 枚举某类方法名（前 80 个，排序输出） =====
static NSString *XGMethodsOfClass(Class cls, BOOL classMethods) {
    unsigned int count = 0;
    // 类方法在元类上：class_copyMethodList(object_getClass(cls)) 枚举（runtime 无 class_copyClassMethod）
    Method *list = classMethods ? class_copyMethodList(object_getClass(cls), &count) : class_copyMethodList(cls, &count);
    if (!list) return @"(无)";
    if (count == 0) { free(list); return @"(无)"; }
    NSMutableArray *names = [NSMutableArray array];
    unsigned int shown = count;
    if (shown > kXGMaxMethodsPerClass) shown = kXGMaxMethodsPerClass;
    for (unsigned int i = 0; i < shown; i++) {
        const char *n = sel_getName(method_getName(list[i]));
        [names addObject:(n ? @(n) : @"?")];
    }
    free(list);
    names = [[names sortedArrayUsingSelector:@selector(compare:)] mutableCopy];
    NSString *suffix = @"";
    if (count > kXGMaxMethodsPerClass) {
        suffix = [NSString stringWithFormat:@" ...共%lu个", (unsigned long)count];
    }
    return [NSString stringWithFormat:@"%@%@", [names componentsJoinedByString:@", "], suffix];
}

// ===== 对 TTNetworkManager 动态挂钩（运行时校验签名，绝不硬编方法签名） =====
static void XGInstallTTNetHooks(Class ttCls) {
    if (!ttCls) return;
    unsigned int count = 0;
    Method *list = class_copyMethodList(ttCls, &count);
    if (!list || count == 0) {
        if (list) free(list);
        XGAppendLog(@"[挂钩] TTNetworkManager 无实例方法可挂\n");
        return;
    }
    NSMutableArray *cands = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        Method m = list[i];
        SEL sel = method_getName(m);
        const char *cn = sel_getName(sel);
        if (!cn) continue;
        NSString *name = @(cn);
        NSString *lower = name.lowercaseString;
        if (![lower containsString:@"request"] && ![lower containsString:@"start"]) continue;
        // 返回值必须是 void 或对象
        char *ret = method_copyReturnType(m);
        BOOL retOK = (ret != NULL) && (ret[0] == 'v' || ret[0] == '@');
        BOOL retObj = (ret != NULL) && (ret[0] == '@');
        if (ret) free(ret);
        if (!retOK) continue;
        // 参数（含 self/_cmd 共 nargs 个）实际对象参数 0~3 个且全为对象类型
        unsigned int nargs = method_getNumberOfArguments(m);
        if (nargs < 2 || nargs > 2 + kXGMaxHookArgs) continue;
        BOOL allObj = YES;
        for (unsigned int a = 2; a < nargs; a++) {
            char *t = method_copyArgumentType(m, a);
            if (!t || t[0] != '@') allObj = NO;
            if (t) free(t);
            if (!allObj) break;
        }
        if (!allObj) continue;
        [cands addObject:@{
            @"name" : name,
            @"sel" : [NSValue valueWithPointer:sel],
            @"argc" : @(nargs - 2),
            @"retObj" : @(retObj)
        }];
    }
    free(list);

    // 选择性挂：含 start 的优先，其次按名字排序，最多 3 个
    NSMutableArray *sorted = [[cands sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL aStart = [a[@"name"] containsString:@"start"];
        BOOL bStart = [b[@"name"] containsString:@"start"];
        if (aStart != bStart) return aStart ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] compare:b[@"name"]];
    }] mutableCopy];

    unsigned int hooked = 0;
    NSMutableString *report = [NSMutableString string];
    for (NSDictionary *c in sorted) {
        if (hooked >= kXGMaxHookCount) break;
        SEL sel = (SEL)[c[@"sel"] pointerValue];
        unsigned int argc = [c[@"argc"] unsignedIntValue];
        BOOL retObj = [c[@"retObj"] boolValue];
        NSString *name = c[@"name"];
        IMP hookImp = NULL;
        if (!retObj && argc == 0) hookImp = (IMP)XGHookV0;
        else if (!retObj && argc == 1) hookImp = (IMP)XGHookV1;
        else if (!retObj && argc == 2) hookImp = (IMP)XGHookV2;
        else if (!retObj && argc == 3) hookImp = (IMP)XGHookV3;
        else if (retObj && argc == 0) hookImp = (IMP)XGHookR0;
        else if (retObj && argc == 1) hookImp = (IMP)XGHookR1;
        else if (retObj && argc == 2) hookImp = (IMP)XGHookR2;
        else if (retObj && argc == 3) hookImp = (IMP)XGHookR3;
        if (!hookImp) continue;
        IMP orig = NULL;
        MSHookMessageEx(ttCls, sel, hookImp, &orig);
        if (!orig) {
            [report appendFormat:@"[挂钩] -%@ 挂钩失败(无原实现)\n", name];
            continue;
        }
        XGOrigSetForSEL(sel, (void *)orig);
        hooked = hooked + 1;
        [report appendFormat:@"[挂钩] -%@ 已挂(%lu个对象参数, %@返回) 运行时签名校验通过\n", name, (unsigned long)argc, retObj ? @"对象" : @"void"];
    }
    if (hooked == 0) {
        [report appendFormat:@"[挂钩] 候选%lu个但未挂任何方法（签名校验不通过则只枚举，不强挂）\n", (unsigned long)cands.count];
    }
    XGAppendLog(report);
}

// ===== 探针启动（幂等：只启动一次，枚举+挂钩） =====
static void XGProbeStart(void) {
    @synchronized (XGLock()) {
        static BOOL sStarted = NO;
        if (sStarted) return;
        sStarted = YES;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableString *head = [NSMutableString string];
        [head appendFormat:@"\n===== XG网络探针v1 启动 %@ =====\n", XGTimestamp()];
        [head appendString:@"模式: 纯观察(只hook+记录, 不修改请求, 不调用签名类)\n"];
        XGAppendLog(head);

        // 1) 类与方法枚举
        NSArray *candidates = @[
            @"TTNetworkManager",
            @"TTHTTPRequestSerializer",
            @"TTNetworkRequest",
            @"TTHTTPRequest",
            @"TTNetRequestDealManager",
            @"BDTGTeeStaticSignModule",
            @"SecuritySignature",
            @"SecurityGuardOpenSecureSignature",
            @"TTNetworkSessionInfo"
        ];
        for (NSString *cn in candidates) {
            Class c = NSClassFromString(cn);
            if (!c) {
                XGAppendLog([NSString stringWithFormat:@"[枚举] %@ 不存在\n", cn]);
                continue;
            }
            XGAppendLog([NSString stringWithFormat:@"[枚举] %@ 存在\n  实例方法(%u上限): %@\n  类方法(%u上限): %@\n",
                         cn, kXGMaxMethodsPerClass, XGMethodsOfClass(c, NO), kXGMaxMethodsPerClass, XGMethodsOfClass(c, YES)]);
        }

        // 2) 动态 hook 请求点（仅 TTNetworkManager，运行时校验签名）
        Class tt = NSClassFromString(@"TTNetworkManager");
        if (tt) {
            XGInstallTTNetHooks(tt);
        } else {
            XGAppendLog(@"[挂钩] TTNetworkManager 不存在, 跳过动态挂钩\n");
        }
        XGAppendLog(@"===== XG网络探针v1 初始化完成 =====\n");
    });
}

// ===== 入口：%ctor 查开关 + 监听运行时拨开关（幂等，不会重复 hook） =====
%ctor {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kXGProbeEnabledKey]) {
        XGProbeStart();
    }
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSUserDefaultsDidChangeNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
                    if ([[NSUserDefaults standardUserDefaults] boolForKey:kXGProbeEnabledKey]) {
                        XGProbeStart();
                    }
                }];
}
