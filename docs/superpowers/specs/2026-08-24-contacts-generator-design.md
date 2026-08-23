# 通讯录生成器 · 实现规格（Design）

> 日期：2026-08-24
> 前置依据：《2026-08-24-数据生成算法-开源调研.md》（算法调研 + Persona Schema 定稿）、《说明文档.md §4.8》（三库写入格式定稿）
> 本规格是通讯录生成功能的唯一实现依据；短信/通话记录生成器后续按同模式另出规格

## 1. 目标与范围

在 SuperPhone 上实现**通讯录生成器**：用户通过配置表单（数量/地区/占比）点击生成 → 设备端生成一批拟真联系人写入系统通讯录（CNContactStore），系统通讯录 App 可见。

**范围**：
- ✅ 通讯录生成（Persona 池 + CNContactStore 写入）
- ✅ 配置表单（数量/地区/占比可调）+ 伪装页「通讯录」标签
- ✅ 设备端能力 + 网关中转 + 前端调用全链路
- ✅ 短信/通话记录生成（见《2026-08-24-calls-sms-generator-design.md》，依赖本规格的 TRRoleLexicon 反查）
- ❌ 改定位（另一窗口实施，伪装页标签位预留）

## 2. 通讯录生成模型

### 2.1 核心原则

**通讯录是"一个人"的通讯录**——一切从常住地 Profile 推导。**地域与关系是两个独立维度**：本地/全国都包含所有关系类型。

### 2.2 生成输入：常住地 Profile（可配置）

```
TRProfile:
  city          常住城市（决定本地 HLR 池，如 北京）
  contactCount  目标数量（默认 50，范围 1-500）
  regionLocal   本地占比（默认 0.65，范围 0-1）
  ratioFriend   朋友/熟人/同事占比（默认 0.55）
  ratioWork     工作/商务占比（默认 0.20）
  ratioService  生活服务占比（默认 0.12）
  ratioFamily   家人亲戚占比（默认 0.08）
  ratioBusiness 机构商家占比（默认 0.05）
  seed          随机种子（可复现，默认随机）
```

**说明**：无本人号码、无本人运营商——通讯录生成不依赖它们。联系人号码的运营商按**全国真实份额**分布（移动≈60%/联通≈20%/电信≈20%，与本人运营商无关）；本人运营商（carrier）用于**通话/短信生成**模拟运营商客服电话（10086/10010/10000）与服务短信，归后续规格。

### 2.3 生成器内部模型 vs 通讯录存储字段（重要区分）

**TRPersona 是生成器内部模型（内存中的"演员表"），不是通讯录存储结构。** 它分两类字段：

- **内部控制字段**（不写入通讯录，仅生成器用 + 供后续通话/短信生成作为输入）：
  ```
  layer / remarkStyle / rank / creationDaysAgo / phoneE164 / city / province / seed
  ```

- **通讯录存储字段**（写入系统通讯录的最小集——**用户强调：只生成名字 + 电话**）：
  ```
  name    显示名（备注模式生成的结果：张伟 / 爸爸 / 张师傅 / 快递小李 / XX银行）
  phone   裸号 11 位
  ```
  不做头像/邮箱/地址/生日/第二号码——通讯录里就是"名字 + 电话"的简单联系人。

即：**写入 CNContactStore 的就是"姓名 + 号码"的简单联系人**；`layer`/`rank` 等控制字段只存在于生成器返回值里（通话/短信生成时**不靠它**——直接读系统通讯录按备注名反查角色，见通话/短信规格 §2.1），绝不进通讯录。

### 2.4 默认占比（可配置表单调整）

| 关系类型 | 默认占比 | 备注模式 | 说明 |
|---|---|---|---|
| 朋友/熟人/同事 | 55% | 真名 90% + 昵称 10% | 社交主体（纯真名） |
| 工作/商务 | 20% | 真名+公司后缀（李强-XX公司） | 客户/供应商/同行 |
| 生活服务 | 12% | 职业+姓（张师傅/王阿姨） | 快递/家政/维修/电工/物业 |
| 家人亲戚 | 8% | 称谓（爸爸/二姨/三舅） | 本地+老家 |
| 机构商家 | 5% | 公司名（XX银行/10086） | 400/95xxx 号 |

