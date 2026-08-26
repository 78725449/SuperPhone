# WiFi 定位伪装 Phase 3 实现计划（坐标→BSSID 动态反查，轨迹跟随）

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 实现设计文档（`docs/superpowers/specs/2026-08-27-wifi-spoof-double-layer-design.md`）的**坐标→BSSID 动态反查**——设备端调 Apple gspe tile 端点（`gspe85-cn-ssl.ls.apple.com/wifi_request_tile`）按模拟坐标反查该位置附近真实 BSSID，替代固定 `kWpsBssids`（仅杭州），使 wifi 注入与标注**任意区域自洽 + 跟随定位路径移动**。

**架构：** tile 反查逻辑（坐标→BSSID）作为**共享模块**放 `TrollVNC/src/`（对齐 CoordTransform 三端编译模式），App（标注）与 daemon（注入）各消费一份。轨迹移动时：当前坐标 → tile 反查 BSSID → A 层注入 + App 标注；LRU 缓存 + 预取下一段避免每点请求。

**技术栈：** Objective-C++（共享模块）/ NSURLSession / protobuf 手写编解码（morton tile key、int64→MAC、sfixed32 坐标）/ theos + CI。

**设计文档：** `docs/superpowers/specs/2026-08-27-wifi-spoof-double-layer-design.md` §坐标→SSID 反查（动态+预取混合）+ §目标 App 分析结论（wifi_bssid 上传）
**协议参考：** `scripts/apple-wps.mjs` §tile（L262-424，PC 端已验证）

---

## 文件结构

- 创建：`TrollVNC/src/TRWpsTile.h` — tile 反查共享接口（坐标→BSSID 列表）
- 创建：`TrollVNC/src/TRWpsTile.mm` — morton key 编码 + X-tilekey 头 + NSURLSession GET + protobuf 解析（纯 protobuf 无 ARPC 头）+ LRU 缓存
- 修改：`TrollVNC/src/SimLocationController.mm` — 轨迹/锚点注入点用 tile 反查 BSSID（替换固定 kWpsBssids）
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m` — 标注用 tile 反查 BSSID（替换固定 kWpsBssids）
- 修改：`TrollVNC/Makefile` — trollvncmanager/trollvncserver_FILES 加 TRWpsTile 源
- 修改：`TrollVNC/app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj` — TRWpsTile.h/.mm 注册（FileRef + group + Sources phase，**这次必须显式引用，bootstrap 教训**）
- 修改：`说明文档.md` — 同步动态反查（§4.12 更新）

---

### 任务 1：TRWpsTile 共享模块（坐标→BSSID 反查）

**文件：**
- 创建：`TrollVNC/src/TRWpsTile.h`
- 创建：`TrollVNC/src/TRWpsTile.mm`

**背景**：移植 `apple-wps.mjs` tile 逻辑（L262-424）到 ObjC。协议关键差异：**tile 是 GET + `X-tilekey` 头，响应纯 protobuf（无 ARPC 头）**；bssid 是 int64（大端取低 6 字节→MAC）；坐标 sfixed32 ÷1e7。含 LRU 缓存（同瓦片复用）。

- [ ] **步骤 1：读 mjs tile 实现完整确认**

读 `scripts/apple-wps.mjs` L262-424：latLonToTile（Web Mercator +0.5 舍入）、packTileKey（morton 编码，level=13）、tileToNW（不用，仅请求侧）、macFromInt64、parseWifiTile（Region(3){Device(2){bssid=5 int64, entry=6{lat=1/long=2 sfixed32}}}）、pickTileHost（中国 bbox 启发式）、tileQuery（GET + X-tilekey）。同时确认 TRWpsClient.mm 已有的 readVarint/skipField 可复用（共享原语或复制）。

- [ ] **步骤 2：创建 TRWpsTile.h**

```objc
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/// 单个 AP（BSSID + WGS-84 坐标）
@interface TRWpsTileAP : NSObject
@property (nonatomic, copy) NSString *bssid;   // 标准格式 XX:XX:XX:XX:XX:XX
@property (nonatomic, assign) CLLocationCoordinate2D coord;
@end

