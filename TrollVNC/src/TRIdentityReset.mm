/*
  TRIdentityReset - 换号身份锚清理实现（2026-08-28）
  分层流程（commit）：SecItem 定向删 → keychain-2.db 直删（先备份）→ 容器 NSUserDefaults 层
  → 无可清项返回 SOP。dryrun 只统计/列路径不写。
  守卫：agrp 匹配 = agrp 等于 bundleId，或 agrp 以 "." + bundleId 结尾（team 前缀形式）——
  其余行（含 NULL agrp、apple 系组、app group）一律不触碰。
*/

#if !__has_feature(objc_arc)
#error This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import <Security/Security.h>
#import <sqlite3.h>

#import "Logging.h"
#import "TRIdentityReset.h"

NSString * const kTRIdentityKeychainDbPath = @"/var/private/var/keychains/keychain-2.db";

@implementation TRIdentityReset

+ (BOOL)isValidBundleId:(NSString *)bundleId {
    if (![bundleId isKindOfClass:[NSString class]]) return NO;
    if (bundleId.length < 3 || bundleId.length > 128) return NO;
    if (![bundleId containsString:@"."]) return NO;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9\-\.]+$"
                                                                        options:0 error:nil];
    return [re numberOfMatchesInString:bundleId options:0 range:NSMakeRange(0, bundleId.length)] == 1;
}

/** 访问组匹配谓词（SQL 参数化）：agrp = ? 或 agrp 以 "." + bundleId 结尾 */
+ (NSString *)matchPredicateSQL {
    return @"(agrp = ?1 OR agrp LIKE ('%.' || ?1))";
}

/** 统计 + 枚举匹配的访问组（dryrun/commit 共用） */
+ (BOOL)countMatchedRows:(sqlite3 *)db
                bundleId:(NSString *)bundleId
                  table:(NSString *)table
                   count:(int *)outCount
                  groups:(NSMutableArray<NSString *> *)outGroups
                   error:(NSString **)outError {
    NSString *sql = [NSString stringWithFormat:@"SELECT COUNT(*), %@ FROM %@ WHERE %@",
                     (outGroups ? @"GROUP_CONCAT(DISTINCT agrp)" : @"0"),
                     table, [TRIdentityReset matchPredicateSQL]];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
        if (outError) *outError = [NSString stringWithFormat:@"%@ prepare: %s", table, sqlite3_errmsg(db)];
        return NO;
    }
    sqlite3_bind_text(stmt, 1, bundleId.UTF8String, -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) {
        if (outError) *outError = [NSString stringWithFormat:@"%@ step: %s", table, sqlite3_errmsg(db)];
        sqlite3_finalize(stmt);
        return NO;
    }
    if (outCount) *outCount = sqlite3_column_int(stmt, 0);
    if (outGroups) {
        const unsigned char *g = sqlite3_column_text(stmt, 1);
        if (g) {
            for (NSString *s in [[NSString stringWithUTF8String:(const char *)g] componentsSeparatedByString:@","])
                if (s.length) [outGroups addObject:s];
        }
    }
    sqlite3_finalize(stmt);
    return YES;
}

/** 执行删除（仅 commit；返回删除行数） */
+ (int)deleteMatchedRows:(sqlite3 *)db bundleId:(NSString *)bundleId table:(NSString *)table error:(NSString **)outError {
    NSString *sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@", table, [TRIdentityReset matchPredicateSQL]];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
        if (outError) *outError = [NSString stringWithFormat:@"%@ prepare: %s", table, sqlite3_errmsg(db)];
        return -1;
    }
    sqlite3_bind_text(stmt, 1, bundleId.UTF8String, -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        if (outError) *outError = [NSString stringWithFormat:@"%@ step: %s", table, sqlite3_errmsg(db)];
        return -1;
    }
    return sqlite3_changes(db);
}

/** 定位目标 App 数据容器（扫 /var/mobile/Containers/Data/Application/*，读 MCM 元数据） */
+ (nullable NSString *)findDataContainerForBundleId:(NSString *)bundleId {
    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *listErr = nil;
    NSArray *entries = [fm contentsOfDirectoryAtPath:root error:&listErr];
    if (!entries) return nil;
    for (NSString *entry in entries) {
        NSString *metaPath = [NSString stringWithFormat:@"%@/%@/.com.apple.mobile_container_manager_metadata.plist", root, entry];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        NSString *ident = meta[@"MCMMetadataIdentifier"];
        if ([ident isKindOfClass:[NSString class]] && [ident isEqualToString:bundleId])
            return [root stringByAppendingPathComponent:entry];
    }
    return nil;
}

