ARCHS := arm64 arm64e
TARGET := iphone:clang:16.5:14.0

INSTALL_TARGET_PROCESSES := Preferences

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME := TrollVNCPrefs

# TrollVNCPrefs_FILES += DpkgVersion.m
TrollVNCPrefs_FILES += TVNCClientCell.m
TrollVNCPrefs_FILES += TVNCButtonCell.m
TrollVNCPrefs_FILES += TVNCClientListController.m
TrollVNCPrefs_FILES += TVNCListItemsController.m
TrollVNCPrefs_FILES += TVNCRootListController.m
TrollVNCPrefs_FILES += TVNCSegmentCell.m
TrollVNCPrefs_FILES += TVNCSliderCell.m
TrollVNCPrefs_FILES += StripedTextTableViewController.m
TrollVNCPrefs_FILES += ZTSelfSignedCertificate.m
# 2026-08-20：connectGateway（桥接/中继验证网关可达）依赖 TVNCGatewayClient（纯 NSURLSession
# 服务类，symlink 共享 app 源码）；TVNCServiceCoordinator 仅 App 编译（THEBOOTSTRAP 条件编译，
# prefs bundle 无 spawn root 能力——relay 分支退化为 fetchDevices 验证，两端行为对齐）
TrollVNCPrefs_FILES += TVNCGatewayClient.m

TrollVNCPrefs_CFLAGS += -fobjc-arc
TrollVNCPrefs_CFLAGS += -DPACKAGE_VERSION=\"$(PACKAGE_VERSION)\"
TrollVNCPrefs_CFLAGS += -DTHEOS_PACKAGE_SCHEME=\"$(THEOS_PACKAGE_SCHEME)\"
# 跨端契约头（TRAppDomain.h 等）：prefs 域经 -I 引用 src/（TVNC* 与 TVNCUtil.h 不带路径 import，2026-08-28）
TrollVNCPrefs_CFLAGS += -I../../src

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
TrollVNCPrefs_CODESIGN_FLAGS += -f -s -
else
TrollVNCPrefs_CODESIGN_FLAGS += -S
endif

TrollVNCPrefs_FRAMEWORKS += UIKit
TrollVNCPrefs_PRIVATE_FRAMEWORKS += Preferences
TrollVNCPrefs_INSTALL_PATH += /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
