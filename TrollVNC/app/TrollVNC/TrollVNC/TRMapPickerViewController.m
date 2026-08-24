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

@interface TRMapPickerViewController () <MKMapViewDelegate, UISearchBarDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UISegmentedControl *modeSeg;   // 步行/驾车（左下胶囊）
@property (nonatomic, strong) UIButton *locateFab;           // 右下角圆形定位开关
@property (nonatomic, strong) UILabel *statusLabel;          // 状态（顶部，可展开步骤）
@property (nonatomic, strong) UIStackView *stepStack;        // 步骤摘要列表（状态条展开）

@property (nonatomic, strong) NSMutableArray *segments;      // 编排段 @[@{type,point/to/radius/durationMin/mode}]
@property (nonatomic, assign) CLLocationCoordinate2D cur;    // 当前模拟位置（地图坐标 GCJ-02）
@property (nonatomic, assign) BOOL hasStart;
@property (nonatomic, assign) BOOL locating;                // 定位开关状态
@property (nonatomic, assign) BOOL expanded;                // 步骤列表展开态

// 区域（长按）临时状态
@property (nonatomic, assign) BOOL regionPicking;
@property (nonatomic, assign) CLLocationCoordinate2D regionCenter;
@property (nonatomic, assign) double regionRadiusM;
@property (nonatomic, strong) MKCircle *regionOverlay;
@property (nonatomic, strong) MKPointAnnotation *curPin;    // 蓝点（自绘）
@end

@implementation TRMapPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.segments = [NSMutableArray array];
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
    UISearchBar *sb = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 8, self.view.bounds.size.width - 24, 44)];
    sb.placeholder = @"搜索地点（如：北京西站）";
    sb.delegate = self;
    sb.searchBarStyle = UISearchBarStyleMinimal;
    sb.backgroundColor = [UIColor systemBackgroundColor];
    sb.layer.cornerRadius = 10;
    sb.layer.masksToBounds = YES;
    [self.view addSubview:sb];
    self.searchBar = sb;

    // 状态条（可点击展开步骤）
    UIButton *statusBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    statusBtn.frame = CGRectMake(12, 60, self.view.bounds.size.width - 24, 32);
    statusBtn.backgroundColor = [UIColor systemBackgroundColor];
    statusBtn.layer.cornerRadius = 8;
    statusBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [statusBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    [statusBtn addTarget:self action:@selector(toggleSteps:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:statusBtn];
    self.statusLabel = statusBtn.titleLabel;

    // 步骤列表（默认收起）
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectMake(12, 96, self.view.bounds.size.width - 24, 0)];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 2;
    stack.hidden = YES;
    [self.view addSubview:stack];
    self.stepStack = stack;

    // 步行/驾车胶囊（左下）
    UISegmentedControl *mode = [[UISegmentedControl alloc] initWithItems:@[@"🚶 步行", @"🚗 驾车"]];
    mode.selectedSegmentIndex = 0;
    [mode addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    mode.frame = CGRectMake(12, self.view.bounds.size.height - 140, 150, 32);
    mode.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:mode];
    self.modeSeg = mode;

    // 定位开关 FAB（右下角圆形）
    UIButton *fab = [UIButton buttonWithType:UIButtonTypeCustom];
    fab.frame = CGRectMake(self.view.bounds.size.width - 68, self.view.bounds.size.height - 140, 56, 56);
    fab.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin;
    fab.layer.cornerRadius = 28;
    fab.backgroundColor = [UIColor systemBlueColor];
    [fab setImage:[UIImage systemImageNamed:@"location.fill"] forState:UIControlStateNormal];
    [fab setTintColor:[UIColor whiteColor]];
    [fab addTarget:self action:@selector(toggleLocate:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:fab];
    self.locateFab = fab;
}

/// 启动时读回 defaults（SimLocationMode + 坐标即状态真相），同步开关/蓝点
- (void)readCurrentStatus {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    NSString *mode = [d stringForKey:@"SimLocationMode"];
    double lat = [d doubleForKey:@"SimLocationLat"];
    double lon = [d doubleForKey:@"SimLocationLon"];
    if ([mode isEqualToString:@"anchor"] || [mode isEqualToString:@"itinerary"]) {
        self.locating = YES;
        [self.locateFab setBackgroundColor:[UIColor systemBlueColor]];
        [self.locateFab setImage:[UIImage systemImageNamed:@"location.fill"] forState:UIControlStateNormal];
        if (lat != 0 || lon != 0) {
            self.cur = CLLocationCoordinate2DMake(lat, lon); // 已是 WGS-84，画回地图转 GCJ
            [self placeCurAt:[CoordTransform wgs84ToGcj02:self.cur]];
        }
    }
}

#pragma mark - 手势：单击递增编排

- (void)handleTap:(UITapGestureRecognizer *)g {
    CGPoint pt = [g locationInView:self.mapView];
    CLLocationCoordinate2D gcj = [self.mapView convertPoint:pt toCoordinateFromView:self.mapView];
    if (!self.hasStart) {
        // 首击 = 设起点（anchor 基底），自动开启定位
        self.hasStart = YES;
        self.cur = gcj;
        self.locating = YES;
        [self placeCurAt:gcj];
        [self.segments addObject:@{@"type": @"anchor", @"lat": @(gcj.latitude), @"lon": @(gcj.longitude)}];
        [self commitAnchor];
        [self updateStatus];
        [self refreshSteps];
        [self rebuildPreview];
    } else {
        // 再击 = 加路线段（上一位置为起点）
        NSString *mode = self.modeSeg.selectedSegmentIndex == 1 ? @"drive" : @"walk";
        [self.segments addObject:@{@"type": @"route", @"to": @{@"lat": @(gcj.latitude), @"lon": @(gcj.longitude)}, @"mode": mode}];
        self.cur = gcj;
        [self placeCurAt:gcj];
        [self updateStatus];
        [self refreshSteps];
        [self rebuildPreview];
        [self commitItinerary];
    }
}

#pragma mark - 手势：长按区域

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    CGPoint pt = [g locationInView:self.mapView];
    CLLocationCoordinate2D gcj = [self.mapView convertPoint:pt toCoordinateFromView:self.mapView];
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            self.regionPicking = YES;
            self.regionCenter = gcj;
            self.regionRadiusM = 300;
            [self addRegionOverlay];
            break;
        case UIGestureRecognizerStateChanged:
            if (self.regionPicking) {
                // 拖动点距中心 = 半径（米）
                CLLocationCoordinate2D gcjW = [CoordTransform gcj02ToWgs84:gcj];
                CLLocationCoordinate2D centerW = [CoordTransform gcj02ToWgs84:self.regionCenter];
                double d = [SimRouteCalculator haversineMeters:centerW to:gcjW];
                self.regionRadiusM = MAX(50, MIN(5000, d));
                [self addRegionOverlay];
            }
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            if (self.regionPicking) {
                self.regionPicking = NO;
                [self promptRegionDuration];
            }
            break;
        default:
            break;
    }
}