+ (NSDictionary *)resetForBundleId:(NSString *)bundleId mode:(NSString *)mode {
    // 串行队列防并发写 keychain-2.db（设置页/脚本/0x50/5802 多入口直调，双击按钮或并发脚本会竞态备份文件）
    static dispatch_once_t once;
    static dispatch_queue_t q;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.trollvnc.identityReset", DISPATCH_QUEUE_SERIAL); });
    __block NSDictionary *result = nil;
    dispatch_sync(q, ^{ result = [self _resetForBundleIdInner:bundleId mode:mode]; });
    return result;
}

+ (NSDictionary *)_resetForBundleIdInner:(NSString *)bundleId mode:(NSString *)mode {
    if (![self isValidBundleId:bundleId])
        return @{@"ok": @NO, @"error": @"bundleId 非法（须为反向域名，3~128 字节含点）"};
    BOOL commit = [mode isEqualToString:@"commit"];
    if (!commit && ![mode isEqualToString:@"dryrun"])
        return @{@"ok": @NO, @"error": @"mode 须为 dryrun 或 commit"};

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"ok"] = @YES;
    result[@"bundleId"] = bundleId;
    result[@"mode"] = commit ? @"commit" : @"dryrun";
    NSMutableArray *warnings = [NSMutableArray array];
    NSMutableArray *sop = [NSMutableArray array];
    NSString *tier = @"none";

    // ===== 层 1：SecItem 按 access group 定向删（跨 App 访问受 keychain-access-groups 限制，预期被拒）=====
    NSMutableDictionary *secitem = [NSMutableDictionary dictionary];
    secitem[@"attempted"] = @NO;
    secitem[@"deleted"] = @0;
    if (commit) {
        secitem[@"attempted"] = @YES;
        NSDictionary *query = @{
            (__bridge NSString *)kSecClass: (__bridge NSString *)kSecClassGenericPassword,
            (__bridge NSString *)kSecAttrAccessGroup: bundleId
        };
        OSStatus st = SecItemDelete((__bridge CFDictionaryRef)query);
        secitem[@"status"] = @(st);
        if (st == errSecSuccess) {
            secitem[@"deleted"] = @1;
            tier = @"secitem";
        } else {
            // -34018 = 缺 entitlement（预期）；-25300 = 未找到
            secitem[@"error"] = [NSString stringWithFormat:@"OSStatus %d", (int)st];
        }
    } else {
        secitem[@"error"] = @"dryrun 跳过";
    }
    result[@"secitem"] = secitem;

    // ===== 层 2：keychain-2.db 定向删（genp/inet，agrp 白名单；删前整库备份）=====
    NSMutableDictionary *kc = [NSMutableDictionary dictionary];
    kc[@"dbPath"] = kTRIdentityKeychainDbPath;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL dbExists = [fm fileExistsAtPath:kTRIdentityKeychainDbPath];
    kc[@"dbExists"] = @(dbExists);
    int matchedGenp = 0, matchedInet = 0;
    NSMutableArray *groups = [NSMutableArray array];
    if (dbExists) {
        sqlite3 *db = NULL;
        if (sqlite3_open_v2(kTRIdentityKeychainDbPath.UTF8String, &db, SQLITE_OPEN_READWRITE, NULL) == SQLITE_OK) {
            sqlite3_busy_timeout(db, 3000);
            NSString *err = nil;
            NSMutableArray *genpGroups = [NSMutableArray array];
            NSMutableArray *inetGroups = [NSMutableArray array];
            [TRIdentityReset countMatchedRows:db bundleId:bundleId table:@"genp" count:&matchedGenp groups:genpGroups error:&err];
            [TRIdentityReset countMatchedRows:db bundleId:bundleId table:@"inet" count:&matchedInet groups:inetGroups error:&err];
            [groups addObjectsFromArray:genpGroups];
            [groups addObjectsFromArray:inetGroups];
            kc[@"matchedGenp"] = @(matchedGenp);
            kc[@"matchedInet"] = @(matchedInet);
            kc[@"groups"] = groups;
            if (err) kc[@"error"] = err;

            if (commit && (matchedGenp > 0 || matchedInet > 0)) {
                // 整库备份（同目录，带时间戳）
                NSString *backup = [NSString stringWithFormat:@"%@.bak-%lld",
                                    kTRIdentityKeychainDbPath, (long long)[NSDate date].timeIntervalSince1970];
                NSError *cpErr = nil;
                if ([fm copyItemAtPath:kTRIdentityKeychainDbPath toPath:backup error:&cpErr]) {
                    kc[@"backupPath"] = backup;
                    int deleted = 0;
                    int d1 = [TRIdentityReset deleteMatchedRows:db bundleId:bundleId table:@"genp" error:&err];
                    if (d1 >= 0) deleted += d1; else kc[@"error"] = err;
                    int d2 = [TRIdentityReset deleteMatchedRows:db bundleId:bundleId table:@"inet" error:&err];
                    if (d2 >= 0) deleted += d2; else kc[@"error"] = err;
                    kc[@"deleted"] = @(deleted);
                    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", NULL, NULL, NULL);
                    if (deleted > 0 && tier == @"none") tier = @"keychain-db";
                } else {
                    kc[@"error"] = [NSString stringWithFormat:@"备份失败（已中止删除）: %@",
                                    cpErr.localizedDescription ?: @""];
                }
            } else if (commit) {
                kc[@"deleted"] = @0;
            }
            sqlite3_close(db);
        } else {
            kc[@"error"] = @"keychain-2.db 打开失败（需 root）";
        }
    }
    result[@"keychain"] = kc;

    // ===== 层 3：数据容器 NSUserDefaults 层 =====
    NSMutableDictionary *container = [NSMutableDictionary dictionary];
    NSString *appContainer = [TRIdentityReset findDataContainerForBundleId:bundleId];
    container[@"found"] = @(appContainer != nil);
    if (appContainer) {
        container[@"path"] = appContainer;
        NSString *prefsPlist = [NSString stringWithFormat:@"%@/Library/Preferences/%@.plist", appContainer, bundleId];
        BOOL existed = [fm fileExistsAtPath:prefsPlist];
        container[@"prefsPlist"] = prefsPlist;
        container[@"prefsExisted"] = @(existed);
        NSMutableArray *cleared = [NSMutableArray array];
        if (commit && existed) {
            NSError *rmErr = nil;
            if ([fm removeItemAtPath:prefsPlist error:&rmErr]) {
                [cleared addObject:prefsPlist];
                if (tier == @"none") tier = @"container";
            } else {
                container[@"error"] = rmErr.localizedDescription ?: @"删除失败";
            }
        }
        container[@"clearedPaths"] = cleared;
    }
    result[@"container"] = container;

    // ===== 层 4：SOP（无可自动清理项时的兜底指引）=====
    if (commit && [tier isEqualToString:@"none"]) {
        tier = @"sop";
        [sop addObject:@"卸载目标 App 后重装（iOS 卸载默认保留 Keychain——本工具已尽力直清，仍不彻底时重装可清沙盒层残留）"];
        [sop addObject:@"设置 → 隐私与安全性 → 跟踪 → 关闭再打开「允许 App 请求跟踪」以重置广告标识符（IDFA 无 root 自动化路径）"];
        [sop addObject:@"换号后前几次操作避开与旧账号完全相同的点击坐标/节奏（配合 HumanizeTouch）"];
    }
    result[@"tier"] = tier;
    result[@"sop"] = sop;

    // ===== 通用警示 =====
    if (commit && (([kc[@"deleted"] intValue] ?: 0) > 0)) {
        [warnings addObject:@"securityd 存在 Keychain 缓存，删除可能需设备重启一次后才完全生效（本工具不代为重启，也绝不 kill securityd）"];
        [warnings addObject:@"已生成 keychain-2.db 整库备份（见 keychain.backupPath），确认无误后可手动删除"];
    }
    [warnings addObject:@"清理范围 = access group 恰为该 bundleId（或 team 前缀形式）的 Keychain 项 + 该 App 容器 NSUserDefaults；app group 共享锚不在覆盖范围"];
    result[@"warnings"] = warnings;
    return result;
}

@end
