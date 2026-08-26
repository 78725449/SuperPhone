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

@interface TVNCHotspotManager : NSObject

+ (instancetype)sharedManager;
- (BOOL)registerWithName:(NSString *)name;
- (void)executeAutoStartupTaskIfNecessary;

@property (nonatomic, strong, readonly) NSArray *lastNetworkList;
@property (nonatomic, copy, readonly) NSString *lastScanSummary;

/// 网络列表更新回调（主队列调用；networkList 非空时触发）
@property (nonatomic, copy, nullable) void (^onNetworkListUpdated)(NSArray *networks, NSString *summary);

/// 诊断：链路各环状态（App 进程内 wifi 链路可观测——5902 只收 daemon 日志，App 进程调试靠此）
@property (nonatomic, assign, readonly) BOOL diagRegisterResult;      // NEHotspotHelper 注册结果
@property (nonatomic, assign, readonly) NSInteger diagCommandCount;    // 收到系统命令总次数
@property (nonatomic, assign, readonly) NSInteger diagListCount;       // 最近一次 networkList 数量
@property (nonatomic, assign, readonly) NSInteger diagBssidCount;      // 最近一次提取的有效 BSSID 数（≥17 位）
@property (nonatomic, copy, readonly) NSString *diagLastListSample;    // 最近一次 networkList 首条摘要（BSSID|SSID|信号%）

@end

NS_ASSUME_NONNULL_END
