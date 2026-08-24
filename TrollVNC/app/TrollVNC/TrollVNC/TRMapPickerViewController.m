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

/// 生长轨迹线（对齐原型 growPath/addedPath：区域自生长逐段可视化 + 完成后常显；与预览虚线区分）
/// 分段式渲染：每个覆盖层挂所属编排段索引，增删/重算只动受影响段
@interface TRGrowPolyline : MKPolyline
@property (nonatomic, assign) NSInteger segmentIndex; // 所属编排段（用于按段移除）
@end
@implementation TRGrowPolyline
@end

@interface TRMapPickerViewController () <MKMapViewDelegate, UISearchBarDelegate, UIGestureRecognizerDelegate, UITableViewDataSource, UITableViewDelegate, CLLocationManagerDelegate>
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
@property (nonatomic, assign) CLLocationCoordinate2D cur;    // 当前模拟位置（地图坐标 GCJ-02）
@property (nonatomic, assign) BOOL hasStart;
@property (nonatomic, assign) BOOL locating;                // 定位开关状态
@property (nonatomic, copy) NSString *currentLegMode;       // 当前位置水滴的出行方式（当前段目标锚点的，walk/drive）
@property (nonatomic, assign) BOOL expanded;                // 步骤列表展开态
@property (nonatomic, assign) BOOL hasFocusedMapOnce;            // 首帧启动聚焦是否已执行（避免 tab 往返重复聚焦）
@property (nonatomic, strong) CLLocationManager *locationManager; // 真实定位授权/位置源（模拟开启时=模拟位置）
@property (nonatomic, assign) BOOL hasFocusedRealOnce;           // 真实定位首次到达是否已聚焦（避免反复跳）
@property (nonatomic, assign) BOOL isGenerating;            // 轨迹生成中（并发保护：正在生长时忽略新的 commit）
@property (nonatomic, copy) void (^pendingEditAction)(void);     // 生成中挂起的最新编辑（完成后执行，最后一次生效）
@property (nonatomic, assign) uint32_t locsimNotifyToken;          // daemon 注入事件订阅 token（状态栏/锚点状态即时刷新）
@property (nonatomic, assign) BOOL pendingFollow;              // 待启用跟随：注入落地（locationd≈目标）后再开，避免先居中真实位置再跳锚点
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
    // 初始无硬编码坐标（self.cur 默认 0,0）；初始视野/聚焦均以 locationd（真实）为准，
    // 无定位时由 focusMapOnCurrentLocation 守卫跳过，避免跳到无效坐标
    [self setupMap];
    [self setupUI];
    [self readCurrentStatus];
    // 真实定位：requestWhenInUse 需 Info.plist usage description；当前位置显示走 showsUserLocation（模拟/真实自动切换）
    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.delegate = self;
    if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusNotDetermined) {
        [self.locationManager requestWhenInUseAuthorization];
    } else if ([CLLocationManager authorizationStatus] != kCLAuthorizationStatusDenied &&
               [CLLocationManager authorizationStatus] != kCLAuthorizationStatusRestricted) {
        [self.locationManager startUpdatingLocation];
    }
    // 定位中 → 原生跟随模式（自动居中并随模拟位置移动，手动拖动自动退出）；未定位 → 不跟随
    self.mapView.userTrackingMode = self.locating ? MKUserTrackingModeFollow : MKUserTrackingModeNone;
    // 启动：地图聚焦到当前所在位置（定位中=模拟位置（跟随）；未定位=真实位置，取不到则回退默认视野）
    [self focusMapOnCurrentLocation];
    // daemon 注入事件订阅：模拟态刷新唯一驱动源（注入即刷新状态栏/锚点状态；停止态由真实 fix 经 didUpdateLocations 驱动）
    __weak typeof(self) weakSelf = self;
    notify_register_dispatch("com.82flex.trollvnc.locsim-update", &_locsimNotifyToken, dispatch_get_main_queue(), ^(int token) {
        __strong typeof(weakSelf) sself = weakSelf;
        [sself refreshLiveStatus];
    });
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
    if (self.locsimNotifyToken) notify_cancel(self.locsimNotifyToken);
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
    mv.showsUserLocation = YES; // 原生当前位置：模拟开启=模拟位置/关闭=真实位置（自定义水滴外观，viewForAnnotation 绘制）
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

    // 无 1s 轮询定时器：模拟态刷新由 locsim-update 事件驱动（daemon 每次注入必发），停止态由真实 fix 经
    // didUpdateLocations 驱动——两态各由真相源驱动，消除双触发重复刷新（曾致锚点状态扫描翻倍卡顿）
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
    table.editing = YES; // 编辑模式（左侧删除 + 拖拽把手）
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
        // 第一个锚点：无前驱 → 点击点成为当前定位；立即聚焦该点并切原生跟随
        self.hasStart = YES;
        self.cur = gcj;
        self.locating = YES;
        [self commitAnchor];
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(gcj, 3000, 3000) animated:YES]; // 立即聚焦锚点
        self.pendingFollow = YES; // 注入落地（locationd≈锚点）后再启用原生跟随，避免先居中真实位置再跳锚点
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

