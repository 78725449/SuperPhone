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
#import "CoordTransform.h"
#import "TRWpsTile.h" // 坐标→BSSID 动态反查（模拟分支按当前位置反查，与 daemon 注入同源；轨迹跟随）
#import "../../../src/TRWifiScanContract.h" // 跨端扫描契约常量（单一真相源，2026-08-28）
#import "../../../src/TRSimContract.h" // 跨端定位契约（轨迹文件路径单一真相源，2026-08-28）
#import "../../../src/TRAppDomain.h" // kTRAppPrefsSuiteName（跨端 prefs 域契约，2026-08-28）
#import "RegionSimulator.h"
#import "SimRouteCalculator.h"
#import "TRWpsClient.h"
#import "TVNCUtil.h" // TVNC_NOTIFY_PREFS_CHANGED（prefs-changed 通知名宏，2026-08-28 收敛）

/// 轨迹文件路径 → kTRSimTrackFilePath（TRSimContract.h 跨端单一真相源，2026-08-28）
// prefs suite 名 → kTRAppPrefsSuiteName（TRAppDomain.h 跨端单一真相源，2026-08-28）
// WiFi 主动扫描契约常量 → TRWifiScanContract.h（共享模块单一真相源，2026-08-28 收敛；不再本地 static 字面量）
static const double kAutoFocusThresholdM = 500.0; // 自动聚焦距离阈值：fix 距上次聚焦点 ≥500m 才拉回（GPS 抖动 <50m 不打扰）

/// 锚点标注（关联编排段索引，点击删除该段；水滴图钉状态分类：未经过=蓝/已经过=红，当前位置=绿；
/// 水滴内嵌该锚点生成时所使用的出行方式图标 🚶/🚗）
@interface TRAnchorAnnotation : MKPointAnnotation
@property (nonatomic, assign) NSInteger segmentIndex;
@property (nonatomic, copy) NSString *type; // anchor | route | region
@property (nonatomic, assign) BOOL passed;  // 是否已被当前位置经过（经过=红，未经过=蓝）
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

/// 自驱当前位置水滴（定位关闭时替代 MKUserLocation——跟编排位置 self.cur，无 locationd 广播时的当前位置观感）
@interface TRSelfDrivenDroplet : MKPointAnnotation
@end
@implementation TRSelfDrivenDroplet
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
@property (nonatomic, assign) uint64_t wifiLastTileKey;        // 模拟态 wifi 标注瓦片 key（对齐 daemon _checkWifiTileChangedAndReinject：跨瓦片才重新反查标注，同瓦片跳过）
@property (nonatomic, strong) NSArray<TRWpsTileAP *> *wifiTileAps;   // 当前瓦片 AP 池缓存（窗口质心刷新源；跨瓦片反查时刷新，2026-08-28）
@property (nonatomic, assign) CLLocationCoordinate2D wifiCurWGS; // 最近一次 wifi 反查质心（WGS；真实 wifi 位置，供启动聚焦兜底/状态显示——GPS 优先、无 GPS 用 wifi 聚焦）
@property (nonatomic, strong) UITableView *stepTable;        // 步骤列表（状态条展开；删除 + 拖拽排序）

@property (nonatomic, strong) NSMutableArray *segments;      // 编排段 @[@{type,point/to/radius/durationMin/mode}]
@property (nonatomic, strong) NSMutableArray *segmentPoints;        // 段点序列缓存（索引对齐 segments：段 i≥1 点序列，NSNull=待生成/失败）——锚点链唯一轨迹真相
@property (nonatomic, assign) BOOL segmentZeroPending;                     // 删首锚点后"当前位置→新首锚"段 0 待生成（段 0 特殊机制：正常链段 0=首锚点仅起点恒有效）
@property (nonatomic, strong) NSMutableArray *anchors;       // 每段对应的锚点标注（TRAnchorAnnotation）
@property (nonatomic, strong) NSMutableArray *waypointAnns;          // 区域漫游途经点标注（TRWaypointAnnotation，随区域段生成/重建）
@property (nonatomic, assign) CLLocationCoordinate2D cur;    // 当前模拟位置（地图坐标 GCJ-02）
@property (nonatomic, assign) BOOL hasStart;
@property (nonatomic, assign) BOOL locating;                // 定位开关状态
@property (nonatomic, copy) NSString *currentLegMode;       // 当前位置水滴的出行方式（当前段目标锚点的，walk/drive）
@property (nonatomic, assign) double currentLegSpeed;              // 当前所在路线（出发锚点段）的生成速度——从段缓存 segmentPoints 取（含 ±10% 抖动；random 段反映实际随机模式）
@property (nonatomic, assign) BOOL startupLockedToAnchor;          // 开启定位瞬间到注入落地前：锁定锚点位置显示（忽略真实 fix，防开启横跳）
@property (nonatomic, strong) NSMutableArray *fabCoinLabels;              // 定位 FAB 铜钱四字（招财进宝，上/右/下/左顺时针）
@property (nonatomic, strong) CAGradientLayer *fabGoldGradient;           // 定位 FAB 铜钱渐变金底（定位中显示）
@property (nonatomic, assign) BOOL expanded;                // 步骤列表展开态
@property (nonatomic, assign) BOOL hasFocusedMapOnce;            // 首帧启动聚焦是否已执行（避免 tab 往返重复聚焦）
@property (nonatomic, strong) CLLocationManager *locationManager; // App 活跃位置订阅（授权 + startUpdatingLocation，didUpdateLocations 主驱动）
@property (nonatomic, assign) CLLocationCoordinate2D lastAutoFocusWGS;   // 上次自动聚焦点（WGS）：fix 距此 ≥ 阈值才聚焦并更新（残留 fix≈基线不触发，替代 hasFocusedRealOnce）
@property (nonatomic, assign) NSTimeInterval startTimestamp;     // 开启定位时刻：模拟分支只认晚于此的 fix（过滤注入落地前的真实残留）
@property (nonatomic, assign) NSTimeInterval stopTimestamp;      // 停止定位时刻：停止分支只认晚于此的 fix（过滤模拟残留/旧缓存）
@property (nonatomic, strong) CLLocation *lastFix;              // 最近一次通过时间戳过滤的回调 fix（坐标/速度真相源，不读 locationManager 属性缓存）
@property (nonatomic, assign) BOOL isGenerating;            // 轨迹生成中（并发保护：正在生长时忽略新的 commit）
@property (nonatomic, copy) void (^pendingEditAction)(void);     // 生成中挂起的最新编辑（完成后执行，最后一次生效）
@property (nonatomic, strong) UITapGestureRecognizer *mapTap;      // 地图单击手势（handleTap；shouldReceiveTouch 拦截锚点水滴点击，防删除竞态）
@property (nonatomic, assign) BOOL hasPromptedLocationAuth;        // 定位授权拒绝提示已弹出（一次性）
@property (nonatomic, strong) NSArray *submittedPoints;             // 已提交的完整轨迹点序列（segmentPoints 展平，播放/上传用）

