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

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <notify.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>

#import "StripedTextTableViewController.h"
#import "TVNCGatewayClient.h"
#import "TVNCRootListController.h"
// 仅 App（bootstrap tipa）：prefs bundle（越狱设置页）无 spawn root 能力，不编 Coordinator
//（2026-08-20 编译分叉修复：symlink 共享源码后 prefs 侧曾因 import 链断链编译失败）
#ifdef THEBOOTSTRAP
#import "BRPickerView/BRTextPickerView.h" // 清理残留（identity.reset）目标应用选择器（仅 App 编译）
#import "TVNCServiceCoordinator.h"
// 2026-08-21 连接网关/桥接网关按钮文字动态化（设计文档 7.4）：TVNCAppStore 为 App 进程单例，
// prefs bundle（Preferences.app 进程）不编译 TVNCAppStore（见 prefs Makefile），须条件编译隔离
#import "TVNCAppStore.h"
#endif
#import "TVNCUtil.h"
#import "TVNCButtonCell.h"
#import "ZTSelfSignedCertificate.h"
// kTRAppPrefsSuiteName（跨端 prefs 域契约，2026-08-28）。双路径 __has_include（对齐 TVNCUtil.h）：
#if __has_include("../../../src/TRAppDomain.h")
#import "../../../src/TRAppDomain.h"
#else
#import "TRAppDomain.h"
#endif

// PSSpecifier 的 name/setName: 为私有属性，bootstrap 方案（xcodebuild + iPhoneOS16.5.sdk）头未声明，
// 本地补声明使折叠组头标题重建可见（运行时真实存在，2026-08-19）
@interface PSSpecifier (TVNCCollapseAccessors)
- (NSString *)name;
- (void)setName:(NSString *)name;
@end

NS_INLINE BOOL TVNCIsValidBindHostLiteral(NSString *host) {
    if (!host)
        return YES;

    NSString *trimmed = [host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0)
        return YES; // Empty means bind any interface

    const char *cstr = trimmed.UTF8String;
    if (!cstr || cstr[0] == '\0')
        return YES;

    struct in_addr v4;
    if (inet_pton(AF_INET, cstr, &v4) == 1)
        return YES;

    // Allow optional IPv6 scope suffix (e.g. fe80::1%en0)
    char addrBuf[INET6_ADDRSTRLEN + 1] = {0};
    const char *pct = strchr(cstr, '%');
    size_t copyLen = pct ? (size_t)(pct - cstr) : strlen(cstr);
    if (copyLen >= sizeof(addrBuf))
        copyLen = sizeof(addrBuf) - 1;
    memcpy(addrBuf, cstr, copyLen);
    addrBuf[copyLen] = '\0';

    struct in6_addr v6;
    return inet_pton(AF_INET6, addrBuf, &v6) == 1;
}

@interface TVNCRootListController () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>

@property(nonatomic, strong) UINotificationFeedbackGenerator *notificationGenerator;
@property(nonatomic, strong) UIColor *primaryColor;
@property(nonatomic, copy) NSString *jbrootPath;

@property(nonatomic, strong) PSSpecifier *certSpecifier;
@property(nonatomic, strong) PSSpecifier *keysSpecifier;
@property(nonatomic, strong) PSSpecifier *exportCertSpecifier;
@property(nonatomic, strong) PSSpecifier *frameRateSpecSpecifier; // 2026-08-20：帧率=自定义时联动 FrameRateSpecCustom 输入框显隐
@property(nonatomic, strong) NSNetServiceBrowser *gatewayBrowser;
@property(nonatomic, strong) NSMutableArray<NSNetService *> *gatewayServices;
@property(nonatomic, assign) BOOL gatewaySearchShown;

// 设置页折叠组（2026-08-19）：_allSpecifiers 完整列表 / _collapsedGroups 已折叠组（默认全折叠）
@property(nonatomic, strong) NSArray<PSSpecifier *> *allSpecifiers;
@property(nonatomic, strong) NSMutableSet<NSString *> *collapsedGroups;


@end

@implementation TVNCRootListController

#ifdef THEBOOTSTRAP
@synthesize bundle = _bundle;

- (NSBundle *)bundle {
    if (!_bundle) {
        _bundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"TrollVNCPrefs" ofType:@"bundle"]];
    }
    return _bundle;
}
#endif

/* clangd behavior workarounds */
#define STRINGIFY(x) #x
#define EXPAND_AND_STRINGIFY(x) STRINGIFY(x)
#define MYNSSTRINGIFY(x)                                                                                               \
    ^{                                                                                                                 \
        NSString *str = [NSString stringWithUTF8String:EXPAND_AND_STRINGIFY(x)];                                       \
        if ([str hasPrefix:@"\""])                                                                                     \
            str = [str substringFromIndex:1];                                                                          \
        if ([str hasSuffix:@"\""])                                                                                     \
            str = [str substringToIndex:str.length - 1];                                                               \
        return str;                                                                                                    \
    }()

- (BOOL)hasManagedConfiguration {
    static BOOL sIsManaged = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *presetPath = [self.bundle pathForResource:@"Managed" ofType:@"plist"];
        if (presetPath) {
            NSDictionary *presetDict = [NSDictionary dictionaryWithContentsOfFile:presetPath];
            if (presetDict) {
                sIsManaged = YES;
            }
        }
    });
    return sIsManaged;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray<PSSpecifier *> *specifiers = nil;

        if (!specifiers) {
            if ([self hasManagedConfiguration]) {
                specifiers = [self loadSpecifiersFromPlistName:@"ManagedRoot" target:self];
            }
        }

        if (!specifiers) {
            specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        }

        for (PSSpecifier *specifier in specifiers) {
            NSString *actionName = [specifier propertyForKey:@"action"];
            if ([actionName isEqualToString:@"exportCertificate"]) {
                _exportCertSpecifier = specifier;
                break;
            }

            NSString *keyName = [specifier propertyForKey:@"key"];
            if ([keyName isEqualToString:@"SslCertFile"]) {
                _certSpecifier = specifier;
            } else if ([keyName isEqualToString:@"SslKeyFile"]) {
                _keysSpecifier = specifier;
            } else if ([keyName isEqualToString:@"FrameRateSpec"]) {
                _frameRateSpecSpecifier = specifier;
            }
        }

        if (![self hasManagedConfiguration]) {
            // 2026-08-19 折叠组：保存完整列表，显示列表由 _visibleSpecifiers 过滤
            _allSpecifiers = specifiers;
            if (!_collapsedGroups) {
                // 2026-08-21 板块整改：折叠组仅剩画面分组「进阶」（performance）；
                // 原「高级」折叠组（advanced）已拆散到直连/画面/交互/保活/关于各分组
                _collapsedGroups = [NSMutableSet setWithObject:@"performance"];
            }
            _specifiers = [self _visibleSpecifiersFrom:specifiers];
        } else {
            _specifiers = specifiers;
        }
    }

    return _specifiers;
}

