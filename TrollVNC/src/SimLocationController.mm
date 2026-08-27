/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "SimLocationController.h"

#import "SimLocationManager.h"
#import "SimRouteCalculator.h" // haversineMeters（与 App 截断同度量，选最近续播点）
#import "TRWpsTile.h" // 坐标→BSSID 动态反查（daemon 注入 wifi 模拟源）
#import "Logging.h"
#import <math.h>

// 轨迹点序列文件（大 payload 走文件，对齐 manager pid 平铺命名）
static NSString *const kSimTrackFilePath = @"/var/mobile/Library/Caches/com.82flex.trollvnc.simloc.json";
// 配置 plist（mobile 域=配置源：App 写 mobile、uploadTrackPoints 也写 mobile；root 域仅兜底）
static NSString *const kSimMobilePrefsPath = @"/var/mobile/Library/Preferences/com.82flex.trollvnc.plist";
// 巡检间隔：失效检测 + 参数变更感知合一
static const NSTimeInterval kSimPatrolInterval = 10.0;
// track 逐点注入间隔（itinerary：1s/点）
static const NSTimeInterval kSimTrackTickInterval = 1.0;
// anchor 微动游走间隔（1s/步）
static const NSTimeInterval kSimAnchorTickInterval = 1.0;
// anchor 微动范围（米）：人在原地附近小幅活动（5~50m 随机取，这里取中位）
static const double kSimAnchorRangeM = 20.0;

@implementation SimLocationController {
    dispatch_source_t _patrolSource;   // 10s 巡检
    dispatch_source_t _trackSource;    // itinerary 逐点注入
    dispatch_source_t _anchorSource;   // anchor 微动游走
    NSArray<NSDictionary *> *_trackPoints; // 轨迹点序列（内存缓存）
    NSUInteger _trackIndex;
    NSString *_lastParamsSig;          // 参数指纹（变更检测）
    BOOL _trackFinished;
    // anchor 基底
    double _anchorLat, _anchorLon, _anchorAcc;
    // 当前位置（每次注入后更新；供 status / 编排初始起点 / 失效恢复）
    double _currentLat, _currentLon, _currentSpeed, _currentCourse;
    NSString *_currentMode;
    // anchor 微动游走状态：相对中心偏移（米，局部平面近似）
    double _currentMx, _currentMy;
    uint64_t _lastWifiTileKey;   // 上次 wifi 反查的瓦片 key（跨瓦片才重反查，轨迹跟随）
}

+ (instancetype)sharedController {
    static SimLocationController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[SimLocationController alloc] init];
    });
    return shared;
}

#pragma mark - 公共入口

- (void)start {
    [self reloadFromPrefs];
    [self _startPatrol];
}

- (void)reloadFromPrefs {
    NSString *sig = [self _paramsSignature];
    if (_lastParamsSig && [sig isEqualToString:_lastParamsSig]) {
        // 参数未变：仍做一次失效兜底（若 static 注入失效则重注入）
        [self _checkRestore];
        return;
    }
    _lastParamsSig = sig;
    [self applyFromPrefs];
}

#pragma mark - 状态机

- (void)applyFromPrefs {
    NSString *mode = [self _readPref:@"SimLocationMode"];
    if (![mode isKindOfClass:[NSString class]] || mode.length == 0) mode = @"off";
    TVLog(@"[locsim] apply mode=%@", mode);
    if ([mode isEqualToString:@"off"]) {
        [self _stopAnchor];
        [self _stopTrack];
        _currentMode = @"off";
        _lastWifiTileKey = 0; // 防残留：off 后重启时首点必重新触发反查
        [[SimLocationManager sharedManager] stopAll]; // 总停：GPS + wifi 一并恢复真实
    } else if ([mode isEqualToString:@"anchor"]) {
        // 位置基底：中心点 + 微动游走（拟人必需，完全静止坐标像假 GPS）
        [self _stopTrack];
        [self _startAnchor];
    } else if ([mode isEqualToString:@"itinerary"]) {
        // 动作序列：轨迹文件逐秒推进（重载后从当前注入位置最近点续播，不从头重放）
        [self _stopAnchor];
        [self _startTrack];
    } else {
        TVLog(@"[locsim] unknown mode=%@ -> off", mode);
        [self _stopAnchor];
        [self _stopTrack];
        _currentMode = @"off";
        _lastWifiTileKey = 0; // 防残留：off 后重启时首点必重新触发反查
        [[SimLocationManager sharedManager] stopAll]; // 总停：GPS + wifi 一并恢复真实
    }
}

