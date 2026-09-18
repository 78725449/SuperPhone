"""页面签名：采集 / 判定 / 列表（二期第一步，资产 L1 页面表的第一块）。

【解决什么问题】
一期暴露的三条约束（详见 docs/known-issues/02-设备端与构建.md）都指向同一件事：
  · wait_for{hashDiff} 热启动会超时 —— 因为判据是"画面变没变"这种弱信号
  · back 不是万能的        —— "返回上一级"因 App/页面而异
  · ★ 缓存坐标需页面前置条件 —— App 会恢复到上次离开的页面，坐标会点错
→ 共同解 = **先回答"我在哪个页面"**。而设备端已有做判定的全部原料
  （vision.ocr 给文字+坐标+置信度、screen.hash 给 pHash），
  **缺的只是"页面 → 特征文字集合"从哪来** —— 现在每次都要人读 OCR 手工挑词。

【本工具做什么】
  snapshot <名字>   抓 OCR → 去噪 → ★【多次采样取交集】= 稳定词 → 存为该页面的签名
  which             抓 OCR → 与所有签名比 → 报"最可能是哪个页面"（附各候选得分）
  list              列出已采集的签名
★ 零设备端改动（只用现有 vision.ocr / screen.hash）；签名是入库的资产，不是运行时缓存。

【★★★ 为什么必须"多次采样取交集"（2026-09-19 实测，这是本工具最关键的设计）】
  只采 1 次时，签名里会混入大量【内容】（点赞数 / 视频标题 / 搜索结果…）。
  实测：抖音首页采 1 次得 17 个词，其中 12 个是内容 → 换一个视频后判定得分
  从 **1.00 掉到 0.29**，直接判不出页面（而且会误导性地提示"该采集新页面"）。
  **结构词每次都在，内容词每次不同 → 交集即结构。**
  ★ 这个"结构 vs 内容"的分离是【自动】的，不需要人工标注。
  → 故默认 samples=3，采样之间主动滚动换内容。

【判定算法】刻意保持最简：score = |签名 ∩ 当前OCR| / |签名|，取最高分且 ≥ 阈值者胜。
  不用复杂相似度 —— 页面判定的本质就是"这页的特征文字在不在"。

用法：
  python scripts/page.py snapshot 首页 --app com.ss.iphone.ugc.Aweme [--samples 3] [--force]
  python scripts/page.py which [--device <id>] [--threshold 0.6]
  python scripts/page.py list
"""
from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import sys
import time
import urllib.request
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGES_DIR = os.path.join(ROOT, "skills", "superphone-device", "pages")
GW = "https://127.0.0.1:8080"
DEFAULT_DEVICE = "553A6EA8-29F1-43DB-94B4-D4E01D4204DC"

# 噪声过滤：状态栏（时间/电量/信号）在屏幕最顶部，任何页面都有 → 对区分页面无贡献
NOISE_Y_MAX = 0.035


def _ctx():
    c = ssl.create_default_context()
    c.check_hostname = False
    c.verify_mode = ssl.CERT_NONE
    return c


def _invoke(device: str, cap: str, params: dict | None = None, timeout: int = 30000) -> dict:
    """调设备能力。

    ★★ timeout 必须【显式传进 body】（2026-09-19 实测踩坑）：
      网关 `invoke` 侧的超时取自 **body.timeout**，默认只有 **5000ms**
      （`server/index.js`：`Number(body.timeout) || 5000`，上限 15s；
       长超时白名单目前只含 screen.wait / screen.waitStable / script.exec）。
      而 `vision.ocr` 实测耗时 **2.0~4.6s**（画面越复杂越慢）→ **紧贴 5s 边缘**，
      不传就会随机吃 **HTTP 504**（实测：不传 5.03s 失败；传 15000 则 5.28s 成功）。
      → 这里统一传 30000；Python 侧 urlopen 的 timeout 只是【客户端等待上限】，两回事。
    """
    body: dict = {"cap": cap, "params": params or {}, "timeout": timeout}
    req = urllib.request.Request(
        "%s/api/devices/%s/invoke" % (GW, device),
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout / 1000.0 + 20, context=_ctx()) as r:
        return json.load(r)


