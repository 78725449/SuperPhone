r"""OmniParser 去重叠逻辑的独立库 —— 抄自其 util/utils.py::remove_overlap_new（L241-319）。

★★ 为什么不直接 import OmniParser 的 util.utils（2026-09-19 实测）：
   它在【模块顶层】就构造两个 OCR 引擎：
       reader = easyocr.Reader(['en'])
       paddle_ocr = PaddleOCR(...)
   → 一 import 就要装 easyocr + paddleocr + paddlepaddle（几百 MB）并当场下模型 ✗。
   而 去重叠 这段逻辑本身【只依赖 numpy】✓ → 抄出来即可，OCR 用我们自己的。

★ 它的广义 IoU 是这段逻辑的精髓：
   标准 IoU 在"小框被大框包含"时分数很低 ✗，而 UI 里恰好全是这种情形
   （图标在按钮里、文字在卡片里）→ 它用 max(IoU, inter/area1, inter/area2)，
   于是"包含"也能被判为重复并合并 ✓

★ 合并规则（照抄）：
   ① 保留【较小的】框（若两个框广义 IoU 超阈且当前更大 → 丢弃当前）
   ② 传入 OCR 框时：OCR 框优先放入结果
      · OCR 框在图标框【内】 → 把 OCR 文字并进该图标框的 content，并移除那个 OCR 框
      · 图标框在 OCR 框【内】 → 丢弃图标框（认为它已是文字的一部分）
"""
from typing import List, Optional


def remove_overlap(boxes: List[dict], iou_threshold: float,
                   ocr_bbox: Optional[List[dict]] = None) -> List[dict]:
    """boxes / ocr_bbox 的元素形如：
    {'type': 'icon'|'text', 'bbox': [x1, y1, x2, y2], 'interactivity': bool, 'content': str|None}
    """
    def box_area(b):
        return (b[2] - b[0]) * (b[3] - b[1])

    def inter_area(b1, b2):
        x1, y1 = max(b1[0], b2[0]), max(b1[1], b2[1])
        x2, y2 = min(b1[2], b2[2]), min(b1[3], b2[3])
        return max(0, x2 - x1) * max(0, y2 - y1)

    def giou(b1, b2):
        """★ 广义 IoU：max(标准IoU, inter/area1, inter/area2)。"""
        inter = inter_area(b1, b2)
        union = box_area(b1) + box_area(b2) - inter + 1e-6
        a1, a2 = box_area(b1), box_area(b2)
        r1 = inter / a1 if a1 > 0 else 0.0
        r2 = inter / a2 if a2 > 0 else 0.0
        return max(inter / union, r1, r2)

    def inside(b1, b2):
        """b1 是否有 >80% 落在 b2 里。"""
        a1 = box_area(b1)
        return (inter_area(b1, b2) / a1) > 0.80 if a1 > 0 else False

    filtered = list(ocr_bbox) if ocr_bbox else []
    for i, e1 in enumerate(boxes):
        b1 = e1["bbox"]
        valid = True
        for j, e2 in enumerate(boxes):
            if i == j:
                continue
            b2 = e2["bbox"]
            # ★ 保留【较小的】那个框
            if giou(b1, b2) > iou_threshold and box_area(b1) > box_area(b2):
                valid = False
                break
        if not valid:
            continue
        if ocr_bbox:
            added, labels = False, ""
            for e3 in ocr_bbox:
                if added:
                    break
                b3 = e3["bbox"]
                if inside(b3, b1):              # OCR 在图标内 → 合并文字
                    labels += (e3.get("content") or "") + " "
                    if e3 in filtered:
                        filtered.remove(e3)
                elif inside(b1, b3):            # 图标在 OCR 内 → 丢图标框
                    added = True
            if not added:
                filtered.append({
                    "type": "icon", "bbox": b1, "interactivity": True,
                    "content": labels.strip() or None,
                    "source": "box_yolo_content_ocr" if labels else "box_yolo_content_yolo",
                })
        else:
            filtered.append(e1)
    return filtered
