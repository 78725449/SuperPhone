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


def _invoke(device: str, cap: str, params: dict | None = None, timeout: int = 90) -> dict:
    req = urllib.request.Request(
        "%s/api/devices/%s/invoke" % (GW, device),
        data=json.dumps({"cap": cap, "params": params or {}}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as r:
        return json.load(r)


def _normalize(s: str) -> str:
    """与设备端 vision.find_text 的比对口径一致：两端去空白。"""
    return re.sub(r"\s+", "", s or "")


MIN_WORD_LEN = 2   # ★ 单字词零区分度（"我"/"的"几乎任何屏幕都有）→ 不当特征词


def _blocks_and_blob(texts: list[dict]) -> tuple[list[str], str]:
    """返回 (块文本列表, 拼接大串)。

    ★★ 为什么要有"大串"（2026-09-19 实测得出的关键设计）：
      OCR 的【分块边界不稳定】—— 同一条顶部栏，一次可能合成一块
      "三 直播 团购 南京 关注 商城推荐"，另一次可能切成三块。
      若用"块字符串精确相等"求交集/判定，会得到【空交集】（实测：3 次采样 0 共同文字）。
      → 故一律在【去空白的大串】上做**子串匹配**，分块边界变化就不再有影响。
    """
    blocks = [_normalize(t.get("text", "")) for t in
              sorted(texts, key=lambda x: (x.get("y", 0), x.get("x", 0)))
              if t.get("y", 1) >= NOISE_Y_MAX]
    blocks = [b for b in blocks if b]
    return blocks, "".join(blocks)


def _in_blob(word: str, blob: str) -> bool:
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
    # ★★ 多次采样取【交集】= 稳定词（2026-09-19 实测得出的关键设计）
    #   实测：抖音首页采 1 次得 17 个词，其中 12 个是【内容】（点赞数/视频标题）——
    #        换一个视频后判定得分从 1.00 掉到 0.29，直接判不出页面。
    #   根因：内容词稀释了分数。而"结构词每次都在、内容词每次不同"→ 交集即结构。
    #   ★ 这个区分是【自动】的，不需要人工标注哪些是结构、哪些是内容。
    samples = []          # [(blocks, blob, phash, ocr块数)]
    for i in range(max(1, a.samples)):
        if i and not a.no_scroll:
            # 主动改变内容（上滑换一条）；对没有内容可滚的页面只是无效果，交集仍=全集，结果正确
            _invoke(a.device, "touch.swipe",
                    {"x1": 0.5, "y1": 0.8, "x2": 0.5, "y2": 0.2, "duration": 0.4})
            time.sleep(a.settle)
        texts, phash = _capture(a.device)
        blocks, blob = _blocks_and_blob(texts)
        samples.append((blocks, blob, phash, len(texts)))
        if a.verbose:
            print("    采样 %d/%d: OCR %d 块 → 特征 %d 个" % (i + 1, a.samples, len(texts), len(blocks)))

    # ★ 交集：以第 1 次采样的块为候选，看它能否在【每次】采样的大串里作为子串找到
    #   （用子串而非精确相等 —— OCR 分块边界不稳定，精确相等会得到空交集）
    stable = [w for w in samples[0][0]
              if all(_in_blob(w, s[1]) for s in samples[1:])]
    union = []
    for blocks, _, _, _ in samples:
        for w in blocks:
            if w not in union:
                union.append(w)

    # 还原页面（把刚才为换内容而滚的，滚回去）
    if a.samples > 1 and not a.no_scroll:
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
        "signature": stable,          # ★ 只用稳定词（跨采样都在的）
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
    print("  ★ 采样    : %d 次（每次之间滚动换内容）" % a.samples)
    print("  特征词    : 交集 = 稳定词 %d 个（并集 %d 个 → 剔除了 %d 个内容词）"
          % (len(stable), len(union), len(union) - len(stable)))
    print("  ★ 稳定词  : %s" % " · ".join(stable[:26]))
    if len(stable) > 26:
        print("              … 共 %d 个" % len(stable))
    dropped = [w for w in union if w not in stable]
    if dropped:
        print("  剔除(内容): %s%s" % (" · ".join(dropped[:10]), " …" if len(dropped) > 10 else ""))
    return 0


def cmd_which(a) -> int:
    sigs = _load_all()
    if not sigs:
        print("✗ 还没有任何页面签名 —— 先用 `snapshot <名字>` 采集一个")
        return 1

    texts, phash = _capture(a.device)
    blocks, blob = _blocks_and_blob(texts)

    print("=" * 84)
    print("当前在哪一页？")
    print("=" * 84)
    print("  当前 pHash : %s" % phash)
    print("  OCR 块数   : %d → 拼接大串 %d 字（匹配在此串上做子串查找）" % (len(texts), len(blob)))
    print()

    ranked = []
    for s in sigs:
        want = s.get("signature", [])
        if not want:
            continue
        hit = [w for w in want if _in_blob(w, blob)]      # ★ 子串匹配，非精确相等
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
    s1.add_argument("--samples", type=int, default=3,
                    help="采样次数（默认 3）。★ 取【交集】= 稳定词，自动剔除内容词")
    s1.add_argument("--no-scroll", action="store_true",
                    help="采样之间不滚动（页面内容不自动变时才用；否则交集=全集，含内容词）")
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

    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
