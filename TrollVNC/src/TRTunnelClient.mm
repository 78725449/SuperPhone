/*
  TRTunnelClient.mm - 设备侧隧道客户端（BSD socket / TCP + 帧封装）
  协议：
    握手阶段（JSON 行）：
      -> {"type":"tunnel_hello","deviceId":"<uuid>","token":"<可选>"}
      <- {"type":"tunnel_ack","ok":true}
    握手成功后进入帧封装透传模式（type:1B + length:4B BE + payload）：
      DATA(0x01)    双向 RFB 透传（隧道 ↔ 本地 127.0.0.1:5901）
      PING(0x02)    心跳请求（设备→网关，间隔可配 HeartbeatIntervalSec，默认 30s）
      PONG(0x03)    心跳响应（网关→设备 / 设备回网关）
      CMD(0x04)     命令 JSON（网关→设备，复用 sendDeviceCmd 通道）
      CMDACK(0x05)  命令 ack JSON（设备→网关）
  帧封装是为了让 RFB 裸字节透传与 JSON 心跳/命令在同一隧道上共存而不互相污染。
  心跳：按 HeartbeatIntervalSec（默认 30s，5-300 钳制）发 PING；断线退避重连（2s 起，上限 30s），与 TRGatewayClient 一致。
  独立线程运行（NSThread），select() 多路复用隧道与本地 RFB 双向数据流。
*/
#import "TRTunnelClient.h"
#import "Logging.h"
#import "TRAppDomain.h" // kTRAppPrefsSuiteName（跨端 prefs 域契约，2026-08-28）

#import <stdio.h>
#import <stdarg.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/select.h>
#import <sys/time.h>
#import <string.h>
#import <time.h>
#import <unistd.h>
#import <pthread.h>
#import <notify.h>

// 帧类型常量（proto:2 通道复用协议，2026-08-23）
static const uint8_t kFrameTypePing     = 0x02;  // 心跳请求（设备→网关）
static const uint8_t kFrameTypePong     = 0x03;  // 心跳响应（网关→设备）
static const uint8_t kFrameTypeCmd      = 0x04;  // 命令 JSON（网关→设备）
static const uint8_t kFrameTypeCmdAck   = 0x05;  // 命令 ack JSON（设备→网关）
static const uint8_t kFrameTypeState    = 0x07;  // 被控状态上报（设备→网关，JSON {"controlled":bool}）
static const uint8_t kFrameTypeChanOpen = 0x08;  // 通道建立（网关→设备）：[chanId:2BE][kind:1B]
static const uint8_t kFrameTypeChanAck  = 0x09;  // 通道建立确认（设备→网关）：[chanId:2BE][ok:1B]
static const uint8_t kFrameTypeChanData = 0x0A;  // 通道 RFB 数据（双向）：[chanId:2BE][rfb字节]
static const uint8_t kFrameTypeChanClose= 0x0B;  // 通道关闭（双向）：[chanId:2BE][reason:1B]

// 隧道协议版本（tunnel_hello.proto，网关不匹配即拒绝）
static const int kTunnelProto = 2;
// 通道号与类型
static const uint16_t kChanIdThumb   = 0;   // 缩略图通道固定 0
static const uint8_t  kChanKindThumb = 0;   // 缩略图通道
static const uint8_t  kChanKindSession = 1; // 会话通道（noVNC 控制/观看）

// 心跳/超时/重连参数
static const NSTimeInterval kTunnelPingInterval  = 30.0;   // 心跳间隔默认值（HeartbeatIntervalSec 未设置时）
static NSTimeInterval gTunnelPingInterval = 30.0;          // 运行期心跳间隔（startWithHost: 从 HeartbeatIntervalSec 读取，5-300 钳制）
static const NSTimeInterval kTunnelSelectTimeout = 5.0;    // select 超时（秒，用于触发心跳与重检）
static const NSTimeInterval kTunnelMinRetryDelay = 2.0;    // 最小重连退避（秒）
static const NSTimeInterval kTunnelMaxRetryDelay = 30.0;   // 最大重连退避（秒）

static const uint16_t kLocalRfbPort     = 5901;            // 本地 RFB server 端口
static const NSInteger kDefaultTunnelPort = 18181;         // 默认隧道端口
static const size_t kFrameHeaderSize    = 5;               // 帧头大小：1(type)+4(length)
static const size_t kMaxFramePayload    = 16 * 1024 * 1024; // 单帧 payload 上限（16MB，防损坏帧耗尽内存）
static const size_t kReadBufSize        = 64 * 1024;       // 单次 read 缓冲（64KB）
static const NSTimeInterval kHandshakeTimeout = 10.0;      // 握手 ack 超时（秒）