/**
 * 由完整 specifiers 计算显示列表（2026-08-19 折叠组 + 动态显隐）：
 * - 折叠组（collapseGroup）子项：组在 collapsedGroups 中则隐藏；组头按钮（cell=PSButtonCell
 *   且带 collapseGroup）保留，标题带 ▸/▾ 指示状态
 * - visibleOnlyCustom：仅 PerformanceMode=custom 时显示（4 项底层传输参数）
 * - visibleOnlyRelay（2026-08-20）：仅 ConnectionMode=relay（网关中继）时显示（自动发现仅被控端有意义）
 * - visibleOnlyAccessFull / visibleOnlyAccessReadonly（2026-08-20）：按访问模式显示对应密码
 * @returns {NSMutableArray} 过滤后的显示列表（可变，供 _specifiers 直接持有）
 */
- (NSMutableArray<PSSpecifier *> *)_visibleSpecifiersFrom:(NSArray<PSSpecifier *> *)all {
    // 2026-08-20：设置写入域为 com.82flex.trollvnc（PSSpecifier defaults），
    // 必须用同一 suite 读取——standardUserDefaults 对应 App bundle（com.82flex.TrollVNCApp）读不到，
    // 导致 ConnectionMode/AccessMode/PerformanceMode 显隐判断恒为默认值（模式切换菜单不变化）。
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    NSString *pm = [ud stringForKey:@"PerformanceMode"] ?: @"balanced";
    NSString *connMode = [ud stringForKey:@"ConnectionMode"] ?: @"relay";
    NSString *accessMode = [ud stringForKey:@"AccessMode"] ?: @"full";
    NSString *fps = [ud stringForKey:@"FrameRateSpec"] ?: @"60";
    BOOL customPM = [pm isEqualToString:@"custom"];
    BOOL customFRS = [fps isEqualToString:@"custom"];
    BOOL relay = [connMode isEqualToString:@"relay"];
    BOOL bridge = [connMode isEqualToString:@"bridge"];
    BOOL accessFull = [accessMode isEqualToString:@"full"];
    BOOL accessReadonly = [accessMode isEqualToString:@"readonly"];

    NSMutableArray *visible = [NSMutableArray arrayWithCapacity:all.count];
    for (PSSpecifier *sp in all) {
        NSString *cg = [sp propertyForKey:@"collapseGroup"];
        // 2026-08-20：折叠组头识别需同时兼容 cell=PSButtonCell 与 cellClass=TVNCButtonCell
        // （「重新生成证书」已改 cellClass=TVNCButtonCell，无 cell 键，否则被误判为折叠子项而隐藏）。
        // 修复闪退（2026-08-20 根因）：PSSpecifier 的 cellClass 键会被 PSListController 解析为
        // Class 对象（NSClassFromString 后 setProperty:forKey:），不能直接 isEqualToString: 比较——
        // 对 Class 对象调用 isEqualToString: 是 unrecognized selector → 进入设置页即闪退。
        // 类型安全判断：NSString 走字符串比较，Class 对象走指针比较。
        BOOL isTVNCButton = NO;
        id cc = [sp propertyForKey:@"cellClass"];
        if ([cc isKindOfClass:[NSString class]]) {
            isTVNCButton = [(NSString *)cc isEqualToString:@"TVNCButtonCell"];
        } else if (cc) {
            isTVNCButton = ((Class)cc == NSClassFromString(@"TVNCButtonCell"));
        }
        BOOL isCollapseHeader = (cg != nil &&
                                 ([[sp propertyForKey:@"cell"] isEqualToString:@"PSButtonCell"] || isTVNCButton));
        // 折叠组的子项：组被折叠则隐藏
        if (cg != nil && !isCollapseHeader && [_collapsedGroups containsObject:cg]) continue;
        // 底层传输参数：仅 custom 模式显示
        if ([sp propertyForKey:@"visibleOnlyCustom"] && !customPM) continue;
        // 自定义帧率输入：仅帧率=自定义显示
        if ([sp propertyForKey:@"visibleOnlyFrameRateCustom"] && !customFRS) continue;
        // 自动发现：仅网关中继（relay）模式显示——桥接控制不注册，无发现意义
        if ([sp propertyForKey:@"visibleOnlyRelay"] && !relay) continue;
        // 连接网关按钮：仅桥接控制（bridge）模式显示——纯控制端连网关入口
        if ([sp propertyForKey:@"visibleOnlyBridge"] && !bridge) continue;
        // 访问密码：仅完全访问模式显示；只读密码：仅只读模式显示
        if ([sp propertyForKey:@"visibleOnlyAccessFull"] && !accessFull) continue;
        if ([sp propertyForKey:@"visibleOnlyAccessReadonly"] && !accessReadonly) continue;
        // 折叠组头：标题附展开/收起指示（以 label 为基准重建，避免箭头叠加）
        if (isCollapseHeader) {
            NSString *marker = [_collapsedGroups containsObject:cg] ? @"▸" : @"▾";
            NSString *label = [sp propertyForKey:@"label"] ?: [sp name];
            [sp setName:[NSString stringWithFormat:@"%@  %@", label, marker]];
        }
        [visible addObject:sp];
    }
    return visible;
}

/**
 * 折叠组头点击（2026-08-19）：切换组展开/收起并刷新列表。
 * @param {PSSpecifier} spec 组头按钮 specifier（plist 中带 collapseGroup 属性）
 */
- (void)toggleCollapseGroup:(PSSpecifier *)spec {
    NSString *cg = [spec propertyForKey:@"collapseGroup"];
    if (!cg) return;
    if ([_collapsedGroups containsObject:cg]) {
        [_collapsedGroups removeObject:cg];
    } else {
        [_collapsedGroups addObject:cg];
    }
    _specifiers = [self _visibleSpecifiersFrom:_allSpecifiers];
    [self reloadSpecifiers];
}

