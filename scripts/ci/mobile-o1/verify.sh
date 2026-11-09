#!/bin/bash

# Evaluates the Hydra jobs of HEAD and of the base commit: prints whether each derivation changed,
# and the Setup build commands of the simplex-chat and simplexmq libraries in each job.
# Usage: scripts/ci/mobile-o1/verify.sh <base commit>

set -uo pipefail

base=$1
nix_ver=nix-2.22.0
nix_hash=4fed7db867186c01ce2a2077da4a6950ed16232efbf78d0cd19700cff80559f9

tmp=$(mktemp -d)
sudo mkdir -p /nix
sudo chown "$USER" /nix
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
curl --proto '=https' --tlsv1.2 -sSf -o "$tmp/install" "https://releases.nixos.org/nix/$nix_ver/install"
echo "$nix_hash  $tmp/install" | sha256sum -c || exit 1
mkdir -p ~/.config/nix
cat > ~/.config/nix/nix.conf << EOF
sandbox = true
max-jobs = auto
cores = 0
experimental-features = nix-command flakes
substituters = https://cache.nixos.org https://cache.zw3rk.com https://cache.iog.io
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= loony-tools:pr9m4BkM/5/eSTZlkQyRt57Jz7OMBxNSUiMC4FkcNfk= hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=
EOF
sh "$tmp/install" --no-daemon
# shellcheck disable=SC1091
. "$HOME/.nix-profile/etc/profile.d/nix.sh"
nix --version

git clone --quiet "$PWD" "$RUNNER_TEMP/base"
git -C "$RUNNER_TEMP/base" checkout --quiet "$base"
head_dir=$PWD
base_dir=$RUNNER_TEMP/base

if [ "${2:-}" = android-size ]; then
  for variant in base head; do
    if [ "$variant" = base ]; then dir=$base_dir; else dir=$head_dir; fi
    started=$SECONDS
    nix build --out-link "$RUNNER_TEMP/result-$variant" "$dir#hydraJobs.x86_64-linux.\"aarch64-android:lib:simplex-chat\"" || exit 1
    echo "$variant built in $(((SECONDS - started) / 60)) min"
    mkdir -p "$RUNNER_TEMP/$variant"
    unzip -o -q "$RUNNER_TEMP/result-$variant"/pkg-*.zip -d "$RUNNER_TEMP/$variant"
    ls -l "$RUNNER_TEMP/$variant"
    size -A "$RUNNER_TEMP/$variant/libsimplex.so" | grep -E '^\.text|^\.rodata|^\.data|^Total'
    echo "$variant libsimplex.so gzip -9: $(gzip -9 -c "$RUNNER_TEMP/$variant/libsimplex.so" | wc -c)"
  done
  exit 0
fi

drv_path() {
  timeout 45m nix eval --raw "$1#hydraJobs.$2.\"$3\".drvPath" 2> "$tmp/eval.log" || { tail -5 "$tmp/eval.log" >&2; return 1; }
}

build_lines() {
  nix derivation show -r "$1" \
    | jq -r 'to_entries[] | .value.env | select((.name // "") | test("^(simplex-chat|simplexmq)-lib-")) | "    \(.name): \(.buildPhase // "" | split("\n") | map(select(test("SETUP_HS build"))) | map(gsub("^ +"; "")) | join(" / "))"'
}

check() {
  local system=$1
  local job=$2
  local head_drv base_drv
  echo "::group::$system $job"
  started=$SECONDS
  head_drv=$(drv_path "$head_dir" "$system" "$job")
  base_drv=$(drv_path "$base_dir" "$system" "$job")
  echo "::endgroup::"
  if [ -z "$head_drv" ] || [ -z "$base_drv" ]; then
    echo "RESULT $system $job: not evaluated ($((SECONDS - started)) s)"
    return
  fi
  if [ "$head_drv" = "$base_drv" ]; then
    echo "RESULT $system $job: unchanged $head_drv"
  else
    echo "RESULT $system $job: changed $base_drv -> $head_drv"
  fi
  echo "  HEAD:"
  build_lines "$head_drv"
  echo "  base:"
  build_lines "$base_drv"
}

for job in "x86_64-linux-static:exe:simplex-chat" "x86_64-windows:lib:simplex-chat" "x86_64-windows:exe:simplex-chat" "aarch64-linux-static:exe:simplex-chat" "i686-linux-static:exe:simplex-chat" "aarch64-android:lib:support" "armv7a-android:lib:support"; do
  check x86_64-linux "$job"
  df -h / | tail -1
done
