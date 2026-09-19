"""诊断：.tipa 里的二进制到底是什么形态，为什么搜不到字符串。"""
import zipfile

TIPA = r"D:\编程项目\SuperPhone\SuperPhone-bootstrap-tap.tipa"
zf = zipfile.ZipFile(TIPA)

for name in ["Payload/TrollVNC.app/trollvncmanager",
             "Payload/TrollVNC.app/trollvncserver"]:
    data = zf.read(name)
    info = zf.getinfo(name)
    print("=" * 84)
    print("  %s" % name)
    print("=" * 84)
    print("  解压后 %d bytes   压缩方式=%s (compress_type=%d)  原始=%d"
          % (len(data), {0: "STORED", 8: "DEFLATED"}.get(info.compress_type, "?"),
             info.compress_type, info.compress_size))
    print("  前 16 字节 (hex): %s" % data[:16].hex(" "))
    magic = data[:4]
    print("  magic: %r" % magic)
    if magic[:4] == b"\xcf\xfa\xed\xfe":
        print("    → Mach-O 64-bit little-endian ✓")
    elif magic[:4] in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
        print("    → FAT/universal binary")
    elif magic[:2] == b"PK":
        print("    → 又一层 zip")
    else:
        print("    → 未识别")
    # 找任意可见 ASCII 串，判断是不是"根本不含可读字符串"
    import re
    runs = re.findall(rb"[\x20-\x7e]{8,}", data)
    print("  可读 ASCII 串(>=8字符) 数量: %d" % len(runs))
    for r in runs[:6]:
        print("      %r" % r[:70])
    # 找 UTF-8 中文
    han = re.findall(rb"(?:[\xe4-\xe9][\x80-\xbf]{2}){3,}", data)
    print("  UTF-8 中文字符串 数量: %d" % len(han))
    for h in han[:6]:
        try:
            print("      %s" % h.decode("utf-8")[:60])
        except Exception:
            pass
    print()

# 也看看 zip 里到底有哪些条目（可能二进制不在我猜的路径）
print("=" * 84)
print("  zip 全部条目前 24 个")
print("=" * 84)
for n in zf.namelist()[:24]:
    print("      " + n)
print("      ... 共 %d 个条目" % len(zf.namelist()))
zf.close()
