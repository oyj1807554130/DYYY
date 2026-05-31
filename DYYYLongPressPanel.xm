#import "AwemeHeaders.h"
#import "DYYYBottomAlertView.h"
#import "DYYYConfirmCloseView.h"
#import "DYYYCustomInputView.h"
#import "DYYYFilterSettingsView.h"
#import "DYYYKeywordListView.h"
#import "DYYYManager.h"
#import "DYYYToast.h"
#import "DYYYUtils.h"

%hook AWELongPressPanelViewGroupModel
%property(nonatomic, assign) BOOL isDYYYCustomGroup;
%end

// Modern风格长按面板（新版UI）
%hook AWEModernLongPressPanelTableViewController
%property(nonatomic, strong) CALayer *dyyyGlassLayer;
%property(nonatomic, assign) BOOL isViewAppeared;

// 长按面板液态玻璃效果
%new
- (void)dyyy_applyGlassEffectToPanel {
    if (!DYYYGetBool(@"DYYYEnableSheetBlur")) return;
    if (self.isViewAppeared) return;
    self.isViewAppeared = YES;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *panelView = self.view;
        if (!panelView) return;

        // 检查是否已有玻璃层
        if ([panelView.layer.sublayers containsObject:self.dyyyGlassLayer]) return;

        // 获取透明度设置
        CGFloat transparent = DYYYGetFloat(@"DYYYSheetBlurTransparent", 0.7);

        // 液态玻璃模糊底层
        UIBlurEffect *glassBlur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
        UIVisualEffectView *glassView = [[UIVisualEffectView alloc] initWithEffect:glassBlur];
        glassView.frame = panelView.bounds;
        glassView.alpha = transparent;
        glassView.layer.cornerRadius = panelView.layer.cornerRadius > 0 ? panelView.layer.cornerRadius : 20;
        glassView.clipsToBounds = YES;
        [panelView.layer insertSublayer:glassView.layer atIndex:0];

        // 渐变高光层
        CAGradientLayer *glassHighlight = [CAGradientLayer layer];
        glassHighlight.frame = glassView.bounds;
        glassHighlight.cornerRadius = glassView.layer.cornerRadius;
        glassHighlight.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.25].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.05].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.04].CGColor
        ];
        glassHighlight.locations = @[@0.0, @0.2, @0.55, @1.0];
        glassHighlight.startPoint = CGPointMake(0, 0);
        glassHighlight.endPoint = CGPointMake(0, 1);
        [glassView.contentView.layer addSublayer:glassHighlight];

        // 淡白描边
        CALayer *glassBorder = [CALayer layer];
        glassBorder.frame = glassView.bounds;
        glassBorder.cornerRadius = glassView.layer.cornerRadius;
        glassBorder.borderWidth = 0.5;
        glassBorder.borderColor = [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
        [glassView.contentView.layer addSublayer:glassBorder];

        self.dyyyGlassLayer = glassView.layer;
    });
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self dyyy_applyGlassEffectToPanel];
}

