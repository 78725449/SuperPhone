/*
  TRVisionEngine - Vision 框架 OCR 引擎实现（2026-08-28）
  管线：取帧（ScreenCapturer.captureSingleFrameBuffer，全屏 ARGB）→ VNImageRequestHandler
        → VNRecognizeTextRequest(.accurate, zh-Hans+en-US) → bbox 左下原点 → 0-1 左上原点换算。
  边界：iOS <14 无 zh-Hans 支持返回明确错误；region 过滤按 bbox 中心判定。
*/

#if !__has_feature(objc_arc)
#error This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import <Vision/Vision.h>

#import "Logging.h"
#import "ScreenCapturer.h"
#import "TRVisionEngine.h"

#pragma mark - 模板匹配辅助（vision.find_image，2026-08-28）

#import <Accelerate/Accelerate.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>

/** ARGB/BGRA 像素缓冲 → Rec.601 灰度平面（malloc，调用方 free） */
static uint8_t *trvGrayFromPixelBuffer(CVPixelBufferRef pb, int *outW, int *outH) {
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    int w = (int)CVPixelBufferGetWidth(pb);
    int h = (int)CVPixelBufferGetHeight(pb);
    size_t rb = CVPixelBufferGetBytesPerRow(pb);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    int offR = 1, offG = 2, offB = 3;
    if (fmt == kCVPixelFormatType32ARGB) { offR = 1; offG = 2; offB = 3; }
    else if (fmt == kCVPixelFormatType32BGRA) { offR = 2; offG = 1; offB = 0; }
    else { CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly); return NULL; }
    uint8_t *gray = (uint8_t *)malloc((size_t)w * h);
    if (!gray) { CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly); return NULL; }
    for (int y = 0; y < h; y++) {
        const uint8_t *src = base + (size_t)y * rb;
        uint8_t *dst = gray + (size_t)y * w;
        for (int x = 0; x < w; x++) {
            dst[x] = (uint8_t)((src[offR] * 299 + src[offG] * 587 + src[offB] * 114) / 1000);
            src += 4;
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    *outW = w; *outH = h;
    return gray;
}

/** base64（PNG/JPEG）→ 灰度平面（RGBA 中转解码；malloc，调用方 free） */
static uint8_t *trvGrayFromBase64(NSString *b64, int *outW, int *outH, NSString **outErr) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (!data || !data.length) { if (outErr) *outErr = @"image 不是有效 base64"; return NULL; }
    UIImage *img = [UIImage imageWithData:data];
    CGImageRef cg = img.CGImage;
    if (!cg) { if (outErr) *outErr = @"image 解码失败（须 PNG/JPEG）"; return NULL; }
    int w = (int)CGImageGetWidth(cg);
    int h = (int)CGImageGetHeight(cg);
    if (w < 8 || h < 8 || w > 2048 || h > 2048) {
        if (outErr) *outErr = @"image 尺寸越界（8~2048px）";
        return NULL;
    }
    uint8_t *rgba = (uint8_t *)malloc((size_t)w * h * 4);
    if (!rgba) { if (outErr) *outErr = @"内存不足"; return NULL; }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgba, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(rgba); if (outErr) *outErr = @"位图上下文创建失败"; return NULL; }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    uint8_t *gray = (uint8_t *)malloc((size_t)w * h);
    if (!gray) { free(rgba); if (outErr) *outErr = @"内存不足"; return NULL; }
    for (size_t i = 0; i < (size_t)w * h; i++)
        gray[i] = (uint8_t)((rgba[i*4] * 299 + rgba[i*4+1] * 587 + rgba[i*4+2] * 114) / 1000);
    free(rgba);
    *outW = w; *outH = h;
    return gray;
}

@implementation TRVisionEngine {
    dispatch_queue_t _queue;   // 串行：防并发 OCR 争内存/ANF
}

