# M5 数据填充三 Tab 完整开发 · 设计（Design）

> 日期：2026-08-25
> 状态：待审查
> 范围：App 伪装页三 Tab（联系人/通话/短信）参数面板 + 生成算法**完整落地**（以 2026-08-24 两份 generator-design 算法定稿为准），补齐省市选择器与收发比
> 本设计以既有文档为唯一依据；实现遇到歧义时对照下列文档位置提交方案定夺，不得自行猜测

## 0. 依据文档索引（开发对照基线，遇到不明确先查这里）

| # | 文档 | 提供什么 |
|---|---|---|
| D1 | `docs/superpowers/specs/2026-08-24-contacts-generator-design.md` | 通讯录生成设计：TRProfile、**备注模式互斥反查（TRRoleLexicon）**、HLR 号码生成、CNContactStore 写入 |
| D2 | `docs/superpowers/specs/2026-08-24-calls-sms-generator-design.md` | 通话/短信生成设计：**角色反查分层加权（family 4.0/work 3.0/friend 2.0/service 1.0/business 0.5）**、陌生号 Zipf 重复度、昼夜权重、时长对数分布、运营商客服短号、内容池模板、未接来电联动 |
| D3 | `outputs/2026-08-24-数据生成算法-开源调研.md` | Persona Schema 定稿（§5）、时间戳拟真算法（§2：昼夜权重表/会话簇/响应速度/jitter） |
| D4 | `outputs/数据填充-编码AI执行规格.md` | 写入路线定论（通话/短信 DB 直写、联系人 CNContactStore）、Cocoa 纪元、刷新 kill daemon、实验定案 |
| D5 | `outputs/Filza-数据填充-调研报告.md` | 三库 schema 实证、daemon 属主表、检测面 §7.6（交叉验证/过度完美/机械特征） |
| D6 | `outputs/M5-App原生伪装页-开发计划.md` | M5 计划：§0.5 顶层原则（共享模块多 target、App 直调与外部 invoke 同一实现）、§4.0 参数真相源、P2 data.test 退役、P8 语料内置 |
| D7 | `outputs/locsim-app-prototype.html` | UI 定稿原型（三 Tab 参数面板形态） |
| D8 | `说明文档.md` | 三库写入格式定稿（CallHistory ZCALLRECORD 字段 / sms.db message-chat-handle-join / Cocoa 纪元） |

## 1. 背景与目标

App 伪装页三 Tab（联系人/通话/短信）UI 已实现（`TRFillDataViewController.m`），写库能力已实现（`TRDataFiller.mm`，data.fill 统一能力四入口）。**但生成算法仅为简化版**（D1/D2 定稿的角色反查/分层加权/Zipf/昼夜权重/运营商客服/内容池模板全部未落地，grep 确认零实现）。

**本次目标（完整开发）**：
1. 联系人：**省市多级选择器**（成品 BRPickerView 替换硬编码 5 城）+ 备注模式互斥（D1 §2.4）+ HLR 号码（D1 §2.5）
2. 通话：**选人构成真联动**（角色反查分层加权 + 陌生号 Zipf）+ 昼夜权重 + 时长对数 + 运营商客服来电（D2 §2.2）
3. 短信：**收发比滑条**（用户新增，默认发 2:8）+ 类型构成 + 内容池扩充 + 运营商服务短信 + 未接来电联动 + 昼夜分布（D2 §2.3）
4. 契约：ratios 键集对齐 D1/D2 真相源
5. **清空能力（用户新增，批量管理）**：App 三 Tab 增加「清空通讯录/通话记录/短信」，并新增注册能力 `data.clear` 供外部统一调用

**本质定位（用户定案）**：完全 App 内部使用（生产主路径）+ 统一的外部可调用的参数选择（同一套 db/count/seed/ratios 契约）+ 通过外部直接为手机内部生成这三类信息（同一实现、四入口、进程内执行、非转发）。

### 1.1 开发流程（三阶段，用户定案 2026-08-25）

