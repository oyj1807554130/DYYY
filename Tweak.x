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
// v1.6 诊断
static long dy4kDigHit = 0;        // 播放页挖到 aweme_id 次数
static NSString *dy4kLastErr = nil; // 最近一次主动路失败原因
static NSString *dy4kDlErr = nil; // v1.9: 最近一次下载失败详情(HTTP状态/错误码)
static long dy4kURLHit = 0;        // v1.6 URLSession拦截命中入库次数
static NSMutableArray *dy4kMonPaths = nil; // Monitor响应URL path样本
static NSMutableArray *dy4kURLPaths = nil; // v1.8: NSURLSession(系统会话)请求path样本
static NSMutableArray *dy4kMonHex = nil;   // Monitor响应body头部hex(判压缩)
// v1.5 自适应诊断
static NSMutableArray *dy4kFoundCls = nil;   // 运行时发现的相关类名
static NSMutableArray *dy4kNTMMethods = nil; // TTNetworkManager 的 GET/POST/request 方法名
static long dy4kWideHooked = 0;              // 广撒网 hook 到的方法数
static NSMutableDictionary *dy4kOldImps = nil; // 广撒网原IMP表(类名+方法名 -> IMP)

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
// v2.1/v2.2 前向声明: 码率回调时同步挖真aid, 让缓存按视频分开
static NSString *DY4KDigCurrentAid(NSString **outDesc, NSString **outAuthor, BOOL quiet);
static NSString *DY4KDigAidFromHolder(id holder, NSString **outDesc, NSString **outAuthor);
// v2.2: 码率回调记录的"正在播放"视频(播放事实, 比BFS挖VC可靠)
static NSString *dy4kPlayingAid = nil;
static NSString *dy4kPlayingDesc = nil;
static NSString *dy4kPlayingAuthor = nil;
static double dy4kPlayingTime = 0;
// v2.3: 拉流反查(video_id->aid映射 + 最近拉流aid=真正在播的硬信号)
static NSMutableDictionary<NSString *, NSString *> *dy4kUriMap = nil;
static NSString *dy4kLastStreamAid = nil;
static double dy4kLastStreamTime = 0;
static long dy4kStreamSeen = 0;  // v2.4: 拦到的合法拉流URL计数
static long dy4kStreamHit = 0;   // v2.4: 拉流反查映射命中计数
static long dy4kFeedHit = 0;     // v2.5: feed兜底成功计数
static long dy4kWebHit = 0;      // v2.7: Step2 Web detail首发成功计数
static long dy4kHealHit = 0;     // v2.7: 自愈重打成功计数
static void DY4KMarkStreamURL(NSString *u);
static void DY4KOnBitrateModels(id self, id models) {
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
        // v2.2: 优先从播放器self挖(真正在播), BFS TopVC可能命中预加载页
        NSString *dgDesc = nil, *dgAuthor = nil;
        NSString *curAid = DY4KDigAidFromHolder(self, &dgDesc, &dgAuthor);
        if (curAid.length < 10) curAid = DY4KDigCurrentAid(&dgDesc, &dgAuthor, YES);
        @synchronized (dy4kMonNames) {
            dy4kPlayingAid = curAid;
            dy4kPlayingDesc = dgDesc;
            dy4kPlayingAuthor = dgAuthor;
            dy4kPlayingTime = [[NSDate date] timeIntervalSince1970];
        }
        @synchronized (dy4kCache) {
            if (curAid.length >= 10 && ![curAid hasPrefix:@"__"]) {
                DY4KVideo *v = dy4kCache[curAid];
                if (!v) {
                    v = [DY4KVideo new];
                    v.aid = curAid;
                    dy4kCache[curAid] = v;
                }
                if (dgDesc.length > 0) v.desc = dgDesc;
                if (dgAuthor.length > 0) v.author = dgAuthor;
                v.time = [[NSDate date] timeIntervalSince1970];
                [v mergeGear:best];
            } else {
                // v2.1: 挖不到aid时按3秒窗口判断换视频, 换视频清空重建防串台
                double now = [[NSDate date] timeIntervalSince1970];
                DY4KVideo *v = dy4kCache[@"__current__"];
                if (!v || now - v.time > 3.0) {
                    v = [DY4KVideo new];
                    v.aid = @"__current__";
                    dy4kCache[@"__current__"] = v;
                }
                v.time = now;
                [v mergeGear:best];
            }
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
            // v2.3: 记录 video_id(uri)->aid, 供拉流请求反查当前播放
            id vid = d[@"video"][@"play_addr"][@"uri"];
            if (![vid isKindOfClass:[NSString class]] || [(NSString *)vid length] < 10) {
                id br0 = ([br isKindOfClass:[NSArray class]] && [(NSArray *)br count] > 0) ? [(NSArray *)br objectAtIndex:0] : nil;
                vid = [br0 isKindOfClass:[NSDictionary class]] ? br0[@"play_addr"][@"uri"] : nil;
            }
            if ([vid isKindOfClass:[NSString class]] && [(NSString *)vid length] >= 10 && aid.length >= 10) {
                if (!dy4kUriMap) dy4kUriMap = [NSMutableDictionary dictionary];
                @synchronized (dy4kMonNames) {
                    if (dy4kUriMap.count > 200) [dy4kUriMap removeAllObjects];
                    dy4kUriMap[vid] = aid;
                }
            }
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
        if (![data isKindOfClass:[NSData class]]) return;
        // v1.6 诊断: 记录path样本与body头部hex(判断是否压缩)
        @synchronized (dy4kMonPaths) {
            if (dy4kMonPaths.count < 40) {
                NSString *pth = @"";
                @try {
                    id r0 = [req valueForKey:@"request"];
                    if ([r0 isKindOfClass:[NSURLRequest class]]) pth = ((NSURLRequest *)r0).URL.path ?: @"";
                    else {
                        id u = [req valueForKey:@"URL"];
                        if ([u isKindOfClass:[NSURL class]]) pth = ((NSURL *)u).path ?: @"";
                    }
                } @catch (NSException *e2) {}
                if (pth.length > 0) [dy4kMonPaths addObject:[NSString stringWithFormat:@"%@(%luB)", pth, (unsigned long)data.length]];
            }
        }
        @synchronized (dy4kMonHex) {
            if (dy4kMonHex.count < 8 && data.length >= 2000) {
                const uint8_t *b = (const uint8_t *)data.bytes;
                [dy4kMonHex addObject:[NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x", b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]];
            }
        }
        // v2.3: TTNet路也标记拉流(用请求URL反查)
        @try {
            NSURL *surl = nil;
            id r0 = [req valueForKey:@"request"];
            if ([r0 isKindOfClass:[NSURLRequest class]]) surl = ((NSURLRequest *)r0).URL;
            else {
                id u = [req valueForKey:@"URL"];
                if ([u isKindOfClass:[NSURL class]]) surl = (NSURL *)u;
            }
            if (surl.absoluteString.length > 0) DY4KMarkStreamURL(surl.absoluteString);
        } @catch (NSException *e5) {}
        if (data.length < 20000) return;
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

#pragma mark - URLSession响应拦截 (v1.6)

// v2.3: 媒体拉流URL带video_id=token, 反查uri map得当前播放aid(拉流=播放硬事实)
static void DY4KMarkStreamURL(NSString *u) {
    if (u.length == 0) return;
    NSRange k = [u rangeOfString:@"video_id="];
    if (k.location == NSNotFound || k.location + k.length >= u.length) return;
    NSString *tail = [u substringFromIndex:k.location + k.length];
    NSRange amp = [tail rangeOfString:@"&"];
    NSString *vid = amp.location == NSNotFound ? tail : [tail substringToIndex:amp.location];
    if (vid.length < 10) return;
    NSString *aid = nil;
    @synchronized (dy4kMonNames) {
        dy4kStreamSeen++;
        aid = dy4kUriMap[vid];
        if (aid.length >= 10) {
            dy4kStreamHit++;
            dy4kLastStreamAid = aid;
            dy4kLastStreamTime = [[NSDate date] timeIntervalSince1970];
        }
    }
}

// v1.6: 拦截APP所有NSURLSession响应(Alamofire等最终都走这里), 抓douyin大JSON入库
static void DY4KTapResponse(NSString *url, NSData *data) {
    if (url.length > 0) DY4KMarkStreamURL(url);
    if (!url.length || data.length < 20000) return;
    if (((const uint8_t *)data.bytes)[0] != 0x7b) return; // 只解析JSON '{'
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    dispatch_async(dy4kParseQueue, ^{
        @try {
            NSMutableDictionary<NSString *, DY4KVideo *> *acc = [NSMutableDictionary dictionary];
            DY4KWalk(json, nil, nil, nil, acc);
            if (acc.count > 0) {
                dy4kURLHit++;
                DY4KAbsorb(acc);
            }
        } @catch (NSException *e) {}
    });
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
        long sc = 0;
        NSString *head = @"";
        NSData *hd = [NSData dataWithContentsOfFile:tmp options:NSDataReadingMappedIfSafe error:nil];
        if (hd.length > 0) {
            NSData *pre = [hd subdataWithRange:NSMakeRange(0, MIN((NSUInteger)24, hd.length))];
            head = [[NSString alloc] initWithData:pre encoding:NSUTF8StringEncoding];
            if (!head) head = [pre description];
        }
        id resp = task.response;
        if ([resp isKindOfClass:[NSHTTPURLResponse class]]) sc = ((NSHTTPURLResponse *)resp).statusCode;
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        @synchronized (dy4kMonNames) {
            dy4kDlErr = [NSString stringWithFormat:@"HTTP%ld body=%@", sc, head];
        }
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{ [self tryNext]; }];
        return;
    }
    if (self.onDone) self.onDone(YES, tmp, nil);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        NSString *u = task.currentRequest.URL.absoluteString ?: @"";
        NSString *tail = [u length] > 40 ? [u substringFromIndex:[u length] - 40] : u;
        @synchronized (dy4kMonNames) {
            dy4kDlErr = [NSString stringWithFormat:@"NET-ERR(%ld):%@ |…%@", (long)error.code, error.localizedDescription ?: @"?", tail];
        }
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

// v1.7: 安全KVC — 先探测getter是否真实存在, 避免全树KVC异常风暴卡死主线程
static id DY4KTryKVC(id obj, NSString *key) {
    if (!obj || ![obj respondsToSelector:@selector(valueForKey:)]) return nil;
    if (!class_getInstanceMethod(object_getClass(obj), NSSelectorFromString(key))) return nil;
    return [obj valueForKey:key];
}

// v1.7: 抖音APP自己的topVC(跳过悬浮球window) — 之前挖aid从悬浮球自身VC树出发, 永远挖不到
static UIViewController *DY4KAppTopVC(void) {
    UIViewController *top = nil;
    NSArray<UIScene *> *scenes = [[UIApplication sharedApplication] connectedScenes].allObjects;
    for (UIScene *sc in scenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        for (NSInteger i = (NSInteger)ws.windows.count - 1; i >= 0; i--) {
            UIWindow *w = ws.windows[(NSUInteger)i];
            if (w.isHidden) continue;
            if ([w isKindOfClass:NSClassFromString(@"DY4KBallWindow")]) continue;
            if (w.rootViewController) { top = w.rootViewController; break; }
        }
        if (top) break;
    }
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

// v1.4: 从当前播放页VC树挖当前视频 aweme_id (AWEPlayInteractionViewController.model.itemID)
// v2.2: 从单个对象(播放器self等)挖当前aweme的aid+文案+作者
static NSString *DY4KDigAidFromHolder(id holder, NSString **outDesc, NSString **outAuthor) {
    if (!holder) return nil;
    for (NSString *mk in @[@"model", @"awemeModel", @"currentAwemeModel", @"awemeDetailModel", @"itemModel", @"currentItem"]) {
        @try {
            id m = DY4KTryKVC(holder, mk);
            if (!m || [m isKindOfClass:[NSNull class]] || [m isKindOfClass:[UIViewController class]] || [m isKindOfClass:[UIView class]]) continue;
            id aid = DY4KTryKVC(m, @"itemID");
            if (![aid isKindOfClass:[NSString class]] || [(NSString *)aid length] < 10) continue;
            if (outDesc) {
                id d = DY4KTryKVC(m, @"descriptionString");
                if (![d isKindOfClass:[NSString class]] || [(NSString *)d length] == 0) d = DY4KTryKVC(m, @"itemTitle");
                *outDesc = [d isKindOfClass:[NSString class]] ? d : nil;
            }
            if (outAuthor) {
                id au0 = DY4KTryKVC(m, @"author");
                id au = (au0 && ![au0 isKindOfClass:[NSString class]]) ? DY4KTryKVC(au0, @"nickname") : au0;
                *outAuthor = [au isKindOfClass:[NSString class]] ? au : nil;
            }
            return aid;
        } @catch (NSException *e) {}
    }
    return nil;
}

static NSString *DY4KDigCurrentAid(NSString **outDesc, NSString **outAuthor, BOOL quiet) {
    UIViewController *top = DY4KAppTopVC();
    if (!top) {
        if (!quiet) { @synchronized (dy4kMonNames) { dy4kLastErr = @"无TopVC"; } }
        return nil;
    }
    // v2.8: 两轮BFS——第一轮只挖可见VC(isViewLoaded且view.window!=nil, 预加载页不在window层级被排除), 第二轮不过滤兜底
    for (int dgRound = 0; dgRound < 2; dgRound++) {
    NSMutableArray<UIViewController *> *queue = [NSMutableArray arrayWithObject:top];
    int steps = 0;
    while (queue.count > 0 && steps < 64) {
        steps++;
        UIViewController *vc = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (!vc) continue;
        if (dgRound == 0 && !(vc.isViewLoaded && vc.view.window != nil)) continue; // v2.8: 不可见页跳过(预加载页)
        // v1.5: 不筛类名(新版抖音类名可能变), 对每个VC无差别尝试KVC挖model
        for (NSString *mk in @[@"model", @"awemeModel", @"currentAwemeModel", @"awemeDetailModel"]) {
            @try {
                id m = DY4KTryKVC(vc, mk);
                if (!m || [m isKindOfClass:[NSNull class]] || [m isKindOfClass:[UIViewController class]] || [m isKindOfClass:[UIView class]]) continue;
                id aid = DY4KTryKVC(m, @"itemID");
                if (![aid isKindOfClass:[NSString class]] || [(NSString *)aid length] < 10) continue;
                dy4kDigHit++;
                if (outDesc) {
                    id d = DY4KTryKVC(m, @"descriptionString");
                    if (![d isKindOfClass:[NSString class]] || [(NSString *)d length] == 0) d = DY4KTryKVC(m, @"itemTitle");
                    *outDesc = [d isKindOfClass:[NSString class]] ? d : nil;
                }
                if (outAuthor) {
                    id au0 = DY4KTryKVC(m, @"author");
                    id au = (au0 && ![au0 isKindOfClass:[NSString class]]) ? DY4KTryKVC(au0, @"nickname") : au0;
                    *outAuthor = [au isKindOfClass:[NSString class]] ? au : nil;
                }
                return aid;
            } @catch (NSException *e) {}
        }
        [queue addObjectsFromArray:vc.childViewControllers];
        if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
    }
    } // v2.8: 两轮BFS结束
    if (!quiet) { @synchronized (dy4kMonNames) { dy4kLastErr = @"未找到播放页VC"; } }
    return nil;
}

// v1.8: body前120字节预览(可打印显示文本, 否则hex) — 看清风控页真容
static NSString *DY4KBodyPreview(NSData *d) {
    if (!d.length) return @"empty";
    NSUInteger n = d.length < 120 ? d.length : 120;
    const uint8_t *b = (const uint8_t *)d.bytes;
    NSUInteger printable = 0;
    for (NSUInteger i = 0; i < n; i++) if (b[i] >= 0x20 && b[i] <= 0x7e) printable++;
    if (printable * 10 >= n * 9) {
        NSString *t = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, n)] encoding:NSASCIIStringEncoding];
        return t ? [t stringByReplacingOccurrencesOfString:@"\n" withString:@" "] : @"?";
    }
    NSMutableString *h = [NSMutableString string];
    NSUInteger hn = n < 32 ? n : 32;
    for (NSUInteger i = 0; i < hn; i++) [h appendFormat:@"%02x", b[i]];
    return h;
}

// v1.8: 记录系统会话请求path样本(确认feed是否走NSURLSession)
static void DY4KRecordURLPath(NSString *u) {
    if (dy4kURLPaths == nil || u.length == 0) return;
    NSString *p = [NSURL URLWithString:u].path;
    if (p.length == 0) return;
    @synchronized (dy4kURLPaths) {
        if (dy4kURLPaths.count < 12 && ![dy4kURLPaths containsObject:p]) [dy4kURLPaths addObject:p];
    }
}

// ===== v2.7: 对齐DYYY 2.2-33 接口4三级链(Step2首发→自愈→feed兜底) =====

static void DY4KBuildVideo(NSString *aid, NSDictionary *item, void (^done)(BOOL ok));

// v2.7: 预热 GET www.douyin.com 刷新web Cookie(__ac_nonce等)
static void DY4KWarmupWeb(void) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.douyin.com/"]];
    req.timeoutInterval = 5;
    [req setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(__unused NSData *d, __unused NSURLResponse *r, __unused NSError *e) {
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC));
}

