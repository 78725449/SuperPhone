# SuperPhone 架构优化设计

> 日期：2026-08-21
> 状态：设计讨论定稿（待用户审查）
> 范围：设备端采集/隧道/缩略图架构、保活分层、双模式语义

## 1. 背景与问题

当前实现存在的核心问题：

1. **SIGILL 崩溃循环（黑屏根因）**——采集启动时机从「有 5901 客户端才启动」改为「服务启动即常驻」（2026-08-21 架构改造引入），导致 `CARenderServerRenderDisplay` 在服务启动早期、渲染上下文未就绪、无客户端时触发 SIGILL（signal 4），watchdog 每 60s 重启 → 无限崩溃循环 → 黑屏。日志实证：崩溃在 `MAIN: entering main runloop` 后 ~50ms（采集首帧）；`HFB:0` 从未打印（崩在采集渲染 `renderDisplayToScreenSurface`，非缩略图路径）；且 `ThumbPushEnabled=NO` 时仍崩（缩略图路径已被短路，坐实非缩略图所致）。
2. **缩略图/屏幕流割裂**——缩略图走自定义 FT_THUMB 帧（整帧 pHash `computeHashHexForPixelBuffer` + 缩略 JPEG 编码 `tvUpdateThumbCache` + manager 5802 轮询 `tvThumbPollTick` 推送），屏幕流走 RFB 协议（tile 脏矩形检测 + 脏矩形编码发送）。两套协议、两套变化检测、两套输出路径，过度复杂，而两者本可统一。
3. **握手竞态（已修复）**——设备端 5901 握手窗口窄（0-50ms 抖动），noVNC 协议版本经「网关 ack → 放行 → 隧道」有毫秒级延迟，间歇超窗口黑屏；已通过「rfb.start 主动写 RFB 版本」修复。

## 2. 目标架构：统一到 RFB

缩略图和屏幕流统一为**同一个 RFB framebuffer 流的两个帧率档位**，通过「单会话约束下的客户端轮换 + 升降频」切换状态，消除 FT_THUMB / 独立 pHash / 缩略图独立编码 / manager 轮询四套自定义路径。

```
                     ┌─────────────────────────────────┐
                     │  采集层（唯一，惰性启动后常驻）     │
                     │  CARenderServerRenderDisplay     │
                     │  → framebuffer → tile 脏矩形检测  │
                     └───────────────┬─────────────────┘
                                     │ 帧率 = f(状态)：CaptureFps ↔ FrameRateSpec
                                     ▼
                     ┌─────────────────────────────────┐
                     │  RFB 服务（5901，单会话，客户端轮换）│
                     │  同一份 framebuffer，两类客户端轮换   │
                     └───────────────┬─────────────────┘
                                     │ 隧道 18181 透传 RFB 字节流
                                     ▼
                     ┌─────────────────────────────────┐
                     │  网关（消费方式随状态切）           │
                     │  缩略图态：解码 RFB → 缩略图（CSS 缩放）│
                     │  屏幕流态：转发 RFB → noVNC          │
                     └─────────────────────────────────┘
```

> 核心：**缩略图 = 网关作为 RFB 客户端收全尺寸 framebuffer**（低帧率 CaptureFps，脏矩形变化才发，前端 CSS 缩放显示）；**屏幕流 = 控制端作为 RFB 客户端收 framebuffer**（高帧率 FrameRateSpec）。两者共用同一采集、同一 framebuffer、同一 RFB 协议、同一 tile 脏矩形检测，**切换只靠升降频 + 客户端轮换**，无独立缩略图路径。

## 3. 详细设计

### 3.1 采集层（唯一，惰性启动后常驻）

