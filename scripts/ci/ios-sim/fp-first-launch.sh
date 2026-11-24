#!/bin/bash

set -uo pipefail

app=$1
out=$2
bundle_id=chat.simplex.app
cases=${FPX_CASES:-url url-dir url-none service domains}
runtime=${SIM_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-$(xcrun --sdk iphonesimulator --show-sdk-version | tr . -)}
device=${SIM_DEVICE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}
mkdir -p "$out"

fileproviderd_pid() {
  pgrep -f 'RuntimeRoot.*fileproviderd' | tr '\n' ' '
}

base=$(xcrun simctl create fpx-base "$device" "$runtime")
echo "base simulator $base, $device, $runtime"
xcrun simctl boot "$base"
xcrun simctl bootstatus "$base" -b
xcrun simctl shutdown "$base"

for c in $cases; do
  dir=$out/$c
  mkdir -p "$dir"
  info=$dir/case.txt
  udid=$(xcrun simctl clone "$base" "fpx-$c")
  echo "case $c, simulator $udid, $device, $runtime" | tee "$info"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl spawn "$udid" log stream --level debug --style compact --predicate 'subsystem == "chat.simplex.fpx"' > "$dir/fpx.log" 2>&1 &
  fpx_log_pid=$!
  xcrun simctl spawn "$udid" log stream --level debug --style compact --predicate 'eventMessage CONTAINS[c] "simplex" AND NOT (subsystem == "chat.simplex.fpx") AND NOT (process BEGINSWITH "SimpleX")' > "$dir/system.log" 2>&1 &
  sys_log_pid=$!
  sleep 3
  xcrun simctl launch "$udid" com.apple.DocumentsApp > /dev/null
  sleep 5
  xcrun simctl terminate "$udid" com.apple.DocumentsApp 2> /dev/null || true
  echo "fileproviderd before install: $(fileproviderd_pid)" | tee -a "$info"
  echo "install start $(date -u +%H:%M:%S)" | tee -a "$info"
  xcrun simctl install "$udid" "$app"
  echo "install end $(date -u +%H:%M:%S)" | tee -a "$info"
  sleep 5
  echo "fileproviderd at launch: $(fileproviderd_pid)" | tee -a "$info"
  echo "launch $(date -u +%H:%M:%S)" | tee -a "$info"
  xcrun simctl launch "$udid" "$bundle_id" -fpxCase "$c" | tee -a "$info"
  deadline=$((SECONDS + 150))
  until grep -qE "FPX done pid=[0-9]+ caller=app tag=case-end" "$dir/fpx.log"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "timeout: case $c did not end in 150 s" | tee -a "$info"
      break
    fi
    sleep 2
  done
  echo "fileproviderd at the end: $(fileproviderd_pid)" | tee -a "$info"
  ls -la "$(xcrun simctl get_app_container "$udid" "$bundle_id" group.chat.simplex.app)" >> "$info" 2>&1
  sleep 2
  kill "$fpx_log_pid" "$sys_log_pid" 2> /dev/null || true
  xcrun simctl shutdown "$udid"
  xcrun simctl delete "$udid"
done

python3 "$(dirname "$0")/fp-first-launch-report.py" "$out" $cases > "$out/report.md"
cat "$out/report.md"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$out/report.md" >> "$GITHUB_STEP_SUMMARY"
fi
