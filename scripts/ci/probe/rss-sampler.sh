#!/bin/sh
while :; do
  mem=$(awk '/^MemAvailable:/ {a = $2} /^SwapTotal:/ {t = $2} /^SwapFree:/ {f = $2} END {printf "avail_mb=%d swap_used_mb=%d", a / 1024, (t - f) / 1024}' /proc/meminfo)
  top=$(ps -eo rss=,comm= --sort=-rss | awk 'NR == 1 {printf "top_rss_mb=%d top_comm=%s", $1 / 1024, $2}')
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $mem $top"
  sleep 5
done