- (void)_startAnchor {
    double lat = [self _readDouble:@"SimLocationLat" def:0.0];
    double lon = [self _readDouble:@"SimLocationLon" def:0.0];
    double acc = [self _readDouble:@"SimLocationAccuracy" def:5.0];
    if (acc < 3.0) acc = 3.0;
    if (acc > 15.0) acc = 15.0;
    _anchorLat = lat;
    _anchorLon = lon;
    _anchorAcc = acc;
    _currentMx = 0.0;
    _currentMy = 0.0;
    // 首点注入前必须同步 _current（否则用残留值/0 坐标注入，蓝点闪跳）
    _currentLat = lat;
    _currentLon = lon;
    _currentSpeed = 0.0;
    _currentCourse = 0.0;
    _currentMode = @"anchor";
    [self _injectAnchorPointWithSpeed:0.0 course:0.0];
    [self _injectWifiSimulationForCurrentLocation]; // wifi 注入一次即可（anchor 微动 ±20m 内 AP 集不变）
    if (!_anchorSource) {
        _anchorSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(_anchorSource, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSimAnchorTickInterval * NSEC_PER_SEC)),
                                  (uint64_t)(kSimAnchorTickInterval * NSEC_PER_SEC), 0);
        __weak __typeof__(self) weakSelf = self; // 用 __typeof__（trollvncserver 的 -std=c++20 下 typeof 不可用，2026-08-25）
        dispatch_source_set_event_handler(_anchorSource, ^{
            [weakSelf _anchorTick];
        });
        dispatch_resume(_anchorSource);
    }
    TVLog(@"[locsim] anchor start (%.5f, %.5f) acc=%.1f", lat, lon, acc);
}

- (void)_anchorTick {
    // 微动游走：微步随机游走 + 范围约束 + 周期回中（相对中心偏移，米制局部平面近似）
    double step = 0.1 + (double)(arc4random_uniform(400)) / 1000.0; // 0.1~0.5m
    double ang = (double)(arc4random_uniform(62832)) / 10000.0;     // 0~2π
    double dx = _currentMx + cos(ang) * step;
    double dy = _currentMy + sin(ang) * step;
    double dist = sqrt(dx * dx + dy * dy);
    if (dist > kSimAnchorRangeM) {
        // 超出范围：朝中心回拉一半（避免越走越远）
        double over = dist - kSimAnchorRangeM;
        dx -= (dx / dist) * over * 0.5;
        dy -= (dy / dist) * over * 0.5;
    } else if (dist > 0.01 && (arc4random_uniform(100) < 15)) {
        // 15% 概率轻微回中（避免长期单方向漂移）
        double pull = dist * 0.2;
        dx -= (dx / dist) * pull;
        dy -= (dy / dist) * pull;
    }
    _currentMx = dx;
    _currentMy = dy;
    double lat = _anchorLat + dy / 111320.0;
    double lon = _anchorLon + dx / (111320.0 * cos(_anchorLat * M_PI / 180.0));
    double course = atan2(dy, dx) * 180.0 / M_PI;
    if (course < 0) course += 360.0;
    _currentLat = lat;
    _currentLon = lon;
    _currentSpeed = step;
    _currentCourse = course;
    _currentMode = @"anchor";
    [self _injectAnchorPointWithSpeed:step course:course];
}

- (void)_injectAnchorPointWithSpeed:(double)speed course:(double)course {
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(_currentLat, _currentLon);
    [[SimLocationManager sharedManager] injectPoint:coord
                                           altitude:45.0
                                           accuracy:_anchorAcc
                                             course:course
                                              speed:speed];
}

