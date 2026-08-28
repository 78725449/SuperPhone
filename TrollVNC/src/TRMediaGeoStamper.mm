/*
  TRMediaGeoStamper - 相册媒体 GPS 包装器（实现，2026-08-28）
  图片：ImageIO 透传重写 EXIF GPS（无损，JPEG/HEIC 主战场；PNG 走系统 eXIf 尽力）
  视频：AVAssetExportSession(presetPassthrough) 内部 remux + session.metadata 写 ISO6709——
        2026-08-28 由 AVAssetReader/Writer 逐轨循环拷贝重写（用户评审：低效且三次真机坑；
        弃用手工拷贝，标准导出管道，不重编码、高效、无 sample 级循环）。
*/
#import "TRMediaGeoStamper.h"
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

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
    if (outUTI) *outUTI = uti;

    NSDictionary *rawProps = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(srcRef, 0, NULL);
    NSMutableDictionary *props = [NSMutableDictionary dictionary];
    if (rawProps) [props addEntriesFromDictionary:rawProps];

    [props removeObjectForKey:(__bridge NSString *)kCGImagePropertyGPSDictionary];

    if (mode == TRMediaGpsModeWrite) {
        if (lat < -90.0 || lat > 90.0 || lon < -180.0 || lon > 180.0) {
            CFRelease(srcRef);
            if (error) *error = tmgError(4, @"坐标越界（lat±90 / lon±180）");
            return nil;
        }
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
        NSMutableDictionary *exif = [props[(__bridge NSString *)kCGImagePropertyExifDictionary] mutableCopy];
        if (exif && exif.count) {
            NSArray *gpsKeys = @[@"GPSLatitude", @"GPSLatitudeRef", @"GPSLongitude",
                                 @"GPSLongitudeRef", @"GPSAltitude", @"GPSAltitudeRef",
                                 @"GPSTimeStamp", @"GPSDateStamp", @"GPSHPositioningError"];
            for (NSString *k in gpsKeys) [exif removeObjectForKey:k];
            props[(__bridge NSString *)kCGImagePropertyExifDictionary] = exif;
        }
    } else if (mode == TRMediaGpsModeClear) {
        NSMutableDictionary *exif = [props[(__bridge NSString *)kCGImagePropertyExifDictionary] mutableCopy];
        if (exif && exif.count) {
            NSArray *gpsKeys = @[@"GPSLatitude", @"GPSLatitudeRef", @"GPSLongitude",
                                 @"GPSLongitudeRef", @"GPSAltitude", @"GPSAltitudeRef",
                                 @"GPSTimeStamp", @"GPSDateStamp", @"GPSHPositioningError"];
            for (NSString *k in gpsKeys) [exif removeObjectForKey:k];
            props[(__bridge NSString *)kCGImagePropertyExifDictionary] = exif;
        }
    }

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

#pragma mark - 视频（AVAssetExportSession passthrough + session.metadata）

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

    NSString *inPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"gps_stamp_in_%ld.mp4", (long)[NSDate date].timeIntervalSince1970]];
    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"gps_stamp_out_%ld.mp4", (long)[NSDate date].timeIntervalSince1970]];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![src writeToFile:inPath atomically:YES]) {
        if (error) *error = tmgError(14, @"视频临时文件写入失败"); return nil;
    }
    if ([fm fileExistsAtPath:outPath]) [fm removeItemAtPath:outPath error:nil];

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:inPath] options:nil];
    // 14.5 SDK 旧名：exportSessionWithAsset:presetName:
    AVAssetExportSession *session = [AVAssetExportSession exportSessionWithAsset:asset
                                                                     presetName:AVAssetExportPresetPassthrough];
    if (!session) {
        [fm removeItemAtPath:inPath error:nil];
        if (error) *error = tmgError(15, @"导出会话创建失败（passthrough 需可复用容器）");
        return nil;
    }
    session.outputURL = [NSURL fileURLWithPath:outPath];
    // passthrough 要求输出容器与源兼容：ftyp 嗅探（isom/mp42→MPEG4；qt  →QuickTimeMovie）
    NSString *fileType = AVFileTypeMPEG4;
    if (src.length >= 12) {
        const char *b = (const char *)src.bytes;
        if (b[4] == 'f' && b[5] == 't' && b[6] == 'y' && b[7] == 'p') {
            if (b[8] == 'q' && b[9] == 't' && b[10] == ' ') fileType = AVFileTypeQuickTimeMovie;
        }
    }
    session.outputFileType = fileType;
    if (mode == TRMediaGpsModeWrite) {
        NSString *iso = [NSString stringWithFormat:@"%+.7f%+.7f/", lat, lon];
        AVMutableMetadataItem *loc = [[AVMutableMetadataItem alloc] init];
        loc.key = AVMetadataIdentifierQuickTimeMetadataLocationISO6709;
        loc.keySpace = AVMetadataKeySpaceQuickTimeMetadata;
        loc.value = iso;
        session.metadata = @[loc];
    } else {
        // Clear：不向输出写任何 location；sharing filter 拒绝可识别个人位置的源 metadata
        session.metadataItemFilter = [AVMetadataItemFilter metadataItemFilterForSharing];
    }

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [session exportAsynchronouslyWithCompletionHandler:^{
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 240 * NSEC_PER_SEC));

    [fm removeItemAtPath:inPath error:nil];
    if (session.status != AVAssetExportSessionStatusCompleted) {
        if ([fm fileExistsAtPath:outPath]) [fm removeItemAtPath:outPath error:nil];
        if (error) *error = tmgError(16, [NSString stringWithFormat:@"视频导出失败（status=%ld）",
                                          (long)session.status]);
        return nil;
    }
    NSData *out = [NSData dataWithContentsOfFile:outPath];
    [fm removeItemAtPath:outPath error:nil];
    if (!out || !out.length) {
        if (error) *error = tmgError(17, @"视频输出读取失败");
        return nil;
    }
    return out;
}

@end