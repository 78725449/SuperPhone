# AGENTS.md（工作区指令 · SuperPhone）

> 机器级全局规则见 `~/.zcode/AGENTS.md`（先加载）；本文件只补充本仓库特有事实。
> **项目知识库**：`说明文档.md` 是唯一真相文档（架构/时序/实现）。改动架构、时序或行为后必须同步更新它（增删改查对应章节）；列表类信息（按键/能力/配置项）只存在于代码真相源，不复制进文档。

## 仓库是什么

内网自用的 iOS 设备群控系统（SuperPhone）。单仓库，三部分：

- `TrollVNC/` — 设备端（Theos 工程）：VNC 服务 + 命令注册表 + App 外壳。`src/` 为核心源码（trollvncserver、TRCapabilityRegistry、TRGatewayClient、TRTunnelClient、STHIDEventGenerator 等）；`app/TrollVNC/` 为 UIKit 外壳；`layout/` 含 5801 直连页文件
- `trollvnc-farm/` — 网关（Node.js ESM）：`server/index.js` 单入口（注册/隧道/控制台），`web/` 为无构建静态前端，`test/` 为测试套件
- `scripts/` — 推送/取包辅助脚本（见"已知坑"）

## 常用命令

```bash
cd trollvnc-farm && npm start        # 启动网关（8080；部署带 FARM_TOKEN=xxx）
cd trollvnc-farm && npm test         # 11 个测试套件（smoke/tunnel/register/dedupe/caps/gesture/pending-replay/press/order/events/tunnel-thumb）——网关改动必须全过
cd TrollVNC && bash devkit/build-all.sh   # 设备端本地构建（仅 macOS + Theos）
```

- **设备端无 lint/typecheck**；**Windows 不能本地构建**，出 .tipa 只能走 CI。
- **CI**（`.github/workflows/build.yml`）：push `main` 触发 macOS 编译 4 种 scheme——default/rootless/roothide 出 `.deb`，bootstrap 出 `.tipa`（TrollStore 安装产物）；可选 `workflow_dispatch` 输入（is_managed 打 Managed.plist 预置、desktop_name、port、view_only、scale、frame_rate_spec、modifier_map）。**push 带 paths 过滤（2026-08-18）**：仅 `TrollVNC/**` 或 workflow 自身变更才触发编译，纯网关/脚本/文档改动不触发（避免私有仓库 billing 拦截秒失败）；`workflow_dispatch` 手动触发不受 paths 限制。
- 版本号在 `TrollVNC/Makefile` 的 `PACKAGE_VERSION`（现 0.0.1）。

## 架构红线（改任何端前先读 `说明文档.md`）

- 端口全固定：5901 RFB（画面+命令扩展消息 0x50/0x80）/ 5801 直连页 / 5802 直连页管理 API（HTTP，v3）/ 5902 远程日志端点（manager 常驻，GET /stderr|/stdout 返回崩溃日志尾部 64KB）/ 8080 控制台 / 18081 注册 / 18181 隧道；端口不可调。
- **能力层唯一地基**：设备操作只走 RFB → IOHID 注入，禁止前端自造输入协议；无通用 `/command` 端点（已删，禁止回归）。
- **前端契约两端对齐**：`trollvnc-farm/web/caps.js` 自包含定义（KEY_DEFS 10 / BATCH_CAPS 20 / CONFIG_DEFS 33），设备端 `TRCapabilityRegistry` 只存 executor；新增能力 = 两端各加一条，无上报、无元数据表、无运行时发现。
- 单会话约束：设备仅 1 条隧道 + 1 个 5901 连接，同设备同时仅 1 个活跃 VNC 会话；纯隧道（无直连回退、无反向模式）。
- 状态以网关为准：前端不持久化设备状态，刷新一律从网关拉取。
- **剪贴板是显式双向搬运（2026-08-17 起，无自动同步）**：复制=拉（clipboard.get）、粘贴=推（type.paste）；**粘贴的 http 降级（2026-08-18 定稿）**：http 读不到控制端剪贴板 → 粘贴按钮与 Ctrl+V **一律弹输入浮层**（PC/触屏统一，浮层内 Ctrl+V 或回车自动注入），https 直读直贴——已废弃隐藏 textarea「第二次点击/Ctrl+V 提交」方案，禁止回归。
- **光标体系（2026-08-18 定稿）**：触屏端不显示任何光标（无自动消失触点）；PC 端常驻自绘覆盖层光标（网关=深灰圆+浅灰外圈 pcRgba、5801=苹果灰圆）；两端均覆盖 `_refreshCursor`（clear/空操作）屏蔽服务器默认 X 形光标。改光标功能时两端语义对齐、勿回归「自动消失触点」。
- **respring 禁用（2026-08-24 定稿）**：respring（kill SpringBoard）重启主屏会**中断前台 App、打断隧道/注册会话、破坏 daemon 保活链路**。数据直写系统库后 kill 对应 daemon（callservicesd/imagent/contactsd，见 `说明文档.md` §4.8）即可让系统 App 读取新数据——respring 属**冗余设计**。**全项目禁止使用 respring**：数据刷新/UI 生效/改名一律不得 kill SpringBoard；`data.respring` 能力已删除，禁止回归；`device.rename` 不再重启 SpringBoard（改名不即时生效可接受）。
- 验证门槛：IPA 改动必须 CI 编译通过；网关改动必须 `npm test` 通过；未验证不声称完成。

