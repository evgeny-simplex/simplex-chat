#!/bin/bash

# Builds the desktop core library with scripts/desktop/build-lib-<os>.sh, as build.yml does, and packs its libs directory.
# Usage: scripts/ci/desktop-linux/build-core.sh <output .tar.gz> [linux|mac|windows]

set -euo pipefail

mkdir -p "$(dirname "$1")"
out="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
os=${2:-linux}
arch=$(uname -m)
case "$os" in
  linux) libs=linux-$arch ;;
  mac) libs=mac-${arch/arm64/aarch64} ;;
  windows) libs=windows-$arch ;;
  *)
    echo "usage: $0 <output .tar.gz> [linux|mac|windows]"
    exit 1
    ;;
esac
libs_dir=apps/multiplatform/common/src/commonMain/cpp/desktop/libs/$libs

ghc --version
cabal --version

case "$os" in
  linux)
    cat > cabal.project.local << EOF
ignore-project: False
jobs: \$ncpus

package direct-sqlcipher
    flags: +openssl
EOF
    ;;
  mac)
    openssl_dir=$(brew --prefix openssl@3.0)
    cat > cabal.project.local << EOF
ignore-project: False
jobs: \$ncpus

package simplexmq
    extra-include-dirs: $openssl_dir/include
    extra-lib-dirs: $openssl_dir/lib

package direct-sqlcipher
    extra-include-dirs: $openssl_dir/include
    extra-lib-dirs: $openssl_dir/lib
    flags: +openssl
EOF
    ;;
esac

SKIP_VLC=1 "scripts/desktop/build-lib-$os.sh"

ls -la "$libs_dir"
case "$os" in
  linux)
    readelf -d "$libs_dir/libsimplex.so" | grep -E 'SONAME|RUNPATH|NEEDED'
    echo "Selected symbols defined in libsimplex.so:"
    nm -D --defined-only "$libs_dir/libsimplex.so" | awk '$NF ~ /^(chat_migrate_init_key|chat_send_cmd_retry|chat_recv_msg_wait)$/ {print "  " $NF}'
    ;;
  mac) otool -L "$libs_dir/libsimplex.dylib" ;;
  windows) objdump -p "$libs_dir/libsimplex.dll" | grep 'DLL Name' ;;
esac
du -sh "$libs_dir"

tar -C "$libs_dir" -czf "$out" .
ls -la "$out"
