// netdisguise.c — 注入式蜂窝伪装 + 注入痕迹隐藏（POC）
// 纯 C 实现（不注册 ObjC 类），由 insert_dylib 注入目标 app 的 LC_LOAD_DYLIB 加载。
// 职责：
//   1. 蜂窝伪装：SCNetworkReachabilityGetFlags 置 WWAN 位、NWPath usesInterfaceType: 只认 cellular
//   2. 痕迹隐藏：_dyld_image_count/_dyld_get_image_name 过滤自身镜像、SecStaticCodeCheckValidity* 伪签
#include <stdint.h>
#include <string.h>
#include <stdbool.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/objc.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <Security/SecStaticCode.h>
#include <Security/SecCode.h>
#include <mach-o/dyld.h>
#include "fishhook.h"

// ---------- 1. 蜂窝伪装：Reachability（C 函数，fishhook） ----------
static int (*nd_orig_SCNetworkReachabilityGetFlags)(SCNetworkReachabilityRef, SCNetworkReachabilityFlags *);
static int nd_SCNetworkReachabilityGetFlags(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) {
    int ret = nd_orig_SCNetworkReachabilityGetFlags(target, flags);
    if (ret && flags) {
        // 置 WWAN 位：Reachability 判定为蜂窝
        *flags |= kSCNetworkReachabilityFlagsIsWWAN;
    }
    return ret;
}

// ---------- 2. 蜂窝伪装：NWPath usesInterfaceType:（ObjC 方法 swizzle） ----------
// NWInterfaceType 枚举（NWInterfaceTypeOther=1 WiFi=2 Cellular=3 Wired=4 Loopback=5）
static BOOL (*nd_orig_usesInterfaceType)(id, SEL, long);
static BOOL nd_usesInterfaceType(id self, SEL _cmd, long interfaceType) {
    (void)self; (void)_cmd;
    // 只把 Cellular 视为真，其余（wifi/wired/other…）全判假
    return (interfaceType == 3);
}

// ---------- 3. 痕迹隐藏：dyld 镜像枚举过滤自身 ----------
static uint32_t nd_selfIndex = UINT32_MAX;
static const char *(*nd_orig__dyld_get_image_name)(uint32_t idx);
static const char *nd__dyld_get_image_name(uint32_t idx) {
    if (nd_selfIndex != UINT32_MAX && idx >= nd_selfIndex) {
        return nd_orig__dyld_get_image_name(idx + 1);
    }
    return nd_orig__dyld_get_image_name(idx);
}
static uint32_t (*nd_orig__dyld_image_count)(void);
static uint32_t nd__dyld_image_count(void) {
    uint32_t c = nd_orig__dyld_image_count();
    return (nd_selfIndex != UINT32_MAX && c > 0) ? c - 1 : c;
}

// ---------- 4. 痕迹隐藏：签名验证伪签（C 函数，fishhook） ----------
static OSStatus (*nd_orig_SecStaticCodeCheckValidity)(SecStaticCodeRef, SecCSFlags);
static OSStatus nd_SecStaticCodeCheckValidity(SecStaticCodeRef code, SecCSFlags flags) {
    (void)code; (void)flags;
    return errSecSuccess;
}
static OSStatus (*nd_orig_SecStaticCodeCheckValidityWithErrors)(SecStaticCodeRef, SecCSFlags, CFErrorRef *);
static OSStatus nd_SecStaticCodeCheckValidityWithErrors(SecStaticCodeRef code, SecCSFlags flags, CFErrorRef *errors) {
    (void)code; (void)flags;
    if (errors) *errors = NULL;
    return errSecSuccess;
}

__attribute__((constructor))
static void nd_init(void) {
    // 定位自身镜像索引
    Dl_info selfInfo;
    if (dladdr((const void *)&nd_init, &selfInfo) && selfInfo.dli_fname) {
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            const char *name = _dyld_get_image_name(i);
            if (name && strcmp(name, selfInfo.dli_fname) == 0) {
                nd_selfIndex = i;
                break;
            }
        }
    }

    // C 函数 hook
    struct rebinding b[] = {
        {"SCNetworkReachabilityGetFlags", (void *)nd_SCNetworkReachabilityGetFlags, (void **)&nd_orig_SCNetworkReachabilityGetFlags},
        {"_dyld_get_image_name", (void *)nd__dyld_get_image_name, (void **)&nd_orig__dyld_get_image_name},
        {"_dyld_image_count", (void *)nd__dyld_image_count, (void **)&nd_orig__dyld_image_count},
        {"SecStaticCodeCheckValidity", (void *)nd_SecStaticCodeCheckValidity, (void **)&nd_orig_SecStaticCodeCheckValidity},
        {"SecStaticCodeCheckValidityWithErrors", (void *)nd_SecStaticCodeCheckValidityWithErrors, (void **)&nd_orig_SecStaticCodeCheckValidityWithErrors},
    };
    rebind_symbols(b, sizeof(b) / sizeof(b[0]));

    // NWPath 方法 swizzle（Network.framework，iOS 12+）
    Class nwPath = objc_getClass("NWPath");
    if (nwPath) {
        SEL sel = sel_registerName("usesInterfaceType:");
        Method m = class_getInstanceMethod(nwPath, sel);
        if (m) {
            nd_orig_usesInterfaceType = (BOOL (*)(id, SEL, NSInteger))method_setImplementation(m, (IMP)nd_usesInterfaceType);
        }
    }
}