/// 坐标→BSSID 动态反查（共享模块：App 标注 + daemon 注入双消费方）
/// 协议：GET gspe85-cn-ssl.ls.apple.com/wifi_request_tile + X-tilekey(morton)，响应纯 protobuf
/// 设计文档 §坐标→SSID 反查：动态+预取混合，本类提供动态查询 + LRU 瓦片缓存
@interface TRWpsTile : NSObject

+ (instancetype)sharedClient;

/// 按坐标反查该位置附近真实 BSSID（level 13 瓦片；同瓦片 LRU 缓存复用）
/// @param coord   WGS-84 坐标（模拟当前位置）
/// @param force   强制刷新（忽略缓存，轨迹预取用）
/// completion 主队列；aps 非空 = 命中；error 非 nil = 网络/HTTP/解析失败
- (void)queryBssidsForCoordinate:(CLLocationCoordinate2D)coord
                           force:(BOOL)force
                      completion:(void (^)(NSArray<TRWpsTileAP *> *aps, NSError *_Nullable error))completion;

/// 清理缓存（瓦片失效/城市切换时）
- (void)clearCache;

@end

NS_ASSUME_NONNULL_END
```

- [ ] **步骤 3：创建 TRWpsTile.mm（核心逻辑）**

```objc
#import "TRWpsTile.h"
#import <CoreFoundation/CoreFoundation.h>

@implementation TRWpsTileAP
@end

@interface TRWpsTile ()
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<TRWpsTileAP *> *> *cache; // tileKey → aps
@end

@implementation TRWpsTile {
    NSMutableDictionary<NSNumber *, NSArray<TRWpsTileAP *> *> *_cache;
}

+ (instancetype)sharedClient {
    static TRWpsTile *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[TRWpsTile alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) { _cache = [NSMutableDictionary dictionary]; }
    return self;
}

// ---------- Web Mercator 瓦片坐标（对齐 mjs latLonToTile，带 +0.5 像素舍入） ----------
static double clipV(double v, double min, double max) { return MIN(MAX(v, min), max); }

static void latLonToTile(double lat, double lon, int level, uint32_t *txOut, uint32_t *tyOut) {
    double size = 256.0 * (1 << level);
    double la = clipV(lat, -85.05112878, 85.05112878);
    double lo = clipV(lon, -180, 180);
    double x = (lo + 180) / 360.0;
    double sinLat = sin(la * M_PI / 180.0);
    double y = 0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * M_PI);
    double px = floor(clipV(x * size + 0.5, 0, size - 1));
    double py = floor(clipV(y * size + 0.5, 0, size - 1));
    *txOut = (uint32_t)(px / 256.0);
    *tyOut = (uint32_t)(py / 256.0);
}

// ---------- morton 编码（对齐 mjs packTileKey；level=13 → key < 2^27 可用 uint64） ----------
static uint64_t packTileKey(uint32_t row, uint32_t column, int level) {
    uint64_t result = 1ull << (level << 1);
    for (int i = 0; i < level; i++) {
        if (column & 1) result += 1ull << (2 * i);
        if (row & 1) result += 1ull << (2 * i + 1);
        column >>= 1;
        row >>= 1;
    }
    return result;
}

// ---------- int64 → MAC（对齐 mjs macFromInt64：大端 8 字节取低 6 字节） ----------
static NSString *macFromInt64(uint64_t v) {
    uint8_t bytes[8];
    for (int i = 0; i < 8; i++) { bytes[7 - i] = (uint8_t)(v & 0xff); v >>= 8; } // 大端展开
    // 取低 6 字节（bytes[2..7]）
    return [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
            bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]];
}

