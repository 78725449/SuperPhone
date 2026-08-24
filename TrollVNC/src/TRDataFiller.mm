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

/// 通话：ZCALLRECORD 批量（ZDATE 秒 / ZDURATION / ZADDRESS 号码 BLOB / 拨入拨出比）
static NSDictionary *trFillCalls(NSInteger count, NSDictionary *ratios) {
    double outRatio = 0.5;
    NSNumber *r = ratios[@"outgoing"];
    if ([r isKindOfClass:[NSNumber class]]) outRatio = MIN(1.0, MAX(0.0, r.doubleValue));

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
        // 时间：近 30 天随机；时长：10s~30min 分布（短多长少）
        double ts = now - trRand01() * 30.0 * 86400.0;
        double dur = 10.0 + pow(trRand01(), 1.6) * 1790.0;
        BOOL outgoing = trRand01() < outRatio;
        NSString *sql = [NSString stringWithFormat:
            @"INSERT INTO ZCALLRECORD (Z_PK,Z_ENT,Z_OPT,ZANSWERED,ZCALLTYPE,ZDISCONNECTED_CAUSE,ZORIGINATED,ZREAD,ZVERIFICATIONSTATUS,ZHANDLE_TYPE,ZCALL_CATEGORY,ZDATE,ZDURATION,ZISO_COUNTRY_CODE,ZADDRESS,ZUNIQUE_ID,ZSERVICE_PROVIDER) "
            @"VALUES (%lld,%lld,1,1,1,0,%d,1,4,2,1,%.0f,%.1f,'CN',CAST('%@' AS BLOB),'%@','com.apple.Telephony')",
            pk, ent, outgoing ? 1 : 0, ts, dur, trRandomPhone(), [[NSUUID UUID] UUIDString]];
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

/// 短信：handle/chat/message/join 链批量（date 纳秒；收发比 is_from_me）
static NSDictionary *trFillSms(NSInteger count, NSDictionary *ratios) {
    double fromMeRatio = 0.5;
    NSNumber *r = ratios[@"incoming"];
    if ([r isKindOfClass:[NSNumber class]]) fromMeRatio = MIN(1.0, MAX(0.0, r.doubleValue)); // incoming = 收到的比例

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
        sqlite3_int64 dateNs = (sqlite3_int64)((now - trRand01() * 30.0 * 86400.0) * 1000000000.0);
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
        BOOL fromMe = trRand01() >= fromMeRatio; // fromMeRatio=incoming 收到的比例
        NSString *text = kSmsTexts()[trRandInt(0, (NSInteger)kSmsTexts().count - 1)];
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
static NSDictionary *trFillContacts(NSInteger count, NSDictionary *ratios) {
    (void)ratios;
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
            CNPhoneNumber *pn = [CNPhoneNumber phoneNumberWithStringValue:trRandomPhone()];
            c.phoneNumbers = @[[CNLabeledValue labeledValueWithLabel:CNLabelPhoneNumberMobile value:pn]];
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