/// 区域覆盖范围调节阀：实时更新半径、遮罩预览与菜单标题/数值（确定后按当前值入段）
- (void)regionRadiusSliderChanged:(UISlider *)sender {
    self.regionRadiusM = MAX(50, MIN(5000, (double)sender.value));
    [self addRegionOverlay];
    UILabel *rLabel = (UILabel *)[self.regionPanel viewWithTag:604];
    rLabel.text = [NSString stringWithFormat:@"覆盖范围 %.0f m", self.regionRadiusM];
    UILabel *title = (UILabel *)[self.regionPanel viewWithTag:606];
    title.text = [NSString stringWithFormat:@"区域漫游 · 覆盖范围 %.0f m", self.regionRadiusM];
}

/// 区域配置菜单：地图底部卡片（时长/途经点/模式 + 取消/确定），对齐原型 param 参数条（非系统弹窗）
- (void)showRegionConfigPanel {
    [self.view endEditing:YES];
    if (self.regionPanel) { [self.regionPanel removeFromSuperview]; self.regionPanel = nil; }
    CGFloat margin = 12;
    CGFloat w = self.view.bounds.size.width - margin * 2;
    CGFloat ph = 280;
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(margin, self.view.bounds.size.height - ph - 12, w, ph)];
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
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, y, w - 28, 20)];
    title.text = [NSString stringWithFormat:@"区域漫游 · 覆盖范围 %.0f m", self.regionRadiusM];
    title.font = [UIFont boldSystemFontOfSize:14];
    title.tag = 606;
    [panel addSubview:title];
    y += 30;

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
    UISegmentedControl *ms = [[UISegmentedControl alloc] initWithItems:@[@"步行", @"驾车"]];
    ms.selectedSegmentIndex = self.modeSeg.selectedSegmentIndex;
    ms.frame = CGRectMake(128, y, w - 142, 30);
    ms.tag = 603;
    [panel addSubview:ms];
    y += 40;

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

/// 确定：读配置 → 加入 region 段 → 自生长提交（时长 clamp 1~120，途经点 clamp 0~15）
- (void)confirmRegionConfig {
    [self.view endEditing:YES];
    UITextField *durTf = (UITextField *)[self.regionPanel viewWithTag:601];
    UITextField *wpTf = (UITextField *)[self.regionPanel viewWithTag:602];
    UISegmentedControl *ms = (UISegmentedControl *)[self.regionPanel viewWithTag:603];
    double dur = MAX(1, MIN(120, [durTf.text doubleValue] ?: 10));
    int customK = (int)[wpTf.text integerValue];
    customK = MAX(0, MIN(15, customK));
    NSString *mode = (ms.selectedSegmentIndex == 1) ? @"drive" : @"walk";
    [self.segments addObject:@{
        @"type": @"region",
        @"radius": @(self.regionRadiusM),
        @"durationMin": @(dur),
        @"mode": mode,
        @"waypointCount": @(customK),
        @"center": @{@"lat": @(self.regionCenter.latitude), @"lon": @(self.regionCenter.longitude)},
    }];
    [self.regionPanel removeFromSuperview];
    self.regionPanel = nil;
    if (self.regionOverlay) { [self.mapView removeOverlay:self.regionOverlay]; self.regionOverlay = nil; }
    // 区域中心只是目标，不是当前位置——当前位置图标保持当前实际位置（不瞬移）
    [self updateStatus];
    [self syncSegmentsUI];
    [self runEdit:^{ [self commitItinerary]; }]; // 生成中挂起，完成后再生长，编辑不丢
}

#pragma mark - 定位开关 / 停止

/// 靶心按钮：聚焦到"当前位置目标"（两态随定位开关：定位中=模拟注入位置，停止=locationd 真实位置，非死绑定系统位置）
/// 定位中 → 切原生跟随（跟随 MKUserLocation=locationd 注入位置，之后手动拖动仍自动退出）；未定位 → 聚焦真实位置
- (void)focusCurrentPosition:(UIButton *)sender {
    if (self.locating) {
        self.pendingFollow = NO; // 已显式聚焦，清待启用跟随
        self.mapView.userTrackingMode = MKUserTrackingModeFollow;
    } else {
        [self focusMapOnCurrentLocation];
    }
}

