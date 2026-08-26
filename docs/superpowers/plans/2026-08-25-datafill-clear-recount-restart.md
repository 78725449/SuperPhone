# 数据填充清空治理（短信计数口径 + 自动重启目标 App）实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** ① 短信清空计数改为"仅信息 App 可见消息"，根治数字虚高/递增；② 生成/清空后自动重启电话/信息 App，实现"立即生效"；③ kill 失败（未找到进程）降级，不再误报"部分失败"。

**架构：** 全部改动集中在设备端 `TrollVNC/src/TRDataFiller.mm`——`clearDatabase`（短信计数 SQL + kills 列表加 App + kill 失败降级）与 `trFillCalls`/`trFillSms`（生成后 kill 目标 App）。复用现有 `trKillDaemon`/`trFindPidByName`（root 权限，无沙盒限制）。

**技术栈：** ObjC（sqlite3 + sysctl 进程枚举）；CI = GitHub Actions bootstrap job 编译 .tipa。

**规格依据：** `docs/superpowers/specs/2026-08-25-datafill-clear-recount-restart-design.md`（已批准 commit 45633d3）。

**工作区纪律（必读）：**
- 设备端改动必须 CI 编译通过才声称完成（Windows 不能本地构建）。
- **对 `TRDataFiller.mm` 的多次编辑必须串行**（一次消息一个 SearchReplace；并行编辑互相覆盖）。
- 改行为必须同步相邻注释；提交与文档同步同一 commit。
- 完成后 push + workflow_dispatch 触发 CI（push-via-api 不触发 Actions）。

---

### 任务 1：clearDatabase 短信计数口径 + kills 列表加 App + kill 失败降级

**文件：**
- 修改：`TrollVNC/src/TRDataFiller.mm` `clearDatabase`（L585-676，`@end` 之前）

- [ ] **步骤 1：读文件确认锚点**

读取 `TrollVNC/src/TRDataFiller.mm` L585-676，确认：sms 分支的 `cleared += (NSInteger)trDbScalar(d, @"SELECT COUNT(*) FROM message WHERE service='SMS'");`（约 L612）、calls 分支 `[kills addObject:@"callservicesd"];`（L602）、sms 分支 `[kills addObject:@"imagent"];`（L624）、结尾 kills 循环（L664-667）与 out 创建（L668）。

- [ ] **步骤 2：短信计数口径改为"仅可见消息"**

将 sms 分支计数 SQL（L612）替换为：

```objc
            // 计数口径（2026-08-25 定稿）：仅统计信息 App 可见消息（有 chat_message_join 关联的 SMS 行）
            // —— 孤儿行（join 失败残留/历史）count 得到但 App 不显示，曾致清空数字虚高且随生成递增
            cleared += (NSInteger)trDbScalar(d, @"SELECT COUNT(*) FROM message m WHERE m.service='SMS' AND EXISTS(SELECT 1 FROM chat_message_join j WHERE j.message_id = m.ROWID)");
```

- [ ] **步骤 3：kills 列表加入目标 App 进程**

calls 分支（L602 `[kills addObject:@"callservicesd"];` 之后）插入：

```objc
            [kills addObject:@"MobilePhone"]; // 电话 App（自动重启实现"立即生效"；未运行则 kill 找不到=忽略）
```

sms 分支（L624 `[kills addObject:@"imagent"];` 之后）插入：

```objc
            [kills addObject:@"MobileSMS"]; // 信息 App（同上）
```

- [ ] **步骤 4：kill 失败降级（未找到进程不再进 errors）**

将结尾的 kills 循环 + out 创建（L664-668）整体替换为：

```objc
    NSMutableDictionary *out = [@{@"ok": @YES, @"db": db, @"cleared": @(cleared)} mutableCopy];
    // kill 失败降级（2026-08-25 定稿）："未找到进程"= daemon 未常驻/App 未运行，属正常，忽略；
    // 其余 kill 错误为信息级（killError 字段），不进 errors——不误报"部分失败"（清空本体已成功）
    NSMutableArray *killErrs = [NSMutableArray array];
    for (NSString *k in kills) {
        NSString *ke = trKillDaemon(k);
        if (!ke || [ke hasPrefix:@"未找到进程"]) continue;
        [killErrs addObject:ke];
    }
    if (killErrs.count) out[@"killError"] = [killErrs componentsJoinedByString:@"; "];
```

