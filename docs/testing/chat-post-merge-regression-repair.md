# Chat post-merge regression repair

Date: 2026-07-17

Status: complete for the authorized Simulator and deterministic-test scope

## Scope and provenance

This report closes the regressions found after merge
`0b6b3e54f8ef45bbf2f9b3e262df492dfcf15787`. The merge parents are
`d6affcdbdd29ca8bde89c9fc44b8be7fe99209b3` and
`8e56a466c0217764cf2f76c950eb45b5f79c000f`. Execution started from
`8106f26851deebe122597eb85fbce91d4dcbdc4b` on `bugfixes/prod`.

The final integration gates ran from a clean detached worktree at
`438178398ac39b62f81a2d493d003126dd1af23e`. That snapshot contains the final
repair commit `209bc5a96165c7cc0419dabba7ba765033dd5a08` and a later concurrent owner
commit, `438178398ac39b62f81a2d493d003126dd1af23e`, whose bootstrap/synchronization
changes were outside the PMR repair scope but were included in every final
integration gate.

The authoritative white-label resource fix is
`f29ab5e31077a09a136d84c77f7351c473c6f479` on the resource repository's
`xabber` branch.

Gate definitions and historical tier evidence remain in
[Chat performance final gates](chat-performance-final-gates.md). This report
supersedes only the post-merge failure verdict for the repaired branch.

## Confirmed causes and repairs

| Area | Confirmed cause | Repair and retained contract |
| --- | --- | --- |
| Orientation | The local runtime plist had been corrected, but it is ignored by Git. The tracked template and authoritative white-label resource still declared an incomplete iPhone orientation set. | The tracked template and resource now declare exactly Portrait, Landscape Left and Landscape Right for iPhone. The iPad subtree is unchanged. Runtime, Debug product and Release product plists were independently checked against the same set. |
| Exact-message anchor | A loaded exact-search request could remain blocked by stale context-prefetch/execution state inherited across the merge seam. | Loaded anchors take precedence over stale blocking context while token, timeout, supersession, missing-target and late-callback protections remain intact. |
| Search result panel | A navigation fallback exposed a future result index before positioning committed it, causing the panel to display a result that was not yet the visible target. | The panel exposes only a valid committed presentation index. Pending/loading states remain at `-1`; queue drain, selection and reducer boundaries are unchanged. |
| Video geometry | Persisted metadata with zero dimensions was treated as a real `0×0` size. Padding then produced a degenerate video frame, while timestamp-backplate offsets were absent from the container minimum. | Missing, empty, non-finite or non-positive video dimensions are unknown and use the existing `128×128` default. Layout also normalizes degenerate manual inputs defensively and accounts for real timestamp/backplate offsets. The Debug geometry validator remains strict. |

Two additional test-only defects were discovered by the full gate and fixed in
separate commits: stale lifecycle expectations for the committed-only search
contract, and a short-lived in-memory Realm fixture in sensitive-media tests.
Neither changed production behavior.

## Focused commits

| Task | Repository | Commit | Result |
| --- | --- | --- | --- |
| PMR-01 | core | `241b86d9c4e784047c8bdc913abe294026e80f47` | Track the complete iPhone orientation contract. |
| PMR-02 | resources | `f29ab5e31077a09a136d84c77f7351c473c6f479` | Make the authoritative white-label plist match the tracked contract. |
| PMR-03 | core | `ee184148c700f8bd396c14f552e60ee2f74466ca` | Prefer loaded exact anchors over stale context state. |
| PMR-04 | core | `2543e34ad480c0cd2053d9e51551dd4609fe5160` | Keep pending search results uncommitted. |
| PMR-04A | core | `ec5ea5283165c9531d78bb3081f6ac0ee9248868` | Update lifecycle tests to the committed-only search contract. |
| PMR-04B | core | `430852b70f0e0d338232d0ef1e6dc9ffae8c1ccb` | Retain the in-memory Realm fixture for the full async test lifetime. |
| PMR-04C | core | `209bc5a96165c7cc0419dabba7ba765033dd5a08` | Default invalid video dimensions and contain timestamp geometry. |

## Before and after

The original merged snapshot exposed the following deterministic failures:

- full preflight/focused matrix: 1,254 of 1,256 tests passed, with four failed
  assertions;
- smoke matrix: 233 of 234 passed, with three failed assertions;
- notification/history-gap matrix: 193 of 195 passed, with four failed
  assertions;
- the local corrected runtime plist allowed the five UI scenarios to pass, but
  the correction was not durable in either tracked configuration source.

