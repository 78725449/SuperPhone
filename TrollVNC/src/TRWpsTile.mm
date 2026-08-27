/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "TRWpsTile.h"
#import "TRWpsProto.h" // protobuf 读取原语（readVarint/skipField 曾本地复制，2026-08-28 上移共享模块）

#import <math.h>

// ---------- 常量（对齐 scripts/apple-wps.mjs TILE_HOSTS/TILE_HEADERS/latLonToTile/packTileKey/macFromInt64/parseWifiTile） ----------
static const int kTRWpsTileLevel = 13;
static const NSUInteger kTRWpsTileCacheLimit = 32;

const NSUInteger kTRWpsWindowSize = 30; // 可见窗口大小（daemon 注入与 App 标注共用，2026-08-28）

static const double kTRWpsMinLat = -85.05112878;
static const double kTRWpsMaxLat = 85.05112878;
static const double kTRWpsMinLon = -180.0;
static const double kTRWpsMaxLon = 180.0;

static NSString *const kTRWpsTileHostIntl = @"https://gspe85-ssl.ls.apple.com";
static NSString *const kTRWpsTileHostCN = @"https://gspe85-cn-ssl.ls.apple.com";

// protobuf 读取原语已上移 TRWpsProto.h/.mm（TRWpsReadVarint/TRWpsSkipField，2026-08-28）

// sfixed32 = 小端 4 字节 → int32（对齐 mjs readInt32LE；逐字节组装无端序依赖）
static int32_t readInt32LE(const uint8_t *p) {
    uint32_t u = (uint32_t)p[0]
               | ((uint32_t)p[1] << 8)
               | ((uint32_t)p[2] << 16)
               | ((uint32_t)p[3] << 24);
    return (int32_t)u;
}

// ---------- 瓦片坐标（对齐 mjs latLonToTile，带 +0.5 像素舍入） ----------
static void latLonToTile(double lat, double lon, int z, int32_t *txOut, int32_t *tyOut) {
    const double size = 256.0 * (1 << z);   // 256 << z
    double la = fmax(fmin(lat, kTRWpsMaxLat), kTRWpsMinLat);
    double lo = fmax(fmin(lon, kTRWpsMaxLon), kTRWpsMinLon);
    double x = (lo + 180.0) / 360.0;
    double sinLat = sin(la * M_PI / 180.0);
    double y = 0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * M_PI);
    double px = floor(fmax(fmin(x * size + 0.5, size - 1), 0));
    double py = floor(fmax(fmin(y * size + 0.5, size - 1), 0));
    *txOut = (int32_t)(px / 256.0);
    *tyOut = (int32_t)(py / 256.0);
}

// ---------- morton 编码（对齐 mjs packTileKey；row=ty, column=tx；level=13 时 key < 2^27） ----------
static uint64_t packTileKey(uint32_t row, uint32_t column, int level) {
    uint64_t result = 1ULL << (level << 1);
    for (int i = 0; i < level; i++) {
        if (column & 1) result += 1ULL << (2 * i);
        if (row & 1) result += 1ULL << (2 * i + 1);
        column >>= 1;
        row >>= 1;
    }
    return result;
}

// ---------- morton 解码（对齐 mjs unpackTileKey；按 key 反解瓦片行列，供按 key 请求选 host） ----------
static void unpackTileKey(uint64_t key, uint32_t *rowOut, uint32_t *colOut) {
    uint32_t row = 0, column = 0;
    int level = 0;
    uint64_t k = key;
    while (k > 1) {
        column |= (uint32_t)((k & 1ULL) << level);
        k >>= 1;
        row |= (uint32_t)((k & 1ULL) << level);
        k >>= 1;
        level++;
    }
    if (rowOut) *rowOut = row;
    if (colOut) *colOut = column;
}

// ---------- 瓦片中心经纬度（Web Mercator 逆投影；供按 key 请求选 host） ----------
static CLLocationCoordinate2D tileCenterFromTile(int32_t tx, int32_t ty, int level) {
    double size = 256.0 * (double)(1 << level);
    double px = (double)tx * 256.0 + 128.0;
    double py = (double)ty * 256.0 + 128.0;
    double lon = px / size * 360.0 - 180.0;
    double lat = atan(sinh(M_PI * (1.0 - 2.0 * py / size))) * 180.0 / M_PI;
    return CLLocationCoordinate2DMake(lat, lon);
}

// ---------- int64→MAC（对齐 mjs macFromInt64：大端 8 字节取低 6 字节 → XX:XX:XX:XX:XX:XX） ----------
static NSString *macFromInt64(uint64_t v) {
    uint8_t bytes[8];
    for (int i = 7; i >= 0; i--) {
        bytes[i] = (uint8_t)(v & 0xff);
        v >>= 8;
    }
    return [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
            bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]];
}

