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
cd trollvnc-farm && npm test         # 10 个测试套件（smoke/tunnel/register/dedupe/caps/gesture/pending-replay/press/order/events）——网关改动必须全过
cd TrollVNC && bash devkit/build-all.sh   # 设备端本地构建（仅 macOS + Theos）
```

- **设备端无 lint/typecheck**；**Windows 不能本地构建**，出 .tipa 只能走 CI。
- **CI**（`.github/workflows/build.yml`）：push `main` 触发 macOS 编译 4 种 scheme——default/rootless/roothide 出 `.deb`，bootstrap 出 `.tipa`（TrollStore 安装产物）；可选 `workflow_dispatch` 输入（is_managed 打 Managed.plist 预置、desktop_name、port、view_only、scale、frame_rate_spec、modifier_map）。**push 带 paths 过滤（2026-08-18）**：仅 `TrollVNC/**` 或 workflow 自身变更才触发编译，纯网关/脚本/文档改动不触发（避免私有仓库 billing 拦截秒失败）；`workflow_dispatch` 手动触发不受 paths 限制。
- 版本号在 `TrollVNC/Makefile` 的 `PACKAGE_VERSION`（现 0.0.1）。

## 架构红线（改任何端前先读 `说明文档.md`）

- 端口全固定：5901 RFB（画面+命令扩展消息 0x50/0x80）/ 5801 直连页 / 5802 直连页管理 API（HTTP，v3）/ 8080 控制台 / 18081 注册 / 18181 隧道；端口不可调。
- **能力层唯一地基**：设备操作只走 RFB → IOHID 注入，禁止前端自造输入协议；无通用 `/command` 端点（已删，禁止回归）。
- **前端契约两端对齐**：`trollvnc-farm/web/caps.js` 自包含定义（KEY_DEFS 10 / BATCH_CAPS 20 / CONFIG_DEFS 29），设备端 `TRCapabilityRegistry` 只存 executor；新增能力 = 两端各加一条，无上报、无元数据表、无运行时发现。
- 单会话约束：设备仅 1 条隧道 + 1 个 5901 连接，同设备同时仅 1 个活跃 VNC 会话；纯隧道（无直连回退、无反向模式）。
- 状态以网关为准：前端不持久化设备状态，刷新一律从网关拉取。
- **剪贴板是显式双向搬运（2026-08-17 起，无自动同步）**：复制=拉（clipboard.get）、粘贴=推（type.paste）；**粘贴的 http 降级（2026-08-18 定稿）**：http 读不到控制端剪贴板 → 粘贴按钮与 Ctrl+V **一律弹输入浮层**（PC/触屏统一，浮层内 Ctrl+V 或回车自动注入），https 直读直贴——已废弃隐藏 textarea「第二次点击/Ctrl+V 提交」方案，禁止回归。
- **光标体系（2026-08-18 定稿）**：触屏端不显示任何光标（无自动消失触点）；PC 端常驻自绘覆盖层光标（网关=深灰圆+浅灰外圈 pcRgba、5801=苹果灰圆）；两端均覆盖 `_refreshCursor`（clear/空操作）屏蔽服务器默认 X 形光标。改光标功能时两端语义对齐、勿回归「自动消失触点」。
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
- **Windows 快照会丢可执行位**：改 `devkit/*.sh` 或 DEBIAN 脚本后必须恢复 100755，否则 CI before-package 报 Permission denied。
- 网关测试目录 `test/` 里还有一批手工 `verify-*.mjs` 前端验收脚本（不属于 `npm test`），改前端后可选跑。
- **手动起网关验证必须全端口隔离**：`FARM_PORT`/`FARM_REG_PORT`/`FARM_TUNNEL_PORT`/`FARM_DATA_DIR`/`FARM_MDNS=0` 全部覆盖（照 test/ 套件写法），否则默认 18081/18181 会劫持局域网真实设备的注册/隧道连接（2026-08-16 实测踩坑）。
- 跨端参数契约（如手势 scale）：一端生成、另一端校验的量必须语义一致并两端钳制/兜底，避免"链路通但语义断"（magnitude 位移量 ≠ 间距比例，曾致 pinch scale 超界被设备端拒绝）。
- **剪贴板是显式双向搬运（2026-08-17 起，无自动同步）**：复制=拉（clipboard.get / 0x50 clipboard.get）、粘贴=推（type.paste）；设备端不再监听系统剪贴板、不再自动推送，控制端复制不再自动写设备——改剪贴板功能时勿回归自动同步（平台无写入者身份，自动同步只能启发式且有误判边界，已决策弃用）。
- **CI 秒失败（job 数秒内 failure/cancelled、日志 BlobNotFound）**：先查 check-run annotations（`GET /repos/{repo}/check-runs/{job_id}/annotations`）——billing 拦截（付款失败/支出限额）的权威错误信息在这里，不要误判为 runner 故障或 YAML 语法（2026-08-17 踩坑）。
- **私有仓库 Actions 被 billing 拦截时的应急编译**：临时转 public（`PATCH /repos/{repo}` `{"private":false}`，公开仓库 macOS runner 免费）→ dispatch 编译 → 下载产物 → **立即转回 private**；配合 `_tmp-sync-tree.mjs` 模式的树同步脚本可推送任意树状态（Git Data API base_tree + 删除条目 sha:null）。转公开前扫描仓库确认无硬编码密钥（ghp_/AKIA/PRIVATE KEY/CHANGE_ME 占位符除外）。
- **脚本化删除大段代码后必须做函数深度扫描**：python 按锚点删段可能误删函数闭合（语法配平但作用域错乱、`node --check` 查不出）——用 tokenizer 级深度扫描验证所有顶层函数深度为 0（或预期值）。2026-08-17 两次踩坑：app.js createRbf 闭合误删（copyFromFocusedDevice 不可见→聚焦黑屏）、5801 mgmt 负长度帧死循环。
