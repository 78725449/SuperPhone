# 给 Mobile-Agent 加一个 iOS 平台 —— 方案（2026-09-18）

> **用户意图（原话）**：
> "为 Mobile-Agent 的现有平台拓展出一个 iOS，然后 wda 的实现我们是有参考项目可以参考的，
> 但是集成逻辑要符合 Mobile-Agent 的当前架构时序设计，参考 wda 的方式，集成进 Mobile-Agent 中。"
>
> **即**：**不改 Mobile-Agent 的规矩，只给它【加一个平台】**；
> **WDA 只参考"iOS 上这个动作该怎么做"，不参考它的部署方式**（要 Mac / 装 runner / iproxy ✗）；
> **底层用我们的 SuperPhone 网关**（VNC + 57 能力）。

---

## 一、Mobile-Agent 的时序（读源码得出，`mobile_use/run_gui_owl_1_5_for_mobile.py:144-283`）

```
main():
  L148  adb_tools = AdbTools(adb_path, device)          ← ★ 设备层在这里被创建（唯一的硬编码点）
  L168  history = []

  for step_id in range(max_steps):                       ← ── 主循环 ──
      L177  ① adb_tools.get_screenshot(path)             ← 设备调用：截图
      L183  ② messages = build_messages(path, instruction, history, model)
      L188     output_text = GUIOwlWrapper(...).predict_mm(messages)   ← 模型决策
      L193  ③ action = parse_action(output_text)         ← 解析 <tool_call>
      L198  ④ smart_resize(...) + rescale_coordinates(...)  ← 0-999 → 像素
      L209  ⑤ if/elif 执行动作：
              click/long_press/type/swipe/system_button  → adb_tools.xxx()   ← 设备调用：动作
              wait/terminate/open/answer/interact        → 其他
      L275  ⑥ history.append({output, image})            ← 记历史
      L276     annotate_screenshot(...)                  ← 画标注图（与设备无关）
      L281     time.sleep(2)
```

**★ 关键结论**：
- **设备层只在【两个地方】被调用**：① 截图（L177）② 动作（L209-272）✓
- **`AdbTools` 是【构造函数直接 new 出来的裸类】**，没有接口/基类 ✓
- **`handle_open_action(..., adb_tools, ...)`（L249）已经把设备对象【当参数传】** ✓
  → **它已经是鸭子类型，不需要改** ✓✓✓

---

## 二、要实现的接口（`AdbTools` 全集，`mobile_use/utils.py:70-189`）

```python
class AdbTools:
    def __init__(self, adb_path, device=None)                    # L73
    def get_screenshot(self, image_path, retry_times=3) -> bool  # L93   ★ 被调用
    def click(self, x, y)                                        # L111  ★
    def long_press(self, x, y, duration=800)                     # L115  ★
    def slide(self, x1, y1, x2, y2, slide_time=800)              # L119  ★
    def back(self)                                               # L123  ★
    def home(self)                                               # L127  ★
    def type(self, text)                                         # L134  ★
    def get_package_name(self, all_packages=False)               # L157  （被 handle_open_action 用）
    def open_app(self, package_name)                             # L184  （同上）
```
**★ 一共 9 个公开方法 —— 这就是"iOS 版"要实现的全部内容** ✓
（`_run` / `_load_image_info` 是内部辅助，不必照抄）

---

## 三、Android vs iOS 的逐条对照（"参考 WDA"的具体内容）

**参考源**：`mobile-use/minitap/mobile_use/clients/wda_client.py:71` `WdaClientWrapper`

| `AdbTools` 方法 | Android 实现（官方） | iOS 怎么做（WDA 参考） | **我们怎么做** |
|---|---|---|---|
| `get_screenshot(path)` | `adb exec-out screencap -p` | `screenshot()`(`:340`) | **`screenshot` 能力** ✓ |
| `click(x,y)` | `input tap x y` | `tap(x,y)`(`:296`) | **`touch.tap`**（坐标 → 0-1）✓ |
| `long_press(x,y,d)` | `input swipe x y x y d` | `tap(x,y,duration=大)` | **`touch.longPress`**（原生，更直接）✓ |
| `slide(x1..y2,t)` | `input swipe x1 y1 x2 y2 t` | `swipe(...)`(`:315`) | **`touch.swipe`** ✓ |
| `back()` | `input keyevent 4` | **WDA 没有 back** ✗ | **边缘右滑**（iOS 无硬件返回键）✓ |
| `home()` | `am start -a MAIN -c HOME` | `button(HOME)`(`:446`) | **`home`** 能力 ✓ |
| `type(text)` | 切 ADB Keyboard IME → broadcast | `text(text)`(`:400`) | **`type.paste`**（剪贴板，比 ADB Keyboard 简单）✓ |
| `get_package_name()` | `pm list packages` | **WDA 没有** ✗ | **`app.list`** ✓ |
| `open_app(pkg)` | `monkey -p pkg -c LAUNCHER 1` | `launch(bundle_id)`(`:360`) | **`app.open`** ✓ |

**★★★ 三处关键印证**：
1. **WDA 自己也没有 `back`** ✗ → **iOS 天生没有硬件返回键**，我们"边缘右滑"是**正确做法**，不是凑合 ✓
2. **iOS 上 `type` 用 `text()`**（WDA 输入法注入）→ 我们用 `type.paste`（剪贴板）**同理**，且更简单 ✓
3. **`long_press` 在 WDA 里是 `tap` 传大 duration** → 我们**有原生 `touch.longPress`**，比它更干净 ✓

