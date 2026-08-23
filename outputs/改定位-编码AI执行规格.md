# 改定位（GPS 注入 L3）· 编码 AI 执行规格（Handoff Spec）

> 供集成执行的编码 AI 使用。本文档是**唯一实施依据**；参考实证（CLSimulationManager 私有接口 / 注入姿势 / 拟人参数）来源见附录 D。
> 版本：v1.0（2026-08-21 与架构对齐定稿）｜状态：待执行
> 目标工程：SuperPhone `TrollVNC/`（Theos 工程，UIKit/ObjC++，CI 编译出 .tipa）；网关 `trollvnc-farm/`（Node ESM）
> 配套：《数据填充-编码AI执行规格.md》由另一编码 AI 执行（本规格只覆盖定位；跨功能自洽约束见 §1 C4）

---

## 0. 执行者须知（先读这段）

**角色**：你是负责把"全系统改定位"能力集成进现有 iOS IPA 工程的编码 AI。
**硬性前提**：目标设备已装 TrollStore（iOS 15.0–16.6.1 / 16.7 RC / 17.0）；能力执行在 `trollvncmanager`（root daemon，persona 99）进程内，**不是**在 App 前台。
**最高优先级**：先执行第 4 节 Go/No-Go 实验（实验 A 是唯一重大不确定性），实验结果决定后续；**禁止跳过实验直接写正式功能**。
**交付物**：2 个设备端源文件（SimLocationManager + SimLocationController）+ `sim.location.track` 控制能力（注册表 Native，大 payload 轨迹上传）+ 5802 `config.set` 管理命令（server 侧）+ 配置项注册 + entitlements/Makefile 改动 + 网关侧轨迹生成与 web 面板 + 实验记录表 + verify 脚本。
**开发顺序**（用户拍板）：网关 web 先行（开发期调试通道，热更新反复调）→ 设备端能力一次到位 → 全部敲定后再固化 App「伪装页面」定位 tab（生产主入口）；IPA 只编译一次，避免反复安装。

**入口模型（两类，本节为准）**：
- **外部（网关 web / 5801 / 远程调试）→ 全部经 TRCapabilityRegistry（注册表）**，只有两个方法入口：`invoke:`（控制型能力，含大 payload 轨迹上传 `sim.location.track`）与 `setConfig:`（配置型参数，经网关 configs API）。无第三套外部通道。
- **App 伪装页（生产主路径，离线自治）→ 走本地**：直接写设备 defaults / 轨迹文件（同域）+ `notify_post(prefs-changed)`，完全不经网关、不经 invoke。
- 两类入口最终落到同一落点：**设备端文件 + defaults → SimLocationController 自治执行**（唯一执行者与状态真相）。

---

## 1. 硬性约束（违反即返工）

| # | 约束 | 说明 |
|---|---|---|
| C1 | **执行者唯一** | 注入只发生在 `trollvncmanager` 内（root + OhMyJetsam 保活 + defaults 持久化）；网关/5801/App 一律只"调参"，不做注入 |
| C2 | **入口模型（两类）** | 定位参数 = 配置型（`setConfig:`，CONFIG_DEFS）+ 控制能力 = `invoke:`（注册表 Native，`sim.location.track` 轨迹上传）。**外部一律经注册表**（invoke/setConfig 两入口）；App 走本地 defaults/文件。禁止绕过注册表新增第三套外部通道 |
| C3 | **离线自治** | 参数持久化在设备端 defaults；manager 启动/失效自动恢复注入；网关断连不影响已设定定位 |
| C4 | **跨功能自洽** | 定位城市/时区必须与数据填充（联系人/通话/短信）的时间戳互洽——人在北京时区就 UTC+8，生成时间戳落本地时刻（与《数据填充规格》共享"目标场景"参数，见 §3.4） |
| C5 | **坐标系统** | 设备端只收 **WGS-84**；GCJ-02↔WGS-84 转换在网关/前端 JS（公开数学，附录 D）；禁止设备端做坐标转换 |
| C6 | **拟人** | 相邻上报位移 ≈ 速度×间隔（±10%）；精度 3–6m 抖动；海拔平滑；完成保持终点不 stop |
| C7 | **时区通知节流** | `AutomaticTimeZoneUpdateNeeded` 仅首次启动/跨时区发，禁止每次注入都发 |
| C8 | **私有接口自写** | CLSimulationManager 接口声明自写（附录 A），参考不复制（Geranium/Andromeda 均 GPL-3.0） |
| C9 | **零外部商业调用** | 不集成任何需 API Key/配额/付费的服务；不用第三方定位 SDK |
| C10 | **首版注入姿势** | 连续轨迹用 **mode A**（每秒全量重发，Andromeda 实证）；队列模式（locationInterval 推进）只作二期实验优化，不作首版赌注 |