// v2.7: ttwid注册(ttwid.bytedance.com union接口), Set-Cookie头与JSON body双路提取
static NSString *DY4KRegisterTtwid(void) {
    __block NSString *ttwid = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://ttwid.bytedance.com/ttwid/union/register/"]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [@ "{\"region\":\"cn\",\"aid\":6383,\"needFid\":false,\"service\":\"www.douyin.com\",\"migrate_info\":{\"ticket\":\"\",\"source\":\"node\"},\"cbUrlProtocol\":\"https\",\"union\":true}" dataUsingEncoding:NSUTF8StringEncoding];
    req.timeoutInterval = 8;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, __unused NSError *e) {
        @try {
            NSHTTPURLResponse *hr = [r isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)r : nil;
            NSString *sc = [hr allHeaderFields][@"Set-Cookie"];
            if (sc.length > 0) {
                NSRange rng = [sc rangeOfString:@"ttwid="];
                if (rng.location != NSNotFound) {
                    NSString *sub = [sc substringFromIndex:rng.location + 6];
                    NSRange semi = [sub rangeOfString:@";"];
                    ttwid = semi.location != NSNotFound ? [sub substringToIndex:semi.location] : sub;
                }
            }
            if (ttwid.length == 0 && d.length > 0) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                if ([json isKindOfClass:[NSDictionary class]]) ttwid = json[@"ttwid"];
            }
        } @catch (__unused NSException *ex) {}
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 9 * NSEC_PER_SEC));
    return ttwid;
}

