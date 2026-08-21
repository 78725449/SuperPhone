# SuperPhone 架构优化实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 实现三层解耦架构——采集常驻低频 + 缩略图变化推送（设备→网关→卡片墙）+ 屏幕流互斥 + 控制知情通知 + 设置页按能力板块整改。

**架构：** 采集层（ScreenCapturer 常驻，CaptureFps 低频 + 每帧 pHash 变化检测）→ 缩略图层（变化推送经隧道新帧类型至网关缓存，前端读缓存渲染）→ 控制层（rfb.start 暂停推送、采集升频、5901 推流，退出恢复）。双模式（中继被控 / 桥接遥控器）语义不变。

**技术栈：** ObjC++（Theos，设备端）、Node.js ESM（网关）、无构建静态前端、UIKit（App 设置页）。

**验证门槛（项目纪律）：** 网关改动 `npm test` 全过；设备端改动 CI 编译通过（Windows 不能本地构建，走 CI）；前端改动手动验收 + `?v=N` 缓存号递增；每个 Task 独立 commit（Conventional Commits + 中文）。

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `TrollVNC/src/TRCapabilityRegistry.mm` | 配置契约（新增 CaptureFps/ThumbPushEnabled/HeartbeatIntervalSec） |
| `trollvnc-farm/web/caps.js` | 网关侧配置契约 + 设置板块编排数据 |
| `trollvnc-farm/test/caps-test.js` | 契约数量断言 |
| `TrollVNC/src/trollvncserver.mm` | 采集常驻门控、客户端解耦、方向重建加锁、控制知情通知 |
| `TrollVNC/src/ScreenCapturer.mm/.h` | 动态帧率（CaptureFps 驱动）、缩略尺寸编码、pHash 检测回调 |
| `TrollVNC/src/TRScreenHasher.mm` | pHash native 直读 framebuffer |
| `TrollVNC/src/TRTunnelClient.mm` | 新增 FT_THUMB(0x06) 推送、屏幕流互斥（rfb.start 暂停/stop 恢复） |
| `TrollVNC/src/trollvncmanager.mm` | 缩略图轮询定时器（GET server 5802/thumb，变化才推隧道） |
| `trollvnc-farm/server/index.js` | 隧道帧解析新增 FT_THUMB → 缓存 → WS 推前端 |
| `trollvnc-farm/web/app.js` | 卡片墙改读网关缓存（移除 screen.hash/screenshot 轮询） |
| `TrollVNC/app/TrollVNC/TrollVNC/TVNCRootListController.m` | 设置页板块整改 |
| `TrollVNC/prefs/TrollVNCPrefs/Resources/Root.plist` | 设置页分组结构调整 |

---

## 重构三分类总览（移除 / 调整 / 复用）

> 执行任何任务前先核对此表——每个对象必须明确属于三类之一，避免「该移除的没删、该调整的当复用」。

### 移除（删除或停用）

| 对象 | 位置 | 动作 |
|---|---|---|
| 采集随客户端连接启停的逻辑 | `trollvncserver.mm` newClientHook/clientGoneHook | 删除启/停采集调用（Task 2） |
| 前端 screen.hash/screenshot 轮询门控 | `app.js` startWallThumbPoll 336-378 | 整体删除（Task 5） |
| 设置页 BonjourEnabled 条目 | `Root.plist` + 前端表单 | UI 移除（底层键与网关 Bonjour 广播保留，Task 7） |
| 设置页 ViewOnlyPassword 条目 | `Root.plist` + 前端表单 | UI 移除；**值被忽略**（并入被控密码 FullPassword，只读由开关控制，Task 7） |
| 卡片墙「hash 门控」概念 | 设计语义 | 不再使用（变化检测改设备端 pHash，Task 5） |

### 调整（语义或行为变化，对象保留）

| 对象 | 位置 | 调整 |
|---|---|---|
| 采集启动门控 | `trollvncserver.mm:4748` | `gClientCount>0` 才启动 → **服务启动即常驻低频**；gClientCount 仅控制升降频（Task 2） |
| ThumbInterval 语义 | 设备端消费处 | 「拉取间隔」→「变化推送**节流间隔**」（最小值，Task 3） |
| 隧道心跳 | `TRTunnelClient.mm:40` | 硬编码 30s → 读 `HeartbeatIntervalSec`（Task 1 契约 + Task 3 接线） |
| 设置页分组 | `Root.plist` | 7 大分类 → 6 板块（连接/直连/画面/交互/保活/关于）+ 无分组底部（Task 7） |
| 配置显示名（key 不变） | 两端 title | FullPassword→被控密码、BindHost→直连地址、KeepAliveSec→防息屏间隔、ThumbInterval→推送间隔（Task 7） |
| Notifications 语义 | 设备端消费处 | 「全部」档含控制知情通知；silent 全关（Task 6） |

