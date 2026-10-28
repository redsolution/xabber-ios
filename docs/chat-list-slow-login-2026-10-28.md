# Slow chat list after fresh login — 2026-10-28

## Result

The delay is confirmed and remains unresolved. No app behavior or production source changed. Recent logout/archive commits do not change XEP-SYNC page size or request scheduling. The October 6 first-response latency follow-up was already open.

## Supplied runtime evidence

Times are Asia/Yekaterinburg (+05:00). Original XML, credentials and message contents are not copied here.

| Boundary | Time / duration |
| --- | --- |
| Login begins | 16:06:33.190 |
| First sync enqueue | 16:06:36.408 |
| First sync did-send callback | 16:06:37.123 |
| Last initial inbound presence | 16:06:37.234 |
| Next inbound callback, devices result | 16:06:52.248 |
| First sync result correlation | 16:06:56.172 |
| First sync XML log / parser entry | 16:06:56.179 / 56.182 |
| First page preparation / Realm apply | approximately 20 ms / 51 ms |
| First page dataset apply complete | 16:06:56.576; 35 rows; dataset work 142 ms |
| Second request enqueue | 16:06:56.253; continuation gap 0 ms |
| Second sync parser entry / Realm apply | 16:07:00.803 / 29 ms |
| Second page dataset apply complete | 16:07:01.355; 66 rows |

The first sync callback wait is approximately 19.05 seconds from did-send to correlation, or 19.77 seconds from enqueue to parser entry. The second enqueue-to-parser interval is approximately 4.55 seconds. These are client callback intervals, not proven pure server/network time.

All primary incoming callbacks pause for approximately 15 seconds while main/lifecycle and HTTP callbacks continue. Devices and a push error arrive first, followed by MAM/rewrite traffic. First-page apply reports 36 created, 1 updated, 3 skipped and 0 failures. The log ends with page three outstanding; full completion is unobserved.

## History and constraints

`9cae2c79` (October 6) changed pages from 15 to 40 and repaired profile hydration, explicitly leaving an earlier 11.85-second first-response delay open. Current `pageSize` remains 40. The latest `bd13ffb9` changes account deletion and immutable list mapping; `f2d5fec0` does not change the sync manager. `b9cc58b9` changes opaque archive IDs and `c7f8f0ad` preview dates/identity. None establishes a scheduling regression for this incident.

The list displays the first page before snapshot completion. Final stamps remain final-page-only. The old cross-file bootstrap send gate was deliberately removed by `1e38c621`; restoring it speculatively would conflict with current list-only/archive isolation. Preserve full XML logging policy; measured first-result logging/routing is approximately 10 ms.

## Attribution gap

There is no independent socket-receipt timestamp or stream-queue lag measurement. Server/network silence and client stream/delegate blocking cannot be distinguished from this log.

Read-only inspection of the local server checkout found devices GET performs synchronous SQL through local IQ routing in the c2s process (`mod_devices.erl`, `get_user_devices` / `sql_select_user_devices`). A slow call can hold delivery of other responses, including a sync result computed by a spawned worker. This is a candidate only: no server runtime timing, SQL trace or deployed-source equivalence was verified. Push returned 400/modify/bad-request; its local error branch does not demonstrate a 15-second wait. The client push timeout alone does not establish cause.

The next discriminating evidence is a correlated c2s/devices/SQL/sync trace or client socket-versus-account-queue timing during login. Account resets, crypto changes and speculative pagination changes are unwarranted by this evidence.

## Verification

Cached Debug test action, iOS 26.0 Simulator, Xabber Development iPhone 16 Pro (`91E09D3E-4BBC-4431-9EAF-14D2410E7B98`), isolated storage, autoconnect disabled, code signing disabled:

- `ClientSynchronizationPaginationTests.testFreshSnapshotUsesFortyItemPagesAndTrackedMaximumForFinality`
- `testIncrementalSyncUsesFortyItemPageSize`
- `testColdRelaunchRecoversMissingListPreviewWithFreshFortyItemPage`
- `testInitialSnapshotRequestsAndAppliesAllThreePagesBeforeCompletion`
- `testInitialSnapshotAppliesThreeHundredTwoConversationFixtureAcrossAllPages`
- `LastChatsViewControllerBehaviorTests.testBootstrapDatasetUpdatePolicySuppressesExpensiveAnimatedWorkOnlyDuringBootstrap`

6/6 passed; app, push extension and test targets built with no compiler/linker errors. These fixtures protect existing pagination/presentation behavior; they do not validate live latency. No separate build or cache reset.

## Concurrent traffic audit

For 16:06:37.123 → 16:06:56.172, excluding the initial sync request/result, logged outgoing application stanzas total 40 IQ + 1 available presence:

- 26 OMEMO2 bundle queries, 7 OMEMO2 device-list queries, 2 trustsharing queries.
- 2 account-device-list queries, 1 push enable, 1 rewrite query, 1 IQ result.

Incoming application stanzas total 109: 62 presence (6 subscribe, 21 available, 35 remote-server-timeout errors), 10 MAM invite-recovery results, 33 PubSub headline events and 4 IQ replies (devices result, push bad-request, MAM fin, rewrite result). Headline events comprise 19 avatar metadata, 7 OMEMO device lists, 5 OMEMO bundles and 2 trustsharing. The MAM recovery request was sent before this interval.

Separate SM activity: ack sends at 37.168 and 52.301, ack request at 37.254, no logged stream_management_ack_received in the interval. A liveness ping was suppressed because an SM ack was already outstanding; timeout diagnostics are not wire stanzas. Two HTTP cloud-stats requests completed during the interval.

Traffic is not uniformly distributed: after incoming subscriptions end at 37.234, no incoming callback occurs until 52.250; then replies, presence/PubSub and new OMEMO queries run before sync reaches the callback at 56.172. Concurrent background traffic is established; its causal contribution to the delay is not quantified.
