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
#import "TRSimContract.h" // 跨端定位契约（轨迹文件路径单一真相源，2026-08-28）
#import "TRAppDomain.h" // kTRAppPrefsSuiteName（跨端 prefs 域契约，2026-08-28）
#import "Logging.h"
#import <math.h>

// 轨迹点序列文件路径 → kTRSimTrackFilePath（TRSimContract.h 跨端单一真相源，2026-08-28）
// 配置 plist（mobile 域=配置源：App 写 mobile、uploadTrackPoints 也写 mobile；root 域仅兜底）
static NSString *const kSimMobilePrefsPath = @"/var/mobile/Library/Preferences/com.82flex.trollvnc.plist";
// 巡检间隔：失效检测 + 参数变更感知合一
static const NSTimeInterval kSimPatrolInterval = 10.0;
// prefs-changed 重载合并窗口：App 一次编辑链（holdAtCurrentPosition → 重算 → writeTrackFile）
// 连发多次通知，窗口内合并为一次重载（防热重载风暴，2026-08-27）
static const NSTimeInterval kSimReloadMergeInterval = 0.5;
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
    dispatch_source_t _reloadDebounce; // prefs-changed 重载合并（500ms 窗口）
    NSArray<NSDictionary *> *_trackPoints; // 轨迹点序列（内存缓存）
    NSUInteger _trackIndex;
    NSString *_lastParamsSig;          // 参数指纹（变更检测）
    BOOL _trackFinished;
    // anchor 基底
    double _anchorLat, _anchorLon, _anchorAcc;
    // 当前位置（每次注入后更新；供 status / 编排初始起点 / 失效恢复）
    double _currentLat, _currentLon, _currentSpeed, _currentCourse, _currentAcc, _currentAlt;
    NSString *_currentMode;
    // anchor 微动游走状态：相对中心偏移（米，局部平面近似）
    double _currentMx, _currentMy;
    uint64_t _lastWifiTileKey;   // 上次 wifi 反查的瓦片 key（跨瓦片才重反查，轨迹跟随）
    NSArray<TRWpsTileAP *> *_wifiTileAps; // 当前瓦片 AP 池（窗口注入源；跨瓦片/首点反查时刷新，2026-08-28）
    NSArray<NSString *> *_lastWifiWindowBssids; // 上次注入的可见 AP BSSID 集（变化才重注入，2026-08-28）
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
    // 启动一律停止态（2026-08-28 对齐 App readCurrentStatus 契约）：残留 anchor/itinerary 强制写 off——
    // manager（launchd 常驻，设备重启/崩溃即拉起）启动时若直接 reloadFromPrefs 会恢复上次模拟模式，
    // 设备重启后用户未打开 App 期间 locationd 自动注入模拟位置（系统其他 App 全部受影响）。
    // 宁可停止不自动模拟：模拟由用户显式开启（App 定位 UI），manager 重启（watchdog 拉起）同理不恢复。
    [self _forceStopOnStartup];
    [self reloadFromPrefs];
    [self _startPatrol];
}

/// 残留模拟模式强制 off（写 mobile 域 plist=配置源，对齐 App readCurrentStatus 语义）。
/// 幂等：仅当残留为 anchor/itinerary 时写 off；off 已是不变式。
- (void)_forceStopOnStartup {
    NSString *mode = [self _readPref:@"SimLocationMode"];
    if ([mode isEqualToString:@"anchor"] || [mode isEqualToString:@"itinerary"]) {
        NSMutableDictionary *mp = [NSMutableDictionary dictionaryWithContentsOfFile:kSimMobilePrefsPath] ?: [NSMutableDictionary dictionary];
        mp[@"SimLocationMode"] = @"off";
        [mp writeToFile:kSimMobilePrefsPath atomically:YES];
        TVLog(@"[locsim] startup: residual mode %@ forced -> off (startup-stop contract)", mode);
    }
    // 定位对抗编排：启动即关闭系统定位（宁停不漏）——off 期间真实坐标不得裸奔；
    // 模拟由用户在 App 显式开启（开启链路会先注入再重开开关）
    [SimLocationManager setSystemLocationServices:NO];
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

/// prefs-changed 通知入口（合并窗口）：App 一次编辑链连发多次通知（hold → 重算 → writeTrack），
/// 每次立即全量重载造成热重载风暴（曾每 1-2s 一波 stop+start+wifi 重注）——
/// 500ms 窗口内合并为一次 reload；重算耗时 > 窗口时 hold 先生效、轨迹后生效（语义不变）
- (void)scheduleReloadFromPrefs {
    if (_reloadDebounce) {
        dispatch_source_cancel(_reloadDebounce);
    }
    _reloadDebounce = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_reloadDebounce,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSimReloadMergeInterval * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 0);
    __weak __typeof__(self) weakSelf = self;
    dispatch_source_set_event_handler(_reloadDebounce, ^{
        [weakSelf reloadFromPrefs];
    });
    dispatch_resume(_reloadDebounce);
}

