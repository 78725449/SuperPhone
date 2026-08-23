/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * SimLocationController - 改定位自治控制器（正式实现）
 *
 * 职责：读取 defaults 中的 SimLocation* 参数（配置型建模），驱动注入状态机
 * （off / static / track），并在 manager 启动/配置变更/失效时自治恢复。
 *
 * 关键设计（对齐《改定位-编码AI执行规格.md》§3.2）：
 * - 参数双域读取：root 域（网关 setConfig 写入）→ mobile 域 plist 回退（App/5801 写入）
 * - 失效巡检 + 参数变更感知合一：10s 定时器，比对参数缓存 + 检查注入状态
 * - track 用 mode A（每秒注入一点，Andromeda 实证姿势），完成后保持终点不 stop
 * - 只感知参数，不改 setConfig 分发机制（instant 语义由本控制器轮询感知）
 */
@interface SimLocationController : NSObject

+ (instancetype)sharedController;

/// manager 启动时调用：恢复上次模式 + 启动 10s 巡检
- (void)start;

/// prefs-changed 通知后调用：重读参数并应用（加速生效，巡检仍是兜底）
- (void)reloadFromPrefs;

@end

NS_ASSUME_NONNULL_END
