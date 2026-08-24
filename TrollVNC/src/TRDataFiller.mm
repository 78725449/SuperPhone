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

#import <sqlite3.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <signal.h>
#import <Contacts/Contacts.h>

#pragma mark - 确定性随机（seed 驱动 xorshift64，同 seed 可复现）

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

#pragma mark - 语料（内置；M5 计划 P8 已定：语料默认内置）

static NSArray *kFamilyNames(void) {
    return @[@"王", @"李", @"张", @"刘", @"陈", @"杨", @"黄", @"赵", @"吴", @"周",
             @"徐", @"孙", @"马", @"朱", @"胡", @"郭", @"何", @"林", @"罗", @"郑"];
}
static NSArray *kGivenNames(void) {
    return @[@"伟", @"芳", @"娜", @"敏", @"静", @"磊", @"军", @"洋", @"勇", @"艳",
             @"杰", @"娟", @"涛", @"明", @"超", @"霞", @"平", @"强", @"倩", @"雪",
             @"鑫", @"晨", @"宇", @"浩", @"婷", @"琳", @"悦", @"哲", @"思远", @"子涵"];
}
static NSArray *kSmsTexts(void) {
    return @[@"好的，知道了", @"在忙吗？", @"晚上一起吃饭？", @"收到，谢谢", @"明天见！",
             @"你到哪里了？", @"记得带伞，要下雨了", @"文件发你邮箱了", @"周末有空吗？",
             @"早点休息，晚安", @"打车了吗？", @"会议室定了，三点见", @"孩子放学我去接",
             @"这个方案明天前要确认", @"快递放门卫了", @"周末去爬山吗？"];
}
// 短信类型语料（对齐原型类型构成：验证码/快递/银行/运营商/营销/家人朋友）
static NSArray *kSmsCodeTexts(void) {
    return @[@"【XX服务】您的验证码是%04ld，10分钟内有效。如非本人操作请忽略。",
             @"验证码：%04ld，您正在登录账号，请勿泄露给他人。"];
}
static NSArray *kSmsExpressTexts(void) {
    return @[@"【驿站】您的包裹已到驿站，取件码%04ld，请及时取件。",
             @"【快递】您的包裹正在派送中，请保持电话畅通。",
             @"【快递】包裹已签收，感谢使用，祝您生活愉快。"];
}
static NSArray *kSmsBankTexts(void) {
    return @[@"【XX银行】您尾号%04ld的账户收入人民币%.2f元，余额%.2f元。",
             @"【XX银行】您尾号%04ld的账户支出人民币%.2f元，余额%.2f元。",
             @"【XX银行】您的信用卡账单已出，本期应还%.2f元，请按时还款。"];
}
static NSArray *kSmsCarrierTexts(void) {
    return @[@"【运营商】您的本月流量已使用%.1fGB，剩余%.1fGB。",
             @"【运营商】温馨提示：您当前套餐即将到期，续约可享优惠。",
             @"【运营商】您的积分已到账，可兑换话费或流量。"];
}
static NSArray *kSmsMarketingTexts(void) {
    return @[@"【优惠】限时秒杀，全场低至5折，点击查看详情。",
             @"【推广】您有1张优惠券即将到期，速来使用。",
             @"【会员】本月会员日，双倍积分+专属折扣等你来。"];
}
static NSArray *kPhonePrefixes(void) {
    return @[@"13", @"15", @"17", @"18", @"19"];
}
static NSString *trRandomPhone(void) {
    NSString *prefix = kPhonePrefixes()[trRandInt(0, (NSInteger)kPhonePrefixes().count - 1)];
    // 11 位：前缀 2 位 + 9 位尾号
    NSInteger tail = trRandInt(100000000, 999999999);
    return [NSString stringWithFormat:@"%@%ld", prefix, (long)tail];
}
static NSString *trRandomName(void) {
    NSString *family = kFamilyNames()[trRandInt(0, (NSInteger)kFamilyNames().count - 1)];
    NSString *given = kGivenNames()[trRandInt(0, (NSInteger)kGivenNames().count - 1)];
    // 名 1~2 字
    if (trRand01() < 0.5) {
        given = [given substringToIndex:1];
    }
    return [family stringByAppendingString:given];
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

#pragma mark - 各库批量写入

/// 通话：ZCALLRECORD 批量（ZDATE 秒 / ZDURATION / ZADDRESS 号码 BLOB / 状态构成：呼入/呼出/未接）
static NSDictionary *trFillCalls(NSInteger count, NSDictionary *ratios) {
    // 时间范围（近 N 天，默认 30）
    NSInteger days = 30;
    if ([ratios[@"days"] isKindOfClass:[NSNumber class]]) days = MAX(1, MIN(90, [ratios[@"days"] integerValue]));
    // 状态权重（呼入/呼出/未接）
    double w[3] = {0.40, 0.40, 0.20};
    NSArray *keys = @[@"statusIn", @"statusOut", @"statusMissed"];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSNumber *v = ratios[keys[i]];
        if ([v isKindOfClass:[NSNumber class]]) w[i] = MAX(0.0, MIN(1.0, v.doubleValue));
    }

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
    double now = [[NSDate date] timeIntervalSince1970];
    NSInteger written = 0;
    NSString *dbErr = nil;
    for (NSInteger i = 0; i < count; i++) {
        double ts = now - trRand01() * days * 86400.0;
        double dur = 10.0 + pow(trRand01(), 1.6) * 1790.0;
        // 按权重选状态：呼出 ZORIGINATED=1/ZANSWERED=1；呼入 0/1；未接 ZANSWERED=0
        double r = trRand01();
        double acc = 0;
        NSInteger st = 0;
        for (NSInteger t = 0; t < 3; t++) { acc += w[t]; if (r < acc) { st = t; break; } }
        int originated = (st == 1) ? 1 : 0;
        int answered = (st == 2) ? 0 : 1;
        NSString *sql = [NSString stringWithFormat:
            @"INSERT INTO ZCALLRECORD (Z_PK,Z_ENT,Z_OPT,ZANSWERED,ZCALLTYPE,ZDISCONNECTED_CAUSE,ZORIGINATED,ZREAD,ZVERIFICATIONSTATUS,ZHANDLE_TYPE,ZCALL_CATEGORY,ZDATE,ZDURATION,ZISO_COUNTRY_CODE,ZADDRESS,ZUNIQUE_ID,ZSERVICE_PROVIDER) "
            @"VALUES (%lld,%lld,1,%d,1,0,%d,1,4,2,1,%.0f,%.1f,'CN',CAST('%@' AS BLOB),'%@','com.apple.Telephony')",
            pk, ent, answered, originated, ts, dur, trRandomPhone(), [[NSUUID UUID] UUIDString]];
        if (trDbExec(db, sql, &dbErr)) {
            trDbExec(db, [NSString stringWithFormat:@"UPDATE Z_PRIMARYKEY SET Z_MAX=%lld WHERE Z_ENT=%lld", pk, ent], nil);
            written++;
        }
        pk++;
    }
    trDbExec(db, @"PRAGMA wal_checkpoint(TRUNCATE)", nil);
    sqlite3_close(db);
    if (dbErr && written == 0)
        return @{@"ok": @NO, @"error": dbErr};
    NSString *killErr = trKillDaemon(@"callservicesd");
    NSMutableDictionary *out = [@{@"ok": @YES, @"db": @"calls", @"count": @(written)} mutableCopy];
    if (killErr) out[@"killError"] = killErr; else out[@"kill"] = @"callservicesd";
    return out;
}

