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

// TVLog 宏依赖的日志开关全局符号（Logging.h extern）。
// App 伪装页编译共享模块（SimRouteCalculator/RegionSimulator 等）引用它——
// trollvncmanager/trollvncserver 各自定义过，App target 需提供本定义。
BOOL tvncLoggingEnabled = YES;

// ═══════════════════════════════════════════════════════════════════
// App 侧时序观测日志（2026-09-11 真机治理期添加）
// NSLog 只进 unified log，SSH 不可读；本函数同时落盘 /var/tmp/trollvnc-app.log
// （mobile 可写 /var/tmp），供真机复现后 SSH tail 直接查看 App 侧完整时序。
// 用法：TVAppLog(@"applySearchResult hasCurPos=%d", hasCurPos);
// 观测结束治理完后整个函数与调用点一次性删除（git 历史可恢复）。
// ═══════════════════════════════════════════════════════════════════
void TVAppLog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list args;
        va_start(args, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
        va_end(args);
        NSString *line = [NSString stringWithFormat:@"%@ [app] %@", [NSDate date], msg];
        NSLog(@"%@", line);
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/tmp/trollvnc-app.log"];
            if (!fh) {
                [[NSFileManager defaultManager] createFileAtPath:@"/var/tmp/trollvnc-app.log" contents:nil attributes:nil];
                fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/tmp/trollvnc-app.log"];
            }
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
        } @catch (NSException *e) {
            // 日志失败不致命，静默
        }
    }
}