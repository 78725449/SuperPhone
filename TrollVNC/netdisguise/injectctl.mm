// injectctl.mm — 注入/解除 netdisguise.dylib 到目标 app（POC 版）
// 用法：injectctl inject <bundleId> | injectctl remove <bundleId>
// 依赖同目录二进制：netdisguise.dylib / insert_dylib / ldid
// 流程 inject：killall → 复制 dylib 进 Frameworks → 备份主二进制 → insert_dylib(LC_LOAD_DYLIB)
//             → ldid 提取 entitlements + 重签主二进制与 dylib → 启动 app
// 流程 remove：killall → 恢复备份主二进制 → 删除 dylib → 启动 app
#import <Foundation/Foundation.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <signal.h>
#import <fcntl.h>
#import <stdio.h>
#import <errno.h>

// LSApplicationWorkspace（MobileCoreServices 私有类，动态取类避免头依赖）
@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleIdentifier;
@end

static NSString *gToolDir;

// 执行外部命令；outFile 非空则 stdout/stderr 重定向到该文件，否则经 log 收集
static int ndRun(NSString *path, NSArray<NSString *> *args, NSString *outFile, NSMutableString *log) {
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
    int rc = posix_spawn(&pid, cargv[0], &fa, NULL, cargv, NULL);
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

    // 2. 准备 Frameworks 目录并复制 dylib
    NSString *fwDir = [appDir stringByAppendingPathComponent:@"Frameworks"];
    NSError *mkErr = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:fwDir
                              withIntermediateDirectories:YES attributes:nil error:&mkErr];
    if (mkErr) [log appendFormat:@"mkdir Frameworks failed: %@\n", mkErr];
    NSString *dylibSrc = [gToolDir stringByAppendingPathComponent:@"netdisguise.dylib"];
    NSString *dylibDst = [fwDir stringByAppendingPathComponent:@"netdisguise.dylib"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dylibSrc]) {
        [log appendFormat:@"dylib missing: %@\n", dylibSrc];
        return -3;
    }
    [[NSFileManager defaultManager] removeItemAtPath:dylibDst error:NULL];
    NSError *cpErr = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:dylibSrc toPath:dylibDst error:&cpErr]) {
        [log appendFormat:@"copy dylib failed: %@ (src=%@ dst=%@)\n", cpErr ?: @"unknown", dylibSrc, dylibDst];
        return -3;
    }

    // 3. 备份主二进制（仅首次）
    NSString *bak = [exe stringByAppendingString:@".nd.bak"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:bak]) {
        [[NSFileManager defaultManager] copyItemAtPath:exe toPath:bak error:NULL];
    }

    // 4. insert_dylib：注入 LC_LOAD_DYLIB（弱引用，降低检测面）
    NSString *insertTool = [gToolDir stringByAppendingPathComponent:@"insert_dylib"];
    int rc = ndRun(insertTool, @[@"--inplace", @"--all-yes", @"--weak",
                                 @"@executable_path/Frameworks/netdisguise.dylib", exe], nil, log);
    if (rc != 0) {
        [log appendFormat:@"insert_dylib failed\n"];
        return -4;
    }

    // 5. ldid：提取 entitlements 并重签主二进制 + dylib
    NSString *ldidTool = [gToolDir stringByAppendingPathComponent:@"ldid"];
    NSString *entPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nd_ent.plist"];
    if (ndRun(ldidTool, @[@"-e", exe], entPath, log) != 0) {
        [log appendFormat:@"extract entitlements failed\n"];
        return -5;
    }
    if (ndRun(ldidTool, @[[NSString stringWithFormat:@"-S%@", entPath], exe], nil, log) != 0) {
        [log appendFormat:@"resign main binary failed\n"];
        return -5;
    }
    if (ndRun(ldidTool, @[[NSString stringWithFormat:@"-S%@", entPath], dylibDst], nil, log) != 0) {
        [log appendFormat:@"resign dylib failed\n"];
        return -5;
    }

    // 6. 启动
    id ws = [NSClassFromString(@"LSApplicationWorkspace") performSelector:NSSelectorFromString(@"defaultWorkspace")];
    if (ws && [ws respondsToSelector:NSSelectorFromString(@"openApplicationWithBundleID:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [ws performSelector:NSSelectorFromString(@"openApplicationWithBundleID:") withObject:bundleId];
#pragma clang diagnostic pop
    }
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

    // 恢复备份
    NSString *bak = [exe stringByAppendingString:@".nd.bak"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:bak]) {
        [[NSFileManager defaultManager] removeItemAtPath:exe error:NULL];
        if (![[NSFileManager defaultManager] moveItemAtPath:bak toPath:exe error:NULL]) {
            [log appendFormat:@"restore backup failed\n"];
            return -6;
        }
    }
    // 删除 dylib
    NSString *dylibDst = [appDir stringByAppendingPathComponent:@"Frameworks/netdisguise.dylib"];
    [[NSFileManager defaultManager] removeItemAtPath:dylibDst error:NULL];

    id ws = [NSClassFromString(@"LSApplicationWorkspace") performSelector:NSSelectorFromString(@"defaultWorkspace")];
    if (ws && [ws respondsToSelector:NSSelectorFromString(@"openApplicationWithBundleID:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [ws performSelector:NSSelectorFromString(@"openApplicationWithBundleID:") withObject:bundleId];
#pragma clang diagnostic pop
    }
    [log appendFormat:@"remove ok: %@\n", bundleId];
    return 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: injectctl <inject|remove> <bundleId>\n");
            return 1;
        }
        NSString *action = [NSString stringWithUTF8String:argv[1]];
        NSString *bundleId = [NSString stringWithUTF8String:argv[2]];
        gToolDir = [[NSString stringWithUTF8String:argv[0]] stringByDeletingLastPathComponent];

        NSMutableString *log = [NSMutableString string];
        int rc;
        if ([action isEqualToString:@"inject"]) {
            rc = ndInject(bundleId, log);
        } else if ([action isEqualToString:@"remove"]) {
            rc = ndRemove(bundleId, log);
        } else {
            fprintf(stderr, "unknown action: %s\n", argv[1]);
            return 1;
        }
        fprintf(stdout, "%s", log.UTF8String);
        return rc;
    }
}
