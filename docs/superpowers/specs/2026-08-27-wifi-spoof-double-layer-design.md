# WiFi 定位伪装 · 双管线叠加设计

日期：2026-08-27
状态：已确认（用户拍板：双管线叠加模型 + 两步实现 + A/B 双层注入 + 动态/预取混合反查 +
B 层静态注入机制 + 三档私有直读检测）
关联愿景：跨网访问网关操作内网设备（B）/ 5801 不经过网关独立操作单台设备（C）
配套调研：`outputs/2026-08-27-WiFi定位伪装-POC设计.md`（POC 设计稿，含 A 层代码/取证清单/任务分解）

## 背景

风控 SDK 可能主动发起 WiFi 扫描 / 读取扫描结果。仅模拟 GPS 坐标时，App 直读系统拿到的
BSSID/SSID 仍是真实环境，坐标层与指纹层断裂 → 风控可判定模拟。需要让"风控可见的 WiFi 指纹"
与模拟坐标**自洽**。

物理层（airportd/内核 IO80211FamilyV2）**不可改**（TrollStore 能力边界：向系统进程注入需
TF_PLATFORM + PAC + PMAP，越狱级）。但风控 SDK 嵌在目标 App 进程内，看世界的唯一方式 =
"进程内发 API 调用"，不可能绕过 API 读 airportd 内存 → **进程内拦截 + locationd 服务层模拟，
即"风控体感上的全系统扫描源覆盖"**。

## App 获取 wifi 定位的两条通道（机制地基）

**通道一：公开 API（CLLocationManager）**

App 调 `startUpdatingLocation` → locationd 返回解算后的 `CLLocation` 对象。App 拿到的**已
是坐标**，看不到底层 wifi 指纹，只能读：`coordinate`（经纬度）/ `horizontalAccuracy`（精度，
wifi 定位一般 10–100m）/ `sourceInformation`（私有 API 可读来源 wifi/GPS/蜂窝）。风控走这条
通道读的是 **locationd 的结果**——这正是 A 层（`setWifiScanResults:`）能覆盖的原因：注入
locationd，解算坐标即变，所有走 CLLocationManager 的 App 全受影响。

**通道二：私有 API 直读（Apple80211 / CoreWiFi / CNCopyCurrentNetworkInfo）**

风控 SDK 可绕过 locationd 直连 airportd 拿**原始扫描结果**：`Apple80211Scan`（BSSID 列表含
RSSI/channel）、CoreWiFi `CWFInterface` 扫描、`CNCopyCurrentNetworkInfo`（当前连接 SSID/BSSID）。
App 拿到 BSSID 后**自己反查**地理库做交叉验证——这就是 B 层（netdisguise hook）要拦截的位置，
堵住"App 进程内发出的扫描 API 调用"。

**风控交叉验证（为什么两层缺一不可）**：风控 SDK 通常两条通道都读——通道一坐标应落在某城市、
通道二 BSSID 反查应落在同一城市，**两者不一致 → 判定模拟**。只模拟坐标（GPS）不够：坐标变了
但自己扫的 BSSID 还是真机 → 一对比就穿帮。**只有让两条通道数据自洽（都指向目标城市）才算
真正伪装成功**。

## 核心模型：双管线叠加（用户 v2 定稿）

GPS 模拟与 WiFi 模拟**不是二选一路由**，是同一套能力的两面，开启时**同时执行**：

| 管线 | 机制 | 作用层 |
|---|---|---|
| GPS 管线 | `appendSimulatedLocation:` | 喂 locationd 融合层（**结果层**） |
| WiFi 管线 | A 层 `setWifiScanResults:` + B 层进程内注入 | 喂扫描源层（**输入层**） |

两模拟不互斥（用户纠正定稿）：GPS 喂"结果"、wifi 喂"输入"，作用层不同叠加即自洽——开启
GPS 时系统仍可能扫 wifi，两层并发成立。**联动语义（用户确认）**：GPS 开启时 wifi 模拟若也开启
则同样工作，B 层代理随模拟定位总开关联动，代理所有调用系统 wifi 扫描的请求（GPS 管线 +
wifi 管线 + B 层代理同时生效）；关闭总开关则全部透传。关闭 GPS 模拟时只剩 wifi 管线在跑，
系统获得的位置即 wifi 定位结果。

