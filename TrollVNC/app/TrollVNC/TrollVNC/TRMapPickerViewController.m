/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#import "TRMapPickerViewController.h"
#import <MapKit/MapKit.h>
#import <MapKit/MKGeometry.h> // NSValue valueWithMKCoordinate/MKCoordinateValue（bootstrap SDK 需显式导入）
#import <CoreLocation/CoreLocation.h> // 真实定位（未模拟定位时显示系统蓝点并聚焦）
#import <SystemConfiguration/CaptiveNetwork.h> // 当前连接 WiFi SSID/BSSID（WiFi 水滴数据源，2026-08-29）
#import <notify.h>
// CoordTransform 曾于 2026-08-30 误删（当时误断言"MKMapView 层全程 WGS-84"）；2026-09-04 治理恢复为编排瓦片系/注入 WGS 的边界转换器
// TRWpsTile import 已移除（2026-09-04 死代码清理：App 标注走 TRWpsClient 当前连接反查，不经 TRWpsTile 原语）
// TRWifiScanContract import 已移除（2026-09-04：TRWifiActiveScanner 死链删除，App 不消费 wifiscan.json/updated）
#import "../../../src/TRSimContract.h" // 跨端定位契约（轨迹文件路径单一真相源，2026-08-28）
#import "../../../src/TRAppDomain.h" // kTRAppPrefsSuiteName（跨端 prefs 域契约，2026-08-28）
#import "RegionSimulator.h"
#import "SimRouteCalculator.h"
#import "../../../src/CoordTransform.h" // GCJ-02 ↔ WGS-84（fix 入口/注入出口边界转换，2026-09-04 治理）
#import "TRWpsClient.h"
#import "TVNCUtil.h" // TVNC_NOTIFY_PREFS_CHANGED（prefs-changed 通知名宏，2026-08-28 收敛）
#import "../../../src/Logging.h" // TVLog 宏（restoreSession 恢复日志用；符号定义在 TRAppLogging.m，2026-08-31 起 App 引用共享模块日志）

/// 轨迹文件路径 → kTRSimTrackFilePath（TRSimContract.h 跨端单一真相源，2026-08-28）
// prefs suite 名 → kTRAppPrefsSuiteName（TRAppDomain.h 跨端单一真相源，2026-08-28）
// WiFi 主动扫描契约常量 → TRWifiScanContract.h（共享模块单一真相源，2026-08-28 收敛；不再本地 static 字面量）
static const double kAutoFocusThresholdM = 500.0; // 自动聚焦距离阈值：fix 距上次聚焦点 ≥500m 才拉回（GPS 抖动 <50m 不打扰）
static const double kPassedThresholdM = 25.0; // 到达/落地判定阈值：距锚点（或轨迹端点/注入基线）25m 内视为已到达——锚点经过判定、25m 锁解锁、播放禁用判定共用（单一真相源）

/// 锚点标注（关联编排段索引，点击删除该段；水滴图钉状态分类：未消费=蓝/消费中=绿/已消费=红，当前位置=绿；
/// 水滴内嵌该锚点生成时所使用的出行方式图标 🚶/🚗）
@interface TRAnchorAnnotation : MKPointAnnotation
@property (nonatomic, assign) NSInteger segmentIndex;
@property (nonatomic, copy) NSString *type; // anchor | route | region
@property (nonatomic, assign) BOOL passed;  // 是否已被当前位置到达（单调：置 YES 后不回退；到达=红/绿，未到达=蓝）
@property (nonatomic, assign) BOOL consuming; // 消费中（绿）：当前路段两端——出发锚点（已到达）或终点锚点（下一锚点，即将到达）；禁删
@property (nonatomic, copy) NSString *mode; // 该锚点生成时所使用的出行方式（walk/drive）
@end
@implementation TRAnchorAnnotation
@end

/// 区域漫游途经点标注（信息点，不可点击删除；复用锚点水滴渲染，内嵌该段出行方式图标 🚶/🚗）
@interface TRWaypointAnnotation : MKPointAnnotation
@property (nonatomic, copy) NSString *mode; // 该段出行方式（walk/drive；random 区域每段随机决定）
@end
@implementation TRWaypointAnnotation
@end

/// WiFi 定位标注（wloc 反查结果；自绘水滴显示，点击不触发 tap 加锚点）
@interface TRWifiAnnotation : MKPointAnnotation
@property (nonatomic, copy) NSString *info; // WiFi 定位信息（坐标 + AP 数），用于自绘水滴显示
@end
@implementation TRWifiAnnotation
@end


/// 生长轨迹线（对齐原型 growPath/addedPath：区域自生长逐段可视化 + 完成后常显；与预览虚线区分）
/// 分段式渲染：每个覆盖层挂所属编排段索引，增删/重算只动受影响段
@interface TRGrowPolyline : MKPolyline
@property (nonatomic, assign) NSInteger segmentIndex; // 所属编排段（用于按段移除）
@end
@implementation TRGrowPolyline
@end

@interface TRMapPickerViewController () <MKMapViewDelegate, UISearchBarDelegate, MKLocalSearchCompleterDelegate, UIGestureRecognizerDelegate, UITableViewDataSource, UITableViewDelegate, CLLocationManagerDelegate, UITableViewDragDelegate, UITableViewDropDelegate>
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *searchResultsView;       // 搜索下拉结果列表（搜索框内向下展开）
@property (nonatomic, strong) NSArray *searchResults;               // MKLocalSearchCompletion / MKMapItem 数组（2026-08-28 关联候选）
@property (nonatomic, strong) MKLocalSearchCompleter *searchCompleter; // 关键词→关联候选（点搜索时一次性触发，非逐字联想，2026-08-28）
@property (nonatomic, strong) UISegmentedControl *modeSeg;   // 步行/驾车（左下胶囊）
@property (nonatomic, strong) UIButton *locateFab;           // 右下角圆形定位开关
@property (nonatomic, strong) UIButton *focusBtn;                   // 定位 FAB 上方的靶心按钮（点击聚焦当前位置）
@property (nonatomic, strong) UIButton *statusBtn;                   // 状态条（用 setTitle 渲染，titleLabel.text 直接赋值无效）
@property (nonatomic, strong) UIView *statusDot;                     // 状态圆点（定位中绿/停止灰）
@property (nonatomic, strong) UILabel *wifiDiagLabel;                // WiFi 链路诊断标签（注册/回调/列表/BSSID/反查 5 环）
@property (nonatomic, assign) NSUInteger wifiQuerySeq;  // wifi 反查请求序号（丢弃过期回调，防模拟/真实切换竞态）
@property (nonatomic, copy) NSString *lastWifiBSSID;  // 上次反查的当前连接 BSSID（fix 驱动增量：BSSID 未变不重复反查，2026-09-04 触发模型治理）
// wifiLastTileKey/wifiTileAps 已删除（2026-09-04 死代码清理：窗口质心标注废弃，标注走当前连接反查）
@property (nonatomic, assign) CLLocationCoordinate2D wifiCurWGS; // 最近一次 wifi 反查质心（WGS；真实 wifi 位置，供启动聚焦兜底/状态显示——GPS 优先、无 GPS 用 wifi 聚焦）
@property (nonatomic, strong) UITableView *stepTable;        // 步骤列表（状态条展开；删除 + 拖拽排序）

@property (nonatomic, strong) NSMutableArray *segments;      // 编排段 @[@{type,point/to/radius/durationMin/mode}]
@property (nonatomic, strong) NSMutableArray *segmentPoints;        // 段点序列缓存（索引对齐 segments：段 i≥1 点序列，NSNull=待生成/失败）——锚点链唯一轨迹真相
@property (nonatomic, assign) BOOL segmentZeroPending;                     // 删首锚点后"当前位置→新首锚"段 0 待生成（段 0 特殊机制：正常链段 0=首锚点仅起点恒有效）
@property (nonatomic, strong) NSMutableArray *anchors;       // 每段对应的锚点标注（TRAnchorAnnotation）
@property (nonatomic, strong) NSMutableArray *waypointAnns;          // 区域漫游途经点标注（TRWaypointAnnotation，随区域段生成/重建）
@property (nonatomic, assign) CLLocationCoordinate2D cur;    // 当前模拟位置（瓦片系=MapKit 显示系，2026-09-04 治理：详见 handleLocationUpdate 边界转换）
@property (nonatomic, assign) BOOL hasStart;
@property (nonatomic, assign) BOOL locating;                // 定位开关状态
@property (nonatomic, copy) NSString *currentLegMode;       // 当前位置水滴的出行方式（当前段目标锚点的，walk/drive）
@property (nonatomic, assign) double currentLegSpeed;              // 当前所在路线（出发锚点段）的生成速度——从段缓存 segmentPoints 取（含 ±10% 抖动；random 段反映实际随机模式）
@property (nonatomic, assign) BOOL startupLockedToAnchor;          // 开启瞬间到注入落地前：锁定锚点显示（忽略旧 fix，防开启横跳）
@property (nonatomic, strong) NSMutableArray *fabCoinLabels;              // 定位 FAB 铜钱四字（招财进宝，上/右/下/左顺时针）
@property (nonatomic, strong) CAGradientLayer *fabGoldGradient;           // 定位 FAB 铜钱渐变金底（定位中显示）
@property (nonatomic, assign) BOOL expanded;                // 步骤列表展开态
@property (nonatomic, assign) BOOL hasFocusedMapOnce;            // 首帧启动聚焦是否已执行（避免 tab 往返重复聚焦）
@property (nonatomic, strong) CLLocationManager *locationManager; // App 活跃位置订阅（授权 + startUpdatingLocation，didUpdateLocations 主驱动）
@property (nonatomic, assign) CLLocationCoordinate2D lastAutoFocusWGS;   // 上次自动聚焦点（WGS）：fix 距此 ≥ 阈值才聚焦并更新（残留 fix≈基线不触发，替代 hasFocusedRealOnce）
@property (nonatomic, assign) NSTimeInterval startTimestamp;     // 开启时刻：只认晚于此的 fix（过滤开启前的旧 fix）
@property (nonatomic, assign) NSTimeInterval stopTimestamp;      // 停止时刻：只认晚于此的 fix（过滤停止前的旧 fix）
@property (nonatomic, strong) CLLocation *lastFix;              // 最近一次通过时间戳过滤的回调 fix（坐标/速度真相源，不读 locationManager 属性缓存）
@property (nonatomic, assign) BOOL isGenerating;            // 轨迹生成中（并发保护：正在生长时忽略新的 commit）
@property (nonatomic, copy) void (^pendingEditAction)(void);     // 生成中挂起的最新编辑（完成后执行，最后一次生效）
@property (nonatomic, strong) UITapGestureRecognizer *mapTap;      // 地图单击手势（handleTap；shouldReceiveTouch 拦截锚点水滴点击，防删除竞态）
@property (nonatomic, assign) BOOL hasPromptedLocationAuth;        // 定位授权拒绝提示已弹出（一次性）
@property (nonatomic, strong) NSArray *submittedPoints;             // 已提交的完整轨迹点序列（segmentPoints 展平，播放/上传用）
@property (nonatomic, assign) NSUInteger trackVersion;                // 轨迹版本号（每次重算递增，2026-08-30）：daemon 恢复时区分新旧轨迹——版本一致用 seq 续播，不一致几何兜底

// 区域（长按）临时状态
@property (nonatomic, assign) BOOL regionPicking;
@property (nonatomic, assign) CLLocationCoordinate2D regionCenter;
@property (nonatomic, assign) double regionRadiusM;
@property (nonatomic, assign) CGPoint regionTouchOffset; // 手势起点-中心（像素偏移，拖移用）
@property (nonatomic, strong) UIView *regionPanel;               // 区域配置菜单（底部卡片，对齐原型 param）
@property (nonatomic, strong) MKCircle *regionOverlay;
- (BOOL)_systemLocationAvailable;
@end

@implementation TRMapPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.segments = [NSMutableArray array];
    self.segmentPoints = [NSMutableArray array];
    self.anchors = [NSMutableArray array];
    self.waypointAnns = [NSMutableArray array];
    // 初始无硬编码坐标（self.cur 默认 0,0）；初始视野/聚焦均以 locationd 当前位置为准，
    // 无定位时由 focusMapOnCurrentLocation 守卫跳过，避免跳到无效坐标
    [self setupMap];
    [self setupUI];
    // 搜索关联候选 completer：必须 init + 设 delegate（2026-08-28：此前只声明 property + 设 queryFragment，
    // 从未 alloc/init 也未设 delegate → 对 nil 发消息静默 no-op，点搜索无反应；iOS 15+ 均需此行）
    self.searchCompleter = [[MKLocalSearchCompleter alloc] init];
    self.searchCompleter.delegate = self;
    [self readCurrentStatus];
    [self restoreSession]; // 2026-08-30 持久化 v2：恢复编排会话（读契约文件重建锚点链/路线）
    // 真实定位授权：requestWhenInUse 需 Info.plist usage description。
    // 授权成功后 locationManagerDidChangeAuthorization 建立 App 自己的活跃位置请求（startUpdatingLocation）——
    // locationd 对活跃请求持续广播（系统地图同理），didUpdateLocations 驱动状态栏/锚点；水滴走 MKMapView 显示（同一 locationd 源）
    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.delegate = self;
    // 精度放宽到 100m（2026-08-24）：系统本就产各种精度的位置（GPS 收敛从粗到精），
    // 默认 Best≈10m 会扣住 acc>10m 的位置不推——模拟注入 acc=3~15m 随机（>10m 被扣→跟随断续）、
    // 停止后真实 GPS 收敛初期误差大（>10m 被扣→干等 2 分钟）。放宽后模拟/真实 fix 都尽早推送
    self.locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters;
    if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusNotDetermined) {
        [self.locationManager requestWhenInUseAuthorization];
    } else if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedWhenInUse ||
               [CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedAlways) {
        [self.locationManager startUpdatingLocation]; // 已授权直接建立活跃请求（不等授权回调）
    }
    // WiFi 位置自动显示（唯一实现 = daemon 主动扫描，2026-08-27 定案）：订阅 Apple80211 扫描通知。
    // 已移除 NEHotspotHelper 被动订阅/水合——不做回退，保证主动扫描唯一数据源可靠工作。
    __weak typeof(self) weakSelf = self;
    // 订阅 WiFi 切换通知（daemon AP 下发成功 → 检测重连 → notify App）
    int wifiSwitchToken = 0;
    notify_register_dispatch("com.82flex.trollvnc.wifi-switched", &wifiSwitchToken,
        dispatch_get_main_queue(), ^(int token) {
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf _updateWifiStatusBar];       // 刷新状态栏（模拟 AP 信息）
            [strongSelf _refreshWifiAnnoFromCurrentConnection]; // 更新水滴标注
        });
    // 订阅轨迹播完通知（2026-09-04，kTRSimPlaybackFinishedNotification daemon→App）：
    // 播放态订阅终止——daemon 播完 → App 复位播放态（与手动停止一致，stopPlayback 内 commitStop 写 off）
    int simFinishToken = 0;
    notify_register_dispatch(kTRSimPlaybackFinishedNotification.UTF8String, &simFinishToken,
        dispatch_get_main_queue(), ^(int token) {
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf playbackDidFinish];
        });
    // 启动：地图聚焦到当前所在位置（启动一律停止态=真实位置，取不到则回退默认视野）
    [self focusMapOnCurrentLocation];
    // App 回前台：地图聚焦到当前所在位置（更直观成熟）
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 首帧兜底：viewDidLoad 时地图布局未定可能使 setRegion 不生效，首现时再聚焦一次（不随 tab 切换重复）
    if (!self.hasFocusedMapOnce) {
        self.hasFocusedMapOnce = YES;
        [self focusMapOnCurrentLocation];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

/// App 回前台：地图立即聚焦到当前所在位置
- (void)appWillEnterForeground {
    [self focusMapOnCurrentLocation];
}

#pragma mark - UI 构建

- (void)setupMap {
    MKMapView *mv = [[MKMapView alloc] initWithFrame:self.view.bounds];
    mv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    mv.delegate = self;
    mv.showsUserLocation = YES; // 原生当前位置：数据源=locationd（播放时=模拟位置/停止时=当前位置）；恒 YES（2026-09-04 治理：单 MKUserLocation，自驱水滴已删）
    mv.showsCompass = YES;
    [self.view addSubview:mv];
    self.mapView = mv;
    // 初始视野：仅当已有有效定位（恢复/已设）时设置，否则保持系统默认视野（首现由 viewDidAppear 聚焦真实位置）
    if (self.cur.latitude != 0 || self.cur.longitude != 0) {
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(self.cur, 5000, 5000) animated:NO];
    }

    // 手势：单击 = 递增编排；长按 500ms = 区域中心
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tap.delegate = self;
    [self.mapView addGestureRecognizer:tap];
    self.mapTap = tap;
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    lp.minimumPressDuration = 0.5;
    lp.delegate = self;
    [self.mapView addGestureRecognizer:lp];

    // 无 1s 轮询/事件兜底：当前位置刷新由 App 活跃订阅（startUpdatingLocation → didUpdateLocations）唯一驱动，
    // 水滴（MKUserLocation）显示同一 locationd 源——单一驱动单一数据源，无冗余兜底策略
}