**备注模式互斥约束（2026-08-24 定稿）**：各角色备注模式必须**互斥可反查**——通话/短信生成时读系统通讯录，用**生成算法同一份词池（TRRoleLexicon）** 的"逆"精确判定角色（称谓→family、职业词→service、机构词→business、公司后缀→work、无特征→friend 兜底）。故 work 必须带公司后缀、family 必须用纯称谓、**service 备注用"职业+姓"且不得含称谓字（阿姨/叔叔/姐/哥等）**，不允许角色间备注模式重叠。

**TRRoleLexicon（生成/反查共享词池，2026-08-24 定稿）**：生成器从对应池取词拼备注名，反查遍历同池匹配——**单一数据源，生成能识别的必能反查**：

| 角色 | 词池（静态常量） | 备注名生成 |
|---|---|---|
| family | 爸爸/妈妈/老爸/老妈/叔叔/阿姨/大伯/二叔/舅舅/姑姑/姨妈/爷爷/奶奶/外公/外婆/姥爷/姥姥/哥哥/姐姐/弟弟/妹妹/表哥/表姐/堂哥/老公/老婆/媳妇/儿子/女儿/宝贝/大姨/三舅… | 从池取 1 词 |
| service | 师傅/律师/医生/护士/老师/电工/快递/外卖/保洁/家政/物业/维修/装修/木工/水电/司机/中介/理发/美容/厨师… | 职业词+姓 |
| business | 银行/客服/保险/4S/营业厅/证券/基金/运营商… | 机构名 |
| work | 公司/科技/集团/工作室/贸易/建设… | 真名-公司名 |
| friend | 无池（纯姓名池） | 真名/昵称 |

**地域分配**：每类关系内部按 `regionLocal`（默认 65%）分本地号段、其余全国号段。

### 2.5 号码生成算法（中国 +86 手机号）

1. **号段池**：真实分配号段按运营商分类（移动/联通/电信/虚商），带份额权重
2. **城市池**：常住城市 + 全国主要城市（按人口权重）
3. **HLR 前缀池**：号段 × 城市 → 归属编码（如 1380=北京移动），保证"号段 ↔ 归属地"一致
4. **尾号**：0000-9999 随机
5. **去重**：与设备已有联系人号码查重 + 生成集合内去重
6. 存储：库内裸号（对齐 handle 表 id/uncanonicalized_id），显示时按需 +86

## 3. 配置表单设计（伪装页「通讯录」标签）

### 3.1 表单控件

| 控件 | 类型 | 默认 | 范围 |
|---|---|---|---|
| 生成数量 | 数字输入 | 50 | 1-500 |
| 常住地区 | 城市下拉 | 北京 | 主要城市列表 |
| 本地占比 | 滑块 0-100% | 65% | 0-100%（与全国互补） |
| 朋友/熟人占比 | 滑块 | 55% | 0-100%（五类合计须=100%，底部显示合计校验） |
| 工作/商务占比 | 滑块 | 20% | 同上 |
| 生活服务占比 | 滑块 | 12% | 同上 |
| 家人亲戚占比 | 滑块 | 8% | 同上 |
| 机构商家占比 | 滑块 | 5% | 同上 |
| 随机种子 | 文本 | 空（随机） | 填了可复现 |
| **生成按钮** | 按钮 | - | 校验通过后提交 |

**交互**：占比五滑块实时合计（底部显示"合计 100% ✓/✗"），不满足 100% 时生成按钮禁用；点击「重置默认」恢复 55/20/12/8/5 默认值。

### 3.2 提交契约（双入口，2026-08-24 定稿）

**App 伪装页**（5802 通用 invoke，直调本机 daemon）：
```json
POST http://127.0.0.1:5802/
{ "op": "invoke", "cap": "data.contacts.generate",
  "params": { "count": 50, "city": "北京", "regionLocal": 0.65,
              "ratios": { "friend": 0.55, "work": 0.20, "service": 0.12, "family": 0.08, "business": 0.05 },
              "seed": null } }
```

