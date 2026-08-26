#!/bin/bash

set -e

if [ "$THEOS_PACKAGE_SCHEME" = "rootless" ]; then
    /usr/libexec/PlistBuddy -c 'Set :ProgramArguments:0 /var/jb/usr/bin/trollvncserver' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.82flex.trollvnc.plist"
    /usr/libexec/PlistBuddy -c 'Set :StandardOutPath /var/jb/tmp/trollvnc-stdout.log' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.82flex.trollvnc.plist"
    /usr/libexec/PlistBuddy -c 'Set :StandardErrorPath /var/jb/tmp/trollvnc-stderr.log' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.82flex.trollvnc.plist"
fi

if [ -z "$THEBOOTSTRAP" ]; then
    exit 0
fi

# Set version information
GIT_COMMIT_COUNT=$(git rev-list --count HEAD)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GIT_COMMIT_COUNT" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PACKAGE_VERSION" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/Info.plist"

# Collect executables
cp -rp "$THEOS_STAGING_DIR/usr/bin/trollvncserver" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"
cp -rp "$THEOS_STAGING_DIR/usr/bin/trollvncmanager" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"

# Collect bundle resources
cp -rp "$THEOS_STAGING_DIR/Library/PreferenceBundles/TrollVNCPrefs.bundle" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"
rm -f "$THEOS_STAGING_DIR/Applications/TrollVNC.app/TrollVNCPrefs.bundle/TrollVNCPrefs"
cp -rp "$THEOS_STAGING_DIR/usr/share/trollvnc/webclients" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"

# netdisguise 注入组件（POC）：injectctl / insert_dylib / dylib 进 App bundle（与 trollvncserver 同级）
# 注：Theos LIBRARY 产物不进入 staging /usr/lib（装到 Theos 自身 lib 目录），dylib 从编译产物直接取
cp -rp "$THEOS_STAGING_DIR/usr/bin/injectctl" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"
cp -rp "$THEOS_STAGING_DIR/usr/bin/insert_dylib" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"
cp -rp "$THEOS_OBJ_DIR/netdisguise.dylib" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"

# 交叉编译 iOS 版 ldid 并放入 App bundle（仅首次；CI macOS runner 提供 xcrun）
if [ ! -f "$THEOS_STAGING_DIR/Applications/TrollVNC.app/ldid" ]; then
  (cd netdisguise/ldid && xcrun -sdk iphoneos clang++ -arch arm64 -miphoneos-version-min=15.0 -I. -c -std=c++11 -o ldid.o ldid.cpp && xcrun -sdk iphoneos clang++ -arch arm64 -miphoneos-version-min=15.0 -o "$THEOS_STAGING_DIR/Applications/TrollVNC.app/ldid" ldid.o -x c lookup2.c -x c sha1.c)
fi

# Remove unused files
rm -rf "${THEOS_STAGING_DIR:?}/usr"
rm -rf "${THEOS_STAGING_DIR:?}/Library"

# Pseudo code signing
ldid -Sapp/TrollVNC/TrollVNC/TrollVNC.entitlements "$THEOS_STAGING_DIR/Applications/TrollVNC.app"
