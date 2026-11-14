# Agent build and test - simplex-chat

Applies once the changes of plans/2026-10-25-pr-dev-build.md ("the CI plan") are on master and on the fork's master (good-git Q3). Line numbers refer to master a5cf718b3; "change N" refers to the CI plan.

## Process

1. The agent pushes commits to its ep/<topic> branch of evgeny-simplex/simplex-chat.
2. The agent dispatches the reduced build on the branch and waits for it (Dispatch).
3. Before review, the reduced build of the final commit passes (good-git STEP 4).
4. The agent opens the draft pull request in simplex-chat/simplex-chat and selects its tests in a `ci-tests` block of the description (Test selection). GitHub runs the reduced build on each push to it.
5. When the pull request is marked ready for review, GitHub runs the full matrix.

The agent merges master into a branch cut before the CI plan's changes, before its first dispatch. INFERENCE: GitHub accepts a dispatch only when the build.yml of the dispatched branch has the `workflow_dispatch` trigger; the requirement is documented for the default branch (https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows).

## Dispatch

```sh
curl -fsS -X POST \
  -H "Authorization: Bearer $(cat /code/.secrets/github_token)" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/evgeny-simplex/simplex-chat/actions/workflows/build.yml/dispatches \
  -d '{"ref": "ep/<topic>", "inputs": {"tests": "/SimpleX chat client/group tests/\n/Message batching/"}}'
```

Endpoint: https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event. Inputs (change 2):

| Input | Default | Value |
|---|---|---|
| `tests` | empty | hspec match patterns, one per line (`\n` in JSON); `/` runs the whole suite, and an empty value builds without tests |
| `base` | `master` | the branch that the changes are compared with:<br>`stable` for a branch cut from stable<br>the parent branch for a stacked branch |

When a newer dispatch on the same branch starts build-linux or build-ios, GitHub cancels the unfinished job of the older one (`cancel-in-progress`, changes 6 and 12).

