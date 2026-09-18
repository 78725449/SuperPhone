"""把《MobileAgent集成-命名与无缝方案》里的 VncTools 全面改为 IosTools，并重写命名章节。

**为什么要改**（用户质疑触发的修正，2026-09-18）：
  上一版凭"名字看起来对称"判定用 VncTools ✗。用户追问"它基于安卓平台来讲，针对的是 ios，
  它应该叫 ios 还是叫 vnc 呢？"→ 去查官方 PC 端怎么命名，露出真正的规则：

    官方三端入口脚本：run_gui_owl_1_5_for_mobile / _for_pc / _for_web   ← 【平台】维度
    官方两个工具类：  AdbTools（Android）/ ComputerTools（PC）
      · Android 有唯一官方通道 adb → 用通道名（Adb ≡ Android 那套操作，几乎同义）
      · PC 没有唯一通道（pyautogui/pywinauto 都行）→ 只能用平台名（Computer）
    → 隐含规则：**有唯一通道用通道名；没有唯一通道用平台名。**
    我们的 iOS 属于后者：没有唯一官方通道（VNC 看画面 + 私有能力做输入，VNC 只占一半）
    → 用 Vnc 命名属【过度承诺】（会让人以为任何 VNC 设备都能用），且实现深度绑定 iOS
    → 正确命名：**IosTools**（与 ComputerTools 同维度）

本脚本做的替换（按顺序，避免二次替换）：
  1. `mobile_use/vnc_tools.py` → `mobile_use/ios_tools.py`
  2. `vnc_tools.py`            → `ios_tools.py`
  3. `from vnc_tools import`   → `from ios_tools import`
  4. `VncTools`                → `IosTools`
  5. `vnc_tools`               → `ios_tools`（兜底）
  6. 重写"一、命名"整章
  7. 追加"修订记录"段

安全：先备份 → 替换 → 校验（无 VncTools 残留 + 仍含 IosTools ≥10 处）
"""
import os, shutil, sys, datetime

ROOT = r"D:\编程项目\SuperPhone"
DOC = os.path.join(ROOT, "MobileAgent集成-命名与无缝方案-2026-09-18.md")

raw = open(DOC, encoding="utf-8").read()
orig_len = len(raw.encode("utf-8"))