> 动因：App 反复编译安装（CI 出 .tipa + 真机装）调试成本高；**联系人/通话/短信的生成完全可以外部实现**——不写入设备，只产出符合三库字段结构与 data.fill 参数契约的结构化结果，调参/审查/契约基准全部在外部完成。
> 前提：**三库写入能力已最小化实证**（data.test 时代真机验证 ZCALLRECORD/sms.db/CNContactStore 写入 + kill daemon 生效，见 D4/D8）——写库不重验；**生成算法在外部定稿，ObjC 只做同构移植 + 写库**。
> **数据源严谨原则（用户定案）**：客观数据（电话区号/手机号段/行政区划）**一律以权威完整数据源为唯一依据**，构建期脚本从数据源生成静态表 + 完整性校验，**禁止手工精简表**（外部算法验证同样要求绝对严谨）。语料类内容（姓名/短信模板/角色词池）为自研内容（D3 §4 定稿"无 LLM 内容池模板"），人工维护。**以此原则对照全部数据类内容**（见 §4.2/§5/§6 与计划任务 3/8/10）。

**阶段 1：生成算法完整实现（Node，可独立产出结果，零编译零装包）**
- 位置：`trollvnc-farm/test/data-gen/`（ESM 纯函数模块，纳入 `npm test`）——**生成器本体在此实现**，输出结构化结果 JSON（联系人 Persona[]/通话记录[]/短信[]，字段对齐设备写入所需结构，含生成语义字段如 role）
- 模块（**算法唯一开发地**，ObjC 从它同构翻译）：
  - `role-lexicon.js` — TRRoleLexicon 词池 + 互斥匹配（family/service/business/work/friend）
  - `contacts-gen.js` — 省市/关系构成/本地占比 → Persona[]：备注名互斥 + HLR 号码 + 全国区号表
  - `calls-gen.js` — 角色反查分层加权 + Zipf 陌生号 + 昼夜权重 + 时长对数 + 运营商客服来电
  - `sms-gen.js` — 类型构成 + 内容池 + 收发比 + 昼夜分布 + 未接来电联动
- 断言（`data-gen-test.mjs`）：占比复现（±2%）、备注互斥、号码格式/区号合法、时间昼夜分布、Zipf 形状、**同 seed 可复现**
- **魔鬼测试（极端场景稳定性，用户定案维度）**：
  - 边界参数：count=1 / 上限（500/200/300）、占比单极值（某类 100% 其余 0%）、regionLocal=0/1、inRatio=0/1、days=1/30、省市极端（直辖市/无区号城市）
  - 数据源极端：通讯录为空（依赖校验）/ 仅 1 人 / 500+ 超大人 / 全部备注无特征（反查零命中 → friend 兜底）
  - 随机压力：同 seed 输出严格一致（可复现）；**连续 100 轮不同 seed 生成不崩**、输出不变量恒成立
  - **输出不变量（恒成立断言）**：号码格式正则 `^1[3-9]\d{9}$` / 固话 `^0\d{2,3}\d{7,8}$`、备注互斥反查命中率 100%、时间戳 ∈ [now-days, now]、号码/guid 无重复、比例误差 ≤2%、无异常/断言失败
- **样例审查**（`data-gen-samples.mjs`）：批量生成 3 组样例（不同省市/运营商/收发比/占比组合）输出 JSON——**用户审核内容质量**（联系人备注像不像真人、短信文案、通话分布），调参收敛到目标能力范围

**阶段 2：ObjC 同构移植 + 写库**
- 阶段 1 生成器定稿 → **ObjC 按 Node 同构翻译**进 `TRDataFiller.mm`（共享模块多 target：App/manager/server），接已实证的写库（CNContactStore / ZCALLRECORD / sms.db）——**算法不二次开发，只翻译 + 写库**
- **防漂移**：真机跑一批，**同 seed 输出与 Node 生成器 JSON diff**（一次性对照）；Node 生成器作为持续回归留在 `npm test`

**阶段 3：UI 联动**
- 省市选择器（BRPickerView）/ 收发比滑条 / 清空按钮 / 依赖提示 / collectRatios 键集对齐 §3.1

### 1.2 自写语料库规格（阶段 1 前置，用户定案 2026-08-25）

