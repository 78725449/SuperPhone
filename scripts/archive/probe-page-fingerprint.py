r"""页面指纹实验台（零设备端改动）—— 逐个特征问："内容变了以后它还认得出吗？"

背景（用户 2026-09-19 提议"三路融合：结构直方图 + CLIP 语义向量 + 文本/像素哈希"）：
  二期的实测已经否掉了两路（像素哈希 ✗ pHash 同页 5 轮全不同；结构直方图数值不稳 ✗ 块数 21/18/20）。
  但"否掉"不该靠推理，该靠数据 —— 故建这个实验台，用现成的 screenshot + vision.ocr 即可。

★ 核心判据（不是"特征算得出来吗"，而是）：
      intra = 同一页面、内容变化时，特征之间的距离   ← 要【小】
      inter = 不同页面之间，特征之间的距离           ← 要【大】
      ★ 有用 ⟺ inter ≫ intra（信噪比 ≥3 算好，<1.5 等于没信息量）

★ 两条必须遵守的实验纪律（都是踩坑换来的）：
  ① 截图与 OCR 必须【同一时刻】取 —— 否则两者对不上，会出现"所有矩形都不覆盖文字"这种
     不可能的结果，差点被误读成"检测无效"。
  ② 两个页面【必须用同样的换内容方式】采 —— 否则"静态 vs 动态"会混进跨页差异里，
     把 intra/inter 的对比做废。

★ 顺带回答"要不要给设备端加 vision.rects"：若电脑侧算出的矩形特征已够用，就不用改设备端。
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
    """同一时刻取 (截图, OCR文字块, pHash)。★ 纪律①：必须同刻取。"""
    ack = gw("screenshot")
    texts = [t for t in gw("vision.ocr").get("texts", []) if t.get("y", 1) >= NOISE_Y_MAX]
    h = gw("screen.hash").get("hash") or ""
    # ★ cv2.imread 在 Windows 上不支持非 ASCII 路径（本项目路径含中文）→ 用 imdecode 绕开
    img = cv2.imdecode(np.frombuffer(base64.b64decode(ack["image"]), dtype=np.uint8),
                       cv2.IMREAD_COLOR)
    return {"img": img, "texts": texts, "hash": h}


# ── 候选特征（统一接口：都接收【帧字典 s】，避免"传 texts 还是传 img"搞混）──────

def f_yhist(s):
    """① 结构直方图：按 y 分 10 带，块数占比（归一化）。"""
    h = [0.0] * 10
    for t in s["texts"]:
        h[min(9, int(t["y"] * 10))] += 1
    tot = sum(h) or 1.0
    return np.array([x / tot for x in h])


def f_zone(s):
    """② 分区域统计：顶/中/底块数【占比】+ 有无底部导航。"""
    texts = s["texts"]
    n = max(1, len(texts))
    top = sum(1 for t in texts if t["y"] < 0.15) / n
    mid = sum(1 for t in texts if 0.15 <= t["y"] < 0.85) / n
    bot = sum(1 for t in texts if t["y"] >= 0.85) / n
    nav = 1.0 if sum(1 for t in texts if t["y"] > 0.92) >= 3 else 0.0
    return np.array([top, mid, bot, nav])


def f_density(s):
    """⑤ ★ 密度：块数分档（★ 不归一化）。

    为什么单列一个：第一版只做了归一化的 zone，结果把"块多块少"这个最强信号抹掉了 ——
    实测视频页 8~18 块 vs 搜索页 45~47 块，归一化后两者比例相近、差异消失。
    这里用分档保留密度，且对小幅波动不敏感。
    """
    n = len(s["texts"])
    b = [0.0] * 6
    idx = 0 if n < 8 else 1 if n < 15 else 2 if n < 25 else 3 if n < 40 else 4 if n < 60 else 5
    b[idx] = 1.0
    return np.array(b)


def f_edgewords(s):
    """④ 边缘区文字集合（只取顶部 y<0.12 与底部 y>0.90 的文字词）。"""
    return set(norm(t["text"]) for t in s["texts"]
               if (t["y"] < 0.12 or t["y"] > 0.90) and len(norm(t["text"])) >= 2)


def f_allwords(s):
    """对照：全部文字集合（二期已在用的那套）。"""
    return set(norm(t["text"]) for t in s["texts"] if len(norm(t["text"])) >= 2)


def f_rects(s):
    """③ 矩形聚类：形态学梯度 → 轮廓 → 保留大块 → 归一化矩形列表。"""
    gray = cv2.cvtColor(s["img"], cv2.COLOR_BGR2GRAY)
    H, W = gray.shape[:2]
    k = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 5))
    g = cv2.morphologyEx(gray, cv2.MORPH_GRADIENT, k)
    _, b = cv2.threshold(g, 40, 255, cv2.THRESH_BINARY)
    b = cv2.morphologyEx(b, cv2.MORPH_CLOSE, k, iterations=3)
    cont, _ = cv2.findContours(b, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    out = []
    for c in cont:
        if cv2.contourArea(c) < 3000:
            continue
        x, y, w, h = cv2.boundingRect(c)
        out.append((x / W, y / H, w / W, h / H))
    return out


def f_rectsig(s):
    """③' 矩形集合压成固定长度向量：面积占比落在 5×5 网格的哪几格。"""
    g = np.zeros((5, 5))
    for (x, y, w, h) in f_rects(s):
        cx, cy = min(4, int((x + w / 2) * 5)), min(4, int((y + h / 2) * 5))
        g[cy][cx] += w * h
    tot = g.sum() or 1.0
    return (g / tot).flatten()


