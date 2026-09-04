/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 跨端定位模拟契约（单一真相源——App 与 daemon 两个 target 各自编译本模块，符号可链接）
/// 两端必须 import 本头引用常量，禁止在消费侧重写字面量
/// （kSimTrackFilePath 曾 App 与 SimLocationController 各持一份 static，2026-08-28 收敛）
/// 常量定义在 TRSimContract.mm（两端 target 都编译该 .mm；App 不编译 SimLocationController.mm，
/// 故契约必须独立成模块——对齐 TRWifiScanContract 模式）

/// 共享轨迹点序列 JSON 路径（App 写：编辑/上传轨迹；daemon 读：itinerary 注入）
extern NSString *const kTRSimTrackFilePath;

/// 轨迹播完通知（daemon notify_post → App notify_register_dispatch 订阅，2026-09-04）：
/// 播放态订阅终止信号——App 收到后执行与手动停止一致的复位（stopPlayback：locating=NO +
/// commitStop 写 off，App/daemon/plist 三方一致归停止态；位置订阅 locationd 不变，终点微动继续）
extern NSString *const kTRSimPlaybackFinishedNotification;

NS_ASSUME_NONNULL_END