// 区域（长按）临时状态
@property (nonatomic, assign) BOOL regionPicking;
@property (nonatomic, assign) CLLocationCoordinate2D regionCenter;
@property (nonatomic, assign) double regionRadiusM;
@property (nonatomic, assign) CGPoint regionTouchOffset; // 手势起点-中心（像素偏移，拖移用）
@property (nonatomic, strong) UIView *regionPanel;               // 区域配置菜单（底部卡片，对齐原型 param）
@property (nonatomic, strong) MKCircle *regionOverlay;
@property (nonatomic, weak) TRSelfDrivenDroplet *selfDrivenDroplet;               // 定位关闭时的自驱当前位置水滴（weak：生命周期由 mapView annotations 持有）
- (BOOL)_systemLocationAvailable;
- (void)_updateDropletMode;
- (void)_syncSelfDrivenDroplet;
@end

@implementation TRMapPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.segments = [NSMutableArray array];
    self.segmentPoints = [NSMutableArray array];
    self.anchors = [NSMutableArray array];
    self.waypointAnns = [NSMutableArray array];
    // 初始无硬编码坐标（self.cur 默认 0,0）；初始视野/聚焦均以 locationd（真实）为准，
    // 无定位时由 focusMapOnCurrentLocation 守卫跳过，避免跳到无效坐标
    [self setupMap];
    [self setupUI];
    // 搜索关联候选 completer：必须 init + 设 delegate（2026-08-28：此前只声明 property + 设 queryFragment，
    // 从未 alloc/init 也未设 delegate → 对 nil 发消息静默 no-op，点搜索无反应；iOS 15+ 均需此行）
    self.searchCompleter = [[MKLocalSearchCompleter alloc] init];
    self.searchCompleter.delegate = self;
    [self readCurrentStatus];
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
    // 主动扫描订阅：daemon（root）周期扫周边 BSSID → 写共享 JSON + Darwin 通知。
    // 模拟开启/关闭→统一读「当前连接 WiFi」的 BSSID 反查标注（2026-08-29 职责重定义，不跟随模拟坐标）。
    int wifiScanToken = 0;
    notify_register_dispatch(kTRWifiScanUpdatedNotification.UTF8String, &wifiScanToken,
        dispatch_get_main_queue(), ^(int token) {
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSArray<NSString *> *bssids = [strongSelf _readActiveScanBssids];
            if (!bssids) return;
            [strongSelf handleActiveWifiBssids:bssids];
        });
    // 订阅 WiFi 切换通知（daemon AP 下发成功 → SCDynamicStore 检测重连 → notify App）
    int wifiSwitchToken = 0;
    notify_register_dispatch("com.82flex.trollvnc.wifi-switched", &wifiSwitchToken,
        dispatch_get_main_queue(), ^(int token) {
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf _refreshWifiAnnoFromCurrentConnection];
        });
    // 启动水合：daemon 常驻可能在 App 启动前已扫过，直接读一次（归一读取，2026-08-28）
    NSArray<NSString *> *seedBssids = [self _readActiveScanBssids];
    if (seedBssids) [self handleActiveWifiBssids:seedBssids];
    [self _updateDropletMode]; // 水滴模式统一切换（系统定位开=MKUserLocation / 关=自驱水滴跟编排位置）
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
    mv.showsUserLocation = YES; // 原生当前位置：数据源头=locationd（模拟开启=模拟位置/关闭=真实位置），精准反馈系统真实位置
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
    wifiDiag.text = @"WiFi: 初始化中";
    wifiDiag.userInteractionEnabled = YES;
    UITapGestureRecognizer *wifiTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(wifiDiagTapped:)];
    [wifiDiag addGestureRecognizer:wifiTap];
    [self.view addSubview:wifiDiag];
    self.wifiDiagLabel = wifiDiag;

    // 步骤列表（默认收起；地图左上卡片，删除 + 拖拽排序，对齐原型 segPanel）
    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    table.translatesAutoresizingMaskIntoConstraints = NO;
    table.dataSource = self;
    table.delegate = self;
    table.hidden = YES;
    table.layer.cornerRadius = 10;
    table.layer.borderWidth = 0.5;
    table.layer.borderColor = [UIColor separatorColor].CGColor;
    table.backgroundColor = [UIColor systemBackgroundColor];
    table.editing = NO; // 自绘 cell：左=拖动图标（dragDelegate），右=删除按钮（点击即删，无系统二次确认）
    table.dragDelegate = self;
    table.dropDelegate = self;
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
        // WiFi 诊断标签：状态条下 6、与搜索框左对齐、右不超边（2 行自适应高度）
        [wifiDiag.topAnchor constraintEqualToAnchor:statusBtn.bottomAnchor constant:6],
        [wifiDiag.leadingAnchor constraintEqualToAnchor:self.searchBar.leadingAnchor],
        [wifiDiag.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-16],
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

/// 刷新 WiFi 链路诊断标签（唯一实现=主动扫描：JSON 时间戳 + BSSID 数 + 最近反查状态）
/// 诊断需 ts，保留单次原始读取后内部取 bssids 计数——不再调 _readActiveScanBssids 二次读文件（2026-08-28）
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

/// 点击 WiFi 诊断标签：手动刷新当前状态（读 daemon 主动扫描 JSON）
- (void)wifiDiagTapped:(UITapGestureRecognizer *)g {
    [self refreshWifiDiag]; // 立即刷新当前状态
}

/// 主动扫描 JSON 读取归一（读文件→解析→取 bssids；无/格式错返回 nil）——订阅回调/水合/刷新共用（2026-08-28）
- (NSArray<NSString *> *)_readActiveScanBssids {
    NSData *data = [NSData dataWithContentsOfFile:kTRWifiScanJsonPath];
    if (!data) return nil;
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *bssids = obj[@"bssids"];
    if (![bssids isKindOfClass:[NSArray class]]) return nil;
    return bssids;
}