/// 统一目标位置源：wifi 扫描模拟与 GPS 同源注入（动态反查——按当前坐标 tile 查 BSSID 注入）
/// 设计文档 §坐标→SSID 反查：动态+预取混合；轨迹移动时随 _current 变化
/// 真机验证点：
/// 1. injectPoint: 的 clearSimulatedLocations 是否连带清 wifi 模拟（若会则需注入后兜底重注）
/// 2. 总开关关闭后 GPS + wifi 是否都恢复真实（5902 日志确认）
- (void)_injectWifiSimulationForCurrentLocation {
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(_currentLat, _currentLon);
    if (coord.latitude == 0 && coord.longitude == 0) return; // 无当前位置
    __weak __typeof__(self) weakSelf = self;
    [[TRWpsTile sharedClient] queryBssidsForCoordinate:coord force:NO completion:^(NSArray<TRWpsTileAP *> *aps, NSError *error) {
        __strong __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error || aps.count == 0) {
            // 反查失败/空：保持现状（负缓存已挡重试风暴；不打断已有 wifi 模拟）
            TVLog(@"[locsim] tile query skipped: %@", error.localizedDescription ?: @"no APs");
            return;
        }
        // 取前 100 个代表性 AP（避免注入请求过大，locationd 解算足够）
        NSArray<NSString *> *sample = [strongSelf _sampleBssids:aps max:100];
        NSArray *scanResults = [SimLocationManager buildScanResultsFromBssidStrings:sample];
        if (scanResults.count) {
            [[SimLocationManager sharedManager] injectWifiScanResults:scanResults];
            TVLog(@"[locsim] wifi simulation inject, %lu APs (dynamic)", (unsigned long)scanResults.count);
        }
    }];
}

/// 取前 max 个 BSSID（动态反查结果采样，避免注入请求过大）
- (NSArray<NSString *> *)_sampleBssids:(NSArray<TRWpsTileAP *> *)aps max:(NSUInteger)max {
    NSMutableArray *bssids = [NSMutableArray arrayWithCapacity:MIN(max, aps.count)];
    NSUInteger n = MIN(max, aps.count);
    for (NSUInteger i = 0; i < n; i++) {
        [bssids addObject:aps[i].bssid];
    }
    return bssids;
}

- (void)_stopAnchor {
    if (_anchorSource) {
        dispatch_source_cancel(_anchorSource);
        _anchorSource = nil;
    }
}

#pragma mark - itinerary 轨迹推进（每秒注入一点，完成后保持终点）

- (void)_startTrack {
    NSArray *points = [self _loadTrackPoints];
    if (points.count == 0) {
        TVLog(@"[locsim] track file empty/missing: %@", kSimTrackFilePath);
        [self _stopTrack];
        [[SimLocationManager sharedManager] stopAll]; // 空轨迹全停（GPS+wifi 一并恢复真实，防残留）
        return;
    }
    _trackPoints = points;
    _currentMode = @"itinerary";
    // 从当前注入位置最近的轨迹点续播（轨迹文件更新后追加/删除/重排不从头重放旧段）；
    // 无当前位置（进程刚起）则从首点开始
    NSUInteger startIdx = 0;
    if (_currentLat != 0 || _currentLon != 0) {
        // 最近点用 haversine（与 App 截断同度量）：平面平方近似在经度方向未按 cos 缩放，
        // 两端可能选到不同续播点 → 重载时位置跳变；统一物理度量保证续播点一致
        CLLocationCoordinate2D cur = CLLocationCoordinate2DMake(_currentLat, _currentLon);
        NSUInteger best = 0;
        double bestD = DBL_MAX;
        for (NSUInteger i = 0; i < points.count; i++) {
            NSDictionary *p = points[i];
            double d = [SimRouteCalculator haversineMeters:cur to:CLLocationCoordinate2DMake([p[@"lat"] doubleValue], [p[@"lon"] doubleValue])];
            if (d < bestD) { bestD = d; best = i; }
        }
        startIdx = best;
    }
    [self _injectPointDict:points[startIdx]];
    [self _injectWifiSimulationForCurrentLocation]; // 首点坐标反查（动态 tile 查 BSSID；跨瓦片时重新触发注入即自动换源，跟随 _current）
    _lastWifiTileKey = [TRWpsTile tileKeyForCoordinate:CLLocationCoordinate2DMake(_currentLat, _currentLon)]; // 记录首点瓦片 key（首点已反查，同瓦片不重复触发）
    _trackIndex = startIdx + 1;
    _trackFinished = NO;
    if (_trackSource) {
        dispatch_source_cancel(_trackSource);
        _trackSource = nil;
    }
    _trackSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_trackSource, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSimTrackTickInterval * NSEC_PER_SEC)),
                              (uint64_t)(kSimTrackTickInterval * NSEC_PER_SEC), 0);
    __weak __typeof__(self) weakSelf = self; // 用 __typeof__（-std=c++20 下 typeof 不可用）
    dispatch_source_set_event_handler(_trackSource, ^{
        [weakSelf _trackTick];
    });
    dispatch_resume(_trackSource);
    TVLog(@"[locsim] itinerary start, %lu points (from idx %lu)", (unsigned long)points.count, (unsigned long)startIdx);
}

