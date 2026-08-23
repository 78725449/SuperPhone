# Filza 文件管理原理 + iOS 通话记录/短信/联系人自动生成 · 调研报告

> 适用范围：TrollStore 评估机（iOS 15.0–16.6.1 / 16.7 RC / 17.0），内部自用、非商用
> 调研日期：2026-08-11
> 配套执行文档：《数据填充-编码AI执行规格.md》（另一台编码 AI 的唯一实施依据）
> 本文档 = 背景调研 + 风险清单；执行请以执行规格为准

---

## 0. 结论速览

| 问题 | 结论 |
|---|---|
| Filza 是什么 | 商业文件管理器（com.tigisoftware.Filza）= 普通 App + root helper（XPC 守护进程）。核心能力：全盘浏览/复制/改权限 + **SQLite 编辑器** + plist 编辑器 + 压缩/WebDAV |
| 无越狱（TrollStore）下 Filza 怎么工作 | App 以 mobile 用户 + `platform-application` + `no-sandbox` 运行 → **/var/mobile 下所有文件可读可写**；/System 等 root 属主目录只读 |
| iOS 17+ 无越狱怎么提权 | 注入 dylib + 内核漏洞（kexploit）→ `sandbox_escape` → `sandbox_elevate_to_root` → `apfs_own`（root 文件翻转成 501:501）。**本项目不需要这一级** |
| 我们要复刻 Filza 的什么 | 不是复刻 Filza 本体，是复刻三个能力：① no-sandbox 直写系统 DB；② SQLite 读写（iOS 自带 libsqlite3）；③ TrollStore `spawnRoot`（persona 99 + uid 0）杀/重启守护进程 |
| 三类数据在哪 | 通话：`/var/mobile/Library/CallHistoryDB/CallHistory.storedata`；短信：`/var/mobile/Library/SMS/sms.db`；联系人：`/var/mobile/Library/AddressBook/AddressBook.sqlitedb`（+Images） |
| 写入路线 | 通话 = **DB 直写（唯一）**；短信 = **DB 直写（唯一）**；联系人 = **CNContactStore 公开 API（首选）/ DB 直写（备选）** |
| 写完后怎么生效 | kill 对应 daemon（callservicesd / imagent / contactsd）→ launchd 自动拉起；必要时 respring（`killall SpringBoard`） |
| 能不能做 | 能。机制全部有源码实证，且目标 daemon 均为 mobile 属主（与我们 App 同 uid，杀进程无权限障碍） |
| 最大风险 | iCloud 同步覆盖、schema 随版本变化（iOS 17 新增 handle 表）、WAL 一致性、数据级交叉验证检测 |
> ⚠️ **respring 已禁用（2026-08-24 项目红线）**：respring（kill SpringBoard）会重启主屏，中断前台 App、打断隧道/注册会话、破坏 daemon 保活链路；数据直写系统库后 kill 对应 daemon（callservicesd/imagent/contactsd）即可让系统 App 读取新数据，respring 属冗余设计。**全文所有涉及 respring 的描述一律作废**，刷新只允许 kill 对应 daemon，禁止按 respring 实现/回归。

---

## 1. 需求与边界

**目标能力（本次请求）**
1. 在 TrollStore 评估机上**自动生成通话记录**（呼入/呼出/未接，含时长、FaceTime 类型）
2. **自动生成短信/iMessage**（会话线程、双向对话、已读/未读状态、时间线拟真）
3. **自动生成联系人**（姓名、号码、邮箱、地址、头像可选）
4. 三者**时间线与内容互相自洽**，能被系统 UI（电话/信息/通讯录）正常读取

**边界确认**
- 仅内部评估机自用，不对外商用/分发
- 不越狱；只依赖 TrollStore（iOS ≤17.0）
- 集成由另一台编码 AI 执行 → 交付"接口签名 + 验收可判定 + 禁令明确"的执行规格
- 最终集成进**我们自研的 IPA**（此前虚拟定位工程的同一套壳）

