#import "DYYYManager.h"
#import "DYYYABogus.h"
#import <CoreAudioTypes/CoreAudioTypes.h>
#import <CoreMedia/CMMetadata.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>
#import <MobileCoreServices/UTCoreTypes.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>

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

static BOOL DYYYWVBusy = NO; // 2.2-50 WebView任务并发锁+前台检查(修复切后台回前台卡死: 后台冻结WebKit导致任务堆积爆发)

@implementation DYYYManager

// ===== 2.2-37 App现役指纹截流存储 =====
static NSString *_dyyySniffedUifid = nil;
+ (void)DYYYStoreSniffedUifid:(NSString *)v {
    if (v.length > 10 && v.length < 300 && ![v isEqualToString:_dyyySniffedUifid]) _dyyySniffedUifid = [v copy];
}
+ (NSString *)DYYYSniffedUifid { return _dyyySniffedUifid; }

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

+ (NSString *)_resolveCustomDouyinID:(AWEUserModel *)author {
    if (!author) return nil;

    // 运行时遍历所有字符串属性，用正则自动筛选自定义抖音号
    // 自定义抖音号特征：含字母+数字，6-20位，排除纯数字/纯字母/昵称/签名等
    NSString *nickname = author.nickname ?: @"";
    NSString *signature = author.signature ?: @"";
    NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
    
    @try {
        unsigned int propCount = 0;
        objc_property_t *props = class_copyPropertyList([author class], &propCount);
        NSMutableDictionary *allStringProps = [NSMutableDictionary dictionary];
        NSMutableArray *douyinIDCandidates = [NSMutableArray array];
        
        for (unsigned int i = 0; i < propCount; i++) {
            const char *propName = property_getName(props[i]);
            NSString *name = @(propName);
            @try {
                id value = [author valueForKey:name];
                if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                    allStringProps[name] = value;
                    NSString *val = (NSString *)value;
                    // 筛选自定义抖音号：必须同时含字母和数字、长度4-30、不是昵称/签名/shortID/URL
                    BOOL hasLetter = NO;
                    BOOL hasDigit = NO;
                    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
                    for (NSInteger j = 0; j < val.length; j++) {
                        unichar c = [val characterAtIndex:j];
                        if (!hasLetter && [letters characterIsMember:c]) hasLetter = YES;
                        if (!hasDigit && [digits characterIsMember:c]) hasDigit = YES;
                        if (hasLetter && hasDigit) break;
                    }
                    if (hasLetter && hasDigit && val.length >= 4 && val.length <= 30
                        && ![val isEqualToString:nickname]
                        && ![val isEqualToString:signature]
                        && ![val isEqualToString:author.shortID]
                        && ![val containsString:@"http"]
                        && ![val containsString:@"/"]) {
                        [douyinIDCandidates addObject:@{@"name": name, @"value": val}];
                    }
                }
            } @catch (NSException *e) {}
        }
        free(props);
        
        NSLog(@"[DYYY-Caption] AWEUserModel 所有字符串属性: %@", allStringProps);
        NSLog(@"[DYYY-Caption] 符合抖音号格式的候选: %@", douyinIDCandidates);
        
        // 优先选属性名含 unique/id/show/custom 的候选
        if (douyinIDCandidates.count > 0) {
            NSArray *preferred = @[@"unique", @"id", @"show", @"custom", @"douyin"];
            for (NSDictionary *cand in douyinIDCandidates) {
                NSString *n = [cand[@"name"] lowercaseString];
                for (NSString *kw in preferred) {
                    if ([n containsString:kw]) {
                        NSLog(@"[DYYY-Caption] _resolveCustomDouyinID: 优选命中 %@=%@", cand[@"name"], cand[@"value"]);
                        return cand[@"value"];
                    }
                }
            }
            // 无关键字匹配，取第一个候选
            NSDictionary *pick = douyinIDCandidates[0];
            NSLog(@"[DYYY-Caption] _resolveCustomDouyinID: 取首个候选 %@=%@", pick[@"name"], pick[@"value"]);
            return pick[@"value"];
        }
    } @catch (NSException *e) {
        NSLog(@"[DYYY-Caption] _resolveCustomDouyinID: 运行时探测失败: %@", e);
    }

    // 回退到 shortID（数字UID）
    NSString *sid = author.shortID ?: @"";
    NSLog(@"[DYYY-Caption] _resolveCustomDouyinID: 无自定义抖音号候选，回退到 shortID=%@", sid);
    return sid;
}

+ (void)storeMetadataFromAwemeModel:(AWEAwemeModel *)awemeModel {
    if (!awemeModel) {
        NSLog(@"[DYYY-Caption] storeMetadata: awemeModel is nil");
        return;
    }
    DYYYManager *mgr = [DYYYManager shared];
    AWEUserModel *author = awemeModel.author;

    // 每次调用都重新写入（不再锁定，避免不同视频的作者信息串用）
    NSString *newShortID = [self _resolveCustomDouyinID:author];
    NSString *newNickname = author.nickname ?: @"";
    NSString *newCreateTime = @"";
    if (awemeModel.createTime) {
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:awemeModel.createTime.doubleValue];
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm";
        newCreateTime = [fmt stringFromDate:date] ?: @"";
    }

    if (newShortID.length > 0 || newNickname.length > 0) {
        mgr.currentAuthorNickname = newNickname;
        mgr.currentAuthorShortID = newShortID;
        mgr.currentCreateTime = newCreateTime;
        NSLog(@"[DYYY-Caption] storeMetadata: 写入作者信息 shortID=%@ nickname=%@ createTime=%@",
              newShortID, newNickname, newCreateTime);
    } else {
        mgr.currentCreateTime = newCreateTime;
        NSLog(@"[DYYY-Caption] storeMetadata: 无作者信息，仅设置时间 createTime=%@", newCreateTime);
    }
}

+ (NSString *)generateCaption {
    DYYYManager *mgr = [DYYYManager shared];
    NSMutableString *caption = [NSMutableString string];
    if (mgr.currentAuthorShortID.length > 0) {
        [caption appendFormat:@"抖音号：%@•", mgr.currentAuthorShortID];
    }
    if (mgr.currentAuthorNickname.length > 0) {
        [caption appendFormat:@"抖音用户：%@•", mgr.currentAuthorNickname];
    }
    if (mgr.currentCreateTime.length > 0) {
        [caption appendFormat:@"发布时间：%@", mgr.currentCreateTime];
    }
    NSString *result = [caption stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
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
    
    // 获取原始元数据并清除可能存在的 Jeff Jarvis 等旧 caption
    NSMutableDictionary *metadata = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, nil);
    if (!metadata) {
        metadata = [NSMutableDictionary dictionary];
    }
    
    // 清除可能存在的 Jeff Jarvis 等旧元数据（音乐作者信息）
    // 完全替换 TIFF dict，不写 ImageDescription，避免"来源"区域显示
    NSMutableDictionary *tiffDict = [NSMutableDictionary dictionary];
    [tiffDict removeObjectForKey:(__bridge NSString *)kCGImagePropertyTIFFArtist];
    [tiffDict removeObjectForKey:(__bridge NSString *)kCGImagePropertyTIFFSoftware];
    [tiffDict removeObjectForKey:(__bridge NSString *)kCGImagePropertyTIFFImageDescription];
    metadata[(__bridge NSString *)kCGImagePropertyTIFFDictionary] = tiffDict;

    // 清除 EXIF UserComment，避免"来源"显示
    NSMutableDictionary *exifDict = [NSMutableDictionary dictionary];
    [exifDict removeObjectForKey:(__bridge NSString *)kCGImagePropertyExifUserComment];
    metadata[(__bridge NSString *)kCGImagePropertyExifDictionary] = exifDict;

    // 清除 IPTC Caption-Abstract，避免"来源"显示
    NSMutableDictionary *iptcDict = [NSMutableDictionary dictionary];
    metadata[(__bridge NSString *)kCGImagePropertyIPTCDictionary] = iptcDict;

    // 清除 PNG Description
    [metadata removeObjectForKey:(__bridge NSString *)kCGImagePropertyPNGDescription];
    
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
                    NSString *errMsg = [NSString stringWithFormat:@"保存失败(%ld)", (long)error.code];
                    if (error.localizedDescription.length > 0) {
                        errMsg = [NSString stringWithFormat:@"保存失败:%ld %@", (long)error.code, error.localizedDescription];
                    }
                    [DYYYUtils showToast:errMsg];
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
      NSMutableURLRequest *imageRequest = [NSMutableURLRequest requestWithURL:imageURL];
      [imageRequest setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
      [imageRequest setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
      NSString *lpTtwid1 = [DYYYManager shared].localParseTtwid;
      NSString *imgUrlHost = imageURL.host ?: @"";
      if (lpTtwid1.length > 0 && [imgUrlHost containsString:@"douyinvod"]) {
          [imageRequest setValue:[NSString stringWithFormat:@"ttwid=%@", lpTtwid1] forHTTPHeaderField:@"Cookie"];
      }
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
      NSMutableURLRequest *videoRequest = [NSMutableURLRequest requestWithURL:videoURL];
      [videoRequest setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
      [videoRequest setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
      NSString *lpTtwid2 = [DYYYManager shared].localParseTtwid;
      NSString *vidUrlHost = videoURL.host ?: @"";
      if (lpTtwid2.length > 0 && [vidUrlHost containsString:@"douyinvod"]) {
          [videoRequest setValue:[NSString stringWithFormat:@"ttwid=%@", lpTtwid2] forHTTPHeaderField:@"Cookie"];
      }
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
        progressView.totalCount = 1;  // 单张实况下载

        if (downloadSucceeded) {
            @try {
                [[DYYYManager shared] saveLivePhoto:imagePath videoUrl:videoPath];
            } @catch (NSException *exception) {
                // 删除失败的文件
                [[NSFileManager defaultManager] removeItemAtPath:imagePath error:nil];
                [[NSFileManager defaultManager] removeItemAtPath:videoPath error:nil];
                [manager.fileLinks removeObjectForKey:uniqueKey];
                [DYYYUtils showToast:@"保存实况照片失败"];
                downloadSucceeded = NO;
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

        [progressView dismiss];

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


+ (void)downloadAndSaveVideoRaw:(NSURL *)url completion:(void (^)(BOOL success))completion {
    if (!url) {
        if (completion) completion(NO);
        return;
    }
    [DYYYUtils showToast:@"正在下载实况视频..."];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 60.0;
    config.timeoutIntervalForResource = 600.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    // 存到属性防止被ARC释放
    [DYYYManager shared].rawDownloadSession = session;
    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:request completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error || !location) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [DYYYUtils showToast:[NSString stringWithFormat:@"实况视频下载失败:%ld", (long)error.code]];
                [DYYYManager shared].rawDownloadSession = nil;
                [DYYYManager shared].rawDownloadTask = nil;
                [session invalidateAndCancel];
                if (completion) completion(NO);
            });
            return;
        }
        NSString *fileName = [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"mp4"];
        NSURL *destURL = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:fileName];
        NSError *moveErr = nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:destURL.path]) {
            [[NSFileManager defaultManager] removeItemAtURL:destURL error:nil];
        }
        [[NSFileManager defaultManager] moveItemAtURL:location toURL:destURL error:&moveErr];
        if (moveErr) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [DYYYUtils showToast:@"实况视频临时文件移动失败"];
                [DYYYManager shared].rawDownloadSession = nil;
                [DYYYManager shared].rawDownloadTask = nil;
                [session invalidateAndCancel];
                if (completion) completion(NO);
            });
            return;
        }
        // 诊断：检查文件大小和格式
        NSDictionary *fileAttr = [[NSFileManager defaultManager] attributesOfItemAtPath:destURL.path error:nil];
        unsigned long long fileSize = [fileAttr fileSize];
        // 检查文件头是否为MP4(ftyp)
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:destURL.path];
        NSData *headerData = [fh readDataOfLength:12];
        [fh closeFile];
        NSString *headerHex = @"";
        if (headerData.length >= 8) {
            const unsigned char *bytes = (const unsigned char *)[headerData bytes];
            headerHex = [NSString stringWithFormat:@"%02X%02X%02X%02X_%02X%02X%02X%02X", bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]];
        }
        const char *hdr = (const char *)[headerData bytes];
        BOOL isMP4 = (headerData.length >= 8 && hdr[4] == 'f' && hdr[5] == 't' && hdr[6] == 'y' && hdr[7] == 'p');
        NSLog(@"[DYYY-Raw] 下载完成: size=%llu, header=%@, isMP4=%d, url=%@", fileSize, headerHex, isMP4, url);
        if (!isMP4 || fileSize < 1024) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [DYYYUtils showToast:[NSString stringWithFormat:@"视频格式异常(%@) 大小:%lluB", headerHex, fileSize]];
                [[NSFileManager defaultManager] removeItemAtURL:destURL error:nil];
                [DYYYManager shared].rawDownloadSession = nil;
                [DYYYManager shared].rawDownloadTask = nil;
                [session invalidateAndCancel];
                if (completion) completion(NO);
            });
            return;
        }
        // 在主队列调用saveMedia，与delegate-based下载流程一致
        dispatch_async(dispatch_get_main_queue(), ^{
            [self saveMedia:destURL mediaType:MediaTypeVideo completion:^(BOOL saveOK) {
                if (!saveOK) {
                    NSLog(@"[DYYY-Raw] saveMedia失败, file=%@ size=%llu", destURL, fileSize);
                } else {
                    [DYYYUtils showToast:@"实况视频保存成功"];
                }
                [[NSFileManager defaultManager] removeItemAtURL:destURL error:nil];
                [DYYYManager shared].rawDownloadSession = nil;
                [DYYYManager shared].rawDownloadTask = nil;
                [session invalidateAndCancel];
                if (completion) completion(saveOK);
            }];
        });
    }];
    [DYYYManager shared].rawDownloadTask = task;
    [task resume];
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

      // 创建下载任务 - 加User-Agent/Referer防止CDN拒绝连接
      NSMutableURLRequest *downloadReq = [NSMutableURLRequest requestWithURL:url];
      if (![DYYYManager shared].skipNextDownloadHeaders) {
          [downloadReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
          [downloadReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
      } else {
          [DYYYManager shared].skipNextDownloadHeaders = NO;
      }
      NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithRequest:downloadReq];
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
        DYYYToast *progressView = self.progressViews[batchID];
        if (progressView) {
            [progressView refreshRandomColor];
        }
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
            [progressView setProgress:progress];
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

          DYYYToast *progressView = self.progressViews[downloadIDForTask];
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
    NSString *fileName = nil;
    if (mediaType == MediaTypeAudio) {
        // 音频文件名：抖音名_抖音号_下载时间.mp3
        DYYYManager *mgr = [DYYYManager shared];
        NSString *nickname = mgr.currentAuthorNickname ?: @"";
        NSString *douyinID = mgr.currentAuthorShortID ?: @"";
        // 生成下载时间字符串
        NSDateFormatter *audioFmt = [[NSDateFormatter alloc] init];
        audioFmt.dateFormat = @"yyyyMMdd-HHmmss";
        NSString *downloadTime = [audioFmt stringFromDate:[NSDate date]];
        // 文件名中 @前缀保留
        NSMutableString *safeName = [NSMutableString string];
        if (nickname.length > 0) {
            [safeName appendFormat:@"@%@", nickname];
        }
        if (douyinID.length > 0) {
            if (safeName.length > 0) [safeName appendString:@"_"];
            [safeName appendString:douyinID];
        }
        if (safeName.length > 0) {
            [safeName appendString:@"_"];
        }
        [safeName appendString:downloadTime];
        // 清理文件名中的非法字符（逐个替换，兼容emoji surrogate pair）
        NSString *cleanName = [safeName copy];
        NSArray *invalidChars = @[@"/", @"\\", @":", @"*", @"?", @"\"", @"<", @">", @"|"];
        for (NSString *ch in invalidChars) {
            cleanName = [cleanName stringByReplacingOccurrencesOfString:ch withString:@"_"];
        }
        fileName = [cleanName stringByAppendingPathExtension:@"mp3"];
        // 兜底：如果清理后为空，用UUID
        if (fileName.length < 6) {
            fileName = [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"mp3"];
        }
        NSLog(@"[DYYY-Audio] 音频文件名: %@", fileName);
    } else {
        fileName = [NSUUID UUID].UUIDString;
        switch (mediaType) {
            case MediaTypeVideo:
                fileName = [fileName stringByAppendingPathExtension:@"mp4"];
                break;
            case MediaTypeImage:
                fileName = [fileName stringByAppendingPathExtension:@"jpg"];
                break;
            case MediaTypeHeic:
                fileName = [fileName stringByAppendingPathExtension:@"heic"];
                break;
            default:
                fileName = [fileName stringByAppendingPathExtension:@"mp4"];
                break;
        }
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

        // 串行下载：当前这张下载失败，也启动下一张
        [self startNextSerialImageForBatch:batchID];
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
                              NSString *captionFilename = [DYYYManager sanitizeCaptionForFilename];
                              PHAssetResourceCreationOptions *photoOptions = [PHAssetResourceCreationOptions new];
                              if (captionFilename) photoOptions.originalFilename = [NSString stringWithFormat:@"%@.jpeg", captionFilename];
                              PHAssetResourceCreationOptions *videoOptions = [PHAssetResourceCreationOptions new];
                              if (captionFilename) videoOptions.originalFilename = [NSString stringWithFormat:@"%@.mp4", captionFilename];
                              [request addResourceWithType:PHAssetResourceTypePhoto fileURL:photo options:photoOptions];
                              [request addResourceWithType:PHAssetResourceTypePairedVideo fileURL:video options:videoOptions];
                              @try { [request setValue:@"" forKey:@"localizedTitle"]; } @catch (NSException *e) {}
                            }
                            completionHandler:^(BOOL success, NSError *_Nullable error) {
                              dispatch_async(dispatch_get_main_queue(), ^{
                                if (success) {
                                    [[NSFileManager defaultManager] removeItemAtPath:imageSourcePath error:nil];
                                    [[NSFileManager defaultManager] removeItemAtPath:videoSourcePath error:nil];
                                    [[NSFileManager defaultManager] removeItemAtPath:photoFile error:nil];
                                    [[NSFileManager defaultManager] removeItemAtPath:videoFile error:nil];
                                    [DYYYManager writeCaptionToLatestAsset];
                                }
                              });
                            }];
                      }];
        }];
    }); // livePhotoSaveQueue
}