// v2.7: 构建Web detail请求(完整参数+浏览器指纹头, 对齐DYYY 2.2-33 Step2)
static NSMutableURLRequest *DY4KWebDetailReq(NSString *aid, NSString *cookie) {
    NSString *ua = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36";
    NSString *api = [NSString stringWithFormat:@"https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=%@&device_platform=webapp&aid=6383&channel=channel_pc_web&update_version_code=170400&pc_client_type=1&version_code=190500&version_name=19.5.0&cookie_enabled=true&screen_width=2560&screen_height=1440&browser_language=zh-CN&browser_platform=Win32&browser_name=Chrome&browser_version=150.0.0.0&browser_online=true&engine_name=Blink&engine_version=150.0.0.0&os_name=Windows&os_version=10&cpu_core_num=12&device_memory=8&platform=PC&downlink=4.75&effective_type=4g&round_trip_time=150", aid];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:api]];
    req.timeoutInterval = 12;
    [req setValue:ua forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
    [req setValue:@"text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7" forHTTPHeaderField:@"Accept"];
    [req setValue:@"zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6" forHTTPHeaderField:@"Accept-Language"];
    [req setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [req setValue:@"no-cache" forHTTPHeaderField:@"Pragma"];
    [req setValue:@"\"Chromium\";v=\"150\", \"Google Chrome\";v=\"150\"" forHTTPHeaderField:@"sec-ch-ua"];
    [req setValue:@"?0" forHTTPHeaderField:@"sec-ch-ua-mobile"];
    [req setValue:@"\"Windows\"" forHTTPHeaderField:@"sec-ch-ua-platform"];
    [req setValue:@"document" forHTTPHeaderField:@"sec-fetch-dest"];
    [req setValue:@"navigate" forHTTPHeaderField:@"sec-fetch-mode"];
    [req setValue:@"same-origin" forHTTPHeaderField:@"sec-fetch-site"];
    [req setValue:@"?1" forHTTPHeaderField:@"sec-fetch-user"];
    [req setValue:@"1" forHTTPHeaderField:@"upgrade-insecure-requests"];
    if (cookie.length > 0) [req setValue:cookie forHTTPHeaderField:@"Cookie"];
    return req;
}

// v2.7: Step2执行+解析(首发与自愈共用), 命中调BuildVideo入库
static void DY4KFireWebDetail(NSString *aid, NSString *cookie, NSString *tag, void (^done)(BOOL ok)) {
    NSMutableURLRequest *req = DY4KWebDetailReq(aid, cookie);
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        @try {
            if (e) {
                @synchronized (dy4kMonNames) { dy4kLastErr = [NSString stringWithFormat:@"%@网络: %@", tag, e.localizedDescription]; }
            } else if (d.length > 0) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                if ([json isKindOfClass:[NSDictionary class]] && [json[@"status_code"] integerValue] == 0 && [json[@"aweme_detail"] isKindOfClass:[NSDictionary class]]) {
                    DY4KBuildVideo(aid, json[@"aweme_detail"], done);
                    return;
                }
                long sc = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 0;
                @synchronized (dy4kMonNames) { dy4kLastErr = [NSString stringWithFormat:@"%@ HTTP%ld status_code=%ld", tag, sc, [json isKindOfClass:[NSDictionary class]] ? [json[@"status_code"] integerValue] : -1]; }
            } else {
                @synchronized (dy4kMonNames) { dy4kLastErr = [NSString stringWithFormat:@"%@空响应", tag]; }
            }
        } @catch (NSException *ex) {
            @synchronized (dy4kMonNames) { dy4kLastErr = [NSString stringWithFormat:@"%@异常: %@", tag, ex.reason]; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(NO); });
    }] resume];
}