// ---------- tile host 选择（对齐 mjs pickTileHost：中国大陆 bbox 启发式） ----------
static NSString *tileHostFor(double lat, double lon) {
    if (lat >= 18 && lat <= 54 && lon >= 73 && lon <= 135) {
        return @"https://gspe85-cn-ssl.ls.apple.com";
    }
    return @"https://gspe85-ssl.ls.apple.com";
}

// ---------- 响应解析（对齐 mjs parseWifiTile：Region(3){Device(2){bssid=5 int64, entry=6{lat=1/long=2 sfixed32}}}） ----------
// 复用 TRWpsClient 的 readVarint/skipField 原语——若无法跨文件复用则在本文件复制一份（静态函数无链接冲突）
static NSArray<TRWpsTileAP *> *parseWifiTileData(NSData *data) {
    // ... 完整解析：外层 field3(wire2)=Region → field2(wire2)=Device → field5(varint)=bssid、field6(wire2)=entry → field1/2(sfixed32) 坐标 ÷1e7
    // 解析失败/空结果返回 @[]
}

- (void)queryBssidsForCoordinate:(CLLocationCoordinate2D)coord
                           force:(BOOL)force
                      completion:(void (^)(NSArray<TRWpsTileAP *> *aps, NSError *_Nullable error))completion {
    if (!completion) return;
    uint32_t tx, ty;
    latLonToTile(coord.latitude, coord.longitude, 13, &tx, &ty);
    uint64_t key = packTileKey(ty, tx, 13);
    NSNumber *keyBox = @(key);
    if (!force && _cache[keyBox]) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(_cache[keyBox], nil); });
        return;
    }
    NSString *host = tileHostFor(coord.latitude, coord.longitude);
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/wifi_request_tile", host]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 15;
    [req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [req setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
    [req setValue:@"geod/1 CFNetwork/1496.0.7 Darwin/23.5.0" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"en-US,en-GB;q=0.9,en;q=0.8" forHTTPHeaderField:@"Accept-Language"];
    [req setValue:@"17.5.21F79" forHTTPHeaderField:@"X-os-version"];
    [req setValue:[NSString stringWithFormat:@"%llu", key] forHTTPHeaderField:@"X-tilekey"];

    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *netErr) {
        NSArray<TRWpsTileAP *> *aps = @[];
        NSError *outErr = netErr;
        if (!netErr) {
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)resp;
            if (![httpResp isKindOfClass:[NSHTTPURLResponse class]] || httpResp.statusCode < 200 || httpResp.statusCode >= 300) {
                outErr = [NSError errorWithDomain:@"TRWpsTile" code:httpResp.statusCode ?: -1
                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"tile HTTP %ld", (long)httpResp.statusCode]}];
            } else if (data.length) {
                aps = parseWifiTileData(data); // 响应纯 protobuf（无 ARPC 头，与 query 不同！）
                if (aps.count) self->_cache[keyBox] = aps; // LRU 缓存（简化：容量上限裁剪可选）
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(aps, outErr); });
    }];
    [task resume];
}

- (void)clearCache {
    [_cache removeAllObjects];
}

