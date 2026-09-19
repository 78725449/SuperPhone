# 资产库（Asset Tree v1 · 2026-09-21 阶段整改定版）

> **存储形态 = 树；语义形态 = 图。** 树持有节点，节点携带**带类型的边**。
> 本文档是这套资产的**格式规范**（改任何资产前先读）。

---

## 一、目录树（四轴：App → 版本 → 页面 → 槽位）

```
assets/
├─ _shared/                          ★ 跨 App/页面共享（只存一份）
│   ├─ elements/                     L0 元素库（图标/控件本体 + 语义名）
│   │   └─ crops/                    裁剪小图（859 张候选待质检入库）
│   └─ revisions/                    页面修订快照（内容寻址；版本间结构未变时页面只写 revisionRef，不复制）
│
├─ _overlays/                        ★ 浮层独立一支 —— 可出现在任意页上，【无父页】
│   └─ <浮层名>.json                  {trigger, dismissChain, safeWords[]}
│
├─ <bundleId>/                       App 层
│   ├─ _app.json                     {name, versions[], latest, siblingApps{}, tree 说明}
│   └─ <version>/                    版本层（★ 目录名 = App 版本号，可枚举）
│       ├─ _version.json             {ios, screen, status, pages[], structureFingerprint{}}
│       └─ <页面>.json                页面层
│
└─ _index.json                       ★ 反向索引（structureHash → 候选页面）；页面 >20 再建，现在不建
```

**为什么是树（用户 2026-09-21 确立）**：
- **路径即查询键**：`assets/抖音/39.9.0/首页.json` 一眼四维定位 ✓（字段化方案要逐文件比对 ✗）
- **枚举天然免费**：`ls <app>/` = 已知版本清单；`ls <app>/<version>/` = 该版页面清单 ✓
- **原生工具可用**：`diff -r 18.5.0 19.0.0` 比版本 · `mv` 迁移 · `rm -r` 回收 ✓
- **蜂群主场**：22 台设备可能装不同版本 → 查表键 = (bundleId, appVersion, iOS, screen) ✓

**树表达不了、必须靠节点内字段的三件事**：
| 缺口 | 为什么树不行 | 修正 |
|---|---|---|
| **导航关系** | 浮层**无父页**（可挂任意页）· tab 是**平级** · push **有反向** —— 树只能表达 push | 节点带 `edges[]`，kind ∈ {push, tab, overlay} |
| **元素复用** | 同一图标跨页/跨 App 复现率极高 → 每页存一份 = 改一处要改 N 处 ✗ | 页面只存 `slots[]`（页内位置+role）→ **引用** L0 `elementRef` |
| **版本共享** | 版本升级但结构没变 → 纯树会复制 N 份完全相同的页面 ✗ | 页面写 `revision`（内容寻址）；结构未变时新版本只写 `revisionRef` |

---

## 二、页面节点格式（`<version>/<页面>.json`）

```json
{
  "page": "抖音-首页(视频流)",
  "app": "com.ss.iphone.ugc.Aweme",
  "appVersion": "39.9.0",
  "revision": "rev-首页-39.9.0-a1b2c3",

  "samplingProtocol": "跨内容（帧间上滑换视频 ×8）",   // ★ 铁律：必须声明（决定 stable 的含义）

  "structureSignature": {"preset":"screenBand", "assert":{"bot":">=3","mid":"<=24"}},  // 判页面类型
  "contentAnchors": ["首页","我","直播 团购 南京 关注 商城 推荐"],                      // 判唯一页

  "slots": [                                        // ★ 引用 L0，不内嵌图标本体
    {"elementRef":"icon.search.magnifier","cx":0.927,"cy":0.055,"role":"entry","seen":"8/8"}
  ],

  "actions": [                                      // ★ 已验证做法（可整段下发 script.exec）
    {"id":"searchEntry","intent":"...","steps":[...],
     "targetPage":"搜索输入页",                       // ★ 跨页嵌套：执行完我到哪
     "evidence":{...},"usesL0Elements":[...],"runCount":1}
  ],

  "edges": [                                        // ★ 导航关系（三种 kind）
    {"kind":"push","to":"搜索结果页","via":"searchEntry","reverse":"backArrow"},
    {"kind":"tab","to":"精选页","via":"tab.jingxuan"},
    {"kind":"overlay","to":"系统-麦克风权限弹窗","trigger":"首次录音"}
  ],

  "pits": [ "..." ],                                // ✗ 负样本：★ 只追加不替换
  "source": { ... }
}
```

