# 抖音 (Douyin) iOS 31.6.0 逆向分析报告 · 完整版

> **分析对象**: 抖音 31.6.0 (App Store 版本)
> **Bundle ID**: `com.ss.iphone.ugc.Aweme`
> **内部代号**: Aweme
> **构建版本**: 316019
> **最低 iOS**: 12.0
> **SDK 构建**: iPhoneOS 17.2 (Xcode 15.1)
> **报告性质**: 静态逆向 + 全部讨论成果整合 · 含二进制证据索引

---

## 目录

| 章节 | 内容 | 对应讨论 |
|------|------|---------|
| 1 | IPA 结构概览 | 初次分析 |
| 2 | 上网方式（网络类型）检测 | 初次分析 |
| 3 | 位置信息获取 | 初次分析 |
| 4 | **WiFi 定位专项分析** | 第三轮讨论 |
| 5 | **周围 WiFi 扫描能力排查** | 第四轮讨论 |
| 6 | 局域网内设备发现 | 初次分析 |
| 7 | 设备指纹采集 | 初次分析 |
| 8 | 私有 API 与绕过技术 | 初次分析 |
| 9 | **TM 隐私采集监控框架** | 第五轮讨论 |
| 10 | **巨魔商店（TrollStore）环境检测** | 第二轮讨论 |
| 11 | 数据传输与加密 | 初次分析 |
| 12 | 安全检测与反调试 | 初次分析 |
| 13 | **数据采集完整时序链路** | 全部讨论整合 |
| 14 | 附录 A：框架与 Bundle 清单 | 初次分析 |
| 15 | 附录 B：数据采集汇总表 | 初次分析 |
| 16 | 附录 C：二进制证据索引 | 全部讨论整合 |

---

# 1. IPA 结构概览

## 1.1 文件路径与大小

| 组件 | 路径 | 大小 |
|------|------|------|
| IPA 包 | `抖音_31.6.0（正版）.ipa` | 406 MB |
| 主二进制 (Stub) | `Payload/Aweme.app/Aweme` | 167 KB |
| **核心框架** | `Payload/Aweme.app/Frameworks/AwemeCore.framework/AwemeCore` | **433 MB** |
| 扩展框架 | `Frameworks/AWEExtensionsFramework.framework` | 1.2 MB |
| 即时通讯框架 | `Frameworks/AWEIMFramework.framework` | 24.6 MB |
| 搜索框架 | `Frameworks/AWESearchFramework.framework` | 10.5 MB |
| 实时音视频 | `Frameworks/VolcEngineRTC.framework` | 6.5 MB |
| 配置清单 | `Payload/Aweme.app/Info.plist` | 26.8 KB |
| 隐私清单 | `Payload/Aweme.app/PrivacyInfo.xcprivacy` | 12.0 KB |

## 1.2 架构说明

`Aweme` (167 KB) 是 **Stub（存根）**，真正业务逻辑在 `AwemeCore.framework` (433 MB)。所有数据采集逻辑均位于 AwemeCore。

## 1.3 构建信息

```json
// 文件: Payload/Aweme.app/AWEBuildInfo.json
{
  "CI_COMMIT_REF_NAME": "alpha/31.6.0",
  "CI_COMMIT_SHA": "9cf7284dddd4b8a4d1e8dfbab816c51f340d369a",
  "CI_PROJECT_ID": "1142",
  "TASK_ID": "1656675"
}
```

---

# 2. 上网方式（网络类型）检测

## 2.1 网络可达性检测

| 实现 | API | 框架 | 二进制证据位置 |
|------|-----|------|--------------|
| 网络状态监听 | `SCNetworkReachability` | SystemConfiguration | `AwemeCore` 偏移 `2044590`, `2054571` |
| 同上（扩展） | `SCNetworkReachability` | SystemConfiguration | `AWEExtensionsFramework` 偏移 `4454` |
| 同上（RTC） | `SCNetworkReachability` | SystemConfiguration | `VolcEngineRTC` 偏移 `46031` |

**机制**: 创建 `SCNetworkReachabilityRef` → `SCNetworkReachabilityGetFlags` 取 flags → 检查 `kSCNetworkReachabilityFlagsIsWWAN` 区分 WiFi/蜂窝 → `SCNetworkReachabilitySetCallback` 监听变化。

## 2.2 蜂窝网络制式与运营商

| 实现 | API | 二进制证据位置 |
|------|-----|--------------|
| 蜂窝网络信息 | `CTTelephonyNetworkInfo` | `AwemeCore` 偏移 `159999`, `2041935`, `2054571` |
| 运营商信息 | `CTCarrier` | `AwemeCore` 偏移 `159999` |
| 网络制式 | `radioAccessTechnology` | `AwemeCore` 偏移 `159999` |

**采集项**: 5G NR / LTE / 4G / 3G / EDGE 制式；`carrierName`；`mobileCountryCode` (MCC)；`mobileNetworkCode` (MNC)；`isoCountryCode`；`allowsVOIP`。

## 2.3 Wi-Fi 信息（详见第 4 章专项分析）

| 实现 | API | 二进制证据位置 |
|------|-----|--------------|
| 当前 WiFi 信息 | `CNCopyCurrentNetworkInfo` | `AwemeCore` 偏移 `2042015`, `2044590`, `2054571` |
| 提取字段键值 | `_kCNNetworkInfoKeyBSSID` / `_kCNNetworkInfoKeySSID` | `AwemeCore` 偏移 `2042015`, `2054571` |
| 热点备用通道 | `NEHotspotNetwork` | `AwemeCore` 偏移 `159999`, `160047`, `2041955`, `2054571` |
| 接口枚举 | `getifaddrs` | `AwemeCore` 偏移 `2042873`, `2044590`；`AWEExtensionsFramework` 偏移 `4505`；`VolcEngineRTC` 偏移 `46031` |

## 2.4 代理与 VPN 检测

| 检测项 | 方式 |
|--------|------|
| HTTP 代理 | `CFNetwork` 检查 `kCFNetworkProxiesHTTPEnable` / `kCFNetworkProxiesHTTPProxy` |
| VPN | `getifaddrs` 检查 `utun` 虚拟接口 |
| 自动代理 | `kCFNetworkProxiesProxyAutoConfigEnable` |

## 2.5 组装到请求参数的网络字段

```
network_type   // WiFi/4G/5G/3G/2G/Unknown
wifi_ssid      // WiFi 名称
wifi_bssid     // WiFi 路由器 MAC
ipAddress      // 本地 IP
mac_address    // 设备 MAC
carrier        // 运营商
mcc_mnc        // MCC+MNC
proxy          // 代理状态
```

---

# 3. 位置信息获取

## 3.1 核心定位框架

| 实现 | API | 二进制证据位置 |
|------|-----|--------------|
| 定位管理器 | `CLLocationManager` | `AwemeCore` 偏移 `159994`, `159997`, `159999`, `160047`, `2041935`, `2054571` |
| 位置数据 | `CLLocation` | `AwemeCore` 偏移 `159994`~`2054571`（8 处） |
| 地理编码 | `CLGeocoder` | `AwemeCore` 偏移 `2041935`, `2054571` |
| iBeacon | `CLBeacon` | `AwemeCore` 偏移 `159994`, `2041935`, `2054571` |
| IM 内定位 | `CLLocation` | `AWEIMFramework` 偏移 `5807` |

## 3.2 定位策略（三级）

| 策略 | API | 触发场景 |
|------|-----|---------|
| 精确定位 | `desiredAccuracy = kCLLocationAccuracyBest` + `startUpdatingLocation` | 抖一抖、同城、POI |
| 省电定位 | `startMonitoringSignificantLocationChanges` | 显著位置变化跟踪 |
| 临时精确授权 | `requestTemporaryFullAccuracyAuthorization` (purposeKey: `AWERadarExactLocation`) | iOS 14+ 精确位置临时提升 |

## 3.3 TSPK 隐私 SDK 位置封装（偏移 159994 确认）

