# AGENTS.md（工作区指令 · SuperPhone）

> 机器级全局规则见 `~/.zcode/AGENTS.md`（先加载）；本文件只补充本仓库特有事实。
> **★ 溢出存档**：本文件曾达 67KB **超出工作区指令预算（65536 bytes）→ 加载时末尾被截断**（「已知坑」尾部对 AI 不可见）。2026-09-18 已把其中【已完结的历史演进】搬到 **`docs/历史决策与排查存档.md`**，现 48KB（余量 17KB）。**「已知坑」里出现"见 `docs/历史决策与排查存档.md`"时去那里查**；新增条目请保持精简，**本文件超 62KB 就应再搬一批**。
> **项目知识库**：`说明文档.md` 是唯一真相文档（架构/时序/实现）。改动架构、时序或行为后必须同步更新它（增删改查对应章节）；列表类信息（按键/能力/配置项）只存在于代码真相源，不复制进文档。
> **★ AI 操作层设计文档（2026-09-18 入库，此前在仓库外长期无人知晓）**：
> - `设备操作Agent时序设计-2026-08-28.md` = **主干**（十条哲学 / 角色分层 / 时序 A→E / 资产结构 / 关键机制 12 条 / 结构契约 / 引擎适配现状 §十一）
> - `架构总纲-AI操作层-2026-09-17.md` = **主干下的感知与执行层细化**（四级验证 / 页面表 / 等待策略 / 工具面现状 / 真机坑清单）
> - **★ 冲突时以主干为准**；细化层只补充，不推翻主干结论。**动 AI 操作层前先读主干。**
> **★ 角色纪律（主干 §三，2026-09-18 补记 —— 这是当前最大的认知缺口）**：**DSH 子代理 = 导演**（只派活/监督/沉淀，**不亲自逐步操作设备**）· **UI 视觉代理 = 演员**（专项模型驱动：观察→决策→动作）· **引擎 = 确定性运行时**（回放/命中/护栏，**无模型**）。→ **"让 DSH 模型逐步决定点哪里"是【角色错位】** ✗
> **★ 硬前提现状（2026-09-18 修正）**：当前模型 `deepseek-v4.1-flash` **不支持图像输入**（`read_image` 报错）→ 演员没有眼睛。**但正解不是"配眼睛"**：架构总纲 §5 已论证 **"GUI 工作模型"是伪需求**（看图→出坐标应由设备端零模型原语做），**正解是「少走视觉（公理一）+ 建图标模板库」**。★ 空档：`vision.find_text` ✅ 可用，`vision.find_image` ❌ 缺模板库 → 详见 §5 边界补注 + §17.8.2。
> **★ 参考项目库（2026-09-18）**：12 个手机控制类项目已汇集到 `_research/`（gitignore 不入库）并对齐上游最新。**深研结论（动 AI 操作层前先读）**：`参考项目调研-共同优点-2026-09-18.md`（13 条共同优点 + 8 条差距）· `参考项目深读汇总-面向通用MCP服务器-2026-09-18.md`（3 项目源码级深读）· **逐条结论已接进架构总纲 §17.8（N1-N8）**。★ 一句话：**不是模型差，是没给它该有的手**（57 能力只暴露 5 个 / 动作退化成裸坐标 / 无步骤校验）。
> **★ 网关做「全平台设备基座」方案（2026-09-18，`网关全平台基座方案-2026-09-18.md`）**：用户设想"以 WDA 同基类让 noVNC 作其分支"，调研后**三处修正**——① **Mobile-Agent 没有那个基类**（v3.5 手机框架仅 1137 行薄脚本、`AdbTools` 无基类、三端不共享抽象、iOS 代码 0 命中）；② 真正的"同基类"是 **`mobilerun-core` 的 `VisualRemoteDriver`**（`driver/visual_remote.py`，**HTTP 契约驱动设备**，与我们网关同构）；③ **不"继承 WDA"**（WDA 需设备装 XCTest runner + Mac 编译 + iproxy）。**★ 最低成本路径：网关加 3 个端点（`/devices`、`/screenshot`、`/actions`）即可被 mobilerun 零改动驱动**；**★ 通用钥匙：把 `vision.ocr` 结果伪装成 a11y 树字段形状 → 它们的 `tap_text`/`find_element` 无需理解 OCR 即可跑通**（三家 iOS 定位 100% 依赖 a11y、OCR 零命中，这是我们的独有能力）。**× 不要做 `AsyncEnv`**（被约 250 处 task_evals 判定器当数据访问口）。

## 仓库是什么

内网自用的 iOS 设备群控系统（SuperPhone）。单仓库，四部分（设备端 / 网关 / 脚本 / DSH 插件扩展）：

- `TrollVNC/` — 设备端（Theos 工程）：VNC 服务 + 命令注册表 + App 外壳。`src/` 为核心源码（trollvncserver、TRCapabilityRegistry、TRGatewayClient、TRTunnelClient、STHIDEventGenerator 等）；`app/TrollVNC/` 为 UIKit 外壳；`layout/` 含 5801 直连页文件
- `trollvnc-farm/` — 网关（Node.js ESM）：`server/index.js` 单入口（注册/隧道/控制台），`web/` 为无构建静态前端，`test/` 为测试套件
- `scripts/` — 推送/取包辅助脚本（见"已知坑"）
- `dsh-superphone/` — **DSH（DeepSeek Harness）侧的设备控制面板插件**（本项目的扩展形式之一）：侧边栏 Tab（设备选择器 + **网关单卡 iframe 嵌入** + 执行日志）+ AI 工具面（**17 个工具**：devices / screenshot / tap / **swipe** / **taps** / **long_press** / **delete** / ocr / take_control / home / app_list / app_open / type / end_control / wait_change / wait_stable / screen_hash）。**AI 操作层定位（开发前必读）**：本插件只是《架构总纲-AI操作层-2026-09-17.md》中**唯一已落地的一层**（设备接口面）。**★ 工具面状态（2026-09-18）**：**已补齐** `touch.swipe`（滑动）/ `touch.taps`（连点）/ `touch.longPress`（长按）/ `home`（回主屏）/ `type.delete`（删除键，与 `type.paste` 正交）；**仍待补**：`vision.find_image`（缺模板来源，加了也用不了）· `screen.hash`（注册表注册了但 `trollvncserver` 的 0x50 分派未实现，调用返回「未知操作」）· `touch.pinch` / `doubleTap` · `clipboard.get` —— 详见 `skills/superphone-device/SKILL.md` 的「工具面待补清单」。**复用纪律**：画面区一切交互（悬停提示、点击浮层、聚焦、FAB 退出、系统光标）都由网关前端提供，插件只用 `?only=`/`?syscursor=` 参数嵌入，**不在宿主侧自绘**。构建：host 走 `tsdown`、client 走 `esbuild` 打成 DSH 的 `window.__ModuleLoader__` 模块格式（`node node_modules/tsdown/dist/run.mjs` + `node scripts/build-client.mjs`）。部署 = 插件目录 junction 到 `${DSH_HOME}/profiles/<profile>/node_modules/` + 在 profile 的 `dsh.profile.bundles` 登记 + 重启 profile。`lib/`、`node_modules/`、`data/` 不入库（见其 `.gitignore`）。

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

