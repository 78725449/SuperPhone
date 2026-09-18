r"""元素表后处理：3 条过滤 —— 解"元素偏多"（抽查查出的三条根因）。

★★ 三条根因（见 scripts/check-duplicate-boxes.py 的实测）：
   ① ★ 主因：OCR 框【不加过滤】就全进元素表 ✗
      —— 状态栏「98%」、视频字幕都被当成"元素"。OmniParser 原版也这么做，
         但它假设"OCR 只识别 UI 文字"；RapidOCR 连状态栏/字幕/正文都识别。
   ② RapidOCR 把同段文字切成多块 ✗ —— 而 remove_overlap 不合并【文字框之间】
   ③ 图标框与文字框部分重叠但不达 0.80 阈值 → 没合并

★ 因此本脚本【从原始 boxes + ocr_bbox 重跑】（不能对已合并结果做事后过滤 ✗，
  因为 ③ 改变的是合并判定本身）：
   F1 过滤状态栏区（cy < 0.035）—— 二期就确认过这条：状态栏对任何页面都一致，是噪声
   F2 预合并【同行相邻的文字框】（同一水平带 + 水平间隙小 → 并成一个文字块）
   F3 放宽"图标含文字"的阈值（0.80 → 0.55），让更多的"图标+其文字"合成一个元素

★ 输出对比表：改前/改后 的元素数、纯图标数、带文字数。
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

from ultralytics import YOLO   # noqa: E402
from rapidocr_onnxruntime import RapidOCR   # noqa: E402

ROOT = r"D:\编程项目\SuperPhone"
WEIGHTS = os.path.join(ROOT, "_research", "OmniParser", "weights", "icon_detect", "model.pt")
MA = os.path.join(ROOT, "_research", "MobileAgent", "Mobile-Agent-v3.5", "mobile_use",
                  "打开设置，进入蓝牙页面，然后返回，再进入通用页面")
SETS = [(MA, "设置 App"), (os.path.join(ROOT, "ma35_task"), "抖音")]
OUT = os.path.join(ROOT, "data", "omniparser-elements-filtered")

STATUS_Y = 0.035        # F1：状态栏带宽（归一化）
SAME_ROW_DY = 0.018     # F2：同一行的 y 容差
GAP_X = 0.045           # F2：水平间隙小于它才算"相邻"
INSIDE_TH = 0.55        # F3：图标含文字的阈值（原版 0.80）


def imread_u(p):
    return cv2.imdecode(np.fromfile(p, dtype=np.uint8), cv2.IMREAD_COLOR)


# ── F2：预合并同行相邻的文字框 ─────────────────────────────────────────
def merge_text_boxes(ocr, W, H):
    """同一水平带、水平间隙小的文字框 → 并成一个。"""
    boxes = [dict(o) for o in ocr]
    changed = True
    while changed:
        changed = False
        for i in range(len(boxes)):
            for j in range(i + 1, len(boxes)):
                a, b = boxes[i]["bbox"], boxes[j]["bbox"]
                ay, by = a[1] + a[3] / 2, b[1] + b[3] / 2
                if abs(ay - by) / H > SAME_ROW_DY:
                    continue
                gap = max(a[0], b[0]) - min(a[0] + a[2], b[0] + b[2])
                if gap / W > GAP_X:
                    continue
                nx1, ny1 = min(a[0], b[0]), min(a[1], b[1])
                nx2, ny2 = max(a[0] + a[2], b[0] + b[2]), max(a[1] + a[3], b[1] + b[3])
                boxes[i] = {"type": "text", "bbox": [nx1, ny1, nx2 - nx1, ny2 - ny1],
                            "interactivity": False,
                            "content": "%s %s" % (a and boxes[i].get("content") or "",
                                                  boxes[j].get("content") or "")}
                boxes.pop(j)
                changed = True
                break
            if changed:
                break
    return boxes


# ── F3：带可调阈值的去重叠（逻辑同 OmniParser，只把 0.80 换成参数）──
def remove_overlap_th(boxes, ocr_bbox, iou_threshold=0.9, inside_th=0.80):
    def aera(b):
        return b[2] * b[3]

    def itr(b1, b2):
        x1, y1 = max(b1[0], b2[0]), max(b1[1], b2[1])
        x2, y2 = min(b1[0] + b1[2], b2[0] + b2[2]), min(b1[1] + b1[3], b2[1] + b2[3])
        return max(0, x2 - x1) * max(0, y2 - y1)

    def giou(b1, b2):
        i = itr(b1, b2)
        u = aera(b1) + aera(b2) - i + 1e-6
        a1, a2 = aera(b1), aera(b2)
        return max(i / u, i / a1 if a1 else 0, i / a2 if a2 else 0)

    def inside(b1, b2):
        a1 = aera(b1)
        return (itr(b1, b2) / a1) > inside_th if a1 else False

    filtered = list(ocr_bbox)
    for i, e1 in enumerate(boxes):
        b1 = e1["bbox"]
        if any(i != j and giou(b1, e2["bbox"]) > iou_threshold and aera(b1) > aera(e2["bbox"])
               for j, e2 in enumerate(boxes)):
            continue
        added, labels = False, ""
        for e3 in ocr_bbox:
            if added:
                break
            b3 = e3["bbox"]
            if inside(b3, b1):
                labels += (e3.get("content") or "") + " "
                if e3 in filtered:
                    filtered.remove(e3)
            elif inside(b1, b3):
                added = True
        if not added:
            filtered.append({"type": "icon", "bbox": b1, "interactivity": True,
                             "content": labels.strip() or None,
                             "source": "box_yolo_content_ocr" if labels else "box_yolo_content_yolo"})
    return filtered


model = YOLO(WEIGHTS)
ocr_engine = RapidOCR()
os.makedirs(OUT, exist_ok=True)

print("=" * 96)
print("  元素表后处理：F1 过滤状态栏 · F2 合并同行文字 · F3 放宽图标含文字阈值")
print("  参数：状态栏 y<%.3f · 同行 dy<%.3f · 相邻间隙<%.3f · 含文字阈值 %.2f"
      % (STATUS_Y, SAME_ROW_DY, GAP_X, INSIDE_TH))
print("=" * 96)

for shot_dir, label in SETS:
    shots = sorted(glob.glob(os.path.join(shot_dir, "screenshot_*.png")) +
                   glob.glob(os.path.join(shot_dir, "screenshot_*.jpg")),
                   key=lambda p: int(re.search(r"screenshot_(\d+)\.", p).group(1)))[:6]
    if not shots:
        continue
    print()
    print("─" * 96)
    print("  【%s】%d 张" % (label, len(shots)))
    print("─" * 96)
    print("  %-6s %-10s %-10s %-10s %-12s %-12s %-12s %s"
          % ("截图", "原元素", "→ 过滤后", "降幅", "原纯图标", "→ 纯图标", "带文字", "OCR框"))
    print("  " + "-" * 90)
    agg = dict(before=0, after=0, ib=0, ia=0, wt=0, ocr=0, n=0)
    for p in shots:
        sid = int(re.search(r"screenshot_(\d+)\.", p).group(1))
        im = imread_u(p)
        H, W = im.shape[:2]
        r = model.predict(im, conf=0.15, verbose=False)[0]
        boxes = []
        for b in r.boxes:
            x1, y1, x2, y2 = [float(v) for v in b.xyxy[0]]
            boxes.append({"type": "icon", "bbox": [x1, y1, x2 - x1, y2 - y1],
                          "interactivity": True, "content": None})
        res, _ = ocr_engine(im)
        ocr_raw = []
        for it in (res or []):
            pts, txt = it[0], it[1]
            xs = [float(q[0]) for q in pts]
            ys = [float(q[1]) for q in pts]
            x1, y1 = min(xs), min(ys)
            w, h = max(xs) - x1, max(ys) - y1
            ocr_raw.append({"type": "text", "bbox": [x1, y1, w, h],
                            "interactivity": False, "content": txt})
        # ── 原口径（不做事后处理）
        before = remove_overlap_th(boxes, [dict(o) for o in ocr_raw], inside_th=0.80)
        # ── 新口径
        ocr2 = [o for o in ocr_raw if (o["bbox"][1] + o["bbox"][3] / 2) / H >= STATUS_Y]  # F1
        ocr2 = merge_text_boxes(ocr2, W, H)                                               # F2
        after = remove_overlap_th(boxes, ocr2, inside_th=INSIDE_TH)                       # F3
        ib = sum(1 for e in before if e["type"] == "icon" and not e.get("content"))
        ia = sum(1 for e in after if e["type"] == "icon" and not e.get("content"))
        wt = sum(1 for e in after if e.get("content"))
        agg.update(before=agg["before"] + len(before), after=agg["after"] + len(after),
                   ib=agg["ib"] + ib, ia=agg["ia"] + ia, wt=agg["wt"] + wt,
                   ocr=agg["ocr"] + len(ocr_raw), n=agg["n"] + 1)
        print("  %-6d %-10d %-10d %-10s %-12d %-12d %-12d %d"
              % (sid, len(before), len(after),
                 "%.0f%%" % (100.0 * (1 - len(after) / max(1, len(before)))),
                 ib, ia, wt, len(ocr_raw)))
        with open(os.path.join(OUT, "%s_s%02d.json" % (label[:2], sid)), "w", encoding="utf-8") as fh:
            json.dump({"label": label, "screenshot": os.path.basename(p),
                       "size": [W, H], "elements": after}, fh, ensure_ascii=False, indent=2)
    n = max(1, agg["n"])
    print()
    print("  均值/张：原 %.1f 元素 → ★ 过滤后 %.1f（降 %.0f%%）"
          % (agg["before"] / n, agg["after"] / n,
             100.0 * (1 - agg["after"] / max(1, agg["before"]))))
    print("          ★ 纯图标 %.1f → %.1f · ★ 带文字 %.1f · OCR 原始框 %.1f"
          % (agg["ib"] / n, agg["ia"] / n, agg["wt"] / n, agg["ocr"] / n))

print()
print("=" * 96)
print("  判读")
print("=" * 96)
print("  ★ 关注两件事：")
print("    ① 元素数是否降到合理量级（设置页 15~50 · 抖音 15~60）")
print("    ② ★ 纯图标数【是否被误伤】—— 那是 OmniParser 的核心价值，不能为了减数把它砍掉")
print("  过滤后的元素表：%s" % OUT)
