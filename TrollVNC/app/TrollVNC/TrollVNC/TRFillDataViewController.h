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

/// 数据填充子页（M5 阶段 2）：联系人/通话/短信三 tab 的参数面板
/// 参数项集合以系统库实证字段为准（M5 计划 §4.0）：数量/时间分布/比例（拨入拨出比、收发比）等；
/// 交互形式参考原型（滑条占比联动、数字种子点击随机、生成反馈按钮下方）。
/// 生成调用：TRFillDataGenerator 组装 → TRDataFiller（App 进程内直接执行，写库+kill daemon）。
@interface TRFillDataViewController : UIViewController

/// @param kind 'contacts' | 'calls' | 'sms'
- (instancetype)initWithKind:(NSString *)kind;

@end

NS_ASSUME_NONNULL_END
