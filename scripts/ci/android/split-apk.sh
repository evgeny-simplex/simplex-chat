#!/bin/bash

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <apk> <out dir> [version code of the split]"
  echo "writes the APK without the core libraries as base.apk, and a split APK with them as split_config.<abi>.apk"
  exit 1
fi

apk=$(realpath "$1")
mkdir -p "$2"
out=$(realpath "$2")
tools=$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -n 1)
android_jar=$(ls -d "$ANDROID_HOME"/platforms/android-*/android.jar | sort -V | tail -n 1)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

badging=$("$tools/aapt2" dump badging "$apk")
package=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<< "$badging")
version_code=${3:-$(sed -n "s/^package: .* versionCode='\([0-9]*\)'.*/\1/p" <<< "$badging")}
abi=$(unzip -Z1 "$apk" 'lib/*/libsimplex.so' | cut -d / -f 2)
if [ "$(wc -l <<< "$abi")" -ne 1 ]; then
  echo "error: $1 has libsimplex.so for more than one ABI: $abi"
  exit 1
fi
libs=("lib/$abi/libsimplex.so" "lib/$abi/libsupport.so")
split=config.${abi//-/_}

cp "$apk" "$work/base.apk"
zip -q -d "$work/base.apk" "${libs[@]}"
"$tools/zipalign" -f 4 "$work/base.apk" "$out/base.apk"

cat > "$work/AndroidManifest.xml" << EOF
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="$package" split="$split" android:versionCode="$version_code">
  <application android:hasCode="false" />
</manifest>
EOF
"$tools/aapt2" link -o "$work/manifest.apk" -I "$android_jar" --manifest "$work/AndroidManifest.xml"
mkdir "$work/split"
unzip -q "$work/manifest.apk" AndroidManifest.xml -d "$work/split"
unzip -q "$apk" "${libs[@]}" -d "$work/split"
find "$work/split" -exec touch -t 198101010101 {} +
(cd "$work/split" && zip -q -X -D -r "$work/split.apk" AndroidManifest.xml lib)
"$tools/zipalign" -f 4 "$work/split.apk" "$out/split_$split.apk"

echo "$package $version_code: $(stat -c %s "$apk") bytes split into $out"
stat -c '%s %n' "$out/base.apk" "$out/split_$split.apk"
