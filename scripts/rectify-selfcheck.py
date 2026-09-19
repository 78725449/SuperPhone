r"""阶段整改自检：资产树合法性 + 设备端改动静态检查。"""
import glob
import io
import json
import os
import re

ROOT = r"D:\编程项目\SuperPhone"
os.chdir(ROOT)

print("=== ① 资产树 JSON 全部合法 + required 齐全 ===")
root = os.path.join("skills", "superphone-device", "assets")
req_page = ["page", "app", "appVersion", "revision", "samplingProtocol",
            "structureSignature", "contentAnchors", "actions", "pits"]
ok = True
for p in sorted(glob.glob(os.path.join(root, "**", "*.json"), recursive=True)):
    try:
        d = json.load(io.open(p, encoding="utf-8"))
    except Exception as e:
        print("  X JSON 非法: %s (%s)" % (p, e))
        ok = False
        continue
    rel = os.path.relpath(p, root)
    if os.path.basename(p).startswith("_"):
        print("  meta  %-44s keys=%d" % (rel, len(d)))
        continue
    miss = [k for k in req_page if k not in d]
    print("  page  %-44s actions=%d edges=%d pits=%d slots=%d %s" % (
        rel, len(d.get("actions", [])), len(d.get("edges", [])),
        len(d.get("pits", [])), len(d.get("slots", [])),
        ("MISSING:" + str(miss)) if miss else "OK"))
    if miss:
        ok = False
print("  -> " + ("全部合法且 required 齐全" if ok else "有问题"))

print()
print("=== ② 设备端两个文件的括号配平 + 新字段 ===")
pat_str = re.compile(r'@?"(\\.|[^"\\])*"')
for f in [os.path.join("TrollVNC", "src", "TRCapabilityRegistry.mm"),
          os.path.join("TrollVNC", "src", "trollvncserver.mm")]:
    s = io.open(f, encoding="utf-8", errors="replace").read()
    t = pat_str.sub('""', s)
    t = re.sub(r"//[^\n]*", "", t)
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    bal = all(t.count(a) == t.count(b) for a, b in [("{", "}"), ("(", ")"), ("[", "]")])
    print("  %-26s braces=%-8s  version=%d build=%d shortVersionString=%d" % (
        os.path.basename(f), "OK" if bal else "MISMATCH",
        s.count('@"version"'), s.count('@"build"'), s.count("shortVersionString")))

print()
print("=== ③ 归档目录 / 活跃 data 目录 ===")
print("  归档文档: %d 份" % len(glob.glob(os.path.join("docs", "归档", "*.md"))))
print("  归档资产: %d 项" % len(os.listdir(os.path.join("data", "archive-20260921"))))
