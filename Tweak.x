// DY4K - 独立抖音4K解析悬浮球 (不依赖DYYY)
// 原理: ①常驻监听 TTNet Monitor Finish 通知截获 App 原生响应JSON(含bit_rate);
//       ②v1.3 runtime swizzle AWEDPlayerVideoModel setBitrateModels 被动截获播放码率模型;
//       ③v1.4 主动路: 播放页挖 aweme_id → 用APP内 TTNetworkManager 主动发 detail 请求,
//         请求走APP自身签名链路(Argus等自动注入), 服务端必认 → 全档画质主动到手。
//       悬浮球点选画质 → 直连下载 → 存相册。零外部解析请求, 不碰签名/Argus。

#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 模型

@interface DY4KGear : NSObject
@property (nonatomic, copy) NSString *gearName;
@property (nonatomic, strong) NSArray<NSString *> *urls;
@property (nonatomic, assign) long width;
@property (nonatomic, assign) long height;
@property (nonatomic, assign) long bitrate;
@end

@implementation DY4KGear
@end

@interface DY4KVideo : NSObject
@property (nonatomic, copy) NSString *aid;
@property (nonatomic, copy) NSString *desc;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, strong) NSMutableArray<DY4KGear *> *gears;
@property (nonatomic, assign) double time;
- (NSString *)displayTitle;
- (void)mergeGear:(DY4KGear *)g;
- (NSArray<DY4KGear *> *)sortedDedupGears;
@end

@implementation DY4KVideo

- (instancetype)init {
    self = [super init];
    if (self) {
        _gears = [NSMutableArray array];
        _time = [[NSDate date] timeIntervalSince1970];
    }
    return self;
}

- (NSString *)displayTitle {
    NSString *d = self.desc;
    if (d.length == 0) d = @"未取到文案";
    if (d.length > 26) d = [[d substringToIndex:26] stringByAppendingString:@"…"];
    if (self.author.length > 0) return [NSString stringWithFormat:@"@%@ %@", self.author, d];
    return d;
}

- (void)mergeGear:(DY4KGear *)g {
    for (DY4KGear *old in self.gears) {
        if ([old.gearName isEqualToString:g.gearName] && old.width == g.width && old.height == g.height) {
            if (g.bitrate > old.bitrate) {
                old.bitrate = g.bitrate;
                old.urls = g.urls;
            }
            return;
        }
    }
    [self.gears addObject:g];
}