def _normalize(s: str) -> str:
    """与设备端 vision.find_text 的比对口径一致：两端去空白。"""
    return re.sub(r"\s+", "", s or "")


MIN_WORD_LEN = 2   # ★ 单字词零区分度（"我"/"的"几乎任何屏幕都有）→ 不当特征词

# ── 布局虚拟词（2026-09-19 新增；用户建议"布局+OCR 多元素"）────────────────────
# 动机：纯文字版只剩 4 个词、得分卡在 0.6~0.8，余量小。而 vision.ocr 每块都带 (x,y,w,h)，
#      我们原先【只用了文字、完全没用位置】。
#
# ★★ 实测结论（scripts/probe-page-layout.py 同一页面 3 帧）：
#    布局的【精确数值】全都不稳（块数 21/18/20、键盘区 6/7/8）——和文字内容词一样随内容变；
#    只有【离散/布尔特征】才可能稳（"底部导航 有·有·有" ✓，"键盘 无·无·有" ✗）。
#  → 故把布局编码成【虚拟词】，与真实文字混在一起，走【同一套】多采样+频次过滤+子串匹配。
#     不稳的会被自动滤掉；稳的自己留下。零新算法。
#
# ★★★ 只做【单侧特征】（条件成立才加词），不加"§无键盘"这类否定词 ——
#     后者在多个页面都成立 → 零区分度 → 只会稀释分数。
#
# ★★ 关于"键盘"：★ 不用位置判据，用【按键文字计数】（2026-09-19 实测修正）。
#    起初写的是"y>0.82 的块 ≥10"，实测在搜索输入页只抓到 7 块（键盘顶部行在 y=0.719，
#    被阈值挡在外面）→ 明明键盘弹着却判成"无键盘"。
#    而键盘按键的文字是【固定集合】（ABC/DEF/GHI/…/空格/123），且实测它们在签名里 3/3 稳定
#    → 直接用它们当特征更鲁棒，不受键盘高度/布局变化影响。
KBD_KEYS = {"ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ",
            "空格", "123", "？！", "#④¥", "AA"}
LAYOUT_WORDS = [
    # (虚拟词,      判定函数)                                    阈值依据（实测）
    ("§底部导航",   lambda real, texts: len([t for t in real if t["y"] > 0.92]) >= 3),   # 首页实测 4/5/5 稳
    ("§键盘",       lambda real, texts: sum(
        1 for t in texts if _normalize(t.get("text", "")) in KBD_KEYS) >= 4),            # 按键文字计数
    ("§内容密集",   lambda real, texts: len(real) >= 30),   # 首页 19~23 / 搜索输入页(无键盘)24 / (有键盘)36~42
    ("§顶栏",       lambda real, texts: len([t for t in real if 0.03 <= t["y"] <= 0.12]) >= 2),
]


def _layout_words(texts: list[dict]) -> list[str]:
    """从 OCR 的坐标与文字算【布局虚拟词】（只加条件成立的那些）。"""
    real = [t for t in texts if t.get("y", 1) >= NOISE_Y_MAX]
    return [w for w, cond in LAYOUT_WORDS if cond(real, texts)]


def _blocks_and_blob(texts: list[dict]) -> tuple[list[str], str]:
    """返回 (块文本列表, 拼接大串)。

    ★★ 为什么要有"大串"（2026-09-19 实测得出的关键设计）：
      OCR 的【分块边界不稳定】—— 同一条顶部栏，一次可能合成一块
      "三 直播 团购 南京 关注 商城推荐"，另一次可能切成三块。
      若用"块字符串精确相等"求交集/判定，会得到【空交集】（实测：3 次采样 0 共同文字）。
      → 故一律在【去空白的大串】上做**子串匹配**，分块边界变化就不再有影响。

    ★★★ 过短词在此【统一剔除】，保证【采集与判定的口径完全一致】：
      实测踩坑：判定用 _in_blob（要求 len≥2），但采集时漏了这一层 →
      单字"我"被收进签名、却永远不可能命中 → 得分【永远达不到 1.0】（实测卡在 0.80）。
      把过滤放在这里，两边都走同一函数，就不会再出现"签名含永不命中项"。
    """
    blocks = [_normalize(t.get("text", "")) for t in
              sorted(texts, key=lambda x: (x.get("y", 0), x.get("x", 0)))
              if t.get("y", 1) >= NOISE_Y_MAX]
    blocks = [b for b in blocks if len(b) >= MIN_WORD_LEN]
    # ★ 布局虚拟词接在真实词之后；大串只由真实文字拼成（虚拟词靠字符串匹配自然命中——
    #   它们以 § 开头，真实 OCR 不会产生该字符，所以不会误命中）
    return blocks + _layout_words(texts), "".join(blocks)


