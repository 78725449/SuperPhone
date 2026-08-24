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
#import <notify.h>
#import "CoordTransform.h"
#import "RegionSimulator.h"
#import "SimRouteCalculator.h"

/// 轨迹文件路径（与 SimLocationController kSimTrackFilePath 一致，App 只当配置源、manager 注入执行）
static NSString *const kSimTrackFilePath = @"/var/mobile/Library/Caches/com.82flex.trollvnc.simloc.json";
static NSString *const kPrefsSuite = @"com.82flex.trollvnc";
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

/// 生长轨迹线（对齐原型 growPath/addedPath：区域自生长逐段可视化 + 完成后常显；与预览虚线区分）
/// 分段式渲染：每个覆盖层挂所属编排段索引，增删/重算只动受影响段
@interface TRGrowPolyline : MKPolyline
@property (nonatomic, assign) NSInteger segmentIndex; // 所属编排段（用于按段移除）
@end
@implementation TRGrowPolyline
@end

@interface TRMapPickerViewController () <MKMapViewDelegate, UISearchBarDelegate, UIGestureRecognizerDelegate, UITableViewDataSource, UITableViewDelegate, CLLocationManagerDelegate, UITableViewDragDelegate, UITableViewDropDelegate>
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *searchResultsView;       // 搜索下拉结果列表（搜索框内向下展开）
@property (nonatomic, strong) NSArray *searchResults;               // MKMapItem 数组
@property (nonatomic, strong) UISegmentedControl *modeSeg;   // 步行/驾车（左下胶囊）
@property (nonatomic, strong) UIButton *locateFab;           // 右下角圆形定位开关
@property (nonatomic, strong) UIButton *focusBtn;                   // 定位 FAB 上方的靶心按钮（点击聚焦当前位置）
@property (nonatomic, strong) UIButton *statusBtn;                   // 状态条（用 setTitle 渲染，titleLabel.text 直接赋值无效）
@property (nonatomic, strong) UIView *statusDot;                     // 状态圆点（定位中绿/停止灰）
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

/// 启动状态（2026-08-24 定：启动一律停止态）：
/// 残留的 anchor/itinerary 模式强制写 off（App 启动态=停止=执行契约，daemon 强制对齐停止、locationd 恢复真实），
/// 避免"启动即自动开启模拟 / 真实位置被当模拟位置 / 恢复态 Follow 干扰搜索聚焦"
- (void)readCurrentStatus {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    NSString *mode = [d stringForKey:@"SimLocationMode"];
    if ([mode isEqualToString:@"anchor"] || [mode isEqualToString:@"itinerary"]) {
        [d setObject:@"off" forKey:@"SimLocationMode"];
        [d synchronize];
        notify_post("com.82flex.trollvnc.prefs-changed");
    }
    self.locating = NO;   // 不恢复定位中；self.cur 保持 0,0，初始视野/聚焦以 locationd（真实）为准
    [self updateStatus];
}

#pragma mark - 手势：单击递增编排