- (void)_trackTick {
    if (_trackIndex >= _trackPoints.count) {
        [self _stopTrack]; // 完成：停 timer，保持终点坐标（不调 stop）
        TVLog(@"[locsim] itinerary finished, keep final point");
        return;
    }
    [self _injectPointDict:_trackPoints[_trackIndex++]];
    // 轨迹 wifi 跟随（用户拍板 2026-08-27）：跨瓦片才重新反查注入（同瓦片 LRU 命中零成本）
    [self _checkWifiTileChangedAndReinject];
}

/// 检测当前坐标瓦片是否变化，跨瓦片则重新 wifi 动态反查注入（轨迹跟随）
- (void)_checkWifiTileChangedAndReinject {
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(_currentLat, _currentLon);
    if (coord.latitude == 0 && coord.longitude == 0) return; // 无当前位置
    uint64_t key = [TRWpsTile tileKeyForCoordinate:coord];
    if (key == _lastWifiTileKey) return; // 同瓦片：不重反查（LRU 已覆盖）
    _lastWifiTileKey = key;
    [self _injectWifiSimulationForCurrentLocation];
}

- (void)_injectPointDict:(NSDictionary *)p {
    double lat = [p[@"lat"] doubleValue];
    double lon = [p[@"lon"] doubleValue];
    double acc = [p[@"acc"] doubleValue];
    if (acc < 3.0) acc = 3.0;
    if (acc > 15.0) acc = 15.0;
    double speed = [p[@"speed"] doubleValue];
    double course = [p[@"course"] doubleValue];
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(lat, lon);
    [[SimLocationManager sharedManager] injectPoint:coord
                                           altitude:[p[@"alt"] doubleValue] > 0 ? [p[@"alt"] doubleValue] : 45.0
                                           accuracy:acc
                                             course:course
                                              speed:speed];
    // 当前位置更新（供 status / 编排初始起点 / 失效恢复）
    _currentLat = lat;
    _currentLon = lon;
    _currentSpeed = speed;
    _currentCourse = course;
}

- (void)_stopTrack {
    if (_trackSource) {
        dispatch_source_cancel(_trackSource);
        _trackSource = nil;
    }
    _trackPoints = nil;
    _trackIndex = 0;
    _trackFinished = YES;
}

- (NSArray *)_loadTrackPoints {
    NSData *data = [NSData dataWithContentsOfFile:kSimTrackFilePath];
    if (!data.length) return @[];
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if ([json isKindOfClass:[NSDictionary class]] && [json[@"points"] isKindOfClass:[NSArray class]]) {
        return json[@"points"];
    }
    if ([json isKindOfClass:[NSArray class]]) return json;
    return @[];
}

#pragma mark - 轨迹上传（App 定位 UI/算路模块直调；2026-08-26 起 sim.location.track 已收敛）

