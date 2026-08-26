# WiFi 定位伪装 Phase 2 实现计划（A 层 wifi 注入）

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 实现设计文档（`docs/superpowers/specs/2026-08-27-wifi-spoof-double-layer-design.md`）的 **A 层 wifi 模拟接线**——`SimLocationManager` 补 `setWifiScanResults:` 注入原语，把目标城市的真实 BSSID 集喂给 locationd，叠加 GPS 模拟（双管线并发不互斥）。含 accuracy 规范（wifi 源精度 10–100m，GPS 源 3–15m 已有）。

**架构：** `SimLocationManager`（manager daemon）新增 `injectWifiScanResults:`/`stopWifiScanSimulation` 原语，复用 CLSimulationManager 私有接口（entitlement 已有）；注入数据 = PC 端已采集的 `wps-expand-hz.json`（801 个真实 BSSID）转 ObjC 常量；与现有 `injectPoint:`（GPS 管线）并发调用，作用层不同不互斥。

**技术栈：** Objective-C++（SimLocationManager.mm）/ CLSimulationManager 私有 API / theos + CI。

**设计文档：** `docs/superpowers/specs/2026-08-27-wifi-spoof-double-layer-design.md` §核心模型·双管线 + §目标 App 分析结论 3（accuracy 规范）
**配套调研：** `outputs/2026-08-27-WiFi定位伪装-POC设计.md` §3（A 层接口补齐 + 字典键名猜想）

---

## 文件结构

- 修改：`TrollVNC/src/SimLocationManager.h` — 加 wifi 注入接口声明 + 总 stop（`stopAll`）
- 修改：`TrollVNC/src/SimLocationManager.mm` — 补 `setWifiScanResults:` 私有声明 + `_wifiSimulating` ivar + 注入/停止/总 stop 方法
- 创建：`TrollVNC/src/WpsBssidData.h` — 内置 BSSID 常量表（生成产物，仿 build-tr-corpus.mjs 模式）
- 修改：`TrollVNC/Makefile` — SimLocationManager 相关 target 加 `WpsBssidData` 源（manager 编译）
- 修改：`TrollVNC/src/SimLocationController.mm` — 总开关联动编排（GPS + wifi 同时启停，任务 5）
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m` — 统一目标位置源（锚点同时驱动坐标+BSSID，任务 5）
- 修改：`说明文档.md` — 同步 A 层 wifi 注入（§2.2 组件 / §4.11 或新增小节）

---

### 任务 1：SimLocationManager 补 wifi 注入原语

**文件：**
- 修改：`TrollVNC/src/SimLocationManager.h`
- 修改：`TrollVNC/src/SimLocationManager.mm`

**背景**：`SimLocationManager` 现在只有 GPS 单点注入（`injectPoint:`/`stop`）。本任务补 wifi 管线：`setWifiScanResults:`（私有接口，POC 稿 §3.1 明确要补，当前未声明）+ `_wifiSimulating` ivar + 注入/停止方法。注入序列对齐 GPS：stop → clear → setWifiScanResults → setSimulatedWifiPower → startWifiSimulation（wifi 模拟无 append/flush，对齐 Geranium/TrollBox 参考行为）。

- [ ] **步骤 1：读现有 SimLocationManager.h/.mm 确认结构**

读 `TrollVNC/src/SimLocationManager.h`（48 行）和 `SimLocationManager.mm`（115 行）。确认：CLSimulationManager 私有接口段（.mm L19-37）已有 `setSimulatedWifiPower:`/`startWifiSimulation`/`stopWifiSimulation`，**缺 `setWifiScanResults:`**；ivar 区（.mm L41-44）有 `_sim`/`_simulating`，缺 `_wifiSimulating`。

- [ ] **步骤 2：头文件加 wifi 注入接口**

在 `SimLocationManager.h` 的 `stop` 声明后加：

```objc
/// WiFi 扫描模拟注入（输入层）：setWifiScanResults + setSimulatedWifiPower + startWifiSimulation
/// @param scanResults  NSArray<NSDictionary *>，每项含 bssid/ssid/rssi/channel/age/timestamp（键名待 XPC 取证校准）
/// 与 GPS 注入（injectPoint:）并发不互斥——GPS 喂结果层、wifi 喂输入层，叠加自洽
- (void)injectWifiScanResults:(NSArray<NSDictionary *> *)scanResults;