- (void)toggleLocate:(UIButton *)sender {
    if (self.locating) {
        // 停止定位：位置停编排最后坐标（App 内保留显示），设备恢复真实定位
        self.locating = NO;
        self.pendingFollow = NO;         // 清待启用跟随
        self.pendingEditAction = nil;    // 放弃生成中挂起的编辑（停止后不再生长/复活设备）
        [self commitStop];
        self.mapView.userTrackingMode = MKUserTrackingModeNone; // 退出原生跟随
        [self refreshUserLocationView];                          // 当前位置水滴去图标（未定位=纯绿点）
        [self focusRealLocationNow];                             // 立即聚焦真实位置（daemon 已清除模拟，locationd 恢复真实）
    } else {
        // 开启：有起点则 anchor，否则提示先设起点
        if (!self.hasStart) {
            [self setHint:@"请先点击地图设定模拟位置起点"];
            return;
        }
        self.locating = YES;
        [self commitAnchor];
        [self refreshUserLocationView];       // 当前位置水滴恢复出行图标
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(self.cur, 3000, 3000) animated:YES]; // 立即聚焦当前位置
        self.pendingFollow = YES;             // 注入落地（locationd≈目标）后再启用原生跟随，避免先居中真实位置再跳
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
        // 第一个锚点（也是当前定位）：立即聚焦该点并切原生跟随
        self.hasStart = YES;
        self.cur = gcj;
        self.locating = YES;
        [self commitAnchor];
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(gcj, 3000, 3000) animated:YES];
        self.pendingFollow = YES; // 注入落地后再启用原生跟随
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
        // 速度 = locationd 权威（daemon 注入时写入），与 refreshLiveStatus 同源，避免"模式档位假速度"被实时值覆盖闪变
        double mps = self.locationManager.location.speed;
        speedTxt = mps > 0 ? [NSString stringWithFormat:@"%.1f m/s", mps] : @"0.0 m/s";
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

/// 实时刷新（daemon 注入事件 notify locsim-update 驱动；已删 1s 定时器冗余双触发）：
/// 定位中读当前位置（locationd 权威）→ 状态栏坐标/速度 + 锚点经过状态/当前位置出行图标切换；
/// 停止态 → 状态栏坐标绑定 locationd 真实位置（真实 fix 由 didUpdateLocations 驱动）
///（当前位置视觉走原生 MKUserLocation，随 daemon 注入自动移动，不在此轮询）
- (void)refreshLiveStatus {
    CLLocationCoordinate2D liveW = [self currentSimPosition]; // locationd 权威
    if (liveW.latitude == 0 && liveW.longitude == 0) return;
    if (!self.locating) {
        // 停止态（真实态）：状态栏坐标强制绑定 locationd 真实位置——定位开关关闭=取消注入，无"保留最后模拟坐标"回退；
        // 锚点红蓝/出行图标定格（updateStatus 轻量，真实 fix 由 didUpdateLocations 高频驱动）
        [self updateStatus];
        return;
    }
    // self.cur 同步为当前位置（GCJ 约定，供重锚/重算作当前位置基准）
    self.cur = [CoordTransform wgs84ToGcj02:liveW];
    // 锚点经过红蓝 + 当前位置出行图标切换（与原生点同源 locationd，避免双源偏差）
    [self updateAnchorPassStateWithLiveWGS:liveW];
    // 速度：locationd 权威（CLLocation.speed，daemon 注入时已写入 locationd）
    double spd = self.locationManager.location.speed;
    NSString *speedTxt = spd > 0 ? [NSString stringWithFormat:@"%.1f m/s", spd] : @"0.0 m/s";
    NSString *modeTxt = @"模拟中 · 定位";
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] init];
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:modeTxt attributes:@{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:13],
        NSForegroundColorAttributeName: [UIColor systemBlueColor],
    }]];
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"   %@", speedTxt] attributes:@{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: [UIColor secondaryLabelColor],
    }]];
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"   %.5f, %.5f", liveW.latitude, liveW.longitude] attributes:@{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: [UIColor secondaryLabelColor],
    }]];
    [self.statusBtn setAttributedTitle:as forState:UIControlStateNormal];
    // 待启用的跟随：locationd 已到达目标位置（注入落地）再启用，避免先居中真实位置再跳的抖动
    if (self.pendingFollow) {
        CLLocationCoordinate2D targetW = [CoordTransform gcj02ToWgs84:self.cur];
        if ([SimRouteCalculator haversineMeters:targetW to:liveW] < 100.0) {
            self.pendingFollow = NO;
            self.mapView.userTrackingMode = MKUserTrackingModeFollow;
        }
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

/// 删除第 idx 锚点（任意锚点）：基于当前位置局部重算——保留当前位置前的轨迹点，
/// 从受影响锚点开始重生长；删除最后锚点（无下一个锚点）→ 保持当前位置（轨迹截断到当前位置）
- (void)deleteSegmentAt:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.segments.count) return;
    [self.segments removeObjectAtIndex:idx];
    if (!self.segments.count) {
        // 全部锚点删除 → 停止定位并同步停止 daemon（写 mode=off，设备恢复真实定位），避免 App 停止但设备仍被模拟
        self.hasStart = NO;
        self.locating = NO;
        self.pendingEditAction = nil;    // 清挂起编辑（空链无需再生成）
        self.pendingFollow = NO;         // 清待启用跟随
        [self commitStop];
        for (id o in self.mapView.overlays) {
            if ([o isKindOfClass:[TRGrowPolyline class]]) [self.mapView removeOverlay:o];
        }
        self.mapView.userTrackingMode = MKUserTrackingModeNone; // 退出原生跟随
        [self refreshUserLocationView];                          // 当前位置水滴去出行图标（=真实位置纯绿点）
        [self focusRealLocationNow];                             // 立即聚焦真实位置（daemon 已清除模拟，locationd 恢复真实）
        [self setHint:@"已清空行程 · 停止模拟定位"];
        [self updateStatus];
        [self syncSegmentsUI];
        return;
    }
    [self updateStatus];
    [self syncSegmentsUI];
    // 基于当前位置局部重算（删除的最后锚点→affected=count→保持当前位置；生成中挂起，编辑不丢）
    NSInteger affected = MIN(idx, (NSInteger)self.segments.count);
    [self runEdit:^{ [self regenerateFromIndex:affected]; }];
    [self setHint:@"已删除锚点 · 基于当前位置重算路线"];
}

