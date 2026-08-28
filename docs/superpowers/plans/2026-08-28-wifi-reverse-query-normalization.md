# WiFi 反查链路规范化实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 规范化 WiFi 反查链路（跨端契约单一真相源、瓦片判定/采样原语共享、App JSON 读取归一、方法重命名、注释同步），**零行为变化**。

**架构：** TRWpsTile 已是三端共享模块（Makefile + pbxproj 双引用）；把"跨端扫描契约常量"提为共享契约模块（头+实现，两端都编译），把"跨瓦片判定 + BSSID 采样"下放为 TRWpsTile 共享原语，App 侧扫描 JSON 读取提炼为私有方法，方法名与实现职责对齐。

**技术栈：** ObjC/ObjC++（Theos + xcodeproj 双构建）；设备端无测试框架，验证 = pbxproj tokenizer 校验 + CI 编译（build-ipa）。

**基线（必须先确认）：** 当前工作区 HEAD 干净（`git status --short` 仅未跟踪的 `抖音iOS逆向分析报告.md`）。所有改动同 commit 提交文档（AGENTS.md 文档纪律）。

---

## 任务 1：跨端扫描契约共享模块（TRWifiScanContract.h/.mm）

**文件：**
- 创建：`TrollVNC/src/TRWifiScanContract.h`
- 创建：`TrollVNC/src/TRWifiScanContract.mm`
- 修改：`TrollVNC/src/TRWifiActiveScanner.h:59-63`（删 2 个 extern，保留 intervalSec）
- 修改：`TrollVNC/src/TRWifiActiveScanner.mm:22-27`（删 2 个定义，import 契约头）
- 测试：无（头/常量；编译验证在任务 6）

- [ ] **步骤 1：创建契约头 `TRWifiScanContract.h`**

```objc
/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 跨端 WiFi 主动扫描契约（单一真相源——App 与 daemon 两个 target 各自编译本模块，符号可链接）
/// 两端必须 import 本头引用常量，禁止在消费侧重写字面量（曾致两端各持一份、改一处忘一处）
/// 常量定义在 TRWifiScanContract.mm（两端 target 都编译该 .mm；App 不编译 TRWifiActiveScanner.mm，
/// 故契约必须独立成模块而非挂在扫描器类上——2026-08-28 定案）

/// 共享扫描结果 JSON 路径（root daemon 写；mobile 用户 App 可读）
extern NSString *const kTRWifiScanJsonPath;
/// 扫描更新 Darwin 通知名（daemon notify_post → App notify_register_dispatch 订阅）
extern NSString *const kTRWifiScanUpdatedNotification;
/// 立即重扫请求通知名（App 关模拟时 notify_post → daemon requestScanNow）
extern NSString *const kTRWifiScanRequestNotification;

NS_ASSUME_NONNULL_END
```

- [ ] **步骤 2：创建契约实现 `TRWifiScanContract.mm`**

```objc
/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "TRWifiScanContract.h"

NSString *const kTRWifiScanJsonPath = @"/var/mobile/Library/Caches/com.82flex.trollvnc.wifiscan.json";
NSString *const kTRWifiScanUpdatedNotification = @"com.82flex.trollvnc.wifiscan-updated";
NSString *const kTRWifiScanRequestNotification = @"com.82flex.trollvnc.wifiscan-request";
```

- [ ] **步骤 3：TRWifiActiveScanner.h 移除已上移的 extern**

将 `TRWifiActiveScanner.h:58-63` 改为（保留 intervalSec，注释指向契约头）：

```objc
/// 共享扫描结果 JSON 路径/更新通知/请求通知 → TRWifiScanContract.h（跨端契约单一真相源，2026-08-28）
/// 本头仅保留 daemon 内部默认扫描周期
/// 默认扫描周期（秒）
extern const NSTimeInterval kTRWifiScanIntervalSec;
```

- [ ] **步骤 4：TRWifiActiveScanner.mm 移除定义 + import 契约头**

`TRWifiActiveScanner.mm:18-27` 改为：

```objc
#import "TRWifiActiveScanner.h"
#import "TRWifiScanContract.h"
#import <notify.h>
#import <dlfcn.h>

/// 默认扫描周期（秒；「启动即自动获取 + 活跃订阅」8s 低频省电）
const NSTimeInterval kTRWifiScanIntervalSec = 8.0;
```

