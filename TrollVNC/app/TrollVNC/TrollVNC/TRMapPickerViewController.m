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
@property (nonatomic, strong) NSMutableArray *anchors;       // 每段对应的锚点标注（TRAnchorAnnotation）
@property (nonatomic, strong) NSMutableArray *waypointAnns;          // 区域漫游途经点标注（TRWaypointAnnotation，随区域段生成/重建）
@property (nonatomic, assign) double currentWalkRatio;              // 区域随机模式当前步行占比（随 currentLegMode 同步，默认 0.7）
@property (nonatomic, assign) CLLocationCoordinate2D cur;    // 当前模拟位置（地图坐标 GCJ-02）
@property (nonatomic, assign) BOOL hasStart;
@property (nonatomic, assign) BOOL locating;                // 定位开关状态
@property (nonatomic, copy) NSString *currentLegMode;       // 当前位置水滴的出行方式（当前段目标锚点的，walk/drive）
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
@property (nonatomic, assign) NSInteger committedSegCount;          // 已提交到轨迹的段数（增量生长：只生长新段）
@property (nonatomic, strong) NSArray *submittedPoints;             // 已提交的完整轨迹点序列（上一段结束点=新段起点）

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
        [self commitAnchor];
        [self refreshUserLocationView];       // 当前位置水滴恢复出行图标
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(self.cur, 3000, 3000) animated:YES]; // 立即聚焦锚点
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
        // 速度 = 当前段出行方式的平均速度（模拟播放按该模式速度推进；random 区域=步行/驾车按占比加权）
        // 注：locationd 广播层对模拟注入位置不保留 CLLocation.speed（恒 -1/0），改用模式代表速度——零通道、与时序无耦合
        NSString *m = self.currentLegMode ?: (self.modeSeg.selectedSegmentIndex == 1 ? @"drive" : @"walk");
        double mps;
        if ([m isEqualToString:@"random"]) {
            double wr = self.currentWalkRatio;
            mps = [RegionSimulator effectiveSpeedForMode:@"walk"] * wr
                + [RegionSimulator effectiveSpeedForMode:@"drive"] * (1.0 - wr);
        } else {
            mps = [RegionSimulator effectiveSpeedForMode:m];
        }
        speedTxt = [NSString stringWithFormat:@"%.1f m/s", mps];
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
    if ([seg[@"to"] isKindOfClass:[NSDictionary class]]) {
        return [CoordTransform gcj02ToWgs84:CLLocationCoordinate2DMake([seg[@"to"][@"lat"] doubleValue], [seg[@"to"][@"lon"] doubleValue])];
    }
    return [CoordTransform gcj02ToWgs84:CLLocationCoordinate2DMake([seg[@"lat"] doubleValue], [seg[@"lon"] doubleValue])];
}

/// submittedPoints 中最后一个距 wgs <30m 的点索引（段终点≈目标锚点；锚点间距 >30m 唯一匹配）
- (NSUInteger)lastPointIndexNearWGS:(CLLocationCoordinate2D)wgs {
    const double thr = 30.0;
    for (NSUInteger i = self.submittedPoints.count; i > 0; i--) {
        NSDictionary *p = self.submittedPoints[i - 1];
        if ([SimRouteCalculator haversineMeters:wgs to:CLLocationCoordinate2DMake([p[@"lat"] doubleValue], [p[@"lon"] doubleValue])] < thr) return i - 1;
    }
    return NSNotFound;
}

/// submittedPoints 中第一个距 wgs <30m 的点索引
- (NSUInteger)firstPointIndexNearWGS:(CLLocationCoordinate2D)wgs {
    const double thr = 30.0;
    for (NSUInteger i = 0; i < self.submittedPoints.count; i++) {
        NSDictionary *p = self.submittedPoints[i];
        if ([SimRouteCalculator haversineMeters:wgs to:CLLocationCoordinate2DMake([p[@"lat"] doubleValue], [p[@"lon"] doubleValue])] < thr) return i;
    }
    return NSNotFound;
}

/// 完成局部重算（统一收尾：写轨迹 + 释放生成锁 + 执行挂起编辑）
- (void)finishLocalRegenerate:(NSArray *)joined hint:(NSString *)hint {
    if (joined.count >= 2) {
        self.submittedPoints = joined;
        self.committedSegCount = self.segments.count;
        [self writeTrackFile:joined];
        [self setHint:[NSString stringWithFormat:@"%@ · %lu 点", hint, (unsigned long)joined.count]];
    } else {
        [self setHint:hint];
    }
    self.isGenerating = NO;
    [self runPendingEdit];
}

#pragma mark - 局部重算（锚点编辑只重算受影响段，其余段/生长线不重渲染）