---

## 2. 总体架构与模块清单

```
外部入口（开发期调试 + 生产期远程调参）—— 全部经 TRCapabilityRegistry（注册表）
  ├─ 网关 web 控制台   POST /api/devices/:id/configs → setConfig:（配置型参数）
  │                    POST /api/devices/:id/invoke  → invoke:（控制能力，含轨迹上传 sim.location.track）
  └─ 5801 直连页       5802 config.set（新增，外部局域网直连，走 5802 → defaults → prefs-changed）
App 入口（生产主路径，离线自治）—— 不经网关/注册表
  └─ App 伪装页（固化） 直接写设备 defaults / 轨迹文件（同域）+ notify_post(prefs-changed)
        ↓ 两类入口同一落点
设备端 trollvncmanager（root 常驻，唯一执行者）
  SimLocationController   自治控制器：双域读 defaults 参数 → 状态机（off/static/track）→ 失效巡检 + 参数变更感知 → 启动自恢复
    └─ SimLocationManager  CLSimulationManager 封装：注入原语（start/stop/append）+ 时区通知节流
        └─ locationd（系统）→ 全系统生效（任何 App 读到模拟坐标）
设备端 trollvncserver（5801/5802 宿主）
  5802 config.set（新增）  config 命令读写对称（config.get 已有白名单读；config.set 白名单写，与 config.get 同白名单：UI 行为参数 + SimLocation*，敏感配置不开放）→ 写当前用户域 plist → notify_post(prefs-changed)
网关侧（生成/UI，纯逻辑，开发期调试主力）
  TrajectoryGen（Node）   点序列生成（区域漫游/路线/GPX/往返）+ 拟人参数
  CoordTransform（共享 JS） GCJ-02↔WGS-84（公开数学；web 与 Node 共用同一模块）
  web 面板                定位 tab：预设城市/坐标输入（setConfigs）/ 轨迹参数（invoke sim.location.track）
```

**模块依赖方向（禁止反向依赖）**：
`外部 → 注册表（invoke/setConfig）`；`App → 本地文件/defaults`；二者 → `SimLocationController → SimLocationManager → CLSimulationManager`
`轨迹生成/坐标转换` 只在网关侧（Node/JS），设备端不包含。

---

## 3. 模块规格（接口签名 + 关键实现要点）

### 3.0 能力契约（配置项 CONFIG_DEFS，两端对齐）

新增 5 个配置项（网关 [caps.js](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/trollvnc-farm/web/caps.js) CONFIG_DEFS + 设备端 `_registerConfigSchemas` 各加一条，**数量同步 `caps-test.js` 断言**）：

| key | type | 说明 | reload |
|---|---|---|---|
| `SimLocationMode` | enum `off`/`static`/`track` | 关闭 / 单点 / 轨迹（默认 `off`） | instant |
| `SimLocationLat` | number | 目标纬度（WGS-84） | instant |
| `SimLocationLon` | number | 目标经度（WGS-84） | instant |
| `SimLocationAccuracy` | number 3~15 | 注入精度 | instant |
| `SimLocationSpeed` | enum `walk`/`cycle`/`drive` | 轨迹速度档（track 用） | instant |

**语义（关键）**：全部 `reload=instant`——instant 的现有语义是"只写 defaults、下次读取自动用新值"（无副作用分发）。sim 控制器通过**低频巡检轮询 defaults 感知变更**（复用 §3.2 失效巡检定时器），任一参数变化即重读并重新注入，**不改 setConfig 分发机制**。
**参数校验**：`SimLocationLat` 钳制 [-90, 90]、`SimLocationLon` 钳制 [-180, 180]（WGS-84 范围），setConfig 校验失败返回错误。
**入口与写入域（两类）**：**外部**经注册表 `setConfig:`（网关 configs API → manager 写 root 域；5801 `config.set` → 写当前用户域）；**App 伪装页**直接写 mobile 域 plist（`/var/mobile/Library/Preferences/com.82flex.trollvnc.plist`）；manager 统一**双域读取**（root 域 → mobile 域 plist 回退，复用 `tvManagerReadPref` 模式，见 §3.3）。
**大 payload（轨迹点序列）**：不进 CONFIG_DEFS。**外部经注册表 `invoke:` 控制能力 `sim.location.track` 上传**（params.points → 设备端落盘文件 + 切 track）；**App 本地直接写轨迹文件**。`SimLocationMode=track` 时设备端从文件加载点序列自治推进（见 §3.3）。

