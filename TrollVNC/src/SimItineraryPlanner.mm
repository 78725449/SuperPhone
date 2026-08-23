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
        NSArray<NSDictionary *> *pts = [RegionSimulator generateRegionPointsCenter:c radius:radius mode:mode durationMin:durationMin startFrom:cur];
        CLLocationCoordinate2D end = [SimItineraryPlanner _lastPoint:pts];
        [joined addObjectsFromArray:pts];
        [SimItineraryPlanner _processSegmentAtIndex:idx + 1 segments:segments cur:end joined:joined completion:completion];
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

#pragma mark - 工具

// 段序列末尾坐标（段终点 = 下一段起点，静态绑定）
+ (CLLocationCoordinate2D)_lastPoint:(NSArray<NSDictionary *> *)points {
    NSDictionary *last = points.lastObject;
    return CLLocationCoordinate2DMake([last[@"lat"] doubleValue], [last[@"lon"] doubleValue]);
}

@end
