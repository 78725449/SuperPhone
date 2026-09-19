# 手机 Agent 开源框架深度调研 —— 机制提炼报告

> 调研方式：本地克隆源码逐文件分析（含 文件:行号 级证据），辅以 GitHub/HuggingFace API 实时数据核实。
> 目标场景：自研 nonvc 传输服务 + iOS 真机 + 小模型蜂群并发 + 长线任务。

---

## 1. 调研对象总览

### 本地已克隆（D:\编程项目\）

| 目录 | 项目 | 星标 | 定位 |
|---|---|---|---|
| `MobileAgent\Mobile-Agent-v3.5` | 阿里 X-PLUG Mobile-Agent-v3.5 | 9.1k | 多平台 GUI Agent（手机/电脑/浏览器），GUI-Owl-1.5 模型家族 |
| `PhoneHarness` | PhoneHarness | 47 | 混合动作（CLI/GUI/MCP）编排 + 评测 harness，确定性优先路由 |
| `AgentProg` | 清华 MobileLLM AgentProg | 32 | 长时程 GUI Agent：程序化上下文管理（Semantic Task Program） |
| `mobile-use` | minitap mobile-use | 2783 | Android+iOS 真机 Agent，宣称首个 AndroidWorld 100% 完成 |
| `mobile-harness` | droidrun mobile-harness | 329 | Markdown 技能库（非运行时），Android/iOS/云手机 |

### 远程调研（未克隆但已核实）

| 项目 | 星标 | 关键价值 |
|---|---|---|
| droidrun/mobilerun | 9.1k | LLM 无关的 Android/iOS 控制；iOS 走 WDA；内部 manager/executor/fast_agent 三角色配置 |
| Westlake-AGI-Lab/AppAgentX | 669 | 技能自动进化：重复操作链固化为高级技能 |
| X-PLUG/ToolCUA | 61 | 把"GUI vs 工具"路径选择训练进模型权重（ToolCUA-8B） |
| droidrun/WebDriverAgent fork | — | iOS 传输提速：高帧率直播流 + 更快动作执行 |
| bytedance/UI-TARS | 11.4k | UI-TARS-1.5-7B 开源权重（128K 上下文）；UI-TARS-2 未全开源 |
| google-research/android_world | 855 | 官方评测基准 |

---

## 2. 两个核心公式（所有机制的优化目标）

```
单步延迟 = 设备观测 + 图像编码 + LLM调用次数 × 推理时长 + 动作执行 + 写死等待
任务长度 ≈ 上下文有界性 × 错误恢复能力 × 技能命中率   （乘法关系，一项崩则全崩）
```

---

## 3. 提速机制库

### 3.1 参数级修正（立即可做，收益最大）

Mobile-Agent-v3.5 默认配置是典型反面教材：

| 问题 | 位置 | 代价 | 修正方案 |
|---|---|---|---|
| `history_n=4` → 每请求携带 5 张 PNG 原图 | `mobile_use\utils.py:337` | prefill token ×5 | history_n 降到 1~2 |
| `MAX_PIXELS=10,035,200`，主循环再 ×200 | `utils.py:439`、`run_gui_owl_1_5_for_mobile.py:202` | 实际从不缩图，全尺寸原图进模型 | 收紧至 ~130 万 px |
| 截图 PNG base64 无压缩 | `utils.py:438` | 传输体积数倍 | 转 JPEG q50（参照 `mobile-use\controllers\android_controller.py:307`） |
| 每步写死 `time.sleep(2)` | `run_gui_owl_1_5_for_mobile.py:281` | 白白 +2s/步 | 改为屏幕哈希变化触发 |
| wait 动作默认 2s | 同文件 :240-241 | — | 按需调整 |
| 失败重试等 20s × 最多10次 | `utils.py:489-495` | 最坏卡死 200s | 指数退避封顶 ~5s |
| erase_text 逐字符 KEYCODE_DEL 最多50次往返 | `mobile-use\android_controller.py:288-290` | 文本清除极慢 | 批量选中删除 |

> 结论：仅参数修正即可把单步延迟从 8~15s 压到 3~6s。

### 3.2 结构级快速通道——让多数步骤不碰大模型

