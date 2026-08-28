/*
  TRIdentityReset - 换号身份锚清理（2026-08-28 风控对抗扩展 · identity.reset）
  功能：清理指定 App 的 Keychain 身份项（install_id/OpenUDID 类跨重装持久锚）与本地残留。
        分层自动降级，返回 tier 如实上报实际执行的层：
          secitem     SecItem 按 access group 定向删（预期多被 securityd ACL 拒绝，成本≈0 保留）
          keychain-db keychain-2.db 直删（root + system-keychain/storage.Keychains entitlements；
                      删前整库备份；agrp 白名单严格匹配，绝不触碰其它 App/系统项）
          container   目标 App 数据容器 NSUserDefaults 层清除（Library/Preferences/<bundleId>.plist）
          sop         无可清项时返回人工 SOP（卸载重装 + 还原广告标识符）
  红线：只清目标 App 的身份项；NULL/agroup 不匹配的行绝不触碰；绝不 kill securityd
        （它若重启失败会全系统 Keychain 不可用，风险不可接受；securityd 缓存可能需设备重启
        才完全生效——作为 warning 如实返回，不自动重启）。
  架构位置：trollvncmanager（注册表 Native executor）+ trollvncserver（0x50/5802 handler）
        双 target 编译同一份源码，两个 root 进程等价执行。
*/
#ifndef TRIdentityReset_h
#define TRIdentityReset_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** keychain-2.db 路径（/var/keychains 符号链接的真身） */
extern NSString * const kTRIdentityKeychainDbPath;

@interface TRIdentityReset : NSObject

/**
 * 清理指定 App 的身份锚。
 * @param bundleId 目标 App 反向域名 ID（格式校验，唯一操作边界——绝不越界清理）
 * @param mode     @"dryrun"（预览将清内容，不写）| @"commit"（执行）
 * @return 结果字典：{ok, bundleId, mode, tier, secitem{}, keychain{}, container{}, warnings[], sop[]}
 *         参数非法返回 {ok:NO, error}。
 */
+ (NSDictionary *)resetForBundleId:(NSString *)bundleId mode:(NSString *)mode;

/** bundleId 格式校验（反向域名，3~128 字节，须含点） */
+ (BOOL)isValidBundleId:(NSString *)bundleId;

@end

NS_ASSUME_NONNULL_END

#endif /* TRIdentityReset_h */