/// 主动扫描结果消费（唯一实现 = daemon Apple80211 周期扫周边 BSSID → 共享 JSON → 本方法标注）。
/// 语义（用户拍板 2026-08-27）：模拟关闭→真实 BSSID wloc 反查标注（不再依赖「打开系统 Wi-Fi 设置页
/// 触发被动扫描」，也无 NEHotspotHelper 回退）；模拟开启→标注由 fix 驱动（handleLocationUpdate 瓦片
/// 检测），此处触发同款检测（跨瓦片才重反查）。
- (void)handleActiveWifiBssids:(NSArray<NSString *> *)bssids {
    if (self.locating) {
        [self _refreshWifiAnnoFromCurrentConnection]; // 模拟态：水滴=当前连接 BSSID 反查（不跟随模拟坐标）
        return;
    }
    NSUInteger seq = ++self.wifiQuerySeq;
    [self _queryWifiAnnoWithBssids:bssids seq:seq]; // 空列表在方法内统一处理（清除残留标注）
}

/// WiFi 水滴（2026-08-29 职责重定义，用户定案）：只读「当前连接 WiFi」的 SSID/BSSID →
/// 用 BSSID 做 wloc 反查（复用 _queryWifiAnnoWithBssids）→ 标注真实 AP 的位置。
/// 不跟随模拟坐标——它是软路由切换效果的可视化验证（真实 BSSID 被定位到哪 = 切换是否生效），
/// 与 GPS 轨迹/模拟位置完全解耦。旧「瓦片检测 + 缓存池质心跟随」逻辑已删。
/// 数据源 = CNCopyCurrentNetworkInfo（App 有定位授权可用；daemon 才需要 ipconfig 通道）。
- (void)_refreshWifiAnnoFromCurrentConnection {
    NSDictionary *info = nil;
    NSArray *ifs = (__bridge_transfer NSArray *)CNCopySupportedInterfaces();
    for (id ifname in ifs) {
        info = (__bridge_transfer NSDictionary *)
            CNCopyCurrentNetworkInfo((__bridge CFStringRef)ifname);
        if (info) break;
    }
    NSString *bssid = info[(__bridge NSString *)kCNNetworkInfoKeyBSSID];
    if (!bssid.length) {
        [self removeWifiAnnotationIfExists]; // 未连接：清除残留标注（真实状态可视化）
        return;
    }
    NSUInteger seq = ++self.wifiQuerySeq;
    [self _queryWifiAnnoWithBssids:@[bssid] seq:seq]; // 复用既有 wloc 反查标注（坐标+AP 数气泡）
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
        CLLocationCoordinate2D gcj = [CoordTransform wgs84ToGcj02:centroid];
        TRWifiAnnotation *ann = [[TRWifiAnnotation alloc] init];
        ann.coordinate = gcj;
        ann.title = strongSelf.locating ? @"WiFi 定位（模拟位置）" : @"WiFi 定位（wloc 反查）";
        ann.info = [NSString stringWithFormat:@"%.4f, %.4f（%lu 个 AP）",
                    centroid.latitude, centroid.longitude, (unsigned long)result.count];
        ann.subtitle = ann.info;
        [strongSelf.mapView addAnnotation:ann];
    }];
}

