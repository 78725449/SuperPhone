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
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>

// 轨迹文件路径常量已收敛至 TRSimContract.h（kTRSimTrackFilePath，App/daemon 共享，2026-08-28）
// 配置 plist（mobile 域=配置源：App 写 mobile 命令参数；root 域仅兜底）
static NSString *const kSimMobilePrefsPath = @"/var/mobile/Library/Preferences/com.82flex.trollvnc.plist";
// daemon 状态文件（daemon 独写，崩溃恢复注入位置+播放进度用，2026-08-30）：{currentPosition:{lat,lon,acc,seq,trackVersion}}
// 编排真相在 kTRSimTrackFilePath（App 独写 segments/points）；本文件只存注入进度，单一写入者无并发
static NSString *const kSimStateFilePath = @"/var/mobile/Library/Preferences/com.82flex.trollvnc.simstate.json";
// simstate 持久化（daemon 独写，崩溃恢复注入位置+播放进度+执行模式用）：
// {currentPosition:{lat,lon,acc,seq,trackVersion}, mode:"off|anchor|itinerary"}（2026-09-05 Q1：mode 入 simstate）
// 编排真相在 kTRSimTrackFilePath（App 独写 segments/points/bssidPlan）；本文件只存执行态，单一写入者无并发
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
    // （2026-09-05 Q1：_reloadDebounce 已随 plist reload 状态机整套退役——UDS 是唯一命令通道）
    NSArray<NSDictionary *> *_trackPoints; // 轨迹点序列（内存缓存）
    NSUInteger _trackIndex;
    NSArray<NSDictionary *> *_bssidPlan; // BSSID 计划缓存（2026-09-05 P-1 性能修复：_startTrack 装载一次，
                                         // tick 零文件解析——曾每秒读盘+全量 JSON 解析数 MB 轨迹文件在主队列，
                                         // 与 GPS 注入/SCDynamicStore/UDS 抢主队列致注入节拍抖动；
                                         // 一致性 = play 重发每次 _startTrack 重装载，编辑后新计划自然生效）
    NSUInteger _currentSeq;          // 当前注入点的 seq（数据源排序，2026-08-30：恢复 O(1) 定位续播，独立维护非 _trackIndex）
    NSUInteger _currentTrackVersion; // 当前播放轨迹的版本号（trackVersion，区分新旧轨迹）
    NSUInteger _persistedSeq;        // 上次持久化的 seq（恢复时校验用）
    NSUInteger _persistedTrackVersion; // 上次持久化的轨迹版本（恢复时校验用）
    // （2026-09-05 Q1：_lastParamsSig/_paramsSignature 已随 reload 指纹机制退役）
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
    // （2026-09-04 死代码清理：_wifiTileAps/_lastWifiWindowBssids 已删除——窗口注入随软路由联动模型废弃，两 ivar 零读写）
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
    // 启动契约（2026-08-28 起；2026-09-05 Q1 修订；daemon 由 launchd/watchdog 拉起 = 崩溃/设备重启恢复场景）：
    // _forceStopOnStartup 先关系统定位（安全基底）→ 注入上次位置（simstate.json，位置连续）→
    // 按 simstate mode 恢复：itinerary 放行恢复播放（C10）；anchor/off 归停止态微动。
    // 与 App 侧契约不对称：App 重启 = 不写任何状态、UDS 对齐（宁停不漏，模拟由用户显式开启）；
    // daemon 重启 = 恢复（App 可能仍在前台播放，崩溃恢复语义）。
    [self _forceStopOnStartup];
    [SimLocationController startSimUDSServer]; // UDS 双向通道（命令/回执内核必达，2026-09-05）
    [self _startBSSIDChangeMonitor]; // WiFi 侧系统订阅常驻（BSSID 变化 → UDS 推 App 反查，双订阅对称）
}

