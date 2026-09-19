r"""查证：为什么"OCR 框在图标框内 → 合并"这个分支从没触发？

★ 现象（2026-09-19 实测）：最终元素里「带文字」数 == OCR 框数（19.3 == 19.3），
  说明每个 OCR 框都【单独成了元素】，而 OmniParser 的"合并 OCR 进图标框"分支一次没走。
★ 若成立，意味着：我们的 YOLO 框【不含】它旁边的文字 → 图文各自独立 →
  "图标 + 它的文字"没能合成一个元素。这会影响 element{region, content} 的质量。

本脚本直接量：图标框与 OCR 框之间的【包含/重叠】关系分布，
并列出几个典型例子，看 iOS 上"图标与文字"到底是不是分离的。
"""
import glob
import json
import os
import re
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ultralytics import YOLO   # noqa: E402
from rapidocr_onnxruntime import RapidOCR   # noqa: E402

ROOT = r"D:\编程项目\SuperPhone"
WEIGHTS = os.path.join(ROOT, "_research", "OmniParser", "weights", "icon_detect", "model.pt")
D1 = os.path.join(ROOT, "_research", "MobileAgent", "Mobile-Agent-v3.5", "mobile_use",
                  "打开设置，进入蓝牙页面，然后返回，再进入通用页面")


def imread_u(p):
    return cv2.imdecode(np.fromfile(p, dtype=np.uint8), cv2.IMREAD_COLOR)


def area(b):
    return (b[2] - b[0]) * (b[3] - b[1])


def inter(b1, b2):
    x1, y1 = max(b1[0], b2[0]), max(b1[1], b2[1])
    x2, y2 = min(b1[2], b2[2]), min(b1[3], b2[3])
    return max(0, x2 - x1) * max(0, y2 - y1)


model = YOLO(WEIGHTS)
ocr = RapidOCR()

print("=" * 96)
print("  查证：图标框 与 OCR 文字框 的包含/重叠关系")
print("=" * 96)
shots = sorted(glob.glob(os.path.join(D1, "screenshot_*.png")) +
               glob.glob(os.path.join(D1, "screenshot_*.jpg")),
               key=lambda p: int(re.search(r"screenshot_(\d+)\.", p).group(1)))[:4]

tot_ic = tot_oc = 0
occ_ocr_in_icon = 0     # OCR 落在某个图标框内（要求 >80%）
occ_icon_in_ocr = 0     # 图标落在某个 OCR 框内
occ_any_overlap = 0     # 任意 >10% 重叠
examples = []

for p in shots:
    sid = int(re.search(r"screenshot_(\d+)\.", p).group(1))
    im = imread_u(p)
    r = model.predict(im, conf=0.15, verbose=False)[0]
    icons = [[float(v) for v in b.xyxy[0]] for b in r.boxes]
    res, _ = ocr(im)
    texts = []
    for it in (res or []):
        pts, txt = it[0], it[1]
        xs = [float(q[0]) for q in pts]
        ys = [float(q[1]) for q in pts]
        texts.append(([min(xs), min(ys), max(xs), max(ys)], txt))
    tot_ic += len(icons)
    tot_oc += len(texts)
    for tb, txt in texts:
        a = area(tb)
        if a <= 0:
            continue
        best_in_icon = max([inter(tb, ib) / a for ib in icons], default=0.0)
        best_any = max([inter(tb, ib) / a for ib in icons], default=0.0)
        if best_in_icon > 0.80:
            occ_ocr_in_icon += 1
        if best_any > 0.10:
            occ_any_overlap += 1
        if len(examples) < 6 and best_any > 0.2:
            examples.append((sid, txt[:18], round(best_any, 2)))
    for ib in icons:
        a = area(ib)
        if a <= 0:
            continue
        if any(inter(ib, tb) / a > 0.80 for tb, _ in texts):
            occ_icon_in_ocr += 1

print("  样本 %d 张 · 图标框 %d 个 · OCR 框 %d 个" % (len(shots), tot_ic, tot_oc))
print()
print("  ★ OCR 框落在某图标框内（>80%%）：%d / %d  = %.1f%%"
      % (occ_ocr_in_icon, tot_oc, 100.0 * occ_ocr_in_icon / max(1, tot_oc)))
print("  ★ 图标框落在某 OCR 框内（>80%%）：%d / %d  = %.1f%%"
      % (occ_icon_in_ocr, tot_ic, 100.0 * occ_icon_in_ocr / max(1, tot_ic)))
print("  ★ OCR 与某图标框有 >10%% 重叠   ：%d / %d  = %.1f%%"
      % (occ_any_overlap, tot_oc, 100.0 * occ_any_overlap / max(1, tot_oc)))
print()
if examples:
    print("  有重叠的样例（截图, OCR文字, 落在图标内的比例）：")
    for sid, t, r_ in examples:
        print("    s%-3d %-20s %.2f" % (sid, t, r_))
else:
    print("  ★ 没有任何 OCR 框与图标框重叠 >20%")
print()
print("=" * 96)
print("  判读")
print("=" * 96)
if occ_ocr_in_icon / max(1, tot_oc) < 0.05:
    print("  → ★ 图标框与文字框【基本互不重叠】→ 我们的 YOLO 框【不含文字】✗")
    print("     ⇒ OmniParser 的'合并 OCR 进图标框'机制在我们的 iOS 截图上【不生效】")
    print("     ⇒ 后果：'图标 + 它的文字'没能合成一个元素，元素表里它们各自独立 ✗")
    print("     ⇒ 影响：content 语义覆盖率低（带文字的只是纯文字元素），L0 图标【没有名字】✗")
    print("     ⇒ ★ 对策：自己补一步'图文配对'（把与图标框相邻/下方最近的文字并进去）✓")
else:
    print("  → 存在相当比例的重叠，合并机制应当在起作用 → 需回查 remove_overlap 的参数")