（原 L22-27 的 jsonPath/updatedNotification 定义删除——已上移至契约模块。）

- [ ] **步骤 5：git diff 自检**

运行：`git diff TrollVNC/src/TRWifiActiveScanner.h TrollVNC/src/TRWifiActiveScanner.mm`
预期：仅 2 处删除 + 1 处 import；无其他改动。

- [ ] **步骤 6：Commit**

```bash
git add TrollVNC/src/TRWifiScanContract.h TrollVNC/src/TRWifiScanContract.mm TrollVNC/src/TRWifiActiveScanner.h TrollVNC/src/TRWifiActiveScanner.mm
git commit -m "refactor(device): 跨端 WiFi 扫描契约提炼为共享模块 TRWifiScanContract.h/.mm（单一真相源）——JSON 路径/更新通知/重扫请求通知三常量两端 target 各自编译同一份实现，替代 App 侧 static 字面量与 daemon extern 双写；新增 kTRWifiScanRequestNotification 收敛裸字符串；intervalSec 保留 daemon 内部"
```

---

## 任务 2：daemon 侧裸字符串收敛 + Makefile 注册契约模块

**文件：**
- 修改：`TrollVNC/src/trollvncmanager.mm:676-685`（wifiscan-request 裸字符串 → 常量）
- 修改：`TrollVNC/Makefile`（trollvncmanager_FILES 与 trollvncserver_FILES 各加 TRWifiScanContract.mm——server 不消费但保持"共享模块三 target 同源"一致性）

- [ ] **步骤 1：trollvncmanager.mm 通知名收敛**

`trollvncmanager.mm:679` 的 `"com.82flex.trollvnc.wifiscan-request"` 改为 `kTRWifiScanRequestNotification.UTF8String`，并在文件顶部 import 区加：

```objc
#import "TRWifiScanContract.h"
```

- [ ] **步骤 2：Makefile 注册契约模块**

`Makefile` 中 `trollvncmanager_FILES += src/TRWifiActiveScanner.mm`（L148）后加一行：

```makefile
trollvncmanager_FILES += src/TRWifiScanContract.mm
```

`trollvncserver_FILES += src/TRWpsTile.mm`（L36）后加一行：

```makefile
trollvncserver_FILES += src/TRWifiScanContract.mm
```

（server target 虽不消费扫描契约，但共享模块须三 target 同源编译——对齐 CoordTransform/TRWpsTile 的既有模式，避免"server 缺符号"类意外。**TRWpsProto.mm 不在本任务注册——文件在任务 3 创建，注册随任务 3 一起 commit，保证每个 commit 引用已存在文件。**）

- [ ] **步骤 3：Commit**

```bash
git add TrollVNC/src/trollvncmanager.mm TrollVNC/Makefile
git commit -m "refactor(device): wifiscan-request 裸字符串收敛为 kTRWifiScanRequestNotification；Makefile 三 target 注册 TRWifiScanContract.mm 共享契约模块"
```

---

## 任务 3：共享原语下放（protobuf 解析原语 + 跨瓦片判定 + BSSID 采样）

**文件：**
- 创建：`TrollVNC/src/TRWpsProto.h`（protobuf 读取原语，共享头）
- 创建：`TrollVNC/src/TRWpsProto.mm`（readVarint/skipField 单一实现）
- 修改：`TrollVNC/src/TRWpsTile.h`（新增 2 个类方法声明 + 头注释补 ?tk=；删除本地 static 原语）
- 修改：`TrollVNC/src/TRWpsTile.mm`（新增实现；原语逻辑从 SimLocationController 原样搬移；readVarint/skipField 改 import）
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TRWpsClient.mm`（删除本地 static readVarint/skipField，改 import 共享原语）
- 修改：`TrollVNC/src/SimLocationController.mm:329-335,253-260`（改用共享原语，删除本地 _sampleBssids）
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m:491-498,525-527`（改用共享原语 + 采样）

- [ ] **步骤 1：创建 TRWpsProto.h/.mm（protobuf 读取原语单一真相源）**