- (NSArray<DY4KGear *> *)sortedDedupGears {
    NSArray<DY4KGear *> *sorted = [self.gears sortedArrayUsingComparator:^NSComparisonResult(DY4KGear *a, DY4KGear *b) {
        if (a.bitrate > b.bitrate) return NSOrderedAscending;
        if (a.bitrate < b.bitrate) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return sorted;
}

@end

#pragma mark - 缓存

static NSMutableDictionary<NSString *, DY4KVideo *> *dy4kCache = nil;
static dispatch_queue_t dy4kParseQueue = nil;
static long dy4kNotifCount = 0;
static long dy4kMonitorHit = 0;
static long dy4kBigHit = 0;
static long dy4kBRHit = 0;
static int dy4kSwizzled = 0;
static NSMutableArray *dy4kMonNames = nil;
// v1.4 主动路诊断
static long dy4kDigHit = 0;        // 播放页挖到 aweme_id 次数
static long dy4kNTMFired = 0;      // TTNetworkManager 请求发出次数
static long dy4kNTMOk = 0;         // 请求成功且解析入库次数
static NSString *dy4kNTMSel = nil; // 命中的 GET selector
static NSString *dy4kLastErr = nil; // 最近一次主动路失败原因

static NSArray<DY4KVideo *> *DY4KRecentVideos(void) {
    NSMutableArray<DY4KVideo *> *arr = [NSMutableArray array];
    double now = [[NSDate date] timeIntervalSince1970];
    @synchronized (dy4kCache) {
        for (NSString *k in [dy4kCache allKeys]) {
            DY4KVideo *v = dy4kCache[k];
            if (now - v.time > 1800) {
                [dy4kCache removeObjectForKey:k];
                continue;
            }
            [arr addObject:v];
        }
    }
    [arr sortUsingComparator:^NSComparisonResult(DY4KVideo *a, DY4KVideo *b) {
        if (a.time > b.time) return NSOrderedAscending;
        if (a.time < b.time) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    if (arr.count > 40) [arr removeObjectsInRange:NSMakeRange(40, arr.count - 40)];
    return arr;
}

#pragma mark - 响应解析

static id DY4KTryVC(id obj, NSString *k1, NSString *k2) {
    @try { id v = [obj valueForKey:k1]; if (v) return v; } @catch (NSException *e) {}
    if (k2) { @try { id v = [obj valueForKey:k2]; if (v) return v; } @catch (NSException *e) {} }
    return nil;
}

static NSString *DY4KFindURL(id node, int depth) {
    if (depth > 5 || !node || node == [NSNull null]) return nil;
    if ([node isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)node;
        if ([s hasPrefix:@"http"] && s.length > 20) return s;
        return nil;
    }
    if ([node isKindOfClass:[NSURL class]]) return ((NSURL *)node).absoluteString;
    if ([node isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)node) {
            NSString *u = DY4KFindURL(v, depth + 1);
            if (u) return u;
        }
        return nil;
    }
    if ([node isKindOfClass:[NSDictionary class]]) {
        for (id v in ((NSDictionary *)node).allValues) {
            NSString *u = DY4KFindURL(v, depth + 1);
            if (u) return u;
        }
        return nil;
    }
    NSString *u = DY4KFindURL(DY4KTryVC(node, @"urlList", @"url_list"), depth + 1);
    if (u) return u;
    u = DY4KFindURL(DY4KTryVC(node, @"playAddr", @"play_addr"), depth + 1);
    if (u) return u;
    return DY4KFindURL(DY4KTryVC(node, @"url", nil), depth + 1);
}

// 竞品同款思路: 播放器设置码率模型时截获(运行时swizzle,不依赖通知)
static void DY4KOnBitrateModels(id models) {
    @try {
        if (!models) return;
        if ([models isKindOfClass:[NSDictionary class]]) models = [(NSDictionary *)models allValues];
        if (![models isKindOfClass:[NSArray class]] || [(NSArray *)models count] == 0) return;
        DY4KGear *best = nil;
        for (id m in (NSArray *)models) {
            if (!m || ![m respondsToSelector:@selector(valueForKey:)]) continue;
            id gn = DY4KTryVC(m, @"gearName", @"gear_name");
            id br = DY4KTryVC(m, @"bitRate", @"bit_rate");
            id pa = DY4KTryVC(m, @"playAddr", @"play_addr");
            id w = DY4KTryVC(m, @"width", nil);
            id h = DY4KTryVC(m, @"height", nil);
            NSString *url = DY4KFindURL(pa, 0);
            if (!url) {
                id u2 = DY4KTryVC(m, @"uri", nil);
                if (!u2 && pa) u2 = DY4KTryVC(pa, @"uri", nil);
                if ([u2 isKindOfClass:[NSString class]] && [(NSString *)u2 length] > 5) {
                    url = [NSString stringWithFormat:@"https://www.douyin.com/aweme/v1/play/?video_id=%@&ratio=1080p", u2];
                }
            }
            if (!url) continue;
            DY4KGear *g = [DY4KGear new];
            g.gearName = [gn isKindOfClass:[NSString class]] ? gn : @"gear";
            g.bitrate = [br isKindOfClass:[NSNumber class]] ? [(NSNumber *)br longValue] : 0;
            g.width = [w isKindOfClass:[NSNumber class]] ? [(NSNumber *)w longValue] : 0;
            g.height = [h isKindOfClass:[NSNumber class]] ? [(NSNumber *)h longValue] : 0;
            g.urls = @[url];
            if (!best || g.bitrate > best.bitrate) best = g;
        }
        if (!best) return;
        @synchronized (dy4kCache) {
            DY4KVideo *v = dy4kCache[@"__current__"];
            if (!v) {
                v = [DY4KVideo new];
                v.aid = @"__current__";
                v.desc = @"当前播放视频";
                dy4kCache[@"__current__"] = v;
            }
            v.time = [[NSDate date] timeIntervalSince1970];
            [v mergeGear:best];
        }
    } @catch (NSException *e) {}
}

static DY4KGear *DY4KParseGear(NSDictionary *br) {
    if (![br isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *pa = br[@"play_addr"];
    if (![pa isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *ul = pa[@"url_list"];
    if (![ul isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    for (id u in ul) {
        if ([u isKindOfClass:[NSString class]] && [(NSString *)u hasPrefix:@"http"]) [urls addObject:u];
    }
    if (urls.count == 0) return nil;
    DY4KGear *g = [DY4KGear new];
    id gn = br[@"gear_name"];
    g.gearName = [gn isKindOfClass:[NSString class]] ? gn : @"gear";
    g.urls = [urls copy];
    g.width = [pa[@"width"] longValue];
    g.height = [pa[@"height"] longValue];
    g.bitrate = [br[@"bit_rate"] longValue];
    return g;
}

// 带 aid 上下文的深度优先: aweme dict 更新本地 aid/desc/author, 子树内 bit_rate 归属该 aid
static void DY4KWalk(id node, NSString *pAid, NSString *pDesc, NSString *pAuthor, NSMutableDictionary<NSString *, DY4KVideo *> *acc) {
    @try {
        if ([node isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = node;
            NSString *aid = pAid;
            id rawAid = d[@"aweme_id"];
            if ([rawAid isKindOfClass:[NSString class]] && [(NSString *)rawAid length] >= 10) {
                aid = rawAid;
            } else if ([rawAid isKindOfClass:[NSNumber class]]) {
                aid = [(NSNumber *)rawAid stringValue];
            }
            BOOL newAid = (aid != nil && ![aid isEqualToString:pAid]);
            NSString *desc = pDesc;
            NSString *author = pAuthor;
            if (newAid) {
                desc = nil;
                author = nil;
            }
            id rawDesc = d[@"desc"];
            if ([rawDesc isKindOfClass:[NSString class]] && [(NSString *)rawDesc length] > 0) desc = rawDesc;
            id ad = d[@"author"];
            if ([ad isKindOfClass:[NSDictionary class]]) {
                id nk = ad[@"nickname"];
                if ([nk isKindOfClass:[NSString class]]) author = nk;
            }
            id br = d[@"bit_rate"];
            if ([br isKindOfClass:[NSArray class]] && aid.length > 0) {
                DY4KVideo *v = acc[aid];
                if (!v) {
                    v = [DY4KVideo new];
                    v.aid = aid;
                    acc[aid] = v;
                }
                if (v.desc.length == 0 && desc.length > 0) v.desc = desc;
                if (v.author.length == 0 && author.length > 0) v.author = author;
                v.time = [[NSDate date] timeIntervalSince1970];
                for (id item in br) {
                    DY4KGear *g = DY4KParseGear(item);
                    if (g) [v mergeGear:g];
                }
            }
            for (id key in [d allKeys]) {
                DY4KWalk(d[key], aid, desc, author, acc);
            }
        } else if ([node isKindOfClass:[NSArray class]]) {
            for (id v in (NSArray *)node) {
                DY4KWalk(v, pAid, pDesc, pAuthor, acc);
            }
        }
    } @catch (NSException *e) {
        // 解析容错, 不中断
    }
}

// v1.4: 解析结果统一入库(通知路/主动路共用)
static void DY4KAbsorb(NSDictionary<NSString *, DY4KVideo *> *acc) {
    if (!acc.count) return;
    @synchronized (dy4kCache) {
        for (NSString *aid in acc) {
            DY4KVideo *nv = acc[aid];
            DY4KVideo *ov = dy4kCache[aid];
            if (!ov) {
                dy4kCache[aid] = nv;
            } else {
                for (DY4KGear *g in nv.gears) [ov mergeGear:g];
                if (ov.desc.length == 0 && nv.desc.length > 0) ov.desc = nv.desc;
                if (ov.author.length == 0 && nv.author.length > 0) ov.author = nv.author;
                ov.time = nv.time;
            }
        }
        // 上限清理: 只保留最近40条
        if (dy4kCache.count > 40) {
            NSArray *keys = [dy4kCache keysSortedByValueUsingComparator:^NSComparisonResult(DY4KVideo *a, DY4KVideo *b) {
                if (a.time > b.time) return NSOrderedDescending;
                if (a.time < b.time) return NSOrderedAscending;
                return NSOrderedSame;
            }];
            for (NSUInteger i = 40; i < keys.count; i++) [dy4kCache removeObjectForKey:keys[i]];
        }
    }
}

static void DY4KInspectResponse(NSDictionary *userInfo) {
    @try {
        if (![userInfo isKindOfClass:[NSDictionary class]]) return;
        id req = userInfo[@"kTTNetworkManagerMonitorRequestKey"];
        NSData *data = userInfo[@"kTTNetworkManagerMonitorResponseDataKey"];
        if (![data isKindOfClass:[NSData class]] || data.length < 20000) return;
        if (((const uint8_t *)data.bytes)[0] != 0x7b) return; // 只解析JSON '{'
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) return;
        dispatch_async(dy4kParseQueue, ^{
            @try {
                NSMutableDictionary<NSString *, DY4KVideo *> *acc = [NSMutableDictionary dictionary];
                DY4KWalk(json, nil, nil, nil, acc);
                dy4kBigHit += (long)acc.count;
                DY4KAbsorb(acc);
            } @catch (NSException *e3) {}
        });
    } @catch (NSException *e) {}
}

#pragma mark - 下载器

@interface DY4KDownloader : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSArray<NSString *> *urls;
@property (nonatomic, assign) NSUInteger idx;
@property (nonatomic, copy) void (^onProgress)(double frac);
@property (nonatomic, copy) void (^onDone)(BOOL ok, NSString *savedPath, NSString *errMsg);
@end

static BOOL DY4KValidMP4(NSString *path) {
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!h) return NO;
    NSData *d = [h readDataOfLength:16];
    [h closeFile];
    if (d.length < 12) return NO;
    const uint8_t *b = (const uint8_t *)d.bytes;
    for (int i = 0; i + 4 <= 12; i++) {
        if (b[i] == 'f' && b[i + 1] == 't' && b[i + 2] == 'y' && b[i + 3] == 'p') return YES;
    }
    return NO;
}

@implementation DY4KDownloader

- (void)start:(NSArray<NSString *> *)urls onProgress:(void (^)(double))prog onDone:(void (^)(BOOL, NSString *, NSString *))done {
    self.urls = urls;
    self.idx = 0;
    self.onProgress = prog;
    self.onDone = done;
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 120;
    cfg.timeoutIntervalForResource = 900;
    // 教训(3302): 不加任何自定义UA/Referer/header, CDN内部鉴权URL直连
    self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    [self tryNext];
}

- (void)tryNext {
    if (self.idx >= self.urls.count) {
        if (self.onDone) self.onDone(NO, nil, @"全部直链下载失败(含有效性校验)");
        return;
    }
    NSString *u = self.urls[self.idx];
    self.idx = self.idx + 1;
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:u]];
    NSURLSessionDownloadTask *t = [self.session downloadTaskWithRequest:req];
    [t resume];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)exp {
    if (exp > 0 && self.onProgress) {
        double f = (double)total / (double)exp;
        if (f > 1.0) f = 1.0;
        self.onProgress(f);
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"dy4k_%f.mp4", [[NSDate date] timeIntervalSince1970]]];
    NSError *mvErr = nil;
    [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:tmp error:&mvErr];
    if (mvErr) {
        if (self.onDone) self.onDone(NO, nil, @"落盘失败");
        return;
    }
    if (!DY4KValidMP4(tmp)) {
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{ [self tryNext]; }];
        return;
    }
    if (self.onDone) self.onDone(YES, tmp, nil);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{ [self tryNext]; }];
    }
}

@end

#pragma mark - UI

@interface DY4KBall : NSObject
+ (instancetype)shared;
- (void)mount;
- (UIViewController *)hostVC;
@end

static UIViewController *DY4KTopVC(void) {
    UIViewController *top = [[DY4KBall shared] hostVC];
    if (!top) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]] && sc.activationState == UISceneActivationStateForegroundActive) {
                UIWindow *w = ((UIWindowScene *)sc).keyWindow;
                if (!w) {
                    for (UIWindow *ww in ((UIWindowScene *)sc).windows) {
                        if (ww.isKeyWindow) { w = ww; break; }
                    }
                }
                top = w.rootViewController;
                break;
            }
        }
    }
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

