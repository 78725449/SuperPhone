/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "TRWpsProto.h"

BOOL TRWpsReadVarint(const uint8_t *buf, NSUInteger len, NSUInteger *off, uint64_t *out) {
    uint64_t result = 0;
    int shift = 0;
    while (*off < len && shift < 64) {
        uint8_t b = buf[*off];
        (*off)++;
        result |= (uint64_t)(b & 0x7f) << shift;
        if (!(b & 0x80)) { *out = result; return YES; }
        shift += 7;
    }
    return NO;
}

BOOL TRWpsSkipField(const uint8_t *buf, NSUInteger len, NSUInteger *off, int wireType) {
    uint64_t v;
    switch (wireType) {
        case 0: return TRWpsReadVarint(buf, len, off, &v);
        case 1: if (*off + 8 > len) return NO; *off += 8; return YES;
        case 2: {
            uint64_t sl;
            if (!TRWpsReadVarint(buf, len, off, &sl)) return NO;
            if (sl > len - *off) return NO;
            *off += (NSUInteger)sl;
            return YES;
        }
        case 5: if (*off + 4 > len) return NO; *off += 4; return YES;
        default: return NO;
    }
}