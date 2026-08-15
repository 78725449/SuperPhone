#!/bin/bash

THEOS="$HOME/theos"
if [ ! -d "$THEOS" ]; then
  THEOS="$GITHUB_WORKSPACE/theos"
fi
if [ ! -d "$THEOS" ]; then
  THEOS="$GITHUB_WORKSPACE/theos-roothide"
fi

export THEOS
export THEOS_PACKAGE_SCHEME=
export THEOS_DEVICE_IP=
export THEOS_DEVICE_PORT=
export THEOS_DEVICE_SIMULATOR=1
export THEBOOTSTRAP=1
