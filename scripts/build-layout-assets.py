r"""把帧级元素表聚合成【页面级资产】——这一步才是真正的"入库"。

★★ 为什么不能直接搬文件：
   data/omniparser-regions/ 是【帧级】的（12 份），而那 12 帧【分属不同页面】
   （漫游任务里跨了设置根页/墙纸页、抖音多屏）。资产应是【每个页面一份、去重后】的。
   → 所以"入库" = 【按页面聚合】，不是复制文件 ✗

★★★ 聚合靠什么：★ 帧间相似度（用各帧的元素 content 集合做 Jaccard）——
   同一页面的不同帧，元素文字高度重合；不同页面则重合低。
   （二期做的"页面签名"是同一思路，只是那时用的是设备端 OCR；这里是离线 OCR 的元素文字。）

★ 去重规则（同页面内多帧 → 一份）：
   · 元素按【内容 + 相对位置】对齐：content 相同且 bbox 中心距离 < 阈值 → 视为同一个
   · 保留【出现次数】(seen) —— 它是"这个元素有多稳定"的证据 ✓
   · 只保留【出现 ≥ 半数帧】的元素 → ★ 滤掉只在某一帧冒出的偶发项（如滚动到的临时内容）
"""
import glob
import json
import os
import re
import sys
from collections import Counter, defaultdict

import numpy as np

ROOT = r"D:\编程项目\SuperPhone"
SRC = os.path.join(ROOT, "data", "omniparser-regions")
OUT_DIR = os.path.join(ROOT, "skills", "superphone-device", "layouts")

SIM_TH = 0.45          # 帧间 Jaccard ≥ 此值 → 认为是同一页面
ALIGN_DIST = 0.05      # 元素对齐：bbox 中心距离（归一化）上限
MIN_KEEP = 0.5         # 元素出现比例 ≥ 此值才保留


def norm(s):
    return re.sub(r"\s+", "", s or "")


def load(f):
    d = json.load(open(f, encoding="utf-8"))
    d["_file"] = os.path.basename(f)
    return d


def sig(d):
    """帧签名 = 元素 content 的集合（文字类元素）。"""
    return set(norm(e.get("content")) for e in d["elements"] if e.get("content"))


def jac(a, b):
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


frames = [load(f) for f in sorted(glob.glob(os.path.join(SRC, "*.json")))]
if not frames:
    print("✗ 先跑 scripts/build-regions.py")
    sys.exit(1)

print("=" * 96)
print("  帧级元素表 → 页面级资产（按页面聚合）")
print("=" * 96)
print("  输入 %d 帧 · 帧间相似阈值 Jaccard ≥ %.2f" % (len(frames), SIM_TH))
print()

# ── 按相似度聚类成"页面"（贪心：与任一已有页面相似即归入）
pages = []
for fr in frames:
    s = sig(fr)
    placed = False
    for p in pages:
        if jac(s, p["sig"]) >= SIM_TH:
            p["frames"].append(fr)
            p["sig"] |= s
            placed = True
            break
    if not placed:
        pages.append({"sig": set(s), "frames": [fr]})

print("  聚类结果：%d 个页面" % len(pages))
for i, p in enumerate(pages):
    labs = Counter(f["label"] for f in p["frames"])
    print("    页面 %d：%d 帧（%s）· 元素文字 %d 种"
          % (i, len(p["frames"]), ",".join("%s×%d" % kv for kv in labs.items()), len(p["sig"])))

# ── 逐页面：把多帧的元素对齐、去重
print()
print("=" * 96)
print("  去重后的页面资产")
print("=" * 96)
print("  %-6s %-7s %-9s %-9s %-9s %s" % ("页面", "帧数", "元素候选", "保留", "滤掉", "区域数"))
print("  " + "-" * 84)