/// 单击地图 = 添加锚点（无起点差别：所有位置都是锚点）
/// 第一个锚点无前驱（前方没有任何锚点）→ 仅当前定位（anchor 注入）；
/// 后续锚点前方都有上一个锚点 → 从上一锚点生长路线到本锚点（增量生长）
- (void)handleTap:(UIGestureRecognizer *)g {
    CGPoint pt = [g locationInView:self.mapView];
    // 点击锚点水滴的拦截由 shouldReceiveTouch 在 touch 阶段完成（早于 didSelect 删除时序，无竞态）。
    // 此处不再做 ended 检测兜底——删除重建后 annotations 已变，兜底检测本身会产生竞态误判（单机制原则）
    CLLocationCoordinate2D gcj = [self.mapView convertPoint:pt toCoordinateFromView:self.mapView];
    NSString *mode = (self.modeSeg.selectedSegmentIndex == 1) ? @"drive" : @"walk";
    [self.segments addObject:@{@"type": @"anchor", @"lat": @(gcj.latitude), @"lon": @(gcj.longitude), @"mode": mode}];
    if (self.segments.count == 1) {
        // 第一个锚点：无前驱 → 点击点成为当前定位；立即聚焦该点并原生跟随
        self.hasStart = YES;
        self.cur = gcj;
        self.locating = YES;
        self.startTimestamp = [[NSDate date] timeIntervalSince1970]; // 记开启时刻（同 toggleLocate）
        self.startupLockedToAnchor = YES; // 注入落地前锁定锚点显示（防"真实→锚点"横跳，同 toggleLocate）
        [self commitAnchor];
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(gcj, 3000, 3000) animated:YES]; // 立即聚焦锚点
        self.lastAutoFocusWGS = [CoordTransform gcj02ToWgs84:gcj]; // 自动聚焦基线（同 toggleLocate）
        self.mapView.userTrackingMode = MKUserTrackingModeFollow; // 原生跟随（水滴跟随 locationd）
        [self setHint:@"已设定位点 · 继续点击添加锚点生长路线"];
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
    [self.segments addObject:seg];
    [self.regionPanel removeFromSuperview];
    self.regionPanel = nil;
    if (self.regionOverlay) { [self.mapView removeOverlay:self.regionOverlay]; self.regionOverlay = nil; }
    // 区域漫游可从当前位置进入（无前置 anchor 起点）——链首为 region 段即视为已设起点，允许开启定位
    if (!self.hasStart) self.hasStart = YES;
    // 区域中心只是目标，不是当前位置——当前位置图标保持当前实际位置（不瞬移）
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
    } else {
        // 开启：有起点则 anchor，否则提示先设起点
        if (!self.hasStart) {
            [self setHint:@"请先点击地图设定模拟位置起点"];
            return;
        }
        self.locating = YES;
        self.startTimestamp = [[NSDate date] timeIntervalSince1970]; // 记开启时刻：模拟分支只认晚于此的 fix（过滤注入落地前的真实残留）
        self.startupLockedToAnchor = YES; // 开启瞬间到注入落地前：锁定锚点位置显示，忽略真实 fix（防"真实→锚点"横跳）
        [self commitAnchor];
        [self refreshUserLocationView];       // 当前位置水滴恢复出行图标
        self.lastAutoFocusWGS = [CoordTransform gcj02ToWgs84:self.cur]; // 自动聚焦基线=模拟位置（拖动退出 Follow 后模拟位置超阈值才拉回）
        self.mapView.userTrackingMode = MKUserTrackingModeFollow; // 原生跟随：MapKit 内部位置源持续订阅 locationd → 水滴跟随模拟位置（单一数据源）
    }
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
    MKLocalSearchRequest *req = [[MKLocalSearchRequest alloc] init];
    req.naturalLanguageQuery = q;
    MKLocalSearch *ls = [[MKLocalSearch alloc] initWithRequest:req];
    [ls startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !response.mapItems.count) {
                self.searchResults = @[];
                [self.searchResultsView reloadData];
                self.searchResultsView.hidden = YES;
                [self setHint:@"未找到地点"];
                return;
            }
            // 结果依次排开（下拉列表，可向下滑动查看；最多 10 条）
            NSRange rng = NSMakeRange(0, MIN(10, (NSInteger)response.mapItems.count));
            self.searchResults = [response.mapItems subarrayWithRange:rng];
            [self.searchResultsView reloadData];
            self.searchResultsView.hidden = NO;
        });
    }];
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
        // 第一个锚点（也是当前定位）：立即聚焦该点并原生跟随
        self.hasStart = YES;
        self.cur = gcj;
        self.locating = YES;
        self.startTimestamp = [[NSDate date] timeIntervalSince1970]; // 记开启时刻（同 toggleLocate）
        self.startupLockedToAnchor = YES; // 注入落地前锁定锚点显示（防"真实→锚点"横跳，同 toggleLocate）
        [self commitAnchor];
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(gcj, 3000, 3000) animated:YES];
        self.lastAutoFocusWGS = [CoordTransform gcj02ToWgs84:gcj]; // 自动聚焦基线（同 toggleLocate）
        self.mapView.userTrackingMode = MKUserTrackingModeFollow; // 原生跟随（水滴跟随 locationd）
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
    // FAB 图标/颜色随定位状态切换（对齐原型：定位中=停止方块，否则=定位图标；品牌紫底）
    UIColor *brand = [UIColor colorWithRed:0.29 green:0.25 blue:0.89 alpha:1.0];
    [self.locateFab setImage:[UIImage systemImageNamed:self.locating ? @"stop.fill" : @"location.fill"] forState:UIControlStateNormal];
    [self.locateFab setBackgroundColor:self.locating ? brand : [UIColor systemGrayColor]];
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

