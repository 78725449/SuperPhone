# M5 · App 原生伪装页开发计划（待确认）

> 范围：App 伪装页固化（生产主路径）+ 网关定位面板对齐 + 文档/CI/真机验收。
> 实施依据：`outputs/改定位-编码AI执行规格.md` §3.3（本地通道）/§3.5（工程改动）/§3.6（伪装页定位 tab）。
> 本版含「契约审查」：对照执行规格 + AGENTS.md 两端对齐红线，剔除超范围/未调研项。

---

## 0. 原型定位原则（先读）

`outputs/locsim-app-prototype.html` 只贡献**两个参考维度**，不具备任何决定权：

1. **交互链路**：操作顺序与反馈闭环（首击=起点、再击=加路线、长按=区域、停止/搜索/FAB 位置等）
2. **布局**：页面结构（全屏地图、浮层、参数面板、四 Tab 切换）

**所有参数定义、行为定义、数据字段，一律以代码真相源为准**：
- 定位：设备端算路/注入能力（walk 1.4 / drive 13.9 m/s、RegionSimulator 参数、轨迹文件格式 §3.3.2）
- 数据填充：系统库实证字段（`data.read`/`data.test` 已实证结构）与设备端生成能力
- 原型上的滑条/种子等仅提供交互形式参考；**具体参数项集合由字段真相源决定，原型不定义参数**

---

## 0.5 M5 顶层原则（用户定案，2026-08-24）

1. **内部独立实现**：位置模拟（编排/算路/落盘）与数据填充（联系人/通话/短信生成）在设备端 SuperPhone 应用体系内**独立完整实现**（生产主路径在 App 内，离线自治，不依赖网关/云端）
2. **外部调用点 = 基于内部实现的注册能力**：为网关/外部留一个**可配置参数 + 可触发执行**的调用点——App 内实现的能力注册进 `TRCapabilityRegistry` + caps.js，外部发**同一套参数**（两端一致校验）即触发**同一实现**执行
3. **实现方式 = 共享模块多 target 编译**（App + manager/server 各编译同一份源码，各自进程内执行），**非转发**——App 直调与外部 invoke 都是"进程内执行同一实现"，参数契约天然一致
4. **落盘自治**：位置模拟 = App 编排/算路 → 写轨迹文件 + notify → manager 注入执行；数据填充 = App 直写系统库 + 同 uid kill daemon
5. 由 1-4 推得：**App 与注册表能力共享同一实现与参数契约**——D1 定案为"算法文件加入 App target 复用"，不双写
6. **网关定位能力移除（开发期过渡 → 正式收敛，用户定案）**：M4 开发期用网关/注册表（manager）生成定位与编排是**过渡手段**；M5 App 原生实现完成后，**网关面板移除自身生成逻辑，只调 App 原生能力（注册表调用点）**；5801 直连页在通道建好后复用同一能力（0x50/5802 分派同一实现）

---

## 1. 已核实事实（方案前提）

