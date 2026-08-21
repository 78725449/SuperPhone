# SuperPhone 架构优化设计

> 日期：2026-08-21
> 状态：设计讨论定稿（待用户审查）
> 范围：设备端采集/隧道/缩略图架构、保活分层、双模式语义

## 1. 背景与问题

当前实现存在的核心问题：

1. **采集（CADisplayLink）与客户端连接强耦合**——newClientHook 对任何连接（含缩略图探测连接）都启动/停止采集，反复启停触发 `maybeResizeFramebufferForRotation` 竞态（采集线程 free 旧 buffer 与 rfbRunEventLoop 线程读写并发 → use-after-free → SIGILL），导致崩溃循环。
2. **隧道握手竞态**——设备端 5901 握手窗口极窄（实测 0-50ms 抖动），noVNC 协议版本经「网关 ack → 放行 → 隧道」链路有毫秒级延迟，间歇性超窗口 → 设备端主动关闭 → 黑屏。
3. **缩略图走 5901 探测连接（现状）**——卡片墙轮询 `screen.hash`（变化检测），每次经 127.0.0.1:5901 扩展消息桥接，触发采集启停，放大崩溃。

## 2. 目标架构：三层解耦

```
┌─────────────────────────────────────────────────────┐
│  采集层（设备端，独立常驻）                            │
│  ScreenCapturer 持续运行 → 更新 framebuffer 双缓冲     │
│  低频（~10fps）：每帧 pHash 变化检测 → 变化才推送       │
│  有屏幕流时升到目标帧率；方向变化重建加锁（消除 SIGILL） │
└─────────────────────────────────────────────────────┘
          │ 变化 → 缩略图推送                 │ 推流（有屏幕流时）
          ▼                                  ▼
┌─────────────────────────┐   ┌─────────────────────────┐
│ 缩略图层（卡片墙）        │   │ 控制层（隧道屏幕流）       │
│ 设备变化推送 → 网关缓存    │   │ 点击卡片 → rfb.start     │
│ （变化才推，节流可配置）    │   │ → 5901 握手 → 推流       │
│ 卡片墙读网关缓存渲染       │   │ 退出 → rfb.stop          │
└─────────────────────────┘   └─────────────────────────┘
```

> 命名说明：缩略图 = **设备端变化推送**（低频采集 + pHash 检测，画面变化才推，节流频率可配置），不是网关定时拉全图；控制时升为实时流（屏幕流互斥）。

## 3. 详细设计

### 3.1 采集层（设备端）

> **现状 vs 目标**：现状是「有 5901 客户端（gClientCount>0）才启动采集」（trollvncserver.mm:4748）；本设计改为**中继模式服务启动即常驻低频采集**（采集生命周期最稳定，避免网络波动驱动启停）；`gClientCount>0` **保留**仅用于**升频**（屏幕流活跃才高帧率）。网关是缩略图消费者，但**不计入 gClientCount**（走隧道命令通道、不连 5901，避免污染「客户端数」语义）。

- **常驻低频采集 + 变化检测**：ScreenCapturer 启动一次，无屏幕流时低频运行（~10fps，为缩略图变化检测供帧），有屏幕流时升到目标帧率（FrameRateSpec）。每帧做 pHash 检测（TRScreenHasher ≈0.3ms，直读 framebuffer 原始像素，不走 JPEG 编码）。
- **与客户端解耦**：newClientHook/clientGoneHook/cap.hello 豁免**不再启停采集**——探测连接、隧道连接都不影响采集生命周期，根治 SIGILL。
- **方向变化重建加锁**：`maybeResizeFramebufferForRotation` 的 free 旧 buffer + rfbNewFramebuffer 用 pthread_mutex 保护，与采集写入/RFB 发送互斥。

### 3.2 缩略图层（设备变化推送）