/// 删除第 idx 锚点（任意锚点）：基于当前位置局部重算——保留当前位置前的轨迹点，
/// 从受影响锚点开始重生长；删除最后锚点（无下一个锚点）→ 保持当前位置（轨迹截断到当前位置）
- (void)deleteSegmentAt:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.segments.count) return;
    NSDictionary *removed = self.segments[idx];
    if ([removed[@"type"] isEqualToString:@"region"]) {
        // 区域段删除 → 该区域不再生长，同步清途经点标注（重算不会触发 processRegionPlan 重建）
        for (TRWaypointAnnotation *w in self.waypointAnns) [self.mapView removeAnnotation:w];
        [self.waypointAnns removeAllObjects];
    }
    [self.segments removeObjectAtIndex:idx];
    if (!self.segments.count) {
        // 全部锚点删除 → 停止定位并同步停止 daemon（写 mode=off，设备恢复真实定位），避免 App 停止但设备仍被模拟
        self.hasStart = NO;
        self.locating = NO;
        self.pendingEditAction = nil;    // 清挂起编辑（空链无需再生成）
        self.stopTimestamp = [[NSDate date] timeIntervalSince1970]; // 记停止时刻（同 toggleLocate）
        [self commitStop];
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
    [self updateStatus];
    [self syncSegmentsUI];
    // 纯 anchor 链 → 局部重算（只重算跨过被删锚点的连接段，其余段/线不重渲染）；
    // 删除的是 region 段或剩余链含 region → 退化为全量重算（锚点匹配切分对 region 段不可靠）
    if ([self segmentsContainRegion] || [removed[@"type"] isEqualToString:@"region"]) {
        NSInteger affected = MIN(idx, (NSInteger)self.segments.count);
        [self runEdit:^{ [self regenerateFromIndex:affected]; }];
        [self setHint:@"已删除锚点 · 基于当前位置重算路线"];
    } else {
        [self runEdit:^{ [self localRegenerateAfterDelete:idx]; }];
    }
}

/// 删除锚点 k（segments 已删 k）后的局部重算：只重算"跨过被删锚点的连接段"（原段 k→k+1 合并为 锚k-1→锚k+1），
/// 其余段点序列与生长线完全保留不重渲染；删链尾=截断、删首锚点=当前位置作起点
- (void)localRegenerateAfterDelete:(NSInteger)k {
    if (self.isGenerating) { self.pendingEditAction = ^{ [self localRegenerateAfterDelete:k]; }; return; }
    self.isGenerating = YES;
    NSInteger oldCount = (NSInteger)self.segments.count + 1; // 删前段数（k 为原索引）
    BOOL isTail = (k >= oldCount - 1);                       // 删的是链尾锚点
    // 受影响旧线 segmentIndex ∈ {k, k+1}（段 k：目标=锚k；段 k+1：起点=锚k）；后续线索引左移 1
    for (id o in [self.mapView.overlays copy]) {
        if (![o isKindOfClass:[TRGrowPolyline class]]) continue;
        TRGrowPolyline *line = (TRGrowPolyline *)o;
        if (line.segmentIndex == k || line.segmentIndex == k + 1) {
            [self.mapView removeOverlay:o];
        } else if (line.segmentIndex > k + 1) {
            line.segmentIndex -= 1;
        }
    }
    if (isTail) {
        // 删链尾：截断（保留到原 k-1 锚点前），无新段
        NSMutableArray *joined = [NSMutableArray array];
        if (k > 0) {
            CLLocationCoordinate2D anchorW = [self anchorWGSOfSegment:self.segments[k - 1]];
            NSUInteger keepEnd = [self lastPointIndexNearWGS:anchorW];
            if (keepEnd != NSNotFound && keepEnd < self.submittedPoints.count) {
                for (NSUInteger i = 0; i <= keepEnd; i++) [joined addObject:self.submittedPoints[i]];
            }
        }
        [self finishLocalRegenerate:joined hint:@"已删除最后锚点 · 保持当前位置"];
        return;
    }
    // 新连接段（删除后 segments[k-1]=原锚k-1、segments[k]=原锚k+1）
    CLLocationCoordinate2D fromW, toW;
    NSString *mode;
    if (k == 0) {
        fromW = [self currentSimPosition];      // 删首：当前位置作起点 → 原锚1
        toW = [self anchorWGSOfSegment:self.segments[0]];
        mode = [self departModeForSegment:0];
    } else {
        fromW = [self anchorWGSOfSegment:self.segments[k - 1]];
        toW = [self anchorWGSOfSegment:self.segments[k]];
        mode = [self departModeForSegment:k];
    }
    // 切分：保留受影响段起点前（≤fromW 附近）与终点后（≥toW 附近）的点序列
    NSMutableArray *joined = [NSMutableArray array];
    NSUInteger keepEnd = [self lastPointIndexNearWGS:fromW];
    if (keepEnd != NSNotFound && keepEnd < self.submittedPoints.count) {
        for (NSUInteger i = 0; i <= keepEnd; i++) [joined addObject:self.submittedPoints[i]];
    }
    NSUInteger keepStart = [self firstPointIndexNearWGS:toW];
    NSLog(@"[locsim-grow] del-recalc seg %ld: (%.5f,%.5f)->(%.5f,%.5f)", (long)k, fromW.latitude, fromW.longitude, toW.latitude, toW.longitude);
    [SimRouteCalculator calculateRoutePointsFrom:fromW to:toW mode:mode completion:^(NSArray<NSDictionary *> *points, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) sself = self;
            if (!sself) return;
            if (error || points.count < 2) {
                [sself setHint:@"已忽略无法重算的锚点"];
            } else {
                [joined addObjectsFromArray:points];
                [sself appendGrowLine:points forSegment:k]; // 新连接段线（其余线保留不重渲染）
            }
            if (keepStart != NSNotFound && keepStart < sself.submittedPoints.count) {
                for (NSUInteger i = keepStart; i < sself.submittedPoints.count; i++) [joined addObject:sself.submittedPoints[i]];
            }
            [sself finishLocalRegenerate:joined hint:@"已删除锚点 · 重算连接路线"];
        });
    }];
}

