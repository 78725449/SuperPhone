/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#ifndef TRAppDomain_h
#define TRAppDomain_h

/// 全局 App 域标识 = bundle id 同名的 NSUserDefaults suite——跨端共享的配置域契约。
/// 全部进程（App / trollvncserver / trollvncmanager / prefs bundle）读写同一配置域
/// （SimLocation*、网关地址、设备 ID、开关等），必须用本宏引用 suite 名，
/// 禁止重写字面量（曾 19 文件 47 处裸字符串/本地 static 各持一份，2026-08-28 收敛）。
/// 用宏而非 extern 常量：三域（src theos / App xcode / prefs bundle）include 即用，无 .mm 链接依赖。
#define kTRAppPrefsSuiteName "com.82flex.trollvnc"

#endif /* TRAppDomain_h */