- (void)setupUI {
    // 全部控件用 AutoLayout（viewDidLoad 时容器 bounds 未定，固定 frame 会错位）
    UISearchBar *sb = [[UISearchBar alloc] init];
    sb.translatesAutoresizingMaskIntoConstraints = NO;
    sb.placeholder = @"搜索地点（如：北京西站）";
    sb.delegate = self;
    sb.searchBarStyle = UISearchBarStyleMinimal;
    sb.backgroundColor = [UIColor systemBackgroundColor];
    sb.layer.cornerRadius = 10;
    sb.layer.masksToBounds = YES;
    [self.view addSubview:sb];
    self.searchBar = sb;

    // 状态条（可点击展开步骤；对齐原型 stat：左侧状态圆点 + 文字 + 右侧展开箭头）
    UIButton *statusBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    statusBtn.translatesAutoresizingMaskIntoConstraints = NO;
    statusBtn.backgroundColor = [UIColor systemBackgroundColor];
    statusBtn.layer.cornerRadius = 8;
    statusBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    statusBtn.titleEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 18);
    [statusBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    [statusBtn addTarget:self action:@selector(toggleSteps:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:statusBtn];
    self.statusBtn = statusBtn;
    // 左侧状态圆点（定位中=绿色 glow，停止=灰）
    UIView *sdot = [[UIView alloc] initWithFrame:CGRectMake(14, 12, 8, 8)];
    sdot.tag = 501;
    sdot.layer.cornerRadius = 4;
    sdot.backgroundColor = [UIColor systemGrayColor];
    [statusBtn addSubview:sdot];
    self.statusDot = sdot;
    // 右侧展开箭头（跟随按钮宽度右对齐）
    UILabel *arr = [[UILabel alloc] initWithFrame:CGRectMake(0, 6, 14, 20)];
    arr.tag = 502;
    arr.text = @"▾";
    arr.font = [UIFont systemFontOfSize:11];
    arr.textColor = [UIColor secondaryLabelColor];
    arr.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [statusBtn addSubview:arr];
    NSLayoutConstraint *arrRight = [NSLayoutConstraint constraintWithItem:arr attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual toItem:statusBtn attribute:NSLayoutAttributeTrailing multiplier:1.0 constant:-10];
    NSLayoutConstraint *arrCenterY = [NSLayoutConstraint constraintWithItem:arr attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:statusBtn attribute:NSLayoutAttributeCenterY multiplier:1.0 constant:0];
    [statusBtn addConstraints:@[arrRight, arrCenterY]];

    // WiFi 链路诊断标签（调试用）：NEHotspotHelper 5 环状态实时显示
    // （放 statusBtn 下方——搜索框正下方已被全宽状态条占据，top 对齐 statusBtn.bottom 避免重叠）
    UILabel *wifiDiag = [[UILabel alloc] init];
    wifiDiag.translatesAutoresizingMaskIntoConstraints = NO;
    wifiDiag.font = [UIFont systemFontOfSize:11];
    wifiDiag.textColor = [UIColor secondaryLabelColor];
    wifiDiag.backgroundColor = [UIColor systemBackgroundColor];
    wifiDiag.layer.cornerRadius = 6;
    wifiDiag.layer.masksToBounds = YES;
    wifiDiag.numberOfLines = 2;
    wifiDiag.textAlignment = NSTextAlignmentCenter;  // 2026-08-30：文字居中
    wifiDiag.text = @"WiFi: 初始化中";
    wifiDiag.userInteractionEnabled = YES;
    UITapGestureRecognizer *wifiTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(wifiDiagTapped:)];
    [wifiDiag addGestureRecognizer:wifiTap];
    [self.view addSubview:wifiDiag];
    self.wifiDiagLabel = wifiDiag;

    // 步骤列表（默认收起；地图左上卡片，删除 + 消费状态圆点，2026-08-30 移除拖拽排序）
    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    table.translatesAutoresizingMaskIntoConstraints = NO;
    table.dataSource = self;
    table.delegate = self;
    table.hidden = YES;
    table.layer.cornerRadius = 10;
    table.layer.borderWidth = 0.5;
    table.layer.borderColor = [UIColor separatorColor].CGColor;
    table.backgroundColor = [UIColor systemBackgroundColor];
    table.editing = NO; // 自绘 cell：左=消费状态圆点，右=删除按钮（点击即删，无系统二次确认）
    // dragDelegate/dropDelegate 已移除（2026-08-30 用户定案：取消拖拽排序，列表开始处改显消费状态）
    table.separatorInset = UIEdgeInsetsMake(0, 40, 0, 0);
    table.layer.shadowColor = [UIColor blackColor].CGColor;
    table.layer.shadowOpacity = 0.12;
    table.layer.shadowRadius = 6;
    table.layer.shadowOffset = CGSizeMake(0, 2);
    [self.view addSubview:table];
    self.stepTable = table;

    // 步行/驾车胶囊（左下；不透明背景+阴影，浮层上可辨）
    UISegmentedControl *mode = [[UISegmentedControl alloc] initWithItems:@[@"🚶 步行", @"🚗 驾车"]];
    mode.translatesAutoresizingMaskIntoConstraints = NO;
    mode.selectedSegmentIndex = 0;
    mode.backgroundColor = [UIColor systemBackgroundColor];
    mode.layer.cornerRadius = 16;
    mode.layer.masksToBounds = NO;
    mode.layer.shadowColor = [UIColor blackColor].CGColor;
    mode.layer.shadowOpacity = 0.25;
    mode.layer.shadowRadius = 4;
    mode.layer.shadowOffset = CGSizeMake(0, 1);
    [mode addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:mode];
    self.modeSeg = mode;

    // 搜索下拉结果列表（默认收起；搜索框内向下展开、可滑动）
    UITableView *srv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    srv.translatesAutoresizingMaskIntoConstraints = NO;
    srv.dataSource = self;
    srv.delegate = self;
    srv.hidden = YES;
    srv.layer.cornerRadius = 10;
    srv.layer.borderWidth = 0.5;
    srv.layer.borderColor = [UIColor separatorColor].CGColor;
    srv.backgroundColor = [UIColor systemBackgroundColor];
    srv.layer.shadowColor = [UIColor blackColor].CGColor;
    srv.layer.shadowOpacity = 0.12;
    srv.layer.shadowRadius = 6;
    srv.layer.shadowOffset = CGSizeMake(0, 2);
    [self.view addSubview:srv];
    self.searchResultsView = srv;

    // 定位开关 FAB（右下角圆形）
    UIButton *fab = [UIButton buttonWithType:UIButtonTypeCustom];
    fab.translatesAutoresizingMaskIntoConstraints = NO;
    fab.layer.cornerRadius = 28;
    fab.backgroundColor = [UIColor colorWithRed:0.29 green:0.25 blue:0.89 alpha:1.0]; // 品牌紫（对齐原型 fab）
    [fab setImage:[UIImage systemImageNamed:@"location.fill"] forState:UIControlStateNormal];
    [fab setTintColor:[UIColor whiteColor]];
    [fab addTarget:self action:@selector(toggleLocate:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:fab];
    self.locateFab = fab;
    // 铜钱四字 + 渐变金底（定位中显示"招财进宝"，上/右/下/左顺时针；未开启隐藏；方孔镂空走 mask，见 updateStatus）
    self.fabCoinLabels = [NSMutableArray arrayWithCapacity:4];
    NSArray *coins = @[@"招", @"财", @"进", @"宝"];
    NSArray *dx = @[@0, @14, @0, @-14];
    NSArray *dy = @[@-14, @0, @14, @0];
    UIFont *coinFont = [UIFont fontWithName:@"STKaiti" size:10] ?: [UIFont boldSystemFontOfSize:10]; // 楷体古风铸字感（缺字库回退粗黑）
    UIColor *coinInk = [UIColor colorWithRed:0.36 green:0.23 blue:0.0 alpha:1.0]; // 深棕（凹刻铸字色 #5C3A00）
    for (NSInteger i = 0; i < 4; i++) {
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(28 - 9 + [dx[i] intValue], 28 - 9 + [dy[i] intValue], 18, 18)];
        lb.text = coins[i];
        lb.font = coinFont;
        lb.textColor = coinInk;
        lb.textAlignment = NSTextAlignmentCenter;
        lb.hidden = YES;
        [fab addSubview:lb];
        [self.fabCoinLabels addObject:lb];
    }
    // 渐变金底（对角：左上亮金 → 右下深金，铜钱立体感；FAB 固定 56×56——bounds 布局前为 0，固定尺寸兜底 + viewDidLayoutSubviews 同步）
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.frame = CGRectMake(0, 0, 56, 56);
    grad.colors = @[(id)[UIColor colorWithRed:0.95 green:0.78 blue:0.30 alpha:1.0].CGColor, // 亮金
                    (id)[UIColor colorWithRed:0.83 green:0.63 blue:0.09 alpha:1.0].CGColor]; // 深金
    grad.startPoint = CGPointMake(0, 0);
    grad.endPoint = CGPointMake(1, 1);
    grad.cornerRadius = 28;
    grad.hidden = YES;
    [fab.layer insertSublayer:grad atIndex:0];
    self.fabGoldGradient = grad;

    // 靶心聚焦按钮：定位 FAB 上方（透明，类靶心），点击聚焦到当前位置——
    // 应对手动编辑（增删锚点/拖动）偏离当前位置后的手动调整
    UIButton *focus = [UIButton buttonWithType:UIButtonTypeCustom];
    focus.translatesAutoresizingMaskIntoConstraints = NO;
    focus.layer.cornerRadius = 22;
    focus.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.55]; // 透明
    focus.layer.shadowColor = [UIColor blackColor].CGColor;
    focus.layer.shadowOpacity = 0.15;
    focus.layer.shadowRadius = 6;
    focus.layer.shadowOffset = CGSizeMake(0, 2);
    [focus setImage:[UIImage systemImageNamed:@"scope"] forState:UIControlStateNormal]; // 靶心
    [focus setTintColor:[UIColor systemBlueColor]];
    [focus addTarget:self action:@selector(focusCurrentPosition:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:focus];
    self.focusBtn = focus;

    // 约束
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        // 搜索框：顶部 8、左右 12、高 40
        [sb.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [sb.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [sb.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [sb.heightAnchor constraintEqualToConstant:40],
        // 状态条：搜索框下 8
        [statusBtn.topAnchor constraintEqualToAnchor:sb.bottomAnchor constant:8],
        [statusBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [statusBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [statusBtn.heightAnchor constraintEqualToConstant:32],
        // WiFi 诊断标签：状态条下 6、与定位状态栏同宽（2026-08-30 用户定案）、高度自适应
        [wifiDiag.topAnchor constraintEqualToAnchor:statusBtn.bottomAnchor constant:6],
        [wifiDiag.leadingAnchor constraintEqualToAnchor:statusBtn.leadingAnchor],
        [wifiDiag.trailingAnchor constraintEqualToAnchor:statusBtn.trailingAnchor],
        // 搜索下拉结果列表：搜索框下 4、左右 12、高 ≤240（可滚动）
        [srv.topAnchor constraintEqualToAnchor:sb.bottomAnchor constant:4],
        [srv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [srv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [srv.heightAnchor constraintEqualToConstant:240],
        // 步骤列表：状态栏下 4、与状态栏同宽（从状态栏向下展开）
        [table.topAnchor constraintEqualToAnchor:statusBtn.bottomAnchor constant:4],
        [table.leadingAnchor constraintEqualToAnchor:statusBtn.leadingAnchor],
        [table.trailingAnchor constraintEqualToAnchor:statusBtn.trailingAnchor],
        [table.heightAnchor constraintEqualToConstant:200],
        // 步行/驾车胶囊：左下
        [mode.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [mode.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
        [mode.widthAnchor constraintEqualToConstant:150],
        [mode.heightAnchor constraintEqualToConstant:32],
        // FAB：右下 56×56
        [fab.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [fab.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
        [fab.widthAnchor constraintEqualToConstant:56],
        [fab.heightAnchor constraintEqualToConstant:56],
        // 靶心聚焦按钮：FAB 上方 12、右对齐、44×44
        [focus.trailingAnchor constraintEqualToAnchor:fab.trailingAnchor],
        [focus.bottomAnchor constraintEqualToAnchor:fab.topAnchor constant:-12],
        [focus.widthAnchor constraintEqualToConstant:44],
        [focus.heightAnchor constraintEqualToConstant:44],
    ]];
}

/// 点击 WiFi 诊断标签：手动刷新当前状态
- (void)wifiDiagTapped:(UITapGestureRecognizer *)g {
    [self _updateWifiStatusBar]; // 立即刷新当前状态
}

/// 当前连接 WiFi 信息（CNCopyCurrentNetworkInfo 封装，2026-09-04 治理：2 处调用收口）。
/// 注意：需系统定位服务开启才返回数据——定位关时返回 nil（wifi 标注触发模型依赖 fix 驱动，
/// 定位关时 fix 不到达自然不触发，与本 helper 的 nil 返回语义一致）
- (NSDictionary *)currentNetworkInfo {
    NSArray *ifs = (__bridge_transfer NSArray *)CNCopySupportedInterfaces();
    for (id ifname in ifs) {
        NSDictionary *info = (__bridge_transfer NSDictionary *)CNCopyCurrentNetworkInfo((__bridge CFStringRef)ifname);
        if (info) return info;
    }
    return nil;
}

/// wifi 状态栏更新（2026-08-30）：统一管理 wifiDiagLabel 显示，取代旧多处分散更新
/// 模拟中 → 读 daemon 写入的 SimAP 数据（SSID/BSSID/坐标/距离）+ 当前位置
/// 非模拟 → 读 CNCopy 当前连接 SSID/BSSID + wloc 反查坐标
- (void)_updateWifiStatusBar {
    CLLocationCoordinate2D pos = [self currentSimPosition];
    if (pos.latitude == 0 && pos.longitude == 0) return;
    NSString *posStr = [NSString stringWithFormat:@"%.5f,%.5f", pos.latitude, pos.longitude];
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    if (self.locating) {
        // 模拟态：显示模拟 AP 信息（daemon _handleAPList 写入）
        NSString *apSSID = [d stringForKey:@"SimAPSSID"];
        NSString *apBSSID = [d stringForKey:@"SimAPBSSID"];
        double apDist = [d doubleForKey:@"SimAPDistance"];
        if (apSSID.length && apBSSID.length) {
            self.wifiDiagLabel.text = [NSString stringWithFormat:@"模拟位置：%@   模拟AP：%@，%@，距离：%.0fm",
                posStr, apSSID, apBSSID, apDist];
        } else {
            self.wifiDiagLabel.text = [NSString stringWithFormat:@"模拟位置：%@   模拟AP：反查中…", posStr];
        }
    } else {
        // 停止态：显示当前连接 WiFi 信息
        NSDictionary *info = [self currentNetworkInfo];
        NSString *bssid = info[(__bridge NSString *)kCNNetworkInfoKeyBSSID];
        NSString *ssid = info[(__bridge NSString *)kCNNetworkInfoKeySSID];
        if (bssid.length && ssid.length) {
            // 用 wloc 反查 BSSID 坐标（已有 _queryWifiAnnoWithBssids 异步回调，但状态栏需即时显示）
            // 先显示 SSID/BSSID，反查结果通过 _queryWifiAnnoWithBssids 回调更新
            self.wifiDiagLabel.text = [NSString stringWithFormat:@"当前AP：%@，%@，AP位置：反查中…", ssid, bssid];
            // 启动一次 wloc 反查（仅用于获取坐标更新状态栏）
            NSUInteger seq = ++self.wifiQuerySeq;
            [self _queryWifiAnnoWithBssids:@[bssid] seq:seq];
        } else {
            self.wifiDiagLabel.text = @"WiFi: 当前连接获取中…";
        }
    }
}

/// WiFi 水滴（2026-08-29 职责重定义，用户定案）：只读「当前连接 WiFi」的 SSID/BSSID →
/// 用 BSSID 做 wloc 反查（复用 _queryWifiAnnoWithBssids）→ 标注真实 AP 的位置。
/// 不跟随模拟坐标——它是软路由切换效果的可视化验证（真实 BSSID 被定位到哪 = 切换是否生效），
/// 与 GPS 轨迹/模拟位置完全解耦。旧「瓦片检测 + 缓存池质心跟随」逻辑已删。
/// 数据源 = CNCopyCurrentNetworkInfo（App 有定位授权可用；daemon 才需要 ipconfig 通道）。
/// wifi 标注触发模型（2026-09-04 治理，与订阅定位同构）：didUpdateLocations 为唯一时钟——
/// 每次 fix 到达时读当前连接 BSSID，与缓存比对：变化/首次 → wloc 反查更新标注；未变 → 跳过（零开销）。
/// 定位关时 fix 不到达 → 不触发（CNCopyCurrentNetworkInfo 需系统定位开启才返回数据——
/// 停止态"获取中"死路的根治：daemon off 注入/播放会开定位，fix 到达即自动恢复反查链）
/// 覆盖触发项：启动恢复（首个 fix）/ 软路由下发断网重连（BSSID 变化）/ 网络切换（同上）
- (void)_refreshWifiAnnoFromCurrentConnection {
    NSDictionary *info = [self currentNetworkInfo];
    NSString *bssid = info[(__bridge NSString *)kCNNetworkInfoKeyBSSID];
    if (!bssid.length) {
        [self removeWifiAnnotationIfExists];
        self.lastWifiBSSID = nil;
        return;
    }
    // fix 驱动增量：BSSID 未变化 → 跳过（同 AP 反查结果稳定，无重复网络请求）
    if ([bssid isEqualToString:self.lastWifiBSSID]) return;
    self.lastWifiBSSID = bssid;
    NSUInteger seq = ++self.wifiQuerySeq;
    [self _queryWifiAnnoWithBssids:@[bssid] seq:seq];
}

/// 用给定 BSSID 集合反查并更新 wifi 标注（动态反查与真实扫描共用；seq 竞态防护，丢弃过期回调）
- (void)_queryWifiAnnoWithBssids:(NSArray<NSString *> *)bssids seq:(NSUInteger)seq {
    if (bssids.count == 0) {
        [self removeWifiAnnotationIfExists]; // 无 BSSID 清除残留（同现有空列表分支语义）
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[TRWpsClient sharedClient] queryCoordinatesForBssids:bssids completion:^(NSDictionary<NSString *,CLLocation *> *result,
        CLLocationCoordinate2D centroid, BOOL hasValid, NSError *error) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (seq != strongSelf.wifiQuerySeq) return; // 过期回调丢弃（模拟/真实切换竞态防护）
        if (error || !hasValid) {
            strongSelf.wifiDiagLabel.text = [NSString stringWithFormat:@"WiFi: 反查失败 %@",
                error.localizedDescription ?: @"无有效坐标"];
            return;
        }
        strongSelf.wifiDiagLabel.text = [NSString stringWithFormat:@"WiFi: 反查OK 定位(%.4f,%.4f)←%lu AP%@",
            centroid.latitude, centroid.longitude, (unsigned long)result.count,
            strongSelf.locating ? @"（模拟位置）" : @"（真实扫描）"];
        // 缓存 wifi 真实位置（WGS）：启动聚焦兜底（无 GPS fix 时用 wifi 位置聚焦）
        strongSelf.wifiCurWGS = centroid;
        // 启动聚焦兜底：viewDidLoad 时 GPS/wifi 均未就绪 → 未聚焦过，wifi 位置到位后补聚焦一次
        if (!strongSelf.hasFocusedMapOnce && ![strongSelf _systemLocationAvailable]) {
            strongSelf.hasFocusedMapOnce = YES;
            [strongSelf focusMapOnCurrentLocation];
        }
        // 更新/创建 wifi 标注（先移除旧的再添加新的，避免重复）
        [strongSelf removeWifiAnnotationIfExists];
// centroid 为 wloc 反查质心（坐标系悬案：gs-loc-cn 中国节点返回 GCJ/WGS 待真机裁决，2026-09-04）——现状直画
        TRWifiAnnotation *ann = [[TRWifiAnnotation alloc] init];
        ann.coordinate = centroid;
        ann.title = strongSelf.locating ? @"WiFi 定位（模拟位置）" : @"WiFi 定位（wloc 反查）";
        ann.info = [NSString stringWithFormat:@"%.4f, %.4f（%lu 个 AP）",
                    centroid.latitude, centroid.longitude, (unsigned long)result.count];
        ann.subtitle = ann.info;
        [strongSelf.mapView addAnnotation:ann];
        // 更新状态栏的 AP 位置（wloc 反查成功）
        [strongSelf _updateWifiStatusBar];
    }];
}

/// 模拟开关切换后立即刷新 wifi 标注（用当前语义：模拟中→模拟位置，停止→真实位置）
- (void)refreshWifiAnnotation {
    if (!self.locating) {
        // 停止态：读当前连接 WiFi 反查标注（回到真实位置，2026-08-30 替代旧主动扫描）
        [self _updateWifiStatusBar]; // 状态栏刷新
        [self _refreshWifiAnnoFromCurrentConnection]; // 水滴标注更新
        return;
    }
    // 模拟态：当前连接 BSSID 反查（不跟随模拟坐标）
    [self _updateWifiStatusBar]; // 状态栏刷新
    [self _refreshWifiAnnoFromCurrentConnection]; // 水滴标注更新
}

/// 移除地图上已有的 WiFi 定位标注（按类型匹配，防重复标注累积）
- (void)removeWifiAnnotationIfExists {
    NSMutableArray *toRemove = [NSMutableArray array];
    for (id<MKAnnotation> ann in self.mapView.annotations) {
        if ([ann isKindOfClass:[TRWifiAnnotation class]]) [toRemove addObject:ann];
    }
    [self.mapView removeAnnotations:toRemove];
}

/// 启动状态（2026-08-24 定：启动一律停止态）：
/// 残留的 anchor/itinerary 模式强制写 off（App 启动态=停止=执行契约，daemon 强制对齐停止、locationd 保持当前位置），
/// 避免"启动即自动开启模拟 / 真实位置被当模拟位置 / 恢复态 Follow 干扰搜索聚焦"
- (void)readCurrentStatus {
    [self commitSimPrefs:^(NSUserDefaults *d) {
        [d setObject:@"off" forKey:@"SimLocationMode"];
    }];
    // 2026-08-30 定案：不再从 SimCurrentLat/Lon 恢复 self.cur——该值可能残留旧坐标系（GCJ-02）
    // 致绿点偏移（实测 SimLocationLat 与 SimCurrentLat 差 538m 东南 = GCJ 偏移特征）。
    // 当前位置唯一真相 = locationd 广播 fix（handleLocationUpdate → self.cur = loc.coordinate，瓦片系）；
    // 启动后首个 fix 到达即建立 self.cur/绿点，无需历史恢复。
    self.locating = NO;   // 不恢复定位中；初始视野/聚焦以 locationd（真实）为准
    [self _updateWifiStatusBar]; // wifi 状态栏：启动时显示当前连接 AP
    [self updateStatus];
}

/// 恢复编排会话（2026-08-30 持久化升级 v2：编排契约文件唯一真相源）——
/// 启动读 kTRSimTrackFilePath 的 segments（锚点链），重建地图编排（锚点标注 + 路线），
/// 与 daemon 播放无缝衔接（位置由 locationd 广播恢复，播放态由 readCurrentStatus 强制 off 后用户显式开启）。
/// 文件为 v1（仅 points）或损坏时静默跳过（首次启动/旧版本无编排可恢复）。
- (void)restoreSession {
    NSData *data = [NSData dataWithContentsOfFile:kTRSimTrackFilePath];
    if (!data.length) return;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    NSArray *segs = json[@"segments"];
    if (![segs isKindOfClass:[NSArray class]] || segs.count == 0) return;
    // 校验：segments 必须是合法段字典数组（防旧版本/损坏文件把垃圾数据当编排）
    for (id s in segs) {
        if (![s isKindOfClass:[NSDictionary class]]) return;
        NSString *t = s[@"type"];
        if (![t isEqualToString:@"anchor"] && ![t isEqualToString:@"region"]) return;
    }
    // ① 恢复 segments 链（anchor/region 段原样恢复；route 段隐式，由 syncChainAndGenerate 重生成）
    [self.segments removeAllObjects];
    [self.segments addObjectsFromArray:segs];
    self.hasStart = YES;
    // ② 重建锚点标注（复用 rebuildAnchors：按段类型取坐标创建 TRAnchorAnnotation）
    [self rebuildAnchors];
    // ③ 补生成缺失段点序列（复用 syncChainAndGenerate：锚点对间 route 段重新算路）
    self.isGenerating = NO;
    [self runEdit:^{ [self syncChainAndGenerate]; }];
    TVLog(@"[locsim-grow] session restored: %lu segments", (unsigned long)self.segments.count);
}

#pragma mark - 手势：单击递增编排

/// 单击地图 = 添加锚点（无起点差别：所有位置都是锚点）
/// 第一个锚点无前驱（前方没有任何锚点）→ 仅当前定位（anchor 注入）；
/// 后续锚点前方都有上一个锚点 → 从上一锚点生长路线到本锚点（增量生长）
- (void)handleTap:(UIGestureRecognizer *)g {
    if ([self.searchBar isFirstResponder]) [self.searchBar resignFirstResponder]; // 点击地图收起搜索键盘（2026-08-28：此前点搜索框后不输入键盘无法收起）
    CGPoint pt = [g locationInView:self.mapView];
    // 点击锚点水滴的拦截由 shouldReceiveTouch 在 touch 阶段完成（早于 didSelect 删除时序，无竞态）。
    // 此处不再做 ended 检测兜底——删除重建后 annotations 已变，兜底检测本身会产生竞态误判（单机制原则）
// convertPoint 返回瓦片系（MapKit 显示层语义=GCJ，2026-09-04 治理纠正），segments 全程存瓦片系
    CLLocationCoordinate2D wgs = [self.mapView convertPoint:pt toCoordinateFromView:self.mapView];
    NSString *mode = (self.modeSeg.selectedSegmentIndex == 1) ? @"drive" : @"walk";
    [self.segments addObject:@{@"type": @"anchor", @"lat": @(wgs.latitude), @"lon": @(wgs.longitude), @"mode": mode}];
    if (self.segments.count == 1) {
        // 第一个锚点：判断是否有当前位置（持久化/注入的）
        CLLocationCoordinate2D curPos = [self currentSimPosition]; // lastFix 优先（daemon 注入的当前位置）
        BOOL hasCurPos = (curPos.latitude != 0 || curPos.longitude != 0);
        if (hasCurPos) {
            // 有当前位置（持久化恢复）：基于当前位置创建锚点（起点，消费），点击位置作为终点 → 生成路线
            // 当前位置锚点插到点击位置前面（segments[0]=起点，segments[1]=终点）
// curPos 为瓦片系（currentSimPosition 已转），segments 统一存瓦片系（2026-09-04 治理）
            [self.segments insertObject:@{@"type": @"anchor", @"lat": @(curPos.latitude), @"lon": @(curPos.longitude), @"mode": mode}
                                atIndex:0];
            self.hasStart = YES;
            self.cur = curPos; // 保持当前位置（不跳到点击位置）
            [self runEdit:^{ [self commitItinerary]; }];  // 生成 当前位置 → 点击位置 路线
            [self setHint:@"已基于当前位置创建锚点 · 路线从当前位置生长"];
        } else {
            // 首次启动无当前位置：点击点成为当前定位；聚焦该点但不开启模拟播放
            self.hasStart = YES;
            self.cur = wgs;
            // 不设 self.locating（保持 OFF）——首锚点只设位置，不开启模拟播放
            [self commitAnchor];
            // 启用 MKUserLocation 跟随注入位置（daemon off 分支已开定位）
            [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(wgs, 3000, 3000) animated:YES]; // 立即聚焦锚点
self.lastAutoFocusWGS = wgs; // 自动聚焦基线（瓦片系，2026-09-04 治理）
            self.mapView.userTrackingMode = MKUserTrackingModeFollow; // 原生跟随（MKUserLocation 跟随 locationd 注入位置）
            [self refreshWifiAnnotation];                            // 首锚点：wifi 标注切到锚点位置
            [self setHint:@"已设定位点 · 继续点击添加锚点生长路线"];
        }
    } else {
        // 后续锚点：点击点只是目标锚点——当前位置图标保持当前实际位置，不随点击瞬移
        //（当前位置由注入事件/定时器随注入实时刷新）
        [self runEdit:^{ [self commitItinerary]; }]; // 生成中挂起，完成后再生长，编辑不丢
        [self setHint:@"已添加锚点 · 路线从上一位置生长"];
    }
    [self updateStatus];
    [self syncSegmentsUI];
}

#pragma mark - 手势：长按区域

/// 长按区域：出现遮罩（原生半透明圆）→ 圆内拖动移动中心 / 圆边拖动调覆盖范围 → 松开弹配置菜单（对齐原型 ring+ringHandle+param）
- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    CGPoint pt = [g locationInView:self.mapView];
// convertPoint 返回瓦片系（MapKit 显示层语义=GCJ，2026-09-04 治理纠正 8-30 误断言）
    CLLocationCoordinate2D wgs = [self.mapView convertPoint:pt toCoordinateFromView:self.mapView];
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            self.regionPicking = YES;
            self.regionCenter = wgs;
            self.regionRadiusM = 300;
            CGPoint centerPt = [self.mapView convertCoordinate:self.regionCenter toPointToView:self.mapView];
            self.regionTouchOffset = CGPointMake(pt.x - centerPt.x, pt.y - centerPt.y);
            [self addRegionOverlay];
            [self setHint:@"拖动圆内移动区域 · 拖动圆边调节覆盖范围"];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!self.regionPicking) break;
            CGPoint centerPt = [self.mapView convertCoordinate:self.regionCenter toPointToView:self.mapView];
            double distPx = hypot(pt.x - centerPt.x, pt.y - centerPt.y);
            double radiusPx = [self pixelsForMeters:self.regionRadiusM];
            if (distPx < radiusPx * 0.6) {
                // 圆内拖动 → 移动区域中心（区域整体平移）
                CLLocationCoordinate2D newCenter = [self.mapView convertPoint:CGPointMake(pt.x - self.regionTouchOffset.x, pt.y - self.regionTouchOffset.y)
                                                          toCoordinateFromView:self.mapView];
                self.regionCenter = newCenter;
            } else {
                // 圆边/外拖动 → 调节覆盖范围（手势点到中心距离）
// wgs/regionCenter 均为 convertPoint 返回（瓦片系），与区域配置同系无需转换（2026-09-04 治理）
                self.regionRadiusM = MAX(50, MIN(5000, [SimRouteCalculator haversineMeters:self.regionCenter to:wgs]));
            }
            [self addRegionOverlay];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            if (self.regionPicking) {
                self.regionPicking = NO;
                [self showRegionConfigPanel]; // 配置菜单（对齐原型 param：时长/途经点/模式）
            }
            break;
        default:
            break;
    }
}

/// 当前地图缩放下的米→像素换算（经度方向近似）
- (double)pixelsForMeters:(double)m {
    CLLocationCoordinate2D c1 = self.regionCenter;
    CLLocationCoordinate2D c2 = CLLocationCoordinate2DMake(c1.latitude, c1.longitude + (m / 111320.0));
    CGPoint p1 = [self.mapView convertCoordinate:c1 toPointToView:self.mapView];
    CGPoint p2 = [self.mapView convertCoordinate:c2 toPointToView:self.mapView];
    return hypot(p2.x - p1.x, p2.y - p1.y);
}

- (void)addRegionOverlay {
    if (self.regionOverlay) [self.mapView removeOverlay:self.regionOverlay];
    self.regionOverlay = [MKCircle circleWithCenterCoordinate:self.regionCenter radius:self.regionRadiusM];
    [self.mapView addOverlay:self.regionOverlay];
}

/// 区域覆盖范围调节阀：实时更新半径、遮罩预览与菜单数值（确定后按当前值入段）
- (void)regionRadiusSliderChanged:(UISlider *)sender {
    self.regionRadiusM = MAX(50, MIN(5000, (double)sender.value));
    [self addRegionOverlay];
    UILabel *rLabel = (UILabel *)[self.regionPanel viewWithTag:604];
    rLabel.text = [NSString stringWithFormat:@"覆盖范围 %.0f m", self.regionRadiusM];
}

/// 区域配置菜单：地图底部卡片（时长/途经点/模式 + 取消/确定），对齐原型 param 参数条（非系统弹窗）
- (void)showRegionConfigPanel {
    [self.view endEditing:YES];
    if (self.regionPanel) { [self.regionPanel removeFromSuperview]; self.regionPanel = nil; }
    CGFloat margin = 12;
    CGFloat w = self.view.bounds.size.width - margin * 2;
    CGFloat ph = 260;
    // 面板底部补偿 safe area（容器底边已延伸到 tab bar 之后，不补偿则最下方按钮被导航栏压住）
    CGFloat safeBottom = self.view.safeAreaInsets.bottom;
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(margin, self.view.bounds.size.height - ph - 12 - safeBottom, w, ph)];
    panel.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    panel.backgroundColor = [UIColor systemBackgroundColor];
    panel.layer.cornerRadius = 14;
    panel.layer.shadowColor = [UIColor blackColor].CGColor;
    panel.layer.shadowOpacity = 0.2;
    panel.layer.shadowRadius = 10;
    panel.layer.shadowOffset = CGSizeMake(0, 2);
    [self.view addSubview:panel];
    self.regionPanel = panel;

    CGFloat y = 14;

    // 覆盖范围调节阀（精确控制区域覆盖范围，实时预览遮罩；长按拖动遮罩边缘快速调仍可用）
    UILabel *rLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, y, 110, 30)];
    rLabel.text = [NSString stringWithFormat:@"覆盖范围 %.0f m", self.regionRadiusM];
    rLabel.font = [UIFont systemFontOfSize:13];
    rLabel.tag = 604;
    [panel addSubview:rLabel];
    UISlider *radiusSlider = [[UISlider alloc] initWithFrame:CGRectMake(128, y, w - 142, 30)];
    radiusSlider.minimumValue = 50;
    radiusSlider.maximumValue = 5000;
    radiusSlider.value = self.regionRadiusM;
    radiusSlider.tag = 605;
    [radiusSlider addTarget:self action:@selector(regionRadiusSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [panel addSubview:radiusSlider];
    y += 40;

    y = [self addConfigFieldOn:panel y:y label:@"时长（分钟）" isDur:YES];
    y = [self addConfigFieldOn:panel y:y label:@"途经点（0=随机）" isDur:NO];
    y += 2;

    UILabel *ml = [[UILabel alloc] initWithFrame:CGRectMake(14, y, 110, 30)];
    ml.text = @"模式";
    ml.font = [UIFont systemFontOfSize:13];
    [panel addSubview:ml];
    // 模式选择器：步行 | 随机（默认） | 驾车——随机=区域内每段出行方式随机（平衡调节阀调权重）
    UISegmentedControl *ms = [[UISegmentedControl alloc] initWithItems:@[@"步行", @"随机", @"驾车"]];
    ms.selectedSegmentIndex = 1; // 默认随机
    ms.frame = CGRectMake(128, y, w - 142, 30);
    ms.tag = 603;
    [ms addTarget:self action:@selector(regionModeChanged:) forControlEvents:UIControlEventValueChanged];
    [panel addSubview:ms];
    y += 40;

    // 平衡调节阀（仅随机模式显示，单行省空间）：左=「步行 xx%」、右=「驾车 xx%」，滑块=步行比例（默认 70%），拖向哪端=提高哪端比例
    UIView *ratioRow = [[UIView alloc] initWithFrame:CGRectMake(0, y, w, 30)];
    ratioRow.tag = 608;
    UILabel *wL = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, 64, 30)];
    wL.text = @"步行 70%";
    wL.font = [UIFont systemFontOfSize:12];
    wL.tag = 610;
    [ratioRow addSubview:wL];
    UISlider *ratio = [[UISlider alloc] initWithFrame:CGRectMake(84, 0, w - 160, 30)];
    ratio.minimumValue = 0;
    ratio.maximumValue = 1;
    ratio.value = 0.7; // 默认 70% 步行 / 30% 驾车
    ratio.tag = 607;
    [ratio addTarget:self action:@selector(regionRatioChanged:) forControlEvents:UIControlEventValueChanged];
    [ratioRow addSubview:ratio];
    UILabel *dL = [[UILabel alloc] initWithFrame:CGRectMake(w - 84, 0, 70, 30)];
    dL.text = @"驾车 30%";
    dL.font = [UIFont systemFontOfSize:12];
    dL.textAlignment = NSTextAlignmentRight;
    dL.tag = 611;
    [ratioRow addSubview:dL];
    [panel addSubview:ratioRow];
    y += 40; // 与前面行距一致（30 高控件 + 10 间隙），按钮自然下移、不挤比例行

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(14, y, (w - 34) / 2, 40);
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    cancel.layer.cornerRadius = 10;
    cancel.backgroundColor = [UIColor secondarySystemBackgroundColor];
    [cancel setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(cancelRegionConfig) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:cancel];
    UIButton *ok = [UIButton buttonWithType:UIButtonTypeSystem];
    ok.frame = CGRectMake(20 + (w - 34) / 2, y, (w - 34) / 2, 40);
    [ok setTitle:@"确定" forState:UIControlStateNormal];
    ok.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    ok.layer.cornerRadius = 10;
    ok.backgroundColor = [UIColor colorWithRed:0.29 green:0.25 blue:0.89 alpha:1.0];
    [ok setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [ok addTarget:self action:@selector(confirmRegionConfig) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:ok];
}

/// 配置面板字段行（tag 601=时长 / 602=途经点）
- (CGFloat)addConfigFieldOn:(UIView *)panel y:(CGFloat)y label:(NSString *)label isDur:(BOOL)isDur {
    CGFloat w = panel.bounds.size.width;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, y, 110, 30)];
    l.text = label;
    l.font = [UIFont systemFontOfSize:13];
    [panel addSubview:l];
    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(128, y, w - 142, 30)];
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.keyboardType = UIKeyboardTypeNumberPad;
    tf.font = [UIFont systemFontOfSize:13];
    tf.tag = isDur ? 601 : 602;
    tf.text = isDur ? @"10" : @"0";
    // 数字键盘无回车键 → 顶部"完成"工具条收起（对齐系统惯例）
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    bar.items = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissRegionKeyboard)],
    ];
    tf.inputAccessoryView = bar;
    [panel addSubview:tf];
    return y + 36;
}

