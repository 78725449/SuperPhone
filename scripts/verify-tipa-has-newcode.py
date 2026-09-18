r"""从 .tipa 里取出二进制，验证【本次新增代码】确实在里面（部署前必做）。

动机（AGENTS.md 已知坑）：曾出现「远程树不含该 commit 的内容 → CI 编译的还是旧代码 →
部署后真机行为与源码不符，极难排查」。故部署前必须证实产物含新代码。

★★★ 编码事实（2026-09-19 实测，必须记住）：
  clang 对 ObjC 里【含非 ASCII】的 @"..." 字面量，会放进 __TEXT,__ustring 段、按 **UTF-16LE** 存；
  只有纯 ASCII 字面量才按 UTF-8 进 __cstring。
  → 所以「用中文字符串 grep 二进制」必须用 **UTF-16LE** 编码，否则永远搜不到（本次就栽在这里）。

本次新增代码的探针（源头在 TrollVNC/src/TRCapabilityRegistry.mm 的 tap 分支）：
  · 中文（UTF-16LE）: "tap 需要 x/y（0-1 归一化，两者都必填）" / "点击 (%.4f,%.4f)"
  · ASCII（UTF-8） : script.exec（该能力 2026-09-18 才加，它的存在本身就说明包是新的）
另设【阳性对照】（旧代码里本来就有），防止"搜不到 = 工具坏"。
"""
import os
import zipfile

ROOT = r"D:\编程项目\SuperPhone"
TIPA = os.path.join(ROOT, "SuperPhone-bootstrap-tap.tipa")

# (显示名, 字符串, 编码)
NEW = [
    ("新·中文", "tap 需要 x/y（0-1 归一化，两者都必填）", "utf-16-le"),
    ("新·中文", "点击 (%.4f,%.4f)", "utf-16-le"),
    ("新·ASCII", "script.exec", "utf-8"),
]
OLD = [
    ("旧·中文(对照)", "未在屏幕上找到文字", "utf-16-le"),
    ("旧·ASCII(对照)", "find_and_click", "utf-8"),
]

print("=" * 84)
print("从 .tipa 提取二进制并搜索新代码字符串（★ 中文用 UTF-16LE）")
print("=" * 84)

zf = zipfile.ZipFile(TIPA)
targets = [n for n in zf.namelist()
           if n.endswith(("trollvncserver", "trollvncmanager", "TrollVNC.app/TrollVNC"))]

print("  候选二进制: %d 个" % len(targets))
for t in targets:
    print("      " + t)
print()

summary = {}
for name in targets:
    data = zf.read(name)
    short = name.split("/")[-1]
    print("-" * 84)
    print("  %s  (%d bytes)" % (short, len(data)))
    print("-" * 84)
    for kind, s, enc in NEW:
        n = data.count(s.encode(enc))
        summary.setdefault(short, []).append((kind, s, n))
        print("    [%s] %-38s 命中 %-4d %s" % (kind, s[:38], n, "★" if n else "—"))
    for kind, s, enc in OLD:
        n = data.count(s.encode(enc))
        print("    [%s] %-32s 命中 %-4d %s" % (kind, s[:32], n, "✓" if n else "✗ 工具可疑"))
    print()
zf.close()

print("=" * 84)
best = {k: all(n > 0 for kind, _, n in v if kind.startswith("新")) for k, v in summary.items()}
hit = [k for k, v in best.items() if v]
print("  结论: %s" % ("★★ 产物含本次新增的 tap op 代码（在 %s）" % "、".join(hit) if hit
                    else "✗ 产物里搜不到新代码 —— 不要部署"))
print("=" * 84)


print("=" * 84)
ok = any(all(v > 0 for v in d.values()) for d in hit_summary.values())
print("  结论: %s" % ("★★ 产物含本次新增的 tap op 代码" if ok
                    else "✗ 产物里【搜不到】新代码 —— 不要部署，先查 CI 编译的是哪个 commit"))
print("=" * 84)
