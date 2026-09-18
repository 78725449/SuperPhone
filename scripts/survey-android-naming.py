"""把 Mobile-Agent 里【Android 相关的全部命名】一次列全。

用户问："当前安卓是怎么命名的？"
→ 只有把 Android 这条线的命名看全（目录/文件/类/构造/CLI/内部变量），
  才能判断我们的 iOS 该沿用什么维度命名。
只读，不改任何文件。
"""
import os, re

ROOT = r"D:\编程项目\SuperPhone\_research\MobileAgent\Mobile-Agent-v3.5"
MOB = os.path.join(ROOT, "mobile_use")
AW = os.path.join(ROOT, "android_world_v3.5")


def sec(t):
    print("\n" + "=" * 92)
    print(t)
    print("=" * 92)


sec("① Android 平台在 mobile_use/ 这条线（产品向：GUI-Owl 直接驱动）")

print("【目录名】 mobile_use/")
print("【文件】")
for f in sorted(os.listdir(MOB)):
    if f.endswith(".py"):
        p = os.path.join(MOB, f)
        n = len(open(p, encoding="utf-8", errors="replace").read().split("\n"))
        print(f"    {f:44s} {n:4d} 行")

print("\n【入口脚本全名】")
for f in os.listdir(MOB):
    if f.startswith("run_"):
        print(f"    {f}")

print("\n【CLI 参数（argparse）】")
p = os.path.join(MOB, "run_gui_owl_1_5_for_mobile.py")
txt = open(p, encoding="utf-8", errors="replace").read()
for m in re.finditer(r'add_argument\(\s*"([^"]+)"(.*?)\)', txt, re.S):
    flag = m.group(1)
    rest = m.group(2)
    default = re.search(r'default=([^,\)]+)', rest)
    d = default.group(1).strip() if default else "-"
    print(f"    {flag:28s} default={d}")

print("\n【类与构造签名】")
for f in sorted(os.listdir(MOB)):
    if not f.endswith(".py"):
        continue
    fp = os.path.join(MOB, f)
    for i, l in enumerate(open(fp, encoding="utf-8", errors="replace")):
        if re.match(r"^class ", l) or re.match(r"\s+def __init__", l):
            print(f"    {f}:{i+1}  {l.strip()[:90]}")

print("\n【main() 里的变量名与实例化】")
for i, l in enumerate(open(p, encoding="utf-8", errors="replace")):
    if re.search(r"AdbTools|adb_tools", l):
        print(f"    {i+1:4d}: {l.rstrip()[:100]}")

sec("② Android 在 android_world_v3.5/ 这条线（评测向：MA3.5 多智能体）")
for probe in ("android_world/env/interface.py",
              "android_world/env/android_world_controller.py",
              "android_world/agents/mobile_agent_v3.py",
              "android_world/agents/infer_ma3.py"):
    fp = os.path.join(AW, probe)
    if not os.path.exists(fp):
        print(f"  ✗ 未找到 {probe}")
        continue
    print(f"\n  --- {probe} ---")
    for i, l in enumerate(open(fp, encoding="utf-8", errors="replace")):
        if re.match(r"^class ", l):
            print(f"    L{i+1}: {l.strip()[:96]}")

sec("③ 三端命名对照（官方用的到底是什么维度）")
print("""
  目录          入口脚本                            设备工具类
  ------------  ----------------------------------  -------------------
  mobile_use/   run_gui_owl_1_5_for_mobile.py       AdbTools        ← 通道名（adb）
  computer_use/ run_gui_owl_1_5_for_pc.py           ComputerTools   ← 平台名（PC）
  browser_use/  run_gui_owl_1_5_for_web.py          （无 Tools 类）
                  ↑ 全部 for_<平台>

  android_world_v3.5/  android_world/env/           AsyncEnv / AsyncAndroidEnv / AndroidWorldController
                  ↑ 这一整套【全部带 Android 前缀或 Android 字样】
""")
