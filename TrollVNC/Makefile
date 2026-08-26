export PACKAGE_VERSION := 0.0.1
export THEOS_PACKAGE_SCHEME

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
ARCHS := arm64 x86_64
TARGET := simulator:clang:latest:15.0
IPHONE_SIMULATOR_ROOT := $(shell devkit/sim-root.sh)
else
ARCHS := arm64
ifeq ($(THEOS_PACKAGE_SCHEME),)
TARGET := iphone:clang:16.5:14.0
else
TARGET := iphone:clang:16.5:15.0
endif
endif

GO_EASY_ON_ME := 1

include $(THEOS)/makefiles/common.mk

TOOL_NAME += trollvncserver

trollvncserver_USE_MODULES := 0

trollvncserver_FILES += src/trollvncserver.mm
trollvncserver_FILES += src/BulletinManager.mm
trollvncserver_FILES += src/ClipboardManager.mm
trollvncserver_FILES += src/ScreenCapturer.mm
trollvncserver_FILES += src/STHIDEventGenerator.mm
trollvncserver_FILES += src/OhMyJetsam.mm
trollvncserver_FILES += src/TRScreenHasher.mm
trollvncserver_FILES += src/TRSelfSignedCert.mm
# 共享模块（App 伪装页 / server / manager 三 target 各自编译同一份源码，写库单一实现）
trollvncserver_FILES += src/CoordTransform.mm
trollvncserver_FILES += src/TRDataFiller.mm
trollvncserver_FILES += src/TRWpsTile.mm
# 数据填充构建产物（corpus.js/数据源 → ObjC 常量，勿手改）
trollvncserver_FILES += src/TRCorpus.mm
trollvncserver_FILES += src/TRAreaCodes.mm
trollvncserver_FILES += src/TRHlr.mm

trollvncserver_CFLAGS += -fobjc-arc
trollvncserver_CFLAGS += -Wno-unknown-warning-option
trollvncserver_CFLAGS += -Wno-unused-but-set-variable
ifeq ($(THEOS_DEVICE_SIMULATOR),)
trollvncserver_CFLAGS += -march=armv8-a+crc
endif
trollvncserver_CCFLAGS += -std=c++20

trollvncserver_CFLAGS += -DPACKAGE_VERSION=\"$(PACKAGE_VERSION)\"
# libvncserver 预编译库启用 LIBZ（rfbconfig.h 声明宏），trollvncserver.mm 需同宏才能访问
# ExtendedClipboard 字段（setXCutTextUTF8/enableExtendedClipboard 在 #ifdef LIBVNCSERVER_HAVE_LIBZ 内）
# .mm(ObjC++) 编译走 CCFLAGS（同 -std=c++20），宏须 CFLAGS+CCFLAGS 双处传递
trollvncserver_CFLAGS += -DLIBVNCSERVER_HAVE_LIBZ
trollvncserver_CCFLAGS += -DLIBVNCSERVER_HAVE_LIBZ
ifeq ($(THEOS_PACKAGE_SCHEME),)
trollvncserver_CFLAGS += -DTHEOS_PACKAGE_SCHEME=\"legacy\"
else
trollvncserver_CFLAGS += -DTHEOS_PACKAGE_SCHEME=\"$(THEOS_PACKAGE_SCHEME)\"
endif

ifeq ($(THEBOOTSTRAP),1)
trollvncserver_CFLAGS += -DTHEBOOTSTRAP=1
endif

trollvncserver_CFLAGS += -Iinclude-spi
ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncserver_CFLAGS += -Iinclude-simulator
trollvncserver_LDFLAGS += -Llib-simulator
trollvncserver_LDFLAGS += -FPrivateFrameworks
else
trollvncserver_CFLAGS += -Iinclude
trollvncserver_LDFLAGS += -Llib
endif

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncserver_LIBRARIES += vncserver
trollvncserver_LIBRARIES += z
else
trollvncserver_LIBRARIES += crypto
trollvncserver_LIBRARIES += lzo2
trollvncserver_LIBRARIES += turbojpeg
trollvncserver_LIBRARIES += png18
trollvncserver_LIBRARIES += sasl2
trollvncserver_LIBRARIES += ssl
trollvncserver_LIBRARIES += vncserver
trollvncserver_LIBRARIES += z
endif

trollvncserver_LIBRARIES += sqlite3

trollvncserver_FRAMEWORKS += Accelerate
trollvncserver_FRAMEWORKS += CoreGraphics
trollvncserver_FRAMEWORKS += CoreImage
trollvncserver_FRAMEWORKS += Contacts
trollvncserver_FRAMEWORKS += CoreLocation
trollvncserver_FRAMEWORKS += CoreMedia
trollvncserver_FRAMEWORKS += CoreVideo
trollvncserver_FRAMEWORKS += Foundation
trollvncserver_FRAMEWORKS += IOKit
trollvncserver_FRAMEWORKS += IOSurface
trollvncserver_FRAMEWORKS += Photos
trollvncserver_FRAMEWORKS += QuartzCore
trollvncserver_FRAMEWORKS += Security
trollvncserver_FRAMEWORKS += UIKit
trollvncserver_FRAMEWORKS += UserNotifications

trollvncserver_PRIVATE_FRAMEWORKS += FrontBoardServices

ifeq ($(THEOS_DEVICE_SIMULATOR),)
trollvncserver_PRIVATE_FRAMEWORKS += Preferences
endif

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncserver_CODESIGN_FLAGS += -f -s - --entitlements src/trollvncserver-simulator.entitlements
else
trollvncserver_CODESIGN_FLAGS += -Ssrc/trollvncserver.entitlements
endif

