"""核对：Mobile-Agent 声明的【全部原语】vs 我们能否用设备能力实现。

用户问："它原语中有了什么样的动作了？它原语能识别的动作我们都用我们的实现给它加上了吗？"
→ 先把它声明的原语列全（含 system_button 的子动作），再逐条对照我们的设备能力。

★ 注意：设备端能力有【两种注册方式】——
  ① `_registerControl:@"x"`            字面量（上次只 grep 了这种，漏了第二种 ✗）
  ② 数组 + for 循环（`hidNoParam`）     ★ 上次盘点漏了这一批
本脚本两种都收。
只读，不改任何文件。
"""
import os, re

ROOT = r"D:\编程项目\SuperPhone"
DEV_SRC = os.path.join(ROOT, "TrollVNC", "src", "TRCapabilityRegistry.mm")


def sec(t):
    print("\n" + "=" * 94)
    print(t)
    print("=" * 94)


txt = open(DEV_SRC, encoding="utf-8", errors="replace").read()

# ── 两种注册方式都收 ──
literal = set(re.findall(r'_registerControl:@"([^"]+)"', txt))
# 数组驱动：@{@"id":@"xxx", ...} 形式
array_ids = set(re.findall(r'@\{@"id":@"([^"]+)"', txt))
all_caps = sorted(literal | array_ids)

sec("① 设备端全部能力（两种注册方式合并）")
print(f"  字面量注册 _registerControl:@\"x\"  : {len(literal)} 个")
print(f"  数组驱动 @{{@\"id\":@\"x\"}}         : {len(array_ids)} 个   ← ★ 上次盘点漏了这一批")
print(f"  合计                                : {len(all_caps)} 个")
if array_ids:
    print(f"\n  ★ 数组驱动的那批（上次漏掉的）:")
    for c in sorted(array_ids):
        print(f"      {c}")

# ── 它声明的原语（含子动作）──
ACTIONS = ["key", "click", "long_press", "swipe", "type", "system_button",
           "open", "wait", "answer", "interact", "terminate"]
BUTTONS = ["Back", "Home", "Menu", "Enter"]

# main() 里实际有分支的
IMPLEMENTED = {"click", "long_press", "swipe", "type", "system_button",
               "open", "wait", "answer", "interact", "terminate"}
BUTTON_IMPL = {"Back", "Home"}

sec("② ★ 它声明的原语 vs main() 里实际有分支的")
print("  【动作 enum】")
missing = []
for a in ACTIONS:
    ok = a in IMPLEMENTED
    mark = "有分支" if ok else "★ 无分支（落 else 静默丢弃）"
    print(f"      {a:16s} {mark}")
    if not ok:
        missing.append(a)
print("  【system_button 的子动作】")
for b in BUTTONS:
    ok = b in BUTTON_IMPL
    mark = "有分支" if ok else "★ 无分支"
    print(f"      {b:16s} {mark}")
    if not ok:
        missing.append("system_button{" + b + "}")

sec(f"③ 结论：漏了 {len(missing)} 个 —— {missing}")
print("""
  它声明了 11 个动作 + 4 个子动作 = 15 个"原语"
  main() 实际实现了 10 个 + 2 个子动作 = 12 个
  → ❌ 漏 3 个：key · system_button{Menu} · system_button{Enter}
""")

# ── 逐条给出可用的设备能力 ──
sec("④ ★ 这 3 个漏项，我们的设备能力能否实现")
print("""
  【1】key（schema 说明：supports adb's keyevent syntax，
               examples: "volume_up" / "volume_down" / "power" / "camera" / "clear"）
        → 可按名字映射到我们已有能力：
            volume_up   → volup        ✓ 已注册
            volume_down → voldn        ✓ 已注册
            power       → power        ✓ 已注册
            clear       → type.delete  ✓ 已注册（清空输入框）
            camera      → ❌ 无对应（iOS 无"打开相机"系统键；可用 app.open 相机）
            back / home → 已有 back()/home() 方法
        → 结论：可实现（5/6 直接有，camera 降级为 app.open）

  【2】system_button{Menu}（schema 说明：opening the application background menu）
        → ★★ iOS 上"应用后台菜单"就是【双击 Home】= 我们的 `home.double` ✓ 已注册
        → 结论：可实现，而且语义**完全对应**（比 Android 的 keyevent MENU 更贴）

  【3】system_button{Enter}（schema 说明：pressing the enter）
        → 需要"发回车键"。设备端 `keyboard` 能力是【无参数】的（只 toggle 屏幕键盘）
           → 需确认是否有可发具体键（含回车）的能力；若没有，则需设备端补一个
        → 结论：★ 待确认（可能要动设备端）
""")

sec("⑤ ★ 顺带修正：我们还有一批能力【它的原语里没有对应】，但价值高")
for c in all_caps:
    if c in ("home.double", "home.long", "spotlight", "power.double", "power.triple",
             "power.long", "hwlock", "hwunlock", "releasekeys"):
        print(f"      {c:16s} ★ 它的 enum 里没有这个动作名 —— 除非走 key() 或扩展 enum")
print("""
  → 这批（double Home / spotlight / 双击电源 / 三击电源 / 长按电源 / 硬件键盘锁…）
    在它【现有的 enum 里没有位置】：
      · home.double 可作为 system_button{Menu} 的实现（✓ 已找到位置）
      · spotlight    需要 key("spotlight") 或新动作（✗ 无位置）
      · 其余同上
  → 所以「在它原语框架内补齐」能覆盖的，就是那 3 个漏项对应的一小批；
     更多能力（如 spotlight / 双击电源）在当前 enum 下【没有入口】。
""")