- **愿景（说明文档 §2.0，开发功能先对照）**：A=局域网经网关 8080 管理所有设备；B=外网访问网关操作内网所有设备（设备主动连 18181 出向）；C=5801 不经过网关独立操作单台设备（局域网直连，不依赖 manager/隧道）。**能力对齐模型**：局域网=5801 页面(WS→5901)+5802(管理)；跨网=8080(WS→隧道 CHAN→5901)+隧道 CMD→注册表(manager)。**关键事实：invoke 不经 5901（manager 直接执行），5901 仅画面；5802 单独实现是进程隔离（愿景 C 独立性保障），非重复。**

- 端口全固定：5901 RFB（画面+命令扩展消息 0x50/0x80）/ 5801 直连页 / 5802 直连页管理 API（HTTP，v3）/ 5902 远程日志端点（manager 常驻，GET /stderr|/stdout 返回崩溃日志尾部 64KB）/ 8080 控制台 / 18081 注册 / 18181 隧道；端口不可调。
- **能力层唯一地基**：设备操作只走 RFB → IOHID 注入，禁止前端自造输入协议；无通用 `/command` 端点（已删，禁止回归）。
- **前端契约两端对齐**：`trollvnc-farm/web/caps.js` 自包含定义（KEY_DEFS 10 / BATCH_CAPS 20 / CONFIG_DEFS 28），设备端 `TRCapabilityRegistry` 只存 executor；新增能力 = 两端各加一条，无上报、无元数据表、无运行时发现。**伪装页数据/定位能力已去除前端按钮 + 外部入口（2026-08-26 直控 App UI + A 档收敛）**：caps.js 删 data.fill/data.clear（BATCH_CAPS 22→20）与 locsim 组（CONFIG_DEFS 33→28）；data.fill/data.clear/sim.itinerary/sim.location.* 的注册表 executor 与 5802/0x50 分派一并移除（**唯一入口 = App 内部直调**）；**data.read 保留**（5802 维护接口 + 注册表愿景 B 闭环）。勿回归"前端面板/外部入口重新实现能力"。
- 单会话约束：设备仅 1 条隧道 + 1 个 5901 连接，同设备同时仅 1 个活跃 VNC 会话；纯隧道（无直连回退、无反向模式）。
- 状态以网关为准：前端不持久化设备状态，刷新一律从网关拉取。
- **剪贴板是显式双向搬运（2026-08-17 起，无自动同步）**：复制=拉（clipboard.get）、粘贴=推（type.paste）；**粘贴的 http 降级（2026-08-18 定稿）**：http 读不到控制端剪贴板 → 粘贴按钮与 Ctrl+V **一律弹输入浮层**（PC/触屏统一，浮层内 Ctrl+V 或回车自动注入），https 直读直贴——已废弃隐藏 textarea「第二次点击/Ctrl+V 提交」方案，禁止回归。
- **光标体系（2026-08-18 定稿）**：触屏端不显示任何光标（无自动消失触点）；PC 端常驻自绘覆盖层光标（网关=深灰圆+浅灰外圈 pcRgba、5801=苹果灰圆）；两端均覆盖 `_refreshCursor`（clear/空操作）屏蔽服务器默认 X 形光标。改光标功能时两端语义对齐、勿回归「自动消失触点」。
- **respring 禁用（2026-08-24 定稿）**：respring（kill SpringBoard）重启主屏会**中断前台 App、打断隧道/注册会话、破坏 daemon 保活链路**。数据直写系统库后 kill 对应 daemon（callservicesd/imagent/contactsd，见 `说明文档.md` §4.8）即可让系统 App 读取新数据——respring 属**冗余设计**。**全项目禁止使用 respring**：数据刷新/UI 生效/改名一律不得 kill SpringBoard；`data.respring` 能力已删除，禁止回归；`device.rename` 不再重启 SpringBoard（改名不即时生效可接受）。
- 验证门槛：IPA 改动必须 CI 编译通过；网关改动必须 `npm test` 通过；未验证不声称完成。

## 开发流程约定（改动前必读）