---

## 四、★★ 坐标：天然对齐，只需一步除法

**官方链路**（`run_gui_owl_1_5_for_mobile.py:198-204`）：
```
模型给 0-999（"屏幕是 1000×1000"）
  → smart_resize(1334, 750, factor=16) → (1328, 752)
  → rescale_coordinates() → resized 像素坐标
  → AdbTools.click(x_px, y_px)  ← ★ 收到的是【像素】
```

**我们要做的**：
```
我们在 click(x_px, y_px) 里：
    self._invoke("touch.tap", {"x": x_px / self._w, "y": y_px / self._h})
其中 self._w/_h 从 get_screenshot 时的 ack.width/height 记录（= 750/1334 物理像素）
→ 【一步除法，无需额外换算】✓
```
**→ 这也顺带解决了 mobilerun 踩过的"截图是物理像素、输入是 points"那个坑**（我们两端都按物理像素算）✓

---

## 五、改动清单（★ 对 Mobile-Agent 只做最小加法）

| # | 改什么 | 位置 | 规模 |
|---|---|---|---|
| **1** | **新增 `mobile_use/ios_tools.py`** —— `IOSTools` 类，9 个方法与 `AdbTools` 同名同签名，内部走 SuperPhone 网关 HTTP | 新文件 | **~120 行** |
| **2** | **让 `main()` 能选到它** | `run_gui_owl_1_5_for_mobile.py:148` | **3-5 行**（加 `--platform` 或按 device 判断）|
| **3** | **`handle_open_action` 不用改** ✓ | —— | **0** |
| **4** | **时序、`build_messages`、`parse_action`、`rescale_coordinates`、`annotate_screenshot` 全不改** ✓ | —— | **0** |

**★ 改动总计：1 个新文件 + 3-5 行。**

**★ 甚至更保守的做法**：`IOSTools` **继承 `AdbTools`** 并覆盖 9 个方法 ——
这样连 `main()` 都不用改（`AdbTools` 名字不变，只是行为换成 iOS）✓
（但更推荐显式加 `--platform`，语义清楚）

---

## 六、`IOSTools` 的接口设计（伪代码）

```python
# mobile_use/ios_tools.py  —— 新增
class IOSTools:
    """与 AdbTools 同接口；底层走 SuperPhone 网关（VNC 画面 + 57 能力）。
    与 AdbTools 的差异：不需要 adb_path（改收 gateway URL + deviceId）。"""
    def __init__(self, gateway="http://localhost:8080", device=None):
        self.gw, self.dev = gateway, device
        self._w, self._h = 750, 1334          # 从 screenshot 的 ack 里更新

    def _invoke(self, cap, params=None, timeout=60): ...   # 内部：POST /api/devices/{id}/invoke

    def get_screenshot(self, image_path, retry_times=3) -> bool:
        # 调 `screenshot` 能力 → base64 → 写文件 → 记 self._w/_h
    def click(self, x, y):        self._invoke("touch.tap",       {"x": x/self._w, "y": y/self._h})
    def long_press(self, x, y, duration=800):
                                  self._invoke("touch.longPress", {"x": x/self._w, "y": y/self._h})
    def slide(self, x1, y1, x2, y2, slide_time=800):
                                  self._invoke("touch.swipe", {...})
    def back(self):               self._invoke("touch.swipe", {左缘右滑})   # iOS 无返回键
    def home(self):               self._invoke("home")
    def type(self, text):         self._invoke("type.paste", {"text": text})
    def get_package_name(self, all_packages=False) -> list[str]:
                                  # 调 `app.list` → 返回 bundleId 列表
    def open_app(self, package_name): self._invoke("app.open", {"bundleId": package_name})
```

**★ 注意**：`get_package_name` 返回的是 **bundleId**（iOS 的"包名"）✓
—— 这也意味着官方 `packages.py` 的**中文别名表（55+ 条 `com.tencent.mm → 微信`）对 iOS 不适用** ✗
（Android 包名 vs iOS bundleId 不同）→ **iOS 侧要么另建别名表，要么用 `app.list` 里的显示名匹配** ✓

---

## 七、自然语言小结

> **要做的事**：给 Mobile-Agent 补一个 iOS 平台。
> **补的方式**：照着它 Android 那层的接口（`AdbTools` 9 个方法），**再写一个同接口的 iOS 版本**
> （`IOSTools`），**底层连我们的 SuperPhone 网关**而不是 ADB。
>
> **时序一点都不动** —— 截图 → 给模型 → 解析动作 → 换算坐标 → 执行 → 记历史 → sleep(2)，
> 这套骨架是它定好的，我们只是把"执行"那一步背后的实现换掉。
>
> **`back`/`home`/`type`/`open_app` 这些"iOS 上该怎么做"参考 WDA**（mobile-use 的实现）：
> - 学到三件事：**iOS 没有返回键**（WDA 自己都没有 `back`）、**输入靠输入法/剪贴板注入**、
>   **Home 是独立按键能力**
> - **不学它的部署**：不装 WebDriverAgentRunner、不要 Mac、不要 iproxy ✓
>
> **结果**：Mobile-Agent 官方代码多出一个平台 iOS，跑起来底下是我们的手机，
> **且我们比它原有的三端还多两个能力**——设备端 OCR 定位、以及更直白的 HID 键输入。
