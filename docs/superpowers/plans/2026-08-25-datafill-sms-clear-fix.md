# 短信清空修复（触发器函数注册 + 软删过滤 + 认知矫正）实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** ① 注册 sms.db message 表触发器依赖函数使 `DELETE` 成功（根治"部分失败：no such function"与数字递增）；② 计数口径补 `flags` 软删过滤（清空显示 ≈ App 可见消息数）；③ 通话库顺带诊断确认无同款问题；④ 矫正三处基于旧认知的注释/文档描述。

**架构：** 全部代码改动集中在 `TrollVNC/src/TRDataFiller.mm`——新增 `trRegisterTriggerFuncs`（读 sqlite_master 触发器 SQL → 正则提取函数名 → `sqlite3_create_function` 注册返回 0 的 stub，自适应任意 iOS 版本）+ 在 clearDatabase sms 分支 DELETE 前调用；计数 SQL 补 `(m.flags & 4) = 0`；calls 分支顺带收集触发器/字段清单返回 `callsMeta`。文档矫正三处。

**技术栈：** ObjC（sqlite3 + NSRegularExpression）；CI = GitHub Actions bootstrap job。

**规格依据：** `docs/superpowers/specs/2026-08-25-datafill-sms-clear-fix-design.md`（已批准 commit 459c340）。

**工作区纪律：**
- 设备端改动必须 CI 编译通过才声称完成。
- **对 `TRDataFiller.mm` 多次编辑必须串行**（一次消息一个 SearchReplace）。
- 改行为同步相邻注释；提交与文档同步同一 commit。
- 完成后 push + workflow_dispatch 触发 CI。

---

### 任务 1：新增 trRegisterTriggerFuncs + sms 分支调用

**文件：**
- 修改：`TrollVNC/src/TRDataFiller.mm`（`trDbExec` 之后、`#pragma mark - kill daemon` 之前插入辅助函数；clearDatabase sms 分支调用）

- [ ] **步骤 1：读文件确认插入锚点**

读取 `TrollVNC/src/TRDataFiller.mm` L91-135（`trDbScalar`/`trDbExec` 区域）与 L608-645（clearDatabase sms 分支 `sqlite3_open_v2` 处），确认插入位置。

- [ ] **步骤 2：在 trDbExec 之后插入辅助函数**

在 `trDbExec` 函数结束、`#pragma mark - kill daemon` 之前插入：

```objc
// 触发器函数 stub（2026-08-25）：iOS sms.db message 表带系统触发器（FTS/未读计数），触发器调用系统
// sqlite 连接注册的自定义函数（老版 read() 等），直连缺失 → DELETE 报 no such function → 残留/数字虚高。
// 注册返回 0 的无副作用 stub，触发器结构原样保留，自适应任意 iOS 版本（不硬编码函数名）。
static void trTriggerStub(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc; (void)argv;
    sqlite3_result_int(ctx, 0);
}
static void trRegisterTriggerFuncs(sqlite3 *db) {
    const char *sql = "SELECT sql FROM sqlite_master WHERE type='trigger' AND tbl_name='message'";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) return;
    static NSSet *kSkip = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kSkip = [NSSet setWithArray:@[@"SELECT",@"FROM",@"WHERE",@"WHEN",@"BEGIN",@"END",@"UPDATE",@"INSERT",@"DELETE",@"IF",@"CASE",@"CAST",@"ABS",@"MIN",@"MAX",@"COUNT",@"SUM",@"LENGTH",@"SUBSTR",@"IFNULL",@"COALESCE",@"NULLIF",@"UPPER",@"LOWER",@"TRIM",@"ROUND",@"OLD",@"NEW",@"ROWID",@"AND",@"OR",@"NOT",@"NULL",@"IS",@"IN",@"EXISTS",@"LIKE",@"GLOB",@"BETWEEN",@"INTO",@"VALUES",@"PRAGMA",@"RAISE",@"TYPEOF",@"CHAR",@"PRINTF",@"QUOTE",@"REPLACE",@"INSTR",@"LAST_INSERT_ROWID",@"CHANGES",@"TOTAL_CHANGES",@"RANDOM",@"RANDOMBLOB",@"ZEROBLOB",@"SOUNDEX",@"UNICODE",@"HEX",@"LIKELIHOOD",@"LIKELY",@"UNLIKELY",@"IIF"]];
    });
    NSMutableSet *funcs = [NSMutableSet set];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"([a-zA-Z_][a-zA-Z0-9_]*)\\s*\\(" options:0 error:nil];
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *txt = sqlite3_column_text(stmt, 0);
        if (!txt) continue;
        NSString *s = [NSString stringWithUTF8String:(const char *)txt];
        [re enumerateMatchesInString:s options:0 range:NSMakeRange(0, s.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
            NSString *fn = [s substringWithRange:[m rangeAtIndex:1]];
            if ([kSkip containsObject:fn.uppercaseString]) return;
            [funcs addObject:fn];
        }];
    }
    sqlite3_finalize(stmt);
    for (NSString *fn in funcs) {
        sqlite3_create_function(db, fn.UTF8String, -1, SQLITE_UTF8, NULL, trTriggerStub, NULL, NULL);
    }
}
```