### 3.1 SimLocationManager（注入原语，约 150 行）

```objc
// src/SimLocationManager.h
@interface SimLocationManager : NSObject
+ (instancetype)sharedManager;
/// 单点注入：stop → clear → append → flush → start（附时区通知节流）
- (void)injectPoint:(CLLocationCoordinate2D)coord
           altitude:(double)alt
           accuracy:(double)acc
             course:(double)course
              speed:(double)speed;
/// 停止注入：stop → clear → flush（附时区通知节流）
- (void)stop;
/// 当前是否处于注入中（供失效巡检）
@property(nonatomic, assign, readonly) BOOL isSimulating;
@end
```

要点：
- `CLSimulationManager` 私有类声明自写（附录 A）；属性只用到 `locationDeliveryBehavior` 等按需设置，默认即可
- `CLLocation` 用**完整构造器**：`initWithCoordinate:altitude:horizontalAccuracy:verticalAccuracy:course:speed:timestamp:`（course/speed 随轨迹填充，不能 speed=0 坐标却在动）
- 时区通知：`CFNotificationCenterPostNotificationWithOptions(..., "AutomaticTimeZoneUpdateNeeded", ...)`，节流（仅首次启动/跨时区，见 C7）
- 本模块只做注入原语，**不做状态机/持久化**（由 Controller 负责）

### 3.2 SimLocationController（自治控制器，核心状态机）

```objc
// src/SimLocationController.h
@interface SimLocationController : NSObject
+ (instancetype)sharedController;
/// manager 启动时调用：读 defaults 参数 → 恢复上次模式（离线自治）
- (void)start;
/// setConfig 变更后调用（或订阅 defaults 通知）：重读参数并重新注入
- (void)reloadFromPrefs;
/// 失效巡检：检测模拟失效（mode!=off 且非模拟中）→ 节流重发
- (void)checkAndRestore;
@end
```

状态机：`off → static → track`（defaults `SimLocationMode` 驱动）
- **off**：不注入；`stop` 清队列恢复真实定位
- **static**：`injectPoint` 一次；失效巡检兜底（每 10s 一次 `checkAndRestore`，若失效则重注入）
- **track**：加载轨迹文件（§3.3）点序列到内存；**1s dispatch timer 逐点 `injectPoint`**（mode A，Andromeda 实证姿势）；推进完**保持终点不 stop**（C6）；支持 pause/resume（timer 挂起）

要点：
- **持久化与自恢复**：参数全在 defaults；`start` 时读 `SimLocationMode` 恢复上次状态（离线自治核心，C3）——manager 重启/设备重启后定位自动恢复，不依赖网关/App
- **失效巡检 + 参数变更感知（合一）**：`checkAndRestore` 每 10s，做两件事：① 判断"mode!=off 且注入异常"则节流重发（节流思路参考 TRWatchDog throttle）；② **双域读取** defaults（root 域 → mobile 域 plist 回退，复用 `tvManagerReadPref` 模式）比对 `SimLocation*` 是否有变化，变化则重读参数并重新注入——以此感知 App 本地/5801 写入的变更，**不改 setConfig 分发机制**
- **保活**：Controller 跑在 manager 进程内，manager 已由 OhMyJetsam（constructor 自动执行）设为 critical + 不可冻结，**无需新增进程级保活**
- **时序**：`injectPoint` 内部 stop→clear→append→flush→start，每秒一次对 locationd 无压力（Andromeda 实测）

### 3.3 入口与传递（两类：外部经注册表 / App 走本地）

**外部入口（全部经 TRCapabilityRegistry）**：