// ---------- tile host（对齐 mjs pickTileHost：中国大陆 bbox 启发式） ----------
static NSString *pickTileHost(double lat, double lon) {
    if (lat >= 18 && lat <= 54 && lon >= 73 && lon <= 135) return kTRWpsTileHostCN;
    return kTRWpsTileHostIntl;
}

// ---------- 响应解析（对齐 mjs parseWifiTile：纯 protobuf 无 ARPC 头） ----------
// 外层 field3(wire2)=Region → Region 内 field2(wire2)=Device → Device 内 field5(varint)=bssid、
// field6(wire2)=entry → entry 内 field1/field2 为 sfixed32（wireType 5，小端）÷1e7 得 lat/lon
static NSArray<TRWpsTileAP *> *parseWifiTile(const uint8_t *buf, NSUInteger len) {
    NSMutableArray *aps = [NSMutableArray array];
    NSUInteger i = 0;
    while (i < len) {
        uint64_t tag;
        if (!TRWpsReadVarint(buf, len, &i, &tag)) break;
        int fieldNum = (int)(tag >> 3);
        int wireType = (int)(tag & 7);
        if (fieldNum == 3 && wireType == 2) {
            uint64_t lenV;
            if (!TRWpsReadVarint(buf, len, &i, &lenV)) break;
            if (lenV > len - i) break;
            NSUInteger regionEnd = i + (NSUInteger)lenV;
            while (i < regionEnd) {
                uint64_t rtag;
                if (!TRWpsReadVarint(buf, len, &i, &rtag)) break;
                int rf = (int)(rtag >> 3);
                int rw = (int)(rtag & 7);
                if (rf == 2 && rw == 2) {
                    uint64_t dlen;
                    if (!TRWpsReadVarint(buf, len, &i, &dlen)) break;
                    if (dlen > len - i) break;
                    NSUInteger devEnd = i + (NSUInteger)dlen;
                    NSString *bssid = nil;
                    double lat = 0, lon = 0;
                    BOOL hasLat = NO, hasLon = NO;
                    while (i < devEnd) {
                        uint64_t dtag;
                        if (!TRWpsReadVarint(buf, len, &i, &dtag)) break;
                        int df = (int)(dtag >> 3);
                        int dw = (int)(dtag & 7);
                        if (df == 5 && dw == 0) {
                            uint64_t value;
                            if (!TRWpsReadVarint(buf, len, &i, &value)) break;
                            bssid = macFromInt64(value);
                        } else if (df == 6 && dw == 2) {
                            uint64_t elen;
                            if (!TRWpsReadVarint(buf, len, &i, &elen)) break;
                            if (elen > len - i) break;
                            NSUInteger entryEnd = i + (NSUInteger)elen;
                            while (i < entryEnd) {
                                uint64_t etag;
                                if (!TRWpsReadVarint(buf, len, &i, &etag)) break;
                                int ef = (int)(etag >> 3);
                                int ew = (int)(etag & 7);
                                if (ew == 5) {
                                    if (i + 4 > len) break;
                                    int32_t raw = readInt32LE(buf + i);
                                    i += 4;
                                    if (ef == 1) { lat = (double)raw / 1e7; hasLat = YES; }
                                    else if (ef == 2) { lon = (double)raw / 1e7; hasLon = YES; }
                                } else {
                                    if (!TRWpsSkipField(buf, len, &i, ew)) break;
                                }
                            }
                        } else {
                            if (!TRWpsSkipField(buf, len, &i, dw)) break;
                        }
                    }
                    if (bssid && hasLat && hasLon) {
                        TRWpsTileAP *ap = [[TRWpsTileAP alloc] init];
                        ap.bssid = bssid;
                        ap.coord = CLLocationCoordinate2DMake(lat, lon);
                        [aps addObject:ap];
                    }
                } else {
                    if (!TRWpsSkipField(buf, len, &i, rw)) break;
                }
            }
        } else {
            if (!TRWpsSkipField(buf, len, &i, wireType)) break;
        }
    }
    return aps;
}

@interface TRWpsTile ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<TRWpsTileAP *> *> *cache;   // key=tileKey
@property (nonatomic, strong) NSMutableArray<NSNumber *> *cacheOrder;                             // LRU 顺序（末尾最新）
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableArray *> *inflight;        // key=tileKey → 在途请求等待回调数组（并发去重）
@end

@implementation TRWpsTileAP
@end

@implementation TRWpsTile