1. **确定性四级路由表**（PhoneHarness `skills\routing.yaml:47-86`）
   - `COMPLETE`：一条 CLI 命令完成
   - `BOOTSTRAP`：CLI 开场 + GUI 收尾
   - `INTENT_ONLY`：仅拉起界面≠完成（须注明做了什么/没做什么）
   - 风险分级：SAFE_COMPLETE / CONFIRM_FIRST / NEVER_AUTO
   - 无匹配时固定优先级：`shell_exec → load_skill → python_exec → run_seed_gui_subtask(标注 SLOWEST)`
   - **核心理念：GUI 是最后兜底，不是默认路径。**

2. **无障碍树直取**（mobile-harness `README.md:98-117`、`GUIDE.md:83-102`）
   - `tap_text("标签")` / `tap_node(node)`：按元素点击，免截图免坐标预测
   - `scroll_until(text_contains, max_swipes=10)`：设备端自循环找元素
   - `execute_script`：Chrome 前台页直接跑 JS 一步到位
   - mobile-use 的 `find_element` 从缓存控件树按 resource_id/text 取 bounds 免二次截屏（`android_controller.py:211-243`）

3. **技能命中零模型执行**（mobile-harness 核心设计）
   - 技能 = Markdown 卡片，经 skills.sh 分发
   - `memory/` 目录跨会话缓存设备/应用 quirk（`core\memory\GUIDE.md:20-26`）
   - CARD.md 只按前台包名加载一张（`GUIDE.md:219-225`）
   - 重复任务推理成本趋近于零

4. **每步 LLM 调用次数应为 1**
   - mobile-use 六角色架构每轮最多 4 次 LLM 调用（planner/orchestrator/contextor/cortex/executor，`graph.py:104-124`），cortex→executor 可合并为单次 tool-call 决策
   - v3.5 的 app-resolver 固定小模型 `qwen-plus` 是唯一轻量分工（`run:56`）

### 3.3 模型层提速

- 简单步用本地小模型 Instruct 版；低置信度/连续失败才升级大模型
- **注意：五个仓库均无真正的 fast/slow 分级实现——这是自建系统的差异化机会**
- 辅助判断（如 App 名解析）固定用小模型，主决策才用大模型

### 3.4 图像 token 预算基准

| 仓库 | 做法 | 数值 |
|---|---|---|
| v3.5 | 不缩图，PNG base64 | MAX_PIXELS=1000万+（失控） |
| mobile-use | 保分辨率，JPEG 重编码 | quality=50（`android_controller.py:299-310`） |
| 推荐自建 | 双管齐下 | max_pixels≈130万 + JPEG q50 + 坐标归一化(0-1000) |

---

## 4. 长线机制库（主要来自 AgentProg 源码级实现）

### 4.1 支柱一：任务表示成"程序"，控制流交给解释器
- 自然语言伪代码**编译成真 Python**（`plan\workflow_utils.py:932-1053`）：for/while 行→`while not check_break_flag() and workflow(...)` 
- 程序计数器 = CPython frame lineno（`_find_frame` 按 `<plan_` 前缀搜栈，`workflow_utils.py:198`）——不自研调度器
- 节点树 `WorkflowContext`：description/global_vars/local_vars/duplicate_context_id/exec_res_history（`:637-664`）
- 价值：长任务的骨架稳定，漂移的是步骤不是目标结构

### 4.2 支柱二：上下文有界三板斧
1. **只喂根到当前节点路径**：兄弟分支、已完成历史不进 prompt（`workflow_utils.py:796-803`）
2. **变量白名单+截断**：`filter_variables` 仅留基本类型与 List/Dict/Tuple（`:308-315`）；`summarize_variables` 前10项加省略号（`:507-543`）——约80行独立函数可直接移植
3. **Belief State 覆盖式更新取代历史堆积**（`core\agentprog.py:119-121`）：LLM 每轮输出 `--- Updated Belief State ---` 与 `--- Plan ---` 字段，解析后整体覆盖。记忆=不断重写的快照，而非越滚越大的雪球

