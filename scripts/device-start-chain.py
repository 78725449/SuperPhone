"""SSH 拉起 daemon 链 —— ★ 真正的 fire-and-forget。

AGENTS.md 已知坑（本次又栽了一次）：发 `nohup ... < /dev/null > log 2>&1 &` 之后
**绝不能去读 stdout**，否则 RemoteHelper 的 exec 通道会挂住直到超时。
正确姿势：开 session → exec_command → 立刻关掉 channel，一个字节都不读。

两条硬要求：**绝对路径**（单例锁拒绝 ./trollvncmanager）、**stdin 脱离**（< /dev/null）。
"""
import json
import ssl
import sys
import time
import urllib.request

import paramiko

HOST, PORT, USER, PWD = "10.0.0.242", 1223, "root", "alpine"

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, port=PORT, username=USER, password=PWD,
          banner_timeout=30, auth_timeout=30, allow_agent=False, look_for_keys=False)


def run(cmd, t=30):
    """读输出（只用于【会正常退出】的命令）。"""
    _, so, se = c.exec_command(cmd, timeout=t)
    return (so.read().decode("utf-8", "replace")
            + se.read().decode("utf-8", "replace")).strip()


def fire_and_forget(cmd):
    """★ 发完就关，不读 stdout —— 专用于 nohup 拉起常驻进程。"""
    chan = c.get_transport().open_session()
    chan.exec_command(cmd)
    time.sleep(1.5)
    chan.close()


print("=" * 84)
print("拉起 daemon 链（fire-and-forget）")
print("=" * 84)

app = run("ls -d /var/containers/Bundle/Application/*/TrollVNC.app | head -1")
print("  App 路径: %s" % app)
if not app or "No such" in app:
    print("  ✗ 找不到 TrollVNC.app —— 装包可能失败了")
    c.close()
    sys.exit(1)

before = run("ps aux | grep -E '[t]rollvncmanager|[t]rollvncserver' | head -4")
print("  拉起前进程: %s" % (before.replace("\n", " | ")[:160] or "（无）"))

print()
print("  → fire-and-forget 发送…")
fire_and_forget("nohup %s/trollvncmanager < /dev/null > /var/tmp/manager.log 2>&1 &" % app)
print("    ✓ 已发送（未读 stdout，channel 已关）")
time.sleep(6)

after = run("ps aux | grep -E '[t]rollvncmanager|[t]rollvncserver' | head -4")
print("  拉起后进程:")
if after:
    for line in after.split("\n")[:4]:
        print("      " + line[:150])
else:
    print("      （无 —— 拉起失败）")

lsof = run("lsof -i :5901 2>/dev/null | head -2")
print("  5901 监听: %s" % ("✓ LISTEN" if "LISTEN" in lsof else "✗ " + (lsof[:90] or "(空)")))

if not after:
    print()
    print("  --- manager.log 尾部（诊断用）---")
    print("  " + run("tail -20 /var/tmp/manager.log 2>/dev/null").replace("\n", "\n  ")[:1200])

c.close()

print()
print("=" * 84)
print("等设备回到网关 online（最多 90s）")
print("=" * 84)
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
for i in range(18):
    time.sleep(5)
    try:
        with urllib.request.urlopen("https://127.0.0.1:8080/api/devices", timeout=10,
                                    context=ctx) as r:
            d = json.load(r)["devices"][0]
        print("  +%3ds  online=%-5s controlState=%s" % ((i + 1) * 5, d.get("online"), d.get("controlState")))
        if d.get("online"):
            print()
            print("  ★★ 设备已上线 ✓")
            break
    except Exception as e:
        print("  +%3ds  %s" % ((i + 1) * 5, str(e)[:60]))
else:
    print("  ✗ 90s 内未上线 —— 需人工点开手机上的 TrollVNC App")
print("DONE")