+ (instancetype)sharedClient {
    static TRWpsTile *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[TRWpsTile alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 15;
        _session = [NSURLSession sessionWithConfiguration:cfg];
        _cache = [NSMutableDictionary dictionary];
        _cacheOrder = [NSMutableArray array];
        _inflight = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)queryBssidsForCoordinate:(CLLocationCoordinate2D)coord
                           force:(BOOL)force
                      completion:(void (^)(NSArray<TRWpsTileAP *> *aps, NSError *_Nullable error))completion {
    if (!completion) return;
    int32_t tx = 0, ty = 0;
    latLonToTile(coord.latitude, coord.longitude, kTRWpsTileLevel, &tx, &ty);
    [self _queryTileKey:packTileKey((uint32_t)ty, (uint32_t)tx, kTRWpsTileLevel) force:force completion:completion];
}

/// 按瓦片 key 直接查询（queryBssidsForCoordinate 与螺旋搜索共用）：
/// LRU 缓存 + inflight 并发合并 + 无失败负缓存（失败重试节奏由调用方控制）
- (void)_queryTileKey:(uint64_t)key
                force:(BOOL)force
           completion:(void (^)(NSArray<TRWpsTileAP *> *aps, NSError *_Nullable error))completion {
    if (!completion) return;
    NSNumber *keyNum = @(key);

    if (!force) {
        @synchronized (self) {
            NSArray<TRWpsTileAP *> *cached = _cache[keyNum];
            if (cached) {
                [_cacheOrder removeObject:keyNum];
                [_cacheOrder addObject:keyNum];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(cached, nil); });
                return;
            }
            // 无失败负缓存：失败重试节奏由调用方（SimLocationController 10s 巡检 + 跨瓦片检测）天然控制，
            // 不做 30s 锁死——避免空洞瓦片"自我锁死循环"（用户定案 2026-08-27）
        }
    }

    // 在途请求合并：同瓦片已有请求在途时挂起等待，首个请求完成时统一回调所有等待者（并发去重，防重复轰炸 gspe 端点）
    @synchronized (self) {
        NSMutableArray *waiters = _inflight[keyNum];
        if (waiters) {
            [waiters addObject:[completion copy]];
            return;
        }
        waiters = [NSMutableArray array];
        _inflight[keyNum] = waiters;
        [waiters addObject:[completion copy]];
    }

    // 按 key 反解瓦片中心选 host（_queryTileKey 无 coord 参数；空洞/邻近瓦片同区域判定不受影响）
    uint32_t urow = 0, ucol = 0;
    unpackTileKey(key, &urow, &ucol);
    CLLocationCoordinate2D center = tileCenterFromTile((int32_t)ucol, (int32_t)urow, kTRWpsTileLevel);
    NSString *host = pickTileHost(center.latitude, center.longitude);
    // URL 追加 ?tk=<tileKey> 作 CDN cache-buster：国内 gspe85-cn-ssl 解析到金山云 CDN，
    // 其缓存键只含 URL、不含 X-tilekey header——曾致所有瓦片命中同一份陈旧缓存（固定 1051B/33AP），
    // 注入的 BSSID 与模拟坐标完全不自洽（2026-08-27 实测：北京瓦片真身 3520B，设备却拿 1051B）。
    // origin 按 X-tilekey header 取数、忽略 query 参数（已实测验证），故 query 仅用于分离 CDN 缓存键。
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/wifi_request_tile?tk=%llu", host, key]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 15;
    // 对齐 mjs TILE_HEADERS + X-tilekey
    [req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [req setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
    [req setValue:@"geod/1 CFNetwork/1496.0.7 Darwin/23.5.0" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"en-US,en-GB;q=0.9,en;q=0.8" forHTTPHeaderField:@"Accept-Language"];
    [req setValue:@"17.5.21F79" forHTTPHeaderField:@"X-os-version"];
    [req setValue:[NSString stringWithFormat:@"%llu", key] forHTTPHeaderField:@"X-tilekey"];

    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req completionHandler:
        ^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<TRWpsTileAP *> *aps = nil;
            NSError *queryErr = nil;
            NSInteger status = 0;
            if (error) {
                queryErr = error;
            } else {
                NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
                status = http.statusCode;
                if (status < 200 || status >= 300) {
                    queryErr = [NSError errorWithDomain:@"TRWpsTile" code:status
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)status]}];
                } else {
                    aps = parseWifiTile((const uint8_t *)data.bytes, data.length); // .mm 按 C++ 编译：void* 需显式转 uint8_t*
                }
            }
            // 诊断：每次请求的 host/key/status/耗时全打印（定位设备端 404 vs PC 通 的服务节点差异）
            fprintf(stderr, "[wps] tile req host=%s key=%llu status=%ld err=%s len=%lu\n",
                    host.UTF8String, key, (long)status,
                    error ? error.localizedDescription.UTF8String : (queryErr ? queryErr.localizedDescription.UTF8String : "none"),
                    (unsigned long)(data ? data.length : 0));
            // 取出全部等待者并先移除（避免重复回调），成功写 LRU 缓存
            NSMutableArray *waiters = nil;
            @synchronized (self) {
                waiters = _inflight[keyNum];
                [_inflight removeObjectForKey:keyNum];
                if (!queryErr) {
                    _cache[keyNum] = aps;
                    [_cacheOrder removeObject:keyNum];
                    [_cacheOrder addObject:keyNum];
                    if (_cacheOrder.count > kTRWpsTileCacheLimit) {
                        NSNumber *oldest = _cacheOrder.firstObject;
                        [_cache removeObjectForKey:oldest];
                        [_cacheOrder removeObjectAtIndex:0];
                    }
                }
            }
            // 统一回调全部等待者（含首个请求者）：成功=aps、失败=空数组+error
            for (void (^run)(NSArray<TRWpsTileAP *> *, NSError *) in waiters) {
                if (queryErr) { run(@[], queryErr); }
                else { run(aps, nil); }
            }
        });
    }];
    [task resume];
}

