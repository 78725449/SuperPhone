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

#import <Foundation/Foundation.h>

#import <arpa/inet.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <notify.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/proc_info.h>
#import <sys/socket.h>
#import <sys/sysctl.h>
#import <unistd.h>

#import "Control.h"
#import "TRGatewayClient.h"
#import "TRTunnelClient.h"
#import "Logging.h"
#import "TRWatchDog.h"
#import "SimLocationManager.h"
#import "libproc.h"

#define SINGLETON_MARKER_PATH "/var/mobile/Library/Caches/com.82flex.trollvnc.manager.pid"

BOOL tvncLoggingEnabled = YES;
BOOL tvncVerboseLoggingEnabled = NO;

static TRWatchDog *gWatchDog = nil;

// 2026-08-21：trollvncserver 崩溃日志路径（watchdog 重定向的 stdout/stderr 文件）。
// 由 main 在计算 jailbreak root 后赋值，供日志 HTTP 端点（5902）远程读取——manager 常驻，
// 即使 trollvncserver 崩溃循环，日志端点仍可用（5801/5802/5901 均随 server 失效）。
static NSString *gLogStdoutPath = nil;
static NSString *gLogStderrPath = nil;

static void mSignalAction(int signal, struct __siginfo *info, void *context) {
    if (signal == SIGCHLD) {
        int status = 0;
        pid_t p = waitpid(info->si_pid, &status, WNOHANG);
        // 2026-08-21 诊断：打印收割的子进程真实退出状态——watchdog 的 TRTask 也在 waitpid
        // 同一子进程（竞争），此处理会先收割导致 TRTask 误报 "exited with code: 0"，
        // 真实死因（signal/exit）被掩盖。打印到 server stderr 文件（manager stderr 已并入）供 5902 读取。
        if (p > 0) {
            fprintf(stderr, "MANAGER: SIGCHLD reaped pid=%d status=0x%x signaled=%d sig=%d exit=%d\n",
                    p, status, WIFSIGNALED(status) ? 1 : 0,
                    WIFSIGNALED(status) ? WTERMSIG(status) : 0,
                    WIFEXITED(status) ? WEXITSTATUS(status) : -1);
        }
    }
}

static void mSignalHandler(int signal) {
    fprintf(stderr, "signal %d received\n", signal);

    /* Terminate itself */
    if (signal == SIGHUP || signal == SIGINT) {
        CFRunLoopStop(CFRunLoopGetMain());
    } else if (signal == SIGTERM) {
        exit((EXIT_FAILURE << 7) | signal);
    }
}

/// 2026-08-20：清理残留 trollvncserver 孤儿进程。manager 重启/被杀后旧 server 不再受
/// watchdog 管辖、仍占用 5901/5801/5802 → 新 server bind 失败（画面全挂）。本进程以 root
/// 运行，sysctl KERN_PROCARGS2 可读任意进程 argv（App 沙盒内同调用返回 EPERM，协调器侧
/// 枚举不可靠，故必须在此侧清理）。不用 libproc（Theos SDK 头不全，proc_listallpids 未声明）。
static void killStaleVncServer(void) {
    size_t len = 0;
    if (sysctl((int[]){CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0}, 4, NULL, &len, NULL, 0) < 0) return;
    struct kinfo_proc *procs = (struct kinfo_proc *)calloc(1, len + sizeof(struct kinfo_proc));
    if (!procs) return;
    if (sysctl((int[]){CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0}, 4, procs, &len, NULL, 0) < 0) {
        free(procs);
        return;
    }
    int cnt = (int)(len / sizeof(struct kinfo_proc));
    char *argBuf = (char *)calloc(1, 4097);
    if (!argBuf) { free(procs); return; }
    for (int i = 0; i < cnt; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 1) continue;
        size_t argSize = 4096;
        memset(argBuf, 0, 4097);
        if (sysctl((int[]){CTL_KERN, KERN_PROCARGS2, pid, 0}, 4, argBuf, &argSize, NULL, 0) < 0) continue;
        const char *exe = argBuf + sizeof(int);
        const char *base = strrchr(exe, '/');
        base = base ? base + 1 : exe;
        if (strcmp(base, "trollvncserver") == 0) {
            fprintf(stderr, "[manager] kill stale trollvncserver pid=%d\n", pid);
            kill(pid, SIGKILL);
        }
    }
    free(argBuf);
    free(procs);
}

