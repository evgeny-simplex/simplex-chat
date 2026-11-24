#!/bin/bash

set -uo pipefail

app=$1
export UI_OUT=$2
bundle_id=chat.simplex.app
fp_id=chat.simplex.app.SimpleX-FP
fp_exec="SimpleX FP.appex/SimpleX FP"
ui=$(dirname "$0")/ui
fixtures=$(cd "$(dirname "$0")/../../../tests/fixtures" && pwd)
mkdir -p "$UI_OUT"
steps=$UI_OUT/steps.txt
log=$UI_OUT/fpx.log
: > "$steps"

note() {
  echo "$*" | tee -a "$steps"
}

step() {
  note ""
  note "## $1 ($(date -u +%H:%M:%S))"
}

count_done() {
  grep -cE "FPX done pid=[0-9]+ caller=$1 tag=$2( |$)" "$log" || true
}

await_done() {
  local deadline=$((SECONDS + $4))
  until [ "$(count_done "$1" "$2")" -gt "$3" ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      note "timeout: no result of $1 $2 in $4 s"
      return 1
    fi
    sleep 1
  done
}

app_cmd() {
  local dir
  dir=$(xcrun simctl get_app_container "$SIM_UDID" "$bundle_id" group.chat.simplex.app)
  printf '%s\n' "$*" > "$dir/fpx-cmd.tmp"
  mv "$dir/fpx-cmd.tmp" "$dir/fpx-cmd"
}

run_app_cmd() {
  local tag=$1 secs=$2 n
  shift 2
  n=$(count_done app "$tag")
  app_cmd "$tag" "$@"
  await_done app "$tag" "$n" "$secs"
}

push() {
  local tag=$1 secs=$2 n f=$UI_OUT/push-$1.json
  printf '{"aps":{"alert":{"title":"FPX","body":"probe %s"},"mutable-content":1},"fpx":"%s"}\n' "$tag" "$tag" > "$f"
  n=$(count_done nse "$tag")
  xcrun simctl push "$SIM_UDID" "$bundle_id" "$f"
  await_done nse "$tag" "$n" "$secs"
}

fp_pids() {
  pgrep -f "$fp_exec" | tr '\n' ' '
}

fp_pid() {
  pgrep -n -f "$fp_exec"
}

fp_ps() {
  local pid
  pid=$(fp_pid) || { note "extension process: none"; return; }
  note "extension process: $(ps -o pid=,lstart=,etime=,stat=,rss= -p "$pid")"
}

app_pid() {
  pgrep -n -f "SimpleX.app/SimpleX$"
}

background_case() {
  local name=$1 mode=$2 before after kills
  run_app_cmd "$name" 30 "$mode" root 5
  before=$(app_pid)
  kills=$(grep -c "Terminating with context" "$UI_OUT/system.log" || true)
  xcrun simctl launch "$SIM_UDID" com.apple.Preferences > /dev/null
  sleep 75
  after=$(app_pid || true)
  note "$name ($mode): app pid before $before, after 75 s in background ${after:-none}, new RunningBoard terminations: $(($(grep -c "Terminating with context" "$UI_OUT/system.log" || true) - kills))"
  xcrun simctl terminate "$SIM_UDID" com.apple.Preferences 2> /dev/null || true
  xcrun simctl launch "$SIM_UDID" "$bundle_id" > /dev/null
  sleep 4
  if [ "$mode" = hold ]; then
    run_app_cmd "$name-held" 15 held - 3
  fi
}

allow_notifications() {
  local deadline=$((SECONDS + 30)) element
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$ui" tap Allow 1 > /dev/null 2>&1; then
      note "notifications allowed"
      return
    fi
    element=$("$ui" point 275 518 2> /dev/null || true)
    if grep -qF '"Allow"' <<< "$element"; then
      "$ui" tap-xy 275 518
      note "notifications allowed at the alert's place"
      return
    fi
    sleep 2
  done
  note "no notifications alert"
}

dismiss_system_sheets() {
  local i
  for i in 1 2 3; do
    "$ui" tap Continue 2 > /dev/null 2>&1 && note "tapped Continue"
    "$ui" tap "Don’t Allow" 2 > /dev/null 2>&1 && note "tapped Don’t Allow"
    "$ui" tap "Not Now" 1 > /dev/null 2>&1 && note "tapped Not Now"
  done
}

element_center() {
  local line=$1 x y w h
  read -r x y w h < <(sed -E 's/.* at (-?[0-9]+),(-?[0-9]+) size ([0-9]+)x([0-9]+).*/\1 \2 \3 \4/' <<< "$line")
  echo "$((x + w / 2)) $((y + h / 2))"
}

tap_line() {
  local cx cy
  read -r cx cy < <(element_center "$1")
  "$ui" tap-xy "$cx" "$cy"
}

open_share_extension() {
  local line cx cy i
  for i in 1 2 3 4 5; do
    line=$("$ui" tree | grep -F 'SimpleX' | grep -vF 'value="SimpleX' | grep -vF 'Return to SimpleX' | head -n 1)
    if [ -n "$line" ]; then
      read -r cx cy < <(element_center "$line")
      if [ "$cx" -gt 0 ] && [ "$cx" -lt 400 ]; then
        note "share sheet entry: $line"
        "$ui" tap-xy "$cx" "$cy"
        return 0
      fi
      note "share sheet entry off screen: $line"
      "$ui" swipe 350 "$cy" 60 "$cy"
    elif [ "$i" -eq 1 ] && line=$("$ui" tree | grep -E '^Button "Activity" ' | sed -n 2p) && [ -n "$line" ]; then
      note "share sheet entry without a label, the second app: $line"
      tap_line "$line"
      return 0
    elif [ "$i" -le 2 ]; then
      "$ui" swipe 350 600 60 600
    elif [ "$i" -eq 3 ]; then
      "$ui" tap More 3 > /dev/null 2>&1 || "$ui" tap "Edit Actions…" 3 > /dev/null 2>&1 || true
    else
      "$ui" swipe 200 700 200 300
    fi
    sleep 1
    "$ui" shot "share-sheet-$i"
  done
  return 1
}

finish() {
  "$ui" shot final > /dev/null 2>&1 || true
  kill "$fpx_log_pid" "$sys_log_pid" "$app_log_pid" 2> /dev/null || true
  find ~/Library/Logs/DiagnosticReports \( -name '*SimpleX*' -o -name '*Tests iOS*' \) -newer "$app" 2> /dev/null | while read -r report; do
    cp "$report" "$UI_OUT/"
  done
  python3 "$(dirname "$0")/fp-report.py" "$log" "$UI_OUT/system.log" "$steps" > "$UI_OUT/report.md"
  cat "$UI_OUT/report.md"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "$UI_OUT/report.md" >> "$GITHUB_STEP_SUMMARY"
  fi
}
trap finish EXIT

axe --version
runtime=${SIM_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-$(xcrun --sdk iphonesimulator --show-sdk-version | tr . -)}
device=${SIM_DEVICE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}
SIM_UDID=$(xcrun simctl create fpx-iphone "$device" "$runtime")
export SIM_UDID
note "simulator $SIM_UDID, $device, $runtime"
xcrun simctl boot "$SIM_UDID"
xcrun simctl bootstatus "$SIM_UDID" -b
open -a Simulator --args -CurrentDeviceUDID "$SIM_UDID"

xcrun simctl spawn "$SIM_UDID" log stream --level debug --style compact --predicate 'subsystem == "chat.simplex.fpx"' > "$log" 2>&1 &
fpx_log_pid=$!
xcrun simctl spawn "$SIM_UDID" log stream --level debug --style compact --predicate 'eventMessage CONTAINS[c] "simplex" AND NOT (subsystem == "chat.simplex.fpx") AND NOT (process BEGINSWITH "SimpleX")' > "$UI_OUT/system.log" 2>&1 &
sys_log_pid=$!
xcrun simctl spawn "$SIM_UDID" log stream --level debug --style compact --predicate 'process BEGINSWITH "SimpleX" AND NOT (subsystem == "chat.simplex.fpx")' > "$UI_OUT/processes.log" 2>&1 &
app_log_pid=$!
sleep 3

step "install"
xcrun simctl install "$SIM_UDID" "$app"
xcrun simctl spawn "$SIM_UDID" pluginkit -m -A -D -v -p com.apple.fileprovider-nonui > "$UI_OUT/pluginkit.txt" 2>&1
note "pluginkit file providers:"
tee -a "$steps" < "$UI_OUT/pluginkit.txt"
fp_ps

step "app launch, first calls after install"
n=$(count_done app launch)
xcrun simctl launch "$SIM_UDID" "$bundle_id"
allow_notifications
await_done app launch "$n" 60
"$ui" shot app-launched
fp_ps
run_app_cmd hold1 90 hold root 60
fp_ps

step "app warm calls"
run_app_cmd burst1 120 burst 20 5
fp_ps

step "nse by simctl push"
push fg 20
"$ui" shot nse-fg

step "app in background without and with a held connection"
background_case bg-a1 release
background_case bg-b1 hold
background_case bg-a2 release
background_case bg-b2 hold
fp_ps

step "share extension while the app holds a connection in background"
run_app_cmd hold2 30 hold root 5
xcrun simctl addmedia "$SIM_UDID" "$fixtures/test.jpg"
xcrun simctl launch "$SIM_UDID" com.apple.mobileslideshow
sleep 6
dismiss_system_sheets
sleep 2
"$ui" shot photos
photo=$("$ui" tree | grep -E '^(Image|Cell|Button|GenericElement) "(Photo|Image|Screenshot|Live Photo)' | head -n 1)
if [ -n "$photo" ]; then
  note "photo: $photo"
  tap_line "$photo"
else
  note "no photo label in the tree, tapping the first grid cell"
  "$ui" tap-xy 66 200
fi
sleep 3
"$ui" shot photo-open
note "app in background since Photos started; waiting 30 s"
sleep 30
n=$(count_done se share)
if "$ui" tap Share 10; then
  sleep 3
  "$ui" shot share-sheet
  if open_share_extension; then
    await_done se share "$n" 40
    sleep 2
    "$ui" shot share-extension
  else
    note "share extension: not found in the share sheet"
  fi
else
  note "share button: not found"
fi
xcrun simctl terminate "$SIM_UDID" com.apple.mobileslideshow 2> /dev/null || true

step "Files app"
xcrun simctl launch "$SIM_UDID" com.apple.DocumentsApp
sleep 6
dismiss_system_sheets
"$ui" shot files
"$ui" tap Browse 5 > /dev/null 2>&1 || true
sleep 3
dismiss_system_sheets
back=$("$ui" tree | grep -E '^Button "(Browse|Back)" ' | head -n 1)
if [ -n "$back" ]; then
  read -r cx cy < <(element_center "$back")
  if [ "$cy" -lt 200 ]; then
    note "back to the locations: $back"
    "$ui" tap-xy "$cx" "$cy"
    sleep 3
  fi
fi
"$ui" shot files-browse
note "Files, Browse, elements with SimpleX: $("$ui" tree | grep -cF SimpleX)"
"$ui" tree | grep -E 'SimpleX|Switch|Locations|On My|iCloud|Recently' | tee -a "$steps"
if "$ui" tap More 3 > /dev/null 2>&1; then
  sleep 1
  "$ui" shot files-more
fi
"$ui" tap Edit 3 > /dev/null 2>&1 || "$ui" tap "Edit Sidebar" 3 > /dev/null 2>&1 || true
sleep 2
"$ui" shot files-edit
note "Files, edit mode, elements with SimpleX: $("$ui" tree | grep -cF SimpleX)"
"$ui" tree | grep -E 'SimpleX|Switch' | tee -a "$steps"
"$ui" tap Done 3 > /dev/null 2>&1 || true
sleep 1
location=$("$ui" tree | grep -F '"SimpleX' | head -n 1)
if [ -n "$location" ]; then
  tap_line "$location"
  sleep 3
  "$ui" shot files-simplex
fi
xcrun simctl terminate "$SIM_UDID" com.apple.DocumentsApp 2> /dev/null || true

step "app back in foreground, call over the held connection"
xcrun simctl launch "$SIM_UDID" "$bundle_id"
sleep 3
"$ui" shot app-foreground
run_app_cmd held1 20 held - 5
run_app_cmd after-bg 30 probe root 5
fp_ps

step "crash call"
note "before: $(fp_pids)"
run_app_cmd crash1 30 crash
sleep 2
note "after crash: $(fp_pids)"
run_app_cmd crash2 30 probe root 5
note "after the next call: $(fp_pids)"
run_app_cmd hold3 30 hold root 5

step "extension killed"
pid=$(fp_pid)
kill -9 "$pid"
note "killed $pid"
sleep 1
run_app_cmd held2 20 held - 3
run_app_cmd kill1 30 probe root 5
note "after the next call: $(fp_pids)"
run_app_cmd hold4 30 hold root 5

step "extension stopped"
pid=$(fp_pid)
kill -STOP "$pid"
note "stopped $pid: $(ps -o stat= -p "$pid")"
run_app_cmd held3 20 held - 3
run_app_cmd stop1 30 probe root 5
note "during stop: $(fp_pids)"
kill -CONT "$pid"
note "continued $pid"
sleep 3
run_app_cmd stop2 30 probe root 5
note "after continue: $(fp_pids)"

step "extension disabled with pluginkit"
xcrun simctl spawn "$SIM_UDID" pluginkit -e ignore -i "$fp_id" 2>&1 | tee -a "$steps"
xcrun simctl spawn "$SIM_UDID" pluginkit -m -A -D -v -i "$fp_id" 2>&1 | tee -a "$steps"
pid=$(fp_pid) && kill -9 "$pid" && note "killed $pid"
sleep 1
run_app_cmd disabled1 30 probe root 5
note "while disabled: $(fp_pids)"
xcrun simctl spawn "$SIM_UDID" pluginkit -e use -i "$fp_id" 2>&1 | tee -a "$steps"
sleep 2
run_app_cmd enabled1 30 probe all 5
run_app_cmd hold5 30 hold root 5

step "idle with the app holding a connection in foreground"
pid=$(fp_pid)
note "extension $pid"
for i in $(seq 1 6); do
  sleep 20
  if ! ps -o pid=,etime=,stat=,rss= -p "$pid" >> "$UI_OUT/idle.txt"; then
    note "extension $pid exited after about $((i * 20)) s idle"
    break
  fi
done
fp_ps
run_app_cmd held4 20 held - 3
run_app_cmd idle1 30 probe root 5

step "idle without the app"
xcrun simctl terminate "$SIM_UDID" "$bundle_id"
pid=$(fp_pid)
note "extension $pid"
for i in $(seq 1 12); do
  sleep 20
  if ! ps -o pid=,etime=,stat=,rss= -p "$pid" >> "$UI_OUT/idle.txt"; then
    note "extension $pid exited after about $((i * 20)) s without the app"
    break
  fi
done
fp_ps
n=$(count_done app launch)
xcrun simctl launch "$SIM_UDID" "$bundle_id"
await_done app launch "$n" 60
fp_ps

step "process outside SimpleX"
root="$(xcrun simctl get_app_container "$SIM_UDID" "$bundle_id" group.chat.simplex.app)/File Provider Storage"
xcode=(
  -project apps/ios/SimpleX.xcodeproj
  -scheme "SimpleX (iOS)"
  -configuration Debug
  -destination "id=$SIM_UDID"
  -derivedDataPath "$FPX_DERIVED"
  -onlyUsePackageVersionsFromResolvedFile
  -skipPackagePluginValidation
  -skipMacroValidation
  -only-testing:"Tests iOS/FPForeignTests/testForeignLookup"
  ARCHS=arm64
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY=-
  DEVELOPMENT_TEAM=
  PROVISIONING_PROFILE_SPECIFIER=
)
xcodebuild build-for-testing -quiet "${xcode[@]}" > "$UI_OUT/foreign-build.log" 2>&1 || note "foreign process: build failed"
TEST_RUNNER_FPX_ROOT="$root" xcodebuild test-without-building "${xcode[@]}" > "$UI_OUT/foreign-test.log" 2>&1 || note "foreign process: test run failed"
grep -F "FPX foreign" "$log" | tee -a "$steps"

step "end"
grep -q "FPX result" "$log" || exit 1