---

## 2. Filza 如何管理 iOS 系统文件（源码实证）

### 2.1 Filza 架构（正常越狱模式）
- Filza 本体是普通 App；所有"系统级"操作走 **root helper**（XPC 守护进程）
- 核心类 `TGRootFileManager`（已在 FilzaJailedDS 的 hook 名中实证：`spawnRootHelper` / `spawnRootHelperIfNeeds` / `respawnRootHelper` / `spawnRoot:args:pid:`）
- 能力清单：全文件系统浏览/复制/移动/删除、chmod/chown、**SQLite 编辑器（看表、执行 SQL、改数据）**、plist 编辑器、压缩/解压、WebDAV、App 数据管理

### 2.2 TrollStore / 无越狱模式（iOS 15/16）—— 本项目适用场景
- TrollStore 安装的 IPA 可用 ldid 任意签名，携带系统级 entitlement：`platform-application` + `com.apple.private.security.no-sandbox`
- 效果：App 以 **mobile 用户 + 无沙盒**运行 → `/var/mobile` 下所有文件可读可写
- 通话/短信/联系人三个数据库**全部位于 /var/mobile/Library**，属主为 mobile:mobile → **直接可写，无需 root**
- 限制：root 属主目录（/System、/var/root、/var/db 部分）只读 → 本项目不涉及

### 2.3 iOS 17+ 无越狱（FilzaJailedDS 参考实现）—— 本项目不需要
- `34306/FilzaJailedDS`（Tweak.m 已全文读源码，656 行）：
  1. hook `TGRootFileManager` 的 root helper 方法（让 Filza 以为 helper 存在）
  2. 运行内核漏洞 `kexploit_opa334()` 获得内核读写
  3. `sandbox_escape(self_proc_addr)` — 内核层改 sandbox extension 数据
  4. `sandbox_elevate_to_root()` — 把进程 p_ucred 换成 launchd 的 uid 0（源码含此注释逻辑）
  5. `apfs_own(path, 501, 501)` / `apfs_own_tree` — 把磁盘上 root 属主文件翻转成 501:501 让 mobile 可写
- 目的：让 Filza 能写 `/var/root`、`/System` 等 root 文件。**我们的三类 DB 全在 /var/mobile/Library，mobile 本就可写，不需要这一级**

### 2.4 能力映射表：Filza → 我们的 IPA

| Filza 能力 | 我们复刻的方式 | 在本项目中的用途 |
|---|---|---|
| no-sandbox 直写系统文件 | entitlements：`platform-application` + `com.apple.private.security.no-sandbox` | 打开/写入系统 DB |
| SQLite 编辑器 | iOS 自带 libsqlite3（Swift `import SQLite3`）| 读写三类数据库 |
| root 命令执行 | TrollStore `spawnRoot` 思路（posix_spawn + persona 99 + uid 0，见第 3 节）| kill daemon / launchctl kickstart / respring |
| plist 编辑 | Foundation PropertyList | 读写 `com.apple.MobileSMS.plist` 等偏好设置 |
| 备份/恢复 | 文件复制（DB + -wal + -shm 三件套）| 写前备份、写后校验 |

---

## 3. 关键机制：TrollStore 进程可以 root 身份 spawn（源码实证）

- `opa334/TrollStore` `Shared/TSUtil.m`（已读源码）：
  - `spawnRoot()` 用 `posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE)` + `set_persona_uid_np(&attr, 0)` + `set_persona_gid_np(&attr, 0)` 实现 **mobile→root 提权执行命令**
  - `respring()` = `killall(@"SpringBoard", YES)` + `exit(0)`
- 含义：我们的 IPA（mobile + no-sandbox）可 spawn root 执行 `killall callservicesd` / `launchctl kickstart -k system/com.apple.imagent` / `killall SpringBoard`（respring）——**不需要越狱**
- 补充事实（launchd plist 镜像源码实证，见第 5 节）：相关 daemon 全部 `UserName = mobile`，与我们 App **同 uid** → 直接 POSIX kill 也行；root spawn 是更稳的兜底

