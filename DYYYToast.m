#import "DYYYToast.h"
#import "DYYYUtils.h"

@interface DYYYToast ()

@property(nonatomic, strong) CALayer *progressBar;
@property(nonatomic, strong) UIView *progressTrack;
@property(nonatomic, strong) UILabel *percentLabel;
@property(nonatomic, assign) CGFloat progress;
@property(nonatomic, strong) UIVisualEffectView *blurEffectView;
@property(nonatomic, strong) CAShapeLayer *checkmarkLayer;
@property(nonatomic, strong) UIView *progressView;
@property(nonatomic, assign) BOOL isShowingSuccessAnimation;
@property(nonatomic, strong) UIView *pillView;

@end

@implementation DYYYToast

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.isCancelled = NO;
        self.allowSuccessAnimation = NO;

        BOOL isDarkMode = [DYYYUtils isDarkMode];

        // 灵动岛样式：透明液态玻璃
        CGFloat pillWidth = 200;
        CGFloat pillHeight = 36;
        _pillView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pillWidth, pillHeight)];
        _pillView.center = CGPointMake(CGRectGetMidX(self.bounds), 130);

        // 液态玻璃：SystemThinMaterial 毛玻璃 + 渐变高光层 + 描边
        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
        _blurEffectView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        _blurEffectView.frame = _pillView.bounds;
        _blurEffectView.layer.cornerRadius = pillHeight / 2;
        _blurEffectView.clipsToBounds = YES;
        [_pillView addSubview:_blurEffectView];

        // 白色渐变高光层
        CAGradientLayer *highlightLayer = [CAGradientLayer layer];
        highlightLayer.frame = _blurEffectView.bounds;
        highlightLayer.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.15].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.05].CGColor,
            (id)[UIColor clearColor].CGColor
        ];
        highlightLayer.locations = @[@0.0, @0.5, @1.0];
        [_blurEffectView.contentView.layer addSublayer:highlightLayer];

        // 淡白描边
        _blurEffectView.layer.borderWidth = 0.5;
        _blurEffectView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.2].CGColor;

        [self addSubview:_pillView];

        // 左边下载图标（小圆点）
        CGFloat iconSize = 8;
        CGFloat iconX = 16;
        CGFloat iconY = (pillHeight - iconSize) / 2;
        UIView *iconDot = [[UIView alloc] initWithFrame:CGRectMake(iconX, iconY, iconSize, iconSize)];
        iconDot.backgroundColor = [UIColor colorWithRed:48/255.0 green:209/255.0 blue:151/255.0 alpha:1.0];
        iconDot.layer.cornerRadius = iconSize / 2;
        [_pillView addSubview:iconDot];

        // 中间文字
        CGFloat labelX = iconX + iconSize + 10;
        CGFloat labelWidth = 70;
        _percentLabel = [[UILabel alloc] initWithFrame:CGRectMake(labelX, 0, labelWidth, pillHeight)];
        _percentLabel.text = @"0%";
        _percentLabel.textColor = [UIColor whiteColor];
        _percentLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        _percentLabel.textAlignment = NSTextAlignmentLeft;
        [_pillView addSubview:_percentLabel];

        // 右边进度条轨道
        CGFloat trackX = labelX + labelWidth + 10;
        CGFloat trackWidth = pillWidth - trackX - 16;
        CGFloat trackHeight = 4;
        CGFloat trackY = (pillHeight - trackHeight) / 2;
        _progressTrack = [[UIView alloc] initWithFrame:CGRectMake(trackX, trackY, trackWidth, trackHeight)];
        _progressTrack.backgroundColor = [UIColor colorWithWhite:0.4 alpha:1.0];
        _progressTrack.layer.cornerRadius = trackHeight / 2;
        [_pillView addSubview:_progressTrack];

        // 进度条
        _progressBar = [CALayer layer];
        _progressBar.frame = CGRectMake(0, 0, 0, trackHeight);
        _progressBar.backgroundColor = [UIColor colorWithRed:48/255.0 green:209/255.0 blue:151/255.0 alpha:1.0].CGColor;
        _progressBar.cornerRadius = trackHeight / 2;
        [_progressTrack.layer addSublayer:_progressBar];

        // 下载中文字
        UILabel *downloadingLabel = [[UILabel alloc] initWithFrame:CGRectMake(trackX + trackWidth + 8, 0, 50, pillHeight)];
        downloadingLabel.text = @"下载中";
        downloadingLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
        downloadingLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        downloadingLabel.textAlignment = NSTextAlignmentLeft;
        [_pillView addSubview:downloadingLabel];

        UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [_pillView addGestureRecognizer:tapGesture];

        self.alpha = 0;
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

    // 更新进度条
    CGFloat trackWidth = _progressTrack.bounds.size.width;
    _progressBar.frame = CGRectMake(0, 0, trackWidth * progress, 4);

    // 更新百分比文字
    int percentage = (int)(progress * 100);
    _percentLabel.text = [NSString stringWithFormat:@"%d%%", percentage];
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

    CGPoint containerPoint = [self convertPoint:point toView:_pillView];
    if ([_pillView pointInside:containerPoint withEvent:event]) {
        return [super hitTest:point withEvent:event];
    }

    return nil;
}

// 下载成功动画方法
- (void)showSuccessAnimation:(void (^)(void))completion {
    BOOL isDarkMode = [DYYYUtils isDarkMode];

    UIColor *successColor =
        isDarkMode ? [UIColor colorWithRed:48 / 255.0 green:209 / 255.0 blue:151 / 255.0 alpha:1.0] : [UIColor colorWithRed:11 / 255.0 green:195 / 255.0 blue:139 / 255.0 alpha:1.0];

    // 动画完成后显示成功文字
    _percentLabel.text = @"完成";

    [UIView animateWithDuration:0.3
        animations:^{
            // 进度条变绿
            _progressBar.backgroundColor = successColor.CGColor;
        }
        completion:^(BOOL finished) {
            if (completion) {
                completion();
            }
        }];
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

- (void)setOverallProgress:(float)progress {
    [self setProgress:progress];
}

- (void)setBatchProgress:(float)progress {
    [self setProgress:progress];
}

+ (void)showSuccessToastWithMessage:(NSString *)message {
    // 空实现，兼容旧代码
}

- (void)showSuccessToastWithMessage:(NSString *)message completion:(void (^)(void))completion {
    // 空实现，兼容旧代码
}

@end
