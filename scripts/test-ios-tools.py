"""IosTools 隔离单测 —— 不跑完整 Mobile-Agent 循环，先验证 9 个方法的真机可用性。

只做【只读】验证（截图 / app.list / 字典注入），不点不滑不打字 ——
写操作留到完整任务跑通时验证，避免测试本身误动设备。

用法：
    python scripts/test-ios-tools.py [gateway] [deviceId]
"""
import json
import os
import sys
import time

MA_DIR = r"D:\编程项目\SuperPhone\_research\MobileAgent\Mobile-Agent-v3.5\mobile_use"
sys.path.insert(0, MA_DIR)

GW = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080"
DEV = sys.argv[2] if len(sys.argv) > 2 else None

print("=" * 80)
print("IosTools 隔离单测")
print("=" * 80)
print(f"  网关: {GW}")
print(f"  设备: {DEV or '(自动选择)'}")
print()

# ── 导入（会连 packages.py 的两张官方字典）──
from ios_tools import IosTools            # noqa: E402
from packages import NAME_PACKAGE_DICT, PACKAGES_NAME_DICT   # noqa: E402
from device_tools import create_device_tools                  # noqa: E402

fails = []


def check(name, cond, detail=""):
    print(f"  [{'OK  ' if cond else 'FAIL'}] {name}" + (f"   {detail}" if detail else ""))
    if not cond:
        fails.append(name)


# ── 0. 工厂能按平台返回正确类型 ──
# ★ 必须在【任何真机调用之前】取快照：
#   注入发生在 get_screenshot() / get_package_name() 内（首次调用时一次性注入），
#    如果等到【3】再取 before，那时字典已经被改过了。
before_np = set(NAME_PACKAGE_DICT.keys())
before_pn = set(PACKAGES_NAME_DICT.keys())

print("【0】工厂分派")
t = create_device_tools("ios", gateway=GW, device=DEV)
check("platform=ios → IosTools", isinstance(t, IosTools), type(t).__name__)
try:
    ta = create_device_tools("android", adb_path="/usr/bin/adb")
    from utils import AdbTools
    check("platform=android → AdbTools", isinstance(ta, AdbTools), type(ta).__name__)
except Exception as exc:
    print(f"  [INFO] AdbTools 未实例化（预期：本地无 adb）: {type(exc).__name__}")

# ── 1. 9 个方法与 AdbTools 同名同签名（静态核对）──
print("\n【1】接口一致性（与 AdbTools 逐方法对比签名）")
import inspect                              # noqa: E402
from utils import AdbTools                  # noqa: E402

for m in ("get_screenshot", "click", "long_press", "slide", "back",
          "home", "type", "get_package_name", "open_app"):
    a = inspect.signature(getattr(AdbTools, m))
    b = inspect.signature(getattr(IosTools, m))
    # 去掉 self 比较
    pa = [p for n, p in a.parameters.items() if n != "self"]
    pb = [p for n, p in b.parameters.items() if n != "self"]
    same = len(pa) == len(pb) and all(
        x.name == y.name and x.default == y.default for x, y in zip(pa, pb))
    check(f"{m}{b}", same, f"AdbTools{a}" if not same else "")

# ── 2. 真机：自动选设备 + 截图 ──
print("\n【2】真机只读操作")
if t.device is None:
    try:
        t.device = t._pick_device()
    except Exception as exc:
        check("自动选择设备", False, str(exc)[:80])
        print(f"\n✗ 无法继续（网关不可达或无设备）")
        sys.exit(1)
check("自动选择设备", bool(t.device), str(t.device))

shot = os.path.join(os.path.dirname(__file__), "_test_shot.jpg")
if os.path.exists(shot):
    os.remove(shot)
ok = t.get_screenshot(shot)
size = os.path.getsize(shot) if os.path.exists(shot) else 0
check("get_screenshot()", ok and size > 1000, f"{size} bytes")
check("截图尺寸已记录（坐标归一化前提）", t.image_info is not None,
      f"{t._w}×{t._h}" + ("  ← 兜底值，说明 ack 未带 width/height" if (t._w, t._h) == (750, 1334) else ""))

# ── 3. app.list 与官方字典注入（"无缝集成"的关键）──
print("\n【3】app.list 与官方别名表注入（无缝集成的关键）")
# ★ 注意：_register_ios_apps() 是【就地修改】这两张官方字典，
#    快照 before_np/before_pn 已在【0】之前取好（必须早于任何真机调用）。
pkgs = t.get_package_name()
check("get_package_name() 返回非空", len(pkgs) > 0, f"{len(pkgs)} 个 bundleId")
check("返回的是 bundleId 形态", all("." in p for p in pkgs[:5]), f"样例: {pkgs[:3]}")

apps = t._app_list_raw()
check("app.list 带显示名（字典注入必需）", any(a.get("name") for a in apps),
      f"样例: {[(a.get('name'), a.get('bundleId')) for a in apps[:2]]}")

added_np = set(NAME_PACKAGE_DICT.keys()) - before_np
added_pn = set(PACKAGES_NAME_DICT.keys()) - before_pn
check("已注入 NAME_PACKAGE_DICT（显示名→包名）", len(added_np) > 0,
      f"新增 {len(added_np)} 个键，样例: {sorted(added_np)[:3]}")
check("已注入 PACKAGES_NAME_DICT（包名→显示名）", len(added_pn) > 0,
      f"新增 {len(added_pn)} 个键，样例: {sorted(added_pn)[:3]}")

# 用一个真实存在的 App 名验证"官方 handle_open_action 那条路能命中"
sample = next((a for a in apps if a.get("name") and a.get("bundleId")), None)
if sample:
    cand = NAME_PACKAGE_DICT.get(sample["name"], [])
    check(f"官方查表路径命中（用真实 App「{sample['name']}」）",
          sample["bundleId"] in cand, f"NAME_PACKAGE_DICT['{sample['name']}'] = {cand[:3]}")
    back = PACKAGES_NAME_DICT.get(sample["bundleId"], [])
    check("官方反查路径命中（LLM 兜底可用）", sample["name"] in back, f"{back[:2]}")
else:
    check("有可验证的 App 样例", False, "app.list 没有同时带 name 与 bundleId 的条目")

# ── 4. 常用 App 能否解析（模拟 handle_open_action 的第一次尝试）──
print("\n【4】模拟 handle_open_action 的解析路径（模型说中文名 → 能否命中）")
installed = set(pkgs)
for zh in ("抖音", "微信", "设置", "相机"):
    cands = NAME_PACKAGE_DICT.get(zh, [])
    hit = [c for c in cands if c in installed]
    mark = "OK  " if hit else "----"
    print(f"  [{mark}] 「{zh}」→ 候选 {cands[:2]}  命中 {hit[:1] if hit else '（表里无此名或未安装）'}")

# ── 汇总 ──
print()
print("=" * 80)
if fails:
    print(f"✗ {len(fails)} 项失败: {fails}")
    sys.exit(1)
print("★ 全部通过 —— IosTools 与 AdbTools 接口一致，真机只读操作与字典注入均正常")
print("  （写操作 click/type/swipe 留给完整任务验证）")