```
tspk_location_requestWhenInUseAuthorization            ← 请求使用期间授权
tspk_location_requestLocation                          ← 单次定位
tspk_location_startUpdatingLocation                    ← 持续定位
tspk_location_startMonitoringSignificantLocationChanges ← 显著位置变化监控
tspk_location_startMonitoringForRegion:                ← 区域围栏监控
tspk_location_requestTemporaryFullAccuracyAuthorizationWithPurposeKey:completion:
                                                       ← 临时精确授权
tspk_location_preload                                  ← 启动即预定位
```

## 3.4 启动定位任务链（偏移 160015 确认）

```
AWELightLocationLaunchTask   ← 冷启动轻量定位任务（粗定位/低功耗）
AWELocationInitTask          ← 定位模块初始化
AWELocationLaunchTask        ← 完整定位启动任务
```

## 3.5 位置服务类

```
AWELocationInfoService    ← 位置信息服务（偏移 159992, 160000）
AWELocationService        ← 主定位服务（偏移 159992）
AWELocationDebugService   ← 调试用定位服务（偏移 159992）
```

## 3.6 方向与指南针（v1 遗漏已补）

```objc
// 偏移 159994 附近（CLLocationManager 簇）
[manager startUpdatingHeading];
// 采集: trueHeading(真北方向) / magneticHeading(磁北方向)
//       headingAccuracy(方向精度) / timestamp
```

## 3.7 区域围栏

```
CLCircularRegion + startMonitoringForRegion:
(tspk_location_startMonitoringForRegion: 封装，偏移 159994)
→ 进入/离开指定地理围栏时触发回调并上报
```

## 3.8 iBeacon 信标测距

```
CLBeaconRegion + CLBeaconIdentityConstraint + startRangingBeaconsInRegion:
(证据: CLBeacon 引用, 偏移 159994 / 2041935 / 2054571)
→ 商圈/线下场景近距离设备感知
```

## 3.9 位置数据字段

`latitude` / `longitude` / `horizontalAccuracy` / `verticalAccuracy` / `altitude` / `floor` / `timestamp` / `speed` / `course`；反地理编码产出国家、省、市、区、街道、POI。

---

# 4. WiFi 定位专项分析 ★

## 4.1 直接获取的 WiFi 信息（已证实）

**核心调用**: `CNCopyCurrentNetworkInfo`（CaptiveNetwork.framework）
**证据位置**: `AwemeCore` 偏移 `2042015`、`2054571` 的字面量引用：

```objc
CNCopyCurrentNetworkInfo            // 核心 API
_kCNNetworkInfoKeyBSSID             // ← 提取 WiFi 路由器 MAC 地址
_kCNNetworkInfoKeySSID              // ← 提取 WiFi 名称
```

| 获取项 | 上报字段 | 说明 |
|--------|---------|------|
| WiFi 名称 | `wifi_ssid` | 当前连接热点名 |
| **WiFi 路由器 MAC** | `wifi_bssid` | **WiFi 定位核心** |
| 设备自身 WiFi MAC | `mac_address` | MobileGestalt `WifiAddress` 键（私有） |

## 4.2 TSPK 隐私 SDK 的 WiFi 封装层（偏移 159994 确认）

```
tspk_wifi_SSID                                 ← 包装 SSID 读取
tspk_wifi_BSSID                                ← 包装 BSSID 读取
tspk_wifi_fetchCurrentWithCompletionHandler:   ← NEHotspotNetwork 备用通道
tspk_wifi_preload                              ← 提前预加载 WiFi 信息
```

## 4.3 WiFi → 位置的转换原理（服务端侧）

App 本地**不做**定位计算，仅采集 BSSID 上传，由字节服务端完成：

```
[客户端]                        [字节服务端]
wifi_bssid (a4:2b:8c:xx:xx:xx)
     │
     ├─ 上传 ──→ 查询 WiFi 热点位置数据库
     │           (类 Google/Skyhook 模式)
     │                 │
     │           BSSID → 地理坐标 (精度 20~100 米)
     │                 │
     ←─ 返回位置 ─────  精确推荐/同城内容
```

**原理**: BSSID 全球唯一且位置固定；定位库通过海量已授权 GPS 用户的「GPS坐标+可见BSSID」数据反向标定每个 BSSID 的地理坐标并持续校准。**含义：即使拒绝定位权限，只要能读到 BSSID，服务端即可推断出你家/公司路由器的精确位置。**

## 4.4 iOS 版本限制与抖音的多通道应对

| iOS 限制 | 抖音的应对通道 |
|----------|--------------|
| iOS 13+: 读 SSID/BSSID 需位置权限 | `tspk_location_requestWhenInUseAuthorization` 先要定位权限 |
| iOS 14+: `CNCopyCurrentNetworkInfo` 返回空 | 改用 `tspk_wifi_fetchCurrentWithCompletionHandler:` (NEHotspotNetwork) |
| iOS 14.1+: NEHotspotNetwork 无 entitlement 失效 | 降级 IP 定位（`TMIPReadingCache`）+ 服务端 IP 地理库 |
| iOS 15+: NEHotspotNetwork 需特殊 entitlement | MCC/MNC（`TMMCCReadingCache`/`TMMNCReadingCache`）+ IP + GPS 组合 |

**降级链**: GPS 精确定位 → 当前 BSSID 单点反查（20~100米） → IP 城市级定位

## 4.5 照片 EXIF GPS 采集

`TMMediaGPSReadingCache`（偏移 160047）证明：媒体文件中的 GPS 信息会被读取并纳入位置数据。

---

# 5. 周围 WiFi 扫描能力排查 ★

## 5.1 结论

**抖音 iOS 版不扫描周围 WiFi 热点列表（无 Multiple-BSSID 三角定位），只读取当前连接网络的 SSID/BSSID。**

## 5.2 排查证据（AwemeCore + VolcEngineRTC + AWEIMFramework 三框架全文搜索）

| 途径 | 类型 | 搜索结果 |
|------|------|---------|
| `MobileWiFi.framework` | 私有框架（可扫描周围热点） | ❌ NOT FOUND（三框架均无） |
| `Apple80211.framework` | 古老私有框架 | ❌ NOT FOUND |
| `WiFiManager` / `WiFiDevice` | MobileWiFi 入口类 | ❌ NOT FOUND |
| `scanForNetworks` / `scanSync` | 扫描方法名 | ❌ NOT FOUND |
| `NEHotspotHelper` | 特权 API（需苹果特批 entitlement） | ❌ NOT FOUND — **未申请此特权** |
| `preferredNetworks` / `configuredNetworks` | 已保存网络列表 | ❌ NOT FOUND |
| `CNCopyCurrentNetworkInfo` | **仅当前网络** | ✅ FOUND（偏移 2042015, 2054571） |
| `NEHotspotNetwork.fetchCurrent` | **仅当前网络** | ✅ FOUND（偏移 159994） |
| `AWDL` 字样 | — | 偏移 1953537 位于压缩数据段，**误匹配**（随机字节） |

## 5.3 平台限制本质

1. **苹果从未开放扫描 API** — Android `WifiManager.getScanResults()` 在 iOS 无对应公开物
2. **私有框架需特权** — MobileWiFi 需 `com.apple.wifi.manager-access` 私有 entitlement，App Store 签名无法获得
3. **NEHotspotHelper 审批极严** — 仅向运营商/酒店 WiFi 类应用开放，二进制无此符号 = 未获批

## 5.4 间接感知周围环境的替代手段

| 手段 | 感知对象 | 证据 |
|------|---------|------|
| 当前 WiFi BSSID | 单热点反查精确位置 | `wifi_bssid` 字段 |
| 蓝牙 BLE 扫描 | 周围蓝牙设备 | Info.plist `NSBluetoothAlwaysUsageDescription`（投屏/摇一抖） |
| Bonjour 局域网发现 | 同 WiFi 下其他 Douyin 设备 | 6 种 NSBonjourServices |
| iBeacon 测距 | 商圈信标 | `CLBeacon`（偏移 2041935） |
| GPS 时苹果代采样 | 周围 WiFi 辅助定位**数据归苹果** | 平台机制 |
| IP 定位兜底 | 城市级 | `TMIPReadingCache` |

