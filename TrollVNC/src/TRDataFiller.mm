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

#import "TRDataFiller.h"

#import "TRCorpus.h"   // 语料构建产物（corpus.js → ObjC 常量；勿手改）
#import "TRAreaCodes.h" // 区号构建产物（数据源 → 静态表；勿手改）
#import "TRHlr.h" // 号段归属地构建产物（phone2region → 静态区间表；勿手改）

#import <sqlite3.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <signal.h>
#import <Contacts/Contacts.h>

#pragma mark - 确定性随机（seed 驱动 xorshift64，同 seed 可复现；与 Node rng.js 同构）

static uint64_t sSeed = 0x9E3779B97F4A7C15ULL;
static void trSeed(uint64_t s) {
    sSeed = s ? s : (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
}
static uint64_t trRand(void) {
    uint64_t x = sSeed;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    sSeed = x;
    return x;
}
static double trRand01(void) { return (double)(trRand() % 1000000) / 1000000.0; }
static NSInteger trRandInt(NSInteger lo, NSInteger hi) {
    if (hi <= lo) return lo;
    return lo + (NSInteger)(trRand01() * (double)(hi - lo + 1));
}

#pragma mark - 角色（词池在 TRCorpus，生成能识别的必能反查）

typedef NS_ENUM(NSInteger, TRContactRole) { TRRoleFriend = 0, TRRoleWork, TRRoleService, TRRoleFamily, TRRoleBusiness };

static TRContactRole trMatchRole(NSString *displayName) {
    if (displayName.length == 0) return TRRoleFriend;
    for (NSString *w in kFamilyWords()) if ([displayName isEqualToString:w]) return TRRoleFamily;
    for (NSString *w in kServiceWords()) if ([displayName rangeOfString:w].location != NSNotFound) return TRRoleService;
    for (NSString *w in kBusinessWords()) if ([displayName rangeOfString:w].location != NSNotFound) return TRRoleBusiness;
    if ([displayName rangeOfString:@"-"].location != NSNotFound) return TRRoleWork;
    for (NSString *w in kWorkWords()) if ([displayName rangeOfString:w].location != NSNotFound) return TRRoleWork;
    return TRRoleFriend;
}

// 备注名生成（互斥约束：work 必带 -、family 纯称谓、service 职业+姓、business 机构名；D1 §2.4）
static NSString *trGenerateRemark(TRContactRole role, NSString *familyName, NSString *givenName) {
    switch (role) {
        case TRRoleFamily: return kFamilyWords()[trRandInt(0, (NSInteger)kFamilyWords().count - 1)];
        case TRRoleService: return [kServiceWords()[trRandInt(0, (NSInteger)kServiceWords().count - 1)] stringByAppendingString:familyName];
        case TRRoleBusiness: return [kBusinessWords()[trRandInt(0, (NSInteger)kBusinessWords().count - 1)] stringByAppendingString:@"客服"];
        case TRRoleWork: return [NSString stringWithFormat:@"%@%@-%@", familyName, givenName, kWorkWords()[trRandInt(0, (NSInteger)kWorkWords().count - 1)]];
        default: return [familyName stringByAppendingString:givenName];
    }
}

#pragma mark - 号码（完整号段池 kPhoneSegments + 归属地 TRHlr 构建产物；固话 0+区号+8 位，区号 TRAreaCodes）

static NSString *trRandomPhone(void) {
    NSString *seg = kPhoneSegments()[trRandInt(0, (NSInteger)kPhoneSegments().count - 1)];
    return [NSString stringWithFormat:@"%@%ld", seg, (long)trRandInt(10000000, 99999999)]; // 3 位号段 + 8 位尾号
}
// 本地归属手机号：常住城市 HLR 前缀（7 位）+ 4 位尾号；城市无数据回退 NULL（调用方回退全国随机）
static NSString *trRandomLocalPhone(NSString *city) {
    uint32_t prefix = trHlrRandomPrefix(city);
    if (!prefix) return nil;
    return [NSString stringWithFormat:@"%u%04u", prefix, (unsigned)trRandInt(0, 9999)];
}
static NSString *trRandomLandline(NSString *areaCode) {
    return [NSString stringWithFormat:@"0%@%ld%ld%ld%ld%ld%ld%ld%ld", areaCode,
            (long)trRandInt(2, 9), (long)trRandInt(0, 9), (long)trRandInt(0, 9), (long)trRandInt(0, 9),
            (long)trRandInt(0, 9), (long)trRandInt(0, 9), (long)trRandInt(0, 9), (long)trRandInt(0, 9)];
}

#pragma mark - sqlite 辅助（calls/sms 直写；contacts 走 CNContactStore）

static sqlite3_int64 trDbScalar(sqlite3 *db, NSString *sql) {
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) return 0;
    sqlite3_int64 v = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW) v = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);
    return v;
}
static BOOL trDbExec(sqlite3 *db, NSString *sql, NSString **err) {
    char *emsg = NULL;
    if (sqlite3_exec(db, sql.UTF8String, NULL, NULL, &emsg) != SQLITE_OK) {
        if (err) *err = emsg ? [NSString stringWithUTF8String:emsg] : @"sqlite error";
        if (emsg) sqlite3_free(emsg);
        return NO;
    }
    return YES;
}

/** 查询多行（data.read 用，移植自 trollvncserver tvDbQueryRows）；INTEGER/FLOAT→number，TEXT→string，
 *  BLOB→base64，NULL→NSNull；失败返回空数组并填 outErr（NSDictionary @{@"error":...}） */
static NSArray *trDbQueryRows(sqlite3 *db, NSString *sql, NSDictionary **outErr) {
    NSMutableArray *rows = [NSMutableArray array];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
        if (outErr) *outErr = @{@"error": [NSString stringWithUTF8String:sqlite3_errmsg(db) ?: "unknown"]};
        return rows;
    }
    int ncol = sqlite3_column_count(stmt);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        for (int i = 0; i < ncol; i++) {
            const char *cname = sqlite3_column_name(stmt, i);
            NSString *k = cname ? [NSString stringWithUTF8String:cname] : [NSString stringWithFormat:@"c%d", i];
            int t = sqlite3_column_type(stmt, i);
            if (t == SQLITE_INTEGER) row[k] = @(sqlite3_column_int64(stmt, i));
            else if (t == SQLITE_FLOAT) row[k] = @(sqlite3_column_double(stmt, i));
            else if (t == SQLITE_TEXT) {
                const char *tx = (const char *)sqlite3_column_text(stmt, i);
                row[k] = tx ? [NSString stringWithUTF8String:tx] : @"";
            } else if (t == SQLITE_BLOB) {
                const void *blob = sqlite3_column_blob(stmt, i);
                int len = sqlite3_column_bytes(stmt, i);
                row[k] = [[NSData dataWithBytes:blob length:(NSUInteger)len] base64EncodedStringWithOptions:0];
            } else {
                row[k] = [NSNull null];
            }
        }
        [rows addObject:row];
    }
    sqlite3_finalize(stmt);
    return rows;
}

