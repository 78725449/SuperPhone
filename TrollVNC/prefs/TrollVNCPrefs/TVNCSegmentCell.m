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

#import "TVNCSegmentCell.h"
#import <Preferences/PSSpecifier.h>

@implementation TVNCSegmentCell {
    UILabel *_titleLabel;
    UISegmentedControl *_control;
    NSArray<NSString *> *_validValues;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (!self) {
        return nil;
    }

    // 2026-08-20 修复重叠：不用系统的 textLabel 承载标题。
    // iOS 15 的 UITableViewCell/PSTableCell 对 textLabel 有内置约束（leading/centerY 等），
    // 若再手动给 textLabel 加约束会双约束冲突 → Auto Layout 破坏性布局 → 标题与控件互相覆盖。
    // 改为 contentView 自建 UILabel，约束只作用于自建视图，与系统布局完全隔离。
    self.textLabel.hidden = YES;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.numberOfLines = 1;
    _titleLabel.lineBreakMode = NSLineBreakByClipping;
    [self.contentView addSubview:_titleLabel];

    _control = [[UISegmentedControl alloc] init];
    _control.translatesAutoresizingMaskIntoConstraints = NO;
    [_control addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:_control];

    // 布局对齐系统 PSSegmentCell：标题靠左、分段控件靠右。
    // 空间不足时标题优先保留（高压缩阻力）、控件允许压缩（低压缩阻力），避免窄屏溢出/重叠。
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_control.leadingAnchor constraintGreaterThanOrEqualToAnchor:_titleLabel.trailingAnchor constant:12],
        [_control.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [_control.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
    ]];
    [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                 forAxis:UILayoutConstraintAxisHorizontal];
    [_control setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                              forAxis:UILayoutConstraintAxisHorizontal];
    [_control setContentHuggingPriority:UILayoutPriorityDefaultLow
                                forAxis:UILayoutConstraintAxisHorizontal];

    [self _syncWithSpecifier:specifier];
    return self;
}

- (void)_syncWithSpecifier:(PSSpecifier *)specifier {
    if (!specifier) {
        return;
    }

    _titleLabel.text = [specifier propertyForKey:@"label"];

    NSArray *values = [specifier propertyForKey:@"validValues"];
    NSArray *titles = [specifier propertyForKey:@"validTitles"];

    _validValues = [values isKindOfClass:[NSArray class]] ? values : nil;
    if (!_validValues.count) {
        _validValues = @[];
    }

    [_control removeAllSegments];
    for (NSUInteger i = 0; i < _validValues.count; i++) {
        NSString *title = nil;
        if ([titles isKindOfClass:[NSArray class]] && i < titles.count) {
            title = [titles[i] isKindOfClass:[NSString class]] ? titles[i] : [NSString stringWithFormat:@"%@", titles[i]];
        }
        if (!title.length) {
            title = [NSString stringWithFormat:@"%@", _validValues[i]];
        }
        [_control insertSegmentWithTitle:title atIndex:(NSInteger)i animated:NO];
    }

    // 读当前值（字符串）→ 匹配段索引；未匹配则用 default 或第 0 段
    id current = [specifier performGetter];
    NSInteger index = NSNotFound;
    if (current) {
        NSString *curStr = [current isKindOfClass:[NSString class]] ? current
                            : [NSString stringWithFormat:@"%@", current];
        index = [_validValues indexOfObject:curStr];
    }
    if (index == NSNotFound) {
        id def = [specifier propertyForKey:@"default"];
        if (def) {
            NSString *defStr = [def isKindOfClass:[NSString class]] ? def
                                : [NSString stringWithFormat:@"%@", def];
            index = [_validValues indexOfObject:defStr];
        }
    }
    _control.selectedSegmentIndex = (index != NSNotFound) ? index : (_validValues.count ? 0 : UISegmentedControlNoSegment);
}

- (void)setSpecifier:(PSSpecifier *)specifier {
    [super setSpecifier:specifier];
    self.textLabel.hidden = YES;
    [self _syncWithSpecifier:specifier];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    self.textLabel.hidden = YES;
    [self _syncWithSpecifier:specifier];
}

- (void)segmentChanged:(UISegmentedControl *)control {
    PSSpecifier *specifier = self.specifier;
    if (!specifier || control.selectedSegmentIndex < 0 || (NSUInteger)control.selectedSegmentIndex >= _validValues.count) {
        return;
    }
    NSString *value = _validValues[control.selectedSegmentIndex];
    [specifier performSetterWithValue:value];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _control.selectedSegmentIndex = UISegmentedControlNoSegment;
    _titleLabel.text = nil;
}

@end