- **惰性启动**：采集**不随服务启动**，随「首个 RFB 客户端出现」启动——网关注册后的缩略图连接（隧道握手成功 → TRTunnelClient connect 本地 5901 → newClientHook），或 5801 直连。根治 SIGILL（避开「服务启动早期、渲染上下文未就绪、无客户端」崩溃窗口）。
- **启动后常驻、只升降频**：采集一旦启动**永不停止**（除非服务退出），只随状态切帧率档——缩略图态 `CaptureFps`（默认 10fps）、屏幕流态 `FrameRateSpec`。避免「反复启停采集」触发 `maybeResizeFramebufferForRotation` 竞态。
- **单一变化检测**：tile 分块 hash（`hashTiledFromBuffer`）脏矩形检测，缩略图与屏幕流**共用同一套**，删除独立的整帧 pHash（`computeHashHexForPixelBuffer`）。
- **方向变化重建加锁**：`maybeResizeFramebufferForRotation` 的 free 旧 buffer + rfbNewFramebuffer 用 pthread_mutex 保护，与采集写入/RFB 发送互斥。

### 3.2 统一 RFB 流（缩略图态 / 屏幕流态）

缩略图与屏幕流是**同一个 RFB framebuffer 流的两个帧率档位**，通过「客户端身份 + 帧率」区分，不再是两条独立路径：

- **缩略图态（空闲）**：网关作为 RFB 客户端，经隧道（设备 TRTunnelClient 桥接本地 5901）收**全尺寸 framebuffer**（低帧率 CaptureFps，脏矩形变化才发，静止零带宽），网关解码后由前端 CSS 缩放显示在卡片墙。**设备端不缩小、不独立 JPEG 编码、不 pHash、不 manager 轮询**。
- **屏幕流态（控制中）**：控制端（noVNC）作为 RFB 客户端，经隧道收 framebuffer（高帧率 FrameRateSpec），网关转发 RFB 字节流给 noVNC 显示。
- **协议统一**：都走 RFB（5901），隧道 18181 透传 RFB 字节流；消除 FT_THUMB 自定义帧、`tvUpdateThumbCache`、`tvThumbPollTick`、5802 `/thumb` 拉取。

### 3.3 状态切换与单会话约束

- **单会话约束**：设备仅 1 个 5901 连接（`_localFd` 单数），缩略图客户端与控制客户端**互斥轮换**（同一时刻仅一个），切换即「顶替」。
- **切换动作 = 客户端轮换 + 升降频**：
  - 缩略图态 → 屏幕流态：点击卡片 → 网关断开缩略图连接、控制端重新握手（复用 rfb.start 无条件重连 + 主动写 RFB 版本）→ 采集升频 FrameRateSpec。
  - 屏幕流态 → 缩略图态：退出控制 → 断开控制连接、网关重新握手缩略图 → 采集降频 CaptureFps。
- **5801 直连**：浏览器直连 5901（旁路，不经网关/隧道），同样产生 5901 客户端 → 升频 + 缩略图暂停；退出降频恢复。

### 3.4 双模式（网关中继 / 桥接控制）

- **标签保留**：设置页保持「网关中继 / 桥接控制」双模式 UI；控制页面保持「加载网关」。
- **中继模式**：注册（18081）+ 隧道（18181 常驻，供缩略图 RFB 流与 rfb.start 命令）+ 惰性启动采集（升降频）+ 5901 RFB（缩略图/屏幕流两态轮换）。
- **桥接控制（遥控器）模式**：纯控制端——**不注册被控、不建隧道客户端、不采集、不启动被控服务**，仅作为 WS 客户端连网关控制被控设备。零被控开销；因不注册，网关设备列表不会出现该设备。

### 3.5 保活分层

分层总览（谁负责什么）：

| 层 | 保活内容 | 负责方 | 手段 |
|---|---|---|---|
| 屏幕 | 屏幕不锁屏（采集持续） | KeepAlive + 用户设置 | `hardwareUnlock` 周期性唤醒（触发条件：**有控制客户端**，非 gClientCount>0）；用户可自行设「不息屏」叠加 |
| 网络连接 | 隧道/注册/WS 存活 | **网关主导** | 心跳检测（隧道 PING 30s、注册 hello、WS 25s）+ 退避重连（2s→30s） |
| 进程 | App/服务存活 | **IPA** | TrollStore：独立进程组（spawn setpgroup，App 被杀服务存活）；越狱：launchd daemon（已实现 postinst launchctl load） |

