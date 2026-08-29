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

@end

NS_ASSUME_NONNULL_END
#endif /* TRWifiKnownNetworks_h */