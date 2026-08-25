/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 数据填充共享模块（App 主路径 + daemon 补充入口，多 target 编译）
/// - App 伪装页：进程内直调（生产主路径，早期规格 DataFillerCoordinator 定案）
/// - 注册表 data.fill：manager 进程执行（网关/隧道外部调用点）
/// - 5901 0x50 / 5802：server 进程（AI 工具/调试）
/// 写库逻辑单一实现：calls/sms 直写（sqlite3）+ contacts CNContactStore，写后 kill 对应 daemon。
/// 参数：{db:'contacts'|'calls'|'sms', count, seed, ratios:{...}}；seed 确定性随机（同 seed 可复现）。
@interface TRDataFiller : NSObject

/// 统一入口：按 db 填充 count 条拟真数据
/// @param db     'contacts' | 'calls' | 'sms'
/// @param count  生成条数（1~1000）
/// @param seed   确定性随机种子（0 = 随机）
/// @param ratios 比例参数（可空，默认内置拟人分布；键集见 M5 计划 §4.0）
/// @return 成功 {ok:YES, db, count}；失败 {ok:NO, error}
+ (NSDictionary *)fillDatabase:(NSString *)db
                         count:(NSInteger)count
                          seed:(uint64_t)seed
                        ratios:(nullable NSDictionary *)ratios;

/// 清空指定库（contacts/calls/sms/all；设计 §7）
/// @param db 'contacts' | 'calls' | 'sms' | 'all'
/// @return {ok:YES, db, cleared}；失败 {ok:NO, error}
+ (NSDictionary *)clearDatabase:(NSString *)db;

@end

NS_ASSUME_NONNULL_END
