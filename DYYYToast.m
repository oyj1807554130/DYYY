#import "DYYYToast.h"
#import "DYYYUtils.h"
#import <stdlib.h>

@interface DYYYToast ()

@property(nonatomic, strong) CAShapeLayer *progressLayer;
@property(nonatomic, strong) CAShapeLayer *borderProgressLayer;  // 屏幕边缘全屏进度圈
@property(nonatomic, strong) CAShapeLayer *borderGlowLayer;      // 霓光glow层
@property(nonatomic, strong) CAShapeLayer *flowLightLayer;        // 流动光效层
@property(nonatomic, strong) CADisplayLink *colorTimer;           // 颜色循环定时器
@property(nonatomic, assign) CGFloat rainbowHue;                 // 当前彩虹色相值
@property(nonatomic, strong) UILabel *percentLabel;
@property(nonatomic, assign) CGFloat progress;
@property(nonatomic, strong) UIVisualEffectView *blurEffectView;
@property(nonatomic, strong) UIVisualEffectView *bgGlassView;  // 弹窗后全屏液态玻璃背景
@property(nonatomic, strong) CAShapeLayer *checkmarkLayer;
@property(nonatomic, strong) UIView *progressView;
@property(nonatomic, assign) NSInteger previousIndex;  // 追踪上一次的currentIndex，用于检测是否换图
@property(nonatomic, assign) BOOL isShowingSuccessAnimation;

@end