def _in_blob_simple(word: str, blob: str) -> bool:
    """仅按大串判定（供 --expect 前置校验用；不含布局虚拟词）。"""
    return len(word) >= MIN_WORD_LEN and word in blob


def _hit(word: str, blob: str, lw: set[str]) -> bool:
    """一个特征词在当前屏幕上是否命中。

    ★ 两类词【命中方式不同】（2026-09-19 修正；起初写成"虚拟词也去大串里找"，那是错的）：
      · 虚拟词（§ 开头）代表【布局事实】（"底部有导航栏"），不是屏幕上的文字 →
        必须在【当前重新算出的布局虚拟词集合】里查，去大串里找永远找不到。
      · 真实文字词 → 在去空白大串里做**子串匹配**（免疫 OCR 分块边界变化）。
    """
    if word.startswith("§"):
        return word in lw
    return len(word) >= MIN_WORD_LEN and word in blob


def _signature_from(texts: list[dict]) -> list[str]:
    """单次采样的特征词（仅用于诊断/兼容；正式采集走 cmd_snapshot 的多采样交集）。"""
    blocks, _ = _blocks_and_blob(texts)
    out, seen = [], set()
    for b in blocks:
        if len(b) >= MIN_WORD_LEN and b not in seen:
            seen.add(b)
            out.append(b)
    return out


def _capture(device: str) -> tuple[list[dict], str]:
    """抓一帧 OCR + pHash。★ timeout 走 _invoke 的默认 30s —— vision.ocr 实测 2~4.6s，
    而网关默认只有 5s，不显式传就会随机吃 504（详见 _invoke 注释）。"""
    ock = _invoke(device, "vision.ocr").get("ack", {})
    if not ock.get("ok"):
        raise SystemExit("✗ vision.ocr 失败: %s" % json.dumps(ock, ensure_ascii=False)[:200])
    hck = _invoke(device, "screen.hash").get("ack", {})
    return ock.get("texts", []), (hck.get("hash") or "")


def _load_all() -> list[dict]:
    out = []
    if not os.path.isdir(PAGES_DIR):
        return out
    for dirpath, _, files in os.walk(PAGES_DIR):
        for f in files:
            if f.endswith(".json"):
                with open(os.path.join(dirpath, f), encoding="utf-8") as fh:
                    try:
                        out.append(json.load(fh))
                    except Exception as e:
                        print("  ⚠️ 跳过损坏的签名 %s: %s" % (f, e))
    return out


# ── 子命令 ────────────────────────────────────────────────────────────────

