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
#import <notify.h>
#import "CoordTransform.h"
#import "RegionSimulator.h"
#import "SimRouteCalculator.h"

/// 轨迹文件路径（与 SimLocationController kSimTrackFilePath 一致，App 只当配置源、manager 注入执行）
static NSString *const kSimTrackFilePath = @"/var/mobile/Library/Caches/com.82flex.trollvnc.simloc.json";
static NSString *const kPrefsSuite = @"com.82flex.trollvnc";

/// 锚点标注（关联编排段索引，点击删除该段；水滴图钉：start=紫/route=蓝/region=绿，对齐原型 segMark）
@interface TRAnchorAnnotation : MKPointAnnotation
@property (nonatomic, assign) NSInteger segmentIndex;
@property (nonatomic, copy) NSString *type; // anchor | route | region
@end
@implementation TRAnchorAnnotation
@end

/// 生长轨迹线（对齐原型 growPath/addedPath：区域自生长逐段可视化 + 完成后常显；与预览虚线区分）
@interface TRGrowPolyline : MKPolyline
@end
@implementation TRGrowPolyline
@end

@interface TRMapPickerViewController () <MKMapViewDelegate, UISearchBarDelegate, UIGestureRecognizerDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *searchResultsView;       // 搜索下拉结果列表（搜索框内向下展开）
@property (nonatomic, strong) NSArray *searchResults;               // MKMapItem 数组
@property (nonatomic, strong) UISegmentedControl *modeSeg;   // 步行/驾车（左下胶囊）
@property (nonatomic, strong) UIButton *locateFab;           // 右下角圆形定位开关
@property (nonatomic, strong) UIButton *statusBtn;                   // 状态条（用 setTitle 渲染，titleLabel.text 直接赋值无效）
@property (nonatomic, strong) UIView *statusDot;                     // 状态圆点（定位中绿/停止灰）
@property (nonatomic, strong) UITableView *stepTable;        // 步骤列表（状态条展开；删除 + 拖拽排序）

@property (nonatomic, strong) NSMutableArray *segments;      // 编排段 @[@{type,point/to/radius/durationMin/mode}]
@property (nonatomic, strong) NSMutableArray *anchors;       // 每段对应的锚点标注（TRAnchorAnnotation）
@property (nonatomic, assign) CLLocationCoordinate2D cur;    // 当前模拟位置（地图坐标 GCJ-02）
@property (nonatomic, assign) BOOL hasStart;
@property (nonatomic, assign) BOOL locating;                // 定位开关状态
@property (nonatomic, assign) BOOL expanded;                // 步骤列表展开态
@property (nonatomic, assign) BOOL isGenerating;            // 轨迹生成中（并发保护：正在生长时忽略新的 commit）
@property (nonatomic, assign) NSInteger committedSegCount;          // 已提交到轨迹的段数（增量生长：只生长新段）
@property (nonatomic, strong) NSArray *submittedPoints;             // 已提交的完整轨迹点序列（上一段结束点=新段起点）

// 区域（长按）临时状态
@property (nonatomic, assign) BOOL regionPicking;
@property (nonatomic, assign) CLLocationCoordinate2D regionCenter;
@property (nonatomic, assign) double regionRadiusM;
@property (nonatomic, assign) CGPoint regionTouchOffset; // 手势起点-中心（像素偏移，拖移用）
@property (nonatomic, strong) UIView *regionPanel;               // 区域配置菜单（底部卡片，对齐原型 param）
@property (nonatomic, strong) MKCircle *regionOverlay;
@property (nonatomic, strong) MKPointAnnotation *curPin;    // 蓝点（自绘）
@end

@implementation TRMapPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.segments = [NSMutableArray array];
    self.anchors = [NSMutableArray array];
    self.cur = CLLocationCoordinate2DMake(39.9042, 116.4074); // 北京，初始
    [self setupMap];
    [self setupUI];
    [self readCurrentStatus];
}

#pragma mark - UI 构建