@implementation DYYYToast

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 设置透明背景
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.isCancelled = NO;
        self.allowSuccessAnimation = NO;
        self.previousIndex = 0;

        BOOL isDarkMode = [DYYYUtils isDarkMode];

        // 弹窗后面全屏液态玻璃背景层
        UIBlurEffect *bgGlassBlur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
        _bgGlassView = [[UIVisualEffectView alloc] initWithEffect:bgGlassBlur];
        _bgGlassView.frame = self.bounds;
        _bgGlassView.alpha = 0.85;
        [self addSubview:_bgGlassView];

        // 液态玻璃渐变湿感高光层
        CAGradientLayer *bgGlassHighlight = [CAGradientLayer layer];
        bgGlassHighlight.frame = self.bounds;
        bgGlassHighlight.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.12].CGColor,
            (id)[UIColor colorWithWhite:0.5 alpha:0.0].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.05].CGColor
        ];
        bgGlassHighlight.locations = @[@0.0, @0.5, @1.0];
        bgGlassHighlight.startPoint = CGPointMake(0, 0);
        bgGlassHighlight.endPoint = CGPointMake(0, 1);
        [_bgGlassView.contentView.layer addSublayer:bgGlassHighlight];

        // 液态玻璃边缘淡白描边
        CALayer *bgGlassBorder = [CALayer layer];
        bgGlassBorder.frame = self.bounds;
        bgGlassBorder.borderWidth = 0.5;
        bgGlassBorder.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
        [_bgGlassView.contentView.layer addSublayer:bgGlassBorder];

        CGFloat containerWidth = 220;
        CGFloat containerHeight = 40;
        _containerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, containerWidth, containerHeight)];
        _containerView.center = CGPointMake(CGRectGetMidX(self.bounds), 130);

        _containerView.backgroundColor = [UIColor clearColor];
        _containerView.layer.cornerRadius = containerHeight / 2;
        _containerView.clipsToBounds = YES;
        _containerView.userInteractionEnabled = YES;

        // 添加毛玻璃效果
        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:isDarkMode ? UIBlurEffectStyleDark : UIBlurEffectStyleLight];
        _blurEffectView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        _blurEffectView.frame = _containerView.bounds;
        _blurEffectView.layer.cornerRadius = containerHeight / 2;
        _blurEffectView.clipsToBounds = YES;
        [_containerView addSubview:_blurEffectView];

        [self addSubview:_containerView];

        _containerView.layer.shadowColor = [UIColor blackColor].CGColor;
        _containerView.layer.shadowOffset = CGSizeMake(0, 2);
        _containerView.layer.shadowRadius = 6;
        _containerView.layer.shadowOpacity = 0.2;

        CGFloat circleSize = 30;
        CGFloat yCenter = containerHeight / 2;
        // 修改为属性而非局部变量
        _progressView = [[UIView alloc] initWithFrame:CGRectMake(10, (containerHeight - circleSize) / 2, circleSize, circleSize)];
        [_containerView addSubview:_progressView];
        CAShapeLayer *backgroundLayer = [CAShapeLayer layer];
        UIBezierPath *circularPath = [UIBezierPath bezierPathWithArcCenter:CGPointMake(circleSize / 2, circleSize / 2)
                                                                    radius:circleSize / 2 - 2  // 稍微减小半径
                                                                startAngle:-M_PI / 2
                                                                  endAngle:3 * M_PI / 2
                                                                 clockwise:YES];
        backgroundLayer.path = circularPath.CGPath;

        UIColor *separatorColor = isDarkMode ? [UIColor colorWithWhite:0.4 alpha:1.0] : [UIColor colorWithWhite:0.85 alpha:1.0];
        backgroundLayer.strokeColor = separatorColor.CGColor;
        backgroundLayer.fillColor = [UIColor clearColor].CGColor;
        backgroundLayer.lineWidth = 2;
        backgroundLayer.lineCap = kCALineCapRound;
        [_progressView.layer addSublayer:backgroundLayer];

        _progressLayer = [CAShapeLayer layer];
        _progressLayer.path = circularPath.CGPath;

        UIColor *progressColor =
            isDarkMode ? [UIColor colorWithRed:48 / 255.0 green:209 / 255.0 blue:151 / 255.0 alpha:1.0] : [UIColor colorWithRed:11 / 255.0 green:195 / 255.0 blue:139 / 255.0 alpha:1.0];
        _progressLayer.strokeColor = progressColor.CGColor;
        _progressLayer.fillColor = [UIColor clearColor].CGColor;
        _progressLayer.lineWidth = 2;
        _progressLayer.lineCap = kCALineCapRound;
        _progressLayer.strokeEnd = 0;
        [_progressView.layer addSublayer:_progressLayer];

        _percentLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, containerWidth, containerHeight)];
        _percentLabel.textAlignment = NSTextAlignmentCenter;
        _percentLabel.textColor = isDarkMode ? [UIColor colorWithWhite:0.9 alpha:1.0] : [UIColor colorWithWhite:0.2 alpha:1.0];
        _percentLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        _percentLabel.adjustsFontSizeToFitWidth = YES;
        _percentLabel.minimumScaleFactor = 0.5;
        _percentLabel.text = @"下载中... 0%";
        _percentLabel.frame = CGRectMake(0, 0, containerWidth, containerHeight);
        _percentLabel.textAlignment = NSTextAlignmentCenter;
        [_containerView addSubview:_percentLabel];

        // 隐藏小环形进度圈，仅保留边缘全屏进度圈
        _progressView.hidden = YES;

        UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [_containerView addGestureRecognizer:tapGesture];

        // 弹窗胶囊边缘霓光glow层（底层的宽模糊光晕，散发荧光效果）
        UIBezierPath *capsulePath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, containerWidth, containerHeight)
                                                             cornerRadius:containerHeight / 2];
        _borderGlowLayer = [CAShapeLayer layer];
        _borderGlowLayer.path = capsulePath.CGPath;
        _borderGlowLayer.strokeColor = progressColor.CGColor;
        _borderGlowLayer.fillColor = [UIColor clearColor].CGColor;
        _borderGlowLayer.lineWidth = 12;
        _borderGlowLayer.lineCap = kCALineCapRound;
        _borderGlowLayer.strokeEnd = 1.0;
        _borderGlowLayer.opacity = 0.25;
        [_containerView.layer addSublayer:_borderGlowLayer];

        // 流动光效层（亮点绕边框跑）
        _flowLightLayer = [CAShapeLayer layer];
        _flowLightLayer.path = capsulePath.CGPath;
        _flowLightLayer.strokeColor = [UIColor whiteColor].CGColor;
        _flowLightLayer.fillColor = [UIColor clearColor].CGColor;
        _flowLightLayer.lineWidth = 3;
        _flowLightLayer.lineCap = kCALineCapRound;
        _flowLightLayer.strokeStart = 0;
        _flowLightLayer.strokeEnd = 0.15;  // 光点占路径的15%
        _flowLightLayer.opacity = 0;
        [_containerView.layer addSublayer:_flowLightLayer];

        // 弹窗胶囊边缘进度圈（围绕_containerView画圈）
        _borderProgressLayer = [CAShapeLayer layer];
        _borderProgressLayer.path = capsulePath.CGPath;
        _borderProgressLayer.strokeColor = progressColor.CGColor;
        _borderProgressLayer.fillColor = [UIColor clearColor].CGColor;
        _borderProgressLayer.lineWidth = 4;
        _borderProgressLayer.lineCap = kCALineCapRound;
        _borderProgressLayer.strokeEnd = 0;
        [_containerView.layer addSublayer:_borderProgressLayer];

        self.alpha = 0;
    }
    return self;
}