---

## 4. 三类数据的存储位置与表结构（源码实证：iLEAPP 2026-07 最新版）

### 4.0 时间纪元（最易错，先记牢）
- 三个库的时间字段都是 **Cocoa 纪元 = 2001-01-01 00:00:00 UTC 起的秒数**
- 换算：`cocoa = unix - 978307200`；读回：`unix = cocoa + 978307200`
- sms.db 个别字段可能是纳秒（iLEAPP 判断：`ts > 10^15` 视为纳秒，除以 10^9）；**写入统一用秒**

### 4.1 通话记录（CallHistory）

| 项 | 内容 |
|---|---|
| 主库 | `/var/mobile/Library/CallHistoryDB/CallHistory.storedata`（**WAL 模式**，伴随 `-wal` / `-shm`）|
| 相关文件 | `CallHistoryTemp.storedata`（临时/未接提醒）、老版本 `call_history.db` |
| 表 | `ZCALLRECORD`（Core Data 存储，表名带 Z 前缀）|
| 关键列（iLEAPP callHistory.py 实证） | `ZDATE`（Cocoa 纪元）、`ZDURATION`（秒，未接=0）、`ZSERVICE_PROVIDER`、`ZCALLTYPE`（0=第三方App/1=电话/8=FaceTime视频/16=FaceTime音频）、`ZORIGINATED`（0=呼入/1=呼出）、`ZADDRESS`（号码/AppleID）、`ZANSWERED`（0=未接/1=已接）、`ZFACE_TIME_DATA`、`ZDISCONNECTED_CAUSE`（0=正常结束/6=拒接或未接）、`ZISO_COUNTRY_CODE`（CN）、`ZLOCATION` |
| Core Data 簿记 | 还有 `Z_PK`/`Z_ENT`/`Z_OPT`；`Z_PRIMARYKEY` 表记录每个实体的最大 Z_PK。**直插必须同步更新 Z_PRIMARYKEY，否则后续系统写入可能主键冲突** |
| 相关 daemon（plist 实证 mobile） | `com.apple.telephonyutilities.callservicesd`（主 daemon）、`com.apple.CallHistorySyncHelper`（iCloud/配对同步）、`com.apple.recentsd`（"最近通话"聚合）|

### 4.2 短信 / iMessage（SMS）

| 项 | 内容 |
|---|---|
| 主库 | `/var/mobile/Library/SMS/sms.db`（**WAL 模式**）；附件目录 `/var/mobile/Library/SMS/Attachments/<UUID>/` |
| 表（iLEAPP sms.py 实证列） | `message`（ROWID, guid, text, attributedBody, date, date_delivered, date_read, service, account, is_from_me, is_sent, is_delivered, is_read）；`chat`（ROWID, chat_identifier, account_login, service_name）；`chat_message_join`（chat_id, message_id）；`message_attachment_join`（message_id, attachment_id）；`attachment`（transfer_name, filename, created_date, mime_type, total_bytes）|
| service 取值 | `iMessage` / `SMS`（以设备实测为准）|
| **iOS 17+ 新增表** | `handle`（id/country/service/uncanonicalized_id/person_centric_id）与 `chat_handle_join`（chat_id + handle_id）——**需在设备上 `sqlite3 sms.db .schema` 二次确认**（iLEAPP 主查询未使用这两张表，属待实证项）|
| 相关 daemon（plist 实证 mobile） | `com.apple.imagent`（消息收发/索引）→ 写后 kill，launchd 自动拉起 |
| 其他事实 | iLEAPP 有 `SMSmissingROWIDs.py`（证明真实设备存在 ROWID 空洞，不必追求 ROWID 连续）；草稿在 `/var/mobile/Library/SMS/Drafts/<会话>*/composition.plist`；保留时长设置在 `com.apple.MobileSMS.plist` |

