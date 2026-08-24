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

#import "TRFillDataGenerator.h"

@implementation TRFillDataGenerator

+ (NSDictionary *)requestForKind:(NSString *)kind
                           count:(NSInteger)count
                            seed:(uint64_t)seed
                          ratios:(NSDictionary *)ratios {
    // 参数契约与 TRDataFiller / 注册表 data.fill 完全一致（db/count/seed/ratios）
    NSMutableDictionary *req = [@{ @"db": kind, @"count": @(count), @"seed": @(seed) } mutableCopy];
    if ([ratios isKindOfClass:[NSDictionary class]] && ratios.count) req[@"ratios"] = ratios;
    return req;
}

@end
