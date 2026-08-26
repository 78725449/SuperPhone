// injectctl.mm — 注入/解除 netdisguise.dylib 到目标 app（POC 版）
// 用法：injectctl inject <bundleId> | injectctl remove <bundleId> | injectctl diag <bundleId>
// 依赖同目录二进制：netdisguise.dylib / insert_dylib / ldid
// 权限模型：目标 app bundle 归 _mobile(33) 且 755，mobile(501) 无写权限——文件操作经
//          persona 机制（com.apple.private.persona-mgmt）posix_spawn 自身 __root 模式以 uid0 执行
// 流程 inject：kill → root(mkdir Frameworks / copy dylib / 备份主二进制 / insert_dylib / ldid 重签 / chown 33:33) → 启动
// 流程 remove：kill → root(恢复备份主二进制 / 删除 dylib) → 启动
#import <Foundation/Foundation.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <signal.h>
#import <fcntl.h>
#import <stdio.h>
#import <errno.h>

// persona 私有 API（libsystem 导出；对齐 TrollFools rootSpawn 机制）
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, int, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, gid_t);
#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 2
#endif

// LSApplicationWorkspace（MobileCoreServices 私有类，动态取类避免头依赖）
@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleIdentifier;
@end

static NSString *gToolDir;
static NSString *gSelfPath;

// 基础 spawn（支持 persona attr + stdout 重定向到 outFile）；outFile 传 nil 时收集进 log
static int ndSpawnWithAttr(NSString *path, NSArray<NSString *> *args, posix_spawnattr_t *attr,
                           NSString *outFile, NSMutableString *log) {
    if (log) [log appendFormat:@"$ %@ %@\n", path, [args componentsJoinedByString:@" "]];
    char **cargv = (char **)calloc(args.count + 2, sizeof(char *));
    cargv[0] = (char *)path.UTF8String;
    for (NSUInteger i = 0; i < args.count; i++) cargv[i + 1] = (char *)args[i].UTF8String;
    cargv[args.count + 1] = NULL;

    int fds[2] = {-1, -1};
    int outFd = -1;
    if (outFile) {
        outFd = open(outFile.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    } else {
        pipe(fds);
    }
    pid_t pid;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    int target = outFile ? outFd : fds[1];
    posix_spawn_file_actions_adddup2(&fa, target, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, target, STDERR_FILENO);
    if (!outFile) posix_spawn_file_actions_addclose(&fa, fds[0]);
    int rc = posix_spawn(&pid, cargv[0], &fa, attr, cargv, NULL);
    if (target != -1) close(target);
    if (rc != 0) {
        if (log) [log appendFormat:@"spawn failed: %s\n", strerror(errno)];
        free(cargv);
        return rc;
    }
    if (!outFile) {
        char buf[2048];
        ssize_t n;
        while ((n = read(fds[0], buf, sizeof(buf))) > 0) {
            if (log) [log appendFormat:@"%.*s", (int)n, buf];
        }
        close(fds[0]);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    free(cargv);
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    if (log) [log appendFormat:@"=> exit %d\n", code];
    return code;
}

// 501 身份 spawn
static int ndRun(NSString *path, NSArray<NSString *> *args, NSString *outFile, NSMutableString *log) {
    return ndSpawnWithAttr(path, args, NULL, outFile, log);
}

// persona 切 uid0 spawn
static int ndRootSpawn(NSString *path, NSArray<NSString *> *args, NSString *outFile, NSMutableString *log) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE, 0);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    int rc = ndSpawnWithAttr(path, args, &attr, outFile, log);
    posix_spawnattr_destroy(&attr);
    return rc;
}

// 以 root 身份执行本工具 __root 模式（文件操作）
static int ndRootRun(NSArray<NSString *> *rootArgs, NSString *outFile, NSMutableString *log) {
    NSMutableArray *full = [NSMutableArray arrayWithObject:@"__root"];
    [full addObjectsFromArray:rootArgs];
    return ndRootSpawn(gSelfPath, full, outFile, log);
}

// 扫描容器目录定位 app bundle（bundleId 匹配）
static NSString *ndFindAppDir(NSString *bundleId) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in @[@"/var/containers/Bundle/Application",
                             @"/private/var/containers/Bundle/Application"]) {
        NSArray *subs = [fm contentsOfDirectoryAtPath:root error:NULL];
        for (NSString *sub in subs) {
            NSString *dir = [root stringByAppendingPathComponent:sub];
            NSArray *apps = [fm contentsOfDirectoryAtPath:dir error:NULL];
            for (NSString *app in apps) {
                if (![app hasSuffix:@".app"]) continue;
                NSString *appDir = [dir stringByAppendingPathComponent:app];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                      [appDir stringByAppendingPathComponent:@"Info.plist"]];
                if ([info[@"CFBundleIdentifier"] isEqualToString:bundleId]) {
                    return appDir;
                }
            }
        }
    }
    return nil;
}

