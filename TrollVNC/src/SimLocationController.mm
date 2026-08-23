/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "SimLocationController.h"

#import "SimLocationManager.h"
#import "Logging.h"

// 轨迹点序列文件（大 payload 走文件，对齐 manager pid 平铺命名）
static NSString *const kSimTrackFilePath = @"/var/mobile/Library/Caches/com.82flex.trollvnc.simloc.json";
// 巡检间隔：失效检测 + 参数变更感知合一
static const NSTimeInterval kSimPatrolInterval = 10.0;
// track 逐点注入间隔（mode A：1s/点）
static const NSTimeInterval kSimTrackTickInterval = 1.0;

@implementation SimLocationController {
    dispatch_source_t _patrolSource;   // 10s 巡检
    dispatch_source_t _trackSource;    // track 逐点注入
    NSArray<NSDictionary *> *_trackPoints; // 轨迹点序列（内存缓存）
    NSUInteger _trackIndex;
    NSString *_lastParamsSig;          // 参数指纹（变更检测）
    BOOL _trackFinished;
}

+ (instancetype)sharedController {
    static SimLocationController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[SimLocationController alloc] init];
    });
    return shared;
}

#pragma mark - 公共入口

- (void)start {
    [self reloadFromPrefs];
    [self _startPatrol];
}

- (void)reloadFromPrefs {
    NSString *sig = [self _paramsSignature];
    if (_lastParamsSig && [sig isEqualToString:_lastParamsSig]) {
        // 参数未变：仍做一次失效兜底（若 static 注入失效则重注入）
        [self _checkRestore];
        return;
    }
    _lastParamsSig = sig;
    [self applyFromPrefs];
}

#pragma mark - 状态机

- (void)applyFromPrefs {
    NSString *mode = [self _readPref:@"SimLocationMode"];
    if (![mode isKindOfClass:[NSString class]] || mode.length == 0) mode = @"off";
    TVLog(@"[locsim] apply mode=%@", mode);
    if ([mode isEqualToString:@"off"]) {
        [self _stopTrack];
        [[SimLocationManager sharedManager] stop];
    } else if ([mode isEqualToString:@"static"]) {
        [self _stopTrack];
        [self _injectStatic];
    } else if ([mode isEqualToString:@"track"]) {
        [self _startTrack]; // _startTrack 内部立即注入轨迹首点（不读 static 旧坐标）
    } else {
        TVLog(@"[locsim] unknown mode=%@ -> off", mode);
        [self _stopTrack];
        [[SimLocationManager sharedManager] stop];
    }
}

- (void)_injectStatic {
    double lat = [self _readDouble:@"SimLocationLat" def:0.0];
    double lon = [self _readDouble:@"SimLocationLon" def:0.0];
    double acc = [self _readDouble:@"SimLocationAccuracy" def:5.0];
    if (acc < 3.0) acc = 3.0;
    if (acc > 15.0) acc = 15.0;
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(lat, lon);
    [[SimLocationManager sharedManager] injectPoint:coord
                                           altitude:45.0
                                           accuracy:acc
                                             course:0.0
                                              speed:0.0];
    TVLog(@"[locsim] static injected (%.5f, %.5f) acc=%.1f", lat, lon, acc);
}

#pragma mark - track（mode A：每秒注入一点，完成后保持终点）

- (void)_startTrack {
    NSArray *points = [self _loadTrackPoints];
    if (points.count == 0) {
        TVLog(@"[locsim] track file empty/missing: %@", kSimTrackFilePath);
        return;
    }
    _trackPoints = points;
    // 立即注入轨迹首点（不读 SimLocationLat/Lon 旧值——算路只写 mode=track，旧坐标会导致启动漂移）
    [self _injectPointDict:points[0]];
    _trackIndex = 1;
    _trackFinished = NO;
    if (_trackSource) {
        dispatch_source_cancel(_trackSource);
        _trackSource = nil;
    }
    _trackSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_trackSource, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSimTrackTickInterval * NSEC_PER_SEC)),
                              (uint64_t)(kSimTrackTickInterval * NSEC_PER_SEC), 0);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_trackSource, ^{
        [weakSelf _trackTick];
    });
    dispatch_resume(_trackSource);
    TVLog(@"[locsim] track start, %lu points", (unsigned long)points.count);
}

- (void)_trackTick {
    if (_trackIndex >= _trackPoints.count) {
        [self _stopTrack]; // 完成：停 timer，保持终点坐标（不调 stop）
        TVLog(@"[locsim] track finished, keep final point");
        return;
    }
    [self _injectPointDict:_trackPoints[_trackIndex++]];
}

- (void)_injectPointDict:(NSDictionary *)p {
    double lat = [p[@"lat"] doubleValue];
    double lon = [p[@"lon"] doubleValue];
    double acc = [p[@"acc"] doubleValue];
    if (acc < 3.0) acc = 3.0;
    if (acc > 15.0) acc = 15.0;
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(lat, lon);
    [[SimLocationManager sharedManager] injectPoint:coord
                                           altitude:[p[@"alt"] doubleValue] > 0 ? [p[@"alt"] doubleValue] : 45.0
                                           accuracy:acc
                                             course:[p[@"course"] doubleValue]
                                              speed:[p[@"speed"] doubleValue]];
}

- (void)_stopTrack {
    if (_trackSource) {
        dispatch_source_cancel(_trackSource);
        _trackSource = nil;
    }
    _trackPoints = nil;
    _trackIndex = 0;
    _trackFinished = YES;
}