/// 短信：handle/chat/message/join 链批量（date 纳秒；类型构成：验证码/快递/银行/运营商/营销/家人朋友）
static NSDictionary *trFillSms(NSInteger count, NSDictionary *ratios) {
    // 时间范围（近 N 天，默认 30）
    NSInteger days = 30;
    if ([ratios[@"days"] isKindOfClass:[NSNumber class]]) days = MAX(1, MIN(90, [ratios[@"days"] integerValue]));
    // 类型权重（验证码/快递/银行/运营商/营销/家人朋友，缺省等权）
    double w[6] = {0.35, 0.20, 0.15, 0.10, 0.10, 0.10};
    NSArray *keys = @[@"typeSms", @"typeExpress", @"typeBank", @"typeCarrier", @"typeMarketing", @"typePersonal"];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSNumber *v = ratios[keys[i]];
        if ([v isKindOfClass:[NSNumber class]]) w[i] = MAX(0.0, MIN(1.0, v.doubleValue));
    }

    NSString *path = @"/var/mobile/Library/SMS/sms.db";
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        NSString *e = [NSString stringWithUTF8String:sqlite3_errmsg(db) ?: "unknown"];
        if (db) sqlite3_close(db);
        return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"打开失败: %@", e]};
    }
    double now = [[NSDate date] timeIntervalSince1970];
    NSInteger written = 0;
    NSString *dbErr = nil;
    for (NSInteger i = 0; i < count; i++) {
        NSString *phone = trRandomPhone();
        NSString *msgGuid = [[NSUUID UUID] UUIDString];
        sqlite3_int64 dateNs = (sqlite3_int64)((now - trRand01() * days * 86400.0) * 1000000000.0);
        // 按权重选类型 → 文本模板（家人朋友=日常语料）
        double r = trRand01();
        double acc = 0;
        NSInteger type = 5;
        for (NSInteger t = 0; t < 6; t++) { acc += w[t]; if (r < acc) { type = t; break; } }
        NSString *text = nil;
        switch (type) {
            case 0: { NSString *tmpl = kSmsCodeTexts()[trRandInt(0, (NSInteger)kSmsCodeTexts().count - 1)]; text = [NSString stringWithFormat:tmpl, (long)trRandInt(1000, 9999)]; break; }
            case 1: { NSString *tmpl = kSmsExpressTexts()[trRandInt(0, (NSInteger)kSmsExpressTexts().count - 1)]; text = [NSString stringWithFormat:tmpl, (long)trRandInt(1000, 9999)]; break; }
            case 2: { NSString *tmpl = kSmsBankTexts()[trRandInt(0, (NSInteger)kSmsBankTexts().count - 1)]; text = [NSString stringWithFormat:tmpl, (long)trRandInt(1000, 9999), trRand01() * 5000, trRand01() * 50000]; break; }
            case 3: { NSString *tmpl = kSmsCarrierTexts()[trRandInt(0, (NSInteger)kSmsCarrierTexts().count - 1)]; text = [NSString stringWithFormat:tmpl, trRand01() * 20, trRand01() * 30]; break; }
            case 4: text = kSmsMarketingTexts()[trRandInt(0, (NSInteger)kSmsMarketingTexts().count - 1)]; break;
            default: text = kSmsTexts()[trRandInt(0, (NSInteger)kSmsTexts().count - 1)]; break;
        }
        // 类型 0-4（验证码/快递/银行/运营商/营销）= 收到的（is_from_me=0）；家人朋友混合
        BOOL fromMe = (type == 5) && (trRand01() < 0.5);
        sqlite3_int64 hid = trDbScalar(db, [NSString stringWithFormat:@"SELECT ROWID FROM handle WHERE id='%@' AND service='SMS'", phone]);
        BOOL ok = YES;
        if (!hid) {
            ok = trDbExec(db, [NSString stringWithFormat:@"INSERT INTO handle (id, country, service, uncanonicalized_id) VALUES ('%@','cn','SMS','%@')", phone, phone], &dbErr);
            if (ok) hid = trDbScalar(db, @"SELECT last_insert_rowid()");
        }
        if (!ok) continue;
        NSString *chatGuid = [NSString stringWithFormat:@"SMS;-;%@", phone];
        sqlite3_int64 cid = trDbScalar(db, [NSString stringWithFormat:@"SELECT ROWID FROM chat WHERE guid='%@'", chatGuid]);
        if (!cid) {
            ok = trDbExec(db, [NSString stringWithFormat:
                @"INSERT INTO chat (guid, chat_identifier, service_name, account_login, style, state, last_addressed_handle, is_archived, is_blackholed, is_filtered) "
                @"VALUES ('%@','%@','SMS',(SELECT account_login FROM chat WHERE account_login IS NOT NULL AND service_name='SMS' LIMIT 1),45,3,'%@',0,0,0)",
                chatGuid, phone, phone], &dbErr);
            if (ok) cid = trDbScalar(db, @"SELECT last_insert_rowid()");
        }
        if (!ok) continue;
        sqlite3_int64 mid = 0;
        ok = trDbExec(db, [NSString stringWithFormat:
            @"INSERT INTO message (guid, text, handle_id, date, date_read, date_delivered, service, account, account_guid, version, is_from_me, is_read, is_sent, is_finished, is_delivered) "
            @"VALUES ('%@','%@',%lld,%lld,%lld,%lld,'SMS','P:%@',(SELECT account_guid FROM message WHERE account_guid IS NOT NULL AND service='SMS' LIMIT 1),10,%d,1,0,1,1)",
            msgGuid, text, hid, dateNs, dateNs, dateNs, phone, fromMe ? 1 : 0], &dbErr);
        if (ok) mid = trDbScalar(db, @"SELECT last_insert_rowid()");
        if (ok) ok = trDbExec(db, [NSString stringWithFormat:@"INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (%lld,%lld,%lld)", cid, mid, dateNs], &dbErr);
        if (ok) ok = trDbExec(db, [NSString stringWithFormat:@"INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (%lld,%lld)", cid, hid], &dbErr);
        if (ok) written++;
    }
    trDbExec(db, @"PRAGMA wal_checkpoint(TRUNCATE)", nil);
    sqlite3_close(db);
    if (dbErr && written == 0)
        return @{@"ok": @NO, @"error": dbErr};
    NSString *killErr = trKillDaemon(@"imagent");
    NSMutableDictionary *out = [@{@"ok": @YES, @"db": @"sms", @"count": @(written)} mutableCopy];
    if (killErr) out[@"killError"] = killErr; else out[@"kill"] = @"imagent";
    return out;
}

