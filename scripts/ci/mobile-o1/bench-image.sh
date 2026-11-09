#!/bin/bash

# Builds simplex-chat-test at -O2, at -O1, and at -O1 with Simplex.Chat.Image at -O2,
# then runs the image tests with each build in three alternating rounds, with RTS statistics.
# Usage: scripts/ci/mobile-o1/bench-image.sh <output dir>

set -euo pipefail

mkdir -p "$1"
out="$(cd "$1" && pwd)"

cp scripts/cabal.project.local.linux cabal.project.local
cabal update

build() {
  local variant=$1
  local start=$SECONDS
  cabal build -j --enable-tests --builddir="dist-$variant" simplex-chat-test
  echo "$variant built in $(((SECONDS - start) / 60)) min"
  find "dist-$variant" -name 'Image.o' -path '*simplex-chat*' -print0 | xargs -0 size | sed "s/^/$variant /"
}

build o2
cat >> cabal.project.local << EOF

package simplex-chat
    ghc-options: -O1

package simplexmq
    ghc-options: -O1
EOF
build o1
sed -i '1i {-# OPTIONS_GHC -O2 #-}' src/Simplex/Chat/Image.hs
head -3 src/Simplex/Chat/Image.hs
build o1i

summary="$out/summary.tsv"
printf 'round\tvariant\tresult\twall_s\tmut_cpu_s\ttotal_cpu_s\n' > "$summary"
for round in 1 2 3 4 5; do
  for variant in o2 o1 o1i; do
    bin=$(find "dist-$variant" -name simplex-chat-test -type f -executable)
    rm -rf tests/tmp
    mkdir -p tests/tmp
    log="$out/image-$variant-$round"
    "$bin" -m "/Image resize/" +RTS -s -RTS > "$log.out" 2> "$log.err" || echo "$variant $round: failures"
    result=$(grep -Eo '[0-9]+ examples?, [0-9]+ failures?' "$log.out" | tail -1 || true)
    wall=$(sed -n 's/^Finished in \([0-9.]*\) seconds.*/\1/p' "$log.out" | tail -1)
    mut=$(sed -n 's/^ *MUT *time *\([0-9.]*\)s.*/\1/p' "$log.err" | tail -1)
    total=$(sed -n 's/^ *Total *time *\([0-9.]*\)s.*/\1/p' "$log.err" | tail -1)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$round" "$variant" "$result" "$wall" "$mut" "$total" | tee -a "$summary"
  done
done

column -t -s $'\t' "$summary"