#### 3.5.1 场景化保活清单

各场景下的具体保活机制：

| # | 场景 | 保活机制 | 负责方 |
|---|---|---|---|
| 1 | 屏幕锁屏（无屏幕流） | 渲染/采集停 → 脏矩形无变化 → 缩略图不更新（卡片停留最后一帧）；网关保留缓存 | 设备（被动） |
| 2 | 屏幕锁屏（屏幕流活跃） | KeepAlive `hardwareUnlock` 周期性唤醒（触发条件：**有控制客户端** 且 KeepAliveSec>0）；用户设「不息屏」为叠加增强 | 设备（KeepAlive + 用户设置） |
| 3 | 网关挂掉 / 网络断开（含 WiFi↔蜂窝切换） | 心跳超时（隧道 PING 30s、注册 hello、WS 25s）→ 退避重连（2s 起翻倍至 30s）；网关恢复自动重连 | **网关主导** + 设备退避 |
| 4 | App 被上滑杀掉 / 后台挂起 | trollvncmanager 独立进程组（spawn setpgroup 脱离 App），App 被杀服务存活；后台挂起不可冻结 | **IPA**（独立进程组） |
| 5 | 系统内存压力（Jetsam 清理） | OhMyJetsam：`JETSAM_PRIORITY_CRITICAL` + 无限高水位 + 不可冻结 → 内存压力从低 band 优先清理，服务几乎不杀 | **IPA**（OhMyJetsam） |
| 6 | trollvncserver 崩溃 / 假死 | 看门狗（watchdog）检测进程存活并 restart-service 重启 | 设备（watchdog） |
| 7 | 系统重启 | 半自动：BGTask 窗口内 ensureServiceRunning 重拉 + LaunchAtLogin/SBS 解锁自拉；无触发源需手动打开 App（详见 6.1） | **IPA**（半自动） |
| 8 | 越狱环境（.deb） | launchd daemon（postinst launchctl load）系统级保活，重启自启、Jetsam 拉起 | launchd（系统级） |

### 3.6 点击卡片弹通知（控制知情 + 软拉起）

- 点击卡片 → 网关经隧道命令通道下发控制请求 → 设备服务弹本地通知（复用 BulletinManager banner 通道）。
- **5801 直连同样弹**——凡**控制客户端**建立即弹（与被控方式无关：点击卡片/5801 直连均触发）。
- **缩略图客户端（网关）不弹**——统一到 RFB 后，网关缩略图连接也是 5901 客户端，必须按「客户端类型」区分：控制客户端弹、缩略图客户端不弹（否则空闲态误弹「被控制」）。
- 价值：**控制知情**（被控方可见谁在控制，安全/透明）+ **软拉起**（用户点通知 → App 打开 → ensure 服务）。通知文案、触发时机等细节待实现时按现有通知体系定。

### 3.7 被控状态上报（控制状态可见性）

- 设备端「控制客户端」建立/断开（0→1 / 1→0）时，经隧道/注册通道推一条轻量状态消息给网关：`{ deviceId, activeClients, source(5801直连 | 隧道rfb.start) }`。
- 网关收到 → 更新设备状态缓存 → WS 推前端 → 卡片叠加「正在被控制中」遮罩（缩略图冻结为背景最后一帧）。
- **仅在状态翻转时推一次**（非持续流），带宽可忽略；5801 直连、点击卡片均触发。

## 4. 时序设计（2026-08-22 统一到 RFB 定稿）

### 4.0 核心不变量（正确路径的骨架）

