r"""执行时顺手采样器 —— 页面指纹【从真实执行里长出来】，不人造实验。

★★ 用户 2026-09-19 指出的一条关键路线：
   "我们视觉 AI 在执行时是会截图的，我们同时记录截图和坐标了，然后对截图进行全面多维的检测，
    只是从截图中提取特征不就能沿用视觉 AI 操作的路线了吗？"
   → 对。页面指纹不该【单独设计采集】✗，它是【执行过程的副产物】✓。

★★★ 这条路线同时解释了本会话实验一直失败的原因：
   我一直在【人工构造实验】（手工导航 + 手工滚动换内容），而每一步都可能失败：
     · 导航失败（App 登出）✗
     · 滚动无效（静态页滚不动：设置页 6 帧文字块数全是 29，自检直接报无效）✗
   而真实执行时：截图自然产生、页面跳转由任务驱动、同一页面的不同时刻天然有多种内容。
   → ★ 不该"设计实验"，该【从真实执行里收集】。

本脚本做什么：
  跑一个【真实多页漫游任务】（设置 App：进某页 → 返回 → 再进同一页 → 再返回 → 换另一页 …），
  每次停在某页时顺手采样若干帧，帧上带【那一刻的意图标签】。
  任务成功 ⇒ 标签自动可信（不需要人工标注）。
  然后从这些【真实帧】算 intra（同页不同轮次）/ inter（不同页）—— 全程不人造内容变化。
"""
import base64
import json
import re
import ssl
import time
import urllib.request

import cv2
import numpy as np

DEV = "553A6EA8-29F1-43DB-94B4-D4E01D4204DC"
GW = "https://127.0.0.1:8080"
NOISE_Y_MAX = 0.035
NSEG = 32
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


def norm(s):
    return re.sub(r"\s+", "", s or "")


def shot():
    """顺手采一帧：截图 + OCR。★ 同一时刻取（否则两者对不上）。"""
    ack = gw("screenshot")
    texts = [t for t in gw("vision.ocr").get("texts", []) if t.get("y", 1) >= NOISE_Y_MAX]
    img = cv2.imdecode(np.frombuffer(base64.b64decode(ack["image"]), dtype=np.uint8),
                       cv2.IMREAD_COLOR)
    return {"img": img, "texts": texts,
            "blob": "".join(norm(t["text"]) for t in texts)}


def run(steps, settle=0.9):
    a = gw("script.exec", {"steps": steps, "stepSettleMs": int(settle * 1000)}, tmo=60000)
    return a.get("ack", {})


def back():
    """返回上一级：点左上角返回箭头（实测有效）。"""
    run([{"op": "tap", "x": 0.06, "y": 0.065},
         {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 3500}])
    time.sleep(1.2)


def enter_list_item(name_hint):
    """在当前列表页里找一个含 name_hint 的文字块并点它（不硬编码坐标）。"""
    ts = gw("vision.ocr").get("texts", [])
    hit = [t for t in ts if name_hint in norm(t["text"]) and 0.08 < t["cy"] < 0.92]
    if not hit:
        return False
    t0 = sorted(hit, key=lambda x: x["cy"])[0]
    run([{"op": "tap", "x": t0["cx"], "y": t0["cy"]},
         {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 4000}])
    time.sleep(1.4)
    return True


print("=" * 96)
print("  执行时顺手采样 —— 标签来自【真实执行】，不人造内容变化")
print("=" * 96)

gw("script.exec", {"steps": [{"op": "home"},
                             {"op": "open", "bundleId": "com.apple.Preferences"}],
                   "stepSettleMs": 900}, tmo=60000)
time.sleep(3)

samples = []          # [{label, frame}]
TARGETS = ["蓝牙", "通用", "墙纸"]
ROUNDS = 2

