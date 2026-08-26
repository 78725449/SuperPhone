# 水滴自驱改造实现计划（Phase 3.5，用户拍板 2026-08-27）

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 将"当前位置显示"从依赖 locationd 广播（MKUserLocation）**解耦为自驱**——以编排注入位置（`self.cur` / daemon `_currentLat/_currentLon`）为真相源，配合 TRWpsTile 动态反查模拟"wifi 计算位置"。实现两种消费语义：系统定位关 = 水滴跟编排位置（wifi 计算观感）；系统定位开 = 双层（GPS 水滴照旧跟 locationd + wifi 标注跟编排位置）。

**用户原话（拍板）**："系统定位不开时，添加锚点生成出行路线区域漫游等一样执行位置路线编排由 wifi 定位方式消费，因为它们底层是一样的注入位置，而我们 APP 又是编排注入位置的，应该基于编排的路线去模拟 wifi 计算的位置，在系统定位开启时，编排的位置走双层模拟（水滴分别实现跟随移动）"

**架构：** 编排位置真相源不变（daemon `_currentLat/_currentLon` ← App 写 plist → `SimLocationController` 注入）。新增：
1. **daemon 瓦片变更检测**：`_trackTick` 每秒注入后检测当前坐标所属瓦片（TRWpsTile 同算法），跨瓦片才重新触发 wifi 动态反查注入（同瓦片 LRU 命中零成本）
2. **App 水滴自驱**：定位关时用自绘水滴标注（仿 TRWifiAnnotation/TRWaypointAnnotation 模式）跟随 `self.cur`（编排位置），不走 MKUserLocation；定位开时保持 MKUserLocation（GPS 层）双轨并行

**技术栈：** Objective-C++ / dispatch_source / TRWpsTile（Phase 3 完成）/ 现有 TRWifiAnnotation 渲染链

**前置依赖：** Phase 3 任务 1-4 完成（TRWpsTile 共享模块 + daemon 动态反查 + App 标注动态反查 + pbxproj 注册）

---

## 文件结构

- 修改：`TrollVNC/src/SimLocationController.mm` — `_trackTick` 瓦片变更检测 + wifi 反查触发；共享瓦片 key 计算辅助
- 修改：`TrollVNC/src/TRWpsTile.h/.mm` — 导出瓦片 key 计算（`+tileKeyForCoordinate:` 静态方法，供 daemon/App 复用做变更检测）
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m` — 水滴自驱（定位关自绘水滴标注跟 self.cur；定位开双层）
- 修改：`说明文档.md` — §4.12 同步（合并任务 5 内容）

---

### 任务 1：TRWpsTile 导出瓦片 key 计算

**文件：**
- 修改：`TrollVNC/src/TRWpsTile.h/.mm`

**背景**：daemon `_trackTick` 需要"当前坐标是否跨瓦片"判定；App 水滴自驱需要同一判定（编排位置移动跨瓦片才重反查）。瓦片 key 计算目前在 TRWpsTile.mm 内部（latLonToTile + packTileKey 静态函数），需导出。

- [ ] **步骤 1：读 TRWpsTile.mm 现有 latLonToTile/packTileKey**

读 `TrollVNC/src/TRWpsTile.mm` L67-90（latLonToTile/packTileKey 静态函数）。确认签名与 level=13 约定。

- [ ] **步骤 2：头文件加静态方法**

```objc
/// 计算坐标所属瓦片 key（level 13，morton；供跨瓦片变更检测——轨迹移动跨瓦片才重反查）
+ (uint64_t)tileKeyForCoordinate:(CLLocationCoordinate2D)coord;
```

- [ ] **步骤 3：.mm 实现（复用内部函数）**

```objc
+ (uint64_t)tileKeyForCoordinate:(CLLocationCoordinate2D)coord {
    uint32_t tx, ty;
    latLonToTile(coord.latitude, coord.longitude, 13, &tx, &ty);
    return packTileKey(ty, tx, 13);
}
```

- [ ] **步骤 4：Commit**

```bash
git add TrollVNC/src/TRWpsTile.h TrollVNC/src/TRWpsTile.mm
git commit -m "feat(device): TRWpsTile 导出瓦片 key 计算——跨瓦片变更检测复用（轨迹移动跟随）"
```

---

### 任务 2：daemon _trackTick 瓦片变更检测（轨迹 wifi 跟随真实化）

**文件：**
- 修改：`TrollVNC/src/SimLocationController.mm`

**背景**：任务 2 实现的 concern——轨迹播放中 `_trackTick` 每秒只做 GPS 注入，不触发 wifi 反查；wifi 换源只发生在 start/restore。本任务：每秒注入后检测瓦片是否变更，跨瓦片才重新 wifi 反查（同瓦片 LRU 命中零成本）。

- [ ] **步骤 1：读 _trackTick 与 ivar**

读 `SimLocationController.mm` L267-274（_trackTick）、L31-45（ivar 区）。需加 ivar 记录当前瓦片 key。

- [ ] **步骤 2：ivar 区加瓦片 key 记录**

```objc
uint64_t _lastWifiTileKey;   // 上次 wifi 反查的瓦片 key（跨瓦片才重反查，轨迹跟随）
```

- [ ] **步骤 3：_trackTick 改造**

```objc
- (void)_trackTick {
    if (_trackIndex >= _trackPoints.count) {
        [self _stopTrack];
        TVLog(@"[locsim] itinerary finished, keep final point");
        return;
    }
    [self _injectPointDict:_trackPoints[_trackIndex++]];
    // 轨迹 wifi 跟随（用户拍板 2026-08-27）：跨瓦片才重新反查注入（同瓦片 LRU 命中零成本）
    [self _checkWifiTileChangedAndReinject];
}

