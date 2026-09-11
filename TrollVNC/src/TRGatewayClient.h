/*
  TRGatewayClient - 内网群控网关注册/心跳客户端（BSD socket / TCP JSON 行协议）
  功能：读取预置网关配置(GatewayHost / GatewayToken)，生成并持久化设备 UUID，
       连接网关注册端口(固定 18081)，register 仅上报连接信息 + configs（2026-08-13，
       宪法 7.3），定时 hello，断线退避重连；设置变更时重发 register 保持 configs 新鲜。
       端口固定不可调：18081 注册 / 5901 VNC / 5801 HTTP 硬编码，不读 GatewayPort/Port/HttpPort。
*/
#ifndef TRGatewayClient_h
#define TRGatewayClient_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class TRWatchDog;

@interface TRGatewayClient : NSObject

+ (instancetype)sharedClient;

/// 读取 com.82flex.trollvnc 配置并开始连接（幂等）
- (void)start;

/// 停止连接与重连
- (void)stop;

/// 外部进程（App 设置页）配置变更通知（2026-08-20）：标记重发 register，
/// worker 线程 ≤5s 内拾取；网关地址变更由 worker 检测后主动断开重连（见 _connectAndRun）。
/// 由 trollvncmanager 的 prefs-changed darwin 通知处理链调用。
- (void)noteExternalPrefsChanged;

/// 设置服务重启处理器（由 trollvncmanager 注入，restart 命令触发）
/// @param handler 返回 YES 表示重启已发起
@property(nonatomic, copy, nullable) BOOL (^restartHandler)(void);

/// 服务进程守护实例（由 trollvncmanager 注入，供 service.* 能力访问属性与方法）
@property(nonatomic, strong, nullable) TRWatchDog *watchdog;

/// 网关连接状态（供 gateway.isConnected 能力查询）
@property(nonatomic, readonly) BOOL isConnected;

/// 当前重连退避延迟（秒，供 gateway.isConnected 能力查询）
@property(nonatomic, readonly) NSTimeInterval retryDelay;

/// 设备元数据快照（供 gateway.deviceInfo 能力查询）
@property(nonatomic, readonly) NSDictionary *deviceInfo;

/**
 * HTTP 回环调用本机 trollvncserver 5802 快照服务（screen.snapshot / screen.wait / screen.waitStable）。
 * 快照真身在画面进程（server）；manager 经 127.0.0.1 回环执行。挂起原语（wait/waitStable）
 * 会阻塞至条件满足或连接断开——必须在独立线程调用（隧道 invoke 路径已异步化）。
 * @param cid     隧道命令 id（登记进取消表，供 cancelLoopbackForId: 中断挂起；可 nil）
 * @param op      原语名（screen.snapshot / screen.wait / screen.waitStable）
 * @param params  参数字典（透传）
 * @return 响应 JSON 字典（含 ok 字段）；通信失败/被取消返回 nil
 */
- (NSDictionary *_Nullable)_loopbackScreenInvoke:(nullable id)cid
                                              op:(NSString *)op
                                          params:(NSDictionary *_Nullable)params;

/**
 * 取消挂起的快照回环（网关超时放弃后经 cmd:'cancel' 到达）：shutdown 挂起 fd 使阻塞 read 返回，
 * 挂起线程退出——防「AI 放弃等待而屏幕永不变」的设备端永久挂起泄漏（2026-09-15）。
 */
- (void)cancelLoopbackForId:(nullable id)cid;

@end

NS_ASSUME_NONNULL_END

#endif /* TRGatewayClient_h */
