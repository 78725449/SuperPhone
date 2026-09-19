r"""补测：OmniParser 检出的框，到底是【图标】还是【文字块】？

★ 为什么问这个：我们的痛点是"图标类控件抓不到"✗（二期实测死结）。
  若它检出的大多是【扁长的文字行】→ 那 OCR 已经够了 ✗ 它没带来新东西 ✗
  若它检出相当比例的【近方形小块】→ ★ 那才是图标 ✓ 才是它不可替代的价值 ✓✓✓

★ 判据：宽高比 ≈ 1:1 且面积小 → 图标型；宽高比 > 2.5:1 且扁 → 文字行型。
  （这是我们唯一能在【没有当时 OCR】的情况下做出的客观判别。）
"""
import glob
import os
import re
import sys

import cv2
import numpy as np

ROOT = r"D:\编程项目\SuperPhone"
W = os.path.join(ROOT, "_research", "OmniParser", "weights", "icon_detect", "model.pt")
MA = os.path.join(ROOT, "_research", "MobileAgent", "Mobile-Agent-v3.5", "mobile_use")
TASK = "打开设置，进入蓝牙页面，然后返回，再进入通用页面"
# ★ 支持传入别的截图目录 —— 设置页（列表型）≠ 抖音首页（图标密集），
#   结论必须分界面类型给，不能拿一类界面推全体。
SHOT_DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.join(MA, TASK)
LABEL = sys.argv[2] if len(sys.argv) > 2 else "设置 App"
OUT = os.path.join(ROOT, "data", "omniparser-crops")

from ultralytics import YOLO  # noqa: E402

model = YOLO(W)


def imread_u(p):
    return cv2.imdecode(np.fromfile(p, dtype=np.uint8), cv2.IMREAD_COLOR)


os.makedirs(OUT, exist_ok=True)
shots = sorted(glob.glob(os.path.join(SHOT_DIR, "screenshot_*.png")) +
               glob.glob(os.path.join(SHOT_DIR, "screenshot_*.jpg")),
               key=lambda p: int(re.search(r"screenshot_(\d+)\.", p).group(1)))

print("=" * 96)
print("  补测：检出的框是【图标】还是【文字行】？  —— 界面：%s" % LABEL)
print("  目录：%s（%d 张）" % (SHOT_DIR, len(shots)))
print("=" * 96)
if not shots:
    print("  ✗ 该目录没有截图")
    sys.exit(1)

allb = []
for p in shots:
    sid = int(re.search(r"screenshot_(\d+)\.", p).group(1))
    im = imread_u(p)
    H, Wd = im.shape[:2]
    r = model.predict(im, conf=0.15, verbose=False)[0]
    for i, b in enumerate(r.boxes):
        x1, y1, x2, y2 = [float(v) for v in b.xyxy[0]]
        w, h = x2 - x1, y2 - y1
        if w <= 0 or h <= 0:
            continue
        allb.append({"step": sid, "x": x1, "y": y1, "w": w, "h": h,
                     "ar": w / h, "area": 100.0 * w * h / (Wd * H),
                     "conf": float(b.conf[0]), "img": im, "W": Wd, "H": H})

print("  总框数 %d（12 张截图）" % len(allb))
ars = np.array([b["ar"] for b in allb])
areas = np.array([b["area"] for b in allb])

print()
print("  宽高比分布：")
for lo, hi, label in [(0, 0.4, "极竖长 (>>高度)"),
                      (0.4, 0.7, "竖长"),
                      (0.7, 1.4, "★ 近方形 ← 图标型"),
                      (1.4, 2.5, "横长"),
                      (2.5, 99, "★ 扁长 ← 文字行型")]:
    n = int(((ars >= lo) & (ars < hi)).sum())
    print("    %-22s %4d 个  %5.1f%%" % (label, n, 100.0 * n / len(allb)))

sq = ((ars >= 0.7) & (ars < 1.4)).sum()
flat = (ars >= 2.5).sum()
print()
print("  ★ 近方形(图标型) %d 个 (%.1f%%) · 扁长(文字行型) %d 个 (%.1f%%)"
      % (sq, 100.0 * sq / len(allb), flat, 100.0 * flat / len(allb)))

print()
print("  面积分布：")
for lo, hi in [(0, 0.1), (0.1, 0.3), (0.3, 1.0), (1.0, 3.0), (3.0, 8.0), (8.0, 100)]:
    n = int(((areas >= lo) & (areas < hi)).sum())
    print("    %5.1f%% ~ %5.1f%%   %4d 个" % (lo, hi, n))

# 把近方形的小框裁出来存盘 —— 那些就是"图标素材"的候选
print()
print("  ★ 裁出【近方形且面积 < 3%%】的框（图标素材候选）→ %s" % OUT)
n_crop = 0
for b in allb:
    if 0.7 <= b["ar"] < 1.4 and b["area"] < 3.0 and b["w"] >= 16 and b["h"] >= 16:
        x, y, w, h = int(b["x"]), int(b["y"]), int(b["w"]), int(b["h"])
        crop = b["img"][y:y + h, x:x + w]
        if crop.size == 0:
            continue
        fn = os.path.join(OUT, "s%02d_%d_%dx%d_c%.2f.png" %
                          (b["step"], n_crop, w, h, b["conf"]))
        cv2.imencode(".png", crop)[1].tofile(fn)     # ★ 同样避开非 ASCII 路径问题
        n_crop += 1
print("    裁出 %d 张" % n_crop)

print()
print("=" * 96)
print("  结论")
print("=" * 96)
if sq / len(allb) >= 0.25:
    print("  ★★ 近方形占比 %.0f%% —— ★ 它确实检出了【图标类元素】✓"
          % (100.0 * sq / len(allb)))
    print("     → 这是 OCR 给不了的东西 ✓ → 它有不可替代的价值 ✓✓✓")
else:
    print("  ⚠️ 近方形只占 %.0f%% —— 它主要在框【文字行】✗" % (100.0 * sq / len(allb)))
    print("     → 与 OCR 重叠度高 → 价值有限 → 考虑自己微调 ✗")
print()
print("  ★ 注意：本例是【设置 App】（列表型界面，文字多图标少）→ 结论只对这一类界面成立。")
print("    要判断「对抖音那种图标密集界面」的效果，需要那边的截图 —— 目前没有 ✗")