assets = []
for pi, p in enumerate(pages):
    nf = len(p["frames"])
    # 收集所有元素（带 regionId）
    cand = []
    for fr in p["frames"]:
        W, H = fr["size"]
        for e in fr["elements"]:
            b = e["bbox"]
            cand.append({"content": norm(e.get("content")),
                         "type": e.get("type"),
                         "cx": (b[0] + b[2] / 2) / W, "cy": (b[1] + b[3] / 2) / H,
                         "bbox": [round(v, 4) for v in b],
                         "source": e.get("source"), "regionId": e.get("regionId"),
                         "_f": fr["_file"]})
    # 对齐去重：同 content + 中心距离小 → 同一个；空 content 的按位置对齐
    groups = []
    for c in cand:
        hit = None
        for g in groups:
            if g[0]["content"] and c["content"] and g[0]["content"] != c["content"]:
                continue
            if not g[0]["content"] and c["content"]:
                continue
            if g[0]["content"] and not c["content"]:
                continue
            d = np.hypot(g[0]["cx"] - c["cx"], g[0]["cy"] - c["cy"])
            if d <= ALIGN_DIST:
                hit = g
                break
        if hit is None:
            groups.append([c])
        else:
            hit.append(c)
    kept = []
    for g in groups:
        seen = len(set(x["_f"] for x in g))
        if seen / nf < MIN_KEEP:
            continue
        g0 = g[0]
        kept.append({"type": g0["type"], "content": g0["content"] or None,
                     "bbox": g0["bbox"], "source": g0["source"],
                     "seen": "%d/%d" % (seen, nf),
                     "stability": round(seen / nf, 2)})
    # 区域数：按保留下来的元素的 regionId 去重（近似）
    regs = len(set(x["regionId"] for x in cand if x["regionId"] is not None))
    print("  %-6d %-7d %-9d %-9d %-9d %d"
          % (pi, nf, len(cand), len(kept), len(cand) - len(kept), regs))
    labs = Counter(f["label"] for f in p["frames"])
    app = labs.most_common(1)[0][0]
    assets.append({"index": pi, "app": app, "frames": nf,
                   "sourceFiles": [f["_file"] for f in p["frames"]],
                   "elements": kept, "regionCount": regs})

# ── 落盘：每个页面一份
for a in assets:
    d = os.path.join(OUT_DIR, a["app"].replace(" ", ""))
    os.makedirs(d, exist_ok=True)
    name = "page%02d_%dframes.json" % (a["index"], a["frames"])
    with open(os.path.join(d, name), "w", encoding="utf-8") as fh:
        json.dump({"app": a["app"], "frames": a["frames"],
                   "sourceScreenshots": a["sourceFiles"],
                   "regionCount": a["regionCount"],
                   "elementCount": len(a["elements"]),
                   "elements": a["elements"]}, fh, ensure_ascii=False, indent=2)

print()
print("=" * 96)
print("  产出")
print("=" * 96)
print("  页面资产 %d 份 → %s" % (len(assets), OUT_DIR))
for a in assets:
    pure = sum(1 for e in a["elements"] if e["type"] == "icon" and not e["content"])
    print("    %-10s %-22s 元素 %-4d（★ 纯图标 %-3d）· 区域 %d"
          % (a["app"], os.path.basename(glob.glob(os.path.join(
              OUT_DIR, a["app"].replace(" ", ""), "*%dframes.json" % a["frames"]))[0]),
             len(a["elements"]), pure, a["regionCount"]))
print()
print("  ★ 这就是【页面级资产】：每个页面一份、元素已去重、带 stability（出现比例）")
print("  ★ stability 高 = 该元素在这个页面上稳定存在 → 技能卡可以放心引用 ✓")
print()
print("  ★ 局限（诚实）：")
print("    · 帧少（每页 1~3 帧）→ stability 的分母小，参考价值有限 ✗")
print("    · 页面聚类用的是【元素文字 Jaccard】—— 对纯图标页会失效（无文字可比）✗")
