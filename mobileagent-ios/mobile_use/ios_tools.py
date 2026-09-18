"""IosTools —— 给 Mobile-Agent 加 iOS 平台：`AdbTools` 的 iOS 实现（同接口，可互换）。

设计原则（2026-09-18）：
  ① **与 `AdbTools` 完全同名同签名** —— 9 个方法逐个对齐，靠鸭子类型互换，
     因此 `run_gui_owl_1_5_for_mobile.py` 里除"创建对象"那一行外【一行都不用改】。
  ② **不依赖 adb / WDA / Mac / 设备端额外进程** —— 全部经 SuperPhone 网关
     （HTTP + VNC 隧道；画面走 VNC，输入走 RFB→IOHID 注入）。
  ③ **对 Mobile-Agent 只增不改** —— 官方 `AdbTools` / `handle_open_action` / `packages.py`
     一个字都不动；iOS 应用通过 `_register_ios_apps()` 在【运行时】注入官方那两张别名表。

★ 坐标约定（重要）
  Mobile-Agent 的 `rescale_coordinates()` 已把模型的 0-999 换算成【截图的实际像素】，
  所以本类的方法收到的 x/y 是【像素】；而 SuperPhone 的 `touch.*` 能力收【0-1 归一化】。
  故这里统一除以 `self._w / self._h`（来自 `screenshot` 返回的 width/height）。
  —— 两端都按【物理像素】记，不存在 mobilerun 踩过的"截图是像素、输入是 points"歧义。

★ 与 WDA 参考实现的差异（参考其动作语义，不参考其部署）
  | 动作        | WDA（mobile-use）      | 本实现                                            |
  | tap         | tap(x,y)               | touch.tap                                          |
  | long_press  | tap(x,y,duration=大)   | touch.longPress（原生，更干净）                    |
  | swipe       | swipe(...)             | touch.swipe                                        |
  | type        | text()（输入法注入）    | type.paste（剪贴板，同理且更简单）                 |
  | home        | button(HOME)           | home（GSEvent 模拟 Home 键）                       |
  | back        | ❌ WDA 也没有 back      | 左缘右滑（iOS 无硬件返回键，这是正解而非凑合）     |
  | list apps   | ❌ WDA 没有            | app.list（返回 bundleId + 显示名）                 |
"""

import base64
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

# 官方别名表：只【读取并注入】，绝不修改该文件本身
from packages import NAME_PACKAGE_DICT, PACKAGES_NAME_DICT

__all__ = ["IosTools"]

# iOS 真机默认物理分辨率（iPhone 6s）；仅在"未先截图就点击"时作兜底
_DEFAULT_W = 750
_DEFAULT_H = 1334