@end
```

**注意**：`parseWifiTileData` 是核心解析（任务 1 的难点），需完整实现——外层 field3=Region、Region 内 field2=Device、Device 内 field5=bssid(int64)、field6=entry、entry 内 field1=lat/field2=lon（sfixed32，`readInt32LE` 语义 = 小端 4 字节，ObjC 用 `memcpy` 到 int32_t 或逐字节组装）。**必须严格对齐 mjs parseWifiTile**（含所有 skip 分支）。bssid 字段号是 5（不是 query 的 1/2）——不要套用 query 解析。

- [ ] **步骤 4：Makefile 加源**

`TrollVNC/Makefile` 的 `trollvncmanager_FILES`（约 L139-144）与 `trollvncserver_FILES`（约 L34-39）各加：
```makefile
trollvncmanager_FILES += src/TRWpsTile.mm
trollvncserver_FILES += src/TRWpsTile.mm
```
（App target 走 pbxproj，见任务 4 或本任务步骤 5——按实现顺序，pbxproj 可在任务 4 统一处理，但**本任务先加 Makefile 让 daemon 侧可编译**；App 侧 pbxproj 在任务 4。）

- [ ] **步骤 5：Commit**

```bash
git add TrollVNC/src/TRWpsTile.h TrollVNC/src/TRWpsTile.mm TrollVNC/Makefile
git commit -m "feat(device): TRWpsTile 坐标→BSSID 动态反查共享模块（gspe tile + morton + LRU 缓存，对齐 apple-wps.mjs tile）"
```

---

### 任务 2：daemon 注入改用动态反查（轨迹跟随 A 层）

**文件：**
- 修改：`TrollVNC/src/SimLocationController.mm`

**背景**：现在 `_injectWifiSimulationForCurrentLocation`（L180-185）用固定 `kWpsBssids` 注入。改为按当前模拟坐标 tile 反查 BSSID 注入——轨迹移动时 wifi 模拟源跟随。

- [ ] **步骤 1：读现有 _injectWifiSimulationForCurrentLocation 与调用点**

读 `SimLocationController.mm` L175-185（当前实现）、L120-121（anchor 调用）、L223-224（track 调用）。确认 `_currentLat/_currentLon` 是每次注入后的当前位置（L157-158/L249-250 已更新）。

- [ ] **步骤 2：改造为动态反查注入**

```objc
/// 统一目标位置源：wifi 扫描模拟与 GPS 同源注入（动态反查——按当前坐标 tile 查 BSSID 注入）
/// 设计文档 §坐标→SSID 反查：动态+预取混合；轨迹移动时随 _current 变化
- (void)_injectWifiSimulationForCurrentLocation {
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(_currentLat, _currentLon);
    if (coord.latitude == 0 && coord.longitude == 0) return; // 无当前位置（未注入过）
    __weak __typeof__(self) weakSelf = self;
    [[TRWpsTile sharedClient] queryBssidsForCoordinate:coord force:NO completion:^(NSArray<TRWpsTileAP *> *aps, NSError *error) {
        __strong __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error || aps.count == 0) {
            // 反查失败：保持现状（若已有 wifi 模拟则不动；无则跳过本次）——避免频繁重试
            TVLog(@"[locsim] tile query failed: %@", error.localizedDescription ?: @"no APs");
            return;
        }
        // 构建 scanResults 字典（复用 SimLocationManager buildScanResultsFromBssids 或直接构造）
        NSMutableArray<NSString *> *bssids = [NSMutableArray arrayWithCapacity:aps.count];
        for (TRWpsTileAP *ap in aps) [bssids addObject:ap.bssid];
        // 用前 N 个（避免请求过大；取前 100 个代表性 AP 足够 locationd 解算）
        NSArray *sample = bssids.count > 100 ? [bssids subarrayWithRange:NSMakeRange(0, 100)] : bssids;
        const char **cArr = calloc(sample.count, sizeof(char *));
        for (NSUInteger i = 0; i < sample.count; i++) {
            cArr[i] = [sample[i] UTF8String]; // 注意：UTF8String 生命周期——需在调用期间保持（或用 NSArray 传递改造 buildScanResults 签名）
        }
        NSArray *scanResults = [SimLocationManager buildScanResultsFromBssids:cArr count:sample.count];
        free(cArr);
        if (scanResults.count) {
            [[SimLocationManager sharedManager] injectWifiScanResults:scanResults];
        }
    }];
}
```

**注意（关键改造点）**：`buildScanResultsFromBssids:` 现有签名是 `(const char **)bssids count:`，传 UTF8String 有生命周期风险。**建议改为新增 `+buildScanResultsFromBssidStrings:(NSArray<NSString *> *)bssids` 重载**（内部转 C 字符串，规避生命周期问题）——或改造现有方法签名（需同步 Phase 2 既有调用点 `kWpsBssids`）。**优先新增重载，保持 kWpsBssids 路径兼容**（标注仍可用固定集兜底）。

- [ ] **步骤 3：静态自检**

- `#import "TRWpsTile.h"`（SimLocationController.mm 顶部）
- buildScanResultsFromBssidStrings 重载：头文件声明 + .mm 实现（内部复用现有循环逻辑，入参改 NSString 数组）
- `__typeof__` 风格（该文件 L124 注释：-std=c++20 下 typeof 不可用）
- kWpsBssids 路径保留（兜底/缓存未命中时）