// v2.7: Step2 Web detail首发: 预热→白名单Cookie(__ac_nonce+ttwid, 旧指纹会被Argus判Uifid Not Found)→无ttwid注册→重打
static void DY4KFetchViaWeb(NSString *aid, void (^done)(BOOL ok)) {
    if (aid.length < 10) { if (done) done(NO); return; }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        DY4KWarmupWeb();
        NSURL *webURL = [NSURL URLWithString:@"https://www.douyin.com/"];
        NSHTTPCookieStorage *store = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        NSMutableString *cookie = [NSMutableString string];
        __block NSString *ttwid = nil;
        for (NSHTTPCookie *c in [store cookiesForURL:webURL]) {
            if ([c.name isEqualToString:@"__ac_nonce"] || [c.name isEqualToString:@"ttwid"]) {
                if (cookie.length > 0) [cookie appendString:@"; "];
                [cookie appendFormat:@"%@=%@", c.name, c.value];
            }
            if ([c.name isEqualToString:@"ttwid"]) ttwid = c.value;
        }
        if (ttwid.length == 0) {
            ttwid = DY4KRegisterTtwid();
            if (ttwid.length > 0) {
                if (cookie.length > 0) [cookie appendString:@"; "];
                [cookie appendFormat:@"ttwid=%@", ttwid];
                NSHTTPCookie *ntw = [NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName: @"ttwid", NSHTTPCookieValue: ttwid, NSHTTPCookieDomain: @".douyin.com", NSHTTPCookiePath: @"/"}];
                if (ntw) [store setCookie:ntw];
            }
        }
        if (cookie.length == 0) {
            @synchronized (dy4kMonNames) { dy4kLastErr = @"Step2无Cookie(预热后仍空)"; }
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(NO); });
            return;
        }
        DY4KFireWebDetail(aid, cookie, @"Step2", ^(BOOL ok) {
            if (ok) dy4kWebHit++;
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(ok); });
        });
    });
}

// v2.7: 自愈重打(对齐DYYY 2.2-27冷会话配方, 不带a_bogus签名-实测判死): 清旧指纹→重新预热→全新ttwid→白名单重组装→重打Step2
static void DY4KFetchHeal(NSString *aid, void (^done)(BOOL ok)) {
    if (aid.length < 10) { if (done) done(NO); return; }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURL *webURL = [NSURL URLWithString:@"https://www.douyin.com/"];
        NSHTTPCookieStorage *store = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        for (NSHTTPCookie *hc in [[store cookiesForURL:webURL] copy]) [store deleteCookie:hc];
        DY4KWarmupWeb();
        NSString *ttwid = DY4KRegisterTtwid();
        if (ttwid.length == 0) {
            @synchronized (dy4kMonNames) { dy4kLastErr = @"自愈ttwid注册失败"; }
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(NO); });
            return;
        }
        NSHTTPCookie *ntw = [NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName: @"ttwid", NSHTTPCookieValue: ttwid, NSHTTPCookieDomain: @".douyin.com", NSHTTPCookiePath: @"/"}];
        if (ntw) [store setCookie:ntw];
        NSMutableString *cookie = [NSMutableString string];
        for (NSHTTPCookie *c in [store cookiesForURL:webURL]) {
            if ([c.name isEqualToString:@"__ac_nonce"] && c.value.length > 0) [cookie appendFormat:@"__ac_nonce=%@; ", c.value];
        }
        [cookie appendFormat:@"ttwid=%@", ttwid];
        DY4KFireWebDetail(aid, cookie, @"自愈", ^(BOOL ok) {
            if (ok) dy4kHealHit++;
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(ok); });
        });
    });
}

// v2.7: 统一构建入库(web/heal/feed三层共用): bit_rate全档 + default原画档(对齐DYYY 2.2-33 Step3)
static void DY4KBuildVideo(NSString *aid, NSDictionary *item, void (^done)(BOOL ok)) {
    NSDictionary *video = [item isKindOfClass:[NSDictionary class]] ? item[@"video"] : nil;
    NSArray *br = [video isKindOfClass:[NSDictionary class]] ? video[@"bit_rate"] : nil;
    if (![br isKindOfClass:[NSArray class]] || br.count == 0) {
        @synchronized (dy4kMonNames) { dy4kLastErr = @"响应无bit_rate"; }
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(NO); });
        return;
    }
    NSMutableArray<DY4KGear *> *gears = [NSMutableArray array];
    for (NSDictionary *b in br) {
        DY4KGear *g = DY4KParseGear(b);
        if (g) [gears addObject:g];
    }
    NSDictionary *ppa = [video isKindOfClass:[NSDictionary class]] ? video[@"play_addr"] : nil;
    id puri = [ppa isKindOfClass:[NSDictionary class]] ? ppa[@"uri"] : nil;
    if ([puri isKindOfClass:[NSString class]] && [(NSString *)puri length] > 0) {
        DY4KGear *og = [DY4KGear new];
        og.gearName = @"原画【最高画质】";
        og.urls = @[[NSString stringWithFormat:@"https://www.douyin.com/aweme/v1/play/?video_id=%@&ratio=default&line=1&device_platform=webapp&aid=6383&channel=channel_pc_web", puri]];
        og.width = [ppa[@"width"] longValue];
        og.height = [ppa[@"height"] longValue];
        og.bitrate = 0;
        [gears insertObject:og atIndex:0];
    }
    if (gears.count == 0) {
        @synchronized (dy4kMonNames) { dy4kLastErr = @"档位解析为空"; }
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(NO); });
        return;
    }
    DY4KVideo *v = [DY4KVideo new];
    v.aid = aid;
    v.time = [[NSDate date] timeIntervalSince1970];
    id fd = [item isKindOfClass:[NSDictionary class]] ? item[@"desc"] : nil;
    if ([fd isKindOfClass:[NSString class]]) v.desc = fd;
    id fau = [item isKindOfClass:[NSDictionary class]] ? item[@"author"] : nil;
    id fn = [fau isKindOfClass:[NSDictionary class]] ? fau[@"nickname"] : nil;
    if ([fn isKindOfClass:[NSString class]]) v.author = fn;
    for (DY4KGear *g in gears) [v mergeGear:g];
    @synchronized (dy4kCache) { dy4kCache[aid] = v; }
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(YES); });
}