// 触发器函数 stub（2026-08-25）：iOS sms.db message 表带系统触发器（FTS/未读计数），触发器调用系统
// sqlite 连接注册的自定义函数（老版 read() 等），直连缺失 → DELETE 报 no such function → 残留/数字虚高。
// 注册返回 0 的无副作用 stub，触发器结构原样保留，自适应任意 iOS 版本（不硬编码函数名）。
static void trTriggerStub(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc; (void)argv;
    sqlite3_result_int(ctx, 0);
}
static void trRegisterTriggerFuncs(sqlite3 *db) {
    const char *sql = "SELECT sql FROM sqlite_master WHERE type='trigger' AND tbl_name='message'";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) return;
    static NSSet *kSkip = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kSkip = [NSSet setWithArray:@[@"SELECT",@"FROM",@"WHERE",@"WHEN",@"BEGIN",@"END",@"UPDATE",@"INSERT",@"DELETE",@"IF",@"CASE",@"CAST",@"ABS",@"MIN",@"MAX",@"COUNT",@"SUM",@"LENGTH",@"SUBSTR",@"IFNULL",@"COALESCE",@"NULLIF",@"UPPER",@"LOWER",@"TRIM",@"ROUND",@"OLD",@"NEW",@"ROWID",@"AND",@"OR",@"NOT",@"NULL",@"IS",@"IN",@"EXISTS",@"LIKE",@"GLOB",@"BETWEEN",@"INTO",@"VALUES",@"PRAGMA",@"RAISE",@"TYPEOF",@"CHAR",@"PRINTF",@"QUOTE",@"REPLACE",@"INSTR",@"LAST_INSERT_ROWID",@"CHANGES",@"TOTAL_CHANGES",@"RANDOM",@"RANDOMBLOB",@"ZEROBLOB",@"SOUNDEX",@"UNICODE",@"HEX",@"LIKELIHOOD",@"LIKELY",@"UNLIKELY",@"IIF",@"DATETIME",@"DATE",@"TIME",@"STRFTIME",@"JULIANDAY",@"UNIXEPOCH"]];
    });
    NSMutableSet *funcs = [NSMutableSet set];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"([a-zA-Z_][a-zA-Z0-9_]*)\\s*\\(" options:0 error:nil];
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *txt = sqlite3_column_text(stmt, 0);
        if (!txt) continue;
        NSString *s = [NSString stringWithUTF8String:(const char *)txt];
        [re enumerateMatchesInString:s options:0 range:NSMakeRange(0, s.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
            NSString *fn = [s substringWithRange:[m rangeAtIndex:1]];
            if ([kSkip containsObject:fn.uppercaseString]) return;
            [funcs addObject:fn];
        }];
    }
    sqlite3_finalize(stmt);
    // 注册前查 pragma_function_list 是否已存在同名函数（内建/系统注册），存在则跳过——防 stub 覆盖内建变参函数（如时间函数族）
    sqlite3_stmt *fs = NULL;
    BOOL hasPragma = (sqlite3_prepare_v2(db, "SELECT name FROM pragma_function_list", -1, &fs, NULL) == SQLITE_OK);
    for (NSString *fn in funcs) {
        if (hasPragma) {
            BOOL exists = NO;
            while (sqlite3_step(fs) == SQLITE_ROW) {
                const unsigned char *n = sqlite3_column_text(fs, 0);
                if (n && strcasecmp((const char *)n, fn.UTF8String) == 0) { exists = YES; break; }
            }
            sqlite3_reset(fs);
            if (exists) continue;
        }
        sqlite3_create_function(db, fn.UTF8String, -1, SQLITE_UTF8, NULL, trTriggerStub, NULL, NULL);
    }
    if (fs) sqlite3_finalize(fs);
}

#pragma mark - kill daemon（sysctl 枚举 + POSIX kill；同 uid 可杀，launchd 自动拉起）

static pid_t trFindPidByName(const char *name) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0) return 0;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(len);
    if (!procs) return 0;
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) { free(procs); return 0; }
    int n = (int)(len / sizeof(struct kinfo_proc));
    pid_t found = 0;
    for (int i = 0; i < n; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, name) == 0) { found = procs[i].kp_proc.p_pid; break; }
    }
    free(procs);
    return found;
}
static NSString *trKillDaemon(NSString *procName) {
    pid_t pid = trFindPidByName(procName.UTF8String);
    if (!pid) return [NSString stringWithFormat:@"未找到进程 %@", procName];
    if (kill(pid, SIGKILL) != 0)
        return [NSString stringWithFormat:@"kill %@(%d) 失败: %s", procName, pid, strerror(errno)];
    return nil;
}

// kill 未找到进程判断（2026-08-25）：daemon 未常驻/App 未运行属正常，调用方忽略
static BOOL trKillNotFound(NSString *err) {
    return err != nil && [err hasPrefix:@"未找到进程"];
}

#pragma mark - 通话算法（D2 §2.2：分层选人/昼夜权重/Zipf 陌生号/时长对数/运营商客服）

// 反查分层选人权重（family 4.0 / work 3.0 / friend 2.0 / service 1.0 / business 0.5）
static double trRoleWeight(TRContactRole role) {
    switch (role) {
        case TRRoleFamily: return 4.0;
        case TRRoleWork: return 3.0;
        case TRRoleService: return 1.0;
        case TRRoleBusiness: return 0.5;
        default: return 2.0;
    }
}

// 昼夜权重（拒绝采样，最多 50 次；D3 §2.2）
static NSInteger trWeightedHour(void) {
    static const struct { NSInteger from, to; double w; } tbl[] = {
        {0,6,0.05},{6,8,0.30},{8,9,0.70},{9,12,0.90},{12,14,0.80},
        {14,18,0.95},{18,21,1.00},{21,23,0.70},{23,24,0.30},
    };
    for (NSInteger i = 0; i < 50; i++) {
        NSInteger h = trRandInt(0, 23);
        for (size_t k = 0; k < sizeof(tbl)/sizeof(tbl[0]); k++) {
            if (h >= tbl[k].from && h < tbl[k].to) {
                if (trRand01() < tbl[k].w) return h;
                break;
            }
        }
    }
    return 19;
}

// 活跃日：随机 1-2 天为活跃日（D2 §2.2）
static NSMutableSet *trActiveDaySet(NSInteger days) {
    NSMutableSet *set = [NSMutableSet setWithObject:@(trRandInt(0, days - 1))];
    if (days > 1 && trRand01() < 0.4) [set addObject:@(trRandInt(0, days - 1))];
    return set;
}

// 时长：对数分布 -ln(U)×120 秒；family 30% 长通话 10-30min（D2 §2.2）
static double trDurationFor(TRContactRole role, BOOL answered) {
    if (!answered) return 0;
    if (role == TRRoleFamily && trRand01() < 0.3) return 600 + trRand01() * 1200;
    double d = -log(1.0 - trRand01()) * 120;
    return MIN(1800, MAX(20, round(d)));
}

// 读系统通讯录 → 反查角色 → 分层池（反差确认：联系人内号码必在通讯录可查；为空返回 nil）
static NSDictionary *trLoadContactPool(NSString **errOut) {
    CNContactStore *store = [[CNContactStore alloc] init];
    NSError *err = nil;
    NSArray *keys = @[CNContactFamilyNameKey, CNContactPhoneNumbersKey];
    CNContactFetchRequest *req = [[CNContactFetchRequest alloc] initWithKeysToFetch:keys];
    NSMutableDictionary *byRole = [NSMutableDictionary dictionary];
    NSMutableArray *all = [NSMutableArray array];
    [store enumerateContactsWithFetchRequest:req error:&err usingBlock:^(CNContact *c, BOOL *stop) {
        NSString *name = c.familyName ?: @"";
        for (CNLabeledValue *lv in c.phoneNumbers) {
            NSString *phone = [lv.value stringValue];
            if (phone.length < 6) continue;
            TRContactRole role = trMatchRole(name);
            NSMutableArray *pool = byRole[@(role)] ?: [NSMutableArray array];
            [pool addObject:@{@"name": name, @"phone": phone}];
            byRole[@(role)] = pool;
            [all addObject:@{@"name": name, @"phone": phone}];
        }
    }];
    if (err && errOut) *errOut = err.localizedDescription;
    if (all.count == 0) return nil; // 通讯录为空 → 依赖校验（D2 §3.3）
    byRole[@(TRRoleFriend)] = byRole[@(TRRoleFriend)] ?: [NSMutableArray array];
    return @{@"byRole": byRole, @"all": all};
}

