r"""清权限弹窗 → 回抖音首页 → 采样（v3：结构判据 + 安全词优先）。

★★★★ 本轮的实测发现（2026-09-19）：
   设备卡在【抖音帮助页 + 麦克风权限弹窗】，全屏文字：
     「"抖音"想访问您的麦克风」@y=0.439
     「不允许」@(0.319, 0.572)   「好」@(0.680, 0.573)   ★ 成对出现 ✓
     「X」@(0.825, 0.870)  ← 帮助页的关闭
   ⇒ ★ 权限弹窗【有】"不允许/好"这对词 → 处置链第 1 级对它【有效】✓
   ⇒ ★ 而活动弹窗（红包）【只有"立即领取"】→ 第 1 级失效，必须走第 3 级 ✗
   ★★ 所以：★ 处置链第 1 级的词表应【按弹窗类型分】✗，而不是一张大表 ✗
      · 权限类：不允许 / 好 / 允许 / 拒绝 / 取消        ← 实测有
      · 提示类：取消 / 关闭 / 稍后 / 以后再说 / 不再提示 / 我知道了 / 跳过 / ×
      · 活动类：★ 常常一个都没有 → 直接跳到第 3 级

★★ 我前面为何没清掉它：S3「中部密度 ≥25」阈值太高 ✗ ——
   权限弹窗是【小卡片】，中部只有 15 块 → 判成"不密" → 没触发处置 ✗
   ★ 教训：结构判据的阈值也要【按弹窗尺度】定，不能只按整页尺度
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

# ★ 按类型分的词表（实测确立）
WORDS_PERM = ["不允许", "拒绝", "取消", "好", "允许"]          # ★ 顺序=安全性：先点"不允许"
WORDS_TIP = ["取消", "关闭", "稍后", "以后再说", "不再提示", "我知道了", "跳过", "×", "X"]
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


# ── ★ 结构判据（不看文字）────────────────────────────────────────────
def s_nav():
    """底部导航带（二期 page.py 同款）。"""
    n = sum(1 for t in texts() if t.get("cy", 0) > 0.93)
    return n >= 3, n


def s_center_blocks():
    return sum(1 for t in texts() if 0.15 <= t.get("cy", 0) <= 0.90)


# ── ★ 按类型清弹窗 ────────────────────────────────────────────────────
def find_safe_button():
    """★ 只在【安全词】里找，且优先"不允许"——绝不擅自点未知按钮（项目红线）。"""
    ts = texts()
    for w in SAFE_FIRST:
        for t in ts:
            if (t.get("text") or "").strip() == w:
                return t, w
    return None, None


def clear_dialogs(max_rounds=4):
    for rnd in range(max_rounds):
        t, w = find_safe_button()
        if not t:
            return True, "无安全词可点"
        print("     [清] 点安全词「%s」@(%.3f,%.3f)" % (w, t["cx"], t["cy"]))
        gw("script.exec", {"steps": [{"op": "tap", "x": t["cx"], "y": t["cy"]}]}, tmo=60000)
        time.sleep(1.8)
    return find_safe_button()[0] is None, "达轮次上限"


print("=" * 96)
print("  清权限弹窗 → 回首页 → 采样（v3）")
print("=" * 96)

print("\n  ① 当前屏幕")
ok_nav, n_nav = s_nav()
print("     底部带 %d 块(%s) · 中部 %d 块 · 文字: %s"
      % (n_nav, "✓" if ok_nav else "✗", s_center_blocks(), blob()[:60]))

print("\n  ② 清弹窗（按类型词表，安全词优先）")
done, how = clear_dialogs()
print("     → %s（%s）" % ("✓" if done else "✗", how))

print("\n  ③ 当前屏幕")
ok_nav, n_nav = s_nav()
print("     底部带 %d 块(%s) · 中部 %d 块 · 文字: %s"
      % (n_nav, "✓" if ok_nav else "✗", s_center_blocks(), blob()[:60]))

print("\n  ④ 回抖音首页：home + 重开（★ 实测最可靠，代价=丢页面位置）")
gw("script.exec", {"steps": [{"op": "home"}]}, tmo=60000)
time.sleep(2.5)
gw("script.exec", {"steps": [{"op": "open", "bundleId": DOUYIN}]}, tmo=60000)
time.sleep(5)
ok_nav, n_nav = s_nav()
print("     重开后：底部带 %d 块(%s) · 文字: %s" % (n_nav, "✓" if ok_nav else "✗", blob()[:60]))
if not ok_nav:
    print("     ⚠️ 底部导航带仍未出现 → 可能还有弹窗，再清一轮")
    clear_dialogs(2)
    ok_nav, n_nav = s_nav()
    print("     再清后：底部带 %d 块(%s) · 文字: %s" % (n_nav, "✓" if ok_nav else "✗", blob()[:60]))

if not ok_nav:
    print("\n  ✗ 回不到带底部 tab 的页面 —— ★ 结构判据（而非词判据）诚实地报出了这一点 ✓")
    raise SystemExit(1)

print("\n  ⑤ 采样（★ 判据用【结构变化】：点 tab 后底部带是否仍在 + 中部块数是否变化）")
PLAN = [("tab-精选", (0.302, 0.963)), ("tab-消息", (0.701, 0.963)),
        ("tab-我", (0.900, 0.963)), ("tab-首页", (0.102, 0.963)),
        ("搜索入口", (0.928, 0.066))]
os.makedirs(SHOT_DIR, exist_ok=True)
n_ok = n_try = 0
with open(OUT, "a", encoding="utf-8") as fh:
    for name, (nx, ny) in PLAN:
        n_try += 1
        b64 = shot_b64()
        if not b64:
            continue
        img = decode(b64)
        H, W = img.shape[:2]
        before_mid = s_center_blocks()
        px, py = int(nx * W), int(ny * H)
        gw("script.exec", {"steps": [{"op": "tap", "x": nx, "y": ny}]}, tmo=60000)
        time.sleep(2.2)
        after_mid = s_center_blocks()
        ok_nav2, n_nav2 = s_nav()
        changed = (after_mid != before_mid)
        # ★ 判据：点了 tab 之后，(a) 底部带仍在 且 (b) 中部块数变了 → 认为操作生效
        if not (ok_nav2 and changed):
            print("     ✗ %-10s 未生效（底部带 %d · 中部 %d→%d）" % (name, n_nav2, before_mid, after_mid))
            continue
        reg, src, conf = reverse_region(img, px, py)
        ts = time.strftime("%Y%m%d-%H%M%S")
        fn = "%s-%s.png" % (ts, name)
        with open(os.path.join(SHOT_DIR, fn), "wb") as f2:
            f2.write(base64.b64decode(b64))
        fh.write(json.dumps({"ts": ts, "name": name, "screen": fn,
                             "tap": {"x": nx, "y": ny, "px": px, "py": py},
                             "verified": "structure:nav_kept+mid_changed",
                             "beforeMid": before_mid, "afterMid": after_mid,
                             "region": reg, "regionSource": src,
                             "regionConfidence": conf, "size": [W, H]},
                            ensure_ascii=False) + "\n")
        fh.flush()
        n_ok += 1
        print("     ✓ %-10s 生效（中部 %d→%d）→ 样本已记（%dx%d %s conf %.2f）"
              % (name, before_mid, after_mid, reg[2], reg[3], src, conf))
        time.sleep(1.2)

print()
print("=" * 96)
print("  结果：%d/%d 通过验证并记为样本" % (n_ok, n_try))
print("  ★ 判据从「等 hashDiff」换成「结构变化」——前者时序敏感，后者是状态比较 ✓")