/** 双线性灰度缩放（多尺度归一，2026-08-28；malloc，调用方 free；边缘钳制） */
static uint8_t *trvRescaleGray(const uint8_t *src, int sw, int sh, int dw, int dh) {
    if (dw < 1 || dh < 1) return NULL;
    uint8_t *dst = (uint8_t *)malloc(sizeof(uint8_t) * (size_t)dw * dh);
    if (!dst) return NULL;
    double sx = (double)sw / dw;
    double sy = (double)sh / dh;
    for (int y = 0; y < dh; y++) {
        double fy = (y + 0.5) * sy - 0.5;
        int y0 = (int)floor(fy), y1 = y0 + 1;
        double wy1 = fy - y0;
        if (y0 < 0) { y0 = 0; wy1 = 0.0; }
        if (y1 > sh - 1) y1 = sh - 1;
        const uint8_t *r0 = src + (size_t)y0 * sw;
        const uint8_t *r1 = src + (size_t)y1 * sw;
        uint8_t *out = dst + (size_t)y * dw;
        for (int x = 0; x < dw; x++) {
            double fx = (x + 0.5) * sx - 0.5;
            int x0 = (int)floor(fx), x1 = x0 + 1;
            double wx1 = fx - x0;
            if (x0 < 0) { x0 = 0; wx1 = 0.0; }
            if (x1 > sw - 1) x1 = sw - 1;
            double v = r0[x0] * (1 - wx1) * (1 - wy1) + r0[x1] * wx1 * (1 - wy1)
                     + r1[x0] * (1 - wx1) * wy1 + r1[x1] * wx1 * wy1;
            out[x] = (uint8_t)(v + 0.5);
        }
    }
    return dst;
}

/** 8×8 盒均值降采样（floor 对齐；malloc double，调用方 free） */
static double *trvDownsample8(const uint8_t *gray, int w, int h, int *outW, int *outH) {
    int dw = w / 8, dh = h / 8;
    if (dw < 1 || dh < 1) return NULL;
    double *out = (double *)malloc(sizeof(double) * (size_t)dw * dh);
    if (!out) return NULL;
    for (int y = 0; y < dh; y++) {
        for (int x = 0; x < dw; x++) {
            int sum = 0;
            for (int j = 0; j < 8; j++) {
                const uint8_t *row = gray + (size_t)(y * 8 + j) * w + x * 8;
                for (int i = 0; i < 8; i++) sum += row[i];
            }
            out[(size_t)y * dw + x] = (double)sum / 64.0;
        }
    }
    *outW = dw; *outH = dh;
    return out;
}

/** 行积分和 SAT（尺寸 (w+1)*(h+1)，calloc；squared=1 建平方和表） */
static double *trvBuildSAT(const double *img, int w, int h, int squared) {
    double *sat = (double *)calloc(sizeof(double), (size_t)(w + 1) * (h + 1));
    if (!sat) return NULL;
    for (int y = 0; y < h; y++) {
        double run = 0.0;
        for (int x = 0; x < w; x++) {
            double v = img[(size_t)y * w + x];
            if (squared) v *= v;
            run += v;
            sat[(size_t)(y + 1) * (w + 1) + (x + 1)] = sat[(size_t)y * (w + 1) + (x + 1)] + run;
        }
    }
    return sat;
}

/** SAT 窗口和：(x,y,w,h) */
static double trvSATSum(const double *sat, int satW, int x, int y, int ww, int hh) {
    return sat[(size_t)(y + hh) * satW + (x + ww)] - sat[(size_t)y * satW + (x + ww)]
         - sat[(size_t)(y + hh) * satW + x] + sat[(size_t)y * satW + x];
}

/** 2D 相关：模板须 180° 翻转传入（vDSP_convD 方向要求）；逐模板行 convD + vaddD 累加 */
static double *trvCorrelate2D(const double *img, int iw,
                              const double *tplFlipped, int tw, int th,
                              int outW, int outH) {
    double *out = (double *)calloc(sizeof(double), (size_t)outW * outH);
    double *acc = (double *)malloc(sizeof(double) * (size_t)outW);
    double *part = (double *)malloc(sizeof(double) * (size_t)outW);
    if (!out || !acc || !part) { free(out); free(acc); free(part); return NULL; }
    for (int v = 0; v < outH; v++) {
        for (int j = 0; j < th; j++) {
            const double *row = img + (size_t)(v + j) * iw;
            const double *frow = tplFlipped + (size_t)(th - 1 - j) * tw;
            vDSP_convD(row, 1, frow, 1, part, 1, (vDSP_Length)iw, (vDSP_Length)tw);
            if (j == 0) memcpy(acc, part, sizeof(double) * (size_t)outW);
            else vDSP_vaddD(acc, 1, part, 1, acc, 1, (vDSP_Length)outW);
        }
        memcpy(out + (size_t)v * outW, acc, sizeof(double) * (size_t)outW);
    }
    free(acc); free(part);
    return out;
}

