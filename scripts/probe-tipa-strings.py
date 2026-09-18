"""用【多个探针】定位字符串搜索失败的原因：
   · ASCII 能力名 / op 名（一定在代码里）
   · 中文串（分"纯中文连续"与"中文+ASCII 混合"两类）
"""
import zipfile

TIPA = r"D:\编程项目\SuperPhone\SuperPhone-bootstrap-tap.tipa"
zf = zipfile.ZipFile(TIPA)

PROBES = [
    ("ASCII 能力名", b"script.exec"),
    ("ASCII 能力名", b"find_and_click"),
    ("ASCII 能力名", b"stepSettleMs"),
    ("ASCII op 名", b"input_text"),
    ("ASCII op 名", b"wait_for"),
    ("ASCII 类名", b"TRCapabilityRegistry"),
    ("ASCII 方法", b"trScriptFindRow"),
    ("中文·纯", "未在屏幕上找到文字".encode("utf-8")),
    ("中文·短", "未在屏幕上".encode("utf-8")),
    ("中文·4字", "屏幕上".encode("utf-8")),
    ("中文·地名", "乌鲁木齐".encode("utf-8")),
    ("新代码·ASCII格式串", b"%.4f,%.4f"),
    ("新代码·中文", "归一化".encode("utf-8")),
]

for name in ["Payload/TrollVNC.app/trollvncmanager",
             "Payload/TrollVNC.app/trollvncserver"]:
    data = zf.read(name)
    print("=" * 88)
    print("  %s   (%d bytes)" % (name.split("/")[-1], len(data)))
    print("=" * 88)
    for kind, b in PROBES:
        n = data.count(b)
        print("    %-20s %-28s 命中 %-5d %s" % (
            kind, repr(b)[:28], n, "★" if n else ""))
    print()

zf.close()
