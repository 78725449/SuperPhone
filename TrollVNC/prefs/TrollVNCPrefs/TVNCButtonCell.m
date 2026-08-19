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

// PSSpecifier 私有 perform（执行 target/action），bootstrap 头未声明，本地补声明
@interface PSSpecifier (TVNCButtonAccess)
- (void)perform;
@end

@implementation TVNCButtonCell {
    UIButton *_button;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (!self) {
        return nil;
    }

    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    // 2026-08-20：不用 UIButtonConfiguration（iOS 15+ API，Theos 编译目标低于 iOS 15 会 -Werror 报错），
    // 改用 iOS 15 之前就兼容的 UIButton + setTitle/backgroundColor/cornerRadius
    _button = [UIButton buttonWithType:UIButtonTypeCustom];
    _button.translatesAutoresizingMaskIntoConstraints = NO;
    _button.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    [_button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_button setBackgroundColor:[UIColor colorWithRed:35 / 255.0 green:158 / 255.0 blue:171 / 255.0 alpha:1.0]];
    _button.layer.cornerRadius = 10.0;
    _button.layer.masksToBounds = YES;
    [_button addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_button];

    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_button.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [_button.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [_button.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
        [_button.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
    ]];

    [self _syncWithSpecifier:specifier];
    return self;
}

- (void)_syncWithSpecifier:(PSSpecifier *)specifier {
    if (!specifier) {
        return;
    }
    [_button setTitle:[specifier propertyForKey:@"label"] forState:UIControlStateNormal];
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

- (void)buttonTapped {
    [self.specifier perform];
}

@end