static void DY4KAlert(NSString *msg, NSArray<UIAlertAction *> *actions) {
    UIViewController *top = DY4KTopVC();
    if (!top) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"DY4K" message:msg preferredStyle:UIAlertControllerStyleAlert];
    if (actions.count == 0) {
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    } else {
        for (UIAlertAction *a in actions) [ac addAction:a];
    }
    [top presentViewController:ac animated:YES completion:nil];
}

// v1.4: 从当前播放页VC树挖当前视频 aweme_id (AWEPlayInteractionViewController.model.itemID)
static NSString *DY4KDigCurrentAid(NSString **outDesc, NSString **outAuthor) {
    UIViewController *top = DY4KTopVC();
    if (!top) {
        @synchronized (dy4kMonNames) { dy4kLastErr = @"无TopVC"; }
        return nil;
    }
    NSMutableArray<UIViewController *> *queue = [NSMutableArray arrayWithObject:top];
    int steps = 0;
    while (queue.count > 0 && steps < 64) {
        steps++;
        UIViewController *vc = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (!vc) continue;
        NSString *cls = NSStringFromClass([vc class]);
        if ([cls containsString:@"PlayInteraction"] || [cls containsString:@"AwemeDetail"]) {
            for (NSString *mk in @[@"model", @"awemeModel", @"currentAwemeModel"]) {
                @try {
                    id m = [vc valueForKey:mk];
                    if (!m || [m isKindOfClass:[NSNull class]]) continue;
                    id aid = [m valueForKey:@"itemID"];
                    if (![aid isKindOfClass:[NSString class]] || [(NSString *)aid length] < 10) continue;
                    dy4kDigHit++;
                    if (outDesc) {
                        id d = [m valueForKey:@"descriptionString"];
                        if (![d isKindOfClass:[NSString class]] || [(NSString *)d length] == 0) d = [m valueForKey:@"itemTitle"];
                        *outDesc = [d isKindOfClass:[NSString class]] ? d : nil;
                    }
                    if (outAuthor) {
                        id au = [m valueForKeyPath:@"author.nickname"];
                        *outAuthor = [au isKindOfClass:[NSString class]] ? au : nil;
                    }
                    return aid;
                } @catch (NSException *e) {}
            }
        }
        [queue addObjectsFromArray:vc.childViewControllers];
        if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
    }
    @synchronized (dy4kMonNames) { dy4kLastErr = @"未找到播放页VC"; }
    return nil;
}

