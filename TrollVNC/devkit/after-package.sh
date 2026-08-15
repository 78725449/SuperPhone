#!/bin/bash

set -e
if [ -z "$THEBOOTSTRAP" ]; then
    exit 0
fi

cd "$(dirname "$0")"/.. || exit 1

cd "$THEOS_STAGING_DIR"

mv Applications Payload
zip -yqr TrollVNC.tipa Payload
mv Payload Applications

cd -
mv "$THEOS_STAGING_DIR"/TrollVNC.tipa packages/TrollVNC_"$PACKAGE_VERSION".tipa