（后续 `if (remainContacts > 0)` 与 `if (errors.count)` 块保持不动，紧跟其后。）

- [ ] **步骤 5：核对完整性**

确认：`out` 现在在 kills 循环前创建；`remainContacts`/`errors` 处理块在 kill 循环后；`cleared` 语义已变为"可见消息数"；kills 数组含 daemon + App 各一；`killError` 仅承载非"未找到"错误。

---

### 任务 2：生成路径自动重启目标 App

**文件：**
- 修改：`TrollVNC/src/TRDataFiller.mm` `trFillCalls`（L416-419）、`trFillSms`（L563-566）

- [ ] **步骤 1：trFillCalls 生成后 kill 电话 App**

将（约 L416-419）：

```objc
    NSString *killErr = trKillDaemon(@"callservicesd");
    NSMutableDictionary *out = [@{@"ok": @YES, @"db": @"calls", @"count": @(written)} mutableCopy];
    if (killErr) out[@"killError"] = killErr; else out[@"kill"] = @"callservicesd";
```

替换为：

```objc
    NSString *killErr = trKillDaemon(@"callservicesd");
    NSString *appErr = trKillDaemon(@"MobilePhone"); // 电话 App 自动重启（未运行=未找到=忽略）
    if (appErr && [appErr hasPrefix:@"未找到进程"]) appErr = nil;
    NSMutableDictionary *out = [@{@"ok": @YES, @"db": @"calls", @"count": @(written)} mutableCopy];
    if (killErr) out[@"killError"] = killErr; else out[@"kill"] = @"callservicesd";
    if (appErr) out[@"appKillError"] = appErr; else out[@"appKill"] = @"MobilePhone";
```

- [ ] **步骤 2：trFillSms 生成后 kill 信息 App**

将（约 L563-566）：

```objc
    NSString *killErr = trKillDaemon(@"imagent");
    NSMutableDictionary *out = [@{@"ok": @YES, @"db": @"sms", @"count": @(written)} mutableCopy];
    if (killErr) out[@"killError"] = killErr; else out[@"kill"] = @"imagent";
```

替换为：

```objc
    NSString *killErr = trKillDaemon(@"imagent");
    NSString *appErr = trKillDaemon(@"MobileSMS"); // 信息 App 自动重启（未运行=未找到=忽略）
    if (appErr && [appErr hasPrefix:@"未找到进程"]) appErr = nil;
    NSMutableDictionary *out = [@{@"ok": @YES, @"db": @"sms", @"count": @(written)} mutableCopy];
    if (killErr) out[@"killError"] = killErr; else out[@"kill"] = @"imagent";
    if (appErr) out[@"appKillError"] = appErr; else out[@"appKill"] = @"MobileSMS";
```

- [ ] **步骤 3：核对**

确认：`trKillDaemon` 返回"未找到进程 xxx"（trFindPidByName 返回 0）时 appErr 置 nil；`killError`/`appKillError` 均为信息级（UI 不展示），`ok:YES` 不受影响。

---

### 任务 3：文档同步（与代码同 commit）

**文件：**
- 修改：`AGENTS.md`（「数据填充行为定稿」条目）
- 修改：`说明文档.md`（§4.9 清空/生成语义）

- [ ] **步骤 1：AGENTS.md 数据填充行为定稿追加 ⑥⑦**

在「数据填充行为定稿（2026-08-25）」条目 ⑤ 之后追加：

```markdown
⑥ **短信清空计数口径（2026-08-25）**：清空短信的 `cleared` 只统计信息 App **可见消息**（`message` 行须有 `chat_message_join` 关联）——孤儿行（join 失败残留/历史）count 得到但 App 不显示，曾致清空数字虚高且随生成递增。删除仍全量（App 全空）。
⑦ **自动重启目标 App（2026-08-25）**：生成/清空通话后 kill `callservicesd` + `MobilePhone`，短信后 kill `imagent` + `MobileSMS`——下次打开电话/信息 App 即新数据（"立即生效"，对齐通讯录 CNContactStore 体验；不碰 SpringBoard，与 respring 无关）。**kill 失败降级**："未找到进程"（daemon 未常驻/App 未运行）忽略，其余进 `killError` 信息级字段，不误报"部分失败"。
```