// v1.4: 用APP内TTNetworkManager主动发detail请求(走APP自身签名链路, Argus等自动注入, 服务端必认)
static void DY4KFetchDetail(NSString *aid, void (^done)(BOOL ok)) {
    dispatch_async(dy4kParseQueue, ^{
        __block BOOL ok = NO;
        @try {
            Class ntm = NSClassFromString(@"TTNetworkManager");
            id mgr = ntm ? [ntm performSelector:NSSelectorFromString(@"sharedManager")] : nil;
            if (!mgr) {
                @synchronized (dy4kMonNames) { dy4kLastErr = @"TTNetworkManager不可用"; }
            } else {
                SEL sels[2] = {NSSelectorFromString(@"GET:parameters:completionHandler:"), NSSelectorFromString(@"GET:parameters:headers:completionHandler:")};
                SEL sel = nil;
                for (int i = 0; i < 2; i++) {
                    if ([mgr respondsToSelector:sels[i]]) {
                        sel = sels[i];
                        @synchronized (dy4kMonNames) { dy4kNTMSel = NSStringFromSelector(sels[i]); }
                        break;
                    }
                }
                if (!sel) {
                    @synchronized (dy4kMonNames) { dy4kLastErr = @"无匹配GET方法"; }
                } else {
                    dy4kNTMFired++;
                    NSString *url = [NSString stringWithFormat:@"https://api.snssdk.com/aweme/v1/feed/detail/?aweme_id=%@", aid];
                    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                    void (^handler)(id, NSError *) = ^(id data, NSError *err) {
                        @try {
                            NSDictionary *json = nil;
                            if ([data isKindOfClass:[NSDictionary class]]) json = data;
                            else if ([data isKindOfClass:[NSData class]]) json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                            if (![json isKindOfClass:[NSDictionary class]]) {
                                @synchronized (dy4kMonNames) { dy4kLastErr = err ? [NSString stringWithFormat:@"HTTP错误:%@", err.localizedDescription] : @"响应非JSON"; }
                            } else {
                                NSMutableDictionary<NSString *, DY4KVideo *> *acc = [NSMutableDictionary dictionary];
                                DY4KWalk(json, nil, nil, nil, acc);
                                DY4KAbsorb(acc);
                                if (acc.count > 0) {
                                    dy4kNTMOk++;
                                    ok = YES;
                                } else {
                                    @synchronized (dy4kMonNames) { dy4kLastErr = @"响应无bit_rate"; }
                                }
                            }
                        } @catch (NSException *e) {}
                        dispatch_semaphore_signal(sem);
                    };
                    if (sel == sels[0]) {
                        ((void (*)(id, SEL, NSString *, NSDictionary *, id))objc_msgSend)(mgr, sel, url, @{}, handler);
                    } else {
                        ((void (*)(id, SEL, NSString *, NSDictionary *, NSDictionary *, id))objc_msgSend)(mgr, sel, url, @{}, @{}, handler);
                    }
                    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 12LL * NSEC_PER_SEC));
                }
            }
        } @catch (NSException *e) {
            @synchronized (dy4kMonNames) { dy4kLastErr = e.reason ?: @"未知异常"; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (done) done(ok);
        });
    });
}

