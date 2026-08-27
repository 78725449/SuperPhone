#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/// 可见窗口大小（单一真相源：daemon 注入与 App 标注共用同一窗口参数，2026-08-28）
extern const NSUInteger kTRWpsWindowSize;

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

/// 距离窗口共享原语（2026-08-28，模拟真实设备移动时可见 AP）：对瓦片 AP 集按"与模拟位置距离"
/// 升序排序并取前 window 个作为可见集——真实设备可见 AP = 信号范围内（近强远弱），位置移动 →
/// 可见集自然渐进变化（daemon 注入与 App 标注共用同一窗口与参数，消除两端脱节）。
/// @param aps    瓦片 AP 集（含坐标，来自 queryBssidsForCoordinate / 螺旋回退）
/// @param center 模拟当前位置（WGS-84）
/// @param window 可见窗口大小（默认 30；RSSI 可见阈值近似）
+ (NSArray<TRWpsTileAP *> *)windowApsByDistance:(NSArray<TRWpsTileAP *> *)aps
                                         center:(CLLocationCoordinate2D)center
                                         window:(NSUInteger)window;

/// RSSI 加权质心（2026-08-28）：可见 AP 坐标按距离反比加权平均——模拟"wifi 反查位置"
/// （真实设备定位偏向强信号=近处 AP）。直接由 AP 坐标计算，无需 wloc 网络反查；
/// 供 App 模拟态标注位置使用（随播放移动，与注入同源）。
+ (CLLocationCoordinate2D)rssiWeightedCentroidOfAps:(NSArray<TRWpsTileAP *> *)aps;

/// 空洞瓦片回退（远程伪装起点即空洞，2026-08-28 定案）：从 coord 所在瓦片出发按 Ulam 螺旋
/// 搜索最近的有效瓦片并返回其 BSSID——Apple 数据空洞区（404）注入邻近瓦片指纹，
/// 避免 locationd 暴露设备本地真实 wifi（对比"不注入=GPS(模拟) vs wifi(本地)"数百公里级不自洽，
/// 邻近瓦片偏差 1-10km 为次优但最优解；社区 acheong08 demo-api 同款 spiral 策略）。
/// @param coord WGS-84 坐标（空洞瓦片内的模拟位置）
/// @param maxAttempts 最多尝试候选瓦片数（防轰炸 gspe 端点；建议 24，对应半径约 3-4 瓦片）
/// completion 主队列；aps 非空 = 最近有效瓦片 BSSID；空 = 周边 maxAttempts 内全空洞（保持不注入）
+ (void)queryNearestBssidsForCoordinate:(CLLocationCoordinate2D)coord
                            maxAttempts:(NSUInteger)maxAttempts
                             completion:(void (^)(NSArray<TRWpsTileAP *> *aps, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
