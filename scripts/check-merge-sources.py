r"""正确判据：合并到底发生了没有？—— 数 source 字段，不要用恒等式推断。

★★ 教训（2026-09-19）：我一度用"带文字数 == OCR 框数"作为"没发生合并"的证据 ——
   那是个【恒等式】✗：每个 OCR 框要么被合并进某个图标框（A 个），要么独立成元素（D 个），
   而"带文字"= A + D = OCR 总数 —— ★ 永远成立，不说明任何问题。
   → 正确做法：直接统计元素表里的 source 字段：
       box_yolo_content_ocr   = 合并了文字的图标框     ← ★ 机制真的生效的证据
       box_yolo_content_yolo  = 纯图标框（无文字）
       type='text'            = 未被合并、独立成元素的文字框
"""
import collections
import glob
import json
import os

OUT = r"D:\编程项目\SuperPhone\data\omniparser-elements"
files = sorted(glob.glob(os.path.join(OUT, "*.json")))
if not files:
    raise SystemExit("✗ 没有元素表，先跑 scripts/omniparser-full.py")

print("=" * 96)
print("  合并机制到底生效了没有 —— 数 source，不靠推导")
print("=" * 96)
print("  元素表 %d 份" % len(files))
print()

by_label = collections.defaultdict(lambda: collections.Counter())
tot = collections.Counter()
for f in files:
    d = json.load(open(f, encoding="utf-8"))
    lb = d["label"]
    for e in d["elements"]:
        key = e.get("source") or ("type:%s" % e.get("type"))
        by_label[lb][key] += 1
        tot[key] += 1

print("  %-28s %-14s %s" % ("来源(source)", "设置 App", "抖音"))
print("  " + "-" * 84)
allkeys = sorted(set(tot))
for k in allkeys:
    print("  %-28s %-14d %d" % (k, by_label["设置 App"].get(k, 0), by_label["抖音"].get(k, 0)))
print()
print("  合计：")
merged = tot.get("box_yolo_content_ocr", 0)
icononly = tot.get("box_yolo_content_yolo", 0)
textonly = tot.get("type:text", 0)
print("    ★ 合并了文字的图标框（box_yolo_content_ocr）：%d  ← ★ 机制生效的证据" % merged)
print("    ★ 纯图标框（box_yolo_content_yolo）        ：%d" % icononly)
print("    ★ 未被合并、独立成元素的文字框（type:text） ：%d" % textonly)
print()
print("=" * 96)
print("  判读")
print("=" * 96)
if merged > 0:
    print("  → ★★ 合并【确实发生了】✓ —— 有 %d 个元素是「图标框 + 并入的文字」✓✓✓" % merged)
    print("     即：element{region, content} 里既有位置、又有语义 —— 这正是我们要的形态 ✓")
    print("     带文字的元素共 %d 个（%d 合并 + %d 独立文字）" % (merged + textonly, merged, textonly))
else:
    print("  → ✗ 一个合并都没有：说明 inside() 判定没通过，需回查坐标口径（像素 vs 归一化）")
print()
print("  ★ 另一件要看的：纯图标框 %d 个 —— 这些【OCR 永远给不了】✓ 是 OmniParser 不可替代之处 ✓"
      % icononly)
