r"""OmniParser 完整版第一步：把 YOLO 的碎框【去重叠】。

★★ 为什么需要它：实测抖音上 YOLO 裸输出 72 框/张（含 25 个 >8% 的大框）✗ —— 太碎。
   OmniParser 本体的 get_som_labeled_img 会用 remove_overlap_new 把碎框合并成"每个可交互元素一个框" ✓

★★★ 为什么不直接 import 它的 util.utils（2026-09-19 实测）：
   它在【模块顶层】就构造了两个 OCR 引擎 —— `reader = easyocr.Reader(['en'])` 与
   `paddle_ocr = PaddleOCR(...)` → 一 import 就要装 easyocr + paddleocr + paddlepaddle（几百 MB）
   并当场下模型 ✗。而 OCR 我们【已经有更好的】（Apple Vision：系统级、懂中文）✓。
   → 故把 remove_overlap_new 的逻辑【原样抄出来】（纯 numpy，只去掉 OCR 依赖），
     并对齐它那个"广义 IoU"设计（见下）。

★ 它的广义 IoU 很关键：标准 IoU 在"小框被大框包含"时分数很低 ✗，
  而 UI 里恰好全是这种情形（图标在按钮里、文字在卡片里）→
  它用 max(IoU, inter/area1, inter/area2)，所以"包含"也能判为重复 ✓
"""
import glob
import json
import os
import re
import sys

import numpy as np

import cv2
from ultralytics import YOLO

ROOT = r"D:\编程项目\SuperPhone"
WEIGHTS = os.path.join(ROOT, "_research", "OmniParser", "weights", "icon_detect", "model.pt")


# ── 抄自 OmniParser util/utils.py::remove_overlap_new（L241-319），去掉 OCR 引擎依赖 ──
def remove_overlap(boxes, iou_threshold, ocr_bbox=None):
    """boxes / ocr_bbox 元素形如 {'type','bbox':[x1,y1,x2,y2],'interactivity','content'}。"""

    def box_area(b):
        return (b[2] - b[0]) * (b[3] - b[1])

    def inter_area(b1, b2):
        x1, y1 = max(b1[0], b2[0]), max(b1[1], b2[1])
        x2, y2 = min(b1[2], b2[2]), min(b1[3], b2[3])
        return max(0, x2 - x1) * max(0, y2 - y1)

    def giou(b1, b2):
        """★ 广义 IoU：max(标准IoU, inter/area1, inter/area2) —— 让"包含"也判为重复。"""
        inter = inter_area(b1, b2)
        union = box_area(b1) + box_area(b2) - inter + 1e-6
        a1, a2 = box_area(b1), box_area(b2)
        r1 = inter / a1 if a1 > 0 else 0.0
        r2 = inter / a2 if a2 > 0 else 0.0
        return max(inter / union, r1, r2)

    def inside(b1, b2):
        a1 = box_area(b1)
        return (inter_area(b1, b2) / a1) > 0.80 if a1 > 0 else False

    filtered = list(ocr_bbox) if ocr_bbox else []
    for i, e1 in enumerate(boxes):
        b1 = e1["bbox"]
        valid = True
        for j, e2 in enumerate(boxes):
            b2 = e2["bbox"]
            # ★ 保留【较小的】那个框
            if i != j and giou(b1, b2) > iou_threshold and box_area(b1) > box_area(b2):
                valid = False
                break
        if not valid:
            continue
        if ocr_bbox:
            added = False
            labels = ""
            for e3 in ocr_bbox:
                if added:
                    break
                b3 = e3["bbox"]
                if inside(b3, b1):          # OCR 在图标内 → 合并文字
                    labels += (e3.get("content") or "") + " "
                    if e3 in filtered:
                        filtered.remove(e3)
                elif inside(b1, b3):        # 图标在 OCR 内 → 丢图标框
                    added = True
            if not added:
                filtered.append({"type": "icon", "bbox": b1, "interactivity": True,
                                 "content": labels or None,
                                 "source": "box_yolo_content_ocr" if labels else "box_yolo_content_yolo"})
        else:
            filtered.append(e1)
    return filtered


def imread_u(p):
    return cv2.imdecode(np.fromfile(p, dtype=np.uint8), cv2.IMREAD_COLOR)


def run(shot_dir, label, conf=0.15, iou=0.9):
    model = YOLO(WEIGHTS)
    shots = sorted(glob.glob(os.path.join(shot_dir, "screenshot_*.png")) +
                   glob.glob(os.path.join(shot_dir, "screenshot_*.jpg")),
                   key=lambda p: int(re.search(r"screenshot_(\d+)\.", p).group(1)))
    print("=" * 96)
    print("  去重叠前后对比 —— 界面：%s（%d 张 · conf=%.2f · iou=%.2f）" % (label, len(shots), conf, iou))
    print("=" * 96)
    print("  %-8s %-10s %-12s %-12s %s" % ("截图", "裸框数", "去重叠后", "降幅", "去重后框数分布"))
    print("  " + "-" * 88)
    tot_raw = tot_mer = 0
    for p in shots:
        sid = int(re.search(r"screenshot_(\d+)\.", p).group(1))
        im = imread_u(p)
        r = model.predict(im, conf=conf, iou=iou, verbose=False)[0]
        raw = []
        for b in r.boxes:
            x1, y1, x2, y2 = [float(v) for v in b.xyxy[0]]
            raw.append({"type": "icon", "bbox": [x1, y1, x2, y2],
                        "interactivity": True, "content": None})
        merged = remove_overlap(raw, iou_threshold=iou, ocr_bbox=None)
        tot_raw += len(raw)
        tot_mer += len(merged)
        print("  %-8d %-10d %-12d %-12s %s"
              % (sid, len(raw), len(merged),
                 "%d→%d" % (len(raw), len(merged)),
                 "%.0f%% 降幅" % (100.0 * (1 - len(merged) / max(1, len(raw))))))
    print()
    print("  合计：裸 %d 框 → 去重叠后 %d 框（降 %.0f%%）"
          % (tot_raw, tot_mer, 100.0 * (1 - tot_mer / max(1, tot_raw))))
    return tot_raw, tot_mer


if __name__ == "__main__":
    d1 = os.path.join(ROOT, "_research", "MobileAgent", "Mobile-Agent-v3.5", "mobile_use",
                      "打开设置，进入蓝牙页面，然后返回，再进入通用页面")
    d2 = os.path.join(ROOT, "ma35_task")
    a = run(d1, "设置 App")
    print()
    b = run(d2, "抖音（一期截图）")
    print()
    print("=" * 96)
    print("  结论")
    print("=" * 96)
    print("  ★ 若去重叠后框数降到【十几~二十几】，说明它确实能把碎框合并成'每个可交互元素一个框' ✓")
    print("  ★ 若几乎不降，说明 72 框里【大多是互不重叠的真元素】—— 那抖音首页确实元素多（合理）")