#pragma mark - 状态机

- (void)applyFromPrefs {
    NSString *mode = [self _readPref:@"SimLocationMode"];
    if (![mode isKindOfClass:[NSString class]] || mode.length == 0) mode = @"off";
    TVLog(@"[locsim] apply mode=%@", mode);
    if ([mode isEqualToString:@"off"]) {
        // 定位对抗编排（2026-08-28）：关模拟=先关系统定位（宁无位置不漏真实）→ 再停注入
        [SimLocationManager setSystemLocationServices:NO];
        [self _stopAnchor];
        [self _stopTrack];
        _currentMode = @"off";
        _lastWifiTileKey = 0; // 防残留：off 后重启时首点必重新触发反查
        [[SimLocationManager sharedManager] stopAll]; // 总停：GPS + wifi 一并恢复真实
    } else if ([mode isEqualToString:@"anchor"]) {
        double lat = [self _readDouble:@"SimLocationLat" def:0.0];
        double lon = [self _readDouble:@"SimLocationLon" def:0.0];
        double acc = [self _readDouble:@"SimLocationAccuracy" def:5.0];
        if (acc < 3.0) acc = 3.0;
        if (acc > 15.0) acc = 15.0;
        if ([_currentMode isEqualToString:@"anchor"] && _anchorSource) {
            // anchor→anchor 坐标更新（编辑 hold 微差/挪锚点）：平移游走中心，不重启——
            // 全量重启会重置游走状态回中闪跳 + wifi 完整重注，是编辑热重载风暴主因（2026-08-27）
            if (lat != _anchorLat || lon != _anchorLon || acc != _anchorAcc) {
                _anchorLat = lat;
                _anchorLon = lon;
                _anchorAcc = acc;
                _currentAcc = acc;
                // 平移后当前位置立即跟随（下一 tick 前注入一次，防空窗）
                _currentLat = _anchorLat + _currentMy / 111320.0;
                _currentLon = _anchorLon + _currentMx / (111320.0 * cos(_anchorLat * M_PI / 180.0));
                [self _injectSimulationForCurrentLocation]; // 统一注入：wifi 窗口 + GPS 收尾（同一坐标两路）
                TVLog(@"[locsim] anchor shift (%.5f, %.5f)", lat, lon);
            }
        } else {
            // 位置基底：中心点 + 微动游走（拟人必需，完全静止坐标像假 GPS）
            [self _stopTrack];
            [self _startAnchor];
        }
    } else if ([mode isEqualToString:@"itinerary"]) {
        // 动作序列：轨迹文件逐秒推进（重载后从当前注入位置最近点续播，不从头重放）
        [self _stopAnchor];
        [self _startTrack];
    } else {
        TVLog(@"[locsim] unknown mode=%@ -> off", mode);
        [SimLocationManager setSystemLocationServices:NO];
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
    _currentAcc = acc;
    _currentAlt = 45.0;
    [self _injectGpsForCurrentLocation]; // GPS 处理器：锚点坐标立即直写广播（首次注入）
    [self _injectWifiSimulationForCurrentLocation]; // wifi 处理器：锚点坐标反查换池（首次；反查成功后统一注入）
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
    // 定位对抗编排：注入已生效（首点已进 locationd 会话）后才开系统定位——
    // 定位开启的第一秒就是模拟值，无真实坐标空窗（2026-08-28）
    [SimLocationManager setSystemLocationServices:YES];
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
    _currentAcc = _anchorAcc;
    // 统一注入动作：GPS 与 wifi 是同一微动位置的两路输出——wifi 在前、GPS 收尾
    // （2026-08-28 用户定案：GPS 直写坐标、wifi 写 AP，同一坐标两个处理器，同 tick 完成）
    [self _injectSimulationForCurrentLocation];
    // anchor 跨瓦片 wifi 跟随（对齐 itinerary _trackTick 语义）：
    // anchor 中心平移（挪锚点/编辑 hold）跨瓦片时自动重反查 BSSID 注入；同瓦片零成本（key 比较）
    [self _checkWifiTileChangedAndReinject];
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
            // 反查失败/空（空洞瓦片 404 等）：保持现状不打断已有 wifi 模拟；
            // 无负缓存——失败重试节奏由巡检区分"曾成功/从未成功"控制（2026-08-27 定案）
            TVLog(@"[locsim] tile query skipped: %@", error.localizedDescription ?: @"no APs");
            // 从未成功（起点即空洞，远程伪装场景）：不注入会让 locationd 的 wifi 源回落为
            // 设备本地真实扫描（GPS=模拟 vs wifi=本地，数百公里级不自洽）——螺旋找最近有效瓦片
            // 注入邻近指纹（偏差 1-10km，次优但最优解，2026-08-28 定案）
            if (![SimLocationManager sharedManager].wasWifiSimulatingOnce) {
                TVLog(@"[locsim] start in empty tile, spiral to nearest valid tile");
                [TRWpsTile queryNearestBssidsForCoordinate:coord maxAttempts:24 completion:^(NSArray<TRWpsTileAP *> *nearAps, NSError *nearErr) {
                    __strong __typeof__(self) sSelf = weakSelf;
                    if (!sSelf) return;
                    if (nearErr || nearAps.count == 0) {
                        // 周边 24 瓦片全空洞：保持不注入（真实设备在此同样查不到 wloc 指纹）
                        TVLog(@"[locsim] spiral fallback also empty, keep no wifi (real-device behavior)");
                        return;
                    }
                    // 螺旋找到邻近有效瓦片：缓存为窗口池 + 统一注入（wifi 窗口 + GPS 收尾，同一坐标两路，2026-08-28）
                    sSelf->_wifiTileAps = nearAps;
                    sSelf->_lastWifiWindowBssids = nil; // 换池：变化检测失效，首窗口强制重注
                    [sSelf _injectSimulationForCurrentLocation];
                }];
            }
            // 曾成功但当前反查失败（跨入新空洞瓦片/网络抖动）：无需保活重注——统一注入下
            // _wifiTileAps 旧池每 tick 继续供窗口注入，wifi 源天然不断供（lastScan 重注是
            // 旧低频注入架构的补丁，2026-08-28 统一注入后删除）；旧池持续到跨瓦片反查成功换新
            return;
        }
        // 缓存瓦片 AP 池（窗口注入源）并统一注入（wifi 窗口 + GPS 收尾，同一坐标两路，
        // 2026-08-28 用户定案）——可见 AP=位置附近、GPS=同一坐标直写，模拟真实设备移动时
        // 可见集渐变且 GPS 持续广播（不再"前 100 一批播到跨瓦片"/wifi 独立节拍）
        strongSelf->_wifiTileAps = aps;
        strongSelf->_lastWifiWindowBssids = nil; // 换池：变化检测失效，首窗口强制重注
        [strongSelf _injectSimulationForCurrentLocation];
    }];
}