```objc
// TRWpsProto.h —— WPS protobuf 读取原语（readVarint/skipField 单一真相源）
// 曾复制于 TRWpsClient.mm 与 TRWpsTile.mm 两份（TRWpsTile 注释自述「复制自 TRWpsClient.mm」；
// 静态函数无法跨文件复用致双份——2026-08-28 提炼为共享模块，两端消费同源）
// 注意 .mm(ObjC++) 下 C 函数默认 C++ linkage，公开时用 extern "C" 暴露 C 符号
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL TRWpsReadVarint(const uint8_t *buf, NSUInteger len, NSUInteger *off, uint64_t *out);
BOOL TRWpsSkipField(const uint8_t *buf, NSUInteger len, NSUInteger *off, int wireType);

#ifdef __cplusplus
}
#endif
```

```objc
// TRWpsProto.mm
#import "TRWpsProto.h"

BOOL TRWpsReadVarint(const uint8_t *buf, NSUInteger len, NSUInteger *off, uint64_t *out) {
    uint64_t result = 0;
    int shift = 0;
    while (*off < len && shift < 64) {
        uint8_t b = buf[*off];
        (*off)++;
        result |= (uint64_t)(b & 0x7f) << shift;
        if (!(b & 0x80)) { *out = result; return YES; }
        shift += 7;
    }
    return NO;
}

BOOL TRWpsSkipField(const uint8_t *buf, NSUInteger len, NSUInteger *off, int wireType) {
    uint64_t v;
    switch (wireType) {
        case 0: return TRWpsReadVarint(buf, len, off, &v);
        case 1: if (*off + 8 > len) return NO; *off += 8; return YES;
        case 2: {
            uint64_t sl;
            if (!TRWpsReadVarint(buf, len, off, &sl)) return NO;
            if (sl > len - *off) return NO;
            *off += (NSUInteger)sl;
            return YES;
        }
        case 5: if (*off + 4 > len) return NO; *off += 4; return YES;
        default: return NO;
    }
}
```

TRWpsClient.mm 删除本地 static readVarint/skipField（L100-128），改 `#import "TRWpsProto.h"`，本地调用 `readVarint(`/`skipField(` 改名 `TRWpsReadVarint(`/`TRWpsSkipField(`（TRWpsClient 内 5 处调用点：L135/136/139/145/146/158/160 等，按 grep 逐处替换）。
TRWpsTile.mm 删除本地 static readVarint/skipField（L27-55），改 `#import "TRWpsProto.h"`，调用点同上改名（L44/46/114/116/121/122 等）。

（跨文件 C 函数共享不用 extern "C" 会在 .mm 中被 C++ mangling——与 AGENTS.md「TRRegions kRegions 坑」同型，必须显式处理。）

Makefile 同步注册（TRWpsProto 随文件创建一起注册，保证 commit 自洽——server/manager 因编译 TRWpsTile 而需要原语符号）：

`trollvncserver_FILES += src/TRWpsTile.mm`（L36）后：
```makefile
trollvncserver_FILES += src/TRWpsProto.mm
```
`trollvncmanager_FILES += src/TRWpsTile.mm`（L147）后：
```makefile
trollvncmanager_FILES += src/TRWpsProto.mm
```

- [ ] **步骤 2：TRWpsTile.h 增加声明 + 补 ?tk= 注释**

`TRWpsTile.h` 在 `tileKeyForCoordinate:` 声明后加：

```objc
/// 跨瓦片判定共享原语（App/daemon 双消费，语义一致）：
/// 计算 coord 所属瓦片 key 并与 previous 比较。返回 YES = 已跨瓦片（*newKey 输出新 key，
/// 消费方应重新反查并记录）；返回 NO = 同瓦片（*newKey 保持 previous 值，消费方跳过）。
+ (BOOL)tileChangedForCoordinate:(CLLocationCoordinate2D)coord
                        previous:(uint64_t)previous
                          newKey:(uint64_t *)newKey;

/// BSSID 采样共享原语（cap 上限；daemon 注入与 App 标注同源，消除"注入 100/标注全量"不对称）
+ (NSArray<NSString *> *)sampleBssidsFromAPs:(NSArray<TRWpsTileAP *> *)aps max:(NSUInteger)max;
```