bkdir = os.path.join(ROOT, "data", "backups",
                     "naming-fix-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
os.makedirs(bkdir, exist_ok=True)
shutil.copy2(DOC, os.path.join(bkdir, os.path.basename(DOC)))
print("备份 -> " + bkdir + "\n")

NEW_NAMING = """## 一、命名：`IosTools` ✓ —— 不是 `VncTools`（本节 2026-09-18 修正）

### 1.1 先看官方自己的命名规则（决定性证据）

```
mobile_use/     run_gui_owl_1_5_for_mobile.py     class AdbTools        ← 通道名
computer_use/   run_gui_owl_1_5_for_pc.py         class ComputerTools   ← ★ 平台名
browser_use/    run_gui_owl_1_5_for_web.py        （无 Tools 类）
         ↑ 三个入口脚本全部是【平台】维度：for_mobile / for_pc / for_web
```

**官方两个工具类一个用通道名、一个用平台名** —— 看似不一致，但规则是清楚的：

| 平台情况 | 官方命名 | 实证 |
|---|---|---|
| **有唯一官方通道** | **用通道名** | Android → `AdbTools`（`adb` ≡ "Android 那套设备操作"，两者几乎同义）|
| **没有唯一通道** | **用平台名** | PC → `ComputerTools`（pyautogui / pywinauto 都行，没有"唯一那条路"）|

### 1.2 我们的 iOS 属于哪一种？→ **后者**

1. **iOS 没有"唯一官方通道"** —— 我们走的是**私有方案**（VNC 看画面 + 私有能力做输入）
2. **而且 VNC 只占一半** —— "看"走 VNC，"点 / 打 / 按"走的是我们自己的设备端能力（**RFB→IOHID**）
3. **用 `Vnc` 命名属【过度承诺】** —— 会让人以为"**任何 VNC 设备都能用这个工具**"，
   而它其实**深度绑定 iOS**：
   - `back()` = 边缘右滑（iOS 无硬件返回键，**这是 iOS 特有做法**）
   - `get_package_name()` 返回 **bundleId**（不是 Android 的 package name）
   - `type()` 走 `type.paste`（我们的能力，不是通用 VNC 能做的）

**→ 结论：`IosTools`** —— 与 `ComputerTools` 同维度，与三个入口脚本的
`for_mobile / for_pc / for_web` 同维度。

> **✗ 上一版的错误**：曾判定"`Adb` 是通道名，所以对标应是 `Vnc`" ——
> **只看到表面**。深一层：`Adb` 能进名字，是因为在 Android 上"adb ≡ 唯一的官方通道"，
> 两者在这个项目里**几乎同义**；而 iOS **没有这个等价物**。

### 1.3 完整命名表

| 项 | Android（官方） | PC（官方） | **我们（iOS）** |
|---|---|---|---|
| 入口脚本 | `run_gui_owl_1_5_for_mobile.py` | `run_gui_owl_1_5_for_pc.py` | **复用 mobile 脚本 + `--platform ios`** |
| 设备工具类 | `AdbTools` | `ComputerTools` | **`IosTools`** |
| 文件 | `mobile_use/utils.py` | `computer_use/utils.py` | **`mobile_use/ios_tools.py`** |
| 构造签名 | `(adb_path, device=None)` | — | **`(gateway, device=None)`** |
| 工厂 | （无） | （无） | **`mobile_use/device_tools.py` → `create_device_tools(platform, **kw)`** |
| 命令行 | `--adb-path` / `--device` | — | **`--platform {android,ios}`** / **`--gateway`** / `--device` |

**★★ 方法名必须与 `AdbTools` 【完全同名同签名】** —— 这是"无缝"的前提：
```python
get_screenshot(image_path, retry_times=3) -> bool
click(x, y)
long_press(x, y, duration=800)
slide(x1, y1, x2, y2, slide_time=800)
back()
home()
type(text)
get_package_name(all_packages=False) -> list[str]
open_app(package_name)
```

> **★ 留一个后路**：若将来 iOS 真出现了统一通道（如某天能在设备上跑 WDA），
> 那时可以再引入 `IosWdaTools` —— **平台名在前、通道名在后**，
> 这样"平台"维度稳定，"通道"维度可扩展 ✓
"""

# ── 定位并替换"一、命名"整章（到"## 二、"为止）──
start = raw.find("## 一、命名：")
end = raw.find("## 二、")
if start < 0 or end < 0 or end <= start:
    print("X 找不到命名章节边界（start=%d end=%d）" % (start, end))
    sys.exit(1)
print("命名章节: L%d 字符 起，到 L%d 字符 止（共 %d 字节）" %
      (start, end, len(raw[start:end].encode("utf-8"))))

raw = raw[:start] + NEW_NAMING + "\n---\n\n" + raw[end:]

# ── 全局改名 ──
repl = [
    ("mobile_use/vnc_tools.py", "mobile_use/ios_tools.py"),
    ("vnc_tools.py", "ios_tools.py"),
    ("from vnc_tools import", "from ios_tools import"),
    ("VncTools", "IosTools"),
    ("vnc_tools", "ios_tools"),
]
for a, b in repl:
    n = raw.count(a)
    if n:
        raw = raw.replace(a, b)
        print("  替换 %-28s → %-28s  %d 处" % (a, b, n))

# ── 追加修订记录 ──
raw += """
---

## 七、修订记录

| 日期 | 改了什么 | 触发 |
|---|---|---|
| 2026-09-18 | **命名由 `VncTools` 改为 `IosTools`**；重写"一、命名"章 | 用户质疑："它基于安卓平台来讲，针对的是 ios，它应该叫 ios 还是叫 vnc 呢？"—— 逼出"官方 PC 端叫 `ComputerTools`（平台名）"这条证据，才发现上一版凭"名字看起来对称"下的判断是错的。**隐含规则：有唯一通道用通道名（Android→Adb），没有就用平台名（PC→Computer）；iOS 属后者。** |
"""

new_len = len(raw.encode("utf-8"))
with open(DOC, "w", encoding="utf-8") as f:
    f.write(raw)

print()
print("=== 校验 ===")
now = open(DOC, encoding="utf-8").read()
ok = True
if "VncTools" in now:
    print("X 仍有 VncTools 残留: %d 处" % now.count("VncTools"))
    ok = False
else:
    print("OK 无 VncTools 残留")
n_ios = now.count("IosTools")
if n_ios < 8:
    print("X IosTools 只出现 %d 处（预期 >=8）" % n_ios)
    ok = False
else:
    print("OK IosTools 出现 %d 处" % n_ios)
if "vnc_tools" in now:
    print("X 仍有 vnc_tools 残留: %d 处" % now.count("vnc_tools"))
    ok = False
else:
    print("OK 无 vnc_tools 残留")

print()
print("文档: %d -> %d bytes" % (orig_len, new_len))
if not ok:
    print("X 校验未全过 —— 请人工检查（备份在 " + bkdir + "）")
    sys.exit(1)
print("OK 全部校验通过")