def cmd_snapshot(a) -> int:
    # ★★★ 先验证"我确实在那一页"（2026-09-19 实测教训）：
    #   实测把"抖音朋友页"当成"首页"采了签名 → 之后 which 判它 1.00，看起来完美，实则错标。
    #   根因：snapshot 依赖【人来告诉它这是哪一页】，而人（或 AI）可能被 OCR 骗：
    #   两页都有"朋友/消息/我"，光看 OCR 分不出来。
    #   → 故支持 --expect：采集前要求屏幕上出现指定文字，否则拒绝采集。
    if a.expect:
        texts0, _ = _capture(a.device)
        _, blob0 = _blocks_and_blob(texts0)
        missing = [w for w in a.expect if not _in_blob_simple(w, blob0)]
        if missing:
            print("✗ 拒绝采集：当前屏幕没有【%s】" % " · ".join(missing))
            print("  → 说明此刻不在这页（或这页的该特征没出现）")
            print("  → 先用可靠方式切到该页再采；不要「先采了再说」——错标的签名会被判定忠实地用起来")
            print("  → 当前大串开头: %s" % blob0[:60])
            return 1
        print("  ✓ 前置校验通过（屏上有 %s）" % " · ".join(a.expect))

    # ★★ 多次采样取【交集】= 稳定词（2026-09-19 实测得出的关键设计）
    #   实测：抖音首页采 1 次得 17 个词，其中 12 个是【内容】（点赞数/视频标题）——
    #        换一个视频后判定得分从 1.00 掉到 0.29，直接判不出页面。
    #   根因：内容词稀释了分数。而"结构词每次都在、内容词每次不同"→ 交集即结构。
    #   ★ 这个区分是【自动】的，不需要人工标注哪些是结构、哪些是内容。
    samples = []          # [(blocks, blob, phash, ocr块数)]
    for i in range(max(1, a.samples)):
        if i and a.churn != "none":
            # 主动改变内容。★ 方式因页面而异（2026-09-19 实测）：
            #   scroll（默认）—— 适合信息流（上滑换一条，结构不变）
            #   none          —— 适合静态页；★ 也适合【键盘页】：
            #                    实测在搜索输入页用上滑会把键盘收起 → 结构变了 →
            #                    签名混入"有键盘/无键盘"两种状态的词 → 判定崩到 0.14
            _invoke(a.device, "touch.swipe",
                    {"x1": 0.5, "y1": 0.8, "x2": 0.5, "y2": 0.2, "duration": 0.4})
            time.sleep(a.settle)
        texts, phash = _capture(a.device)
        blocks, blob = _blocks_and_blob(texts)
        samples.append((blocks, blob, phash, len(texts)))
        if a.verbose:
            print("    采样 %d/%d: OCR %d 块 · 大串 %d 字 · 开头「%s」"
                  % (i + 1, a.samples, len(texts), len(blob), blob[:24]))

    # ★★★ 前提自检（2026-09-19 实测补）：多采样取高频【依赖"每次内容真的变了"】。
    #   实测踩坑：抖音首页滚动没生效 → 5 次看到同一屏 → 内容词全被当成"5/5 稳定词"
    #   （签名从 4 个词暴涨到 23 个，全是同一个视频的标题/数字），而且【完全静默】。
    #   → 这里显式检查各次采样的大串是否相同；全同就告警，不让人误信结果。
    blobs = [s[1] for s in samples]
    content_changed = len(set(blobs)) > 1
    if a.samples > 1 and a.churn != "none" and not content_changed:
        print("  ⚠️⚠️ 【滚动没有改变内容】—— %d 次采样的大串完全相同" % a.samples)
        print("      → 本次结果【不可信】：内容词会被误当稳定词（每次看到的都一样）")
        print("      → 常见原因：上滑在该页面无效/被拦截（抖音首页滑过评论区即如此）")
        print("      → 处置：换一种换内容的方式；或确认该页内容确实不变，再加 --no-scroll 明确接受")
        print()

    # ★ 特征词判据：出现频率 ≥ min_freq（默认 = 过半），而【不是】要求"每次都在"。
    #   2026-09-19 实测教训：用严格交集（要求 N/N 次都在）时只活下来 3 个词，
    #   验证 5 轮里 2 轮只剩 2/3 命中（OCR 会偶尔漏识某个词）→ 余量太小，再漏一个就判不出。
    #   改成"5 次里出现 ≥3 次"后，更多结构词能活下来（它们大多次都在），
    #   而内容词每次内容都不同、很难达到过半频率 → 仍被滤掉。
    freq = {}
    for blocks, _, _, _ in samples:
        for w in set(blocks):
            freq[w] = freq.get(w, 0) + 1
    # ★ 默认下限 = samples-1（5 次取 ≥4、3 次取 ≥2）：比"严格交集"宽容 OCR 偶尔漏识，
    #   又比"过半"严——实测"过半(3/5)"会让"玩同款"这类【视频上的按钮文字】混进签名。
    min_freq = a.min_freq if a.min_freq > 0 else max(2, len(samples) - 1)
    stable = [w for w in samples[0][0] if freq.get(w, 0) >= min_freq]
    # 把只在后续采样里冒头、但已达频率的也补进来（第 1 次没识出、后几次识出的词）
    for w, n in freq.items():
        if n >= min_freq and w not in stable and len(w) >= MIN_WORD_LEN:
            stable.append(w)

    union = []
    for blocks, _, _, _ in samples:
        for w in blocks:
            if w not in union:
                union.append(w)

    # 还原页面（把刚才为换内容而滚的，滚回去）
    if a.samples > 1 and a.churn != "none":
        for _ in range(a.samples - 1):
            _invoke(a.device, "touch.swipe",
                    {"x1": 0.5, "y1": 0.2, "x2": 0.5, "y2": 0.8, "duration": 0.4})
            time.sleep(0.3)

    if not stable:
        print("✗ %d 次采样【没有】稳定文字 —— 该页面内容每次都全变？" % a.samples)
        print("  已试：块级精确匹配（分块边界会变）→ 现用块级子串匹配。若仍为空，考虑：")
        print("       · 加大 --samples")
        print("       · 该页确实无稳定文字（纯图形页）→ 只能靠 pHash 或图标模板")
        return 1

    app = a.app or "unknown"
    d = os.path.join(PAGES_DIR, app)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "%s.json" % a.page)

    existed = os.path.exists(path)
    if existed and not a.force:
        print("✗ %s 已存在（要覆盖请加 --force）" % os.path.relpath(path, ROOT))
        return 1

    rec = {
        "page": a.page,
        "app": app,
        "env": {
            "screen": "%sx%s" % (a.width, a.height),
            "lang": "zh-Hans",
            "collected": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "device": a.device,
            "samples": a.samples,
            "match": "substring",     # ★ 匹配口径：在去空白大串上做子串匹配
        },
        "hash": samples[0][2],
        "signature": stable,          # ★ 只用高频词（跨采样稳定出现的）
        "freq": {w: freq.get(w, 0) for w in stable},   # 每个特征词出现几次（诊断/调阈值用）
        "union": union,               # 诊断用：本次见过的全部词（含内容词）
        "rawCount": samples[0][3],
    }
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    print("=" * 84)
    print("%s 页面签名：%s" % ("覆盖" if existed else "新建", a.page))
    print("=" * 84)
    print("  文件      : %s" % os.path.relpath(path, ROOT))
    print("  App       : %s" % app)
    print("  ★ 采样    : %d 次（每次之间滚动换内容）· 特征词判据：出现 ≥%d 次" % (a.samples, min_freq))
    n_virtual = len([w for w in stable if w.startswith("§")])
    n_dropped = len([w for w in union if w not in stable])
    print("  特征词    : 稳定词 %d 个（布局虚拟词 %d + 文字词 %d）· 并集 %d → 滤掉 %d 个低频=内容词"
          % (len(stable), n_virtual, len(stable) - n_virtual, len(union), n_dropped))
    print("  ★ 稳定词  : %s" % " · ".join(
        "%s(%d/%d)" % (w, freq.get(w, 0), a.samples) for w in stable[:20]))
    if len(stable) > 20:
        print("              … 共 %d 个" % len(stable))
    dropped = [w for w in union if w not in stable]
    if dropped:
        print("  滤掉(低频): %s%s" % (" · ".join(dropped[:10]), " …" if len(dropped) > 10 else ""))
    return 0


