"""AGENTS.md 精简 第二遍：搬走「数据填充行为定稿 ①-⑯」整块（约 19KB）。

第一遍已把 AGENTS.md 从 67893 压到 58597（预算内）。本遍再搬「数据填充行为定稿（2026-08-25）」
及其 ⑥-⑯ 续条（从该行一直到文件末尾），把余量从 6.9KB 扩大到 ~26KB，
避免下次再记两条大记录就又超预算——那会让「已知坑」尾部再次对 AI 不可见。

其中的活纪律已在第一遍留下的「数据填充/伪装页两条活纪律（保留）」里覆盖：
  · CNContactStore 写删不 kill contactsd / sqlite 直写才 kill 对应 daemon
  · 伪装页 A 档收敛（写操作唯一入口 = App 内部直调）+ A/B 类分类指南
  · 「三处补齐」纪律（该行原文已含）
"""
import os, shutil, sys, datetime

ROOT = r"D:\编程项目\SuperPhone"
SRC = os.path.join(ROOT, "AGENTS.md")
ARCH = os.path.join(ROOT, "docs", "历史决策与排查存档.md")

ANCHOR = "- **数据填充行为定稿（2026-08-25）**"
TITLE = "数据填充行为定稿 ①-⑯（2026-08-25 ~ 08-27）"

lines = open(SRC, encoding="utf-8").read().split("\n")
orig = len("\n".join(lines).encode("utf-8"))

hits = [i for i, l in enumerate(lines) if l.startswith(ANCHOR)]
if len(hits) != 1:
    print("X 锚点命中 " + str(len(hits)) + " 次（须 1 次）")
    sys.exit(1)
s = hits[0]
e = len(lines)
# 去掉尾部的空行
while e > s and lines[e - 1].strip() == "":
    e -= 1
body = "\n".join(lines[s:e])
print("锚定: L" + str(s + 1) + "-" + str(e) + "  (" + str(len(body.encode("utf-8"))) + " bytes)")
print("末行: " + lines[e - 1][:70])

bkdir = os.path.join(ROOT, "data", "backups",
                     "agents-slim2-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
os.makedirs(bkdir, exist_ok=True)
shutil.copy2(SRC, os.path.join(bkdir, "AGENTS.md"))
print("备份 -> " + bkdir + "\n")

# 追加到存档
arch = open(ARCH, encoding="utf-8").read()
addition = "\n## " + TITLE + "\n\n" + body + "\n"
with open(ARCH, "a", encoding="utf-8") as f:
    f.write(addition)
print("存档追加: " + TITLE + "  (存档现 " + str(os.path.getsize(ARCH)) + " bytes)")

# 重建 AGENTS.md（删掉这一整块）
new_lines = lines[:s]
while new_lines and new_lines[-1].strip() == "":
    new_lines.pop()
out = "\n".join(new_lines) + "\n"
new_bytes = len(out.encode("utf-8"))

# 校验：body 完整在存档里
arch_now = open(ARCH, encoding="utf-8").read()
if body not in arch_now:
    print("X 存档里找不到完整块，未写入")
    sys.exit(1)
print("OK 校验：搬出的 " + str(len(body.encode("utf-8"))) + " bytes 完整出现在存档中")

with open(SRC, "w", encoding="utf-8") as f:
    f.write(out)

print()
print("AGENTS.md: " + str(orig) + " -> " + str(new_bytes) + " bytes  (本遍省 " + str(orig - new_bytes) + ")")
if new_bytes < 65536:
    print("预算 65536 -> OK 余量 " + str(65536 - new_bytes) + " bytes")
else:
    print("预算 65536 -> X 仍超 " + str(new_bytes - 65536))
print()
print("最终行数: " + str(len(out.split(chr(10)))))