## 开发流程约定（改动前必读）

1. **文档纪律**：改动架构/时序/行为后必须同步 `说明文档.md`（唯一真相文档）对应章节；CodeWiki.md 中与该改动相关的行号/数量/描述同步校准；`?v=N` 缓存号递增。**提交与文档同步同一 commit**，避免"代码先行、文档遗忘"。
2. **契约两端对齐**：新增能力/配置 = 网关 `caps.js` + 设备端 `TRCapabilityRegistry` 各加一条；数量变化（KEY_DEFS/BATCH_CAPS/CONFIG_DEFS）同步 `caps-test.js` 断言与三方文档计数。5801 分叉 caps.js 与网关 caps.js 互不引用，各自维护。
3. **行为改动带验证**：网关改动 → `npm test`；前端改动 → 手动验收（`test/verify-*.mjs` 可选）+ 缓存号递增；设备端改动 → CI 编译。未验证不声称完成。
4. **注释与实现一致**：改行为时必须同步相邻注释（本项目多次踩坑：注释描述旧方案误导后续开发）；删除功能时全局 grep 其所有变体（含本地化/托管脚本/workflow/文档）确认无残留。
5. **跨端语义一致**：两端（5801 与网关）同一交互必须语义对齐（粘贴/光标/FAB 菜单），改一端时对照另一端，禁止单边改动造成行为分叉。

## 约定

- 提交用 Conventional Commits + 中文描述（`feat(web):` / `fix:` / `refactor:` / `docs:`），中文沟通。
- 前端改动（`trollvnc-farm/web/`）记得同步 `?v=N` 缓存破坏引用；改 `caps.js` 时注意它和 `TrollVNC/layout/usr/share/trollvnc/webclients/caps.js`（5801 直连页）是**分叉的两个文件**，互不引用。

## 已知坑