/// 联系人：CNContactStore（系统维护排序/FTS；kTCCServiceAddressBook entitlement 放行）
/// 拟人参数：关系构成（朋友/工作/生活/家人/机构 → 号码 label 分布）、本地占比/常住地区（号段）
static NSDictionary *trFillContacts(NSInteger count, NSDictionary *ratios) {
    double localRatio = 0.65;
    NSNumber *lr = ratios[@"localRatio"];
    if ([lr isKindOfClass:[NSNumber class]]) localRatio = MAX(0.0, MIN(1.0, lr.doubleValue));
    // 关系权重（缺省对齐原型）
    double w[5] = {0.55, 0.20, 0.12, 0.08, 0.05};
    NSArray *keys = @[@"relFriends", @"relWork", @"relLife", @"relFamily", @"relBiz"];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSNumber *v = ratios[keys[i]];
        if ([v isKindOfClass:[NSNumber class]]) w[i] = MAX(0.0, MIN(1.0, v.doubleValue));
    }
    // 号码 label（真实联系人本地化 label；系统常量无 Work/Home（仅 *Fax），用自定义中文更真实）
    NSArray *labels = @[@"手机", @"工作", @"住宅", @"iPhone", @"主号"];
    NSString *city = [ratios[@"city"] isKindOfClass:[NSString class]] ? ratios[@"city"] : @"beijing";
    NSDictionary *cityArea = @{@"beijing": @"10", @"shanghai": @"21", @"guangzhou": @"20",
                               @"shenzhen": @"755", @"chengdu": @"28"};

    NSInteger written = 0;
    NSString *dbErr = nil;
    CNContactStore *store = [[CNContactStore alloc] init];
    NSInteger batch = 50;
    for (NSInteger i = 0; i < count; i += batch) {
        CNSaveRequest *req = [[CNSaveRequest alloc] init];
        NSInteger end = MIN(count, i + batch);
        for (NSInteger j = i; j < end; j++) {
            CNMutableContact *c = [[CNMutableContact alloc] init];
            c.familyName = trRandomName(); // 全名放单字段（与真实联系人同构，避免"姓 名"顺序反）
            // 关系构成 → 号码 label；本地占比 → 手机号 vs 外地固话（区号按常住地区）
            double r = trRand01();
            double acc = 0;
            NSInteger rel = 0;
            for (NSInteger t = 0; t < 5; t++) { acc += w[t]; if (r < acc) { rel = t; break; } }
            NSString *phone;
            if (trRand01() < localRatio) {
                phone = trRandomPhone();
            } else {
                NSString *area = cityArea[city] ?: @"10";
                phone = [NSString stringWithFormat:@"0%@%ld%ld%ld%ld%ld%ld%ld%ld", area,
                         (long)trRandInt(2, 9), (long)trRandInt(0, 9), (long)trRandInt(0, 9),
                         (long)trRandInt(0, 9), (long)trRandInt(0, 9), (long)trRandInt(0, 9),
                         (long)trRandInt(0, 9), (long)trRandInt(0, 9)];
            }
            CNPhoneNumber *pn = [CNPhoneNumber phoneNumberWithStringValue:phone];
            c.phoneNumbers = @[[CNLabeledValue labeledValueWithLabel:labels[rel] value:pn]];
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
    NSString *killErr = trKillDaemon(@"contactsd");
    NSMutableDictionary *out = [@{@"ok": @YES, @"db": @"contacts", @"count": @(written)} mutableCopy];
    if (killErr) out[@"killError"] = killErr; else out[@"kill"] = @"contactsd";
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

@end