/// 拖拽排序后：基于当前位置局部重算（保留当前位置前轨迹点，从受影响位置重生长）
- (void)moveSegmentFrom:(NSInteger)from to:(NSInteger)to {
    if (from < 0 || to < 0 || from >= (NSInteger)self.segments.count || to >= (NSInteger)self.segments.count || from == to) return;
    NSDictionary *item = self.segments[from];
    NSArray *prevSegments = [self.segments copy]; // 重排前链（用于对比受影响段 + 切分旧点序列）
    [self.segments removeObjectAtIndex:from];
    [self.segments insertObject:item atIndex:to];
    [self syncSegmentsUI];
    // 纯 anchor 链 → 局部重算（只重算起点/目标邻接变化的段）；含 region 段 → 退化全量
    if ([self segmentsContainRegion]) {
        [self setHint:@"行程已重排 · 基于当前位置重算"];
        [self runEdit:^{ [self regenerateFromIndex:0]; }]; // 生成中挂起，完成后再重算
    } else {
        [self runEdit:^{ [self localRegenerateAfterReorder:prevSegments]; }];
    }
}

/// 拖拽重排后的局部重算：只对"起点或目标锚点邻接变化"的段重新算路（串行），
/// 不变段复用旧轨迹点序列即时重画（无算路等待）；含 region 段由调用方退化为全量
- (void)localRegenerateAfterReorder:(NSArray *)prevSegments {
    if (self.isGenerating) { self.pendingEditAction = ^{ [self localRegenerateAfterReorder:prevSegments]; }; return; }
    self.isGenerating = YES;
    NSInteger newCount = (NSInteger)self.segments.count;
    NSInteger oldCount = (NSInteger)prevSegments.count;
    // 受影响段（新链索引 i≥1）：起点/目标锚点邻接组合在旧链中不存在 → 需重新算路
    NSMutableIndexSet *affected = [NSMutableIndexSet indexSet];
    for (NSInteger i = 1; i < newCount; i++) {
        BOOL unchanged = NO;
        for (NSInteger j = 1; j < oldCount; j++) {
            if ([self sameAnchor:self.segments[i - 1] b:prevSegments[j - 1]] &&
                [self sameAnchor:self.segments[i] b:prevSegments[j]]) { unchanged = YES; break; }
        }
        if (!unchanged) [affected addIndex:(NSUInteger)i];
    }
    // 切分旧 submittedPoints → 旧链段点（段 j = [firstNear(锚j-1) .. lastNear(锚j)]）
    NSMutableDictionary *segPoints = [NSMutableDictionary dictionary];
    for (NSInteger j = 1; j < oldCount; j++) {
        CLLocationCoordinate2D aPrev = [self anchorWGSOfSegment:prevSegments[j - 1]];
        CLLocationCoordinate2D aJ = [self anchorWGSOfSegment:prevSegments[j]];
        NSUInteger s = [self firstPointIndexNearWGS:aPrev];
        NSUInteger e = [self lastPointIndexNearWGS:aJ];
        if (s == NSNotFound || e == NSNotFound || e < s) continue;
        segPoints[@(j)] = [self.submittedPoints subarrayWithRange:NSMakeRange(s, e - s + 1)];
    }
    // 移除全部生长线（重排后段索引已变，统一按新链重画；不变段用保留点序列即时画，无算路等待）
    for (id o in [self.mapView.overlays copy]) {
        if ([o isKindOfClass:[TRGrowPolyline class]]) [self.mapView removeOverlay:o];
    }
    __block NSMutableArray *joined = [NSMutableArray array];
    __block NSInteger si = 1;
    __block void (^step)(void);
    step = ^{
        if (si >= newCount) {
            [self finishLocalRegenerate:joined hint:@"行程已重排 · 重算受影响段"];
            return;
        }
        NSInteger i = si;
        if ([affected containsIndex:(NSUInteger)i]) {
            CLLocationCoordinate2D fromW = [self anchorWGSOfSegment:self.segments[i - 1]];
            CLLocationCoordinate2D toW = [self anchorWGSOfSegment:self.segments[i]];
            NSString *mode = [self departModeForSegment:i];
            NSLog(@"[locsim-grow] reorder-recalc seg %ld: (%.5f,%.5f)->(%.5f,%.5f)", (long)i, fromW.latitude, fromW.longitude, toW.latitude, toW.longitude);
            [SimRouteCalculator calculateRoutePointsFrom:fromW to:toW mode:mode completion:^(NSArray<NSDictionary *> *points, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(self) sself = self;
                    if (!sself) return;
                    if (!error && points.count >= 2) {
                        [joined addObjectsFromArray:points];
                        [sself appendGrowLine:points forSegment:i];
                    } else {
                        [sself setHint:@"已忽略无法重算的段"];
                    }
                    si++;
                    step();
                });
            }];
        } else {
            NSArray *pts = segPoints[@(i)];
            if (pts.count) {
                [joined addObjectsFromArray:pts];
                [self appendGrowLine:pts forSegment:i]; // 不变段复用旧点序列即时重画
            }
            si++;
            step();
        }
    };
    step();
}