/// 区域面板数字键盘"完成"→ 收起键盘（配置值在确定时读取）
- (void)dismissRegionKeyboard {
    [self.view endEditing:YES];
}

- (void)cancelRegionConfig {
    [self.view endEditing:YES];
    [self.regionPanel removeFromSuperview];
    self.regionPanel = nil;
    if (self.regionOverlay) { [self.mapView removeOverlay:self.regionOverlay]; self.regionOverlay = nil; }
    [self setHint:@"长按地图添加区域漫游"];
}

/// 区域模式选择器变化：随机档显示平衡调节阀，固定档隐藏（对齐"选其他两个模式隐藏调节阀"）
- (void)regionModeChanged:(UISegmentedControl *)sender {
    UIView *row = [self.regionPanel viewWithTag:608];
    row.hidden = (sender.selectedSegmentIndex != 1); // 仅"随机"（中间档）显示
}

/// 平衡调节阀变化：实时更新两侧步行/驾车比例文案（左=步行 xx% 右=驾车 xx%）
- (void)regionRatioChanged:(UISlider *)sender {
    int walkPct = (int)llround(sender.value * 100);
    UILabel *wL = (UILabel *)[self.regionPanel viewWithTag:610];
    wL.text = [NSString stringWithFormat:@"步行 %d%%", walkPct];
    UILabel *dL = (UILabel *)[self.regionPanel viewWithTag:611];
    dL.text = [NSString stringWithFormat:@"驾车 %d%%", 100 - walkPct];
}

