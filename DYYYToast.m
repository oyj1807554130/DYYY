#import "DYYYToast.h"
#import "DYYYUtils.h"

@interface DYYYToast ()

@property(nonatomic, strong) CAShapeLayer *progressLayer;
@property(nonatomic, strong) UILabel *percentLabel;
@property(nonatomic, assign) CGFloat progress;
@property(nonatomic, strong) CAShapeLayer *checkmarkLayer;
@property(nonatomic, strong) UIView *progressView;
@property(nonatomic, assign) BOOL isShowingSuccessAnimation;
@property(nonatomic, strong) UIColor *randomColor;
@property(nonatomic, strong) UIColor *innerRandomColor;
@property(nonatomic, strong) UIColor *dotRandomColor;
@property(nonatomic, strong) UIView *dotView;

@end

@implementation DYYYToast

// 生成三色
- (void)generateRandomColors {
    _randomColor = [UIColor colorWithHue:(CGFloat)arc4random_uniform(256)/256.0
                              saturation:0.6+(CGFloat)arc4random_uniform(128)/256.0
                              brightness:0.8+(CGFloat)arc4random_uniform(64)/256.0
                                   alpha:1.0];
    _innerRandomColor = [UIColor colorWithHue:(CGFloat)arc4random_uniform(256)/256.0
                                  saturation:0.6+(CGFloat)arc4random_uniform(128)/256.0
                                  brightness:0.8+(CGFloat)arc4random_uniform(64)/256.0
                                       alpha:1.0];
    _dotRandomColor = [UIColor colorWithHue:(CGFloat)arc4random_uniform(256)/256.0
                                saturation:0.6+(CGFloat)arc4random_uniform(128)/256.0
                                brightness:0.8+(CGFloat)arc4random_uniform(64)/256.0
                                     alpha:1.0];
}

- (void)refreshRandomColor {
    [self generateRandomColors];
    _progressLayer.strokeColor = _randomColor.CGColor;
    _containerView.layer.shadowColor = _randomColor.CGColor;
    _progressBar.backgroundColor = _innerRandomColor;
    _dotView.backgroundColor = _dotRandomColor;
}

- (void)applyStrokeToLabel:(UILabel *)label {
    label.textColor = [UIColor whiteColor];
    label.layer.shadowColor = [UIColor blackColor].CGColor;
    label.layer.shadowOffset = CGSizeMake(0, 1);
    label.layer.shadowRadius = 3;
    label.layer.shadowOpacity = 0.8;
    label.layer.masksToBounds = NO;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.isCancelled = NO;
        self.allowSuccessAnimation = NO;

        [self generateRandomColors];

        // 透明液态玻璃 - 灵动岛胶囊样式
        CGFloat pillWidth = 200;
        CGFloat pillHeight = 36;
        _containerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pillWidth, pillHeight)];
        _containerView.center = CGPointMake(CGRectGetMidX(self.bounds), 130);
        _containerView.backgroundColor = [UIColor clearColor];
        _containerView.layer.cornerRadius = pillHeight / 2;
        _containerView.clipsToBounds = YES;
        _containerView.userInteractionEnabled = YES;

        // 透明背景 + 淡白描边
        _containerView.layer.borderWidth = 1.0;
        _containerView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;

        // 彩虹外发光
        _containerView.layer.shadowColor = _randomColor.CGColor;
        _containerView.layer.shadowOffset = CGSizeZero;
        _containerView.layer.shadowRadius = 8;
        _containerView.layer.shadowOpacity = 0.4;

        [self addSubview:_containerView];

        // === 外圈环形进度（胶囊边缘） ===
        CGFloat ringWidth = 3;
        CGFloat ringPadding = 1.5;
        CGFloat ringRadius = (pillHeight / 2) - ringPadding;

        UIBezierPath *ringPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(ringPadding, ringPadding, pillWidth - 2 * ringPadding, pillHeight - 2 * ringPadding) cornerRadius:ringRadius];

        // 背景环
        CAShapeLayer *backgroundRing = [CAShapeLayer layer];
        backgroundRing.path = ringPath.CGPath;
        backgroundRing.fillColor = [UIColor clearColor].CGColor;
        backgroundRing.strokeColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
        backgroundRing.lineWidth = ringWidth;
        backgroundRing.lineCap = kCALineCapRound;
        [_containerView.layer addSublayer:backgroundRing];

        // 外圈彩虹进度环
        _progressLayer = [CAShapeLayer layer];
        _progressLayer.path = ringPath.CGPath;
        _progressLayer.fillColor = [UIColor clearColor].CGColor;
        _progressLayer.strokeColor = _randomColor.CGColor;
        _progressLayer.lineWidth = ringWidth;
        _progressLayer.lineCap = kCALineCapRound;
        _progressLayer.strokeStart = 0;
        _progressLayer.strokeEnd = 0;
        [_containerView.layer addSublayer:_progressLayer];

        // 左边小圆点
        CGFloat dotSize = 8;
        CGFloat dotX = 14;
        CGFloat dotY = (pillHeight - dotSize) / 2;
        _dotView = [[UIView alloc] initWithFrame:CGRectMake(dotX, dotY, dotSize, dotSize)];
        _dotView.backgroundColor = _dotRandomColor;
        _dotView.layer.cornerRadius = dotSize / 2;
        [_containerView addSubview:_dotView];

        // 百分比标签（白字+黑描边）
        CGFloat labelX = 34;
        _percentLabel = [[UILabel alloc] initWithFrame:CGRectMake(labelX, 0, 150, pillHeight)];
        _percentLabel.text = @"下载中 0%";
        _percentLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        _percentLabel.textAlignment = NSTextAlignmentLeft;
        [self applyStrokeToLabel:_percentLabel];
        [_containerView addSubview:_percentLabel];

        // 进度条轨道（紧跟文字右侧，延伸到胶囊边缘）
        CGFloat trackStartX = labelX + 90 + 8;
        CGFloat trackEndPadding = 14;
        CGFloat trackWidth = pillWidth - trackStartX - trackEndPadding;
        CGFloat trackHeight = 4;
        CGFloat trackY = (pillHeight - trackHeight) / 2;
        _progressBarBackground = [[UIView alloc] initWithFrame:CGRectMake(trackStartX, trackY, trackWidth, trackHeight)];
        _progressBarBackground.backgroundColor = [UIColor colorWithWhite:0.4 alpha:1.0];
        _progressBarBackground.layer.cornerRadius = trackHeight / 2;
        [_containerView addSubview:_progressBarBackground];

        // 进度条
        _progressBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, trackHeight)];
        _progressBar.backgroundColor = _innerRandomColor;
        _progressBar.layer.cornerRadius = trackHeight / 2;
        [_progressBarBackground addSubview:_progressBar];

        UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [_containerView addGestureRecognizer:tapGesture];

        self.alpha = 0;
        _progressView = _containerView;
    }
    return self;
}