/// 模拟开关切换后立即刷新 wifi 标注（用当前语义：模拟中→模拟位置，停止→真实位置）
- (void)refreshWifiAnnotation {
    if (!self.locating) {
        // 停止态：请求 daemon 立即重扫（不等 8s 周期，关模拟瞬间拿到最新真实 BSSID）+
        // 先消费当前缓存立即显示（wloc 反查），随后新扫描 notify 到达再刷新
        notify_post(kTRWifiScanRequestNotification.UTF8String);
        // 消费 daemon 主动扫描真实 BSSID → wloc 反查标注（回到真实 wifi 位置）。
        // 唯一数据源 = 主动扫描 JSON（不做 NEHotspotHelper 回退——用户定案：唯一实现可靠工作）。
        // JSON 缺失/空：清除残留标注，待主动扫描下一次产出数据（notify 回调）恢复。
        NSArray<NSString *> *bssids = [self _readActiveScanBssids];
        if (bssids.count) {
            NSUInteger seq = ++self.wifiQuerySeq;
            [self _queryWifiAnnoWithBssids:bssids seq:seq]; // 真实 BSSID wloc 反查标注（回到真实位置）
        } else {
            [self _refreshWifiAnnoFromCurrentConnection]; // 停止态：同样读当前连接反查（职责统一）
        }
        self.wifiLastTileKey = 0; // 重置瓦片 key：下次开启模拟强制重新反查
        self.wifiTileAps = nil;   // 清瓦片 AP 池（停止态不保留模拟指纹，2026-08-28）
        return;
    }
    [self _refreshWifiAnnoFromCurrentConnection]; // 模拟态：当前连接 BSSID 反查（与模拟坐标解耦）
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
/// 残留的 anchor/itinerary 模式强制写 off（App 启动态=停止=执行契约，daemon 强制对齐停止、locationd 恢复真实），
/// 避免"启动即自动开启模拟 / 真实位置被当模拟位置 / 恢复态 Follow 干扰搜索聚焦"
- (void)readCurrentStatus {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    NSString *mode = [d stringForKey:@"SimLocationMode"];
    if ([mode isEqualToString:@"anchor"] || [mode isEqualToString:@"itinerary"]) {
        [d setObject:@"off" forKey:@"SimLocationMode"];
        [d synchronize];
        notify_post(TVNC_NOTIFY_PREFS_CHANGED);
    }
    self.locating = NO;   // 不恢复定位中；self.cur 保持 0,0，初始视野/聚焦以 locationd（真实）为准
    [self updateStatus];
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
    CLLocationCoordinate2D gcj = [self.mapView convertPoint:pt toCoordinateFromView:self.mapView];
    NSString *mode = (self.modeSeg.selectedSegmentIndex == 1) ? @"drive" : @"walk";
    [self.segments addObject:@{@"type": @"anchor", @"lat": @(gcj.latitude), @"lon": @(gcj.longitude), @"mode": mode}];
    if (self.segments.count == 1) {
        // 第一个锚点：判断是否有当前位置（持久化/注入的）
        CLLocationCoordinate2D curPos = [self currentSimPosition]; // lastFix 优先（daemon 注入的当前位置）
        BOOL hasCurPos = (curPos.latitude != 0 || curPos.longitude != 0);
        if (hasCurPos) {
            // 有当前位置（持久化恢复）：基于当前位置创建锚点（起点，消费），点击位置作为终点 → 生成路线
            // 当前位置锚点插到点击位置前面（segments[0]=起点，segments[1]=终点）
            CLLocationCoordinate2D curG = [CoordTransform wgs84ToGcj02:curPos];
            [self.segments insertObject:@{@"type": @"anchor", @"lat": @(curG.latitude), @"lon": @(curG.longitude), @"mode": mode}
                                atIndex:0];
            self.hasStart = YES;
            self.cur = curG;   // 保持当前位置（不跳到点击位置）
            [self _syncSelfDrivenDroplet];
            [self runEdit:^{ [self commitItinerary]; }];  // 生成 当前位置 → 点击位置 路线
            [self setHint:@"已基于当前位置创建锚点 · 路线从当前位置生长"];
        } else {
            // 首次启动无当前位置：点击点成为当前定位；聚焦该点但不开启模拟播放
            self.hasStart = YES;
            self.cur = gcj;
            // 不设 self.locating（保持 OFF）——首锚点只设位置，不开启模拟播放
            [self _syncSelfDrivenDroplet]; // 自驱水滴跟随新首锚点（cur 已就绪）
            [self commitAnchor];
            // 启用 MKUserLocation 跟随注入位置（daemon off 分支已开定位）
            [self _updateDropletMode];
            [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(gcj, 3000, 3000) animated:YES]; // 立即聚焦锚点
            self.lastAutoFocusWGS = [CoordTransform gcj02ToWgs84:gcj]; // 自动聚焦基线
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
    CLLocationCoordinate2D gcj = [self.mapView convertPoint:pt toCoordinateFromView:self.mapView];
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            self.regionPicking = YES;
            self.regionCenter = gcj;
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
                CLLocationCoordinate2D gcjW = [CoordTransform gcj02ToWgs84:gcj];
                CLLocationCoordinate2D centerW = [CoordTransform gcj02ToWgs84:self.regionCenter];
                self.regionRadiusM = MAX(50, MIN(5000, [SimRouteCalculator haversineMeters:centerW to:gcjW]));
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
    // 链首 region 段（无前驱锚点）：在区域内自生成入口锚点（2026-08-28 用户定案：
    // 区域漫游独立成环，不从当前位置/0,0 起链）——随机取半径内 0.3~0.8 因子一点（避开边缘/圆心），
    // 插为链首后区域段成为 index 1 正常生成；cur 一并设为入口（供 commitAnchor/currentSimPosition/水滴）
    if (self.segments.count == 0) {
        CLLocationCoordinate2D centerW = [CoordTransform gcj02ToWgs84:self.regionCenter];
        double ang = (double)(arc4random_uniform(62832)) / 10000.0; // 0~2π
        double distM = self.regionRadiusM * (0.3 + (double)(arc4random_uniform(50)) / 100.0);
        double cosLat = cos(centerW.latitude * M_PI / 180.0);
        CLLocationCoordinate2D entryW = CLLocationCoordinate2DMake(
            centerW.latitude + distM * sin(ang) / 111320.0,
            centerW.longitude + distM * cos(ang) / (111320.0 * cosLat));
        CLLocationCoordinate2D entryG = [CoordTransform wgs84ToGcj02:entryW];
        [self.segments addObject:@{@"type": @"anchor",
            @"lat": @(entryG.latitude), @"lon": @(entryG.longitude),
            @"mode": (self.modeSeg.selectedSegmentIndex == 1) ? @"drive" : @"walk"}];
        self.hasStart = YES;
        self.cur = entryG;
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

- (void)toggleLocate:(UIButton *)sender {
    if (self.locating) {
        // 停止定位：位置停编排最后坐标（App 内保留显示），设备恢复真实定位
        self.locating = NO;
        self.pendingEditAction = nil;    // 放弃生成中挂起的编辑（停止后不再生长/复活设备）
        self.stopTimestamp = [[NSDate date] timeIntervalSince1970]; // 记停止时刻：停止分支只认晚于此的真实 fix（过滤模拟残留）
        [self commitStop];
        self.mapView.userTrackingMode = MKUserTrackingModeNone; // 退出原生跟随（水滴随 locationd 恢复真实）
        [self refreshUserLocationView];                          // 当前位置水滴去图标（未定位=纯绿点）
        [self focusRealLocationNow];                             // 聚焦当前位置（水滴同源）
        [self refreshWifiAnnotation];                            // 停止：立即恢复真实 wifi 位置（不等下次系统扫描回调）
    } else {
        // 开启：有起点则 anchor，否则提示先设起点
        if (!self.hasStart) {
            [self setHint:@"请先点击地图设定模拟位置起点"];
            return;
        }
        self.locating = YES;
        self.startTimestamp = [[NSDate date] timeIntervalSince1970]; // 记开启时刻：模拟分支只认晚于此的 fix（过滤注入落地前的真实残留）
        self.startupLockedToAnchor = YES; // 开启瞬间到注入落地前：锁定锚点位置显示，忽略真实 fix（防"真实→锚点"横跳）
        [self commitAnchor]; // 写坐标+notify（不写模式）
        // 写模式=anchor（开启模拟/播放开关）；有路线则写 itinerary
        {
            NSUserDefaults *d2 = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
            BOOL hasRoute = [[NSFileManager defaultManager] fileExistsAtPath:kTRSimTrackFilePath];
            [d2 setObject:hasRoute ? @"itinerary" : @"anchor" forKey:@"SimLocationMode"];
            [d2 synchronize];
            notify_post(TVNC_NOTIFY_PREFS_CHANGED);
        }
        [self refreshUserLocationView];       // 当前位置水滴恢复出行图标
        // 停止后再开启：之前模拟位置（cur）距当前实际位置（lastFix=真实或残留）>500m → 瞬间跳回停止前位置（复用首锚点视野行为）；
        // 距离近（位置本就在附近/残留）不跳——维持"开启不主动聚焦"的常规语义
        if (self.lastFix) {
            CLLocationCoordinate2D curW = [CoordTransform gcj02ToWgs84:self.cur];
            if ((curW.latitude != 0 || curW.longitude != 0)
                && [SimRouteCalculator haversineMeters:curW to:self.lastFix.coordinate] > kAutoFocusThresholdM) {
                [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(self.cur, 3000, 3000) animated:YES];
            }
        }
        self.lastAutoFocusWGS = [CoordTransform gcj02ToWgs84:self.cur]; // 自动聚焦基线=模拟位置（拖动退出 Follow 后模拟位置超阈值才拉回）
        self.mapView.userTrackingMode = MKUserTrackingModeFollow; // 原生跟随：MapKit 内部位置源持续订阅 locationd → 水滴跟随模拟位置（单一数据源）
        [self refreshWifiAnnotation];                            // 开启：立即切到模拟位置 wifi 标注（不等下次系统扫描回调）
    }
    [self _updateDropletMode]; // 水滴模式统一切换（定位开关变更后：系统定位开=MKUserLocation / 关=自驱水滴）
    [self updateStatus];
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
    CLLocationCoordinate2D wgs = item.placemark.coordinate;
    CLLocationCoordinate2D gcj = [CoordTransform wgs84ToGcj02:wgs];
    NSString *mode = (self.modeSeg.selectedSegmentIndex == 1) ? @"drive" : @"walk";
    [self.segments addObject:@{@"type": @"anchor", @"lat": @(gcj.latitude), @"lon": @(gcj.longitude), @"mode": mode}];
    if (self.segments.count == 1) {
        // 第一个锚点：判断是否有当前位置（持久化/注入的）
        CLLocationCoordinate2D curPos = [self currentSimPosition];
        BOOL hasCurPos = (curPos.latitude != 0 || curPos.longitude != 0);
        if (hasCurPos) {
            // 有当前位置：基于当前位置创建锚点（起点，消费），搜索位置作为终点 → 生成路线
            CLLocationCoordinate2D curG = [CoordTransform wgs84ToGcj02:curPos];
            [self.segments insertObject:@{@"type": @"anchor", @"lat": @(curG.latitude), @"lon": @(curG.longitude), @"mode": mode}
                                atIndex:0];
            self.hasStart = YES;
            self.cur = curG;   // 保持当前位置
            [self _syncSelfDrivenDroplet];
            [self runEdit:^{ [self commitItinerary]; }];  // 生成 当前位置 → 搜索位置 路线
            [self setHint:@"已基于当前位置创建锚点 · 路线从当前位置生长"];
        } else {
            // 首次启动无当前位置：搜索点成为第一锚点+当前定位；聚焦但不开启模拟播放
            self.hasStart = YES;
            self.cur = gcj;
            self.startTimestamp = [[NSDate date] timeIntervalSince1970]; // 记开启时刻：过滤旧 fix
            self.startupLockedToAnchor = YES; // 锁定锚点显示，忽略旧位置（防"旧→新"横跳）
            // 不设 self.locating（保持 OFF）——首锚点只设位置，不开启模拟播放
            [self _syncSelfDrivenDroplet]; // 自驱水滴跟随新首锚点（cur 已就绪）
            [self commitAnchor];
            [self _updateDropletMode]; // 确保 MKUserLocation 跟随注入位置
            [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(gcj, 3000, 3000) animated:YES];
            self.lastAutoFocusWGS = [CoordTransform gcj02ToWgs84:gcj]; // 自动聚焦基线
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
    NSString *modeTxt = self.locating ? @"模拟中 · 定位" : @"已停止 · 定位";
    if (self.locating) {
        // 速度 = 当前所在路线（出发锚点段）的生成速度——updateAnchorPassStateWithLiveWGS 已从段缓存更新 currentLegSpeed
        speedTxt = [NSString stringWithFormat:@"%.1f m/s", self.currentLegSpeed];
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
    // 状态圆点：定位中=绿（glow），停止=灰（对齐原型 stat .p.on）
    self.statusDot.backgroundColor = self.locating ? [UIColor colorWithRed:0.11 green:0.79 blue:0.51 alpha:1.0] : [UIColor systemGrayColor];
    self.statusDot.layer.shadowColor = self.locating ? self.statusDot.backgroundColor.CGColor : [UIColor clearColor].CGColor;
    self.statusDot.layer.shadowOpacity = self.locating ? 0.6 : 0;
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
        [self.anchors addObject:a];
        [self.mapView addAnnotation:a];
    }
}

/// 段目标锚点坐标（WGS；anchor 用 lat/lon，旧 route 兼容 to）
- (CLLocationCoordinate2D)anchorWGSOfSegment:(NSDictionary *)seg {
    if ([seg[@"type"] isEqualToString:@"region"]) {
        // region 段目标锚点 = 区域中心（region 段无 lat/lon，缺失此分支会取到 (0,0) → 涉及 region 段的编辑路线乱连）
        return [CoordTransform gcj02ToWgs84:CLLocationCoordinate2DMake([seg[@"center"][@"lat"] doubleValue], [seg[@"center"][@"lon"] doubleValue])];
    }
    if ([seg[@"to"] isKindOfClass:[NSDictionary class]]) {
        return [CoordTransform gcj02ToWgs84:CLLocationCoordinate2DMake([seg[@"to"][@"lat"] doubleValue], [seg[@"to"][@"lon"] doubleValue])];
    }
    return [CoordTransform gcj02ToWgs84:CLLocationCoordinate2DMake([seg[@"lat"] doubleValue], [seg[@"lon"] doubleValue])];
}

/// 删除第 idx 锚点（任意锚点）：锚点链顺序语义——删锚 k 只重算跨过它的连接段（前驱→后继），
/// 其余段点序列缓存与生长线保留；删首=当前位置作起点、删尾=轨迹截断保持当前位置
- (void)deleteSegmentAt:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.segments.count) return;
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
        [self focusRealLocationNow];                             // 聚焦当前位置（水滴同源）
        [self setHint:@"已清空行程 · 停止模拟定位"];
        [self updateStatus];
        [self syncSegmentsUI];
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

/// 读当前位置（WGS）——权威 = 最近一次通过过滤的回调 fix（lastFix，locationd 广播真实值，不读 locationManager 属性缓存）；
/// 模拟开启=注入位置/关闭=真实位置；无 fix 时回退 self.cur
- (CLLocationCoordinate2D)currentSimPosition {
    if (self.lastFix) return self.lastFix.coordinate;
    return [CoordTransform gcj02ToWgs84:self.cur];
}

/// 停止定位后只记录自动聚焦基线（停止瞬间位置=模拟残留）——不主动聚焦：
/// 聚焦完全交给订阅驱动（首个真实 fix 距基线超阈值 → maybeAutoFocus 自动聚焦，防残留抢占）
- (void)focusRealLocationNow {
    self.lastAutoFocusWGS = [self currentSimPosition];
}

/// 自动聚焦（距离阈值）：fix 距上次自动聚焦点 ≥ 阈值才聚焦一次并更新基线。
/// 基线未初始化（启动时 lastAutoFocusWGS=(0,0)）→ 首个 fix 建立基线并聚焦（打开 APP 聚焦当前位置）；
/// 已初始化 → 残留 fix（≈基线）不触发、大幅位移（停止回真实/模拟出视野）必触发、GPS 抖动（<50m）不打扰
- (void)maybeAutoFocus:(CLLocationCoordinate2D)wgs {
    BOOL uninitialized = (self.lastAutoFocusWGS.latitude == 0 && self.lastAutoFocusWGS.longitude == 0);
    if (!uninitialized && [SimRouteCalculator haversineMeters:wgs to:self.lastAutoFocusWGS] < kAutoFocusThresholdM) return;
    self.lastAutoFocusWGS = wgs;
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance([CoordTransform wgs84ToGcj02:wgs], 3000, 3000) animated:YES];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.fabGoldGradient.frame = self.locateFab.bounds; // 渐变金底随 FAB 布局同步（创建时 bounds 为 0，必须布局后更新，否则铜钱背景近乎透明）
}

/// 地图立即聚焦到当前位置（首锚点/启动定位/停止/回前台时调用）
/// 定位中=聚焦 self.cur（模拟位置，App 已知锚点）；未定位=GPS 活跃订阅真实位置优先，无 GPS 用 wifi 真实位置兜底
- (void)focusMapOnCurrentLocation {
    CLLocationCoordinate2D center = self.locating ? self.cur
                                                   : [CoordTransform wgs84ToGcj02:[self currentSimPosition]];
    // GPS 无 fix（locationd 未就绪）→ wifi 位置兜底（wifiCurWGS，真实 wifi 反查质心）
    if (center.latitude == 0 && center.longitude == 0) {
        center = [CoordTransform wgs84ToGcj02:self.wifiCurWGS];
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

/// 水滴模式统一切换（viewDidLoad/toggleLocate/locationManagerDidChangeAuthorization 调用）：
/// 系统定位开 → showsUserLocation=YES（MKUserLocation 跟 locationd，模拟/真实同源）+ 移除自驱水滴；
/// 系统定位关 → showsUserLocation=NO（locationd 无广播）+ 自驱水滴跟编排位置 self.cur
- (void)_updateDropletMode {
    if ([self _systemLocationAvailable]) {
        self.mapView.showsUserLocation = YES; // 系统定位开：MKUserLocation 走 locationd（模拟/真实同源）
    } else {
        self.mapView.showsUserLocation = NO; // 系统定位关：locationd 无广播，由自驱水滴替代
    }
    [self _syncSelfDrivenDroplet];
}

/// 自驱当前位置水滴维护（幂等）：系统定位关且定位开关开启且 self.cur 有效 → 创建/跟随 self.cur（编排位置真相源）；
/// 否则移除（定位开时不显示自驱水滴，避免与 MKUserLocation 双层重复）。self.cur 全部赋值点与定位开关切换后调用
- (void)_syncSelfDrivenDroplet {
    TRSelfDrivenDroplet *drop = self.selfDrivenDroplet;
    // 2026-08-29 定案：只要有有效位置就显示绿色水滴（不依赖 self.locating——首锚点后 locating=NO 也显示）
    if (![self _systemLocationAvailable] && (self.cur.latitude != 0 || self.cur.longitude != 0)) {
        if (!drop) {
            drop = [[TRSelfDrivenDroplet alloc] init];
            drop.title = @"当前位置";
            [self.mapView addAnnotation:drop];
            self.selfDrivenDroplet = drop;
        }
        drop.coordinate = self.cur; // GCJ-02 地图坐标，MKAnnotationView coordinate 直接使用（KVO 自动移动视图）
    } else {
        if (drop) {
            [self.mapView removeAnnotation:drop];
            self.selfDrivenDroplet = nil;
        }
    }
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
    [self _updateDropletMode]; // 授权变化：水滴模式统一切换（开→MKUserLocation / 拒绝→自驱水滴跟编排位置）
}

/// 定位失败回调（原生能力利用）：定位错误（权限拒绝/无定位源/模拟注入异常）不再静默——
/// 记录日志便于排查（权限拒绝的 UI 提示由 locationManagerDidChangeAuthorization 负责，此处不重复）
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    NSLog(@"[locsim] locationManager failed: code=%ld %@", (long)error.code, error.localizedDescription);
}

/// 当前位置统一处理（主驱动，2026-08-24）：App 自己的活跃订阅（startUpdatingLocation）推送 → 状态栏/锚点/聚焦/self.cur。
/// locationd 对活跃请求持续广播，与水滴（MKMapView 内部位置源）同源。
/// 时间戳分辨新旧（2026-08-24）：开启/停止瞬间有"旧状态残留"抢跑（停止前模拟残留/开启前真实残留），
/// 每个 fix 自带出生时间（CLLocation.timestamp，系统盖章），只认晚于对应切换时刻的 fix——旧货当没看见
- (void)handleLocationUpdate:(CLLocation *)loc {
    if (!loc) return;
    if (self.locating) {
        // 模拟态：只认晚于开启时刻的 fix（注入落地后的模拟位置）——过滤开启瞬间注入落地前的真实残留
        if ([loc.timestamp timeIntervalSince1970] < self.startTimestamp) return;
        // 开启锁定：注入落地前 locationd 广播的还是真实位置——距锚点 >25m 的 fix 忽略（保持锚点显示，防"真实→锚点"横跳）；
        // 注入落地后 fix≈锚点（<25m）→ 解锁，恢复 fix 驱动
        if (self.startupLockedToAnchor) {
            double d = [SimRouteCalculator haversineMeters:loc.coordinate to:[CoordTransform gcj02ToWgs84:self.cur]];
            if (d > 25.0) return;
            self.startupLockedToAnchor = NO;
        }
        self.lastFix = loc; // 记录回调 fix（坐标/速度真相源，不读属性缓存）
        self.cur = [CoordTransform wgs84ToGcj02:loc.coordinate];
        [self _syncSelfDrivenDroplet]; // 定位关时自驱水滴跟编排推进（定位开时不显示自驱水滴，无影响）
        [self _refreshWifiAnnoFromCurrentConnection]; // wifi 水滴驱动：读当前连接 BSSID 反查（不随 fix tick 跟随模拟坐标）
        [self updateAnchorPassStateWithLiveWGS:loc.coordinate]; // 先更新段速度/经过态，状态栏立即反映
        [self updateStatus];
        // 自动聚焦：Follow 原生已跟随无需重复；用户拖动退出 Follow 后模拟位置距上次聚焦点超阈值则拉回
        if (self.mapView.userTrackingMode != MKUserTrackingModeFollow) [self maybeAutoFocus:loc.coordinate];
        return;
    }
    // 停止态：只认晚于停止时刻的 fix（真实位置）——过滤停止瞬间的模拟残留/旧缓存
    if ([loc.timestamp timeIntervalSince1970] <= self.stopTimestamp) return;
    // 首锚点锁定（2026-08-30）：创建锚点后注入落地前，locationd 广播的还是旧位置——
    // 距新锚点 >25m 的 fix 忽略（保持锚点位置显示，防"旧→新"横跳）；注入落地后 fix≈锚点（<25m）→ 解锁
    if (self.startupLockedToAnchor) {
        double d = [SimRouteCalculator haversineMeters:loc.coordinate to:[CoordTransform gcj02ToWgs84:self.cur]];
        if (d > 25.0) return;
        self.startupLockedToAnchor = NO;
    }
    self.lastFix = loc; // 记录回调 fix
    // 更新当前位置（首锚点注入落地后，self.cur 跟随 locationd 注入位置）
    self.cur = [CoordTransform wgs84ToGcj02:loc.coordinate];
    [self _syncSelfDrivenDroplet]; // 定位关时自驱水滴跟随
    [self updateStatus];
    // 自动聚焦（距离阈值）：真实 fix 距停止瞬间基线（模拟残留）超阈值才聚焦——
    // 残留 fix（≈基线）不触发、真实 fix（画布外）必触发；GPS 收敛渐进超阈值再拉回
    [self maybeAutoFocus:loc.coordinate];
}

/// App 自己的活跃订阅回调（locationd 广播）：唯一驱动
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    [self handleLocationUpdate:locations.lastObject];
}

/// 锚点状态刷新（O(锚点数)，修复全量轨迹扫描卡顿）：当前位置距锚点 < 阈值视为"经过"（passed 单调不回退），
/// 锚点红蓝 + 当前位置水滴出行图标切换。轨迹单向推进（算路生成），无需按轨迹索引判定——
/// 旧实现每刷新对每个锚点全量遍历 submittedPoints 找最近索引（区域轨迹可达数万点 → 主线程 O(A×P) haversine 卡死）
/// liveW 为当前位置（WGS）；仅定位中生效（停止态颜色定格）
- (void)updateAnchorPassStateWithLiveWGS:(CLLocationCoordinate2D)liveW {
    if (!self.locating || self.anchors.count == 0) return;
    static const double kPassedThresholdM = 25.0; // 距锚点 25m 内视为经过（停留微动 ±1m 远小于阈值，锚点间距通常 >50m）
    TRAnchorAnnotation *departAnchor = nil; // 当前位置所在段的出发锚点 = 已经过的最后一个锚点
    for (TRAnchorAnnotation *a in self.anchors) {
        CLLocationCoordinate2D aW = [CoordTransform gcj02ToWgs84:a.coordinate];
        BOOL passed = [SimRouteCalculator haversineMeters:liveW to:aW] < kPassedThresholdM;
        if (passed != a.passed) {
            a.passed = passed;
            MKAnnotationView *v = [self.mapView viewForAnnotation:a];
            if (v) v.image = [self waterdropImageWithColor:(passed ? [UIColor colorWithRed:0.94 green:0.23 blue:0.13 alpha:1.0] : [UIColor colorWithRed:0.13 green:0.65 blue:0.97 alpha:1.0]) size:22 emoji:[self emojiForMode:a.mode]];
        }
        if (a.passed) departAnchor = a; // 已经过的最后一个锚点 = 当前位置所在段的出发锚点
    }
    // 当前位置出行方式：取所在段出发锚点的出行方式；链首/空则退回首个锚点或当前选择
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
        // 左：拖动图标（最前；拖拽排序走 dragDelegate，整行可拖）
        UIImageView *drag = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal"]];
        drag.tag = 201;
        drag.tintColor = [UIColor secondaryLabelColor];
        drag.frame = CGRectMake(10, 13, 20, 18);
        drag.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin;
        [cell.contentView addSubview:drag];
        // 标题 / 副标题（自绘，避开左侧拖动图标；删除走系统原生右滑，无自绘删除按钮）
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
    [cell.contentView viewWithTag:201].hidden = NO;
    NSDictionary *seg = self.segments[indexPath.row];
    NSString *type = seg[@"type"];
    NSString *title = @"";
    NSString *sub = @"";
    if ([type isEqualToString:@"anchor"]) {
        title = @"锚点";
        CLLocationCoordinate2D w = [CoordTransform gcj02ToWgs84:CLLocationCoordinate2DMake([seg[@"lat"] doubleValue], [seg[@"lon"] doubleValue])];
        sub = [NSString stringWithFormat:@"%.4f, %.4f", w.latitude, w.longitude];
    } else {
        title = @"区域漫游";
        sub = [NSString stringWithFormat:@"%.0f m · %@ min", [seg[@"radius"] doubleValue], seg[@"durationMin"]];
    }
    ((UILabel *)[cell.contentView viewWithTag:203]).text = [NSString stringWithFormat:@"%ld  %@", (long)(indexPath.row + 1), title];
    ((UILabel *)[cell.contentView viewWithTag:204]).text = sub;
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
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance([CoordTransform wgs84ToGcj02:wgs], 2000, 2000) animated:YES];
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
    return tableView == self.stepTable;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    if (tableView == self.stepTable) {
        [self moveSegmentFrom:from.row to:to.row];
    }
}

#pragma mark - UITableViewDragDelegate / UITableViewDropDelegate（原生拖拽排序：整行可拖）

- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath {
    if (tableView != self.stepTable) return @[];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.segments.count) return @[];
    NSItemProvider *ip = [[NSItemProvider alloc] initWithObject:@(indexPath.row)];
    UIDragItem *item = [[UIDragItem alloc] initWithItemProvider:ip];
    item.localObject = @(indexPath.row);
    return @[item];
}

- (UITableViewDropProposal *)tableView:(UITableView *)tableView dropSessionDidUpdate:(id<UIDropSession>)session withDestinationIndexPath:(NSIndexPath *)destinationIndexPath {
    if (tableView != self.stepTable) return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationForbidden];
    return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationMove intent:UITableViewDropIntentInsertAtDestinationIndexPath];
}

- (void)tableView:(UITableView *)tableView performDropWithCoordinator:(id<UITableViewDropCoordinator>)coordinator {
    if (tableView != self.stepTable) return;
    NSIndexPath *dest = coordinator.destinationIndexPath;
    if (!dest) dest = [NSIndexPath indexPathForRow:MAX(0, (NSInteger)self.segments.count - 1) inSection:0];
    for (id<UITableViewDropItem> di in coordinator.items) {
        NSNumber *fromRow = di.dragItem.localObject;
        if ([fromRow isKindOfClass:[NSNumber class]]) {
            NSInteger from = fromRow.integerValue;
            if (from >= 0 && from < (NSInteger)self.segments.count) [self moveSegmentFrom:from to:dest.row];
            break;
        }
    }
}

#pragma mark - 落盘自治（App=配置源，manager=注入执行器）

- (void)commitAnchor {
    // 2026-08-29 定案：只写坐标，不写模式——daemon off 分支检测坐标变化后注入+开定位，保持模式为 off
    CLLocationCoordinate2D wgs = [CoordTransform gcj02ToWgs84:self.cur];
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    [d setDouble:wgs.latitude forKey:@"SimLocationLat"];
    [d setDouble:wgs.longitude forKey:@"SimLocationLon"];
    [d synchronize];
    notify_post(TVNC_NOTIFY_PREFS_CHANGED);
}

- (void)commitStop {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    [d setObject:@"off" forKey:@"SimLocationMode"];
    [d synchronize];
    notify_post(TVNC_NOTIFY_PREFS_CHANGED);
}

/// 重算期间让 daemon 驻留在当前位置（anchor 微动）：编辑（删除/重排）重算耗时期间，
/// 避免 daemon 继续沿已删除/已重排的旧轨迹移动（走向被删锚点）+ 重载时旧轨迹被截断的回跳——
/// "只要不是停止定位，编辑时底层保持当前位置不乱跳"（仅定位中生效；停止态编辑不动 daemon）
- (void)holdAtCurrentPosition:(CLLocationCoordinate2D)curW {
    if (!self.locating) return;
    // 2026-08-29 定案：只写坐标，不写模式——编辑时保持当前模式不变
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    [d setDouble:curW.latitude forKey:@"SimLocationLat"];
    [d setDouble:curW.longitude forKey:@"SimLocationLon"];
    [d synchronize];
    notify_post(TVNC_NOTIFY_PREFS_CHANGED);
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

/// 生长可视化：每段算路点序列追加为生长轨迹线（算路点 WGS-84 → 画图转 GCJ-02，否则路线与点击点偏移数百米）
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
        cs[i] = [CoordTransform wgs84ToGcj02:CLLocationCoordinate2DMake([p[@"lat"] doubleValue], [p[@"lon"] doubleValue])];
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

/// 全链收尾：展平 submittedPoints + 按段重画生长线（段点序列已缓存，同步瞬画不涉及算路）+ 写轨迹 + 释放生成锁
- (void)finishChainSync {
    NSMutableArray *joined = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)self.segments.count; i++) {
        id pts = (i < (NSInteger)self.segmentPoints.count) ? self.segmentPoints[i] : nil;
        if ([pts isKindOfClass:[NSArray class]]) [joined addObjectsFromArray:pts];
    }
    self.submittedPoints = joined;
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
    CLLocationCoordinate2D centerW = [CoordTransform gcj02ToWgs84:CLLocationCoordinate2DMake([seg[@"center"][@"lat"] doubleValue], [seg[@"center"][@"lon"] doubleValue])];
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
        // 途经点坐标转 GCJ-02（plan 返回 WGS-84；地图显示坐标系=GCJ，与生长线 appendGrowLine 同转换，不转则图标偏离路线数百米）
        w.coordinate = [CoordTransform wgs84ToGcj02:[wps[k] MKCoordinateValue]];
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
    BOOL locating = self.locating;
    static dispatch_queue_t sTrackWriteQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sTrackWriteQueue = dispatch_queue_create("com.82flex.trollvnc.trackwrite", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(sTrackWriteQueue, ^{
        NSDictionary *payload = @{ @"version": @1, @"points": snapshot };
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
        // 实心水滴图钉（状态分类：未经过=蓝/已经过=红；内嵌该锚点生成时的出行方式图标；尖对准坐标点）
        UIColor *color = a.passed
            ? [UIColor colorWithRed:0.94 green:0.23 blue:0.13 alpha:1.0]
            : [UIColor colorWithRed:0.13 green:0.65 blue:0.97 alpha:1.0];
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
    if ([annotation isKindOfClass:[TRSelfDrivenDroplet class]]) {
        // 自驱当前位置水滴（定位关闭时替代 MKUserLocation）：绿色水滴+出行图标，外观/光晕对齐原生 MKUserLocation
        static NSString *rid = @"SelfDrivenCurPin";
        MKAnnotationView *v = [mapView dequeueReusableAnnotationViewWithIdentifier:rid];
        if (!v) {
            v = [[MKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:rid];
            v.canShowCallout = NO;
            v.userInteractionEnabled = YES; // 供 shouldReceiveTouch 拦截，防 tap 误加锚点
        }
        v.annotation = annotation;
        NSString *mode = self.currentLegMode ?: (self.modeSeg.selectedSegmentIndex == 1 ? @"drive" : @"walk");
        UIColor *green = [UIColor colorWithRed:0.11 green:0.79 blue:0.51 alpha:1.0];
        v.image = [self waterdropImageWithColor:green size:24 emoji:[self emojiForMode:mode]];
        v.centerOffset = CGPointMake(0, -15); // 尖对准坐标点
        v.frame = CGRectMake(0, 0, 24, 30);
        v.layer.shadowColor = green.CGColor; // 光晕（对齐原生 MKUserLocation）
        v.layer.shadowOpacity = 0.6;
        v.layer.shadowRadius = 6;
        v.layer.shadowOffset = CGSizeMake(0, 0);
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
                if ([av.annotation isKindOfClass:[TRSelfDrivenDroplet class]]) return NO; // 自驱当前位置水滴：不触发 tap 加锚点
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
