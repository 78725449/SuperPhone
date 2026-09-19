r"""iou 阈值敏感度扫描 —— 看 OmniParser 的去重叠阈值该取多少。

★ 背景：默认 iou_threshold=0.9（OmniParser 自己用的），实测设置页仍剩 32 框/张（偏多）。
  但那是因为我没传 ocr_bbox（OCR 框才是合并主力 ✗）。
  在【纯 YOLO 框】的前提下，先看阈值本身能带来多少压缩 —— 为后面接 OCR 定基线。
"""
import glob
import os
import re
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from omniparser_merge_lib import remove_overlap   # noqa: E402

from ultralytics import YOLO   # noqa: E402

ROOT = r"D:\编程项目\SuperPhone"
WEIGHTS = os.path.join(ROOT, "_research", "OmniParser", "weights", "icon_detect", "model.pt")
SETS = [
    (os.path.join(ROOT, "_research", "MobileAgent", "Mobile-Agent-v3.5", "mobile_use",
                  "打开设置，进入蓝牙页面，然后返回，再进入通用页面"), "设置 App"),
    (os.path.join(ROOT, "ma35_task"), "抖音"),
]


def imread_u(p):
    return cv2.imdecode(np.fromfile(p, dtype=np.uint8), cv2.IMREAD_COLOR)


model = YOLO(WEIGHTS)
cache = {}
for d, label in SETS:
    shots = sorted(glob.glob(os.path.join(d, "screenshot_*.png")) +
                   glob.glob(os.path.join(d, "screenshot_*.jpg")),
                   key=lambda p: int(re.search(r"screenshot_(\d+)\.", p).group(1)))
    frames = []
    for p in shots:
        im = imread_u(p)
        r = model.predict(im, conf=0.15, verbose=False)[0]
        boxes = []
        for b in r.boxes:
            x1, y1, x2, y2 = [float(v) for v in b.xyxy[0]]
            boxes.append({"type": "icon", "bbox": [x1, y1, x2, y2],
                          "interactivity": True, "content": None})
        frames.append(boxes)
    cache[label] = frames

print("=" * 92)
print("  iou 阈值敏感度（纯 YOLO 框，无 OCR）—— 均值框数/张")
print("=" * 92)
print("  %-12s %s" % ("iou 阈值", "  ".join("%-14s" % s[1] for s in SETS)))
print("  " + "-" * 88)
for th in [0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1]:
    cells = []
    for _, label in SETS:
        frames = cache[label]
        n = sum(len(remove_overlap(f, iou_threshold=th)) for f in frames) / max(1, len(frames))
        cells.append("%-14.1f" % n)
    print("  %-12.2f %s" % (th, "  ".join(cells)))

print()
print("  ★ 参考：设置页一屏列表约 15~20 行 + 顶栏/底栏；抖音首页的可交互元素通常 10~25 个")
print("  ★ 目标：调到均值落在这个量级附近，再让 OCR 框去消掉剩下的'文字在图内'类重复")