- (void)setProgress:(float)progress {
    // 确保在主线程中更新UI
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self setProgress:progress];
        });
        return;
    }

    // 进度值限制在0到1之间
    progress = MAX(0.0, MIN(1.0, progress));
    _progress = progress;

    // 更新屏幕边缘全屏进度圈（进度条不退，只跟随真实进度）
    // 颜色不在此处改变，换图时在setBatchProgress中统一换色
    self.borderProgressLayer.strokeEnd = progress;
    self.borderGlowLayer.strokeEnd = progress;
    self.flowLightLayer.strokeEnd = progress > 0 ? 0.15 : 0;
    if (progress > 0 && self.flowLightLayer.opacity == 0) {
        [self startFlowLight];
        [self stopRainbowColorCycle];
    }
}

// 更新批次总体进度label（环形进度条保持当前单张图进度不变）
- (void)setOverallProgress:(float)progress {
    // 确保在主线程中更新UI
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self setOverallProgress:progress];
        });
        return;
    }

    // 进度值限制在0到1之间
    progress = MAX(0.0, MIN(1.0, progress));

    // 更新进度百分比（总体批次进度）
    int percentage = (int)(progress * 100);

    // 显示格式：正在保存（X/Y）n%，如 "正在保存（1/16）6%"
    if (self.totalCount > 0 && self.currentIndex > 0) {
        int totalPercentage = (int)((CGFloat)self.currentIndex / self.totalCount * 100);
        _percentLabel.text = [NSString stringWithFormat:@"正在保存（%ld/%ld）%d%% 总%d%%", (long)self.currentIndex, (long)self.totalCount, percentage, totalPercentage];
    } else {
        _percentLabel.text = [NSString stringWithFormat:@"正在保存... %d%%", percentage];
    }
}