/// 两段锚点坐标是否相同（anchor 段存 lat/lon，直接值比较；纯 anchor 链无 region）
- (BOOL)sameAnchor:(NSDictionary *)a b:(NSDictionary *)b {
    double al = [a[@"lat"] doubleValue], alo = [a[@"lon"] doubleValue];
    if ([a[@"to"] isKindOfClass:[NSDictionary class]]) {
        al = [a[@"to"][@"lat"] doubleValue];
        alo = [a[@"to"][@"lon"] doubleValue];
    }
    double bl = [b[@"lat"] doubleValue], blo = [b[@"lon"] doubleValue];
    if ([b[@"to"] isKindOfClass:[NSDictionary class]]) {
        bl = [b[@"to"][@"lat"] doubleValue];
        blo = [b[@"to"][@"lon"] doubleValue];
    }
    return al == bl && alo == blo;
}

/// 编辑路径是否含 region 段（局部重算的锚点匹配切分对 region 段不可靠 → 退化为全量重算）
- (BOOL)segmentsContainRegion {
    for (NSDictionary *seg in self.segments) {
        if ([seg[@"type"] isEqualToString:@"region"]) return YES;
    }
    return NO;
}

#pragma mark - 基于当前位置的局部重算（manager 注入写回 mobile plist 为当前位置真相）

/// 读当前位置（WGS）——权威 = 最近一次通过过滤的回调 fix（lastFix，locationd 广播真实值，不读 locationManager 属性缓存）；
/// 模拟开启=注入位置/关闭=真实位置；无 fix 时回退 self.cur
- (CLLocationCoordinate2D)currentSimPosition {
    if (self.lastFix) return self.lastFix.coordinate;
    return [CoordTransform gcj02ToWgs84:self.cur];
}

/// 停止后聚焦当前位置：读 lastFix（停止落地后首个真实 fix 到达校正）
/// 同步记录停止瞬间位置（模拟残留）为自动聚焦基线——首个真实 fix 距此超阈值才聚焦（防残留抢占）
- (void)focusRealLocationNow {
    self.lastAutoFocusWGS = [self currentSimPosition];
    [self focusMapOnCurrentLocation];
}

/// 自动聚焦（距离阈值）：fix 距上次自动聚焦点 ≥ 阈值才聚焦一次并更新基线。
/// 残留 fix（≈基线）不触发、大幅位移（停止回真实/模拟出视野）必触发、GPS 抖动（<50m）不打扰。
- (void)maybeAutoFocus:(CLLocationCoordinate2D)wgs {
    if (self.lastAutoFocusWGS.latitude == 0 && self.lastAutoFocusWGS.longitude == 0) return; // 基线未初始化
    if ([SimRouteCalculator haversineMeters:wgs to:self.lastAutoFocusWGS] < kAutoFocusThresholdM) return;
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
        self.lastFix = loc; // 记录回调 fix（坐标/速度真相源，不读属性缓存）
        self.cur = [CoordTransform wgs84ToGcj02:loc.coordinate];
        [self updateStatus];
        [self updateAnchorPassStateWithLiveWGS:loc.coordinate];
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
        // 区域随机：同步步行占比（状态栏平均速度按此加权）；其余模式归一化默认值
        self.currentWalkRatio = 0.7;
        if ([mode isEqualToString:@"random"] && departAnchor) {
            NSDictionary *seg = self.segments[departAnchor.segmentIndex];
            double wr = [seg[@"walkRatio"] doubleValue];
            if (wr > 0) self.currentWalkRatio = wr;
        }
        [self refreshUserLocationView]; // 当前位置水滴切换出行图标（原生 MKUserLocation 视图）
    }
}

/// 已提交轨迹中距目标最近的点索引（截断基准）
- (NSUInteger)nearestPointIndexTo:(CLLocationCoordinate2D)targetW {
    NSUInteger best = 0;
    double bestD = DBL_MAX;
    for (NSUInteger i = 0; i < self.submittedPoints.count; i++) {
        NSDictionary *p = self.submittedPoints[i];
        CLLocationCoordinate2D c = CLLocationCoordinate2DMake([p[@"lat"] doubleValue], [p[@"lon"] doubleValue]);
        double d = [SimRouteCalculator haversineMeters:targetW to:c];
        if (d < bestD) { bestD = d; best = i; }
    }
    return best;
}

