# WiFi 主动扫描（daemon Apple80211）实现计划

日期：2026-08-27
状态：已确认（用户拍板：实现 Apple80211 主动扫描，替代 NEHotspotHelper 被动通道的"去系统设置页激活"依赖）
关联：Phase 3/3.5 完成后真机暴露的链路缺口——真实 wifi 标注必须"打开系统 Wi-Fi 设置页"后才显示

## 问题根因（真机验证结论）

App 侧 `TVNCHotspotManager` 走 **NEHotspotHelper 被动回调模型**（`registerWithOptions:` 后只能等系统派发
FilterScanList/DisplayNetworks 命令）。iOS 上系统仅在**自身扫描活动**（打开系统 Wi-Fi 设置页持续扫描）时才派发——
App 无法主动触发系统扫描 → "必须去系统设置页拉一次列表"。

## 方案：daemon 侧 Apple80211 主动扫描（root 权限）

系统设置页底层就是 MobileWiFi 框架的 `Apple80211Open/Bind/Scan`。我们的 trollvncmanager 是 root 常驻进程，
可直接 dlopen 私有框架主动发起扫描（越狱社区标准用法）。

### 数据流

```
trollvncmanager（root）
  TRWifiActiveScanner（新模块）
    dlopen MobileWiFi.framework + dlsym Apple80211*
    周期扫描（默认 8s，活跃订阅语义；对齐"启动即自动获取"）
      → 周边 BSSID 列表
      → 写 /var/mobile/Library/Caches/com.82flex.trollvnc.wifiscan.json（mobile 可读）
      → notify_post("com.82flex.trollvnc.wifiscan-updated")
                        │ Darwin 通知
                        ▼
App TRMapPickerViewController.m
  订阅 wifiscan-updated → 读 JSON → BSSID 数组 → handleActiveWifiBssids:
    模拟开启：无视（模拟链路走 TRWpsTile 动态反查，已独立成立）
    模拟关闭：真实 BSSID → _queryWifiAnnoWithBssids: → wloc 反查 → wifi 标注（真实位置）
```

### 任务分解

#### 任务 1：新增 TRWifiActiveScanner 模块（src/TRWifiActiveScanner.h + .mm）

- `+ (instancetype)sharedScanner;` / `- (void)start;` / `- (void)stop;`
- dlopen `/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi`（不存在则日志降级退出）
- dlsym：`Apple80211Open` / `Apple80211Bind` / `Apple80211Close` / `Apple80211Scan`
- 典型调用序列（越狱社区共识）：

```objc
void *h = NULL;
Apple80211Open(&h);
Apple80211Bind(h, CFSTR("en0"));
CFArrayRef results = NULL;
Apple80211Scan(h, &results, NULL);   // NULL 参数 = 扫描全部周边 AP
// results 每项 = CFDictionaryRef，键含 BSSID/SSID/RSSI/CHANNEL
```

- GCD 周期 timer（dispatch_source，间隔 kScanIntervalSec=8，可在头文件暴露常量）
- 结果 JSON 形如：`{"ts":..., "bssids":["XX:..","YY:.."], "ssids":[...], "rssi":[...]}`，原子写（tmp+rename，对齐 kSimTrackFilePath 同款原子写模式）
- 写后 `notify_post("com.82flex.trollvnc.wifiscan-updated")`
- 扫描失败（wifi 未开/框架缺失）→ 日志降级，不崩溃；保留上次结果文件

#### 任务 2：Makefile 挂载 + trollvncmanager 启动

- `TrollVNC/Makefile`：`trollvncmanager_FILES += src/TRWifiActiveScanner.mm`
- `trollvncmanager.mm` 启动区（与 [SimLocationController sharedController] start / [TRDailyTrajectory start] 同块）
  追加 `[[TRWifiActiveScanner sharedScanner] start];`

#### 任务 3：App 侧订阅 + 真实 wifi 标注接线

- `TRMapPickerViewController.m` viewDidLoad（现有 wifi 水合段附近）：
  - `notify_register_dispatch("com.82flex.trollvnc.wifiscan-updated", ..., dispatch_get_main_queue(), ...)`
  - 回调 → 读 kSimWifiScanJsonPath JSON → 提取 BSSID 数组
  - 新增 `- (void)handleActiveWifiBssids:(NSArray<NSString *> *)bssids;`
    - `self.locating`（模拟开启）→ return（模拟链路独立，勿干扰）
    - 模拟关闭 → `[self _queryWifiAnnoWithBssids:bssids seq:++self.wifiQuerySeq];`（复用现有真实 wloc 反查标注链路）
  - 水合一次：启动时若 JSON 已存在（daemon 已扫过）直接消费

#### 任务 4：文档同步（Phase3.5 任务4 合并）

- `说明文档.md`：wifi 定位能力章节增补 "主动扫描（daemon Apple80211）"——真实 wifi 标注不再依赖系统设置页激活；
  NEHotspotHelper 保留为兜底通道
- 同步 `?v=N`（若涉及 web 静态资源则递增，本任务纯设备端+App，无 web 改动）

### 验收

1. CI 4 scheme 全部通过（`node scripts/wait-ipa.mjs`）
2. .tipa 内 `trollvncmanager` 二进制含 `TRWifiActiveScanner` 符号
3. 真机：系统定位关闭 + 模拟关闭 → 不进系统设置页，App 地图 8s 内出现真实 wifi 位置标注（wloc 反查 OK 标签）
4. 模拟开启时 wifi 标注不受主动扫描影响（仍走模拟反查）

### 已知坑（对照 AGENTS.md）

- daemon 新文件必须挂 `trollvncmanager_FILES`，否则 .deb 缺模块
- ObjC 类若只有声明无 @implementation 会链接失败（TRWpsTileAP 教训）——TRWifiActiveScanner 完整实现即可
- `.mm` C++ 编译：`void *` 转 `uint8_t *` 需显式 cast（parseWifiTile 教训）
- 并行编辑同一文件会互相覆盖——App 侧接线与后续文档修改必须串行