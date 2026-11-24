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
  for i in 1 2 3 4; do
    line=$("$ui" tree | grep -F 'SimpleX' | grep -vF 'value="SimpleX' | head -n 1)
    if [ -n "$line" ]; then
      read -r cx cy < <(element_center "$line")
      if [ "$cx" -gt 0 ] && [ "$cx" -lt 400 ]; then
        note "share sheet entry: $line"
        "$ui" tap-xy "$cx" "$cy"
        return 0
      fi
      note "share sheet entry off screen: $line"
      "$ui" swipe 350 "$cy" 60 "$cy"
    elif [ "$i" -eq 1 ] || [ "$i" -eq 3 ]; then
      "$ui" swipe 350 560 60 560
    else
      "$ui" tap More 3 > /dev/null 2>&1 || true
    fi
    "$ui" shot "share-sheet-$i"
  done
  return 1
}

finish() {
  "$ui" shot final > /dev/null 2>&1 || true
  kill "$fpx_log_pid" "$sys_log_pid" "$app_log_pid" 2> /dev/null || true
  find ~/Library/Logs/DiagnosticReports -name '*SimpleX*' -newer "$app" 2> /dev/null | while read -r report; do
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
runtime=com.apple.CoreSimulator.SimRuntime.iOS-$(xcrun --sdk iphonesimulator --show-sdk-version | tr . -)
SIM_UDID=$(xcrun simctl create fpx-iphone com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$runtime")
export SIM_UDID
note "simulator $SIM_UDID, runtime $runtime"
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

step "app launch"
n=$(count_done app launch)
xcrun simctl launch "$SIM_UDID" "$bundle_id"
allow_notifications
await_done app launch "$n" 60
"$ui" shot app-launched
fp_ps
note "extension processes: $(fp_pids)"

step "app warm calls"
run_app_cmd burst1 120 burst 20 5
fp_ps

step "nse, app in foreground"
push fg 40
"$ui" shot nse-fg

step "share extension, opened from Photos"
xcrun simctl addmedia "$SIM_UDID" "$fixtures/test.jpg"
xcrun simctl launch "$SIM_UDID" com.apple.mobileslideshow
sleep 6
"$ui" shot photos
"$ui" tap Continue 3 > /dev/null 2>&1 || true
"$ui" tap "Not Now" 2 > /dev/null 2>&1 || true
photo=$("$ui" tree | grep -E '"Photo, |"Photo"|"Image, ' | head -n 1)
if [ -n "$photo" ]; then
  note "photo: $photo"
  tap_line "$photo"
else
  note "no photo label in the tree, tapping the grid"
  "$ui" tap-xy 60 300
fi
sleep 3
"$ui" shot photo-open
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
"$ui" shot files
"$ui" tap Continue 3 > /dev/null 2>&1 || true
"$ui" tap Browse 5 > /dev/null 2>&1 || true
sleep 2
"$ui" shot files-browse
note "Files, Browse, elements with SimpleX: $("$ui" tree | grep -cF SimpleX)"
"$ui" tree | grep -F SimpleX | tee -a "$steps"
if "$ui" tap More 3 > /dev/null 2>&1; then
  sleep 1
  "$ui" shot files-more
fi
"$ui" tap Edit 3 > /dev/null 2>&1 || "$ui" tap "Edit Sidebar" 3 > /dev/null 2>&1 || true
sleep 2
"$ui" shot files-edit
note "Files, edit mode, elements with SimpleX: $("$ui" tree | grep -cF SimpleX)"
"$ui" tree | grep -F SimpleX | tee -a "$steps"
"$ui" tap Done 3 > /dev/null 2>&1 || true
sleep 1
location=$("$ui" tree | grep -F '"SimpleX' | head -n 1)
if [ -n "$location" ]; then
  tap_line "$location"
  sleep 3
  "$ui" shot files-simplex
fi

step "nse, app in background"
push bg 40
"$ui" shot nse-bg
xcrun simctl terminate "$SIM_UDID" com.apple.DocumentsApp 2> /dev/null || true

step "nse, app terminated"
xcrun simctl terminate "$SIM_UDID" "$bundle_id"
sleep 2
push term 40

step "app relaunch"
n=$(count_done app launch)
xcrun simctl launch "$SIM_UDID" "$bundle_id"
await_done app launch "$n" 60
fp_ps

step "nse while the app holds a connection in foreground"
push fg2 40
sleep 2

step "crash call"
note "before: $(fp_pids)"
run_app_cmd crash1 30 crash
sleep 2
note "after crash: $(fp_pids)"
run_app_cmd crash2 30 probe root 5
note "after the next call: $(fp_pids)"
run_app_cmd hold2 30 hold root 5

step "extension killed"
pid=$(fp_pid)
kill -9 "$pid"
note "killed $pid"
sleep 1
run_app_cmd kill1 30 probe root 5
note "after the next call: $(fp_pids)"
push killed 40
run_app_cmd hold3 30 hold root 5

step "extension stopped"
pid=$(fp_pid)
kill -STOP "$pid"
note "stopped $pid: $(ps -o stat= -p "$pid")"
run_app_cmd stop1 30 probe root 5
note "during stop: $(fp_pids)"
push stopped 40
kill -CONT "$pid"
note "continued $pid"
sleep 3
run_app_cmd stop2 30 probe root 5
note "after continue: $(fp_pids)"

step "extension disabled"
xcrun simctl spawn "$SIM_UDID" pluginkit -e ignore -i "$fp_id" 2>&1 | tee -a "$steps"
xcrun simctl spawn "$SIM_UDID" pluginkit -m -A -D -v -i "$fp_id" 2>&1 | tee -a "$steps"
pid=$(fp_pid) && kill -9 "$pid" && note "killed $pid"
sleep 1
run_app_cmd disabled1 30 probe root 5
note "while disabled: $(fp_pids)"
push disabled 40
xcrun simctl spawn "$SIM_UDID" pluginkit -e use -i "$fp_id" 2>&1 | tee -a "$steps"
xcrun simctl spawn "$SIM_UDID" pluginkit -m -A -D -v -i "$fp_id" 2>&1 | tee -a "$steps"
sleep 2
run_app_cmd enabled1 30 probe all 5
run_app_cmd hold4 30 hold root 5

step "idle with the app holding a connection"
pid=$(fp_pid)
note "extension $pid"
for i in $(seq 1 12); do
  sleep 20
  if ! ps -o pid=,etime=,stat=,rss= -p "$pid" >> "$UI_OUT/idle.txt"; then
    note "extension $pid exited after about $((i * 20)) s idle"
    break
  fi
done
fp_ps
run_app_cmd idle1 30 probe root 5

step "idle without the app"
xcrun simctl terminate "$SIM_UDID" "$bundle_id"
pid=$(fp_pid)
note "extension $pid"
for i in $(seq 1 15); do
  sleep 20
  if ! ps -o pid=,etime=,stat=,rss= -p "$pid" >> "$UI_OUT/idle.txt"; then
    note "extension $pid exited after about $((i * 20)) s without the app"
    break
  fi
done
fp_ps
push idle 40
n=$(count_done app launch)
xcrun simctl launch "$SIM_UDID" "$bundle_id"
await_done app launch "$n" 60
fp_ps

step "end"
grep -q "FPX result" "$log" || exit 1