static void monitorSelfAndRestartIfVnodeDeleted(const char *executable) {
    int myHandle = open(executable, O_EVTONLY);
    if (myHandle <= 0) {
        return;
    }

    static unsigned long monitorMask = DISPATCH_VNODE_DELETE;
    static dispatch_source_t monitorSource;
    monitorSource =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, myHandle, monitorMask, dispatch_get_main_queue());

    dispatch_source_set_event_handler(monitorSource, ^{
        unsigned long flags = dispatch_source_get_data(monitorSource);
        if (flags & DISPATCH_VNODE_DELETE) {
            dispatch_source_cancel(monitorSource);
            exit(EXIT_SUCCESS);
        }
    });

    dispatch_resume(monitorSource);
}

/// 2026-08-20 双域配置读取：root defaults 优先，mobile 域 plist 兜底。
/// App 设置页（mobile 用户）写 mobile 域，manager（root）的 NSUserDefaults 实例读不到，
/// 须文件级兜底——与 TRGatewayClient _gatewayHost 同款双域链。
static id tvManagerReadPref(NSUserDefaults *defaults, NSString *key) {
    id v = [defaults objectForKey:key];
    if (v) return v;
    NSDictionary *mobilePrefs = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.82flex.trollvnc.plist"];
    return mobilePrefs[key];
}

/// 当前是否桥接控制模式（ConnectionMode=bridge：本机仅控制端，不注册/不开隧道）。
/// 默认 relay（未设置/非 bridge 均按中继处理）。
static BOOL tvManagerIsBridgeMode(void) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    id mode = tvManagerReadPref(defaults, @"ConnectionMode");
    return [mode isKindOfClass:[NSString class]] && [mode isEqualToString:@"bridge"];
}

// Open a local IPv4 TCP listener on 127.0.0.1:port that accepts and
// immediately closes connections (no response). This lets clients detect
// the service by a successful connect without any protocol exchange.
static void openLocalDummyService(uint16_t port) {
    static int sListenFD = -1;
    static dispatch_source_t sAcceptSource = nil;
    if (sListenFD != -1 || sAcceptSource) {
        return; // already set up
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        fprintf(stderr, "[dummy-listener] socket() failed: %s\n", strerror(errno));
        return;
    }

    int yes = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    // Non-blocking for accept loop
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags != -1)
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    // 2026-08-20：防 fd 继承——子进程（trollvncserver 经 posix_spawn 继承 fd）不得持有
    // 46751 探活监听，否则 manager 被 kill 后孤儿进程仍监听该端口，协调器端口探活误判
    // "manager 存活" → 永不重新 spawn → 设备永久失联（重置默认值事故的次要因子）。
    int fdflags = fcntl(fd, F_GETFD, 0);
    if (fdflags != -1)
        fcntl(fd, F_SETFD, fdflags | FD_CLOEXEC);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[dummy-listener] bind(127.0.0.1:%u) failed: %s\n", (unsigned)port, strerror(errno));
        close(fd);
        return;
    }

    if (listen(fd, SOMAXCONN) < 0) {
        fprintf(stderr, "[dummy-listener] listen() failed: %s\n", strerror(errno));
        close(fd);
        return;
    }

    sListenFD = fd;
    sAcceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_main_queue());
    if (!sAcceptSource) {
        close(fd);
        sListenFD = -1;
        return;
    }

    dispatch_source_set_event_handler(sAcceptSource, ^{
        while (1) {
            struct sockaddr_storage clientAddr;
            socklen_t clientLen = sizeof(clientAddr);
            int cfd = accept(fd, (struct sockaddr *)&clientAddr, &clientLen);
            if (cfd < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                    break;
                }
                // Unexpected error; break to avoid busy loop
                break;
            }
            // Immediately close; no response needed
            close(cfd);
        }
    });

    dispatch_source_set_cancel_handler(sAcceptSource, ^{
        if (sListenFD != -1) {
            close(sListenFD);
            sListenFD = -1;
        }
    });

    dispatch_resume(sAcceptSource);
    fprintf(stderr, "[dummy-listener] listening on 127.0.0.1:%u\n", (unsigned)port);
}