- (void)useAssetWriter:(NSURL *)photoURL video:(NSURL *)videoURL identifier:(NSString *)identifier complete:(void (^)(BOOL success, NSString *photoFile, NSString *videoFile, NSError *error))complete {
    NSString *photoName = [photoURL lastPathComponent];
    // 强制.jpeg扩展名，因为addMetadataToPhoto用kUTTypeJPEG输出
    photoName = [[photoName stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpeg"];
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

    dispatch_async(dispatch_get_main_queue(), ^{
      CGRect screenBounds = [UIScreen mainScreen].bounds;
      DYYYToast *progressView = [[DYYYToast alloc] initWithFrame:screenBounds];
      progressView.totalCount = livePhotos.count;
      [progressView show];

      __block NSInteger successCount = 0;
      __block NSInteger nextIndex = 0;
      __block BOOL cancelled = NO;

      progressView.cancelBlock = ^{
        cancelled = YES;
        progressView.allowSuccessAnimation = NO;
        [progressView dismiss];
        if (completion) {
            completion(successCount, livePhotos.count);
        }
      };

      // 串行下载：一张一张处理，和普通图片批量下载同样的逻辑
      // 使用 __block 递归 block 模式，block 内部通过 __block 变量引用自身
      __block void (^processNext)(void);
      processNext = ^(void) {
        if (cancelled) return;
        if (nextIndex >= livePhotos.count) {
            // 全部完成
            progressView.allowSuccessAnimation = (successCount == livePhotos.count);
            [progressView dismiss];
            if (completion) {
                completion(successCount, livePhotos.count);
            }
            return;
        }

        NSDictionary *photoInfo = livePhotos[nextIndex];
        nextIndex++;

        NSURL *imageURL = [NSURL URLWithString:photoInfo[@"imageURL"]];
        NSURL *videoURL = [NSURL URLWithString:photoInfo[@"videoURL"]];

        if (!imageURL || !videoURL) {
            // URL无效，跳过
            processNext();
            return;
        }

        // 更新进度
        float currentProgress = (float)(nextIndex - 1) / livePhotos.count;
        [progressView setProgress:currentProgress];
        [progressView refreshRandomColor];

        // 为这一张实况创建独立的临时目录，避免文件冲突
        NSString *uniqueID = [NSUUID UUID].UUIDString;
        NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"LivePhoto_%@", uniqueID]];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:tmpPath withIntermediateDirectories:YES attributes:nil error:nil];

        NSString *imagePath = [tmpPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.heic", uniqueID]];
        NSString *videoPath = [tmpPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.mp4", uniqueID]];

        // 下载这一张的图片和视频
        dispatch_group_t downloadGroup = dispatch_group_create();
        __block BOOL imageOK = NO;
        __block BOOL videoOK = NO;

        dispatch_group_enter(downloadGroup);
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 60.0;
        config.timeoutIntervalForResource = 600.0;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
        NSMutableURLRequest *batchImgReq = [NSMutableURLRequest requestWithURL:imageURL];
        [batchImgReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
        [batchImgReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
        NSString *btTtwid1 = [DYYYManager shared].localParseTtwid;
        NSString *batchImgHost = imageURL.host ?: @"";
        if (btTtwid1.length > 0 && [batchImgHost containsString:@"douyinvod"]) {
            [batchImgReq setValue:[NSString stringWithFormat:@"ttwid=%@", btTtwid1] forHTTPHeaderField:@"Cookie"];
        }
        NSURLSessionDataTask *imgTask = [session dataTaskWithRequest:batchImgReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!error && data && [data writeToFile:imagePath atomically:YES]) {
                imageOK = YES;
            }
            [session invalidateAndCancel];
            dispatch_group_leave(downloadGroup);
        }];
        [imgTask resume];

        dispatch_group_enter(downloadGroup);
        NSURLSession *session2 = [NSURLSession sessionWithConfiguration:config];
        NSMutableURLRequest *batchVidReq = [NSMutableURLRequest requestWithURL:videoURL];
        [batchVidReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
        [batchVidReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
        NSString *btTtwid2 = [DYYYManager shared].localParseTtwid;
        NSString *batchVidHost = videoURL.host ?: @"";
        if (btTtwid2.length > 0 && [batchVidHost containsString:@"douyinvod"]) {
            [batchVidReq setValue:[NSString stringWithFormat:@"ttwid=%@", btTtwid2] forHTTPHeaderField:@"Cookie"];
        }
        NSURLSessionDataTask *vidTask = [session2 dataTaskWithRequest:batchVidReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!error && data && [data writeToFile:videoPath atomically:YES]) {
                videoOK = YES;
            }
            [session2 invalidateAndCancel];
            dispatch_group_leave(downloadGroup);
        }];
        [vidTask resume];

        // 下载完成后处理
        dispatch_group_notify(downloadGroup, dispatch_get_main_queue(), ^{
          if (cancelled) {
              [fm removeItemAtPath:tmpPath error:nil];
              return;
          }

          if (!imageOK || !videoOK) {
              // 下载失败，清理并处理下一张
              [fm removeItemAtPath:tmpPath error:nil];
              processNext();
              return;
          }

          // 下载成功，添加元数据并保存到相册
          NSString *identifier = [NSUUID UUID].UUIDString;

          // 处理照片元数据（HEIC→JPEG + contentIdentifier）
          NSString *photoName = [[imagePath lastPathComponent] stringByDeletingPathExtension];
          photoName = [photoName stringByAppendingPathExtension:@"jpeg"];
          NSString *photoFile = [[DYYYManager shared] filePathFromTmp:photoName];
          [[DYYYManager shared] addMetadataToPhoto:[NSURL fileURLWithPath:imagePath] outputFile:photoFile identifier:identifier];

          // 检查照片文件是否生成成功
          if (![fm fileExistsAtPath:photoFile]) {
              [fm removeItemAtPath:tmpPath error:nil];
              processNext();
              return;
          }

          // 处理视频元数据
          NSString *videoName = [videoPath lastPathComponent];
          NSString *videoFile = [[DYYYManager shared] filePathFromTmp:videoName];

          AVAssetReader *localReader = nil;
          AVAssetWriter *localWriter = nil;
          dispatch_queue_t localQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
          dispatch_group_t localGroup = dispatch_group_create();

          NSString *realPhotoFile = photoFile;
          __block BOOL videoCompleteCalled = NO;
          [[DYYYManager shared] addMetadataToVideoWithLocalVars:[NSURL fileURLWithPath:videoPath]
                                                     outputFile:videoFile
                                                     identifier:identifier
                                                         reader:&localReader
                                                         writer:&localWriter
                                                          queue:localQueue
                                                          group:localGroup
                                                       complete:^(BOOL success, NSString *videoOutFile, NSError *error) {
                                                         if (videoCompleteCalled) return; // 防止超时和正常回调重复调用
                                                         videoCompleteCalled = YES;
                                                         if (success && videoOutFile) {
                                                             NSURL *photo = [NSURL fileURLWithPath:realPhotoFile];
                                                             NSURL *video = [NSURL fileURLWithPath:videoOutFile];

                                                             [[PHPhotoLibrary sharedPhotoLibrary]
                                                                 performChanges:^{
                                                                   PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
                                                                   NSString *captionFilename = [DYYYManager sanitizeCaptionForFilename];
                                                                   PHAssetResourceCreationOptions *photoOpts = [PHAssetResourceCreationOptions new];
                                                                   if (captionFilename) photoOpts.originalFilename = [NSString stringWithFormat:@"%@.jpeg", captionFilename];
                                                                   PHAssetResourceCreationOptions *videoOpts = [PHAssetResourceCreationOptions new];
                                                                   if (captionFilename) videoOpts.originalFilename = [NSString stringWithFormat:@"%@.mp4", captionFilename];
                                                                   [request addResourceWithType:PHAssetResourceTypePhoto fileURL:photo options:photoOpts];
                                                                   [request addResourceWithType:PHAssetResourceTypePairedVideo fileURL:video options:videoOpts];
                                                                   @try { [request setValue:@"" forKey:@"localizedTitle"]; } @catch (NSException *e) {}
                                                                 }
                                                                 completionHandler:^(BOOL saved, NSError *_Nullable saveError) {
                                                                   if (saved) {
                                                                       successCount++;
                                                                   }

                                                                   // 清理临时文件
                                                                   [fm removeItemAtPath:imagePath error:nil];
                                                                   [fm removeItemAtPath:videoPath error:nil];
                                                                   [fm removeItemAtPath:realPhotoFile error:nil];
                                                                   if (videoOutFile) [fm removeItemAtPath:videoOutFile error:nil];
                                                                   [fm removeItemAtPath:tmpPath error:nil];

                                                                   // 更新进度
                                                                   float prog = (float)nextIndex / livePhotos.count;
                                                                   [progressView setProgress:prog];

                                                                   // 间隔1.5秒再处理下一张，避免iOS相册写入频率限制
                                                                   dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                                                     processNext();
                                                                   });
                                                                 }];
                                                         } else {
                                                             // 视频元数据处理失败
                                                             [fm removeItemAtPath:imagePath error:nil];
                                                             [fm removeItemAtPath:videoPath error:nil];
                                                             if (realPhotoFile) [fm removeItemAtPath:realPhotoFile error:nil];
                                                             if (videoOutFile) [fm removeItemAtPath:videoOutFile error:nil];
                                                             [fm removeItemAtPath:tmpPath error:nil];
                                                             processNext();
                                                         }
                                                       }];
          // 超时保底：如果30秒内addMetadataToVideoWithLocalVars未回调，跳过当前张继续下一张
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!videoCompleteCalled) {
                videoCompleteCalled = YES;
                NSLog(@"[DYYY] ⚠️ addMetadataToVideoWithLocalVars超时，跳过第%ld张", (long)nextIndex);
                [fm removeItemAtPath:imagePath error:nil];
                [fm removeItemAtPath:videoPath error:nil];
                if (realPhotoFile) [fm removeItemAtPath:realPhotoFile error:nil];
                [fm removeItemAtPath:tmpPath error:nil];
                processNext();
            }
          });
        });
      };

      processNext();
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
                               complete:(void (^)(BOOL success, NSString *videoOutFile, NSError *error))complete {
    NSError *error = nil;
    AVAsset *asset = [AVAsset assetWithURL:videoURL];
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (error || !reader) {
        if (complete)
            complete(NO, nil, error);
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
            complete(NO, nil, error);
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
            if (complete)
                complete(YES, outputFile, nil);
        } else {
            if (complete)
                complete(NO, nil, writer.error);
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

+ (id)shareCountActionWithCount:(NSNumber *)shareCount {
    @try {
        if (!shareCount || ![shareCount isKindOfClass:[NSNumber class]] || [shareCount integerValue] <= 0) return nil;
        NSInteger count = [shareCount integerValue];
        NSString *countStr = nil;
        if (count >= 100000000) {
            double yi = count / 100000000.0;
            if (yi == (NSInteger)yi) {
                countStr = [NSString stringWithFormat:@"%ld亿", (long)yi];
            } else {
                countStr = [NSString stringWithFormat:@"%.1f亿", yi];
            }
        } else if (count >= 10000) {
            double wan = count / 10000.0;
            if (wan == (NSInteger)wan) {
                countStr = [NSString stringWithFormat:@"%ld万", (long)wan];
            } else {
                countStr = [NSString stringWithFormat:@"%.1f万", wan];
            }
        } else {
            countStr = [NSString stringWithFormat:@"%ld", (long)count];
        }
        NSString *title = [NSString stringWithFormat:@"当前作品转发量：%@", countStr];
        return [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:title imgName:nil handler:^{}];
    } @catch (NSException *e) {
        NSLog(@"[DYYY] shareCount action exception: %@", e);
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


+ (void)localParseFromAwemeModel:(id)awemeModel completion:(void(^)(NSDictionary *result))completion {
    if (!awemeModel || !completion) {
        if (completion) completion(nil);
        return;
    }

    // 在后台线程执行所有网络操作，不阻塞主线程
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        NSMutableArray *videoList = [NSMutableArray array];
        NSMutableArray *images = [NSMutableArray array];

        // 提取视频模型
        id videoModel = [awemeModel valueForKey:@"video"];
        id musicModel = [awemeModel valueForKey:@"music"];
        id authorModel = [awemeModel valueForKey:@"author"];


            // --- 视频码率列表 ---
        if (videoModel) {
            // 第一步：收集所有可用的URL，从中提取video_id
            NSString *videoURI = nil;
            NSMutableSet *collectedURLs = [NSMutableSet set];
            NSMutableArray *urlSources = [NSMutableArray array]; // 收集所有URL来源

            // 从h264URL收集
            @try {
                id h264URL = [videoModel valueForKey:@"h264URL"];
                if (h264URL && [h264URL valueForKey:@"originURLList"]) {
                    NSArray *list = [h264URL valueForKey:@"originURLList"];
                    if ([list isKindOfClass:[NSArray class]]) {
                        for (NSString *u in list) {
                            if (u.length > 0 && ![collectedURLs containsObject:u]) {
                                [collectedURLs addObject:u];
                                [urlSources addObject:u];
                            }
                        }
                    }
                }
            } @catch (NSException *e) {}

            // 从playURL收集
            @try {
                id playURL = [videoModel valueForKey:@"playURL"];
                if (playURL && [playURL isKindOfClass:NSClassFromString(@"AWEURLModel")]) {
                    // 先尝试直接取uri属性（对应竞品的play_addr.uri）
                    id uriVal = [playURL valueForKey:@"URI"];
                    if (uriVal && [uriVal isKindOfClass:[NSString class]] && [(NSString *)uriVal length] > 0) {
                        videoURI = (NSString *)uriVal;
                    }
                    NSArray *list = [playURL valueForKey:@"originURLList"];
                    if ([list isKindOfClass:[NSArray class]]) {
                        for (NSString *u in list) {
                            if (u.length > 0 && ![collectedURLs containsObject:u]) {
                                [collectedURLs addObject:u];
                                [urlSources addObject:u];
                            }
                        }
                    }
                }
            } @catch (NSException *e) {}

            // 从playAddr收集（有些视频模型直接有playAddr属性）
            @try {
                id playAddr = [videoModel valueForKey:@"playAddr"];
                if (playAddr) {
                    // 先尝试取uri
                    if (!videoURI || videoURI.length == 0) {
                        id uriVal = [playAddr valueForKey:@"URI"];
                        if (uriVal && [uriVal isKindOfClass:[NSString class]] && [(NSString *)uriVal length] > 0) {
                            videoURI = (NSString *)uriVal;
                        }
                    }
                    NSArray *list = [playAddr valueForKey:@"originURLList"];
                    if (!list || ![list isKindOfClass:[NSArray class]] || list.count == 0) {
                        list = [playAddr valueForKey:@"urlList"];
                    }
                    if ([list isKindOfClass:[NSArray class]]) {
                        for (NSString *u in list) {
                            if (u.length > 0 && ![collectedURLs containsObject:u]) {
                                [collectedURLs addObject:u];
                                [urlSources addObject:u];
                            }
                        }
                    }
                }
            } @catch (NSException *e) {}

            // 从bitrateModels收集（最全的URL来源）
            @try {
                NSArray *bitrateModels = [videoModel valueForKey:@"bitrateModels"];
                if (bitrateModels && [bitrateModels isKindOfClass:[NSArray class]]) {
                    for (id model in bitrateModels) {
                        id modelPlayAddr = [model valueForKey:@"playAddr"];
                        if (modelPlayAddr) {
                            // 从bitrateModel的playAddr取uri
                            if (!videoURI || videoURI.length == 0) {
                                id uriVal = [modelPlayAddr valueForKey:@"URI"];
                                if (uriVal && [uriVal isKindOfClass:[NSString class]] && [(NSString *)uriVal length] > 0) {
                                    videoURI = (NSString *)uriVal;
                                }
                            }
                            NSArray *list = [modelPlayAddr valueForKey:@"originURLList"];
                            if (!list || ![list isKindOfClass:[NSArray class]] || list.count == 0) {
                                list = [modelPlayAddr valueForKey:@"urlList"];
                            }
                            if ([list isKindOfClass:[NSArray class]]) {
                                for (NSString *u in list) {
                                    if (u.length > 0 && ![collectedURLs containsObject:u]) {
                                        [collectedURLs addObject:u];
                                        [urlSources addObject:u];
                                    }
                                }
                            }
                        }
                        // 也尝试从playURL取（有些BSModel有playURL而非playAddr）
                        id modelPlayURL = [model valueForKey:@"playURL"];
                        if (modelPlayURL && modelPlayURL != [videoModel valueForKey:@"playURL"]) {
                            if (!videoURI || videoURI.length == 0) {
                                id uriVal = [modelPlayURL valueForKey:@"URI"];
                                if (uriVal && [uriVal isKindOfClass:[NSString class]] && [(NSString *)uriVal length] > 0) {
                                    videoURI = (NSString *)uriVal;
                                }
                            }
                            NSArray *list = [modelPlayURL valueForKey:@"originURLList"];
                            if ([list isKindOfClass:[NSArray class]]) {
                                for (NSString *u in list) {
                                    if (u.length > 0 && ![collectedURLs containsObject:u]) {
                                        [collectedURLs addObject:u];
                                        [urlSources addObject:u];
                                    }
                                }
                            }
                        }
                    }
                }
            } @catch (NSException *e) {}

            // 如果uri仍为空，从收集到的URL中提取video_id
            if (!videoURI || videoURI.length == 0) {
                for (NSString *urlStr in urlSources) {
                    NSRange vidRange = [urlStr rangeOfString:@"/video_id/" options:NSBackwardsSearch];
                    if (vidRange.location != NSNotFound) {
                        NSString *afterVid = [urlStr substringFromIndex:vidRange.location + vidRange.length];
                        NSRange slashRange = [afterVid rangeOfString:@"/"];
                        if (slashRange.location != NSNotFound && slashRange.location > 0) {
                            videoURI = [afterVid substringToIndex:slashRange.location];
                            break;
                        } else {
                            NSRange paramRange = [afterVid rangeOfString:@"?"];
                            if (paramRange.location != NSNotFound && paramRange.location > 0) {
                                videoURI = [afterVid substringToIndex:paramRange.location];
                                break;
                            }
                        }
                    }
                }
            }

            // 验证videoURI有效性
            if (!videoURI || ![videoURI isKindOfClass:[NSString class]] || videoURI.length == 0) {
                videoURI = nil;
            }

            // 第二步：构建画质列表
            Float64 originalFPS = 0;
            NSInteger originalBitrate = 0;
            NSMutableDictionary *resolutionFPSMap = [NSMutableDictionary dictionary];
            NSString *originalResKey = nil;
            // 2.1 如果有videoURI，用play接口获取真正原画 + 多画质
            // 对每个play URL发HEAD请求获取Content-Length(文件大小)
            if (videoURI) {
                NSArray *ratios = @[
                    @[@"default", @"原画【最高画质】"],
                    @[@"1080p", @"【清晰】1080P"],
                    @[@"720p", @"【标准】720P"],
                    @[@"540p", @"【模糊】540P"]
                ];
                // 先构建所有play URL
                NSMutableArray *playURLs = [NSMutableArray array];
                NSMutableArray *playLabels = [NSMutableArray array];
                for (NSArray *ratioItem in ratios) {
                    NSString *ratio = ratioItem[0];
                    NSString *name = ratioItem[1];
                    NSString *playAPIURL = [NSString stringWithFormat:
                        @"https://www.douyin.com/aweme/v1/play/?video_id=%@&ratio=%@&line=1&device_platform=webapp&aid=6383&channel=channel_pc_web",
                        videoURI, ratio];
                    [playURLs addObject:playAPIURL];
                    [playLabels addObject:name];
                }

                // 并行HEAD请求获取每个画质的文件大小 + CDN直链URL + FPS
                // 所有网络请求放入同一个dispatch_group，一次wait，总超时8秒
                NSMutableArray *fileSizes = [NSMutableArray arrayWithArray:@[@0, @0, @0, @0]];
                NSMutableArray *cdnURLs = [NSMutableArray arrayWithArray:@[[NSNull null], [NSNull null], [NSNull null], [NSNull null]]];
                NSMutableArray *fpsValues = [NSMutableArray arrayWithArray:@[@0, @0, @0, @0]];
                NSMutableArray *headCompleted = [NSMutableArray arrayWithArray:@[@NO, @NO, @NO, @NO]];

                dispatch_group_t netGroup = dispatch_group_create();

                // 阶段1：并行发起所有HEAD请求
                for (NSInteger i = 0; i < playURLs.count; i++) {
                    NSString *urlStr = playURLs[i];
                    dispatch_group_enter(netGroup);
                    NSMutableURLRequest *headReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
                    headReq.HTTPMethod = @"HEAD";
                    [headReq setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
                    [headReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
                    NSURLSessionDataTask *headTask = [[NSURLSession sharedSession] dataTaskWithRequest:headReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                        if (response && [response isKindOfClass:[NSHTTPURLResponse class]]) {
                            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                            long long contentLength = [httpResp expectedContentLength];
                            if (contentLength > 0) {
                                @synchronized(fileSizes) {
                                    fileSizes[i] = @(contentLength);
                                }
                            }
                            // 保存302后的CDN直链URL
                            NSURL *finalURL = httpResp.URL;
                            if (finalURL) {
                                @synchronized(cdnURLs) {
                                    cdnURLs[i] = finalURL;
                                }
                            }
                        }
                        @synchronized(headCompleted) {
                            headCompleted[i] = @YES;
                        }
                        dispatch_group_leave(netGroup);
                    }];
                    [headTask resume];
                }

                // 等待所有网络请求完成（总超时8秒，覆盖HEAD+重试+FPS）
                dispatch_time_t netTimeout = dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC);
                dispatch_group_wait(netGroup, netTimeout);

                // 阶段2：对HEAD失败的请求发起GET+Range重试，同时对有CDN URL的请求获取FPS
                dispatch_group_t phase2Group = dispatch_group_create();

                for (NSInteger i = 0; i < fileSizes.count; i++) {
                    BOOL headDone = NO;
                    @synchronized(headCompleted) {
                        headDone = [headCompleted[i] boolValue];
                    }
                    long long size = [fileSizes[i] longLongValue];

                    // HEAD失败（未完成或文件太小）→ 重试
                    if (!headDone || size < 10240) {
                        dispatch_group_enter(phase2Group);
                        NSMutableURLRequest *retryReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:playURLs[i]]];
                        retryReq.HTTPMethod = @"GET";
                        [retryReq setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];
                        [retryReq setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
                        [retryReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
                        NSURLSessionDataTask *retryTask = [[NSURLSession sharedSession] dataTaskWithRequest:retryReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                            if (response && [response isKindOfClass:[NSHTTPURLResponse class]]) {
                                NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                                NSString *contentRange = [httpResp.allHeaderFields objectForKey:@"Content-Range"];
                                if (contentRange.length > 0) {
                                    NSRange slashRange = [contentRange rangeOfString:@"/"];
                                    if (slashRange.location != NSNotFound) {
                                        NSString *totalStr = [contentRange substringFromIndex:slashRange.location + 1];
                                        long long totalSize = [totalStr longLongValue];
                                        if (totalSize > 10240) {
                                            @synchronized(fileSizes) {
                                                fileSizes[i] = @(totalSize);
                                            }
                                        }
                                    }
                                }
                                if ([fileSizes[i] longLongValue] < 10240) {
                                    long long cl = [httpResp expectedContentLength];
                                    if (cl > 10240) {
                                        @synchronized(fileSizes) {
                                            fileSizes[i] = @(cl);
                                        }
                                    }
                                }
                                NSURL *finalURL = httpResp.URL;
                                if (finalURL) {
                                    @synchronized(cdnURLs) {
                                        cdnURLs[i] = finalURL;
                                    }
                                }
                            }
                            dispatch_group_leave(phase2Group);
                        }];
                        [retryTask resume];
                    }

                    // 有CDN URL → 并行获取FPS
                    NSURL *cdnURL = nil;
                    @synchronized(cdnURLs) {
                        cdnURL = cdnURLs[i];
                    }
                    if ([cdnURL isKindOfClass:[NSURL class]]) {
                        dispatch_group_enter(phase2Group);
                        AVURLAsset *asset = [AVURLAsset assetWithURL:cdnURL];
                        NSString *fpsKey = @"tracks";
                        [asset loadValuesAsynchronouslyForKeys:@[fpsKey] completionHandler:^{
                            NSError *trackError = nil;
                            AVKeyValueStatus status = [asset statusOfValueForKey:fpsKey error:&trackError];
                            if (status == AVKeyValueStatusLoaded) {
                                NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
                                if (tracks.count > 0) {
                                    AVAssetTrack *videoTrack = tracks[0];
                                    Float64 fps = videoTrack.nominalFrameRate;
                                    @synchronized(fpsValues) {
                                        fpsValues[i] = @(fps);
                                    }
                                }
                            }
                            dispatch_group_leave(phase2Group);
                        }];
                    }
                }

                // 等待阶段2完成（重试+FPS，超时5秒）
                dispatch_group_wait(phase2Group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

                // FPS默认值：AVAsset加载失败时默认30FPS
                for (NSInteger i = 0; i < fpsValues.count; i++) {
                    Float64 fps = [fpsValues[i] floatValue];
                    if (fps <= 0) {
                        fpsValues[i] = @(30);
                    }
                }

                // 保存原画FPS，供后bitrateModels比较用
                originalFPS = [fpsValues[0] floatValue];
                @try { originalBitrate = [[videoModel valueForKey:@"bitrate"] integerValue]; } @catch (NSException *e) {}

                // 构建分辨率→FPS映射（供bitrateModels复用）
                NSArray *resolutionKeys = @[@"1440", @"1080", @"720", @"540", @"480"];
                for (NSInteger i = 0; i < playLabels.count; i++) {
                    Float64 f = [fpsValues[i] floatValue];
                    if (f > 0) {
                        NSString *label = playLabels[i];
                        for (NSString *rKey in resolutionKeys) {
                            if ([label containsString:rKey] || (i == 0 && [rKey isEqualToString:@"1440"])) {
                                resolutionFPSMap[rKey] = @(f);
                                break;
                            }
                        }
                    }
                }
                // 原画(default)的FPS也映射到所有分辨率key（作为fallback）
                if (originalFPS > 0) {
                    for (NSString *rKey in resolutionKeys) {
                        if (!resolutionFPSMap[rKey]) {
                            resolutionFPSMap[rKey] = @(originalFPS);
                        }
                    }
                }

                // 获取视频原始分辨率（用于原画lite判断）
                NSInteger videoWidth = 0;
                @try {
                    id playAddrModel = [videoModel valueForKey:@"playAddr"];
                    if (playAddrModel) {
                        NSNumber *w = [playAddrModel valueForKey:@"imageWidth"];
                        if (w && [w isKindOfClass:[NSNumber class]]) videoWidth = [w integerValue];
                    }
                    if (videoWidth <= 0) {
                        id h264URLModel = [videoModel valueForKey:@"h264URL"];
                        if (h264URLModel) {
                            NSNumber *w = [h264URLModel valueForKey:@"imageWidth"];
                            if (w && [w isKindOfClass:[NSNumber class]]) videoWidth = [w integerValue];
                        }
                    }
                } @catch (NSException *e) {}
                // 原画分辨率key
                if (videoWidth >= 2160) originalResKey = @"1440";
                else if (videoWidth >= 1080) originalResKey = @"1080";
                else if (videoWidth >= 720) originalResKey = @"720";
                else if (videoWidth >= 540) originalResKey = @"540";
                else if (videoWidth >= 480) originalResKey = @"480";

                // 构建画质列表
                for (NSInteger i = 0; i < playURLs.count; i++) {
                    NSString *label = [NSString stringWithFormat:@"[%@]", playLabels[i]];
                    // FPS
                    Float64 fps = [fpsValues[i] floatValue];
                    if (fps > 0) {
                        NSInteger fpsInt = (NSInteger)(fps + 0.5);
                        label = [label stringByAppendingFormat:@"-[%ldFPS]", (long)fpsInt];
                    }
                    // 文件大小
                    long long size = [fileSizes[i] longLongValue];
                    if (size >= 10240) {
                        NSString *sizeStr;
                        if (size >= 1024 * 1024 * 1024) {
                            sizeStr = [NSString stringWithFormat:@"%.2fGB", (double)size / (1024.0 * 1024.0 * 1024.0)];
                        } else if (size >= 1024 * 1024) {
                            sizeStr = [NSString stringWithFormat:@"%.1fMB", (double)size / (1024.0 * 1024.0)];
                        } else if (size >= 1024) {
                            sizeStr = [NSString stringWithFormat:@"%.0fKB", (double)size / 1024.0];
                        } else {
                            sizeStr = [NSString stringWithFormat:@"%lldB", size];
                        }
                        label = [label stringByAppendingFormat:@"-[%@]", sizeStr];
                    }
                    [videoList addObject:@{@"level": label, @"url": playURLs[i]}];
                }
            }

            // 2.2 h264URL/playURL作为直链备用（无videoURI时的唯一选项，有videoURI时跳过）
            if (!videoURI) {
                NSString *urlStr = nil;
                id h264URL = [videoModel valueForKey:@"h264URL"];
                if (h264URL && [h264URL valueForKey:@"originURLList"]) {
                    NSArray *list = [h264URL valueForKey:@"originURLList"];
                    if ([list isKindOfClass:[NSArray class]] && list.count > 0) urlStr = list.firstObject;
                }
                if (urlStr.length == 0) {
                    id playURL = [videoModel valueForKey:@"playURL"];
                    if (playURL && [playURL isKindOfClass:NSClassFromString(@"AWEURLModel")]) {
                        NSArray *list = [playURL valueForKey:@"originURLList"];
                        if ([list isKindOfClass:[NSArray class]] && list.count > 0) urlStr = list.firstObject;
                    }
                }
                if (urlStr.length > 0) {
                    [videoList addObject:@{@"level": @"[原画【最高画质】(直链)]", @"url": urlStr}];
                }
            }


            // 2.25 web API获取4K画质（ttwid + bit_rate）
            {
                NSString *awemeId = nil;
                @try { awemeId = [awemeModel valueForKey:@"awemeID"]; } @catch (NSException *e) {}
                if (!awemeId) {
                    @try { awemeId = [awemeModel valueForKey:@"awemeId"]; } @catch (NSException *e2) {}
                }
                if (awemeId.length > 0 && videoURI.length > 0) {
                    __block NSString *ttwidStr = nil;
                    __block NSDictionary *webBitrate4K = nil;
                    __block NSDictionary *webBitrate1440 = nil;
                    __block NSMutableString *web4kProbe = [NSMutableString stringWithFormat:@"[本地解析][4K补充探针] awemeId=%@\n", awemeId];
                    dispatch_group_t webApiGroup = dispatch_group_create();
                    dispatch_group_enter(webApiGroup);
                    // Step 1: 获取ttwid
                    NSString *ttwidURL = @"https://ttwid.bytedance.com/ttwid/union/register/";
                    NSString *ttwidBody = @"{\"region\":\"cn\",\"aid\":6383,\"needFid\":false,\"service\":\"www.douyin.com\",\"migrate_info\":{\"ticket\":\"\",\"source\":\"node\"},\"cbUrlProtocol\":\"https\",\"union\":true}";
                    NSMutableURLRequest *ttwidReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:ttwidURL]];
                    ttwidReq.HTTPMethod = @"POST";
                    ttwidReq.HTTPBody = [ttwidBody dataUsingEncoding:NSUTF8StringEncoding];
                    [ttwidReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
                    [ttwidReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" forHTTPHeaderField:@"User-Agent"];
                    NSURLSessionDataTask *ttwidTask = [[NSURLSession sharedSession] dataTaskWithRequest:ttwidReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                        @try {
                            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                            NSDictionary *headers = [httpResp allHeaderFields];
                            NSString *setCookie = headers[@"Set-Cookie"];
                            if (setCookie.length > 0) {
                                NSRange r = [setCookie rangeOfString:@"ttwid="];
                                if (r.location != NSNotFound) {
                                    NSString *sub = [setCookie substringFromIndex:r.location + 6];
                                    NSRange semi = [sub rangeOfString:@";"];
                                    ttwidStr = semi.location != NSNotFound ? [sub substringToIndex:semi.location] : sub;
                                }
                            }
                            // 降级：注册失败时从app Cookie存储取ttwid
                            if (!ttwidStr || ttwidStr.length == 0) {
                                NSHTTPCookieStorage *cs1 = [NSHTTPCookieStorage sharedHTTPCookieStorage];
                                NSArray *ck1 = [cs1 cookiesForURL:[NSURL URLWithString:@"https://www.douyin.com/"]];
                                for (NSHTTPCookie *c1 in ck1) {
                                    if ([[c1 name] isEqualToString:@"ttwid"]) { ttwidStr = [c1 value]; break; }
                                }
                            }
                            [web4kProbe appendFormat:@"ttwid注册: HTTP %ld 结果=%@\n", (long)([response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0), ttwidStr.length > 0 ? @"成功" : @"失败"];
                            // Step 2: 用ttwid调web API
                            if (ttwidStr.length > 0) {
                                // 存储ttwid供后续CDN下载使用
                                [DYYYManager shared].localParseTtwid = ttwidStr;
                                NSString *apiURL = [NSString stringWithFormat:@"https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=%@&device_platform=webapp&aid=6383&channel=channel_pc_web", awemeId];
                                NSMutableURLRequest *apiReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:apiURL]];
                                [apiReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
                                [apiReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
                                [apiReq setValue:@"application/json" forHTTPHeaderField:@"Accept"];
                                [apiReq setValue:[NSString stringWithFormat:@"ttwid=%@", ttwidStr] forHTTPHeaderField:@"Cookie"];
                                NSURLSessionDataTask *apiTask = [[NSURLSession sharedSession] dataTaskWithRequest:apiReq completionHandler:^(NSData *apiData, NSURLResponse *apiResp, NSError *apiErr) {
                                    NSHTTPURLResponse *wHttp = [apiResp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)apiResp : nil;
                                    [web4kProbe appendFormat:@"WebAPI请求: HTTP %ld body=%lu err=%@\n", (long)wHttp.statusCode, (unsigned long)apiData.length, apiErr.localizedDescription ?: @"无"];
                                    if (apiData.length > 0 && apiData.length < 2000) {
                                        NSString *wraw = [[NSString alloc] initWithData:apiData encoding:NSUTF8StringEncoding];
                                        if (wraw.length > 300) wraw = [wraw substringToIndex:300];
                                        [web4kProbe appendFormat:@"WebAPI原文(前300): %@\n", wraw ?: @"(非UTF8)"];
                                    }
                                    @try {
                                        if (apiData.length > 0) {
                                            NSDictionary *apiJson = [NSJSONSerialization JSONObjectWithData:apiData options:0 error:nil];
                                            NSDictionary *awemeDetail = apiJson[@"aweme_detail"];
                                            NSDictionary *videoDetail = awemeDetail[@"video"];
                                            NSArray *bitRateList = videoDetail[@"bit_rate"];
                                            if (bitRateList && [bitRateList isKindOfClass:[NSArray class]]) {
                                                for (NSDictionary *br in bitRateList) {
                                                    NSString *gear = br[@"gear_name"];
                                                    if (!gear) continue;
                                                    // 4K条目（gear含_4_且bitrate最高）
                                                    if ([gear containsString:@"_4_"] && !webBitrate4K) {
                                                        if (!webBitrate4K || [[br valueForKey:@"bit_rate"] integerValue] > [[webBitrate4K valueForKey:@"bit_rate"] integerValue]) {
                                                            webBitrate4K = br;
                                                        }
                                                    }
                                                    // 1440P条目
                                                    if ([gear containsString:@"1440"] && !webBitrate1440) {
                                                        webBitrate1440 = br;
                                                    }
                                                }
                                            }
                                            [web4kProbe appendFormat:@"WebAPI结果: bit_rate=%lu条 4K档=%@ 2K档=%@\n", (unsigned long)([bitRateList isKindOfClass:[NSArray class]] ? [bitRateList count] : 0), webBitrate4K ? @"有" : @"无", webBitrate1440 ? @"有" : @"无"];
                                        }
                                    } @catch (NSException *e2) {}
                                    dispatch_group_leave(webApiGroup);
                                }];
                                [apiTask resume];
                            } else {
                                dispatch_group_leave(webApiGroup);
                            }
                        } @catch (NSException *e) {
                            dispatch_group_leave(webApiGroup);
                        }
                    }];
                    [ttwidTask resume];
                    dispatch_group_wait(webApiGroup, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
                    
                    // Step 3: 从4K条目提取CDN直链，构建画质条目
                    NSMutableArray *web4KItems = [NSMutableArray array];
                    // 4K
                    if (webBitrate4K) {
                        NSDictionary *pa = webBitrate4K[@"play_addr"];
                        NSArray *urlList = pa[@"url_list"];
                        NSString *url4k = nil;
                        if (urlList && urlList.count > 0) url4k = urlList[0];
                        if (url4k.length > 0) {
                            NSInteger bitrate = [[webBitrate4K valueForKey:@"bit_rate"] integerValue];
                            NSInteger fps = [[webBitrate4K valueForKey:@"FPS"] integerValue];
                            if (fps <= 0) fps = 30;
                            NSString *label4k = [NSString stringWithFormat:@"[【极致】4K]-[%ldFPS]", (long)fps];
                            [web4KItems addObject:@{@"level": label4k, @"url": url4k, @"bitrate": @(bitrate), @"sortKey": @(bitrate)}];
                        }
                    }
                    // 1440P
                    if (webBitrate1440) {
                        NSDictionary *pa = webBitrate1440[@"play_addr"];
                        NSArray *urlList = pa[@"url_list"];
                        NSString *url1440 = nil;
                        if (urlList && urlList.count > 0) url1440 = urlList[0];
                        if (url1440.length > 0) {
                            NSInteger bitrate = [[webBitrate1440 valueForKey:@"bit_rate"] integerValue];
                            NSInteger fps = [[webBitrate1440 valueForKey:@"FPS"] integerValue];
                            if (fps <= 0) fps = 30;
                            NSString *label1440 = [NSString stringWithFormat:@"[【高清】2K]-[%ldFPS]", (long)fps];
                            [web4KItems addObject:@{@"level": label1440, @"url": url1440, @"bitrate": @(bitrate), @"sortKey": @(bitrate)}];
                        }
                    }
                    // 对4K条目做HEAD获取文件大小
                    if (web4KItems.count > 0) {
                        NSMutableArray *web4KSizes = [NSMutableArray array];
                        for (NSInteger k = 0; k < web4KItems.count; k++) [web4KSizes addObject:@0];
                        dispatch_group_t headGroup = dispatch_group_create();
                        for (NSInteger wi = 0; wi < web4KItems.count; wi++) {
                            NSString *wUrl = web4KItems[wi][@"url"];
                            dispatch_group_enter(headGroup);
                            NSMutableURLRequest *hReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:wUrl]];
                            hReq.HTTPMethod = @"HEAD";
                            [hReq setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];
                            [hReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
                            NSURLSessionDataTask *hTask = [[NSURLSession sharedSession] dataTaskWithRequest:hReq completionHandler:^(NSData *hData, NSURLResponse *hResp, NSError *hErr) {
                                if (hResp && [hResp isKindOfClass:[NSHTTPURLResponse class]]) {
                                    long long cl = [(NSHTTPURLResponse *)hResp expectedContentLength];
                                    if (cl > 10240) web4KSizes[wi] = @(cl);
                                }
                                dispatch_group_leave(headGroup);
                            }];
                            [hTask resume];
                        }
                        dispatch_group_wait(headGroup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
                        // 构建最终画质条目（排在最前面）
                        for (NSInteger wi = 0; wi < web4KItems.count; wi++) {
                            NSString *finalLabel = web4KItems[wi][@"level"];
                            long long sz = [web4KSizes[wi] longLongValue];
                            if (sz >= 10240) {
                                NSString *szStr;
                                if (sz >= 1024 * 1024 * 1024) szStr = [NSString stringWithFormat:@"%.2fGB", (double)sz / (1024.0 * 1024.0 * 1024.0)];
                                else if (sz >= 1024 * 1024) szStr = [NSString stringWithFormat:@"%.1fMB", (double)sz / (1024.0 * 1024.0)];
                                else szStr = [NSString stringWithFormat:@"%.0fKB", (double)sz / 1024.0];
                                finalLabel = [finalLabel stringByAppendingFormat:@"-[%@]", szStr];
                            }
                            NSString *finalUrl = web4KItems[wi][@"url"];
                            [videoList insertObject:@{@"level": finalLabel, @"url": finalUrl} atIndex:0];
                        }
                    }
                    [web4kProbe appendFormat:@"最终: 4K条目=%@ 2K条目=%@ 待插入=%lu\n", webBitrate4K ? @"有" : @"无", webBitrate1440 ? @"有" : @"无", (unsigned long)web4KItems.count];
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"DYYYProbeNotification" object:nil userInfo:@{@"text": [web4kProbe copy]}];
                }
            }

            // 2.3 bitrateModels补充（去重，带gearName和码率信息）
            // 所有bitrateModel的HEAD请求也并行执行
            {
                NSArray *bitrateModels = nil;
                @try { bitrateModels = [videoModel valueForKey:@"bitrateModels"]; } @catch (NSException *e) {}
                if (bitrateModels && [bitrateModels isKindOfClass:[NSArray class]] && bitrateModels.count > 0) {
                    NSMutableArray *sortedModels = [NSMutableArray arrayWithArray:bitrateModels];
                    [sortedModels sortUsingComparator:^NSComparisonResult(id a, id b) {
                        NSInteger ba = 0, bb = 0;
                        @try { ba = [[a valueForKey:@"bitrate"] integerValue]; } @catch (NSException *e) {}
                        @try { bb = [[b valueForKey:@"bitrate"] integerValue]; } @catch (NSException *e) {}
                        return bb - ba;
                    }];
                    NSMutableSet *existingURLs = [NSMutableSet set];
                    for (NSDictionary *item in videoList) {
                        NSString *u = item[@"url"];
                        if (u) [existingURLs addObject:u];
                    }

                    // 收集需要HEAD的bitrateModel项
                    NSMutableArray *bmItems = [NSMutableArray array]; // 存储: @{@"index": @(idx), @"url": urlStr, @"model": model}
                    for (id model in sortedModels) {
                        @try {
                            id modelPlayAddr = [model valueForKey:@"playAddr"];
                            NSString *urlStr = nil;
                            if (modelPlayAddr && [modelPlayAddr isKindOfClass:NSClassFromString(@"AWEURLModel")]) {
                                id originList = [modelPlayAddr valueForKey:@"originURLList"];
                                if ([originList isKindOfClass:[NSArray class]] && [(NSArray *)originList count] > 0) {
                                    urlStr = [(NSArray *)originList firstObject];
                                }
                            }
                            if (urlStr.length == 0 || [existingURLs containsObject:urlStr]) continue;

                            // 取码率
                            NSInteger bitrate = 0;
                            @try { bitrate = [[model valueForKey:@"bitrate"] integerValue]; } @catch (NSException *e) {}
                            if (bitrate <= 0) continue;

                            [bmItems addObject:@{@"url": urlStr, @"model": model, @"bitrate": @(bitrate)}];
                        } @catch (NSException *e) {}
                    }

                    // 并行HEAD请求所有bitrateModel
                    NSMutableArray *bmSizes = [NSMutableArray array];
                    for (NSInteger k = 0; k < bmItems.count; k++) [bmSizes addObject:@0];
                    NSMutableArray *bmCdnURLs = [NSMutableArray array];
                    for (NSInteger k = 0; k < bmItems.count; k++) [bmCdnURLs addObject:[NSNull null]];

                    dispatch_group_t bmGroup = dispatch_group_create();
                    for (NSInteger bi = 0; bi < bmItems.count; bi++) {
                        NSString *urlStr = bmItems[bi][@"url"];
                        dispatch_group_enter(bmGroup);
                        NSMutableURLRequest *headReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
                        headReq.HTTPMethod = @"HEAD";
                        [headReq setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
                        [headReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
                        NSURLSessionDataTask *headTask = [[NSURLSession sharedSession] dataTaskWithRequest:headReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                            if (response && [response isKindOfClass:[NSHTTPURLResponse class]]) {
                                NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                                long long contentLength = [httpResp expectedContentLength];
                                if (contentLength > 10240) {
                                    @synchronized(bmSizes) {
                                        bmSizes[bi] = @(contentLength);
                                    }
                                }
                                NSURL *finalURL = httpResp.URL;
                                if (finalURL) {
                                    @synchronized(bmCdnURLs) {
                                        bmCdnURLs[bi] = finalURL;
                                    }
                                }
                            }
                            dispatch_group_leave(bmGroup);
                        }];
                        [headTask resume];
                    }
                    dispatch_group_wait(bmGroup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

                    // 对HEAD失败的bitrateModel重试（GET+Range），也并行
                    dispatch_group_t bmRetryGroup = dispatch_group_create();
                    for (NSInteger bi = 0; bi < bmItems.count; bi++) {
                        long long size = [bmSizes[bi] longLongValue];
                        if (size < 10240) {
                            NSString *urlStr = bmItems[bi][@"url"];
                            dispatch_group_enter(bmRetryGroup);
                            NSMutableURLRequest *retryReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
                            retryReq.HTTPMethod = @"GET";
                            [retryReq setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];
                            [retryReq setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
                            [retryReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
                            NSURLSessionDataTask *retryTask = [[NSURLSession sharedSession] dataTaskWithRequest:retryReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                if (response && [response isKindOfClass:[NSHTTPURLResponse class]]) {
                                    NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                                    NSString *contentRange = [httpResp.allHeaderFields objectForKey:@"Content-Range"];
                                    long long retrySize = 0;
                                    if (contentRange.length > 0) {
                                        NSRange slashRange = [contentRange rangeOfString:@"/"];
                                        if (slashRange.location != NSNotFound) {
                                            NSString *totalStr = [contentRange substringFromIndex:slashRange.location + 1];
                                            retrySize = [totalStr longLongValue];
                                        }
                                    }
                                    if (retrySize < 10240) {
                                        retrySize = [httpResp expectedContentLength];
                                    }
                                    if (retrySize > 10240) {
                                        @synchronized(bmSizes) {
                                            bmSizes[bi] = @(retrySize);
                                        }
                                    }
                                    NSURL *finalURL = httpResp.URL;
                                    if (finalURL) {
                                        @synchronized(bmCdnURLs) {
                                            bmCdnURLs[bi] = finalURL;
                                        }
                                    }
                                }
                                dispatch_group_leave(bmRetryGroup);
                            }];
                            [retryTask resume];
                        }
                    }
                    dispatch_group_wait(bmRetryGroup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

                    // 构建bitrateModel画质列表
                    for (NSInteger bi = 0; bi < bmItems.count; bi++) {
                        @try {
                            id model = bmItems[bi][@"model"];
                            NSString *urlStr = bmItems[bi][@"url"];
                            NSInteger bitrate = [bmItems[bi][@"bitrate"] integerValue];
                            long long headSize = [bmSizes[bi] longLongValue];

                            // 取gearName
                            NSString *gearName = nil;
                            @try { gearName = [model valueForKey:@"gearName"]; } @catch (NSException *e) {}

                            // gearName友好名称：从gearName自动解析分辨率
                            NSDictionary *gearNameMap = @{@"adapt_lowest_1440_1": @"【高清】2K", @"adapt_lowest_4_1": @"【极致】4K"};
                            NSString *displayName = gearNameMap[gearName];
                            if (!displayName && gearName.length > 0) {
                                NSRange r = [gearName rangeOfString:@"1440"];
                                if (r.location != NSNotFound) { displayName = @"【高清】2K"; }
                                else {
                                    r = [gearName rangeOfString:@"1080"];
                                    if (r.location != NSNotFound) { displayName = @"【清晰】1080P"; }
                                    else {
                                        r = [gearName rangeOfString:@"720"];
                                        if (r.location != NSNotFound) { displayName = @"【标准】720P"; }
                                        else {
                                            r = [gearName rangeOfString:@"540"];
                                            if (r.location != NSNotFound) { displayName = @"【模糊】540P"; }
                                            else {
                                                r = [gearName rangeOfString:@"480"];
                                                if (r.location != NSNotFound) { displayName = @"【模糊】480P"; }
                                                else { displayName = gearName; }
                                            }
                                        }
                                    }
                                }
                            }

                            // 从分辨率→FPS映射获取FPS（复用play URL的FPS，不再单独AVAsset加载）
                            Float64 fps = 0;
                            if (gearName.length > 0) {
                                for (NSString *rKey in @[@"1440", @"1080", @"720", @"540", @"480"]) {
                                    if ([gearName containsString:rKey]) {
                                        NSNumber *mappedFPS = resolutionFPSMap[rKey];
                                        if (mappedFPS) fps = [mappedFPS floatValue];
                                        break;
                                    }
                                }
                            }
                            // FPS默认30（抖音绝大多数视频30FPS）
                            if (fps <= 0) fps = 30;

                            // 构建label：原画lite判断（分辨率匹配原画 + 码率/FPS辅助）
                            BOOL sameAsOriginal = NO;
                            // 方法1：分辨率与原画分辨率一致
                            if (originalResKey.length > 0 && gearName.length > 0 && [gearName containsString:originalResKey]) {
                                sameAsOriginal = YES;
                            }
                            // 方法2：码率相同
                            if (!sameAsOriginal && originalBitrate > 0 && bitrate > 0 && bitrate == originalBitrate) {
                                sameAsOriginal = YES;
                            }
                            // 方法3：FPS与原画相同且都>0
                            if (!sameAsOriginal) {
                                NSInteger fpsInt = (NSInteger)(fps + 0.5);
                                NSInteger origFpsInt = (NSInteger)(originalFPS + 0.5);
                                if (origFpsInt > 0 && fpsInt > 0 && fpsInt == origFpsInt) {
                                    sameAsOriginal = YES;
                                }
                            }
                            NSString *qualityLabel;
                            if (sameAsOriginal) {
                                if (bitrate > 0) {
                                    qualityLabel = [NSString stringWithFormat:@"[%ldkbps]", (long)(bitrate/1000)];
                                } else if (displayName.length > 0) {
                                    qualityLabel = [NSString stringWithFormat:@"[%@]", displayName];
                                } else {
                                    qualityLabel = @"[原画lite]";
                                }
                            } else if (displayName.length > 0) {
                                qualityLabel = [NSString stringWithFormat:@"[%@]", displayName];
                            } else {
                                qualityLabel = [NSString stringWithFormat:@"[%ldkbps]", (long)(bitrate/1000)];
                            }
                            if (fps > 0) {
                                NSInteger fpsInt = (NSInteger)(fps + 0.5);
                                qualityLabel = [qualityLabel stringByAppendingFormat:@"-[%ldFPS]", (long)fpsInt];
                            }
                            NSString *sizeStr = @"";
                            if (headSize >= 10240) {
                                if (headSize >= 1024 * 1024 * 1024) {
                                    sizeStr = [NSString stringWithFormat:@"%.2fGB", (double)headSize / (1024.0 * 1024.0 * 1024.0)];
                                } else if (headSize >= 1024 * 1024) {
                                    sizeStr = [NSString stringWithFormat:@"%.1fMB", (double)headSize / (1024.0 * 1024.0)];
                                } else if (headSize >= 1024) {
                                    sizeStr = [NSString stringWithFormat:@"%.0fKB", (double)headSize / 1024.0];
                                } else {
                                    sizeStr = [NSString stringWithFormat:@"%lldB", headSize];
                                }
                                qualityLabel = [qualityLabel stringByAppendingFormat:@"-[%@]", sizeStr];
                            }

                            // 非lite标准分辨率用play接口URL（不过期），lite和非标准分辨率用CDN直链
                            NSString *downloadURL = urlStr;
                            if (!sameAsOriginal && videoURI.length > 0) {
                                NSString *ratioForPlay = nil;
                                if ([gearName containsString:@"1080"]) ratioForPlay = @"1080p";
                                else if ([gearName containsString:@"720"]) ratioForPlay = @"720p";
                                else if ([gearName containsString:@"540"]) ratioForPlay = @"540p";
                                else if ([gearName containsString:@"480"]) ratioForPlay = @"480p";
                                if (ratioForPlay) {
                                    downloadURL = [NSString stringWithFormat:@"https://www.douyin.com/aweme/v1/play/?video_id=%@&ratio=%@&line=1&device_platform=webapp&aid=6383&channel=channel_pc_web", videoURI, ratioForPlay];
                                }
                            }
                            [existingURLs addObject:urlStr];
                            if (![downloadURL isEqualToString:urlStr]) {
                                [existingURLs addObject:downloadURL];
                            }
                            if (sameAsOriginal && videoList.count > 0) {
                                [videoList insertObject:@{@"level": qualityLabel, @"url": downloadURL} atIndex:1];
                            } else {
                                [videoList addObject:@{@"level": qualityLabel, @"url": downloadURL}];
                            }
                        } @catch (NSException *e) {}
                    }
                }
            }
            id coverURL = [videoModel valueForKey:@"coverURL"];
            if (coverURL && [coverURL valueForKey:@"originURLList"]) {
                NSArray *list = [coverURL valueForKey:@"originURLList"];
                if ([list isKindOfClass:[NSArray class]] && list.count > 0) {
                    result[@"cover"] = list.firstObject;
                }
            }
        }

        // --- 图集图片 ---
        NSArray *albumImages = [awemeModel valueForKey:@"albumImages"];
        if (albumImages && [albumImages isKindOfClass:[NSArray class]]) {
            for (id imgModel in albumImages) {
                @try {
                    // 检查是否有实况视频（clipVideo）
                    id clipVideo = [imgModel valueForKey:@"clipVideo"];
                    if (clipVideo) {
                        id playURL = [clipVideo valueForKey:@"playURL"];
                        NSString *videoURLStr = nil;
                        if (playURL && [playURL isKindOfClass:NSClassFromString(@"AWEURLModel")]) {
                            NSArray *list = [playURL valueForKey:@"originURLList"];
                            if ([list isKindOfClass:[NSArray class]] && list.count > 0) videoURLStr = list.firstObject;
                        }

                        // 优先获取原图URL
                        NSString *imageURLStr = nil;
                        {
                            id originUrlModel = [imgModel valueForKey:@"originUrl"];
                            if (originUrlModel && [originUrlModel respondsToSelector:@selector(originURLList)]) {
                                NSArray *originList = [originUrlModel originURLList];
                                if ([originList isKindOfClass:[NSArray class]] && originList.count > 0) {
                                    imageURLStr = originList.firstObject;
                                }
                            }
                        }
                        if (!imageURLStr) {
                            NSArray *urlList = [imgModel valueForKey:@"urlList"];
                            if ([urlList isKindOfClass:[NSArray class]] && urlList.count > 0) {
                                for (NSString *u in urlList) {
                                    if (![u hasSuffix:@".image"]) { imageURLStr = u; break; }
                                }
                                if (!imageURLStr) imageURLStr = urlList.firstObject;
                            }
                        }

                        if (videoURLStr.length > 0 && imageURLStr.length > 0) {
                            [videoList addObject:@{@"level": @"实况", @"url": videoURLStr}];
                            [images addObject:imageURLStr];
                        }
                    } else {
                        // 普通图片 - 优先获取原图URL
                        NSString *imgURL = nil;
                        {
                            id originUrlModel = [imgModel valueForKey:@"originUrl"];
                            if (originUrlModel && [originUrlModel respondsToSelector:@selector(originURLList)]) {
                                NSArray *originList = [originUrlModel originURLList];
                                if ([originList isKindOfClass:[NSArray class]] && originList.count > 0) {
                                    imgURL = originList.firstObject;
                                }
                            }
                        }
                        if (!imgURL) {
                            NSArray *urlList = [imgModel valueForKey:@"urlList"];
                            if ([urlList isKindOfClass:[NSArray class]] && urlList.count > 0) {
                                for (NSString *u in urlList) {
                                    if (![u hasSuffix:@".image"]) { imgURL = u; break; }
                                }
                                if (!imgURL) imgURL = urlList.firstObject;
                            }
                        }
                        if (imgURL.length > 0) [images addObject:imgURL];
                    }
                } @catch (NSException *e) {
                    NSLog(@"[DYYY] localParse albumImage error: %@", e);
                }
            }
        }

        // --- 音乐 ---
        if (musicModel) {
            id playURL = [musicModel valueForKey:@"playURL"];
            if (playURL && [playURL valueForKey:@"originURLList"]) {
                NSArray *list = [playURL valueForKey:@"originURLList"];
                if ([list isKindOfClass:[NSArray class]] && list.count > 0) {
                    result[@"music"] = list.firstObject;
                }
            }
        }

        // --- 作者信息 ---
        if (authorModel) {
            NSString *nickname = [authorModel valueForKey:@"nickname"];
            if (nickname.length > 0) result[@"author"] = nickname;
        }

        // --- 标题 ---
        NSString *desc = [awemeModel valueForKey:@"desc"];
        if (!desc || ![desc isKindOfClass:[NSString class]]) {
            desc = [awemeModel valueForKey:@"descriptionString"];
        }
        if (desc.length > 0) result[@"title"] = desc;

        // --- 转发量 ---
        @try {
            id statsModel = [awemeModel valueForKey:@"statistics"];
            if (statsModel) {
                NSNumber *shareCount = [statsModel valueForKey:@"shareCount"];
                if (shareCount && [shareCount isKindOfClass:[NSNumber class]] && [shareCount integerValue] > 0) {
                    result[@"share_count"] = shareCount;
                    NSLog(@"[DYYY] localParse share_count from statistics: %@", shareCount);
                }
            }
            // 保存awemeId
            NSString *awemeId = [awemeModel valueForKey:@"awemeId"];
            if (awemeId && awemeId.length > 0) {
                result[@"aweme_id"] = awemeId;
            }
        } @catch (NSException *e) {
            NSLog(@"[DYYY] localParse shareCount error: %@", e);
        }

        if (videoList.count > 0) result[@"video_list"] = videoList;
        if (images.count > 0) result[@"images"] = images;

        NSDictionary *finalResult = result.count > 0 ? result : nil;
        completion(finalResult);
    });
}

// 从app Cookie存储获取抖音完整Cookie字符串（ttwid+msToken+sessionid等）
+ (NSString *)getDouyinFullCookieString {
    NSHTTPCookieStorage *store = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray *cookies = [store cookiesForURL:[NSURL URLWithString:@"https://www.douyin.com/"]];
    // 需要的关键cookie名
    NSArray *neededKeys = @[@"ttwid", @"msToken", @"sessionid", @"sessionid_ss", @"sid_tt", @"sid_guard", @"passport_csrf_token", @"s_v_web_id", @"odin_tt", @"is_id"];
    NSMutableDictionary *cookieDict = [NSMutableDictionary dictionary];
    for (NSHTTPCookie *c in cookies) {
        NSString *name = [c name];
        for (NSString *key in neededKeys) {
            if ([name isEqualToString:key]) {
                cookieDict[key] = [c value];
                break;
            }
        }
    }
    // 如果没有ttwid，尝试注册
    if (!cookieDict[@"ttwid"] || [cookieDict[@"ttwid"] length] == 0) {
        __block NSString *regTtwid = nil;
        NSString *ttwidURL = @"https://ttwid.bytedance.com/ttwid/union/register/";
        NSString *ttwidBody = @"{\"region\":\"cn\",\"aid\":6383,\"needFid\":false,\"service\":\"www.douyin.com\",\"migrate_info\":{\"ticket\":\"\",\"source\":\"node\"},\"cbUrlProtocol\":\"https\",\"union\":true}";
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:ttwidURL]];
        req.HTTPMethod = @"POST";
        req.HTTPBody = [ttwidBody dataUsingEncoding:NSUTF8StringEncoding];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            @try {
                NSHTTPURLResponse *hr = (NSHTTPURLResponse *)response;
                NSString *sc = [hr allHeaderFields][@"Set-Cookie"];
                if (sc.length > 0) {
                    NSRange r = [sc rangeOfString:@"ttwid="];
                    if (r.location != NSNotFound) {
                        NSString *sub = [sc substringFromIndex:r.location + 6];
                        NSRange semi = [sub rangeOfString:@";"];
                        regTtwid = semi.location != NSNotFound ? [sub substringToIndex:semi.location] : sub;
                    }
                }
                if (!regTtwid || regTtwid.length == 0) {
                    if (data.length > 0) {
                        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                        if ([j isKindOfClass:[NSDictionary class]]) {
                            NSString *bt = j[@"ttwid"];
                            if (bt.length > 0) regTtwid = bt;
                        }
                    }
                }
            } @catch (NSException *e) {}
            dispatch_semaphore_signal(sem);
        }];
        [task resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        if (regTtwid.length > 0) cookieDict[@"ttwid"] = regTtwid;
    }
    // 存ttwid到localParseTtwid
    NSString *fullTtwid = cookieDict[@"ttwid"];
    if (fullTtwid.length > 0) {
        [DYYYManager shared].localParseTtwid = fullTtwid;
    }
    // 拼接cookie字符串
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in neededKeys) {
        NSString *val = cookieDict[key];
        if (val && val.length > 0) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, val]];
        }
    }
    return [parts componentsJoinedByString:@"; "];
}