/// 启动定位处理（2026-08-29 定案；2026-09-05 Q1 对齐启动契约 C10）：
/// 先关定位（安全基底）→ 注入上次位置 → 按持久化 mode 恢复（itinerary 放行续播，anchor/off 微动）。
/// 状态源 = simstate.json（C11 持久化驱动：位置+seq+trackVersion+mode 四合一，daemon 独写）
- (void)_forceStopOnStartup {
    // ① 读系统定位当前状态（诊断）
    BOOL sysLocON = [CLLocationManager locationServicesEnabled];
    TVLog(@"[locsim] startup: system location = %@", sysLocON ? @"ON" : @"OFF");
    // ② 先关定位（确定安全状态；setSystemLocationServices: 内部幂等：已关则跳过）
    [SimLocationManager setSystemLocationServices:NO];

    // ③ 读 daemon 状态文件，注入上次注入位置（有则注入，确保注入始终跑——即使不恢复播放）
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
        // 启动契约完整化（2026-09-05 用户定义）：有轨迹+当前位置 → 注入后开定位，恢复位置立即可见广播
        // （无位置场景不开定位——直到首锚点/搜索/播放等显式位置命令出现）
        [SimLocationManager setSystemLocationServices:YES];
        TVLog(@"[locsim] startup: injected persisted position (%.5f, %.5f) seq=%lu ver=%lu, location ON",
              statePos.latitude, statePos.longitude, (unsigned long)_persistedSeq, (unsigned long)_persistedTrackVersion);
    } else {
        TVLog(@"[locsim] startup: no persisted position, no injection (first launch / no record)");
    }

    // ④ 按持久化 mode 恢复（2026-09-05 Q1，C10 放行恢复）：simstate mode 是唯一执行态真相——
    // itinerary → _startTrack 续播（接力机器现成：版本一致 seq 精确/不一致几何兜底，C7）；
    // anchor/off → 停止态微动（中心=恢复的当前位置）。无位置且 mode=itinerary 时不恢复（无可续播位置）
    NSString *mode = [state isKindOfClass:[NSDictionary class]] ? state[@"mode"] : nil;
    if (![mode isKindOfClass:[NSString class]] || mode.length == 0) mode = @"off";
    if ([mode isEqualToString:@"itinerary"] && (_currentLat != 0 || _currentLon != 0)) {
        _currentMode = @"itinerary"; // _startTrack 会重设；先置防恢复窗口内 push 谎报
        [self _startTrack];
        TVLog(@"[locsim] startup: persisted itinerary -> resume playback (crash recovery)");
    } else {
        if (_currentLat != 0 || _currentLon != 0) {
            [self _startMicroWanderWithCenter:CLLocationCoordinate2DMake(_currentLat, _currentLon) acc:_currentAcc];
        }
        _currentMode = @"off";
        TVLog(@"[locsim] startup: mode=%@ -> stopped state (micro-wander)", mode);
    }
}

/// 停止态执行核心（2026-09-05 Q1 抽取）：原 applyFromPrefs off 分支语义——停轨迹推进、
/// 停 wifi 扫描（不动常驻 BSSID 订阅！store 生命周期 = daemon 生命周期）、以当前位置为中心微动。
/// 调用方：UDS stop 命令 / 启动恢复非 itinerary 分支 / forceOffAndReload / _startTrack 空轨迹分支
- (void)_applyStopNow {
    [self _stopTrack];  // 停轨迹推进（位置保持；拟人微动由下方统一启动）
    [[SimLocationManager sharedManager] stopPlaybackOnly]; // 停 wifi 扫描，不清 GPS 会话
    _wifiTargetBSSID = nil;
    _currentMode = @"off";
    _lastWifiTileKey = 0;
    // 未播放时保持拟人微动（2026-08-30 用户定案：真人不会一动不动）——
    // 中心 = 当前位置，只随机偏移不推进轨迹；无有效位置则不启动
    if (_currentLat != 0 || _currentLon != 0) {
        [self _startMicroWanderWithCenter:CLLocationCoordinate2DMake(_currentLat, _currentLon) acc:_currentAcc];
    }
}