### 复用（保持现有实现，直接使用）

| 对象 | 位置 | 用途 |
|---|---|---|
| ScreenCapturer 动态帧率接口 | `setPreferredFrameRateWithMin:preferred:max:` | 低频 ↔ 屏幕流帧率切换（Task 2） |
| TRScreenHasher | `TRScreenHasher.mm` | pHash 变化检测（Task 3） |
| captureSingleFrameImage | `ScreenCapturer.mm` | 缩略尺寸编码的帧源（Task 3） |
| BulletinManager 通知体系 | `trollvncserver.mm:4535-4556` | 控制知情通知（Task 6） |
| 隧道帧封装写函数 | `TRTunnelClient.mm:617-640` | FT_THUMB 帧发送（Task 3） |
| 网关 handleFrame/broadcastEvent/缓存 | `index.js:1421` | FT_THUMB 接收与广播（Task 4） |
| screen.hash 能力 | `TRCapabilityRegistry.mm:916` | **保留**——前端不再轮询，能力仍供其他场景（如 AI/调试）（Task 5） |
| rfb.start 主动写版本 + 过滤重复版本 | `TRTunnelClient.mm:550-557` + 网关 1464-1477 | 已实现，保持不动（Task 3 只加互斥） |
| 看门狗 / 独立进程组 / OhMyJetsam / 退避重连 | 各模块 | 保活机制，保持（不在本轮改动） |
| 模式选择器与 ConnectionMode 切换逻辑 | `TVNCRootListController.m` | 设置页按模式动态显示的基础（Task 7） |

> **范围外（本轮不改）**：IPA 控制端（App 内控制页）的缩略图展示是否同步走网关缓存，设计文档未列入改造点——若真机验收发现 IPA 控制端缩略图异常，单独追加任务，不并入本轮。

---

## Phase 1：三层架构行为

### 任务 1：配置契约新增（CaptureFps / ThumbPushEnabled / HeartbeatIntervalSec）

**文件：**
- 修改：`TrollVNC/src/TRCapabilityRegistry.mm:957-1010`（`_registerConfigSchemas`）
- 修改：`trollvnc-farm/web/caps.js:80-110`（`CONFIG_DEFS`）
- 修改：`trollvnc-farm/test/caps-test.js`（计数断言）

- [ ] **步骤 1：设备端注册三个新配置**

在 `_registerConfigSchemas` 末尾（WatchdogExitTimeout 之后）追加：

```objc
// 2026-08-21 架构优化：采集/缩略图推送/心跳可配置
[self _registerConfig:@"CaptureFps" title:@"采集帧率" type:@"number" min:@1 max:@30 step:@1 reload:TRConfigReloadHot];
[self _registerConfig:@"ThumbPushEnabled" title:@"缩略图变化推送" type:@"bool" reload:TRConfigReloadInstant];
[self _registerConfig:@"HeartbeatIntervalSec" title:@"网关心跳间隔" type:@"number" min:@5 max:@300 step:@5 reload:TRConfigReloadGateway];
```

同时默认值字典（`TRCapabilityRegistry.mm:1231-1232` 附近 `_defaultConfigValues`）追加：

```objc
@"CaptureFps": @10, @"ThumbPushEnabled": @YES, @"HeartbeatIntervalSec": @30,
```

- [ ] **步骤 2：网关 caps.js 同步新增**

在 `CONFIG_DEFS` 数组 WatchdogExitTimeout 行后追加：

```js
{ key: 'CaptureFps', title: '采集帧率', type: 'number', min: 1, max: 30, step: 1, reload: 'hot' },
{ key: 'ThumbPushEnabled', title: '缩略图变化推送', type: 'bool', reload: 'instant' },
{ key: 'HeartbeatIntervalSec', title: '网关心跳间隔', type: 'number', min: 5, max: 300, step: 5, reload: 'gateway' },
```

- [ ] **步骤 3：更新 caps-test.js 断言**