- (NSArray *)dataArray {
    // 检查是否开启精简模式
    BOOL simplifyPanel = DYYYGetBool(@"DYYYSimplifyLongPressPanel");

    NSArray *originalArray = %orig;
    if (!originalArray) {
        originalArray = @[];
    }

    // 如果开启精简模式，直接跳过原始面板处理，只返回自定义选项
    if (simplifyPanel) {
        originalArray = @[]; // 清空原始数组
    } else {
        // 获取需要隐藏的按钮设置（从文本输入框读取，逗号分隔）
        NSString *hidePanelItems = DYYYGetString(@"DYYYHidePanelItems");
        NSMutableSet<NSString *> *hideItemsLowerSet = [NSMutableSet set];

        if (hidePanelItems && hidePanelItems.length > 0) {
            // 支持中英文逗号分隔
            NSString *normalizedItems = [hidePanelItems stringByReplacingOccurrencesOfString:@"，" withString:@","];
            NSArray *items = [normalizedItems componentsSeparatedByString:@","];
            for (NSString *item in items) {
                NSString *trimmedItem = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (trimmedItem.length > 0) {
                    [hideItemsLowerSet addObject:[trimmedItem lowercaseString]];
                }
            }
        }

        // 如果有需要隐藏的项目，才进行过滤
        if (hideItemsLowerSet.count > 0) {
            NSMutableArray *modifiedOriginalGroups = [NSMutableArray array];

            for (id group in originalArray) {
                if ([group isKindOfClass:%c(AWELongPressPanelViewGroupModel)]) {
                    AWELongPressPanelViewGroupModel *groupModel = (AWELongPressPanelViewGroupModel *)group;
                    NSMutableArray *filteredGroupArr = [NSMutableArray array];

                    for (id item in groupModel.groupArr) {
                        if ([item isKindOfClass:%c(AWELongPressPanelBaseViewModel)]) {
                            AWELongPressPanelBaseViewModel *viewModel = (AWELongPressPanelBaseViewModel *)item;
                            NSString *descString = viewModel.describeString;

                            BOOL shouldHide = NO;
                            if (descString && descString.length > 0) {
                                NSString *descLower = [descString lowercaseString];

                                // 精确匹配
                                if ([hideItemsLowerSet containsObject:descLower]) {
                                    shouldHide = YES;
                                } else {
                                    // 部分匹配
                                    for (NSString *hideItemLower in hideItemsLowerSet) {
                                        if ([descLower containsString:hideItemLower] || [hideItemLower containsString:descLower]) {
                                            shouldHide = YES;
                                            break;
                                        }
                                    }
                                }
                            }

                            if (!shouldHide) {
                                [filteredGroupArr addObject:item];
                            }
                        } else {
                            [filteredGroupArr addObject:item];
                        }
                    }

                    if (filteredGroupArr.count > 0) {
                        AWELongPressPanelViewGroupModel *filteredGroup = [[%c(AWELongPressPanelViewGroupModel) alloc] init];
                        filteredGroup.groupType = groupModel.groupType;
                        filteredGroup.isModern = groupModel.isModern;
                        filteredGroup.groupArr = filteredGroupArr;
                        [modifiedOriginalGroups addObject:filteredGroup];
                    }
                } else {
                    [modifiedOriginalGroups addObject:group];
                }
            }
            originalArray = modifiedOriginalGroups;
        }
    }

    // 检查是否启用了任意长按功能
    BOOL hasAnyFeatureEnabled = NO;
    // 检查各个单独的功能开关
    BOOL enableSaveVideo = DYYYGetBool(@"DYYYLongPressSaveVideo");
    BOOL enableSaveCover = DYYYGetBool(@"DYYYLongPressSaveCover");
    BOOL enableSaveAudio = DYYYGetBool(@"DYYYLongPressSaveAudio");
    BOOL enableSaveCurrentImage = DYYYGetBool(@"DYYYLongPressSaveCurrentImage");
    BOOL enableSaveAllImages = DYYYGetBool(@"DYYYLongPressSaveAllImages");
    BOOL enableCopyText = DYYYGetBool(@"DYYYLongPressCopyText");
    BOOL enableCopyLink = DYYYGetBool(@"DYYYLongPressCopyLink");
    BOOL enableApiDownload = DYYYGetBool(@"DYYYLongPressApiDownload");
    BOOL enableFilterUser = DYYYGetBool(@"DYYYLongPressFilterUser");
    BOOL enableFilterKeyword = DYYYGetBool(@"DYYYLongPressFilterTitle");
    BOOL enableTimerClose = DYYYGetBool(@"DYYYLongPressTimerClose");
    BOOL enableCreateVideo = DYYYGetBool(@"DYYYLongPressCreateVideo");

    // 检查是否有任何功能启用
    hasAnyFeatureEnabled = enableSaveVideo || enableSaveCover || enableSaveAudio || enableSaveCurrentImage || enableSaveAllImages || enableCopyText || enableCopyLink || enableApiDownload ||
                           enableFilterUser || enableFilterKeyword || enableTimerClose || enableCreateVideo;

    // 如果没有任何功能启用，仅使用官方按钮
    if (!hasAnyFeatureEnabled) {
        return originalArray;
    }

    // 创建自定义功能按钮
    NSMutableArray *viewModels = [NSMutableArray array];

    BOOL isNewLivePhoto = (self.awemeModel.video && self.awemeModel.animatedImageVideoInfo != nil);

    // 视频下载功能 (非实况照片才显示)
    if (enableSaveVideo && self.awemeModel.awemeType != 68 && !isNewLivePhoto) {
        AWELongPressPanelBaseViewModel *downloadViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        downloadViewModel.awemeModel = self.awemeModel;
        downloadViewModel.actionType = 666;
        downloadViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        downloadViewModel.describeString = @"保存视频";
        AWEAwemeModel *capturedAwemeModel_video = self.awemeModel;
        downloadViewModel.action = ^{
          @try {
          AWEAwemeModel *awemeModel = capturedAwemeModel_video;
          if (!awemeModel) { [DYYYUtils showToast:@"数据异常"]; return; }
          [DYYYManager storeMetadataFromAwemeModel:awemeModel];
          AWEVideoModel *videoModel = awemeModel.video;
          AWEMusicModel *musicModel = awemeModel.music;
          NSURL *audioURL = nil;
          if (musicModel && musicModel.playURL && musicModel.playURL.originURLList.count > 0) {
              audioURL = [NSURL URLWithString:musicModel.playURL.originURLList.firstObject];
          }

                  if (videoModel && videoModel.h264URL && videoModel.h264URL.originURLList.count > 0) {
                      NSURL *url = [NSURL URLWithString:videoModel.h264URL.originURLList.firstObject];
                      if (url) {
                          [DYYYManager downloadMedia:url
                                           mediaType:MediaTypeVideo
                                               audio:audioURL
                                          completion:^(BOOL success){
                                          }];
                      }
                  }
              
          
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
          } @catch (NSException *e) {
              NSLog(@"[DYYY] Save video action exception: %@", e);
              [DYYYUtils showToast:@"保存视频异常，请重试"];
          }
        };
        [viewModels addObject:downloadViewModel];
    }

    //  新版实况照片保存
    if (enableSaveVideo && self.awemeModel.awemeType != 68 && isNewLivePhoto) {
        AWELongPressPanelBaseViewModel *livePhotoViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        livePhotoViewModel.awemeModel = self.awemeModel;
        livePhotoViewModel.actionType = 679;
        livePhotoViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        livePhotoViewModel.describeString = @"保存实况";
        AWEAwemeModel *capturedAwemeModel_lp = self.awemeModel;
        livePhotoViewModel.action = ^{
          @try {
          AWEAwemeModel *awemeModel = capturedAwemeModel_lp;
          if (!awemeModel) { [DYYYUtils showToast:@"数据异常"]; return; }
          [DYYYManager storeMetadataFromAwemeModel:awemeModel];
          AWEVideoModel *videoModel = awemeModel.video;

          // 使用封面URL作为图片URL
          NSURL *imageURL = nil;
          if (videoModel && videoModel.coverURL && videoModel.coverURL.originURLList.count > 0) {
              imageURL = [NSURL URLWithString:videoModel.coverURL.originURLList.firstObject];
          }

          // 视频URL从视频模型获取
          NSURL *videoURL = nil;
          if (videoModel && videoModel.playURL && videoModel.playURL.originURLList.count > 0) {
              videoURL = [NSURL URLWithString:videoModel.playURL.originURLList.firstObject];
          } else if (videoModel && videoModel.h264URL && videoModel.h264URL.originURLList.count > 0) {
              videoURL = [NSURL URLWithString:videoModel.h264URL.originURLList.firstObject];
          }

          // 下载实况照片
          if (imageURL && videoURL) {
              [DYYYManager downloadLivePhoto:imageURL
                                    videoURL:videoURL
                                  completion:^{
                                  }];
          }

          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
          } @catch (NSException *e) {
              NSLog(@"[DYYY] Live photo action exception: %@", e);
              [DYYYUtils showToast:@"保存实况异常，请重试"];
          }
        };
        [viewModels addObject:livePhotoViewModel];
    }



    // 当前图片/实况下载功能
    if (enableSaveCurrentImage && self.awemeModel.awemeType == 68 && self.awemeModel.albumImages.count > 0) {
        AWELongPressPanelBaseViewModel *imageViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        imageViewModel.awemeModel = self.awemeModel;
        imageViewModel.actionType = 669;
        imageViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";

        if (self.awemeModel.albumImages.count == 1) {
            imageViewModel.describeString = @"保存图片";
        } else {
            imageViewModel.describeString = @"保存当前图片";
        }

        NSInteger safeImageIndex = self.awemeModel.currentImageIndex;
        if (safeImageIndex <= 0 || safeImageIndex > self.awemeModel.albumImages.count) {
            safeImageIndex = 1;
        }
        AWEImageAlbumImageModel *currimge = self.awemeModel.albumImages[safeImageIndex - 1];
        if (currimge.clipVideo != nil || self.awemeModel.isLivePhoto) {
            if (self.awemeModel.albumImages.count == 1) {
                imageViewModel.describeString = @"保存实况";
            } else {
                imageViewModel.describeString = @"保存当前实况";
            }
        }
        AWEAwemeModel *capturedAwemeModel_img = self.awemeModel;
        imageViewModel.action = ^{
          AWEAwemeModel *awemeModel = capturedAwemeModel_img;
          [DYYYManager storeMetadataFromAwemeModel:awemeModel];
          AWEImageAlbumImageModel *currentImageModel = nil;
          if (awemeModel.currentImageIndex > 0 && awemeModel.currentImageIndex <= awemeModel.albumImages.count) {
              currentImageModel = awemeModel.albumImages[awemeModel.currentImageIndex - 1];
          } else if (awemeModel.albumImages.count > 0) {
              currentImageModel = awemeModel.albumImages.firstObject;
          }
          if (!currentImageModel) {
              [DYYYUtils showToast:@"无法获取当前图片信息"];
              AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
              [panelManager dismissWithAnimation:YES completion:nil];
              return;
          }
          // 如果是实况的话
          // 查找非.image后缀的URL
          NSURL *downloadURL = nil;
          for (NSString *urlString in currentImageModel.urlList) {
              NSURL *url = [NSURL URLWithString:urlString];
              NSString *pathExtension = [url.path.lowercaseString pathExtension];
              if (![pathExtension isEqualToString:@"image"]) {
                  downloadURL = url;
                  break;
              }
          }

          if (currentImageModel.clipVideo != nil) {
              NSURL *videoURL = [currentImageModel.clipVideo.playURL getDYYYSrcURLDownload];
              [DYYYManager downloadLivePhoto:downloadURL
                                    videoURL:videoURL
                                  completion:^{
                                  }];
          } else if (currentImageModel && currentImageModel.urlList.count > 0) {
              if (downloadURL) {
                  [DYYYManager downloadMedia:downloadURL
                                   mediaType:MediaTypeImage
                                       audio:nil
                                  completion:^(BOOL success) {
                                    if (success) {
                                    } else {
                                        [DYYYUtils showToast:@"图片保存已取消"];
                                    }
                                  }];
              } else {
                  [DYYYUtils showToast:@"没有找到合适格式的图片"];
              }
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:imageViewModel];
    }

    // 保存所有图片/实况功能
    if (enableSaveAllImages && self.awemeModel.awemeType == 68 && self.awemeModel.albumImages.count > 1) {
        AWELongPressPanelBaseViewModel *allImagesViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        allImagesViewModel.awemeModel = self.awemeModel;
        allImagesViewModel.actionType = 670;
        allImagesViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        AWEAwemeModel *capturedAwemeModel_allimg = self.awemeModel;
        allImagesViewModel.describeString = @"保存所有图片";
        // 检查是否有实况照片并更改按钮文字
        BOOL hasLivePhoto = NO;
        for (AWEImageAlbumImageModel *imageModel in self.awemeModel.albumImages) {
            if (imageModel.clipVideo != nil) {
                hasLivePhoto = YES;
                break;
            }
        }
        if (hasLivePhoto) {
            allImagesViewModel.describeString = @"保存所有实况";
        }
        allImagesViewModel.action = ^{
          AWEAwemeModel *awemeModel = capturedAwemeModel_allimg;
          [DYYYManager storeMetadataFromAwemeModel:awemeModel];
          NSMutableArray *imageURLs = [NSMutableArray array];
          NSMutableArray *livePhotos = [NSMutableArray array];

          for (AWEImageAlbumImageModel *imageModel in awemeModel.albumImages) {
              if (imageModel.urlList.count > 0) {
                  // 查找非.image后缀的URL
                  NSURL *downloadURL = nil;
                  for (NSString *urlString in imageModel.urlList) {
                      NSURL *url = [NSURL URLWithString:urlString];
                      NSString *pathExtension = [url.path.lowercaseString pathExtension];
                      if (![pathExtension isEqualToString:@"image"]) {
                          downloadURL = url;
                          break;
                      }
                  }

                  if (!downloadURL && imageModel.urlList.count > 0) {
                      downloadURL = [NSURL URLWithString:imageModel.urlList.firstObject];
                  }

                  // 检查是否是实况照片
                  if (imageModel.clipVideo != nil) {
                      NSURL *videoURL = [imageModel.clipVideo.playURL getDYYYSrcURLDownload];
                      [livePhotos addObject:@{@"imageURL" : downloadURL.absoluteString, @"videoURL" : videoURL.absoluteString}];
                  } else {
                      [imageURLs addObject:downloadURL.absoluteString];
                  }
              }
          }

          // 分别处理普通图片和实况照片
          if (livePhotos.count > 0) {
              [DYYYManager downloadAllLivePhotos:livePhotos];
          }

          if (imageURLs.count > 0) {
              [DYYYManager downloadAllImages:imageURLs];
          }

          if (livePhotos.count == 0 && imageURLs.count == 0) {
              [DYYYUtils showToast:@"没有找到合适格式的图片"];
          }

          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:allImagesViewModel];
    }

    // 接口1保存功能
    NSString *apiKey1 = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYInterfaceDownload"];
    if (enableApiDownload) {
        AWELongPressPanelBaseViewModel *apiDownload1 = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        apiDownload1.awemeModel = self.awemeModel;
        apiDownload1.actionType = 673;
        apiDownload1.duxIconName = @"ic_cloudarrowdown_outlined_20";
        apiDownload1.describeString = @"接口1保存";
        // 提前捕获值，避免block执行时self/awemeModel已被释放导致闪退
        AWEAwemeModel *capturedAwemeModel = self.awemeModel;
        NSInteger capturedImageIndex = self.awemeModel.currentImageIndex;
        NSString *capturedShareLink = [self.awemeModel valueForKey:@"shareURL"];
        apiDownload1.action = ^{
          @try {
          if (apiKey1.length == 0) {
              [DYYYUtils showToast:@"请先在设置页面填写接口1地址"];
              return;
          }
          [DYYYManager storeMetadataFromAwemeModel:capturedAwemeModel];
          // 存储当前浏览的图片索引，用于接口保存实况照片时定位
          [DYYYManager shared].currentImageIndex = capturedImageIndex;
          if (capturedShareLink.length == 0) {
              [DYYYUtils showToast:@"无法获取分享链接"];
              return;
          }
          // 使用封装的方法进行解析下载
          [DYYYManager parseAndDownloadVideoWithShareLink:capturedShareLink apiKey:apiKey1];
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
          } @catch (NSException *e) {
              NSLog(@"[DYYY] API download action exception: %@", e);
              [DYYYUtils showToast:@"接口1保存异常，请重试"];
          }
        };
        [viewModels addObject:apiDownload1];
    }

    // 接口2保存功能
    NSString *apiKey2 = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYInterfaceDownload2"];
    if (enableApiDownload) {
        AWELongPressPanelBaseViewModel *apiDownload2 = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        apiDownload2.awemeModel = self.awemeModel;
        apiDownload2.actionType = 674;
        apiDownload2.duxIconName = @"ic_cloudarrowdown_outlined_20";
        apiDownload2.describeString = @"接口2保存";
        // 提前捕获值，避免block执行时self/awemeModel已被释放导致闪退
        AWEAwemeModel *capturedAwemeModel2 = self.awemeModel;
        NSInteger capturedImageIndex2 = self.awemeModel.currentImageIndex;
        NSString *capturedShareLink2 = [self.awemeModel valueForKey:@"shareURL"];
        apiDownload2.action = ^{
          @try {
          if (apiKey2.length == 0) {
              [DYYYUtils showToast:@"请先在设置页面填写接口2地址"];
              return;
          }
          [DYYYManager storeMetadataFromAwemeModel:capturedAwemeModel2];
          // 存储当前浏览的图片索引，用于接口保存实况照片时定位
          [DYYYManager shared].currentImageIndex = capturedImageIndex2;
          if (capturedShareLink2.length == 0) {
              [DYYYUtils showToast:@"无法获取分享链接"];
              return;
          }
          // 使用封装的方法进行解析下载
          [DYYYManager parseAndDownloadVideoWithShareLink:capturedShareLink2 apiKey:apiKey2];
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
          } @catch (NSException *e) {
              NSLog(@"[DYYY] API download action exception: %@", e);
              [DYYYUtils showToast:@"接口2保存异常，请重试"];
          }
        };
        [viewModels addObject:apiDownload2];
    }

    // 封面下载功能
    if (enableSaveCover && self.awemeModel.awemeType != 68) {
        AWELongPressPanelBaseViewModel *coverViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        coverViewModel.awemeModel = self.awemeModel;
        coverViewModel.actionType = 667;
        coverViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        coverViewModel.describeString = @"保存封面";
        AWEAwemeModel *capturedAwemeModel_cover = self.awemeModel;
        coverViewModel.action = ^{
          AWEAwemeModel *awemeModel = capturedAwemeModel_cover;
          [DYYYManager storeMetadataFromAwemeModel:awemeModel];
          AWEVideoModel *videoModel = awemeModel.video;
          if (videoModel && videoModel.coverURL && videoModel.coverURL.originURLList.count > 0) {
              NSURL *url = [NSURL URLWithString:videoModel.coverURL.originURLList.firstObject];
              [DYYYManager downloadMedia:url
                               mediaType:MediaTypeImage
                                   audio:nil
                              completion:^(BOOL success) {
                                if (success) {
                                } else {
                                    [DYYYUtils showToast:@"封面保存已取消"];
                                }
                              }];
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:coverViewModel];
    }

    // 音频下载功能
    if (enableSaveAudio) {
        AWELongPressPanelBaseViewModel *audioViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        audioViewModel.awemeModel = self.awemeModel;
        audioViewModel.actionType = 668;
        audioViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        audioViewModel.describeString = @"保存音频";
        AWEAwemeModel *capturedAwemeModel_audio = self.awemeModel;
        audioViewModel.action = ^{
          AWEAwemeModel *awemeModel = capturedAwemeModel_audio;
          [DYYYManager storeMetadataFromAwemeModel:awemeModel];
          AWEMusicModel *musicModel = awemeModel.music;
          if (musicModel && musicModel.playURL && musicModel.playURL.originURLList.count > 0) {
              NSURL *url = [NSURL URLWithString:musicModel.playURL.originURLList.firstObject];
              [DYYYManager downloadMedia:url mediaType:MediaTypeAudio audio:nil completion:nil];
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:audioViewModel];
    }

    // 创建视频功能
    if (enableCreateVideo && self.awemeModel.awemeType == 68) {
        AWELongPressPanelBaseViewModel *createVideoViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        createVideoViewModel.awemeModel = self.awemeModel;
        createVideoViewModel.actionType = 677;
        createVideoViewModel.duxIconName = @"ic_videosearch_outlined_20";
        createVideoViewModel.describeString = @"制作视频";
        AWEAwemeModel *capturedAwemeModel_vid = self.awemeModel;
        createVideoViewModel.action = ^{
          AWEAwemeModel *awemeModel = capturedAwemeModel_vid;

          // 收集普通图片URL
          NSMutableArray *imageURLs = [NSMutableArray array];
          // 收集实况照片信息（图片URL+视频URL）
          NSMutableArray *livePhotos = [NSMutableArray array];

          // 获取背景音乐URL
          NSString *bgmURL = nil;
          if (awemeModel.music && awemeModel.music.playURL && awemeModel.music.playURL.originURLList.count > 0) {
              bgmURL = awemeModel.music.playURL.originURLList.firstObject;
          }

          // 处理所有图片和实况
          for (AWEImageAlbumImageModel *imageModel in awemeModel.albumImages) {
              if (imageModel.urlList.count > 0) {
                  // 查找非.image后缀的URL
                  NSString *bestURL = nil;
                  for (NSString *urlString in imageModel.urlList) {
                      NSURL *url = [NSURL URLWithString:urlString];
                      NSString *pathExtension = [url.path.lowercaseString pathExtension];
                      if (![pathExtension isEqualToString:@"image"]) {
                          bestURL = urlString;
                          break;
                      }
                  }

                  if (!bestURL && imageModel.urlList.count > 0) {
                      bestURL = imageModel.urlList.firstObject;
                  }

                  // 如果是实况照片，需要收集图片和视频URL
                  if (imageModel.clipVideo != nil) {
                      NSURL *videoURL = [imageModel.clipVideo.playURL getDYYYSrcURLDownload];
                      if (videoURL) {
                          [livePhotos addObject:@{@"imageURL" : bestURL, @"videoURL" : videoURL.absoluteString}];
                      }
                  } else {
                      // 普通图片
                      [imageURLs addObject:bestURL];
                  }
              }
          }

          // 调用视频创建API
          [DYYYManager createVideoFromMedia:imageURLs
              livePhotos:livePhotos
              bgmURL:bgmURL
              progress:^(NSInteger current, NSInteger total, NSString *status) {
              }
              completion:^(BOOL success, NSString *message) {
                if (success) {
                } else {
                    [DYYYUtils showToast:[NSString stringWithFormat:@"视频制作失败: %@", message]];
                }
              }];

          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:createVideoViewModel];
    }

    // 复制文案功能
    if (enableCopyText) {
        AWELongPressPanelBaseViewModel *copyText = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        copyText.awemeModel = self.awemeModel;
        copyText.actionType = 671;
        copyText.duxIconName = @"ic_xiaoxihuazhonghua_outlined";
        copyText.describeString = @"复制文案";
        AWEAwemeModel *capturedAwemeModel_text = self.awemeModel;
        copyText.action = ^{
          NSString *descText = [capturedAwemeModel_text valueForKey:@"descriptionString"];
          if (descText && descText.length > 0) {
              [[UIPasteboard generalPasteboard] setString:descText];
              [DYYYToast showSuccessToastWithMessage:@"文案已复制"];
          } else {
              [DYYYUtils showToast:@"没有可复制的文案"];
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:copyText];
    }

    // 复制分享链接功能
    if (enableCopyLink) {
        AWELongPressPanelBaseViewModel *copyShareLink = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        copyShareLink.awemeModel = self.awemeModel;
        copyShareLink.actionType = 672;
        copyShareLink.duxIconName = @"ic_share_outlined";
        copyShareLink.describeString = @"复制链接";
        AWEAwemeModel *capturedAwemeModel_link = self.awemeModel;
        copyShareLink.action = ^{
          NSString *shareLink = [capturedAwemeModel_link valueForKey:@"shareURL"];
          if (shareLink && shareLink.length > 0) {
              NSString *cleanedURL = cleanShareURL(shareLink);
              [[UIPasteboard generalPasteboard] setString:cleanedURL];
              [DYYYToast showSuccessToastWithMessage:@"分享链接已复制"];
          } else {
              [DYYYUtils showToast:@"无法获取分享链接"];
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:copyShareLink];
    }

    // 过滤用户功能
    if (enableFilterUser) {
        AWELongPressPanelBaseViewModel *filterKeywords = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        filterKeywords.awemeModel = self.awemeModel;
        filterKeywords.actionType = 674;
        filterKeywords.duxIconName = @"ic_userban_outlined_20";
        filterKeywords.describeString = @"过滤用户";
        AWEAwemeModel *capturedAwemeModel_filter = self.awemeModel;
        filterKeywords.action = ^{
          AWEUserModel *author = capturedAwemeModel_filter.author;
          if (!author) {
              [DYYYUtils showToast:@"无法获取用户信息"];
              return;
          }
          NSString *nickname = author.nickname ?: @"未知用户";
          NSString *shortId = author.shortID ?: @"";
          // 创建当前用户的过滤格式 "nickname-shortid"
          NSString *currentUserFilter = [NSString stringWithFormat:@"%@-%@", nickname, shortId];
          // 获取保存的过滤用户列表
          NSString *savedUsers = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFilterUsers"] ?: @"";
          NSArray *userArray = [savedUsers length] > 0 ? [savedUsers componentsSeparatedByString:@","] : @[];
          BOOL userExists = NO;
          for (NSString *userInfo in userArray) {
              NSArray *components = [userInfo componentsSeparatedByString:@"-"];
              if (components.count >= 2) {
                  NSString *userId = [components lastObject];
                  if ([userId isEqualToString:shortId] && shortId.length > 0) {
                      userExists = YES;
                      break;
                  }
              }
          }
          NSString *actionButtonText = userExists ? @"取消过滤" : @"添加过滤";
          [DYYYBottomAlertView showAlertWithTitle:@"过滤用户视频"
              message:[NSString stringWithFormat:@"用户: %@ (ID: %@)", nickname, shortId]
              avatarURL:nil
              cancelButtonText:@"管理过滤列表"
              confirmButtonText:actionButtonText
              cancelAction:^{
                DYYYKeywordListView *keywordListView = [[DYYYKeywordListView alloc] initWithTitle:@"过滤用户列表" keywords:userArray];
                keywordListView.onConfirm = ^(NSArray *users) {
                  NSString *userString = [users componentsJoinedByString:@","];
                  [[NSUserDefaults standardUserDefaults] setObject:userString forKey:@"DYYYFilterUsers"];
                  [DYYYUtils showToast:@"过滤用户列表已更新"];
                };
                [keywordListView show];
              }
              closeAction:nil
              confirmAction:^{
                // 添加或移除用户过滤
                NSMutableArray *updatedUsers = [NSMutableArray arrayWithArray:userArray];
                if (userExists) {
                    // 移除用户
                    NSMutableArray *toRemove = [NSMutableArray array];
                    for (NSString *userInfo in updatedUsers) {
                        NSArray *components = [userInfo componentsSeparatedByString:@"-"];
                        if (components.count >= 2) {
                            NSString *userId = [components lastObject];
                            if ([userId isEqualToString:shortId]) {
                                [toRemove addObject:userInfo];
                            }
                        }
                    }
                    [updatedUsers removeObjectsInArray:toRemove];
                    [DYYYUtils showToast:@"已从过滤列表中移除此用户"];
                } else {
                    // 添加用户
                    [updatedUsers addObject:currentUserFilter];
                    [DYYYUtils showToast:@"已添加此用户到过滤列表"];
                }
                // 保存更新后的列表
                NSString *updatedUserString = [updatedUsers componentsJoinedByString:@","];
                [[NSUserDefaults standardUserDefaults] setObject:updatedUserString forKey:@"DYYYFilterUsers"];
              }];
        };
        [viewModels addObject:filterKeywords];
    }

    // 过滤文案功能
    if (enableFilterKeyword) {
        AWELongPressPanelBaseViewModel *filterKeywords = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        filterKeywords.awemeModel = self.awemeModel;
        filterKeywords.actionType = 675;
        filterKeywords.duxIconName = @"ic_funnel_outlined_20";
        filterKeywords.describeString = @"过滤文案";
        AWEAwemeModel *capturedAwemeModel_kw = self.awemeModel;
        filterKeywords.action = ^{
          NSString *descText = [capturedAwemeModel_kw valueForKey:@"descriptionString"];
          NSString *propName = nil;
          if (capturedAwemeModel_kw.propGuideV2) {
              propName = capturedAwemeModel_kw.propGuideV2.propName;
          }
          DYYYFilterSettingsView *filterView = [[DYYYFilterSettingsView alloc] initWithTitle:@"过滤关键词调整" text:descText propName:propName];
          filterView.onConfirm = ^(NSString *selectedText) {
            if (selectedText.length > 0) {
                NSString *currentKeywords = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFilterKeywords"] ?: @"";
                NSString *newKeywords;
                if (currentKeywords.length > 0) {
                    newKeywords = [NSString stringWithFormat:@"%@,%@", currentKeywords, selectedText];
                } else {
                    newKeywords = selectedText;
                }
                [[NSUserDefaults standardUserDefaults] setObject:newKeywords forKey:@"DYYYFilterKeywords"];
                [DYYYUtils showToast:[NSString stringWithFormat:@"已添加过滤词: %@", selectedText]];
            }
          };
          // 设置过滤关键词按钮回调
          filterView.onKeywordFilterTap = ^{
            // 获取保存的关键词
            NSString *savedKeywords = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFilterKeywords"] ?: @"";
            NSArray *keywordArray = [savedKeywords length] > 0 ? [savedKeywords componentsSeparatedByString:@","] : @[];
            // 创建并显示关键词列表视图
            DYYYKeywordListView *keywordListView = [[DYYYKeywordListView alloc] initWithTitle:@"设置过滤关键词" keywords:keywordArray];
            // 设置确认回调
            keywordListView.onConfirm = ^(NSArray *keywords) {
              // 将关键词数组转换为逗号分隔的字符串
              NSString *keywordString = [keywords componentsJoinedByString:@","];
              // 保存到用户默认设置
              [[NSUserDefaults standardUserDefaults] setObject:keywordString forKey:@"DYYYFilterKeywords"];
              // 显示提示
              [DYYYUtils showToast:@"过滤关键词已更新"];
            };
            // 显示关键词列表视图
            [keywordListView show];
          };
          [filterView show];
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:filterKeywords];
    }

    if (enableTimerClose) {
        AWELongPressPanelBaseViewModel *timerCloseViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        timerCloseViewModel.awemeModel = self.awemeModel;
        timerCloseViewModel.actionType = 676;
        timerCloseViewModel.duxIconName = @"ic_c_alarm_outlined";
        // 检查是否已有定时任务在运行
        NSNumber *shutdownTime = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimerShutdownTime"];
        BOOL hasActiveTimer = shutdownTime != nil && [shutdownTime doubleValue] > [[NSDate date] timeIntervalSince1970];
        timerCloseViewModel.describeString = hasActiveTimer ? @"取消定时" : @"定时关闭";
        timerCloseViewModel.action = ^{
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
          NSNumber *shutdownTime = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimerShutdownTime"];
          BOOL hasActiveTimer = shutdownTime != nil && [shutdownTime doubleValue] > [[NSDate date] timeIntervalSince1970];
          if (hasActiveTimer) {
              [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"DYYYTimerShutdownTime"];
              [DYYYUtils showToast:@"已取消定时关闭任务"];
              return;
          }
          // 读取上次设置的时间
          NSInteger defaultMinutes = [[NSUserDefaults standardUserDefaults] integerForKey:@"DYYYTimerCloseMinutes"];
          if (defaultMinutes <= 0) {
              defaultMinutes = 5;
          }
          NSString *defaultText = [NSString stringWithFormat:@"%ld", (long)defaultMinutes];
          DYYYCustomInputView *inputView = [[DYYYCustomInputView alloc] initWithTitle:@"设置定时关闭时间" defaultText:defaultText placeholder:@"请输入关闭时间(单位:分钟)"];
          inputView.onConfirm = ^(NSString *inputText) {
            NSInteger minutes = [inputText integerValue];
            if (minutes <= 0) {
                minutes = 5;
            }
            // 保存用户设置的时间以供下次使用
            [[NSUserDefaults standardUserDefaults] setInteger:minutes forKey:@"DYYYTimerCloseMinutes"];
            NSInteger seconds = minutes * 60;
            NSTimeInterval shutdownTimeValue = [[NSDate date] timeIntervalSince1970] + seconds;
            [[NSUserDefaults standardUserDefaults] setObject:@(shutdownTimeValue) forKey:@"DYYYTimerShutdownTime"];
            [DYYYUtils showToast:[NSString stringWithFormat:@"抖音将在%ld分钟后关闭...", (long)minutes]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
              NSNumber *currentShutdownTime = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimerShutdownTime"];
              if (currentShutdownTime != nil && [currentShutdownTime doubleValue] <= [[NSDate date] timeIntervalSince1970]) {
                  [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"DYYYTimerShutdownTime"];
                  // 显示确认关闭弹窗，而不是直接退出
                  DYYYConfirmCloseView *confirmView = [[DYYYConfirmCloseView alloc] initWithTitle:@"定时关闭" message:@"定时关闭时间已到，是否关闭抖音？"];
                  [confirmView show];
              }
            });
          };
          [inputView show];
        };
        [viewModels addObject:timerCloseViewModel];
    }

    // 创建自定义组
    NSMutableArray *customGroups = [NSMutableArray array];
    NSInteger totalButtons = viewModels.count;

    // 根据按钮总数确定每行的按钮数
    NSInteger firstRowCount = 0;
    NSInteger secondRowCount = 0;

    // 确定分配方式与原代码相同
    if (totalButtons <= 2) {
        firstRowCount = totalButtons;
    } else if (totalButtons <= 4) {
        firstRowCount = totalButtons / 2;
        secondRowCount = totalButtons - firstRowCount;
    } else if (totalButtons <= 5) {
        firstRowCount = 3;
        secondRowCount = totalButtons - firstRowCount;
    } else if (totalButtons <= 6) {
        firstRowCount = 4;
        secondRowCount = totalButtons - firstRowCount;
    } else if (totalButtons <= 8) {
        firstRowCount = 4;
        secondRowCount = totalButtons - firstRowCount;
    } else {
        firstRowCount = 5;
        secondRowCount = totalButtons - firstRowCount;
    }

    // 创建第一行
    if (firstRowCount > 0) {
        NSArray<AWELongPressPanelBaseViewModel *> *firstRowButtons = [viewModels subarrayWithRange:NSMakeRange(0, firstRowCount)];
        AWELongPressPanelViewGroupModel *firstRowGroup = [[%c(AWELongPressPanelViewGroupModel) alloc] init];
        firstRowGroup.isDYYYCustomGroup = YES;
        firstRowGroup.groupType = (firstRowCount <= 3) ? 11 : 12;
        firstRowGroup.isModern = YES;
        firstRowGroup.groupArr = firstRowButtons;
        [customGroups addObject:firstRowGroup];
    }

    // 创建第二行
    if (secondRowCount > 0) {
        NSArray<AWELongPressPanelBaseViewModel *> *secondRowButtons = [viewModels subarrayWithRange:NSMakeRange(firstRowCount, secondRowCount)];
        AWELongPressPanelViewGroupModel *secondRowGroup = [[%c(AWELongPressPanelViewGroupModel) alloc] init];
        secondRowGroup.isDYYYCustomGroup = YES;
        secondRowGroup.groupType = (secondRowCount <= 3) ? 11 : 12;
        secondRowGroup.isModern = YES;
        secondRowGroup.groupArr = secondRowButtons;
        [customGroups addObject:secondRowGroup];
    }

    return [customGroups arrayByAddingObjectsFromArray:originalArray];
}
%end

// 修复Modern风格长按面板水平设置单元格的大小计算
%hook AWEModernLongPressHorizontalSettingCell
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.longPressViewGroupModel && [self.longPressViewGroupModel isDYYYCustomGroup]) {
        if (self.dataArray && indexPath.item < self.dataArray.count) {
            CGFloat totalWidth = collectionView.bounds.size.width;
            NSInteger itemCount = self.dataArray.count;
            CGFloat itemWidth = totalWidth / itemCount;
            return CGSizeMake(itemWidth, 73);
        }
        return CGSizeMake(73, 73);
    }
    return %orig;
}
%end

// 修复Modern风格长按面板交互单元格的大小计算
%hook AWEModernLongPressInteractiveCell
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.longPressViewGroupModel && [self.longPressViewGroupModel isDYYYCustomGroup]) {
        if (self.dataArray && indexPath.item < self.dataArray.count) {
            NSInteger itemCount = self.dataArray.count;
            CGFloat totalWidth = collectionView.bounds.size.width - 12 * (itemCount - 1);
            CGFloat itemWidth = totalWidth / itemCount;
            return CGSizeMake(itemWidth, 73);
        }
        return CGSizeMake(73, 73);
    }
    return %orig;
}
%end