Final evidence from the clean `43817839` snapshot:

| Gate | Result | Test time |
| --- | --- | ---: |
| Repaired orientation/anchor/search/video contracts | 7/7, zero failures | 0.305 s |
| G20 preflight, 96 selectors, no known-red entries | 1,261/1,261, zero failures | 418.074 s |
| G20 focused, same 96-selector union | 1,261/1,261, zero failures | 445.357 s |
| G20 smoke, 15 classes | 234/234, zero failures | 4.110 s |
| Notification/history-gap, eight classes | 195/195, zero failures | 16.736 s |
| Push routing within the gap matrix | 14/14, zero failures | included above |
| Debug Simulator build | `BUILD SUCCEEDED` | — |
| Deterministic UI | 5/5, zero failures | 78.369 s |
| Release performance and Instruments analyzer | success | — |

The video follow-up also passed its affected four-class matrix 42/42, the final
mapping/layout matrix 20/20, and the zero/negative/`5×5` edge matrix 3/3 before
the final integration run.

## Release Simulator evidence

Release probes used the production datasource-operation counter and exactly 20
recorded cycles. The strict independent JSON audit passed for both scales.

| Metric | 100 logical messages | 1,000,000 logical messages |
| --- | ---: | ---: |
| Resident messages | 80 | 80 |
| First stable frame | 1,136.459 ms | 678.330 ms |
| Resident growth | 0.0617% | 0.0359% |
| Optimistic local row | 6.719 ms | 5.708 ms |
| Applies / inserts / deletes / moves / reloads | 42 / 42 / 42 / 0 / 0 | 42 / 42 / 42 / 0 / 0 |
| Forced layouts / programmatic offsets | 1 / 1 | 1 / 1 |
| Delayed corrections / anchor drift | 0 / 0 pt | 0 / 0 pt |
| Media download / decode / visible cache hit | 1 / 1 / 1 | 1 / 1 / 1 |
| Potential-hang rows | 0 | 0 |

Both probes reported zero full-history enumerations and passed actual-operation,
deterministic, memory-plateau and optimistic-row budgets. Time Profiler was
captured for both scales and Allocations for the million-message scale.

The Simulator first-frame delta was 458.129 ms / 40.312%, so the reference
device's absolute 50 ms and relative 10% formula is **not** claimed as passing.
Simulator timing and RSS are non-gating trends. Animation Hitches and Network
Connections are `SIMULATOR_UNSUPPORTED`; the hardware frame/network gates were
not measured.

## Authorized and excluded evidence

- Hosted deterministic XCTest: `PASS`.
- Deterministic UI fixture: `PASS`.
- Release deterministic operation and memory budgets: `PASS`.
- Live read-only QA: `NOT_RUN`.
- Live mutation QA: `NOT_RUN`.
- Fixed-live Simulator: `NOT_TOUCHED`.
- Physical-device and hardware performance gates: `EXCLUDED_BY_OWNER`.
- Animation Hitches on Simulator: `SIMULATOR_UNSUPPORTED`.
- Network Connections on Simulator: `SIMULATOR_UNSUPPORTED`.

The owner-reported physical-device crash supplied the reproduction signature;
Codex did not install, launch or automate the app on a physical device. MAM
stanza shape, transport and persistence behavior were not changed. Their
existing tests remain part of the green full and history-gap matrices.

## Repository and privacy audit

The following pre-existing owner changes remained byte-identical, unstaged and
excluded from every task commit:

- `xabber-push-extension/NotificationService.swift` —
  `7f5f0dff1412f27193f51770e96207ae2ce1ef2ff9e0d67d142aab2976c0c53a`;
- `xabber.xcodeproj/xcshareddata/xcschemes/PushNotificationsDevice.xcscheme` —
  `8ac3b5d91ab590920ed6024b84ce400d279e829b130da867dbab4c616f083243`;
- `xabber/xmpp/push_notifications/APNS/APNSManager.swift` —
  `b026feea995ccac6611ee4df397fd233472d2b4ad694964271e839cd5def7383`.

The runtime `xabber/Info.plist` remains ignored and was never force-added. Its
durable sources are the tracked template and the separate resource commit.
Complete logs, result bundles and performance artifacts remain outside Git at
`<external-cache-root>`. The dedicated Simulator is referenced only as
`<dedicated-simulator-udid>` in durable repository documentation. No account
credentials, message bodies, private identifiers, server URLs or tokens are
included in this report.