/** 单候选 NCCC：分母 = n·σS·σT；方差过小返回 -1 */
static double trvNCCScore(double corr, const double *satSum, const double *satSq, int satW,
                          int u, int v, int tw, int th, double tSum, double tSqSum) {
    double n = (double)tw * th;
    double sSum = trvSATSum(satSum, satW, u, v, tw, th);
    double sSq = trvSATSum(satSq, satW, u, v, tw, th);
    double sMean = sSum / n;
    double sVar = sSq - sSum * sMean;
    double tMean = tSum / n;
    double tVar = tSqSum - tSum * tMean;
    if (sVar < 1e-6 || tVar < 1e-6) return -1.0;
    return (corr - tMean * sSum) / (sqrt(sVar) * sqrt(tVar));
}

#pragma mark - 单例

+ (instancetype)sharedEngine {
    static TRVisionEngine *_inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _inst = [[TRVisionEngine alloc] init];
    });
    return _inst;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _queue = dispatch_queue_create("com.trollvnc.visionEngine", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (nullable NSArray<NSDictionary *> *)recognizeScreenTextWithRegion:(nullable NSDictionary *)region
                                                         frameSize:(CGSize *)frameSize
                                                        durationMs:(NSTimeInterval *)durationMs
                                                             error:(NSError **)error {
    __block NSArray<NSDictionary *> *rows = nil;
    __block NSError *innerError = nil;
    dispatch_sync(_queue, ^{
        rows = [self _recognizeUnsafeWithRegion:region frameSize:frameSize durationMs:durationMs error:&innerError];
    });
    if (!rows && error) *error = innerError;
    return rows;
}

- (nullable NSArray<NSDictionary *> *)_recognizeUnsafeWithRegion:(nullable NSDictionary *)region
                                                       frameSize:(CGSize *)frameSize
                                                      durationMs:(NSTimeInterval *)durationMs
                                                           error:(NSError **)error {
    if (@available(iOS 14.0, *)) {
        // ===== 取帧（与 screen.hash 同源：全屏 ARGB CVPixelBuffer，按需渲染 ~20ms）=====
        CVPixelBufferRef pixelBuffer = [[ScreenCapturer sharedCapturer] captureSingleFrameBuffer];
        if (!pixelBuffer) {
            if (error) *error = [NSError errorWithDomain:@"TRVision" code:1
                                userInfo:@{NSLocalizedDescriptionKey:@"取帧失败（屏幕渲染不可用）"}];
            return nil;
        }

        CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
        CGSize frame = CGSizeMake(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer));
        if (frameSize) *frameSize = frame;

        // ===== Vision OCR（performRequests 同步执行，完成后才继续）=====
        VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:nil];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.recognitionLanguages = @[@"zh-Hans", @"en-US"];
        request.usesLanguageCorrection = NO;   // 系统纠错会改写 UI 文案导致匹配失败，必须关闭

        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBuffer options:@{}];
        NSError *reqError = nil;
        BOOL ok = [handler performRequests:@[request] error:&reqError];
        CVPixelBufferRelease(pixelBuffer);
        if (!ok) {
            if (error) *error = [NSError errorWithDomain:@"TRVision" code:2
                                userInfo:@{NSLocalizedDescriptionKey:
                                           [NSString stringWithFormat:@"OCR 失败: %@",
                                            reqError.localizedDescription ?: @"performRequests 错误"]}];
            return nil;
        }
        if (durationMs) *durationMs = (CFAbsoluteTimeGetCurrent() - started) * 1000.0;

        // ===== region 归一化 {x,y,w,h}（bbox 中心过滤，坐标仍为全屏绝对 0-1）=====
        CGRect filter = CGRectNull;
        if ([region isKindOfClass:[NSDictionary class]]) {
            NSNumber *rx = region[@"x"], *ry = region[@"y"], *rw = region[@"w"], *rh = region[@"h"];
            if ([rx isKindOfClass:[NSNumber class]] && [ry isKindOfClass:[NSNumber class]] &&
                [rw isKindOfClass:[NSNumber class]] && [rh isKindOfClass:[NSNumber class]]) {
                filter = CGRectMake(rx.doubleValue, ry.doubleValue, rw.doubleValue, rh.doubleValue);
            }
        }

        // ===== bbox 换算：VN 左下原点归一化 → 左上原点归一化（y01 = 1 - midY）=====
        NSArray<VNRecognizedTextObservation *> *observations =
            [request.results filteredArrayUsingPredicate:
             [NSPredicate predicateWithBlock:^BOOL(id obj, NSDictionary *_) {
                 return [obj isKindOfClass:[VNRecognizedTextObservation class]];
             }]];
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray arrayWithCapacity:observations.count];
        for (VNRecognizedTextObservation *obs in observations) {
            if (rows.count >= TRVisionMaxTextRows) break;   // 帧上限（响应 ≤1MB 守卫）
            VNRecognizedText *candidate = [obs topCandidates:1].firstObject;
            if (!candidate) continue;
            CGRect bb = obs.boundingBox;   // 归一化、左下原点
            double x01 = bb.origin.x;
            double y01 = 1.0 - bb.origin.y - bb.size.height;   // 顶边
            double w01 = bb.size.width, h01 = bb.size.height;
            double cx01 = x01 + w01 / 2.0, cy01 = 1.0 - CGRectGetMidY(bb);
            if (!CGRectIsNull(filter)) {
                if (cx01 < CGRectGetMinX(filter) || cx01 > CGRectGetMaxX(filter) ||
                    cy01 < CGRectGetMinY(filter) || cy01 > CGRectGetMaxY(filter)) continue;
            }
            [rows addObject:@{
                @"text": candidate.string ?: @"",
                @"x": @(x01), @"y": @(y01), @"w": @(w01), @"h": @(h01),
                @"cx": @(cx01), @"cy": @(cy01),
                @"confidence": @(obs.confidence)
            }];
        }
        return rows;
    }

    if (error) *error = [NSError errorWithDomain:@"TRVision" code:3
                        userInfo:@{NSLocalizedDescriptionKey:@"需要 iOS 14+（zh-Hans 识别）"}];
    return nil;
}

