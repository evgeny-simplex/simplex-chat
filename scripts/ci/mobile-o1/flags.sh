#!/bin/bash

# Prints the optimisation flags, in their order, of the GHC commands that build the simplexmq and simplex-chat libraries.
# Usage: scripts/ci/mobile-o1/flags.sh cabal|nix

set -euo pipefail

log=$RUNNER_TEMP/build-v2.log

if [ "$1" = cabal ]; then
  cp scripts/cabal.project.local.linux cabal.project.local
  cat >> cabal.project.local << EOF

package simplex-chat
    ghc-options: -O1

package simplexmq
    ghc-options: -O1
EOF
  cat cabal.project.local
  cabal update
  cabal build -v2 --builddir=dist-flags lib:simplex-chat > "$log" 2>&1 || { tail -50 "$log"; exit 1; }
  grep -E 'Building|Installing|simplexmq' "$log" | head -20
  find ~/.cache/cabal/logs ~/.cabal/logs -name 'simplexmq-*.log' 2> /dev/null | tee "$RUNNER_TEMP/simplexmq-logs"
  xargs cat < "$RUNNER_TEMP/simplexmq-logs" >> "$log"
else
  scripts/ci/mobile-o1/verify.sh ee7eb5987f9a9ac276a22539a292c2eb0696080b install-only
  # shellcheck disable=SC1091
  . "$HOME/.nix-profile/etc/profile.d/nix.sh"
  nix build -L --out-link "$RUNNER_TEMP/result" '.#hydraJobs.x86_64-linux."aarch64-android:lib:simplex-chat"' > "$log" 2>&1 || { tail -50 "$log"; exit 1; }
fi

grep -E -- '--make .*-this-unit-id (simplexmq|simplex-chat)-' "$log" | while IFS= read -r line; do
  unit=$(echo "$line" | grep -Eo -- '-this-unit-id [^ ]+' | head -1)
  flags=$(echo "$line" | tr ' ' '\n' | grep -n -E '^-O[0-9]*$' | tr '\n' ' ')
  echo "$unit: $(echo "$line" | wc -w) words; -O flags as word:flag: $flags"
done
