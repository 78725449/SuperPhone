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

/// 伪装页容器（M5）：顶部 UISegmentedControl 4 段（位置模拟/联系人/通话/短信）+ 子页容器
/// 交互链路与布局以原型（outputs/locsim-app-prototype.html）为参考；
/// 参数定义/行为以设备端能力与系统库实证字段为准（原型无决定权）。
@interface TRDisguiseViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