- **实际远程仓库是 `78725449/SuperPhone`（私有，2026-08-15 单仓库化迁移后启用）**；`78725449/TrollVNC` 是迁移前的旧 fork（已废弃）。
- **github.com 直连常被网络阻断** → 推送走 `scripts/push-via-api.mjs`（Git Data API，api.github.com 正常）：`GHTOK=<token> node push-via-api.mjs <本地commit> <远程base> [本地base]`（默认 REPO=78725449/SuperPhone、BRANCH=main，CWD 可用环境变量覆盖；支持大文件与 base tree 去重；远程 main 与 base 不符会拒绝）。
- **GitHub API 间歇性 503（2026-08-18 实测）**：Git Data API（blobs/trees/commits）、workflow dispatch、artifact 下载、甚至 `PATCH /repos` 转私有都可能瞬时 503——用循环重试（间隔 20–45s，幂等可重复）；**转公开后必须立刻确认转回私有成功**（PATCH 可能 503，需重试直到 `private=True`），期间仓库处于公开状态有风险。`push-via-api.mjs` 无内部重试，外层 PowerShell for 循环包住即可。
- **push-via-api 中文路径编码损坏（2026-08-19 实测）**：经 Git Data API 推送含中文路径文件（如 `说明文档.md`）后，远程树可能出现 `????.md` 幽灵文件（原文件名的编码损坏副本，内容为旧版本）。**推送后必须核对远程树 sha 与本地树 sha 一致**（`git rev-parse HEAD^{tree}` vs 远程 commit tree，Git 树 sha 是内容哈希，一致即等价）；发现多出的 `????` 文件时，用一次性脚本构建含 `{path: "????.md", sha: null}` 删除条目的树（base_tree 增量）重建 commit 清理，勿残留。
- 取 CI 产物：`node scripts/wait-ipa.mjs <runId>`（默认 REPO 同上）。
- **Git Data API 推送不触发 Actions（2026-08-23 实测）**：`push-via-api.mjs` 经 Git Data API 更新 ref，GitHub **不会**为它触发 push 事件驱动的 workflow（Actions 只在真实 git push 时触发）。推送后必须手动 `workflow_dispatch`（`POST /repos/{repo}/actions/workflows/build.yml/dispatches` `{"ref":"main"}`，不受 paths 过滤限制）才能编译。
- **push-via-api 重建 commit 导致远程 sha ≠ 本地 sha（2026-08-23 实测）**：Git Data API 创建 commit 时 parent 指向远程 base（而非本地 commit 的父），远程 commit sha 与本地不同（内容等价）。**匹配 CI run 必须用推送后的远程 HEAD sha**（重新 `GET /git/ref/heads/main`），不能用本地 sha——否则永远匹配不到 run 卡到超时。
- **一键出 .tipa：`GHTOK=<token> node scripts/build-ipa.mjs [commit] [outDir]`**（2026-08-23 新增）：推送（push-via-api）→ workflow_dispatch 触发 → 轮询 run → 下载 packages-bootstrap.zip → 解压 .tipa 到仓库根。注意：本地 git 无远程 base 对象（remote 名是 `superphone` 非 `origin`，无 `origin/main` 引用），脚本 diff 基准显式取 `HEAD^` 传入 push-via-api 第三参，勿用远程 base 做本地 diff。
- **build-ipa.mjs 两个 Windows bug（2026-08-23 实测修复）**：① `git rev-parse ${LOCAL}^` 在 cmd/PowerShell 下 `^` 是转义字符会被吞掉 → localBase 解析成 LOCAL 自身 → diff 为空、0 blob 推送 → **远程树不含该 commit 的任何内容**（CI 编译的还是旧代码）——必须用 `~1`；② `workflow_dispatch` POST 返回 **204 No Content**，`api()` 的 `res.json()` 抛 SyntaxError → CI 未触发——204 时返回 null。**推送后务必核对远程树包含预期文件**（如 `git ls-tree` 或 push-via-api 输出的 MOD 列表），尤其首次修复后（远程树可能缺内容仍在跑 CI）。
- **Windows 快照会丢可执行位**：改 `devkit/*.sh` 或 DEBIAN 脚本后必须恢复 100755，否则 CI before-package 报 Permission denied。
- 网关测试目录 `test/` 里还有一批手工 `verify-*.mjs` 前端验收脚本（不属于 `npm test`），改前端后可选跑。
- **手动起网关验证必须全端口隔离**：`FARM_PORT`/`FARM_REG_PORT`/`FARM_TUNNEL_PORT`/`FARM_DATA_DIR`/`FARM_MDNS=0` 全部覆盖（照 test/ 套件写法），否则默认 18081/18181 会劫持局域网真实设备的注册/隧道连接（2026-08-16 实测踩坑）。
- **运行中的网关不会热加载新路由（2026-08-23 实测）**：Node 启动时即加载 server/index.js 全量路由，此后改代码必须**重启网关进程**才生效；否则新增路由（如 `/api/devices/:id/album`）被 Koa 以 **405 Method Not Allowed** 拒绝、前端报「上传失败」。排查特征：新接口返回 405 / 落到 GET 兜底 `{device}`，而旧功能正常——先查网关进程启动时间（`Get-Process` StartTime）是否早于代码改动时间；`Get-NetTCPConnection -LocalPort 8080` 找 OwningProcess 定位旧进程，`Stop-Process` 后 `npm start` 重启，设备注册/隧道会自动重连。
- 跨端参数契约（如手势 scale）：一端生成、另一端校验的量必须语义一致并两端钳制/兜底，避免"链路通但语义断"（magnitude 位移量 ≠ 间距比例，曾致 pinch scale 超界被设备端拒绝）。
- **剪贴板是显式双向搬运（2026-08-17 起，无自动同步）**：复制=拉（clipboard.get / 0x50 clipboard.get）、粘贴=推（type.paste）；设备端不再监听系统剪贴板、不再自动推送，控制端复制不再自动写设备——改剪贴板功能时勿回归自动同步（平台无写入者身份，自动同步只能启发式且有误判边界，已决策弃用）。
- **CI 秒失败（job 数秒内 failure/cancelled、日志 BlobNotFound）**：先查 check-run annotations（`GET /repos/{repo}/check-runs/{job_id}/annotations`）——billing 拦截（付款失败/支出限额）的权威错误信息在这里，不要误判为 runner 故障或 YAML 语法（2026-08-17 踩坑）。
- **私有仓库 Actions 被 billing 拦截时的应急编译**：临时转 public（`PATCH /repos/{repo}` `{"private":false}`，公开仓库 macOS runner 免费）→ dispatch 编译 → 下载产物 → **立即转回 private**；配合 `_tmp-sync-tree.mjs` 模式的树同步脚本可推送任意树状态（Git Data API base_tree + 删除条目 sha:null）。转公开前扫描仓库确认无硬编码密钥（ghp_/AKIA/PRIVATE KEY/CHANGE_ME 占位符除外）。
- **脚本化删除大段代码后必须做函数深度扫描**：python 按锚点删段可能误删函数闭合（语法配平但作用域错乱、`node --check` 查不出）——用 tokenizer 级深度扫描验证所有顶层函数深度为 0（或预期值）。2026-08-17 两次踩坑：app.js createRbf 闭合误删（copyFromFocusedDevice 不可见→聚焦黑屏）、5801 mgmt 负长度帧死循环。
- **noVNC 握手死锁（2026-08-23 实测，偶发「连接中→10s 超时」的根因）**：`novnc/core/rfb.js` 的 `_negotiateProtocolVersion()` 结尾**必须显式 `return true`**——缺了它时 `_handleMessage` 在 connecting 态的 while 循环里 `!_initMsg()` 即 break，同一 WS message 里版本行之后的握手字节（LibVNCServer 3.8 安全列表 `01 01`）永不处理，noVNC 卡 Security 态、不发 SecurityType，设备 5901 也在等客户端选安全类型 → 双方死锁。粘包 14B 一包必现、分片 12B+2B 两包正常 → 表现为偶发 ~20% 失败且趋连发。**升级 noVNC 或改动其握手代码后必须核对**；排查特征：前端 connTimer 超时诊断 `init=Security wsReady=open rQunread=2 rQhex=0101`、网关侧失败通道 `tx=12 rx=14`。
- **noVNC disconnect 事件原版不带 code（2026-08-23 实测，接管/断开文案与自动退出全部失效的根因）**：`_socketClose(e)` 能拿到 WS close code，但 dispatch 的 disconnect 事件 detail **只有 `{clean}`**——前端 `e.detail.code` 恒为 undefined → 4001/4003/4005/4006 分支永远走默认文案「连接已断开」、4001 自动 exitFocus 不触发。已在 `_socketClose` 存 `_lastCloseCode/_lastCloseReason` 并在 disconnected dispatch 透传（网关与 5801 两处 noVNC 均已 patch）。**升级 noVNC 必须核对 disconnect detail 是否含 code**。
- **MapKit 分类方法在 bootstrap/roothide SDK 未间接导入（2026-08-24 实测）**：`NSValue valueWithMKCoordinate/MKCoordinateValue` 是 MapKit 的 NSValue 分类（`MKGeometry.h`）。**使用方文件必须显式 `#import <MapKit/MKGeometry.h>`**——`RegionSimulator.mm` 有导入所以编过，但 `SimItineraryPlanner.mm` 没导入：rootless/default/roothide 三种 scheme 被其他头间接导入**掩盖错误编译通过**，唯独 bootstrap（roothide theos + iPhoneOS16.5.sdk）报 `no known instance method for selector 'MKCoordinateValue'`（`id` → `CLLocationCoordinate2D` 不可转换）→ **只修 grep 到的编译错误不够，凡是 `[NSValue MKCoordinateValue]`/`valueWithMKCoordinate:` 的消费文件都必须显式导入 MKGeometry.h**；排查特征：仅 bootstrap job 的 `Build package (bootstrap)` 失败、`Diagnose bootstrap app compile (raw xcodebuild)` 却 success（App 不含 manager 代码），其余 3 scheme 全过。
- **并行窗口的 git 恢复会覆盖未提交工作区（2026-08-24 实测）**：多窗口共享本地仓库时，任一窗口执行 `git checkout/restore/stash`（或提交后清理）会把**其他窗口未提交的修改覆盖回 HEAD 版本**（本次 RegionSimulator.h/.mm 修改被回滚，仅保留已写盘的 SimItineraryPlanner.mm 部分）。**防线：设备端/核心文件改动尽量在一次性会话内完成并立即 `git add`+`commit`；跨窗口协作时改完即提交，避免长时间保留未提交修改**；被覆盖后用 git reflog/fsck 找回提交过的内容，未提交的工作区内容无法找回。
- **respring 全量去除记录（2026-08-24，红线见"架构红线"节）**：respring（kill SpringBoard）重启主屏会中断前台 App、打断隧道/注册会话、破坏 daemon 保活链路，已全项目禁用。去除位置清单（后续出现相关问题时按此对照排查）：
  1. `TrollVNC/src/trollvncserver.mm`：删除 `data.respring` 能力共 4 处——前置声明（原 ~L3586）、5901 0x50 分派分支（原 ~L3711）、函数体 `tvExtHandleDataRespring`（原 ~L4293-4302）、5802 分派分支（原 ~L4332）。**外部再调 `data.respring` 将返回"未知操作"**（属预期，勿当 bug）。
  2. `TrollVNC/src/TRCapabilityRegistry.mm`：`device.rename` 移除第 3 步 fork+`killall SpringBoard`（原 ~L721-731）。**改名不再即时生效**——MobileGestalt/DesktopName 写入即时完成，`UIDevice.name` 新值在下次系统重启后更新，属已知行为。
  3. `TrollVNC/prefs/TrollVNCPrefs/Resources/{en,zh-Hans}.lproj/Root.strings`：删除 3 条 respring 本地化（`"Are you sure you want to respring your device?"`、`"Respring"`、`"Respring to Apply Changes"`）——均无 Root.plist 引用（孤儿条目，删除安全）。
  4. 文档未删除、补警示说明：`说明文档.md` §4.8、`outputs/数据填充-编码AI执行规格.md`、`outputs/Filza-数据填充-调研报告.md`、`docs/superpowers/specs/*-generator-design.md`（每篇首处加"⚠️ respring 已禁用"并标注全文描述作废）。
  **排查提示**：数据刷新不生效 → 确认 kill 了对应 daemon（callservicesd/imagent/contactsd）而非依赖 respring；设备改名不更新 → 见第 2 条；外部报"未知操作 data.respring" → 见第 1 条。