/// anchor 执行核心（2026-09-05 Q2 参数化）：坐标/精度由调用方显式传入，唯一调用链 =
/// UDS anchor 命令（JSON 坐标直达，C2）。旧 `_startAnchor` plist 读壳已删除——
/// plist SimLocationLat/Lon 是陈旧污染源（读它=UDS 命令坐标被覆写/跳回旧锚点/0,0 裸开定位）。
/// 完整动作序列（2026-09-06 X1 定稿，用户确认：位置在哪 AP 跟到哪，驻留态同样下发）：
/// ① 设模式/坐标 → ② **先注入再开定位**（压窄 locationd 广播真实值的窗口）→
/// ③ AP 反查+下发（驻留态 AP 跟随模拟位置，否则 wifi 层拆穿 GPS 层）→ ④ 微动游走
- (void)_startAnchorAtLat:(double)lat lon:(double)lon acc:(double)acc {
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
    // ① 注入新坐标（变更持久注入的内容）
    [self _injectGpsForCurrentLocation];
    // ② 检查并开启系统定位（先注入后开，确保第一秒即模拟值——开定位时 locationd 冷启动即有注入会话在）
    if (![CLLocationManager locationServicesEnabled]) {
        [SimLocationManager setSystemLocationServices:YES];
    }
    // ③ AP 跟随（驻留态同样下发：最近 AP → 无感漫游；X1 最初版"anchor 不下发"定性错误已撤销）
    [self _handleAPSwitchForCurrentLocation];
    // ④ 启动 anchor 微动游走（拟人化：真人不会一动不动）
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
/// 不改 _currentMode——微动只是移动位置，模式（off/anchor/itinerary）由 UDS 命令状态机决定（2026-09-05 Q1 修订）
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
    // 2026-09-06 X1 定稿（用户裁决）：anchor 驻留态**同样下发**——位置在哪 AP 跟到哪（四层自洽：
    // 驻留时不跟随 = wifi 层守在家庭 AP = wloc 拆穿 GPS 层）。本方法与 _startAnchorAtLat 的
    // 时序契约：**注入→开定位之后**才调用（AP 反查/下发不打断 GPS 广播，且首次下发前位置已是模拟值）。
    // （X1 最初版"anchor 不下发"是误读注释的错判，已撤销——错误注释"不触发下发"同步删除）
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

/// AP 列表处理：按距离取最近 AP → 下发软路由（2026-09-05 语义重定义：设备无感漫游）——
/// SSID 保持设备当前连接的不变（同 SSID 换 BSSID = iOS 原生漫游，不断网/不动密码/不动已知网络），
/// 只把匹配段的 macaddr 改为目标 BSSID；known-networks/名称库 SSID/evt=ap 均退役
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
    // 下发前取当前连接 SSID/BSSID（软路由精准匹配 wireless 段用）
    NSString *curSSID = [TRWifiKnownNetworks currentSSID];
    NSString *curBSSID = [TRWifiKnownNetworks currentBSSID];
    if (!curSSID.length) { TVLog(@"[locsim] no current ssid (not associated?), skip switch"); return; }
    TVLog(@"[locsim] wifi-switch -> target bssid %@ (d=%.0fm, ssid unchanged: %@)", nearest.bssid, best, curSSID);
    // 下发（fire-and-forget）：软路由精准匹配段后只改 macaddr——SSID 不变 = 设备无感漫游
    // 结果验证走常驻 BSSID 订阅 → UDS evt=bssid → App 反查（前端只验证结果）
    [self _requestRouterSwitchSSID:curSSID bssid:nearest.bssid currentSSID:curSSID currentBSSID:curBSSID completion:^(BOOL ok) {
        TVLog(@"[locsim] router switch %@", ok ? @"sent OK" : @"FAILED");
    }];
}

#pragma mark - WiFi 重连监听（SCDynamicStore 键变化回调，2026-08-30）
/// 2026-08-30 真机验证：SCDynamicStore 符号在 iOS dyld cache 存在（SDK 头标记"不可用"系编译期误判，已删错误注释）——
/// dlsym 动态解析后监听 State:/Network/Interface/en0/AirPort 键变化（重连时 configd 更新该键），
/// 匹配目标 BSSID 后 notify App 更新水滴；监听生命周期 = 下发成功后 → 匹配成功（无轮询、无超时兜底，2026-08-30 用户定案）