- (void)addRegionOverlay {
    if (self.regionOverlay) [self.mapView removeOverlay:self.regionOverlay];
    self.regionOverlay = [MKCircle circleWithCenterCoordinate:self.regionCenter radius:self.regionRadiusM];
    [self.mapView addOverlay:self.regionOverlay];
}

/// 区域参数（时长）输入 → 加入 region 段 → 提交编排
- (void)promptRegionDuration {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"区域漫游"
                                                                message:[NSString stringWithFormat:@"半径 %.0f m · 请输入活动时长（分钟）", self.regionRadiusM]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.text = @"10";
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        if (self.regionOverlay) { [self.mapView removeOverlay:self.regionOverlay]; self.regionOverlay = nil; }
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        double dur = MAX(1, [ac.textFields.firstObject.text doubleValue] ?: 10);
        NSString *mode = self.modeSeg.selectedSegmentIndex == 1 ? @"drive" : @"walk";
        [self.segments addObject:@{
            @"type": @"region",
            @"radius": @(self.regionRadiusM),
            @"durationMin": @(dur),
            @"mode": mode,
            @"center": @{@"lat": @(self.regionCenter.latitude), @"lon": @(self.regionCenter.longitude)},
        }];
        if (self.regionOverlay) { [self.mapView removeOverlay:self.regionOverlay]; self.regionOverlay = nil; }
        // 模拟位置推进到区域中心（进入区域起点）
        self.cur = self.regionCenter;
        [self placeCurAt:self.regionCenter];
        [self updateStatus];
        [self refreshSteps];
        [self rebuildPreview];
        [self commitItinerary];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 定位开关 / 停止

- (void)toggleLocate:(UIButton *)sender {
    if (self.locating) {
        // 停止定位：位置停最后坐标，恢复真实定位
        self.locating = NO;
        [self.locateFab setBackgroundColor:[UIColor systemGrayColor]];
        [self commitStop];
    } else {
        // 开启：有起点则 anchor，否则提示先设起点
        if (!self.hasStart) {
            [self setHint:@"请先点击地图设定模拟位置起点"];
            return;
        }
        self.locating = YES;
        [self.locateFab setBackgroundColor:[UIColor systemBlueColor]];
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
        if (error || !response.mapItems.count) {
            [self setHint:@"未找到地点"];
            return;
        }
        MKMapItem *item = response.mapItems.firstObject;
        CLLocationCoordinate2D wgs = item.placemark.coordinate;
        CLLocationCoordinate2D gcj = [CoordTransform wgs84ToGcj02:wgs];
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(gcj, 3000, 3000) animated:YES];
        if (!self.hasStart) {
            // 搜索位置直接作为起点
            self.hasStart = YES;
            self.cur = gcj;
            self.locating = YES;
            [self.locateFab setBackgroundColor:[UIColor systemBlueColor]];
            [self placeCurAt:gcj];
            [self.segments addObject:@{@"type": @"anchor", @"lat": @(gcj.latitude), @"lon": @(gcj.longitude)}];
            [self commitAnchor];
            [self updateStatus];
            [self refreshSteps];
            [self rebuildPreview];
        }
        [self setHint:item.name ?: @"已定位"];
    }];
}

