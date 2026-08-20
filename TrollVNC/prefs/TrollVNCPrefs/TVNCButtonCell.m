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

    // 2026-08-20 修复按钮消失：纯 UIView(bg) 无 intrinsic，自动行高下塌缩为 0。
    // 修复：frame 布局（layoutSubviews 手动设置），行高由 Root.plist height 属性指定。
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
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;

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