/// 确定：读配置 → 加入 region 段 → 自生长提交（时长 clamp 1~120，途经点 clamp 0~15）
- (void)confirmRegionConfig {
    [self.view endEditing:YES];
    UITextField *durTf = (UITextField *)[self.regionPanel viewWithTag:601];
    UITextField *wpTf = (UITextField *)[self.regionPanel viewWithTag:602];
    UISegmentedControl *ms = (UISegmentedControl *)[self.regionPanel viewWithTag:603];
    double dur = MAX(1, MIN(120, [durTf.text doubleValue] ?: 10));
    int customK = (int)[wpTf.text integerValue];
    customK = MAX(0, MIN(15, customK));
    // 模式：步行(index0)/驾车(index2) 固定；随机(index1) → 存 walkRatio（平衡调节阀）
    NSString *mode;
    NSNumber *walkRatio = nil;
    if (ms.selectedSegmentIndex == 0) {
        mode = @"walk";
    } else if (ms.selectedSegmentIndex == 2) {
        mode = @"drive";
    } else {
        mode = @"random";
        UISlider *ratio = (UISlider *)[self.regionPanel viewWithTag:607];
        walkRatio = @(MAX(0.0, MIN(1.0, ratio.value)));
    }
    NSMutableDictionary *seg = [@{@"type": @"region",
        @"radius": @(self.regionRadiusM),
        @"durationMin": @(dur),
        @"mode": mode,
        @"waypointCount": @(customK),
        @"center": @{@"lat": @(self.regionCenter.latitude), @"lon": @(self.regionCenter.longitude)},
    } mutableCopy];
    if (walkRatio) seg[@"walkRatio"] = walkRatio;
    // 链首 region 段（无前驱锚点）：有当前位置 → 基于当前位置创建入口锚点（2026-08-30 用户定案）；
    // 无当前位置（新设备第一次打开 APP）→ 随机取区域半径内 0.3~0.8 因子一点（避开边缘/圆心）生成入口锚点
    if (self.segments.count == 0) {
        CLLocationCoordinate2D curPos = [self currentSimPosition];
        BOOL hasCurPos = (curPos.latitude != 0 || curPos.longitude != 0);
        if (hasCurPos) {
            // 有当前位置：基于当前位置创建链首入口锚点（区域漫游从当前位置进入）
            // curPos 为 WGS-84（currentSimPosition 契约），segments/cur 统一存 WGS-84（2026-08-30）
            [self.segments addObject:@{@"type": @"anchor",
                @"lat": @(curPos.latitude), @"lon": @(curPos.longitude),
                @"mode": (self.modeSeg.selectedSegmentIndex == 1) ? @"drive" : @"walk"}];
            self.hasStart = YES;
            self.cur = curPos;
        } else {
            // 无当前位置（新设备第一次）：随机生成区域内入口锚点
// regionCenter 为 convertPoint 返回（瓦片系），与区域逻辑同系无需转换（2026-09-04 治理）
            double ang = (double)(arc4random_uniform(62832)) / 10000.0; // 0~2π
            double distM = self.regionRadiusM * (0.3 + (double)(arc4random_uniform(50)) / 100.0);
            double cosLat = cos(self.regionCenter.latitude * M_PI / 180.0);
            CLLocationCoordinate2D entryW = CLLocationCoordinate2DMake(
                self.regionCenter.latitude + distM * sin(ang) / 111320.0,
                self.regionCenter.longitude + distM * cos(ang) / (111320.0 * cosLat));
            [self.segments addObject:@{@"type": @"anchor",
                @"lat": @(entryW.latitude), @"lon": @(entryW.longitude),
                @"mode": (self.modeSeg.selectedSegmentIndex == 1) ? @"drive" : @"walk"}];
            self.hasStart = YES;
            self.cur = entryW;
        }
    }
    [self.segments addObject:seg];
    [self.regionPanel removeFromSuperview];
    self.regionPanel = nil;
    if (self.regionOverlay) { [self.mapView removeOverlay:self.regionOverlay]; self.regionOverlay = nil; }
    if (!self.hasStart) self.hasStart = YES;
    // 区域中心只是目标；当前位置图标：链首无前驱时 cur=区域内入口锚点（随上方插入设定），有前驱时不瞬移保持原位置
    [self updateStatus];
    [self syncSegmentsUI];
    [self runEdit:^{ [self commitItinerary]; }]; // 生成中挂起，完成后再生长，编辑不丢
}

#pragma mark - 定位开关 / 停止

/// 靶心按钮：聚焦到"当前位置目标"（两态随定位开关：定位中=模拟注入位置，停止=真实位置）
- (void)focusCurrentPosition:(UIButton *)sender {
    [self focusMapOnCurrentLocation];
}

/// 停止播放（2026-09-04 抽取：手动停止 toggleLocate 与轨迹播完复位 playbackDidFinish 共用同一路径——
/// 用户定案"播完=复位=与手动停止一致"）：复位播放态 UI + commitStop 写 off 通知 daemon，
/// App/daemon/plist 三方一致归停止态；位置订阅 locationd 不变（off 分支终点微动继续，注入始终运行）
- (void)stopPlayback {
    self.locating = NO;
    self.pendingEditAction = nil;    // 放弃生成中挂起的编辑（停止后不再生长/复活设备）
    self.stopTimestamp = [[NSDate date] timeIntervalSince1970]; // 停止时刻：只认晚于此的 fix（过滤停止前的旧 fix）
    self.startupLockedToAnchor = NO; // 停止即解锁（2026-09-04 治理：锁生命周期限定播放会话内，防跨状态残留）
    [self commitStop];
    self.mapView.userTrackingMode = MKUserTrackingModeNone; // 退出原生跟随（水滴随 locationd 当前位置）
    [self refreshUserLocationView];                          // 当前位置水滴去图标（未定位=纯绿点）
    [self resetFocusBaseline];                              // 重置自动聚焦基线（下一个 fix 触发聚焦）
    [self refreshWifiAnnotation];                            // 停止：立即更新 wifi 标注（不等下次系统扫描回调）
    [self _updateWifiStatusBar]; // wifi 状态栏刷新（切换模拟/真实 AP 显示）
    [self updateStatus];
}

- (void)toggleLocate:(UIButton *)sender {
    if (self.locating) {
        // 停止定位：位置停编排最后坐标（App 内保留显示），daemon 停 tick
        [self stopPlayback];
    } else {
        // 开启：有起点则 anchor，否则提示先设起点
        if (!self.hasStart) {
            [self setHint:@"请先点击地图设定模拟位置起点"];
            return;
        }
        // 可播放性判定（2026-09-04 设计层治理，纯几何派生无存储）：位置已在轨迹尽头
        // 且已离开起点 = 路线已播完卡在终点，无可继续播放的路径 → 播放按钮禁用（不切换状态）。
        // 往返路线（起终点重合）不受影响：位置距起点也近 → 判定不触发，可反复播放
        if (self.anchors.count >= 2) {
            CLLocationCoordinate2D startW = self.anchors.firstObject.coordinate;
            CLLocationCoordinate2D endW = self.anchors.lastObject.coordinate;
            double dEnd = [SimRouteCalculator haversineMeters:self.cur to:endW];
            double dStart = [SimRouteCalculator haversineMeters:self.cur to:startW];
            if (dEnd <= 25.0 && dStart > 25.0) {
                [self setHint:@"已在轨迹终点，无可继续播放的路径（编辑路线或重设锚点后可再播放）"];
                return;
            }
        }
        self.locating = YES;
        self.startTimestamp = [[NSDate date] timeIntervalSince1970]; // 开启时刻：只认晚于此的 fix（过滤开启前的旧 fix）
        self.startupLockedToAnchor = YES; // 开启瞬间到注入落地前：锁定锚点位置显示，忽略旧 fix（防"旧→锚点"横跳）
        // 原子写入：坐标 + 模式，一次 notify（daemon 模式切换已跳过 500ms 合并，立即执行）
        {
    [self commitSimPrefs:^(NSUserDefaults *d) {
        BOOL hasRoute = [[NSFileManager defaultManager] fileExistsAtPath:kTRSimTrackFilePath];
        [d setDouble:self.cur.latitude forKey:@"SimLocationLat"];
        [d setDouble:self.cur.longitude forKey:@"SimLocationLon"];
        [d setObject:hasRoute ? @"itinerary" : @"anchor" forKey:@"SimLocationMode"];
    }];
        }
        [self refreshUserLocationView];       // 当前位置水滴恢复出行图标
        // 停止后再开启：之前模拟位置（cur）距当前实际位置（lastFix=真实或残留）>500m → 瞬间跳回停止前位置（复用首锚点视野行为）；
        // 距离近（位置本就在附近/残留）不跳——维持"开启不主动聚焦"的常规语义
        if (self.lastFix) {
// self.cur 为瓦片系（2026-09-04 治理），lastFix 为 WGS fix → 转瓦片系后比较（同系）
            CLLocationCoordinate2D curW = self.cur;
if ((curW.latitude != 0 || curW.longitude != 0)
                && [SimRouteCalculator haversineMeters:curW to:[CoordTransform wgs84ToGcj02:self.lastFix.coordinate]] > kAutoFocusThresholdM) {
                [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(self.cur, 3000, 3000) animated:YES];
            }
        }
self.lastAutoFocusWGS = self.cur; // 自动聚焦基线=模拟位置（瓦片系，拖动退出 Follow 后模拟位置超阈值才拉回）
        self.mapView.userTrackingMode = MKUserTrackingModeFollow; // 原生跟随：MapKit 内部位置源持续订阅 locationd → 水滴跟随模拟位置（单一数据源）
        [self refreshWifiAnnotation];                            // 开启：立即切到模拟位置 wifi 标注（不等下次系统扫描回调）
        [self _updateWifiStatusBar]; // wifi 状态栏刷新（切换模拟/真实 AP 显示）
        [self updateStatus];
    }
    // 停止分支的刷新由 stopPlayback 统一执行（2026-09-04 抽取：手动停止与播完复位共用）
}

#pragma mark - 模式切换 / 搜索

- (void)modeChanged:(UISegmentedControl *)sender {
    // 模式影响后续 route/region 段的算路档；已在段提交时读取
    // 当前位置水滴内嵌的出行图标：跟随 currentLegMode（链上段模式），切胶囊本身不改当前位置图标；
    // 无链（currentLegMode 为空）时预览所选模式
    if (!self.currentLegMode) [self refreshUserLocationView];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    NSString *q = [searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!q.length) return;
    // 关键词 → 关联候选：走 MKLocalSearchCompleter 一次性拉取（2026-08-28 用户定案，
    // 替代 MKLocalSearch 直接搜索——地区名精确匹配只有 1~2 条；补全引擎出行政区/区县/POI 关联候选）；
    // 仅在点搜索时触发，不做输入逐字联想（区别于地图 App 的边输入边弹）
    self.searchCompleter.queryFragment = q;
}

/// 关联候选就绪（点搜索触发 completer 后的回调）
- (void)completerDidUpdateResults:(MKLocalSearchCompleter *)completer {
    NSArray *results = completer.results;
    if (!results.count) {
        self.searchResults = @[];
        [self.searchResultsView reloadData];
        self.searchResultsView.hidden = YES;
        [self setHint:@"未找到匹配地点"];
        return;
    }
    // 候选依次排开（下拉列表可滑动；最多 10 条）
    NSRange rng = NSMakeRange(0, MIN(10, (NSInteger)results.count));
    self.searchResults = [results subarrayWithRange:rng];
    [self.searchResultsView reloadData];
    self.searchResultsView.hidden = NO;
}

- (void)completer:(MKLocalSearchCompleter *)completer didFailWithError:(NSError *)error {
    self.searchResults = @[];
    [self.searchResultsView reloadData];
    self.searchResultsView.hidden = YES;
    [self setHint:@"搜索失败，请重试"];
}

/// 搜索框文本清空 → 收起结果列表
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (!searchText.length) {
        self.searchResultsView.hidden = YES;
    }
}

/// 搜索选中结果 → 添加锚点（与地图点击同构，无起点差别）
/// 第一个锚点无前驱 → 直接作为当前定位；后续锚点 → 从上一锚点生长路线
- (void)applySearchResult:(MKMapItem *)item {
// placemark.coordinate 为瓦片系（MKLocalSearch 与瓦片同系，2026-09-04 治理纠正），segments 存瓦片系
    CLLocationCoordinate2D wgs = item.placemark.coordinate;
    NSString *mode = (self.modeSeg.selectedSegmentIndex == 1) ? @"drive" : @"walk";
    [self.segments addObject:@{@"type": @"anchor", @"lat": @(wgs.latitude), @"lon": @(wgs.longitude), @"mode": mode}];
    if (self.segments.count == 1) {
        // 第一个锚点：判断是否有当前位置（持久化/注入的）
        CLLocationCoordinate2D curPos = [self currentSimPosition];
        BOOL hasCurPos = (curPos.latitude != 0 || curPos.longitude != 0);
        if (hasCurPos) {
            // 有当前位置：基于当前位置创建锚点（起点，消费），搜索位置作为终点 → 生成路线
            // curPos 为 WGS-84（currentSimPosition 契约）
            [self.segments insertObject:@{@"type": @"anchor", @"lat": @(curPos.latitude), @"lon": @(curPos.longitude), @"mode": mode}
                                atIndex:0];
            self.hasStart = YES;
            self.cur = curPos;   // 保持当前位置
            [self runEdit:^{ [self commitItinerary]; }];  // 生成 当前位置 → 搜索位置 路线
            [self setHint:@"已基于当前位置创建锚点 · 路线从当前位置生长"];
        } else {
            // 首次启动无当前位置：搜索点成为第一锚点+当前定位；聚焦但不开启模拟播放
            self.hasStart = YES;
            self.cur = wgs;
            self.startTimestamp = [[NSDate date] timeIntervalSince1970]; // 记开启时刻：过滤旧 fix
            self.startupLockedToAnchor = YES; // 锁定锚点显示，忽略旧位置（防"旧→新"横跳）
            // 不设 self.locating（保持 OFF）——首锚点只设位置，不开启模拟播放
            [self commitAnchor];
            [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(wgs, 3000, 3000) animated:YES];
self.lastAutoFocusWGS = wgs; // 自动聚焦基线（瓦片系，2026-09-04 治理）
            self.mapView.userTrackingMode = MKUserTrackingModeFollow; // 原生跟随（MKUserLocation 跟随 locationd 注入位置）
        }
    } else {
        // 后续锚点：不移动视野（保持当前位置聚焦），从上一位置生长（生成中挂起，编辑不丢）
        [self runEdit:^{ [self commitItinerary]; }];
    }
    [self updateStatus];
    [self syncSegmentsUI];            // 水滴锚点显示
    [self setHint:item.name ?: @"已添加锚点"];
}

#pragma mark - 状态 / 步骤 / 提示