### 4.3 联系人（AddressBook）

| 项 | 内容 |
|---|---|
| 主库 | `/var/mobile/Library/AddressBook/AddressBook.sqlitedb` + `AddressBookImages.sqlitedb`（头像，可选）|
| 表与列（iLEAPP addressBook.py 实证，iOS 16–18 均解析成功） | `ABPerson`（ROWID, CreationDate, Prefix/First/Middle/Last/Suffix, DisplayName, First/Middle/LastPhonetic, Organization/Department/JobTitle, Nickname, Note, Birthday, StoreID, ModificationDate）；`ABMultiValue`（record_id, property, value, label, UID）；`ABMultiValueLabel`（ROWID, value）；`ABGroup`（ROWID, Name）；`ABGroupMembers`（group_id, member_id）；`ABStore`（ROWID, Name）；`ABMultiValueEntry` + `ABMultiValueEntryKey`（复合字段）；`ABThumbnailImage` / `ABFullSizeImage`（record_id, data）|
| **property 数字 ID** | 3=电话, 4=邮箱, 5=地址, 13=IM, 22=URL, 23=相关人, 46=社交资料 |
| 相关 daemon（plist 实证 mobile） | `com.apple.ABDatabaseDoctor`（AB 数据库修复）；`contactsd` 属主**待设备实测** |
| 首选路线 | **公开 API `CNContactStore`**（需一次用户授权）：`CNSaveRequest` + `CNMutableContact`，系统自动建索引、无需杀进程——最简单可靠 |
| 时间字段 | 同为 Cocoa 纪元 |

---

## 5. 守护进程与刷新机制（写完后如何让系统"看到"）

### 5.1 daemon 属主表（launchd plist 镜像 `mrjlovetian/ios_LaunchDaemons` 二进制 plist 解析实证）

| daemon | 属主 | 作用 | 写入后处理 |
|---|---|---|---|
| `com.apple.telephonyutilities.callservicesd` | **mobile** | 通话记录读写 | kill / `launchctl kickstart -k system/...` |
| `com.apple.CallHistorySyncHelper` | **mobile** | 通话 iCloud/配对同步 | 不主动动它（受 iCloud 开关控制）|
| `com.apple.recentsd` | **mobile** | "最近通话"聚合 | 随 respring 刷新 |
| `com.apple.imagent` | **mobile** | 短信/iMessage 收发与索引 | kill（launchd 自动拉起）|
| `com.apple.ABDatabaseDoctor` | **mobile** | AB 数据库修复 | 不主动动它 |
| `com.apple.SpringBoard` | **mobile** | 主界面/缓存 | respring = `killall SpringBoard` |

> 全部实证为 mobile：意味着**我们的 App（mobile + no-sandbox）与它们同 uid，可直接 kill**；root spawn（persona 99）用于 `launchctl kickstart` 与兜底。

### 5.2 刷新策略（推荐顺序）
1. **写库**（SQLite 事务提交，注意 WAL）
2. **kill 目标 daemon**：`killall callservicesd` / `killall imagent`（launchd 按 KeepAlive 自动重启并重新读库）
3. **respring**（`killall SpringBoard`）：刷新 UI 缓存（角标、"最近通话"聚合、信息列表）。若评估 App 正在前台，可只 kill daemon 不 respring，实测后定
4. **联系人**：CNContactStore 路线无需任何处理；DB 直写路线 kill `contactsd`（待实证）或 respring

---

## 6. 方案选型