- [ ] **步骤 2：说明文档.md §4.9 同步**

搜索说明文档.md 中"清空语义"与生成 kill 相关小节，同步：清空短信 `cleared` 口径（仅可见消息）、生成/清空后自动重启目标 App（kill 列表含 MobilePhone/MobileSMS）、kill 失败降级（killError 信息级不误报）。`?v=N` 如相关则递增。

---

### 任务 4：代码 + 文档一次提交

**文件：** `TrollVNC/src/TRDataFiller.mm`、`AGENTS.md`、`说明文档.md`

- [ ] **步骤 1：提交（同一 commit）**

```bash
git add TrollVNC/src/TRDataFiller.mm AGENTS.md "说明文档.md"
git commit -m "feat: 短信清空计数口径+自动重启目标App+kill失败降级
- 清空短信 cleared 仅统计可见消息（EXISTS chat_message_join），根治数字虚高/递增
- 生成/清空后 kill MobilePhone/MobileSMS 自动重启，实现立即生效
- kill 未找到进程降级忽略，不误报部分失败；文档同步"
```

预期：commit 成功；`git status --short` 无本次改动残留。

---

### 任务 5：CI 编译验证（未验证不声称完成）

**文件：** 无（推送与触发）

- [ ] **步骤 1：推送并触发 CI**

```bash
# 远程 base = 当前远程 main sha（GET /repos/78725449/SuperPhone/git/ref/heads/main）
GHTOK=<token> node scripts/push-via-api.mjs <本地commit> <远程base> HEAD~1   # 外层 for 循环重试 503
# 推送后核对关键文件 sha（TrollVNC/src/TRDataFiller.mm 等）本地/远程一致
# POST /repos/78725449/SuperPhone/actions/workflows/build.yml/dispatches {"ref":"main"}（204）
# 匹配 run 用推送后的远程 HEAD sha（勿用本地 sha）
```

- [ ] **步骤 2：等待编译并下载校验**

```bash
GHTOK=<token> node -e "轮询 run 至 completed；下载 packages-bootstrap.zip；解压；tar -tf 校验 .tipa 条目与关键文件（trollvncmanager/trollvncserver/App 主二进制）"
```

预期：bootstrap job success，.tipa 体积 ~3.9MB 且关键文件齐全；default/rootless/roothide 3 job 同步 success。

- [ ] **步骤 3：真机验证清单（用户执行）**

| 场景 | 预期 |
|---|---|
| 生成 20 条短信 → 清空 | 提示约等于信息 App 可见短信数（无几百条虚高），连续两次不递增 |
| 清空后打开信息 App | 全空（删除仍全量） |
| 生成/清空通话后 | 电话 App 下次打开即新数据（无需手动重启） |
| 生成/清空短信后 | 信息 App 下次打开即新数据 |
| 电话/信息 App 未运行时清空 | 无"部分失败"字样（kill 未找到已忽略） |

---

## 自检

**1. 规格覆盖度：**
- §2.1 短信计数口径 → 任务 1 步骤 2 ✅
- §2.2 自动重启 App（清空侧）→ 任务 1 步骤 3（kills 加 App）✅
- §2.2 自动重启 App（生成侧）→ 任务 2 ✅
- §2.3 kill 失败降级 → 任务 1 步骤 4 + 任务 2（未找到忽略）✅
- §3 接口契约（cleared 语义、killError 信息级、UI 不动）→ 任务 1/2 内联 ✅
- §4 边界（通话计数不动、生成侧 SQL 不动、contacts 不动）→ 任务划分明确 ✅
- §5 验证门槛 → 任务 5 ✅

**2. 占位符扫描：** 无 TODO/待定；所有步骤含完整代码或精确命令。

**3. 类型一致性：** `killErrs`（NSMutableArray）在任务 1 内一致；`killError`/`appKillError`/`appKill` 键在任务 1/2 中一致；`trKillDaemon`/`trFindPidByName` 复用现有签名；SQL 别名 `m`/`j` 一致。