// DIAG: file log for tunnel passthrough debugging (Filza at /tmp)
static void TRTunnelLog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char buf[512];
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    FILE *f = fopen("/tmp/trollvnc-tunnel.log", "a");
    if (f) {
        fprintf(f, "[%.0f] %s\n", [[NSDate date] timeIntervalSince1970], buf);
        fclose(f);
    }
}

@interface TRTunnelClient () {
    NSString *_host;           // 网关主机
    NSInteger _port;           // 网关隧道端口（默认 18181）
    NSString *_deviceId;       // 设备 ID（握手鉴权）
    NSString *_token;          // 网关鉴权 token（可为 nil）
    NSThread *_workerThread;   // 工作线程
    BOOL _started;             // 是否已启动
    BOOL _connected;           // 是否已连接（含握手成功）
    NSTimeInterval _retryDelay;   // 当前重连退避（秒）
    // 隧道帧解析缓冲（动态扩容）
    uint8_t *_frameBuf;
    size_t _frameBufLen;
    size_t _frameBufCap;
    BOOL _restartLocal;
    // proto:2 通道表：chanId(NSNumber) -> 本地 5901 fd(NSNumber)。
    // 单隧道多路 5901 连接（chan 0 缩略图 + 会话通道），select 循环单线程私有，无需加锁
    NSMutableDictionary<NSNumber *, NSNumber *> *_channels;
    int _tunnelFd;              // 当前隧道 socket fd（握手成功后赋值，供被控状态上报复用）
    pthread_mutex_t _writeMutex;  // _writeFrame 串行化（worker/主线程并发写同一隧道 fd）
    BOOL _kickSessionsRequested;  // 5801 直连接管请求（跨线程标志，@synchronized 保护）
    BOOL _directControlActive;    // 5801 直连控制中（跨线程标志，@synchronized 保护；供会话归零时抑制错误上报 NO）
    BOOL _controlled;           // 最近一次上报的被控状态（去重）
    NSString *_controlledSource; // 最近一次上报的被控来源（@"5801" 直连 / @"tunnel" 隧道，去重）
}
@end

@implementation TRTunnelClient

#pragma mark - 单例与生命周期

/**
 * 获取共享单例（dispatch_once 保证线程安全一次性初始化）
 * @return TRTunnelClient 全局唯一实例
 */
+ (instancetype)sharedClient {
    static TRTunnelClient *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[TRTunnelClient alloc] init];
    });
    return inst;
}

/**
 * 初始化隧道客户端，设置默认重连退避与端口
 * @return 实例对象
 */
- (instancetype)init {
    self = [super init];
    if (self) {
        _retryDelay = kTunnelMinRetryDelay;
        _port = kDefaultTunnelPort;
        pthread_mutex_init(&_writeMutex, NULL);
        _tunnelFd = -1;   // 显式初始化，防御 alloc 清零得到 0 的时序隐患
        _channels = [NSMutableDictionary dictionary];
    }
    return self;
}

/**
 * 析构：释放帧缓冲内存
 */
- (void)dealloc {
    pthread_mutex_destroy(&_writeMutex);
    if (_frameBuf) {
        free(_frameBuf);
        _frameBuf = nil;
    }
}

/**
 * 启动隧道客户端，建立到网关 18181 的连接（异步，在工作线程内完成）
 * @param gatewayHost 网关主机地址
 * @param gatewayPort 网关隧道端口（默认 18181，传 0 或越界用默认值）
 * @param deviceId 设备 ID（用于鉴权握手）
 * @param token 网关鉴权 token（可为 nil）
 * @return YES 表示参数有效并已启动工作线程（异步连接）；NO 表示参数无效
 */
- (BOOL)startWithHost:(NSString *)gatewayHost
                 port:(NSInteger)gatewayPort
             deviceId:(NSString *)deviceId
                token:(NSString *)token {
    if (!gatewayHost.length || !deviceId.length) {
        TVLog(@"[tunnel] start rejected: invalid host/deviceId");
        return NO;
    }
    if (_started) {
        // 已启动：参数变化时先停止再重启，参数一致则幂等返回
        BOOL same = [_host isEqualToString:gatewayHost]
                    && _port == (gatewayPort > 0 ? gatewayPort : kDefaultTunnelPort)
                    && [_deviceId isEqualToString:deviceId];
        if (same) return YES;
        [self stop];
    }
    _host = [gatewayHost copy];
    _port = (gatewayPort > 0 && gatewayPort < 65536) ? gatewayPort : kDefaultTunnelPort;
    _deviceId = [deviceId copy];
    _token = [token copy];
    _retryDelay = kTunnelMinRetryDelay;
    // HeartbeatIntervalSec（gateway 级，5-300s 默认 30）：与 TRGatewayClient 同域读取心跳间隔
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    NSNumber *hb = [ud objectForKey:@"HeartbeatIntervalSec"];
    NSTimeInterval v = hb ? hb.doubleValue : kTunnelPingInterval;
    if (v < 5) v = 5;
    if (v > 300) v = 300;
    gTunnelPingInterval = v;
    _started = YES;
    _workerThread = [[NSThread alloc] initWithTarget:self selector:@selector(_workerMain) object:nil];
    [_workerThread setName:@"com.82flex.trollvnc.tunnel-client"];
    [_workerThread start];
    TVLog(@"[tunnel] client started -> %@:%ld deviceId=%@", _host, (long)_port, _deviceId);
    return YES;
}

