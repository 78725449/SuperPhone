/*
  TRMediaGeoStamper - 相册媒体 GPS 包装器（2026-08-28 风控对齐 · album.import）
  背景：抖音 TMMediaGPSReadingCache 会读取相册照片/视频的 EXIF GPS（逆向报告 §4 实证）——
        上传到设备的媒体若带真实位置/异地 EXIF，会与当前模拟定位冲突（穿帮）。
  职责：上传落库前把媒体 GPS 改写为当前模拟定位（或显式坐标 / 清除），使相册里
        的照片/视频"生于"所模拟的位置。

  - 图片（JPEG/HEIC/PNG）：ImageIO CGImageSource→CGImageDestination 透传原编码无损重写
    kCGImagePropertyGPSDictionary（JPEG/HEIC 为真实透传；PNG 走系统 eXIf 支持，能力所限可能失败）
  - 视频（MOV/MP4）：AVAssetReader/AVAssetWriter 逐轨直拷（不重编码、画质无损）+
    AVAssetWriterInputMetadataAdaptor 写 com.apple.quicktime.location.ISO6709 GPS 元数据

  线程：调用方线程（album.import 的 5802 后台队列），内部同步执行。
  归零原则：写入失败必须向上返回错误，不得静默"包装失败但假装成功"。
*/
#ifndef TRMediaGeoStamper_h
#define TRMediaGeoStamper_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** GPS 写入模式 */
typedef NS_ENUM(NSInteger, TRMediaGpsMode) {
    TRMediaGpsModeKeep   = 0,  ///< 保留原媒体 GPS（显式 keep）
    TRMediaGpsModeWrite  = 1,  ///< 写入坐标（模拟定位 / 显式 lat/lon）
    TRMediaGpsModeClear  = 2,  ///< 清除 GPS（无模拟时的默认防线：宁无位置不露真实）
};

@interface TRMediaGeoStamper : NSObject

/**
 * 改写图片元数据 GPS（原编码透传，无损）。
 * @param src    原始图片数据（PNG/JPEG/HEIC）
 * @param mode   Write=写坐标 / Clear=清 GPS；Keep 应直接跳过本方法
 * @param lat    纬度（-90~90），mode=Write 时有效
 * @param lon    经度（-180~180）
 * @param outUTI 输出图片的 UTI（jpg/heic/png），可为 NULL
 * @return 改写后的图片数据；失败返回 nil 并置 error（绝不静默）
 */
+ (nullable NSData *)stampImageData:(NSData *)src
                                uti:(CFStringRef * _Nullable)outUTI
                               mode:(TRMediaGpsMode)mode
                                lat:(double)lat
                                lon:(double)lon
                              error:(NSError **)error;

/**
 * 改写视频元数据 GPS（AVAssetReader/Writer 逐轨直拷，不重编码）。
 * @param src    原始视频数据（MP4/MOV）
 * @param mode   Write=写坐标 / Clear=清 GPS（Clear 对视频=移除 location 元数据）
 * @return 改写后的视频数据；失败返回 nil 并置 error
 */
+ (nullable NSData *)stampVideoData:(NSData *)src
                               mode:(TRMediaGpsMode)mode
                                lat:(double)lat
                                lon:(double)lon
                              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
#endif /* TRMediaGeoStamper_h */