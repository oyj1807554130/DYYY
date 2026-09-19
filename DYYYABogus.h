#import <Foundation/Foundation.h>

@interface DYYYABogus : NSObject

// JavaScriptCore 引擎是否加载成功
+ (BOOL)isReady;

// 对 query 串本地计算 a_bogus 签名, 返回 params + "&a_bogus=xxx" 完整串; 失败返回 nil
// body: POST 请求体, GET 请求传 nil; ua: 必须与实际请求使用的 User-Agent 完全一致
+ (NSString *)signedQueryForParams:(NSString *)params body:(NSString *)body ua:(NSString *)ua;

@end