> **定位**：语料类内容（姓名/角色词池/短信模板/品牌变体/日常语料）为**自研内容**（非客观数据，D3 §4 定稿"无 LLM 内容池模板替代"），人工编写、**前期一次性充分落地**（不随任务零星补）。
> **单一数据源**：Node `test/data-gen/corpus.js` 为语料唯一开发地（+ role-lexicon.js 角色词池），构建脚本生成 ObjC 常量 `TRCorpus.mm/.h`（与 TRAreaCodes 同模式，App 无 Node 运行时）——**两端同源，防漂移**。

**语料清单与规模（"极为庞大"，用户定案 2026-08-25 扩充）**：

| 语料 | 规模 | 用途 |
|---|---|---|
| 常见姓（纯单姓，复姓不用——超出正常范围，用户定案） | 100 | 联系人姓名 |
| 常用名（单字 120 + 双字 298，去重 418） | 400+ | 联系人姓名（组合 100×418 充足；用户定案"名多姓少"） |
| 角色词池 family | 100+ | 备注名生成 + 通话/短信反查 |
| 角色词池 service | 80+ | 同上（职业+姓） |
| 角色词池 business | 30+ | 同上（机构名） |
| 角色词池 work | 30+ | 同上（真名-公司） |
| 昵称池 | 40+ | friend 备注 10% 昵称 |
| 验证码模板 | 80+ | 短信（平台×银行×出行×政务×校园×App 场景全展开） |
| 快递模板 | 70+ | 短信（快递公司×驿站×丰巢×生鲜×冷链×国际×大件×改址） |
| 银行模板 | 70+ | 短信（12 银行×消费/转账/账单/贷款/ETC/社保/公积金/理财场景） |
| 运营商模板 | 70+ | 短信（流量/套餐/积分/缴费/停机/宽带/IPTV/亲情号/物联网，按 carrier） |
| 营销模板 | 165（9 行业分组） | **行业分组 + 行业品牌池（品牌-内容强关联，用户定案）**：realty/travel/food/tech/auto/fin/edu/health/retail；`{brand}` 取本行业品牌池、`{discount}`/`{pct}` 专用变量；标签=品牌、内容表达行业 |
| 家人朋友日常语料 | 140+ | 短信（约饭/接娃/快递/天气/工作/家庭/出行/健康多场景） |
| 品牌变体池（banks/couriers/platforms/stations/estates/orgs/products/ecoms/**brands**） | 20/15/20/20/20/20/30/15/41 | 模板 {var} 注入；brands=平台/本地生活型（营销通用标签，防垂直品牌错配） |

**模拟调参面板（用户定案 2026-08-25）**：`data-gen-panel.mjs` 模拟 App 三 Tab 参数面板的离散档位（省市×运营商×收发比×数量×各占比预设），矩阵化批量生成 + 自动审查（占比偏差/互斥/格式/分布/不变量），输出调参报告；执行者据报告迭代调语料/算法直至符合预期——纳入 `npm test`。

**质量规范（"正规"）**：
- 每条模板 `{var}` 必有对应 replace，无占位符残留；短信长度 < 70 字；语法自然、无模板重复感
- 无敏感/违规内容；不映射真实机构攻击性文案；语料参考公开短信风格但**人工编写**（不直接复制数据集）
- 角色词池互斥约束沿用 D1 §2.4：service 词不得含称谓字（阿姨/叔叔/姐/哥）、family 纯称谓、work 必带公司词
- corpus.js 内建**语料自检**（并入 data-gen-test）：模板无 `{` 残留、长度 < 70、词池互斥、规模达标（≥ 上表下限）

## 2. 目标架构（保持现状，不重构）

```
TRFillDataViewController（三 Tab 面板）→ TRFillDataGenerator（组装）→ TRDataFiller.fillDatabase（写库+kill daemon）
外部：注册表 data.fill（manager）/ 5901 0x50 / 5802 → 同一 TRDataFiller 实现（三 target 编译）
```

- **保持 data.fill 统一能力**（不回归 D6 前的三独立能力 data.contacts.generate 等）
- **保持 App 进程内直调**（D6 §0.5-3 共享模块多 target，非 5802 转发）
- caps.js / 注册表定义**零改动**（ratios 为自由字典；caps.js data.fill 仅 db/count/seed/ratios 透传）

## 3. ratios 契约定稿（对齐 D1/D2 键名）

| db | 顶层参数 | ratios 键 |
|---|---|---|
| contacts | count, seed, city, province | `{friend, work, service, family, business}`（关系构成，合计≈1）、`regionLocal`（本地占比 0-1，放 ratios 内与现状 localRatio 同位） |
| calls | count, seed, days, carrier | `{contact, stranger}`（选人构成，合计≈1）+ `{incoming, outgoing, missed}`（状态构成，合计≈1） |
| sms | count, seed, days, carrier, **inRatio** | `{code, express, bank, carrierSms, marketing, family}`（类型构成，合计≈1） |

- carrier：`cmcc | cucc | ctcc`（内部映射运营商名，避免中文键）
- city/province：中文名（"北京"/"浙江"），联系人用
- **inRatio**：我发占比 0-1，**默认 0.2**（发 2 收 8，用户定案），仅作用于 family 类 `is_from_me`
- 键名从当前实现（relFriends/knownRatio/typeSms 等）统一到上表——只改 App `collectRatios` 与 TRDataFiller 消费键，对外契约行为不变

### 3.1 与已实现 UI 的联动映射（防实现错位）

| Tab | 现有 UI 控件顺序 | → 新 ratios 键 | 变化 |
|---|---|---|---|
| contacts | 关系构成滑条组（朋友/工作/生活/家人/机构） | `{friend, work, service, family, business}` | 仅重命名（relFriends→friend 等）；UI 顺序、100% 合计、重置默认机制不动 |
| contacts | 本地占比滑条 | `regionLocal` | 仅重命名（localRatio→regionLocal） |
| contacts | 常住地区 segmented 5 城 | `city/province`（中文名） | **值语义变化**：beijing→北京；控件换 BRPickerView 省市选择器 |
| calls | 选人构成（联系人内/陌生号） | `{contact, stranger}` | 仅重命名（knownRatio→contact/stranger） |
| calls | 状态构成（呼入/呼出/未接） | `{incoming, outgoing, missed}` | 仅重命名（statusIn→incoming 等） |
| sms | 类型构成（验证码/快递/银行/运营商/营销/家人朋友） | `{code, express, bank, carrierSms, marketing, family}` | 仅重命名（typeSms→code 等） |
| sms | **新增**收发比滑条 | 顶层 `inRatio` | 新增控件，插入类型构成之后、种子之前，默认 20% |

**沿用现状不改的 UI**：
- days：现有 `1/3/7/30` 四档 segmented（design 文档 §3 的"1-30 输入"是早期表单描述，**以已实现四档为准**）
- seed：现有"点击随机"按钮（非文本输入）
- carrierSeg：值沿用 `cmcc/cucc/ctcc`
- 比例合计联动机制（TRRatioRow 组、末项补足、tag 777 合计标签、重置默认）——键名改动不触碰
- 错误回执：新增"通讯录为空"等走现有 `{ok:NO, error}` → resultLabel 通道

**需补 UI**：
- 通话/短信 Tab 顶部依赖提示"基于通讯录生成，请先生成通讯录"（D2 §3 UI 定稿，当前 UI 缺失）
- 短信 Tab 收发比滑条（§6.1）

## 4. 联系人 Tab

### 4.1 常住地区：省市选择器（BRPickerView）
- 集成 BRPickerView（纯 OC、iOS11+、手动拖源码）→ 新目录 `TrollVNC/app/TrollVNC/TrollVNC/BRPickerView/` + pbxproj 加入 App target
- 用法：`BRTextPickerView` 省→市两列联动（V3 组件；集成时拉源码确认 API）——**省市两级数据不用 BRPickerView 内置数据，改用数据源生成**（province-city-china 民政部行政区划的省/市两级，构建期 `build-area-table.mjs` 产出省市 JSON 喂给选择器，与区号表同一数据源）
- 选中输出：`province`（省名）+ `city`（市名）→ 行内回显"省 · 市"
- 替换现有 `UISegmentedControl` 5 城（北京/上海/广州/深圳/成都）

### 4.2 生成算法（对齐 D1 §2）
- **备注模式互斥**（D1 §2.4 + TRRoleLexicon，词池规模/质量见 §1.2）：关系构成 → 备注名：
  - friend 真名 90% + 昵称 10%｜work 真名-公司名｜service 职业+姓（**不含称谓字**）｜family 纯称谓词池｜business 机构名
  - 互斥约束：work 必带公司后缀、family 纯称谓、service 不得含称谓字——保证通话/短信反查 100% 命中（单一数据源）
- **号码生成**（D1 §2.5 落地）：**完整号段池**（工信部《电信网编号计划》全部 11 位手机号段，含移动/联通/电信/虚商，构建期从数据源生成）+ 常住城市/异地城市 HLR 前缀 + 尾号随机 + **去重**（设备已有号码查重 + 生成集内查重）
- **非本地号码语义**（用户定案）：本地=手机号、非本地=固话（`0+城市区号+8位`）——**区号表以权威完整数据源为唯一依据**（民政部行政区划 + 工信部编号计划，覆盖全国全部地级行政区，禁止手工精简表）；构建期脚本 `build-area-table.mjs` 从数据源生成 `area-codes.json`（省→市→区号）+ 完整性校验（每省地级市覆盖、区号格式 `0\d{2,3}`、直辖市 010/021/022/023）；ObjC 静态表（TRAreaCodes）由同一数据源生成（**单一数据源，两端一致**）
- 关系构成 → 号码 label 保持现有映射（手机/工作/住宅/iPhone/主号），备注名与 label 双通道并存（备注名=角色反查依据、label=号码类型展示）
- 写入 CNContactStore：familyName=备注名、phoneNumbers=@[phone]；写后 kill contactsd

## 5. 通话 Tab

### 5.1 选人构成真联动（D2 §2.2）
- **联系人内（contact 比例，默认 70%）**：读系统通讯录（CNContactStore）→ **TRRoleLexicon 反查角色** → 分层加权选人（family 4.0/work 3.0/friend 2.0/service 1.0/business 0.5）
- **陌生号（stranger 比例，默认 30%）**：Zipf 重复度分布——高频复用号（占通话量 ~15%，单号重复 3-10 次 = "记住的号"）+ 低频一次性号（~15% = 真陌生，未接集中于此）
- **运营商客服来电**（carrier，D2 §2.4）：1-2 条特服号（cmcc=10086 / cucc=10010 / ctcc=10000）呼入/呼出，计入陌生号池
- **依赖校验**：通讯录为空 → 返回 `{error:"通讯录为空，请先生成通讯录"}`（D2 §3.3）
- **边界：角色层为空**——通讯录有联系人但某层（如 business）无命中 → 跳过该层并对剩余层权重归一化（不报错）

### 5.2 时间与状态拟真（D2 §2.2）
- 昼夜权重：0-6 点 0.05、6-8 点 0.30、8-9 点 0.70、9-12 点 0.90、12-14 点 0.80、14-18 点 0.95、18-21 点 1.00、21-23 点 0.70、23-24 点 0.30（拒绝采样）
- 时段微调：白天（9-18）work/business 权重略高、晚上（18-23）family/friend 略高
- 活跃日/沉寂日：随机 1-2 天活跃、其余稀疏
- 状态构成（incoming/outgoing/missed）：未接集中在陌生号；时长对数分布 `-ln(U)×120` 秒（30s-2min 为主），family 30% 概率 10-30min 长通话，未接=0
- 连续通话：同人多条紧挨（占 ~15%）
- 写入 ZCALLRECORD（D8 格式：ZDATE Cocoa 秒、Z_PK 同步 Z_PRIMARYKEY、ZVERIFICATIONSTATUS=4 等）+ kill callservicesd

## 6. 短信 Tab

### 6.1 收发比滑条（用户新增，原型同步补）
- UI：短信 Tab 新增「收发比（我发占比）」滑条，默认 20%，范围 0-100%
- 算法：仅作用于 **family 类**消息 `is_from_me = rand < inRatio`；其余五类（验证码/快递/银行/运营商/营销）恒为收到的（fromMe=0）
- **原型同步**：`outputs/locsim-app-prototype.html` 短信 Tab 补收发比行（原型是 UI 定稿参照，需同步）

### 6.2 生成算法（D2 §2.3）
- 类型构成：code 35%/express 20%/bank 15%/carrierSms 10%/marketing 10%/family 10%（服务 90% + 日常 10%）
- **内容池**（D2 §2.3 模板表扩充，**完整语料按 §1.2 规格在 corpus.js 一次落地**）：每类 15-30 条高质量模板 + 品牌名变体（验证码：抖音/微信/京东/饿了么/银行；快递：顺丰/中通/圆通/驿站；银行：招商/工商/建设/农行；运营商：**按 carrier 生成 10086/10010/10000 + 流量/套餐/积分/缴费文案**；营销：楼盘/贷款/课程/电商）——自建内容池（无成品库可调用，公开数据集仅作风格参考，D3 §4 定稿"无 LLM，内容池模板替代"）
- **未接来电联动**（D2 §2.3）：若最近通话有未接陌生号 → 跟 1 条"【运营商】您有一个来自{号码}的未接来电"
- **选人**：family/friend 从反查角色池选（简短 1-3 条，不做长往返）；服务/陌生类用服务号/陌生号单条
- 时间：服务短信单条散落按昼夜权重（验证码/快递/银行在 9-18、营销在 19-22）；family 偶尔 2-5 条小簇（间隔 30s-5min、jitter ×0.7-1.3）
- 写入 sms.db（D8 格式：date 纳秒、service=SMS、chat style=45/state=3、handle UNIQUE 复用）+ kill imagent

## 7. 清空能力（批量管理，用户新增）

### 7.1 能力契约

```
cap: data.clear
params: { db: 'contacts' | 'calls' | 'sms' | 'all' }
返回: { ok, cleared: N }   // cleared=清空数量（all=三库合计）
```

- 与 data.fill 对称：App 直调 `TRDataFiller.clearDatabase:`（进程内）+ 注册表 `data.clear`（外部 invoke）+ 0x50/5802 分派——**同一实现四入口**，遵循能力层唯一地基与两端契约（AGENTS.md 流程 2）
- **契约影响**：新增能力 = 两端各加一条——caps.js BATCH_CAPS **21→22**（data.clear 定义，含 params 说明）+ caps-test.js 断言 `=== 21` 改 `=== 22` 且补 `data.clear` 存在性断言 + TRCapabilityRegistry 注册 + 三方文档能力计数同步

### 7.2 清空实现（TRDataFiller.clearDatabase:）

| db | 实现 | 刷新 |
|---|---|---|
| contacts | CNContactStore 枚举全部删除（CNSaveRequest deleteContact，批 50）——与写入同 API 路线 | kill contactsd |
| calls | `DELETE FROM ZCALLRECORD`（**不动 Z_PRIMARYKEY**——ROWID 空洞正常，D5 §7.4/SMSmissingROWIDs 实证；重置反而有主键冲突风险） | kill callservicesd |
| sms | 按 `service='SMS'` 清理（保留 iMessage）：清 `message`/`chat`/`handle` 的 SMS 记录 + 关联 `chat_message_join`/`chat_handle_join` | kill imagent |
| all | 上述三库全清 | kill 三 daemon |

- 返回 cleared = 受影响行数/联系人删除数；失败 `{ok:NO, error}`
- **联动**：清空通讯录后通话/短信生成依赖校验立即生效（返回"通讯录为空，请先生成通讯录"）

### 7.3 UI（App 三 Tab + 外部入口）

- App：三 Tab 各在「生成」按钮下方加「清空」按钮（红色警示样式）→ **UIAlertController 确认弹窗**（"将清空全部{联系人/通话记录/短信}，不可恢复"）→ 直调 `TRDataFiller.clearDatabase:` → resultLabel 回执"已清空 N 条"
- 注册表 `data.clear`：外部（网关/隧道）可调用；网关面板与 5801 直连页在数据填充区**可选**加"清空"按钮（缺省 db 单选）

## 8. 工程改动清单

| 文件 | 改动 |
|---|---|
| `TrollVNC/app/TrollVNC/TrollVNC/BRPickerView/`（新增目录） | BRPickerView 源码拖入 + pbxproj 加入 App target |
| `TrollVNC/app/TrollVNC/TrollVNC/TRFillDataViewController.m` | ①常住地区行换省市选择器（回显省·市）②短信 Tab 加收发比滑条 ③通话/短信 Tab 顶部依赖提示 ④collectRatios 键集对齐 §3.1 |
| `TrollVNC/app/TrollVNC/TrollVNC/TRFillDataGenerator.m` | 注释同步新键集（AGENTS.md 流程 4：注释与实现一致） |
| `TrollVNC/src/TRDataFiller.mm` | ①TRRoleLexicon 词池（family/service/business/work 表 + 匹配函数）②CNContactStore 读+反查角色 ③分层加权选人（含角色层空归一化）④Zipf 陌生号 ⑤昼夜权重+时段微调+活跃日 ⑥时长对数+连续通话 ⑦运营商客服来电（calls）/服务短信（sms）⑧内容池扩充 ⑨未接来电联动 ⑩收发比 inRatio ⑪全国城市区号表（key=中文城市名）⑫依赖校验 ⑬**新增 `clearDatabase:`（contacts/calls/sms/all，§7.2）** |
| `TrollVNC/src/TRCapabilityRegistry.mm` | **新增能力 `data.clear` 注册**（executor 调 TRDataFiller.clearDatabase:） |
| `trollvnc-farm/web/caps.js` | **已核对**：data.fill params 含 ratios（object 自由字典，L67-73），ratios 键名变化零改动；**新增 data.clear 定义（BATCH_CAPS 21→22）** |
| `trollvnc-farm/test/data-gen/`（新增目录，阶段 1） | `role-lexicon.js`/`contacts-gen.js`/`calls-gen.js`/`sms-gen.js`（ESM 纯函数）+ `data-gen-test.mjs`（断言）+ `data-gen-samples.mjs`（样例审查输出） |
| `trollvnc-farm/test/data-gen-test.mjs` 并入 `npm test` | package.json test 脚本追加（若独立脚本，走 `npm test` 聚合）；**阶段 1 门槛：npm test 全过 + 用户样例审查通过** |
| `trollvnc-farm/test/caps-test.js` | 断言 `BATCH_CAPS.length === 21` → `22` + 补 `data.clear` 存在性断言 + 注释更新 |
| `TrollVNC/layout/usr/share/trollvnc/webclients/index.vnc` | **5801 直连页补数据填充入口**（D1 §3/D2 §4 契约，当前缺失）：操作栏按钮 → 5802 invoke data.fill {db,count,seed}（ratios 缺省内置分布）；可选补 data.clear 清空 |
| `outputs/locsim-app-prototype.html` | 短信 Tab 补收发比行（UI 定稿参照同步） |
| 说明文档.md / CodeWiki.md / `?v=N` | 数据填充章节补齐（当前两文档均无 data.fill/data.clear 章节，属文档缺口）+ 能力计数同步 |
| `trollvnc-farm/web/caps.js` | **已核对**：data.fill params 含 ratios（object 自由字典，L67-73），键名变化零改动；caps-test.js BATCH_CAPS 数量不受影响 |

### 8.1 契约核对结论（本次需要遵守的既有契约）

| 契约 | 出处 | 结论 |
|---|---|---|
| 能力层唯一地基（设备操作走注册表） | AGENTS.md 红线 | data.fill 已在地基内；**data.clear 新增进地基** |
| 新增能力两端各加一条 | AGENTS.md 流程 2 | **本次适用**：data.clear = TRCapabilityRegistry + caps.js BATCH_CAPS 各加一条（21→22）+ caps-test.js 断言 + 文档计数；ratios 键为自由字典，data.fill 定义零改动 |
| 注释与实现一致 | AGENTS.md 流程 4 | 改键名同步 TRFillDataGenerator/TRDataFiller 注释 |
| 跨端语义一致（5801/网关/App） | AGENTS.md 流程 5 | 三端同一 data.fill/data.clear 契约；5801 本次补齐入口（App 完整参数、网关/5801 简化参数缺省 ratios） |
| 文档同步同一 commit | AGENTS.md 流程 1 | 说明文档.md + CodeWiki + ?v=N + 原型收发比，与代码同一 commit |
| 写入格式定稿 | D8 说明文档.md | ZCALLRECORD/sms.db 格式沿用现有 TRDataFiller（已实证） |
| 刷新只 kill daemon，禁 respring | AGENTS.md 红线 | 沿用现有 kill callservicesd/imagent/contactsd（清空同） |
| 依赖校验语义 | D2 §3.3 | 通讯录为空返回错误提示先生成通讯录（清空后同样生效） |
| 验证门槛 | AGENTS.md | IPA 改动 CI 编译通过；网关改动 npm test（caps-test.js 断言更新后必须全过） |

## 9. 明确不做（防止跑偏）

- ❌ 完整 Persona 体系（rank/layer/remarkStyle/creationDaysAgo 结构化持久化）——D2 §2.1 已定稿"无演员表、无持久化"，反查直接读系统通讯录
- ❌ 运营商号段表（用户澄清：carrier 只决定客服来电/服务短信，不决定号码段）
- ❌ 会话簇长往返（D2 §2.3 定稿：家人朋友仅简短 1-3 条，不做 5-20 条往返）
- ❌ 短信附件/群聊/iMessage/FaceTime/头像/邮箱/地址/生日/第二号码
- ❌ 指纹驱动/幂等账本/备份三件套（D4 早期约束；当前 schema 已实证、guid 用 UUID 天然唯一、评估机可重置，触发条件：换设备/iOS 版本需重跑 data.probe 时再评估）
- ❌ respring（项目红线，只 kill daemon）

## 10. 验证方案（按三阶段门禁）

**阶段 1（外部算法）**：
1. `npm test` 全过（含 data-gen-test.mjs 断言：占比 ±2%、备注互斥、号码格式、昼夜分布、Zipf、seed 可复现）
2. **魔鬼测试全过**（§1.1 边界参数 / 数据源极端 / 随机压力 / 输出不变量恒成立，连续 100 轮不崩）
3. `data-gen-samples.mjs` 生成 3 组样例（不同省市/运营商/收发比/占比组合）→ **用户审查内容质量，调参收敛**（此步为阶段 1 门禁，通过才进阶段 2）

**阶段 2（App 集成）**：
3. CI 四 scheme 编译全过（含 bootstrap）；BRPickerView 集成后确认编译
4. 真机：联系人（省市生成/备注互斥/号码本地异地）→ 通话（反查命中联系人名/运营商客服短号/未接集中陌生号/昼夜分布）→ 短信（收发比 2:8/运营商特服号/内容池不重复/未接联动）→ 清空（系统 App 数据消失/依赖校验生效/重复清空幂等）
5. **同 seed 对照**：真机批量生成输出 JSON，与 Node 副本同 seed 输出 diff（防两端漂移）

**阶段 3（UI 联动）**：
6. 面板全流程：省市选择器回显 / 收发比滑条 / 清空确认弹窗 / 依赖提示 / 占比合计校验
7. 文档同步（说明文档.md / CodeWiki / 原型 / `?v=N`，与代码同一 commit）；网关 `npm test` 全过（caps-test.js 21→22）

## 11. 待确认（集成期核实，不阻塞设计）

1. **数据源落地**：`province-city-china`（民政部，含 district-code 区号包）与 `ChinaCityList`（MIT 完整地级市+区号）选型确认——**以能拿到原始数据文件 + 来源可溯源为准**，落地进 `trollvnc-farm/test/data-gen/area-data/`（vendor，注明来源与版本）
2. **手机号段完整清单**：按工信部《电信网编号计划》整理完整号段（含虚商 162/165/167/170/171），构建期生成
3. BRPickerView V3 `BRTextPickerView` 省市两列 API（拉源码确认）
4. ObjC 静态表生成方式：构建脚本产出 `TRAreaCodes.mm` / `TRCorpus.mm`（提交产物）vs 运行时文件加载——**倾向构建期生成提交**（App 无 Node 运行时）
5. **语料库落地**：`corpus.js` 完整语料（§1.2 规模：姓名 100×120 / 词池 50+40+15+15 / 模板 25+20+20+20+20+30 / 品牌池每类 8-12）一次编写落地 + 语料自检并入 data-gen-test
