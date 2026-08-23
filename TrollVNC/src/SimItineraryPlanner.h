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
 * SimItineraryPlanner - 定位编排器（sim.itinerary 能力执行）
 *
 * 对齐《改定位-编码AI执行规格.md》§3.3.4：
 * - 输入 segments 动作序列：route（沿真实道路算路）/ region（区域漫游）/ anchor（终点基底）
 * - 段起点静态绑定（编排连续性命门）：seg1 起点 = 提交时刻 _current；seg_i 起点 = seg_{i-1} 终点
 *   （生成时确定，不实时读坐标；运行时 _current 是播放进度，不参与段间拼接）
 * - 逐段串行生成拼接（route 段联网算路异步；region 段同步生成；anchor 段不生成序列）
 * - 拼接完整点序列后原子落盘 + 切 SimLocationMode=itinerary，由 SimLocationController 自治推进
 * - 异步执行：invoke 5s 超时内无法等待算路，本类异步跑，调用方立即收到 calculating ack
 */
@interface SimItineraryPlanner : NSObject

/// 提交编排（异步）：段起点静态绑定 + 逐段生成拼接 → 落盘 + 切 itinerary → completion
/// @param segments [{type:'route', to:{lat,lon}, mode}, {type:'region', radius, mode, durationMin}, {type:'anchor', point?}]
/// @param completion result={ok,count}；error 非 nil 时编排失败（不落盘）
+ (void)submitItinerary:(NSArray<NSDictionary *> *)segments
             completion:(void (^)(NSDictionary *result, NSError *error))completion;

@end

NS_ASSUME_NONNULL_END
