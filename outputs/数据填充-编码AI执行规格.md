# 数据填充（通话记录/短信/联系人自动生成）· 编码 AI 执行规格（Handoff Spec）

> 供集成执行的编码 AI 使用。本文档是**唯一实施依据**；背景调研与风险清单见同目录《Filza-数据填充-调研报告.md》。
> 版本：v1.0（2026-08-11）｜状态：待执行
> 目标工程：现有 iOS IPA（TrollStore 安装，Swift/SwiftUI，macOS + Xcode 15+ 构建）

---

## 0. 执行者须知（先读这段）

**角色**：你是负责把"自动生成通话记录 / 短信 / 联系人"能力集成进现有 iOS IPA 工程的编码 AI。
**硬性前提**：目标设备已装 TrollStore（iOS 15.0–16.6.1 / 16.7 RC / 17.0）；工程为 Swift/SwiftUI；构建环境 macOS + Xcode 15+。
**最高优先级**：先执行第 4 节 Go/No-Go 实验，实验结果决定技术路线；**禁止跳过实验直接写正式功能**。
**三条写入路线的定论（本规格已定，不要推翻）**：
- 通话记录 → 只能 DB 直写 `CallHistory.storedata`（无公开写 API）
- 短信 → 只能 DB 直写 `sms.db`（无公开写 API）
- 联系人 → **首选公开 API `CNContactStore`**，DB 直写 `AddressBook.sqlitedb` 为备选（实验 3 定案）
**交付物**：8 个核心源文件 + entitlements 配置 + 单元测试 + 打包脚本 + 实验记录表 + schema 指纹 fixture。

---

## 1. 硬性约束（违反即返工）

| # | 约束 | 说明 |
|---|---|---|
| C1 | **零外部商业调用** | 不得集成任何需 API Key/配额/付费的服务 |
| C2 | **干净实现** | 参考 Filza/TrollStore/iLEAPP 的**思路与公开 schema**，不得复制其源码；私有接口声明自写 |
| C3 | **先探测后写入** | 写入前必须用 `SchemaProbe`（3.1）抓取目标库 schema 指纹；INSERT 列名/枚举值全部由指纹驱动，**禁止硬编码列清单** |
| C4 | **写前备份** | 任何写入前必须 `BackupManager` 备份 DB + -wal + -shm 三件套；失败可恢复 |
| C5 | **时间纪元** | 三个库时间字段一律 **Cocoa 纪元秒（2001-01-01 UTC 起）**；换算 `cocoa = unix - 978307200`；单元测试覆盖 |
| C6 | **写后刷新并验证** | 写入完成后必须按实验结论刷新（kill daemon / respring）并重新打开库验证行数与 `PRAGMA integrity_check` |
| C7 | **幂等** | 同一批数据重复执行不得产生重复记录（guid 唯一 + App 自带批次账本）|
| C8 | **iOS 版本** | 仅支持 TrollStore 2 范围（iOS 15.0–16.6.1 / 16.7 RC / 17.0）；iOS 18+ 不在范围 |
| C9 | **仅内部评估机** | 高权限 IPA 只装评估机，不对外分发 |
> ⚠️ **respring 已禁用（2026-08-24 项目红线）**：respring（kill SpringBoard）会重启主屏，中断前台 App、打断隧道/注册会话、破坏 daemon 保活链路；数据直写系统库后 kill 对应 daemon（callservicesd/imagent/contactsd）即可让系统 App 读取新数据，respring 属冗余设计。**全文所有涉及 respring 的描述一律作废**，刷新只允许 kill 对应 daemon，禁止按 respring 实现/回归。

---

## 2. 总体架构与模块清单