**外部**（网关中转，隧道 invoke）：
```json
POST /api/devices/{deviceId}/contacts-generate
{ "count": 50, "city": "北京", "regionLocal": 0.65,
  "ratios": { "friend": 0.55, "work": 0.20, "service": 0.12, "family": 0.08, "business": 0.05 },
  "seed": null }
```

## 4. 接口契约

### 4.1 设备端能力（TRCapabilityRegistry，唯一地基）

```
cap: data.contacts.generate（正式能力，替代 POC data.test 的 contacts 分支）
params: { count, city, regionLocal, ratios{friend,work,service,family,business}, seed }
返回: { ok, created: N, personas: N }   // created=实际写入数，personas=生成总数
行为: 生成 Persona 池 → CNContactStore 批量写入 → kill contactsd → respring 提示
```
> ⚠️ **respring 已禁用（2026-08-24 项目红线）**：respring（kill SpringBoard）会重启主屏，中断前台 App、打断隧道/注册会话、破坏 daemon 保活链路；数据直写系统库后 kill 对应 daemon（callservicesd/imagent/contactsd）即可让系统 App 读取新数据，respring 属冗余设计。**全文所有涉及 respring 的描述一律作废**，刷新只允许 kill 对应 daemon，禁止按 respring 实现/回归。

注册方式：`[registry _registerControl:@"data.contacts.generate" ...]`，executor 调用生成器（新文件 `src/TRContactsGenerator.mm`）+ 写入层（复用 data.test 已验证的 CNContactStore 逻辑）。

### 4.2 网关中转（server/index.js，外部走能力通道）

```
POST /api/devices/:id/contacts-generate
→ 校验 count(1-500)/city/ratios(合计≈1)
→ sendDeviceCmd(id, { cmd:'invoke', cap:'data.contacts.generate', params })
→ 返回 { ok, created } | 504 timeout
```

复用现有 `/apps` `/app-open` 的 sendDeviceCmd 模式（隧道 invoke，跨网可用）。

### 4.3 双入口（2026-08-24 架构定稿——统一落到 TRCapabilityRegistry）

**关键认知**：TRCapabilityRegistry 是 daemon 进程内组件，跨进程调用方（App/网关）都不能"直接调"，必须走通道。两条入口最终都落在 TRCapabilityRegistry（能力地基唯一），与改定位（sim.location.*）完全同一机制：

| 入口 | 调用方 | 路径 |
|---|---|---|
| **5802 HTTP 通用 invoke** | App 伪装页（原生，同设备） | `127.0.0.1:5802` POST `{"op":"invoke","cap":"data.contacts.generate","params":{...}}` → `tvHttpApiDispatch` 加通用 invoke 转发到 TRCapabilityRegistry |
| **隧道 CMD invoke** | 外部（网关/5801） | sendDeviceCmd → TRCapabilityRegistry |

**5802 新增通用 invoke op（`tvHttpApiDispatch` 加分发）**：`op=invoke, {cap, params}` → 查 TRCapabilityRegistry 执行 executor 并返回。伪装页改定位/生成/短信/通话任何标签统一走此入口，与外部能力调用同一套 executor。

App 伪装页调用示例（NSURLSession，复用 App 现有 http 模式 + 5802 自签信任）：
```objc
POST http://127.0.0.1:5802/  body={ "op":"invoke", "cap":"data.contacts.generate", "params":{ count, city, regionLocal, ratios, seed } }
```

## 5. 伪装页集成（App 内，原生页面）

### 5.1 页面结构

伪装页 = **App 第三 Tab（控制后、设置前）原生页面**，四标签：

| 标签 | 状态 |
|---|---|
| 改定位 | 能力已实现（daemon `SimLocationManager.mm`/`SimLocationController.mm`，`sim.location.track`/`sim.route.calculate` + SimLocation* 配置），伪装页标签需调 daemon 能力（改定位窗口实施） |
| **生成通讯录** | ✅ 本次实现 |
| 生成短信 | 通话/短信规格 |
| 生成通话记录 | 通话/短信规格 |

### 5.2 载体方案（2026-08-24 架构定稿）