/**
 * 停止隧道客户端，断开连接并退出工作线程
 */
- (void)stop {
    _started = NO;
    if (_workerThread) {
        [_workerThread cancel];
        _workerThread = nil;
    }
    _connected = NO;
    TVLog(@"[tunnel] client stopped");
}

/**
 * 隧道是否已连接（含握手成功）
 * @return YES 表示隧道已建立并完成握手
 */
- (BOOL)isConnected {
    return _connected;
}

/**
 * 请求断开所有隧道会话通道（5801 直连接管，2026-08-23）：
 * 仅置标志，由隧道 worker 线程在 select 循环内处理（通道表仅该线程安全访问）。
 * @return void
 */
- (void)requestKickSessions {
    @synchronized(self) {
        _kickSessionsRequested = YES;
    }
}

#pragma mark - 工作线程主循环

/**
 * 工作线程主循环：反复连接网关并运行透传，失败按退避策略重连
 */
- (void)_workerMain {
    while (_started && ![[NSThread currentThread] isCancelled]) {
        @autoreleasepool {
            BOOL ok = [self _connectAndRun];
            if (!ok && _started) {
                TVLog(@"[tunnel] connection lost, retry in %.0fs", _retryDelay);
                usleep((useconds_t)(_retryDelay * 1e6));
                _retryDelay = MIN(_retryDelay * 2, kTunnelMaxRetryDelay);
            }
        }
    }
}

/**
 * 建立到网关的隧道连接并运行透传循环
 * 流程：TCP 连接 → 发 tunnel_hello → 收 tunnel_ack → 连本地 5901 → select 双向透传
 * @return YES 表示因 stop 正常退出（无需重连）；NO 表示连接异常断开（需重连）
 */
- (BOOL)_connectAndRun {
    _connected = NO;
    [self _resetFrameBuf];

    // 1. TCP 连接到网关隧道端口
    int tunnelFd = socket(AF_INET, SOCK_STREAM, 0);
    if (tunnelFd < 0) return NO;

    struct hostent *he = gethostbyname(_host.UTF8String);
    if (!he) { close(tunnelFd); return NO; }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)_port);
    memcpy(&addr.sin_addr, he->h_addr, he->h_length);

    if (connect(tunnelFd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(tunnelFd);
        return NO;
    }
    TVLog(@"[tunnel] connected to %@:%ld", _host, (long)_port);
    TRTunnelLog("tunnel connected %@:%ld", _host, (long)_port);

    // 2. 发送 tunnel_hello 握手
    if (![self _sendHandshakeHello:tunnelFd]) {
        close(tunnelFd);
        return NO;
    }

    // 3. 接收 tunnel_ack（JSON 行，握手阶段用行缓冲）
    BOOL ackOk = NO;
    if (![self _recvHandshakeAck:tunnelFd okOut:&ackOk]) {
        close(tunnelFd);
        return NO;
    }
    if (!ackOk) {
        TVLog(@"[tunnel] handshake rejected by gateway");
        close(tunnelFd);
        return NO;
    }
    TVLog(@"[tunnel] handshake ok, entering passthrough mode");
    _retryDelay = kTunnelMinRetryDelay;

    // 4. 通道由网关 CHAN_OPEN 驱动（proto:2）：隧道就绪后网关先开 chan 0（缩略图），
    //    会话时再开会话通道——设备端在 CHAN_OPEN 处理处同步 connect 5901 + 主动写版本
    _connected = YES;
    // 被控状态上报：握手成功后缓存当前隧道 fd，安装通知监听（首次），复位去重标记
    _tunnelFd = tunnelFd;
    [self _installControlStateListeners];
    _controlled = NO;
    // 通知采集惰性启动（缩略图态基线帧率 CaptureFps；会话通道打开时升频）
    notify_post("com.82flex.trollvnc.capture-idle");
    notify_post("com.82flex.trollvnc.tunnel-connected");
    TRTunnelLog("handshake ok, waiting for CHAN_OPEN (thumb chan 0)");

    // 5. select passthrough (channels driven)
    BOOL normalExit = [self _passthroughLoop:tunnelFd];

    // 6. cleanup
    _connected = NO;
    // 隧道断开（网关重启/断网）：关闭全部通道 fd 并清表
    for (NSNumber *fdNum in [_channels allValues]) {
        int fd = fdNum.intValue;
        if (fd >= 0) close(fd);
    }
    [_channels removeAllObjects];
    close(tunnelFd);
    _tunnelFd = -1;  // 隧道已关闭，复位上报 fd（避免 write 到已关闭/复用的 fd）
    [self _resetFrameBuf];
    return normalExit;
}

