r"""验证 L0 图标库的正确建法：靠【视觉相似度聚类】，不靠 caption。

★★ 为什么改用聚类（2026-09-19 实测结论）：
   icon_caption 给 200 个纯图标出了 75 种名字，其中既有合理的（back / find / wifi network /
   messages / calendar / close ✓），也有明显乱猜的（asian people / coloring book / pocket camp ✗）
   和错字（powerattery ✗）。
   → 它的名字【不能直接当资产】✗。
   而 L0 图标库真正需要的不是"名字准"，而是"**同一图标能被认成同一个**" ✓
   —— 那件事该用【视觉特征聚类】做，名字只是聚好之后的【标注】。

★ 本脚本用 pHash（同一族我们已经用过、设备端也有：screen.hash）对图标聚类，回答：
    这 200 个图标里，有多少个【其实是同一个图标】？聚出来的类是否"看起来合理"（类内数量分布）？
"""
import glob
import json
import os
import re
import sys
from collections import Counter, defaultdict

import cv2
import numpy as np

ROOT = r"D:\编程项目\SuperPhone"
ELEM_DIR = os.path.join(ROOT, "data", "omniparser-elements")
CAP_JSON = os.path.join(ROOT, "data", "omniparser-captions.json")
OUT = os.path.join(ROOT, "data", "omniparser-icon-clusters.json")
MA = os.path.join(ROOT, "_research", "MobileAgent", "Mobile-Agent-v3.5", "mobile_use",
                  "打开设置，进入蓝牙页面，然后返回，再进入通用页面")
SHOT_DIRS = {"设置 App": MA, "抖音": os.path.join(ROOT, "ma35_task")}


def imread_u(p):
    return cv2.imdecode(np.fromfile(p, dtype=np.uint8), cv2.IMREAD_COLOR)


def phash(img, hash_size=8, highfreq_factor=4):
    """★ 与设备端 screen.hash 同族的 pHash（这里自己算，因为要对裁剪小图做）。"""
    s = hash_size * highfreq_factor
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    g = cv2.resize(g, (s, s), interpolation=cv2.INTER_AREA).astype(np.float32)
    d = cv2.dct(g)
    low = d[:hash_size, :hash_size]
    med = np.median(low[1:].flatten()) if low.size > 1 else 0.0
    return (low > med).flatten()


def hamming(a, b):
    return int(np.count_nonzero(a != b))


# 读 caption 明细（它已含 label/shot/bbox/caption）
caps = json.load(open(CAP_JSON, encoding="utf-8")) if os.path.exists(CAP_JSON) else []
if not caps:
    print("✗ 先跑 scripts/omniparser-caption.py（需要它落盘的图标清单）")
    sys.exit(1)

items = []
for c in caps:
    sd = SHOT_DIRS.get(c["label"])
    if not sd:
        continue
    img_path = os.path.join(sd, c["shot"])
    if not os.path.exists(img_path):
        continue
    im = imread_u(img_path)
    if im is None:
        continue
    x, y, w, h = c["bbox"]
    crop = im[y:y + h, x:x + w]
    if crop.size == 0:
        continue
    g = cv2.resize(crop, (32, 32))
    items.append({"key": "%s|%s|%d,%d" % (c["label"], c["shot"], x, y),
                  "label": c["label"], "caption": c.get("caption", ""),
                  "phash": phash(g),
                  "gray": cv2.cvtColor(g, cv2.COLOR_BGR2GRAY).astype(np.float32)})

print("=" * 96)
print("  图标聚类验证 —— %d 个纯图标" % len(items))
print("=" * 96)

# 贪心聚类：pHash 汉明距离 ≤ TH 视为同类（先到先得，取类的第一个为代表）
TH = 10
clusters = []
for it in items:
    placed = False
    for cl in clusters:
        if hamming(it["phash"], cl[0]["phash"]) <= TH:
            cl.append(it)
            placed = True
            break
    if not placed:
        clusters.append([it])
clusters.sort(key=lambda c: -len(c))

sizes = [len(c) for c in clusters]
print("  pHash 汉明阈值 ≤ %d → 聚成 %d 类（原 %d 个）" % (TH, len(clusters), len(items)))
print("  类大小：max %d · 中位 %d · 单例类 %d 个（占 %.0f%%）"
      % (max(sizes), int(np.median(sizes)), sum(1 for s in sizes if s == 1),
         100.0 * sum(1 for s in sizes if s == 1) / len(sizes)))
print()

# 用 caption 的【众数】给每个类当标签，并报告类内 caption 一致性（这是"名字有多可信"的度量）
print("  %-5s %-6s %-30s %-8s %s" % ("类#", "大小", "caption 众数", "一致率", "涉及界面"))
print("  " + "-" * 92)
out = []
for i, cl in enumerate(clusters[:18]):
    cs = Counter((x["caption"] or "").strip().lower() for x in cl)
    mode, n = cs.most_common(1)[0]
    labs = Counter(x["label"] for x in cl)
    out.append({"cluster": i, "size": len(cl), "mode_caption": mode,
                "purity": round(n / len(cl), 2),
                "labels": dict(labs),
                "members": [x["key"] for x in cl]})
    print("  %-5d %-6d %-30s %-8.2f %s"
          % (i, len(cl), mode[:30], n / len(cl),
             ",".join("%s×%d" % kv for kv in labs.items())))

print()
print("=" * 96)
print("  判读")
print("=" * 96)
multi = [c for c in clusters if len(c) > 1]
cov = sum(len(c) for c in multi)
print("  ★ 被归入多成员类的图标：%d / %d（%.0f%%）→ 这些是【确实重复出现】的图标 ✓"
      % (cov, len(items), 100.0 * cov / len(items)))
print("  ★ 单例类：%d 个（只出现过一次）—— 可能是独有图标，也可能是聚类太严 ✗"
      % sum(1 for s in sizes if s == 1))
print()
if multi:
    pur = np.mean([Counter((x["caption"] or "").strip().lower() for x in c).most_common(1)[0][1]
                   / len(c) for c in multi])
    print("  ★ 多成员类的 caption 一致率均值：%.2f" % pur)
    print("    → 若明显高于【全局的 1/75】水平，说明★ caption 在【同类内】比【全局】稳得多 ✓")
print()
print("  ★ 结论方向：L0 图标库 = 【按视觉特征聚类】+ 【每类用 caption 众数/人工确认命名】")
print("    而不是「逐个图标让模型起名」✗")
json.dump({"threshold": TH, "clusters": out,
           "allSizes": sizes}, open(OUT, "w", encoding="utf-8"),
          ensure_ascii=False, indent=2)
print("  明细已落盘：%s" % OUT)
