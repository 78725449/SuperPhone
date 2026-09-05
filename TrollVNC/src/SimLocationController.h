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
 * SimLocationController - 定位模拟注入控制器（daemon 侧执行引擎）
 *
 * 职责：驱动注入状态机（off / anchor / itinerary）；命令唯一入口 = UDS（startSimUDSServer）；
 * 崩溃后由 launchd/watchdog 拉起时按启动契约恢复（_forceStopOnStartup：关定位→注入上次位置→
 * 开定位→按 simstate mode 恢复，itinerary 放行续播）。
 *
 * 关键设计（2026-09-05 Q1/Q2 校准）：
 * - UDS 唯一命令通道（C1）：plist SimLocation* 命令键零读零写（reload/applyFromPrefs/
 *   scheduleReloadFromPrefs 状态机已整套退役）；plist 仅存非命令配置（SimRouterHTTP 等）
 * - 状态源（C11 持久化驱动）：simstate.json = daemon 独写的唯一执行态文件
 *   （currentPosition{lat,lon,acc,seq,trackVersion} + mode）；恢复链 = simstate 四合一恢复
 * - 命令三步模式：直调执行分支 → _persistState → push state/bssid 回执
 * - 位置真相 = locationd 广播（App 订阅）；注入始终运行（off/anchor/播完均保持注入+拟人微动）
 * - anchor（位置基底）：坐标由 UDS 命令显式传入（_startAnchorAtLat:lon:acc:，Q2 参数化，
 *   禁止读 plist 覆写）+ 拟人微动（静止为主 + 45s 刷新 + 偶发小迁移 5~20m）
 * - itinerary（轨迹推进）：simloc.json 点序列逐秒推进（seq/segIdx/trackVersion/bssidPlan 契约），
 *   播完自动终点微动
 * - WiFi 联动：计划固化（App 创建轨迹时两级反查 bssidPlan）→ daemon 按 seq 段下发（无感漫游，
 *   只改目标 BSSID）→ SCDynamicStore 常驻订阅（生命周期 = daemon 生命周期，停止不拆）→ evt=bssid 推 App
 * - 单一写入者：simloc.json 编排 = App 独写；simstate.json 执行态 = daemon 独写；无并发
 */
@interface SimLocationController : NSObject

+ (instancetype)sharedController;

/// manager 启动时调用（launchd/watchdog 拉起 = 崩溃/重启恢复场景）：执行启动契约后按 simstate mode 恢复
- (void)start;

/// daemon.restart 升级通道用（2026-08-28）：归 off 并落盘 simstate——防新 manager 启动契约
/// 恢复播放；系统定位关闭由重启后启动契约完成（宁无位置不漏真实）
+ (void)forceOffAndReload;

/// UDS 双向通道（2026-09-05 权威架构）：命令/回执内核必达通道（Unix Domain Socket）。
/// App 连接 sim.uds 后发命令 JSON 行（cmd=play/stop/anchor/query），daemon 执行后回执
/// state JSON 行 + evt=bssid 当前连接；执行态任何变更主动推送回执——App UI 由此对齐 daemon 真相。
/// manager 启动时调用。
+ (void)startSimUDSServer;

/// 执行态变更时推送回执给已连接的 App（UDS 命令处理完成/播完复位/连接建立等所有状态变更点调用）
+ (void)pushSimStateToApp;

@end

NS_ASSUME_NONNULL_END