头注释 `/// 协议：GET gspe85-cn-ssl.ls.apple.com/wifi_request_tile + X-tilekey(morton)，响应纯 protobuf` 后补一行：

```objc
/// URL 已追加 ?tk=<tilekey> 作 CDN cache-buster（金山云 CDN 缓存键只含 URL、不含 X-tilekey header，
/// 曾致所有瓦片命中同一份陈旧缓存固定响应；origin 按 header 取数、忽略 query，2026-08-27 实测）
```

- [ ] **步骤 3：TRWpsTile.mm 添加实现**

在 `+ (uint64_t)tileKeyForCoordinate:` 实现后追加：

```objc
+ (BOOL)tileChangedForCoordinate:(CLLocationCoordinate2D)coord
                        previous:(uint64_t)previous
                          newKey:(uint64_t *)newKey {
    int32_t tx = 0, ty = 0;
    latLonToTile(coord.latitude, coord.longitude, kTRWpsTileLevel, &tx, &ty);
    uint64_t key = packTileKey((uint32_t)ty, (uint32_t)tx, kTRWpsTileLevel);
    if (newKey) *newKey = key;
    return (key != previous);
}

+ (NSArray<NSString *> *)sampleBssidsFromAPs:(NSArray<TRWpsTileAP *> *)aps max:(NSUInteger)max {
    NSMutableArray *bssids = [NSMutableArray arrayWithCapacity:MIN(max, aps.count)];
    NSUInteger n = MIN(max, aps.count);
    for (NSUInteger i = 0; i < n; i++) [bssids addObject:aps[i].bssid];
    return bssids;
}
```

- [ ] **步骤 3：SimLocationController 改用共享原语（内联，删除本地采样方法）**

`SimLocationController.mm:329-335` `_checkWifiTileChangedAndReinject` 改为（直接调用共享原语）：

```objc
- (void)_checkWifiTileChangedAndReinject {
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(_currentLat, _currentLon);
    if (coord.latitude == 0 && coord.longitude == 0) return; // 无当前位置
    uint64_t newKey = 0;
    if (![TRWpsTile tileChangedForCoordinate:coord previous:_lastWifiTileKey newKey:&newKey]) return; // 同瓦片
    _lastWifiTileKey = newKey;
    [self _injectWifiSimulationForCurrentLocation];
}
```

`SimLocationController.mm:253-260` 的本地 `_sampleBssids:max:` 方法**整段删除**，`SimLocationController.mm:243` 调用点改为：

```objc
NSArray<NSString *> *sample = [TRWpsTile sampleBssidsFromAPs:aps max:100];
```

- [ ] **步骤 4：App 侧改用共享原语 + 采样**

`TRMapPickerViewController.m:491-498` `_refreshWifiAnnoIfTileChanged` 内联改为：

```objc
- (void)_refreshWifiAnnoIfTileChanged {
    if (!self.locating) return;
    CLLocationCoordinate2D curW = [CoordTransform gcj02ToWgs84:self.cur];
    if (curW.latitude == 0 && curW.longitude == 0) return; // 无当前位置
    uint64_t newKey = 0;
    if (![TRWpsTile tileChangedForCoordinate:curW previous:self.wifiLastTileKey newKey:&newKey]) return; // 同瓦片
    self.wifiLastTileKey = newKey;
    [self handleWifiScanUpdate:@[] summary:@""]; // 跨瓦片：按模拟当前位置反查标注
}
```

`TRMapPickerViewController.m:525-527` 的 BSSID 全量转换改为：

```objc
NSArray<NSString *> *bssids = [TRWpsTile sampleBssidsFromAPs:aps max:100]; // 与 daemon 注入同源 cap（2026-08-28）
```

- [ ] **步骤 5：git diff 自检 + Commit**

