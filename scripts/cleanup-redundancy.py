r"""冗余清理（2026-09-21 · 用户批准全部执行）。

★ 分批（与审计一致）：
  批1 冲突与垃圾：空目录 data/page-assets、data/pages；根部 0 字节 "=" 文件
  批2 未跟踪遗留：9 份根部 md + 6 个脚本 + skills/.../layouts（未跟踪产物）
      → ★ 移入 data/archive-20260921/（可救回），不物理删
  批3 无引用探针脚本：→ scripts/archive/（保留可追溯性，清根目录噪音）
      ★ 不物理删（用户未逐项裁决；归档是"从活跃位置移出" ✓）

★ 与主干同名的文件必须先 diff（可能是不同版本 ✗）—— 见 step 0。
"""
import glob
import hashlib
import io
import os
import shutil
import subprocess

ROOT = r"D:\编程项目\SuperPhone"
os.chdir(ROOT)
ARC = os.path.join("data", "archive-20260921")
os.makedirs(ARC, exist_ok=True)


def md5(p):
    return hashlib.md5(io.open(p, "rb").read()).hexdigest()[:10]


print("=" * 88)
print("  step 0 · 与主干同名的文件先 diff（防误删不同版本）")
print("=" * 88)
pairs = [("设备操作Agent时序设计.md", "设备操作Agent时序设计-2026-08-28.md"),
         ("手机Agent框架机制提炼报告.md", "docs/归档/docs-调研-手机Agent框架机制提炼报告-2026-08-28.md")]
for a, b in pairs:
    if os.path.exists(a) and os.path.exists(b):
        ha, hb = md5(a), md5(b)
        sa, sb = os.path.getsize(a), os.path.getsize(b)
        same = ha == hb
        print("  %-38s %8d B  %s" % (a, sa, ha))
        print("  %-38s %8d B  %s   → %s" % (b, sb, hb, "★ 内容相同（安全归档）" if same else "⚠️ 内容不同！需人工裁决"))
    else:
        print("  （缺）%s / %s" % (a, b))

print()
print("=" * 88)
print("  批1 · 冲突与垃圾")
print("=" * 88)
for d in ["data/page-assets", "data/pages"]:
    if os.path.isdir(d):
        n = len(glob.glob(os.path.join(d, "**", "*"), recursive=True))
        if n == 0:
            os.rmdir(d)
            print("  ✓ 删空目录 %s" % d)
        else:
            print("  ⚠️ %s 非空（%d 项），跳过" % (d, n))
if os.path.exists("="):
    os.remove("=")
    print("  ✓ 删 0 字节垃圾文件 '='")

print()
print("=" * 88)
print("  批2 · 未跟踪遗留 → data/archive-20260921/untracked/")
print("=" * 88)
UNTRACKED_MD = [
    "SuperPhone-设备端能力验收报告-2026-08-28.md",
    "dsh-device-skill.md",
    "农场设备特征对抗清单.md",
    "引擎风控对抗实施提示词.md",
    "手机Agent框架机制提炼报告.md",
    "抖音iOS逆向分析报告.md",
    "模拟对抗能力台账.md",
    "设备操作Agent时序设计.md",
]
dst = os.path.join(ARC, "untracked")
os.makedirs(dst, exist_ok=True)
moved = 0
for f in UNTRACKED_MD:
    if os.path.exists(f):
        shutil.move(f, os.path.join(dst, f))
        print("  ✓ %s" % f)
        moved += 1
    else:
        print("  （无）%s" % f)
# 未跟踪脚本
UNTRACKED_PY = ["scripts/actor-run.py", "scripts/check-device-stability.py",
                "scripts/deploy-no-spawn.py", "scripts/get-artifact.mjs",
                "scripts/ma35-mobile-use.py", "scripts/verify-artifact-has-band.py"]
for f in UNTRACKED_PY:
    if os.path.exists(f):
        shutil.move(f, os.path.join(dst, os.path.basename(f)))
        print("  ✓ %s" % f)
        moved += 1
# layouts 产物（未跟踪）
if os.path.isdir("skills/superphone-device/layouts"):
    shutil.move("skills/superphone-device/layouts", os.path.join(ARC, "skills-layouts-旧产物"))
    print("  ✓ skills/superphone-device/layouts → archive（与 assets/ 重复的旧产物）")
    moved += 1
print("  共处置 %d 项" % moved)

print()
print("=" * 88)
print("  批3 · 无引用探针脚本 → scripts/archive/")
print("=" * 88)
ORPHANS = """_tilecheck.mjs accept-new-keys.py align-research-repos.py analyze-ma-trace.py
audit-element-table.py audit-primitive-coverage.py audit-redundancy.py build-wps-data.mjs
capture-dynamic-page.py capture-pages-v2.py capture-pages-v3.py capture-pages.py
check-and-dispatch-ci.py check-device-binary.py check-icon-text-containment.py
check-merge-sources.py ci-status.py cluster-icon-library.py diag-tipa-binary.py
extract-verified-tipa.py fetch-florence2-base-files.py goto-douyin-home.py
measure-agents-md.py omniparser-iou-sweep.py omniparser-merge.py probe-exec-sampling.py
probe-page-fingerprint.py probe-page-skeleton.py probe-page-skeleton2.py
probe-rect-detection.py probe-structural-selfcheck.py probe-tab-state-color.py
probe-tipa-encoding.py probe-tipa-strings.py read-app-versions.py
read-mobileagent-timing.py rectify-assets-20260921.py rectify-selfcheck.py
rename-vnc-to-ios.py retry-research-fetch.py sample-during-exec-v2.py
sample-during-exec.py sample-v3-clear-and-sample.py sample-v4-final.py
slim-agents-md-2.py slim-agents-md.py survey-android-naming.py
sync-research-repos.py test-ios-tools-extra.py validate-omniparser-aspect.py
fetch-omniparser-weights.py validate-omniparser-ios.py""".split()
ARC_S = os.path.join("scripts", "archive")
os.makedirs(ARC_S, exist_ok=True)
n_arc = 0
for s in ORPHANS:
    p = os.path.join("scripts", s)
    if os.path.exists(p):
        shutil.move(p, os.path.join(ARC_S, s))
        n_arc += 1
print("  ✓ 归档 %d 个无引用脚本 → scripts/archive/" % n_arc)
print()
print("  活跃 scripts/ 剩余：%d 个文件" % len([f for f in os.listdir("scripts")
                                             if os.path.isfile(os.path.join("scripts", f))]))
