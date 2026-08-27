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

/// 私有框架符号声明（MobileWiFi —— Apple80211* 系列老式 C API，越狱/root 进程标准用法）
typedef int (*Apple80211OpenFunc)(void **handle);
typedef int (*Apple80211BindFunc)(void *handle, CFStringRef ifname);
typedef int (*Apple80211CloseFunc)(void *handle);
typedef int (*Apple80211ScanFunc)(void *handle, CFArrayRef *results, CFDictionaryRef parameters);

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
    Apple80211OpenFunc  _openFn;
    Apple80211BindFunc  _bindFn;
    Apple80211CloseFunc _closeFn;
    Apple80211ScanFunc  _scanFn;
    BOOL _scanning;
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

/// dlopen MobileWiFi 私有框架 + dlsym Apple80211 四件套。
/// TrollStore daemon 以 root 运行，无需额外 entitlement（越狱社区标准做法）。
/// 框架/符号加载（唯一实现，不降级）：open+bind+scan 任一缺失即显式报错返回 NO，
/// 避免静默降级掩盖"主动扫描未跑通"（用户定案：不做回退，保证唯一实现可靠工作）。
- (BOOL)_loadMobileWiFi {
    if (_openFn && _bindFn && _scanFn) return YES;
    const char *fwPath = "/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi";
    void *h = dlopen(fwPath, RTLD_NOW);
    if (!h) {
        fprintf(stderr, "[wifiscan] dlopen MobileWiFi failed: %s\n", dlerror());
        return NO;
    }
    _openFn  = (Apple80211OpenFunc)dlsym(h, "Apple80211Open");
    _bindFn  = (Apple80211BindFunc)dlsym(h, "Apple80211BindToInterface"); // 真机实测：MobileWiFi 导出的是 Apple80211BindToInterface（非 Apple80211Bind）
    _closeFn = (Apple80211CloseFunc)dlsym(h, "Apple80211Close");
    _scanFn  = (Apple80211ScanFunc)dlsym(h, "Apple80211Scan");
    if (!_openFn || !_bindFn || !_scanFn) {
        fprintf(stderr, "[wifiscan] dlsym Apple80211* incomplete (open=%p bind=%p close=%p scan=%p)\n",
                _openFn, _bindFn, _closeFn, _scanFn);
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
        TRWifiScanSnapshot *snap = [strongSelf _performScan];
        if (snap && snap.bssids.count > 0) {
            [strongSelf _writeSnapshot:snap];
            notify_post(kTRWifiScanUpdatedNotification.UTF8String);
        }
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
}

/// 执行一次 Apple80211 主动扫描（root 权限；与系统设置页同底层）。
/// 扫描返回 CFArrayRef，每项 CFDictionaryRef，键含 BSSID/SSID/RSSI。
- (TRWifiScanSnapshot *)_performScan {
    if (!_openFn || !_bindFn || !_scanFn) return nil;
    void *h = NULL;
    int rc = _openFn(&h);
    if (rc != 0 || !h) {
        fprintf(stderr, "[wifiscan] Apple80211Open failed rc=%d\n", rc);
        return nil;
    }
    int brc = _bindFn(h, CFSTR("en0")); // 绑定接口（Apple80211BindToInterface）
    CFArrayRef results = NULL;
    int src = _scanFn(h, &results, NULL); // parameters 传 NULL = 扫描全部周边 AP
    if (src != 0 || !results) {
        fprintf(stderr, "[wifiscan] Apple80211Scan failed rc=%d bindRc=%d\n", src, brc);
        if (_closeFn) _closeFn(h);
        return nil;
    }
    NSMutableArray<NSString *> *bssids = [NSMutableArray array];
    NSMutableArray<NSString *> *ssids = [NSMutableArray array];
    NSMutableArray<NSNumber *> *rssis = [NSMutableArray array];
    CFIndex count = CFArrayGetCount(results);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef ap = (CFDictionaryRef)CFArrayGetValueAtIndex(results, i);
        if (!ap) continue;
        CFStringRef bssid = (CFStringRef)CFDictionaryGetValue(ap, CFSTR("BSSID"));
        CFStringRef ssid  = (CFStringRef)CFDictionaryGetValue(ap, CFSTR("SSID"));
        CFNumberRef rssi  = (CFNumberRef)CFDictionaryGetValue(ap, CFSTR("RSSI"));
        if (bssid && CFStringGetLength(bssid) >= 17) {
            [bssids addObject:(__bridge NSString *)bssid];
        }
        if (ssid) [ssids addObject:(__bridge NSString *)ssid];
        if (rssi) {
            double v = 0;
            CFNumberGetValue(rssi, kCFNumberDoubleType, &v);
            [rssis addObject:@(v)];
        }
    }
    if (_closeFn) _closeFn(h);
    CFRelease(results); // 扫描结果数组由 scan 分配，显式释放
    fprintf(stderr, "[wifiscan] scan done: %lu APs\n", (unsigned long)bssids.count);
    return [[TRWifiScanSnapshot alloc] initWithBssids:bssids ssids:ssids rssi:rssis
                                                   ts:[[NSDate date] timeIntervalSince1970]];
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