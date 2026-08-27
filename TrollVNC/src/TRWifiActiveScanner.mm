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

#import "TRWifiActiveScanner.h"
#import <notify.h>
#import <dlfcn.h>

/// 共享扫描结果 JSON 路径（root daemon 写；mobile 用户 App 可读——/var/mobile 权限宽松）
NSString *const kTRWifiScanJsonPath = @"/var/mobile/Library/Caches/com.82flex.trollvnc.wifiscan.json";
/// 扫描更新 Darwin 通知名（daemon notify_post → App notify_register_dispatch 订阅）
NSString *const kTRWifiScanUpdatedNotification = @"com.82flex.trollvnc.wifiscan-updated";
/// 默认扫描周期（秒；对齐「启动即自动获取 + 活跃订阅」语义，8s 低频省电）
const NSTimeInterval kTRWifiScanIntervalSec = 8.0;

/// 私有框架符号声明（MobileWiFi —— WiFiManagerClient* 异步 API，iOS 13+ IO80211FamilyV2 重构后的
/// locationd 同款接口。老式同步 Apple80211Scan 在新系统已失效：实测返回 rc=13 EACCES）
typedef void *WiFiManagerRef;
typedef void *WiFiDeviceClientRef;
typedef void *WiFiNetworkRef;
typedef WiFiManagerRef (*WiFiManagerClientCreateFunc)(CFAllocatorRef allocator, int flags);
typedef void (*WiFiManagerClientScheduleWithRunLoopFunc)(WiFiManagerRef manager, CFRunLoopRef runLoop, CFStringRef mode);
typedef CFArrayRef (*WiFiManagerClientCopyDevicesFunc)(WiFiManagerRef manager);
typedef void (*WiFiDeviceClientScanAsyncFunc)(WiFiDeviceClientRef device, CFDictionaryRef scanParams,
                                              void (*callback)(WiFiDeviceClientRef device, CFArrayRef results, int error, const void *object),
                                              const void *object);
typedef CFStringRef (*WiFiNetworkGetSSIDFunc)(WiFiNetworkRef network);
typedef CFTypeRef (*WiFiNetworkGetPropertyFunc)(WiFiNetworkRef network, CFStringRef key);

/// 异步扫描回调（静态 C 函数，经 self 指针访问实例）
static void TRWifiScanCallback(WiFiDeviceClientRef device, CFArrayRef results, int error, const void *object) {
    (void)device; // 回调签名必需；结果已含在 results
    TRWifiActiveScanner *self = (__bridge TRWifiActiveScanner *)object;
    if (!self) return;
    [self handleScanResults:results error:error];
}

@implementation TRWifiScanSnapshot

- (instancetype)initWithBssids:(NSArray<NSString *> *)bssids
                         ssids:(NSArray<NSString *> *)ssids
                          rssi:(NSArray<NSNumber *> *)rssi
                             ts:(NSTimeInterval)ts {
    self = [super init];
    if (self) {
        _bssids = [bssids copy];
        _ssids = [ssids copy];
        _rssi = [rssi copy];
        _ts = ts;
    }
    return self;
}

@end

@implementation TRWifiActiveScanner {
    dispatch_source_t _timer;
    void *_wifiHandle;      // MobileWiFi 框架句柄
    WiFiManagerClientCreateFunc           _mgrCreateFn;
    WiFiManagerClientScheduleWithRunLoopFunc _mgrScheduleFn;
    WiFiManagerClientCopyDevicesFunc      _mgrCopyDevicesFn;
    WiFiDeviceClientScanAsyncFunc         _devScanAsyncFn;
    WiFiNetworkGetSSIDFunc                _netGetSSIDFn;
    WiFiNetworkGetPropertyFunc            _netGetPropertyFn;
    WiFiManagerRef _manager;      // 复用的 manager（ScheduleWithRunLoop 一次）
    WiFiDeviceClientRef _device;  // 复用的 device client
    BOOL _scanning;
    BOOL _scanInFlight;
}

+ (instancetype)sharedScanner {
    static TRWifiActiveScanner *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[TRWifiActiveScanner alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self _loadMobileWiFi];
    }
    return self;
}