#pragma mark - 握手（JSON 行）

/**
 * 发送 tunnel_hello 握手 JSON 行
 * @param fd 隧道 socket fd
 * @return YES 表示发送成功
 */
- (BOOL)_sendHandshakeHello:(int)fd {
    NSMutableDictionary *hello = [NSMutableDictionary dictionary];
    hello[@"type"] = @"tunnel_hello";
    hello[@"deviceId"] = _deviceId;
    hello[@"proto"] = @(kTunnelProto); // proto:2 通道复用协议（网关不匹配即拒绝）
    if (_token.length) hello[@"token"] = _token;
    NSData *json = [NSJSONSerialization dataWithJSONObject:hello options:0 error:NULL];
    if (!json) return NO;
    NSMutableData *md = [json mutableCopy];
    const char nl = '\n';
    [md appendBytes:&nl length:1];
    ssize_t n = write(fd, md.bytes, md.length);
    return n == (ssize_t)md.length;
}

/**
 * 接收 tunnel_ack 握手响应（阻塞读直到 \n 或超时）
 * @param fd    隧道 socket fd
 * @param okOut 输出参数，接收 ack.ok 布尔值
 * @return YES 表示成功收到并解析 ack 行；NO 表示读取失败/超时/解析失败
 */
- (BOOL)_recvHandshakeAck:(int)fd okOut:(BOOL *)okOut {
    char buf[512];
    size_t len = 0;
    time_t deadline = time(NULL) + (time_t)kHandshakeTimeout;
    while (time(NULL) < deadline) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        struct timeval tv;
        tv.tv_sec = 2;
        tv.tv_usec = 0;
        int sel = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (sel <= 0) continue;  // 超时或中断，继续等
        ssize_t n = read(fd, buf + len, sizeof(buf) - len - 1);
        if (n <= 0) return NO;
        len += (size_t)n;
        buf[len] = '\0';
        char *nl = strchr(buf, '\n');
        if (nl) {
            *nl = '\0';
            NSData *data = [NSData dataWithBytes:buf length:strlen(buf)];
            NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if (![msg isKindOfClass:[NSDictionary class]]) return NO;
            if (![msg[@"type"] isEqualToString:@"tunnel_ack"]) return NO;
            *okOut = [msg[@"ok"] boolValue];
            // 换行后剩余字节可能是首个帧数据，追加到帧缓冲
            size_t consumed = (size_t)((nl - buf) + 1);
            if (len > consumed) {
                [self _appendFrameData:(const uint8_t *)(buf + consumed) length:(len - consumed)];
            }
            return YES;
        }
        if (len >= sizeof(buf) - 1) return NO;  // 超长无换行，异常
    }
    return NO;  // 超时
}

#pragma mark - 本地 RFB 连接

/**
 * 建立到本地 RFB server（127.0.0.1:5901）的 TCP 连接
 * @return 连接成功的 fd（>=0）；失败返回 -1
 */
- (int)_connectLocalRfb {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kLocalRfbPort);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

#pragma mark - 透传主循环（select 多路复用）

/**
 * select 多路复用双向透传循环
 * 隧道可读 → 帧解析 → CHAN_DATA 写对应通道 fd / PONG 重置心跳 / CMD 调 commandHandler 回 CMDACK
 * 通道 fd 可读 → 封装 CHAN_DATA 帧写隧道（按 chanId）
 * 按 HeartbeatIntervalSec（默认 30s）间隔发 PING 心跳帧
 * @param tunnelFd 隧道 socket fd
 * @return YES 表示因 stop 正常退出；NO 表示连接异常断开（需重连）
 */
