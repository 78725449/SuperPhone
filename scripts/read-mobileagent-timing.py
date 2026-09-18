"""把 Mobile-Agent v3.5 的【时序】与【平台接入点】钉死，供"给 Mobile-Agent 加 iOS 平台"使用。

用户意图（2026-09-18）：
  "为 Mobile-Agent 的现有平台拓展出一个 iOS"；"wda 的实现有参考项目可参考"；
  "但集成逻辑要符合 Mobile-Agent 的当前架构时序设计"；"参考 wda 的方式，集成进 Mobile-Agent 中"。
  → 即：不改 Mobile-Agent 的规矩，只给它【加一个平台】；底层用我们的 SuperPhone 网关替代 WDA/ADB。

本脚本只读、不改任何文件。输出：
  ① run_gui_owl_1_5_for_mobile.py 的完整执行骨架（每步在做什么、顺序、数据流）
  ② AdbTools 的【完整方法清单】—— 这就是"iOS 版要实现的接口"
  ③ 平台是怎么被"选中"的（有没有分支、在哪分支）
  ④ 三端（mobile/PC/web）的时序是否一致
"""
import os, re, sys

ROOT = r"D:\编程项目\SuperPhone\_research\MobileAgent\Mobile-Agent-v3.5"


def show(title):
    print("\n" + "=" * 96)
    print(title)
    print("=" * 96)


def dump(path, start_pat=None, end_pat=None, limit=400, indent="  "):
    if not os.path.exists(path):
        print(f"{indent}✗ 文件不存在: {path}")
        return
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    s, e = 0, len(lines)
    if start_pat:
        hit = [i for i, l in enumerate(lines) if re.search(start_pat, l)]
        if not hit:
            print(f"{indent}✗ 未匹配 {start_pat}")
            return
        s = hit[0]
    if end_pat:
        hit = [i for i, l in enumerate(lines) if i > s and re.search(end_pat, l)]
        if hit:
            e = hit[0]
    for i in range(s, min(e, s + limit)):
        print(f"{indent}{i+1:4d}: {lines[i]}")


# ── ① 主执行骨架 ──────────────────────────────────────────
show("① mobile_use/run_gui_owl_1_5_for_mobile.py —— 完整执行骨架（时序）")
main_py = os.path.join(ROOT, "mobile_use", "run_gui_owl_1_5_for_mobile.py")
lines = open(main_py, encoding="utf-8", errors="replace").read().split("\n")
print(f"  文件 {len(lines)} 行\n")
# 打印 main() 全部
inmain = False
for i, l in enumerate(lines):
    if re.match(r"^def main\(", l):
        inmain = True
    if inmain:
        print(f"  {i+1:4d}: {l}")

# ── ② AdbTools 完整方法清单 ────────────────────────────────
show("② AdbTools 的完整方法清单 —— 这就是『iOS 版要实现的接口』")
dump(os.path.join(ROOT, "mobile_use", "utils.py"), r"^class AdbTools",
     r"^class |^def ", limit=200)

# ── ③ 平台是怎么被选中的 ───────────────────────────────────
show("③ 平台选择：三端是【各自一个入口脚本】还是【一个脚本里分支】？")
for sub in ("mobile_use", "computer_use", "browser_use"):
    d = os.path.join(ROOT, sub)
    if not os.path.isdir(d):
        continue
    print(f"\n  --- {sub}/ ---")
    for f in sorted(os.listdir(d)):
        if f.endswith(".py"):
            p = os.path.join(d, f)
            n = len(open(p, encoding="utf-8", errors="replace").read().split("\n"))
            print(f"    {f:44s} {n:4d} 行")
            hits = [l.strip() for l in open(p, encoding="utf-8", errors="replace")
                    if re.search(r"^(class |def main|if __name__)", l)]
            for h in hits[:8]:
                print(f"        {h[:92]}")

# ── ④ 三端的动作空间对比 ───────────────────────────────────
show("④ 三端动作空间（enum）对比 —— iOS 该实现哪一套")
for sub, name in (("mobile_use", "手机"), ("computer_use", "PC")):
    for f in os.listdir(os.path.join(ROOT, sub)):
        if not f.endswith(".py"):
            continue
        p = os.path.join(ROOT, sub, f)
        txt = open(p, encoding="utf-8", errors="replace").read()
        m = re.search(r'"enum":\s*\[([^\]]+)\]', txt)
        if m:
            print(f"  [{name}] {sub}/{f}")
            print(f"      enum = {m.group(1)[:300]}")

# ── ⑤ 坐标换算 ─────────────────────────────────────────────
show("⑤ 坐标换算：coordinate_resize.py 支持哪几种坐标制")
p = os.path.join(ROOT, "mobile_use", "coordinate_resize.py")
if not os.path.exists(p):
    # 可能在别的目录
    for root, _, files in os.walk(ROOT):
        if "coordinate_resize.py" in files:
            p = os.path.join(root, "coordinate_resize.py")
            break
if os.path.exists(p):
    print(f"  文件: {p}\n")
    txt = open(p, encoding="utf-8", errors="replace").read().split("\n")
    for i, l in enumerate(txt):
        if re.search(r"^(def |    def |class |# |COORD|.*coordinate_format)", l) or "format" in l.lower():
            print(f"  {i+1:4d}: {l[:110]}")
else:
    print("  ✗ 未找到 coordinate_resize.py")
