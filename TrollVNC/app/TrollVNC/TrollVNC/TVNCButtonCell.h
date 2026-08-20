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
 * 仅负责渲染（自建 UILabel 标题 + 圆角背景）；点击交系统 PSListController
 * didSelect → [specifier perform] 触发 action（与普通 PSButtonCell 同路径）。
 * 注意：不可手动调 [specifier target]/[specifier action]——PSSpecifier 无这两个
 * getter（虚构声明会 unrecognized selector 崩溃）。
 * 与 app/TrollVNC/TrollVNC/TVNCButtonCell 为分叉副本，互不引用。
 */
@interface TVNCButtonCell : PSTableCell

@end

NS_ASSUME_NONNULL_END