- (BOOL)_passthroughLoop:(int)tunnelFd {
    uint8_t *readBuf = (uint8_t *)malloc(kReadBufSize);
    if (!readBuf) return NO;
    time_t lastPing = time(NULL);

    while (_started && ![[NSThread currentThread] isCancelled]) {
        // 5801 直连接管（2026-08-23）：隧道会话通道让位——仅本线程访问 _channels，
        // 在此统一关闭所有会话通道（reason=1 通知网关清理会话 → 网关前端断开），
        // _closeChannel 自动降频 + 上报被控结束；chan 0 缩略图保留。
        BOOL kick = NO;
        @synchronized(self) { kick = _kickSessionsRequested; _kickSessionsRequested = NO; }
        if (kick) {
            NSArray<NSNumber *> *sessionChans = [[_channels allKeys]
                filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id cid, NSDictionary *bd) {
                    return [(NSNumber *)cid unsignedShortValue] != kChanIdThumb;
                }]];
            for (NSNumber *cid in sessionChans) {
                TRTunnelLog("kick session chan %u (5801 takeover)", cid.unsignedShortValue);
                // reason=3：5801 直连接管（区别于本地 EOF 的 1）——网关据此关前端 WS 4001
                [self _closeChannel:cid.unsignedShortValue reason:3];
            }
        }
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(tunnelFd, &rfds);
        int maxFd = tunnelFd;
        // 通道 fd 全部加入 select 读集合（chan 0 缩略图 + 会话通道）
        for (NSNumber *fdNum in [_channels allValues]) {
            int fd = fdNum.intValue;
            if (fd < 0) continue;
            FD_SET(fd, &rfds);
            if (fd > maxFd) maxFd = fd;
        }
        struct timeval tv;
        tv.tv_sec = (time_t)kTunnelSelectTimeout;
        tv.tv_usec = 0;
        int sel = select(maxFd + 1, &rfds, NULL, NULL, &tv);
        if (sel < 0) {
            free(readBuf);
            return NO;
        }
        if (sel == 0) {
            // timeout: heartbeat
            time_t now = time(NULL);
            if (now - lastPing >= (time_t)gTunnelPingInterval) {
                if (![self _writeFrame:tunnelFd type:kFrameTypePing data:NULL length:0]) {
                    free(readBuf);
                    return NO;
                }
                lastPing = now;
            }
            continue;
        }
        // tunnel readable
        if (FD_ISSET(tunnelFd, &rfds)) {
            ssize_t n = read(tunnelFd, readBuf, kReadBufSize);
            if (n <= 0) { free(readBuf); return NO; }
            [self _appendFrameData:readBuf length:(size_t)n];
            TRTunnelLog("tunnel readable, read %zd bytes, frameBufLen=%zu", n, _frameBufLen);
            if (![self _processFramesTunnel:tunnelFd]) {
                TRTunnelLog("processFrames returned NO");
                free(readBuf);
                return NO;
            }
        }
        // 通道 fd readable：反查 chanId，封装 CHAN_DATA 上行
        for (NSNumber *chanNum in [_channels allKeys]) {
            int fd = [_channels[chanNum] intValue];
            if (fd < 0 || !FD_ISSET(fd, &rfds)) continue;
            ssize_t n = read(fd, readBuf, kReadBufSize);
            if (n <= 0) {
                // 本地 5901 连接关闭（服务端断开/异常）是正常事件：仅清理该通道，
                // 绝不能退出隧道（否则隧道重连导致网关 4002 tunnel closed）
                [self _closeChannel:chanNum.unsignedShortValue reason:1];
                continue;
            }
            TRTunnelLog("chan %@ readable, read %zd bytes, sending CHAN_DATA", chanNum, n);
            // 封装 [chanId:2BE][rfb字节]
            uint8_t hdr[2];
            uint16_t cid = chanNum.unsignedShortValue;
            hdr[0] = (uint8_t)(cid >> 8);
            hdr[1] = (uint8_t)(cid & 0xFF);
            uint8_t *frame = (uint8_t *)malloc(2 + (size_t)n);
            if (!frame) { free(readBuf); return NO; }
            memcpy(frame, hdr, 2);
            memcpy(frame + 2, readBuf, (size_t)n);
            BOOL ok = [self _writeFrame:tunnelFd type:kFrameTypeChanData data:frame length:2 + (size_t)n];
            free(frame);
            if (!ok) {
                TRTunnelLog("CHAN_DATA write to tunnel failed");
                free(readBuf);
                return NO;
            }
        }
    }
    free(readBuf);
    return YES;  // stop
}

#pragma mark - 帧封装/解析

/**
 * 向帧缓冲追加原始字节（隧道读到的数据，可能含多个/部分帧）
 * @param data 数据指针
 * @param len  数据长度
 */
- (void)_appendFrameData:(const uint8_t *)data length:(size_t)len {
    if (len == 0) return;
    size_t need = _frameBufLen + len;
    if (need > _frameBufCap) {
        size_t newCap = _frameBufCap ? _frameBufCap : 8192;
        while (newCap < need) newCap *= 2;
        uint8_t *p = (uint8_t *)realloc(_frameBuf, newCap);
        if (!p) {
            // 内存分配失败：丢弃缓冲防止状态混乱
            TVLog(@"[tunnel] frame buf alloc failed, resetting");
            [self _resetFrameBuf];
            return;
        }
        _frameBuf = p;
        _frameBufCap = newCap;
    }
    memcpy(_frameBuf + _frameBufLen, data, len);
    _frameBufLen += len;
}

