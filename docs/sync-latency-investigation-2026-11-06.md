# Startup and chat synchronization latency investigation — 2026-11-06

The physical iPhone repeats a full six-page chat-list synchronization, while the client performs substantial recents projection and diagnostic work. Chat synchronization and first visible history are different boundaries: the original successful video shows real messages approximately 100 ms after visible navigation starts, while the native fresh verified content receipt arrives after 2.295 s. No production fix was made during this investigation.

## Evidence and interpretation

- Installed `xabber.ios` on the wired iPhone 12 Pro; no additional test messages were sent.
- Original native run: connection → final sync response 7.074 s, background release 7.127 s. A fresh profiled run reached final response at 6.872 s and background release at 6.943 s. A further restart, after nonempty persisted stamps were confirmed, reached the final response at 8.612 s and release at 8.684 s; it again sent six unstamped requests with `max=40`.
- All six complete requests in both fresh captures omit `stamp`, request `max=40`, and use `after` from page two onward. These are full snapshots, not incremental deltas. The second run has 6.006 s of logged response waits and 0.977 s between pages, versus 3.957 s and 0.971 s in the first run.
- The first five console response frames are truncated near 32 KiB. Only the final response is complete: 11 conversations, RSM count 204. Do not infer exact current total/unique counts from incomplete frames.
- A complete historical November 3 capture contains 211 conversation records but 204 unique conversation keys. Seven cross-page overlaps explain that difference; this is not evidence of seven duplicate UI rows or lost records.
- The original VFR recording has 360 actual decoded frames. Frame 21 at 12.825000 s shows recents; frame 22 at 12.858333 s starts chat navigation with skeleton; frame 24 at 12.925000 s still shows skeleton; frame 25 at 12.958333 s shows real history. The visible transition-to-content interval is approximately 100 ms, bounded to 67–133 ms. Video and native clocks were not directly synchronized.

The persisted completed/event sync stamps were independently read as nonempty before the further restart, with bootstrap-in-progress false; only presence booleans were retained. Thus full synchronization despite existing completed state is observed. The precise preview-recovery branch inside the installed binary was not instrumented. Source findings below refer to the current checkout; the exact dirty source snapshot of the installed executable was not captured.

## Measured client CPU work

The saved Time Profiler recording includes the actual cold process PID 8740. Initial exported app frames were unsymbolicated and the exporter reported overlapping image mappings. Restricted app-range addresses were resolved offline with the matching cached device Mach-O and recovered load base. The earlier process PID 8723 was excluded. Of 3,810 unique app addresses, 3,802 resolved to named symbols.

During first sync request → last sync response (4.928 s wall time), sampled work totals 6.636 CPU-s across cores. Main-thread work accounts for 0.184 CPU-s. This phase window is approximately aligned through profile start-date and console wall timestamps; no cross-clock error bound was measured. Inclusive groups are:

| Stack group | Sampled inclusive CPU-s |
| --- | ---: |
| Recents preprocessing | 3.877 |
| Recents mapping | 3.712 |
| Materialized preview resolver | 2.754 |
| Realm | 3.878 |
| Diagnostic XML/privacy sanitizer | 0.941 |
| Private log formatter | 0.449 |
| CocoaLumberjack | 1.002 |
| Client synchronization | 0.533 |
| Credential access | 0.074 |

These groups overlap and must not be added or subtracted from wall time. Recents mapping and preview work ran on background threads. The profile establishes substantial competing client work; it does not isolate the server/network contribution or prove absence of main-thread waits. Waiting threads were not recorded.

## Startup findings

1. **Preview recovery can discard incremental-sync eligibility globally.** `ClientSynchronizationManager.swift:625–674` checks for any durable row with an unresolved last-message link and no process-only preview before consulting saved completed/event stamps. All owner rows participate, including archived rows; this has no visible-row, cold-only or once-only restriction. A single permanently unresolved preview can keep triggering full snapshots. Current tests deliberately require this recovery behavior. The actual unstamped full requests are proven; attribution to this exact branch remains an inference until its input state is observed.

