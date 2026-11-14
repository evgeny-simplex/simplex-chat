#!/bin/bash

# Unpacks the core package from build-core.sh where scripts/desktop/build-lib-<os>.sh leaves the libraries,
# and links them as the desktop app's resources, as that script does.
# Usage: scripts/ci/desktop-linux/install-core.sh <core .tar.gz> [linux|mac|windows]

set -euo pipefail

arch=$(uname -m)
case "$arch" in
  aarch64 | arm64) compose_arch=arm64 ;;
  *) compose_arch=x64 ;;
esac
case "${2:-linux}" in
  linux) libs=linux-$arch link=linux-$compose_arch ;;
  mac) libs=mac-${arch/arm64/aarch64} link=macos-$compose_arch ;;
  windows) libs=windows-$arch link=windows-$compose_arch ;;
  *)
    echo "usage: $0 <core .tar.gz> [linux|mac|windows]"
    exit 1
    ;;
esac
libs_dir=apps/multiplatform/common/src/commonMain/cpp/desktop/libs/$libs

mkdir -p "$libs_dir"
tar -C "$libs_dir" -xzf "$1"
ls -la "$libs_dir"

mkdir -p apps/multiplatform/build/links
ln -sfn "../../common/src/commonMain/cpp/desktop/libs/$libs/" "apps/multiplatform/build/links/$link"
ls -la apps/multiplatform/build/links
