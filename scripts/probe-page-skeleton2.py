r"""骨架实验 v2 —— 把「多采样取稳定」从【文字词】推广到【几何结构】。

v1 的失败与教训（2026-09-19）：
  v1 把"长横条"直接当骨架 → intra 17.17 ≈ inter 17.25 → 判定没用。
  根因不是"骨架没用"，而是【我的骨架定义错了】：
  设置页的【列表分隔线/卡片边框】也是长横条，但它们**随滚动移动**，
  把真正固定的栏（顶栏/底部 tab）淹没了。
  ★ 区分"骨架"与"内容"的真正判据不是"长得像长条"，而是【跨帧不动】。

v2 的正解：
  采 N 帧（帧间滚动换内容）→ 对每一行/列统计"有几帧这里有长条"→
  ★ 取【出现频率 ≥ 阈值】的那些行/列 = 稳定骨架。
  这与二期在文字词上用的"多采样取高频"是同一套思路，只是搬到了几何结构上。

★ 严格性：用【独立帧】评估，避免过拟合 ——
  从 A 组前一半推出骨架，用 A 组后一半测 intra，用 B 组全部测 inter。
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


def frame():
    ack = gw("screenshot")
    texts = [t for t in gw("vision.ocr").get("texts", []) if t.get("y", 1) >= NOISE_Y_MAX]
    img = cv2.imdecode(np.frombuffer(base64.b64decode(ack["image"]), dtype=np.uint8),
                       cv2.IMREAD_COLOR)
    return {"img": img, "texts": texts}


def seg_profile(mask, axis):
    """把 mask 投影成 NSEG 段的 0-1 向量（每段只要有就算 1）。"""
    v = (mask > 0).sum(axis=axis)
    v = (v > 0).astype(float)
    step = max(1, len(v) // NSEG)
    out = [1.0 if v[i:i + step].any() else 0.0 for i in range(0, len(v), step)]
    if len(out) < NSEG:
        out += [0.0] * (NSEG - len(out))
    return np.array(out[:NSEG])


def frame_bars(img):
    """单帧的 (长横条剖面, 长竖条剖面)。"""
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    e = cv2.Canny(gray, 40, 120)
    e = cv2.dilate(e, np.ones((3, 3), np.uint8), 1)
    H, W = e.shape
    hk = cv2.getStructuringElement(cv2.MORPH_RECT, (max(8, W // 2), 1))
    vk = cv2.getStructuringElement(cv2.MORPH_RECT, (1, max(8, H // 2)))
    horiz = cv2.morphologyEx(e, cv2.MORPH_OPEN, hk)
    vert = cv2.morphologyEx(e, cv2.MORPH_OPEN, vk)
    return seg_profile(horiz, 1), seg_profile(vert, 0)


def stable_skeleton(frames, min_freq_ratio=0.6):
    """★ 从多帧推出【稳定骨架】：每一段在 ≥60% 的帧里都有长条才算骨架。"""
    hs, vs = [], []
    for s in frames:
        h, v = frame_bars(s["img"])
        hs.append(h)
        vs.append(v)
    k = max(1, int(len(frames) * min_freq_ratio + 0.5))
    hstable = (np.sum(hs, axis=0) >= k).astype(float)
    vstable = (np.sum(vs, axis=0) >= k).astype(float)
    return np.concatenate([hstable, vstable]), k


def d_l1(a, b):
    return float(np.abs(np.asarray(a, float) - np.asarray(b, float)).sum())


def skel_of(s, use_stable, stable):
    """用稳定骨架做匹配：先算单帧剖面，再看它是否覆盖稳定骨架（对称差）。"""
    h, v = frame_bars(s["img"])
    cur = np.concatenate([h, v])
    if not use_stable:
        return cur
    # ★ 判据：稳定骨架的段，当前帧有没有？(漏掉的惩罚) + 当前帧多出来的非骨架段（轻惩罚）
    missing = float(np.sum((stable > 0) & (cur == 0)))
    extra = float(np.sum((stable == 0) & (cur > 0)))
    return np.array([missing, extra * 0.25])


def mean_pair(series, fn):
    vals = [d_l1(fn(series[i]), fn(series[j]))
            for i in range(len(series)) for j in range(i + 1, len(series))]
    return float(np.mean(vals)) if vals else float("nan")


def capture(label, k, settle=1.8, require_change=True):
    print("\n  采集【%s】%d 帧（帧间上滑换内容）" % (label, k))
    out = []
    for i in range(k):
        if i:
            gw("touch.swipe", {"x1": 0.5, "y1": 0.75, "x2": 0.5, "y2": 0.30, "duration": 0.45})
            time.sleep(settle)
        s = frame()
        out.append(s)
        print("     帧%d: 文字 %2d 块" % (i + 1, len(s["texts"])))
    if require_change:
        ws = [tuple(sorted(norm(t["text"]) for t in s["texts"] if len(norm(t["text"])) >= 2))
              for s in out]
        if len(set(ws)) == 1:
            print("  ✗✗ 【本组内容没有任何变化】实验无效")
            raise SystemExit(3)
        print("     ✓ 自检：%d 帧有 %d 种不同文字集合（内容确实变了）" % (k, len(set(ws))))
    return out


print("=" * 96)
print("  骨架实验 v2 —— ★ 稳定骨架（跨帧不动的那部分）能不能区分页面")
print("=" * 96)

gw("script.exec", {"steps": [{"op": "home"},
                             {"op": "open", "bundleId": "com.apple.Preferences"}],
                   "stepSettleMs": 900}, tmo=60000)
time.sleep(3)

A = capture("设置·根页", 6)
stable_A, k_used = stable_skeleton(A[:3])
print("     ★ 由前 3 帧推出的稳定骨架（阈值：≥%d 帧）: 横条段 %d/32 · 竖条段 %d/32"
      % (k_used, int(stable_A[:NSEG].sum()), int(stable_A[NSEG:].sum())))

print("\n  进入子页…")
ts = [t for t in gw("vision.ocr").get("texts", []) if t.get("y", 1) >= NOISE_Y_MAX]
cand = [t for t in ts if 0.10 < t["y"] < 0.55 and len(norm(t["text"])) >= 2]
if cand:
    t0 = sorted(cand, key=lambda x: x["y"])[0]
    print("     点「%s」" % norm(t0["text"]))
    gw("script.exec", {"steps": [{"op": "tap", "x": t0["cx"], "y": t0["cy"]},
                                 {"op": "wait_for", "expect": {"hashDiff": True},
                                  "timeoutMs": 5000}], "stepSettleMs": 900}, tmo=60000)
    time.sleep(2)
B = capture("设置·子页", 6)

A_test = A[3:]          # ★ 独立帧（没参与推骨架）
print()
print("=" * 96)
print("  结果（用【独立帧】评估；距离越小越像）")
print("=" * 96)
print("  %-30s %-11s %-11s %-11s %s" % ("特征", "intra", "inter", "信噪比", "判定"))
print("  " + "-" * 90)


def report(name, fn_intra, fn_inter):
    ia, ie = fn_intra(), fn_inter()
    ratio = ie / ia if ia > 1e-9 else float("inf")
    verdict = "★★ 好" if ratio >= 3 else "△ 勉强" if ratio >= 1.5 else "✗ 没用"
    print("  %-30s %-11.4f %-11.4f %-11.2f %s" % (name, ia, ie, ratio, verdict))


# 单帧骨架（v1 口径，作对照）
report("v1 单帧骨架(长条剖面)",
       lambda: mean_pair(A_test, lambda s: np.concatenate(frame_bars(s["img"]))),
       lambda: float(np.mean([d_l1(np.concatenate(frame_bars(a["img"])),
                                   np.concatenate(frame_bars(b["img"])))
                              for a in A_test for b in B])))

# ★ v2 稳定骨架（主角）
report("★v2 稳定骨架(跨帧不动)",
       lambda: float(np.mean([d_l1(skel_of(s, True, stable_A),
                                   np.array([0.0, 0.0])) for s in A_test])),
       lambda: float(np.mean([d_l1(skel_of(s, True, stable_A),
                                   np.array([0.0, 0.0])) for s in B])))

print()
print("  v2 读法：skel_of 返回 [漏掉的骨架段数, 多出的非骨架段数×0.25]。")
print("    与 [0,0] 的距离 = 该帧的「偏离骨架程度」→ 越小越像这一页。")
