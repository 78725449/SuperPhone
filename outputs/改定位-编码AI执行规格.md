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
| C10 | **注入姿势（方案 C append-only，已定案）** | 连续轨迹 **首次 start 后每秒只 `append+flush`，不 stop/clear/restart**（依据：TrollBox 实证「stop 后位置异常」是 locationd 系统 bug，每秒 stop→start 高频触发 → 周期性漂移；2026-08-24 真机验证通过：蓝点连续移动无漂移）。`loadScenarioFromURL` 已放弃（全网无任何实际使用者） |

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
  SimLocationController   自治控制器：双域读 defaults 参数 → 状态机（off/anchor/route/region，§3.2）→ 失效巡检 + 参数变更感知 → 启动自恢复；维护当前位置 `_current`
    └─ SimLocationManager  CLSimulationManager 封装：注入原语（start/stop/append）+ 时区通知节流
        └─ locationd（系统）→ 全系统生效（任何 App 读到模拟坐标）
  SimRouteCalculator      Apple 地图原生算路（路线段：MKDirections→polyline→重采样）
  RegionEngine + RegionTimeAllocator  区域漫游（区域段：撒途经点 + 行为形状时间分配，M4）
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
| `SimLocationMode` | enum `off`/`anchor`/`itinerary` | 关闭 / 位置基底（微动）/ 动作序列（route/region 段）（默认 `off`） | instant |
| `SimLocationLat` | number | 目标纬度（WGS-84） | instant |
| `SimLocationLon` | number | 目标经度（WGS-84） | instant |
| `SimLocationAccuracy` | number 3~15 | 注入精度 | instant |
| `SimLocationSpeed` | enum `walk`/`cycle`/`drive` | 轨迹速度档（track 用） | instant |

**语义（关键）**：全部 `reload=instant`——instant 的现有语义是"只写 defaults、下次读取自动用新值"（无副作用分发）。sim 控制器通过**低频巡检轮询 defaults 感知变更**（复用 §3.2 失效巡检定时器），任一参数变化即重读并重新注入，**不改 setConfig 分发机制**。
**参数校验**：`SimLocationLat` 钳制 [-90, 90]、`SimLocationLon` 钳制 [-180, 180]（WGS-84 范围），setConfig 校验失败返回错误。
**入口与写入域（两类）**：**外部**经注册表 `setConfig:`（网关 configs API → manager 写 root 域；5801 `config.set` → 写当前用户域）；**App 伪装页**直接写 mobile 域 plist（`/var/mobile/Library/Preferences/com.82flex.trollvnc.plist`）；manager 统一**双域读取**（root 域 → mobile 域 plist 回退，复用 `tvManagerReadPref` 模式，见 §3.3）。
**大 payload（轨迹点序列）**：不进 CONFIG_DEFS。**外部经注册表 `invoke:` 控制能力 `sim.location.track` 上传**（params.points → 设备端落盘文件 + 切 itinerary）；**App 本地直接写轨迹文件**。`SimLocationMode=itinerary` 时设备端从文件加载点序列自治推进（见 §3.3）。

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

状态机：`off → anchor（位置基底）→ itinerary（动作序列）`（defaults `SimLocationMode` 驱动）
- **off**：不注入；`stop` 清队列恢复真实定位
- **anchor（位置基底，默认模拟态）**：`injectPoint` 中心点一次，随后 Controller **内置微动游走**（每次 tick 微步随机游走：步长 0.1–0.5m、范围 5–50m、周期性回中、course/speed 随游走更新）——不需要序列文件；完全静止坐标像假 GPS，微动是拟人必需。**设备任何时刻都有 anchor 落点（当前位置）**
- **itinerary（动作序列）**：基于当前位置，按序执行 route/region 段（§3.3.4）；**段起点静态绑定**（seg1=提交时刻当前位置，seg_i=seg_{i-1} 终点）；执行完停在终点 = 新的 anchor 基底。route/region **不单独成态**——它们是 itinerary 的段类型（"单独选路线/区域"= 单段 itinerary）

