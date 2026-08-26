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

/// 总停止：GPS + wifi 模拟一并停止（总开关关闭时调用，恢复真实定位与真实扫描源）
- (void)stopAll;

/// WiFi 扫描模拟注入（输入层）：setWifiScanResults + setSimulatedWifiPower + startWifiSimulation
/// @param scanResults  NSArray<NSDictionary *>，每项含 bssid/ssid/rssi/channel/age/timestamp（键名待 XPC 取证校准）
/// 与 GPS 注入（injectPoint:）并发不互斥——GPS 喂结果层、wifi 喂输入层，叠加自洽
- (void)injectWifiScanResults:(NSArray<NSDictionary *> *)scanResults;

/// 停止 wifi 扫描模拟：stopWifiSimulation + setSimulatedWifiPower:NO（恢复真实扫描源）
- (void)stopWifiScanSimulation;

/// 构建 setWifiScanResults: 的字典数组（NSString 版——规避 C 字符串生命周期，动态反查用）
/// 输入：NSString BSSID 数组；每项含 bssid/ssid/rssi/channel/age/timestamp（键名待 XPC 取证校准）
/// rssi 随机 -40~-85 dBm（决定 wifi 源精度 10-100m，与 GPS 源 5-30m 区分）
+ (NSArray<NSDictionary *> *)buildScanResultsFromBssidStrings:(NSArray<NSString *> *)bssids;

/// 当前 wifi 模拟是否开启
@property(nonatomic, assign, readonly) BOOL isWifiSimulating;

/// 当前是否处于注入中（供后续失效巡检使用）
@property(nonatomic, assign, readonly) BOOL isSimulating;

@end

NS_ASSUME_NONNULL_END
