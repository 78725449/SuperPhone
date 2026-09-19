"""量 AGENTS.md 各条目的体量，找出该移出存档的最大几条。

AGENTS.md 超出工作区指令预算（65536），导致加载时末尾被截断 —— 「已知坑」尾部对 AI 不可见。
本脚本只读测量，不改文件。
"""
import os, re

P = r"D:\编程项目\SuperPhone\AGENTS.md"
raw = open(P, encoding="utf-8").read()
print(f"AGENTS.md 总计: {len(raw.encode('utf-8'))} bytes  ({len(raw)} chars)")
print(f"预算: 65536 bytes   超出: {len(raw.encode('utf-8')) - 65536}\n")

lines = raw.split("\n")

# 找「已知坑」章节
start = next(i for i, l in enumerate(lines) if l.startswith("## 已知坑"))
print(f"「已知坑」从 L{start+1} 开始，到文件末尾共 {len(lines)-start} 行")
print()

# 按顶层 "- **" 条目切分
entries = []
cur_start, cur_lines = None, []
for i in range(start, len(lines)):
    l = lines[i]
    if l.startswith("- **") or l.startswith("⑥ **") or l.startswith("⑦ **"):
        if cur_start is not None:
            entries.append((cur_start, i, cur_lines))
        cur_start, cur_lines = i, [l]
    elif cur_start is not None:
        cur_lines.append(l)
if cur_start is not None:
    entries.append((cur_start, len(lines), cur_lines))

sized = []
for s, e, ls in entries:
    text = "\n".join(ls)
    b = len(text.encode("utf-8"))
    title = re.sub(r"^[-\s]*", "", ls[0])[:60]
    sized.append((b, s + 1, e, title))

sized.sort(reverse=True)
print(f"{'bytes':>7}  {'行范围':>12}  条目")
print("-" * 100)
for b, s, e, t in sized:
    print(f"{b:>7}  L{s:>4}-{e:<5}  {t}")

print()
print("=== 前 8 条合计 ===")
tot = sum(x[0] for x in sized[:8])
print(f"  {tot} bytes —— 若全部移出存档，AGENTS.md 可降到约 {len(raw.encode('utf-8')) - tot} bytes")
print(f"  （目标 < 60000 以留余量；{'✓ 够了' if len(raw.encode('utf-8')) - tot < 60000 else '✗ 还不够，需多移几条'}）")

# 全文其他大段
print()
print("=== 「已知坑」之外的章节体量 ===")
sec = []
cur = None
for i, l in enumerate(lines):
    if l.startswith("## "):
        if cur:
            sec.append(cur)
        cur = [l, i, [l]]
    elif cur:
        cur[2].append(l)
if cur:
    sec.append(cur)
for name, i, ls in sec:
    print(f"  {len(chr(10).join(ls).encode('utf-8')):>7} bytes  L{i+1:<5} {name[:60]}")
