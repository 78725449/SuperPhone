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

#import "ClipboardManager.h"
#import "Logging.h"

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
    return [super init];
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
    [pb setString:text];
    TVLog(@"Remote setString length=%lu", (unsigned long)text.length);
}

- (void)setStringForPasteInput:(NSString *)text {
    if (!text)
        return;
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    [pb setString:text];
    TVLog(@"Paste-input setString length=%lu", (unsigned long)text.length);
}

@end