- [ ] **步骤 4：Commit**

```bash
git add TrollVNC/src/SimLocationManager.h TrollVNC/src/SimLocationManager.mm TrollVNC/src/SimLocationController.mm
git commit -m "feat(device): daemon wifi 注入改动态反查——按当前坐标 tile 查 BSSID，轨迹移动 wifi 源跟随（buildScanResults 加 NSString 重载）"
```

---

### 任务 3：App 标注改用动态反查（轨迹跟随显示）

**文件：**
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m`

**背景**：现在 `handleWifiScanUpdate:` 模拟分支用固定 `kWpsBssids` 反查（坐标恒在杭州）。改为按模拟当前位置 tile 反查 BSSID → wloc 反查坐标 → 标注跟随。

- [ ] **步骤 1：读现有 handleWifiScanUpdate 模拟分支**

读 `TRMapPickerViewController.m` L438-483（handleWifiScanUpdate）、L485-490（refreshWifiAnnotation）、self.cur（模拟当前位置，GCJ-02）。

- [ ] **步骤 2：改造模拟分支为动态反查**

```objc
if (self.locating) {
    // 模拟开启：按模拟当前位置动态反查 BSSID（与 daemon 注入同源，轨迹跟随）
    CLLocationCoordinate2D curWGS = [CoordTransform gcj02ToWgs84:self.cur];
    if (curWGS.latitude != 0 || curWGS.longitude != 0) {
        __weak typeof(self) wSelf = self;
        [[TRWpsTile sharedClient] queryBssidsForCoordinate:curWGS force:NO completion:^(NSArray<TRWpsTileAP *> *aps, NSError *error) {
            __strong typeof(self) sSelf = wSelf;
            if (!sSelf || error || aps.count == 0) return; // 静默
            NSMutableArray *bssids = [NSMutableArray arrayWithCapacity:aps.count];
            for (TRWpsTileAP *ap in aps) [bssids addObject:ap.bssid];
            [sSelf _queryWifiAnnoWithBssids:bssids seq:seq]; // 复用下方反查+标注逻辑
        }];
        return; // 动态路径走完，不落固定 kWpsBssids
    }
    // fallback：cur 无效（未定位）→ 固定集（保持现状）
}
```

**注意**：抽一个 `_queryWifiAnnoWithBssids:seq:` 私有方法承载"wloc 反查 → 标签更新 → 标注更新"（原 completion 逻辑），动态/固定两条路径都调它，避免重复。**seq 竞态防护保留**（wifiQuerySeq 机制）。

- [ ] **步骤 3：静态自检**

- `#import "TRWpsTile.h"`（TRMapPickerViewController.m 顶部，WpsBssidData.h 旁）
- `_queryWifiAnnoWithBssids:seq:` 抽取不破坏原逻辑；kWpsBssids 兜底路径保留
- self.cur 是 GCJ-02 → gcj02ToWgs84 转换（已有 CoordTransform）

- [ ] **步骤 4：Commit**

```bash
git add TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m
git commit -m "feat(app): wifi 标注改动态反查——按模拟当前位置 tile 查 BSSID，标注随定位路径移动"
```

---

### 任务 4：pbxproj 注册 TRWpsTile（bootstrap 编译）

**文件：**
- 修改：`TrollVNC/app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj`

**背景**：任务 1 只加了 Makefile（daemon 侧）。App target 用 xcodebuild，**必须显式注册 TRWpsTile.h/.mm**（WpsBssidData.h 教训：隐式路径仅 theos 3 scheme 掩盖，bootstrap 报 file not found）。