```
UI 层
  DataFillerView    参数面板（窗口时间/数量/模式 追加或重建/种子/语料选择）→ 进度条 → 结果报告
引擎层
  DataGenerator     拟真数据生成（联系人/通话/短信线程，时间线互洽，可复现种子）
  SchemaProbe       目标库 schema 指纹（表/列/类型/抽样真实行/Z_PRIMARYKEY）
写入层
  BackupManager     写前备份三件套 + 恢复
  CallRecordWriter  ZCALLRECORD 直插 + Z_PRIMARYKEY 更新
  SMSWriter         chat/message/join 直插（+iOS17 handle）
  ContactWriter     CNContactStore（主）/ AB 库直写（备）
支撑
  ProcessControl    persona 99 spawnRoot / kill / launchctl kickstart / respring
  DataFillerCoordinator  总编排：状态机 + 失败恢复 + 验证
```

> 🖥️ **交互原型（UI 定稿参照）**：`outputs/locsim-app-prototype.html`——浏览器打开即可验证四 Tab（位置模拟/联系人/通话/短信）全部交互与最终 UI 形态；后续 UI 开发以该原型为准。

**模块依赖方向（禁止反向依赖）**：
`UI 层 → DataFillerCoordinator → {DataGenerator, SchemaProbe, BackupManager, 各 Writer, ProcessControl}`

---

## 3. 模块规格（接口签名 + 关键实现要点）

### 3.0 SQLite 基础设施（各 Writer 共用）
- 使用 iOS 系统库 `libsqlite3`（Swift `import SQLite3`），**零第三方依赖**
- 自写一个最小封装（约 120 行）：`open` / `exec` / `prepare` / `bind` / `step` / `finalize` / `lastInsertRowID` / `beginTransaction` / `commit` / `rollback` / `integrityCheck`
- 打开方式：普通打开（自动带 WAL）；**不要**在写入后立即 `PRAGMA wal_checkpoint`（是否必要由实验 E8 定案；默认不 checkpoint）

### 3.1 SchemaProbe.swift
```swift
struct TableSchema { let name: String
                     let columns: [String: String]        // 列名 -> SQLite 类型
                     let sampleRows: [[String: Any?]] }   // 前 3 行真实值（枚举/格式参考）
struct DatabaseSchema { let dbPath: String
                        let tables: [String: TableSchema]
                        let journalMode: String
                        let hasWAL: Bool
                        let entityMaxPK: [String: Int] }  // Core Data: 实体名 -> Z_PRIMARYKEY.Z_MAX
enum SchemaProbe {
    static func capture(dbPath: String, sampleLimit: Int = 3) throws -> DatabaseSchema
    static func captureAll() throws -> [String: DatabaseSchema]  // 三个库一次抓齐
}
```
要点：
- 实现：`SELECT sql FROM sqlite_master WHERE type='table'` + `PRAGMA table_info(<t>)` + `SELECT * FROM <t> LIMIT 3` + `PRAGMA journal_mode` + `SELECT Z_NAME, Z_MAX FROM Z_PRIMARYKEY`（仅通话库有）
- 三个库路径见附录 B；输出**保存为 fixture JSON**（随仓库提交，供测试复用）
- 若某库打不开/表不存在 → 记录到实验表，按第 4 节门禁判定

### 3.2 BackupManager.swift
```swift
struct DBBackup { let dir: String; let files: [String] }
enum BackupManager {
    static let backupRoot = "/var/mobile/Documents/DataFillerBackups"
    static func backup(_ dbPath: String) throws -> DBBackup   // 复制 db、db-wal、db-shm 到 <backupRoot>/<yyyyMMddHHmmss>/
    static func restore(_ backup: DBBackup) throws            // 三件套覆盖回原路径
}
```
要点：用 FileManager 复制；备份目录含时间戳；每个批次备份一次（不是每条记录一次）。