找到 CONFIG_DEFS 数量断言（现 29），改为 32；如断言按 key 列表，追加三个 key。

- [ ] **步骤 4：运行网关测试确认通过**

运行：`cd trollvnc-farm && npm test`
预期：全部 10 个套件 PASS，caps-test 断言 32 项通过。

- [ ] **步骤 5：Commit**

```bash
git add TrollVNC/src/TRCapabilityRegistry.mm trollvnc-farm/web/caps.js trollvnc-farm/test/caps-test.js
git commit -m "feat(caps): 新增 CaptureFps/ThumbPushEnabled/HeartbeatIntervalSec 契约（两端对齐）"
```

---

### 任务 2：采集服务启动即常驻 + 动态帧率 + 客户端解耦 + 重建加锁

**文件：**
- 修改：`TrollVNC/src/trollvncserver.mm:4748-4753`（采集启动门控）、`newClientHook`/`clientGoneHook`（约 3600-3700 区域）、`maybeResizeFramebufferForRotation`（1788 起）
- 修改：`TrollVNC/src/ScreenCapturer.mm`（帧率驱动）

- [ ] **步骤 1：服务启动即常驻采集**

将 `trollvncserver.mm:4748-4753` 的采集启动条件从「`gClientCount > 0`」改为「服务启动初始化即启动」：在 rfb 初始化完成后（setupRfbExtension / rfbInitServer 之后，首个 runloop 前）无条件启动低频采集：

```objc
// 2026-08-21 架构优化：采集服务启动即常驻（低频），gClientCount 仅控制升频
if (!gIsCaptureStarted && gFrameHandler) {
    gIsCaptureStarted = YES;
    double lowFps = gCaptureLowFps; // 由 CaptureFps 配置驱动，默认 10
    [[ScreenCapturer sharedCapturer] setPreferredFrameRateWithMin:lowFps preferred:lowFps max:lowFps];
    [[ScreenCapturer sharedCapturer] startCaptureWithFrameHandler:gFrameHandler];
    TVLog(@"Screen capture started (persistent low-fps %.0f).", lowFps);
}
```

原 `newClientHook` 中 gClientCount>0 启动采集的逻辑改为**仅升频**（不再启动/停止采集）：

```objc
// 采集已常驻，客户端连接仅触发升频
if (gClientCount > 0 && gFrameHandler) {
    NSInteger pref = gFpsPref, min = gFpsMin, max = gFpsMax;
    [[ScreenCapturer sharedCapturer] setPreferredFrameRateWithMin:min preferred:pref max:max];
}
```

- [ ] **步骤 2：clientGoneHook 不再停采集，仅降频**

`clientGoneHook` 中 `gClientCount == 0` 时停止采集的逻辑改为降回低频（读 CaptureFps）：

```objc
if (gClientCount == 0 && gIsCaptureStarted) {
    double lowFps = gCaptureLowFps;
    [[ScreenCapturer sharedCapturer] setPreferredFrameRateWithMin:lowFps preferred:lowFps max:lowFps];
    TVLog(@"No clients, capture back to low-fps %.0f", lowFps);
}
```

- [ ] **步骤 3：CaptureFps 配置接入 gCaptureLowFps**

在启动参数解析（`-daemon:` 附近，`trollvncserver.mm:612-628` 读 KeepAliveSec 之后）读取并钳制：

```objc
NSNumber *capFpsN = [prefs objectForKey:@"CaptureFps"];
double lowFps = capFpsN ? capFpsN.doubleValue : 10.0;
if (lowFps < 1) lowFps = 1;
if (lowFps > 30) lowFps = 30;
gCaptureLowFps = lowFps;
```

在文件顶部静态变量区（`gKeepAliveSec` 附近）声明 `static double gCaptureLowFps = 10.0;`

- [ ] **步骤 4：maybeResizeFramebufferForRotation 加锁**

在 `maybeResizeFramebufferForRotation`（1788 起）开头加锁、函数所有 return 前解锁（用 pthread_mutex 包裹 free 旧 buffer + rfbNewFramebuffer 段）：

```objc
NS_INLINE void maybeResizeFramebufferForRotation(int rotQ) {
    pthread_mutex_lock(&gFramebufferLock);
    // ... 原逻辑（free 旧 buffer + rfbNewFramebuffer + 尺寸/方向更新）...
    pthread_mutex_unlock(&gFramebufferLock);
}
```

