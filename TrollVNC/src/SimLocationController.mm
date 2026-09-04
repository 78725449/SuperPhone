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
#import <notify.h> // notify_post（WiFi 重连通知 App 更新水滴，2026-08-29）
// SCDynamicStore 动态符号解析由 TRWifiKnownNetworks.mm 兼容层提供（TVLoadSCDynamicStore；SDK 头标记 iOS 不可用但真机 dyld cache 存在，2026-08-30）
#import "TRWpsTile.h" // 坐标→BSSID 动态反查（daemon 注入 wifi 模拟源）
#import "TRSimContract.h" // 跨端定位契约（轨迹文件路径单一真相源，2026-08-28）
#import "TRAppDomain.h" // kTRAppPrefsSuiteName（跨端 prefs 域契约，2026-08-28）
#import "Logging.h"
#import <math.h>

// 轨迹文件路径常量已收敛至 TRSimContract.h（kTRSimTrackFilePath，App/daemon 共享，2026-08-28）
// 配置 plist（mobile 域=配置源：App 写 mobile 命令参数；root 域仅兜底）
static NSString *const kSimMobilePrefsPath = @"/var/mobile/Library/Preferences/com.82flex.trollvnc.plist";
// daemon 状态文件（daemon 独写，崩溃恢复注入位置+播放进度用，2026-08-30）：{currentPosition:{lat,lon,acc,seq,trackVersion}}
// 编排真相在 kTRSimTrackFilePath（App 独写 segments/points）；本文件只存注入进度，单一写入者无并发
static NSString *const kSimStateFilePath = @"/var/mobile/Library/Preferences/com.82flex.trollvnc.simstate.json";
// prefs-changed 重载合并窗口：App 一次编辑链（holdAtCurrentPosition → 重算 → writeTrackFile）
// 连发多次通知，窗口内合并为一次重载（防热重载风暴，2026-08-27）
static const NSTimeInterval kSimReloadMergeInterval = 0.5;
// track 逐点注入间隔（itinerary：1s/点）
static const NSTimeInterval kSimTrackTickInterval = 1.0;
// anchor 节拍间隔（1s/拍）
static const NSTimeInterval kSimAnchorTickInterval = 1.0;
// 拟人化（2026-08-29 漂移问题修复）：真人 95% 时间静止在一点——
// ①静止期低频注入刷新 timestamp（45s 一次，同坐标新时间戳，防"1小时前fix"指纹）
// ②偶发小迁移（3~8min 一次，5~20m 内新点，模拟在房间间走动/起身）
static const NSTimeInterval kSimAnchorRefreshInterval = 45.0;   // 静止刷新间隔（s）
static const NSTimeInterval kSimAnchorMoveMinGap = 180.0;       // 小迁移最小间隔（s）
static const double kSimAnchorMoveProbPerTick = 0.002;           // 每次拍迁移概率（≈3~8min 一次）

// private 前向声明（类方法在实现文件后部定义，先声明避免编译器警告）
@interface SimLocationController (Persist)
+ (NSDictionary *)loadPersistedPosition;
+ (CLLocationCoordinate2D)readPositionFromState:(NSDictionary *)state;
@end