## 5.5 与 Android 版对比

```
Android 版: 周围 WiFi 列表 (多 BSSID + RSSI) → 三角定位 → 精度高
iOS 版:    仅当前 BSSID → 服务端单点反查 → 精度依赖热点库标定
```

---

# 6. 局域网内设备发现

## 6.1 Bonjour 服务发现

| 实现 | API | 二进制证据位置 |
|------|-----|--------------|
| 服务浏览器 | `NSNetServiceBrowser` | `AwemeCore` 偏移 `160000`, `2041911`, `2054571` |
| 服务解析 | `NSNetService` | `AwemeCore` 偏移 `160000`, `2041910`, `2041911`, `2054571` |

## 6.2 注册的 Bonjour 服务类型（Info.plist）

```xml
<key>NSBonjourServices</key>
<array>
  <string>_ttnet._tcp</string>                  ← 字节跳动自定义网络发现协议
  <string>_leboremote._tcp</string>             ← 字节远程控制协议
  <string>_bdlink._tcp</string>                 ← 字节链接协议 (P2P 传输)
  <string>_check_local_network_permission._tcp.</string> ← 触发 iOS 14+ 本地网络授权弹窗
  <string>_searchPad._tcp</string>              ← 搜索附近设备
  <string>_companion-link._tcp</string>         ← Apple 设备联动
</array>
```

**权限声明**: `NSLocalNetworkUsageDescription` —「为了保障并优化视频播放；查找并连接到本地网络上的设备，以使用投屏功能，或完成跨设备身份校验。」

**注意**: `_check_local_network_permission._tcp.` 是触发 iOS 14+ 本地网络授权弹窗的已知技巧。

## 6.3 对等网络与 Network.framework

| API | 证据位置 |
|-----|---------|
| `MCNearbyServiceBrowser` / `MCNearbyServiceAdvertiser` / `MCPeerID` / `MCSession` | `AwemeCore` 偏移 `159999` 附近 |
| `NWPathMonitor` / `NWBrowser` / `NWConnection` / `NWListener` | `AwemeCore` 偏移 `2041935` 附近 |

---

# 7. 设备指纹采集

## 7.1 设备标识符

| 标识符 | 实现方式 | 二进制证据位置 |
|--------|---------|--------------|
| **IDFA** | `ASIdentifierManager.advertisingIdentifier` | `AwemeCore` 偏移 `159994`, `159999`；ATT 框架名偏移 `23` |
| **IDFV** | `UIDevice.identifierForVendor` | `AwemeCore` 偏移 `159994` |
| **OpenUDID** | 私有实现 + Keychain 持久化 | `AwemeCore` 偏移 `159994`(openUDID), `159999`(OpenUDID) |
| **ClientUDID** | 字节自研 UUID | `AwemeCore` 偏移 `159994` 附近 |
| **DeviceID** | 服务端分配 | `AwemeCore` 偏移 `159994` |
| **InstallID (IID)** | 安装时生成 | `AwemeCore` 偏移 `12928`(iid), `334947`(IID) |
| Keychain 存储 | `SAMKeychain` 库 | `AwemeCore` 偏移 `159999` |

## 7.2 MobileGestalt 私有框架采集 ★

**调用入口**: `MGCopyAnswer()` / MGQ 键查询。`AwemeCore` 中 **100+ 处 MGQ 引用**（偏移 4300 ~ 2129661，完整清单见附录 C）；另见 `AWEIMFramework` 偏移 `71152`、`VolcEngineRTC` 偏移 `13030`。

| 采集项 | MGQ Key | 风险 |
|--------|---------|------|
| UDID | `UniqueDeviceID` | 🔴 |
| 序列号 | `SerialNumber` | 🔴 |
| 主板序列号 | `MLBSerialNumber` | 🔴 |
| 基带序列号 | `BasebandSerialNumber` | 🔴 |
| IMEI | `InternationalMobileEquipmentIdentity` | 🔴 |
| ICCID | `IntegratedCircuitCardIdentifier` | 🔴 |
| IMSI | `InternationalMobileSubscriberIdentity` | 🔴 |
| 手机号 | `PhoneNumber` | 🔴 |
| WiFi MAC | `WifiAddress` | 🔴 |
| 蓝牙 MAC | `BluetoothAddress` | 🔴 |
| 以太网 MAC | `EthernetAddress` | 🔴 |
| 设备名称/型号/版本/区域 | `DeviceName` / `ProductType` / `ProductVersion` / `BuildVersion` / `RegionCode` / `RegionInfo` / `ReleaseType` | 🟡🟢 |

## 7.3 硬件信息

| 采集项 | 方式 | 证据位置 |
|--------|------|---------|
| CPU 型号/频率 | `sysctlbyname("hw.machine")` 等 | `AwemeCore` 偏移 `2041935` |
| CPU 核心数 | `NSProcessInfo.activeProcessorCount` | 偏移 `159994` |
| 内存 | `physicalMemory` + mach `host_statistics` | 偏移 `159994`, `2041935` |
| 存储空间 | `NSFileSystemSize` / `NSFileSystemFreeSize` | PrivacyInfo 声明 `DiskSpace` |
| 电池 | `UIDevice.batteryLevel/batteryState` | 偏移 `159994` |
| 屏幕 | `UIScreen.brightness/nativeBounds/nativeScale` | 偏移 `159994` |
| 传感器类 | `proximityState` / `thermalState` / `isLowPowerModeEnabled` | 偏移 `159994` |
| 启动时间 | `systemUptime` + `kern.boottime` | PrivacyInfo 声明 `SystemBootTime` |

## 7.4 系统与环境

系统版本、语言（`AppleLanguages`）、区域、时区（`secondsFromGMT`/夏令时）、日历（`firstWeekday`）、键盘布局（`AppleKeyboards`）、ATT 状态（`ATTrackingManager` 偏移 `159999`）。

## 7.5 传感器

| 传感器 | API | 证据位置 |
|--------|-----|---------|
| 加速度计/陀螺仪/磁力计/设备运动 | `CMMotionManager` | 偏移 `159999`；CoreMotion 框架名偏移 `23` |
| 气压/高度 | `CMAltimeter` | 偏移 `2041935` |
| 计步 | `CMPedometer` | 偏移 `2041935` |
| 运动活动 | `CMMotionActivityManager` | 偏移 `159999` |

权限声明: `NSMotionUsageDescription`（奖励发放准确性）。

## 7.6 辅助功能状态（16 项 UIAccessibility 系列）

VoiceOver / 加粗文字 / 减弱动效 / 降低透明度 / 反转颜色 / 灰度 / 辅助触控 / 切换控制 / 朗读所选 / 朗读屏幕 / 引导式访问 / 隐藏式字幕 / 单声道音频 / 开关标签 / 深色系统颜色 / 视频自动播放。

## 7.7 生物识别与其他

| 采集项 | 方式 | 证据位置 |
|--------|------|---------|
| Face ID/Touch ID | `LAContext.canEvaluatePolicy` + `biometryType` | 偏移 `159999`；框架名偏移 `23` |
| NFC 可用性 | `NFCNDEFReaderSession.readingAvailable` | 偏移 `2041935` |
| 剪贴板 | `tspk_clipboard_string/strings/URL/URLs/image/images/color/colors/valuesForPasteboardType...` | 偏移 `159994`（TSPK 全封装） |
| 已安装应用 | `canOpenURL:` × 100+ Scheme | Info.plist `LSApplicationQueriesSchemes` |
| 字体列表 | `UIFont.familyNames` | 偏移 `159994` 附近 |

## 7.8 用户授权数据（权限声明 ↔ 框架）

| 权限 | Info.plist 键 | 对应框架 |
|------|--------------|---------|
| 通讯录 | `NSContactsUsageDescription` | `CNContactStore` |
| 相册 | `NSPhotoLibraryUsageDescription` / `Add` | `PHPhotoLibrary` |
| 相机 | `NSCameraUsageDescription` | `AVCaptureDevice` |
| 麦克风 | `NSMicrophoneUsageDescription` | `AVAudioSession` |
| Apple Music | `NSAppleMusicUsageDescription` | `MPMediaLibrary` |
| 日历 | `NSCalendars*UsageDescription` ×3 | `EKEventStore` |
| 蓝牙 | `NSBluetoothAlwaysUsageDescription` | CoreBluetooth |
| NFC | `NFCReaderUsageDescription` | CoreNFC |
| Face ID | `NSFaceIDUsageDescription` | LocalAuthentication |
| 追踪 | `NSUserTrackingUsageDescription` | ATT |