- (void)clearCache {
    NSMutableArray *abandoned = [NSMutableArray array];   // 被清空的在途等待者（回调和弃，防调用方挂起）
    @synchronized (self) {
        [_cache removeAllObjects];
        [_cacheOrder removeAllObjects];
        [_inflight enumerateKeysAndObjectsUsingBlock:^(NSNumber *k, NSMutableArray *waiters, BOOL *stop) {
            [abandoned addObjectsFromArray:waiters];
        }];
        [_inflight removeAllObjects];
    }
    // 在途请求本身仍会完成并写回 cache
    if (abandoned.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            for (void (^run)(NSArray<TRWpsTileAP *> *, NSError *) in abandoned) {
                run(@[], nil);
            }
        });
    }
}

+ (uint64_t)tileKeyForCoordinate:(CLLocationCoordinate2D)coord {
    int32_t tx = 0, ty = 0;
    latLonToTile(coord.latitude, coord.longitude, kTRWpsTileLevel, &tx, &ty);
    return packTileKey((uint32_t)ty, (uint32_t)tx, kTRWpsTileLevel);
}

+ (BOOL)tileChangedForCoordinate:(CLLocationCoordinate2D)coord
                        previous:(uint64_t)previous
                          newKey:(uint64_t *)newKey {
    int32_t tx = 0, ty = 0;
    latLonToTile(coord.latitude, coord.longitude, kTRWpsTileLevel, &tx, &ty);
    uint64_t key = packTileKey((uint32_t)ty, (uint32_t)tx, kTRWpsTileLevel);
    if (newKey) *newKey = key;
    return (key != previous);
}

+ (NSArray<NSString *> *)sampleBssidsFromAPs:(NSArray<TRWpsTileAP *> *)aps max:(NSUInteger)max {
    NSMutableArray *bssids = [NSMutableArray arrayWithCapacity:MIN(max, aps.count)];
    NSUInteger n = MIN(max, aps.count);
    for (NSUInteger i = 0; i < n; i++) [bssids addObject:aps[i].bssid];
    return bssids;
}

// ---------- 距离窗口 + RSSI 加权质心（2026-08-28：模拟真实设备移动时可见 AP 渐变） ----------

+ (NSArray<TRWpsTileAP *> *)windowApsByDistance:(NSArray<TRWpsTileAP *> *)aps
                                         center:(CLLocationCoordinate2D)center
                                         window:(NSUInteger)window {
    if (aps.count == 0) return @[];
    NSUInteger win = MAX(window, (NSUInteger)1);
    // 平面近似距离排序（窗口内 ≤4.9km，经纬度线性足够；经度按 cos 纬度缩放）
    double cosLat = cos(center.latitude * M_PI / 180.0);
    NSArray *sorted = [aps sortedArrayUsingComparator:^NSComparisonResult(TRWpsTileAP *a, TRWpsTileAP *b) {
        double dLatA = a.coord.latitude - center.latitude;
        double dLonA = (a.coord.longitude - center.longitude) * cosLat;
        double dLatB = b.coord.latitude - center.latitude;
        double dLonB = (b.coord.longitude - center.longitude) * cosLat;
        double da = dLatA * dLatA + dLonA * dLonA;
        double db = dLatB * dLatB + dLonB * dLonB;
        return da < db ? NSOrderedAscending : (da > db ? NSOrderedDescending : NSOrderedSame);
    }];
    NSUInteger n = MIN(win, sorted.count);
    return [sorted subarrayWithRange:NSMakeRange(0, n)];
}

