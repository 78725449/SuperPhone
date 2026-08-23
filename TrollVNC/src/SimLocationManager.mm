/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "SimLocationManager.h"

#import <CoreLocation/CoreLocation.h>

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
    if (!_simulating) {
        // 首次：完整启动（stop→clear→append→flush→start）
        [_sim stopLocationSimulation];
        [_sim clearSimulatedLocations];
        [_sim appendSimulatedLocation:location];
        [_sim flush];
        [_sim startLocationSimulation];
        _simulating = YES;
    } else {
        // running 态：append-only，不 stop/clear/restart
        // 依据：TrollBox 实证「stop 后位置异常」是系统 daemon bug，每秒 stop→start 高频触发 → 周期性漂移
        [_sim appendSimulatedLocation:location];
        [_sim flush];
    }
    [SimLocationManager postTimezoneUpdate];
}

- (void)stop {
    [_sim stopLocationSimulation];
    [_sim clearSimulatedLocations];
    [_sim flush];
    _simulating = NO;
    [SimLocationManager postTimezoneUpdate];
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