// v2.5: feed兜底(对齐DYYY 2.2-30 Step2.7) - aweme.snssdk.com v1/feed 游客态免签名, 带App登录态Cookie预期全档
static void DY4KFetchViaFeed(NSString *aid, void (^done)(BOOL ok)) {
    if (aid.length < 10) { if (done) done(NO); return; }
    NSString *fu = [NSString stringWithFormat:@"https://aweme.snssdk.com/aweme/v1/feed/?aweme_id=%@&version_code=26.0.4&app_name=aweme&channel=App%%20Store&device_platform=iphone&device_type=iPhone15,3&os_version=18.0&aid=1128", aid];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:fu]];
    req.timeoutInterval = 8;
    [req setValue:@"Aweme/260400 CFNetwork/1498 Darwin/23.0.0" forHTTPHeaderField:@"User-Agent"];
    NSMutableString *ck = [NSMutableString string];
    for (NSHTTPCookie *c in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies]) {
        if ([c.domain containsString:@"douyin"]) [ck appendFormat:@"%@=%@; ", c.name, c.value];
    }
    if (ck.length > 0) [req setValue:ck forHTTPHeaderField:@"Cookie"];
    NSURLSessionDataTask *tsk = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        BOOL ok = NO;
        @try {
            long scode = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 0;
            if (e) {
                @synchronized (dy4kMonNames) { dy4kLastErr = [NSString stringWithFormat:@"feed网络: %@(%ld)", e.localizedDescription, (long)e.code]; }
            } else if (d.length > 1000 && scode == 200) {
                id json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                // v2.7防串台(对齐DYYY 2.2-32): 逐条校验aweme_id, 游客态降级推荐流时严禁取别人的视频
                id match = nil;
                if ([json isKindOfClass:[NSDictionary class]]) {
                    NSArray *list = json[@"aweme_list"];
                    if ([list isKindOfClass:[NSArray class]]) {
                        for (NSDictionary *fc in list) {
                            if (![fc isKindOfClass:[NSDictionary class]]) continue;
                            NSString *fid = [fc[@"aweme_id"] isKindOfClass:[NSString class]] ? fc[@"aweme_id"] : [NSString stringWithFormat:@"%@", fc[@"aweme_id"] ?: @""];
                            if ([fid isEqualToString:aid]) { match = fc; break; }
                        }
                    }
                    if (!match && [json[@"aweme_detail"] isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *fd1 = json[@"aweme_detail"];
                        NSString *did1 = [fd1[@"aweme_id"] isKindOfClass:[NSString class]] ? fd1[@"aweme_id"] : [NSString stringWithFormat:@"%@", fd1[@"aweme_id"] ?: @""];
                        if ([did1 isEqualToString:aid]) match = fd1;
                    }
                }
                if (match) {
                    DY4KBuildVideo(aid, match, ^(BOOL bok) {
                        if (bok) dy4kFeedHit++;
                        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(bok); });
                    });
                    return;
                } else {
                    @synchronized (dy4kMonNames) { dy4kLastErr = @"feed无匹配ID(疑似推荐流降级)"; }
                }
            } else {
                @synchronized (dy4kMonNames) { dy4kLastErr = [NSString stringWithFormat:@"feed HTTP%ld body=%lu", scode, (unsigned long)d.length]; }
            }
        } @catch (NSException *ex) {
            @synchronized (dy4kMonNames) { dy4kLastErr = [NSString stringWithFormat:@"feed异常: %@", ex.reason]; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(ok); });
    }];
    [tsk resume];
}

