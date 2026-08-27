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
 * （off / anchor / itinerary），并在 manager 启动/配置变更/失效时自治恢复。
 *
 * 关键设计（对齐《改定位-编码AI执行规格.md》§3.2）：
 * - 参数双域读取：root 域（网关 setConfig 写入）→ mobile 域 plist 回退（App/5801 写入）
 * - 失效巡检 + 参数变更感知合一：10s 定时器，比对参数缓存 + 检查注入状态
 * - anchor（位置基底）：中心点 + 微动游走（微步随机游走 + 回中，拟人必需）
 * - itinerary（动作序列）：轨迹文件逐秒推进（方案 C append-only，不 restart），完成后保持终点
 * - 当前位置 _current 每次注入后更新，供 status 查询 / 编排初始起点 / 失效恢复
 * - 只感知参数，不改 setConfig 分发机制（instant 语义由本控制器轮询感知）
 */
@interface SimLocationController : NSObject

+ (instancetype)sharedController;

/// manager 启动时调用：恢复上次模式 + 启动 10s 巡检
- (void)start;

/// prefs-changed 通知后调用：重读参数并应用（加速生效，巡检仍是兜底）
- (void)reloadFromPrefs;

/// prefs-changed 通知入口（合并窗口 500ms）：App 一次编辑链连发多次通知时合并为一次重载
/// （防热重载风暴，2026-08-27；manager 订阅回调请调此方法而非 reloadFromPrefs）
- (void)scheduleReloadFromPrefs;

/// 上传轨迹点序列（App 定位 UI/算路模块直调；2026-08-26 起注册表 sim.location.track 已移除）：
/// 校验坐标范围 → 原子写轨迹文件（临时文件 rename）→ 写 SimLocationMode=itinerary
/// @return YES 成功；NO 失败并置 error
+ (BOOL)uploadTrackPoints:(NSArray<NSDictionary *> *)points error:(NSError **)error;

/// 当前位置状态（App/daemon 查询当前注入状态；2026-08-26 起注册表 sim.location.status 已移除）：{mode, lat, lon, speed, course}
+ (NSDictionary *)currentStatus;

@end

NS_ASSUME_NONNULL_END