#pragma mark - 状态 / 步骤 / 提示

- (void)setHint:(NSString *)hint {
    // 状态条短暂显示提示
    self.statusLabel.text = hint;
    self.statusLabel.textColor = [UIColor labelColor];
}

- (void)updateStatus {
    CLLocationCoordinate2D wgs = [CoordTransform gcj02ToWgs84:self.cur];
    NSString *modeTxt = self.locating ? @"模拟中 · 定位" : @"已停止 · 定位";
    self.statusLabel.text = [NSString stringWithFormat:@"%@ · %.5f, %.5f（WGS-84）", modeTxt, wgs.latitude, wgs.longitude];
    self.statusLabel.textColor = self.locating ? [UIColor systemBlueColor] : [UIColor labelColor];
}

- (void)toggleSteps:(UIButton *)sender {
    self.expanded = !self.expanded;
    self.stepStack.hidden = !self.expanded;
}

- (void)refreshSteps {
    for (UIView *v in self.stepStack.arrangedSubviews) [self.stepStack removeArrangedSubview:v];
    for (NSDictionary *seg in self.segments) {
        NSString *txt = nil;
        NSString *type = seg[@"type"];
        if ([type isEqualToString:@"anchor"]) {
            txt = @"起点（锚点基底）";
        } else if ([type isEqualToString:@"route"]) {
            CLLocationCoordinate2D w = [CoordTransform gcj02ToWgs84:CLLocationCoordinate2DMake([seg[@"to"][@"lat"] doubleValue], [seg[@"to"][@"lon"] doubleValue])];
            txt = [NSString stringWithFormat:@"路线 → (%.4f, %.4f)", w.latitude, w.longitude];
        } else if ([type isEqualToString:@"region"]) {
            txt = [NSString stringWithFormat:@"区域漫游 %.0f m · %@ 分钟", [seg[@"radius"] doubleValue], seg[@"durationMin"]];
        }
        if (!txt) continue;
        UILabel *l = [[UILabel alloc] init];
        l.font = [UIFont systemFontOfSize:12];
        l.text = txt;
        [self.stepStack addArrangedSubview:l];
    }
}

#pragma mark - 地图预览（路线直线连线 / 区域圆）