// v2.7: 对齐DYYY 2.2-33三级链: Step2 Web detail首发(保4K) → 自愈重打(冷会话配方) → feed兜底(保返回) → 全灭落缓存列表
static void DY4KFetchAll(NSString *aid, void (^done)(BOOL ok, NSString *src)) {
    DY4KFetchViaWeb(aid, ^(BOOL ok1) {
        if (ok1) { if (done) done(YES, @"web"); return; }
        DY4KFetchHeal(aid, ^(BOOL ok2) {
            if (ok2) { if (done) done(YES, @"heal"); return; }
            DY4KFetchViaFeed(aid, ^(BOOL ok3) {
                if (done) done(ok3, ok3 ? @"feed" : nil);
            });
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
    [msg appendFormat:@"\nfeed兜底:%ld", dy4kFeedHit];
    [msg appendFormat:@"\nStep2:%ld 自愈:%ld", dy4kWebHit, dy4kHealHit];
    NSString *lastErr = nil;
    @synchronized (dy4kMonNames) { lastErr = dy4kLastErr; }
    [msg appendFormat:@"\n主动路错误:%@", lastErr ?: @"无"];
    [msg appendFormat:@"\nURL拦截入库:%ld", dy4kURLHit];
    @synchronized (dy4kMonNames) {
        [msg appendFormat:@"\n拉流URL:%ld 反查命中:%ld 映射:%lu", dy4kStreamSeen, dy4kStreamHit, (unsigned long)dy4kUriMap.count];
        [msg appendFormat:@"\n最近拉流aid:%@", dy4kLastStreamAid ?: @"无"];
    }
    NSString *upLst = nil;
    @synchronized (dy4kURLPaths) {
        if (dy4kURLPaths.count > 0) upLst = [dy4kURLPaths componentsJoinedByString:@", "];
    }
    [msg appendFormat:@"\nURL会话样本:%@", upLst ?: @"无"];
    NSString *pthLst = nil;
    NSString *hexLst = nil;
    @synchronized (dy4kMonPaths) {
        if (dy4kMonPaths.count > 0) pthLst = [dy4kMonPaths componentsJoinedByString:@"\n"];
    }
    @synchronized (dy4kMonHex) {
        if (dy4kMonHex.count > 0) hexLst = [dy4kMonHex componentsJoinedByString:@", "];
    }
    [msg appendFormat:@"\nMonitor样本:\n%@", pthLst ?: @"无"];
    [msg appendFormat:@"\nMonitorHex:%@", hexLst ?: @"无"];
    [msg appendFormat:@"\n缓存:%lu条", (unsigned long)dy4kCache.count];
    NSString *names = nil;
    @synchronized (dy4kMonNames) { names = [dy4kMonNames componentsJoinedByString:@", "]; }
    [msg appendFormat:@"\n相关通知:%@", names.length ? names : @"无"];
    NSString *clsLst = nil;
    NSString *ntmLst = nil;
    @synchronized (dy4kFoundCls) {
        if (dy4kFoundCls.count > 0) {
            NSArray *part = [dy4kFoundCls subarrayWithRange:NSMakeRange(0, MIN((unsigned long)10, dy4kFoundCls.count))];
            clsLst = [part componentsJoinedByString:@", "];
        }
    }
    @synchronized (dy4kNTMMethods) {
        if (dy4kNTMMethods.count > 0) {
            NSArray *part = [dy4kNTMMethods subarrayWithRange:NSMakeRange(0, MIN((unsigned long)24, dy4kNTMMethods.count))];
            ntmLst = [part componentsJoinedByString:@", "];
        }
    }
    [msg appendFormat:@"\n发现类(%lu):%@", (unsigned long)dy4kFoundCls.count, clsLst ?: @"无"];
    [msg appendFormat:@"\nNTM方法:%@", ntmLst ?: @"未枚举"];
    [msg appendFormat:@"\n广撒网hook:%ld", dy4kWideHooked];
    DY4KAlert(msg, nil);
}

static void DY4KSaveAndReport(NSString *path) {
    // v1.9: 先显式申请"添加照片"权限, 被拒时给出明确指引
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus st) {
        if (st != PHAuthorizationStatusAuthorized && st != PHAuthorizationStatusLimited) {
            dispatch_async(dispatch_get_main_queue(), ^{
                DY4KAlert(@"保存失败: 相册权限被拒\n请在 iOS 设置-抖音-照片-添加照片 打开", nil);
            });
            return;
        }
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
    }];
}

static void DY4KDownloadGear(DY4KGear *g) {
    UIViewController *top = DY4KTopVC();
    if (!top) return;
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:@"DY4K 下载中" message:@"0%" preferredStyle:UIAlertControllerStyleAlert];
    [busy addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    // v1.9: 从画质sheet的handler同步present会被sheet的dismiss动画阻塞而静默失败, 延迟等sheet关完
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *t2 = DY4KTopVC();
        if (t2) [t2 presentViewController:busy animated:YES completion:nil];
    });
    DY4KDownloader *dl = [DY4KDownloader new];
    [dl start:g.urls onProgress:^(double frac) {
        dispatch_async(dispatch_get_main_queue(), ^{
            busy.message = [NSString stringWithFormat:@"%.0f%%", frac * 100];
        });
    } onDone:^(BOOL ok, NSString *savedPath, NSString *errMsg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // v1.9: busy可能未成功present(历史版本竞态), 按实际状态分支, 保证结果提示必达
            void (^finish)(void) = ^{
                if (ok) {
                    DY4KSaveAndReport(savedPath);
                } else {
                    NSString *dlErr = nil;
                    @synchronized (dy4kMonNames) { dlErr = dy4kDlErr; }
                    DY4KAlert([NSString stringWithFormat:@"下载失败: %@\n%@\n档位: %@ %ldx%ld", errMsg, dlErr ?: @"", g.gearName, g.width, g.height], nil);
                }
            };
            if (busy.presentingViewController) {
                [busy dismissViewControllerAnimated:NO completion:finish];
            } else {
                finish();
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
        NSString *tag = @"[标清] ";
        NSString *gnL = [g.gearName lowercaseString];
        if ([gnL containsString:@"4k"] || [gnL containsString:@"2160"]) tag = @"[4K] ";
        else if ([gnL containsString:@"1080"]) tag = @"[1080p] ";
        else if ([gnL containsString:@"720"]) tag = @"[720p] ";
        else if ([gnL containsString:@"原画"]) tag = @"[原画] ";
        else if ([gnL containsString:@"540"]) tag = @"[540p] ";
        else {
            long maxEdge = g.width > g.height ? g.width : g.height;
            if (maxEdge >= 2100) tag = @"[4K] ";
            else if (maxEdge >= 1400) tag = @"[2K] ";
            else if (maxEdge >= 1060) tag = @"[1080p] ";
            else if (maxEdge >= 700) tag = @"[720p] ";
        }
        NSString *t = (g.width > 0 && g.bitrate > 0) ? [NSString stringWithFormat:@"%@%@ %ldx%ld · %.1fMbps", tag, g.gearName, g.width, g.height, (double)g.bitrate / 1000000.0] : [NSString stringWithFormat:@"%@%@", tag, g.gearName];
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
        NSMutableString *dg = [NSMutableString string];
        [dg appendString:@"DY4K v1.5 已运行\n"];
        [dg appendFormat:@"通知:%ld Monitor:%ld 大响应:%ld\n", dy4kNotifCount, dy4kMonitorHit, dy4kBigHit];
        [dg appendFormat:@"挖aid:%ld Step2:%ld 自愈:%ld feed:%ld swizzle:%d\n", dy4kDigHit, dy4kWebHit, dy4kHealHit, dy4kFeedHit, dy4kSwizzled];
        NSString *err = nil;
        @synchronized (dy4kMonNames) { err = dy4kLastErr; }
        if (err.length > 0) [dg appendFormat:@"错误:%@\n", err];
        [dg appendString:@"先播放一个视频再点悬浮球"];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:dg preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"详细诊断" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            DY4KShowDiag();
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *t0 = DY4KTopVC();
        if (t0) [t0 presentViewController:ac animated:YES completion:nil];
        return;
    }
    if (recent.count == 1) {
        DY4KVideo *v0 = recent.firstObject;
        if (![v0.desc hasPrefix:@"["]) v0.desc = [NSString stringWithFormat:@"[缓存] %@", (v0.desc.length > 0 ? v0.desc : @"无文案")];
        DY4KShowQuality(v0);
        return;
    }
    UIViewController *top = DY4KTopVC();
    if (!top) return;
    UIAlertController *pick = [UIAlertController alertControllerWithTitle:@"选择视频" message:@"按最近截获排序" preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger n = recent.count > 6 ? 6 : recent.count;
    for (NSUInteger i = 0; i < n; i++) {
        DY4KVideo *v = recent[i];
        [pick addAction:[UIAlertAction actionWithTitle:v.displayTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            if (![v.desc hasPrefix:@"["]) v.desc = [NSString stringWithFormat:@"[缓存] %@", (v.desc.length > 0 ? v.desc : @"无文案")];
            DY4KShowQuality(v);
        }]];
    }
    [pick addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:pick animated:YES completion:nil];
}

// v1.4 入口: 先挖当前播放视频主动拉全档, 失败退回截获缓存
static void DY4KShowMenu(void) {
    NSString *dgDesc = nil, *dgAuthor = nil;
    NSString *srcTag = nil; // v2.4: 识别路径标记
    NSString *aid = nil;
    // v2.8修复"下载成其他视频": ①码率回调最优先(setBitrateModels只有真实在播才触发, 预加载页不会回调; 窗口60→150秒覆盖暂停看评论)
    NSString *pa = nil, *pd = nil, *pau = nil;
    double pt = 0;
    @synchronized (dy4kMonNames) { pa = dy4kPlayingAid; pd = dy4kPlayingDesc; pau = dy4kPlayingAuthor; pt = dy4kPlayingTime; }
    if (pa.length >= 10 && ![pa hasPrefix:@"__"] && [[NSDate date] timeIntervalSince1970] - pt < 150) {
        aid = pa;
        dgDesc = pd;
        dgAuthor = pau;
        srcTag = @"码率";
    }
    // v2.8: ②可见VC挖当前model(DY4KDigCurrentAid两轮BFS: 第一轮只挖可见页, 预加载页view.window为nil被排除)
    if (aid.length == 0) {
        aid = DY4KDigCurrentAid(&dgDesc, &dgAuthor, NO);
        if (aid.length > 0) srcTag = @"界面";
    }
    // v2.8: ③拉流降为兜底(根因: 预加载下个视频也拉流且时间戳反超当前视频, v2.3把拉流放最优先导致"下载成其他视频")
    if (aid.length == 0) {
        NSString *sa = nil;
        double st = 0;
        @synchronized (dy4kMonNames) { sa = dy4kLastStreamAid; st = dy4kLastStreamTime; }
        if (sa.length >= 10 && [[NSDate date] timeIntervalSince1970] - st < 300) {
            aid = sa;
            srcTag = @"拉流";
            @synchronized (dy4kCache) {
                DY4KVideo *sv = dy4kCache[sa];
                if (sv) { dgDesc = sv.desc; dgAuthor = sv.author; }
            }
        }
    }
    // v2.4: 全链(拉流/码率/BFS)都没识别到 → 不再静默赌最近缓存, 让用户从缓存列表自己挑
    if (aid.length == 0) {
        DY4KShowMenuLegacy();
        return;
    }
    if (aid.length > 0) {
        UIViewController *top = DY4KTopVC();
        if (!top) return;
        __block BOOL cancelled = NO;
        UIAlertController *busy = [UIAlertController alertControllerWithTitle:@"DY4K 拉取全档画质中…" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [busy addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) {
            cancelled = YES;
        }]];
        [top presentViewController:busy animated:YES completion:nil];
        DY4KFetchAll(aid, ^(BOOL ok, NSString *src) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (cancelled) return;
                // v1.7: dismiss完成后才present, 避免presentation冲突导致弹窗失效
                [busy dismissViewControllerAnimated:NO completion:^{
                    DY4KVideo *v = nil;
                    @synchronized (dy4kCache) { v = dy4kCache[aid]; }
                    if (ok && v && v.gears.count > 0) {
                        if (dgDesc.length > 0) v.desc = dgDesc;
                        if (dgAuthor.length > 0) v.author = dgAuthor;
                        if (![v.desc hasPrefix:@"["]) {
                            NSString *srcN = src ?: @"feed";
                            NSString *pre = srcTag ? [NSString stringWithFormat:@"%@·%@", srcTag, srcN] : [NSString stringWithFormat:@"[%@]", srcN];
                            v.desc = [NSString stringWithFormat:@"%@ %@", pre, (v.desc.length > 0 ? v.desc : @"无文案")];
                        }
                        DY4KShowQuality(v);
                        return;
                    }
                    NSString *err = nil;
                    @synchronized (dy4kMonNames) { err = dy4kLastErr; }
                    UIAlertController *info = [UIAlertController alertControllerWithTitle:nil message:[NSString stringWithFormat:@"解析未拿到档位(%@)\n\n可看已截获的缓存数据", err ?: @"超时"] preferredStyle:UIAlertControllerStyleAlert];
                    [info addAction:[UIAlertAction actionWithTitle:@"看缓存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                        DY4KShowMenuLegacy();
                    }]];
                    [info addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                    UIViewController *t2 = DY4KTopVC();
                    if (t2) [t2 presentViewController:info animated:YES completion:nil];
                }];
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
    // v1.7: 历史存档位置钳制回屏内, 防按钮跑出屏幕点不到
    if (x > scr0.width - 48) x = scr0.width - 48;
    if (y > scr0.height - 140) y = scr0.height - 140;
    if (x < 0) x = 0;
    if (y < 80) y = 80;
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
        _btn.frame = f;
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

// v1.5 广撒网统一IMP: 先截获, 再沿继承链找原实现调用
static void dy4kWideHookIMP(id self, SEL _cmd, id models) {
    DY4KOnBitrateModels(self, models);
    IMP old = NULL;
    @synchronized (dy4kOldImps) {
        Class c = object_getClass(self);
        while (c) {
            NSString *k = [NSStringFromClass(c) stringByAppendingString:NSStringFromSelector(_cmd)];
            NSValue *v = dy4kOldImps[k];
            if (v) { old = (IMP)[v pointerValue]; break; }
            c = [c superclass];
        }
    }
    if (old) ((void (*)(id, SEL, id))old)(self, _cmd, models);
}

// v1.5: 运行时全量扫描真实类名(新版抖音类名可能全变, 不再赌精确名)
static void DY4KScanClasses(void) {
    @synchronized (dy4kFoundCls) { [dy4kFoundCls removeAllObjects]; }
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;
    NSArray *keys = @[@"PlayInteraction", @"AwemeDetail", @"BitrateModel", @"BitRateModel", @"DPlayer", @"NetworkManager"];
    NSMutableArray *found = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        for (NSString *k in keys) {
            if ([name containsString:k]) {
                if (found.count < 40) [found addObject:name];
                break;
            }
        }
    }
    free(classes);
    @synchronized (dy4kFoundCls) { [dy4kFoundCls addObjectsFromArray:found]; }
}

// v1.5: 对发现的 *BitrateModel* 类, hook 其全部 set*Bitrate* 方法
static void DY4KSwizzleWide(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;
    long hooked = 0;
    NSMutableArray *hitNames = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (![name containsString:@"BitrateModel"] && ![name containsString:@"BitRateModel"] && ![name containsString:@"bitrateModel"]) continue;
        unsigned int mc = 0;
        Method *methods = class_copyMethodList(classes[i], &mc);
        for (unsigned int j = 0; j < mc; j++) {
            NSString *sn = NSStringFromSelector(method_getName(methods[j]));
            if (![sn hasPrefix:@"set"] || sn.length < 8) continue;
            if (![sn containsString:@"Bitrate"] && ![sn containsString:@"Bit_rate"] && ![sn containsString:@"BitRate"]) continue;
            NSString *k = [name stringByAppendingString:sn];
            @synchronized (dy4kOldImps) {
                if (dy4kOldImps[k]) continue;
                IMP old = method_getImplementation(methods[j]);
                method_setImplementation(methods[j], (IMP)dy4kWideHookIMP);
                dy4kOldImps[k] = [NSValue valueWithPointer:old];
            }
            if (hitNames.count < 8) [hitNames addObject:[NSString stringWithFormat:@"%@ %@", name, sn]];
            hooked++;
        }
        if (methods) free(methods);
    }
    free(classes);
    dy4kWideHooked = hooked;
    if (hitNames.count > 0) {
        @synchronized (dy4kMonNames) {
            for (NSString *hn in hitNames) {
                if (dy4kMonNames.count < 12) [dy4kMonNames addObject:[@"SW:" stringByAppendingString:hn]];
            }
        }
    }
}

// v1.5: 枚举 TTNetworkManager 真实方法名(诊断 GET selector 不匹配问题)
static void DY4KProbeNTM(void) {
    Class ntm = NSClassFromString(@"TTNetworkManager");
    if (!ntm) {
        @synchronized (dy4kMonNames) { dy4kLastErr = @"TTNetworkManager类不存在"; }
        return;
    }
    NSMutableArray *names = [NSMutableArray array];
    unsigned int mc = 0;
    Method *methods = class_copyMethodList(object_getClass(ntm), &mc); // 类方法
    for (unsigned int j = 0; j < mc; j++) {
        NSString *sn = NSStringFromSelector(method_getName(methods[j]));
        if ([sn hasPrefix:@"shared"] && names.count < 4) [names addObject:[@"+ " stringByAppendingString:sn]];
    }
    if (methods) free(methods);
    methods = class_copyMethodList(ntm, &mc); // 实例方法
    for (unsigned int j = 0; j < mc; j++) {
        NSString *sn = NSStringFromSelector(method_getName(methods[j]));
        if (([sn hasPrefix:@"GET"] || [sn hasPrefix:@"get"] || [sn hasPrefix:@"request"] || [sn hasPrefix:@"POST"]) && names.count < 14) [names addObject:sn];
    }
    if (methods) free(methods);
    @synchronized (dy4kNTMMethods) { [dy4kNTMMethods addObjectsFromArray:names]; }
}

// v1.8: 探测TTNet响应filter链(getResponseMutableDataFilterObjects=解压后明文, 下一步注册filter的路标)
static void DY4KProbeFilters(void) {
    Class ntm = NSClassFromString(@"TTNetworkManager");
    if (!ntm) return;
    id mgr = nil;
    SEL s1 = NSSelectorFromString(@"sharedManager");
    SEL s2 = NSSelectorFromString(@"sharedInstance");
    if ([ntm respondsToSelector:s1]) mgr = ((id (*)(id, SEL))objc_msgSend)(ntm, s1);
    else if ([ntm respondsToSelector:s2]) mgr = ((id (*)(id, SEL))objc_msgSend)(ntm, s2);
    if (!mgr) {
        @synchronized (dy4kNTMMethods) { [dy4kNTMMethods addObject:@"FLT:无实例"]; }
        return;
    }
    SEL sf = NSSelectorFromString(@"getResponseMutableDataFilterObjects");
    if (![mgr respondsToSelector:sf]) {
        @synchronized (dy4kNTMMethods) { [dy4kNTMMethods addObject:@"FLT:无方法"]; }
        return;
    }
    @try {
        NSArray *arr = ((NSArray *(*)(id, SEL))objc_msgSend)(mgr, sf);
        NSMutableArray *names = [NSMutableArray array];
        [names addObject:[NSString stringWithFormat:@"FLT:共%lu个", (unsigned long)arr.count]];
        for (id f in arr) {
            if (names.count >= 9) break;
            [names addObject:[@"FLT:" stringByAppendingString:NSStringFromClass([f class])]];
        }
        @synchronized (dy4kNTMMethods) { [dy4kNTMMethods addObjectsFromArray:names]; }
    } @catch (NSException *e) {
        @synchronized (dy4kNTMMethods) { [dy4kNTMMethods addObject:@"FLT:异常"]; }
    }
}

// v1.7: 抖音API域过滤(feed流量在snssdk/amemv/zijieapi等域, 只match douyin会全漏)
static BOOL DY4KIsAPIURL(NSString *u) {
    if (u.length == 0) return NO;
    return [u containsString:@"douyin"] || [u containsString:@"snssdk"] || [u containsString:@"amemv"] || [u containsString:@"zijieapi"] || [u containsString:@"bytedance"] || [u containsString:@"bdxigua"] || [u containsString:@"zjcdn"];
}

// v1.6: hook NSURLSession 响应(Alamofire/系统会话都走这里, 不依赖抖音类名)
@interface NSURLSession (DY4KH)
- (NSURLSessionDataTask *)dy4k_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *resp, NSError *err))handler;
- (NSURLSessionDataTask *)dy4k_dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *data, NSURLResponse *resp, NSError *err))handler;
@end

