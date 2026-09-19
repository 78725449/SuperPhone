r"""自证判据 v3 —— ★ 用【结构特征】，不用词。

★★★★ 为什么推翻前面的做法（2026-09-19，被数据打脸四次）：
   我这一轮反复用【词】做自证，四次被骗：
     ① 用"设置"           → 通用词，很多页面都有 → 误通过
     ② "带文字数==OCR数"   → 恒等式，恒真 → 推出错误结论
     ③ "0/0 → inf"        → 除零假象 → 输出"★★ 可作判据"
     ④ 词表里放单字"我"     → 任意文本都可能含 → 在【抖音帮助页】上误报"在首页"
   共同点：★ 特征不具区分力，却在某些情形下【恰好给出想要的答案】✗

★★ 解药【二期已经给过】✗：page.py 里的 §底部导航 = 「y>0.92 区域有 ≥3 个文字块」——
   它用的是【结构】而非文字，所以对 OCR 抖动免疫 ✓
   而我这一轮忘了这条，退回去用词 ✗ ⇒ ★ 说明经验没形成纪律就会被重复踩

★ 本脚本提供【结构型】判据并实测其可靠性：
   S1 底部导航带：y>0.93 的文字块数 ≥3        → 判定"在某个带底部 tab 的页面"
   S2 顶部栏带：  0.03≤y≤0.12 的块数 ≥2        → 判定"有顶部栏"
   S3 ★ 组合 + 排除：底部带存在 且 屏幕中部【没有大面积高亮卡片】→ 排除弹窗遮挡
   ★ 全部与具体文字无关 ✓
"""
import json
import ssl
import time
import urllib.request

ROOT = r"D:\编程项目\SuperPhone"
DEV = "553A6EA8-29F1-43DB-94B4-D4E01D4204DC"
GW = "https://127.0.0.1:8080"
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


# ── ★ 结构型判据（与文字无关）────────────────────────────────────────
def s_bottom_nav(ts, min_blocks=3):
    """S1：底部导航带 —— 二期 page.py 的 §底部导航 同款。"""
    bot = [t for t in ts if t.get("cy", 0) > 0.93]
    return len(bot) >= min_blocks, len(bot)


def s_topbar(ts, min_blocks=2):
    """S2：顶部栏带。"""
    top = [t for t in ts if 0.03 <= t.get("cy", 0) <= 0.12]
    return len(top) >= min_blocks, len(top)


def s_dense_center(ts, min_blocks=25):
    """S3：屏幕中部文字密度（弹窗/帮助页这类密集文字页会很高）。"""
    mid = [t for t in ts if 0.15 <= t.get("cy", 0) <= 0.90]
    return len(mid) >= min_blocks, len(mid)


def describe():
    ts = texts()
    b1, n1 = s_bottom_nav(ts)
    b2, n2 = s_topbar(ts)
    b3, n3 = s_dense_center(ts)
    print("     底部带 %d 块(%s) · 顶栏 %d 块(%s) · 中部 %d 块(%s)"
          % (n1, "✓" if b1 else "✗", n2, "✓" if b2 else "✗", n3, "密" if b3 else "疏"))
    return b1, b2, b3, ts


print("=" * 96)
print("  自证判据 v3：结构特征（与文字无关）")
print("=" * 96)

print("\n  ① 当前屏幕的结构特征")
b1, b2, b3, ts = describe()
print("     屏幕文字（前 70）：%s" % blob()[:70])

print("\n  ② 清掉可能挡路的弹窗/权限框（按结构判断：中部密度高 + 有'想访问'类词才动）")
PERM_WORDS = ["想访问", "允许", "不允许", "好", "以后再说", "不再提示", "取消", "关闭"]
hit = None
for t in ts:
    s = (t.get("text") or "").strip()
    if any(w == s or w in s for w in PERM_WORDS):
        hit = t
        break
if hit and b3:
    print("     发现疑似权限/弹窗按钮「%s」@(%.3f,%.3f) → 点'不允许/取消'类优先"
          % (hit["text"], hit["cx"], hit["cy"]))
    # ★ 优先点"不允许/取消"（安全），没有才点其它
    for t in ts:
        s = (t.get("text") or "").strip()
        if s in ("不允许", "取消", "关闭"):
            print("     → 点「%s」" % s)
            gw("script.exec", {"steps": [{"op": "tap", "x": t["cx"], "y": t["cy"]}]}, tmo=60000)
            time.sleep(1.8)
            break
    else:
        print("     → 没有'不允许/取消'类词，不擅自点（避免副作用）")
else:
    print("     没有明显弹窗迹象（中部不密 或 无权限词）")

print("\n  ③ 重新看结构特征")
b1, b2, b3, ts = describe()
print("     屏幕文字（前 70）：%s" % blob()[:70])

print("\n  ④ 结论")
if b1 and not b3:
    print("     ★★ 结构上像【带底部 tab 的内容页】且中部不密 → 可能是抖音首页 ✓")
elif b1 and b3:
    print("     ⚠️ 有底部 tab 但中部很密 → 可能是【弹窗/帮助页盖在上面】✗")
else:
    print("     ✗ 没有底部导航带 → 当前不是带 tab 的页面（帮助页/设置页等）")

print()
print("  ★★ 与词判据的对比：本判据完全【不看文字内容】✓")
print("     · 不受通用词影响（「设置」在不在都无所谓）")
print("     · 不受单字误命中影响（不看字，只看块数与 y 位置）")
print("     · 对 OCR 抖动免疫（识别成「肉息」也不影响块数）")
print("  ★ 局限：它只能判「像不像带 tab 的内容页」，不能判「是不是抖音首页」——")
print("    要区分同结构的不同页，仍需文字或其他特征 → 两者应【组合】：结构先筛，文字后验")