- **设备端变化推送（非网关拉取）**：设备低频采集时每帧做 pHash 变化检测（TRScreenHasher，≈0.3ms，直读 framebuffer 不走 5901 探测连接、不触发采集启停）；画面变化 → 编码缩略图 → 经隧道推送网关；画面静止 → 不推（零带宽）。
- **节流（ThumbInterval）**：画面频繁变化时（如播放视频）不能逐帧推——复用现有 `ThumbInterval` 配置（1-60s，默认 3s）作为**最小推送间隔**：变化且距上次推送 ≥ ThumbInterval 才推，避免退化成屏幕流。
- **缩略尺寸编码**：设备端缩到卡片墙所需分辨率（非全图）再 JPEG 编码推送，省带宽（现有 screenshot 返回全图 base64，卡片墙场景不需要全图）。
- **推送静默（隧道不可用）**：变化检测照常做（采集常驻），但推送动作在隧道未连接（未注册/网关挂/网络断）时**静默丢弃**——不堆积、不重试、不报错；缩略图是「尽力而为的最新帧」，隧道恢复后推最新帧即可。**节流时间戳仅在真正推送成功时更新**，恢复后首个变化立即可推。
- **网关缓存**：网关收推送更新缓存（最新帧 + 时间戳），WS 推前端或前端读缓存渲染（低负载）。
- **屏幕流互斥**：点击卡片（rfb.start）→ 设备端暂停缩略图推送（**含暂停 pHash 变化检测**，采集照常并升频供屏幕流，只推帧不检测）；退出（rfb.stop）→ 采集降回 10fps → 恢复变化检测与推送。两个消费者永不重叠。

### 3.3 控制层（屏幕流 = 设备推）

- **点击卡片**：前端大屏「连接中...」（复用加载动画）→ WS /ws/vnc → 网关 → 隧道 FT_CMD rfb.start → 设备 connect 本地 5901 → **主动写协议版本**（已修复握手竞态）→ 握手 → 采集升频 → 推流 → 显示。
- **5801 直连**：浏览器访问 → noVNC 直连设备 5901（wss）→ 直接触发开启隧道（推流），与隧道流共享同一采集。
- **退出**：rfb.stop → 采集降频回低频（~10fps）。

### 3.4 双模式（网关中继 / 桥接控制）

- **标签保留**：设置页保持「网关中继 / 桥接控制」双模式 UI；控制页面保持「加载网关」。
- **中继模式**：注册（18081）+ 隧道（18181 常驻，供缩略图变化推送与 rfb.start 命令）+ 低频采集（变化检测）+ 按需 5901 RFB。
- **桥接控制（遥控器）模式**：纯控制端——**不注册被控、不建隧道客户端、不采集、不启动被控服务**，仅作为 WS 客户端连网关控制被控设备。零被控开销；因不注册，网关设备列表不会出现该设备。

### 3.5 保活分层

分层总览（谁负责什么）：

| 层 | 保活内容 | 负责方 | 手段 |
|---|---|---|---|
| 屏幕 | 屏幕不锁屏（采集持续） | KeepAlive + 用户设置 | `hardwareUnlock` 周期性唤醒（保留，触发条件不变 gClientCount>0）；用户可自行设「不息屏」叠加 |
| 网络连接 | 隧道/注册/WS 存活 | **网关主导** | 心跳检测（隧道 PING 30s、注册 hello、WS 25s）+ 退避重连（2s→30s） |
| 进程 | App/服务存活 | **IPA** | TrollStore：独立进程组（spawn setpgroup，App 被杀服务存活）；越狱：launchd daemon（已实现 postinst launchctl load） |

#### 3.5.1 场景化保活清单

各场景下的具体保活机制：

