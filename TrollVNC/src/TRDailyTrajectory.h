//
//  TRDailyTrajectory.h
//  每日轨迹（2026-08-26）：真人行为模拟——每天随机少量通话/短信/未接，
//  manager daemon 自治调度（root 常驻，不依赖外部触发/App 存活/网关在线）。
//  默认开启；数据操作走 TRDataFiller（App 伪装页同源），不暴露任何外部入口。
//

#import <Foundation/Foundation.h>

@interface TRDailyTrajectory : NSObject

/// manager 启动时调用：注册每小时 tick（GCD 后台队列递归），并立即执行一次首检
+ (void)start;

@end