- (void)setProgress:(float)progress {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setProgress:progress];
        });
        return;
    }

    progress = MAX(0.0, MIN(1.0, progress));
    _progress = progress;

    // 外圈环形进度（平滑递进动画）
    CABasicAnimation *ringAnim = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    ringAnim.fromValue = @(_progressLayer.strokeEnd);
    ringAnim.toValue = @(progress);
    ringAnim.duration = 0.25;
    ringAnim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    ringAnim.fillMode = kCAFillModeForwards;
    ringAnim.removedOnCompletion = NO;
    _progressLayer.strokeEnd = progress;
    [_progressLayer addAnimation:ringAnim forKey:@"progressAnimation"];

    // 更新进度条
    CGFloat trackWidth = _progressBarBackground.bounds.size.width;
    [UIView animateWithDuration:0.25
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self->_progressBar.frame = CGRectMake(0, 0, trackWidth * progress, 4);
    } completion:nil];

    // 更新百分比文字
    int percentage = (int)(progress * 100);
    _percentLabel.text = [NSString stringWithFormat:@"下载中 %d%%", percentage];
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

- (void)showCancelAnimation:(void (^)(void))completion {
    _percentLabel.text = @"已取消";
    [UIView animateWithDuration:0.2
        animations:^{
            self.alpha = 0;
        }
        completion:^(BOOL finished) {
            [self removeFromSuperview];
            if (completion) {
                completion();
            }
        }];
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
                    // 隐藏进度条相关元素
                    self.dotView.hidden = YES;
                    self.progressBarBackground.hidden = YES;
                    self.progressBar.hidden = YES;
                    // 让percentLabel撑满剩余空间，居中显示
                    CGRect labelFrame = self.percentLabel.frame;
                    labelFrame.origin.x = 20;
                    labelFrame.size.width = self.containerView.bounds.size.width - 40;
                    self.percentLabel.frame = labelFrame;
                    self.percentLabel.textAlignment = NSTextAlignmentCenter;

                    [UIView transitionWithView:self.percentLabel
                                      duration:0.2
                                       options:UIViewAnimationOptionTransitionCrossDissolve
                                    animations:^{
                                        if (self.totalCount > 0) {
                                            self.percentLabel.text = [NSString stringWithFormat:@"✅ 下载完成（共%ld张）", (long)self.totalCount];
                                        } else {
                                            self.percentLabel.text = @"✅ 下载完成";
                                        }
                                    }
                                    completion:^(BOOL finished) {
                                        // 打勾弹出动画
                                        CAKeyframeAnimation *scaleAnim = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
                                        scaleAnim.values = @[@1.0, @1.3, @1.0];
                                        scaleAnim.keyTimes = @[@0, @0.5, @1.0];
                                        scaleAnim.duration = 0.3;
                                        scaleAnim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                                        [self.percentLabel.layer addAnimation:scaleAnim forKey:@"popIn"];
                                    }];
                }
                completion:^(BOOL finished) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [UIView animateWithDuration:0.2
                            animations:^{
                                self.alpha = 0;
                            }
                            completion:^(BOOL finished) {
                                [self removeFromSuperview];
                                if (completion) {
                                    completion();
                                }
                            }];
                    });
                }];
        }];
}

+ (void)showSuccessToastWithMessage:(NSString *)message {
    // 空实现
}

- (void)showSuccessToastWithMessage:(NSString *)message completion:(void (^)(void))completion {
    // 空实现
}

@end
