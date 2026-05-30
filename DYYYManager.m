#import "DYYYManager.h"
#import <CoreAudioTypes/CoreAudioTypes.h>
#import <CoreMedia/CMMetadata.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>
#import <MobileCoreServices/UTCoreTypes.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

#import "DYYYToast.h"
#import "DYYYUtils.h"

// MARK: - API 类型定义
typedef NS_ENUM(NSInteger, DYYYAPIType) {
    DYYYAPITypeTikHub,     // TikHub API
    DYYYAPITypeQSY,        // qsy.ink (备用)
    DYYYAPITypeCustom       // 自定义API
};

@interface DYYYManager () {
    AVAssetExportSession *session;
    AVURLAsset *asset;
}
@end

@interface DYYYManager (APIAdapter)
+ (DYYYAPIType)detectAPIType:(NSString *)apiKey;
+ (NSDictionary *)adaptAPIResponse:(NSDictionary *)original fromType:(DYYYAPIType)apiType;
+ (NSDictionary *)adaptTikHubResponse:(NSDictionary *)tikHubData;
+ (NSDictionary *)adaptQSYResponse:(NSDictionary *)qsyData;
+ (void)requestWithAPIType:(DYYYAPIType)apiType
                         url:(NSString *)apiUrl
                         key:(NSString *)apiKey
                  completion:(void (^)(NSDictionary *data, NSError *error))completion;
@end

@interface DYYYManager () <NSURLSessionDownloadDelegate>
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSURLSessionDownloadTask *> *downloadTasks;
@property(nonatomic, strong) NSMutableDictionary<NSString *, DYYYToast *> *progressViews;
@property(nonatomic, strong) NSOperationQueue *downloadQueue;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *taskProgressMap;
@property(nonatomic, strong) NSMutableDictionary<NSString *, void (^)(BOOL success, NSURL *fileURL)> *completionBlocks;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *mediaTypeMap;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *filePathToDownloadID;
@property(nonatomic, strong) NSMutableSet *completedDownloadIDs;  // 已成功完成下载的ID集合，防止误报失败
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *downloadRetryCount;  // 下载重试计数
@property(nonatomic, strong) dispatch_queue_t livePhotoSaveQueue;  // 实况照片保存串行队列，防止并发覆盖 reader/writer

// 批量下载相关属性
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *downloadToBatchMap;                                                 // 下载ID到批量ID的映射
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *batchCompletedCountMap;                                             // 批量ID到已完成数量的映射
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *batchSuccessCountMap;                                               // 批量ID到成功数量的映射
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *batchTotalCountMap;                                                 // 批量ID到总数量的映射
@property(nonatomic, strong) NSMutableDictionary<NSString *, void (^)(NSInteger current, NSInteger total)> *batchProgressBlocks;              // 批量进度回调
@property(nonatomic, strong) NSMutableDictionary<NSString *, void (^)(NSInteger successCount, NSInteger totalCount)> *batchCompletionBlocks;  // 批量完成回调
// 串行图片下载状态
@property(nonatomic, strong) NSMutableArray *serialImageURLs;  // 剩余待下载URL列表
@property(nonatomic, copy) NSString *serialBatchID;            // 当前串行下载的batchID
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *serialIndexMap;  // downloadID -> 当前索引
@end

@implementation DYYYManager

#pragma mark - API 适配器实现

+ (DYYYAPIType)detectAPIType:(NSString *)apiKey {
    if ([apiKey rangeOfString:@"tikhub.io"].location != NSNotFound || 
        [apiKey rangeOfString:@"tikhub"].location != NSNotFound) {
        return DYYYAPITypeTikHub;
    }
    if ([apiKey rangeOfString:@"qsy.ink"].location != NSNotFound) {
        return DYYYAPITypeQSY;
    }
    return DYYYAPITypeCustom;
}

+ (NSDictionary *)adaptAPIResponse:(NSDictionary *)original fromType:(DYYYAPIType)apiType {
    if (!original) return nil;
    switch (apiType) {
        case DYYYAPITypeTikHub:
            return [self adaptTikHubResponse:original];
        case DYYYAPITypeQSY:
            return [self adaptQSYResponse:original];
        default:
            return original; // 自定义直接用
    }
}



+ (NSDictionary *)adaptQSYResponse:(NSDictionary *)qsyData {
    // qsy.ink 格式已经兼容，直接透传
    return qsyData;
}

+ (void)requestWithAPIType:(DYYYAPIType)apiType
                         url:(NSString *)apiUrl
                         key:(NSString *)apiKey
                  completion:(void (^)(NSDictionary *data, NSError *error))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:apiUrl]];
    request.timeoutInterval = 30;
    
    // TikHub 需要 Authorization header
    if (apiType == DYYYAPITypeTikHub) {
        NSString *token = apiKey;
        // 如果 apiKey 是完整URL，提取 Token（格式可能是 tikhub://{token} 或直接传 token）
        if ([apiKey rangeOfString:@"http"].location != NSNotFound) {
            // 从URL参数里提取 token？或者 token 是单独传的
            // 暂时假设 apiKey 传的是 token 字符串，或者已经包含 token
            NSLog(@"[DYYY-API] TikHub API 模式，请确保传的是 Bearer Token");
        } else {
            [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
        }
    }
    
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request
                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError) {
            completion(nil, jsonError);
            return;
        }
        completion(json, nil);
    }];
    [dataTask resume];
}

#pragma mark - 作者元数据 Caption 功能

+ (void)storeMetadataFromAwemeModel:(AWEAwemeModel *)awemeModel {
    if (!awemeModel) {
        NSLog(@"[DYYY-Caption] storeMetadata: awemeModel is nil");
        return;
    }
    DYYYManager *mgr = [DYYYManager shared];
    AWEUserModel *author = awemeModel.author;

    // 锁定逻辑：已有锁定值时，不覆盖
    if (mgr.authorInfoLocked) {
        NSLog(@"[DYYY-Caption] storeMetadata: 已锁定，跳过写入 shortID=%@ nickname=%@",
              mgr.currentAuthorShortID, mgr.currentAuthorNickname);
        return;
    }

    NSString *newShortID = author.shortID ?: @"";
    NSString *newNickname = author.nickname ?: @"";
    NSString *newCreateTime = @"";
    if (awemeModel.createTime) {
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:awemeModel.createTime.doubleValue];
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm";
        newCreateTime = [fmt stringFromDate:date] ?: @"";
    }

    // 如果有有效作者信息则写入并锁定
    BOOL hasAuthorInfo = (newShortID.length > 0 || newNickname.length > 0);
    if (hasAuthorInfo) {
        mgr.currentAuthorNickname = newNickname;
        mgr.currentAuthorShortID = newShortID;
        mgr.currentCreateTime = newCreateTime;
        mgr.authorInfoLocked = YES;
        NSLog(@"[DYYY-Caption] storeMetadata: 锁定作者信息 shortID=%@ nickname=%@ createTime=%@",
              newShortID, newNickname, newCreateTime);
    } else {
        // 无作者信息时，仅写入时间
        mgr.currentCreateTime = newCreateTime;
        NSLog(@"[DYYY-Caption] storeMetadata: 无作者信息，仅设置时间 createTime=%@", newCreateTime);
    }
}

+ (NSString *)generateCaption {
    DYYYManager *mgr = [DYYYManager shared];
    NSMutableString *caption = [NSMutableString string];
    BOOL hasAuthorInfo = NO;
    if (mgr.currentAuthorShortID.length > 0) {
        [caption appendFormat:@"抖音号：%@·", mgr.currentAuthorShortID];
        hasAuthorInfo = YES;
    }
    if (mgr.currentAuthorNickname.length > 0) {
        [caption appendFormat:@"抖音用户：%@·", mgr.currentAuthorNickname];
        hasAuthorInfo = YES;
    }
    if (mgr.currentCreateTime.length > 0) {
        [caption appendFormat:@"发布时间：%@", mgr.currentCreateTime];
    }
    NSString *result = [caption stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    // 如果没有任何作者信息但有时间，也返回（兜底）
    if (!hasAuthorInfo && result.length > 0) {
        NSLog(@"[DYYY-Caption] generateCaption: 作者信息为空，使用兜底: %@", result);
        return result;
    }
    // 有作者信息时，即使时间为空也返回
    if (hasAuthorInfo && result.length > 0) {
        return result;
    }
    NSLog(@"[DYYY-Caption] generateCaption: %@", result.length > 0 ? result : @"(empty)");
    return result.length > 0 ? result : nil;
}

+ (void)writeCaptionToLatestAsset {
    NSString *caption = [self generateCaption];
    if (!caption) return;
    
    PHFetchOptions *opts = [[PHFetchOptions alloc] init];
    opts.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
    opts.fetchLimit = 1;
    PHFetchResult<PHAsset *> *result = [PHAsset fetchAssetsWithOptions:opts];
    if (result.count == 0) return;
    
    PHAsset *asset = result[0];
    [[PHPhotoLibrary sharedPhotoLibrary]
     performChanges:^{
         PHAssetChangeRequest *changeRequest = [PHAssetChangeRequest changeRequestForAsset:asset];
         // Try multiple approaches to set caption
         @try {
             // Approach 1: performSelector with setCaption:
             SEL captionSel = NSSelectorFromString(@"setCaption:");
             if ([changeRequest respondsToSelector:captionSel]) {
                 #pragma clang diagnostic push
                 #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                 [changeRequest performSelector:captionSel withObject:caption];
                 #pragma clang diagnostic pop
                 NSLog(@"[DYYY-Caption] writeCaptionToLatestAsset: performSelector setCaption: SUCCESS");
             } else {
                 NSLog(@"[DYYY-Caption] writeCaptionToLatestAsset: changeRequest does not respond to setCaption:");
             }
         } @catch (NSException *e) {
             NSLog(@"[DYYY-Caption] performSelector setCaption: failed: %@", e);
         }
         @try {
             // Approach 2: KVC caption
             [changeRequest setValue:caption forKey:@"caption"];
             NSLog(@"[DYYY-Caption] writeCaptionToLatestAsset: KVC caption SUCCESS");
         } @catch (NSException *e) {
             NSLog(@"[DYYY-Caption] KVC 'caption' failed: %@", e);
             @try {
                 // Approach 3: KVC localizedTitle
                 [changeRequest setValue:caption forKey:@"localizedTitle"];
                 NSLog(@"[DYYY-Caption] writeCaptionToLatestAsset: KVC localizedTitle SUCCESS");
             } @catch (NSException *e2) {
                 NSLog(@"[DYYY-Caption] KVC 'localizedTitle' failed: %@", e2);
                 @try {
                     // Approach 4: KVC description
                     [changeRequest setValue:caption forKey:@"description"];
                     NSLog(@"[DYYY-Caption] writeCaptionToLatestAsset: KVC description SUCCESS");
                 } @catch (NSException *e3) {
                     NSLog(@"[DYYY-Caption] KVC 'description' failed: %@", e3);
                 }
             }
         }
     }
     completionHandler:^(BOOL success, NSError *error) {
         if (success) {
             NSLog(@"[DYYY-Caption] writeCaptionToLatestAsset: CHANGE COMMITTED");
         } else {
             NSLog(@"[DYYY-Caption] writeCaptionToLatestAsset: FAILED - %@", error);
         }
     }];
}

+ (NSString *)sanitizeCaptionForFilename {
    // Use caption text as filename so iOS Photos populates the "添加说明" field from it
    NSString *caption = [self generateCaption];
    if (!caption) return nil;
    // Replace characters that are invalid in filenames
    NSMutableString *safe = [caption mutableCopy];
    [safe replaceOccurrencesOfString:@"/" withString:@"／" options:0 range:NSMakeRange(0, safe.length)];
    [safe replaceOccurrencesOfString:@":" withString:@"：" options:0 range:NSMakeRange(0, safe.length)];
    [safe replaceOccurrencesOfString:@"\\" withString:@"＼" options:0 range:NSMakeRange(0, safe.length)];
    [safe replaceOccurrencesOfString:@"*" withString:@"＊" options:0 range:NSMakeRange(0, safe.length)];
    [safe replaceOccurrencesOfString:@"?" withString:@"？" options:0 range:NSMakeRange(0, safe.length)];
    [safe replaceOccurrencesOfString:@"\"" withString:@"＂" options:0 range:NSMakeRange(0, safe.length)];
    [safe replaceOccurrencesOfString:@"<" withString:@"＜" options:0 range:NSMakeRange(0, safe.length)];
    [safe replaceOccurrencesOfString:@">" withString:@"＞" options:0 range:NSMakeRange(0, safe.length)];
    [safe replaceOccurrencesOfString:@"|" withString:@"｜" options:0 range:NSMakeRange(0, safe.length)];
    // Truncate to reasonable length (filesystem limit ~255 bytes)
    if (safe.length > 80) {
        [safe deleteCharactersInRange:NSMakeRange(80, safe.length - 80)];
    }
    NSLog(@"[DYYY-Caption] sanitizeCaptionForFilename: %@", safe);
    return safe;
}

+ (NSURL *)embedCaptionInImageFile:(NSURL *)sourceURL {
    // 生成 caption 内容
    NSString *caption = [self generateCaption];
    if (!caption || caption.length == 0) {
        NSLog(@"[DYYY-Caption] embedCaptionInImageFile: caption为空，跳过");
        return sourceURL;
    }
    
    // 确定文件类型
    NSString *ext = [sourceURL pathExtension].lowercaseString;
    NSString *uti = nil;
    if ([ext isEqualToString:@"heic"] || [ext isEqualToString:@"heif"]) {
        uti = @"public.heic";
    } else if ([ext isEqualToString:@"png"]) {
        uti = @"public.png";
    } else {
        uti = @"public.jpeg";
    }
    
    // 读取源图片和元数据
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)sourceURL, nil);
    if (!source) {
        NSLog(@"[DYYY-Caption] embedCaptionInImageFile: CGImageSourceCreateWithURL failed");
        return sourceURL;
    }
    
    // 获取原始元数据的可变副本，只清除 caption 相关字段，保留其他所有原始元数据
    NSMutableDictionary *metadata = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, nil);
    if (!metadata) {
        metadata = [NSMutableDictionary dictionary];
    }
    
    // TIFF Artist/Software/ImageDescription（音乐作者信息）
    NSMutableDictionary *tiffDict = [metadata[(__bridge NSString *)kCGImagePropertyTIFFDictionary] mutableCopy];
    if (!tiffDict) tiffDict = [NSMutableDictionary dictionary];
    [tiffDict removeObjectForKey:(__bridge NSString *)kCGImagePropertyTIFFArtist];
    [tiffDict removeObjectForKey:(__bridge NSString *)kCGImagePropertyTIFFSoftware];
    [tiffDict removeObjectForKey:(__bridge NSString *)kCGImagePropertyTIFFImageDescription];
    metadata[(__bridge NSString *)kCGImagePropertyTIFFDictionary] = tiffDict;

    // EXIF UserComment（音乐作者评论）
    NSMutableDictionary *exifDict = [metadata[(__bridge NSString *)kCGImagePropertyExifDictionary] mutableCopy];
    if (!exifDict) exifDict = [NSMutableDictionary dictionary];
    [exifDict removeObjectForKey:(__bridge NSString *)kCGImagePropertyExifUserComment];
    metadata[(__bridge NSString *)kCGImagePropertyExifDictionary] = exifDict;

    // IPTC Caption-Abstract（来源显示的 caption）
    NSMutableDictionary *iptcDict = [metadata[(__bridge NSString *)kCGImagePropertyIPTCDictionary] mutableCopy];
    if (!iptcDict) iptcDict = [NSMutableDictionary dictionary];
    [iptcDict removeObjectForKey:(__bridge NSString *)kCGImagePropertyIPTCCaptionAbstract];
    metadata[(__bridge NSString *)kCGImagePropertyIPTCDictionary] = iptcDict;
    
    // 读取图片数据
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nil);
    CFRelease(source);
    if (!image) {
        NSLog(@"[DYYY-Caption] embedCaptionInImageFile: CGImageSourceCreateImageAtIndex failed");
        return sourceURL;
    }
    
    // 生成临时文件名：用 caption 当文件名，这样 iOS 相册会把它填入"添加说明"
    NSString *sanitizedCaption = [self sanitizeCaptionForFilename];
    NSString *tempFileName = nil;
    if (sanitizedCaption.length > 0) {
        tempFileName = [NSString stringWithFormat:@"%@.%@", sanitizedCaption, ext.length > 0 ? ext : @"jpg"];
    } else {
        tempFileName = [NSString stringWithFormat:@"dyyy_%@.%@", [[NSUUID UUID].UUIDString substringToIndex:8], ext.length > 0 ? ext : @"jpg"];
    }
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:tempFileName];
    NSURL *tempURL = [NSURL fileURLWithPath:tempPath];
    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
    
    // 创建带元数据的新图片
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)tempURL, (__bridge CFStringRef)uti, 1, nil);
    if (!destination) {
        NSLog(@"[DYYY-Caption] embedCaptionInImageFile: CGImageDestinationCreateWithURL failed");
        CGImageRelease(image);
        return sourceURL;
    }
    
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)metadata);
    BOOL finalized = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    
    if (!finalized) {
        NSLog(@"[DYYY-Caption] embedCaptionInImageFile: CGImageDestinationFinalize failed");
        return sourceURL;
    }
    
    NSLog(@"[DYYY-Caption] embedCaptionInImageFile: 成功写入 IPTC Caption: %@", caption);
    return tempURL;
}

+ (NSURL *)embedCaptionInVideoFile:(NSURL *)sourceURL {
    // 生成 caption 内容
    NSString *caption = [self generateCaption];
    if (!caption || caption.length == 0) {
        NSLog(@"[DYYY-Caption] embedCaptionInVideoFile: caption为空，跳过");
        return sourceURL;
    }
    
    // 使用 AVAssetWriter 添加元数据到视频
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:sourceURL options:nil];
    if (!asset) {
        NSLog(@"[DYYY-Caption] embedCaptionInVideoFile: AVURLAsset init failed");
        return sourceURL;
    }
    
    // 不写视频元数据，避免"来源"区域显示；仅靠文件名填充"添加说明"
    NSMutableArray *metadataItems = [NSMutableArray array];
    
    // 生成临时文件名：用 caption 当文件名，这样 iOS 相册会把它填入"添加说明"
    NSString *sanitizedCaption = [self sanitizeCaptionForFilename];
    NSString *tempFileName = nil;
    if (sanitizedCaption.length > 0) {
        tempFileName = [NSString stringWithFormat:@"%@.mp4", sanitizedCaption];
    } else {
        tempFileName = [NSString stringWithFormat:@"dyyy_%@.mp4", [[NSUUID UUID].UUIDString substringToIndex:8]];
    }
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:tempFileName];
    NSURL *tempURL = [NSURL fileURLWithPath:tempPath];
    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
    
    // 使用 AVAssetExportSession 导出（保留元数据）
    AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetPassthrough];
    if (!exportSession) {
        NSLog(@"[DYYY-Caption] embedCaptionInVideoFile: export session init failed");
        return sourceURL;
    }
    
    exportSession.outputURL = tempURL;
    exportSession.outputFileType = AVFileTypeQuickTimeMovie;
    exportSession.metadata = metadataItems;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    
    if (exportSession.status != AVAssetExportSessionStatusCompleted) {
        NSLog(@"[DYYY-Caption] embedCaptionInVideoFile: export failed: %@", exportSession.error);
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
        return sourceURL;
    }
    
    NSLog(@"[DYYY-Caption] embedCaptionInVideoFile: 成功写入元数据: %@", caption);
    return tempURL;
}

+ (instancetype)shared {
    static DYYYManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _fileLinks = [NSMutableDictionary dictionary];
        _downloadTasks = [NSMutableDictionary dictionary];
        _progressViews = [NSMutableDictionary dictionary];
        _downloadQueue = [[NSOperationQueue alloc] init];
        _downloadQueue.maxConcurrentOperationCount = 6;
        _taskProgressMap = [NSMutableDictionary dictionary];
        _completionBlocks = [NSMutableDictionary dictionary];
        _mediaTypeMap = [NSMutableDictionary dictionary];
        _filePathToDownloadID = [NSMutableDictionary dictionary];
        _completedDownloadIDs = [NSMutableSet set];
        _downloadRetryCount = [NSMutableDictionary dictionary];
        _livePhotoSaveQueue = dispatch_queue_create("com.dyyy.livePhotoSave", DISPATCH_QUEUE_SERIAL);

        // 初始化批量下载相关字典
        _downloadToBatchMap = [NSMutableDictionary dictionary];
        _batchCompletedCountMap = [NSMutableDictionary dictionary];
        _batchSuccessCountMap = [NSMutableDictionary dictionary];
        _batchTotalCountMap = [NSMutableDictionary dictionary];
        _batchProgressBlocks = [NSMutableDictionary dictionary];
        _batchCompletionBlocks = [NSMutableDictionary dictionary];
        // 初始化串行下载状态
        _serialImageURLs = [NSMutableArray array];
        _serialIndexMap = [NSMutableDictionary dictionary];
    }
    return self;
}

+ (void)saveMedia:(NSURL *)mediaURL mediaType:(MediaType)mediaType completion:(void (^)(BOOL success))completion {
    if (mediaType == MediaTypeAudio) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
              completion(NO);
            });
        }
        return;
    }

    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
      if (status != PHAuthorizationStatusAuthorized) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [DYYYUtils showToast:@"请允许访问相册权限后重试"];
            [[NSFileManager defaultManager] removeItemAtPath:mediaURL.path error:nil];
            [[DYYYManager shared] finalizeDownloadWithFileURL:mediaURL success:NO];
            if (completion) {
                completion(NO);
            }
          });
          return;
      }

      void (^reportResult)(BOOL) = ^(BOOL success) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [[DYYYManager shared] finalizeDownloadWithFileURL:mediaURL success:success];
            // 保存成功后写入作者信息元数据
            if (success) {
                [DYYYManager writeCaptionToLatestAsset];
                NSLog(@"[DYYY-Caption] 媒体保存完成，已写入作者信息元数据");
            }
            if (completion) {
                completion(success);
            }
          });
      };

      if (mediaType == MediaTypeHeic) {
          NSString *actualFormat = [DYYYUtils detectFileFormat:mediaURL];

          if ([actualFormat isEqualToString:@"webp"]) {
              [DYYYUtils convertWebpToGifSafely:mediaURL
                                     completion:^(NSURL *gifURL, BOOL success) {
                                  if (success && gifURL) {
                                      [DYYYUtils saveGifToPhotoLibrary:gifURL
                                                            completion:^(BOOL gifSuccess) {
                                                         [[NSFileManager defaultManager] removeItemAtPath:mediaURL.path error:nil];
                                                         reportResult(gifSuccess);
                                                       }];
                                  } else {
                                      dispatch_async(dispatch_get_main_queue(), ^{
                                        [DYYYUtils showToast:@"转换失败"];
                                        [[NSFileManager defaultManager] removeItemAtPath:mediaURL.path error:nil];
                                        reportResult(NO);
                                      });
                                  }
                                }];
              return;
          }

          if ([actualFormat isEqualToString:@"heic"] || [actualFormat isEqualToString:@"heif"]) {
              // Save HEIC with caption filename
              NSURL *captionURL = [DYYYManager embedCaptionInImageFile:mediaURL];
              [[PHPhotoLibrary sharedPhotoLibrary]
                  performChanges:^{
                    PHAssetChangeRequest *req = [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:captionURL];
                    @try {
                        [req setValue:@"" forKey:@"localizedTitle"];
                    } @catch (NSException *e) {
                        NSLog(@"[DYYY-Caption] Failed to set localizedTitle: %@", e);
                    }
                  }
                  completionHandler:^(BOOL success, NSError *_Nullable error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                      if (!success) {
                          // Fallback: try converting to JPEG and saving
                          [DYYYUtils convertHeicToGif:mediaURL
                                           completion:^(NSURL *gifURL, BOOL convSuccess) {
                                        if (convSuccess && gifURL) {
                                            [DYYYUtils saveGifToPhotoLibrary:gifURL
                                                                  completion:^(BOOL gifSuccess) {
                                                               [[NSFileManager defaultManager] removeItemAtPath:mediaURL.path error:nil];
                                                               reportResult(gifSuccess);
                                                             }];
                                        } else {
                                            [DYYYUtils showToast:@"转换失败"];
                                            [[NSFileManager defaultManager] removeItemAtPath:mediaURL.path error:nil];
                                            reportResult(NO);
                                        }
                                      }];
                          // 注意：fallback是异步的，reportResult已在上面的completionHandler中调用
                          // 这里return防止再次调用
                          return;
                      } else {
                          [[NSFileManager defaultManager] removeItemAtPath:mediaURL.path error:nil];
                      }
                      if (captionURL != mediaURL) {
                          [[NSFileManager defaultManager] removeItemAtURL:captionURL error:nil];
                      }
                      reportResult(success);
                    });
                  }];
              return;
          }

          if ([actualFormat isEqualToString:@"gif"]) {
              [DYYYUtils saveGifToPhotoLibrary:mediaURL
                                    completion:^(BOOL gifSuccess) {
                                 // GIF caption not supported - skip
                                 reportResult(gifSuccess);
                               }];
              return;
          }

          // Save image with caption filename - 使用统一方法
          [DYYYManager saveAssetToLibrary:mediaURL mediaType:MediaTypeImage useCaption:YES completion:^(BOOL success) {
              reportResult(success);
          }];
          return;
      }

      // Copy file with caption as filename for "添加说明" field - 使用统一方法
      [DYYYManager saveAssetToLibrary:mediaURL mediaType:mediaType useCaption:YES completion:^(BOOL success) {
          reportResult(success);
      }];
    }];
}

