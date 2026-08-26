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

#import "TVNCHotspotManager.h"
#import "TVNCServiceCoordinator.h"

#import <NetworkExtension/NetworkExtension.h>

@interface TVNCHotspotManager ()

@property (nonatomic, strong, readwrite) NSArray *lastNetworkList;
@property (nonatomic, copy, readwrite) NSString *lastScanSummary;
@property (nonatomic, assign, readwrite) BOOL diagRegisterResult;
@property (nonatomic, assign, readwrite) NSInteger diagCommandCount;
@property (nonatomic, assign, readwrite) NSInteger diagListCount;
@property (nonatomic, assign, readwrite) NSInteger diagBssidCount;
@property (nonatomic, copy, readwrite) NSString *diagLastListSample;

@end

@implementation TVNCHotspotManager

+ (instancetype)sharedManager {
    static TVNCHotspotManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
    }
    return self;
}

- (BOOL)registerWithName:(NSString *)name {
    NSDictionary *options = @{kNEHotspotHelperOptionDisplayName: name};
    __weak typeof(self) weakSelf = self;
    self.diagRegisterResult = [NEHotspotHelper registerWithOptions:options queue:dispatch_get_main_queue() handler:^(NEHotspotHelperCommand * _Nonnull cmd) {
        __strong typeof(self) strongSelf = weakSelf;
        [strongSelf handleCommand:cmd];
    }];
    return self.diagRegisterResult;
}

- (void)handleCommand:(NEHotspotHelperCommand *)command {
    self.diagCommandCount++;
    // 统一读取 networkList：FilterScanList/DisplayNetworks/Evaluate 等命令都可能携带网络列表，
    // 不依赖具体命令类型枚举——DisplayNetworks 为私有枚举（公开头无声明，bootstrap 编译失败教训 2026-08-27）。
    // captureNetworkList 自带 count==0 守卫，空列表安全。
    [self captureNetworkList:command.networkList];
    switch (command.commandType) {
        case kNEHotspotHelperCommandTypeNone:
            break;
        case kNEHotspotHelperCommandTypeFilterScanList:
            [self executeAutoStartupTaskIfNecessary];
            break;
        case kNEHotspotHelperCommandTypeEvaluate:
        case kNEHotspotHelperCommandTypeAuthenticate:
        case kNEHotspotHelperCommandTypePresentUI:
        case kNEHotspotHelperCommandTypeMaintain:
        case kNEHotspotHelperCommandTypeLogoff:
            [self executeAutoStartupTaskIfNecessary];
            break;
        default:
            break;
    }
}

- (void)captureNetworkList:(NSArray *)networkList {
    // 诊断：列表计数在空列表提前 return 前记录（空列表也要记 0——区分"无回调"与"回调空列表"）
    self.diagListCount = networkList.count;
    if (networkList.count == 0) {
        self.diagBssidCount = 0;
        self.diagLastListSample = @"";
        // 空列表也触发回调（诊断关键：让"回调但空"到达 UI，区分"无回调"与"回调空列表"；
        // handleWifiScanUpdate 对空数组安全——bssids.count==0 即 return）
        if (self.onNetworkListUpdated) {
            self.onNetworkListUpdated(@[], @"");
        }
        return;
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:networkList.count];
    NSInteger bssidCount = 0;
    for (NEHotspotNetwork *network in networkList) {
        if (network.BSSID.length >= 17) bssidCount++;
        [lines addObject:[NSString stringWithFormat:@"%@|%@|%ld",
                          network.BSSID ?: @"",
                          network.SSID ?: @"",
                          (long)(network.signalStrength * 100)]];
    }
    self.diagBssidCount = bssidCount;
    self.diagLastListSample = lines.firstObject ?: @"";
    self.lastNetworkList = networkList;
    self.lastScanSummary = [lines componentsJoinedByString:@"\n"];
    NSLog(@"[wifiscan] NEHotspotHelper networkList count=%lu\n%@",
          (unsigned long)networkList.count, self.lastScanSummary);
    // 主动通知观察者（captureNetworkList: 在主队列执行——registerWithName: 队列为 main，回调天然主队列）
    if (self.onNetworkListUpdated) {
        self.onNetworkListUpdated(self.lastNetworkList, self.lastScanSummary);
    }
}

- (void)executeAutoStartupTaskIfNecessary {
    [[TVNCServiceCoordinator sharedCoordinator] ensureServiceRunning];
}

@end
