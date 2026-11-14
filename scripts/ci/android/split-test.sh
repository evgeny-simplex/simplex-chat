#!/bin/bash

set -euo pipefail

package=chat.simplex.app.dev
activity=chat.simplex.app.MainActivity
abi=arm64-v8a
split=split_config.arm64_v8a.apk
splits="splits=\[base, config\.arm64_v8a\]"
installed_libs=lib/arm64
strings=apps/multiplatform/common/src/commonMain/moko-resources/base/strings.xml
button="Get started"
changed_button="Get started (new base)"
first_screen_secs=300
here=$(cd "$(dirname "$0")" && pwd)
ui=$here/ui

change() {
  sed -i "s|<string name=\"get_started\">$button</string>|<string name=\"get_started\">$changed_button</string>|" "$strings"
  if git diff --quiet -- "$strings"; then
    echo "error: get_started is not \"$button\" in $strings"
    return 1
  fi
  git diff -- "$strings"
}

prepare() {
  local apk=$1 changed=$2 dir=$3 tools version_code key file
  tools=$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -n 1)
  version_code=$("$tools/aapt2" dump badging "$apk" | sed -n "s/^package: .* versionCode='\([0-9]*\)'.*/\1/p")
  "$here/split-apk.sh" "$apk" "$dir/first"
  "$here/split-apk.sh" "$changed" "$dir/second"
  "$here/split-apk.sh" "$apk" "$dir/next" $((version_code + 1))
  if cmp "$dir/first/$split" "$dir/second/$split"; then
    echo "both builds have the same $split"
  fi
  mkdir -p "$dir/other"
  cp "$dir/second/base.apk" "$dir/other/base.apk"
  for key in test other; do
    keytool -genkeypair -keystore "$dir/$key.keystore" -storepass "$key-key" -alias "$key" -keyalg RSA -keysize 2048 -validity 1 -dname "CN=$key"
  done
  for file in "$dir/first/base.apk" "$dir/first/$split" "$dir/second/base.apk" "$dir/next/$split"; do
    "$tools/apksigner" sign --ks "$dir/test.keystore" --ks-pass pass:test-key "$file"
  done
  "$tools/apksigner" sign --ks "$dir/other.keystore" --ks-pass pass:other-key "$dir/other/base.apk"
}

check() {
  local what=$1
  shift
  if "$@"; then
    echo "PASS $what" | tee -a "$UI_OUT/checks.txt"
  else
    echo "FAIL $what" | tee -a "$UI_OUT/checks.txt"
    echo "::error::$what"
  fi
}

not() {
  ! "$@"
}

refused() {
  local expected=$1 output
  shift
  if output=$("$@" 2>&1); then
    echo "$output"
    return 1
  fi
  echo "$output"
  grep -qF "$expected" <<< "$output"
}

code_dir() {
  adb shell pm path "$package" | sed -n 's|^package:\(.*\)/base.apk$|\1|p'
}

record() {
  local name=$1 code
  code=$(code_dir)
  {
    echo "code $code"
    adb shell dumpsys package "$package" | grep -E '^ *(versionCode|versionName|splits|primaryCpuAbi|lastUpdateTime)='
    adb shell "cd $code && for f in *.apk $installed_libs/*; do echo \$(stat -c '%i %s %y' \$f) \$(sha256sum \$f | cut -d ' ' -f 1) \$f; done"
  } | tee "$UI_OUT/$name.txt"
}

recorded() {
  grep -E "$2" "$UI_OUT/$1.txt"
}

start_app() {
  local name=$1 text=$2 deadline=$((SECONDS + first_screen_secs)) pid
  adb logcat -c
  adb shell am start -W -n "$package/$activity"
  until "$ui" find "$text" > /dev/null 2>&1; do
    if "$ui" find "New in" > /dev/null 2>&1; then
      "$ui" click-text OK
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      "$ui" shot "$name-timeout"
      echo "error: \"$text\" is not on screen $first_screen_secs s after the start"
      return 1
    fi
    sleep 1
  done
  "$ui" shot "$name"
  pid=$(adb shell pidof -s "$package")
  adb shell cat "/proc/$pid/maps" | awk '$6 ~ /^\/data\/app\/.*\.so$/ { print $6 }' | sort -u | tee "$UI_OUT/$name-maps.txt"
  adb logcat -d > "$UI_OUT/$name-logcat.txt"
  grep -E 'nativeloader|NativeBridge|libsimplex' "$UI_OUT/$name-logcat.txt" || true
}

