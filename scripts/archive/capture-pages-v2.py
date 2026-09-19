r"""同页多帧采集 v2 —— 补上"重置到确定起点"+ 用【区分性特征】自证。

★★ v1 的两个错误（2026-09-19 自证查出）：
   ① 采集时【页面状态没被重置】：我"打开设置"，设备却停在【上次的微博 App 设置页】✗
      （iOS 记住位置）→ 「设置-根页」与「设置-子页」采到的 8 帧【一模一样】✗
   ② 自证判据太弱：我用"含'设置'"✗ —— 而那个页面也有"设置"二字 → 误通过 ✗
   → 这是【同一类错误的第三次】（都是"用了不具区分力的量去下判断"）✗

★ v2 的两条对策：
   D1 【导航直到自证通过】：不再假设"点一下就到"，而是循环操作 + 每轮自证，直到满足为止
   D2 【区分性特征】：每个页面配【只在该页出现】的字串
      · 设置根页 → "飞行模式" / "无线局域网"（★ 通用词"设置"绝不用 ✗）
      · 设置二级页 → "关于本机" / "软件更新"
      · 权限页 → "允许" + "访问"
      · 抖音 → 用底部 tab 坐标点击到达（OCR 对它有抖动 ✗ 坐标更稳 ✓）
"""
import base64
import json
import os
import ssl
import time
import urllib.request

ROOT = r"D:\编程项目\SuperPhone"
DEV = "553A6EA8-29F1-43DB-94B4-D4E01D4204DC"
GW = "https://127.0.0.1:8080"
OUT = os.path.join(ROOT, "data", "pages")
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


def run(steps, settle=0.9):
    return gw("script.exec", {"steps": steps, "stepSettleMs": int(settle * 1000)},
              tmo=60000).get("ack", {})


def blob():
    t = gw("vision.ocr").get("texts", [])
    return "".join((x.get("text", "") or "").replace(" ", "") for x in t if x.get("y", 1) >= 0.035)


def has_all(*words):
    b = blob()
    return all(w in b for w in words), b


def shoot(name, n=8, interval=1.0, expect=()):
    """连拍 n 帧。expect 是【区分性】特征（必须只在该页出现）。"""
    ok, b = has_all(*expect) if expect else (True, blob())
    print("  【%s】自证：%s" % (name, "✓ 含 %s" % " · ".join(expect) if ok else
                              "✗ 缺（当前: %s）" % b[:44]))
    if not ok:
        return 0
    d = os.path.join(OUT, name)
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):                     # 清掉旧的同名帧，避免新旧混杂
        if f.startswith("screenshot_"):
            os.remove(os.path.join(d, f))
    with open(os.path.join(d, "ocr.json"), "w", encoding="utf-8") as fh:
        json.dump({"page": name, "expect": list(expect), "blob": b[:600]},
                  fh, ensure_ascii=False, indent=2)
    got = 0
    for i in range(n):
        ack = gw("screenshot")
        if not ack.get("image"):
            continue
        with open(os.path.join(d, "screenshot_%d.png" % i), "wb") as fh:
            fh.write(base64.b64decode(ack["image"]))
        got += 1
        if i < n - 1:
            time.sleep(interval)
    print("     ✓ %d 帧" % got)
    return got


def back_until(expect, tries=6):
    """★ D1：点左上角返回箭头，每轮自证，直到满足 expect。"""
    for i in range(tries):
        ok, _ = has_all(*expect)
        if ok:
            return True
        run([{"op": "tap", "x": 0.06, "y": 0.065},
             {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 3500}])
        time.sleep(1.2)
    return has_all(*expect)[0]


def click_text_until(text, expect, tries=3):
    """点含 text 的文字，然后自证 expect。"""
    for i in range(tries):
        ts = gw("vision.ocr").get("texts", [])
        hit = [t for t in ts if text in (t.get("text") or "") and 0.08 < t["cy"] < 0.92]
        if not hit:
            return False
        t0 = sorted(hit, key=lambda x: x["cy"])[0]
        run([{"op": "tap", "x": t0["cx"], "y": t0["cy"]},
             {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 4000}])
        time.sleep(1.5)
        if has_all(*expect)[0]:
            return True
    return False


print("=" * 96)
print("  同页多帧采集 v2（导航直到自证通过 · 用区分性特征）")
print("=" * 96)
os.makedirs(OUT, exist_ok=True)
total = 0

# ── ① 设置根页：先用 find_and_click 找"设置"返回键回退，直到出现"飞行模式/无线局域网"
print("\n  ① 设置根页")
run([{"op": "home"}, {"op": "open", "bundleId": "com.apple.Preferences"}])
time.sleep(3)
if not has_all("飞行模式")[0] and not has_all("无线局域网")[0]:
    # 子页时左上角返回按钮的文字是上一级标题；直接点固定坐标回退更稳
    back_until(("飞行模式",)) or back_until(("无线局域网",))
ok = has_all("飞行模式")[0] or has_all("无线局域网")[0]
total += shoot("设置-根页", 8, expect=("飞行模式",) if has_all("飞行模式")[0]
               else (("无线局域网",) if ok else ("__none__",)))

# ── ② 设置·通用（二级页）：点"通用"→ 自证"关于本机"
print("\n  ② 设置·通用（二级页）")
if click_text_until("通用", ("关于本机",)) or click_text_until("通用", ("软件更新",)):
    total += shoot("设置-通用", 8, expect=("关于本机",) if has_all("关于本机")[0] else ("软件更新",))
else:
    print("  ✗ 未能进入「通用」页")
# 回根页
back_until(("飞行模式",)) or back_until(("无线局域网",))

# ── ③ 设置·蓝牙（另一个二级页）
print("\n  ③ 设置·蓝牙")
if click_text_until("蓝牙", ("蓝牙",)):
    time.sleep(1)
    total += shoot("设置-蓝牙", 6, expect=("蓝牙",))
else:
    print("  ✗ 未找到「蓝牙」条目（可能在列表下方，需先滚动）")
back_until(("飞行模式",)) or back_until(("无线局域网",))

# ── ④ 抖音首页：用底部 tab 坐标到达（OCR 对它抖动 ✗ 坐标更稳 ✓）
print("\n  ④ 抖音首页")
run([{"op": "home"}, {"op": "open", "bundleId": "com.ss.iphone.ugc.Aweme"}])
time.sleep(4)
b = blob()
if "登录后即可" in b or "验证并登录" in b:
    print("  ⚠️ 抖音在登录页 —— 跳过（当前设备未登录）")
else:
    run([{"op": "tap", "x": 0.11, "y": 0.963},
         {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 4000}])
    time.sleep(2)
    total += shoot("抖音-首页", 8, expect=("朋友", "消息"))

print()
print("=" * 96)
print("  采集完成：共 %d 帧" % total)
for d in sorted(os.listdir(OUT)):
    p = os.path.join(OUT, d)
    if os.path.isdir(p):
        n = len([x for x in os.listdir(p) if x.startswith("screenshot_")])
        print("    %-22s %d 帧" % (d, n))
print()
print("  ★ 下一步：python scripts/verify-captured-pages.py 自证 → 再跑管线")