/**
 * 配置值写入拦截（2026-08-19 动态显隐联动；2026-08-20 热重载通道 + 自动重启 + manager 自治）：
 * - PerformanceMode 变更 → 刷新（custom 才显示 4 项底层参数）+ 预设写底层参数 → 自动重启（预设含 restart 级）
 * - FrameRateSpec 变更 → 刷新（帧率五档：15/30/60/动态/自定义，动态=15-60 范围自适应；自定义=显示输入框）+ 热重载
 * - Notifications 变更（2026-08-20）→ 同步写底层 SingleNotifEnabled/ClientNotifsEnabled
 *   （与 TRCapabilityRegistry setConfig 对称，保证 currentConfigs 反推一致）+ 热重载即时生效
 * - 所有写入后 notify_post(TVNC_NOTIFY_PREFS_CHANGED)，双接收方跨进程自治：
 *   trollvncserver 热重载 hot/instant 配置；trollvncmanager 处理桥接自退/网关配置重连/watchdog 参数热调
 * - restart 级 key（密码/BindHost/TileSize/MaxRects/AsyncSwap/BonjourEnabled/PerformanceMode 预设）
 *   → 防抖自动重启（restart-service 通知 → manager watchdog 重启 server）
 */
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    [super setPreferenceValue:value specifier:spec];
    if ([self hasManagedConfiguration]) return; // 托管页无折叠/联动/重启确认，避免 _allSpecifiers 为空清空列表
    NSString *key = [spec propertyForKey:@"key"];
    if ([key isEqualToString:@"PerformanceMode"] || [key isEqualToString:@"FrameRateSpec"] ||
        [key isEqualToString:@"ConnectionMode"] || [key isEqualToString:@"AccessMode"]) {
        if ([key isEqualToString:@"PerformanceMode"]) {
            // 2026-08-20：设置页改画质模式需与 TRCapabilityRegistry setConfig 对称——按预设写底层参数，
            // 否则只写 PerformanceMode 枚举、TileSize 等不变，画质模式实际不生效（trollvncserver 不读枚举）。
            NSString *mode = [value isKindOfClass:[NSString class]] ? value : @"balanced";
            NSDictionary *presets = @{
                @"balanced":   @{@"TileSize": @32, @"MaxRects": @512, @"FullscreenThresholdPercent": @50, @"AsyncSwap": @NO},
                @"quality":     @{@"TileSize": @64, @"MaxRects": @2048, @"FullscreenThresholdPercent": @80, @"AsyncSwap": @NO},
                @"performance": @{@"TileSize": @16, @"MaxRects": @128, @"FullscreenThresholdPercent": @30, @"AsyncSwap": @YES},
                @"custom":      @{}
            };
            NSDictionary *preset = presets[mode];
            if (preset) {
                NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
                for (NSString *k in preset) {
                    [defs setObject:preset[k] forKey:k];
                }
                [defs synchronize];
            }
        }
        _specifiers = [self _visibleSpecifiersFrom:_allSpecifiers];
        [self reloadSpecifiers];
    } else if ([key isEqualToString:@"Notifications"]) {
        // 通知模式枚举 → 映射底层开关（trollvncserver 启动/热重载时读底层开关生效）
        NSString *mode = [value isKindOfClass:[NSString class]] ? value : @"all";
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
        if ([mode isEqualToString:@"connectOnly"]) {
            [defaults setObject:@NO forKey:@"SingleNotifEnabled"];
            [defaults setObject:@YES forKey:@"ClientNotifsEnabled"];
        } else if ([mode isEqualToString:@"silent"]) {
            [defaults setObject:@NO forKey:@"SingleNotifEnabled"];
            [defaults setObject:@NO forKey:@"ClientNotifsEnabled"];
        } else { // all
            [defaults setObject:@YES forKey:@"SingleNotifEnabled"];
            [defaults setObject:@YES forKey:@"ClientNotifsEnabled"];
        }
        [defaults synchronize];
        // 2026-08-20 起即时生效（热重载通道），不再重启
    }
    if (key && [[self _restartRequiredKeys] containsObject:key]) {
        [self _scheduleAutoRestart];
    }
    // 2026-08-20 设置页通知通道（双接收方，均跨进程自治）：
    // - trollvncserver：热重载 hot/instant 配置（帧率/通知等即时生效）
    // - trollvncmanager：桥接模式自退；网关地址/令牌变更重读配置并重连（原 manager 重启级
    //   配置 GatewayHost/Token/Watchdog* 即时生效，无需 kill 重启——沙盒内 kill root 恒 EPERM）
    // restart 级配置由上方 _scheduleAutoRestart（restart-service 通知）重启生效。
    // 2026-08-21 竞态修复：manager 的双域读取兜底走 plist 文件（tvManagerReadPref），
    // cfprefsd 懒落盘会让 root 侧读到旧值——relay→bridge 切换读到 relay 不自退，
    // bridge 下残留注册/隧道（UI 已显示桥接但服务仍按中继跑，模式分叉）。synchronize
    // 强制 flush 后再 notify，消除「通知先于落盘」的读写竞态。
    NSUserDefaults *syncDefs = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    [syncDefs synchronize];
    notify_post(TVNC_NOTIFY_PREFS_CHANGED);
}

// Add Apply button in nav bar
- (void)viewDidLoad {
    [super viewDidLoad];

    _notificationGenerator = [[UINotificationFeedbackGenerator alloc] init];
    _primaryColor = [UIColor colorWithRed:35 / 255.0 green:158 / 255.0 blue:171 / 255.0 alpha:1.0];
    [[UISwitch appearanceWhenContainedInInstancesOfClasses:@[
        [self class],
    ]] setOnTintColor:_primaryColor];
    [[UISlider appearanceWhenContainedInInstancesOfClasses:@[
        [self class],
    ]] setMinimumTrackTintColor:_primaryColor];
    [self.view setTintColor:_primaryColor];

    self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"设置"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:nil
                                                                            action:nil];
    self.navigationItem.backBarButtonItem.tintColor = _primaryColor;

    if ([self hasManagedConfiguration]) {
        return;
    }