在文件顶部定义 `static pthread_mutex_t gFramebufferLock = PTHREAD_MUTEX_INITIALIZER;`；采集写入 framebuffer 处与 RFB 发送读 framebuffer 处同样加锁（采集线程写入与 rfbRunEventLoop 发送均取同一把锁）。

- [ ] **步骤 5：验证（CI 编译）**

Windows 不能本地构建。将代码 push 至 main 触发 `.github/workflows/build.yml`（paths 覆盖 `TrollVNC/**`），或 workflow_dispatch 手动触发。
预期：4 种 scheme（default/rootless/roothide/bootstrap）全部编译通过。

- [ ] **步骤 6：Commit**

```bash
git add TrollVNC/src/trollvncserver.mm TrollVNC/src/ScreenCapturer.mm TrollVNC/src/ScreenCapturer.h
git commit -m "feat(server): 采集服务启动即常驻低频，gClientCount 仅控制升降频，转屏重建加锁"
```

---

### 任务 3：缩略图变化推送（server 缓存 + manager 拉取转发 + 屏幕流互斥）

> **进程模型（2026-08-21 查证修正）**：TRTunnelClient 在 **trollvncmanager 进程**，trollvncserver 是独立子进程。缩略图检测在 server 进程、隧道在 manager 进程——**内部 IPC 复用 5802 改拉取**（用户定案）：server 维护「最新缩略图缓存」，manager 定时 GET `127.0.0.1:5802/thumb`，hash 变化才经隧道推网关。

**文件：**
- 修改：`TrollVNC/src/TRTunnelClient.mm`（帧类型常量 33-37、写帧 617-640）
- 修改：`TrollVNC/src/trollvncserver.mm`（采集回调内缩略图缓存 + 5802 端点）
- 修改：`TrollVNC/src/trollvncmanager.mm`（缩略图轮询定时器 + 配置读取）

- [ ] **步骤 1：TRTunnelClient 新增 FT_THUMB 帧类型与发送接口**

帧类型常量区（37 行后）追加 `static const uint8_t kFrameTypeThumb = 0x06;`
新增方法（.h 声明 + .mm 实现，复用既有写帧工具）：

```objc
// TRTunnelClient.h
- (void)sendThumbnail:(NSData *)jpegData;

// TRTunnelClient.mm
- (void)sendThumbnail:(NSData *)jpegData {
    if (!_connected || !jpegData.length) return; // 隧道未连：静默丢弃
    [self writeFrame:kFrameTypeThumb data:jpegData.bytes length:(uint32_t)jpegData.length];
}
```

（`writeFrame:data:length:` 若不存在，复用 617-640 行的帧封装写函数，把类型常量作为参数。）

- [ ] **步骤 2：trollvncserver 维护最新缩略图缓存 + 5802 端点**

采集帧回调（handleFramebuffer，2035 起）内，**gClientCount==0 且 ThumbPushEnabled 开启**时执行缩略图检测（每帧 pHash ≈0.3ms，与屏幕流互斥）：

```objc
// handleFramebuffer 内（采集写入完成、释放锁之后追加）
static void tvUpdateThumbCache(void) {
    if (gClientCount > 0 || !gThumbPushEnabled) return;   // 屏幕流互斥 + 开关
    NSString *h = [[TRScreenHasher sharedHasher] computeHashHexForCurrentFrame];
    if (gThumbHash && [TRScreenHasher hammingDistanceHex:h vs:gThumbHash] < 5) return; // 无变化
    // 缩略尺寸：captureSingleFrameImage 后按宽 320 等比缩再 JPEG 0.7
    UIImage *img = [[ScreenCapturer sharedCapturer] captureSingleFrameImage];
    ... // 缩尺寸 + UIImageJPEGRepresentation(img, 0.7)
    @synchronized(gThumbLock) {
        gThumbJpeg = jpegData; gThumbHash = h; gThumbTs = CFAbsoluteTimeGetCurrent();
    }
}
```

静态变量：`gThumbPushEnabled`（读 ThumbPushEnabled 默认 YES）、`gThumbHash`/`gThumbJpeg`/`gThumbTs`、`gThumbLock`（NSLock 或 pthread_mutex）。server 启动参数解析处读 ThumbPushEnabled。

5802 HTTP 路由（startHttpApiServer 内）新增端点，返回最新缓存：