// MARK: - 统一保存到相册方法（合并重复代码）
+ (void)saveAssetToLibrary:(NSURL *)fileURL
                 mediaType:(MediaType)mediaType
                useCaption:(BOOL)useCaption
                completion:(void (^)(BOOL success))completion {
    if (!fileURL || ![fileURL isFileURL]) {
        if (completion) completion(NO);
        return;
    }
    
    // 处理caption文件名
    NSURL *saveURL = fileURL;
    NSURL *tempCaptionURL = nil;
    if (useCaption) {
        if (mediaType == MediaTypeVideo) {
            tempCaptionURL = [DYYYManager embedCaptionInVideoFile:fileURL];
        } else {
            tempCaptionURL = [DYYYManager embedCaptionInImageFile:fileURL];
        }
        saveURL = tempCaptionURL ?: fileURL;
    }
    
    [[PHPhotoLibrary sharedPhotoLibrary]
        performChanges:^{
            PHAssetChangeRequest *req = nil;
            if (mediaType == MediaTypeVideo) {
                req = [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:saveURL];
            } else {
                req = [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:saveURL];
            }
            if (req) {
                @try {
                    [req setValue:@"" forKey:@"localizedTitle"];
                } @catch (NSException *e) {
                    NSLog(@"[DYYY-Caption] Failed to set localizedTitle: %@", e);
                }
            }
        }
        completionHandler:^(BOOL success, NSError *_Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!success) {
                    NSLog(@"[DYYY] saveAssetToLibrary failed: %@", error);
                    // 降级：图片用 UIImageWriteToSavedPhotosAlbum
                    if (mediaType != MediaTypeVideo) {
                        UIImage *fallbackImage = [UIImage imageWithContentsOfFile:saveURL.path];
                        if (!fallbackImage) {
                            fallbackImage = [UIImage imageWithContentsOfFile:fileURL.path];
                        }
                        if (fallbackImage) {
                            NSLog(@"[DYYY] saveAssetToLibrary: fallback to UIImageWriteToSavedPhotosAlbum");
                            UIImageWriteToSavedPhotosAlbum(fallbackImage, nil, nil, nil);
                            if (tempCaptionURL && tempCaptionURL != fileURL) {
                                [[NSFileManager defaultManager] removeItemAtURL:tempCaptionURL error:nil];
                            }
                            [[NSFileManager defaultManager] removeItemAtPath:fileURL.path error:nil];
                            if (completion) completion(YES);
                            return;
                        }
                    }
                    [DYYYUtils showToast:@"保存失败"];
                }
                if (tempCaptionURL && tempCaptionURL != fileURL) {
                    [[NSFileManager defaultManager] removeItemAtURL:tempCaptionURL error:nil];
                }
                [[NSFileManager defaultManager] removeItemAtPath:fileURL.path error:nil];
                if (completion) completion(success);
            });
        }];
}

+ (void)downloadLivePhoto:(NSURL *)imageURL videoURL:(NSURL *)videoURL completion:(void (^)(void))completion {
    // 参数安全检查
    if (!imageURL || !videoURL) {
        NSLog(@"[DYYY] downloadLivePhoto: imageURL or videoURL is nil");
        dispatch_async(dispatch_get_main_queue(), ^{
          [DYYYUtils showToast:@"实况照片URL无效"];
        });
        if (completion) completion();
        return;
    }
    
    // 获取共享实例，确保FileLinks字典存在
    DYYYManager *manager = [DYYYManager shared];
    if (!manager.fileLinks) {
        manager.fileLinks = [NSMutableDictionary dictionary];
    }

    // 为图片和视频URL创建唯一的键
    NSString *uniqueKey = [NSString stringWithFormat:@"%@_%@", imageURL.absoluteString, videoURL.absoluteString];

    // 检查是否已经存在此下载任务
    NSDictionary *existingPaths = manager.fileLinks[uniqueKey];
    if (existingPaths) {
        NSString *imagePath = existingPaths[@"image"];
        NSString *videoPath = existingPaths[@"video"];

        // 使用异步检查以避免主线程阻塞
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          BOOL imageExists = [[NSFileManager defaultManager] fileExistsAtPath:imagePath];
          BOOL videoExists = [[NSFileManager defaultManager] fileExistsAtPath:videoPath];

          dispatch_async(dispatch_get_main_queue(), ^{
            if (imageExists && videoExists) {
                [[DYYYManager shared] saveLivePhoto:imagePath videoUrl:videoPath];
                if (completion) {
                    completion();
                }
                return;
            } else {
                // 文件不完整，需要重新下载
                [self startDownloadLivePhotoProcess:imageURL videoURL:videoURL uniqueKey:uniqueKey completion:completion];
            }
          });
        });
    } else {
        // 没有缓存，直接开始下载
        [self startDownloadLivePhotoProcess:imageURL videoURL:videoURL uniqueKey:uniqueKey completion:completion];
    }
}

+ (void)startDownloadLivePhotoProcess:(NSURL *)imageURL videoURL:(NSURL *)videoURL uniqueKey:(NSString *)uniqueKey completion:(void (^)(void))completion {
    // 创建临时目录
    NSString *livePhotoPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"LivePhoto"];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:livePhotoPath]) {
        [fileManager createDirectoryAtPath:livePhotoPath withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // 生成唯一标识符，防止多次调用时文件冲突
    NSString *uniqueID = [NSUUID UUID].UUIDString;
    // 根据图片URL后缀决定文件扩展名（API返回heic→jpeg的原画质URL，扩展名应为.jpeg）
    NSString *imageExt = @"heic";
    NSString *imageURLStr = imageURL.absoluteString.lowercaseString;
    if ([imageURLStr containsString:@".jpeg"] || [imageURLStr containsString:@".jpg"]) {
        imageExt = @"jpeg";
    } else if ([imageURLStr containsString:@".webp"]) {
        imageExt = @"webp";
    }
    NSString *imagePath = [livePhotoPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", uniqueID, imageExt]];
    NSString *videoPath = [livePhotoPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.mp4", uniqueID]];

    // 存储文件路径，以便下次下载相同的URL时可以复用
    DYYYManager *manager = [DYYYManager shared];
    [manager.fileLinks setObject:@{@"image" : imagePath, @"video" : videoPath} forKey:uniqueKey];

    dispatch_async(dispatch_get_main_queue(), ^{
      // 创建进度视图
      CGRect screenBounds = [UIScreen mainScreen].bounds;
      DYYYToast *progressView = [[DYYYToast alloc] initWithFrame:screenBounds];
      [progressView show];

      // 优化会话配置
      NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
      configuration.timeoutIntervalForRequest = 60.0;  // 单次请求等待60s，大文件避免超时
      configuration.timeoutIntervalForResource = 600.0; // 整个资源下载允许600s，大视频可能超过100MB
      configuration.HTTPMaximumConnectionsPerHost = 10;                             // 增加并发连接数
      configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;  // 强制从网络重新下载

      // 使用共享委托的session以节省资源
      NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:[DYYYManager shared] delegateQueue:[NSOperationQueue mainQueue]];

      dispatch_group_t group = dispatch_group_create();
      __block BOOL imageDownloaded = NO;
      __block BOOL videoDownloaded = NO;
      __block float imageProgress = 0.0;
      __block float videoProgress = 0.0;

      // 设置单独的下载观察者ID用于进度跟踪
      NSString *imageDownloadID = [NSString stringWithFormat:@"image_%@", uniqueID];
      NSString *videoDownloadID = [NSString stringWithFormat:@"video_%@", uniqueID];

      // 更新合并进度的定时器
      __weak DYYYToast *weakProgressView = progressView;
      __block NSTimer *progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                                       repeats:YES
                                                                         block:^(NSTimer *_Nonnull timer) {
                                                                           DYYYToast *strongProgressView = weakProgressView;
                                                                           if (!strongProgressView) {
                                                                               [timer invalidate];
                                                                               progressTimer = nil;
                                                                               return;
                                                                           }

                                                                           float totalProgress = (imageProgress + videoProgress) / 2.0;
                                                                           [strongProgressView setProgress:totalProgress];

                                                                           // 更新进度文字
                                                                           if (imageDownloaded && !videoDownloaded) {
                                                                           } else if (!imageDownloaded && videoDownloaded) {
                                                                           } else if (imageDownloaded && videoDownloaded) {
                                                                               [timer invalidate];  // 全部完成时停止定时器
                                                                               progressTimer = nil;
                                                                           }
                                                                        }];

      // 下载图片
      dispatch_group_enter(group);
      NSURLRequest *imageRequest = [NSURLRequest requestWithURL:imageURL];
      NSURLSessionDataTask *imageTask = [session dataTaskWithRequest:imageRequest
                                                   completionHandler:^(NSData *_Nullable data, NSURLResponse *_Nullable response, NSError *_Nullable error) {
                                                     if (!error && data) {
                                                         // 直接写入文件，避免临时文件移动操作
                                                         if ([data writeToFile:imagePath atomically:YES]) {
                                                             imageDownloaded = YES;
                                                             imageProgress = 1.0;
                                                         }
                                                     }
                                                     dispatch_group_leave(group);
                                                   }];

      // 设置图片下载进度观察
      if ([imageTask respondsToSelector:@selector(taskIdentifier)]) {
          [[manager taskProgressMap] setObject:@(0.0) forKey:imageDownloadID];

          // 使用系统API观察进度 (iOS 11+)
          if (@available(iOS 11.0, *)) {
              [imageTask.progress addObserver:manager forKeyPath:@"fractionCompleted" options:NSKeyValueObservingOptionNew context:(__bridge void *)(imageDownloadID)];
          }
      }

      // 下载视频
      dispatch_group_enter(group);
      NSURLRequest *videoRequest = [NSURLRequest requestWithURL:videoURL];
      NSURLSessionDataTask *videoTask = [session dataTaskWithRequest:videoRequest
                                                   completionHandler:^(NSData *_Nullable data, NSURLResponse *_Nullable response, NSError *_Nullable error) {
                                                     if (!error && data) {
                                                         // 直接写入文件，避免临时文件移动操作
                                                         if ([data writeToFile:videoPath atomically:YES]) {
                                                             videoDownloaded = YES;
                                                             videoProgress = 1.0;
                                                         }
                                                     }
                                                     dispatch_group_leave(group);
                                                   }];

      // 设置视频下载进度观察
      if ([videoTask respondsToSelector:@selector(taskIdentifier)]) {
          [[manager taskProgressMap] setObject:@(0.0) forKey:videoDownloadID];

          // 使用系统API观察进度 (iOS 11+)
          if (@available(iOS 11.0, *)) {
              [videoTask.progress addObserver:manager forKeyPath:@"fractionCompleted" options:NSKeyValueObservingOptionNew context:(__bridge void *)(videoDownloadID)];
          }
      }

      // 启动下载任务
      [imageTask resume];
      [videoTask resume];

      // 当两个下载都完成后，保存实况照片
      dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        // 停止进度定时器
        if (progressTimer) {
            [progressTimer invalidate];
            progressTimer = nil;
        }

        // 移除进度观察
        if (@available(iOS 11.0, *)) {
            if ([imageTask respondsToSelector:@selector(progress)]) {
                [imageTask.progress removeObserver:manager forKeyPath:@"fractionCompleted"];
            }
            if ([videoTask respondsToSelector:@selector(progress)]) {
                [videoTask.progress removeObserver:manager forKeyPath:@"fractionCompleted"];
            }
        }

        // 检查文件是否真的存在
        BOOL imageExists = [[NSFileManager defaultManager] fileExistsAtPath:imagePath];
        BOOL videoExists = [[NSFileManager defaultManager] fileExistsAtPath:videoPath];

        BOOL downloadSucceeded = imageExists && videoExists;
        progressView.allowSuccessAnimation = downloadSucceeded;
        [progressView dismiss];

        if (downloadSucceeded) {
            @try {
                // 添加iOS版本检查
                if (@available(iOS 15.0, *)) {
                    [[DYYYManager shared] saveLivePhoto:imagePath videoUrl:videoPath];
                }
            } @catch (NSException *exception) {
                // 删除失败的文件
                [[NSFileManager defaultManager] removeItemAtPath:imagePath error:nil];
                [[NSFileManager defaultManager] removeItemAtPath:videoPath error:nil];
                [manager.fileLinks removeObjectForKey:uniqueKey];
                [DYYYUtils showToast:@"保存实况照片失败"];
            }
        } else {
            // 清理不完整的文件
            if (imageExists)
                [[NSFileManager defaultManager] removeItemAtPath:imagePath error:nil];
            if (videoExists)
                [[NSFileManager defaultManager] removeItemAtPath:videoPath error:nil];
            [manager.fileLinks removeObjectForKey:uniqueKey];
            [DYYYUtils showToast:@"下载实况照片失败"];
        }

        if (completion) {
            completion();
        }
      });
    });
}

// 需要添加KVO回调方法来处理下载进度
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"fractionCompleted"] && [object isKindOfClass:[NSProgress class]]) {
        NSString *downloadID = (__bridge NSString *)context;
        if (downloadID) {
            NSProgress *progress = (NSProgress *)object;
            float fractionCompleted = progress.fractionCompleted;
            [self.taskProgressMap setObject:@(fractionCompleted) forKey:downloadID];
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

+ (void)downloadMedia:(NSURL *)url mediaType:(MediaType)mediaType audio:(NSURL *)audioURL completion:(void (^)(BOOL success))completion {
    if (!url) {
        NSLog(@"[DYYY] downloadMedia: url is nil");
        dispatch_async(dispatch_get_main_queue(), ^{
          [DYYYUtils showToast:@"下载地址无效"];
        });
        if (completion) completion(NO);
        return;
    }
    [self downloadMediaWithProgress:url
                          mediaType:mediaType
                              audio:audioURL
                           progress:nil
                         completion:^(BOOL success, NSURL *fileURL) {
                           void (^notifyCompletion)(BOOL) = ^(BOOL result) {
                               if (completion) {
                                   completion(result);
                               }
                           };

                           if (success) {
                               if (mediaType == MediaTypeAudio) {
                                   dispatch_async(dispatch_get_main_queue(), ^{
                                     [[DYYYManager shared] finalizeDownloadWithFileURL:fileURL success:YES];
                                     // 保存到"文件"App（如果可用），否则用分享面板
                                     if (@available(iOS 11.0, *)) {
                                         UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithURL:fileURL inMode:UIDocumentPickerModeExportToService];
                                         picker.shouldShowFileExtensions = YES;
                                         UIViewController *rootVC = [DYYYUtils topView];
                                         if (rootVC) {
                                             [rootVC presentViewController:picker animated:YES completion:nil];
                                         }
                                     } else {
                                         UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[ fileURL ] applicationActivities:nil];
                                         UIViewController *rootVC2 = [DYYYUtils topView];
                                         if (rootVC2) {
                                             [rootVC2 presentViewController:activityVC animated:YES completion:nil];
                                         }
                                     }
                                     notifyCompletion(YES);
                                   });
                               } else {
                                   if (mediaType == MediaTypeVideo && audioURL) {
                                       if (![DYYYUtils videoHasAudio:fileURL]) {
                                           [DYYYUtils downloadAudioAndMergeWithVideo:fileURL
                                                                            audioURL:audioURL
                                                                          completion:^(BOOL mergeSuccess, NSURL *mergedURL) {
                                                                       if (mergeSuccess) {
                                                                           [[DYYYManager shared] replaceFileURL:fileURL withFileURL:mergedURL];
                                                                           [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
                                                                           [self saveMedia:mergedURL
                                                                                 mediaType:mediaType
                                                                                completion:^(BOOL saveSuccess) {
                                                                                  notifyCompletion(saveSuccess);
                                                                                }];
                                                                       } else {
                                                                           [self saveMedia:fileURL
                                                                                 mediaType:mediaType
                                                                                completion:^(BOOL saveSuccess) {
                                                                                  notifyCompletion(saveSuccess);
                                                                                }];
                                                                       }
                                                                     }];
                                           return;
                                       }
                                   }
                                   [self saveMedia:fileURL
                                         mediaType:mediaType
                                        completion:^(BOOL saveSuccess) {
                                          notifyCompletion(saveSuccess);
                                        }];
                               }
                           } else {
                               notifyCompletion(NO);
                               if (fileURL) {
                                   [[DYYYManager shared] finalizeDownloadWithFileURL:fileURL success:NO];
                               }
                           }
                         }];
}

+ (void)downloadMediaWithProgress:(NSURL *)url
                        mediaType:(MediaType)mediaType
                            audio:(NSURL *)audioURL
                         progress:(void (^)(float progress))progressBlock
                       completion:(void (^)(BOOL success, NSURL *fileURL))completion {
    // 创建自定义进度条界面
    dispatch_async(dispatch_get_main_queue(), ^{
      // 创建进度视图
      CGRect screenBounds = [UIScreen mainScreen].bounds;
      DYYYToast *progressView = [[DYYYToast alloc] initWithFrame:screenBounds];

      // 生成下载ID并保存进度视图
      NSString *downloadID = [NSUUID UUID].UUIDString;
      [[DYYYManager shared].progressViews setObject:progressView forKey:downloadID];

      [progressView show];

      // 保存回调
      [[DYYYManager shared] setCompletionBlock:completion forDownloadID:downloadID];
      [[DYYYManager shared] setMediaType:mediaType forDownloadID:downloadID];

      // 配置下载会话 - 使用带委托的会话以获取进度更新
      NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
      configuration.timeoutIntervalForRequest = 60.0;  // 单次请求等待60s，大文件避免超时
      configuration.timeoutIntervalForResource = 600.0; // 整个资源下载允许600s，大视频可能超过100MB
      NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:[DYYYManager shared] delegateQueue:[NSOperationQueue mainQueue]];

      // 创建下载任务 - 不加自定义header，避免CDN反爬断连
      NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:url];
      downloadTask.taskDescription = downloadID;

      // 存储下载任务
      [[DYYYManager shared].downloadTasks setObject:downloadTask forKey:downloadID];
      [[DYYYManager shared].taskProgressMap setObject:@0.0 forKey:downloadID];  // 初始化进度为0

      // 开始下载
      [downloadTask resume];
    });
}

// 取消所有下载
+ (void)cancelAllDownloads {
    NSArray *downloadIDs = [[DYYYManager shared].downloadTasks allKeys];

    for (NSString *downloadID in downloadIDs) {
        NSURLSessionDownloadTask *task = [[DYYYManager shared].downloadTasks objectForKey:downloadID];
        if (task) {
            [task cancel];
        }

        DYYYToast *progressView = [[DYYYManager shared].progressViews objectForKey:downloadID];
        if (progressView) {
            progressView.isCancelled = YES;
            [progressView dismiss];
        }
    }

    NSString *livePhotoPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"LivePhotoBatch"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:livePhotoPath]) {
        NSError *error = nil;
        [fileManager removeItemAtPath:livePhotoPath error:&error];
        if (error) {
            NSLog(@"清理实况照片临时目录失败: %@", error.localizedDescription);
        }
    }

    NSString *generalLivePhotoPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"LivePhoto"];
    if ([fileManager fileExistsAtPath:generalLivePhotoPath]) {
        NSError *error = nil;
        [fileManager removeItemAtPath:generalLivePhotoPath error:&error];
        if (error) {
            NSLog(@"清理LivePhoto临时目录失败: %@", error.localizedDescription);
        }
    }

    [[DYYYManager shared].downloadTasks removeAllObjects];
    [[DYYYManager shared].progressViews removeAllObjects];
    // 清空串行下载状态，防止取消后 completion 还触发下一张
    [DYYYManager shared].serialBatchID = nil;
    [[DYYYManager shared].serialImageURLs removeAllObjects];
}

+ (void)downloadAllImages:(NSMutableArray *)imageURLs {
    if (imageURLs.count == 0) {
        return;
    }
    // 每次批量下载前解锁，确保新一批图片用新的作者信息
    [DYYYManager shared].authorInfoLocked = NO;
    [self downloadAllImagesWithProgress:imageURLs
                               progress:nil
                             completion:^(NSInteger successCount, NSInteger totalCount){
                             }];
}

+ (void)downloadAllImagesWithProgress:(NSMutableArray *)imageURLs
                             progress:(void (^)(NSInteger current, NSInteger total))progressBlock
                           completion:(void (^)(NSInteger successCount, NSInteger totalCount))completion {
    if (imageURLs.count == 0) {
        if (completion) {
            completion(0, 0);
        }
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      CGRect screenBounds = [UIScreen mainScreen].bounds;
      DYYYToast *progressView = [[DYYYToast alloc] initWithFrame:screenBounds];
      NSString *batchID = [NSUUID UUID].UUIDString;
      [[DYYYManager shared].progressViews setObject:progressView forKey:batchID];

      [progressView show];

      NSInteger totalCount = imageURLs.count;
      progressView.totalCount = totalCount;

      // 存储批量下载的相关信息
      [[DYYYManager shared] setBatchInfo:batchID totalCount:totalCount progressBlock:progressBlock completionBlock:completion];

      // 进度视图取消操作
      progressView.cancelBlock = ^{
        if (completion) {
            completion(0, totalCount);
        }
      };

      // 串行下载：先分发第一张，剩下的在 didFinishDownloadingToURL 里触发
      [[DYYYManager shared] setSerialBatchID:batchID];
      [[DYYYManager shared].serialImageURLs removeAllObjects];
      [[DYYYManager shared].serialImageURLs addObjectsFromArray:imageURLs];
      // 立即启动第一张
      [[DYYYManager shared] startNextSerialImageForBatch:batchID];
    });
}