// ===== 2.2-20 WKWebView真浏览器救援：桌面UA加载视频页，acrawler自动完成验证，抓取内嵌数据的完整HTML，并回填养熟的cookie =====
static NSString *DYYYFetchAwemeDetailViaWebView(NSString *awemeId, NSMutableString *probeLog) {
    __block NSString *jsonResult = nil;
    __block BOOL signaled = NO;
    dispatch_semaphore_t rescueSem = dispatch_semaphore_create(0);
    NSString *pageURL = [NSString stringWithFormat:@"https://www.douyin.com/video/%@", awemeId];
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [probeLog appendFormat:@"[Step2.6 WKWebView API拦截] 开始加载 %@\n", pageURL];
            WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
            // 真机指纹对齐: 模拟iPadOS桌面模式Safari(UA=Macintosh+platform=MacIntel+iPad真实分辨率1024x1366, iPad本就是MacUA+触摸的真实组合)
            NSString *fpJS = @"(function(){try{Object.defineProperty(navigator,'platform',{get:function(){return 'MacIntel';}});}catch(e){}"
                              @"try{Object.defineProperty(screen,'width',{get:function(){return 1024;}});}catch(e){}"
                              @"try{Object.defineProperty(screen,'height',{get:function(){return 1366;}});}catch(e){}"
                              @"try{Object.defineProperty(screen,'availWidth',{get:function(){return 1024;}});}catch(e){}"
                              @"try{Object.defineProperty(screen,'availHeight',{get:function(){return 1366;}});}catch(e){}"
                              @"try{Object.defineProperty(navigator,'webdriver',{get:function(){return false;}});}catch(e){}})();";
            WKUserScript *fpScript = [[WKUserScript alloc] initWithSource:fpJS injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
            [cfg.userContentController addUserScript:fpScript];
            // 2.2-24 API拦截: hook fetch/XHR, 页面自身调detail接口时截获响应体存入__dyDetailJSON; 同时记录所有请求URL到__dyReqLog(哨兵)
            NSString *hookJS = [NSString stringWithFormat:@"(function(){"
                                 @"try{if(window.__dyHookInstalled)return;}catch(e){}"
                                 @"window.__dyHookInstalled=true;window.__dyDetailJSON='';window.__dyReqLog=[];"
                                 @"var __dyTarget='%@';"
                                 @"function isDetail(u){return u&&(u.indexOf('aweme/detail')>-1||u.indexOf('aweme_detail')>-1);}"
                                 @"function save(t){try{if(!t||t.length<100)return;if(t.indexOf('aweme_detail')<0)return;if(__dyTarget&&t.indexOf(__dyTarget)<0)return;if(!window.__dyDetailJSON)window.__dyDetailJSON=t;}catch(e){}}"
                                 @"function logReq(u){try{if(u&&window.__dyReqLog.length<50)window.__dyReqLog.push(''+u);}catch(e){}}"
                                 @"var of=window.fetch;"
                                 @"if(of){window.fetch=function(){"
                                 @"var u=(arguments[0]&&arguments[0].url)?(''+arguments[0].url):(''+(arguments[0]||''));"
                                 @"try{logReq(u);}catch(e){}"
                                 @"var p=of.apply(this,arguments);"
                                 @"if(isDetail(u)){try{p.then(function(r){try{r.clone().text().then(function(t){save(t);});}catch(e){}}).catch(function(){});}catch(e){}}"
                                 @"return p;};}"
                                 @"var oo=XMLHttpRequest.prototype.open;"
                                 @"XMLHttpRequest.prototype.open=function(m,u){try{this.__dyUrl=''+u;}catch(e){}return oo.apply(this,arguments);};"
                                 @"var os=XMLHttpRequest.prototype.send;"
                                 @"XMLHttpRequest.prototype.send=function(){var x=this;try{logReq(x.__dyUrl);}catch(e){}"
                                 @"x.addEventListener('load',function(){try{if(isDetail(x.__dyUrl))save(x.responseText);}catch(e){}});"
                                 @"return os.apply(this,arguments);};"
                                 @"})();", awemeId];
            WKUserScript *hookScript = [[WKUserScript alloc] initWithSource:hookJS injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
            [cfg.userContentController addUserScript:hookScript];
            // 加载阶段用桌面视口大frame, 模拟真实桌面窗口宽度
            WKWebView *wv = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 1024, 1366) configuration:cfg];
            wv.customUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15";
            wv.hidden = YES;
            static WKWebView *sRescueWV = nil;
            sRescueWV = wv; // 静态持有防提前释放
            UIView *kw = [UIApplication sharedApplication].keyWindow;
            if (kw) [kw addSubview:wv];
            [wv loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:pageURL]]];
            __block NSInteger tries = 0;
            __block NSInteger maxTries = 15; // 自动阶段: 4s首查+15次x2s约30s
            __block BOOL visualShown = NO;
            __block UIView *maskView = nil;
            __block void (^cleanup)(void) = nil;
            __block void (^showVisual)(void) = nil;
            __block void (^poll)(void) = nil;
            cleanup = ^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    [maskView removeFromSuperview];
                    [wv stopLoading];
                    [wv removeFromSuperview];
                    sRescueWV = nil;
                });
            };
            // 可视化: 自动阶段未拦截到时把页面弹到屏幕上, 由用户人工滑动验证码
            showVisual = ^{
                if (visualShown) return;
                visualShown = YES;
                [probeLog appendFormat:@"[WKWebView救援] 自动阶段未拦截到detail接口, 弹出页面请人工滑动验证码(最长120s)\n"];
                UIView *key = [UIApplication sharedApplication].keyWindow;
                if (!key) return;
                maskView = [[UIView alloc] initWithFrame:key.bounds];
                maskView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
                UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(20, 48, key.bounds.size.width - 40, 24)];
                tip.text = @"请滑动验证码，通过后自动继续保存";
                tip.textColor = [UIColor whiteColor];
                tip.font = [UIFont systemFontOfSize:14];
                tip.textAlignment = NSTextAlignmentCenter;
                wv.frame = CGRectMake(16, 84, key.bounds.size.width - 32, key.bounds.size.height - 110);
                wv.hidden = NO;
                [maskView addSubview:tip];
                [maskView addSubview:wv];
                [key addSubview:maskView];
            };
            poll = ^{
                if (signaled || wv == nil) return;
                tries++;
                [wv evaluateJavaScript:@"(function(){try{return ((window.__dyDetailJSON?window.__dyDetailJSON.length:0)+'|'+((window.__dyReqLog||[]).length)+'|'+(document.title||''));}catch(e){return '0|0|';}})()" completionHandler:^(id res, NSError *err) {
                    if (signaled) return;
                    NSString *info = [res isKindOfClass:[NSString class]] ? res : @"0|0|";
                    NSArray *parts = [info componentsSeparatedByString:@"|"];
                    NSInteger jsonLen = [parts count] > 0 ? [parts[0] integerValue] : 0;
                    NSInteger reqCount = [parts count] > 1 ? [parts[1] integerValue] : 0;
                    NSString *pageTitle = [parts count] > 2 ? parts[2] : @"";
                    if (jsonLen > 0) {
                        [wv evaluateJavaScript:@"(window.__dyDetailJSON||'')" completionHandler:^(id json, NSError *err2) {
                            if (signaled) return;
                            NSString *got = [json isKindOfClass:[NSString class]] ? json : nil;
                            if (got.length > 0) {
                                signaled = YES;
                                jsonResult = got;
                                [probeLog appendFormat:@"[WKWebView救援] 成功! 轮询%ld次 拦截detail JSON len=%lu 页面已发请求%ld个 回填cookie\n", (long)tries, (unsigned long)got.length, (long)reqCount];
                                [wv.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cks) {
                                    NSInteger n = 0;
                                    for (NSHTTPCookie *c in cks) {
                                        if ([c.domain containsString:@"douyin"]) { [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookie:c]; n++; }
                                    }
                                    NSLog(@"[DYYY][WKWebView救援] cookie回填 %ld 个", (long)n);
                                }];
                                cleanup();
                                dispatch_semaphore_signal(rescueSem);
                            } else {
                                [probeLog appendFormat:@"[WKWebView救援] 轮询%ld次 JSON标记存在但读取为空, 继续\n", (long)tries];
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), poll);
                            }
                        }];
                        return;
                    }
                    if (tries >= maxTries) {
                        if (visualShown) {
                            // 人工阶段超时: 读请求日志辅助定位
                            [wv evaluateJavaScript:@"(function(){try{return (window.__dyReqLog||[]).slice(0,10).join(' ; ');}catch(e){return '';}})()" completionHandler:^(id reqs, NSError *err3) {
                                if (signaled) return;
                                [probeLog appendFormat:@"[WKWebView救援] 人工阶段超时 轮询%ld次 page=%@ 已捕获请求%ld个 放弃\n页面请求(前10): %@\n", (long)tries, pageTitle.length ? pageTitle : @"-", (long)reqCount, [reqs isKindOfClass:[NSString class]] ? reqs : @"(读取失败)"];
                                signaled = YES;
                                cleanup();
                                dispatch_semaphore_signal(rescueSem);
                            }];
                        } else {
                            [probeLog appendFormat:@"[WKWebView救援] 自动阶段结束(%ld次) page=%@ 已捕获请求%ld个\n", (long)tries, pageTitle.length ? pageTitle : @"-", (long)reqCount];
                            maxTries = tries + 60; // 人工阶段再等120s
                            showVisual();
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), poll);
                        }
                        return;
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), poll);
                }];
            };
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), poll);
        } @catch (NSException *e) {
            [probeLog appendFormat:@"[WKWebView救援] 异常: %@\n", e.reason ?: @"unknown"];
            if (!signaled) { signaled = YES; dispatch_semaphore_signal(rescueSem); }
        }
    });
    dispatch_semaphore_wait(rescueSem, dispatch_time(DISPATCH_TIME_NOW, 170 * NSEC_PER_SEC));
    return jsonResult;
}