### 4.3 支柱三：Checkpoint = 序列化执行树
- 执行树清洗为 `{lineno, update_vars, duplicate_id}` JSON（`agentprog.py:253-270`）
- 恢复：`WorkflowSystem(recover_tree=dict)` 从树上继续重放而非重新规划（`workflow_utils.py:1121-1134`）
- 同位置脚本缓存：连续两次生成相同脚本→直接重放免查询（`agentprog.py:45-50`）；循环缓存命中时 StopIteration→BREAK 自动推断（`:160-164`）

### 4.4 支柱四：错误恢复双保险
- **WPC 五操作二次审核**：第二次 LLM 查询只能输出 HOLD/RETRY/RETURN/BREAK/CONTINUE 五选一（`workflow_utils.py:624-629`）；RETRY="代码成功但目标未达成"→强制换策略（`:1352-1356`）；MAX_LOOP_TIME=100 防死循环
- **技能卡预声明 failure_patterns**（PhoneHarness `skills\loader.py:14-23`）：失败模式进任务前已知
- exec 错误写入全局 error_info 并注入下轮提示（`workflow_utils.py:1308-1313`）

### 4.5 步数上限参考（参数 vs 现实）

| 层面 | 数值 |
|---|---|
| v3.5 默认 max_steps | 50（argparse 默认） |
| mobilerun 默认 max_steps | 15（config_manager.py:125） |
| 上下文窗口 | UI-TARS-1.5-7B=128K；GUI-Owl-1.5 发布配置32K；v3.5 滑动窗口仅最近4步图 |
| **真实可靠性地平线** | **20~30 步后成功率显著衰减（误差累积），单次连续运行有效工作量 ≈30 步 / 3~5 分钟** |
| 正解 | 不拉高步数：子目标链拆分 + checkpoint 续跑 + 技能回放消化重复段 |

---

## 5. 可移植机制总排行（收益/移植成本比）

| # | 机制 | 来源 | 移植成本 |
|---|---|---|---|
| 1 | routing.yaml 确定性路由表 + INTENT_ONLY 诚实标注 | PhoneHarness | 纯数据文件即生效 |
| 2 | 技能卡六字段格式（prompt_extension/allowed_tools/preconditions/verification/failure_patterns）+ load_skill 渐进加载 | PhoneHarness | 一天 |
| 3 | v3.5 参数修正包（sleep/history_n/max_pixels/JPEG） | 反面教材 | 改两行 |
| 4 | 变量截断摘要 filter/summarize_variables | AgentProg | ~80行独立函数 |
| 5 | belief state 覆盖式更新替代历史 | AgentProg | 一个 dataclass + 两个 prompt 字段 |
| 6 | WPC 五操作审核（RETRY 强制换策略） | AgentProg | 每步多一次小查询 |
| 7 | 同位置脚本缓存免查询重放 | AgentProg | 中等耦合 |
| 8 | journal 全量落盘 + render_replay_text 复盘 | PhoneHarness | 低成本可观测性 |
| 9 | STP 编译为可执行控制流（frame=PC） | AgentProg | 收益最高但需 AST/exec 基建 |
| 10 | fast/slow 置信度分级路由 | **无仓库实现** | 自研差异化机会 |

---

## 6. 模型选型（UI 识别精准 + 长上下文）

### 6.1 候选模型（HuggingFace 已核实）

| 模型 | 底座 | 上下文 | 备注 |
|---|---|---|---|
| GUI-Owl-1.5 系列（2B/4B/8B/32B/235B，Instruct&Think） | Qwen3-VL | 8B 配置 32K | 多平台 SOTA，坐标归一化 0-1000 输出 |
| UI-TARS-1.5-7B | Qwen2.5-VL | **128K**（config 实测） | HF 下载量最大的开源 GUI 模型，GGUF 量化齐全 |
| OS-Atlas-Pro-7B | — | — | 轻量备选 |
| Holo1.5-7B | — | — | 定位能力突出 |
| ToolCUA-8B | — | — | 内化 GUI↔工具路径编排决策 |

### 6.2 RTX 2080 Ti（11GB）蜂群容量估算（Q4 量化 + continuous batching）

