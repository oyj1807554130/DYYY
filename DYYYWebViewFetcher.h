#import <Foundation/Foundation.h>

@interface DYYYWebViewFetcher : NSObject
// 经隐藏WKWebView加载抖音PC版详情页, 拦截页面自身发出的aweme/detail响应(签名/cookie/指纹全真, Argus必放行)
+ (void)fetchDetail:(NSString *)awemeId probeLog:(NSMutableString *)probeLog completion:(void (^)(NSDictionary *awemeDetail))completion;
@end
