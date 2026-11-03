#!/bin/bash

# Proves, on a built macOS app, where peer message text goes when notifications are shown.
# two-slices is forced to select its AppleScript backend (OsXToaster) with -Dtwoslices.preferred, the backend
# a Mac with a GNTP server, Growl or notify-send would select, or any Mac where NotificationCenterToaster fails.
# An osascript shim on PATH records every osascript invocation and its arguments, then runs the real osascript.
# A second profile, with the released CLI, sends the running app a plain message and one containing a quote.
#   - master (unfixed): the app runs osascript with the peer text spliced into a "display notification ..." script;
#     the notification does not go through Notification Center. The job proves the problem: peer text reaches the
#     AppleScript interpreter, escaped only by OsXToaster replacing " with \".
#   - branch (fixed): the app sends no osascript; Notification Center records the messages under the app's bundle,
#     where the text is an NSString. The job proves the fix.
# Usage: scripts/ci/desktop-mac-notifications/check.sh <dir with simplex-chat CLI> <output dir> <branch|master>

set -euo pipefail

cli=$1/simplex-chat
out=$2
variant=${3:?pass branch or master}
app=$(find apps/multiplatform/release -maxdepth 4 -name '*.app' -type d | head -1)
data=$HOME/.local/share/simplex
config=$HOME/.config/simplex
peer=$RUNNER_TEMP/peer
checks=$out/checks.txt
shimdir=$out/shim
plain='ntfprobe plain alpha'
breakout='ntfprobe beta \" closes'
messages=("$plain" "$breakout")
mkdir -p "$out" "$data" "$config" "$peer" "$shimdir"
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

contact_of() {
  local contacts
  contacts=$("$cli" -d "$1/simplex_v1" -e "/contacts" -t 5 2> /dev/null || true)
  grep -q "$2" <<< "$contacts"
}

echo "app: $app, variant: $variant"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")
executable=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Contents/Info.plist")
echo "bundle: $bundle_id, executable: $executable"

# osascript shim: records each call, then runs the real osascript so the app behaves normally.
cat > "$shimdir/osascript" <<'SHIM'
#!/bin/bash
{
  echo "=== osascript $(date '+%H:%M:%S.%N') ==="
  for a in "$@"; do printf 'ARG %s\n' "$a"; done
} >> "${OSA_LOG:-/dev/null}"
exec /usr/bin/osascript "$@"
SHIM
chmod +x "$shimdir/osascript"
export PATH="$shimdir:$PATH"
export OSA_LOG="$out/osascript-app.log"
: > "$OSA_LOG"

# the shim records an osascript call, so an empty app log later means the app ran none
osascript -e 'return 1' > /dev/null
check "the osascript shim records osascript calls" grep -q 'osascript' "$OSA_LOG"
: > "$OSA_LOG"

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

: > "$OSA_LOG"
JAVA_TOOL_OPTIONS='-Dtwoslices.preferred=com.sshtools.twoslices.impl.OsXToaster' \
  "$app/Contents/MacOS/$executable" > "$out/app.log" 2>&1 &
app_pid=$!
for _ in $(seq 1 60); do
  grep -q "initChatController" "$out/app.log" && break
  sleep 2
done
sleep 30

for message in "${messages[@]}"; do
  "$cli" -d "$peer/simplex_v1" -e "@ntf_app $message" -t 15 >> "$out/peer-send.log" 2>&1 || true
done
sleep 20
screencapture -x "$out/app-screen.png" || true
kill "$app_pid" 2> /dev/null || true
log show --last 10m --style compact --predicate 'process == "usernoted"' > "$out/notification-center.log" 2>&1 || true

# a control notification shown through osascript: it is recorded under the osascript host, not the app bundle
OSA_LOG="$out/osascript-control.log" osascript -e 'display notification "osa-control" with title "osa-control"' || true

echo "::group::osascript calls while the app ran"
cat "$out/osascript-app.log"
echo "::endgroup::"
echo "::group::app log (tail)"
tail -n 80 "$out/app.log"
echo "::endgroup::"

app_notifications=$(grep -c '^ARG display notification' "$out/osascript-app.log" || true)
plain_in_osa=$(grep -F "$plain" "$out/osascript-app.log" > /dev/null 2>&1 && echo yes || echo no)
breakout_line=$(grep -F 'ntfprobe beta' "$out/osascript-app.log" | head -1 || true)
breakout_closed=$(grep -F 'ntfprobe beta' "$out/osascript-app.log" | grep -F '\\"' > /dev/null 2>&1 && echo yes || echo no)
received=$(grep -c "notifyMessageReceived" "$out/app.log" || true)
app_records=$(grep -c "NotificationRecord app:\"$bundle_id\"" "$out/notification-center.log" || true)

echo "osascript display-notification calls by the app: $app_notifications"
echo "plain message text in the app's osascript calls: $plain_in_osa"
echo "break-out message line: $breakout_line"
echo "break-out closed the AppleScript string: $breakout_closed"
echo "notifyMessageReceived in app log: $received"
echo "Notification Center records under $bundle_id: $app_records"

check "the forced AppleScript backend was in effect (JAVA_TOOL_OPTIONS applied)" grep -q 'twoslices.preferred' "$out/app.log"
check "the app processed both peer messages" [ "$received" -ge "${#messages[@]}" ]

if [ "$variant" = master ]; then
  check "PROBLEM: the app ran osascript with the peer message text spliced into the AppleScript" [ "$plain_in_osa" = yes ]
  check "PROBLEM: the notification did not go through Notification Center" [ "$app_records" -eq 0 ]
  echo "INFO: OsXToaster escapes only \" to \\\" (OsXToaster.java:80-82); the osascript call above shows the peer text in the 'display notification' script the app ran"
else
  check "FIX: the app ran no osascript notification" [ "$app_notifications" -eq 0 ]
  check "FIX: Notification Center recorded the peer messages under the app bundle" [ "$app_records" -ge "${#messages[@]}" ]
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### $variant code — checks"
    echo
    sed 's/^/- /' "$checks"
    echo
    echo "### osascript calls by the app (empty when fixed)"
    echo
    echo '```'
    cat "$out/osascript-app.log"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

grep -q '^FAIL' "$checks" && exit 1 || exit 0
