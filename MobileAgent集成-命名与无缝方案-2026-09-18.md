# 命名与集成方案 —— 让 Mobile-Agent「合规且无缝」地多一个 iOS 平台（2026-09-18）

> 回答用户两问：
> ① **"我们应该用 vnc 的名来对标 adb 对吧？命名你打算怎么命名？"**
> ② **"你要怎么集成才能使其更合规且能被原 Mobile-Agent 上下游无缝集成？"**

---

## 一、命名：用 `Vnc` 对标 `Adb` ✓ —— 但理由比"对称"更深

### 1.1 为什么是 `VncTools` 而不是 `IOSTools` / `SuperPhoneTools`

| 候选 | 命名逻辑 | 判断 |
|---|---|---|
| **`VncTools`** | **`Vnc` = "用什么通道碰设备"** —— 与 `Adb` **同一逻辑** ✓ | ★ **推荐** |
| `IOSTools` | `IOS` 是**平台名**，`Adb` 是**通道名** → **逻辑不对称** ✗ | ✗ |
| `SuperPhoneTools` | 绑定我们项目名 → **"只有你有"，上游会被拒** ✗ | ✗ |

**★ 三条支撑理由**：
1. **命名逻辑对称**：`Adb`(Android Debug Bridge) ↔ `Vnc`(Virtual Network Computing) —— **都是"那条通往设备的通道"** ✓
2. **不绑定项目名** → **任何有 VNC 的设备都能用**（Android/PC 的 VNC server 同样适用）✓ → **上游更容易接受** ✓✓✓
3. **与它的文件风格一致**：官方 `mobile_use/utils.py` 里就一个 `AdbTools`；我们平行放一个 `mobile_use/vnc_tools.py` ✓

### 1.2 完整命名表

| 项 | Android（官方） | **我们（iOS / VNC）** | 理由 |
|---|---|---|---|
| 模块 | `mobile_use/utils.py`（内含 `AdbTools`）| **`mobile_use/vnc_tools.py`** | 同目录、同风格 |
| 类 | `AdbTools` | **`VncTools`** | **通道名对标** |
| 构造签名 | `__init__(self, adb_path, device=None)` | **`__init__(self, gateway, device=None)`** | 我们没有 `adb_path`，改收**网关地址** |
| 工厂 | （官方无）| **`mobile_use/device_tools.py` → `create_device_tools(platform, **kw)`** | 让 `main()` 只改 1 行 |
| 命令行 | `--adb-path` / `--device` | **`--platform {android,ios}`** / **`--gateway`** / `--device` | 显式、可扩展 |

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

---

## 二、★★★ "无缝"的真正难点（读源码才发现的）

### 2.1 问题：`open` 动作依赖两张 **Android 专属字典**

`handle_open_action`（`mobile_use/run_gui_owl_1_5_for_mobile.py:90-141`）：
```python
app_name = action_parameter.get("text", "")                 # 模型给 "抖音"
package_candidates = NAME_PACKAGE_DICT.get(app_name, [])    # ★ 字典①：显示名 → [Android 包名]
installed_packages = adb_tools.get_package_name()           # 设备层：已安装列表

for pkg in package_candidates:                              # ① 直接命中
    if pkg in installed_packages:
        adb_tools.open_app(pkg); return True

installed_app_names = []
for pkg in installed_packages:
    if pkg in PACKAGES_NAME_DICT:                           # ★ 字典②：Android 包名 → 显示名
        installed_app_names.append(PACKAGES_NAME_DICT[pkg][0])
resolved_name = resolve_app_name_via_llm(instruction, ", ".join(installed_app_names), ...)  # ② LLM 兜底

resolved_packages = NAME_PACKAGE_DICT.get(resolved_name, [])  # ③ 再查一次表
...
input(f"[ACTION REQUIRED] Please install the app: {display_name}")   # ④ 走到这儿 = 卡死
```

**★ 若 `VncTools.get_package_name()` 只返回 iOS bundleId** ✗：
- **①** `NAME_PACKAGE_DICT["抖音"]` 给的是 **Android 包名** → **不在我们的列表里** → **不命中** ✗
- **②** `PACKAGES_NAME_DICT[bundleId]` **查不到** → **`installed_app_names` 为空** → **LLM 兜底也废** ✗
- **③** 同样不命中 ✗
- **④** → **`input("Please install the app")` 阻塞** ✗ **任务卡死**

**→ 结论：光写一个 `VncTools` 是不够的，`open` 动作会走不通。**

### 2.2 解法：**运行时注入字典**（不改官方一行代码）✓✓✓

