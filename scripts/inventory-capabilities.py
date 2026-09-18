"""能力对照盘点：我们的 57 个能力 vs 各框架要求的接口，算出【交集/缺口/闲置】。

回答用户三问：
  ① "我们应该看我们欠缺什么能力才对吧？"
  ② "我们对原项目是怎么改造的？"（改造清单见另一文档，本脚本只算能力）
  ③ "我们 app 自身各个动作的原语它知道了吗？"
只读，不改任何文件。
"""
import os, re

ROOT = r"D:\编程项目\SuperPhone"
DEV_SRC = os.path.join(ROOT, "TrollVNC", "src", "TRCapabilityRegistry.mm")
MA = os.path.join(ROOT, "_research", "MobileAgent", "Mobile-Agent-v3.5", "mobile_use")


def sec(t):
    print("\n" + "=" * 92)
    print(t)
    print("=" * 92)


# ── 我们设备端的全部能力 ──
txt = open(DEV_SRC, encoding="utf-8", errors="replace").read()
caps = sorted(set(re.findall(r'_registerControl:@"([^"]+)"', txt)))
print(f"设备端注册能力总数: {len(caps)}")

# ── Mobile-Agent（AdbTools）要的 9 个方法 ──
ADB_METHODS = ["get_screenshot", "click", "long_press", "slide", "back", "home",
               "type", "get_package_name", "open_app"]

# 我们的 IosTools 把这 9 个映射到了哪些能力
ADB_TO_CAP = {
    "get_screenshot": "screenshot",
    "click": "touch.tap",
    "long_press": "touch.longPress",
    "slide": "touch.swipe",
    "back": "touch.swipe（左缘右滑）",
    "home": "home",
    "type": "type.paste",
    "get_package_name": "app.list",
    "open_app": "app.open",
}
used = {v.split("（")[0] for v in ADB_TO_CAP.values()}

sec("① 对照一：Mobile-Agent（AdbTools 9 方法）")
print(f"  它要 {len(ADB_METHODS)} 个方法 → 我们用了 {len(used)} 个能力:")
for m in ADB_METHODS:
    print(f"    {m:20s} → {ADB_TO_CAP[m]}")

idle = [c for c in caps if c not in used and not c.startswith(("clients.", "gateway.", "settings.", "identity.", "sys.", "service."))]
sec(f"② ★ 我们【有】但 Mobile-Agent 【完全不知道】的能力（{len(idle)} 个）")
# 按用途分组
groups = {
    "感知/视觉（我们的独有优势）": ["vision.ocr", "vision.find_text", "vision.find_image"],
    "零模型校验/等待": ["screen.hash", "screen.snapshot", "script.exec"],
    "输入（比 adb 更正统）": ["keyboard", "type.delete"],
    "手势（它压根没有）": ["touch.doubleTap", "touch.pinch", "touch.taps",
                          "touch.twoFingerTap", "touch.threeFingerTap", "touch.curveSwipe"],
    "低层触控原语": ["touch.down", "touch.up", "touch.event", "touch.eventStream",
                     "touch.downMulti", "touch.upMulti", "touch.reset",
                     "touch.downMultiAt", "touch.upMultiAt"],
    "硬件/系统": ["power", "volup", "voldn", "mute", "bridn", "briup"],
    "剪贴板": ["clipboard.get"],
    "应用管理": ["app.list", "app.open"],
}
shown = set()
for gname, members in groups.items():
    hit = [m for m in members if m in caps]
    if hit:
        print(f"  [{gname}]")
        for m in hit:
            mark = "★ 已在 AdbTools 接口内" if m in used else "✗ 它用不到"
            print(f"      {m:22s} {mark}")
            shown.add(m)

rest = [c for c in idle if c not in shown]
if rest:
    print(f"  [其它]")
    for c in rest:
        print(f"      {c:22s} ✗ 它用不到")

sec("③ 对照二：别的框架要的、我们【没有】的能力（真缺口）")
# 来自 mobilerun Connection / DeviceDriver 的接口（子代理实测）
WANTED = [
    ("current_app_id / 查前台 App bundleId", "让 assert_on / wait_for_app 类逻辑可用", "缺 ✗"),
    ("terminate_app / app_stop", "强杀进程", "缺 ✗（官方降级建议 key('home')）"),
    ("open_url / deep link", "直接打开某链接", "缺 ✗"),
    ("install / uninstall IPA", "装卸应用", "缺 ✗（且有风险）"),
    ("grant_permission", "授予权限", "缺 ✗"),
    ("execute_script", "执行脚本", "有 ✓（script.exec）"),
    ("input_text / erase_text", "输入 / 删除", "有 ✓（type.paste / type.delete）"),
    ("press_button(home)", "Home 键", "有 ✓（home）"),
    ("screenshot", "截图", "有 ✓"),
    ("tap / swipe / long_press", "触控", "有 ✓"),
    ("list_apps / launch_app", "应用管理", "有 ✓（app.list / app.open）"),
]
for name, why, st in WANTED:
    print(f"  {st:26s} {name:38s} {why}")

sec("④ ★ 结论：缺的是【三类】，不是一类")
print("""
  A. 设备端【真缺】的能力（要从 TrollVNC 补，2-3 个）：
     · 查前台 App bundleId —— 最要紧（多框架都依赖它做"我在哪"的判定）
     · app.list 里包含系统 App（现在 `if (type == "System") continue;` 把它们滤掉了）
        → 后果：「打开设置」「打开相机」解析不到 bundleId
     · App 中文名规范（实测「微信」未命中：表里是 Android 的 com.tencent.mm）
        → 需确认 app.list 返回的 name 实际形态，再决定补别名还是改设备端

  B. 我们【有】但框架【用不到】的能力（约 30+ 个）：
     · 根因：Mobile-Agent 的动作空间是【枚举写死的 11 个 adb 风格动作】，
       SYSTEM_PROMPT 里根本没有 keyboard / find_text / screen.hash 这些词
     · → 不改它的提示词就永远用不上（而改提示词 = 改法，PR 会被拒）
     · → 正解是 MCP：工具由 tools/list 动态发现，不受枚举约束

  C. 我们【不该补】的能力（判断后放弃）：
     · install/uninstall IPA、grant_permission —— 风险高、与"内网自用"目标无关
     · terminate_app —— 官方降级建议就是 key('home')，我们已有 home
""")
