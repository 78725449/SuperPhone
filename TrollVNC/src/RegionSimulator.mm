/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "RegionSimulator.h"

#import <MapKit/MKGeometry.h> // NSValue valueWithMKCoordinate/MKCoordinateValue（MapKit 分类）
#import <math.h>

// 区域有效速度（m/s）
static const double kRegSpeedWalk = 1.4;
static const double kRegSpeedDrive = 13.9;

@implementation RegionSimulator

#pragma mark - 公共入口

+ (NSDictionary *)generateRegionPlanCenter:(CLLocationCoordinate2D)center
                                    radius:(double)radiusM
                                      mode:(NSString *)mode
                               durationMin:(double)durationMin
                                startFrom:(CLLocationCoordinate2D)start
                                  customK:(int)customK {
    (void)mode; // 速度因子独立于模式（模式只影响算路 transportType），见 §3.4.1
    (void)start; // 计划只定途经点与时间分配；进入段起点由 Planner 静态绑定 cur
    if (radiusM < 10.0) radiusM = 10.0;
    if (durationMin <= 0) durationMin = 10.0;
    double T = durationMin * 60.0;

    // ① 途经点数 K：自定义 >0 生效（clamp 1~15）；默认 0 → 亚线性饱和（√T×2.5，clamp 3~15，±1 抖动）
    int K;
    if (customK > 0) {
        K = MAX(1, MIN(15, customK));
    } else {
        double base = round(sqrt(T / 60.0) * 2.5);
        int jitter = (int)arc4random_uniform(3) - 1;
        K = MAX(3, MIN(15, (int)base + jitter));
    }

    // ② 途经点：拒绝采样区域内均匀撒点（K 个，访问顺序随机）
    NSMutableArray<NSValue *> *wps = [NSMutableArray arrayWithCapacity:K];
    for (int i = 0; i < K; i++) {
        double r = sqrt((double)arc4random_uniform(100000) / 100000.0) * radiusM;
        double a = (double)arc4random_uniform(62832) / 10000.0; // 0~2π
        double dLat = r * sin(a) / 111320.0;
        double dLon = r * cos(a) / (111320.0 * cos(center.latitude * M_PI / 180.0));
        [wps addObject:[NSValue valueWithMKCoordinate:CLLocationCoordinate2DMake(center.latitude + dLat, center.longitude + dLon)]];
    }

    // ③ 停留预算：停留占比 ρ 随机（0.15~0.5），各途经点停留时长偏态抽样后归一化到 stayTotal；
    //    最后途经点不收尾补满（收尾"逛到某处到点了"停住，不故意拉长停留）
    double rho = 0.15 + (double)arc4random_uniform(3500) / 10000.0;
    double stayTotal = T * rho;
    NSMutableArray<NSNumber *> *staySeconds = [NSMutableArray arrayWithCapacity:K];
    double staySum = 0.0;
    for (int i = 0; i < K; i++) {
        double s = [RegionSimulator _sampleStayDuration];
        [staySeconds addObject:@(s)];
        staySum += s;
    }
    if (staySum <= 0) staySum = 1.0;
    for (int i = 0; i < K; i++) {
        staySeconds[i] = @([staySeconds[i] doubleValue] / staySum * stayTotal);
    }

    // ④ 速度因子：每段随机 0.7~1.3（时间不平均；段数 K = 进入段 + 途经点间段）
    NSMutableArray<NSNumber *> *moveFactors = [NSMutableArray arrayWithCapacity:K];
    for (int i = 0; i < K; i++) {
        double f = 0.7 + (double)arc4random_uniform(6000) / 10000.0;
        [moveFactors addObject:@(f)];
    }

    return @{ @"waypoints": wps, @"staySeconds": staySeconds, @"moveFactors": moveFactors };
}

+ (double)effectiveSpeedForMode:(NSString *)mode {
    return [mode isEqualToString:@"drive"] ? kRegSpeedDrive : kRegSpeedWalk;
}

#pragma mark - 时间分配（行为形状）

// 偏态停留：70% 短档 20~90s；30% 长档 120~300s（短多长少，模拟红绿灯/短暂看手机 vs 排队/购物）
+ (double)_sampleStayDuration {
    if (arc4random_uniform(100) < 70) {
        return 20.0 + (double)arc4random_uniform(7000) / 100.0;
    }
    return 120.0 + (double)arc4random_uniform(18000) / 100.0;
}

#pragma mark - 点序列生成（移动/停留）

