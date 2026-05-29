// DYYYStickerSaveFix.xm
// 修复抖音38.x评论区表情包保存功能 - 诊断版
// 只做运行时类扫描，不hook不存在的方法

#import <objc/runtime.h>
#import <string.h>

// ============================================================
// 启动时扫描并打印所有匹配的类名（用于诊断）
// ============================================================
static void dyyy_scanClasses(void) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;
    
    const char *patterns[] = {
        "CommentLongPressPanel",
        "SaveImageElement", 
        "StickerComponent",
        "LongPressPanel",
        "AWELongPressPanel",
        "AWECommentPanel"
    };
    
    for (unsigned int p = 0; p < sizeof(patterns)/sizeof(patterns[0]); p++) {
        const char *pattern = patterns[p];
        NSMutableArray *matches = [NSMutableArray array];
        for (unsigned int i = 0; i < classCount; i++) {
            Class cls = classes[i];
            const char *name = class_getName(cls);
            if (name && strstr(name, pattern)) {
                [matches addObject:[NSString stringWithUTF8String:name]];
            }
        }
        if (matches.count > 0) {
            NSLog(@"[DYYY-Sticker] 扫描到 [%s]: %@", pattern, matches);
        }
    }
    free(classes);
}

static __attribute__((constructor)) void dyyy_sticker_init(void) {
    NSLog(@"[DYYY-Sticker] 表情包保存诊断模块加载");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        dyyy_scanClasses();
    });
}