- (void)setHint:(NSString *)hint {
    // 状态条短暂显示提示（UIButton 用 setTitle 渲染，titleLabel.text 直接赋值无效）
    [self.statusBtn setTitle:hint forState:UIControlStateNormal];
    [self.statusBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
}

- (void)updateStatus {
    // 坐标：强制绑定当前位置（locationd 单一真相，2026-08-24 定）——模拟中=注入位置 / 停止=真实位置，无"保留最后模拟坐标"回退
    CLLocationCoordinate2D showWgs = [self currentSimPosition];
    NSString *coordTxt = (showWgs.latitude == 0 && showWgs.longitude == 0)
        ? @"   --"
        : [NSString stringWithFormat:@"   %.5f, %.5f", showWgs.latitude, showWgs.longitude];
    NSString *speedTxt = @"0.0 m/s";
    // 2026-08-30：注入始终跑，无"停止"——移动中=路线播放，模拟中=静止注入
    // 状态文案订阅真实移动（2026-09-04 治理）：lastFix.speed 为 locationd 广播的实际速度
    // （daemon 注入轨迹点自带 speed 字段）——速度 >0.1 = 移动中；播放但速度≈0 = 驻留微动
    BOOL isMoving = self.lastFix && self.lastFix.speed > 0.1;
    NSString *modeTxt = self.locating ? (isMoving ? @"移动中" : @"驻留中") : @"模拟中";
    if (self.locating) {
        // 速度 = lastFix.speed（locationd 广播的实际速度，daemon 注入轨迹点自带 speed 字段）
        // （currentLegSpeed 为段配置速度，仅用于锚点图标，不作为实际移动速度显示）
        speedTxt = [NSString stringWithFormat:@"%.1f m/s", self.lastFix ? self.lastFix.speed : self.currentLegSpeed];
    }
    // 富文本：模式加粗 + 速度等宽灰 + 坐标等宽灰（对齐原型 stat .m/.spd/.c）
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] init];
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:modeTxt attributes:@{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:13],
        NSForegroundColorAttributeName: self.locating ? [UIColor systemBlueColor] : [UIColor labelColor],
    }]];
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"   %@", speedTxt] attributes:@{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: [UIColor secondaryLabelColor],
    }]];
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:coordTxt attributes:@{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: [UIColor secondaryLabelColor],
    }]];
    [self.statusBtn setAttributedTitle:as forState:UIControlStateNormal];
    // 状态圆点：移动中=绿（glow），模拟中=品牌蓝（注入中，2026-08-30 去掉"停止=灰"——注入始终跑）
    UIColor *simBlue = [UIColor colorWithRed:0.13 green:0.65 blue:0.97 alpha:1.0];
    self.statusDot.backgroundColor = self.locating ? [UIColor colorWithRed:0.11 green:0.79 blue:0.51 alpha:1.0] : simBlue;
    self.statusDot.layer.shadowColor = self.statusDot.backgroundColor.CGColor;
    self.statusDot.layer.shadowOpacity = self.locating ? 0.6 : 0.3;
    self.statusDot.layer.shadowRadius = 3;
    // FAB 状态切换：未开启=品牌紫+定位图标；定位中=铜钱（渐变金底+暗金描边+招财进宝四字+方孔——金色=进行中，与"待开启"紫区分）
    UIColor *brand = [UIColor colorWithRed:0.29 green:0.25 blue:0.89 alpha:1.0];
    if (self.locating) {
        [self.locateFab setBackgroundColor:[UIColor clearColor]];
        [self.locateFab setImage:nil forState:UIControlStateNormal];
        self.fabGoldGradient.hidden = NO;
        self.locateFab.layer.borderWidth = 1.5;
        self.locateFab.layer.borderColor = [UIColor colorWithRed:0.66 green:0.49 blue:0.03 alpha:1.0].CGColor; // 暗金描边（铜钱外缘）
        // 方孔镂空（evenOdd：圆 − 中心方孔 → 孔区透明露出页面背景，空心铜钱）
        CAShapeLayer *holeMask = [CAShapeLayer layer];
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 56, 56) cornerRadius:28];
        [path appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(22, 22, 12, 12)]];
        path.usesEvenOddFillRule = YES;
        holeMask.path = path.CGPath;
        holeMask.fillRule = kCAFillRuleEvenOdd;
        self.locateFab.layer.mask = holeMask;
        for (UILabel *lb in self.fabCoinLabels) lb.hidden = NO;
    } else {
        [self.locateFab setBackgroundColor:brand];
        [self.locateFab setImage:[UIImage systemImageNamed:@"location.fill"] forState:UIControlStateNormal];
        self.fabGoldGradient.hidden = YES;
        self.locateFab.layer.borderWidth = 0;
        self.locateFab.layer.mask = nil;
        for (UILabel *lb in self.fabCoinLabels) lb.hidden = YES;
    }
}

- (void)toggleSteps:(UIButton *)sender {
    self.expanded = !self.expanded;
    self.stepTable.hidden = !self.expanded;
}

/// 编排段变化后统一刷新：步骤列表 + 锚点（路线只由锚点间生长线呈现，无虚线预览）
- (void)syncSegmentsUI {
    [self.stepTable reloadData];
    [self rebuildAnchors];
    [self updateAnchorPassStateWithLiveWGS:[self currentSimPosition]]; // 新增/删除/排序后立即对齐状态色
}

- (void)reloadSteps {
    [self.stepTable reloadData];
}

#pragma mark - 锚点系统（每段终点/中心地图锚点，点击删除该段，路线自适应）

- (void)rebuildAnchors {
    // 2026-08-30 修复：重建前按 segmentIndex 保存旧 passed（红锚点不因重建丢失——
    // 播放中 syncSegmentsUI 频繁重建，旧实现重建后全蓝 + 25m 距离重算 → 远离的红锚点"消失"）
    NSMutableDictionary *oldPassed = [NSMutableDictionary dictionary];
    for (TRAnchorAnnotation *oldA in self.anchors) {
        oldPassed[@(oldA.segmentIndex)] = @(oldA.passed);
    }
    for (TRAnchorAnnotation *a in self.anchors) [self.mapView removeAnnotation:a];
    [self.anchors removeAllObjects];
    for (NSUInteger i = 0; i < self.segments.count; i++) {
        NSDictionary *seg = self.segments[i];
        NSString *type = seg[@"type"];
        CLLocationCoordinate2D c = self.cur;
        if ([type isEqualToString:@"anchor"]) {
            c = CLLocationCoordinate2DMake([seg[@"lat"] doubleValue], [seg[@"lon"] doubleValue]);
        } else if ([type isEqualToString:@"route"]) {
            c = CLLocationCoordinate2DMake([seg[@"to"][@"lat"] doubleValue], [seg[@"to"][@"lon"] doubleValue]);
        } else if ([type isEqualToString:@"region"]) {
            c = CLLocationCoordinate2DMake([seg[@"center"][@"lat"] doubleValue], [seg[@"center"][@"lon"] doubleValue]);
        }
        TRAnchorAnnotation *a = [[TRAnchorAnnotation alloc] init];
        a.coordinate = c;
        a.segmentIndex = (NSInteger)i;
        a.type = type;
        a.mode = seg[@"mode"] ?: (self.modeSeg.selectedSegmentIndex == 1 ? @"drive" : @"walk"); // 该锚点生成时的出行方式
        a.passed = [oldPassed[@(i)] boolValue]; // 迁移旧 passed（同索引锚点保持已消费状态）
        [self.anchors addObject:a];
        [self.mapView addAnnotation:a];
    }
}

/// 段目标锚点坐标（WGS；anchor 用 lat/lon，旧 route 兼容 to）
/// segments 统一存瓦片系（与算路 API 同系，2026-09-04 治理），直接喂 MKDirections 不转换
- (CLLocationCoordinate2D)anchorWGSOfSegment:(NSDictionary *)seg {
    if ([seg[@"type"] isEqualToString:@"region"]) {
        // region 段目标锚点 = 区域中心（region 段无 lat/lon，缺失此分支会取到 (0,0) → 涉及 region 段的编辑路线乱连）
        return CLLocationCoordinate2DMake([seg[@"center"][@"lat"] doubleValue], [seg[@"center"][@"lon"] doubleValue]);
    }
    if ([seg[@"to"] isKindOfClass:[NSDictionary class]]) {
        return CLLocationCoordinate2DMake([seg[@"to"][@"lat"] doubleValue], [seg[@"to"][@"lon"] doubleValue]);
    }
    return CLLocationCoordinate2DMake([seg[@"lat"] doubleValue], [seg[@"lon"] doubleValue]);
}

/// 删除第 idx 锚点（2026-08-30 用户定案 v2：绿=消费中禁删，蓝/红可删）：
/// - 红（已消费，路线走完）：可删
/// - 绿（消费中：当前路段出发锚点 或 终点锚点）：禁删——统一覆盖"终点禁删"，无特例
/// - 蓝（未消费，非当前路段）：可删（复用补插位逻辑：重算上一个锚点和下一个锚点的路线并更新 json）
/// 锚点链顺序语义——删锚 k 只重算跨过它的连接段（前驱→后继），
/// 其余段点序列缓存与生长线保留；删首=当前位置作起点、删尾=轨迹截断保持当前位置
- (void)deleteSegmentAt:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.segments.count) return;
    // 找目标锚点
    TRAnchorAnnotation *targetAnchor = nil;
    for (TRAnchorAnnotation *a in self.anchors) {
        if (a.segmentIndex == idx) { targetAnchor = a; break; }
    }
    if (targetAnchor && targetAnchor.consuming) {
        // 绿：消费中（出发锚点 或 当前路段终点）——禁止删除
        [self setHint:@"该锚点正在消费中（绿色，含终点），暂不可删除"];
        return;
    }
    // 播放中：消费中路线的前后锚点一并禁删（2026-09-04 用户决策）——
    // 消费中段（绿锚点所在段）正在播放推进，删除其出发/终点锚点会打断当前段重算，
    // 触发 hold 驻留致播放中断感；停止态编辑自由不受限
    if (self.locating) {
        TRAnchorAnnotation *consumingAnchor = nil;
        for (TRAnchorAnnotation *a in self.anchors) {
            if (a.consuming && !a.passed) { consumingAnchor = a; break; }
        }
        if (consumingAnchor) {
            NSInteger sC = consumingAnchor.segmentIndex;
            if (idx == sC || idx == sC - 1) {
                [self setHint:@"播放中不可删除当前消费中路线的前后锚点（绿及其出发锚点）"];
                return;
            }
        }
    }
    // 红（已消费路线走完）/ 蓝（未消费）：可删——蓝走补插位逻辑（下方删锚 k 只重算前驱→后继段）
    NSDictionary *removed = self.segments[idx];
    if ([removed[@"type"] isEqualToString:@"region"]) {
        // 区域段删除 → 该区域不再生长，同步清途经点标注
        for (TRWaypointAnnotation *w in self.waypointAnns) [self.mapView removeAnnotation:w];
        [self.waypointAnns removeAllObjects];
    }
    [self.segments removeObjectAtIndex:idx];
    // 段点序列同步删（索引对齐 segments：段 i 目标=segments[i]；删锚点 idx 后旧段 idx+1 前移到 idx）
    if (idx < (NSInteger)self.segmentPoints.count) {
        [self.segmentPoints removeObjectAtIndex:idx];
    }
    if (!self.segments.count) {
        // 全部锚点删除 → 停止定位并同步停止 daemon（写 mode=off，设备恢复真实定位），避免 App 停止但设备仍被模拟
        self.hasStart = NO;
        self.locating = NO;
        self.pendingEditAction = nil;    // 清挂起编辑（空链无需再生成）
        self.stopTimestamp = [[NSDate date] timeIntervalSince1970]; // 记停止时刻（同 toggleLocate）
        [self commitStop];
        [self.segmentPoints removeAllObjects];
        for (id o in self.mapView.overlays) {
            if ([o isKindOfClass:[TRGrowPolyline class]]) [self.mapView removeOverlay:o];
        }
        self.mapView.userTrackingMode = MKUserTrackingModeNone; // 退出原生跟随
        [self refreshUserLocationView];                          // 当前位置水滴去出行图标（=真实位置纯绿点）
        [self resetFocusBaseline];                              // 重置自动聚焦基线（下一个 fix 触发聚焦）
        [self setHint:@"已清空行程 · 停止模拟定位"];
        [self updateStatus];
        [self syncSegmentsUI];
    [self writeTrackFile:@[]]; // 删光同步清编排契约文件——否则重开 App restoreSession 恢复出幽灵锚点（2026-09-04 实测修复）
        return;
    }
    // 跨过被删锚点的合并段标记待生成；删链尾则无（轨迹截断到上一锚点）
    if (idx < (NSInteger)self.segments.count) {
        if (idx == 0) {
            // 删首锚点：看当前位置是否还在首锚路线上（以"距新首锚是否已消费"判定，阈值同经过判定 25m）——
            // 已到达新首锚（首锚路线完全消费）→ 直接删除（段 0 不生成，轨迹从新首锚继续，daemon 自当前位置续播）；
            // 仍在路上 → 当前位置作新起点，段 0（当前位置→新首锚）待生成
            CLLocationCoordinate2D newHeadW = [self anchorWGSOfSegment:self.segments[0]];
            CLLocationCoordinate2D curW = [self currentSimPosition];
            self.segmentZeroPending = ([SimRouteCalculator haversineMeters:curW to:newHeadW] >= 25.0);
        }
        if (idx >= (NSInteger)self.segmentPoints.count) {
            [self.segmentPoints addObject:[NSNull null]];
        } else {
            self.segmentPoints[idx] = [NSNull null];
        }
    }
    [self updateStatus];
    [self syncSegmentsUI];
    // 顺序补齐：只重算标记段（其余段点序列缓存保留），无全量重算
    [self runEdit:^{ [self syncChainAndGenerate]; }];
}

/// 拖拽排序：只重排 segments + 段点序列缓存（按"起点/目标锚点对"匹配保留），邻接变化的段标记待生成，顺序补齐
- (void)moveSegmentFrom:(NSInteger)from to:(NSInteger)to {
    if (from < 0 || to < 0 || from >= (NSInteger)self.segments.count || to >= (NSInteger)self.segments.count || from == to) return;
    NSDictionary *item = self.segments[from];
    NSArray *prevSegments = [self.segments copy];   // 重排前链（锚点邻接对比）
    NSArray *prevSegPoints = [self.segmentPoints copy]; // 重排前段点序列缓存
    [self.segments removeObjectAtIndex:from];
    [self.segments insertObject:item atIndex:to];
    // 段点序列按"起点/目标锚点对"重排：锚点邻接不变的段保留旧点序列（不重算），变化的段标记待生成
    NSMutableArray *newSegPoints = [NSMutableArray arrayWithCapacity:self.segments.count];
    for (NSInteger i = 0; i < (NSInteger)self.segments.count; i++) {
        if (i == 0) {
            // 段 0：链首未变则保留旧序列（prevSegPoints[0] 可能 NSNull=正常链无段 0），变化则待生成（由 segmentZeroPending 标记）
            [newSegPoints addObject:(prevSegPoints.count ? prevSegPoints[0] : [NSNull null])];
            continue;
        }
        BOOL found = NO;
        for (NSInteger j = 1; j < (NSInteger)prevSegments.count; j++) {
            if ([self sameAnchor:self.segments[i - 1] b:prevSegments[j - 1]] &&
                [self sameAnchor:self.segments[i] b:prevSegments[j]]) {
                [newSegPoints addObject:(j < (NSInteger)prevSegPoints.count ? prevSegPoints[j] : [NSNull null])];
                found = YES;
                break;
            }
        }
        if (!found) [newSegPoints addObject:[NSNull null]]; // 邻接变化 → 待生成
    }
    // 段 0（删首后：当前位置→首锚）：仅当段 0 已存在（删首过）且链首锚点变化时标记重算；正常链/拖拽不产生段 0
    if (prevSegPoints.count && [prevSegPoints[0] isKindOfClass:[NSArray class]]) {
        self.segmentZeroPending = !(prevSegments.count && [self sameAnchor:self.segments[0] b:prevSegments[0]]);
    }
    self.segmentPoints = newSegPoints;
    [self syncSegmentsUI];
    // 顺序补齐：只重算标记段，其余段点序列缓存保留，无全量重算
    [self runEdit:^{ [self syncChainAndGenerate]; }];
}

/// 两段锚点坐标是否相同（anchor 段存 lat/lon、region 段存 center，各自取坐标值比较）
- (BOOL)sameAnchor:(NSDictionary *)a b:(NSDictionary *)b {
    CLLocationCoordinate2D aW = [self anchorWGSOfSegment:a];
    CLLocationCoordinate2D bW = [self anchorWGSOfSegment:b];
    return aW.latitude == bW.latitude && aW.longitude == bW.longitude;
}

#pragma mark - 基于当前位置的局部重算（manager 注入写回 mobile plist 为当前位置真相）

/// 读当前位置（WGS）——权威 = 最近一次通过过滤的回调 fix（lastFix，locationd 广播值，不读 locationManager 属性缓存）；
/// 播放/停止同一来源（注入位置），无 fix 时回退 self.cur（统一瓦片系，2026-09-04 治理）
- (CLLocationCoordinate2D)currentSimPosition {
    // lastFix 为 WGS fix（locationd 语义）→ 转瓦片系与 segments 同系；self.cur 已是瓦片系
    if (self.lastFix) return [CoordTransform wgs84ToGcj02:self.lastFix.coordinate];
    return self.cur;
}

/// 停止定位后只记录自动聚焦基线（停止瞬间位置=模拟残留）——不主动聚焦：
/// 聚焦完全交给订阅驱动（首个 fix 距基线超阈值 → maybeAutoFocus 自动聚焦）
- (void)resetFocusBaseline {
    self.lastAutoFocusWGS = [self currentSimPosition];
}

/// 自动聚焦（距离阈值）：当前位置距上次自动聚焦点 ≥ 阈值才聚焦一次并更新基线。
/// 基线未初始化（启动时 lastAutoFocusWGS=(0,0)）→ 首个位置建立基线并聚焦（打开 APP 聚焦当前位置）；
/// 已初始化 → 残留位置（≈基线）不触发、大幅位移（模拟出视野）必触发、GPS 抖动（<50m）不打扰
- (void)maybeAutoFocus:(CLLocationCoordinate2D)wgs {
    BOOL uninitialized = (self.lastAutoFocusWGS.latitude == 0 && self.lastAutoFocusWGS.longitude == 0);
    if (!uninitialized && [SimRouteCalculator haversineMeters:wgs to:self.lastAutoFocusWGS] < kAutoFocusThresholdM) return;
// 参数为瓦片系（2026-09-04 治理：调用方传 mapCoord），setRegion 为 MapKit 显示层 API 同系直接用
// 参数为瓦片系（2026-09-04 治理：调用方传 mapCoord），setRegion 为 MapKit 显示层 API 同系直接用
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(wgs, 3000, 3000) animated:YES];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.fabGoldGradient.frame = self.locateFab.bounds; // 渐变金底随 FAB 布局同步（创建时 bounds 为 0，必须布局后更新，否则铜钱背景近乎透明）
}

/// 地图立即聚焦到当前位置（首锚点/启动定位/停止/回前台时调用）
/// 定位中=聚焦 self.cur（模拟位置，App 已知锚点）；未定位=GPS 活跃订阅真实位置优先，无 GPS 用 wifi 真实位置兜底
/// 瓦片系口径（2026-09-04 治理）：currentSimPosition 已转瓦片系；wifiCurWGS 系别悬案待真机裁决
- (void)focusMapOnCurrentLocation {
    CLLocationCoordinate2D center = self.locating ? self.cur : [self currentSimPosition];
    // GPS 无 fix（locationd 未就绪）→ wifi 位置兜底（wifiCurWGS，真实 wifi 反查质心）
    if (center.latitude == 0 && center.longitude == 0) {
        center = self.wifiCurWGS;
    }
    // 守卫：位置无效（从未设过且 locationd/wifi 均未就绪）→ 不聚焦，保持当前视野
    if (center.latitude == 0 && center.longitude == 0) return;
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(center, 3000, 3000) animated:YES];
}

