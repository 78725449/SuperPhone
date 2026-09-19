r"""从 data/pages/ 的【同页多帧】生成【带 stability 的页面资产】—— 链路真正闭环。

★★ 为什么这一步才是关键（2026-09-19）：
   前面所有环节（检测/元素表/命名/聚类/分层）都做完了，但【页面资产】一直做不实 ✗——
   因为缺"同页多帧"，stability（元素出现比例）的分母是 1，没有意义。
   现在 data/pages/抖音-首页/ 有 8 帧【自证通过】的同页帧 ✓ → stability 终于有意义 ✓

★ 流程：8 帧 → 每帧跑完整管线（YOLO + OCR + 去重叠 + 分层）→ 帧间元素对齐 → 聚合
   ★ 产出每个元素的 stability（在几帧里出现）—— 这是"这个元素在这个页面上稳不稳"的证据
   · stability 高 → 页面的稳定结构 → 技能卡可放心引用 ✓
   · stability 低 → 内容（换视频就变）→ 不该进页面签名 ✗

★ 对齐判据沿用 build-layout-assets 的思路，但阈值按本批数据实测定（不猜）。
"""
import glob
import json
import os
import re
import sys
from collections import Counter, defaultdict

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ultralytics import YOLO   # noqa: E402
from rapidocr_onnxruntime import RapidOCR   # noqa: E402

ROOT = r"D:\编程项目\SuperPhone"
WEIGHTS = os.path.join(ROOT, "_research", "OmniParser", "weights", "icon_detect", "model.pt")
PAGES = os.path.join(ROOT, "data", "pages")
OUT = os.path.join(ROOT, "data", "page-assets")
STATUS_Y = 0.035
ALIGN_DIST = 0.06      # 元素对齐：中心距离上限（★ 实测定：8 帧同页，位置应有小抖动）


def imread_u(p):
    return cv2.imdecode(np.fromfile(p, dtype=np.uint8), cv2.IMREAD_COLOR)


def norm(s):
    return re.sub(r"\s+", "", s or "")


model = YOLO(WEIGHTS)
ocr_engine = RapidOCR()


def elements_of(img):
    """一帧 → 元素列表（YOLO + OCR，像素坐标；不做合并，保留最大信息）。"""
    H, W = img.shape[:2]
    r = model.predict(img, conf=0.15, verbose=False)[0]
    out = []
    for b in r.boxes:
        x1, y1, x2, y2 = [float(v) for v in b.xyxy[0]]
        out.append({"type": "icon", "bbox": [x1, y1, x2 - x1, y2 - y1],
                    "cx": (x1 + x2) / 2 / W, "cy": (y1 + y2) / 2 / H,
                    "content": ""})
    res, _ = ocr_engine(img)
    for it in (res or []):
        pts, txt = it[0], it[1]
        xs = [float(q[0]) for q in pts]
        ys = [float(q[1]) for q in pts]
        x1, y1 = min(xs), min(ys)
        w, h = max(xs) - x1, max(ys) - y1
        if (y1 + h / 2) / H < STATUS_Y:          # ★ 状态栏不入（二期就确认过是噪声）
            continue
        out.append({"type": "text", "bbox": [x1, y1, w, h],
                    "cx": (x1 + w / 2) / W, "cy": (y1 + h / 2) / H,
                    "content": norm(txt)})
    return out, W, H


print("=" * 96)
print("  同页多帧 → 页面资产（带 stability）")
print("=" * 96)
os.makedirs(OUT, exist_ok=True)