2. **Six serial pages amplify response and client processing costs.** `ClientSynchronizationManager.swift:411, 1962–2123` uses pages of 40 and sends the next cursor only after the current page is applied. In the original measured run, 1.876 s precede the first request, logged response waits total 4.242 s, inter-page gaps total 0.956 s, and completion takes another 0.053 s. The profiled run has 0.971 s of inter-page gaps. This is not an artificial sleep between sync pages, and cursor pagination cannot simply be parallelized.

3. **Recents invalidation repeatedly projects the whole list.** `LastChatsViewController.swift:3974–3993, 4589–4719` remaps every matching chat and builds the full section diff. Exact changed conversation primaries already exist in `LastChatListSyncPreviewStore.swift:293–304`, but the subscriber at `LastChatsViewController.swift:4920–4932` ignores them. Whole-owner outgoing history, typing and resource changes also invalidate the full list. Coalescing reduces bursts but does not make the work incremental. This matches the measured recents CPU hotspot.

4. **The preview resolver repeats broad Realm work for unchanged rows.** `LastChatsViewController.swift:1359–1412` reconstructs owner/message-ID sets, queries and groups candidate messages on every full map, and applies opponent/type filtering later. It intentionally does not populate the durable link and has no result memoization. Additional per-row resource queries/sorts and repeated rich-preview/reference preparation occur at lines 4178–4245. Message-ID fields are indexed: this is repeated and overly broad work, not a proven missing-index defect.

5. **Skeleton listeners accumulate across dataset rebinds.** `LastChatsViewController.swift:3255–3266` replaces `datasetBag` but disposes the new skeleton subscription into `self.bag`. Repeated filter/rebind operations therefore retain additional full-update listeners until the broader subscription lifecycle resets. This source-level bug has not been reproduced with an observer-count regression here.

6. **Full XML diagnostics execute on the receive hot path.** `AccountStreamDelegate.swift:610–633` eagerly computes pretty XML before routing the synchronization response. `ConnectionDiagnosticsLogger` at `Account.swift:3188–3260` accepts raw XML and performs sanitization; sink formatting adds more work. The persistent-file logging setting does not avoid this path. Profiling confirms material sanitizer/logger CPU. Preserve the privacy boundary when optimizing this work.

7. **Other repeated work occurs before and during page application.** Sync parsing and OMEMO preparation run on the account callback queue before `applyQueue.async` (`ClientSynchronizationManager.swift:1897–1962`). Each page recomputes group membership projections (`:953`, `AccountGroupchatIntegration.swift:751–789`). Per-row tombstone checks decode the stored set repeatedly. `SettingManager.swift:476–500` also obtains the access-group identifier through a fresh credential-store file read/decode (`CredentialsManager.swift:108–124`). These are confirmed repeated operations; individual causal wall-time contributions are not established.

8. **Overlapping pages repeat expensive application.** `seenSnapshotConversationKeys` counts duplicates but does not filter `page.conversations` before application (`ClientSynchronizationManager.swift:270–307, 1156–1170, 1936–1979`). The historical seven repeated records therefore repeat preparation/application work. Blindly dropping repeated keys is unsafe because later records may carry newer content; current tests exercise an old then new value for the same key.

## Chat-opening findings

9. **Interactive history shares one MAM lane and its cooldown.** `Account.swift:173–185, 434–499` limits account-wide archive work to one slot and applies a 350 ms cooldown irrespective of the next task's interactive priority. Promotion cannot preempt a running background request or bypass that pause. `MessageArchiveTransportAdapter.swift:433–463, 842–1010, 1136` holds the lane through persistence/materialization/accounting, extending head-of-line blocking beyond wire completion. This mechanism is proven by code, but its contribution to the measured opening was not isolated.