- [ ] **步骤 3：clearDatabase sms 分支调用**

sms 分支 `sqlite3_open_v2(...) == SQLITE_OK` 后、`cleared += ...` 计数之前插入：

```objc
            trRegisterTriggerFuncs(d); // DELETE 前注册 message 表触发器依赖函数（防 no such function → 残留/数字虚高）
```

---

### 任务 2：计数口径补软删过滤 + 注释矫正

**文件：**
- 修改：`TrollVNC/src/TRDataFiller.mm`（clearDatabase sms 分支计数行）

- [ ] **步骤 1：更新计数 SQL**

将当前计数行（含其上方注释）替换为：

```objc
            // 计数口径（2026-08-25 定稿）：仅统计信息 App 可见消息——排除软删除标记行（flags&4，iOS 删除短信=标记 0x04 永留表内，App 不显示）
            // 且须有 chat_message_join 关联（孤儿/join 失败残留不计）；曾致清空数字虚高（900+ vs 列表 20）且随生成递增
            cleared += (NSInteger)trDbScalar(d, @"SELECT COUNT(*) FROM message m WHERE m.service='SMS' AND (m.flags & 4) = 0 AND EXISTS(SELECT 1 FROM chat_message_join j WHERE j.message_id = m.ROWID)");
```

- [ ] **步骤 2：核对**

确认：删除仍全量（`DELETE FROM message WHERE service='SMS'` 不动）；`cleared` 语义 = App 可见消息数；注释与实现/设计一致。

---

### 任务 3：通话库顺带诊断（callsMeta）

**文件：**
- 修改：`TrollVNC/src/TRDataFiller.mm`（clearDatabase calls 分支 + out 构建处）

- [ ] **步骤 1：calls 分支收集诊断数据**

在 `clearDatabase` 方法体 `NSInteger cleared = 0;` 之后加局部变量声明：

```objc
    NSDictionary *callsMeta = nil; // 通话库诊断（2026-08-25）：确认 CallHistory 无短信同款问题（触发器/软删字段）
```

calls 分支 `sqlite3_open_v2(...) == SQLITE_OK` 块内、`sqlite3_close(d);` 之前插入收集逻辑：

```objc
            // 顺带诊断：CallHistory 触发器列表 + ZCALLRECORD 字段清单（真机确认无同款机制）
            NSMutableArray *trigs = [NSMutableArray array];
            sqlite3_stmt *ts = NULL;
            if (sqlite3_prepare_v2(d, "SELECT name FROM sqlite_master WHERE type='trigger'", -1, &ts, NULL) == SQLITE_OK) {
                while (sqlite3_step(ts) == SQLITE_ROW) [trigs addObject:@((const char *)sqlite3_column_text(ts, 0))];
            }
            sqlite3_finalize(ts);
            NSMutableArray *cols = [NSMutableArray array];
            sqlite3_stmt *cs = NULL;
            if (sqlite3_prepare_v2(d, "PRAGMA table_info(ZCALLRECORD)", -1, &cs, NULL) == SQLITE_OK) {
                while (sqlite3_step(cs) == SQLITE_ROW) [cols addObject:@((const char *)sqlite3_column_text(cs, 1))];
            }
            sqlite3_finalize(cs);
            callsMeta = @{@"triggers": trigs, @"columns": cols};
```

- [ ] **步骤 2：out 构建后写入 callsMeta**

`NSMutableDictionary *out = ...` 之后、kill 循环之前插入：

```objc
    if (callsMeta) out[@"callsMeta"] = callsMeta; // 通话库诊断（仅 calls/all 清空时存在）
```

---

### 任务 4：文档矫正（与代码同 commit）

**文件：**
- 修改：`AGENTS.md`（⑥ 条目）
- 修改：`说明文档.md`（§4.9 短信清空语义段）