// 设置批量下载信息
- (void)setBatchInfo:(NSString *)batchID
          totalCount:(NSInteger)totalCount
       progressBlock:(void (^)(NSInteger current, NSInteger total))progressBlock
     completionBlock:(void (^)(NSInteger successCount, NSInteger totalCount))completionBlock {
    [self.batchTotalCountMap setObject:@(totalCount) forKey:batchID];
    [self.batchCompletedCountMap setObject:@(0) forKey:batchID];
    [self.batchSuccessCountMap setObject:@(0) forKey:batchID];

    if (progressBlock) {
        [self.batchProgressBlocks setObject:[progressBlock copy] forKey:batchID];
    }

    if (completionBlock) {
        [self.batchCompletionBlocks setObject:[completionBlock copy] forKey:batchID];
    }
}

// 串行下载：启动下一张图片（仅针对批量图片下载）
- (void)startNextSerialImageForBatch:(NSString *)batchID {
    @synchronized(self) {
        if (self.serialImageURLs.count == 0) {
            return; // 没有剩余图片
        }
        if (![self.serialBatchID isEqualToString:batchID]) {
            return; // 不是当前串行批次，跳过
        }

        // 取下一张图的URL
        NSString *urlString = self.serialImageURLs.firstObject;
        [self.serialImageURLs removeObjectAtIndex:0];

        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) {
            // 无效URL，跳到下一张
            [self startNextSerialImageForBatch:batchID];
            return;
        }

        NSString *downloadID = [NSUUID UUID].UUIDString;
        [self associateDownload:downloadID withBatchID:batchID];

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 60.0;
        configuration.timeoutIntervalForResource = 600.0;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:[NSOperationQueue mainQueue]];

        NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:url];
        self.downloadTasks[downloadID] = downloadTask;
        self.taskProgressMap[downloadID] = @0.0;
        [self setMediaType:MediaTypeImage forDownloadID:downloadID];
        [downloadTask resume];
    }
}

// 设置批量下载信息

// 关联单个下载到批量下载
- (void)associateDownload:(NSString *)downloadID withBatchID:(NSString *)batchID {
    [self.downloadToBatchMap setObject:batchID forKey:downloadID];
}

// 批量下载完成计数并更新进度
- (void)incrementCompletedAndUpdateProgressForBatch:(NSString *)batchID success:(BOOL)success {
    @synchronized(self) {
        NSNumber *completedCountNum = self.batchCompletedCountMap[batchID];
        NSInteger completedCount = completedCountNum ? [completedCountNum integerValue] + 1 : 1;
        [self.batchCompletedCountMap setObject:@(completedCount) forKey:batchID];

        if (success) {
            NSNumber *successCountNum = self.batchSuccessCountMap[batchID];
            NSInteger successCount = successCountNum ? [successCountNum integerValue] + 1 : 1;
            [self.batchSuccessCountMap setObject:@(successCount) forKey:batchID];
        }

        NSNumber *totalCountNum = self.batchTotalCountMap[batchID];
        NSInteger totalCount = totalCountNum ? [totalCountNum integerValue] : 0;

        DYYYToast *progressView = self.progressViews[batchID];
        if (progressView) {
            progressView.currentIndex = completedCount;
            progressView.totalCount = totalCount;
            float progress = totalCount > 0 ? (float)completedCount / totalCount : 0;
            [progressView setOverallProgress:progress];
        }

        void (^progressBlock)(NSInteger current, NSInteger total) = self.batchProgressBlocks[batchID];
        if (progressBlock) {
            progressBlock(completedCount, totalCount);
        }

        if (completedCount >= totalCount) {
            NSInteger successCount = [self.batchSuccessCountMap[batchID] integerValue];

            void (^completionBlock)(NSInteger successCount, NSInteger totalCount) = self.batchCompletionBlocks[batchID];
            if (completionBlock) {
                completionBlock(successCount, totalCount);
            }

            if (progressView) {
                progressView.successCount = successCount;
                progressView.failCount = totalCount - successCount;
                progressView.allowSuccessAnimation = (successCount == totalCount);
                [progressView dismiss];
            }
            [self.progressViews removeObjectForKey:batchID];

            // 清理批量下载相关信息
            [self.batchCompletedCountMap removeObjectForKey:batchID];
            [self.batchSuccessCountMap removeObjectForKey:batchID];
            [self.batchTotalCountMap removeObjectForKey:batchID];
            [self.batchProgressBlocks removeObjectForKey:batchID];
            [self.batchCompletionBlocks removeObjectForKey:batchID];

            // 移除关联的下载ID
            NSArray *downloadIDs = [self.downloadToBatchMap allKeysForObject:batchID];
            for (NSString *downloadID in downloadIDs) {
                [self.downloadToBatchMap removeObjectForKey:downloadID];
            }
        }
    }
}

// 保存完成回调
- (void)setCompletionBlock:(void (^)(BOOL success, NSURL *fileURL))completion forDownloadID:(NSString *)downloadID {
    if (completion) {
        [self.completionBlocks setObject:[completion copy] forKey:downloadID];
    }
}

// 保存媒体类型
- (void)setMediaType:(MediaType)mediaType forDownloadID:(NSString *)downloadID {
    [self.mediaTypeMap setObject:@(mediaType) forKey:downloadID];
}

- (void)associateFileURL:(NSURL *)fileURL withDownloadID:(NSString *)downloadID {
    if (!fileURL || downloadID.length == 0) {
        return;
    }
    NSString *filePath = fileURL.path;
    if (filePath.length == 0) {
        return;
    }
    @synchronized(self.filePathToDownloadID) {
        self.filePathToDownloadID[filePath] = downloadID;
    }
}

- (NSString *)downloadIDForFileURL:(NSURL *)fileURL {
    if (!fileURL) {
        return nil;
    }
    NSString *filePath = fileURL.path;
    if (filePath.length == 0) {
        return nil;
    }
    @synchronized(self.filePathToDownloadID) {
        return self.filePathToDownloadID[filePath];
    }
}

- (void)replaceFileURL:(NSURL *)oldURL withFileURL:(NSURL *)newURL {
    if (!newURL) {
        return;
    }
    NSString *downloadID = [self downloadIDForFileURL:oldURL];
    if (downloadID.length == 0) {
        return;
    }
    NSString *newPath = newURL.path;
    if (newPath.length == 0) {
        return;
    }
    @synchronized(self.filePathToDownloadID) {
        if (oldURL.path.length > 0) {
            [self.filePathToDownloadID removeObjectForKey:oldURL.path];
        }
        self.filePathToDownloadID[newPath] = downloadID;
    }
}

- (void)removeMappingsForDownloadID:(NSString *)downloadID {
    if (downloadID.length == 0) {
        return;
    }
    [self.completedDownloadIDs removeObject:downloadID];
    @synchronized(self.filePathToDownloadID) {
        NSArray *keys = [self.filePathToDownloadID allKeysForObject:downloadID];
        for (NSString *key in keys) {
            [self.filePathToDownloadID removeObjectForKey:key];
        }
    }
}

- (void)finalizeDownloadWithFileURL:(NSURL *)fileURL success:(BOOL)success {
    NSString *downloadID = [self downloadIDForFileURL:fileURL];
    if (downloadID.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (!success) {
              [DYYYUtils showToast:@"保存失败"];
          }
        });
        return;
    }
    [self finalizeDownloadWithID:downloadID success:success fileURL:fileURL];
}

- (void)finalizeDownloadWithID:(NSString *)downloadID success:(BOOL)success fileURL:(NSURL *_Nullable)fileURL {
    if (downloadID.length == 0) {
        return;
    }

    [self removeMappingsForDownloadID:downloadID];

    dispatch_async(dispatch_get_main_queue(), ^{
      DYYYToast *progressView = self.progressViews[downloadID];
      if (progressView) {
          progressView.allowSuccessAnimation = success;
          if (success) {
              [progressView setProgress:1.0f];
          }
          [progressView dismiss];
          [self.progressViews removeObjectForKey:downloadID];
      }

      [self.taskProgressMap removeObjectForKey:downloadID];
      [self.completionBlocks removeObjectForKey:downloadID];
      [self.mediaTypeMap removeObjectForKey:downloadID];
      [self.downloadTasks removeObjectForKey:downloadID];
      [self.downloadToBatchMap removeObjectForKey:downloadID];
    });

    if (fileURL) {
        NSString *filePath = fileURL.path;
        if (filePath.length > 0) {
            @synchronized(self.filePathToDownloadID) {
                [self.filePathToDownloadID removeObjectForKey:filePath];
            }
        }
    }
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)downloadTask
                 didWriteData:(int64_t)bytesWritten
            totalBytesWritten:(int64_t)totalBytesWritten
    totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    // 确保不会除以0
    if (totalBytesExpectedToWrite <= 0) {
        return;
    }

    // 计算进度
    float progress = (float)totalBytesWritten / totalBytesExpectedToWrite;

    dispatch_async(dispatch_get_main_queue(), ^{
      NSString *downloadIDForTask = nil;

      for (NSString *key in self.downloadTasks.allKeys) {
          NSURLSessionDownloadTask *task = self.downloadTasks[key];
          if (task == downloadTask) {
              downloadIDForTask = key;
              break;
          }
      }

      // 如果找到对应的进度视图，更新进度
      if (downloadIDForTask) {
          [self.taskProgressMap setObject:@(progress) forKey:downloadIDForTask];

          // 优先按downloadID查找（非批量下载）
          DYYYToast *progressView = self.progressViews[downloadIDForTask];
          // 如果没找到，尝试通过batchID查找（批量串行下载）
          if (!progressView) {
              NSString *batchID = self.downloadToBatchMap[downloadIDForTask];
              if (batchID) {
                  progressView = self.progressViews[batchID];
              }
          }
          if (progressView) {
              if (!progressView.isCancelled) {
                  [progressView setProgress:progress];
              }
          }
      }
    });
}

// 下载完成的代理方法
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    // 找到对应的下载ID
    NSString *downloadIDForTask = nil;
    for (NSString *key in self.downloadTasks.allKeys) {
        NSURLSessionDownloadTask *task = self.downloadTasks[key];
        if (task == downloadTask) {
            downloadIDForTask = key;
            break;
        }
    }

    if (!downloadIDForTask) {
        return;
    }

    // 检查是否属于批量下载
    NSString *batchID = self.downloadToBatchMap[downloadIDForTask];
    BOOL isBatchDownload = (batchID != nil);

    // 标记此下载ID已成功接收数据，防止 didCompleteWithError 误报
    [self.completedDownloadIDs addObject:downloadIDForTask];

    // 获取该下载任务的mediaType
    NSNumber *mediaTypeNumber = self.mediaTypeMap[downloadIDForTask];
    MediaType mediaType = MediaTypeImage;  // 默认为图片
    if (mediaTypeNumber) {
        mediaType = (MediaType)[mediaTypeNumber integerValue];
    }

    // 处理下载的文件
    // 不用URL的lastPathComponent（抖音CDN URL含 ~: 等非法字符且太长）
    // 改用UUID生成干净文件名，根据mediaType决定扩展名
    NSString *fileName = [NSUUID UUID].UUIDString;
    switch (mediaType) {
        case MediaTypeVideo:
            fileName = [fileName stringByAppendingPathExtension:@"mp4"];
            break;
        case MediaTypeImage:
            fileName = [fileName stringByAppendingPathExtension:@"jpg"];
            break;
        case MediaTypeAudio:
            fileName = [fileName stringByAppendingPathExtension:@"mp3"];
            break;
        case MediaTypeHeic:
            fileName = [fileName stringByAppendingPathExtension:@"heic"];
            break;
    }

    NSURL *tempDir = [NSURL fileURLWithPath:NSTemporaryDirectory()];
    NSURL *destinationURL = [tempDir URLByAppendingPathComponent:fileName];

    NSError *moveError;
    if ([[NSFileManager defaultManager] fileExistsAtPath:destinationURL.path]) {
        [[NSFileManager defaultManager] removeItemAtURL:destinationURL error:nil];
    }

    [[NSFileManager defaultManager] moveItemAtURL:location toURL:destinationURL error:&moveError];
    if (moveError) {
        NSLog(@"[DYYY] moveItemAtURL failed: %@, from=%@, to=%@", moveError, location, destinationURL);
    }

    if (isBatchDownload) {
        if (!moveError) {
            [DYYYManager saveMedia:destinationURL
                         mediaType:mediaType
                        completion:^(BOOL success) {
                          [[DYYYManager shared] incrementCompletedAndUpdateProgressForBatch:batchID success:success];
                          // 串行下载：当前这张保存完成后，启动下一张
                          [self startNextSerialImageForBatch:batchID];
                        }];
        } else {
            [[DYYYManager shared] incrementCompletedAndUpdateProgressForBatch:batchID success:NO];
            // 串行下载：当前这张下载失败，也启动下一张
            [self startNextSerialImageForBatch:batchID];
        }

        [self.downloadTasks removeObjectForKey:downloadIDForTask];
        [self.taskProgressMap removeObjectForKey:downloadIDForTask];
        [self.mediaTypeMap removeObjectForKey:downloadIDForTask];
    } else {
        void (^completionBlock)(BOOL success, NSURL *fileURL) = self.completionBlocks[downloadIDForTask];

        if (!moveError) {
            [self associateFileURL:destinationURL withDownloadID:downloadIDForTask];
            [self.downloadTasks removeObjectForKey:downloadIDForTask];
            [self.taskProgressMap setObject:@1.0f forKey:downloadIDForTask];

            if (completionBlock) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  completionBlock(YES, destinationURL);
                });
            } else {
                [[DYYYManager shared] finalizeDownloadWithFileURL:destinationURL success:YES];
            }
        } else {
            [self.downloadTasks removeObjectForKey:downloadIDForTask];
            if (completionBlock) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  completionBlock(NO, nil);
                });
            }
            [self finalizeDownloadWithID:downloadIDForTask success:NO fileURL:nil];
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (!error) {
        return;  // 成功完成的情况已在didFinishDownloadingToURL处理
    }

    // 处理错误情况
    NSString *downloadIDForTask = nil;
    for (NSString *key in self.downloadTasks.allKeys) {
        NSURLSessionTask *existingTask = self.downloadTasks[key];
        if (existingTask == task) {
            downloadIDForTask = key;
            break;
        }
    }

    if (!downloadIDForTask) {
        return;
    }

    // 检查是否属于批量下载
    NSString *batchID = self.downloadToBatchMap[downloadIDForTask];
    BOOL isBatchDownload = (batchID != nil);

    if (isBatchDownload) {
        // 批量下载错误处理
        [[DYYYManager shared] incrementCompletedAndUpdateProgressForBatch:batchID success:NO];

        // 清理下载任务
        [self.downloadTasks removeObjectForKey:downloadIDForTask];
        [self.taskProgressMap removeObjectForKey:downloadIDForTask];
        [self.mediaTypeMap removeObjectForKey:downloadIDForTask];
        [self.downloadToBatchMap removeObjectForKey:downloadIDForTask];
    } else {
        // 单个下载错误处理
        void (^completionBlock)(BOOL success, NSURL *fileURL) = self.completionBlocks[downloadIDForTask];

        // 检查是否已经通过 didFinishDownloadingToURL 成功接收了文件
        // 如果已经收到文件，说明数据已保存成功，这里的 error 可能是连接关闭等无害错误，不提示"下载失败"
        BOOL alreadyDownloaded = [self.completedDownloadIDs containsObject:downloadIDForTask];

        if (error.code != NSURLErrorCancelled && !alreadyDownloaded) {
            // 网络中断或超时：使用 resumeData 断点续传（最多2次）
            NSInteger retry = [self.downloadRetryCount[downloadIDForTask] integerValue];
            if ((error.code == NSURLErrorNetworkConnectionLost || error.code == NSURLErrorTimedOut) && retry < 2) {
                self.downloadRetryCount[downloadIDForTask] = @(retry + 1);
                
                // 优先使用 resumeData 断点续传
                NSData *resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData];
                NSURLRequest *originalRequest = task.originalRequest;
                NSURL *originalURL = originalRequest.URL;
                
                NSLog(@"[DYYY-Resume] error.code=%ld, resumeData.length=%lu", (long)error.code, (unsigned long)resumeData.length);
                
                if (originalURL) {
                    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
                    cfg.timeoutIntervalForRequest = 60.0;
                    cfg.timeoutIntervalForResource = 600.0;
                    NSURLSession *retrySession = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:[NSOperationQueue mainQueue]];
                    
                    NSURLSessionDownloadTask *retryTask;
                    if (resumeData && resumeData.length > 0) {
                        // 断点续传：从已下载的位置继续
                        retryTask = [retrySession downloadTaskWithResumeData:resumeData];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [DYYYUtils showToast:[NSString stringWithFormat:@"断点续传(%ld)...", (long)(retry + 1)]];
                        });
                    } else {
                        // 无 resumeData：重新下载
                        retryTask = [retrySession downloadTaskWithURL:originalURL];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [DYYYUtils showToast:[NSString stringWithFormat:@"重新下载(%ld)...", (long)(retry + 1)]];
                        });
                    }
                    
                    retryTask.taskDescription = downloadIDForTask;
                    self.downloadTasks[downloadIDForTask] = retryTask;
                    [retryTask resume];
                    return;
                }
            }
            
            NSString *errMsg = [NSString stringWithFormat:@"下载失败(%ld)", (long)error.code];
            if (error.code == NSURLErrorTimedOut) errMsg = @"下载超时，请重试";
            else if (error.code == NSURLErrorNetworkConnectionLost) errMsg = @"网络连接中断，重试失败";
            NSString *finalErrMsg = errMsg;
            dispatch_async(dispatch_get_main_queue(), ^{
              [DYYYUtils showToast:finalErrMsg];
            });
        }

        if (completionBlock && !alreadyDownloaded) {
            dispatch_async(dispatch_get_main_queue(), ^{
              completionBlock(NO, nil);
            });
        }

        if (!alreadyDownloaded) {
            [self finalizeDownloadWithID:downloadIDForTask success:NO fileURL:nil];
            [self.downloadRetryCount removeObjectForKey:downloadIDForTask];
        } else {
            // 已成功下载，只是连接关闭，清理标记即可
            [self.completedDownloadIDs removeObject:downloadIDForTask];
        }
    }
}

// MARK: 以下都是创建保存实况的调用方法
- (void)saveLivePhoto:(NSString *)imageSourcePath videoUrl:(NSString *)videoSourcePath {
    // 串行化保存操作，防止多个实况照片并发保存时 reader/writer/group 被覆盖导致闪退
    dispatch_async(self.livePhotoSaveQueue, ^{
      // 首先检查iOS版本
      if (@available(iOS 15.0, *)) {
        // iOS 15及更高版本使用原有的实现
        NSURL *photoURL = [NSURL fileURLWithPath:imageSourcePath];
        NSURL *videoURL = [NSURL fileURLWithPath:videoSourcePath];
        BOOL available = [PHAssetCreationRequest supportsAssetResourceTypes:@[ @(PHAssetResourceTypePhoto), @(PHAssetResourceTypePairedVideo) ]];
        if (!available) {
            return;
        }
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
          if (status != PHAuthorizationStatusAuthorized) {
              return;
          }
          NSString *identifier = [NSUUID UUID].UUIDString;
          [self useAssetWriter:photoURL
                         video:videoURL
                    identifier:identifier
                      complete:^(BOOL success, NSString *photoFile, NSString *videoFile, NSError *error) {
                        NSURL *photo = [NSURL fileURLWithPath:photoFile];
                        NSURL *video = [NSURL fileURLWithPath:videoFile];
                        [[PHPhotoLibrary sharedPhotoLibrary]
                            performChanges:^{
                              PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
                              // Set originalFilename via PHAssetResourceCreationOptions so iOS populates "添加说明"
                              NSString *captionFilename = [DYYYManager sanitizeCaptionForFilename];
                              PHAssetResourceCreationOptions *photoOptions = [PHAssetResourceCreationOptions new];
                              if (captionFilename) photoOptions.originalFilename = [NSString stringWithFormat:@"%@.heic", captionFilename];
                              PHAssetResourceCreationOptions *videoOptions = [PHAssetResourceCreationOptions new];
                              if (captionFilename) videoOptions.originalFilename = [NSString stringWithFormat:@"%@.mp4", captionFilename];
                              [request addResourceWithType:PHAssetResourceTypePhoto fileURL:photo options:photoOptions];
                              [request addResourceWithType:PHAssetResourceTypePairedVideo fileURL:video options:videoOptions];
                              // Set localizedTitle to empty so caption doesn't appear in title area
                              @try { [request setValue:@"" forKey:@"localizedTitle"]; } @catch (NSException *e) {}
                            }
                            completionHandler:^(BOOL success, NSError *_Nullable error) {
                              dispatch_async(dispatch_get_main_queue(), ^{
                                if (success) {
                                    // 删除临时文件
                                    [[NSFileManager defaultManager] removeItemAtPath:imageSourcePath error:nil];
                                    [[NSFileManager defaultManager] removeItemAtPath:videoSourcePath error:nil];
                                    [[NSFileManager defaultManager] removeItemAtPath:photoFile error:nil];
                                    [[NSFileManager defaultManager] removeItemAtPath:videoFile error:nil];
                                    
                                    // Caption for live photos: write caption via KVC after save
                                    [DYYYManager writeCaptionToLatestAsset];
                                }
                              });
                            }];
                      }];
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
          [DYYYUtils showToast:@"当前iOS版本不支持实况照片，将分别保存图片和视频"];
        });
    }
    }); // livePhotoSaveQueue
}