- **App**：`TRMainTabBarController` 新增**第三 Tab「伪装」**（连接/控制/**伪装**/设置），**原生页面**（UITableView/表单），四标签在原生页内切换（segment/页面）
- **调用**：伪装页直接调本机 daemon **5802**（`127.0.0.1:5802`，NSURLSession + 自签信任，复用 App 现有 http 模式）——改定位/生成通讯录/短信/通话记录四个标签统一走此入口
- **外部**：网关/5801 走 TRCapabilityRegistry 能力通道（§4.3）
- **对齐**：改定位标签复用已实现的 daemon 能力（sim.location.track 等），伪装页只做原生表单 + 调用

### 5.3 通讯录标签流程

```
填写表单 → 校验 → 生成按钮 → 调 127.0.0.1:5802 {op:'invoke', cap:'data.contacts.generate', params}
→ toast(成功 created N) → 提示"已写入，需 respring 生效" → 提供「立即 respring」按钮（调 data.respring）
```

### 5.4 UI 定稿（成品形态，2026-08-24 确认）

> 🖥️ **交互原型（UI 定稿参照）**：`outputs/locsim-app-prototype.html`——浏览器打开即可验证四 Tab（位置模拟/联系人/通话/短信）全部交互与最终 UI 形态；后续 UI 开发以该原型为准。

**页面结构**（iOS 原生，主题紫 107/78/255）：
```
状态栏（时间/电量）
标题「伪装」
顶部 segment：改定位 | 通讯录 | 短信 | 通话记录（四标签切换）
内容区（当前标签：算法说明区 + 表单区 + 生成按钮 + 提示区）
底部 TabBar：连接 | 控制 | 伪装(高亮) | 设置
```

**各标签结构**（统一三段式）：
1. **算法说明区**：顶部浅紫底色文字块，简述生成算法（如"常住地 HLR + 五类关系占比…"）
2. **表单区**：参数行（label + 控件），占比较多的用滑块（滑轨 + 填充 + 手柄 + 百分比），输入用圆角输入框
3. **生成区**：紫色实心「生成」按钮 + 底部提示（"基于通讯录生成" / "已写入 N 条 · 需 respring 生效 → 立即 respring"）

**交互规范**：
- 占比滑块组实时合计，底部显示"合计 100% ✓/✗"；不满足 100% 时生成按钮禁用
- 「重置默认」恢复各标签默认参数
- 生成按钮点击 → 生成中 → ✓ 已生成；成功后显示"需 respring 生效"并提供「立即 respring」
- 通话/短信标签顶部提示"基于通讯录生成，请先生成通讯录"（依赖校验）

**视觉**：卡片式表单行（细分割线）、紫色主题强调、原生 UIKit 控件（UISlider/UITextField/UISegmentedControl 风格）

## 6. 实现分层

```
┌ App 伪装页（第三 Tab 原生页面，四标签）      ← §3/§5
├ 设备端 5802 通用 invoke（App 直调入口）      ← §4.3
├ 设备端能力（TRCapabilityRegistry，外部入口） ← §4.1
├ 设备端写入层（CNContactStore，已验证）      ← 复用 data.test contacts 分支
└ 设备端生成器（TRContactsGenerator.mm）      ← 纯函数：Profile+随机源 → Persona[]
```

**生成器与写入解耦**：`TRContactsGenerator` 输出 `TRPersona[]`（纯函数，seed 可复现，可单测；含内部控制字段供后续通话/短信用）→ 写入层**只取 name/phone 两个存储字段**逐个转 CNMutableContact（familyName=name、phoneNumbers=@[phone]）；Persona 完整结果序列化返回给调用方，不落入通讯录。

## 7. 验证方案

1. **生成器单测**：固定 seed 输入 → 断言 Persona 数量/占比/备注模式/号码格式（号段真实、归属地合理、无重复）
2. **端到端**：表单生成 50 个 → 系统通讯录可见 → 占比统计接近配置值 → respring 后仍存在
3. **幂等/累加**：重复生成累加不覆盖；数量大（500）性能可接受
4. **回归**：网关 `npm test` 全过；设备端 CI 编译通过

## 8. 范围外

- 联系人头像/邮箱/地址/生日/第二号码（明确不做，通讯录仅"名字 + 电话"）
- 群聊/iMessage、短信附件、FaceTime 通话（见通话/短信规格）
- 伪装页改定位标签（另一窗口）