### 3.3 DataGenerator.swift（算法核心，重点写清楚）
```swift
struct Persona { let seed: UInt64
                 let activeHours: [Int]                  // 活跃小时集合，如 [8...23]
                 let weekendBoost: Bool
                 let frequentContacts: [String]          // 高频联系号码
                 let callIncomingRatio: Double           // 默认 0.6
                 let missedCallRatio: Double             // 默认 0.10（呼入中）
                 let replyLatency: ClosedRange<Int>      // 默认 20...600 秒
                 let unreadRatio: Double                 // 默认 0.15 }
struct CallEvent { let date: Date; let duration: TimeInterval
                   let address: String; let originated: Int   // 0 呼入 / 1 呼出
                   let answered: Bool; let callType: Int      // 1 电话 / 8 FT视频 / 16 FT音频
                   let disconnectedCause: Int; let serviceProvider: String? }
struct MessageItem { let guid: String; let text: String; let date: Date
                     let dateDelivered: Date?; let dateRead: Date?
                     let isFromMe: Bool; let isSent: Bool; let isDelivered: Bool; let isRead: Bool }
struct MessageThread { let chatIdentifier: String; let service: String   // "iMessage"/"SMS"
                       let isGroup: Bool; let messages: [MessageItem] }
struct GeneratedContact { let givenName: String; let familyName: String
                          let phones: [(label: String, number: String)]
                          let emails: [(label: String, value: String)]
                          let organization: String?; let jobTitle: String?
                          let note: String?; let birthday: Date? }
enum DataGenerator {
    static func generateContacts(seed: UInt64, count: Int) -> [GeneratedContact]
    static func generateCalls(persona: Persona, window: ClosedRange<Date>, count: Int) -> [CallEvent]
    static func generateMessageThreads(persona: Persona, window: ClosedRange<Date>,
                                       threadCount: Int, messagesPerThread: ClosedRange<Int>) -> [MessageThread]
}
```
**算法要点（拟真，禁止均匀分布/过度完美）**：
1. **时间分布**：日期在 window 内，时刻服从 activeHours 加权密度（早晚高峰更高）；周末活跃度不同（weekendBoost）；相邻事件间隔符合偏态（多数短间隔、少数长间隔），不用均匀随机
2. **通话拟真**：呼入/呼出比例按 persona；呼入中 5–15% 未接（duration=0, answered=false, disconnectedCause=6）；接通时长偏态分布 20s–45min（多数 1–5min）；FaceTime 类型占少量（如 5%）；号码从 frequentContacts + 生成号码池中选，高频联系人占比高
3. **短信拟真**：每个线程先定会话对象（与联系人/通话共享号码池，保证互洽）；消息成"会话片段"（burst）：1–8 条集中在 1–15 分钟内，交替 is_from_me，回复延迟按 replyLatency；部分消息未读（is_read=false）；iMessage 用 UUID 大写 guid（唯一），SMS 用设备抽样到的真实 guid 格式（来自 SchemaProbe.sampleRows）
4. **幂等**：每批数据用批次种子 + 起始时间戳生成，guid 全局唯一；App 记录已用 guid 集合到自身容器（UserDefaults/JSON），重复执行跳过已存在 guid
5. **语料**：预置中文/英文常用口语短句库（300+ 条，分问候/工作/家庭/闲聊类别）；号码段多样（13x/15x/18x/17x 混合，含 010 座机少量）；联系人姓名中英混合，部分带 Organization/JobTitle