// 2026-08-21：远程日志端点（局域网 0.0.0.0:5902）。GET /stderr 返回 trollvncserver 崩溃日志
// 尾部 64KB、GET /stdout 返回 stdout 尾部 64KB。独立于 trollvncserver（随其崩溃仍可用），
// 供 AI/脚本远程读取崩溃日志定位根因。无鉴权（仅内网，与 5802 管理 API 同等级别）。
static const uint16_t kLogHttpPort = 5902;

static NSString *tvReadLogTail(NSString *path, NSUInteger maxBytes) {
    if (!path) return @"";
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return @"(log file not found)";
    unsigned long long size = [fh seekToEndOfFile];
    unsigned long long off = (size > maxBytes) ? (size - maxBytes) : 0;
    [fh seekToFileOffset:off];
    NSData *data = [fh readDataToEndOfFile];
    [fh closeFile];
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}

static NSString *tvReadLogHead(NSString *path, NSUInteger maxBytes) {
    if (!path) return @"";
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return @"(log file not found)";
    NSData *data = [fh readDataOfLength:maxBytes];
    [fh closeFile];
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}

static void tvLogHttpWriteRaw(int fd, const char *head, NSData *body) {
    NSMutableData *out = [NSMutableData dataWithBytes:head length:strlen(head)];
    [out appendData:body];
    const char *base = (const char *)out.bytes;
    ssize_t written = 0;
    while (written < (ssize_t)out.length) {
        ssize_t n = write(fd, base + written, out.length - (NSUInteger)written);
        if (n <= 0) break;
        written += n;
    }
}

static void tvLogHttpHandleClient(int cfd) {
    // 监听 fd 为 O_NONBLOCK（dispatch_source accept 需要），accept 返回的 cfd 在 macOS
    // 上会继承该标志 → recv 立即 EAGAIN 被误判为连接关闭。此处显式改回阻塞模式。
    int fl = fcntl(cfd, F_GETFL, 0);
    if (fl != -1) fcntl(cfd, F_SETFL, fl & ~O_NONBLOCK);

    char buf[1024];
    ssize_t n = recv(cfd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) { close(cfd); return; }
    buf[n] = '\0';
    NSString *reqLine = [[[NSString stringWithUTF8String:buf] componentsSeparatedByString:@"\r\n"] firstObject];
    NSString *path = nil;
    if ([reqLine hasPrefix:@"GET "]) {
        NSArray *parts = [reqLine componentsSeparatedByString:@" "];
        if (parts.count >= 2) path = parts[1];
    }
    NSString *logPath = nil;
    if ([path isEqualToString:@"/stderr"]) {
        logPath = gLogStderrPath;
    } else if ([path isEqualToString:@"/stdout"]) {
        logPath = gLogStdoutPath;
    } else if ([path isEqualToString:@"/tunnel"]) {
        // TRTunnelClient 透传日志（帧读写/握手字节流转），定位画面黑根因用。
        // 注意：TRTunnelClient 运行在 trollvncserver 进程内，其 /tmp 是 jailbreak root 的
        // /tmp（非系统 /tmp），故从 gLogStderrPath 推导同目录而非硬编码 /tmp。
        NSString *dir = [gLogStderrPath stringByDeletingLastPathComponent];
        logPath = [dir stringByAppendingPathComponent:@"trollvnc-tunnel.log"];
    } else if ([path hasPrefix:@"/crash/"]) {
        // 崩溃报告：/crash/trollvncserver-<时间戳>.ips 读取指定 .ips 文件内容（SIGILL 定位用）。
        // manager 以 root 运行，可读 /var/mobile/Library/Logs/CrashReporter/。
        NSString *name = [path substringFromIndex:7];
        // 防路径穿越：仅允许 CrashReporter 目录内的 .ips 文件
        if (name.length && [name hasSuffix:@".ips"] && ![name containsString:@"/"] && ![name containsString:@".."]) {
            logPath = [@"/var/mobile/Library/Logs/CrashReporter" stringByAppendingPathComponent:name];
        }
    } else if ([path isEqualToString:@"/crashlist"]) {
        // 崩溃报告列表：返回 CrashReporter 目录内 trollvncserver-*.ips 文件名（换行分隔）
        NSMutableString *listing = [NSMutableString string];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var/mobile/Library/Logs/CrashReporter" error:NULL];
        for (NSString *f in files) {
            if ([f hasPrefix:@"trollvncserver-"] && [f hasSuffix:@".ips"]) {
                [listing appendFormat:@"%@\n", f];
            }
        }
        NSData *lbody = [listing dataUsingEncoding:NSUTF8StringEncoding];
        char lhead[256];
        snprintf(lhead, sizeof(lhead),
                 "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n"
                 "Access-Control-Allow-Origin: *\r\nConnection: close\r\nContent-Length: %lu\r\n\r\n",
                 (unsigned long)lbody.length);
        tvLogHttpWriteRaw(cfd, lhead, lbody);
        close(cfd);
        return;
    }
    if (!logPath) {
        const char *notFound = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n";
        (void)send(cfd, notFound, strlen(notFound), 0);
        close(cfd);
        return;
    }
    // 崩溃报告读头部（堆栈在文件开头）；其余日志读尾部
    BOOL isCrashReport = [path hasPrefix:@"/crash/"];
    NSString *content;
    if (isCrashReport) {
        content = tvReadLogHead(logPath, 128 * 1024);
    } else {
        content = tvReadLogTail(logPath, 64 * 1024);
    }
    NSData *body = [content dataUsingEncoding:NSUTF8StringEncoding];
    char head[256];
    snprintf(head, sizeof(head),
             "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n"
             "Access-Control-Allow-Origin: *\r\nConnection: close\r\nContent-Length: %lu\r\n\r\n",
             (unsigned long)body.length);
    tvLogHttpWriteRaw(cfd, head, body);
    close(cfd);
}