/// 局部重算：保留当前位置前的已提交轨迹点，从 affectedIdx 锚点重生长到链尾
/// （删除中间锚点→当前位置→下一锚点重算；无下一锚点→保持当前位置）
- (void)regenerateFromIndex:(NSInteger)affectedIdx {
    if (self.isGenerating) return;
    self.isGenerating = YES;
    // 分段式渲染：只移除受影响段（affectedIdx 起）的生长线，之前的段保持不重渲染（不闪/不丢状态）
    for (id o in self.mapView.overlays) {
        if ([o isKindOfClass:[TRGrowPolyline class]] && [(TRGrowPolyline *)o segmentIndex] >= affectedIdx) {
            [self.mapView removeOverlay:o];
        }
    }
    // 续算起点（WGS）：优先用轨迹截断点（轨迹上的位置）——lastFix 停止态=真实位置可能不在轨迹上，
    // 直接作起点会让重算路线从画布外"随机位置"续到受影响锚点（编辑后路线乱连）
    CLLocationCoordinate2D curW = [self currentSimPosition];
    NSMutableArray *joined = [NSMutableArray array];
    // 保留当前位置前的已提交轨迹点（截断到最近点）
    if (self.submittedPoints.count) {
        NSUInteger cut = [self nearestPointIndexTo:curW];
        for (NSUInteger i = 0; i <= cut && i < self.submittedPoints.count; i++) {
            [joined addObject:self.submittedPoints[i]];
        }
        if (joined.count) {
            NSDictionary *lastP = joined.lastObject;
            curW = CLLocationCoordinate2DMake([lastP[@"lat"] doubleValue], [lastP[@"lon"] doubleValue]);
        }
    }
    // 重算期间 daemon 驻留续算点（防沿旧轨迹乱走 + 重载回跳）
    [self holdAtCurrentPosition:curW];
    [self setHint:@"正在重算路线…"];
    __weak typeof(self) weakSelf = self;
    [self buildPointsFromIndex:(NSUInteger)affectedIdx cur:curW joined:joined completion:^(NSArray *points) {
        __strong typeof(self) sself = weakSelf;
        if (!sself) return;
        if (affectedIdx >= (NSInteger)sself.segments.count) {
            // 无下一个锚点（affected 已到链尾）→ 保持当前位置（截断轨迹）
            sself.submittedPoints = points;
            sself.committedSegCount = sself.segments.count;
            if (points.count) [sself writeTrackFile:points];
            [sself setHint:@"已删除最后锚点 · 保持当前位置"];
        } else if (points.count < 2) {
            [sself setHint:@"路线重算失败（点不足）"];
        } else {
            sself.submittedPoints = points;
            sself.committedSegCount = sself.segments.count;
            [sself writeTrackFile:points];
            [sself setHint:[NSString stringWithFormat:@"路线已重算 · %lu 点", (unsigned long)points.count]];
        }
        sself.isGenerating = NO;
        [sself runPendingEdit]; // 生成期间挂起的编辑在此执行（最后一次生效）
    }];
}

#pragma mark - UITableViewDataSource / Delegate（步骤列表：删除 + 拖拽排序）

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.searchResultsView) return (NSInteger)self.searchResults.count;
    return MAX(1, (NSInteger)self.segments.count); // 空态占位（对齐原型 segPanel .empty）
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
        // 右：删除按钮（点击即删，无系统二次确认）
        UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
        del.tag = 202;
        [del setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
        del.tintColor = [UIColor systemRedColor];
        del.frame = CGRectMake(cell.contentView.bounds.size.width - 46, 0, 46, 44);
        del.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight;
        [del addTarget:self action:@selector(deleteStepTapped:) forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:del];
        // 标题 / 副标题（自绘，避开左右按钮）
        UILabel *tl = [[UILabel alloc] init];
        tl.tag = 203;
        tl.font = [UIFont systemFontOfSize:12];
        tl.frame = CGRectMake(42, 5, cell.contentView.bounds.size.width - 42 - 56, 18);
        tl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleRightMargin;
        [cell.contentView addSubview:tl];
        UILabel *sl = [[UILabel alloc] init];
        sl.tag = 204;
        sl.font = [UIFont systemFontOfSize:10];
        sl.textColor = [UIColor secondaryLabelColor];
        sl.frame = CGRectMake(42, 23, cell.contentView.bounds.size.width - 42 - 56, 14);
        sl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleRightMargin;
        [cell.contentView addSubview:sl];
    }
    if (indexPath.row >= (NSInteger)self.segments.count) {
        ((UILabel *)[cell.contentView viewWithTag:203]).text = @"暂无行程";
        ((UILabel *)[cell.contentView viewWithTag:204]).text = @"点击地图设定起点";
        [cell.contentView viewWithTag:201].hidden = YES;
        [cell.contentView viewWithTag:202].hidden = YES;
        cell.userInteractionEnabled = NO;
        return cell;
    }
    cell.userInteractionEnabled = YES;
    [cell.contentView viewWithTag:201].hidden = NO;
    UIButton *del = (UIButton *)[cell.contentView viewWithTag:202];
    del.hidden = NO;
    del.tag = (NSInteger)indexPath.row; // 删除目标行（点击即删）
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

