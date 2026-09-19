r"""从【视觉 AI 的真实执行】里论证完整链路 —— 用完即弃的分析器。

输入（全部由 run-ios-agent.py 的真实执行产生，无任何人造数据）：
  · data/ma-trace/run.log                —— stdout，含每步 [MODEL OUTPUT]（AI 的动作 + 坐标）
  · <task_dir>/screenshot_<step>.png     —— 每步截图（task_dir 名 = 指令本身）
  · <task_dir>_anno/                     —— Mobile-Agent 自己画过标注的图

论证四件事（每件都给出数据，不给结论式空话）：
  ① 元素区域反推：从"AI 点的那个坐标 + 那一帧截图"能不能反推出可点击区域？
     判据：区域【必须覆盖点击点】✓ · 面积在 0.3%~20% 屏面积之间 ✓
  ② 页面识别：同一页面在多次到达时骨架稳不稳 / 不同页面差异大不大
  ③ 轨迹 → 技能卡：AI 的决策序列能不能直接落成 steps
  ④ 诚实列缺口：哪些东西这次没拿到（如 OCR 需当时取）
"""
import glob
import json
import os
import re
import sys

import cv2
import numpy as np

ROOT = r"D:\编程项目\SuperPhone"
LOG = os.path.join(ROOT, "data", "ma-trace", "run.log")
MA_DIR = os.path.join(ROOT, "_research", "MobileAgent", "Mobile-Agent-v3.5", "mobile_use")


def read_log():
    """读 stdout 日志。

    ★★ 踩坑（2026-09-19）：PowerShell 的 `Tee-Object` 默认写 **UTF-16LE**，
      用 utf-8 读会得到「6 E A 8」这种字符间夹 NUL 的乱码 →
      正则全部失配、解析到 0 步。故这里【先探测编码】再读。
    """
    if not os.path.exists(LOG):
        print("✗ 没有 %s —— 先跑 run-ios-agent.py" % LOG)
        sys.exit(1)
    raw = open(LOG, "rb").read()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16")
    # 无 BOM 时的启发：ASCII 文本里出现大量 NUL 就是 UTF-16
    if raw[:400].count(b"\x00") > 40:
        return raw.decode("utf-16-le", errors="replace")
    return raw.decode("utf-8", errors="replace")


def parse_steps(text):
    """从 stdout 里抽每一步：step_id + 自然语言意图 + tool_call（含动作与坐标）。

    ★ 实测格式（2026-09-19 驱动 GUI-Owl 得到）：
        ======
        STEP 0
        ======
        [MODEL OUTPUT]
        Action: Click on the "设置" option at the top left ...      ← ★ 自然语言意图（天然标签）
        <tool_call>
        {"name": "mobile_use", "arguments": {"action": "click", "coordinate": [107, 66]}}
        </tool_call>
    ★ 注意：动作名在 arguments.action 里（不是顶层 name ✗ —— 顶层恒为 "mobile_use"）
    """
    steps = []
    blocks = re.split(r"={10,}\s*\nSTEP\s+(\d+)\s*\n={10,}", text)
    # blocks: [前言, sid1, body1, sid2, body2, ...]
    for i in range(1, len(blocks) - 1, 2):
        sid = int(blocks[i])
        body = blocks[i + 1]
        intent = ""
        mo = re.search(r"\[MODEL OUTPUT\]\s*\n(.*?)(?=<tool_call>|\Z)", body, re.S)
        if mo:
            intent = mo.group(1).strip().replace("\n", " ")
            intent = re.sub(r"^Action:\s*", "", intent)
        act = None
        mt = re.search(r"<tool_call>\s*(.*?)\s*</tool_call>", body, re.S)
        if mt:
            try:
                j = json.loads(mt.group(1))
                arg = j.get("arguments") or {}
                act = {"action": arg.get("action") or j.get("name"),
                       "arguments": arg}
            except Exception:
                pass
        if act is None:
            mm = re.search(r'"coordinate"\s*:\s*\[\s*(\d+)\s*,\s*(\d+)', body)
            if mm:
                act = {"action": "(regex)", "arguments":
                       {"coordinate": [int(mm.group(1)), int(mm.group(2))]}}
        steps.append({"step": sid, "intent": intent, "action": act})
    return steps


def find_task_dir(text):
    """task_dir 名 = 指令（空格换下划线、截断 80）。从日志里反推。"""
    m = re.search(r"instruction[：:]\s*(.+)", text)
    if m:
        cand = m.group(1).strip().replace(" ", "_")[:80]
        p = os.path.join(MA_DIR, cand)
        if os.path.isdir(p):
            return p
    # 退化：找 MA_DIR 下最近修改的目录
    dirs = [d for d in glob.glob(os.path.join(MA_DIR, "*")) if os.path.isdir(d)]
    dirs = [d for d in dirs if not d.endswith("_anno")]
    if not dirs:
        return None
    return max(dirs, key=os.path.getmtime)


