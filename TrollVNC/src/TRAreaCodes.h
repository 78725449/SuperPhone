// TRAreaCodes.h —— 构建产物（勿手改）
#import <Foundation/Foundation.h>

/// 城市(中文名) → 国内长途区号（去前导 0）；缺省 @"10"（北京）
NSString *trAreaCodeForCity(NSString *city);
