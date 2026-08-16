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

#if !__has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import <UIKit/UIKit.h>
#import <notify.h>

#import "ClipboardManager.h"
#import "Logging.h"

static NSString *const kPasteboardDarwinNotification = @"com.apple.pasteboard.notify.changed";

@interface ClipboardManager ()
@property(nonatomic, assign) int notifyToken;
@property(nonatomic, assign, getter=isStarted) BOOL started;
@property(nonatomic, assign) NSInteger lastObservedChangeCount;     // last seen changeCount from UIPasteboard
@property(nonatomic, assign) NSInteger lastSetChangeCount;          // 远程写入后自身 set 造成的 changeCount 锚点（-1=无效）
@property(nonatomic, copy, nullable) NSString *lastSetValue;        // 最近一次远程写入的文本（suppressInputEcho 文本对比用）
@property(nonatomic, assign) BOOL suppressInputEcho;                // 粘贴输入（type.paste）写入标记：下次通知文本相等则吞掉
@property(nonatomic, copy, nullable) NSString *lastSentValue;       // 上次成功发送到控制端的文本（重复通知判定用）
@end

@implementation ClipboardManager

+ (instancetype)sharedManager {
    static ClipboardManager *_inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _inst = [[self alloc] init];
    });
    return _inst;
}

- (instancetype)init {
    if (self = [super init]) {
        _notifyToken = 0;
        _started = NO;
        _lastObservedChangeCount = -1;
        _lastSetChangeCount = -1;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    if (self.started) {
        TVLog("start called but already started");
        return;
    }

    self.started = YES;
    TVLog("Starting clipboard monitoring");

    // 先同步初始化基线，再注册通知（2026-08-15 修复"首次复制不触发"）：
    // 原实现 dispatch_async 异步初始化——block 排队期间若用户已复制，block 执行时读到的
    // changeCount 已是复制后的值，随后通知回调因 lastObservedChangeCount == currentCount
    // 判为"重复通知"吞掉首次真实复制（需复制第二次才触发）。
    // 改为「同步读基线 + 后注册通知」：基线读取先于注册，任何触发通知的复制都发生在基线之后，
    // 通知回调的 currentCount 必然 > 基线 → 首次复制即放行。changeCount 为对齐 NSInteger，
    // 跨线程读取原子安全，读到旧值（基线偏小）反而更安全。
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    self.lastObservedChangeCount = pb.changeCount;
    TVLog("Initial pasteboard changeCount=%ld", (long)self.lastObservedChangeCount);

    // Register Darwin notification for pasteboard changes
    __weak __typeof(self) weakSelf = self;
    int token = 0;
    uint32_t status =
        notify_register_dispatch(kPasteboardDarwinNotification.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
            __strong __typeof(weakSelf) selfRef = weakSelf;
            if (!selfRef)
                return;
            [selfRef handlePasteboardChangeFromSystem];
        });

    if (status == NOTIFY_STATUS_OK) {
        self.notifyToken = token;
        TVLog("Registered for pasteboard notifications (token=%d)", token);
    } else {
        self.notifyToken = 0;
        TVLog("Failed to register pasteboard notifications (status=%u)", status);
    }
}

- (void)stop {
    if (!self.started) {
        TVLog("stop called but not started");
        return;
    }

    self.started = NO;
    TVLog("Stopping clipboard monitoring");

    if (self.notifyToken != 0) {
        notify_cancel(self.notifyToken);
        TVLog("Notification token %d canceled", self.notifyToken);
        self.notifyToken = 0;
    }
}

- (nullable NSString *)currentString {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSString *text = pb.string;
    if (text.length == 0)
        return nil;
    return text;
}

- (void)setStringFromRemote:(NSString *)text {
    if (!text)
        return;

    UIPasteboard *pb = [UIPasteboard generalPasteboard];

    // 2026-08-15 修复"被控端复制第一次不成功"（根因）：
    // 原实现用计数型 suppressNextCallbacks=1 吞"自身写入触发的 1 次系统通知"。但 iOS 的
    // com.apple.pasteboard.notify.changed 通知可能被延迟/合并：若自身写入的通知还没到达、
    // 用户就复制了新文本，合并后的首个通知会被计数抑制误吞 → 用户第一次真实复制丢失，
    // 只能等第二次/第三次才同步。改为 changeCount 锚点判定：记录自身 set 后的 changeCount，
    // 仅当后续系统通知的 changeCount 恰好等于该锚点时判定为"自身回显"；任何越过锚点的
    // 变化（真实复制，changeCount 更大）立即放行。锚点无效（changeCount 未同步推进）时
    // 不设锚点，通知到达时按真实复制放行（最多回环一次，由控制端锚点兜底）。
    self.lastSetChangeCount = -1;
    [pb setString:text];
    NSInteger after = pb.changeCount;
    if (after > self.lastObservedChangeCount) {
        self.lastSetChangeCount = after; // 锚点有效：changeCount 已同步推进
    }
    TVLog("Remote setString length=%lu, anchor=%ld", (unsigned long)text.length, (long)self.lastSetChangeCount);
    // Do NOT proactively callback: remote already has the content
}