ifeq ($(THEBOOTSTRAP),1)
TOOL_NAME += trollvncmanager

trollvncmanager_FILES += src/trollvncmanager.mm
trollvncmanager_FILES += src/TRWatchDog.mm
trollvncmanager_FILES += src/TaskProcess+ObjC.swift
trollvncmanager_FILES += src/OhMyJetsam.mm
trollvncmanager_FILES += src/TRGatewayClient.mm
trollvncmanager_FILES += src/TRCapabilityRegistry.mm
trollvncmanager_FILES += src/TRTunnelClient.mm
# 能力执行依赖（守护进程侧类，Manager 内嵌执行能力时同样需要；与 trollvncserver 为独立二进制，无符号冲突）
trollvncmanager_FILES += src/BulletinManager.mm
trollvncmanager_FILES += src/ClipboardManager.mm
trollvncmanager_FILES += src/STHIDEventGenerator.mm
trollvncmanager_FILES += src/ScreenCapturer.mm
# 守护进程桥接函数的 Manager 降级实现（tvGetInflightStats/tvGetBonjourTXT/tvReloadConfigForKey）
trollvncmanager_FILES += src/TRDaemonBridgeManager.mm
# 自签证书生成（原 TRCapabilityRegistry 内实现抽出共享，trollvncmanager 与 trollvncserver 各自编译）
trollvncmanager_FILES += src/TRSelfSignedCert.mm
# 全系统改定位：注入原语 + 自治控制器 + Apple 地图算路 + 区域漫游（MKDirections 两点沿真实道路轨迹）
trollvncmanager_FILES += src/SimLocationManager.mm
trollvncmanager_FILES += src/SimLocationController.mm
trollvncmanager_FILES += src/SimRouteCalculator.mm
trollvncmanager_FILES += src/RegionSimulator.mm
# 共享模块（App 伪装页 / server / manager 三 target 各自编译同一份源码，写库单一实现）
trollvncmanager_FILES += src/CoordTransform.mm
trollvncmanager_FILES += src/TRDataFiller.mm
trollvncmanager_FILES += src/TRWpsTile.mm
# 每日轨迹（2026-08-26）：manager daemon 自治的每日通话/短信/未接 + 每周联系人（真人行为模拟）
trollvncmanager_FILES += src/TRDailyTrajectory.mm
# 数据填充构建产物（corpus.js/数据源 → ObjC 常量，勿手改）
trollvncmanager_FILES += src/TRCorpus.mm
trollvncmanager_FILES += src/TRAreaCodes.mm
trollvncmanager_FILES += src/TRHlr.mm
trollvncmanager_FRAMEWORKS += UIKit

trollvncmanager_CFLAGS += -fobjc-arc
trollvncmanager_CFLAGS += -Iinclude-spi

trollvncmanager_FRAMEWORKS += Foundation
trollvncmanager_FRAMEWORKS += CoreGraphics
trollvncmanager_FRAMEWORKS += CoreImage
trollvncmanager_FRAMEWORKS += CoreMedia
trollvncmanager_FRAMEWORKS += CoreVideo
trollvncmanager_FRAMEWORKS += IOKit
trollvncmanager_FRAMEWORKS += IOSurface
trollvncmanager_FRAMEWORKS += QuartzCore
trollvncmanager_FRAMEWORKS += UserNotifications
trollvncmanager_FRAMEWORKS += CoreLocation
trollvncmanager_FRAMEWORKS += MapKit
trollvncmanager_FRAMEWORKS += Contacts
trollvncmanager_LIBRARIES += sqlite3
ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncmanager_CODESIGN_FLAGS += -f -s - --entitlements src/trollvncmanager.entitlements
else
trollvncmanager_CODESIGN_FLAGS += -Ssrc/trollvncmanager.entitlements
endif
endif

# ===== netdisguise 注入组件（POC，2026-08-26）：蜂窝伪装 dylib + 注入编排 + Mach-O 注入器 =====
LIBRARY_NAME += netdisguise
netdisguise_FILES += netdisguise/netdisguise.c netdisguise/fishhook.c
netdisguise_INSTALL_PATH = /usr/lib
netdisguise_CFLAGS += -fobjc-arc
netdisguise_FRAMEWORKS += Foundation SystemConfiguration Security

TOOL_NAME += injectctl
injectctl_FILES += netdisguise/injectctl.mm
injectctl_CFLAGS += -fobjc-arc
injectctl_FRAMEWORKS += Foundation Security
injectctl_INSTALL_PATH = /usr/bin
# 注入需脱离沙箱写目标 app 容器 + 启动 app（spawn 子进程不继承父进程 profile，须自带）
injectctl_CODESIGN_FLAGS += -Snetdisguise/injectctl.entitlements

TOOL_NAME += insert_dylib
insert_dylib_FILES += netdisguise/insert_dylib/main.c
insert_dylib_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/library.mk

SUBPROJECTS += prefs/TrollVNCPrefs
SUBPROJECTS += prefs/CCTrollVNC

ifeq ($(THEBOOTSTRAP),1)
SUBPROJECTS += app/TrollVNC
endif

include $(THEOS_MAKE_PATH)/aggregate.mk

export THEOS_PACKAGE_SCHEME
export THEOS_STAGING_DIR
before-package::
	@devkit/before-package.sh

export THEOS_STAGING_DIR
after-package::
	@devkit/after-package.sh