| # | 场景 | 保活机制 | 负责方 |
|---|---|---|---|
| 1 | 屏幕锁屏（无屏幕流） | 渲染/采集停 → pHash 无变化 → 缩略图不推（卡片停留最后一帧，可接受）；网关保留缓存 | 设备（被动） |
| 2 | 屏幕锁屏（屏幕流活跃） | KeepAlive `hardwareUnlock` 周期性唤醒（触发条件不变：gClientCount>0 且 KeepAliveSec>0）；用户设「不息屏」为叠加增强 | 设备（KeepAlive + 用户设置） |
| 3 | 网关挂掉 / 网络断开（含 WiFi↔蜂窝切换） | 心跳超时（隧道 PING 30s、注册 hello、WS 25s）→ 退避重连（2s 起翻倍至 30s）；网关恢复自动重连 | **网关主导** + 设备退避 |
| 4 | App 被上滑杀掉 / 后台挂起 | trollvncmanager 独立进程组（spawn setpgroup 脱离 App），App 被杀服务存活；后台挂起不可冻结 | **IPA**（独立进程组） |
| 5 | 系统内存压力（Jetsam 清理） | OhMyJetsam：`JETSAM_PRIORITY_CRITICAL` + 无限高水位 + 不可冻结 → 内存压力从低 band 优先清理，服务几乎不杀 | **IPA**（OhMyJetsam） |
| 6 | trollvncserver 崩溃 / 假死 | 看门狗（watchdog）检测进程存活并 restart-service 重启 | 设备（watchdog） |
| 7 | 系统重启 | 半自动：BGTask 窗口内 ensureServiceRunning 重拉 + LaunchAtLogin/SBS 解锁自拉；无触发源需手动打开 App（详见 6.1） | **IPA**（半自动） |
| 8 | 越狱环境（.deb） | launchd daemon（postinst launchctl load）系统级保活，重启自启、Jetsam 拉起 | launchd（系统级） |

### 3.6 点击卡片弹通知（控制知情 + 软拉起）

- 点击卡片 → 网关经隧道命令通道下发控制请求 → 设备服务弹本地通知（复用 BulletinManager banner 通道）。
- **5801 直连同样弹**——凡控制会话建立即弹（与被控方式无关：点击卡片/5801 直连均触发）。
- 价值：**控制知情**（被控方可见谁在控制，安全/透明）+ **软拉起**（用户点通知 → App 打开 → ensure 服务）。通知文案、触发时机等细节待实现时按现有通知体系定。

## 4. 时序设计

### 4.1 注册后（未点击，缩略图）

```
1. 设备采集常驻（低频 ~10fps）→ 每帧 pHash 变化检测（≈0.3ms）
2. 画面变化且距上次推送 ≥ ThumbInterval → 编码缩略图 → 隧道推送网关；静止不推
3. 网关收推送更新缓存 → 卡片墙前端从缓存渲染（WS 推送/读缓存）
4. 不建 5901 RFB 连接、不触发采集启停、不走 5901 探测连接
```

### 4.2 点击卡片（屏幕流）

```
1. 前端大屏「连接中...」（复用加载动画）
2. 设备端暂停该设备缩略图推送（屏幕流互斥，rfb.start 即暂停）
3. WS /ws/vnc → 网关 → 隧道 FT_CMD rfb.start
4. 设备 TRTunnelClient connect 本地 5901 → 主动写协议版本（RFB 003.008）→ 握手
5. 采集升频 → ServerInit → FBU 帧流 → 显示
6. 设备服务弹本地通知（控制知情）
7. 退出 → rfb.stop → 采集降频回低频 → 恢复缩略图变化推送
```

### 4.3 5801 直连

```
1. 浏览器访问 http://设备:5801 → noVNC 页面
2. noVNC 直连设备 5901（wss）→ 直接触发开启隧道（推流）
3. 采集升频 → 推流（与隧道流共享同一采集）
4. 设备服务弹本地通知（控制知情，同 3.6）
```

## 5. 改造点清单

### 设备端（TrollVNC/src）

| 模块 | 改动 |
|---|---|
| trollvncserver.mm | 采集改为**服务启动即常驻低频**（gClientCount>0 门控保留、仅用于升频）+ 与客户端解耦（newClientHook/clientGoneHook/cap.hello 不再启停采集）；`maybeResizeFramebufferForRotation` 加锁；控制知情通知（复用现有 BulletinManager banner） |
| ScreenCapturer.mm | 支持动态帧率（低频 ~10fps ↔ 目标帧率 FrameRateSpec）；缩略尺寸编码；采集循环内每帧 pHash 变化检测 + ThumbInterval 节流（变化且距上次推送 ≥ 节流间隔才编码推送） |
| TRScreenHasher（trollvncserver 进程） | pHash native 直读 framebuffer 原始像素（不再经 5901 桥接供卡片墙轮询） |
| TRTunnelClient.mm | 新增缩略图推送消息类型（设备→网关，standby 期间可用）；**屏幕流互斥设备端落点：rfb.start 暂停缩略图推送 + pHash 检测，rfb.stop 恢复**；已修复：rfb.start 主动写协议版本 + 过滤重复版本 |
| trollvncmanager.mm | 桥接模式纯控制端（不 spawn 被控服务） |