/**
 * 重置帧解析缓冲（释放内存并清零计数）
 */
- (void)_resetFrameBuf {
    if (_frameBuf) {
        free(_frameBuf);
        _frameBuf = nil;
    }
    _frameBufLen = 0;
    _frameBufCap = 0;
}

/**
 * 处理帧缓冲中所有完整帧：
 *   DATA   → 写本地 RFB 5901
 *   PONG   → 心跳响应（链路存活即可）
 *   PING   → 回 PONG（双向保活）
 *   CMD    → 调 commandHandler 处理，回 CMDACK
 *   其它   → 忽略并告警
 * @param tunnelFd 隧道 fd（用于回 CMDACK/PONG）
 * @param localFd  本地 RFB fd（DATA 帧 payload 写入此处）
 * @return YES 表示处理正常（可继续）；NO 表示本地 RFB 写失败（需断开重连）
 */
- (BOOL)_processFramesTunnel:(int)tunnelFd {
    while (_frameBufLen >= kFrameHeaderSize) {
        uint8_t type = _frameBuf[0];
        uint32_t payloadLen = ((uint32_t)_frameBuf[1] << 24) | ((uint32_t)_frameBuf[2] << 16)
                            | ((uint32_t)_frameBuf[3] << 8) | (uint32_t)_frameBuf[4];
        if (payloadLen > kMaxFramePayload) {
            TVLog(@"[tunnel] frame too large (%u), resetting", payloadLen);
            [self _resetFrameBuf];
            return YES;
        }
        size_t total = kFrameHeaderSize + payloadLen;
        if (_frameBufLen < total) break;  // 不完整，等更多数据

        const uint8_t *payload = _frameBuf + kFrameHeaderSize;
        switch (type) {
            case kFrameTypeChanOpen: {
                // 通道建立（网关→设备）：[chanId:2BE][kind:1B]
                // 同步 connect 本地 5901 + 主动写协议版本（5901 握手窗口 0-50ms 极窄，
                // 绕过网关往返延迟），回 CHAN_ACK 携带 connect 结果——网关据此精确放行
                // 该通道缓冲的握手字节（替代 proto:1 的 rfb.start ack 窗口）
                if (payloadLen < 3) break;
                uint16_t chanId = ((uint16_t)payload[0] << 8) | payload[1];
                uint8_t kind = payload[2];
                int fd = [self _connectLocalRfb];
                BOOL ok = (fd >= 0);
                if (ok) {
                    _channels[@(chanId)] = @(fd);
                    const char kLocalVersion[] = "RFB 003.008\n";
                    ssize_t vw = write(fd, kLocalVersion, sizeof(kLocalVersion) - 1);
                    TRTunnelLog("CHAN_OPEN chan=%u kind=%u fd=%d vw=%zd", chanId, kind, fd, vw);
                    if (kind == kChanKindSession) {
                        // 会话通道：升频到 FrameRateSpec（屏幕流）+ 上报被控状态
                        notify_post("com.82flex.trollvnc.capture-active");
                        [self _reportControlState:YES source:@"tunnel"];
                        // 方向2 互斥（2026-08-23）：网关控制会话建立 → 踢 5801 直连（非 loopback）。
                        // 跨进程 notify 到 trollvncserver 断开 5801 客户端，与方向1（5801 接管踢隧道）
                        // 对称，保证任意时刻仅一个控制者。无 5801 客户端时对端 no-op。
                        notify_post("com.82flex.trollvnc.tunnel-kick-remote");
                    }
                } else {
                    TVLog(@"[tunnel] CHAN_OPEN chan=%u local connect failed", chanId);
                    TRTunnelLog("CHAN_OPEN chan=%u connect failed", chanId);
                }
                uint8_t ackBuf[3];
                ackBuf[0] = (uint8_t)(chanId >> 8);
                ackBuf[1] = (uint8_t)(chanId & 0xFF);
                ackBuf[2] = ok ? 1 : 0;
                [self _writeFrame:tunnelFd type:kFrameTypeChanAck data:ackBuf length:3];
                break;
            }
            case kFrameTypeChanData: {
                // 通道 RFB 数据（网关→设备）：[chanId:2BE][rfb字节]
                if (payloadLen < 2) break;
                uint16_t chanId = ((uint16_t)payload[0] << 8) | payload[1];
                NSNumber *fdNum = _channels[@(chanId)];
                if (!fdNum) {
                    // 未知通道：丢弃 + 回 CHAN_CLOSE（重同步，防协议污染）
                    TVLog(@"[tunnel] CHAN_DATA for unknown chan %u, dropping", chanId);
                    uint8_t closeBuf[3];
                    closeBuf[0] = (uint8_t)(chanId >> 8);
                    closeBuf[1] = (uint8_t)(chanId & 0xFF);
                    closeBuf[2] = 2; // reason=错误
                    [self _writeFrame:tunnelFd type:kFrameTypeChanClose data:closeBuf length:3];
                    break;
                }
                int fd = fdNum.intValue;
                // 2026-08-23 恢复（proto:2 改造误删）：重复协议版本过滤——CHAN_OPEN 后本进程
                // 已主动向本地 5901 写入 "RFB 003.008\n"（抢 0-50ms 握手窗口），网关缩略图
                // 解码器（chan 0）收到服务端版本后也会回版本行，若再写入 5901 服务端已在
                // 安全类型阶段 → wrong security type (82) → 断开 → chan 0 循环 EOF。
                // 12B 且以 "RFB 003." 开头的帧视为重复协议版本，丢弃（后续字节照常）。
                if (payloadLen - 2 == 12 && memcmp(payload + 2, "RFB 003.", 8) == 0) {
                    TRTunnelLog("drop duplicate client version (chan %u)", chanId);
                    break;
                }
                size_t off = 2;
                while (off < payloadLen) {
                    ssize_t w = write(fd, payload + off, payloadLen - off);
                    TRTunnelLog("CHAN_DATA chan=%u write local fd=%d -> %zd (off=%zu)", chanId, fd, w, off);
                    if (w <= 0) {
                        TVLog(@"[tunnel] write local RFB failed (chan %u)", chanId);
                        TRTunnelLog("write local RFB failed w=%zd errno=%d", w, errno);
                        return NO;
                    }
                    off += (size_t)w;
                }
                break;
            }
            case kFrameTypeChanClose: {
                // 通道关闭（网关→设备）：[chanId:2BE][reason:1B]
                if (payloadLen < 2) break;
                uint16_t chanId = ((uint16_t)payload[0] << 8) | payload[1];
                [self _closeChannel:chanId reason:0];
                break;
            }
            case kFrameTypePong:
                // 心跳响应：收到即表示链路存活
                break;
            case kFrameTypePing:
                // 网关主动 ping 时回 pong（双向保活）
                [self _writeFrame:tunnelFd type:kFrameTypePong data:NULL length:0];
                break;
            case kFrameTypeCmd: {
                // 命令帧：解析 JSON，调 commandHandler 处理，回 CMDACK
                NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:
                    [NSData dataWithBytes:payload length:payloadLen] options:0 error:NULL];
                if (![cmd isKindOfClass:[NSDictionary class]]) break;
                NSDictionary *ack = self.commandHandler ? self.commandHandler(cmd) : nil;
                if (!ack) {
                    ack = @{ @"type": @"ack",
                             @"id": cmd[@"id"] ?: [NSNull null],
                             @"ok": @NO,
                             @"error": @"no command handler" };
                }
                NSData *ackJson = [NSJSONSerialization dataWithJSONObject:ack options:0 error:NULL];
                if (ackJson) {
                    [self _writeFrame:tunnelFd type:kFrameTypeCmdAck data:ackJson.bytes length:ackJson.length];
                }
                break;
            }
            case kFrameTypeCmdAck:
                // 设备侧不主动发命令，CMDACK 帧忽略
                break;
            default:
                TVLog(@"[tunnel] unknown frame type 0x%02x, ignoring", type);
                break;
        }
        // 移除已处理帧
        size_t remain = _frameBufLen - total;
        if (remain > 0) {
            memmove(_frameBuf, _frameBuf + total, remain);
        }
        _frameBufLen = remain;
    }
    return YES;
}