def f_rectcount(s):
    """③'' 矩形【数量】分档（同类于密度，但来自图像而非文字）。"""
    n = len(f_rects(s))
    b = [0.0] * 5
    b[0 if n < 2 else 1 if n < 5 else 2 if n < 10 else 3 if n < 20 else 4] = 1.0
    return np.array(b)


# ── 距离 ───────────────────────────────────────────────────────────────

def d_l1(a, b):
    return float(np.abs(np.asarray(a, dtype=float) - np.asarray(b, dtype=float)).sum())


def d_jac(a, b):
    if not a and not b:
        return 0.0
    return 1.0 - len(a & b) / max(1, len(a | b))


VEC = {"yhist": f_yhist, "zone": f_zone, "dens": f_density,
       "rect": f_rectsig, "rectn": f_rectcount}
SET = {"edge": f_edgewords, "all": f_allwords}

KEYS = [
    ("①结构直方图(y分10带)", "yhist"),
    ("②分区域统计(归一化)", "zone"),
    ("③矩形格点(5×5)", "rect"),
    ("③''矩形数量分档", "rectn"),
    ("④边缘区文字集合", "edge"),
    ("★⑤密度(文字块数分档)", "dens"),
    ("对照·全部文字集合", "all"),
    ("对照·pHash", "phash"),
]


def val_of(s, k):
    if k in VEC:
        return VEC[k](s)
    if k in SET:
        return SET[k](s)
    return int(s["hash"], 16) if s["hash"] else 0


def dist_pair(a, b, k):
    if k in VEC:
        return d_l1(a, b)
    if k in SET:
        return d_jac(a, b)
    return bin(a ^ b).count("1") / 64.0


def mean_intra(series, k):
    vals = [dist_pair(val_of(series[i], k), val_of(series[j], k), k)
            for i in range(len(series)) for j in range(i + 1, len(series))]
    return float(np.mean(vals)) if vals else float("nan")


def mean_inter(A, B, k):
    vals = [dist_pair(val_of(a, k), val_of(b, k), k) for a in A for b in B]
    return float(np.mean(vals)) if vals else float("nan")