@implementation SimLocationController {
    // dispatch_source_t _patrolSource; 已移除（2026-08-29 配置驱动覆盖）
    dispatch_source_t _trackSource;    // itinerary 逐点注入
    dispatch_source_t _anchorSource;   // anchor 微动游走
    dispatch_source_t _reloadDebounce; // prefs-changed 重载合并（500ms 窗口）
    NSArray<NSDictionary *> *_trackPoints; // 轨迹点序列（内存缓存）
    NSUInteger _trackIndex;
    NSUInteger _currentSeq;          // 当前注入点的 seq（数据源排序，2026-08-30：恢复 O(1) 定位续播，独立维护非 _trackIndex）
    NSUInteger _currentTrackVersion; // 当前播放轨迹的版本号（trackVersion，区分新旧轨迹）
    NSUInteger _persistedSeq;        // 上次持久化的 seq（恢复时校验用）
    NSUInteger _persistedTrackVersion; // 上次持久化的轨迹版本（恢复时校验用）
    NSString *_lastParamsSig;          // 参数指纹（变更检测）
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
    uint64_t _lastWifiTileKey;   // 上次 wifi 反查的瓦片 key（跨瓦片才重反查，轨迹跟随）
    NSString *_wifiTargetBSSID;   // WiFi 重连监听目标 BSSID（SCDynamicStore 键变化比对，匹配即清理，2026-08-30 去兜底）
    TVSCDynamicStoreRef _wifiStore; // WiFi 重连监听 store（SCDynamicStore 键变化回调，2026-08-30 替代 1s 轮询）
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
    // 启动契约（2026-08-28 起；daemon 由 launchd/watchdog 拉起 = 崩溃/设备重启恢复场景）：
    // _forceStopOnStartup 先关系统定位（安全基底）→ 注入上次位置（simstate.json，位置连续）→
    // 残留 itinerary（崩溃前播放中）放行恢复播放；anchor/off 归停止态。
    // 与 App 侧契约不对称：App 重启 = readCurrentStatus 强制 off（宁停不漏，模拟由用户显式开启）；
    // daemon 重启 = 恢复（App 可能仍在前台播放，崩溃恢复语义）。
    [self _forceStopOnStartup];
    [self reloadFromPrefs];
}

