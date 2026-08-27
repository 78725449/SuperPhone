#import "TRWpsClient.h"
#import "../../../src/TRWpsProto.h" // protobuf 读取原语（readVarint/skipField 曾本地复制，2026-08-28 上移共享模块）
#import <CoreFoundation/CoreFoundation.h>

@interface TRWpsClient ()
@end

@implementation TRWpsClient

+ (instancetype)sharedClient {
    static TRWpsClient *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[TRWpsClient alloc] init]; });
    return shared;
}

// ---------- protobuf 编码原语（对齐 mjs varint/zigzag） ----------
static void appendVarint(NSMutableData *out, uint64_t value) {
    uint8_t bytes[10];
    int n = 0;
    do {
        uint8_t b = value & 0x7f;
        value >>= 7;
        if (value) b |= 0x80;
        bytes[n++] = b;
    } while (value);
    [out appendBytes:bytes length:n];
}

static void appendTag(NSMutableData *out, int field, int wireType) {
    appendVarint(out, ((uint64_t)field << 3) | (uint64_t)wireType);
}

static void appendFieldSint32(NSMutableData *out, int field, int64_t value) {
    // sint32 → zigzag（对齐 mjs encFieldSint32）
    uint64_t z = (uint64_t)((value << 1) ^ (value >> 63));
    appendTag(out, field, 0);
    appendVarint(out, z);
}

static void appendFieldString(NSMutableData *out, int field, NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    appendTag(out, field, 2);
    appendVarint(out, (uint64_t)d.length);
    [out appendData:d];
}

static void appendFieldMsg(NSMutableData *out, int field, NSData *body) {
    appendTag(out, field, 2);
    appendVarint(out, (uint64_t)body.length);
    [out appendData:body];
}

// ---------- 请求体（对齐 mjs encodeWifiDevice/encodeDeviceType/encodeAppleWLoc） ----------
static NSData *encodeAppleWLoc(NSArray<NSString *> *bssids) {
    NSMutableData *body = [NSMutableData data];
    for (NSString *bssid in bssids) {
        NSMutableData *dev = [NSMutableData data];
        appendFieldString(dev, 1, bssid);      // wifi_devices[].mac
        appendFieldMsg(body, 2, dev);          // wifi_devices (repeated field 2)
    }
    appendFieldSint32(body, 3, 0);             // num_cell_results = 0
    appendFieldSint32(body, 4, 0);             // num_wifi_results = 0 → 返回全部邻域
    NSMutableData *dt = [NSMutableData data];
    appendFieldString(dt, 1, @"iPhone OS17.5/21F79");
    appendFieldString(dt, 2, @"iPhone12,1");
    appendFieldMsg(body, 33, dt);              // device_type
    return body;
}

// ---------- ARPC 头（对齐 mjs buildArpcRequest，全部大端） ----------
static uint16_t be16(uint16_t v) { return CFSwapInt16HostToBig(v); }
static uint32_t be32(uint32_t v) { return CFSwapInt32HostToBig(v); }

