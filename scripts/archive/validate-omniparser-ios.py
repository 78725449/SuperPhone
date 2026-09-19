r"""验证 OmniParser 的 icon_detect 在【我们真实的 iOS 截图】上到底行不行。

★ 为什么必须实测：它训练数据是【67K 网页截图 + DOM bbox】✗，论文只说"ID 模型能很好泛化到移动端"，
  但那是 Android/通用移动端 —— ★ 我们的 iPhone 6s / iOS 15 截图是否适用，【必须自己验】。

★ 数据集（现成，全来自真实执行，无人工标注）：
  _research/MobileAgent/Mobile-Agent-v3.5/mobile_use/<指令>/
    screenshot_0..11.png     —— GUI-Owl 执行时的 12 帧
  data/ma-trace/run.log      —— 每步的意图 + 点击坐标（ground truth！）

★ 判据（★ 事先定好，避免事后找理由）：
  J1 框数量：合理 5~40 个。太多（>80）= 碎成噪点 ✗；太少（<3）= 漏检 ✗
  J2 框尺寸：中位数面积应在 0.3%~8% 屏面积（UI 元素量级）✗ 若中位数 <0.1% = 只框住了字
  J3 ★ 关键：它检出的框，有没有【独立于文字】的（即不含任何 OCR 文字块）→ 那是图标 ✓
  J4 ★★ 决定性：STEP 0 的点击点 (80,88) 是【已被验证可点】的（点完界面确实跳转了）——
        它有没有覆盖这个点的框？
  J5 与我们 OpenCV 反推结果 (58,68,68,33) 的关系（IoU / 包含）
"""
import glob
import json
import os
import re
import sys

import cv2
import numpy as np

ROOT = r"D:\编程项目\SuperPhone"
WEIGHTS = os.path.join(ROOT, "_research", "OmniParser", "weights", "icon_detect", "model.pt")
MA_DIR = os.path.join(ROOT, "_research", "MobileAgent", "Mobile-Agent-v3.5", "mobile_use")
TASK = "打开设置，进入蓝牙页面，然后返回，再进入通用页面"
LOG = os.path.join(ROOT, "data", "ma-trace", "run.log")
NOISE_Y_MAX = 0.035


def imread_u(p):
    """★ cv2.imread 不支持非 ASCII 路径（本项目路径含中文）→ 用 imdecode。"""
    return cv2.imdecode(np.fromfile(p, dtype=np.uint8), cv2.IMREAD_COLOR)


def read_log():
    """★ PowerShell Tee-Object 默认写 UTF-16LE → 先探测编码再读。"""
    raw = open(LOG, "rb").read()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16")
    if raw[:400].count(b"\x00") > 40:
        return raw.decode("utf-16-le", errors="replace")
    return raw.decode("utf-8", errors="replace")


def parse_clicks(text):
    """从 run.log 抽 (step, action, coord0-999)。"""
    out = {}
    blocks = re.split(r"={10,}\s*\nSTEP\s+(\d+)\s*\n={10,}", text)
    for i in range(1, len(blocks) - 1, 2):
        sid, body = int(blocks[i]), blocks[i + 1]
        mt = re.search(r"<tool_call>\s*(.*?)\s*</tool_call>", body, re.S)
        if not mt:
            continue
        try:
            j = json.loads(mt.group(1))
            arg = j.get("arguments") or {}
            c = arg.get("coordinate")
            if c and len(c) == 2:
                out[sid] = {"action": arg.get("action"), "coord": c}
        except Exception:
            pass
    return out


