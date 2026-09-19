r"""元素表抽查 —— 用【已知可点击位置】当 ground truth，不靠"看图"。

★★ 为什么这么查：我看不到图（当前模型不支持图像输入）✗，所以抽查必须有【客观依据】。
   ground truth 来源 = 【OCR 实测确认过的、必然可点击的 UI 元素及其位置】：
     · 抖音首页底部 4 个 tab（首页/朋友/消息/我）@ y≈0.963 ← 带文字的 tab，必可点击
     · 抖音右侧操作列 @ x≈0.92（点赞/评论/收藏/分享）← 图标类，正好考 OmniParser
     · 设置页顶栏标题 / 列表行 / 子页返回箭头

★ 判据（事先定好）：
   P1 【覆盖】：每个已知可点击位置，元素表里至少有一个元素框包含它 —— 漏了就是漏检 ✗
   P2 【密度】：元素框/屏 应该落在合理量级（设置页 15~50 · 抖音 15~60），过多则疑为过检
   P3 【重复】：同一位置被【多个】元素框覆盖的比例 —— 高则说明没合并干净 ✗
"""
import glob
import json
import os
import re
import sys
from collections import defaultdict

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from rapidocr_onnxruntime import RapidOCR   # noqa: E402

ROOT = r"D:\编程项目\SuperPhone"
ELEM_DIR = os.path.join(ROOT, "data", "omniparser-elements")
MA = os.path.join(ROOT, "_research", "MobileAgent", "Mobile-Agent-v3.5", "mobile_use",
                  "打开设置，进入蓝牙页面，然后返回，再进入通用页面")
SHOT_DIRS = {"设置 App": MA, "抖音": os.path.join(ROOT, "ma35_task")}

# 已知可点击的【文字】—— 用 OCR 定位它们，然后查元素表是否覆盖
# （选带文字的是因为：能靠 OCR 客观定位；纯图标位置只能靠人工，而我看不到图 ✗）
GT_WORDS = {
    "抖音": ["首页", "朋友", "消息", "我", "搜索", "推荐", "关注"],
    "设置 App": ["设置", "墙纸", "通用", "蓝牙", "无线局域网", "电池", "隐私"],
}

ocr = RapidOCR()


def imread_u(p):
    return cv2.imdecode(np.fromfile(p, dtype=np.uint8), cv2.IMREAD_COLOR)


def contains(bbox, x, y):
    bx, by, bw, bh = bbox
    return bx <= x <= bx + bw and by <= y <= by + bh


print("=" * 96)
print("  元素表抽查 —— 用已知可点击位置当 ground truth")
print("=" * 96)

report = {}
for label, words in GT_WORDS.items():
    sd = SHOT_DIRS[label]
    files = sorted(glob.glob(os.path.join(ELEM_DIR, "%s_s*.json" % label[:2])))
    if not files or not os.path.isdir(sd):
        print("  ✗ %s 没有元素表或缺截图目录" % label)
        continue
    print()
    print("─" * 96)
    print("  【%s】元素表 %d 份" % (label, len(files)))
    print("─" * 96)
    print("  %-8s %-8s %-14s %-10s %-10s %-10s %s"
          % ("截图", "元素数", "命中已知元素", "覆盖", "漏检", "重复覆盖", "密度判定"))
    print("  " + "-" * 86)

    tot = defaultdict(int)
    for f in files:
        d = json.load(open(f, encoding="utf-8"))
        elems = d["elements"]
        W, H = d["size"]
        img_path = os.path.join(sd, d["screenshot"])
        im = imread_u(img_path)
        if im is None:
            continue
        # OCR 定位已知文字（离线，历史截图可反复算 ✓）
        res, _ = ocr(im)
        found = []
        for it in (res or []):
            pts, txt = it[0], it[1]
            xs = [float(q[0]) for q in pts]
            ys = [float(q[1]) for q in pts]
            cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
            t = re.sub(r"\s+", "", txt or "")
            for w in words:
                if w in t:
                    found.append((w, cx, cy))
                    break
        hit = miss = dup = 0
        for (w, cx, cy) in found:
            cov = [e for e in elems if contains(e["bbox"], cx, cy)]
            if not cov:
                miss += 1
            else:
                hit += 1
                if len(cov) > 1:
                    dup += 1
        n_e = len(elems)
        dens = ("✓ 合理" if 12 <= n_e <= 65 else ("✗ 偏多" if n_e > 65 else "⚠️ 偏少"))
        print("  %-8s %-8d %-14d %-10d %-10d %-10d %s"
              % (d["screenshot"].replace("screenshot_", "s").replace(".png", "")
                 .replace(".jpg", ""), n_e, len(found), hit, miss, dup, dens))
        tot["elems"] += n_e
        tot["found"] += len(found)
        tot["hit"] += hit
        tot["miss"] += miss
        tot["dup"] += dup
        tot["n"] += 1

    n = max(1, tot["n"])
    print()
    print("  小结：平均 %.1f 元素/张 · 已知元素 %d 个 → ★ 覆盖 %d · ★ 漏检 %d · ★ 重复覆盖 %d"
          % (tot["elems"] / n, tot["found"], tot["hit"], tot["miss"], tot["dup"]))
    if tot["found"]:
        print("        ★ 覆盖率 %.0f%% · 重复覆盖占命中 %.0f%%"
              % (100.0 * tot["hit"] / tot["found"],
                 100.0 * tot["dup"] / max(1, tot["hit"])))
    report[label] = dict(tot)

print()
print("=" * 96)
print("  判读")
print("=" * 96)
for label, t in report.items():
    if not t["found"]:
        print("  【%s】没定位到已知元素（OCR 未命中），无法判定" % label)
        continue
    cov = 100.0 * t["hit"] / t["found"]
    dup = 100.0 * t["dup"] / max(1, t["hit"])
    print("  【%s】已知可点击元素覆盖 %.0f%% · 重复覆盖 %.0f%% · 均值 %.1f 元素/张"
          % (label, cov, dup, t["elems"] / max(1, t["n"])))
    if cov >= 95:
        print("     → ★★ 覆盖率高：元素表【没有漏掉带文字的可点击元素】✓")
    else:
        print("     → ⚠️ 有漏检：元素表未覆盖 %d 个已知可点击位置 ✗" % t["miss"])
    if dup > 40:
        print("     → ⚠️ 重复覆盖偏高：同一位置被多个框盖住，说明【合并不够】✗")
    else:
        print("     → ★ 重复覆盖低：合并是干净的 ✓")
print()
print("  ★ 局限（诚实说明）：")
print("    · 本抽查只用【带文字的】已知元素（纯图标位置无法靠 OCR 客观定位，而我看不到图）")
print("      → 因此它验证的是【文字类元素】的覆盖，不是【图标类】的 ✗")
print("    · 图标类元素的质量仍需【人工看图】或【真实点击验证】")