- (void)setupMap {
    MKMapView *mv = [[MKMapView alloc] initWithFrame:self.view.bounds];
    mv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    mv.delegate = self;
    mv.showsUserLocation = NO; // 自绘蓝点
    mv.showsCompass = YES;
    [self.view addSubview:mv];
    self.mapView = mv;
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(self.cur, 5000, 5000) animated:NO];

    // 手势：单击 = 递增编排；长按 500ms = 区域中心
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tap.delegate = self;
    [self.mapView addGestureRecognizer:tap];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    lp.minimumPressDuration = 0.5;
    lp.delegate = self;
    [self.mapView addGestureRecognizer:lp];
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
    ]];
}

/// 启动时读回 defaults（SimLocationMode + 坐标即状态真相），同步开关/蓝点
- (void)readCurrentStatus {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    NSString *mode = [d stringForKey:@"SimLocationMode"];
    double lat = [d doubleForKey:@"SimLocationLat"];
    double lon = [d doubleForKey:@"SimLocationLon"];
    if ([mode isEqualToString:@"anchor"] || [mode isEqualToString:@"itinerary"]) {
        self.locating = YES;
        if (lat != 0 || lon != 0) {
            self.cur = CLLocationCoordinate2DMake(lat, lon); // 已是 WGS-84，画回地图转 GCJ
            [self placeCurAt:[CoordTransform wgs84ToGcj02:self.cur]];
        }
    }
    [self updateStatus];
}

#pragma mark - 手势：单击递增编排

/// 单击地图 = 添加锚点（无起点差别：所有位置都是锚点）
/// 第一个锚点无前驱（前方没有任何锚点）→ 仅当前定位（anchor 注入）；
/// 后续锚点前方都有上一个锚点 → 从上一锚点生长路线到本锚点（增量生长）
- (void)handleTap:(UITapGestureRecognizer *)g {
    CGPoint pt = [g locationInView:self.mapView];
    CLLocationCoordinate2D gcj = [self.mapView convertPoint:pt toCoordinateFromView:self.mapView];
    [self.segments addObject:@{@"type": @"anchor", @"lat": @(gcj.latitude), @"lon": @(gcj.longitude)}];
    self.cur = gcj;
    [self placeCurAt:gcj];
    if (self.segments.count == 1) {
        // 第一个锚点：无前驱 → 直接作为当前定位
        self.hasStart = YES;
        self.locating = YES;
        [self commitAnchor];
        [self setHint:@"已设定位点 · 继续点击添加锚点生长路线"];
    } else {
        // 后续锚点：从上一锚点生长路线（增量，上一段结束点=新段起点）
        [self commitItinerary];
        [self setHint:@"已添加锚点 · 路线从上一位置生长"];
    }
    [self updateStatus];
    [self syncSegmentsUI];
}

#pragma mark - 手势：长按区域

/// 长按区域：出现遮罩（紫虚线圆）→ 圆内拖动移动中心 / 圆边拖动调半径 → 松开弹配置菜单（对齐原型 ring+ringHandle+param）
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
            [self setHint:@"拖动圆内移动区域 · 拖动圆边调节半径"];
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
                // 圆边/外拖动 → 调节半径（手势点到中心距离）
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

/// 区域配置菜单：地图底部卡片（时长/途经点/模式 + 取消/确定），对齐原型 param 参数条（非系统弹窗）
- (void)showRegionConfigPanel {
    [self.view endEditing:YES];
    if (self.regionPanel) { [self.regionPanel removeFromSuperview]; self.regionPanel = nil; }
    CGFloat margin = 12;
    CGFloat w = self.view.bounds.size.width - margin * 2;
    CGFloat ph = 250;
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
    title.text = [NSString stringWithFormat:@"区域漫游 · 半径 %.0f m（拖动遮罩可调）", self.regionRadiusM];
    title.font = [UIFont boldSystemFontOfSize:14];
    [panel addSubview:title];
    y += 30;

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
    [panel addSubview:tf];
    return y + 36;
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
    // 模拟位置推进到区域中心（进入区域起点）
    self.cur = self.regionCenter;
    [self placeCurAt:self.regionCenter];
    [self updateStatus];
    [self syncSegmentsUI];
    [self commitItinerary];
}

#pragma mark - 定位开关 / 停止

