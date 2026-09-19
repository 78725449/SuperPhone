# 给 Mobile-Agent 加 iOS：架构设计（2026-09-18）

> **用户的问题**：
> "我们是不是可以复用 mobile 脚本，只在与安卓平级的下方分支工具文件签名等地方开发一个 IOS 分支？
> 还是怎么样，架构是什么样的？"
>
> **答**：**对，就是你说的那样** —— 而且官方自己的命名已经预示了这个架构。

---

## 一、★ 决定架构的证据：Android 是怎么命名的（全量勘察）

```
【目录】 mobile_use/                        ← ★ 是 mobile，不是 android
【入口】 run_gui_owl_1_5_for_mobile.py      ← ★ 是 for_mobile，不是 for_android
【文件】 utils.py —— 内含 class AdbTools
【构造】 def __init__(self, adb_path, device=None)
【CLI】  --adb_path · --device · --api_key · --base_url · --model · --instruction
         · --add_info · --max_steps · --app_resolver_api_key/_base_url/_model
【变量】 adb_tools（在入口脚本里出现 12 处：L93/107/113/136/148/177/210/216/222/225/235/237/252）
```

### 1.1 官方实际用的是【两层维度】

| 层级 | 官方命名 | **维度** |
|---|---|---|
| **平台类别**（目录 + 入口脚本）| `mobile_use` / `computer_use` / `browser_use`；`for_mobile` / `for_pc` / `for_web` | **平台类别** ✓ |
| **该类别的具体实现**（设备工具类）| `AdbTools`（mobile）/ `ComputerTools`（pc）| **实现方式** ✓ |

**★★ 关键结论**：
> **目录与入口用【平台类别】（`mobile`），工具类用【实现方式】（`Adb`）** ✓
> **→ 所以 iOS 与 Android 是【同一个类别（mobile）下的两个实现】** ✓✓✓
> **—— 而不是两个平行类别** ✗

**★★★ 这也解释了我前两轮的反复**：
- 第一轮我说"用 `VncTools`（通道名）" —— **只看了工具类那一层** ✓ 对但不全
- 第二轮我说"用 `IosTools`（平台名）" —— **把两层的维度搞混了** ✗
- **正确**：**目录/入口 = 平台类别（`mobile`，复用）；工具文件 = 实现方式（`Adb` / `Ios`）** ✓

---

## 二、★ 架构（推荐方案 A）

```
Mobile-Agent-v3.5/
│
├── mobile_use/                          ★ 【手机】平台类别 —— iOS 与 Android 同属，不新建 ios_use/
│   │
│   ├── run_gui_owl_1_5_for_mobile.py     入口：时序骨架（★ 只改 3 行）
│   │     ① 截图   → device_tools.get_screenshot()
│   │     ② 模型   → build_messages + GUIOwlWrapper        （不动）
│   │     ③ 解析   → parse_action                           （不动）
│   │     ④ 换算   → smart_resize + rescale_coordinates     （不动）
│   │     ⑤ 执行   → device_tools.click/swipe/type/...     ← ★ 唯一与平台相关的一步
│   │     ⑥ 记历史 → history.append + annotate_screenshot   （不动）
│   │
│   ├── device_tools.py    ★ 新增：工厂 create_device_tools(platform, **kw)
│   ├── utils.py           （官方）AdbTools   ← Android 实现，一行不动
│   ├── ios_tools.py       ★ 新增：IosTools   ← iOS 实现，与 utils.py 平级
│   └── packages.py        （官方）App 别名表（Android 包名）← 不改，靠运行时注入
│
├── computer_use/           【PC】平台类别（不动）
├── browser_use/            【浏览器】平台类别（不动）
└── android_world_v3.5/     【评测框架】另一条线（不碰）
```

### 2.1 为什么【不】新建 `ios_use/` 目录

| 方案 | 做法 | 判断 |
|---|---|---|
| **A（推荐）** | 在 `mobile_use/` 里加**平级工具文件** | **2 新文件 + 3 行** ✓ |
| **B** | 新建 `ios_use/` + `run_gui_owl_1_5_for_ios.py` | **288 行脚本复制一份** ✗ |

**★ 方案 B 的问题**：
- 两者的差异**只在设备工具那 9 个方法**（约 40 行）✓
- **其余约 280 行完全相同** ✗ → 复制一份 = **上游改一处就要同步两处** ✗ **维护灾难**

**★ 而且方案 B 在语义上也是错的**：`mobile` 是"手机"这个**类别**，
iOS 和 Android 都是手机 → **它们本来就该在同一个目录下** ✓

---

## 三、★★★ 三个关键设计点

### 3.1 目录复用 `mobile_use/`（因为它的名字是类别名）

