#import <Foundation/Foundation.h>

/**
 * TRTunnelClient - 设备侧隧道客户端
 * 功能：设备注册到网关成功后，自动建立到网关 18181 端口的隧道连接，
 *       用于跨网络访问时的 RFB/控制流量透传。
 * 单例模式，仿 TRGatewayClient 连接管理风格。
 */
@interface TRTunnelClient : NSObject

/** 获取共享单例 */
+ (instancetype)sharedClient;

/** 隧道是否已连接 */
@property (nonatomic, readonly) BOOL isConnected;

/**
 * 启动隧道客户端，建立到网关 18181 的连接
 * @param gatewayHost 网关主机地址
 * @param gatewayPort 网关隧道端口（默认 18181）
 * @param deviceId 设备 ID（用于鉴权握手）
 * @param token 网关鉴权 token（可为 nil）
 * @return YES 表示启动成功（异步连接），NO 表示参数无效
 */
- (BOOL)startWithHost:(NSString *)gatewayHost
                 port:(NSInteger)gatewayPort
             deviceId:(NSString *)deviceId
                token:(NSString *)token;

/** 停止隧道客户端，断开连接 */
- (void)stop;

/**
 * 命令处理器（隧道 CMD 帧到达时调用，返回 ack 字典）
 * 由 TRGatewayClient 注入，复用现有命令处理逻辑（query/set/invoke/restart/ping）。
 * @param cmd 网关通过隧道下发的命令字典（{type:"cmd", cmd, id, ...}）
 * @return ack 字典（{type:"ack", cmd, id, ok, ...}），将通过 CMDACK 帧回传网关；
 *         返回 @{@"pendingAsync": @YES} 表示已异步接管，稍后必须经 sendCmdAckForId:ack: 回写
 */
@property (nonatomic, copy, nullable) NSDictionary *(^commandHandler)(NSDictionary *cmd);

/**
 * 异步回写 CMDACK（配合 commandHandler 的 pendingAsync 语义，2026-09-15 快照服务）：
 * 长挂起原语（screen.wait / screen.waitStable）由独立线程经 HTTP 回环等待，完成后回写。
 * 线程安全（内部 _writeFrame 自带写锁）；隧道已断开时静默失败。
 * @param cid 原命令 id（NSString 或 NSNumber，原样回传网关）
 * @param ack 应答字典（自动补 type/id 字段）
 * @return YES 写入成功；NO 隧道不可用
 */
- (BOOL)sendCmdAckForId:(nullable id)cid ack:(NSDictionary *)ack;

/**
 * 请求断开所有隧道会话通道（5801 直连接管时调用，2026-08-23）：
 * 仅置线程安全标志，隧道 worker 线程在 select 循环内统一关闭会话通道（reason=1 通知网关
 * 清理会话 → 网关前端断开），并自动降频 + 上报被控结束；chan 0 缩略图通道保留。
 * 无会话通道时为 no-op。5801 直连因此「默认断开网关控制直接接管」。
 */
- (void)requestKickSessions;

@end