### 3.4 CallRecordWriter.swift
```swift
struct CallRecordWriter {
    static func insert(calls: [CallEvent], schema: DatabaseSchema) throws -> Int
}
```
要点：
- 打开 `CallHistory.storedata`；事务内逐条 INSERT `ZCALLRECORD`
- 列名/类型来自 `schema.tables["ZCALLRECORD"].columns`（**禁止硬编码**）；必填：`ZDATE`（Cocoa 秒）、`ZDURATION`、`ZORIGINATED`、`ZADDRESS`、`ZANSWERED`、`ZCALLTYPE`、`ZDISCONNECTED_CAUSE`；可选（有抽样值就填）：`ZSERVICE_PROVIDER`、`ZISO_COUNTRY_CODE`、`ZLOCATION`
- Core Data 簿记：`Z_PK` = `schema.entityMaxPK["ZCallRecord"] + 1` 起递增；`Z_ENT` 从 `Z_PRIMARYKEY` 查（找 Z_NAME='ZCallRecord' 的 Z_ENT）；`Z_OPT = 1`
- 提交后 `UPDATE Z_PRIMARYKEY SET Z_MAX = <新最大值> WHERE Z_ENT = <ZCallRecord 的 Z_ENT>`
- 返回插入行数；失败回滚
- 刷新：由 Coordinator 调 `ProcessControl.refresh(dataKind: .callHistory)`（实验 1 定 kill vs respring）

### 3.5 SMSWriter.swift
```swift
struct SMSWriter {
    static func insert(threads: [MessageThread], schema: DatabaseSchema) throws -> Int
}
```
要点：
- 打开 `sms.db`；事务内逐线程处理：
  1. 若该 `chat_identifier` 已存在 → 复用 chat ROWID；否则 INSERT `chat`（chat_identifier, account_login, service_name）取 `last_insert_rowid`
  2. 逐条 INSERT `message`（guid, text, date/date_delivered/date_read 转 Cocoa 秒, service, is_from_me, is_sent, is_delivered, is_read）；ROWID 让 SQLite 自增（**不手动指定**，真实设备存在空洞属正常）
  3. INSERT `chat_message_join`（chat_id, message_id）
  4. **iOS 17**（schema 含 handle 表时）：INSERT `handle`（id=chat_identifier, service）取 ROWID，INSERT `chat_handle_join`；列名以指纹为准
- 附件（可选，M6）：attachment 行 + message_attachment_join + 文件写入 `Attachments/<UUID>/`，三者一致
- 刷新：`ProcessControl.refresh(dataKind: .sms)` → kill imagent（实验 2 定）

### 3.6 ContactWriter.swift
```swift
enum ContactRoute { case cnContactStore, directDB }
struct ContactWriter {
    static func insertViaCNContactStore(_ contacts: [GeneratedContact]) throws -> Int
    static func insertViaDirectDB(_ contacts: [GeneratedContact], schema: DatabaseSchema) throws -> Int
}
```
要点（主路线 CNContactStore）：
- Info.plist 必须含 `NSContactsUsageDescription`；首次调用 `CNContactStore.requestAccess(for: .contacts)`
- `CNSaveRequest` + `CNMutableContact`（givenName/familyName/phoneNumbers/emailAddresses/organization/jobTitle/note/birthday）；`store.execute(request)`
- 系统自动建索引，**无需杀进程**；返回写入数
- 备选 directDB（实验 3 失败才启用）：
  - INSERT `ABPerson`（First/Last/DisplayName/CreationDate/ModificationDate 转 Cocoa 秒/StoreID 取 `ABStore` 现有 ROWID，通常 1/Kind=0）
  - INSERT `ABMultiValue`（record_id=ABPerson ROWID, property=3 电话 / 4 邮箱, value, label 引用 `ABMultiValueLabel` 现有 ROWID 或按指纹插入, UID 唯一）
  - 刷新：kill `contactsd`（存在时）或 respring（实验 3 定）

