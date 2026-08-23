/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * RegionSimulator - 区域漫游计划生成（RegionEngine + RegionTimeAllocator，行为形状算法）
 *
 * 对齐《改定位-编码AI执行规格.md》§3.4.1（网关 Node 有同算法可测副本）：
 * - RegionEngine：拒绝采样区域内均匀撒途经点（K 亚线性饱和：√T×2.5，clamp 3~15，±1 抖动；
 *   可自定义途经点数，默认 0=随机）
 * - RegionTimeAllocator：给定总时长 T，用"行为形状"分配（不依赖场景统计参数）：
 *   停留占比 ρ 随机（0.15~0.5）→ 停留时长偏态（70% 短 20~90s / 30% 长 120~300s）→
 *   速度因子每段随机（0.7~1.3，时间不平均）→ 最后途经点不收尾补满（收尾到点停）
 * - 本类只输出"计划"（途经点 + 时间分配），不生成移动点序列——移动段由
 *   SimItineraryPlanner 对相邻途经点逐段 MKDirections 真实道路算路拼接（进入段起点=上一位置，
 *   途经点对 <30m 或算路失败降级直线，见 §3.4.1 生长式区域算路）
 * - 停留段（同点微动 ±1m）由 appendStayPointsAt: 生成
 */
@interface RegionSimulator : NSObject

/// 生成区域漫游计划（途经点 + 时间分配，不含移动点序列）
/// @param center 区域中心（WGS-84）
/// @param radiusM 区域半径（米，最小 10）
/// @param mode walk / drive（区域有效速度 walk 1.4 / drive 13.9 m/s）
/// @param durationMin 区域活动分钟（>0，默认 10）
/// @param start 进入区域的起始坐标（= 上段终点 / 当前位置）
/// @param customK 自定义途经点数（>0 生效，clamp 1~15）；0=随机（亚线性饱和）
/// @return @{
///     @"waypoints": NSArray<NSValue *>（MKCoordinate，K 个访问顺序，均已 MKCoordinateValue），
///     @"staySeconds": NSArray<NSNumber *>（每途经点停留秒，最后点不收尾补满），
///     @"moveFactors": NSArray<NSNumber *>（每段速度因子 0.7~1.3，共 K 段：进入段 + 途经点间段）
/// }
+ (NSDictionary *)generateRegionPlanCenter:(CLLocationCoordinate2D)center
                                    radius:(double)radiusM
                                      mode:(NSString *)mode
                               durationMin:(double)durationMin
                                startFrom:(CLLocationCoordinate2D)start
                                  customK:(int)customK;

/// 模式有效速度（walk 1.4 / drive 13.9 m/s；其他值按 walk 兜底）
+ (double)effectiveSpeedForMode:(NSString *)mode;

/// 降级直线移动段（途经点对 <30m 或算路失败时用；§3.3.2 点格式，1s/点，速度±20% 波动）
+ (NSArray<NSDictionary *> *)degradedLinePointsFrom:(CLLocationCoordinate2D)from
                                                 to:(CLLocationCoordinate2D)to
                                            seconds:(double)seconds
                                              speed:(double)speed;

/// 停留段：同点微动（±1m 慢速漂移 0.1~0.5m/s，拟人"原地活动"），追加到 pts
+ (void)appendStayPointsAt:(CLLocationCoordinate2D)at
                   seconds:(double)seconds
                      into:(NSMutableArray *)pts;

@end

NS_ASSUME_NONNULL_END