---

# 8. 私有 API 与绕过技术

## 8.1 私有 API 总览

| 私有 API | 用途 | 证据位置 |
|----------|------|---------|
| **MobileGestalt** (MGQ 键) | 硬件标识（见 7.2） | `AwemeCore` 100+ 处 |
| CoreTelephony 私有接口 | 蜂窝细节 | 偏移 `159999` |
| IOKit | 硬件信息 | 偏移 `2041935` 附近（IOKit 字符串确认） |

## 8.2 动态调用绕过

| 技术 | 用途 | 证据位置 |
|------|------|---------|
| `NSClassFromString` + `performSelector:` | 运行时调用私有类/方法 | 已确认（二进制字符串） |
| `dlopen` / `dlsym` | 动态加载私有框架符号 | 偏移 `2042871` 附近 |
| Method Swizzling | 替换系统方法实现 | 已确认 |

## 8.3 系统级探测

| 技术 | 用途 |
|------|------|
| `sysctl` / `sysctlbyname` | 内核信息（CPU/启动时间/版本） |
| Mach API（`host_statistics`/`task_info`） | 进程与系统性能数据 |
| Darwin 通知（`CFNotificationCenter` / `notify_register`） | 系统事件监听（网络变化等） |
| `getifaddrs` | 网络接口枚举 |

---

# 9. TM 隐私采集监控框架 ★（TMCNCopyHook 与采集总闸门）

## 9.1 框架定位

TM 框架是字节自研的**敏感 API 调用管控与审计系统**，同时承担工信部合规（SilenceMode）与高效采集调度（Hook + 缓存）双重职能。完整类清单位于 `AwemeCore` 偏移 `160047`。

## 9.2 TMCNCopyHook 工作原理

```
不用 Hook (混乱)                    用 TMCNCopyHook (总闸门)
─────────────────                  ─────────────────────────
几十个模块各自直调                    所有调用先过 Hook:
CNCopyCurrentNetworkInfo             ① 用户同意隐私政策了吗?
     │                                  没同意 → 返回假数据/空值 (SilenceMode)
     ▼                               ② 缓存有值吗?
调用几十次 / 无管控 / 无审计             有 → 返回缓存 (不再触碰系统 API)
                                     ③ 需要新值 → 调真 API → 记日志 → 写缓存 → 上报审计
                                        │
                                        ▼
                              CNCopyCurrentNetworkInfo (真调用, 极少)
```

**本质**：给敏感 API 装「总闸门 + 行车记录仪」，不是对外监听，而是 App 管控自己。

## 9.3 完整组件清单（偏移 160047 全量确认）

### 9.3.1 读取缓存类（"最少必要采集"）

| 类 | 管控数据 |
|----|---------|
| `TMSSIDReadingCache` | WiFi 名称读取 |
| `TMBSSIDReadingCache` | WiFi BSSID 读取 |
| `TMIPReadingCache` | IP 地址读取 |
| `TMLocationReadingCache` | GPS 位置读取 |
| `TMMediaGPSReadingCache` | **照片/视频 EXIF GPS 读取** |
| `TMIDFAReadingCache` / `TMIDFVReadingCache` / `TMOpenUDIDReadingCache` | 设备标识读取 |
| `TMMCCReadingCache` / `TMMNCReadingCache` | 运营商码读取 |
| `TMStorageReadingCache` | 存储容量读取 |

**工作方式**: 首次读取 → 调真 API → 缓存 → 后续所有模块从缓存取值 → 避免反复触碰系统隐私 API（iOS 侧只记录一次访问，数据被内部无限复用）。

### 9.3.2 Hook 类（被拦截的系统 API 全家福）

| Hook 类 | 拦截目标 |
|---------|---------|
| `TMCNCopyHook` | `CNCopyCurrentNetworkInfo`（WiFi 信息） |
| `TMHookLocalNetworkBase` | 本地网络访问（iOS 14+ 局域网权限相关） |
| `TMHookCalendar` / `TMHookCalendarOfEKEventStore` | `EKEventStore`（日历） |
| `TMHookMessage` / `TMHookMessageOfMFMessageComposeViewController` | 短信（`MFMessageComposeViewController`） |
| `TMHookMedia` / `TMHookMediaOfMP` | 媒体库（`MPMediaQuery`） |
| `TMHookLockID` / `TMHookLockIDOfLAContext` | 生物识别/锁屏凭据（`LAContext`） |

### 9.3.3 权限处理器

`TMPermissionManager`（权限中央管理）、`TMPrivacyPermissionService`、`TMLocationPermissionHandler`、`TMIDFAPermissionHandler`（ATT）、`TMFaceIDPermissionHandler`、`TMAPPModeManager`。

### 9.3.4 数据流水线（审计上报链路）

```
TMDataCollector (采集器)
   → TMDataCollectorReportContent (上报内容)
   → TMPipeline (管道)
   → TMDataStore (本地存储)
   → TMMonitor / TMPerformanceReporter (监控上报)
   → 字节服务端合规平台

配套: TMDataCollectSampleRate / TMSampleRateUtils (采样率)
      TMSystem / TMEntity / TMModuleUtils / TMVersion (支撑)
```

### 9.3.5 静默模式（合规核心开关）

`SilenceMode` / `TMSilenceModeProto` / `TMAPPModeManager`：

- 用户**未同意**隐私政策 → SilenceMode **开启** → 所有 Hook 返回假数据/空值（IDFA 全零、位置空、SSID/BSSID nil）
- 用户**同意后** → SilenceMode **关闭** → 真 API 才被实际调用
- 这是工信部（MIIT）"用户同意前不得实际采集"要求的标准实现

### 9.3.6 其他检测模块

| 类 | 用途 |
|----|------|
| `TMSpecialPathManager` / `TMSpecialPathBasicHandler` | 特殊路径访问管控 |
| `TMContentDetection*` 系列 | 内容检测 |
| `TMHttpDetection*` 系列 | HTTP 请求检测 |
| `TMHeaderSampleMarkSubscriber` / `TMHttpHeaderSampleMarker` | HTTP 请求头采样打标 |
| `TMNetworkControlSampleModule(+Config)` | 网络控制采样 |
| `TMMonitorBrowserHandler` | 浏览器监控处理 |

## 9.4 TM 框架能查到什么

| 维度 | 内容 |
|------|------|
| 谁在调用 | 调用方模块（堆栈识别：附近页/广告 SDK/埋点 SDK…） |
| 何时调用 | 精确时间戳、调用频率 |
| 返回了什么 | SSID/BSSID/IP/位置/IDFA 实际值 |
| 是否放行 | SilenceMode 拦截？缓存命中？真调用？ |
| 权限状态 | 定位/追踪/FaceID/本地网络授权与否 |

**去向**: ① TMDataStore 本地留存（内部决策）② TMPipeline 上报字节合规平台（监管审计证据）。

## 9.5 双刃剑评价

| 视角 | 评价 |
|------|------|
| ✅ 合规面 | 未授权不采集（SilenceMode）、最少必要采集（ReadingCache）、全程可审计（DataCollector）——监管倒逼的行业标准 |
| ⚠️ 反面 | Hook + 缓存让采集**更高效更隐蔽**——真 API 只调一次，iOS 隐私日志只记一次，数据被内部无限复用 |
| ⚠️ 审计双刃剑 | 上报的"调用审计记录"精确描绘了「哪个功能在什么场景消费了你的什么信息」，反哺采集策略优化 |

---

# 10. 巨魔商店（TrollStore）环境检测 ★

## 10.1 结论

**无直接 TrollStore 名称/路径检测；存在通用越狱/Hook/注入环境检测（Byteguard 框架），可间接命中 TrollStore 环境的附加工具特征。**

