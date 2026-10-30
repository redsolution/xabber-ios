# First-ten chat opening and history QA — 2026-10-30

Status: physical QA completed with failed acceptance cases. Three defects are recorded for later fixes. A clean ten-chat / fifty-page acceptance result is not claimed; this report contains no production changes.

## Device and source

Only the cable-connected iPhone 12 Pro / iOS 26.6.1 was operated. Source `847b4f93` was built with the cached signed device configuration and installed in place as `xabber.ios`; accounts and storage were retained. The loaded module path matches the new bundle. A network-only phone was excluded. The standalone physical XCTest runner has no dependency on the application target and uses no synthetic accounts or fixture flags.

Chat names, account identifiers, message bodies, exact primary keys, AX dumps, Realm copies and video remain in the private vault. D01–D10 refer to the ten real rows frozen before the first measured launch, excluding banners.

## Opening results

All ten frozen conversations were actually selected. The initial cold matrix reached D01–D07; a corrected runner lookup subsequently reached D08–D10. Eight chats rendered real messages. Exact canonical primary/message IDs were checked against quiescent read-only Realm snapshots:

- Initial pass: seven correct latest targets and one correct first-unread target. No saved positions existed in that baseline.
- Later complete cold opening-only control: all eight valid saved anchors appeared in the first real window. Seven short anchors center within 0.167 pt; the tall D07 message correctly top-aligns under the existing centering policy.
- All eight sampled stability windows retained row order and showed 0 pt shared-row vertical drift before any chat scroll. The complete later video reveals those same windows directly, with no captured intermediate wrong-message window or automatic correction.

The later control records both full wired-screen video and ten native opening contexts. Video: 175.754 s, 9,411 source frames, average 53.54 FPS, minimum 36 frames per complete second after warmup, no capture/discard/append/PTS/backpressure failures, video only. Frame delivery has a maximum 234 ms source interval; it cannot exclude every very short hitch. No ordinary app crash was observed during these automated chat-opening passes; Back remained usable in the observed failed loading states. The later D07 cold saved-position reopen failed the loading-time requirement described below.

| Chat | Native request → content | Request → matching stable marker | Recorded skeleton | Outcome |
|---|---:|---:|---:|---|
| D01 | 2.661 s | 2.662 s | 2.518 s | saved anchor correct |
| D02 | 2.493 s | 2.500 s | 2.430 s | saved anchor correct |
| D03 | 2.503 s | 2.585 s | 2.360 s | saved anchor correct |
| D04 | unavailable | unavailable | unavailable | admission fails before MAM enqueue |
| D05 | 2.404 s | 2.469 s | 2.293 s | saved anchor correct |
| D06 | no content | no content | 0.263 s | successful authoritative empty receipt at 0.319 s |
| D07 | 2.733 s | 2.734 s | 2.679 s | saved tall-message anchor correct |
| D08 | 1.804 s | 1.815 s | 1.743 s | saved anchor correct |
| D09 | 2.662 s | 2.667 s | 2.596 s | saved anchor correct |
| D10 | 2.630 s | 2.643 s | 2.559 s | saved anchor correct |

Durations use native monotonic timestamps, not XCTest polling. Logical stable markers are not raster-frame proof; the independent video supplies the visual-position evidence. Observed visual push/skeleton-to-real intervals were 1.053–2.090 s, a different clock interval from input/request latency.

## Confirmed defects for follow-up

### QA-01 — D04 opens into unresolved history after admission failure

Reproduced in the initial and later cold pass. Required latest bootstrap has no real cells after the eight-second observation budget; the screen shows a neutral “Messages aren’t loaded yet” state. In the later native capture, latest execution 13 fails during admission, before any MAM enqueue, then finishes with failure. Telemetry contains unclassified failure domain 9 and bridged error code 3; the originating error domain/cause is absent, so membership/server/network causes must not be guessed. No content, empty or stable receipt appears. Investigate admission error handling and present an actionable terminal state. History pagination is blocked here.

### QA-02 — D10 older pagination fails without visible recovery

The later safe history pass captures nine successful transported, nonempty, verified older operations. Their proof counts are seven responses of100 IDs, one of83 and one of94; these are transported IDs, not unique new inserts. A subsequent older execution192 receives a response and fails with domain2/reason7, mapped by current source to `ArchiveTransportValidationError.persistenceFailure`. Fifteen later executions194–208 reuse the retained terminal failure without another enqueue or commit; repeated gestures do not represent new pages.

The narrow raw accounting window has100 unique delivered IDs,99 matched rows and1 missing identity, while the summary reports99 saved/1 updated/0 failed. This is evidence of an accounting/identity-validation mismatch, not proof of a failed disk write, corrupted Realm or lost messages. The screen retains15 real rows at0% scroll position, with no visible Retry/error/recovery state after the failure. Investigate the identity accounting and the boundary-error presentation while preserving protection against repeated invalid requests.

### QA-03 — D07 cold deep saved-position reopen remains skeleton beyond8 s

An additional cold run after deep history navigation selects the same frozen D07 row and cannot obtain real cells during its eight-second opening wait. A screenshot retains the required skeleton and native telemetry contains a saved-purpose open request without content/empty/stable receipts. Actor1 uses locator7/archiveID; the captured enqueue→receipt phase lasts approximately11.56 s. Its first one-ID result materializes without coverage, followed by a later30-ID result. Back cancels the still-active preparation before any content receipt; no older gesture or private quiescence override is invoked in this pass.