static void openLogHttpService(void) {
    static int sLogFD = -1;
    static dispatch_source_t sLogSource = nil;
    if (sLogFD != -1 || sLogSource) return;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    int yes = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags != -1) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kLogHttpPort);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[log-http] bind 0.0.0.0:%u failed: %s\n", (unsigned)kLogHttpPort, strerror(errno));
        close(fd);
        return;
    }
    if (listen(fd, 8) < 0) {
        fprintf(stderr, "[log-http] listen failed: %s\n", strerror(errno));
        close(fd);
        return;
    }

    sLogFD = fd;
    sLogSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_main_queue());
    if (!sLogSource) { close(fd); sLogFD = -1; return; }
    dispatch_source_set_event_handler(sLogSource, ^{
        while (1) {
            int cfd = accept(fd, NULL, NULL);
            if (cfd < 0) break;
            // 读日志是轻量 IO，但为不阻塞 manager 主 runloop（watchdog 心跳依赖），
            // 每连接独立线程处理（与 5802 每连接线程同策略）。
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                tvLogHttpHandleClient(cfd);
            });
        }
    });
    dispatch_source_set_cancel_handler(sLogSource, ^{
        if (sLogFD != -1) { close(sLogFD); sLogFD = -1; }
    });
    dispatch_resume(sLogSource);
    fprintf(stderr, "[log-http] listening on 0.0.0.0:%u (stderr/stdout tail)\n", (unsigned)kLogHttpPort);
}