class IosTools:
    """Wrapper around the SuperPhone gateway for device interaction.

    Drop-in replacement for `AdbTools`（同 9 个方法、同签名）。
    """

    def __init__(self, gateway="http://127.0.0.1:8080", device=None, token=None, timeout=60):
        """
        Args:
            gateway: SuperPhone 网关地址，如 "http://127.0.0.1:8080"。
                     对应 `AdbTools` 的 `adb_path`（都是"通往设备的那条路的地址"）。
            device:  设备 id；为 None 时自动取网关里第一台在线设备。
            token:   网关 token（部署带 FARM_TOKEN 时必填）。
        """
        self.gateway = gateway.rstrip("/")
        self.device = device
        self.token = token or os.environ.get("FARM_TOKEN") or None
        self.timeout = timeout
        self.image_info = None            # (w, h)，与 AdbTools 同名，便于调用方兼容
        self._w, self._h = _DEFAULT_W, _DEFAULT_H
        self._apps_cache = None           # app.list 结果缓存（避免每步都拉）
        self._ios_apps_registered = False

    # -- helpers ----------------------------------------------------------
    # ⚠️ 以下三行是给静态检查器的"存在性声明"：NAME_PACKAGE_DICT / PACKAGES_NAME_DICT
    #    在 _register_ios_apps() 里被就地修改，这里只是让 flake8 等不误报未使用。
    _OFFICIAL_DICTS = (NAME_PACKAGE_DICT, PACKAGES_NAME_DICT)

    def _headers(self):
        h = {"Content-Type": "application/json"}
        if self.token:
            h["Authorization"] = "Bearer " + self.token
        return h

    def _pick_device(self):
        """未指定 device 时，取网关里第一台在线设备。"""
        req = urllib.request.Request(self.gateway + "/api/devices",
                                     headers=self._headers(), method="GET")
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            devices = (json.load(r) or {}).get("devices") or []
        if not devices:
            raise RuntimeError("SuperPhone 网关里没有任何设备")
        online = [d for d in devices if d.get("online")]
        return (online or devices)[0].get("id")

    def _invoke(self, cap, params=None, timeout=None):
        """调网关 invoke 通道。返回 ack 字典（不含最外层 ok 包装）。"""
        if self.device is None:
            self.device = self._pick_device()
        body = json.dumps({"cap": cap, "params": params or {}}).encode("utf-8")
        url = "%s/api/devices/%s/invoke" % (self.gateway, urllib.parse.quote(str(self.device)))
        req = urllib.request.Request(url, data=body, headers=self._headers(), method="POST")
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as r:
                payload = json.load(r)
        except urllib.error.HTTPError as e:
            raise RuntimeError("网关 %s 调用失败 HTTP %s: %s" %
                               (cap, e.code, e.read().decode("utf-8", "replace")[:200]))
        ack = (payload or {}).get("ack") or {}
        if ack.get("ok") is False:
            raise RuntimeError("能力 %s 执行失败: %s" % (cap, ack.get("error") or payload.get("error")))
        return ack

    def _load_image_info(self, path):
        """Cache the width and height of the screenshot（与 AdbTools 同名）。"""
        try:
            from PIL import Image  # Mobile-Agent 已依赖 Pillow
            width, height = Image.open(path).size
            self._w, self._h = width, height
        except Exception:
            pass
        self.image_info = (self._w, self._h)

    # -- screenshot -------------------------------------------------------

    def get_screenshot(self, image_path, retry_times=3):
        """
        Capture a screenshot from the device and save it to *image_path*.
        Returns True on success, False after exhausting retries.

        对应 adb 的 `exec-out screencap -p`；这里走设备端 `screenshot` 能力
        （ScreenCapturer 单帧捕获 → JPEG base64）。ack 里的 width/height
        是【物理像素】，本类据此做后续坐标归一化。
        """
        for _ in range(retry_times):
            try:
                ack = self._invoke("screenshot")
                b64 = ack.get("image")
                if b64:
                    with open(image_path, "wb") as f:
                        f.write(base64.b64decode(b64))
                    w, h = ack.get("width"), ack.get("height")
                    if w and h:
                        self._w, self._h = int(w), int(h)
                        self.image_info = (self._w, self._h)
                    else:
                        self._load_image_info(image_path)
                    # 首次截图成功后，把 iOS 应用注入官方别名表（见 _register_ios_apps）
                    self._ensure_apps_registered()
                    return True
            except Exception as exc:            # 网络抖动/设备忙 → 重试
                print("[IosTools] get_screenshot failed: %s" % exc)
            time.sleep(0.5)
        return False

    # -- input actions ----------------------------------------------------

    def click(self, x, y):
        """Tap at screen coordinate (x, y). x/y 为【像素】。"""
        self._invoke("touch.tap", {"x": x / float(self._w), "y": y / float(self._h)}, timeout=30)

    def long_press(self, x, y, duration=800):
        """Long-press at (x, y) for *duration* milliseconds."""
        # 设备端 touch.longPress 用默认按压时长；如需精确控制可改为 touch.swipe 同点慢滑
        self._invoke("touch.longPress", {"x": x / float(self._w), "y": y / float(self._h)}, timeout=30)

    def slide(self, x1, y1, x2, y2, slide_time=800):
        """Swipe from (x1, y1) to (x2, y2) over *slide_time* milliseconds."""
        self._invoke("touch.swipe", {
            "x1": x1 / float(self._w), "y1": y1 / float(self._h),
            "x2": x2 / float(self._w), "y2": y2 / float(self._h),
            "duration": max(0.2, slide_time / 1000.0),
        }, timeout=30)

    def back(self):
        """Press the Back button.

        ★ iOS 没有硬件返回键（连 WDA 都没有 `back`）——
        正解是【左边缘向右滑】的返回手势。这里用屏幕左上区起手，
        避开主屏下拉（通知中心）与底部 Home 指示条。
        """
        self._invoke("touch.swipe", {
            "x1": 0.02, "y1": 0.12, "x2": 0.45, "y2": 0.12, "duration": 0.6,
        }, timeout=30)

    def home(self):
        """Press the Home button to return to the home screen."""
        self._invoke("home", {}, timeout=30)

    def type(self, text):
        """Type text（支持 CJK）。

        对照：Android 需先装 ADB Keyboard 并切 IME；WDA 走输入法注入。
        这里走 `type.paste`（剪贴板 Cmd+V），实现更简单且天然支持中文。
        """
        if not text:
            return
        self._invoke("type.paste", {"text": text}, timeout=30)

    # -- ★ 补齐 Mobile-Agent【声明了却没实现】的 3 个动作（2026-09-18） --------
    #
    # 背景（源码核对）：它的 SYSTEM_PROMPT 声明了 11 个动作 + system_button 的 4 个子动作，
    # 但 run_gui_owl_1_5_for_mobile.py 的 if/elif 分发链【只有 10 个动作 + 2 个子动作】，
    # 漏了三个（落到 `else: [WARN] Unsupported action type` 被静默丢弃）：
    #     · key                        —— 完全无分支
    #     · system_button{Menu}        —— 无分支
    #     · system_button{Enter}       —— 无分支
    # 下面三个方法把这三个补上，使「它原语里声明的动作」都能落到我们设备。
    #
    # ★ 注意：这三个动作【本来就在它的 enum 里】，所以补它们不需要改它的动作空间、
    #   也不需要改提示词 —— 属于「修它声明了却没实现的洞」，PR 时理直气壮。

    # key 动作的名字 → 我们的能力（schema 说明支持 adb keyevent 语法，
    # examples: "volume_up" / "volume_down" / "power" / "camera" / "clear"）
    _KEY_TO_CAP = {
        "volume_up": ("volup", None),
        "volume-down": ("voldn", None),
        "volume_down": ("voldn", None),
        "volumeup": ("volup", None),
        "volumedown": ("voldn", None),
        "mute": ("mute", None),
        "power": ("power", None),
        "camera": (None, "device_unsupported"),     # iOS 无「打开相机」系统键
        "clear": ("type.delete", {"count": 200}),   # 清空输入框（退格到空）
        "backspace": ("type.delete", {"count": 1}),
        "delete": ("type.delete", {"count": 1}),
        "back": ("__method__:back", None),
        "home": ("__method__:home", None),
        "menu": ("home.double", None),              # iOS 的「菜单」= 双击 Home 看后台
        "enter": ("__method__:enter", None),
    }

    def press_key(self, name):
        """`key` 动作：按 adb keyevent 风格的名字发一个按键/系统动作。

        映射（详见 _KEY_TO_CAP）：
            volume_up / volume_down / mute / power   → 同名 HID 能力
            clear / backspace / delete               → type.delete（清空 / 退格）
            back / home / enter / menu               → 方法或 home.double
            camera                                   → 如实不支持（iOS 无系统相机键）

        Returns:
            bool —— 是否成功执行（False 表示该键在 iOS 上不支持）。
        """
        key = (name or "").strip()
        cap, params = self._KEY_TO_CAP.get(key, (None, None))
        if cap is None:
            if params == "device_unsupported":
                print("[IosTools] key('%s') 在 iOS 上无对应系统键，已跳过"
                      "（可改用 open_app 打开「相机」）" % key)
            else:
                print("[IosTools] key('%s') 未在 _KEY_TO_CAP 中登记，已跳过" % key)
            return False
        if cap.startswith("__method__:"):
            getattr(self, cap.split(":", 1)[1])()
            return True
        self._invoke(cap, params or {}, timeout=30)
        return True

    def menu(self):
        """`system_button{Menu}` 动作：打开"应用后台菜单"。

        ★ iOS 上「应用后台菜单」就是【双击 Home】（App Switcher）——
        我们的 `home.double` 能力（`STHIDEventGenerator.menuDoublePress`）语义**完全对应**，
        比 Android 的 `keyevent MENU` 更贴。
        （官方 schema 原话："Menu means opening the application background menu"）
        """
        self._invoke("home.double", {}, timeout=30)

    def enter(self):
        """`system_button{Enter}` 动作：按回车（搜索 / 发送 / 确认）。

        ★ 设备端 HID 子系统支持具名键 `@"RETURN"` / `@"ENTER"`
        （`STHIDEventGenerator.mm:1425-1426` → `kHIDUsage_KeyboardReturnOrEnter`），
        但【注册表暂未把它暴露成能力】（`keyboard` 是无参的，只 toggle 屏幕键盘）。

        → 过渡实现：用「粘贴一个换行符」触发输入框的确认行为；
           若某些 App 不认，则报错提示需要设备端补 `keyboard.key` 能力。
           设备端补齐后，把本方法的实现换成一次 `_invoke("keyboard.key", {"name": "RETURN"})` 即可。
        """
        try:
            self._invoke("type.paste", {"text": "\n"}, timeout=30)
            return True
        except Exception as exc:
            print("[IosTools] enter() 失败（需设备端补 keyboard.key 能力发送 RETURN）: %s" % exc)
            return False

    # -- package management -----------------------------------------------

    def _app_list_raw(self):
        """拉取已安装应用（{bundleId, name}）。带缓存。"""
        if self._apps_cache is None:
            ack = self._invoke("app.list", {}, timeout=30)
            self._apps_cache = [a for a in (ack.get("apps") or [])
                                if a.get("bundleId")]
        return self._apps_cache

    def _ensure_apps_registered(self):
        """把 iOS 应用注入官方那两张 Android 别名表 —— 只做一次。"""
        if self._ios_apps_registered:
            return
        try:
            self._register_ios_apps(self._app_list_raw())
            self._ios_apps_registered = True
        except Exception as exc:
            print("[IosTools] register ios apps into official dicts failed: %s" % exc)

    @staticmethod
    def _register_ios_apps(apps):
        """★ 无缝集成的关键一步。

        官方 `handle_open_action()`（run_gui_owl_1_5_for_mobile.py:90-141）依赖
        `packages.py` 的两张【Android 包名】表来把"抖音"解析成可启动的标识：

            package_candidates = NAME_PACKAGE_DICT.get(app_name, [])     # 显示名 → [包名]
            for pkg in installed_packages:
                if pkg in PACKAGES_NAME_DICT: ...                        # 包名 → 显示名

        iOS 的标识是 bundleId，那两张表里没有 → 两条路径都落空 →
        最终停在 `input("[ACTION REQUIRED] Please install the app: ...")` 【任务卡死】。

        解法：把 iOS 的 (显示名 ↔ bundleId) 【运行时】并入这两张表（幂等、只增不减），
        于是官方那两条路径都能命中，**`handle_open_action` 一行都不用改**。
        """
        for a in apps:
            name, bid = a.get("name"), a.get("bundleId")
            if not (name and bid):
                continue
            # 包名 → 显示名（用于 LLM 兜底时列出"已安装应用的显示名"）
            PACKAGES_NAME_DICT.setdefault(bid, [name])
            # 显示名 → 包名（用于"抖音"直接命中 bundleId）
            lst = NAME_PACKAGE_DICT.setdefault(name, [])
            if bid not in lst:
                lst.append(bid)
            # 顺带兼容 App 英文名（localizedName 有时是英文），提升命中率
            alt = a.get("nameEn")
            if alt and alt != name:
                lst2 = NAME_PACKAGE_DICT.setdefault(alt, [])
                if bid not in lst2:
                    lst2.append(bid)

    def get_package_name(self, all_packages=False):
        """
        Return a sorted list of installed package names.

        ★ iOS 侧返回的是 **bundleId**（语义与 Android 的 package name 一致：
        "唯一标识一个 App 的字符串"）。同时把应用注入官方别名表（见 _register_ios_apps），
        使官方 `handle_open_action` 无需修改即可工作。

        （`all_packages` 参数为接口兼容保留：我们的 app.list 只列用户安装的 App，
        这点与 Android 默认的 `pm list packages -3` 行为一致。）
        """
        bundles = [a["bundleId"] for a in self._app_list_raw()]
        self._ensure_apps_registered()
        return sorted(set(bundles))

    def open_app(self, package_name):
        """Launch an app by its bundle id."""
        self._invoke("app.open", {"bundleId": package_name}, timeout=30)