/// 步骤列表删除按钮：点击即删（无二次确认）
- (void)deleteStepTapped:(UIButton *)sender {
    NSInteger row = sender.tag;
    if (row >= 0 && row < (NSInteger)self.segments.count) [self deleteSegmentAt:row];
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

/// 编排提交（增量生长原则）：从上一段结束点继续生长，不是每次都从起点重画。
/// - 纯追加（新段数 > 已提交段数）→ 只生长新段（起点=已提交轨迹最后点），旧段/旧生长线保留
/// - 删除/排序导致段数变化 → 全量重建（清生长线，从 anchor 起点重新生长）
- (void)commitItinerary {
    // 并发保护：正在生长时忽略新的提交（避免多流程竞争 overlay/文件）
    if (self.isGenerating) return;

    // 判断增量 vs 重建：纯追加且已有 ≥2 点的已提交轨迹 → 增量；否则全量重建
    BOOL appendMode = (self.segments.count > self.committedSegCount)
        && self.committedSegCount > 0
        && self.submittedPoints.count >= 2;
    if (!appendMode) {
        // 重建：清掉旧生长轨迹（对齐原型 clearRoute/growPath 重置）
        for (id o in self.mapView.overlays) {
            if ([o isKindOfClass:[TRGrowPolyline class]]) [self.mapView removeOverlay:o];
        }
        self.submittedPoints = @[];
        self.committedSegCount = 0;
    }
    self.isGenerating = YES;
    // 算路（异步）期间 daemon 驻留当前位置：防沿旧轨迹继续播放 + 算路完成后重载续播点跳变
    if (self.locating) [self holdAtCurrentPosition:[self currentSimPosition]];

    NSMutableArray *joined = [self.submittedPoints mutableCopy];
    if (!joined) joined = [NSMutableArray array];
    NSInteger startIdx = appendMode ? self.committedSegCount : 0;
    CLLocationCoordinate2D start;
    if (appendMode && joined.count) {
        // 增量：起点 = 已提交轨迹最后点（上一段结束点，WGS）
        NSDictionary *last = joined.lastObject;
        start = CLLocationCoordinate2DMake([last[@"lat"] doubleValue], [last[@"lon"] doubleValue]);
    } else {
        // 重建：起点 = 编排 anchor（首个起点）
        start = [CoordTransform gcj02ToWgs84:self.cur];
        for (NSDictionary *seg in self.segments) {
            if ([seg[@"type"] isEqualToString:@"anchor"]) {
                start = CLLocationCoordinate2DMake([seg[@"lat"] doubleValue], [seg[@"lon"] doubleValue]);
                break;
            }
        }
    }
    [self setHint:appendMode ? @"正在生长新段…" : @"正在生长轨迹…"];
    __weak typeof(self) weakSelf = self;
    [self buildPointsFromIndex:startIdx cur:start joined:joined completion:^(NSArray *points) {
        __strong typeof(self) sself = weakSelf;
        if (!sself) return;
        if (points.count < 2) {
            [sself setHint:@"轨迹生长失败（点不足）"];
        } else {
            // 更新提交状态：全部段已提交（含 anchor 段计数），完整轨迹 = 本次 points
            sself.submittedPoints = points;
            sself.committedSegCount = sself.segments.count;
            [sself writeTrackFile:points];
            [sself setHint:[NSString stringWithFormat:@"轨迹已提交 · %lu 点", (unsigned long)points.count]];
        }
        sself.isGenerating = NO;
        [sself runPendingEdit]; // 生成期间挂起的编辑在此执行（最后一次生效）
    }];
}

/// 生长可视化：每段算路点序列追加为生长轨迹线（算路点 WGS-84 → 画图转 GCJ-02，否则路线与点击点偏移数百米）
/// 分段式渲染：生长线挂所属编排段索引，增删/重算只动受影响段，不重画整条链
- (void)appendGrowLine:(NSArray *)pts forSegment:(NSInteger)segIdx {
    if (![pts isKindOfClass:[NSArray class]] || pts.count < 2) return;
    CLLocationCoordinate2D *cs = malloc(pts.count * sizeof(CLLocationCoordinate2D));
    for (NSUInteger i = 0; i < pts.count; i++) {
        NSDictionary *p = pts[i];
        cs[i] = [CoordTransform wgs84ToGcj02:CLLocationCoordinate2DMake([p[@"lat"] doubleValue], [p[@"lon"] doubleValue])];
    }
    TRGrowPolyline *line = [TRGrowPolyline polylineWithCoordinates:cs count:pts.count];
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

/// 锚点链逐段生成（递归）：首个锚点无前驱→仅作起点；后续锚点→从上一位置生长路线；
/// region 锚点→进入段（上一锚点→区域第一途经点）+ 区域内途经点链（processRegionPlan）
- (void)buildPointsFromIndex:(NSUInteger)idx
                         cur:(CLLocationCoordinate2D)cur
                      joined:(NSMutableArray *)joined
                  completion:(void (^)(NSArray *points))completion {
    if (idx >= self.segments.count) { if (completion) completion(joined); return; }
    NSDictionary *seg = self.segments[idx];
    NSString *type = seg[@"type"];
    if ([type isEqualToString:@"region"]) {
        CLLocationCoordinate2D centerW = [CoordTransform gcj02ToWgs84:CLLocationCoordinate2DMake([seg[@"center"][@"lat"] doubleValue], [seg[@"center"][@"lon"] doubleValue])];
        double radius = [seg[@"radius"] doubleValue];
        double durationMin = [seg[@"durationMin"] doubleValue];
        NSString *regionMode = seg[@"mode"] ?: @"walk";
        double walkRatio = [seg[@"walkRatio"] doubleValue] > 0 ? [seg[@"walkRatio"] doubleValue] : 0.7; // 随机模式的步行占比（默认 70%）
        int customK = (int)[seg[@"waypointCount"] integerValue]; // >0 生效，0=随机
        NSDictionary *plan = [RegionSimulator generateRegionPlanCenter:centerW radius:radius mode:regionMode durationMin:durationMin startFrom:cur customK:customK];
        // 进入区域的段 = 出发锚点以其生成时的出行方式前往区域；区域内途经点链用区域配置的模式（随机=每段随机）
        [self processRegionPlan:plan cur:cur entryMode:[self departModeForSegment:idx] mode:regionMode walkRatio:walkRatio joined:joined
                    itineraryIdx:idx + 1 completion:completion];
        return;
    }
    // 锚点段：目标坐标（anchor 用 lat/lon；旧 route 段兼容用 to）
    double toLat = [seg[@"lat"] doubleValue], toLon = [seg[@"lon"] doubleValue];
    if ([seg[@"to"] isKindOfClass:[NSDictionary class]]) {
        toLat = [seg[@"to"][@"lat"] doubleValue];
        toLon = [seg[@"to"][@"lon"] doubleValue];
    }
    CLLocationCoordinate2D toW = [CoordTransform gcj02ToWgs84:CLLocationCoordinate2DMake(toLat, toLon)];
    // 出行方式 = 出发锚点的（本段目标由上一锚点以其生成时的出行方式前往）
    NSString *mode = [self departModeForSegment:idx];
    if (idx == 0 && joined.count == 0) {
        // 首个锚点且无已提交轨迹：无前驱 → 仅作起点，不生长路线
        // （局部重算时 joined 含截断点 → 首个锚点也基于当前位置生长）
        [self buildPointsFromIndex:idx + 1 cur:toW joined:joined completion:completion];
        return;
    }
    // 后续锚点：从上一位置（上一锚点/区域终点）生长路线到本锚点
    NSLog(@"[locsim-grow] seg %lu %@: from (%.5f,%.5f) -> to (%.5f,%.5f)", (unsigned long)idx, type, cur.latitude, cur.longitude, toW.latitude, toW.longitude); // 生长顺序诊断
    [SimRouteCalculator calculateRoutePointsFrom:cur to:toW mode:mode completion:^(NSArray<NSDictionary *> *points, NSError *error) {
        // MKDirections completion 队列不保证主线程，UI 操作统一回主线程
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) sself = self;
            if (!sself) return;
            if (error || points.count < 2) {
                // 锚点间无法算路（<30m/无路网/失败）→ 忽略该中间锚点（对齐锚点链原则：
                // 不生成直线兜底），从当前位置继续到下一个锚点
                [sself setHint:@"已忽略无法算路的锚点"];
                [sself buildPointsFromIndex:idx + 1 cur:cur joined:joined completion:completion];
                return;
            }
            [joined addObjectsFromArray:points];
            // 生长：逐段画线（当前位置图标不随生长瞬移——当前位置由注入实时位置驱动）
            [sself appendGrowLine:points forSegment:(NSInteger)idx];
            CLLocationCoordinate2D end = CLLocationCoordinate2DMake([points.lastObject[@"lat"] doubleValue], [points.lastObject[@"lon"] doubleValue]);
            [sself buildPointsFromIndex:idx + 1 cur:end joined:joined completion:completion];
        });
    }];
}

