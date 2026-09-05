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
 * 职责：读取 mobile 域 plist 的 SimLocation* 命令参数，驱动注入状态机
 * （off / anchor / itinerary）；由 prefs-changed 通知触发重载；崩溃后由
 * launchd/watchdog 拉起时按启动契约恢复（见 start）。
 *
 * 关键设计（现状，2026-09-04 校准）：
 * - 命令/状态分离：plist SimLocationMode 是 App→daemon 的命令（非状态回读）；
 *   daemon 执行态为内部 _currentMode；App 播放态由其自行维护（播完复位通知为规划项，未落地）
 * - 启动契约（App 与 daemon 不对称）：App 重启 = readCurrentStatus 强制 off（宁停不漏）；
 *   daemon 重启 = 先关定位 → 注入上次位置（simstate.json）→ itinerary 放行恢复播放（崩溃恢复）
 * - 位置真相 = locationd 广播（App 订阅）；注入始终运行（off/anchor/播完均保持注入+拟人微动）
 * - anchor（位置基底）：中心点 + 拟人微动（静止为主 + 45s 刷新 + 偶发小迁移 5~20m）
 * - itinerary（轨迹推进）：simloc.json 点序列逐秒推进（seq/segIdx/trackVersion 契约），播完自动终点微动
 * - WiFi 联动：WPS 瓦片反查 → 软路由改 {SSID,BSSID} → SCDynamicStore 监听重连（2026-08-29 起，替代已废弃的扫描结果注入）
 * - 单一写入者：simloc.json 编排 = App 独写；simstate.json 注入进度 = daemon 独写；无并发
 */
@interface SimLocationController : NSObject

+ (instancetype)sharedController;

/// manager 启动时调用（launchd/watchdog 拉起 = 崩溃/重启恢复场景）：执行启动契约后按残留模式恢复
- (void)start;

/// 重读参数并应用（模式切换立即执行；参数未变跳过——巡检已移除，配置驱动 notify 覆盖）
- (void)reloadFromPrefs;

/// prefs-changed 通知入口（合并窗口 500ms）：App 一次编辑链连发多次通知时合并为一次重载
/// （防热重载风暴，2026-08-27；manager 订阅回调请调此方法而非 reloadFromPrefs）
- (void)scheduleReloadFromPrefs;

/// daemon.restart 升级通道用（2026-08-28）：升级退出前写 off 并重载——防新 manager 启动契约
/// 读到残留 itinerary 恢复播放；系统定位关闭由重启后启动契约完成（宁无位置不漏真实）
+ (void)forceOffAndReload;

/// UDS 双向通道（2026-09-05 权威架构）：命令/回执内核必达通道（Unix Domain Socket）。
/// App 连接 sim.uds 后发命令 JSON 行（cmd=play/stop/anchor），daemon 执行后回执状态 JSON 行；
/// 执行态任何变更（applyFromPrefs/播完复位）主动推送回执——App UI 由此对齐 daemon 真相。
/// manager 启动时调用；plist+notify 命令路径保留并存（兜底），验证后退役。
+ (void)startSimUDSServer;

/// 执行态变更时推送回执给已连接的 App（applyFromPrefs 完成/播完复位等所有状态变更点调用）
+ (void)pushSimStateToApp;

@end

NS_ASSUME_NONNULL_END