def iou(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    x1, y1 = max(ax, bx), max(ay, by)
    x2, y2 = min(ax + aw, bx + bw), min(ay + ah, by + bh)
    if x2 <= x1 or y2 <= y1:
        return 0.0
    inter = (x2 - x1) * (y2 - y1)
    return inter / float(aw * ah + bw * bh - inter)


if not os.path.exists(WEIGHTS):
    print("✗ 权重不在: %s" % WEIGHTS)
    print("  先跑: python scripts/fetch-omniparser-weights.py")
    sys.exit(1)

from ultralytics import YOLO   # noqa: E402

print("=" * 96)
print("  OmniParser icon_detect 在【真实 iOS 截图】上的实测")
print("=" * 96)
model = YOLO(WEIGHTS)
names = getattr(model, "names", None)
print("  权重      : %s" % WEIGHTS)
print("  类别      : %s" % names)
print()

tdir = os.path.join(MA_DIR, TASK)
shots = sorted(glob.glob(os.path.join(tdir, "screenshot_*.png")) +
               glob.glob(os.path.join(tdir, "screenshot_*.jpg")),
               key=lambda p: int(re.search(r"screenshot_(\d+)\.", p).group(1)))
clicks = parse_clicks(read_log())
print("  截图 %d 张 · 日志里解析到 %d 个动作" % (len(shots), len(clicks)))
print()

# OCR（设备端文字）用来判 J3：哪些框不含文字 → 图标
def gw(cap, params=None, tmo=30000):
    import ssl
    import urllib.request
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    rq = urllib.request.Request(
        "https://127.0.0.1:8080/api/devices/553A6EA8-29F1-43DB-94B4-D4E01D4204DC/invoke",
        data=json.dumps({"cap": cap, "params": params or {}, "timeout": tmo}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(rq, timeout=60, context=ctx) as r:
        return json.load(r)["ack"]


rows = []
for p in shots:
    sid = int(re.search(r"screenshot_(\d+)\.", p).group(1))
    im = imread_u(p)
    H, W = im.shape[:2]
    r = model.predict(im, conf=0.15, verbose=False)[0]
    boxes = []
    for b in r.boxes:
        x1, y1, x2, y2 = [float(v) for v in b.xyxy[0]]
        boxes.append((x1, y1, x2 - x1, y2 - y1, float(b.conf[0])))
    areas = [100.0 * w * h / (W * H) for (_, _, w, h, _) in boxes]
    med = float(np.median(areas)) if areas else 0.0
    rows.append({"step": sid, "n": len(boxes), "med": med,
                 "boxes": boxes, "W": W, "H": H,
                 "click": clicks.get(sid)})

print("  %-6s %-6s %-12s %-14s %s" % ("截图", "框数", "中位面积%", "AI 点(像素)", "该点被框覆盖吗"))
print("  " + "-" * 92)
for row in rows:
    ck = ""
    cov = "—"
    if row["click"]:
        cx = row["click"]["coord"][0] / 999.0 * row["W"]
        cy = row["click"]["coord"][1] / 999.0 * row["H"]
        ck = "(%d, %d)" % (cx, cy)
        hit = [b for b in row["boxes"] if b[0] <= cx <= b[0] + b[2] and b[1] <= cy <= b[1] + b[3]]
        cov = ("✓ 覆盖（框面积 %.2f%% conf %.2f）" % (100.0 * hit[0][2] * hit[0][3] / (row["W"] * row["H"]), hit[0][4])
               if hit else "✗ 未被任何框覆盖")
    print("  %-6d %-6d %-12.3f %-14s %s" % (row["step"], row["n"], row["med"], ck, cov))

print()
print("=" * 96)
print("  判据汇总")
print("=" * 96)
ns = [r["n"] for r in rows]
meds = [r["med"] for r in rows]
print("  J1 框数量      : min %d · max %d · 均值 %.1f  → %s"
      % (min(ns), max(ns), sum(ns) / len(ns),
         "✓ 合理(5~40)" if 5 <= sum(ns) / len(ns) <= 40 else
         ("✗ 太少=漏检" if sum(ns) / len(ns) < 5 else "✗ 太多=碎")))
print("  J2 中位面积    : min %.3f%% · max %.3f%%  → %s"
      % (min(meds), max(meds),
         "✓ UI 元素量级" if 0.3 <= float(np.median(meds)) <= 8 else
         ("✗ 太小=只框住字" if float(np.median(meds)) < 0.3 else "✗ 太大=框了整块")))

# J4：决定性判据 —— 已确认可点击的点有没有被覆盖
ck_rows = [r for r in rows if r["click"]]
cov_n = 0
for r in ck_rows:
    cx = r["click"]["coord"][0] / 999.0 * r["W"]
    cy = r["click"]["coord"][1] / 999.0 * r["H"]
    if any(b[0] <= cx <= b[0] + b[2] and b[1] <= cy <= b[1] + b[3] for b in r["boxes"]):
        cov_n += 1
print("  J4 ★★ 已确认可点击的点被覆盖 : %d/%d  %s"
      % (cov_n, len(ck_rows), "★★ 通过" if cov_n == len(ck_rows) else "⚠️ 有漏"))

# J5：与 OpenCV 反推结果 (58,68,68,33) 的关系
REF = (58, 68, 68, 33)      # 我们对 STEP 0 点击点用 OpenCV 轮廓反推出的区域
r0 = rows[0] if rows else None
if r0 and r0["boxes"]:
    best, bv = None, 0.0
    for b in r0["boxes"]:
        v = iou(REF, b[:4])
        if v > bv:
            best, bv = b, v
    print("  J5 与 OpenCV 反推 (58,68,68,33) 的最佳 IoU : %.3f  %s"
          % (bv, "✓ 吻合" if bv > 0.3 else "✗ 不吻合"))
    if best:
        print("     OmniParser 在那一带检出的框: (%d,%d,%d,%d) conf %.2f"
              % (best[0], best[1], best[2], best[3], best[4]))

print()
print("  ★ 若 J1/J2 通过而 J4 有漏 → 它整体可用但对【我们这类 iOS 元素】有偏")
print("  ★ 若 J1 是「太多=碎」 → 它把 iOS 界面切太碎，需自己微调")