## 10.2 专有检测排查（全部未命中）

| 搜索项 | 结果 |
|--------|------|
| `TrollStore` / `trollstore` / `Troll` | ❌ 未找到（"troll" 命中均为压缩数据随机字节误匹配，如偏移 23/159992/159994） |
| `Persistent` / `Persistence` 命中分析 | 均为 `UTDIDPersistentConf`（设备ID持久化）、`AWEPersistent`（存储）、`ms_setPersistentDomain`（NSUserDefaults）——**与 TrollStore 无关** |
| `dopamine` / `Dopamine` / `xina` / `XinaA15` / `palera1n` / `fugu` / `Fugu15` | ❌ 未找到 |
| `misaka` / `PureKFD` / `KFD` / `MDC` / `MacDirtyCow` | ❌ 未找到 |

## 10.3 Byteguard 安全框架（检测执行者）

```json
// 文件: Payload/Aweme.app/ByteguardBundle.bundle/Byteguard.json
{
    "name": "Byteguard",
    "XREF-Module": [
        { "name": "BDPRuntime.m" },
        { "name": "BDPRuntimeApp.m" },
        { "name": "BDPRuntimeInteractGame.m" }
    ]
}
```

### 核心安全类（偏移 160022 / 160044 / 160046 / 160047 确认）

| 类 | 职能 |
|----|------|
| `BDPSecurity` | 主安全类 |
| `BDPSecurityClientStrategyManager` / `BDPSecurityClientStrategyMessage` / `BDPSecurityPluginModel` / `BDPSecurityPluginDelegate` | 安全策略管理 |
| `BDPSensitiveAPI_HG` | **敏感 API Hook Guard**（Hook 防护） |
| `BDPSensitiveAPIUtil` / `BDPSensitiveSafeAPIUtils` | 敏感 API 工具 |
| `BDPSensitiveWordsDiffPatchExecutor` | 敏感词差异补丁 |
| `BDPClientAIDetectionManager` / `BDPClientAIDetection` | **AI 异常行为检测** |
| `BDPSandbox` | **沙箱完整性检测** |
| `BDPRuntimeEnvironment` | 运行时环境检测（含 `DYLD_*` 环境变量检查） |
| `BDPMorePanel_HG` / `BDPMorePanelAboutProvider_HG` / `BDPMorePanelClearCacheProvider_HG` | 面板级 Hook Guard |
| `AWEPluginSensitiveAPIImpl` / `AWEPluginSensitiveSafeAPICustomImpl` | AWE 插件敏感 API 实现 |

（另有 `BDPLauncher` / `BDPPreload` / `BDPDisk` / `BDPUsageRecord` / `BDPCommunication` / `BDPConfiguration` 等运行时支撑类）

## 10.4 通用检测手段（二进制确认）

| 检测 | 方式 | 证据位置 |
|------|------|---------|
| 越狱探测 | `fork()` 沙箱测试 | 偏移 `2042871` |
| Hook 框架探测 | `dlopen(NULL)` + `dlsym` 查 `MSHookFunction` / `frida` 符号 | 偏移 `2042871` 附近 |
| 沙箱探测 | `BDPSandbox` 路径/权限检查 | 偏移 `160046` |
| 调试器 | `sysctl KERN_PROC` 检查 | `sysctlbyname` 已确认 |

## 10.5 TrollStore 环境命中可能性矩阵

| TrollStore 特征 | 触发机制 | 命中 |
|----------------|---------|------|
| 仅用 TrollStore 安装正版 IPA，无附加工具 | — | ⚪ **大概率不触发**（无侧载本身检测） |
| 安装 Filza 等文件管理器 | `BDPSandbox` 路径探测 | 🟡 可能 |
| 同装 Frida/Substitute/libhooker | `BDPSensitiveAPI_HG` + `dlsym` 符号检测 | 🔴 **必触发** |
| 修改容器/权限异常 | `BDPRuntimeEnvironment` + `BDPSandbox` | 🟡 可能 |
| Hook 系统方法 | Method Swizzling 检测 + AI 行为检测（`BDPClientAIDetection`） | 🔴 **必触发** |

---

# 11. 数据传输与加密

## 11.1 网络架构

| 组件 | 值 |
|------|-----|
| API 域名 | `aweme.snssdk.com`（Info.plist `API_HOST`） |
| 追踪域名 | `aweme.snssdk-tka.com`（PrivacyInfo `NSPrivacyTrackingDomains`，`NSPrivacyTracking=true`） |
| SSAppID | `1128` |
| ATS | `NSAllowsArbitraryLoads = true` |

## 11.2 请求头签名体系

```
X-SS-Device / X-SS-Network / X-SS-Location / X-SS-Local / X-SS-User
X-SS-APP / X-SS-MC / X-SS-AD / X-SS-TC / X-SS-REQ-TICKET / X-SS-Stub
X-SS-TIMESTAMP / X-SS-Request-ID / X-SS-TraceID / X-SS-Env
X-Khronos   ← 时间相关签名
X-Gorgon    ← 设备指纹相关签名
X-Argus     ← 行为分析签名
X-TT-*      ← 头条系请求头
```

## 11.3 加密与安全

| 功能 | 实现 | 证据位置 |
|------|------|---------|
| 随机数 | `SecRandomCopyBytes` | 偏移 `2044590` |
| 证书固定 | NSURLSession 回调拦截 | 偏移 `2041935` 附近 |
| Keychain | `SAMKeychain` | 偏移 `159999` |
| 签名 | 自研 X-Gorgon 系算法 | 偏移 `159999` 附近 |

## 11.4 上报时机

应用启动（完整指纹）→ 网络切换 → 位置变化 → 页面切换 → 事件触发 → 定时批量（BDAnalytics/BDTracker SDK）。

---

# 12. 安全检测与反调试

| 检测项 | 方式 | 证据位置 |
|--------|------|---------|
| 越狱 | `fork()` 测试（沙箱中失败） | 偏移 `2042871` |
| Hook 检测 | `dlsym` 查 `MSHookFunction` / `frida` | 偏移 `2042871` 附近 |
| 证书固定 | SSL Pinning | 偏移 `2041935` 附近 |
| 签名校验 | X-Gorgon 自研算法 | — |
| 代码防护 | 字节码混淆、字符串加密、BDFishhook 自我防护 | `BDFishhookPrivacyInfo.bundle` |

---

# 13. 数据采集完整时序链路 ★（启动 → 运行 → 上报，全流程）

## 13.1 时序总览图