/// AirPort 状态键变化回调：重连完成时 configd 更新该键（2026-09-05 Q6 修订：空 BSSID 也推——
/// 断连是真实物理事件，App 需要它撤水滴/显示未连接；载荷带 ssid 同源白送，App 渲染零二次查询）
- (void)_handleWifiStoreChanged {
    NSString *curBSSID = [TRWifiKnownNetworks currentBSSID];
    NSString *curSSID = [TRWifiKnownNetworks currentSSID];
    // BSSID 变化必推 UDS（双订阅对称架构：WiFi 侧网络流 → App 渲染+变化才反查；
    // 任意变化都推，App 侧与 lastWifiBSSID 比对去重，零开销）
    [SimLocationController _simUDSSendLine:[NSString stringWithFormat:
        @"{\"evt\":\"bssid\",\"bssid\":\"%@\",\"ssid\":\"%@\"}",
        curBSSID ?: @"", curSSID ?: @""]];
}

/// （2026-09-05 F5：_teardownWifiStore 已删除——BSSID 订阅常驻化后零调用者，
///  store 生命周期 = daemon 生命周期，随进程消亡由内核回收）

/// BSSID 变化常驻订阅（2026-09-05 双订阅对称架构）：daemon 启动即建立，不随下发/匹配拆装——
/// 任意 BSSID 变化经 _handleWifiStoreChanged → UDS 推 App（App 比对去重后反查更新水滴）
- (void)_startBSSIDChangeMonitor {
    if (_wifiStore) return; // 常驻：已建立则不重建
    TVFn_SCDynamicStoreCreate createFn = NULL;
    TVFn_SCDynamicStoreSetNotificationKeys setKeysFn = NULL;
    TVFn_SCDynamicStoreSetDispatchQueue setQueueFn = NULL;
    if (!TVLoadSCDynamicStore(&createFn, NULL, &setKeysFn, &setQueueFn)) {
        TVLog(@"[locsim] SCDynamicStore symbols unavailable, BSSID monitor skip");
        return;
    }
    TVSCDynamicStoreContext ctx = {0, (__bridge void *)self, NULL, NULL, NULL};
    _wifiStore = createFn(NULL, CFSTR("com.82flex.trollvnc.bssid-monitor"), _wifiAirPortStoreCallback, &ctx);
    if (!_wifiStore) { TVLog(@"[locsim] BSSID monitor create failed"); return; }
    CFStringRef keys[] = { CFSTR("State:/Network/Interface/en0/AirPort") };
    CFArrayRef keyArr = CFArrayCreate(NULL, (const void **)keys, 1, &kCFTypeArrayCallBacks);
    setKeysFn(_wifiStore, keyArr, NULL);
    CFRelease(keyArr);
    setQueueFn(_wifiStore, dispatch_get_main_queue());
    TVLog(@"[locsim] BSSID change monitor started (persistent)");
    // 初始状态推送（2026-09-05 断裂点 A1）：SCDynamicStore 只在"变化"时回调——
    // App 重连/启动时 BSSID 无变化则永不推送，App 的 wifi 状态栏/水滴永挂初始态。
    // 订阅建立 = 视为一次状态事件，立即推当前 BSSID 对齐。
    [self _handleWifiStoreChanged];
}

static void _wifiAirPortStoreCallback(TVSCDynamicStoreRef store, CFArrayRef changedKeys, void *info) {
    SimLocationController *ctrl = (__bridge SimLocationController *)info;
    [ctrl _handleWifiStoreChanged];
}



