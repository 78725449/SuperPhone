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
#import "TRRegions.h"
#import "BRPickerView/BRTextPickerView.h"

/// 单行比例滑条（组内合计 100% 联动，最后一个自动补足）
@interface TRRatioRow : NSObject
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *value;
@property (nonatomic, assign) NSInteger groupIndex;
@property (nonatomic, assign) NSInteger indexInGroup;
@end
@implementation TRRatioRow
@end

@interface TRFillDataViewController ()
@property (nonatomic, strong) NSMutableArray *rows;          // 全部比例行（TRRatioRow）
@property (nonatomic, strong) NSMutableArray *groupSizes;    // 各组行数（联动用）
@property (nonatomic, strong) UISlider *countSlider;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UISegmentedControl *daysSeg;   // 时间范围（短信/通话）
@property (nonatomic, strong) UISegmentedControl *carrierSeg;// 本人运营商（短信/通话）
@property (nonatomic, strong) UILabel *cityProvinceLabel;    // 常住地区当前值（联系人；BRPickerView 省市选择）
@property (nonatomic, strong) NSString *selectedProvince;    // 选中省（中文）
@property (nonatomic, strong) NSString *selectedCity;        // 选中市（中文，区号表 key）
@property (nonatomic, strong) UISlider *localRatioSlider;    // 本地占比（联系人）
@property (nonatomic, strong) UILabel *localRatioLabel;
@property (nonatomic, strong) UISlider *inRatioSlider;       // 收发比（短信，我发占比，默认 20%）
@property (nonatomic, strong) UILabel *inRatioLabel;
@property (nonatomic, strong) UIButton *seedButton;
@property (nonatomic, strong) UILabel *resultLabel;
@property (nonatomic, strong) UIScrollView *scrollView;
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
        self.rows = [NSMutableArray array];
        self.groupSizes = [NSMutableArray array];
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

#pragma mark - UI 构建