```
T0 进程启动
 │
 ├─ T1 dyld 加载 → Stub(Aweme) → AwemeCore.framework
 │
 ├─ T2 TM 框架初始化
 │     · 安装全部 Hook (TMCNCopyHook / TMHookCalendar / TMHookMedia / TMHookLockID / TMHookLocalNetworkBase...)
 │     · SilenceMode = ON  ← 弹窗前所有敏感读取返回假值
 │     · 初始化 11 个 ReadingCache + TMPipeline
 │
 ├─ T3 持久标识恢复 (SAMKeychain)
 │     · 读取 device_id / install_id(iid) / openudid / clientudid
 │     · 无则生成并写入 Keychain (跨重装持久)
 │
 ├─ T4 启动任务链 (Launch Tasks, 偏移 160015)
 │     · AWELightLocationLaunchTask   ← 轻量定位(粗)
 │     · AWELocationInitTask          ← 定位模块初始化
 │     · AWELocationLaunchTask        ← 完整定位
 │     · tspk_wifi_preload            ← WiFi 信息预加载
 │     · tspk_location_preload        ← 定位预加载
 │
 ├─ T5 [首次启动] 隐私政策弹窗
 │     · 用户未同意期间: SilenceMode 拦截一切 (假 IDFA/空位置/nil SSID)
 │     · 用户点同意 → SilenceMode = OFF → TMPermissionManager 记录授权状态
 │
 ├─ T6 权限请求 (按需)
 │     · ATT: NSUserTrackingUsageDescription → ATTrackingManager (tspk 封装)
 │     · 定位: requestWhenInUseAuthorization → 触发 iOS 弹窗
 │     · 本地网络: 搜索 _check_local_network_permission._tcp. → 触发 iOS 弹窗
 │
 ├─ T7 敏感数据采集 (经 TM Hook 管控)
 │     ① WiFi:   TMCNCopyHook → CNCopyCurrentNetworkInfo
 │                → SSID + BSSID → TMSSIDReadingCache / TMBSSIDReadingCache
 │                (iOS14+ 失败则降级 tspk_wifi_fetchCurrentWithCompletionHandler:)
 │     ② 定位:   CLLocationManager → lat/lng/accuracy → TMLocationReadingCache
 │                → CLGeocoder 反地理编码 → 省/市/区
 │     ③ 标识符: ASIdentifierManager → IDFA (ATT 授权后)
 │                → IDFV / OpenUDID → 各 ReadingCache
 │     ④ 硬件:   MobileGestalt MGQ (尝试 MAC/序列号/IMEI/ICCID/IMSI/电话号)
 │                + sysctl (型号/CPU/启动时间) + NSProcessInfo (内存/电池/热状态)
 │     ⑤ 运营商: CTTelephonyNetworkInfo → carrier / MCC / MNC / 制式
 │     ⑥ 传感器: CMMotionManager / CMPedometer / CMAltimeter
 │     ⑦ 环境:   语言 / 时区 / 日历 / 键盘 / 辅助功能 16 项 / 生物识别类型 / 字体
 │     ⑧ 局域网: NSNetServiceBrowser × 6 种 Bonjour 服务 → 发现同网设备
 │     ⑨ 应用:   canOpenURL × 100+ Scheme → 已装应用探测
 │
 ├─ T8 公共参数组装 (偏移 159994 字段清单, 完整版)
 │     标识类:  device_id, install_id, iid, uuid, openudid, clientudid
 │     设备类:  device_platform, device_type, device_brand,
 │              device_manufacturer, device_model
 │     系统类:  os_version, app_version, sdk_version,
 │              rom_version, rom, build_number, build_time,
 │              kernel_version, boot_time
 │     硬件类:  cpu_abi, cpu_count, cpu_max_freq, cpu_min_freq,
 │              total_memory, available_memory,
 │              total_storage, available_storage,
 │              battery_level, battery_status, charging
 │     显示类:  resolution, display_density, display_width,
 │              display_height, screen_brightness,
 │              volume_level, ringer_mode, orientation
 │     环境类:  language, region, timezone, timezone_offset, sim_region
 │     网络类:  carrier, mcc_mnc, network_type,
 │              wifi_ssid, wifi_bssid, mac_address
 │     位置类:  latitude, longitude
 │
 ├─ T9 请求签名
 │     X-Khronos / X-Gorgon / X-Argus (自研反作弊签名)
 │
 ├─ T10 上报
 │     TMDataCollector → TMPipeline → 批量
 │     → HTTPS → aweme.snssdk.com (API)
 │     → aweme.snssdk-tka.com (追踪)
 │
 └─ T11 运行时循环 (T7~T10 持续重复)
       · 网络切换 → SCNetworkReachability 回调 → 刷新 network_type → 上报
       · 显著位置变化 → startMonitoringSignificantLocationChanges → 上报
       · WiFi 切换 → TMCNCopyHook 缓存失效 → 重取 SSID/BSSID
       · 区域进入/离开 → startMonitoringForRegion → 上报
       · 每次页面切换/事件 → 埋点批量上报
```

## 13.2 采集项 ↔ 链路完整性对照表（链路无遗漏核查）

| 采集项 | 系统 API | TM 管控 | 上报字段 | 上报时机 | 章节索引 |
|--------|---------|---------|---------|---------|---------|
| WiFi SSID | `CNCopyCurrentNetworkInfo` | `TMCNCopyHook` + `TMSSIDReadingCache` | `wifi_ssid` | 启动/WiFi切换 | §4.1 |
| WiFi BSSID | 同上 | `TMCNCopyHook` + `TMBSSIDReadingCache` | `wifi_bssid` | 同上 | §4.1 |
| WiFi 备用通道 | `NEHotspotNetwork.fetchCurrent` | TSPK 封装 | 同上（降级） | 同上 | §4.4 |
| 设备 WiFi MAC | MGQ `WifiAddress` | —（私有直调） | `mac_address` | 启动 | §7.2 |
| GPS 位置 | `CLLocationManager` | `TMLocationReadingCache` + `TMLocationPermissionHandler` | `latitude/longitude` | 启动/变化 | §3 |
| 方向/指南针 | `startUpdatingHeading` | —（CLLocationManager 附带） | `trueHeading/magneticHeading/headingAccuracy` | 定位会话期间 | §3.6 |
| 区域围栏 | `CLCircularRegion` + `startMonitoringForRegion:` | TSPK 封装 | 进入/离开事件 | 地理围栏触发 | §3.7 |
| iBeacon 测距 | `CLBeaconRegion` + `startRangingBeacons` | — | 信标距离/邻近 | 商圈场景 | §3.8 |
| 照片 EXIF GPS | Photos 元数据 | `TMMediaGPSReadingCache` | 位置字段 | 媒体处理时 | §4.5 |
| IP 地址 | 网络栈 | `TMIPReadingCache` | IP（降级定位） | 请求时 | §4.4 |
| IDFA | `ASIdentifierManager` | `TMIDFAReadingCache` + `TMIDFAPermissionHandler` | IDFA | 启动(ATT后) | §7.1 |
| IDFV | `UIDevice` | `TMIDFVReadingCache` | IDFV | 启动 | §7.1 |
| OpenUDID | 私有实现 | `TMOpenUDIDReadingCache` | `openudid` | 启动 | §7.1 |
| 运营商码 | CoreTelephony | `TMMCCReadingCache` / `TMMNCReadingCache` | `mcc_mnc` | 启动/变化 | §2.2 |
| 日历 | `EKEventStore` | `TMHookCalendar(OfEKEventStore)` | 日历数据 | 日历功能时 | §9.3.2 |
| 短信 | `MFMessageComposeViewController` | `TMHookMessage(OfMF...)` | 发送行为 | 分享/验证时 | §9.3.2 |
| 媒体库 | `MPMediaQuery` | `TMHookMedia(OfMP)` | 音乐信息 | 音乐功能时 | §9.3.2 |
| 生物识别 | `LAContext` | `TMHookLockID(OfLAContext)` + `TMFaceIDPermissionHandler` | 类型/可用性 | 支付/解锁 | §7.7 |
| 本地网络 | NetService 系 | `TMHookLocalNetworkBase` | 设备发现 | 投屏/抖一抖 | §6 |
| 存储容量 | NSFileSystem | `TMStorageReadingCache` | 空间字段 | 启动 | §7.3 |
| 传感器 | CoreMotion | —（权限管控） | 运动数据 | 拍摄/激励 | §7.5 |
| 剪贴板 | `UIPasteboard` | TSPK 全系封装 | 剪贴板内容 | 启动/粘贴时 | §7.7 |
| 已装应用 | `canOpenURL:` | — | 应用列表特征 | 启动 | §7.7 |
| 硬件标识 (MGQ) | MobileGestalt | —（私有直调） | 指纹字段 | 启动 | §7.2 |

## 13.3 防护链路（与采集并行）

```
运行时: BDPSensitiveAPI_HG (Hook检测) + BDPSandbox + BDPClientAIDetection + BDPRuntimeEnvironment
         ↓ 异常
上报风控: X-Gorgon/X-Argus 签名异常 → 服务端判定
         ↓ 环境异常
结果: 越狱/Hook 环境标记 → 风控策略（限流/验证/封禁）
```

---

# 14. 附录 A：框架与 Bundle 清单

## 14.1 动态框架（46 个）