1. **文档纪律**：改动架构/时序/行为后必须同步 `说明文档.md`（唯一真相文档）对应章节；结构变化（新增/删除/改名模块或函数）同步 CodeWiki.md（模块地图，**不含行号与数量**——定位用 grep，数量以 caps-test 断言为准）；`?v=N` 缓存号递增。**提交与文档同步同一 commit**，避免"代码先行、文档遗忘"。
2. **契约两端对齐**：新增能力/配置 = 网关 `caps.js` + 设备端 `TRCapabilityRegistry` 各加一条；数量变化（KEY_DEFS/BATCH_CAPS/CONFIG_DEFS）只同步 `caps-test.js` 断言（文档不写可断言数字，代码 Wiki 与说明文档一律以断言为准）。5801 分叉 caps.js 与网关 caps.js 互不引用，各自维护。
3. **行为改动带验证**：网关改动 → `npm test`；前端改动 → 手动验收（`test/verify-*.mjs` 可选）+ 缓存号递增；设备端改动 → CI 编译。未验证不声称完成。
4. **注释与实现一致**：改行为时必须同步相邻注释（本项目多次踩坑：注释描述旧方案误导后续开发）；删除功能时全局 grep 其所有变体（含本地化/托管脚本/workflow/文档）确认无残留。
5. **跨端语义一致**：两端（5801 与网关）同一交互必须语义对齐（粘贴/光标/FAB 菜单），改一端时对照另一端，禁止单边改动造成行为分叉。
6. **架构调整必须附「三视角体感走查」（2026-09-17 用户确立，长期约定）**：凡属**架构/机制层面**的调整（新增或删除一层、改契约、换机制、改时序、改判定依据），说明**必须先从实际使用角度**讲清三种情形下**直观可感受到的流程**，并**以此为出发点**说明该调整**对操作造成的影响**：
   - ① **首次执行任务**（探索期／"学"）——最贵且必须付的一次，产出技能卡与 trace；关注成功判定、预算、幂等
   - ② **第二次执行任务**（技能回放期／"用"）——零模型调用、秒级、偶有卡壳后走降级链自愈；关注技能移植性与失效检测
   - ③ **蜂群执行任务**（N 台复制／"复制"）——一次学会全群拥有；风险是失败放大、行为同质化、技能库并发写
   **只讲结构/契约/代码而不讲体感变化的说明视为不完整**（用户会要求重讲）。体感走查不是"附加说明"，而是调整说明的**出发点与主结构**。
7. **提新机制前必答「三问」（2026-09-17 用户确立，长期约定；由一次真实返工提炼）**：凡想**新增**一层/一个机制/一个通道/一个原语之前，必须先回答：
   - **① 消费者是谁 —— 机器还是人？** （机器的输入 vs 给人看的图是**两件事**，混为一谈会导致"用可视化去复刻一份机器判定"这类冗余设计）
   - **② 已有原语能不能直接回答它？** （先 grep 设备端/网关现有能力，再考虑新增；本项目的设备端 `vision.*` / `screen.*` 已覆盖大量感知需求）
   - **③ 它在「0 模型 / 离线」路径里还活着吗？** （校验、定位这类**运行期必需**的能力，必须由**非模型原语**承担，否则 0 AI 自动执行不成立）
   **纪律**：**凡是"用一层新机制去复刻一份已有判定"的设计，都是冗余** —— 三次问完若已有原语能覆盖，就**只做"接进 trace / 触发 on_fail"这类接线工作**，不新增机制。判例见《架构总纲-AI操作层-2026-09-17.md》§4.8.4（执行反馈：三项提案被三问砍成"零新增"）。

## 约定

- 提交用 Conventional Commits + 中文描述（`feat(web):` / `fix:` / `refactor:` / `docs:`），中文沟通。
- 前端改动（`trollvnc-farm/web/`）记得同步 `?v=N` 缓存破坏引用；改 `caps.js` 时注意它和 `TrollVNC/layout/usr/share/trollvnc/webclients/caps.js`（5801 直连页）是**分叉的两个文件**，互不引用。

## 已知坑

- **★★★★ 网关 TLS 与「嵌入客户端」的协议契约（2026-09-18 三轮才修对，必须记住）**：
  网关默认启用 TLS（`FARM_TLS !== '0'` → https + 自签证书），同时用**同一端口按首字节协议分发**（TLS ClientHello → https server；明文 → `httpRedirect`）。原先 `httpRedirect` 对**【所有】明文请求**都 301 到 https（原意只是"browser can omit https://"，方便用户手输 IP）。
  **后果**：任何跑在 http 宿主里的嵌入客户端（DSH 侧边栏插件的 iframe，宿主 `http://127.0.0.1:3080`）**两种协议都进不去** ——
  · 用 **https** → 浏览器不信任自签证书；★ **iframe 里的证书错误不提供"继续访问"入口**（只有主框架才给）→ 页面直接报「网页似乎有问题，或者可能已永久移动到新的 Web 地址」；
  · 用 **http** → 每个请求被 301 到 https → 浏览器把该重定向按**跨源**处理 → 网关不带 CORS 头 → 脚本/接口全被拒（实测 `caps.js?v=15` / `press.js` / `gesture.js` 报 `No 'Access-Control-Allow-Origin' header`）。
  **正确解法（定论）**：**301 只对【顶层导航】生效**，其余一律明文服务。
  ```js
  const dest = (req.headers['sec-fetch-dest'] || '').toLowerCase();
  const isTopLevelNav = dest ? dest === 'document' : (req.headers.accept || '').includes('text/html');
  if (!isTopLevelNav) { requestHandler(req, res); return; }   // iframe/脚本/样式/fetch 都不 301
  ```
  安全语义不变：用户直接访问 `http://IP:8080` 仍是 `document` → 照旧升级到 https。
  **另需两条配套**（缺一不可，实测都会单独导致失败）：① `httpRedirect` 这个 http server **必须挂 `upgrade` 监听**并把明文 WS 转发给真正的 server（否则 iframe 页面出得来但画面永久空白）；② 客户端侧协议要**随宿主**选择（插件 `frameGateway`：宿主 http → iframe 用 http；宿主 https → 必须 https）。
  **★ 走过的两个弯路（勿重犯）**：① 用「请求带嵌入参数（`only`/`syscursor`/`pv`）」判嵌入场景 —— 只覆盖顶层导航，**iframe 内的 `/style.css`、`/api/*` 都不带参数**；② 用「`Referer` 指向嵌入页」补 —— **浏览器加载 `<script>` 时不带可用 Referer**，判据失守（本地用 python 带 Referer 测是 200，所以**自己测"通过"了），这正是"本地测过关、真机仍失败"的典型。
  **★ 方法论教训（本次返工 3 轮的真因）**：**修这类"多段链路"的问题，必须【一次性列出并验证整条链路的每一个请求】，而不是"改一处 → 测一处 → 报通过"**。逐段报通过 = 每次都在下一段撞墙，用户被迫反复反馈。已落成脚本 `scripts/verify-iframe-chain.py`（覆盖 iframe 顶层导航 / 6 个脚本 / 样式 / 7 个 API / 2 个 WS + 顶层导航必须 301 的对照组，共 21 项）——**改网关重定向/协议相关逻辑后必须跑它，全绿才算完成**。