// 经典风格长按面板
%hook AWELongPressPanelTableViewController
- (NSArray *)dataArray {
    NSArray *originalArray = %orig;
    if (!originalArray) {
        originalArray = @[];
    }
    if (!self.awemeModel.author.nickname) {
        return originalArray;
    }

    // 检查是否开启精简模式
    BOOL simplifyPanel = DYYYGetBool(@"DYYYSimplifyLongPressPanel");

    // 如果开启精简模式，直接跳过原始面板处理，只返回自定义选项
    if (simplifyPanel) {
        originalArray = @[]; // 清空原始数组
    } else {
        // 获取需要隐藏的按钮设置（从文本输入框读取，逗号分隔）
        NSString *hidePanelItems = DYYYGetString(@"DYYYHidePanelItems");
        NSMutableSet<NSString *> *hideItemsLowerSet = [NSMutableSet set];

        if (hidePanelItems && hidePanelItems.length > 0) {
            // 支持中英文逗号分隔
            NSString *normalizedItems = [hidePanelItems stringByReplacingOccurrencesOfString:@"，" withString:@","];
            NSArray *items = [normalizedItems componentsSeparatedByString:@","];
            for (NSString *item in items) {
                NSString *trimmedItem = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (trimmedItem.length > 0) {
                    [hideItemsLowerSet addObject:[trimmedItem lowercaseString]];
                }
            }
        }

        // 如果有需要隐藏的项目，才进行过滤
        if (hideItemsLowerSet.count > 0) {
            NSMutableArray *modifiedOriginalGroups = [NSMutableArray array];

            for (id group in originalArray) {
                if ([group isKindOfClass:%c(AWELongPressPanelViewGroupModel)]) {
                    AWELongPressPanelViewGroupModel *groupModel = (AWELongPressPanelViewGroupModel *)group;
                    NSMutableArray *filteredGroupArr = [NSMutableArray array];

                    for (id item in groupModel.groupArr) {
                        if ([item isKindOfClass:%c(AWELongPressPanelBaseViewModel)]) {
                            AWELongPressPanelBaseViewModel *viewModel = (AWELongPressPanelBaseViewModel *)item;
                            NSString *descString = viewModel.describeString;

                            BOOL shouldHide = NO;
                            if (descString && descString.length > 0) {
                                NSString *descLower = [descString lowercaseString];

                                // 精确匹配
                                if ([hideItemsLowerSet containsObject:descLower]) {
                                    shouldHide = YES;
                                } else {
                                    // 部分匹配
                                    for (NSString *hideItemLower in hideItemsLowerSet) {
                                        if ([descLower containsString:hideItemLower] || [hideItemLower containsString:descLower]) {
                                            shouldHide = YES;
                                            break;
                                        }
                                    }
                                }
                            }

                            if (!shouldHide) {
                                [filteredGroupArr addObject:item];
                            }
                        } else {
                            [filteredGroupArr addObject:item];
                        }
                    }

                    if (filteredGroupArr.count > 0) {
                        AWELongPressPanelViewGroupModel *filteredGroup = [[%c(AWELongPressPanelViewGroupModel) alloc] init];
                        filteredGroup.groupType = groupModel.groupType;
                        filteredGroup.groupArr = filteredGroupArr;
                        [modifiedOriginalGroups addObject:filteredGroup];
                    }
                } else {
                    [modifiedOriginalGroups addObject:group];
                }
            }
            originalArray = modifiedOriginalGroups;
        }
    }

    // 检查是否启用了任意长按功能
    BOOL hasAnyFeatureEnabled = NO;

    // 检查各个单独的功能开关
    BOOL enableSaveVideo = DYYYGetBool(@"DYYYLongPressSaveVideo");
    BOOL enableSaveCover = DYYYGetBool(@"DYYYLongPressSaveCover");
    BOOL enableSaveAudio = DYYYGetBool(@"DYYYLongPressSaveAudio");
    BOOL enableSaveCurrentImage = DYYYGetBool(@"DYYYLongPressSaveCurrentImage");
    BOOL enableSaveAllImages = DYYYGetBool(@"DYYYLongPressSaveAllImages");
    BOOL enableCopyText = DYYYGetBool(@"DYYYLongPressCopyText");
    BOOL enableCopyLink = DYYYGetBool(@"DYYYLongPressCopyLink");
    BOOL enableApiDownload = DYYYGetBool(@"DYYYLongPressApiDownload");
    BOOL enableFilterUser = DYYYGetBool(@"DYYYLongPressFilterUser");
    BOOL enableFilterKeyword = DYYYGetBool(@"DYYYLongPressFilterTitle");
    BOOL enableTimerClose = DYYYGetBool(@"DYYYLongPressTimerClose");
    BOOL enableCreateVideo = DYYYGetBool(@"DYYYLongPressCreateVideo");

    // 检查是否有任何功能启用
    hasAnyFeatureEnabled = enableSaveVideo || enableSaveCover || enableSaveAudio || enableSaveCurrentImage || enableSaveAllImages || enableCopyText || enableCopyLink || enableApiDownload ||
                           enableFilterUser || enableFilterKeyword || enableTimerClose || enableCreateVideo;

    if (!hasAnyFeatureEnabled) {
        return originalArray;
    }

    // 创建自定义功能组
    AWELongPressPanelViewGroupModel *newGroupModel = [[%c(AWELongPressPanelViewGroupModel) alloc] init];
    newGroupModel.groupType = 0;
    NSMutableArray *viewModels = [NSMutableArray array];

    BOOL isNewLivePhoto = (self.awemeModel.video && self.awemeModel.animatedImageVideoInfo != nil);

    // 视频下载功能 (非实况照片才显示)
    if (enableSaveVideo && self.awemeModel.awemeType != 68 && !isNewLivePhoto) {
        AWELongPressPanelBaseViewModel *downloadViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        downloadViewModel.awemeModel = self.awemeModel;
        downloadViewModel.actionType = 666;
        downloadViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        downloadViewModel.describeString = @"保存视频";
        AWEAwemeModel *capturedAwemeModel_video = self.awemeModel;
        downloadViewModel.action = ^{
          AWEAwemeModel *awemeModel = capturedAwemeModel_video;
          [DYYYManager storeMetadataFromAwemeModel:awemeModel];
          AWEVideoModel *videoModel = awemeModel.video;
          AWEMusicModel *musicModel = awemeModel.music;
          NSURL *audioURL = nil;
          if (musicModel && musicModel.playURL && musicModel.playURL.originURLList.count > 0) {
              audioURL = [NSURL URLWithString:musicModel.playURL.originURLList.firstObject];
          }

                  // 备用方法：直接使用h264URL
                  if (videoModel && videoModel.h264URL && videoModel.h264URL.originURLList.count > 0) {
                      NSURL *url = [NSURL URLWithString:videoModel.h264URL.originURLList.firstObject];
                      if (url) {
                          [DYYYManager downloadMedia:url
                                           mediaType:MediaTypeVideo
                                               audio:audioURL
                                          completion:^(BOOL success){
                                          }];
                      }
                  }
              
          
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:downloadViewModel];
    }

    //  新版实况照片保存
    if (enableSaveVideo && self.awemeModel.awemeType != 68 && isNewLivePhoto) {
        AWELongPressPanelBaseViewModel *livePhotoViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        livePhotoViewModel.awemeModel = self.awemeModel;
        livePhotoViewModel.actionType = 679;
        livePhotoViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        livePhotoViewModel.describeString = @"保存实况";
        AWEAwemeModel *capturedAwemeModel_lp = self.awemeModel;
        livePhotoViewModel.action = ^{
          @try {
          AWEAwemeModel *awemeModel = capturedAwemeModel_lp;
          if (!awemeModel) { [DYYYUtils showToast:@"数据异常"]; return; }
          [DYYYManager storeMetadataFromAwemeModel:awemeModel];
          AWEVideoModel *videoModel = awemeModel.video;

          // 使用封面URL作为图片URL
          NSURL *imageURL = nil;
          if (videoModel && videoModel.coverURL && videoModel.coverURL.originURLList.count > 0) {
              imageURL = [NSURL URLWithString:videoModel.coverURL.originURLList.firstObject];
          }

          // 视频URL从视频模型获取
          NSURL *videoURL = nil;
          if (videoModel && videoModel.playURL && videoModel.playURL.originURLList.count > 0) {
              videoURL = [NSURL URLWithString:videoModel.playURL.originURLList.firstObject];
          } else if (videoModel && videoModel.h264URL && videoModel.h264URL.originURLList.count > 0) {
              videoURL = [NSURL URLWithString:videoModel.h264URL.originURLList.firstObject];
          }

          // 下载实况照片
          if (imageURL && videoURL) {
              [DYYYManager downloadLivePhoto:imageURL
                                    videoURL:videoURL
                                  completion:^{
                                  }];
          }

          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
          } @catch (NSException *e) {
              NSLog(@"[DYYY] Live photo action exception: %@", e);
              [DYYYUtils showToast:@"保存实况异常，请重试"];
          }
        };
        [viewModels addObject:livePhotoViewModel];
    }



    // 当前图片/实况下载功能
    if (enableSaveCurrentImage && self.awemeModel.awemeType == 68 && self.awemeModel.albumImages.count > 0) {
        AWELongPressPanelBaseViewModel *imageViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        imageViewModel.awemeModel = self.awemeModel;
        imageViewModel.actionType = 669;
        imageViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";

        if (self.awemeModel.albumImages.count == 1) {
            imageViewModel.describeString = @"保存图片";
        } else {
            imageViewModel.describeString = @"保存当前图片";
        }

        NSInteger safeImageIndex = self.awemeModel.currentImageIndex;
        if (safeImageIndex <= 0 || safeImageIndex > self.awemeModel.albumImages.count) {
            safeImageIndex = 1;
        }
        AWEImageAlbumImageModel *currimge = self.awemeModel.albumImages[safeImageIndex - 1];
        if (currimge.clipVideo != nil || self.awemeModel.isLivePhoto) {
            if (self.awemeModel.albumImages.count == 1) {
                imageViewModel.describeString = @"保存实况";
            } else {
                imageViewModel.describeString = @"保存当前实况";
            }
        }

        AWEAwemeModel *capturedAwemeModel_img2 = self.awemeModel;
        imageViewModel.action = ^{
          AWEAwemeModel *awemeModel = capturedAwemeModel_img2;
          [DYYYManager storeMetadataFromAwemeModel:awemeModel];
          AWEImageAlbumImageModel *currentImageModel = nil;
          if (awemeModel.currentImageIndex > 0 && awemeModel.currentImageIndex <= awemeModel.albumImages.count) {
              currentImageModel = awemeModel.albumImages[awemeModel.currentImageIndex - 1];
          } else if (awemeModel.albumImages.count > 0) {
              currentImageModel = awemeModel.albumImages.firstObject;
          }
          if (!currentImageModel) {
              [DYYYUtils showToast:@"无法获取当前图片信息"];
              AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
              [panelManager dismissWithAnimation:YES completion:nil];
              return;
          }
          // 如果是实况的话
          // 查找非.image后缀的URL
          NSURL *downloadURL = nil;
          for (NSString *urlString in currentImageModel.urlList) {
              NSURL *url = [NSURL URLWithString:urlString];
              NSString *pathExtension = [url.path.lowercaseString pathExtension];
              if (![pathExtension isEqualToString:@"image"]) {
                  downloadURL = url;
                  break;
              }
          }

          if (currentImageModel.clipVideo != nil) {
              NSURL *videoURL = [currentImageModel.clipVideo.playURL getDYYYSrcURLDownload];
              [DYYYManager downloadLivePhoto:downloadURL
                                    videoURL:videoURL
                                  completion:^{
                                  }];
          } else if (currentImageModel && currentImageModel.urlList.count > 0) {
              if (downloadURL) {
                  [DYYYManager downloadMedia:downloadURL
                                   mediaType:MediaTypeImage
                                       audio:nil
                                  completion:^(BOOL success) {
                                    if (success) {
                                    } else {
                                        [DYYYUtils showToast:@"图片保存已取消"];
                                    }
                                  }];
              } else {
                  [DYYYUtils showToast:@"没有找到合适格式的图片"];
              }
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:imageViewModel];
    }

    // 保存所有图片/实况功能
    if (enableSaveAllImages && self.awemeModel.awemeType == 68 && self.awemeModel.albumImages.count > 1) {
        AWELongPressPanelBaseViewModel *allImagesViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        allImagesViewModel.awemeModel = self.awemeModel;
        allImagesViewModel.actionType = 670;
        allImagesViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        AWEAwemeModel *capturedAwemeModel_allimg = self.awemeModel;
        allImagesViewModel.describeString = @"保存所有图片";
        // 检查是否有实况照片并更改按钮文字
        BOOL hasLivePhoto = NO;
        for (AWEImageAlbumImageModel *imageModel in self.awemeModel.albumImages) {
            if (imageModel.clipVideo != nil) {
                hasLivePhoto = YES;
                break;
            }
        }
        if (hasLivePhoto) {
            allImagesViewModel.describeString = @"保存所有实况";
        }
        allImagesViewModel.action = ^{
          AWEAwemeModel *awemeModel = capturedAwemeModel_allimg;
          [DYYYManager storeMetadataFromAwemeModel:awemeModel];
          NSMutableArray *imageURLs = [NSMutableArray array];
          NSMutableArray *livePhotos = [NSMutableArray array];

          for (AWEImageAlbumImageModel *imageModel in awemeModel.albumImages) {
              if (imageModel.urlList.count > 0) {
                  // 查找非.image后缀的URL
                  NSURL *downloadURL = nil;
                  for (NSString *urlString in imageModel.urlList) {
                      NSURL *url = [NSURL URLWithString:urlString];
                      NSString *pathExtension = [url.path.lowercaseString pathExtension];
                      if (![pathExtension isEqualToString:@"image"]) {
                          downloadURL = url;
                          break;
                      }
                  }

                  if (!downloadURL && imageModel.urlList.count > 0) {
                      downloadURL = [NSURL URLWithString:imageModel.urlList.firstObject];
                  }

                  // 检查是否是实况照片
                  if (imageModel.clipVideo != nil) {
                      NSURL *videoURL = [imageModel.clipVideo.playURL getDYYYSrcURLDownload];
                      [livePhotos addObject:@{@"imageURL" : downloadURL.absoluteString, @"videoURL" : videoURL.absoluteString}];
                  } else {
                      [imageURLs addObject:downloadURL.absoluteString];
                  }
              }
          }

          // 分别处理普通图片和实况照片
          if (livePhotos.count > 0) {
              [DYYYManager downloadAllLivePhotos:livePhotos];
          }

          if (imageURLs.count > 0) {
              [DYYYManager downloadAllImages:imageURLs];
          }

          if (livePhotos.count == 0 && imageURLs.count == 0) {
              [DYYYUtils showToast:@"没有找到合适格式的图片"];
          }

          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:allImagesViewModel];
    }

    // 接口1保存功能
    NSString *apiKey1 = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYInterfaceDownload"];
    if (enableApiDownload) {
        AWELongPressPanelBaseViewModel *apiDownload1 = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        apiDownload1.awemeModel = self.awemeModel;
        apiDownload1.actionType = 673;
        apiDownload1.duxIconName = @"ic_cloudarrowdown_outlined_20";
        apiDownload1.describeString = @"接口1保存";
        // 提前捕获值，避免block执行时self/awemeModel已被释放导致闪退
        AWEAwemeModel *capturedAwemeModel = self.awemeModel;
        NSInteger capturedImageIndex = self.awemeModel.currentImageIndex;
        NSString *capturedShareLink = [self.awemeModel valueForKey:@"shareURL"];
        apiDownload1.action = ^{
          @try {
          if (apiKey1.length == 0) {
              [DYYYUtils showToast:@"请先在设置页面填写接口1地址"];
              return;
          }
          [DYYYManager storeMetadataFromAwemeModel:capturedAwemeModel];
          // 存储当前浏览的图片索引，用于接口保存实况照片时定位
          [DYYYManager shared].currentImageIndex = capturedImageIndex;
          if (capturedShareLink.length == 0) {
              [DYYYUtils showToast:@"无法获取分享链接"];
              return;
          }
          // 使用封装的方法进行解析下载
          [DYYYManager parseAndDownloadVideoWithShareLink:capturedShareLink apiKey:apiKey1];
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
          } @catch (NSException *e) {
              NSLog(@"[DYYY] API download action exception: %@", e);
              [DYYYUtils showToast:@"接口1保存异常，请重试"];
          }
        };
        [viewModels addObject:apiDownload1];
    }

    // 接口2保存功能
    NSString *apiKey2 = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYInterfaceDownload2"];
    if (enableApiDownload) {
        AWELongPressPanelBaseViewModel *apiDownload2 = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        apiDownload2.awemeModel = self.awemeModel;
        apiDownload2.actionType = 674;
        apiDownload2.duxIconName = @"ic_cloudarrowdown_outlined_20";
        apiDownload2.describeString = @"接口2保存";
        // 提前捕获值，避免block执行时self/awemeModel已被释放导致闪退
        AWEAwemeModel *capturedAwemeModel2 = self.awemeModel;
        NSInteger capturedImageIndex2 = self.awemeModel.currentImageIndex;
        NSString *capturedShareLink2 = [self.awemeModel valueForKey:@"shareURL"];
        apiDownload2.action = ^{
          @try {
          if (apiKey2.length == 0) {
              [DYYYUtils showToast:@"请先在设置页面填写接口2地址"];
              return;
          }
          [DYYYManager storeMetadataFromAwemeModel:capturedAwemeModel2];
          // 存储当前浏览的图片索引，用于接口保存实况照片时定位
          [DYYYManager shared].currentImageIndex = capturedImageIndex2;
          if (capturedShareLink2.length == 0) {
              [DYYYUtils showToast:@"无法获取分享链接"];
              return;
          }
          // 使用封装的方法进行解析下载
          [DYYYManager parseAndDownloadVideoWithShareLink:capturedShareLink2 apiKey:apiKey2];
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
          } @catch (NSException *e) {
              NSLog(@"[DYYY] API download action exception: %@", e);
              [DYYYUtils showToast:@"接口2保存异常，请重试"];
          }
        };
        [viewModels addObject:apiDownload2];
    }

    // 封面下载功能
    if (enableSaveCover && self.awemeModel.awemeType != 68) {
        AWELongPressPanelBaseViewModel *coverViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        coverViewModel.awemeModel = self.awemeModel;
        coverViewModel.actionType = 667;
        coverViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        coverViewModel.describeString = @"保存封面";
        AWEAwemeModel *capturedAwemeModel_cover = self.awemeModel;
        coverViewModel.action = ^{
          AWEAwemeModel *awemeModel = capturedAwemeModel_cover;
          [DYYYManager storeMetadataFromAwemeModel:awemeModel];
          AWEVideoModel *videoModel = awemeModel.video;
          if (videoModel && videoModel.coverURL && videoModel.coverURL.originURLList.count > 0) {
              NSURL *url = [NSURL URLWithString:videoModel.coverURL.originURLList.firstObject];
              [DYYYManager downloadMedia:url
                               mediaType:MediaTypeImage
                                   audio:nil
                              completion:^(BOOL success) {
                                if (success) {
                                } else {
                                    [DYYYUtils showToast:@"封面保存已取消"];
                                }
                              }];
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:coverViewModel];
    }

    // 音频下载功能
    if (enableSaveAudio) {
        AWELongPressPanelBaseViewModel *audioViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        audioViewModel.awemeModel = self.awemeModel;
        audioViewModel.actionType = 668;
        audioViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        audioViewModel.describeString = @"保存音频";
        AWEAwemeModel *capturedAwemeModel_audio = self.awemeModel;
        audioViewModel.action = ^{
          AWEAwemeModel *awemeModel = capturedAwemeModel_audio;
          [DYYYManager storeMetadataFromAwemeModel:awemeModel];
          AWEMusicModel *musicModel = awemeModel.music;
          if (musicModel && musicModel.playURL && musicModel.playURL.originURLList.count > 0) {
              NSURL *url = [NSURL URLWithString:musicModel.playURL.originURLList.firstObject];
              [DYYYManager downloadMedia:url mediaType:MediaTypeAudio audio:nil completion:nil];
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:audioViewModel];
    }

    // 创建视频功能
    if (enableCreateVideo && self.awemeModel.awemeType == 68) {
        AWELongPressPanelBaseViewModel *createVideoViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        createVideoViewModel.awemeModel = self.awemeModel;
        createVideoViewModel.actionType = 677;
        createVideoViewModel.duxIconName = @"ic_videosearch_outlined_20";
        createVideoViewModel.describeString = @"制作视频";
        AWEAwemeModel *capturedAwemeModel_vid = self.awemeModel;
        createVideoViewModel.action = ^{
          AWEAwemeModel *awemeModel = capturedAwemeModel_vid;

          // 收集普通图片URL
          NSMutableArray *imageURLs = [NSMutableArray array];
          // 收集实况照片信息（图片URL+视频URL）
          NSMutableArray *livePhotos = [NSMutableArray array];

          // 获取背景音乐URL
          NSString *bgmURL = nil;
          if (awemeModel.music && awemeModel.music.playURL && awemeModel.music.playURL.originURLList.count > 0) {
              bgmURL = awemeModel.music.playURL.originURLList.firstObject;
          }

          // 处理所有图片和实况
          for (AWEImageAlbumImageModel *imageModel in awemeModel.albumImages) {
              if (imageModel.urlList.count > 0) {
                  // 查找非.image后缀的URL
                  NSString *bestURL = nil;
                  for (NSString *urlString in imageModel.urlList) {
                      NSURL *url = [NSURL URLWithString:urlString];
                      NSString *pathExtension = [url.path.lowercaseString pathExtension];
                      if (![pathExtension isEqualToString:@"image"]) {
                          bestURL = urlString;
                          break;
                      }
                  }

                  if (!bestURL && imageModel.urlList.count > 0) {
                      bestURL = imageModel.urlList.firstObject;
                  }

                  // 如果是实况照片，需要收集图片和视频URL
                  if (imageModel.clipVideo != nil) {
                      NSURL *videoURL = [imageModel.clipVideo.playURL getDYYYSrcURLDownload];
                      if (videoURL) {
                          [livePhotos addObject:@{@"imageURL" : bestURL, @"videoURL" : videoURL.absoluteString}];
                      }
                  } else {
                      // 普通图片
                      [imageURLs addObject:bestURL];
                  }
              }
          }

          // 调用视频创建API
          [DYYYManager createVideoFromMedia:imageURLs
              livePhotos:livePhotos
              bgmURL:bgmURL
              progress:^(NSInteger current, NSInteger total, NSString *status) {
              }
              completion:^(BOOL success, NSString *message) {
                if (success) {
                } else {
                    [DYYYUtils showToast:[NSString stringWithFormat:@"视频制作失败: %@", message]];
                }
              }];

          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:createVideoViewModel];
    }

    // 复制文案功能
    if (enableCopyText) {
        AWELongPressPanelBaseViewModel *copyText = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        copyText.awemeModel = self.awemeModel;
        copyText.actionType = 671;
        copyText.duxIconName = @"ic_xiaoxihuazhonghua_outlined";
        copyText.describeString = @"复制文案";
        AWEAwemeModel *capturedAwemeModel_text = self.awemeModel;
        copyText.action = ^{
          NSString *descText = [capturedAwemeModel_text valueForKey:@"descriptionString"];
          if (descText && descText.length > 0) {
              [[UIPasteboard generalPasteboard] setString:descText];
              [DYYYToast showSuccessToastWithMessage:@"文案已复制"];
          } else {
              [DYYYUtils showToast:@"没有可复制的文案"];
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:copyText];
    }

    // 复制分享链接功能
    if (enableCopyLink) {
        AWELongPressPanelBaseViewModel *copyShareLink = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        copyShareLink.awemeModel = self.awemeModel;
        copyShareLink.actionType = 672;
        copyShareLink.duxIconName = @"ic_share_outlined";
        copyShareLink.describeString = @"复制链接";
        AWEAwemeModel *capturedAwemeModel_link = self.awemeModel;
        copyShareLink.action = ^{
          NSString *shareLink = [capturedAwemeModel_link valueForKey:@"shareURL"];
          if (shareLink && shareLink.length > 0) {
              NSString *cleanedURL = cleanShareURL(shareLink);
              [[UIPasteboard generalPasteboard] setString:cleanedURL];
              [DYYYToast showSuccessToastWithMessage:@"分享链接已复制"];
          } else {
              [DYYYUtils showToast:@"无法获取分享链接"];
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:copyShareLink];
    }

    // 过滤用户功能
    if (enableFilterUser) {
        AWELongPressPanelBaseViewModel *filterKeywords = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        filterKeywords.awemeModel = self.awemeModel;
        filterKeywords.actionType = 674;
        filterKeywords.duxIconName = @"ic_userban_outlined_20";
        filterKeywords.describeString = @"过滤用户";
        AWEAwemeModel *capturedAwemeModel_filter = self.awemeModel;
        filterKeywords.action = ^{
          AWEUserModel *author = capturedAwemeModel_filter.author;
          if (!author) {
              [DYYYUtils showToast:@"无法获取用户信息"];
              return;
          }
          NSString *nickname = author.nickname ?: @"未知用户";
          NSString *shortId = author.shortID ?: @"";
          // 创建当前用户的过滤格式 "nickname-shortid"
          NSString *currentUserFilter = [NSString stringWithFormat:@"%@-%@", nickname, shortId];
          // 获取保存的过滤用户列表
          NSString *savedUsers = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFilterUsers"] ?: @"";
          NSArray *userArray = [savedUsers length] > 0 ? [savedUsers componentsSeparatedByString:@","] : @[];
          BOOL userExists = NO;
          for (NSString *userInfo in userArray) {
              NSArray *components = [userInfo componentsSeparatedByString:@"-"];
              if (components.count >= 2) {
                  NSString *userId = [components lastObject];
                  if ([userId isEqualToString:shortId] && shortId.length > 0) {
                      userExists = YES;
                      break;
                  }
              }
          }
          NSString *actionButtonText = userExists ? @"取消过滤" : @"添加过滤";
          [DYYYBottomAlertView showAlertWithTitle:@"过滤用户视频"
              message:[NSString stringWithFormat:@"用户: %@ (ID: %@)", nickname, shortId]
              avatarURL:nil
              cancelButtonText:@"管理过滤列表"
              confirmButtonText:actionButtonText
              cancelAction:^{
                DYYYKeywordListView *keywordListView = [[DYYYKeywordListView alloc] initWithTitle:@"过滤用户列表" keywords:userArray];
                keywordListView.onConfirm = ^(NSArray *users) {
                  NSString *userString = [users componentsJoinedByString:@","];
                  [[NSUserDefaults standardUserDefaults] setObject:userString forKey:@"DYYYFilterUsers"];
                  [DYYYUtils showToast:@"过滤用户列表已更新"];
                };
                [keywordListView show];
              }
              closeAction:nil
              confirmAction:^{
                // 添加或移除用户过滤
                NSMutableArray *updatedUsers = [NSMutableArray arrayWithArray:userArray];
                if (userExists) {
                    // 移除用户
                    NSMutableArray *toRemove = [NSMutableArray array];
                    for (NSString *userInfo in updatedUsers) {
                        NSArray *components = [userInfo componentsSeparatedByString:@"-"];
                        if (components.count >= 2) {
                            NSString *userId = [components lastObject];
                            if ([userId isEqualToString:shortId]) {
                                [toRemove addObject:userInfo];
                            }
                        }
                    }
                    [updatedUsers removeObjectsInArray:toRemove];
                    [DYYYUtils showToast:@"已从过滤列表中移除此用户"];
                } else {
                    // 添加用户
                    [updatedUsers addObject:currentUserFilter];
                    [DYYYUtils showToast:@"已添加此用户到过滤列表"];
                }
                // 保存更新后的列表
                NSString *updatedUserString = [updatedUsers componentsJoinedByString:@","];
                [[NSUserDefaults standardUserDefaults] setObject:updatedUserString forKey:@"DYYYFilterUsers"];
              }];
        };
        [viewModels addObject:filterKeywords];
    }

    // 过滤文案功能
    if (enableFilterKeyword) {
        AWELongPressPanelBaseViewModel *filterKeywords = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        filterKeywords.awemeModel = self.awemeModel;
        filterKeywords.actionType = 675;
        filterKeywords.duxIconName = @"ic_funnel_outlined_20";
        filterKeywords.describeString = @"过滤文案";
        AWEAwemeModel *capturedAwemeModel_kw = self.awemeModel;
        filterKeywords.action = ^{
          NSString *descText = [capturedAwemeModel_kw valueForKey:@"descriptionString"];
          NSString *propName = nil;
          if (capturedAwemeModel_kw.propGuideV2) {
              propName = capturedAwemeModel_kw.propGuideV2.propName;
          }
          DYYYFilterSettingsView *filterView = [[DYYYFilterSettingsView alloc] initWithTitle:@"过滤关键词调整" text:descText propName:propName];
          filterView.onConfirm = ^(NSString *selectedText) {
            if (selectedText.length > 0) {
                NSString *currentKeywords = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFilterKeywords"] ?: @"";
                NSString *newKeywords;
                if (currentKeywords.length > 0) {
                    newKeywords = [NSString stringWithFormat:@"%@,%@", currentKeywords, selectedText];
                } else {
                    newKeywords = selectedText;
                }
                [[NSUserDefaults standardUserDefaults] setObject:newKeywords forKey:@"DYYYFilterKeywords"];
                [DYYYUtils showToast:[NSString stringWithFormat:@"已添加过滤词: %@", selectedText]];
            }
          };
          // 设置过滤关键词按钮回调
          filterView.onKeywordFilterTap = ^{
            // 获取保存的关键词
            NSString *savedKeywords = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFilterKeywords"] ?: @"";
            NSArray *keywordArray = [savedKeywords length] > 0 ? [savedKeywords componentsSeparatedByString:@","] : @[];
            // 创建并显示关键词列表视图
            DYYYKeywordListView *keywordListView = [[DYYYKeywordListView alloc] initWithTitle:@"设置过滤关键词" keywords:keywordArray];
            // 设置确认回调
            keywordListView.onConfirm = ^(NSArray *keywords) {
              // 将关键词数组转换为逗号分隔的字符串
              NSString *keywordString = [keywords componentsJoinedByString:@","];
              // 保存到用户默认设置
              [[NSUserDefaults standardUserDefaults] setObject:keywordString forKey:@"DYYYFilterKeywords"];
              // 显示提示
              [DYYYUtils showToast:@"过滤关键词已更新"];
            };
            // 显示关键词列表视图
            [keywordListView show];
          };
          [filterView show];
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:filterKeywords];
    }

    if (enableTimerClose) {
        AWELongPressPanelBaseViewModel *timerCloseViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        timerCloseViewModel.awemeModel = self.awemeModel;
        timerCloseViewModel.actionType = 676;
        timerCloseViewModel.duxIconName = @"ic_c_alarm_outlined";
        // 检查是否已有定时任务在运行
        NSNumber *shutdownTime = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimerShutdownTime"];
        BOOL hasActiveTimer = shutdownTime != nil && [shutdownTime doubleValue] > [[NSDate date] timeIntervalSince1970];
        timerCloseViewModel.describeString = hasActiveTimer ? @"取消定时" : @"定时关闭";
        timerCloseViewModel.action = ^{
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
          NSNumber *shutdownTime = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimerShutdownTime"];
          BOOL hasActiveTimer = shutdownTime != nil && [shutdownTime doubleValue] > [[NSDate date] timeIntervalSince1970];
          if (hasActiveTimer) {
              [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"DYYYTimerShutdownTime"];
              [DYYYUtils showToast:@"已取消定时关闭任务"];
              return;
          }
          // 读取上次设置的时间
          NSInteger defaultMinutes = [[NSUserDefaults standardUserDefaults] integerForKey:@"DYYYTimerCloseMinutes"];
          if (defaultMinutes <= 0) {
              defaultMinutes = 5;
          }
          NSString *defaultText = [NSString stringWithFormat:@"%ld", (long)defaultMinutes];
          DYYYCustomInputView *inputView = [[DYYYCustomInputView alloc] initWithTitle:@"设置定时关闭时间" defaultText:defaultText placeholder:@"请输入关闭时间(单位:分钟)"];
          inputView.onConfirm = ^(NSString *inputText) {
            NSInteger minutes = [inputText integerValue];
            if (minutes <= 0) {
                minutes = 5;
            }
            // 保存用户设置的时间以供下次使用
            [[NSUserDefaults standardUserDefaults] setInteger:minutes forKey:@"DYYYTimerCloseMinutes"];
            NSInteger seconds = minutes * 60;
            NSTimeInterval shutdownTimeValue = [[NSDate date] timeIntervalSince1970] + seconds;
            [[NSUserDefaults standardUserDefaults] setObject:@(shutdownTimeValue) forKey:@"DYYYTimerShutdownTime"];
            [DYYYUtils showToast:[NSString stringWithFormat:@"抖音将在%ld分钟后关闭...", (long)minutes]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
              NSNumber *currentShutdownTime = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimerShutdownTime"];
              if (currentShutdownTime != nil && [currentShutdownTime doubleValue] <= [[NSDate date] timeIntervalSince1970]) {
                  [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"DYYYTimerShutdownTime"];
                  // 显示确认关闭弹窗，而不是直接退出
                  DYYYConfirmCloseView *confirmView = [[DYYYConfirmCloseView alloc] initWithTitle:@"定时关闭" message:@"定时关闭时间已到，是否关闭抖音？"];
                  [confirmView show];
              }
            });
          };
          [inputView show];
        };
        [viewModels addObject:timerCloseViewModel];
    }

    newGroupModel.groupArr = viewModels;

    // 返回自定义组+原始组的结果
    if (originalArray.count > 0) {
        NSMutableArray *resultArray = [originalArray mutableCopy];
        [resultArray insertObject:newGroupModel atIndex:0];
        return [resultArray copy];
    } else {
        return @[ newGroupModel ];
    }
}
%end

// 隐藏评论分享功能

%hook AWEIMCommentShareUserHorizontalCollectionViewCell

- (void)layoutSubviews {
    %orig;

    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentShareToFriends"]) {
        self.hidden = YES;
    } else {
        self.hidden = NO;
    }
}

%end

%hook AWEIMCommentShareUserHorizontalSectionController

- (CGSize)sizeForItemAtIndex:(NSInteger)index model:(id)model collectionViewSize:(CGSize)size {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentShareToFriends"]) {
        return CGSizeZero;
    }
    return %orig;
}

- (void)configCell:(id)cell index:(NSInteger)index model:(id)model {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentShareToFriends"]) {
        return;
    }
    %orig;
}

%end

%ctor {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYUserAgreementAccepted"]) {
        %init;
    }
}