/// dlopen MobileWiFi 私有框架 + dlsym WiFiManagerClient* 异步 API 全套。
/// TrollStore daemon 以 root 运行，配合 com.apple.wifi.manager-access entitlement。
/// 唯一实现，不降级：任一符号缺失即显式报错返回 NO（用户定案：不做回退）。
- (BOOL)_loadMobileWiFi {
    if (_mgrCreateFn && _mgrCopyDevicesFn && _devScanAsyncFn && _netGetSSIDFn && _netGetPropertyFn) return YES;
    const char *fwPath = "/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi";
    void *h = dlopen(fwPath, RTLD_NOW);
    if (!h) {
        fprintf(stderr, "[wifiscan] dlopen MobileWiFi failed: %s\n", dlerror());
        return NO;
    }
    _mgrCreateFn     = (WiFiManagerClientCreateFunc)dlsym(h, "WiFiManagerClientCreate");
    _mgrScheduleFn   = (WiFiManagerClientScheduleWithRunLoopFunc)dlsym(h, "WiFiManagerClientScheduleWithRunLoop");
    _mgrCopyDevicesFn = (WiFiManagerClientCopyDevicesFunc)dlsym(h, "WiFiManagerClientCopyDevices");
    _devScanAsyncFn  = (WiFiDeviceClientScanAsyncFunc)dlsym(h, "WiFiDeviceClientScanAsync");
    _netGetSSIDFn    = (WiFiNetworkGetSSIDFunc)dlsym(h, "WiFiNetworkGetSSID");
    _netGetPropertyFn = (WiFiNetworkGetPropertyFunc)dlsym(h, "WiFiNetworkGetProperty");
    if (!_mgrCreateFn || !_mgrScheduleFn || !_mgrCopyDevicesFn || !_devScanAsyncFn || !_netGetSSIDFn || !_netGetPropertyFn) {
        fprintf(stderr, "[wifiscan] dlsym WiFiManagerClient* incomplete (create=%p sched=%p devs=%p scan=%p ssid=%p prop=%p)\n",
                _mgrCreateFn, _mgrScheduleFn, _mgrCopyDevicesFn, _devScanAsyncFn, _netGetSSIDFn, _netGetPropertyFn);
        return NO;
    }
    _wifiHandle = h;
    return YES;
}

- (void)start {
    if (_timer || _scanning) return;
    if (![self _loadMobileWiFi]) {
        // 框架不可用：周期 timer 空转无意义，直接不启动（log 已在 _loadMobileWiFi 内）
        return;
    }
    _scanning = YES;
    dispatch_queue_t q = dispatch_queue_create("com.82flex.trollvnc.wifiscan", DISPATCH_QUEUE_SERIAL);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(_timer,
        dispatch_time(DISPATCH_TIME_NOW, 0),                       // 首次立即扫（启动即获取）
        (uint64_t)(kTRWifiScanIntervalSec * NSEC_PER_SEC),        // 之后周期
        (uint64_t)(1.0 * NSEC_PER_SEC));                          // 1s 容差（低频省电）
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf _triggerScan]; // 异步触发：结果经 WiFiDeviceClientScanAsync 回调 → handleScanResults
    });
    dispatch_resume(_timer);
    fprintf(stderr, "[wifiscan] active scanner started (interval %.0fs)\n", kTRWifiScanIntervalSec);
}

- (void)stop {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    _scanning = NO;
    if (_device) { CFRelease(_device); _device = NULL; }
    if (_manager) { CFRelease(_manager); _manager = NULL; }
}

