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

/// 坐标系转换（GCJ-02 ↔ WGS-84）——编排/注入双世界的边界转换器
/// 中国区坐标语义（2026-09-04 治理定案）：
/// - Apple 地图瓦片 = GCJ-02（合法偏移化）；MapKit API 层（annotation/overlay/convertPoint/MKDirections）
///   与瓦片同系 = GCJ 语义——App 编排世界（锚点/路线/self.cur/UI）统一存瓦片系数值
/// - locationd 广播 = WGS-84 语义（真实 GPS 原始值；MapKit 显示 MKUserLocation 时自动偏移对齐瓦片）
/// - 注入出口（injectPoint）GCJ→WGS：对外 App 拿到真实地理位置（根治"GCJ 数值冒充 WGS"的东南 500m 偏移）
/// - fix 入口（handleLocationUpdate）WGS→GCJ：广播值转回瓦片系参与编排计算（与锚点/锁/判定同系）
/// - App 内地图显示自洽：锚点/路线（GCJ 直画瓦片）+ 水滴（系统偏移）+ 状态栏（瓦片系数值）
/// 算法来源：公开 GCJ-02 偏移数学模型（非第三方源码）；一次偏移近似精度 ~2m，远小于偏移量本身。
@interface CoordTransform : NSObject

/// 模拟系统合法坐标谓词（2026-09-04 治理）：中国境内（非越界）且纬度非零——
/// 全链路（App 写 plist/handleLocationUpdate、daemon 读 plist/injectPoint/微动/persistState）
/// 统一用它拒绝无效坐标（{0,0}、lat=0 破碎对、境外值），杜绝"无效数据穿透五层防线"
+ (BOOL)isValidSimCoordinate:(CLLocationCoordinate2D)coord;

/// 是否越出中国范围（近似判断，越界坐标原样返回不转换）
+ (BOOL)outOfChinaLatitude:(double)lat longitude:(double)lon;

/// GCJ-02 → WGS-84（地图选点出口统一走这里）
+ (CLLocationCoordinate2D)gcj02ToWgs84:(CLLocationCoordinate2D)gcj;

/// WGS-84 → GCJ-02（设备坐标画回地图 / 展示用）
+ (CLLocationCoordinate2D)wgs84ToGcj02:(CLLocationCoordinate2D)wgs;

@end

NS_ASSUME_NONNULL_END