**当前位置生命周期（状态核心）**：Controller 维护 `_current {lat, lon, speed, course, timestamp}`，**每次注入后更新**：
- 消费方①：`sim.location.status` 返回 `{mode, lat, lon, speed, course}`（web/App 地图实时显示"现在在哪"）
- 消费方②：**编排初始起点**——itinerary seg1 起点 = 提交时刻 `_current`（提交后不再变化，段间拼接静态绑定）
- 消费方③：失效恢复——巡检发现注入丢失 → 从 `_current` 继续（而非从头）

要点：
- **持久化与自恢复**：参数全在 defaults；`start` 时读 `SimLocationMode` 恢复上次状态（离线自治核心，C3）——manager 重启/设备重启后定位自动恢复，不依赖网关/App
- **失效巡检 + 参数变更感知（合一）**：`checkAndRestore` 每 10s，做两件事：① 判断"mode!=off 且注入异常"则节流重发（节流思路参考 TRWatchDog throttle）；② **双域读取** defaults（root 域 → mobile 域 plist 回退，复用 `tvManagerReadPref` 模式）比对 `SimLocation*` 是否有变化，变化则重读参数并重新注入——以此感知 App 本地/5801 写入的变更，**不改 setConfig 分发机制**
- **保活**：Controller 跑在 manager 进程内，manager 已由 OhMyJetsam（constructor 自动执行）设为 critical + 不可冻结，**无需新增进程级保活**
- **时序**：`injectPoint` 首帧 stop→clear→append→flush→start，**running 态仅 append+flush（方案 C append-only，不 restart）**——规避 locationd stop 系统 bug 引发的周期性漂移（2026-08-24 真机验证）

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
//       ③ 写 SimLocationMode=itinerary（defaults，root 域）
//       ④ 返回 {ok, count}
// Controller 巡检/通知感知 mode 变化 → 从文件加载点序列逐秒注入（方案 C append-only）
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
//       ④ 原子写轨迹文件 + 切 SimLocationMode=itinerary → Controller 自治推进（§3.3.3 结果）
//       ⑤ 立即返回 {ok, status:'calculating'}（MKDirections 联网 1-3s 超 invoke 5s 超时，故异步）
```

要点：
- **沿真实道路**：MKDirections 返回 MKRoute.polyline 即沿路坐标，重采样后轨迹贴道路，不穿楼
- **零第三方/零部署**：Apple 原生能力（MKDirections/MapKit），无需 OSRM/路网数据；生产（App 伪装页）与开发（网关 web）同路径
- **局限**：仅设备端、需设备联网（Apple 服务）、transportType 公开档仅驾车/步行（骑行无公开 API，不提供）
- **与 sim.location.track 分工**：`sim.route.calculate` = 设备端自动算路生成轨迹；`sim.location.track` = 外部显式上传点序列（GPX 导入/其他来源）——二者都落盘同一轨迹文件 + 切 itinerary

#### 3.3.4 `sim.itinerary`（注册表 Native 控制能力，路线+区域编排）

```objc
// 注册（TRCapabilityRegistry _registerNativeCapabilities，route=TRCapRouteNative）
// capId: sim.itinerary
// params: { segments: [ {type:'route', to, mode}, {type:'region', radius, mode, durationMin}, {type:'anchor', point?}, ... ] }
// 段起点静态绑定（编排连续性命门）：seg1 起点 = 提交时刻 _current；seg_i 起点 = seg_{i-1} 终点
//   route 段只需 {to, mode}（起点自动）；region 段只需 {radius, mode, durationMin}（中心=上段终点，显式 center 可覆盖）
// 行为：① 校验 segments 数组非空、逐段参数合法
//       ② 异步逐段生成（route 段：MKDirections 算路；region 段：RegionEngine+RegionTimeAllocator 漫游；anchor 段：终点基底，不生成序列）
//       ③ 逐段拼接完整点序列（前段终点 = 后段起点，静态绑定；anchor 段为落点不参与拼接）
//       ④ 原子写轨迹文件 + 切 SimLocationMode=itinerary → Controller 自治推进，执行完停在终点（新 anchor 基底）
//       ⑤ 立即返回 {ok, status:'calculating'}（异步，同 §3.3.3）
```

要点：
- **能力编排哲学**：每个能力（算路/区域/静置/上传）独立可执行；编排 = 基于当前位置按序拼接成完整行程——**段起点静态绑定**：seg1=提交时刻 `_current`、seg_i=seg_{i-1} 终点（生成时确定，不实时读坐标；运行时 `_current` 是播放进度，不参与拼接）
- **时间语义**：route 段时间 = 物理（距离÷速度，不手动输）；region 段时间 = 用户意图（durationMin，人在区域内待多久）；anchor 段为落点基底持续到编排切换；由算法自然衔接
- **区域途经点间 MKDirections 逐段算路**（§3.4.1），真实道路；编排内"从区域去下一个点"用 route 段（沿路）——正好满足"区域活动后按路线到某点"的编排需求
- **UI 流程**：先选当前定位（anchor 基底）→ 再基于该位置选路线/区域，或基于当前位置编排 [route, region, ...] 完整行程（§3.4）

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
- 阶段 1：预设城市列表（北京/上海/广州/深圳/成都…，`web/` 一个常量文件）+ 手输坐标 → 单发 `setConfigs({SimLocationMode:'anchor', SimLocationLat, SimLocationLon, SimLocationAccuracy})`（注册表 setConfig 入口）
- 阶段 2：轨迹（起点/终点 + 驾车/步行）→ **`invokeCap('sim.route.calculate', {from, to, mode})`**（设备端 Apple 地图原生算路，沿真实道路，异步——立即 ack，蓝点稍后自动沿路移动）
- 停止：`setConfigs({SimLocationMode:'off'})`
- 批量差异化（农场）：每台设备独立人设（城市+种子），**逐台循环单发**（configs 同参数不适用，`batchSetConfigs` 只用于同参数场景）
- 右侧操作列按钮：`renderCapOps` 的 `focusOpsCap`/`opsMenuCap` 各加一个「定位」动作按钮，点开面板（与现有按钮能力同通道）

**轨迹生成（三态骨架，独立可执行，可编排拼接；设备端实现 + 网关 Node 可测副本）**：

```
三态骨架（各自独立 = 独立能力）：
  anchor  静置微动   Controller 内置游走（§3.2，不需要序列文件）：中心点 ± 微步随机游走 + 回中
  route   路线       sim.route.calculate（MKDirections 算路）/ GPX 导入 → 沿真实道路点序列（§3.3.3）
  region  区域       RegionEngine 撒途经点 + RegionTimeAllocator 时间分配 → 途经点间 MKDirections 逐段真实道路点序列（§3.4.1）
