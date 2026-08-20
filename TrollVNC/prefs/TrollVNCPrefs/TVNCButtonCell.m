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
    UILabel *_titleLabel;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (!self) {
        return nil;
    }

    // 2026-08-20 修复按钮点击闪退（根因）：仅渲染（自建 UILabel + 圆角背景），
    // 点击交系统 PSListController didSelect → [specifier perform] 触发 action；
    // 不可手动调 [specifier target]/[specifier action]（PSSpecifier 无此 getter，会崩溃）。
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;

    UIView *bg = [[UIView alloc] init];
    bg.translatesAutoresizingMaskIntoConstraints = NO;
    bg.backgroundColor = [UIColor colorWithRed:35 / 255.0 green:158 / 255.0 blue:171 / 255.0 alpha:1.0];
    bg.layer.cornerRadius = 10.0;
    bg.layer.masksToBounds = YES;
    [self.contentView addSubview:bg];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 1;
    _titleLabel.lineBreakMode = NSLineBreakByClipping;
    [self.contentView addSubview:_titleLabel];

    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [bg.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [bg.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [bg.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
        [bg.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
        [_titleLabel.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    ]];

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
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
}

@end