- (void)setupUI {
    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sv.contentInset = UIEdgeInsetsMake(0, 0, 40, 0);
    [self.view addSubview:sv];
    self.scrollView = sv;

    CGFloat y = 20;
    CGFloat margin = 20;
    CGFloat w = self.view.bounds.size.width - margin * 2;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, w, 24)];
    title.text = [NSString stringWithFormat:@"生成%@", [self kindTitle]];
    title.font = [UIFont boldSystemFontOfSize:17];
    [sv addSubview:title];
    y += 36;

    // 通话/短信依赖提示（反差确认前提：联系人内选人依赖通讯录，D2 §3 UI 定稿）
    if ([_kind isEqualToString:@"calls"] || [_kind isEqualToString:@"sms"]) {
        UILabel *dep = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, w, 18)];
        dep.text = @"基于通讯录生成，请先生成通讯录";
        dep.font = [UIFont systemFontOfSize:12];
        dep.textColor = [UIColor secondaryLabelColor];
        [sv addSubview:dep];
        y += 26;
    }

    // 生成数量
    y = [self addRowLabel:@"生成数量" y:y] + 24;
    UISlider *cs = [[UISlider alloc] initWithFrame:CGRectMake(margin, y, w - 70, 30)];
    cs.minimumValue = 1;
    cs.maximumValue = 500;
    cs.value = [self defaultCount];
    [cs addTarget:self action:@selector(countChanged:) forControlEvents:UIControlEventValueChanged];
    [sv addSubview:cs];
    self.countSlider = cs;
    UILabel *cv = [[UILabel alloc] initWithFrame:CGRectMake(w + margin - 66, y + 3, 66, 24)];
    cv.textAlignment = NSTextAlignmentRight;
    cv.font = [UIFont systemFontOfSize:13];
    [sv addSubview:cv];
    self.countLabel = cv;
    y += 34;

    // 联系人专属：常住地区（BRPickerView 省市选择）+ 本地占比
    if ([_kind isEqualToString:@"contacts"]) {
        y = [self addRowLabel:@"常住地区" y:y] + 24;
        UIButton *cityBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        cityBtn.frame = CGRectMake(margin, y, w, 36);
        [cityBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        cityBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        cityBtn.backgroundColor = [UIColor secondarySystemBackgroundColor];
        cityBtn.layer.cornerRadius = 8;
        [cityBtn addTarget:self action:@selector(showRegionPicker) forControlEvents:UIControlEventTouchUpInside];
        [sv addSubview:cityBtn];
        UILabel *cv = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, w - 24, 20)];
        cv.text = @"北京";
        cv.font = [UIFont systemFontOfSize:14];
        [cityBtn addSubview:cv];
        self.cityProvinceLabel = cv;
        self.selectedProvince = @"北京";
        self.selectedCity = @"北京";
        y += 44;

        y = [self addRowLabel:@"本地占比" y:y] + 24;
        UISlider *lr = [[UISlider alloc] initWithFrame:CGRectMake(margin, y, w - 70, 30)];
        lr.minimumValue = 0; lr.maximumValue = 100; lr.value = 65;
        [lr addTarget:self action:@selector(localRatioChanged:) forControlEvents:UIControlEventValueChanged];
        [sv addSubview:lr];
        self.localRatioSlider = lr;
        UILabel *lv = [[UILabel alloc] initWithFrame:CGRectMake(w + margin - 66, y + 3, 66, 24)];
        lv.textAlignment = NSTextAlignmentRight;
        lv.font = [UIFont systemFontOfSize:13];
        [sv addSubview:lv];
        self.localRatioLabel = lv;
        y += 34;
    }

    // 短信/通话专属：时间范围 + 本人运营商
    if ([_kind isEqualToString:@"sms"] || [_kind isEqualToString:@"calls"]) {
        y = [self addRowLabel:@"时间范围" y:y] + 24;
        UISegmentedControl *days = [[UISegmentedControl alloc] initWithItems:@[@"1天", @"3天", @"7天", @"30天"]];
        days.selectedSegmentIndex = 1;
        days.frame = CGRectMake(margin, y, w, 32);
        [sv addSubview:days];
        self.daysSeg = days;
        y += 40;

        y = [self addRowLabel:@"本人运营商" y:y] + 24;
        UISegmentedControl *carrier = [[UISegmentedControl alloc] initWithItems:@[@"移动", @"联通", @"电信"]];
        carrier.selectedSegmentIndex = 0;
        carrier.frame = CGRectMake(margin, y, w, 32);
        [sv addSubview:carrier];
        self.carrierSeg = carrier;
        y += 40;
    }

    // 比例滑条组（合计 100% 联动）
    y = [self addRatioGroupsAtY:y];
    y += 8;

    // 短信专属：收发比（我发占比，默认 20% = 发2收8；仅作用于家人朋友类，设计 §6.1）
    if ([_kind isEqualToString:@"sms"]) {
        y = [self addRowLabel:@"收发比（我发占比）" y:y] + 24;
        UISlider *ir = [[UISlider alloc] initWithFrame:CGRectMake(margin, y, w - 70, 30)];
        ir.minimumValue = 0; ir.maximumValue = 100; ir.value = 20;
        [ir addTarget:self action:@selector(inRatioChanged:) forControlEvents:UIControlEventValueChanged];
        [sv addSubview:ir];
        self.inRatioSlider = ir;
        UILabel *il = [[UILabel alloc] initWithFrame:CGRectMake(w + margin - 66, y + 3, 66, 24)];
        il.textAlignment = NSTextAlignmentRight;
        il.font = [UIFont systemFontOfSize:13];
        [sv addSubview:il];
        self.inRatioLabel = il;
        y += 34;
        [self refreshInRatioLabel];
    }

    // 随机种子
    y = [self addRowLabel:@"随机种子（点击随机）" y:y] + 24;
    UIButton *seedBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    seedBtn.frame = CGRectMake(margin, y, w, 40);
    [seedBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    seedBtn.backgroundColor = [UIColor secondarySystemBackgroundColor];
    seedBtn.layer.cornerRadius = 8;
    [seedBtn addTarget:self action:@selector(randomizeSeed:) forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:seedBtn];
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
    [sv addSubview:gen];
    y += 52;

    // 清空按钮（设计 §7.3：确认弹窗，不可恢复）
    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(margin, y, w, 40);
    [clearBtn setTitle:[NSString stringWithFormat:@"清空全部%@", [self kindTitle]] forState:UIControlStateNormal];
    [clearBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    clearBtn.backgroundColor = [UIColor secondarySystemBackgroundColor];
    clearBtn.layer.cornerRadius = 8;
    [clearBtn addTarget:self action:@selector(clearAll:) forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:clearBtn];
    y += 48;

    UILabel *result = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, w, 60)];
    result.numberOfLines = 3;
    result.font = [UIFont systemFontOfSize:13];
    result.textColor = [UIColor secondaryLabelColor];
    [sv addSubview:result];
    self.resultLabel = result;

    sv.contentSize = CGSizeMake(self.view.bounds.size.width, y + 80);
    [self refreshCountLabel];
    [self refreshLocalRatioLabel];
    [self refreshSeedButton];
}