/// 统一注入动作（2026-08-29 改造）：GPS 直写为主；wifi 处理器改为"软路由联动下发"——
/// ① wifi 处理器（新链路：反查 AP → 下发软路由改 {SSID,BSSID} → 改 known-networks → 设备重连）
/// ② GPS 处理器（直写坐标：完整重启广播当前坐标）
/// GPS 链路全程不受影响（anchor/itinerary 坐标注入独立保留）；wifi 注入扫描结果链路已移除
- (void)_injectSimulationForCurrentLocation {
    [self _handleAPSwitchForCurrentLocation];  // ① wifi 处理器：轨迹沿 AP 排列切换软路由（只改目标 BSSID，SSID 不变=无感漫游）
    [self _injectGpsForCurrentLocation];            // ② GPS 处理器：当前坐标直写完整重启（收尾）
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
        // 空轨迹归停止态（2026-09-05 Q4：状态不自谎）——mode/落盘/回执与 stop 命令同语义
        [self _applyStopNow];
        [self _persistState];
        return;
    }
    _trackPoints = points;
    _bssidPlan = [self _loadBSSIDPlan]; // 计划随轨迹同装载（P-1：tick 零文件解析；play 重发=重装载，编辑后新计划生效）
    _currentMode = @"itinerary";
    // 记录当前轨迹版本（恢复续播校验：版本一致 → seq 精确定位；不一致 → 几何兜底）
    _currentTrackVersion = [self _loadTrackVersion];
    // 从当前注入位置续播（轨迹文件更新后追加/删除/重排不从头重放旧段）；
    // 无当前位置（进程刚起）则从首点开始
    NSUInteger startIdx = 0;
    if (_currentLat != 0 || _currentLon != 0) {
        BOOL seqValid = NO;
        // ① seq 精确续播（2026-08-30 数据源排序）：轨迹版本一致 + 记录的 seq 在范围内 + 位置一致性校验 → 直接定位
        //    位置一致性（2026-09-04 接力纪律）：seq 指向的点必须与当前位置吻合（<50m）才可信——
        //    daemon 重启等场景 simstate 的 seq 可能与实际注入位置脱节（如 plist 命令坐标已把位置移到别处），
        //    此时盲信 seq = 跳到 seq 点（回起点/已消费坐标）；接力棒是当前位置，seq 只是加速索引
        if (_currentTrackVersion == _persistedTrackVersion && _currentSeq < points.count) {
            NSDictionary *seqPt = points[_currentSeq];
            double seqDist = [SimRouteCalculator haversineMeters:CLLocationCoordinate2DMake(_currentLat, _currentLon)
                                       to:CLLocationCoordinate2DMake([seqPt[@"lat"] doubleValue], [seqPt[@"lon"] doubleValue])];
            if (seqDist < 50.0) {
                startIdx = _currentSeq;
                seqValid = YES;
            } else {
                TVLog(@"[locsim] seq %lu stale (point %.0fm from current pos) -> geometric fallback", (unsigned long)_currentSeq, seqDist);
            }
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
    // 首点：更新当前位置 + 统一注入（2026-09-06 W-B 修订：AP 下发统一走计划段——首点 seq 已由
    // _updateCurrentFromPoint 设置，_dispatchBSSIDForSeq 与 tick 同一语义"段 BSSID 与上次不同才下发"，
    // 消灭旧瓦片路径+计划路径的双下发（两次路由 reload、两 BSSID 不同=设备来回漫游）；
    // 无计划（旧轨迹）时 _dispatchBSSIDForSeq 内部自动退化瓦片反查路径）
    [self _updateCurrentFromPoint:points[startIdx]];
    [self _dispatchBSSIDForSeq:_currentSeq]; // ① wifi 处理器：计划段下发（首点 seq，与 tick 同构）
    [self _injectGpsForCurrentLocation];      // ② GPS 处理器收尾
    _lastWifiTileKey = [TRWpsTile tileKeyForCoordinate:CLLocationCoordinate2DMake(_currentLat, _currentLon)]; // 记录首点瓦片 key（退化路径防重复触发）
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
        // 播完单方复位（2026-09-04 治理，替代"通知 App 由 App commitStop"的竞速设计）：
        // daemon 单点保证三方一致——_currentMode 归 off + _persistState 落盘（simstate mode=off，
        // 2026-09-05 Q1：plist 写块删除，simstate 是唯一持久化状态源）——位置连续，未来恢复不跳回起点
        _currentMode = @"off";
        [self _persistState];
        TVLog(@"[locsim] itinerary finished, keep final point + idle micro-wander (mode reset to off)");
        notify_post(kTRSimPlaybackFinishedNotification.UTF8String); // App 仅做 UI 复位（丢失无害，plist 已 off）
        [SimLocationController pushSimStateToApp]; // UDS 回执推送：播完复位必达（通知丢失的兜底，2026-09-05）
        return;
    }
    [self _updateCurrentFromPoint:_trackPoints[_trackIndex++]];
    [self _injectGpsForCurrentLocation];
    // BSSID 下发（2026-09-05 权威语义：bssidPlan 计划驱动）——轨迹文件自包含计划（创建时固化），
    // tick 只做"当前 seq 所在覆盖段 → 段 bssid 与上次下发不同 → 下发一次"（段内零下发，
    // 符合基站覆盖物理）。播放中零反查网络请求。
    [self _dispatchBSSIDForSeq:_currentSeq];
}

