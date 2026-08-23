/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "SimItineraryPlanner.h"

#import "SimLocationController.h"
#import "SimRouteCalculator.h"
#import "RegionSimulator.h"
#import "Logging.h"

@implementation SimItineraryPlanner

#pragma mark - 公共入口

+ (void)submitItinerary:(NSArray<NSDictionary *> *)segments
             completion:(void (^)(NSDictionary *result, NSError *error))completion {
    if (![segments isKindOfClass:[NSArray class]] || segments.count == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"SimItin" code:1 userInfo:@{NSLocalizedDescriptionKey:@"segments 不能为空"}]);
        return;
    }
    // 段起点静态绑定：seg1 起点 = 提交时刻当前位置（之后不实时读坐标）
    NSDictionary *st = [SimLocationController currentStatus];
    CLLocationCoordinate2D cur = CLLocationCoordinate2DMake([st[@"lat"] doubleValue], [st[@"lon"] doubleValue]);
    if (!st[@"lat"] && ![segments[0][@"type"] isEqualToString:@"anchor"]) {
        // 从未注入过位置：无 _current 起点，且首段不是 anchor 落点 → 无从绑定起点
        if (completion) completion(nil, [NSError errorWithDomain:@"SimItin" code:2 userInfo:@{NSLocalizedDescriptionKey:@"无当前位置（请先设置 anchor 基底）"}]);
        return;
    }
    NSMutableArray *joined = [NSMutableArray array];
    [SimItineraryPlanner _processSegmentAtIndex:0 segments:segments cur:cur joined:joined completion:completion];
}

#pragma mark - 逐段串行生成（递归；route 段异步、region 段同步、anchor 段不生成）