1. **采集惰性启动 + 启动后常驻只升降频**：采集不随服务启动，随「首个 RFB 客户端」启动，之后永不停止（除非服务退出），只切帧率档（`CaptureFps` ↔ `FrameRateSpec`）——根治 SIGILL 的根基
2. **统一到 RFB**：缩略图与屏幕流都是「RFB 客户端收 framebuffer」，共用同一采集、同一 framebuffer、同一 tile 脏矩形检测，无独立缩略图路径
3. **单会话约束下的客户端轮换**：设备仅 1 个 5901 连接（`_localFd` 单数），缩略图客户端（网关）与控制客户端（noVNC）互斥轮换，切换即顶替
4. **隧道 = 注册生命周期**：18181 隧道常驻，断线只退避重连（2s→30s 翻倍封顶），不拆不重建
5. **脏矩形变化才发**：静止零带宽；锁屏/无变化留最后帧

> 主路径上任何「服务启动即采集」「空闲建独立缩略图路径」「反复启停采集」的行为都是错误的。

### 4.1 生命周期全景（S0→S3）

| 状态 | 采集 | 隧道 | 5901 | RFB 消费 | 保活在岗 |
|---|---|---|---|---|---|
| S0 冷启动 | 未启动 | — | — | — | 进程组 + Jetsam 就位 |
| S1 服务运行 · 无客户端 | 惰性未启动 | 未连接 | 监听（5801 可直连） | — | watchdog + Jetsam |
| S2 已注册 · 缩略图态（**默认态**） | @CaptureFps | 常驻 + 心跳 | 1 连接（网关缩略图） | 网关解码缩略图 | 心跳 + 退避重连 |
| S3 屏幕流态 | @FrameRateSpec | 常驻（承载数据流） | 1 连接（控制端） | 转发 noVNC | KeepAlive 防息屏 + 知情通知 |

- S0→S1：spawn 链 App→manager→server
- S1→S2：连接网关（18081 注册 → ack → 18181 隧道握手）→ 网关缩略图客户端连接（首个 RFB 客户端）→ **采集惰性启动 @CaptureFps**
- S2→S3：点击卡片 / 5801 直连 → 客户端轮换（网关缩略图断开 → 控制端连接）+ **升频 FrameRateSpec**
- S3→S2：退出控制 → 客户端轮换回网关缩略图 + **降频 CaptureFps**

异常自愈不离开服务生命周期：网关挂/断网 → 隧道断 → 缩略图连接断开、采集降频（静默）；server 崩溃 → watchdog 重启重走 S1→S2；App 被杀/挂起 → 独立进程组无感；锁屏 → 留最后帧；系统重启 → 半自动/launchd 恢复。

### 4.2 缩略图态执行链路（S2）

```
1. 网关注册成功 → 隧道握手完成
2. 设备 TRTunnelClient connect 本地 5901（网关缩略图客户端 = 首个 RFB 客户端）
3. newClientHook → 采集惰性启动 @ CaptureFps（默认 10fps，1-30 可配）
4. 采集帧 → framebuffer → tile 脏矩形检测 → 变化才标脏（rfbMarkRectAsModified）
5. libvncserver 编码脏矩形 → 5901 → TRTunnelClient 透传 → 隧道 → 网关
6. 网关解码 RFB 流 → 全尺寸 framebuffer → 缩略图（前端 CSS 缩放）→ 卡片墙渲染
7. 静止 → 脏矩形无变化 → 零带宽；锁屏 → 留最后帧
```

> 与屏幕流共用同一采集/framebuffer/tile 检测，唯一区别是帧率（CaptureFps）与消费方（网关解码缩略图）。

### 4.3 屏幕流态执行链路（S3）

点击卡片（隧道屏幕流）：

