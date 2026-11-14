#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/../.."

case "${1:-}" in
  badge-web)
    (cd apps/simplex-badge-service/web && npm ci && npm test)
    ;;
  ci-scripts)
    python3 scripts/ci/test_packages_release.py
    ;;
  build-tool)
    python3 -m unittest discover -s scripts/simplex_build -t scripts
    python3 -m pip install --quiet mypy==1.18.2 ruff==0.14.0
    python3 -m mypy --strict --exclude '(^|/)(test_.*|testing)\.py$' scripts/simplex_build
    python3 -m ruff check scripts/simplex-chat-build.py scripts/simplex_build
    ;;
  *)
    echo "usage: $0 badge-web | ci-scripts | build-tool" >&2
    exit 1
    ;;
esac