#ifdef THEBOOTSTRAP
    // 2026-08-21 连接网关/桥接网关按钮文字动态化（设计文档 7.4）：
    // 监听 TVNCAppStore 状态变化（object=AppStore 单例），驱动按钮文字 已连接/已桥接。
    // 托管页（ManagedRoot.plist）无连接网关按钮，已提前 return，不注册。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_gatewayStateDidChange)
                                                 name:TVNCGatewayStateDidChangeNotification
                                               object:[TVNCAppStore sharedStore]];
#endif
    // 右上角 Apply 按钮已移除（2026-08-14）：
    // 配置变更按 reload 级别即时生效（网关组自动重注册 / hot 走控制端热重载），
    // restart 级配置修改后由 setPreferenceValue 拦截自动弹确认框触发重启，
    // 不再需要手动"应用"动作（对齐控制端 Web 面板 setConfig 自动重启行为）。
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UINavigationControllerDelegate（2026-08-15：根页隐藏导航栏，子页临时显示）

/**
 * 导航控制器即将显示某个 VC 时按层级切换导航栏显隐：
 * 根页（self）隐藏（顶部干净、顶到状态栏）；push 进入的子设置页显示（承载返回按钮），
 * 退回根页再次隐藏。仅影响「设置」Tab 的导航控制器。
 * @param navigationController 设置页所在导航控制器
 * @param viewController 即将显示的控制器
 * @param animated 是否动画
 */
- (void)navigationController:(UINavigationController *)navigationController
      willShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    BOOL isRoot = (viewController == self);
    [navigationController setNavigationBarHidden:!isRoot animated:animated];
}

#pragma mark - Actions

/**
 * 需要重启服务才能生效的配置键（与 CONFIG_DEFS reload=restart 对齐）
 * @return NSSet<NSString *> 键集合
 */
- (NSSet<NSString *> *)_restartRequiredKeys {
    static NSSet<NSString *> *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSSet setWithArray:@[
            @"BindHost", @"FullPassword", @"ViewOnlyPassword",
            @"TileSize", @"MaxRects", @"AsyncSwap",
            // 2026-08-20 根因修复：Scale/OrientationPadFix 会重建 framebuffer，不能热重载
            // （热重载在非 RFB 线程 free 旧 buffer → 与后台 rfbRunEventLoop 竞态崩溃），改 restart 级
            @"Scale", @"OrientationPadFix",
            // 2026-08-20：BonjourEnabled 为 server 启动期标志（reload 不注销已注册服务），
            // 原 manager 重启级 → 归入 server 重启级（watchdog 重启生效）
            @"BonjourEnabled",
            // 2026-08-20 起不再触发重启：
            // - ConnectionMode：TVNCServiceCoordinator 每 3s 轮询自动生效（relay→拉起 / bridge→停服务），重启是冗余中断
            // - FrameRateSpec：hot 级，设置页热重载通道（notify → trollvncserver tvApplyPrefsChanged）即时生效
            // - Notifications：instant 级，同上走热重载
            @"PerformanceMode", // 2026-08-20：画质模式预设含 restart 级底层参数（TileSize/MaxRects/AsyncSwap），需重启生效
        ]];
    });
    return keys;
}

/// 2026-08-20：原「需重启 trollvncmanager 的配置键」机制整体移除——App 沙盒内 kill root
/// 进程恒 EPERM，该通路从未生效。新归属：
/// - GatewayHost/GatewayToken/WatchdogThrottleInterval/WatchdogExitTimeout：
///   prefs-changed 通知 → manager 自治（重读配置/重连注册/watchdog 属性热调），即时生效
/// - BonjourEnabled：归入 _restartRequiredKeys（server 启动期标志，经 watchdog 重启生效）

/// 防抖：连续修改多个 restart 配置时合并为一次重启（400ms 窗口）
- (void)_scheduleAutoRestart {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_autoRestartNow) object:nil];
    [self performSelector:@selector(_autoRestartNow) withObject:nil afterDelay:0.4];
}

/// 2026-08-20 由「重启确认弹窗」改为「防抖自动重启」：restart 级配置变更（含选择器类：
/// 连接模式/画质模式/帧率/通知）后直接重启服务生效，不再弹确认框打断操作（用户反馈）。
- (void)_autoRestartNow {
    // 端口固定不可调（5901/5801），仅校验绑定地址（沿用原 Apply 逻辑）
    NSString *bindHost = @"";
    for (PSSpecifier *sp in _specifiers) {
        NSString *key = [sp propertyForKey:@"key"];
        if ([key isEqualToString:@"BindHost"]) {
            id val = [self readPreferenceValue:sp];
            if ([val isKindOfClass:[NSString class]]) {
                bindHost = (NSString *)val;
            }
            break;
        }
    }

    if (!TVNCIsValidBindHostLiteral(bindHost)) {
        NSString *t = NSLocalizedStringFromTableInBundle(@"Invalid Bind Address", @"Localizable", self.bundle, nil);
        NSString *msg = NSLocalizedStringFromTableInBundle(
            @"Bind address must be a valid IPv4/IPv6 literal, or empty to listen on all interfaces.",
            @"Localizable", self.bundle, nil);
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:t
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return; // do not restart now
    }

    TVNCRestartVNCService();
    [_notificationGenerator notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self.view endEditing:YES];
}

- (NSString *)jbrootPath {
    if (!_jbrootPath) {
        NSString *rootPath = [self.bundle bundlePath];
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
        _jbrootPath = rootPath;
    }
    return _jbrootPath;
}