// 本地解析全画质：从awemeModel取awemeId，走ttwid+web API+bit_rate全画质（JS规则）
+ (void)localParseFullFromAwemeModel:(id)awemeModel completion:(void(^)(NSDictionary *result))completion {
    if (!awemeModel || !completion) {
        if (completion) completion(nil);
        return;
    }
    NSString *awemeId = nil;
    @try { awemeId = [awemeModel valueForKey:@"awemeID"]; } @catch (NSException *e) {}
    if (!awemeId || awemeId.length == 0) {
        @try { awemeId = [awemeModel valueForKey:@"awemeId"]; } @catch (NSException *e2) {}
    }
    if (!awemeId || awemeId.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ [DYYYUtils showToast:@"本地解析失败: 无法获取awemeId"]; });
        // 失败探针全覆盖：awemeId失败也上报剪贴板
        [[NSNotificationCenter defaultCenter] postNotificationName:@"DYYYProbeNotification" object:nil userInfo:@{@"text": @"[接口4探针][失败] 无法获取awemeId（awemeModel异常或非视频帖）"}];
        if (completion) completion(nil);
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // ===== 接口4全流程探针 =====
        __block NSMutableString *probeLog = [NSMutableString stringWithString:@"[接口4探针]\n"];
        [probeLog appendFormat:@"awemeId=%@\n", awemeId];

        // Step 0: Cookie预热——GET www.douyin.com刷新web Cookie，确保msToken等不过期
        {
            NSMutableURLRequest *warmupReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.douyin.com/"]];
            [warmupReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
            [warmupReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
            dispatch_semaphore_t warmupSem = dispatch_semaphore_create(0);
            __block NSInteger warmupStatus = 0;
            __block NSInteger warmupCookieCountBefore = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:[NSURL URLWithString:@"https://www.douyin.com/"]].count;
            NSURLSessionDataTask *warmupTask = [[NSURLSession sharedSession] dataTaskWithRequest:warmupReq completionHandler:^(NSData *wData, NSURLResponse *wResp, NSError *wErr) {
                if (wResp && [wResp isKindOfClass:[NSHTTPURLResponse class]]) warmupStatus = [(NSHTTPURLResponse *)wResp statusCode];
                dispatch_semaphore_signal(warmupSem);
            }];
            [warmupTask resume];
            dispatch_semaphore_wait(warmupSem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
            NSInteger warmupCookieCountAfter = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:[NSURL URLWithString:@"https://www.douyin.com/"]].count;
            [probeLog appendFormat:@"\n[Step0 预热]\nGET www.douyin.com → HTTP %ld\nCookie: %ld→%ld\n", (long)warmupStatus, (long)warmupCookieCountBefore, (long)warmupCookieCountAfter];
        }

        // Step 1: 构建完整Cookie（从app Cookie存储取douyin.com全部cookie，对齐JS规则）
        NSHTTPCookieStorage *cookieStore = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        NSArray *appCookies = [cookieStore cookiesForURL:[NSURL URLWithString:@"https://www.douyin.com/"]];
        NSMutableString *fullCookieStr = [NSMutableString string];
        __block NSString *ttwidStr = nil;
        // 白名单:只带 __ac_nonce+ttwid(实测冷会话直出200含4K;bd_sso/UIFID_TEMP等旧指纹与新ttwid不匹配会被Argus判Uifid Not Found 403)
        NSArray *cookieWhitelist = @[@"__ac_nonce", @"ttwid"];
        NSArray *loginCookieNames = @[@"sessionid", @"sessionid_ss", @"sid_tt", @"sid_guard", @"uid", @"sid_ucp_v1", @"ssid_ucp_v1"]; // 2.2-43
        __block NSInteger loginCount = 0;
        for (NSHTTPCookie *c in appCookies) {
            if ([cookieWhitelist containsObject:[c name]]) {
                if (fullCookieStr.length > 0) [fullCookieStr appendString:@"; "];
                [fullCookieStr appendFormat:@"%@=%@", [c name], [c value]];
            }
            if ([loginCookieNames containsObject:[c name]]) { // 2.2-43 登录态优先
                if (fullCookieStr.length > 0) [fullCookieStr appendString:@"; "];
                [fullCookieStr appendFormat:@"%@=%@", [c name], [c value]];
                loginCount++;
            }
            if ([[c name] isEqualToString:@"ttwid"]) ttwidStr = [c value];
        }
        // 探针：Cookie信息
        [probeLog appendFormat:@"\n[Step1 Cookie]\ncount=%lu\n", (unsigned long)appCookies.count];
        [probeLog appendFormat:@"[登录态] 账号cookie=%ld个\n", (long)loginCount]; // 2.2-43
        { // 2.2-52 存档登录Cookie优先: 整体替换(登录WebView收割的自洽全套, 免签名过Argus)
            NSString *savedLogin = [[NSUserDefaults standardUserDefaults] stringForKey:@"DYYYLoginCookie"];
            if (savedLogin.length > 100) {
                [fullCookieStr setString:savedLogin];
                [probeLog appendFormat:@"[2.2-52] 存档登录Cookie启用 len=%lu\n", (unsigned long)savedLogin.length];
            }
        }
        for (NSHTTPCookie *c in appCookies) {
            NSString *val = [c value];
            NSString *valPreview = val.length > 20 ? [[val substringToIndex:20] stringByAppendingString:@"..."] : val;
            [probeLog appendFormat:@"  %@=%@ (domain=%@)\n", [c name], valPreview, [c domain]];
        }
        [probeLog appendFormat:@"ttwid=%@\n", ttwidStr.length > 0 ? @"有" : @"无"];
        // 降级：如果没有ttwid，从注册接口获取并追加到cookie
        if (!ttwidStr || ttwidStr.length == 0) {
            NSString *ttwidURL = @"https://ttwid.bytedance.com/ttwid/union/register/";
            NSString *ttwidBody = @"{\"region\":\"cn\",\"aid\":6383,\"needFid\":false,\"service\":\"www.douyin.com\",\"migrate_info\":{\"ticket\":\"\",\"source\":\"node\"},\"cbUrlProtocol\":\"https\",\"union\":true}";
            NSMutableURLRequest *ttwidReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:ttwidURL]];
            ttwidReq.HTTPMethod = @"POST";
            ttwidReq.HTTPBody = [ttwidBody dataUsingEncoding:NSUTF8StringEncoding];
            [ttwidReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            [ttwidReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
            dispatch_semaphore_t ttwidSem = dispatch_semaphore_create(0);
            __block NSInteger ttwidHttpStatus = 0;
            __block NSString *ttwidFromHeader = nil;
            __block NSString *ttwidFromBody = nil;
            NSURLSessionDataTask *ttwidTask = [[NSURLSession sharedSession] dataTaskWithRequest:ttwidReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                @try {
                    NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                    ttwidHttpStatus = [httpResp statusCode];
                    NSDictionary *headers = [httpResp allHeaderFields];
                    NSString *setCookie = headers[@"Set-Cookie"];
                    if (setCookie.length > 0) {
                        NSRange r = [setCookie rangeOfString:@"ttwid="];
                        if (r.location != NSNotFound) {
                            NSString *sub = [setCookie substringFromIndex:r.location + 6];
                            NSRange semi = [sub rangeOfString:@";"];
                            ttwidFromHeader = semi.location != NSNotFound ? [sub substringToIndex:semi.location] : sub;
                            ttwidStr = ttwidFromHeader;
                        }
                    }
                    if (!ttwidStr || ttwidStr.length == 0) {
                        if (data.length > 0) {
                            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                            if ([json isKindOfClass:[NSDictionary class]]) {
                                ttwidFromBody = json[@"ttwid"];
                                if (ttwidFromBody.length > 0) ttwidStr = ttwidFromBody;
                            }
                        }
                    }
                } @catch (NSException *e) {}
                dispatch_semaphore_signal(ttwidSem);
            }];
            [ttwidTask resume];
            dispatch_semaphore_wait(ttwidSem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
            // 断网重连后网络可能未就绪，首次失败等2秒重试一次
            if (!ttwidStr || ttwidStr.length == 0) {
                [ttwidTask cancel];
                [NSThread sleepForTimeInterval:2.0];
                ttwidSem = dispatch_semaphore_create(0);
                ttwidHttpStatus = 0; ttwidFromHeader = nil; ttwidFromBody = nil;
                NSMutableURLRequest *rtReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:ttwidURL]];
                rtReq.HTTPMethod = @"POST";
                rtReq.HTTPBody = [ttwidBody dataUsingEncoding:NSUTF8StringEncoding];
                [rtReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
                [rtReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
                NSURLSessionDataTask *rtTask = [[NSURLSession sharedSession] dataTaskWithRequest:rtReq completionHandler:^(NSData *rd, NSURLResponse *rr, NSError *re) {
                    @try {
                        NSHTTPURLResponse *hr = (NSHTTPURLResponse *)rr;
                        ttwidHttpStatus = [hr statusCode];
                        NSString *sc = [hr allHeaderFields][@"Set-Cookie"];
                        if (sc.length > 0) { NSRange r2 = [sc rangeOfString:@"ttwid="]; if (r2.location != NSNotFound) { NSString *s2 = [sc substringFromIndex:r2.location + 6]; NSRange sm = [s2 rangeOfString:@";"]; ttwidFromHeader = sm.location != NSNotFound ? [s2 substringToIndex:sm.location] : s2; ttwidStr = ttwidFromHeader; } }
                        if (!ttwidStr || ttwidStr.length == 0) { if (rd.length > 0) { NSDictionary *rj = [NSJSONSerialization JSONObjectWithData:rd options:0 error:nil]; if ([rj isKindOfClass:[NSDictionary class]]) { ttwidFromBody = rj[@"ttwid"]; if (ttwidFromBody.length > 0) ttwidStr = ttwidFromBody; } } }
                    } @catch (NSException *ex) {}
                    dispatch_semaphore_signal(ttwidSem);
                }];
                [rtTask resume];
                dispatch_semaphore_wait(ttwidSem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
            }
            [probeLog appendFormat:@"\n[Step1.5 ttwid注册]\nPOST ttwid.bytedance.com → HTTP %ld\nSet-Cookie ttwid=%@ (len=%lu)\nJSON body ttwid=%@\n最终ttwid=%@\n", (long)ttwidHttpStatus, ttwidFromHeader ? [[ttwidFromHeader substringToIndex:MIN(20, ttwidFromHeader.length)] stringByAppendingString:@"..."] : @"无", (unsigned long)(ttwidFromHeader ? ttwidFromHeader.length : 0), ttwidFromBody ? @"有" : @"无", ttwidStr.length > 0 ? @"有" : @"无"];
            if (ttwidStr && ttwidStr.length > 0) {
                if (fullCookieStr.length > 0) [fullCookieStr appendString:@"; "];
                [fullCookieStr appendFormat:@"ttwid=%@", ttwidStr];
            }
        }
        if (fullCookieStr.length == 0) {
            [probeLog appendFormat:@"\n[失败] Cookie为空，无法构建请求\n"];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"DYYYProbeNotification" object:nil userInfo:@{@"text": [probeLog copy]}];
            if (completion) completion(nil);
            return;
        }
        // 存储ttwid供后续CDN下载使用
        if (ttwidStr && ttwidStr.length > 0) [DYYYManager shared].localParseTtwid = ttwidStr;

        // Step 2: web API（完整URL参数+浏览器指纹header+全Cookie，对齐JS规则）
        __block NSDictionary *awemeDetail = nil;
        NSString *apiURL = [NSString stringWithFormat:@"https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=%@&device_platform=webapp&aid=6383&channel=channel_pc_web&update_version_code=170400&pc_client_type=1&version_code=190500&version_name=19.5.0&cookie_enabled=true&screen_width=2560&screen_height=1440&browser_language=zh-CN&browser_platform=Win32&browser_name=Chrome&browser_version=150.0.0.0&browser_online=true&engine_name=Blink&engine_version=150.0.0.0&os_name=Windows&os_version=10&cpu_core_num=12&device_memory=8&platform=PC&downlink=4.75&effective_type=4g&round_trip_time=150", awemeId];
        NSMutableURLRequest *apiReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:apiURL]];
        [apiReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
        [apiReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
        [apiReq setValue:@"text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7" forHTTPHeaderField:@"Accept"];
        [apiReq setValue:@"zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6" forHTTPHeaderField:@"Accept-Language"];
        [apiReq setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
        [apiReq setValue:@"no-cache" forHTTPHeaderField:@"Pragma"];
        NSString *secChUa = [NSString stringWithFormat:@"%cChromium%c;v=%c150%c, %cGoogle Chrome%c;v=%c150%c", 34, 34, 34, 34, 34, 34, 34, 34];
        [apiReq setValue:secChUa forHTTPHeaderField:@"sec-ch-ua"];
        [apiReq setValue:@"?0" forHTTPHeaderField:@"sec-ch-ua-mobile"];
        NSString *secChPlatform = [NSString stringWithFormat:@"%cWindows%c", 34, 34];
        [apiReq setValue:secChPlatform forHTTPHeaderField:@"sec-ch-ua-platform"];
        [apiReq setValue:@"document" forHTTPHeaderField:@"sec-fetch-dest"];
        [apiReq setValue:@"navigate" forHTTPHeaderField:@"sec-fetch-mode"];
        [apiReq setValue:@"same-origin" forHTTPHeaderField:@"sec-fetch-site"];
        [apiReq setValue:@"?1" forHTTPHeaderField:@"sec-fetch-user"];
        [apiReq setValue:@"1" forHTTPHeaderField:@"upgrade-insecure-requests"];
        [apiReq setValue:fullCookieStr forHTTPHeaderField:@"Cookie"];
        [probeLog appendFormat:@"\n[Step2 发送Cookie] len=%lu preview=%@...\n", (unsigned long)fullCookieStr.length, [fullCookieStr substringToIndex:MIN(120, fullCookieStr.length)]];
        [probeLog appendFormat:@"[Step2 URL] %@\n", [apiURL substringToIndex:MIN(500, [apiURL length])]]; // 2.2-38
        dispatch_semaphore_t apiSem = dispatch_semaphore_create(0);
        NSURLSessionDataTask *apiTask = [[NSURLSession sharedSession] dataTaskWithRequest:apiReq completionHandler:^(NSData *apiData, NSURLResponse *apiResp, NSError *apiErr) {
            @try {
                if (apiData.length > 0) {
                    NSDictionary *apiJson = [NSJSONSerialization JSONObjectWithData:apiData options:0 error:nil];
                    if ([apiJson isKindOfClass:[NSDictionary class]]) {
                        NSInteger statusCode = [apiJson[@"status_code"] integerValue];
                        if (statusCode == 0) awemeDetail = apiJson[@"aweme_detail"];
                        // 探针：web API响应
                        [probeLog appendFormat:@"\n[Step2 WebAPI响应]\nstatus_code=%ld\n", (long)statusCode];
                        NSHTTPURLResponse *httpR = (NSHTTPURLResponse *)apiResp;
                        [probeLog appendFormat:@"HTTP status=%ld\n", (long)httpR.statusCode];
                        [probeLog appendFormat:@"responseBody长度=%lu\n", (unsigned long)apiData.length];
                        if (statusCode == 0 && awemeDetail) {
                            if (ttwidStr.length > 20) [[NSUserDefaults standardUserDefaults] setObject:ttwidStr forKey:@"DYYYLastGoodTtwid"]; // 2.2-38 成功会话存档
                            { // 2.2-41 配对存档: msToken取URL原文, 截流uifid有货一并入库
                                NSRange hmr = [apiURL rangeOfString:@"msToken="];
                                if (hmr.location != NSNotFound && hmr.location + hmr.length < [apiURL length]) {
                                    NSString *hmt = [apiURL substringFromIndex:hmr.location + hmr.length];
                                    NSRange her = [hmt rangeOfString:@"&"];
                                    if (her.location != NSNotFound) hmt = [hmt substringToIndex:her.location];
                                    if (hmt.length > 20) [[NSUserDefaults standardUserDefaults] setObject:hmt forKey:@"DYYYLastGoodMsToken"];
                                }
                                NSString *hsu = [DYYYManager DYYYSniffedUifid];
                                if (hsu.length > 10) [[NSUserDefaults standardUserDefaults] setObject:hsu forKey:@"DYYYLastGoodUifid"];
                            }
                            NSDictionary *vObj = awemeDetail[@"video"];
                            NSArray *brList = vObj[@"bit_rate"];
                            [probeLog appendFormat:@"bit_rate条目数=%lu\n", (unsigned long)(brList ? brList.count : 0)];
                            for (NSDictionary *br in (brList ?: @[])) {
                                NSString *gn = br[@"gear_name"] ?: @"?";
                                NSInteger brVal = [br[@"bit_rate"] integerValue];
                                NSInteger fps = [br[@"FPS"] integerValue];
                                NSDictionary *pa = br[@"play_addr"] ?: @{};
                                NSInteger h = [pa[@"height"] integerValue];
                                NSInteger w = [pa[@"width"] integerValue];
                                long long ds = [pa[@"data_size"] longLongValue];
                                [probeLog appendFormat:@"  gear=%@ bitrate=%ld fps=%ld %ldx%ld size=%lld\n", gn, (long)brVal, (long)fps, (long)w, (long)h, ds];
                            }
                        } else {
                            // 截取前200字符看错误
                            NSString *raw = [[NSString alloc] initWithData:apiData encoding:NSUTF8StringEncoding];
                            if (raw.length > 200) raw = [raw substringToIndex:200];
                            [probeLog appendFormat:@"error响应: %@\n", raw];
                        }
                    } else {
                        // 2.2-20: HTTP错误(403等)非JSON响应原文+关键头（此前403内容是黑盒）
                        NSString *raw2 = [[NSString alloc] initWithData:apiData encoding:NSUTF8StringEncoding];
                        if (raw2.length > 300) raw2 = [raw2 substringToIndex:300];
                        NSHTTPURLResponse *hr2 = [apiResp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)apiResp : nil;
                        [probeLog appendFormat:@"\n[Step2 HTTP错误响应] HTTP %ld body=%lu 原文=%@\n", (long)(hr2 ? hr2.statusCode : 0), (unsigned long)apiData.length, raw2 ?: @"(非UTF8)"];
                        if (hr2) {
                            NSDictionary *rh2 = hr2.allHeaderFields;
                            id sc2 = rh2[@"Set-Cookie"];
                            NSUInteger scCount = [sc2 isKindOfClass:[NSArray class]] ? [(NSArray *)sc2 count] : ([sc2 isKindOfClass:[NSString class]] ? 1 : 0);
                            [probeLog appendFormat:@"关键头: server=%@ x-tt-trace-tag=%@ retry-after=%@ set-cookie数=%lu\n", rh2[@"server"] ?: @"-", rh2[@"x-tt-trace-tag"] ?: @"-", rh2[@"Retry-After"] ?: @"-", (unsigned long)scCount];
                        }
                    }
                } else {
                    [probeLog appendFormat:@"\n[Step2 WebAPI响应]\n响应为空! error=%@\n", apiErr.localizedDescription];
                }
            } @catch (NSException *e) {}
            dispatch_semaphore_signal(apiSem);
        }];
        [apiTask resume];
        dispatch_semaphore_wait(apiSem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));

        if (!awemeDetail || ![awemeDetail isKindOfClass:[NSDictionary class]]) {
            // ===== 2.2-27 自愈重试：清空旧指纹会话→重新预热→注册全新ttwid→白名单重组装→重打Step2（复现冷会话直出配方）=====
            [probeLog appendFormat:@"\n[Step2.2 自愈重试] Step2失败，清空旧指纹会话重来\n"];
            NSHTTPCookieStorage *healStore = [NSHTTPCookieStorage sharedHTTPCookieStorage];
            NSURL *healURL = [NSURL URLWithString:@"https://www.douyin.com/"];
            NSUInteger healPurged = 0;
            __block NSString *healUifid = nil, *healMsToken = nil;
            NSString *healSvwebid = nil;
            for (NSHTTPCookie *hs in [healStore cookiesForURL:healURL]) {
                if ([[hs name] isEqualToString:@"UIFID_TEMP"]) healUifid = [hs value];
                else if ([[hs name] isEqualToString:@"msToken"]) healMsToken = [hs value];
                else if ([[hs name] isEqualToString:@"s_v_web_id"]) healSvwebid = [hs value];
            }
            [probeLog appendFormat:@"指纹快照: uifid=%@ msToken=%@ svwebid=%@\n", healUifid ? @"有" : @"无", healMsToken ? @"有" : @"无", healSvwebid ? @"有" : @"无"];
            // 2.2-37 App现役uifid截流, 优先于快照(这是抖音自己请求正在用的指纹)
            {
                NSString *snU = [DYYYManager DYYYSniffedUifid];
                if (snU.length > 0) {
                    healUifid = snU;
                    [probeLog appendFormat:@"[截流] App现役uifid len=%lu\n", (unsigned long)snU.length];
                }
            }
            // ===== 2.2-31 指纹雷达: 快照缺指纹时, 运行时扫描宿主App内建指纹体系(真uifid/msToken与App会话天然配套) =====
            if (healUifid.length == 0 || healMsToken.length == 0) {
                void (^radar)(void) = ^{
                    [probeLog appendFormat:@"\n[Step2.3 指纹雷达] 扫描宿主App内建指纹体系\n"];
                    @try {
                        unsigned int rc = 0;
                        Class *rclasses = objc_copyClassList(&rc);
                        if (!rclasses) return;
                        NSArray *rkw = @[@"Uifid", @"uifid", @"AppLog", @"Applog", @"applog", @"TokenManager", @"DeviceManager", @"DeviceInfo", @"Fingerprint", @"MSKernel"];
                        int rdump = 0;
                        for (unsigned int ri = 0; ri < rc && rdump < 40; ri++) {
                            NSString *rcn = NSStringFromClass(rclasses[ri]);
                            BOOL rhit = NO;
                            for (NSString *rk in rkw) if ([rcn containsString:rk]) { rhit = YES; break; }
                            if (!rhit) continue;
                            NSArray *rexcl = @[@"ByteCast", @"TIMX", @"IESEC", @"AWETeen", @"Lynx", @"Salamander", @"CoreODIE", @"VisualIntelligence", @"SavedDelete", @"UltraCreation"];
                            BOOL rskip = NO;
                            for (NSString *rx in rexcl) if ([rcn containsString:rx]) { rskip = YES; break; }
                            if (rskip) continue;
                            BOOL rdeep = [rcn containsString:@"AppLog"] || [rcn containsString:@"Applog"];
                            rdump++;
                            Class rcls = rclasses[ri];
                            id rinst = nil;
                            for (NSString *rsel in @[@"sharedInstance", @"sharedManager", @"defaultManager", @"currentManager", @"shared", @"getInstance"]) {
                                SEL rs = NSSelectorFromString(rsel);
                                if (class_getClassMethod(rcls, rs)) {
                                    @try { rinst = ((id (*)(id, SEL))objc_msgSend)(rcls, rs); } @catch (NSException *re1) {}
                                    if (rinst) break;
                                }
                            }
                            unsigned int rmc = 0;
                            __block NSMutableString *rgetters = [NSMutableString string];
                            // 类方法
                            Method *rmeths = class_copyMethodList(object_getClass(rcls), &rmc);
                            for (unsigned int rj = 0; rj < rmc; rj++) {
                                NSString *rmn = NSStringFromSelector(method_getName(rmeths[rj]));
                                char *rrtc = method_copyReturnType(rmeths[rj]);
                                if (method_getNumberOfArguments(rmeths[rj]) != 2 || !rrtc || rrtc[0] != '@') { if (rrtc) free(rrtc); continue; }
                                free(rrtc);
                                [rgetters appendFormat:@"%@+ ", rmn];
                                NSString *rl = rmn.lowercaseString;
                                BOOL rtarget = [rl containsString:@"uifid"] || [rl containsString:@"mstoken"];
                                if (!rtarget) continue;
                                @try {
                                    id rv = ((id (*)(id, SEL))objc_msgSend)(rcls, NSSelectorFromString(rmn));
                                    if ([rv isKindOfClass:[NSString class]] && [rv length] > 10 && [rv length] < 500 && ![rv isEqualToString:rcn]) {
                                        [probeLog appendFormat:@"[雷达收获] %@ +%@ => %@... (len=%lu)\n", rcn, rmn, [rv substringToIndex:MIN(50, [rv length])], (unsigned long)[rv length]];
                                        if ([rl containsString:@"uifid"] && healUifid.length == 0) healUifid = rv;
                                        if ([rl containsString:@"mstoken"] && healMsToken.length == 0) healMsToken = rv;
                                    }
                                } @catch (NSException *re2) { [probeLog appendFormat:@"[雷达异常] %@ +%@: %@\n", rcn, rmn, re2.name]; }
                            }
                            free(rmeths);
                            // 实例方法
                            if (rinst) {
                                Method *rims = class_copyMethodList(rcls, &rmc);
                                for (unsigned int rj = 0; rj < rmc; rj++) {
                                    NSString *rmn = NSStringFromSelector(method_getName(rims[rj]));
                                    char *rrtc = method_copyReturnType(rims[rj]);
                                    if (method_getNumberOfArguments(rims[rj]) != 2 || !rrtc || rrtc[0] != '@') { if (rrtc) free(rrtc); continue; }
                                    free(rrtc);
                                    [rgetters appendFormat:@"%@- ", rmn];
                                    NSString *rl = rmn.lowercaseString;
                                    BOOL rtarget = [rl containsString:@"uifid"] || [rl containsString:@"mstoken"];
                                    if (!rtarget) continue;
                                    @try {
                                        id rv = ((id (*)(id, SEL))objc_msgSend)(rinst, NSSelectorFromString(rmn));
                                        if ([rv isKindOfClass:[NSString class]] && [rv length] > 10 && [rv length] < 500 && ![rv isEqualToString:rcn]) {
                                            [probeLog appendFormat:@"[雷达收获] %@ -%@ => %@... (len=%lu)\n", rcn, rmn, [rv substringToIndex:MIN(50, [rv length])], (unsigned long)[rv length]];
                                            if ([rl containsString:@"uifid"] && healUifid.length == 0) healUifid = rv;
                                            if ([rl containsString:@"mstoken"] && healMsToken.length == 0) healMsToken = rv;
                                        }
                                    } @catch (NSException *re3) { [probeLog appendFormat:@"[雷达异常] %@ -%@: %@\n", rcn, rmn, re3.name]; }
                                }
                                free(rims);
                            }
                            [probeLog appendFormat:@"[雷达类] %@ 实例=%@ 无参getter: %@\n", rcn, rinst ? @"有" : @"无", rgetters];
                        }
                        free(rclasses);
                        [probeLog appendFormat:@"[雷达完成] 命中%d类 uifid=%@ msToken=%@\n", rdump, healUifid.length > 0 ? @"真指纹到手" : @"无", healMsToken.length > 0 ? @"真msToken到手" : @"无"];
                    } @catch (NSException *rE) { [probeLog appendFormat:@"[雷达异常] 全局: %@\n", rE]; }
                };
                radar(); // 2.2-36止血: 当前线程直接扫, 不再dispatch_sync主线程
            }
            // ===== 2.2-35 真指纹矿脉: 全量扫NSUserDefaults(uifid真实存放处, cookie只是二手拷贝) =====
            if (healUifid.length == 0 || healMsToken.length == 0) {
                @try {
                    NSDictionary *pall = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
                    int pfound = 0;
                    for (NSString *pk in pall) {
                        if (pfound > 25) break;
                        NSString *pl = pk.lowercaseString;
                        if (!([pl containsString:@"uifid"] || [pl containsString:@"mstoken"] || [pl containsString:@"ms_token"] || [pl containsString:@"device_id"] || [pl containsString:@"deviceid"])) continue;
                        id pv = pall[pk];
                        if ([pv isKindOfClass:[NSNumber class]]) pv = [pv stringValue];
                        if (![pv isKindOfClass:[NSString class]] || [pv length] < 8 || [pv length] > 500) continue;
                        pfound++;
                        [probeLog appendFormat:@"[矿脉] %@ => %@... (len=%lu)\n", pk, [pv substringToIndex:MIN(50, [pv length])], (unsigned long)[pv length]];
                        if ([pl containsString:@"uifid"] && healUifid.length == 0) healUifid = pv;
                        if ([pl containsString:@"ms"] && [pl containsString:@"token"] && healMsToken.length == 0) healMsToken = pv;
                    }
                    [probeLog appendFormat:@"[矿脉完成] 命中%dkey uifid=%@ msToken=%@\n", pfound, healUifid.length > 0 ? @"到手" : @"无", healMsToken.length > 0 ? @"到手" : @"无"];
                } @catch (NSException *pE) { [probeLog appendFormat:@"[矿脉异常] %@\n", pE]; }
            }
            // ===== 2.2-46 WebView uifid收割机v2: WKHTTPCookieStore全量收割(含httpOnly) + document.cookie双通道 =====
            if (healUifid.length == 0 && !DYYYWVBusy && [[UIApplication sharedApplication] applicationState] == UIApplicationStateActive) {
                DYYYWVBusy = YES;
                @try {
                    [probeLog appendFormat:@"[WebView收割] v2启动: 隐身浏览器加载抖音网页...\n"];
                    __block dispatch_semaphore_t wsem = dispatch_semaphore_create(0);
                    __block WKWebView *wv = nil;
                    __block NSString *wcookie = nil;
                    __block NSArray *wallCookies = nil;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        WKWebViewConfiguration *wcfg = [[WKWebViewConfiguration alloc] init];
                        wv = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 1, 1) configuration:wcfg];
                        wv.hidden = YES;
                        [wv loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://www.douyin.com/"]]];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [wv evaluateJavaScript:@"document.cookie" completionHandler:^(id wres, NSError *werr) {
                                if ([wres isKindOfClass:[NSString class]]) wcookie = wres;
                                [[WKWebsiteDataStore defaultDataStore].httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *wcs) {
                                    wallCookies = wcs;
                                    dispatch_semaphore_signal(wsem);
                                }];
                            }];
                        });
                    });
                    dispatch_semaphore_wait(wsem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(14.0 * NSEC_PER_SEC)));
                    int wkc = 0;
                    for (NSHTTPCookie *wc in wallCookies) {
                        NSString *wnl = wc.name.lowercaseString;
                        if (![wnl containsString:@"uifid"]) continue;
                        wkc++;
                        [probeLog appendFormat:@"[WebView收割] 库内 %@ (domain=%@) len=%lu%@\n", wc.name, wc.domain, (unsigned long)wc.value.length, wc.isHTTPOnly ? @" httpOnly" : @""];
                        if (wc.value.length > 10 && healUifid.length == 0) {
                            healUifid = wc.value;
                            [[NSUserDefaults standardUserDefaults] setObject:wc.value forKey:@"DYYYLastGoodUifid"];
                        }
                    }
                    [probeLog appendFormat:@"[WebView收割] WK库共%lu条cookie uifid相关=%d\n", (unsigned long)wallCookies.count, wkc];
                    if (healUifid.length == 0 && wcookie.length > 0) {
                        [probeLog appendFormat:@"[WebView收割] document.cookie len=%lu\n", (unsigned long)wcookie.length];
                        NSError *wre = nil;
                        NSRegularExpression *wrx = [NSRegularExpression regularExpressionWithPattern:@"(?i)(UIFID(?:_TEMP)?|uifid)=([^;\\s]+)" options:0 error:&wre];
                        NSArray *wms = [wrx matchesInString:wcookie options:0 range:NSMakeRange(0, wcookie.length)];
                        for (NSTextCheckingResult *wm in wms) {
                            NSString *wval = [wcookie substringWithRange:[wm rangeAtIndex:2]];
                            [probeLog appendFormat:@"[WebView收割] JS侧 %@ len=%lu\n", [wcookie substringWithRange:[wm rangeAtIndex:1]], (unsigned long)wval.length];
                            if (wval.length > 10 && healUifid.length == 0) {
                                healUifid = wval;
                                [[NSUserDefaults standardUserDefaults] setObject:wval forKey:@"DYYYLastGoodUifid"];
                            }
                        }
                    }
                    [probeLog appendFormat:@"[WebView收割] v2完成 uifid=%@\n", healUifid.length > 0 ? @"现场生成到手" : @"未产出"];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [wv stopLoading];
                        [wv removeFromSuperview];
                        wv = nil;
                    });
                } @catch (NSException *wE) { [probeLog appendFormat:@"[WebView收割异常] %@\n", wE]; }
                DYYYWVBusy = NO;
            }
            if (healMsToken.length == 0) { // 2.2-41 配对复用: 采集链没货就用历史成功msToken
                NSString *goodMs = [[NSUserDefaults standardUserDefaults] stringForKey:@"DYYYLastGoodMsToken"];
                if (goodMs.length > 20) {
                    healMsToken = goodMs;
                    [probeLog appendFormat:@"[自愈] 复用历史成功msToken len=%lu\n", (unsigned long)goodMs.length];
                }
            }
            if (healMsToken.length == 0) {
                NSMutableString *hm = [NSMutableString stringWithCapacity:116];
                NSString *halpha = @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
                for (int hqi = 0; hqi < 116; hqi++) [hm appendFormat:@"%C", [halpha characterAtIndex:arc4random_uniform((uint32_t)halpha.length)]];
                healMsToken = hm;
            }
            for (NSHTTPCookie *hc in [[healStore cookiesForURL:healURL] copy]) {
                [healStore deleteCookie:hc];
                healPurged++;
            }
            [probeLog appendFormat:@"已清除旧cookie: %lu个\n", (unsigned long)healPurged];
            NSMutableURLRequest *healWarmReq = [NSMutableURLRequest requestWithURL:healURL];
            [healWarmReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
            [healWarmReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
            dispatch_semaphore_t healWarmSem = dispatch_semaphore_create(0);
            __block NSInteger healWarmStatus = 0;
            NSURLSessionDataTask *healWarmTask = [[NSURLSession sharedSession] dataTaskWithRequest:healWarmReq completionHandler:^(NSData *hwData, NSURLResponse *hwResp, NSError *hwErr) {
                if (hwResp && [hwResp isKindOfClass:[NSHTTPURLResponse class]]) healWarmStatus = [(NSHTTPURLResponse *)hwResp statusCode];
                dispatch_semaphore_signal(healWarmSem);
            }];
            [healWarmTask resume];
            dispatch_semaphore_wait(healWarmSem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
            [probeLog appendFormat:@"重新预热 GET www.douyin.com → HTTP %ld\n", (long)healWarmStatus];
            { // 2.2-41 配对复用: uifid历史存档(采集链全空才用)
                NSString *goodUf = [[NSUserDefaults standardUserDefaults] stringForKey:@"DYYYLastGoodUifid"];
                if (goodUf.length > 10 && healUifid.length == 0) {
                    healUifid = goodUf;
                    [probeLog appendFormat:@"[自愈] 复用历史成功uifid len=%lu\n", (unsigned long)goodUf.length];
                }
            }
            __block NSString *healTtwid = nil;
            NSString *goodTtwid = [[NSUserDefaults standardUserDefaults] stringForKey:@"DYYYLastGoodTtwid"];
            if (goodTtwid.length > 20) {
                healTtwid = goodTtwid;
                [probeLog appendFormat:@"[自愈] 优先复用历史成功ttwid len=%lu\n", (unsigned long)goodTtwid.length];
            }
            if (healTtwid.length == 0) { // 2.2-38: 无成功存档才注册新ttwid
            NSString *healTtwidURL = @"https://ttwid.bytedance.com/ttwid/union/register/";
            NSString *healTtwidBody = @"{\"region\":\"cn\",\"aid\":6383,\"needFid\":false,\"service\":\"www.douyin.com\",\"migrate_info\":{\"ticket\":\"\",\"source\":\"node\"},\"cbUrlProtocol\":\"https\",\"union\":true}";
            NSMutableURLRequest *healTtwidReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:healTtwidURL]];
            healTtwidReq.HTTPMethod = @"POST";
            healTtwidReq.HTTPBody = [healTtwidBody dataUsingEncoding:NSUTF8StringEncoding];
            [healTtwidReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            [healTtwidReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
            dispatch_semaphore_t healTtwidSem = dispatch_semaphore_create(0);
            NSURLSessionDataTask *healTtwidTask = [[NSURLSession sharedSession] dataTaskWithRequest:healTtwidReq completionHandler:^(NSData *htData, NSURLResponse *htResp, NSError *htErr) {
                @try {
                    NSHTTPURLResponse *htHttp = (NSHTTPURLResponse *)htResp;
                    NSString *htSetCookie = [htHttp allHeaderFields][@"Set-Cookie"];
                    if (htSetCookie.length > 0) {
                        NSRange hr2 = [htSetCookie rangeOfString:@"ttwid="];
                        if (hr2.location != NSNotFound) {
                            NSString *hs2 = [htSetCookie substringFromIndex:hr2.location + 6];
                            NSRange hm2 = [hs2 rangeOfString:@";"];
                            healTtwid = hm2.location != NSNotFound ? [hs2 substringToIndex:hm2.location] : hs2;
                        }
                    }
                    if (!healTtwid || healTtwid.length == 0) {
                        if (htData.length > 0) {
                            NSDictionary *htJson = [NSJSONSerialization JSONObjectWithData:htData options:0 error:nil];
                            if ([htJson isKindOfClass:[NSDictionary class]]) healTtwid = htJson[@"ttwid"];
                        }
                    }
                } @catch (NSException *htEx) {}
                dispatch_semaphore_signal(healTtwidSem);
            }];
            [healTtwidTask resume];
            dispatch_semaphore_wait(healTtwidSem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
            [probeLog appendFormat:@"全新ttwid=%@\n", healTtwid.length > 0 ? @"有" : @"无"];
            if (healTtwid.length > 0) {
                ttwidStr = healTtwid;
                [DYYYManager shared].localParseTtwid = healTtwid;
            }
            } // 2.2-38 end
            NSMutableString *healCookie = [NSMutableString string];
            for (NSHTTPCookie *hc2 in [healStore cookiesForURL:healURL]) {
                if ([[hc2 name] isEqualToString:@"__ac_nonce"]) {
                    if (healCookie.length > 0) [healCookie appendString:@"; "];
                    [healCookie appendFormat:@"%@=%@", [hc2 name], [hc2 value]];
                }
            }
            if (healTtwid.length > 0) {
                if (healCookie.length > 0) [healCookie appendString:@"; "];
                [healCookie appendFormat:@"ttwid=%@", healTtwid];
                NSHTTPCookie *healNewTtwidCookie = [NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName: @"ttwid", NSHTTPCookieValue: healTtwid, NSHTTPCookieDomain: @".douyin.com", NSHTTPCookiePath: @"/"}];
                if (healNewTtwidCookie) [healStore setCookie:healNewTtwidCookie];
            }
            { // 2.2-43 自愈Cookie同样带上登录态
                NSInteger healLogin = 0;
                NSArray *healLoginNames = @[@"sessionid", @"sessionid_ss", @"sid_tt", @"sid_guard", @"uid", @"sid_ucp_v1", @"ssid_ucp_v1"];
                for (NSHTTPCookie *hc3 in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:[NSURL URLWithString:@"https://www.douyin.com/"]]) {
                    if ([healLoginNames containsObject:[hc3 name]]) {
                        if (healCookie.length > 0) [healCookie appendString:@"; "];
                        [healCookie appendFormat:@"%@=%@", [hc3 name], [hc3 value]];
                        healLogin++;
                    }
                }
                [probeLog appendFormat:@"[自愈][登录态] 账号cookie=%ld个\n", (long)healLogin];
            { // 2.2-52 自愈同样优先存档登录Cookie
                NSString *savedHeal = [[NSUserDefaults standardUserDefaults] stringForKey:@"DYYYLoginCookie"];
                if (savedHeal.length > 100) {
                    [healCookie setString:savedHeal];
                    [probeLog appendFormat:@"[2.2-52] 自愈存档登录Cookie启用 len=%lu\n", (unsigned long)savedHeal.length];
                }
            }
            }
            [probeLog appendFormat:@"自愈Cookie头 len=%lu\n", (unsigned long)healCookie.length];
            if (healCookie.length > 0) {
                // 2.2-28 全家桶重打: query追加msToken/fp → a_bogus本地签名(V6回归) → uifid头
                NSString *healUa = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36";
                NSMutableString *healQ = [NSMutableString stringWithString:[apiURL substringFromIndex:[apiURL rangeOfString:@"?"].location + 1]];
                [healQ appendFormat:@"&msToken=%@", healMsToken];
                if (healSvwebid.length > 0) [healQ appendFormat:@"&fp=%@", healSvwebid];
                NSString *healSigned = [DYYYABogus signedQueryForParams:healQ body:nil ua:healUa];
                [probeLog appendFormat:@"a_bogus签名=%@ q_len=%lu\n", healSigned.length > 0 ? @"OK" : @"失败", (unsigned long)healQ.length];
                NSMutableURLRequest *healApiReq = nil;
                if (healSigned.length > 0) {
                    healApiReq = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://www.douyin.com/aweme/v1/web/aweme/detail/?%@", healSigned]]];
                } else {
                    healApiReq = [apiReq mutableCopy];
                }
                [healApiReq setValue:healUa forHTTPHeaderField:@"User-Agent"];
                [healApiReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
                [healApiReq setValue:healCookie forHTTPHeaderField:@"Cookie"];
                if (healUifid.length > 0) {
                    [healApiReq setValue:healUifid forHTTPHeaderField:@"uifid"];
                    [probeLog appendFormat:@"uifid头 len=%lu\n", (unsigned long)healUifid.length];
                }
                __block NSInteger healHttpStatus = 0;
                __block NSInteger healStatusCode = -1;
                dispatch_semaphore_t healApiSem = dispatch_semaphore_create(0);
                NSURLSessionDataTask *healApiTask = [[NSURLSession sharedSession] dataTaskWithRequest:healApiReq completionHandler:^(NSData *haData, NSURLResponse *haResp, NSError *haErr) {
                    @try {
                        NSHTTPURLResponse *haHttp = (NSHTTPURLResponse *)haResp;
                        healHttpStatus = [haHttp statusCode];
                        if (haData.length > 0) {
                            NSDictionary *haJson = [NSJSONSerialization JSONObjectWithData:haData options:0 error:nil];
                            if ([haJson isKindOfClass:[NSDictionary class]]) {
                                healStatusCode = [haJson[@"status_code"] integerValue];
                                if (healStatusCode == 0) awemeDetail = haJson[@"aweme_detail"];
                            }
                        }
                    } @catch (NSException *haEx) {}
                    dispatch_semaphore_signal(healApiSem);
                }];
                [healApiTask resume];
                dispatch_semaphore_wait(healApiSem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
                [probeLog appendFormat:@"自愈重试结果: HTTP %ld status_code=%ld 成功=%@\n", (long)healHttpStatus, (long)healStatusCode, awemeDetail ? @"YES" : @"NO"];
            }
            // ===== 2.2-47 WebView代答: 隐身浏览器内fetch detail, 网页acrawler签名引擎自动补uifid+签名, 只收答案 =====
            if ((!awemeDetail || ![awemeDetail isKindOfClass:[NSDictionary class]]) && !DYYYWVBusy && [[UIApplication sharedApplication] applicationState] == UIApplicationStateActive) {
                DYYYWVBusy = YES;
                @try {
                    [probeLog appendFormat:@"\n[WebViewFetch] 启动: 隐身浏览器让网页代发detail请求 awemeId=%@\n", awemeId];
                    __block dispatch_semaphore_t fsem = dispatch_semaphore_create(0);
                    __block WKWebView *fwv = nil;
                    __block NSString *fresp = nil;
                    __block NSInteger fstatus = 0;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        WKWebViewConfiguration *fcfg = [[WKWebViewConfiguration alloc] init];
                        fwv = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 1, 1) configuration:fcfg];
                        fwv.hidden = YES;
                        [fwv loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://www.douyin.com/"]]];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            NSString *fjs = [NSString stringWithFormat:@"(function(){var n=0;var iv=setInterval(function(){n++;if(document.readyState==='complete'||n>20){clearInterval(iv);"
                                             "var x=new XMLHttpRequest();x.open('GET','https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=%@&device_platform=webapp&channel=aweme_web&aid=6383&version_code=170400&pc_client_type=1',true);x.withCredentials=true;x.onload=function(){window.__DYYY_RES=JSON.stringify({s:x.status,b:(x.responseText||'').substring(0,3000000)})};x.onerror=function(){window.__DYYY_RES=JSON.stringify({s:0,b:'XHRerr'})};x.send()"
                                             "}},500)})()", awemeId];
                            [fwv evaluateJavaScript:fjs completionHandler:^(id fres, NSError *ferr) {
                                if (ferr) { [probeLog appendFormat:@"[WebViewFetch] 启动JS错误: %@\n", ferr.localizedDescription]; dispatch_semaphore_signal(fsem); return; }
                                __block NSInteger pollN = 0;
                                __block dispatch_block_t fpoll;
                                fpoll = ^{
                                    pollN++;
                                    if (!fwv) return;
                                    [fwv evaluateJavaScript:@"(window.__DYYY_RES||'')" completionHandler:^(id fpr, NSError *fpe) {
                                        if ([fpr isKindOfClass:[NSString class]] && [(NSString *)fpr length] > 0) {
                                            @try {
                                                NSDictionary *fj = [NSJSONSerialization JSONObjectWithData:[(NSString *)fpr dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                                                if ([fj isKindOfClass:[NSDictionary class]]) {
                                                    fstatus = [fj[@"s"] isKindOfClass:[NSNumber class]] ? [fj[@"s"] integerValue] : 0;
                                                    fresp = fj[@"b"];
                                                }
                                            } @catch (NSException *fje) {}
                                            [probeLog appendFormat:@"[WebViewFetch] 轮询命中(第%ld次) HTTP %ld body=%lu字节\n", (long)pollN, (long)fstatus, (unsigned long)fresp.length];
                                            dispatch_semaphore_signal(fsem);
                                        } else if (pollN < 36) {
                                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), fpoll);
                                        } else {
                                            [probeLog appendString:@"[WebViewFetch] 轮询超时: __DYYY_RES始终为空(fetch未回或页面异常)\n"];
                                            dispatch_semaphore_signal(fsem);
                                        }
                                    }];
                                };
                                fpoll();
                            }];
                        });
                    });
                    dispatch_semaphore_wait(fsem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35.0 * NSEC_PER_SEC)));
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [fwv stopLoading];
                        [fwv removeFromSuperview];
                        fwv = nil;
                    });
                    [probeLog appendFormat:@"[WebViewFetch] 网页代发结果: HTTP %ld body=%lu字节\n", (long)fstatus, (unsigned long)fresp.length];
                    if (fstatus == 200 && fresp.length > 5000 && [fresp containsString:@"bit_rate"]) {
                        NSDictionary *fj = [NSJSONSerialization JSONObjectWithData:[fresp dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                        if ([fj isKindOfClass:[NSDictionary class]]) {
                            NSDictionary *fd = fj[@"aweme_detail"];
                            if (![fd isKindOfClass:[NSDictionary class]]) fd = fj[@"item_list"][0];
                            if ([fd isKindOfClass:[NSDictionary class]] && [fd objectForKey:@"bit_rate"]) {
                                awemeDetail = fd;
                                [probeLog appendFormat:@"[WebViewFetch] 成功: 网页亲答 bit_rate=%lu档, uifid/签名全由网页自己补齐\n", (unsigned long)((NSArray *)fd[@"bit_rate"]).count];
                            }
                        }
                    } else if (fresp.length > 0 && fresp.length <= 600) {
                        [probeLog appendFormat:@"[WebViewFetch] 响应原文: %@\n", fresp];
                    }
                } @catch (NSException *fE) { [probeLog appendFormat:@"[WebViewFetch异常] %@\n", fE]; }
                DYYYWVBusy = NO;
            }
            // ===== 2.2-54 服务器API兜底: 本地全灭时转用户腾讯云TikHub服务(全档直出, 实测3.7s), 接管下载 =====
            if (!awemeDetail || ![awemeDetail isKindOfClass:[NSDictionary class]]) {
                [probeLog appendFormat:@"\n[Step2.7 服务器API兜底] 转腾讯云TikHub v33 (1.15.172.174:8001)\n"];
                [[NSNotificationCenter defaultCenter] postNotificationName:@"DYYYProbeNotification" object:nil userInfo:@{@"text": [probeLog copy], @"clipboard": @YES}];
                NSString *rescueLink = [NSString stringWithFormat:@"https://www.douyin.com/video/%@", awemeId];
                NSString *rescueApi = @"http://1.15.172.174:8001/api/douyin?key=DYYY&url=";
                dispatch_async(dispatch_get_main_queue(), ^{
                    [DYYYUtils showToast:@"本地解析失败, 已切换服务器API下载..."];
                    [DYYYManager parseAndDownloadVideoWithShareLink:rescueLink apiKey:rescueApi retryCount:0];
                });
                if (completion) completion(nil);
                return;
            }
            // ===== 2.2-30 feed兜底: App端v1/feed游客态免签名(不走Argus), WebAPI全灭时的稳定底层 =====
            BOOL feedRescued = NO;
            if (!awemeDetail || ![awemeDetail isKindOfClass:[NSDictionary class]]) {
                [probeLog appendFormat:@"\n[Step2.8 feed兜底] aweme.snssdk.com v1/feed 游客态\n"];
                NSString *feedURL = [NSString stringWithFormat:@"https://aweme.snssdk.com/aweme/v1/feed/?aweme_id=%@&version_code=26.0.4&app_name=aweme&channel=App%%20Store&device_platform=iphone&device_type=iPhone15,3&os_version=18.0&aid=1128", awemeId];
                NSMutableURLRequest *feedReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:feedURL]];
                feedReq.timeoutInterval = 8;
                [feedReq setValue:@"Aweme/260400 CFNetwork/1498 Darwin/23.0.0" forHTTPHeaderField:@"User-Agent"];
                __block NSData *feedData = nil;
                __block NSInteger feedStatus = 0;
                dispatch_semaphore_t feedSem = dispatch_semaphore_create(0);
                NSURLSessionDataTask *feedTask = [[NSURLSession sharedSession] dataTaskWithRequest:feedReq completionHandler:^(NSData *fd, NSURLResponse *fr, NSError *fe) {
                    if ([fr isKindOfClass:[NSHTTPURLResponse class]]) feedStatus = [(NSHTTPURLResponse *)fr statusCode];
                    feedData = fd;
                    dispatch_semaphore_signal(feedSem);
                }];
                [feedTask resume];
                dispatch_semaphore_wait(feedSem, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC));
                [probeLog appendFormat:@"feed响应: HTTP %ld body=%lu\n", (long)feedStatus, (unsigned long)feedData.length];
                if (feedData.length > 1000) {
                    @try {
                        id fjson = [NSJSONSerialization JSONObjectWithData:feedData options:0 error:nil];
                        id fitem = nil;
                        int flistCnt = 0;
                        if ([fjson isKindOfClass:[NSDictionary class]]) {
                            NSArray *flist = fjson[@"aweme_list"];
                            // 2.2-32: 逐条校验aweme_id, 游客态可能降级推荐流, 严禁取别人的视频
                            if ([flist isKindOfClass:[NSArray class]]) {
                                for (NSDictionary *fc in flist) {
                                    if (![fc isKindOfClass:[NSDictionary class]]) continue;
                                    flistCnt++;
                                    NSString *fid = [fc[@"aweme_id"] isKindOfClass:[NSString class]] ? fc[@"aweme_id"] : [NSString stringWithFormat:@"%@", fc[@"aweme_id"] ?: @""];
                                    if ([fid isEqualToString:awemeId]) { fitem = fc; break; }
                                }
                            }
                            if (!fitem && [fjson[@"aweme_detail"] isKindOfClass:[NSDictionary class]]) {
                                NSDictionary *fd1 = fjson[@"aweme_detail"];
                                NSString *did1 = [fd1[@"aweme_id"] isKindOfClass:[NSString class]] ? fd1[@"aweme_id"] : [NSString stringWithFormat:@"%@", fd1[@"aweme_id"] ?: @""];
                                if ([did1 isEqualToString:awemeId]) fitem = fd1;
                            }
                        }
                        [probeLog appendFormat:@"feed条目=%d ID匹配=%@\n", flistCnt, fitem ? @"YES" : @"NO"];
                        NSDictionary *fvideo = [fitem isKindOfClass:[NSDictionary class]] ? fitem[@"video"] : nil;
                        NSArray *fbr = [fvideo isKindOfClass:[NSDictionary class]] ? fvideo[@"bit_rate"] : nil;
                        if ([fitem isKindOfClass:[NSDictionary class]] && [fbr isKindOfClass:[NSArray class]] && fbr.count > 0) {
                            awemeDetail = fitem;
                            feedRescued = YES;
                            [probeLog appendFormat:@"[feed兜底成功] bit_rate %lu条 gears=%@\n", (unsigned long)fbr.count, [fbr valueForKeyPath:@"gear_name"]];
                        } else {
                            [probeLog appendFormat:@"feed无匹配ID或无bit_rate(疑似推荐流降级)\n"];
                        }
                    } @catch (NSException *fe2) { [probeLog appendFormat:@"feed解析异常: %@\n", fe2]; }
                }
            }
            if (!awemeDetail || ![awemeDetail isKindOfClass:[NSDictionary class]]) {
                [probeLog appendFormat:@"\n[失败] Step2+自愈+feed兜底全失败\n"];
                [[NSNotificationCenter defaultCenter] postNotificationName:@"DYYYProbeNotification" object:nil userInfo:@{@"text": [probeLog copy], @"clipboard": @YES}];
                if (completion) completion(nil);
                return;
            }
            if (feedRescued) [probeLog appendFormat:@"[feed救回] 本次画质来自App端feed接口\n"];
        }
        // Step 3: bit_rate全画质解析（JS规则）
        NSDictionary *videoObj = awemeDetail[@"video"] ?: @{};
        NSDictionary *author = awemeDetail[@"author"] ?: @{};
        NSDictionary *music = awemeDetail[@"music"] ?: @{};
        NSMutableArray *videoList = [NSMutableArray array];
        NSMutableArray *images = [NSMutableArray array];
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        BOOL isImagePost = NO;
        NSInteger awemeType = [awemeDetail[@"aweme_type"] integerValue];
        if (awemeType == 68 || awemeType == 150) isImagePost = YES;
        NSArray *rawImages = awemeDetail[@"image_post_info"][@"images"];
        if (!rawImages || ![rawImages isKindOfClass:[NSArray class]]) rawImages = awemeDetail[@"images"];
        if (!rawImages || ![rawImages isKindOfClass:[NSArray class]]) rawImages = @[];
        if (rawImages.count > 0) isImagePost = YES;

        NSArray *bitRateList = videoObj[@"bit_rate"];
        if (!bitRateList || ![bitRateList isKindOfClass:[NSArray class]]) bitRateList = @[];
        NSMutableDictionary *byQuality = [NSMutableDictionary dictionary];
        for (NSDictionary *b in bitRateList) {
            NSDictionary *playAddr = b[@"play_addr"] ?: @{};
            NSInteger width = [playAddr[@"width"] integerValue];
            NSInteger height = [playAddr[@"height"] integerValue];
            NSInteger longerSide = (width > height) ? width : height;
            NSString *qCode = nil;
            if (longerSide >= 3840) qCode = @"2160p";
            else if (longerSide >= 2560) qCode = @"1440p";
            else if (longerSide >= 1920) qCode = @"1080p";
            else if (longerSide >= 1280) qCode = @"720p";
            else if (longerSide >= 1024) qCode = @"540p";
            if (!qCode) continue;
            NSArray *urlList = playAddr[@"url_list"];
            NSString *url = (urlList && urlList.count > 0) ? urlList[0] : nil;
            if (!url || url.length == 0) continue;
            NSInteger bitRate = [b[@"bit_rate"] integerValue];
            NSDictionary *existing = byQuality[qCode];
            if (!existing || bitRate > [existing[@"bitRate"] integerValue]) {
                byQuality[qCode] = @{@"url": url, @"size": playAddr[@"data_size"] ?: @(0), @"bitRate": @(bitRate), @"fps": b[@"FPS"] ?: @(30)};
            }
        }

        NSString *videoURI = nil;
        NSDictionary *playAddrDict = videoObj[@"play_addr"];
        if (playAddrDict && [playAddrDict isKindOfClass:[NSDictionary class]]) videoURI = playAddrDict[@"uri"];
        NSString *ttwidCookie = [NSString stringWithFormat:@"ttwid=%@", ttwidStr];
        NSMutableSet *seen = [NSMutableSet set];
        NSArray *qualities = @[@[@"2160p", @"【极致】4K"], @[@"1440p", @"【高清】2K"], @[@"default", @"原画【最高画质】"], @[@"1080p", @"【清晰】1080P"], @[@"720p", @"【标准】720P"], @[@"540p", @"【模糊】540P"]];

        for (NSArray *q in qualities) {
            NSString *qCode = q[0];
            NSString *label = q[1];
            NSString *url = nil;
            long long size = 0;
            NSInteger fps = 30;
            if ([qCode isEqualToString:@"default"]) {
                if (videoURI.length > 0) {
                    NSString *playURL = [NSString stringWithFormat:@"https://www.douyin.com/aweme/v1/play/?video_id=%@&ratio=default&line=1&device_platform=webapp&aid=6383&channel=channel_pc_web", videoURI];
                    NSMutableURLRequest *headReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:playURL]];
                    headReq.HTTPMethod = @"HEAD";
                    [headReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" forHTTPHeaderField:@"User-Agent"];
                    [headReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
                    [headReq setValue:ttwidCookie forHTTPHeaderField:@"Cookie"];
                    __block NSString *cdnURL = nil;
                    __block long long cdnSize = 0;
                    dispatch_semaphore_t headSem = dispatch_semaphore_create(0);
                    NSURLSessionDataTask *headTask = [[NSURLSession sharedSession] dataTaskWithRequest:headReq completionHandler:^(NSData *hData, NSURLResponse *hResp, NSError *hErr) {
                        if (hResp && [hResp isKindOfClass:[NSHTTPURLResponse class]]) {
                            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)hResp;
                            if (httpResp.statusCode == 302) {
                                NSString *loc = httpResp.allHeaderFields[@"Location"];
                                if (loc.length > 0) {
                                    NSURL *locURL = [NSURL URLWithString:loc];
                                    NSString *host = locURL.host;
                                    if ([host containsString:@"douyinvod.com"] || [host containsString:@"365yg.com"] || [host containsString:@"ixigua.com"] || [host containsString:@"pstatp.com"] || [host containsString:@"snssdk.com"]) {
                                        NSRange webRange = [loc rangeOfString:@"-web."];
                                        if (webRange.location != NSNotFound) loc = [loc stringByReplacingOccurrencesOfString:@"-web." withString:@"." options:0 range:webRange];
                                        cdnURL = loc;
                                        cdnSize = [httpResp expectedContentLength];
                                    }
                                }
                            } else if (httpResp.statusCode == 200) {
                                NSURL *finalURL = httpResp.URL;
                                if (finalURL) { cdnURL = [finalURL absoluteString]; cdnSize = [httpResp expectedContentLength]; }
                            }
                        }
                        dispatch_semaphore_signal(headSem);
                    }];
                    [headTask resume];
                    dispatch_semaphore_wait(headSem, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC));
                    if (cdnURL.length > 0) { url = cdnURL; size = cdnSize; }
                }
                if (!url || url.length == 0) {
                    NSString *bestKey = nil;
                    NSInteger bestBitrate = 0;
                    for (NSString *k in byQuality) { NSInteger br = [byQuality[k][@"bitRate"] integerValue]; if (br > bestBitrate) { bestBitrate = br; bestKey = k; } }
                    if (bestKey) { NSDictionary *best = byQuality[bestKey]; url = best[@"url"]; size = [best[@"size"] longLongValue]; fps = [best[@"fps"] integerValue]; }
                }
            } else {
                NSDictionary *qi = byQuality[qCode];
                if (qi) { url = qi[@"url"]; size = [qi[@"size"] longLongValue]; fps = [qi[@"fps"] integerValue]; }
            }
            if (!url || url.length == 0 || [seen containsObject:url]) continue;
            [seen addObject:url];
            NSString *sizeStr = @"";
            if (size >= 1024 * 1024 * 1024) sizeStr = [NSString stringWithFormat:@"%.2fGB", (double)size / (1024.0 * 1024.0 * 1024.0)];
            else if (size >= 1024 * 1024) sizeStr = [NSString stringWithFormat:@"%.1fMB", (double)size / (1024.0 * 1024.0)];
            else if (size >= 1024) sizeStr = [NSString stringWithFormat:@"%.0fKB", (double)size / 1024.0];
            if (size < 10240 && ![qCode isEqualToString:@"default"]) {
                dispatch_semaphore_t hSem2 = dispatch_semaphore_create(0);
                NSMutableURLRequest *hReq2 = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
                hReq2.HTTPMethod = @"HEAD";
                [hReq2 setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];
                [hReq2 setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
                __block long long hSize2 = 0;
                NSURLSessionDataTask *hTask2 = [[NSURLSession sharedSession] dataTaskWithRequest:hReq2 completionHandler:^(NSData *hD, NSURLResponse *hR, NSError *hE) {
                    if (hR && [hR isKindOfClass:[NSHTTPURLResponse class]]) { long long cl = [(NSHTTPURLResponse *)hR expectedContentLength]; if (cl > 10240) hSize2 = cl; }
                    dispatch_semaphore_signal(hSem2);
                }];
                [hTask2 resume];
                dispatch_semaphore_wait(hSem2, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
                if (hSize2 > 10240) {
                    size = hSize2;
                    if (size >= 1024 * 1024 * 1024) sizeStr = [NSString stringWithFormat:@"%.2fGB", (double)size / (1024.0 * 1024.0 * 1024.0)];
                    else if (size >= 1024 * 1024) sizeStr = [NSString stringWithFormat:@"%.1fMB", (double)size / (1024.0 * 1024.0)];
                    else if (size >= 1024) sizeStr = [NSString stringWithFormat:@"%.0fKB", (double)size / 1024.0];
                }
            }
            NSString *level = [NSString stringWithFormat:@"[%@]-[%ldFPS]", label, (long)fps];
            if (sizeStr.length > 0) level = [level stringByAppendingFormat:@"-[%@]", sizeStr];
            [videoList addObject:@{@"level": level, @"url": url}];
        }
        if (videoList.count == 0) {
            NSArray *fallbackList = videoObj[@"play_addr"][@"url_list"];
            if ([fallbackList isKindOfClass:[NSArray class]] && fallbackList.count > 0) [videoList addObject:@{@"level": @"[原画【最高画质]]-[30FPS]", @"url": fallbackList[0]}];
        }
        NSMutableArray *liveVideoURLs = [NSMutableArray array];
        if (isImagePost) {
            for (NSDictionary *img in rawImages) {
                NSArray *urlLists = @[];
                id displayImage = img[@"origin_image"] ?: img[@"display_image"];
                if (displayImage && [displayImage isKindOfClass:[NSDictionary class]]) { NSArray *ul = displayImage[@"url_list"]; if ([ul isKindOfClass:[NSArray class]]) urlLists = ul; }
                if (urlLists.count == 0) { id thumb = img[@"thumbnail"] ?: img; if ([thumb isKindOfClass:[NSDictionary class]]) { NSArray *ul = thumb[@"url_list"]; if ([ul isKindOfClass:[NSArray class]]) urlLists = ul; } }
                if (urlLists.count == 0) { NSArray *ul = img[@"url_list"]; if ([ul isKindOfClass:[NSArray class]]) urlLists = ul; }
                NSString *imgUrl = nil;
                for (NSString *u in urlLists) { if ([u hasSuffix:@".jpeg"] || [u hasSuffix:@".jpg"] || [u hasSuffix:@".png"]) { imgUrl = u; break; } }
                if (!imgUrl && urlLists.count > 0) imgUrl = urlLists[0];
                // 提取实况视频URL（同JS: img.video.play_addr.url_list[0]）
                NSDictionary *imgVideo = img[@"video"];
                NSString *liveVideoUrl = nil;
                if (imgVideo && [imgVideo isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *playAddr = imgVideo[@"play_addr"];
                    if (playAddr && [playAddr isKindOfClass:[NSDictionary class]]) {
                        NSArray *lvUrls = playAddr[@"url_list"];
                        if ([lvUrls isKindOfClass:[NSArray class]] && lvUrls.count > 0) liveVideoUrl = lvUrls[0];
                    }
                }
                if (liveVideoUrl.length > 0 && imgUrl.length > 0) {
                    [videoList addObject:@{@"level": @"实况", @"url": liveVideoUrl}];
                    [liveVideoURLs addObject:liveVideoUrl];
                    [images addObject:imgUrl];
                } else if (imgUrl.length > 0) {
                    [images addObject:imgUrl];
                }
            }
        }
        NSArray *coverUrls = videoObj[@"cover"][@"url_list"];
        if (!coverUrls) coverUrls = videoObj[@"origin_cover"][@"url_list"];
        NSString *coverUrl = ([coverUrls isKindOfClass:[NSArray class]] && coverUrls.count > 0) ? coverUrls[0] : nil;
        NSString *musicUrl = music[@"play_url"][@"uri"];
        if (!musicUrl || ![musicUrl isKindOfClass:[NSString class]]) { NSArray *mul = music[@"play_url"][@"url_list"]; if ([mul isKindOfClass:[NSArray class]] && mul.count > 0) musicUrl = mul[0]; }
        NSString *primaryUrl = videoList.count > 0 ? videoList[0][@"url"] : @"";
        if (!isImagePost) { result[@"cover"] = coverUrl ?: @""; result[@"pics"] = coverUrl ?: @""; }
        result[@"music"] = musicUrl ?: @"";
        result[@"music_url"] = musicUrl ?: @"";
        result[@"url"] = isImagePost ? @"" : primaryUrl;
        result[@"video"] = isImagePost ? @"" : primaryUrl;
        result[@"video_url"] = isImagePost ? @"" : primaryUrl;
        result[@"images"] = isImagePost ? images : @[];
        result[@"img"] = @[];
        result[@"live_videos"] = isImagePost ? liveVideoURLs : @[];
        result[@"image_count"] = @(isImagePost ? images.count : 0);
        result[@"batch_download"] = @(isImagePost && images.count > 1);
        // 图集帖只保留实况条目，无实况的图集video_list为空（走图片保存分支）
        if (isImagePost) {
            NSMutableArray *liveOnlyList = [NSMutableArray array];
            for (id item in videoList) {
                if ([item isKindOfClass:[NSDictionary class]] && [((NSDictionary *)item)[@"level"] containsString:@"实况"]) {
                    [liveOnlyList addObject:item];
                }
            }
            result[@"video_list"] = liveOnlyList;
        } else {
            result[@"video_list"] = videoList;
        }
        result[@"title"] = awemeDetail[@"desc"] ?: @"";
        result[@"author"] = author[@"nickname"] ?: @"";

        // ===== 探针：最终video_list + 弹窗展示 =====
        NSArray *finalVideoList = result[@"video_list"];
        [probeLog appendFormat:@"\n[最终画质列表] count=%lu\n", (unsigned long)(finalVideoList ? finalVideoList.count : 0)];
        for (NSDictionary *item in (finalVideoList ?: @[])) {
            NSString *lvl = item[@"level"] ?: @"?";
            NSString *u = item[@"url"] ?: @"?";
            NSString *urlPreview = u.length > 60 ? [[u substringToIndex:60] stringByAppendingString:@"..."] : u;
            [probeLog appendFormat:@"  %@ → %@\n", lvl, urlPreview];
        }
        [probeLog appendFormat:@"\nvideoURI=%@\n", videoURI ?: @"无"];
        {
            NSString *probeText = [probeLog copy];
            // 存储探针结果，通过通知在主线程弹窗
            [[NSNotificationCenter defaultCenter] postNotificationName:@"DYYYProbeNotification" object:nil userInfo:@{@"text": probeText}];
        }

        if (completion) completion(result.count > 0 ? result : nil);
    });
}
+ (void)localParseFromShareLink:(NSString *)shareLink completion:(void(^)(NSDictionary *result))completion {
    if (!shareLink || shareLink.length == 0) {
        if (completion) completion(nil);
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Step 1: 从分享链接解析awemeId
        __block NSString *awemeId = nil;
        // 直接从URL中提取
        NSRange videoRange = [shareLink rangeOfString:@"/video/"];
        if (videoRange.location != NSNotFound) {
            NSString *after = [shareLink substringFromIndex:videoRange.location + 7];
            NSRange slashRange = [after rangeOfString:@"?"];
            if (slashRange.location != NSNotFound) {
                awemeId = [after substringToIndex:slashRange.location];
            } else {
                NSRange slash2 = [after rangeOfString:@"/"];
                if (slash2.location != NSNotFound) {
                    awemeId = [after substringToIndex:slash2.location];
                } else {
                    awemeId = after;
                }
            }
        }
        // 尝试从参数中提取
        if (!awemeId || awemeId.length == 0) {
            NSRange modalRange = [shareLink rangeOfString:@"modal_id="];
            if (modalRange.location != NSNotFound) {
                NSString *after = [shareLink substringFromIndex:modalRange.location + 9];
                NSRange ampRange = [after rangeOfString:@"&"];
                awemeId = ampRange.location != NSNotFound ? [after substringToIndex:ampRange.location] : after;
            }
        }
        if (!awemeId || awemeId.length == 0) {
            NSRange awemeRange = [shareLink rangeOfString:@"aweme_id="];
            if (awemeRange.location != NSNotFound) {
                NSString *after = [shareLink substringFromIndex:awemeRange.location + 9];
                NSRange ampRange = [after rangeOfString:@"&"];
                awemeId = ampRange.location != NSNotFound ? [after substringToIndex:ampRange.location] : after;
            }
        }
        // 短链接需要先302跳转
        if ((!awemeId || awemeId.length == 0) && ([shareLink containsString:@"v.douyin.com"] || [shareLink containsString:@"vm.douyin.com"])) {
            NSURL *shortURL = [NSURL URLWithString:shareLink];
            NSMutableURLRequest *redirectReq = [NSMutableURLRequest requestWithURL:shortURL];
            redirectReq.HTTPMethod = @"HEAD";
            [redirectReq setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];
            dispatch_semaphore_t redirectSem = dispatch_semaphore_create(0);
            NSURLSessionDataTask *redirectTask = [[NSURLSession sharedSession] dataTaskWithRequest:redirectReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                if (response && [response isKindOfClass:[NSHTTPURLResponse class]]) {
                    NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                    NSString *location = httpResp.allHeaderFields[@"Location"];
                    if (!location) location = [httpResp.URL absoluteString];
                    if (location.length > 0) {
                        NSRange vr = [location rangeOfString:@"/video/"];
                        if (vr.location != NSNotFound) {
                            NSString *after = [location substringFromIndex:vr.location + 7];
                            NSRange sr = [after rangeOfString:@"?"];
                            if (sr.location != NSNotFound) awemeId = [after substringToIndex:sr.location];
                            else awemeId = after;
                        }
                        if (!awemeId || awemeId.length == 0) {
                            NSRange mr = [location rangeOfString:@"modal_id="];
                            if (mr.location != NSNotFound) {
                                NSString *after = [location substringFromIndex:mr.location + 9];
                                NSRange ar = [after rangeOfString:@"&"];
                                awemeId = ar.location != NSNotFound ? [after substringToIndex:ar.location] : after;
                            }
                        }
                    }
                }
                dispatch_semaphore_signal(redirectSem);
            }];
            [redirectTask resume];
            dispatch_semaphore_wait(redirectSem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        }

        if (!awemeId || awemeId.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ [DYYYUtils showToast:[NSString stringWithFormat:@"本地解析: 无法提取awemeId, link=%@", [shareLink substringToIndex:(shareLink.length > 50 ? 50 : shareLink.length)]]]; });
            if (completion) completion(nil);
            return;
        }

        // Step 2: 获取ttwid（优先从app Cookie存储取，降级走注册接口）
        __block NSString *ttwidStr = nil;
        // 优先从app的NSHTTPCookieStorage取ttwid（app运行时一定有）
        NSHTTPCookieStorage *shareCookieStore = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        NSArray *shareCookies = [shareCookieStore cookiesForURL:[NSURL URLWithString:@"https://www.douyin.com/"]];
        for (NSHTTPCookie *sc in shareCookies) {
            if ([[sc name] isEqualToString:@"ttwid"]) {
                ttwidStr = [sc value];
                break;
            }
        }
        // 降级：从注册接口获取
        if (!ttwidStr || ttwidStr.length == 0) {
            NSString *ttwidURL = @"https://ttwid.bytedance.com/ttwid/union/register/";
            NSString *ttwidBody = @"{\"region\":\"cn\",\"aid\":6383,\"needFid\":false,\"service\":\"www.douyin.com\",\"migrate_info\":{\"ticket\":\"\",\"source\":\"node\"},\"cbUrlProtocol\":\"https\",\"union\":true}";
            NSMutableURLRequest *ttwidReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:ttwidURL]];
            ttwidReq.HTTPMethod = @"POST";
            ttwidReq.HTTPBody = [ttwidBody dataUsingEncoding:NSUTF8StringEncoding];
            [ttwidReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            [ttwidReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" forHTTPHeaderField:@"User-Agent"];
            dispatch_semaphore_t ttwidSem = dispatch_semaphore_create(0);
            NSURLSessionDataTask *ttwidTask = [[NSURLSession sharedSession] dataTaskWithRequest:ttwidReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                @try {
                    NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                    NSDictionary *headers = [httpResp allHeaderFields];
                    NSString *setCookie = headers[@"Set-Cookie"];
                    if (setCookie.length > 0) {
                        NSRange r = [setCookie rangeOfString:@"ttwid="];
                        if (r.location != NSNotFound) {
                            NSString *sub = [setCookie substringFromIndex:r.location + 6];
                            NSRange semi = [sub rangeOfString:@";"];
                            ttwidStr = semi.location != NSNotFound ? [sub substringToIndex:semi.location] : sub;
                        }
                    }
                    // 也从响应body中取
                    if (!ttwidStr || ttwidStr.length == 0) {
                        if (data.length > 0) {
                            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                            if ([json isKindOfClass:[NSDictionary class]]) {
                                NSString *bodyTtwid = json[@"ttwid"];
                                if (bodyTtwid.length > 0) ttwidStr = bodyTtwid;
                            }
                        }
                    }
                } @catch (NSException *e) {}
                dispatch_semaphore_signal(ttwidSem);
            }];
            [ttwidTask resume];
            dispatch_semaphore_wait(ttwidSem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        }
        if (!ttwidStr || ttwidStr.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ [DYYYUtils showToast:@"本地解析: 无法获取ttwid"]; });
            if (completion) completion(nil);
            return;
        }
        [DYYYManager shared].localParseTtwid = ttwidStr;

        // Step 3: 用全Cookie调web API（4K/2K需要msToken/sid_guard等完整Cookie）
        __block NSDictionary *awemeDetail = nil;
        // 从app Cookie存储取全部douyin.com Cookie
        NSString *fullCookie = nil;
        NSHTTPCookieStorage *fullCookieStore = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        NSArray *fullCookies = [fullCookieStore cookiesForURL:[NSURL URLWithString:@"https://www.douyin.com/"]];
        if (fullCookies.count > 0) {
            NSMutableArray *cookieParts = [NSMutableArray array];
            for (NSHTTPCookie *fc in fullCookies) {
                [cookieParts addObject:[NSString stringWithFormat:@"%@=%@", [fc name], [fc value]]];
            }
            fullCookie = [cookieParts componentsJoinedByString:@"; "];
        }
        if (!fullCookie || fullCookie.length == 0) {
            fullCookie = [NSString stringWithFormat:@"ttwid=%@", ttwidStr];
        }
        NSString *apiURL = [NSString stringWithFormat:@"https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=%@&device_platform=webapp&aid=6383&channel=channel_pc_web&version_code=190600&screen_width=1920&screen_height=1080&browser_language=zh-CN&browser_name=Chrome&browser_version=126.0.0.0&cookie_enabled=true&platform=PC&downlink=10", awemeId];
        NSMutableURLRequest *apiReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:apiURL]];
        [apiReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
        [apiReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
        [apiReq setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];
        [apiReq setValue:@"zh-CN,zh;q=0.9,en;q=0.8" forHTTPHeaderField:@"Accept-Language"];
        [apiReq setValue:@"no-cors" forHTTPHeaderField:@"sec-fetch-mode"];
        [apiReq setValue:@"same-origin" forHTTPHeaderField:@"sec-fetch-site"];
        [apiReq setValue:@"empty" forHTTPHeaderField:@"sec-fetch-dest"];
        [apiReq setValue:@"\"Chromium\";v=\"126\", \"Google Chrome\";v=\"126\", \"Not-A.Brand\";v=\"99\"" forHTTPHeaderField:@"sec-ch-ua"];
        [apiReq setValue:@"?0" forHTTPHeaderField:@"sec-ch-ua-mobile"];
        [apiReq setValue:@"\"Windows\"" forHTTPHeaderField:@"sec-ch-ua-platform"];
        [apiReq setValue:fullCookie forHTTPHeaderField:@"Cookie"];
        dispatch_semaphore_t apiSem = dispatch_semaphore_create(0);
        NSURLSessionDataTask *apiTask = [[NSURLSession sharedSession] dataTaskWithRequest:apiReq completionHandler:^(NSData *apiData, NSURLResponse *apiResp, NSError *apiErr) {
            @try {
                if (apiData.length > 0) {
                    NSDictionary *apiJson = [NSJSONSerialization JSONObjectWithData:apiData options:0 error:nil];
                    if ([apiJson isKindOfClass:[NSDictionary class]]) {
                        NSInteger statusCode = [apiJson[@"status_code"] integerValue];
                        if (statusCode == 0) {
                            awemeDetail = apiJson[@"aweme_detail"];
                        }
                    }
                }
            } @catch (NSException *e) {}
            dispatch_semaphore_signal(apiSem);
        }];
        [apiTask resume];
        dispatch_semaphore_wait(apiSem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));

        if (!awemeDetail || ![awemeDetail isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{ [DYYYUtils showToast:@"本地解析: web API返回空"]; });
            if (completion) completion(nil);
            return;
        }

        // Step 4: 解析bit_rate构建画质列表
        NSDictionary *videoObj = awemeDetail[@"video"] ?: @{};
        NSDictionary *author = awemeDetail[@"author"] ?: @{};
        NSDictionary *music = awemeDetail[@"music"] ?: @{};

        NSMutableArray *videoList = [NSMutableArray array];
        NSMutableArray *images = [NSMutableArray array];
        NSMutableDictionary *result = [NSMutableDictionary dictionary];

        // 图集检测
        BOOL isImagePost = NO;
        NSInteger awemeType = [awemeDetail[@"aweme_type"] integerValue];
        if (awemeType == 68 || awemeType == 150) isImagePost = YES;
        NSArray *rawImages = awemeDetail[@"image_post_info"][@"images"];
        if (!rawImages || ![rawImages isKindOfClass:[NSArray class]]) rawImages = awemeDetail[@"images"];
        if (!rawImages || ![rawImages isKindOfClass:[NSArray class]]) rawImages = @[];
        if (rawImages.count > 0) isImagePost = YES;

        // 解析bit_rate
        NSArray *bitRateList = videoObj[@"bit_rate"];
        if (!bitRateList || ![bitRateList isKindOfClass:[NSArray class]]) bitRateList = @[];
        NSMutableDictionary *byQuality = [NSMutableDictionary dictionary];
        for (NSDictionary *b in bitRateList) {
            NSDictionary *playAddr = b[@"play_addr"] ?: @{};
            NSInteger width = [playAddr[@"width"] integerValue];
            NSInteger height = [playAddr[@"height"] integerValue];
            NSInteger longerSide = (width > height) ? width : height;
            NSString *qCode = nil;
            if (longerSide >= 3840) qCode = @"2160p";
            else if (longerSide >= 2560) qCode = @"1440p";
            else if (longerSide >= 1920) qCode = @"1080p";
            else if (longerSide >= 1280) qCode = @"720p";
            else if (longerSide >= 1024) qCode = @"540p";
            if (!qCode) continue;
            NSArray *urlList = playAddr[@"url_list"];
            NSString *url = (urlList && urlList.count > 0) ? urlList[0] : nil;
            if (!url || url.length == 0) continue;
            NSInteger bitRate = [b[@"bit_rate"] integerValue];
            NSDictionary *existing = byQuality[qCode];
            if (!existing || bitRate > [existing[@"bitRate"] integerValue]) {
                byQuality[qCode] = @{
                    @"url": url,
                    @"size": playAddr[@"data_size"] ?: @(0),
                    @"bitRate": @(bitRate),
                    @"fps": b[@"FPS"] ?: @(30)
                };
            }
        }

        // 获取videoURI用于play接口
        NSString *videoURI = nil;
        NSDictionary *playAddr = videoObj[@"play_addr"];
        if (playAddr && [playAddr isKindOfClass:[NSDictionary class]]) {
            videoURI = playAddr[@"uri"];
        }
        NSString *ttwidCookie = [NSString stringWithFormat:@"ttwid=%@", ttwidStr];
        NSMutableSet *seen = [NSMutableSet set];

        // 画质排列: 4K -> 2K -> 原画 -> 1080P -> 720P -> 540P
        NSArray *qualities = @[
            @[@"2160p", @"【极致】4K"],
            @[@"1440p", @"【高清】2K"],
            @[@"default", @"原画【最高画质】"],
            @[@"1080p", @"【清晰】1080P"],
            @[@"720p", @"【标准】720P"],
            @[@"540p", @"【模糊】540P"]
        ];

        for (NSArray *q in qualities) {
            NSString *qCode = q[0];
            NSString *label = q[1];
            NSString *url = nil;
            long long size = 0;
            NSInteger fps = 30;

            if ([qCode isEqualToString:@"default"]) {
                // 原画: 先尝试play接口302拿CDN
                if (videoURI.length > 0) {
                    NSString *playURL = [NSString stringWithFormat:@"https://www.douyin.com/aweme/v1/play/?video_id=%@&ratio=default&line=1&device_platform=webapp&aid=6383&channel=channel_pc_web", videoURI];
                    NSMutableURLRequest *headReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:playURL]];
                    headReq.HTTPMethod = @"HEAD";
                    [headReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" forHTTPHeaderField:@"User-Agent"];
                    [headReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
                    [headReq setValue:ttwidCookie forHTTPHeaderField:@"Cookie"];
                    __block NSString *cdnURL = nil;
                    __block long long cdnSize = 0;
                    dispatch_semaphore_t headSem = dispatch_semaphore_create(0);
                    NSURLSessionDataTask *headTask = [[NSURLSession sharedSession] dataTaskWithRequest:headReq completionHandler:^(NSData *hData, NSURLResponse *hResp, NSError *hErr) {
                        if (hResp && [hResp isKindOfClass:[NSHTTPURLResponse class]]) {
                            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)hResp;
                            NSInteger status = httpResp.statusCode;
                            if (status == 302) {
                                NSString *loc = httpResp.allHeaderFields[@"Location"];
                                if (loc.length > 0) {
                                    NSURL *locURL = [NSURL URLWithString:loc];
                                    NSString *host = locURL.host;
                                    if ([host containsString:@"douyinvod.com"] || [host containsString:@"365yg.com"] || [host containsString:@"ixigua.com"] || [host containsString:@"pstatp.com"] || [host containsString:@"snssdk.com"]) {
                                        NSRange webRange = [loc rangeOfString:@"-web."];
                                        if (webRange.location != NSNotFound) {
                                            loc = [loc stringByReplacingOccurrencesOfString:@"-web." withString:@"." options:0 range:webRange];
                                        }
                                        cdnURL = loc;
                                        cdnSize = [httpResp expectedContentLength];
                                    }
                                }
                            } else if (status == 200) {
                                NSURL *finalURL = httpResp.URL;
                                if (finalURL) {
                                    cdnURL = [finalURL absoluteString];
                                    cdnSize = [httpResp expectedContentLength];
                                }
                            }
                        }
                        dispatch_semaphore_signal(headSem);
                    }];
                    [headTask resume];
                    dispatch_semaphore_wait(headSem, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC));
                    if (cdnURL.length > 0) {
                        url = cdnURL;
                        size = cdnSize;
                    }
                }
                // play接口失败, fallback到bit_rate最高码率
                if (!url || url.length == 0) {
                    NSString *bestKey = nil;
                    NSInteger bestBitrate = 0;
                    for (NSString *k in byQuality) {
                        NSInteger br = [byQuality[k][@"bitRate"] integerValue];
                        if (br > bestBitrate) { bestBitrate = br; bestKey = k; }
                    }
                    if (bestKey) {
                        NSDictionary *best = byQuality[bestKey];
                        url = best[@"url"];
                        size = [best[@"size"] longLongValue];
                        fps = [best[@"fps"] integerValue];
                    }
                }
            } else {
                NSDictionary *qi = byQuality[qCode];
                if (qi) {
                    url = qi[@"url"];
                    size = [qi[@"size"] longLongValue];
                    fps = [qi[@"fps"] integerValue];
                }
            }
            if (!url || url.length == 0 || [seen containsObject:url]) continue;
            [seen addObject:url];

            // 格式化大小
            NSString *sizeStr = @"";
            if (size >= 1024 * 1024 * 1024) sizeStr = [NSString stringWithFormat:@"%.2fGB", (double)size / (1024.0 * 1024.0 * 1024.0)];
            else if (size >= 1024 * 1024) sizeStr = [NSString stringWithFormat:@"%.1fMB", (double)size / (1024.0 * 1024.0)];
            else if (size >= 1024) sizeStr = [NSString stringWithFormat:@"%.0fKB", (double)size / 1024.0];

            // 对没有HEAD到大小的bit_rate条目，做HEAD获取
            if (size < 10240 && ![qCode isEqualToString:@"default"]) {
                dispatch_semaphore_t hSem2 = dispatch_semaphore_create(0);
                NSMutableURLRequest *hReq2 = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
                hReq2.HTTPMethod = @"HEAD";
                [hReq2 setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];
                [hReq2 setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
                __block long long hSize2 = 0;
                NSURLSessionDataTask *hTask2 = [[NSURLSession sharedSession] dataTaskWithRequest:hReq2 completionHandler:^(NSData *hD, NSURLResponse *hR, NSError *hE) {
                    if (hR && [hR isKindOfClass:[NSHTTPURLResponse class]]) {
                        long long cl = [(NSHTTPURLResponse *)hR expectedContentLength];
                        if (cl > 10240) hSize2 = cl;
                    }
                    dispatch_semaphore_signal(hSem2);
                }];
                [hTask2 resume];
                dispatch_semaphore_wait(hSem2, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
                if (hSize2 > 10240) {
                    size = hSize2;
                    if (size >= 1024 * 1024 * 1024) sizeStr = [NSString stringWithFormat:@"%.2fGB", (double)size / (1024.0 * 1024.0 * 1024.0)];
                    else if (size >= 1024 * 1024) sizeStr = [NSString stringWithFormat:@"%.1fMB", (double)size / (1024.0 * 1024.0)];
                    else if (size >= 1024) sizeStr = [NSString stringWithFormat:@"%.0fKB", (double)size / 1024.0];
                }
            }

            NSString *level = [NSString stringWithFormat:@"[%@]-[%ldFPS]", label, (long)fps];
            if (sizeStr.length > 0) level = [level stringByAppendingFormat:@"-[%@]", sizeStr];
            [videoList addObject:@{@"level": level, @"url": url}];
        }

        // 图集图片
        if (isImagePost) {
            for (NSDictionary *img in rawImages) {
                NSArray *urlLists = @[];
                id displayImage = img[@"origin_image"] ?: img[@"display_image"];
                if (displayImage && [displayImage isKindOfClass:[NSDictionary class]]) {
                    NSArray *ul = displayImage[@"url_list"];
                    if ([ul isKindOfClass:[NSArray class]]) urlLists = ul;
                }
                if (urlLists.count == 0) {
                    id thumb = img[@"thumbnail"] ?: img;
                    if ([thumb isKindOfClass:[NSDictionary class]]) {
                        NSArray *ul = thumb[@"url_list"];
                        if ([ul isKindOfClass:[NSArray class]]) urlLists = ul;
                    }
                }
                if (urlLists.count == 0) {
                    NSArray *ul = img[@"url_list"];
                    if ([ul isKindOfClass:[NSArray class]]) urlLists = ul;
                }
                NSString *imgUrl = nil;
                for (NSString *u in urlLists) {
                    if ([u hasSuffix:@".jpeg"] || [u hasSuffix:@".jpg"] || [u hasSuffix:@".png"]) { imgUrl = u; break; }
                }
                if (!imgUrl && urlLists.count > 0) imgUrl = urlLists[0];
                if (imgUrl.length > 0) [images addObject:imgUrl];
            }
        }

        // 封面
        NSArray *coverUrls = videoObj[@"cover"][@"url_list"];
        if (!coverUrls) coverUrls = videoObj[@"origin_cover"][@"url_list"];
        NSString *coverUrl = nil;
        if ([coverUrls isKindOfClass:[NSArray class]] && coverUrls.count > 0) coverUrl = coverUrls[0];

        // 音乐
        NSString *musicUrl = music[@"play_url"][@"uri"];
        if (!musicUrl || ![musicUrl isKindOfClass:[NSString class]]) {
            NSArray *musicUrls = music[@"play_url"][@"url_list"];
            if ([musicUrls isKindOfClass:[NSArray class]] && musicUrls.count > 0) musicUrl = musicUrls[0];
        }

        // 作者
        NSString *authorName = author[@"nickname"];

        // 标题
        NSString *title = awemeDetail[@"desc"];

        // 构建DYYY格式结果
        NSString *primaryUrl = videoList.count > 0 ? videoList[0][@"url"] : @"";
        if (!isImagePost) {
            result[@"cover"] = coverUrl ?: @"";
            result[@"pics"] = coverUrl ?: @"";
        }
        result[@"music"] = musicUrl ?: @"";
        result[@"music_url"] = musicUrl ?: @"";
        result[@"url"] = isImagePost ? @"" : primaryUrl;
        result[@"video"] = isImagePost ? @"" : primaryUrl;
        result[@"video_url"] = isImagePost ? @"" : primaryUrl;
        result[@"images"] = isImagePost ? images : @[];
        result[@"img"] = @[];
        result[@"live_videos"] = @[];
        result[@"image_count"] = @(isImagePost ? images.count : 0);
        result[@"batch_download"] = @(isImagePost && images.count > 1);
        result[@"video_list"] = isImagePost ? @[] : videoList;
        result[@"title"] = title ?: @"";
        result[@"author"] = authorName ?: @"";

        if (completion) completion(result.count > 0 ? result : nil);
    });
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
                                                                                                        NSMutableArray *allLivePhotoDicts = [NSMutableArray array];
                                                                                                        for (NSDictionary *pair in livePhotoPairs) {
                                                                                                            [allLivePhotoDicts addObject:@{
                                                                                                                @"imageURL": pair[@"image"],
                                                                                                                @"videoURL": pair[@"video"]
                                                                                                            }];
                                                                                                        }
                                                                                                        [DYYYManager downloadAllLivePhotosWithProgress:allLivePhotoDicts
                                                                                                                                            progress:nil
                                                                                                                                          completion:^(NSInteger successCount, NSInteger totalCount){
                                                                                                                                          }];
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
                                                                                                    AWEUserSheetAction *subShareCountAction = [self shareCountActionWithCount:dataDict[@"share_count"]];
                                                                                                    if (subShareCountAction) {
                                                                                                        [qualityActions addObject:subShareCountAction];
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
                                                                                                                                                                                    [self resolveAndDownloadVideo:videoDownloadUrl
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
                // 获取作者信息（同时存入DYYYManager供音频文件名使用）
                NSString *authorName = nil;
                NSString *authorDouyinID = nil;
                // 尝试从多个字段获取作者名
                NSArray *authorKeys = @[@"author", @"nickname", @"author_name", @"music_author", @"author_nickname", @"music_author_name", @"user", @"user_name"];
                // 尝试获取抖音号
                NSArray *douyinIDKeys = @[@"author_id", @"uid", @"user_id", @"short_id", @"unique_id", @"douyin_id", @"sec_uid"];
                for (NSString *key in authorKeys) {
                    id value = dataDict[key];
                    if (value && [value isKindOfClass:[NSString class]] && [value length] > 0) {
                        authorName = value;
                        break;
                    }
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
                // 获取抖音号
                for (NSString *key in douyinIDKeys) {
                    id value = dataDict[key];
                    if (value && [value isKindOfClass:[NSString class]] && [value length] > 0) {
                        authorDouyinID = value;
                        break;
                    }
                    if ([value isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *authorDict = (NSDictionary *)value;
                        for (NSString *innerKey in @[@"id", @"uid", @"short_id", @"unique_id"]) {
                            if (authorDict[innerKey] && [authorDict[innerKey] isKindOfClass:[NSString class]] && [authorDict[innerKey] length] > 0) {
                                authorDouyinID = authorDict[innerKey];
                                break;
                            }
                        }
                        if (authorDouyinID) break;
                    }
                }
                // 存入DYYYManager供音频文件名使用
                if (authorName.length > 0) {
                    [DYYYManager shared].currentAuthorNickname = authorName;
                }
                if (authorDouyinID.length > 0) {
                    [DYYYManager shared].currentAuthorShortID = authorDouyinID;
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
            
            // 选项5：保存当前图片（实况帖也可以只存图片）
            NSInteger savedImgIndex = [DYYYManager shared].currentImageIndex;
            NSMutableArray *allImages = [NSMutableArray array];
            for (id imgObj in images) {
                if ([imgObj isKindOfClass:[NSString class]] && [(NSString *)imgObj length] > 0) {
                    [allImages addObject:imgObj];
                }
            }
            if (allImages.count > 0) {
                NSString *currentImgTitle = allImages.count > 1 ? @"保存当前图片" : @"保存图片";
                AWEUserSheetAction *currentImgAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:currentImgTitle
                                                                                    imgName:nil
                                                                                    handler:^{
                                                                                        NSInteger idx = savedImgIndex > 0 ? savedImgIndex - 1 : 0;
                                                                                        if (idx < allImages.count) {
                                                                                            NSURL *imgUrl = [NSURL URLWithString:allImages[idx]];
                                                                                            [DYYYManager downloadMedia:imgUrl mediaType:MediaTypeImage audio:nil completion:^(BOOL success) {
                                                                                                if (!success) { [DYYYUtils showToast:@"图片下载失败"]; }
                                                                                            }];
                                                                                        } else {
                                                                                            [DYYYUtils showToast:@"无法定位当前图片"];
                                                                                        }
                                                                                    }];
                [actions addObject:currentImgAction];
            }
            if (allImages.count > 1) {
                AWEUserSheetAction *allImgAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"保存全部图片"
                                                                                    imgName:nil
                                                                                    handler:^{
                                                                                        [DYYYManager downloadAllImages:allImages];
                                                                                    }];
                [actions addObject:allImgAction];
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
                                                                                                            [self resolveAndDownloadVideo:videoDownloadUrl
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
                // 获取作者信息（同时存入DYYYManager供音频文件名使用）
                NSString *authorName = nil;
                NSString *authorDouyinID = nil;
                NSArray *authorKeys = @[@"author", @"nickname", @"author_name", @"music_author", @"author_nickname", @"music_author_name", @"user", @"user_name"];
                NSArray *douyinIDKeys = @[@"author_id", @"uid", @"user_id", @"short_id", @"unique_id", @"douyin_id", @"sec_uid"];
                for (NSString *key in authorKeys) {
                    id value = dataDict[key];
                    if (value && [value isKindOfClass:[NSString class]] && [value length] > 0) {
                        authorName = value;
                        break;
                    }
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
                // 获取抖音号
                for (NSString *key in douyinIDKeys) {
                    id value = dataDict[key];
                    if (value && [value isKindOfClass:[NSString class]] && [value length] > 0) {
                        authorDouyinID = value;
                        break;
                    }
                    if ([value isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *authorDict = (NSDictionary *)value;
                        for (NSString *innerKey in @[@"id", @"uid", @"short_id", @"unique_id"]) {
                            if (authorDict[innerKey] && [authorDict[innerKey] isKindOfClass:[NSString class]] && [authorDict[innerKey] length] > 0) {
                                authorDouyinID = authorDict[innerKey];
                                break;
                            }
                        }
                        if (authorDouyinID) break;
                    }
                }
                // 存入DYYYManager供音频文件名使用
                if (authorName.length > 0) {
                    [DYYYManager shared].currentAuthorNickname = authorName;
                }
                if (authorDouyinID.length > 0) {
                    [DYYYManager shared].currentAuthorShortID = authorDouyinID;
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
                // 转发量行
                NSNumber *localShareCount = dataDict[@"share_count"];
                AWEUserSheetAction *shareCountAction = [self shareCountActionWithCount:localShareCount];

                if (disclaimerDetail) {
                    [actions insertObject:disclaimerDetail atIndex:0];
                }
                if (disclaimerAction) {
                    [actions insertObject:disclaimerAction atIndex:0];
                }
                if (shareCountAction) {
                    NSInteger insertIdx = 0;
                    if (disclaimerAction) insertIdx++;
                    if (disclaimerDetail) insertIdx++;
                    [actions insertObject:shareCountAction atIndex:insertIdx];
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
                                                                                              [self resolveAndDownloadVideo:videoDownloadUrl
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
        [self resolveAndDownloadVideo:videoDownloadUrl
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

+ (void)resolveAndDownloadVideo:(NSURL *)url audio:(NSURL *)audioURL completion:(void (^)(BOOL success))completion {
    if (!url) {
        if (completion) completion(NO);
        return;
    }
    NSString *urlStr = url.absoluteString;
    // play接口URL：HEAD+GET解析CDN直链
    if ([urlStr containsString:@"douyin.com/aweme/v1/play/"]) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"HEAD";
        [req setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
        [req setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
        NSString *cdTtwid = [DYYYManager shared].localParseTtwid;
        if (cdTtwid.length > 0) {
            // play接口请求需要ttwid认证
            [req setValue:[NSString stringWithFormat:@"ttwid=%@", cdTtwid] forHTTPHeaderField:@"Cookie"];
        }
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 15.0;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
        [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSURL *resolvedURL = nil;
            if (response) {
                resolvedURL = response.URL;
            }
            if (!resolvedURL) resolvedURL = url;
            // 如果HEAD没跟随302到CDN，用GET重试
            if ([resolvedURL.absoluteString containsString:@"douyin.com/aweme/v1/play/"]) {
                NSLog(@"[DYYY] play接口HEAD未302到CDN，GET重试: %@", resolvedURL.absoluteString);
                NSMutableURLRequest *getReq = [NSMutableURLRequest requestWithURL:url];
                getReq.HTTPMethod = @"GET";
                [getReq setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
                [getReq setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
                NSURLSessionConfiguration *getConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
                getConfig.timeoutIntervalForRequest = 15.0;
                getConfig.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
                NSURLSession *getSession = [NSURLSession sessionWithConfiguration:getConfig];
                [[getSession dataTaskWithRequest:getReq completionHandler:^(NSData *getData, NSURLResponse *getResponse, NSError *getError) {
                    NSURL *getCdnURL = getResponse.URL;
                    if (!getCdnURL || [getCdnURL.absoluteString containsString:@"douyin.com/aweme/v1/play/"]) getCdnURL = url;
                    NSLog(@"[DYYY] play接口GET解析: %@ -> %@", url.absoluteString, getCdnURL.absoluteString);
                    [self downloadMedia:getCdnURL mediaType:MediaTypeVideo audio:audioURL completion:completion];
                }] resume];
                return;
            }
            NSLog(@"[DYYY] play接口解析: %@ -> %@", url.absoluteString, resolvedURL.absoluteString);
            [self downloadMedia:resolvedURL mediaType:MediaTypeVideo audio:audioURL completion:completion];
        }] resume];
        return;
    }
    // CDN直链URL：先HEAD解析获取新鲜CDN URL，降级直连
    BOOL isCDNURL = ([urlStr containsString:@"douyinvod.com"] ||
                     [urlStr containsString:@"365yg.com"] ||
                     [urlStr containsString:@"ixigua.com"] ||
                     [urlStr containsString:@"pstatp.com"] ||
                     [urlStr containsString:@"snssdk.com"]);
    if (isCDNURL) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"HEAD";
        [req setValue:@"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
        [req setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 5.0;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
        [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSURL *resolvedURL = url;
            if (response && [response isKindOfClass:[NSHTTPURLResponse class]]) {
                NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                if (httpResp.statusCode >= 200 && httpResp.statusCode < 400) {
                    NSURL *finalURL = httpResp.URL;
                    if (finalURL) resolvedURL = finalURL;
                }
            }
            NSLog(@"[DYYY] CDN HEAD解析: %@ -> %@", url.absoluteString, resolvedURL.absoluteString);
            [self downloadMedia:resolvedURL mediaType:MediaTypeVideo audio:audioURL completion:completion];
        }] resume];
        return;
    }
    // 其他URL，直接下载
    [self downloadMedia:url mediaType:MediaTypeVideo audio:audioURL completion:completion];
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