/**
 * 关闭一个通道：关本地 5901 fd、清表项、按需降频/上报被控状态、通知网关
 * @param chanId 通道号（0=缩略图，其余=会话）
 * @param reason 0=网关主动关闭（不回通知）；1=本地 EOF（回 CHAN_CLOSE reason=1）；
 *               3=5801 直连接管（回 CHAN_CLOSE reason=3，网关据此关前端 WS 4001）
 */
- (void)_closeChannel:(uint16_t)chanId reason:(uint8_t)reason {
    NSNumber *fdNum = _channels[@(chanId)];
    if (!fdNum) return;
    int fd = fdNum.intValue;
    if (fd >= 0) close(fd);
    [_channels removeObjectForKey:@(chanId)];
    BOOL isSession = (chanId != kChanIdThumb);
    if (isSession) {
        // 会话通道关闭：若已无任何会话通道，降频 + 上报被控结束
        BOOL anySession = NO;
        for (NSNumber *cid in _channels) {
            if (cid.unsignedShortValue != kChanIdThumb) { anySession = YES; break; }
        }
        if (!anySession) {
            // 2026-08-23 竞态修复：5801 直连接管踢会话时，control-active 通知是异步的，
            // 此处若无条件上报 NO 会覆盖 5801 的 controlled=YES（时序不定）→ 网关卡片
            // 不显示「被 5801 控制中」。仅当 5801 也未在控制时才上报被控结束。
            BOOL directActive = NO;
            @synchronized(self) { directActive = _directControlActive; }
            if (!directActive) {
                notify_post("com.82flex.trollvnc.capture-idle");
                [self _reportControlState:NO source:nil];
            }
        }
    }
    if (reason == 1 || reason == 3) {
        // 本地 EOF（1）/ 5801 接管（3）：通知网关关闭该通道（网关清理会话）
        uint8_t closeBuf[3];
        closeBuf[0] = (uint8_t)(chanId >> 8);
        closeBuf[1] = (uint8_t)(chanId & 0xFF);
        closeBuf[2] = reason;
        [self _writeFrame:_tunnelFd type:kFrameTypeChanClose data:closeBuf length:3];
    }
    TRTunnelLog("chan %u closed (reason=%u)", chanId, reason);
}

