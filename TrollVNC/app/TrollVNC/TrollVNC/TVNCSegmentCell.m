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

    _control = [[UISegmentedControl alloc] init];
    _control.translatesAutoresizingMaskIntoConstraints = NO;
    [_control addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:_control];

    // 布局对齐系统 PSSegmentCell：标题靠左、分段控件靠右（PSTableCell 的 super init
    // 已按 specifier 的 label 设置 self.textLabel.text）。control 不强制占满整行，
    // 仅约束 leading >= label.trailing + 12，避免 5 段（如帧率）时挤压标题。
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    UILabel *label = self.textLabel;
    BOOL hasLabel = (label.text.length > 0);
    if (hasLabel) {
        label.translatesAutoresizingMaskIntoConstraints = NO;
    }

    NSMutableArray *constraints = [NSMutableArray array];
    if (hasLabel) {
        [constraints addObject:[label.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor]];
        [constraints addObject:[label.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor]];
        [constraints addObject:[_control.leadingAnchor constraintGreaterThanOrEqualToAnchor:label.trailingAnchor constant:12]];
        [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    } else {
        [constraints addObject:[_control.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor]];
    }
    [constraints addObject:[_control.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor]];
    [constraints addObject:[_control.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor]];
    [NSLayoutConstraint activateConstraints:constraints];

    [NSLayoutConstraint activateConstraints:@[
        [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
    ]];

    [self _syncWithSpecifier:specifier];
    return self;
}

- (void)_syncWithSpecifier:(PSSpecifier *)specifier {
    if (!specifier) {
        return;
    }

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
    [self _syncWithSpecifier:specifier];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
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
}

@end
