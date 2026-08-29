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
#import "TRWifiKnownNetworks.h" // 软路由联动：已知网络条目 SSID 修改（2026-08-29）
#import "TRWpsTile.h" // 坐标→BSSID 动态反查（daemon 注入 wifi 模拟源）
#import "TRSimContract.h" // 跨端定位契约（轨迹文件路径单一真相源，2026-08-28）
#import "TRAppDomain.h" // kTRAppPrefsSuiteName（跨端 prefs 域契约，2026-08-28）
#import "Logging.h"
#import <math.h>

// 轨迹点序列文件路径 → kTRSimTrackFilePath（TRSimContract.h 跨端单一真相源，2026-08-28）
// 配置 plist（mobile 域=配置源：App 写 mobile、uploadTrackPoints 也写 mobile；root 域仅兜底）
static NSString *const kSimMobilePrefsPath = @"/var/mobile/Library/Preferences/com.82flex.trollvnc.plist";
// 模拟状态持久化文件（L3' 崩溃恢复，2026-08-29）：{mode, anchorLat/Lon/Acc, mx, my, lastRefresh}
// 崩溃后新 manager 据此恢复播放（复用轨迹文件"文件即状态"机制）；与轨迹文件并列
static NSString *const kSimStateFilePath = @"/var/mobile/Library/Preferences/com.82flex.trollvnc.simstate.json";
// 巡检间隔（已移除 2026-08-29：配置驱动 + L3' + L4 哨兵 + 启动兜底已覆盖）
// prefs-changed 重载合并窗口：App 一次编辑链（holdAtCurrentPosition → 重算 → writeTrackFile）
// 连发多次通知，窗口内合并为一次重载（防热重载风暴，2026-08-27）
static const NSTimeInterval kSimReloadMergeInterval = 0.5;
// track 逐点注入间隔（itinerary：1s/点）
static const NSTimeInterval kSimTrackTickInterval = 1.0;
// anchor 节拍间隔（1s/拍）
static const NSTimeInterval kSimAnchorTickInterval = 1.0;
// anchor 微动范围（米）：人在原地附近小幅活动（5~50m 随机取，这里取中位）
static const double kSimAnchorRangeM = 20.0;
// 拟人化（2026-08-29 漂移问题修复）：真人 95% 时间静止在一点——
// ①静止期低频注入刷新 timestamp（30~60s 一次，同坐标新时间戳，防"1小时前fix"指纹）
// ②偶发小迁移（3~10min 一次，5~20m 内新点，模拟在房间间走动/起身）
static const NSTimeInterval kSimAnchorRefreshInterval = 45.0;   // 静止刷新间隔（s）
static const NSTimeInterval kSimAnchorMoveMinGap = 180.0;       // 小迁移最小间隔（s）
static const double kSimAnchorMoveProbPerTick = 0.002;           // 每次拍迁移概率（≈3~8min 一次）

@implementation SimLocationController {
    // dispatch_source_t _patrolSource; 已移除（2026-08-29 配置驱动覆盖）
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
    // 拟人化节拍（2026-08-29）：静止刷新/小迁移计时
    uint64_t _anchorTickCount;
    CFAbsoluteTime _anchorLastRefreshAt;
    CFAbsoluteTime _anchorLastMoveAt;
    // 崩溃恢复标记（L3'）：_forceStopOnStartup 恢复状态后置位，_startAnchor 消费（保留游走偏移）
    BOOL _restorePending;
    uint64_t _trackTickCount;   // itinerary 落盘节流（每 5 tick 持久化一次）
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
    // 旧巡检（10s 轮询 _checkRestore）已移除（2026-08-29 定案：配置驱动 + L3' + L4 哨兵 + 启动兜底已覆盖）
}