- [ ] **步骤 1：AGENTS.md ⑥ 矫正**

将「数据填充行为定稿」⑥ 的旧表述（"孤儿行（join 失败残留/历史）count 得到但 App 不显示，曾致清空数字虚高且随生成递增。删除仍全量（App 全空）。"）替换为：

```markdown
⑥ **短信清空根治（2026-08-25 定稿）**：① iOS 删除短信=**软删除**（`message.flags` 标记 `0x04`，行永留表内、App 过滤显示）→ 计数必须 `(flags&4)=0` 排除软删历史；② message 表带**系统触发器**（FTS/未读计数，调用系统注册函数如 `read()`）→ 直连 DELETE 报 `no such function` 致残留/递增，`clearDatabase` 须先 `trRegisterTriggerFuncs`（读触发器 SQL 提取函数名、注册返回 0 的 stub，不 DROP 不破坏系统结构）；③ 计数口径=`App 可见消息`（flags 非软删 + 有 join），删除仍全量。通话记录无此机制（无软删/无 FTS 触发器，物理删）。
```

- [ ] **步骤 2：说明文档.md §4.9 同步矫正**

将说明文档.md §4.9「清空语义」段中短信清空描述同步为与 AGENTS ⑥ 一致（软删除标记 + 触发器函数注册 + 可见消息口径）；通话诊断 callsMeta 字段补记。

---

### 任务 5：代码 + 文档一次提交

**文件：** `TrollVNC/src/TRDataFiller.mm`、`AGENTS.md`、`说明文档.md`

- [ ] **步骤 1：提交**

```bash
git add TrollVNC/src/TRDataFiller.mm AGENTS.md "说明文档.md"
git commit -m "fix: 短信清空根治（触发器函数注册+软删过滤计数）+通话诊断
- trRegisterTriggerFuncs：读触发器 SQL 提取函数名注册 stub，DELETE 不再 no such function
- 清空计数补 (flags&4)=0 排除软删历史，显示≈App 可见消息数
- 通话库顺带诊断（callsMeta 触发器/字段），确认无同款机制
- 认知矫正（AGENTS ⑥ / 说明文档 §4.9）"
```

预期：commit 成功；`git status --short` 无本次改动残留。

---

### 任务 6：CI 编译验证（未验证不声称完成）

**文件：** 无（推送与触发）

- [ ] **步骤 1：推送并触发 CI**

```bash
# 远程 base = 当前远程 main sha（GET /git/ref/heads/main）
GHTOK=<token> node scripts/push-via-api.mjs <本地commit> <远程base> HEAD~1   # for 循环重试 503
# 核对关键文件 sha（TrollVNC/src/TRDataFiller.mm 等）
# POST .../actions/workflows/build.yml/dispatches {"ref":"main"}（204）
# 匹配 run 用推送后远程 HEAD sha
```

- [ ] **步骤 2：下载校验**

轮询 run → success → 下载 packages-bootstrap.zip → 解压 → `tar -tf` 校验 .tipa（关键文件齐全、体积 ~3.9MB）。

- [ ] **步骤 3：真机验证清单（用户执行）**

| 场景 | 预期 |
|---|---|
| 清空短信 | 无"部分失败：no such function"报错 |
| 清空短信显示数量 | ≈ 信息 App 列表可见消息数（不再是 900+ 级） |
| 连续两次"生成→清空" | 数字不递增 |
| 清空后信息 App | 全空（含软删历史全清） |
| 清空通话（callsMeta 诊断） | 返回触发器=空、ZCALLRECORD 字段清单（确认无同款机制） |

---

## 自检

**1. 规格覆盖度：**
- §2.1 触发器函数注册 → 任务 1 ✅
- §2.2 计数补 flags → 任务 2 ✅
- §2.3 通话诊断 callsMeta → 任务 3 ✅
- §2.4 认知矫正 → 任务 4 ✅
- §3 契约（cleared 语义、无 no such function、callsMeta 新增字段）→ 任务 1/2/3 内联 ✅
- §4 边界（通话逻辑不动、kill 降级保留、生成侧不动）→ 任务划分 ✅
- §5 验证门槛 → 任务 6 ✅

**2. 占位符扫描：** 无 TODO/待定；所有步骤含完整代码或精确命令。

**3. 类型一致性：** `trTriggerStub`/`trRegisterTriggerFuncs` 在任务 1 内定义与调用一致；`callsMeta`（NSDictionary*）任务 3 声明/赋值/输出一致；计数 SQL 的 `m`/`j` 别名与任务 2 一致。