- (void)useAssetWriter:(NSURL *)photoURL video:(NSURL *)videoURL identifier:(NSString *)identifier complete:(void (^)(BOOL success, NSString *photoFile, NSString *videoFile, NSError *error))complete {
    NSString *photoName = [photoURL lastPathComponent];
    NSString *photoFile = [self filePathFromTmp:photoName];
    [self addMetadataToPhoto:photoURL outputFile:photoFile identifier:identifier];
    NSString *videoName = [videoURL lastPathComponent];
    NSString *videoFile = [self filePathFromTmp:videoName];
    
    // 使用局部变量而非共享ivar，避免多个实况并发保存时互相覆盖
    __block AVAssetReader *localReader = nil;
    __block AVAssetWriter *localWriter = nil;
    __block dispatch_group_t localGroup = nil;
    __block dispatch_queue_t localQueue = nil;
    
    [self addMetadataToVideo:videoURL outputFile:videoFile identifier:identifier readerPtr:&localReader writerPtr:&localWriter groupPtr:&localGroup queuePtr:&localQueue];
    
    if (!localGroup)
        return;
    dispatch_group_notify(localGroup, dispatch_get_main_queue(), ^{
      if (!localReader || !localWriter) {
          if (complete)
              complete(NO, photoFile, videoFile, nil);
          return;
      }
      [localReader cancelReading];
      [localWriter finishWritingWithCompletionHandler:^{
        if (complete)
            complete(YES, photoFile, videoFile, nil);
      }];
    });
}
- (void)addMetadataToVideo:(NSURL *)videoURL outputFile:(NSString *)outputFile identifier:(NSString *)identifier readerPtr:(AVAssetReader *__autoreleasing *)readerPtr writerPtr:(AVAssetWriter *__autoreleasing *)writerPtr groupPtr:(dispatch_group_t __autoreleasing *)groupPtr queuePtr:(dispatch_queue_t __autoreleasing *)queuePtr {
    NSError *error = nil;
    AVAsset *asset = [AVAsset assetWithURL:videoURL];
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (error || !reader) {
        NSLog(@"[DYYY-LivePhoto] addMetadataToVideo: reader init failed: %@", error);
        [[NSFileManager defaultManager] removeItemAtPath:outputFile error:nil];
        [[NSFileManager defaultManager] copyItemAtURL:videoURL toURL:[NSURL fileURLWithPath:outputFile] error:nil];
        // 创建一个立即完成的 group
        dispatch_group_t g = dispatch_group_create();
        dispatch_group_enter(g);
        dispatch_group_leave(g);
        *groupPtr = g;
        return;
    }
    NSMutableArray<AVMetadataItem *> *metadata = asset.metadata.mutableCopy;
    AVMetadataItem *item = [self createContentIdentifierMetadataItem:identifier];
    [metadata addObject:item];
    NSURL *videoFileURL = [NSURL fileURLWithPath:outputFile];
    [self deleteFile:outputFile];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:videoFileURL fileType:AVFileTypeQuickTimeMovie error:&error];
    if (error || !writer) {
        NSLog(@"[DYYY-LivePhoto] addMetadataToVideo: writer init failed: %@", error);
        [[NSFileManager defaultManager] removeItemAtPath:outputFile error:nil];
        [[NSFileManager defaultManager] copyItemAtURL:videoURL toURL:videoFileURL error:nil];
        dispatch_group_t g = dispatch_group_create();
        dispatch_group_enter(g);
        dispatch_group_leave(g);
        *groupPtr = g;
        return;
    }
    [writer setMetadata:metadata];
    NSArray<AVAssetTrack *> *tracks = [asset tracks];
    for (AVAssetTrack *track in tracks) {
        NSDictionary *readerOutputSettings = nil;
        NSDictionary *writerOuputSettings = nil;
        if ([track.mediaType isEqualToString:AVMediaTypeAudio]) {
            readerOutputSettings = @{AVFormatIDKey : @(kAudioFormatLinearPCM)};
            writerOuputSettings = @{AVFormatIDKey : @(kAudioFormatMPEG4AAC), AVSampleRateKey : @(44100), AVNumberOfChannelsKey : @(2), AVEncoderBitRateKey : @(128000)};
        }
        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:readerOutputSettings];
        AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:track.mediaType outputSettings:writerOuputSettings];
        if ([reader canAddOutput:output] && [writer canAddInput:input]) {
            [reader addOutput:output];
            [writer addInput:input];
        }
    }
    AVAssetWriterInput *input = [self createStillImageTimeAssetWriterInput];
    AVAssetWriterInputMetadataAdaptor *adaptor = [AVAssetWriterInputMetadataAdaptor assetWriterInputMetadataAdaptorWithAssetWriterInput:input];
    if ([writer canAddInput:input]) {
        [writer addInput:input];
    }
    [writer startWriting];
    [writer startSessionAtSourceTime:kCMTimeZero];
    [reader startReading];
    AVMetadataItem *timedItem = [self createStillImageTimeMetadataItem];
    CMTimeRange timedRange = CMTimeRangeMake(kCMTimeZero, CMTimeMake(1, 100));
    AVTimedMetadataGroup *timedMetadataGroup = [[AVTimedMetadataGroup alloc] initWithItems:@[ timedItem ] timeRange:timedRange];
    [adaptor appendTimedMetadataGroup:timedMetadataGroup];
    
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_group_t group = dispatch_group_create();
    
    for (NSInteger i = 0; i < reader.outputs.count; ++i) {
        dispatch_group_enter(group);
        // 通过block捕获局部变量，不再使用共享ivar
        AVAssetReaderOutput *output = reader.outputs[i];
        AVAssetWriterInput *writerInput = writer.inputs[i];
        [writerInput requestMediaDataWhenReadyOnQueue:queue
                                 usingBlock:^{
                                   while (writerInput.readyForMoreMediaData) {
                                       AVAssetReaderStatus status = reader.status;
                                       CMSampleBufferRef buffer = NULL;
                                       if ((status == AVAssetReaderStatusReading) && (buffer = [output copyNextSampleBuffer])) {
                                           BOOL success = [writerInput appendSampleBuffer:buffer];
                                           CFRelease(buffer);
                                           if (!success) {
                                               [writerInput markAsFinished];
                                               dispatch_group_leave(group);
                                               return;
                                           }
                                       } else {
                                           [writerInput markAsFinished];
                                           dispatch_group_leave(group);
                                           return;
                                       }
                                   }
                                 }];
    }
    
    *readerPtr = reader;
    *writerPtr = writer;
    *groupPtr = group;
    *queuePtr = queue;
}

- (void)addMetadataToPhoto:(NSURL *)photoURL outputFile:(NSString *)outputFile identifier:(NSString *)identifier {
    NSData *rawData = [NSData dataWithContentsOfURL:photoURL];
    if (!rawData || rawData.length == 0) {
        NSLog(@"[DYYY-LivePhoto] addMetadataToPhoto: photo data is nil or empty");
        [[NSFileManager defaultManager] copyItemAtURL:photoURL toURL:[NSURL fileURLWithPath:outputFile] error:nil];
        return;
    }
    NSMutableData *data = rawData.mutableCopy;
    UIImage *image = [UIImage imageWithData:data];
    if (!image || !image.CGImage) {
        NSLog(@"[DYYY-LivePhoto] addMetadataToPhoto: cannot create image from data");
        [data writeToFile:outputFile atomically:YES];
        return;
    }
    CGImageRef imageRef = image.CGImage;
    NSDictionary *imageMetadata = @{(NSString *)kCGImagePropertyMakerAppleDictionary : @{@"17" : identifier}};
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((CFMutableDataRef)data, kUTTypeJPEG, 1, nil);
    if (dest) {
        CGImageDestinationAddImage(dest, imageRef, (CFDictionaryRef)imageMetadata);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    [data writeToFile:outputFile atomically:YES];
}

- (AVMetadataItem *)createContentIdentifierMetadataItem:(NSString *)identifier {
    AVMutableMetadataItem *item = [AVMutableMetadataItem metadataItem];
    item.keySpace = AVMetadataKeySpaceQuickTimeMetadata;
    item.key = AVMetadataQuickTimeMetadataKeyContentIdentifier;
    item.value = identifier;
    return item;
}

- (AVAssetWriterInput *)createStillImageTimeAssetWriterInput {
    NSArray *spec = @[ @{
        (NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier : @"mdta/com.apple.quicktime.still-image-time",
        (NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType : (NSString *)kCMMetadataBaseDataType_SInt8
    } ];
    CMFormatDescriptionRef desc = NULL;
    CMMetadataFormatDescriptionCreateWithMetadataSpecifications(kCFAllocatorDefault, kCMMetadataFormatType_Boxed, (__bridge CFArrayRef)spec, &desc);
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeMetadata outputSettings:nil sourceFormatHint:desc];
    return input;
}

- (AVMetadataItem *)createStillImageTimeMetadataItem {
    AVMutableMetadataItem *item = [AVMutableMetadataItem metadataItem];
    item.keySpace = AVMetadataKeySpaceQuickTimeMetadata;
    item.key = @"com.apple.quicktime.still-image-time";
    item.value = @(-1);
    item.dataType = (NSString *)kCMMetadataBaseDataType_SInt8;
    return item;
}
- (NSString *)filePathFromTmp:(NSString *)filename {
    NSString *tempPath = NSTemporaryDirectory();
    NSString *filePath = [tempPath stringByAppendingPathComponent:filename];
    return filePath;
}

- (void)deleteFile:(NSString *)file {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:file]) {
        [fm removeItemAtPath:file error:nil];
    }
}

#pragma mark - 评论区图片保存

+ (void)saveCommentImages:(NSArray *)imageModels
             currentIndex:(NSInteger)currentIndex
               completion:(void (^)(NSInteger successCount, NSInteger livePhotoCount, NSInteger failedCount))completion {
    if (!imageModels || imageModels.count == 0) {
        if (completion) completion(0, 0, 0);
        return;
    }
    
    // 确定要保存的图片
    NSArray *imagesToSave = nil;
    if (currentIndex >= 0 && currentIndex < (NSInteger)imageModels.count) {
        imagesToSave = @[imageModels[currentIndex]];
    } else {
        imagesToSave = imageModels;
    }
    
    // 分离普通图片和实况照片
    NSMutableArray *normalImages = [NSMutableArray array];
    NSMutableArray *livePhotos = [NSMutableArray array];
    
    for (id imageModel in imagesToSave) {
        @try {
            // 获取图片 URL - originUrl 和 mediumUrl 都是 AWEURLModel 类型
            NSString *imageUrlStr = nil;
            
            // 首先尝试 originUrl
            AWEURLModel *originUrlModel = [imageModel valueForKey:@"originUrl"];
            if (originUrlModel) {
                NSArray *urlList = [originUrlModel originURLList];
                if (urlList && urlList.count > 0) {
                    imageUrlStr = urlList.firstObject;
                }
            }
            
            // 如果 originUrl 没有获取到，尝试 mediumUrl
            if (!imageUrlStr) {
                AWEURLModel *mediumUrlModel = [imageModel valueForKey:@"mediumUrl"];
                if (mediumUrlModel) {
                    NSArray *urlList = [mediumUrlModel originURLList];
                    if (urlList && urlList.count > 0) {
                        imageUrlStr = urlList.firstObject;
                    }
                }
            }
            
            NSLog(@"[DYYY] 评论图片URL: %@", imageUrlStr);
            
            if (!imageUrlStr || imageUrlStr.length == 0) {
                NSLog(@"[DYYY] 无法获取图片URL，imageModel: %@", imageModel);
                continue;
            }
            
            // 检查是否是实况照片
            id livePhotoModel = [imageModel valueForKey:@"livePhotoModel"];
            if (livePhotoModel) {
                NSArray *videoUrls = [livePhotoModel valueForKey:@"videoUrl"];
                if (videoUrls && videoUrls.count > 0) {
                    NSString *videoUrlStr = videoUrls.firstObject;
                    if (videoUrlStr && videoUrlStr.length > 0) {
                        // 传入字符串而不是 NSURL，与 downloadAllLivePhotosWithProgress 期望的格式一致
                        [livePhotos addObject:@{
                            @"imageURL": imageUrlStr,
                            @"videoURL": videoUrlStr
                        }];
                        continue;
                    }
                }
            }
            
            // 普通图片 - 存储字符串而不是 NSURL
            [normalImages addObject:imageUrlStr];
        } @catch (NSException *e) {
            NSLog(@"[DYYY] 解析评论图片失败: %@", e);
        }
    }
    
    NSLog(@"[DYYY] 解析完成: 普通图片=%lu, 实况照片=%lu", (unsigned long)normalImages.count, (unsigned long)livePhotos.count);
    
    // 如果都没有解析到有效URL，直接返回失败
    if (normalImages.count == 0 && livePhotos.count == 0) {
        if (completion) completion(0, 0, (NSInteger)imagesToSave.count);
        return;
    }
    
    __block NSInteger successCount = 0;
    __block NSInteger livePhotoCount = 0;
    __block NSInteger failedCount = 0;
    
    dispatch_group_t group = dispatch_group_create();
    
    // 保存普通图片
    if (normalImages.count > 0) {
        dispatch_group_enter(group);
        [self downloadAllImagesWithProgress:[normalImages mutableCopy]
                                   progress:nil
                                 completion:^(NSInteger imgSuccess, NSInteger imgTotal) {
            successCount += imgSuccess;
            failedCount += (imgTotal - imgSuccess);
            dispatch_group_leave(group);
        }];
    }
    
    // 保存实况照片
    if (livePhotos.count > 0) {
        dispatch_group_enter(group);
        [self downloadAllLivePhotosWithProgress:livePhotos
                                       progress:nil
                                     completion:^(NSInteger lpSuccess, NSInteger lpTotal) {
            successCount += lpSuccess;
            livePhotoCount = lpSuccess;
            failedCount += (lpTotal - lpSuccess);
            dispatch_group_leave(group);
        }];
    }
    
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        // 写入作者信息元数据（最后一张图片会有完整信息）
        if (successCount > 0) {
            [DYYYManager writeCaptionToLatestAsset];
            NSLog(@"[DYYY-Caption] 评论区图片保存完成，已写入作者信息元数据");
        }
        if (completion) {
            completion(successCount, livePhotoCount, failedCount);
        }
    });
}

+ (void)downloadAllLivePhotos:(NSArray<NSDictionary *> *)livePhotos {
    if (livePhotos.count == 0) {
        return;
    }
    // 每次批量下载前解锁，确保新一批图片用新的作者信息
    [DYYYManager shared].authorInfoLocked = NO;
    [self downloadAllLivePhotosWithProgress:livePhotos
                                   progress:nil
                                 completion:^(NSInteger successCount, NSInteger totalCount){
                                 }];
}
+ (void)downloadAllLivePhotosWithProgress:(NSArray<NSDictionary *> *)livePhotos
                                 progress:(void (^)(NSInteger current, NSInteger total))progressBlock
                               completion:(void (^)(NSInteger successCount, NSInteger totalCount))completion {
    if (livePhotos.count == 0) {
        if (completion) {
            completion(0, 0);
        }
        return;
    }

    // 检查iOS版本是否支持实况照片
    BOOL supportsLivePhoto = NO;
    if (@available(iOS 15.0, *)) {
        supportsLivePhoto = YES;
    }

    if (!supportsLivePhoto) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [DYYYUtils showToast:@"当前iOS版本不支持实况照片"];
          if (completion) {
              completion(0, livePhotos.count);
          }
        });
        return;
    }

    // 创建进度显示UI
    dispatch_async(dispatch_get_main_queue(), ^{
      CGRect screenBounds = [UIScreen mainScreen].bounds;
      DYYYToast *progressView = [[DYYYToast alloc] initWithFrame:screenBounds];
      [progressView show];

      progressView.cancelBlock = ^{
        [self cancelAllDownloads];
        if (completion) {
            completion(0, livePhotos.count);
        }
      };

      NSMutableArray<NSDictionary *> *downloadedFiles = [NSMutableArray arrayWithCapacity:livePhotos.count];
      for (int i = 0; i < livePhotos.count; i++) {
          [downloadedFiles addObject:@{@"imageURL" : livePhotos[i][@"imageURL"], @"videoURL" : livePhotos[i][@"videoURL"], @"imagePath" : [NSNull null], @"videoPath" : [NSNull null]}];
      }

      // 进度计算 - 为三个阶段分配权重
      NSInteger totalSteps = livePhotos.count * 10;  // 每个实况照片总共10步(4+4+2)
      __block NSInteger completedSteps = 0;
      __block NSInteger phase = 0;  // 0:下载图片阶段，1:下载视频阶段，2:合成阶段

      // 创建临时目录
      NSString *livePhotoPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"LivePhotoBatch"];
      NSFileManager *fileManager = [NSFileManager defaultManager];
      [fileManager createDirectoryAtPath:livePhotoPath withIntermediateDirectories:YES attributes:nil error:nil];

      // 更新进度的block
      void (^updateProgress)(NSString *) = ^(NSString *statusText) {
        float progress = 0;
        @synchronized(self) {
            progress = (float)completedSteps / totalSteps;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
          [progressView setProgress:progress];
          if (progressBlock) {
              NSInteger steps = 0;
              @synchronized(self) {
                  steps = completedSteps;
              }
              progressBlock(steps, totalSteps);
          }
        });
      };

      // 下载完成后的处理
      void (^finishProcess)(void) = ^{
        __block NSInteger successCount = 0;

        // 请求相册权限
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
          if (status == PHAuthorizationStatusAuthorized) {
              dispatch_queue_t processQueue = dispatch_queue_create("com.dyyy.livephoto.process", DISPATCH_QUEUE_SERIAL);
              dispatch_group_t saveGroup = dispatch_group_create();

              NSInteger validFileCount = 0;
              for (NSDictionary *fileInfo in downloadedFiles) {
                  NSString *imagePath = fileInfo[@"imagePath"];
                  NSString *videoPath = fileInfo[@"videoPath"];

                  if (![imagePath isKindOfClass:[NSNull class]] && ![videoPath isKindOfClass:[NSNull class]] && [fileManager fileExistsAtPath:imagePath] && [fileManager fileExistsAtPath:videoPath]) {
                      validFileCount++;
                  }
              }

              if (validFileCount == 0) {
                  dispatch_async(dispatch_get_main_queue(), ^{
                    progressView.allowSuccessAnimation = NO;
                    [progressView dismiss];
                    [fileManager removeItemAtPath:livePhotoPath error:nil];
                    if (completion) {
                        completion(0, livePhotos.count);
                    }
                  });
                  return;
              }

              float progressPerItem = (float)(livePhotos.count * 2) / totalSteps;
              __block NSInteger processedCount = 0;

              for (NSDictionary *fileInfo in downloadedFiles) {
                  NSString *imagePath = fileInfo[@"imagePath"];
                  NSString *videoPath = fileInfo[@"videoPath"];

                  if (![imagePath isKindOfClass:[NSNull class]] && ![videoPath isKindOfClass:[NSNull class]] && [fileManager fileExistsAtPath:imagePath] && [fileManager fileExistsAtPath:videoPath]) {
                      dispatch_group_enter(saveGroup);

                      dispatch_async(processQueue, ^{
                        // 生成唯一标识符
                        NSString *identifier = [NSUUID UUID].UUIDString;

                        // 创建每个任务的专属实例变量，避免共享变量冲突
                        AVAssetReader *localReader = nil;
                        AVAssetWriter *localWriter = nil;
                        dispatch_queue_t localQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
                        dispatch_group_t localGroup = dispatch_group_create();

                        // 处理照片和元数据
                        NSString *photoName = [imagePath lastPathComponent];
                        NSString *photoFile = [[DYYYManager shared] filePathFromTmp:photoName];
                        [[DYYYManager shared] addMetadataToPhoto:[NSURL fileURLWithPath:imagePath] outputFile:photoFile identifier:identifier];

                        // 处理视频和元数据
                        NSString *videoName = [videoPath lastPathComponent];
                        NSString *videoFile = [[DYYYManager shared] filePathFromTmp:videoName];

                        // 使用本地变量而非全局共享变量
                        [[DYYYManager shared] addMetadataToVideoWithLocalVars:[NSURL fileURLWithPath:videoPath]
                                                                   outputFile:videoFile
                                                                   identifier:identifier
                                                                       reader:&localReader
                                                                       writer:&localWriter
                                                                        queue:localQueue
                                                                        group:localGroup
                                                                     complete:^(BOOL success, NSString *photoFile, NSString *videoFile, NSError *error) {
                                                                       if (success) {
                                                                           NSURL *photo = [NSURL fileURLWithPath:photoFile];
                                                                           NSURL *video = [NSURL fileURLWithPath:videoFile];

                                                                           [[PHPhotoLibrary sharedPhotoLibrary]
                                                                               performChanges:^{
                                                                                 PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
                                                                                 NSString *captionFilename = [DYYYManager sanitizeCaptionForFilename];
                                                                                 PHAssetResourceCreationOptions *photoOpts = [PHAssetResourceCreationOptions new];
                                                                                 if (captionFilename) photoOpts.originalFilename = [NSString stringWithFormat:@"%@.heic", captionFilename];
                                                                                 PHAssetResourceCreationOptions *videoOpts = [PHAssetResourceCreationOptions new];
                                                                                 if (captionFilename) videoOpts.originalFilename = [NSString stringWithFormat:@"%@.mp4", captionFilename];
                                                                                 [request addResourceWithType:PHAssetResourceTypePhoto fileURL:photo options:photoOpts];
                                                                                 [request addResourceWithType:PHAssetResourceTypePairedVideo fileURL:video options:videoOpts];
                                                                                 @try { [request setValue:@"" forKey:@"localizedTitle"]; } @catch (NSException *e) {}
                                                                               }
                                                                               completionHandler:^(BOOL success, NSError *_Nullable error) {
                                                                                 if (success) {
                                                                                     successCount++;
                                                                                 }

                                                                                 NSArray *filesToDelete = @[ imagePath, videoPath, photoFile, videoFile ];
                                                                                 for (NSString *path in filesToDelete) {
                                                                                     [fileManager removeItemAtPath:path error:nil];
                                                                                 }

                                                                                 // 增加进度步数
                                                                                 processedCount++;
                                                                                 @synchronized(self) { completedSteps += 2; }  // 每完成一个合成任务增加2步
                                                                                 updateProgress([NSString stringWithFormat:@"已合成 %ld/%ld", (long)processedCount, (long)validFileCount]);

                                                                                 dispatch_group_leave(saveGroup);
                                                                               }];
                                                                       } else {
                                                                           [fileManager removeItemAtPath:imagePath error:nil];
                                                                           [fileManager removeItemAtPath:videoPath error:nil];
                                                                           if (photoFile)
                                                                               [fileManager removeItemAtPath:photoFile error:nil];
                                                                           if (videoFile)
                                                                               [fileManager removeItemAtPath:videoFile error:nil];

                                                                           // 增加进度步数（即使失败也增加）
                                                                           processedCount++;
                                                                           @synchronized(self) { completedSteps += 2; }
                                                                           updateProgress([NSString stringWithFormat:@"已合成 %ld/%ld", (long)processedCount, (long)validFileCount]);

                                                                           dispatch_group_leave(saveGroup);
                                                                       }
                                                                     }];
                      });
                  }
              }

              dispatch_group_notify(saveGroup, dispatch_get_main_queue(), ^{
                progressView.allowSuccessAnimation = (successCount > 0 && successCount == validFileCount);
                [progressView dismiss];

                [fileManager removeItemAtPath:livePhotoPath error:nil];

                if (completion) {
                    completion(successCount, livePhotos.count);
                }
              });
          } else {
              // 没有相册权限
              dispatch_async(dispatch_get_main_queue(), ^{
                progressView.allowSuccessAnimation = NO;
                [progressView dismiss];
                [DYYYUtils showToast:@"没有相册权限，无法保存实况照片"];

                [fileManager removeItemAtPath:livePhotoPath error:nil];

                if (completion) {
                    completion(0, livePhotos.count);
                }
              });
          }
        }];
      };

      // 第一阶段：批量下载所有图片
      dispatch_group_t imageDownloadGroup = dispatch_group_create();
      updateProgress(@"正在下载图片...");

      for (NSInteger i = 0; i < livePhotos.count; i++) {
          NSDictionary *livePhoto = downloadedFiles[i];
          NSString *imageURLString = livePhoto[@"imageURL"];
          NSURL *imageURL = [NSURL URLWithString:imageURLString];

          if (!imageURL) {
              completedSteps += 4;  // 图片下载占4步
              continue;
          }

          dispatch_group_enter(imageDownloadGroup);

          // 创建文件路径
          NSString *uniqueID = [NSUUID UUID].UUIDString;
          // 根据图片URL后缀决定文件扩展名（原画质URL可能是.jpeg）
          NSString *imageExt = @"heic";
          NSString *imgURLLower = imageURLString.lowercaseString;
          if ([imgURLLower containsString:@".jpeg"] || [imgURLLower containsString:@".jpg"]) {
              imageExt = @"jpeg";
          } else if ([imgURLLower containsString:@".webp"]) {
              imageExt = @"webp";
          }
          NSString *imagePath = [livePhotoPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", uniqueID, imageExt]];

          // 配置下载会话
          NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
          configuration.timeoutIntervalForRequest = 60.0;
          configuration.timeoutIntervalForResource = 600.0;
          NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];

          NSURLSessionDataTask *imageTask = [session dataTaskWithURL:imageURL
                                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                     if (!error && data) {
                                                         if ([data writeToFile:imagePath atomically:YES]) {
                                                             @synchronized(downloadedFiles) {
                                                                 NSMutableDictionary *updatedInfo = [downloadedFiles[i] mutableCopy];
                                                                 updatedInfo[@"imagePath"] = imagePath;
                                                                 downloadedFiles[i] = updatedInfo;
                                                             }
                                                         }
                                                     }

                                                     @synchronized(self) { completedSteps += 4; }  // 图片下载占4步
                                                     updateProgress([NSString stringWithFormat:@"已下载图片 %ld/%ld", (long)(i + 1), (long)livePhotos.count]);
                                                     dispatch_group_leave(imageDownloadGroup);
                                                   }];

          [imageTask resume];
      }

      // 所有图片下载完成后，开始下载视频
      dispatch_group_notify(imageDownloadGroup, dispatch_get_main_queue(), ^{
        phase = 1;  // 进入视频下载阶段
        updateProgress(@"正在下载视频...");

        dispatch_group_t videoDownloadGroup = dispatch_group_create();

        for (NSInteger i = 0; i < livePhotos.count; i++) {
            NSDictionary *fileInfo = downloadedFiles[i];

            // 只处理图片下载成功的项
            if ([fileInfo[@"imagePath"] isKindOfClass:[NSNull class]]) {
                completedSteps += 4;  // 视频下载占4步
                continue;
            }

            NSString *videoURLString = fileInfo[@"videoURL"];
            NSURL *videoURL = [NSURL URLWithString:videoURLString];

            if (!videoURL) {
                completedSteps += 4;  // 视频下载占4步
                continue;
            }

            dispatch_group_enter(videoDownloadGroup);

            // 使用与图片相同的ID但不同的扩展名
            NSString *imagePath = fileInfo[@"imagePath"];
            NSString *baseName = [[imagePath lastPathComponent] stringByDeletingPathExtension];
            NSString *videoPath = [livePhotoPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.mp4", baseName]];

            // 配置下载会话
            NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
            configuration.timeoutIntervalForRequest = 60.0;
            configuration.timeoutIntervalForResource = 600.0;
            NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];

            NSURLSessionDataTask *videoTask = [session dataTaskWithURL:videoURL
                                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                       if (!error && data) {
                                                           if ([data writeToFile:videoPath atomically:YES]) {
                                                               @synchronized(downloadedFiles) {
                                                                   NSMutableDictionary *updatedInfo = [downloadedFiles[i] mutableCopy];
                                                                   updatedInfo[@"videoPath"] = videoPath;
                                                                   downloadedFiles[i] = updatedInfo;
                                                               }
                                                           }
                                                       }

                                                       @synchronized(self) { completedSteps += 4; }  // 视频下载占4步
                                                       updateProgress([NSString stringWithFormat:@"已下载视频 %ld/%ld", (long)(i + 1), (long)livePhotos.count]);
                                                       dispatch_group_leave(videoDownloadGroup);
                                                     }];

            [videoTask resume];
        }

        // 所有视频下载完成后，开始合成实况照片
        dispatch_group_notify(videoDownloadGroup, dispatch_get_main_queue(), ^{
          phase = 2;  // 进入合成阶段
          finishProcess();
        });
      });
    });
}