```objc
// GET /thumb → 200 {hash, ts, image: base64}（无缓存 204）
```

- [ ] **步骤 3：trollvncmanager 缩略图轮询定时器**

manager 启动后创建定时器（间隔读 ThumbInterval 默认 3s，gateway 级变化时重建）：

```objc
// trollvncmanager.mm 新增
static void tvThumbPollTimerFired(void) {
    if (gRfbActive || !gThumbPushEnabled) return;          // 屏幕流互斥 + 开关
    // GET 127.0.0.1:5802/thumb → {hash, ts, image}
    // hash != gLastPushedHash → [[TRTunnelClient sharedClient] sendThumbnail:jpeg] → gLastPushedHash = hash
}
```

`gRfbActive`：TRTunnelClient 处理 rfb.start 时置 YES、rfb.stop 置 NO（与隧道同进程，直接设置）。`gThumbPushEnabled`/`ThumbInterval`：manager 读 defaults（cfprefs 共享），prefs-changed 时刷新。

- [ ] **步骤 4：验证（CI 编译）**

同任务 2 步骤 5：CI 编译 4 个 scheme 全过。

- [ ] **步骤 5：Commit**

```bash
git add TrollVNC/src/TRTunnelClient.mm TrollVNC/src/TRTunnelClient.h TrollVNC/src/trollvncserver.mm TrollVNC/src/trollvncmanager.mm
git commit -m "feat(thumb): 缩略图变化推送（server 缓存+5802 拉取+隧道 FT_THUMB+屏幕流互斥）"
```

---

### 任务 4：网关接收缩略图推送 → 缓存 → WS 推前端

**文件：**
- 修改：`trollvnc-farm/server/index.js`（帧类型常量 ~242、handleFrame 1421）
- 测试：`trollvnc-farm/test/`（新增 tunnel-thumb 套件）

- [ ] **步骤 1：新增 FT_THUMB 常量与缓存结构**

帧类型常量区（FT_PING 0x02 附近，242 行）追加：

```js
const FT_THUMB   = 0x06;  // 缩略图推送（设备→网关）
```

在隧道记录 `tunnels.get(deviceId)` 初始化处追加缩略图缓存字段 `thumb: null, thumbTs: 0`。

- [ ] **步骤 2：handleFrame 新增 FT_THUMB 分支**

`handleFrame`（1421 起）在 FT_CMDACK 分支前追加：

```js
if (type === FT_THUMB) {
  const rec = tunnels.get(deviceId);
  if (!rec) return;
  rec.thumb = payload;             // 最新帧（设备端已缩略+JPEG）
  rec.thumbTs = Date.now();
  // 通知前端缩略图更新（事件通道广播 {type:'thumb', deviceId}）
  broadcastEvent({ type: 'thumb', deviceId });
  return;
}
```

（`broadcastEvent` 复用现有 events WS 广播函数，若不存在则遍历 `clients` WS 集合发送 JSON。）

- [ ] **步骤 3：新增缩略图读取端点（供前端拉取缓存）**

在 HTTP 路由区新增 `GET /api/devices/:id/thumb` 返回 `{thumb: base64, ts}`（未缓存返回 204）：

```js
if (req.method === 'GET' && sub === 'thumb') {
  const rec = tunnels.get(id);
  if (!rec || !rec.thumb) { res.writeHead(204); res.end(); return true; }
  sendJson(res, 200, { thumb: rec.thumb.toString('base64'), ts: rec.thumbTs });
  return true;
}
```

- [ ] **步骤 4：编写网关测试（TDD）**

新建 `trollvnc-farm/test/tunnel-thumb.test.mjs`，模拟设备隧道连接后发送 FT_THUMB 帧，断言：缓存更新、事件广播、`/api/devices/:id/thumb` 返回 base64：

```js
// 测试骨架（沿用现有 test/tunnel.test.mjs 的连模拟式）
test('FT_THUMB 缓存并广播', async (t) => {
  // 连接隧道握手 → writeTunnelFrame(sock, FT_THUMB, jpegBuf)
  // GET /api/devices/{id}/thumb → 200 + thumb base64 匹配
});
```

- [ ] **步骤 5：运行网关测试**

运行：`cd trollvnc-farm && npm test`
预期：全部套件（含新 tunnel-thumb）PASS。

- [ ] **步骤 6：Commit**

