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
 * 全宽按钮 cell（2026-08-20）：用于搜索/连接网关、重新生成证书。
 * 背景：系统 PSButtonCell + cellForRowAtIndexPath 改样式在 iOS 15 上不可靠（复用串状态/不生效），
 * 改用 cellClass 自定义 + UIButtonConfiguration（filled）——渲染完全自控、点击经 [specifier perform] 触发 action。
 */
@interface TVNCButtonCell : PSTableCell

@end

NS_ASSUME_NONNULL_END