- (nullable NSDictionary *)findImageWithTemplateBase64:(NSString *)base64
                                             threshold:(double)threshold
                                                region:(nullable NSDictionary *)region
                                                 scale:(double)scale
                                                 error:(NSError **)error {
    __block NSDictionary *result = nil;
    dispatch_sync(_queue, ^{
        result = [self _findImageUnsafeWithBase64:base64 threshold:threshold region:region scale:scale error:error];
    });
    return result;
}

- (nullable NSDictionary *)_findImageUnsafeWithBase64:(NSString *)base64
                                            threshold:(double)threshold
                                               region:(nullable NSDictionary *)region
                                                scale:(double)scale
                                                 error:(NSError **)error {
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    if (base64.length > TRVisionMaxTemplateB64Bytes) {
        if (error) *error = [NSError errorWithDomain:@"TRVision" code:11
                            userInfo:@{NSLocalizedDescriptionKey:@"模板过大（>256KB base64）"}];
        return nil;
    }
    if (threshold <= 0.0 || threshold > 1.0) threshold = TRVisionDefaultMatchThreshold;
    // 多尺度归一（2026-08-28 优化）：scale=模板相对本机原生分辨率比例（云端缩略图 0.5x → 0.5，放大约 2×）；非法值按 1.0
    if (scale <= 0.0 || scale > 4.0) scale = 1.0;

    int tw = 0, th = 0, W = 0, H = 0, dw = 0, dh = 0, tw8 = 0, th8 = 0;
    NSString *tErr = nil;
    uint8_t *tgray = NULL, *sgray = NULL;
    double *ds = NULL, *dt = NULL, *tflip8 = NULL, *tflipFull = NULL;
    double *satS = NULL, *satSq = NULL, *corr8 = NULL;
    double *win = NULL, *satWS = NULL, *satWSq = NULL, *corrW = NULL;
    // C++ 规则：goto 不得跨越带初始化的作用域声明——全部上移到函数头
    double tSum8 = 0, tSq8 = 0, tSumF = 0, tSqF = 0;
    int cOutW = 0, cOutH = 0;
    NSDictionary *outDict = nil;

    tgray = trvGrayFromBase64(base64, &tw, &th, &tErr);
    if (!tgray) {
        if (error) *error = [NSError errorWithDomain:@"TRVision" code:11
                            userInfo:@{NSLocalizedDescriptionKey:tErr ?: @"模板解码失败"}];
        return nil;
    }

    // 多尺度归一：按 scale 单次自适应缩放模板（目标原生尺寸 = 模板像素 / scale；边缘钳制、双线性）
    if (scale != 1.0) {
        int nw = MAX(8, (int)lround(tw / scale));
        int nh = MAX(8, (int)lround(th / scale));
        if (nw > 4096 || nh > 4096) {
            free(tgray);
            if (error) *error = [NSError errorWithDomain:@"TRVision" code:14
                                userInfo:@{NSLocalizedDescriptionKey:@"模板经 scale 缩放后超出 4096px 上限"}];
            return nil;
        }
        uint8_t *re = trvRescaleGray(tgray, tw, th, nw, nh);
        free(tgray);
        tgray = re;
        tw = nw;
        th = nh;
        if (!tgray) {
            if (error) *error = [NSError errorWithDomain:@"TRVision" code:15
                                userInfo:@{NSLocalizedDescriptionKey:@"模板缩放内存不足"}];
            return nil;
        }
    }

    CVPixelBufferRef pb = [[ScreenCapturer sharedCapturer] captureSingleFrameBuffer];
    if (!pb) {
        free(tgray);
        if (error) *error = [NSError errorWithDomain:@"TRVision" code:1
                            userInfo:@{NSLocalizedDescriptionKey:@"取帧失败（屏幕渲染不可用）"}];
        return nil;
    }
    sgray = trvGrayFromPixelBuffer(pb, &W, &H);
    CVPixelBufferRelease(pb);
    if (!sgray) {
        free(tgray);
        if (error) *error = [NSError errorWithDomain:@"TRVision" code:2
                            userInfo:@{NSLocalizedDescriptionKey:@"灰度化失败"}];
        return nil;
    }

    if (tw > W || th > H || tw < 32 || th < 32) {
        free(tgray); free(sgray);
        if (error) *error = [NSError errorWithDomain:@"TRVision" code:12
                            userInfo:@{NSLocalizedDescriptionKey:@"模板尺寸不合法（≥32px 且不大于屏幕）"}];
        return nil;
    }

    // ===== 1/8 金字塔（模板同步降采样）=====
    ds = trvDownsample8(sgray, W, H, &dw, &dh);
    dt = trvDownsample8(tgray, tw, th, &tw8, &th8);
    if (!ds || !dt || tw8 < 4 || th8 < 4) {
        free(tgray); free(sgray); free(ds); free(dt);
        if (error) *error = [NSError errorWithDomain:@"TRVision" code:13
                            userInfo:@{NSLocalizedDescriptionKey:@"模板过小（降采样后 <4px）"}];
        return nil;
    }

    // ===== 模板 180° 翻转（vDSP_conv 方向要求）+ 统计 =====
    tflip8 = (double *)malloc(sizeof(double) * (size_t)tw8 * th8);
    tflipFull = (double *)malloc(sizeof(double) * (size_t)tw * th);
    if (!tflip8 || !tflipFull) goto cleanup;
    for (int y = 0; y < th8; y++)
        for (int x = 0; x < tw8; x++)
            tflip8[(size_t)y * tw8 + x] = dt[(size_t)(th8 - 1 - y) * tw8 + (tw8 - 1 - x)];
    for (int y = 0; y < th; y++)
        for (int x = 0; x < tw; x++)
            tflipFull[(size_t)y * tw + x] = (double)tgray[(size_t)(th - 1 - y) * tw + (tw - 1 - x)];
    for (size_t i = 0; i < (size_t)tw8 * th8; i++) { tSum8 += dt[i]; tSq8 += dt[i] * dt[i]; }
    for (size_t i = 0; i < (size_t)tw * th; i++) { tSumF += tflipFull[i]; tSqF += tflipFull[i] * tflipFull[i]; }

    // ===== 粗匹配（1/8 尺度）：SAT + 相关图 + NCCC 找峰 =====
    satS = trvBuildSAT(ds, dw, dh, 0);
    satSq = trvBuildSAT(ds, dw, dh, 1);
    if (!satS || !satSq) goto cleanup;
    cOutW = dw - tw8 + 1;
    cOutH = dh - th8 + 1;
    corr8 = trvCorrelate2D(ds, dw, tflip8, tw8, th8, cOutW, cOutH);
    if (!corr8) goto cleanup;

    {
        int uMin = 0, vMin = 0, uMax = cOutW - 1, vMax = cOutH - 1;
        if ([region isKindOfClass:[NSDictionary class]]) {
            NSNumber *rx = region[@"x"], *ry = region[@"y"], *rw = region[@"w"], *rh = region[@"h"];
            if ([rx isKindOfClass:[NSNumber class]] && [ry isKindOfClass:[NSNumber class]] &&
                [rw isKindOfClass:[NSNumber class]] && [rh isKindOfClass:[NSNumber class]]) {
                uMin = MAX(uMin, (int)floor(rx.doubleValue * W / 8.0));
                vMin = MAX(vMin, (int)floor(ry.doubleValue * H / 8.0));
                uMax = MIN(uMax, (int)ceil((rx.doubleValue + rw.doubleValue) * W / 8.0) - tw8);
                vMax = MIN(vMax, (int)ceil((ry.doubleValue + rh.doubleValue) * H / 8.0) - th8);
            }
        }
        if (uMin > uMax || vMin > vMax) {
            outDict = @{@"ok": @YES, @"found": @NO, @"score": @(-1.0),
                        @"width": @(W), @"height": @(H),   // 轻量帧校验：编排层可跨 op 比对帧尺寸察觉滚动/旋转后帧变化
                        @"durationMs": @((int)round((CFAbsoluteTimeGetCurrent() - started) * 1000.0))};
            goto cleanup;
        }
        double best = -2.0; int bu = uMin, bv = vMin;
        for (int v = vMin; v <= vMax; v++)
            for (int u = uMin; u <= uMax; u++) {
                double s = trvNCCScore(corr8[(size_t)v * cOutW + u], satS, satSq, dw + 1,
                                       u, v, tw8, th8, tSum8, tSq8);
                if (s > best) { best = s; bu = u; bv = v; }
            }

        // ===== 精匹配（原尺寸，粗定位 ±48px ROI）=====
        int margin = TRVisionRefineMarginPx;
        int ww = MIN(W, tw + 2 * margin);
        int wh = MIN(H, th + 2 * margin);
        int cx0 = (int)((bu + tw8 / 2.0) * 8.0) - tw / 2;
        int cy0 = (int)((bv + th8 / 2.0) * 8.0) - th / 2;
        int wx = MAX(0, MIN(W - ww, cx0 - margin));
        int wy = MAX(0, MIN(H - wh, cy0 - margin));
        win = (double *)malloc(sizeof(double) * (size_t)ww * wh);
        if (!win) goto cleanup;
        for (int y = 0; y < wh; y++)
            for (int x = 0; x < ww; x++)
                win[(size_t)y * ww + x] = (double)sgray[(size_t)(wy + y) * W + (wx + x)];
        satWS = trvBuildSAT(win, ww, wh, 0);   // 必须在 win 填值后构建（曾于填充前构建读到未初始化内存）
        satWSq = trvBuildSAT(win, ww, wh, 1);
        if (!satWSq) goto cleanup;
        int wOutW = ww - tw + 1, wOutH = wh - th + 1;
        corrW = trvCorrelate2D(win, ww, tflipFull, tw, th, wOutW, wOutH);
        if (!corrW) goto cleanup;
        double bestF = -2.0; int fu = 0, fv = 0;
        for (int v = 0; v < wOutH; v++)
            for (int u = 0; u < wOutW; u++) {
                double s = trvNCCScore(corrW[(size_t)v * wOutW + u], satWS, satWSq, ww + 1,
                                       u, v, tw, th, tSumF, tSqF);
                if (s > bestF) { bestF = s; fu = u; fv = v; }
            }

        double fx = (double)(wx + fu), fy = (double)(wy + fv);
        BOOL found = bestF >= threshold;
        outDict = @{@"ok": @YES,
                    @"found": @(found),
                    @"score": @(round(bestF * 1000.0) / 1000.0),
                    @"x": @((fx + tw / 2.0) / W), @"y": @((fy + th / 2.0) / H),
                    @"w": @((double)tw / W), @"h": @((double)th / H),
                    @"width": @(W), @"height": @(H),   // 轻量帧校验：与 OCR 等感知 op 的 width/height 对齐，编排层跨 op 校验帧一致性
                    @"threshold": @(threshold),
                    @"durationMs": @((int)round((CFAbsoluteTimeGetCurrent() - started) * 1000.0))};
        goto cleanup;
    }

cleanup:
    free(tgray); free(sgray); free(ds); free(dt); free(tflip8); free(tflipFull);
    free(satS); free(satSq); free(corr8); free(win); free(satWS); free(satWSq); free(corrW);
    return outDict;
}

@end
