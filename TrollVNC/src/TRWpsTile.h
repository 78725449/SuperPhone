#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/// 单个 AP（BSSID + WGS-84 坐标）
@interface TRWpsTileAP : NSObject
@property (nonatomic, copy) NSString *bssid;   // 标准格式 XX:XX:XX:XX:XX:XX
@property (nonatomic, assign) CLLocationCoordinate2D coord;
@end

/// 坐标→BSSID 动态反查（共享模块：App 标注 + daemon 注入双消费方）
/// 协议：GET gspe85-cn-ssl.ls.apple.com/wifi_request_tile + X-tilekey(morton)，响应纯 protobuf
/// URL 已追加 ?tk=<tilekey> 作 CDN cache-buster（金山云 CDN 缓存键只含 URL、不含 X-tilekey header，
/// 曾致所有瓦片命中同一份陈旧缓存固定响应；origin 按 header 取数、忽略 query，2026-08-27 实测）
/// 设计文档 §坐标→SSID 反查：动态+预取混合，本类提供动态查询 + LRU 瓦片缓存
@interface TRWpsTile : NSObject

+ (instancetype)sharedClient;

/// 按坐标反查该位置附近真实 BSSID（level 13 瓦片；同瓦片 LRU 缓存复用）
/// @param coord   WGS-84 坐标（模拟当前位置）
/// @param force   强制刷新（忽略缓存，轨迹预取用）
/// completion 主队列；aps 非空 = 命中；error 非 nil = 网络/HTTP/解析失败
- (void)queryBssidsForCoordinate:(CLLocationCoordinate2D)coord
                           force:(BOOL)force
                      completion:(void (^)(NSArray<TRWpsTileAP *> *aps, NSError *_Nullable error))completion;

/// 清理缓存（瓦片失效/城市切换时）
- (void)clearCache;

/// 计算坐标所属瓦片 key（level 13，morton；供跨瓦片变更检测——轨迹移动跨瓦片才重反查）
+ (uint64_t)tileKeyForCoordinate:(CLLocationCoordinate2D)coord;

/// 跨瓦片判定共享原语（App/daemon 双消费，语义一致）：
/// 计算 coord 所属瓦片 key 并与 previous 比较。返回 YES = 已跨瓦片（*newKey 输出新 key，
/// 消费方应重新反查并记录）；返回 NO = 同瓦片（*newKey 保持 previous 值，消费方跳过）。
+ (BOOL)tileChangedForCoordinate:(CLLocationCoordinate2D)coord
                        previous:(uint64_t)previous
                          newKey:(uint64_t *)newKey;

/// BSSID 采样共享原语（cap 上限；daemon 注入与 App 标注同源，消除"注入 100/标注全量"不对称）
+ (NSArray<NSString *> *)sampleBssidsFromAPs:(NSArray<TRWpsTileAP *> *)aps max:(NSUInteger)max;

@end

NS_ASSUME_NONNULL_END
