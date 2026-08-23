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
 * SimLocationManager - 全系统改定位注入原语（实验 A 最小实现）
 *
 * 职责：封装 CLSimulationManager（私有 API，TrollStore entitlement
 * `com.apple.locationd.simulation` 授权）的单点注入/停止原语。
 * 本类只做注入，不做状态机/持久化（由后续 SimLocationController 负责）。
 *
 * 注入序列（Andromeda/Geranium 实证）：stop → clear → append → flush → start，
 * 再发时区更新通知（节流由 Controller 负责，本类每次注入都会发）。
 */
@interface SimLocationManager : NSObject

+ (instancetype)sharedManager;

/// 单点注入（WGS-84）：stop → clear → append → flush → start + 时区通知
/// @param coord   WGS-84 坐标
/// @param alt     海拔（米）
/// @param acc     horizontalAccuracy（米）
/// @param course  航向（度）
/// @param speed   速度（米/秒）
- (void)injectPoint:(CLLocationCoordinate2D)coord
           altitude:(double)alt
           accuracy:(double)acc
             course:(double)course
              speed:(double)speed;

/// 停止注入：stop → clear → flush + 时区通知（恢复真实定位）
- (void)stop;

/// 当前是否处于注入中（供后续失效巡检使用）
@property(nonatomic, assign, readonly) BOOL isSimulating;

@end

NS_ASSUME_NONNULL_END