/// 统一注入动作（2026-08-28 用户定案）：GPS 与 wifi 是同一"当前位置坐标集"的两路输出——
/// ① wifi 处理器（写 AP：从瓦片池按当前坐标取可见 AP 窗口注入）
/// ② GPS 处理器（直写坐标：完整重启广播当前坐标）
/// 次序 wifi 在前、GPS 收尾：wifi 重启瞬间可能打断同会话 GPS 广播，紧后 GPS 注入同 tick 恢复——
/// 无真空、无独立兜底（对应用户"不要补丁式兜底，注入动作本身合一"）
- (void)_injectSimulationForCurrentLocation {
    [self _injectWifiWindowForCurrentLocation]; // ① wifi 处理器：当前坐标 → 可见 AP 窗口注入
    [self _injectGpsForCurrentLocation];        // ② GPS 处理器：当前坐标直写完整重启（收尾）
}

/// GPS 处理器：当前模拟坐标直写（完整重启广播；无当前位置则跳过——"无 GPS 仅 wifi"语义）。
/// acc 取 _currentAcc（itinerary=轨迹点 acc 3~15、anchor=锚点 acc，游走 tick 已同步）
- (void)_injectGpsForCurrentLocation {
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(_currentLat, _currentLon);
    if (coord.latitude == 0 && coord.longitude == 0) return; // 无当前位置
    [[SimLocationManager sharedManager] injectPoint:coord
                                           altitude:_currentAlt > 0 ? _currentAlt : 45.0
                                           accuracy:_currentAcc
                                             course:_currentCourse
                                              speed:_currentSpeed];
}

