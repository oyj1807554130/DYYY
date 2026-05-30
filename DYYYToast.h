#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DYYYToast : UIView

@property(nonatomic, strong) UIView *containerView;
@property(nonatomic, strong) UIView *progressBarBackground;
@property(nonatomic, strong) UIView *progressBar;
@property(nonatomic, copy) void (^cancelBlock)(void);
@property(nonatomic, assign) BOOL isCancelled;
@property(nonatomic, assign) BOOL allowSuccessAnimation;
@property(nonatomic, assign) NSInteger currentIndex;   // 当前第几张
@property(nonatomic, assign) NSInteger totalCount;     // 总共多少张
@property(nonatomic, assign) NSInteger successCount;   // 成功张数
@property(nonatomic, assign) NSInteger failCount;       // 失败张数

- (instancetype)initWithFrame:(CGRect)frame;
- (void)setProgress:(float)progress;
- (void)setOverallProgress:(float)progress;  // 仅更新label文字（批次总体进度）
- (void)setBatchProgress:(float)progress;   // 批量下载时更新总进度（边框动画+文字）
- (void)show;
- (void)dismiss;
- (void)showSuccessAnimation:(void (^)(void))completion;

+ (void)showSuccessToastWithMessage:(NSString *)message;
- (void)showSuccessToastWithMessage:(NSString *)message completion:(void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END
