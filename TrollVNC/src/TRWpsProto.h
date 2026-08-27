/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// WPS protobuf 读取原语（readVarint/skipField 单一真相源）
/// 曾复制于 TRWpsClient.mm 与 TRWpsTile.mm 两份（TRWpsTile 注释自述「复制自 TRWpsClient.mm」；
/// 静态函数无法跨文件复用致双份——2026-08-28 提炼为共享模块，两端消费同源）
/// 注意 .mm(ObjC++) 下 C 函数默认 C++ linkage，公开时用 extern "C" 暴露 C 符号

#ifdef __cplusplus
extern "C" {
#endif

BOOL TRWpsReadVarint(const uint8_t *buf, NSUInteger len, NSUInteger *off, uint64_t *out);
BOOL TRWpsSkipField(const uint8_t *buf, NSUInteger len, NSUInteger *off, int wireType);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END