/// 地图立即聚焦到当前位置（首锚点/启动定位/停止/回前台时调用）
/// 定位中=聚焦 self.cur（模拟位置，App 已知锚点）；未定位=聚焦活跃订阅真实位置
- (void)focusMapOnCurrentLocation {
    CLLocationCoordinate2D center = self.locating ? self.cur
                                                   : [CoordTransform wgs84ToGcj02:[self currentSimPosition]];
    // 守卫：位置无效（从未设过且 locationd 未就绪）→ 不聚焦，保持当前视野
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
        [self updateAnchorPassStateWithLiveWGS:loc.coordinate]; // 先更新段速度/经过态，状态栏立即反映
        [self updateStatus];
        // 自动聚焦：Follow 原生已跟随无需重复；用户拖动退出 Follow 后模拟位置距上次聚焦点超阈值则拉回
        if (self.mapView.userTrackingMode != MKUserTrackingModeFollow) [self maybeAutoFocus:loc.coordinate];
        return;
    }
    // 停止态：只认晚于停止时刻的 fix（真实位置）——过滤停止瞬间的模拟残留/旧缓存
    if ([loc.timestamp timeIntervalSince1970] <= self.stopTimestamp) return;
    self.lastFix = loc; // 记录回调 fix
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
        MKMapItem *item = self.searchResults[indexPath.row];
        cell.textLabel.text = item.name ?: @"地点";
        cell.detailTextLabel.text = item.placemark.title ?: @"";
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
        MKMapItem *item = self.searchResults[indexPath.row];
        [self applySearchResult:item];
        self.searchBar.text = @"";              // 清空搜索输入框
        [self.searchBar resignFirstResponder];
        self.searchResultsView.hidden = YES;
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
    CLLocationCoordinate2D wgs = [CoordTransform gcj02ToWgs84:self.cur];
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    [d setObject:@"anchor" forKey:@"SimLocationMode"];
    [d setDouble:wgs.latitude forKey:@"SimLocationLat"];
    [d setDouble:wgs.longitude forKey:@"SimLocationLon"];
    [d synchronize];
    notify_post("com.82flex.trollvnc.prefs-changed");
}

- (void)commitStop {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    [d setObject:@"off" forKey:@"SimLocationMode"];
    [d synchronize];
    notify_post("com.82flex.trollvnc.prefs-changed");
}

/// 重算期间让 daemon 驻留在当前位置（anchor 微动）：编辑（删除/重排）重算耗时期间，
/// 避免 daemon 继续沿已删除/已重排的旧轨迹移动（走向被删锚点）+ 重载时旧轨迹被截断的回跳——
/// "只要不是停止定位，编辑时底层保持当前位置不乱跳"（仅定位中生效；停止态编辑不动 daemon）
- (void)holdAtCurrentPosition:(CLLocationCoordinate2D)curW {
    if (!self.locating) return;
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    [d setObject:@"anchor" forKey:@"SimLocationMode"];
    [d setDouble:curW.latitude forKey:@"SimLocationLat"];
    [d setDouble:curW.longitude forKey:@"SimLocationLon"];
    [d synchronize];
    notify_post("com.82flex.trollvnc.prefs-changed");
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
        NSString *tmp = [kSimTrackFilePath stringByAppendingString:@".tmp"];
        if (![json writeToFile:tmp options:NSDataWritingAtomic error:nil]) return;
        if ([[NSFileManager defaultManager] fileExistsAtPath:kSimTrackFilePath]) {
            [[NSFileManager defaultManager] removeItemAtPath:kSimTrackFilePath error:nil];
        }
        if (![[NSFileManager defaultManager] moveItemAtPath:tmp toPath:kSimTrackFilePath error:nil]) return;
        if (locating) {
            NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
            [d setObject:@"itinerary" forKey:@"SimLocationMode"];
            [d synchronize];
            notify_post("com.82flex.trollvnc.prefs-changed");
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
