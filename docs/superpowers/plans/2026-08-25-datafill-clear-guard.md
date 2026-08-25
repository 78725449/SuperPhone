# 数据填充清空残留校验与短信依赖校验 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** ① 清空联系人后重新枚举校验残留，>0 时显式报错（只读账户/SIM/iCloud 回写可感知）；② 短信生成加通讯录依赖校验，通讯录为空时整体拦截（与通话一致）。

**架构：** 全部改动集中在设备端共享模块 `TRDataFiller.mm`（clearDatabase contacts 分支追加清空后校验；trFillSms 追加依赖校验）；Node 端零改动（generateSms 作为纯算法原型保持能力，产品层门禁在设备端）；UI 无需改动（已有 `ok:NO → 显示 error` 逻辑）。

**技术栈：** ObjC（iOS Contacts framework CNContactStore）；CI = GitHub Actions bootstrap job 编译 .tipa。

**规格依据：** `docs/superpowers/specs/2026-08-25-datafill-clear-guard-design.md`（已批准 commit 1611932）。

**工作区纪律（必读）：**
- 设备端改动必须 CI 编译通过才声称完成（Windows 不能本地构建）。
- **对 `TRDataFiller.mm` 的多次编辑必须串行**（一次消息一个 SearchReplace；并行编辑会互相覆盖——2026-08-25 实测踩坑）。
- 改行为必须同步相邻注释；提交与文档同步同一 commit（代码+说明文档+AGENTS+CodeWiki 一次提交）。
- 完成后需 push + workflow_dispatch 触发 CI（push-via-api 不触发 Actions，必须手动 dispatch）。

---

### 任务 1：清空联系人后校验 + 残留报错

**文件：**
- 修改：`TrollVNC/src/TRDataFiller.mm` `clearDatabase` contacts 分支（L628-650 附近，`@end` 之前）

- [ ] **步骤 1：读取目标区域确认锚点**

读取 `TrollVNC/src/TRDataFiller.mm` L615-660，确认 contacts 分支结构（`if (all || [db isEqualToString:@"contacts"]) { ... }`、`NSMutableDictionary *out = [@{@"ok": @YES, @"db": db, @"cleared": @(cleared)} mutableCopy];`、`if (errors.count) out[@"errors"] = errors; return out;`）。

- [ ] **步骤 2：在 contacts 分支前声明残留计数变量**

在 `if (all || [db isEqualToString:@"contacts"])` 之前插入一行（紧跟 `NSMutableArray *errors = [NSMutableArray array];` 之后）：

```objc
    __block NSInteger remainContacts = -1; // 清空后残留数（-1=未校验/校验失败；仅 contacts 分支写入，非 contacts 清空不受影响）
```

- [ ] **步骤 3：删除循环后追加清空后校验**

在 contacts 分支的删除 for 循环结束后、`// 不 kill contactsd` 注释之前插入：

```objc
        // 清空后校验（2026-08-25 定稿）：重新枚举统计残留；>0 = 部分失败显式报错
        // （只读账户/SIM/iCloud 回写无法删除时给用户明确感知，避免"看似清空实际未删干净"）
        remainContacts = 0;
        CNContactFetchRequest *vReq = [[CNContactFetchRequest alloc] initWithKeysToFetch:@[CNContactIdentifierKey]];
        NSError *vErr = nil;
        if (![store enumerateContactsWithFetchRequest:vReq error:&vErr usingBlock:^(CNContact *c, BOOL *stop) {
            remainContacts++;
        }] && vErr) {
            [errors addObject:[NSString stringWithFormat:@"清空后校验失败: %@", vErr.localizedDescription ?: @"未知"]];
            remainContacts = -1; // 校验失败不判定残留
        }
```

- [ ] **步骤 4：out 创建后按残留数改写返回值**

在 `NSMutableDictionary *out = [@{@"ok": @YES, @"db": db, @"cleared": @(cleared)} mutableCopy];` 之后、`if (errors.count)` 之前插入：

