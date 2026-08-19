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

    // 系统 textLabel/detailTextLabel 一并隐藏（本 cell 用自建 UIButton 渲染全宽按钮）
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
    cfg.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    cfg.baseBackgroundColor = [UIColor colorWithRed:35 / 255.0 green:158 / 255.0 blue:171 / 255.0 alpha:1.0];
    cfg.baseForegroundColor = [UIColor whiteColor];
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *_Nonnull(
        NSDictionary<NSAttributedStringKey, id> *_Nonnull attrs) {
        NSMutableDictionary *a = [attrs mutableCopy];
        a[NSFontAttributeName] = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        return a;
    };

    _button = [UIButton buttonWithConfiguration:cfg];
    _button.translatesAutoresizingMaskIntoConstraints = NO;
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
    UIButtonConfiguration *cfg = _button.configuration;
    cfg.title = [specifier propertyForKey:@"label"];
    _button.configuration = cfg;
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
}

- (void)buttonTapped {
    [self.specifier perform];
}

@end