| 模型 | 权重占用 | 可支撑并发会话 |
|---|---|---|
| GUI-Owl-1.5-2B-Instruct | ~1.5GB | 12–16 路 |
| GUI-Owl-1.5-4B-Instruct | ~3GB | 8–12 路 |
| GUI-Owl-1.5-8B-Instruct | ~5.5GB | 4–6 路 |

按每步 3~6s 计，单卡带 8~10 台手机做长线任务是现实的。图像 token 是显存大头，必须压 max_pixels。

---

## 7. 设备层对接（nonvc + iOS）

### 7.1 Agent 大脑需要的最小接口面（v3.5 AdbTools 的 9 个方法）

```
get_screenshot()          click(x,y)        long_press(x,y,dur)
slide(x1,y1,x2,y2,t)      back()            home()
type(text)                get_package_name()  open_app(pkg)
```

写一个同名 `NonvcTools` 类、签名不变、内部转 nonvc HTTP 调用，上层循环零改动。
mobilerun 的 IOSDriver 佐证：8 个 REST 方法足矣（tap/swipe/input_text/press_button/start_app/screenshot/get_ui_tree/get_date）。

### 7.2 必踩的坑：iOS 坐标契约
- iPhone 截图是物理像素（@2x/@3x），点击坐标是逻辑点（points），差一个 scale 因子
- 解法（mobilerun ios_provider.py）：显式坐标契约——视觉模型输出归一化 [0-1000] 或记录缩放后尺寸做 convert_point 映射；契约失效时禁用坐标类动作防误触
- 归一化坐标系天然规避此问题（GUI-Owl 1.5 默认输出 0-1000）

### 7.3 iOS 性能参考
- droidrun WDA fork：高帧率直播流 + 更快动作执行
- 多台 iPhone 同时推流：先压测 USB 集线器与编码开销；必要时降帧率/分辨率

---

## 8. Trace 复盘系统（HTML Viewer 三层分离架构，源自 PhoneHarness trace2html.py 739行实测）

```
采集层  每步 NDJSON 三类事件（step/tool_call/tool_result）+ 三段计时(ss_ms/llm_ms/act_ms) + tokens + CoT
        截图落盘为帧文件 step_NNN.png，trace 仅存相对路径引用
转换层  按步号关联三类事件 → 正则分离 CoT 与 <tool_call> 动作 → 计算瀑布占比 → 定位瓶颈步
渲染层  单文件 HTML + 内嵌 JSON 数据 + vanilla JS：
        总览卡片(总耗时/LLM耗时/截图耗时/Tokens) · PASS/FAIL 判定横幅 · 时间瀑布图(瓶颈红标)
        分步卡片点击展开[截图|明细表格|CoT 思考框] · 子任务嵌套内联 · 工具调用流视图
```

推荐 NDJSON 单行 schema（nonvc+蜂群版）：
```json
{"step_id":7,"device_id":"iphone_03","task_id":"...","ts":"...",
 "screen_hash":"a1b2c3","action":{"type":"tap","x":500,"y":320},
 "model_output":"...<tool_call>...</tool_call>","cot":"...",
 "ss_ms":120,"llm_ms":2100,"act_ms":90,
 "ok":true,"skill_hit":false,"checkpoint":true}
```
蜂群聚合视图：按 device × step 渲染矩阵，一眼扫出偏离群体行为的设备（失败放大早期信号）。

---

## 9. 蜂群架构蓝图（v2：双层循环）

### 9.1 三层运行时

```
L0 执行器   路由卡确定性路径 · tap_text直取 · 技能回放              ← 零模型或本地小模型
L1 守护者   内联校验：屏幕哈希增量 · OCR锚点抽查 · verification字段  ← 焊死在每步里，零LLM成本
L2 修复者   仅L1报警时唤醒（异常触发，构造上禁止主动接管）           ← 单次大模型调用 + 严格输出契约
```

> 三条工程约束：**验证焊在执行里**（每步 = 执行50ms + 校验~100ms，不可拆成独立阶段）；
> **迭代分内外环**（即时修补是临时的，经验沉淀是永久的）；**修补后要复检**（过同一道闸门才算数）。

### 9.2 内环（快·任务内）：执行 ⟶ 内联验证 ─失败→ 就地修补 → 复检 → 继续