+ (void)_processSegmentAtIndex:(NSUInteger)idx
                      segments:(NSArray<NSDictionary *> *)segments
                           cur:(CLLocationCoordinate2D)cur
                        joined:(NSMutableArray *)joined
                    completion:(void (^)(NSDictionary *result, NSError *error))completion {
    if (idx >= segments.count) {
        // 全部拼接完成 → 原子落盘 + 切 itinerary，Controller 自治推进
        NSError *uerr = nil;
        if (![SimLocationController uploadTrackPoints:joined error:&uerr]) {
            if (completion) completion(nil, uerr);
            return;
        }
        [[SimLocationController sharedController] reloadFromPrefs];
        TVLog(@"[locsim] itinerary submitted: %lu points, %lu segments", (unsigned long)joined.count, (unsigned long)segments.count);
        if (completion) completion(@{@"ok":@YES, @"count":@(joined.count)}, nil);
        return;
    }
    NSDictionary *seg = segments[idx];
    NSString *type = [seg[@"type"] isKindOfClass:[NSString class]] ? seg[@"type"] : @"";
    if ([type isEqualToString:@"route"]) {
        NSDictionary *to = seg[@"to"];
        if (![to isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, [NSError errorWithDomain:@"SimItin" code:3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"第 %lu 段 route: to 缺失", (unsigned long)idx + 1]}]);
            return;
        }
        double toLat = [to[@"lat"] doubleValue], toLon = [to[@"lon"] doubleValue];
        if (toLat < -90.0 || toLat > 90.0 || toLon < -180.0 || toLon > 180.0) {
            if (completion) completion(nil, [NSError errorWithDomain:@"SimItin" code:3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"第 %lu 段 route: to 坐标非法", (unsigned long)idx + 1]}]);
            return;
        }
        NSString *mode = [seg[@"mode"] isKindOfClass:[NSString class]] ? seg[@"mode"] : @"walk";
        CLLocationCoordinate2D toC = CLLocationCoordinate2DMake(toLat, toLon);
        [SimRouteCalculator calculateRoutePointsFrom:cur to:toC mode:mode completion:^(NSArray<NSDictionary *> *points, NSError *error) {
            if (error || points.count == 0) {
                if (completion) completion(nil, error ?: [NSError errorWithDomain:@"SimItin" code:4 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"第 %lu 段 route 算路失败", (unsigned long)idx + 1]}]);
                return;
            }
            CLLocationCoordinate2D end = [SimItineraryPlanner _lastPoint:points];
            [joined addObjectsFromArray:points];
            [SimItineraryPlanner _processSegmentAtIndex:idx + 1 segments:segments cur:end joined:joined completion:completion];
        }];
    } else if ([type isEqualToString:@"region"]) {
        double radius = [seg[@"radius"] doubleValue];
        double durationMin = [seg[@"durationMin"] doubleValue];
        if (!(radius > 0) || !(durationMin > 0)) {
            if (completion) completion(nil, [NSError errorWithDomain:@"SimItin" code:5 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"第 %lu 段 region: radius/durationMin 必须为正数", (unsigned long)idx + 1]}]);
            return;
        }
        NSDictionary *center = seg[@"center"];
        CLLocationCoordinate2D c = cur;
        if ([center isKindOfClass:[NSDictionary class]]) {
            double cLat = [center[@"lat"] doubleValue], cLon = [center[@"lon"] doubleValue];
            if (cLat >= -90.0 && cLat <= 90.0 && cLon >= -180.0 && cLon <= 180.0) c = CLLocationCoordinate2DMake(cLat, cLon);
        }
        NSString *mode = [seg[@"mode"] isKindOfClass:[NSString class]] ? seg[@"mode"] : @"walk";
        // 自定义途经点数（>0 生效，0=随机亚线性饱和，§3.4.1）
        int customK = (int)[seg[@"waypointCount"] integerValue];
        // 计划（途经点 + 停留/速度因子时间分配）；移动段逐对 MKDirections 真实道路算路拼接（生长式）
        NSDictionary *plan = [RegionSimulator generateRegionPlanCenter:c radius:radius mode:mode durationMin:durationMin startFrom:cur customK:customK];
        [SimItineraryPlanner _processRegionPlan:plan cur:cur mode:mode joined:joined segIdx:0 itineraryIdx:idx segments:segments completion:completion];
    } else if ([type isEqualToString:@"anchor"]) {
        // 终点基底：不生成序列、不参与拼接；显式 point 则作为后续段起点
        NSDictionary *point = seg[@"point"];
        if ([point isKindOfClass:[NSDictionary class]]) {
            double pLat = [point[@"lat"] doubleValue], pLon = [point[@"lon"] doubleValue];
            if (pLat >= -90.0 && pLat <= 90.0 && pLon >= -180.0 && pLon <= 180.0) {
                cur = CLLocationCoordinate2DMake(pLat, pLon);
            }
        }
        [SimItineraryPlanner _processSegmentAtIndex:idx + 1 segments:segments cur:cur joined:joined completion:completion];
    } else {
        if (completion) completion(nil, [NSError errorWithDomain:@"SimItin" code:6 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"第 %lu 段 type=%@ 非法（route/region/anchor）", (unsigned long)idx + 1, type]}]);
    }
}

#pragma mark - 区域段：逐段真实道路算路拼接（生长式，§3.4.1）

