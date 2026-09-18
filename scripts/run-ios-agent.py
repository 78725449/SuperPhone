"""一键用 Mobile-Agent 操作手机 —— 直接给指令即可。

用法（在仓库根目录）：
    python scripts/run-ios-agent.py "打开抖音搜索南京美食"
    python scripts/run-ios-agent.py "打开设置看看蓝牙" --max-steps 15
    python scripts/run-ios-agent.py "调高音量" --device <deviceId>

它会先自检三件依赖（缺谁报谁，不让你对着报错猜）：
    ① SuperPhone 网关（8080）—— 不在就自动拉起
    ② 本地 GUI-Owl 模型服务（8092）—— 不在就提示启动命令
    ③ 目标设备在线 —— 不在就提示
然后把指令交给 Mobile-Agent 官方脚本（--platform ios）执行，并实时打印每一步。

★ 这是「演员」的入口：你下指令，它自己看屏幕、自己决定点哪里。
"""

import argparse
import glob
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MA_DIR = os.path.join(ROOT, "_research", "MobileAgent", "Mobile-Agent-v3.5", "mobile_use")
MA_SCRIPT = os.path.join(MA_DIR, "run_gui_owl_1_5_for_mobile.py")

GATEWAY = "http://127.0.0.1:8080"
LLAMA = "http://127.0.0.1:8092"
DEFAULT_MODEL = r"D:\llama.cpp\models\GUI-Owl-1.5-4B\gui-owl-1.5-4b-instruct-q4_k_m.gguf"


def ok(msg):
    print("  [OK]   " + msg)


def bad(msg):
    print("  [FAIL] " + msg)


def info(msg):
    print("  [ .. ] " + msg)


def http_json(url, timeout=8):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.load(r)


def check_gateway(gateway, auto_start=True):
    """① 网关：不在就拉起（纯加法，不影响正在跑的设备链路）。"""
    print("\n[1/3] SuperPhone 网关 (8080)")
    try:
        d = http_json(gateway + "/api/devices")
        ok("已在线，设备 %d 台" % len(d.get("devices") or []))
        return d
    except Exception:
        pass
    if not auto_start:
        bad("未运行（且已禁用自动拉起）")
        return None
    info("未运行，正在拉起…")
    log = os.path.join(ROOT, "trollvnc-farm", "data", "gateway.log")
    env = dict(os.environ)
    env.pop("FARM_TLS", None)           # ★ 必须用默认 TLS：FARM_TLS=0 会破坏 App 连接
    env.pop("FARM_DEBUG_REDIRECT", None)
    subprocess.Popen(
        ["node", "server/index.js"],
        cwd=os.path.join(ROOT, "trollvnc-farm"),
        stdout=open(log, "ab"), stderr=subprocess.STDOUT, env=env,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0,
    )
    for _ in range(20):
        time.sleep(1.5)
        try:
            d = http_json(gateway + "/api/devices")
            ok("已拉起，设备 %d 台" % len(d.get("devices") or []))
            return d
        except Exception:
            continue
    bad("拉起失败，请手动：cd trollvnc-farm && npm start")
    return None


def check_llama():
    """② 本地 GUI-Owl 模型服务。"""
    print("\n[2/3] 本地模型服务 GUI-Owl (8092)")
    try:
        h = http_json(LLAMA + "/health")
        if h.get("status") != "ok":
            bad("health 异常: %s" % h)
            return None
        m = http_json(LLAMA + "/v1/models")
        mid = (m.get("data") or [{}])[0].get("id")
        ok("已在线，模型 = %s" % mid)
        return mid
    except Exception:
        bad("未运行 —— 请先启动（另开一个窗口）：")
        print("         powershell -File scripts\\start-gui-owl.ps1")
        return None


def check_device(devices, want=None):
    """③ 目标设备在线。"""
    print("\n[3/3] 目标设备")
    ds = (devices or {}).get("devices") or []
    if not ds:
        bad("网关里没有任何设备")
        return None, None
    if want:
        hit = [d for d in ds if d.get("id") == want]
        if not hit:
            bad("找不到设备 %s" % want)
            return None, None
        d = hit[0]
    else:
        online = [d for d in ds if d.get("online")]
        if not online:
            bad("没有【在线】设备。设备有在线时再试（或点开手机上的 TrollVNC App）")
            return None, None
        d = online[0]
    if not d.get("online"):
        bad("设备 %s 离线" % d.get("id"))
        return None, None
    ok("%s  %s  controlState=%s" % (d.get("id"), d.get("name", ""), d.get("controlState")))
    return d.get("id"), d.get("name", "")


def main():
    ap = argparse.ArgumentParser(description="用 Mobile-Agent 操作 SuperPhone 手机（一条指令即可）")
    ap.add_argument("instruction", help="要它做的事，例如：打开抖音搜索南京美食")
    ap.add_argument("--max-steps", type=int, default=15, help="最多执行多少步（默认 15）")
    ap.add_argument("--device", default=None, help="设备 id（默认取第一台在线设备）")
    ap.add_argument("--model", default=None, help="模型 id（默认取 llama-server 里加载的那个）")
    ap.add_argument("--gateway", default=GATEWAY, help="SuperPhone 网关地址")
    ap.add_argument("--no-auto-start", action="store_true", help="不要自动拉起网关")
    args = ap.parse_args()

    gateway = args.gateway.rstrip("/")

    print("=" * 78)
    print("Mobile-Agent  iOS 平台驱动 SuperPhone")
    print("=" * 78)
    print("  指令: %s" % args.instruction)

    if not os.path.exists(MA_SCRIPT):
        bad("找不到 Mobile-Agent 脚本：%s" % MA_SCRIPT)
        sys.exit(1)

    devs = check_gateway(gateway, auto_start=not args.no_auto_start)
    if devs is None:
        sys.exit(1)

    model = check_llama()
    if not model:
        sys.exit(1)
    model = args.model or model

    device_id, dev_name = check_device(devs, args.device)
    if not device_id:
        sys.exit(1)

    # 保持设备亮屏（避免跑一半自动锁屏）
    try:
        urllib.request.urlopen(urllib.request.Request(
            "%s/api/devices/%s/invoke" % (GATEWAY, device_id),
            data=json.dumps({"cap": "screen.snapshot", "params": {}}).encode(),
            headers={"Content-Type": "application/json"}, method="POST"), timeout=20).read()
    except Exception:
        pass

    cmd = [
        sys.executable, MA_SCRIPT,
        "--platform", "ios",
        "--gateway", GATEWAY,
        "--api_key", "dummy",
        "--base_url", LLAMA + "/v1",
        "--model", model,
        "--instruction", args.instruction,
        "--max_steps", str(args.max_steps),
        "--device", device_id,
    ]
    print("\n" + "=" * 78)
    print("开始执行（它会自己看屏幕、自己决定点哪里）")
    print("=" * 78 + "\n")
    print("  " + " ".join('"%s"' % c if " " in c else c for c in cmd[1:]) + "\n")

    rc = subprocess.call(cmd, cwd=MA_DIR)
    print("\n" + "=" * 78)
    print("执行结束（返回码 %d）" % rc)
    print("产物目录：%s\\<指令前 80 字符>\\" % MA_DIR)
    print("=" * 78)
    sys.exit(rc)


if __name__ == "__main__":
    main()