/**
 * 写入一个帧到隧道 fd（type + 4字节大端 length + payload）
 * @param fd   隧道 socket fd
 * @param type 帧类型（DATA/PING/PONG/CMD/CMDACK）
 * @param data payload 指针（PING/PONG 可传 NULL）
 * @param len  payload 长度
 * @return YES 表示写入成功
 */
- (BOOL)_writeFrame:(int)fd type:(uint8_t)type data:(const void *)data length:(size_t)len {
    pthread_mutex_lock(&_writeMutex);
    BOOL ok = [self _writeFrameLocked:fd type:type data:data length:len];
    pthread_mutex_unlock(&_writeMutex);
    return ok;
}

- (BOOL)_writeFrameLocked:(int)fd type:(uint8_t)type data:(const void *)data length:(size_t)len {
    uint8_t header[kFrameHeaderSize];
    header[0] = type;
    header[1] = (uint8_t)((len >> 24) & 0xFF);
    header[2] = (uint8_t)((len >> 16) & 0xFF);
    header[3] = (uint8_t)((len >> 8) & 0xFF);
    header[4] = (uint8_t)(len & 0xFF);
    ssize_t n = write(fd, header, kFrameHeaderSize);
    if (n != (ssize_t)kFrameHeaderSize) return NO;
    if (len > 0 && data) {
        size_t off = 0;
        while (off < len) {
            ssize_t w = write(fd, (const uint8_t *)data + off, len - off);
            if (w <= 0) return NO;
            off += (size_t)w;
        }
    }
    return YES;
}

/** 被控状态上报：状态变化时经隧道 FT_STATE 帧推网关（去重，避免重复推送）
 *  source：@"5801"（非 loopback 直连控制）/ @"tunnel"（隧道会话通道控制）；controlled=NO 时忽略 */
- (void)_reportControlState:(BOOL)controlled source:(NSString *)source {
    if (controlled == _controlled && [source isEqualToString:_controlledSource]) return;
    _controlled = controlled;
    _controlledSource = source;
    NSDictionary *msg = @{ @"type": @"state", @"controlled": @(controlled),
                           @"source": source ?: @"tunnel" };
    NSData *json = [NSJSONSerialization dataWithJSONObject:msg options:0 error:NULL];
    if (json && _tunnelFd >= 0) {
        [self _writeFrame:_tunnelFd type:kFrameTypeState data:json.bytes length:json.length];
    }
}

/** 安装被控状态通知监听（首次调用时注册，重复调用无副作用） */
- (void)_installControlStateListeners {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    static int activeTok = 0, idleTok = 0, kickTok = 0;
    notify_register_dispatch("com.82flex.trollvnc.control-active", &activeTok,
        dispatch_get_main_queue(), ^(int t) {
        (void)t;
        // 5801 直连控制开始：置标志（供隧道会话归零时抑制错误上报 NO）+ 上报被控
        @synchronized(self) { _directControlActive = YES; }
        [self _reportControlState:YES source:@"5801"];
    });
    notify_register_dispatch("com.82flex.trollvnc.control-idle", &idleTok,
        dispatch_get_main_queue(), ^(int t) {
        (void)t;
        @synchronized(self) { _directControlActive = NO; }
        [self _reportControlState:NO source:nil];
    });
    // 5801 直连接管（2026-08-23）：trollvncserver（不同编译目标）经 notify 请求踢会话通道，
    // 主线程转发到线程安全的 requestKickSessions（仅置标志，隧道 worker 线程统一关闭）
    notify_register_dispatch("com.82flex.trollvnc.tunnel-kick-sessions", &kickTok,
        dispatch_get_main_queue(), ^(int t) { (void)t; [self requestKickSessions]; });
}

@end
