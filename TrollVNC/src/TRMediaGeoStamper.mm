/*
  TRMediaGeoStamper - 相册媒体 GPS 包装器（实现，2026-08-28）
  图片：ImageIO 透传重写 EXIF GPS（无损，JPEG/HEIC 主战场；PNG 走系统 eXIf 尽力）
  视频：AVAssetReader/Writer 逐轨直拷 + MetadataAdaptor 写 ISO6709（不重编码）
*/
#import "TRMediaGeoStamper.h"
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreLocation/CoreLocation.h>

static NSString *const kTMGErrDomain = @"com.trollvnc.mediaGeoStamper";

static NSError *tmgError(int code, NSString *msg) {
    return [NSError errorWithDomain:kTMGErrDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @"GPS 包装失败"}];
}

@implementation TRMediaGeoStamper

#pragma mark - 图片（ImageIO 无损透传）

+ (nullable NSData *)stampImageData:(NSData *)src
                                uti:(CFStringRef * _Nullable)outUTI
                               mode:(TRMediaGpsMode)mode
                                lat:(double)lat
                                lon:(double)lon
                              error:(NSError **)error {
    if (!src.length) { if (error) *error = tmgError(1, @"图片数据为空"); return nil; }
    CGImageSourceRef srcRef = CGImageSourceCreateWithData((__bridge CFDataRef)src, NULL);
    if (!srcRef) { if (error) *error = tmgError(2, @"图片解码失败（ImageIO 无法识别该格式）"); return nil; }
    CFStringRef uti = CGImageSourceGetType(srcRef);
    if (!uti) { CFRelease(srcRef); if (error) *error = tmgError(3, @"图片类型未知"); return nil; }
    if (outUTI) *outUTI = uti;   // 调用方（如有）需自行 CFRelease；这里所有权转移

    NSDictionary *rawProps = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(srcRef, 0, NULL);
    NSMutableDictionary *props = [NSMutableDictionary dictionary];
    if (rawProps) [props addEntriesFromDictionary:rawProps];

    // 无论写/清都先移除旧 GPS（Write 在下方重新装配）
    [props removeObjectForKey:(__bridge NSString *)kCGImagePropertyGPSDictionary];

    if (mode == TRMediaGpsModeWrite) {
        if (lat < -90.0 || lat > 90.0 || lon < -180.0 || lon > 180.0) {
            CFRelease(srcRef);
            if (error) *error = tmgError(4, @"坐标越界（lat±90 / lon±180）");
            return nil;
        }
        // 校准 GPS 时间到"现在"，避免 EXIF GPSDateStamp 与拍摄时间错位引发常识性怀疑
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy:MM:dd";
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        NSDateFormatter *tf = [[NSDateFormatter alloc] init];
        tf.dateFormat = @"HH:mm:ss.SSS";
        tf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        NSDate *now = [NSDate date];

        NSMutableDictionary *gps = [NSMutableDictionary dictionary];
        gps[(__bridge NSString *)kCGImagePropertyGPSLatitude] = @(fabs(lat));
        gps[(__bridge NSString *)kCGImagePropertyGPSLatitudeRef] = lat >= 0 ? @"N" : @"S";
        gps[(__bridge NSString *)kCGImagePropertyGPSLongitude] = @(fabs(lon));
        gps[(__bridge NSString *)kCGImagePropertyGPSLongitudeRef] = lon >= 0 ? @"E" : @"W";
        gps[(__bridge NSString *)kCGImagePropertyGPSAltitude] = @0.0;
        gps[(__bridge NSString *)kCGImagePropertyGPSTimeStamp] = [tf stringFromDate:now];
        gps[(__bridge NSString *)kCGImagePropertyGPSDateStamp] = [df stringFromDate:now];
        props[(__bridge NSString *)kCGImagePropertyGPSDictionary] = gps;
        // 同步 Exif 内若残留 GPS 相关字段的一并清掉（兼容部分写入器放在 Exif 字典里）
        NSMutableDictionary *exif = [props[(__bridge NSString *)kCGImagePropertyExifDictionary] mutableCopy];
        if (exif && exif.count) {
            NSArray *gpsKeys = @[@"GPSLatitude", @"GPSLatitudeRef", @"GPSLongitude",
                                 @"GPSLongitudeRef", @"GPSAltitude", @"GPSAltitudeRef",
                                 @"GPSTimeStamp", @"GPSDateStamp", @"GPSHPositioningError"];
            for (NSString *k in gpsKeys) [exif removeObjectForKey:k];
            props[(__bridge NSString *)kCGImagePropertyExifDictionary] = exif;
        }
    }
    // Clear：旧 GPS 已移除，Exif 内残留同样清
    else if (mode == TRMediaGpsModeClear) {
        NSMutableDictionary *exif = [props[(__bridge NSString *)kCGImagePropertyExifDictionary] mutableCopy];
        if (exif && exif.count) {
            NSArray *gpsKeys = @[@"GPSLatitude", @"GPSLatitudeRef", @"GPSLongitude",
                                 @"GPSLongitudeRef", @"GPSAltitude", @"GPSAltitudeRef",
                                 @"GPSTimeStamp", @"GPSDateStamp", @"GPSHPositioningError"];
            for (NSString *k in gpsKeys) [exif removeObjectForKey:k];
            props[(__bridge NSString *)kCGImagePropertyExifDictionary] = exif;
        }
    }
    // Keep：调用方不应进入（本方法可不支持），但防御性原样透传

    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, uti, 1, NULL);
    if (!dst) { CFRelease(srcRef); if (error) *error = tmgError(5, @"输出上下文创建失败"); return nil; }
    CGImageDestinationAddImageFromSource(dst, srcRef, 0, (__bridge CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CFRelease(srcRef);
    if (!ok) { if (error) *error = tmgError(6, @"图片元数据重写失败（格式不支持 GPS 改写？）"); return nil; }
    return out;
}

#pragma mark - 视频（AVAssetReader/Writer 直拷 + ISO6709）

+ (nullable NSData *)stampVideoData:(NSData *)src
                               mode:(TRMediaGpsMode)mode
                                lat:(double)lat
                                lon:(double)lon
                              error:(NSError **)error {
    if (!src.length) { if (error) *error = tmgError(11, @"视频数据为空"); return nil; }
    if (mode != TRMediaGpsModeWrite && mode != TRMediaGpsModeClear) {
        if (error) *error = tmgError(12, @"视频仅支持 Write/Clear");
        return nil;
    }
    if (mode == TRMediaGpsModeWrite && (lat < -90.0 || lat > 90.0 || lon < -180.0 || lon > 180.0)) {
        if (error) *error = tmgError(13, @"坐标越界（lat±90 / lon±180）");
        return nil;
    }

    // 临时文件 → AVURLAsset
    NSString *ext = [src.description rangeOfString:@"mp4"].length ? @"mp4" : @"mov";
    NSString *inPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"gps_stamp_in_%ld.%@", (long)[NSDate date].timeIntervalSince1970, ext]];
    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"gps_stamp_out_%ld.%@", (long)[NSDate date].timeIntervalSince1970, ext]];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![src writeToFile:inPath atomically:YES]) {
        if (error) *error = tmgError(14, @"视频临时文件写入失败"); return nil;
    }
    if ([fm fileExistsAtPath:outPath]) [fm removeItemAtPath:outPath error:nil];

    NSURL *inURL = [NSURL fileURLWithPath:inPath];
    AVURLAsset *asset = [AVURLAsset assetWithURL:inURL];
    NSError *rErr = nil, *wErr = nil;
    NSURL *outURL = [NSURL fileURLWithPath:outPath];
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&rErr];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:outURL
                                                     fileType:AVFileTypeMPEG4
                                                        error:&wErr];
    if (!reader || !writer) {
        [fm removeItemAtPath:inPath error:nil];
        if (error) *error = tmgError(15, [NSString stringWithFormat:@"视频打开失败: %@",
                                          (wErr ?: rErr).localizedDescription ?: @""]);
        return nil;
    }

    // 1) 视频轨 + 音频轨：逐 sample 直拷（不重编码，画质无损）
    NSArray *vidTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    NSArray *audTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (!vidTracks.count) {
        [fm removeItemAtPath:inPath error:nil];
        if (error) *error = tmgError(16, @"视频无视频轨");
        return nil;
    }
    NSMutableArray<AVAssetReaderOutput *> *rOuts = [NSMutableArray array];
    NSMutableArray<AVAssetWriterInput *> *wIns = [NSMutableArray array];
    for (AVAssetTrack *tr in vidTracks) {
        AVAssetReaderTrackOutput *ro = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tr outputSettings:nil];   // 14.5 SDK 旧名
        AVAssetWriterInput *wi = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                  outputSettings:nil
                                                                sourceFormatHint:(__bridge CMFormatDescriptionRef)tr.formatDescriptions.firstObject];
        wi.transform = tr.preferredTransform;
        wi.expectsMediaDataInRealTime = NO;
        if ([reader canAddOutput:ro]) [reader addOutput:ro];
        if ([writer canAddInput:wi]) [writer addInput:wi];
        [rOuts addObject:ro]; [wIns addObject:wi];
    }
    for (AVAssetTrack *tr in audTracks) {
        AVAssetReaderTrackOutput *ro = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tr outputSettings:nil];
        AVAssetWriterInput *wi = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                                  outputSettings:nil
                                                                sourceFormatHint:(__bridge CMFormatDescriptionRef)tr.formatDescriptions.firstObject];
        wi.expectsMediaDataInRealTime = NO;
        if ([reader canAddOutput:ro]) [reader addOutput:ro];
        if ([writer canAddInput:wi]) [writer addInput:wi];
        [rOuts addObject:ro]; [wIns addObject:wi];
    }

    // 2.5) GPS 全局元数据（writer.metadata——不建 metadata 轨：
    // 2026-08-28 真机崩溃修复①：AVAssetWriterInputMetadataAdaptor 要求 metadata input 带 format hint，
    // nil hint 构造即抛 NSInvalidArgumentException → 未捕获 SIGABRT 杀 daemon；改 writer.metadata 无异常路径。
    // 修复②（真机第二坑）：writer.metadata 必须于 startWriting（status=Writing）之前设置，否则
    // setMetadata 抛异常 Cannot call method when status is 1——故本段置于 startReading/startWriting 之前。
    if (mode == TRMediaGpsModeWrite) {
        NSString *iso = [NSString stringWithFormat:@"%+.7f%+.7f/", lat, lon];
        AVMutableMetadataItem *loc = [[AVMutableMetadataItem alloc] init];
        loc.key = AVMetadataIdentifierQuickTimeMetadataLocationISO6709;
        loc.keySpace = AVMetadataKeySpaceQuickTimeMetadata;
        loc.value = iso;
        writer.metadata = @[loc];
    }
    // Clear 模式：重 mux 不写任何 location 元数据 = 无位置（源 location 不继承）

    if (![reader startReading] || ![writer startWriting]) {
        [fm removeItemAtPath:inPath error:nil];
        if (error) *error = tmgError(17, @"视频读写启动失败");
        return nil;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    // 3) 主轨拷贝循环
    // 2026-08-28 真机第三坑：requestMediaDataWhenReady 的 block 会被系统多次回调，
    // 曾在每次回调 leave（enter 仅一次）→ group 计数提前归零 → group_wait 早返回、
    // reader 尚在读（status=Reading）被误判失败。修正：仅当 copy 返回 nil（读尽）时
    // markAsFinished 并 leave 一次；block 再次回调时 finished 短路。
    dispatch_group_t group = dispatch_group_create();
    for (NSUInteger i = 0; i < wIns.count; i++) {
        AVAssetWriterInput *wi = wIns[i];
        AVAssetReaderOutput *ro = rOuts[i];
        if (!wi || !ro) continue;
        dispatch_group_enter(group);
        __block BOOL finished = NO;
        [wi requestMediaDataWhenReadyOnQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
                                  usingBlock:^{
            if (finished) return;
            while ([wi isReadyForMoreMediaData]) {
                CMSampleBufferRef sbuf = [ro copyNextSampleBuffer];
                if (sbuf) {
                    [wi appendSampleBuffer:sbuf];
                    CFRelease(sbuf);
                } else {
                    finished = YES;
                    [wi markAsFinished];
                    break;
                }
            }
            if (finished) dispatch_group_leave(group);
        }];
    }
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC));
    // group 收敛后 reader 状态切换可能仍有瞬态：短轮询收口
    for (int w = 0; w < 100 && reader.status == AVAssetReaderStatusReading; w++) {
        usleep(50000);
    }

    if (reader.status != AVAssetReaderStatusCompleted) {
        [writer cancelWriting];
        [fm removeItemAtPath:inPath error:nil];
        if ([fm fileExistsAtPath:outPath]) [fm removeItemAtPath:outPath error:nil];
        if (error) *error = tmgError(18, [NSString stringWithFormat:@"视频轨拷贝失败 (reader=%@)",
                                          @(reader.status)]);
        return nil;
    }
    __block NSError *fErr = nil;
    dispatch_semaphore_t fsema = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        fErr = writer.error;
        dispatch_semaphore_signal(fsema);
    }];
    dispatch_semaphore_wait(fsema, dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC));
    [fm removeItemAtPath:inPath error:nil];
    if (writer.status != AVAssetWriterStatusCompleted || fErr) {
        if ([fm fileExistsAtPath:outPath]) [fm removeItemAtPath:outPath error:nil];
        if (error) *error = tmgError(19, [NSString stringWithFormat:@"视频导出失败: %@",
                                          fErr.localizedDescription ?: @""]);
        return nil;
    }
    NSData *out = [NSData dataWithContentsOfFile:outPath];
    [fm removeItemAtPath:outPath error:nil];
    if (!out || !out.length) {
        if (error) *error = tmgError(20, @"视频输出读取失败");
        return nil;
    }
    return out;
}

@end