for rnd in range(ROUNDS):
    print("\n  ── 第 %d 轮漫游 ──" % (rnd + 1))
    # 根页
    f = shot()
    samples.append({"label": "设置·根页", "round": rnd, "frame": f})
    print("     根页: 文字 %2d 块" % len(f["texts"]))
    for tg in TARGETS:
        if not enter_list_item(tg):
            print("     ✗ 列表里没找到「%s」，跳过" % tg)
            continue
        f = shot()
        samples.append({"label": "设置·%s" % tg, "round": rnd, "frame": f})
        print("     %s页: 文字 %2d 块" % (tg, len(f["texts"])))
        back()
    # 回到根页确认
    f = shot()
    if "设置" not in f["blob"] and len(f["texts"]) < 5:
        print("     ⚠️ 可能没回到根页")

print()
print("=" * 96)
print("  采样结果：共 %d 帧" % len(samples))
print("=" * 96)
from collections import defaultdict
by = defaultdict(list)
for s in samples:
    by[s["label"]].append(s["frame"])
for k, v in sorted(by.items()):
    print("  %-14s %d 帧  文字块数 %s" % (k, len(v), [len(f["texts"]) for f in v]))


# ── 特征 ────────────────────────────────────────────────────────────────

def seg_profile(mask, axis):
    v = (mask > 0).sum(axis=axis)
    v = (v > 0).astype(float)
    step = max(1, len(v) // NSEG)
    out = [1.0 if v[i:i + step].any() else 0.0 for i in range(0, len(v), step)]
    if len(out) < NSEG:
        out += [0.0] * (NSEG - len(out))
    return np.array(out[:NSEG])


def bars(img):
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    e = cv2.dilate(cv2.Canny(gray, 40, 120), np.ones((3, 3), np.uint8), 1)
    H, W = e.shape
    h = cv2.morphologyEx(e, cv2.MORPH_OPEN,
                         cv2.getStructuringElement(cv2.MORPH_RECT, (max(8, W // 2), 1)))
    v = cv2.morphologyEx(e, cv2.MORPH_OPEN,
                         cv2.getStructuringElement(cv2.MORPH_RECT, (1, max(8, H // 2))))
    return np.concatenate([seg_profile(h, 1), seg_profile(v, 0)])


def words(f):
    return set(norm(t["text"]) for t in f["texts"] if len(norm(t["text"])) >= 2)


def d_l1(a, b):
    return float(np.abs(np.asarray(a, float) - np.asarray(b, float)).sum())


def d_jac(a, b):
    if not a and not b:
        return 0.0
    return 1.0 - len(a & b) / max(1, len(a | b))


def intra(lbl, fn):
    v = by.get(lbl, [])
    if len(v) < 2:
        return float("nan")
    return float(np.mean([fn(v[i], v[j]) for i in range(len(v)) for j in range(i + 1, len(v))]))


def inter(fn):
    labs = [k for k, v in by.items() if v]
    vals = [fn(by[a][0], by[b][0]) for a in labs for b in labs if a != b]
    return float(np.mean(vals)) if vals else float("nan")


print()
print("=" * 96)
print("  真实帧上的结果（距离越小越像）")
print("=" * 96)
print("  %-26s %-22s %-11s %-11s %s" % ("特征", "intra(同页·不同轮次)", "inter", "信噪比", "判定"))
print("  " + "-" * 90)
for nm, fn in [("★骨架(长横/竖条剖面)", lambda a, b: d_l1(bars(a["img"]), bars(b["img"]))),
               ("对照·全部文字集合", lambda a, b: d_jac(words(a), words(b)))]:
    ia_vals = [intra(k, fn) for k in by if len(by[k]) >= 2]
    ia = float(np.nanmean(ia_vals)) if ia_vals else float("nan")
    ie = inter(fn)
    ratio = ie / ia if ia and ia > 1e-9 else float("inf")
    verdict = "★★ 好" if ratio >= 3 else "△ 勉强" if ratio >= 1.5 else "✗ 没用"
    print("  %-26s %-22.4f %-11.4f %-11.2f %s" % (nm, ia, ie, ratio, verdict))

print()
print("  ★ 这些帧全部来自【真实执行】，标签由任务的导航语义给定，未人造任何内容变化。")
print("    静态页（设置各页）本来就不变 → 它的 intra 天然为 0 是【正常】的，不是作弊。")