// 使用本地变量处理视频
- (void)addMetadataToVideoWithLocalVars:(NSURL *)videoURL
                             outputFile:(NSString *)outputFile
                             identifier:(NSString *)identifier
                                 reader:(AVAssetReader **)readerPtr
                                 writer:(AVAssetWriter **)writerPtr
                                  queue:(dispatch_queue_t)queue
                                  group:(dispatch_group_t)group
                               complete:(void (^)(BOOL success, NSString *photoFile, NSString *videoFile, NSError *error))complete {
    NSError *error = nil;
    AVAsset *asset = [AVAsset assetWithURL:videoURL];
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (error || !reader) {
        if (complete)
            complete(NO, nil, nil, error);
        return;
    }

    *readerPtr = reader;

    NSMutableArray<AVMetadataItem *> *metadata = asset.metadata.mutableCopy;
    AVMetadataItem *item = [self createContentIdentifierMetadataItem:identifier];
    [metadata addObject:item];
    NSURL *videoFileURL = [NSURL fileURLWithPath:outputFile];
    [self deleteFile:outputFile];

    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:videoFileURL fileType:AVFileTypeQuickTimeMovie error:&error];
    if (error || !writer) {
        if (complete)
            complete(NO, nil, nil, error);
        return;
    }

    *writerPtr = writer;
    [writer setMetadata:metadata];

    NSArray<AVAssetTrack *> *tracks = [asset tracks];
    for (AVAssetTrack *track in tracks) {
        NSDictionary *readerOutputSettings = nil;
        NSDictionary *writerOuputSettings = nil;
        if ([track.mediaType isEqualToString:AVMediaTypeAudio]) {
            readerOutputSettings = @{AVFormatIDKey : @(kAudioFormatLinearPCM)};
            writerOuputSettings = @{AVFormatIDKey : @(kAudioFormatMPEG4AAC), AVSampleRateKey : @(44100), AVNumberOfChannelsKey : @(2), AVEncoderBitRateKey : @(128000)};
        }

        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:readerOutputSettings];
        AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:track.mediaType outputSettings:writerOuputSettings];

        if ([reader canAddOutput:output] && [writer canAddInput:input]) {
            [reader addOutput:output];
            [writer addInput:input];
        }
    }

    AVAssetWriterInput *input = [self createStillImageTimeAssetWriterInput];
    AVAssetWriterInputMetadataAdaptor *adaptor = [AVAssetWriterInputMetadataAdaptor assetWriterInputMetadataAdaptorWithAssetWriterInput:input];
    if ([writer canAddInput:input]) {
        [writer addInput:input];
    }

    [writer startWriting];
    [writer startSessionAtSourceTime:kCMTimeZero];
    [reader startReading];

    AVMetadataItem *timedItem = [self createStillImageTimeMetadataItem];
    CMTimeRange timedRange = CMTimeRangeMake(kCMTimeZero, CMTimeMake(1, 100));
    AVTimedMetadataGroup *timedMetadataGroup = [[AVTimedMetadataGroup alloc] initWithItems:@[ timedItem ] timeRange:timedRange];
    [adaptor appendTimedMetadataGroup:timedMetadataGroup];

    for (NSInteger i = 0; i < reader.outputs.count; ++i) {
        dispatch_group_enter(group);
        [self writeTrackWithLocalVars:i reader:reader writer:writer queue:queue group:group];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
      [reader cancelReading];
      [writer finishWritingWithCompletionHandler:^{
        AVAssetWriterStatus status = writer.status;
        if (status == AVAssetWriterStatusCompleted) {
            NSString *photoName = [[videoURL lastPathComponent] stringByDeletingPathExtension];
            NSString *photoFile = [self filePathFromTmp:[photoName stringByAppendingPathExtension:@"heic"]];
            if (complete)
                complete(YES, photoFile, outputFile, nil);
        } else {
            if (complete)
                complete(NO, nil, nil, writer.error);
        }
      }];
    });
}

// 处理视频曲目的写入
- (void)writeTrackWithLocalVars:(NSInteger)trackIndex reader:(AVAssetReader *)reader writer:(AVAssetWriter *)writer queue:(dispatch_queue_t)queue group:(dispatch_group_t)group {
    AVAssetReaderOutput *output = reader.outputs[trackIndex];
    AVAssetWriterInput *input = writer.inputs[trackIndex];

    [input requestMediaDataWhenReadyOnQueue:queue
                                 usingBlock:^{
                                   while (input.readyForMoreMediaData) {
                                       AVAssetReaderStatus status = reader.status;
                                       CMSampleBufferRef buffer = NULL;
                                       if ((status == AVAssetReaderStatusReading) && (buffer = [output copyNextSampleBuffer])) {
                                           BOOL success = [input appendSampleBuffer:buffer];
                                           CFRelease(buffer);
                                           if (!success) {
                                               [input markAsFinished];
                                               dispatch_group_leave(group);
                                               return;
                                           }
                                       } else {
                                           [input markAsFinished];
                                           dispatch_group_leave(group);
                                           return;
                                       }
                                   }
                                 }];
}

#pragma mark - Action Sheet Header

+ (id)disclaimerActionWithCount:(NSInteger)actionCount {
    @try {
        NSString *title = @"";
        if (actionCount > 0) {
            title = [NSString stringWithFormat:@"共%ld个可用质量选项", (long)actionCount];
        } else {
            title = @"免责声明";
        }
        return [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:title imgName:nil handler:^{
            // 点击无操作
        }];
    } @catch (NSException *e) {
        NSLog(@"[DYYY] create disclaimer action exception: %@", e);
        return nil;
    }
}

+ (id)disclaimerDetailAction {
    @try {
        NSString *title = @"免责声明:下载的视频仅供个人学习";
        return [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:title imgName:nil handler:^{
            // 点击无操作
        }];
    } @catch (NSException *e) {
        NSLog(@"[DYYY] create disclaimer detail action exception: %@", e);
        return nil;
    }
}