- (NSInteger)defaultCount {
    if ([_kind isEqualToString:@"contacts"]) return 50;
    if ([_kind isEqualToString:@"sms"]) return 30;
    return 20; // calls
}

- (CGFloat)addRowLabel:(NSString *)text y:(CGFloat)y {
    CGFloat margin = 20;
    CGFloat w = self.view.bounds.size.width - margin * 2;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, w, 20)];
    l.text = text;
    l.font = [UIFont systemFontOfSize:14];
    [self.scrollView addSubview:l];
    return y;
}

/// 渲染比例滑条组（每组合计 100%，最后一个自动补足）
- (CGFloat)addRatioGroupsAtY:(CGFloat)y {
    CGFloat margin = 20;
    CGFloat w = self.view.bounds.size.width - margin * 2;
    NSArray *groups = [self ratioGroups];
    for (NSDictionary *g in groups) {
        // 组标题
        NSString *gTitle = g[@"title"];
        if (gTitle.length) {
            UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, w, 20)];
            t.text = gTitle;
            t.font = [UIFont systemFontOfSize:13];
            t.textColor = [UIColor secondaryLabelColor];
            [self.scrollView addSubview:t];
            y += 24;
        }
        NSArray *items = g[@"items"];
        [self.groupSizes addObject:@(items.count)];
        for (NSUInteger i = 0; i < items.count; i++) {
            NSDictionary *it = items[i];
            CGFloat yy = y + (CGFloat)i * 34;
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(margin, yy, 96, 30)];
            l.text = it[@"label"];
            l.font = [UIFont systemFontOfSize:13];
            [self.scrollView addSubview:l];
            UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(margin + 100, yy, w - 158, 30)];
            s.minimumValue = 0; s.maximumValue = 100; s.value = [it[@"value"] floatValue];
            [s addTarget:self action:@selector(ratioChanged:) forControlEvents:UIControlEventValueChanged];
            [self.scrollView addSubview:s];
            UILabel *vl = [[UILabel alloc] initWithFrame:CGRectMake(margin + 100 + w - 158 + 4, yy, 40, 30)];
            vl.textAlignment = NSTextAlignmentRight;
            vl.font = [UIFont systemFontOfSize:13];
            [self.scrollView addSubview:vl];
            TRRatioRow *row = [[TRRatioRow alloc] init];
            row.label = l; row.slider = s; row.value = vl;
            row.groupIndex = (NSInteger)[self.groupSizes count] - 1;
            row.indexInGroup = (NSInteger)i;
            [self.rows addObject:row];
        }
        y += (CGFloat)items.count * 34;
    }
    // 合计 + 重置默认（对齐原型 .sum + .rst）
    CGFloat sumW = w - 90;
    UILabel *sum = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, sumW, 20)];
    sum.tag = 777;
    sum.font = [UIFont systemFontOfSize:12];
    [self.scrollView addSubview:sum];
    UIButton *rst = [UIButton buttonWithType:UIButtonTypeSystem];
    rst.frame = CGRectMake(margin + sumW + 4, y, 86, 20);
    [rst setTitle:@"重置默认" forState:UIControlStateNormal];
    rst.titleLabel.font = [UIFont systemFontOfSize:12];
    [rst setTitleColor:[UIColor colorWithRed:0.29 green:0.25 blue:0.89 alpha:1.0] forState:UIControlStateNormal];
    [rst addTarget:self action:@selector(resetRatioDefaults) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:rst];
    y += 26;
    [self refreshRatioLabels];
    return y;
}