/// 刷新当前位置（原生 MKUserLocation）水滴外观：绿色 + 出行方式图标（定位中显示图标，未定位纯绿点）
- (void)refreshUserLocationView {
    MKAnnotationView *uv = [self.mapView viewForAnnotation:self.mapView.userLocation];
    if (!uv) return;
    NSString *mode = self.currentLegMode ?: (self.modeSeg.selectedSegmentIndex == 1 ? @"drive" : @"walk");
    UIColor *green = [UIColor colorWithRed:0.11 green:0.79 blue:0.51 alpha:1.0];
    uv.image = [self waterdropImageWithColor:green size:24 emoji:(self.locating ? [self emojiForMode:mode] : @"")];
}

/// 系统定位服务是否可用（决定水滴消费方式：开=MKUserLocation 走 locationd GPS 层，关=自驱水滴跟编排位置 self.cur）
- (BOOL)_systemLocationAvailable {
    CLAuthorizationStatus st = [CLLocationManager authorizationStatus];
    return (st == kCLAuthorizationStatusAuthorizedWhenInUse || st == kCLAuthorizationStatusAuthorizedAlways);
}



#pragma mark - CLLocationManagerDelegate（真实定位）

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    CLAuthorizationStatus st = manager.authorizationStatus;
    if (st == kCLAuthorizationStatusAuthorizedWhenInUse || st == kCLAuthorizationStatusAuthorizedAlways) {
        // 建立 App 自己的活跃位置请求（关键，2026-08-24 根因）：locationd 只在存在活跃请求时持续计算并广播——
        // 仅 showsUserLocation=YES（MapKit 内部位置源）不构成活跃请求，实测"系统地图打开才激活我们 App"；
        // startUpdatingLocation 是持续订阅（Apple DTS 确认不自动停），locationd 持续推 → 不依赖外部 App 激活
        [manager startUpdatingLocation];
    } else if ((st == kCLAuthorizationStatusDenied || st == kCLAuthorizationStatusRestricted) && !self.hasPromptedLocationAuth) {
        // 当前位置显示依赖定位授权（模拟时=模拟位置）；拒绝则地图当前位置不可见 → 一次性引导
        self.hasPromptedLocationAuth = YES;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"需要定位权限"
            message:@"地图上的当前位置显示依赖定位权限（模拟定位时显示模拟位置）。请在 设置 → 隐私与安全性 → 定位服务 中开启。"
            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"去设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
            if (url && [[UIApplication sharedApplication] canOpenURL:url]) {
                [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            }
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

/// 定位失败回调（原生能力利用）：定位错误（权限拒绝/无定位源/模拟注入异常）不再静默——
/// 记录日志便于排查（权限拒绝的 UI 提示由 locationManagerDidChangeAuthorization 负责，此处不重复）
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    NSLog(@"[locsim] locationManager failed: code=%ld %@", (long)error.code, error.localizedDescription);
}

/// 当前位置统一处理（主驱动，2026-08-24）：App 自己的活跃订阅（startUpdatingLocation）推送 → 状态栏/锚点/聚焦/self.cur。
/// locationd 对活跃请求持续广播，与水滴（MKMapView 内部位置源）同源。
/// 时间戳分辨新旧（2026-08-24）：开启/停止瞬间有"旧状态残留"抢跑（停止前旧 fix/开启前旧 fix），
/// 每个 fix 自带出生时间（CLLocation.timestamp，系统盖章），只认晚于对应切换时刻的 fix——旧货当没看见
- (void)handleLocationUpdate:(CLLocation *)loc {
    if (!loc) return;
    // 坐标系边界转换（2026-09-04 治理）：locationd 广播 = WGS-84 语义（注入出口已转 WGS/真实 GPS 亦 WGS），
    // 编排世界（锚点/路线/25m 锁基线/self.cur）= 地图瓦片系——入口统一 WGS→GCJ，函数内全部用 mapCoord
    // （与锚点/锁/经过判定/聚焦同系；水滴 MKUserLocation 由 MapKit 自动偏移，不走此路径）
    CLLocationCoordinate2D mapCoord = [CoordTransform wgs84ToGcj02:loc.coordinate];
    if (self.locating) {
        // 播放态：只认晚于开启时刻的 fix——过滤开启前的旧 fix
        if ([loc.timestamp timeIntervalSince1970] < self.startTimestamp) return;
        // 开启锁定：注入落地前 locationd 广播的还是旧位置——距锚点 >25m 的 fix 忽略（保持锚点显示，防"旧→锚点"横跳）；
        // 注入落地后 fix≈锚点（<25m）→ 解锁，恢复 fix 驱动。
        // self.cur 无效（0,0，新装未收到过任何 fix）时跳过锁定——无效基线无"横跳"可言，否则永锁（2026-09-04 实测死锁修复）
        if (self.startupLockedToAnchor
            && (self.cur.latitude != 0 || self.cur.longitude != 0)) {
            double d = [SimRouteCalculator haversineMeters:mapCoord to:self.cur];
            if (d > 25.0) return;
            self.startupLockedToAnchor = NO;
        }
        self.lastFix = loc; // 记录回调 fix（原始 WGS 对象；坐标/速度真相源，不读属性缓存）
        self.cur = mapCoord; // self.cur 统一存瓦片系（与锚点/路线/算路同系，2026-09-04 治理）
        [self _updateWifiStatusBar]; // wifi 状态栏刷新（模拟位置/模拟AP）
        [self _refreshWifiAnnoFromCurrentConnection]; // wifi 水滴标注更新
        [self updateAnchorPassStateWithLiveWGS:mapCoord]; // 先更新段速度/经过态，状态栏立即反映
        [self updateStatus];
        // 自动聚焦：Follow 原生已跟随无需重复；用户拖动退出 Follow 后模拟位置距上次聚焦点超阈值则拉回
        if (self.mapView.userTrackingMode != MKUserTrackingModeFollow) [self maybeAutoFocus:mapCoord];
        return;
    }
    // 停止态：只认晚于停止时刻的 fix——过滤停止前的旧 fix
    if ([loc.timestamp timeIntervalSince1970] <= self.stopTimestamp) return;
    // 首锚点锁定（2026-08-30）：创建锚点后注入落地前，locationd 广播的还是旧位置——
    // 距新锚点 >25m 的 fix 忽略（保持锚点位置显示，防"旧→新"横跳）；注入落地后 fix≈锚点（<25m）→ 解锁。
    // self.cur 无效（0,0）时跳过锁定（同播放态死锁修复）
    if (self.startupLockedToAnchor
        && (self.cur.latitude != 0 || self.cur.longitude != 0)) {
        double d = [SimRouteCalculator haversineMeters:mapCoord to:self.cur];
        if (d > 25.0) return;
        self.startupLockedToAnchor = NO;
    }
    self.lastFix = loc; // 记录回调 fix
    // 更新当前位置（首锚点注入落地后，self.cur 跟随 locationd 注入位置；瓦片系统一存储）
    self.cur = mapCoord;
    [self updateAnchorPassStateWithLiveWGS:mapCoord]; // 停止态也更新三态（passed 单调：红锚点保持红，仅反映位置新经过）
[self _refreshWifiAnnoFromCurrentConnection]; // wifi 标注 fix 驱动刷新（BSSID 增量比对）
    [self updateStatus];
    // 自动聚焦（距离阈值）：fix 距停止瞬间基线超阈值才聚焦——
    // 旧 fix（≈基线）不触发、新 fix（画布外）必触发；GPS 收敛渐进超阈值再拉回
    [self maybeAutoFocus:mapCoord];
}

/// App 自己的活跃订阅回调（locationd 广播）：唯一驱动
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    [self handleLocationUpdate:locations.lastObject];
}

/// 锚点状态刷新（O(锚点数)，修复全量轨迹扫描卡顿）：当前位置距锚点 < 阈值视为"到达"（passed 单调不回退，
/// 2026-08-30 修复：旧实现可回退致播放远离后红锚点"消失"）；三态消费状态（2026-08-30 用户定案 v2）：
/// - 蓝（未消费）：不在当前路段上（未到达且非终点）
/// - 绿（消费中）：当前路段两端——出发锚点（已到达，正在走它出发的路段）**或终点锚点**（下一锚点，即将到达）
/// - 红（已消费）：已到达且路线已走完（非当前段出发锚点 / 链尾）
/// 绿=消费中禁删统一覆盖"终点禁删"（删除规则只需判 consuming，无特例）
/// 锚点红蓝绿 + 当前位置水滴出行图标切换。轨迹单向推进（算路生成），无需按轨迹索引判定——
/// 旧实现每刷新对每个锚点全量遍历 submittedPoints 找最近索引（区域轨迹可达数万点 → 主线程 O(A×P) haversine 卡死）
/// liveW 为当前位置（瓦片系，调用方 handleLocationUpdate 已转）；仅定位中生效（停止态颜色定格）
- (void)updateAnchorPassStateWithLiveWGS:(CLLocationCoordinate2D)liveW {
    // 2026-08-30：不依赖 locating——有当前位置即更新锚点三态（首锚点后 locating=NO 也生效：
    // 基于当前位置创建的锚点立即标红=已消费，点击位置锚点保持蓝=待消费）
    if (self.anchors.count == 0) return;
    static const double kPassedThresholdM = 25.0; // 距锚点 25m 内视为到达（停留微动 ±1m 远小于阈值，锚点间距通常 >50m）
    // 第一遍：passed 单调置位（到达过即到达过，不回退——防播放远离后红锚点消失）
    for (TRAnchorAnnotation *a in self.anchors) {
// a.coordinate 来自 rebuildAnchors（segments 瓦片系），直接使用（2026-09-04 治理）
        CLLocationCoordinate2D aW = a.coordinate;
        BOOL reached = [SimRouteCalculator haversineMeters:liveW to:aW] < kPassedThresholdM;
        if (reached) a.passed = YES; // 单调：只置 YES，不回退
    }
    // 第二遍：找当前段出发锚点（已到达且下一锚点未到达；链尾视为路线走完非出发锚点）
    TRAnchorAnnotation *departAnchor = nil; // 当前段出发锚点
    for (NSUInteger i = 0; i < self.anchors.count; i++) {
        TRAnchorAnnotation *a = self.anchors[i];
        BOOL nextPassed = (i + 1 < self.anchors.count) ? ((TRAnchorAnnotation *)self.anchors[i + 1]).passed : YES; // 链尾=已消费
        if (a.passed && !nextPassed) { departAnchor = a; break; } // 第一个满足 = 当前位置所在段的出发锚点
    }
    // 第三遍：consuming = 出发锚点 + 终点锚点（当前路段两端，删除守卫用）；颜色：绿=终点（即将到达）/红=已到达（含出发锚点+已走完）/蓝=未消费
    for (TRAnchorAnnotation *a in self.anchors) {
        a.consuming = (a == departAnchor)
            || (departAnchor && a.segmentIndex == departAnchor.segmentIndex + 1); // 终点锚点=下一锚点（消费中）
        UIColor *stateColor = nil;
        if (a.consuming && !a.passed) {
            stateColor = [UIColor colorWithRed:0.11 green:0.79 blue:0.51 alpha:1.0]; // 绿：终点锚点（即将到达，消费中）
        } else if (a.passed) {
            stateColor = [UIColor colorWithRed:0.94 green:0.23 blue:0.13 alpha:1.0]; // 红：已消费（出发锚点/已走完）
        } else {
            stateColor = [UIColor colorWithRed:0.13 green:0.65 blue:0.97 alpha:1.0]; // 蓝（未消费）
        }
        MKAnnotationView *v = [self.mapView viewForAnnotation:a];
        if (v) v.image = [self waterdropImageWithColor:stateColor size:22 emoji:[self emojiForMode:a.mode]];
    }
    // 当前位置出行方式：取当前段出发锚点的出行方式；无出发锚点（链首未消费/全消费）退回首个锚点或当前选择
    NSString *mode = departAnchor ? departAnchor.mode
                                  : (self.anchors.count ? ((TRAnchorAnnotation *)self.anchors.firstObject).mode : nil);
    mode = mode ?: (self.modeSeg.selectedSegmentIndex == 1 ? @"drive" : @"walk");
    if (![self.currentLegMode isEqualToString:mode]) {
        self.currentLegMode = mode;
        [self refreshUserLocationView]; // 当前位置水滴切换出行图标（原生 MKUserLocation 视图）
    }
    // 当前段速度：从段缓存取"当前位置所在段"首点生成速度（出发锚点→下一锚点）
    [self updateCurrentLegSpeedWithDepart:departAnchor mode:mode];
}

/// 当前段速度 = 段缓存中"当前位置所在段"首点生成的 speed（含 ±10% 抖动；random 段反映实际随机模式）——
/// 从内存段缓存索引取（非序列化、非最近点扫描）；段无效/未生成时回退模式平均
- (void)updateCurrentLegSpeedWithDepart:(TRAnchorAnnotation *)departAnchor mode:(NSString *)mode {
    NSInteger segIdx = departAnchor ? departAnchor.segmentIndex + 1 : 1; // 当前段 = 出发锚点→下一锚点（无已过锚点=首锚路线=段 1）
    double speed = 0;
    if (segIdx >= 1 && segIdx < (NSInteger)self.segmentPoints.count) {
        id pts = self.segmentPoints[segIdx];
        if ([pts isKindOfClass:[NSArray class]] && ((NSArray *)pts).count) {
            NSNumber *sp = ((NSArray *)pts).firstObject[@"speed"];
            if ([sp isKindOfClass:[NSNumber class]]) speed = [sp doubleValue];
        }
    }
    if (speed <= 0) speed = [RegionSimulator effectiveSpeedForMode:mode];
    self.currentLegSpeed = speed;
}

#pragma mark - UITableViewDataSource / Delegate（步骤列表：删除 + 拖拽排序）

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.searchResultsView) return (NSInteger)self.searchResults.count;
    return (NSInteger)self.segments.count; // 无锚点时显示空白（不设占位行）
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 搜索下拉结果列表
    if (tableView == self.searchResultsView) {
        static NSString *rid = @"SearchCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
            cell.textLabel.font = [UIFont systemFontOfSize:14];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        }
        id obj = self.searchResults[indexPath.row];
        if ([obj isKindOfClass:[MKMapItem class]]) {
            cell.textLabel.text = ((MKMapItem *)obj).name ?: @"地点";
            cell.detailTextLabel.text = ((MKMapItem *)obj).placemark.title ?: @"";
        } else {
            MKLocalSearchCompletion *c = obj;
            cell.textLabel.text = c.title;
            cell.detailTextLabel.text = c.subtitle;
        }
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    static NSString *rid = @"SegCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
        // 左：消费状态圆点（2026-08-30 用户定案：替代原拖拽排序图标——列表开始处显示 蓝(未消费)/绿(消费中)/红(已消费)）
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(14, 14, 10, 10)];
        dot.tag = 201;
        dot.layer.cornerRadius = 5;
        dot.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin;
        [cell.contentView addSubview:dot];
        // 标题 / 副标题（自绘，避开左侧状态圆点；删除走系统原生右滑，无自绘删除按钮）
        UILabel *tl = [[UILabel alloc] init];
        tl.tag = 203;
        tl.font = [UIFont systemFontOfSize:12];
        tl.frame = CGRectMake(42, 5, cell.contentView.bounds.size.width - 56, 18);
        tl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleRightMargin;
        [cell.contentView addSubview:tl];
        UILabel *sl = [[UILabel alloc] init];
        sl.tag = 204;
        sl.font = [UIFont systemFontOfSize:10];
        sl.textColor = [UIColor secondaryLabelColor];
        sl.frame = CGRectMake(42, 23, cell.contentView.bounds.size.width - 56, 14);
        sl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleRightMargin;
        [cell.contentView addSubview:sl];
    }
    cell.userInteractionEnabled = YES;
    NSDictionary *seg = self.segments[indexPath.row];
    NSString *type = seg[@"type"];
    NSString *title = @"";
    NSString *sub = @"";
    if ([type isEqualToString:@"anchor"]) {
        title = @"锚点";
// segments 存瓦片系（2026-09-04 治理），直接取值显示
        CLLocationCoordinate2D w = CLLocationCoordinate2DMake([seg[@"lat"] doubleValue], [seg[@"lon"] doubleValue]);
        sub = [NSString stringWithFormat:@"%.4f, %.4f", w.latitude, w.longitude];
    } else {
        title = @"区域漫游";
        sub = [NSString stringWithFormat:@"%.0f m · %@ min", [seg[@"radius"] doubleValue], seg[@"durationMin"]];
    }
    ((UILabel *)[cell.contentView viewWithTag:203]).text = [NSString stringWithFormat:@"%ld  %@", (long)(indexPath.row + 1), title];
    ((UILabel *)[cell.contentView viewWithTag:204]).text = sub;
    // 状态圆点颜色 = 该锚点消费状态（蓝未消费/绿消费中/红已消费；region 段目标=区域中心同规则）
    UIView *dot = [cell.contentView viewWithTag:201];
    dot.hidden = NO;
    TRAnchorAnnotation *rowAnchor = nil;
    for (TRAnchorAnnotation *a in self.anchors) {
        if (a.segmentIndex == (NSInteger)indexPath.row) { rowAnchor = a; break; }
    }
    UIColor *stateColor = [UIColor secondaryLabelColor];
    if (rowAnchor) {
        if (rowAnchor.consuming && !rowAnchor.passed) {
            stateColor = [UIColor colorWithRed:0.11 green:0.79 blue:0.51 alpha:1.0]; // 绿：终点锚点（即将到达，消费中）
        } else if (rowAnchor.passed) {
            stateColor = [UIColor colorWithRed:0.94 green:0.23 blue:0.13 alpha:1.0]; // 红：已消费（出发锚点/已走完）
        } else {
            stateColor = [UIColor colorWithRed:0.13 green:0.65 blue:0.97 alpha:1.0]; // 蓝（未消费）
        }
    }
    dot.backgroundColor = stateColor;
    return cell;
}

