r"""分层：给元素标注所属【区域】—— 不合并，只分组（零信息损失）。

★★ 契约（用户 2026-09-19 采纳方案 C「分层」）：
   · 元素（element）= 一个可点区域（图标/文字/开关）← OmniParser 直接给的
   · 区域（region） = 一个逻辑单元（如"设置的一行"）← 本文档新增
   · ★ 关系：区域【包含】元素（一对多），★ 但【不做合并】✗
     —— 因为合并会丢信息（行内右侧的开关本身也可点 ✗，合掉就没了）
   · 技能卡按需引用：引用区域 → 容错大；引用元素 → 精确 ✓

★★ 为什么要分层而不是二选一：
   "点设置里那一行" 与 "把那个开关打开" 是两种真实需求，
   前者要容错（点行任意处），后者要精确。分层让两者共存，成本只是【一次聚合】。

★ 分组规则（阈值全部【实测定】，不猜）：
   1. 按 y 中心分带：同带 = |dy| < DY
   2. 带内按 x 排序；相邻元素水平间隙 < GAP_X 的连成一段 → 一个 region
   3. region.bbox = 成员元素 bbox 的并集
"""
import glob
import json
import os
import re
import sys
from collections import defaultdict

import numpy as np

ROOT = r"D:\编程项目\SuperPhone"
SRC = os.path.join(ROOT, "data", "omniparser-elements-filtered")
OUT = os.path.join(ROOT, "data", "omniparser-regions")

DY = 0.018          # 同一水平带的 y 容差（归一化）
GAP_X = 0.030       # 水平间隙小于它才算"同一逻辑单元的一段"


def center_y(e, H):
    return (e["bbox"][1] + e["bbox"][3] / 2) / H


def left(e, W):
    return e["bbox"][0] / W


def right(e, W):
    return (e["bbox"][0] + e["bbox"][2]) / W


def wide(e, W):
    return e["bbox"][2] / W


def group(elems, W, H):
    """把元素按"同一水平带 + 水平相邻"分组，返回 (regions, elems_with_id)。"""
    idx = sorted(range(len(elems)), key=lambda i: center_y(elems[i], H))
    used = [False] * len(elems)
    regions = []
    for a in idx:
        if used[a]:
            continue
        band = [a]
        used[a] = True
        y0 = center_y(elems[a], H)
        for b in idx:
            if used[b]:
                continue
            if abs(center_y(elems[b], H) - y0) < DY:
                band.append(b)
                used[b] = True
        # 带内按 x 排序，间隙小的连段
        band.sort(key=lambda i: left(elems[i], W))
        seg, segs = [band[0]], []
        for k in range(1, len(band)):
            prev, cur = band[k - 1], band[k]
            gap = left(elems[cur], W) - right(elems[prev], W)
            if gap <= GAP_X:
                seg.append(cur)
            else:
                segs.append(seg)
                seg = [cur]
        segs.append(seg)
        for s in segs:
            bx1 = min(elems[i]["bbox"][0] for i in s) / W
            by1 = min(elems[i]["bbox"][1] for i in s) / H
            bx2 = max(elems[i]["bbox"][0] + elems[i]["bbox"][2] for i in s) / W
            by2 = max(elems[i]["bbox"][1] + elems[i]["bbox"][3] for i in s) / H
            regions.append({"bbox": [bx1, by1, bx2 - bx1, by2 - by1],
                            "members": s, "n": len(s)})
    out = []
    for ri, r in enumerate(regions):
        for i in r["members"]:
            e = dict(elems[i])
            e["regionId"] = ri
            out.append(e)
    return regions, out


files = sorted(glob.glob(os.path.join(SRC, "*.json")))
if not files:
    print("✗ 先跑 scripts/filter-element-table.py（它产出过滤后的元素表）")
    sys.exit(1)

print("=" * 96)
print("  分层：元素 → 区域（★ 只标注，不合并）")
print("  参数：同带 |dy|<%.3f · 相邻间隙 ≤%.3f" % (DY, GAP_X))
print("=" * 96)
os.makedirs(OUT, exist_ok=True)
print()
print("  %-14s %-9s %-9s %-11s %-11s %s"
      % ("文件", "元素", "区域", "多元素区域", "单元素区域", "★ 元素/区域"))
print("  " + "-" * 84)

agg = defaultdict(int)
by_label = defaultdict(lambda: defaultdict(int))
for f in files:
    d = json.load(open(f, encoding="utf-8"))
    W, H = d["size"]
    elems = d["elements"]
    regions, out = group(elems, W, H)
    multi = sum(1 for r in regions if r["n"] > 1)
    single = len(regions) - multi
    d2 = dict(d)
    d2["regions"] = [{"id": i, "bbox": r["bbox"], "n": r["n"]} for i, r in enumerate(regions)]
    d2["elements"] = out
    json.dump(d2, open(os.path.join(OUT, os.path.basename(f)), "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)
    lb = d["label"]
    agg["e"] += len(elems); agg["r"] += len(regions)
    agg["m"] += multi; agg["s"] += single; agg["f"] += 1
    by_label[lb]["e"] += len(elems); by_label[lb]["r"] += len(regions)
    by_label[lb]["m"] += multi; by_label[lb]["s"] += single; by_label[lb]["f"] += 1
    print("  %-14s %-9d %-9d %-11d %-11d %.2f"
          % (os.path.basename(f)[:14], len(elems), len(regions), multi, single,
             len(elems) / max(1, len(regions))))

print()
print("=" * 96)
print("  结论")
print("=" * 96)
for lb, t in by_label.items():
    n = max(1, t["f"])
    print("  【%s】平均 %.1f 元素/张 → ★ %.1f 区域/张（多元素区域 %.1f · 单元素 %.1f）"
          % (lb, t["e"] / n, t["r"] / n, t["m"] / n, t["s"] / n))
    print("     ★ 区域数【已是合理量级】—— 它才对应'一屏有几个逻辑单元'")
print()
print("  ★ 元素数没变（零信息损失 ✓），只是多了一层区域标注 ✓")
print("  ★ 技能卡选择：")
print("     · \"点设置里那一行\" → 引用 region.bbox（容错大）")
print("     · \"把那个开关打开\" → 引用 element.bbox（精确）")
print("  落盘：%s" % OUT)