```
① 点击卡片 → 前端「连接中…」→ WS /ws/vnc/:id?ctrl=1
② 网关断开缩略图连接（客户端轮换）→ FT_CMD rfb.start(id) 经隧道
③ 设备关旧 fd · connect 127.0.0.1:5901 · 主动写 RFB 003.008（消除握手竞态）
④ 控制端握手 → 采集升频 FrameRateSpec（缩略图态暂停）；弹控制知情通知
⑤ ack(ok=connect) → 网关精确放行缓冲的握手字节（3s 超时兜底）
⑥ RFB 握手透传：版本 / 安全类型 / ServerInit（隧道+网关透明传输）
⑦ 帧数据 @ FrameRateSpec → FBU 增量帧流 → noVNC 渲染（屏幕出现）
⑧ 控制输入反向同路（键鼠/触控 → IOHID 注入）
```

会话退出：

```
⑨ rfb.stop / 断开 WS
⑩ 客户端轮换回网关缩略图连接 + 采集降频 CaptureFps → 回到 S2
```

5801 直连（旁路入口 · 与隧道路径同一语义）：

```
浏览器 → http://设备IP:5801 直连页 → ws(s)://设备:5801/websockify → 桥接本机 5901
（不经网关、不发 rfb.start）。同样产生 5901 客户端 → 升频 / 缩略图暂停 /
控制知情通知 / 退出降频恢复全部一致（④⑦⑧⑩ 复用）。
```

### 4.4 保活在岗映射（阶段 × 机制）

保活不是独立功能，而是嵌在每个阶段的在岗守卫：

| 阶段 | 在岗守卫 |
|---|---|
| 全程（S0-S3） | 进程层：独立进程组 + Jetsam + watchdog |
| S2/S3 | 网络层：隧道 PING / 注册 hello / WS 三路心跳 + 退避重连 |
| S3 | 屏幕层：KeepAlive 防息屏（gClientCount>0 且 KeepAliveSec>0） |
| 系统重启后 | 恢复层：BGTask/SBS 半自动（TrollStore）/ launchd 全自动（越狱） |

详细场景清单见 3.5.1。

## 5. 改造点清单

### 设备端（TrollVNC/src）

| 模块 | 改动 |
|---|---|
| trollvncserver.mm | 采集改为**惰性启动**（首个 RFB 客户端触发，非服务启动即常驻）+ 启动后常驻只升降频；**删除 `tvUpdateThumbCache`**（缩略图独立 pHash + JPEG 编码）；**新增「客户端类型」区分**（缩略图 vs 控制，驱动升降频/KeepAlive/知情通知/被控上报）；`maybeResizeFramebufferForRotation` 加锁保留 |
| ScreenCapturer.mm | 保留动态帧率（升降频）；删除缩略尺寸编码（缩略图改由网关解码全尺寸 framebuffer） |
| TRScreenHasher | 删除整帧 pHash（`computeHashHexForPixelBuffer`），统一用 tile hash（`hashTiledFromBuffer`）脏矩形检测 |
| TRTunnelClient.mm | 从「rfb.start 才 connect 5901」改为「**隧道握手成功后即 connect 5901**（缩略图客户端）+ rfb.start 只轮换/升降频不重连」；保留 rfb.start 主动写版本 + 过滤重复版本；**删除 `sendThumbnail`（FT_THUMB）** |
| trollvncmanager.mm | 桥接模式纯控制端（保留）；**删除缩略图轮询 `tvThumbPollTick` + 5802 `/thumb` 拉取** |

### 网关（trollvnc-farm/server）

| 模块 | 改动 |
|---|---|
| index.js | **新增 RFB 客户端解码**：缩略图态收隧道 RFB 流 → 解码全尺寸 framebuffer → 缓存 + WS 推前端（CSS 缩放）；屏幕流态转发 RFB 流给 noVNC；**删除 FT_THUMB 接收逻辑**；**接收被控状态上报** → 更新状态缓存 → WS 推前端；rfb.start 跳过重复版本（已改） |

### 前端（trollvnc-farm/web）

| 模块 | 改动 |
|---|---|
| app.js | 卡片缩略图读网关解码后的 framebuffer（CSS 缩放显示）；卡片叠加「被控制中」遮罩（收到被控状态上报时）；点击卡片进入控制（客户端轮换由网关/设备端处理） |

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