/// 拖拽排序后：基于当前位置局部重算（保留当前位置前轨迹点，从受影响位置重生长）
- (void)moveSegmentFrom:(NSInteger)from to:(NSInteger)to {
    if (from < 0 || to < 0 || from >= (NSInteger)self.segments.count || to >= (NSInteger)self.segments.count || from == to) return;
    NSDictionary *item = self.segments[from];
    [self.segments removeObjectAtIndex:from];
    [self.segments insertObject:item atIndex:to];
    [self setHint:@"行程已重排 · 基于当前位置重算"];
    [self syncSegmentsUI];
    [self runEdit:^{ [self regenerateFromIndex:0]; }]; // 生成中挂起，完成后再重算
}

#pragma mark - 基于当前位置的局部重算（manager 注入写回 mobile plist 为当前位置真相）

/// 读当前位置（WGS）——权威 = locationd（模拟开启=注入位置/关闭=真实位置，与原生点同源）；无定位时回退 self.cur
- (CLLocationCoordinate2D)currentSimPosition {
    CLLocation *loc = self.locationManager.location;
    if (loc) return loc.coordinate;
    return [CoordTransform gcj02ToWgs84:self.cur];
}

/// 停止后立即聚焦真实位置：daemon off 分支已调用 SimLocationManager stop（clearSimulatedLocations），
/// locationd 立即回归真实；此刻 App 侧 locationManager 缓存可能仍是最后模拟位置，故重置 hasFocusedRealOnce
/// 让下一个真实 fix 到达时（didUpdateLocations）校正聚焦——无兜底记录机制
- (void)focusRealLocationNow {
    self.hasFocusedRealOnce = NO;
    [self focusMapOnCurrentLocation];
}

/// 地图立即聚焦到当前位置（首锚点/启动定位/停止/回前台时调用）
/// 定位中=切原生跟随模式（自动居中并随模拟位置移动）；未定位=聚焦当前位置（locationd=真实位置，无定位回退 self.cur）
- (void)focusMapOnCurrentLocation {
    if (self.locating) {
        self.mapView.userTrackingMode = MKUserTrackingModeFollow; // 原生跟随：手动拖动自动退出，聚焦时恢复
        return;
    }
    CLLocationCoordinate2D center = [CoordTransform wgs84ToGcj02:[self currentSimPosition]];
    // 守卫：位置无效（从未设过且 locationd 未就绪）→ 不聚焦，保持当前视野
    if (center.latitude == 0 && center.longitude == 0) return;
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(center, 3000, 3000) animated:YES];
}

