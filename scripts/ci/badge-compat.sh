#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/../.."
MASTER=abc483d9d0c7f622410eb5513883ab65faa7ef7e
temp=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/badge-compat

usage() {
  echo "usage: $0 client" >&2
  exit 1
}

pinned_tree() {
  git cat-file -e "$MASTER^{commit}" 2>/dev/null || git fetch -q --depth=1 origin "$MASTER"
  mkdir -p "$1"
  git archive "$MASTER" | tar -x -C "$1"
}

in_tree() {
  if docker container inspect builder >/dev/null 2>&1; then
    docker exec -w "$tree" builder "$@"
  else
    (cd "$tree" && "$@")
  fi
}

case "${1:-}" in
  client)
    [ $# -eq 1 ] || usage
    tree=$temp/master
    pinned_tree "$tree"
    cp scripts/ci/badge-compat/Main.hs "$tree/apps/simplex-chat/Main.hs"
    [ ! -f cabal.project.local ] || cp cabal.project.local "$tree/cabal.project.local"
    in_tree cabal build -j --ghc-options=-O0 exe:simplex-chat
    client=$(in_tree cabal list-bin --ghc-options=-O0 exe:simplex-chat | tail -n 1)
    if [ -x simplex-chat-test ]; then
      tests=./simplex-chat-test
    else
      tests=$(cabal list-bin --ghc-options=-O0 simplex-chat-test | tail -n 1)
    fi
    mkdir -p tests/tmp
    MASTER_CLIENT_BIN=$client "$tests" -m "/SimpleX store service e2e/master compatibility/master CLI/"
    ;;
  *)
    usage
    ;;
esac
