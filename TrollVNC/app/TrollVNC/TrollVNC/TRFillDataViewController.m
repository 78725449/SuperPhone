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

#import "TRFillDataViewController.h"
#import "TRFillDataGenerator.h"
#import "TRDataFiller.h"

@interface TRFillDataViewController ()
@property (nonatomic, strong) UISlider *countSlider;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UISlider *ratioSlider;   // calls=拨出比 / sms=收到比（contacts 无）
@property (nonatomic, strong) UILabel *ratioLabel;
@property (nonatomic, strong) UIButton *seedButton;    // 数字种子（点击随机）
@property (nonatomic, strong) UILabel *resultLabel;    // 生成反馈（按钮下方）
@property (nonatomic, assign) uint64_t seed;
@end

@implementation TRFillDataViewController {
    NSString *_kind;
}

- (instancetype)initWithKind:(NSString *)kind {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _kind = [kind copy];
        _seed = (uint64_t)[[NSDate date] timeIntervalSince1970];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self setupUI];
}

- (NSString *)kindTitle {
    if ([_kind isEqualToString:@"contacts"]) return @"联系人";
    if ([_kind isEqualToString:@"calls"]) return @"通话记录";
    if ([_kind isEqualToString:@"sms"]) return @"短信";
    return _kind;
}

- (void)setupUI {
    CGFloat y = 20;
    CGFloat margin = 20;
    CGFloat w = self.view.bounds.size.width - margin * 2;

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, w, 24)];
    title.text = [NSString stringWithFormat:@"生成%@", [self kindTitle]];
    title.font = [UIFont boldSystemFontOfSize:17];
    [self.view addSubview:title];
    y += 36;

    // 数量
    UILabel *countTitle = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, w, 20)];
    countTitle.text = @"数量";
    countTitle.font = [UIFont systemFontOfSize:14];
    [self.view addSubview:countTitle];
    y += 24;

    UISlider *cs = [[UISlider alloc] initWithFrame:CGRectMake(margin, y, w - 70, 30)];
    cs.minimumValue = 10;
    cs.maximumValue = 500;
    cs.value = 50;
    [cs addTarget:self action:@selector(countChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:cs];
    self.countSlider = cs;

    UILabel *cv = [[UILabel alloc] initWithFrame:CGRectMake(w + margin - 66, y + 3, 66, 24)];
    cv.text = @"50 条";
    cv.textAlignment = NSTextAlignmentRight;
    cv.font = [UIFont systemFontOfSize:13];
    [self.view addSubview:cv];
    self.countLabel = cv;
    y += 34;

    // 比例（calls=拨出比 / sms=收到比；contacts 无）
    if (![_kind isEqualToString:@"contacts"]) {
        NSString *ratioTitle = [_kind isEqualToString:@"calls"] ? @"拨出比（其余为拨入）" : @"收到比（其余为发出）";
        UILabel *rt = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, w, 20)];
        rt.text = ratioTitle;
        rt.font = [UIFont systemFontOfSize:14];
        [self.view addSubview:rt];
        y += 24;

        UISlider *rs = [[UISlider alloc] initWithFrame:CGRectMake(margin, y, w - 70, 30)];
        rs.minimumValue = 0;
        rs.maximumValue = 100;
        rs.value = 50;
        [rs addTarget:self action:@selector(ratioChanged:) forControlEvents:UIControlEventValueChanged];
        [self.view addSubview:rs];
        self.ratioSlider = rs;

        UILabel *rv = [[UILabel alloc] initWithFrame:CGRectMake(w + margin - 66, y + 3, 66, 24)];
        rv.text = @"50%";
        rv.textAlignment = NSTextAlignmentRight;
        rv.font = [UIFont systemFontOfSize:13];
        [self.view addSubview:rv];
        self.ratioLabel = rv;
        y += 34;
    }

    // 数字种子（点击随机）
    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, w, 20)];
    st.text = @"数字种子（点击随机）";
    st.font = [UIFont systemFontOfSize:14];
    [self.view addSubview:st];
    y += 24;

    UIButton *seedBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    seedBtn.frame = CGRectMake(margin, y, w, 40);
    [seedBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    seedBtn.backgroundColor = [UIColor secondarySystemBackgroundColor];
    seedBtn.layer.cornerRadius = 8;
    [seedBtn addTarget:self action:@selector(randomizeSeed:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:seedBtn];
    self.seedButton = seedBtn;
    y += 48;

    // 生成按钮
    UIButton *gen = [UIButton buttonWithType:UIButtonTypeSystem];
    gen.frame = CGRectMake(margin, y, w, 44);
    [gen setTitle:@"生成" forState:UIControlStateNormal];
    gen.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    gen.backgroundColor = [UIColor systemBlueColor];
    [gen setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    gen.layer.cornerRadius = 10;
    [gen addTarget:self action:@selector(generate:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:gen];
    y += 52;

    // 结果反馈（按钮下方）
    UILabel *result = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, w, 60)];
    result.numberOfLines = 3;
    result.font = [UIFont systemFontOfSize:13];
    result.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:result];
    self.resultLabel = result;

    [self refreshCountLabel];
    [self refreshRatioLabel];
    [self refreshSeedButton];
}

- (void)countChanged:(UISlider *)sender {
    [self refreshCountLabel];
}

- (void)ratioChanged:(UISlider *)sender {
    [self refreshRatioLabel];
}

- (void)refreshCountLabel {
    self.countLabel.text = [NSString stringWithFormat:@"%ld 条", (long)(NSInteger)self.countSlider.value];
}

- (void)refreshRatioLabel {
    self.ratioLabel.text = [NSString stringWithFormat:@"%ld%%", (long)(NSInteger)self.ratioSlider.value];
}

- (void)randomizeSeed:(UIButton *)sender {
    self.seed = (uint64_t)[[NSDate date] timeIntervalSince1970] ^ (uint64_t)(arc4random());
    [self refreshSeedButton];
    self.resultLabel.text = @"";
}

- (void)refreshSeedButton {
    [self.seedButton setTitle:[NSString stringWithFormat:@"%llu", self.seed] forState:UIControlStateNormal];
}

/// 生成：组装参数 → TRDataFiller（App 进程内直接执行写库 + kill daemon）
- (void)generate:(UIButton *)sender {
    NSInteger count = (NSInteger)self.countSlider.value;
    NSDictionary *ratios = nil;
    if ([_kind isEqualToString:@"calls"]) {
        ratios = @{ @"outgoing": @(self.ratioSlider.value / 100.0) };
    } else if ([_kind isEqualToString:@"sms"]) {
        ratios = @{ @"incoming": @(self.ratioSlider.value / 100.0) };
    }
    NSDictionary *req = [TRFillDataGenerator requestForKind:_kind count:count seed:self.seed ratios:ratios];
    self.resultLabel.text = @"生成中…";
    // 同步执行（写库 + kill daemon 较快）；放后台避免大 count 卡 UI
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *res = [TRDataFiller fillDatabase:req[@"db"]
                                                 count:[req[@"count"] integerValue]
                                                  seed:[req[@"seed"] unsignedLongLongValue]
                                                ratios:req[@"ratios"]];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([res[@"ok"] boolValue]) {
                self.resultLabel.text = [NSString stringWithFormat:@"已生成 %@ %@ 条，刷新 %@ 生效",
                                         [self kindTitle], res[@"count"] ?: @(count), res[@"kill"] ?: @"daemon"];
            } else {
                self.resultLabel.text = [NSString stringWithFormat:@"生成失败：%@", res[@"error"] ?: @"未知错误"];
            }
        });
    });
}

@end