static void DY4KShowDiag(void) {
    NSMutableString *msg = [NSMutableString string];
    [msg appendFormat:@"通知总数:%ld", dy4kNotifCount];
    [msg appendFormat:@"\nMonitorFinish:%ld", dy4kMonitorHit];
    [msg appendFormat:@"\n大响应入库:%ld", dy4kBigHit];
    [msg appendFormat:@"\n码率模型:%ld", dy4kBRHit];
    [msg appendFormat:@"\nswizzle:%d", dy4kSwizzled];
    [msg appendFormat:@"\n挖aid:%ld", dy4kDigHit];
    [msg appendFormat:@"\n主动请求:%ld/%ld", dy4kNTMOk, dy4kNTMFired];
    NSString *ntmSel = nil;
    NSString *lastErr = nil;
    @synchronized (dy4kMonNames) { ntmSel = dy4kNTMSel; lastErr = dy4kLastErr; }
    if (ntmSel.length > 0) [msg appendFormat:@"\nGET方法:%@", ntmSel];
    [msg appendFormat:@"\n主动路错误:%@", lastErr ?: @"无"];
    [msg appendFormat:@"\n缓存:%lu条", (unsigned long)dy4kCache.count];
    NSString *names = nil;
    @synchronized (dy4kMonNames) { names = [dy4kMonNames componentsJoinedByString:@", "]; }
    [msg appendFormat:@"\n相关通知:%@", names.length ? names : @"无"];
    DY4KAlert(msg, nil);
}

