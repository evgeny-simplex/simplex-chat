#!/bin/bash

# Finds the newest run of this branch in this repository that uploaded an unexpired artifact with this name,
# and writes its id as run-id to GITHUB_OUTPUT. Needs GH_TOKEN with actions: read.
# Usage: scripts/ci/desktop-linux/earlier-run.sh <artifact name>
# Artifacts from forks and other branches are not used: their workflows could upload anything under this name.
# For the same reason, a run of build-apps.yml that built a pull request is used only by runs for that pull request.

set -euo pipefail

name=$1
own_title=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" --jq .display_title)
run_ids=$(gh api "repos/$GITHUB_REPOSITORY/actions/artifacts?name=$name&per_page=100" | jq -r --arg branch "$GITHUB_REF_NAME" '
  [.artifacts[]
    | select((.expired | not) and .workflow_run.head_branch == $branch and .workflow_run.head_repository_id == .workflow_run.repository_id)]
  | sort_by(.created_at) | reverse | .[].workflow_run.id')
for run_id in $run_ids; do
  if gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run_id" | jq -e --arg own "$own_title" \
    '.path != ".github/workflows/build-apps.yml" or (.display_title | startswith("build-apps pull request") | not)
      or (.display_title | split(" ")[:4]) == ($own | split(" ")[:4])' > /dev/null; then
    echo "$name: from run $run_id"
    echo "run-id=$run_id" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  echo "$name: run $run_id built another pull request"
done
echo "$name: not built yet"