10. **Remote submission follows synchronous opening preparation and waits for a full initial page.** View/layout/skeleton preparation precedes actor submission. The measured native open → submit interval is 393.918 ms, not an admission-provider delay. Initial history requests contain 80 records and the transport receipt includes scheduling, final response, message persistence and materialization. The measured enqueue → receipt interval is 1.725 s, followed by 44.601 ms of coverage commit and about 126 ms to the fresh content receipt. These are composite boundaries, not pure network/DB/UI costs. Early local rendering can overlap this work.

11. **A cancelled latest-cache request may never be replaced.** `ChatViewController+ArchiveEngine.swift:1237–1296, 3476–3499` allows a newly accepted actor skeleton to cancel a pending local mapping job. The pending request UUID prevents a replacement; the old callback later clears the UUID, rejects its outdated generation and does not retry. The saved-target path explicitly re-reads, ordinary latest does not. This is a source-level interleaving defect requiring a controlled regression. It was not established in the successful physical opening, which displayed real history early.

12. **Opening before startup completes inherits the full startup gate.** All primary MAM work, including interactive work, waits for initial list synchronization (`Account.swift:435–446`). This is the existing owner-required startup contract, not a gate to remove casually. The successful basic opening occurred 26.64 s after its launch event, so that particular opening did not wait behind startup; adding 7.1 s and 2.3 s as a measured total would be wrong.

## Correctness, policy and observability findings

13. **Warm snapshot and push application admit a stale-overwrite interleaving.** Push payloads apply on the account queue while snapshot pages apply separately. A previously completed snapshot makes the initial-sync predicate false, suppressing the catch-up flag; current metadata writes do not compare incoming and existing stamps, and snapshot completion resets the recognized stamp (`ClientSynchronizationManager.swift:1095, 1584–1606, 1766, 1962, 2021`). A newer push can therefore be overwritten by an older queued page of the same generation. This is an untested static counterexample, not a reproduced cause of the measured delay.

14. **Code/tests and documented loading contracts disagree.** Ordinary latest fallback currently applies for every skeleton; a five-second opening deadline can clear the skeleton into neutral pending (`ChatViewController+ArchiveEngine.swift:704–708, 3824–3880`). The verified KB describes a narrower saved-only exception and preserving the same skeleton while work remains in flight. A transport document also describes releasing the wire lease at raw final, while the current adapter retains the scheduler slot through storage work. The sync comment still says a 20-row first page although code, tests and wire use 40. These need policy/document reconciliation, not a blind rollback.

15. **Current telemetry conflates freshness with first visibility.** Numeric content event 2 is emitted by the fresh verified presentation wrapper, while local latest/saved cache applies bypass it (`ChatViewController.swift:3300–3314`, archive extension `:1329–1343, 5219–5242`). The earlier first-appearance statement is corrected by the original video. A missing stable event does not prove instability. Large console XML frames are also truncated, so counts and timing need bounded typed diagnostics rather than inference from incomplete dumps.

The 60-second sync response timeout and later retry backoff also permit long recovery on a lost response; the response timer ends before page application, and no separate apply deadline was identified. This path was not exercised in the successful 6–9 s starts and is not their demonstrated cause.

## Verification and next priorities

Six existing focused simulator tests passed, building the app, extension and test target through `tools/xcodebuild_cached.sh` with isolated storage enabled, account autoconnect disabled and a concrete destination. They cover cold full-snapshot preview recovery, all-row recovery, duplicate-page application, scheduler cooldown, startup MAM gating and the five-second opening policy. They confirm current behavior; they do not reproduce the two static race counterexamples or establish a performance distribution.

Prioritize repeated full-snapshot recovery and recents projection amplification, then eager XML diagnostics and interactive archive scheduling. Keep current sync/roster/presence ordering and distinguish renderable cached rows from fresh archive/read authority. Race fixes need dedicated deterministic XCTest coverage before production changes.

Safe numeric evidence, original video/frame classifications and the saved profile are retained privately in the vault at `projects/xabber/debug/2026-11-06-sync-latency-investigation/`. The task note is `projects/xabber/tasks/done/xab-ios-basic-sync-latency-2026-11-06.md`.
