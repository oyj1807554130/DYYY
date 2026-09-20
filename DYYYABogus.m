#import "DYYYABogus.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import "abogus_js.h"

static JSContext *_dyyyAbCtx = nil;
static JSValue *_dyyyAbCtor = nil;

@implementation DYYYABogus

+ (void)initialize {
    if (self != [DYYYABogus class]) return;
    NSData *jsData = [NSData dataWithBytes:(const void *)abogus_js length:(NSUInteger)abogus_js_len];
    NSString *src = [[NSString alloc] initWithData:jsData encoding:NSUTF8StringEncoding];
    if (!src) {
        NSLog(@"[DYYYABogus] JS源码解码失败");
        return;
    }
    JSContext *ctx = [[JSContext alloc] init];
    // 垫片: 假 CommonJS 环境 + TextEncoder polyfill(JSContext缺此Web API, 缺失则src执行中断于第117行, module.exports永为空→签名引擎永不就绪)
    [ctx evaluateScript:@"var module={exports:{}};var require={main:null};var console={log:function(){},warn:function(){},error:function(){}};var TextEncoder=function(){this.encode=function(s){var out=[];for(var i=0;i<s.length;i++){var c=s.codePointAt(i);if(c>0xFFFF)i++;if(c<0x80)out.push(c);else if(c<0x800)out.push(0xC0|(c>>6),0x80|(c&63));else if(c<0x10000)out.push(0xE0|(c>>12),0x80|((c>>6)&63),0x80|(c&63));else out.push(0xF0|(c>>18),0x80|((c>>12)&63),0x80|((c>>6)&63),0x80|(c&63));}return new Uint8Array(out);};};"];
    ctx.exceptionHandler = ^(JSContext *c, JSValue *e) {
        NSLog(@"[DYYYABogus] JS异常: %@", [e toString]);
    };
    [ctx evaluateScript:src];
    // FIX: 严格模式下顶层class声明不挂全局, 必须从module.exports显式挂到globalThis, 否则ctx["ABogus"]永远undefined
    [ctx evaluateScript:@"globalThis.ABogus = module.exports.ABogus;"];
    JSValue *ctor = ctx[@"ABogus"];
    if (!ctor || ctor.isUndefined) {
        NSLog(@"[DYYYABogus] 未找到ABogus构造器");
        return;
    }
    _dyyyAbCtx = ctx;
    _dyyyAbCtor = ctor;
    NSLog(@"[DYYYABogus] 引擎就绪 len=%u", abogus_js_len);
}

+ (BOOL)isReady {
    return (_dyyyAbCtx != nil && _dyyyAbCtor != nil);
}

+ (NSString *)signedQueryForParams:(NSString *)params body:(NSString *)body ua:(NSString *)ua {
    if (!_dyyyAbCtx || !_dyyyAbCtor) return nil;
    @synchronized (self) {
        @try {
            // 每次签名新建实例: big_array 会被 transform_bytes 原地改写, 状态跨调用持续变化
            // 只传 (fp, ua): options/rng/timeFn 走默认 -> [0,1,14](兼容GET), 真随机, 系统时钟
            JSValue *inst = [_dyyyAbCtor constructWithArguments:@[ @"", ua ?: @"" ]];
            if (!inst || inst.isUndefined) return nil;
            JSValue *result = [inst invokeMethod:@"generate_abogus" withArguments:@[ params ?: @"", body ?: @"" ]];
            if (!result || result.isUndefined || !result.isArray) return nil;
            return [[result objectAtIndexedSubscript:0] toString];
        } @catch (NSException *e) {
            NSLog(@"[DYYYABogus] 签名异常: %@", e);
            return nil;
        }
    }
}

@end