### 网关（trollvnc-farm/server）

| 模块 | 改动 |
|---|---|
| index.js | 接收缩略图推送 → 缓存最新帧 → WS 推前端；rfb.start 跳过重复版本（已改） |

### 前端（trollvnc-farm/web）

| 模块 | 改动 |
|---|---|
| app.js | 卡片缩略图读网关缓存（WS 推送更新，替换现状轮询门控）；点击卡片进入控制（暂停推送由设备端 rfb.start 自动处理） |

## 6. 落地性结论

### 6.1 TrollStore（.tipa）系统级保活查证（2026-08-21 全网搜索）

- **结论：TrollStore 无法 launchd daemon 化**——系统路径（`/Library/LaunchDaemons`）受 SIP/SSV 保护，TrollStore 是 jailed（非越狱）应用，即使有 `platform-application` + `no-sandbox` 权限也无法写系统路径。
- **TrollStore 的现实保活 = Root Helper 机制**：IPA 内的 root 二进制（`TSRootBinaries` 声明）由 App 启动（posix_spawn），独立进程组运行——**这正是当前实现的模式**（App spawn trollvncmanager，setpgroup 脱离）。
- **Jetsam 保护（当前已实现）**：`OhMyJetsam.mm` 构造函数（进程加载即执行）调用 `memorystatus_control` 将服务进程设为 `JETSAM_PRIORITY_CRITICAL`（关键优先级）+ 无限高水位 + `SET_PROCESS_IS_FREEZABLE=0`（不可冻结）——内存压力时 jetsam 从低 band 清理，服务几乎不杀；用户上滑杀 App（独立进程组不波及）、后台挂起（不可冻结）均存活。
- **系统重启——半自动恢复 + 全自动缺口**：重启后进程全死，TrollStore 无 launchd 不自启。当前已实现两条「半自动」恢复路径（TVNCServiceCoordinator）：
  1. **BGTaskScheduler 后台刷新**（`registerBackgroundTasks`，iOS 13+）：注册 `BGAppRefreshTask`（`com.82flex.trollvnc.refresh`）每 15 分钟请求一次系统窗口，窗口内 `ensureServiceRunning` 端口探活、掉线即重拉 manager——但系统重启后已提交的调度请求是否恢复不保证，且 TrollStore 签名 App 的 BGTask 有效性未经真机验证，只能算「有机会在系统窗口内恢复」。
  2. **LaunchAtLogin + SBS 解锁自拉**（`checkPrebootDependencies`）：重启后 App 一旦被**任何途径**拉起（用户打开 / BGTask 窗口 / 其它 App 经 SBS 拉起），检测 `LastPrebootLaunch` 早于本次 bootTime → 调 `SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions(unlockDevice:YES)` 拉起自身 → App 前台 3 秒定时器端口探活恢复 manager。属「半自动」：需要某个触发源先拉起 App（鸡生蛋）；重启后无人触碰时服务不恢复，仍需手动打开 App。
- **结论**：有「重启后若被触发则自愈」的恢复路径，**无「重启后自动启动」的全自动机制**（iOS 无越狱物理限制，无通用「开机自启 App」；TrollStore 无法写系统 launchd 路径）。若需全自动，只能靠越狱 .deb 的 launchd daemon（6.2）。
- 参考：TrollStore 官方 README（root helper）、社区「权限持久化」文章、CSDN TrollStore 指南。

### 6.2 越狱（.deb）

- launchd daemon **已实现**（postinst launchctl load）——系统级保活，重启自启、Jetsam 拉起。
- 含 LaunchDaemon plist + trollvncserver 二进制，`com.82flex.trollvnc.plist`。

### 6.3 产物分层

| 产物 | 保活 | 说明 |
|---|---|---|
| TrollStore .tipa | 独立进程组（App spawn + setpgroup） | App 被杀服务存活；BGTask 窗口 + LaunchAtLogin/SBS 半自动恢复；重启无触发源时需手动打开 App |
| 越狱 .deb | launchd daemon（已实现） | 系统级保活，24h 在线 |

## 7. 后续规划：设置页按能力板块编排（初步方向，待本方案定稿后整体整改）

