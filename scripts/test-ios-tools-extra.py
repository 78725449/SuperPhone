"""测试 IosTools 新补的 3 个动作（key / menu / enter）—— 补它声明了却没实现的洞。

安全选择：
  · volume_up / volume_down —— 安全、可验证（音量条会出现）
  · power —— 【跳过】会锁屏，打断设备
  · menu (= 双击 Home) —— 会出 App Switcher，测完 home() 退回
  · enter —— 需先有输入框，本次先测方法可调用性

用法：python scripts/test-ios-tools-extra.py [gateway] [deviceId]
"""
import os
import sys
import time

MA_DIR = r"D:\编程项目\SuperPhone\_research\MobileAgent\Mobile-Agent-v3.5\mobile_use"
sys.path.insert(0, MA_DIR)

GW = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080"
DEV = sys.argv[2] if len(sys.argv) > 2 else None

from ios_tools import IosTools   # noqa: E402

t = IosTools(gateway=GW, device=DEV)
t.device = t.device or t._pick_device()
print("=" * 80)
print("IosTools 新增动作测试（key / menu / enter）")
print("=" * 80)
print("  设备: %s" % t.device)

fails = []


def check(name, cond, detail=""):
    print("  [%s] %s%s" % ("OK  " if cond else "FAIL", name, ("   " + detail) if detail else ""))
    if not cond:
        fails.append(name)


def shot_hash():
    """取当前帧 pHash（用 screen.hash，零网络大包）"""
    try:
        ack = t._invoke("screen.hash", {}, timeout=30)
        return ack.get("hash")
    except Exception:
        return None


# ── 1. key("volume_up") / key("volume_down") ──
print("\n【1】key 动作（schema 声明了却没实现）")
h_before = shot_hash()
ok_up = t.press_key("volume_up")
time.sleep(0.8)
h_after_up = shot_hash()
ok_dn = t.press_key("volume_down")
time.sleep(0.8)
h_after_dn = shot_hash()
check("press_key('volume_up') 返回 True", ok_up is True)
check("press_key('volume_down') 返回 True", ok_dn is True)
check("音量键改变了屏幕（HUD 出现）", h_before != h_after_up or h_after_up != h_after_dn,
      "hash %s → %s → %s" % (str(h_before)[:10], str(h_after_up)[:10], str(h_after_dn)[:10]))

# ── 2. key("camera") 应如实不支持 ──
print("\n【2】key('camera') 应如实返回 False（iOS 无系统相机键）")
ok_cam = t.press_key("camera")
check("press_key('camera') 返回 False（如实不支持）", ok_cam is False)

# ── 3. key 未知名字 ──
print("\n【3】key('不存在的键') 应如实返回 False")
check("press_key('nonsense_key') 返回 False", t.press_key("nonsense_key") is False)

# ── 4. menu() = 双击 Home（system_button{Menu}）──
print("\n【4】menu 动作（= 双击 Home → App Switcher）")
h1 = shot_hash()
ok_menu = t.menu()
time.sleep(1.5)
h2 = shot_hash()
check("menu() 执行无异常", ok_menu is None or ok_menu is True)
check("双击 Home 改变了屏幕（App Switcher）", h1 != h2,
      "hash %s → %s" % (str(h1)[:10], str(h2)[:10]))
# 退回主屏
t.home()
time.sleep(1.0)
h3 = shot_hash()
print("    已 home() 退回，hash=%s" % str(h3)[:10])

# ── 5. enter() 可调用性 ──
print("\n【5】enter()（system_button{Enter}）可调用性")
try:
    r = t.enter()
    check("enter() 可调用（过渡实现：粘贴换行）", True, "返回 %s" % r)
except Exception as exc:
    check("enter() 可调用", False, str(exc)[:70])

# ── 6. 三个方法的签名存在性 ──
print("\n【6】三个新方法存在且可调用")
for m in ("press_key", "menu", "enter"):
    check("IosTools.%s 存在" % m, callable(getattr(t, m, None)))

print()
print("=" * 80)
if fails:
    print("✗ %d 项失败: %s" % (len(fails), fails))
    sys.exit(1)
print("★ 全部通过 —— key / menu / enter 三个补齐的动作在我们设备上均可用")
