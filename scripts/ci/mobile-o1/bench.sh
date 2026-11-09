#!/bin/bash

# Builds simplex-chat-test with simplex-chat and simplexmq at the -O2 of their cabal files and at -O1,
# then runs CPU-heavy and message-heavy test groups with each build in three alternating rounds, with RTS statistics.
# Usage: scripts/ci/mobile-o1/bench.sh <output dir>

set -euo pipefail

mkdir -p "$1"
out="$(cd "$1" && pwd)"

ghc --version
cabal --version
nproc
cp scripts/cabal.project.local.linux cabal.project.local
cabal update

build() {
  local variant=$1
  local start=$SECONDS
  cabal build -j --enable-tests --builddir="dist-$variant" simplex-chat-test
  echo "$variant built in $(((SECONDS - start) / 60)) min"
  find "dist-$variant" -name 'libHSsimplex*.a' ! -name '*-ghc*' -print0 | xargs -0 size -t | tail -1 | sed "s/^/$variant library code: /"
  find "dist-$variant" -name 'libHSsimplex*.a' ! -name '*-ghc*' -print0 | xargs -0 ls -l
}

build o2
cat >> cabal.project.local << EOF

package simplex-chat
    ghc-options: -O1

package simplexmq
    ghc-options: -O1
EOF
build o1

bin_o2=$(find dist-o2 -name simplex-chat-test -type f -executable)
bin_o1=$(find dist-o1 -name simplex-chat-test -type f -executable)
echo "o2: $bin_o2"
echo "o1: $bin_o1"

summary="$out/summary.tsv"
printf 'round\tvariant\tgroup\tresult\twall_s\tmut_cpu_s\tgc_cpu_s\ttotal_cpu_s\n' > "$summary"

run() {
  local round=$1
  local variant=$2
  local bin=$3
  local group=$4
  shift 4
  local args=()
  for p in "$@"; do args+=(-m "$p"); done
  local log="$out/$group-$variant-$round"
  rm -rf tests/tmp
  mkdir -p tests/tmp
  "$bin" "${args[@]}" +RTS -s -RTS > "$log.out" 2> "$log.err" || echo "$group $variant $round: failures"
  local result wall mut gc total
  result=$(grep -Eo '[0-9]+ examples?, [0-9]+ failures?' "$log.out" | tail -1 || true)
  wall=$(sed -n 's/^Finished in \([0-9.]*\) seconds.*/\1/p' "$log.out" | tail -1)
  mut=$(sed -n 's/^ *MUT *time *\([0-9.]*\)s.*/\1/p' "$log.err" | tail -1)
  gc=$(sed -n 's/^ *GC *time *\([0-9.]*\)s.*/\1/p' "$log.err" | tail -1)
  total=$(sed -n 's/^ *Total *time *\([0-9.]*\)s.*/\1/p' "$log.err" | tail -1)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$round" "$variant" "$group" "$result" "$wall" "$mut" "$gc" "$total" | tee -a "$summary"
}

groups() {
  local round=$1
  local variant=$2
  local bin=$3
  run "$round" "$variant" "$bin" image "/Image resize/"
  run "$round" "$variant" "$bin" encoding "/JSON Tests/" "/SimpleX chat protocol/" "/Message batching/" "/SimpleX chat markdown/"
  run "$round" "$variant" "$bin" messages "many chat batches" "send large message" "forward batched messages" "number of recipients"
}

groups 1 o2 "$bin_o2"
groups 1 o1 "$bin_o1"
groups 2 o1 "$bin_o1"
groups 2 o2 "$bin_o2"
groups 3 o2 "$bin_o2"
groups 3 o1 "$bin_o1"

column -t -s $'\t' "$summary"