#pragma mark - 短信模板填充（与 Node fillTemplate 同构；{var} 替换，{brand} 取行业品牌池）

static NSString *trFillTemplate(NSString *tpl, NSString *carrier, NSArray *brandPool) {
    NSMutableString *s = [tpl mutableCopy];
    NSArray *brands = (brandPool.count > 0) ? brandPool : kBrands();
    NSDictionary *repl = @{
        @"{code4}": [NSString stringWithFormat:@"%ld", (long)trRandInt(1000, 9999)],
        @"{code6}": [NSString stringWithFormat:@"%ld", (long)trRandInt(100000, 999999)],
        @"{station}": kStations()[trRandInt(0, (NSInteger)kStations().count - 1)],
        @"{company}": kCouriers()[trRandInt(0, (NSInteger)kCouriers().count - 1)],
        @"{trackno}": [NSString stringWithFormat:@"%ld", (long)trRandInt(1000000000, 9999999999)],
        @"{box}": [NSString stringWithFormat:@"%ld", (long)trRandInt(1, 99)],
        @"{bank}": kBanks()[trRandInt(0, (NSInteger)kBanks().count - 1)],
        @"{last4}": [NSString stringWithFormat:@"%ld", (long)trRandInt(1000, 9999)],
        @"{time}": [NSString stringWithFormat:@"%ld:%02ld", (long)trRandInt(0, 23), (long)trRandInt(0, 59)],
        @"{amount}": [NSString stringWithFormat:@"%.2f", trRand01() * 5000],
        @"{balance}": [NSString stringWithFormat:@"%.2f", trRand01() * 50000],
        @"{day}": [NSString stringWithFormat:@"%ld日", (long)trRandInt(1, 28)],
        @"{gb1}": [NSString stringWithFormat:@"%.1f", trRand01() * 20],
        @"{gb2}": [NSString stringWithFormat:@"%.1f", trRand01() * 30],
        @"{carrier}": [carrier isEqualToString:@"cucc"] ? @"中国联通" : ([carrier isEqualToString:@"ctcc"] ? @"中国电信" : @"中国移动"),
        @"{estate}": kEstates()[trRandInt(0, (NSInteger)kEstates().count - 1)],
        @"{wan}": [NSString stringWithFormat:@"%ld", (long)trRandInt(15, 60)],
        @"{org}": kOrgs()[trRandInt(0, (NSInteger)kOrgs().count - 1)],
        @"{loan}": [NSString stringWithFormat:@"%ld", (long)trRandInt(5, 50)],
        @"{platform}": kPlatforms()[trRandInt(0, (NSInteger)kPlatforms().count - 1)],
        @"{product}": kProducts()[trRandInt(0, (NSInteger)kProducts().count - 1)],
        @"{ecom}": kEcoms()[trRandInt(0, (NSInteger)kEcoms().count - 1)],
        @"{brand}": brands[trRandInt(0, (NSInteger)brands.count - 1)],
        @"{discount}": [NSString stringWithFormat:@"%ld", (long)trRandInt(5, 9)],
        @"{pct}": [NSString stringWithFormat:@"%.1f", 0.5 + trRand01() * 7.5],
        @"{phone}": [NSString stringWithFormat:@"400-%ld", (long)trRandInt(1000000, 9999999)],
    };
    for (NSString *k in repl) {
        [s replaceOccurrencesOfString:k withString:repl[k] options:0 range:NSMakeRange(0, s.length)];
    }
    return s;
}

static NSString *trCarrierSvcPhone(NSString *carrier) {
    return [carrier isEqualToString:@"cucc"] ? @"10010" : ([carrier isEqualToString:@"ctcc"] ? @"10000" : @"10086");
}
// 106 企业特服号（验证码/营销短信发件；106 号段真实服务短信专用，非私人手机号）——106 + 8 位 = 11 位
static NSString *trRandomSvc106(void) {
    return [NSString stringWithFormat:@"106%08ld", (long)trRandInt(0, 99999999)];
}

#pragma mark - 各库批量写入

// 城市名归一（2026-08-25 修复）：App/5801 传入可能带"市/省/自治区"后缀（BRPickerView 数据源 regions.json 城市名带"市"，如"杭州市"），
// 而 AREA/HLR 表 key 为无后缀（"杭州"）——不归一则本地号/区号全回退（全国随机/北京区号），致通讯录与通话地区"断裂"
static NSString *trNormalizeCity(NSString *city) {
    if (![city isKindOfClass:[NSString class]]) return @"北京";
    NSArray *suf = @[@"特别行政区", @"维吾尔自治区", @"回族自治区", @"壮族自治区", @"自治区", @"省", @"市"];
    for (NSString *s in suf) city = [city stringByReplacingOccurrencesOfString:s withString:@""];
    return city.length ? city : @"北京";
}

/// 联系人：CNContactStore（关系构成 → 角色 → 备注名互斥；完整号段 + 区号固话；设计 §4）
static NSDictionary *trFillContacts(NSInteger count, NSDictionary *ratios) {
    double regionLocal = 0.65;
    NSNumber *rl = ratios[@"regionLocal"];
    if ([rl isKindOfClass:[NSNumber class]]) regionLocal = MAX(0.0, MIN(1.0, rl.doubleValue));
    NSArray *roles = @[@"friend", @"work", @"service", @"family", @"business"];
    double w[5] = {0.55, 0.20, 0.12, 0.08, 0.05};
    for (NSUInteger i = 0; i < roles.count; i++) {
        NSNumber *v = ratios[roles[i]];
        if ([v isKindOfClass:[NSNumber class]]) w[i] = MAX(0.0, MIN(1.0, v.doubleValue));
    }
    NSString *city = trNormalizeCity(ratios[@"city"]); // 归一城市名（去"市/省"后缀，AREA/HLR key 无后缀）
    NSString *areaCode = trAreaCodeForCity(city);

    NSInteger written = 0;
    NSString *dbErr = nil;
    CNContactStore *store = [[CNContactStore alloc] init];
    NSInteger batch = 50;
    NSMutableSet *used = [NSMutableSet set];
    for (NSInteger i = 0; i < count; i += batch) {
        CNSaveRequest *req = [[CNSaveRequest alloc] init];
        NSInteger end = MIN(count, i + batch);
        for (NSInteger j = i; j < end; j++) {
            double total = w[0] + w[1] + w[2] + w[3] + w[4];
            double r = (total > 0) ? trRand01() * total : trRand01(); // 归一化（对齐 Node weightedIndex；合计≠100 时差额等比分配而非塞首项）
            double acc = 0;
            NSInteger ri = 0;
            for (NSInteger t = 0; t < 5; t++) { acc += w[t]; if (r < acc) { ri = t; break; } }
            TRContactRole role = (TRContactRole)ri;
            NSString *fam = kFamilyNames()[trRandInt(0, (NSInteger)kFamilyNames().count - 1)];
            NSString *giv = kGivenNames()[trRandInt(0, (NSInteger)kGivenNames().count - 1)];
            NSString *name = trGenerateRemark(role, fam, giv);
            NSString *phone;
            // 号码分配（D1 §2.5 HLR 语义，与 Node contacts-gen 同构）：机构/生活服务类小比例本地固话；
            // regionLocal 分支 = 常住城市归属手机号（HLR 前缀），其余 = 全国随机手机号
            if ((role == TRRoleService || role == TRRoleBusiness) && trRand01() < 0.3) {
                phone = trRandomLandline(areaCode);
            } else if (trRand01() < regionLocal) {
                phone = trRandomLocalPhone(city) ?: trRandomPhone();
            } else {
                phone = trRandomPhone();
            }
            if ([used containsObject:phone]) { j--; continue; } // 生成集内去重
            [used addObject:phone];
            CNMutableContact *c = [[CNMutableContact alloc] init];
            c.familyName = name;
            c.phoneNumbers = @[[CNLabeledValue labeledValueWithLabel:@"手机" value:[CNPhoneNumber phoneNumberWithStringValue:phone]]];
            [req addContact:c toContainerWithIdentifier:nil];
        }
        NSError *cerr = nil;
        if (![store executeSaveRequest:req error:&cerr]) {
            dbErr = cerr.localizedDescription ?: @"CNContactStore 写入失败";
            break;
        }
        written += (end - i);
    }
    if (dbErr && written == 0)
        return @{@"ok": @NO, @"error": dbErr};
    // 不 kill contactsd（2026-08-25 定稿）：CNContactStore 写入由 contactsd 进程执行，其自身缓存/change-token 已同步
    // 并广播 CNContactStoreDidChangeNotification 让系统通讯录自动刷新——kill 是 data.test 直写 DB 时代遗留，
    // 反而打断所有 CNContactStore 客户端连接、制造重启窗口（清空/后续操作遇 CommunicationError 通信错误）。
    NSMutableDictionary *out = [@{@"ok": @YES, @"db": @"contacts", @"count": @(written)} mutableCopy];
    out[@"kill"] = @"none"; // 走 CNContactStore 无需 kill daemon（对比 calls/sms sqlite 直写必须 kill）
    return out;
}

