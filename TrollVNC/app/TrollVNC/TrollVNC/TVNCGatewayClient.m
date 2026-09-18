/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "TVNCGatewayClient.h"
// kTRAppPrefsSuiteName（跨端 prefs 域契约，2026-08-28）。双路径 __has_include（对齐 TVNCUtil.h）：
#if __has_include("../../../src/TRAppDomain.h")
#import "../../../src/TRAppDomain.h"
#else
#import "TRAppDomain.h"
#endif

#import <Security/Security.h>

/// 网关 HTTP 控制台端口（固定 8080 不可调，trollvnc-farm FARM_PORT）
static const NSInteger kGatewayDefaultConsolePort = 8080;
/// 配置 Suite 名 → kTRAppPrefsSuiteName（TRAppDomain.h 跨端单一真相源，2026-08-28）
/// 网关地址配置键
static NSString *const kGatewayHostKey = @"GatewayHost";
/// 网关 Token 配置键
static NSString *const kGatewayTokenKey = @"GatewayToken";

@interface TVNCGatewayClient () <NSURLSessionDelegate>
- (void)fetchDevicesAllowProtocolFallback:(BOOL)allowFallback
                               completion:(void (^)(NSArray<NSDictionary *> *_Nullable, NSError *_Nullable))completion;
@end

@implementation TVNCGatewayClient