static void DY4KSaveAndReport(NSString *path) {
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:path]];
    } completionHandler:^(BOOL success, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                DY4KAlert(@"已保存到相册", nil);
            } else {
                DY4KAlert([NSString stringWithFormat:@"保存失败: %@", err.localizedDescription ?: @"未知错误"], nil);
            }
        });
    }];
}

static void DY4KDownloadGear(DY4KGear *g) {
    UIViewController *top = DY4KTopVC();
    if (!top) return;
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:@"DY4K 下载中" message:@"0%" preferredStyle:UIAlertControllerStyleAlert];
    [busy addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:busy animated:YES completion:nil];
    DY4KDownloader *dl = [DY4KDownloader new];
    [dl start:g.urls onProgress:^(double frac) {
        dispatch_async(dispatch_get_main_queue(), ^{
            busy.message = [NSString stringWithFormat:@"%.0f%%", frac * 100];
        });
    } onDone:^(BOOL ok, NSString *savedPath, NSString *errMsg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [busy dismissViewControllerAnimated:NO completion:nil];
            if (ok) {
                DY4KSaveAndReport(savedPath);
            } else {
                DY4KAlert([NSString stringWithFormat:@"下载失败: %@\n档位: %@ %ldx%ld", errMsg, g.gearName, g.width, g.height], nil);
            }
        });
    }];
}

