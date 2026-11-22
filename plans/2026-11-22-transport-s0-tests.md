# S0: tests and measurement before the transport rework

## Scope

1. Reproduction tests of the open transport defects, marked pending until their fix lands.
2. Per-member delivery delay in groups of 20, 50 and 100 members, recorded as a baseline.
3. Crash-window tests with kill points behind a test-only build flag.
4. Commit benchmark of the store layouts.
5. Throughput and latency of event processing: PostgreSQL by pool size, RPC round trip under an event backlog.
6. Interoperation job: the released CLI against the new CLI.

The pin bump to simplexmq master is its own PR after simplex-chat/simplexmq#2082 merges.

## PRs

| PR | Repository | Contents |
|---|---|---|
| A | simplexmq | agent reproduction tests T1, T4, T6-T9, T13, T17, T18 |
| D | simplexmq | agent kill points behind a new flag `test_hooks`; tests T4k, T12, T22 |
| B | simplex-chat | chat reproduction tests T2, T3, T5, T20, T21; delay tests D1-D4; chat kill points behind `test_hooks` (added by #8284); benchmarks B1-B3 |
| C | simplex-chat | CI job: released CLI against the branch CLI |

Order: A, then D, then B on D's commit (DO NOT MERGE until D merges); C independent.
A merges after simplex-chat/simplexmq#2079: A then runs T1 and takes `receiveMsgs` from it; its `withPausedProxyOn` is defined with `withTCPForwarderOn` of A.

## Reproduction tests

Status:
- pending: the test asserts the fixed behaviour and is marked pending until its fix.
- master: the test asserts master's behaviour, because the fixed behaviour requires an interface of the fix; the fix changes the assertion.
- passes: the test passes on master and guards the behaviour.

| Id | Defect | Repository | Asserts | Status |
|---|---|---|---|---|
| T1 | three threads wait on each other (ICAck worker, subscriber, chat send) | simplexmq | sendMessages returns and every flooded message arrives within 10 s | pending until simplex-chat/simplexmq#2079 |
| T2 | group leave holds the group lock across blocking queue writes | simplex-chat | the command returns; a direct message is shown within 10 s | pending |
| T3 | HELLO acknowledged before the chat handles CON | simplex-chat | after a stop between them, B and C connect and pending group messages are sent | pending |
| T4 | queue pending after a stop before ACK | simplexmq | after the agent restarts, with and without a server restart: queue active, message redelivered, ACK empties the queue | passes |
| T4k | queue pending after a kill before ACK | simplexmq | as T4, after a kill at the kill point | passes |
| T5 | backlog after an upgrade | simplex-chat | every message of 500 in a 50-member group is processed | pending |
| T6 | queue rotation waits for the peer without a deadline | simplexmq | master: the switch stays in RSSendingQADD without commands or deliveries; fixed: it ends with an error after the deadline | master |
| T7 | moveable command retried forever after host errors | simplexmq | master: the command stays after 2 s of retries; fixed: ERR after an age limit, and the command is deleted | master |
| T8 | ICQDelete retried forever | simplexmq | the old queue is abandoned after deleteErrorCount failures; the switch completes within 10 s | pending |
| T9 | dead connection kept for 15 minutes | simplexmq | reconnect and receipt within 10 s after forwarding stops | pending |
| T12 | IPv4 not tried after an IPv6 timeout | simplexmq | connection succeeds within tcpConnectTimeout | pending |
| T13 | network reported offline without validation | simplexmq | delivery waits userNetworkInterval, then the message is sent | passes |
| T17 | chunk deadline assumes a minimum throughput | simplexmq | RFDONE or RFERR within 25 s at 512 KB/s | pending |
| T18 | retry reuses the replica record read before the first attempt | simplexmq | the file completes with 3 recipients after the first upload is cut | pending |
| T20 | cancelled upload never reported to the recipient | simplex-chat | the recipient's item ends cancelled | pending |
| T21 | group leave interrupted between the agent call and the member status | simplex-chat | every member receives the leave, or none | pending |
| T22 | delivery events queued before the delivery row is deleted | simplexmq | after a kill between them, SENT is received once | pending |

T6, T7, T8, T17 and T20 assert deadlines (decision D6: every unfinished state gets one); durations per state in each test.

## Delay tests

Setup:
- in-process SMP servers with queue quota 16
- retry intervals scaled: initialInterval, increaseAfter and maxInterval together
- groups of 20, 50 and 100 members

| Id | Scenario | Measured |
|---|---|---|
| D1 | member X offline while more than 16 messages are sent | per member: send to SENT, created_at minus item_ts, MWARN count, time to QCONT |
| D2 | stop between the quota counter reset and the pending send | pending messages left after restart |
| D3 | messages forwarded or relayed to an inactive member | messages never delivered |
| D4 | the chat store busy for one message of member X | stall until resubscription |

Output per test: p50, p95 and max delay; messages never delivered; recovery time after restart.

B runs D1-D4 twice: with simplexmq before simplex-chat/simplexmq#2079, and with the simplexmq commit of D.

## Kill points

Flag: `test_hooks` in both packages, manual, default off; CI enables it in builds other than v* tags, as #8284 does for the chat.

| Point | Window |
|---|---|
| chat: after the chat write, before the agent call | Wa |
| chat: after the agent call, before the chat write | Wb |
| agent: after commit, before the event is queued | We |
| agent: after the event is queued, before the delivery row is deleted | Wd |
| agent: after the network request, before its result is stored | Wn |

One process-level test kills a child committing to both SQLCipher files with SIGKILL and checks a cross-file invariant after reopen.

## Benchmark

| Id | Layouts | Transaction classes |
|---|---|---|
| B1 | two stores; one connection with the agent file attached; three connections | chat-only, agent-only, combined |

Measured: p50 and p99 commit latency; with two processes on the same files, the busy rate.

| Id | Setup | Measured |
|---|---|---|
| B2 | PostgreSQL client with pool size 1, 4 and 10; 50 groups exchanging messages | events handled per second; one event thread against one worker per agent connection |
| B3 | a service request while a 100-member group fills the event queue | round-trip time of the reply, p50 and p99 |

```mermaid
flowchart LR
  P["S1: simplexmq#2079"] --> A["A: simplexmq reproduction tests"]
  A --> D["D: simplexmq kill points"]
  D --> B["B: chat tests, delay tests, benchmark"]
  C["C: interoperation job"]
  B --> M["S1 measured: delay tests before and after simplexmq#2079"]
```