- [ ] **步骤 1：读 pbxproj 现有 src/ 引用模式**

读 `TrollVNC/app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj` 的 CoordTransform.h/TRWpsClient.h 条目（FileRef `path = ../../../src/...` + group children + Sources phase），确认新 ID 段。

- [ ] **步骤 2：添加引用（仿 WpsBssidData.h 修复模式）**

```pbxproj
/* PBXFileReference section */
<ID1> /* TRWpsTile.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = ../../../src/TRWpsTile.h; sourceTree = "<group>"; };
<ID2> /* TRWpsTile.mm */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objcpp; path = ../../../src/TRWpsTile.mm; sourceTree = "<group>"; };

/* group children（CoordTransform.h 旁） */
<ID1> /* TRWpsTile.h */,
<ID2> /* TRWpsTile.mm */,

/* App target Sources phase（TRWpsClient.mm 旁） */
<ID3> /* TRWpsTile.mm in Sources */ = {isa = PBXBuildFile; fileRef = <ID2> /* TRWpsTile.mm */; };
```

**硬约束（AGENTS.md pbxproj 三坑）**：
- ID 24 位十六进制全表唯一（用 AA01000000000000000000B6 起的未用段）
- 含特殊字符 path 加引号（TRWpsTile 无特殊字符，裸写即可）
- 改完静态校验：括号配平 + 每行分号 + ID 唯一 + LF 无 CRLF（写 python 校验，同 WpsBssidData 修复）
- `git show HEAD:` 核对存储版 LF

- [ ] **步骤 3：Commit**

```bash
git add TrollVNC/app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj
git commit -m "fix(app): pbxproj 注册 TRWpsTile.h/.mm——App target 显式引用 src/ 头（bootstrap 编译必需）"
```

---

### 任务 5：文档同步 + 收尾

**文件：**
- 修改：`说明文档.md`

- [ ] **步骤 1：说明文档更新 §4.12**

补动态反查：TRWpsTile 坐标→BSSID（gspe tile），daemon 注入与 App 标注双消费；轨迹移动 wifi 源跟随；LRU 缓存；已知限制（tile 需设备联网访问 gspe-cn，真机可达性验证）。

- [ ] **步骤 2：确认无残留**

grep `kWpsBssids` 确认固定集仅作兜底（SimLocationManager buildScanResults 重载 + 标注 fallback）；无死代码。

- [ ] **步骤 3：Commit**

```bash
git add 说明文档.md
git commit -m "docs(device): 同步坐标→BSSID 动态反查（TRWpsTile，轨迹跟随）"
```

---

## 自检记录

- **规格覆盖度**：设计文档 §坐标→SSID 反查（动态+预取混合）→ 任务 1（动态查询 + LRU 缓存）+ 任务 2/3（消费方）；预取下一段 → 任务 2 步骤 2 注释提及（force 参数预留，完整预取留后续——本计划聚焦动态 + LRU）；目标 App 结论（wifi_bssid 上传）→ 任务 3 标注自洽。
- **占位符扫描**：无"待定/TODO"；`parseWifiTileData` 标注为任务 1 核心难点需完整实现（协议字段号已写全：Region=3/Device=2/bssid=5/entry=6/lat=1/lon=2，sfixed32/1e7，int64→MAC 大端低 6 字节）——这是明确实现要求，非占位符。
- **类型一致性**：`queryBssidsForCoordinate:force:completion:`（任务 1）签名在任务 2/3 消费一致；`buildScanResultsFromBssidStrings:` 重载（任务 2 新增）与 `_queryWifiAnnoWithBssids:seq:`（任务 3 抽取）签名各自一致；`TRWpsTileAP.bssid/coord`（任务 1）在任务 2/3 消费一致。
- **生命周期**：任务 2 的 `cArr` UTF8String 问题已在步骤 2 显式规避（新增 NSString 重载，不用 C 数组传 UTF8String）。
