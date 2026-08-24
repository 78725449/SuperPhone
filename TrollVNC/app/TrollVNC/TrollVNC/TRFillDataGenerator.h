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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 数据填充参数组装器（M5 阶段 2）：UI 参数 → TRDataFiller 统一参数
/// 参数契约与注册表 data.fill / TRDataFiller 完全一致（db/count/seed/ratios）。
@interface TRFillDataGenerator : NSObject

/// 组装 data.fill 请求参数
/// @param kind  'contacts' | 'calls' | 'sms'
/// @param count 生成条数
/// @param seed  数字种子（点击随机）
/// @param ratios 比例参数 {incoming/outgoing…}（UI 滑条汇总，可空=默认分布）
+ (NSDictionary *)requestForKind:(NSString *)kind
                           count:(NSInteger)count
                            seed:(uint64_t)seed
                          ratios:(nullable NSDictionary *)ratios;

@end

NS_ASSUME_NONNULL_END
