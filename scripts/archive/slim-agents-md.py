"""把 AGENTS.md 里【已完结的历史条目】搬到存档文档，原位留一行索引。

动机：AGENTS.md 实测 67.9KB > 工作区指令预算 65536 → 加载时末尾被截断，
「已知坑」尾部（含 2026-09-18 刚记的 TLS/301 两课）对 AI 不可见。
「已知坑」占 54KB（全文 80%），其中最大的几条是【已完结的历史演进】而非活的纪律。

安全设计（教训：本项目曾因脚本删段误伤代码闭合）：
  ① 锚点定位（用条目的唯一开头文本），不硬编码行号
  ② 搬移前先断言每个锚点命中且唯一
  ③ 搬移后双向校验：移出的每条完整出现在存档里；行数自洽
  ④ 先备份，校验不过就不写
"""
import os, shutil, sys, datetime

ROOT = r"D:\编程项目\SuperPhone"
SRC = os.path.join(ROOT, "AGENTS.md")
ARCH = os.path.join(ROOT, "docs", "历史决策与排查存档.md")

KEEP_SIM = (
    '- **sim.* 外部能力已收敛（2026-08-26 起）**：`data.fill` / `data.clear` / `sim.itinerary` / '
    '`sim.location.*` 的**外部入口（注册表 + 0x50 + 5802）已全部移除**，唯一入口 = **App 内部直调**'
    '（伪装页三 Tab + 定位 UI）。外部再调返回「未知操作」属**预期**，勿当 bug。'
    '排查数据/定位不生效 → 先查 App 伪装页/定位 UI 直调链路。'
    'daemon 侧的注入机制演进史（双域配置 / 注入必重启 / 时间戳分辨新旧 / prefs-changed 热重载风暴 / '
    '区域漫游随机模式 等）已移入 `docs/历史决策与排查存档.md`。'
)

KEEP_BOOTSTRAP = (
    '- **App target（pbxproj）改动只在 bootstrap job 暴露**：default/rootless/roothide 三 scheme 用 theos gmake '
    '**直接编译源码、不读 xcodeproj**，仅 bootstrap 走 `xcodebuild -scheme TrollVNC` → '
    '**App target 改动可能三 scheme 全过而 bootstrap 失败**。'
    '排查特征：`Build package (bootstrap)` failure 而 `Diagnose bootstrap app compile` success。'
    '5 个具体坑（pbxproj ID 唯一 / `+` 要引号 / HEADER_SEARCH_PATHS 被覆盖 / `.mm` 的 C 函数要 `extern C` / '
    'ObjC 字典 key 要 `@`）见 `docs/历史决策与排查存档.md`。'
)

KEEP_DATAFILL = (
    '- **数据填充/伪装页两条活纪律（保留）**：'
    '① **CNContactStore 写删不 kill `contactsd`**（否则打断 XPC → 「通信错误」）；'
    '**sqlite 直写（calls/sms）才 kill 对应 daemon**；'
    '**勿回归"直写 AddressBook.sqlitedb"**（缺 FTS/触发器，系统列表不显示）。'
    '② **伪装页能力收敛 A 档（2026-08-26 定案）**：数据填充/定位**写操作唯一入口 = App 内部直调**；'
    '**新功能开发前先按 说明文档 §2.0「能力实现分类指南」判定 A/B 类**'
    '——App 里点的 → A 类（内部直调）；控制端/脚本调的 → B 类（三处补齐）。'
    '其余定案细节（清空联系人 / 短信软删与触发器 / 城市名归一 / ZHANDLE / 号段过滤 / 服务短信发件号 / '
    '每日轨迹 / 结果 UI 契约 等 ①-⑯）见 `docs/历史决策与排查存档.md`。'
)

MOVES = [
    {
        "anchor": '- **respring 全量去除记录（2026-08-24，红线见"架构红线"节）**',
        "keep": None,
        "title": "respring 全量去除记录（2026-08-24）",
    },
    {
        "anchor": "- **定位编排联动事件（2026-08-24；⚠️ 2026-08-26 起 sim.* 外部能力已收敛仅 App 内部直调",
        "keep": KEEP_SIM,
        "title": "定位编排联动事件与 daemon 注入机制演进（2026-08-24 ~ 08-27）",
    },
    {
        "anchor": "- **bootstrap job 才读 pbxproj（2026-08-25，阶段 3 五连败根因链）**",
        "keep": KEEP_BOOTSTRAP,
        "title": "bootstrap job 才读 pbxproj —— 阶段 3 五连败根因链（2026-08-25）",
    },
    {
        "anchor": "- **清空联系人报「通信错误」/「无响应」根因 + 精简定稿（2026-08-25）**",
        "keep": KEEP_DATAFILL,
        "title": "数据填充行为定稿与清空链路根治（2026-08-25 ~ 08-27，①-⑯）",
    },
]

