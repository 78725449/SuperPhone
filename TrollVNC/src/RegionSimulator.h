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
 * RegionSimulator - 区域漫游点序列生成（RegionEngine + RegionTimeAllocator，行为形状算法）
 *
 * 对齐《改定位-编码AI执行规格.md》§3.4.1（网关 Node 有同算法可测副本）：
 * - RegionEngine：拒绝采样区域内均匀撒途经点 + 触界反射
 * - RegionTimeAllocator：给定总时长 T，用"行为形状"分配（不依赖场景统计参数）：
 *   活动块计划（K 个途经点随机）→ 停留占比 ρ 随机 → 停留时长偏态（短多长少）→
 *   移动段自由走插值（步长=speed×1s、转角受限、抖动）→ 开场先走 / 收尾到点停 → 校验收敛
 * - 输出 §3.3.2 格式点数组（lat/lon/speed/course/alt/acc，WGS-84），总时长 ≈ durationMin ±2%
 */
@interface RegionSimulator : NSObject

/// 生成区域内漫游点序列
/// @param center 区域中心（WGS-84）
/// @param radiusM 区域半径（米，最小 10）
/// @param mode walk / drive（区域有效速度 walk 1.4 / drive 13.9 m/s）
/// @param durationMin 区域活动分钟（>0，默认 10）
/// @param start 进入区域的起始坐标（= 上段终点 / 当前位置）
+ (NSArray<NSDictionary *> *)generateRegionPointsCenter:(CLLocationCoordinate2D)center
                                                  radius:(double)radiusM
                                                    mode:(NSString *)mode
                                             durationMin:(double)durationMin
                                               startFrom:(CLLocationCoordinate2D)start;

@end

NS_ASSUME_NONNULL_END
