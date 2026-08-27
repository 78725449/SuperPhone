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

@end

NS_ASSUME_NONNULL_END