+ (void)addDisclaimerHeaderToActionSheet:(id)actionSheet actionCount:(NSInteger)actionCount {
    if (!actionSheet) return;
    @try {
        if ([actionSheet respondsToSelector:@selector(setHeaderTitleText:)]) {
            NSMutableString *headerText = [NSMutableString string];
            if (actionCount > 0) {
                [headerText appendFormat:@"共%ld个可用质量选项\n", (long)actionCount];
            }
            [headerText appendString:@"免责声明:下载的视频仅供个人学习"];
            // 去除首尾空白
            NSString *result = [headerText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (result.length > 0) {
                [actionSheet setHeaderTitleText:result];
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[DYYY] setHeaderTitleText exception: %@", e);
    }
}

+ (void)addDisclaimerHeaderToActionSheet:(id)actionSheet {
    [self addDisclaimerHeaderToActionSheet:actionSheet actionCount:0];
}

+ (void)parseAndDownloadVideoWithShareLink:(NSString *)shareLink apiKey:(NSString *)apiKey {
    [self parseAndDownloadVideoWithShareLink:shareLink apiKey:apiKey retryCount:0];
}



+ (void)parseAndDownloadVideoWithShareLink:(NSString *)shareLink apiKey:(NSString *)apiKey retryCount:(NSInteger)retryCount {
    if (shareLink.length == 0) {
        [DYYYUtils showToast:@"无法获取分享链接"];
        return;
    }
    
    // 使用通用API
    NSString *customAPI = apiKey.length > 0 ? apiKey : [[NSUserDefaults standardUserDefaults] stringForKey:@"DYYYInterfaceDownload"];
    if (customAPI.length == 0) {
        [DYYYUtils showToast:@"请先在设置里填写API地址"];
        return;
    }
    NSString *apiUrl = [NSString stringWithFormat:@"%@%@", customAPI,
              [shareLink stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    NSLog(@"[DYYY-API] 使用通用API: %@", apiUrl);

    NSURL *url = [NSURL URLWithString:apiUrl];
    if (!url) {
        [DYYYUtils showToast:@"API地址格式错误"];
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30;
    
    NSURLSession *session = [NSURLSession sharedSession];

    NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request
                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                  dispatch_async(dispatch_get_main_queue(), ^{
                                                    @try {
                                                    // 检查HTTP状态码（404等不会触发NSError）
                                                    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                                                    if ([httpResponse isKindOfClass:[NSHTTPURLResponse class]] && httpResponse.statusCode >= 400) {
                                                        if (retryCount < 2) {
                                                            [DYYYUtils showToast:[NSString stringWithFormat:@"接口返回错误(%ld)，正在重试...", (long)httpResponse.statusCode]];
                                                            [self parseAndDownloadVideoWithShareLink:shareLink apiKey:apiKey retryCount:retryCount + 1];
                                                        } else {
                                                            [DYYYUtils showToast:[NSString stringWithFormat:@"接口请求失败(HTTP %ld)，请检查API地址", (long)httpResponse.statusCode]];
                                                        }
                                                        return;
                                                    }

                                                    if (error) {
                                                        if (retryCount < 2) {
                                                            // 自动重试（最多2次）
                                                            NSString *retryMsg = [NSString stringWithFormat:@"接口请求失败，正在第%ld次重试...", (long)(retryCount + 1)];
                                                            [DYYYUtils showToast:retryMsg];
                                                            [self parseAndDownloadVideoWithShareLink:shareLink apiKey:apiKey retryCount:retryCount + 1];
                                                        } else {
                                                            if (error.code == NSURLErrorTimedOut) {
                                                                [DYYYUtils showToast:@"接口请求超时，请检查网络或稍后重试"];
                                                            } else if (error.code == NSURLErrorNotConnectedToInternet || error.code == NSURLErrorNetworkConnectionLost) {
                                                                [DYYYUtils showToast:@"网络连接异常，请检查网络设置"];
                                                            } else {
                                                                [DYYYUtils showToast:[NSString stringWithFormat:@"接口请求失败: %@", error.localizedDescription]];
                                                            }
                                                        }
                                                        return;
                                                    }
                                                    
                                                    if (!data || data.length == 0) {
                                                        if (retryCount < 2) {
                                                            [DYYYUtils showToast:@"接口返回为空，正在重试..."];
                                                            [self parseAndDownloadVideoWithShareLink:shareLink apiKey:apiKey retryCount:retryCount + 1];
                                                        } else {
                                                            [DYYYUtils showToast:@"接口返回数据为空"];
                                                        }
                                                        return;
                                                    }

                                                    NSError *jsonError;
                                                    id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                                                    if (jsonError || ![jsonObj isKindOfClass:[NSDictionary class]]) {
                                                        if (retryCount < 2) {
                                                            [DYYYUtils showToast:@"解析失败，正在重试..."];
                                                            [self parseAndDownloadVideoWithShareLink:shareLink apiKey:apiKey retryCount:retryCount + 1];
                                                        } else {
                                                            [DYYYUtils showToast:@"解析接口返回数据失败"];
                                                        }
                                                        return;
                                                    }
                                                    NSDictionary *json = (NSDictionary *)jsonObj;

                                                    // 标准API格式处理
                                                    NSInteger code = [json[@"code"] integerValue];
                                                    if (code != 0 && code != 200) {
                                                        [DYYYUtils showToast:[NSString stringWithFormat:@"接口返回错误: %@", json[@"msg"] ?: @"未知错误"]];
                                                        return;
                                                    }
                                                    NSDictionary *dataDict = json[@"data"];

                                                    if (!dataDict) {
                                                        // 检查是否有视频专用API，自动分流重试
                                                        NSString *videoAPI = [[NSUserDefaults standardUserDefaults] stringForKey:@"DYYYVideoAPI"];
                                                        if (videoAPI.length > 0 && retryCount < 2) {
                                                            [DYYYUtils showToast:@"通用API解析失败，切换到视频专用API重试..."];
                                                            // 用视频专用API重新请求
                                                            NSString *encodedLink = [shareLink stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
                                                            NSString *videoApiUrl = [NSString stringWithFormat:@"%@%@", videoAPI, encodedLink];
                                                            NSLog(@"[DYYY-API] 自动分流，切换到视频专用API: %@", videoApiUrl);
                                                            [self requestCustomAPI:videoApiUrl shareLink:shareLink retryCount:retryCount + 1];
                                                            return;
                                                        }
                                                        
                                                        if (retryCount < 2) {
                                                            [DYYYUtils showToast:@"接口数据为空，正在重试..."];
                                                            [self parseAndDownloadVideoWithShareLink:shareLink apiKey:apiKey retryCount:retryCount + 1];
                                                        } else {
                                                            [DYYYUtils showToast:@"接口返回数据为空"];
                                                        }
                                                        return;
                                                    }
                                                    
                                                    // 检查是否有图片或视频数据
                                                    BOOL hasImages = dataDict[@"images"] && [(NSArray *)dataDict[@"images"] count] > 0;
                                                    BOOL hasVideo = dataDict[@"video_list"] && [(NSArray *)dataDict[@"video_list"] count] > 0;
                                                    
                                                    // 如果没有图片也没有有效视频，且有视频专用API，自动切换
                                                    NSString *videoAPI = [[NSUserDefaults standardUserDefaults] stringForKey:@"DYYYVideoAPI"];
                                                    if (!hasImages && !hasVideo && videoAPI.length > 0 && retryCount < 2) {
                                                        [DYYYUtils showToast:@"检测到视频帖，自动切换到视频专用API..."];
                                                        NSString *encodedLink = [shareLink stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
                                                        NSString *videoApiUrl = [NSString stringWithFormat:@"%@%@", videoAPI, encodedLink];
                                                        NSLog(@"[DYYY-API] 自动分流，视频帖切换到专用API: %@", videoApiUrl);
                                                        [self requestCustomAPI:videoApiUrl shareLink:shareLink retryCount:retryCount + 1];
                                                        return;
                                                    }

                                                    // 直接处理接口返回的数据
                                                    [self handleVideoData:dataDict];
                                                  } @catch (NSException *e) {
                                                    NSLog(@"[DYYY] parseAndDownload exception: %@", e);
                                                    [DYYYUtils showToast:@"数据处理异常，请重试"];
                                                  }
                                                  });
                                                }];

    [dataTask resume];
}

// 自定义API专用请求方法（用于自动分流重试）
+ (void)requestCustomAPI:(NSString *)apiUrl shareLink:(NSString *)shareLink retryCount:(NSInteger)retryCount {
    NSURL *url = [NSURL URLWithString:apiUrl];
    if (!url) {
        [DYYYUtils showToast:@"API地址格式错误"];
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30;
    
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request
                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                  dispatch_async(dispatch_get_main_queue(), ^{
                                                    @try {
                                                        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                                                        if ([httpResponse isKindOfClass:[NSHTTPURLResponse class]] && httpResponse.statusCode >= 400) {
                                                            if (retryCount < 2) {
                                                                [DYYYUtils showToast:[NSString stringWithFormat:@"接口返回错误(%ld)，正在重试...", (long)httpResponse.statusCode]];
                                                                [self requestCustomAPI:apiUrl shareLink:shareLink retryCount:retryCount + 1];
                                                            } else {
                                                                [DYYYUtils showToast:[NSString stringWithFormat:@"接口请求失败(HTTP %ld)", (long)httpResponse.statusCode]];
                                                            }
                                                            return;
                                                        }
                                                        
                                                        if (error) {
                                                            if (retryCount < 2) {
                                                                [DYYYUtils showToast:@"接口请求失败，正在重试..."];
                                                                [self requestCustomAPI:apiUrl shareLink:shareLink retryCount:retryCount + 1];
                                                            } else {
                                                                [DYYYUtils showToast:@"接口请求失败"];
                                                            }
                                                            return;
                                                        }
                                                        
                                                        if (!data || data.length == 0) {
                                                            [DYYYUtils showToast:@"接口返回数据为空"];
                                                            return;
                                                        }
                                                        
                                                        NSError *jsonError;
                                                        id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                                                        if (jsonError || ![jsonObj isKindOfClass:[NSDictionary class]]) {
                                                            [DYYYUtils showToast:@"解析接口返回数据失败"];
                                                            return;
                                                        }
                                                        
                                                        NSDictionary *json = (NSDictionary *)jsonObj;
                                                        NSInteger code = [json[@"code"] integerValue];
                                                        if (code != 0 && code != 200) {
                                                            [DYYYUtils showToast:[NSString stringWithFormat:@"接口返回错误: %@", json[@"msg"] ?: @"未知错误"]];
                                                            return;
                                                        }
                                                        
                                                        NSDictionary *dataDict = json[@"data"];
                                                        if (!dataDict) {
                                                            [DYYYUtils showToast:@"视频专用API解析失败"];
                                                            return;
                                                        }
                                                        
                                                        [self handleVideoData:dataDict];
                                                    } @catch (NSException *e) {
                                                        NSLog(@"[DYYY] requestCustomAPI exception: %@", e);
                                                        [DYYYUtils showToast:@"数据处理异常，请重试"];
                                                    }
                                                  });
                                                }];
    [dataTask resume];
}

// 双API智能合并：调用辅助信息API，合并到主数据中
+ (void)mergeWithInfoAPI:(NSString *)shareLink mainData:(NSDictionary *)mainData infoAPI:(NSString *)infoAPI completion:(void (^)(NSDictionary *mergedData))completion {
    if (!infoAPI || infoAPI.length == 0) {
        if (completion) completion(mainData);
        return;
    }
    
    NSString *encodedLink = [shareLink stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *infoApiUrl = [NSString stringWithFormat:@"%@%@", infoAPI, encodedLink];
    NSURL *url = [NSURL URLWithString:infoApiUrl];
    if (!url) {
        NSLog(@"[DYYY-API] 辅助API地址格式错误");
        if (completion) completion(mainData);
        return;
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 8;  // 缩短超时时间
    
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data) {
                NSLog(@"[DYYY-API] 辅助API请求失败: %@", error);
                [DYYYUtils showToast:@"获取补充信息失败，使用主API数据"];
                if (completion) completion(mainData);
                return;
            }
            
            NSError *jsonError;
            id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (jsonError || ![jsonObj isKindOfClass:[NSDictionary class]]) {
                NSLog(@"[DYYY-API] 辅助API解析失败");
                if (completion) completion(mainData);
                return;
            }
            
            NSDictionary *json = (NSDictionary *)jsonObj;
            NSInteger code = [json[@"code"] integerValue];
            if (code != 0 && code != 200) {
                NSLog(@"[DYYY-API] 辅助API返回错误: %@", json[@"msg"]);
                if (completion) completion(mainData);
                return;
            }
            
            NSDictionary *infoData = json[@"data"];
            if (!infoData) {
                NSLog(@"[DYYY-API] 辅助API返回数据为空");
                if (completion) completion(mainData);
                return;
            }
            
            // 合并数据：用辅助API的数据补充主数据缺少的字段
            NSMutableDictionary *merged = [mainData mutableCopy];
            
            // 合并播放量
            if (!merged[@"play_count"] && infoData[@"play_count"]) {
                merged[@"play_count"] = infoData[@"play_count"];
                NSLog(@"[DYYY-API] 合并播放量: %@", infoData[@"play_count"]);
            }
            
            // 合并音乐/原声信息（主API没有的话用辅助API的）
            if (!merged[@"music"] && !merged[@"music_url"] && !merged[@"music_detail"]) {
                if (infoData[@"music"]) merged[@"music"] = infoData[@"music"];
                if (infoData[@"music_url"]) merged[@"music_url"] = infoData[@"music_url"];
                if (infoData[@"music_detail"]) merged[@"music_detail"] = infoData[@"music_detail"];
                NSLog(@"[DYYY-API] 合并音乐信息");
            }
            
            // 合并其他可能的字段（封面、图片列表等，主API没有才补）
            if (!merged[@"cover"] && infoData[@"cover"]) {
                merged[@"cover"] = infoData[@"cover"];
            }
            if (!merged[@"images"] && infoData[@"images"]) {
                merged[@"images"] = infoData[@"images"];
            }
            if (!merged[@"desc"] && infoData[@"desc"]) {
                merged[@"desc"] = infoData[@"desc"];
            }
            if (!merged[@"author"] && infoData[@"author"]) {
                merged[@"author"] = infoData[@"author"];
            }
            
            NSLog(@"[DYYY-API] 双API合并完成");
            if (completion) completion(merged);
        });
    }];
    [dataTask resume];
}


+ (void)handleVideoData:(NSDictionary *)dataDict {
    if (!dataDict || ![dataDict isKindOfClass:[NSDictionary class]]) {
        [DYYYUtils showToast:@"接口返回数据格式异常"];
        return;
    }
    // 首先检查videos和images数组
    NSArray *videoList = dataDict[@"video_list"];
    NSArray *videos = dataDict[@"videos"];
    NSArray *images = dataDict[@"images"];
    NSArray *imgArray = dataDict[@"img"];

    // 获取封面URL
    NSString *coverURL = nil;
    if (dataDict[@"cover"] && [dataDict[@"cover"] length] > 0) {
        coverURL = dataDict[@"cover"];
    } else if (dataDict[@"pics"] && [dataDict[@"pics"] length] > 0) {
        coverURL = dataDict[@"pics"];
    }

    // 尝试获取音乐URL（供后续下载视频时合并音频使用）
    NSString *musicURL = nil;
    if (dataDict[@"music"] && [dataDict[@"music"] length] > 0) {
        musicURL = dataDict[@"music"];
    } else if (dataDict[@"music_url"] && [dataDict[@"music_url"] length] > 0) {
        musicURL = dataDict[@"music_url"];
    }

    // 获取音频详情（供"保存原声"选项使用）
    NSDictionary *musicDetail = nil;
    if ([dataDict[@"music_detail"] isKindOfClass:[NSDictionary class]]) {
        musicDetail = dataDict[@"music_detail"];
        // 优先从 music_detail 取音频URL
        if (!musicURL && musicDetail[@"url"] && [musicDetail[@"url"] length] > 0) {
            musicURL = musicDetail[@"url"];
        }
    }

    // 检查是否有视频列表(优先处理)
    BOOL hasVideoList = [videoList isKindOfClass:[NSArray class]] && videoList.count > 0;
    BOOL hasImages = [images isKindOfClass:[NSArray class]] && images.count > 0;
    BOOL hasImgArray = [imgArray isKindOfClass:[NSArray class]] && imgArray.count > 0;
    
    // 检测是否为实况照片：video_list中有"实况"标注 + images有内容
    BOOL isLivePhotoFromAPI = NO;
    if (hasVideoList && hasImages) {
        for (id videoItem in videoList) {
            if (![videoItem isKindOfClass:[NSDictionary class]]) continue;
            NSString *level = ((NSDictionary *)videoItem)[@"level"] ?: @"";
            if ([level containsString:@"实况"]) {
                isLivePhotoFromAPI = YES;
                break;
            }
        }
    }
    
    if (hasVideoList) {
        if (isLivePhotoFromAPI && images.count > 0) {
            // 实况照片：根据数量显示不同选项
            AWEUserActionSheetView *actionSheet = [[NSClassFromString(@"AWEUserActionSheetView") alloc] init];
            [DYYYManager addDisclaimerHeaderToActionSheet:actionSheet];
            NSMutableArray *actions = [NSMutableArray array];
            
            // 收集所有实况图片-视频对
            NSMutableArray *livePhotoPairs = [NSMutableArray array];
            NSInteger liveIdx = 0;
            for (id videoItem in videoList) {
                if (![videoItem isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *videoDict = (NSDictionary *)videoItem;
                NSString *level = videoDict[@"level"] ?: @"";
                if ([level containsString:@"实况"]) {
                    NSString *videoURLString = videoDict[@"url"];
                    NSString *imageURLString = (liveIdx < images.count) ? images[liveIdx] : nil;
                    // 类型安全：确保 imageURLString 是 NSString
                    if (![imageURLString isKindOfClass:[NSString class]]) imageURLString = nil;
                    if (imageURLString && videoURLString && [videoURLString isKindOfClass:[NSString class]]) {
                        [livePhotoPairs addObject:@{@"image": imageURLString, @"video": videoURLString, @"level": level}];
                    }
                    liveIdx++;
                }
            }
            
            BOOL hasMultiple = livePhotoPairs.count > 1;
            
            // 选项1：保存当前实况照片
            NSInteger savedImageIndex = [DYYYManager shared].currentImageIndex; // 用户当前浏览的图片索引（1-based）
            // 将 currentImageIndex 转换为 livePhotoPairs 的索引
            // currentImageIndex 是 1-based，且对应 images 数组的下标
            // livePhotoPairs 按 liveIdx 顺序排列（0-based），与 images 中实况图顺序一致
            NSInteger currentPairIndex = 0; // 默认第一张
            if (savedImageIndex > 0 && savedImageIndex <= images.count) {
                NSString *targetImageURL = images[savedImageIndex - 1];
                // 类型安全：确保 targetImageURL 是 NSString
                if ([targetImageURL isKindOfClass:[NSString class]]) {
                    for (NSInteger i = 0; i < livePhotoPairs.count; i++) {
                        if ([livePhotoPairs[i][@"image"] isEqualToString:targetImageURL]) {
                            currentPairIndex = i;
                            break;
                        }
                    }
                }
            }
            
            NSString *currentTitle = hasMultiple ? @"保存当前实况" : @"保存实况";
            AWEUserSheetAction *livePhotoAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:currentTitle
                                                                                                imgName:nil
                                                                                                handler:^{
                                                                                                    if (currentPairIndex < livePhotoPairs.count) {
                                                                                                        NSDictionary *pair = livePhotoPairs[currentPairIndex];
                                                                                                        [DYYYManager downloadLivePhoto:[NSURL URLWithString:pair[@"image"]]
                                                                                                                              videoURL:[NSURL URLWithString:pair[@"video"]]
                                                                                                                            completion:^{
                                                                                                                            }];
                                                                                                    } else if (livePhotoPairs.count > 0) {
                                                                                                        // fallback 到第一张
                                                                                                        NSDictionary *pair = livePhotoPairs[0];
                                                                                                        [DYYYManager downloadLivePhoto:[NSURL URLWithString:pair[@"image"]]
                                                                                                                              videoURL:[NSURL URLWithString:pair[@"video"]]
                                                                                                                            completion:^{
                                                                                                                            }];
                                                                                                    } else {
                                                                                                        [DYYYUtils showToast:@"无法获取实况照片URL"];
                                                                                                    }
                                                                                                }];
            [actions addObject:livePhotoAction];
            
            // 选项2：保存所有实况照片（多实况时显示）
            if (hasMultiple) {
                AWEUserSheetAction *allLivePhotoAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"保存所有实况"
                                                                                                    imgName:nil
                                                                                                    handler:^{
                                                                                                        for (NSDictionary *pair in livePhotoPairs) {
                                                                                                            [DYYYManager downloadLivePhoto:[NSURL URLWithString:pair[@"image"]]
                                                                                                                                  videoURL:[NSURL URLWithString:pair[@"video"]]
                                                                                                                                completion:^{
                                                                                                                                }];
                                                                                                        }
                                                                                                    }];
                [actions addObject:allLivePhotoAction];
            }
            
            // 选项3：保存视频（仅视频）
            AWEUserSheetAction *videoOnlyAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"保存视频"
                                                                                                imgName:nil
                                                                                                handler:^{
                                                                                                    // 显示画质选择
                                                                                                    AWEUserActionSheetView *qualitySheet = [[NSClassFromString(@"AWEUserActionSheetView") alloc] init];
                                                                                                    NSMutableArray *qualityActions = [NSMutableArray array];
                                                                                                    
                                                                                                    // 先计算质量选项数量
                                                                                                    NSInteger subQualityCount = 0;
                                                                                                    for (id videoItem in videoList) {
                                                                                                        if (![videoItem isKindOfClass:[NSDictionary class]]) continue;
                                                                                                        NSDictionary *videoDict = (NSDictionary *)videoItem;
                                                                                                        NSString *url = videoDict[@"url"];
                                                                                                        NSString *level = videoDict[@"level"];
                                                                                                        if (url.length > 0 && level.length > 0) {
                                                                                                            subQualityCount++;
                                                                                                        }
                                                                                                    }
                                                                                                    

                                                                                                    // 免责声明：数量行 + 详情行
                                                                                                    AWEUserSheetAction *subDisclaimer = [self disclaimerActionWithCount:subQualityCount];
                                                                                                    if (subDisclaimer) {
                                                                                                        [qualityActions addObject:subDisclaimer];
                                                                                                    }
                                                                                                    AWEUserSheetAction *subDisclaimerDetail = [self disclaimerDetailAction];
                                                                                                    if (subDisclaimerDetail) {
                                                                                                        [qualityActions addObject:subDisclaimerDetail];
                                                                                                    }
                                                                                                    
                                                                                                    subQualityCount = 0;
                                                                                                    for (id videoItem in videoList) {
                                                                                                        if (![videoItem isKindOfClass:[NSDictionary class]]) continue;
                                                                                                        NSDictionary *videoDict = (NSDictionary *)videoItem;
                                                                                                        NSString *url = videoDict[@"url"];
                                                                                                        NSString *level = videoDict[@"level"];
                                                                                                        if (url.length > 0 && level.length > 0) {
                                                                                                            subQualityCount++;
                                                                                                            NSString *capturedSubURL = url;
                                                                                                            AWEUserSheetAction *qualityAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:level
                                                                                                                                                                                  imgName:nil
                                                                                                                                                                                  handler:^{
                                                                                                                                                                                    NSURL *videoDownloadUrl = [NSURL URLWithString:capturedSubURL];
                                                                                                                                                                                    if (!videoDownloadUrl) { [DYYYUtils showToast:@"视频地址无效"]; return; }
                                                                                                                                                                                    NSURL *optionalAudioURL = nil;
                                                                                                                                                                                    if (musicURL.length > 0) {
                                                                                                                                                                                        optionalAudioURL = [NSURL URLWithString:musicURL];
                                                                                                                                                                                    }
                                                                                                                                                                                    [self downloadMedia:videoDownloadUrl
                                                                                                                                                                                              mediaType:MediaTypeVideo
                                                                                                                                                                                                  audio:optionalAudioURL
                                                                                                                                                                                             completion:^(BOOL success) {
                                                                                                                                                                                               if (!success) {
                                                                                                                                                                                               }
                                                                                                                                                                                             }];
                                                                                                                                                                                  }];
                                                                                                            [qualityActions addObject:qualityAction];
                                                                                                        }
                                                                                                    }
                                                                                                    if (qualityActions.count > 0) {
                                                                                                        [DYYYManager addDisclaimerHeaderToActionSheet:qualitySheet actionCount:subQualityCount];
                                                                                                        [qualitySheet setActions:qualityActions];
                                                                                                        [qualitySheet show];
                                                                                                    }
                                                                                                }];
            [actions addObject:videoOnlyAction];
            
            // 选项4：保存原声
            if (musicURL.length > 0) {
                // 获取作者信息
                NSString *authorName = nil;
                // 尝试从多个字段获取作者
                NSArray *authorKeys = @[@"author", @"nickname", @"author_name", @"music_author", @"author_nickname", @"music_author_name", @"user", @"user_name"];
                for (NSString *key in authorKeys) {
                    id value = dataDict[key];
                    if (value && [value isKindOfClass:[NSString class]] && [value length] > 0) {
                        authorName = value;
                        break;
                    }
                    // 如果是字典类型，尝试取里面的 name/nickname
                    if ([value isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *authorDict = (NSDictionary *)value;
                        for (NSString *innerKey in @[@"name", @"nickname", @"nick_name", @"username"]) {
                            if (authorDict[innerKey] && [authorDict[innerKey] isKindOfClass:[NSString class]] && [authorDict[innerKey] length] > 0) {
                                authorName = authorDict[innerKey];
                                break;
                            }
                        }
                        if (authorName) break;
                    }
                }
                
                // 构建音频标题
                NSString *audioTitle = @"保存原声";
                NSMutableString *titleBuilder = [NSMutableString stringWithString:@"保存原声"];
                
                // 添加作者信息
                if (authorName.length > 0) {
                    [titleBuilder appendFormat:@"：@%@", authorName];
                } else if (musicDetail && musicDetail[@"title"] && [musicDetail[@"title"] length] > 0) {
                    // 如果没有作者，显示音乐标题
                    [titleBuilder appendFormat:@"：%@", musicDetail[@"title"]];
                }
                
                audioTitle = titleBuilder;
                NSString *capturedMusicURL = musicURL;
                AWEUserSheetAction *audioAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:audioTitle
                                                                                                    imgName:nil
                                                                                                    handler:^{
                                                                                                      NSURL *audioDownloadUrl = [NSURL URLWithString:capturedMusicURL];
                                                                                                      if (!audioDownloadUrl) { [DYYYUtils showToast:@"音频地址无效"]; return; }
                                                                                                      [DYYYManager downloadMedia:audioDownloadUrl
                                                                                                                    mediaType:MediaTypeAudio
                                                                                                                        audio:nil
                                                                                                                   completion:^(BOOL success) {
                                                                                                                     if (!success) {
                                                                                                                         [DYYYUtils showToast:@"原声保存失败"];
                                                                                                                     }
                                                                                                                   }];
                                                                                                    }];
                [actions addObject:audioAction];
            }
            
            if (actions.count > 0) {
                [DYYYManager addDisclaimerHeaderToActionSheet:actionSheet];
                [actionSheet setActions:actions];
                [actionSheet show];
                return;
            }
        } else {
            // 非实况照片：显示画质选择
            AWEUserActionSheetView *actionSheet = [[NSClassFromString(@"AWEUserActionSheetView") alloc] init];
            NSMutableArray *actions = [NSMutableArray array];
            
            // 先计算质量选项数量
            NSInteger qualityCount = 0;
            for (id videoItem in videoList) {
                if (![videoItem isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *videoDict = (NSDictionary *)videoItem;
                NSString *url = videoDict[@"url"];
                NSString *level = videoDict[@"level"];
                if (url.length > 0 && level.length > 0) {
                    qualityCount++;
                }
            }
            


            // 免责声明：数量行 + 详情行
            AWEUserSheetAction *disclaimerAction = [self disclaimerActionWithCount:qualityCount];
            AWEUserSheetAction *disclaimerDetail = [self disclaimerDetailAction];
            for (id videoItem in videoList) {
                if (![videoItem isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *videoDict = (NSDictionary *)videoItem;
                NSString *url = videoDict[@"url"];
                NSString *level = videoDict[@"level"];
                if (url.length > 0 && level.length > 0) {
                    NSString *capturedURL = url;
                    AWEUserSheetAction *qualityAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:level
                                                                                                          imgName:nil
                                                                                                          handler:^{
                                                                                                            NSURL *videoDownloadUrl = [NSURL URLWithString:capturedURL];
                                                                                                            NSURL *optionalAudioURL = nil;
                                                                                                            if (musicURL.length > 0) {
                                                                                                                optionalAudioURL = [NSURL URLWithString:musicURL];
                                                                                                            }
                                                                                                            [self downloadMedia:videoDownloadUrl
                                                                                                                      mediaType:MediaTypeVideo
                                                                                                                          audio:optionalAudioURL
                                                                                                                     completion:^(BOOL success) {
                                                                                                                       if (!success) {
                                                                                                                       }
                                                                                                                     }];
                                                                                                          }];
                    [actions addObject:qualityAction];
                }
            }

            // 保存原声选项
            if (musicURL.length > 0) {
                // 获取作者信息
                NSString *authorName = nil;
                // 尝试从多个字段获取作者
                NSArray *authorKeys = @[@"author", @"nickname", @"author_name", @"music_author", @"author_nickname", @"music_author_name", @"user", @"user_name"];
                for (NSString *key in authorKeys) {
                    id value = dataDict[key];
                    if (value && [value isKindOfClass:[NSString class]] && [value length] > 0) {
                        authorName = value;
                        break;
                    }
                    // 如果是字典类型，尝试取里面的 name/nickname
                    if ([value isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *authorDict = (NSDictionary *)value;
                        for (NSString *innerKey in @[@"name", @"nickname", @"nick_name", @"username"]) {
                            if (authorDict[innerKey] && [authorDict[innerKey] isKindOfClass:[NSString class]] && [authorDict[innerKey] length] > 0) {
                                authorName = authorDict[innerKey];
                                break;
                            }
                        }
                        if (authorName) break;
                    }
                }
                
                // 构建音频标题
                NSString *audioTitle = @"保存原声";
                NSMutableString *titleBuilder = [NSMutableString stringWithString:@"保存原声"];
                
                // 添加作者信息
                if (authorName.length > 0) {
                    [titleBuilder appendFormat:@"：@%@", authorName];
                } else if (musicDetail && musicDetail[@"title"] && [musicDetail[@"title"] length] > 0) {
                    // 如果没有作者，显示音乐标题
                    [titleBuilder appendFormat:@"：%@", musicDetail[@"title"]];
                }
                
                audioTitle = titleBuilder;
                NSString *capturedMusicURL = musicURL;
                AWEUserSheetAction *audioAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:audioTitle
                                                                                                    imgName:nil
                                                                                                    handler:^{
                                                                                                      NSURL *audioDownloadUrl = [NSURL URLWithString:capturedMusicURL];
                                                                                                      if (!audioDownloadUrl) { [DYYYUtils showToast:@"音频地址无效"]; return; }
                                                                                                      [DYYYManager downloadMedia:audioDownloadUrl
                                                                                                                    mediaType:MediaTypeAudio
                                                                                                                        audio:nil
                                                                                                                   completion:^(BOOL success) {
                                                                                                                     if (!success) {
                                                                                                                         [DYYYUtils showToast:@"原声保存失败"];
                                                                                                                     }
                                                                                                                   }];
                                                                                                    }];
                [actions addObject:audioAction];
            }

            if (actions.count > 0) {
                if (disclaimerDetail) {
                    [actions insertObject:disclaimerDetail atIndex:0];
                }
                if (disclaimerAction) {
                    [actions insertObject:disclaimerAction atIndex:0];
                }
                [DYYYManager addDisclaimerHeaderToActionSheet:actionSheet actionCount:qualityCount];
                [actionSheet setActions:actions];
                [actionSheet show];
                return;
            }
        }
    }

    // 尝试获取视频URL
    NSString *singleVideoURL = nil;
    if (dataDict[@"url"] && [dataDict[@"url"] length] > 0) {
        singleVideoURL = dataDict[@"url"];
    } else if (dataDict[@"video"] && [dataDict[@"video"] length] > 0) {
        singleVideoURL = dataDict[@"video"];
    } else if (dataDict[@"video_url"] && [dataDict[@"video_url"] length] > 0) {
        singleVideoURL = dataDict[@"video_url"];
    }

    // 确保处理空的videos数组
    BOOL hasVideos = [videos isKindOfClass:[NSArray class]] && videos.count > 0;

    BOOL shouldShowQualityOptions = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYShowAllVideoQuality"];

    // 如果只有图片没有视频，处理图片下载
    if (!hasVideos && singleVideoURL == nil && (hasImages || hasImgArray || coverURL != nil)) {
        NSMutableArray *allImages = [NSMutableArray array];
        if (hasImages)
            [allImages addObjectsFromArray:images];
        if (hasImgArray)
            [allImages addObjectsFromArray:imgArray];
        if (coverURL && coverURL.length > 0 && ![allImages containsObject:coverURL]) {
            [allImages addObject:coverURL];
        }

        if (allImages.count > 0) {
            if (allImages.count == 1) {
                // 单张图片直接下载
                NSURL *imageDownloadUrl = [NSURL URLWithString:allImages[0]];
                [self downloadMedia:imageDownloadUrl
                          mediaType:MediaTypeImage
                              audio:nil
                         completion:^(BOOL success) {
                           if (!success) {
                               NSLog(@"[DYYY] 图片下载失败 - downloadMedia returned NO, URL=%@", allImages[0]);
                               [DYYYUtils showToast:@"图片下载失败"];
                           }
                         }];
            } else {
                // 多张图片：弹出选项 保存当前/保存全部
                AWEUserActionSheetView *actionSheet = [[NSClassFromString(@"AWEUserActionSheetView") alloc] init];
                [DYYYManager addDisclaimerHeaderToActionSheet:actionSheet];
                NSMutableArray *actions = [NSMutableArray array];
                
                NSInteger savedImageIndex = [DYYYManager shared].currentImageIndex; // 1-based
                
                // 选项1：保存当前图片
                AWEUserSheetAction *currentImageAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"保存当前图片"
                                                                                                    imgName:nil
                                                                                                    handler:^{
                                                                                                        // currentImageIndex 是 1-based，对应 images 数组
                                                                                                        NSInteger idx = savedImageIndex > 0 ? savedImageIndex - 1 : 0;
                                                                                                        if (idx < allImages.count) {
                                                                                                            NSURL *imageDownloadUrl = [NSURL URLWithString:allImages[idx]];
                                                                                                            [DYYYManager downloadMedia:imageDownloadUrl
                                                                                                                              mediaType:MediaTypeImage
                                                                                                                                  audio:nil
                                                                                                                             completion:^(BOOL success) {
                                                                                                                               if (!success) {
                                                                                                                                   [DYYYUtils showToast:@"图片下载失败"];
                                                                                                                               }
                                                                                                                             }];
                                                                                                        } else {
                                                                                                            [DYYYUtils showToast:@"无法定位当前图片"];
                                                                                                        }
                                                                                                    }];
                [actions addObject:currentImageAction];
                
                // 选项2：保存全部图片
                AWEUserSheetAction *allImagesAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"保存全部图片"
                                                                                                    imgName:nil
                                                                                                    handler:^{
                                                                                                        [DYYYManager downloadAllImages:allImages];
                                                                                                    }];
                [actions addObject:allImagesAction];
                
                // 选项3：保存原声
                if (musicURL.length > 0) {
                    // 获取作者信息
                    NSString *authorName = nil;
                    // 尝试从多个字段获取作者
                    NSArray *authorKeys = @[@"author", @"nickname", @"author_name", @"music_author", @"author_nickname", @"music_author_name", @"user", @"user_name"];
                    for (NSString *key in authorKeys) {
                        id value = dataDict[key];
                        if (value && [value isKindOfClass:[NSString class]] && [value length] > 0) {
                            authorName = value;
                            break;
                        }
                        // 如果是字典类型，尝试取里面的 name/nickname
                        if ([value isKindOfClass:[NSDictionary class]]) {
                            NSDictionary *authorDict = (NSDictionary *)value;
                            for (NSString *innerKey in @[@"name", @"nickname", @"nick_name", @"username"]) {
                                if (authorDict[innerKey] && [authorDict[innerKey] isKindOfClass:[NSString class]] && [authorDict[innerKey] length] > 0) {
                                    authorName = authorDict[innerKey];
                                    break;
                                }
                            }
                            if (authorName) break;
                        }
                    }
                    
                    // 构建音频标题
                    NSString *audioTitle = @"保存原声";
                    NSMutableString *titleBuilder = [NSMutableString stringWithString:@"保存原声"];
                    
                    // 添加作者信息
                    if (authorName.length > 0) {
                        [titleBuilder appendFormat:@"：@%@", authorName];
                    } else if (musicDetail && musicDetail[@"title"] && [musicDetail[@"title"] length] > 0) {
                        // 如果没有作者，显示音乐标题
                        [titleBuilder appendFormat:@"：%@", musicDetail[@"title"]];
                    }
                    
                    audioTitle = titleBuilder;
                    NSString *capturedMusicURL = musicURL;
                    AWEUserSheetAction *audioAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:audioTitle
                                                                                                        imgName:nil
                                                                                                        handler:^{
                                                                                                          NSURL *audioDownloadUrl = [NSURL URLWithString:capturedMusicURL];
                                                                                                          if (!audioDownloadUrl) { [DYYYUtils showToast:@"音频地址无效"]; return; }
                                                                                                          [DYYYManager downloadMedia:audioDownloadUrl
                                                                                                                        mediaType:MediaTypeAudio
                                                                                                                            audio:nil
                                                                                                                       completion:^(BOOL success) {
                                                                                                                         if (!success) {
                                                                                                                             [DYYYUtils showToast:@"原声保存失败"];
                                                                                                                         }
                                                                                                                       }];
                                                                                                        }];
                    [actions addObject:audioAction];
                }
                
                if (actions.count > 0) {
                    [actionSheet setActions:actions];
                    [actionSheet show];
                }
            }
            return;
        }
    }

    // 单个视频情况下的处理
    if (shouldShowQualityOptions && singleVideoURL && singleVideoURL.length > 0) {
        AWEUserActionSheetView *actionSheet = [[NSClassFromString(@"AWEUserActionSheetView") alloc] init];
        [DYYYManager addDisclaimerHeaderToActionSheet:actionSheet];
        NSMutableArray *actions = [NSMutableArray array];

        AWEUserSheetAction *videoAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"下载视频"
                                                                                            imgName:nil
                                                                                            handler:^{
                                                                                              NSURL *videoDownloadUrl = [NSURL URLWithString:singleVideoURL];
                                                                                              if (!videoDownloadUrl) { [DYYYUtils showToast:@"视频地址无效"]; return; }
                                                                                              NSURL *optionalAudioURL = nil;
                                                                                              if (musicURL.length > 0) {
                                                                                                  optionalAudioURL = [NSURL URLWithString:musicURL];
                                                                                              }
                                                                                              [self downloadMedia:videoDownloadUrl
                                                                                                        mediaType:MediaTypeVideo
                                                                                                            audio:optionalAudioURL
                                                                                                       completion:^(BOOL success) {
                                                                                                         if (!success) {
                                                                                                         }
                                                                                                       }];
                                                                                            }];
        [actions addObject:videoAction];

        if (coverURL && coverURL.length > 0) {
            AWEUserSheetAction *coverAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"下载封面图"
                                                                                                imgName:nil
                                                                                                handler:^{
                                                                                                  NSURL *imageDownloadUrl = [NSURL URLWithString:coverURL];
                                                                                                  if (!imageDownloadUrl) { [DYYYUtils showToast:@"封面地址无效"]; return; }
                                                                                                  [self downloadMedia:imageDownloadUrl
                                                                                                            mediaType:MediaTypeImage
                                                                                                                audio:nil
                                                                                                           completion:^(BOOL success) {
                                                                                                             if (!success) {
                                                                                                             }
                                                                                                           }];
                                                                                                }];
            [actions addObject:coverAction];
        }

        if (musicURL && musicURL.length > 0) {
            AWEUserSheetAction *musicAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"下载背景音乐"
                                                                                                imgName:nil
                                                                                                handler:^{
                                                                                                  NSURL *audioDownloadUrl = [NSURL URLWithString:musicURL];
                                                                                                  [self downloadMedia:audioDownloadUrl
                                                                                                            mediaType:MediaTypeAudio
                                                                                                                audio:nil
                                                                                                           completion:^(BOOL success) {
                                                                                                             if (!success) {
                                                                                                             }
                                                                                                           }];
                                                                                                }];
            [actions addObject:musicAction];
        }

        // 添加批量下载选项
        NSMutableArray *allImages = [NSMutableArray array];
        if (hasImages)
            [allImages addObjectsFromArray:images];
        if (hasImgArray)
            [allImages addObjectsFromArray:imgArray];
        if (coverURL && coverURL.length > 0 && ![allImages containsObject:coverURL]) {
            [allImages addObject:coverURL];
        }

        if (allImages.count > 0 || singleVideoURL.length > 0) {
            AWEUserSheetAction *batchDownloadAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"批量下载所有资源"
                                                                                                        imgName:nil
                                                                                                        handler:^{
                                                                                                          NSMutableArray *singleVideoArray = nil;
                                                                                                          if (singleVideoURL.length > 0) {
                                                                                                              singleVideoArray = [NSMutableArray arrayWithObject:@{@"url" : singleVideoURL}];
                                                                                                          }
                                                                                                          [self batchDownloadResources:singleVideoArray images:allImages];
                                                                                                        }];
            [actions addObject:batchDownloadAction];
        }

        if (actions.count > 0) {
            [actionSheet setActions:actions];
            [actionSheet show];
            return;
        }
    }

    if (!shouldShowQualityOptions && singleVideoURL && singleVideoURL.length > 0) {
        NSURL *videoDownloadUrl = [NSURL URLWithString:singleVideoURL];
        if (!videoDownloadUrl) { [DYYYUtils showToast:@"视频地址无效"]; return; }
        NSURL *optionalAudioURL = nil;
        if (musicURL.length > 0) {
            optionalAudioURL = [NSURL URLWithString:musicURL];
        }
        [self downloadMedia:videoDownloadUrl
                  mediaType:MediaTypeVideo
                      audio:optionalAudioURL
                 completion:^(BOOL success) {
                   if (!success) {
                   }
                 }];
        return;
    }

    // 如果前面的条件都不满足，尝试批量下载所有资源
    NSMutableArray *allImages = [NSMutableArray array];
    if (hasImages)
        [allImages addObjectsFromArray:images];
    if (hasImgArray)
        [allImages addObjectsFromArray:imgArray];
    if (coverURL && coverURL.length > 0 && ![allImages containsObject:coverURL]) {
        [allImages addObject:coverURL];
    }

    if (allImages.count > 0 || hasVideos) {
        [self batchDownloadResources:videos images:allImages];
    } else {
        [DYYYUtils showToast:@"没有找到可下载的资源"];
    }
}

