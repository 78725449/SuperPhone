/*
  TRWifiKnownNetworks - 已知网络条目修改器（实现，2026-08-29）
  数据结构实证见头文件；写盘用 plist 二进制（与系统一致），修改后通知 wifid。
*/
#import "TRWifiKnownNetworks.h"
#import <spawn.h>   // posix_spawn（wifid 重载通知；模块化编译需显式 import）

static NSString *const kKnownNetworksPath = @"/var/preferences/com.apple.wifi.known-networks.plist";

@implementation TRWifiKnownNetworks

+ (BOOL)renameKnownNetworkSSID:(NSString *)oldSSID to:(NSString *)newSSID error:(NSError **)error {
    if (!oldSSID.length || !newSSID.length || [oldSSID isEqualToString:newSSID]) {
        if (error) *error = [NSError errorWithDomain:@"TRWifiKN" code:1
                             userInfo:@{NSLocalizedDescriptionKey: @"SSID 参数非法"}];
        return NO;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kKnownNetworksPath]) {
        if (error) *error = [NSError errorWithDomain:@"TRWifiKN" code:2
                             userInfo:@{NSLocalizedDescriptionKey: @"known-networks.plist 不存在"}];
        return NO;
    }
    // 1) 备份（与 identity.reset 同款 .bak 纪律）
    NSString *bak = [kKnownNetworksPath stringByAppendingString:@".bak-trv"];
    [fm removeItemAtPath:bak error:NULL];
    if (![fm copyItemAtPath:kKnownNetworksPath toPath:bak error:NULL]) {
        if (error) *error = [NSError errorWithDomain:@"TRWifiKN" code:3
                             userInfo:@{NSLocalizedDescriptionKey: @"备份失败，中止"}];
        return NO;
    }
    // 2) 读 plist
    NSData *data = [NSData dataWithContentsOfFile:kKnownNetworksPath];
    NSMutableDictionary *plist = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListMutableContainersAndLeaves format:NULL error:error];
    if (![plist isKindOfClass:[NSMutableDictionary class]]) {
        if (error) *error = [NSError errorWithDomain:@"TRWifiKN" code:4
                             userInfo:@{NSLocalizedDescriptionKey: @"known-networks.plist 解析失败"}];
        return NO;
    }
    // 3) 找旧条目（键名可能带特殊字符——用 SSID data 匹配）
    NSString *oldKey = [@"wifi.network.ssid." stringByAppendingString:oldSSID];
    NSString *newKey = [@"wifi.network.ssid." stringByAppendingString:newSSID];
    NSMutableDictionary *entry = plist[oldKey];
    if (![entry isKindOfClass:[NSMutableDictionary class]]) {
        // 键名直接匹配失败——尝试按 SSID data 内容匹配（SSID 含特殊字符时键名编码不同）
        for (NSString *k in [plist allKeys]) {
            NSDictionary *e = plist[k];
            NSData *sd = e[@"SSID"];
            if ([sd isKindOfClass:[NSData class]] &&
                [[NSString alloc] initWithData:sd encoding:NSUTF8StringEncoding] == oldSSID) {
                entry = [e mutableCopy];
                oldKey = k;
                break;
            }
        }
    }
    if (!entry) {
        if (error) *error = [NSError errorWithDomain:@"TRWifiKN" code:5
                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"已知网络无条目 %@", oldSSID]}];
        return NO;
    }
    // 4) 改条目：SSID data + 移到新键（保留加密/密码/BSSList 等全部字段）
    entry[@"SSID"] = [newSSID dataUsingEncoding:NSUTF8StringEncoding];
    [plist removeObjectForKey:oldKey];
    plist[newKey] = entry;
    // 5) 写回（二进制 plist，与系统一致）
    NSData *out = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0
                                                            options:0 error:error];
    if (!out) return NO;
    if (![out writeToFile:kKnownNetworksPath options:NSDataWritingAtomic error:error]) return NO;
    // 6) 通知 wifid 重载（先试 kickstart；失败不阻塞——iOS 搜索已知网络时可能自行重读）
    @try {
        pid_t pid = 0;
        char *args[] = { (char *)"launchctl", (char *)"kickstart", (char *)"system/com.apple.wifid", NULL };
        posix_spawn(&pid, "/bin/launchctl", NULL, NULL, args, NULL);
    } @catch (NSException *ex) {
        // 忽略——通知非关键
    }
    return YES;
}

/// ipconfig getsummary en0 解析当前连接（root 可用、无需 TCC——
/// CNCopyCurrentNetworkInfo 在 root daemon 无 App 授权上下文时不返回，2026-08-29 实测）
+ (nullable NSString *)_valueFromIPConfig:(NSString *)key {
    // 绝对路径：daemon 环境 PATH 可能为空（server spawn manager 时只传语言码 env）
    FILE *fp = popen("/usr/sbin/ipconfig getsummary en0 2>/dev/null", "r");
    if (!fp) return nil;
    NSString *result = nil;
    char line[512];
    // 前导空格避免匹配 "BSSID :"（BSSID 包含 SSID 子串）
    NSString *pat = [NSString stringWithFormat:@" %@ :", key];
    while (fgets(line, sizeof(line), fp)) {
        NSString *l = [NSString stringWithCString:line encoding:NSUTF8StringEncoding];
        NSRange r = [l rangeOfString:pat];
        if (r.location != NSNotFound) {
            NSString *v = [[l substringFromIndex:NSMaxRange(r)]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (v.length) { result = v; break; }
        }
    }
    pclose(fp);
    return result;
}

+ (nullable NSString *)currentSSID {
    // 仅走 ipconfig（root 可用、实测有效）；CNCopyCurrentNetworkInfo 已删——
    // 它在 root daemon 无 TCC 授权上下文下不返回（2026-08-29 实测证伪，保留只会混淆）
    return [self _valueFromIPConfig:@"SSID"];
}

+ (nullable NSString *)currentBSSID {
    return [self _valueFromIPConfig:@"BSSID"];
}

@end