- (void)viewLogs {
#if TARGET_IPHONE_SIMULATOR
    NSString *logsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/trollvnc-stderr.log"];
#else
    NSString *logsPath = [self.jbrootPath stringByAppendingPathComponent:@"tmp/trollvnc-stderr.log"];
#endif

    StripedTextTableViewController *logsVC = [[StripedTextTableViewController alloc] initWithPath:logsPath];
    logsVC.primaryColor = self.primaryColor;

    [logsVC setAutoReload:YES];
    [logsVC setMaximumNumberOfRows:1000];
    [logsVC setMaximumNumberOfLines:20];
    [logsVC setReversed:YES];
    [logsVC setAllowDismissal:YES];
    [logsVC setAllowMultiline:YES];
    [logsVC setAllowTrash:NO];
    [logsVC setAllowSearch:YES];
    [logsVC setAllowShare:YES];
    [logsVC setPullToReload:YES];
    [logsVC setTapToCopy:YES];
    [logsVC setPressToCopy:YES];
    [logsVC setPreserveEmptyLines:NO];
    [logsVC setRemoveDuplicates:NO];

    NSRegularExpression *rowRegex =
        [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\b"
                                                  options:0
                                                    error:nil];

    [logsVC setRowPrefixRegularExpression:rowRegex];
    [logsVC setRowSeparator:@"\r\n"];
    [logsVC setTitle:NSLocalizedStringFromTableInBundle(@"View Logs", @"Localizable", self.bundle, nil)];
    [logsVC setLocalizationBundle:self.bundle];

    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:logsVC];
    [self presentViewController:navController animated:YES completion:nil];
}

- (NSString *)cacertPath {
#if TARGET_IPHONE_SIMULATOR
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.82flex.trollvnc.ca-cert.pem"];
#else
    return [self.jbrootPath
        stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.82flex.trollvnc.ca-cert.pem"];
#endif
}

- (NSString *)cakeyPath {
#if TARGET_IPHONE_SIMULATOR
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.82flex.trollvnc.ca-key.pem"];
#else
    return [self.jbrootPath
        stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.82flex.trollvnc.ca-key.pem"];
#endif
}

- (void)exportCertificate {
    NSString *cacertPath = [self cacertPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cacertPath]) {
        NSString *title =
            NSLocalizedStringFromTableInBundle(@"Certificate Not Found", @"Localizable", self.bundle, nil);
        NSString *message = NSLocalizedStringFromTableInBundle(
            @"You need to generate a self-signed CA certificate first before exporting it.", @"Localizable",
            self.bundle, nil);
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];

        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSURL *fileURL = [NSURL fileURLWithPath:cacertPath];
    if (!fileURL) {
        return;
    }

    UIActivityViewController *activityViewController =
        [[UIActivityViewController alloc] initWithActivityItems:@[ fileURL ] applicationActivities:nil];

    PSTableCell *exportCertCell = nil;
    if (_exportCertSpecifier) {
        exportCertCell = [self cachedCellForSpecifier:_exportCertSpecifier];
    }
    activityViewController.popoverPresentationController.sourceView = exportCertCell ?: self.view;

    [self presentViewController:activityViewController animated:YES completion:nil];
}

- (void)generateKeys {
    NSString *cakeyPath = [self cakeyPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:cakeyPath]) {
        NSString *title =
            NSLocalizedStringFromTableInBundle(@"Overwrite Existing Keys", @"Localizable", self.bundle, nil);
        NSString *message =
            NSLocalizedStringFromTableInBundle(@"A CA private key already exists. Generating new keys will overwrite "
                                               @"the existing ones. Are you sure you want to continue?",
                                               @"Localizable", self.bundle, nil);
        NSString *cancel = NSLocalizedStringFromTableInBundle(@"Cancel", @"Localizable", self.bundle, nil);
        NSString *generate = NSLocalizedStringFromTableInBundle(@"Overwrite", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:generate
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *_Nonnull action) {
                                                    [weakSelf _reallyGenerateKeys];
                                                }]];
        [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringFromTableInBundle(
                                                            @"Export Certificate…", @"Localizable", self.bundle, nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_Nonnull action) {
                                                    [weakSelf exportCertificate];
                                                }]];

        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [self _reallyGenerateKeys];
}

- (void)_reallyGenerateKeys {
    NSString *randomUUID = [[[NSUUID UUID] UUIDString] substringFromIndex:28];
    NSString *commonName = [NSString stringWithFormat:@"SuperPhone %@", randomUUID];

    ZTSelfSignedCertificate *ca = [ZTSelfSignedCertificate generateWithCommonName:commonName];
    if (!ca) {
        NSString *title = NSLocalizedStringFromTableInBundle(@"Generation Failed", @"Localizable", self.bundle, nil);
        NSString *message = NSLocalizedStringFromTableInBundle(@"Failed to generate self-signed CA certificate.",
                                                               @"Localizable", self.bundle, nil);
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];

        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    BOOL succeed = YES;
    NSError *error = nil;
    do {
        NSString *cacertPath = [self cacertPath];
        succeed = [ca.certificatePEM writeToFile:cacertPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (!succeed) {
            break;
        }

        succeed = [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0600}
                                                   ofItemAtPath:cacertPath
                                                          error:&error];
        if (!succeed) {
            break;
        }

        NSString *cakeyPath = [self cakeyPath];
        succeed = [ca.privateKeyPEM writeToFile:cakeyPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (!succeed) {
            break;
        }

        succeed = [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0600}
                                                   ofItemAtPath:cakeyPath
                                                          error:&error];
        if (!succeed) {
            break;
        }
    } while (0);

    if (!succeed) {
        NSString *title = NSLocalizedStringFromTableInBundle(@"Generation Failed", @"Localizable", self.bundle, nil);
        NSString *message =
            [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"Failed to save generated keys: %@",
                                                                          @"Localizable", self.bundle, nil),
                                       error.localizedDescription];
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];

        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [super setPreferenceValue:[self cacertPath] specifier:[self certSpecifier]];
    [super setPreferenceValue:[self cakeyPath] specifier:[self keysSpecifier]];

    [self reloadSpecifiers];

    NSString *title = NSLocalizedStringFromTableInBundle(@"Generation Succeeded", @"Localizable", self.bundle, nil);
    NSString *message = NSLocalizedStringFromTableInBundle(
        @"The self-signed CA certificate and private key have been successfully generated. You need to trust this "
        @"certificate in your client browser or operating system. Restart the service to apply the changes.",
        @"Localizable", self.bundle, nil);
    NSString *restart = NSLocalizedStringFromTableInBundle(@"Restart", @"Localizable", self.bundle, nil);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    // Apply 按钮已移除：生成证书后直接提供"重启服务"入口使 SslCertFile/SslKeyFile 生效
    [alert addAction:[UIAlertAction actionWithTitle:restart
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                TVNCRestartVNCService();
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringFromTableInBundle(@"Export Certificate…",
                                                                                       @"Localizable", self.bundle, nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                [self exportCertificate];
                                            }]];

    [self presentViewController:alert animated:YES completion:nil];
}

