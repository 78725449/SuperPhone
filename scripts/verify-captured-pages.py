r"""自证采集到的帧：8 帧到底是不是同一页？页面名标对了吗？

★★ 为什么必须自证（2026-09-19）：页面名是我给的 ✗ —— 而我犯过"把朋友页标成首页"的错 ✗。
   我看不到图，只能靠文字自证。判据很硬：
     · 同一页的 8 帧 → 文字集合【高度重合】(两两 Jaccard 高) ✓
     · 若某页的两两 Jaccard 很低 → ★ 那 8 帧不是同一页（页面在变 / 或采到了别的页）✗

★ 顺带回答两件事：
   ① 「设置-子页-允许"微博"」到底是什么（是不是弹窗）
   ② 「抖音-首页」是首页还是登录页
"""
import glob
import json
import os
import re
import sys
from collections import Counter

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from rapidocr_onnxruntime import RapidOCR   # noqa: E402

ROOT = r"D:\编程项目\SuperPhone"
PAGES = os.path.join(ROOT, "data", "pages")
NOISE_Y = 0.035


def imread_u(p):
    return cv2.imdecode(np.fromfile(p, dtype=np.uint8), cv2.IMREAD_COLOR)


def norm(s):
    return re.sub(r"\s+", "", s or "")


ocr = RapidOCR()

print("=" * 96)
print("  自证：8 帧是不是同一页 · 页面名标对了吗")
print("=" * 96)

for d in sorted(os.listdir(PAGES)):
    dirp = os.path.join(PAGES, d)
    if not os.path.isdir(dirp):
        continue
    shots = sorted(glob.glob(os.path.join(dirp, "screenshot_*.png")),
                   key=lambda p: int(re.search(r"screenshot_(\d+)\.", p).group(1)))
    if not shots:
        print("\n  【%s】0 帧（空目录，应清理）" % d)
        continue
    sigs, W0, H0 = [], None, None
    for p in shots:
        im = imread_u(p)
        if im is None:
            continue
        H0, W0 = im.shape[:2]
        res, _ = ocr(im)
        s = set()
        for it in (res or []):
            pts, txt = it[0], it[1]
            ys = [float(q[1]) for q in pts]
            if min(ys) / H0 < NOISE_Y:      # 去状态栏
                continue
            k = norm(txt)
            if len(k) >= 2:
                s.add(k)
        sigs.append(s)

    print()
    print("─" * 96)
    print("  【%s】%d 帧 · 每帧文字数 %s" % (d, len(sigs), [len(s) for s in sigs]))
    # 两两 Jaccard
    vals = []
    for i in range(len(sigs)):
        for j in range(i + 1, len(sigs)):
            a, b = sigs[i], sigs[j]
            vals.append(len(a & b) / max(1, len(a | b)))
    med = float(np.median(vals)) if vals else 0.0
    print("     两两 Jaccard：min %.2f · 中位 %.2f · max %.2f" % (min(vals), med, max(vals)))
    if med >= 0.5:
        print("     ★★ 中位 ≥ 0.5 → ★ 这 %d 帧【确实是同一页】✓" % len(sigs))
    elif med >= 0.3:
        print("     ⚠️ 中位 %.2f → 大体同页，但有波动（OCR 抖动 / 页面轻微变化）" % med)
    else:
        print("     ✗ 中位 %.2f → ★ 这 %d 帧【不是同一页】✗（页面在变）" % (med, len(sigs)))
    # 全页共有的文字（稳定内容）
    common = set.intersection(*sigs) if sigs else set()
    print("     ★ 8 帧都出现的文字（%d 个）：%s" % (len(common), " · ".join(sorted(common)[:14])))
    # 只在少数帧出现的（不稳定 / 内容变化）
    cnt = Counter()
    for s in sigs:
        for x in s:
            cnt[x] += 1
    unstable = [k for k, v in cnt.items() if v <= len(sigs) // 3]
    if unstable:
        print("     ⚠️ 只在少数帧出现的文字（%d 个）：%s"
              % (len(unstable), " · ".join(x[:10] for x in unstable[:12])))

print()
print("=" * 96)
print("  判读")
print("=" * 96)
print("  ★ 中位 Jaccard 高的页 → 可用于建立页面资产（stability 才有意义）")
print("  ★ 中位低的页 → 采集时页面在变，需重采或改采集方式")
print("  ★ 「8 帧都出现」的文字 = 这个页面的【稳定特征】→ 正是页面签名该用的 ✓")
print("  ★ 「只在少数帧出现」的文字 = 内容（如视频标题/滚动到的条目）→ 不该当签名 ✗")