This later scenario fails the requested2–3 s loading limit despite the earlier D07 saved-anchor control passing at2.733 s. It is not an observed CPU freeze: Back works, and the slow phase is archive-target preparation. The division between server, network, admission and client work remains unproven. Investigate cached exact-target readiness and cold restoration latency without removing the required-target gate merely because a deadline elapsed. Five older pages in this supplemental D07 run are blocked by opening failure.

## Other outcomes and limits

D06 shows an encrypted introduction with device/contact verification controls and a pending subscription, not a blank chat. Native latest execution18 succeeds and commits an empty result, then emits an empty receipt at318.794 ms. This is not an archive actor failure. Stored encrypted-scope readiness is confirmed, but its empty segment list does not prove a complete both-edge ledger. Confirm namespace/projection and expected archive contents before classifying missing history as a defect. No verification, subscription or trust settings were changed.

Strict launch→2–3 s→actual first tap remains unverified. The normal controls explicitly wait2.5 s after public `launch()` returns; in the later control the coordinate-tap call starts2.501 s later but XCTest delays dispatch inside its8.303 s call. A separate guarded external-launch experiment sends no tap because the pre-created public XCTest application handle never observes foreground. Video independently shows foreground and real first-ten rows around2.85 s after CLI launch start (approximate clock mapping), followed by normal recents throughout the30 s observation timeout. Local runtime inspection corroborates a cached process pointer in the state getter. This is a harness failure, not evidence that the app stayed in background. A private test-driver override was prepared and ABI-checked; no override input was actually dispatched. It supplies no early-input or rapid-traversal acceptance evidence.

## History verification

All seven content-bearing long-history candidates were traversed using ordinary swipes; D08 was separately verified as a complete11-message archive. The safe run completed in1404.5 s without navigation/assertion failures. Its empty defect array does not test semantic page success or error affordances. Five UI rounds, gesture batches, duplicate submissions and UIKit applies are never equated with five completed pages.

The safe-run quiescent snapshots confirm2042→8936 materialized messages globally, zero removed pre-existing primary keys, and zero changes to pre-existing deletion/hidden flags. Per-chat results below use the same before/after snapshots, not the later cold supplemental state:

| Chat | Materialized records before→after | Verified archive start | History outcome |
|---|---:|---|---|
| D01 | 549→3027 | no | substantial older progress; exact remote-page count incompletely captured |
| D02 | 379→1192 | yes | reached confirmed beginning |
| D03 | 180→483 | yes | reached confirmed beginning |
| D04 | no traversable content | unconfirmed | blocked by QA-01 |
| D05 | 232→1736 | no | substantial older progress; exact remote-page count incompletely captured |
| D06 | 0→0 in candidate scopes | no both-edge proof | successful empty latest window; separate triage |
| D07 | 80→343 | no |300-ID verified older prefix; only1 qualifying older operation captured; later QA-03 blocks supplement |
| D08 | 11→11 | yes, and live edge | complete short archive; five older pages do not exist |
| D09 | 278→468 | yes | reached confirmed beginning;1 qualifying older operation captured in safe pass |
| D10 | 280→1614 | no |9 qualifying older operations, then QA-02 |

The saved native fragments have a30.397 s gap and lack early custom actor diagnostics despite independent stored-history growth and continuous system scrolling events. Captured counts are lower bounds, not true zeros for D01/D02/D03/D05. Ledger cardinality, materialized deltas and transported proof counts are different measures; several server ledger cursors do not map directly to materialized rows, so they cannot be silently substituted for a page counter or diagnosed as data loss. A full five-successful-page-per-chat acceptance result remains failed/unverified for the reasons above.

## Verification and evidence limits

- Cached signed device app build succeeded; runner build-for-testing and probe executions succeeded. QA aggregates intentionally fail when candidates or preconditions are recorded; they are not interpreted as compiler failures or as a clean acceptance result.
- No production source was changed. Prior implementation validation remains 446/446 scoped Simulator tests at `847b4f93`.
- Main all-system CPU/log collector exhausted host temporary storage and failed. The 12.26 GB raw spool was SHA-256 verified onto the external volume before removing the closed original. A bounded recovery import stalled at EOF and was stopped as a host-only process; that capture provides no claimed native metrics. The later Logging-only control completed and is the authority for the table above.
- The first long screen capture truncated at 63.945 s and lacked healthy final metadata; it covers only D01. A short D08 supplement and the later complete healthy capture replace broader visual claims. XCTest’s approximately 1 FPS movie alone cannot exclude flashes.
- An experimental scrollbar gesture opened a message menu during history QA. It was stopped, the exact unique Cancel control dismissed the unconfirmed deletion sheet, and a quiescent database comparison verified zero removed pre-existing messages and zero deletion/hidden-state changes. The method was removed in favor of ordinary swipes. This was a harness incident, not a product defect.
- A preflight Swift debugger expression failed and restored/detached; it is not an ordinary app-crash reproduction. No debugger pauses occurred during measured opening intervals.

Private evidence and row mapping: `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/debug/2026-10-30-iphone-first-ten-chat-opening/`. Task/handoff and UI/tests/XMPP notes in the vault link the raw evidence, the three open defect tasks, the D06 triage and reproducible conditions. Final post-supplement audit retained9034 messages with zero removed existing keys or changed deletion/hidden flags. No message/media was sent, edited or deleted and no account was reset or logged out. Normal opening, read-marker, MAM, roster hydration and cache writes occurred.
