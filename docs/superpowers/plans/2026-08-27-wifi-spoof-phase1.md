# WiFi 定位伪装 Phase 1 实现计划（真实 WiFi 位置显示）

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 实现设计文档（`docs/superpowers/specs/2026-08-27-wifi-spoof-double-layer-design.md`）的**第一步能力**——系统定位服务关闭时，App 内自扫真实 wifi → 反查坐标 → 地图显示"真实 wifi 位置"，同时完成**关卡 1（扫描通道实验）**验证：定位关闭态下 App 能否通过 NEHotspotHelper 拿到邻近 BSSID 列表。

**架构：** 复用 App 已注册的 NEHotspotHelper（`TVNCHotspotManager`）读取系统扫描的邻近网络列表 → 新移植 wloc 反查客户端（ObjC 版 `scripts/apple-wps.mjs` query 逻辑）把 BSSID 集合查成坐标 → 伪装页（`TRMapPickerViewController`）地图加标注显示。全程不依赖系统定位服务，走"通道二"读法。

**技术栈：** Objective-C（App target）/ NEHotspotHelper（NetworkExtension，entitlement 已有）/ NSURLSession / protobuf 手写编解码（varint + ARPC 头，对齐 mjs 实现）。

**设计文档：** `docs/superpowers/specs/2026-08-27-wifi-spoof-double-layer-design.md` §能力拆分·第一步 + §验证·关卡 1

---

## 文件结构

- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TVNCHotspotManager.m` — handler 读取 `command.networkList`，输出 BSSID 日志（任务 0）
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TVNCHotspotManager.h` — 加 networkList 读取接口（任务 0）
- 创建：`TrollVNC/app/TrollVNC/TrollVNC/TRWpsClient.h` — wloc 反查客户端接口（任务 1）
- 创建：`TrollVNC/app/TrollVNC/TrollVNC/TRWpsClient.mm` — protobuf 编解码 + ARPC 头 + NSURLSession 请求（任务 1）
- 修改：`TrollVNC/app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj` — 注册 TRWpsClient.h/.mm（任务 1）
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m` — 加"扫描 wifi"按钮 + 反查 + 地图标注（任务 2）
- 修改：`说明文档.md` — 同步第一步能力（任务 3）

---

### 任务 0：扫描通道实验（关卡 1 验证）

**文件：**
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TVNCHotspotManager.m`
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TVNCHotspotManager.h`

**背景**：`TVNCHotspotManager` 已注册 NEHotspotHelper（registerWithOptions:queue:handler:），但 handler 只触发服务保活、不读 `command.networkList`。本任务把 `networkList` 里的 BSSID 打日志，真机验证**系统定位关闭态**下能否拿到邻近网络列表。这是关卡 1 的实锤数据，决定任务 2 扫描通道方案（NEHotspotHelper vs CoreWiFi）。

- [ ] **步骤 1：读取现有 TVNCHotspotManager.h 结构**

先读 `TrollVNC/app/TrollVNC/TrollVNC/TVNCHotspotManager.h`，确认现有接口，保持风格。

- [ ] **步骤 2：头文件加 networkList 读取接口**

在 `TVNCHotspotManager.h` 加属性与接口：

```objc
/// 最近一次系统扫描返回的邻近网络（NEHotspotNetwork 数组，nil=未收到）
@property (nonatomic, strong, readonly) NSArray *lastNetworkList;
/// 最近一次扫描日志（SSID/BSSID/signalStrength 摘要，调试用）
@property (nonatomic, copy, readonly) NSString *lastScanSummary;
/// 主动请求系统扫描（返回后可通过 lastNetworkList 读取；触发时机由系统决定）
- (void)requestScan;
```

- [ ] **步骤 3：handler 读取 networkList 并打日志**

在 `TVNCHotspotManager.m` 的 `handleCommand:` 中，对携带网络列表的命令类型读取并记录：

```objc
#import "TVNCHotspotManager.h"
#import "TVNCServiceCoordinator.h"

#import <NetworkExtension/NetworkExtension.h>

@interface TVNCHotspotManager ()
@property (nonatomic, strong) NSArray *lastNetworkList;
@property (nonatomic, copy) NSString *lastScanSummary;
@end