### 3.7 ProcessControl.swift
```swift
enum ProcessControl {
    static func spawnRoot(_ path: String, args: [String]) throws -> (stdout: String, stderr: String)
    static func kill(_ processName: String) throws
    static func kickstart(_ label: String) throws          // launchctl kickstart -k system/<label>
    static func respring() throws
    static func refresh(dataKind: DataKind) throws         // callHistory / sms / contacts
}
```
要点：
- `spawnRoot`：自写 `posix_spawn` + `posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE)` + `set_persona_uid_np(&attr, 0)` + `set_persona_gid_np(&attr, 0)`（**机制参考 TrollStore，代码自写**）；extern 声明三个私有函数
- `kill`：优先同 uid POSIX `kill(pid, SIGKILL)`（目标 daemon 均为 mobile，同 uid 可行）；失败再走 `spawnRoot("killall", [processName])`
- `refresh(.callHistory)`：kill `callservicesd`；`refresh(.sms)`：kill `imagent`；`refresh(.contacts)`：kill `contactsd`（若进程存在；属主与刷新必要性由实验 3 实测；CNContactStore 路线不调用）
- `respring`：`spawnRoot("killall", ["SpringBoard"])`（App 会退出，调用前先落盘所有状态）
- **实验 1/2 定案前，刷新策略按"kill daemon + 不 respring"实现，开关可配置**

### 3.8 DataFillerCoordinator.swift
```swift
enum FillMode { case append, rebuild }
struct FillRequest { let mode: FillMode
                     let window: ClosedRange<Date>
                     let callCount: Int; let threadCount: Int; let contactCount: Int
                     let seed: UInt64; let persona: Persona }
struct FillReport { let callsInserted: Int; let messagesInserted: Int
                    let contactsInserted: Int; let backups: [String]
                    let refreshLog: [String]; let verified: Bool }
enum DataFillerCoordinator {
    static func run(_ request: FillRequest,
                    progress: @escaping (String, Double) -> Void) async throws -> FillReport
}
```
状态机：`idle → probing → backingUp → generating → writing → refreshing → verifying → done | failed`
- 失败路径：任一步抛错 → 回滚当前事务 → 记录错误 →（可选）`BackupManager.restore` → 返回 failed（**不静默吞错**）
- verifying：重新打开三个库，校验（a）行数≥预期；（b）`PRAGMA integrity_check` = ok；（c）guid 无重复；（d）样本 SQL 可查出刚插入的最近 N 条
- `rebuild` 模式：先清空本批次标记的旧数据（App 账本记录 guid），再插入；`append` 模式：只追加

---

## 4. 前置验证实验（Go/No-Go，先于一切正式开发）

### 实验 0：环境与探测（0.5 天，门禁 0）
- 步骤：目标机装最新 IPA → 打开 → `SchemaProbe.captureAll()`
- 判定：三库指纹全部抓取成功（表存在、抽样行可读） = **Pass** → 继续；任一库失败 = **No-Go**（先排查 entitlements，再排查设备/iOS 版本，禁止带病开发）

### 实验 1：通话最小写入 + 刷新方式定案（门禁 1）
- 步骤：插 1 行 ZCALLRECORD（用指纹驱动）→ 三态对比：A) 仅 kill callservicesd；B) respring；C) 什么都不做只重开电话 App
- 记录：电话 App"最近通话"是否显示｜日期时长是否正确｜`CallHistory.storedata` 行数是否+1｜重启后是否仍在
- 判定：任一态下 UI 可见 = **Pass** → 按最优态实现 `refresh(.callHistory)`；全部不可见 = **No-Go**

### 实验 2：短信最小写入 + 刷新方式定案（门禁 2）
- 步骤：插 1 条 message + chat + join（iOS17 含 handle）→ 对比 kill imagent / respring
- 记录：信息 App 是否显示会话与内容｜时间正确｜重启后仍在
- 判定：可见 = **Pass**；否则 **No-Go**

### 实验 3：联系人路线定案（门禁 3）
- 步骤：CNContactStore 写 1 个测试联系人 → 通讯录 App 查看
- 判定：可见 = **Pass**（主路线 CNContactStore 定案，directDB 仅保留为代码路径但默认关闭）；不可见且授权正常 = 试 directDB 1 条，仍失败 = **No-Go**

### 实验 4：批量 + 持久性
- 步骤：200 联系人 / 1000 短信 / 500 通话 → respring → 关机重启 → 再查
- 判定：重启后数据完整、integrity_check ok = **Pass**；否则排查 WAL（E8 结论）与 daemon 冲突

