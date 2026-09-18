"""把本地 .tipa 部署到设备并【无人值守地】把 daemon 链拉起来，最后确认设备回到 online。

为什么需要"无人值守"这一段（AGENTS.md 已知坑）：
  TrollStore 装包会杀掉 App，而 【App 的 ServiceCoordinator 是 daemon 链唯一拉起者】
  （tipa 不含 LaunchDaemon）。通常恢复只要"点开一次手机上的 App"，
  但自动化场景点不了 → 只能 SSH 手动拉起：
      nohup <APP>/trollvncmanager < /dev/null > /var/tmp/manager.log 2>&1 &
  两条硬要求：**必须绝对路径**（单例锁拒绝 ./trollvncmanager）、
             **stdin 必须 < /dev/null**（否则 RemoteHelper exec 通道挂起至超时）。

该 sshd 的限制：不支持 sftp；`cat > file` 传大文件会挂住 → 用 base64 分块。
"""
import base64
import json
import os
import ssl
import sys
import time
import urllib.request

import paramiko

HOST, PORT, USER, PWD = "10.0.0.242", 1223, "root", "alpine"
TIPA = sys.argv[1] if len(sys.argv) > 1 else r"D:\编程项目\SuperPhone\SuperPhone-bootstrap-tap.tipa"
CHUNK = 30000


def gw_devices():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen("https://127.0.0.1:8080/api/devices",
                                timeout=10, context=ctx) as r:
        return json.load(r)["devices"]


print("=" * 88)
print("部署 .tipa 到设备并拉起 daemon 链")
print("=" * 88)
size = os.path.getsize(TIPA)
print("  包: %s  (%.2f MB)" % (os.path.basename(TIPA), size / 1048576))

print()
print("[0] 部署前状态")
try:
    d = gw_devices()[0]
    print("    设备 online=%s controlState=%s" % (d.get("online"), d.get("controlState")))
    if d.get("controlState") not in ("idle", "ai"):
        print("    ⚠️ controlState=%s（可能有人在操作）—— 继续，但请注意" % d.get("controlState"))
except Exception as e:
    print("    ⚠️ 查网关失败: %s" % str(e)[:70])

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, port=PORT, username=USER, password=PWD,
          banner_timeout=30, auth_timeout=30, allow_agent=False, look_for_keys=False)


def run(cmd, t=60):
    _, so, se = c.exec_command(cmd, timeout=t)
    return (so.read().decode("utf-8", "replace")
            + se.read().decode("utf-8", "replace")).strip()


print()
print("[1] 传输（base64 分块，%d 字符/块）…" % CHUNK)
data = base64.b64encode(open(TIPA, "rb").read()).decode()
run("rm -f /var/tmp/t.b64 /var/tmp/t.tipa")
t0 = time.time()
for i in range(0, len(data), CHUNK):
    run("echo -n '%s' >> /var/tmp/t.b64" % data[i:i + CHUNK], t=40)
print("    %d 块 / %.0fs" % ((len(data) + CHUNK - 1) // CHUNK, time.time() - t0))

ts = run("ls -d /var/containers/Bundle/Application/*/TrollStore.app | head -1")
rh = run("ls -d /var/containers/Bundle/Application/*/TrollStoreRemoteHelper.app | head -1")
run("%s/fakeroot/bin/base64 -d /var/tmp/t.b64 > /var/tmp/t.tipa 2>/dev/null" % rh)
got = run("wc -c < /var/tmp/t.tipa").strip()
ok = str(size) == got
print("[2] 字节核对 本地 %d / 设备 %s → %s" % (size, got, "✓ 一致" if ok else "✗ 不一致，中止"))
if not ok:
    c.close()
    sys.exit(2)

print()
print("[3] 安装（装包会杀掉 App 与整条链，属预期）…")
out = run("%s/trollstorehelper install /var/tmp/t.tipa" % ts, t=300)
print("    " + (out.split("\n")[0][:160] if out else "(无输出)"))
time.sleep(5)

app = run("ls -d /var/containers/Bundle/Application/*/TrollVNC.app | head -1")
print("[4] App 路径: %s" % app)

print()
print("[5] ★ 无人值守拉起 daemon 链（nohup + 绝对路径 + stdin 脱离）…")
print("    " + run("ps aux | grep -E '[t]rollvncmanager|[t]rollvncserver' | head -3")[:200] if run("ps aux | grep -E '[t]rollvncmanager|[t]rollvncserver' | head -3") else "    （装完后无进程，符合预期）")
run("nohup %s/trollvncmanager < /dev/null > /var/tmp/manager.log 2>&1 &" % app, t=15)
time.sleep(6)
ps = run("ps aux | grep -E '[t]rollvncmanager|[t]rollvncserver' | head -4")
print("    拉后进程:")
for line in (ps or "（空）").split("\n")[:4]:
    print("      " + line[:150])
lsof = run("lsof -i :5901 2>/dev/null | head -2")
print("    5901 监听: %s" % ("✓" if "LISTEN" in lsof else "✗ " + lsof[:80]))

c.close()

print()
print("[6] 等设备回到网关 online（最多 90s）…")
for i in range(18):
    time.sleep(5)
    try:
        dd = gw_devices()[0]
        print("    +%3ds  online=%-5s controlState=%s" % ((i + 1) * 5, dd.get("online"), dd.get("controlState")))
        if dd.get("online"):
            print()
            print("  ★★ 部署完成，设备已上线 ✓")
            break
    except Exception as e:
        print("    +%3ds  %s" % ((i + 1) * 5, str(e)[:60]))
else:
    print("  ✗ 90s 内未上线 —— 需要人工点开手机上的 TrollVNC App")
print("DONE")
