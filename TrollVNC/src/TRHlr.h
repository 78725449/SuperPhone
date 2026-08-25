// TRHlr.h —— 构建产物（勿手改，改 phone.dat 后重跑 build-tr-hlr.mjs；构建于 2026-08-25）
#import <Foundation/Foundation.h>
#import <stdint.h>

/// 手机号段归属地表（phone2region 数据源 → 静态区间表；城市名不带"市"后缀，与区号表一致）
/// kHlrRandomPrefix：随机取该城市归属的一个 7 位号段前缀；无数据返回 0
#ifdef __cplusplus
extern "C" {
#endif
uint32_t trHlrRandomPrefix(NSString *city);
NSInteger trHlrCityCount(void); // 表内城市数（测试/校验用）
#ifdef __cplusplus
}
#endif