```objc
    if (remainContacts > 0) {
        out[@"ok"] = @NO;
        out[@"remaining"] = @(remainContacts);
        out[@"error"] = [NSString stringWithFormat:@"仍有 %ld 条联系人未能删除（可能来自 iCloud 同步/只读账户/SIM 卡），请检查 设置→通讯录→账户", (long)remainContacts];
    }
```

- [ ] **步骤 5：核对完整性**

确认：`remainContacts` 声明在 `@implementation TRDataFiller` 方法体内（局部变量）；非 contacts 调用（`calls`/`sms`）时 remainContacts 保持 -1 不触发改写；`remaining` 字段仅残留场景存在，返回结构向后兼容。

---

### 任务 2：短信生成加通讯录依赖校验

**文件：**
- 修改：`TrollVNC/src/TRDataFiller.mm` `trFillSms`（L450-453 附近，`for (NSInteger i = 0; i < count; i++)` 之前）

- [ ] **步骤 1：定位家人朋友号码池代码**

确认锚点：

```objc
    // 家人朋友号码池（反差确认：家人消息号码在通讯录可查；通讯录空退化为随机号）
    NSDictionary *famPool = trLoadContactPool(nil);
    NSArray *famNumbers = @[];
    if (famPool) famNumbers = famPool[@"byRole"][@(TRRoleFamily)] ?: @[];
```

- [ ] **步骤 2：替换为依赖校验 + 号码池**

将上述 3 行替换为（保留 famNumbers 空数组时 family 类退化随机号的现有行为，仅在通讯录整体为空时拦截）：

```objc
    // 依赖校验（2026-08-25 定稿）：家人朋友短信依赖通讯录反查角色，通讯录为空整体拦截
    // （与通话生成一致，设计 §3.3 L191；Node generateSms 作为纯算法原型仍可脱离通讯录生成）
    NSDictionary *famPool = trLoadContactPool(nil);
    if (!famPool) return @{@"ok": @NO, @"error": @"通讯录为空，请先生成通讯录（家人朋友短信依赖通讯录）"};
    NSArray *famNumbers = famPool[@"byRole"][@(TRRoleFamily)] ?: @[];
```

- [ ] **步骤 3：核对语义**

确认：`trLoadContactPool` 返回 nil 的唯一条件 = 枚举联系人总数为 0（通讯录空）；通讯录非空但无 family 角色时 `famNumbers` 为空数组，family 类短信仍走 `else phone = trRandomPhone()` 退化（现有行为，不在本次改动范围）；其余 5 类短信（code/express/bank/carrierSms/marketing 90%）不依赖通讯录但受整体校验约束（符合用户定案"短信也报错拦截"）。

---

### 任务 3：文档同步（与代码同 commit）

**文件：**
- 修改：`AGENTS.md`（「数据填充行为定稿」条目补两条）
- 修改：`说明文档.md`（§4.8 数据填充对应条目）
- 修改：`CodeWiki.md`（相关行号/数量/描述校准）

- [ ] **步骤 1：AGENTS.md 数据填充行为定稿补条目**

在「数据填充行为定稿（2026-08-25）」条目（③之后）追加：

```markdown
④ **清空残留校验（2026-08-25）**：清空联系人后重新枚举 CNContactStore 统计残留，残留>0 → 返回 `ok:NO` + `remaining` + 明确报错（iCloud 同步/只读账户/SIM 卡提示）；校验枚举失败仅提示不误报。防"看似清空实际未删干净"无感知。
⑤ **短信依赖校验（2026-08-25）**：短信生成前置依赖校验，通讯录为空 → 整体拦截返回"通讯录为空，请先生成通讯录（家人朋友短信依赖通讯录）"（与通话一致，设计 §3.3 L191）；Node generateSms 作为纯算法原型保持可脱离通讯录生成（family `phone:null`）——算法层提供能力、产品层加门禁的分层。
```

