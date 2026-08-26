#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/// wloc 反查客户端（ObjC 移植自 scripts/apple-wps.mjs query 逻辑）
/// 输入 BSSID 集合，输出每个 BSSID 的坐标 + 有效坐标质心。
/// 协议：POST gs-loc-cn.apple.com/clls/wloc，ARPC 头 + protobuf（对齐 mjs 实现）
@interface TRWpsClient : NSObject

+ (instancetype)sharedClient;

/// 批量反查（一次请求携带全部 BSSID，wifi_devices repeated field）
/// 坐标均为 WGS-84；unknown 的 BSSID（lat=-180 哨兵）不出现在 result 中
/// completion 在主队列回调；error 非 nil = 网络/HTTP 失败
- (void)queryCoordinatesForBssids:(NSArray<NSString *> *)bssids
                       completion:(void (^)(NSDictionary<NSString *, CLLocation *> *result,
                                            CLLocationCoordinate2D centroid,
                                            BOOL hasValid,
                                            NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
