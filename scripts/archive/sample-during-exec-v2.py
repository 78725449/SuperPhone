r"""执行时采样器 v2 —— ★ 先清弹窗、再回确定起点、然后才采样。

★★ v1 的阻塞（2026-09-19 实测）：
   5 个确定性操作【全部未通过验证】✗ —— 因为一个抖音红包弹窗盖住了底部 tab，
   点 tab 坐标实际点在弹窗上。★ 而验证机制拦住了它们（没记成假样本 ✓）。
   处置链实测确立后（见 scripts/popup-handling-chain.py），本版把链【接进流程】：
     ① 先清弹窗（四级链，末级诚实兜底）
     ② 再回【确定起点】（★ 因为第 3 级 home+重开会丢页面位置）
     ③ 然后才开始采样

★ 采样纪律（保持不变）：
   · 只记【被 expect 验证过】的交互（"成功"必须是被验证的，不是自称的）
   · 每次采样前重取截图（避免用过期帧反推区域）
"""
import base64
import json
import os
import ssl
import sys
import time
import urllib.request

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

ROOT = r"D:\编程项目\SuperPhone"
DEV = "553A6EA8-29F1-43DB-94B4-D4E01D4204DC"
GW = "https://127.0.0.1:8080"
OUT = os.path.join(ROOT, "data", "interaction-samples.jsonl")
SHOT_DIR = os.path.join(ROOT, "data", "interaction-shots")
DOUYIN = "com.ss.iphone.ugc.Aweme"
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


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


# ── ① 清弹窗（四级链，实测确立）────────────────────────────────────────
POPUP_MARKERS = ["恭喜获得老友回归红包", "老友专属", "可微信提现", "开启通知", "不再提示", "以后再说"]
CLOSE_WORDS = ["取消", "关闭", "稍后", "以后再说", "不再提示", "我知道了", "跳过", "×"]


def popup_present():
    b = blob()
    return [m for m in POPUP_MARKERS if m in b]


def clear_popup(max_rounds=3):
    """★ 四级链：常见关闭词 → 点卡片外 → home+重开 → 诚实放弃。"""
    for rnd in range(max_rounds):
        hits = popup_present()
        if not hits:
            return True, "无弹窗"
        print("     弹窗标记命中: %s" % hits[:3])
        # 第 1 级
        w = None
        for t in texts():
            s = (t.get("text") or "").strip()
            if any(c in s for c in CLOSE_WORDS):
                w = t
                break
        if w:
            print("     [1级] 点关闭词「%s」" % w["text"])
            gw("script.exec", {"steps": [{"op": "tap", "x": w["cx"], "y": w["cy"]},
                                         {"op": "wait_for", "expect": {"hashDiff": True},
                                          "timeoutMs": 3000}]}, tmo=60000)
            time.sleep(1.5)
            if not popup_present():
                return True, "1级"
        else:
            print("     [1级] ★ 无常见关闭词（末级才会用到第3级）")
        # 第 2 级
        print("     [2级] 点卡片外 (0.5, 0.12)")
        gw("script.exec", {"steps": [{"op": "tap", "x": 0.5, "y": 0.12}]}, tmo=60000)
        time.sleep(1.5)
        if not popup_present():
            return True, "2级"
        # 第 3 级
        print("     [3级] home + 重开 App（★ 会丢页面位置，故之后必须重置起点）")
        gw("script.exec", {"steps": [{"op": "home"}]}, tmo=60000)
        time.sleep(2.5)
        gw("script.exec", {"steps": [{"op": "open", "bundleId": DOUYIN}]}, tmo=60000)
        time.sleep(4.5)
        if not popup_present():
            return True, "3级"
    return False, "4级:需人工"


# ── ② 回确定起点：抖音首页 ────────────────────────────────────────────
# ★★ 自证判据的两条纪律（都是实测换来的）：
#   ① 不能用【通用词】（"设置"在很多页面都有 → v1 误通过）
#   ② 也不能用【单个 OCR 易错词】—— 实测"消息"会被识别成"肉息"、或干脆认不出 ✗
#   → 改用【多词多数表决】：底部 4 个 tab 词里命中 ≥2 个即判定 ✓
#      （"首页"稳、"我"单字不会错、"精选"稳 → 三个里任意两个都够）
TAB_WORDS = ["首页", "精选", "朋友", "消息", "我"]