1. **网关 web**：`POST /api/devices/:id/configs` → 隧道 → manager `setConfig:` 写 root 域（配置型参数，controller 巡检感知 §3.2 ②）；`POST /api/devices/:id/invoke {cap:'sim.location.track', params:{points}}` → 隧道 CMD 帧 → manager `invoke:` → executor（§3.3.1）
2. **5801 直连页（新增命令）**：5801 前端 `mgmtRequest('config.set', {keys, values, ...})` → **新增** 5802 管理 API `config.set`（trollvncserver 侧，与已有 `config.get` 成对、**白名单对称**：现有 `config.get` 可读的 UI 行为参数键（FabAutoCollapse 等）+ 新增 `SimLocation*` 均可写，密码/证书等敏感配置不开放）→ 写当前用户域 plist（与 config.get 同域）→ `notify_post(prefs-changed)` → manager 感知。命令表 ops 列表同步加 `config.set`

**App 入口（生产主路径，离线自治）**：App（mobile 进程）直接写 mobile 域 `com.82flex.trollvnc` plist（`/var/mobile/Library/Preferences/com.82flex.trollvnc.plist`，App 自己的 NSUserDefaults suite 即此路径）+ 轨迹文件 → `notify_post("com.82flex.trollvnc.prefs-changed")` → manager 已有订阅（[trollvncmanager.mm](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncmanager.mm#L622-L642)）→ controller 感知。**不加新通知名，复用现有双通知自治模型**。

**manager 双域读取**：controller 统一用 `tvManagerReadPref` 模式（root 域 → mobile 域 plist 回退，[trollvncmanager.mm](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncmanager.mm#L142-L148)），外部与 App 写入均可见。

#### 3.3.1 `sim.location.track`（注册表 Native 控制能力，大 payload 轨迹上传）

```objc
// 注册（TRCapabilityRegistry _registerNativeCapabilities，route=TRCapRouteNative）
// capId: sim.location.track
// params: { points: [ {lat, lon, speed, course, alt, acc}, ... ] }   // WGS-84，拟人参数已含
// 行为：① 校验 points 非空、坐标在范围（lat∈[-90,90]、lon∈[-180,180]）
//       ② 原子写轨迹文件 /var/mobile/Library/Caches/com.82flex.trollvnc.simloc.json（§3.3.2 格式）
//       ③ 写 SimLocationMode=track（defaults，root 域）
//       ④ 返回 {ok, count}
// Controller 巡检/通知感知 mode 变化 → 从文件加载点序列逐秒注入（mode A）
```

要点：
- **只做"数据搬运 + 触发"**，不做生成：点序列由网关 `TrajectoryGen` 生成（§3.4），executor 只落盘 + 切 mode，Controller 自治推进——与"设备端唯一执行者、参数自治"语义一致
- **幂等全量覆盖**：每次调用覆盖整个轨迹文件（不做增量拼接），避免外部多次调用互相干扰
- **16MB 隧道帧约束**：1 小时轨迹 3600 点 ≈ 200KB、24 小时 ≈ 5MB，均在安全范围；超长轨迹由网关分块多次调用（每块覆盖式，最后一帧携带全量）
- **App 离线路径不走本能力**：App 直接写轨迹文件 + defaults（同域），Controller 双域读取同样可见

#### 3.3.3 `sim.route.calculate`（注册表 Native 控制能力，Apple 地图原生算路）

```objc
// 注册（TRCapabilityRegistry _registerNativeCapabilities，route=TRCapRouteNative）
// capId: sim.route.calculate
// params: { from: {lat, lon}, to: {lat, lon}, mode: 'walk'|'drive' }
// 行为：① 校验 from/to 坐标范围
//       ② 异步 MKDirections 算路（walk→walking 1.4m/s / drive→automobile 13.9m/s；仅两个稳定真实档）
//       ③ 算路完成：MKRoute.polyline 坐标 → 按速度重采样（步长=speed×1s + 拟人参数，对齐 §3.3.2 格式）
//       ④ 原子写轨迹文件 + 切 SimLocationMode=track → Controller 自治推进
//       ⑤ 立即返回 {ok, status:'calculating'}（MKDirections 联网 1-3s 超 invoke 5s 超时，故异步）
```

要点：
- **沿真实道路**：MKDirections 返回 MKRoute.polyline 即沿路坐标，重采样后轨迹贴道路，不穿楼
- **零第三方/零部署**：Apple 原生能力（MKDirections/MapKit），无需 OSRM/路网数据；生产（App 伪装页）与开发（网关 web）同路径
- **局限**：仅设备端、需设备联网（Apple 服务）、transportType 公开档仅驾车/步行（骑行无公开 API，不提供）
- **与 sim.location.track 分工**：`sim.route.calculate` = 设备端自动算路生成轨迹；`sim.location.track` = 外部显式上传点序列（GPX 导入/其他来源）——二者都落盘同一轨迹文件 + 切 track

#### 3.3.2 轨迹文件格式（version 字段留演进余地）

```json
{
  "version": 1,
  "speed": "walk",
  "points": [
    { "lat": 39.9087, "lon": 116.3975, "speed": 1.4, "course": 120.0, "alt": 45.0, "acc": 4.0 },
    { "lat": 39.90874, "lon": 116.39756, "speed": 1.4, "course": 122.0, "alt": 45.1, "acc": 5.0 }
  ]
}
```
- 坐标一律 **WGS-84**（C5）；`ts` 不需要（按 1s 间隔推进）
- 网关生成时逐点带拟人抖动（±0.00001° ≈ ±1m）、精度 3–6m 随机、海拔平滑 ±0.5m
- 文件平铺命名对齐 `.manager.pid`；写入方需**原子写**（先写临时文件再 rename），避免 Controller 读到半截 JSON

**读回状态**：`SimLocationMode` + 坐标即状态真相，外部/App 读 defaults（各自域）即可，无需新查询通道。

### 3.4 网关侧（web 面板 + 轨迹生成）

**web 面板「模拟定位」**（[trollvnc-farm/web/](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/trollvnc-farm/web) 新增面板，无构建热更新，开发期调试主力）：
- 阶段 1：预设城市列表（北京/上海/广州/深圳/成都…，`web/` 一个常量文件）+ 手输坐标 → 单发 `setConfigs({SimLocationMode:'static', SimLocationLat, SimLocationLon, SimLocationAccuracy})`（注册表 setConfig 入口）
- 阶段 2：轨迹（起点/终点 + 驾车/步行）→ **`invokeCap('sim.route.calculate', {from, to, mode})`**（设备端 Apple 地图原生算路，沿真实道路，异步——立即 ack，蓝点稍后自动沿路移动）
- 停止：`setConfigs({SimLocationMode:'off'})`
- 批量差异化（农场）：每台设备独立人设（城市+种子），**逐台循环单发**（configs 同参数不适用，`batchSetConfigs` 只用于同参数场景）
- 右侧操作列按钮：`renderCapOps` 的 `focusOpsCap`/`opsMenuCap` 各加一个「定位」动作按钮，点开面板（与现有按钮能力同通道）

**轨迹生成（Node，`npm test` 可覆盖）**：
```
RegionEngine        圆/多边形活动区域 + 区域内撒途经点 + 触界反射（拒绝采样/网格+抖动）
RandomWalkTrajectory 受限随机游走 + 转角惯性（≤45°/步）+ 拟人停顿 3-10s + 速度 ±20% 波动
GPXParser           导入 wpt/trkpt/rtept（回放真实轨迹，最拟真）
Interpolator        A→B 按速度插值（Andromeda interpolateRoute 思路：步长=speed×1s）
```
- 输出统一为 §3.3 文件格式（WGS-84，已含拟人参数）
- 速度档：walk 1.4 / cycle 5.5 / drive 13.9 m/s（与 `SimLocationSpeed` 对齐）

**坐标转换（共享 JS 模块，web 与 Node 通用）**：`CoordTransform.js` 公开数学（Krasovsky 椭球 + 中国范围判断），浏览器与 Node 均可用（无 DOM 依赖，纯函数）。**所有坐标出口统一过它**：web 前端选点/预设城市（GCJ-02 源 → `gcj02ToWgs84`）、Node 轨迹生成入口（区域中心/路线端点，GCJ-02 → WGS-84）——一律先转 WGS-84 再写入参数/文件（C5）。禁止两端各写一份转换。

### 3.5 工程配置改动（一次到位，避免重编译）

| 文件 | 改动 |
|---|---|
| [TrollVNC.entitlements](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/app/TrollVNC/TrollVNC/TrollVNC.entitlements) | +`com.apple.locationd.simulation` = true（manager/server 签名均引用此文件，一处改全生效） |
| [Makefile](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/Makefile) | `trollvncmanager_FRAMEWORKS += CoreLocation`；新增 `SimLocationManager.mm`/`SimLocationController.mm` 入 `trollvncmanager_FILES` |
| [TRCapabilityRegistry.mm](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/TRCapabilityRegistry.mm) | `_registerConfigSchemas` +5 项（`SimLocationLat/Lon` 加 WGS-84 范围校验）；`_registerNativeCapabilities` +1 控制能力 `sim.location.track`（route=Native，executor 校验 points → 原子写轨迹文件 → 写 `SimLocationMode=track`） |
| [trollvncmanager.mm](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncmanager.mm) | 启动时 `[SimLocationController start]`；prefs-changed 订阅内加 `[[SimLocationController sharedController] reloadFromPrefs]`（加速 App/5801 写入生效，巡检仍是兜底） |
| [trollvncserver.mm](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm) | **新增 5802 `config.set` 管理命令**：与已有 `config.get` 成对、**白名单对称**——现有 `config.get` 可读键（FabAutoCollapse 等 UI 参数）+ `SimLocation*` 均可写，密码/证书等敏感配置不开放 → 写当前用户域 plist `com.82flex.trollvnc.plist`（与 config.get 同域）→ `notify_post("com.82flex.trollvnc.prefs-changed")`；命令表 ops 列表（现有 [config.get](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm#L3876) 处）同步加 `config.set` |
| [index.vnc](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/layout/usr/share/trollvnc/webclients/index.vnc)（5801 前端） | 定位按钮 + 调 `mgmtRequest('config.set', ...)`（与现有 `config.get` 同通道） |

---

## 4. 前置验证实验（Go/No-Go，先于一切正式开发）

### 实验 A（门禁 1，唯一重大不确定性）
- **目的**：root daemon 进程内 `CLSimulationManager` 注入是否被 locationd 接受；定位授权是否必需
- **步骤**：最小实现 `SimLocationManager.injectPoint`（不写 Controller）→ 打 tipa 装评估机 → 注入北京天安门坐标 → 开系统地图看蓝点
- **分支**：① 蓝点跟随 → **通过**，继续；② 蓝点不动 → 尝试让 App 前台 `requestAlwaysAuthorization()` 一次后再注入（TCC 授权是否对 manager daemon 进程生效为**实验验证项**，不作既定假设）；③ 仍不动 → **No-Go**，停止本方案开发，排查 entitlement/进程上下文
- **记录**：iOS 版本｜是否生效｜是否需授权｜`isSimulatedBySoftware` 值（仅记录不作 gate）

### 实验 B（门禁 2，注入姿势定案）
- **目的**：确认 mode A（每秒全量重发）在本架构稳定
- **步骤**：`SimLocationController` track 模式跑 5 分钟轨迹 → 测试 App/系统地图采样相邻位移
- **判定**：位移 ≈ 速度×1s（±10%）、无跳变 = **通过**；若发现 locationd 拒绝高频重发 → 记录并回退（降频或查错）
- **结论写回**：mode A 为正式实现；mode B（队列+locationInterval）仅在 mode A 失败时实验

### 实验 C（记录，非门禁）
- **目的**：时区是否跟随、通知节流是否生效
- **步骤**：注入北京 vs 乌鲁木齐坐标 → 观察系统时间/时区显示；确认通知不每秒发
- **记录**：时区跟随｜节流行为｜跨时区注入是否触发更新

**实验记录表模板**（每个实验输出一张表，作为交付物提交）：
| 实验 | iOS版本 | 设备 | 结果字段1 | 结果字段2 | Pass/No-Go | 结论 |

---

## 5. 里程碑与验收（带 Go/No-Go 判定）

| 里程碑 | 任务 | 验收标准（可判定） |
|---|---|---|
| M1 | 实验 A + B + C | 记录表齐全；root daemon 注入生效；mode A 稳定；时区跟随 |
| M2 | SimLocationManager + 配置注册 + static 单点 | 系统地图蓝点=目标坐标；时区跟随；`setConfigs` 从网关下发生效（web 阶段 1） |
| M3 | track 轨迹（网关 `TrajectoryGen` 生成 → `invoke sim.location.track` 上传落盘 → controller 推进） | 相邻位移≈步长（±10%）、全程连续、完成后保持终点；off 恢复真实定位；重复上传幂等覆盖 |
| M4 | 保活 + 离线自治 | 设备重启后定位自动恢复（mode 保持）；关 WiFi 后定位仍指向目标（记录，L2 暂缓不作承诺）；manager 内失效巡检可自恢复 |
| M5 | 外部入口 + App 固化 + 文档 | 网关 web 面板/5801 按钮调参全通（经注册表）；App 伪装页定位 tab 骨架接入（写 mobile 域 defaults + 轨迹文件 + prefs-changed，离线自治）；`说明文档.md`/CodeWiki/`?v=N` 同步；`caps-test.js` 数量断言更新 |

---

## 6. 测试要求

| 测试 | 位置 | 断言 |
|---|---|---|
| CoordTransformTests | 网关 `npm test`（Node 侧移植公开算法） | 已知点位 GCJ-02↔WGS-84 往返；越界坐标原样返回 |
| TrajectoryGenTests | 网关 `npm test` | 相邻位移=步长±10%；转角≤45°；区域不越界；同 seed 可复现；拟人参数在范围内 |
| GPXParserTests | 网关 `npm test` | wpt/trkpt/rtept 解析与导出往返一致 |
| verify-locsim.mjs | 网关 `test/` 真机脚本 | 连评估机 → setConfigs(static) → 读回 defaults 校验 → `invoke sim.location.track`（轨迹上传）→ status 轮询（对齐现有 `verify-*.mjs` 风格） |

设备端无 XCTest（Theos 无测试设施、Windows 不能本地构建）→ **所有纯逻辑（轨迹/坐标）放网关 Node 侧测试**，设备端只留不可移植的执行器；设备端改动以 CI 编译 + 真机 verify 脚本为验证门槛。

---

## 7. 明确"不做什么"（防止跑偏）

- ❌ 不做网络定位 MITM（L2：`/clls/wloc` 改写、NEPacketTunnelProvider、Go 代理、CA 信任）——与农场拓扑冲突且需人工信任 CA，已暂缓，本期只做 GPS 注入（L3）
- ❌ 不复制 Geranium / Andromeda / TrollBox 源码（GPL-3.0）——私有接口声明自写（附录 A），算法按公开数学/规格实现
- ❌ 不集成/不对抗高德、腾讯、百度等第三方定位 SDK
- ❌ 不在 App 前台注入（App 只调参，不执行注入）
- ❌ 不做队列模式（mode B）作首版——实验 B 通过后 mode A 即定案，mode B 另立二期
- ❌ 不承诺"绝对不被检测"（`isSimulatedBySoftware` 标志 iOS 15+ 必置位，组合风控检测在方案边界外）
- ❌ 不承诺"WiFi 开着必然指向模拟点"（属 L2，已暂缓；GPS 注入覆盖上层 App 读取为当前承诺范围）
- ❌ 不做 iOS 18+ 支持
- ❌ 不做多设备 Web 面板的复杂编排（先单机跑通；多设备差异化仅"逐台单发 + 独立人设"，不做调度器）

---

## 8. 完成自检清单（编码 AI 交付前逐项打勾）

- [ ] 实验 A/B/C 记录表齐全，结论明确（A 为 Go）
- [ ] `SimLocationManager`/`SimLocationController` 实现完成，接口与本文一致
- [ ] 5 个配置项两端注册对齐（caps.js CONFIG_DEFS + `_registerConfigSchemas`），`caps-test.js` 断言已更新
- [ ] `sim.location.track` 控制能力注册（`_registerNativeCapabilities`，route=Native）：points 校验 + 原子写轨迹文件 + 切 track
- [ ] entitlements +`com.apple.locationd.simulation`；Makefile +CoreLocation +2 文件
- [ ] 轨迹文件格式与 §3.3.2 一致；`SimLocationMode=track` 从文件加载推进；写入原子（临时文件 rename）
- [ ] 时区通知节流（首次/跨时区）；CLLocation 完整构造器（course/speed）
- [ ] 离线自治：设备重启后 mode 自动恢复；失效巡检可自恢复
- [ ] 网关侧：web 面板（阶段 1/2）+ 轨迹生成 + 坐标转换，`npm test` 全绿
- [ ] verify-locsim.mjs 真机通过：static/track/off 三态（track 经 invoke 上传）+ 读回校验
- [ ] M5 文档同步：`说明文档.md`/CodeWiki/`?v=N`
- [ ] 未违反第 7 节任何"不做"

---

## 附录 A：CLSimulationManager 私有接口声明（自写，参考 udevs 头文件）

```objc
// 参考 Geranium/Andromeda 使用的私有接口（GPL 参考不复制，接口为逆向公开知识）
#import <Foundation/Foundation.h>
#import <stdint.h>
@interface CLSimulationManager : NSObject
@property (assign, nonatomic) uint8_t locationDeliveryBehavior;
@property (assign, nonatomic) double locationDistance;
@property (assign, nonatomic) double locationInterval;
@property (assign, nonatomic) double locationSpeed;
@property (assign, nonatomic) uint8_t locationRepeatBehavior;
- (void)clearSimulatedLocations;
- (void)startLocationSimulation;
- (void)stopLocationSimulation;
- (void)appendSimulatedLocation:(id)location;
- (void)flush;
- (void)loadScenarioFromURL:(id)url;   // 可选
- (void)setSimulatedWifiPower:(BOOL)p; // 可选增强，不作主路径
- (void)startWifiSimulation;
- (void)stopWifiSimulation;
- (void)setSimulatedCell:(id)cell;     // 可选增强
- (void)startCellSimulation;
- (void)stopCellSimulation;
@end
```

## 附录 B：CLLocation 构造与拟人参数（Andromeda 实证值）

```objc
CLLocation *loc = [[CLLocation alloc] initWithCoordinate:coord
                                               altitude:alt + drand(-0.5, 0.5)      // 海拔抖动 ±0.5m
                                     horizontalAccuracy:drand(3.0, 6.0)             // 精度 3-6m 随机
                                       verticalAccuracy:5.0
                                              course:course
                                               speed:speed
                                            timestamp:[NSDate date]];
```
- 坐标抖动：lat/lon ±0.00001°（≈±1m）
- 城市海拔参考：市区 20–60m，随轨迹平滑变化
- 完成轨迹：**不调 stop**，保持终点（人不会"瞬间消失"）

## 附录 C：路径与配置速查

| 项 | 值 |
|---|---|
| 轨迹文件 | `/var/mobile/Library/Caches/com.82flex.trollvnc.simloc.json`（平铺，对齐 `.manager.pid` 命名；原子写：临时文件 rename） |
| 参数域 | defaults suite `com.82flex.trollvnc`：外部 setConfig 写 root 域；5801 `config.set` 写当前用户域；App 写 mobile 域；manager **双域读取**（`tvManagerReadPref` 模式） |
| 外部入口 | 经注册表：`POST /api/devices/:id/configs`（setConfig 配置型）+ `POST /api/devices/:id/invoke {cap:'sim.location.track', params:{points}}`（invoke 控制型，轨迹上传） |
| App 入口 | 本地直写 mobile 域 plist + 轨迹文件 + `notify_post(prefs-changed)`（不经网关/注册表，离线自治） |
| 通知 | 复用 `com.82flex.trollvnc.prefs-changed`（不加新通知名） |
| 5801 通道 | 5802 管理 API `config.set`（新增，与 `config.get` 成对、白名单对称：UI 行为参数 + SimLocation*，敏感配置不开放）→ 写当前用户域 plist → `prefs-changed` |
| entitlements | `com.apple.locationd.simulation`（唯一新增） |
| 注入节奏 | static：一次 + 10s 失效巡检；track：1s/点（mode A） |
| 保活 | OhMyJetsam（已有，constructor 自动执行，manager 进程级）→ Controller 随 manager 常驻 |

## 附录 D：参考源码（仅参考接口/参数/算法，不得复制）

| 项目 | 文件 | 用途 |
|---|---|---|
| Geranium（GPL-3.0） | `LocSim/LocSimPrivateHeaders.h` | CLSimulationManager 接口（附录 A 已按此自写） |
| Geranium | `LocSim/LocSimManager.swift` | 最小调用序列（stop→clear→append→flush→start） |
| Geranium | `LocSim/CoordTransform.swift` | GCJ-02↔WGS-84 公开数学（Krasovsky 椭球 6378245.0 / e² 0.00669342162296594323 / 中国范围 72.004–137.847 / 0.8293–55.8271） |
| Andromeda（GPL-3.0） | `RouteSimulator.swift` | mode A 每秒全量重发实证、`interpolateRoute` 插值、拟人抖动参数、完成保持终点 |
| TrollBox | `LocationSimulator/LocSimManager.swift` | 同源调用序列（交叉验证） |