/// 刷新当前位置（MKUserLocation）水滴外观：绿色 + 出行方式图标（定位中显示图标，未定位纯绿点）
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

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *loc = locations.lastObject;
    if (!loc) return;
    // 定位中（模拟态）：位置由 daemon 注入驱动（locsim-update 事件→refreshLiveStatus），此处直接过滤，不干预模拟刷新
    if (self.locating) return;
    // 停止态（真实态）：真实 fix 到达 → 状态栏坐标立即绑定真实位置（两态随定位开关切换，不依赖事件/定时器）
    [self updateStatus];
    // 首次真实 fix 到达 → 聚焦真实位置一次（hasFocusedRealOnce 防反复跳；停止时已被 focusRealLocationNow 重置）
    if (self.hasFocusedRealOnce) return;
    self.hasFocusedRealOnce = YES;
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance([CoordTransform wgs84ToGcj02:loc.coordinate], 3000, 3000) animated:YES];
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
    // 当前位置（WGS）
    CLLocationCoordinate2D curW = [self currentSimPosition];
    // 重算期间 daemon 驻留当前位置（防沿旧轨迹乱走 + 重载回跳）
    [self holdAtCurrentPosition:curW];
    NSMutableArray *joined = [NSMutableArray array];
    // 保留当前位置前的已提交轨迹点（截断到最近点）
    if (self.submittedPoints.count) {
        NSUInteger cut = [self nearestPointIndexTo:curW];
        for (NSUInteger i = 0; i <= cut && i < self.submittedPoints.count; i++) {
            [joined addObject:self.submittedPoints[i]];
        }
    }
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
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
        cell.textLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
    }
    if (indexPath.row >= (NSInteger)self.segments.count) {
        cell.textLabel.text = @"暂无行程";
        cell.detailTextLabel.text = @"点击地图设定起点";
        cell.showsReorderControl = NO;
        cell.editingAccessoryType = UITableViewCellAccessoryNone;
        cell.userInteractionEnabled = NO;
        return cell;
    }
    cell.userInteractionEnabled = YES;
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
    cell.textLabel.text = [NSString stringWithFormat:@"%ld  %@", (long)(indexPath.row + 1), title];
    cell.detailTextLabel.text = sub;
    cell.showsReorderControl = YES;
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
        int customK = (int)[seg[@"waypointCount"] integerValue]; // >0 生效，0=随机
        NSDictionary *plan = [RegionSimulator generateRegionPlanCenter:centerW radius:radius mode:regionMode durationMin:durationMin startFrom:cur customK:customK];
        // 进入区域的段 = 出发锚点以其生成时的出行方式前往区域；区域内途经点链用区域配置的模式
        [self processRegionPlan:plan cur:cur entryMode:[self departModeForSegment:idx] mode:regionMode joined:joined
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

/// 区域段：进入段（出发锚点模式）→ 区域内途经点链（区域配置模式）逐途经点 MKDirections 算路拼接
/// （<30m/算路失败 → 忽略该中间途经点，直接进入下一途经点）+ 停留微动（§3.4.1）
- (void)processRegionPlan:(NSDictionary *)plan
                      cur:(CLLocationCoordinate2D)cur
                entryMode:(NSString *)entryMode
                     mode:(NSString *)mode
                   joined:(NSMutableArray *)joined
             itineraryIdx:(NSUInteger)nextIdx
               completion:(void (^)(NSArray *points))completion {
    NSArray *wps = plan[@"waypoints"];
    NSArray *stay = plan[@"staySeconds"];
    NSArray *factors = plan[@"moveFactors"];
    if (!wps.count) { [self buildPointsFromIndex:nextIdx cur:cur joined:joined completion:completion]; return; }
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
        NSString *legMode = (segIdx == 0) ? entryMode : mode; // 进入段用出发锚点模式，区域内用区域配置模式
        double speed = [RegionSimulator effectiveSpeedForMode:legMode];
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

- (void)mapView:(MKMapView *)mapView regionWillChangeAnimated:(BOOL)animated {
    // 用户手动拖动/缩放 → 取消待启用的跟随（程序化 setRegion 带 animated=YES，不误判）
    if (!animated) self.pendingFollow = NO;
}

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
    if ([annotation isKindOfClass:[MKUserLocation class]]) {
        // 当前位置（原生管线）：模拟开启=模拟位置/关闭=真实位置；绿色水滴+出行方式图标外观
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
