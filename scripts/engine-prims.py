r"""执行引擎的【机械附肢】—— 给引擎（模型）用的确定性原语驱动。

★★ 定位（2026-09-19 用户确立，勿混淆）：
   · 正式流水线的【决策点全在模型」—— 模型是执行引擎（意图分析/查库裁决/监督纠错）
   · 本脚本只是【机械采集/执行的附肢】：帮引擎做"采集基线、下发执行"这些机械动作
   · ✗ 它不是流水线主体 ✗ —— 见《定案》§十

用法：
  python scripts/engine-prims.py status            网关/设备状态
  python scripts/engine-prims.py baseline [out.png]  截图存盘 + OCR + 结构带计数
  python scripts/engine-prims.py exec --steps '<json>' [--wantband] [--settle N]
                                                   下发 script.exec（wantBand=true 时 trace 带结构带）

★ 结构带口径（与设备端 trScriptScreenBand 对齐）：y<0.035 状态栏不计 ·
  y<=0.12 顶栏 · y>0.93 底部 · 其余中部
"""
import base64
import json
import os
import ssl
import sys
import urllib.request

ROOT = r"D:\编程项目\SuperPhone"
DEV = "553A6EA8-29F1-43DB-94B4-D4E01D4204DC"
GW = "https://127.0.0.1:8080"
SHOT = os.path.join(ROOT, "data", "engine-baselines")
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


def gw(cap, params=None, tmo=60000, wait=120):
    rq = urllib.request.Request(
        "%s/api/devices/%s/invoke" % (GW, DEV),
        data=json.dumps({"cap": cap, "params": params or {}, "timeout": tmo}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(rq, timeout=wait, context=ctx) as r:
        return json.load(r)["ack"]


def band_from_ocr(rows):
    top = mid = bot = 0
    for r in rows:
        cy = r.get("cy", 0)
        if cy < 0.035:
            continue
        if cy <= 0.12:
            top += 1
        elif cy > 0.93:
            bot += 1
        else:
            mid += 1
    return {"top": top, "mid": mid, "bot": bot, "total": top + mid + bot}


def status():
    with urllib.request.urlopen("https://127.0.0.1:8080/api/devices", timeout=15, context=ctx) as r:
        d = json.load(r)["devices"][0]
    return {"online": d.get("online"), "name": d.get("name"), "controlState": d.get("controlState")}


def baseline(save=None):
    ack = gw("screenshot")
    img = (ack.get("image") or "")
    if img and save:
        with open(save, "wb") as fh:
            fh.write(base64.b64decode(img))
    ocr = gw("vision.ocr", tmo=20000)
    rows = [t for t in ocr.get("texts", []) if t.get("y", 1) >= 0.035]
    band = band_from_ocr(rows)
    heads = "".join((r.get("text") or "").replace(" ", "") for r in rows)
    return {"image": os.path.basename(save) if save else None, "band": band,
            "textHead": "".join(rows[0]["text"] for _ in [0]) and \
                        "".join((r.get("text") or "").replace(" ", "") for r in rows)[:120]}


def exec_steps(steps, settle=900, wantband=False):
    p = {"steps": steps, "stepSettleMs": settle}
    if wantband:
        p["wantBand"] = True
    return gw("script.exec", p, tmo=120000)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "status":
        print(json.dumps(status(), ensure_ascii=False))
    elif cmd == "baseline":
        out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
            ROOT, "data", "engine-baselines", "baseline.png")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        r = baseline(out)
        print(json.dumps(r, ensure_ascii=False, indent=1))
    elif cmd == "exec":
        steps = None
        want = False
        settle = 900
        args = sys.argv[2:]
        i = 0
        while i < len(args):
            if args[i] == "--steps":
                steps = json.loads(args[i + 1]); i += 2
            elif args[i] == "--wantband":
                want = True; i += 1
            elif args[i] == "--settle":
                settle = int(args[i + 1]); i += 2
            else:
                i += 1
        r = gw("script.exec", {
            "steps": steps, "stepSettleMs": settle,
            **({"wantBand": True} if want else {})}, tmo=120000)
        print(json.dumps(r, ensure_ascii=False, indent=1))
    else:
        print(__doc__)
        sys.exit(2)
