# 数据生成器（通讯录/通话记录/短信）设计

> 日期：2026-08-24
> 状态：待审查
> 前置调研：《Filza-数据填充-调研报告.md》（outputs/，2026-08-11，三类 DB 直写机制实证）

## 1. 背景与目标

SuperPhone 控制台（网关 + 5801 直连页）当前已具备应用枚举/启动、触控、相册导入等能力。本次新增**数据生成**能力：在设备上生成随机通讯录、基于当前时间的来去电通话记录、收发短信记录，用于模拟真实设备使用数据。

**验收标准**：点击控制台按钮 → 设备生成数据 → 系统原生 UI（通讯录/电话/信息 App）可读到新数据；重复点击累加不覆盖。

## 2. 能力评估结论（已确认具备）

- **权限**：TrollStore 安装的 .tipa 已含 `platform-application` + `no-container` + `storage.CallHistory` + `storage.Messages` + `persona-mgmt`；三个数据库（`CallHistory.storedata`/`sms.db`/`AddressBook.sqlitedb`）全在 `/var/mobile/Library`，属主 mobile:mobile，与 trollvncserver 同 uid → 文件系统层可写
- **写入路线**（复用调研结论）：通话 = DB 直写（唯一）；短信 = DB 直写（唯一）；联系人 = DB 直写（备选 CNContactStore 公开 API）
- **生效**：写后 kill `callservicesd`/`imagent`/`contactsd`（同 uid 直接 kill，persona-mgmt spawnRoot 兜底）
- **技术缺口（本次补齐）**：Makefile 加 `sqlite3` 链接（已完成，提交 08f156c）

## 2.1 POC 实证（2026-08-24，真机 data.probe）

对三个库执行 `data.probe`（读 sqlite_master + 事务回滚写测试），**全部 writable=1**：

| 库 | 文件 | 属主 | 权限 | 可写 |
|---|---|---|---|---|
| 通话 | `/var/mobile/Library/CallHistoryDB/CallHistory.storedata` | 501:501 | 644 | ✅ |
| 短信 | `/var/mobile/Library/SMS/sms.db` | 501:501 | 644 | ✅ |
| 通讯录 | `/var/mobile/Library/AddressBook/AddressBook.sqlitedb` | 501:501 | 644 | ✅ |

**schema 实证结论（真机表结构，写入 SQL 以此为准）**：
- 通话：`ZCALLRECORD`（ZDATE/ZDURATION/ZORIGINATED/ZANSWERED/ZCALLTYPE/ZADDRESS/ZUNIQUE_ID）+ `Z_PRIMARYKEY`（确认存在，直插需同步）+ `ZHANDLE`
- 短信：`message` + `chat` + `chat_message_join` + `handle` + `chat_handle_join`（**POC 纠正：iOS 15+ 实测也有 handle 表**，写入必须处理）+ `attachment`
- 通讯录：`ABPerson` + `ABMultiValue` + `ABStore`（需查有效 StoreID）+ FTS 虚表

**偏差修正**：设计文档原假设"补 AddressBook entitlement"，POC 实测当前 entitlements（no-container + storage.*）已可直接写入三个库，**无需补任何 entitlement**。

## 3. 架构

```
设备端 TRCapabilityRegistry 新增 3 能力（唯一地基，路径 A 收敛原则）
  data.contacts.generate ─ 生成随机通讯录
  data.calls.generate    ─ 生成通话记录（基于当前时间）
  data.sms.generate      ─ 生成短信记录（基于当前时间）

网关新增 3 个中转路由（走隧道 invoke，跨网可用）
  POST /api/devices/:id/contacts-generate
  POST /api/devices/:id/calls-generate
  POST /api/devices/:id/sms-generate

双端 UI 各加 3 按钮
  网关控制台（trollvnc-farm/web/）：设备操作区「生成通讯录 / 生成通话记录 / 生成短信记录」
  5801 直连页（index.vnc）：工具栏同 3 按钮
```

**关键决策：生成算法放设备端**。网关只透传 invoke 参数，设备端就地生成随机数据并写库。优点：走隧道 invoke 跨网可用、数据不经过网络、与写库同进程、复用能力地基。5802 直连的 `tvExtHandle*` 同实现（语义对齐，复用纯函数，cl=NULL 可测）。

## 4. 数据生成算法（设备端自研）

### 4.1 通讯录（data.contacts.generate）
- 每次生成**随机数量 10-50 个**联系人
- 姓名池：中文姓名（常见姓 50 + 名池）+ 少量英文姓名，随机组合
- 号码池：`1[3-9]xxxxxxxxx` 随机，避免与已有重复（写前查询去重）
- 可选字段：邮箱（`name@qq.com/163.com/...`）、地址（随机城市+街道）、公司（随机池）
- 写入 `AddressBook.sqlitedb`：`ABPerson` + `ABMultiValue`（phone/email/label）

