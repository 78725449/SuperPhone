/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "TRWpsTile.h"

#import <math.h>

// ---------- 常量（对齐 scripts/apple-wps.mjs TILE_HOSTS/TILE_HEADERS/latLonToTile/packTileKey/macFromInt64/parseWifiTile） ----------
static const int kTRWpsTileLevel = 13;
static const NSUInteger kTRWpsTileCacheLimit = 32;

static const double kTRWpsMinLat = -85.05112878;
static const double kTRWpsMaxLat = 85.05112878;
static const double kTRWpsMinLon = -180.0;
static const double kTRWpsMaxLon = 180.0;

static NSString *const kTRWpsTileHostIntl = @"https://gspe85-ssl.ls.apple.com";
static NSString *const kTRWpsTileHostCN = @"https://gspe85-cn-ssl.ls.apple.com";

// ---------- protobuf 原语（静态函数无法跨文件复用，复制自 TRWpsClient.mm，语义对齐 mjs readVarint/skipField） ----------
static BOOL readVarint(const uint8_t *buf, NSUInteger len, NSUInteger *off, uint64_t *out) {
    uint64_t result = 0;
    int shift = 0;
    while (*off < len && shift < 64) {
        uint8_t b = buf[*off];
        (*off)++;
        result |= (uint64_t)(b & 0x7f) << shift;
        if (!(b & 0x80)) { *out = result; return YES; }
        shift += 7;
    }
    return NO;
}

static BOOL skipField(const uint8_t *buf, NSUInteger len, NSUInteger *off, int wireType) {
    uint64_t v;
    switch (wireType) {
        case 0: return readVarint(buf, len, off, &v);
        case 1: if (*off + 8 > len) return NO; *off += 8; return YES;
        case 2: {
            uint64_t sl;
            if (!readVarint(buf, len, off, &sl)) return NO;
            if (sl > len - *off) return NO;
            *off += (NSUInteger)sl;
            return YES;
        }
        case 5: if (*off + 4 > len) return NO; *off += 4; return YES;
        default: return NO;
    }
}

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
        if (!readVarint(buf, len, &i, &tag)) break;
        int fieldNum = (int)(tag >> 3);
        int wireType = (int)(tag & 7);
        if (fieldNum == 3 && wireType == 2) {
            uint64_t lenV;
            if (!readVarint(buf, len, &i, &lenV)) break;
            if (lenV > len - i) break;
            NSUInteger regionEnd = i + (NSUInteger)lenV;
            while (i < regionEnd) {
                uint64_t rtag;
                if (!readVarint(buf, len, &i, &rtag)) break;
                int rf = (int)(rtag >> 3);
                int rw = (int)(rtag & 7);
                if (rf == 2 && rw == 2) {
                    uint64_t dlen;
                    if (!readVarint(buf, len, &i, &dlen)) break;
                    if (dlen > len - i) break;
                    NSUInteger devEnd = i + (NSUInteger)dlen;
                    NSString *bssid = nil;
                    double lat = 0, lon = 0;
                    BOOL hasLat = NO, hasLon = NO;
                    while (i < devEnd) {
                        uint64_t dtag;
                        if (!readVarint(buf, len, &i, &dtag)) break;
                        int df = (int)(dtag >> 3);
                        int dw = (int)(dtag & 7);
                        if (df == 5 && dw == 0) {
                            uint64_t value;
                            if (!readVarint(buf, len, &i, &value)) break;
                            bssid = macFromInt64(value);
                        } else if (df == 6 && dw == 2) {
                            uint64_t elen;
                            if (!readVarint(buf, len, &i, &elen)) break;
                            if (elen > len - i) break;
                            NSUInteger entryEnd = i + (NSUInteger)elen;
                            while (i < entryEnd) {
                                uint64_t etag;
                                if (!readVarint(buf, len, &i, &etag)) break;
                                int ef = (int)(etag >> 3);
                                int ew = (int)(etag & 7);
                                if (ew == 5) {
                                    if (i + 4 > len) break;
                                    int32_t raw = readInt32LE(buf + i);
                                    i += 4;
                                    if (ef == 1) { lat = (double)raw / 1e7; hasLat = YES; }
                                    else if (ef == 2) { lon = (double)raw / 1e7; hasLon = YES; }
                                } else {
                                    if (!skipField(buf, len, &i, ew)) break;
                                }
                            }
                        } else {
                            if (!skipField(buf, len, &i, dw)) break;
                        }
                    }
                    if (bssid && hasLat && hasLon) {
                        TRWpsTileAP *ap = [[TRWpsTileAP alloc] init];
                        ap.bssid = bssid;
                        ap.coord = CLLocationCoordinate2DMake(lat, lon);
                        [aps addObject:ap];
                    }
                } else {
                    if (!skipField(buf, len, &i, rw)) break;
                }
            }
        } else {
            if (!skipField(buf, len, &i, wireType)) break;
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
    uint64_t key = packTileKey((uint32_t)ty, (uint32_t)tx, kTRWpsTileLevel);
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

    NSString *host = pickTileHost(coord.latitude, coord.longitude);
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

@end