/// wifi 处理器：按当前模拟位置对缓存瓦片 AP 池做距离窗口注入（可见 AP 渐变；不重新反查）。
/// 池由路线/锚点确定时反查预取（跨瓦片/首点换池）；播放期只取窗口，无实时网络。
/// 变化检测：BSSID 集未变（静止/微动未跨出可见阈值）则跳过注入——统一注入动作下 wifi
/// 与 GPS 同 tick 跑，但 wifi 完整重启成本高（stopWifiSimulation→set→start），集不变不重启，
/// 消除"每 tick 全量 wifi 重启"（2026-08-28：用户定案统一注入 + 此节流）
- (void)_injectWifiWindowForCurrentLocation {
    if (_wifiTileAps.count == 0) return;
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(_currentLat, _currentLon);
    if (coord.latitude == 0 && coord.longitude == 0) return; // 无当前位置
    NSArray<TRWpsTileAP *> *winAps = [TRWpsTile windowApsByDistance:_wifiTileAps center:coord window:kTRWpsWindowSize];
    if (winAps.count == 0) return;
    NSArray<NSString *> *bssids = [TRWpsTile sampleBssidsFromAPs:winAps max:100];
    if (_lastWifiWindowBssids && [bssids isEqualToArray:_lastWifiWindowBssids]) return; // 可见集未变：不重注入
    NSArray *scanResults = [SimLocationManager buildScanResultsFromBssidStrings:bssids];
    if (scanResults.count) {
        _lastWifiWindowBssids = bssids;
        [[SimLocationManager sharedManager] injectWifiScanResults:scanResults];
        TVLog(@"[locsim] wifi window inject, %lu APs (visible)", (unsigned long)scanResults.count);
    }
}

/// BSSID 采样已上移 TRWpsTile sampleBssidsFromAPs:（共享原语，2026-08-28）

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
        TVLog(@"[locsim] track file empty/missing: %@", kTRSimTrackFilePath);
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
    // 首点：更新当前位置 + 统一注入（wifi 池未建→GPS 直写先行；随后反查换池，成功回调统一注入收尾）
    [self _updateCurrentFromPoint:points[startIdx]];
    [self _injectSimulationForCurrentLocation];
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
    // 定位对抗编排：同 anchor——注入生效后再开系统定位（2026-08-28）
    [SimLocationManager setSystemLocationServices:YES];
    TVLog(@"[locsim] itinerary start, %lu points (from idx %lu)", (unsigned long)points.count, (unsigned long)startIdx);
}

- (void)_trackTick {
    if (_trackIndex >= _trackPoints.count) {
        [self _stopTrack]; // 完成：停 timer，保持终点坐标（不调 stop）
        TVLog(@"[locsim] itinerary finished, keep final point");
        return;
    }
    [self _updateCurrentFromPoint:_trackPoints[_trackIndex++]];
    // 统一注入动作：GPS 与 wifi 是同一播放（轨迹/锚点坐标）的两路输出——wifi 在前、GPS 收尾
    // （2026-08-28 用户定案：wifi 不要独立实时节拍，加入 GPS 完整时序；wifi 重启打断的 GPS
    // 广播由同 tick 紧后的 GPS 注入立即恢复，无真空无兜底）
    [self _injectSimulationForCurrentLocation];
    // 轨迹 wifi 跟随：跨瓦片才重新反查换池（同瓦片 LRU 命中零成本；反查池成功后同 tick 注入）
    [self _checkWifiTileChangedAndReinject];
}

/// 检测当前坐标瓦片是否变化，跨瓦片则重新 wifi 动态反查注入（轨迹跟随）
/// 共享原语 TRWpsTile tileChangedForCoordinate:（App/daemon 同源，2026-08-28）
- (void)_checkWifiTileChangedAndReinject {
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(_currentLat, _currentLon);
    if (coord.latitude == 0 && coord.longitude == 0) return; // 无当前位置
    uint64_t newKey = 0;
    if (![TRWpsTile tileChangedForCoordinate:coord previous:_lastWifiTileKey newKey:&newKey]) return; // 同瓦片：不重反查（LRU 已覆盖）
    _lastWifiTileKey = newKey;
    [self _injectWifiSimulationForCurrentLocation];
}