#define DYYYLogVideo(format, ...) NSLog((@"[DYYY视频合成] " format), ##__VA_ARGS__)
// 创建视频合成器从多种媒体源
+ (void)createVideoFromMedia:(NSArray<NSString *> *)imageURLs
                  livePhotos:(NSArray<NSDictionary *> *)livePhotos
                      bgmURL:(NSString *)bgmURL
                    progress:(void (^)(NSInteger current, NSInteger total, NSString *status))progressBlock
                  completion:(void (^)(BOOL success, NSString *message))completion {
    DYYYLogVideo(@"开始创建视频 - 图片数量: %lu, 实况照片数量: %lu, 背景音乐: %@", (unsigned long)imageURLs.count, (unsigned long)livePhotos.count, bgmURL.length > 0 ? @"有" : @"无");

    if ((imageURLs.count == 0 && livePhotos.count == 0) || (imageURLs == nil && livePhotos == nil)) {
        DYYYLogVideo(@"错误: 没有提供媒体资源");
        if (completion) {
            completion(NO, @"没有提供媒体资源");
        }
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      CGRect screenBounds = [UIScreen mainScreen].bounds;
      DYYYToast *progressView = [[DYYYToast alloc] initWithFrame:screenBounds];
      [progressView show];

      progressView.cancelBlock = ^{
        DYYYLogVideo(@"用户取消了视频合成");
        [self cancelAllDownloads];
        if (completion) {
            completion(NO, @"用户取消了操作");
        }
      };

      // 创建临时目录
      NSString *mediaPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"VideoComposition"];
      NSFileManager *fileManager = [NSFileManager defaultManager];
      if ([fileManager fileExistsAtPath:mediaPath]) {
          DYYYLogVideo(@"正在清理旧的临时目录: %@", mediaPath);
          [fileManager removeItemAtPath:mediaPath error:nil];
      }

      NSError *dirError = nil;
      [fileManager createDirectoryAtPath:mediaPath withIntermediateDirectories:YES attributes:nil error:&dirError];
      if (dirError) {
          DYYYLogVideo(@"创建临时目录失败: %@", dirError);
          if (completion) {
              completion(NO, @"创建临时文件夹失败");
          }
          return;
      }
      DYYYLogVideo(@"成功创建临时目录: %@", mediaPath);

      // 计算总共需要下载的文件数和合成步骤
      NSInteger totalImages = imageURLs.count;
      NSInteger totalLivePhotos = livePhotos.count * 2;  // 每个实况照片有2个文件
      NSInteger hasBGM = (bgmURL.length > 0) ? 1 : 0;

      // 总步骤：下载所有媒体 + 合成视频 + 保存视频
      NSInteger totalSteps = totalImages + totalLivePhotos + hasBGM + 2;
      __block NSInteger completedSteps = 0;

      // 储存下载的媒体文件路径
      NSMutableArray *imageFilePaths = [NSMutableArray array];
      NSMutableArray<NSDictionary *> *livePhotoFilePaths = [NSMutableArray array];
      __block NSString *bgmFilePath = nil;

      void (^updateProgress)(NSString *) = ^(NSString *status) {
        float progress = (float)completedSteps / totalSteps;
        dispatch_async(dispatch_get_main_queue(), ^{
          [progressView setProgress:progress];
          DYYYLogVideo(@"进度更新: %.2f%% - %@", progress * 100, status);
          if (progressBlock) {
              progressBlock(completedSteps, totalSteps, status);
          }
        });
      };

      // 第一阶段：下载所有普通图片
      dispatch_group_t imageDownloadGroup = dispatch_group_create();
      updateProgress(@"正在下载图片...");

      for (NSInteger i = 0; i < imageURLs.count; i++) {
          NSString *imageURLString = imageURLs[i];
          NSURL *imageURL = [NSURL URLWithString:imageURLString];

          if (!imageURL) {
              DYYYLogVideo(@"图片URL无效: %@", imageURLString);
              completedSteps++;
              updateProgress(@"图片URL无效");
              continue;
          }

          dispatch_group_enter(imageDownloadGroup);

          // 创建文件路径
          NSString *uniqueID = [NSUUID UUID].UUIDString;
          NSString *imagePath = [mediaPath stringByAppendingPathComponent:[NSString stringWithFormat:@"image_%@.jpg", uniqueID]];
          DYYYLogVideo(@"开始下载图片 %ld/%ld: %@", (long)(i + 1), (long)imageURLs.count, imageURLString);

          // 配置下载会话
          NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
          configuration.timeoutIntervalForRequest = 60.0;
          configuration.timeoutIntervalForResource = 600.0;
          NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];

          NSURLSessionDataTask *imageTask = [session dataTaskWithURL:imageURL
                                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                     if (error) {
                                                         DYYYLogVideo(@"下载图片失败 %ld/%ld: %@", (long)(i + 1), (long)imageURLs.count, error);
                                                     } else if (!data) {
                                                         DYYYLogVideo(@"下载图片数据为空 %ld/%ld", (long)(i + 1), (long)imageURLs.count);
                                                     } else {
                                                         NSInteger dataSize = data.length;
                                                         if ([data writeToFile:imagePath atomically:YES]) {
                                                             DYYYLogVideo(@"成功下载并保存图片 %ld/%ld: %@ (大小: %.2f KB)", (long)(i + 1), (long)imageURLs.count, imagePath, dataSize / 1024.0);
                                                             @synchronized(imageFilePaths) {
                                                                 [imageFilePaths addObject:imagePath];
                                                             }
                                                         } else {
                                                             DYYYLogVideo(@"保存图片文件失败 %ld/%ld: %@", (long)(i + 1), (long)imageURLs.count, imagePath);
                                                         }
                                                     }

                                                     @synchronized(self) { completedSteps++; }
                                                     updateProgress([NSString stringWithFormat:@"已下载图片 %ld/%ld", (long)(i + 1), (long)imageURLs.count]);
                                                     dispatch_group_leave(imageDownloadGroup);
                                                   }];

          [imageTask resume];
      }

      // 第二阶段：下载所有实况照片
      dispatch_group_t livePhotoDownloadGroup = dispatch_group_create();

      dispatch_group_notify(imageDownloadGroup, dispatch_get_main_queue(), ^{
        DYYYLogVideo(@"第一阶段完成，已下载 %ld 张图片", (long)imageFilePaths.count);
        updateProgress(@"正在下载实况照片...");
        DYYYLogVideo(@"开始第二阶段: 下载实况照片 (%ld 项)", (long)livePhotos.count);

        for (NSInteger i = 0; i < livePhotos.count; i++) {
            NSDictionary *livePhoto = livePhotos[i];
            NSString *imageURLString = livePhoto[@"imageURL"];
            NSString *videoURLString = livePhoto[@"videoURL"];
            NSURL *imageURL = [NSURL URLWithString:imageURLString];
            NSURL *videoURL = [NSURL URLWithString:videoURLString];

            if (!imageURL || !videoURL) {
                DYYYLogVideo(@"实况照片URL无效: 图片=%@, 视频=%@", imageURLString, videoURLString);
                completedSteps += 2;
                updateProgress(@"实况照片URL无效");
                continue;
            }

            NSString *uniqueID = [NSUUID UUID].UUIDString;
            NSString *imagePath = [mediaPath stringByAppendingPathComponent:[NSString stringWithFormat:@"livephoto_img_%@.jpg", uniqueID]];
            NSString *videoPath = [mediaPath stringByAppendingPathComponent:[NSString stringWithFormat:@"livephoto_vid_%@.mp4", uniqueID]];

            // 下载图片部分
            dispatch_group_enter(livePhotoDownloadGroup);
            NSURLSessionConfiguration *imgConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
            imgConfig.timeoutIntervalForRequest = 60.0;
            imgConfig.timeoutIntervalForResource = 600.0;
            NSURLSession *imgSession = [NSURLSession sessionWithConfiguration:imgConfig];

            DYYYLogVideo(@"开始下载实况照片图片部分 %ld/%ld: %@", (long)(i + 1), (long)livePhotos.count, imageURLString);
            NSURLSessionDataTask *imageTask =
                [imgSession dataTaskWithURL:imageURL
                          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                            if (error) {
                                DYYYLogVideo(@"下载实况照片图片部分失败 %ld/%ld: %@", (long)(i + 1), (long)livePhotos.count, error);
                            } else if (!data) {
                                DYYYLogVideo(@"下载实况照片图片数据为空 %ld/%ld", (long)(i + 1), (long)livePhotos.count);
                            } else if ([data writeToFile:imagePath atomically:YES]) {
                                DYYYLogVideo(@"成功保存实况照片图片部分 %ld/%ld: %@ (大小: %.2f KB)", (long)(i + 1), (long)livePhotos.count, imagePath, data.length / 1024.0);
                            } else {
                                DYYYLogVideo(@"保存实况照片图片文件失败 %ld/%ld: %@", (long)(i + 1), (long)livePhotos.count, imagePath);
                            }

                            @synchronized(self) { completedSteps++; }
                            updateProgress([NSString stringWithFormat:@"已下载实况照片(图片) %ld/%ld", (long)(i + 1), (long)livePhotos.count]);
                            dispatch_group_leave(livePhotoDownloadGroup);
                          }];

            // 下载视频部分
            dispatch_group_enter(livePhotoDownloadGroup);
            NSURLSessionConfiguration *vidConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
            vidConfig.timeoutIntervalForRequest = 60.0;
            vidConfig.timeoutIntervalForResource = 600.0;
            NSURLSession *vidSession = [NSURLSession sessionWithConfiguration:vidConfig];

            DYYYLogVideo(@"开始下载实况照片视频部分 %ld/%ld: %@", (long)(i + 1), (long)livePhotos.count, videoURLString);
            NSURLSessionDataTask *videoTask =
                [vidSession dataTaskWithURL:videoURL
                          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                            if (error) {
                                DYYYLogVideo(@"下载实况照片视频部分失败 %ld/%ld: %@", (long)(i + 1), (long)livePhotos.count, error);
                            } else if (!data) {
                                DYYYLogVideo(@"下载实况照片视频数据为空 %ld/%ld", (long)(i + 1), (long)livePhotos.count);
                            } else if ([data writeToFile:videoPath atomically:YES]) {
                                DYYYLogVideo(@"成功保存实况照片视频部分 %ld/%ld: %@ (大小: %.2f MB)", (long)(i + 1), (long)livePhotos.count, videoPath, data.length / (1024.0 * 1024.0));
                                @synchronized(livePhotoFilePaths) {
                                    [livePhotoFilePaths addObject:@{@"image" : imagePath, @"video" : videoPath}];
                                    DYYYLogVideo(@"成功记录实况照片对: 图片=%@, 视频=%@", imagePath, videoPath);
                                }
                            } else {
                                DYYYLogVideo(@"保存实况照片视频文件失败 %ld/%ld: %@", (long)(i + 1), (long)livePhotos.count, videoPath);
                            }

                            @synchronized(self) { completedSteps++; }
                            updateProgress([NSString stringWithFormat:@"已下载实况照片(视频) %ld/%ld", (long)(i + 1), (long)livePhotos.count]);
                            dispatch_group_leave(livePhotoDownloadGroup);
                          }];

            [imageTask resume];
            [videoTask resume];
        }

        // 第三阶段：下载背景音乐
        dispatch_group_t bgmDownloadGroup = dispatch_group_create();

        dispatch_group_notify(livePhotoDownloadGroup, dispatch_get_main_queue(), ^{
          DYYYLogVideo(@"第二阶段完成，已下载 %ld 组实况照片", (long)livePhotoFilePaths.count);

          if (bgmURL.length > 0) {
              DYYYLogVideo(@"开始第三阶段: 下载背景音乐 %@", bgmURL);
              updateProgress(@"正在下载背景音乐...");
              NSURL *bgmURL_obj = [NSURL URLWithString:bgmURL];

              if (!bgmURL_obj) {
                  DYYYLogVideo(@"背景音乐URL无效: %@", bgmURL);
                  completedSteps++;
                  updateProgress(@"背景音乐URL无效");
              } else {
                  dispatch_group_enter(bgmDownloadGroup);

                  // 创建文件路径
                  NSString *uniqueID = [NSUUID UUID].UUIDString;
                  NSString *audioPath = [mediaPath stringByAppendingPathComponent:[NSString stringWithFormat:@"bgm_%@.mp3", uniqueID]];

                  // 配置下载会话
                  NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
                  configuration.timeoutIntervalForRequest = 60.0;
                  configuration.timeoutIntervalForResource = 600.0;
                  NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];

                  NSURLSessionDataTask *audioTask = [session dataTaskWithURL:bgmURL_obj
                                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                             if (error) {
                                                                 DYYYLogVideo(@"下载背景音乐失败: %@", error);
                                                             } else if (!data) {
                                                                 DYYYLogVideo(@"下载背景音乐数据为空");
                                                             } else if ([data writeToFile:audioPath atomically:YES]) {
                                                                 DYYYLogVideo(@"成功保存背景音乐: %@ (大小: %.2f MB)", audioPath, data.length / (1024.0 * 1024.0));
                                                                 bgmFilePath = audioPath;
                                                             } else {
                                                                 DYYYLogVideo(@"保存背景音乐文件失败: %@", audioPath);
                                                             }

                                                             @synchronized(self) { completedSteps++; }
                                                             updateProgress(@"背景音乐下载完成");
                                                             dispatch_group_leave(bgmDownloadGroup);
                                                           }];

                  [audioTask resume];
              }
          }

          // 第四阶段：合成视频
          dispatch_group_notify(bgmDownloadGroup, dispatch_get_main_queue(), ^{
            DYYYLogVideo(@"第三阶段完成，背景音乐状态: %@", bgmFilePath ? @"已下载" : @"无或下载失败");
            DYYYLogVideo(@"开始第四阶段: 合成视频");
            updateProgress(@"正在合成视频...");

            // 如果没有成功下载任何媒体，则退出
            if (imageFilePaths.count == 0 && livePhotoFilePaths.count == 0) {
                DYYYLogVideo(@"错误: 没有成功下载任何媒体文件，取消合成");
                progressView.allowSuccessAnimation = NO;
                [progressView dismiss];
                if (completion) {
                    completion(NO, @"没有成功下载任何媒体文件");
                }
                [fileManager removeItemAtPath:mediaPath error:nil];
                return;
            }

            DYYYLogVideo(@"媒体文件统计: %ld张图片, %ld组实况照片, 背景音乐: %@", (long)imageFilePaths.count, (long)livePhotoFilePaths.count, bgmFilePath ? @"有" : @"无");

            NSString *outputPath = [mediaPath stringByAppendingPathComponent:[NSString stringWithFormat:@"final_%@.mp4", [NSUUID UUID].UUIDString]];
            DYYYLogVideo(@"视频输出路径: %@", outputPath);

            // 使用AVFoundation合成视频
            [self composeVideo:imageFilePaths
                    livePhotos:livePhotoFilePaths
                       bgmPath:bgmFilePath
                    outputPath:outputPath
                    completion:^(BOOL success) {
                      completedSteps++;
                      if (success) {
                          DYYYLogVideo(@"视频合成成功");
                      } else {
                          DYYYLogVideo(@"视频合成失败");
                      }
                      updateProgress(@"视频合成完成");

                      if (success) {
                          DYYYLogVideo(@"开始保存视频到相册");
                          [DYYYManager saveAssetToLibrary:[NSURL fileURLWithPath:outputPath]
                                                mediaType:MediaTypeVideo
                                               useCaption:YES
                                               completion:^(BOOL success) {
                              completedSteps++;
                              dispatch_async(dispatch_get_main_queue(), ^{
                                progressView.allowSuccessAnimation = success;
                                [progressView dismiss];
                                if (success) {
                                    DYYYLogVideo(@"视频已成功保存到相册");
                                    if (completion) completion(YES, @"视频已成功保存到相册");
                                } else {
                                    DYYYLogVideo(@"保存视频到相册失败");
                                    if (completion) completion(NO, @"保存视频到相册失败");
                                }
                                DYYYLogVideo(@"清理临时文件: %@", mediaPath);
                                [fileManager removeItemAtPath:mediaPath error:nil];
                              });
                          }];
                      } else {
                          dispatch_async(dispatch_get_main_queue(), ^{
                            progressView.allowSuccessAnimation = NO;
                            [progressView dismiss];
                            if (completion) {
                                completion(NO, @"视频合成失败");
                            }

                            DYYYLogVideo(@"清理临时文件: %@", mediaPath);
                            [fileManager removeItemAtPath:mediaPath error:nil];
                          });
                      }
                    }];
          });
        });
      });
    });
}