static NSData *buildArpcRequest(NSData *payload) {
    NSString *locale = @"en-001_001";
    NSString *appId = @"com.apple.locationd";
    NSString *osVer = @"18.6.2.22G100";
    NSData *l = [locale dataUsingEncoding:NSUTF8StringEncoding];
    NSData *a = [appId dataUsingEncoding:NSUTF8StringEncoding];
    NSData *o = [osVer dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger headLen = 2 + (2 + l.length) + (2 + a.length) + (2 + o.length) + 4 + 4;
    NSMutableData *head = [NSMutableData dataWithCapacity:headLen];
    uint16_t v16 = be16(1);
    [head appendBytes:&v16 length:2];
    uint16_t llen = be16((uint16_t)l.length);
    [head appendBytes:&llen length:2]; [head appendData:l];
    uint16_t alen = be16((uint16_t)a.length);
    [head appendBytes:&alen length:2]; [head appendData:a];
    uint16_t olen = be16((uint16_t)o.length);
    [head appendBytes:&olen length:2]; [head appendData:o];
    uint32_t fn = be32(1);
    [head appendBytes:&fn length:4];
    uint32_t plen = be32((uint32_t)payload.length);
    [head appendBytes:&plen length:4];
    [head appendData:payload];
    return head;
}

// protobuf 读取原语已上移 TRWpsProto.h/.mm（TRWpsReadVarint/TRWpsSkipField，2026-08-28）

// ---------- 响应解析（对齐 mjs parseWifiDevices/parseWifiDevice/parseLocation） ----------
static BOOL parseLocationField(const uint8_t *buf, NSUInteger len, int fieldNum, double *out) {
    NSUInteger i = 0;
    while (i < len) {
        uint64_t tag;
        if (!TRWpsReadVarint(buf, len, &i, &tag)) return NO;
        int fn = (int)(tag >> 3);
        int wt = (int)(tag & 7);
        if (wt == 0) {
            uint64_t value;
            if (!TRWpsReadVarint(buf, len, &i, &value)) return NO;
            // int64 负数 = 64 位补码（对齐 mjs 符号修正）
            int64_t signedV = (int64_t)value;
            if (fn == 1 && fieldNum == 1) { *out = (double)signedV / 1e8; return YES; }
            if (fn == 2 && fieldNum == 2) { *out = (double)signedV / 1e8; return YES; }
        } else {
            if (!TRWpsSkipField(buf, len, &i, wt)) return NO;
        }
    }
    return NO;
}

static CLLocationCoordinate2D parseWifiDevice(const uint8_t *buf, NSUInteger len, NSString **bssidOut) {
    CLLocationCoordinate2D coord = { kCLLocationCoordinate2DInvalid.latitude, kCLLocationCoordinate2DInvalid.longitude };
    *bssidOut = nil;
    NSUInteger i = 0;
    while (i < len) {
        uint64_t tag;
        if (!TRWpsReadVarint(buf, len, &i, &tag)) break;
        int fn = (int)(tag >> 3);
        int wt = (int)(tag & 7);
        if (fn == 1 && wt == 2) {
            uint64_t sl;
            if (!TRWpsReadVarint(buf, len, &i, &sl)) break;
            if (sl > len - i) break;
            *bssidOut = [[NSString alloc] initWithBytes:buf + i length:(NSUInteger)sl encoding:NSUTF8StringEncoding];
            i += (NSUInteger)sl;
        } else if (fn == 2 && wt == 2) {
            uint64_t sl;
            if (!TRWpsReadVarint(buf, len, &i, &sl)) break;
            if (sl > len - i) break;
            double lat = 0, lon = 0;
            BOOL hasLat = parseLocationField(buf + i, (NSUInteger)sl, 1, &lat);
            BOOL hasLon = parseLocationField(buf + i, (NSUInteger)sl, 2, &lon);
            if (hasLat && hasLon) {
                coord.latitude = lat;
                coord.longitude = lon;
            }
            i += (NSUInteger)sl;
        } else {
            if (!TRWpsSkipField(buf, len, &i, wt)) break;
        }
    }
    return coord;
}

- (void)queryCoordinatesForBssids:(NSArray<NSString *> *)bssids
                       completion:(void (^)(NSDictionary<NSString *, CLLocation *> *result,
                                            CLLocationCoordinate2D centroid,
                                            BOOL hasValid,
                                            NSError *_Nullable error))completion {
    if (bssids.count == 0 || !completion) { return; }
    NSData *body = buildArpcRequest(encodeAppleWLoc(bssids));
    NSURL *url = [NSURL URLWithString:@"https://gs-loc-cn.apple.com/clls/wloc"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 15;
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [req setValue:@"utf-8" forHTTPHeaderField:@"Accept-Charset"];
    [req setValue:@"en-us" forHTTPHeaderField:@"Accept-Language"];
    [req setValue:@"locationd/2890.16.16 CFNetwork/1496.0.7 Darwin/23.5.0" forHTTPHeaderField:@"User-Agent"];
    req.HTTPBody = body;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req
                                            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *netErr) {
        NSMutableDictionary<NSString *, CLLocation *> *result = [NSMutableDictionary dictionary];
        CLLocationCoordinate2D centroid = kCLLocationCoordinate2DInvalid;
        BOOL hasValid = NO;
        NSError *outErr = netErr;
        if (!netErr) {
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)resp;
            if (![httpResp isKindOfClass:[NSHTTPURLResponse class]]) {
                outErr = [NSError errorWithDomain:@"TRWpsClient" code:-1
                    userInfo:@{NSLocalizedDescriptionKey: @"wloc 非 HTTP 响应"}];
            } else if (httpResp.statusCode < 200 || httpResp.statusCode >= 300) {
                outErr = [NSError errorWithDomain:@"TRWpsClient" code:(NSInteger)httpResp.statusCode
                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"wloc HTTP %ld", (long)httpResp.statusCode]}];
            }
        }
        if (!outErr && data.length >= 10) {
            // 响应 = 10B 帧头 + protobuf（对齐 mjs）
            NSData *proto = [data subdataWithRange:NSMakeRange(10, data.length - 10)];
            const uint8_t *bytes = (const uint8_t *)proto.bytes; // .mm 按 C++ 编译：void* 需显式转 uint8_t*
            NSUInteger len = proto.length;
            NSUInteger i = 0;
            double latSum = 0, lonSum = 0;
            int validCount = 0;
            while (i < len) {
                uint64_t tag;
                if (!TRWpsReadVarint(bytes, len, &i, &tag)) break;
                int fn = (int)(tag >> 3);
                int wt = (int)(tag & 7);
                if (fn == 2 && wt == 2) {
                    uint64_t sl;
                    if (!TRWpsReadVarint(bytes, len, &i, &sl)) break;
                    if (sl > len - i) break;
                    NSString *bssid = nil;
                    CLLocationCoordinate2D coord = parseWifiDevice(bytes + i, (NSUInteger)sl, &bssid);
                    i += (NSUInteger)sl;
                    if (bssid && CLLocationCoordinate2DIsValid(coord) &&
                        !(coord.latitude == -180 && coord.longitude == -180)) { // 哨兵=库中未知
                        result[bssid] = [[CLLocation alloc] initWithCoordinate:coord
                                                                      altitude:0
                                                            horizontalAccuracy:100
                                                              verticalAccuracy:-1
                                                                        course:-1
                                                                         speed:-1
                                                                      timestamp:[NSDate date]];
                        latSum += coord.latitude;
                        lonSum += coord.longitude;
                        validCount++;
                        hasValid = YES;
                    }
                } else {
                    if (!TRWpsSkipField(bytes, len, &i, wt)) break;
                }
            }
            if (validCount > 0) {
                centroid.latitude = latSum / validCount;
                centroid.longitude = lonSum / validCount;
            }
        } else if (!outErr) {
            outErr = [NSError errorWithDomain:@"TRWpsClient"
                                        code:-1
                                    userInfo:@{NSLocalizedDescriptionKey: @"wloc 响应过短"}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result, centroid, hasValid, outErr);
        });
    }];
    [task resume];
}

@end
