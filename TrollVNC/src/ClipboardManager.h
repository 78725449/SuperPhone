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

#ifndef ClipboardManager_h
#define ClipboardManager_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Lightweight clipboard manager that only supports UTF-8 text.
/// Wraps UIPasteboard as the shared clipboard access point for:
///  - clipboard.get（复制按钮显式拉取被控端剪贴板）
///  - type.paste / 5801 paste（粘贴输入的数据载体写入）
/// 不再监听系统剪贴板变化（2026-08-17：自动同步架构已移除，剪贴板改为显式双向搬运——
/// 复制=拉取、粘贴=注入，无自动推送、无回显抑制需求）。
@interface ClipboardManager : NSObject

/// Global singleton instance
+ (instancetype)sharedManager;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

/// Get current clipboard string (UTF-8). Returns nil if no plain text is available.
- (nullable NSString *)currentString;

/// Write clipboard string from a remote client（RFB 协议写入 / 5801 粘贴的数据载体）。
- (void)setStringFromRemote:(NSString *)text;

/// Write clipboard string as a *paste-input* data carrier（type.paste 注入）。
/// 与 setStringFromRemote 同义写入，保留独立名供 type.paste executor 调用点；
/// 无需回显抑制（自动同步已移除）。
- (void)setStringForPasteInput:(NSString *)text;

@end

NS_ASSUME_NONNULL_END

#endif /* ClipboardManager_h */