- (void)toggleLocate:(UIButton *)sender {
    if (self.locating) {
        // 停止定位：位置停编排最后坐标（App 内保留显示），设备恢复真实定位
        self.locating = NO;
        [self commitStop];
    } else {
        // 开启：有起点则 anchor，否则提示先设起点
        if (!self.hasStart) {
            [self setHint:@"请先点击地图设定模拟位置起点"];
            return;
        }
        self.locating = YES;
        [self commitAnchor];
    }
    [self updateStatus];
}

#pragma mark - 模式切换 / 搜索

- (void)modeChanged:(UISegmentedControl *)sender {
    // 模式影响后续 route/region 段的算路档；已在段提交时读取
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
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(gcj, 3000, 3000) animated:YES];
    [self.segments addObject:@{@"type": @"anchor", @"lat": @(gcj.latitude), @"lon": @(gcj.longitude)}];
    self.cur = gcj;
    self.hasStart = YES;
    [self placeCurAt:gcj];
    if (self.segments.count == 1) {
        self.locating = YES;
        [self commitAnchor];          // 第一个锚点：直接当前定位
    } else {
        [self commitItinerary];       // 后续锚点：从上一锚点生长
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
    CLLocationCoordinate2D wgs = [CoordTransform gcj02ToWgs84:self.cur];
    NSString *speedTxt = @"0.0 m/s";
    NSString *modeTxt = self.locating ? @"模拟中 · 定位" : @"已停止 · 定位";
    if (self.locating) {
        // 速度按模式档位显示（真实注入速度为 manager 每秒推进，App 侧展示档位）
        double mps = self.modeSeg.selectedSegmentIndex == 1 ? 13.9 : 1.4;
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
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"   %.5f, %.5f", wgs.latitude, wgs.longitude] attributes:@{
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

/// 编排段变化后统一刷新：步骤列表 + 锚点 + 预览（对齐原型 addSegment → renderRail+renderOverlaysFromSegments）
- (void)syncSegmentsUI {
    [self.stepTable reloadData];
    [self rebuildAnchors];
    [self rebuildPreview];
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
        [self.anchors addObject:a];
        [self.mapView addAnnotation:a];
    }
}

/// 删除第 idx 锚点（任意锚点）：基于当前位置局部重算——保留当前位置前的轨迹点，
/// 从受影响锚点开始重生长；删除最后锚点（无下一个锚点）→ 保持当前位置（轨迹截断到当前位置）
- (void)deleteSegmentAt:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.segments.count) return;
    [self.segments removeObjectAtIndex:idx];
    // 模拟位置回退到最后一个剩余锚点
    if (self.segments.count) {
        NSDictionary *last = self.segments.lastObject;
        if ([last[@"type"] isEqualToString:@"region"]) {
            self.cur = CLLocationCoordinate2DMake([last[@"center"][@"lat"] doubleValue], [last[@"center"][@"lon"] doubleValue]);
        } else {
            self.cur = CLLocationCoordinate2DMake([last[@"lat"] doubleValue], [last[@"lon"] doubleValue]);
        }
        [self placeCurAt:self.cur];
    } else {
        self.hasStart = NO;
        self.locating = NO;
    }
    [self updateStatus];
    [self syncSegmentsUI];
    // 基于当前位置局部重算（删除的最后锚点→affected=count→保持当前位置）
    NSInteger affected = MIN(idx, (NSInteger)self.segments.count);
    [self regenerateFromIndex:affected];
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
    [self regenerateFromIndex:0];
}

#pragma mark - 基于当前位置的局部重算（manager 注入写回 mobile plist 为当前位置真相）