L2 修复上下文包（保证"基于当前执行场景"而非抽象任务描述）：
`{失败动作原文 · 点击时目标表快照 · 当前帧diff · 前后截图 · 技能卡该步原文 · 失败计数}`

输出契约三选一（第四项"接管后续/从零重规划"在构造上不存在）：

| 输出 | 内容 | 生效范围 |
|---|---|---|
| a 参数补丁 | 改目标id / 坐标微调 / 加等待 | 继续原技能流，用完即弃 |
| b 局部重规划 | 只替换步骤 k 之后的子序列 | 不回滚整个任务 |
| c 技能修订 | 更新 failure_patterns / 替换步骤 | 写回技能库 |

预算护栏：每技能卡每小时限额 N 次修复调用，防止修复风暴。修补完成后必须重新通过同一套验证闸门——不允许修复者自行宣布修好。

### 9.3 外环（慢·跨任务）：经验沉淀

```
任务结束 → trace 蒸馏 → 技能库版本化更新 → 灰度推送(先1台验证) → 全蜂群生效
```

- 闭环规则：a/b 类修复在同一位置重复 ≥2 次 → 自动升级为 c 类固化进技能
- 保守铁律：外环产物永久生效且全群传染——宁缺毋滥，必须自带 verification 字段

### 9.4 群拓扑与模型服务

```
              ┌─ orchestrator：任务队列 / 设备池 / 失败重试 / 技能库共享
              │
   ┌──────────┼──────────┐
worker_1     worker_2     worker_N    ← 每机一个轻量循环进程（v3.5 主循环改造）
   │            │            │             · 路由卡先行（确定性路径零模型）
 nonvc        nonvc        nonvc           · 技能命中 → 回放（毫秒级）
   │            │            │             · 未命中 → 本地小模型决策
iPhone_1     iPhone_2     iPhone_N          · 低置信度 → 升级 API 大模型
   └────┬──────┴─────┬─────┘
        ↓ 全部指向同一 OpenAI 兼容端点
   vLLM Server（GUI-Owl-1.5-4B-Q4，--max-num-seqs 调并发槽）
```

**三大预埋防线**：
1. 失败放大：每步廉价校验（屏幕哈希比对、关键元素抽查）；异常设备踢出单独处理
2. 行为同质化：任务错峰 + 动作时序/轨迹参数抖动（orchestrator 基本能力）
3. 传输瓶颈：多机推流先压测；降帧降分辨率兜底

**技能库共享是蜂群最大加速器**：一台机器探索走通 → 全群回放。规模越大，模型调用量趋近于零。

---

## 10. 落地路线图

```
第1周（参数级，收益立现）
 └ 自建循环完成 §3.1 修正表：JPEG q50、max_pixels 130万、history≤2、去sleep、退避封顶
   预期：单步 8~15s → 3~6s

第2周（结构级）
 ├ 移植 routing.yaml 四级路由卡（纯数据文件生效）
 ├ 技能卡六字段格式 + load_skill 渐进加载（一天）
 └ nonvc 出元素信息则补 tap_node 型快速通道；否则靠技能回放补位

第3周（长线级）
 ├ belief state 覆盖式更新（dataclass + 两个 prompt 字段）
 ├ checkpoint = 步骤状态JSON + 屏幕哈希，恢复走重放
 ├ WPC 五操作审核防死循环
 └ 置信度路由：本地 2B/4B 主力，低置信升级 API
```

---

## 11. 一句话总结

> **快**，靠"多数步骤不碰大模型"——路由表 + 技能库 + 参数修正；
> **长**，靠"任务是程序、记忆是快照、恢复靠重放"——AgentProg 三件套；
> **稳**，靠"每步可验证、失败有边界"——trace 复盘 + 廉价校验 + 隔离重试。
>
> mobile-harness 证明重复任务边际成本可归零，AgentProg 证明上下文可以结构性有界，
> PhoneHarness 证明 GUI 应该是最后手段而非默认路径——三者拼合即是超越现有框架的蜂群底座。

---

*报告生成于代码级分析会话；所有 文件:行号 引用均可本地复核。*