// 批量下载时更新总进度（同时更新边框动画和文字）
- (void)setBatchProgress:(float)progress {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self setBatchProgress:progress];
        });
        return;
    }

    progress = MAX(0.0, MIN(1.0, progress));
    _progress = progress;

    // 进度条保持填满（strokeEnd=1.0），只换图时换颜色
    self.borderProgressLayer.strokeEnd = 1.0;
    self.borderGlowLayer.strokeEnd = 1.0;
    self.flowLightLayer.strokeEnd = 1.0;
    [self startFlowLight];
    [self stopRainbowColorCycle];  // 停掉彩虹循环

    // 每换一张图换一次随机颜色（检测currentIndex是否增加）
    if (self.currentIndex > self.previousIndex) {
        CGFloat hue1 = arc4random_uniform(256) / 256.0;
        CGFloat hue2 = arc4random_uniform(256) / 256.0;
        UIColor *innerColor = [UIColor colorWithHue:hue1 saturation:0.85 brightness:0.95 alpha:1.0];
        UIColor *outerColor = [UIColor colorWithHue:hue2 saturation:0.85 brightness:0.95 alpha:1.0];
        self.borderProgressLayer.strokeColor = innerColor.CGColor;
        self.borderGlowLayer.strokeColor = [outerColor colorWithAlphaComponent:0.5].CGColor;
        self.flowLightLayer.strokeColor = [UIColor colorWithHue:hue1 saturation:0.6 brightness:1.0 alpha:1.0].CGColor;
        self.previousIndex = self.currentIndex;
    }

    // 更新文字
    int percentage = (int)(progress * 100);
    if (self.totalCount > 0 && self.currentIndex > 0) {
        int totalPercentage = (int)((CGFloat)self.currentIndex / self.totalCount * 100);
        _percentLabel.text = [NSString stringWithFormat:@"正在保存（%ld/%ld）%d%% 总%d%%", (long)self.currentIndex, (long)self.totalCount, percentage, totalPercentage];
    } else {
        _percentLabel.text = [NSString stringWithFormat:@"正在保存... %d%%", percentage];
    }
}

- (void)show {
    UIWindow *window = [DYYYUtils getActiveWindow];
    if (!window) {
        window = UIApplication.sharedApplication.windows.firstObject;
    }
    if (!window) {
        return;
    }

    [window addSubview:self];

    [UIView animateWithDuration:0.3
                     animations:^{
                       self.alpha = 1.0;
                     }];
}