%group DYYYFilterSetterGroup

%hook HOOK_TARGET_OWNER_CLASS

- (void)setModelsArray:(id)arg1 {
    if (![arg1 isKindOfClass:[NSArray class]]) {
        %orig(arg1);
        return;
    }

    NSArray *inputArray = (NSArray *)arg1;
    NSMutableArray *filteredArray = nil;

    for (id item in inputArray) {
        NSString *className = NSStringFromClass([item class]);

        BOOL shouldFilter = ([className isEqualToString:@"AWECommentIMSwiftImpl.CommentLongPressPanelForwardElement"] &&
                             [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentLongPressDaily"]) ||

                            ([className isEqualToString:@"AWECommentLongPressPanelSwiftImpl.CommentLongPressPanelCopyElement"] &&
                             [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentLongPressCopy"]) ||

                            ([className isEqualToString:@"AWECommentLongPressPanelSwiftImpl.CommentLongPressPanelSaveImageElement"] &&
                             [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentLongPressSaveImage"]) ||

                            ([className isEqualToString:@"AWECommentLongPressPanelSwiftImpl.CommentLongPressPanelReportElement"] &&
                             [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentLongPressReport"]) ||

                            ([className isEqualToString:@"AWECommentStudioSwiftImpl.CommentLongPressPanelVideoReplyElement"] &&
                             [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentLongPressVideoReply"]) ||

                            ([className isEqualToString:@"AWECommentSearchSwiftImpl.CommentLongPressPanelPictureSearchElement"] &&
                             [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentLongPressPictureSearch"]) ||

                            ([className isEqualToString:@"AWECommentSearchSwiftImpl.CommentLongPressPanelSearchElement"] &&
                             [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentLongPressSearch"]);

        if (shouldFilter) {
            if (!filteredArray) {
                filteredArray = [NSMutableArray arrayWithCapacity:inputArray.count];
                for (id keepItem in inputArray) {
                    if (keepItem == item)
                        break;
                    [filteredArray addObject:keepItem];
                }
            }
            continue;
        }

        if (filteredArray) {
            [filteredArray addObject:item];
        }
    }

    if (filteredArray) {
        %orig([filteredArray copy]);
    } else {
        %orig(arg1);
    }
}

%end
%end

%ctor {
    Class ownerClass = objc_getClass("AWECommentLongPressPanelSwiftImpl.CommentLongPressPanelNormalSectionViewModel");
    if (ownerClass) {
        %init(DYYYFilterSetterGroup, HOOK_TARGET_OWNER_CLASS = ownerClass);
    }
}