/// 2026-08-21 关于分组「重启服务」按钮：发跨进程通知，manager watchdog 重启 trollvncserver
- (void)restartService {
    TVNCRestartVNCService();
    [_notificationGenerator notificationOccurred:UINotificationFeedbackTypeSuccess];
}

/// 2026-08-21 底部无分组「版本信息」静态文本 getter：
/// App（bootstrap）取 mainBundle（TrollVNC.app）版本；越狱设置页（Preferences.app 进程）
/// 取 TrollVNCPrefs bundle 版本
- (NSString *)appVersionText {
#ifdef THEBOOTSTRAP
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
#else
    NSString *ver = [self.bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *build = [self.bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
#endif
    if (!ver.length) return @"";
    return build.length ? [NSString stringWithFormat:@"v%@ (%@)", ver, build] : ver;
}

- (void)cleanResidues {
    // 换号身份锚清理（identity.reset，2026-08-28）：设置页一键入口 —— 选 App → 确认 → 5802 commit。
    // 执行体在 root daemon（TRIdentityReset），App 仅消费 5802 本地通道（无权限直写 keychain-2.db）。
    __weak typeof(self) weakSelf = self;
    [self _identityPost:@{@"op": @"app.list", @"params": @{}} completion:^(NSDictionary *resp, NSString *errMsg) {
        NSArray *apps = resp[@"apps"];
        if (errMsg || ![apps isKindOfClass:[NSArray class]] || apps.count == 0) {
            UIAlertController *fail = [UIAlertController alertControllerWithTitle:@"清理残留"
                message:(errMsg ?: @"未获取到应用列表（服务未运行或无用户应用）")
                preferredStyle:UIAlertControllerStyleAlert];
            [fail addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [weakSelf presentViewController:fail animated:YES completion:nil];
            return;
        }
#ifdef THEBOOTSTRAP
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSString *> *nameToBundle = [NSMutableDictionary dictionary];
        for (NSDictionary *app in apps) {
            NSString *bid = app[@"bundleId"];
            NSString *rawName = ([app[@"name"] isKindOfClass:[NSString class]]) ? (NSString *)app[@"name"] : nil;
            NSString *name = (rawName.length > 0) ? rawName : bid;
            if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
            [names addObject:name];
            nameToBundle[name] = bid;
        }
        BRTextPickerView *picker = [[BRTextPickerView alloc] initWithPickerMode:BRTextPickerComponentSingle];
        picker.dataSourceArr = names;
        picker.title = @"选择要清理残留的应用";
        picker.singleResultBlock = ^(BRTextModel *model, NSInteger index) {
            NSString *bundleId = nameToBundle[model.text];
            if (!bundleId.length) return;
            UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"清理残留"
                message:[NSString stringWithFormat:@"将清理「%@」(%@) 的 Keychain 身份项与本地残留。\n不可恢复；securityd 缓存可能需重启设备后完全生效。", model.text, bundleId]
                preferredStyle:UIAlertControllerStyleAlert];
            [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [confirm addAction:[UIAlertAction actionWithTitle:@"清理" style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *action) {
                    [weakSelf _identityPost:@{@"op": @"identity.reset", @"params": @{@"bundleId": bundleId, @"mode": @"commit"}}
                        completion:^(NSDictionary *result, NSString *err2) {
                            NSMutableString *msg = [NSMutableString string];
                            if (err2) {
                                [msg appendFormat:@"失败：%@", err2];
                            } else if (![result[@"ok"] boolValue]) {
                                [msg appendFormat:@"失败：%@", result[@"error"] ?: @"未知错误"];
                            } else {
                                [msg appendFormat:@"完成（层级 %@）。", result[@"tier"] ?: @""];
                                if ([result[@"tier"] isEqualToString:@"sop"])
                                    [msg appendString:@"\n未发现可自动清理的残留——建议：卸载重装 + 重置广告标识符。"];
                                for (NSString *w in result[@"warnings"]) [msg appendFormat:@"\n• %@", w];
                            }
                            UIAlertController *done = [UIAlertController alertControllerWithTitle:@"清理残留"
                                message:msg preferredStyle:UIAlertControllerStyleAlert];
                            [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                            [weakSelf presentViewController:done animated:YES completion:nil];
                        }];
            }]];
            [weakSelf presentViewController:confirm animated:YES completion:nil];
        };
        [picker show];
#else
        // prefs bundle（越狱设置页）上下文：BRPickerView 不在该 target 编译，引导回 App 内使用
        UIAlertController *tip = [UIAlertController alertControllerWithTitle:@"清理残留"
            message:@"请在 SuperPhone App 的设置页中使用此功能（需选择目标应用）。"
            preferredStyle:UIAlertControllerStyleAlert];
        [tip addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [weakSelf presentViewController:tip animated:YES completion:nil];
#endif
    }];
}

/** 5802 本地管理 API 调用（清理残留专用；127.0.0.1 环回 + ATS NSAllowsArbitraryLoads 放行） */
- (void)_identityPost:(NSDictionary *)body completion:(void (^)(NSDictionary *resp, NSString *errMsg))completion {
    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:5802/"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 15.0;
    NSError *jerr = nil;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jerr];
    if (jerr || !req.HTTPBody) {
        completion(nil, @"请求序列化失败");
        return;
    }
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
            if (err) {
                completion(nil, err.localizedDescription ?: @"服务未运行");
                return;
            }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:[NSDictionary class]]) {
                completion(nil, @"响应解析失败");
                return;
            }
            completion(json, nil);
        }] resume];
}