/// 停止 wifi 扫描模拟：stopWifiSimulation + setSimulatedWifiPower:NO（恢复真实扫描源）
- (void)stopWifiScanSimulation;

/// 当前 wifi 模拟是否开启
@property(nonatomic, assign, readonly) BOOL isWifiSimulating;
```

- [ ] **步骤 3：.mm 补私有接口声明 + ivar**

在 `.mm` 的 CLSimulationManager 私有接口段（L19-37）补一条（POC 稿 §3.1）：

```objc
- (void)setWifiScanResults:(id)scanResults;
```

在 ivar 区（L41-44）补：

```objc
    BOOL _wifiSimulating;
```

- [ ] **步骤 4：.mm 实现 wifi 注入/停止方法**

在 `stop` 方法之后加：

```objc
- (BOOL)isWifiSimulating {
    return _wifiSimulating;
}

- (void)injectWifiScanResults:(NSArray<NSDictionary *> *)scanResults {
    if (!_sim || scanResults.count == 0) return;
    // 每次注入完整重启（对齐 GPS 注入语义）：先停旧的再起新的，保证新数据被 locationd 消费
    [_sim stopWifiSimulation];
    [_sim setSimulatedWifiPower:NO];
    [_sim setWifiScanResults:scanResults];
    [_sim setSimulatedWifiPower:YES];
    [_sim startWifiSimulation];
    _wifiSimulating = YES;
    NSLog(@"[locsim] wifi simulation start, %lu APs", (unsigned long)scanResults.count);
}

- (void)stopWifiScanSimulation {
    if (!_sim) return;
    [_sim stopWifiSimulation];
    [_sim setSimulatedWifiPower:NO];
    _wifiSimulating = NO;
    NSLog(@"[locsim] wifi simulation stopped");
}
```

- [ ] **步骤 5：静态自检**

- `setWifiScanResults:` 参数用 `id` 对齐现有接口段风格（该段全是 `id` 裸类型，勿提前用 NSArray<NSDictionary *> 破坏一致性）
- 头文件方法签名与 .mm 实现一致
- 无其他文件改动

- [ ] **步骤 6：Commit**

```bash
git add TrollVNC/src/SimLocationManager.h TrollVNC/src/SimLocationManager.mm
git commit -m "feat(device): SimLocationManager 补 wifi 扫描模拟注入原语（setWifiScanResults 输入层，与 GPS 并发）"
```

---

### 任务 2：WPS 数据内置（wps-expand-hz.json → ObjC 常量）

**文件：**
- 创建：`TrollVNC/src/WpsBssidData.h`（生成产物）
- 修改：`TrollVNC/Makefile`（trollvncmanager_FILES 加源）

**背景**：A 层注入需要目标城市的真实 BSSID 集。PC 端已采集 `wps-expand-hz.json`（801 个 BSSID + 坐标，自洽验证通过）。本任务把它转成 ObjC 常量表（仿 `build-tr-corpus.mjs` → `TRCorpus.mm` 生成模式），供 `injectWifiScanResults:` 使用。

- [ ] **步骤 1：确认 wps-expand-hz.json 结构**

读 `c:\Users\Administrator\Documents\ChatGPT\New project\wps-expand-hz.json` 的字段结构（bssid/lat/lon/rssi 等）。确认数据字段与 `setWifiScanResults:` 字典键名的映射（初始猜想：bssid/ssid/rssi/channel/age/timestamp，键名待 XPC 取证校准——本任务先用猜想键名，后续任务校准）。

- [ ] **步骤 2：写生成脚本（仿 build-tr-corpus.mjs 模式）**

先读 `scripts/build-tr-corpus.mjs`（或同类生成脚本）看生成模式：输入 JSON → 输出 .h/.mm 常量。创建 `scripts/build-wps-data.mjs`：

```js
// scripts/build-wps-data.mjs
// 输入：wps-expand-hz.json（BSSID 列表）
// 输出：TrollVNC/src/WpsBssidData.h（静态常量数组）
// 用法：node scripts/build-wps-data.mjs [input.json] [output.h]
import fs from 'node:fs';