> 用户提出的后续整改方向，暂不实施；本方案实现完且定稿后再整体编排或重构现有设置页面。

> **设置页板块展示顺序（2026-08-21 定）：连接 → 直连 → 画面 → 交互 → 保活 → 关于**

- **目标**：设置菜单全部基于**能力板块**同步设置，按功能域聚类（如 连接 / 保活 / 采集 / 画面 / 输入 / 安全 / 通知 等），使配置更贴合「设备能力」心智，更便于配置。
- **底座（已具备）**：设备端能力元数据含 `category` 字段（TRCapabilityRegistry，由 capId 前缀 + route 类型**自动推断**，`_inferCategoryForCapId`）；网关 `caps.js` 的 `CONFIG_DEFS` 为配置项契约——配置项挂到能力板块下即「能力即配置」，单一真相源自然收敛，两端契约无需新增。
- **与现有设置页的关系**：现有 7 大分类按「reload 生效级别 + 功能域」混排。整改建议：**功能域做一级分组，reload 级别（即时/热/重启）做配置项子标注**——生效级别信息保留，分组改为能力板块。性能类（PerformanceMode 等）按现状并入对应板块。
- **整改范围**：既有配置项**仅重排前端编排与分组来源**，保留两端契约（caps.js / CONFIG_DEFS / 设备端 executor）；方案**新增配置项**（`CaptureFps` 采集帧率、`ThumbPushEnabled` 变化推送开关、`HeartbeatIntervalSec` 网关心跳间隔）按常规两端契约对齐新增。可能去除/重构现有设置页结构。
- **状态**：板块编排已全部定稿（2026-08-21）；**设置页整改纳入本轮实现**。

### 7.1 板块草案：画面（已确认，2026-08-21）

> 排序逻辑：按画面数据链路——采集层 → 缩略图层 → 控制层（推流）；方向为画面属性，置于推流链路过渡位。

| # | 配置项 | 说明 | reload 建议 |
|---|---|---|---|
| 1 | 采集帧率（**新** `CaptureFps`） | 低频采集帧率（替代常量 10fps），1-30 默认 10 | hot |
| 2 | 变化推送开关（**新** `ThumbPushEnabled`） | 缩略图变化推送总开关（关闭则卡片墙不更新缩略图，省带宽/隐私） | instant |
| 3 | 推送间隔 / 卡片墙刷新间隔（ThumbInterval，改名） | 变化推送节流间隔（1-60s 默认 3s） | instant |
| 4 | 推流帧率（FrameRateSpec） | 屏幕流目标帧率 | hot |
| 5 | 方向同步（OrientationSync） | 画面方向 | hot |
| 5a | 方向偏移（OrientationPadFix，**保留**） | 方向同族紧跟（触摸坐标交换有消费） | restart |
| 6 | 推流画质（PerformanceMode） | 流畅/智能/画质/自定义；custom 展开 TileSize/MaxRects/脏区阈值/AsyncSwap | hot |
| 7 | 输出缩放（Scale） | 画质族 | restart |
| 8 | 进阶：延迟窗口（DeferWindowSec）/ 最大并行帧（MaxInflight） | 推流性能 | hot |

### 7.2 板块草案：交互（已确认，2026-08-21）

> 输入链路排序：触控 → 滚轮 → 辅助 → 键盘 → 诊断。全局只读（ViewOnly）**不在此板块，归「连接」板块**（与网关令牌/访问密码同组）。

| # | 配置项 | 说明 | reload 建议 |
|---|---|---|---|
| 1 | 自然滚动（NaturalScroll） | 触控/滚动方向 | instant |
| 2 | 滚轮步进（WheelStepPx） | 滚轮每格像素 | hot |
| 3 | 辅助触控（AutoAssistEnabled） | 系统辅助功能自动启用 | instant |
| 4 | 修饰键映射（ModifierMap） | 键盘 Alt↔Cmd 映射 | hot |
| 5 | 键盘日志（KeyLogging） | 键盘调试日志（诊断性质） | instant |

### 7.3 板块草案：保活（已确认，2026-08-21）

> 只保留「有业务感知、用户会调」的项；机制类（独立进程组/Jetsam/launchd/退避重连）默认开启不设控制，watchdog 参数归诊断区，重启后自启（LaunchAtLogin）保持 App 默认开启。