@implementation NSURLSession (DY4KH)

- (NSURLSessionDataTask *)dy4k_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = handler;
    NSString *u = request.URL.absoluteString;
    @try { if (u.length > 0) DY4KRecordURLPath(u); } @catch (__unused NSException *e9) {}
    if (handler && u.length > 0 && DY4KIsAPIURL(u)) {
        NSString *ourl = [u copy];
        wrapped = ^(NSData *d, NSURLResponse *r, NSError *e) {
            @try {
                if (d.length > 0) DY4KTapResponse(ourl, d);
            } @catch (NSException *ex) {}
            handler(d, r, e);
        };
    }
    return [self dy4k_dataTaskWithRequest:request completionHandler:wrapped];
}

- (NSURLSessionDataTask *)dy4k_dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = handler;
    NSString *u = url.absoluteString;
    @try { if (u.length > 0) DY4KRecordURLPath(u); } @catch (__unused NSException *e9) {}
    if (handler && u.length > 0 && DY4KIsAPIURL(u)) {
        NSString *ourl = [u copy];
        wrapped = ^(NSData *d, NSURLResponse *r, NSError *e) {
            @try {
                if (d.length > 0) DY4KTapResponse(ourl, d);
            } @catch (NSException *ex) {}
            handler(d, r, e);
        };
    }
    return [self dy4k_dataTaskWithURL:url completionHandler:wrapped];
}

