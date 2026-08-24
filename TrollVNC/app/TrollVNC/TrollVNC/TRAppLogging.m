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
// App 伪装页编译共享模块（SimRouteCalculator/RegionSimulator 等）时引用它——
// trollvncmanager/trollvncserver 各自定义过，App target 需提供本定义。
BOOL tvncLoggingEnabled = YES;