| 数据 | 路线 | 说明 |
|---|---|---|
| 联系人 | **A. CNContactStore 公开 API（推荐）** | 一次授权；系统自动索引；无需杀进程；失败风险最低 |
| 联系人 | B. DB 直写（ABPerson/ABMultiValue） | 权限被拒或批量>1 万时用；需保证 StoreID/时间字段/复合字段一致 |
| 短信 | **DB 直写（唯一路线）** | 无公开写 API；直插 message/chat/join（+iOS17 handle）后 kill imagent |
| 通话 | **DB 直写（唯一路线）** | 无公开写 API；直插 ZCALLRECORD + 更新 Z_PRIMARYKEY 后 kill callservicesd / respring |
| 兜底 | PC 端编辑 iOS 备份再恢复 | 原理：备份内 sms.db 文件名是 SHA1 哈希 `3d0d7e5fb2ce288813306e4d4636395e047a3d28`（libimobiledevice 路线）；仅当设备端直写失败时考虑 |

---

## 7. 风险清单（用户可能没考虑到的点）

### 7.1 iCloud 同步覆盖（最可能翻车）
- 若开启"iCloud 云端信息"或"iCloud 备份"，imagent/CallHistorySyncHelper 可能把本地直写的数据同步到云端或**用云端数据覆盖本地**；评估机建议**关闭 iCloud 相关开关**或接受覆盖风险（写入后 10 分钟内观察是否存活）

### 7.2 Spotlight / 索引刷新
- 短信与联系人会被 Spotlight 索引；写入后索引刷新有时滞。若评估场景检测搜索行为，注意新数据可能延迟出现在搜索中（属正常现象，不一定是写入失败）

### 7.3 schema 随版本变化（最重要的技术风险）
- sms.db 在 iOS 17 新增 handle/chat_handle_join；CallHistory 不同版本列有增减（老版 call_history.db 与新版 storedata 并存）
- **对策（写进执行规格）**：写入前先做"schema 指纹"（`.schema` 全量导出 + 抽样真实行），生成器按指纹生成 INSERT，禁止硬编码列名

### 7.4 WAL 模式与文件一致性
- 三个库都是 WAL 模式：直接改 DB 文件而不管 -wal/-shm 会造成**读到旧数据或损坏**
- 对策：① 用 SQLite API 正常打开（自动带 WAL）；② 备份时三件套一起复制；③ 写完后可选 `PRAGMA wal_checkpoint(TRUNCATE)`

### 7.5 Core Data 内部一致性（仅通话库）
- ZCALLRECORD 直插必须处理 `Z_PK`/`Z_ENT`/`Z_OPT` 与 `Z_PRIMARYKEY.Z_MAX`，否则后续系统写入主键冲突 → 数据库异常（这是直写 Core Data 存储最常见的坑）

### 7.6 数据级检测面（评估场景）
- **交叉验证**：通话时间、短信时间、定位轨迹、App 使用记录不能互相矛盾（如"人在北京但通话记录全在凌晨 3 点"、"短信秒回但 GPS 显示在高速移动"）
- **过度完美**：全部已读、全部秒回、时长全整数、号码全 138 段 → 反而可疑；要有未读、未接、漏回、号码段多样
- 机械特征：生成数据的时间戳分布应服从人行为（活跃时段、周末模式），而不是均匀分布

### 7.7 附件 / 媒体一致性（可选范围）
- 若注入带附件消息，attachment 表 + `message_attachment_join` + `Attachments/<UUID>/` 文件三者必须一致，否则 Messages 显示占位图或打不开

### 7.8 与真实数据混排
- 直写不会清空真实数据；若评估机已有真实通话/短信，生成数据与真实数据混在一起，时间线要衔接自然（不要在真实数据中间插入矛盾记录）。执行规格提供"全量重建"与"增量追加"两种模式

### 7.9 安全与合规
- 该 IPA 含 no-sandbox + platform-application 高权限，**只装在自己名下评估机，绝不外传**
- 生成的"通话记录/短信/联系人"仅用于内部功能评估；若用于伪造证据/欺诈/规避监管，有法律风险，本项目定位为内部测试工具

---

## 8. 参考项目与源码位置