@end

%ctor {
    @autoreleasepool {
        dy4kCache = [NSMutableDictionary dictionary];
        dy4kParseQueue = dispatch_queue_create("com.omega.dy4k.parse", DISPATCH_QUEUE_SERIAL);
        dy4kMonNames = [NSMutableArray array];
        dy4kFoundCls = [NSMutableArray array];
        dy4kNTMMethods = [NSMutableArray array];
        dy4kOldImps = [NSMutableDictionary dictionary];
        dy4kMonPaths = [NSMutableArray array];
        dy4kURLPaths = [NSMutableArray array];
        dy4kMonHex = [NSMutableArray array];
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
        // v1.6: swizzle NSURLSession(替换已死的 AWEDPlayerVideoModel 精确hook, 类在新版抖音不存在)
        Method mu0 = class_getInstanceMethod([NSURLSession class], NSSelectorFromString(@"dataTaskWithRequest:completionHandler:"));
        Method mu1 = class_getInstanceMethod([NSURLSession class], NSSelectorFromString(@"dy4k_dataTaskWithRequest:completionHandler:"));
        if (mu0 && mu1) {
            method_exchangeImplementations(mu0, mu1);
            dy4kSwizzled = 2;
        }
        Method mu2 = class_getInstanceMethod([NSURLSession class], NSSelectorFromString(@"dataTaskWithURL:completionHandler:"));
        Method mu3 = class_getInstanceMethod([NSURLSession class], NSSelectorFromString(@"dy4k_dataTaskWithURL:completionHandler:"));
        if (mu2 && mu3) method_exchangeImplementations(mu2, mu3);
        dy4kActiveObs = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[DY4KBall shared] mount];
            });
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[DY4KBall shared] mount];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            DY4KScanClasses();
            DY4KSwizzleWide();
            DY4KProbeNTM();
            DY4KProbeFilters();
        });
    }
}