- [ ] **步骤 2：说明文档.md §4.8 同步**

在说明文档.md §4.8 数据填充相关小节补两处：清空联系人返回含 `remaining` 校验字段；短信生成在通讯录为空时返回依赖校验错误。同步 `?v=N`（若该章节引用缓存号则递增）。

- [ ] **步骤 3：CodeWiki.md 校准**

搜索 CodeWiki.md 中与 data.fill / 清空 / 短信生成相关的行号或数量描述，按本次改动校准（如 clearDatabase 返回值描述、trFillSms 依赖校验描述）。

---

### 任务 4：代码 + 文档一次提交

**文件：**
- `TrollVNC/src/TRDataFiller.mm`
- `AGENTS.md`、`说明文档.md`、`CodeWiki.md`

- [ ] **步骤 1：提交（同一 commit，项目纪律"代码与文档同步"）**

```bash
git add TrollVNC/src/TRDataFiller.mm AGENTS.md "说明文档.md" CodeWiki.md
git commit -m "feat: 清空残留校验与短信通讯录依赖校验
- 清空联系人后重新枚举，残留>0 显式报错（remaining 字段）
- 短信生成通讯录为空整体拦截，与通话校验一致
- 文档同步（说明文档/AGENTS/CodeWiki）"
```

预期：commit 成功；`git status --short` 无本次改动残留。

---

### 任务 5：CI 编译验证（未验证不声称完成）

**文件：** 无（推送与触发）

- [ ] **步骤 1：推送并触发 CI**

```bash
# 推送（Git Data API，push-via-api 不触发 Actions）
GHTOK=<token> node scripts/push-via-api.mjs <本地commit> main <本地base>
# 触发编译（不受 paths 过滤限制）
# POST /repos/78725449/SuperPhone/actions/workflows/build.yml/dispatches {"ref":"main"}
# 匹配 run 用推送后的远程 HEAD sha（重新 GET /git/ref/heads/main，勿用本地 sha）
```

- [ ] **步骤 2：等待编译并核对结果**

```bash
GHTOK=<token> node scripts/wait-ipa.mjs <runId>
```

预期：bootstrap job 编译成功，产出 .tipa；default/rootless/roothide 3 个 .deb job 同样 success。**若 bootstrap 失败**：检查 check-run annotations（billing 拦截）与编译错误（本次仅 .mm 局部改动，无 pbxproj/头文件变更，风险低）。

- [ ] **步骤 3：真机验证清单（用户执行）**

| 场景 | 预期 |
|---|---|
| 清空通讯录（无残留） | 显示"已清空 N 条联系人"（ok:YES） |
| 通讯录含只读/SIM 残留时清空 | 显示"清空失败：仍有 N 条联系人未能删除…" |
| 清空通讯录后点生成短信 | 显示"生成失败：通讯录为空，请先生成通讯录（家人朋友短信依赖通讯录）" |
| 生成通讯录后点生成短信 | 正常生成，family 类使用家人号码 |
| 生成通讯录后点生成通话 | 行为不变（原有校验） |

---

## 自检

**1. 规格覆盖度：**
- 规格 §2.1（清空后校验）→ 任务 1 ✅
- 规格 §2.2（短信依赖校验）→ 任务 2 ✅
- 规格 §2.3（文档同步）→ 任务 3 ✅
- 规格 §3（接口契约：remaining 字段、错误文案）→ 任务 1/2 内联 ✅
- 规格 §4（边界：calls/sms 清空不动、通话校验不动、Node 零改动）→ 任务 1/2 边界说明 ✅
- 规格 §5（验证门槛）→ 任务 5 ✅

**2. 占位符扫描：** 无 TODO/待定；所有步骤含完整代码或精确命令。

**3. 类型一致性：** `remainContacts`（NSInteger）在任务 1 三处引用一致；`remaining` 键与规格 §3 一致；`trLoadContactPool`/`famPool`/`famNumbers` 复用现有类型与命名，无新类型跨任务引用。
