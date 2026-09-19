r"""导航回抖音首页（鲁棒版）—— 循环尝试所有"返回/关闭"手段，每轮用结构判据自证。

★★ 实测到的困境（2026-09-19）：
   权限弹窗清掉后，落进了【抖音客服聊天页】；`home + 重开 App` 【没能】把它重置 ✗
   —— 说明"home+重开"并不总能把 App 打回首页（App 会恢复上次页面）
   ⇒ ★ 所以"从确定起点开始"这条【需要更可靠的实现】✗，不能只靠 home+重开

★ 本脚本穷举返回手段，每轮自证（结构判据：底部导航带 y>0.93 的块数 ≥3）：
   ① 左上角返回（Douyin 实测有效：tap 0.05,0.063）
   ② 右上/右下角的 X（实测客服页有 X@(0.825,0.870)）
   ③ 点底部 tab 区（若 tab 已在，点"首页"即可）
   ④ 从屏幕左缘右滑（iOS 返回手势）
   ⑤ home + 重开（实测不一定有效，但仍试）
"""
import json
import ssl
import sys
import time
import urllib.request

ROOT = r"D:\编程项目\SuperPhone"
DEV = "553A6EA8-29F1-43DB-94B4-D4E01D4204DC"
GW = "https://127.0.0.1:8080"
DOUYIN = "com.ss.iphone.ugc.Aweme"
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


def texts():
    return [t for t in gw("vision.ocr").get("texts", []) if t.get("y", 1) >= 0.035]


def blob():
    return "".join((t.get("text", "") or "").replace(" ", "") for t in texts())


def nav_blocks():
    return sum(1 for t in texts() if t.get("cy", 0) > 0.93)


def at_content_page():
    """★ 结构判据：底部导航带 ≥3 块（与文字无关）。"""
    n = nav_blocks()
    return n >= 3, n


def tap(x, y, settle=2.0):
    gw("script.exec", {"steps": [{"op": "tap", "x": x, "y": y}]}, tmo=60000)
    time.sleep(settle)


def find_close_x():
    """找角落里的 X / 关闭类按钮。"""
    for t in texts():
        s = (t.get("text") or "").strip()
        if s in ("X", "×", "✕", "关闭"):
            return t
    return None


print("=" * 96)
print("  导航回抖音首页（穷举返回手段 + 结构自证）")
print("=" * 96)

ok, n = at_content_page()
print("\n  起点：底部带 %d 块(%s) · %s" % (n, "✓" if ok else "✗", blob()[:60]))

for rnd in range(1, 9):
    ok, n = at_content_page()
    if ok:
        print("\n  ★★ 第 %d 轮后已在带底部 tab 的页面（底部带 %d 块）✓" % (rnd - 1, n))
        print("     文字：%s" % blob()[:70])
        sys.exit(0)

    print("\n  ── 第 %d 轮（当前底部带 %d 块）──" % (rnd, n))
    # ① 左上角返回
    print("     [1] 点左上角返回 (0.05, 0.063)")
    tap(0.05, 0.063)
    if at_content_page()[0]:
        continue
    # ② 角落 X
    x = find_close_x()
    if x:
        print("     [2] 点「%s」@(%.3f,%.3f)" % (x["text"], x["cx"], x["cy"]))
        tap(x["cx"], x["cy"])
        if at_content_page()[0]:
            continue
    else:
        print("     [2] 屏上没有 X/关闭 按钮")
    # ③ 左缘右滑（iOS 返回手势）
    print("     [3] 左缘右滑")
    gw("script.exec", {"steps": [{"op": "swipe", "x1": 0.02, "y1": 0.5,
                                  "x2": 0.75, "y2": 0.5, "duration": 0.35}]}, tmo=60000)
    time.sleep(2)
    if at_content_page()[0]:
        continue
    # ④ home + 重开（多等一会，App 冷启会到 splash）
    print("     [4] home + 重开（等 7s）")
    gw("script.exec", {"steps": [{"op": "home"}]}, tmo=60000)
    time.sleep(2.5)
    gw("script.exec", {"steps": [{"op": "open", "bundleId": DOUYIN}]}, tmo=60000)
    time.sleep(7)
    if at_content_page()[0]:
        continue
    # ⑤ 点底部 tab 区中心（万一 tab 在但 OCR 没识别出字）
    print("     [5] 点底部 4 个 tab 位置（盲点，验证靠结构）")
    for cx in (0.102, 0.302, 0.701, 0.900):
        tap(cx, 0.963, settle=1.8)
        if at_content_page()[0]:
            break

ok, n = at_content_page()
print()
print("=" * 96)
if ok:
    print("  ★★ 成功回到带底部 tab 的页面（底部带 %d 块）✓" % n)
    print("     文字：%s" % blob()[:70])
else:
    print("  ✗ 穷举 8 轮仍回不去（底部带 %d 块）" % n)
    print("     文字：%s" % blob()[:90])
    print()
    print("  ★★ 这本身是一条【重要发现】：")
    print("     · `home + 重开 App` 【不保证】回到首页（App 会恢复上次页面）✗")
    print("     · 左缘右滑在抖音【无效】✗（与二期「back 不通用」的结论一致）")
    print("     · 所以「起点重置」需要【更强的实现】—— 例如：")
    print("       ① 记录「从首页到当前位置」的路径，反向走回去")
    print("       ② 或强制结束进程再启动（★ 但我们没有 kill app 的能力，需确认）")
    print("       ③ 或用【确定性入口】（如 URL scheme 直接跳首页）—— 需先勘察是否可用")