### 实验 5：iCloud 影响（记录用，非门禁）
- 步骤：iCloud 云端信息开/关各写一批，10 分钟后查存活
- 记录：是否被覆盖/同步
- 结论：写入评估机配置建议（默认建议关闭）

### 实验 6（可选）：附件注入
- 步骤：1 条带图片消息（attachment 三件套）→ 信息 App 查看缩略图
- 判定：显示正常 = Pass（M6 才需要）

**实验记录表模板**（每个实验输出一张表，作为交付物提交）：
| 实验 | iOS版本 | 设备 | 结果字段1 | 结果字段2 | Pass/No-Go | 结论 |

---

## 5. 里程碑与验收（带 Go/No-Go 判定）

| 里程碑 | 任务 | 验收标准（可判定） |
|---|---|---|
| M1 | 实验 0 + 实验 1 | 三库指纹抓齐；1 条通话在电话 App 可见；刷新策略定案 |
| M2 | 实验 2 + 实验 3 | 1 条短信在信息 App 可见；联系人路线定案 |
| M3 | DataGenerator + 批量填充 | 全量批次（附录 B 规模）写入成功；guid 无重复；时间线拟真（单测覆盖）|
| M4 | 刷新 + 持久性 | respring 与重启后数据完整；integrity_check ok |
| M5 | 集成进 IPA（UI + 编排 + 日志） | DataFillerView 可一键填充；FillReport 显示；失败可恢复 |
| M6（可选） | 附件 / 群聊 / FaceTime 类型扩展 | 附件缩略图正常；群聊显示成员；FT 记录类型正确 |

---

## 6. 测试要求（纯本地 XCTest，随构建运行）

| 测试 | 断言 |
|---|---|
| CocoaTimeTests | 2001-01-01 00:00:00 UTC = 0；2026-08-11 00:00:00 UTC = 808099200（计算值，测试里用固定常量）；往返一致 |
| SchemaProbeTests | 对内存 fixture 库（用三库真实 .schema 建表）抓指纹：表/列/类型齐全 |
| CallRecordWriterTests | fixture 库插入后行数+1；Z_PRIMARYKEY.Z_MAX 正确递增；事务失败回滚 |
| SMSWriterTests | 每线程 chat/message/join 三表一致；guid 唯一；重复执行幂等 |
| DataGeneratorTests | 时间单调不重叠越界；活跃时段外无事件；未接比例在 5–15%；回复延迟在 replyLatency 内；guid 唯一；同 seed 输出可复现 |
| BackupManagerTests | 三件套复制/恢复往返后字节一致 |
| ProcessControlTests | 仅测命令构造与参数（**不在单测中真实 kill/respring**）|

---

## 7. 明确"不做什么"（防止跑偏）

- ❌ 不复制 Filza / FilzaJailedDS / iLEAPP / TrollStore 源码（含头文件直接粘贴——接口自写声明）
- ❌ 不越狱、不做内核漏洞（iOS 17 的 sandbox_escape/apfs_own 那一级本项目不需要）
- ❌ 不写 /System、/var/root、其他 App 沙盒数据（目标 DB 全在 /var/mobile/Library）
- ❌ 不碰 iCloud 账号数据、不动非评估机数据
- ❌ 不实现 iMessage"真正发送"（需要 Apple 服务器交互，超范围；只造本地记录）
- ❌ 不实现"拨打/接听"行为（只生成历史记录）
- ❌ 不承诺"绝对不被检测"（数据级交叉验证检测在方案边界外，见调研报告 7.6）
- ❌ 不做 iOS 18+ 支持
- ❌ 不集成任何商业 SDK / 付费 API
- ❌ 不做 App Store 上架相关
- ❌ 不在无实验定案前实现 `wal_checkpoint` / 附件 / 群聊（均为实验或 M6 后的事）

---