- (void)dismiss {
    void (^dismissBlock)(void) = ^{
      if (self.isCancelled) {
          [self showCancelAnimation:nil];
          return;
      }

      if (self.allowSuccessAnimation) {
          if (!self.isShowingSuccessAnimation) {
              self.isShowingSuccessAnimation = YES;
              [self showSuccessAnimation:nil];
          }
          return;
      }

      [UIView animateWithDuration:0.2
          animations:^{
            self.alpha = 0;
          }
          completion:^(BOOL finished) {
            [self.borderProgressLayer removeFromSuperlayer];
            [self.borderGlowLayer removeFromSuperlayer];
            [self.flowLightLayer removeFromSuperlayer];
            [self.bgGlassView removeFromSuperview];
            [self stopRainbowColorCycle];
            [self removeFromSuperview];
          }];
    };

    if ([NSThread isMainThread]) {
        dismissBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), dismissBlock);
    }
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    self.isCancelled = YES;
    if (self.cancelBlock) {
        self.cancelBlock();
    }
    [self dismiss];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha == 0) {
        return nil;
    }

    CGPoint containerPoint = [self convertPoint:point toView:_containerView];
    if ([_containerView pointInside:containerPoint withEvent:event]) {
        return [super hitTest:point withEvent:event];
    }

    return nil;
}
// 下载成功动画方法
- (void)showSuccessAnimation:(void (^)(void))completion {
    BOOL isDarkMode = [DYYYUtils isDarkMode];

    UIColor *successColor =
        isDarkMode ? [UIColor colorWithRed:48 / 255.0 green:209 / 255.0 blue:151 / 255.0 alpha:1.0] : [UIColor colorWithRed:11 / 255.0 green:195 / 255.0 blue:139 / 255.0 alpha:1.0];

    [UIView animateWithDuration:0.3
        animations:^{
          [self setProgress:1.0];
        }
        completion:^(BOOL finished) {
          CAShapeLayer *circleLayer = [CAShapeLayer layer];
          CGFloat circleSize = 30;
          UIBezierPath *circlePath = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, circleSize, circleSize)];

          circleLayer.path = circlePath.CGPath;
          circleLayer.fillColor = successColor.CGColor;
          circleLayer.opacity = 0;

          [self.progressView.layer addSublayer:circleLayer];

          CAShapeLayer *checkmarkLayer = [CAShapeLayer layer];

          UIBezierPath *checkPath = [UIBezierPath bezierPath];
          [checkPath moveToPoint:CGPointMake(circleSize * 0.25, circleSize * 0.5)];
          [checkPath addLineToPoint:CGPointMake(circleSize * 0.45, circleSize * 0.7)];
          [checkPath addLineToPoint:CGPointMake(circleSize * 0.75, circleSize * 0.3)];

          checkmarkLayer.path = checkPath.CGPath;
          checkmarkLayer.fillColor = nil;
          checkmarkLayer.strokeColor = [UIColor whiteColor].CGColor;
          checkmarkLayer.lineWidth = 2.5;
          checkmarkLayer.lineCap = kCALineCapRound;
          checkmarkLayer.lineJoin = kCALineJoinRound;
          checkmarkLayer.strokeEnd = 0;

          [self.progressView.layer addSublayer:checkmarkLayer];

          [UIView animateWithDuration:0.15
              animations:^{
                self.progressLayer.opacity = 0;
                self.borderProgressLayer.opacity = 0;
                self.borderGlowLayer.opacity = 0;
                self.flowLightLayer.opacity = 0;
                [self stopRainbowColorCycle];

                [UIView transitionWithView:self.percentLabel
                                  duration:0.2
                                   options:UIViewAnimationOptionTransitionCrossDissolve
                                animations:^{
                                  self.percentLabel.text = [NSString stringWithFormat:@"全部保存完成 成功%ld张，失败%ld张", (long)self.successCount, (long)self.failCount];
                                }
                                completion:nil];
              }
              completion:^(BOOL finished) {
                CABasicAnimation *circleAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
                circleAnimation.fromValue = @0.0;
                circleAnimation.toValue = @1.0;
                circleAnimation.duration = 0.1;  // 从0.2改为0.1
                circleLayer.opacity = 1.0;
                [circleLayer addAnimation:circleAnimation forKey:@"fadeIn"];

                __weak __typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                  DYYYToast *toast = weakSelf;
                  if (!toast) {
                      return;
                  }
                  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHapticFeedbackEnabled"]) {
                      UINotificationFeedbackGenerator *feedbackGenerator = [[UINotificationFeedbackGenerator alloc] init];
                      [feedbackGenerator notificationOccurred:UINotificationFeedbackTypeSuccess];
                  }
                  CABasicAnimation *checkmarkAnimation = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
                  checkmarkAnimation.fromValue = @0.0;
                  checkmarkAnimation.toValue = @1.0;
                  checkmarkAnimation.duration = 0.15;  // 从0.3改为0.15
                  checkmarkAnimation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
                  checkmarkLayer.strokeEnd = 1.0;
                  [checkmarkLayer addAnimation:checkmarkAnimation forKey:@"drawCheckmark"];

                  [UIView animateWithDuration:0.15  // 从0.2改为0.15
                      delay:0.1
                      usingSpringWithDamping:0.6
                      initialSpringVelocity:0.8
                      options:UIViewAnimationOptionCurveEaseInOut
                      animations:^{
                        toast.progressView.transform = CGAffineTransformMakeScale(1.15, 1.15);
                      }
                      completion:^(BOOL finished) {
                        [UIView animateWithDuration:0.2
                                         animations:^{
                                           toast.progressView.transform = CGAffineTransformIdentity;
                                         }];
                      }];

                  __weak __typeof(toast) innerWeakToast = toast;
                  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    DYYYToast *innerToast = innerWeakToast;
                    if (!innerToast) {
                        return;
                    }
                    [UIView animateWithDuration:0.2  // 从0.3改为0.2
                        animations:^{
                          innerToast.alpha = 0;
                        }
                        completion:^(BOOL finished) {
                          [innerToast.borderProgressLayer removeFromSuperlayer];
                          [innerToast.borderGlowLayer removeFromSuperlayer];
                          [innerToast removeFromSuperview];
                          if (completion) {
                              completion();
                          }
                        }];
                  });
                });
              }];
        }];
}

