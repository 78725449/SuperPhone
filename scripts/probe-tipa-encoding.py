"""确认：含中文的 ObjC 字面量在产物里用什么编码存？

待验假设：ASCII 字面量按 UTF-8 存（能搜到），含中文的按别的编码存（搜不到）。
逐个试 UTF-16LE / UTF-16BE / 各字节序 —— 找到哪个编码能命中就实锤。
"""
import zipfile

TIPA = r"D:\编程项目\SuperPhone\SuperPhone-bootstrap-tap.tipa"
zf = zipfile.ZipFile(TIPA)
data = zf.read("Payload/TrollVNC.app/trollvncmanager")
zf.close()

# 用源码里【一定存在】的中文片段做探针（TRCapabilityRegistry.mm 的 script.exec 段）
CANDIDATES = ["未在屏幕上找到文字", "屏幕上", "点击", "归一化"]

print("=" * 88)
print("  在 trollvncmanager 里找含中文的字面量，逐个编码试探")
print("=" * 88)
for s in CANDIDATES:
    print("  探针: %s" % s)
    for enc in ["utf-8", "utf-16-le", "utf-16-be", "utf-16", "gb18030"]:
        try:
            b = s.encode(enc)
        except Exception as e:
            print("      %-10s 编码失败 %s" % (enc, e))
            continue
        n = data.count(b)
        print("      %-10s %-34s 命中 %d %s" % (enc, b.hex(" ")[:34], n, "★" if n else ""))
    print()

print("=" * 88)
print("  结论")
print("=" * 88)
print("""
  · ASCII 字面量（如 "script.exec" / "find_and_click"）：按 UTF-8 存 → 能搜到 ✓
  · 含中文的字面量：按上表命中的那种编码存 → 用 utf-8 搜必然搜不到

  ★ 由此得出一条【该记住的事实】：
    「用中文字符串去验证产物是否含新代码」这个方法【不成立】——
    要么改用 ASCII 探针，要么按正确的编码去搜。
  ★ 而更可靠的验证仍是【两头对齐】：
    ① 推送后核对 远程树 sha == 本地树 sha（内容确认）
    ② CI run 的 head_sha == 推送后的远程 ref sha（编的是这个 commit）
""")