/// 重置比例滑条为默认（对齐原型 .rst 重置默认）
- (void)resetRatioDefaults {
    NSArray *groups = [self ratioGroups];
    NSInteger gi = 0;
    for (NSDictionary *g in groups) {
        NSArray *items = g[@"items"];
        NSArray *gr = [self rowsInGroup:gi];
        for (NSUInteger i = 0; i < items.count && i < gr.count; i++) {
            [(TRRatioRow *)gr[i] slider].value = [items[i][@"value"] floatValue];
        }
        gi++;
    }
    if (self.localRatioSlider) self.localRatioSlider.value = 65;
    if (self.inRatioSlider) self.inRatioSlider.value = 20;
    [self refreshRatioLabels];
    [self refreshInRatioLabel];
    self.resultLabel.text = @"";
}

/// 各组比例定义（默认值对齐原型）
- (NSArray *)ratioGroups {
    if ([_kind isEqualToString:@"contacts"]) {
        return @[
            @{@"title": @"关系构成", @"items": @[
                @{@"label": @"朋友/熟人", @"value": @55},
                @{@"label": @"工作/商务", @"value": @20},
                @{@"label": @"生活服务", @"value": @12},
                @{@"label": @"家人亲戚", @"value": @8},
                @{@"label": @"机构商家", @"value": @5},
            ]},
        ];
    }
    if ([_kind isEqualToString:@"sms"]) {
        return @[
            @{@"title": @"类型构成", @"items": @[
                @{@"label": @"验证码", @"value": @35},
                @{@"label": @"快递", @"value": @20},
                @{@"label": @"银行/金融", @"value": @15},
                @{@"label": @"运营商", @"value": @10},
                @{@"label": @"营销/推广", @"value": @10},
                @{@"label": @"家人/朋友", @"value": @10},
            ]},
        ];
    }
    // calls
    return @[
        @{@"title": @"选人构成", @"items": @[
            @{@"label": @"联系人内", @"value": @70},
            @{@"label": @"陌生号", @"value": @30},
        ]},
        @{@"title": @"状态构成", @"items": @[
            @{@"label": @"呼入", @"value": @40},
            @{@"label": @"呼出", @"value": @40},
            @{@"label": @"未接", @"value": @20},
        ]},
    ];
}

#pragma mark - 联动与刷新

- (void)ratioChanged:(UISlider *)sender {
    // 找到所在组，把同组最后一个滑条设为 100 - 其余和（≥0 时）；若其余和 >100 钳制当前值
    for (TRRatioRow *row in self.rows) {
        if (row.slider == sender) {
            NSInteger gi = row.groupIndex;
            NSArray *groupRows = [self rowsInGroup:gi];
            NSInteger lastIdx = (NSInteger)groupRows.count - 1;
            float otherSum = 0;
            for (NSInteger i = 0; i < lastIdx; i++) {
                TRRatioRow *r = groupRows[i];
                if (r == row) otherSum += row.slider.value; else otherSum += r.slider.value;
            }
            if (otherSum > 100) {
                row.slider.value = 100 - (otherSum - row.slider.value);
            }
            TRRatioRow *last = groupRows[lastIdx];
            if (last != row) {
                last.slider.value = MAX(0, 100 - otherSum);
            }
            [self refreshRatioLabels];
            return;
        }
    }
}

- (NSArray *)rowsInGroup:(NSInteger)gi {
    NSMutableArray *arr = [NSMutableArray array];
    for (TRRatioRow *row in self.rows) if (row.groupIndex == gi) [arr addObject:row];
    return arr;
}

