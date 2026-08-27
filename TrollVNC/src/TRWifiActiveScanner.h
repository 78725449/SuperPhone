/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 主动扫描结果快照（daemon 写共享 JSON 的模型；App 侧订阅通知后读取同构）
@interface TRWifiScanSnapshot : NSObject
@property (nonatomic, copy, readonly) NSArray<NSString *> *bssids; // 标准格式 XX:XX:XX:XX:XX:XX（大写）
@property (nonatomic, copy, readonly) NSArray<NSString *> *ssids;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *rssi;   // dBm
@property (nonatomic, assign, readonly) NSTimeInterval ts;          // 扫描时刻（unix）

- (instancetype)initWithBssids:(NSArray<NSString *> *)bssids
                         ssids:(NSArray<NSString *> *)ssids
                          rssi:(NSArray<NSNumber *> *)rssi
                             ts:(NSTimeInterval)ts;
@end

/// daemon 侧 Apple80211 主动扫描（root 进程 dlopen MobileWiFi 私有框架，系统设置页同一底层）
/// 目的：真实 wifi 定位不再依赖「打开系统 Wi-Fi 设置页触发被动扫描」——
/// manager 常驻周期主动扫周边 BSSID → 写共享 JSON + Darwin 通知 → App 订阅消费。
/// 启动点：trollvncmanager.mm 启动区（与 SimLocationController / TRDailyTrajectory 同块）。
@interface TRWifiActiveScanner : NSObject

+ (instancetype)sharedScanner;

/// 启动周期扫描（默认 8s；首次立即扫；GCD timer，1s 容差）
- (void)start;

/// 停止扫描（bridge 模式自退 / 进程退出时调用；清 timer）
- (void)stop;

/// 立即触发一次主动扫描（不等周期 timer；供"关模拟立刻重扫"请求通道调用，
/// 内部经 WiFiDeviceClientScanAsync 异步，_scanInFlight 防并发堆积）
- (void)requestScanNow;

/// 异步扫描回调处理（供静态 C 回调 TRWifiScanCallback 调用；results 每项 WiFiNetworkRef）
- (void)handleScanResults:(CFArrayRef)results error:(int)error;

@end

/// 共享扫描结果 JSON 路径/更新通知/请求通知 → TRWifiScanContract.h（跨端契约单一真相源，2026-08-28）
/// 本头仅保留 daemon 内部默认扫描周期
/// 默认扫描周期（秒）
extern const NSTimeInterval kTRWifiScanIntervalSec;

NS_ASSUME_NONNULL_END