- (void)setStringForPasteInput:(NSString *)text {
    if (!text)
        return;

    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    // 2026-08-15 粘贴输入与剪贴板同步解耦（用户拍板）：
    // type.paste 的"写剪贴板"只是 Cmd+V 注入的数据载体，不是"用户复制"。
    // 记录本次写入文本 + 置 suppressInputEcho，后续系统通知若剪贴板文本仍等于该值
    // （自身写入的回显，含通知延迟/合并场景）→ 吞掉不回传控制端，
    // 避免"输入到被控端的文字反过来覆盖控制端剪贴板"的混乱。用户真实复制（文本不同）
    // 不受影响（仍放行）。
    // 2026-08-16 移除 changeCount 锚点：粘贴输入管线仅靠 suppressInputEcho 文本对比抑制回显
    // （changeCount 延迟递增，锚点不可靠且可能误吞"粘贴后立即复制不同文本"的真实复制）。
    // 仅清锚点、不回设：清掉 setStringFromRemote 可能残留的旧锚点，避免跨管线误吞。
    self.lastSetChangeCount = -1;
    self.lastSetValue = text;
    self.suppressInputEcho = YES;
    [pb setString:text];
    TVLog("Remote setStringForPasteInput length=%lu, suppressInputEcho=YES",
          (unsigned long)text.length);
}

#pragma mark - Internal

- (void)handlePasteboardChangeFromSystem {

    // System change notification received (triggered by external apps or by our own set)
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSInteger currentCount = pb.changeCount;
    TVLog("System pasteboard changed: count=%ld last=%ld anchor=%ld suppress=%d", (long)currentCount,
          (long)self.lastObservedChangeCount, (long)self.lastSetChangeCount, self.suppressInputEcho);

    // 2026-08-16 方案 C：重复通知判定改为「文本相等 且 changeCount 相等」。
    // 原实现仅 changeCount 相等判重复；但 changeCount 延迟递增（官方文档「waits until the
    // end of the current event loop」）——首次复制时通知回调读到的 changeCount 仍是基线值，
    // 被误判为「重复通知」吞掉（首次复制需第二次才触发）。改为文本对比：文本变了（首次
    // 复制/新内容）必然放行；只有「文本没变 且 changeCount 也没变」才是真重复。
    NSString *current = [self currentString];
    BOOL sameText = (current == self.lastSentValue) ||
                    (current != nil && [current isEqualToString:self.lastSentValue]);
    if (sameText && self.lastObservedChangeCount == currentCount) {
        TVLog("Ignoring duplicate pasteboard notification");
        return;
    }

    // Advance baseline and then process
    self.lastObservedChangeCount = currentCount;

    // 2026-08-15 粘贴输入回显抑制（type.paste 输入与剪贴板同步解耦）：
    // suppressInputEcho 置位表示最近一次剪贴板写入来自粘贴输入（数据载体非用户复制）。
    // 若当前剪贴板文本仍等于该次写入值 → 自身回显，吞掉不回传控制端（无论 changeCount
    // 锚点是否失效/通知是否延迟合并）；文本已不同（用户随后真实复制）→ 清标记正常放行。
    // 一次性：抑制只针对该次输入写入，之后恢复正常同步。
    if (self.suppressInputEcho) {
        NSString *cur = [self currentString];
        if (cur.length > 0 && [cur isEqualToString:self.lastSetValue]) {
            self.suppressInputEcho = NO;
            self.lastSetValue = nil;
            self.lastSetChangeCount = -1;
            TVLog("Suppressing paste-input echo (count=%ld)", (long)currentCount);
            return;
        }
        self.suppressInputEcho = NO;
        self.lastSetValue = nil;
        TVLog("Paste-input marker cleared, change differs — real copy passes through");
    }

    // 2026-08-15 changeCount 锚点回显判定（替代原计数型抑制，防误吞真实复制）：
    // - currentCount <= lastSetChangeCount：未越过锚点 = 远程写入自身的回显
    //   （含乱序的早期通知/中间计数）→ 跳过；仅在恰好等于锚点时清锚点
    //   （两次远程写入紧邻时，第一条写入的乱序通知 count < 第二条锚点，锚点必须保留，
    //   否则第二条写入的回显会被误当真实复制回调）
    // - currentCount > lastSetChangeCount：真实复制发生在远程写入之后 → 放行并清锚点
    //   （通知延迟/合并时首条通知的 changeCount 可能直接越过锚点，此时用户复制绝不能被吞）
    if (self.lastSetChangeCount >= 0) {
        NSInteger anchor = self.lastSetChangeCount;
        if (currentCount <= anchor) {
            if (currentCount == anchor) {
                self.lastSetChangeCount = -1;
            }
            TVLog("Ignoring self-echo of remote set (count=%ld anchor=%ld)",
                  (long)currentCount, (long)anchor);
            return;
        }
        self.lastSetChangeCount = -1;
        TVLog("Change advanced past anchor (%ld) — real copy, dispatching", (long)currentCount);
    }

    // 真实变化 → 记录本次发送文本，供下次重复判定对比（2026-08-16 方案 C）
    self.lastSentValue = current;
    [self dispatchChangeIfNeeded];
}

- (void)dispatchChangeIfNeeded {
    NSString *current = [self currentString];

    void (^cb)(NSString *_Nullable) = self.onChange;
    if (cb) {
        // Ensure callback is invoked on the main thread
        TVLog("Invoking onChange with system string (len=%lu)", (unsigned long)current.length);
        if ([NSThread isMainThread]) {
            cb(current);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                cb(current);
            });
        }
    }
}

@end
