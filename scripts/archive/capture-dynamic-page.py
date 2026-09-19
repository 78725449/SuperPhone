r"""动态页采样 v4 —— ★ 让 stability 真正测"跨内容的稳定"。

★★ 为什么必须改（2026-09-19 实测出的方法论问题）：
   v3 采抖音首页时是【连拍 8 帧，间隔 1 秒】→ 8 帧全在【同一个视频】上 ✗
   结果 stability 把"视频标题/字幕"也判成 8/8 稳定 ✗ ——
   那是【内容】，换个视频就变，却被误判为【页面结构】✗

★ 根因：stability 的语义【由采样协议决定】✗
   · 连拍 1 秒 → 测的是"瞬时稳定"✗
   · 要测"跨内容稳定"→ ★ 采样必须【跨越内容的自然变化】✓

★ 对抖音：★ 上滑 = 换下一个视频 ✓（一期验证过的确定行为）
   → 每采一帧就切换一次 → 8 帧跨越 8 个视频 ✓
   → 这时【仍然 8/8 稳定】的才是真正的【页面结构】（顶栏/底部 tab/侧边按钮）✓
   → 而视频标题/字幕会掉下去 ✓

★ 这也顺带给出了页面签名的【正确过滤条件】：
   在"内容充分变化"的样本上仍稳定的元素 = 可依赖结构 ✓
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
OUT = os.path.join(ROOT, "data", "pages-dynamic")
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


def find_text(sub, ymin=0.04, ymax=0.96):
    ts = gw("vision.ocr").get("texts", [])
    out = []
    for t in ts:
        s = re.sub(r"\s+", "", t.get("text") or "")
        if sub in s and ymin <= t.get("cy", 0) <= ymax:
            out.append(t)
    return sorted(out, key=lambda x: x["cy"])


print("=" * 96)
print("  动态页采样 v4 —— ★ 帧间切换内容，让 stability 测「跨内容的稳定」")
print("=" * 96)
os.makedirs(OUT, exist_ok=True)

# 回主屏 → 打开抖音（主屏点图标：bundleId 打开系统 App 不可靠，但抖音是第三方，可先试）
run([{"op": "home"}])
time.sleep(2.5)
hit = find_text("抖音", 0.04, 0.92)
if hit:
    print("  主屏点「抖音」@(%.3f,%.3f)" % (hit[0]["cx"], hit[0]["cy"]))
    run([{"op": "tap", "x": hit[0]["cx"], "y": hit[0]["cy"]},
         {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 5000}])
    time.sleep(4)
else:
    print("  主屏未找到「抖音」，改用 bundleId")
    run([{"op": "open", "bundleId": "com.ss.iphone.ugc.Aweme"}])
    time.sleep(4.5)

b = blob()
print("  当前屏幕：%s" % b[:70])
if "登录后即可" in b or "验证并登录" in b:
    print("  ⚠️ 抖音在登录页 —— 无法采动态页")
    raise SystemExit(1)

# 用底部 tab 坐标确保在首页
run([{"op": "tap", "x": 0.11, "y": 0.963},
     {"op": "wait_for", "expect": {"hashDiff": True}, "timeoutMs": 4000}])
time.sleep(2)
b = blob()
print("  首页自证：%s（含'朋友':%s · 含'消息':%s）" % (b[:44], "朋友" in b, "消息" in b))

d = os.path.join(OUT, "抖音-首页-跨视频")
os.makedirs(d, exist_ok=True)
for f in os.listdir(d):
    if f.startswith("screenshot_"):
        os.remove(os.path.join(d, f))

N = 8
titles = []
got = 0
for i in range(N):
    ack = gw("screenshot")
    if ack.get("image"):
        with open(os.path.join(d, "screenshot_%d.png" % i), "wb") as fh:
            fh.write(base64.b64decode(ack["image"]))
        got += 1
    t = blob()
    titles.append(t[:34])
    print("     帧%d ✓ 画面开头: %s" % (i, t[:34]))
    if i < N - 1:
        # ★ 关键：上滑 = 换下一个视频（一期验证过的确定行为）
        run([{"op": "swipe", "x1": 0.5, "y1": 0.78, "x2": 0.5, "y2": 0.22, "duration": 0.35}])
        time.sleep(2.2)

# 自证：8 帧的可见文字应该【各不相同】（说明内容确实变了 ✓）
uniq = len(set(titles))
print()
print("  采集 %d 帧 · 画面各不相同的有 %d 个" % (got, uniq))
if uniq >= max(3, got - 1):
    print("  ★★ 自证通过：帧间内容【确实在变】→ stability 有资格测「跨内容稳定」✓✓✓")
else:
    print("  ⚠️ 画面变化不足（%d/%d 不重复）→ 上滑可能没换视频 ✗" % (uniq, got))

with open(os.path.join(d, "ocr.json"), "w", encoding="utf-8") as fh:
    json.dump({"page": "抖音-首页-跨视频", "expect": ["朋友", "消息"],
               "sampling": "每帧间上滑换视频（跨越内容变化）",
               "frameHeads": titles}, fh, ensure_ascii=False, indent=2)

print()
print("=" * 96)
print("  下一步")
print("=" * 96)
print("  ★ python scripts/build-page-assets.py 会读 data/pages-dynamic/ 吗？—— 不会 ✗")
print("    需先把 PAGES 常量改为含 pages-dynamic，或将本目录并入 data/pages/")
print("  ★ 然后对比：")
print("    · 连拍采的（v3）→ 31/32 稳定（★ 含视频标题，是假的稳定 ✗）")
print("    · 换视频采的（v4）→ 期望只有顶栏/底部 tab/侧边按钮remain稳定 ✓")
print("      —— ★ 这个差集就是「内容 vs 结构」的分界线 ✓✓✓")