- (void)refreshRatioLabels {
    for (TRRatioRow *row in self.rows) {
        row.value.text = [NSString stringWithFormat:@"%ld%%", (long)(NSInteger)row.slider.value];
    }
    // 合计标签（tag 777）
    for (UIView *v in self.scrollView.subviews) {
        if (v.tag == 777 && [v isKindOfClass:[UILabel class]]) {
            NSMutableString *txt = [NSMutableString string];
            for (NSInteger gi = 0; gi < (NSInteger)self.groupSizes.count; gi++) {
                NSArray *gr = [self rowsInGroup:gi];
                NSInteger sum = 0;
                for (TRRatioRow *r in gr) sum += (NSInteger)r.slider.value;
                if (gi > 0) [txt appendString:@" · "];
                [txt appendFormat:@"组%ld %ld%%", (long)(gi + 1), (long)sum];
            }
            [txt appendString:@" ✓"];
            ((UILabel *)v).text = [NSString stringWithFormat:@"合计 %@", txt];
            ((UILabel *)v).textColor = [UIColor systemGreenColor];
        }
    }
}

- (void)countChanged:(UISlider *)sender { [self refreshCountLabel]; }
- (void)localRatioChanged:(UISlider *)sender { [self refreshLocalRatioLabel]; }

- (void)refreshCountLabel {
    self.countLabel.text = [NSString stringWithFormat:@"%ld 条", (long)(NSInteger)self.countSlider.value];
}
- (void)refreshLocalRatioLabel {
    self.localRatioLabel.text = [NSString stringWithFormat:@"%ld%%", (long)(NSInteger)self.localRatioSlider.value];
}

- (void)randomizeSeed:(UIButton *)sender {
    self.seed = (uint64_t)[[NSDate date] timeIntervalSince1970] ^ (uint64_t)(arc4random());
    [self refreshSeedButton];
    self.resultLabel.text = @"";
}

- (void)refreshSeedButton {
    [self.seedButton setTitle:[NSString stringWithFormat:@"%llu", self.seed] forState:UIControlStateNormal];
}

#pragma mark - 省市选择器 / 收发比 / 清空

/// 常住地区：BRPickerView 省市两列级联（数据源 = 构建产物 kRegions，民政部）
- (void)showRegionPicker {
    BRTextPickerView *picker = [[BRTextPickerView alloc] initWithPickerMode:BRTextPickerComponentCascade];
    picker.dataSourceArr = [NSArray br_modelArrayWithJson:kRegions() mapper:nil];
    picker.title = @"选择常住地区";
    if (self.selectedProvince && self.selectedCity) {
        picker.selectIndexs = @[[self provinceIndex], [self cityIndex]];
    }
    __weak typeof(self) ws = self;
    picker.resultBlock = ^(NSArray *models, NSArray *indexs) {
        __strong typeof(ws) ss = ws;
        if (models.count >= 2) {
            BRTextModel *p = models[0];
            BRTextModel *c = models[1];
            ss.selectedProvince = p.text;
            ss.selectedCity = c.text;
            ss.cityProvinceLabel.text = [NSString stringWithFormat:@"%@ · %@", p.text, c.text];
        }
    };
    [picker show];
}

- (NSNumber *)provinceIndex {
    NSArray *regions = kRegions();
    for (NSUInteger i = 0; i < regions.count; i++) {
        if ([[regions[i] valueForKey:@"text"] isEqualToString:self.selectedProvince]) return @(i);
    }
    return @(0);
}
- (NSNumber *)cityIndex {
    for (NSDictionary *p in kRegions()) {
        if ([[p valueForKey:@"text"] isEqualToString:self.selectedProvince]) {
            NSArray *cities = [p valueForKey:@"children"];
            for (NSUInteger i = 0; i < cities.count; i++) {
                if ([[cities[i] valueForKey:@"text"] isEqualToString:self.selectedCity]) return @(i);
            }
            break;
        }
    }
    return @(0);
}