- **★★★★★ 浏览器【永久缓存 301】—— 服务端改好了、浏览器仍用旧跳转（2026-09-18 实测，本次 4 轮返工的最终真因）**：
  **症状**：网关侧修复已生效（`verify-iframe-chain.py` 21 项全绿、curl 全部 200），但用户的浏览器**仍报同样的错**，且错误信息里 URL 一直在"换"（先 `caps.js?v=15`，后 `press.js`、`gesture.js`，再 `rfb.js?v=4`）。
  **根因**：`HTTP 301` 是"永久重定向"，**浏览器默认无限期缓存**。在网关还对所有明文请求 301 的那段时间里，iframe 的若干资源各被 301 过一次，浏览器从此记住 —— **之后它压根不向网关发请求**，直接跳到 https（自签证书）→ CORS 拒绝。
  **★★ 这类故障最坑的地方：网关侧【既看不到请求、也看不到 301】**。本次加了 `FARM_DEBUG_REDIRECT=1` 的诊断日志后才发现：日志里**完全没有**那些 URL 的请求记录。单看服务端会误判成"网关已修好、问题在别处"——前两轮修复就是这样被误导的。
  **三层问题（逐层解决，缺一层都不行）**：
  1. **301 范围过大** → 改为**只对顶层导航生效**（见上一条）。
  2. **301 被永久缓存** → ① 给前端资源**递增版本号**（换新 URL）；② 301 响应加 `Cache-Control: no-store, no-cache, must-revalidate, max-age=0`（杜绝复发）。
  3. **★ 打地鼠没有尽头** → `app.js` → `/novnc/core/rfb.js`（服务端内存 patch）→ **它自己又 import 了 29 个相对模块**（`util/*.js`、`display.js`、`decoders/*.js`、`input/*.js`…），**这些相对 import 全都不带版本号**，逐个加不现实。
  **终极解法：换 iframe 的 host —— `127.0.0.1` → `localhost`** ✓
  浏览器缓存按**完整 URL** 索引，换 host = 整个 URL 空间对浏览器全新，**一次性绕开全部历史缓存的 301**。
  可行性：网关监听 `0.0.0.0`（`localhost` 可达）；证书 SAN 含 `DNS:localhost`（https 场景同样可用）。实现见插件 client 的 `frameGateway`。
  **★ 诊断手段（务必保留）**：`FARM_DEBUG_REDIRECT=1` 启动网关 → 每个明文请求记录 `method / path / Sec-Fetch-Dest / Origin / Referer / 去向`；
  再用 `scripts/analyze-gateway-redirect-log.py` 区分**【浏览器真实请求】**（带 Referer/Origin）与**【脚本请求】**（两者都不带），并直接给出"有没有非顶层导航被 301"的结论。
  **这是定位"服务端看不见"类问题的唯一可靠手段 —— 不必再让用户按 F12。**
  **★ 纪律**：
  - **凡改前端资源（`web/*.js|css`、noVNC patch），必须递增引用处的 `?v=N`**，并同步 iframe 的 `pv`；
  - **凡改协议/重定向/路由，先跑 `verify-iframe-chain.py`**，再用诊断日志确认【浏览器真的在发请求】——**服务端 200 ≠ 浏览器拿到了**；
  - **判断"修好了没有"要看浏览器行为，不能只看 curl**：本次 curl 全绿而浏览器全程失败，差异就在"浏览器有没有真的发这个请求"。
