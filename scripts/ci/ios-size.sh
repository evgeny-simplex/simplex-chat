#!/bin/bash

# Archives the iOS app for devices without signing, with the project file of the base commit and of HEAD,
# with SimpleX assets made from assets/multiplatform, and saves the apps, thinned asset catalogs and link maps.
# Usage: scripts/ci/ios-size.sh <base commit> <output dir>

set -euo pipefail

base=$1
mkdir -p "$2"
out="$(cd "$2" && pwd)"
derived="$RUNNER_TEMP/DerivedData-size"
git fetch --depth=1 origin "$base"

art="$RUNNER_TEMP/art/ios/Assets.xcassets"
mkdir -p "$art"
printf '{"info":{"author":"xcode","version":1}}\n' > "$art/Contents.json"
for f in assets/multiplatform/resources/MR/images/*@3x.*; do
  file=$(basename "$f")
  ext=${file##*.}
  mp=${file%@3x.*}
  case "$mp" in
    crowdfunding_*) name=$mp ;;
    *) name=$(echo "$mp" | tr _ -) ;;
  esac
  dir="$art/$name.imageset"
  mkdir -p "$dir"
  cp "assets/multiplatform/resources/MR/images/$mp@2x.$ext" "$dir/$name@2x.$ext"
  cp "$f" "$dir/$name@3x.$ext"
  printf '{"images":[{"filename":"%s@2x.%s","idiom":"universal","scale":"2x"},{"filename":"%s@3x.%s","idiom":"universal","scale":"3x"}],"info":{"author":"xcode","version":1}}\n' "$name" "$ext" "$name" "$ext" > "$dir/Contents.json"
done
ls "$art"
cp -R "$art"/*.imageset apps/ios/Shared/SimpleXAssets.xcassets/

cat > apps/ios/Local.xcconfig <<EOF
SIMPLEX_ASSETS_DIR = $RUNNER_TEMP/art
SWIFT_ACTIVE_COMPILATION_CONDITIONS = \$(inherited) SIMPLEX_ASSETS
EOF
cat apps/ios/Local.xcconfig

pbxproj=apps/ios/SimpleX.xcodeproj/project.pbxproj
api_types=apps/ios/Shared/Model/AppAPITypes.swift

indirect_results() {
  sed -i '' -E 's/^enum (ChatResponse[012]|ChatEvent): Decodable, ChatAPIResult \{$/indirect enum \1: Decodable, ChatAPIResult {/' "$api_types"
  [ "$(grep -c '^indirect enum' "$api_types")" -eq 4 ]
}

archive() {
  local variant=$1
  local commit=$2
  local api=$3
  local se_assets=$4
  git checkout "$commit" -- "$pbxproj"
  git checkout "$base" -- "$api_types"
  if [ "$se_assets" = no ]; then
    sed -i '' '/E5C0BBE92F82B45500EA7527/d' "$pbxproj"
  fi
  if [ "$api" = indirect ]; then
    indirect_results
  fi
  scripts/ios/update-pbxproj.sh
  grep -n 'SWIFT_OPTIMIZATION_LEVEL\|SimpleXAssets.xcassets in Resources' "$pbxproj"
  grep -n 'enum ChatResponse[012]\|enum ChatEvent' "$api_types"
  local start=$SECONDS
  xcodebuild archive -quiet \
    -project apps/ios/SimpleX.xcodeproj \
    -scheme "SimpleX (iOS)" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$out/$variant.xcarchive" \
    -derivedDataPath "$derived" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM= \
    LD_GENERATE_MAP_FILE=YES
  echo "$variant archived in $((SECONDS - start)) s"

  mkdir -p "$out/$variant-maps"
  find "$derived" -name '*LinkMap*.txt' -exec mv {} "$out/$variant-maps/" \;
  gzip -9 "$out/$variant-maps/"*

  local app="$out/$variant.xcarchive/Products/Applications/SimpleX.app"
  echo "== $variant: files over 100 KB"
  find "$app" -type f -size +100k -print0 | xargs -0 du -k | sort -n -r
  echo "== $variant: binaries"
  size -m "$app/SimpleX" "$app/Frameworks/SimpleXChat.framework/SimpleXChat" "$app/Frameworks/WebRTC.framework/WebRTC" "$app/PlugIns/SimpleX NSE.appex/SimpleX NSE" "$app/PlugIns/SimpleX SE.appex/SimpleX SE" | grep -E '^Segment|__text|^total|:$'

  for car in "$app/Assets.car" "$app/PlugIns/SimpleX SE.appex/Assets.car"; do
    local owner
    owner=$(basename "$(dirname "$car")" | tr ' ' '-')
    xcrun assetutil --info "$car" > "$out/$variant-$owner-assets.json"
    xcrun assetutil --idiom phone --subtype 0 --scale 3 --display-gamut srgb --graphicsclass MTL2,2 --graphicsclassfallbacks MTL1,2:GLES2,0 --memory 1 --hostedidioms car,watch "$car" -o "$out/$variant-$owner-thinned-3x.car" || echo "thinning $car failed"
    xcrun assetutil --idiom phone --subtype 0 --scale 2 --display-gamut srgb --graphicsclass MTL2,2 --graphicsclassfallbacks MTL1,2:GLES2,0 --memory 1 --hostedidioms car,watch "$car" -o "$out/$variant-$owner-thinned-2x.car" || echo "thinning $car failed"
  done

  tar -czf "$out/$variant-SimpleX.app.tar.gz" -C "$(dirname "$app")" SimpleX.app
  rm -rf "$out/$variant.xcarchive"
}

archive base "$base" direct yes
archive lean "$base" indirect no
archive full HEAD indirect no
ls -l "$out"
