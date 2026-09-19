r"""弹窗处置链 —— 四级兜底（2026-09-19 真机实测确立）。

★★ 由来：用户早就问过「对弹窗和对话框等不规律出现的情况如何处理呢？」，
   当时只能【设计】✗。本轮真机跑采样时，一个抖音红包弹窗【真的挡住了整条流程】✗，
   于是有了实测样本，四级链的每一级都被验过。

★★★ 实测数据（抖音红包弹窗「恭喜获得老友回归红包…立即领取」）：
   · 它【没有"取消/关闭/×"】✗ —— 全屏特征词只找到"立即领取"
   · 它【没有全屏遮罩】✓ —— 底部 tab 在 y=0.966 仍然可见
   · 但它【拦截了触摸】✗ —— 点底部 tab 的坐标，界面不变（hashDiff 不通过）
   · 点卡片外 (0.5, 0.12) → ★ 无效 ✗（"界面变了"只是弹幕在动）
   · ★ home + 重开 App → ★✓✓✓ 弹窗消失（App 重开后弹窗不保留）

★ 四级链（成本从低到高，末级是诚实兜底）：
   1 常见关闭词   取消/关闭/稍后/以后再说/不再提示/我知道了/跳过/×
                  ★ 有一类弹窗根本没有这些词 → 必须往下走
   2 点卡片外区域  ★ 实测对本弹窗无效 → 不指望它
   3 ★ home + 重开 App  ✓ 实测有效；★ 代价=丢失当前页面位置 → 处置后必须重新导航
   4 记录为坑 + 上报人工  诚实兜底，而不是无限重试

★★ 由此得到一条【结构性结论】：
   · 因为第 3 级会把 App 打回起点，"从确定起点开始"就不是风格问题而是【必要前提】✗
   · 技能卡/采集流程都应显式声明起点，并在弹窗处置后重新导航 ✓

★ 本脚本只做实测验证，不落盘资产（弹窗样本本身价值有限，链的验证才值钱）。
"""
import json
import ssl
import sys
import time
import urllib.request

ROOT = r"D:\编程项目\SuperPhone"
DEV = "553A6EA8-29F1-43DB-94B4-D4E01D4204DC"
GW = "https://127.0.0.1:8080"
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

CLOSE_WORDS = ["取消", "关闭", "稍后", "以后再说", "不再提示", "我知道了", "跳过", "×"]


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


def find_close_word():
    """第 1 级：找常见关闭词。"""
    for t in texts():
        s = (t.get("text") or "").strip()
        if any(w in s for w in CLOSE_WORDS):
            return t
    return None


def tap(x, y, wait_ms=4000):
    a = gw("script.exec", {"steps": [{"op": "tap", "x": x, "y": y},
                                     {"op": "wait_for", "expect": {"hashDiff": True},
                                      "timeoutMs": wait_ms}],
                           "stepSettleMs": 900}, tmo=60000)
    steps = a.get("ack", {}).get("steps") or []
    return bool(steps) and all(s.get("ok") for s in steps)


def try_close_popup(bundle_id, popup_marker, verbose=True):
    """★ 四级兜底链。返回 (是否关掉, 用了哪一级)。"""
    def still_on():
        return popup_marker in blob()

    if not still_on():
        return True, "无需处置"

    # 第 1 级：常见关闭词
    t = find_close_word()
    if t:
        if verbose:
            print("    [1级] 找到关闭词「%s」@(%.3f,%.3f)" % (t["text"], t["cx"], t["cy"]))
        tap(t["cx"], t["cy"])
        time.sleep(1.5)
        if not still_on():
            return True, "1级:常见关闭词"
    elif verbose:
        print("    [1级] ★ 没有常见关闭词 —— 这一级【失效】")

    # 第 2 级：点卡片外区域（上方一块空白）
    if verbose:
        print("    [2级] 试点卡片外 (0.5, 0.12)")
    tap(0.5, 0.12)
    time.sleep(1.5)
    if not still_on():
        return True, "2级:点卡片外"
    if verbose:
        print("    [2级] ★ 无效")

    # 第 3 级：home + 重开（★ 实测有效；代价=丢失页面位置）
    if verbose:
        print("    [3级] home + 重开 App")
    gw("script.exec", {"steps": [{"op": "home"}]}, tmo=60000)
    time.sleep(2.5)
    gw("script.exec", {"steps": [{"op": "open", "bundleId": bundle_id}]}, tmo=60000)
    time.sleep(4.5)
    if not still_on():
        return True, "3级:home+重开"

    # 第 4 级：诚实兜底
    if verbose:
        print("    [4级] ★ 三级都无效 → 记录为坑，上报人工")
    return False, "4级:需人工"


if __name__ == "__main__":
    print("=" * 96)
    print("  弹窗处置链（四级兜底）—— 实测验证")
    print("=" * 96)
    marker = sys.argv[1] if len(sys.argv) > 1 else "恭喜获得老友回归红包"
    bid = "com.ss.iphone.ugc.Aweme"
    b = blob()
    print("  当前弹窗标记「%s」在屏: %s" % (marker, marker in b))
    ok, how = try_close_popup(bid, marker)
    print()
    print("  结果：%s（%s）" % ("✓ 已关掉" if ok else "✗ 未关掉", how))
    print()
    print("  ★ 关键结论（写进设计）：")
    print("    · 第 1 级【有一类弹窗根本不适用】—— 实测红包弹窗只有「立即领取」，无取消/关闭/×")
    print("    · 第 2 级【实测无效】—— 点了卡片外，弹窗仍在（'界面变了'只是弹幕在动）")
    print("    · ★ 第 3 级【实测有效】—— App 重开后弹窗不保留（内存态）")
    print("    · 但第 3 级会【丢失页面位置】→ ★ 处置后必须重新导航")
    print("    → 所以「从确定起点开始」不是风格问题，而是【必要前提】")
