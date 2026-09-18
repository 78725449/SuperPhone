"""实证：布局特征对页面有没有区分度？（用现有 vision.ocr 的坐标，零新能力）

背景：纯文字版页面签名只剩 4 个词、得分卡在 0.6~0.8。用户提出"能不能用布局+OCR 多元素"。
本脚本先【实测】而不是先设计 —— 看几个候选布局特征在已知页面上的取值是否稳定、是否有区分度。
"""
import json
import ssl
import urllib.request

DEV = "553A6EA8-29F1-43DB-94B4-D4E01D4204DC"
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
NOISE_Y_MAX = 0.035


def ocr():
    rq = urllib.request.Request(
        "https://127.0.0.1:8080/api/devices/%s/invoke" % DEV,
        data=json.dumps({"cap": "vision.ocr", "params": {}}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(rq, timeout=90, context=ctx) as r:
        return json.load(r).get("ack", {}).get("texts", [])


def features(texts):
    real = [t for t in texts if t.get("y", 1) >= NOISE_Y_MAX]
    n = len(real)
    bottom = [t for t in real if t.get("y", 0) > 0.90]
    kbd = [t for t in real if t.get("y", 0) > 0.85]
    top = [t for t in real if 0.03 <= t.get("y", 0) <= 0.12]
    mid = [t for t in real if 0.15 < t.get("y", 0) < 0.85]
    return {
        "块数": n,
        "底部(y>0.90)": len(bottom),
        "键盘区(y>0.85)": len(kbd),
        "顶栏(0.03-0.12)": len(top),
        "中部(0.15-0.85)": len(mid),
        "★底部导航": "有" if len(bottom) >= 3 else "无",
        "★键盘": "有" if len(kbd) >= 8 else "无",
        "★顶栏": "有" if len(top) >= 2 else "无",
    }


print("=" * 96)
print("  布局特征实测（同一页面连续取 3 帧，看稳不稳）")
print("=" * 96)
print("  %-20s %s" % ("特征", " · ".join("帧%d" % (i + 1) for i in range(3))))
print("  " + "-" * 92)

frames = [features(ocr()) for _ in range(3)]
keys = list(frames[0].keys())
for k in keys:
    vals = [str(f[k]) for f in frames]
    stable = "✓ 稳" if len(set(vals)) == 1 else "✗ 不稳"
    print("  %-20s %-30s %s" % (k, " · ".join(vals), stable))

print()
print("  ★ 提示："
      "'不稳'的特征不能当签名项（多采样会自动滤掉它）；")
print("    '稳'的特征才有资格进签名 —— 而多帧稳定性正是【多采样机制】能自动筛的")