for d in sorted(os.listdir(PAGES)):
    dp = os.path.join(PAGES, d)
    if not os.path.isdir(dp):
        continue
    shots = sorted(glob.glob(os.path.join(dp, "screenshot_*.png")),
                   key=lambda p: int(re.search(r"screenshot_(\d+)\.", p).group(1)))
    if len(shots) < 3:
        print("\n  【%s】只有 %d 帧，跳过（stability 无从谈起）" % (d, len(shots)))
        continue
    ocf = os.path.join(dp, "ocr.json")
    exp = json.load(open(ocf, encoding="utf-8")).get("expect") if os.path.exists(ocf) else None

    print()
    print("─" * 96)
    print("  【%s】%d 帧 · 自证特征 %s" % (d, len(shots), exp))
    print("─" * 96)

    frames = []
    for p in shots:
        im = imread_u(p)
        if im is None:
            continue
        els, W, H = elements_of(im)
        frames.append({"file": os.path.basename(p), "elems": els, "W": W, "H": H,
                       "texts": set(e["content"] for e in els if e["content"])})
    n = len(frames)
    print("  每帧元素数：%s" % [len(f["elems"]) for f in frames])

    # 帧间文字重合（印证"确实是同页"）
    js = [len(frames[i]["texts"] & frames[j]["texts"]) /
          max(1, len(frames[i]["texts"] | frames[j]["texts"]))
          for i in range(n) for j in range(i + 1, n)]
    print("  帧间文字 Jaccard：中位 %.2f（★ 同页应偏高）" % float(np.median(js)))

    # ── 元素对齐：同类型 + 位置近 → 视为同一元素
    groups = []
    for fi, fr in enumerate(frames):
        for e in fr["elems"]:
            hit = None
            for g in groups:
                g0 = g[0]
                if g0["type"] != e["type"]:
                    continue
                # 文字类：内容必须一致；图标类：只看位置
                if e["type"] == "text" and g0["content"] and e["content"] and \
                        g0["content"] != e["content"]:
                    continue
                if np.hypot(g0["cx"] - e["cx"], g0["cy"] - e["cy"]) <= ALIGN_DIST:
                    hit = g
                    break
            if hit is None:
                groups.append([dict(e, _f=fr["file"])])
            else:
                hit.append(dict(e, _f=fr["file"]))

    kept = []
    for g in groups:
        seen = len(set(x["_f"] for x in g))
        # 取出现最多帧的那个内容（内容可能因 OCR 抖动略有差异）
        cnt = Counter(x["content"] for x in g if x["content"])
        content = cnt.most_common(1)[0][0] if cnt else None
        kept.append({"type": g[0]["type"], "content": content,
                     "cx": round(float(np.mean([x["cx"] for x in g])), 4),
                     "cy": round(float(np.mean([x["cy"] for x in g])), 4),
                     "stability": round(seen / n, 2), "seen": "%d/%d" % (seen, n)})
    kept.sort(key=lambda x: (-x["stability"], x["cy"], x["cx"]))

    stable = [e for e in kept if e["stability"] >= 0.8]
    mid = [e for e in kept if 0.3 <= e["stability"] < 0.8]
    low = [e for e in kept if e["stability"] < 0.3]
    print("  对齐去重：%d 个候选元素 → ★ 稳定(≥0.8) %d · 中等(0.3~0.8) %d · 不稳定(<0.3) %d"
          % (len(kept), len(stable), len(mid), len(low)))
    print()
    print("  ★ 稳定元素（≥80%% 的帧都出现）—— 这是页面的【稳定结构】：")
    for e in stable[:14]:
        print("     %-6s %-22s @(%.3f,%.3f)  %s"
              % (e["type"], (e["content"] or "(纯图标)")[:22], e["cx"], e["cy"], e["seen"]))
    if mid:
        print()
        print("  ⚠️ 中等（0.3~0.8）—— 可能是慢变内容（如滚动的列表项）：")
        for e in mid[:6]:
            print("     %-6s %-22s %s" % (e["type"], (e["content"] or "(纯图标)")[:22], e["seen"]))
    if low:
        print()
        print("  ✗ 不稳定（<30%%）—— ★ 这是【内容】，不该进页面签名：")
        for e in low[:8]:
            print("     %-6s %-22s %s" % (e["type"], (e["content"] or "(纯图标)")[:22], e["seen"]))

    with open(os.path.join(OUT, "%s.json" % d), "w", encoding="utf-8") as fh:
        json.dump({"page": d, "frames": n, "expect": exp,
                   "stable": stable, "medium": mid, "unstable": low,
                   "all": kept}, fh, ensure_ascii=False, indent=2)

print()
print("=" * 96)
print("  结论")
print("=" * 96)
print("  ★ stability 高的元素 = 这个页面的【可依赖结构】→ 技能卡可放心引用 ✓")
print("  ★ stability 低的 = 内容 → 明确排除在页面签名之外 ✓")
print("  → ★ 这就是【页面资产】该有的形态，而它【只有靠同页多帧才算得出来】✓")
print("  落盘：%s" % OUT)