- **★ 暴露一个「从未被调用过」的既有能力 = 给它做首次验收（2026-09-18 实测，血泪）**：给 AI 工具面新增一个透传工具时，**不能假设"设备端已实现 = 可用"** —— 那个能力的 executor 可能**从未被真实调用过**，里面藏着从未触发的 bug。**真实事故**：`superphone_taps` 透传设备端 `touch.taps`，首次调用即把 `trollvncmanager` 打死（`NSParameterAssert(delay > 0.0)` 断言写反，而所有调用者都传 0 → NSException → abort），设备 5901/5802/5801 三个端口全不通、网关 `online=false`；崩溃报告历史显示该 bug 在 8-24 也引爆过 3 次。**纪律**：① 新增透传工具后，**先在真机跑一次最小调用**再交付；② 崩溃报告在设备 `/var/mobile/Library/Logs/CrashReporter/<proc>-<时间>.ips`，**`_userInfoForFileAndLine` 符号 = `NSParameterAssert`/`NSAssert` 失败**，配 `EXC_CRASH + SIGABRT + abort() called` 即可定性；③ **判"能不能用"的黄金判据**：调用后**进程是否还活着 + 有没有新崩溃报告**（不能只看 ack ok=true —— 它是"已投递"）。**相关**：`screen.hash` 是同一族的另一面 —— 注册表里注册了，但 `trollvncserver` 的 0x50 分派没实现，调用返回「未知操作」。
- **实际远程仓库是 `78725449/SuperPhone`（私有，2026-08-15 单仓库化迁移后启用）**；`78725449/TrollVNC` 是迁移前的旧 fork（已废弃）。
- **github.com 直连常被网络阻断** → 推送走 `scripts/push-via-api.mjs`（Git Data API，api.github.com 正常）：`GHTOK=<token> node push-via-api.mjs <本地commit> <远程base> [本地base]`（默认 REPO=78725449/SuperPhone、BRANCH=main，CWD 可用环境变量覆盖；支持大文件与 base tree 去重；远程 main 与 base 不符会拒绝）。**（2026-09-17 实测补坑）Windows 上必须显式覆盖 `CWD`**：脚本默认 `CWD` 是**另一个项目的旧路径**（`C:\Users\Administrator\Documents\ChatGPT\New project`），不覆盖时 `execSync({cwd})` 抛 **ENOENT 且错误里出现的路径是 `C:\Windows\system32\cmd.exe`** ——极易误判成"沙盒拦截 node 子进程"或"环境缺 cmd.exe"（本次就误判了一轮；实测 `execSync/execFileSync/spawnSync` 三种方式在 DSH 下均正常，`cmd.exe` 也确实存在），**真因是 cwd 不存在**。正确调用：`$env:CWD = (Get-Location).Path; node scripts/push-via-api.mjs <local> <remoteBase> <localBase>`。
- **GitHub API 间歇性 503（2026-08-18 实测）**：Git Data API（blobs/trees/commits）、workflow dispatch、artifact 下载、甚至 `PATCH /repos` 转私有都可能瞬时 503——用循环重试（间隔 20–45s，幂等可重复）；**转公开后必须立刻确认转回私有成功**（PATCH 可能 503，需重试直到 `private=True`），期间仓库处于公开状态有风险。`push-via-api.mjs` 无内部重试，外层 PowerShell for 循环包住即可。
- **push-via-api 中文路径编码损坏（2026-08-19 实测）**：经 Git Data API 推送含中文路径文件（如 `说明文档.md`）后，远程树可能出现 `????.md` 幽灵文件（原文件名的编码损坏副本，内容为旧版本）。**推送后必须核对远程树 sha 与本地树 sha 一致**（`git rev-parse HEAD^{tree}` vs 远程 commit tree，Git 树 sha 是内容哈希，一致即等价）；发现多出的 `????` 文件时，用一次性脚本构建含 `{path: "????.md", sha: null}` 删除条目的树（base_tree 增量）重建 commit 清理，勿残留。
- 取 CI 产物：`node scripts/wait-ipa.mjs <runId>`（默认 REPO 同上）。
- **Git Data API 推送不触发 Actions（2026-08-23 实测）**：`push-via-api.mjs` 经 Git Data API 更新 ref，GitHub **不会**为它触发 push 事件驱动的 workflow（Actions 只在真实 git push 时触发）。推送后必须手动 `workflow_dispatch`（`POST /repos/{repo}/actions/workflows/build.yml/dispatches` `{"ref":"main"}`，不受 paths 过滤限制）才能编译。
- **push-via-api 重建 commit 导致远程 sha ≠ 本地 sha（2026-08-23 实测）**：Git Data API 创建 commit 时 parent 指向远程 base（而非本地 commit 的父），远程 commit sha 与本地不同（内容等价）。**匹配 CI run 必须用推送后的远程 HEAD sha**（重新 `GET /git/ref/heads/main`），不能用本地 sha——否则永远匹配不到 run 卡到超时。
- **一键出 .tipa：`GHTOK=<token> node scripts/build-ipa.mjs [commit] [outDir]`**（2026-08-23 新增）：推送（push-via-api）→ workflow_dispatch 触发 → 轮询 run → 下载 packages-bootstrap.zip → 解压 .tipa 到仓库根。注意：本地 git 无远程 base 对象（remote 名是 `superphone` 非 `origin`，无 `origin/main` 引用），脚本 diff 基准显式取 `HEAD^` 传入 push-via-api 第三参，勿用远程 base 做本地 diff。
- **build-ipa.mjs 两个 Windows bug（2026-08-23 实测修复）**：① `git rev-parse ${LOCAL}^` 在 cmd/PowerShell 下 `^` 是转义字符会被吞掉 → localBase 解析成 LOCAL 自身 → diff 为空、0 blob 推送 → **远程树不含该 commit 的任何内容**（CI 编译的还是旧代码）——必须用 `~1`；② `workflow_dispatch` POST 返回 **204 No Content**，`api()` 的 `res.json()` 抛 SyntaxError → CI 未触发——204 时返回 null。**推送后务必核对远程树包含预期文件**（如 `git ls-tree` 或 push-via-api 输出的 MOD 列表），尤其首次修复后（远程树可能缺内容仍在跑 CI）。
- **Windows 快照会丢可执行位**：改 `devkit/*.sh` 或 DEBIAN 脚本后必须恢复 100755，否则 CI before-package 报 Permission denied。
- **build-ipa diff 基准陷阱（2026-09-13 实测，血泪）**：`build-ipa.mjs` 默认以 `HEAD~1` 作 push-via-api 的 localBase——**只带出最后一个 commit 的变更**。本地积压多个未推送 commit（如一次重构 5 个 commit）时，**前面的 commit 全部不上远程**（远程树 = 旧代码 + 最后一个 commit 的文件），CI 编译旧代码、部署后真机行为与源码不符，极难排查（本次症状：改了 wait 逻辑但设备行为不变，直到比对二进制代码段才定性）。**纪律**：① 批量推送手动跑 `node scripts/push-via-api.mjs <local> <remoteBase> <localBase>`，localBase 取「本次要推送内容的前一个已推送 commit」，并核对输出的 MOD 列表覆盖全部改动文件；② 推送后核对**远程树 sha == 本地树 sha**（`git rev-parse 'HEAD^{tree}'`）；③ CI 触发后核对 **run.head_sha == 推送后的远程 ref sha**（推/dispatch 并发会吃到旧 head——本次 run 34580383465 白跑一轮）；④ **部署前验证产物二进制含新代码**（`grep -a` 搜新字符串；必要时比对设备二进制与本地构建产物**代码段 md5**——TrollStore 重签名只改尾部，代码段应完全一致）。
- **设备端部署与手动拉起服务链（2026-09-13 实测可用路径）**：SSH 环境（RemoteHelper，root/alpine）无 `uiopen`/`open`/真 `launchctl`，TrollStore 安装 tipa 会杀掉 App 且**不会自动重启**（`trollstorehelper launch` 只拉起挂起壳，ServiceCoordinator 不跑）。命令行安装：`<TrollStore.app>/trollstorehelper install <tipa>`；验证时**绕过 App 直接拉起 daemon**：`nohup <APP>/trollvncmanager < /dev/null > /var/tmp/manager.log 2>&1 &`——**必须绝对路径**（manager 单例锁拒绝 `./trollvncmanager`）、**stdin 必须 `< /dev/null`**（否则 RemoteHelper exec 通道挂起至超时），manager 随即 watchdog 拉起 server/5802，等效 App ServiceCoordinator 的 spawn。tipa 传输用 base64 分块 echo（设备端解码器 `<TrollStoreRemoteHelper.app>/fakeroot/bin/base64`），传后 `wc -c` 核对字节数。
- **【运维】设备重启后 / 装包后链路恢复 + 「App 角色」认知（2026-09-13 实测定案）**：**症状**——设备重启或安装新 tipa 后，网关里设备离线、缩略图与大屏控制都不可用。**根因**——tipa 不含 LaunchDaemon（`layout/Library/LaunchDaemons/*.plist` 只有越狱 .deb 才有），daemon 链**唯一拉起者 = App 的 ServiceCoordinator**（3s 探活 127.0.0.1:46751，失败即 spawn manager）；装包时 TrollStore 替换二进制 → manager 的 vnode-delete watchdog 自退 → 整条链（manager→server）被拆；设备重启则进程全无。**恢复动作（二选一）**：① **点开一次手机上的 TrollVNC App**（推荐：随后 ServiceCoordinator + manager watchdog 双保险保活；设备重启后也只需此一步）；② SSH 手动拉起（见上一条命令）。**链路自检**：`ps aux | grep -E 'trollvncmanager|trollvncserver -daemon'` 两进程齐全；`lsof -i :5901` 有 LISTEN；网关 `/api/devices` 该设备 online=true。**认知澄清（勿误判）**：**App 不参与任何画面数据链路，它只是「启动器 + 保活器」**——缩略图链路（网关 SnapshotPoller → 隧道 invoke `screen.snapshot` → manager 注册表 → HTTP 回环 5802 → server 按需取帧+JPEG）与大屏链路（浏览器 WS → 网关 → 隧道会话通道 → manager TRTunnelClient → connect 5901 → server RFB）**都只依赖 manager + server 两个进程**。因此「App 没在前台，但缩略图/大屏正常」是**完全正常**的现象（只要 daemon 链在跑）；反之「链没起来时两者都不可用」也不是 App 的锅。另：设备端日志出现 `webSocketsHandshake: unknown connection error` + `Client <网关IP> gone` = 有客户端用 **WebSocket 直连 5901**（5801 直连页路径）握手失败，与网关大屏（走隧道会话通道的裸 RFB 字节）**不是同一条路径**，排查时勿混淆；大屏会话被顶掉的日志特征是前端 WS `4001 preempted by another controller`（另一控制端持有 ctrl 会话）。
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
- **窄容器嵌入网关：用 `?only=<deviceId>` + `?syscursor=1` 复用网关实现，禁止在宿主侧复刻（2026-09-17 实测）**：把控制台嵌进窄容器（DSH 侧边栏插件面板 iframe ≈300-400px 等）时有两个坑与两个参数——① **`isMobile()`（`max-width: 900px`）把窄 iframe 判成触屏端** → 光标走"屏蔽"分支（`clear()` → 系统光标 `none` + 自绘圆点清空），鼠标移入画面毫无反应；**正解是 `?syscursor=1`（保持系统鼠标）**：让 noVNC 光标子系统在本会话完全不动 cursor（覆盖 `_refreshCursor` + `_cursor.change` + `_cursor.clear`，后两者由 rfb.js 内部直接调用；并清掉挂载时已设的 `cursor:none`）→ 窄容器里保持系统默认箭头。**❌ 不可改用"强制走 PC 分支"**：那会启用自绘圆点，而**触屏端"无任何光标"是刻意设计**（noVNC 在触屏上本会画 fallback 圆点，是网关 clear 屏蔽掉的），真触屏设备带该参数即破坏红线。② **嵌入方若只过滤卡片，顶栏计数与直控/批量/布局、批量条仍会出现** → 加 `?only=<deviceId>` 走单卡模式：只渲染该设备一张卡并填满容器 + `body.single-card` 隐藏 `header`/`#batchBar`，`#wall.single-tile .tile-bar` 隐藏卡片底栏（状态点/设备名/状态/⋯ 菜单——由嵌入方的选择器承载设备名与状态，卡片只留画面）；（保留 `#tileMenu`/`#editModal`/`#fab`+`#opsMenu`/`#kbdInput` 与聚焦视图）。`only` 的过滤**只在渲染循环 + directMode 补建**，数据源/计数/聚焦校验/10+ 处 `wallInstances` 遍历都不动，**缺省行为完全不变**（窄屏 `#wall` 的 2 列基础规则不受影响——`.single-tile` 无参数时不匹配）。**纪律**：窄容器嵌入一律加这两个参数复用网关的光标/卡片/缩略图/聚焦/退出，**禁止在宿主侧另写一套**，且**任何新参数都不得让触屏端出现光标**。
- **控制状态三态互斥 + 快照推图必须按内容比较（2026-09-17 实测）**：① `controlState ∈ {direct,gateway,ai,idle}` 是**互斥单值**，由网关在 `/api/devices` 合成：`direct`/`gateway` 来自设备 FT_STATE（5801 / 隧道会话），**`ai` 来自 `sendDeviceCmd` 对输入类能力（`^(touch|type|key)\.`）的观测**——AI 的输入必经此处（插件工具/MCP/脚本/curl 全覆盖），**设备端零改动且不漏源**；读取类（`screen.`/`vision.`/`app.`）不触发，故 SnapshotPoller 的 `screen.snapshot` 轮询不会自激。会话优先于 AI（与 `guardHumanControl` 同一事实）。AI 会话结束 = 显式 `control.end`（网关拦截，不下发设备）或空闲 **180s** 兜底。② **SnapshotPoller 不得按 `seq` 去重**：`seq` 由采集管线逐帧 pHash 驱动，**无消费者时采集停止 → seq 冻结 → 前端画面永久定格**（实测三帧 jpeg md5 各不同而 seq 恒 1984）；必须**比较 JPEG 内容**（`this.jpeg !== ack.jpeg`）。`seq` 只服务 `screen.wait`/`waitStable`（有等待者→采集在跑→自洽）。
- **变化检测（事件源）不得放在推流背压之后（2026-09-17 真机确诊并修复）**：`handleFramebuffer` 的 busy-drop（`gInflight >= gMaxInflightUpdates` → `return`）**必须位于逐帧 pHash 变化检测之后** —— 它是 `screen.wait`/`wait_change` 的事件源，与推流背压无关。原实现放在其前面，一旦 `gInflight` 泄漏（客户端异常断开致 `displayFinishedHook` 不配对；设备日志特征是先有 `FramebufferUpdate : N` 统计、之后再无 RFB 会话）就会**永久丢帧**：`gChangeSeq` 冻结 → AI 的 wait 永久超时（实测 `no change within 15000ms` / 网关 504），而**看板缩略图完全不受影响**（它走按需取帧 + 比较 JPEG 内容）。**确诊特征**：出现「`waitStable` 能正常返回、`wait` 永远超时」这对组合即可锁定（waitStable 读的 `gLastChangeTime` 是 wait 挂起时设的，不依赖 pHash）。**修复**：① busy-drop 下移到变化检测之后（下移后 `return` 前必须补 `CVPixelBufferUnlockBaseAddress`，因该处已 lock）；② 客户端归零时 `gInflight.exchange(0)` 兜底 + 日志。**排查纪律**：先确认「屏幕是否真的在变」（连续三次 `screen.snapshot` 比对 jpeg md5）——画面真静止时 wait 超时是**正确行为**，别误判为 bug。
- **设备端 SSH 与装包路径（2026-09-17 实测）**：设备 SSH 是 **TrollStore RemoteHelper 的 Go sshd**，端口 **1223**（同 App 的 Web 界面在 **1222**，`GCDWebServer`，页面含 `restart_server` / `restart_sshd` 按钮，接口 `POST /restart_sshd`、`GET /log`）。**端口 ECONNREFUSED = sshd 没跑** → 先 `POST http://10.0.0.242:1222/restart_sshd` 拉起。**该 sshd 的限制**：不支持 **sftp subsystem**（`open_sftp` → `Channel closed`）；`cat > file` 传大文件会让 channel 挂住（Go sshd 等后台子进程）；**可靠路径 = base64 分块**：本地 base64 → 分块 `echo -n '<chunk>' >> /var/tmp/x.b64`（30000 字符/块，实测 3.9MB → 174 块 3 秒）→ 设备端 `<RemoteHelper.app>/fakeroot/bin/base64 -d` 解码 → `wc -c` 核对字节数。**设备无 curl/wget/python/nc**，不能"让设备自己下载"。**拉起 daemon 要 fire-and-forget**（发 `nohup ... < /dev/null > log 2>&1 &` 后**不要读 stdout**，否则 channel 挂住）。**Windows 侧无 ssh 客户端** → 用 **paramiko**（已装 5.0.0；`connect(..., banner_timeout=30, auth_timeout=30, allow_agent=False, look_for_keys=False)`；该 sshd 对短超时敏感，报 "Error reading SSH protocol banner" 通常只是超时太短）。
- **MapKit 分类方法在 bootstrap/roothide SDK 未间接导入（2026-08-24 实测）**：`NSValue valueWithMKCoordinate/MKCoordinateValue` 是 MapKit 的 NSValue 分类（`MKGeometry.h`）。**使用方文件必须显式 `#import <MapKit/MKGeometry.h>`**——`RegionSimulator.mm` 有导入所以编过，但 `SimItineraryPlanner.mm` 没导入：rootless/default/roothide 三种 scheme 被其他头间接导入**掩盖错误编译通过**，唯独 bootstrap（roothide theos + iPhoneOS16.5.sdk）报 `no known instance method for selector 'MKCoordinateValue'`（`id` → `CLLocationCoordinate2D` 不可转换）→ **只修 grep 到的编译错误不够，凡是 `[NSValue MKCoordinateValue]`/`valueWithMKCoordinate:` 的消费文件都必须显式导入 MKGeometry.h**；排查特征：仅 bootstrap job 的 `Build package (bootstrap)` 失败、`Diagnose bootstrap app compile (raw xcodebuild)` 却 success（App 不含 manager 代码），其余 3 scheme 全过。
- **并行窗口的 git 恢复会覆盖未提交工作区（2026-08-24 实测）**：多窗口共享本地仓库时，任一窗口执行 `git checkout/restore/stash`（或提交后清理）会把**其他窗口未提交的修改覆盖回 HEAD 版本**（本次 RegionSimulator.h/.mm 修改被回滚，仅保留已写盘的 SimItineraryPlanner.mm 部分）。**防线：设备端/核心文件改动尽量在一次性会话内完成并立即 `git add`+`commit`；跨窗口协作时改完即提交，避免长时间保留未提交修改**；被覆盖后用 git reflog/fsck 找回提交过的内容，未提交的工作区内容无法找回。
- **sim.* 外部能力已收敛（2026-08-26 起）**：`data.fill` / `data.clear` / `sim.itinerary` / `sim.location.*` 的**外部入口（注册表 + 0x50 + 5802）已全部移除**，唯一入口 = **App 内部直调**（伪装页三 Tab + 定位 UI）。外部再调返回「未知操作」属**预期**，勿当 bug。排查数据/定位不生效 → 先查 App 伪装页/定位 UI 直调链路。daemon 侧的注入机制演进史（双域配置 / 注入必重启 / 时间戳分辨新旧 / prefs-changed 热重载风暴 / 区域漫游随机模式 等）已移入 `docs/历史决策与排查存档.md`。
- **App 原生定位（2026-08-24）**：地图当前位置走 `showsUserLocation`（自定义 MKUserLocation 水滴）+ `MKUserTrackingModeFollow`（原生跟随，拖动自动退出）；真实定位用 `CLLocationManager`（`requestWhenInUseAuthorization`，Info.plist 需 `NSLocationWhenInUseUsageDescription`）。**必须显式 `#import <CoreLocation/CoreLocation.h>`**（MapKit 头不保证带 CLLocationManager 声明，bootstrap SDK 场景同 MKGeometry 教训）。当前位置数据源统一 locationd（模拟开启=注入位置/关闭=真实位置），无 plist 回退——改位置读取时勿加回"轮询 daemon 写回 plist"旧路径。
- **定位坐标禁止硬编码（2026-08-24）**：全项目（App/网关 web/5801）已移除预设城市坐标与硬编码初始坐标（App 初始 `self.cur`=0,0 + 无效坐标守卫）；**网关 web 与 5801 定位面板已去除（2026-08-26 直控 App UI），定位操作完全交 App 定位 UI（设备端原生地图）**。**新增定位 UI/逻辑禁止出现预设坐标或硬编码经纬度**（如 `39.9042,116.4074`），初始视野/聚焦一律以 locationd（真实）为准；测试脚本坐标除外。
- **中国区坐标语义双层（2026-09-04 治理定案，纠正 8-30 误断言）**：Apple 地图瓦片与 MapKit API 层（annotation/overlay/convertPoint/MKDirections/MKLocalSearch）= **GCJ 语义（瓦片系）**；locationd 广播 = **WGS-84 语义**（MapKit 显示 MKUserLocation 时自动偏移）。App 编排世界（锚点/路线/self.cur/锁基线）统一存**瓦片系数值**；两个边界转换：①`injectPoint:` 出口 GCJ→WGS（CoordTransform，对外 App 拿真实位置）；②`handleLocationUpdate` 入口 WGS→GCJ（广播值转回瓦片系参与计算）。8-30 曾误断言"MapKit API 层统一 WGS-84"删 CoordTransform，致水滴双重偏移东南 ~500m + 对外坐标系统性偏移；排查"当前位置偏移"先核对此双层语义。**当前位置显示 = 单 MKUserLocation**（`showsUserLocation` 恒 YES）——自驱水滴双模式已删除（切换死角曾致播放显示冻结死锁：daemon 开定位后自驱水滴被移除而蓝点未启用，叠加 self.cur=0,0 无效基线时 25m 锁永锁；25m 锁现带 0,0 守卫）。
- **AutoLayout 约束视图的 layer 内容布局前 bounds 为 0（2026-08-25 实测）**：`translatesAutoresizingMaskIntoConstraints=NO` 的视图在约束布局前 `bounds` 为 (0,0)——直接 `layer.frame = view.bounds` 的 CAGradientLayer/CAShapeLayer 会变成 0×0 不显示（本次 FAB 渐变金底近乎透明根因）。**必须**：创建时用固定尺寸兜底（约束已知固定 56×56 就写死）+ `viewDidLayoutSubviews` 里同步 `layer.frame = view.bounds`。排查特征：子 layer 内容看不到、只露出 `backgroundColor`（或 clearColor 时近乎透明）。
- **5801 直连页可用能力 ≠ 注册表能力（2026-08-25，data.clear 踩坑）**：`TRCapabilityRegistry` 注册（manager 进程）只保证网关 invoke 通道可用；5801 直连页 mgmtRequest 走设备 **5802 HTTP → trollvncserver 进程**，若只在注册表注册而 5802/0x50 分派（`tvHttpApiDispatch`/`tvExtHandleMessage`）没补分支，直连页会收「未知操作」。**新增数据/管理类能力三处补齐**：注册表 + 0x50 分派 + 5802 分派（handler 用 `tvExtHandle*` 纯函数，cl 传 NULL 复用）。
- **caps.js 改动必须递增 `?v=N`（2026-08-25 补坑）**：阶段 2 改 `trollvnc-farm/web/caps.js`（+data.clear，BATCH_CAPS 21→22）漏递增 `app.js` 里 `caps.js?v=13` → 浏览器缓存旧 caps 不出现新能力。**凡改 caps.js/前端静态资源，同 commit 递增引用处 `?v=N`**（网关 app.js 的 caps.js/rfb.js 引用号、index.html 的 app.js/style.css 引用号）。
- **App target（pbxproj）改动只在 bootstrap job 暴露**：default/rootless/roothide 三 scheme 用 theos gmake **直接编译源码、不读 xcodeproj**，仅 bootstrap 走 `xcodebuild -scheme TrollVNC` → **App target 改动可能三 scheme 全过而 bootstrap 失败**。排查特征：`Build package (bootstrap)` failure 而 `Diagnose bootstrap app compile` success。5 个具体坑（pbxproj ID 唯一 / `+` 要引号 / HEADER_SEARCH_PATHS 被覆盖 / `.mm` 的 C 函数要 `extern C` / ObjC 字典 key 要 `@`）见 `docs/历史决策与排查存档.md`。
- **并行 SearchReplace 会互相覆盖（2026-08-25 实测）**：同一条消息里对同一文件发多个 SearchReplace，竞态导致只有最后一个生效（本次 pbxproj 3 处引号只提交 1 处）。**对同一文件的多次编辑必须串行**（一条消息一个编辑，或合并成一次编辑）。
- **CI 产物 .tipa 体积骤降 = 解压截断（2026-08-25 实测）**：下载 packages-bootstrap.zip 后 `Expand-Archive` 解压时磁盘空间不足 → 解压被静默截断 → 复制出的 .tipa 缺核心文件（App 主二进制/BRPickerView.bundle/trollvncmanager）只剩 1.5MB（真实 3.9MB）。**解压前确认磁盘空间；.tipa 体积异常变小必须 `tar -tf` 校验条目数与关键文件**（tar 报 "Error exit delayed" = 截断），勿直接安装。
- **数据填充/伪装页两条活纪律（保留）**：① **CNContactStore 写删不 kill `contactsd`**（否则打断 XPC → 「通信错误」）；**sqlite 直写（calls/sms）才 kill 对应 daemon**；**勿回归"直写 AddressBook.sqlitedb"**（缺 FTS/触发器，系统列表不显示）。② **伪装页能力收敛 A 档（2026-08-26 定案）**：数据填充/定位**写操作唯一入口 = App 内部直调**；**新功能开发前先按 说明文档 §2.0「能力实现分类指南」判定 A/B 类**——App 里点的 → A 类（内部直调）；控制端/脚本调的 → B 类（三处补齐）。其余定案细节（清空联系人 / 短信软删与触发器 / 城市名归一 / ZHANDLE / 号段过滤 / 服务短信发件号 / 每日轨迹 / 结果 UI 契约 等 ①-⑯）见 `docs/历史决策与排查存档.md`。
