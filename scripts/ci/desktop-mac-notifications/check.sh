#!/bin/bash

# Connects a profile in the desktop app's database to a second profile with the released CLI, starts the built app,
# sends it messages with quotes and backslashes from the second profile, and checks how the app shows them:
# each message is passed to the notification library, no osascript process runs, and Notification Center records
# the notifications under the app's bundle, while a control notification shown through osascript is recorded under
# another app. The screen, the app log and the Notification Center log are saved to the output dir.
# Usage: scripts/ci/desktop-mac-notifications/check.sh <dir with simplex-chat CLI> <output dir> [report]
# With "report", failed checks are listed without failing the job.

set -euo pipefail

cli=$1/simplex-chat
out=$2
mode=${3:-fail}
app=$(find apps/multiplatform/release -maxdepth 4 -name '*.app' -type d | head -1)
data=$HOME/.local/share/simplex
config=$HOME/.config/simplex
peer=$RUNNER_TEMP/peer
checks=$out/checks.txt
messages=(
  'Quotes "double" and '\''single'\'''
  'Backslash \ and quote \" together'
)
mkdir -p "$out" "$data" "$config" "$peer"
: > "$checks"

check() {
  local what=$1
  shift
  if "$@"; then
    echo "PASS $what" | tee -a "$checks"
  else
    echo "FAIL $what" | tee -a "$checks"
  fi
}

info() {
  local what=$1
  shift
  if "$@"; then
    echo "INFO yes: $what" | tee -a "$checks"
  else
    echo "INFO no: $what" | tee -a "$checks"
  fi
}

contact_of() {
  local contacts
  contacts=$("$cli" -d "$1/simplex_v1" -e "/contacts" -t 5 2> /dev/null || true)
  grep -q "$2" <<< "$contacts"
}

echo "app: $app"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")
executable=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Contents/Info.plist")
echo "bundle: $bundle_id, executable: $executable"

"$cli" -d "$data/simplex_v1" --user-display-name ntf_app -e "/c" -t 15 > "$out/app-invitation.log" 2>&1
link=$(awk '/pass this invitation link/ { getline; getline; print $1; exit }' "$out/app-invitation.log")
echo "invitation: ${link:0:40}..."
[ -n "$link" ] || { cat "$out/app-invitation.log"; exit 1; }

"$cli" -d "$data/simplex_v1" -e "/contacts" -t 90 > "$out/app-connect.log" 2>&1 &
app_cli=$!
sleep 5
"$cli" -d "$peer/simplex_v1" --user-display-name ntf_peer -e "/c $link" -t 60 > "$out/peer-connect.log" 2>&1 || true
wait "$app_cli" || true
for attempt in 1 2 3; do
  contact_of "$data" ntf_peer && contact_of "$peer" ntf_app && break
  echo "not connected yet, attempt $attempt"
  "$cli" -d "$data/simplex_v1" -e "/contacts" -t 40 > /dev/null 2>&1 &
  "$cli" -d "$peer/simplex_v1" -e "/contacts" -t 40 > /dev/null 2>&1
  wait
done
check "the CLI profiles are connected" contact_of "$data" ntf_peer

printf 'DeveloperTools=true\nLogLevel=DEBUG\n' > "$config/settings.properties"

: > "$out/osascript.log"
( while true; do pgrep -lf osascript || true; sleep 0.02; done ) >> "$out/osascript.log" 2>&1 &
monitor=$!
osascript -e 'delay 0.5' > /dev/null
check "the process monitor sees osascript" grep -q osascript "$out/osascript.log"
: > "$out/osascript.log"

"$app/Contents/MacOS/$executable" > "$out/app.log" 2>&1 &
app_pid=$!
for _ in $(seq 1 60); do
  grep -q "initChatController" "$out/app.log" && break
  sleep 2
done
sleep 30
screencapture -x "$out/1-started.png" || true

for message in "${messages[@]}"; do
  "$cli" -d "$peer/simplex_v1" -e "@ntf_app $message" -t 15 >> "$out/peer-send.log" 2>&1 || true
done
sleep 20
screencapture -x "$out/2-messages.png" || true
kill "$monitor" 2> /dev/null || true
kill "$app_pid" 2> /dev/null || true
log show --last 10m --style compact --predicate 'process == "usernoted"' > "$out/notification-center.log" 2>&1 || true

control_start=$(date '+%Y-%m-%d %H:%M:%S')
osascript -e 'display notification "control" with title "control"'
sleep 5
log show --start "$control_start" --style compact --predicate 'process == "usernoted"' > "$out/notification-center-control.log" 2>&1 || true

records_of() {
  grep -o 'NotificationRecord app:"[^"]*"' "$1" | sed 's/^NotificationRecord app:"//; s/"$//' | sort | uniq -c || true
}
senders_of() {
  { grep -o 'NotificationRecord app:"[^"]*"' "$1" | sed 's/^NotificationRecord app:"//; s/"$//'; grep -o 'req:"[^"]*"' "$1" | sed 's/^req:"//; s/"$//'; } \
    | grep -v -x -e "$bundle_id" -e 'com.apple.notificationcenter.askpermissions' -e '' | sort -u || true
}
records_of "$out/notification-center.log" | tee "$out/records-app.txt"
records_of "$out/notification-center-control.log" | tee "$out/records-control.txt"
app_records=$(grep -c "NotificationRecord app:\"$bundle_id\"" "$out/notification-center.log" || true)
control_apps=$(senders_of "$out/notification-center-control.log")
echo "control notification recorded under: ${control_apps:-nothing}"

echo "::group::app log"
cat "$out/app.log"
echo "::endgroup::"
grep -n -i -E "twoslices|showing notification|toaster|Exception" "$out/app.log" || true

received=$(grep -c "notifyMessageReceived" "$out/app.log" || true)
echo "notifications passed to the library: $received"
check "each message is passed to the notification library" [ "$received" -ge "${#messages[@]}" ]
check "no osascript process ran while the app was running" [ ! -s "$out/osascript.log" ]
check "the app logged no notification error" bash -c "! grep -q -i -E 'showing notification|twoslices' '$out/app.log'"
check "Notification Center recorded each message under the app's bundle" [ "$app_records" -ge "${#messages[@]}" ]
check "a notification shown through osascript is recorded under another app" [ -n "$control_apps" ]
for control_app in $control_apps; do
  check "nothing was recorded for $control_app while the app was running" bash -c "! grep -q -e 'app:\"$control_app\"' -e 'req:\"$control_app\"' '$out/notification-center.log'"
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Checks"
    echo
    sed 's/^/- /' "$checks"
    echo
    echo "### Notification Center records while the app ran"
    echo
    sed 's/^/    /' "$out/records-app.txt"
    echo
    echo "### Notification Center records of the osascript control"
    echo
    sed 's/^/    /' "$out/records-control.txt"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$mode" != report ] && grep -q '^FAIL' "$checks"; then
  exit 1
fi
