# 数据填充清空治理：短信计数口径 + 自动重启目标 App（设计规格）

> 日期：2026-08-25
> 状态：已批准（用户定案：单一治本）
> 前置依据：`2026-08-25-datafill-clear-guard-design.md`（清空残留校验，已实施）；用户真机观察（2026-08-25）

## 1. 背景与问题

用户真机观察（2026-08-25）：
1. **短信清空数字虚高且递增**：只生成 20 条短信，清空却提示"已清空几百条"；多次"生成→清空"循环数字递增。但**清空后信息 App 实际全空**（观感上彻底清除）。
   - **根因**：`clearDatabase` 计数 `COUNT(*) FROM message WHERE service='SMS'` 统计 **message 表全量**——包含信息 App **不可见**的孤儿行（生成时 `message` INSERT 成功但 `chat_message_join` 失败留下的行，[trFillSms L539](file:///c:/Users/Administrator/Documents/ChatGPT/New project/TrollVNC/src/TRDataFiller.mm) `continue` 前未回滚）与历史 SMS 行。孤儿/历史行 count 得到、App 不显示 → 数字与观感脱节、随生成量递增。
2. **通话/短信需重启 App 才生效**：直写 sqlite 无法触发电话/信息 App 的 UI 刷新（App 进程缓存 + 不监听外部 DB 变更）；苹果官方亦认可"关闭并重开 App 刷新"。通讯录走 CNContactStore 有系统变更通知故实时。
3. **"未找到进程 callservicesd"误报"部分失败"**：kill daemon 辅助动作失败（进程未常驻/launchd 重启窗口）被计入 errors → UI 显示"已清空 N 条（部分失败：…）"，但清空本体已成功。

## 2. 方案（单一治本 + 独立需求）

### 2.1 短信清空计数口径（治本，用户定案）

`clearDatabase` sms 分支计数改为**仅信息 App 可见消息**：

```sql
-- 旧（含孤儿/历史，虚高）
SELECT COUNT(*) FROM message WHERE service='SMS'
-- 新（仅可见）
SELECT COUNT(*) FROM message m
WHERE m.service='SMS'
  AND EXISTS(SELECT 1 FROM chat_message_join j WHERE j.message_id = m.ROWID)
```

- 孤儿行不参与计数 → 数字与信息 App 观感严格一致，递增消失。
- **不做**生成侧回滚/孤儿二次清除/before-after 透明（治标项，全部砍除——口径一改即根治）。
- 删除仍全量（`DELETE FROM message WHERE service='SMS'`），保证 App 全空。

### 2.2 自动重启目标 App（独立需求，用户确认）

生成/清空后 kill 对应 daemon **并** kill 目标 App 进程（root 权限可行，[trFindPidByName](file:///c:/Users/Administrator/Documents/ChatGPT/New project/TrollVNC/src/TRDataFiller.mm#L113-L127) 复用）：

| 数据 | daemon | 目标 App（进程名） |
|---|---|---|
| calls | callservicesd | MobilePhone |
| sms | imagent | MobileSMS |

- 用户下次打开电话/信息 App 即全新加载 → "立即生效"（对齐通讯录体验）。
- 与 respring 红线无关（不碰 SpringBoard，仅 kill 单个 App 进程）。

### 2.3 kill 失败降级（2.2 的必要组成部分）

- kill **未找到进程**（daemon 未常驻 / App 未运行）→ **不再计入 errors**，不显示"部分失败"（App 未打开是常态，不得误报）。
- 仅真正 kill 失败（进程存在但 kill 返回错误）才保留警告级提示。

## 3. 接口契约

- `clearDatabase("sms")` 返回 `cleared` 语义变为"可见消息数"；删除行为不变；无新增字段。
- `fillDatabase`/`clearDatabase` 的 kill 处理：成功 → `kill` 字段；失败（未找到/错误）→ `killError` 字段（**降级为信息，不进 errors**）。
- UI 无需改动（`ok:NO → error`、`errors → 部分失败` 逻辑保留，kill 失败不再触发）。

## 4. 边界

- 通话计数不动（ZCALLRECORD 每条=一次通话，与 Recents 口径一致）。
- 生成侧不动（计数口径已根治，无需回滚逻辑）。
- contacts 清空不动（CNContactStore 已实时刷新）。

## 5. 验证门槛

1. 设备端改动 → CI bootstrap 编译通过。
2. 真机：生成 20 条短信 → 清空 → 提示约 20 条（=可见短信），连续两次不递增；清空后信息 App 全空。
3. 真机：生成/清空通话与短信后，电话/信息 App 下次打开即为新数据。
4. 真机：目标 App 未运行时清空 → 无"部分失败"字样。
