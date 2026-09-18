r"""骨架实验：页面的【几何骨架】能不能判断"是不是同一页"？（用户 2026-09-19 纠正）

★★ 用户的两个纠正：
  ① "不用登录也可以看页面的啊" —— 我不该因抖音登出就停下（改用别的 App 即可）
  ② "页面的骨架不是能判断出是否一个页面吗" —— ★ 这一句点破了我方法的错误：
     我一直在算【文字块 + 块的统计直方图】✗ —— 那是页面的【血肉】，内容一变就废。
     而"骨架"是【区域的几何结构】（顶部有没有横栏、底部有没有导航条、中间是一整块还是分栏），
     ★ 它不受内容影响。

★ 本实验要验证的正是这一点：用【长横条 / 长竖条】的位置作为骨架，
  在【同一页滚动换内容】时应当稳定（intra 小），而【换到另一页】时应当明显不同（inter 大）。

实现（零设备端改动，纯 OpenCV）：
  · 提取长横条：横向开运算（核宽 = 50% 屏宽）→ 只剩宽度超半屏的横向结构
  · 提取长竖条：纵向开运算（核高 = 50% 屏高）
  · 把"每一行有没有长横条 / 每一列有没有长竖条"压成 0-1 剖面向量 → ★ 这就是骨架
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
    """同一时刻取截图 + OCR（★ 必须同刻，否则对不上）。"""
    ack = gw("screenshot")
    texts = [t for t in gw("vision.ocr").get("texts", []) if t.get("y", 1) >= NOISE_Y_MAX]
    img = cv2.imdecode(np.frombuffer(base64.b64decode(ack["image"]), dtype=np.uint8),
                       cv2.IMREAD_COLOR)
    return {"img": img, "texts": texts}


# ── ★★★ 骨架特征（本实验的主角）─────────────────────────────────────────

def _binary(img):
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    # 边缘化：UI 的栏/分隔线/卡片边框都是强边缘
    e = cv2.Canny(gray, 40, 120)
    return cv2.dilate(e, np.ones((3, 3), np.uint8), iterations=1)


def f_skeleton(img):
    """★ 骨架 = 「每一行有没有长横条」+「每一列有没有长竖条」的 0-1 剖面（降采样到 32 段）。

    为什么用【长条】而不是所有边缘：长条对应的是【栏/导航条/分栏】这类页面骨架，
    短边缘对应的是文字与图标（血肉）—— 后者随内容变，前者不变。
    """
    b = _binary(img)
    H, W = b.shape
    hk = cv2.getStructuringElement(cv2.MORPH_RECT, (max(8, W // 2), 1))
    vk = cv2.getStructuringElement(cv2.MORPH_RECT, (1, max(8, H // 2)))
    horiz = cv2.morphologyEx(b, cv2.MORPH_OPEN, hk)      # 只剩长横条
    vert = cv2.morphologyEx(b, cv2.MORPH_OPEN, vk)       # 只剩长竖条

    def profile(m, axis):
        v = (m > 0).sum(axis=axis)
        v = (v > 0).astype(float)
        # 降采样到 32 段（每段只要有就算 1）→ 对小幅位移不敏感
        n = 32
        step = max(1, len(v) // n)
        out = []
        for i in range(0, len(v), step):
            out.append(1.0 if v[i:i + step].any() else 0.0)
        return np.array(out[:n] if len(out) >= n else out + [0.0] * (n - len(out)))

    return np.concatenate([profile(horiz, 1), profile(vert, 0)])   # 各 32 → 共 64 维


def f_blockgrid(img):
    """对照 A：★ 半骨架 —— 用 OCR 文字块的【有无】占 10×6 网格（离散化，不用面积/数量）。"""
    # 注意：这里只标"该格有没有文字块"，刻意不记块数 —— 记块数就等于记内容密度了
    g = np.zeros((10, 6))
    return g  # 占位：真实实现需要 texts，见 f_blockgrid_s


def f_blockgrid_s(s):
    g = np.zeros((10, 6))
    for t in s["texts"]:
        r = min(9, int(t["cy"] * 10))
        c = min(5, int(t["cx"] * 6))
        g[r][c] = 1.0
    return g.flatten()


def f_allwords(s):
    return set(norm(t["text"]) for t in s["texts"] if len(norm(t["text"])) >= 2)


def d_l1(a, b):
    return float(np.abs(np.asarray(a, float) - np.asarray(b, float)).sum())


def d_jac(a, b):
    if not a and not b:
        return 0.0
    return 1.0 - len(a & b) / max(1, len(a | b))


def val_of(s, k):
    if k == "skel":
        return f_skeleton(s["img"])
    if k == "grid":
        return f_blockgrid_s(s)
    return f_allwords(s)


def dist_pair(a, b, k):
    return d_jac(a, b) if k == "words" else d_l1(a, b)


def mean_intra(series, k):
    vals = [dist_pair(val_of(series[i], k), val_of(series[j], k), k)
            for i in range(len(series)) for j in range(i + 1, len(series))]
    return float(np.mean(vals)) if vals else float("nan")


def mean_inter(A, B, k):
    vals = [dist_pair(val_of(a, k), val_of(b, k), k) for a in A for b in B]
    return float(np.mean(vals)) if vals else float("nan")


def capture(label, k, scroll=True, settle=1.8, require_change=False):
    print("\n  采集【%s】%d 帧%s" % (label, k, "（帧间上滑换内容）" if scroll else ""))
    out = []
    for i in range(k):
        if i and scroll:
            gw("touch.swipe", {"x1": 0.5, "y1": 0.75, "x2": 0.5, "y2": 0.30, "duration": 0.45})
            time.sleep(settle)
        s = frame()
        out.append(s)
        print("     帧%d: 文字 %2d 块" % (i + 1, len(s["texts"])))
    if require_change:
        # ★ 自检：内容必须真的变了（否则 intra 恒为 0，一切特征都"完美"= 假象）
        ws = [tuple(sorted(f_allwords(s))) for s in out]
        if len(set(ws)) == 1:
            print("  ✗✗ 【本组内容没有任何变化】—— 实验无效（intra 会恒为 0，全是假象）")
            raise SystemExit(3)
        print("     ✓ 自检通过：%d 帧里有 %d 种不同文字集合（内容确实变了）"
              % (k, len(set(ws))))
    return out


print("=" * 96)
print("  骨架实验 —— 判据：intra（同页滚动换内容）要【小】，inter（跨页）要【大】")
print("=" * 96)

print("\n  打开【设置】App（不用登录 ✓ 有多个层级页 ✓ 可滚动 ✓）")
gw("script.exec", {"steps": [{"op": "home"},
                             {"op": "open", "bundleId": "com.apple.Preferences"}],
                   "stepSettleMs": 900}, tmo=60000)
time.sleep(3)

A = capture("设置·根页", 4, scroll=True, require_change=True)

print("\n  进入子页（点击列表里第一个可见项）…")
# 用 OCR 找一个列表项来点（不硬编码坐标）
ts = [t for t in gw("vision.ocr").get("texts", []) if t.get("y", 1) >= NOISE_Y_MAX]
cand = [t for t in ts if 0.10 < t["y"] < 0.55 and len(norm(t["text"])) >= 2]
if cand:
    t0 = sorted(cand, key=lambda x: x["y"])[0]
    print("     点「%s」@(%.3f,%.3f)" % (norm(t0["text"]), t0["cx"], t0["cy"]))
    gw("script.exec", {"steps": [{"op": "tap", "x": t0["cx"], "y": t0["cy"]},
                                 {"op": "wait_for", "expect": {"hashDiff": True},
                                  "timeoutMs": 5000}], "stepSettleMs": 900}, tmo=60000)
    time.sleep(2)
B = capture("设置·子页", 4, scroll=True)

print()
print("=" * 96)
print("  结果（距离越小越像）")
print("=" * 96)
print("  %-26s %-11s %-11s %-11s %s" % ("特征", "intra", "inter", "信噪比", "判定"))
print("  " + "-" * 90)
for name, k in [("★★ 骨架(长横/竖条剖面)", "skel"),
                ("半骨架(文字块有无·10×6)", "grid"),
                ("对照·全部文字集合", "words")]:
    ia, ie = mean_intra(A, k), mean_inter(A, B, k)
    ratio = ie / ia if ia > 1e-9 else float("inf")
    verdict = "★★ 好" if ratio >= 3 else "△ 勉强" if ratio >= 1.5 else "✗ 没用"
    print("  %-26s %-11.4f %-11.4f %-11.2f %s" % (name, ia, ie, ratio, verdict))

print()
print("  ★ 期望结果：骨架的 intra 明显小于 inter（同页滚动不变，换页就变）。")
print("    若骨架 intra 也不小 → 说明长条提取对内容/滚动仍敏感，需再调核大小或改用固定分段的投影。")
