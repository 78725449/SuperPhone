r"""验证：在【UI 截图】上做矩形检测，到底能不能检出【OCR 抓不到的东西】？

动机（用户 2026-09-19 提出）："布局的矩形检测最能反映页面"。
  二期卡在"动态页的结构是图标+小字，OCR 抓不到"（首页 verify 仅 2/5）。
  矩形检测理论上能抓到图标的位置 —— 但 VNDetectRectanglesRequest 是为【拍照文档】设计的，
  在 UI 截图上有没有用【未知】。故先离线验证，再决定要不要给设备端加 vision.rects。

★ 本模型不支持图像输入（看不到图），所以判据必须【数值化】：
  对每个检出的矩形，数它覆盖了几个 OCR 文字块 ——
    · 覆盖 ≥1 个文字块 → 多半只是"文字的外框"，OCR bbox 已经够了，价值低
    · ★ 覆盖 0 个文字块  → 那是【图标 / 图片 / 容器】，这才是矩形检测的独特价值
  再对照设备端已知的 UI 结构（顶部 tab / 底部 tab / 键盘）看矩形有没有落在正确的地方。
"""
import json
import os
import ssl
import urllib.request

import cv2
import numpy as np

ROOT = r"D:\编程项目\SuperPhone"
IMG = os.path.join(ROOT, "data", "_rect-test-cur.jpg")
DEV = "553A6EA8-29F1-43DB-94B4-D4E01D4204DC"
NOISE_Y_MAX = 0.035

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


