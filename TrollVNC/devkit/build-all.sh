#!/bin/bash

set -e

# shellcheck disable=SC1091
source devkit/bootstrap.sh
FINALPACKAGE=1 gmake clean package

# shellcheck disable=SC1091
source devkit/default.sh
FINALPACKAGE=1 gmake clean package

# shellcheck disable=SC1091
source devkit/rootless.sh
FINALPACKAGE=1 gmake clean package

# shellcheck disable=SC1091
source devkit/roothide.sh
FINALPACKAGE=1 gmake clean package
