/*
  TRVisionEngine - Vision 框架 OCR 引擎（2026-08-28 风控对抗扩展 · vision.*）
  功能：基于 iOS 系统 Vision framework（VNRecognizeTextRequest）的离线中文 OCR 原语，
        为上层脚本/导演提供"传文字→回坐标"的机械匹配原语（语义判断不在手机端）。
  设计基线（用户定稿）：
    - VNRecognizeTextRequest .accurate 级、语言 ["zh-Hans","en-US"]、usesLanguageCorrection=NO
      （系统纠错会改写 UI 文案导致匹配失败，必须关闭）
    - 输入复用 ScreenCapturer.captureSingleFrameBuffer（与 screen.hash 同源取帧，不另开抓屏路径）
    - 坐标契约：VN bbox 左下原点 → 转换为 touch.* 一致的 0-1 归一化左上原点
      （y01 = 1 - bbox.midY）；App 锁定竖屏不做横屏适配
    - 串行队列防并发 OCR 争内存（.accurate 全屏约 0.5~2s）
  架构位置：trollvncserver 进程内（帧源所在进程），经 0x50/5802 暴露，注册表 LocalCmd 桥接
*/
#ifndef TRVisionEngine_h
#define TRVisionEngine_h

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** OCR 结果行数上限（防 0x50/5802 响应超 1MB 帧上限） */
static const NSInteger TRVisionMaxTextRows = 200;

#pragma mark - 模板匹配常量（vision.find_image，2026-08-28）

/** 匹配分值低于该值的候选丢弃（用户定稿 0.7） */
static const double TRVisionDefaultMatchThreshold = 0.7;

/** 模板 base64 输入上限（0x50/5802 请求帧 1MB 内的安全余量） */
static const NSInteger TRVisionMaxTemplateB64Bytes = 256 * 1024;

/** 精匹配搜索边距（全分辨率像素；粗定位 ±48px 窗内精匹配） */
static const NSInteger TRVisionRefineMarginPx = 48;

/**
 * TRVisionEngine - Vision OCR 核心（单例，串行）
 * 线程安全：内部串行队列串行化 OCR 与帧访问。
 * 生命周期：单例，随 trollvncserver 进程。
 */
@interface TRVisionEngine : NSObject

+ (instancetype)sharedEngine;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

/**
 * 对当前屏幕帧执行中文 OCR。
 * @param region    0-1 归一化 {x,y,w,h} 过滤区（bbox 中心落在区内才返回）；nil/非法=全屏
 * @param frameSize 输出：实际帧像素尺寸（供调用方注记 width/height）
 * @param durationMs 输出：OCR 耗时毫秒
 * @return 结果行数组 [{text,x,y,w,h,cx,cy,confidence}]（0-1 归一化、左上原点、cx/cy=中心）；
 *         失败返回 nil 并设置 error（取帧失败/Vision 不可用/识别失败）
 */
- (nullable NSArray<NSDictionary *> *)recognizeScreenTextWithRegion:(nullable NSDictionary *)region
                                                         frameSize:(CGSize *)frameSize
                                                        durationMs:(NSTimeInterval *)durationMs
                                                             error:(NSError **)error;

#pragma mark - 模板匹配（vision.find_image，2026-08-28）

/**
 * 锚点图匹配：接收一张 base64 小图（云端视觉代理截取的锚点），在当前屏幕上找其位置。
 * 管线（用户定稿，系统框架自实现、不加 OpenCV）：
 *   灰度化（Rec.601）→ 1/8 金字塔降采样（模板同步）→ 模板翻转（vDSP 卷积方向）
 *   → vDSP_conv 相关图 → NCCC 归一化（SAT 局部均值/方差，抗亮度变化）→ vDSP_maxvi 找峰
 *   → 粗定位 ±48px ROI 原尺寸精匹配 → 阈值过滤（默认 0.7），找不到返回 found:NO。
 * @param base64       锚点图（PNG/JPEG，≤256KB base64）
 * @param threshold    归一化相关分值阈值；<=0 用默认 0.7
 * @param region       0-1 归一化 {x,y,w,h} 搜索区（可选）
 * @param scale        模板相对本机原生分辨率的缩放比例（云端缩略图 0.5x → 传 0.5，设备端自适应放大模板）；
 *                     [0.25, 4]，<=0/>4 时按 1.0 处理（**多尺度归一，2026-08-28 优化**：不做多档穷举，单次自适应缩放）
 * @return {found, x, y, w, h, score, width, height, durationMs}
 *         （x/y=匹配中心 0-1，w/h=匹配矩形 0-1，width/height=本次匹配的屏幕帧像素尺寸——编排层可据以跨 op 校验帧一致性）；
 *         失败返回 nil+error
 */
- (nullable NSDictionary *)findImageWithTemplateBase64:(NSString *)base64
                                             threshold:(double)threshold
                                                region:(nullable NSDictionary *)region
                                                 scale:(double)scale
                                                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif /* TRVisionEngine_h */
