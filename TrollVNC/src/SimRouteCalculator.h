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
 * SimRouteCalculator - Apple 地图原生算路（MKDirections）
 *
 * 两点沿真实道路的轨迹生成：MKDirections 算路 → MKRoute.polyline 坐标 →
 * 按速度重采样（步长=speed×1s）→ 拟人参数。
 * 本类只返回/生成点序列（纯算路，不落盘、不切 mode）——供 App 定位 UI（TRMapPickerViewController）
 * 逐段算路拼接使用（2026-08-26 起外部 sim.* 能力已收敛，注册表/0x50/5802 不再调用）；
 * 落盘由调用方负责（App writeTrackFile 直写 simloc.json）。
 *
 * 模式（Apple transportType 公开档，仅两个稳定真实档）：
 * - walk → MKDirectionsTransportTypeWalking（1.4m/s）
 * - drive → MKDirectionsTransportTypeAutomobile（13.9m/s）
 */
@interface SimRouteCalculator : NSObject

/// 异步算路仅返回点序列（不落盘、不切 mode）——供编排逐段拼接使用
/// @param from 起点（WGS-84）
/// @param to   终点（WGS-84）
/// @param mode walk / drive（其他值按 walk 兜底）
/// @param completion 点序列（§3.3.2 格式）；error 非 nil 时 points 为空数组
+ (void)calculateRoutePointsFrom:(CLLocationCoordinate2D)from
                              to:(CLLocationCoordinate2D)to
                            mode:(NSString *)mode
                      completion:(void (^)(NSArray<NSDictionary *> *points, NSError *error))completion;

/// 两点球面距离（haversine，米）——供区域段逐段算路使用
+ (double)haversineMeters:(CLLocationCoordinate2D)a to:(CLLocationCoordinate2D)b;

@end

NS_ASSUME_NONNULL_END