/// 读当前位置（WGS；manager 注入写回 mobile plist；无写回回退最近锚点）
- (CLLocationCoordinate2D)currentSimPosition {
    NSDictionary *mobile = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.82flex.trollvnc.plist"];
    double lat = [mobile[@"SimLocationLat"] doubleValue];
    double lon = [mobile[@"SimLocationLon"] doubleValue];
    if (lat != 0 || lon != 0) return CLLocationCoordinate2DMake(lat, lon);
    return [CoordTransform gcj02ToWgs84:self.cur];
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
    // 清掉生长线（重画受影响之后的轨迹）
    for (id o in self.mapView.overlays) {
        if ([o isKindOfClass:[TRGrowPolyline class]]) [self.mapView removeOverlay:o];
    }
    // 当前位置（WGS）
    CLLocationCoordinate2D curW = [self currentSimPosition];
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
        sself.isGenerating = NO;
        // 无下一个锚点（affected 已到链尾）→ 保持当前位置（截断轨迹）
        if (affectedIdx >= (NSInteger)sself.segments.count) {
            sself.submittedPoints = points;
            sself.committedSegCount = sself.segments.count;
            if (points.count) [sself writeTrackFile:points];
            [sself setHint:@"已删除最后锚点 · 保持当前位置"];
            return;
        }
        if (points.count < 2) {
            [sself setHint:@"路线重算失败（点不足）"];
            return;
        }
        sself.submittedPoints = points;
        sself.committedSegCount = sself.segments.count;
        [sself writeTrackFile:points];
        [sself setHint:[NSString stringWithFormat:@"路线已重算 · %lu 点", (unsigned long)points.count]];
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

#pragma mark - 地图预览（路线直线连线 / 区域圆）

- (void)rebuildPreview {
    // 移除旧预览 polyline（跳过生长轨迹 TRGrowPolyline——生长线常显，对齐原型 addedPath）
    for (id overlay in self.mapView.overlays) {
        if ([overlay isKindOfClass:[MKPolyline class]] && ![overlay isKindOfClass:[TRGrowPolyline class]]) {
            [self.mapView removeOverlay:overlay];
        }
    }
    // 预览连线：依次连接各段锚点（起点 + route to + region center）
    NSMutableArray *coords = [NSMutableArray array];
    for (NSDictionary *seg in self.segments) {
        NSString *type = seg[@"type"];
        if ([type isEqualToString:@"anchor"]) {
            [coords addObject:[NSValue valueWithMKCoordinate:CLLocationCoordinate2DMake([seg[@"lat"] doubleValue], [seg[@"lon"] doubleValue])]];
        } else if ([type isEqualToString:@"route"]) {
            [coords addObject:[NSValue valueWithMKCoordinate:CLLocationCoordinate2DMake([seg[@"to"][@"lat"] doubleValue], [seg[@"to"][@"lon"] doubleValue])]];
        } else if ([type isEqualToString:@"region"]) {
            [coords addObject:[NSValue valueWithMKCoordinate:CLLocationCoordinate2DMake([seg[@"center"][@"lat"] doubleValue], [seg[@"center"][@"lon"] doubleValue])]];
        }
    }
    if (coords.count >= 2) {
        CLLocationCoordinate2D *cs = malloc(coords.count * sizeof(CLLocationCoordinate2D));
        for (NSUInteger i = 0; i < coords.count; i++) cs[i] = [coords[i] MKCoordinateValue];
        MKPolyline *line = [MKPolyline polylineWithCoordinates:cs count:coords.count];
        free(cs);
        [self.mapView addOverlay:line];
    }
}

- (void)placeCurAt:(CLLocationCoordinate2D)gcj {
    if (self.curPin) [self.mapView removeAnnotation:self.curPin];
    self.curPin = [[MKPointAnnotation alloc] init];
    self.curPin.coordinate = gcj;
    [self.mapView addAnnotation:self.curPin];
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
        sself.isGenerating = NO;
        if (points.count < 2) {
            [sself setHint:@"轨迹生长失败（点不足）"];
            return;
        }
        // 更新提交状态：全部段已提交（含 anchor 段计数），完整轨迹 = 本次 points
        sself.submittedPoints = points;
        sself.committedSegCount = sself.segments.count;
        [sself writeTrackFile:points];
        [sself setHint:[NSString stringWithFormat:@"轨迹已提交 · %lu 点", (unsigned long)points.count]];
    }];
}