// 下载取消动画方法
- (void)showCancelAnimation:(void (^)(void))completion {
    BOOL isDarkMode = [DYYYUtils isDarkMode];

    UIColor *cancelColor = isDarkMode ? [UIColor colorWithRed:52 / 255.0 green:152 / 255.0 blue:219 / 255.0 alpha:1.0] : [UIColor colorWithRed:41 / 255.0 green:128 / 255.0 blue:185 / 255.0 alpha:1.0];

    // 创建圆形背景
    CAShapeLayer *circleLayer = [CAShapeLayer layer];
    CGFloat circleSize = 30;
    UIBezierPath *circlePath = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, circleSize, circleSize)];

    circleLayer.path = circlePath.CGPath;
    circleLayer.fillColor = cancelColor.CGColor;
    circleLayer.opacity = 0;

    [self.progressView.layer addSublayer:circleLayer];

    CAShapeLayer *crossLayer = [CAShapeLayer layer];

    UIBezierPath *crossPath = [UIBezierPath bezierPath];

    [crossPath moveToPoint:CGPointMake(circleSize * 0.7, circleSize * 0.3)];
    [crossPath addLineToPoint:CGPointMake(circleSize * 0.3, circleSize * 0.7)];
    [crossPath moveToPoint:CGPointMake(circleSize * 0.3, circleSize * 0.3)];
    [crossPath addLineToPoint:CGPointMake(circleSize * 0.7, circleSize * 0.7)];

    crossLayer.path = crossPath.CGPath;
    crossLayer.fillColor = nil;
    crossLayer.strokeColor = [UIColor whiteColor].CGColor;
    crossLayer.lineWidth = 2.5;
    crossLayer.lineCap = kCALineCapRound;
    crossLayer.lineJoin = kCALineJoinRound;
    crossLayer.strokeEnd = 0;

    [self.progressView.layer addSublayer:crossLayer];

    [UIView animateWithDuration:0.15
        animations:^{
          self.progressLayer.opacity = 0;
          self.borderProgressLayer.opacity = 0;
          self.borderGlowLayer.opacity = 0;
          self.flowLightLayer.opacity = 0;
          [self stopRainbowColorCycle];

          [UIView transitionWithView:self.percentLabel
                            duration:0.2
                             options:UIViewAnimationOptionTransitionCrossDissolve
                          animations:^{
                            self.percentLabel.text = @"已取消下载";
                          }
                          completion:nil];
        }
        completion:^(BOOL finished) {
          CABasicAnimation *circleAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
          circleAnimation.fromValue = @0.0;
          circleAnimation.toValue = @1.0;
          circleAnimation.duration = 0.1;  // 从0.2改为0.1
          circleLayer.opacity = 1.0;
          [circleLayer addAnimation:circleAnimation forKey:@"fadeIn"];

          __weak __typeof(self) weakSelf = self;
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            DYYYToast *toast = weakSelf;
            if (!toast) {
                return;
            }
            if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHapticFeedbackEnabled"]) {
                UINotificationFeedbackGenerator *feedbackGenerator = [[UINotificationFeedbackGenerator alloc] init];
                [feedbackGenerator notificationOccurred:UINotificationFeedbackTypeError];
            }
            // 绘制叉号
            CABasicAnimation *crossAnimation = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
            crossAnimation.fromValue = @0.0;
            crossAnimation.toValue = @1.0;
            crossAnimation.duration = 0.15;  // 从0.3改为0.15
            crossAnimation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            crossLayer.strokeEnd = 1.0;
            [crossLayer addAnimation:crossAnimation forKey:@"drawCross"];

            [UIView animateWithDuration:0.15  // 从0.2改为0.15
                delay:0.1
                usingSpringWithDamping:0.6
                initialSpringVelocity:0.8
                options:UIViewAnimationOptionCurveEaseInOut
                animations:^{
                  toast.progressView.transform = CGAffineTransformMakeScale(1.15, 1.15);
                }
                completion:^(BOOL finished) {
                  [UIView animateWithDuration:0.2
                                   animations:^{
                                     toast.progressView.transform = CGAffineTransformIdentity;
                                   }];
                }];

            __weak __typeof(toast) innerWeakToast = toast;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
              DYYYToast *innerToast = innerWeakToast;
              if (!innerToast) {
                  return;
              }
              [UIView animateWithDuration:0.2  // 从0.3改为0.2
                  animations:^{
                    innerToast.alpha = 0;
                  }
                  completion:^(BOOL finished) {
                    [innerToast.borderProgressLayer removeFromSuperlayer];
                    [innerToast.borderGlowLayer removeFromSuperlayer];
                    [innerToast removeFromSuperview];
                    if (completion) {
                        completion();
                    }
                  }];
            });
          });
        }];
}

