//
//  TRDailyTrajectory.mm
//  每日轨迹（2026-08-26）：真人行为模拟——manager daemon 自治调度（root 常驻）。
//  · 每日：随机目标 通话 3-10 / 短信 5-15 / 未接 0-2，跨天重置
//  · 每周：随机新增联系人 1-5（city 取 App 常住地区，mobile plist 读取）
//  · 每小时 tick（GCD 后台队列），昼夜权重决定是否补生成（8-21 时活跃、深夜几乎不）
//  · 数据操作走 TRDataFiller（与 App 伪装页同源），不暴露任何外部入口；默认开启
//  计数/目标持久化：NSUserDefaults suite com.82flex.trollvnc（root 域，daemon 自持）
//

#import "TRDailyTrajectory.h"
#import "TRDataFiller.h"
#import "TRAppDomain.h" // kTRAppPrefsSuiteName（跨端 prefs 域契约，2026-08-28）

@implementation TRDailyTrajectory

// 昼夜权重（与 Node calls-gen CIRCADIAN_WEIGHTS 同构）：[起始时, 结束时, 权重]
static const struct { int from, to; double w; } kCircadian[] = {
    {0, 6, 0.05}, {6, 8, 0.30}, {8, 9, 0.70}, {9, 12, 0.90}, {12, 14, 0.80},
    {14, 18, 0.95}, {18, 21, 1.00}, {21, 23, 0.70}, {23, 24, 0.30},
};

static const NSTimeInterval kTickInterval = 3600.0; // 每小时

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [self scheduleNextTick];
        [self tick]; // 启动立即首检（装包重启即可能按当天缺口补生成）
    });
}

+ (void)scheduleNextTick {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTickInterval * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        [self tick];
        [self scheduleNextTick];
    });
}

// 读取 App 设置的常住地区（App 伪装页 NSUserDefaults 长效化写入 → mobile 域 plist）
static NSString *mobileCity(void) {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.82flex.trollvnc.plist"];
    id v = plist[@"TRFillResidentCity"];
    if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    id p = plist[@"TRFillResidentProvince"];
    return [p isKindOfClass:[NSString class]] && [p length] ? p : nil;
}

// 当前小时昼夜权重（命中区间返回权重，未命中回退 0.3）
static double hourWeight(NSCalendar *cal, NSDate *now) {
    NSInteger hour = [cal component:NSCalendarUnitHour fromDate:now];
    for (NSUInteger i = 0; i < sizeof(kCircadian) / sizeof(kCircadian[0]); i++) {
        if (hour >= kCircadian[i].from && hour < kCircadian[i].to) return kCircadian[i].w;
    }
    return 0.3;
}