// 视频合成核心方法
+ (void)composeVideo:(NSArray<NSString *> *)imageFiles
          livePhotos:(NSArray<NSDictionary *> *)livePhotoFiles
             bgmPath:(NSString *)bgmPath
          outputPath:(NSString *)outputPath
          completion:(void (^)(BOOL success))completion {
    // 视频尺寸（标准1080p）
    CGSize videoSize = CGSizeMake(1080, 1920);
    DYYYLogVideo(@"开始合成视频 - 目标尺寸: %.0fx%.0f", videoSize.width, videoSize.height);
    DYYYLogVideo(@"媒体源: %ld张图片, %ld组实况照片, 背景音乐: %@", (long)imageFiles.count, (long)livePhotoFiles.count, bgmPath ? @"有" : @"无");

    dispatch_group_t processingGroup = dispatch_group_create();

    // 存储所有媒体片段信息
    NSMutableArray *mediaSegments = [NSMutableArray array];

    // 处理静态图片 - 先将所有图片转换为临时视频片段
    for (NSInteger i = 0; i < imageFiles.count; i++) {
        NSString *imagePath = imageFiles[i];
        if (![[NSFileManager defaultManager] fileExistsAtPath:imagePath]) {
            DYYYLogVideo(@"错误: 图片文件不存在: %@", imagePath);
            continue;
        }

        UIImage *image = [UIImage imageWithContentsOfFile:imagePath];
        if (!image) {
            DYYYLogVideo(@"错误: 无法加载图片: %@", imagePath);
            continue;
        }
        DYYYLogVideo(@"处理图片 %ld/%ld: 尺寸 %.0fx%.0f", (long)(i + 1), (long)imageFiles.count, image.size.width, image.size.height);

        // 创建临时视频文件路径
        NSString *tempVideoPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"temp_img_%@.mp4", [NSUUID UUID].UUIDString]];

        dispatch_group_enter(processingGroup);

        // 使用Core Animation创建静态图片视频
        [self createVideoFromImage:image
                          duration:5.0
                        outputPath:tempVideoPath
                        completion:^(BOOL success) {
                          if (success) {
                              @synchronized(mediaSegments) {
                                  [mediaSegments addObject:@{@"type" : @"image", @"path" : tempVideoPath, @"duration" : @5.0}];
                                  DYYYLogVideo(@"成功创建图片视频片段 %ld/%ld: %@", (long)(i + 1), (long)imageFiles.count, tempVideoPath);
                              }
                          } else {
                              DYYYLogVideo(@"错误: 创建图片视频片段失败 %ld/%ld", (long)(i + 1), (long)imageFiles.count);
                          }
                          dispatch_group_leave(processingGroup);
                        }];
    }

    // 处理实况照片 - 收集所有视频路径信息
    for (NSInteger i = 0; i < livePhotoFiles.count; i++) {
        NSDictionary *livePhoto = livePhotoFiles[i];
        NSString *imagePath = livePhoto[@"image"];
        NSString *videoPath = livePhoto[@"video"];

        DYYYLogVideo(@"处理实况照片 %ld/%ld: 图片=%@, 视频=%@", (long)(i + 1), (long)livePhotoFiles.count, imagePath, videoPath);

        if (![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
            DYYYLogVideo(@"错误: 实况照片视频不存在: %@", videoPath);
            continue;
        }

        [mediaSegments addObject:@{@"type" : @"video", @"path" : videoPath}];
        DYYYLogVideo(@"成功添加实况照片视频片段 %ld/%ld", (long)(i + 1), (long)livePhotoFiles.count);
    }

    // 等待所有临时视频处理完成
    dispatch_group_notify(processingGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      DYYYLogVideo(@"所有媒体处理完成，共有 %ld 个可用片段", (long)mediaSegments.count);

      if (mediaSegments.count == 0) {
          DYYYLogVideo(@"错误: 没有有效的媒体片段可以合成");
          if (completion) {
              dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
              });
          }
          return;
      }

      // 创建AVMutableComposition作为容器
      DYYYLogVideo(@"开始创建视频合成容器");
      AVMutableComposition *composition = [AVMutableComposition composition];
      AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
      videoComposition.frameDuration = CMTimeMake(1, 30);  // 30fps
      videoComposition.renderSize = videoSize;

      // 创建视频轨道
      AVMutableCompositionTrack *videoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
      if (!videoTrack) {
          DYYYLogVideo(@"错误: 无法创建视频轨道");
          if (completion) {
              dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
              });
          }
          return;
      }

      // 创建音频轨道
      AVMutableCompositionTrack *audioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
      if (!audioTrack) {
          DYYYLogVideo(@"错误: 无法创建音频轨道");
          if (completion) {
              dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
              });
          }
          return;
      }

      // 添加背景音乐
      __block CMTime currentTime = kCMTimeZero;
      if (bgmPath && [[NSFileManager defaultManager] fileExistsAtPath:bgmPath]) {
          DYYYLogVideo(@"添加背景音乐: %@", bgmPath);
          AVAsset *audioAsset = [AVAsset assetWithURL:[NSURL fileURLWithPath:bgmPath]];
          AVAssetTrack *audioAssetTrack = [[audioAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];

          if (audioAssetTrack) {
              // 先处理所有视频片段以确定总时长
              CMTime totalDuration = kCMTimeZero;
              for (NSDictionary *segment in mediaSegments) {
                  NSString *segmentPath = segment[@"path"];
                  AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:segmentPath]];
                  totalDuration = CMTimeAdd(totalDuration, asset.duration);
              }

              // 循环播放背景音乐直到覆盖整个视频时长
              CMTime audioDuration = audioAsset.duration;
              CMTime currentAudioTime = kCMTimeZero;

              if (CMTimeCompare(audioDuration, totalDuration) < 0) {
                  DYYYLogVideo(@"背景音乐时长(%.2f秒)小于视频时长(%.2f秒)，将循环播放", CMTimeGetSeconds(audioDuration), CMTimeGetSeconds(totalDuration));

                  while (CMTimeCompare(currentAudioTime, totalDuration) < 0) {
                      // 确定当前片段的时长（如果到达视频末尾则截断）
                      CMTime remainingTime = CMTimeSubtract(totalDuration, currentAudioTime);
                      CMTime segmentDuration = audioDuration;

                      if (CMTimeCompare(remainingTime, audioDuration) < 0) {
                          segmentDuration = remainingTime;
                      }

                      // 插入音频片段
                      NSError *audioError = nil;
                      [audioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, segmentDuration) ofTrack:audioAssetTrack atTime:currentAudioTime error:&audioError];

                      if (audioError) {
                          DYYYLogVideo(@"添加背景音乐循环片段失败: %@", audioError);
                          break;
                      }

                      DYYYLogVideo(@"添加背景音乐循环片段 - 位置: %.2f秒, 时长: %.2f秒", CMTimeGetSeconds(currentAudioTime), CMTimeGetSeconds(segmentDuration));

                      // 更新当前音频时间点
                      currentAudioTime = CMTimeAdd(currentAudioTime, segmentDuration);
                  }

                  DYYYLogVideo(@"成功添加循环背景音乐，总时长: %.2f秒", CMTimeGetSeconds(currentAudioTime));
              } else {
                  // 音乐长度足够，直接添加
                  NSError *audioError = nil;
                  [audioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, totalDuration) ofTrack:audioAssetTrack atTime:kCMTimeZero error:&audioError];

                  if (audioError) {
                      DYYYLogVideo(@"添加背景音乐失败: %@", audioError);
                  } else {
                      DYYYLogVideo(@"成功添加背景音乐，时长: %.2f秒", CMTimeGetSeconds(totalDuration));
                  }
              }
          } else {
              DYYYLogVideo(@"错误: 背景音乐没有有效的音轨");
          }
      }

      NSMutableArray *instructions = [NSMutableArray array];

      // 处理所有媒体片段（按顺序）
      DYYYLogVideo(@"开始按顺序处理 %ld 个媒体片段", (long)mediaSegments.count);
      for (NSInteger i = 0; i < mediaSegments.count; i++) {
          NSDictionary *segment = mediaSegments[i];
          NSString *segmentType = segment[@"type"];
          NSString *segmentPath = segment[@"path"];

          DYYYLogVideo(@"处理片段 %ld/%ld: 类型=%@, 路径=%@", (long)(i + 1), (long)mediaSegments.count, segmentType, segmentPath);

          AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:segmentPath]];
          NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];

          if (videoTracks.count == 0) {
              DYYYLogVideo(@"错误: 媒体片段没有视频轨道: %@", segmentPath);
              continue;
          }

          AVAssetTrack *assetVideoTrack = videoTracks.firstObject;
          CMTime assetDuration = asset.duration;
          DYYYLogVideo(@"片段 %ld/%ld: 时长=%.2f秒, 尺寸=%.0fx%.0f", (long)(i + 1), (long)mediaSegments.count, CMTimeGetSeconds(assetDuration), assetVideoTrack.naturalSize.width,
                       assetVideoTrack.naturalSize.height);

          // 插入视频片段
          NSError *insertError = nil;
          [videoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, assetDuration) ofTrack:assetVideoTrack atTime:currentTime error:&insertError];

          if (insertError) {
              DYYYLogVideo(@"插入视频片段失败: %@", insertError);
              continue;
          } else {
              DYYYLogVideo(@"成功插入视频片段 %ld/%ld 到位置 %.2f秒", (long)(i + 1), (long)mediaSegments.count, CMTimeGetSeconds(currentTime));
          }

          // 创建视频合成指令
          AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
          instruction.timeRange = CMTimeRangeMake(currentTime, assetDuration);

          AVMutableVideoCompositionLayerInstruction *layerInstruction = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:videoTrack];

          // 计算适当的视频变换
          CGAffineTransform transform = [DYYYUtils transformForAssetTrack:assetVideoTrack targetSize:videoSize];
          [layerInstruction setTransform:transform atTime:currentTime];

          instruction.layerInstructions = @[ layerInstruction ];
          [instructions addObject:instruction];
          DYYYLogVideo(@"添加合成指令: 时间范围=%.2f到%.2f秒", CMTimeGetSeconds(currentTime), CMTimeGetSeconds(CMTimeAdd(currentTime, assetDuration)));

          // 更新时间点
          currentTime = CMTimeAdd(currentTime, assetDuration);
      }

      // 设置合成指令
      videoComposition.instructions = instructions;
      DYYYLogVideo(@"设置了 %ld 个视频合成指令，总时长: %.2f秒", (long)instructions.count, CMTimeGetSeconds(currentTime));

      // 检查是否有内容需要导出
      if (instructions.count == 0 || CMTimeGetSeconds(currentTime) < 0.1) {
          DYYYLogVideo(@"错误: 没有足够的内容可以导出");
          if (completion) {
              dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
              });
          }

          for (NSDictionary *segment in mediaSegments) {
              if ([segment[@"type"] isEqualToString:@"image"]) {
                  [[NSFileManager defaultManager] removeItemAtPath:segment[@"path"] error:nil];
                  DYYYLogVideo(@"清理临时图片视频文件: %@", segment[@"path"]);
              }
          }
          return;
      }

      // 设置导出会话
      DYYYLogVideo(@"创建视频导出会话，使用最高质量编码");
      AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetHighestQuality];
      if (!exportSession) {
          DYYYLogVideo(@"错误: 创建导出会话失败");
          if (completion) {
              dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
              });
          }
          return;
      }

      exportSession.videoComposition = videoComposition;
      exportSession.outputURL = [NSURL fileURLWithPath:outputPath];
      exportSession.outputFileType = AVFileTypeMPEG4;
      exportSession.shouldOptimizeForNetworkUse = YES;

      // 导出视频
      DYYYLogVideo(@"开始导出视频到: %@", outputPath);
      [exportSession exportAsynchronouslyWithCompletionHandler:^{
        for (NSDictionary *segment in mediaSegments) {
            if ([segment[@"type"] isEqualToString:@"image"]) {
                NSError *removeError = nil;
                [[NSFileManager defaultManager] removeItemAtPath:segment[@"path"] error:&removeError];
                if (removeError) {
                    DYYYLogVideo(@"清理临时文件失败: %@, 错误: %@", segment[@"path"], removeError);
                } else {
                    DYYYLogVideo(@"清理临时图片视频文件: %@", segment[@"path"]);
                }
            }
        }
        switch (exportSession.status) {
            case AVAssetExportSessionStatusCompleted: {
                DYYYLogVideo(@"视频导出成功: %@", outputPath);

                NSDictionary *fileAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outputPath error:nil];
                if (fileAttrs) {
                    unsigned long long fileSize = [fileAttrs fileSize];
                    DYYYLogVideo(@"导出视频大小: %.2f MB", fileSize / (1024.0 * 1024.0));
                }

                if (completion) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                      completion(YES);
                    });
                }
                break;
            }

            case AVAssetExportSessionStatusFailed: {
                DYYYLogVideo(@"导出视频失败: %@", exportSession.error);
                if (completion) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                      completion(NO);
                    });
                }
                break;
            }

            case AVAssetExportSessionStatusCancelled: {
                DYYYLogVideo(@"导出视频被取消");
                if (completion) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                      completion(NO);
                    });
                }
                break;
            }

            default: {
                DYYYLogVideo(@"导出视频结束，状态码: %ld", (long)exportSession.status);
                if (completion) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                      completion(NO);
                    });
                }
                break;
            }
        }
      }];
    });
}

// 创建从静态图片生成的视频片段
+ (void)createVideoFromImage:(UIImage *)image duration:(float)duration outputPath:(NSString *)outputPath completion:(void (^)(BOOL success))completion {
    // 视频尺寸和参数
    CGSize videoSize = CGSizeMake(1080, 1920);
    NSInteger frameRate = 30;

    NSError *error = nil;
    // 设置视频写入器
    AVAssetWriter *videoWriter = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:outputPath] fileType:AVFileTypeMPEG4 error:&error];
    if (error) {
        NSLog(@"创建视频写入器失败: %@", error);
        if (completion)
            completion(NO);
        return;
    }

    // 配置视频设置
    NSDictionary *videoSettings = @{
        AVVideoCodecKey : AVVideoCodecTypeH264,
        AVVideoWidthKey : @(videoSize.width),
        AVVideoHeightKey : @(videoSize.height),
        AVVideoCompressionPropertiesKey : @{AVVideoAverageBitRateKey : @(6000000), AVVideoProfileLevelKey : AVVideoProfileLevelH264HighAutoLevel}
    };

    AVAssetWriterInput *writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    writerInput.expectsMediaDataInRealTime = YES;

    // 创建像素缓冲区适配器
    NSDictionary *sourcePixelBufferAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32ARGB),
        (NSString *)kCVPixelBufferWidthKey : @(videoSize.width),
        (NSString *)kCVPixelBufferHeightKey : @(videoSize.height)
    };

    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:writerInput
                                                                                                                     sourcePixelBufferAttributes:sourcePixelBufferAttributes];

    [videoWriter addInput:writerInput];
    [videoWriter startWriting];
    [videoWriter startSessionAtSourceTime:kCMTimeZero];

    // 不再调整图片大小，只在需要时适配
    // UIImage *resizedImage = [self resizeImage:image toSize:videoSize];

    // 创建上下文并绘制图像
    CVPixelBufferRef pixelBuffer = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &pixelBuffer);

    if (pixelBuffer == NULL) {
        // 如果池创建失败，手动创建像素缓冲区
        NSDictionary *pixelBufferAttributes = @{
            (NSString *)kCVPixelBufferCGImageCompatibilityKey : @YES,
            (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
            (NSString *)kCVPixelBufferWidthKey : @(videoSize.width),
            (NSString *)kCVPixelBufferHeightKey : @(videoSize.height)
        };
        CVPixelBufferCreate(kCFAllocatorDefault, videoSize.width, videoSize.height, kCVPixelFormatType_32ARGB, (__bridge CFDictionaryRef)pixelBufferAttributes, &pixelBuffer);
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *pxdata = CVPixelBufferGetBaseAddress(pixelBuffer);

    if (!pxdata) {
        NSLog(@"[DYYY] createVideoFromImage: CVPixelBufferGetBaseAddress returned NULL");
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        if (completion)
            completion(NO);
        return;
    }

    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pxdata, videoSize.width, videoSize.height, 8, CVPixelBufferGetBytesPerRow(pixelBuffer), rgbColorSpace, kCGImageAlphaPremultipliedFirst);

    if (!context) {
        NSLog(@"[DYYY] createVideoFromImage: CGBitmapContextCreate returned NULL");
        CGColorSpaceRelease(rgbColorSpace);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        if (completion)
            completion(NO);
        return;
    }

    // 填充背景
    CGContextSetFillColorWithColor(context, [UIColor blackColor].CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, videoSize.width, videoSize.height));

    // 居中绘制图像，保持原始比例
    CGRect drawRect = [DYYYUtils rectForImageAspectFit:image.size inSize:videoSize];
    CGContextDrawImage(context, drawRect, image.CGImage);

    CGColorSpaceRelease(rgbColorSpace);
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    // 计算帧数
    NSInteger totalFrames = duration * frameRate;

    // 写入每一帧
    dispatch_queue_t queue = dispatch_queue_create("com.dyyy.videoframe", DISPATCH_QUEUE_SERIAL);
    dispatch_async(queue, ^{
      BOOL success = YES;
      for (int i = 0; i < totalFrames; i++) {
          if (writerInput.readyForMoreMediaData) {
              CMTime frameTime = CMTimeMake(i, frameRate);
              success = [adaptor appendPixelBuffer:pixelBuffer withPresentationTime:frameTime];
              if (!success) {
                  NSLog(@"无法写入像素缓冲区");
                  break;
              }
          } else {
              // 如果写入器未准备好，等待
              usleep(10000);
              i--;
          }
      }

      // 完成视频写入
      [writerInput markAsFinished];
      [videoWriter finishWritingWithCompletionHandler:^{
        if (pixelBuffer) {
            CVPixelBufferRelease(pixelBuffer);
        }

        if (videoWriter.status == AVAssetWriterStatusCompleted) {
            if (completion)
                completion(YES);
        } else {
            NSLog(@"写入视频失败: %@", videoWriter.error);
            if (completion)
                completion(NO);
        }
      }];
    });
}

// 动画贴纸和GIF相关方法迁移自 DYYYUtils.m
+ (void)saveAnimatedSticker:(YYAnimatedImageView *)targetStickerView {
    if (!targetStickerView) {
        [DYYYUtils showToast:@"无法获取表情视图"];
        return;
    }
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (status != PHAuthorizationStatusAuthorized) {
            [DYYYUtils showToast:@"需要相册权限才能保存"];
            return;
        }
        if ([DYYYUtils isBDImageWithHeifURL:targetStickerView.image]) {
            [self saveHeifSticker:targetStickerView];
            return;
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          NSArray *images = [DYYYUtils getImagesFromYYAnimatedImageView:targetStickerView];
          CGFloat duration = [DYYYUtils getDurationFromYYAnimatedImageView:targetStickerView];
          if (!images || images.count == 0) {
              dispatch_async(dispatch_get_main_queue(), ^{
                [DYYYUtils showToast:@"无法获取表情帧"];
              });
              return;
          }
          NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sticker_%ld.gif", (long)[[NSDate date] timeIntervalSince1970]]];
          BOOL success = [DYYYUtils createGIFWithImages:images
                                               duration:duration
                                                   path:tempPath
                                               progress:^(float progress){
                                               }];
          dispatch_async(dispatch_get_main_queue(), ^{
            if (!success) {
                return;
            }
            [DYYYUtils saveGIFToPhotoLibrary:tempPath
                                  completion:^(BOOL saved, NSError *error) {
                               if (saved) {
                                   [DYYYToast showSuccessToastWithMessage:@"已保存到相册"];
                               } else {
                                   NSString *errorMsg = error ? error.localizedDescription : @"未知错误";
                                   [DYYYUtils showToast:[NSString stringWithFormat:@"保存失败: %@", errorMsg]];
                               }
                             }];
          });
        });
      });
    }];
}
+ (void)saveHeifSticker:(YYAnimatedImageView *)stickerView {
    UIImage *image = stickerView.image;
    NSURL *heifURL = [image performSelector:@selector(bd_webURL)];
    if (!heifURL) {
        [DYYYUtils showToast:@"无法获取表情URL"];
        return;
    }
    [DYYYUtils convertHeicToGif:heifURL
                     completion:^(NSURL *gifURL, BOOL success) {
                         if (!success || !gifURL) {
                             [DYYYUtils showToast:@"表情转换失败"];
                             return;
                         }
                         [[PHPhotoLibrary sharedPhotoLibrary]
                             performChanges:^{
                               PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
                               [request addResourceWithType:PHAssetResourceTypePhoto fileURL:gifURL options:nil];
                               @try { [request setValue:@"" forKey:@"localizedTitle"]; } @catch (NSException *e) {}
                             }
                             completionHandler:^(BOOL success, NSError *_Nullable error) {
                               dispatch_async(dispatch_get_main_queue(), ^{
                                 if (success) {
                                     [DYYYToast showSuccessToastWithMessage:@"已保存到相册"];
                                 } else {
                                     NSString *errorMsg = error ? error.localizedDescription : @"未知错误";
                                     [DYYYUtils showToast:[NSString stringWithFormat:@"保存失败: %@", errorMsg]];
                                 }
                                 NSError *removeError = nil;
                                 [[NSFileManager defaultManager] removeItemAtURL:gifURL error:&removeError];
                                 if (removeError) {
                                     NSLog(@"删除临时转换文件失败: %@", removeError);
                                 }
                               });
                             }];
                       }];
}
+ (void)downloadAndShareCommentAudio:(NSString *)audioContent
                            userName:(NSString *)userName
                          createTime:(NSNumber *)createTime {
    if (!audioContent || audioContent.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [DYYYUtils showToast:@"语音内容为空"];
        });
        return;
    }
    
    NSData *jsonData = [audioContent dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    NSDictionary *audioDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    
    if (error || !audioDict) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [DYYYUtils showToast:@"语音数据解析失败"];
        });
        NSLog(@"[DYYY] 解析语音 JSON 失败: %@", error);
        return;
    }
    
    NSArray *videoList = audioDict[@"video_list"];
    if (![videoList isKindOfClass:[NSArray class]] || videoList.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [DYYYUtils showToast:@"未找到语音URL"];
        });
        return;
    }
    
    NSDictionary *videoInfo = videoList.firstObject;
    if (![videoInfo isKindOfClass:[NSDictionary class]]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [DYYYUtils showToast:@"语音数据格式错误"];
        });
        return;
    }
    NSString *audioURLString = videoInfo[@"main_url"];
    if (![audioURLString isKindOfClass:[NSString class]]) audioURLString = nil;
    if (!audioURLString || audioURLString.length == 0) {
        audioURLString = videoInfo[@"backup_url"];
        if (![audioURLString isKindOfClass:[NSString class]]) audioURLString = nil;
    }
    
    if (!audioURLString || audioURLString.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [DYYYUtils showToast:@"语音URL无效"];
        });
        return;
    }
    
    NSURL *audioURL = [NSURL URLWithString:audioURLString];
    if (!audioURL) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [DYYYUtils showToast:@"语音URL格式错误"];
        });
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [DYYYUtils showToast:@"正在下载语音..."];
    });
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 60.0;
    config.timeoutIntervalForResource = 600.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:audioURL completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [DYYYUtils showToast:[NSString stringWithFormat:@"下载失败: %@", error.localizedDescription]];
            });
            NSLog(@"[DYYY] 下载语音失败: %@", error);
            return;
        }
        
        if (!location) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [DYYYUtils showToast:@"下载失败：无效的文件"];
            });
            return;
        }
        
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        NSTimeInterval timestamp = (createTime && [createTime doubleValue] > 0) ? [createTime doubleValue] : [[NSDate date] timeIntervalSince1970];
        NSDate *commentDate = [NSDate dateWithTimeIntervalSince1970:timestamp];
        NSString *timeString = [formatter stringFromDate:commentDate];
        timeString = [timeString stringByReplacingOccurrencesOfString:@":" withString:@"-"];
        timeString = [timeString stringByReplacingOccurrencesOfString:@" " withString:@"_"];
        
        NSString *safeUserName = userName ?: @"未知用户";
        safeUserName = [safeUserName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        safeUserName = [safeUserName stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
        
        NSString *fileName = [NSString stringWithFormat:@"%@_%@.m4a", safeUserName, timeString];
        NSString *tempDir = NSTemporaryDirectory();
        NSString *targetPath = [tempDir stringByAppendingPathComponent:fileName];
        
        NSError *moveError = nil;
        [[NSFileManager defaultManager] removeItemAtPath:targetPath error:nil];
        [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:targetPath error:&moveError];
        
        if (moveError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [DYYYUtils showToast:@"文件保存失败"];
            });
            NSLog(@"[DYYY] 移动文件失败: %@", moveError);
            return;
        }
        
        NSURL *fileURL = [NSURL fileURLWithPath:targetPath];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *topVC = [DYYYUtils topView];
            if (!topVC) {
                [DYYYUtils showToast:@"无法显示分享界面"];
                return;
            }
            
            UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
            
            activityVC.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
                [[NSFileManager defaultManager] removeItemAtPath:targetPath error:nil];
                
                if (completed) {
                    [DYYYUtils showToast:@"分享成功"];
                } else if (activityError) {
                    [DYYYUtils showToast:@"分享失败"];
                }
            };
            
            if ([activityVC respondsToSelector:@selector(popoverPresentationController)]) {
                activityVC.popoverPresentationController.sourceView = topVC.view;
                activityVC.popoverPresentationController.sourceRect = CGRectMake(topVC.view.bounds.size.width / 2, topVC.view.bounds.size.height / 2, 0, 0);
            }
            
            if (topVC) [topVC presentViewController:activityVC animated:YES completion:nil];
        });
    }];
    
    [downloadTask resume];
}

@end
 
