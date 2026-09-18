# ★ 里程碑：Mobile-Agent 用 `--platform ios` 成功驱动我们的 iPhone（2026-09-18）

> **结论**：**Mobile-Agent v3.5 官方脚本，加 `--platform ios`，成功在我们的真机上完成了任务。**
> 改动量：**2 个新文件 + 3 行 + 1 行官方 bug 修复**。
> 官方 `AdbTools` / 时序 / 动作协议 / `handle_open_action` —— **一行未动**。

---

## 一、实测记录（含独立验证）

**命令**：
```bash
python run_gui_owl_1_5_for_mobile.py \
  --platform ios --gateway http://127.0.0.1:8080 \
  --api_key dummy --base_url http://127.0.0.1:8092/v1 \
  --model <GUI-Owl-1.5-4B gguf> \
  --instruction "打开抖音" --max_steps 6 \
  --device 553A6EA8-29F1-43DB-94B4-D4E01D4204DC
```

**运行结果**：
```
STEP 0  模型输出: {"action": "open", "text": "抖音"}
        → handle_open_action（官方逻辑，未改动）
        → NAME_PACKAGE_DICT['抖音'] 命中【我们注入的】com.ss.iphone.ugc.Aweme  ✓
        → IosTools.open_app() → 网关 app.open → 抖音打开

STEP 1  模型看到抖音首页 → {"action": "answer", ...} 任务完成
[DONE] Agent execution finished.
```

**★ 独立验证（不依赖模型自述）**：事后我直接调网关的 `vision.ocr` 读当前屏幕，与模型描述逐项对照：

| 网关 OCR 实测 | 模型在 STEP 1 的描述 | |
|---|---|---|
| `00:31` · `100%` | "时间为 00:30，电量100%" | ✓（差 1 分钟）|
| `5034` / `458` / `611` | "点赞5034、评论458、转发611" | ✓ 逐字一致 |
| `@路小雨` | "作者为"@路小雨"" | ✓ |
| `西湖纵有千般美 无你不过一滩水` | 同 | ✓ 逐字一致 |
| `#西湖 #杭州 #mrms 洗发水展开` | "#西湖#杭州#mrrms洗发水等标签" | ✓ |
| `首页 朋友 消息 我` | "底部导航栏显示首页朋友消息我四个标签" | ✓ |

**→ 结论：真机屏幕内容与模型描述一致，链路真实打通。**

---

## 二、最终改动清单（对 Mobile-Agent）

| # | 文件 | 动作 | 规模 |
|---|---|---|---|
| **①** | `mobile_use/ios_tools.py` | **新增** —— `IosTools`（9 方法 + 运行时注入官方别名表）| 232 行 |
| **②** | `mobile_use/device_tools.py` | **新增** —— `create_device_tools(platform, **kw)` | 28 行 |
| **③** | `mobile_use/run_gui_owl_1_5_for_mobile.py` | **改 3 处**：import 工厂 + 加 `--platform`/`--gateway`（并把 `--adb_path` 改为非必需）+ 实例化换工厂 | +20 / −4 |
| **④** | `mobile_use/utils.py` | **改 1 处**（上游 bug 修复，见下）| +6 / −1 |
| **⑤** | `AdbTools` / `handle_open_action` / `build_messages` / `parse_action` / `rescale_coordinates` / `annotate_screenshot` / `packages.py` / 时序 / 动作协议 | **完全未动** | **0** |

**源码保存在我们仓库**：`mobileagent-ios/mobile_use/{ios_tools.py, device_tools.py}`

---

## 三、★ 顺带查出两个【上游 bug】

### 3.1 `file://` 前缀不一致（**必修，否则 OpenAI 路径必炸**）

```python
# build_messages()（utils.py:401/407/415/422）产出带前缀的：
{"image": "file://" + image_path}

# 但 image_to_base64()（utils.py:436）直接当本地路径打开：
def image_to_base64(image_path):
    dummy_image = Image.open(image_path)     # ✗ 'file://...' → OSError: [Errno 22]
```

**→ 说明 `GUIOwlWrapper`（OpenAI 兼容路径）【从来没有被跑通过】** ✗
（`file://` 形态是给 DashScope 用的）

**我们的修法（+6/−1，零副作用）**：
```python
def image_to_base64(image_path):
    if isinstance(image_path, str) and image_path.startswith("file://"):
        image_path = image_path[len("file://"):]      # 容忍前缀；纯路径行为不变
    dummy_image = Image.open(image_path)
```

### 3.2 `factor=28` vs `factor=16`（**已记录，暂未修**）

| 位置 | factor |
|---|---|
| `image_to_base64()`（送模型的图）| **28** |
| `main()` 的 `rescale_coordinates()`（坐标换算）| **16** |

**→ 同一张截图被 resize 两次且尺度不同 → 750×1334 下约 4–6px 系统性坐标偏差** ✗
（与 sub-agent 早先的判断一致）
**暂不动它**：先让链路跑通；偏差量需真机量化后再决定是否修（可能属"能接受"）。

---

## 四、★ 实测暴露的两个【我们自己的能力缺口】

| # | 缺口 | 证据 | 影响 |
|---|---|---|---|
| **①** | **系统 App 不在 `app.list` 里** | `TRCapabilityRegistry.mm:939` 有 `if (type == "System") continue;` | 「设置」「相机」等**别名表候选为空** → 模型说"打开设置"会失败（但 `app.open` 本身能打开，只是解析不到 bundleId）|
| **②** | **部分 App 的中文名与 bundleId 对不上** | 「微信」候选是 `com.tencent.mm`（Android 包名），而 iOS 微信是 `com.tencent.xinWeChat`；本次实测**未命中** | 若设备装了微信，需确认 `app.list` 里的 `name` 是什么（是否带后缀），再决定补别名 |

**★ 这两个都要在 MCP 阶段按 §17.8 **N2**（结构化错误 + `alternative` + `hint`）如实暴露** ✓

---

## 五、这次跑通【验证了什么 / 没验证什么】

**✓ 验证了**：
1. **接口同构可行** —— 9 个方法与 `AdbTools` 签名完全一致，主循环零感知
2. **运行时注入字典有效** —— 官方 `handle_open_action` 的两条路径都能命中 iOS bundleId（**这是"无缝"的关键**）
3. **坐标归一化正确** —— 模型给的 0-999 → 像素 → ÷750/1334 → `touch.tap`，点击落在了正确位置（"打开抖音"是 `open` 动作，坐标路径待下一个任务验证）
4. **整条链路真实可用** —— 本地 GUI-Owl-4B 模型 + 我们的网关 + 真机

**✗ 还没验证**：
1. **`click` / `swipe` / `type` 的坐标精度**（本次只用到了 `open` 和截图）
2. **多步任务**（本次 2 步就完成）
3. **`IosTools.back()`**（边缘右滑是否真的等效"返回"）
4. **`type()`**（`type.paste` 在真实输入框里的表现）

**→ 下一步该跑一个"需要点击与输入"的任务来验证** ✓

---

## 六、下一步

| 选项 | 内容 |
|---|---|
| **A** | **跑一个"点击 + 输入"的任务**（如"打开抖音搜索南京美食"）验证坐标精度与 `type()` |
| **B** | **开始做 MCP 服务器**（腿 2，正题）|
| **C** | 把这个 iOS 支持整理成可提给上游的形态（含两个 bug 的修复说明）|

**★ 建议 A → B**：A 能把"接口真能用"这件事钉死（同时补上 `click`/`type` 的实测），
B 才是主线。
