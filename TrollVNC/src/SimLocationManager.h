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
 * SimLocationManager - 定位注入原语（CLSimulationManager 私有 API 封装）
 *
 * 职责：封装 CLSimulationManager（私有 API，TrollStore entitlement
 * `com.apple.locationd.simulation` 授权）的单点注入/停止原语。
 * 本类只做注入原语，不做状态机/持久化（由 SimLocationController 负责）。
 *
 * 注入序列（Andromeda/Geranium 实证）：stop → clear → append → flush → start，
 * 再发时区更新通知。GPS 注入（injectPoint:）当前唯一活跃链路；
 * wifi 扫描结果注入系列方法已于 2026-09-04 死代码清理中移除（2026-08-29 软路由联动模型替代）。
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

/// 只停轨迹播放（停 wifi 扫描播放），不清 locationd 会话（2026-08-29）——
/// 当前活跃调用（SimLocationController off/空轨迹分支）
- (void)stopPlaybackOnly;

/// wifi 模拟是否"曾成功注入过"（单调不回退；供空洞螺旋区分"曾成功但丢失→重反查" vs
/// "从未成功（空洞瓦片）→安静等待跨瓦片换源"——2026-08-27 定案，防自我锁死循环；唯一消费点 SimLocationController._handleAPSwitchForCurrentLocation）
@property(nonatomic, assign, readonly) BOOL wasWifiSimulatingOnce;

/// 系统定位服务总开关（私有 CLLocationManager setLocationServicesEnabled:，TrollStore root 可用；
/// LocationServicesSwitcher 开源先例。2026-08-28 定位对抗编排核心：
/// 注入确认后开开关；启动安全基底/异常失效=先关开关再注入——宁无位置不漏真实）
+ (BOOL)setSystemLocationServices:(BOOL)on;
+ (BOOL)systemLocationServicesEnabled;

@end

NS_ASSUME_NONNULL_END
