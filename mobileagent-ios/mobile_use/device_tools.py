"""设备工具工厂 —— 按平台返回 `AdbTools`（Android）或 `IosTools`（iOS）。

为什么需要这个文件（2026-09-18）：
  `AdbTools` 与 `IosTools` 的【9 个方法签名完全一致】（鸭子类型可互换），
  但两者的【构造签名必然不同】：

      AdbTools(adb_path=..., device=...)      # Android：adb 可执行文件在哪
      IosTools(gateway=...,  device=...)      # iOS：SuperPhone 网关地址在哪

  工厂负责把这个差异收在一处，于是 `run_gui_owl_1_5_for_mobile.py` 里
  只需要把"创建对象"那一行换成 `create_device_tools(...)` 即可 —— 主循环其余部分零改动。

设计立场：**只增不改**
  · 官方 `utils.py`（含 `AdbTools`）不碰
  · 官方 `handle_open_action` / `packages.py` 不碰
  · 本文件是新增的，`main()` 只改 3 行
  → 这样的 PR 只增不改，上游最容易接受。
"""

__all__ = ["create_device_tools"]


def create_device_tools(platform="android", adb_path=None, gateway=None,
                        device=None, token=None):
    """按平台创建设备工具对象。

    Args:
        platform: "android"（默认，走官方 AdbTools）或 "ios"（走 IosTools → SuperPhone 网关）。
        adb_path: Android 用（对应官方 `--adb_path`）。
        gateway:  iOS 用；SuperPhone 网关地址，默认 http://127.0.0.1:8080。
        device:   两端通用；目标设备标识（Android 是 adb serial，iOS 是设备 id）。
        token:    iOS 可选；网关 token（部署带 FARM_TOKEN 时必填）。

    Returns:
        与 `AdbTools` 同接口的对象（含 get_screenshot / click / long_press / slide /
        back / home / type / get_package_name / open_app 九个方法）。
    """
    if platform == "ios":
        from ios_tools import IosTools
        return IosTools(gateway=gateway or "http://127.0.0.1:8080",
                        device=device, token=token)
    from utils import AdbTools
    return AdbTools(adb_path=adb_path, device=device)
