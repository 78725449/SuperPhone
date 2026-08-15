#!/bin/bash

THEOS="$HOME/theos-roothide"
if [ ! -d "$THEOS" ]; then
  THEOS="$GITHUB_WORKSPACE/theos-roothide"
fi

export THEOS
export THEOS_PACKAGE_SCHEME=roothide
export THEOS_DEVICE_IP=127.0.0.1
export THEOS_DEVICE_PORT=58422
export THEOS_DEVICE_SIMULATOR=
export THEBOOTSTRAP=1