/// 启动定位处理（2026-08-29 定案）：先关定位（安全基底）→ 再根据状态决定是否恢复模拟
/// 用户定案：宁停不漏；恢复模拟由后续 reload→apply→_startAnchor 统一完成
- (void)_forceStopOnStartup {
    // ① 读系统定位当前状态（诊断）
    BOOL sysLocON = [CLLocationManager locationServicesEnabled];
    TVLog(@"[locsim] startup: system location = %@", sysLocON ? @"ON" : @"OFF");
    // ② 先关定位（确定安全状态；setSystemLocationServices: 内部幂等：已关则跳过）
    [SimLocationManager setSystemLocationServices:NO];

    NSString *mode = [self _readPref:@"SimLocationMode"];
    NSDictionary *state = [SimLocationController loadPersistedState];
    // ③ 可恢复 anchor → 恢复游走偏移，标记 pending（reload→apply→_startAnchor 统一完成注入+开定位）
    if ([mode isEqualToString:@"anchor"] && state && [state[@"mode"] isEqualToString:@"anchor"]) {
        _anchorLat = [state[@"anchorLat"] doubleValue];
        _anchorLon = [state[@"anchorLon"] doubleValue];
        _anchorAcc = [state[@"anchorAcc"] doubleValue];
        _currentMx = [state[@"mx"] doubleValue];
        _currentMy = [state[@"my"] doubleValue];
        _currentLat = _anchorLat + _currentMy / 111320.0;
        _currentLon = _anchorLon + _currentMx / (111320.0 * cos(_anchorLat * M_PI / 180.0));
        _currentMode = @"anchor";
        _currentAcc = _anchorAcc;
        _restorePending = YES;
        TVLog(@"[locsim] startup: state restored, pending re-start (%.5f, %.5f)", _anchorLat, _anchorLon);
        return;   // 定位已关；reload→apply→_startAnchor 将注入+开定位
    }
    // ④ itinerary：放行 reload 恢复（轨迹文件驱动）
    if ([mode isEqualToString:@"itinerary"]) {
        TVLog(@"[locsim] startup: itinerary mode, allowing reload to restore playback");
        return;   // 定位已关；reload 恢复播放
    }
    // ⑤ 无可恢复状态 → 保持关闭（定位已在②关掉）
    if ([mode isEqualToString:@"anchor"] || [mode isEqualToString:@"itinerary"]) {
        // 预置 off 写回（防 _readPref 双域不一致）
        NSMutableDictionary *mp = [NSMutableDictionary dictionaryWithContentsOfFile:kSimMobilePrefsPath] ?: [NSMutableDictionary dictionary];
        mp[@"SimLocationMode"] = @"off";
        [mp writeToFile:kSimMobilePrefsPath atomically:YES];
        TVLog(@"[locsim] startup: residual mode %@ forced -> off (startup-stop contract)", mode);
    }
    // 定位已在②关掉，无需额外动作
}

