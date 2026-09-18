r"""OmniParser 完整版：YOLO 检测 + OCR 融合 + 去重叠 → 结构化【元素表】。

★ 完整管线（对齐 OmniParser 的 get_som_labeled_img，但换掉它的两个 OCR 引擎）：
    ① icon_detect（YOLOv8-Nano）      → 图标框
    ② OCR                            → 文字框 + 文字内容
    ③ remove_overlap(boxes, iou, ocr_bbox) → 每个可交互元素一个框 + 合并后的语义
  **OCR 我们用自己的（RapidOCR · 离线可用 ✓）**，因为：
    · OmniParser 顶层就构造 easyocr + paddleocr（几百 MB，且当场下模型）✗
    · 而【离线资产解析】这一步不要求用设备端 OCR ✓ → 电脑侧 OCR 更合适（可反复重跑历史截图 ✓）

★ 输出即是我们真正要的资产形态：
    {'type': 'icon', 'bbox': [...], 'interactivity': True,
     'content': '搜索'|'Menu'|None, 'source': 'box_yolo_content_ocr'|'box_yolo_content_yolo'}
  → content 非空 = 「带文字的可交互元素」✓；content 为空 = 「纯图标元素」✓ ← 后者正是 OCR 给不了的
"""
import glob
import json
import os
import re
import sys
import time

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
OUT_DIR = os.path.join(ROOT, "data", "omniparser-elements")


def imread_u(p):
    return cv2.imdecode(np.fromfile(p, dtype=np.uint8), cv2.IMREAD_COLOR)


print("=" * 96)
print("  OmniParser 完整版：YOLO + OCR 融合 + 去重叠")
print("=" * 96)

from rapidocr_onnxruntime import RapidOCR   # noqa: E402
ocr_engine = RapidOCR()
print("  ✓ RapidOCR 就绪（仅用于离线解析，不影响设备端）")
model = YOLO(WEIGHTS)
print("  ✓ icon_detect 就绪")
os.makedirs(OUT_DIR, exist_ok=True)
print()

summary = {}
for shot_dir, label in SETS:
    shots = sorted(glob.glob(os.path.join(shot_dir, "screenshot_*.png")) +
                   glob.glob(os.path.join(shot_dir, "screenshot_*.jpg")),
                   key=lambda p: int(re.search(r"screenshot_(\d+)\.", p).group(1)))
    if not shots:
        print("  ✗ %s 无截图" % label)
        continue
    print("─" * 96)
    print("  【%s】%d 张" % (label, len(shots)))
    print("─" * 96)
    print("  %-6s %-8s %-10s %-12s %-12s %s"
          % ("截图", "YOLO框", "OCR框", "最终元素", "★带文字", "★纯图标"))
    print("  " + "-" * 88)

    tot = {"yolo": 0, "ocr": 0, "elems": 0, "withtext": 0, "icononly": 0}
    t0 = time.time()
    for p in shots[:6]:            # 每类先跑 6 张（离线解析，可反复重跑，不必一次跑完）
        sid = int(re.search(r"screenshot_(\d+)\.", p).group(1))
        im = imread_u(p)
        r = model.predict(im, conf=0.15, verbose=False)[0]
        boxes = []
        for b in r.boxes:
            x1, y1, x2, y2 = [float(v) for v in b.xyxy[0]]
            boxes.append({"type": "icon", "bbox": [x1, y1, x2, y2],
                          "interactivity": True, "content": None})
        # OCR（RapidOCR 返回 [[box4点], text, score]）
        ocr_bbox = []
        try:
            res, _ = ocr_engine(im)
            for item in (res or []):
                pts, txt, score = item[0], item[1], item[2]
                xs = [float(q[0]) for q in pts]
                ys = [float(q[1]) for q in pts]
                ocr_bbox.append({"type": "text",
                                 "bbox": [min(xs), min(ys), max(xs), max(ys)],
                                 "interactivity": False, "content": txt})
        except Exception as e:
            print("      ⚠️ OCR 失败: %s" % str(e)[:60])
        elems = remove_overlap(boxes, iou_threshold=0.9, ocr_bbox=ocr_bbox)
        withtext = [e for e in elems if e.get("content")]
        icononly = [e for e in elems if e.get("type") == "icon" and not e.get("content")]
        tot["yolo"] += len(boxes)
        tot["ocr"] += len(ocr_bbox)
        tot["elems"] += len(elems)
        tot["withtext"] += len(withtext)
        tot["icononly"] += len(icononly)
        print("  %-6d %-8d %-10d %-12d %-12d %d"
              % (sid, len(boxes), len(ocr_bbox), len(elems), len(withtext), len(icononly)))
        with open(os.path.join(OUT_DIR, "%s_s%02d.json" % (label[:2], sid)), "w",
                  encoding="utf-8") as fh:
            json.dump({"label": label, "screenshot": os.path.basename(p),
                       "size": [im.shape[1], im.shape[0]],
                       "elements": elems, "ocrCount": len(ocr_bbox)},
                      fh, ensure_ascii=False, indent=2)
    n = 6
    elapsed = time.time() - t0
    print()
    print("  均值/张：YOLO %.1f 框 · OCR %.1f 框 → ★ 元素 %.1f 个"
          % (tot["yolo"] / n, tot["ocr"] / n, tot["elems"] / n))
    print("         其中 ★ 带文字的 %.1f 个 · ★★ 纯图标的 %.1f 个  ← 后者是 OCR 永远给不了的"
          % (tot["withtext"] / n, tot["icononly"] / n))
    print("  耗时：%.1f 秒/张（离线解析，可接受）" % (elapsed / n))
    summary[label] = tot
    print()

print("=" * 96)
print("  结论")
print("=" * 96)
for label, t in summary.items():
    n = 6
    print("  【%s】最终元素 %.1f 个/张 —— 带文字 %.1f · ★ 纯图标 %.1f"
          % (label, t["elems"] / n, t["withtext"] / n, t["icononly"] / n))
print()
print("  ★ 若「纯图标」占相当比例 → ★ OmniParser 补上了 OCR 给不了的那一半 ✓✓✓")
print("  ★ 若「带文字」占绝大多数 → 与 OCR 重叠度高，价值有限")
print("  元素表已落盘：%s" % OUT_DIR)