/// 生长可视化：每段算路点序列追加为生长轨迹线（对齐原型 growRegionRoute 逐段 moveTo 生长）
- (void)appendGrowLine:(NSArray *)pts {
    if (![pts isKindOfClass:[NSArray class]] || pts.count < 2) return;
    CLLocationCoordinate2D *cs = malloc(pts.count * sizeof(CLLocationCoordinate2D));
    for (NSUInteger i = 0; i < pts.count; i++) {
        NSDictionary *p = pts[i];
        cs[i] = CLLocationCoordinate2DMake([p[@"lat"] doubleValue], [p[@"lon"] doubleValue]);
    }
    TRGrowPolyline *line = [TRGrowPolyline polylineWithCoordinates:cs count:pts.count];
    free(cs);
    [self.mapView addOverlay:line];
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
        NSString *mode = seg[@"mode"] ?: @"walk";
        int customK = (int)[seg[@"waypointCount"] integerValue]; // >0 生效，0=随机
        NSDictionary *plan = [RegionSimulator generateRegionPlanCenter:centerW radius:radius mode:mode durationMin:durationMin startFrom:cur customK:customK];
        [self processRegionPlan:plan cur:cur mode:mode joined:joined
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
    NSString *mode = [seg[@"mode"] isKindOfClass:[NSString class]] ? seg[@"mode"] : (self.modeSeg.selectedSegmentIndex == 1 ? @"drive" : @"walk");
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
                [sself setHint:@"路线算路失败（请检查网络）"];
                if (completion) completion(@[]);
                return;
            }
            [joined addObjectsFromArray:points];
            // 生长：逐段画线 + 蓝点推进（对齐原型 moveTo 逐段生长）
            [sself appendGrowLine:points];
            CLLocationCoordinate2D end = CLLocationCoordinate2DMake([points.lastObject[@"lat"] doubleValue], [points.lastObject[@"lon"] doubleValue]);
            [sself placeCurAt:[CoordTransform wgs84ToGcj02:end]];
            [sself buildPointsFromIndex:idx + 1 cur:end joined:joined completion:completion];
        });
    }];
}