raw = open(SRC, encoding="utf-8").read()
orig_bytes = len(raw.encode("utf-8"))
lines = raw.split("\n")
print("AGENTS.md 原始: " + str(orig_bytes) + " bytes, " + str(len(lines)) + " 行\n")

bkdir = os.path.join(ROOT, "data", "backups",
                     "agents-slim-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
os.makedirs(bkdir, exist_ok=True)
shutil.copy2(SRC, os.path.join(bkdir, "AGENTS.md"))
print("备份 -> " + bkdir + "\\AGENTS.md\n")

blocks = []
for mv in MOVES:
    hits = [i for i, l in enumerate(lines) if l.startswith(mv["anchor"])]
    if len(hits) != 1:
        print("X 锚点命中 " + str(len(hits)) + " 次（须恰好 1 次）: " + mv["anchor"][:50])
        sys.exit(1)
    s = hits[0]
    e = s + 1
    while e < len(lines):
        nl = lines[e]
        is_new = nl.startswith("- **") or (len(nl) > 3 and nl[0] in "⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯" and nl[1] == " ")
        if is_new:
            break
        e += 1
    blocks.append((s, e, mv))
    print("OK 锚定: " + mv["title"])
    print("   L" + str(s + 1) + "-" + str(e) + "  (" +
          str(len("\n".join(lines[s:e]).encode("utf-8"))) + " bytes)")

print()
blocks.sort(key=lambda x: x[0])
for i in range(len(blocks) - 1):
    if blocks[i][1] > blocks[i + 1][0]:
        print("X 块重叠")
        sys.exit(1)

arch_parts = [
    "# 历史决策与排查存档（SuperPhone）",
    "",
    "> **本文件是 `AGENTS.md` 的溢出存档**。AGENTS.md 超出工作区指令预算（65536 bytes）会导致",
    "> **加载时末尾被截断**（AI 看不到「已知坑」尾部），故把其中【已完结的历史演进】搬到这里。",
    ">",
    "> **搬移原则**：只搬【已完结 / 已被取代 / 纯历史演进】的条目；",
    "> **活着的纪律与红线一律留在 AGENTS.md**（TLS/301 协议契约、窄容器嵌入、SSH 装包路径、",
    "> 坐标语义双层、推送流程坑、noVNC 补丁注意项 等）。",
    ">",
    "> 搬移日期：" + datetime.datetime.now().strftime("%Y-%m-%d"),
    "",
    "---",
    "",
]
moved_texts = []
for s, e, mv in blocks:
    body = "\n".join(lines[s:e]).rstrip()
    moved_texts.append(body)
    arch_parts += ["## " + mv["title"], "", body, "", "---", ""]

os.makedirs(os.path.dirname(ARCH), exist_ok=True)
with open(ARCH, "w", encoding="utf-8") as f:
    f.write("\n".join(arch_parts))
print("存档已写: " + ARCH + "  (" + str(os.path.getsize(ARCH)) + " bytes)")

new_lines = list(lines)
for s, e, mv in sorted(blocks, key=lambda x: -x[0]):
    new_lines[s:e] = [mv["keep"]] if mv["keep"] else []

out = "\n".join(new_lines)
new_bytes = len(out.encode("utf-8"))

print()
print("=== 校验 ===")
ok = True
arch_now = open(ARCH, encoding="utf-8").read()
for t in moved_texts:
    if t not in arch_now:
        print("X 存档里找不到完整条目: " + t.split("\n")[0][:60])
        ok = False
print(("OK " if ok else "X ") + "移出的 " + str(len(moved_texts)) + " 条均完整出现在存档中")

removed = sum(e - s for s, e, _ in blocks)
kept = sum(1 for _, _, mv in blocks if mv["keep"])
expect = len(lines) - removed + kept
if len(new_lines) != expect:
    print("X 行数不符: " + str(len(new_lines)) + " != " + str(expect))
    ok = False
else:
    print("OK 行数自洽: " + str(len(lines)) + " - " + str(removed) + " + " + str(kept) +
          " = " + str(len(new_lines)))

if not ok:
    print("\nX 校验失败，未写入 AGENTS.md（备份仍在）")
    sys.exit(1)

with open(SRC, "w", encoding="utf-8") as f:
    f.write(out)
print()
print("AGENTS.md 已更新: " + str(orig_bytes) + " -> " + str(new_bytes) +
      " bytes  (省 " + str(orig_bytes - new_bytes) + ")")
if new_bytes < 65536:
    print("预算 65536 -> OK 已回到预算内，余量 " + str(65536 - new_bytes) + " bytes")
else:
    print("预算 65536 -> X 仍超出 " + str(new_bytes - 65536))