// 终止目标 app：sysctl 枚举进程 + kill（iOS /usr/bin 无 killall，不依赖外部二进制）
static void ndKillApp(NSString *procName) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) return;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return;
    if (sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
        size_t count = size / sizeof(struct kinfo_proc);
        for (size_t i = 0; i < count; i++) {
            char *comm = procs[i].kp_proc.p_comm;
            if (comm && strcmp(comm, procName.UTF8String) == 0) {
                kill(procs[i].kp_proc.p_pid, SIGKILL);
            }
        }
    }
    free(procs);
}

static void ndLaunchApp(NSString *bundleId) {
    id ws = [NSClassFromString(@"LSApplicationWorkspace") performSelector:NSSelectorFromString(@"defaultWorkspace")];
    if (ws && [ws respondsToSelector:NSSelectorFromString(@"openApplicationWithBundleID:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [ws performSelector:NSSelectorFromString(@"openApplicationWithBundleID:") withObject:bundleId];
#pragma clang diagnostic pop
    }
}

static int ndInject(NSString *bundleId, NSMutableString *log) {
    NSString *appDir = ndFindAppDir(bundleId);
    if (!appDir) {
        [log appendFormat:@"app not found: %@\n", bundleId];
        return -2;
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [appDir stringByAppendingPathComponent:@"Info.plist"]];
    NSString *exeName = info[@"CFBundleExecutable"];
    NSString *exe = [appDir stringByAppendingPathComponent:exeName];
    if (!exeName) return -2;

    // 1. 终止目标 app
    ndKillApp(exeName);

    // 2. 准备 Frameworks 目录并复制 dylib（root）
    NSString *fwDir = [appDir stringByAppendingPathComponent:@"Frameworks"];
    NSString *dylibSrc = [gToolDir stringByAppendingPathComponent:@"netdisguise.dylib"];
    NSString *dylibDst = [fwDir stringByAppendingPathComponent:@"netdisguise.dylib"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dylibSrc]) {
        [log appendFormat:@"dylib missing: %@\n", dylibSrc];
        return -3;
    }
    ndRootRun(@[@"mkdir", fwDir], nil, log);
    if (ndRootRun(@[@"copy", dylibSrc, dylibDst], nil, log) != 0) {
        [log appendFormat:@"copy dylib failed\n"];
        return -3;
    }

    // 3. 备份主二进制（仅首次，root）
    NSString *bak = [exe stringByAppendingString:@".nd.bak"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:bak]) {
        ndRootRun(@[@"copy", exe, bak], nil, log);
    }

    // 4. insert_dylib：注入 LC_LOAD_DYLIB（弱引用，root）
    NSString *insertTool = [gToolDir stringByAppendingPathComponent:@"insert_dylib"];
    if (ndRootRun(@[@"run", @"-", insertTool, @"--inplace", @"--all-yes", @"--weak",
                    @"@executable_path/Frameworks/netdisguise.dylib", exe], nil, log) != 0) {
        [log appendFormat:@"insert_dylib failed\n"];
        return -4;
    }

    // 5. ldid：提取 entitlements（501 可读）并重签主二进制 + dylib（root 写）
    NSString *ldidTool = [gToolDir stringByAppendingPathComponent:@"ldid"];
    NSString *entPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nd_ent.plist"];
    if (ndRun(ldidTool, @[@"-e", exe], entPath, log) != 0) {
        [log appendFormat:@"extract entitlements failed\n"];
        return -5;
    }
    if (ndRootRun(@[@"run", @"-", ldidTool, [NSString stringWithFormat:@"-S%@", entPath], exe], nil, log) != 0) {
        [log appendFormat:@"resign main binary failed\n"];
        return -5;
    }
    if (ndRootRun(@[@"run", @"-", ldidTool, [NSString stringWithFormat:@"-S%@", entPath], dylibDst], nil, log) != 0) {
        [log appendFormat:@"resign dylib failed\n"];
        return -5;
    }
    // 6. 注入文件 chown 回 installd(33:33)
    ndRootRun(@[@"chown", dylibDst], nil, log);
    ndRootRun(@[@"chown", exe], nil, log);

    // 7. 启动
    ndLaunchApp(bundleId);
    [log appendFormat:@"inject ok: %@\n", bundleId];
    return 0;
}

static int ndRemove(NSString *bundleId, NSMutableString *log) {
    NSString *appDir = ndFindAppDir(bundleId);
    if (!appDir) {
        [log appendFormat:@"app not found: %@\n", bundleId];
        return -2;
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [appDir stringByAppendingPathComponent:@"Info.plist"]];
    NSString *exeName = info[@"CFBundleExecutable"];
    NSString *exe = [appDir stringByAppendingPathComponent:exeName];

    ndKillApp(exeName);

    // 恢复备份（root）+ 删除 dylib（root）
    NSString *bak = [exe stringByAppendingString:@".nd.bak"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:bak]) {
        if (ndRootRun(@[@"move", bak, exe], nil, log) != 0) {
            [log appendFormat:@"restore backup failed\n"];
            return -6;
        }
    }
    NSString *dylibDst = [appDir stringByAppendingPathComponent:@"Frameworks/netdisguise.dylib"];
    ndRootRun(@[@"rm", dylibDst], nil, log);

    ndLaunchApp(bundleId);
    [log appendFormat:@"remove ok: %@\n", bundleId];
    return 0;
}

