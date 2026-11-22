# Badge cross-version tests

Repository: simplex-chat/simplex-chat.
Branch: `ep/names-review-fixes-r4`, the follow-up of #8243.
Base: `ep/names-review-fixes` at `b44093d9c` (#8243).
Pin: master `abc483d9d`, the merge base of #8243 and of this branch.

The owner's words:

> why it touches badge code we agreed not to touch? anything else changes badge code that badly?

> I think changes affecting ONLY badges must be reverted in this PR, this PR was about names. The rest should be very carefully reviewed.

> could we maybe run cross-version badge tests somehow?

> I propose both A and B - CLI from master talking to service from 8243 (after we complete it). The opposite is not important - new clients won't talk to old service, and this branch doesn't change client anyway (other than via shared types).

## Composition

```mermaid
flowchart LR
  subgraph PIN["pin abc483d9d"]
    MS["service writes<br>BadgeService.Store<br>BadgeService.Store.Invoices"]
    MJ["protocol JSON<br>Simplex.Chat.Badges.Service"]
    MP["badge page<br>web/src/api.ts"]
    MC["simplex-chat CLI<br>with scripts/ci/badge-compat/Main.hs"]
  end
  subgraph HEAD["branch head"]
    NM["migration 20261013_names"]
    PT["Simplex.Chat.StoreService"]
    WA["StoreService.Web.Server<br>StoreService.Web.Http"]
    SS["store service<br>StoreService.Service"]
  end
  MS -->|"A1: rows, then the migration, then reads and flows"| NM
  MJ -->|"A2: fixture recorded once"| PT
  WA -->|"A3: recorded answers"| MP
  MC <-->|"B: requests over SimpleX"| SS
```

| Part | Test | CI job | CI step | Backend |
|---|---|---|---|---|
| A1 | `Bots.StoreService.BadgeCompatTests`, "master rows" | build-linux | Run tests, when selected | SQLite |
| A1 | the same | test-store-postgres | Run store tests | PostgreSQL |
| A2 | `BadgeTests`, "service protocol JSON" | build-linux | Run tests, when selected | - |
| A3 | `web/test/service-refusals.test.ts`<br>`web/test/service-answers.test.ts` | build-linux | Test changed scopes, scope badge-web | - |
| B | `Bots.StoreService.BadgeCompatTests`, "master CLI" | build-linux | Test changed scopes, scope badge-compat | SQLite |

## Pin

- `scripts/ci/badge-compat.sh` holds `MASTER`, the full hash of `abc483d9d`.
- `git diff v7.1.0 abc483d9d -- src/Simplex/Chat/Badges src/Simplex/Chat/Store/Badges.hs src/Simplex/Chat/PaymentService.hs src/Simplex/Chat/PaymentService` is empty.
- `git diff abc483d9d ddcdc1b50 -- src/Simplex/Chat/Badges src/Simplex/Chat/Store/Badges.hs src/Simplex/Chat/PaymentService.hs src/Simplex/Chat/PaymentService apps/simplex-badge-service` is empty.
- `git diff v7.1.4 abc483d9d -- apps/simplex-badge-service/web` is empty.

## A1. Master's badge rows under the names migration

Module: `tests/Bots/StoreService/BadgeCompatTests.hs`.
Registered in tests/Test.hs under "SimpleX store service e2e", as `describe "master compatibility"`.

Sequence:
1. The service's chat database is created, as `withStoreServiceVerifierIO` creates it.
2. The service migrations of `storeServiceSchemaMigrations` up to `20261012_badge_subscriptions` are applied by `migrateDBSchema` with the table `sx_badge_service_migrations`, as `runStoreServiceMigrations` applies them.
3. The rows are inserted by master's statements.
4. The service is started on the database; `runStoreServiceMigrations` applies `20261013_names`.
5. Every row is read back.
6. Each flow is run on the migrated rows.

`withSeededStoreService` is `withStoreServiceVerifierIO` with the seed of steps 2 and 3 as a parameter, given the service's options and issuer key; `withStoreServiceVerifierIO` calls it with a seed that writes nothing, and its callers are unchanged.

Master's statements:
- the SQL text of each writer below, copied from the pin, with the pin's CPP branches for PostgreSQL;
- values of app types as literal texts of the pin's encoders, listed below;
- timestamps, integers and bytes as values of the database library;
- credentials as JSON of credentials issued with the test issuer key.

`Store`, `Store.Invoices` and `Catalog` are `BadgeService.Store`, `BadgeService.Store.Invoices` and `BadgeService.Catalog` at the pin, and `StoreService.Store` and `StoreService.Store.Invoices` on the branch.

Encoders of the literal texts, at the pin:
- `Store.Invoices.invoiceStatusText`
- `Store.Invoices.paymentStatusText`
- `Store.Invoices.itemStatusText`
- `Store.Invoices.cryptoCurrencyText`
- `Simplex.Chat.Badges.Ledger.entryTypeColumns`
- `textEncode` of `BadgeType`
- `textEncode` of `BadgeCodePaymentStatus`
- `textEncode` of `BadgePurchaseStatus`
- `textEncode` of `PaymentProvider`
- `textEncode` of `SubscriptionState`

| Table | Writer at the pin | Rows |
|---|---|---|
| badge_prices | `Store.Invoices.seedCatalog` | the prices of `Catalog.defaultCatalog` |
| badge_offers | `Store.Invoices.seedCatalog` | the offers of `Catalog.defaultCatalog` |
| badge_codes | `Store.insertBadgeCode` | free, single use, redeemed |
| badge_codes | `Store.insertBadgeCode` | paid, three uses, one redeemed |
| badge_codes | `Store.insertBadgeCode` | free, revoked by `Store.revokeCode` |
| badge_codes | `Store.Invoices.createInvoiceRows` | unpaid, of an open invoice |
| badge_codes | `Store.Invoices.markCodePaid` | paid, its deadline passed |
| badge_codes | `Store.setCodeGroupItem` | with a group item |
| invoices, badge_code_invoices | `Store.Invoices.createInvoiceRows` | btc, open |
| invoices, badge_code_invoices | `Store.Invoices.createInvoiceRows` | xmr, part paid |
| invoices, badge_code_invoices | `Store.Invoices.createInvoiceRows` | card, paid by `updateInvoiceStatus` |
| invoices, badge_code_invoices | `Store.Invoices.createInvoiceRows` | btc, expired by `expireOverdue` |
| invoices, badge_code_invoices | `Store.Invoices.createInvoiceRows` | card, cancelled by `cancelOpenInvoice` |
| payments | `Store.Invoices.upsertPayment` | the xmr part payment |
| payments | `Store.Invoices.upsertPayment` | the card payment, settled |
| payments | `Store.createStorePurchase` | google, one time |
| payments | `Store.createStorePurchase` | google subscription, with a token |
| payments | `Store.createStorePurchase` | apple subscription |
| payments | `Store.stampSubscriptionCheck`<br>`Store.setSubscriptionState` | the apple subscription, checked, cancelled |
| payments | `Store.rebindStorePayment` | the google subscription, moved |
| badge_purchases | `Store.createCodePurchase` | of the redeemed codes |
| badge_purchases | `Store.createStorePurchase` | of the store payments |
| badge_purchases | `Store.rebindStorePayment` | the moved subscription's new purchase |
| badge_purchases | `Store.setPurchaseBadgeType` | the apple purchase, legend |
| badge_ledger | `Store.appendLedgerPlan` | every credit type and every debit type |
| badge_issuances | `Store.appendLedgerPlan` | a current and a past month |
| subscription_charges | `Store.insertSubscriptionCharge` | an apple and a google charge |
| group | `Store.insertManagedGroup`<br>`Store.markOwnerBootstrapped` | one group, owner set up |

Read back after the migration:

| Table | Reader on the branch | Checked |
|---|---|---|
| badge_prices<br>badge_offers | `Store.Invoices.readCatalogRows` | every row, equal to the inserted values |
| badge_codes | `Store.getBadgeCode`<br>`Store.getCodeTracker` | every field of every code |
| invoices | `Store.Invoices.getInvoice` | every invoice, product badge |
| invoices | `Store.Invoices.getInvoiceByProviderRef` | every provider ref of badge_code_invoices |
| invoices | `Store.Invoices.unpaidRefs` | every invoice other than the paid one |
| payments | `Store.getStorePaymentCredit`<br>`Store.getPurchaseSubscription` | every store payment |
| badge_purchases | `Store.getPurchaseByKey`<br>`Store.getCodePurchaseForKey` | every purchase key |
| badge_ledger | `Store.getLedgerEntries` | every entry, equal to the inserted entries |
| badge_issuances | `Store.getCurrentIssuance` | the current credential |
| subscription_charges | `Store.getSubscriptionCharge` | both charges |
| group | `Store.getManagedGroup` | the group |
| all | `Store.badgeCounts` | the counts of the inserted rows |

Flows on the migrated rows:

| Flow | Request | Checked |
|---|---|---|
| the redeemed single-use code again, by its purchase key | `serviceCmd` redeemBadgeCode | the stored credential and statement |
| the second use of the three-use code | `serviceCmd` redeemBadgeCode | a credential; redeem_count 2 |
| the revoked code | `serviceCmd` redeemBadgeCode | code_invalid |
| the code past its deadline | `serviceCmd` redeemBadgeCode | code_expired |
| renewal of a code purchase, current month | `serviceCmd` issueBadge, the stored tip | the stored credential |
| renewal one month later, by `setClockAt` | `serviceCmd` issueBadge | a new credential and its rows |
| the google one-time payment again, by its purchase key | `serviceCmd` purchaseBadge | the stored credential |
| the moved subscription, old key | `serviceCmd` issueBadge | credential absent, subscription ended |
| the open btc invoice | `webApp` GET /api/invoice/{id} | its view |
| the open btc invoice settled | the provider's settled answer, one poller pass | status paid, its code paid |
| the part paid xmr invoice | `webApp` POST /api/invoice/{id}/cancel | funded |
| a revoke of the three-use code | `//revoke` | revoked, one use left unspent |

The web flows use `withListener` of WebTests over the service's store, with WebTests' `stubProvider` for crypto and for card invoices, as WebTests' poller tests do.

## A2. Protocol messages recorded from master

Fixture: `tests/fixtures/store-service/badge-protocol.json`.
Test: tests/BadgeTests.hs, group "service protocol JSON", item "encodes and decodes every message a released client sends or reads as master does".

The test:
- builds each message from fixed keys, codes, times, credential bytes and texts;
- writes the object of all messages by `writeFixture`, whose `testGenerate` fails on a difference;
- decodes each message of the file with the branch's types and checks that its encoding equals the file's value.

Messages, by key:

| Key | Message |
|---|---|
| redeemBadgeCode | request, version 1, purchaseKey, redeemBadgeCode |
| purchaseBadge.google | request, purchaseBadge, google payment |
| purchaseBadge.apple | request, purchaseBadge, apple payment |
| transferBadge.google | request, transferBadge, google payment |
| transferBadge.apple | request, transferBadge, apple payment |
| upgradeBadgeSubscription | request, upgradeBadgeSubscription, apple payment, balance |
| issueBadge | request, issueBadge, balance |
| badgeCredential.full | answer, credential, receipt, statement of every entry type, subscription renewing |
| badgeCredential.empty | answer, credential and receipt absent, previousEntryId |
| badgeCredential.subscription.{state} | answer for each of `SSRenewing`, `SSCancelled`, `SSBillingRetry`, `SSEnded`, `SSUnknown` |
| error.{code} | answer for each error code of the pin, and an unknown code |
| error.retryAfter | answer with message and retryAfter |

Recorded once from the pin:
1. Fork branch `ep/badge-protocol-master` from `abc483d9d`.
2. Its commit: the same test with the pin's names (`BadgeServiceRequest`, `BSC`, `BSP`, `BSE`), and the fixture file, empty.
3. A dispatch of build.yml with tests `/Supporter badges/service protocol JSON/`: the test writes the fixture and fails on the empty file; the artifact `generated-files-ubuntu-22.04-ghc9.6.3` holds the fixture.
4. The fixture committed on `ep/badge-protocol-master`; a second dispatch passes.
5. The same file committed on this branch.
6. The pull request links both runs.

## A3. Master's badge page on the branch's answers

Fixtures, recorded in WebTests by `responseFixture` and `storeFixture` into tests/fixtures/store-service/rest-api:

| Fixture | Answer |
|---|---|
| badge-created-btc | POST /api/invoice, btc |
| badge-created-xmr | POST /api/invoice, xmr |
| badge-created-card | POST /api/invoice, card |
| badge-view-open-btc | GET /api/invoice/{id}, open |
| badge-view-partial-btc | GET, part paid |
| badge-view-processing-btc | GET, paid in full, confirming |
| badge-view-paid-btc | GET, paid |
| badge-view-expired-btc | GET, expired |
| badge-view-open-card | GET, card, open |
| badge-view-paid-card | GET, card, paid |
| badge-cancelled | POST /api/invoice/{id}/cancel, expired |
| read-not-found | GET, unknown invoice |
| read-rate-limited | GET over the read limit |
| read-holds-full | GET with wait while every hold is taken |

- invoiceId is written as "invoice".
- expiresAt and settledAt are written as "1970-01-01T00:00:00Z", as `stableJSON` writes times.
- The refusal fixtures of service-refusals.test.ts are kept.

Tests, compiled against either page:
- `web/test/service-refusals.test.ts`: each refusal rejects with its recorded code, status and Retry-After.
- `web/test/service-answers.test.ts`: `createInvoice` returns the recorded fields of each created invoice for its method; `readInvoice` returns the recorded status and fields of each view; `waitForChange` from open returns the paid view; `cancelInvoice` returns the expired view; read-not-found rejects as not_found; read-rate-limited and read-holds-full reject as rate_limited with their Retry-After.
- Both read the fixtures from `STORE_FIXTURES`, else from ../../../tests/fixtures/store-service/rest-api.
- Both import only `createInvoice`, `readInvoice`, `cancelInvoice`, `waitForChange`, `ApiError` and `timedTest`, which the pin's page exports.

`scripts/ci/badge-compat.sh page`:
1. `git fetch -q --depth=1 origin "$MASTER"`.
2. `git archive "$MASTER" apps/simplex-badge-service/web` unpacked into `$RUNNER_TEMP/badge-compat/page`.
3. The two test files copied into its `test/`.
4. `npm ci`, `npx tsc -p tsconfig.json`, `npx tsc -p tsconfig.test.json`.
5. `STORE_FIXTURES=<branch fixtures> TZ=UTC node --test build/test/service-refusals.test.js build/test/service-answers.test.js`.

First result on `1130173af`: every refusal other than the 404 answers reads as unknown; the pin's `decodeError` reads `error`, and `jsonError` of StoreService.Web.Http writes `type`.

## B. Master's CLI against the store service

### Client

`scripts/ci/badge-compat/Main.hs` replaces apps/simplex-chat/Main.hs of the pin's tree.
It runs `simplexChatCLI cfg (Just simplexChatServer)` with `cfg` = `terminalChatConfig` and:

| Field | Value |
|---|---|
| badgeServiceAddress | `STORE_SERVICE_ADDRESS` |
| badgePublicKeys | `BADGE_ISSUER_KEY`, `<index>:<base64url key>` |
| shortLinkPresetServers | `SMP_PRESET_SERVER` |
| badgeCurrentTime | the current time plus the seconds in the file `BADGE_CLOCK_FILE` |
| badgeDevRequests | True |

Arguments of each process:
- `-d <test dir>/<name>`
- `-s smp://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=:server_password@localhost:<SMP port>`
- `-p <WebSocket port>`
- `--user-display-name <name>`
- `--yes-migrate`

`scripts/ci/badge-compat.sh client`:
1. `git fetch -q --depth=1 origin "$MASTER"`.
2. `git archive "$MASTER"` unpacked into `$RUNNER_TEMP/badge-compat/master`, its dist-newstyle kept.
3. The harness copied over apps/simplex-chat/Main.hs.
4. cabal.project.local written as the step "Prepare cabal.project.local" writes it.
5. `docker exec -w $RUNNER_TEMP/badge-compat/master builder cabal build -j --ghc-options=-O0 exe:simplex-chat`.
6. The binary copied to `$RUNNER_TEMP/badge-compat/simplex-chat-master`.
7. `MASTER_CLIENT_BIN=$RUNNER_TEMP/badge-compat/simplex-chat-master ./simplex-chat-test -m "/SimpleX store service e2e/master compatibility/master CLI/"`.

### Service and driver

- `describe "master CLI"` in `Bots.StoreService.BadgeCompatTests`.
- Each item is pending without `MASTER_CLIENT_BIN`, with the reason "scripts/ci/scope-tests.sh badge-compat runs it".
- The SMP server is the one of `testBracket`.
- The service is started by `withStoreServiceEnv`, with the fake store's verifier of tests/Bots/StoreService/FakeStore.hs, the test issuer key and `TestClock`.
- Codes are issued by `issueCodeAs`.
- `STORE_SERVICE_ADDRESS` is the service's short link, `bsAddress`.
- `BADGE_ISSUER_KEY` is the key of `badgePublicKeys` of `bsClientCfg`.
- The clock file holds the offset of `bsClock`; `setClockAt` and the file are moved together.
- Master's CLI processes are started by `System.Process`, one per device.
- Commands are sent as `{"corrId": "<n>", "cmd": "<command>"}` over the CLI's WebSocket API, `runChatServer` of apps/simplex-chat/Server.hs, by the `websockets` client, added to the test suite's dependencies.
- A response is the message with its corrId; events are the messages without one.
- The service's rows are read in the test process, by `ledgerRows` and the store readers.

### Flows

| # | Device, user | Commands of master's CLI | Request to the service | Service setup | Checked |
|---|---|---|---|---|---|
| B1 | A, 1 | `/_redeem_badge_code 1 <code>` | redeemBadgeCode | supporter, months 2, free | badgeRedeemed, newBadge true, supporter; the short link resolved |
| B2 | A, 1 | `/_badge ledger 1 <purchase id>` | - | B1 | entries equal the service's ledger rows |
| B3 | A, 1 | `/_redeem_badge_code 1 <code>` again | redeemBadgeCode | B1 | badgeRedeemed, newBadge false |
| B4 | A, 1 | `/_redeem_badge_code 1 <valid code never issued>` | redeemBadgeCode | - | badgeRedeemError, serviceError code_invalid |
| B5 | A, 2 | `/create user alisa`, `/_redeem_badge_code 2 <code of B1>` | redeemBadgeCode | B1 | serviceError code_used |
| B6 | A, 2 | `/_redeem_badge_code 2 <code>` | redeemBadgeCode | an unpaid code marked paid with a deadline in the past, as testExpiredCode marks it | serviceError code_expired |
| B7 | A, 1 | `/_badge request 1` | issueBadge, the client's tip | B1 | badgeState, the same expiry; the ledger unchanged on both sides |
| B8 | A, 1 | the clock moved one month; `/_badge request 1` | issueBadge | B1 | badgeState, the next month's expiry; both ledgers equal |
| B9 | B, 1 | `/_badge invoice 1`, `/_badge purchase 1 invoice=<id> <supporterPlay>`, `/_badge state 1` until credited | purchaseBadge, google | the fake store's Play token | badge supporter; storePurchases empty; one purchase on the service |
| B10 | B, 2 | `/create user bob2`, `/_badge purchase 2 <subscriptionPlay>` | purchaseBadge, google subscription | the fake store's subscription token | badge supporter, subscription renewing |
| B11 | C, 1 | `/_badge purchase 1 restored <subscriptionPlay>` | transferBadge | B10 | badge on C; `/_badge request 2` on B retires the badge, subscription ended |
| B12 | C, 2 | `/create user cath2`, `/_badge purchase 2 <Apple supporter subscription JWS>`, then `/_badge purchase 2 <Apple legend subscription JWS>` while it is shown | purchaseBadge, apple; upgradeBadgeSubscription | the fake store's Apple subscription, reported legend, as testAppleTierChangeHandOver reports it | badge legend; both ledgers equal |
| B13 | A, 1 | `/_service_request 1 <address> {"version":1,"request":{"type":"pauseBadge"}}` | pauseBadge | - | `{"code":"unsupported_version","type":"error"}` |
| B14 | A, 1 | `/_service_request 1 <address> {"version":2,"request":{"type":"issueBadge"}}` | issueBadge, version 2 | - | unsupported_version |

Items:

| Item | Flows |
|---|---|
| "redeems codes and reads the service's refusals as master does" | B1 to B6 |
| "renews a code badge within its month and in the next" | B7, B8 |
| "credits a Play purchase handed over with its invoice" | B9 |
| "moves a Play subscription to a new device" | B10, B11 |
| "grants an Apple tier change while the badge is shown" | B12 |
| "answers unsupported versions and commands" | B13, B14 |

### Sequence

```mermaid
sequenceDiagram
  participant S as Test changed scopes
  participant D as builder container
  participant T as simplex-chat-test
  participant V as store service, branch
  participant P as SMP server
  participant M as master CLI
  S->>S: git fetch, git archive of the pin, harness Main.hs
  S->>D: cabal build exe:simplex-chat at -O0
  D-->>S: simplex-chat-master
  S->>T: MASTER_CLIENT_BIN, -m "master CLI"
  T->>P: started by testBracket
  T->>V: started: fake store verifier, test issuer key, TestClock
  V->>P: address created
  T->>V: //issue supporter months 2 free
  T->>M: started: address, issuer key, preset server, clock file, -p
  T->>M: /_redeem_badge_code 1 code, over WebSocket
  M->>P: short link resolved
  M->>V: redeemBadgeCode
  V-->>M: badgeCredential
  M-->>T: badgeRedeemed
  T->>T: client ledger and service ledger compared
  T->>V: setClockAt plus one month
  T->>M: clock file plus one month, /_badge request 1
  M->>V: issueBadge with the tip
  V-->>M: badgeCredential, next month
  M-->>T: badgeState
  T->>M: stopped
  T->>V: stopped
```

### #8243's final head

1. Fork branch `ep/badge-compat-8243` from #8243's final head.
2. The diff of this branch's B commits applied by `git apply`, and committed.
3. One dispatch of build.yml with base `names` and no tests.
4. The run's link given to the owner before #8243 merges.

## CI

Scope `badge-compat`, as scripts/ci/README.md "Adding CI coverage" states:

| File | Change |
|---|---|
| scripts/ci/packages_release.py | `SCOPE_CHANGES["badge-compat"]`, after badge-web |
| scripts/ci/packages_release.py | `BUILD_CHANGES["haskell"]`: scripts/ci/badge-compat/** |
| .github/workflows/build.yml | each glob of the scope in `on.pull_request.paths` |
| scripts/ci/scope-tests.sh | case `badge-compat)`: `scripts/ci/badge-compat.sh client`; the name in the usage line |
| scripts/ci/scope-tests.sh | case `badge-web)`: `scripts/ci/badge-compat.sh page` after `npm test` |
| scripts/ci/test_packages_release.py | a ChangesTest case for src/Simplex/Chat/Badges/Types.hs; the two store service cases print badge-compat |
| scripts/ci/README.md | subsection "badge-compat"; subsection "badge-web" with the page step |
| simplex-chat.cabal | `websockets` in the test suite; module `Bots.StoreService.BadgeCompatTests` |

Globs of badge-compat:
- apps/simplex-store-service/src/**
- src/Simplex/Chat/StoreService.hs
- src/Simplex/Chat/Badges/**
- src/Simplex/Chat/PaymentService.hs
- src/Simplex/Chat/PaymentService/**
- tests/Bots/StoreService/**
- scripts/ci/badge-compat.sh
- scripts/ci/badge-compat/**
- cabal.project

Steps of build-linux, conditioned on `contains(needs.maybe-release.outputs.scopes, 'badge-compat')`:

| Step | Place | Action |
|---|---|---|
| Restore the pinned client build from cache | before "Test changed scopes" | `actions/cache/restore@v4`, path `${{ runner.temp }}/badge-compat/master/dist-newstyle`, key `badge-compat-<dist key>-<hash of the script and the harness>`, restore key `badge-compat-<dist key>-` |
| Save the pinned client build to cache | after "Test changed scopes" | `actions/cache/save@v4` of the same path and key, when the restore missed the key |

Time:

| Part | Added |
|---|---|
| A1 | about 1 minute per backend |
| A2 | seconds |
| A3 | about 1 minute |
| B, first run of a branch or pull request | the pinned core built, about 25 minutes, and the items, about 4 minutes |
| B, later runs | the build restored and the harness relinked, about 2 minutes, and the items |

## Acceptance

- A2: the second run on `ep/badge-protocol-master` passes on the recorded fixture; this branch's run passes on the same file.
- A1: passes in "Run tests" with `/SimpleX store service e2e/master compatibility/master rows/` and in "Run store tests" of test-store-postgres.
- A3: fails on `1130173af`, every refusal other than the 404 answers read as unknown by the pin's page; passes after the refusal body the owner decides; the branch's page passes on the same fixtures.
- B: passes on this branch's head and on `ep/badge-compat-8243`.
- Mutation, on throwaway fork branches: `statement` of badgeCredential renamed fails A2 and B; the names migration without the provider ref copy from badge_code_invoices fails A1.
- The pull request links each run.

## Outside these tests

- The apps' Swift and Kotlin code: the apps run the core that the CLI runs.
- Apple's and Google's verification: the fake store's verifier answers.
- BTCPay and Stripe: their fakes answer A1; A3 reads recorded answers.
- B on PostgreSQL: A1 runs the migrated rows on PostgreSQL.
- The production address on smp5.simplex.im, private routing and real networks: one local SMP server.
- The operators' console and group commands.
- Months of real time: one clock offset, moved by the test.
- Master's client on rows that master's service wrote: B starts on a new database; A1 sends the branch's requests.
- The service worker of a browser across the deploy: A3 runs the page's API module.
- The deployment's ini and image paths.
