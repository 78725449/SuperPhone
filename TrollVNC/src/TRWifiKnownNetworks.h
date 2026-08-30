/*
  TRWifiKnownNetworks - 已连接 WiFi 的已知网络条目修改器（2026-08-29 进阶实现）
  用途：软路由把 AP 改成目标 {SSID, BSSID} 后，设备需把已知网络条目键名+SSID 改成目标 SSID，
        设备才能按"同 SSID + 同加密 + 同密码"自动重连（iOS 已知网络按 SSID 匹配，BSSID 不参与）。

  数据结构（真机实证 /var/preferences/com.apple.wifi.known-networks.plist）：
    wifi.network.ssid.<SSID> → { SSID(data), SupportedSecurityTypes, BSSList[...],
                                  __OSSpecific__={BSSID,...}, Hidden, AddedAt, ... }
  修改：旧条目键 wifi.network.ssid.<old> → 键 wifi.network.ssid.<new>；SSID data 同步替换。
  通知：wifid 重载（launchctl kickstart system/com.apple.wifid）——待真机确认是否必需。

  红线：只改键名+SSID 字段；不碰加密/密码/BSSList（复用原条目配置，新 AP 须同加密同密码）。
*/
#ifndef TRWifiKnownNetworks_h
#define TRWifiKnownNetworks_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TRWifiKnownNetworks : NSObject

/// 修改当前连接网络的已知网络条目 SSID（old → new）
/// @param oldSSID 当前条目 SSID（键 wifi.network.ssid.<old>）
/// @param newSSID 目标 SSID（软路由改后的）
/// @return YES 修改成功；NO 失败（条目不存在/写盘失败/文件不可读）
+ (BOOL)renameKnownNetworkSSID:(NSString *)oldSSID to:(NSString *)newSSID error:(NSError *_Nullable *_Nullable)error;

/// 读当前连接 WiFi 的 SSID（CNCopyCurrentNetworkInfo；iOS15+ 定位权限已给则可用）
+ (nullable NSString *)currentSSID;

/// 读当前连接 WiFi 的 BSSID（软路由双定位校验用：SSID+MAC 防 2.4G/5G 同名歧义）
+ (nullable NSString *)currentBSSID;

@end

// ===== SCDynamicStore 兼容层（2026-08-30 真机验证）=====
// SDK 头文件将 SCDynamicStore* API 标记 API_UNAVAILABLE(ios) → 编译期直接调用报错（此前被误判为"运行期不可用"）。
// 真机实证：/usr/sbin/scutil（链接 SystemConfiguration.framework）可读 State:/Network/Interface/en0/AirPort
// 含 SSID/BSSID → 符号在 iOS dyld shared cache 中存在。此处自声明类型 + dlsym 运行时解析，绕开编译期标记。
// 供 TRWifiKnownNetworks.mm 与 SimLocationController.mm（WiFi 重连监听）共用。
typedef const struct __SCDynamicStore *TVSCDynamicStoreRef;
typedef void (*TVSCDynamicStoreCallBack)(TVSCDynamicStoreRef store, CFArrayRef changedKeys, void *info);
typedef struct {
    CFIndex version;
    void *info;
    const void *(*retain)(const void *info);
    void (*release)(const void *info);
    CFStringRef (*copyDescription)(const void *info);
} TVSCDynamicStoreContext;
typedef TVSCDynamicStoreRef (*TVFn_SCDynamicStoreCreate)(CFAllocatorRef allocator, CFStringRef name,
                                                          TVSCDynamicStoreCallBack callout, TVSCDynamicStoreContext *context);
typedef CFPropertyListRef (*TVFn_SCDynamicStoreCopyValue)(TVSCDynamicStoreRef store, CFStringRef key);
typedef Boolean (*TVFn_SCDynamicStoreSetNotificationKeys)(TVSCDynamicStoreRef store, CFArrayRef keys, CFArrayRef patterns);
typedef void (*TVFn_SCDynamicStoreSetDispatchQueue)(TVSCDynamicStoreRef store, dispatch_queue_t queue);

/// 一次性 dlopen SystemConfiguration + dlsym 解析符号；返回是否至少取到 Create/CopyValue（核心读能力）
BOOL TVLoadSCDynamicStore(TVFn_SCDynamicStoreCreate *_Nullable outCreate,
                          TVFn_SCDynamicStoreCopyValue *_Nullable outCopyValue,
                          TVFn_SCDynamicStoreSetNotificationKeys *_Nullable outSetKeys,
                          TVFn_SCDynamicStoreSetDispatchQueue *_Nullable outSetQueue);

NS_ASSUME_NONNULL_END
#endif /* TRWifiKnownNetworks_h */