+ (void)showSuccessToastWithMessage:(NSString *)message {
    DYYYToast *toast = [[DYYYToast alloc] initWithFrame:[UIScreen mainScreen].bounds];
    [toast showSuccessToastWithMessage:message completion:nil];
}

- (void)showSuccessToastWithMessage:(NSString *)message completion:(void (^)(void))completion {
    UIWindow *window = [DYYYUtils getActiveWindow];
    if (!window) {
        window = UIApplication.sharedApplication.windows.firstObject;
    }
    if (!window) {
        return;
    }
    for (UIGestureRecognizer *gesture in self.containerView.gestureRecognizers) {
        [self.containerView removeGestureRecognizer:gesture];
    }

    [window addSubview:self];

    self.percentLabel.text = message ?: @"成功";

    self.progressLayer.opacity = 0;
    self.borderProgressLayer.opacity = 0;
    self.borderGlowLayer.opacity = 0;
    self.flowLightLayer.opacity = 0;
    [self stopRainbowColorCycle];

    [UIView animateWithDuration:0.2
        animations:^{
          self.alpha = 1.0;
        }
        completion:^(BOOL finished) {
          [self directlyShowSuccessAnimation:completion];
        }];
}

- (void)directlyShowSuccessAnimation:(void (^)(void))completion {
    BOOL isDarkMode = [DYYYUtils isDarkMode];

    UIColor *successColor =
        isDarkMode ? [UIColor colorWithRed:48 / 255.0 green:209 / 255.0 blue:151 / 255.0 alpha:1.0] : [UIColor colorWithRed:11 / 255.0 green:195 / 255.0 blue:139 / 255.0 alpha:1.0];

    CAShapeLayer *circleLayer = [CAShapeLayer layer];
    CGFloat circleSize = 30;
    UIBezierPath *circlePath = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, circleSize, circleSize)];

    circleLayer.path = circlePath.CGPath;
    circleLayer.fillColor = successColor.CGColor;
    circleLayer.opacity = 0;

    [self.progressView.layer addSublayer:circleLayer];

    CAShapeLayer *checkmarkLayer = [CAShapeLayer layer];

    UIBezierPath *checkPath = [UIBezierPath bezierPath];
    [checkPath moveToPoint:CGPointMake(circleSize * 0.25, circleSize * 0.5)];
    [checkPath addLineToPoint:CGPointMake(circleSize * 0.45, circleSize * 0.7)];
    [checkPath addLineToPoint:CGPointMake(circleSize * 0.75, circleSize * 0.3)];

    checkmarkLayer.path = checkPath.CGPath;
    checkmarkLayer.fillColor = nil;
    checkmarkLayer.strokeColor = [UIColor whiteColor].CGColor;
    checkmarkLayer.lineWidth = 2.5;
    checkmarkLayer.lineCap = kCALineCapRound;
    checkmarkLayer.lineJoin = kCALineJoinRound;
    checkmarkLayer.strokeEnd = 0;

    [self.progressView.layer addSublayer:checkmarkLayer];

    CABasicAnimation *circleAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    circleAnimation.fromValue = @0.0;
    circleAnimation.toValue = @1.0;
    circleAnimation.duration = 0.1;
    circleLayer.opacity = 1.0;
    [circleLayer addAnimation:circleAnimation forKey:@"fadeIn"];

    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      DYYYToast *toast = weakSelf;
      if (!toast) {
          return;
      }
      if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHapticFeedbackEnabled"]) {
          UINotificationFeedbackGenerator *feedbackGenerator = [[UINotificationFeedbackGenerator alloc] init];
          [feedbackGenerator notificationOccurred:UINotificationFeedbackTypeSuccess];
      }

      CABasicAnimation *checkmarkAnimation = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
      checkmarkAnimation.fromValue = @0.0;
      checkmarkAnimation.toValue = @1.0;
      checkmarkAnimation.duration = 0.15;
      checkmarkAnimation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
      checkmarkLayer.strokeEnd = 1.0;
      [checkmarkLayer addAnimation:checkmarkAnimation forKey:@"drawCheckmark"];

      [UIView animateWithDuration:0.15
          delay:0.1
          usingSpringWithDamping:0.6
          initialSpringVelocity:0.8
          options:UIViewAnimationOptionCurveEaseInOut
          animations:^{
            toast.progressView.transform = CGAffineTransformMakeScale(1.15, 1.15);
          }
          completion:^(BOOL finished) {
            [UIView animateWithDuration:0.2
                             animations:^{
                               toast.progressView.transform = CGAffineTransformIdentity;
                             }];
          }];

      __weak __typeof(toast) innerWeakToast = toast;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DYYYToast *innerToast = innerWeakToast;
        if (!innerToast) {
            return;
        }
        [UIView animateWithDuration:0.2
            animations:^{
              innerToast.alpha = 0;
            }
            completion:^(BOOL finished) {
              [innerToast.borderProgressLayer removeFromSuperlayer];
              [innerToast.borderGlowLayer removeFromSuperlayer];
              [innerToast removeFromSuperview];
              if (completion) {
                  completion();
              }
            }];
      });
    });
}