def at_home():
    b = blob()
    n = sum(1 for w in TAB_WORDS if w in b)
    return n >= 2, b, n


def goto_start():
    for attempt in range(3):
        gw("script.exec", {"steps": [{"op": "tap", "x": 0.102, "y": 0.963},
                                     {"op": "wait_for", "expect": {"hashDiff": True},
                                      "timeoutMs": 4000}]}, tmo=60000)
        time.sleep(2)
        ok, b, n = at_home()
        if ok:
            print("     起点自证通过（底部 tab 词命中 %d/5）" % n)
            return True
        print("     起点自证未过（命中 %d/5 · %s），重试" % (n, b[:40]))
        clear_popup(1)
    return False


print("=" * 96)
print("  执行时采样 v2（先清弹窗 → 回起点 → 再采样）")
print("=" * 96)
os.makedirs(SHOT_DIR, exist_ok=True)

print("\n  ① 清弹窗")
ok, how = clear_popup()
print("     → %s（%s）" % ("✓ 已清" if ok else "✗ 未清", how))
if not ok:
    print("  ✗ 弹窗清不掉 → 本轮采样无意义（记样本会全部失败）")
    raise SystemExit(1)

print("\n  ② 回确定起点（抖音首页）")
if not goto_start():
    print("  ✗ 回不到起点 —— ★ 这正说明「起点重置」是必要前提，不能省")
    raise SystemExit(1)
print("     ✓ 已在首页（自证：底部 tab 词多数表决通过）")

print("\n  ③ 采样")
# ★ 只用【已实测会成功】的确定性操作；expect 用 hashDiff（硬判据）
PLAN = [
    ("抖音-tab-精选", (0.302, 0.963)),
    ("抖音-tab-消息", (0.701, 0.963)),
    ("抖音-tab-我",   (0.900, 0.963)),
    ("抖音-tab-首页", (0.102, 0.963)),
    ("抖音-tab-精选-2", (0.302, 0.963)),
    ("抖音-搜索入口", (0.928, 0.066)),
]
n_ok = n_try = 0
with open(OUT, "a", encoding="utf-8") as fh:
    for name, (nx, ny) in PLAN:
        n_try += 1
        # ★ 每次采样前【重取】截图（避免用过期帧反推区域）
        b64 = shot_b64()
        if not b64:
            continue
        img = decode(b64)
        H, W = img.shape[:2]
        px, py = int(nx * W), int(ny * H)
        a = gw("script.exec", {"steps": [{"op": "tap", "x": nx, "y": ny},
                                         {"op": "wait_for", "expect": {"hashDiff": True},
                                          "timeoutMs": 5000}]}, tmo=60000)
        steps = a.get("ack", {}).get("steps") or []
        if not (steps and all(s.get("ok") for s in steps)):
            print("     ✗ %-16s 未通过验证（不记样本）" % name)
            continue
        reg, src, conf = reverse_region(img, px, py)
        ts = time.strftime("%Y%m%d-%H%M%S")
        fn = "%s-%s.png" % (ts, name)
        with open(os.path.join(SHOT_DIR, fn), "wb") as f2:
            f2.write(base64.b64decode(b64))
        fh.write(json.dumps({"ts": ts, "name": name, "screen": fn,
                             "tap": {"x": nx, "y": ny, "px": px, "py": py},
                             "verified": "hashDiff", "region": reg,
                             "regionSource": src, "regionConfidence": conf,
                             "size": [W, H]}, ensure_ascii=False) + "\n")
        fh.flush()
        n_ok += 1
        print("     ✓ %-16s 验证通过 → 样本已记（%dx%d · %s · conf %.2f）"
              % (name, reg[2], reg[3], src, conf))
        time.sleep(1.3)

print()
print("=" * 96)
print("  结果：%d/%d 通过验证并记为样本" % (n_ok, n_try))
print("  ★ 与 v1（0/5）对比 —— 差别只在于【先清了弹窗】✓")
print("  样本：%s" % OUT)