const input = process.argv[2] ?? 'wps-expand-hz.json';
const output = process.argv[3] ?? 'TrollVNC/src/WpsBssidData.h';
const data = JSON.parse(fs.readFileSync(input, 'utf8'));

// 提取 BSSID 列表（按数据实际结构：可能是数组或 {bssids: [...]}）
const bssids = Array.isArray(data) ? data : (data.bssids ?? []);
// 只取字符串 BSSID，去重、大写
const uniq = [...new Set(bssids.map((b) => (typeof b === 'string' ? b : b.bssid).toUpperCase()))];

const lines = [
  '/*',
  ' * WpsBssidData.h — 目标城市真实 BSSID 常量表（生成产物，勿手改）',
  ' * 源数据：wps-expand-hz.json（apple-wps.mjs tile/expand 实测，801 个自洽验证）',
  ' * 生成：node scripts/build-wps-data.mjs',
  ' */',
  '#ifndef WpsBssidData_h',
  '#define WpsBssidData_h',
  '',
  '#define kWpsBssidCount ' + uniq.length,
  'static const char *kWpsBssids[kWpsBssidCount] = {',
  ...uniq.map((b) => `    "${b}",`),
  '};',
  '',
  '#endif',
];
fs.writeFileSync(output, lines.join('\n') + '\n');
console.log(`[build-wps-data] wrote ${uniq.length} BSSIDs to ${output}`);
```

- [ ] **步骤 3：跑生成脚本，验证产物**

```bash
node scripts/build-wps-data.mjs wps-expand-hz.json TrollVNC/src/WpsBssidData.h
```

验证：`TrollVNC/src/WpsBssidData.h` 生成成功，`kWpsBssidCount` 与数据实际 BSSID 数一致，格式正确（每行引号结尾 + 分号）。

- [ ] **步骤 4：Makefile 加源**

`TrollVNC/Makefile` 的 `trollvncmanager_FILES` 区（约 L139-144）加一行（wifi 注入在 manager daemon，A 层宿主）：
```makefile
trollvncmanager_FILES += src/WpsBssidData.h
```
（若 manager 编译不吃 .h 源，则改为在 `SimLocationManager.mm` 里 `#import "WpsBssidData.h"`，Makefile 加对应 .mm 或仅靠头文件导入——按项目实际 theos 规则处理，grep 现有 Makefile 中 .h 参与编译的先例。）

- [ ] **步骤 5：Commit**

```bash
git add scripts/build-wps-data.mjs TrollVNC/src/WpsBssidData.h TrollVNC/Makefile
git commit -m "feat(device): WPS 数据内置——wps-expand-hz.json 转 ObjC 常量表（801 个真实 BSSID，生成脚本）"
```

---

### 任务 3：accuracy 规范 + 字典键名校准

**文件：**
- 修改：`TrollVNC/src/SimLocationManager.mm`（或新增字典构建辅助）
- 修改：`TrollVNC/src/SimLocationController.mm`（确认 GPS 精度钳制注释对齐规范）