+ (BOOL)uploadTrackPoints:(NSArray<NSDictionary *> *)points error:(NSError **)error {
    if (![points isKindOfClass:[NSArray class]] || points.count == 0) {
        if (error) *error = [NSError errorWithDomain:@"SimLoc" code:1 userInfo:@{NSLocalizedDescriptionKey:@"points 数组不能为空"}];
        return NO;
    }
    NSMutableArray *clean = [NSMutableArray arrayWithCapacity:points.count];
    for (id item in points) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            if (error) *error = [NSError errorWithDomain:@"SimLoc" code:2 userInfo:@{NSLocalizedDescriptionKey:@"points 元素须为对象 {lat,lon,...}"}];
            return NO;
        }
        double lat = [item[@"lat"] doubleValue];
        double lon = [item[@"lon"] doubleValue];
        if (lat < -90.0 || lat > 90.0 || lon < -180.0 || lon > 180.0) {
            if (error) *error = [NSError errorWithDomain:@"SimLoc" code:3 userInfo:@{NSLocalizedDescriptionKey:@"坐标超出 WGS-84 范围"}];
            return NO;
        }
        NSMutableDictionary *pt = [item mutableCopy];
        double acc = [pt[@"acc"] doubleValue];
        if (!(acc >= 3.0 && acc <= 15.0)) pt[@"acc"] = @(MIN(15.0, MAX(3.0, acc))); // 精度钳制 3~15
        [clean addObject:pt];
    }
    // 原子写：临时文件 + rename，避免 Controller 读到半截 JSON
    NSDictionary *payload = @{ @"version": @1, @"points": clean };
    NSError *jerr = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jerr];
    if (!json) {
        if (error) *error = jerr ?: [NSError errorWithDomain:@"SimLoc" code:4 userInfo:@{NSLocalizedDescriptionKey:@"轨迹序列化失败"}];
        return NO;
    }
    NSString *tmp = [kSimTrackFilePath stringByAppendingString:@".tmp"];
    NSError *werr = nil;
    if (![json writeToFile:tmp options:NSDataWritingAtomic error:&werr]) {
        if (error) *error = werr ?: [NSError errorWithDomain:@"SimLoc" code:5 userInfo:@{NSLocalizedDescriptionKey:@"轨迹临时文件写入失败"}];
        return NO;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:kSimTrackFilePath]) {
        [[NSFileManager defaultManager] removeItemAtPath:kSimTrackFilePath error:NULL];
    }
    if (![[NSFileManager defaultManager] moveItemAtPath:tmp toPath:kSimTrackFilePath error:&werr]) {
        if (error) *error = werr ?: [NSError errorWithDomain:@"SimLoc" code:6 userInfo:@{NSLocalizedDescriptionKey:@"轨迹文件替换失败"}];
        return NO;
    }
    // 切 itinerary 模式（统一写 mobile 域 plist=配置源：App 也是 mobile 域写入，二者同域不冲突；
    // 旧实现写 root 域，root 域一旦残留 SimLocationMode 会覆盖 App 的 mobile 写入 → App 开启定位永不生效）
    NSMutableDictionary *mp = [NSMutableDictionary dictionaryWithContentsOfFile:kSimMobilePrefsPath] ?: [NSMutableDictionary dictionary];
    mp[@"SimLocationMode"] = @"itinerary";
    [mp writeToFile:kSimMobilePrefsPath atomically:YES];
    TVLog(@"[locsim] track uploaded: %lu points", (unsigned long)clean.count);
    return YES;
}

#pragma mark - 当前位置状态（App/daemon 查询；2026-08-26 起 sim.location.status 已收敛）

+ (NSDictionary *)currentStatus {
    SimLocationController *c = [SimLocationController sharedController];
    NSString *mode = c->_currentMode ?: @"off";
    if ([mode isEqualToString:@"off"] || (c->_currentLat == 0 && c->_currentLon == 0)) {
        return @{ @"mode": mode };
    }
    return @{
        @"mode": mode,
        @"lat": @(c->_currentLat),
        @"lon": @(c->_currentLon),
        @"speed": @(c->_currentSpeed),
        @"course": @(c->_currentCourse),
    };
}

#pragma mark - 巡检（10s：失效恢复 + 参数变更感知）