/// 轨迹点 → 更新当前位置状态（供统一注入动作 GPS/wifi 处理器消费；不注入——注入统一走
/// _injectSimulationForCurrentLocation，2026-08-28 用户定案"同一坐标两路输出，动作合一"）
- (void)_updateCurrentFromPoint:(NSDictionary *)p {
    double lat = [p[@"lat"] doubleValue];
    double lon = [p[@"lon"] doubleValue];
    double acc = [p[@"acc"] doubleValue];
    if (acc < 3.0) acc = 3.0;
    if (acc > 15.0) acc = 15.0;
    _currentLat = lat;
    _currentLon = lon;
    _currentAcc = acc;
    _currentSpeed = [p[@"speed"] doubleValue];
    _currentCourse = [p[@"course"] doubleValue];
    _currentAlt = [p[@"alt"] doubleValue] > 0 ? [p[@"alt"] doubleValue] : 45.0;
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
    NSData *data = [NSData dataWithContentsOfFile:kTRSimTrackFilePath];
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
    NSString *tmp = [kTRSimTrackFilePath stringByAppendingString:@".tmp"];
    NSError *werr = nil;
    if (![json writeToFile:tmp options:NSDataWritingAtomic error:&werr]) {
        if (error) *error = werr ?: [NSError errorWithDomain:@"SimLoc" code:5 userInfo:@{NSLocalizedDescriptionKey:@"轨迹临时文件写入失败"}];
        return NO;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:kTRSimTrackFilePath]) {
        [[NSFileManager defaultManager] removeItemAtPath:kTRSimTrackFilePath error:NULL];
    }
    if (![[NSFileManager defaultManager] moveItemAtPath:tmp toPath:kTRSimTrackFilePath error:&werr]) {
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
            // 定位对抗编排：异常期间先关系统定位（无真实值可出）→ 重注入生效后再开
            [SimLocationManager setSystemLocationServices:NO];
            TVLog(@"[locsim] anchor lost, re-start");
            [self _startAnchor];
        } else if (![SimLocationManager sharedManager].isWifiSimulating && [SimLocationManager sharedManager].wasWifiSimulatingOnce) {
            // wifi 曾成功但当前丢失（locationd 会话中断）→ 重反查换池（2026-08-28 定案：
            // 原条件 isSimulating && wasWifiSimulatingOnce 在 GPS 正常+曾成功时恒真 → 每 10s
            // 无条件重反查，曾致"每 10s 报 wifi lost"假象；改为仅 wifi 源确实丢失才触发）。
            // 从未成功（空洞瓦片反查失败）不重试——重注无意义且造成"自我锁死循环"；
            // 等轨迹跨瓦片（_lastWifiTileKey 变化）自然换源反查（2026-08-27 定案）
            TVLog(@"[locsim] anchor wifi lost, re-query");
            [self _injectWifiSimulationForCurrentLocation];
        }
    } else if ([mode isEqualToString:@"itinerary"]) {
        // 已完成（停在终点）不重播：仅播放中 timer 丢失才重启；进度不持久化，进程重启后从头播
        if (!_trackFinished && !_trackSource) {
            TVLog(@"[locsim] itinerary timer lost, restart");
            [self _startTrack];
        } else if (![SimLocationManager sharedManager].isWifiSimulating && [SimLocationManager sharedManager].wasWifiSimulatingOnce) {
            // 同上：仅"曾成功但丢失"重反查；"从未成功"（空洞瓦片）安静等待跨瓦片换源
            TVLog(@"[locsim] itinerary wifi lost, re-query");
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
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    return [d objectForKey:key];
}

- (double)_readDouble:(NSString *)key def:(double)def {
    id v = [self _readPref:key];
    if ([v respondsToSelector:@selector(doubleValue)]) return [v doubleValue];
    return def;
}

- (NSString *)_paramsSignature {
    // 轨迹 mtime 仅 itinerary 纳入指纹（它才消费轨迹文件）——anchor/off 态下轨迹重写
    // （编辑重算期间）不触发 anchor 无谓重启（热重载风暴成因之一，2026-08-27）
    NSString *mode = [self _readPref:@"SimLocationMode"] ?: @"off";
    long long trackStamp = 0;
    if ([mode isEqualToString:@"itinerary"]) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kTRSimTrackFilePath error:NULL];
        NSDate *mtime = attrs[NSFileModificationDate];
        trackStamp = (long long)(mtime.timeIntervalSince1970 * 1000);
    }
    return [NSString stringWithFormat:@"%@|%.6f|%.6f|%.2f|%@|%lld",
            mode,
            [self _readDouble:@"SimLocationLat" def:0.0],
            [self _readDouble:@"SimLocationLon" def:0.0],
            [self _readDouble:@"SimLocationAccuracy" def:5.0],
            [self _readPref:@"SimLocationSpeed"] ?: @"",
            trackStamp];
}

@end