Results:
- `GH_TOKEN=$(cat /code/.secrets/github_token) scripts/ci/wait-runs.py <commit>` waits until every run of the commit completes, then prints each run and its jobs that did not succeed (wait-runs.py:39-47). It reads the repository from the `origin` remote (wait-runs.py:35). The script is on branch ep/link-notices of evgeny-simplex/simplex-chat only (added in 86bd763ee).
- Run and jobs: `GET /repos/evgeny-simplex/simplex-chat/actions/runs?head_sha=<commit>&event=workflow_dispatch` returns the run id; `GET /repos/evgeny-simplex/simplex-chat/actions/runs/<run id>/jobs` returns each step with its start, end and conclusion.
- Job log: `GET /repos/evgeny-simplex/simplex-chat/actions/jobs/<job id>/logs` returns a redirect to a text file, valid for 1 minute (https://docs.github.com/en/rest/actions/workflow-jobs#download-job-logs-for-a-workflow-run). The test summary is printed as "Finished in N seconds" and "N examples, N failures".

## Scopes

The reduced build runs one Linux job, build-linux (ubuntu-22.04 x86_64), for every scope except ios, and one macOS job, build-ios (macos-latest), for ios (CI plan, "Triggers and jobs").

### core

- Globs: packages_release.py:52-69.
- CI, in build-linux:
  - Docker image (build.yml:297-312);
  - caches (:344-404);
  - `cabal build -j --enable-tests --ghc-options=-O0` (:418-432, change 3);
  - simplex-chat-test with the selected tests (:609-637, change 7d).
- Local:
  ```sh
  cp scripts/cabal.project.local.linux cabal.project.local
  cabal build --enable-tests --ghc-options=-O0
  mkdir -p tests/tmp
  cabal test simplex-chat-test --ghc-options=-O0 --test-option=-m --test-option='/SimpleX chat client/group tests/'
  ```
  `--ghc-options=-O0` matches the reduced build; the cabal stanzas set -O2 (simplex-chat.cabal:363, :805). Test directories are created under tests/tmp (Test.hs:137-140).

### kotlin

- Globs: packages_release.py:70.
- CI: Gradle in the Docker container of build-linux (build.yml:641-651; change 6, matrix field `kotlin`).
- Local:
  ```sh
  cd apps/multiplatform
  ./gradlew --no-daemon --max-workers=1 :common:desktopTest :desktop:compileKotlinJvm -x :desktop:cmakeBuildAndCopy :android:compileGoogleDebugKotlin :android:testFossDebugUnitTest
  ```
  JDK 17 (build.yml:70) and an Android SDK in ANDROID_HOME (Dockerfile.build:120-143) are required.

### ios

- Globs (change 18; CI plan Q5):
  - apps/ios/**
  - scripts/ci/ios-stub-libs.sh
  - .github/workflows/build.yml
- CI: build-ios: stub libraries, then xcodebuild for the iOS Simulator without signing (change 12).
- Local, on macOS: `scripts/ci/ios-stub-libs.sh`, then the xcodebuild command of build.yml:1192-1201.

### packages

- Globs (change 18):
  - packages/simplex-chat-nodejs/**
  - packages/simplex-chat-client/types/typescript/**
  - packages/simplex-chat-python/**
  - scripts/ci/package-tests.sh
- CI, in build-linux:
  - Node 22 and Python 3.12 (build.yml:653-665);
  - libsimplex, when core also changed (:434-448, change 7c);
  - `package-tests.sh build linux-x86_64` and `package-tests.sh test` (:667-675, change 7f).
- With libsimplex built, SIMPLEX_LIBS_DIR is set to it for the nodejs tests (build.yml:672); the python tests run with it unset (package-tests.sh:33). Without SIMPLEX_LIBS_DIR, the pinned release libraries are downloaded (packages/simplex-chat-nodejs/src/libs.ts:80-92).
- Local:
  ```sh
  scripts/ci/package-tests.sh build linux-x86_64
  scripts/ci/package-tests.sh test
  ```

### badge-web

- Globs: apps/simplex-badge-service/web/** (change 18). These paths are also in the core globs (packages_release.py:57), and web/src/catalog.ts is read by core tests (tests/Bots/BadgeService/CatalogTests.hs:205, WebTests.hs:653).
- CI, in build-linux: core build and tests, then `scope-tests.sh badge-web` (changes 7g, 17).
- Selected core tests: `/SimpleX badge service/` and `/SimpleX badge service e2e/`.
- Local:
  ```sh
  cd apps/simplex-badge-service/web
  npm ci
  npm test
  ```

### ci-scripts

- Globs (change 18):
  - scripts/ci/packages_release.py
  - scripts/ci/test_packages_release.py
- These paths are also in the core globs (scripts/ci/**, packages_release.py:65).
- CI, in build-linux: `scope-tests.sh ci-scripts` (changes 7g, 17).
- Local: `python3 scripts/ci/test_packages_release.py`; Python 3.11 or newer is required for tomllib (packages_release.py:34).

### Scopes lacking CI tests

The CI plan lists them ("Scopes lacking CI tests today"). The agent that changes one of them adds its CI coverage in the same pull request (Adding CI coverage).

## Test selection

- Dispatch: the `tests` input.
- Draft pull request: a fenced block with info string `ci-tests` in the description, read on each push (change 7d):
  ````
  ```ci-tests
  /SimpleX chat client/group tests/
  /Message batching/
  ```
  ````
  A description edit applies from the next push.
- One pattern per line; leading and trailing whitespace is removed, and empty lines are ignored. Each pattern becomes `-m <pattern>`; an item is selected when any pattern is a substring of its path `/group/subgroup/item/` (hspec-core 2.11.7, Util.hs:100-128). A leading and a trailing `/` select one group: `/SimpleX badge service/` excludes `/SimpleX badge service e2e/`.
- With at least one pattern, `--fail-on=empty` is added, so a run in which every item is filtered out fails; a misspelt pattern beside a matching one is visible only in the example count.
- `/` selects the whole suite. With no pattern, a reduced run builds without core tests. After ready for review, the whole suite runs.

Top-level groups, with example counts from run 40202672400 (22.04, GHC 9.6.3):

| Pattern | Examples | Test.hs |
|---|---|---|
| `/Schema dump/` | 4 | :72 |
| `/Bot API docs/` | 17 | :74 |
| `/WebRTC encryption/` | 4 | :76 |
| `/Supporter badges/` | 56 | :78 |
| `/SimpleX badge service/` | 374, 1 pending | :79-87 |
| `/SimpleX chat markdown/` | 121 | :88 |
| `/JSON Tests/` | 9 | :89 |
| `/Member relations/` | 45 | :90 |
| `/SimpleX chat view/` | 42 | :91 |
| `/SimpleX chat protocol/` | 80 | :92 |
| `/Valid names/` | 1 | :93 |
| `/Message batching/` | 58 | :94 |
| `/Operators/` | 18 | :95 |
| `/Random servers/` | 2 | :96 |
| `/names tests/` | 14 | :98 |
| `/SimpleX Directory names/` | 2 | :99 |
| `/Mobile API Tests/` | 18 | :108 |
| `/SimpleX chat client/` | 616, 7 pending | :110 |
| `/SimpleX Directory service bot/` | 56 | :112 |
| `/SimpleX badge service e2e/` | 137 | :113-115 |
| `/Remote session/` | 56, 36 pending | :116 |

"SimpleX Broadcast bot" (:111) and "Save query plans" (:118) are pending only.

Groups of `/SimpleX chat client/` (ChatTests.hs:15-22):

| Pattern | Examples |
|---|---|
| `/SimpleX chat client/direct tests/` | 101 |
| `/SimpleX chat client/forward tests/` | 24 |
| `/SimpleX chat client/group tests/` | 283 |
| `/SimpleX chat client/chat relay tests/` | 20 |
| `/SimpleX chat client/local chats tests/` | 9 |
| `/SimpleX chat client/file tests/` | 39 |
| `/SimpleX chat client/profile tests/` | 132 |
| `/SimpleX chat client/chat list pagination tests/` | 8 |

Whole-suite test time on 22.04 x86_64: 707-844 s (CI plan M3). Deeper groups and item names are printed in the test log of any run.

## Artifacts

- The output of the reduced build is its job log.
- The app workflows (android-emu, desktop-linux, ios-sim) are outside the reduced build. The app is uploaded only for their Claude job, with retention 1 day (android-emu.yml:252-260, desktop-linux.yml:261-269, ios-sim.yml:257-265). When they run and how an app reaches a manual tester: CI plan Q4.
- Download: `GET /repos/evgeny-simplex/simplex-chat/actions/runs/<run id>/artifacts` returns the artifact ids; `GET /repos/evgeny-simplex/simplex-chat/actions/artifacts/<artifact id>/zip` with the Authorization header returns a redirect to the zip, valid for 1 minute (https://docs.github.com/en/rest/actions/artifacts#download-an-artifact).

## Adding CI coverage

For a scope lacking CI tests, in the pull request that changes it:
1. scripts/ci/packages_release.py: an entry `"<scope>": ["<glob>", ...]` in SCOPE_CHANGES.
2. build.yml, `on.pull_request.paths`: the same globs; the two are compared in test_packages_release.py:243-250.
3. scripts/ci/scope-tests.sh: a `<scope>)` case with the build and test commands, and the scope name in the usage line.
4. scripts/ci/test_packages_release.py, ChangesTest: a case asserting that the scope is printed in `scopes` for a change to one of its files.
5. scripts/ci/README.md, "Reduced build": a row for the scope.
6. Checks: `python3 scripts/ci/test_packages_release.py`, the new case of scope-tests.sh locally, then a dispatch of the reduced build.

The scope commands run in build-linux after the core tests, with Node 22 and Python 3.12 (build.yml:658, :665). For a scope that needs other versions, the agent adds a setup step before "Test changed scopes", conditioned on the scope name in `needs.maybe-release.outputs.scopes`. A scope that needs macOS is a BUILD_CHANGES entry with a separate maybe-release output, as ios is (packages_release.py:71, build.yml:99), and a step in build-ios; the `if` of build-ios (change 12) includes that output.
