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

#import "CoordTransform.h"
#import <math.h>

/// GCJ-02 椭球参数（公开常数）
static const double kA  = 6378245.0;
static const double kEe = 0.00669342162296594323;

static double _transformLat(double x, double y) {
    double ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(fabs(x));
    ret += (20.0 * sin(6.0 * x * M_PI) + 20.0 * sin(2.0 * x * M_PI)) * 2.0 / 3.0;
    ret += (20.0 * sin(y * M_PI) + 40.0 * sin(y / 3.0 * M_PI)) * 2.0 / 3.0;
    ret += (160.0 * sin(y / 12.0 * M_PI) + 320.0 * sin(y * M_PI / 30.0)) * 2.0 / 3.0;
    return ret;
}

static double _transformLon(double x, double y) {
    double ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(fabs(x));
    ret += (20.0 * sin(6.0 * x * M_PI) + 20.0 * sin(2.0 * x * M_PI)) * 2.0 / 3.0;
    ret += (20.0 * sin(x * M_PI) + 40.0 * sin(x / 3.0 * M_PI)) * 2.0 / 3.0;
    ret += (150.0 * sin(x / 12.0 * M_PI) + 300.0 * sin(x / 30.0 * M_PI)) * 2.0 / 3.0;
    return ret;
}

/// 计算 GCJ-02 偏移量（返回 dLat/dLon，单位度）
static void _offset(double lat, double lon, double *dLatOut, double *dLonOut) {
    double dLat = _transformLat(lon - 105.0, lat - 35.0);
    double dLon = _transformLon(lon - 105.0, lat - 35.0);
    double radLat = lat / 180.0 * M_PI;
    double magic = sin(radLat);
    magic = 1.0 - kEe * magic * magic;
    double sqrtMagic = sqrt(magic);
    dLat = (dLat * 180.0) / ((kA * (1.0 - kEe)) / (magic * sqrtMagic) * M_PI);
    dLon = (dLon * 180.0) / (kA / sqrtMagic * cos(radLat) * M_PI);
    if (dLatOut) *dLatOut = dLat;
    if (dLonOut) *dLonOut = dLon;
}

@implementation CoordTransform

+ (BOOL)outOfChinaLatitude:(double)lat longitude:(double)lon {
    return lon < 72.004 || lon > 137.8347 || lat < 0.8293 || lat > 55.8271;
}

+ (BOOL)isValidSimCoordinate:(CLLocationCoordinate2D)coord {
    if (coord.latitude == 0 && coord.longitude == 0) return NO;  // 无效基线
    if ([self outOfChinaLatitude:coord.latitude longitude:coord.longitude]) return NO;  // 越界（含 lat≈0 赤道类坏数据）
    return YES;
}

+ (CLLocationCoordinate2D)gcj02ToWgs84:(CLLocationCoordinate2D)gcj {
    if ([self outOfChinaLatitude:gcj.latitude longitude:gcj.longitude]) return gcj;
    double dLat = 0, dLon = 0;
    _offset(gcj.latitude, gcj.longitude, &dLat, &dLon);
    return CLLocationCoordinate2DMake(gcj.latitude - dLat, gcj.longitude - dLon);
}

+ (CLLocationCoordinate2D)wgs84ToGcj02:(CLLocationCoordinate2D)wgs {
    if ([self outOfChinaLatitude:wgs.latitude longitude:wgs.longitude]) return wgs;
    // 一次偏移近似（公开算法标准形式）
    double dLat = 0, dLon = 0;
    _offset(wgs.latitude, wgs.longitude, &dLat, &dLon);
    return CLLocationCoordinate2DMake(wgs.latitude + dLat, wgs.longitude + dLon);
}

@end