- (void)inRatioChanged:(UISlider *)sender { [self refreshInRatioLabel]; self.resultLabel.text = @""; }
- (void)refreshInRatioLabel {
    if (self.inRatioLabel) self.inRatioLabel.text = [NSString stringWithFormat:@"%ld%%", (long)(NSInteger)self.inRatioSlider.value];
}

/// 清空本 Tab 数据（设计 §7.3：确认弹窗，不可恢复）
- (void)clearAll:(UIButton *)sender {
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"确认清空"
        message:[NSString stringWithFormat:@"将清空全部%@，不可恢复", [self kindTitle]]
        preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [al addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *res = [TRDataFiller clearDatabase:_kind];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.resultLabel.text = [res[@"ok"] boolValue]
                    ? [NSString stringWithFormat:@"已清空 %@ 条%@", res[@"cleared"], [self kindTitle]]
                    : [NSString stringWithFormat:@"清空失败：%@", res[@"error"] ?: @"未知错误"];
            });
        });
    }]];
    [self presentViewController:al animated:YES completion:nil];
}

#pragma mark - 生成

/// 汇总各比例组为 ratios 字典（键名对齐 TRDataFiller 契约，设计 §3）
- (NSDictionary *)collectRatios {
    NSMutableDictionary *ratios = [NSMutableDictionary dictionary];
    if ([_kind isEqualToString:@"contacts"]) {
        NSArray *keys = @[@"friend", @"work", @"service", @"family", @"business"];
        NSArray *gr = [self rowsInGroup:0];
        for (NSUInteger i = 0; i < keys.count && i < gr.count; i++) {
            ratios[keys[i]] = @([(TRRatioRow *)gr[i] slider].value / 100.0);
        }
        if (self.localRatioSlider) ratios[@"regionLocal"] = @(self.localRatioSlider.value / 100.0);
        if (self.selectedCity) {
            ratios[@"city"] = self.selectedCity;     // 中文城市名（区号表 key）
            ratios[@"province"] = self.selectedProvince ?: @"";
        }
    } else if ([_kind isEqualToString:@"sms"]) {
        NSArray *keys = @[@"code", @"express", @"bank", @"carrierSms", @"marketing", @"family"];
        NSArray *gr = [self rowsInGroup:0];
        for (NSUInteger i = 0; i < keys.count && i < gr.count; i++) {
            ratios[keys[i]] = @([(TRRatioRow *)gr[i] slider].value / 100.0);
        }
        if (self.inRatioSlider) ratios[@"inRatio"] = @(self.inRatioSlider.value / 100.0);
        ratios[@"days"] = @[@1, @3, @7, @30][self.daysSeg.selectedSegmentIndex];
        ratios[@"carrier"] = @[@"cmcc", @"cucc", @"ctcc"][self.carrierSeg.selectedSegmentIndex];
    } else { // calls
        NSArray *g0 = [self rowsInGroup:0];
        double contact = [(TRRatioRow *)g0[0] slider].value / 100.0;
        ratios[@"contact"] = @(contact);
        ratios[@"stranger"] = @(1.0 - contact);
        NSArray *statusKeys = @[@"incoming", @"outgoing", @"missed"];
        NSArray *g1 = [self rowsInGroup:1];
        for (NSUInteger i = 0; i < statusKeys.count && i < g1.count; i++) {
            ratios[statusKeys[i]] = @([(TRRatioRow *)g1[i] slider].value / 100.0);
        }
        ratios[@"days"] = @[@1, @3, @7, @30][self.daysSeg.selectedSegmentIndex];
        ratios[@"carrier"] = @[@"cmcc", @"cucc", @"ctcc"][self.carrierSeg.selectedSegmentIndex];
    }
    return ratios;
}

- (void)generate:(UIButton *)sender {
    NSInteger count = (NSInteger)self.countSlider.value;
    NSDictionary *ratios = [self collectRatios];
    NSDictionary *req = [TRFillDataGenerator requestForKind:_kind count:count seed:self.seed ratios:ratios];
    self.resultLabel.text = @"生成中…";
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