**开关关系（用户拍板 2026-08-27）**：**总开关联动**——定位开关同时控制 GPS + wifi 双管线
（与 B 层代理联动语义一致），关闭时全部停止恢复真实；`SimLocationManager` 需提供总 stop
（GPS + wifi 一并停止），App 定位开关/状态条反映双管线状态。

**目标位置源（用户拍板 2026-08-27）**：**统一目标位置源**——用户选锚点/轨迹点时，同一目标
位置同时驱动 GPS 坐标注入（`injectPoint:`）+ wifi BSSID 集注入（`injectWifiScanResults:`，
该位置反查的 BSSID）。两条管线数据自洽由同一位置源保证。

## 能力拆分：两步实现

### 第一步（先实现）：真实 WiFi 位置显示

解决"系统定位服务已关闭 → 地图无位置"的现状（用户真机已关系统定位）。

```
App 自扫真实 wifi（NEHotspotHelper 优先，entitlement 已有）
  → 设备端反查坐标（移植 scripts/apple-wps.mjs query 逻辑 → ObjC）
  → 地图显示"真实 wifi 位置"（不依赖系统定位服务）
```

即"未开启模拟时获得的位置是真实的 wifi 位置"——把系统定位关闭状态下唯一可用的定位源
（wifi）变成 App 可视化。验证=当前真机（定位已关）地图能显示真实 wifi 位置。

### 第二步（后实现）：代理层

| 模拟状态 | 代理层行为 |
|---|---|
| 未开模拟 | **透传**真实 wifi 位置（真实扫描 → 真实反查 → 真实坐标） |
| 开模拟 | 模拟位置 → 反查该位置 SSID 集 → 作为 wifi 扫描列表注入（A+B 双层）→ 目标 App 反查得模拟坐标 |

**扫描列表随移动实时更新**：播放轨迹的每个坐标点都有对应 SSID 集，目标 App 在任何时刻反查
都落在模拟位置——"每个模拟的位置（出行路线经过的每个移动坐标）都需要其对应 SSID 对应"。

## 注入通道：A/B 双层（用户确认）

| 通道 | 机制 | 生效范围 |
|---|---|---|
| A 层（locationd 级） | `setWifiScanResults:` 喂 locationd | 系统定位开启时，所有 App 的 CLLocationManager wifi 定位全生效 |
| B 层（进程内代理） | netdisguise hook 目标 App 扫描/定位读取 | 目标 App 进程内，含风控私有扫描 |

注意：系统定位服务是全局开关，关闭后 locationd 可能不再广播任何位置（含模拟注入）——
"所有 app 生效"在定位关闭态可能只能靠 B 层逐个注入，或需系统定位保持开启。**该点为真机
验证项，直接决定 A/B 优先级**。

## 目标 App 分析结论（抖音 31.6.0 逆向，2026-08-27）

> 来源：抖音 iOS IPA 逆向报告（用户提供）。仅记录对本设计有直接影响的结论，其余设备指纹
> （IMEI/序列号/MobileGestalt）、传感器、VPN/代理检测、X-Gorgon 签名等与本设计无关，不记录。

### 结论 1：A 层是主战场——抖音位置读取全在公开通道

抖音定位全走 CLLocationManager：`startUpdatingLocation`/`requestLocation`/
`startMonitoringSignificantLocationChanges`/`allowsBackgroundLocationUpdates`/`CLGeocoder`
反地理编码——**全部经 locationd**。A 层（`setWifiScanResults:`）一旦生效，抖音绝大部分定位
读取被天然覆盖。验证"先 A 后 B、只补缺口"路线。

### 结论 2：B 层 hook 清单明确两个具体点