- (void)reloadFromPrefs {
    NSString *sig = [self _paramsSignature];
    if (_lastParamsSig && [sig isEqualToString:_lastParamsSig]) {
        return;   // 参数未变：跳过（旧巡检已移除，配置驱动 notify 覆盖）
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
    if (!_restorePending) {
        _currentMx = 0.0;
        _currentMy = 0.0;
    }
    _restorePending = NO;
    _anchorTickCount = 0;
    _anchorLastRefreshAt = CFAbsoluteTimeGetCurrent();
    _anchorLastMoveAt = CFAbsoluteTimeGetCurrent();   // 启动即开始计时（首次迁移 3~8min 后）
    // 首点注入前必须同步 _current（否则用残留值/0 坐标注入，蓝点闪跳）
    _currentLat = lat;
    _currentLon = lon;
    _currentSpeed = 0.0;
    _currentCourse = 0.0;
    _currentMode = @"anchor";
    _currentAcc = acc;
    _currentAlt = 45.0;
    [self _injectGpsForCurrentLocation]; // GPS 处理器：锚点坐标立即直写广播（首次注入）
    [self _handleAPSwitchForCurrentLocation]; // wifi 处理器：锚点坐标反查 → 下发软路由切换（首次）
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
    // L3 场景持久化（实验）：模拟状态写入 locationd 场景文件，目标=脱离 manager 生命周期
    // （client 崩溃后 locationd 仍投递最后模拟坐标，覆盖崩溃→拉起窗口）；失败仅日志不影响主链路
    TVLog(@"[locsim] anchor start (%.5f, %.5f) acc=%.1f", lat, lon, acc);
}

- (void)_anchorTick {
    // 拟人化锚点（2026-08-29 漂移问题修复）：真人"静止为主"——
    // 默认不注入（蓝点静止，locationd 重复投递最后 fix），仅两类事件触发注入：
    //  ① 静止刷新（45s）：同坐标重注入（时间戳保鲜，防"1 小时前 fix"指纹）
    //  ② 偶发小迁移（3~8min 一次概率）：5~20m 内新点（房间间走动/起身），迁移后静止
    // 彻底去除"每秒连续微动爬行"（旧实现每秒动 0.1~0.5m = 不自然的永动漂移）
    _anchorTickCount++;
    BOOL shouldMove = (_anchorLastMoveAt == 0)
        ? (arc4random_uniform(1000) < 50)   // 首个迁移点稍快出现（启动后 1~2min）
        : (arc4random_uniform(10000) < (uint32_t)(kSimAnchorMoveProbPerTick * 10000));
    if (shouldMove &&
        (CFAbsoluteTimeGetCurrent() - _anchorLastMoveAt) >= kSimAnchorMoveMinGap) {
        // 小迁移：在 anchor 中心 5~20m 内取新偏移点（不连续漂移，直接落点）
        double r = 5.0 + (double)(arc4random_uniform(1500)) / 100.0;  // 5~20m
        double ang = (double)(arc4random_uniform(62832)) / 10000.0;
        _currentMx = cos(ang) * r;
        _currentMy = sin(ang) * r;
        _anchorLastMoveAt = CFAbsoluteTimeGetCurrent();
        [self _commitAnchorPoint];
        [self _handleAPSwitchForCurrentLocation];   // 迁移/首点后重新反查 → AP 切换
        return;
    }
    if ((CFAbsoluteTimeGetCurrent() - _anchorLastRefreshAt) >= kSimAnchorRefreshInterval) {
        // 静止刷新：同坐标重注入（timestamp 保鲜）
        _anchorLastRefreshAt = CFAbsoluteTimeGetCurrent();
        [self _commitAnchorPoint];
    }
}

/// anchor 当前点提交：按当前游走偏移计算坐标并注入（GPS 单路；wifi 由调用方按需触发）
- (void)_commitAnchorPoint {
    double lat = _anchorLat + _currentMy / 111320.0;
    double lon = _anchorLon + _currentMx / (111320.0 * cos(_anchorLat * M_PI / 180.0));
    _currentLat = lat;
    _currentLon = lon;
    _currentSpeed = 0.0;                 // 静止：速度 0（真人在家无 GPS 速度）
    _currentCourse = 0.0;
    _currentMode = @"anchor";
    _currentAcc = _anchorAcc;
    [self _injectGpsForCurrentLocation];
    [self _persistState];   // 状态落盘（崩溃恢复用；45s 低频写，无 I/O 压力）
}

/// 统一目标位置源：wifi 扫描模拟与 GPS 同源注入（动态反查——按当前坐标 tile 查 BSSID 注入）
/// 设计文档 §坐标→SSID 反查：动态+预取混合；轨迹移动时随 _current 变化
/// 真机验证点：
/// 1. injectPoint: 的 clearSimulatedLocations 是否连带清 wifi 模拟（若会则需注入后兜底重注）
/// 2. 总开关关闭后 GPS + wifi 是否都恢复真实（5902 日志确认）
- (void)_handleAPSwitchForCurrentLocation {
    // 2026-08-29 软路由联动：反查 AP 列表（空洞螺旋保留）→ 最近 AP → 下发软路由切换
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(_currentLat, _currentLon);
    if (coord.latitude == 0 && coord.longitude == 0) return;
    [[TRWpsTile sharedClient] queryBssidsForCoordinate:coord force:NO completion:^(NSArray<TRWpsTileAP *> *aps, NSError *error) {
        if (error || aps.count == 0) {
            TVLog(@"[locsim] tile query skipped: %@", error.localizedDescription ?: @"no APs");
            if (![SimLocationManager sharedManager].wasWifiSimulatingOnce) {
                TVLog(@"[locsim] start in empty tile, spiral to nearest valid tile");
                [TRWpsTile queryNearestBssidsForCoordinate:coord maxAttempts:24 completion:^(NSArray<TRWpsTileAP *> *nearAps, NSError *nearErr) {
                    if (!nearErr && nearAps.count) [self _handleAPList:nearAps atCoord:coord];
                }];
            }
            return;
        }
        [self _handleAPList:aps atCoord:coord];
    }];
}

/// AP 列表处理：按距离取最近 AP → 下发软路由切换（已知网络条目修改在回调后）
- (void)_handleAPList:(NSArray<TRWpsTileAP *> *)aps atCoord:(CLLocationCoordinate2D)coord {
    TRWpsTileAP *nearest = aps[0];
    double best = DBL_MAX;
    for (TRWpsTileAP *ap in aps) {
        double d = [SimRouteCalculator haversineMeters:coord to:ap.coord];
        if (d < best) { best = d; nearest = ap; }
    }
    static NSString *sLastAPBSSID = nil;
    if (sLastAPBSSID && [sLastAPBSSID isEqualToString:nearest.bssid]) return; // 同 AP 不重复下发
    sLastAPBSSID = nearest.bssid;
    NSString *targetSSID = [self _generateCitySSIDForBSSID:nearest.bssid];
    TVLog(@"[locsim] wifi-switch -> {ssid:%@ bssid:%@} d=%.0fm", targetSSID, nearest.bssid, best);
    // 下发前先取当前连接 SSID（软路由按它定位要改的 wireless 段；known-networks 也改它）
    NSString *curSSID = [TRWifiKnownNetworks currentSSID];
    NSString *curBSSID = [TRWifiKnownNetworks currentBSSID];
    if (!curSSID.length) { TVLog(@"[locsim] no current ssid (not associated?), skip switch"); return; }
    __weak __typeof__(self) weakSelf = self;
    [self _requestRouterSwitchSSID:targetSSID bssid:nearest.bssid currentSSID:curSSID currentBSSID:curBSSID completion:^(BOOL ok) {
        __strong __typeof__(self) sSelf = weakSelf;
        if (!sSelf) return;
        if (!ok) { TVLog(@"[locsim] router switch failed, skip known-networks"); return; }
        // AP 已改成功（回调）→ 改设备已知网络条目 SSID（用户定案时序：AP 先行，设备随后）
        if (![curSSID isEqualToString:targetSSID]) {
            NSError *err = nil;
            BOOL rn = [TRWifiKnownNetworks renameKnownNetworkSSID:curSSID to:targetSSID error:&err];
            TVLog(@"[locsim] known-networks rename %@->%@ : %@ %@",
                  curSSID, targetSSID, rn ? @"OK" : @"FAIL", err.localizedDescription ?: @"");
        }
    }];
}

/// 统一注入动作（2026-08-29 改造）：GPS 直写为主；wifi 处理器改为"软路由联动下发"——
/// ① wifi 处理器（新链路：反查 AP → 下发软路由改 {SSID,BSSID} → 改 known-networks → 设备重连）
/// ② GPS 处理器（直写坐标：完整重启广播当前坐标）
/// GPS 链路全程不受影响（anchor/itinerary 坐标注入独立保留）；wifi 注入扫描结果链路已移除
- (void)_injectSimulationForCurrentLocation {
    [self _handleAPSwitchForCurrentLocation];  // ① wifi 处理器：轨迹沿 AP 排列切换软路由
    [self _injectGpsForCurrentLocation];            // ② GPS 处理器：当前坐标直写完整重启（收尾）
}


/// SSID 生成：WPS 反查只有 BSSID 无 SSID——用"城市常见 SSID 风格池"按 BSSID 哈希取稳定名
- (NSString *)_generateCitySSIDForBSSID:(NSString *)bssid {
    static NSArray *kCitySSIDPool = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        kCitySSIDPool = @[@"CMCC-", @"ChinaNet-", @"ChinaUnicom-", @"Tenda_", @"TP-LINK_", @"HUAWEI-"];
    });
    // BSSID 后 3 段做哈希 → 稳定取池 + 随机后缀
    NSUInteger h = 0;
    for (NSUInteger i = 0; i < bssid.length; i++) h = h * 31 + [bssid characterAtIndex:i];
    NSString *prefix = kCitySSIDPool[h % kCitySSIDPool.count];
    NSString *suffix = [NSString stringWithFormat:@"%02X%02X", (unsigned)(h >> 16 & 0xFF), (unsigned)(h & 0xFF)];
    return [prefix stringByAppendingString:suffix];
}