/// 通话：ZCALLRECORD 批量（分层选人 + Zipf 陌生号 + 昼夜 + 时长 + 运营商客服；设计 §5）
static NSDictionary *trFillCalls(NSInteger count, NSDictionary *ratios) {
    NSInteger days = 30;
    if ([ratios[@"days"] isKindOfClass:[NSNumber class]]) days = MAX(1, MIN(90, [ratios[@"days"] integerValue]));
    double rContact = 0.70;
    NSNumber *rc = ratios[@"contact"];
    if ([rc isKindOfClass:[NSNumber class]]) rContact = MAX(0.0, MIN(1.0, rc.doubleValue));
    double wSt[3] = {0.40, 0.40, 0.20};
    NSArray *stKeys = @[@"incoming", @"outgoing", @"missed"];
    for (NSUInteger i = 0; i < stKeys.count; i++) {
        NSNumber *v = ratios[stKeys[i]];
        if ([v isKindOfClass:[NSNumber class]]) wSt[i] = MAX(0.0, MIN(1.0, v.doubleValue));
    }
    NSString *carrier = [ratios[@"carrier"] isKindOfClass:[NSString class]] ? ratios[@"carrier"] : @"cmcc";
    NSString *svcPhone = trCarrierSvcPhone(carrier);

    // 依赖校验：通讯录为空 → 提示先生成通讯录（D2 §3.3；反差确认前提）
    NSString *poolErr = nil;
    NSDictionary *pool = trLoadContactPool(&poolErr);
    if (!pool) return @{@"ok": @NO, @"error": @"通讯录为空，请先生成通讯录（联系人内选人依赖它）"};
    NSDictionary *byRole = pool[@"byRole"];

    NSString *path = @"/var/mobile/Library/CallHistoryDB/CallHistory.storedata";
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        NSString *e = [NSString stringWithUTF8String:sqlite3_errmsg(db) ?: "unknown"];
        if (db) sqlite3_close(db);
        return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"打开失败: %@", e]};
    }
    sqlite3_int64 ent = trDbScalar(db, @"SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME LIKE '%CallRecord%' LIMIT 1");
    if (!ent) ent = trDbScalar(db, @"SELECT Z_ENT FROM ZCALLRECORD LIMIT 1");
    sqlite3_int64 pk = trDbScalar(db, @"SELECT MAX(Z_PK) FROM ZCALLRECORD") + 1;
    // Cocoa epoch（2001-01-01）：ZCALLRECORD.ZDATE 是 Cocoa 纪元秒，用 timeIntervalSince1970（Unix 1970）会偏移 31 年（实测显示 2057 年）
    double now = [[NSDate date] timeIntervalSinceReferenceDate];

    __block NSInteger written = 0;
    __block NSString *dbErr = nil;
    void (^insertCall)(sqlite3_int64, double, NSString *, int, int, double) = ^(sqlite3_int64 tsPK, double ts, NSString *phone, int originated, int answered, double duration) {
        NSString *sql = [NSString stringWithFormat:
            @"INSERT INTO ZCALLRECORD (Z_PK,Z_ENT,Z_OPT,ZANSWERED,ZCALLTYPE,ZDISCONNECTED_CAUSE,ZORIGINATED,ZREAD,ZVERIFICATIONSTATUS,ZHANDLE_TYPE,ZCALL_CATEGORY,ZDATE,ZDURATION,ZISO_COUNTRY_CODE,ZADDRESS,ZUNIQUE_ID,ZSERVICE_PROVIDER) "
            @"VALUES (%lld,%lld,1,%d,1,0,%d,1,4,2,1,%.0f,%.1f,'CN',CAST('%@' AS BLOB),'%@','com.apple.Telephony')",
            tsPK, ent, answered, originated, ts, duration, phone, [[NSUUID UUID] UUIDString]];
        if (trDbExec(db, sql, &dbErr)) {
            trDbExec(db, [NSString stringWithFormat:@"UPDATE Z_PRIMARYKEY SET Z_MAX=%lld WHERE Z_ENT=%lld", tsPK, ent], nil);
            written++;
        }
    };

    // 角色键集合（反查分层选人；family 权重最高）
    NSArray *roleKeys = @[];
    for (NSNumber *k in byRole) {
        if ([byRole[k] count] > 0) roleKeys = [roleKeys arrayByAddingObject:k];
    }
    NSMutableSet *activeDays = trActiveDaySet(days);
    NSMutableArray *strangerPool = [NSMutableArray array]; // Zipf 陌生号局部池（模块级会跨 seed 污染）
    BOOL svcDone = NO;
    for (NSInteger i = 0; i < count; i++) {
        NSInteger day = trRandInt(0, days - 1);
        if (![activeDays containsObject:@(day)] && trRand01() < 0.6) { i--; continue; } // 沉寂日低频
        NSInteger hour = trWeightedHour();
        double ts = now - day * 86400.0 - (hour + trRand01()) * 3600.0;
        // 运营商客服来电 1-2 条（首次 8% 概率，D2 §2.4；已接时长短通话 30-120s）
        if (!svcDone && trRand01() < 0.08) {
            svcDone = YES;
            BOOL svcAnswered = trRand01() < 0.5;
            insertCall(pk++, ts, svcPhone, 0, svcAnswered ? 1 : 0, svcAnswered ? 30 + trRand01() * 90 : 0);
            continue;
        }
        // 选人池：联系人内（分层加权）/ 陌生号（Zipf 复用）
        BOOL isContact = trRand01() < rContact;
        NSString *phone; TRContactRole role = TRRoleFriend; NSString *name = nil;
        if (isContact) {
            NSArray *keys = roleKeys.count ? roleKeys : @[@(TRRoleFriend)];
            double total = 0; NSMutableArray *wR = [NSMutableArray array];
            for (NSNumber *k in keys) { double v = trRoleWeight((TRContactRole)k.integerValue); [wR addObject:@(v)]; total += v; }
            double r2 = trRand01() * total; NSInteger sel = 0;
            for (NSUInteger t = 0; t < keys.count; t++) { r2 -= [wR[t] doubleValue]; if (r2 < 0) { sel = t; break; } }
            NSArray *poolArr = byRole[keys[sel]] ?: @[];
            if (poolArr.count) { NSDictionary *c = poolArr[trRandInt(0, (NSInteger)poolArr.count - 1)]; phone = c[@"phone"]; name = c[@"name"]; role = (TRContactRole)((NSNumber *)keys[sel]).integerValue; }
            else { phone = (strangerPool.count && trRand01() < 0.5) ? strangerPool[trRandInt(0, (NSInteger)strangerPool.count - 1)] : (^{ NSString *n = trRandomPhone(); [strangerPool addObject:n]; return n; })(); }
        } else {
            if (strangerPool.count && trRand01() < 0.5) phone = strangerPool[trRandInt(0, (NSInteger)strangerPool.count - 1)];
            else { phone = trRandomPhone(); [strangerPool addObject:phone]; }
        }
        // 状态：missed 集中在陌生号（D2 §2.2）
        double totalSt = wSt[0] + wSt[1] + wSt[2];
        double r3 = (totalSt > 0) ? trRand01() * totalSt : trRand01(); // 归一化（对齐 Node）
        double acc = 0; NSInteger st = 0;
        for (NSInteger t = 0; t < 3; t++) { acc += wSt[t]; if (r3 < acc) { st = t; break; } }
        BOOL missed = (st == 2);
        BOOL answered = !missed;
        insertCall(pk++, ts, phone, (st == 1) ? 1 : 0, answered ? 1 : 0, trDurationFor(role, answered));
    }
    trDbExec(db, @"PRAGMA wal_checkpoint(TRUNCATE)", nil);
    sqlite3_close(db);
    if (dbErr && written == 0)
        return @{@"ok": @NO, @"error": dbErr};
    NSString *killErr = trKillDaemon(@"callservicesd");
    if (trKillNotFound(killErr)) killErr = nil; // daemon 未常驻=忽略
    NSString *appErr = trKillDaemon(@"MobilePhone"); // 电话 App 自动重启（未运行=未找到=忽略）
    if (trKillNotFound(appErr)) appErr = nil;
    NSMutableDictionary *out = [@{@"ok": @YES, @"db": @"calls", @"count": @(written)} mutableCopy];
    if (killErr) out[@"killError"] = killErr; else out[@"kill"] = @"callservicesd";
    if (appErr) out[@"appKillError"] = appErr; else out[@"appKill"] = @"MobilePhone";
    return out;
}