def imread_u(path):
    """★ cv2.imread 在 Windows 上不支持非 ASCII 路径（本项目路径含中文）→ 用 imdecode 绕开。"""
    return cv2.imdecode(np.fromfile(path, dtype=np.uint8), cv2.IMREAD_COLOR)


def reverse_region(img, px, py):
    """★ 从点击点反推可点击区域 —— 三路合取，返回 (region, source, confidence)。

    路 1：以点为中心取一个小窗口，在窗口内找【包含该点】的最大连通"非背景块"轮廓。
    路 2：若路 1 的区域异常（过大/过小），退化为【固定尺寸窗口】（经验值：按钮级）。
    路 3：给出置信度 —— 轮廓面积占比合理 + 点接近区域中心 → 高；否则低。

    ★ 关键设计：反推只是【记录】，不影响当下执行；错误会在复用时被 verify 抓到。
    """
    H, W = img.shape[:2]
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    edges = cv2.dilate(cv2.Canny(gray, 40, 120), np.ones((3, 3), np.uint8), 1)
    cont, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    best = None
    for c in cont:
        x, y, w, h = cv2.boundingRect(c)
        if not (x <= px <= x + w and y <= py <= y + h):
            continue
        area_ratio = (w * h) / float(W * H)
        if not (0.002 <= area_ratio <= 0.25):
            continue
        if w < 20 or h < 20:
            continue
        # 取"面积最小且仍包含该点"的那个 → 最贴近元素边界
        if best is None or w * h < best[2] * best[3]:
            best = (x, y, w, h)
    if best is None:
        w, h = int(W * 0.12), int(H * 0.06)     # 路 2：退化窗口
        return (max(0, px - w // 2), max(0, py - h // 2), w, h), "fallback_window", 0.3
    x, y, w, h = best
    # 置信度：点离区域中心越近越高
    cx, cy = x + w / 2.0, y + h / 2.0
    d = np.hypot(px - cx, py - cy) / max(1.0, np.hypot(w / 2.0, h / 2.0))
    conf = float(np.clip(1.0 - d * 0.6, 0.4, 0.95))
    return (x, y, w, h), "contour", round(conf, 2)


def skeleton(img):
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    e = cv2.dilate(cv2.Canny(gray, 40, 120), np.ones((3, 3), np.uint8), 1)
    H, W = e.shape
    h = cv2.morphologyEx(e, cv2.MORPH_OPEN,
                         cv2.getStructuringElement(cv2.MORPH_RECT, (max(8, W // 2), 1)))
    v = cv2.morphologyEx(e, cv2.MORPH_OPEN,
                         cv2.getStructuringElement(cv2.MORPH_RECT, (1, max(8, H // 2))))

    def prof(m, axis, n=32):
        a = (m > 0).sum(axis=axis)
        a = (a > 0).astype(float)
        step = max(1, len(a) // n)
        o = [1.0 if a[i:i + step].any() else 0.0 for i in range(0, len(a), step)]
        if len(o) < n:
            o += [0.0] * (n - len(o))
        return np.array(o[:n])
    return np.concatenate([prof(h, 1), prof(v, 0)])


text = read_log()
steps = parse_steps(text)
tdir = find_task_dir(text)

print("=" * 96)
print("  从【视觉 AI 的真实执行】论证完整链路")
print("=" * 96)
print("  日志        : %s" % LOG)
print("  解析到步骤  : %d 步" % len(steps))
print("  产物目录    : %s" % (tdir or "（未找到）"))
if not steps:
    print()
    print("  ✗ 没解析到 [MODEL OUTPUT]。日志末尾 600 字：")
    print(text[-600:])
    sys.exit(2)

# 动作分布
from collections import Counter
acts = Counter((s["action"] or {}).get("action", "(解析失败)") for s in steps)
print("  动作分布    : %s" % dict(acts))
print()
print("  ★ 每步的【自然语言意图】= 天然的标签（不需要人工标注）：")
for s in steps[:6]:
    print("    %2d. [%-8s] %s" % (s["step"],
                                  (s["action"] or {}).get("action", "?"),
                                  (s["intent"] or "")[:80]))

# ── ① 元素区域反推 ─────────────────────────────────────────────────────
print()
print("─" * 96)
print("  ① 元素区域反推：从「AI 点的坐标 + 那一帧截图」能不能反推出可点击区域？")
print("─" * 96)
shots = {}
if tdir:
    for p in glob.glob(os.path.join(tdir, "screenshot_*.png")) + \
             glob.glob(os.path.join(tdir, "screenshot_*.jpg")):
        m = re.search(r"screenshot_(\d+)\.", p)
        if m:
            shots[int(m.group(1))] = p
print("  找到截图 %d 张: %s" % (len(shots), sorted(shots)[:12]))

# ★ 只对【点类动作】反推可点击区域 —— 滑动不是"点元素"，对它反推区域没有意义
#   （实测教训：对 swipe 反推会得到"屏幕底部一大片"，面积 16%~25%，把统计带偏 ✗）
CLICK_ACTIONS = {"click", "tap", "long_press", "double_click", "longpress"}
rows = []
for s in steps:
    sid = s["step"]
    a = s["action"]
    if not a:
        continue
    act_name = a.get("action", "?")
    if act_name not in CLICK_ACTIONS:
        continue
    args = a.get("arguments") or {}
    coord = args.get("coordinate") or args.get("coordinates")
    if not coord or len(coord) != 2:
        continue
    img = shots.get(sid)
    if img is None:
        continue
    im = imread_u(img)
    if im is None:
        continue
    H, W = im.shape[:2]
    # ★ Mobile-Agent 用 0-999 归一化坐标 → 转像素
    px, py = int(coord[0] / 999.0 * W), int(coord[1] / 999.0 * H)
    reg, src, conf = reverse_region(im, px, py)
    x, y, w, h = reg
    cov = (x <= px <= x + w) and (y <= py <= y + h)
    area = 100.0 * w * h / (W * H)
    rows.append((sid, act_name, coord, (x, y, w, h), src, conf, cov, area))

print("  可反推的点类动作：%d 个（滑动等非点类已排除 ✓）" % len(rows))

print()
print("  %-5s %-16s %-14s %-26s %-15s %-6s %-7s %s" %
      ("步", "动作", "AI输出坐标", "反推区域(像素)", "来源", "置信", "面积%", "覆盖点"))
print("  " + "-" * 94)
for sid, nm, coord, reg, src, conf, cov, area in rows:
    print("  %-5d %-16s %-14s %-26s %-15s %-6.2f %-7.2f %s" %
          (sid, nm[:16], str(coord), str(reg), src, conf, area, "✓" if cov else "✗"))
if rows:
    cov_n = sum(1 for r in rows if r[6])
    print()
    print("  ★ 区域覆盖点击点：%d/%d" % (cov_n, len(rows)))
    print("  ★ 面积分布：min %.2f%% · max %.2f%% · 均值 %.2f%%" %
          (min(r[7] for r in rows), max(r[7] for r in rows),
           sum(r[7] for r in rows) / len(rows)))
    print("  ★ 判据：覆盖必中（否则反推错）· 面积应在 0.3%~20%")

# ── ② 页面识别（骨架）──────────────────────────────────────────────────
print()
print("─" * 96)
print("  ② 页面识别：真实执行中各帧的骨架，同页稳不稳 / 跨页差异大不大")
print("─" * 96)
sks = []
for sid in sorted(shots):
    im = imread_u(shots[sid])
    if im is not None:
        sks.append((sid, skeleton(im)))
if len(sks) >= 2:
    d = [float(np.abs(sks[i][1] - sks[j][1]).sum())
         for i in range(len(sks)) for j in range(i + 1, len(sks))]
    print("  帧数 %d · 骨架两两 L1 距离：min %.1f · max %.1f · 均值 %.1f（满量程 64）"
          % (len(sks), min(d), max(d), sum(d) / len(d)))
    print("  ★ 注意：真实执行里页面会【自然跳转】，所以这里的距离混合了「同页不同帧」与「跨页」——")
    print("    要分开算 intra/inter，需要【标签】。而标签正是 AI 的意图序列（下一步做）。")
else:
    print("  帧数不足，跳过")

# ── ③ 轨迹 → 技能卡 ───────────────────────────────────────────────────
print()
print("─" * 96)
print("  ③ 轨迹 → 技能卡：AI 的决策序列能不能直接落成 steps？")
print("─" * 96)
seq = []
for s in steps:
    a = s["action"]
    if not a:
        continue
    arg = a.get("arguments") or {}
    seq.append({"op": a.get("action", "?"), "args": dict(arg)})
print("  AI 的原始决策序列（可直接作为技能卡的 steps 骨架）：")
for i, x in enumerate(seq[:14]):
    print("    %2d. %s" % (i + 1, json.dumps(x, ensure_ascii=False)[:110]))
if len(seq) > 14:
    print("    … 共 %d 步" % len(seq))
print()
print("  ★ 观察点：坐标是【绝对值】→ 若要落成可复用的卡，必须替换为元素引用（region/文字）")

# ── ④ 诚实列缺口 ───────────────────────────────────────────────────────
print()
print("─" * 96)
print("  ④ 本次没拿到的（诚实列出）")
print("─" * 96)
print("  · 每步当时的 OCR —— Mobile-Agent 只存截图不存 OCR；事后补已对不上画面了")
print("    → 正解：网关侧加 FARM_TRACE 钩子，在输入类 invoke 时顺手记 params + 异步抓一帧 OCR")
print("  · 每步的【意图标签】—— 只在 task_dir 名（整条指令）这一级，没有逐页标签")
print("    → 正解：把 AI 的决策序列 + 截图配对，用「上一动作的目标」作为这一帧标签")