/// 下发软路由：HTTP POST /cgi-bin/wifi-switch {current_ssid, current_bssid, target:{ssid,bssid}} → {ok}
/// （Superwrt uhttpd CGI：SSID+MAC 双定位 wireless 段（防同名歧义）→ uci 改 ssid+macaddr → wifi reload）
- (void)_requestRouterSwitchSSID:(NSString *)ssid bssid:(NSString *)bssid
                    currentSSID:(NSString *)curSSID currentBSSID:(NSString *)curBSSID
                       completion:(void (^)(BOOL ok))completion {
    NSString *routerURL = [self _readPref:@"SimRouterHTTP"];
    if (!routerURL.length) routerURL = @"http://10.0.0.1:8080/cgi-bin/wifi-switch.cgi"; // Superwrt uhttpd CGI（默认=用户部署路径；可配置覆盖）
    NSURL *url = [NSURL URLWithString:routerURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 15.0;   // wifi reload 断线重连 1-3s，放宽超时
    NSDictionary *body = @{
        @"current_ssid": curSSID ?: @"",
        @"current_bssid": curBSSID ?: @"",
        @"target": @{ @"ssid": ssid, @"bssid": bssid },
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    NSURLSession *sess = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [sess dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        BOOL ok = NO;
        if (!err && data.length) {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            ok = [j isKindOfClass:[NSDictionary class]] && [j[@"ok"] boolValue];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok); });
    }];
    [task resume];
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