static int ndDiag(NSString *bundleId, NSMutableString *log) {
    [log appendFormat:@"euid=%d uid=%d\n", geteuid(), getuid()];
    // 对照：写 mobile 可写区（判断是否沙箱受限）
    NSString *ctlPath = @"/var/mobile/Library/Preferences/__nd_test";
    NSError *cerr = nil;
    BOOL cw = [@"" writeToFile:ctlPath atomically:YES encoding:NSUTF8StringEncoding error:&cerr];
    if (cw) {
        [log appendFormat:@"controlWrite(YES) /var/mobile 可写\n"];
        [[NSFileManager defaultManager] removeItemAtPath:ctlPath error:NULL];
    } else {
        [log appendFormat:@"controlWrite(NO) err=%@\n", cerr ?: @"?"];
    }
    NSString *appDir = ndFindAppDir(bundleId);
    [log appendFormat:@"appDir=%@\n", appDir ?: @"(not found)"];
    if (appDir) {
        struct stat st;
        if (stat(appDir.UTF8String, &st) == 0) {
            [log appendFormat:@"appBundle owner=%d mode=%o\n", st.st_uid, st.st_mode & 07777];
        }
        // persona root 写测试
        NSString *test = [appDir stringByAppendingPathComponent:@"__nd_test"];
        if (ndRootRun(@[@"copy", ctlPath, test], nil, log) == 0) {
            [log appendFormat:@"rootWriteTest=YES (persona root 可写 app bundle)\n"];
            ndRootRun(@[@"rm", test], nil, log);
        } else {
            [log appendFormat:@"rootWriteTest=NO\n"];
        }
    }
    return 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        gSelfPath = [NSString stringWithUTF8String:argv[0]];
        gToolDir = [gSelfPath stringByDeletingLastPathComponent];

        // __root 模式：persona uid0 下执行文件操作（子进程，直接系统调用）
        if (argc >= 3 && strcmp(argv[1], "__root") == 0) {
            NSString *op = [NSString stringWithUTF8String:argv[2]];
            NSMutableString *log = [NSMutableString string];
            int rc = 0;
            if ([op isEqualToString:@"copy"]) {
                // __root copy <src> <dst>
                NSString *src = [NSString stringWithUTF8String:argv[3]];
                NSString *dst = [NSString stringWithUTF8String:argv[4]];
                [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
                if (![[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:NULL]) rc = -3;
                chown(dst.UTF8String, 33, 33);
            } else if ([op isEqualToString:@"mkdir"]) {
                NSString *p = [NSString stringWithUTF8String:argv[3]];
                if (![[NSFileManager defaultManager] createDirectoryAtPath:p
                                              withIntermediateDirectories:YES attributes:nil error:NULL]) rc = -7;
            } else if ([op isEqualToString:@"chown"]) {
                if (chown([NSString stringWithUTF8String:argv[3]].UTF8String, 33, 33) != 0) rc = -8;
            } else if ([op isEqualToString:@"move"]) {
                // __root move <src> <dst>
                NSString *src = [NSString stringWithUTF8String:argv[3]];
                NSString *dst = [NSString stringWithUTF8String:argv[4]];
                [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
                if (![[NSFileManager defaultManager] moveItemAtPath:src toPath:dst error:NULL]) rc = -6;
                chown(dst.UTF8String, 33, 33);
            } else if ([op isEqualToString:@"rm"]) {
                NSString *p = [NSString stringWithUTF8String:argv[3]];
                [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
            } else if ([op isEqualToString:@"run"]) {
                // __root run <outFile|- > <binary> <args...>（子进程继承 root）
                NSString *outFile = [NSString stringWithUTF8String:argv[3]];
                if ([outFile isEqualToString:@"-"]) outFile = nil;
                NSString *bin = [NSString stringWithUTF8String:argv[4]];
                NSMutableArray *a = [NSMutableArray array];
                for (int i = 5; i < argc; i++) [a addObject:[NSString stringWithUTF8String:argv[i]]];
                rc = ndSpawnWithAttr(bin, a, NULL, outFile, log);
            } else {
                rc = -9;
            }
            fprintf(stdout, "%s", log.UTF8String);
            return rc;
        }

        if (argc < 3) {
            fprintf(stderr, "usage: injectctl <inject|remove|diag> <bundleId>\n");
            return 1;
        }
        NSString *action = [NSString stringWithUTF8String:argv[1]];
        NSString *bundleId = [NSString stringWithUTF8String:argv[2]];

        NSMutableString *log = [NSMutableString string];
        int rc;
        if ([action isEqualToString:@"inject"]) {
            rc = ndInject(bundleId, log);
        } else if ([action isEqualToString:@"remove"]) {
            rc = ndRemove(bundleId, log);
        } else if ([action isEqualToString:@"diag"]) {
            rc = ndDiag(bundleId, log);
        } else {
            fprintf(stderr, "unknown action: %s\n", argv[1]);
            return 1;
        }
        fprintf(stdout, "%s", log.UTF8String);
        return rc;
    }
}