/// BSSID 计划段查询+下发（2026-09-05 权威语义）：当前 seq 落在 bssidPlan 哪个覆盖段 →
/// 段 bssid 与上次下发不同才下发（段内零下发，符合基站覆盖物理）。无 plan（旧轨迹）→ 退化瓦片反查路径。
- (void)_dispatchBSSIDForSeq:(NSUInteger)seq {
    NSArray *plan = _bssidPlan; // 内存缓存（_startTrack 装载；tick 零文件解析，P-1）
    if (plan.count == 0) {
        [self _checkWifiTileChangedAndReinject]; // 兼容：旧轨迹无 plan → 瓦片变化临时反查（现状路径）
        return;
    }
    NSString *targetBSSID = nil;
    for (NSDictionary *seg in plan) {
        NSUInteger from = [seg[@"fromSeq"] unsignedIntegerValue];
        NSUInteger to = [seg[@"toSeq"] unsignedIntegerValue];
        if (seq >= from && seq <= to) { targetBSSID = seg[@"bssid"]; break; }
    }
    if (!targetBSSID.length) return;
    static NSString *sLastSentBSSID = nil;
    if ([targetBSSID isEqualToString:sLastSentBSSID]) return; // 段内：零下发
    sLastSentBSSID = targetBSSID;
    NSString *curSSID = [TRWifiKnownNetworks currentSSID];
    NSString *curBSSID = [TRWifiKnownNetworks currentBSSID];
    if (!curSSID.length) { TVLog(@"[locsim] bssid dispatch skipped (no current ssid)"); return; }
    TVLog(@"[locsim] plan dispatch -> bssid %@ (seq=%lu)", targetBSSID, (unsigned long)seq);
    [self _requestRouterSwitchSSID:curSSID bssid:targetBSSID currentSSID:curSSID currentBSSID:curBSSID completion:^(BOOL ok) {
        TVLog(@"[locsim] router switch %@", ok ? @"sent OK" : @"FAILED");
    }];
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
    _bssidPlan = nil; // 计划随轨迹生命周期释放（P-1）
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

/// 读轨迹文件的 BSSID 计划（2026-09-05 权威语义：创建轨迹时固化的覆盖段数组）
- (NSArray *)_loadBSSIDPlan {
    NSData *data = [NSData dataWithContentsOfFile:kTRSimTrackFilePath];
    if (!data.length) return @[];
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if ([json isKindOfClass:[NSDictionary class]] && [json[@"bssidPlan"] isKindOfClass:[NSArray class]]) {
        return json[@"bssidPlan"];
    }
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
    // mode 入 simstate（2026-09-05 Q1，C11 持久化驱动状态源）：执行态与位置同文件同生命周期，
    // 注入频率 = 落盘频率 → mode 恒新鲜；恢复链 = simstate 四合一恢复（位置+seq+版本+模式）
    NSDictionary *payload = @{
        @"currentPosition": @{ @"lat": @(_currentLat), @"lon": @(_currentLon), @"acc": @(_currentAcc),
                               @"seq": @(_currentSeq), @"trackVersion": @(_currentTrackVersion) },
        @"mode": _currentMode ?: @"off",
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

/// 强制写 off 并重载（daemon.restart 升级通道用，2026-08-28）：升级退出前归 off，防新 manager
/// 启动契约恢复播放；系统定位关闭由重启后 _forceStopOnStartup ② 兜底（本方法不直接关定位）
+ (void)forceOffAndReload {
    // 2026-09-05 Q1：写 simstate mode=off（唯一持久化状态源）→ _applyStopNow（停轨迹+微动）；
    // 不再写 plist（Sim* 命令键零写）
    SimLocationController *sc = [SimLocationController sharedController];
    [sc _applyStopNow];
    [sc _persistState]; // 显式落盘（停微动路径注入间隔最长 45s，升级窗口内需立即持久化 mode=off）
    TVLog(@"[locsim] forceOffAndReload done (daemon restarting)");
}

/// （2026-09-05 Q1：writeMobilePrefsUsingBlock 已删除——Sim* 命令键零写，写块调用点全部退役；
///  播完复位/forceOffAndReload 均改 _persistState 落盘 simstate）

#pragma mark - 配置读取（mobile 域 plist 优先 → root suite 仅兜底；仅非命令配置，2026-09-05 Q1 收敛）

- (id)_readPref:(NSString *)key {
    // 仅存非命令配置（现唯一消费：SimRouterHTTP 软路由地址）；Sim* 命令键零读取
    // 配置源=mobile 域；root 域仅兜底（历史：root 残留曾覆盖 App 的 mobile 写入）
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

#pragma mark - UDS 双向通道（2026-09-05 权威架构：命令/回执内核必达通道）

// Unix Domain Socket：App(mobile) ↔ daemon(root) 直连。协议 = 每行一个 JSON（\n 分隔）：
//   App→daemon：{"cmd":"play"|"stop"|"anchor"(lat,lon,acc)|"query"}
//   daemon→App：{"evt":"state","mode":"off|anchor|itinerary","seq":N,"lat":..,"lon":..,"acc":..}
//               {"evt":"bssid","bssid":"..","ssid":".."}（变化推/断连推空/连接与命令后必推）
// notify 即发即弃（历次脱节根因），UDS 由内核保证送达；执行态任何变更主动推送回执，
// App UI 由此对齐 daemon 真相（locating 派生自回执，不再自持）。
static int g_simUDSListenFD = -1;
static int g_simUDSClientFD = -1;
static dispatch_source_t g_simUDSAcceptSource;
static dispatch_source_t g_simUDSReadSource;
static NSString *const kSimUDSPath = @"/var/mobile/Library/Caches/com.82flex.trollvnc/sim.uds";

+ (void)_simUDSSendLine:(NSString *)line {
    if (g_simUDSClientFD < 0 || line.length == 0) return;
    NSString *payload = [line stringByAppendingString:@"\n"];
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    ssize_t n = write(g_simUDSClientFD, data.bytes, data.length);
    if (n < 0) {
        TVLog(@"[locsim] UDS write failed (client gone), closing");
        close(g_simUDSClientFD);
        g_simUDSClientFD = -1;
    }
}

+ (void)pushSimStateToApp {
    SimLocationController *sc = self.sharedController; // 强类型：类方法里 self 是 Class，直接链式访问 ivar 报 id 错误
    [self _simUDSSendLine:[NSString stringWithFormat:
        @"{\"evt\":\"state\",\"mode\":\"%@\",\"seq\":%lu,\"lat\":%.6f,\"lon\":%.6f,\"acc\":%.2f}",
        sc->_currentMode ?: @"off",
        (unsigned long)sc->_currentSeq,
        sc->_currentLat,
        sc->_currentLon,
        sc->_currentAcc]];
}

+ (void)_simUDSHandleCommand:(NSData *)data {
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!line.length) return;
    id json = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    NSString *cmd = json[@"cmd"];
    SimLocationController *selfer = self.sharedController;
    TVLog(@"[locsim] UDS command: %@", cmd);
    // 命令三步模式（2026-09-05 Q1）：① 直调执行分支（真机验证过的机器）② _persistState（mode 入 simstate，
    // 恢复链唯一状态源）③ push state+bssid 回执（App UI 对齐真相）
    if ([cmd isEqualToString:@"play"]) {
        // 等价 itinerary 分支（权威语义：接力棒 = _currentLat，不读 plist 坐标）
        [selfer _stopAnchor];
        [selfer _startTrack];
        [selfer _persistState];
    } else if ([cmd isEqualToString:@"stop"]) {
        // 停止核心（位置以 _currentLat 为准，微动接管；不拆常驻 BSSID 订阅——store 生命周期 = daemon 生命周期）
        [selfer _applyStopNow];
        [selfer _persistState];
    } else if ([cmd isEqualToString:@"anchor"]) {
        // 显式位置命令（设锚点/hold）：读命令内坐标 → Q2 参数化直达（不读 plist！）→ 注入+开定位+微动驻留
        double lat = [json[@"lat"] doubleValue];
        double lon = [json[@"lon"] doubleValue];
        double acc = [json[@"acc"] doubleValue];
        if (lat != 0 || lon != 0) {
            [selfer _stopTrack];
            [selfer _startAnchorAtLat:lat lon:lon acc:acc];
            [selfer _persistState];
        }
    } else if ([cmd isEqualToString:@"query"]) {
        // WiFi 对账命令（2026-09-05 Q6）：App 点诊断条 → daemon 同步读当前连接（configd 直读，
        // 无定位依赖）→ 下方统一 evt 回推权威值 → App 缓存被修正（校验走权威通道，App 零自读）
        TVLog(@"[locsim] UDS query -> push current bssid/ssid");
    }
    [self pushSimStateToApp]; // 回执：执行态必达（App UI 对齐真相）
    // 当前连接推送（断裂点 A2 + Q6）：anchor/play 会开定位——App 在"先关再开"抖动窗口里的
    // CNCopy 必空（Q6 后 App 已无 CNCopy，此推送是 evt 链的对齐源）；query 命令也经此回推权威值。
    [[self sharedController] _handleWifiStoreChanged]; // 实例方法（经 sharedController 强类型访问）
}

+ (void)startSimUDSServer {
    if (g_simUDSListenFD >= 0) return;
    NSString *dir = kSimUDSPath.stringByDeletingLastPathComponent;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    unlink(kSimUDSPath.fileSystemRepresentation); // 清残留 socket 文件
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { TVLog(@"[locsim] UDS socket() failed"); return; }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, kSimUDSPath.fileSystemRepresentation, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { TVLog(@"[locsim] UDS bind failed"); close(fd); return; }
    chmod(kSimUDSPath.fileSystemRepresentation, 0666); // App(mobile) 可连接
    if (listen(fd, 2) < 0) { TVLog(@"[locsim] UDS listen failed"); close(fd); return; }
    g_simUDSListenFD = fd;
    g_simUDSAcceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(g_simUDSAcceptSource, ^{
        int cfd = accept(g_simUDSListenFD, NULL, NULL);
        if (cfd < 0) return;
        if (g_simUDSClientFD >= 0) close(g_simUDSClientFD); // 单客户端：新连接替换旧
        g_simUDSClientFD = cfd;
        TVLog(@"[locsim] UDS client connected (fd=%d)", cfd);
        if (g_simUDSReadSource) { dispatch_source_cancel(g_simUDSReadSource); g_simUDSReadSource = nil; }
        g_simUDSReadSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, cfd, 0, dispatch_get_main_queue());
        NSMutableData *buf = [NSMutableData data];
        dispatch_source_set_event_handler(g_simUDSReadSource, ^{
            uint8_t chunk[1024];
            ssize_t n = read(cfd, chunk, sizeof(chunk));
            if (n <= 0) { // 断开
                dispatch_source_cancel(g_simUDSReadSource);
                return;
            }
            [buf appendBytes:chunk length:(NSUInteger)n];
            // 按行拆分命令（\n 分隔），逐条处理
            NSRange r;
            while ((r = [buf rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, buf.length)]).location != NSNotFound) {
                NSData *lineData = [buf subdataWithRange:NSMakeRange(0, r.location)];
                [buf replaceBytesInRange:NSMakeRange(0, r.location + 1) withBytes:NULL length:0]; // 删除已消费行（含\n）
                if (lineData.length) [self _simUDSHandleCommand:lineData];
            }
        });
        dispatch_source_set_cancel_handler(g_simUDSReadSource, ^{
            close(cfd);
            if (g_simUDSClientFD == cfd) g_simUDSClientFD = -1;
        });
        dispatch_resume(g_simUDSReadSource);
        [self pushSimStateToApp]; // 连接建立即推当前状态（App 启动对齐）
        [[self sharedController] _handleWifiStoreChanged]; // 连接建立即推当前连接（F1：A1 逻辑延伸到连接时点——
        // App 重启后 wifi 缓存不能等"下一次 BSSID 变化"，accept 即对齐）
    });
    dispatch_source_set_cancel_handler(g_simUDSAcceptSource, ^{
        if (g_simUDSClientFD >= 0) close(g_simUDSClientFD);
        close(g_simUDSListenFD);
        g_simUDSListenFD = -1;
        g_simUDSClientFD = -1;
    });
    dispatch_resume(g_simUDSAcceptSource);
    TVLog(@"[locsim] UDS server listening on %@", kSimUDSPath);
}

@end