/// 选中搜索结果 → 直接定位为当前位置 + 清空输入框 + 收起列表
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (tableView == self.searchResultsView) {
        id obj = self.searchResults[indexPath.row];
        self.searchBar.text = @"";              // 清空搜索输入框
        [self.searchBar resignFirstResponder];
        self.searchResultsView.hidden = YES;
        if ([obj isKindOfClass:[MKMapItem class]]) {
            [self applySearchResult:obj];       // 已有坐标：直接加锚点
            return;
        }
        // completer 候选无坐标：补一次 MKLocalSearch 解析成 MKMapItem 再落锚点（2026-08-28）。
        // 注：initWithCompletion: 是 iOS 18 SDK 才有的初始化器，bootstrap 用 16.5 SDK 编译 App target
        // 报 no visible @interface——用 request + title/subtitle 自然语言查询兜底（16.5 SDK 兼容）
        MKLocalSearchCompletion *cc = (MKLocalSearchCompletion *)obj;
        MKLocalSearchRequest *req = [[MKLocalSearchRequest alloc] init];
        req.naturalLanguageQuery = [NSString stringWithFormat:@"%@ %@", cc.title, cc.subtitle];
        MKLocalSearch *ls = [[MKLocalSearch alloc] initWithRequest:req];
        [ls startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error || !response.mapItems.count) {
                    [self setHint:@"无法定位该地点"];
                    return;
                }
                [self applySearchResult:response.mapItems.firstObject];
            });
        }];
        return;
    }
    // 状态栏行程列表：点击聚焦到该行锚点（anchor=锚点坐标，region=区域中心）
    if (tableView == self.stepTable && indexPath.row >= 0 && indexPath.row < (NSInteger)self.segments.count) {
        CLLocationCoordinate2D wgs = [self anchorWGSOfSegment:self.segments[indexPath.row]];
// wgs 为瓦片系（self.cur 同系），plist 写瓦片系数值——daemon injectPoint 出口统一 GCJ→WGS（2026-09-04）
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(wgs, 2000, 2000) animated:YES];
    }
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.searchResultsView) return UITableViewCellEditingStyleNone;
    return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.stepTable && editingStyle == UITableViewCellEditingStyleDelete) {
        [self deleteSegmentAt:indexPath.row];
    }
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    // 2026-08-30 用户定案：移除拖拽排序能力（状态栏列表开始处改显消费状态圆点，不再支持排序）
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    if (tableView == self.stepTable) {
        [self moveSegmentFrom:from.row to:to.row];
    }
}

#pragma mark - UITableViewDragDelegate / UITableViewDropDelegate（2026-08-30 已移除拖拽排序：方法保留但禁用，防误触）

- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath {
    return @[]; // 拖拽已移除（2026-08-30 用户定案）
}

- (UITableViewDropProposal *)tableView:(UITableView *)tableView dropSessionDidUpdate:(id<UIDropSession>)session withDestinationIndexPath:(NSIndexPath *)destinationIndexPath {
    return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationForbidden];
}

- (void)tableView:(UITableView *)tableView performDropWithCoordinator:(id<UITableViewDropCoordinator>)coordinator {
    // 拖拽已移除（2026-08-30 用户定案）：空实现
}

#pragma mark - 落盘自治（App=配置源，manager=注入执行器）

/// mobile 域命令提交（唯一出口，2026-09-04 治理）：写键 → synchronize（防 cfprefsd 懒落盘竞态，
/// 2026-08-27 教训）→ notify_post。所有 SimLocation*/SimAP* 写入必须走此 helper
/// （readCurrentStatus/toggleLocate/commitAnchor/commitStop/holdAtCurrentPosition 收口）
- (void)commitSimPrefs:(void (^)(NSUserDefaults *d))mutate {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    if (mutate) mutate(d);
    [d synchronize];
    notify_post(TVNC_NOTIFY_PREFS_CHANGED);
}

- (void)commitAnchor {
    // 2026-08-29 定案：只写坐标，不写模式——daemon off 分支检测坐标变化后注入+开定位，保持模式为 off
// self.cur 统一瓦片系（2026-09-04 治理），直接写 plist——daemon injectPoint 出口统一 GCJ→WGS
    [self commitSimPrefs:^(NSUserDefaults *d) {
        CLLocationCoordinate2D wgs = self.cur;
        [d setDouble:wgs.latitude forKey:@"SimLocationLat"];
        [d setDouble:wgs.longitude forKey:@"SimLocationLon"];
    }];
}

- (void)commitStop {
    [self commitSimPrefs:^(NSUserDefaults *d) {
        [d setObject:@"off" forKey:@"SimLocationMode"];
    }];
}

/// 轨迹播完复位（daemon kTRSimPlaybackFinishedNotification 通知，2026-09-04 治理）：
/// daemon 播完分支已单方复位三方（_currentMode=off + plist 写 off/终点坐标）——App 仅做 UI 复位，
/// 不再 commitStop（避免与 daemon 单方复位的反向竞速；Darwin 通知丢失也无害，plist 已 off）。
/// 幂等守卫：未开启时忽略。
- (void)playbackDidFinish {
    if (!self.locating) return;
    TVLog(@"[locsim] playback finished (daemon notified) -> reset to stopped");
    self.locating = NO;
    self.pendingEditAction = nil;
    self.stopTimestamp = [[NSDate date] timeIntervalSince1970];
    self.startupLockedToAnchor = NO; // 解锁（防御性重置）
    self.mapView.userTrackingMode = MKUserTrackingModeNone;
    [self refreshUserLocationView];
    [self resetFocusBaseline];
    [self refreshWifiAnnotation];
    [self _updateWifiStatusBar];
    [self updateStatus];
}

/// 重算期间让 daemon 驻留在当前位置（anchor 微动）：编辑（删除/重排）重算耗时期间，
/// 避免 daemon 继续沿已删除/已重排的旧轨迹移动（走向被删锚点）+ 重载时旧轨迹被截断的回跳——
/// "只要不是停止定位，编辑时底层保持当前位置不乱跳"（仅定位中生效；停止态编辑不动 daemon）
- (void)holdAtCurrentPosition:(CLLocationCoordinate2D)curW {
    if (!self.locating) return;
    // 2026-08-29 定案：只写坐标，不写模式——编辑时保持当前模式不变
    [self commitSimPrefs:^(NSUserDefaults *d) {
        [d setDouble:curW.latitude forKey:@"SimLocationLat"];
        [d setDouble:curW.longitude forKey:@"SimLocationLon"];
    }];
}

/// 编辑动作统一入口（联动性：编辑不丢）——生成中挂起（最后一次生效），否则立即执行
- (void)runEdit:(void (^)(void))action {
    if (self.isGenerating) {
        self.pendingEditAction = action; // 合并：连续编辑只保留最后一次
        return;
    }
    action();
}

/// 生成完成后执行挂起的最新编辑（安全重入：此时 isGenerating=NO，内部会再触发生成）
- (void)runPendingEdit {
    void (^pending)(void) = self.pendingEditAction;
    self.pendingEditAction = nil;
    if (pending) pending();
}

/// 编排提交（锚点链顺序生长原则）：新增锚点 → 新段标记待生成，顺序补齐只重算缺失段（无全量重建/重渲染）
- (void)commitItinerary {
    // 并发保护：正在生长时忽略新的提交（runEdit 已挂起编辑，最后一次生效）
    if (self.isGenerating) return;
    // 段点序列缓存补齐到链长（新锚点对应段为 NSNull 待生成）
    while ((NSInteger)self.segmentPoints.count < (NSInteger)self.segments.count) {
        [self.segmentPoints addObject:[NSNull null]];
    }
    [self syncChainAndGenerate];
}

/// 生长可视化：每段算路点序列追加为生长轨迹线（算路点/segments 均为瓦片系，与显示同系——
/// 2026-08-30 坐标统一：曾"画图转 GCJ-02"系早期自定义 GCJ 瓦片时代的经验，标准 MKMapView 契约下已多余）
/// 分段式渲染：生长线挂所属编排段索引，增删/重算只动受影响段，不重画整条链
/// 显示层降采样：轨迹点按 1 点/秒生成（步行 1.4m/点），长路线（区域段可达数千点）整条 polyline
/// 在地图滚动/缩放时每帧重绘是"操作地图卡顿"主因——显示抽稀到 ≤600 点（轨迹文件保留全量播放精度）
- (void)appendGrowLine:(NSArray *)pts forSegment:(NSInteger)segIdx {
    if (![pts isKindOfClass:[NSArray class]] || pts.count < 2) return;
    static const NSUInteger kMaxLinePoints = 600;
    NSArray *disp = pts;
    if (pts.count > kMaxLinePoints) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:kMaxLinePoints];
        [out addObject:pts.firstObject];
        NSUInteger step = (pts.count - 1) / (kMaxLinePoints - 1);
        for (NSUInteger i = step; i < pts.count - 1; i += step) [out addObject:pts[i]];
        [out addObject:pts.lastObject];
        disp = out;
    }
    CLLocationCoordinate2D *cs = malloc(disp.count * sizeof(CLLocationCoordinate2D));
    for (NSUInteger i = 0; i < disp.count; i++) {
        NSDictionary *p = disp[i];
// 算路点瓦片系，直接画（2026-09-04 治理）
        cs[i] = CLLocationCoordinate2DMake([p[@"lat"] doubleValue], [p[@"lon"] doubleValue]);
    }
    TRGrowPolyline *line = [TRGrowPolyline polylineWithCoordinates:cs count:disp.count];
    line.segmentIndex = segIdx;
    free(cs);
    [self.mapView addOverlay:line];
}

/// 出发锚点的出行方式：段 idx 的路线由上一段（出发锚点）以其生成时的出行方式前往下一段
/// （对齐"锚点图标 = 此锚点如何移动到下一锚点"原则）；无上一段时退回本段/当前选择
- (NSString *)departModeForSegment:(NSUInteger)idx {
    if (idx > 0) {
        id m = self.segments[idx - 1][@"mode"];
        if ([m isKindOfClass:[NSString class]]) return m;
    }
    id m2 = self.segments[idx][@"mode"];
    if ([m2 isKindOfClass:[NSString class]]) return m2;
    return (self.modeSeg.selectedSegmentIndex == 1) ? @"drive" : @"walk";
}

/// 段 i 是否已有有效点序列（≥2 点）；段 0 特殊：正常链=首锚点仅起点恒有效（跳过），删首后=待生成（无效需生成）
- (BOOL)segmentValid:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.segments.count) return NO;
    if (i == 0) return !self.segmentZeroPending;
    id pts = (i < (NSInteger)self.segmentPoints.count) ? self.segmentPoints[i] : nil;
    return [pts isKindOfClass:[NSArray class]] && ((NSArray *)pts).count >= 2;
}

/// 生成段 i 点序列（anchor=两点算路；region=区域计划+途经点链整段），回调 pts（空=失败/忽略）
- (void)generateSegment:(NSInteger)i completion:(void (^)(NSArray<NSDictionary *> *pts))completion {
    NSDictionary *seg = self.segments[i];
    if ([seg[@"type"] isEqualToString:@"region"]) {
        [self generateRegionSegment:i completion:completion];
        return;
    }
    CLLocationCoordinate2D fromW = (i > 0) ? [self anchorWGSOfSegment:self.segments[i - 1]] : [self currentSimPosition];
    CLLocationCoordinate2D toW = [self anchorWGSOfSegment:self.segments[i]];
    NSString *mode = [self departModeForSegment:i];
    NSLog(@"[locsim-grow] seg %ld %@: from (%.5f,%.5f) -> to (%.5f,%.5f)", (long)i, seg[@"type"], fromW.latitude, fromW.longitude, toW.latitude, toW.longitude); // 生长顺序诊断
    [SimRouteCalculator calculateRoutePointsFrom:fromW to:toW mode:mode completion:^(NSArray<NSDictionary *> *points, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || points.count < 2) {
                [self setHint:@"已忽略无法算路的锚点"];
                if (completion) completion(@[]);
                return;
            }
            if (completion) completion(points);
        });
    }];
}

/// 锚点链顺序补齐：从第一个无效段（NSNull/失败）起按段顺序生成到链尾。
/// 编辑（添加/删除/拖拽）只把受影响段标记为无效，此处只重算受影响段，其余段点序列缓存完全保留（无全量重算）
- (void)syncChainAndGenerate {
    if (self.isGenerating) return;
    self.isGenerating = YES;
    while ((NSInteger)self.segmentPoints.count < (NSInteger)self.segments.count) {
        [self.segmentPoints addObject:[NSNull null]];
    }
    if (self.locating) [self holdAtCurrentPosition:[self currentSimPosition]]; // 算路期间 daemon 驻留当前位置
    __block NSInteger i = self.segmentZeroPending ? 0 : 1; // 删首后段 0（当前位置→新首锚）待生成
    __block void (^step)(void);
    step = ^{
        while (i < (NSInteger)self.segments.count && [self segmentValid:i]) i++;
        if (i >= (NSInteger)self.segments.count) {
            [self finishChainSync];
            return;
        }
        NSInteger gen = i;
        [self generateSegment:gen completion:^(NSArray<NSDictionary *> *pts) {
            self.segmentPoints[gen] = (pts.count ? pts : [NSNull null]);
            if (gen == 0) self.segmentZeroPending = NO; // 段 0 生成完（成功/失败），回归正常链语义
            i = gen + 1;
            step();
        }];
    };
    step();
}

/// 全链收尾：展平 submittedPoints（按段赋 seq 全局顺序号 + segIdx 段归属，2026-08-30 数据源排序）+
/// 按段重画生长线（段点序列已缓存，同步瞬画不涉及算路）+ 写轨迹 + 释放生成锁
- (void)finishChainSync {
    NSMutableArray *joined = [NSMutableArray array];
    NSUInteger seq = 0;
    for (NSInteger i = 0; i < (NSInteger)self.segments.count; i++) {
        id pts = (i < (NSInteger)self.segmentPoints.count) ? self.segmentPoints[i] : nil;
        if ([pts isKindOfClass:[NSArray class]]) {
            for (NSDictionary *p in pts) {
                if (![p isKindOfClass:[NSDictionary class]]) continue;
                NSMutableDictionary *np = [p mutableCopy];
                np[@"seq"] = @(seq++);       // 全局递增顺序号（数据源排序，恢复 O(1) 定位）
                np[@"segIdx"] = @(i);        // 所属段（恢复锚点颜色派生：seq→段→锚点 passed）
                [joined addObject:np];
            }
        }
    }
    self.submittedPoints = joined;
    self.trackVersion++; // 轨迹重算 → 版本递增（daemon 恢复时区分新旧轨迹）
    for (id o in [self.mapView.overlays copy]) {
        if ([o isKindOfClass:[TRGrowPolyline class]]) [self.mapView removeOverlay:o];
    }
    for (NSInteger i = 0; i < (NSInteger)self.segments.count; i++) {
        id pts = (i < (NSInteger)self.segmentPoints.count) ? self.segmentPoints[i] : nil;
        if ([pts isKindOfClass:[NSArray class]] && ((NSArray *)pts).count >= 2) [self appendGrowLine:pts forSegment:i];
    }
    if (joined.count >= 2) [self writeTrackFile:joined];
    [self setHint:[NSString stringWithFormat:@"路线已更新 · %lu 点", (unsigned long)joined.count]];
    self.isGenerating = NO;
    [self runPendingEdit];
}

/// 区域段整段生成：进入段（出发锚点模式）→ 区域内途经点链（区域配置模式，随机=每段按 walkRatio 随机）逐途经点 MKDirections 算路拼接
/// （<30m/算路失败 → 忽略该中间途经点，直接进入下一途经点）+ 停留微动；回调整段点序列（不再递归后续段）
- (void)generateRegionSegment:(NSInteger)i completion:(void (^)(NSArray<NSDictionary *> *pts))completion {
    NSDictionary *seg = self.segments[i];
// segments 存瓦片系（2026-09-04 治理），center 直接取，无需转换
    CLLocationCoordinate2D centerW = CLLocationCoordinate2DMake([seg[@"center"][@"lat"] doubleValue], [seg[@"center"][@"lon"] doubleValue]);
    double radius = [seg[@"radius"] doubleValue];
    double durationMin = [seg[@"durationMin"] doubleValue];
    NSString *regionMode = seg[@"mode"] ?: @"walk";
    double walkRatio = [seg[@"walkRatio"] doubleValue] > 0 ? [seg[@"walkRatio"] doubleValue] : 0.7; // 随机模式的步行占比（默认 70%）
    int customK = (int)[seg[@"waypointCount"] integerValue]; // >0 生效，0=随机
    CLLocationCoordinate2D cur = (i > 0) ? [self anchorWGSOfSegment:self.segments[i - 1]] : [self currentSimPosition];
    // 链首 region 段从当前位置进入——当前位置无效（冷启动未收到真实 fix，cur=0,0）时拦截，防路线从海中央连出
    if (cur.latitude == 0 && cur.longitude == 0) {
        [self setHint:@"尚未获取当前位置，请稍后再圈区域"];
        if (completion) completion(@[]);
        return;
    }
    NSDictionary *plan = [RegionSimulator generateRegionPlanCenter:centerW radius:radius mode:regionMode durationMin:durationMin startFrom:cur customK:customK];
    NSArray *wps = plan[@"waypoints"];
    NSArray *stay = plan[@"staySeconds"];
    NSArray *factors = plan[@"moveFactors"];
    if (!wps.count) { if (completion) completion(@[]); return; }
    // 途经点标注：区域段生成/重算前清掉旧的，按 waypoints 重建（信息点，内嵌每段出行图标；复用锚点水滴渲染）
    for (TRWaypointAnnotation *w in self.waypointAnns) [self.mapView removeAnnotation:w];
    [self.waypointAnns removeAllObjects];
    for (NSUInteger k = 0; k < wps.count; k++) {
        TRWaypointAnnotation *w = [[TRWaypointAnnotation alloc] init];
// 途经点坐标：plan 返回瓦片系（与瓦片显示同系，2026-09-04 治理纠正 8-30 误断言），直接使用
        w.coordinate = [wps[k] MKCoordinateValue];
        [self.waypointAnns addObject:w];
        [self.mapView addAnnotation:w];
    }
    __block NSMutableArray *pts = [NSMutableArray array];
    __block NSUInteger segIdx = 0;
    __block CLLocationCoordinate2D legCur = cur;

    // 递归块必须 __block：否则块内捕获的是创建时的未初始化指针（赋值后仍是垃圾），首次递归即崩溃
    __block void (^processLeg)(void);
    processLeg = ^{
        if (segIdx >= wps.count) { if (completion) completion(pts); return; }
        CLLocationCoordinate2D wp = [wps[segIdx] MKCoordinateValue];
        double staySec = [stay[segIdx] doubleValue];
        double factor = [factors[segIdx] doubleValue];
        NSString *legMode;
        if (segIdx == 0) {
            legMode = [self departModeForSegment:i]; // 进入段用出发锚点模式
        } else if ([regionMode isEqualToString:@"random"]) {
            legMode = ((double)arc4random_uniform(100) < walkRatio * 100) ? @"walk" : @"drive"; // 区域内段每段随机（按步行占比）
        } else {
            legMode = regionMode; // 固定模式（walk/drive）
        }
        double speed = [RegionSimulator effectiveSpeedForMode:legMode];
        // 该段途经点标注内嵌出行图标（与锚点同款蓝水滴；随机模式下每段确定后刷新）
        if (segIdx < self.waypointAnns.count) {
            TRWaypointAnnotation *w = self.waypointAnns[segIdx];
            w.mode = legMode;
            MKAnnotationView *wv = [self.mapView viewForAnnotation:w];
            if (wv) wv.image = [self waterdropImageWithColor:[UIColor colorWithRed:0.13 green:0.65 blue:0.97 alpha:1.0] size:18 emoji:[self emojiForMode:legMode]];
        }
        double segDist = [SimRouteCalculator haversineMeters:legCur to:wp];

        void (^goStay)(CLLocationCoordinate2D) = ^(CLLocationCoordinate2D end) {
            [RegionSimulator appendStayPointsAt:end seconds:staySec into:pts];
            legCur = end;
            segIdx++;
            processLeg();
        };
        if (segDist < 30.0) {
            // 途经点对 <30m 无法成路 → 忽略该中间途经点（对齐"忽略中间锚点"原则），直接进入下一途经点
            [self setHint:@"已忽略过近的途经点"];
            segIdx++;
            processLeg();
            return;
        }
        [SimRouteCalculator calculateRoutePointsFrom:legCur to:wp mode:legMode completion:^(NSArray<NSDictionary *> *ptsIn, NSError *error) {
            // MKDirections completion 队列不保证主线程，UI 操作统一回主线程
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error || ptsIn.count < 2) {
                    // 算路失败 → 忽略该中间途经点，从当前位置继续进入下一途经点
                    [self setHint:@"已忽略无法算路的途经点"];
                    segIdx++;
                    processLeg();
                    return;
                }
                NSUInteger target = MAX(1, (NSUInteger)ceil(segDist / (speed * factor)));
                target = MIN(target, 5000); // 点量上限，防内存爆
                NSArray *resampled = [self resamplePoints:ptsIn toCount:target];
                [pts addObjectsFromArray:resampled];
                CLLocationCoordinate2D legEnd = CLLocationCoordinate2DMake([resampled.lastObject[@"lat"] doubleValue], [resampled.lastObject[@"lon"] doubleValue]);
                goStay(legEnd);
            });
        }];
    };
    processLeg();
}