运行：`git diff --stat TrollVNC/src/TRWpsProto.h TrollVNC/src/TRWpsProto.mm TrollVNC/src/TRWpsTile.h TrollVNC/src/TRWpsTile.mm TrollVNC/app/TrollVNC/TrollVNC/TRWpsClient.mm TrollVNC/src/SimLocationController.mm TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m TrollVNC/Makefile`
预期：6 文件 + 2 新建；`tileChangedForCoordinate` 与 `sampleBssidsFromAPs` 两端调用点一致；`readVarint`/`skipField` 不再出现于 TRWpsClient.mm 与 TRWpsTile.mm（`git grep -n "readVarint\\|skipField" TrollVNC/src/TRWpsTile.mm TrollVNC/app/TrollVNC/TrollVNC/TRWpsClient.mm` 应 0 命中）。

```bash
git add TrollVNC/src/TRWpsProto.h TrollVNC/src/TRWpsProto.mm TrollVNC/src/TRWpsTile.h TrollVNC/src/TRWpsTile.mm TrollVNC/app/TrollVNC/TrollVNC/TRWpsClient.mm TrollVNC/src/SimLocationController.mm TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m TrollVNC/Makefile
git commit -m "refactor(device): WPS 共享原语下放——①protobuf 读取原语提炼为 TRWpsProto.h/.mm（TRWpsClient 与 TRWpsTile 曾各复制一份 readVarint/skipField，现单一真相源 extern \"C\" 共享）；②跨瓦片判定 tileChangedForCoordinate:/BSSID 采样 sampleBssidsFromAPs: 入 TRWpsTile——App 标注与 daemon 注入同源，消除两端重复实现与 AP cap 不对称"
```

---

## 任务 4：App 扫描 JSON 读取归一（私有方法提炼）

**文件：**
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m`（新增私有方法；替换 4 处重复读取 + 订阅回调/水合/诊断/刷新共用）

- [ ] **步骤 1：新增私有方法**

在 `handleActiveWifiBssids:`（L479）前加：

```objc
/// 主动扫描 JSON 读取归一（读文件→解析→取 bssids；无/格式错返回 nil）——订阅回调/水合/诊断/刷新共用
- (NSArray<NSString *> *)_readActiveScanBssids {
    NSData *data = [NSData dataWithContentsOfFile:kTRWifiScanJsonPath];
    if (!data) return nil;
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *bssids = obj[@"bssids"];
    if (![bssids isKindOfClass:[NSArray class]]) return nil;
    return bssids;
}
```

- [ ] **步骤 2：替换 4 处重复读取**

1. 订阅回调（L169-174）：

```objc
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSArray<NSString *> *bssids = [strongSelf _readActiveScanBssids];
        if (!bssids) return;
        [strongSelf handleActiveWifiBssids:bssids];
```

2. 启动水合（L178-183）：

```objc
    NSArray<NSString *> *seedBssids = [self _readActiveScanBssids];
    if (seedBssids) [self handleActiveWifiBssids:seedBssids];
```

3. refreshWifiDiag（L453-467）：直接用已解析的 obj 取 bssids 计数（诊断需 ts，保留单次原始读取；避免再次调用 _readActiveScanBssids 读文件）：

```objc
- (void)refreshWifiDiag {
    NSData *data = [NSData dataWithContentsOfFile:kTRWifiScanJsonPath];
    if (data) {
        NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([obj isKindOfClass:[NSDictionary class]]) {
            NSArray *bssids = obj[@"bssids"];
            NSNumber *ts = obj[@"ts"];
            self.wifiDiagLabel.text = [NSString stringWithFormat:
                @"WiFi: 主动扫描 %lu BSSID @%@",
                (unsigned long)([bssids isKindOfClass:[NSArray class]] ? bssids.count : 0),
                ts ? [NSDate dateWithTimeIntervalSince1970:[ts doubleValue]] : (id)@"—"];
            return;
        }
    }
    self.wifiDiagLabel.text = @"WiFi: 主动扫描未产出数据";
}
```

（注：诊断需 ts，保留单次原始读取拿到 obj 后内部取 bssids——不再调用 _readActiveScanBssids，避免二次读文件。）

4. refreshWifiAnnotation 停止分支（L583-593）：

```objc
        NSArray<NSString *> *bssids = [self _readActiveScanBssids];
        if (bssids.count) {
            NSUInteger seq = ++self.wifiQuerySeq;
            [self _queryWifiAnnoWithBssids:bssids seq:seq]; // 真实 BSSID wloc 反查标注（回到真实位置）
        } else {
            [self handleWifiScanUpdate:@[] summary:@""]; // 主动扫描未产出：清除残留标注（等 notify 恢复）
        }