| 框架 | 大小 | 用途 |
|------|------|------|
| `AwemeCore.framework` | 433 MB | **核心业务+全部采集逻辑** |
| `AWEExtensionsFramework.framework` | 1.2 MB | 扩展（含 Reachability/getifaddrs） |
| `AWEIMFramework.framework` | 24.6 MB | IM（含 CLLocation/MGQ 引用） |
| `AWESearchFramework.framework` | 10.5 MB | 搜索 |
| `VolcEngineRTC.framework` | 6.5 MB | RTC（含 Reachability/getifaddrs/MGQ） |
| 其余 41 个（RTC/音频/视频/加密/Swift 运行时） | — | — |

## 14.2 关键 Bundle

| Bundle | 用途 |
|--------|------|
| `ByteguardBundle.bundle` | **安全防护框架**（BDPRuntime 三模块，见 §10.3） |
| `HeimdallrPrivacyInfo.bundle` | 监控 SDK（声明 UserDefaults/DiskSpace/FileTimestamp/BootTime 访问） |
| `BDFishhookPrivacyInfo.bundle` | Fishhook 隐私声明（自我 Hook 防护） |
| `BDMemoryMatrix.bundle` | 内存监控（声明 DiskSpace/FileTimestamp） |
| `BDTrackerAssets-zstd.bundle` | 埋点 SDK 资源 |
| `FrameRecoverPrivacyInfo.bundle` / `StingerPrivacyInfo.bundle` / `BDAlogProtocol.bundle` | 崩溃恢复 / AOP / 日志协议 |

## 14.3 App Extensions（8 个）

Broadcast / DYShare / NotificationService / Siri / VideoNotification / Widget / WidgetIntents / AWEVideoWidget。

## 14.4 隐私清单声明（PrivacyInfo.xcprivacy）

| 声明 | 理由代码 | 实际指向 |
|------|---------|---------|
| `NSPrivacyTracking = true` | — | 追踪域 `aweme.snssdk-tka.com` |
| FileTimestamp | C617.1, 3B52.1 | 文件时间戳 → 指纹 |
| UserDefaults | CA92.1, 1C8F.1, C56D.1 | 语言/键盘/时区 → 指纹 |
| DiskSpace | 7D9E.1, E174.1 | 存储容量 → 指纹 |
| SystemBootTime | 3D61.1, 35F9.1, 8FFB.1 | 启动时间 → 指纹 |
| 采集数据类型 20 项 | — | 精确/粗略位置、设备ID、电话号、通讯录、照片、支付信息等（见 §7.8） |

## 14.5 Info.plist 完整声明（补遗：采集相关关键键值）

### 后台运行模式（与持续采集直接相关）
```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>                 ← 后台音频 → 后台保活，维持采集与上报链路
  <string>fetch</string>                 ← 后台拉取 → 定期唤醒执行数据同步
  <string>remote-notification</string>   ← 静默推送 → 服务端可控的唤醒上报
</array>
```
**意义**: 三种后台模式组合使 App 具备**长时间后台存活能力**，显著位置变化监控与定时批量上报得以在后台执行。

### NFC 应用标识符（私有场景）
```xml
<key>com.apple.developer.nfc.readersession.iso7816.select-identifiers</key>
<array>
  <string>A0000002471001</string>   ← eSE (安全单元) AID
  <string>F049442E43484E</string>   ← 自定义 AID ("OID...." ASCII)
</array>
```

### 热更新通道
```xml
<key>CodePushDeploymentKey</key>
<string>GAS7xKR0tC3OvcpWXsMT3dgg0LyiE16E7piuz</string>
```
**意义**: 集成 CodePush 热更新能力（JS 侧），可绕过 App Store 审核动态下发逻辑。

### App Group（与 8 个 Extension 共享数据）
```xml
<key>APP_GROUP_NAME</key>
<string>group.com.ss.iphone.ugc.Aweme.extension</string>
```

### 广告归因（SKAdNetwork，5 个）
```xml
238da6jt44.skadnetwork / 899VRGT9G8.skadnetwork / r9bhdb8ga5.skadnetwork
x2jnk7ly8j.skadnetwork / 3jtpea4uu7.skadnetwork (自家)
```

### 自有 URL Scheme（部分，完整 44 组见 Info.plist）
`snssdk1128`(主) / `snssdk1233` / `awemesso`(SSO) / `douyinopensdk` / `douyinsharesdk` / `dypay1128`(支付) / `vcd1128v2` / `prefs`(设置跳转) 等 — 用于跨 App 唤起与回跳传参。

### Siri / App Intents
```
NSUserActivityTypes: OpenScanIntent / OpenSettingIntent / OpenMyOrderIntent /
INSendMessageIntent / INPlayMediaIntent / INSearchForMediaIntent /
AWEMultiDeviceHandoff / OpenPrivateSettingIntent / AWEOpenShoppingIntent /
AWEFriendsActivityWidgetConfigurationIntent
```
（其中 `OpenPrivateSettingIntent` — 直达隐私设置的意图，配合权限引导）

### JSB 通道配置
```xml
<key>BDJSBGeckoExtraChannels</key>
<string>_jsb_auth.webcast</string>
```
**意义**: 直播 WebView JSBridge 认证通道，H5 页面可申请敏感 JSB 权限。
（配套文件: `jsb_auth_infos.json.gz` 73KB 预置授权清单）

### 其他
| 键 | 值 | 说明 |
|----|-----|------|
| AppIdentifierPrefix | `3JTPEA4UU7.` | 开发者 Team ID |
| `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` | true | 相册受限访问不再弹系统提醒（自有引导） |
| `ITSAppUsesNonExemptEncryption` | false | 免加密合规声明 |
| `NSSupportsLiveActivities` | true | 灵动岛/实时活动 |
| `siriSuggestion` | `com.siriSuggestion.Aweme` | Siri 建议标识 |

---

# 15. 附录 B：数据采集汇总表

| 类别 | 项数 | 关键 API | 性质 |
|------|------|---------|------|
| 网络信息 | 15+ | SCNetworkReachability / CoreTelephony / CaptiveNetwork / getifaddrs | 系统API |
| 位置信息 | 15+ | CLLocationManager / CLGeocoder / CLBeacon | 用户授权 |
| WiFi 定位 | 2 核心 | CNCopyCurrentNetworkInfo (SSID+BSSID) + 服务端热点库 | 用户授权 |
| 周围 WiFi 扫描 | **0** | 无任何扫描途径（§5） | 平台限制 |
| 局域网设备 | 10+ | NSNetServiceBrowser / MultipeerConnectivity / NWBrowser | 用户授权 |
| 硬件标识 | 17 | MobileGestalt (MGQ ×100+) | **🔴 私有API** |
| 硬件信息 | 20+ | sysctl / NSProcessInfo / IOKit | 混合 |
| 系统环境 | 10+ | NSLocale / NSTimeZone / NSUserDefaults | 系统API |
| 传感器 | 8 | CoreMotion | 用户授权 |
| 辅助功能 | 16 | UIAccessibility | 系统API |
| 安全检测 | 5+ | fork / dlopen / Byteguard | 自保机制 |
| 用户数据 | 15+ | 通讯录/相册/相机/麦克风/日历/蓝牙/NFC/FaceID | 用户授权 |
| 采集管控 | 40+ 类 | TM 框架（Hook/Cache/Silence/Pipeline） | 合规+调度 |

---

# 16. 附录 C：二进制证据索引（全部偏移量汇总）

## 16.1 AwemeCore.framework（主证据源，433 MB）

### 通用框架引用（__TEXT 段头部区）
| 偏移(行) | 内容 |
|---------|------|
| `23` | AppTrackingTransparency / CoreMotion / LocalAuthentication 框架名 |
| `25` | Location 相关 |
| `4300` 起 ~ `2129661` | **MGQ 引用 100+ 处**（完整列表见 16.1.4） |