| 项目 | 仓库/文件 | 用途 |
|---|---|---|
| iLEAPP（schema 圣经） | `abrignoni/iLEAPP` → `scripts/artifacts/{callHistory,sms,addressBook,SMSmissingROWIDs}.py` | 三类 DB 表结构/列/枚举值（2026-07 版实证）|
| TrollStore 提权/重启 | `opa334/TrollStore` → `Shared/TSUtil.m` | `spawnRoot`（persona 99+uid 0）、`killall`、`respring` |
| Filza 无越狱原理 | `34306/FilzaJailedDS` → `Tweak.m` + `sandbox_escape.h` + `apfs_own.h` | TGRootFileManager hook、sandbox_escape、apfs_own 思路（本项目不用内核级）|
| GeoFilza / PlankFilza | `GeoSn0w/GeoFilza`、`brandonplank/PlankFilza` | 同思路备选 |
| launchd plist 镜像 | `mrjlovetian/ios_LaunchDaemons` → `LaunchDaemons/` | daemon 属主实证（imagent/callservicesd/CallHistorySyncHelper/recentsd/ABDatabaseDoctor/SpringBoard 均 mobile）|
| 通话解析 | `MetadataForensics/iQueryContacts`、`MetadataForensics/Call_History_Group_Calls`、`Kinetic-Data/IOS-Call-History-SQLite` | 枚举值/字段含义交叉验证 |
| 短信解析 | `jsharkey13/iphone_message_parser` | 字段含义交叉验证 |
| 远程消息（思路参考） | `JimmyAustin/MessageServer` | 注入 MobileSMS 做远程收发（需 root 注入，本项目不采用，仅思路）|

---

## 9. 待实证清单（执行 AI 必须先在设备上验证，禁止跳过）

| # | 实证项 | 方法 | 影响 |
|---|---|---|---|
| E0 | 三个库 mobile 可读可写 | 用我们的 App 打开库执行 `PRAGMA journal_mode` + 读行数 + 事务性写 1 行再回滚 | 门禁 1 |
| E1 | 通话写入后刷新方式 | 插 1 行 ZCALLRECORD → 分别试 kill callservicesd / respring / 仅重开电话 App | 决定刷新策略 |
| E2 | 短信写入后刷新方式 | 插 1 条 message+chat+join → 试 kill imagent / respring | 决定刷新策略 |
| E3 | iOS 17 handle/chat_handle_join 列名 | `SELECT sql FROM sqlite_master WHERE name IN ('handle','chat_handle_join')` | 决定 iOS17 插入 SQL |
| E4 | Z_PRIMARYKEY 内容 | `SELECT * FROM Z_PRIMARYKEY`（找 ZCALLRECORD 的 Z_ENT 与 Z_MAX）| 决定 Z_ENT 值 |
| E5 | CallHistoryTemp 是否需处理 | 写入后对比 Phone 应用显示与直接查 storedata | 决定是否动 Temp |
| E6 | iCloud 影响 | 开关 iCloud 云端信息各写一批，10 分钟/重启后观察存活 | 决定评估机配置要求 |
| E7 | 联系人 CNContactStore 授权与生效 | 写 1 个测试联系人 → 通讯录 App 查看 | 门禁 2（联系人路线定案）|
| E8 | WAL checkpoint 必要性 | 写入后不 checkpoint vs checkpoint，重启对比 | 决定是否加 checkpoint |

---

## 10. 一句话总结

**Filza 的本质是"no-sandbox 直写 + SQLite 编辑 + root 命令执行"三件套；在 TrollStore 上这三件我们全部可以自己实现（entitlements + libsqlite3 + persona 99 spawnRoot），不需要 Filza 本体。通话/短信两个库只能 DB 直写，联系人优先用公开 API；写入后 kill 对应 daemon（都是 mobile 属主）即可生效。最大的坑是 schema 版本差异、WAL 一致性与 iCloud 覆盖，全部已写入执行规格的 Go/No-Go 实验。**