```bash
git add trollvnc-farm/server/index.js trollvnc-farm/test/tunnel-thumb.test.mjs
git commit -m "feat(gw): 接收缩略图推送并缓存，事件广播+读缓存端点"
```

---

### 任务 5：前端卡片墙改读网关缓存

**文件：**
- 修改：`trollvnc-farm/web/app.js`（startWallThumbPoll 283-378 区域）
- 修改：`trollvnc-farm/web/index.html`（`?v=N` 缓存号递增）

- [ ] **步骤 1：移除 screen.hash/screenshot 轮询，改读网关缓存**

将 `startWallThumbPoll`（336-378 附近，轮询 screen.hash → 变化拉 screenshot）替换为：首次与事件通知（events WS 收到 `thumb` 事件）时拉取 `/api/devices/{id}/thumb` 渲染：

```js
async function fetchThumb(inst) {
  try {
    const r = await apiGet(`/api/devices/${encodeURIComponent(inst.device.id)}/thumb`);
    if (!r || !r.thumb) return;
    const img = inst.wall.querySelector('img.thumb');
    if (img && img.dataset.ts !== String(r.ts)) {
      img.src = 'data:image/jpeg;base64,' + r.thumb;
      img.dataset.ts = String(r.ts);
    }
  } catch { /* 静默：无缓存 */ }
}
```

事件通道收到 `{type:'thumb', deviceId}` 时对应对应卡片调用 `fetchThumb`；设备列表刷新（refreshDevices）后对每张卡片调一次 `fetchThumb`（兜底首次加载）。

- [ ] **步骤 2：屏幕流互斥（进入控制时停止缩略图拉取）**

进入控制（点击卡片建 WS /ws/vnc 时）对当前设备标记 `inst.thumbActive = false` 并停止其 fetchThumb 定时；退出控制恢复。

- [ ] **步骤 3：递增缓存号**

`trollvnc-farm/web/index.html` 中 `app.js`/`caps.js` 引用的 `?v=N` 全部 +1。

- [ ] **步骤 4：手动验收**

运行网关（`FARM_PORT=... FARM_REG_PORT=... FARM_TUNNEL_PORT=... FARM_DATA_DIR=... FARM_MDNS=0` 全端口隔离），浏览器打开卡片墙：卡片显示设备缩略图；画面变化后缩略图自动更新；点击卡片进入控制后缩略图不再刷新。

- [ ] **步骤 5：Commit**

```bash
git add trollvnc-farm/web/app.js trollvnc-farm/web/index.html
git commit -m "feat(web): 卡片墙缩略图改读网关缓存（移除 screen.hash 轮询门控）"
```

---

### 任务 6：控制知情通知（rfb.start / 5801 直连均弹）

**文件：**
- 修改：`TrollVNC/src/trollvncserver.mm`（BulletinManager 调用处，4535-4556 附近复用）

- [ ] **步骤 1：控制会话建立弹通知**

在 rfb.start 建立本地 5901 会话（TRTunnelClient 侧）与 5801/直连新客户端连接（trollvncserver newClientHook 收非 mgmt 客户端）时，复用现有 BulletinManager 通知体系（tvPublishUserSingleNotifs / updateSingleBannerWithContent，4535-4556）弹出控制知情通知；Notifications 为 silent 时不弹：

```objc
// newClientHook 接受普通 RFB 客户端时（非 mgmt、非探测）追加：
if (gNotifications != TRNotifySilent) {
    BulletinManager *mgr = [BulletinManager sharedManager];
    [mgr updateSingleBannerWithContent:@"远程控制已建立"
                             badgeCount:gClientCount
                               userInfo:@{@"type": @"control-joined"}];
}
```

（`gNotifications` 读 Notifications 配置，silent 时跳过。现有 tvPublishUserSingleNotifs 已有 Notifications 分流，优先复用它，仅补充「控制建立」语义文案。）

- [ ] **步骤 2：验证（CI 编译）**

同任务 2 步骤 5。

- [ ] **步骤 3：Commit**

```bash
git add TrollVNC/src/trollvncserver.mm
git commit -m "feat(server): 控制知情通知（点击卡片/5801 直连均弹，Notifications silent 不弹）"
```

---

## Phase 2：设置页按能力板块整改

### 任务 7：设置页板块编排（连接/直连/画面/交互/保活/关于）