// 降级直线移动段：等距插值（步长=speed×1s），带转角平滑 + 坐标抖动 + 速度波动（拟人调料）
// 仅用于途经点对 <30m 或 MKDirections 算路失败时（正常移动段走真实道路算路，见 SimItineraryPlanner）
+ (NSArray<NSDictionary *> *)degradedLinePointsFrom:(CLLocationCoordinate2D)from
                                                 to:(CLLocationCoordinate2D)to
                                            seconds:(double)seconds
                                              speed:(double)speed {
    NSMutableArray *pts = [NSMutableArray array];
    if (seconds <= 0) return pts;
    NSUInteger steps = (NSUInteger)floor(seconds);
    if (steps < 1) steps = 1;
    double heading = [RegionSimulator _initialBearingFrom:from to:to];
    for (NSUInteger i = 1; i <= steps; i++) {
        double f = (double)i / (double)steps;
        double lat = from.latitude + (to.latitude - from.latitude) * f
                     + [RegionSimulator _jitter];
        double lon = from.longitude + (to.longitude - from.longitude) * f
                     + [RegionSimulator _jitter];
        double spd = speed * (0.8 + (double)arc4random_uniform(400) / 1000.0); // ±20% 波动
        double crs = heading + (double)arc4random_uniform(400) / 1000.0 * 6.0 - 1.2; // 航向 ±1.2°
        [pts addObject:@{
            @"lat": @(lat), @"lon": @(lon),
            @"speed": @(spd), @"course": @(crs),
            @"alt": @(45.0 + (double)arc4random_uniform(1000) / 1000.0 - 0.5), // ±0.5m
            @"acc": @(3.0 + (double)arc4random_uniform(3000) / 1000.0),        // 3~6m
        }];
    }
    return pts;
}

// 停留段：同点微动（±1m 慢速漂移，speed 0.1~0.5m/s），拟人"原地活动"；追加到 pts
+ (void)appendStayPointsAt:(CLLocationCoordinate2D)at
                   seconds:(double)seconds
                      into:(NSMutableArray *)pts {
    NSUInteger count = (NSUInteger)floor(seconds);
    if (count < 1) count = 1;
    double acc = 3.0 + (double)arc4random_uniform(3000) / 1000.0;
    for (NSUInteger i = 0; i < count; i++) {
        double lat = at.latitude + [RegionSimulator _jitterDeg:1.0];  // ±1m
        double lon = at.longitude + [RegionSimulator _jitterDeg:1.0];
        double spd = 0.1 + (double)arc4random_uniform(400) / 1000.0;  // 0.1~0.5m/s
        double crs = (double)arc4random_uniform(36000) / 100.0;
        [pts addObject:@{
            @"lat": @(lat), @"lon": @(lon),
            @"speed": @(spd), @"course": @(crs),
            @"alt": @(45.0 + (double)arc4random_uniform(1000) / 1000.0 - 0.5),
            @"acc": @(acc),
        }];
    }
}

#pragma mark - 几何工具（公开数学）

+ (double)_haversineMeters:(CLLocationCoordinate2D)a to:(CLLocationCoordinate2D)b {
    double R = 6371000.0;
    double dLat = (b.latitude - a.latitude) * M_PI / 180.0;
    double dLon = (b.longitude - a.longitude) * M_PI / 180.0;
    double s = sin(dLat / 2) * sin(dLat / 2)
               + cos(a.latitude * M_PI / 180.0) * cos(b.latitude * M_PI / 180.0) * sin(dLon / 2) * sin(dLon / 2);
    return 2 * R * asin(sqrt(s));
}

+ (double)_initialBearingFrom:(CLLocationCoordinate2D)a to:(CLLocationCoordinate2D)b {
    double lat1 = a.latitude * M_PI / 180.0, lat2 = b.latitude * M_PI / 180.0;
    double dLon = (b.longitude - a.longitude) * M_PI / 180.0;
    double y = sin(dLon) * cos(lat2);
    double x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    double brg = atan2(y, x) * 180.0 / M_PI;
    if (brg < 0) brg += 360.0;
    return brg;
}

+ (double)_jitter {
    return [RegionSimulator _jitterDeg:0.3];
}

// 抖动（米 → 度）：[-m, +m]
+ (double)_jitterDeg:(double)meters {
    double deg = meters / 111320.0;
    return ((double)arc4random_uniform(2000000) / 1000000.0 - 1.0) * deg;
}

@end
