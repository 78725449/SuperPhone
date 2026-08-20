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

// PSSpecifier 私有 target/action 属性（bootstrap 头未声明，本地补声明）——
// 不用 perform（私有方法内部 performSelector:withObject: 带参调用 action，无参方法会崩溃）
@interface PSSpecifier (TVNCButtonAccess)
@property(nonatomic, retain) id target;
- (SEL)action;
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
    // 兜底：PSListController/PSTableCell 可能在刷新时重新显示系统 label
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
}

- (void)buttonTapped {
    PSSpecifier *specifier = self.specifier;
    if (!specifier) {
        return;
    }
    id target = [specifier target];
    SEL action = [specifier action];
    if (!target || !action) {
        return;
    }
    // 2026-08-20 修复闪退：action 为无参方法（generateKeys/searchGateway/connectGateway），
    // 必须无参调用——用 [specifier perform] 内部是 performSelector:withObject: 带参调用无参方法会崩溃。
    [target performSelector:action];
}

@end
