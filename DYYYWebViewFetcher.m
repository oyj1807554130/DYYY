#import "DYYYWebViewFetcher.h"
#import <WebKit/WebKit.h>
#import "DYYYManager.h"

@interface DYYYWebViewFetcher () <WKScriptMessageHandler, WKNavigationDelegate>
@property (strong) WKWebView *wv;
@property (copy) void (^doneBlock)(NSDictionary *);
@property (copy) NSMutableString *log;
@property (assign) BOOL finished;
@end

static DYYYWebViewFetcher *_dyyyActiveWV = nil;

@implementation DYYYWebViewFetcher

+ (void)fetchDetail:(NSString *)awemeId probeLog:(NSMutableString *)probeLog completion:(void (^)(NSDictionary *))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        DYYYWebViewFetcher *f = [[DYYYWebViewFetcher alloc] init];
        f.log = probeLog;
        f.doneBlock = completion;
        _dyyyActiveWV = f;
        [f start:awemeId];
    });
}

- (void)start:(NSString *)awemeId {
    // documentStart注入: 早于页面所有JS, hook XHR与fetch, 捕获detail响应原文回传ObjC
    NSString *hookJS = @"(function(){"
        "var op=XMLHttpRequest.prototype.open;"
        "XMLHttpRequest.prototype.open=function(m,u){this.__dyyyUrl=String(u);return op.apply(this,arguments);};"
        "var sd=XMLHttpRequest.prototype.send;"
        "XMLHttpRequest.prototype.send=function(){var x=this;"
        "if(x.__dyyyUrl&&x.__dyyyUrl.indexOf('/aweme/v1/web/aweme/detail')!==-1){"
        "x.addEventListener('load',function(){try{window.webkit.messageHandlers.dyyyDetail.postMessage({url:x.__dyyyUrl,body:x.responseText});}catch(e){}});"
        "}"
        "return sd.apply(this,arguments);};"
        "var of=window.fetch;"
        "if(of){window.fetch=function(){var u=(typeof arguments[0]==='string')?arguments[0]:((arguments[0]&&arguments[0].url)||'');"
        "var p=of.apply(this,arguments);"
        "if(u&&u.indexOf('/aweme/v1/web/aweme/detail')!==-1){"
        "p.then(function(r){try{r.clone().text().then(function(t){window.webkit.messageHandlers.dyyyDetail.postMessage({url:String(u),body:t});});}catch(e){}})['catch'](function(){});}"
        "return p;};}"
        "})();";
    [self.log appendString:@"[Step2 WebView] 准备创建WKWebView...\n"];
    [DYYYManager persistProbeLog:self.log];
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:hookJS injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    [ucc addScriptMessageHandler:self name:@"dyyyDetail"];
    cfg.userContentController = ucc;
    self.wv = [[WKWebView alloc] initWithFrame:CGRectMake(-2000, -2000, 1280, 800) configuration:cfg];
    [self.log appendString:@"[Step2 WebView] WKWebView创建成功\n"];
    [DYYYManager persistProbeLog:self.log];
    self.wv.navigationDelegate = self;
    self.wv.customUserAgent = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36";
    // 挂到keyWindow屏幕外位置: 避免离屏节流, 且用户不可见
    @try {
        NSArray *wins = [UIApplication sharedApplication].windows;
        UIWindow *kw = nil;
        for (UIWindow *w in wins) { if (w.isKeyWindow) { kw = w; break; } }
        if (!kw && wins.count > 0) kw = wins.firstObject;
        if (kw) [kw addSubview:self.wv];
    } @catch (NSException *e) {}
    [self.log appendString:@"[Step2 WebView] UA设置完成\n"];
    [DYYYManager persistProbeLog:self.log];
    [self.log appendFormat:@"[Step2 WebView] WKWebView就绪(PC UA) 开始加载页面\n"];
    [DYYYManager persistProbeLog:self.log];
    NSString *pageURL = [NSString stringWithFormat:@"https://www.douyin.com/video/%@", awemeId];
    [self.wv loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:pageURL]]];
    [self.log appendString:@"[Step2 WebView] loadRequest已发出\n"];
    [DYYYManager persistProbeLog:self.log];
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 18 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [ws fireTimeout];
    });
}

- (void)fireTimeout {
    if (self.finished) return;
    self.finished = YES;
    NSURL *cur = self.wv.URL;
    [self.log appendFormat:@"[Step2 WebView] 18秒超时 未拦截到detail响应 当前页面=%@\n", cur.absoluteString ?: @"?"];
    [DYYYManager persistProbeLog:self.log];
    [self finishWith:nil];
}

- (void)finishWith:(NSDictionary *)detail {
    void (^cb)(NSDictionary *) = self.doneBlock;
    self.doneBlock = nil;
    [self teardown];
    if (cb) cb(detail);
}

- (void)teardown {
    @try {
        [self.wv.configuration.userContentController removeScriptMessageHandlerForName:@"dyyyDetail"];
        [self.wv stopLoading];
        [self.wv removeFromSuperview];
    } @catch (NSException *e) {}
    [self.log appendString:@"[Step2 WebView] teardown完成\n"];
    [DYYYManager persistProbeLog:self.log];
    self.wv = nil;
    if (_dyyyActiveWV == self) _dyyyActiveWV = nil;
}

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)msg {
    if (self.finished || ![msg.name isEqualToString:@"dyyyDetail"]) return;
    NSDictionary *pl = msg.body;
    if (![pl isKindOfClass:[NSDictionary class]]) return;
    NSString *bodyStr = pl[@"body"];
    if (bodyStr.length == 0) return;
    NSData *d = [bodyStr dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![j isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *ad = j[@"aweme_detail"];
    if (![ad isKindOfClass:[NSDictionary class]]) {
        [self.log appendFormat:@"[Step2 WebView] detail响应异常 status_code=%@ 继续等待\n", j[@"status_code"] ?: @"?"];
        [DYYYManager persistProbeLog:self.log];
        return;
    }
    self.finished = YES;
    [self.log appendFormat:@"[Step2 WebView] 拦截成功 status_code=%@\n", j[@"status_code"] ?: @"?"];
    [DYYYManager persistProbeLog:self.log];
    [self finishWith:ad];
}

- (void)webView:(WKWebView *)wv didCommitNavigation:(WKNavigation *)navigation {
    [self.log appendFormat:@"[Step2 WebView] 页面提交加载 %@\n", wv.URL.absoluteString ?: @"?"];
    [DYYYManager persistProbeLog:self.log];
}

- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)navigation {
    [self.log appendFormat:@"[Step2 WebView] 页面加载完成 等待页面自身发出detail请求\n"];
    [DYYYManager persistProbeLog:self.log];
}

- (void)webView:(WKWebView *)wv didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (self.finished) return;
    [self.log appendFormat:@"[Step2 WebView] 页面加载失败 %@\n", error.localizedDescription ?: @"?"];
    [DYYYManager persistProbeLog:self.log];
}

@end