```

- [ ] **步骤 3：git diff 自检 + Commit**

确认重复读取已消除（订阅回调/水合/刷新 3 处改为 `_readActiveScanBssids`；诊断因需 ts 保留原始读取）：

运行：`git grep -n "dataWithContentsOfFile:kTRWifiScanJsonPath"`（预期 2 命中 = 私有方法体 + refreshWifiDiag）

```bash
git add TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m
git commit -m "refactor(app): 主动扫描 JSON 读取提炼为 _readActiveScanBssids 私有方法——订阅回调/启动水合/诊断/刷新四处重复模式归一"
```

---

## 任务 5：方法重命名与注释同步

**文件：**
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m`（handleWifiScanUpdate: 重命名 + 注释清理）
- 修改：`TrollVNC/src/SimLocationManager.h:47-48`（键名注释更新）
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TRWpsClient.h`（如头注释仍有 NEHotspotHelper 残留则清理）

- [ ] **步骤 1：handleWifiScanUpdate: → requeryAnnotationForSimLocation:**

方法签名（L504）与注释改为：

```objc
/// 模拟态 wifi 标注反查（唯一调用方 = _refreshWifiAnnoIfTileChanged / 停止态清除残留）：
/// 按模拟当前位置动态反查 BSSID（TRWpsTile，与 daemon 注入同源；轨迹跟随）。
/// 真实位置标注统一走 handleActiveWifiBssids（主动扫描唯一数据源）。
- (void)requeryAnnotationForSimLocation {
    if (!self.locating) return; // 仅模拟态使用；停止态由 handleActiveWifiBssids 驱动
    CLLocationCoordinate2D curW = [CoordTransform gcj02ToWgs84:self.cur];
    if (curW.latitude != 0 || curW.longitude != 0) {
        NSUInteger seqHere = ++self.wifiQuerySeq;
        __weak typeof(self) wSelf = self;
        [[TRWpsTile sharedClient] queryBssidsForCoordinate:curW force:NO completion:^(NSArray<TRWpsTileAP *> *aps, NSError *error) {
            __strong typeof(self) sSelf = wSelf;
            if (!sSelf) return;
            if (seqHere != sSelf.wifiQuerySeq) return; // 过期回调丢弃（竞态防护）
            if (error || aps.count == 0) {
                sSelf.wifiDiagLabel.text = [NSString stringWithFormat:@"WiFi: 模拟位置(%.4f,%.4f)瓦片反查失败%@",
                    curW.latitude, curW.longitude,
                    error.localizedDescription ?: @"（该位置无 BSSID，Apple 数据空洞区）"];
                return;
            }
            NSArray<NSString *> *bssids = [TRWpsTile sampleBssidsFromAPs:aps max:100];
            [sSelf _queryWifiAnnoWithBssids:bssids seq:seqHere]; // 复用反查+标注显示
        }];
    } else {
        [self removeWifiAnnotationIfExists]; // 无当前位置：清除残留标注
    }
}
```

方法体原注释（L501-503 的 NEHotspotHelper 残留对比）一并删除。其余调用点同步改名：
- L498 `[self handleWifiScanUpdate:@[] summary:@""]` → `[self requeryAnnotationForSimLocation]`
- L506 方法定义内 `(void)nets; (void)summary;` 兼容注释删除（签名已无参数）
- L595 `[self handleWifiScanUpdate:@[] summary:@""]` → `[self requeryAnnotationForSimLocation]`

全局检查残留：

运行：`git grep -n "handleWifiScanUpdate"`（预期 0 命中）

- [ ] **步骤 2：SimLocationManager.h 键名注释更新**

L47-48 改为：

```objc
/// WiFi 扫描模拟注入（输入层）：setWifiScanResults + setSimulatedWifiPower + startWifiSimulation
/// @param scanResults  NSArray<NSDictionary *>，每项含 bssid/ssid/rssi/channel/age/timestamp
/// 键名按初始猜想 + XPC 载荷取证校准；已真机投产（buildScanResultsFromBssidStrings 生成方与此消费方同构）
```

- [ ] **步骤 3：Commit**

```bash
git add TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m TrollVNC/src/SimLocationManager.h
git commit -m "refactor(app): handleWifiScanUpdate: 重命名为 requeryAnnotationForSimLocation:（对齐实现职责：模拟态反查，不再消费扫描结果）；删除 NEHotspotHelper 残留对比注释；SimLocationManager.h 键名注释更新为投产状态"
```

---

## 任务 6：pbxproj 注入契约 + protobuf 共享模块 + tokenizer 校验

**文件：**
- 修改：`TrollVNC/app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj`
- 创建（一次性）：校验脚本（可用后删除或留 scripts/）

- [ ] **步骤 1：pbxproj 注入 TRWifiScanContract.mm/.h + TRWpsProto.mm/.h**

参照 `CoordTransform` 条目模式（A100...0001/.h + A100...0002/.m + A100...0003 BuildFile）新增两组（ID 用 AA 系列未占用号：D1-D3 契约、D4-D6 protobuf）：

1. PBXBuildFile 段新增：
```
AA01000000000000000000D1 /* TRWifiScanContract.mm in Sources */ = {isa = PBXBuildFile; fileRef = AA01000000000000000000D2 /* TRWifiScanContract.mm */; };
AA01000000000000000000D4 /* TRWpsProto.mm in Sources */ = {isa = PBXBuildFile; fileRef = AA01000000000000000000D5 /* TRWpsProto.mm */; };
```
2. PBXFileReference 段新增：
```
AA01000000000000000000D2 /* TRWifiScanContract.mm */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objcpp; path = ../../../src/TRWifiScanContract.mm; sourceTree = "<group>"; };
AA01000000000000000000D3 /* TRWifiScanContract.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = ../../../src/TRWifiScanContract.h; sourceTree = "<group>"; };
AA01000000000000000000D5 /* TRWpsProto.mm */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objcpp; path = ../../../src/TRWpsProto.mm; sourceTree = "<group>"; };
AA01000000000000000000D6 /* TRWpsProto.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = ../../../src/TRWpsProto.h; sourceTree = "<group>"; };
```
3. Group children 段（CoordTransform 附近）加 4 项（两组 .h + .mm）
4. 主 target Sources phase（含 CoordTransform，L524 所在）加两条 BuildFile

**注意（AGENTS.md bootstrap 坑）：** ①新增对象 ID 必须全局唯一（参照表对照全文件）；②path 含特殊字符需引号（本 path 无 + / 等，常规引号形式即可）；③不要动其它行。Windows 无 xcodebuild，靠 tokenizer 校验。

- [ ] **步骤 2：一次性 tokenizer 校验（括号配平/每行分号/ID 唯一性）**

创建 `_tmp-insp/pbxproj-syntax-check.mjs` 并按 AGENTS.md 建议校验：

```js
import { readFileSync } from 'node:fs';
const src = readFileSync(process.argv[2], 'utf8');
let depth = 0, line = 1, ok = true;
for (const ch of src) {
  if (ch === '\n') { line++; }
  if (ch === '{') depth++;
  if (ch === '}') { depth--; if (depth < 0) { console.error(`L${line}: 括号闭合溢出`); ok = false; } }
}
if (depth !== 0) { console.error(`括号配平失败 depth=${depth}`); ok = false; }
const ids = new Set();
let m;
const idRe = /\b([0-9A-F]{24}) \/\* .*? \*\/ = /g;
while ((m = idRe.exec(src))) { if (ids.has(m[1])) { console.error(`ID 重复: ${m[1]}`); ok = false; } ids.add(m[1]); }
console.log(ok ? 'pbxproj syntax OK' : 'pbxproj syntax FAIL');
```

运行：`node _tmp-insp/pbxproj-syntax-check.mjs TrollVNC/app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj`
预期：`pbxproj syntax OK`

- [ ] **步骤 3：Commit**

```bash
git add TrollVNC/app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj
git commit -m "build(app): pbxproj 注册共享契约模块 TRWifiScanContract.mm/.h（主 target Sources + FileRef，参照 CoordTransform 模式）"
```

---

## 任务 7：文档同步 + 全量 diff 自检

**文件：**
- 修改：`说明文档.md`（§4.x WiFi 定位章节：契约模块/共享原语/重命名同步）
- 修改：`AGENTS.md`（已知坑/约定如有相关描述则校准行号与措辞）

- [ ] **步骤 1：说明文档.md 同步**

在 WiFi 主动扫描/反查相关章节（§4.8 或 §4.12 内）追加或校准：

```markdown
- **跨端扫描契约单一真相源（2026-08-28）**：`TRWifiScanContract.h/.mm` 为共享契约模块（App 与 daemon 两端 target 各自编译），常量 `kTRWifiScanJsonPath`/`kTRWifiScanUpdatedNotification`/`kTRWifiScanRequestNotification` 单一来源；消费侧禁止重写字面量。
- **瓦片反查共享原语（2026-08-28）**：`TRWpsTile tileChangedForCoordinate:previous:newKey:`（跨瓦片判定）与 `sampleBssidsFromAPs:max:`（AP 采样 cap）为共享原语，App 标注与 daemon 注入同源；`handleWifiScanUpdate:` 已更名 `requeryAnnotationForSimLocation:`。
```

（按文档实际章节结构放置，勿复制列表进文档——只更新事实描述。）

- [ ] **步骤 2：全量 diff 自检**

运行：`git diff HEAD~6 --stat` 并逐一确认：仅计划内文件改动，无行为逻辑变化（状态机/注入序列/巡检节奏/UI 语义均未触碰）。

- [ ] **步骤 3：Commit**

```bash
git add 说明文档.md AGENTS.md
git commit -m "docs: WiFi 扫描契约单一真相源 + 瓦片反查共享原语入档"
```

---

## 任务 8：CI 出包验证（唯一编译验证）

**文件：** 无

- [ ] **步骤 1：推送 + dispatch + 下载 .tipa**

运行（Push via API + workflow_dispatch，`GHTOK` 已配置）：

```powershell
$env:GHTOK = (Get-Content "$env:USERPROFILE\.trae-cn\gh-token.txt" | Select-Object -First 1)
node scripts/build-ipa.mjs HEAD "."
```

预期：CI 四 scheme（default/rootless/roothide/bootstrap）全 success；`TrollVNC_0.0.1.tipa` 产出（3.9MB 级、~178 条目，`tar -tf` 校验无截断）。

- [ ] **步骤 2：真机行为验证清单（装机后）**

| 验证项 | 预期 |
|---|---|
| 停止态 wifi 标注 | 正常反查（真实位置）——契约常量路径/通知名未变 |
| 模拟态北京/洛阳城区 | 瓦片反查 OK，AP cap ≤100——共享采样生效 |
| 连续编辑锚点 | 热重载无风暴（6bda04d 特征仍有效） |
| 5902 日志 | `[wps] tile req` 正常输出；无缺符号/链接错误 |

---

## 自检记录（writing-plans 规格覆盖度）

- 规格节 1（契约收敛）→ 任务 1、2、6（共享模块 + 两端引用 + pbxproj 注册）
- 规格节 2（原语下放：protobuf + 跨瓦片判定）→ 任务 3
- 规格节 3（采样对齐）→ 任务 3 步骤 4 + 任务 5 步骤 1
- 规格节 4（JSON 读取归一）→ 任务 4
- 规格节 5（注释与命名）→ 任务 5
- 文档同步 + 验证 → 任务 7、8

**设计修正记录：**
1. 原方案 A「契约头仅 extern 声明」经代码勘察修正——App 不编译 TRWifiActiveScanner.mm，extern 符号无法链接；故契约改为**独立共享模块（.h+.mm 双文件，两端编译）**，与 CoordTransform/TRWpsTile 的既有共享模式一致。
2. 审查期新增：**protobuf 读取原语 readVarint/skipField 在 TRWpsClient.mm 与 TRWpsTile.mm 各复制一份**（TRWpsTile 注释自述「复制自 TRWpsClient.mm」）——这是真正的"两个实现"；提炼为 `TRWpsProto.h/.mm` 共享模块（extern "C" 防 C++ mangling，对齐 AGENTS.md TRRegions kRegions 坑）。