int main(int argc, const char *argv[]) {
    /* 2026-08-21 诊断：stderr 无缓冲（重定向到日志文件后是全缓冲，崩溃/信号时不 flush 丢诊断）*/
    setvbuf(stderr, NULL, _IONBF, 0);
    if (!argv || !argv[0] || argv[0][0] != '/') {
        fprintf(stderr, "This program must be run from an absolute path\n");
        return EXIT_FAILURE;
    }

    /* Singleton */
    monitorSelfAndRestartIfVnodeDeleted(argv[0]);

    NSString *markerPath = @SINGLETON_MARKER_PATH;
    const char *cMarkerPath = [markerPath fileSystemRepresentation];

    // Open file for read/write, create if doesn't exist
    static int lockFD = open(cMarkerPath, O_RDWR | O_CREAT, 0644);
    if (lockFD == -1) {
        fprintf(stderr, "Failed to open lock file: %s\n", strerror(errno));
        return EXIT_FAILURE;
    }

    // Try to acquire an exclusive lock
    struct flock fl;
    fl.l_type = F_WRLCK;
    fl.l_whence = SEEK_SET;
    fl.l_start = 0;
    fl.l_len = 0; // Lock entire file

    if (fcntl(lockFD, F_SETLK, &fl) == -1) {
        // Lock already held by another process
        fprintf(stderr, "Another instance is already running\n");
        close(lockFD);
        return EXIT_FAILURE;
    }

    // Truncate the file to clear any previous content
    if (ftruncate(lockFD, 0) == -1) {
        fprintf(stderr, "Failed to truncate lock file: %s\n", strerror(errno));
        // Continue anyway
    }

    // Write PID to file
    pid_t pid = getpid();
    char pidStr[16];
    int len = snprintf(pidStr, sizeof(pidStr), "%d\n", pid);
    if (write(lockFD, pidStr, len) != len) {
        fprintf(stderr, "Failed to write PID to lock file: %s\n", strerror(errno));
        // Continue anyway
    }

    // Keep the file descriptor open to maintain the lock
    // It will be automatically closed when the process exits
    fchown(lockFD, 501, 501);

    @autoreleasepool {
        NSString *executablePath = [NSString stringWithUTF8String:argv[0]];
        executablePath = [executablePath stringByDeletingLastPathComponent];
        executablePath = [executablePath stringByAppendingPathComponent:@"trollvncserver"];

        gWatchDog = [[TRWatchDog alloc] init];

        [gWatchDog setLabel:@"SuperPhone-Server"];
        [gWatchDog setProgramArguments:@[
            executablePath,
            @"-daemon",
        ]];

        NSMutableDictionary *mEnvs = [[[NSProcessInfo processInfo] environment] mutableCopy];

        [gWatchDog setEnvironmentVariables:mEnvs];
        [gWatchDog setWorkingDirectory:[[NSFileManager defaultManager] currentDirectoryPath]];

        NSString *rootPath = executablePath;
        do {
            if ([rootPath hasSuffix:@"/procursus"] || [rootPath hasSuffix:@"/var/jb"] ||
                [[rootPath lastPathComponent] hasPrefix:@".jbroot-"]) {
                // Found the jailbreak root
                break;
            }
            if ([rootPath hasPrefix:@"/private/preboot/"] && [rootPath hasSuffix:@"/jb"]) {
                // Found the jailbreak root (NathanLR)
                break;
            }
            if ([rootPath isEqualToString:@"/"] || !rootPath.length) {
                // Reached the root without finding jailbreak root
                break;
            }
            rootPath = [rootPath stringByDeletingLastPathComponent];
        } while (YES);

        NSString *stdoutPath = [rootPath stringByAppendingPathComponent:@"tmp/trollvnc-stdout.log"];
        NSString *stderrPath = [rootPath stringByAppendingPathComponent:@"tmp/trollvnc-stderr.log"];

        // 供日志端点（5902）远程读取
        gLogStdoutPath = stdoutPath;
        gLogStderrPath = stderrPath;

        // 2026-08-21 诊断：manager 自身 stderr 并入 server stderr 文件——watchdog 的
        // 子进程退出状态日志（"exited with code"/"terminated by signal"）可经 5902 /stderr
        // 远程读取，用于区分 server 是正常退出（runloop 返回）还是信号终止（崩溃循环根因）。
        freopen([gLogStderrPath UTF8String], "a", stderr);
        setvbuf(stderr, NULL, _IONBF, 0);   // freopen 会重置缓冲，重新设无缓冲

        [gWatchDog setStandardOutputPath:stdoutPath];
        [gWatchDog setStandardErrorPath:stderrPath];

        BOOL isOwnedByRoot = NO;
        struct stat sb;
        if (stat([executablePath fileSystemRepresentation], &sb) == 0) {
            isOwnedByRoot = (sb.st_uid == 0);
        }

        if (isOwnedByRoot) {
            /* If the executable is owned by root, run as root */
            /* The privilege will be dropped by the child process itself */
            [gWatchDog setUserName:@"root"];
            [gWatchDog setGroupName:@"wheel"];
        } else {
            [gWatchDog setUserName:@"mobile"];
            [gWatchDog setGroupName:@"mobile"];
        }

        [gWatchDog setExitTimeOut:3.0];
        // 2026-08-21：默认节流 5s→60s——崩溃循环时 5s 重启一次放大故障（FD 泄漏加速累积、
        // 网关反复探测触发采集空转）；60s 仍能及时拉起，但把高频重启风暴压平。
        [gWatchDog setThrottleInterval:60.0];
        [gWatchDog setKeepAlive:@YES];

        // 2026-08-20：设置页补齐 Watchdog 配置——启动时从 defaults 读取覆盖默认值（与 CONFIG_DEFS 对齐）
        // 双域读取（tvManagerReadPref）：设置页写 mobile 域，root defaults 直读恒空导致从未生效
        NSUserDefaults *wdDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
        NSNumber *exitTimeoutN = tvManagerReadPref(wdDefaults, @"WatchdogExitTimeout");
        if ([exitTimeoutN isKindOfClass:[NSNumber class]]) {
            [gWatchDog setExitTimeOut:exitTimeoutN.doubleValue];
        }
        NSNumber *throttleN = tvManagerReadPref(wdDefaults, @"WatchdogThrottleInterval");
        if ([throttleN isKindOfClass:[NSNumber class]]) {
            [gWatchDog setThrottleInterval:throttleN.doubleValue];
        }

        NSError *argError = nil;
        BOOL validated = [gWatchDog validateConfigurationWithError:&argError];
        if (!validated) {
            fprintf(stderr, "Invalid configuration: %s\n", [[argError localizedDescription] UTF8String]);
            return EXIT_FAILURE;
        }

        // 2026-08-20：启动 watchdog 前清理残留 trollvncserver 孤儿——manager 重启/被杀后旧
        // server 不再受 watchdog 管辖、仍占用 5901/5801/5802 → 新 server bind 失败（画面全挂）。
        // 必须在 [gWatchDog start] 之前执行，避免误杀 watchdog 刚 spawn 的新实例。本进程以
        // root 运行，proc_pidpath 可读任意进程路径（App 沙盒做不到，协调器侧枚举不可靠）。
        killStaleVncServer();

        BOOL started = [gWatchDog start];
        if (!started) {
            fprintf(stderr, "Failed to start watchdog\n");
            return EXIT_FAILURE;
        }
        // Internal farm gateway registration/heartbeat (enabled when GatewayHost/URL is configured)
        [[TRGatewayClient sharedClient] setRestartHandler:^BOOL{
            // restart 命令触发 watchdog 重启 trollvncserver 进程
            return [gWatchDog restart];
        }];
        // 注入 watchdog 实例，供 service.* 能力（signal/state/info/isActive/isThrottled/validate）访问
        [TRGatewayClient sharedClient].watchdog = gWatchDog;
        [[TRGatewayClient sharedClient] start];

        // ===== 实验 A 临时触发（验证后删除）：SimLocationTestInject=1 时注入天安门坐标 =====
        // 目的：验证 root daemon 进程内 CLSimulationManager 注入链路（entitlement locationd.simulation）。
        // 临时开关读 defaults（App/网关可经 configs 通道设置），实验完成后整体移除。
        {
            NSUserDefaults *td = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
            id injectFlag = tvManagerReadPref(td, @"SimLocationTestInject"); // 双域读取：Filza 写 mobile 域 plist 即可触发
            if ([injectFlag boolValue]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    CLLocationCoordinate2D tiananmen = CLLocationCoordinate2DMake(39.9087, 116.3975);
                    [[SimLocationManager sharedManager] injectPoint:tiananmen
                                                           altitude:45.0
                                                           accuracy:5.0
                                                             course:0.0
                                                              speed:0.0];
                    fprintf(stderr, "[manager] SimLocationTestInject: injected (39.9087, 116.3975)\n");
                });
            }
        }
    }

    {
        // handle SIGCHLD signal
        struct sigaction act, oldact;
        act.sa_sigaction = &mSignalAction;
        act.sa_flags = SA_SIGINFO;
        sigaction(SIGCHLD, &act, &oldact);
    }
    {
        // handle SIGHUP signal
        struct sigaction act, oldact;
        act.sa_handler = &mSignalHandler;
        sigaction(SIGHUP, &act, &oldact);
    }
    {
        // handle SIGINT signal
        struct sigaction act, oldact;
        act.sa_handler = &mSignalHandler;
        sigaction(SIGINT, &act, &oldact);
    }
    {
        // handle SIGTERM signal
        struct sigaction act, oldact;
        act.sa_handler = &mSignalHandler;
        sigaction(SIGTERM, &act, &oldact);
    }

    // Open a passive local probe port for clients to detect availability.
    // IPv4 127.0.0.1:46751, no response; accept and close.
    openLocalDummyService(kTvAlivePort);

    // 2026-08-21：远程日志端点（局域网 5902）——trollvncserver 崩溃循环时 5801/5802/5901
    // 均不可用，仅 manager 常驻可提供崩溃日志（stderr/stdout 尾部），供 AI/脚本远程定位根因。
    openLogHttpService();

    // 2026-08-20 双通知自治模型：App（mobile 沙盒）对 root 进程 kill 恒 EPERM，
    // 旧「App 枚举进程发信号」的停止/重启通路从未生效。改为 manager 订阅跨进程通知自治：
    // - prefs-changed（设置页每次写入后必发）：桥接模式自退 + 通知 GatewayClient 重读配置
    // - restart-service（restart 级配置生效）：watchdog 重启 trollvncserver（root 杀 root）
    // 通知名字面量与 trollvncserver.mm / TVNCUtil.h 约定一致（src/ 进程不引 App 头文件）。
    {
        int prefsToken = 0;
        notify_register_dispatch("com.82flex.trollvnc.prefs-changed", &prefsToken,
            dispatch_get_main_queue(), ^(int token) {
                (void)token;
                // 桥接控制模式：本机仅作为控制端，不注册/不开隧道 → 自退
                //（CFRunLoopStop 复用 SIGHUP 同款清理路径：watchdog 停止 → 等子进程退出）
                if (tvManagerIsBridgeMode()) {
                    fprintf(stderr, "[manager] bridge mode detected -> self exit\n");
                    CFRunLoopStop(CFRunLoopGetMain());
                    return;
                }
                // 网关地址/令牌/设备名变更 → 标记重发 register（host 变更由 worker 断开重连）
                [[TRGatewayClient sharedClient] noteExternalPrefsChanged];
                // watchdog 节流/退出超时：TRWatchDog 属性可热调，即时生效
                //（2026-08-20 前为 manager 重启级；双域读取保证 mobile 域设置页写入可见）
                NSUserDefaults *wd = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
                NSNumber *exitN = tvManagerReadPref(wd, @"WatchdogExitTimeout");
                if ([exitN isKindOfClass:[NSNumber class]]) [gWatchDog setExitTimeOut:exitN.doubleValue];
                NSNumber *thrN = tvManagerReadPref(wd, @"WatchdogThrottleInterval");
                if ([thrN isKindOfClass:[NSNumber class]]) [gWatchDog setThrottleInterval:thrN.doubleValue];
            });
    }
    {
        int restartToken = 0;
        notify_register_dispatch("com.82flex.trollvnc.restart-service", &restartToken,
            dispatch_get_main_queue(), ^(int token) {
                (void)token;
                // restart 级配置生效（密码/BindHost/Scale/TileSize/Bonjour 等）：
                // 经 watchdog 重启 trollvncserver——App 沙盒内直接 kill root 恒 EPERM 的唯一可行路径
                if (gWatchDog) {
                    [gWatchDog restart];
                    fprintf(stderr, "[manager] restart-service notified -> watchdog restarting trollvncserver\n");
                }
            });
    }

    // 启动守卫：coordinator 的 spawn 决策（relay）与本订阅建立之间若切到 bridge
    //（该次 notify 已丢），此处二次检查兜底——跳过 runloop 直接走清理路径退出，不留孤儿进程
    if (!tvManagerIsBridgeMode()) {
        CFRunLoopRun();
    } else {
        fprintf(stderr, "[manager] bridge mode at startup -> skip runloop, cleanup\n");
    }
    @autoreleasepool {
        pid_t child = [gWatchDog processIdentifier];
        [gWatchDog stop];
        gWatchDog = nil;

        // Wait for the child process to exit
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
        while (child > 1 && kill(child, 0) == 0 && [deadline timeIntervalSinceNow] > 0) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1e-3, true);
        }
    }

    return EXIT_SUCCESS;
}