- (void)resetDefaults {
    NSString *title = NSLocalizedStringFromTableInBundle(@"Reset to Defaults", @"Localizable", self.bundle, nil);
    NSString *message = NSLocalizedStringFromTableInBundle(
        @"Are you sure you want to reset all settings to their defaults?", @"Localizable", self.bundle, nil);
    NSString *cancel = NSLocalizedStringFromTableInBundle(@"Cancel", @"Localizable", self.bundle, nil);
    NSString *reset = NSLocalizedStringFromTableInBundle(@"Reset", @"Localizable", self.bundle, nil);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:reset
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                [weakSelf _reallyResetDefaults];
                                            }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_reallyResetDefaults {
    // 2026-08-20 根因修复：仅删空域会把网关地址/令牌/DeviceUUID/watchdog 配置一并清空，
    // 导致设备失联（manager 无网关地址不注册）+ watchdog 回退 0 节流（重启风暴）。
    // 重置只恢复"功能默认"，保留设备身份与网络连接信息，并写回关键安全默认。
    NSUserDefaults *keep = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    NSString *deviceUUID = [keep stringForKey:@"DeviceUUID"];
    NSString *gatewayHost = [keep stringForKey:@"GatewayHost"];
    NSString *gatewayToken = [keep stringForKey:@"GatewayToken"];

    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:kTRAppPrefsSuiteName];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // 写回保留项 + 关键安全默认（watchdog 节流/退出超时不可为 0，否则服务重启风暴）
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    if (deviceUUID.length) [defs setObject:deviceUUID forKey:@"DeviceUUID"];
    if (gatewayHost.length) [defs setObject:gatewayHost forKey:@"GatewayHost"];
    if (gatewayToken.length) [defs setObject:gatewayToken forKey:@"GatewayToken"];
    [defs setObject:@"relay" forKey:@"ConnectionMode"];
    // 2026-08-28 风控收敛：Bonjour 默认关闭（原为 YES 安全默认）——mDNS publish 即广播，
    // 默认不发布不可见；重置后与内建默认（trollvncserver.mm gBonjourEnabled=NO）对齐，勿改回
    [defs setBool:NO forKey:@"BonjourEnabled"];
    [defs setInteger:60 forKey:@"WatchdogThrottleInterval"];
    [defs setInteger:3 forKey:@"WatchdogExitTimeout"];
    [defs synchronize];

    [self reloadSpecifiers];

    // Apply 按钮已移除：重置后自动重启，使默认值在服务端全局变量中生效
    [self _scheduleAutoRestart];
}

#pragma mark - UITableViewDataSource & UITableViewDelegate

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self hasManagedConfiguration]) {
        return [super tableView:tableView cellForRowAtIndexPath:indexPath];
    }

    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *key = [specifier propertyForKey:@"cell"];
    if ([key isEqualToString:@"PSButtonCell"]) {
        // 2026-08-20：全宽按钮（搜索/连接网关/重新生成证书）已改用 cellClass=TVNCButtonCell 自定义渲染，
        // 此处仅处理普通 PSButtonCell（查看日志/重置默认）的文字颜色。
        UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
        BOOL isDestructive =
            ([specifier propertyForKey:@"isDestructive"] && [[specifier propertyForKey:@"isDestructive"] boolValue]);
        cell.textLabel.textColor = isDestructive ? [UIColor systemRedColor] : self.primaryColor;
        cell.textLabel.highlightedTextColor = isDestructive ? [UIColor systemRedColor] : self.primaryColor;
        return cell;
    }

#ifdef THEBOOTSTRAP
    // 2026-08-21 连接网关/桥接网关按钮动态标题（设计文档 7.4）：
    // cell 复用/刷新（setSpecifier/refreshCellContentsWithSpecifier）会重读 plist label 恢复默认文字，
    // 返回前重放动态标题（与 _applyGatewayButtonTitles 同语义）。
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    if ([cell isKindOfClass:[TVNCButtonCell class]] &&
        [[specifier propertyForKey:@"action"] isEqualToString:@"connectGateway"]) {
        [(TVNCButtonCell *)cell setCellTitle:[self _gatewayButtonTitle]];
    }
    return cell;
#else
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
#endif
}

- (void)tableView:(UITableView *)tableView
      willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    // 2026-08-20：移除 PSSliderCell 的 findLabelInView+sizeToFit hack——
    // 系统 PSSliderCell 自带 Auto Layout，sizeToFit 会收缩标题 label 导致标题丢失/错乱。
    (void)tableView;
    (void)cell;
    (void)indexPath;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return [super tableView:tableView titleForFooterInSection:section];
}


#pragma mark - Gateway Search (internal farm)

/// 2026-08-21 连接网关/桥接网关按钮动态标题（设计文档 7.4）：
/// relay 且已注册 → 「已连接」；bridge 且桥接已连 → 「已桥接」；其余 → 默认（按模式）。
/// prefs bundle（Preferences.app 进程）无 App 状态层（TVNCAppStore 仅 App 编译），恒默认文字。
- (NSString *)_gatewayButtonTitle {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    NSString *connMode = [defaults stringForKey:@"ConnectionMode"] ?: @"relay";
#ifdef THEBOOTSTRAP
    TVNCGatewayState state = [TVNCAppStore sharedStore].gatewayState;
    if ([connMode isEqualToString:@"bridge"] && state == TVNCGatewayStateBridgeConnected) {
        return @"已桥接";
    }
    if ([connMode isEqualToString:@"relay"] && state == TVNCGatewayStateRegistered) {
        return @"已连接";
    }
#endif
    return [connMode isEqualToString:@"bridge"] ? @"桥接网关" : @"连接网关";
}

#ifdef THEBOOTSTRAP
/// 2026-08-21 遍历可见 cell，对 action==connectGateway 的 TVNCButtonCell 应用动态标题。
/// 不写回 specifier：后续 setSpecifier/refreshCellContentsWithSpecifier 会重读 plist label
/// 恢复默认文字，cellForRow 已负责重新应用动态标题。
- (void)_applyGatewayButtonTitles {
    UITableView *tv = [self valueForKey:@"table"];   // PSListController 私有 table，KVC 取（无公开属性）
    if (!tv) return;
    for (UITableViewCell *cell in tv.visibleCells) {
        if (![cell isKindOfClass:[TVNCButtonCell class]]) continue;
        PSSpecifier *sp = [(PSTableCell *)cell specifier];
        if (![[sp propertyForKey:@"action"] isEqualToString:@"connectGateway"]) continue;
        [(TVNCButtonCell *)cell setCellTitle:[self _gatewayButtonTitle]];
    }
}

- (void)_gatewayStateDidChange {
    // 防御性切主队列（TVNCAppStore 实际在主线程发布）；nil 消息安全
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf _applyGatewayButtonTitles];
    });
}
#endif