**前提已确认**：我们的 `app.list` **返回 `{name, bundleId}` 两个字段** ✓
（实证：`dsh-superphone/src/tools.ts:673` —
`const apps = (ack?.ack?.apps ?? []) as Array<{ name: string; bundleId: string }>`）

```python
# mobile_use/vnc_tools.py —— 在 VncTools 里做一次性注入
from packages import NAME_PACKAGE_DICT, PACKAGES_NAME_DICT

def _register_ios_apps(apps):
    """把 iOS 应用注入官方的两张字典，使 handle_open_action 无需修改即可命中。
    幂等：重复注册不会产生重复项。"""
    for a in apps:
        name, bid = a.get("name"), a.get("bundleId")
        if not (name and bid):
            continue
        PACKAGES_NAME_DICT.setdefault(bid, [name])        # 字典②：bundleId → 显示名
        lst = NAME_PACKAGE_DICT.setdefault(name, [])      # 字典①：显示名 → bundleId
        if bid not in lst:
            lst.append(bid)
```

**在 `VncTools.__init__`（或首次 `get_package_name()`）里调一次** ✓

**★ 效果**：
| 路径 | 注入前 | **注入后** |
|---|---|---|
| ① 直接查表 | ✗ 不命中 | ✓ `NAME_PACKAGE_DICT["抖音"]` → `["com.ss.iphone.ugc.Aweme"]` |
| ② LLM 兜底 | ✗ 候选为空 | ✓ `installed_app_names` 有内容 |
| ③ 再查表 | ✗ | ✓ |
| ④ 卡死提示 | **会走到** ✗ | **不会走到** ✓ |

**→ `handle_open_action` 一行都不用改** ✓✓✓ **完全无缝** ✓

---

## 三、集成方式：三层"合规"（加法而非改法）

### 3.1 改动总账

| # | 做什么 | 动了官方什么 |
|---|---|---|
| **① 新增** | `mobile_use/vnc_tools.py` —— `VncTools`（9 方法 + 字典注入）≈ **130 行** | **0** ✓ |
| **② 新增** | `mobile_use/device_tools.py` —— `create_device_tools(platform, **kw)` ≈ **25 行** | **0** ✓ |
| **③ 改 `main()`** | 加 `--platform` / `--gateway` 参数（**2 行**）+ `adb_tools = AdbTools(...)` → `adb_tools = create_device_tools(...)`（**1 行**）| **3 行** ✓ |
| **④ `AdbTools` 本身** | **完全不动** | **0** ✓ |
| **⑤ `handle_open_action`** | **完全不动**（靠字典注入）| **0** ✓ |
| **⑥ 时序 / `build_messages` / `parse_action` / `rescale_coordinates` / `annotate_screenshot`** | **完全不动** | **0** ✓ |

**★ 总计：2 个新文件 + 3 行改动。**

### 3.2 工厂函数（让 `main()` 只改 1 行）

```python
# mobile_use/device_tools.py —— 新增
def create_device_tools(platform="android", **kw):
    """按平台返回设备工具对象。
    android → AdbTools（官方原样）
    ios     → VncTools（走 SuperPhone 网关；与 AdbTools 同接口，可互换）"""
    if platform == "ios":
        from vnc_tools import VncTools
        return VncTools(gateway=kw.get("gateway"), device=kw.get("device"))
    from utils import AdbTools
    return AdbTools(adb_path=kw.get("adb_path"), device=kw.get("device"))
```

**`main()` 的改动**（`run_gui_owl_1_5_for_mobile.py`）：
```python
# 参数区（+2 行）
parser.add_argument("--platform", choices=["android", "ios"], default="android")
parser.add_argument("--gateway", default="http://localhost:8080",
                    help="SuperPhone 网关地址（platform=ios 时使用）")

# L148（改 1 行）
- adb_tools = AdbTools(adb_path=args.adb_path, device=args.device)
+ adb_tools = create_device_tools(args.platform, adb_path=args.adb_path,
+                                 gateway=args.gateway, device=args.device)
```

### 3.3 三条"合规"原则

1. **不加抽象基类** ✗ —— Python 鸭子类型本来就不需要；**加基类 = 动它的架构** ✗
2. **不改 `AdbTools`** ✓ —— 官方代码**零风险**；PR 只增不改，接受度最高
3. **用运行时注入解决字典依赖** ✓ —— 而不是改 `handle_open_action`（那是"改法"）

### 3.4 一个刻意的取舍：**变量名 `adb_tools` 保持不变**

