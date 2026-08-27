/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 跨端 WiFi 主动扫描契约（单一真相源——App 与 daemon 两个 target 各自编译本模块，符号可链接）
/// 两端必须 import 本头引用常量，禁止在消费侧重写字面量（曾致两端各持一份、改一处忘一处）
/// 常量定义在 TRWifiScanContract.mm（两端 target 都编译该 .mm；App 不编译 TRWifiActiveScanner.mm，
/// 故契约必须独立成模块而非挂在扫描器类上——2026-08-28 定案）

/// 共享扫描结果 JSON 路径（root daemon 写；mobile 用户 App 可读）
extern NSString *const kTRWifiScanJsonPath;
/// 扫描更新 Darwin 通知名（daemon notify_post → App notify_register_dispatch 订阅）
extern NSString *const kTRWifiScanUpdatedNotification;
/// 立即重扫请求通知名（App 关模拟时 notify_post → daemon requestScanNow）
extern NSString *const kTRWifiScanRequestNotification;

NS_ASSUME_NONNULL_END