static void DY4KShowQuality(DY4KVideo *v) {
    NSArray<DY4KGear *> *gears = [v sortedDedupGears];
    if (gears.count == 0) {
        DY4KAlert(@"该视频暂无档位数据\n请先播放几秒或切换一次画质, 再点悬浮球", nil);
        return;
    }
    UIViewController *top = DY4KTopVC();
    if (!top) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择画质" message:v.displayTitle preferredStyle:UIAlertControllerStyleActionSheet];
    for (DY4KGear *g in gears) {
        long maxEdge = g.width > g.height ? g.width : g.height;
        NSString *tag = @"[标清] ";
        if (maxEdge >= 2100) tag = @"[4K] ";
        else if (maxEdge >= 1400) tag = @"[2K] ";
        else if (maxEdge >= 1060) tag = @"[1080p] ";
        else if (maxEdge >= 700) tag = @"[720p] ";
        NSString *t = [NSString stringWithFormat:@"%@%@ %ldx%ld · %.1fMbps", tag, g.gearName, g.width, g.height, (double)g.bitrate / 1000000.0];
        [sheet addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            DY4KDownloadGear(g);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:sheet animated:YES completion:nil];
}

static void DY4KShowMenuLegacy(void) {
    NSArray<DY4KVideo *> *recent = DY4KRecentVideos();
    if (recent.count == 0) {
        DY4KAlert(@"暂无截获数据\n先在抖音刷一两个视频(滑动切换), 再点悬浮球", nil);
        return;
    }
    if (recent.count == 1) {
        DY4KShowQuality(recent.firstObject);
        return;
    }
    UIViewController *top = DY4KTopVC();
    if (!top) return;
    UIAlertController *pick = [UIAlertController alertControllerWithTitle:@"选择视频" message:@"按最近截获排序" preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger n = recent.count > 6 ? 6 : recent.count;
    for (NSUInteger i = 0; i < n; i++) {
        DY4KVideo *v = recent[i];
        [pick addAction:[UIAlertAction actionWithTitle:v.displayTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            DY4KShowQuality(v);
        }]];
    }
    [pick addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:pick animated:YES completion:nil];
}

// v1.4 入口: 先挖当前播放视频主动拉全档, 失败退回截获缓存
static void DY4KShowMenu(void) {
    NSString *aid = DY4KDigCurrentAid(nil, nil);
    if (aid.length > 0) {
        UIViewController *top = DY4KTopVC();
        if (!top) return;
        __block BOOL cancelled = NO;
        UIAlertController *busy = [UIAlertController alertControllerWithTitle:@"DY4K 拉取全档画质中…" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [busy addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) {
            cancelled = YES;
        }]];
        [top presentViewController:busy animated:YES completion:nil];
        DY4KFetchDetail(aid, ^(BOOL ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (cancelled) return;
                [busy dismissViewControllerAnimated:NO completion:nil];
                DY4KVideo *v = nil;
                @synchronized (dy4kCache) { v = dy4kCache[aid]; }
                if (v && v.gears.count > 0) {
                    DY4KShowQuality(v);
                    return;
                }
                NSString *err = nil;
                @synchronized (dy4kMonNames) { err = dy4kLastErr; }
                UIAlertController *info = [UIAlertController alertControllerWithTitle:nil message:[NSString stringWithFormat:@"主动请求未拿到档位(%@)\n\n可看已截获的缓存数据", err ?: @"超时"] preferredStyle:UIAlertControllerStyleAlert];
                [info addAction:[UIAlertAction actionWithTitle:@"看缓存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                    DY4KShowMenuLegacy();
                }]];
                [info addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                UIViewController *t2 = DY4KTopVC();
                if (t2) [t2 presentViewController:info animated:YES completion:nil];
            });
        });
        return;
    }
    DY4KShowMenuLegacy();
}

#pragma mark - 悬浮球

@interface DY4KBallWindow : UIWindow
@property (nonatomic, weak) UIView *allowedView;
@property (nonatomic, weak) UIViewController *hostRef;
@end

@implementation DY4KBallWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:p withEvent:event];
    if (hit == nil || hit == self) return nil;
    UIView *v = hit;
    while (v && v != self) {
        if (v == self.allowedView) return hit;
        v = v.superview;
    }
    UIViewController *pres = self.hostRef.presentedViewController;
    if (pres && pres.isViewLoaded && [hit isDescendantOfView:pres.view]) return hit;
    return nil;
}
@end

@implementation DY4KBall {
    DY4KBallWindow *_win;
    UIViewController *_hostVC;
    UIButton *_btn;
}

+ (instancetype)shared {
    static DY4KBall *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [DY4KBall new];
    });
    return s;
}

- (UIViewController *)hostVC {
    return _hostVC;
}