- (NSArray *)_loadTrackPoints {
    NSData *data = [NSData dataWithContentsOfFile:kSimTrackFilePath];
    if (!data.length) return @[];
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if ([json isKindOfClass:[NSDictionary class]] && [json[@"points"] isKindOfClass:[NSArray class]]) {
        return json[@"points"];
    }
    if ([json isKindOfClass:[NSArray class]]) return json;
    return @[];
}

#pragma mark - 轨迹上传（sim.location.track executor 调用）

+ (BOOL)uploadTrackPoints:(NSArray<NSDictionary *> *)points error:(NSError **)error {
    if (![points isKindOfClass:[NSArray class]] || points.count == 0) {
        if (error) *error = [NSError errorWithDomain:@"SimLoc" code:1 userInfo:@{NSLocalizedDescriptionKey:@"points 数组不能为空"}];
        return NO;
    }
    NSMutableArray *clean = [NSMutableArray arrayWithCapacity:points.count];
    for (id item in points) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            if (error) *error = [NSError errorWithDomain:@"SimLoc" code:2 userInfo:@{NSLocalizedDescriptionKey:@"points 元素须为对象 {lat,lon,...}"}];
            return NO;
        }
        double lat = [item[@"lat"] doubleValue];
        double lon = [item[@"lon"] doubleValue];
        if (lat < -90.0 || lat > 90.0 || lon < -180.0 || lon > 180.0) {
            if (error) *error = [NSError errorWithDomain:@"SimLoc" code:3 userInfo:@{NSLocalizedDescriptionKey:@"坐标超出 WGS-84 范围"}];
            return NO;
        }
        NSMutableDictionary *pt = [item mutableCopy];
        double acc = [pt[@"acc"] doubleValue];
        if (!(acc >= 3.0 && acc <= 15.0)) pt[@"acc"] = @(MIN(15.0, MAX(3.0, acc))); // 精度钳制 3~15
        [clean addObject:pt];
    }
    // 原子写：临时文件 + rename，避免 Controller 读到半截 JSON
    NSDictionary *payload = @{ @"version": @1, @"points": clean };
    NSError *jerr = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jerr];
    if (!json) {
        if (error) *error = jerr ?: [NSError errorWithDomain:@"SimLoc" code:4 userInfo:@{NSLocalizedDescriptionKey:@"轨迹序列化失败"}];
        return NO;
    }
    NSString *tmp = [kSimTrackFilePath stringByAppendingString:@".tmp"];
    NSError *werr = nil;
    if (![json writeToFile:tmp options:NSDataWritingAtomic error:&werr]) {
        if (error) *error = werr ?: [NSError errorWithDomain:@"SimLoc" code:5 userInfo:@{NSLocalizedDescriptionKey:@"轨迹临时文件写入失败"}];
        return NO;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:kSimTrackFilePath]) {
        [[NSFileManager defaultManager] removeItemAtPath:kSimTrackFilePath error:NULL];
    }
    if (![[NSFileManager defaultManager] moveItemAtPath:tmp toPath:kSimTrackFilePath error:&werr]) {
        if (error) *error = werr ?: [NSError errorWithDomain:@"SimLoc" code:6 userInfo:@{NSLocalizedDescriptionKey:@"轨迹文件替换失败"}];
        return NO;
    }
    // 切 track 模式（root 域；App 写 mobile 域由双域读取兜底）
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    [d setObject:@"track" forKey:@"SimLocationMode"];
    [d synchronize];
    TVLog(@"[locsim] track uploaded: %lu points", (unsigned long)clean.count);
    return YES;
}

#pragma mark - 巡检（10s：失效恢复 + 参数变更感知）

- (void)_startPatrol {
    if (_patrolSource) return;
    _patrolSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_patrolSource, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSimPatrolInterval * NSEC_PER_SEC)),
                              (uint64_t)(kSimPatrolInterval * NSEC_PER_SEC), 0);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_patrolSource, ^{
        [weakSelf reloadFromPrefs];
    });
    dispatch_resume(_patrolSource);
}

- (void)_checkRestore {
    NSString *mode = [self _readPref:@"SimLocationMode"];
    if (![mode isKindOfClass:[NSString class]] || mode.length == 0) mode = @"off";
    if ([mode isEqualToString:@"off"]) return;
    if ([mode isEqualToString:@"static"]) {
        // static 注入失效（locationd 会话中断）则重注入
        if (![SimLocationManager sharedManager].isSimulating) {
            TVLog(@"[locsim] static injection lost, re-inject");
            [self _injectStatic];
        }
    } else if ([mode isEqualToString:@"track"]) {
        if (!_trackSource) {
            TVLog(@"[locsim] track timer lost, restart track");
            [self _startTrack];
        }
    }
}

#pragma mark - 参数读取（双域：root 域 → mobile 域 plist 回退）

- (id)_readPref:(NSString *)key {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    id v = [d objectForKey:key];
    if (v) return v;
    NSDictionary *mobilePrefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.82flex.trollvnc.plist"];
    return mobilePrefs[key];
}

- (double)_readDouble:(NSString *)key def:(double)def {
    id v = [self _readPref:key];
    if ([v respondsToSelector:@selector(doubleValue)]) return [v doubleValue];
    return def;
}

- (NSString *)_paramsSignature {
    return [NSString stringWithFormat:@"%@|%.6f|%.6f|%.2f|%@",
            [self _readPref:@"SimLocationMode"] ?: @"off",
            [self _readDouble:@"SimLocationLat" def:0.0],
            [self _readDouble:@"SimLocationLon" def:0.0],
            [self _readDouble:@"SimLocationAccuracy" def:5.0],
            [self _readPref:@"SimLocationSpeed"] ?: @""];
}

@end