- (void)rebuildPreview {
    // 移除旧 polyline（保留区域圆由 region 状态管理）
    for (id overlay in self.mapView.overlays) {
        if ([overlay isKindOfClass:[MKPolyline class]]) [self.mapView removeOverlay:overlay];
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

/// 递增编排提交：异步逐段生成点序列 → 原子写轨迹文件 + 切 itinerary + notify
- (void)commitItinerary {
    NSMutableArray *joined = [NSMutableArray array];
    CLLocationCoordinate2D start = [CoordTransform gcj02ToWgs84:self.cur];
    // 从编排起点取（首个 anchor 段）
    for (NSDictionary *seg in self.segments) {
        if ([seg[@"type"] isEqualToString:@"anchor"]) {
            start = CLLocationCoordinate2DMake([seg[@"lat"] doubleValue], [seg[@"lon"] doubleValue]);
            break;
        }
    }
    [self setHint:@"正在生成轨迹…"];
    [self buildPointsFromIndex:0 cur:start joined:joined completion:^(NSArray *points) {
        if (points.count < 2) {
            [self setHint:@"轨迹生成失败（点不足）"];
            return;
        }
        [self writeTrackFile:points];
        [self setHint:[NSString stringWithFormat:@"轨迹已提交 · %lu 点", (unsigned long)points.count]];
    }];
}

/// 逐段生成（递归；route 段算路、region 段计划+逐对算路、anchor 段作起点基底）
- (void)buildPointsFromIndex:(NSUInteger)idx
                         cur:(CLLocationCoordinate2D)cur
                      joined:(NSMutableArray *)joined
                  completion:(void (^)(NSArray *points))completion {
    if (idx >= self.segments.count) { if (completion) completion(joined); return; }
    NSDictionary *seg = self.segments[idx];
    NSString *type = seg[@"type"];
    if ([type isEqualToString:@"anchor"]) {
        [self buildPointsFromIndex:idx + 1 cur:cur joined:joined completion:completion];
    } else if ([type isEqualToString:@"route"]) {
        CLLocationCoordinate2D toW = CLLocationCoordinate2DMake([seg[@"to"][@"lat"] doubleValue], [seg[@"to"][@"lon"] doubleValue]);
        toW = [CoordTransform gcj02ToWgs84:toW];
        NSString *mode = seg[@"mode"] ?: @"walk";
        [SimRouteCalculator calculateRoutePointsFrom:cur to:toW mode:mode completion:^(NSArray<NSDictionary *> *points, NSError *error) {
            if (error || points.count < 2) {
                [self setHint:@"路线算路失败（请检查网络）"];
                if (completion) completion(@[]);
                return;
            }
            [joined addObjectsFromArray:points];
            CLLocationCoordinate2D end = CLLocationCoordinate2DMake([points.lastObject[@"lat"] doubleValue], [points.lastObject[@"lon"] doubleValue]);
            [self buildPointsFromIndex:idx + 1 cur:end joined:joined completion:completion];
        }];
    } else if ([type isEqualToString:@"region"]) {
        CLLocationCoordinate2D centerW = [CoordTransform gcj02ToWgs84:CLLocationCoordinate2DMake([seg[@"center"][@"lat"] doubleValue], [seg[@"center"][@"lon"] doubleValue])];
        double radius = [seg[@"radius"] doubleValue];
        double durationMin = [seg[@"durationMin"] doubleValue];
        NSString *mode = seg[@"mode"] ?: @"walk";
        NSDictionary *plan = [RegionSimulator generateRegionPlanCenter:centerW radius:radius mode:mode durationMin:durationMin startFrom:cur customK:0];
        [self processRegionPlan:plan cur:cur mode:mode joined:joined
                    itineraryIdx:idx + 1 completion:completion];
    } else {
        [self buildPointsFromIndex:idx + 1 cur:cur joined:joined completion:completion];
    }
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
            [legJoined addObjectsFromArray:[RegionSimulator degradedLinePointsFrom:legCur to:wp seconds:segTime speed:speed]];
            goStay(wp);
            return;
        }
        [SimRouteCalculator calculateRoutePointsFrom:legCur to:wp mode:mode completion:^(NSArray<NSDictionary *> *pts, NSError *error) {
            if (error || pts.count < 2) {
                [legJoined addObjectsFromArray:[RegionSimulator degradedLinePointsFrom:legCur to:wp seconds:segTime speed:speed]];
                goStay(wp);
                return;
            }
            NSUInteger target = MAX(1, (NSUInteger)ceil(segDist / (speed * factor)));
            NSArray *resampled = [self resamplePoints:pts toCount:target];
            [legJoined addObjectsFromArray:resampled];
            goStay(CLLocationCoordinate2DMake([resampled.lastObject[@"lat"] doubleValue], [resampled.lastObject[@"lon"] doubleValue]));
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

/// 原子写轨迹文件（tmp + rename，防半截 JSON）+ 切 itinerary + notify
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
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    [d setObject:@"itinerary" forKey:@"SimLocationMode"];
    [d synchronize];
    notify_post("com.82flex.trollvnc.prefs-changed");
}

#pragma mark - MKMapViewDelegate

- (MKOverlayRenderer *)mapView:(MKMapView *)mapView rendererForOverlay:(id<MKOverlay>)overlay {
    if ([overlay isKindOfClass:[MKCircle class]]) {
        MKCircleRenderer *r = [[MKCircleRenderer alloc] initWithCircle:overlay];
        r.fillColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.15];
        r.strokeColor = [UIColor systemBlueColor];
        r.lineWidth = 1.5;
        return r;
    }
    if ([overlay isKindOfClass:[MKPolyline class]]) {
        MKPolylineRenderer *r = [[MKPolylineRenderer alloc] initWithPolyline:overlay];
        r.strokeColor = [UIColor systemBlueColor];
        r.lineWidth = 3.0;
        return r;
    }
    return nil;
}

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    if (annotation == self.curPin) {
        static NSString *rid = @"CurPin";
        MKAnnotationView *v = [mapView dequeueReusableAnnotationViewWithIdentifier:rid];
        if (!v) {
            v = [[MKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:rid];
            v.canShowCallout = NO;
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 16, 16)];
            dot.layer.cornerRadius = 8;
            dot.backgroundColor = [UIColor systemBlueColor];
            dot.layer.borderColor = [UIColor whiteColor].CGColor;
            dot.layer.borderWidth = 2;
            [v addSubview:dot];
        }
        v.annotation = annotation;
        return v;
    }
    return nil;
}

#pragma mark - UIGestureRecognizerDelegate

// 地图滚动时不应触发 tap/longPress
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

@end
