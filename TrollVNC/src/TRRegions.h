// TRRegions.h —— 构建产物（勿手改，改 regions.json 后重跑 build-tr-regions.mjs；构建于 2026-08-25）
#import <Foundation/Foundation.h>

/// 省市两级树（民政部数据源 → regions.json），喂 BRTextPickerView dataSourceArr
/// 格式：NSArray<NSDictionary*>{text:省, children:[{text:市}]}
/// kRegions 被 ObjC（.m）侧 TRFillDataViewController 调用，需 C linkage（见 .mm 的 extern "C"）
#ifdef __cplusplus
extern "C" {
#endif
NSArray *kRegions(void);
#ifdef __cplusplus
}
#endif