def cmd_which(a) -> int:
    sigs = _load_all()
    if not sigs:
        print("✗ 还没有任何页面签名 —— 先用 `snapshot <名字>` 采集一个")
        return 1

    texts, phash = _capture(a.device)
    blocks, blob = _blocks_and_blob(texts)
    lw = set(_layout_words(texts))

    print("=" * 84)
    print("当前在哪一页？")
    print("=" * 84)
    print("  当前 pHash : %s" % phash)
    print("  OCR 块数   : %d → 大串 %d 字（真实词在此做子串匹配）" % (len(texts), len(blob)))
    print("  ★ 布局特征 : %s" % (" · ".join(sorted(lw)) if lw else "（无）"))
    print()

    ranked = []
    for s in sigs:
        want = s.get("signature", [])
        if not want:
            continue
        hit = [w for w in want if _hit(w, blob, lw)]
        missed = [w for w in want if w not in hit]
        score = len(hit) / len(want)
        ranked.append((score, s, hit, missed))
    ranked.sort(key=lambda x: -x[0])

    print("  %-6s %-22s %-12s %s" % ("得分", "页面", "App", "命中/应有"))
    print("  " + "-" * 76)
    for score, s, hit, missed in ranked:
        mark = "★" if score >= a.threshold else " "
        print("  %s%-5.2f %-22s %-12s %d/%d" % (
            mark, score, s.get("page", "?")[:22],
            (s.get("app") or "").split(".")[-1][:12], len(hit), len(hit) + len(missed)))
    print()

    top = ranked[0]
    if top[0] >= a.threshold:
        print("  ★ 判定：这是【%s】（得分 %.2f ≥ 阈值 %.2f）" % (top[1].get("page"), top[0], a.threshold))
        print("     命中: %s" % " · ".join(top[2][:16]))
        if top[3]:
            print("     未出现: %s" % " · ".join(top[3][:12]))
    else:
        print("  ✗ 判定：未知页面（最高才 %.2f < 阈值 %.2f）" % (top[0], a.threshold))
        print("     → 这页还没采集过；确认后跑：page.py snapshot <页面名> --app <bundleId>")
        print("     ★ 这正是【该采集新页面】的信号（但若刚换了内容就判不出，见下）")
    if len(ranked) > 1 and ranked[1][0] >= a.threshold:
        print()
        print("  ⚠️ 另有候选也过阈值：%s（%.2f）—— 两者特征词可能太像，建议补区分性更强的词"
              % (ranked[1][1].get("page"), ranked[1][0]))
    return 0