**背景**：设计文档「目标 App 分析结论 3」——accuracy 必须与定位源匹配：wifi 源 10–100m、GPS 源 5–30m。现状：[SimLocationController.mm L238-239](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/SimLocationController.mm#L238-L239) GPS 已钳制 3–15m（符合 5–30m 规范）。本任务：wifi 模拟的精度由注入字典的 rssi 分布决定（locationd 根据信号强度解算精度），需要在构建 scanResults 字典时给合理 rssi 值（-40~-85 dBm 范围，别全给满格），并注释说明键名待 XPC 取证校准。

- [ ] **步骤 1：读 POC 设计稿 §3.3 字典键名猜想**

读 `outputs/2026-08-27-WiFi定位伪装-POC设计.md` §3.3（初始猜想字典结构：bssid/ssid/rssi/channel/age/timestamp）。确认键名与 rssi 取值范围约定。

- [ ] **步骤 2：写 scanResults 字典构建辅助**

在 `SimLocationManager.mm` 加一个静态辅助（供 injectWifiScanResults: 或调用方构造字典），把 `kWpsBssids` 转成 `NSArray<NSDictionary *>`，rssi 取合理范围：

```objc
/// 构建 setWifiScanResults: 的字典数组（键名初始猜想，待 XPC 取证校准；rssi 给 -40~-85 合理范围）
+ (NSArray<NSDictionary *> *)buildScanResultsFromBssids:(const char **)bssids count:(NSUInteger)count {
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        double rssi = -40.0 - (double)(arc4random_uniform(4500)) / 100.0; // -40 ~ -85 dBm
        [results addObject:@{
            @"bssid": [NSString stringWithUTF8String:bssids[i]],
            @"ssid": @"",
            @"rssi": @(rssi),
            @"channel": @(1 + arc4random_uniform(13)),
            @"age": @(0),
            @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        }];
    }
    return results;
}
```

- [ ] **步骤 3：SimLocationController 注释对齐 accuracy 规范**

`SimLocationController.mm` L238-239 的钳制注释（若有）补充说明符合"GPS 源 5–30m"规范；无则不改（避免无谓改动）。

- [ ] **步骤 4：Commit**

```bash
git add TrollVNC/src/SimLocationManager.mm TrollVNC/src/SimLocationController.mm
git commit -m "feat(device): wifi 注入字典构建辅助——rssi 合理范围(-40~-85)，accuracy 规范对齐（wifi 10-100m/GPS 5-30m）"
```

---

### 任务 4：文档同步 + 收尾

**文件：**
- 修改：`说明文档.md`

- [ ] **步骤 1：说明文档同步 A 层 wifi 注入**

在 `说明文档.md` 定位相关章节（§4.11 之后或定位组件表）补：SimLocationManager 新增 wifi 扫描模拟注入（setWifiScanResults 输入层），与 GPS 注入并发不互斥；WpsBssidData.h 内置 801 个真实 BSSID；accuracy 规范（wifi 10-100m/GPS 5-30m）；总开关联动 + 统一目标位置源（用户拍板）。

- [ ] **步骤 2：确认无残留**

grep `injectWifiScanResults`/`kWpsBssids`/`WpsBssidData` 确认引用完整；对照 AGENTS.md「契约两端对齐」——本次为 App/daemon 内部 A 类能力，不新增注册表能力，无需改 caps.js。

- [ ] **步骤 3：Commit**

```bash
git add 说明文档.md
git commit -m "docs(device): 同步 A 层 wifi 扫描模拟注入（SimLocationManager + WpsBssidData + accuracy 规范 + 总开关联动）"
```

---

### 任务 5：总开关联动 + 统一目标位置源（用户拍板 2026-08-27）

**文件：**
- 修改：`TrollVNC/src/SimLocationManager.h` / `.mm` — 加总 stop
- 修改：`TrollVNC/src/SimLocationController.mm` — 总开关联动编排（GPS + wifi 同时启停）
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m` — 统一目标位置源（锚点/轨迹点同时驱动 GPS 坐标 + wifi BSSID 集）

**背景**：用户拍板两个决策——①**总开关联动**：定位开关同时控制 GPS + wifi 双管线，关闭时全部停止恢复真实；②**统一目标位置源**：用户选锚点/轨迹点时，同一目标位置同时驱动 GPS 坐标注入 + wifi BSSID 集注入。本任务实现这两个决策的编排层接线。

- [ ] **步骤 1：SimLocationManager 加总 stop**

在 `SimLocationManager.h` 加：

```objc
/// 总停止：GPS + wifi 模拟一并停止（总开关关闭时调用，恢复真实定位与真实扫描源）
- (void)stopAll;
```

在 `SimLocationManager.mm` 实现（复用已有 stop 与 stopWifiScanSimulation）：

```objc
- (void)stopAll {
    [self stop];                    // GPS：stopLocationSimulation + clear + flush
    [self stopWifiScanSimulation]; // wifi：stopWifiSimulation + power NO
}
```

- [ ] **步骤 2：SimLocationController 总开关联动**

读 `SimLocationController.mm` 的 stop 调用点（L84/L98）与注入链（L167-169 `injectPoint:`）。改造成：定位开关关闭 → 调 `stopAll`（GPS + wifi 一起停）；定位开启 → 依配置同时 `injectPoint:` + `injectWifiScanResults:`（wifi 数据来自 `kWpsBssids` 构建的 scanResults 字典，任务 3 的 `buildScanResultsFromBssids:`）。

```objc
// 伪代码示意（具体按现有 start/stop 结构接入）：
- (void)stop {
    [[SimLocationManager sharedManager] stopAll]; // 原 stop 改为 stopAll
}
```

- [ ] **步骤 3：App 统一目标位置源**

读 `TRMapPickerViewController.m` 的锚点选择/轨迹点生成逻辑（搜 `anchor`/`segmentPoints`/`injectPoint` 相关）。改造：目标位置确定时，除现有 GPS 注入外，同时用该位置反查/取 BSSID 集（`kWpsBssids` 或后续 tile 动态反查）→ `injectWifiScanResults:`。**注意**：wifi BSSID 集与目标位置的绑定，若用内置 `kWpsBssids`（杭州数据）则只支持杭州区域；跨区域需 Phase 后续的 tile 动态反查——本任务先用内置数据打通链路，注释说明跨区域待动态反查。

- [ ] **步骤 4：真机验证点记录**

在代码注释或说明文档记录两个真机验证点：
1. `injectPoint:` 的 `clearSimulatedLocations` 是否连带清 wifi 模拟（若会，GPS 每秒注入打断 wifi 管线，需调注入序列）
2. 总开关关闭后 GPS + wifi 是否都恢复真实（5902 日志确认）

- [ ] **步骤 5：Commit**

```bash
git add TrollVNC/src/SimLocationManager.h TrollVNC/src/SimLocationManager.mm TrollVNC/src/SimLocationController.mm TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m
git commit -m "feat(device): 总开关联动(GPS+wifi 一并启停) + 统一目标位置源(锚点同时驱动坐标与BSSID注入)"
```

---

## 自检记录

- **规格覆盖度**：设计文档 A 层 wifi 注入 → 任务 1（原语）+ 任务 2（数据源）+ 任务 3（字典/精度）；双管线并发 → 任务 1 步骤 4 注释明示与 injectPoint 不互斥；accuracy 规范（结论 3）→ 任务 3；总开关联动 + 统一目标位置源（用户拍板）→ 任务 5。阶段 0 验证（5902 日志确认模拟状态翻转）→ 各任务后由 CI + 真机执行（控制者）。
- **占位符扫描**：无"待定/TODO"；代码步骤含完整实现；字典键名为"初始猜想待 XPC 取证"是设计文档既定事实（非计划占位符），实现按猜想键名、校准留待真机取证任务。
- **类型一致性**：`injectWifiScanResults:` 签名（任务 1）与 `buildScanResultsFromBssids:`（任务 3）返回 NSArray<NSDictionary *> 匹配；`kWpsBssids`/`kWpsBssidCount`（任务 2 生成）与任务 3 消费一致；`isWifiSimulating`（任务 1 头文件 + .mm）一致；`stopAll`（任务 5）复用任务 1 的 `stopWifiScanSimulation` 与既有 `stop`，无新类型。