/// 区域段：逐途经点 MKDirections 算路拼接（<30m/失败降级直线）+ 停留微动（§3.4.1）
- (void)processRegionPlan:(NSDictionary *)plan
                      cur:(CLLocationCoordinate2D)cur
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

    void (^processLeg)(void) = ^{
        if (segIdx >= wps.count) {
            CLLocationCoordinate2D end = CLLocationCoordinate2DMake([legJoined.lastObject[@"lat"] doubleValue], [legJoined.lastObject[@"lon"] doubleValue]);
            [self buildPointsFromIndex:nextIdx cur:end joined:legJoined completion:completion];
            return;
        }
        CLLocationCoordinate2D wp = [wps[segIdx] MKCoordinateValue];
        double staySec = [stay[segIdx] doubleValue];
        double factor = [factors[segIdx] doubleValue];
        double speed = [RegionSimulator effectiveSpeedForMode:mode];
        double segDist = [SimRouteCalculator haversineMeters:legCur to:wp];
        double segTime = segDist / (speed * factor);

        void (^goStay)(CLLocationCoordinate2D) = ^(CLLocationCoordinate2D end) {
            [RegionSimulator appendStayPointsAt:end seconds:staySec into:legJoined];
            legCur = end;
            segIdx++;
            processLeg();
        };
        if (segDist < 30.0) {
            NSArray *degraded = [RegionSimulator degradedLinePointsFrom:legCur to:wp seconds:segTime speed:speed];
            [legJoined addObjectsFromArray:degraded];
            // 生长：降级直线段也画线 + 蓝点推进
            [self appendGrowLine:degraded];
            [self placeCurAt:[CoordTransform wgs84ToGcj02:wp]];
            goStay(wp);
            return;
        }
        [SimRouteCalculator calculateRoutePointsFrom:legCur to:wp mode:mode completion:^(NSArray<NSDictionary *> *pts, NSError *error) {
            // MKDirections completion 队列不保证主线程，UI 操作统一回主线程
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(self) sself = self;
                if (!sself) return;
                if (error || pts.count < 2) {
                    NSArray *degraded = [RegionSimulator degradedLinePointsFrom:legCur to:wp seconds:segTime speed:speed];
                    [legJoined addObjectsFromArray:degraded];
                    [sself appendGrowLine:degraded];
                    [sself placeCurAt:[CoordTransform wgs84ToGcj02:wp]];
                    goStay(wp);
                    return;
                }
                NSUInteger target = MAX(1, (NSUInteger)ceil(segDist / (speed * factor)));
                target = MIN(target, 5000); // 点量上限，防内存爆
                NSArray *resampled = [sself resamplePoints:pts toCount:target];
                [legJoined addObjectsFromArray:resampled];
                // 生长：真实道路段画线 + 蓝点推进（对齐原型 moveTo+stayAt 途经点间生长）
                [sself appendGrowLine:resampled];
                CLLocationCoordinate2D legEnd = CLLocationCoordinate2DMake([resampled.lastObject[@"lat"] doubleValue], [resampled.lastObject[@"lon"] doubleValue]);
                [sself placeCurAt:[CoordTransform wgs84ToGcj02:legEnd]];
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
    if ([overlay isKindOfClass:[MKPolyline class]]) {
        // 预览连线（对齐原型 routePath：蓝虚线 1.5px）
        MKPolylineRenderer *r = [[MKPolylineRenderer alloc] initWithPolyline:overlay];
        r.strokeColor = [UIColor colorWithRed:0.13 green:0.65 blue:0.97 alpha:1.0];
        r.lineWidth = 1.5;
        r.lineDashPattern = @[@5, @4];
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
            v.canShowCallout = YES;
            UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
            [del setImage:[UIImage systemImageNamed:@"trash"] forState:UIControlStateNormal];
            del.frame = CGRectMake(0, 0, 30, 30);
            v.rightCalloutAccessoryView = del;
        }
        v.annotation = annotation;
        // 实心水滴图钉（UIGraphicsImageRenderer 自绘：半圆顶+尖底+白边；锚点=蓝/区域=绿）
        UIColor *color = [UIColor colorWithRed:0.13 green:0.65 blue:0.97 alpha:1.0];
        if ([a.type isEqualToString:@"region"]) color = [UIColor colorWithRed:0.11 green:0.79 blue:0.51 alpha:1.0];
        CGFloat sz = 22;
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
        }];
        v.image = img;
        v.centerOffset = CGPointMake(0, -(sz + 6) / 2); // 尖对齐坐标点
        v.frame = CGRectMake(0, 0, sz, sz + 6);
        v.calloutOffset = CGPointMake(0, -6);
        return v;
    }
    if (annotation == self.curPin) {
        static NSString *rid = @"CurPin";
        MKAnnotationView *v = [mapView dequeueReusableAnnotationViewWithIdentifier:rid];
        if (!v) {
            v = [[MKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:rid];
            v.canShowCallout = NO;
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 14)];
            dot.layer.cornerRadius = 7;
            dot.backgroundColor = [UIColor colorWithRed:0.13 green:0.65 blue:0.97 alpha:1.0];
            dot.layer.borderColor = [UIColor whiteColor].CGColor;
            dot.layer.borderWidth = 2;
            // 外圈 glow（对齐原型 .dot box-shadow 0 0 0 5px rgba(34,165,247,.28)）
            dot.layer.shadowColor = dot.backgroundColor.CGColor;
            dot.layer.shadowOpacity = 0.6;
            dot.layer.shadowRadius = 6;
            dot.layer.shadowOffset = CGSizeMake(0, 0);
            [v addSubview:dot];
        }
        v.annotation = annotation;
        return v;
    }
    return nil;
}

/// 锚点 callout 删除按钮：删除该段（对齐原型「点击锚点删除该点，路线自适应连接」）
- (void)mapView:(MKMapView *)mapView annotationView:(MKAnnotationView *)view calloutAccessoryControlTapped:(UIControl *)control {
    if ([view.annotation isKindOfClass:[TRAnchorAnnotation class]]) {
        TRAnchorAnnotation *a = (TRAnchorAnnotation *)view.annotation;
        [self deleteSegmentAt:a.segmentIndex];
    }
}

#pragma mark - UIGestureRecognizerDelegate

// 地图滚动时不应触发 tap/longPress
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

@end