- **定位编排联动事件（2026-08-24）**：参数变更感知 = manager 订阅 `prefs-changed` → `reloadFromPrefs` + `_paramsSignature` 含**轨迹文件 mtime 指纹**（新轨迹必重载、从当前位置最近点续播）；注入后 daemon（`_injectPointDict`/`_anchorTick`）发 `notify_post("com.82flex.trollvnc.locsim-update")` 供 App 即时刷新。**mobile plist 位置写回已删除**。**编辑重算（删除/重排）时 App 先写 `mode=anchor` 驻留当前位置（`holdAtCurrentPosition`），重算完成写新轨迹+itinerary 续播**——防重算期间沿已删除/重排的旧轨迹乱走 + 重载回跳；**续播最近点用 haversine**（与 App 截断同度量，平面平方近似在经度方向失真）。**停止态状态栏坐标强制绑定 locationd 真实位置**（无"保留最后模拟坐标"回退）。**App 启动一律停止态**：`readCurrentStatus` 不再恢复定位中，残留 `mode=anchor/itinerary` 强制写 `off`（daemon 对齐停止、locationd 恢复真实）——防"启动即自动开启模拟 / 真实位置被当模拟位置 / 恢复态 Follow 干扰搜索聚焦"，勿回归"恢复上次会话"旧行为。改这条链路时两端事件名/指纹须同步，勿回退"巡检感知 + 从头重放"旧机制。
- **App 原生定位（2026-08-24）**：地图当前位置走 `showsUserLocation`（自定义 MKUserLocation 水滴）+ `MKUserTrackingModeFollow`（原生跟随，拖动自动退出）；真实定位用 `CLLocationManager`（`requestWhenInUseAuthorization`，Info.plist 需 `NSLocationWhenInUseUsageDescription`）。**必须显式 `#import <CoreLocation/CoreLocation.h>`**（MapKit 头不保证带 CLLocationManager 声明，bootstrap SDK 场景同 MKGeometry 教训）。当前位置数据源统一 locationd（模拟开启=注入位置/关闭=真实位置），无 plist 回退——改位置读取时勿加回"轮询 daemon 写回 plist"旧路径。
- **定位坐标禁止硬编码（2026-08-24）**：全项目（App/网关 web/5801）已移除预设城市坐标与硬编码初始坐标（App 初始 `self.cur`=0,0 + 无效坐标守卫；网关 web 与 5801 定位面板仅**手动坐标输入**）。**新增定位 UI/逻辑禁止出现预设坐标或硬编码经纬度**（如 `39.9042,116.4074`），初始视野/聚焦一律以 locationd（真实）为准；测试脚本坐标除外。
