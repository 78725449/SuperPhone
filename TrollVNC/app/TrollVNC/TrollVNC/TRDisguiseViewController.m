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

#import "TRDisguiseViewController.h"
#import "TRMapPickerViewController.h"
#import "TRFillDataViewController.h"

/// 子页索引
typedef NS_ENUM(NSUInteger, TRDisguiseSegment) {
    TRDisguiseSegmentLocation = 0, // 位置模拟
    TRDisguiseSegmentContacts,     // 联系人
    TRDisguiseSegmentCalls,        // 通话
    TRDisguiseSegmentSms,          // 短信
};

@interface TRDisguiseViewController ()
@property (nonatomic, strong) UISegmentedControl *segControl;
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) TRMapPickerViewController *locationVC;
@property (nonatomic, strong) TRFillDataViewController *contactsVC;
@property (nonatomic, strong) TRFillDataViewController *callsVC;
@property (nonatomic, strong) TRFillDataViewController *smsVC;
@property (nonatomic, strong) UIViewController *currentChild;
@end

@implementation TRDisguiseViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self setupSegmentedControl];
    [self setupContainer];
    [self switchToSegment:TRDisguiseSegmentLocation];
}

- (void)setupSegmentedControl {
    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"位置模拟", @"联系人", @"通话", @"短信"]];
    seg.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:seg];
    [NSLayoutConstraint activateConstraints:@[
        [seg.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [seg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [seg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
    ]];
    [seg addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    seg.selectedSegmentIndex = TRDisguiseSegmentLocation;
    self.segControl = seg;
}

- (void)setupContainer {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:container];
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:self.segControl.bottomAnchor constant:8],
        [container.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [container.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    self.containerView = container;
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    [self switchToSegment:sender.selectedSegmentIndex];
}

- (void)switchToSegment:(TRDisguiseSegment)segment {
    UIViewController *vc = nil;
    switch (segment) {
        case TRDisguiseSegmentLocation:
            if (!self.locationVC) self.locationVC = [[TRMapPickerViewController alloc] init];
            vc = self.locationVC;
            break;
        case TRDisguiseSegmentContacts:
            if (!self.contactsVC) self.contactsVC = [[TRFillDataViewController alloc] initWithKind:@"contacts"];
            vc = self.contactsVC;
            break;
        case TRDisguiseSegmentCalls:
            if (!self.callsVC) self.callsVC = [[TRFillDataViewController alloc] initWithKind:@"calls"];
            vc = self.callsVC;
            break;
        case TRDisguiseSegmentSms:
            if (!self.smsVC) self.smsVC = [[TRFillDataViewController alloc] initWithKind:@"sms"];
            vc = self.smsVC;
            break;
    }
    [self.currentChild willMoveToParentViewController:nil];
    [self.currentChild.view removeFromSuperview];
    [self.currentChild removeFromParentViewController];

    [self addChildViewController:vc];
    vc.view.frame = self.containerView.bounds;
    vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.containerView addSubview:vc.view];
    [vc didMoveToParentViewController:self];
    self.currentChild = vc;
}

@end
