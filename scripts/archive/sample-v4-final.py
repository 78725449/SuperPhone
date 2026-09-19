r"""采样 v4（最终版）—— 结构判据 + 安全清障 + 穷举返回。

★★ 三轮踩坑后的定版（2026-09-19）：
   v1 ✗ 弹窗盖住 tab → 5 个操作全失败（但验证机制拦住了假样本 ✓）
   v2 ✗ 词判据放单字「我」→ 在帮助页误报"已在首页"✗
   v3 ✗ 清弹窗后落进客服页，home+重开【没能】回首页 ✗
   v4 ✓ 三个修正合起来：
     ① ★ 结构判据（底部导航带 y>0.93 ≥3 块）—— 与文字无关，不受通用词/单字/OCR 抖动影响
     ② ★ 安全词优先清障（不允许/取消/关闭…），绝不点未知按钮
     ③ ★ 穷举返回手段（左上返回 → 角落 X → 左缘右滑 → home+重开 → 盲点 tab）
        —— 实测【左上角的 X】是关键手段（客服页那个 X 在 (0.075,0.063)）

★ 采样判据（关键改动）：★ 从「等 hashDiff」换成「结构状态比较」
   · hashDiff 时序敏感（变化发生在等待之前就错过）✗ —— 实测 tab 切换就踩这个
   · 结构比较是【点前 vs 点后】两个状态对比，不依赖"恰好捕获到变化"✓
"""
import base64
import json
import os
import ssl
import time
import urllib.request

import cv2
import numpy as np

ROOT = r"D:\编程项目\SuperPhone"
DEV = "553A6EA8-29F1-43DB-94B4-D4E01D4204DC"
GW = "https://127.0.0.1:8080"
OUT = os.path.join(ROOT, "data", "interaction-samples.jsonl")
SHOT_DIR = os.path.join(ROOT, "data", "interaction-shots")
DOUYIN = "com.ss.iphone.ugc.Aweme"
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
SAFE_FIRST = ["不允许", "取消", "关闭", "稍后", "以后再说", "不再提示", "我知道了", "跳过"]