/// 启动定位处理（2026-08-29 定案）：先关定位（安全基底）→ 注入上次位置 → 根据残留模式决定是否恢复播放
/// 宁停不漏的落点 = App 启动强制 off；daemon 启动对 itinerary 放行（崩溃恢复），anchor 无进度可恢复 → off
- (void)_forceStopOnStartup {
    // ① 读系统定位当前状态（诊断）
    BOOL sysLocON = [CLLocationManager locationServicesEnabled];
    TVLog(@"[locsim] startup: system location = %@", sysLocON ? @"ON" : @"OFF");
    // ② 先关定位（确定安全状态；setSystemLocationServices: 内部幂等：已关则跳过）
    [SimLocationManager setSystemLocationServices:NO];

    // ③ 读 daemon 状态文件，注入上次注入位置（有则注入，确保注入始终跑——即使不恢复播放；
    // 位置连续：崩溃后注入上次位置而非 0,0/真实位置；位置真相=daemon 写回的注入进度）
    NSDictionary *state = [SimLocationController loadPersistedPosition];
    CLLocationCoordinate2D statePos = [SimLocationController readPositionFromState:state];
    if (CLLocationCoordinate2DIsValid(statePos)) {
        _currentLat = statePos.latitude;
        _currentLon = statePos.longitude;
        _currentAcc = [state[@"currentPosition"][@"acc"] doubleValue];
        if (_currentAcc < 3.0) _currentAcc = 5.0;
        // 恢复 seq/trackVersion（数据源排序续播锚点：_startTrack 比对当前轨迹版本，一致用 seq 精确定位）
        NSDictionary *cp = state[@"currentPosition"];
        _persistedSeq = [cp[@"seq"] unsignedIntegerValue];
        _persistedTrackVersion = [cp[@"trackVersion"] unsignedIntegerValue];
        _currentSeq = _persistedSeq;
        [self _injectGpsForCurrentLocation];
        TVLog(@"[locsim] startup: injected persisted position (%.5f, %.5f) seq=%lu ver=%lu",
              statePos.latitude, statePos.longitude, (unsigned long)_persistedSeq, (unsigned long)_persistedTrackVersion);
    } else {
        TVLog(@"[locsim] startup: no persisted position, no injection (first launch / no record)");
    }

    // ④ 残留模式处理：itinerary = 崩溃前播放中 → 放行（后续 start 的 reloadFromPrefs 恢复续播）；
    NSString *mode = [self _readPref:@"SimLocationMode"];
    if ([mode isEqualToString:@"itinerary"]) {
        TVLog(@"[locsim] startup: itinerary mode, allowing reload to restore playback");
        return;   // 定位已关；reload 恢复播放
    }
    // ⑤ anchor（无播放进度可恢复）→ 强制 off 归停止态（防双域不一致残留）。
    // 注：itinerary 分支已在上方 return，此条件实际仅 anchor 可达（|| itinerary 为不可达残留，保留不动）
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

/// prefs-changed 通知入口：模式切换（off ↔ itinerary ↔ anchor）立即执行，不经过 500ms 合并；
/// 模式不变（编辑锚点坐标变化）则 500ms 合并窗口防热重载风暴（hold → 重算 → writeTrack 连发多次通知）
- (void)scheduleReloadFromPrefs {
    // 模式切换：立即执行，零延迟响应播放/停止
    NSString *newMode = [self _readPref:@"SimLocationMode"];
    if (![newMode isKindOfClass:[NSString class]] || newMode.length == 0) newMode = @"off";
    if (![newMode isEqualToString:_currentMode]) {
        [self reloadFromPrefs];
        return;
    }
    // 模式不变（编辑坐标变化）：500ms 合并窗口防风暴
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
        // 2026-08-29 定案：off = 停止播放（不推进轨迹），不关系统定位、不清注入（注入始终运行）
        // 但若坐标有变化（App 创建锚点/更新位置），则注入新坐标+开定位
        double lat = [self _readDouble:@"SimLocationLat" def:0.0];
        double lon = [self _readDouble:@"SimLocationLon" def:0.0];
        double acc = [self _readDouble:@"SimLocationAccuracy" def:5.0];
        if (acc < 3.0) acc = 3.0;
        if (acc > 15.0) acc = 15.0;
        BOOL coordChanged = (fabs(_currentLat - lat) > 0.000001 || fabs(_currentLon - lon) > 0.000001);
        if (coordChanged && (lat != 0 || lon != 0)) {
            _currentLat = lat;
            _currentLon = lon;
            _currentAcc = acc;
            [self _injectGpsForCurrentLocation];
            if (![CLLocationManager locationServicesEnabled]) {
                [SimLocationManager setSystemLocationServices:YES];
            }
            TVLog(@"[locsim] off mode: injected position (%.5f, %.5f) acc=%.1f", lat, lon, acc);
        }
        [self _stopTrack];  // 停轨迹推进（位置保持；拟人微动由下方 off 分支统一启动）
        [[SimLocationManager sharedManager] stopPlaybackOnly]; // 停 wifi 扫描，不清 GPS 会话
        [self _teardownWifiStore];           // 停止播放即停止 wifi 重连监听（无兜底，2026-08-30）
        _wifiTargetBSSID = nil;
        _currentMode = @"off";
        _lastWifiTileKey = 0;
        // 未播放时保持拟人微动（2026-08-30 用户定案：真人不会一动不动）——
        // 中心 = 当前位置，只随机偏移不推进轨迹；模式保持 off（微动不改模式）；无有效位置则不启动
        if (_currentLat != 0 || _currentLon != 0) {
            [self _startMicroWanderWithCenter:CLLocationCoordinate2DMake(_currentLat, _currentLon) acc:_currentAcc];
        }
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
        // 动作序列：轨迹文件逐秒推进（续播见 _startTrack：版本一致 seq 精确定位 / 不一致几何兜底，不从头重放）
        [self _stopAnchor];
        [self _startTrack];
    } else {
        TVLog(@"[locsim] unknown mode=%@ -> off", mode);
        [self _stopAnchor];
        [self _stopTrack];
        [[SimLocationManager sharedManager] stopPlaybackOnly];
        _currentMode = @"off";
        _lastWifiTileKey = 0; // 防残留：off 后重启时首点必重新触发反查
    }
}

