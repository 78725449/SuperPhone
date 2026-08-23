/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "SimRouteCalculator.h"

#import <MapKit/MapKit.h>

#import "SimLocationController.h"
#import "Logging.h"

@implementation SimRouteCalculator

+ (void)calculateRouteFrom:(CLLocationCoordinate2D)from
                        to:(CLLocationCoordinate2D)to
                      mode:(NSString *)mode {
    NSString *m = mode.length ? mode : @"walk";
    double mps = 1.4;
    MKDirectionsTransportType tt = MKDirectionsTransportTypeWalking;
    if ([m isEqualToString:@"drive"]) {
        mps = 13.9;
        tt = MKDirectionsTransportTypeAutomobile;
    }
    // 仅 walk/drive 两个稳定真实档（Apple transportType 公开档）；其他值按 walk 兜底
    MKDirectionsRequest *req = [[MKDirectionsRequest alloc] init];
    req.source = [MKMapItem placemarkWithCoordinate:from];
    req.destination = [MKMapItem placemarkWithCoordinate:to];
    req.transportType = tt;
    MKDirections *dir = [[MKDirections alloc] initWithRequest:req];
    TVLog(@"[simroute] calculate %@ (%.5f,%.5f)->(%.5f,%.5f)", m, from.latitude, from.longitude, to.latitude, to.longitude);
    [dir calculateDirectionsWithCompletionHandler:^(MKDirectionsResponse *response, NSError *error) {
        if (error) {
            TVLog(@"[simroute] MKDirections error: %@", error.localizedDescription);
            return;
        }
        MKRoute *route = response.routes.firstObject;
        if (!route) { TVLog(@"[simroute] no route"); return; }
        MKPolyline *polyline = route.polyline;
        NSUInteger count = polyline.pointCount;
        if (count < 2) { TVLog(@"[simroute] polyline too short (%lu)", (unsigned long)count); return; }
        CLLocationCoordinate2D *coords = malloc(count * sizeof(CLLocationCoordinate2D));
        if (!coords) { TVLog(@"[simroute] malloc failed"); return; }
        [polyline getCoordinates:coords range:NSMakeRange(0, count)];
        NSArray *points = [SimRouteCalculator resample:coords count:count mps:mps];
        free(coords);
        if (points.count < 2) { TVLog(@"[simroute] resample too few points"); return; }
        NSError *uerr = nil;
        if (![SimLocationController uploadTrackPoints:points error:&uerr]) {
            TVLog(@"[simroute] upload failed: %@", uerr.localizedDescription ?: @"unknown");
            return;
        }
        [[SimLocationController sharedController] reloadFromPrefs];
        TVLog(@"[simroute] ok: %lu points, %.1f km, mode=%@", (unsigned long)points.count, route.distance / 1000.0, m);
    }];
}

#pragma mark - 沿 polyline 按速度重采样（步长=speed×1s，拟人参数对齐网关 trajectory-gen）

+ (NSArray *)resample:(CLLocationCoordinate2D *)coords count:(NSUInteger)count mps:(double)mps {
    // 先求累计距离（haversine）
    double *cum = malloc(count * sizeof(double));
    if (!cum) return @[];
    cum[0] = 0;
    for (NSUInteger i = 1; i < count; i++) {
        cum[i] = cum[i - 1] + [SimRouteCalculator haversineMeters:coords[i - 1] to:coords[i]];
    }
    double total = cum[count - 1];
    if (total <= 0) { free(cum); return @[]; }
    const double step = mps;            // 每秒 1 步
    const double jitterDeg = 0.3 / 111320.0; // ±0.3m 抖动（双轴合成 ≤±0.85m）
    NSMutableArray *pts = [NSMutableArray array];
    // 沿累计距离等距取点，段内线性插值
    double cursor = 0;
    NSUInteger seg = 1;
    while (cursor <= total) {
        while (seg < count && cum[seg] < cursor) seg++;
        if (seg >= count) seg = count - 1;
        double segStart = cum[seg - 1], segLen = cum[seg] - cum[seg - 1];
        double t = segLen > 0 ? (cursor - segStart) / segLen : 0;
        double lat = coords[seg - 1].latitude + (coords[seg].latitude - coords[seg - 1].latitude) * t;
        double lon = coords[seg - 1].longitude + (coords[seg].longitude - coords[seg - 1].longitude) * t;
        double course = [SimRouteCalculator headingDeg:coords[seg - 1] to:coords[seg]];
        double normCourse = fmod(course + (drand48() - 0.5) * 8 + 360.0, 360.0); // 航向 ±4° 抖动 + 归一化
        NSDictionary *pt = @{
            @"lat": @(lat + (drand48() - 0.5) * 2 * jitterDeg),
            @"lon": @(lon + (drand48() - 0.5) * 2 * jitterDeg),
            @"speed": @(mps * (0.9 + drand48() * 0.2)),
            @"course": @(normCourse),
            @"alt": @(45.0 + (drand48() - 0.5)),
            @"acc": @(3.0 + drand48() * 3.0),
        };
        [pts addObject:pt];
        cursor += step;
    }
    free(cum);
    return pts;
}

+ (double)haversineMeters:(CLLocationCoordinate2D)a to:(CLLocationCoordinate2D)b {
    const double R = 6371000.0;
    double dLat = (b.latitude - a.latitude) * M_PI / 180.0;
    double dLon = (b.longitude - a.longitude) * M_PI / 180.0;
    double la = a.latitude * M_PI / 180.0, lb = b.latitude * M_PI / 180.0;
    double h = sin(dLat / 2) * sin(dLat / 2) + cos(la) * cos(lb) * sin(dLon / 2) * sin(dLon / 2);
    return 2 * R * asin(sqrt(h));
}

+ (double)headingDeg:(CLLocationCoordinate2D)a to:(CLLocationCoordinate2D)b {
    double dLon = (b.longitude - a.longitude) * M_PI / 180.0;
    double y = sin(dLon) * cos(b.latitude * M_PI / 180.0);
    double x = cos(a.latitude * M_PI / 180.0) * sin(b.latitude * M_PI / 180.0)
             - sin(a.latitude * M_PI / 180.0) * cos(b.latitude * M_PI / 180.0) * cos(dLon);
    return fmod(atan2(y, x) * 180.0 / M_PI + 360.0, 360.0);
}

@end