// 启动流动光效动画
- (void)startFlowLight {
    if (self.flowLightLayer.opacity == 1.0) {
        return;  // 已在运行
    }
    self.flowLightLayer.opacity = 1.0;

    // strokeStart从0到1，strokeEnd固定0.15（光点宽度），形成绕圈跑的效果
    CABasicAnimation *flowAnim = [CABasicAnimation animationWithKeyPath:@"strokeStart"];
    flowAnim.fromValue = @0.0;
    flowAnim.toValue = @1.0;
    flowAnim.duration = 1.2;
    flowAnim.repeatCount = HUGE_VALF;
    flowAnim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [self.flowLightLayer addAnimation:flowAnim forKey:@"flowLight"];
}

// 停止流动光效动画
- (void)stopFlowLight {
    [self.flowLightLayer removeAnimationForKey:@"flowLight"];
    self.flowLightLayer.opacity = 0;
    [self stopRainbowColorCycle];
}

// 启动彩虹色循环（进度条颜色平滑流动渐变）
- (void)startRainbowColorCycle {
    if (self.colorTimer) {
        return;
    }
    self.rainbowHue = 0;

    __weak __typeof(self) weakSelf = self;
    self.colorTimer = [CADisplayLink displayLinkWithTarget:weakSelf selector:@selector(tickRainbowColor)];
    self.colorTimer.preferredFramesPerSecond = 30;
    [self.colorTimer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

// 彩虹色循环 tick
- (void)tickRainbowColor {
    self.rainbowHue += 0.02;
    if (self.rainbowHue > 1.0) {
        self.rainbowHue -= 1.0;
    }
    UIColor *color = [UIColor colorWithHue:self.rainbowHue saturation:0.85 brightness:0.95 alpha:1.0];
    self.borderProgressLayer.strokeColor = color.CGColor;
    self.borderGlowLayer.strokeColor = [color colorWithAlphaComponent:0.25].CGColor;
    self.flowLightLayer.strokeColor = [UIColor colorWithHue:self.rainbowHue saturation:0.6 brightness:1.0 alpha:1.0].CGColor;
}

// 停止彩虹色循环
- (void)stopRainbowColorCycle {
    [self.colorTimer invalidate];
    self.colorTimer = nil;
}

@end