+ (void)tick {
    @autoreleasepool {
        NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDate *now = [NSDate date];

        // ---- 跨天重置每日目标 ----
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd";
        NSString *today = [fmt stringFromDate:now];
        if (![[ud stringForKey:@"TRDailyLastDate"] isEqualToString:today]) {
            [ud setObject:today forKey:@"TRDailyLastDate"];
            [ud setInteger:3 + arc4random_uniform(8) forKey:@"TRDailyCallsTarget"];    // 3-10
            [ud setInteger:5 + arc4random_uniform(11) forKey:@"TRDailySmsTarget"];      // 5-15
            [ud setInteger:arc4random_uniform(3) forKey:@"TRDailyMissedTarget"];        // 0-2
            [ud setInteger:0 forKey:@"TRDailyCallsDone"];
            [ud setInteger:0 forKey:@"TRDailySmsDone"];
            [ud setInteger:0 forKey:@"TRDailyMissedDone"];
            [ud synchronize];
        }

        // ---- 跨周重置每周联系人目标 ----
        NSInteger week = [cal component:NSCalendarUnitWeekOfYear fromDate:now];
        NSInteger year = [cal component:NSCalendarUnitYear fromDate:now];
        if ([ud integerForKey:@"TRDailyWeekYear"] != year || [ud integerForKey:@"TRDailyWeekNo"] != week) {
            [ud setInteger:year forKey:@"TRDailyWeekYear"];
            [ud setInteger:week forKey:@"TRDailyWeekNo"];
            [ud setInteger:1 + arc4random_uniform(5) forKey:@"TRDailyContactsTarget"];  // 1-5
            [ud setInteger:0 forKey:@"TRDailyContactsDone"];
            [ud synchronize];
        }

        NSInteger callsT = [ud integerForKey:@"TRDailyCallsTarget"];
        NSInteger smsT = [ud integerForKey:@"TRDailySmsTarget"];
        NSInteger missedT = [ud integerForKey:@"TRDailyMissedTarget"];
        NSInteger ctT = [ud integerForKey:@"TRDailyContactsTarget"];
        NSInteger callsD = [ud integerForKey:@"TRDailyCallsDone"];
        NSInteger smsD = [ud integerForKey:@"TRDailySmsDone"];
        NSInteger missedD = [ud integerForKey:@"TRDailyMissedDone"];
        NSInteger ctD = [ud integerForKey:@"TRDailyContactsDone"];

        // ---- 昼夜权重决定本小时是否补生成（峰值 1.0 必试、凌晨 5% 几乎不） ----
        double w = hourWeight(cal, now);
        if ((arc4random() % 1000) >= (unsigned)(w * 1000)) return;

        // ---- 未接来电（每日 0-2，独立于正常通话；陌生号） ----
        if (missedD < missedT) {
            NSInteger batch = (NSInteger)MIN(1, missedT - missedD);
            NSDictionary *res = [TRDataFiller fillDatabase:@"calls" count:batch seed:0
                ratios:@{@"days": @1, @"missed": @1.0, @"contact": @0.0, @"stranger": @1.0}];
            if ([res[@"ok"] boolValue]) {
                [ud setInteger:missedD + batch forKey:@"TRDailyMissedDone"];
                [ud synchronize];
            }
            // 通讯录为空等失败：跳过本次，下小时重试
        }

        // ---- 通话（正常通话：呼入/呼出混合，接通） ----
        if (callsD < callsT) {
            NSInteger batch = MIN(callsT - callsD, 1 + arc4random_uniform(2)); // 1-2 条/小时
            NSDictionary *res = [TRDataFiller fillDatabase:@"calls" count:batch seed:0
                ratios:@{@"days": @1, @"incoming": @0.5, @"outgoing": @0.5, @"missed": @0.0}];
            if ([res[@"ok"] boolValue]) {
                [ud setInteger:callsD + batch forKey:@"TRDailyCallsDone"];
                [ud synchronize];
            }
        }

        // ---- 短信（家人+服务混合；family 依赖通讯录） ----
        if (smsD < smsT) {
            NSInteger batch = MIN(smsT - smsD, 1 + arc4random_uniform(3)); // 1-3 条/小时
            NSDictionary *res = [TRDataFiller fillDatabase:@"sms" count:batch seed:0 ratios:@{@"days": @1}];
            if ([res[@"ok"] boolValue]) {
                [ud setInteger:smsD + batch forKey:@"TRDailySmsDone"];
                [ud synchronize];
            }
        }

        // ---- 新增联系人（每周 1-5；city 取 App 常住地区，无则北京回退） ----
        if (ctD < ctT) {
            NSInteger batch = MIN(ctT - ctD, 1); // 每小时最多 1 个新联系人（稀疏感）
            NSString *region = mobileCity();
            NSMutableDictionary *ratios = [@{@"regionLocal": @0.65, @"days": @1} mutableCopy];
            if (region.length) ratios[@"city"] = region;
            NSDictionary *res = [TRDataFiller fillDatabase:@"contacts" count:batch seed:0 ratios:ratios];
            if ([res[@"ok"] boolValue]) {
                [ud setInteger:ctD + batch forKey:@"TRDailyContactsDone"];
                [ud synchronize];
            }
        }
    }
}

@end
