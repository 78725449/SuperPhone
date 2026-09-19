r"""同页多帧采集 v3 —— 修掉 v2 查出的两个真问题。

★★ v2 的诊断结论（2026-09-19，自证挖出）：
   ① ★ `open bundleId=com.apple.Preferences` 【完全没生效】✗
      · 设备 21 个已装 App 里【没有它】（app.list 不列系统 App；
        主屏上明明有"设置"图标，但拿不到它的 bundleId）
      · home 后是主屏，open 后【仍是主屏】；自证"飞行模式"全 False
      → ★ 正解：★ 在【主屏】用 OCR 找到"设置"图标文字，点它 ✓
   ② ★ OCR 文字匹配不能用 `==` ✗ —— OCR 的 text 常带空格/杂字，
      实测用 `== "设置"` 命中 0 个，而屏幕上确实有"设置"
      → ★ 正解：strip 掉空白后用【包含】匹配 ✓

★ 本版的三条对策：
   D1 【先重置到确定起点】：每次导航前先 home，不假设"上一步之后应该在哪"✓
   D2 【用图标文字打开 App】：find_text(名字) → tap ✓（不用 bundleId ✗）
   D3 【区分性特征自证】：每页配【只在该页出现】的字串，绝不使用通用词 ✓
"""
import base64
import json
import os
import re
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


def find_text(sub, ymin=0.04, ymax=0.96):
    """★ D2：strip 后【包含】匹配（不用 == ✗ —— OCR 的 text 常带空格/杂字）。"""
    ts = gw("vision.ocr").get("texts", [])
    out = []
    for t in ts:
        s = re.sub(r"\s+", "", t.get("text") or "")
        if sub in s and ymin <= t.get("cy", 0) <= ymax:
            out.append(t)
    return sorted(out, key=lambda x: x["cy"])


def home_reset():
    """★ D1：强制回到确定起点（主屏）。"""
    run([{"op": "home"}])
    time.sleep(2.5)


def open_app(icon_text, expect, tries=2):
    """在主屏点【图标文字】打开 App，并用 expect 自证。"""
    for i in range(tries):
        home_reset()
        hit = find_text(icon_text, 0.04, 0.92)
        if not hit:
            print("     ✗ 主屏上找不到「%s」" % icon_text)
            return False
        t0 = hit[0]
        print("     点「%s」@(%.3f,%.3f)" % (re.sub(r"\s+", "", t0.get("text") or ""),
                                            t0["cx"], t0["cy"]))
        run([{"op": "tap", "x": t0["cx"], "y": t0["cy"]},
             {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 5000}])
        time.sleep(3.5)
        ok, b = has_all(*expect)
        if ok:
            return True
        print("     ⚠️ 打开后自证不通过（当前: %s），重试" % b[:44])
    return False


def shoot(name, n=8, interval=1.0, expect=()):
    ok, b = has_all(*expect) if expect else (True, blob())
    print("     自证：%s" % ("✓ 含 %s" % " · ".join(expect) if ok else "✗ 缺（当前: %s）" % b[:44]))
    if not ok:
        return 0
    d = os.path.join(OUT, name)
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d):
        if f.startswith("screenshot_"):
            os.remove(os.path.join(d, f))
    with open(os.path.join(d, "ocr.json"), "w", encoding="utf-8") as fh:
        json.dump({"page": name, "expect": list(expect), "blob": b[:600]},
                  fh, ensure_ascii=False, indent=2)
    got = 0
    for i in range(n):
        ack = gw("screenshot")
        if ack.get("image"):
            with open(os.path.join(d, "screenshot_%d.png" % i), "wb") as fh:
                fh.write(base64.b64decode(ack["image"]))
            got += 1
        if i < n - 1:
            time.sleep(interval)
    print("     ✓ %d 帧" % got)
    return got


def back_once():
    run([{"op": "tap", "x": 0.06, "y": 0.065},
         {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 3500}])
    time.sleep(1.3)


print("=" * 96)
print("  同页多帧采集 v3（home 重置 · 点图标开 App · 区分性自证）")
print("=" * 96)
os.makedirs(OUT, exist_ok=True)
total = 0

# ── ① 设置根页：主屏点"设置"图标 → 自证"飞行模式"（★ 区分性）
print("\n  ① 设置·根页")
GATE = ("飞行模式",)          # ★ 只出现在设置根页
if open_app("设置", GATE):
    total += shoot("设置-根页", 8, expect=GATE)

    # ── ② 设置·通用（二级页）
    print("\n  ② 设置·通用（二级页）")
    hit = find_text("通用", 0.08, 0.90)
    if hit:
        run([{"op": "tap", "x": hit[0]["cx"], "y": hit[0]["cy"]},
             {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 4000}])
        time.sleep(1.8)
        if has_all("关于本机")[0]:
            total += shoot("设置-通用", 8, expect=("关于本机",))
        else:
            print("     ✗ 进「通用」后自证不通过")
        back_once()
    else:
        print("     ✗ 根页上没找到「通用」")

    # ── ③ 设置·蓝牙
    print("\n  ③ 设置·蓝牙")
    hit = find_text("蓝牙", 0.08, 0.90)
    if not hit:
        print("     ⚠️ 不在首屏 —— 上滑找一次")
        run([{"op": "swipe", "x1": 0.5, "y1": 0.75, "x2": 0.5, "y2": 0.35, "duration": 0.4}])
        time.sleep(1.5)
        hit = find_text("蓝牙", 0.08, 0.90)
    if hit:
        run([{"op": "tap", "x": hit[0]["cx"], "y": hit[0]["cy"]},
             {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 4000}])
        time.sleep(1.8)
        # ★ 蓝牙页的区分性特征：页标题是"蓝牙"，且含"其他设备"或"现在可被发现"
        b = blob()
        if "蓝牙" in b and ("其他设备" in b or "可被发现" in b or "隔空投送" in b):
            exp = ("其他设备",) if "其他设备" in b else (("可被发现",) if "可被发现" in b else ("隔空投送",))
            total += shoot("设置-蓝牙", 6, expect=exp)
        else:
            print("     ⚠️ 进「蓝牙」后特征不符（当前: %s）→ 按当前内容采" % b[:40])
            total += shoot("设置-二级页", 6, expect=())
        back_once()
    else:
        print("     ✗ 没找到「蓝牙」")
else:
    print("  ✗ 未能打开设置")

# ── ④ 抖音首页（用底部 tab 坐标到达 ✓ 已验证有效）
print("\n  ④ 抖音·首页")
if open_app("抖音", ("朋友",)) or open_app("抖音", ()):
    run([{"op": "tap", "x": 0.11, "y": 0.963},
         {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 4000}])
    time.sleep(2)
    b = blob()
    if "登录后即可" in b or "验证并登录" in b:
        print("     ⚠️ 处于登录页 —— 跳过")
    else:
        total += shoot("抖音-首页", 8, expect=("朋友", "消息"))

print()
print("=" * 96)
print("  采集完成：共 %d 帧" % total)
for d in sorted(os.listdir(OUT)):
    p = os.path.join(OUT, d)
    if os.path.isdir(p):
        n = len([x for x in os.listdir(p) if x.startswith("screenshot_")])
        o = os.path.join(p, "ocr.json")
        exp = json.load(open(o, encoding="utf-8")).get("expect") if os.path.exists(o) else None
        print("    %-20s %d 帧 · 自证特征 %s" % (d, n, exp))
print()
print("  ★ 下一步：python scripts/verify-captured-pages.py")
