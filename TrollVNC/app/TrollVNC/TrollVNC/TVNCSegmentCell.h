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

#import <Preferences/PSTableCell.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 分段选择 cell（2026-08-20）：系统 PSSegmentCell 的 validValues/default 只支持整数索引，
 * 而我们配置值是字符串（如 ConnectionMode=relay/bridge）。自定义 cell 在
 * 「字符串值 ↔ 段索引」间转换：读时按 validValues 匹配索引、写时按索引取 validValues 值。
 * 用法：cell=TVNCSegmentCell + validValues(字符串数组) + validTitles + default(字符串)。
 */
@interface TVNCSegmentCell : PSTableCell

@end

NS_ASSUME_NONNULL_END
