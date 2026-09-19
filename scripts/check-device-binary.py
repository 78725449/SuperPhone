r"""核对设备端【正在运行】的二进制是否含新代码（不只看本地产物）。

★ 教训（AGENTS.md）：部署脚本"跑完了"不等于装上了 —— deploy 最后一超时，
  必须【上设备核对二进制】：grep ASCII 字面量 screenBand（在 __cstring，UTF-8 可搜）。
"""
import json
import ssl
import time
import urllib.request

DEV_IP = "10.0.0.242"
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

import paramiko   # noqa: E402


def sh(cmd, t=30):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(DEV_IP, port=1223, username="root", password="alpine",
              banner_timeout=30, auth_timeout=30, allow_agent=False,
              look_for_keys=False)
    i, o, e = c.exec_command(cmd, timeout=t)
    out = o.read().decode("utf-8", "replace")
    err = e.read().decode("utf-8", "replace")
    c.close()
    return out, err


APP = "/var/containers/Bundle/Application/635D7189-48E8-4F09-BB07-7CB35B855239/TrollVNC.app"
print("=== ① 设备端镜像内二进制的改码时间 ===")
out, _ = sh("ls -la %s/trollvncmanager 2>/dev/null; ls -l %s | head -5" % (APP, APP))
print(out[:800])

print("=== ② grep 新键（screenBand / wantBand / bandBefore —— ASCII，__cstring 可搜）===")
out, err = sh("grep -c screenBand %s/trollvncmanager; grep -c wantBand %s/trollvncmanager" % (APP, APP), t=60)
print("  screenBand=%s wantBand=%s" % (out.strip().replace("\n", "·"), err.strip()[:60]))

print("=== ③ 运行中进程与启动时间 ===")
out, _ = sh("ps aux | grep trollvnc | grep -v grep")
print(out[:600])

print("=== ④ 有没有 TrollStore 残留安装信息（新包到底装没装上去）===")
out, _ = sh("ls -la /var/mobile/Library/TrollStore 2>/dev/null | head -3; "
            "find /var/containers/Bundle/Application -name 'TrollVNC.app' -maxdepth 2 2>/dev/null | head -5")
print(out[:600])