// 区域漫游 = 进入段（cur → 途经点①）+ 途经点间段（①→②→…→K），每段 MKDirections 真实道路算路；
// 段耗时 = 段距离/(速度×速度因子)，在真实算路 polyline 上重采样到目标点数（保持贴路）；
// 途经点对 <30m 或算路失败 → 降级直线（明确标注 degraded，不伪装成真实道路）。
+ (void)_processRegionPlan:(NSDictionary *)plan
                       cur:(CLLocationCoordinate2D)cur
                      mode:(NSString *)mode
                    joined:(NSMutableArray *)joined
                    segIdx:(NSUInteger)segIdx
              itineraryIdx:(NSUInteger)idx
                  segments:(NSArray<NSDictionary *> *)segments
                completion:(void (^)(NSDictionary *result, NSError *error))completion {
    NSArray *wps = plan[@"waypoints"];
    NSArray *stay = plan[@"staySeconds"];
    NSArray *factors = plan[@"moveFactors"];
    if (segIdx >= wps.count) {
        // 全部移动 + 停留完成 → 收尾到点停，继续下一个 itinerary 段
        CLLocationCoordinate2D end = [SimItineraryPlanner _lastPoint:joined];
        [SimItineraryPlanner _processSegmentAtIndex:idx + 1 segments:segments cur:end joined:joined completion:completion];
        return;
    }
    CLLocationCoordinate2D wp = [wps[segIdx] MKCoordinateValue];
    double staySec = [stay[segIdx] doubleValue];
    double factor = [factors[segIdx] doubleValue];
    double speed = [RegionSimulator effectiveSpeedForMode:mode];
    double segDist = [SimRouteCalculator haversineMeters:cur to:wp];
    double segTime = segDist / (speed * factor);
    void (^goStay)(CLLocationCoordinate2D) = ^(CLLocationCoordinate2D end) {
        // 到达途经点后停留（同点微动）；最后途经点不收尾补满（收尾到点停）
        [RegionSimulator appendStayPointsAt:end seconds:staySec into:joined];
        [SimItineraryPlanner _processRegionPlan:plan cur:end mode:mode joined:joined segIdx:segIdx + 1 itineraryIdx:idx segments:segments completion:completion];
    };
    if (segDist < 30.0) {
        TVLog(@"[locsim] region leg %lu degraded to line (<30m)", (unsigned long)segIdx);
        [joined addObjectsFromArray:[RegionSimulator degradedLinePointsFrom:cur to:wp seconds:segTime speed:speed]];
        goStay(wp);
        return;
    }
    [SimRouteCalculator calculateRoutePointsFrom:cur to:wp mode:mode completion:^(NSArray<NSDictionary *> *points, NSError *error) {
        if (error || points.count < 2) {
            TVLog(@"[locsim] region leg %lu degraded to line: %@", (unsigned long)segIdx, error.localizedDescription ?: @"too few points");
            [joined addObjectsFromArray:[RegionSimulator degradedLinePointsFrom:cur to:wp seconds:segTime speed:speed]];
            goStay(wp);
            return;
        }
        // 目标点数 = 段距离/(速度×因子)（因子>1 慢→点多，<1 快→点少，时间不平均）；
        // 在真实算路 polyline 上抽/插值到目标点数，保持贴路不穿越
        NSUInteger target = MAX(1, (NSUInteger)ceil(segDist / (speed * factor)));
        NSArray *resampled = [SimItineraryPlanner _resamplePoints:points toCount:target];
        [joined addObjectsFromArray:resampled];
        goStay([SimItineraryPlanner _lastPoint:resampled]);
    }];
}

// 在真实算路点序列上重采样到 target 个点（抽取/插值都在算路 polyline 上，保持真实道路形状）
+ (NSArray *)_resamplePoints:(NSArray<NSDictionary *> *)pts toCount:(NSUInteger)target {
    NSUInteger n = pts.count;
    if (n == 0) return pts;
    if (n == target) return pts;
    if (target == 1) return @[pts[n / 2]];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:target];
    if (target < n) {
        // 抽取：均匀取 target 个
        for (NSUInteger i = 0; i < target; i++) {
            NSUInteger idx = (NSUInteger)llround((double)(n - 1) * i / (double)(target - 1));
            [out addObject:pts[idx]];
        }
    } else {
        // 插值：在相邻算路点间线性插值（仍在算路段上）
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

#pragma mark - 工具

// 段序列末尾坐标（段终点 = 下一段起点，静态绑定）
+ (CLLocationCoordinate2D)_lastPoint:(NSArray<NSDictionary *> *)points {
    NSDictionary *last = points.lastObject;
    return CLLocationCoordinate2DMake([last[@"lat"] doubleValue], [last[@"lon"] doubleValue]);
}

@end