| # | 配置项 | 说明 | reload 建议 |
|---|---|---|---|
| 1 | 通知模式（Notifications） | 全部（含控制知情通知）/仅连接/静默 | instant |
| 2 | 防息屏间隔（KeepAliveSec） | 屏幕流活跃时周期性唤醒屏幕防息屏（0=关闭） | hot |
| 3 | 网关心跳间隔（**新** `HeartbeatIntervalSec`） | 设备与网关隧道心跳频率，探测断线（当前硬编码 30s） | gateway |

### 7.4 板块草案：连接（按模式动态显示，2026-08-21）

> 顶部为**模式选择器**（网关中继 / 桥接控制），连接板块内容随模式切换显示。桥接控制 = 纯遥控器（本机不被控，无被控密码/只读/证书）。**桥接模式下仅展示桥接配置组，其余板块（画面/交互/保活/直连）为被控侧配置、不适用、无需特殊编排。**

#### 网关中继（被控模式）

| # | 配置项 | 说明 | reload |
|---|---|---|---|
| 1 | 网关地址（GatewayHost） | 保持现状 | gateway |
| 2 | 网关令牌（GatewayToken） | 保持现状 | gateway |
| 3 | [按钮] 连接网关 | **多态按钮**：地址未填 → 点击=搜索网关（settings.searchGateway）；地址已填 → 点击=连接网关（连接后文字变「已连接」） | — |

> 被控密码 / 只读模式开关已移入「直连」分组（访问控制是设备服务属性，与接入方式无关）。

#### 桥接控制（纯遥控器）

| # | 配置项 | 说明 | reload |
|---|---|---|---|
| 1 | 网关地址（GatewayHost） | 保持现状 | gateway |
| 2 | 网关令牌（GatewayToken） | 保持现状 | gateway |
| 3 | [按钮] 桥接网关 | 连接后按钮文字变为「已桥接」（同样支持未填=搜索 / 已填=桥接 多态） | — |

### 7.5 板块草案：直连（2026-08-21）

> 分组名「直连」；不经网关、直连本设备服务（5801/5901，公网或内网）的访问配置。被控密码/只读开关自连接板块移入；绑定地址改名为「直连地址」（公网出口，能力支持随后探讨，先实现设置框架）；自动发现（BonjourEnabled）**移除**（主路径网关/输 IP 不依赖）。

| # | 配置项 | 说明 | reload |
|---|---|---|---|
| 1 | 直连地址（BindHost 改名） | 本设备服务绑定一个公/内网地址供外/内网访问（不填时显示其灰色内网 IP，可输入公网 IP 或网址） | restart |
| 2 | 被控密码（FullPassword 改名） | 供外/内网访问的被控密码（只读密码 ViewOnlyPassword 已并入，只读由开关控制） | restart |
| 3 | [按钮] 生成证书 / 重新生成证书（settings.generateKeys） | 生成供公网直连 / 5801 内网直连的 https 证书 | — |
| 4 | 只读模式开关（ViewOnly） | 控制此设备能否点击操作 | instant |

### 7.6 板块草案：关于（2026-08-21）

> 设置页最下方分组。**当前 IP 已移除**（直连地址可输状态显示灰色本机 IP，承担本机 IP 信息）。**查看日志 / UDID / 版本信息 已移出，置于无分组的一级目录**（不挂在任何分组下）。

| # | 项 | 说明 |
|---|---|---|
| 1 | [按钮] 重置默认设置 | 恢复默认配置 |
| 2 | [按钮] 重启服务（service.restart） | 重启 trollvncserver |
| 3 | 重启节流间隔（WatchdogThrottleInterval） | 重启相关：防崩溃循环防抖（60s） |
| 4 | 退出超时（WatchdogExitTimeout） | 重启相关：等待旧进程退出超时（3s） |

> **无分组一级目录**（独立于各板块，页面**底部**按顺序显示）：① 查看日志 ② UDID ③ 版本信息。

### 7.7 默认化设置项（2026-08-21 评估：schema 保留、设置页不显示）

- **悬浮菜单自动收起（FabAutoCollapse）**——固定「自动收起」行为，无调节价值。