def cmd_verify(a) -> int:
    """★ 重复判定，看同一页面能不能【稳定】认出来。

    ★★ 关于"换内容"（2026-09-19 实测教训，务必理解）：
      原先默认滚动换内容，但实测发现"换内容但留在同一页"这件事**本身就需要页面判定** ——
      鸡生蛋。不同页面的"内容"性质不同：
        · 抖音首页 = 视频流，上滑换一条【但连续上滑会滑进直播间】→ 那一轮其实已离开首页
        · 搜索结果页 = 结果列表，滚动不换页 ✓
        · 静态页（设置/搜索输入页）= 内容根本不变
      → 实测：滚动版验证 6 轮有 2 轮判不出，一度被误读成"签名坏了"，
        实际是【判定正确、验证方法错】。
      → 故本命令**默认不滚动**（只测 OCR 稳定性）；要测"内容变化下的鲁棒性"请显式加 --scroll，
        并自行确认该页面滚动不会换页 —— 且**判定失败不等于签名坏**。
    """
    sigs = {s.get("page"): s for s in _load_all()}
    target = sigs.get(a.page)
    if not target:
        print("✗ 没有名为「%s」的签名。现有：%s" % (a.page, " · ".join(sigs) or "（无）"))
        return 1
    want = target.get("signature", [])
    if not want:
        print("✗ 「%s」的签名为空" % a.page)
        return 1
    scroll = getattr(a, "scroll", False)

    print("=" * 84)
    print("验证页面签名：「%s」（%d 个特征词）" % (a.page, len(want)))
    print("=" * 84)
    print("  方式    : %s" % ("★ 每轮滚动换内容（需自行确认不会换页！）" if scroll
                              else "重复判定（不滚动）—— 测 OCR 稳定性"))
    fr = target.get("freq") or {}
    print("  特征词  : %s" % " · ".join(
        ("%s(%s)" % (w, fr.get(w, "?"))) for w in want[:20]))
    print()

    scores = []
    for i in range(a.rounds):
        if i and scroll:
            _invoke(a.device, "touch.swipe",
                    {"x1": 0.5, "y1": 0.8, "x2": 0.5, "y2": 0.2, "duration": 0.4})
            time.sleep(a.settle)
        texts, phash = _capture(a.device)
        _, blob = _blocks_and_blob(texts)
        hit = [w for w in want if _hit(w, blob, set(_layout_words(texts)))]
        score = len(hit) / len(want)
        scores.append(score)
        missed = [w for w in want if w not in hit]
        mark = "✓" if score >= a.threshold else "✗"
        print("  第 %d 轮  pHash=%s  得分 %.2f  %s  命中 %d/%d%s"
              % (i + 1, phash[:12], score, mark, len(hit), len(want),
                 ("  缺: " + " · ".join(missed)) if missed else ""))

    print()
    lo, avg = min(scores), sum(scores) / len(scores)
    passed = sum(1 for s in scores if s >= a.threshold)
    print("  最低 %.2f · 平均 %.2f · 过阈值 %d/%d 轮" % (lo, avg, passed, len(scores)))
    if passed == len(scores):
        print("  ★★ 通过 —— %d 轮都稳定认出「%s」" % (len(scores), a.page))
        return 0
    print("  ✗ 未通过 —— %d 轮里有 %d 轮认不出" % (len(scores), len(scores) - passed))
    if scroll:
        print("     ⚠️ 你开了 --scroll：若滚动会离开该页面，判不出是【正确行为】，不是签名坏")
        print("        → 先确认这一点，再考虑重采")
    else:
        print("     → 同一画面重复判定都不稳 = OCR 本身不稳；可加大 --samples 重采")
    return 2