/// 检测当前坐标瓦片是否变化，跨瓦片则重新 wifi 动态反查注入（轨迹跟随）
- (void)_checkWifiTileChangedAndReinject {
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(_currentLat, _currentLon);
    if (coord.latitude == 0 && coord.longitude == 0) return;
    uint64_t key = [TRWpsTile tileKeyForCoordinate:coord];
    if (key == _lastWifiTileKey) return; // 同瓦片：不重反查（LRU 已覆盖）
    _lastWifiTileKey = key;
    [self _injectWifiSimulationForCurrentLocation];
}
```

`_startTrack` 首点注入后（L249 附近）也设置 `_lastWifiTileKey`（用当前坐标算一次）。

- [ ] **步骤 4：静态自检**

- `#import "TRWpsTile.h"` 已有（任务 2 加了）
- `_lastWifiTileKey` 初始化 0；首次 _trackTick 时 key≠0 触发反查
- anchor 模式：微动 ±20m 同瓦片，`_anchorTick` 不触发（anchor 语义"wifi 注入一次即可"保留）——**确认：anchor 不接 _checkWifiTileChangedAndReinject**（微动范围远小于瓦片）
- 停止/off 时 `_lastWifiTileKey` 重置（在 `stopAll` 路径或 applyFromPrefs off 分支重置为 0，防残留导致 restart 不触发）

- [ ] **步骤 5：Commit**

```bash
git add TrollVNC/src/SimLocationController.mm
git commit -m "feat(device): 轨迹 wifi 跟随——_trackTick 瓦片变更检测，跨瓦片才重新反查注入（同瓦片 LRU 零成本）"
```

---

### 任务 3：App 水滴自驱（定位关自绘水滴跟编排位置 + 定位开双层）