### 字段纪律
1. **`samplingProtocol` 必填** —— 不同协议下 `stable` 含义完全不同（连拍测"瞬时稳定" vs 跨内容测"结构稳定"，实测差 3 倍 ✗）
2. **`structureSignature` 只能判【页面类型】，不能唯一判页** —— 实测：搜索结果页的活动横条也让 `bot=4` → `require` 会**假通过** ✗ → 必须叠加 `contentAnchors`，最终裁决在引擎（看图）
3. **`slots` 引用 L0**，不内嵌图标本体（内嵌 = 改一处要改 N 处 ✗）
4. **`actions[].targetPage` 必填** —— 没有它，引擎无法【编排跨页任务】，只能事后看图 ✗
5. **`pits` 只追加不替换** —— 负样本比成功经验更值钱 ✗
6. **`runCount` 由引擎在验证成功后 +1**；到阈值（≥5）升为预置卡

---

## 三、蜂群跨版本查表：四级阶梯

```
设备上报 (bundleId=抖音, appVersion=39.9.0, iOS=15.8.8, screen=750x1334)
  ↓
① 精确命中：<bundleId>/39.9.0/<页面>.json 存在 → 直接取 ✓
  ↓ 无
② 同结构借用：比各版本 _version.json 的 structureFingerprint → 有同指纹版本
              → 借它的 revision（★ 结构没变就不复制，这是 revision 的回报 ✓）
  ↓ 无（结构真的变了）
③ 邻近预测：取最新 active 版本的签名当【预测】下发 →
            执行时 require 先验证 → 失败即带证据回传 → 模型看图纠错（预测-校正回路 ✓）
  ↓ 全无
④ 探索：走路径 A → 产出【新版本目录 + 新页面资产】
```

## 四、增删改查编

| 操作 | 做法 | 树带来的便利 |
|---|---|---|
| **增** | `mkdir <新版本>` + `_version.json`；页面**结构未变只写 revisionRef** | 新增即目录，天然可见 |
| **删** | `status:"deprecated"` + `deprecatedAt`（★ **不物理删** —— 旧设备还在跑） | 真删 = `rm -r`，原生 |
| **改** | 新 `revision` + 该版本页面指向新 sha；旧 revision 保留 → **灰度/回滚天然支持** | `diff -r` 直接看差异 |
| **查** | 见上面四级阶梯 | 路径剪枝 |
| **编** | 读 `actions[].targetPage` + `edges[]` 串成跨页脚本，一次下发（序列内部零模型） | 节点自带出边 |

## 五、AI 介入时机（与执行时序的接口）

```
预测命中 + 每步 verify 通过  → 机械走（★ 模型不在环，序列内部零模型）
任一步 verify 与预测不符      → ★ AI 立即接手（带 bandBefore/bandAfter + 全屏 OCR 证据）
预演批准点（下单/发消息/关注） → ★ 必过 AI（看副作用等级，不看命中率）
熔断 ≤3 / 沉淀裁决 / runCount 升格 → ★ AI 审批（不是计数器）
```

## 六、现在做 / 以后做

```
★ 已做：树结构 + 两份真资产迁入版本目录 + _app.json/_version.json + _shared/_overlays 占位
★★ 待做（规模上来再做，现在做是过度设计）：
   · _index.json 反向索引（页面 >20）
   · _shared/revisions/ 内容寻址（出现第二个版本时才有意义）
   · L0 元素实体入库（859 裁片质检后 → 填 _shared/elements/）
✗ 不做：向量检索（痛点仍是覆盖度）· 版本目录复制（用 revision）· overlay 塞进页面树
```

## 七、历史

- **2026-09-21**：V1 定版（树形态 + 四轴 + 带类型边 + slots 引用化 + targetPage）。此前为"每 App 一个平铺目录"的 V0 形态（2 份资产）。
- **已知版本**（SSH 直读 Info.plist）：抖音 `39.9.0` · 抖音火山版 `22.3.6` · 抖音极速版 `39.9.0` · 微信 `8.0.75`
- **设备端配套**：`app.list` 于 2026-09-21 补 `version`/`build` 字段（纯加法，注册表 + 5802 两处对齐）——此前只有 `{bundleId,name}`，**物理上拿不到版本**，版本目录无从建立 ✗