| # | 事实 | 证据 | 对方案的影响 |
|---|---|---|---|
| 1 | **App 工程未链 MapKit**；manager 已链 CoreLocation+MapKit | 主 [Makefile](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/Makefile#L150-L151)；App [project.pbxproj](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj) grep 无 MapKit | 阶段 0：pbxproj 加 `MapKit.framework` |
| 2 | **轨迹文件链成立**：App 写文件 + 写 defaults + notify 即离线自治 | `kSimTrackFilePath` [SimLocationController.mm L17](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/SimLocationController.mm#L17)；`_loadTrackPoints` [L247-256](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/SimLocationController.mm#L247-L256)；原子写 [L282-302](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/SimLocationController.mm#L282-L302)；notify 订阅 [trollvncmanager.mm L629-642](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncmanager.mm#L629-L642)；双域读取 [L361-368](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/SimLocationController.mm#L361-L368)；`_startTrack` 立即注入首点 [L180-205](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/SimLocationController.mm#L180-L205) | App=配置源、manager=执行器；App 侧只写文件+notify |
| 3 | **CoordTransform 无 ObjC 版**，仅原型 JS 版 | [locsim-app-prototype.html L262-279](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/outputs/locsim-app-prototype.html#L262-L279) | 阶段 1 新增 ObjC 版（公开数学，非原型决定权） |
| 4 | **data.\* 是双分派同一 handler**：`data.probe/test/read` 同时挂 5901 RFB 扩展消息（[tvExtHandleMessage L3704-3709](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm#L3704-L3709)）与 5802 HTTP（[tvHttpApiDispatch L4312-4317](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm#L4312-L4317)），同一纯函数 | 双分派注释"与 0x50 通道同一组纯函数" [L4303](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm#L4303) | **data.fill = 新增 handler + 两处分派表各加一条**（非"5802 新 op"） |
| 5 | **5802 HTTP 请求形态确认**：POST JSON body `{op, params}` 到任意 path；无鉴权、CORS 全开、TLS 明文分流兼容 | [tvHttpApiHandleClient L4444-4493](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm#L4444-L4493)；绑定 INADDR_ANY [L4527-4548](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm#L4527-L4548) | **App 本地 POST 127.0.0.1:5802 `{op:'data.fill',...}` 成立** |
| 6 | **config.set 未实现**：5802 只有 config.get（执行规格 §3.5 规划未落地） | grep 全文件无 `config.set`；5802 分派 [L4310](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm#L4310) 仅 config.get | **M5 前置缺口**：5801 定位按钮依赖 config.set |
| 7 | **data.\* 未收敛进注册表（遗留）**：`data.probe/test/read` 的 handler 只在 server 进程双分派（5901+5802）；`TRCapabilityRegistry`（manager 进程，[Makefile L119](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/Makefile#L119)）内**无 data.\*** 能力 | 完整能力列表 grep（`_registerControl` 51 条）无 data.\* | **方向 = 收敛进注册表**（对齐 touch.\*/app.\* 先例），非"无通道" |
| 7a | **收敛先例成立**：`touch.*`/`app.*` 的 executor 在 manager 进程直接执行（[STHIDEventGenerator.mm](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/STHIDEventGenerator.mm) 双 target 编译 [Makefile L29+L124](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/Makefile#L29)；`app.list/open` 经 LSApplicationWorkspace 在 manager 执行），5802/5901 双入口保留 | memory：2026-08-24 路径 A 收敛 /apps /touch 进注册表，跨网络验证通过 | **共享模块双 target 编译 = 本项目已接受的模式** |
| 7b | **App 内直写与 manager 执行写库的条件均就绪**：三进程（App/server/manager）**共享同一 entitlements**（[trollvncmanager.entitlements](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncmanager.entitlements) 内容即引用 [TrollVNC.entitlements](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/app/TrollVNC/TrollVNC/TrollVNC.entitlements#L26)，`kTCCServiceAddressBook` L26 三处生效）+ TrollStore 无沙盒 + sqlite3 系统库 | [Makefile L106/153](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/Makefile#L106) 两处 CODESIGN_FLAGS 指向同一文件 | **需补链**：manager_FRAMEWORKS +Contacts；App pbxproj +Contacts.framework +libsqlite3（阶段 0 已含） |
| 8 | **sim.\* 能力已在注册表**（manager 进程）：`sim.location.track/status`、`sim.route.calculate`、`sim.itinerary` | [TRCapabilityRegistry.mm L724-782](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/TRCapabilityRegistry.mm#L724-L782) | 网关面板可 invoke；**但 sim.\* 不在 5802 分派表 → App 无法本地调 daemon 算路** → 路径 A（App 前台自算）为唯一选择 |
| 9 | **contacts 分支依赖已就绪**：Contacts.framework 已链（[Makefile L87](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/Makefile#L87)）、`kTCCServiceAddressBook` 已在 [TrollVNC.entitlements L26](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/app/TrollVNC/TrollVNC/TrollVNC.entitlements#L26) | `data.test` contacts 分支 CNContactStore 已实证 [L4159-4173](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm#L4159-L4173) | data.fill 复用 contacts 分支**无新依赖** |
| 10 | **caps.js BATCH_CAPS 20 项无 sim.\***；但网关面板 invoke 是硬编码通道，**不依赖 BATCH_CAPS 定义** | [caps.js L45-67](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/trollvnc-farm/web/caps.js#L45-L67)；[verify-locsim.mjs L57-89](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/trollvnc-farm/test/verify-locsim.mjs#L57-L89) 直接 POST invoke | sim.\* 不进 BATCH_CAPS 不影响功能；补定义=批量菜单可见（可选，见 P3） |
| 11 | **5801 直连页无定位按钮**，`mgmtRequest` 已封装 5802 通道 | [index.vnc L946](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/layout/usr/share/trollvnc/webclients/index.vnc#L946) | M5 需新增 5801 定位按钮（依赖 P1 config.set） |
| 12 | **无需定位权限**；App 现有 3 tab（连接/控制/设置），紫色 tint | App Info.plist；[TRMainTabBarController.m L29-78](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/app/TrollVNC/TrollVNC/TRMainTabBarController.m#L29-L78) | 阶段 0 加第 4 tab；不新增权限键 |

---

## 1.5 契约审查结论（对照执行规格 + AGENTS.md + 说明文档 + CodeWiki）

**既有契约（三方文档一致，先于本计划）**：

| 契约 | 出处 |
|---|---|
| 能力层唯一地基：设备操作统一经 `TRCapabilityRegistry`（invoke 控制型 / setConfig 配置型） | AGENTS.md 红线；[说明文档 L13/L294](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/说明文档.md#L13) |
| 新增能力 = 设备端注册表 + 前端 caps.js 定义**各加一条**；数量变化同步 caps-test.js 断言与三方文档计数 | AGENTS.md 流程 2；[说明文档 L295](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/说明文档.md#L295)；[CodeWiki L1288](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/CodeWiki.md#L1288) |
| 能力 handler 唯一、入口多：0x50（隧道透传）与 5802 HTTP（直连）共用同一组 `tvExtHandle*` 纯函数 | [说明文档 L35](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/说明文档.md#L35) |
| **`data.probe/test/read` 是 POC 调试能力，走 5802 + 0x50 双通道，"正式实现时收敛"** | [说明文档 L274](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/说明文档.md#L274) |
| 5801 分叉 caps.js 与网关 caps.js 互不引用，各自维护 | AGENTS.md 约定 |

| # | 审查发现 | 处置 |
|---|---|---|
| P1 | **config.set 未实现**：§3.5 规划"新增 5802 config.set（与 config.get 成对、白名单对称）"未落地；5801 定位按钮（§3.6 M5 里程碑"5801 按钮调参全通"）依赖它 | **纳入 M5 前置任务**（阶段 3 开头实现 config.set：白名单对称 = config.get 可读键 + SimLocation\* 可写，写当前用户域 plist + notify_post） |
| P2 | **数据填充路径以早期规格定案为准**：数据填充-编码AI执行规格.md §2/§3.7 定案 = **App 内 DataFillerCoordinator 直接执行**（UI → 协调器 → 各 Writer 直写系统库 + 同 uid kill daemon），**不经网络通道**。当前 daemon 的 data.probe/test/read 是 POC 调试能力（说明文档 L274"正式实现时收敛"） | **M5 正式能力 = `data.fill`**：TRDataFiller 共享模块加入 App target（写库+刷新在 App 内完成）→ 收敛进注册表 + caps.js（两端契约）；**data.test 退役**（单条写库并入 data.fill，count=1 等价）；data.probe/read 保留为 0x50/5802 调试能力，**不入注册表**。删除"App → 5802 HTTP"绕路 |
| P3 | **caps.js 缺 sim.\* 定义**：M4 新增 sim.\* 未进 BATCH_CAPS（功能不受影响，面板硬编码 invoke） | 列为**可选完善**（不进 M5 必做）；data.fill 收敛时两端各加一条（BATCH_CAPS + 注册表），caps-test.js 断言随之更新 |
| P4 | **D4 为伪决策点**：sim.\* 不在 5802 分派表，App 无法本地调 daemon 算路；§3.6 已定案路径 A（App 前台自算） | **删除 D4**：路径 A 是唯一合理选择（也绕开跨进程问题） |
| P5 | **data.fill 接入方式（handler 唯一，多入口，App 为主）**：写库逻辑提取为共享模块 `TRDataFiller`（App + server + manager 三 target 编译，同 STHIDEventGenerator 先例）；**①** App 进程内直调（主路径）**②** 注册表 `data.fill` executor（manager 进程，网关/隧道可用）**③** 5901 RFB 扩展消息分派 **④** 5802 HTTP 分派（AI 工具/调试） | 阶段 2 按此实现；两端契约同步（caps.js BATCH_CAPS + TRCapabilityRegistry + caps-test.js 断言） |
| P6 | **contacts 分支依赖**：server 已链 Contacts.framework（[Makefile L87](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/Makefile#L87)）且 kTCCServiceAddressBook 双生效；**manager 需补链 Contacts.framework**（事实 #7b） | data.fill 共享模块双 target 编译时，manager_FRAMEWORKS +Contacts |

---

## 2. 阶段 0：工程接入（一次到位，避免重编译）

| 改动 | 内容 | 验收 |
|---|---|---|
| [project.pbxproj](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj) | Link Binary With Libraries + `MapKit.framework` + `Contacts.framework` + `libsqlite3`；新文件（CoordTransform/TRDisguiseViewController/TRMapPickerViewController/TRFillDataViewController/TRFillDataGenerator/TRDataFiller）加入 App target Compile Sources | CI 编译通过 |
| [TRMainTabBarController.m](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/app/TrollVNC/TrollVNC/TRMainTabBarController.m) | 加第 4 tab「伪装」（`theatermasks`），容器 `TRDisguiseViewController` | 四 tab 可切换 |
| 新文件 | `CoordTransform.mm`（GCJ-02↔WGS-84，ObjC）、`TRDisguiseViewController`（4 段容器）、`TRMapPickerViewController`（位置模拟）、`TRFillDataViewController`（数据三 tab 参数面板）、`TRFillDataGenerator`（参数→TRDataFiller 请求）、`TRDataFiller`（写库共享模块，App target） | 编译通过 |

> **D1（实现期评估）**：区域漫游/算路算法文件（[RegionSimulator.mm](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/RegionSimulator.mm)、[SimItineraryPlanner.mm](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/SimItineraryPlanner.mm)）优先直接加入 App target 复用；依赖链耦合过深则 App 侧建轻量编排器（复用 RegionSimulator 纯数学 + 前台 MKDirections，同 §3.4.1 语义）。**不双写算法。**

---

## 3. 阶段 1：位置模拟 tab（核心）

生产主路径 = App 前台 MKDirections（§3.6 路径 A；**sim.\* 不在 5802 分派表，App 无法本地调 daemon 算路——路径 A 是唯一选择**）。

| 模块 | 实现要点 | 真相源 |
|---|---|---|
| 地图交互（TRMapPickerViewController） | MKMapView 全屏；**交互链路+布局参考原型**：首击=设起点（锚点标志）、再击=加路线（以上一位置为起点）、长按=区域中心+拖半径+遮罩+从上一位置"生长"路线；右下角定位开关、左下步行/驾车胶囊、搜索（MKLocalSearch）、可展开步骤列表；锚点可点删、路线自适应 | 原型（仅交互链路+布局） |
| GCJ-02 转换（CoordTransform） | 选点/区域圆心为 GCJ-02；**所有选点出口统一过 `gcj02ToWgs84`** 再写设备；坐标框/状态栏展示 WGS-84；蓝点画在选点处 | 公开算法 |
| 算路（App 前台） | 路线段：MKDirections 逐段算路 → polyline 重采样到步长（walk 1.4 / drive 13.9 ± 拟人抖动）；区域段：RegionSimulator 计划 → 途经点间逐段算路；<30m 或失败降级直线并标注（§3.4.1）。**App 内执行，与注册表 sim.itinerary 同一实现**（RegionSimulator/SimItineraryPlanner 加入 App target，顶层原则 §0.5-2/4） | 设备端能力参数 |
| 落盘自治 | 原子写轨迹文件 → 写 `SimLocationMode=itinerary`（mobile 域）→ `notify_post(prefs-changed)`；停止：`SimLocationMode=off` + notify | 事实 #2 现成链路 |
| 蓝点 | showsUserLocation=NO 自绘；当前进度从 defaults 读回（`SimLocationMode`+坐标即状态真相） | — |

**验收**：① 地图选点→系统地图蓝点到达（GCJ→WGS 无偏移）；② 递增编排连续；③ 停止恢复真实定位；④ App 杀重开 mode 自动恢复。

---

## 4. 阶段 2：联系人/通话/短信 tab

### 4.0 参数真相源（先定字段，再定 UI）

参数项由系统库实证字段反推（原型滑条仅交互形式参考）：

| Tab | 实证字段（真相源） | 可生成参数项 | 证据 |
|---|---|---|---|
| 通话 | `ZCALLRECORD`：ZDATE（秒）、ZDURATION、ZADDRESS（号码 BLOB）、ZISO_COUNTRY_CODE、ZSERVICE_PROVIDER、ZVERIFICATIONSTATUS、ZHANDLE_TYPE、ZCALL_CATEGORY、ZORIGINATED/ZANSWERED/ZREAD | 数量；时间分布（近 N 天）；时长分布；**拨入/拨出比**；号码段 | [L4106-4119](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm#L4106-L4119) |
| 短信 | `message`（date 纳秒/text/is_from_me/is_read/service='SMS'）；`handle`；`chat`（style=45/state=3/account_login） | 数量；时间分布；**收发比**；文本库；号码段 | [L4121-4158](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm#L4121-L4158) |
| 联系人 | `CNContactStore`：familyName、phoneNumbers（label=Mobile）——系统维护排序/FTS | 数量；中文姓名（姓/名库）；号码段 | [L4159-4173](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm#L4159-L4173) |

- `seed` 驱动确定性随机（同 seed 可复现）；生成器在 TRDataFiller 共享模块内（多 target 同一实现），网关 Node 侧放可测副本（npm test）

### 4.1 共享模块 `TRDataFiller`（App 主路径 + daemon 补充入口）

`data.test` 只写单条硬编码 → 新增批量生成，**写库单一实现、多 target 编译**：

> **data.test 退役**（用户拍板：正式能力 = data.fill，不要 test）：data.test 的单条写库逻辑并入 data.fill（count=1 等价），从正式能力体系移除；data.probe/data.read 保留为 0x50/5802 调试能力（**不入注册表**，开发期验证 schema/数据用）。

- **写库核心提取为共享模块 `TRDataFiller.mm/.h`**（从 trollvncserver.mm 的 data.test 逻辑抽出，参数化）：**App + server + manager 三 target 编译**（同 STHIDEventGenerator 多 target 先例）
  - 参数 `{db:'contacts'|'calls'|'sms', count, seed, ratios:{...}}`（ratios 键集见 §4.0，`{db,count,seed}` 强制）
  - `seed` 确定性随机 → 逐条构造 → 复用 data.test 已实证写库语句（calls/sms 直写 + contacts CNContactStore）→ `PRAGMA wal_checkpoint` → kill 对应 daemon（callservicesd/imagent/contactsd）
  - 拟人调料：中文姓名/号码段/文本库/时间与时长分布为模块化小生成器
- **执行入口（handler 唯一，多入口分派）**：
  1. **App 进程内直调（主路径，早期规格定案）**：伪装页生成按钮 → TRDataFiller（App target）
  2. **注册表**：`TRCapabilityRegistry` 注册 `data.fill`（TRCapRouteNative，executor 调 TRDataFiller）→ 网关经隧道 invoke 跨网络可用
  3. **5901 RFB 扩展消息**：tvExtHandleMessage 分派表加一条（[L3704-3709](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm#L3704-L3709) 区）→ AI 工具/脚本
  4. **5802 HTTP**：tvHttpApiDispatch 分派表加一条（[L4312-4317](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/src/trollvncserver.mm#L4312-L4317) 区）→ AI 工具/调试
- **工程配置**：`Makefile` 的 `trollvncserver_FILES`/`trollvncmanager_FILES` 各加 TRDataFiller；`trollvncmanager_FRAMEWORKS` +Contacts；App 工程 pbxproj 加 TRDataFiller + Contacts.framework + libsqlite3（见阶段 0）
- **两端契约**：网关 `caps.js` BATCH_CAPS + `data.fill`（两端各加一条）；`caps-test.js` 断言 BATCH_CAPS 20→21

### 4.2 App 侧：参数面板 + 生成调用

- UI 交互形式参考原型（滑条联动/数字种子/按钮下方反馈）；参数项按 §4.0
- **调用链（对齐早期数据填充规格的既定路径）**：`TRDataFiller` **加入 App target** → App 伪装页生成按钮**进程内直接执行**写库 + 同 uid kill daemon（callservicesd/imagent/contactsd）→ 回执"生成 N 条"
  - 早期规格（数据填充-编码AI执行规格.md §2/§3.7）定案路径 = App 内 DataFillerCoordinator 直接执行，不经网络通道；App 与 daemon 同 entitlements（含 kTCCServiceAddressBook）+ TrollStore 无沙盒，写 mobile 域系统库可行
  - **App 直写 vs daemon 写 = 共享模块多 target 编译，非转发**
- **验证项**：App 进程内 CNContactStore 写通讯录（授权已放行）+ 同 uid kill daemon 需真机确认（App 伪装页首版首跑验证；失败回退 daemon 5802 路径）

---

## 5. 阶段 3：网关/5801 对齐

| 改动 | 内容 | 前置 |
|---|---|---|
| 5802 `config.set`（**P1 前置缺口**） | 与 config.get 成对、**白名单对称**（config.get 可读键 + SimLocation\* 可写；密码/证书不开放）→ 写当前用户域 plist → notify_post | 无（本阶段第一步） |
| 网关 web 定位面板 | 重做为与 App 同布局（交互链路+布局参照 App；`?v=N` 递增）；**移除网关侧生成逻辑（开发期过渡）**，只调注册表 sim.* 能力（App 原生同一实现，§0.5-6） | 无 |
| 5801 直连页定位按钮 | index.vnc 新增定位按钮 → `mgmtRequest('config.set', {keys, values})`（与 config.get 同通道） | **config.set** |
| 网关数据填充面板（**D3 决策**） | 经注册表 invoke `data.fill`（TRDataFiller 编译进 manager，隧道通道）；三 tab 参数项同 §4.0。是否纳入 M5 由用户拍板 | data.fill（阶段 2） |

---

## 6. 阶段 4：文档同步 + CI + 真机验收

- `说明文档.md`（红线：改动必须同步）＋ `CodeWiki.md` 行号/数量校准 ＋ `?v=N` 递增
- 网关 `npm test` 全绿：CoordTransform Node 侧对照测试、`data.fill` 生成器 Node 可测副本（新增）；`caps-test.js` 断言更新（BATCH_CAPS 20→21，若 D5 加 sim.\* 则再 +4）
- CI：push-via-api → workflow_dispatch → wait-ipa 取 `.tipa`；**匹配 run 用远程 HEAD sha**
- 真机验收：四 tab 全流程（位置模拟编排/停止；三数据 tab 生成后系统 App 可见——信息/电话/通讯录；5801 定位按钮）

---

## 7. 决策点与待确认项

**已定案**：D1 复用 / D2 App 内直写 / D3 网关数据填充面板纳入 / D4 删除 / D6 data.fill 正式、data.test 退役；顶层原则 §0.5 全 6 条；**P7 保持原型顺序（位置模拟\|联系人\|通话\|短信）/ P8 按 §4.0 集合语料内置 / P13 网关面板同布局（全屏地图）/ P14 全做**。

| # | 待确认项 | 影响 | 倾向/默认 |
|---|---|---|---|
| P7 | **伪装页 4 子 tab 标签与顺序**：原型现为「位置模拟\|联系人\|通话\|短信」[L140-143](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/outputs/locsim-app-prototype.html#L140-L143)，但你调整过（通话/短信换位、定位移最后）——最终顺序？ | 阶段 0 容器 + 阶段 1/2 UI | 按你的最终定稿 |
| P8 | **数据填充参数项集合（§4.0）**：通话（数量/时间分布/时长分布/拨入拨出比/号码段）、短信（数量/时间分布/收发比/文本库/号码段）、联系人（数量/中文姓名/号码段）——参数项集合与 ratios 键集是否即最终？语料（姓名/号码段/文本库）默认内置？ | 阶段 2 参数面板 + data.fill 契约 | 默认按 §4.0；语料内置 |
| P9 | **数据填充 count 范围**：滑条范围（默认 10~500？） | 阶段 2 参数面板 | 10~500 可调 |
| P10 | **config.set 白名单键集（P1）**：可写键 = config.get 可读 UI 参数 + SimLocation\*（密码/证书/端口不开放）——具体键清单 | 阶段 3 config.set 实现 | 按 §3.5 白名单对称 |
| P11 | **sim.\* 去留明细**：status 保留（只读查询）/ track 保留（外部轨迹上传如 GPX）/ route.calculate+itinerary 保留为调用点（实现 = App 原生共享模块）；"网关侧生成逻辑移除"范围实现时盘点 | 阶段 1/3 | 按上述默认 |
| P12 | **5801 定位按钮形态**：简单锚点设置（config.set SimLocation\*）vs 完整定位入口 | 阶段 3 5801 | 简单锚点优先 |
| P13 | **网关定位面板重做范围**：与 App 同布局（全屏地图+递增编排，工作量大）vs 简化参数版 | 阶段 3 规模 | 需你拍板（倾向同布局？） |
| P14 | **M5 开工范围**：阶段 0-4 全做 vs 分阶段推进 | 整体排期 | 待你确认 |
| D5 | caps.js BATCH_CAPS 补 sim.\* 4 条（批量菜单可见）？ | 阶段 3 可选 | 暂不补 |

---

## 8. 明确不做什么

- ❌ App 前台不做注入（App 只调参写文件，manager 注入）
- ❌ 不复制 Geranium/Andromeda/TrollBox 源码（算法按公开数学实现）
- ❌ 不使用 respring（kill 对应 daemon 生效）
- ❌ data.\* 不新建 manager↔server IPC 桥（收敛进注册表 = manager 进程直接执行，无需桥）
- ❌ 不做 iOS 18+ 支持、不做多设备调度器
