# SuperPhone Code Wiki

> 本文档是 SuperPhone 项目的代码级百科，基于实际源码提炼（2026-08-17 生成）。涵盖整体架构、模块职责、关键类与函数、依赖关系、协议契约与运行方式。
> **真相源**：代码始终优先。本文档描述代码中实际存在的机制；与 `说明文档.md`（项目知识库）和 `AGENTS.md`（工作区指令）存在数量差异处，以代码为准并在文中标注。
> **配套文档**：`说明文档.md`（架构/时序/实现真相）、`AGENTS.md`（工作区规则）、`TrollVNC/README.md`（设备端快速开始）、`trollvnc-farm/README.md`（网关启动）。

---

## 目录

1. [项目概述](#1-项目概述)
2. [整体架构](#2-整体架构)
3. [目录结构](#3-目录结构)
4. [设备端模块（TrollVNC/）](#4-设备端模块trollvnc)
   - 4.1 [核心源码（src/）](#41-核心源码src)
   - 4.2 [App 外壳（app/TrollVNC/）](#42-app-外壳apptrollvnc)
   - 4.3 [偏好插件（prefs/）](#43-偏好插件prefs)
   - 4.4 [构建系统（Makefile + devkit/）](#44-构建系统makefile--devkit)
5. [网关模块（trollvnc-farm/）](#5-网关模块trollvnc-farm)
   - 5.1 [服务端（server/index.js）](#51-服务端serverindexjs)
   - 5.2 [前端（web/）](#52-前端web)
   - 5.3 [测试套件（test/）](#53-测试套件test)
   - 5.4 [部署（Dockerfile / deploy/）](#54-部署dockerfile--deploy)
6. [辅助脚本（scripts/）](#6-辅助脚本scripts)
7. [端口与协议契约](#7-端口与协议契约)
8. [依赖关系全景](#8-依赖关系全景)
9. [项目运行方式](#9-项目运行方式)
10. [已知边界与约束](#10-已知边界与约束)
11. [文档差异核对](#11-文档差异核对)

---

## 1. 项目概述

**定位**：内网自用的 iOS 设备群控系统（SuperPhone）。手机装一次、初始化一次，之后零操作；通过软路由上的网页随时看到并操作所有设备。

**三端控制**：
- PC web 控制台（`trollvnc-farm/web/`）
- 手机 web 控制台（同上，移动端布局）
- IPA 控制端（`TrollVNC/app/`，控制 Tab = WKWebView 容器加载网关 H5）

**核心设计原则**：
- **能力层唯一地基**：所有设备操作走 RFB → IOHID 注入，禁止前端自造输入协议
- **前端静态契约**：`caps.js` 自包含定义按键/批量/配置/手势契约，无上报、无元数据表、无运行时发现
- **纯隧道模式**：三端控制台一律走网关隧道，无直连回退、无反向模式
- **状态以网关为准**：前端不持久化设备状态，刷新一律从网关拉取

**边界（明确不做）**：注册鉴权（网关仅 FARM_TOKEN 兜底）、过度 Agent 命令通道、TLS 加固（内网）、多租户、审计、计费、商业化。

---

## 2. 整体架构

### 2.1 三大组成部分

```
┌─────────────────────────────────────────────────────────────────────┐
│                       SuperPhone 单仓库                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  TrollVNC/         设备端（Theos 工程，iOS）                          │
│  ├── src/          VNC 服务 + 命令注册表 + 守护进程（核心源码）         │
│  ├── app/TrollVNC/ UIKit 三 Tab App 外壳                              │
│  ├── prefs/        偏好设置插件（CCTrollVNC + TrollVNCPrefs）         │
│  ├── devkit/       4 scheme 构建脚本                                  │
│  ├── layout/       .deb/.tipa 打包布局（含 5801 直连页）              │
│  └── lib/          预编译静态库（libvncserver/openssl/jpeg/...）       │
│                                                                      │
│  trollvnc-farm/    网关（Node.js ESM）                                │
│  ├── server/       单入口 index.js（注册/隧道/控制台/WS 桥接）         │
│  ├── web/          无构建静态前端（app.js/caps.js/press.js/gesture.js）│
│  ├── test/         测试套件（npm test 串行 11 套件）                    │
│  ├── deploy/       软路由部署文档                                      │
│  └── scripts/      gen-cert.mjs（自签证书）                           │
│                                                                      │
│  scripts/          推送/取包辅助脚本                                   │
│  ├── push-via-api.mjs  Git Data API 推送                              │
│  ├── wait-ipa.mjs      取 CI 产物                                     │
│  └── _tmp-reorder-5801.py  临时脚本                                   │
│                                                                      │
│  .github/workflows/build.yml  CI（macOS 编译 4 scheme）               │
│  说明文档.md          项目知识库（架构/时序/实现真相）                  │
│  AGENTS.md            工作区指令（规则/已知坑）                         │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 端口全集（全固定不可调）

| 端口 | 角色 | 协议 | 说明 |
|---|---|---|---|
| 手机 **5901** | 原生双向控制通道 | RFB/VNC | 画面下行 + 操作上行；含 0x50/0x80 扩展消息命令通道；配置证书后 WS 自动支持 wss（webSocketsCheck 首字节分流，明文不受影响） |
| 手机 **5801** | 网页文件服务器 | HTTP/HTTPS | 只发 noVNC 页面；管理 API 在 5802；有证书时自建 HTTPS 服务器接管（TLS + 明文 301，2026-08-19） |
| 手机 **5802** | 直连页管理 API | HTTP/HTTPS v3 | clipboard.get / type.paste / config.get / cap.list（trollvncserver 自实现轻量 API 服务器，与 RFB 流隔离，2026-08-17 起；**与网关 REST 同构**——管理 HTTP / 画面 RFB，复用 tvExtHandle* 纯函数；2026-08-19 起支持 TLS，peek 分流明文/TLS） |
| 网关 **8080** | 控制台 | HTTP/HTTPS + WS | 外部经 frp/隧道到此，再由网关桥到 5901 |
| 网关 **18081** | 注册/心跳 | TCP JSON 行 | 设备主动拨入 |
| 网关 **18181** | 隧道 | TCP 帧（FT_） | 设备主动建立；无隧道 4003 拒绝 |
| 手机 **46751** | 服务存活探活 | TCP | trollvncmanager 哑服务，accept 后立即 close |

### 2.3 连接模型

- **连接方向**：手机主动注册到网关（18081 TCP JSON），网关被动等待，不做轮询保活
- **设备身份**：首启生成 UUID（`DeviceUUID`）为唯一 `deviceId`，注册名用设备真实名称；同 deviceId 只保留最新一条连接
- **在线状态**：网关维护 = 注册连接存活 **或** 隧道连接存活（任一存活即在线）
- **鉴权**：内网可信，不设设备鉴权；网关保留 `FARM_TOKEN` 兜底
- **初始化**：打开一次 App → 搜索网关（mDNS `_superphone-farm._tcp`）/手动输入 → 保存，之后全自动；Managed.plist 可预置网关免初始化

### 2.4 关键时序

**注册与上线**：
```
设备开机/App 启动 → TRGatewayClient 连接网关 18081
  → 发送 register（deviceId/name/vncPort/configs/screen/httpPort）
  → 网关记录设备，回 ack
  → 设备收到 ack 后才启动 18181 隧道（TRTunnelClient，防重）
  → 网关设备墙出现该设备（在线）
  → 此后每 30s hello；90s 无心跳判离线；重连退避由设备侧拨号
```

**控制会话（proto:2 通道化）**：
```
浏览器/控制端 → WS /ws/vnc/:id（8080）
  → 网关查 tunnels[deviceId]：无隧道 → ws.close(4003, 'no tunnel')；有 → 分配 chanId → 发 CHAN_OPEN(chanId, session)
  → 设备同步 connect 本地 5901 + 主动写 RFB 003.008 → 回 CHAN_ACK(ok)
  → 网关收到 ACK 才放行该通道缓冲的握手字节（跳过 12B 重复版本；3s 超时兜底）
  → connect 失败 → 显式 close 会话（4005 "画面服务不可用"）；缩略图通道（chan 0）常驻并存
```

---

## 3. 目录结构

```
New project/
├── .github/workflows/build.yml          # CI（macOS 编译 4 scheme）
├── AGENTS.md                            # 工作区指令
├── 说明文档.md                          # 项目知识库（真相文档）
├── CodeWiki.md                          # 本文档
│
├── TrollVNC/                            # 设备端 Theos 工程
│   ├── Makefile                         # 主构建文件（PACKAGE_VERSION=0.0.1）
│   ├── src/                             # 核心源码（22 个 .mm/.h）
│   ├── app/TrollVNC/TrollVNC/           # UIKit App 外壳（23 个源文件）
│   ├── prefs/                           # 偏好设置插件
│   │   ├── CCTrollVNC/                  # 控制中心开关
│   │   └── TrollVNCPrefs/               # Preferences.app 设置 bundle
│   ├── devkit/                          # 4 scheme 构建脚本
│   ├── layout/                          # 打包布局
│   │   └── usr/share/trollvnc/webclients/  # 5801 直连页（caps.js 分叉副本）
│   ├── lib/                             # 预编译静态库
│   ├── include/                         # 第三方头文件
│   ├── include-spi/                     # 私有 API 头文件
│   └── CHANGELOG.md / README.md / COPYING
│
├── trollvnc-farm/                       # 网关 Node.js ESM
│   ├── server/index.js                  # 单入口（1574 行）
│   ├── web/                             # 前端（无构建）
│   │   ├── index.html / app.js / style.css
│   │   ├── caps.js                      # 前端契约唯一真相源
│   │   ├── press.js / gesture.js
│   │   └── mockup.html / mockup-full.html
│   ├── test/                            # 测试套件（11 套件 + 验收脚本）
│   ├── deploy/                          # 软路由部署文档
│   ├── scripts/gen-cert.mjs             # 自签证书生成
│   ├── Dockerfile / docker-compose.yml
│   └── package.json
│
└── scripts/                             # 辅助脚本
    ├── push-via-api.mjs                 # Git Data API 推送
    ├── wait-ipa.mjs                     # 取 CI 产物
    └── _tmp-reorder-5801.py             # 临时重排脚本
```

---

## 4. 设备端模块（TrollVNC/）

### 4.1 核心源码（src/）

#### 4.1.1 trollvncserver.mm — VNC 服务主进程

**文件**：`TrollVNC/src/trollvncserver.mm`（~4873 行，无 ObjC 类，全 C 函数）
**入口**：`main(argc, argv)` (L4826)

**核心职责**：基于 libvncserver 暴露 5901 RFB + 5801 HTTP + Bonjour mDNS；通过 RFB 扩展消息 0x50/0x80 暴露设备能力通道；**采集惰性启动（2026-08-22，隧道握手成功 tunnel-connected 通知触发，CaptureFps 低频驱动；客户端连接只升降频 FrameRateSpec，不再启停采集）**；管理客户端连接/黑名单；接收命令注入 IOHID 触控/键盘事件；提供配置热重载入口 `tvReloadConfigForKey`。

**关键函数**：

| 函数 | 行号 | 作用 |
|---|---|---|
| `main(argc, argv)` | L4826 | 进程入口：dropPrivileges → parseCLI → setupGeometry → setupRfbScreen → initializeAndRunRfbServer → installSignalHandlers |
| `tvExtHandleMessage(cl, data, message)` | L3354 | RFB 扩展消息分发入口；拦截 `message->type == 0x50`，按 op 路由到 14 个子 handler |
| `tvExtReadMessage(cl)` | L3295 | 从 rfbClientPtr 读 7B 剩余帧头 + 4B BE payloadLen + JSON payload，反序列化为 NSDictionary |
| `tvExtWriteResponse(cl, resp)` | L3313 | 构造 0x80 响应帧（8B 头 + JSON），在 `cl->sendMutex` 锁内整帧写出（防与 FBU 帧交错） |
| `tvExtHandleCapHello(cl, params)` | L3448 | 管理客户端豁免：`mgmt=YES` 时 `isMgmtClient=YES`、`gClientCount--`、`viewOnly=TRUE` |
| `tvExtHandleTypePaste(cl, params)` | L3484 | 剪贴板写入 + Cmd+V 注入：setStringForPasteInput → releaseEveryKeys → COMMAND↓ → v↓ → v↑ → COMMAND↑ |
| `tvReloadConfigForKey(key)` | L3247 | 配置热重载：支持 Scale/FrameRateSpec/OrientationSync/DeferWindowSec/MaxInflight/KeepAliveSec/WheelStepPx/ModifierMap/FullscreenThresholdPercent；**2026-08-20 改按 suite `com.82flex.trollvnc` 读取**（原 standardUserDefaults 无 bundle 进程读不到设置页值）；返回 0=成功 / -1=未知 / -2=无效 |
| `tvApplyPrefsChanged` / `tvInstallPrefsChangedListener` | L3310 / L3341 | **设置页热重载通道（2026-08-20）**：notify 监听 `com.82flex.trollvnc.prefs-changed` → 重读 suite 热重载 hot/instant 配置（含 Notifications 映射底层开关、OrientationPadFix 重建 framebuffer、NaturalScroll/AutoAssistEnabled/KeyLogging 全局变量） |
| `tvGetInflightStats(void)` / `tvGetBonjourTXT(void)` | L3103 / L3108 | 公开统计访问，供 sys.* 能力调用 |

**0x50/0x80 扩展操作（14 个 op）**：`cap.hello` / `cap.list` / `screen.hash` / `screen.diff` / `screen.waitStable` / `clients.count` / `clients.list` / `clients.disconnect` / `clients.block` / `clients.unblock` / `clients.blocked.list` / `clipboard.get` / `type.paste` / `config.get`

**关键全局变量**：`gPort=5901`、`gHttpPort=5801`（端口固定不可调）、`gScale/gFpsMin/gFpsPref/gFpsMax/gDeferWindowSec/gMaxInflightUpdates/gTileSize/gFullscreenThresholdPercent/gMaxRectsLimit/gAsyncSwapEnabled`、`gWheelStepPx=48.0`、**`gCaptureLowFps=10.0`（缩略图态惰性采集低频帧率，CaptureFps 钳制 1..30）、`gFramebufferLock`（framebuffer 重建/采集写入/RFB 发送互斥）**

---

#### 4.1.2 trollvncmanager.mm — 守护进程主程序

**文件**：`TrollVNC/src/trollvncmanager.mm`（474 行）
**入口**：`main(argc, argv)` (L228)

**核心职责**：用文件锁实现单例；监控自身可执行文件 vnode 删除事件（被升级覆盖时 exit 让 launchd 重启）；启动 `TRWatchDog` 守护 `trollvncserver`；启动 `TRGatewayClient` 注册到网关 18081；监听 SIGCHLD/SIGHUP/SIGINT/SIGTERM；在 127.0.0.1:46751 打开哑服务端口供探测；启动时 sysctl 清理孤儿 trollvncserver；**双通知自治（2026-08-20，替代 App kill 通路——mobile 沙盒 kill root 恒 EPERM）**：订阅 `prefs-changed`（桥接模式自退 / GatewayClient 重发 register / watchdog 热调，双域读取）与 `restart-service`（watchdog 重启 trollvncserver，root 杀 root）。

**关键函数**：

| 函数 | 行号 | 作用 |
|---|---|---|
| `main(argc, argv)` | L228 | 单例锁 → killStaleVncServer 清孤儿 → 探测越狱根 → 创建 TRWatchDog → 配置可执行文件/环境/用户 → start → 注入 restartHandler → 启动 TRGatewayClient → 信号注册 → openLocalDummyService → 订阅双通知（prefs-changed / restart-service）→ bridge 启动守卫 → CFRunLoopRun → 清理（watchdog stop + 等子进程退出） |
| `monitorSelfAndRestartIfVnodeDeleted(executable)` | L101 | dispatch_source 监听 `DISPATCH_VNODE_DELETE`，文件被删除时 exit(EXIT_SUCCESS) |
| `killStaleVncServer()` | L71 | sysctl KERN_PROC_ALL + KERN_PROCARGS2 枚举（root 可读任意进程 argv），SIGKILL 残留 trollvncserver（释放 5901/5801/5802） |
| `tvManagerReadPref(defaults, key)` | L126 | 双域配置读取：root defaults 优先，mobile 域 plist 文件兜底（App 设置页写 mobile 域、root 进程读不到） |
| `tvManagerIsBridgeMode()` | L136 | ConnectionMode=bridge 判定（未设置/非 bridge 均 relay） |
| `openLocalDummyService(port)` | L145 | 在 127.0.0.1:port 监听 TCP，accept 后立即 close 不响应 |
| `mSignalAction` / `mSignalHandler` | L49-65 | SIGCHLD 调 waitpid(WNOHANG) 收尸；SIGHUP/SIGINT 停 run loop；SIGTERM 直接退出 |

**关键常量**：`SINGLETON_MARKER_PATH = "/var/mobile/Library/Caches/com.82flex.trollvnc.manager.pid"`、`kTvAlivePort = 46751`、stdout/stderr 重定向到 `<jbroot>/tmp/trollvnc-stdout.log` / `trollvnc-stderr.log`

---

#### 4.1.3 TRCapabilityRegistry — 能力注册表

**文件**：`TrollVNC/src/TRCapabilityRegistry.h`（94 行）+ `.mm`（1751 行）
**类名**：`TRCapabilityRegistry`（单例）

**核心职责**：能力即服务注册表，数据驱动统一管理所有设备能力（控制型 + 配置型）；提供 `invoke:` 统一执行入口（按 route 分发 HID/Touch/LocalCmd/Native）和 `setConfig:` 统一配置下发入口；经 5901 RFB 扩展消息桥接本地命令；自签 CA 证书生成；局域网网关搜索。

**关键方法**：

| 方法 | 作用 |
|---|---|
| `+ sharedRegistry` | dispatch_once 单例 |
| `- invoke:params:error:` | 查 `_controlCaps[capId]` → 调 `cap.executor(params, error)`；route 类型仅作元数据标记 |
| `- setConfig:value:error:` | 类型/范围校验 → 写 NSUserDefaults → 按 reload 分发（hot: tvReloadConfigForKey / restart: wd restart / gateway/instant: NSUserDefaultsDidChangeNotification） |
| `- allControlMetadata` / `- allConfigSchema` / `- currentConfigs` | 供 query 命令返回能力清单/配置 schema/当前值（含 hasPassword 标记） |
| `- _registerAllCapabilities` | 注册 8 大类：HID/Touch/Native/SettingsActions/LocalCmd/SystemQuery/Gateway/ScreenHash + ConfigSchemas（`_registerConfigSchemas` **35 项**——前端 CONFIG_DEFS 33 项 + BonjourEnabled/ViewOnlyPassword 保留注册不暴露 UI，2026-08-23 定位 +5 SimLocation*） |
| `- _rfbCommand:params:timeoutMs:error:` (L1682) | 以 JSON {op, params} 封装为 0x50 帧发送到 127.0.0.1:5901，读 0x80 响应 |
| `static tvRfbConnect(NSError **)` (L1590) | RFB 3.8 握手 + 发送 `cap.hello {mgmt:YES}` 标记管理客户端 |
| `static TRGenerateSelfSignedCert(...)` (L123) | RSA2048 自签 CA 证书（pathLen=0、keyUsage/EKU 齐全） |

**能力分类与路由**：
- `TRCapCategory`：Control=0（一级菜单）/ Config=1（二级菜单）
- `TRCapRouteType`：HID=0 / Touch=1 / LocalCmd=2（经 5901 RFB 扩展消息）/ Native=3（原生 ObjC 调用）
- `TRConfigReload`：Instant=0 / Hot=1（trollvncserver 监听重载）/ Gateway=2（改注册字段触发重报）/ Restart=3（端口/认证变更需重启）

**触控契约**：归一化 0-1（(0,0)=左上、(0.5,0.5)=中央、(1,1)=右下），`_normToPixelX:y:outPoint:` 转屏幕物理像素钳制 [0, sz-1]；`HIDMaxTouchCount=30`；pinch scale 限制 0.5~2.0

**type.paste 时序**：150ms 等 Ctrl 残留 → releaseEveryKeys → COMMAND↓ → 120ms → v↓ → 90ms → v↑ → 40ms → COMMAND↑，异步执行 + ack 提前返回

---

#### 4.1.4 TRGatewayClient — 网关注册/心跳客户端

**文件**：`TrollVNC/src/TRGatewayClient.h`（47 行）+ `.mm`（613 行）
**类名**：`TRGatewayClient`（单例）

**核心职责**：内网群控网关注册/心跳客户端（BSD socket / TCP JSON 行协议）；读取 `GatewayHost/GatewayToken` 配置生成并持久化设备 UUID；连接网关 18081 发送 register，定时 30s 发 hello；处理网关下发的 cmd 命令（ping/query/set/invoke/restart）；收到 ack 后启动 18181 隧道客户端并注入 commandHandler；设置变更时标记 `_needsReregister` 由 worker 线程重发 register；跨用户域镜像 DeviceUUID 到 mobile 域供 App 读取。

**关键方法**：

| 方法 | 行号 | 作用 |
|---|---|---|
| `+ sharedClient` | — | dispatch_once 单例；init 时监听 NSUserDefaultsDidChangeNotification |
| `- start` / `- stop` | — | 启动/停止 worker thread |
| `- _connectAndRun` | L324 | socket + gethostbyname + connect → 发 _registerData → 重置 _retryDelay=2s → 进入 select 读循环（5s 超时） |
| `- _registerData` | L240 | 构造 register JSON `{type, deviceId, name, vncPort:5901, configs, screen:{width,height}, httpPort:5801}` + `\n` |
| `- _handleServerLine:fd:` | L453 | 解析 JSON 行；type=="ack" → 同步启动隧道（防重）；type=="cmd" → _buildAckForCommand |
| `- _buildAckForCommand:` | L480 | 分发 ping/query/set/invoke/restart（query target=caps/configs/schema/status） |
| `- _startTunnel` | L599 | 创建 TRTunnelClient，注入 commandHandler block（复用 query/set/invoke/restart 通道） |
| `- _mirrorDeviceIdToMobileDomain:` | L172 | 经 CFPreferencesSetValue 写 mobile 用户域；回退直接写 plist；写后读回验证 |

**关键常量**：`kHelloInterval=30.0`、`kReadTimeout=5.0`、`kMinRetryDelay=2.0`、`kMaxRetryDelay=30.0`；端口硬编码 `_gatewayPort=18081` / `_vncPort=5901` / `_httpPort=5801`

**环境变量**：无（2026-08-20 删除 env 读取——spawn 时刻冻结的 `TVNC_GATEWAY_HOST` 会永久遮蔽设置页后续修改）；网关配置读 `_gatewayHost` 双域链：root defaults → mobile 域 plist 兜底；host 变更由 `_connectAndRun` 超时分支比对 connectedHost 主动断开重连；`noteExternalPrefsChanged`（manager prefs-changed 通知链调入）标记重发 register + 清设备名缓存 + 未启动时立即 start

---

#### 4.1.5 TRTunnelClient — 隧道客户端

**文件**：`TrollVNC/src/TRTunnelClient.h`（38 行）+ `.mm`（~740 行）
**类名**：`TRTunnelClient`（单例）

**核心职责**：设备侧隧道客户端（BSD socket / TCP + 帧封装）；注册到网关成功后由 TRGatewayClient._startTunnel 启动，建立到网关 18181 的隧道连接；握手后进入帧封装透传模式（proto:2 通道复用），让多路 RFB 连接（chan 0 缩略图 + 会话通道）与 JSON 心跳/命令在同一隧道上共存；通过 select() 多路复用隧道与全部通道 fd 的双向数据流；每 30s 发 PING 心跳；CMD 帧复用 commandHandler；独立线程运行，断线退避重连。

**关键方法**：

| 方法 | 行号 | 作用 |
|---|---|---|
| `- startWithHost:port:deviceId:token:` | L132 | 参数校验 + 已启动时参数变化则先 stop 再重启，否则幂等返回 |
| `- _connectAndRun` | L205 | TCP connect → _sendHandshakeHello（proto:2）→ _recvHandshakeAck → 等待网关 CHAN_OPEN → _passthroughLoop |
| `- _passthroughLoop:` | L361 | select 多路复用——tunnel 可读 → _appendFrameData → _processFramesTunnel；通道 fd 可读 → 反查 chanId 封装 CHAN_DATA 写隧道；通道 EOF 仅清理该通道（_closeChannel） |
| `- _processFramesTunnel:` | L479 | 循环解析帧——CHAN_OPEN 同步 connect 5901 + 主动写版本 + 回 CHAN_ACK；CHAN_DATA 写对应通道 fd（未知通道丢弃+回 CHAN_CLOSE）；CHAN_CLOSE 关通道；FT_PONG 标记存活；FT_PING 回 FT_PONG；FT_CMD 委托 commandHandler |
| `- _closeChannel:reason:` | L~665 | 关通道 fd、清表项、会话通道归零时降频+上报被控结束、EOF 时回 CHAN_CLOSE 通知网关 |
| `- _writeFrame:fd:type:data:length:` | L~700 | 写 5 字节头（1B type + 4B BE length）+ payload，处理部分写 |
| `- _appendFrameData:length:` | L436 | 动态扩容帧缓冲（初始 8KB，倍增到 16MB 上限） |

**FT_ 帧类型常量**（L35-46）：
- `FT_PING=0x02` 心跳请求（设备→网关，每 30s）
- `FT_PONG=0x03` 心跳响应（双向）
- `FT_CMD=0x04` 命令 JSON（网关→设备）
- `FT_CMDACK=0x05` 命令 ack JSON（设备→网关）
- `FT_STATE=0x07` 被控状态上报（设备→网关）
- `FT_CHAN_OPEN=0x08` 通道建立（网关→设备，[chanId:2BE][kind:1B]）
- `FT_CHAN_ACK=0x09` 通道建立确认（设备→网关，[chanId:2BE][ok:1B]）
- `FT_CHAN_DATA=0x0A` 通道 RFB 数据（双向，[chanId:2BE][rfb字节]）
- `FT_CHAN_CLOSE=0x0B` 通道关闭（双向，[chanId:2BE][reason:1B]）

**关键常量**：`kTunnelPingInterval=30.0`、`kTunnelSelectTimeout=5.0`、`kTunnelMinRetryDelay=2.0`、`kTunnelMaxRetryDelay=30.0`、`kLocalRfbPort=5901`、`kDefaultTunnelPort=18181`、`kFrameHeaderSize=5`、`kMaxFramePayload=16MB`、`kReadBufSize=64KB`、`kTunnelProto=2`、`kChanIdThumb=0`

**通道模型（proto:2，2026-08-23）**：通道表 `_channels`（chanId→5901 fd）；chan 0 固定缩略图（隧道握手后网关即开），会话通道从 1 起网关单调分配；CHAN_OPEN 同步 connect 5901 + 主动写 `RFB 003.008\n`（5901 握手窗口 0-50ms 极窄）+ 回 CHAN_ACK；会话通道开/关驱动升降频（capture-active/idle）与被控上报（controlled YES/NO）。rfb.start/rfb.stop 已移除。

---

#### 4.1.6 STHIDEventGenerator — IOHID 事件注入器

**文件**：`TrollVNC/src/STHIDEventGenerator.h`（305 行）+ `.mm`（1686 行）
**类名**：`STHIDEventGenerator`（单例）

**核心职责**：通过 IOKit 私有 API（IOHIDEventCreateKeyboardEvent / IOHIDEventCreateDigitizerEvent 等）注入键盘、触摸、按键、滚轮事件至系统 BackBoard，使所有事件具有真实硬件来源（绕过沙盒限制）；提供触摸/手势/按键的高级 API + 底层事件流；keepAlive 定时器防休眠；管理活动按键/触点状态。

**关键方法**：

| 方法 | 作用 |
|---|---|
| `+ sharedGenerator` | dispatch_once 单例；init 时计算 _physicalScreenSize（含 OrientationPadFix 交换） |
| `- touchDown:` / `- liftUp:` | 单指按下/抬起 |
| `- touchDownAtPoints:touchCount:` | 多指异点按下（C 数组，长度≥touchCount） |
| `- dispatchHandResetEvent` | 发送 HandReset 事件清除所有触点（touch.reset 能力） |
| `- dispatchEventWithInfo:` | 透传 eventInfo 字典构造任意 IOHIDEvent（touch.event） |
| `- sendEventStream:` | 按时间轴播放事件流（touch.eventStream，异步线程，支持插值/时间步进） |
| `- tap/doubleTap/twoFingerTap/threeFingerTap/longPress` | 手势方法 |
| `- dragLinearWithStartPoint:endPoint:duration:` / `- dragCurveWithStartPoint:endPoint:duration:` | 线性/曲线拖拽 |
| `- pinchLinearInBounds:scale:angle:duration:` (L945) | 在 bounds 矩形内执行线性 pinch（scale 0.5~2.0 + angle 弧度） |
| `- keyDown:` / `- keyUp:` / `- keyPress:` (L1197) | ASCII 键盘（c<128）→ HID usage code 映射（含 Shift 包装判断） |
| `- menuPress/menuDoublePress/menuLongPress` | Home 键组合 |
| `- powerPress/powerDoublePress/powerTriplePress/powerLongPress` | Power 键组合 |
| `- snapshotPress` | Home+Power 截图 |
| `- hardwareLock` / `- hardwareUnlock` | 键盘锁定/解锁（Kiosk 模式） |
| `- releaseEveryKeys` | 释放所有按下按键（type.paste 前清残留修饰键） |
| `- setKeepAliveInterval:` | 设置防休眠定时器间隔（≥30s），fire 时调 hardwareUnlock |

**关键常量**：`HIDMaxTouchCount = 30`、`fingerIdentifiers[]`（30 个 IOHID 触点 ID）、`fingerLiftDelay=0.05`、`multiTapInterval=0.15`、`fingerMoveInterval=0.016`（≈60fps）、`longPressHoldDelay=2.0`、`defaultMajorRadius=5`、`defaultPathPressure=0`

---

#### 4.1.7 ScreenCapturer + TRScreenHasher

**ScreenCapturer**（`ScreenCapturer.h` 127 行 + `.mm` 496 行，单例）
- 基于 `CADisplayLink` + `IOSurface` + `CARenderServerRenderDisplay`（私有 API）捕获设备屏幕
- 产生 `CMSampleBufferRef`（CVPixelBuffer backing by IOSurface）供编码器使用，零拷贝包装
- 支持脏帧检测（CARenderServerGetDirtyFrameCount）
- `captureSingleFrameBuffer` 零拷贝 CVPixelBuffer（供 pHash，省 ~8ms）
- `captureSingleFrameImage` UIImage via CoreImage（静默截图，不触发系统截图动画）
- DEBUG 构建含 FPS 统计（EMA 平滑，alpha=0.2）
- **采集生命周期（2026-08-22 统一到 RFB）**：隧道握手成功（tunnel-connected 通知）才惰性启动低频采集（CaptureFps 默认 10fps）；客户端连接只经 `setPreferredFrameRateWithMin:preferred:max:` 升降频（newClientHook 升频 FrameRateSpec / clientGoneHook、cap.hello 豁免归零降回低频），不再启停采集

**TRScreenHasher**（`TRScreenHasher.h` 133 行 + `.mm` 459 行，单例，Phase 11.4）
- 基于 Accelerate framework（vImage + 自写 DCT-II）实现 5 步 pHash 管线：取帧 → 缩放 32×32 → 灰度 Rec.601 → DCT-II → 8×8 低频哈希
- 单次 pHash ≈0.3ms（vs JPEG 8ms，快 26 倍）；60fps 持续计算 CPU <1%，内存 4KB
- `computeHashForCurrentFrame` / `computeHashHexForCurrentFrame` 返回 64bit pHash（hex 版本供 screen.hash 能力使用）
- `hammingDistanceBetweenHash:andHash:` 用 `__builtin_popcountll(a ^ b)`
- `diffWithBaselineHash:threshold:currentHash:` 计算 `{distance, threshold, changed, currentHash}`
- `waitStableWithMaxMs:stableMs:intervalMs:threshold:frameCount:durationMs:lastHash:` 轮询等待画面稳定
- **用途**：screen.hash / screen.diff / screen.waitStable 三项能力底层实现（按需调用，替代已移除的前端 screen.hash/screenshot 卡片墙轮询门控）

**默认阈值**：`TRScreenHashDiffDefaultThreshold=5`（<3 基本相同 / 3-8 轻微 / 8-15 明显 / >15 完全不同）、`TRScreenWaitStableDefaultMaxMs=3000`、`TRScreenWaitStableDefaultStableMs=500`、`TRScreenWaitStableDefaultIntervalMs=200`、`TRScreenWaitStableDefaultThreshold=3`

---

#### 4.1.8 ClipboardManager — 剪贴板访问点

**文件**：`TrollVNC/src/ClipboardManager.h`（54 行）+ `.mm`（66 行，单例）

**核心职责**：轻量级剪贴板访问点（仅 UTF-8 文本），包装 `UIPasteboard generalPasteboard`，供 `clipboard.get`（复制按钮显式拉取）、`type.paste`（粘贴数据载体写入）、RFB Extended Clipboard 协议共用。

**关键方法**：
- `+ sharedManager`：单例
- `- currentString`：读 UIPasteboard.generalPasteboard.string，空返回 nil
- `- setStringFromRemote:`：写 UIPasteboard（RFB 协议 / 5801 经 5802 管理通道粘贴的数据载体，RFB 原语兜底）
- `- setStringForPasteInput:`：与 setStringFromRemote 同义，保留独立名供 type.paste executor 调用

**架构决策（2026-08-17）**：自动同步已移除——平台无写入者身份，自动同步只能启发式且有误判边界，已决策弃用；显式双向搬运：复制=拉（clipboard.get / 0x50 clipboard.get）、粘贴=推（type.paste）；设备端不再监听系统剪贴板、不再自动推送。

---

#### 4.1.9 其他设备端源码

**BulletinManager**（`BulletinManager.h` 41 行 + `.mm` 171 行，单例）
- 本地通知横幅管理；通过 `UNUserNotificationCenter initWithBundleIdentifier:` 借用其他 bundle ID 发通知（bootstrap 用 `com.82flex.TrollVNCApp`，否则 `com.apple.Preferences`）
- `popBannerWithContent:userInfo:` 一次性通知（interruptionLevel=Active + defaultSound）
- `updateSingleBannerWithContent:badgeCount:userInfo:` 单条持续横幅（interruptionLevel=Passive，0.33s 延迟 trigger）
- iOS 16+ `setBadgeCount:` 重置徽章

**TRWatchDog**（`TRWatchDog.h` 159 行 + `.mm` 990 行）
- 基于 `TRTask`（Swift）启动/停止/重启子进程，状态机驱动（Stopped/Starting/Running/Stopping/Crashed/Throttled）
- 串行 dispatch_queue 保证线程安全；keepAlive 条件重启（BOOL 或 NSDictionary 含 Crashed/SuccessfulExit 条件）
- throttle interval 防止快速重启循环；exit timeout 超时后 SIGKILL 强制终止
- 默认值：`exitTimeOut=3.0`、`throttleInterval=30.0`、`keepAlive=@YES`

**TRDaemonBridgeManager.mm**（34 行，C 函数 stub）
- 守护进程桥接函数的 Manager 降级实现：bootstrap 构建中 TRCapabilityRegistry 编译进 trollvncmanager，调用 `tvGetInflightStats / tvGetBonjourTXT / tvReloadConfigForKey` 时本文件提供 stub 返回空数据 / -1
- 调用方对非 0 返回值做 Watchdog/HID 属性兜底处理

**OhMyJetsam.mm**（80 行，C 函数 + constructor(101)）
- Jetsam 内存压力绕过：进程启动时调 `memorystatus_control` 私有 API 提升到 `JETSAM_PRIORITY_CRITICAL`
- 设置高水位标记 -1（无限）、task limit=0x400、PROCESS_IS_MANAGED=0、PROCESS_IS_FREEZABLE=0、proc_track_dirty(0)
- simulator 不编译

**Logging.h**（34 行，宏）
- 定义 `tvncLoggingEnabled`（默认 YES）/ `tvncVerboseLoggingEnabled`（默认 NO）
- `TVLog(fmt, ...)` / `TVLogVerbose(fmt, ...)` 宏封装 NSLog + `__PRETTY_FUNCTION__` + `__LINE__`
- 用 `\r` 行尾让日志在 iOS Console 中紧贴前一行显示

**Control.h**（22 行，软链到 app/.../Control.h）
- `FOUNDATION_EXTERN int gOrientationFixQuad`：方向修正象限（0=0°、1=90°CW、2=180°、3=270°CW）
- `static const int kTvAlivePort = 46751`：trollvncmanager 哑服务端口

**TaskProcess+ObjC.swift**（Swift 实现 `TRTask` 类）
- 对 `posix_spawn` + 私有 persona API 的 ObjC 友好封装
- 提供 executableURL/arguments/environment/userIdentifier/groupIdentifier/standardInput/Output/Error/terminationHandler/launchAndReturnError/terminate
- 被 TRWatchDog.mm 通过 `trollvncmanager-Swift.h` 引用
- persona API（`posix_spawnattr_set_persona_np` 等）实现 root 身份 spawn

---

### 4.2 App 外壳（app/TrollVNC/）

UIKit 三 Tab App（SceneDelegate → TRMainTabBarController）：

```
AppDelegate.m                  生命周期 + 崩溃落盘 + 启动 ServiceCoordinator/HotspotManager
SceneDelegate.m                构建窗口 + 根 VC（@try Tab / @catch 回退设置页）
TRMainTabBarController.m       四 Tab 容器（紫色调 RGB 107/78/255，所有 Tab 顶部导航栏隐藏）
  ├── Tab 1 连接 = TVNCConnectViewController
  ├── Tab 2 控制 = TVNCConsoleWebViewController（WKWebView 加载 ?container=ipa）
  ├── Tab 3 伪装 = TRDisguiseViewController（M5 伪装页：位置模拟/联系人/通话/短信 四子页容器）
  └── Tab 4 设置 = TVNCRootListController（PSRootController 包装）
```

#### 4.2.1 TVNCConsoleWebViewController — 控制 Tab 内核

**核心职责**：WKWebView 容器，加载网关 H5 控制台 `https://{host}:{port}/?container=ipa&token=&selfId=`；提供原生桥（`farmBridge`）；处理自签证书信任、配置轮询、加载失败引导。

**关键方法**：
- `viewDidLoad` — 五步分步 `@try` 降级（setupWebView / spinner / statusOverlay / 约束 / 首屏加载标记）
- `viewDidLayoutSubviews` — 首次布局完成后才触发首屏加载（避免 WKWebView 初始 frame 错误导致 H5 视口尺寸错乱）
- `buildConsoleURL` — 读 TVNCGatewayClient host/port/token + TVNCReadSelfDeviceId() 拼接
- `loadConsoleIfNeeded` — 幂等加载（URL 未变且已加载成功跳过；否则 ReloadIgnoringLocalCacheData + 15s timeout）
- `userContentController:didReceiveScriptMessage:` — farmBridge 桥消息：
  - `writeClipboard`：原生写 UIPasteboard（绕开 iOS WebKit 非手势 writeText 被拒）
  - `setTabBarHidden`：H5 聚焦时隐藏/恢复底部 TabBar
- `webView:didReceiveAuthenticationChallenge:` — 无条件信任 serverTrust（内网自签边界）

#### 4.2.2 TVNCConnectViewController — 连接 Tab

**核心职责**：Hero 卡片（设备名+状态点+连接状态+服务状态三行）+ 扫码直连卡 + 客户端列表卡；监听 3 类通知刷新。

**关键方法**：
- `TVNCEn0IPv4()` — 静态；getifaddrs 取 en0 IPv4
- `TVNCQRCodeImage(content)` — 静态；CIQRCodeGenerator + M 级纠错 + 10x scale
- `makeHeroCard` — 构建 TVNCGradientCard（渐变蓝），含 3 行
- `refreshStatus` — 按 TVNCGatewayState（Registered→绿/ServiceUp→黄/Disconnected→红/Idle→灰）刷新
- `generateQRAsync` — 后台生成 `http://{ip}:5801` 二维码（端口固定 5801）

#### 4.2.3 TVNCGatewayClient — App 内网关客户端

**核心职责**：单例 HTTP 客户端；读 NSUserDefaults 配置；信任网关自签证书；封装 `/api/devices` 拉取。

**关键方法**：
- `sharedClient` — dispatch_once 单例
- `gatewayHost` / `gatewayPort`（固定 8080）/ `gatewayToken` — 实时读取 `com.82flex.trollvnc` suite
- `tlsTrustingSession` — 懒加载 URLSession，timeoutIntervalForRequest=6.0
- `URLSession:didReceiveChallenge:completionHandler:` — 信任 serverTrust
- `requestWithURL:method:body:` — 注入 Bearer {token} + Content-Type
- `fetchDevicesWithCompletion:` — GET /api/devices → 解析 devices 数组 → 主线程回调

#### 4.2.4 TVNCServiceCoordinator — 服务守护

**核心职责**：守护 trollvncserver 进程；3s 定时探活（连接 127.0.0.1:46751）；掉线拉起；BGTaskScheduler 锁屏保活；LaunchAtLogin preboot 拉起依赖 App；首次写入 DeviceUUID/Managed defaults。

**关键方法/函数**：
- `TVNCDeviceUDID()` — 全局函数；dlopen libMobileGestalt.dylib + MGCopyAnswer("UniqueDeviceID")，失败回退 NSUserDefaults
- `sharedTaskEnvironment` — 静态环境字典；仅注入 TVNC_LANGUAGE_CODE（2026-08-20 删除 TVNC_GATEWAY_HOST/TOKEN env 注入——冻结在 spawn 时刻会永久遮蔽设置页修改；root 域配置读取统一走 TRGatewayClient 双域链）
- `registerServiceMonitor` — 启动 3s NSTimer + registerBackgroundTasks
- `ensureServiceRunning` — ConnectionMode=bridge 时早退（本机仅控制端，不 spawn；stopService 已删——manager 收 prefs-changed 通知自退）；否则 _isServiceRunning 失败时调 checkPrebootDependencies + spawnService
- `_isServiceRunning` — 真机：socket connect 127.0.0.1:46751 端口探活（沙盒安全准确）；不用进程枚举（iOS 沙盒 KERN_PROCARGS2 读 root 进程 EPERM，枚举会误判）；模拟器：恒 YES
- `spawnService` — TRTask 启动 trollvncmanager（setUserIdentifier:0 root / setGroupIdentifier:0）
- `checkPrebootDependencies` — 读 LaunchAtLogin → SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions
- `registerBackgroundTasks` / `scheduleBGRefresh` / `handleBGRefreshTask:` — BGTaskScheduler 注册 `com.82flex.trollvnc.refresh`，earliestBeginDate=15min

#### 4.2.5 TVNCAppStore — 控制端状态层

**核心职责**：单一数据源；网关状态机（Idle/ServiceUp/Registered/Disconnected/**BridgeConnected**——2026-08-20 桥接模式：isBridgeMode 网关可达即目标态，无注册判定不重试）+ 设备目录缓存（60s TTL）+ 结果驱动重试退避（1→2→4→8→15s 封顶，最多 8 次 ≈ 75s 上限）。

**关键方法**：
- `ensureDeviceDirectory` — 缓存新鲜（< 60s）直接复用；网关未配置 return；否则 fetchWithRetry
- `isRegistered` — 动态读 TVNCReadSelfDeviceId()，遍历目录匹配自身 id 且该记录 online=true（2026-08-20：仅活跃注册才算已连接，db 残留记录不再误判）
- `isBridgeMode` — 动态读 ConnectionMode（App 直读 mobile 域，无需跨域兜底）；默认 relay
- `fetchWithRetry` — 防重入；置 ServiceUp 态；performFetch
- `performFetch` — 调 TVNCGatewayClient.fetchDevicesWithCompletion；按结果判定 Registered/Disconnected/BridgeConnected（桥接模式可达即达，不重试）
- `retryIfNeeded` — MIN(startInterval * (1<<retryCount), maxInterval) 退避

#### 4.2.6 伪装页·位置模拟（TRDisguiseViewController + TRMapPickerViewController）

**TRDisguiseViewController** — M5 伪装页容器：segmented control 顶部切换子页（`addChildViewController` 挂载，`vc.view.frame = containerView.bounds`）；位置模拟子页 = TRMapPickerViewController。

**TRMapPickerViewController** — 地图位置模拟核心（Apple 地图 + 活跃订阅唯一驱动）：

- **锚点链编排**：`segments`（anchor/region 段）+ `segmentPoints` 段点序列缓存（锚点链唯一轨迹真相）——添加=新段标记待生成顺序补齐、删除=段缓存同步删+合并段（前驱→后继）标记待生成、拖拽=按起点/目标锚点邻接重排（邻接不变段保留旧点序列），只对标记段重算 MKDirections（`SimRouteCalculator.calculateRoutePointsFrom` 真实道路），**无全量重算**；删首分流（当前位置距新首锚 <25m 直接删，否则当前位置→新首锚重算段 0）；region 段目标锚点=区域中心；生长线按段缓存瞬画 + 按 segmentIndex 分色（5 色循环，段 0 深紫）
- **区域漫游**：region 段入链即置 `hasStart`（可从当前位置进入）；`RegionSimulator.generateRegionPlan`（K 途经点亚线性饱和 3~15/停留/速度因子）→ 进入段（出发锚点模式）+ 区域内逐途经点 MKDirections 拼接（<30m/失败忽略该途经点）；模式 walk/random（默认，walkRatio 平衡阀）/drive
- **定位开关**：anchor（当前位置驻留+微动）/ itinerary（轨迹逐秒推进）/ off；`startupLockedToAnchor`（开启瞬间忽略距锚点 >25m 的真实 fix 防"真实→锚点"横跳，注入落地解锁）；自动聚焦=距离阈值（`lastAutoFocusWGS` 基线，启动未初始化=(0,0)→首个 fix 聚焦，fix 距基线 ≥500m 才聚焦）；停止后再开启距真实 >500m 时 setRegion 瞬间跳回
- **播放**：`finishChainSync` 按段索引展平 → `writeTrackFile`（异步+串行队列写盘）→ daemon 轨迹文件 mtime 指纹重载 → 从当前注入位置 haversine 最近点续播；`_trackIndex` 单调推进逐点注入（正常播放 100% 顺序）
- **状态栏/列表**：速度=当前段缓存首点 speed（`departAnchor.segmentIndex+1`）；点击行聚焦该行程首锚点；删除走系统原生右滑；无锚点显示空白
- **FAB**：未开启=品牌紫+location.fill；定位中=渐变金底（CAGradientLayer，viewDidLayoutSubviews 同步 frame）+ 暗金描边 + 招财进宝四字（楷体深棕，上/右/下/左顺时针）+ mask 镂空方孔
- **daemon 链路**：SimLocationManager（CLSimulationManager 注入，每次 stop→clear→append→flush→start + 投递参数）/ SimLocationController（读 SimLocation* 参数驱动状态机，mobile 域优先 root 兜底）

#### 4.2.7 TVNCRootListController — 设置 Tab

**核心职责**：PSRootController 子类；加载 Root.plist 或 ManagedRoot.plist；restart 级配置变更防抖自动重启服务；自签 CA 证书生成/导出；网关 Bonjour 搜索；查看日志 / 重置默认。

**关键方法**：
- `specifiers` — 优先 ManagedRoot.plist（hasManagedConfiguration），否则 Root.plist
- `setPreferenceValue:specifier:` — 覆写；restart 级 key 变更时调 _scheduleAutoRestart；**2026-08-20 起所有写入后 `notify_post(TVNC_NOTIFY_PREFS_CHANGED)` 触发设置页热重载通道**（帧率/通知/缩放等即时生效）
- `_restartRequiredKeys` — BindHost/FullPassword/ViewOnlyPassword/TileSize/MaxRects/AsyncSwap/Scale/OrientationPadFix/BonjourEnabled/PerformanceMode（2026-08-20：Scale/OrientationPadFix 重建 framebuffer 改 restart 级；BonjourEnabled server 启动期标志改 restart 级；移除 ConnectionMode——协调器 3s 轮询自动生效、FrameRateSpec——热重载生效、Notifications——instant 级）
- `_managerRestartKeys` 已删除（2026-08-20 双通知自治：App kill root 恒 EPERM 通路废弃）——GatewayHost/GatewayToken 变更走 prefs-changed → noteExternalPrefsChanged 重发 register + worker host 比对断开重连；WatchdogThrottleInterval/WatchdogExitTimeout 由 manager 收通知热调即时生效；BonjourEnabled 归入 server restart 级
- `_scheduleAutoRestart` / `_autoRestartNow` — 400ms 防抖；校验 BindHost IPv4/IPv6 literal；TVNCRestartVNCService()（notify_post restart-service → manager watchdog 重启 trollvncserver）自动重启（2026-08-20 由确认弹窗改为自动重启，不再弹框打断）
- `connectGateway` — 双模式分派（2026-08-20 幂等 ensure 语义）：bridge 纯 App 级 fetchDevices 验证网关可达并反馈设备数（不碰进程）；relay 分支按构建上下文（`#ifdef THEBOOTSTRAP`）——App 走 ensureServiceRunning（manager 死则立即 spawn，活则交给 prefs-changed 自治）；prefs bundle 无 spawn root 能力退化为 fetchDevices 验证可达（与 bridge 分支同款反馈），均无 kill 重启
- `navigationController:willShowViewController:animated:` — 根页隐藏导航栏 / 子页显示
- `_reallyGenerateKeys` — 调 ZTSelfSignedCertificate.generateWithCommonName → 写 cacertPath/cakeyPath（0600）
- `viewLogs` — StripedTextTableViewController 打开 `<jbroot>/tmp/trollvnc-stderr.log`
- `searchGateway` / `presentFoundGateways` / `saveGateway:port:` — `_superphone-farm._tcp` Bonjour 搜索；1.5s 后弹选择 sheet；写 GatewayHost + GatewayPort=18081（端口固定忽略搜索值）

#### 4.2.8 TVNCClientListController — 客户端列表

**核心职责**：通过 5901 RFB 扩展消息（0x50 请求 / 0x80 响应）执行 `clients.list` / `clients.disconnect` / `clients.block` / `clients.unblock`；冻结/解冻持久化；**通知驱动即时刷新 + 5s 轮询兜底**（2026-08-23：监听 trollvncserver `clients-changed` darwin 通知即时刷新，轮询保留兜底）；右滑操作 + 长按菜单。

**关键方法**：
- `TVNCControlConnect()` — 静态；socket connect 127.0.0.1:5901 → RFB 3.8 握手 → 发 `cap.hello {mgmt:YES}` 标记管理客户端
- `TVNCControlInvoke(op, params)` — 静态；每次新建连接，封装 `{op, params}` JSON 发 0x50 帧，读 0x80 帧解析 JSON 响应
- `reloadDataFromServer` — 后台 TVNCControlInvoke(@"clients.list", nil) → 主线程 applyRows
- `freezeClientWithId:` / `unfreezeHost:` — 本地 frozenHosts 持久化 + RFB clients.block/clients.unblock

#### 4.2.9 其他 App 文件

- **TVNCHotspotManager**：NEHotspotHelper 注册（保活兜底）；任何 hotspot 命令回调时拉起 VNC 服务
- **TVNCListItemsController**：PSListItemsController 子类（仅设置主题色，用于 PSLinkListCell 子页）
- **TVNCClientCell**：客户端列表 cell（ID + Host + Subtitle + View-Only badge）
- **TVNCButtonCell**：自定义 PSTableCell（**frame 布局**：layoutSubviews 手动设置圆角背景 + 居中标题，不依赖 Auto Layout——2026-08-20 修复按钮消失：纯 UIView 无 intrinsic 在自动行高下塌缩为 0；行高由 Root.plist `height` 键明确指定（48）。**点击交系统** PSListController didSelect 触发 action；PSSpecifier **无** `target`/`action` getter，不可手动调）
- **TVNCSliderCell**：自定义 PSTableCell（自建标题 UILabel + UISlider + 右侧值标签；2026-08-20 重新启用——系统 PSSliderCell 在 iOS 15 上不显示标题；布局：标题压缩阻力 300 可截断、值标签 46pt/13pt、间距 8，让位滑杆）
- **TVNCSegmentCell**：自定义 PSTableCell（无标题，UISegmentedControl 占满整行；字符串值 ↔ 段索引双向转换；系统 PSSegmentCell 只认整数索引，2026-08-20 新增）
- **自定义 cell 布局约定（2026-08-20 修复重叠）**：标题用 contentView 自建 UILabel，隐藏系统 textLabel/detailTextLabel（detailTextLabel 会被 PSTableCell 设为当前值如 "full"）——iOS 15 的 UITableViewCell/PSTableCell 对系统 label 有内置约束，手动再加约束会双约束冲突 → Auto Layout 破坏性布局 → 标题与控件互相覆盖；自建视图约束与系统布局完全隔离，layoutSubviews 兜底隐藏系统 label。选择器行（TVNCSegmentCell）无标题、控件占满整行
- **StripedTextTableViewController**：通用文本日志查看器（dispatch_source VNODE 监听 + 反向 + maxRows + 搜索 + 分享 + 清空）
- **ZTSelfSignedCertificate**：调 Security.framework 私有 API `SecGenerateSelfSignedCertificate` 生成自签 CA 证书（RSA 2048 / CA:TRUE pathLen=0）
- **TRTask.m / TaskProcess+ObjC.swift**：进程 spawn 工具（posix_spawn + 私有 persona API 实现 root 身份切换）
- **TVNCUtil.h**：工具头文件（DeviceUUID 4 级回退读取 + 进程枚举 + VNC 服务重启）
- **Info.plist**：NSAllowsArbitraryLoads 兜底 ATS 豁免 + NSBonjourServices + UIApplicationSceneManifest + UIBackgroundModes=[network-authentication] + BGTaskSchedulerPermittedIdentifiers
- **TrollVNC.entitlements**：约 200+ 项（HID/进程/SpringBoard/HotspotHelper/persona/IOKit user-client class/keychain-access-groups/rootless）

---

### 4.3 偏好插件（prefs/）

#### 4.3.1 CCTrollVNC — 控制中心开关

**路径**：`TrollVNC/prefs/CCTrollVNC/`
**核心职责**：iOS 控制中心开关，启用/禁用 VNC 服务。
- `init` — 初始化 NSUserDefaults suite `com.82flex.trollvnc`，registerDefaults:@{Enabled:YES}
- `isSelected` / `setSelected:` — 读/写 Enabled key；setSelected: 内调 TVNCRestartVNCService() + notify_post(TVNC_NOTIFY_PREFS_CHANGED)
- `selectedColor` — RGB(35,158,171) 青色
- Makefile：`ARCHS = arm64 arm64e`、`INSTALL_TARGET_PROCESSES = SpringBoard`、`BUNDLE_EXTENSION = bundle`、`PRIVATE_FRAMEWORKS = ControlCenterUIKit`、`INSTALL_PATH = /Library/ControlCenter/Bundles`

#### 4.3.2 TrollVNCPrefs — Preferences.app 设置 bundle

**路径**：`TrollVNC/prefs/TrollVNCPrefs/`
**核心职责**：Preferences.app 加载的设置面板（独立安装到非 bootstrap 设备时使用，与 App 内嵌 TVNCRootListController 共享代码）。
- `TrollVNCPrefs_FILES` = 9 个 .m：TVNCClientCell / TVNCClientListController / TVNCListItemsController / TVNCRootListController / TVNCSegmentCell / TVNCSliderCell / StripedTextTableViewController / ZTSelfSignedCertificate / TVNCGatewayClient（2026-08-20 加：connectGateway 验证网关可达所需，纯 NSURLSession 服务类）
- `INSTALL_TARGET_PROCESSES = Preferences`、`PRIVATE_FRAMEWORKS = Preferences`、`INSTALL_PATH = /Library/PreferenceBundles`
- **共享方式（2026-08-20 校准）**：大部分源文件（RootListController/ClientListController/ClientCell/ListItemsController/SliderCell/StripedTextTable/ZTSelfSignedCertificate/TVNCUtil/TVNCGatewayClient/Control.h）是**指向 `../../app/TrollVNC/TrollVNC/` 的 git symlink（120000）**——编译期同源，App 改动 prefs 自动跟随；仅 TVNCButtonCell/TVNCSegmentCell（bundle 专属 UI 组件）与 Resources/Makefile 是实体分叉。**App-only 依赖须 `#ifdef THEBOOTSTRAP` 条件编译**（如 TVNCServiceCoordinator——prefs bundle 无 spawn root 能力），否则 symlink 断链编译失败（2026-08-20 踩坑：connectGateway 引入 GatewayClient/Coordinator 后 rootless scheme 编译 'TVNCGatewayClient.h' file not found）

**Resources/Root.plist 分组（2026-08-21 定稿）**：按能力板块分组 = **连接 / 直连 / 画面 / 交互 / 保活 / 关于**（6 组）+ 页面底部无分组（查看日志/UDID/版本信息）；连接/直连/画面/交互/保活仅中继模式显示（visibleOnlyRelay）
**关键配置项**（端口固定不出现）：ConnectionMode（网关中继/桥接控制）/ GatewayHost / GatewayToken /「连接网关」按钮（visibleOnlyRelay）/「桥接网关」按钮（visibleOnlyBridge）/ BindHost（直连地址，仅中继）/ FullPassword（被控密码，仅中继）/ generateKeys（生成证书，仅中继）/ ViewOnly（只读开关，仅中继）/ CaptureFps（采集帧率 1-30 默认 10，仅中继）/ FrameRateSpec（推流帧率 15/30/60/动态/自定义，自定义联动 FrameRateSpecCustom）/ OrientationSync（方向同步）/ OrientationPadFix（方向偏移）/ PerformanceMode（推流画质 流畅/智能/画质/自定义）/ Scale（输出缩放 0.25-1.0）/ 进阶（collapseGroup=performance：DeferWindowSec / MaxInflight）/ TileSize● / MaxRects● / FullscreenThresholdPercent / AsyncSwap●（仅自定义）/ NaturalScroll / WheelStepPx / AutoAssistEnabled / ModifierMap / KeyLogging / Notifications（通知模式 全部通知/仅连接/静默）/ KeepAliveSec（防息屏间隔 0-300 默认 30）/ HeartbeatIntervalSec（网关心跳间隔 5-300 默认 30）/ WatchdogThrottleInterval（重启节流默认 60）/ WatchdogExitTimeout（退出超时默认 3）/ resetDefaults（重置默认设置）/ restartService（重启服务）/ viewLogs（查看日志）/ DeviceUUID（UDID）/ appVersionText（版本信息）。**2026-08-21 移除**：AccessMode/ViewOnlyPassword/BonjourEnabled/searchGateway/FabAutoCollapse 设置页项（FabAutoCollapse 在 CONFIG_DEFS 保留 group:null）；显示名对齐：FullPassword→被控密码、BindHost→直连地址、KeepAliveSec→防息屏间隔；需重启项 label 带 ● 标记

---

### 4.4 构建系统（Makefile + devkit/）

#### 4.4.1 TrollVNC/Makefile

**关键变量**：
- `PACKAGE_VERSION := 0.0.1`
- `TARGET` 选择：模拟器 `simulator:clang:latest:15.0` / 真机无 scheme `iphone:clang:16.5:14.0` / 真机有 scheme `iphone:clang:16.5:15.0`
- `trollvncserver_FILES`（7 个核心源）：trollvncserver.mm / BulletinManager.mm / ClipboardManager.mm / ScreenCapturer.mm / STHIDEventGenerator.mm / OhMyJetsam.mm / TRScreenHasher.mm
- `trollvncserver_LIBRARIES`（真机）= crypto lzo2 turbojpeg png18 sasl2 ssl vncserver z；模拟器仅 vncserver z
- `trollvncserver_FRAMEWORKS` = Accelerate/CoreGraphics/CoreImage/CoreMedia/CoreVideo/Foundation/IOKit/IOSurface/QuartzCore/UIKit/UserNotifications；`PRIVATE_FRAMEWORKS = FrontBoardServices`
- `THEBOOTSTRAP=1` 时额外编译 `trollvncmanager`（含 trollvncmanager.mm / TRWatchDog.mm / TaskProcess+ObjC.swift / TRGatewayClient.mm / TRCapabilityRegistry.mm / TRTunnelClient.mm 等）
- `SUBPROJECTS = prefs/TrollVNCPrefs prefs/CCTrollVNC`；`THEBOOTSTRAP=1` 时 `+= app/TrollVNC`

#### 4.4.2 devkit/ 脚本

| 脚本 | THEOS_PACKAGE_SCHEME | THEBOOTSTRAP | 输出 | 安装方式 |
|------|------|------|------|---------|
| `bootstrap.sh` | `roothide` | `1` | `.tipa` | TrollStore |
| `default.sh` | ``（空） | ``（空） | `.deb` | 经典 rootfs 越狱 |
| `rootless.sh` | `rootless` | ``（空） | `.deb` | rootless（/var/jb） |
| `roothide.sh` | `roothide` | ``（空） | `.deb` | roothide（隐藏 root） |

共同配置：`THEOS_DEVICE_IP=127.0.0.1`、`THEOS_DEVICE_PORT=58422`、`THEOS_DEVICE_SIMULATOR=`（真机模式）

**before-package.sh**：
- rootless scheme：PlistBuddy 改 LaunchDaemon plist 的 ProgramArguments:0 为 `/var/jb/usr/bin/trollvncserver`
- bootstrap scheme：写 CFBundleVersion（git rev-list --count HEAD）+ CFBundleShortVersionString；cp trollvncserver/trollvncmanager/TrollVNCPrefs.bundle/webclients → `.app/`；ldid 伪签名

**after-package.sh**：
- bootstrap scheme：cd $THEOS_STAGING_DIR → mv Applications Payload → zip -yqr TrollVNC.tipa Payload → mv 到 packages/TrollVNC_${PACKAGE_VERSION}.tipa

**build-all.sh**：本地一键编译 4 scheme（依次 source 各 scheme.sh 后 `FINALPACKAGE=1 gmake clean package`），`set -e` 任一失败立即中止

**gen-managed-plist.sh**：根据环境变量生成 Managed.plist（MDM 预置配置）；`add_bool/add_str/add_int/add_real` 函数；写头 → 顺序 add_* → 写尾 → plutil 校验；端口固定不生成

**simulator.sh / sim-root.sh / sim-spawn.sh**：iOS 模拟器开发辅助三件套（仅 dev 调试，非 CI 流程）

#### 4.4.3 .github/workflows/build.yml

**触发**：`push.branches=[main]` + `workflow_dispatch`（inputs: is_managed / desktop_name / port / view_only / scale / frame_rate_spec / modifier_map）

**步骤**：
1. 依赖安装：`brew install xcbeautify ldid-procursus p7zip make`
2. Checkout roothide/theos（submodules）→ `theos-roothide/`
3. Install iOS SDKs：`./bin/install-sdk iPhoneOS16.5` + `iPhoneOS14.5`
4. Setup Xcode 16.2
5. Generate Managed.plist（仅 `workflow_dispatch && inputs.is_managed == true`）
6. Build matrix：`source devkit/${scheme}.sh` + `FINALPACKAGE=1 gmake clean package`（scheme = default/rootless/roothide/bootstrap）
7. Diagnose bootstrap failure（failure() && scheme == 'bootstrap'）
8. Prepare artifacts：`artifacts/dsym-${scheme}` + `artifacts/packages-${scheme}`
9. Upload artifacts
10. Release（仅 push main）：读取 Makefile PACKAGE_VERSION → TAG_NAME=v${VERSION} → softprops/action-gh-release 上传 release-packages + body=TrollVNC/CHANGELOG.md

所有 run 步骤 `working-directory: TrollVNC`

---

## 5. 网关模块（trollvnc-farm/）

### 5.1 服务端（server/index.js）

**文件**：`trollvnc-farm/server/index.js`（1567 行，单入口）

**核心职责**：在一个 Node 进程内同时承担 REST API、静态资源服务、WebSocket↔VNC 桥接、mDNS 发现、TCP 存活探测、注册通道（TCP JSON 行）、隧道通道（TCP 帧协议）、广播群控、TLS 自签证书与同端口协议自适应。还内置对 noVNC `rfb.js` / `gesturehandler.js` 的内存 patch（不修改 node_modules）。

#### 5.1.1 HTTP 路由清单

API 全部前缀 `/api`，统一走 `authOk`（Bearer Token 或 `?token=`，无 Token 时 LAN 直通）。

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/api/state` | 网关自描述：`{name, version:'0.0.1', deviceCount, uptime}` |
| GET | `/api/devices` | 设备列表（sortDevices 按 order 升序在前、addedAt 在后、id 字典序兜底） |
| POST | `/api/devices` | 手动添加设备（host/port 校验、source='manual'、随后 probeDevice） |
| GET | `/api/devices/:id` | 单设备详情 |
| DELETE | `/api/devices/:id` | 删除设备记录 |
| PATCH | `/api/devices/:id` | 改名/分组/备注/host/port/order（order 0-99999 整数，null/空=清除） |
| GET | `/api/devices/:id/caps` | 仅返回 configs（能力 schema 不再上报） |
| GET | `/api/devices/:id/configs` | 当前配置值 |
| POST | `/api/devices/:id/configs` | 批量 set：逐键 sendDeviceCmd({cmd:'set',key,value}) |
| POST | `/api/devices/:id/invoke` | 调用能力（cap + params，超时 500-15000ms） |
| POST | `/api/devices/:id/restart` | 重启服务（超时 15s） |
| POST | `/api/devices/:id/ping` | TCP 探活（不走命令通道） |
| POST | `/api/devices/batch/invoke` | 批量调用（deviceIds + cap + params） |
| POST | `/api/devices/batch/configs` | 批量设置配置 |
| POST | `/api/devices/batch/restart` | 批量重启（15s） |

> **关键顺序约束**：`/api/devices/batch/*` 分支必须先于 `:id` 单设备分支，否则 `id='batch'` 会被 findDevice 当成设备 ID 返回 404

非 API 路由（静态资源，不鉴权）：`/` → index.html；`/novnc/*` → noVNC 资源（core/rfb.js 与 core/input/gesturehandler.js 走内存 patch）；`/web/*` 与其余路径 → web/ 目录

#### 5.1.2 WebSocket 端点

`wss` 用 `path: undefined` 接管全部 WS 连接，按 pathname 手工分发；无 Token 或 token 不符直接 `ws.close(4001,'unauthorized')`。

| 路径正则 | 参数 | 处理函数 |
|---|---|---|
| `^/ws/vnc/([^/]+)$` | `grp`、`broadcast=1`、`ctrl=1` | `handleVncSocket` |
| `^/ws/control/([^/]+)$` | — | `handleControlSocket`（AI 工具 JSON 行控制端点） |
| 其它 | — | `ws.close(4000,'unknown ws path')`（WS 注册端点已废弃） |

#### 5.1.3 隧道帧协议与处理（proto:2 通道复用）

帧格式：`1B type + 4B 大端 length + payload`（writeTunnelFrame 实现，5B 头 + 可选 payload）

| 常量 | 值 | 方向 | 作用 |
|---|---|---|---|
| `FT_PING` | 0x02 | 设备→网关 | 心跳请求，网关立即回 FT_PONG |
| `FT_PONG` | 0x03 | 网关→设备 | 心跳响应 |
| `FT_CMD` | 0x04 | 网关→设备 | 命令 JSON（`{type:'cmd',cmd,id,ts,...}`） |
| `FT_CMDACK` | 0x05 | 设备→网关 | 命令 ack JSON |
| `FT_STATE` | 0x07 | 设备→网关 | 被控状态上报（`{controlled,source}`） |
| `FT_CHAN_OPEN` | 0x08 | 网关→设备 | 通道建立（`[chanId:2BE][kind:1B]`，kind 0=thumb 1=session） |
| `FT_CHAN_ACK` | 0x09 | 设备→网关 | 通道建立确认（`[chanId:2BE][ok:1B]`） |
| `FT_CHAN_DATA` | 0x0A | 双向 | 通道 RFB 数据（`[chanId:2BE][rfb字节]`） |
| `FT_CHAN_CLOSE` | 0x0B | 双向 | 通道关闭（`[chanId:2BE][reason:1B]`，0=正常 1=对端EOF 2=错误） |

`feedFrame` 解析器：frameBuf 累积，每帧读 5B 头取 type+len，`len>16MB` 直接 sock.destroy() 防内存炸；不完整帧等下次 chunk

`handleFrame` 分支：
- `FT_CHAN_DATA`：按 chanId 分发——chan 0 喂 `rec.thumbRfb.feed` 解码（Raw 编码 → JPEG，onJpeg 广播 thumb 事件）；其余按 `rec.channels.get(chanId)` 找到会话 WS 直发（无订阅者即丢弃，通道隔离）
- `FT_CHAN_ACK`：chan 0 → 创建 ThumbRfbDecoder（onSend 封装 chan 0 下行，有会话则 pause）；会话通道 → `ch.ready=true` 放行缓冲握手字节（releaseChPendingUp 跳过 12B 重复协议版本），ack fail → `ch.ws.close(4005,'device RFB unavailable')`
- `FT_CHAN_CLOSE`：chan 0 → 丢弃解码器 + 2s 退避重开（scheduleThumbOpen）；会话通道 → 删通道 + `ch.ws.close(4006,'device rfb eof')` + 会话归零时 resumeThumb
- `FT_CMDACK`：按 ack.id 匹配 pendingCmds 解析 Promise
- `FT_PING`：回 PONG；`FT_PONG`：仅作存活证明

#### 5.1.4 sendDeviceCmd 逻辑

`sendDeviceCmd(deviceId, cmdObj, timeoutMs=5000)`：
1. 生成 `cid = 'c' + Date.now().toString(36) + 随机`，组装 payload `{type:'cmd', id:cid, ts, ...cmdObj}`
2. **优先隧道**：若 tunnels.get(deviceId) 存活且可写，writeTunnelFrame(tun.sock, FT_CMD, ...)
3. **回退注册通道**：隧道不可用时 sendToDevice(deviceId, payload)（往注册 socket 写 JSON + '\n'）
4. 挂起 pendingCmds.set(cid, {resolve, timer, cmd, deviceId})，超时清理并 resolve(null)

#### 5.1.5 会话通道（4001/4002/4003/4005，proto:2 通道化）

`handleVncSocket(ws, req, deviceId, grp, isBroadcast, isCtrl)`：

| 关闭码 | 触发条件 |
|---|---|
| 4004 | findDevice(deviceId) 找不到设备 |
| 4003 | 隧道不存在（tunnels.get 为空/sock 已毁/不可写）—— 禁止直连回退 |
| 4001 | 新 ctrl 顶掉旧 ctrl（业务层唯一控制者；viewOnly 与任何会话并存，不再被顶） |
| 4002 | 隧道关闭时一并关闭其 channels 内全部会话 WS |
| 4005 | CHAN_ACK 失败（设备 5901 不可用），关闭对应会话 |
| 4006 | 设备端 5901 EOF 回 CHAN_CLOSE，关闭对应会话 |

**核心约束（proto:2 通道化，2026-08-23）**：
- 每个 WS 会话分配独立通道（`tun.nextChan++`），发 CHAN_OPEN(chanId, session)；设备端各 connect 一条 5901（LibVNCServer 原生多客户端），无连接轮换、无 rfb.start/stop、无「首会话重建」语义
- ACK 前上行字节缓冲到通道 `ch.pendingUp`（64KB 滚动），收到 CHAN_ACK ok 才放行（releaseChPendingUp 跳过 12B 重复协议版本）；3s 兜底超时强制放行；ack fail 则 `ch.ws.close(4005)`
- 缩略图暂停/恢复：会话通道存在期间 `tun.thumbRfb.pause()`（不发增量请求，连接保留零流量）；会话通道归零 `resumeThumb()`（补发增量请求即恢复）
- cleanup() 幂等（`if (!tun.channels.has(chanId)) return`），通道删除后向设备发 CHAN_CLOSE；设备 EOF 路径先删通道再关 WS

#### 5.1.6 关键函数清单

| 函数 | 作用 |
|---|---|
| `loadDb/saveDb` | 设备库读写，saveDb 300ms 防抖落盘 data/devices.json；loadDb 对 source=register 设备初始 online=false（2026-08-20：在线只能由活跃注册驱动，不继承 db 残留状态） |
| `upsertRegistered` | 注册设备按 deviceId 键去重；manual/mdns 同 host:port 合并到 deviceId；保留 addedAt；剥离 capabilities/capMetadata/configSchema |
| `sortDevices` | order 升序在前 → addedAt 升序在后 → id 字典序兜底，稳定排序 |
| `writeTunnelFrame` | 写 5B 头帧（1B type + 4B BE length + payload） |
| `sendDeviceCmd` | 命令下发 + 等 ack（隧道优先，注册通道回退，5s/15s 超时） |
| `chanPayload/chanDataPayload` | 通道帧 payload 构造（[chanId:2BE] + kind/reason/rfb字节） |
| `pauseThumb/resumeThumb/hasSessionChannels` | 缩略图暂停/恢复与会话通道存在判定 |
| `releaseChPendingUp` | ACK 放行缓冲握手字节（跳过 12B 重复协议版本） |
| `scheduleThumbOpen` | chan 0 EOF/ACK 失败后 2s 退避重开 |
| `handleVncSocket` | WS↔VNC 桥接 + 会话通道生命周期管理 |
| `handleControlSocket` | AI 工具 WS 控制端点（JSON 行 cmd→ack 透传） |
| `handleApi` | REST API 路由分发（含 batch 分支优先级） |
| `GET /api/devices/:id/thumb` | 缩略图读回（2026-08-22 统一到 RFB）：`trec.thumbRfb.jpeg` 有值 → 200 `{thumb: base64, ts}`；无 → 204；设备不存在 → 404 |
| `notifyDevicesChanged` | 设备变更事件广播（/ws/events），type ∈ register/offline/delete/update/thumb（2026-08-21 新增 thumb） |
| `loadTlsOptions` | TLS 证书加载，缺失时 spawnSync 调 scripts/gen-cert.mjs 自动生成 |
| `bootstrap`（同端口协议自适应） | 首字节 0x16 0x03 → TLS server，否则 → httpRedirect 301；pause→unshift→emit→nextTick(resume) 交接 |

#### 5.1.7 关键数据结构

```js
// 设备记录（持久化到 data/devices.json）
dev = {
  id, name, host, port,
  source: 'manual' | 'mdns' | 'register',
  group, note, order: number|null,  // 0-99999 整数
  online: boolean|null, lastSeen: number|null, addedAt: number,
  configs?: object, screen?: {width,height}, httpPort?: number
}

// 隧道记录（tunnels.get(deviceId)，proto:2 通道复用）
tun = {
  sock,                  // 隧道 TCP socket
  channels: Map<chanId, {id, kind, ws, ready, pendingUp, timer}>, // 通道表（chan 0 缩略图 + 会话通道）
  nextChan: 1,           // 会话通道号分配器（0 固定缩略图）
  controller: ws|null,   // 唯一控制者（业务层）
  thumbRfb: ThumbRfbDecoder|null,  // 缩略图通道解码器（Raw→JPEG，2026-08-22）
  thumbRetryTimer,       // chan 0 EOF/失败重开定时器（2s）
  controlled: boolean,             // 被控状态（2026-08-22）
  controlledSource: '5801'|'tunnel'|null, // 被控来源（2026-08-22：5801 直连 / 隧道会话通道）
}

// 命令挂起表（pendingCmds.get(cid)）
{ resolve, timer, cmd, deviceId }

// 注册设备（registeredDevices.get(deviceId)）
{ sock, lastHeartbeat }
```

#### 5.1.8 依赖关系

- `bonjour-service`：mDNS `_rfb._tcp` 发现 + 发布 `_superphone-farm._tcp`（REG_PORT）；`FARM_MDNS=0` 可关
- `ws`：WebSocketServer（挂在 server 上，path undefined）
- `@novnc/novnc`：静态资源 + 内存 patch（core/rfb.js 与 core/input/gesturehandler.js）
- `net`：注册/隧道两个 net.createServer + 同端口协议自适应 bootstrap
- `https`/`http`/`fs`/`path`/`child_process.spawnSync`（调 gen-cert.mjs）

---

### 5.2 前端（web/）

#### 5.2.1 web/app.js — 前端主逻辑

**文件**：`trollvnc-farm/web/app.js`（2804 行）

**核心职责**：浏览器/WKWebView 单页应用，承担卡片墙渲染、聚焦大屏控制、操作列与移动端 FAB、布局切换、批量操作、直控模式、同步控制、剪贴板显式双向搬运、iOS 软键盘双通道输入、容器模式（?container=ipa）。

**关键函数**：

| 函数 | 作用 |
|---|---|
| `refreshDevices` | 拉 /api/devices，过滤 SELF_ID，注入 MOCK_DEVICES，按签名变化重算卡片比例；由 /ws/events 推送驱动（2026-08-18），轮询已移除（2026-08-19） |
| `connectEventsWS` | 订阅 /ws/events 设备变更推送：收到事件重拉 refreshDevices；断线退避重连（2s 起，上限 30s）；死连接检测由后端心跳 ping/pong 负责（2026-08-19） |
| `startWallRfb` | 卡片墙缩略图获取（2026-08-22 起事件驱动）：每张卡片建 `{kind:'thumb'}` 实例并 fetchThumb 拉一次；画面更新由 /ws/events 的 thumb 事件广播 + 设备列表刷新兜底驱动；前端无轮询定时器、无 RFB 连接（缩略图 RFB 流由网关侧 thumbRfb 维护） |
| `fetchThumb` | GET /api/devices/:id/thumb → 200 `{thumb: base64, ts}` 更新卡片 `<img class="thumb">` 并记录 data-ts；204/404 跳过；离线/聚焦/直控/同步卡片跳过（fetchThumb 内部判断） |
| `createWallTile` | 创建卡片 DOM（含批量复选框、⋯ 菜单）；点击卡片进入聚焦/同步/批量不同分支 |
| `enterFocus` / `exitFocus` | 聚焦大屏进出：URL ?focus= 持久化、IPA setTabBarHidden 桥接、createRfb(grp+broadcast+ctrl)、断线重连 |
| `createRfb` | noVNC RFB 工厂：scaleViewport、transparent 背景、viewOnly/触屏不显示任何光标（_refreshCursor=clear 屏蔽服务器光标）、PC 聚焦/直控常驻自绘深灰圆+浅灰外圈覆盖层（pcRgba）、attachFarmGesture 挂多点手势、disconnect 码 4001/4003/4005 分别提示 |
| `initTouchKeyboard` | iOS 软键盘双通道：compositionend 整段提交（type.paste）/ input 删除键（Backspace 直发）/ input 单 ASCII（kbdSendAscii 键值直发）/ keydown Enter |
| `kbdSendAscii` | Shift 状态跟踪（连续大写保持按下、切小写才抬起、空闲 400ms 自动释放）+ 基础字符 ↓50ms↑ |
| `toggleSync` / `toggleDirectMode` | 同步控制（grp viewOnly 订阅 + 广播接收）/ 直控模式（所有在线真实设备 ctrl=false 可输入连接，互不抢占；进入直控先 exitFocus + 布局重置 grid，2026-08-19） |
| `showBatchMenu` / `showBatchConfigPanel` | 批量执行菜单（纯按钮列表对齐 opsMenu：按键复用 attachPress 按压识别同右侧按键——批量态补声明 BATCH_CAPS 多击能力如 home.double，电源/截图键不入菜单，+ service.restart 重启；releasekeys/hwlock/hwunlock/批量重启已去除）+ 批量配置面板（**按 reload 策略分区：即时生效/热重载/网关设置/需重启生效（警示色），2026-08-19**）；执行候选仅限在线设备；菜单锚定「执行」按钮向下展开、「执行」点一次展开再点收起、点外部仅关菜单（closeBatchMenu 不退批量模式——胶囊行仅顶部「取消」收起） |
| `scheduleFocusReconnect` / `reconnectFocusRfb` | 聚焦画面断线重连（首立即、后续 2s 间隔，上限 8 次；1000/1001/4001 不重连；visibilitychange 回前台触发） |

**关键模式**：
- **卡片墙缩略图事件驱动（2026-08-22 统一到 RFB + 2026-08-23 proto:2）**：设备 5901 经隧道 CHAN_DATA(0)（chan 0 缩略图通道）发 RFB Raw 流 → 网关 ThumbRfbDecoder 解码产 JPEG → 广播 `{type:'thumb', deviceId}` → 前端收到后补拉该设备缩略图（fetchThumb，不触发全量刷新）；screen.hash/screenshot 轮询门控已移除
- **聚焦抢占语义**：主控连接始终带 grp+broadcast，勾选同步设备无需重建主控；新 ctrl 顶旧 ctrl 由网关 4001 处理
- **剪贴板显式双向搬运**（2026-08-17 决策）：
  - 复制 = 拉：copyFromFocusedDevice → invokeCap('','id','clipboard.get') → farmWriteClipboardToControl（IPA 走原生桥 writeClipboard，浏览器走 navigator.clipboard.writeText 降级 execCommand('copy')）
  - 粘贴 = 推：pasteToFocusedDevice / Ctrl+V 拦截 → https 下 readClipboardText 直读 → submitPasteText → invokeCap('','id','type.paste',{text})；**http 下（PC/触屏统一，2026-08-18）一律弹输入浮层 showPasteFallbackModal**，浮层内 paste 事件（clipboardData 不要求安全上下文）或回车 → submitPasteText 自动注入并关闭；已废弃隐藏 textarea「第二次 Ctrl+V」方案（ensureFarmClipText 已删）
- **容器模式**（?container=ipa + ?selfId=）：过滤自身卡片；document.body.dataset.container='ipa'；进入聚焦发 farmBridge.postMessage({type:'setTabBarHidden',hidden:true})，退出恢复

**关键数据结构**：
```js
// 墙卡片实例（wallInstances.get(deviceId)）
inst = { device, tile, statusEl, paused, rfb, checkbox }
// rfb 实为缩略图获取状态标记：{kind:'thumb', closed, fetching}（2026-08-21 起无轮询定时器）
//   或 {kind:'mock', closed}（虚拟预览设备）

// 聚焦状态
focus = { device, rfb } | null

// 批量与同步
selectedDevices: Set<string>
syncRfbs: Map<deviceId, RFB>           // 同步 grp viewOnly 订阅
directRfbs: Map<deviceId, RFB>         // 直控 ctrl=false 连接

// Shift 键状态机（kbdSendAscii）
kbdShiftHeld, kbdShiftTimer, kbdComposing, kbdJustComposed, kbdLastLen
```

#### 5.2.2 web/caps.js — 前端契约唯一真相源

**文件**：`trollvnc-farm/web/caps.js`（212 行）

**核心职责**：自包含定义按键/批量能力/手势/配置表单契约，封装网关 invoke/configs API。原则：无上报、无元数据表、无运行时发现；新增能力 = 设备端注册 executor + 此处加一条。

**定义数组清单**：

| 常量 | 数量 | 用途 | 传输通道 |
|---|---|---|---|
| `KEY_DEFS` | 10 | 右侧按键直发（power/home/volup/mute/voldn/briup/bridn/snapshot/spotlight/keyboard） | RFB 直发（ks keysym / code DOM code / ptr 指针掩码）；每项 events:{click,long} 或 {click,down,up}（双击/三击=自然连点，显式 double/triple 走 BATCH_CAPS） |
| `BATCH_CAPS` | 20 | 批量调用菜单（17 hid + service.restart + settings.generateKeys + settings.searchGateway） | invoke API；按 category 分组（hid/service/native） |
| `GESTURE_DEFS` | 3 | 画布多点手势（pinch→touch.pinch / twotap→touch.twoFingerTap / threetap→touch.threeFingerTap） | invoke API（坐标 0-1 归一化） |
| `CONFIG_DEFS` | **33 项** | 配置表单契约（2026-08-22 统一到 RFB：+CaptureFps/HeartbeatIntervalSec、-ThumbPushEnabled/ThumbInterval/BonjourEnabled/ViewOnlyPassword UI；按能力板块 group 分组 connection/direct/display/interaction/keepalive/about/locsim，null=UI 隐藏；**2026-08-23 +5 SimLocation*（group:locsim，定位模拟自治参数）**） | set API；每项含 reload: hot/restart/instant/gateway |
| `CONFIG_BY_KEY` | Map | 按 key 索引 schema | — |
| `CATEGORY_LABELS` | 8 类 | 批量菜单分组标题 | hid/touch/stylus/system/native/service/gateway/control |

**API 封装函数**：

| 函数 | 路径 | 作用 |
|---|---|---|
| `invokeCap(apiBase, deviceId, capId, params)` | POST /api/devices/:id/invoke | 单设备能力调用 |
| `setConfigs(apiBase, deviceId, configs)` | POST /api/devices/:id/configs | 单设备配置设置 |
| `batchInvoke(apiBase, deviceIds, capId, params)` | POST /api/devices/batch/invoke | 批量调用 |
| `batchSetConfigs(apiBase, deviceIds, configs)` | POST /api/devices/batch/configs | 批量配置 |
| `batchRestart(apiBase, deviceIds)` | POST /api/devices/batch/restart | 批量重启 |
| `groupByCategory(caps)` | — | 按 category 字段分组（Map，保持插入顺序） |

所有封装统一注入 `window._farmAuthHeader`（Bearer Token），失败抛 Error(await res.text())

**分叉约束**：与 `TrollVNC/layout/usr/share/trollvnc/webclients/caps.js`（5801 直连页）是**分叉的两个文件**，互不引用

#### 5.2.3 web/press.js — 按压语义识别

**文件**：`trollvnc-farm/web/press.js`（76 行）

**核心职责**：把 keyDef.events 声明的按压模式（click/double/triple/long/down/up）翻译为能力 id 调用。常量 `DOUBLE_MS=300`、`LONG_MS=800`。

**attachPress(element, keyDef, opts) 时序**：
- `pointerdown`：fire('down')（按下立即触发）；若声明 long，启动 LONG_MS 长按定时器
- `pointerup`：fire('up')；若已 long 不再算 click；pressCount++；
  - 有 double/triple：开 DOUBLE_MS 多击窗口，超时后分级判定（≥3 triple / ≥2 double / 否则 click）
  - 仅 down（按压式按键：音量/亮度/静音）：**不补 click**，避免一次短按触发 down+up+click 三次注入导致设备端双响应
  - 无多击无 down：立即 fire('click')，零延迟
- `pointercancel`：复位按压状态（触摸被系统打断）
- 返回卸载函数，清理定时器与监听

#### 5.2.4 web/gesture.js — 画布多点手势识别

**文件**：`trollvnc-farm/web/gesture.js`（78 行）

**核心职责**：消费 server patch 的 rfb.js 在 pinch/twotap/threetap 手势上派发的 `farmgesture` CustomEvent，译为 `{cap, params}` 调用 touch.* 能力。

**关键函数**：

| 函数 | 作用 |
|---|---|
| `normalizePoint(x, y, rect)` | 画布视口坐标 → 0-1 归一化（钳制画布内兜底）；无 rect 回退 (0.5, 0.5) |
| `resolveGesture(detail)` | 纯函数：pinch（scale 钳制 [0.5,2.0]，≈1 跳过返回 null）→ touch.pinch{x,y,scale,angle,duration=0.6}；twotap → touch.twoFingerTap{x,y}；threetap → touch.threeFingerTap{x,y}；未知 → null |
| `attachFarmGesture(canvas, opts)` | 在画布挂 farmgesture 监听；opts.shouldRun 门控（仅聚焦可操控会话响应）；opts.invoke(cap, params) 调用 |

#### 5.2.5 web/index.html / web/style.css

**HTML 结构**：
```
header
  #meta 设备统计（无 h1 标题，2026-08-19 移除）
  .actions: directBtn
            batchBtn
            layoutBtn + layoutMenu（宫格/列表两档，PC/移动端共用、最右侧；调节阀 #cardwRange 在菜单内
            宫格选项下方，仅宫格态显示——2026-08-19）
批量操作（顶部入口，2026-08-19）：#batchBtn.batch-bar（顶部「批量」，直控右侧；批量模式变「取消」激活态承担退出）
            点击后屏幕墙顶部出现全宽圆角胶囊 #batchBar（main 首子级 in-flow，无取消按钮）：
            [✓ 全选][已选 N 台] ...... [执行][设置]，执行弹 #batchMenu（锚定执行按钮向下展开）、设置弹配置面板
main
  #workspace
    #focusPanel: .focus-head(状态点+标题) + #focusScreen>#focusStage + #focusStatusOv(连接浮层)
    #focusOps: #focusOpsCap + btnSync(同步) + data-op=full(全屏) + data-op=disc(断开)
    #wall: 卡片墙容器
  #empty（无设备占位）
  #fab（移动端 WiFi 信号悬浮按钮，可拖动）
  #opsMenu（移动端悬浮操作菜单）
#kbdInput（fixed 全屏透明 input，iOS 软键盘输入源）
#editModal（order 排序号 + name）/ #tileMenu（编辑/删除/旋转）
script app.js?v=170（type=module）
```

**关键设计**：
- viewport 禁缩放 + viewport-fit=cover 适配刘海
- #kbdInput 必须可视视口内（left:-9999px iOS 不弹键盘），故 fixed 全屏透明层，pointer-events:none 不挡画布
- 引用 `?v=N` 缓存破坏：app.js?v=170、style.css?v=33；caps.js?v=9、rfb.js?v=2 版本号在 app.js 的 ESM import 处（gesture/press 逻辑无版本号，静态文件 no-cache 覆盖）

**CSS 关键约定**：
- CSS 变量：`--bg/--panel/--panel2/--line/--text/--muted/--accent/--ok/--bad` + `--safe-top/right/bottom/left`
- `@media (prefers-color-scheme: light)` 整套浅色模式覆盖
- body：user-select:none + -webkit-touch-callout:none 禁 iOS 长按系统菜单
- `.focus-stage canvas` 用 `position:absolute !important; left/top:50%; transform:translate(-50%,-50%) !important` 绝对居中（解决 WKWebView 首帧布局漂移）
- 移动端 @media (max-width:900px)：聚焦全屏、布局按钮可见、卡片 2 列、FAB 显示

---

### 5.3 测试套件（test/）

所有端到端套件共享模式：随机端口隔离（FARM_PORT/REG_PORT/TUNNEL_PORT + FARM_DATA_DIR 临时目录 + FARM_TLS=0 + FARM_HOST=127.0.0.1，order-test 额外 FARM_MDNS=0）、spawn 网关子进程、waitFor 轮询就绪、check(name,cond) 断言、finally 杀子进程 + 清临时目录。

**npm test 串行 11 个套件**（package.json 实际配置，2026-08-21 新增 tunnel-thumb-test）：

| # | 文件 | 测什么 |
|---|---|---|
| 1 | `smoke.js` | 冒烟：启动 FakeVncServer、POST /api/devices 返回 201、无 token 返回 401、GET 列表包含设备、无隧道 WS 被拒 4003 |
| 2 | `tunnel-test.js` | 隧道通道复用（proto:2）：FakeDevice（register + openTunnel 握手 proto:2 + 帧解析 + CHAN_OPEN 自动 ack）；viewOnly 会话收 CHAN_OPEN + 收到 CHAN_DATA；viewOnly 上行→CHAN_DATA；ctrl 输入→CHAN_DATA；新 ctrl 顶掉旧 ctrl（4001）；broadcast 输入→目标设备会话通道 |
| 3 | `register-test.js` | P0 注册/心跳/命令：WS /ws/register 已废弃（4000）；TCP 注册带 manifest，能力字段被网关剥离不入库；invoke ack 往返；不 ack 设备 invoke→504；configs set ack；断开→离线→离线 invoke 504；TCP hello 保活；batch 端点可达 |
| 4 | `dedupe-test.js` | 去重/身份合并：同 deviceId 重复注册仍 1 条、旧连接被关；manual+register 同 host:port 合并为 deviceId；已注册设备不被 manual 降级 |
| 5 | `caps-test.js` | caps.js 自包含定义契约：BATCH_CAPS=22（2026-08-25 +data.fill/data.clear）且每项含 id/title/icon/category/params、含 service.restart；CONFIG_DEFS=33（2026-08-23 定位 +5 SimLocation*，七板块 group 均非空、仅 FabAutoCollapse 为 null、不含 BonjourEnabled/ViewOnlyPassword）且不含 Port$ 项且每项含 reload；KEY_DEFS=10；groupByCategory=3 组；GESTURE_DEFS=3 |
| 6 | `gesture-test.js` | gesture.js 契约：GESTURE_DEFS 与 resolveGesture 三态覆盖一致；normalizePoint 中心/越界钳制/无 rect 兜底；pinch scale>1/<1/钳制 [0.5,2.0]/≈1 跳过 null；未知类型 null |
| 7 | `pending-replay-test.js` | 回归（proto:2 通道隔离）：会话 A 建立收 CHAN_OPEN + 画面帧；A 关闭网关下发 CHAN_CLOSE；设备推旧通道残留帧 → 按 chanId 分发无订阅者丢弃；重进会话 B 新通道号 ≠ A；会话 B 600ms 窗口内不得收到旧残留数据 |
| 8 | `press-test.js` | press.js 时序：volup 按下 down、抬起 up、不补 click；home 双击→home.double；单击窗口超时→click；按住 900ms→home.long；power 三击→power.triple |
| 9 | `order-test.js` | 卡片墙 order 排序：注册 a/b/c 初始按 addedAt；PATCH b=1/a=3 → [b,a,c]；相同 order 按 id 字典序兜底；清除 order（null）回到注册时间段；order=-1/100000 拒绝 400 |
| 10 | `events-test.js` | 设备变更推送（2026-08-18）：/ws/events 订阅后设备 register 上线收到 register 事件；DELETE 删除收到 delete 事件；事件为 {type,deviceId,ts} 轻量通知；非 /ws/events 连接不进入订阅集合；心跳 ping→pong（2026-08-19） |
| 11 | `tunnel-thumb-test.js` | 缩略图 RFB 流（2026-08-22 统一到 RFB + 2026-08-23 proto:2）：隧道握手后网关开 chan 0 → 假设备回 CHAN_ACK → 经 CHAN_DATA(0) 发 RFB Raw 流 → 网关 ThumbRfbDecoder 解码 → GET /api/devices/:id/thumb 读回 base64（200）；无缩略图 204；无隧道设备 204；未知设备 404 |

**辅助文件**（不属于 npm test）：
- `fake-rfb-server.js`：smoke 用的假 VNC echo server
- `_tmp-*.mjs` / `verify-*.mjs` / `run-fake-server.mjs` / `rfb-handshake-diag.js` / `dump-root-plist.py`：手工验收/复现/诊断脚本

---

### 5.4 部署（Dockerfile / deploy/）

#### 5.4.1 Dockerfile

```dockerfile
FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY server ./server
COPY web ./web
ENV NODE_ENV=production
ENV FARM_PORT=8080
EXPOSE 8080
CMD ["node", "server/index.js"]
```

要点：Node 22 Alpine、npm ci --omit=dev、仅 COPY server+web（不含 test/scripts/deploy）、默认 FARM_PORT=8080

#### 5.4.2 docker-compose.yml

要点：
- `network_mode: host`（必须，否则容器内 mDNS 发现与访问局域网手机 VNC 端口都失效）
- 环境变量：`FARM_PORT=8080`、`FARM_TOKEN=change-me-please`（部署必须改）、`FARM_PROBE_INTERVAL=15000`、`FARM_REG_PORT=18081`
- 卷 `./data:/app/data` 持久化设备列表
- `restart: unless-stopped`
- 未声明 FARM_TUNNEL_PORT（使用默认 18181）

#### 5.4.3 deploy 文档

| 维度 | Docker 方式 | 无 Docker 方式（Entware + Node） |
|---|---|---|
| 适用 | x86_64/ARM64 能跑 Docker 的软路由 | 老 ARM 机型不支持 Docker |
| 安装 | `opkg install docker dockerd luci-app-docker` | `opkg install entware` → `/opt/bin/opkg install node` |
| 部署 | `docker compose up -d --build` | `scp -r` 项目 + `/opt/bin/npm ci --omit=dev` |
| 服务 | compose 自带 restart | procd 服务 `/etc/init.d/trollvnc-farm` |
| 网络 | host 模式 | 直享软路由网络 |
| 内网穿透 | frp（frps 公网 VPS + frpc 软路由） | `opkg install frpc` |

#### 5.4.4 scripts/gen-cert.mjs — 自签证书生成

**文件**：`trollvnc-farm/scripts/gen-cert.mjs`（116 行）

**核心职责**：为网关自动生成自签 TLS 证书（RSA2048，3650 天），SAN 含 DNS:localhost + 全部本机 IPv4。

**关键函数**：
- `findOpenSSL` — 探测 openssl：Windows 先 where.exe openssl 再试 Git/OpenSSL 常见安装路径；其他平台 PATH openssl
- `collectIPv4` — 收集本机全部非内部 IPv4 + 127.0.0.1
- `main` — mkdir CERT_DIR；证书已存在则跳过；openssl 不可用打印手动生成命令；`openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=SuperPhone-Farm -addext subjectAltName=DNS:localhost,IP:...` → cert.pem + key.pem；失败清理半成品

被 server/index.js 的 loadTlsOptions 在证书缺失时 spawnSync 同步调用

---

## 6. 辅助脚本（scripts/）

### 6.1 push-via-api.mjs — Git Data API 推送

**文件**：`scripts/push-via-api.mjs`
**核心职责**：通过 GitHub Git Data API 推送本地 commit（github.com 直连不可达时的备用通道；支持大文件 256MB 与 base tree 去重）

**关键步骤**：
1. `GET /repos/${REPO}/git/ref/heads/${BRANCH}` 验证远程 HEAD sha == REMOTE_BASE（否则拒绝，防覆盖）
2. `git diff --name-status ${LOCAL_BASE} ${LOCAL}` 取变更文件 → 对每个 A/M 用 `git cat-file blob` 读内容 → base64 → `POST /repos/${REPO}/git/blobs` 上传 → 收集 treeEntries（D 操作直接 sha:null）
3. `GET /repos/${REPO}/git/trees/${baseTree}?recursive=1` 取 base tree 全量 → 过滤与 base 相同 sha 的条目（防 GitHub tree API 422）
4. `POST /repos/${REPO}/git/trees`（base_tree: baseTree, tree: filtered）；filtered 为空时直接复用 baseTree
5. `POST /repos/${REPO}/git/commits`（message = `git log -1 --format=%B ${LOCAL}`，tree = 新 tree sha，parents: [REMOTE_BASE]）
6. `PATCH /repos/${REPO}/git/refs/heads/${BRANCH}`（sha: commit.sha, force: false）

**输入**：
- 环境变量：`GHTOK`（必需）、`REPO`（默认 `78725449/SuperPhone`）、`BRANCH`（默认 `main`）、`CWD`（默认项目根）
- 命令行参数：`<localCommit> <remoteBaseCommit> [localBaseCommit]`（localBase 默认 = remoteBase）

### 6.2 wait-ipa.mjs — 取 CI 产物

**文件**：`scripts/wait-ipa.mjs`
**核心职责**：轮询 GitHub Actions run 状态，完成后下载 packages-bootstrap artifact zip

**关键步骤**：
- `git credential-manager get` — 提取 GCM 缓存的 GitHub token
- 轮询循环：`GET /repos/${REPO}/actions/runs/${RUN_ID}` 取 status/conclusion；30s 间隔，最长 45 分钟
- 完成判定：conclusion === 'success' 才下载，否则退出码 1
- 下载：`GET /repos/${REPO}/actions/runs/${RUN_ID}/artifacts` 列出 → 过滤 `name.startsWith('packages-')`，优先 packages-bootstrap → `GET /repos/${REPO}/actions/artifacts/${id}/zip` → 写入 `${OUT_DIR}/${target.name}.zip`

**输入**：环境变量 `REPO`（默认 `78725449/SuperPhone`）、`OUT_DIR`（默认项目根）；命令行参数 `<runId> [outDir]`

### 6.3 _tmp-reorder-5801.py — 临时重排脚本

**文件**：`scripts/_tmp-reorder-5801.py`
**核心职责**：一次性临时脚本——重排 5801 直连页 index.vnc 中 BAR_KEYS 数组顺序

旧顺序 `power,home,volup,mute,voldn,briup,bridn,snapshot,spotlight,kb,copy,paste,full,disc` → 新顺序 `home,copy,paste,kb,snapshot,volup,mute,voldn,briup,bridn,spotlight,full,power,disc`

---

## 7. 端口与协议契约

### 7.1 RFB 扩展消息（0x50/0x80）

**头格式**（8 字节）：
```
type:1B (0x50 client→server / 0x80 server→client)
reserved:3B
payloadLen:4B (big-endian)
```
+ JSON payload

**14 个 op**：`cap.hello` / `cap.list` / `screen.hash` / `screen.diff` / `screen.waitStable` / `clients.count` / `clients.list` / `clients.disconnect` / `clients.block` / `clients.unblock` / `clients.blocked.list` / `clipboard.get` / `type.paste` / `config.get`

**v2 单连接承载**（2026-08-17 定稿）：0x50 请求经主 RFB 连接发送，设备端 novnc rfb.js patch 的 case 128 把 0x80 响应转 tvextresponse 事件；tvExtWriteResponse 在 sendMutex 锁内写出（与 FBU 帧互斥，防流错位断连）

### 7.2 隧道帧协议（FT_）

**头格式**（5 字节）：
```
type:1B
length:4B (big-endian)
```
+ payload

| 常量 | 值 | 方向 | 作用 |
|---|---|---|---|
| FT_PING | 0x02 | 设备→网关 | 心跳请求 |
| FT_PONG | 0x03 | 双向 | 心跳响应 |
| FT_CMD | 0x04 | 网关→设备 | 命令 JSON |
| FT_CMDACK | 0x05 | 设备→网关 | 命令 ack JSON |
| FT_STATE | 0x07 | 设备→网关 | 被控状态上报（{controlled, source}） |
| FT_CHAN_OPEN | 0x08 | 网关→设备 | 通道建立（[chanId:2BE][kind:1B]，0=thumb 1=session） |
| FT_CHAN_ACK | 0x09 | 设备→网关 | 通道建立确认（[chanId:2BE][ok:1B]） |
| FT_CHAN_DATA | 0x0A | 双向 | 通道 RFB 数据（[chanId:2BE][rfb字节]） |
| FT_CHAN_CLOSE | 0x0B | 双向 | 通道关闭（[chanId:2BE][reason:1B]，0=正常 1=对端EOF 2=错误） |

> 2026-08-23 proto:2：FT_DATA(0x01) 删除，RFB 数据统一走 FT_CHAN_DATA（chanId 分流）。通道复用让缩略图（chan 0）与控制流（会话通道）并存，取代 rfb.start/stop 轮换。

### 7.3 注册通道（18081，JSON 行）

```
设备→网关: {type:'register', deviceId, name, vncPort, configs?, screen?, httpPort?, ...}
         {type:'hello'}                    // 心跳
         {type:'ack', id, cmd, ok, ...}    // 命令 ack
网关→设备: {type:'ack', deviceId, name}    // 注册 ack
         {type:'cmd', id, ts, cmd, ...}    // 命令下发（cmd ∈ ping/query/invoke/set/restart）
```

### 7.4 隧道握手（18181）

```
设备→网关: {type:'tunnel_hello', deviceId, proto:2}   // 握手（行，proto 不匹配网关拒绝）
网关→设备: {type:'tunnel_ack', ok, error?}           // 握手 ack（行）
握手后切帧模式（feedFrame）；网关即发 CHAN_OPEN(chan 0, thumb) 开缩略图通道
```

### 7.5 控制端点（/ws/control/:id，JSON 行）

```
客户端→网关: {cmd:'ping|query|invoke|set|restart', id, cap?, params?, target?, key?, value?, timeout?}
网关→客户端: {type:'ack', cmd, id, ok, ...}     // envelope 覆盖 type/cmd/id/ok，透传设备 ack 数据字段
```

### 7.6 WS 会话关闭码

```
4000 unknown ws path
4001 unauthorized / preempted by new session/controller
4002 tunnel closed
4003 no tunnel: device not registered
4004 device not found
4005 device RFB unavailable (CHAN_ACK failed)
4006 device rfb eof (设备端 5901 EOF 回 CHAN_CLOSE)
```

---

## 8. 依赖关系全景

### 8.1 设备端进程结构

```
┌─────────────────────────────────────────────────────────────────┐
│                  launchd / launchctl                            │
│                              ↓                                  │
│              trollvncmanager.mm (main)                           │
│   ┌──────────────────────────────────────────────┐               │
│   │  OhMyJetsam.mm (constructor(101) Jetsam 绕过)│               │
│   └──────────────────────────────────────────────┘               │
│         │                                                       │
│         ├── TRWatchDog ──┬──> TRTask (Swift)                    │
│         │   (守护进程)    │     posix_spawn                      │
│         │                 └──> trollvncserver (子进程)            │
│         │                          │                             │
│         │                          ├── libvncserver (5901 RFB)   │
│         │                          ├── 0x50/0x80 扩展消息        │
│         │                          ├── ScreenCapturer ──> IOSurface│
│         │                          │   └── TRScreenHasher (pHash)│
│         │                          │       └── screen.hash/diff/waitStable│
│         │                          ├── STHIDEventGenerator       │
│         │                          │   (IOHID 注入)              │
│         │                          ├── ClipboardManager          │
│         │                          ├── BulletinManager (通知)    │
│         │                          └── Bonjour mDNS              │
│         │                                                       │
│         └── TRGatewayClient ──> 18081 注册/心跳                  │
│                 │                  ↑                             │
│                 │           ┌──────┴───────┐                    │
│                 │           ↓              │                    │
│                 │    TRCapabilityRegistry   │                    │
│                 │    (invoke/set/能力清单)   │                    │
│                 │           ↑              │                    │
│                 │           └── tvReloadConfigForKey             │
│                 │             (trollvncserver 实现 / Manager stub)│
│                 │                                               │
│                 └── TRTunnelClient ──> 18181 隧道               │
│                       (FT_ 帧协议透传 RFB + CMD)                 │
│                                                                 │
│   openLocalDummyService(46751)  ←─ 探测端口                     │
│   notify_register_dispatch:                                     │
│     prefs-changed   ←─ App 设置页写入（bridge 自退/重发 register/│
│                       watchdog 热调，双域读取 tvManagerReadPref）│
│     restart-service ←─ App TVNCRestartVNCService()（notify_post，│
│                       watchdog 重启 trollvncserver）             │
└─────────────────────────────────────────────────────────────────┘
```

### 8.2 端到端数据流

1. **配置写入路径**：用户在 TVNCRootListController 设置页修改 → NSUserDefaults suite `com.82flex.trollvnc` → **2026-08-20 起写后 `notify_post("com.82flex.trollvnc.prefs-changed")` → trollvncserver `tvApplyPrefsChanged` 热重载 hot/instant 配置（帧率/通知/自然滚动等即时生效）+ trollvncmanager 双通知自治（GatewayClient 重发 register / watchdog 热调）**；restart 级 key（密码/BindHost/TileSize/MaxRects/AsyncSwap/Scale/OrientationPadFix/BonjourEnabled/PerformanceMode 预设）触发 `_scheduleAutoRestart` → `TVNCRestartVNCService()`（notify_post restart-service）→ trollvncmanager watchdog 重启 trollvncserver（root 杀 root）→ 读取最新 defaults；ConnectionMode 不重启（TVNCServiceCoordinator 3s 轮询自动生效）
2. **服务启动路径**：AppDelegate → TVNCServiceCoordinator.registerServiceMonitor → 3s 定时探活 127.0.0.1:46751 → 失败时 spawnService（TRTask posix_spawn trollvncmanager 以 root 身份）→ trollvncmanager 再拉起 trollvncserver。**2026-08-20 桥接控制（ConnectionMode=bridge）**：`ensureServiceRunning` 不 spawn；切桥接时设置页 notify_post(prefs-changed) → trollvncmanager 收通知检测 bridge 模式自退（CFRunLoopStop 清理路径，root 进程自治）——本机仅作控制端连网关，省注册+隧道+后台保活全部开销（探活/后台刷新均空转）
3. **网关注册路径**：trollvncmanager → TCP 18081 注册到 trollvnc-farm 网关 → 网关设备目录含 selfId → TVNCAppStore.fetchWithRetry 拉取 /api/devices → isRegistered 匹配 selfId → 状态 = Registered → Hero 卡片绿"已连接"
4. **控制 Tab 路径**：TVNCConsoleWebViewController.buildConsoleURL → `https://{host}:8080/?container=ipa&token=&selfId=` → WKWebView 加载 → farmBridge 桥（writeClipboard / setTabBarHidden）
5. **客户端列表路径**：TVNCClientListController → TVNCControlConnect 127.0.0.1:5901 RFB 3.8 握手 + cap.hello（mgmt=YES 豁免）→ TVNCControlInvoke clients.list / clients.disconnect / clients.block / clients.unblock
6. **命令通道路径**：前端 → POST /api/devices/:id/invoke|configs|restart|ping → 网关 sendDeviceCmd：隧道 FT_CMD 帧优先，注册通道 JSON 行回退 → 设备 TRGatewayClient → TRCapabilityRegistry.invoke/setConfig → executor 执行 → ACK → 网关回调用端（默认 5s 等待 ack，超时/离线 504）
7. **卡片墙缩略图路径（2026-08-22 统一到 RFB + 2026-08-23 proto:2）**：隧道握手成功 → 网关发 CHAN_OPEN(chan 0) → 设备 connect 本地 5901（缩略图客户端 = 首个 RFB 客户端）+ 采集惰性启动（tunnel-connected 通知 @ CaptureFps）→ 采集帧 → framebuffer → tile 脏矩形检测 → libvncserver 编码 Raw → 5901 → 设备通道表 chan 0 → 隧道 CHAN_DATA(0) → 网关 ThumbRfbDecoder 解码（Raw → JPEG）→ 缓存 jpeg + 广播 `{type:'thumb', deviceId}` → 前端 fetchThumb GET /api/devices/:id/thumb 渲染（原 screen.hash/screenshot 轮询门控已移除）

### 8.3 端口契约矩阵

| 端口 | 用途 | 涉及模块 |
|------|------|---------|
| 5901 | RFB（画面+命令扩展消息 0x50/0x80） | TVNCClientListController / 设备端 TRCapabilityRegistry / trollvncserver |
| 5801 | 直连页 HTTP | TVNCConnectViewController.generateQRAsync / trollvncserver HTTP |
| 8080 | 网关控制台 | TVNCGatewayClient.gatewayPort / TVNCConsoleWebViewController.buildConsoleURL |
| 18081 | 网关注册 | TVNCRootListController.saveGateway（写死）/ TVNCServiceCoordinator（env 不注入）/ TRGatewayClient |
| 18181 | 网关隧道 | TRTunnelClient |
| 46751 | 服务存活探活 | Control.h::kTvAlivePort / TVNCServiceCoordinator._isServiceRunning |

### 8.4 构建产物矩阵

| Scheme | THEBOOTSTRAP | 输出 | 安装方式 | 含 app/ | 含 trollvncmanager |
|--------|------|------|---------|--------|----|
| default | 空 | .deb | 经典 rootfs 越狱 | 否 | 否 |
| rootless | 空 | .deb | rootless（/var/jb） | 否 | 否 |
| roothide | 空 | .deb | roothide（隐藏 root） | 否 | 否 |
| bootstrap | 1 | .tipa | TrollStore | 是 | 是 |

---

## 9. 项目运行方式

### 9.1 网关启动

```bash
cd trollvnc-farm && npm start        # 启动网关（8080；部署带 FARM_TOKEN=xxx）
cd trollvnc-farm && npm test         # 11 个测试套件（smoke/tunnel/register/dedupe/caps/gesture/pending-replay/press/order/events/tunnel-thumb）
```

**环境变量**（手动起网关必须全端口隔离）：
- `FARM_PORT` / `FARM_REG_PORT` / `FARM_TUNNEL_PORT` / `FARM_DATA_DIR` / `FARM_MDNS=0` 全部覆盖
- 否则默认 18081/18181 会劫持局域网真实设备的注册/隧道连接（2026-08-16 实测踩坑）

**Docker 部署**：
```bash
cd trollvnc-farm
# 修改 docker-compose.yml 中 FARM_TOKEN
docker compose up -d --build
```

### 9.2 设备端构建

```bash
cd TrollVNC && bash devkit/build-all.sh   # 设备端本地构建（仅 macOS + Theos）
```

**4 scheme 构建脚本**：bootstrap / default / rootless / roothide

**Windows 不能本地构建**，出 .tipa 只能走 CI（push main 触发或 workflow_dispatch）

### 9.3 CI 流程

- push `main` 触发 `.github/workflows/build.yml`（macOS runner）；**push 带 paths 过滤（2026-08-18）**：仅 `TrollVNC/**` 或 workflow 自身变更才触发，纯网关/脚本/文档改动不触发（避免私有仓库 billing 拦截秒失败）；`workflow_dispatch` 手动触发不受 paths 限制
- 4 scheme matrix 编译：default/rootless/roothide 出 `.deb`，bootstrap 出 `.tipa`（TrollStore 安装产物）
- 可选 `workflow_dispatch` 输入：is_managed（打 Managed.plist 预置）/ desktop_name / port / view_only / scale / frame_rate_spec / modifier_map
- push main 时创建 v0.0.1 tag + GitHub Release（body = TrollVNC/CHANGELOG.md）

### 9.4 推送与取包

```bash
# 推送（github.com 直连阻断时走 Git Data API）
GHTOK=<token> node scripts/push-via-api.mjs <本地commit> <远程base> [本地base]
# 默认 REPO=78725449/SuperPhone、BRANCH=main

# 取 CI 产物
node scripts/wait-ipa.mjs <runId>
# 默认 REPO 同上
```

### 9.5 版本号

- 设备端：`TrollVNC/Makefile` 的 `PACKAGE_VERSION`（现 0.0.1）
- 网关：`trollvnc-farm/package.json` 的 `version`（0.0.1，独立版本）

---

## 10. 已知边界与约束

### 10.1 架构红线

1. **能力层唯一**：设备操作只走 RFB→IOHID，禁止前端自造输入协议
2. **契约两端对齐**：前端 caps.js 自包含定义 + 设备端注册表存 executor；无上报、无元数据、无运行时发现；新增能力 = 设备端注册 + 前端定义数组各加一条
3. **单注册通道**：仅 18081 TCP JSON；WS 注册端点已废弃
4. **单会话约束**：设备仅 1 条隧道 + 1 个 5901 连接，同设备同时仅 1 个活跃 VNC 会话（4001 顶替）
5. **纯隧道**：三端控制台一律走隧道；无隧道 4003 拒绝；无直连回退、无反向模式
6. **协议先行**：跨端新能力先定契约，两端各自自测后再联调
7. **状态以网关为准**：前端不持久化设备状态，刷新一律从网关拉取
8. **改动可验证**：IPA 改动必须 CI 编译通过；网关改动必须 npm test 通过；未验证不声称完成
9. **无通用 /command 端点**（已删，禁止回归）；screen.diff / screen.waitStable 已删注册（不回归）
10. **文档纪律**：改动架构/时序/实现后同步更新说明文档.md（增删改查对应章节）；列表类信息（配置项/能力项/按键表）只存在于代码真相源

### 10.2 已知坑

- **实际远程仓库是 `78725449/SuperPhone`（私有，2026-08-15 单仓库化迁移后启用）**；`78725449/TrollVNC` 是迁移前的旧 fork（已废弃）
- **github.com 直连常被网络阻断** → 推送走 `scripts/push-via-api.mjs`（Git Data API，api.github.com 正常）
- **Windows 快照会丢可执行位**：改 `devkit/*.sh` 或 DEBIAN 脚本后必须恢复 100755，否则 CI before-package 报 Permission denied
- **手动起网关验证必须全端口隔离**：FARM_PORT/FARM_REG_PORT/FARM_TUNNEL_PORT/FARM_DATA_DIR/FARM_MDNS=0 全部覆盖
- **跨端参数契约**（如手势 scale）：一端生成、另一端校验的量必须语义一致并两端钳制/兜底，避免"链路通但语义断"
- **剪贴板是显式双向搬运（2026-08-17 起，无自动同步）**：复制=拉（clipboard.get）、粘贴=推（type.paste）；设备端不再监听系统剪贴板、不再自动推送，控制端复制不再自动写设备
- **CI 秒失败（job 数秒内 failure/cancelled、日志 BlobNotFound）**：先查 check-run annotations（`GET /repos/{repo}/check-runs/{job_id}/annotations`）——billing 拦截（付款失败/支出限额）的权威错误信息在这里，不要误判为 runner 故障或 YAML 语法
- **私有仓库 Actions 被 billing 拦截时的应急编译**：临时转 public → dispatch 编译 → 下载产物 → 立即转回 private
- **脚本化删除大段代码后必须做函数深度扫描**：python 按锚点删段可能误删函数闭合（语法配平但作用域错乱、node --check 查不出）——用 tokenizer 级深度扫描验证所有顶层函数深度为 0

### 10.3 已知边界与决策记录

- **iOS 后台挂起**：心跳无法阻止挂起；BGTask 后台刷新（15–60min）延长存活；锁屏久仍可能掉线 → 离线可见 + 解锁自动重连
- **Silent Push 唤醒**：技术上可行但依赖 APNs + 真机实测，**默认不投入**
- **通知治理**：连接/断开本地通知在农场场景会被控制台自身连接刷屏 → 默认关闭（Managed.plist 预置），保留"首连单条"可选
- **mDNS**：部分 AP 不可达 → 手动输入网关兜底
- **私有 API**：随 iOS 升级可能失效，锁定 TrollStore 支持范围，升级前灰度
- **多设备端到端同步验证**：单台真机链路已大量联调；群控（广播/批量/同步）多设备端到端验证待第二台实体设备

---

## 11. 文档差异核对

> 本节记录 Code Wiki（基于代码真相源）与 `AGENTS.md` / `说明文档.md` 的数量校准结果。已校准项如下（2026-08-17 修正 8→9 套件；2026-08-18 因 ServerCursor 移除 38→37，三方一致；2026-08-21 采集架构升级校准 CONFIG_DEFS 30 项与测试套件 11 个）。

| 项 | 修复前 | 代码真相源 | 修复状态 |
|---|---|---|---|
| 测试套件数 | 8（AGENTS.md / 说明文档.md） | **11**（package.json 串行 11 个：…/events-test.js + `tunnel-thumb-test.js`，2026-08-22 改测缩略图 RFB 流） | ✅ 已修复：说明文档.md 已同步为 11 套件，套件列表补 `events`、`tunnel-thumb`。**AGENTS.md 需同步**（仍写 10 套件） |
| CONFIG_DEFS 项数 | 38（2026-08-17 校准）/ 37 | **33 项**（caps.js 实际 33，`caps-test.js` 断言 `=== 33`；2026-08-20 配置治理 37→29；2026-08-21 采集架构升级 29→30；2026-08-22 统一到 RFB 30→28：-ThumbPushEnabled/ThumbInterval；**2026-08-23 定位 +5 SimLocation* 28→33**，设备端 `_registerConfigSchemas` 35 项） | ✅ 已修复：说明文档.md、CodeWiki 同步为 33。**AGENTS.md 需同步**（仍写 30 项相关描述） |
| BATCH_CAPS | 22（两文档一致，2026-08-25 +data.fill/data.clear） | 22（一致） | ✅ 已修复：说明文档.md §4.1 同步为 22 |
| KEY_DEFS | 10（两文档一致） | 10（一致） | — 无需修复 |
| GESTURE_DEFS | 3（两文档一致） | 3（一致） | — 无需修复 |

---

**文档完。** 所有信息均从源码提取，关键行号已标注便于回溯。如需补充特定文件细节或新增模块，请同步更新本 Wiki 与 `说明文档.md`。
