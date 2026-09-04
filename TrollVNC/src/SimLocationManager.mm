/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "SimLocationManager.h"
#import "CoordTransform.h" // GCJ-02 ↔ WGS-84（注入出口边界转换）
#import "Logging.h" // TVLog（拒绝注入日志）

#import <CoreLocation/CoreLocation.h>

// 私有类方法（classdump 实证，iOS 15/17 均在；LocationServicesSwitcher 同款用法）：
// 系统定位总开关——定位对抗编排的防御位（启动安全基底/异常失效时先关，宁无位置不漏真实）
@interface CLLocationManager (TrollVNCLocationSwitch)
+ (void)setLocationServicesEnabled:(BOOL)enabled;
@end

/**
 * CLSimulationManager 私有接口声明（自写，参考逆向公开知识；不复制 GPL 源码）。
 * 接口事实来源：Geranium/Andromeda/TrollBox 均使用同一声明（udevs 头文件）。
 * 依赖 entitlement：com.apple.locationd.simulation（见 TrollVNC.entitlements）。
 * （2026-09-04 死声明清理：loadScenarioFromURL/setSimulatedCell/startCellSimulation/
 *  stopCellSimulation/setWifiScanResults/startWifiSimulation 已删——零调用，
 *  cell 模拟与扫描结果注入从未启用；仅保留 GPS 注入 + wifi 扫描停止实际用到的声明）
 */
@interface CLSimulationManager : NSObject
@property (assign, nonatomic) uint8_t locationDeliveryBehavior;
@property (assign, nonatomic) double locationDistance;
@property (assign, nonatomic) double locationInterval;
@property (assign, nonatomic) double locationSpeed;
@property (assign, nonatomic) uint8_t locationRepeatBehavior;
- (void)clearSimulatedLocations;
- (void)startLocationSimulation;
- (void)stopLocationSimulation;
- (void)appendSimulatedLocation:(id)location;
- (void)flush;
- (void)setSimulatedWifiPower:(BOOL)p;
- (void)stopWifiSimulation;
@end

static const NSString *kLocSimTimezoneNotification = @"AutomaticTimeZoneUpdateNeeded";

@implementation SimLocationManager {
    CLSimulationManager *_sim;
    BOOL _wifiSimulatingOnce; // 曾成功注入过 wifi（单调不回退，供空洞螺旋区分"曾成功 vs 从未成功"，2026-08-27）
}

+ (instancetype)sharedManager {
    static SimLocationManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[SimLocationManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sim = [[CLSimulationManager alloc] init];
    }
    return self;
}

- (void)injectPoint:(CLLocationCoordinate2D)coord
           altitude:(double)alt
           accuracy:(double)acc
             course:(double)course
              speed:(double)speed {
    // 坐标系边界转换（2026-09-04 治理）：编排层（锚点/轨迹/self.cur，来自地图瓦片系）传 GCJ 语义数值，
    // locationd/对外 App 消费 WGS-84 语义——注入出口统一 GCJ→WGS，对外拿到真实地理位置
    // （根治"GCJ 数值冒充 WGS"的东南 ~500m 偏移）；daemon 内部进度（simstate）保持瓦片系与轨迹文件同系
    coord = [CoordTransform gcj02ToWgs84:coord];
    if (![CoordTransform isValidSimCoordinate:coord]) {
        TVLog(@"[locsim] reject invalid coordinate (lat %.6f lon %.6f) — not injecting", coord.latitude, coord.longitude);
        return;  // 无效/境外坐标拒绝注入（定位跑澳洲的根治防线，2026-09-04）
    }
    CLLocation *location = [[CLLocation alloc] initWithCoordinate:coord
                                                         altitude:alt
                                               horizontalAccuracy:acc
                                                 verticalAccuracy:5
                                                           course:course
                                                            speed:speed
                                                        timestamp:[NSDate date]];
    // 每次注入完整重启（对齐 TrollBox/Geranium 等参考实现）：stop→clear→append→flush→start。
    // append-only（不重启）时 locationd 不把模拟位置广播给持续订阅的 client——
    // App/MKMapView 收不到（实测：只有外部 App 发起新定位请求才"顺带"返回）。
    // 投递参数每次一并设置：默认 0（unset）→ locationd 不投递模拟 fix。
    [_sim stopLocationSimulation];
    [_sim clearSimulatedLocations];
    _sim.locationDeliveryBehavior = 1; // 持续投递
    _sim.locationDistance = 0;         // 无距离过滤：每次注入都投递
    _sim.locationInterval = 1.0;       // 投递间隔 1s（对齐 daemon 每秒注入节奏）
    _sim.locationSpeed = 0;            // 速度由注入 CLLocation 自带（不插值）
    _sim.locationRepeatBehavior = 1;   // 重复投递
    [_sim appendSimulatedLocation:location];
    [_sim flush];
    [_sim startLocationSimulation];
    [SimLocationManager postTimezoneUpdate];
}

/// 只停播放，不清掉 locationd 模拟会话——注入持续活到最后位置（2026-08-29 定案）
- (void)stopPlaybackOnly {
    [self stopWifiScanSimulation];
    // 不调 [self stop] —— 不清 locationd 会话（stopLocationSimulation + clear + flush 都不调）
    // （2026-09-04 死代码清理：stop/stopAll（清模拟回真实）已删除——注入始终运行架构下无停止路径消费）
}

- (BOOL)wasWifiSimulatingOnce {
    return _wifiSimulatingOnce;
}

#pragma mark - 系统定位服务总开关（定位对抗编排防御位）

+ (BOOL)setSystemLocationServices:(BOOL)on {
    @try {
        if (![CLLocationManager respondsToSelector:@selector(setLocationServicesEnabled:)]) {
            return NO;
        }
        BOOL before = [CLLocationManager locationServicesEnabled];
        if (before == on) return YES;   // 幂等
        [CLLocationManager setLocationServicesEnabled:on];
        BOOL after = [CLLocationManager locationServicesEnabled];
        return after == on;             // 回读确认（失败向上报告）
    } @catch (NSException *ex) {
        return NO;                      // 私有 API 异常不外泄
    }
}

+ (BOOL)systemLocationServicesEnabled {
    return [CLLocationManager locationServicesEnabled];
}

- (void)stopWifiScanSimulation {
    if (!_sim) return;
    [_sim stopWifiSimulation];
    [_sim setSimulatedWifiPower:NO];
    NSLog(@"[locsim] wifi simulation stopped");
}

/// 通知系统刷新时区显示（模拟跨时区后地图/时间跟随）。
/// 调用点：injectPoint: 每次注入后发送（原注释"节流由上层负责"已不准确——上层无节流，保留现状）
+ (void)postTimezoneUpdate {
    CFNotificationCenterPostNotificationWithOptions(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (CFStringRef)kLocSimTimezoneNotification,
        NULL, NULL, kCFNotificationDeliverImmediately);
}

@end