def gw(cap, params=None, tmo=30000, wait=90):
    rq = urllib.request.Request(
        "%s/api/devices/%s/invoke" % (GW, DEV),
        data=json.dumps({"cap": cap, "params": params or {}, "timeout": tmo}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(rq, timeout=wait, context=ctx) as r:
        return json.load(r)["ack"]


def texts():
    return [t for t in gw("vision.ocr").get("texts", []) if t.get("y", 1) >= 0.035]


def blob():
    return "".join((t.get("text", "") or "").replace(" ", "") for t in texts())


def nav_blocks():
    return sum(1 for t in texts() if t.get("cy", 0) > 0.93)


def mid_blocks():
    return sum(1 for t in texts() if 0.15 <= t.get("cy", 0) <= 0.90)


def at_content_page():
    n = nav_blocks()
    return n >= 3, n


def tap(x, y, settle=2.0):
    gw("script.exec", {"steps": [{"op": "tap", "x": x, "y": y}]}, tmo=60000)
    time.sleep(settle)


def find_safe():
    ts = texts()
    for w in SAFE_FIRST:
        for t in ts:
            if (t.get("text") or "").strip() == w:
                return t, w
    return None, None


def find_corner_x():
    for t in texts():
        if (t.get("text") or "").strip() in ("X", "×", "✕", "关闭"):
            return t
    return None


def ensure_home(max_rounds=8):
    """★ 穷举返回手段直到结构判据通过。"""
    for rnd in range(max_rounds):
        ok, n = at_content_page()
        if ok:
            return True, rnd, n
        t, w = find_safe()
        if t:
            tap(t["cx"], t["cy"], 1.6)
            continue
        x = find_corner_x()
        if x:
            tap(x["cx"], x["cy"], 1.8)
            continue
        tap(0.05, 0.063, 1.8)                      # 左上返回
        if at_content_page()[0]:
            continue
        gw("script.exec", {"steps": [{"op": "swipe", "x1": 0.02, "y1": 0.5,
                                      "x2": 0.75, "y2": 0.5, "duration": 0.35}]}, tmo=60000)
        time.sleep(2)
        if at_content_page()[0]:
            continue
        gw("script.exec", {"steps": [{"op": "home"}]}, tmo=60000)
        time.sleep(2.5)
        gw("script.exec", {"steps": [{"op": "open", "bundleId": DOUYIN}]}, tmo=60000)
        time.sleep(6)
    ok, n = at_content_page()
    return ok, max_rounds, n


def shot_b64():
    return gw("screenshot").get("image")


def decode(b64):
    return cv2.imdecode(np.frombuffer(base64.b64decode(b64), dtype=np.uint8), cv2.IMREAD_COLOR)


def reverse_region(img, px, py):
    H, W = img.shape[:2]
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    edges = cv2.dilate(cv2.Canny(gray, 40, 120), np.ones((3, 3), np.uint8), 1)
    cont, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    best = None
    for c in cont:
        x, y, w, h = cv2.boundingRect(c)
        if not (x <= px <= x + w and y <= py <= y + h):
            continue
        ar = (w * h) / float(W * H)
        if not (0.002 <= ar <= 0.25) or w < 20 or h < 20:
            continue
        if best is None or w * h < best[2] * best[3]:
            best = (x, y, w, h)
    if best is None:
        w, h = int(W * 0.12), int(H * 0.06)
        return [max(0, px - w // 2), max(0, py - h // 2), w, h], "fallback_window", 0.3
    x, y, w, h = best
    cx, cy = x + w / 2.0, y + h / 2.0
    d = np.hypot(px - cx, py - cy) / max(1.0, np.hypot(w / 2.0, h / 2.0))
    return [x, y, w, h], "contour", round(float(np.clip(1 - d * 0.6, 0.4, 0.95)), 2)


print("=" * 96)
print("  采样 v4（结构判据 + 安全清障 + 穷举返回）")
print("=" * 96)
os.makedirs(SHOT_DIR, exist_ok=True)

ok, rnd, n = ensure_home()
print("\n  回首页：%s（用了 %d 轮 · 底部带 %d 块）" % ("✓" if ok else "✗", rnd, n))
print("     文字：%s" % blob()[:70])
if not ok:
    raise SystemExit(1)

print("\n  采样（判据 = 点前/点后【中部块数变化】+ 底部带仍在）")
PLAN = [("tab-1", (0.102, 0.963)), ("tab-2", (0.302, 0.963)),
        ("tab-3", (0.701, 0.963)), ("tab-4", (0.900, 0.963)),
        ("tab-1-again", (0.102, 0.963)), ("search", (0.928, 0.066))]
n_ok = n_try = 0
with open(OUT, "a", encoding="utf-8") as fh:
    for name, (nx, ny) in PLAN:
        n_try += 1
        b64 = shot_b64()
        if not b64:
            continue
        img = decode(b64)
        H, W = img.shape[:2]
        b_mid, b_nav = mid_blocks(), nav_blocks()
        px, py = int(nx * W), int(ny * H)
        tap(nx, ny, 2.4)
        a_mid, a_nav = mid_blocks(), nav_blocks()
        # ★ 判据：底部带仍在（说明没被弹窗顶掉）+ 中部块数变了（说明确实切了内容）
        if not (a_nav >= 3 and a_mid != b_mid):
            print("     ✗ %-12s 未生效（底部带 %d→%d · 中部 %d→%d）"
                  % (name, b_nav, a_nav, b_mid, a_mid))
            continue
        reg, src, conf = reverse_region(img, px, py)
        ts = time.strftime("%Y%m%d-%H%M%S")
        fn = "%s-%s.png" % (ts, name)
        with open(os.path.join(SHOT_DIR, fn), "wb") as f2:
            f2.write(base64.b64decode(b64))
        fh.write(json.dumps({"ts": ts, "name": name, "screen": fn,
                             "tap": {"x": nx, "y": ny, "px": px, "py": py},
                             "verified": "structure:nav_kept+mid_changed",
                             "beforeMid": b_mid, "afterMid": a_mid,
                             "region": reg, "regionSource": src,
                             "regionConfidence": conf, "size": [W, H]},
                            ensure_ascii=False) + "\n")
        fh.flush()
        n_ok += 1
        print("     ✓ %-12s 生效（中部 %d→%d）→ 样本已记（%dx%d %s conf %.2f）"
              % (name, b_mid, a_mid, reg[2], reg[3], src, conf))
        time.sleep(1.2)

print()
print("=" * 96)
print("  结果：%d/%d 通过验证并记为样本" % (n_ok, n_try))
print("  ★ 判据三次演进：hashDiff（时序敏感 ✗）→ 词（不具区分力 ✗）→ 结构（✓）")
print("  样本：%s" % OUT)