/// 短信：handle/chat/message/join 链批量（类型构成 + 收发比 + 内容池 TRCorpus + 运营商特服号 + 未接联动；设计 §6）
static NSDictionary *trFillSms(NSInteger count, NSDictionary *ratios) {
    NSInteger days = 30;
    if ([ratios[@"days"] isKindOfClass:[NSNumber class]]) days = MAX(1, MIN(90, [ratios[@"days"] integerValue]));
    double inRatio = 0.2; // 收发比（发 2 收 8，用户定案；仅 family 类生效）
    NSNumber *ir = ratios[@"inRatio"];
    if ([ir isKindOfClass:[NSNumber class]]) inRatio = MAX(0.0, MIN(1.0, ir.doubleValue));
    double wT[6] = {0.35, 0.20, 0.15, 0.10, 0.10, 0.10};
    NSArray *tKeys = @[@"code", @"express", @"bank", @"carrierSms", @"marketing", @"family"];
    for (NSUInteger i = 0; i < tKeys.count; i++) {
        NSNumber *v = ratios[tKeys[i]];
        if ([v isKindOfClass:[NSNumber class]]) wT[i] = MAX(0.0, MIN(1.0, v.doubleValue));
    }
    NSString *carrier = [ratios[@"carrier"] isKindOfClass:[NSString class]] ? ratios[@"carrier"] : @"cmcc";
    NSString *svcPhone = trCarrierSvcPhone(carrier);

    // 依赖校验（2026-08-25 定稿）：家人朋友短信依赖通讯录反查角色，通讯录为空整体拦截
    // （与通话生成一致，设计 §3.3 L191；Node generateSms 作为纯算法原型仍可脱离通讯录生成）
    NSDictionary *famPool = trLoadContactPool(nil);
    if (!famPool) return @{@"ok": @NO, @"error": @"通讯录为空，请先生成通讯录（家人朋友短信依赖通讯录）"};
    NSArray *famNumbers = famPool[@"byRole"][@(TRRoleFamily)] ?: @[];

    NSString *path = @"/var/mobile/Library/SMS/sms.db";
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        NSString *e = [NSString stringWithUTF8String:sqlite3_errmsg(db) ?: "unknown"];
        if (db) sqlite3_close(db);
        return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"打开失败: %@", e]};
    }
    // Cocoa epoch（2001-01-01）：message.date 是 Cocoa 纪元纳秒，用 timeIntervalSince1970（Unix 1970）会偏移 31 年（实测显示 2057 年）
    double now = [[NSDate date] timeIntervalSinceReferenceDate];
    NSInteger written = 0;
    NSString *dbErr = nil;

    // 未接来电联动（D2 §2.3）：查最近未接陌生号 → 跟 1 条"您有一个未接来电"
    NSString *missedPhone = nil;
    NSString *cp = @"/var/mobile/Library/CallHistoryDB/CallHistory.storedata";
    sqlite3 *cdb = NULL;
    if (sqlite3_open_v2(cp.UTF8String, &cdb, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) == SQLITE_OK) {
        sqlite3_stmt *stmt = NULL;
        const char *msql = "SELECT ZADDRESS FROM ZCALLRECORD WHERE ZANSWERED=0 ORDER BY ZDATE DESC LIMIT 5";
        if (sqlite3_prepare_v2(cdb, msql, -1, &stmt, NULL) == SQLITE_OK) {
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                const void *blob = sqlite3_column_blob(stmt, 0);
                int len = sqlite3_column_bytes(stmt, 0);
                if (blob && len > 0) {
                    NSString *addr = [[NSString alloc] initWithBytes:blob length:len encoding:NSUTF8StringEncoding];
                    if (addr.length >= 6 && ![addr hasPrefix:@"1008"] && ![addr hasPrefix:@"1001"] && ![addr hasPrefix:@"1000"]) { missedPhone = addr; break; }
                }
            }
        }
        sqlite3_finalize(stmt);
        sqlite3_close(cdb);
    }

    for (NSInteger i = 0; i < count; i++) {
        double totalT = wT[0] + wT[1] + wT[2] + wT[3] + wT[4] + wT[5];
        double r = (totalT > 0) ? trRand01() * totalT : trRand01(); // 归一化（对齐 Node weightedIndex）
        double acc = 0;
        NSInteger type = 5;
        for (NSInteger t = 0; t < 6; t++) { acc += wT[t]; if (r < acc) { type = t; break; } }
        sqlite3_int64 dateNs = (sqlite3_int64)((now - trRand01() * days * 86400.0) * 1000000000.0);
        NSString *text = nil;
        NSString *phone = nil;
        BOOL fromMe = NO;
        if (type == 5) { // family：家人朋友号码（通讯录家人池/随机）+ 日常语料，收发比生效
            fromMe = trRand01() < inRatio;
            if (famNumbers.count) phone = famNumbers[trRandInt(0, (NSInteger)famNumbers.count - 1)][@"phone"];
            else phone = trRandomPhone();
            text = kSmsFamilyTexts()[trRandInt(0, (NSInteger)kSmsFamilyTexts().count - 1)];
        } else if (type == 3) { // carrierSms：运营商服务短信，发件=特服号
            phone = svcPhone;
            text = trFillTemplate(kSmsCarrierTexts()[trRandInt(0, (NSInteger)kSmsCarrierTexts().count - 1)], carrier, nil);
        } else if (type == 4) { // marketing：随机行业组（品牌-内容强关联），发件=106 营销特服号
            NSArray *inds = kSmsMarketingIndustries();
            NSDictionary *g = inds[trRandInt(0, (NSInteger)inds.count - 1)];
            phone = trRandomSvc106();
            NSArray *tmpls = g[@"templates"];
            text = trFillTemplate(tmpls[trRandInt(0, (NSInteger)tmpls.count - 1)], carrier, g[@"brands"]);
        } else { // code/express/bank：服务短信，发件=服务号码（验证码 106 特服号 / 快递短号池 / 银行短号池，非私人手机号）
            NSArray *pool = nil;
            switch (type) {
                case 0: phone = trRandomSvc106(); pool = kSmsCodeTexts(); break;       // 验证码：106 特服号
                case 1: phone = kSmsSvcExpress()[trRandInt(0, (NSInteger)kSmsSvcExpress().count - 1)]; pool = kSmsExpressTexts(); break; // 快递：953xx/955xx 客服短号
                default: phone = kSmsSvcBank()[trRandInt(0, (NSInteger)kSmsSvcBank().count - 1)]; pool = kSmsBankTexts(); break;       // 银行：955xx 客服短号
            }
            text = trFillTemplate(pool[trRandInt(0, (NSInteger)pool.count - 1)], carrier, nil);
        }

        NSString *msgGuid = [[NSUUID UUID] UUIDString];
        sqlite3_int64 hid = phone ? trDbScalar(db, [NSString stringWithFormat:@"SELECT ROWID FROM handle WHERE id='%@' AND service='SMS'", phone]) : 0;
        BOOL ok = YES;
        if (phone && !hid) {
            ok = trDbExec(db, [NSString stringWithFormat:@"INSERT INTO handle (id, country, service, uncanonicalized_id) VALUES ('%@','cn','SMS','%@')", phone, phone], &dbErr);
            if (ok) hid = trDbScalar(db, @"SELECT last_insert_rowid()");
        }
        if (!ok) continue;
        sqlite3_int64 cid = 0;
        if (phone) {
            NSString *chatGuid = [NSString stringWithFormat:@"SMS;-;%@", phone];
            cid = trDbScalar(db, [NSString stringWithFormat:@"SELECT ROWID FROM chat WHERE guid='%@'", chatGuid]);
            if (!cid) {
                ok = trDbExec(db, [NSString stringWithFormat:
                    @"INSERT INTO chat (guid, chat_identifier, service_name, account_login, style, state, last_addressed_handle, is_archived, is_blackholed, is_filtered) "
                    @"VALUES ('%@','%@','SMS',(SELECT account_login FROM chat WHERE account_login IS NOT NULL AND service_name='SMS' LIMIT 1),45,3,'%@',0,0,0)",
                    chatGuid, phone, phone], &dbErr);
                if (ok) cid = trDbScalar(db, @"SELECT last_insert_rowid()");
            }
        }
        if (!ok) continue;
        sqlite3_int64 mid = 0;
        if (phone) {
            ok = trDbExec(db, [NSString stringWithFormat:
                @"INSERT INTO message (guid, text, handle_id, date, date_read, date_delivered, service, account, account_guid, version, is_from_me, is_read, is_sent, is_finished, is_delivered) "
                @"VALUES ('%@','%@',%lld,%lld,%lld,%lld,'SMS','P:%@',(SELECT account_guid FROM message WHERE account_guid IS NOT NULL AND service='SMS' LIMIT 1),10,%d,1,0,1,1)",
                msgGuid, text, hid, dateNs, dateNs, dateNs, phone, fromMe ? 1 : 0], &dbErr);
            if (ok) mid = trDbScalar(db, @"SELECT last_insert_rowid()");
            if (ok) ok = trDbExec(db, [NSString stringWithFormat:@"INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (%lld,%lld,%lld)", cid, mid, dateNs], &dbErr);
            if (ok) ok = trDbExec(db, [NSString stringWithFormat:@"INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (%lld,%lld)", cid, hid], &dbErr);
        } else {
            // family 类无 phone（家人朋友会话）：用系统账户 GUID 单消息插入（is_from_me 按收发比）
            ok = trDbExec(db, [NSString stringWithFormat:
                @"INSERT INTO message (guid, text, handle_id, date, date_read, date_delivered, service, account, account_guid, version, is_from_me, is_read, is_sent, is_finished, is_delivered) "
                @"VALUES ('%@','%@',NULL,%lld,%lld,%lld,'SMS','P:0',(SELECT account_guid FROM message WHERE account_guid IS NOT NULL AND service='SMS' LIMIT 1),10,%d,1,0,1,1)",
                msgGuid, text, dateNs, dateNs, dateNs, fromMe ? 1 : 0], &dbErr);
        }
        if (ok) written++;
    }
    // 未接联动短信（30% 概率跟 1 条）
    if (missedPhone && trRand01() < 0.3) {
        sqlite3_int64 dateNs = (sqlite3_int64)(now * 1000000000.0);
        trDbExec(db, [NSString stringWithFormat:
            @"INSERT INTO message (guid, text, handle_id, date, date_read, date_delivered, service, account, account_guid, version, is_from_me, is_read, is_sent, is_finished, is_delivered) "
            @"VALUES ('%@','【运营商】您有一个来自%@的未接来电',NULL,%lld,%lld,%lld,'SMS','P:0',(SELECT account_guid FROM message WHERE account_guid IS NOT NULL AND service='SMS' LIMIT 1),10,0,1,0,1,1)",
            [[NSUUID UUID] UUIDString], missedPhone, dateNs, dateNs, dateNs], nil);
        written++;
    }
    trDbExec(db, @"PRAGMA wal_checkpoint(TRUNCATE)", nil);
    sqlite3_close(db);
    if (dbErr && written == 0)
        return @{@"ok": @NO, @"error": dbErr};
    NSString *killErr = trKillDaemon(@"imagent");
    if (trKillNotFound(killErr)) killErr = nil; // daemon 未常驻=忽略
    NSString *appErr = trKillDaemon(@"MobileSMS"); // 信息 App 自动重启（未运行=未找到=忽略）
    if (trKillNotFound(appErr)) appErr = nil;
    NSMutableDictionary *out = [@{@"ok": @YES, @"db": @"sms", @"count": @(written)} mutableCopy];
    if (killErr) out[@"killError"] = killErr; else out[@"kill"] = @"imagent";
    if (appErr) out[@"appKillError"] = appErr; else out[@"appKill"] = @"MobileSMS";
    return out;
}