- (void)_startPatrol {
    if (_patrolSource) return;
    _patrolSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_patrolSource, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSimPatrolInterval * NSEC_PER_SEC)),
                              (uint64_t)(kSimPatrolInterval * NSEC_PER_SEC), 0);
    __weak __typeof__(self) weakSelf = self; // 用 __typeof__（-std=c++20 下 typeof 不可用）
    dispatch_source_set_event_handler(_patrolSource, ^{
        [weakSelf reloadFromPrefs];
    });
    dispatch_resume(_patrolSource);
}

- (void)_checkRestore {
    NSString *mode = [self _readPref:@"SimLocationMode"];
    if (![mode isKindOfClass:[NSString class]] || mode.length == 0) mode = @"off";
    if ([mode isEqualToString:@"off"]) return;
    if ([mode isEqualToString:@"anchor"]) {
        // anchor 注入失效（locationd 会话中断）或游走 timer 丢失则重启
        if (![SimLocationManager sharedManager].isSimulating || !_anchorSource) {
            TVLog(@"[locsim] anchor lost, re-start");
            [self _startAnchor];
        } else if ([SimLocationManager sharedManager].isSimulating && [SimLocationManager sharedManager].wasWifiSimulatingOnce) {
            // wifi 曾成功但当前丢失（locationd 会话中断）→ 兜底重注（幂等：内部完整重启）。
            // 从未成功（空洞瓦片反查失败）不重试——重注无意义且造成"自我锁死循环"；
            // 等轨迹跨瓦片（_lastWifiTileKey 变化）自然换源反查（2026-08-27 定案）
            TVLog(@"[locsim] anchor wifi lost, re-inject");
            [self _injectWifiSimulationForCurrentLocation];
        }
    } else if ([mode isEqualToString:@"itinerary"]) {
        // 已完成（停在终点）不重播：仅播放中 timer 丢失才重启；进度不持久化，进程重启后从头播
        if (!_trackFinished && !_trackSource) {
            TVLog(@"[locsim] itinerary timer lost, restart");
            [self _startTrack];
        } else if ([SimLocationManager sharedManager].isSimulating && [SimLocationManager sharedManager].wasWifiSimulatingOnce) {
            // 同上：仅"曾成功但丢失"重注；"从未成功"（空洞瓦片）安静等待跨瓦片换源
            TVLog(@"[locsim] itinerary wifi lost, re-inject");
            [self _injectWifiSimulationForCurrentLocation];
        }
    }
}

#pragma mark - 参数读取（双域：root 域 → mobile 域 plist 回退）

- (id)_readPref:(NSString *)key {
    // 配置源=mobile 域（App 与 uploadTrackPoints 都写 mobile，同域无覆盖问题）；
    // root 域仅兜底——旧实现 root 域优先，daemon 曾写 root 残留 SimLocationMode 会永久覆盖 App 的 mobile 写入
    NSDictionary *mobilePrefs = [NSDictionary dictionaryWithContentsOfFile:kSimMobilePrefsPath];
    id v = mobilePrefs[key];
    if (v) return v;
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    return [d objectForKey:key];
}

- (double)_readDouble:(NSString *)key def:(double)def {
    id v = [self _readPref:key];
    if ([v respondsToSelector:@selector(doubleValue)]) return [v doubleValue];
    return def;
}

- (NSString *)_paramsSignature {
    // 轨迹文件 mtime 纳入指纹：App 新增/删除/重排锚点重写轨迹文件后，签名必变 → 巡检触发重载
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kSimTrackFilePath error:NULL];
    NSDate *mtime = attrs[NSFileModificationDate];
    long long trackStamp = (long long)(mtime.timeIntervalSince1970 * 1000);
    return [NSString stringWithFormat:@"%@|%.6f|%.6f|%.2f|%@|%lld",
            [self _readPref:@"SimLocationMode"] ?: @"off",
            [self _readDouble:@"SimLocationLat" def:0.0],
            [self _readDouble:@"SimLocationLon" def:0.0],
            [self _readDouble:@"SimLocationAccuracy" def:5.0],
            [self _readPref:@"SimLocationSpeed"] ?: @"",
            trackStamp];
}

@end
