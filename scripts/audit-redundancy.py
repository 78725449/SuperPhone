r"""冗余审计（2026-09-21）：scripts / data / 根部散落文件 / SKILL.md 治理状态。

★ 判据（不是"看起来旧"，而是可核验的）：
  ① 脚本：是否被【文档/SKILL/其他脚本】引用 → 无引用 = 一次性探针候选
  ② data/：是否在 .gitignore（运行时数据 vs 该入库的资产）
  ③ 根部散落：git status 未跟踪项
  ④ SKILL.md：关键断言是否与【当前实现】一致（如 screen.hash 已修好？find_image 还缺吗？）
"""
import glob
import io
import os
import re
import subprocess

ROOT = r"D:\编程项目\SuperPhone"
os.chdir(ROOT)

# ── ① 脚本引用审计 ──────────────────────────────────────────────
print("=" * 92)
print("  ① scripts/ 脚本引用审计（无引用 = 一次性探针候选）")
print("=" * 92)
scripts = sorted(os.path.basename(p) for p in glob.glob("scripts/*.py") + glob.glob("scripts/*.mjs"))
docs = []
for pat in ["*.md", "docs/**/*.md", "skills/**/*.md", "TrollVNC/**/*.md", "trollvnc-farm/**/*.md"]:
    docs += glob.glob(pat, recursive=True)
docs = [d for d in docs if "node_modules" not in d]
doc_text = {}
for d in docs:
    try:
        doc_text[d] = io.open(d, encoding="utf-8", errors="replace").read()
    except Exception:
        pass
script_text = {}
for s in scripts:
    p = os.path.join("scripts", s)
    try:
        script_text[s] = io.open(p, encoding="utf-8", errors="replace").read()
    except Exception:
        script_text[s] = ""

orphan, cited = [], []
for s in scripts:
    stem = s.rsplit(".", 1)[0]
    refs = []
    for d, t in doc_text.items():
        if stem in t:
            refs.append(os.path.basename(d))
    for s2, t in script_text.items():
        if s2 != s and stem in t:
            refs.append("scripts/" + s2)
    (cited if refs else orphan).append((s, refs))

print("  被引用（保留）：%d" % len(cited))
for s, r in cited:
    print("     %-34s ← %s" % (s, ", ".join(r[:3]) + ("…" if len(r) > 3 else "")))
print()
print("  ★ 无任何引用（一次性探针候选）：%d" % len(orphan))
for s, _ in orphan:
    sz = os.path.getsize(os.path.join("scripts", s))
    print("     %-34s %5.1fKB" % (s, sz / 1024))

# ── ② data/ 与 gitignore ────────────────────────────────────────
print()
print("=" * 92)
print("  ② data/ 目录（★ 标 * = 已被 .gitignore 忽略，即运行时数据）")
print("=" * 92)
gi = io.open(".gitignore", encoding="utf-8", errors="replace").read()
for d in sorted(os.listdir("data")):
    p = os.path.join("data", d)
    if not os.path.isdir(p):
        continue
    n = sum(len(f) for _, _, f in os.walk(p))
    mb = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(p) for f in fs) / 1048576
    ign = ("*" if (d + "/" in gi or "data/" + d in gi) else " ")
    print("   %s %-32s %5d 文件 %7.1fMB" % (ign, d, n, mb))

# ── ③ 根部散落 ──────────────────────────────────────────────────
print()
print("=" * 92)
print("  ③ 根部/scripts 未跟踪文件（git status）")
print("=" * 92)
out = subprocess.run(["git", "status", "--short"], capture_output=True, text=True,
                     encoding="utf-8", errors="replace").stdout
untracked = [l[3:] for l in out.splitlines() if l.startswith("??")]
print("  未跟踪项：%d" % len(untracked))
for u in untracked[:30]:
    print("     %s" % u)
if len(untracked) > 30:
    print("     … 还有 %d 项" % (len(untracked) - 30))

# ── ④ SKILL.md 治理状态 ─────────────────────────────────────────
print()
print("=" * 92)
print("  ④ SKILL.md 治理状态（关键断言 vs 当前实现）")
print("=" * 92)
sk = io.open(os.path.join("skills", "superphone-device", "SKILL.md"), encoding="utf-8",
             errors="replace").read()
print("  体积：%.1fKB · 行数 %d" % (len(sk.encode("utf-8")) / 1024, sk.count("\n") + 1))
print("  章节：")
for m in re.finditer(r"^(#{2,4})\s+(.+)$", sk, re.M):
    print("     %s%s" % ("  " * (len(m.group(1)) - 2), m.group(2)[:64]))
print()
print("  关键断言检查（是否与当前实现一致）：")
checks = [
    ("screen.hash 说『已修好』", "screen.hash" in sk and "已修好" in sk),
    ("find_image 说『缺模板来源』", "find_image" in sk and ("缺模板" in sk or "加了也用不了" in sk)),
    ("仍引用旧 pages/ 资产路径", "pages/" in sk or "pages\\" in sk),
    ("已含新资产树 assets/", "assets/" in sk),
    ("已含 require/screenBand", "require" in sk and "screenBand" in sk),
    ("仍写 17 个工具（旧数）", "17 个工具" in sk),
]
for name, val in checks:
    print("     %-30s %s" % (name, "命中" if val else "未出现"))