def ocr_texts():
    rq = urllib.request.Request(
        "https://127.0.0.1:8080/api/devices/%s/invoke" % DEV,
        data=json.dumps({"cap": "vision.ocr", "params": {}, "timeout": 30000}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(rq, timeout=60, context=ctx) as r:
        return json.load(r)["ack"].get("texts", [])


# ★★★ 关键：截图与 OCR 必须【同一时刻】取（2026-09-19 实测踩坑）。
#   第一版先离线抓图、脚本里再重新 OCR，中间画面已变 → 两者对不上 →
#   出现"所有矩形都不覆盖任何文字"这种不可能的结果，差点被误读成"矩形检测无效"。
def screenshot_ack():
    rq = urllib.request.Request(
        "https://127.0.0.1:8080/api/devices/%s/invoke" % DEV,
        data=json.dumps({"cap": "screenshot", "params": {}, "timeout": 30000}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(rq, timeout=90, context=ctx) as r:
        return json.load(r)["ack"]


ack = screenshot_ack()
texts = [t for t in ocr_texts() if t.get("y", 1) >= NOISE_Y_MAX]

# ★ cv2.imread 在 Windows 上【不支持非 ASCII 路径】（本项目路径含中文"编程项目"）→ 会静默返回 None。
#   必须用 np.fromfile/imdecode 或 frombuffer+imdecode 绕开。
import base64 as _b64
img = cv2.imdecode(np.frombuffer(_b64.b64decode(ack["image"]), dtype=np.uint8),
                   cv2.IMREAD_COLOR)
if img is None:
    raise SystemExit("✗ 解码截图失败")
H, W = img.shape[:2]
print("=" * 96)
print("  矩形检测验证 —— 图 %dx%d（设备报 %sx%s）· 同一时刻 OCR 文字块 %d 个"
      % (W, H, ack.get("width"), ack.get("height"), len(texts)))
print("=" * 96)


def covers(r, t):
    """矩形 r=(x,y,w,h)【像素】是否覆盖文字块 t（t 的坐标是【归一化 0-1】，须换算）。

    ★★★ 踩坑记录（2026-09-19）：第一版直接拿 t["cx"]（0-1）与 r（像素）比较 →
      0-1 的值永远小于像素坐标 → 永远判"不覆盖" → 173 个矩形全被报成"零文字"，
      ★ 差点据此得出"矩形检测对 UI 无效"的错误结论。单位必须统一。
    """
    tx, ty = t["cx"] * W, t["cy"] * H
    return (r[0] <= tx <= r[0] + r[2]) and (r[1] <= ty <= r[1] + r[3])


def report(name, rects):
    """rects: list of (x,y,w,h) 像素。数值化报告：多少矩形、多少个"零文字"。"""
    rects = [r for r in rects if r[2] >= 12 and r[3] >= 12]        # 丢掉极小噪点
    if not rects:
        print("\n  【%s】检出 0 个（面积过滤后）" % name)
        return
    empty, withtext = [], []
    for r in rects:
        hit = sum(1 for t in texts if covers(r, t))
        (withtext if hit else empty).append((r, hit))
    print("\n  【%s】检出 %d 个矩形" % (name, len(rects)))
    print("     其中：★ 零文字（=图标/图片/容器的候选）%d 个 · 覆盖文字的 %d 个"
          % (len(empty), len(withtext)))
    print("     —— 最大的 8 个矩形（归一化 x,y,w,h · 覆盖文字数）——")
    for r, hit in sorted(rects and [(r, sum(1 for t in texts if covers(r, t))) for r in rects],
                         key=lambda z: -(z[0][2] * z[0][3]))[:8]:
        print("        (%5.3f,%5.3f) %5.3f×%5.3f  面积%5.1f%%  文字%2d 个  %s"
              % (r[0] / W, r[1] / H, r[2] / W, r[3] / H,
                 100.0 * r[2] * r[3] / (W * H), hit, "★零文字" if hit == 0 else ""))
    if empty:
        print("     ★ 零文字矩形的位置分布（判断它落在 UI 的哪个区）:")
        for r, _ in sorted(empty, key=lambda z: -(z[0][2] * z[0][3]))[:6]:
            cy = (r[1] + r[3] / 2) / H
            zone = "顶部区" if cy < 0.15 else "底部区" if cy > 0.85 else "中部区"
            print("        cy=%.3f %-6s  %5.3f×%5.3f" % (cy, zone, r[2] / W, r[3] / H))


gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

# 方法 1：Canny 边缘 → 轮廓 → 多边形逼近成四边形
edges = cv2.Canny(gray, 50, 150)
cont, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
r1 = []
for c in cont:
    peri = cv2.arcLength(c, True)
    ap = cv2.approxPolyDP(c, 0.02 * peri, True)
    if len(ap) == 4 and cv2.isContourConvex(ap):
        r1.append(cv2.boundingRect(ap))
report("方法1 Canny+四边形逼近", r1)

# 方法 2：自适应阈值 → 轮廓 → 外接矩形
th = cv2.adaptiveThreshold(gray, 255, cv2.ADAPTIVE_THRESH_MEAN_C,
                           cv2.THRESH_BINARY_INV, 25, 10)
cont2, _ = cv2.findContours(th, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
r2 = [cv2.boundingRect(c) for c in cont2 if cv2.contourArea(c) > 200]
report("方法2 自适应阈值+轮廓", r2)

# 方法 3：形态学梯度 → 轮廓（捕捉图标/图片这种"成片的非文字块"）
k = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 5))
grad = cv2.morphologyEx(gray, cv2.MORPH_GRADIENT, k)
_, gb = cv2.threshold(grad, 40, 255, cv2.THRESH_BINARY)
gb = cv2.morphologyEx(gb, cv2.MORPH_CLOSE, k, iterations=3)
cont3, _ = cv2.findContours(gb, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
r3 = [cv2.boundingRect(c) for c in cont3 if cv2.contourArea(c) > 2000]
report("方法3 形态学梯度+闭运算", r3)

print()
print("=" * 96)
print("  对照：设备端已知的 UI 结构（来自实测）")
print("=" * 96)
print("  · 顶部标签栏   y≈0.063（直播/团购/南京/关注/商城/推荐）")
print("  · 内容区       y≈0.15~0.92")
print("  · 底部导航栏   y≈0.963（首页/朋友/消息/我 —— 图标+小字，OCR 时有时无）")
print("  ★ 判据：若某方法能在 y≈0.96 处检出矩形，说明它抓到了 OCR 抓不到的底部 tab")