编排      sim.itinerary：anchor/route/region 段按序执行拼接（§3.3.4；anchor 段内嵌状态不参与拼接）
拟人调料（通用，叠加在两种移动骨架）：
  偏态停留（短多长少） / 突发簇节奏 / 秒级坐标抖动 / 速度±20%波动 / 转角受限 / 入场-收尾结构
```

- 输出统一为 §3.3.2 文件格式（WGS-84，已含拟人参数）；速度档 walk 1.4 / drive 13.9 m/s
- **区域途经点间连接 = 自由走**（开放空间无道路概念：直线插值+抖动+转角受限），**不贴路**；仅路线段沿真实道路（§3.4.1）
- **当前位置贯穿三态**（§3.2）：route/region 生成时 `from/center` 缺省 = `_current`；anchor 微动实时更新 `_current`

### 3.4.1 区域漫游（RegionEngine 撒点 + RegionTimeAllocator 时间分配 + MKDirections 逐段算路，真实道路生长）

**结构（2026-08-24 升级为真实道路）**：区域 = 区域内一串途经点 → **相邻途经点间 MKDirections 逐段真实道路算路拼接** → 停留段 → 逐秒点序列（与路线段同格式，可拼接）。进入区域的第 1 段起点 = 上一位置（段起点静态绑定，§3.3.4）。

**RegionEngine（撒点/包含/反射）**：圆/多边形区域；拒绝采样均匀撒点；`contains` 判定；触界反射约束途经点全程不越界（算路路径本身由道路决定，天然在区域内/沿道路）。

**RegionTimeAllocator（时间分配，核心）**：给定总时长 T，**不依赖场景统计参数**（真实场景数据无法获取，禁止伪精确），用**行为形状**拟人：

1. **活动块计划**：T → K 个活动块（**K 与 T 正相关：每 ~4 分钟一个途经点，clamp 2~8，±1 随机抖动**——"逛了几个点"，待得久逛得多；**每次生成 K 与途经点位置均随机**）；每块 = 一次移动簇 + 一次停留簇
2. **突发簇节奏**：停留占比 ρ 每次活动随机（0.15~0.5），停留簇在少数块长、多数块短——不是均匀"走-停"交替
3. **偏态停留**：停留时长 log-normal 类分布（短多长少，20s~10min），均值不固定，由块内随机节奏决定
4. **移动簇（真实道路，2026-08-24 替换原"自由走"）**：块内移动 = 对相邻途经点调 `MKDirections` 算路（from=上一位置/上一途经点，to=下一途经点）→ 取 `MKRoute.polyline` 真实道路坐标 → 按有效速度重采样（复用 `SimRouteCalculator.calculateRoutePointsFrom` 的 resample）；**途经点对 <30m 或算路失败 → 该段降级直线**（避免整段失败，其余段保持真实道路）
5. **入场/收尾结构**：开场先纯移动不立刻停（进场）；收尾"逛到某处到点了"停住（不是刚好走完）
6. **校验收敛**：生成后实际总时长 ≈ T（±2%），不符微调停留时长/途经点距离迭代

**生长式渲染（App 端，2026-08-24 定稿）**：区域段轨迹按"上一位置 → 途经点① → 途经点② → …"顺序**逐段异步算路、逐段渲染**（`MKMapView` + `MKPolyline` 逐段 `addOverlay`）——路线从上一位置逐步生长进区域，边算边画；全部完成 = 区域内完整真实道路漫游轨迹，确认后执行（蓝点沿真实道路逐点移动）。交互原型见 `outputs/locsim-app-prototype.html`（直线模拟占位，生产为真实算路）。

**拟人化生长参数（2026-08-24 定稿，原型已验证节奏）**——时间**不平均**是拟人核心，各环节均带随机，禁止均匀分布：

| 环节 | 参数 | 拟人语义 |
|---|---|---|
| 途经点数 K | **自定义 N>0 → K=N（clamp 1~15）**；默认 0 → `max(3, min(15, round(√T × 2.5) ± 1 随机))` | **亚线性饱和**：短时多逛几个、长时间饱和 ~15，不随 T 线性堆积（50min/6h 不会几百个点）；每次生成 K 与位置均随机 |
| 移动段速度因子 | 每段随机 0.7~1.3 | 距离相同的段耗时不同（走走停停、快慢不一） |
| 移动段重采样 | 步长 = 有效速度(mps) × 因子 × 1s | 长段点多、慢段点密；段点数 = 段距离 ÷ 步长 |
| 偏态停留 | 70% 短 20~90s / 30% 长 120~480s | 路过/看手机（短多）vs 排队/购物（长少） |
| 停留时机 | 途经点到达后停留；**最后途经点不收尾停留**（收尾"逛到某处到点了"停住） | 入场先移动、收尾到点停 |
| 生长渲染节奏 | 逐段算路逐段画；段内按速度因子推进 | 生产端不画动画，仅用同一套参数生成逐秒点序列 |

> 原型中停留"节拍"是动画缩放（1~2 / 4~8 节拍 × 260ms），生产端映射为**真实秒**（短 20~90s / 长 120~480s）；速度因子直接作为有效速度的乘数参与重采样。

> 拟人本质 = 行为的"形状"（偏态/成簇/多层/次次不同），非场景数值。设备端与网关 Node 实现同一算法（网关侧可测副本 npm test 验证：总时长≈T、不越界、位移≈速度×时间、停顿分布偏态）。

**坐标转换（共享 JS 模块，web 与 Node 通用）**：`CoordTransform.js` 公开数学（Krasovsky 椭球 + 中国范围判断），浏览器与 Node 均可用（无 DOM 依赖，纯函数）。**所有坐标出口统一过它**：web 前端选点/预设城市（GCJ-02 源 → `gcj02ToWgs84`）、Node 轨迹生成入口（区域中心/路线端点，GCJ-02 → WGS-84）——一律先转 WGS-84 再写入参数/文件（C5）。禁止两端各写一份转换。

### 3.5 工程配置改动（一次到位，避免重编译）

| 文件 | 改动 |
|---|---|
| [TrollVNC.entitlements](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/app/TrollVNC/TrollVNC/TrollVNC.entitlements) | +`com.apple.locationd.simulation` = true（manager/server 签名均引用此文件，一处改全生效） |
| [Makefile](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/Makefile) | `trollvncmanager_FRAMEWORKS += CoreLocation`；新增 `SimLocationManager.mm`/`SimLocationController.mm` 入 `trollvncmanager_FILES` |
| [TRCapabilityRegistry.mm](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/TRCapabilityRegistry.mm) | `_registerConfigSchemas` +5 项（`SimLocationLat/Lon` 加 WGS-84 范围校验）；`_registerNativeCapabilities` +1 控制能力 `sim.location.track`（route=Native，executor 校验 points → 原子写轨迹文件 → 写 `SimLocationMode=itinerary`） |
| [trollvncmanager.mm](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncmanager.mm) | 启动时 `[SimLocationController start]`；prefs-changed 订阅内加 `[[SimLocationController sharedController] reloadFromPrefs]`（加速 App/5801 写入生效，巡检仍是兜底） |
| [trollvncserver.mm](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm) | **新增 5802 `config.set` 管理命令**：与已有 `config.get` 成对、**白名单对称**——现有 `config.get` 可读键（FabAutoCollapse 等 UI 参数）+ `SimLocation*` 均可写，密码/证书等敏感配置不开放 → 写当前用户域 plist `com.82flex.trollvnc.plist`（与 config.get 同域）→ `notify_post("com.82flex.trollvnc.prefs-changed")`；命令表 ops 列表（现有 [config.get](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm#L3876) 处）同步加 `config.set` |
| [index.vnc](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/layout/usr/share/trollvnc/webclients/index.vnc)（5801 前端） | 定位按钮 + 调 `mgmtRequest('config.set', ...)`（与现有 `config.get` 同通道） |

### 3.6 App 伪装页定位 tab（生产主路径，M5 固化）

**地图交互（Apple 原生 MKMapView，零第三方）**——伪装页定位 tab 的主交互载体：

| 功能 | 交互 |
|---|---|
| 静态定位 | 点击地图选坐标 → 写 mobile 域 defaults（anchor 静置微动） |
| 路线 | 地图点选 / `MKLocalSearch` 搜地名选起点终点 + 驾车/步行 → 算路 |
| 区域 | 地图选圆心 + 半径（MKCircle overlay）→ 漫游 |
| 轨迹预览 | 路线 polyline / 区域 overlay 显示 |

**GCJ-02 转换（C5 落地，必踩）**：MKMapView 中国区瓦片为 **GCJ-02**，地图选点为 GCJ-02——**所有选点出口统一过 `CoordTransform.gcj02ToWgs84`**（App 侧实现同一公开算法，与网关 JS 一致）→ 转 WGS-84 再写 defaults/轨迹文件。设备端只收 WGS-84 不变。

**MKDirections 双路径（实验 D 定案）**：

| 路径 | 执行者 | 场景 | 说明 |
|---|---|---|---|
| **A（生产主）** | **App 前台调 MKDirections** | App 伪装页 | App 有正常 bundle/attribution 上下文，Apple 服务更易放行——若实验 D 证明 daemon 不可用则以此为主 |
| **B（开发/远程）** | daemon `sim.route.calculate` | 网关 web | 实验 D 验证；不可用则 A 为主、网关降级提示/GPX |

- **降级链**：MKDirections 不可用（网络/服务/代理）→ **GPX 导入**路线回放（最拟真兜底）
- **App 本地通道**：App 伪装页直接调（地图 UI + 算路）→ 写设备 mobile 域 defaults/轨迹文件 + `notify_post` → manager Controller 推进（不经网关/注册表，离线自治，§3.3）

> 🖥️ **交互原型（UI 定稿参照）**：`outputs/locsim-app-prototype.html`——浏览器打开即可验证四 Tab（位置模拟/联系人/通话/短信）全部交互与最终 UI 形态；后续 UI 开发以该原型为准。

---

## 4. 前置验证实验（Go/No-Go，先于一切正式开发）

### 实验 A（门禁 1，唯一重大不确定性）
- **目的**：root daemon 进程内 `CLSimulationManager` 注入是否被 locationd 接受；定位授权是否必需
- **步骤**：最小实现 `SimLocationManager.injectPoint`（不写 Controller）→ 打 tipa 装评估机 → 注入北京天安门坐标 → 开系统地图看蓝点
- **分支**：① 蓝点跟随 → **通过**，继续；② 蓝点不动 → 尝试让 App 前台 `requestAlwaysAuthorization()` 一次后再注入（TCC 授权是否对 manager daemon 进程生效为**实验验证项**，不作既定假设）；③ 仍不动 → **No-Go**，停止本方案开发，排查 entitlement/进程上下文
- **记录**：iOS 版本｜是否生效｜是否需授权｜`isSimulatedBySoftware` 值（仅记录不作 gate）

### 实验 B（门禁 2，注入姿势定案）✅ 已定案（方案 C append-only）
- **目的**：确认连续注入姿势在本架构稳定（根治周期性漂移）
- **步骤**：`SimLocationController` track 模式跑长轨迹 → 测试 App/系统地图采样相邻位移
- **结果（2026-08-24 真机）**：每秒 stop→start（mode A）产生**周期性漂移**；根因 = TrollBox issue #35 实证「stop 后位置异常」是 locationd 系统 bug，被每秒 restart 高频触发
- **结论写回**：**方案 C append-only 定案**——首次 start 后每秒只 `append+flush`，不 stop/clear/restart；真机验证蓝点连续移动无漂移；`loadScenarioFromURL` 全网无实际使用者，放弃

### 实验 C（记录，非门禁）
- **目的**：时区是否跟随、通知节流是否生效
- **步骤**：注入北京 vs 乌鲁木齐坐标 → 观察系统时间/时区显示；确认通知不每秒发
- **记录**：时区跟随｜节流行为｜跨时区注入是否触发更新

### 实验 D（门禁 4，MKDirections 算路可行性——沿路落地 Go/No-Go）
- **目的**：root daemon 进程内 MKDirections 联网算路是否有效（§3.6 双路径定案依据）
- **步骤**：装含 `sim.route.calculate` 的 tipa → 网关面板轨迹区 → 起点北京/终点上海/驾车 → 观察
- **分支**：① 日志 `[simroute] ok: N points` + 蓝点沿真实道路移动 → **通过**，daemon 路径（B）可用，M4 编排 route 段走它；② 算路失败/被限流 → 转 **路径 A**：App 伪装页前台调 MKDirections（正常 bundle 上下文）为主，网关降级提示/GPX；③ 二者均不可用 → 沿路降级 **GPX 导入**回放
- **记录**：iOS 版本｜算路成功与否｜日志错误｜代理环境下 Apple 服务可达性｜中国区算路
- **结论写回**：§3.6 双路径定案（A/B 主次 + 降级链）
- **结果（2026-08-24 真机）**：✅ **通过**——daemon 算路 `[simroute] ok`，蓝点沿真实道路移动；路径 B（daemon `sim.route.calculate`）可用，M4 编排 route 段走它

**实验记录表模板**（每个实验输出一张表，作为交付物提交）：
| 实验 | iOS版本 | 设备 | 结果字段1 | 结果字段2 | Pass/No-Go | 结论 |

---

## 5. 里程碑与验收（带 Go/No-Go 判定）

| 里程碑 | 任务 | 验收标准（可判定） |
|---|---|---|
| M1 | 实验 A + B + C | 记录表齐全；root daemon 注入生效；**方案 C append-only 定案（无漂移）**；时区跟随 |
| M2 | SimLocationManager + 配置注册 + anchor 静置微动 | 系统地图蓝点=目标坐标 ± 微动游走（非完全静止）；时区跟随；`setConfigs` 从网关下发生效（web 阶段 1） |
| M3 | track 轨迹（网关 `TrajectoryGen` 生成 → `invoke sim.location.track` 上传落盘 → controller 推进） | 相邻位移≈步长（±10%）、全程连续、完成后保持终点；off 恢复真实定位；重复上传幂等覆盖 |
| M4 | 区域漫游 + 编排（sim.itinerary）+ 保活离线自治 | 区域段：RegionEngine 撒点不越界 + RegionTimeAllocator 总时长≈T±2%；`sim.itinerary` route+region 段拼接连续推进（前段终点=后段起点）；设备重启后 mode 自动恢复；失效巡检可自恢复 |
| M5 | 外部入口 + App 固化 + 文档 | 网关 web 面板/5801 按钮调参全通（经注册表）；App 伪装页定位 tab 固化（§3.6：MKMapView 地图选点/路线/区域/预览 + GCJ-02→WGS-84 转换 + MKDirections 双路径 + GPX 降级；写 mobile 域 defaults/轨迹文件 + prefs-changed，离线自治）；`说明文档.md`/CodeWiki/`?v=N` 同步；`caps-test.js` 数量断言更新 |

---

## 6. 测试要求

| 测试 | 位置 | 断言 |
|---|---|---|
| CoordTransformTests | 网关 `npm test`（Node 侧移植公开算法） | 已知点位 GCJ-02↔WGS-84 往返；越界坐标原样返回 |
| TrajectoryGenTests | 网关 `npm test` | 相邻位移=步长±10%；转角≤45°；区域不越界；同 seed 可复现；拟人参数在范围内 |
| GPXParserTests | 网关 `npm test` | wpt/trkpt/rtept 解析与导出往返一致 |
| verify-locsim.mjs | 网关 `test/` 真机脚本 | 连评估机 → setConfigs(anchor) → 读回 defaults 校验 → `invoke sim.location.track`（轨迹上传）→ status 轮询（对齐现有 `verify-*.mjs` 风格） |

设备端无 XCTest（Theos 无测试设施、Windows 不能本地构建）→ **所有纯逻辑（轨迹/坐标）放网关 Node 侧测试**，设备端只留不可移植的执行器；设备端改动以 CI 编译 + 真机 verify 脚本为验证门槛。

---

## 7. 明确"不做什么"（防止跑偏）

- ❌ 不做网络定位 MITM（L2：`/clls/wloc` 改写、NEPacketTunnelProvider、Go 代理、CA 信任）——与农场拓扑冲突且需人工信任 CA，已暂缓，本期只做 GPS 注入（L3）
- ❌ 不复制 Geranium / Andromeda / TrollBox 源码（GPL-3.0）——私有接口声明自写（附录 A），算法按公开数学/规格实现
- ❌ 不集成/不对抗高德、腾讯、百度等第三方定位 SDK
- ❌ 不在 App 前台注入（App 只调参，不执行注入）
- ❌ 不做队列模式（mode B）作首版——**方案 C append-only 已定案**（实验 B 通过）；mode B 仅作二期可选实验
- ❌ 不使用 `loadScenarioFromURL`（GPX 场景加载）——全网无任何项目实际使用、行为未知，已放弃
- ❌ 不承诺"绝对不被检测"（`isSimulatedBySoftware` 标志 iOS 15+ 必置位，组合风控检测在方案边界外）
- ❌ 不承诺"WiFi 开着必然指向模拟点"（属 L2，已暂缓；GPS 注入覆盖上层 App 读取为当前承诺范围）
- ❌ 不做 iOS 18+ 支持
- ❌ 不做多设备 Web 面板的复杂编排（先单机跑通；多设备差异化仅"逐台单发 + 独立人设"，不做调度器）

---

## 8. 完成自检清单（编码 AI 交付前逐项打勾）

- [ ] 实验 A/B/C 记录表齐全，结论明确（A 为 Go）
- [ ] `SimLocationManager`/`SimLocationController` 实现完成，接口与本文一致
- [ ] 5 个配置项两端注册对齐（caps.js CONFIG_DEFS + `_registerConfigSchemas`），`caps-test.js` 断言已更新
- [ ] `sim.location.track` 控制能力注册（`_registerNativeCapabilities`，route=Native）：points 校验 + 原子写轨迹文件 + 切 itinerary
- [ ] entitlements +`com.apple.locationd.simulation`；Makefile +CoreLocation +2 文件
- [ ] 轨迹文件格式与 §3.3.2 一致；`SimLocationMode=itinerary` 从文件加载推进；写入原子（临时文件 rename）
- [ ] `sim.itinerary` 编排能力：route 段（算路）+ region 段（RegionEngine+RegionTimeAllocator）逐段生成拼接，段起点静态绑定（seg1=提交时刻当前位置），落盘+切 itinerary
- [ ] RegionTimeAllocator 行为形状：活动块计划/突发簇/偏态停留/入场收尾/校验收敛（±2%）；网关 Node 可测副本 npm test（总时长≈T、不越界、位移≈速度×时间、停顿偏态）
- [ ] 时区通知节流（首次/跨时区）；CLLocation 完整构造器（course/speed）
- [ ] 离线自治：设备重启后 mode 自动恢复；失效巡检可自恢复
- [ ] M5 App 伪装页定位 tab：MKMapView 地图选点/路线/区域/预览；**地图选点统一过 gcj02ToWgs84**（地图选点→蓝点=选点位置验收）；MKDirections 双路径按实验 D 定案；GPX 导入降级可用
- [ ] 网关侧：web 面板（阶段 1/2）+ 轨迹生成 + 坐标转换，`npm test` 全绿
- [ ] verify-locsim.mjs 真机通过：anchor/route/region/off 四态（route/region 经 invoke 上传）+ 读回校验 + status 返回当前位置
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
- (void)loadScenarioFromURL:(id)url;   // 已放弃（全网无实际使用者，勿用）
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
| 注入节奏 | anchor：中心点 + 微动游走（Controller 内置）；route/region：1s/点（方案 C append-only：首次 start 后每秒 append+flush，不 restart） |
| 保活 | OhMyJetsam（已有，constructor 自动执行，manager 进程级）→ Controller 随 manager 常驻 |

## 附录 D：参考源码（仅参考接口/参数/算法，不得复制）

| 项目 | 文件 | 用途 |
|---|---|---|
| Geranium（GPL-3.0） | `LocSim/LocSimPrivateHeaders.h` | CLSimulationManager 接口（附录 A 已按此自写） |
| Geranium | `LocSim/LocSimManager.swift` | 最小调用序列（stop→clear→append→flush→start） |
| Geranium | `LocSim/CoordTransform.swift` | GCJ-02↔WGS-84 公开数学（Krasovsky 椭球 6378245.0 / e² 0.00669342162296594323 / 中国范围 72.004–137.847 / 0.8293–55.8271） |
| Andromeda（GPL-3.0） | `RouteSimulator.swift` | 每秒注入实证（被我们改造为 append-only）、`interpolateRoute` 插值、拟人抖动参数、完成保持终点 |
| TrollBox | `LocationSimulator/LocSimManager.swift` | 同源调用序列（交叉验证） |
