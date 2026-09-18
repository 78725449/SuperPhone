r"""查证：那些"重复覆盖"是【一行被拆成多段】(合理)，还是【真·重复框】(该合)？

★★ 动机：抽查发现"重复覆盖"占比很高（抖音 83% · 设置 59%）——
   同一坐标被多个元素框包含。这有两种截然不同的解释：
     ① 粒度不同：一行设置/一个 tab 被拆成"图标框 + 文字框 + 箭头框"，各自不重叠 →
        ★ 这不是 bug，是 OmniParser 输出【元素】而非【行】；
     ② 真重复：几个框几乎盖在同一块地方 → ★ 那是合并不够，该修。

★ 判据：取"被多个框覆盖"的那些点，看这些框之间的关系：
   · 若【y 相近而 x 分离】→ 同行不同段（解释 ①）✓
   · 若【互相重叠】(IoU 高) → 真重复（解释 ②）✗
"""
import glob
import json
import os
import re
import sys
from collections import defaultdict

import cv2

ROOT = r"D:\编程项目\SuperPhone"
ELEM_DIR = os.path.join(ROOT, "data", "omniparser-elements")


def area(b):
    return b[2] * b[3]


def inter(b1, b2):
    x1, y1 = max(b1[0], b2[0]), max(b1[1], b2[1])
    x2, y2 = min(b1[0] + b1[2], b2[0] + b2[2]), min(b1[1] + b1[3], b2[1] + b2[3])
    return max(0, x2 - x1) * max(0, y2 - y1)


def iou(b1, b2):
    i = inter(b1, b2)
    return i / (area(b1) + area(b2) - i + 1e-6) if i else 0.0


print("=" * 96)
print("  查证：重复覆盖 = 同行不同段（合理）还是真重复（该合）？")
print("=" * 96)

stat = defaultdict(int)
samples = []
for f in sorted(glob.glob(os.path.join(ELEM_DIR, "*.json"))):
    d = json.load(open(f, encoding="utf-8"))
    elems = d["elements"]
    W, H = d["size"]
    # 检查每一对元素框：是否重叠
    for i in range(len(elems)):
        for j in range(i + 1, len(elems)):
            a, b = elems[i]["bbox"], elems[j]["bbox"]
            v = iou(a, b)
            if v <= 0.02:
                continue
            # 两框中心的 y 差（归一化）与 x 差
            ay, by = a[1] + a[3] / 2, b[1] + b[3] / 2
            ax, bx = a[0] + a[2] / 2, b[0] + b[2] / 2
            dy = abs(ay - by) / H
            dx = abs(ax - bx) / W
            if dy < 0.02:
                stat["同高"] += 1          # 同一水平带 → 很可能是"一行被拆"
            else:
                stat["异高"] += 1
            if v > 0.5:
                stat["高重叠(>0.5)"] += 1  # 真重复
            elif v > 0.2:
                stat["中重叠(0.2~0.5)"] += 1
            else:
                stat["低重叠(0.02~0.2)"] += 1
            if len(samples) < 10 and v > 0.2:
                samples.append((os.path.basename(f), v, a, b, dy, dx,
                                elems[i].get("type"), elems[j].get("type"),
                                elems[i].get("content"), elems[j].get("content")))

tot_pairs = stat["同高"] + stat["异高"]
print("  有重叠的元素对：%d 对" % tot_pairs)
print("    ★ 同一水平带（|dy| < 2%%）: %d 对 = %.0f%%  ← ★ 很可能是「一行被拆成多段」✓"
      % (stat["同高"], 100.0 * stat["同高"] / max(1, tot_pairs)))
print("    ★ 不同水平带            : %d 对 = %.0f%%" % (stat["异高"], 100.0 * stat["异高"] / max(1, tot_pairs)))
print()
print("  重叠强度：")
for k in ["高重叠(>0.5)", "中重叠(0.2~0.5)", "低重叠(0.02~0.2)"]:
    print("    %-18s %d 对" % (k, stat[k]))
print()
if samples:
    print("  高/中重叠的样例（文件, IoU, 框A, 框B, dy, dx, 类型, 内容）：")
    for s in samples:
        print("    %-14s IoU %.2f  A%s B%s  dy %.3f dx %.3f  %s/%s  「%s」「%s」"
              % (s[0][:14], s[1], tuple(round(v) for v in s[2]), tuple(round(v) for v in s[3]),
                 s[4], s[5], s[6], s[7], (s[8] or "")[:8], (s[9] or "")[:8]))
print()
print("=" * 96)
print("  判读")
print("=" * 96)
hi = stat["高重叠(>0.5)"]
if tot_pairs == 0:
    print("  → 没有元素对重叠：说明「重复覆盖」是【包含关系】（大框里有小框）而非重叠 ✓")
elif hi / max(1, tot_pairs) < 0.15:
    print("  → ★ 高重叠对很少（%.0f%%）→ ★ 主要不是「真重复」，而是【包含/同行不同段】✓"
          % (100.0 * hi / tot_pairs))
    print("     ⇒ 「重复覆盖率高」是【粒度现象】：OmniParser 输出【元素】而非【行/区域】✓")
    print("     ⇒ 若要「一行一个框」，需要我们自己补一步【行聚类】（同 y 的框按 x 合并）")
else:
    print("  → ✗ 高重叠对占 %.0f%% → 确实有【真重复框】，合并逻辑没吃干净" % (100.0 * hi / tot_pairs))
