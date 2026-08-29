/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "SimLocationManager.h"

#import <CoreLocation/CoreLocation.h>

// 私有类方法（classdump 实证，iOS 15/17 均在；LocationServicesSwitcher 同款用法）：
// 系统定位总开关——定位对抗编排的防御位（关模拟/失效时关开关，宁无位置不漏真实）
@interface CLLocationManager (TrollVNCLocationSwitch)
+ (void)setLocationServicesEnabled:(BOOL)enabled;
@end

/**
 * CLSimulationManager 私有接口声明（自写，参考逆向公开知识；不复制 GPL 源码）。
 * 接口事实来源：Geranium/Andromeda/TrollBox 均使用同一声明（udevs 头文件）。
 * 依赖 entitlement：com.apple.locationd.simulation（见 TrollVNC.entitlements）。
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
- (void)loadScenarioFromURL:(id)url;
- (void)setWifiScanResults:(id)scanResults;
- (void)setSimulatedWifiPower:(BOOL)p;
- (void)startWifiSimulation;
- (void)stopWifiSimulation;
- (void)setSimulatedCell:(id)cell;
- (void)startCellSimulation;
- (void)stopCellSimulation;
@end

static const NSString *kLocSimTimezoneNotification = @"AutomaticTimeZoneUpdateNeeded";

@implementation SimLocationManager {
    CLSimulationManager *_sim;
    BOOL _simulating;
    BOOL _wifiSimulating;
    BOOL _wifiSimulatingOnce; // 曾成功注入过 wifi（单调不回退，供巡检/螺旋区分"曾成功 vs 从未成功"）
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
        _simulating = NO;
        _wifiSimulating = NO;
    }
    return self;
}

- (BOOL)isSimulating {
    return _simulating;
}

- (void)injectPoint:(CLLocationCoordinate2D)coord
           altitude:(double)alt
           accuracy:(double)acc
             course:(double)course
              speed:(double)speed {
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
    _simulating = YES;
    [SimLocationManager postTimezoneUpdate];
}

- (void)stop {
    [_sim stopLocationSimulation];
    [_sim clearSimulatedLocations];
    [_sim flush];
    _simulating = NO;
    [SimLocationManager postTimezoneUpdate];
}

- (void)stopAll {
    [self stop];                    // GPS：stopLocationSimulation + clear + flush
    [self stopWifiScanSimulation]; // wifi：stopWifiSimulation + power NO
}

/// 只停播放，不清掉 locationd 模拟会话——注入持续活到最后位置（2026-08-29 定案）
- (void)stopPlaybackOnly {
    [self stopWifiScanSimulation];
    // 不调 [self stop] —— 不清 locationd 会话（stopLocationSimulation + clear + flush 都不调）
}

- (BOOL)isWifiSimulating {
    return _wifiSimulating;
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

- (void)injectWifiScanResults:(NSArray<NSDictionary *> *)scanResults {
    if (!_sim) return;
    if (scanResults.count == 0) {
        NSLog(@"[locsim] wifi simulation inject skipped: empty scan results");
        return;
    }
    // 每次注入完整重启（对齐 GPS 注入语义）：先停旧的再起新的，保证新数据被 locationd 消费
    [_sim stopWifiSimulation];
    [_sim setSimulatedWifiPower:NO];
    [_sim setWifiScanResults:scanResults];
    [_sim setSimulatedWifiPower:YES];
    [_sim startWifiSimulation];
    _wifiSimulating = YES;
    _wifiSimulatingOnce = YES; // 曾成功注入过（单调不回退，供巡检区分曾成功/从未成功）
    NSLog(@"[locsim] wifi simulation start, %lu APs", (unsigned long)scanResults.count);
}

- (void)stopWifiScanSimulation {
    if (!_sim) return;
    [_sim stopWifiSimulation];
    [_sim setSimulatedWifiPower:NO];
    _wifiSimulating = NO;
    NSLog(@"[locsim] wifi simulation stopped");
}

+ (NSArray<NSDictionary *> *)buildScanResultsFromBssidStrings:(NSArray<NSString *> *)bssids {
    if (bssids.count == 0) return @[];
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:bssids.count];
    double now = [[NSDate date] timeIntervalSince1970];
    for (NSString *bssid in bssids) {
        if (bssid.length == 0) continue;                      // 空串兜底
        double rssi = -40.0 - (double)(arc4random_uniform(4500)) / 100.0; // -40 ~ -85 dBm
        [results addObject:@{
            @"bssid"     : bssid,
            @"ssid"      : @"",
            @"rssi"      : @(rssi),
            @"channel"   : @(1 + arc4random_uniform(13)),
            @"age"       : @(0.5),
            @"timestamp" : @(now),
        }];
    }
    return results;
}

/// 通知系统刷新时区显示（模拟跨时区后地图/时间跟随）。
/// 节流由上层（Controller）负责；实验 A 阶段每次注入直接发。
+ (void)postTimezoneUpdate {
    CFNotificationCenterPostNotificationWithOptions(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (CFStringRef)kLocSimTimezoneNotification,
        NULL, NULL, kCFNotificationDeliverImmediately);
}

@end