/// 区域段：进入段（出发锚点模式）→ 区域内途经点链（区域配置模式，随机=每段按 walkRatio 随机）逐途经点 MKDirections 算路拼接
/// （<30m/算路失败 → 忽略该中间途经点，直接进入下一途经点）+ 停留微动（§3.4.1）
- (void)processRegionPlan:(NSDictionary *)plan
                      cur:(CLLocationCoordinate2D)cur
                entryMode:(NSString *)entryMode
                     mode:(NSString *)mode
                walkRatio:(double)walkRatio
                   joined:(NSMutableArray *)joined
             itineraryIdx:(NSUInteger)nextIdx
               completion:(void (^)(NSArray *points))completion {
    NSArray *wps = plan[@"waypoints"];
    NSArray *stay = plan[@"staySeconds"];
    NSArray *factors = plan[@"moveFactors"];
    if (!wps.count) { [self buildPointsFromIndex:nextIdx cur:cur joined:joined completion:completion]; return; }
    // 途经点标注：区域段生成/重算前清掉旧的，按 waypoints 重建（信息点，内嵌每段出行图标；复用锚点水滴渲染）
    for (TRWaypointAnnotation *w in self.waypointAnns) [self.mapView removeAnnotation:w];
    [self.waypointAnns removeAllObjects];
    for (NSUInteger i = 0; i < wps.count; i++) {
        TRWaypointAnnotation *w = [[TRWaypointAnnotation alloc] init];
        // 途经点坐标转 GCJ-02（plan 返回 WGS-84；地图显示坐标系=GCJ，与生长线 appendGrowLine 同转换，不转则图标偏离路线数百米）
        w.coordinate = [CoordTransform wgs84ToGcj02:[wps[i] MKCoordinateValue]];
        [self.waypointAnns addObject:w];
        [self.mapView addAnnotation:w];
    }
    __block NSUInteger segIdx = 0;
    __block CLLocationCoordinate2D legCur = cur;
    __block NSMutableArray *legJoined = joined;

    // 递归块必须 __block：否则块内捕获的是创建时的未初始化指针（赋值后仍是垃圾），首次递归即崩溃
    __block void (^processLeg)(void);
    processLeg = ^{
        if (segIdx >= wps.count) {
            CLLocationCoordinate2D end = CLLocationCoordinate2DMake([legJoined.lastObject[@"lat"] doubleValue], [legJoined.lastObject[@"lon"] doubleValue]);
            [self buildPointsFromIndex:nextIdx cur:end joined:legJoined completion:completion];
            return;
        }
        CLLocationCoordinate2D wp = [wps[segIdx] MKCoordinateValue];
        double staySec = [stay[segIdx] doubleValue];
        double factor = [factors[segIdx] doubleValue];
        NSString *legMode;
        if (segIdx == 0) {
            legMode = entryMode; // 进入段用出发锚点模式
        } else if ([mode isEqualToString:@"random"]) {
            legMode = ((double)arc4random_uniform(100) < walkRatio * 100) ? @"walk" : @"drive"; // 区域内段每段随机（按步行占比）
        } else {
            legMode = mode; // 固定模式（walk/drive）
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
            [RegionSimulator appendStayPointsAt:end seconds:staySec into:legJoined];
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
        [SimRouteCalculator calculateRoutePointsFrom:legCur to:wp mode:legMode completion:^(NSArray<NSDictionary *> *pts, NSError *error) {
            // MKDirections completion 队列不保证主线程，UI 操作统一回主线程
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(self) sself = self;
                if (!sself) return;
                if (error || pts.count < 2) {
                    // 算路失败 → 忽略该中间途经点，从当前位置继续进入下一途经点
                    [sself setHint:@"已忽略无法算路的途经点"];
                    segIdx++;
                    processLeg();
                    return;
                }
                NSUInteger target = MAX(1, (NSUInteger)ceil(segDist / (speed * factor)));
                target = MIN(target, 5000); // 点量上限，防内存爆
                NSArray *resampled = [sself resamplePoints:pts toCount:target];
                [legJoined addObjectsFromArray:resampled];
                // 生长：真实道路段画线（当前位置图标不随生长瞬移——由注入实时位置驱动）
                [sself appendGrowLine:resampled forSegment:(NSInteger)(nextIdx - 1)];
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

/// 原子写轨迹文件（tmp + rename，防半截 JSON）；定位状态由 FAB 开关控制——
/// 仅在定位中才切 SimLocationMode=itinerary + notify（添加/删除锚点不改变定位状态，对齐原型"不随后续增删路线改变状态"）
- (void)writeTrackFile:(NSArray *)points {
    NSDictionary *payload = @{ @"version": @1, @"points": points };
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json) return;
    NSString *tmp = [kSimTrackFilePath stringByAppendingString:@".tmp"];
    if (![json writeToFile:tmp options:NSDataWritingAtomic error:nil]) return;
    if ([[NSFileManager defaultManager] fileExistsAtPath:kSimTrackFilePath]) {
        [[NSFileManager defaultManager] removeItemAtPath:kSimTrackFilePath error:nil];
    }
    if (![[NSFileManager defaultManager] moveItemAtPath:tmp toPath:kSimTrackFilePath error:nil]) return;
    if (self.locating) {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
        [d setObject:@"itinerary" forKey:@"SimLocationMode"];
        [d synchronize];
        notify_post("com.82flex.trollvnc.prefs-changed");
    }
}

#pragma mark - MKMapViewDelegate

/// 出行方式 → 图标（与模式胶囊按钮同款）
- (NSString *)emojiForMode:(NSString *)mode {
    return [mode isEqualToString:@"drive"] ? @"🚗" : @"🚶";
}

/// 水滴图钉绘制（实心水滴：半圆顶+尖底+白边；颜色=状态分类；可内嵌出行方式图标）
- (UIImage *)waterdropImageWithColor:(UIColor *)color size:(CGFloat)sz emoji:(NSString *)emoji {
    UIGraphicsImageRenderer *ir = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(sz, sz + 6)];
    return [ir imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
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
        // 生长轨迹（对齐原型 growPath：深紫 3px 实线）
        MKPolylineRenderer *r = [[MKPolylineRenderer alloc] initWithPolyline:overlay];
        r.strokeColor = [UIColor colorWithRed:0.24 green:0.18 blue:0.79 alpha:1.0];
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