抖音读 wifi 用 `CNCopyCurrentNetworkInfo`（当前连接 SSID/BSSID，C 函数）+ `NEHotspotNetwork`
（邻近网络，ObjC）——与关卡 1 的 NEHotspotHelper 同源系统扫描。**B 层 hook 清单**：
- `CNCopyCurrentNetworkInfo`（+ `CNCopySupportedInterfaces`）→ fishhook `rebind_symbols` 返回注入数据
  **——必做（非建议）**：报告 §2.5/§5.11 确认抖音把 `wifi_ssid`/`wifi_bssid` **组装进请求参数上传**
  服务器（不是仅本地读）——服务器端可能拿当前连接 BSSID 反查位置与上报坐标交叉校验。hook 后
  抖音上传的即注入值，服务器反查落在模拟位置，自洽
- `NEHotspotNetwork` 读取 → ObjC swizzle
- **硬约束：保留现有 `_dyld_get_image_name`/`_dyld_image_count` 镜像隐藏 hook**（netdisguise.c
  已有，应对抖音"检测注入 dylib"类防御，加 wifi hook 时不得破坏）

**hook 共存风险（报告 §6.2.3/§9.1 新发现）**：抖音自带 BDFishhook（fishhook 封装库）且使用
`method_exchangeImplementations`（Method Swizzling）——我们 B 层注入也用 fishhook，**双方都在
改符号绑定/方法实现**。netdisguise 必须：①保留原始 IMP 链（已有 `nd_orig_*` 模式）；②若抖音先
hook 了某符号、我们后 rebind，`rebind_symbols` 会拿到抖音的 wrapper 而非原始指针——需按 hook
链顺序设计（Phase 3 实现时写进计划）。

### 结论 3：A 层注入参数补 accuracy 规范

抖音读 `horizontalAccuracy`（报告 §3.2：`kCLLocationAccuracyBest` 最高精度；§3.3 读
latitude/longitude/horizontalAccuracy/altitude/floor/speed/course 全字段）。模拟坐标的 accuracy
必须与定位源匹配：**wifi 源给 10–100m、GPS 源给 5–30m**，禁止"wifi 源却 5m 精度"的矛盾值
（风控读精度即可判异常）。A 层注入走 `injectPoint:accuracy:` 时按管线给对应精度。

**补充验证点（报告 §3.3 新发现）**：抖音读 `CLLocation.floor`（楼层）——我们注入的 CLLocation
未设 floor（nil），室内场景风控可能读它；低优先级，真机观察后决定是否补。

### 结论 4：局域网设备发现实锤（独立第三维度，维持不覆盖）

抖音 `NSBonjourServices` 声明 `_ttnet._tcp`/`_leboremote._tcp`/`_bdlink._tcp`/
`_check_local_network_permission._tcp.`/`_searchPad._tcp` + `NSNetServiceBrowser`/
`MCNearbyServiceBrowser`/`NWBrowser` 全套局域网发现——LAN fingerprinting 实锤，与本设计 wifi
指纹维度无关，维持"不覆盖"（网关/拓扑难伪造）。特征串记录供实测参考。

### 结论 5：检测方法修正——档位 0 静态分析有局限（报告 §6.2.1 新发现）

抖音用 `NSClassFromString` + `performSelector:` 动态调 API、`dlopen`/`dlsym` 动态加载私有
框架——**strings 静态查符号可能漏检动态调用的私有 API**。三档检测中**档位 0（静态分析）对
抖音可能失效**（查不到 ≠ 未用私有扫描），**必须以档位 1（注入观测探针）实测为准**。

### 结论 6：网络变化重读验证点（报告 §6.3/§7.4 新发现）

抖音监听 `com.apple.system.config.network_change` Darwin 通知，**网络切换时重读并上报**。
验证 wifi 注入的**持续性**：网络切换/重扫后注入是否仍生效（A 层与 B 层都要验证——网络变化是
风控重取指纹的天然触发点）。

## B 层注入机制（进程内怎么实现，用户确认）

**不是跨进程管理**：iOS 无跨进程内存注入能力（运行时 hook 别的 App 需越狱级 task_for_pid +
tfp0，TrollStore 做不到）。路径 = **文件系统级静态注入 + 重启生效**：

