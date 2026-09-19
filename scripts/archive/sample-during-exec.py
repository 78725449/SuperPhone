r"""执行时采样器（确定性版）—— 产出【自带可信标签】的交互样本。

★★★★ 为什么是这一步（2026-09-19 论证收口后）：
  用户真正问的是"找到【我们真正要的】截图布局拆解方案"，而我只验了 OmniParser 一条路 ✗。
  想判断"自训 YOLO 是不是更优"，就需要 (截图, bbox) 的【真值】✗ ——
  而 OmniParser 的输出是模型输出、不是真值 ✗；我们的点击点只有 1 个真样本 ✗。
  → ★ 所以瓶颈是【样本】，不是算法 ✓

★★ 本脚本的关键设计：★ 采样【不需要 AI】✓
  用【确定性操作】+ `expect` 验证：
    · 执行前抓截图
    · 执行一个【已知会成功】的确定性操作（如点底部 tab）
    · ★ 用 expect 验证"界面确实变了" —— 只有验证通过才记一条样本 ✓
    · 顺手用 OpenCV 从点击点反推区域（作为 bbox 初值）
  → ★ 样本自带可信标签（因为"操作成功"是【被验证过】的，不是 AI 自称的 ✓）
  → ★★ 这正是那条纪律的应用：「AI/意图 必须加校验」✗

★ 输出 data/interaction-samples.jsonl，一行一条：
    {ts, screen, tap:{x,y}, before, after, verified, region, regionSource}
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


def run_verified(steps, settle=0.9):
    """★ 执行并返回【每个步骤是否验证通过】—— 只有 expect 通过才算数。"""
    a = gw("script.exec", {"steps": steps, "stepSettleMs": int(settle * 1000)}, tmo=60000)
    return a.get("ack", {})


def shot_b64():
    a = gw("screenshot")
    return a.get("image")


def decode(b64):
    return cv2.imdecode(np.frombuffer(base64.b64decode(b64), dtype=np.uint8), cv2.IMREAD_COLOR)


def reverse_region(img, px, py):
    """从点击点反推可点击区域（OpenCV 轮廓；与 OmniParser 独立，曾实测 IoU 0.539 吻合）。"""
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


# ── 确定性操作清单（★ 只用【已经实测验证过会成功】的）────────────────
# 每条：name, 前置（回主屏/进 App）, 点击坐标, 用哪个 expect 判定成功
PLAN = [
    # 抖音：底部 tab 之间的切换（一期验证过 tab 在 y≈0.963，x 分别为 .102/.302/.701/.900）
    {"name": "抖音-tab-精选", "app": "抖音", "tap": (0.302, 0.963), "expect": {"text": None}},
    {"name": "抖音-tab-消息", "app": "抖音", "tap": (0.701, 0.963), "expect": {"text": None}},
    {"name": "抖音-tab-我",   "app": "抖音", "tap": (0.900, 0.963), "expect": {"text": None}},
    {"name": "抖音-tab-首页", "app": "抖音", "tap": (0.102, 0.963), "expect": {"text": None}},
    # 抖音：右上角搜索入口（一期验证过）
    {"name": "抖音-搜索入口", "app": "抖音", "tap": (0.928, 0.066), "expect": {"hashDiff": True}},
]

print("=" * 96)
print("  执行时采样（确定性版）—— 只记【被 expect 验证过】的交互")
print("=" * 96)
os.makedirs(SHOT_DIR, exist_ok=True)

# 进抖音
b = ""
ts = gw("vision.ocr").get("texts", [])
cand = [t for t in ts if "抖音" in (t.get("text") or "")]
print()
print("  已在抖音？先看当前屏幕")
cur = "".join((t.get("text", "") or "").replace(" ", "") for t in ts if t.get("y", 1) >= 0.035)
print("    %s" % cur[:70])

n_ok = 0
n_try = 0
with open(OUT, "a", encoding="utf-8") as fh:
    for item in PLAN:
        n_try += 1
        before = shot_b64()
        if not before:
            print("    ✗ 取不到截图，跳过 %s" % item["name"])
            continue
        img = decode(before)
        H, W = img.shape[:2]
        px, py = int(item["tap"][0] * W), int(item["tap"][1] * H)
        # ★ 执行：tap + 用 hashDiff 作为"变了"的硬判据（比语义判据更宽，但仍是真的验证）
        ack = run_verified([{"op": "tap", "x": item["tap"][0], "y": item["tap"][1]},
                            {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 5000}])
        steps = ack.get("steps") or []
        ok = bool(steps) and all(s.get("ok") for s in steps)
        after = shot_b64()
        if not ok or not after:
            print("    ✗ %-18s 未通过验证（不记样本）" % item["name"])
            continue
        reg, src, conf = reverse_region(img, px, py)
        tsstr = time.strftime("%Y%m%d-%H%M%S")
        fn = "%s-%s.png" % (tsstr, item["name"])
        with open(os.path.join(SHOT_DIR, fn), "wb") as f2:
            f2.write(base64.b64decode(before))
        rec = {"ts": tsstr, "name": item["name"], "screen": fn,
               "tap": {"x": item["tap"][0], "y": item["tap"][1], "px": px, "py": py},
               "verified": "hashDiff", "region": reg, "regionSource": src,
               "regionConfidence": conf, "size": [W, H]}
        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
        fh.flush()
        n_ok += 1
        print("    ✓ %-18s 验证通过 → 样本已记（区域 %dx%d · %s · conf %.2f）"
              % (item["name"], reg[2], reg[3], src, conf))
        time.sleep(1.2)

print()
print("=" * 96)
print("  结果：%d/%d 个操作通过验证并记为样本" % (n_ok, n_try))
print("  样本文件：%s" % OUT)
print("  截图目录：%s" % SHOT_DIR)
print()
print("  ★ 这些样本的标签【可信】—— 因为'操作成功'是被 expect 验证过的，不是自称的 ✓")
print("  ★ 但它们【还不够训模型】：")
print("    · 数量少（几十条 vs YOLO 起步的几百张）")
print("    · 只有【正样本】（没有'这里不可点'的负样本）→ 会训出'到处都可点'的模型 ✗")
print("    · 区域是【反推】的初值，不是人工/权威真值")
print("  → ★★ 正确用法：先积累，并用它【评估】OmniParser 与其它方案（而非立刻训练）")
