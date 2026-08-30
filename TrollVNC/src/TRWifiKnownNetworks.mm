/*
  TRWifiKnownNetworks - 已知网络条目修改器（实现，2026-08-29）
  数据结构实证见头文件；写盘用 plist 二进制（与系统一致），修改后通知 wifid。
*/
#import "TRWifiKnownNetworks.h"
#import <spawn.h>   // posix_spawn（wifid 重载通知；模块化编译需显式 import）
#import <SystemConfiguration/SystemConfiguration.h> // SCDynamicStore 读当前连接 WiFi（2026-08-30 真机验证：iOS 可用，替代 popen/ipconfig）

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

/// 用 SCDynamicStore 读当前连接 WiFi 状态字典（2026-08-30：真机验证 iOS 可用，替代 popen/ipconfig——
/// daemon 环境 popen 受限致 currentSSID 空、AP 下发被 no current ssid 跳过；SCDynamicStore 纯系统 API 无 shell 依赖）
+ (nullable NSDictionary *)_airportState {
    SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("com.82flex.trollvnc.wifi"), NULL, NULL);
    if (!store) return nil;
    CFPropertyListRef val = SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Interface/en0/AirPort"));
    CFRelease(store);
    if (!val) return nil;
    NSDictionary *dict = [(__bridge NSDictionary *)val copy];
    CFRelease(val);
    return dict;
}

+ (nullable NSString *)currentSSID {
    // 真机实测（2026-08-30）：键字典 SSID_STR 是 NSString（如"时来运转"），SSID 是 NSData（UTF-8 字节）——
    // 优先 SSID_STR；异常情况降级解码 SSID data
    NSDictionary *st = [self _airportState];
    if (!st) return nil;
    NSString *str = st[@"SSID_STR"];
    if (str.length) return str;
    NSData *data = st[@"SSID"];
    if (data.length) return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return nil;
}

+ (nullable NSString *)currentBSSID {
    // 真机实测：BSSID 是 6 字节 NSData（如 0xa477589f0039），格式化为 mac 字符串 a4:77:58:9f:00:39
    NSDictionary *st = [self _airportState];
    if (!st) return nil;
    NSData *data = st[@"BSSID"];
    if (data.length != 6) return nil;
    const uint8_t *b = (const uint8_t *)data.bytes;
    return [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x",
            b[0], b[1], b[2], b[3], b[4], b[5]];
}

@end