+ (instancetype)sharedClient {
    static TVNCGatewayClient *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

#pragma mark - 配置（实时读取，设置是唯一默认源）

/// 读取当前网关地址（未配置返回 nil）。
- (nullable NSString *)gatewayHost {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    return [d stringForKey:kGatewayHostKey];
}

/// 读取当前网关 HTTP 端口（固定 8080 不可调）。
- (NSInteger)gatewayPort {
    return kGatewayDefaultConsolePort;
}

/**
 * 当前使用的网关协议（"https" / "http"）。
 *
 * 背景（2026-09-18 真机定位）：网关【设计上默认启用 TLS】（trollvnc-farm 的
 * FARM_TLS !== '0' → https + 自签证书，本类 didReceiveChallenge 信任它），
 * 但允许用 FARM_TLS=0 以纯 HTTP 运行（调试/内网无 TLS 场景）。
 * 本类原先固定拼 "https://"，一旦网关以 HTTP 启动，App 的 https 请求必然握手失败，
 * 表现为 Hero 卡「网关不可达，请检查网关配置」——而 manager 走 TCP 18081 注册不受影响，
 * 于是出现「网关侧 online=true、设备 App 却报不可达」的两边状态不一致。
 * 现改为记协议并自适应：默认 https（保持原设计），握手失败自动降级 http 并记住。
 */
static NSString *const kGatewaySchemeKey = @"GatewayScheme";

- (NSString *)gatewayScheme {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    NSString *s = [d stringForKey:kGatewaySchemeKey];
    return [s isEqualToString:@"http"] ? @"http" : @"https"; // 缺省 https（原设计）
}

- (void)setGatewayScheme:(NSString *)scheme {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    [d setObject:scheme forKey:kGatewaySchemeKey];
    [d synchronize];
}

/**
 * 判定"协议不匹配"类错误（对端不是当前协议的服务），用于决定是否切换协议重试。
 *
 * 只覆盖【协议错配】的形态，不覆盖纯网络故障——否则网关真的不可达时也会去试另一协议，
 * 白等一个 timeout，还掩盖了真实故障。实测：对纯 HTTP 服务发 https 请求，
 * iOS 常报 -1200（SecureConnectionFailed），个别版本报 -1004/-1005/-1017。
 */
static BOOL tvIsProtocolMismatchError(NSError *err) {
    if (!err || ![err.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (err.code) {
        case NSURLErrorSecureConnectionFailed:   // -1200：TLS 握手失败（明文服务收到 ClientHello）
        case NSURLErrorServerCertificateUntrusted: // -1202
        case NSURLErrorCannotConnectToHost:      // -1004
        case NSURLErrorNetworkConnectionLost:    // -1005
        case NSURLErrorCannotParseResponse:      // -1017
            return YES;
        default:
            return NO;
    }
}

/// 读取当前网关 Token（可为空字符串）。
- (nullable NSString *)gatewayToken {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    return [d stringForKey:kGatewayTokenKey];
}

#pragma mark - 请求构造

/// 构造网关基础 URL：<scheme>://host:port/api/...（host 未配置返回 nil）。
/// scheme 取自 gatewayScheme（默认 https，握手失败自动降级 http 并记住，见该属性注释）。
/// 网关默认启用 https（自签证书，见 trollvnc-farm §2.3m）；证书信任由 tlsTrustingSession 的 challenge 处理。
- (nullable NSURL *)apiURLWithPath:(NSString *)path {
    NSString *host = [self gatewayHost];
    if (!host.length) return nil;
    NSInteger port = [self gatewayPort];
    NSString *urlStr = [NSString stringWithFormat:@"%@://%@:%ld%@", [self gatewayScheme], host, (long)port, path];
    return [NSURL URLWithString:urlStr];
}

/// 懒加载 URLSession：信任网关自签证书（内网自签边界，与"无鉴权内网"设计一致）。
/// @return 带自签信任的 URLSession
- (NSURLSession *)tlsTrustingSession {
    static NSURLSession *session = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 6.0;
        session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    });
    return session;
}

/**
 * TLS 挑战处理：网关为内网自签证书，信任 serverTrust。
 * @param challenge 认证挑战
 * @param completionHandler 完成回调
 */
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        SecTrustRef trust = challenge.protectionSpace.serverTrust;
        if (trust) {
            completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
            return;
        }
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

/// 构造通用请求：注入 Bearer Token 与 JSON 头。
/// @param url    目标 URL
/// @param method HTTP 方法（GET/POST）
/// @param body   请求体（GET 传 nil）
/// @return 配置完成的请求
- (NSMutableURLRequest *)requestWithURL:(NSURL *)url method:(NSString *)method body:(NSData *_Nullable)body {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method;
    req.timeoutInterval = 6.0;
    NSString *token = [self gatewayToken];
    if (token.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
    if (body) {
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = body;
    }
    return req;
}

/// 在主线程派发回调（网络完成回调默认在后台线程）。
- (void)dispatchOnMain:(void (^)(void))block {
    if (block) {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

/// 解析响应 JSON 为字典（非字典/解析失败返回 nil）。
- (NSDictionary *)parseJSONDictionary:(NSData *)data {
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

#pragma mark - Public API

- (void)fetchDevicesWithCompletion:(void (^)(NSArray<NSDictionary *> *_Nullable, NSError *_Nullable))completion {
    [self fetchDevicesAllowProtocolFallback:YES completion:completion];
}

/**
 * 拉取设备目录（内部实现，带一次协议降级重试）。
 *
 * @param allowFallback 是否允许在协议不匹配时切换协议并重试一次（递归时传 NO 防死循环）
 * @param completion    结果回调（主线程）
 *
 * 协议自适应（2026-09-18）：网关可能以 https（默认）或 http（FARM_TLS=0）启动，
 * 两者 App 都应当能用。首次请求用记住的协议；若报"协议不匹配"，切换后【重试一次】并记住新协议，
 * 后续请求直接走对的那个。递归深度最多 2（https↔http），不会反复。
 */
- (void)fetchDevicesAllowProtocolFallback:(BOOL)allowFallback
                               completion:(void (^)(NSArray<NSDictionary *> *_Nullable, NSError *_Nullable))completion {
    NSURL *url = [self apiURLWithPath:@"/api/devices"];
    if (!url) {
        [self dispatchOnMain:^{
            if (completion) completion(nil, [NSError errorWithDomain:@"TVNCGateway" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"未配置网关地址"}]);
        }];
        return;
    }
    NSString *usedScheme = [self gatewayScheme];
    NSURLRequest *req = [self requestWithURL:url method:@"GET" body:nil];
    NSURLSessionDataTask *task = [[self tlsTrustingSession] dataTaskWithRequest:req
                                                                 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray<NSDictionary *> *devices = nil;
        if (!err && data) {
            NSDictionary *json = [self parseJSONDictionary:data];
            id list = json[@"devices"];
            if ([list isKindOfClass:[NSArray class]]) devices = list;
        }
        // 协议不匹配 → 切换协议重试一次（并记住正确的协议，后续请求直接命中）
        if (!devices && allowFallback && tvIsProtocolMismatchError(err)) {
            NSString *other = [usedScheme isEqualToString:@"https"] ? @"http" : @"https";
            [self setGatewayScheme:other];
            NSLog(@"[TVNCGateway] %@ 请求失败(code=%ld)，切换协议为 %@ 重试", usedScheme, (long)err.code, other);
            [self fetchDevicesAllowProtocolFallback:NO completion:completion];
            return;
        }
        [self dispatchOnMain:^{
            if (completion) completion(devices, err);
        }];
    }];
    [task resume];
}

@end
