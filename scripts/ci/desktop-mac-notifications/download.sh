#!/bin/bash

# Downloads the released macOS CLI and desktop app, and puts the app's core libraries where
# scripts/desktop/build-lib-mac.sh leaves them, linked as the desktop app's resources.
# Usage: scripts/ci/desktop-mac-notifications/download.sh <release tag> <output dir>

set -euo pipefail

tag=$1
out=$2
arch=aarch64
base=https://github.com/simplex-chat/simplex-chat/releases/download/$tag
libs_dir=apps/multiplatform/common/src/commonMain/cpp/desktop/libs/mac-$arch

mkdir -p "$out"
curl -fsSL -o "$out/simplex-chat" "$base/simplex-chat-macos-$arch"
chmod +x "$out/simplex-chat"
"$out/simplex-chat" -h | head -3

curl -fsSL -o "$out/app.dmg" "$base/simplex-desktop-macos-$arch.dmg"
yes | hdiutil attach -nobrowse -readonly -noverify -mountpoint "$out/dmg" "$out/app.dmg" > /dev/null
app=$(find "$out/dmg" -maxdepth 1 -name '*.app' | head -1)
find "$app/Contents" -maxdepth 3 -not -path '*/runtime/*' | head -60

mkdir -p "$libs_dir"
find "$app/Contents/app/resources" -maxdepth 1 -name '*.dylib' ! -name 'libapp-lib.dylib' -exec cp {} "$libs_dir/" \;
ls -la "$libs_dir"
hdiutil detach "$out/dmg" > /dev/null

mkdir -p apps/multiplatform/build/links
ln -sfn "../../common/src/commonMain/cpp/desktop/libs/mac-$arch/" apps/multiplatform/build/links/macos-arm64
ls -la apps/multiplatform/build/links