## 8. 完成自检清单（编码 AI 交付前逐项打勾）

- [ ] 实验 0–5 记录表齐全，结论明确（附件实验可选）
- [ ] 8 个核心文件实现完成，接口与本文一致
- [ ] 三库 schema 指纹 fixture JSON 已提交，写入 SQL 全部由指纹驱动（无硬编码列）
- [ ] Cocoa 时间转换单测全绿
- [ ] 写前备份三件套可恢复（已实测 restore）
- [ ] Z_PRIMARYKEY 更新实现且有单测
- [ ] 刷新策略（kill daemon / respring）按实验结论实现并可配置
- [ ] 幂等：同一批次重复执行无重复记录（guid + 账本）
- [ ] 批量填充后 respring + 重启数据完整、integrity_check ok
- [ ] DataFillerView 可一键执行全流程并显示 FillReport
- [ ] 未违反第 7 节任何"不做"

---

## 附录 A：SQL 插桩示例（占位符；列名以指纹为准，不得照抄）

```sql
-- 通话（CallHistory.storedata，Core Data 库）
INSERT INTO ZCALLRECORD (Z_PK, Z_ENT, Z_OPT, ZDATE, ZDURATION, ZORIGINATED, ZADDRESS,
                         ZANSWERED, ZCALLTYPE, ZDISCONNECTED_CAUSE, ZISO_COUNTRY_CODE)
VALUES (?1, ?2, 1, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'CN');
-- ?1 = Z_MAX+1；?2 = Z_PRIMARYKEY 中 ZCallRecord 的 Z_ENT；?3 = cocoa 秒；?4 = 时长秒

-- 短信（sms.db，普通 SQLite）
INSERT INTO chat (chat_identifier, service_name, account_login) VALUES (?1, ?2, ?3);
INSERT INTO message (guid, text, date, service, is_from_me, is_sent, is_delivered, is_read)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
INSERT INTO chat_message_join (chat_id, message_id) VALUES (?1, ?2);
-- iOS 17 追加：
INSERT INTO handle (id, service) VALUES (?1, ?2);
INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?1, ?2);

-- 联系人（AddressBook.sqlitedb，普通 SQLite；备选路线）
INSERT INTO ABPerson (First, Last, DisplayName, CreationDate, ModificationDate, StoreID, Kind)
VALUES (?1, ?2, ?3, ?4, ?4, 1, 0);
INSERT INTO ABMultiValue (record_id, property, value, label, UID)
VALUES (?1, 3, ?2, ?3, ?4);  -- property 3=电话；label 引用 ABMultiValueLabel.ROWID
```

## 附录 B：路径与配置速查

| 项 | 值 |
|---|---|
| 通话库 | `/var/mobile/Library/CallHistoryDB/CallHistory.storedata`（+ -wal/-shm；`CallHistoryTemp.storedata` 实验 E5 定）|
| 短信库 | `/var/mobile/Library/SMS/sms.db`（+ -wal/-shm）|
| 联系人库 | `/var/mobile/Library/AddressBook/AddressBook.sqlitedb`（+Images 可选）|
| 备份目录 | `/var/mobile/Documents/DataFillerBackups/<yyyyMMddHHmmss>/` |
| 通话 daemon | `com.apple.telephonyutilities.callservicesd`（mobile，可 kill）|
| 短信 daemon | `com.apple.imagent`（mobile，可 kill）|
| 联系人 daemon | `contactsd`（待实测；CNContactStore 路线不涉及）|
| respring | `killall SpringBoard`（root spawn）|
| entitlements | `com.apple.private.security.no-sandbox` = true；`platform-application` = true |
| Info.plist | `NSContactsUsageDescription`（联系人路线必填）|
| 参考源码（仅读思路） | iLEAPP `scripts/artifacts/{callHistory,sms,addressBook}.py`；TrollStore `Shared/TSUtil.m`；FilzaJailedDS `Tweak.m` |