- (void)_startAnchor {
    // 2026-08-29 定案：首锚点只注入坐标 + 确保定位开启，不启动播放（等待路线生成后 _startTrack 接管）
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
    _currentLat = lat;
    _currentLon = lon;
    _currentSpeed = 0.0;
    _currentCourse = 0.0;
    _currentMode = @"anchor";
    _currentAcc = acc;
    _currentAlt = 45.0;
    // 注入新坐标（变更持久注入的内容）
    [self _injectGpsForCurrentLocation];
    [self _handleAPSwitchForCurrentLocation]; // 反查 AP（播放未开始，不触发下发）
    // 检查并开启系统定位（先注入后开，确保第一秒即模拟值）
    if (![CLLocationManager locationServicesEnabled]) {
        [SimLocationManager setSystemLocationServices:YES];
    }
    // 启动 anchor 微动游走（拟人化：真人不会一动不动，2026-08-30 修复：此前 timer 从未创建，_anchorTick 死代码）
    [self _startMicroWanderWithCenter:CLLocationCoordinate2DMake(lat, lon) acc:acc];
    TVLog(@"[locsim] anchor set (%.5f, %.5f) acc=%.1f (idle micro-wander)", lat, lon, acc);
}

/// 启动拟人微动游走（2026-08-30 抽取共享：anchor 模式 / off 模式共用）——
/// 以指定中心坐标建立微动 timer（_anchorTick 在中心附近随机偏移），不改 _currentMode（由调用方状态机决定）
- (void)_startMicroWanderWithCenter:(CLLocationCoordinate2D)center acc:(double)acc {
    _anchorLat = center.latitude;
    _anchorLon = center.longitude;
    _anchorAcc = acc;
    _currentMx = 0.0;
    _currentMy = 0.0;
    _anchorLastMoveAt = 0;      // 首个迁移点稍快出现（_anchorTick 首个 tick 即可能迁移）
    _anchorLastRefreshAt = 0;   // 首个 tick 即静止刷新（timestamp 保鲜）
    if (!_anchorSource) {
        _anchorSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(_anchorSource, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSimAnchorTickInterval * NSEC_PER_SEC)),
                                  (uint64_t)(kSimAnchorTickInterval * NSEC_PER_SEC), 0);
        __weak __typeof__(self) weakSelf = self; // 用 __typeof__（-std=c++20 下 typeof 不可用）
        dispatch_source_set_event_handler(_anchorSource, ^{
            [weakSelf _anchorTick];
        });
        dispatch_resume(_anchorSource);
    }
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
        [self _checkWifiTileChangedAndReinject]; // 小迁移后瓦片变化才重反查换池（网络变化时序，2026-08-30）
        return;
    }
    if ((CFAbsoluteTimeGetCurrent() - _anchorLastRefreshAt) >= kSimAnchorRefreshInterval) {
        // 静止刷新：同坐标重注入（timestamp 保鲜）
        _anchorLastRefreshAt = CFAbsoluteTimeGetCurrent();
        [self _commitAnchorPoint];
    }
}

/// anchor 当前点提交：按当前游走偏移计算坐标并注入（GPS 单路；wifi 由调用方按需触发）
/// 不改 _currentMode——微动只是移动位置，模式（off/anchor/itinerary）由状态机 applyFromPrefs 决定（2026-08-30）
- (void)_commitAnchorPoint {
    double lat = _anchorLat + _currentMy / 111320.0;
    double lon = _anchorLon + _currentMx / (111320.0 * cos(_anchorLat * M_PI / 180.0));
    _currentLat = lat;
    _currentLon = lon;
    _currentSpeed = 0.0;                 // 静止：速度 0（真人在家无 GPS 速度）
    _currentCourse = 0.0;
    _currentAcc = _anchorAcc;
    [self _injectGpsForCurrentLocation];
}

