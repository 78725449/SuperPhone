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

#import "TVNCButtonCell.h"
#import <Preferences/PSSpecifier.h>

@implementation TVNCButtonCell {
    UIView *_bgView;
    UILabel *_titleLabel;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (!self) {
        return nil;
    }

    // 2026-08-20 修复按钮消失（根因）：纯 UIView(bg) 无 intrinsicContentSize，
    // 若 PSListController 用自动行高，行高由内容 intrinsic 决定 → bg/label 无 intrinsic 或
    // 内容为空时行高塌缩为 0 → 按钮不可见。
    // 修复：改用 frame 布局（layoutSubviews 手动设置，不依赖 Auto Layout 求解）；
    // 行高由 Root.plist 的 height 属性明确指定（PSListController heightForRowAtIndexPath 读取）。
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;

    _bgView = [[UIView alloc] initWithFrame:CGRectZero];
    _bgView.backgroundColor = [UIColor colorWithRed:35 / 255.0 green:158 / 255.0 blue:171 / 255.0 alpha:1.0];
    _bgView.layer.cornerRadius = 10.0;
    _bgView.layer.masksToBounds = YES;
    [self.contentView addSubview:_bgView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 1;
    _titleLabel.lineBreakMode = NSLineBreakByClipping;
    [self.contentView addSubview:_titleLabel];

    [self _syncWithSpecifier:specifier];
    return self;
}

- (void)_syncWithSpecifier:(PSSpecifier *)specifier {
    if (!specifier) {
        return;
    }
    _titleLabel.text = [specifier propertyForKey:@"label"];
}

- (void)setSpecifier:(PSSpecifier *)specifier {
    [super setSpecifier:specifier];
    [self _syncWithSpecifier:specifier];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self _syncWithSpecifier:specifier];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 兜底：PSListController/PSTableCell 可能在刷新时重新显示系统 label
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;

    // frame 布局：背景撑满 contentView（上下 6 / 左右 16 内缩），标题撑满背景居中
    CGRect b = self.contentView.bounds;
    if (b.size.width < 20 || b.size.height < 20) {
        return;
    }
    CGFloat vInset = 6.0;
    CGFloat hInset = 16.0;
    _bgView.frame = CGRectMake(hInset, vInset, b.size.width - hInset * 2, b.size.height - vInset * 2);
    _titleLabel.frame = _bgView.frame;
}

@end