@implementation TRDataFiller

+ (NSDictionary *)fillDatabase:(NSString *)db
                         count:(NSInteger)count
                          seed:(uint64_t)seed
                        ratios:(NSDictionary *)ratios {
    if (![db isKindOfClass:[NSString class]]) return @{@"ok": @NO, @"error": @"db 缺失"};
    if (count < 1 || count > 1000) return @{@"ok": @NO, @"error": @"count 须在 1~1000"};
    trSeed(seed);
    NSDictionary *rr = [ratios isKindOfClass:[NSDictionary class]] ? ratios : @{};
    if ([db isEqualToString:@"calls"]) return trFillCalls(count, rr);
    if ([db isEqualToString:@"sms"]) return trFillSms(count, rr);
    if ([db isEqualToString:@"contacts"]) return trFillContacts(count, rr);
    return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"未知 db: %@（contacts/calls/sms）", db]};
}

+ (NSDictionary *)clearDatabase:(NSString *)db {
    if (![db isKindOfClass:[NSString class]]) return @{@"ok": @NO, @"error": @"db 缺失"};
    BOOL all = [db isEqualToString:@"all"];
    NSInteger cleared = 0;
    NSDictionary *callsMeta = nil; // 通话库诊断（2026-08-25，真机确认无同款机制后删除）：触发器列表 + ZCALLRECORD 字段
    NSDictionary *smsMeta = nil; // 短信库诊断（2026-08-25，真机确认口径后删除）：message flags/join 分布 + chat state 分布
    NSMutableArray *kills = [NSMutableArray array];
    NSMutableArray *errors = [NSMutableArray array];
    __block NSInteger remainContacts = -1; // 清空后残留数（-1=未校验/校验失败；仅 contacts 分支写入，非 contacts 清空不受影响）
    if (all || [db isEqualToString:@"calls"]) {
        NSString *path = @"/var/mobile/Library/CallHistoryDB/CallHistory.storedata";
        sqlite3 *d = NULL;
        if (sqlite3_open_v2(path.UTF8String, &d, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL) == SQLITE_OK) {
            cleared += (NSInteger)trDbScalar(d, @"SELECT COUNT(*) FROM ZCALLRECORD");
            NSString *e = nil;
            trDbExec(d, @"DELETE FROM ZCALLRECORD", &e); // 不动 Z_PRIMARYKEY（ROWID 空洞正常，D5 §7.4）
            if (e) [errors addObject:e];
            // 2026-08-26 修复：iOS 后台把通话号码同步进 ZHANDLE（Handle 表），清空只删 ZCALLRECORD 会残留历史号码
            // （生成陌生号随机含驻马店等号段 → 清空后 ZHANDLE 残留 → Recents 关联显示"被删号码复活"）
            e = nil;
            trDbExec(d, @"DELETE FROM ZHANDLE", &e);
            if (e) [errors addObject:e];
            trDbExec(d, @"PRAGMA wal_checkpoint(TRUNCATE)", nil);
            // 顺带诊断：CallHistory 触发器列表 + ZCALLRECORD 字段清单（真机确认无同款机制）
            NSMutableArray *trigs = [NSMutableArray array];
            sqlite3_stmt *ts = NULL;
            if (sqlite3_prepare_v2(d, "SELECT name FROM sqlite_master WHERE type='trigger'", -1, &ts, NULL) == SQLITE_OK) {
                while (sqlite3_step(ts) == SQLITE_ROW) [trigs addObject:[NSString stringWithUTF8String:(const char *)sqlite3_column_text(ts, 0) ?: ""]];
            }
            sqlite3_finalize(ts);
            NSMutableArray *cols = [NSMutableArray array];
            sqlite3_stmt *cs = NULL;
            if (sqlite3_prepare_v2(d, "PRAGMA table_info(ZCALLRECORD)", -1, &cs, NULL) == SQLITE_OK) {
                while (sqlite3_step(cs) == SQLITE_ROW) [cols addObject:[NSString stringWithUTF8String:(const char *)sqlite3_column_text(cs, 1) ?: ""]];
            }
            sqlite3_finalize(cs);
            callsMeta = @{@"triggers": trigs, @"columns": cols};
            sqlite3_close(d);
            [kills addObject:@"callservicesd"];
            [kills addObject:@"MobilePhone"]; // 电话 App（自动重启实现"立即生效"；未运行则 kill 找不到=忽略）
        } else {
            [errors addObject:[NSString stringWithFormat:@"calls 库打开失败: %@", [NSString stringWithUTF8String:sqlite3_errmsg(d) ?: "unknown"]]];
            if (d) sqlite3_close(d);
        }
    }
    if (all || [db isEqualToString:@"sms"]) {
        NSString *path = @"/var/mobile/Library/SMS/sms.db";
        sqlite3 *d = NULL;
        if (sqlite3_open_v2(path.UTF8String, &d, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL) == SQLITE_OK) {
            trRegisterTriggerFuncs(d); // DELETE 前注册 message 表触发器依赖函数（防 no such function → 残留/数字虚高）
            // 顺带诊断：message 按 flags 分组 / join 有无分布 + chat 按 state 分组（真机定论显示口径）
            NSMutableArray *flagsDist = [NSMutableArray array];
            sqlite3_stmt *fs2 = NULL;
            if (sqlite3_prepare_v2(d, "SELECT flags, COUNT(*) FROM message WHERE service='SMS' GROUP BY flags", -1, &fs2, NULL) == SQLITE_OK) {
                while (sqlite3_step(fs2) == SQLITE_ROW) {
                    [flagsDist addObject:[NSString stringWithFormat:@"flags=%lld n=%lld", (long long)sqlite3_column_int64(fs2, 0), (long long)sqlite3_column_int64(fs2, 1)]];
                }
            }
            sqlite3_finalize(fs2);
            NSMutableArray *joinDist = [NSMutableArray array];
            sqlite3_stmt *js = NULL;
            if (sqlite3_prepare_v2(d, "SELECT COUNT(*) FROM message m WHERE m.service='SMS' AND EXISTS(SELECT 1 FROM chat_message_join j WHERE j.message_id = m.ROWID)", -1, &js, NULL) == SQLITE_OK) {
                if (sqlite3_step(js) == SQLITE_ROW) [joinDist addObject:[NSString stringWithFormat:@"with_join=%lld", (long long)sqlite3_column_int64(js, 0)]];
            }
            sqlite3_finalize(js);
            NSMutableArray *chatState = [NSMutableArray array];
            sqlite3_stmt *cs2 = NULL;
            if (sqlite3_prepare_v2(d, "SELECT state, is_filtered, COUNT(*) FROM chat WHERE service_name='SMS' GROUP BY state, is_filtered", -1, &cs2, NULL) == SQLITE_OK) {
                while (sqlite3_step(cs2) == SQLITE_ROW) {
                    [chatState addObject:[NSString stringWithFormat:@"state=%lld flt=%lld n=%lld", (long long)sqlite3_column_int64(cs2, 0), (long long)sqlite3_column_int64(cs2, 1), (long long)sqlite3_column_int64(cs2, 2)]];
                }
            }
            sqlite3_finalize(cs2);
            smsMeta = @{@"flagsDist": flagsDist, @"joinDist": joinDist, @"chatState": chatState};
            // 计数口径（2026-08-25 定稿）：会话口径——信息 App 主界面=会话列表（chat 表），message 行/join 关联与显示脱节
            // （EXISTS join + flags 曾把实际可见短信全排除报 0；软删历史行仍在 chat 维度被计数，属"清空全部短信"应有语义）
            cleared += (NSInteger)trDbScalar(d, @"SELECT COUNT(*) FROM chat WHERE service_name='SMS' AND is_filtered=0 AND is_archived=0 AND is_blackholed=0");
            NSString *e = nil;
            // 保留 iMessage：仅清 SMS 相关链（设计 §7.2）
            trDbExec(d, @"DELETE FROM chat_message_join WHERE message_id IN (SELECT ROWID FROM message WHERE service='SMS')", &e);
            trDbExec(d, @"DELETE FROM chat_handle_join WHERE chat_id IN (SELECT ROWID FROM chat WHERE service_name='SMS')", &e);
            trDbExec(d, @"DELETE FROM message WHERE service='SMS'", &e);
            trDbExec(d, @"DELETE FROM chat WHERE service_name='SMS'", &e);
            trDbExec(d, @"DELETE FROM handle WHERE service='SMS'", &e);
            if (e) [errors addObject:e];
            trDbExec(d, @"PRAGMA wal_checkpoint(TRUNCATE)", nil);
            sqlite3_close(d);
            [kills addObject:@"imagent"];
            [kills addObject:@"MobileSMS"]; // 信息 App（同上）
        } else {
            [errors addObject:[NSString stringWithFormat:@"sms 库打开失败: %@", [NSString stringWithUTF8String:sqlite3_errmsg(d) ?: "unknown"]]];
            if (d) sqlite3_close(d);
        }
    }
    if (all || [db isEqualToString:@"contacts"]) {
        CNContactStore *store = [[CNContactStore alloc] init];
        // identifier 必须显式请求：deleteContact: 依赖 contact.identifier（iOS 15 起缺省 keys 删除不生效）
        NSArray *keys = @[CNContactIdentifierKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey];
        CNContactFetchRequest *req = [[CNContactFetchRequest alloc] initWithKeysToFetch:keys];
        __block NSMutableArray *toDelete = [NSMutableArray array];
        NSError *fErr = nil;
        if (![store enumerateContactsWithFetchRequest:req error:&fErr usingBlock:^(CNContact *c, BOOL *stop) {
            [toDelete addObject:c];
        }] && fErr) {
            [errors addObject:[NSString stringWithFormat:@"通讯录枚举失败: %@", fErr.localizedDescription ?: @"未知"]];
        }
        // 分批删除（20 条/批小事务）；deleteContact 传 mutableCopy——immutable 快照删除偶发"返回成功但静默不提交"（苹果论坛 #660494）
        for (NSInteger i = 0; i < (NSInteger)toDelete.count; i += 20) {
            CNSaveRequest *dReq = [[CNSaveRequest alloc] init];
            NSInteger end = MIN((NSInteger)toDelete.count, i + 20);
            for (NSInteger j = i; j < end; j++) [dReq deleteContact:[toDelete[j] mutableCopy]];
            NSError *dErr = nil;
            if ([store executeSaveRequest:dReq error:&dErr]) cleared += (end - i);
            else [errors addObject:dErr.localizedDescription ?: @"CNContactStore 删除失败"];
        }
        // 清空后校验（2026-08-25 定稿）：重新枚举统计残留；>0 = 部分失败显式报错
        // （只读账户/SIM/iCloud 回写无法删除时给用户明确感知，避免"看似清空实际未删干净"）
        remainContacts = 0;
        CNContactFetchRequest *vReq = [[CNContactFetchRequest alloc] initWithKeysToFetch:@[CNContactIdentifierKey]];
        NSError *vErr = nil;
        if (![store enumerateContactsWithFetchRequest:vReq error:&vErr usingBlock:^(CNContact *c, BOOL *stop) {
            remainContacts++;
        }] && vErr) {
            [errors addObject:[NSString stringWithFormat:@"清空后校验失败: %@", vErr.localizedDescription ?: @"未知"]];
            remainContacts = -1; // 校验失败不判定残留
        }
        // 不 kill contactsd：写删由 contactsd 执行自同步 + change 通知自动刷新（kill 是直写 DB 时代遗留，自伤）
    }
    NSMutableDictionary *out = [@{@"ok": @YES, @"db": db, @"cleared": @(cleared)} mutableCopy];
    if (callsMeta) out[@"callsMeta"] = callsMeta; // 通话库诊断（仅 calls/all 清空时存在）
    if (smsMeta) out[@"smsMeta"] = smsMeta; // 短信库诊断（仅 sms/all 清空时存在）
    // kill 失败降级（2026-08-25 定稿）："未找到进程"= daemon 未常驻/App 未运行，属正常，忽略；
    // 其余 kill 错误为信息级（killError 字段），不进 errors——不误报"部分失败"（清空本体已成功）
    NSMutableArray *killErrs = [NSMutableArray array];
    for (NSString *k in kills) {
        NSString *ke = trKillDaemon(k);
        if (!ke || trKillNotFound(ke)) continue;
        [killErrs addObject:ke];
    }
    if (killErrs.count) out[@"killError"] = [killErrs componentsJoinedByString:@"; "];
    if (remainContacts > 0) {
        out[@"ok"] = @NO;
        out[@"remaining"] = @(remainContacts);
        out[@"error"] = [NSString stringWithFormat:@"仍有 %ld 条联系人未能删除（可能来自 iCloud 同步/只读账户/SIM 卡），请检查 设置→通讯录→账户", (long)remainContacts];
    }
    if (errors.count) out[@"errors"] = errors;
    return out;
}

