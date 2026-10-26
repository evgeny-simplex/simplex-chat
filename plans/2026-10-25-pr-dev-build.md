# Reduced build - simplex-chat

The agent guide is plans/2026-10-25-agent-build-test.md.

Line numbers refer to master a5cf718b3. These files are unchanged between 66e381bf5 and a5cf718b3 (`GET /repos/simplex-chat/simplex-chat/compare/66e381bf5...a5cf718b3`) and are cited at 66e381bf5:
- scripts/ci/*
- tests/Test.hs
- tests/ChatTests.hs
- simplex-chat.cabal

`build.yml` is `.github/workflows/build.yml`.

Run data ("the run sample"): the 40 latest build.yml runs of simplex-chat/simplex-chat that concluded success or failure and include a GHC job, created from 2026-10-22 to 2026-10-25 (`GET /repos/simplex-chat/simplex-chat/actions/workflows/build.yml/runs`, then `GET .../actions/runs/<run id>/jobs`). "Log <run id>" is the job log of its ubuntu-22.04-x86_64 GHC 9.6.3 job (`GET .../actions/jobs/<job id>/logs`).

## Goal

A manual run (workflow_dispatch on a fork branch) and a push to a draft pull request run the reduced build:
- one Linux job, which builds and tests every changed scope;
- one macOS job, only when iOS code changed.

The full matrix runs:
- when a pull request is marked ready for review, and on later pushes to it;
- on pushes to master and stable, and on tag pushes.

## Consistency with simplexmq

These parts repeat simplexmq PR simplex-chat/simplexmq#1986 (run 40223821058) with the same names and syntax:
- `pull_request` types (change 1);
- workflow_dispatch input `tests` (change 2);
- `opt` and `ghc_options` (change 3);
- maybe-release output `reduced`, with the expression `github.event_name == 'workflow_dispatch' || github.event.pull_request.draft == true` (change 4);
- the test step env `TESTS` and `PR_BODY`, the `ci-tests` block and `--fail-on=empty` (change 7d);
- `image_cache` under `github.repository_owner` (change 21).

Differences required by simplex-chat's structure:
- Input `base`: jobs are selected by changed paths (packages_release.py:502-506), and a dispatch has no pull request base.
- Job conditions select the reduced job in both repositories. simplex-chat already splits its Linux entries into jobs with job-level conditions (build-linux-push :752, build-linux-ghc8 :788), so the 24.04 entry becomes the job build-linux-full (change 8).
- The reduced job is ubuntu-22.04 x86_64, where simplexmq uses 24.04: the 22.04 entry builds libsimplex (`libs: true`, build.yml:247), which the package tests load (:672).

## Scopes

| Scope | Globs | Build | Tests | CI today |
|---|---|---|---|---|
| core | packages_release.py:52-69 | `cabal build -j --enable-tests` (build.yml:425) | simplex-chat-test, 1732 examples (Test.hs:62-118; M3) | pull request: 6 GHC jobs (build.yml:240-255, :801-808, :941-955, :1328-1331)<br>tests on x86_64 Linux (:618) and macos-latest (:1165) |
| kotlin | packages_release.py:70 | `:desktop:compileKotlinJvm`<br>`:android:compileGoogleDebugKotlin`<br>(build.yml:649-650) | `:common:desktopTest`<br>`:android:testFossDebugUnitTest`<br>(:648, :651) | build-linux 24.04 (:255, :641-651)<br>desktop-linux.yml:271-274, by dispatch<br>app smoke tests, by dispatch |
| ios | packages_release.py:71 | xcodebuild with stub libraries (build.yml:1191-1201) | - (`apps/ios/Tests iOS` includes only the Xcode templates) | compile in build-macos macos-latest (:948, :1186-1201)<br>ios-sim.yml smoke test, by dispatch |
| packages | packages.yml:6-8 | `package-tests.sh build` (package-tests.sh:16-26) | nodejs: jest<br>python: pytest<br>types: -<br>(package-tests.sh:28-34) | "Package tests (pull request)" on 4 platforms when core globs changed (build.yml:667-675, :1241-1247, :1511-1517)<br>packages.yml on 5 platforms otherwise (packages.yml:33-72; packages_release.py:90-96, :509-511) |
| badge-web | badge-web.yml:9 | `npm run build` (web/package.json) | `npm test`: node --test (web/package.json) | badge-web.yml:3-33 |
| ci-scripts | scripts/ci/packages_release.py<br>scripts/ci/test_packages_release.py | - | unittest, 80 tests (M8) | - |
| website | website/**<br>images/**<br>blog/**<br>docs/**<br>PRIVACY.md<br>(web.yml:8-13) | website/web.sh | - ("test" script exits 1) | build and deploy on master pushes (web.yml:3-39) |
| ts-client | packages/simplex-chat-client/typescript/** | tsc<br>rollup | prettier<br>eslint<br>jest<br>("test" script) | - |
| webrtc | packages/simplex-chat-webrtc/** | tsc | node --test ("test" script) | - |
| mcp | packages/simplex-chat-mcp/** | tsc | jest test/unit<br>jest test/e2e | - |
| calculator-bot | apps/simplex-calculator-bot/** | tsc | vitest run ("test" script) | - |
| support-bot | apps/simplex-support-bot/** | tsc | bot.test.ts with vitest.config.ts<br>package.json scripts: build and start | - |
| support-bot-light | apps/simplex-support-bot-light/** | hatchling | pytest (pyproject.toml testpaths) | - |
| prices | scripts/prices/** (added in ea679e6e9) | - | - | - |
| nft | eth/nft/** | Solidity | *_test.sol | - |

Scopes lacking CI tests today:
- ios: compile only
- types package: compile only
- ci-scripts: covered by change 17
- website: master build only
- ts-client
- webrtc
- mcp
- calculator-bot
- support-bot
- support-bot-light
- prices
- nft

The agent that changes a scope lacking CI tests adds its build and tests to CI in the same pull request (agent guide, "Adding CI coverage").

## Triggers and jobs

Reduced run: workflow_dispatch, or pull_request with `draft` true (output `reduced`, change 4).

| Trigger | Changed scope | Jobs | Steps |
|---|---|---|---|
| reduced | core | build-linux: ubuntu-22.04 x86_64 | Docker image<br>caches<br>`cabal build` at -O0<br>simplex-chat-test with the selected tests |
| reduced | kotlin | build-linux | Docker image<br>Gradle compile and unit tests |
| reduced | packages | build-linux | libsimplex, when core also changed<br>`package-tests.sh build`<br>`package-tests.sh test` |
| reduced | a SCOPE_CHANGES scope | build-linux | `scope-tests.sh <scope>` |
| reduced | ios | build-ios: macos-latest | iOS compile with stub libraries |
| ready_for_review<br>push to a non-draft pull request | per scope, as today | build-linux 22.04 x86_64<br>build-linux-full: 24.04, core and Kotlin<br>build-linux-ghc8<br>build-macos: 2 jobs<br>build-ios<br>build-windows<br>packages.yml: 5 jobs, when packages changed without core | steps as today<br>scope tests in build-linux |
| push to master | all | build-linux<br>build-linux-full<br>build-linux-ghc8<br>build-linux-push: 2 aarch64 jobs, build only<br>build-macos: 2 jobs<br>build-ios<br>build-windows | steps as today<br>scope tests in build-linux |
| push to stable | all | as master, without build-linux-ghc8 (build.yml:788) | as master |
| push of a v* tag | core | release jobs | steps as today |

Each run also includes the control jobs variables (build.yml:66-74) and maybe-release (:92-217), 0.2 min (M5). cla.yml runs on pull_request_target events (cla.yml:3-6).

## Test selection

- Dispatch: input `tests`, hspec match patterns, one per line.
- Draft pull request: a fenced block with info string `ci-tests` in the description, one pattern per line:
  ````
  ```ci-tests
  /SimpleX chat client/group tests/
  /Message batching/
  ```
  ````
  The block is read from the event payload (`github.event.pull_request.body`) of the run, so a description edit applies from the next push; the types of change 1 exclude `edited`.
- Leading and trailing whitespace is removed, and empty lines are ignored. Each pattern is passed as `-m <pattern>`, and `--fail-on=empty` is added when at least one pattern is given (change 7d). `/` selects the whole suite; with no pattern, a reduced run builds without core tests and "Run tests" prints "No tests selected".
- The suite runs under `hspec` (Test.hs:62), which reads the command line (hspec-core 2.11.7, Runner.hs:179-180, :235-237).
- A pattern is matched as a substring against the item path `/group/subgroup/item/` and against its formatted requirement (hspec-core 2.11.7, Util.hs:100-128). A leading and a trailing `/` select one group: `/SimpleX badge service/` excludes `SimpleX badge service e2e`.
- With `--fail-on=empty`, a run in which every item is filtered out fails (hspec-core 2.11.7 help.txt:14-17).
- hspec: `hspec ==2.11.*` (simplex-chat.cabal:865) at index-state 2023-12-12 (cabal.project:14). In simplexmq CI, cabal resolves hspec-core 2.11.7 at the same index-state (simplexmq runs 40208397814, 40208402680, 40208423064, job logs). INFERENCE: cabal resolves the same version for simplex-chat.
- Full runs: `TESTS` is empty outside workflow_dispatch and `PR_BODY` is empty unless the pull request is a draft, so the whole suite runs, with 3 attempts on stable and tags (build.yml:622-637).
- The agent guide lists the groups with their example counts.

## Warm cache

Main repository, draft pull request from a fork branch:
- In a pull request run, caches of its merge ref, of the base branch and of the default branch (stable, `GET /repos/simplex-chat/simplex-chat`) are restorable (https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching, "Restrictions for accessing a cache").
- The 22.04 x86_64 caches restored by the reduced job are saved by master pushes:
  - dependencies (build.yml:461-466);
  - source repositories (:468-473);
  - the -O0 build directory (:704-747; `cache_o0` :38).
- Keys: `deps-<target>-<branch>-*` (:350) and `dist-<target>-O0-<branch>-*` (:380), where `<target>` is `ubuntu-22.04-x86_64-ghc9.6.3-<toolchain>` (:338-342) and `<branch>` is the base branch (:37).
- Run 40202672400 (pull request from ep/fix-tests, job header "Cache mode: write", log :28) restored deps, src, dist and dist-lib entries keyed with `master` (log :2420, :2449, :2482, :2514). The dist and dist-lib entries end in c2134f2c5, a merge commit of an earlier run of that pull request (the commits API returns "No commit found" for it). It saved dist and dist-lib entries keyed with its merge commit ded1ea9a9 (log :3552, :3577).
- Docker image layers are imported from the weekly registry cache (build.yml:292-312) with the token of the main repository (log 40202672400:1508-1520).

Fork, dispatch on an ep/ branch:
- In a run, caches of its branch and of the default branch, master, are restorable (dependency caching docs; default branch: `GET /repos/evgeny-simplex/simplex-chat`).
- `branch` (build.yml:37) is the branch name, so caches are saved per branch, and keys with the same prefix in those two scopes are matched by restore-keys (:351-353, :381-383).
- 64 caches, 10,787 MB, are stored in the fork, all on refs/pull/6/merge and refs/pull/10/merge (`GET /repos/evgeny-simplex/simplex-chat/actions/caches`, 2026-10-25). They are not restorable by branch runs (dependency caching docs).
- The first dispatch of a branch runs an uncached build until the fork's master holds seeds (Q2). In later dispatches of the branch, its caches are restored.
- Fork master pushes skip every build job today: in fork run 40207892523, maybe-release fails at "Library release" (build.yml:156-179), and the build jobs are skipped (jobs API).
- Docker image today: the fork's import of ghcr.io/simplex-chat/simplex-chat-build-cache fails with "403 Forbidden", and the image is built from scratch in 7.7 min (fork run 40207961758, job 121212924986, log :1526; jobs API). With change 21, fork jobs read ghcr.io/evgeny-simplex/simplex-chat-build-cache, which is written by fork master pushes (build.yml:312) once they reach build-linux (Q2).
- Caches of one branch total about 0.5 GB (M7). The limit is 10 GB per repository; caches unused for 7 days are evicted (dependency caching docs).

## Changes

Adoption order: good-git Q3 (PR evgeny-simplex/agents#3).

1. build.yml:12-31, `pull_request`. Lines appended after :31, and `types` after the paths; `paths:` is required on the line after `pull_request:` by the regex at test_packages_release.py:245:
   ```yaml
         - "packages/simplex-chat-nodejs/**"
         - "packages/simplex-chat-client/types/typescript/**"
         - "packages/simplex-chat-python/**"
         - "scripts/ci/package-tests.sh"
         - "apps/simplex-badge-service/web/**"
         - "scripts/ci/packages_release.py"
         - "scripts/ci/test_packages_release.py"
       types: [opened, synchronize, reopened, ready_for_review]
   ```

2. build.yml, after the `pull_request` block:
   ```yaml
     workflow_dispatch:
       inputs:
         tests:
           description: "hspec match patterns, one per line; / runs all tests, empty runs none"
           type: string
           default: ""
         base:
           description: the branch that the changes are compared with
           type: string
           default: master
   ```

3. build.yml:34-35:
   ```yaml
     opt: ${{ github.event_name == 'push' && 'O2' || 'O0' }}
     ghc_options: ${{ github.event_name != 'push' && '--ghc-options=-O0' || '' }}
   ```

4. build.yml, maybe-release outputs, after :106:
   ```yaml
         packages: ${{ steps.changes.outputs.packages }}
         scopes: ${{ steps.changes.outputs.scopes }}
         reduced: ${{ github.event_name == 'workflow_dispatch' || github.event.pull_request.draft == true }}
   ```

5. build.yml:109, the `if` of "Clone project", is removed. "Check changes" (:114-130) becomes:
   ```yaml
         - name: Check changes
           id: changes
           shell: bash
           env:
             BASE: ${{ github.event.pull_request.base.sha }}
             BASE_BRANCH: ${{ inputs.base }}
             GH_TOKEN: ${{ github.token }}
           run: |
             case "$GITHUB_EVENT_NAME" in
               pull_request)
                 git fetch -q --depth=1 origin "$BASE"
                 python3 scripts/ci/packages_release.py changes "$BASE"
                 ;;
               workflow_dispatch)
                 base=$(gh api "repos/$GITHUB_REPOSITORY/compare/$BASE_BRANCH...$GITHUB_REF_NAME" --jq .merge_base_commit.sha)
                 git fetch -q --depth=1 origin "$base"
                 python3 scripts/ci/packages_release.py changes "$base"
                 ;;
               *)
                 echo "haskell=true"
                 if [ "$GITHUB_REF_TYPE" = branch ]; then
                   echo "kotlin=true"
                   echo "ios=true"
                   python3 scripts/ci/packages_release.py scopes
                 fi
                 ;;
             esac >> "$GITHUB_OUTPUT"
   ```
   The compare endpoint returns `merge_base_commit` for `BASE...HEAD` branch names (https://docs.github.com/en/rest/commits/commits#compare-two-commits); a head branch with a slash is accepted (`GET /repos/evgeny-simplex/simplex-chat/compare/master...ep/link-notices` returned merge base 66e381bf5). `gh api` is used on runners in scripts/ci/desktop-linux/earlier-run.sh:11.

6. build.yml, build-linux. After `needs` (:225):
   ```yaml
       if: needs.maybe-release.outputs.haskell == 'true' || needs.maybe-release.outputs.scopes != '' || (needs.maybe-release.outputs.reduced == 'true' && (needs.maybe-release.outputs.kotlin == 'true' || needs.maybe-release.outputs.packages == 'true'))
   ```
   :235 becomes `cancel-in-progress: ${{ github.event_name != 'push' }}`. The 24.04 entry (:248-255) is moved to change 8. These lines follow `libs: true` (:247) in the 22.04 entry:
   ```yaml
               kotlin: ${{ needs.maybe-release.outputs.reduced == 'true' && needs.maybe-release.outputs.kotlin == 'true' }}
               packages: ${{ needs.maybe-release.outputs.reduced == 'true' && needs.maybe-release.outputs.packages == 'true' }}
               scope_tests: ${{ needs.maybe-release.outputs.scopes != '' }}
   ```
   INFERENCE: the Kotlin step succeeds in the 22.04 image, which is built from the same Dockerfile.build as the 24.04 image (build.yml:303, :306); Validation 4 checks it.

7. build.yml, `&linux-steps`:
   - a. "Checkout Code", :258: `if: matrix.should_run == true || matrix.kotlin == true || matrix.packages == true || matrix.scope_tests == true`
   - b. "Restore library build directory from cache", :391: `if: env.release != 'true' && matrix.libs && needs.maybe-release.outputs.core_changed && matrix.arch == 'x86_64' && (needs.maybe-release.outputs.reduced != 'true' || matrix.packages == true)`
   - c. "Build library", :437: `if: matrix.libs && (needs.maybe-release.outputs.libs_tag || (needs.maybe-release.outputs.core_changed && matrix.arch == 'x86_64' && (needs.maybe-release.outputs.reduced != 'true' || matrix.packages == true)))`
   - d. "Run tests" (:617-637): :620-622 are replaced by the first block, and :626 by the second; the other lines are kept:
     ```yaml
             shell: bash
             env:
               TESTS: ${{ github.event_name == 'workflow_dispatch' && inputs.tests || '' }}
               PR_BODY: ${{ github.event.pull_request.draft == true && github.event.pull_request.body || '' }}
             run: |
               if [ -n "$PR_BODY" ]; then
                 TESTS=$(printf '%s\n' "$PR_BODY" | tr -d '\r' | awk '/^```ci-tests[ \t]*$/ {f = 1; next} /^```[ \t]*$/ {f = 0} f')
               fi
               args=()
               while read -r p; do
                 if [ -n "$p" ]; then args+=(-m "$p"); fi
               done <<< "$TESTS"
               if [ "${#args[@]}" -gt 0 ]; then args+=(--fail-on=empty); fi
               i=1
     ```
     ```bash
                 if ./simplex-chat-test "${args[@]}"; then
     ```
     The description and the input are passed to the script through environment variables, the method prescribed for untrusted input (https://docs.github.com/en/actions/reference/security/secure-use).
   - e. "Setup Node.js", :655: `if: ${{ !cancelled() && (matrix.packages == true || matrix.scope_tests == true || (matrix.should_run == true && matrix.libs && ((github.event_name == 'pull_request' && needs.maybe-release.outputs.reduced != 'true') || needs.maybe-release.outputs.addon_draft || needs.maybe-release.outputs.publish))) }}`
   - f. "Package tests (pull request)", :668: `if: ${{ !cancelled() && steps.setup-python.outcome == 'success' && github.event_name != 'push' && steps.build-lib.outcome != 'failure' && ((needs.maybe-release.outputs.reduced != 'true' && matrix.should_run == true) || matrix.packages == true) }}`
   - g. New step after "Package tests result" (:702). Scope tests run with Node 22 and Python 3.12 (:658, :665); badge-web.yml used Node 24 (badge-web.yml:27). INFERENCE: the badge-web tests pass on Node 22; Validation 4 checks it.
     ```yaml
           - name: Test changed scopes
             if: ${{ !cancelled() && matrix.scope_tests == true && steps.setup-python.outcome == 'success' }}
             timeout-minutes: 30
             shell: bash
             env:
               SCOPES: ${{ needs.maybe-release.outputs.scopes }}
             run: |
               for scope in $SCOPES; do
                 scripts/ci/scope-tests.sh "$scope"
               done
     ```

8. build.yml, new job after :747:
   ```yaml
     build-linux-full:
       name: "ubuntu-${{ matrix.os }}-${{ matrix.arch }} (CLI,Desktop), GHC: ${{ matrix.ghc }}"
       needs: [maybe-release, variables]
       if: needs.maybe-release.outputs.reduced != 'true' && (needs.maybe-release.outputs.haskell == 'true' || needs.maybe-release.outputs.kotlin == 'true')
       runs-on: ${{ matrix.runner }}
       permissions:
         contents: write
         packages: write
       env:
         image_cache: ghcr.io/${{ github.repository_owner }}/simplex-chat-build-cache:${{ matrix.os }}-${{ matrix.arch }}-ghc${{ matrix.ghc }}
         source_hashes: dist-newstyle/sources.sha256
       concurrency: *linux-concurrency
       strategy:
         fail-fast: false
         matrix:
           include:
             - os: 24.04
               os_underscore: 24_04
               arch: x86_64
               runner: "ubuntu-24.04"
               should_run: ${{ needs.maybe-release.outputs.haskell == 'true' }}
               ghc: ${{ needs.variables.outputs.GHC_VER }}
               hash: 'sha256:98ff7968124952e719a8a69bb3cccdd217f5fe758108ac4f21ad22e1df44d237'
               kotlin: ${{ needs.maybe-release.outputs.kotlin == 'true' }}
       steps: *linux-steps
   ```
   The job name, the concurrency group and the entry are those of the moved 24.04 entry (build.yml:224, :233-235, :248-255).

9. build.yml:752: `if: github.event_name == 'push'`

10. build.yml:788: `if: ${{ needs.maybe-release.outputs.reduced != 'true' && needs.maybe-release.outputs.haskell == 'true' && !(github.ref == 'refs/heads/stable' || startsWith(github.ref, 'refs/tags/v')) }}`

11. build.yml, build-macos:
    - after `needs` (:932): `if: needs.maybe-release.outputs.reduced != 'true' && needs.maybe-release.outputs.haskell == 'true'`
    - :948 (`ios:`) is removed
    - :958 and :964: `if: matrix.should_run == true`
    - "Build iOS app" (:1186-1201) is moved to change 12

12. build.yml, new job after :1310. Its steps are the build-macos steps that ran when only `ios` was true (:957-966, :1186-1201):
    ```yaml
      build-ios:
        name: "macos-latest (iOS)"
        needs: maybe-release
        if: needs.maybe-release.outputs.ios == 'true'
        runs-on: macos-latest
        concurrency:
          group: ${{ github.workflow }}-${{ github.ref }}-ios
          cancel-in-progress: ${{ github.event_name != 'push' }}
        steps:
          - name: Checkout Code
            uses: actions/checkout@v3

          - name: Point Command Line Tools SDK to Xcode SDK
            shell: bash
            run: sudo ln -sfn "$(xcrun --sdk macosx --show-sdk-path)" /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk

          - name: Build iOS app
            timeout-minutes: 60
            shell: bash
            run: |
              scripts/ci/ios-stub-libs.sh
              xcodebuild build -quiet \
                -project apps/ios/SimpleX.xcodeproj \
                -scheme "SimpleX (iOS)" \
                -configuration Debug \
                -destination "generic/platform=iOS Simulator" \
                -onlyUsePackageVersionsFromResolvedFile \
                -skipPackagePluginValidation \
                -skipMacroValidation \
                ARCHS=arm64 \
                CODE_SIGNING_ALLOWED=NO
    ```
    The checkout runs without submodules. The only submodule is apps/multiplatform/external/nanohttpd/upstream (.gitmodules), and the same project is built in ios-sim.yml from a checkout without submodules (ios-sim.yml:193-194, :235-250).

13. build.yml:1319: `if: needs.maybe-release.outputs.reduced != 'true' && needs.maybe-release.outputs.haskell == 'true'`

14. build.yml:1625 and :1649: `build-linux-full` and `build-ios` are added to `needs`; the order of releases and publish after the moved steps is kept:
    ```yaml
        needs: [maybe-release, build-linux, build-linux-full, build-linux-push, build-linux-postgres, build-macos, build-ios, build-windows]
    ```
    ```yaml
        needs: [maybe-release, build-linux, build-linux-full, build-linux-push, build-macos, build-ios, build-windows, releases]
    ```

15. packages.yml: `types` after the paths (:5-9), and a draft condition on the first job (:25):
    ```yaml
        types: [opened, synchronize, reopened, ready_for_review]
    ```
    ```yaml
      addon:
        if: github.event.pull_request.draft == false
    ```
    The build job is skipped with its need (packages.yml:43-44).

16. .github/workflows/badge-web.yml is deleted. Its tests run in change 7g.

17. scripts/ci/scope-tests.sh, new, mode 755:
    ```bash
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
      *)
        echo "usage: $0 badge-web | ci-scripts" >&2
        exit 1
        ;;
    esac
    ```

18. scripts/ci/packages_release.py:
    - :13 is replaced by two lines:
      ```
      changes           print whether the changes since a commit touch the chat core, the add-on, each build of build.yml and each scope of scope-tests.sh
      scopes            print every scope of scope-tests.sh
      ```
    - :50 becomes:
      ```python
      # The pull_request paths of build.yml are the union of the globs of BUILD_CHANGES and SCOPE_CHANGES; ":!" excludes a path from its build.
      ```
    - :71 becomes the first line below; the "packages" entry follows it, and SCOPE_CHANGES follows the closing brace (:72):
      ```python
          "ios": ["apps/ios/**", "scripts/ci/ios-stub-libs.sh"],
          "packages": [
              "packages/simplex-chat-nodejs/**",
              "packages/simplex-chat-client/types/typescript/**",
              "packages/simplex-chat-python/**",
              "scripts/ci/package-tests.sh",
          ],
      }
      SCOPE_CHANGES = {
          "badge-web": ["apps/simplex-badge-service/web/**"],
          "ci-scripts": ["scripts/ci/packages_release.py", "scripts/ci/test_packages_release.py"],
      }
      ```
    - :498-499:
      ```python
      def build_pathspecs(build: str) -> list[str]:
          return [path if path.startswith(":") else f":(glob){path}" for path in (BUILD_CHANGES | SCOPE_CHANGES)[build]]
      ```
    - after :506, in `changes`:
      ```python
          print(f"scopes={' '.join(scope for scope in SCOPE_CHANGES if changed_since(base, build_pathspecs(scope)))}")
      ```
    - after :961: `commands.add_parser("scopes")`; after :998:
      ```python
          elif args.command == "scopes":
              print(f"scopes={' '.join(SCOPE_CHANGES)}")
      ```

19. scripts/ci/test_packages_release.py:
    - :29: `SCOPE_CHANGES` is imported after `BUILD_CHANGES`
    - :248: `globs = {path for build in (BUILD_CHANGES | SCOPE_CHANGES).values() for path in build if not path.startswith(":")}`
    - :466-467: the parsed output is kept in `self.values` before the builds are returned
    - ChangesTest, new cases:
      ```python
          def test_other_workflow_change_builds_the_core_and_kotlin(self):
              self.assertEqual(self.builds(".github/workflows/web.yml"), {"haskell", "kotlin"})

          def test_package_change_builds_only_packages(self):
              self.assertEqual(self.builds("packages/simplex-chat-python/src/simplex_chat/client.py"), {"packages"})

          def test_badge_web_change_builds_the_core_and_tests_its_scope(self):
              self.assertEqual(self.builds("apps/simplex-badge-service/web/src/catalog.ts"), {"haskell"})
              self.assertEqual(self.values["scopes"], "badge-web")

          def test_release_script_change_tests_the_ci_scripts(self):
              self.assertEqual(self.builds("scripts/ci/packages_release.py"), {"haskell"})
              self.assertEqual(self.values["scopes"], "ci-scripts")
      ```

20. scripts/ci/README.md:
    - the title becomes "CI on GitHub's runners";
    - a section "Reduced build" before "Starting a run" includes these sections of the agent guide:
      - "Dispatch"
      - "Scopes"
      - "Adding CI coverage"

21. build.yml:231, :758, :794 and the `env` of build-linux-full (change 8):
    ```yaml
          image_cache: ghcr.io/${{ github.repository_owner }}/simplex-chat-build-cache:${{ matrix.os }}-${{ matrix.arch }}-ghc${{ matrix.ghc }}
    ```
    In the main repository the value is unchanged (`simplex-chat`).

## Measurements

- M1. Standard runners for public repositories (https://docs.github.com/en/actions/reference/runners/github-hosted-runners); their use is free and unlimited there (same page):
  - Linux x64 and Linux arm64: 4 CPU, 16 GB;
  - macOS arm64 (macos-latest): 3 CPU (M1), 7 GB;
  - macos-15-intel: 4 CPU, 14 GB.
- M2. Step "Run tests" in the run sample, median (n, range); successful and failed steps; 120-min timeouts excluded:
  - 22.04 x86_64: 17.9 min (n=37, 11.8-21.0);
  - 24.04 x86_64: 16.2 min (n=34);
  - 22.04 GHC 8.10.7: 21.6 min (n=32);
  - macos-latest: 21.5 min (n=36);
  - 24.04 minus 22.04 in the 33 runs with both: median -7 s; 22.04 is faster in 14 of 33.
- M3. hspec "Finished in", 3 successful runs (39914881495, 40172782505, 40202672400; job logs):
  - 22.04: 707, 844, 716 s;
  - 24.04: 830, 978, 966 s;
  - GHC 8.10.7: 779, 1064, 1067 s;
  - macos-latest: 1079, 1076, 1151 s;
  - the GHC 9.6.3 suite has 1732 examples, 46 of them pending; the GHC 8.10.7 suite has 1715.
- M4. Failed "Run tests" steps in the M2 sample:
  - 22.04: 27 of 37;
  - 24.04: 20 of 34;
  - GHC 8.10.7: 19 of 32;
  - macos-latest: 33 of 36.
- M5. Successful steps on pull requests in the run sample, median [range]:
  - 22.04 Docker image: 1.2 min [0.9-6.0], n=33;
  - 22.04 "Build CLI": 0.5 min [0.3-23.9], n=32;
  - 22.04 "Build library": 1.0 min [0.1-13.8], n=28;
  - 22.04 "Package tests (pull request)": 1.5 min [1.1-2.6], n=32;
  - 24.04 Kotlin step: 12.3 min [6.8-26.9], n=8;
  - macos-latest iOS compile: 11.8 min [4.7-14.7], n=10;
  - control jobs in run 40207583652: maybe-release 0.2 min; variables under 0.1 min.
- M6. Docker image step in the master pushes that changed Dockerfile.build: 5.6-7.1 min (run 39925980877 for 773434a56; run 39933406998 for 66e381bf5).
- M7. Cache sizes, log 40202672400:
  - deps: 117 MB;
  - src: 178 MB;
  - dist: 169 MB;
  - dist-lib: 61 MB.
- M8. `python3 scripts/ci/test_packages_release.py`, run locally on 2026-10-25:
  - 66e381bf5: 80 tests pass;
  - copies with changes 1-15, 17-19 and 21 applied: 84 tests pass. On the changed build.yml, actionlint 1.7.12 reports only the kinds of finding it reports on master (matrix properties undefined in some jobs of the shared steps, checkout@v3, the `if: false` of variables); on the changed packages.yml, it reports none.
- M9. ubuntu-22.04 x86_64 GHC 9.6.3 jobs on master pushes in the run sample: 18.0-29.7 min (6 jobs).

## aarch64 experiment

State:
- Tests on aarch64 Linux were disabled in 2175db934 (2025-08-16), PR #6192; its description is null, with 0 comments (GitHub API).
- Today aarch64 jobs run only on push events (build.yml:749-783) and build without tests (:618).
- Runner sizes are equal (M1).
- "Build CLI" in run 40095405557 (jobs API):
  - 22.04 aarch64: 27.3 min;
  - 24.04 aarch64: 27.3 min;
  - 22.04 x86_64: 23.9 min;
  - 24.04 x86_64: 33.6 min.
- simplexmq master push 40180494957, build step: 7.7 min on aarch64; 6.5 min on x86-64 (jobs API).
- Test duration on aarch64: unmeasured.

Procedure, after the changes are on the fork's master, on throwaway fork branches, as in Q3 A of the simplexmq plan, without a permanent dispatch input:
1. Branches:
   - ep/arm-base: master and one commit, in which the 22.04 entry of build-linux is set to `arch: aarch64`, `runner: "ubuntu-22.04-arm"` and the hash of build.yml:772, and the `matrix.arch == 'x86_64'` terms of "Mount RAM disk for tests" (:610) and "Run tests" (:618) are removed;
   - ep/arm-test: ep/arm-base and a core change, dispatched with `base: ep/arm-base`, so the build.yml commit is outside the compared changes;
   - ep/arm-x86: master and the same core change, dispatched with `base: master`.
2. One dispatch of ep/arm-test and one of ep/arm-x86, with `tests` empty, warm their caches.
3. Ten dispatches per branch follow, alternating between ep/arm-test and ep/arm-x86; a dispatch starts after the previous run completes.
4. Recorded per dispatch:
   - job duration, from the jobs API;
   - "Build CLI" duration;
   - "Run tests" duration and conclusion;
   - "Finished in" from the log.
5. One dispatch of ep/arm-test after a Kotlin change, and one after a packages change.
6. The three branches are deleted.

Decision rule: ubuntu-22.04-arm is adopted as the runner of the reduced job when all four hold over the ten pairs:
1. the median of "Run tests" on aarch64 is at most the x86_64 median;
2. the median job duration on aarch64 is at most the x86_64 median;
3. failed "Run tests" steps on aarch64 are at most those on x86_64;
4. the Kotlin and package steps of procedure step 5 succeed.

Adoption is a separate pull request; it includes -O0 caches of aarch64 on master pushes (`cache_o0` is false in build-linux-push, build.yml:760).

Cost: 24 dispatches of one Linux job on the public fork.

## Validation

1. `python3 scripts/ci/test_packages_release.py` passes.
2. The draft pull request of these changes in the main repository has this description block:
   ````
   ```ci-tests
   /SimpleX chat markdown/
   ```
   ````
   GitHub runs:
   - variables and maybe-release;
   - build-linux, with these steps:
     - core build and the selected tests: "121 examples, 0 failures";
     - Kotlin;
     - scope ci-scripts;
   - packages.yml, with the addon job skipped;
   - cla.yml.
3. After it is marked ready, GitHub runs:
   - build-linux, with the whole suite;
   - build-linux-full;
   - build-linux-ghc8;
   - build-macos, 2 jobs;
   - build-ios;
   - build-windows;
   - packages.yml: the addon job, with the build job skipped (build plan `[]`, packages_release.py:510).
4. After the merge and the fork sync (good-git Q3), dispatches on fork branches, each with `base` set to its parent branch:

| Change | Inputs | Expected |
|---|---|---|
| core | `tests: /SimpleX chat markdown/` | build-linux; "121 examples, 0 failures" |
| core | `tests: /no such group/` | build-linux; "Run tests" fails with "all spec items have been filtered; failing due to --fail-on=empty" |
| apps/multiplatform | - | build-linux with the Docker and Gradle steps; cabal steps skipped |
| packages/simplex-chat-python | - | build-linux with the Node, Python and package steps; Docker steps skipped |
| apps/simplex-badge-service/web | `tests: /SimpleX badge service/` | build-linux; scope badge-web |
| apps/ios | - | build-ios only |

5. The durations of the first and the second dispatch of one branch (cold and warm) and of its Docker image step are recorded; they are inputs to Q2.

## Open questions

Q2. Fork cache seeding; the same question as good-git Q4. The fork's 64 caches are not restorable by branch dispatches, and fork master pushes write neither caches nor the Docker image (Warm cache).
- A. Per branch: the first dispatch of each branch runs an uncached build and an uncached image. Cost: one cold build per branch, duration unmeasured (Validation 5); workflow unchanged.
- B. On a push to the fork's master or stable, only the 22.04 entry of build-linux runs, as on a master push: -O2 build, tests, -O0 caches (build.yml:704-747) and the image cache (:312); the release steps of maybe-release (:156-217) are skipped when `github.repository != 'simplex-chat/simplex-chat'`. Cost: a condition on the other jobs and on the release steps; one Linux job of 18-30 min per sync (M9).
- C. Full matrix on fork syncs, with the same release-step condition. Cost: 9 jobs per sync, 3 of them macOS.
- Recommendation: B, as Q6 B of the simplexmq plan (PR evgeny-simplex/simplexmq#14). A costs a cold build for every branch; with C, the full matrix runs outside the expected triggers.

Q4. App workflow runs and app delivery. The app workflows are started only by hand (android-emu.yml:3-17, desktop-linux.yml:3-17, ios-sim.yml:3-13). A run includes:
- a plan job;
- a core job, when no earlier core artifact matches;
- an app job;
- a backend job, on the `backend` input;
- a claude job, on the `claude` input;
- a release job, on the `release` input (android-emu, desktop-linux).

The app is uploaded only for the Claude job, with retention 1 day (android-emu.yml:252-260, desktop-linux.yml:261-269, ios-sim.yml:257-265). In the fork, 12 app-workflow runs were dispatched on ep/llm-ux between 14:39 and 16:30 on 2026-10-25 (`GET /repos/evgeny-simplex/simplex-chat/actions/runs?branch=ep/llm-ux&event=workflow_dispatch`).
- A. App workflows run on the user's instruction only; with a new `upload` input (default off), the app is uploaded with retention 14 days. Cost: a user instruction per manual test; 3 lines per workflow.
- B. The agent dispatches the workflow of each changed app platform once before review, with upload on. Cost: 2-3 jobs per platform; 10-25 min, plus 25-45 min when the core changed; iOS on macOS (scripts/ci/README.md:31-32).
- C. pull_request triggers on app paths (the design of PR #8). Cost: 2-3 jobs per changed platform on every draft push, beyond the reduced build.
- Recommendation: A. B and C cost jobs in every review round.

Q5. build.yml in the ios globs (change 18). The user expects the macOS job only for iOS code changes; with build.yml in the globs, every build.yml change, each "Adding CI coverage" change included, runs build-ios (11.8 min median, M5).
- A. Keep build.yml in the ios globs. Cost: a macOS job on every build.yml change; the expectation is unmet.
- B. Remove it: the ios entry of change 18 becomes `["apps/ios/**", "scripts/ci/ios-stub-libs.sh"]`, and the expected set of test_packages_release.py:490-491 becomes `{"haskell", "kotlin"}`. Cost: a change to build-ios is compiled first on the master push (`ios=true` on branch pushes, change 5); 2 changed lines.
- Recommendation: B, applied in simplex-chat/simplex-chat#7870 (changes 1 and 18). With A, a macOS job runs for changes outside iOS code.
