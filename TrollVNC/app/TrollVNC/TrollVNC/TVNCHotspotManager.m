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
    return [NEHotspotHelper registerWithOptions:options queue:dispatch_get_main_queue() handler:^(NEHotspotHelperCommand * _Nonnull cmd) {
        __strong typeof(self) strongSelf = weakSelf;
        [strongSelf handleCommand:cmd];
    }];
}

- (void)handleCommand:(NEHotspotHelperCommand *)command {
    switch (command.commandType) {
        case kNEHotspotHelperCommandTypeNone:
            break;
        case kNEHotspotHelperCommandTypeFilterScanList:
            [self captureNetworkList:command.networkList];
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
    if (networkList.count == 0) {
        return;
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:networkList.count];
    for (NEHotspotNetwork *network in networkList) {
        [lines addObject:[NSString stringWithFormat:@"%@|%@|%ld",
                          network.BSSID ?: @"",
                          network.SSID ?: @"",
                          (long)(network.signalStrength * 100)]];
    }
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