### 4.2 通话记录（data.calls.generate）
- 每次生成**固定组量 10-30 条**，时间戳基于当前时间，在最近 1-3 天自然分布（呼出时间按使用习惯聚类，如白天多）
- 类型分布：呼入/呼出/未接 + 少量 FaceTime（音频/视频）
- 时长：已接 10s-30min 随机；未接 0s
- 号码：优先匹配已有联系人号码（写前查询），无匹配则随机号码——保证"最近通话"能关联到联系人
- 写入 `CallHistory.storedata` → `ZCALLRECORD`（Cocoa 纪元秒、`Z_PRIMARYKEY` 同步）

### 4.3 短信记录（data.sms.generate）
- 每次生成**固定组量 15-40 条**，时间戳最近 1-3 天
- 会话拟真：随机选若干联系人，每个会话 2-10 条往返（收发交替），已读/未读状态自然混合
- service：SMS 为主，iMessage 少量；内容池（日常中文短句 + 快递/验证码类）
- 写入 `sms.db`：`message` + `chat` + `chat_message_join` + `handle` + `chat_handle_join`（POC 实证 iOS 15+ 均存在）

## 5. 写库技术要点

1. **Cocoa 纪元**：`cocoa = unix - 978307200`，所有时间字段用秒
2. **WAL 一致性**：写前对目标库 `PRAGMA wal_checkpoint(PASSIVE)` 或先完成 WAL 落盘，避免 -wal 未合并导致新数据不可见；必要时写后 `PRAGMA wal_checkpoint(TRUNCATE)`
3. **通话库 Core Data 簿记**：直插 `ZCALLRECORD` 必须同步 `Z_PRIMARYKEY` 表，避免后续系统写入主键冲突
4. **schema 已实证**：POC `data.probe` 已确认三个库真机表结构（ZCALLRECORD/Z_PRIMARYKEY、message/chat/handle/chat_handle_join、ABPerson/ABMultiValue/ABStore），写入 SQL 以此为准
5. **备份与回滚**：写库前复制 `DB + -wal + -shm` 三件套到临时目录，写入校验失败可恢复

## 6. 生效机制

写库完成 → kill `callservicesd`（通话）/ `imagent`（短信）/ `contactsd`（通讯录）→ launchd 自动拉起 → 系统 UI 重新读取新数据。同 uid 直接 `kill()`，失败用 persona-mgmt spawnRoot 兜底（复用 TrollStore `spawnRoot` 思路，代码自写）。

## 7. UI 设计

- 网关控制台：设备操作列新增 3 个按钮（生成通讯录/生成通话记录/生成短信记录），调用网关 3 个中转路由；执行结果 toast 展示（生成条数）
- 5801 直连页：工具栏/操作区同 3 按钮，调用 5802 直连 op；语义与网关端对齐（跨端一致性）
- 按钮点击 → 请求 → 设备生成 → 返回 `{ok, count}` → toast

## 8. 验证方案

1. **网关**：新增 3 路由，`npm test` 全过（11 套件不回归）
2. **设备端**：CI 编译通过
3. **真机验收**：点击按钮生成 → 打开系统通讯录/电话/信息 App 截图确认新数据可见 → 重复点击确认累加 → 重启设备确认数据持久
4. **schema 实证**：真机 `.schema` 与写入逻辑核对（iOS 版本差异）

## 9. 风险清单

| 风险 | 等级 | 缓解 |
|---|---|---|
| schema 版本差异 | 低 | POC 已实证当前设备（iOS 15+）三个库表结构；换设备/升级 iOS 需重跑 data.probe |
| iCloud 同步覆盖 | 中 | 评估机关闭 iCloud 通讯录/信息同步，或接受同步行为 |
| WAL 未合并导致新数据不可见 | 中 | 写前/写后 checkpoint |
| 通话库 Z_PRIMARYKEY 冲突 | 中 | 直插同步更新 Z_PRIMARYKEY |
| 数据交叉验证检测（风控类 App 读取 DB 校验） | 低 | 时间戳/号码/时长拟真，不追求极端真实 |
| daemon kill 权限 | 低 | 同 uid 直接 kill，persona-mgmt 兜底 |

## 10. 范围外（本次不做）

- 短信附件（图片/语音）
- 群聊
- 联系人头像
- 通话/短信内容的语义级拟真（如按时间段话题）