/// 2026-08-20 双模式的「连接网关」按钮（幂等 ensure 语义，不碰进程重启）：
/// - 桥接控制：纯 App 级——用当前配置拉取设备目录验证网关可达，反馈设备数
/// - 网关中继（App/bootstrap）：ensureServiceRunning——manager 死则立即 spawn（读最新 defaults，
///   不等 3s 轮询）；活则交给 manager 的 prefs-changed 自治（重读配置/重连），无需 kill 重启（沙盒内恒 EPERM）
/// - 网关中继（prefs bundle/越狱设置页）：无 spawn root 能力，manager 由 launchd 常驻自治，
///   按钮退化为验证网关可达（与桥接分支同款反馈，两端行为对齐）
- (void)connectGateway {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    NSString *host = [defaults stringForKey:@"GatewayHost"];
    if (!host.length) {
        // 2026-08-21 多态按钮（relay「连接网关」/ bridge「桥接网关」共用入口）：
        // 网关地址未填 → 点击转为搜索网关（settings.searchGateway）
        [self searchGateway];
        return;
    }
    [self showGatewayMessage:[NSString stringWithFormat:@"正在连接网关 %@…", host]];
    NSString *connMode = [defaults stringForKey:@"ConnectionMode"] ?: @"relay";
    if ([connMode isEqualToString:@"bridge"]) {
        __weak typeof(self) weakSelf = self;
        [[TVNCGatewayClient sharedClient] fetchDevicesWithCompletion:^(NSArray<NSDictionary *> *devices, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (devices) {
                [self showGatewayMessage:[NSString stringWithFormat:@"网关可达 · %ld 台设备", (long)devices.count]];
#ifdef THEBOOTSTRAP
                // 2026-08-21 状态通知可能滞后（AppStore 状态由自身拉取驱动），点击验证可达后主动刷新按钮文字
                [self _applyGatewayButtonTitles];
#endif
            } else {
                [self showGatewayMessage:[NSString stringWithFormat:@"网关不可达：%@",
                    error.localizedDescription ?: @"未知错误"]];
            }
        }];
    } else {
#ifdef THEBOOTSTRAP
        // App（bootstrap）：manager 死则立即 spawn（读最新 defaults，不等 3s 轮询）；
        // 活则交给 manager 的 prefs-changed 自治（重读配置/重连），无需 kill 重启（沙盒内恒 EPERM）
        [[TVNCServiceCoordinator sharedCoordinator] ensureServiceRunning];
#else
        // prefs bundle（越狱设置页，Preferences.app 进程）：无 spawn root 能力；
        // manager 由 launchd 常驻自治（prefs-changed 通知重读配置/重连），
        // 按钮退化为验证网关可达（与 bridge 分支同款反馈语义，两端行为对齐）
        __weak typeof(self) weakSelf = self;
        [[TVNCGatewayClient sharedClient] fetchDevicesWithCompletion:^(NSArray<NSDictionary *> *devices, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (devices) {
                [self showGatewayMessage:[NSString stringWithFormat:@"网关可达 · %ld 台设备", (long)devices.count]];
            } else {
                [self showGatewayMessage:[NSString stringWithFormat:@"网关不可达：%@",
                    error.localizedDescription ?: @"未知错误"]];
            }
        }];
#endif
    }
}

- (void)searchGateway {
    if (self.gatewayBrowser) {
        [self.gatewayBrowser stop];
        self.gatewayBrowser = nil;
    }
    self.gatewayServices = [NSMutableArray array];
    self.gatewaySearchShown = NO;
    self.gatewayBrowser = [[NSNetServiceBrowser alloc] init];
    self.gatewayBrowser.delegate = self;
    [self.gatewayBrowser searchForServicesOfType:@"_superphone-farm._tcp" inDomain:@"local."];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"搜索网关"
                                                                  message:@"正在局域网内查找 SuperPhone 网关…"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        [self.gatewayBrowser stop];
        self.gatewayBrowser = nil;
    }]];
    [self presentViewController:alert animated:YES completion:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self presentFoundGateways];
    });
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
    [self.gatewayServices addObject:service];
    service.delegate = self;
    [service resolveWithTimeout:3.0];
}

- (void)presentFoundGateways {
    if (!self.gatewayBrowser || self.gatewaySearchShown) return;
    self.gatewaySearchShown = YES;
    [self.gatewayBrowser stop];
    self.gatewayBrowser = nil;

    [self dismissViewControllerAnimated:YES completion:nil];

    NSMutableArray<NSNetService *> *ready = [NSMutableArray array];
    for (NSNetService *svc in self.gatewayServices) {
        if ([self ipAddressOfService:svc]) [ready addObject:svc];
    }

    if (!ready.count) {
        [self showGatewayMessage:@"未找到网关，请检查软路由是否运行 superphone-farm"];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择网关"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSNetService *svc in ready) {
        NSString *host = [self ipAddressOfService:svc];
        NSInteger port = svc.port;
        NSString *title = [NSString stringWithFormat:@"%@ (%@:%ld)", svc.name, host, (long)port];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            __strong typeof(weakSelf) self = weakSelf;
            [self saveGateway:host port:port];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)saveGateway:(NSString *)host port:(NSInteger)port {
    // 端口固定不可调（18081 = 网关注册端口），忽略搜索到的 port，统一写 18081
    (void)port;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kTRAppPrefsSuiteName];
    [defaults setObject:host forKey:@"GatewayHost"];
    [defaults setInteger:18081 forKey:@"GatewayPort"];
    [defaults synchronize];
    [self showGatewayMessage:[NSString stringWithFormat:@"已设置网关 %@:%d", host, 18081]];
    [self reloadSpecifiers];
    // 2026-08-20：网关地址变更 → prefs-changed 通知（manager 自治：worker 检测 host 变更后
    // 断开重连注册到新网关；此路径绕过 setPreferenceValue，须显式发通知）
    notify_post(TVNC_NOTIFY_PREFS_CHANGED);
}

- (NSString *)ipAddressOfService:(NSNetService *)service {
    for (NSData *address in service.addresses) {
        const struct sockaddr *sa = (const struct sockaddr *)address.bytes;
        if (sa->sa_family != AF_INET) continue;
        char host[NI_MAXHOST];
        if (getnameinfo(sa, (socklen_t)address.length, host, sizeof(host), NULL, 0, NI_NUMERICHOST) == 0) {
            NSString *ip = [NSString stringWithUTF8String:host];
            if (![ip hasPrefix:@"169.254."]) return ip;
        }
    }
    return nil;
}

- (void)showGatewayMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"网关" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