/// 在真实算路点序列上重采样到 target 个点（对齐 SimItineraryPlanner._resamplePoints）
- (NSArray *)resamplePoints:(NSArray<NSDictionary *> *)pts toCount:(NSUInteger)target {
    NSUInteger n = pts.count;
    if (n == 0 || n == target) return pts;
    if (target == 1) return @[pts[n / 2]];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:target];
    if (target < n) {
        for (NSUInteger i = 0; i < target; i++) {
            NSUInteger idx = (NSUInteger)llround((double)(n - 1) * i / (double)(target - 1));
            [out addObject:pts[idx]];
        }
    } else {
        for (NSUInteger i = 0; i < target; i++) {
            double f = (double)(n - 1) * i / (double)(target - 1);
            NSUInteger lo = (NSUInteger)floor(f);
            NSUInteger hi = MIN(lo + 1, n - 1);
            double t = f - lo;
            NSDictionary *a = pts[lo], *b = pts[hi];
            double lat = [a[@"lat"] doubleValue] + ([b[@"lat"] doubleValue] - [a[@"lat"] doubleValue]) * t;
            double lon = [a[@"lon"] doubleValue] + ([b[@"lon"] doubleValue] - [a[@"lon"] doubleValue]) * t;
            [out addObject:@{
                @"lat": @(lat), @"lon": @(lon),
                @"speed": a[@"speed"], @"course": a[@"course"],
                @"alt": a[@"alt"], @"acc": a[@"acc"],
            }];
        }
    }
    return out;
}

/// 原子写轨迹文件（tmp + rename，防半截 JSON），定位状态由 FAB 开关控制——
/// 仅在定位中才切 SimLocationMode=itinerary + notify（添加/删除锚点不改变定位状态，对齐原型"不随后续增删路线改变状态"）
/// 异步化 + 串行化（2026-08-25）：全量轨迹 JSON（数万点≈数 MB）序列化 + 磁盘写不阻塞主线程（锚点列表卡顿主因），
/// 且用串行队列按提交顺序完整写盘——连续编辑并发写同一文件会覆盖/半截 → daemon 读到损坏轨迹跳点乱播
- (void)writeTrackFile:(NSArray *)points {
    NSArray *snapshot = [points copy];
    // 2026-08-30 持久化升级 v3：编排契约文件承载唯一真相——segments（锚点链）+ points（带 seq/segIdx 数据源排序）+ trackVersion（新旧轨迹区分）
    // seq：全局顺序号，daemon 恢复 O(1) 定位续播（无几何歧义）；segIdx：所属段，恢复锚点颜色派生
    // trackVersion：每次重算递增，daemon 恢复时版本一致用 seq、不一致几何兜底（编辑后新轨迹）
    NSArray *segSnapshot = [self.segments copy];
    NSUInteger trackVersion = self.trackVersion;
    BOOL locating = self.locating;
    static dispatch_queue_t sTrackWriteQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sTrackWriteQueue = dispatch_queue_create("com.82flex.trollvnc.trackwrite", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(sTrackWriteQueue, ^{
        NSDictionary *payload = @{ @"version": @3, @"trackVersion": @(trackVersion), @"segments": segSnapshot, @"points": snapshot };
        NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (!json) return;
        NSString *tmp = [kTRSimTrackFilePath stringByAppendingString:@".tmp"];
        if (![json writeToFile:tmp options:NSDataWritingAtomic error:nil]) return;
        if ([[NSFileManager defaultManager] fileExistsAtPath:kTRSimTrackFilePath]) {
            [[NSFileManager defaultManager] removeItemAtPath:kTRSimTrackFilePath error:nil];
        }
        if (![[NSFileManager defaultManager] moveItemAtPath:tmp toPath:kTRSimTrackFilePath error:nil]) return;
        // 2026-08-29 定案：轨迹写入后不自动切换模式——播放开关由用户控制
        if (locating) {
            // 仅通知 daemon 轨迹文件已更新（不改变模式，可用于读取路线点）
            notify_post(TVNC_NOTIFY_PREFS_CHANGED);
        }
    });
}

#pragma mark - MKMapViewDelegate

/// 出行方式 → 图标（与模式胶囊按钮同款）
- (NSString *)emojiForMode:(NSString *)mode {
    return [mode isEqualToString:@"drive"] ? @"🚗" : @"🚶";
}

/// 颜色 → 稳定 key（位图缓存键用，避免 UIColor.description 不稳定）
- (NSString *)colorHexKey:(UIColor *)c {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [c getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"%02x%02x%02x", (int)(r * 255 + 0.5), (int)(g * 255 + 0.5), (int)(b * 255 + 0.5)];
}

/// 水滴图钉绘制（实心水滴：半圆顶+尖底+白边；颜色=状态分类；可内嵌出行方式图标）
/// 结果按 (颜色,size,emoji) 缓存——viewForAnnotation 随地图滚动/缩放反复调用，
/// 每次重复位图绘制是"操作地图卡顿"主因之一（颜色/大小/图标组合有限，缓存命中率极高）
- (UIImage *)waterdropImageWithColor:(UIColor *)color size:(CGFloat)sz emoji:(NSString *)emoji {
    static NSMutableDictionary *sPinCache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sPinCache = [NSMutableDictionary dictionary]; });
    NSString *key = [NSString stringWithFormat:@"%@|%.0f|%@", [self colorHexKey:color], sz, emoji ?: @""];
    UIImage *cached = sPinCache[key];
    if (cached) return cached;
    UIGraphicsImageRenderer *ir = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(sz, sz + 6)];
    UIImage *img = [ir imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:CGPointMake(sz / 2, sz + 6)]; // 底部尖
        [p addQuadCurveToPoint:CGPointMake(0, sz / 2) controlPoint:CGPointMake(1, sz - 3)]; // 左下弧
        // 顶部半圆：从 π(左) 经 π/2(顶部) 到 0(右)——clockwise:YES（UIKit y 向下，NO 会画成下半圆导致上半透明）
        [p addArcWithCenter:CGPointMake(sz / 2, sz / 2) radius:sz / 2 startAngle:M_PI endAngle:0 clockwise:YES];
        [p addQuadCurveToPoint:CGPointMake(sz / 2, sz + 6) controlPoint:CGPointMake(sz - 1, sz - 3)]; // 右下弧到尖
        [p closePath];
        [color setFill];
        [p fill];
        p.lineWidth = 1.5;
        [[UIColor whiteColor] setStroke];
        [p stroke];
        if (emoji.length) {
            CGFloat f = sz * 0.58; // 图标随水滴缩放（锚点小号/当前位置大号）
            [emoji drawInRect:CGRectMake(sz / 2 - f * 0.6, sz / 2 - f * 0.6, f * 1.2, f * 1.2)
               withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:f]}];
        }
    }];
    sPinCache[key] = img;
    return img;
}

- (MKOverlayRenderer *)mapView:(MKMapView *)mapView rendererForOverlay:(id<MKOverlay>)overlay {
    if ([overlay isKindOfClass:[MKCircle class]]) {
        // 原生区域遮罩（实线描边 + 半透明填充，MKCircleRenderer 原生呈现；非虚线）
        MKCircleRenderer *r = [[MKCircleRenderer alloc] initWithCircle:overlay];
        r.fillColor = [[UIColor colorWithRed:0.29 green:0.25 blue:0.89 alpha:1.0] colorWithAlphaComponent:0.18];
        r.strokeColor = [UIColor colorWithRed:0.29 green:0.25 blue:0.89 alpha:1.0];
        r.lineWidth = 2.0;
        return r;
    }
    if ([overlay isKindOfClass:[TRGrowPolyline class]]) {
        // 生长轨迹：按 segmentIndex 分配颜色（重叠/同路段不同段也能分辨"路线确实创建了"；段 0 保留深紫主色）
        MKPolylineRenderer *r = [[MKPolylineRenderer alloc] initWithPolyline:overlay];
        static NSArray *sSegColors;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            sSegColors = @[
                [UIColor colorWithRed:0.24 green:0.18 blue:0.79 alpha:1.0], // 深紫（段 0）
                [UIColor colorWithRed:0.95 green:0.55 blue:0.13 alpha:1.0], // 橙
                [UIColor colorWithRed:0.13 green:0.65 blue:0.97 alpha:1.0], // 蓝
                [UIColor colorWithRed:0.91 green:0.24 blue:0.52 alpha:1.0], // 玫红
                [UIColor colorWithRed:0.10 green:0.72 blue:0.48 alpha:1.0], // 绿
            ];
        });
        NSInteger idx = ((TRGrowPolyline *)overlay).segmentIndex;
        r.strokeColor = sSegColors[idx < 0 ? 0 : (idx % (NSInteger)sSegColors.count)];
        r.lineWidth = 3.0;
        r.lineCap = kCGLineCapRound;
        return r;
    }
    return nil;
}

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:[TRAnchorAnnotation class]]) {
        TRAnchorAnnotation *a = (TRAnchorAnnotation *)annotation;
        static NSString *rid = @"AnchorPin";
        MKAnnotationView *v = [mapView dequeueReusableAnnotationViewWithIdentifier:rid];
        if (!v) {
            v = [[MKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:rid];
            v.canShowCallout = NO; // 点击水滴即删除（didSelectAnnotationView），不弹气泡
            v.userInteractionEnabled = YES; // 保证 tap shouldReceiveTouch 能命中标注视图（拦截误加锚点）
        }
        v.annotation = annotation;
        // 实心水滴图钉（状态分类：绿=终点锚点(即将到达)/红=已消费(出发锚点+已走完)/蓝=未消费，2026-08-30 用户定案 v3；内嵌出行方式图标；尖对准坐标点）
        UIColor *color = [UIColor colorWithRed:0.13 green:0.65 blue:0.97 alpha:1.0]; // 蓝（未消费）
        if (a.consuming && !a.passed) {
            color = [UIColor colorWithRed:0.11 green:0.79 blue:0.51 alpha:1.0]; // 绿：终点锚点（即将到达，消费中）
        } else if (a.passed) {
            color = [UIColor colorWithRed:0.94 green:0.23 blue:0.13 alpha:1.0]; // 红：已消费（出发锚点/已走完）
        }
        v.image = [self waterdropImageWithColor:color size:22 emoji:[self emojiForMode:a.mode]];
        v.centerOffset = CGPointMake(0, -14); // 尖对准坐标点
        v.frame = CGRectMake(0, 0, 22, 28);
        return v;
    }
    if ([annotation isKindOfClass:[TRWaypointAnnotation class]]) {
        // 区域漫游途经点：蓝色小水滴 + 该段出行方式图标（样式与锚点一致，仅不可点击删除；复用锚点水滴渲染）
        TRWaypointAnnotation *w = (TRWaypointAnnotation *)annotation;
        static NSString *rid = @"WaypointPin";
        MKAnnotationView *v = [mapView dequeueReusableAnnotationViewWithIdentifier:rid];
        if (!v) {
            v = [[MKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:rid];
            v.canShowCallout = NO;
            v.userInteractionEnabled = YES; // 供 shouldReceiveTouch 拦截，防 tap 误加锚点
        }
        v.annotation = annotation;
        v.image = [self waterdropImageWithColor:[UIColor colorWithRed:0.13 green:0.65 blue:0.97 alpha:1.0] size:18 emoji:[self emojiForMode:w.mode]];
        v.centerOffset = CGPointMake(0, -12); // 尖对准坐标点
        v.frame = CGRectMake(0, 0, 18, 24);
        return v;
    }
    if ([annotation isKindOfClass:[TRWifiAnnotation class]]) {
        // WiFi 定位标注：蓝紫水滴 + 📶，canShowCallout=YES 气泡显示坐标+AP 数；
        // userInteractionEnabled=YES 供 shouldReceiveTouch 拦截，防 tap 误加锚点
        static NSString *rid = @"WifiPin";
        MKAnnotationView *v = [mapView dequeueReusableAnnotationViewWithIdentifier:rid];
        if (!v) {
            v = [[MKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:rid];
            v.canShowCallout = YES;
            v.userInteractionEnabled = YES; // 供 shouldReceiveTouch 拦截，防 tap 误加锚点
        }
        v.annotation = annotation;
        v.image = [self waterdropImageWithColor:[UIColor colorWithRed:0.45 green:0.30 blue:0.85 alpha:1.0] size:22 emoji:@"📶"];
        v.centerOffset = CGPointMake(0, -14); // 尖对准坐标点
        v.frame = CGRectMake(0, 0, 22, 28);
        return v;
    }
    if ([annotation isKindOfClass:[MKUserLocation class]]) {
        // 当前位置（原生管线）：数据源头=locationd（模拟开启=模拟位置/关闭=真实位置）；绿色水滴+出行方式图标外观
        static NSString *rid = @"CurPin";
        MKAnnotationView *v = [mapView dequeueReusableAnnotationViewWithIdentifier:rid];
        if (!v) {
            v = [[MKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:rid];
            v.canShowCallout = NO;
        }
        v.annotation = annotation;
        NSString *mode = self.currentLegMode ?: (self.modeSeg.selectedSegmentIndex == 1 ? @"drive" : @"walk");
        UIColor *green = [UIColor colorWithRed:0.11 green:0.79 blue:0.51 alpha:1.0];
        // 定位中显示当前段出行图标；未定位纯绿点（位置=真实位置）
        v.image = [self waterdropImageWithColor:green size:24 emoji:(self.locating ? [self emojiForMode:mode] : @"")];
        v.centerOffset = CGPointMake(0, -15); // 尖对准坐标点
        v.frame = CGRectMake(0, 0, 24, 30);
        // 光晕（对齐原型 .dot box-shadow 0 0 0 5px rgba(34,165,247,.28)）
        v.layer.shadowColor = green.CGColor;
        v.layer.shadowOpacity = 0.6;
        v.layer.shadowRadius = 6;
        v.layer.shadowOffset = CGSizeMake(0, 0);
        return v;
    }
    return nil;
}

/// 点击锚点水滴 = 删除该锚点（对齐原型「点击锚点删除该点，路线自适应连接」）；
/// 单次点击即删（不弹气泡）；handleTap 已对锚点区域拦截，不会误加新锚点
- (void)mapView:(MKMapView *)mapView didSelectAnnotationView:(MKAnnotationView *)view {
    if ([view.annotation isKindOfClass:[TRAnchorAnnotation class]]) {
        TRAnchorAnnotation *a = (TRAnchorAnnotation *)view.annotation;
        [mapView deselectAnnotation:view.annotation animated:NO];
        [self deleteSegmentAt:a.segmentIndex];
    }
}

#pragma mark - UIGestureRecognizerDelegate

/// 点击落在锚点水滴上 → tap 手势直接不识别（删除走 didSelectAnnotationView）；
/// 在 touch 阶段拦截（早于任何删除时序），避免"didSelect 删除重建后 handleTap 误加新锚点"的竞态
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer == self.mapTap) {
        UIView *v = touch.view;
        while (v) {
            if ([v isKindOfClass:[MKAnnotationView class]]) {
                MKAnnotationView *av = (MKAnnotationView *)v;
                if ([av.annotation isKindOfClass:[TRAnchorAnnotation class]]) return NO;
                if ([av.annotation isKindOfClass:[TRWaypointAnnotation class]]) return NO; // 途经点同锚点：不触发 tap 加锚点
                if ([av.annotation isKindOfClass:[TRWifiAnnotation class]]) return NO; // WiFi 标注同锚点：不触发 tap 加锚点
            }
            v = v.superview;
        }
    }
    return YES;
}

// 地图滚动时不应触发 tap/longPress
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

@end
