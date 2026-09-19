r"""经 SSH 直接读设备上 App 的版本号（不依赖 CI/装包，立刻可得）。

★ 为什么绕 SSH：`app.list` 原本只返回 {bundleId,name}（无版本）✗ —— 已改设备端（纯加法）
  但要等 CI 编译 + 装包才能用。而【版本目录】是资产树的前置条件 → 先用 SSH 从 Info.plist 读，
  不阻塞资产重构；设备端改好后两条路都能拿 ✓

★ 路径：/var/containers/Bundle/Application/<UUID>/<App>.app/Info.plist（plist 是二进制）
  设备上没有 python/plutil 的把握 → 用 grep -a 抽字符串，或直接读 plist 的 XML 头
  更稳的办法：用 `defaults read`（iOS 有 defaults）或 strings。
"""
import plistlib
import re
import sys

import paramiko

DEV_IP = "10.0.0.242"


def sh(cmd, t=60):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(DEV_IP, port=1223, username="root", password="alpine",
              banner_timeout=30, auth_timeout=30, allow_agent=False, look_for_keys=False)
    i, o, e = c.exec_command(cmd, timeout=t)
    out = o.read()
    err = e.read().decode("utf-8", "replace")
    c.close()
    return out, err


# 列出所有 App 容器 → 找到目标 bundle 的 .app 路径
print("=== 定位 App 容器 ===")
out, err = sh("ls -d /var/containers/Bundle/Application/*/*.app 2>/dev/null | head -40")
apps = [l.strip() for l in out.decode("utf-8", "replace").splitlines() if l.strip()]
print("  找到 %d 个 .app" % len(apps))
for a in apps[:12]:
    print("    %s" % a)

TARGETS = {"抖音": "Aweme", "微信": "WeChat", "设置": "Preferences"}
print()
print("=== 读版本号（用 defaults read 优先，失败则 grep 二进制）===")
for a in apps:
    for label, key in TARGETS.items():
        if key in a:
            info = a + "/Info.plist"
            o2, _ = sh("defaults read %s CFBundleShortVersionString 2>/dev/null" % a.replace(".app", ""))
            v1 = o2.decode("utf-8", "replace").strip()
            o3, _ = sh("defaults read %s CFBundleVersion 2>/dev/null" % a.replace(".app", ""))
            v2 = o3.decode("utf-8", "replace").strip()
            if not v1:
                # 退化：从 Info.plist 二进制里抽（key 与 value 相邻，字符串可读）
                o4, _ = sh("grep -a -A1 CFBundleShortVersionString %s | head -4" % info)
                v1 = "(grep) " + o4.decode("utf-8", "replace").strip()[:80]
            print("  %-10s %-58s version=%s build=%s" % (label, a[:58], v1 or "?", v2 or "?"))
