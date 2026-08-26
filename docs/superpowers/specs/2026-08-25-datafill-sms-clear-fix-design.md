# 短信清空修复：触发器函数注册 + 计数口径补软删过滤 + 认知矫正（设计规格）

> 日期：2026-08-25
> 状态：已批准（用户定案：修复 + 同步矫正文档）
> 前置依据：`2026-08-25-datafill-clear-recount-restart-design.md`（已实施 c37d709）；用户真机反馈（2026-08-25）

## 1. 背景与问题（完整根因，2026-08-25 定论）

用户真机（已装 c37d709 .tipa）反馈：
1. **清空短信报"部分失败：no such function: after delete messge plugin"**；
2. **信息 App 短信列表只有 20 条，清空却显示 900+ 条**（EXISTS 可见消息口径下仍为全量级）；
3. 多次"生成→清空"数字递增。

**完整根因链（三层）**：
1. **iOS 短信删除是软删除**：系统将 `message.flags` 标记 `0x04`（kSMSMessageFlagDeleted），行永留 message 表，信息 App 显示时过滤 → 设备累积大量"App 不可见"的软删历史行（用户列表 20 条 ≠ message 表 900+ 行）。
2. **message 表带系统触发器**（维护 FTS 全文索引/未读计数，老版调用自定义函数 `read()`）：我们的 `sqlite3_open_v2` 连接未注册这些函数 → `DELETE FROM message WHERE service='SMS'` **整句失败** → message 行残留（join/chat 已被前置 DELETE 移除 → 孤儿化 → App 不显示）→ count（清空前全量）虚高且递增、报"部分失败"。
3. 通话记录（CallHistory.storedata）**无此机制**（无软删标记、无 FTS 触发器、删除即物理删）——需真机诊断确认无同款问题。

## 2. 方案（修复三件套 + 认知矫正）

### 2.1 注册 message 表触发器依赖函数（DELETE 成功）

`clearDatabase` sms 分支执行 DELETE 前，读取 `sqlite_master` 中 message 表触发器定义，**自适应提取其调用的函数名**（正则 `\b([a-zA-Z_][a-zA-Z0-9_]*)\s*\(` 过滤 SQL 关键字/内置函数），用 `sqlite3_create_function` 注册**无副作用 stub**（返回 0）。触发器结构原样保留（不 DROP，不破坏系统 FTS/未读机制）；适配任意 iOS 版本（不硬编码函数名，老版 `read()` 与新版均覆盖）。

```objc
// 提取 message 表触发器 SQL → 注册缺失函数 stub（sqlite3_create_function 返回 0）
static void trRegisterTriggerFuncs(sqlite3 *db);
```

### 2.2 计数口径补软删过滤（对齐 App 可见）

```sql
SELECT COUNT(*) FROM message m
WHERE m.service='SMS'
  AND (m.flags & 4) = 0                 -- 排除软删除标记（App 不显示）
  AND EXISTS(SELECT 1 FROM chat_message_join j WHERE j.message_id = m.ROWID)
```

`cleared` 显示 ≈ 信息 App 列表真实可见消息数（20 级），不再 900+。

### 2.3 通话库顺带诊断

`clearDatabase` calls 分支（或 data.probe）顺带读取 CallHistory.storedata 的 `sqlite_master` 触发器列表 + ZCALLRECORD 字段清单，返回给调用方（真机一次确认通话无同款问题；有则后续修）。

### 2.4 认知矫正（与修复同 commit）

| 位置 | 旧表述（不准确） | 矫正为 |
|---|---|---|
| TRDataFiller.mm 计数注释 | "孤儿行（join 失败残留/历史）count 得到但 App 不显示" | 软删除标记行（flags=0x04）+ DELETE 触发器函数缺失致残留；App 不显示但 count 得到 |
| AGENTS.md ⑥ | 同旧表述 | 同步矫正（含 2.1/2.2 机制） |
| 说明文档.md §4.9 | 同旧表述 | 同步矫正 |

## 3. 接口契约

- `clearDatabase("sms")` 返回 `cleared` 语义 = "App 可见消息数"（flags 非软删 + 有效 join）；删除全量（含软删历史与孤儿）。
- sms 分支不再报 `no such function`（函数已注册）；`errors` 不再含此错误。
- 通话诊断结果作为新增字段返回（如 `callsMeta`），不改变既有字段。

## 4. 边界

- 通话计数与删除逻辑本次不动（仅加诊断）；通话无软删/触发器同款问题（若诊断发现则另行立项）。
- kill 降级、自动重启目标 App（c37d709）为当前有效实现，保留不动。
- 生成侧（trFillSms INSERT）不动（INSERT 触发器无函数缺失问题，用户生成正常）。

## 5. 验证门槛

1. 设备端改动 → CI bootstrap 编译通过。
2. 真机：清空短信 → 无"部分失败"报错；显示数量 ≈ 信息 App 列表可见消息数；连续两次"生成→清空"不递增；清空后信息 App 全空。
3. 真机：通话诊断输出确认无触发器/软删字段。
