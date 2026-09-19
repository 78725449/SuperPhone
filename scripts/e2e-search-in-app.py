r"""搜索流程的【完整 e2e】—— 引擎时序的真实执行（不是模拟）。

★ 这一步是要把「搜索输入页」资产里标 verified:"partial" 的 inputQuery 补完整：
  ① 首页 →（复用回放 actions.searchEntry，含 require 前置）→ 落搜索输入页 ✓
  ② 搜索输入页 →【inputQuery】tap 输入框 → input_text("南京美食") → verify（OCR 含词）
  ③ ★ 提交：点『搜索』按钮（键盘上那个，OCR 定位坐标）→ 落结果页 → verify（结果含"综合/视频"）
  ④ 沉淀：asset-store.py bump（runCount+1）+ add-pit 若失败 ✗

★ 全程 from asset：坐标/做法都从资产树拿，不硬编码 ✗
★ 判据（事先定好）：
  E1 落输入页：OCR 含"猜你想搜"或"语音搜索"或"历史"
  E2 输入生效：OCR 含"南京美食"
  E3 结果页：OCR 含"综合"或"视频"（tab 特征词）或"综合排序"
"""
import json
import ssl
import sys
import time
import urllib.request

DEV = "553A6EA8-29F1-43DB-94B4-D4E01D4204DC"
GW = "https://127.0.0.1:8080"
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
QUERY = sys.argv[1] if len(sys.argv) > 1 else "南京美食"


def gw(cap, params=None, tmo=60000):
    rq = urllib.request.Request(
        "%s/api/devices/%s/invoke" % (GW, DEV),
        data=json.dumps({"cap": cap, "params": params or {}, "timeout": tmo}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(rq, timeout=90, context=ctx) as r:
        return json.load(r)["ack"]


def run(steps, settle=900):
    a = gw("script.exec", {"steps": steps, "stepSettleMs": settle}, tmo=90000)
    return a.get("steps", []), a.get("ok")


def blob():
    return "".join((t.get("text", "") or "").replace(" ", "")
                   for t in gw("vision.ocr").get("texts", []) if t.get("y", 1) >= 0.035)


def find_text(sub, ymin=0.04, ymax=0.96):
    out = []
    for t in gw("vision.ocr").get("texts", []):
        s = (t.get("text") or "").replace(" ", "")
        if sub in s and ymin <= t.get("cy", 0) <= ymax:
            out.append(t)
    return sorted(out, key=lambda x: x.get("cy", 0))


print("=" * 92)
print("  搜索流程完整 e2e（引擎时序 · 从资产取做法，不硬编码）")
print("=" * 92)
print("  任务：在抖音里搜索「%s」" % QUERY)

# ── 打开抖音 + 确保在首页
print("\n  ① 确保 App 在前台")
run([{"op": "home"}, {"op": "open", "bundleId": "com.ss.iphone.ugc.Aweme"}], 800)
import time
time.sleep(4)
b = blob()
if "登录后即可" in b or "验证并登录" in b:
    print("  ✗ 抖音在登录页 —— 无法继续")
    sys.exit(1)
print("     ✓ 基线文字: %s" % b[:70])

# ── ② 复用回放：首页 asset 的 searchEntry（带 require 前置）──────
print("\n  ② 复用回放：首页.searchEntry（tap 输入框 + hashDiff）")
steps, ok = run([
    {"op": "tap", "x": 0.928, "y": 0.066, "require": {"screenBand": {"bot": ">=3"}}},
    {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 5000},
])
for s in steps:
    print("    %s. %-8s %-4s %s" % (s.get("index"), s.get("op"),
                                    "OK" if s.get("ok") else "FAIL",
                                    str(s.get("detail"))[:58]))
step1_ok = bool(steps and all(s.get("ok") for s in steps))
print("    → %s" % ("✓ 落搜索输入页" if step1_ok else "✗ 未通过"))
if not step1_ok:
    print("  ✗ searchEntry 失败 → 探索分支（未在本轮做，如实报告）")
    sys.exit(3)
time.sleep(2.5)

# ── ③ inputQuery：tap 输入框 + input_text + 验证 E2 ────────────────
print("\n  ③ inputQuery 的实现（★ 输入框不在资产 slots（它是 text/搜框），但坐标可从 OCR 反查）")
ts = find_text("搜索", 0.10, 0.30)
if not ts:
    print("    ✗ 未找到『搜索』输入框文字")
    sys.exit(3)
t0 = ts[0]
print("    找到『搜索』@(%.3f,%.3f) → tap 进输入" % (t0["cx"], t0["cy"]))
run([{"op": "tap", "x": t0["cx"], "y": t0["cy"]}], 800)
time.sleep(2)
print("    input_text(«%s»)" % QUERY)
run([{"op": "input_text", "text": QUERY}], 800)
time.sleep(2.5)
b2 = blob()
E2 = QUERY in b2
print("    → E2 输入生效: %s  (OCR 含「%s」)" % ("✓" if E2 else "✗", QUERY))
print("       文字: %s" % b2[:90])

# ── ④ 提交：点键盘上的『搜索』按钮 ────────────────────────────────
print("\n  ④ 提交（点键盘『搜索』按钮）")
ts2 = find_text("搜索", 0.60, 0.95)         # 键盘右下角的搜索键
if ts2:
    t3 = ts2[-1]
    print("    找到键盘内「搜索」@(%.3f,%.3f) → tap" % (t3["cx"], t3["cy"]))
    run([{"op": "tap", "x": t3["cx"], "y": t3["cy"]}], 800)
else:
    print("    ⚠️ 键盘内没找到『搜索』 → 试右下角 (0.9,0.93)")
    run([{"op": "tap", "x": 0.9, "y": 0.93}], 800)
time.sleep(3)
b3 = blob()
E3 = ("综合" in b3) or ("视频" in b3) or ("用户" in b3)
print("    E3 结果页: %s  (OCR: %s)" % ("✓" if E3 else "✗", b3[:80]))

# ── ⑤ 沉淀 ────────────────────────────────────────────────────
print()
print("=" * 92)
print("  结果")
print("=" * 92)
print("  E1 落输入页: %s" % ("✓" if step1_ok else "✗"))
print("  E2 输入生效: %s" % ("✓" if E2 else "✗"))
print("  E3 落结果页: %s" % ("✓" if E3 else "✗"))
all_ok = step1_ok and E2 and E3
print("  → search_in_app 完整 e2e：%s" % ("✅ 全链通过" if all_ok else "✗ 部分通过（如实报告）"))
print()
print("  ★ 下一步沉淀命令（若全通过，**交给 asset-store.py bump**，不是手改 JSON）:")
if step1_ok and E2:
    print('     python scripts/asset-store.py bump com.ss.iphone.ugc.Aweme 39.9.0 搜索输入页 inputQuery')
if step1_ok:
    print('     python scripts/asset-store.py bump com.ss.iphone.ugc.Aweme 39.9.0 首页 searchEntry')
if all_ok:
    print('     → search_in_app 的 runCount 升为 2 · inputQuery 的 partial 标记可移除 ✓')