def goto_douyin_home():
    """导航到抖音首页（动态视频流）—— ★ 本实验的 A 组【必须】是动态页。

    ★★ 踩坑（2026-09-19）：第一版没做这个，直接拿"当前页"当 A 组，结果设备停在搜索页
      （静态，上滑只收键盘不换内容）→ 5 帧 pHash 完全相同 → intra 全 0 →
      ★ 所有特征都显示"完美"，但那全是假象，实验无效。
      这正是二期已经吃过一次的教训：必须先验证"换内容真的生效"。
    """
    print("  导航到抖音首页（home → open → 点底部第一个 tab）…")
    gw("script.exec", {"steps": [{"op": "home"},
                                 {"op": "open", "bundleId": "com.ss.iphone.ugc.Aweme"}],
                       "stepSettleMs": 800}, tmo=60000)
    time.sleep(3)
    for attempt in range(3):
        gw("script.exec", {"steps": [{"op": "tap", "x": 0.11, "y": 0.963},
                                     {"op": "wait_for", "expect": {"hashDiff": True},
                                      "timeoutMs": 4000}],
                           "stepSettleMs": 900}, tmo=60000)
        time.sleep(2)
        blob = "".join(norm(t["text"]) for t in
                       gw("vision.ocr").get("texts", []) if t.get("y", 1) >= NOISE_Y_MAX)
        if "三直播团购" in blob or ("推荐" in blob and "团购" in blob):
            print("  ✓ 已在首页（第 %d 次尝试）" % (attempt + 1))
            return True
        print("  … 还不在首页，再试一次")
    print("  ⚠️ 未能确认在首页 —— A 组可能不是动态页，结论将不可信")
    return False


def capture_series(label, k, churn=True, settle=2.0, require_change=False):
    """采集一系列帧。★ require_change=True 时自检"换内容真的生效了"，否则直接报错退出。"""
    print("\n  采集【%s】%d 帧%s" % (label, k, "（帧间上滑换内容）" if churn else "（不换内容）"))
    out = []
    for i in range(k):
        if i and churn:
            gw("touch.swipe", {"x1": 0.5, "y1": 0.8, "x2": 0.5, "y2": 0.2, "duration": 0.4})
            time.sleep(settle)
        s = frame()
        out.append(s)
        print("     帧%d: 文字 %2d 块 · pHash %s" % (i + 1, len(s["texts"]), s["hash"][:12]))
    hashes = set(s["hash"] for s in out)
    if require_change and len(hashes) == 1:
        print()
        print("  ✗✗ 【本组没有任何内容变化】—— %d 帧 pHash 全同（%s）" % (k, list(hashes)[0][:12]))
        print("      → 此时 intra 必然为 0，所有特征都会显示「完美」，但那是假象，实验无效 ✗")
        print("      → 常见原因：该页是静态页（上滑只收键盘不换内容），或滚动被吸收")
        print("      → 正确做法：A 组必须是【动态页】（如抖音首页视频流）")
        raise SystemExit(3)
    return out


print("=" * 96)
print("  页面指纹实验台 —— 判据：intra（同页内容变化）要【小】，inter（跨页）要【大】")
print("=" * 96)

# ★ 纪律②：两组都用 churn=True（同样的换内容方式），否则静态/动态会混进跨页差异里
# ★ 纪律③：A 组【必须】是动态页，并自检"换内容真的生效"（require_change=True）
goto_douyin_home()
A = capture_series("第一页（抖音首页·动态）", 5, churn=True, require_change=True)

print("\n  切换页面…（tap 搜索图标 → 进搜索页）")
gw("script.exec", {"steps": [{"op": "tap", "x": 0.928, "y": 0.066},
                             {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 6000}],
                   "stepSettleMs": 900}, tmo=60000)
time.sleep(2)
B = capture_series("第二页（搜索页）", 5, churn=False)

print()
print("=" * 96)
print("  结果（距离都【越小越像】；★ 有用 ⟺ inter ≫ intra）")
print("=" * 96)
print("  %-24s %-11s %-11s %-11s %s" % ("特征", "intra", "inter", "信噪比", "判定"))
print("  " + "-" * 90)
rows = []
for name, k in KEYS:
    ia, ie = mean_intra(A, k), mean_inter(A, B, k)
    ratio = ie / ia if ia > 1e-9 else float("inf")
    if ratio >= 3:
        verdict = "★★ 好"
    elif ratio >= 1.5:
        verdict = "△ 勉强"
    else:
        verdict = "✗ 没用"
    rows.append((ratio, name, ia, ie, verdict))
    print("  %-24s %-11.4f %-11.4f %-11.2f %s" % (name, ia, ie, ratio, verdict))

print()
print("  读法：intra 小 = 内容变了它还稳；inter 大 = 跨页分得开；信噪比 <1.5 等于没信息量。")
best = max(rows)
print("  ★ 本次最佳：%s（信噪比 %.2f）" % (best[1], best[0]))
