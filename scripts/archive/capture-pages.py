r"""同页多帧采集 —— 补上"页面级资产"缺的数据。

★★ 为什么需要它（2026-09-19 实测结论）：
   现有元素表来自"漫游任务"和"一期抖音截图" → ★ 每页只有 1~2 帧 ✗
   而页面级资产的价值【恰恰在 stability】（"哪些元素在这个页面上稳定存在"）——
   分母太小就没有参考价值。→ 必须先采【同一页面的多帧】。

★ 采集方式：导航到目标页 → ★ 停留并连拍 N 帧（间隔 ~1s，无需再操作）✓
  这比"跑任务顺便截"更可控，也不会引入任务本身的状态变化。

★ 输出结构（对齐现有管线的读取约定 `<dir>/screenshot_N.png`）：
   data/pages/<页面名>/screenshot_0.png … screenshot_N.png

★ 同时抓一帧 OCR 存成同一目录的 ocr.json（设备端 Apple Vision ✓ 与截图同刻 ✓），
  作为"这一页确实是什么"的证据 —— 因为我看不到图，只能靠 OCR 文字自证 ✗
"""
import base64
import json
import os
import ssl
import sys
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
    return gw("script.exec", {"steps": steps, "stepSettleMs": int(settle * 1000)}, tmo=60000).get("ack", {})


def blob():
    t = gw("vision.ocr").get("texts", [])
    return "".join((x.get("text", "") or "").replace(" ", "") for x in t if x.get("y", 1) >= 0.035)


def shoot_page(name, n=8, interval=1.0, expect=None):
    """连拍 n 帧。expect 用于自证"确实在这一页"（我看不到图，必须靠文字自证）。"""
    d = os.path.join(OUT, name)
    os.makedirs(d, exist_ok=True)
    b = blob()
    ok = (expect is None) or all(e in b for e in expect)
    print("  【%s】" % name)
    if expect is None:
        print("     自证：无前置要求（这页按当前实际内容命名）")
    elif ok:
        print("     自证：✓ 含 %s" % " · ".join(expect))
    else:
        print("     自证：✗ 不含 %s（当前: %s）" % (" · ".join(expect), b[:40]))
    if not ok:
        return 0
    with open(os.path.join(d, "ocr.json"), "w", encoding="utf-8") as fh:
        json.dump({"page": name, "expect": expect or [], "blob": b[:600]}, fh,
                  ensure_ascii=False, indent=2)
    got = 0
    for i in range(n):
        ack = gw("screenshot")
        img = ack.get("image")
        if not img:
            print("     帧%d ✗ 无图" % i)
            continue
        with open(os.path.join(d, "screenshot_%d.png" % i), "wb") as fh:
            fh.write(base64.b64decode(img))
        got += 1
        print("     帧%d ✓ %s" % (i, ("%sx%s" % (ack.get("width"), ack.get("height")))))
        if i < n - 1:
            time.sleep(interval)
    return got


print("=" * 96)
print("  同页多帧采集（每页 8 帧，间隔 1s）")
print("=" * 96)
os.makedirs(OUT, exist_ok=True)

# 起点：回主屏并打开设置
print("\n  准备：回主屏 → 打开设置")
run([{"op": "home"}, {"op": "open", "bundleId": "com.apple.Preferences"}])
time.sleep(3)

total = 0

# ① 设置·根页（列表型）
total += shoot_page("设置-根页", 8, expect=["设置"])
# ② 设置·子页（二级列表）—— 点列表里第一个像样的条目
ts = gw("vision.ocr").get("texts", [])
cand = [t for t in ts if 0.10 < t["cy"] < 0.55 and len((t.get("text") or "").strip()) >= 2]
if cand:
    t0 = sorted(cand, key=lambda x: x["cy"])[0]
    nm = (t0.get("text") or "").strip()[:6]
    print("\n  进入子页：点「%s」" % nm)
    run([{"op": "tap", "x": t0["cx"], "y": t0["cy"]},
         {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 4000}])
    time.sleep(2)
    total += shoot_page("设置-子页-%s" % nm, 8, expect=None)
    # 返回根页
    run([{"op": "tap", "x": 0.06, "y": 0.065},
         {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 4000}])
    time.sleep(1.5)

# ③ 抖音（首页，若已登录；未登录则为登录页 —— 无论哪个都当一页采 ✓ 但那不是我们要的）
print("\n  准备：打开抖音")
run([{"op": "home"}, {"op": "open", "bundleId": "com.ss.iphone.ugc.Aweme"}])
time.sleep(4)
b = blob()
if "登录后即可" in b or "验证并登录" in b:
    print("  ⚠️ 抖音处于登录页 —— 跳过（不是目标页面）")
else:
    total += shoot_page("抖音-首页", 8, expect=None)

print()
print("=" * 96)
print("  采集完成：共 %d 帧" % total)
print("  目录：%s" % OUT)
for d in sorted(os.listdir(OUT)):
    p = os.path.join(OUT, d)
    if os.path.isdir(p):
        n = len([x for x in os.listdir(p) if x.startswith("screenshot_")])
        print("    %-24s %d 帧" % (d, n))
print()
print("  ★ 下一步：重跑管线（它会读 data/pages/<页面>/screenshot_*.png）")