/// 当前位置 WiFi 联动下发（2026-08-29 软路由联动模型，替代已废弃的"扫描结果注入"）：
/// 坐标 → TRWpsTile 瓦片动态反查 BSSID → 最近 AP → 下发软路由改 SSID/BSSID → known-networks 改名 →
/// SCDynamicStore 监听重连。调用时机：启动/锚点/轨迹 tick 仅瓦片变化才触发（不每 tick 下发，2026-08-30 用户定案）
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
    NSString *targetSSID = [self _generateCitySSIDForBSSID:nearest.bssid];
    // 写入 SimAP 信息（App wifi 状态栏消费：当前模拟 AP 的 SSID/BSSID/坐标/距离）
    {
        NSMutableDictionary *mp = [NSMutableDictionary dictionaryWithContentsOfFile:kSimMobilePrefsPath]
                                    ?: [NSMutableDictionary dictionary];
        mp[@"SimAPSSID"] = targetSSID;
        mp[@"SimAPBSSID"] = nearest.bssid;
        mp[@"SimAPLat"] = @(nearest.coord.latitude);
        mp[@"SimAPLon"] = @(nearest.coord.longitude);
        mp[@"SimAPDistance"] = @(best);
        [mp writeToFile:kSimMobilePrefsPath atomically:YES];
    }
    static NSString *sLastAPBSSID = nil;
    if (sLastAPBSSID && [sLastAPBSSID isEqualToString:nearest.bssid]) return; // 同 AP 不重复下发
    sLastAPBSSID = nearest.bssid;
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
        // 启动 SCDynamicStore 监听 WiFi 重连（收到 notify 后 App 更新水滴）
        [sSelf _startWifiReconnectMonitorWithTargetBSSID:nearest.bssid];
    }];
}

#pragma mark - WiFi 重连监听（SCDynamicStore 键变化回调，2026-08-30）
/// 2026-08-30 真机验证：SCDynamicStore 符号在 iOS dyld cache 存在（SDK 头标记"不可用"系编译期误判，已删错误注释）——
/// dlsym 动态解析后监听 State:/Network/Interface/en0/AirPort 键变化（重连时 configd 更新该键），
/// 匹配目标 BSSID 后 notify App 更新水滴；监听生命周期 = 下发成功后 → 匹配成功（无轮询、无超时兜底，2026-08-30 用户定案）

/// AirPort 状态键变化回调：重连完成时 configd 更新该键，读当前 BSSID 比对目标
- (void)_handleWifiStoreChanged {
    if (!_wifiTargetBSSID) return;
    NSString *curBSSID = [TRWifiKnownNetworks currentBSSID];
    if (curBSSID.length && [curBSSID caseInsensitiveCompare:_wifiTargetBSSID] == NSOrderedSame) {
        notify_post("com.82flex.trollvnc.wifi-switched");
        TVLog(@"[locsim] wifi reconnect: %@ matches target, notified App", curBSSID);
        _wifiTargetBSSID = nil;
        [self _teardownWifiStore];
    }
}

/// 释放 SCDynamicStore 监听（SetDispatchQueue(NULL) 停止投递 + CFRelease）
- (void)_teardownWifiStore {
    if (!_wifiStore) return;
    TVFn_SCDynamicStoreSetDispatchQueue setQueueFn = NULL;
    TVLoadSCDynamicStore(NULL, NULL, NULL, &setQueueFn);
    if (setQueueFn) setQueueFn(_wifiStore, NULL);
    CFRelease(_wifiStore);
    _wifiStore = NULL;
}

static void _wifiAirPortStoreCallback(TVSCDynamicStoreRef store, CFArrayRef changedKeys, void *info) {
    SimLocationController *ctrl = (__bridge SimLocationController *)info;
    [ctrl _handleWifiStoreChanged];
}

