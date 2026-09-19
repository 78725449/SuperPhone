r"""从已验证的 CI 产物 zip 提取 .tipa → 显式部署（不用陈旧默认包）。

★ 教训：deploy-tipa.py 无参调用会用【陈旧默认包】SuperPhone-bootstrap-tap.tipa，
  造成"装了但其实装了旧镜像"—— cat 首次验收才发现（screenBand grep=0）✗。
  → 每次部署必须【显式给出包路径 + 事后 grep 设备端二进制核验】。
"""
import io
import os
import zipfile

Z = r"D:\编程项目\SuperPhone\data\ci-artifact\packages-bootstrap.zip"
OUT = r"D:\编程项目\SuperPhone\data\ci-artifact\TrollVNC_0.0.1.tipa"
with zipfile.ZipFile(Z) as z:
    print("  外层条目：%s" % z.namelist())
    tipa = [n for n in z.namelist() if n.lower().endswith(".tipa")]
    inner = z.read(tipa[0])
    # 内层 .tipa 本身也是 zip → 确认含 trollvncmanager 与新键
    with zipfile.ZipFile(io.BytesIO(inner)) as z2:
        cand = [n for n in z2.namelist() if n.endswith("trollvncmanager")]
        mgr = z2.read(cand[0])
        n = mgr.count("screenBand".encode())
        print("  内核 grep screenBand = %d %s" % (n, "✓ 是新镜像" if n else "✗ 不是！"))
    open(OUT, "wb").write(inner)
    print("  ✓ 已落盘 %s (%.2f MB)" % (OUT, len(inner) / 1048576))
