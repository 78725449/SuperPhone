r"""实测：底部 tab 的【选中态】能不能靠"找色"判定？—— 为"操作生效"找可靠判据。

★★ 为什么需要它（2026-09-19）：
   采样器两次跑出 0 样本，根因不是设备、不是弹窗（弹窗已清 ✓），
   而是【缺一个可靠的"操作生效"判据】✗：
     · wait_for{hashDiff} 时序敏感（变化发生在等待之前就错过）✗
     · 点 tab 后的语义特征不确定 ✗
     · ★ 而 tab 的选中态【本质是颜色】✗ OCR 抓不到 ✓

★ 本脚本实测三件事（全部零新能力，用已有 screenshot 在电脑侧算像素）：
   J1 底部 tab 条带里，4 个 tab 位置的【颜色】能否区分选中/未选中？
   J2 同一 tab 在"选中"与"未选中"两种状态下，颜色差是否【显著大于】同状态的帧间波动？
      （★ 这正是"信噪比"判据，与前面页面指纹实验同一把尺子 ✓）
   J3 稳态下（不操作）颜色是否稳定？不稳就不能当判据 ✗
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
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

# 底部 4 个 tab 的中心 x（一期与后续实测一致：首页/精选|朋友/消息/我）
TABS = [("首页", 0.102), ("精选", 0.302), ("消息", 0.701), ("我", 0.900)]
TAB_Y = 0.966
PATCH_W, PATCH_H = 0.10, 0.030      # 每个 tab 取一小块（覆盖图标+文字）


def gw(cap, params=None, tmo=30000, wait=90):
    rq = urllib.request.Request(
        "%s/api/devices/%s/invoke" % (GW, DEV),
        data=json.dumps({"cap": cap, "params": params or {}, "timeout": tmo}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(rq, timeout=wait, context=ctx) as r:
        return json.load(r)["ack"]


def decode(b64):
    return cv2.imdecode(np.frombuffer(base64.b64decode(b64), dtype=np.uint8), cv2.IMREAD_COLOR)


def patch_stat(img, cx, cy):
    """取某 tab 处的色块统计：★ 均值亮度 + 高亮像素占比（选中态通常更亮/更饱和）。"""
    H, W = img.shape[:2]
    x1 = int((cx - PATCH_W / 2) * W)
    x2 = int((cx + PATCH_W / 2) * W)
    y1 = int((cy - PATCH_H / 2) * H)
    y2 = int((cy + PATCH_H / 2) * H)
    p = img[max(0, y1):y2, max(0, x1):x2]
    if p.size == 0:
        return None
    g = cv2.cvtColor(p, cv2.COLOR_BGR2GRAY).astype(np.float32)
    return {"mean": float(g.mean()),
            "max": float(g.max()),
            "p95": float(np.percentile(g, 95)),
            # ★ 高亮像素占比：选中态的图标/文字通常更亮
            "bright_ratio": float((g > 150).mean())}


def tabs_of(img):
    return {name: patch_stat(img, cx, TAB_Y) for name, cx in TABS}


def run_tap(x, y, wait_ms=3500):
    gw("script.exec", {"steps": [{"op": "tap", "x": x, "y": y},
                                 {"op": "wait_for", "expect": {"hashDiff": True},
                                  "timeoutMs": wait_ms}]}, tmo=60000)
    time.sleep(1.8)


print("=" * 96)
print("  实测：底部 tab 选中态能不能靠找色判定")
print("=" * 96)

# 先回首页（用多数表决自证）
for _ in range(3):
    gw("script.exec", {"steps": [{"op": "tap", "x": 0.102, "y": 0.963}]}, tmo=60000)
    time.sleep(2)
    t = gw("vision.ocr").get("texts", [])
    b = "".join((x.get("text", "") or "").replace(" ", "") for x in t if x.get("y", 1) >= 0.035)
    if sum(1 for w in ["首页", "精选", "朋友", "消息", "我"] if w in b) >= 2:
        break

print("\n  【J3】稳态下各 tab 的颜色统计（不操作，连采 4 帧）")
steady = []
for i in range(4):
    ack = gw("screenshot")
    img = decode(ack["image"])
    steady.append(tabs_of(img))
    print("     帧%d：" % i + " · ".join(
        "%s(均值%.0f 亮占比%.2f)" % (n, s["mean"], s["bright_ratio"])
        for n, s in steady[-1].items() if s))
    time.sleep(0.9)

print("\n  稳态波动（同状态帧间差，越小越好）：")
for name, _ in TABS:
    ms = [f[name]["mean"] for f in steady if f.get(name)]
    bs = [f[name]["bright_ratio"] for f in steady if f.get(name)]
    print("     %-5s 均值波动 σ=%.2f  亮占比 σ=%.4f" % (name, float(np.std(ms)), float(np.std(bs))))

# ── 逐个切换 tab，看选中态是否可分辨
print("\n  【J1】切换 tab 后各 tab 的颜色（★ 选中态的那个应明显不同）")
states = {}
for name, cx in TABS:
    gw("script.exec", {"steps": [{"op": "tap", "x": cx, "y": TAB_Y}]}, tmo=60000)
    time.sleep(2.2)
    ack = gw("screenshot")
    img = decode(ack["image"])
    st = tabs_of(img)
    states[name] = st
    # 找出"最亮"的 tab —— 若选中态更亮，它应该就是刚点的那个
    cand = [(n, s["bright_ratio"]) for n, s in st.items() if s]
    top = max(cand, key=lambda kv: kv[1])[0]
    print("     点「%s」→ 亮占比最高的是「%s」  %s" % (name, top, "✓ 命中" if top == name else "✗ 不符"))
    for n, s in st.items():
        if s:
            print("          %-5s 均值%6.1f 亮占比%.3f p95=%.0f" % (n, s["mean"], s["bright_ratio"], s["p95"]))

# ── J2：信噪比
print()
print("=" * 96)
print("  【J2】信噪比：选中态 vs 未选中态 的差 ÷ 同状态波动")
print("=" * 96)
for name, _ in TABS:
    sel = [states[k][name]["bright_ratio"] for k in states if states[k].get(name) and k == name]
    unsel = [states[k][name]["bright_ratio"] for k in states if states[k].get(name) and k != name]
    if not sel or not unsel:
        continue
    noise = float(np.std([f[name]["bright_ratio"] for f in steady if f.get(name)]))
    delta = float(np.mean(sel) - np.mean(unsel))
    # ★★★ 退化情形必须先判 —— 否则 0/0 会被算成 inf，输出一个【看起来很漂亮的好评】✗
    #     （本 session 第三类同类错误：恒等式当证据 · 分母选错 · 除零假象）
    if abs(delta) < 1e-6:
        verdict = "✗ 无差异（选中与未选中完全一样 → 本特征无效 或 操作根本没生效）"
        ratio_s = "—"
    elif noise < 1e-6:
        verdict = "✗ 波动为 0 却又有差异 —— 数据异常，不能用"
        ratio_s = "—"
    else:
        ratio = abs(delta) / noise
        ratio_s = "%.1f" % ratio
        verdict = ("★★ 可作判据" if ratio >= 3 else ("△ 勉强" if ratio >= 1.5 else "✗ 不可用"))
    print("  %-5s 选中 %.3f · 未选中 %.3f · Δ%+.3f · 同态σ %.4f → 信噪比 %s  %s"
          % (name, np.mean(sel), np.mean(unsel), delta, noise, ratio_s, verdict))

print()
print("  ★ 若信噪比高 → ★「找色」可以做「操作生效」的判据 ✓（零新能力，电脑侧算像素即可）")
print("  ★ 若不高 → 需要换特征（如【与模板比色】：拿选中态小图当模板 ✓ —— 这就要 L0 图标库）")