def cmd_list(a) -> int:
    sigs = _load_all()
    if not sigs:
        print("（还没有任何页面签名）")
        return 0
    print("=" * 84)
    print("已采集的页面签名（%d 个）" % len(sigs))
    print("=" * 84)
    print("  %-22s %-34s %-6s %s" % ("页面", "App", "词数", "采集时间"))
    print("  " + "-" * 76)
    for s in sorted(sigs, key=lambda x: (x.get("app", ""), x.get("page", ""))):
        print("  %-22s %-34s %-6d %s" % (
            s.get("page", "?")[:22], (s.get("app") or "?")[:34],
            len(s.get("signature", [])), s.get("env", {}).get("collected", "?")))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="页面签名：采集 / 判定 / 列表")
    ap.add_argument("--device", default=DEFAULT_DEVICE)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s1 = sub.add_parser("snapshot", help="抓当前屏幕并存为该页面的签名")
    s1.add_argument("page", help="页面名，如 首页 / 搜索输入页")
    s1.add_argument("--app", default="", help="App bundleId（用于分组）")
    s1.add_argument("--force", action="store_true", help="覆盖已存在的同名签名")
    s1.add_argument("--expect", action="append", default=[], metavar="文字",
                    help="★ 采集前置校验：要求屏幕上出现该文字，否则拒绝采集（可多次）。"
                         "防「把 A 页当成 B 页采下来」——错标的签名会被判定忠实使用，很危险")
    s1.add_argument("--samples", type=int, default=3,
                    help="采样次数（默认 3）。★ 取【高频词】= 稳定词，自动剔除内容词")
    s1.add_argument("--min-freq", type=int, default=0, dest="min_freq",
                    help="特征词的频率下限（默认=过半，即 3 次采样时要求 ≥2 次）。"
                         "★ 不要设成等于 samples —— 那是严格交集，OCR 偶尔漏识会让可用词太少")
    s1.add_argument("--churn", choices=["scroll", "none"], default="scroll",
                    help="★ 采样之间怎么「换内容」。scroll=上滑换一条（默认，适合信息流）；"
                         "none=不换（适合静态页，★ 也适合【键盘页】——实测在搜索输入页上滑会收起键盘、"
                         "结构被改变，签名会混入两种状态导致判定崩掉）")
    s1.add_argument("--settle", type=float, default=2.0, help="每次采样前的等待秒数（默认 2.0）")
    s1.add_argument("--verbose", action="store_true", help="打印每次采样详情")
    s1.add_argument("--width", type=int, default=750)
    s1.add_argument("--height", type=int, default=1334)
    s1.set_defaults(fn=cmd_snapshot)

    s2 = sub.add_parser("which", help="判定当前在哪个页面")
    s2.add_argument("--threshold", type=float, default=0.6)
    s2.set_defaults(fn=cmd_which)

    s3 = sub.add_parser("list", help="列出已采集的签名")
    s3.set_defaults(fn=cmd_list)

    s4 = sub.add_parser("verify", help="★ 重复判定，看同一页面能否稳定认出")
    s4.add_argument("page", help="要验证的页面名")
    s4.add_argument("--rounds", type=int, default=5, help="验证轮数（默认 5）")
    s4.add_argument("--threshold", type=float, default=0.6)
    s4.add_argument("--scroll", action="store_true",
                    help="★ 每轮滚动换内容（默认不滚动）。仅在该页面【滚动不会换页】时用；"
                         "否则判不出是正确行为，不是签名坏")
    s4.add_argument("--settle", type=float, default=2.0)
    s4.set_defaults(fn=cmd_verify)

    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