/// 触发一次异步主动扫描（locationd 同款 WiFiDeviceClientScanAsync；结果经 TRWifiScanCallback 回调）。
/// manager/device 首次复用（ScheduleWithRunLoop 一次），device 扫描需在 runloop 驱动的线程。
- (void)_triggerScan {
    if (_scanInFlight) return; // 上次扫描未回调：跳过本次（防堆积）
    if (!_mgrCreateFn || !_mgrCopyDevicesFn || !_devScanAsyncFn) return;
    if (!_manager) {
        _manager = _mgrCreateFn(kCFAllocatorDefault, 0);
        if (!_manager) {
            fprintf(stderr, "[wifiscan] WiFiManagerClientCreate failed\n");
            return;
        }
        CFArrayRef devices = _mgrCopyDevicesFn(_manager);
        if (!devices || CFArrayGetCount(devices) == 0) {
            fprintf(stderr, "[wifiscan] WiFiManagerClientCopyDevices empty (WiFi off?)\n");
            if (devices) CFRelease(devices);
            return;
        }
        _device = (WiFiDeviceClientRef)CFArrayGetValueAtIndex(devices, 0);
        CFRetain(_device); // 脱离数组后保留引用
        CFRelease(devices);
        if (_mgrScheduleFn) {
            _mgrScheduleFn(_manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        }
    }
    if (!_device) return;
    // 必须传空字典（airscan 实证：NULL 不触发扫描）
    CFDictionaryRef options = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                                                 &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    _scanInFlight = YES;
    _devScanAsyncFn(_device, options, &TRWifiScanCallback, (__bridge const void *)self);
    CFRelease(options);
}

/// 异步扫描回调处理（主队列调用；results 每项 = WiFiNetworkRef）
- (void)handleScanResults:(CFArrayRef)results error:(int)error {
    _scanInFlight = NO;
    if (error != 0 || !results) {
        fprintf(stderr, "[wifiscan] WiFiDeviceClientScanAsync error=%d\n", error);
        return;
    }
    NSMutableArray<NSString *> *bssids = [NSMutableArray array];
    NSMutableArray<NSString *> *ssids = [NSMutableArray array];
    NSMutableArray<NSNumber *> *rssis = [NSMutableArray array];
    CFIndex count = CFArrayGetCount(results);
    for (CFIndex i = 0; i < count; i++) {
        WiFiNetworkRef net = (WiFiNetworkRef)CFArrayGetValueAtIndex(results, i);
        if (!net) continue;
        if (_netGetSSIDFn) {
            CFStringRef ssid = _netGetSSIDFn(net);
            if (ssid) [ssids addObject:(__bridge NSString *)ssid];
        }
        if (_netGetPropertyFn) {
            CFStringRef bssid = (CFStringRef)_netGetPropertyFn(net, CFSTR("BSSID"));
            if (bssid && CFStringGetLength(bssid) >= 17) {
                [bssids addObject:(__bridge NSString *)bssid];
            }
            CFNumberRef rssi = (CFNumberRef)_netGetPropertyFn(net, CFSTR("RSSI"));
            if (rssi) {
                double v = 0;
                CFNumberGetValue(rssi, kCFNumberDoubleType, &v);
                [rssis addObject:@(v)];
            }
        }
    }
    fprintf(stderr, "[wifiscan] scan done: %lu APs\n", (unsigned long)bssids.count);
    if (bssids.count == 0) return; // 空结果不写 JSON（保持上次数据，防误清）
    TRWifiScanSnapshot *snap = [[TRWifiScanSnapshot alloc] initWithBssids:bssids ssids:ssids rssi:rssis
                                                                       ts:[[NSDate date] timeIntervalSince1970]];
    [self _writeSnapshot:snap];
    notify_post(kTRWifiScanUpdatedNotification.UTF8String);
}

/// 原子写共享 JSON（tmp + rename，对齐 SimLocationController kSimTrackFilePath 同款模式）
- (void)_writeSnapshot:(TRWifiScanSnapshot *)snap {
    NSDictionary *obj = @{
        @"ts"     : @(snap.ts),
        @"bssids" : snap.bssids ?: @[],
        @"ssids"  : snap.ssids ?: @[],
        @"rssi"   : snap.rssi ?: @[],
    };
    NSError *werr = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&werr];
    if (!json) {
        fprintf(stderr, "[wifiscan] JSON serialize failed: %s\n", werr.localizedDescription.UTF8String);
        return;
    }
    NSString *tmp = [kTRWifiScanJsonPath stringByAppendingString:@".tmp"];
    if (![json writeToFile:tmp atomically:YES]) {
        fprintf(stderr, "[wifiscan] write tmp failed\n");
        return;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:kTRWifiScanJsonPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:kTRWifiScanJsonPath error:NULL];
    }
    if (![[NSFileManager defaultManager] moveItemAtPath:tmp toPath:kTRWifiScanJsonPath error:NULL]) {
        fprintf(stderr, "[wifiscan] rename tmp failed\n");
    }
}

@end