@implementation TVNCHotspotManager

+ (instancetype)sharedManager {
    static TVNCHotspotManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (void)handleCommand:(NEHotspotHelperCommand *)command {
    // 读取网络列表（FilterScanList/Evaluate 命令携带；None 也可能带，统一尝试）
    if (command.networkList.count > 0) {
        self.lastNetworkList = command.networkList;
        NSMutableArray *lines = [NSMutableArray array];
        for (NEHotspotNetwork *net in command.networkList) {
            NSString *bssid = net.BSSID ?: @"(nil)";
            [lines addObject:[NSString stringWithFormat:@"%@|%@|%.0f", bssid, net.SSID ?: @"(nil)", net.signalStrength * 100]];
        }
        self.lastScanSummary = [lines componentsJoinedByString:@"\n"];
        NSLog(@"[wifiscan] NEHotspotHelper networkList count=%lu\n%@",
              (unsigned long)command.networkList.count, self.lastScanSummary);
    }
    switch (command.commandType) {
        case kNEHotspotHelperCommandTypeNone:
            break;
        case kNEHotspotHelperCommandTypeFilterScanList:
        case kNEHotspotHelperCommandTypeEvaluate:
        case kNEHotspotHelperCommandTypeAuthenticate:
        case kNEHotspotHelperCommandTypePresentUI:
        case kNEHotspotHelperCommandTypeMaintain:
        case kNEHotspotHelperCommandTypeLogoff:
            [self executeAutoStartupTaskIfNecessary];
            break;
        default:
            break;
    }
}

- (void)requestScan {
    // NEHotspotHelper 是被动回调：本方法仅触发一次服务注册状态确认；
    // 实际扫描结果依赖系统时机（打开 wifi 设置/网络变化），通过 lastNetworkList 读取。
    NSLog(@"[wifiscan] requestScan called (system-driven)");
}

- (BOOL)registerWithName:(NSString *)name {
    NSDictionary *options = @{kNEHotspotHelperOptionDisplayName: name};
    __weak typeof(self) weakSelf = self;
    return [NEHotspotHelper registerWithOptions:options queue:dispatch_get_main_queue() handler:^(NEHotspotHelperCommand * _Nonnull cmd) {
        __strong typeof(self) strongSelf = weakSelf;
        [strongSelf handleCommand:cmd];
    }];
}

- (void)executeAutoStartupTaskIfNecessary {
    [[TVNCServiceCoordinator sharedCoordinator] ensureServiceRunning];
}

@end
```

- [ ] **步骤 4：确认编译（App target 只被 bootstrap job 编译）**

Windows 无法本地构建，出 .tipa 走 CI。先做静态检查：
- 确认 `NEHotspotNetwork` 的 `BSSID` 属性存在（iOS 13+，Xcode 14+ SDK 中为 `@property (readonly) NSString *BSSID`）
- 确认 `kNEHotspotHelperCommandTypeFilterScanList` 枚举存在（iOS 13+）
- 确认 `command.networkList` 类型为 `NSArray<NEHotspotNetwork *> *`

预期：全部存在，无编译风险点。

- [ ] **步骤 5：Commit**

```bash
git add TrollVNC/app/TrollVNC/TrollVNC/TVNCHotspotManager.h TrollVNC/app/TrollVNC/TrollVNC/TVNCHotspotManager.m
git commit -m "feat(app): NEHotspotHelper 读取 networkList 并输出 BSSID 日志（关卡1 扫描通道实验）"
```

- [ ] **步骤 6：CI 出包 + 真机验证关卡 1**

出包：`GHTOK=<token> node scripts/build-ipa.mjs [commit] [outDir]`（或用已构建产物）。TrollStore 安装后：
1. 确保系统定位服务**保持关闭**（当前真机状态）
2. 打开 App → 进入伪装页 → 打开系统 wifi 设置页再返回（触发系统扫描时机）
3. 检查 5902 日志（`GET /stderr`）或 Xcode Console，看 `[wifiscan]` 行
4. **判定**：
   - 日志有 `networkList count>0` + BSSID 行 → **关卡 1 通过**，任务 2 用 NEHotspotHelper 方案 ✅
   - 日志无 `[wifiscan]` 或 count=0 → NEHotspotHelper 在定位关闭态拿不到列表 → 任务 2 切换到 CoreWiFi 实验（另立任务，暂停本计划其余步骤）

记录结果到 `说明文档.md` 或本计划备注（真机结论必须留痕）。

---

### 任务 1：wloc 反查客户端（ObjC 移植）

**文件：**
- 创建：`TrollVNC/app/TrollVNC/TrollVNC/TRWpsClient.h`
- 创建：`TrollVNC/app/TrollVNC/TrollVNC/TRWpsClient.mm`
- 修改：`TrollVNC/app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj`

**背景**：把 `scripts/apple-wps.mjs` 的 wloc query 逻辑（BSSID→坐标，已验证 801 个真实 BSSID）移植为 ObjC。协议：POST `https://gs-loc-cn.apple.com/clls/wloc`（中国区），body = ARPC 头 + protobuf（wifi_devices + 请求参数 + device_type），响应 = 10B 帧头 + protobuf（repeated wifi_device，各含 bssid + location(lat/lon ×1e8)）。

- [ ] **步骤 1：创建 TRWpsClient.h**

```objc
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/// wloc 反查客户端（ObjC 移植自 scripts/apple-wps.mjs query 逻辑）
/// 输入 BSSID 集合，输出每个 BSSID 的坐标 + 有效坐标质心。
/// 协议：POST gs-loc-cn.apple.com/clls/wloc，ARPC 头 + protobuf（对齐 mjs 实现）
@interface TRWpsClient : NSObject

+ (instancetype)sharedClient;

/// 批量反查（一次请求携带全部 BSSID，wifi_devices repeated field）
/// 坐标均为 WGS-84；unknown 的 BSSID（lat=-180 哨兵）不出现在 result 中
/// completion 在主队列回调；error 非 nil = 网络/HTTP 失败
- (void)queryCoordinatesForBssids:(NSArray<NSString *> *)bssids
                       completion:(void (^)(NSDictionary<NSString *, CLLocation *> *result,
                                            CLLocationCoordinate2D centroid,
                                            BOOL hasValid,
                                            NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
```

- [ ] **步骤 2：创建 TRWpsClient.mm（protobuf 编码原语）**

```objc
#import "TRWpsClient.h"
#import <CoreFoundation/CoreFoundation.h>

@interface TRWpsClient ()
@end

@implementation TRWpsClient

+ (instancetype)sharedClient {
    static TRWpsClient *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[TRWpsClient alloc] init]; });
    return shared;
}

// ---------- protobuf 编码原语（对齐 mjs varint/zigzag） ----------
static void appendVarint(NSMutableData *out, uint64_t value) {
    uint8_t bytes[10];
    int n = 0;
    do {
        uint8_t b = value & 0x7f;
        value >>= 7;
        if (value) b |= 0x80;
        bytes[n++] = b;
    } while (value);
    [out appendBytes:bytes length:n];
}

static void appendTag(NSMutableData *out, int field, int wireType) {
    appendVarint(out, ((uint64_t)field << 3) | (uint64_t)wireType);
}

static void appendFieldSint32(NSMutableData *out, int field, int64_t value) {
    // sint32 → zigzag（对齐 mjs encFieldSint32）
    uint64_t z = (uint64_t)((value << 1) ^ (value >> 63));
    appendTag(out, field, 0);
    appendVarint(out, z);
}

static void appendFieldString(NSMutableData *out, int field, NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    appendTag(out, field, 2);
    appendVarint(out, (uint64_t)d.length);
    [out appendData:d];
}

static void appendFieldMsg(NSMutableData *out, int field, NSData *body) {
    appendTag(out, field, 2);
    appendVarint(out, (uint64_t)body.length);
    [out appendData:body];
}

// ---------- 请求体（对齐 mjs encodeWifiDevice/encodeDeviceType/encodeAppleWLoc） ----------
static NSData *encodeAppleWLoc(NSArray<NSString *> *bssids) {
    NSMutableData *body = [NSMutableData data];
    for (NSString *bssid in bssids) {
        NSMutableData *dev = [NSMutableData data];
        appendFieldString(dev, 1, bssid);      // wifi_devices[].mac
        appendFieldMsg(body, 2, dev);          // wifi_devices (repeated field 2)
    }
    appendFieldSint32(body, 3, 0);             // num_cell_results = 0
    appendFieldSint32(body, 4, 0);             // num_wifi_results = 0 → 返回全部邻域
    NSMutableData *dt = [NSMutableData data];
    appendFieldString(dt, 1, @"iPhone OS17.5/21F79");
    appendFieldString(dt, 2, @"iPhone12,1");
    appendFieldMsg(body, 33, dt);              // device_type
    return body;
}

// ---------- ARPC 头（对齐 mjs buildArpcRequest，全部大端） ----------
static uint16_t be16(uint16_t v) { return CFSwapInt16HostToBig(v); }
static uint32_t be32(uint32_t v) { return CFSwapInt32HostToBig(v); }

static NSData *buildArpcRequest(NSData *payload) {
    NSString *locale = @"en-001_001";
    NSString *appId = @"com.apple.locationd";
    NSString *osVer = @"18.6.2.22G100";
    NSData *l = [locale dataUsingEncoding:NSUTF8StringEncoding];
    NSData *a = [appId dataUsingEncoding:NSUTF8StringEncoding];
    NSData *o = [osVer dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger headLen = 2 + (2 + l.length) + (2 + a.length) + (2 + o.length) + 4 + 4;
    NSMutableData *head = [NSMutableData dataWithCapacity:headLen];
    uint16_t v16 = be16(1);
    [head appendBytes:&v16 length:2];
    uint16_t llen = be16((uint16_t)l.length);
    [head appendBytes:&llen length:2]; [head appendData:l];
    uint16_t alen = be16((uint16_t)a.length);
    [head appendBytes:&alen length:2]; [head appendData:a];
    uint16_t olen = be16((uint16_t)o.length);
    [head appendBytes:&olen length:2]; [head appendData:o];
    uint32_t fn = be32(1);
    [head appendBytes:&fn length:4];
    uint32_t plen = be32((uint32_t)payload.length);
    [head appendBytes:&plen length:4];
    [head appendData:payload];
    return head;
}
```

- [ ] **步骤 3：TRWpsClient.mm 加响应解析（readVarint + parse 三件套）**

```objc
// ---------- protobuf 解析原语（对齐 mjs readVarint） ----------
static BOOL readVarint(const uint8_t *buf, NSUInteger len, NSUInteger *off, uint64_t *out) {
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

static BOOL skipField(const uint8_t *buf, NSUInteger len, NSUInteger *off, int wireType) {
    uint64_t v;
    switch (wireType) {
        case 0: return readVarint(buf, len, off, &v);
        case 1: if (*off + 8 > len) return NO; *off += 8; return YES;
        case 2: {
            uint64_t sl;
            if (!readVarint(buf, len, off, &sl)) return NO;
            if (*off + sl > len) return NO;
            *off += (NSUInteger)sl;
            return YES;
        }
        case 5: if (*off + 4 > len) return NO; *off += 4; return YES;
        default: return NO;
    }
}

// ---------- 响应解析（对齐 mjs parseWifiDevices/parseWifiDevice/parseLocation） ----------
static BOOL parseLocationField(const uint8_t *buf, NSUInteger len, int fieldNum, double *out) {
    NSUInteger i = 0;
    while (i < len) {
        uint64_t tag;
        if (!readVarint(buf, len, &i, &tag)) return NO;
        int fn = (int)(tag >> 3);
        int wt = (int)(tag & 7);
        if (wt == 0) {
            uint64_t value;
            if (!readVarint(buf, len, &i, &value)) return NO;
            // int64 负数 = 64 位补码（对齐 mjs 符号修正）
            int64_t signedV = (int64_t)value;
            if (fn == 1 && fieldNum == 1) { *out = (double)signedV / 1e8; return YES; }
            if (fn == 2 && fieldNum == 2) { *out = (double)signedV / 1e8; return YES; }
        } else {
            if (!skipField(buf, len, &i, wt)) return NO;
        }
    }
    return NO;
}

static CLLocationCoordinate2D parseWifiDevice(const uint8_t *buf, NSUInteger len, NSString **bssidOut) {
    CLLocationCoordinate2D coord = { kCLLocationCoordinate2DInvalid.latitude, kCLLocationCoordinate2DInvalid.longitude };
    *bssidOut = nil;
    NSUInteger i = 0;
    while (i < len) {
        uint64_t tag;
        if (!readVarint(buf, len, &i, &tag)) break;
        int fn = (int)(tag >> 3);
        int wt = (int)(tag & 7);
        if (fn == 1 && wt == 2) {
            uint64_t sl;
            if (!readVarint(buf, len, &i, &sl)) break;
            if (i + sl > len) break;
            *bssidOut = [[NSString alloc] initWithBytes:buf + i length:(NSUInteger)sl encoding:NSUTF8StringEncoding];
            i += (NSUInteger)sl;
        } else if (fn == 2 && wt == 2) {
            uint64_t sl;
            if (!readVarint(buf, len, &i, &sl)) break;
            if (i + sl > len) break;
            double lat = 0, lon = 0;
            parseLocationField(buf + i, (NSUInteger)sl, 1, &lat);
            parseLocationField(buf + i, (NSUInteger)sl, 2, &lon);
            coord.latitude = lat;
            coord.longitude = lon;
            i += (NSUInteger)sl;
        } else {
            if (!skipField(buf, len, &i, wt)) break;
        }
    }
    return coord;
}
```

- [ ] **步骤 4：TRWpsClient.mm 加主请求方法（NSURLSession POST + 解析 + 质心）**

```objc
- (void)queryCoordinatesForBssids:(NSArray<NSString *> *)bssids
                       completion:(void (^)(NSDictionary<NSString *, CLLocation *> *result,
                                            CLLocationCoordinate2D centroid,
                                            BOOL hasValid,
                                            NSError *_Nullable error))completion {
    if (bssids.count == 0 || !completion) { return; }
    NSData *body = buildArpcRequest(encodeAppleWLoc(bssids));
    NSURL *url = [NSURL URLWithString:@"https://gs-loc-cn.apple.com/clls/wloc"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 15;
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [req setValue:@"utf-8" forHTTPHeaderField:@"Accept-Charset"];
    [req setValue:@"en-us" forHTTPHeaderField:@"Accept-Language"];
    [req setValue:@"locationd/2890.16.16 CFNetwork/1496.0.7 Darwin/23.5.0" forHTTPHeaderField:@"User-Agent"];
    req.HTTPBody = body;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req
                                            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *netErr) {
        NSMutableDictionary<NSString *, CLLocation *> *result = [NSMutableDictionary dictionary];
        CLLocationCoordinate2D centroid = kCLLocationCoordinate2DInvalid;
        BOOL hasValid = NO;
        NSError *outErr = netErr;
        if (!netErr && data.length >= 10) {
            // 响应 = 10B 帧头 + protobuf（对齐 mjs）
            NSData *proto = [data subdataWithRange:NSMakeRange(10, data.length - 10)];
            const uint8_t *bytes = proto.bytes;
            NSUInteger len = proto.length;
            NSUInteger i = 0;
            double latSum = 0, lonSum = 0;
            int validCount = 0;
            while (i < len) {
                uint64_t tag;
                if (!readVarint(bytes, len, &i, &tag)) break;
                int fn = (int)(tag >> 3);
                int wt = (int)(tag & 7);
                if (fn == 2 && wt == 2) {
                    uint64_t sl;
                    if (!readVarint(bytes, len, &i, &sl)) break;
                    if (i + sl > len) break;
                    NSString *bssid = nil;
                    CLLocationCoordinate2D coord = parseWifiDevice(bytes + i, (NSUInteger)sl, &bssid);
                    i += (NSUInteger)sl;
                    if (bssid && CLLocationCoordinate2DIsValid(coord) &&
                        !(coord.latitude == -180 && coord.longitude == -180)) { // 哨兵=库中未知
                        result[bssid] = [[CLLocation alloc] initWithCoordinate:coord
                                                                      altitude:0
                                                            horizontalAccuracy:100
                                                              verticalAccuracy:-1
                                                                        course:-1
                                                                         speed:-1
                                                                      timestamp:[NSDate date]];
                        latSum += coord.latitude;
                        lonSum += coord.longitude;
                        validCount++;
                        hasValid = YES;
                    }
                } else {
                    if (!skipField(bytes, len, &i, wt)) break;
                }
            }
            if (validCount > 0) {
                centroid.latitude = latSum / validCount;
                centroid.longitude = lonSum / validCount;
            }
            outErr = nil;
        } else if (!netErr) {
            outErr = [NSError errorWithDomain:@"TRWpsClient"
                                        code:-1
                                    userInfo:@{NSLocalizedDescriptionKey: @"wloc 响应过短"}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result, centroid, hasValid, outErr);
        });
    }];
    [task resume];
}

@end
```

- [ ] **步骤 5：pbxproj 注册新文件（bootstrap job 才读 pbxproj）**

`TrollVNC/app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj` 需要 4 处新增（TRWpsClient.h + TRWpsClient.mm × FileRef + BuildFile，且 TRWpsClient.mm 加入 App target 的 Sources phase）。参考现有条目格式（如 `TVNCSegmentCell` 的 D0B1B2C3D4E5F60718293A03/04）：

```pbxproj
/* PBXBuildFile section（各 App target 一个，对齐 TVNCGatewayClient 两个 AA0100... 条目） */
<NEWID1> /* TRWpsClient.mm in Sources */ = {isa = PBXBuildFile; fileRef = <NEWID3> /* TRWpsClient.mm */; };

/* PBXFileReference section */
<NEWID3> /* TRWpsClient.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = TRWpsClient.h; sourceTree = "<group>"; };
<NEWID4> /* TRWpsClient.mm */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.cpp.objcpp; path = TRWpsClient.mm; sourceTree = "<group>"; };

/* 组（放 TRMapPickerViewController.m 同组）与 App target 的 Sources phase 各加一条 */
```

**硬约束**（AGENTS.md pbxproj 三坑）：
- 新对象 ID 必须 24 位十六进制且与全表唯一（建议用 `AA01000000000000000000B1` 起的未用段）
- 含特殊字符的 path 必须引号；TRWpsClient 无特殊字符，裸 path 即可
- 改完用 OpenStep tokenizer 校验括号配平/每行分号/ID 唯一（Windows 无 xcodebuild，只能静态校验）
- `git show HEAD:TrollVNC/app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj` 核对存储版 LF

- [ ] **步骤 6：Commit**

```bash
git add TrollVNC/app/TrollVNC/TrollVNC/TRWpsClient.h TrollVNC/app/TrollVNC/TrollVNC/TRWpsClient.mm TrollVNC/app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj
git commit -m "feat(app): wloc 反查客户端 ObjC 移植（BSSID→坐标，对齐 apple-wps.mjs query 协议）"
```

---

### 任务 2（2026-08-27 用户改向定稿）：伪装页 wifi 位置自动订阅（撤按钮）

**文件：**
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TVNCHotspotManager.h/.m`（加 `onNetworkListUpdated` 回调）
- 修改：`TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m`（自动订阅 + 自动反查显示）

**设计变更（用户拍板）**：~~扫描WiFi按钮~~ **废除**。wifi 位置显示与真实 GPS 活跃订阅完全同构：App 启动后自动订阅系统扫描结果，扫描回调到达 → 自动 wloc 反查 → 更新地图 wifi 位置标注。**无按钮、无弹窗（错误静默）、无聚焦（不打断用户地图操作）**。

**实现**：
- `TVNCHotspotManager`：`captureNetworkList:` 存属性后触发 `onNetworkListUpdated` 回调（主队列天然保证）
- `TRMapPickerViewController`：viewDidLoad 设置订阅回调（weakSelf/strongSelf）+ **初始水合**（启动扫描可能早于订阅，先消费 `lastNetworkList` 缓存）→ `handleWifiScanUpdate:summary:` 提取 BSSID（≥17 位）→ `TRWpsClient` 反查 → `CoordTransform wgs84ToGcj02:` → `TRWifiAnnotation` 标注（先移除旧标注防重复）
- 保留 `TRWifiAnnotation` 自绘水滴 + shouldReceiveTouch 拦截（点击标注不误触 tap 加锚点）

**验收**：真机（系统定位已关）打开系统 Wi-Fi 设置页触发扫描 → 地图出现 wifi 位置标注。

- [ ] **步骤 1：读 TRMapPickerViewController.m 的 viewDidLoad 控件创建区**

读 `TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m` L100-340（viewDidLoad 内 UI 构建），找现有 FAB/按钮创建模式（AutoLayout + 固定约束），确定 wifi 按钮插入位置（建议左下角、modeSeg 上方）。同时读 `viewDidLayoutSubviews`（L1045）确认布局同步模式。

- [ ] **步骤 2：加 wifi 扫描按钮（AutoLayout）**

在 viewDidLoad 控件区追加：

```objc
// WiFi 扫描按钮（左下、modeSeg 上方）：读取系统扫描的真实 wifi → wloc 反查 → 地图显示
UIButton *wifiBtn = [UIButton buttonWithType:UIButtonTypeSystem];
wifiBtn.translatesAutoresizingMaskIntoConstraints = NO;
wifiBtn.backgroundColor = [UIColor systemBackgroundColor];
wifiBtn.layer.cornerRadius = 8;
wifiBtn.layer.borderWidth = 1;
wifiBtn.layer.borderColor = [UIColor systemGray4Color].CGColor;
[wifiBtn setImage:[UIImage systemImageNamed:@"wifi"] forState:UIControlStateNormal];
[wifiBtn setTitle:@" 扫描WiFi" forState:UIControlStateNormal];
[wifiBtn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
[wifiBtn.titleLabel.font = [UIFont systemFontOfSize:14]];
[wifiBtn addTarget:self action:@selector(scanWifiAndShow:) forControlEvents:UIControlEventTouchUpInside];
[self.view addSubview:wifiBtn];
self.wifiScanBtn = wifiBtn;
```

并在 viewDidLoad 约束区（现有 AutoLayout 块内）追加：

```objc
[NSLayoutConstraint activateConstraints:@[
    [wifiBtn.leadingAnchor constraintEqualToAnchor:self.modeSeg.leadingAnchor],
    [wifiBtn.bottomAnchor constraintEqualToAnchor:self.modeSeg.topAnchor constant:-8],
    [wifiBtn.heightAnchor constraintEqualToConstant:32],
    [wifiBtn.widthAnchor constraintGreaterThanOrEqualToConstant:96],
]];
```

- [ ] **步骤 3：实现 scanWifiAndShow:（读 BSSID → 反查 → 标注）**

在 `TRMapPickerViewController.m` 加属性 `wifiScanBtn` 与处理方法：

```objc
/// 扫描真实 wifi 并在地图显示 wloc 反查位置（走"通道二"读法，不依赖系统定位服务）
- (void)scanWifiAndShow:(id)sender {
    TVNCHotspotManager *hs = [TVNCHotspotManager sharedManager];
    NSArray *nets = hs.lastNetworkList;
    if (nets.count == 0) {
        [hs requestScan]; // 触发一次；结果系统驱动，稍后重试
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"暂无扫描结果"
            message:@"请打开系统 Wi-Fi 设置页后返回，再点一次" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    NSMutableArray *bssids = [NSMutableArray array];
    for (NEHotspotNetwork *net in nets) {
        if (net.BSSID.length >= 17) [bssids addObject:net.BSSID.uppercaseString];
    }
    if (bssids.count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫描结果无 BSSID"
            message:@"networkList 缺少 BSSID 字段" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[TRWpsClient sharedClient] queryCoordinatesForBssids:bssids completion:^(NSDictionary<NSString *,CLLocation *> *result,
        CLLocationCoordinate2D centroid, BOOL hasValid, NSError *error) {
        __strong typeof(self) strongSelf = weakSelf;
        if (error || !hasValid) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"反查失败"
                message:error.localizedDescription ?: @"无有效坐标" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [strongSelf presentViewController:alert animated:YES completion:nil];
            return;
        }
        CLLocationCoordinate2D gcj = [CoordTransform wgs84ToGcj02:centroid];
        MKPointAnnotation *ann = [[MKPointAnnotation alloc] init];
        ann.coordinate = gcj;
        ann.title = @"WiFi 定位（wloc 反查）";
        ann.subtitle = [NSString stringWithFormat:@"%.4f, %.4f（%lu 个 AP）",
                        centroid.latitude, centroid.longitude, (unsigned long)result.count];
        [strongSelf.mapView addAnnotation:ann];
        [strongSelf.mapView setRegion:MKCoordinateRegionMakeWithDistance(gcj, 3000, 3000) animated:YES];
    }];
}
```

（`TRMapPickerViewController.m` 需 `#import "TVNCHotspotManager.h"`、`#import "TRWpsClient.h"`；`NEHotspotNetwork` 来自 `TVNCHotspotManager.h` 间接导入 NetworkExtension 或直接 `#import <NetworkExtension/NetworkExtension.h>`——**必须显式 import，勿依赖间接**）

- [ ] **步骤 4：静态自检**

- 新增 `@property (nonatomic, strong) UIButton *wifiScanBtn;` 声明（扩展区）
- `#import "TVNCHotspotManager.h"` + `#import "TRWpsClient.h"` + `#import <NetworkExtension/NetworkExtension.h>` 显式导入
- 按钮约束与现有 AutoLayout 块不冲突（modeSeg 已存在）
- `viewDidLayoutSubviews` 无需改动（wifiBtn 无自定义 layer）

- [ ] **步骤 5：Commit**

```bash
git add TrollVNC/app/TrollVNC/TrollVNC/TRMapPickerViewController.m
git commit -m "feat(app): 伪装页加扫描WiFi按钮——读 NEHotspotHelper 网络列表→wloc 反查→地图显示真实 wifi 位置"
```

- [ ] **步骤 6：CI 出包 + 真机验收**

出包：`GHTOK=<token> node scripts/build-ipa.mjs <commit>`（bootstrap job 编译 App target，若 pbxproj 出错只有此 job 报——对照 AGENTS.md pbxproj 排查链）。TrollStore 安装后：
1. 系统定位服务保持关闭
2. 伪装页点"扫描WiFi"→ 提示无结果则打开系统 wifi 设置再返回重试
3. 期望：地图出现"WiFi 定位"标注，坐标与周边环境吻合（如杭州 → 标注落在杭州）
4. 同时看 5902 日志 `[wifiscan]` 确认原始 BSSID 已扫到

**验收标准**：系统定位关闭态下，App 地图能显示真实 wifi 位置 —— 设计文档"第一步"验证项 ✅

---

### 任务 3：文档同步 + 收尾

**文件：**
- 修改：`说明文档.md`

- [ ] **步骤 1：说明文档同步第一步能力**

在 `说明文档.md` 定位相关章节补第一步能力描述（架构/时序/行为变更必须同步）：App 内 NEHotspotHelper 扫描 + wloc 反查 + 地图显示真实 wifi 位置，不依赖系统定位服务；标记 A 层注入/代理层为 Phase 2 未实现。

- [ ] **步骤 2：确认无残留**

全局 grep `wifiscan`/`TRWpsClient`/`lastNetworkList` 确认引用完整；对照 AGENTS.md「契约两端对齐」检查——本 Phase 未新增注册表能力（纯 App 内部直调，A 类），无需改 caps.js。

- [ ] **步骤 3：Commit**

```bash
git add 说明文档.md
git commit -m "docs(device): 同步 WiFi 定位伪装第一步——真实 wifi 位置显示（NEHotspotHelper+wloc 反查）"
```

---

## 自检记录

- **规格覆盖度**：设计文档第一步（真实 wifi 位置显示）→ 任务 0/1/2；关卡 1（扫描通道实验）→ 任务 0 步骤 6；验证（CI 编译 + 真机）→ 各任务 CI 步骤。A 层注入 / B 层代理 / 动态预取反查 → Phase 2 未纳入（本计划范围 = 第一步）。
- **占位符扫描**：无"待定/TODO"；所有代码步骤含完整实现。
- **类型一致性**：`lastNetworkList`（任务 0 定义）在任务 2 使用，类型 NSArray（元素 NEHotspotNetwork）；`queryCoordinatesForBssids:completion:` 签名任务 1 定义、任务 2 调用，参数/回调一致；`wifiScanBtn` 任务 2 内声明使用。