summary() {
  {
    echo "### The dev app updated by its base APK"
    echo
    echo "| File | Bytes |"
    echo "|---|---|"
    for file in "$dir/first/base.apk" "$dir/first/$split" "$dir/second/base.apk"; do
      echo "| ${file#"$dir"/} | $(stat -c %s "$file") |"
    done
    echo
    sed 's/^/- /' "$UI_OUT/checks.txt"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

run() {
  local code version_code next lib_sha base_sha
  dir=$1
  export UI_OUT=$2
  mkdir -p "$UI_OUT"
  : > "$UI_OUT/checks.txt"
  trap summary EXIT
  adb root
  adb wait-for-device
  lib_sha=$(unzip -p "$dir/first/$split" "lib/$abi/libsimplex.so" | sha256sum | cut -d ' ' -f 1)
  base_sha=$(sha256sum "$dir/second/base.apk" | cut -d ' ' -f 1)

  adb install-multiple -g "$dir/first/base.apk" "$dir/first/$split"
  record installed
  code=$(code_dir)
  version_code=$(sed -n 's/^ *versionCode=\([0-9]*\) .*/\1/p' "$UI_OUT/installed.txt")
  next=$((version_code + 1))
  check "the first build is installed as base.apk and $split" recorded installed "$splits"
  start_app installed "$button"
  check "the first build shows \"$button\"" "$ui" find "$button"
  check "the first build does not show \"$changed_button\"" not "$ui" find "$changed_button"

  check "a split of version code $next does not install over version code $version_code" \
    refused "Existing version code $version_code inconsistent with $next" adb install-multiple -p "$package" "$dir/next/$split"
  check "a base APK signed with another key does not install" \
    refused "Existing signatures are inconsistent" adb install-multiple -p "$package" "$dir/other/base.apk"
  check "the refused updates keep the installed files" [ "$(code_dir)" = "$code" ]

  adb install-multiple -p "$package" "$dir/second/base.apk"
  record updated
  check "the update keeps version code $version_code" recorded updated "^ *versionCode=$version_code "
  check "the update keeps both APKs" recorded updated "$splits"
  check "the update installed the second build's base APK" recorded updated " $base_sha base\.apk$"
  check "the update kept $split: the same inode, size, time and SHA-256" \
    [ "$(recorded installed " $split\$")" = "$(recorded updated " $split\$")" ]
  check "the second build's base APK has no libsimplex.so" not unzip -Z1 "$dir/second/base.apk" "lib/$abi/libsimplex.so"
  check "libsimplex.so of the update is extracted from the kept split" recorded updated " $lib_sha $installed_libs/libsimplex\.so$"
  start_app updated "$changed_button"
  check "the updated app shows \"$changed_button\"" "$ui" find "$changed_button"
  check "the updated app has the update's libsimplex.so loaded" grep -qx "$(code_dir)/$installed_libs/libsimplex.so" "$UI_OUT/updated-maps.txt"

  if grep -q '^FAIL' "$UI_OUT/checks.txt"; then
    echo "error: $(grep -c '^FAIL' "$UI_OUT/checks.txt") of $(wc -l < "$UI_OUT/checks.txt") checks failed"
    return 1
  fi
  echo "the base APK alone updated the app, which kept the split with the core libraries"
}

case "${1:-}" in
  change) change ;;
  prepare) prepare "$2" "$3" "$4" ;;
  run) run "$2" "$3" ;;
  *)
    echo "usage: $0 change | prepare <apk> <apk with the changed string> <dir> | run <dir> <out dir>"
    exit 1
    ;;
esac