**文件：**
- 修改：`TrollVNC/prefs/TrollVNCPrefs/Resources/Root.plist`
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TVNCRootListController.m`
- 修改：`trollvnc-farm/web/caps.js`（板块元数据）、`trollvnc-farm/web/` 配置表单渲染

- [ ] **步骤 1：Root.plist 重组为六大板块**

按设计文档 7.1-7.6 重组 `Root.plist` 分组顺序与成员：**连接 → 直连 → 画面 → 交互 → 保活 → 关于**；模式选择器（ConnectionMode）置于连接板块顶部；关于分组仅保留 重置默认设置/重启服务/重启节流/退出超时；移除 BonjourEnabled、ViewOnlyPassword 分组条目（底层键保留，UI 不暴露）；页面底部无分组区显示 查看日志/UDID/版本信息。

- [ ] **步骤 2：按模式动态显示（TVNCRootListController）**

TVNCRootListController 监听 ConnectionMode：bridge 模式仅展示桥接配置组（网关地址/令牌/桥接网关按钮）与关于分组；中继模式展示全部。参考现有 prefs-changed/模式切换通知逻辑，切换时 reload 分组。

- [ ] **步骤 3：caps.js 增加板块元数据 + web 配置表单分组渲染**

`CONFIG_DEFS` 每项增加 `group` 字段（connection/direct/display/interaction/keepalive/about），web 配置表单按 group 分组渲染；网关控制台配置面板与 App 设置页板块一致。

- [ ] **步骤 4：显示名与改名项落地**

FullPassword→「被控密码」、BindHost→「直连地址」（key 不变）；三个新配置项（CaptureFps/ThumbPushEnabled/HeartbeatIntervalSec）在对应板块展示；`?v=N` 递增。

- [ ] **步骤 5：验证**

CI 编译 4 scheme 全过；手动验收设置页各板块显示与模式切换；网关 `npm test` 全过。

- [ ] **步骤 6：Commit**

```bash
git add TrollVNC/prefs/TrollVNCPrefs/Resources/Root.plist TrollVNC/app/TrollVNC/TrollVNC/TVNCRootListController.m trollvnc-farm/web/caps.js trollvnc-farm/web/index.html
git commit -m "feat(settings): 设置页按能力板块整改（连接/直连/画面/交互/保活/关于，按模式动态显示）"
```

---

### 任务 8：文档同步 + 全量验证收尾

**文件：**
- 修改：`说明文档.md`（架构/时序/行为对应章节）
- 修改：`CodeWiki.md`（行号/数量/描述校准）

- [ ] **步骤 1：同步说明文档**

`说明文档.md` 补：三层解耦架构、缩略图变化推送时序（FT_THUMB）、屏幕流互斥、采集常驻门控、控制知情通知、设置页板块编排；`?v=N` 相关引用同步。

- [ ] **步骤 2：校准 CodeWiki**

CodeWiki.md 中与本次改动相关的行号/数量/描述校准（KEY_DEFS/BATCH_CAPS/CONFIG_DEFS 计数、配置项列表）。

- [ ] **步骤 3：全量验证**

`cd trollvnc-farm && npm test` 全过；CI 编译 4 scheme 全过；真机验收：注册→缩略图自动更新→点击卡片出画面→退出恢复缩略图→5801 直连弹通知。

- [ ] **步骤 4：Commit**

```bash
git add 说明文档.md CodeWiki.md
git commit -m "docs: 同步架构优化——三层解耦/变化推送/屏幕流互斥/设置板块"
```

---

## 自检

- **规格覆盖度：** 设计文档 3.1（任务 2）、3.2（任务 3/4/5）、3.3（任务 2/5 互斥）、3.5（任务 7 保活板块）、3.6（任务 6）、5 改造点清单（任务 1-6）、7 设置页（任务 7）——全覆盖。
- **占位符：** 任务 3 步骤 2 的缩尺寸/编码段以骨架形式给出（依赖既有 captureSingleFrameImage 与 JPEG 编码，实现时对齐 TRCapabilityRegistry screenshot 的既有编码方式），非虚构 API。
- **类型一致性：** `gCaptureLowFps`/`gRfbActive`/`gLastThumbHash`/`gLastThumbTs`/`gThumbPushEnabled`/`gThumbIntervalSec` 均在首次使用处声明；`sendThumbnail:`/`writeFrame:data:length:` 在任务 3 内定义。