**文件：**
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m`

**背景**：当前水滴=MKUserLocation（locationd 广播），定位关时无广播→水滴消失。改造：定位关时用自绘水滴跟随 `self.cur`（编排位置，wifi 计算观感）；定位开时保持 MKUserLocation（GPS 层）+ wifi 标注（已在任务 3 动态反查）并行=双层。

**语义定稿（用户拍板）：**
| 系统定位 | 编排 | 水滴 | wifi 标注 |
|---|---|---|---|
| 关 | 照常跑（注入照常） | 自绘水滴跟 self.cur（自驱） | 跟 self.cur（动态反查，任务 3 已做） |
| 开 | 照常跑 | MKUserLocation 跟 locationd | 跟 self.cur（动态反查） |

**注意**：`self.cur` 是 GCJ-02 地图坐标（App 侧）；动态反查前转 WGS-84（`gcj02ToWgs84:`）。

- [ ] **步骤 1：读现有水滴链路**

读 `TRMapPickerViewController.m` L189（showsUserLocation）、L1191-1206（refreshUserLocationView）、L1078（真实定位去图标）、L832/L845（toggleLocate 水滴切换）。理解现有 MKUserLocation 依赖。

- [ ] **步骤 2：新增自绘水滴标注类型**

仿 TRWifiAnnotation（L53-58 附近接口区）：

```objc
/// 自驱当前位置水滴（定位关闭时替代 MKUserLocation——跟编排位置 self.cur，wifi 计算观感）
@interface TRSelfDrivenDroplet : MKPointAnnotation
@end
```

- [ ] **步骤 3：视图分支 + 交互拦截**

- `viewForAnnotation:` 加 TRSelfDrivenDroplet 分支（仿 TRWaypointAnnotation 自绘水滴，绿色出行图标可复用 refreshUserLocationView 的现有外观逻辑）
- `shouldReceiveTouch:` 加 TRSelfDrivenDroplet return NO（同 TRWifiAnnotation 机制，防 tap 加锚点）
- **关键**：自驱水滴出现时 `mapView.showsUserLocation` 处理——定位关时若 `showsUserLocation=YES` 但无广播，MapKit 可能显示"无位置"占位或不显示；需在 toggleLocate/状态切换时按语义切换（详见步骤 4）

- [ ] **步骤 4：定位关/开切换逻辑**

在 toggleLocate 与位置订阅回调里，按 `CLLocationManager.authorizationStatus()` 判定系统定位是否可用：

```objc
- (BOOL)_systemLocationAvailable {
    CLAuthorizationStatus st = [CLLocationManager authorizationStatus];
    return (st == kCLAuthorizationStatusAuthorizedWhenInUse || st == kCLAuthorizationStatusAuthorizedAlways);
}
```

- 系统定位可用（开）：`self.mapView.showsUserLocation = YES`（MKUserLocation 走 locationd，GPS 层）；自驱水滴不加（或隐藏）
- 系统定位不可用（关）：`self.mapView.showsUserLocation = NO`（MKUserLocation 无数据不可用）；自驱水滴跟随 `self.cur`（在位置更新回调里同步 coordinate）

**自驱水滴跟随**：在现有 `self.cur` 更新的位置（锚点/轨迹/区域漫游的编排推进处，grep `self.cur =` 定位）同步更新自驱水滴 coordinate（自驱数据源=编排位置，与注入同源）。

- [ ] **步骤 5：静态自检**

- TRSelfDrivenDroplet 声明/视图分支/拦截三处齐全
- showsUserLocation 按系统定位状态切换（不残留 MKUserLocation 空数据）
- `self.cur` 更新处同步水滴（grep 确认所有 `self.cur =` 赋值点）
- 不与现有 wifi 标注（任务 3 已做）冲突——wifi 标注是"wifi 计算位置"信息标注，自驱水滴是"当前位置"指针，两者并存：标注显示位置信息，水滴显示当前位置指针

- [ ] **步骤 6：Commit**

```bash
git add TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m
git commit -m "feat(app): 当前位置水滴自驱——定位关自绘水滴跟编排位置，定位开双层(MKUserLocation+wifi标注)"
```

---

### 任务 4：文档同步（§4.12 更新 + 水滴自驱语义）

**文件：**
- 修改：`说明文档.md`

- [ ] **步骤 1：§4.12 更新**

- 更新 buildScanResults 方法名（FromBssidStrings）
- 更新"跨城轨迹固定 kWpsBssids"段落（已完成动态反查 TRWpsTile）
- 补水滴自驱语义（定位关自绘水滴跟编排位置；定位开双层）

- [ ] **步骤 2：Commit**

```bash
git add 说明文档.md
git commit -m "docs(device): 同步动态反查完成态 + 水滴自驱双层语义（§4.12）"
```

---

## 自检记录

- **规格覆盖度**：用户拍板三要点——①daemon 轨迹 wifi 跟随 → 任务 2（瓦片变更检测）；②App 水滴自驱（编排位置消费）→ 任务 3（TSelfDrivenDroplet + showsUserLocation 切换）；③双层语义 → 任务 3 步骤 4（系统定位可用判定）。任务 1 是前置（瓦片 key 导出）。任务 4 文档同步。
- **占位符扫描**：无"待定/TODO"；自绘水滴可复用 TRWaypointAnnotation 既有模式（任务 3 步骤 3 指明仿写对象）。
- **类型一致性**：`tileKeyForCoordinate:`（任务 1）在任务 2 消费，返回 uint64_t；`_lastWifiTileKey`（任务 2）类型 uint64_t；TSelfDrivenDroplet（任务 3）继承 MKPointAnnotation，视图分支/拦截与 TRWifiAnnotation 同模式。
- **行为边界**：anchor 模式不接瓦片检测（微动 ≤20m 远小于瓦片，保留"wifi 注入一次即可"）；off 时 `_lastWifiTileKey` 重置（防 restart 残留）。自驱水滴仅定位关时出现，定位开时隐藏（双层=GPS 水滴+信息标注）。