/// wifi 处理器（旧：locationd 扫描输入注入）已于 2026-08-29 移除——
/// 抖音读的是「当前连接网络的 SSID/BSSID」（CNCopyCurrentNetworkInfo），不读扫描列表；
/// 扫描模拟被证伪为无用功。新链路：反查 AP → 下发软路由改 SSID/BSSID → 设备重连（见 _handleAPList）。

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
    [self _handleAPSwitchForCurrentLocation]; // 首点坐标反查（动态 tile 查 AP；跨瓦片重新反查，跟随 _current）
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
    if (++_trackTickCount % 5 == 0) [self _persistState];   // 每 5s 落盘（崩溃续播不丢太多）
    // 轨迹 wifi 跟随：跨瓦片才重新反查换池（同瓦片 LRU 命中零成本；反查池成功后同 tick 注入）
    [self _handleAPSwitchForCurrentLocation];   // 迁移/首点后重新反查 → AP 切换
}

/// 检测当前坐标瓦片是否变化，跨瓦片则重新反查并下发软路由 AP 切换（轨迹跟随，2026-08-29）
/// 共享原语 TRWpsTile tileChangedForCoordinate:（App/daemon 同源，2026-08-28）
- (void)_checkWifiTileChangedAndReinject {
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(_currentLat, _currentLon);
    if (coord.latitude == 0 && coord.longitude == 0) return; // 无当前位置
    uint64_t newKey = 0;
    if (![TRWpsTile tileChangedForCoordinate:coord previous:_lastWifiTileKey newKey:&newKey]) return; // 同瓦片：不重反查（LRU 已覆盖）
    _lastWifiTileKey = newKey;
    [self _handleAPSwitchForCurrentLocation];
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

#pragma mark - daemon.restart 升级通道（2026-08-28）

/// 持久化当前模拟状态（anchor 游走偏移 + 模式），崩溃恢复用（L3'，2026-08-29）
- (void)_persistState {
    if ([_currentMode isEqualToString:@"anchor"]) {
        NSDictionary *st = @{
            @"version": @1,
            @"mode": @"anchor",
            @"anchorLat": @(_anchorLat), @"anchorLon": @(_anchorLon), @"anchorAcc": @(_anchorAcc),
            @"mx": @(_currentMx), @"my": @(_currentMy),
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:st options:0 error:NULL];
        [json writeToFile:kSimStateFilePath atomically:YES];
    } else if ([_currentMode isEqualToString:@"itinerary"]) {
        // itinerary：存当前位置（_startTrack 的续播逻辑依赖 _current 找最近点；崩溃后恢复续播不从头跳变）
        NSDictionary *st = @{
            @"version": @1,
            @"mode": @"itinerary",
            @"lat": @(_currentLat), @"lon": @(_currentLon), @"acc": @(_currentAcc),
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:st options:0 error:NULL];
        [json writeToFile:kSimStateFilePath atomically:YES];
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:kSimStateFilePath error:NULL];
    }
}

/// 读取持久化状态（崩溃恢复）；无/损坏返回 nil
+ (NSDictionary *)loadPersistedState {
    NSData *data = [NSData dataWithContentsOfFile:kSimStateFilePath];
    if (!data.length) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

+ (void)forceOffAndReload {
    // 重启前停模拟：写 off 到 mobile 域 plist（配置源）→ reloadFromPrefs 走 off 分支
    // （先关系统定位再停注入，宁无位置不漏真实）；启动契约亦会兜底
    NSMutableDictionary *mp = [NSMutableDictionary dictionaryWithContentsOfFile:kSimMobilePrefsPath]
                                ?: [NSMutableDictionary dictionary];
    mp[@"SimLocationMode"] = @"off";
    [mp writeToFile:kSimMobilePrefsPath atomically:YES];
    [[SimLocationController sharedController] reloadFromPrefs];
    TVLog(@"[locsim] forceOffAndReload done (daemon restarting)");
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