```
App 伪装页 → trollvncserver → spawn injectctl
  → kill 目标 app（先杀进程）
  → persona/root_wrapper 提权到 uid0
  → 把 netdisguise.dylib 拷进目标 app bundle
  → insert_dylib 修改主二进制，加 LC_LOAD_DYLIB
  → ldid 重签 + chown 33:33
  → 启动 app → 进程加载 dylib → hook 生效
```

基建已有（2026-08-26 蜂窝伪装 POC 遗留，[Makefile](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/Makefile#L177-L194) 已纳入）：
- `netdisguise/injectctl.mm`：注入编排（kill → root → copy dylib → insert_dylib → 重签 →
  chown → 启动），提权走 persona uid0 或 TrollStore 官方 root_wrapper
- `netdisguise/insert_dylib/main.c`：Mach-O 注入器
- `netdisguise/netdisguise.c`：拦截库本体，现有 hook 蜂窝伪装（SCNetworkReachabilityGetFlags/
  NWPath swizzle）+ 痕迹隐藏（SecStaticCode 伪签）；**wifi 扫描 hook 是本次新增**

**B 层注入边界（两条硬线）**：
1. **只能注入"二进制可写"的目标 app**：App Store 下载的加密 app（FairPlay DRM）不能
   insert_dylib，注入不了。目标 app 须自签名/TrollStore 安装（内测包、企业包）——内网群控
   场景目标基本是此类，可行；但这条线必须清醒。
2. **注入是重启生效**：改的是磁盘上二进制，目标 app 下次启动才加载 dylib，不能对运行中的
   app 热注入。

**不注入的替代方案（可行性结论）**：
- **A 层强化覆盖公开通道**：多数风控 SDK 走 CLLocationManager（要系统授权 + accuracy 字段），
  这条无需注入即可覆盖，是"不注入"的主路径——**先做 A 层成本最低、见效最广**
- **私有直读无替代**：通道二本质是目标 App 进程内直连 airportd，数据不经过 locationd、无任何
  系统服务层可拦截——要改只有进程内注入（B 层），或接受这路露真实
- **半替代（VPN 域名重定向）不作主线**：改写 SDK 联网反查请求返回模拟坐标，硬伤——只对
  "联网反查"的 SDK 有效（本地内置库无效）+ HTTPS 证书固定直接阻断，且我们在 BSSID 层已给
  数据，无需网络层二次拦截
- **务实路线**：先 A 层（不注入），用阶段 1 对照表实测暴露缺口，再决定 B 层值不值得做

## 数据源自洽性

A、B 两层返回的都是 `scripts/apple-wps.mjs`（tile/query/expand 实测）的目标城市**真实 BSSID**
（801 个，distKm 1.45–1.97km 自洽验证通过）。因此：

- locationd 拿这些 BSSID 查 wloc → 目标城市真实坐标 → 与 GPS 模拟坐标天然一致
- App 主动扫描读到这些 BSSID → 反查地理库 → 仍目标城市
- 两个感知层坐标对得上 → 风控判定自洽

## 坐标→SSID 反查：动态 + 预取混合（用户确认）

- **动态**：设备端按当前模拟坐标实时反查 gspe tile 端点（移植 `tile` 逻辑 → ObjC），
  任意位置可查、无 PC 依赖
- **LRU 缓存**：已查区域复用，避免同区域重复请求（兼顾频率控制防风控检测）
- **预取**：播放时提前取下一段路线的 SSID 集，避免播放卡顿

## 验证

### 检测目标 app 是否有私有直读（三档方法，用户确认）

档位 0（最便宜，静态分析二进制）：目标 app 是自签名 IPA 时解包查符号——
`otool -L 目标app | grep -iE "Apple80211|CoreWiFi|MobileWiFi"`、
`strings 目标app | grep -iE "Apple80211Scan|CWFInterface|CNCopyCurrentNetworkInfo"`。
命中即实锤链接私有框架；没命中大概率只走公开 API。

档位 1（最准，注入观测探针）：用 injectctl 注入"只观测不拦截"的 netdisguise 变体——hook
私有扫描 API（Apple80211Scan / CoreWiFi scan / CNCopyCurrentNetworkInfo），**只打日志不返回值**
（记录是否被调用 + 调用栈）。基建可复用：`rebind_symbols`（[netdisguise.c L86-94](file:///c:/Users/Administrator/Documents/ChatGPT/New%20project/TrollVNC/netdisguise/netdisguise.c#L86-L94)）管 C 函数、
`method_setImplementation`（L96-104）管 ObjC 方法。判定：日志有调用 → 实锤私有直读且知道走
哪个 API/SDK；无调用 → 只走公开通道，A 层即够。

档位 2（黑盒，参考）：开关 wifi 观察目标 app 行为差异（定位跳变/报错）、网络抓包看 SDK 是否
联网反查。只能侧面印证，作交叉参考。

**关键洞察**："检测私有直读"和"B 层注入"的能力边界是同一个——档位 1 需注入目标 app，而这正是
B 层拦截的前提：**能注入就能观测，能观测就能拦截**。流程 = 档位 0 筛 → 档位 1 实锤 → 决定
B 层做不做、做哪几个 hook。

### 验证步骤

1. 第一步：真机（系统定位已关）App 地图显示真实 wifi 位置，坐标与周边环境吻合
2. 阶段 0（A 层）：CI 编译（4 scheme，bootstrap 验证 App target）+ 真机 5902 日志确认模拟状态翻转
3. 阶段 1（全通道对照表）：档位 0/1 检测目标 app 私有直读 → 注入前后逐通道读数
   （CLSimulationManager 读回 / CLLocationManager 私有扫描 / Apple80211 / NEHotspotHelper
   四通道 × 注入前后），量化 A 层覆盖边界。**目标 app 首选用抖音**（逆向已确认位置读取
   全走公开通道 + wifi 读 CNCopyCurrentNetworkInfo/NEHotspotNetwork）——实测预期：A 层覆盖
   CLLocationManager 通道 ✅，B 层需补 CNCopyCurrentNetworkInfo + NEHotspotNetwork 两个 hook
4. 阶段 2（B 层）：仅按阶段 1 暴露的缺口补 netdisguise hook（Apple80211 dlsym / CoreLocation
   swizzle / Network.framework），复测对照表三档观测全通过
5. 出包路径：`GHTOK=<token> node scripts/build-ipa.mjs` → TrollStore 安装 → 真机闭环

## 边界与安全

- 不做：基站定位（setSimulatedCell:）模拟，本次范围仅 wifi
- 不做：物理层改动（TrollStore 能力边界外，且对风控无意义——SDK 不可能绕过 API 读 airportd 内存）
- 不做：未经验证的 B 层盲写（严格按阶段 1 对照表驱动；检测优先档位 0 静态分析 → 档位 1
  观测探针实锤，B 层只补实测暴露的缺口）
- B 层注入边界：仅"二进制可写"目标 app（App Store FairPlay 加密不可注入）；注入重启生效
  （不能热注入运行中的 app）
- **本地网络探测 ≠ wifi 扫描（独立第三维度，用户确认）**：App 运行中弹「想要访问本地网络下的
  其他设备」= iOS 14 Local Network Privacy，触发的是局域网**数据通信**（NWBrowser/组播/Bonjour/
  网关 MAC 探测），与 wifi 指纹（Apple80211 无线电层）是两个层次——后者永不触发该弹窗。
  风控 LAN fingerprinting 是独立特征维度，本设计不覆盖（网关/拓扑难伪造，多数风控仅作辅助）；
  实测时若目标 app 依赖它再评估，不盲做
- 系统升级改变 CLSimulationManager 签名 → 接口声明集中一处便于适配（目标机型 iOS 版本冻结）
- 字典键名无公开资料 → 初始猜想 + XPC 载荷取证校准（POC 设计稿 §3.3/§6）
- 坐标→SSID 反查为设备端联网操作 → 需频率控制（LRU + 限速），避免风控检测到高频 Apple 请求

## 任务分解提示

详细任务分解见 `outputs/2026-08-27-WiFi定位伪装-POC设计.md`（A 层接线 / WPS 数据内置 /
B 层拦截 / XPC 取证 / 三档观测 / CI 出包）。本设计为两步实现 + 三阶段验证的决策依据，
实现计划在 `docs/superpowers/plans/` 落地。