+ (CLLocationCoordinate2D)rssiWeightedCentroidOfAps:(NSArray<TRWpsTileAP *> *)aps {
    if (aps.count == 0) return kCLLocationCoordinate2DInvalid;
    // 相对首点（窗口内小范围）算米制距离，权重 1/(1+d) 近强远弱——模拟定位偏向强信号 AP
    TRWpsTileAP *ref = aps[0];
    double cosRef = cos(ref.coord.latitude * M_PI / 180.0);
    double wlat = 0, wlon = 0, wsum = 0;
    for (TRWpsTileAP *ap in aps) {
        double dLat = (ap.coord.latitude - ref.coord.latitude) * 111320.0;
        double dLon = (ap.coord.longitude - ref.coord.longitude) * 111320.0 * cosRef;
        double d = sqrt(dLat * dLat + dLon * dLon);
        double w = 1.0 / (1.0 + d);
        wlat += ap.coord.latitude * w;
        wlon += ap.coord.longitude * w;
        wsum += w;
    }
    return CLLocationCoordinate2DMake(wlat / wsum, wlon / wsum);
}

// ---------- 空洞瓦片螺旋回退（远程伪装起点即空洞，2026-08-28 定案；社区 acheong08 demo-api 同款） ----------
// 场景：模拟坐标所在瓦片为 Apple 数据空洞（404）且从未注入成功——不注入会让 locationd 的 wifi 源
// 回落为设备本地真实扫描（GPS=模拟 vs wifi=本地，数百公里级不自洽）。从空洞瓦片出发按 Ulam 螺旋
// 搜索最近的有效瓦片，注入其 BSSID（偏差 1-10km，次优但最优解）；全部空洞则保持不注入（真实设备行为）。

+ (void)queryNearestBssidsForCoordinate:(CLLocationCoordinate2D)coord
                            maxAttempts:(NSUInteger)maxAttempts
                             completion:(void (^)(NSArray<TRWpsTileAP *> *aps, NSError *_Nullable error))completion {
    if (!completion) return;
    int32_t tx0 = 0, ty0 = 0;
    latLonToTile(coord.latitude, coord.longitude, kTRWpsTileLevel, &tx0, &ty0);
    // Ulam spiral 候选序列：从自身出发，步长 1,1,2,2,3,3...，方向 右/上/左/下（距离近→远）
    NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    int dx = 0, dy = 0, step = 1, dir = 0, dirCount = 0;
    NSUInteger cap = MAX(maxAttempts, (NSUInteger)1);
    for (NSUInteger i = 0; i < cap; i++) {
        int32_t tx = tx0 + dx, ty = ty0 + dy;
        if (!(tx == tx0 && ty == ty0)) { // 跳过自身（发起方已对该瓦片失败）
            NSNumber *k = @(packTileKey((uint32_t)ty, (uint32_t)tx, kTRWpsTileLevel));
            if (![seen containsObject:k]) { [seen addObject:k]; [candidates addObject:k]; }
        }
        switch (dir) {
            case 0: dx++; break;  // 右
            case 1: dy--; break;  // 上（ty 北小）
            case 2: dx--; break;  // 左
            default: dy++; break; // 下
        }
        if (++dirCount >= step) {
            dir = (dir + 1) % 4;
            dirCount = 0;
            if (dir == 0 || dir == 2) step++; // 每完成两个方向步长 +1
        }
    }
    if (candidates.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], nil); });
        return;
    }
    [[self sharedClient] _trySpiral:candidates index:0 completion:completion];
}

/// 串行尝试候选瓦片：找到第一个有效即停；全部空洞回调空
- (void)_trySpiral:(NSArray<NSNumber *> *)keys
             index:(NSUInteger)idx
        completion:(void (^)(NSArray<TRWpsTileAP *> *aps, NSError *_Nullable error))completion {
    if (idx >= keys.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], nil); });
        return;
    }
    __weak __typeof__(self) weakSelf = self;
    [self _queryTileKey:keys[idx].unsignedLongLongValue force:NO completion:^(NSArray<TRWpsTileAP *> *aps, NSError *error) {
        __strong __typeof__(self) strongSelf = weakSelf;
        if (aps.count > 0) { completion(aps, nil); return; } // 最近有效瓦片
        if (strongSelf) [strongSelf _trySpiral:keys index:idx + 1 completion:completion];
        else completion(@[], error);
    }];
}

@end