- `main()` 里变量名是 `adb_tools`（L148），iOS 下语义不准 ✗
- **改名要牵动 12+ 处**（L148 / L177 / L210-237 / L249...）✗ → **PR 显著变大**
- **→ 保持不变** ✓，在 `VncTools` 的 docstring 里写明"**与 `AdbTools` 同接口、可互换**"
- （该方法名/变量名带来的"不精确"由**文档**承担，而不是由**大改**承担 ✓）

---

## 四、逐条对照：Android / WDA / 我们（"参考 WDA"的具体内容）

| `AdbTools` 方法 | Android 官方实现 | iOS（WDA 参考，`mobile-use/wda_client.py:71`）| **我们的实现** |
|---|---|---|---|
| `get_screenshot(path)` | `adb exec-out screencap -p` | `screenshot()` `:340` | **`screenshot` 能力** ✓ |
| `click(x,y)` | `input tap x y` | `tap(x,y)` `:296` | **`touch.tap`**（÷屏幕宽高归一化）✓ |
| `long_press(x,y,d)` | `input swipe x y x y d` | `tap(x,y,duration=大)` | **`touch.longPress`**（原生，更干净）✓ |
| `slide(x1..y2,t)` | `input swipe x1 y1 x2 y2 t` | `swipe(...)` `:315` | **`touch.swipe`** ✓ |
| `back()` | `input keyevent 4` | **WDA 没有 back** ✗ | **边缘右滑**（iOS 无硬件返回键）✓ |
| `home()` | `am start -a MAIN -c HOME` | `button(HOME)` `:446` | **`home`** 能力 ✓ |
| `type(text)` | 切 ADB Keyboard IME → broadcast | `text(text)` `:400` | **`type.paste`**（剪贴板，更简单）✓ |
| `get_package_name()` | `pm list packages` | **WDA 没有** ✗ | **`app.list`**（返回 `{name,bundleId}`）✓ |
| `open_app(pkg)` | `monkey -p pkg -c LAUNCHER 1` | `launch(bundle_id)` `:360` | **`app.open`** ✓ |

**★ 三处关键印证**：
1. **WDA 自己也没有 `back`** → **iOS 天生没有硬件返回键** → 我们"边缘右滑"是**正解而非凑合** ✓
2. **iOS 的 `type` 靠输入法/剪贴板注入** → 我们 `type.paste` 同一思路、更简单 ✓
3. **`get_package_name` WDA 都没有** → 我们靠 `app.list` **补上了它缺的那块** ✓

---

## 五、坐标：一步除法

```
官方链路：模型给 0-999 → smart_resize(1334,750,16)=(1328,752) → rescale_coordinates → 像素
          → AdbTools.click(x_px, y_px)          ← 收到的是【像素】

我们：在 click 里  {"x": x_px / self._w, "y": y_px / self._h}
      self._w/_h 来自 get_screenshot() 时 ack 返回的 width/height（= 750 / 1334 物理像素）
      → 【一步除法，无需额外换算】✓
```
**★ 顺带避开 mobilerun 踩过的坑**：它的 `ios_provider.py:71-92` 直写"iOS 截图是物理像素、
taps 是 points"，无契约时**直接拒绝坐标动作** ✗ —— **我们两端都按物理像素算，不存在这个歧义** ✓

---

## 六、自然语言小结

> **命名**：**用 `Vnc` 对标 `Adb`** ✓ —— 因为两者都是"**那条通往设备的通道**"的意思。
> 类叫 `VncTools`，文件叫 `vnc_tools.py`，和官方 `AdbTools` / `utils.py` 平行摆着。
> **不叫 `IOSTools`**（那是平台名，和"通道名"不是一回事），
> **更不叫 `SuperPhoneTools`**（绑了项目名，上游会觉得"只有你能用"而拒掉）。
>
> **集成**：**只加不改** —— 新增 2 个文件（`vnc_tools.py` + `device_tools.py`），
> `main()` 只改 3 行（加两个参数、把实例化换成工厂调用），**其余一行不动**。
>
> **最要紧的一步是"运行时注入字典"**：因为 `open` 动作（打开 App）偷偷依赖两张
> **Android 包名**的字典 —— 我们如果不处理，模型一说"打开抖音"就会走到
> "请你安装这个应用"然后卡死。**解决办法是在 `VncTools` 里把 iOS 的应用名与 bundleId
> 注入那两张字典**，这样 `handle_open_action` 一个字都不用改就能正常工作。
>
> **这样得到的东西**：Mobile-Agent 官方代码多出一个 `--platform ios`，
> 底下连的是我们的手机；**它的时序、数据结构、动作协议、提示词，全都没动** ✓