- (void)_startWifiReconnectMonitorWithTargetBSSID:(NSString *)bssid {
    _wifiTargetBSSID = bssid;
    // 清理旧监听（复用/重复下发时）
    [self _teardownWifiStore];
    TVFn_SCDynamicStoreCreate createFn = NULL;
    TVFn_SCDynamicStoreSetNotificationKeys setKeysFn = NULL;
    TVFn_SCDynamicStoreSetDispatchQueue setQueueFn = NULL;
    if (!TVLoadSCDynamicStore(&createFn, NULL, &setKeysFn, &setQueueFn)) {
        TVLog(@"[locsim] SCDynamicStore symbols unavailable, skip wifi monitor");
        _wifiTargetBSSID = nil; // 无兜底：失败即清理目标，防残留（2026-08-30）
        return;
    }
    TVSCDynamicStoreContext ctx = {0, (__bridge void *)self, NULL, NULL, NULL};
    _wifiStore = createFn(NULL, CFSTR("com.82flex.trollvnc.wifi-monitor"), _wifiAirPortStoreCallback, &ctx);
    if (!_wifiStore) { TVLog(@"[locsim] SCDynamicStoreCreate failed"); _wifiTargetBSSID = nil; return; }
    if (!setKeysFn || !setQueueFn) {
        TVLog(@"[locsim] SCDynamicStore setKeys/setQueue symbols unavailable, teardown");
        [self _teardownWifiStore];
        _wifiTargetBSSID = nil;
        return;
    }
    // 监听 AirPort 状态键（重连/断连时 configd 更新该键 → 回调）
    CFStringRef keys[] = { CFSTR("State:/Network/Interface/en0/AirPort") };
    CFArrayRef keyArr = CFArrayCreate(NULL, (const void **)keys, 1, &kCFTypeArrayCallBacks);
    if (setKeysFn) setKeysFn(_wifiStore, keyArr, NULL);
    CFRelease(keyArr);
    if (setQueueFn) setQueueFn(_wifiStore, dispatch_get_main_queue());
    // 监听生命周期：匹配成功即清理（_handleWifiStoreChanged），无轮询无超时兜底（2026-08-30 用户定案）
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
/// 注入即写（2026-08-30 用户定案）：每次注入成功立即持久化当前位置——currentPosition 恒等于最近注入位置，
/// 崩溃恢复完全可靠（无节流滞后）；写入为几十字节小 JSON（itinerary 1s/次，NAND 压力可接受）
- (void)_injectGpsForCurrentLocation {
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(_currentLat, _currentLon);
    if (coord.latitude == 0 && coord.longitude == 0) return; // 无当前位置
    [[SimLocationManager sharedManager] injectPoint:coord
                                           altitude:_currentAlt > 0 ? _currentAlt : 45.0
                                           accuracy:_currentAcc
                                             course:_currentCourse
                                              speed:_currentSpeed];
    [self _persistState]; // 注入即写：currentPosition = 最近注入位置（崩溃恢复完全可靠）
}

/// wifi 处理器（旧：locationd 扫描输入注入）已于 2026-08-29 移除——
/// 抖音读的是「当前连接网络的 SSID/BSSID」（CNCopyCurrentNetworkInfo），不读扫描列表；
/// 扫描模拟被证伪为无用功。新链路：反查 AP → 下发软路由改 SSID/BSSID → 设备重连（见 _handleAPList）。

/// 停止 anchor 微动游走（取消 _anchorSource timer，2026-08-30 修复：此前方法体错位为 _startTrack）
- (void)_stopAnchor {
    if (_anchorSource) {
        dispatch_source_cancel(_anchorSource);
        _anchorSource = nil;
    }
}

#pragma mark - itinerary 轨迹推进（每秒注入一点，播完自动终点微动）

- (void)_startTrack {
    NSArray *points = [self _loadTrackPoints];
    if (points.count == 0) {
        TVLog(@"[locsim] track file empty/missing: %@", kTRSimTrackFilePath);
        [self _stopTrack];
        [[SimLocationManager sharedManager] stopPlaybackOnly]; // 空轨迹：停播放，不清注入
        return;
    }
    _trackPoints = points;
    _currentMode = @"itinerary";
    // 记录当前轨迹版本（恢复续播校验：版本一致 → seq 精确定位；不一致 → 几何兜底）
    _currentTrackVersion = [self _loadTrackVersion];
    // 从当前注入位置续播（轨迹文件更新后追加/删除/重排不从头重放旧段）；
    // 无当前位置（进程刚起）则从首点开始
    NSUInteger startIdx = 0;
    if (_currentLat != 0 || _currentLon != 0) {
        BOOL seqValid = NO;
        // ① seq 精确续播（2026-08-30 数据源排序）：轨迹版本一致 + 记录的 seq 在范围内 → 直接定位（O(1) 无几何歧义）
        if (_currentTrackVersion == _persistedTrackVersion && _currentSeq < points.count) {
            startIdx = _currentSeq;
            seqValid = YES;
        }
        if (!seqValid) {
            // ② 几何兜底（版本不一致=编辑过新轨迹，或 seq 越界）：顺序感知找最近点——
            // 遍历全部点找几何最近，但近似等距（U 型/折返重复经过）取顺序靠后，防重播已走过段
            CLLocationCoordinate2D cur = CLLocationCoordinate2DMake(_currentLat, _currentLon);
            double bestD = DBL_MAX;
            for (NSUInteger i = 0; i < points.count; i++) {
                NSDictionary *p = points[i];
                double d = [SimRouteCalculator haversineMeters:cur to:CLLocationCoordinate2DMake([p[@"lat"] doubleValue], [p[@"lon"] doubleValue])];
                if (d < bestD - 1.0) {        // 严格更近（>1m 才算，容忍近似相等）
                    bestD = d;
                    startIdx = i;
                } else if (fabs(d - bestD) <= 1.0) {
                    startIdx = i;             // 近似等距（重复经过点）→ 取顺序靠后，防重播已走过段
                }
            }
        }
    }
    // 首点：更新当前位置 + 统一注入（wifi 反查 + GPS 收尾同 tick，2026-08-28 定案"同一坐标两路输出，动作合一"）
    [self _updateCurrentFromPoint:points[startIdx]];
    [self _injectSimulationForCurrentLocation]; // 首点无条件 wifi 反查 + GPS 注入（正确：建立 AP 池）
    _lastWifiTileKey = [TRWpsTile tileKeyForCoordinate:CLLocationCoordinate2DMake(_currentLat, _currentLon)]; // 记录首点瓦片 key（首点已反查，同瓦片不重复触发）
    _trackIndex = startIdx + 1;
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
    // 2026-08-29 定案：路线播放前检查/开启系统定位（注入已在首点完成）
    if (![CLLocationManager locationServicesEnabled]) {
        [SimLocationManager setSystemLocationServices:YES];
    }
    TVLog(@"[locsim] itinerary start, %lu points (from idx %lu)", (unsigned long)points.count, (unsigned long)startIdx);
}

- (void)_trackTick {
    if (_trackIndex >= _trackPoints.count) {
        [self _stopTrack]; // 播完：停轨迹 timer（不调 stop——保持注入会话）
        // 播完回到拟人微动（真人不会一动不动，2026-08-30）：中心=终点坐标，继续小幅随机偏移
        [self _startMicroWanderWithCenter:CLLocationCoordinate2DMake(_currentLat, _currentLon) acc:_currentAcc];
        TVLog(@"[locsim] itinerary finished, keep final point + idle micro-wander");
        return;
    }
    [self _updateCurrentFromPoint:_trackPoints[_trackIndex++]];
    // GPS 注入：每 tick 必需（locationd 广播新坐标，App 当前位置跟随）
    // wifi 反查：仅瓦片变化才触发，不每 tick 下发（2026-08-30 用户定案）
    [self _injectGpsForCurrentLocation];
    // 网络变化监控：瓦片变化才重新反查换池（同瓦片 LRU 命中零成本；反查池成功后同 tick 注入）
    [self _checkWifiTileChangedAndReinject];   // 2026-08-30 用户定案：wifi 反查只发生在启动/回调/网络变化
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

/// 轨迹点 → 更新当前位置状态（仅更新内存，不注入——注入由调用方决定路径：
/// 首点/锚点平移走 _injectSimulationForCurrentLocation（两路合一），轨迹 tick 走 GPS 每点 + wifi 瓦片变化触发，2026-08-30）
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
    id seqV = p[@"seq"];
    if ([seqV isKindOfClass:[NSNumber class]]) _currentSeq = [seqV unsignedIntegerValue]; // 记录当前注入点 seq（数据源排序）
}

- (void)_stopTrack {
    if (_trackSource) {
        dispatch_source_cancel(_trackSource);
        _trackSource = nil;
    }
    _trackPoints = nil;
    _trackIndex = 0;
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

/// 读轨迹文件的版本号（2026-08-30 数据源排序：恢复续播校验——版本一致用 seq 精确定位，不一致几何兜底）
/// 无文件/无 trackVersion（旧版 v1/v2 数据）返回 0：与持久化版本初始 0 相等 → 走 seq 校验分支；
/// 旧数据无 seq 时 _persistedSeq/_currentSeq 为 0 → startIdx=0 从头播放（旧版无续播语义，符合预期）
- (NSUInteger)_loadTrackVersion {
    NSData *data = [NSData dataWithContentsOfFile:kTRSimTrackFilePath];
    if (!data.length) return 0;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSNumber *v = json[@"trackVersion"];
        if ([v isKindOfClass:[NSNumber class]]) return [v unsignedIntegerValue];
    }
    return 0;
}

#pragma mark - daemon 状态文件（崩溃恢复注入位置，daemon 独写，2026-08-30）

/// 读取 daemon 状态文件；无/损坏返回 nil
+ (NSDictionary *)loadPersistedPosition {
    NSData *data = [NSData dataWithContentsOfFile:kSimStateFilePath];
    if (!data.length) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

/// 从状态文件提取注入位置坐标（无效时返回 kCLLocationCoordinate2DInvalid）
+ (CLLocationCoordinate2D)readPositionFromState:(NSDictionary *)state {
    NSDictionary *cp = state[@"currentPosition"];
    if (![cp isKindOfClass:[NSDictionary class]]) return kCLLocationCoordinate2DInvalid;
    double lat = [cp[@"lat"] doubleValue];
    double lon = [cp[@"lon"] doubleValue];
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return kCLLocationCoordinate2DInvalid;
    return CLLocationCoordinate2DMake(lat, lon);
}

/// 持久化注入位置到状态文件（daemon 独写，崩溃恢复注入连续用；原子写：tmp+rename）
/// 只在注入进度变化时调用（_injectGpsForCurrentLocation 注入后）；不写编排数据（segments/points 在 kTRSimTrackFilePath）
- (void)_persistState {
    if (_currentLat == 0 && _currentLon == 0) return; // 无有效位置不写（宁缺勿错：不写 0,0 覆盖上次有效进度）
    // 记录持久化的 seq/trackVersion（恢复续播校验：_startTrack 读 _persistedTrackVersion 比对当前轨迹版本）
    _persistedSeq = _currentSeq;
    _persistedTrackVersion = _currentTrackVersion;
    NSDictionary *payload = @{
        @"currentPosition": @{ @"lat": @(_currentLat), @"lon": @(_currentLon), @"acc": @(_currentAcc),
                               @"seq": @(_currentSeq), @"trackVersion": @(_currentTrackVersion) },
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    if (!json) return;
    NSString *tmp = [kSimStateFilePath stringByAppendingString:@".tmp"];
    if (![json writeToFile:tmp options:NSDataWritingAtomic error:NULL]) return;
    if ([[NSFileManager defaultManager] fileExistsAtPath:kSimStateFilePath]) {
        [[NSFileManager defaultManager] removeItemAtPath:kSimStateFilePath error:NULL];
    }
    [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:kSimStateFilePath error:NULL];
}

/// 强制写 off 并重载（daemon.restart 升级通道用，2026-08-28）：升级退出前写 off，防新 manager
/// 启动契约读到残留 itinerary 而恢复播放；系统定位关闭由重启后 _forceStopOnStartup ② 兜底（本方法不直接关定位）
+ (void)forceOffAndReload {
    // 写 off 到 mobile 域 plist（配置源）→ reloadFromPrefs 走 off 分支（停轨迹，保留注入会话）；
    // 系统定位关闭由重启后 _forceStopOnStartup ② 完成（宁无位置不漏真实）
    NSMutableDictionary *mp = [NSMutableDictionary dictionaryWithContentsOfFile:kSimMobilePrefsPath]
                                ?: [NSMutableDictionary dictionary];
    mp[@"SimLocationMode"] = @"off";
    [mp writeToFile:kSimMobilePrefsPath atomically:YES];
    [[SimLocationController sharedController] reloadFromPrefs];
    TVLog(@"[locsim] forceOffAndReload done (daemon restarting)");
}

#pragma mark - 参数读取（mobile 域 plist 优先 → root suite 仅兜底）

- (id)_readPref:(NSString *)key {
    // 配置源=mobile 域（App 写入，同域无覆盖问题）；
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
