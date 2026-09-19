r"""控制变量实验：hashDiff 到底是"时序敏感"还是"画面真的没变"？

★★ 为什么要做（2026-09-19）：
   我在 §9.2 写了"hashDiff 时序敏感，tab 切换必踩"，并据此提出"需要 stateChanged 断言"。
   但读源码发现【矛盾】：
     · baseHash 是【本步动作前】的基线（TRCapabilityRegistry.mm L785），不是"等待前"✗
     · wait_for 是【轮询】（250ms 间隔，L745-753）→ 不是"等一次事件"✗
   ⇒ 若基线和轮询都如源码所示，那"变化发生在等待之前就错过"这个机制【不成立】✗
   ★ 而我此前从未做过控制变量实验就下了结论 —— 正是我这一轮反复犯的错 ✗
   → ★ 本脚本用三组对照把机制钉死。

   A：tap + wait_for{hashDiff}            → 看实测失败时的 detail（distance 是多少）
   B：tap 后不等待，直接比【动作前后】pHash → 看画面到底变了没（★ 关键对照）
   C：同一位置连点两次                    → 第二次"没变"应正确报 NO（证明判据会报假）

★ 判读：
   · 若 A 失败而 B 显示"确实变了" → 说明 hashDiff 判据【不可靠】✓（但不是"时序"而是别的原因）
   · 若 A 失败且 B 显示"没变"     → 说明【画面真的没变】，我的"时序敏感"结论是错的 ✗
"""
import json
import ssl
import time
import urllib.request

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


def nav():
    return sum(1 for t in gw("vision.ocr").get("texts", [])
               if t.get("y", 1) >= 0.035 and t.get("cy", 0) > 0.93)


def blob():
    return "".join((t.get("text", "") or "").replace(" ", "")
                   for t in gw("vision.ocr").get("texts", []) if t.get("y", 1) >= 0.035)


def hamming(a, b):
    if not a or not b:
        return -1
    return bin(int(a, 16) ^ int(b, 16)).count("1")


print("=" * 96)
print("  控制变量实验：hashDiff 是「时序敏感」还是「画面真的没变」？")
print("=" * 96)
print("\n  当前：底部带 %d 块 · %s" % (nav(), blob()[:60]))

print("\n  ── A：tap tab-2 + wait_for{hashDiff}（复现我观察到的失败）──")
for i in range(3):
    a = gw("script.exec", {"steps": [{"op": "tap", "x": 0.302, "y": 0.963},
                                     {"op": "wait_for", "expect": {"hashDiff": True},
                                      "timeoutMs": 5000}],
                           "stepSettleMs": 900}, tmo=60000)
    for s in (a.get("steps") or []):
        print("     第%d次 %s. %-8s %-4s %s"
              % (i + 1, s.get("index"), s.get("op"),
                 "OK" if s.get("ok") else "FAIL", str(s.get("detail"))[:66]))
    time.sleep(2)

print("\n  ── B：★ 关键对照 —— tap 后不等待，直接比「动作前 vs 动作后」pHash ──")
for i in range(3):
    h1 = gw("screen.hash").get("hash")
    gw("script.exec", {"steps": [{"op": "tap", "x": 0.900, "y": 0.963}]}, tmo=60000)
    time.sleep(2.4)
    h2 = gw("screen.hash").get("hash")
    d = hamming(h1, h2)
    print("     第%d次 前 %s → 后 %s · 汉明 %d  %s"
          % (i + 1, (h1 or "?")[:10], (h2 or "?")[:10], d,
             "★ 画面确实变了" if d > 5 else "✗ 画面没变"))
    time.sleep(1.5)

print("\n  ── C：同一位置连点两次（第二次应正确报「没变」）──")
for i in range(2):
    a = gw("script.exec", {"steps": [{"op": "tap", "x": 0.900, "y": 0.963},
                                     {"op": "wait_for", "expect": {"hashDiff": True},
                                      "timeoutMs": 4000}],
                           "stepSettleMs": 900}, tmo=60000)
    for s in (a.get("steps") or []):
        if s.get("op") == "wait_for":
            print("     第%d次 %s %s" % (i + 1, "OK" if s.get("ok") else "FAIL",
                                         str(s.get("detail"))[:66]))
    time.sleep(2.5)

print()
print("=" * 96)
print("  判读")
print("=" * 96)
print("  ★ 若 A 全 FAIL 而 B 显示「画面确实变了」")
print("    → hashDiff 判据【不可靠】✓，但根因不是「时序」而是【阈值/哈希特性】")
print("      （detail 里的 distance 会给出线索：distance=0 说明两个 pHash 完全相同）")
print("  ★ 若 A 全 FAIL 且 B 显示「画面没变」")
print("    → ★ 画面真的没变 → 我的「时序敏感」结论是错的 ✗，应改为「操作没生效」")
print("  ★ C 若第二次报 OK → 说明判据【把没变报成变了】→ 那是更严重的不可靠 ✗")