- **`mobile_use` / `computer_use` / `browser_use`** 是**三个平台类别** ✓
- **iOS 属于 `mobile`** ✓ → **不新建目录** ✓

### 3.2 工具文件与 `utils.py` 平级（用户说的"下方分支工具文件"）

```
mobile_use/
    utils.py         AdbTools     ← 官方：Android via adb
    ios_tools.py     IosTools     ← 我们：iOS via SuperPhone 网关    ★ 新增
    device_tools.py  （工厂）      ← 抹平构造签名差异                  ★ 新增
```

### 3.3 工厂函数抹平"构造签名不同"（回答"签名等地方"）

**★ 9 个【方法】签名必须完全一致**（鸭子类型的前提）✓：
```python
get_screenshot(image_path, retry_times=3) -> bool
click(x, y) · long_press(x, y, duration=800) · slide(x1, y1, x2, y2, slide_time=800)
back() · home() · type(text)
get_package_name(all_packages=False) -> list[str] · open_app(package_name)
```

**★★ 但【构造】签名必然不同**（我们没有 `adb_path`）✗：
```python
AdbTools(adb_path=..., device=...)      # Android
IosTools(gateway=..., device=...)       # iOS
```
**★★★ → 这就是工厂存在的理由** ✓：
```python
def create_device_tools(platform="android", **kw):
    if platform == "ios":
        from ios_tools import IosTools
        return IosTools(gateway=kw.get("gateway"), device=kw.get("device"))
    from utils import AdbTools
    return AdbTools(adb_path=kw.get("adb_path"), device=kw.get("device"))
```

---

## 四、将来的扩展路径（这条也顺了）

**若哪天 Android 手机也能跑 VNC**，或出现别的通道 ✗ → **`IosTools` 就不再合适** ✗
**但那时可以加第三个** ✓：

```
mobile_use/
    utils.py       AdbTools    ← 官方：Android via adb
    ios_tools.py   IosTools    ← 我们：iOS via SuperPhone 网关
    vnc_tools.py   VncTools    ← 将来：任何平台 via VNC（若需要）
```

**→ 即：`mobile_use/` 下的工具文件按【实现方式】命名** ✓
**—— 与官方的 `AdbTools` 同一维度** ✓✓✓
**（目录/入口 = 平台类别；工具文件 = 实现方式。官方两层就是这么分的。）**

---

## 五、改动总账（不变）

| # | 做什么 | 规模 | 动了官方什么 |
|---|---|---|---|
| ① | **新增** `mobile_use/ios_tools.py` —— `IosTools`（9 方法 + 运行时注入字典）| ≈130 行 | **0** |
| ② | **新增** `mobile_use/device_tools.py` —— 工厂 | ≈25 行 | **0** |
| ③ | **改 `run_gui_owl_1_5_for_mobile.py`**：加 `--platform`/`--gateway`（2 行）+ `adb_tools = AdbTools(...)` → `device_tools = create_device_tools(...)`（1 行）| **3 行** | **3 行** |
| ④ | `AdbTools` / `handle_open_action` / 时序 / `build_messages` / `parse_action` / `rescale_coordinates` / `annotate_screenshot` / `packages.py` | — | **0** |

**★ 总计：2 个新文件 + 3 行改动。**

> **★ 变量名的小取舍**：`main()` 里变量名 `adb_tools` 已出现 12 处 ✗
> **改名 = 12 处 + PR 变大** ✗ → **保持不动** ✓，由 `IosTools` 的 docstring 说明可互换 ✓

---

## 六、自然语言小结

> **你问的架构，就是"目录复用、工具文件分叉"** ✓
>
> **上层（`mobile_use/` 目录 + `run_gui_owl_1_5_for_mobile.py`）是【手机】这个平台类别，iOS 和 Android 共用。**
> 手机上跑的那套时序 —— 截图、给模型、解析、换算、执行、记历史 —— **一行都不动**。
>
> **下层（设备工具）分叉成两个文件**：`utils.py` 里是官方的 `AdbTools`（走 adb），
> `ios_tools.py` 里是我们的 `IosTools`（走 SuperPhone 网关）。
> 两者**方法签名完全一样**，所以脚本里怎么调 `AdbTools` 就怎么调 `IosTools`。
>
> **唯一的差异是构造函数**（我们没有 `adb_path`，改收网关地址）——
> 所以加一个薄薄的工厂函数，让脚本里那一行"创建工具"变成按平台选择。
>
> **不新建 `ios_use/` 目录** —— 因为 `mobile` 是"手机"这个类别名，
> 新建目录等于把 288 行的脚本抄一遍，只为改其中 9 个方法的实现，而且以后上游一改就要同步两处。