// ===== data.read 数据读取（2026-08-25 能力缺口补齐）=====
// 读取指定库现有数据（最近 N 行），验证「读取链路 + 系统数据格式」——写入前的先决验证。
// 移植自 trollvncserver tvExtHandleDataRead：kDBPaths + 白名单表 + SELECT * ORDER BY ROWID DESC LIMIT。
// 返回结构对齐旧实现（含 ok 字段），trollvncserver 5802/0x50 薄封装直接透传、注册表 invoke 检测 ok 转 NSError。

+ (NSDictionary *)readDatabase:(NSString *)dbName table:(NSString *)table limit:(NSInteger)limit {
    if (![dbName isKindOfClass:[NSString class]])
        return @{@"ok": @NO, @"error": @"data.read 缺少参数 db（calls/sms/contacts）"};
    if (limit < 1 || limit > 50) limit = 5;
    static NSDictionary *kDBPaths = nil;
    if (!kDBPaths) {
        kDBPaths = @{
            @"calls": @"/var/mobile/Library/CallHistoryDB/CallHistory.storedata",
            @"sms": @"/var/mobile/Library/SMS/sms.db",
            @"contacts": @"/var/mobile/Library/AddressBook/AddressBook.sqlitedb",
        };
    }
    NSString *path = kDBPaths[dbName];
    if (![path isKindOfClass:[NSString class]] || path.length == 0)
        return @{@"ok": @NO, @"error": @"data.read 缺少参数 db（calls/sms/contacts）"};

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        NSString *e = [NSString stringWithUTF8String:sqlite3_errmsg(db) ?: "unknown"];
        if (db) sqlite3_close(db);
        return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"打开失败: %@", e]};
    }

    NSDictionary *qerr = nil;
    NSArray *rows = nil;
    // table 参数（可选，白名单）：默认读各库主表，可按需读 chat/handle 等关联表排查
    NSArray *allowed = nil;
    NSString *defaultTable = nil;
    if ([dbName isEqualToString:@"calls"]) {
        allowed = @[@"ZCALLRECORD", @"ZHANDLE", @"Z_PRIMARYKEY"];
        defaultTable = @"ZCALLRECORD";
    } else if ([dbName isEqualToString:@"sms"]) {
        allowed = @[@"message", @"chat", @"handle", @"chat_message_join", @"chat_handle_join"];
        defaultTable = @"message";
    } else if ([dbName isEqualToString:@"contacts"]) {
        allowed = @[@"ABPerson", @"ABMultiValue", @"ABStore"];
        defaultTable = @"ABPerson";
    } else {
        sqlite3_close(db);
        return @{@"ok": @NO, @"error": @"未知 db: calls/sms/contacts"};
    }
    if (table && ![table isKindOfClass:[NSString class]]) { sqlite3_close(db); return @{@"ok": @NO, @"error": @"table 必须为字符串"}; }
    if (table && ![allowed containsObject:table]) { sqlite3_close(db); return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"table 不在白名单: %@", table]}; }
    if (!table) table = defaultTable;
    rows = trDbQueryRows(db, [NSString stringWithFormat:@"SELECT * FROM %@ ORDER BY ROWID DESC LIMIT %ld", table, (long)limit], &qerr);
    sqlite3_close(db);

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"ok"] = @YES;
    out[@"db"] = dbName;
    out[@"count"] = @(rows.count);
    out[@"rows"] = rows;
    if (qerr) out[@"error"] = qerr[@"error"];
    return out;
}

@end
