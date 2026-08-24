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

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 位置模拟子页（M5 阶段 1）
/// 交互链路+布局参考原型：全屏地图 + 递增编排（首击=起点、再击=加路线以上一位置为起点、
/// 长按=区域中心+拖半径+遮罩+从上一位置"生长"路线）+ 右下角定位开关 + 左下步行/驾车胶囊。
/// 执行：App 前台 MKDirections 算路（与注册表 sim.* 同一实现）→ GCJ→WGS 转换 →
/// 原子写轨迹文件 + SimLocationMode=itinerary + notify_post → manager 注入。
@interface TRMapPickerViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