- (void)mount {
    if (_win) return;
    UIWindowScene *scene = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]] && sc.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)sc;
            break;
        }
    }
    if (!scene) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)sc; break; }
        }
    }
    if (!scene) return;
    CGFloat x = [[NSUserDefaults standardUserDefaults] floatForKey:@"dy4k_ball_x"];
    CGFloat y = [[NSUserDefaults standardUserDefaults] floatForKey:@"dy4k_ball_y"];
    CGSize scr0 = scene.screen.bounds.size;
    if (x <= 0 && y <= 0) {
        x = scr0.width - 60;
        y = 220;
    }
    _win = [[DY4KBallWindow alloc] initWithWindowScene:scene];
    _win.frame = scene.screen.bounds;
    _win.windowLevel = 1000000;
    _win.backgroundColor = [UIColor clearColor];
    _win.hidden = NO;
    _hostVC = [UIViewController new];
    _win.rootViewController = _hostVC;
    _win.hostRef = _hostVC;
    _win.allowedView = nil;
    _btn = [UIButton buttonWithType:UIButtonTypeCustom];
    _btn.frame = CGRectMake(x, y, 44, 44);
    _btn.layer.cornerRadius = 22;
    _btn.clipsToBounds = YES;
    _btn.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.72];
    [_btn setTitle:@"4K" forState:UIControlStateNormal];
    _btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_btn addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    [_btn addGestureRecognizer:pan];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longpressed:)];
    lp.minimumPressDuration = 0.8;
    [_btn addGestureRecognizer:lp];
    _win.allowedView = _btn;
    [_win addSubview:_btn];
}

- (void)panned:(UIPanGestureRecognizer *)p {
    if (p.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [p translationInView:_win];
        CGRect f = _btn.frame;
        f.origin.x += t.x;
        f.origin.y += t.y;
        CGSize scr = _win.bounds.size;
        if (f.origin.x < 0) f.origin.x = 0;
        if (f.origin.y < 80) f.origin.y = 80;
        if (f.origin.x > scr.width - 44) f.origin.x = scr.width - 44;
        if (f.origin.y > scr.height - 120) f.origin.y = scr.height - 120;
        _win.frame = f;
        [p setTranslation:CGPointZero inView:_win];
    } else if (p.state == UIGestureRecognizerStateEnded) {
        [[NSUserDefaults standardUserDefaults] setFloat:_btn.frame.origin.x forKey:@"dy4k_ball_x"];
        [[NSUserDefaults standardUserDefaults] setFloat:_btn.frame.origin.y forKey:@"dy4k_ball_y"];
    }
}

- (void)tapped {
    UIImpactFeedbackGenerator *hap = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [hap impactOccurred];
    dispatch_async(dispatch_get_main_queue(), ^{
        DY4KShowMenu();
    });
}

- (void)longpressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIImpactFeedbackGenerator *hap = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [hap impactOccurred];
    dispatch_async(dispatch_get_main_queue(), ^{
        DY4KShowDiag();
    });
}

@end

#pragma mark - 入口

static id dy4kAllObs = nil;
static id dy4kActiveObs = nil;
static IMP dy4kOrigSetBR = NULL;

static void dy4kHookSetBitrateModels(id self, SEL _cmd, id models) {
    DY4KOnBitrateModels(models);
    if (dy4kOrigSetBR) ((void (*)(id, SEL, id))dy4kOrigSetBR)(self, _cmd, models);
}

%ctor {
    @autoreleasepool {
        dy4kCache = [NSMutableDictionary dictionary];
        dy4kParseQueue = dispatch_queue_create("com.omega.dy4k.parse", DISPATCH_QUEUE_SERIAL);
        dy4kMonNames = [NSMutableArray array];
        dy4kAllObs = [[NSNotificationCenter defaultCenter] addObserverForName:nil object:nil queue:nil usingBlock:^(NSNotification *note) {
            @try {
                dy4kNotifCount++;
                NSString *n = note.name ?: @"";
                if ([n containsString:@"Monitor"] || [n containsString:@"TTNetwork"] || [n containsString:@"Network"] || [n containsString:@"network"]) {
                    @synchronized (dy4kMonNames) {
                        if (dy4kMonNames.count < 12 && ![dy4kMonNames containsObject:n]) [dy4kMonNames addObject:n];
                    }
                }
                if ([n isEqualToString:@"kTTNetworkManagerMonitorFinishNotification"]) {
                    dy4kMonitorHit++;
                    DY4KInspectResponse(note.userInfo);
                }
            } @catch (NSException *e) {}
        }];
        Class brCls = NSClassFromString(@"AWEDPlayerVideoModel");
        if (brCls) {
            Method m = class_getInstanceMethod(brCls, NSSelectorFromString(@"setBitrateModels:"));
            if (m) {
                dy4kOrigSetBR = method_getImplementation(m);
                method_setImplementation(m, (IMP)dy4kHookSetBitrateModels);
                dy4kSwizzled = 1;
            }
        }
        dy4kActiveObs = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[DY4KBall shared] mount];
            });
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[DY4KBall shared] mount];
        });
    }
}
