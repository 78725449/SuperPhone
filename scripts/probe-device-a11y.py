"""实测：我们设备（iPhone 6s / iOS 15 / TrollStore）能否拿到 a11y 树。

只读探测，不改设备任何东西。测四件事：
  ① 私有框架是否存在（AXRuntime / AccessibilityUtilities / UIKit）
  ② 是否已有 UI dump 类工具（frida / cycript / objection / 命令行）
  ③ 现有进程（trollvncmanager）链接了哪些私有框架
  ④ 系统版本与运行环境（能否编译/运行自定义代码）

用法：python scripts/probe-device-a11y.py [ip] [port]
"""
import sys

import paramiko

IP = sys.argv[1] if len(sys.argv) > 1 else "10.0.0.242"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 1223


def run(cli, cmd, timeout=30):
    """执行命令，返回 (stdout, stderr, exit_status)。"""
    try:
        _in, out, err = cli.exec_command(cmd, timeout=timeout)
        o = out.read().decode("utf-8", "replace").strip()
        e = err.read().decode("utf-8", "replace").strip()
        st = out.channel.recv_exit_status()
        return o, e, st
    except Exception as exc:
        return "", "EXC: %s" % exc, -1


def sec(t):
    print("\n" + "=" * 78)
    print(t)
    print("=" * 78)


cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
print("连接 %s:%d …" % (IP, PORT))
cli.connect(IP, port=PORT, username="root", password="alpine",
            banner_timeout=30, auth_timeout=30,
            allow_agent=False, look_for_keys=False)
print("  ✓ 已连接")

# ── ① 私有框架存在性 ──
sec("① 私有框架是否存在（a11y 的地基）")
frames = [
    "/System/Library/PrivateFrameworks/AXRuntime.framework",
    "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework",
    "/System/Library/PrivateFrameworks/AccessibilityUIUtilities.framework",
    "/System/Library/PrivateFrameworks/AccessibilitySharedSupport.framework",
    "/System/Library/Frameworks/UIKit.framework",
    "/System/Library/PrivateFrameworks/ScreenReaderCore.framework",
]
for f in frames:
    o, _, st = run(cli, "[ -d '%s' ] && echo YES || echo NO" % f)
    print("  %-62s %s" % (f.split("/")[-1], "✓ 在" if o == "YES" else "✗ 无"))

# ── ② 已有工具 ──
sec("② 是否已有 UI dump / 注入类工具")
for tool in ("frida", "frida-server", "cycript", "objection", "class-dump",
             "python3", "python", "swift", "swiftc", "clang", "clang++",
             "ldid", "jtool2", "otool", "nm"):
    o, _, _ = run(cli, "command -v %s 2>/dev/null || echo -" % tool)
    if o and o != "-":
        print("  %-16s ✓ %s" % (tool, o))
print("  （只列存在的）")

# ── ③ 现有进程链接的私有框架（关键：manager 已经在用私有 API）──
sec("③ trollvncmanager 链接的框架（看私有 API 是否可达）")
o, _, _ = run(cli, "ps aux | grep -E 'trollvncmanager|trollvncserver' | grep -v grep | head -5")
print("  进程:")
for line in (o or "(无)").splitlines():
    print("    " + line[:150])
o, _, _ = run(cli, "ls -la /var/containers/Bundle/Application/*/TrollVNC.app/trollvncmanager 2>/dev/null | head -3")
print("  二进制: %s" % (o or "(未找到)"))

# ── ④ 系统环境 ──
sec("④ 系统与运行环境")
for label, cmd in [
    ("内核/系统", "uname -a"),
    ("iOS 版本", "cat /System/Library/CoreServices/SystemVersion.plist 2>/dev/null | grep -A1 ProductVersion | tail -1"),
    ("是否越狱(root)", "id"),
    ("沙盒状态", "cat /proc/self/status 2>/dev/null | head -3 || echo '(无 /proc)'"),
    ("dyld 共享缓存", "ls -la /System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64* 2>/dev/null | head -3"),
]:
    o, _, _ = run(cli, cmd)
    print("  [%s] %s" % (label, (o or "(空)")[:170]))

cli.close()
print("\n" + "=" * 78)
print("探测完成（未改动设备任何内容）")