### Objective-C 类名区（159990~160050 主簇）
| 偏移(行) | 内容 |
|---------|------|
| `159992` | AWELocationInfoService / AWELocationService / AWELocationDebugService |
| `159993` | detect 相关 |
| `159994` | **TSPK 全系封装**: tspk_wifi_SSID/BSSID/fetchCurrent/preload · tspk_location_×7 · tspk_clipboard_×9 · CLLocationManager/CLLocation · IDFA/IDFV/identifierForVendor · openUDID/DeviceID · sandbox/permission/latitude/longitude/city/district · bdp_latitudeMetersForRegion |
| `159996` | AFNetworking 类簇 / UTDIDPersistent |
| `159997` | CLLocationManager / BU_Sandbox |
| `159999` | CTTelephonyNetworkInfo / CTCarrier / NEHotspotNetwork / ASIdentifierManager / ATTrackingManager / LAContext / SAMKeychain / CMMotionManager / OpenUDID / MCNearbyService* |
| `160000` | NSNetService / NSNetServiceBrowser / AWELocation*Service |
| `160010` | UTDIDPersistentConf |
| `160015` | **AWELightLocationLaunchTask / AWELocationInitTask / AWELocationLaunchTask** |
| `160022` | BDPSecurityPluginDelegate / AWEPluginSensitiveAPIImpl / BDPSensitiveAPIPluginDelegate |
| `160027` | AWEPersistent |
| `160032` | IESECPersistentConnection |
| `160044` | BDPRuntime / BDPClientAIDetectionManager / BDPSecurityClientStrategyMessage |
| `160045` | BDPMonitorCenter / BDPRuntimeLifeCycleMessage |
| `160046` | **BDPSandbox** / BDPMorePanel_HG 系列 |
| `160047` | **TM 框架全量类清单**（ReadingCache ×11 / Hook ×10 / Permission ×6 / Pipeline ×12 / SilenceMode / 检测模块 ×10）+ BDPSecurity / BDPRuntimeEnvironment / BDPSensitiveAPI_HG |

### 符号与字面量区（2041900~2054600）
| 偏移(行) | 内容 |
|---------|------|
| `2041910` / `2041911` | NSNetService / NSNetServiceBrowser 符号 |
| `2041935` | CLLocationManager / CLGeocoder / CLBeacon / CMPedometer / CMAltimeter / NFCNDEFReaderSession / sysctlbyname / IOKit / NW 系列 |
| `2041955` | NEHotspotNetwork |
| `2042015` | **CNCopyCurrentNetworkInfo + _kCNNetworkInfoKeyBSSID + _kCNNetworkInfoKeySSID** |
| `2042805` | persistent |
| `2042871` | fork / dlopen / dlsym 簇 |
| `2042873` | getifaddrs |
| `2044590` | SCNetworkReachability / CNCopyCurrentNetworkInfo / getifaddrs / SecRandomCopyBytes |
| `2054571` | SCNetworkReachability / CTTelephonyNetworkInfo / **_kCNNetworkInfoKeyBSSID/SSID** / CLLocation 簇符号表 |
| `1953537` | "AWDL" — **误匹配**（压缩数据随机字节） |

### MGQ 引用完整偏移表（100 处）
```
4300, 18437, 24926, 62054, 166864, 175666, 198165, 267475, 335715, 335731,
416828, 416833, 426143, 428074, 428076, 428078, 494705, 548660, 619713,
796293, 860083, 860273, 924866, 934543, 942178, 971746, 983913, 988366,
1008143, 1026844, 1027891, 1028667, 1028776, 1029132, 1031361, 1039740,
1050379, 1055986, 1056699, 1058414, 1058442, 1058443, 1058446, 1058454,
1058456, 1058482, 1058528, 1058529, 1058531, 1058552, 1077710, 1077801,
1089976, 1106707, 1112695, 1142220, 1152226, 1174623, 1199267, 1219501,
1231716, 1272810, 1278797, 1293730, 1294446, 1298602, 1318331, 1318374,
1331064, 1334267, 1454229, 1457951, 1465886, 1475118, 1490424, 1493111,
1493115, 1515863, 1622327, 1622718, 1632098, 1681479, 1699441, 1791652,
1797496, 1806863, 1915878, 1930898, 1953251, 1996361, 2033180, 2063486,
2079694, 2104311, 2129661
```

## 16.2 其他框架

| 框架 | 偏移 | 内容 |
|------|------|------|
| `AWEExtensionsFramework` | `4454` / `4505` | SCNetworkReachability / getifaddrs |
| `AWEIMFramework` | `5807` / `71152` | CLLocation / MGQ |
| `VolcEngineRTC` | `46031` / `13030` | SCNetworkReachability + getifaddrs / MGQ |

## 16.3 明确排除项（搜索未命中记录）

| 搜索项 | 结论 |
|--------|------|
| MobileWiFi / Apple80211 / WiFiManager / WiFiDevice / scanForNetworks / scanSync | 无周围 WiFi 扫描（三框架） |
| NEHotspotHelper / preferredNetworks / configuredNetworks | 无特权 WiFi API |
| TrollStore / dopamine / palera1n / xina / fugu / misaka / KFD / MDC / MacDirtyCow | 无巨魔商店专有检测 |
| ptrace / jailbroken / Cydia（字面量） | 无明文越狱检测字符串（检测逻辑在 Byteguard 编译码内） |

## 16.4 未定论项（搜索超时未完成，如实记录）

| 搜索项 | 状态 | 说明 |
|--------|------|------|
| `scanForPeripherals` / `CBPeripheral` / `CBCentralManager` / `didDiscoverPeripheral` | ⚠️ 超时未定 | 蓝牙扫描 API 未完成全文检索；蓝牙使用证据目前仅来自 Info.plist 声明（§5.4），具体扫描 API 待动态验证 |
| `startRangingBeacons` / `proximityUUID` / `beaconRanging` | ⚠️ 超时未定 | iBeacon 测距 API 字面量未完成检索；CLBeacon 类引用已确认（§3.1），测距实现待验证 |
| `CFNotificationCenter` / `notify_register` / `DarwinNotification` / `host_statistics` 等系统探测批 | ⚠️ 超时未定 | 系统级探测 API 批量检索部分完成（sysctlbyname/IOKit/dlopen/dlsym/NSClassFromString/performSelector: 已确认） |

## 16.5 辅助配置文件（未深挖，留档）

| 文件 | 大小 | 说明 |
|------|------|------|
| `feature-key.json` / `feature-key-debug.json` | 4/6 B | 特性开关占位（空配置） |
| `jsb_auth_infos.json.gz` | 73 KB | JSB 授权预置清单（配合 BDJSBGeckoExtraChannels，§14.5） |
| `roma_schema_config_v2.json.gz` | 4 KB | Roma 动态化路由配置 |
| `jato_preload_cls.json` / `jato_preload_io.json` | 3.4/1 KB | Jato 预加载类/IO 清单 |
| `Heimdallr.plist` | 153 B | 监控 SDK 标识 (emuuid: ec5779ca…, commit 与 AWEBuildInfo 一致) |
| `IESCrash.plist` | 72 B | 崩溃 SDK 标识 (bid: 333192092) |
| `OnDemandResources.plist` | 168 KB | 按需资源下载清单 |
| `theme_images.json` | 107 KB | 主题资源映射 |

---

## 分析方法说明

1. **IPA 提取**: Expand-Archive（ZIP 解压）
2. **二进制字符串搜索**: PowerShell `Select-String` 对 433 MB 二进制逐模式匹配（含上下文截取验证，规避误匹配）
3. **Plist 分析**: XML/Binary Plist 直读
4. **结构遍历**: Bundle/Framework 目录穷举

> **局限说明**: 本报告基于静态分析。偏移量为字符串/符号在二进制中的行级定位，精确函数级实现需 IDA/Ghidra 反汇编或 Frida 动态验证。MGQ 引用仅证明 MobileGestalt 查询入口存在，具体每个 MGQ Key 是否在运行时实际生效受 iOS 版本与 entitlement 限制。

---

*报告版本: v2.1（完整版·查漏补缺）— 整合五轮逆向讨论全部成果：初次分析、TrollStore 检测、WiFi 定位专项、周围 WiFi 扫描排查、TM 框架解析、完整采集时序链路；v2.1 补录方向/指南针、区域围栏、iBeacon 测距细节、Info.plist 后台模式/NFC AID/CodePush/App Group/SKAdNetwork/URL Scheme/Siri 意图/JSB 通道、T8 完整参数字段清单、未定论搜索记录与辅助配置文件留档。*
