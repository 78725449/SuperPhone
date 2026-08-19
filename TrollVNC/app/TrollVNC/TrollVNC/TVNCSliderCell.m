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

#import "TVNCSliderCell.h"
#import <Preferences/PSSpecifier.h>

@implementation TVNCSliderCell {
    UILabel *_titleLabel;
    UISlider *_slider;
    UILabel *_valueLabel;
    NSString *_formatString;
    CGFloat _valueLabelWidth;
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
    // 若再手动给 textLabel 加约束会双约束冲突 → Auto Layout 破坏性布局 → 标题与滑杆互相覆盖。
    // 改为 contentView 自建 UILabel，约束只作用于自建视图，与系统布局完全隔离。
    // detailTextLabel 会被 PSTableCell 设为当前值（如 "full"），一并隐藏。
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.numberOfLines = 1;
    _titleLabel.lineBreakMode = NSLineBreakByClipping;
    [self.contentView addSubview:_titleLabel];

    // Read custom value label width (default 50)
    NSNumber *labelWidthNum = [specifier propertyForKey:@"valueLabelWidth"];

    if (labelWidthNum && [labelWidthNum isKindOfClass:[NSNumber class]]) {
        _valueLabelWidth = [labelWidthNum floatValue];
    } else {
        // 2026-08-20 调节阀加长：值标签默认 50→46，字体 13pt，进一步让位给滑杆
        _valueLabelWidth = 46.0;
    }

    // Create slider
    _slider = [[UISlider alloc] init];
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    [_slider addTarget:self action:@selector(sliderValueChanged:) forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:_slider];

    // Create value label (only if showValue is true)
    NSNumber *showValue = [specifier propertyForKey:@"showValue"];

    if (!showValue || [showValue boolValue]) {
        _valueLabel = [[UILabel alloc] init];
        _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightRegular];
        _valueLabel.textColor = [UIColor secondaryLabelColor];
        _valueLabel.numberOfLines = 1;
        _valueLabel.lineBreakMode = NSLineBreakByClipping;
        [self.contentView addSubview:_valueLabel];
    }

    // Sync slider properties from specifier
    [self _syncWithSpecifier:specifier];

    // Setup constraints
    [self setupConstraints];

    return self;
}

- (void)setupConstraints {
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;

    // 布局：标题靠左（空间不足时可截断）、valueLabel 靠右、slider 填充中间。
    // 2026-08-20 调节阀加长：标题压缩阻力降为低值（300，可截断），间距 12→8，
    // slider 保持默认压缩阻力（750）——空间不足时牺牲标题宽度、滑杆优先保持最长。
    // 2026-08-20 修复"滑杆被宽度限制"：slider.leading 从 GreaterThanOrEqual 改为固定 Equal——
    // 不等式 + UISlider 固有宽度会导致轨道不拉伸、只占中间一段；固定 leading 让 slider 明确从标题右侧铺到值标签。
    NSMutableArray *constraints = [NSMutableArray array];
    [constraints addObject:[_titleLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor]];
    [constraints addObject:[_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor]];
    [constraints addObject:[_slider.leadingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor constant:8]];
    if (_valueLabel) {
        // Value label on the right
        [constraints addObject:[_valueLabel.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor]];
        [constraints addObject:[_valueLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor]];
        [constraints addObject:[_valueLabel.widthAnchor constraintEqualToConstant:_valueLabelWidth]];
        [constraints addObject:[_slider.trailingAnchor constraintEqualToAnchor:_valueLabel.leadingAnchor constant:-8]];
    } else {
        [constraints addObject:[_slider.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor]];
    }
    [constraints addObject:[_slider.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor]];
    [NSLayoutConstraint activateConstraints:constraints];

    [_titleLabel setContentCompressionResistancePriority:(UILayoutPriority)300
                                                 forAxis:UILayoutConstraintAxisHorizontal];
    [_slider setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh
                                             forAxis:UILayoutConstraintAxisHorizontal];
    [_slider setContentHuggingPriority:(UILayoutPriority)250
                               forAxis:UILayoutConstraintAxisHorizontal];

    // Fixed height constraint
    [NSLayoutConstraint activateConstraints:@[
        [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
    ]];
}

- (void)_syncWithSpecifier:(PSSpecifier *)specifier {
    if (!specifier) {
        return;
    }

    _titleLabel.text = [specifier propertyForKey:@"label"];

    _formatString = [specifier propertyForKey:@"format"];

    if (!_formatString || ![_formatString isKindOfClass:[NSString class]]) {
        _formatString = @"%.0f";
    }

    NSNumber *minValue = [specifier propertyForKey:@"min"];
    NSNumber *maxValue = [specifier propertyForKey:@"max"];

    if (minValue) {
        _slider.minimumValue = [minValue floatValue];
    }

    if (maxValue) {
        _slider.maximumValue = [maxValue floatValue];
    }

    NSNumber *isContinuous = [specifier propertyForKey:@"isContinuous"];
    _slider.continuous = isContinuous ? [isContinuous boolValue] : YES;

    id value = [specifier performGetter];

    if ([value isKindOfClass:[NSNumber class]]) {
        _slider.value = [value floatValue];
    } else {
        NSNumber *defaultValue = [specifier propertyForKey:@"default"];

        if (defaultValue) {
            _slider.value = [defaultValue floatValue];
        }
    }

    [self updateValueLabel];
}

- (void)setSpecifier:(PSSpecifier *)specifier {
    [super setSpecifier:specifier];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
    [self _syncWithSpecifier:specifier];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
    [self _syncWithSpecifier:specifier];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 兜底：PSListController/PSTableCell 可能在刷新时重新显示系统 label
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
}

- (void)updateValueLabel {
    if (_valueLabel) {
        _valueLabel.text = [NSString stringWithFormat:_formatString, _slider.value];
    }
}

- (void)sliderValueChanged:(UISlider *)slider {
    PSSpecifier *specifier = self.specifier;

    // Handle segmented slider - snap to discrete values
    NSNumber *isSegmented = [specifier propertyForKey:@"isSegmented"];

    if (isSegmented && [isSegmented boolValue]) {
        NSNumber *segmentCount = [specifier propertyForKey:@"segmentCount"];

        if (segmentCount && [segmentCount integerValue] > 0) {
            NSInteger segments = [segmentCount integerValue];
            CGFloat range = slider.maximumValue - slider.minimumValue;
            CGFloat step = range / (CGFloat)segments;
            CGFloat normalizedValue = (slider.value - slider.minimumValue) / step;
            CGFloat snappedValue = slider.minimumValue + (round(normalizedValue) * step);
            slider.value = snappedValue;
        }
    }

    // Update value label
    [self updateValueLabel];

    // Notify the specifier's target - use performSetterWithValue method
    if (specifier) {
        NSNumber *value = @(slider.value);
        [specifier performSetterWithValue:value];
    }
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _slider.value = _slider.minimumValue;
    _titleLabel.text = nil;
    _valueLabel.text = nil;
}

@end
