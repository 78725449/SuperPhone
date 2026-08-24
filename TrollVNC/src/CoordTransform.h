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

#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/// 坐标系转换（GCJ-02 ↔ WGS-84）
/// 公开算法（与网关 Node 侧 / 原型 JS 版一致）：
/// - MKMapView 中国区瓦片为 GCJ-02，地图选点/区域圆心出口必须过 gcj02ToWgs84 再写设备
/// - 设备端（SimLocationManager 注入）只收 WGS-84
/// 算法来源：公开 GCJ-02 偏移数学模型（非第三方源码）。
@interface CoordTransform : NSObject

/// 是否越出中国范围（近似判断，越界坐标原样返回不转换）
+ (BOOL)outOfChinaLatitude:(double)lat longitude:(double)lon;

/// GCJ-02 → WGS-84（地图选点出口统一走这里）
+ (CLLocationCoordinate2D)gcj02ToWgs84:(CLLocationCoordinate2D)gcj;

/// WGS-84 → GCJ-02（设备坐标画回地图 / 展示用）
+ (CLLocationCoordinate2D)wgs84ToGcj02:(CLLocationCoordinate2D)wgs;

@end

NS_ASSUME_NONNULL_END
