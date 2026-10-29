# Chat opening position regression — 2026-10-29

## Expected behavior

Normal opening follows the knowledge-base contract: explicit requested message → positive server unread → edge-safe saved position at zero total unread → live bottom. A normal group row tap follows the same rules; a mention badge does not make it an explicit mention action. Archive IDs are opaque identities ordered by verified coverage, never numbers or timestamps.

References: `xabber-knowledge/behavioral-specs/chat/chat-open-and-scroll-behavior.md`, `behavioral-specs/notifications/mentions-read-state-navigation.md`, and the current archive-engine contract.

## Confirmed causes and repair

- Cold latest-cache presentation reused the skeleton's top offset instead of atomically aligning the newest message. An 80-message hosted test reproduced offset -54 pt instead of the required 4915 pt. Cold normal/latest cache presentation must align bottom in its first real transaction while retained reading-position recovery preserves its viewport.
- Navigation teardown invalidated and emptied the timeline before position persistence. Even live bottom became a saved middle-of-viewport row. Persist before archive/search teardown, while live-edge and pending-target information still exists.
- A historical resident window's last row is not the actual live edge. Persistence requires both near-bottom geometry and `isResidentAtLiveTail` before clearing the saved position.
- Missing or blank edge fingerprints compared equal and authorized old saved positions. Both saved/current last-message and archive-edge fingerprints must exist and match.
- A normal group-row tap implicitly generated an old mention route. Keep explicit mention actions separate and let normal unread/saved/latest selection run.
- A locally resolved unread boundary became an exact archive-ID locator, while remote resolution correctly selected firstUnread. All request-to-locator entry points now preserve unread semantics, including authoritative-empty handling. Boundary-only/outgoing-only loaded rows do not become unread targets.
- A verified unread window may be centered beyond a long outgoing prefix and omit the boundary. Resolve its first incoming target from the matching owned firstUnread snapshot and verified chronological ledger; keep generic unverified boundary-free rows unresolved. Runtime unread jumps share the atomic target receipt.
- Retained-cache restoration ran even while an owned exact target was actively loading, exposing an unrelated previous window and releasing target ownership too early. Block that restoration only for owned non-offline skeleton targets; ordinary latest refresh, offline and real terminal failures retain current content. This reconciles broad cached-opening operational notes with the verified first-frame contract.
- Skeleton removal could drain observer work before publishing the aligned-frame receipt, allowing a duplicate loaded-message scroll. Publish receipt ownership before visibility/loading callbacks.
- Legacy saved positions contain MAM-or-stanza identifiers in one field. Recover the actual MAM cursor from the exact visible owned persisted row, validating conversation, message identity and expiry; this supplies identity, not archive/read authority.

The initial-opening spec still contains an older numeric comparison example. The later opaque archive-engine contract governs implementation; no numeric ordering was reintroduced.

The P14 performance fixture's ordinary row tap now expects first unread (120), preserving the offscreen mention (160), instead of encoding the product bug. Its enum/raw selector remains compatible.

## Verification

Tests were written first. Original RED1 ran six methods with ten expected assertion failures; original RED2 ran fourteen methods with fifteen expected assertion failures. The new scenarios reproduce actual recents taps, navigation cleanup, Realm persistence, initial/submitted archive locators, saved cursor identity and strict unread resolution.

Original RED3 ran two methods with eleven assertion failures, covering long outgoing-prefix windows in initial/runtime navigation and duplicate positioning. A baseline run with original HEAD conversation source reproduced the same ten failed legacy cases (41 methods, 52 assertions) from the first expanded integration run. Nonsingleton test coverage now lists every known archive ID explicitly, nonempty opaque cursors have positive coverage, and retry source checks follow the current actor-owned backoff. Existing behavior assertions were retained.

After the target-loading guard, all 42 first-frame methods pass, including strict exact-route loading, the long outgoing prefix and sole positioning receipt. Cold-cache RED ran those plus two cache tests: its bottom offset failed by 4969 pt; the retained-viewport control preserved its anchor/offset but its synthetic fixture initially lacked an accepted retained snapshot; the fixture now supplies the actual rendered datasource/layout snapshot before recovery.

Final integration: **446/446 passed**, zero failures/unexpected failures; cached `Debug` test action built the app, push extension and test bundle for the iOS 26.0 Simulator (`91E09D3E-4BBC-4431-9EAF-14D2410E7B98`). Both test-isolation flags were enabled and code signing disabled. Compiler/linker errors: zero; unsatisfiable-constraint warnings: zero. No separate Debug build or cache reset followed the successful test action.

Coverage: saved-position policy, actual disappearance/persistence, real recents taps, archive presentation and UI contracts, proof-scoped exact targets, first-frame transactions, message anchors, P14 plans/gates, viewport read boundaries, and six archive-engine unread/outgoing-prefix scenarios. The deadline regression uses a hosted real collection, verifies its timer token and actual expiry, then proves the same committed skeleton/context survives. Earlier final2's two remaining assertions were fixture-host/collection setup errors; production was unchanged for final3.

Independent review, `git diff --check`, project-plist validation and unique new test-registration ID validation passed. No physical-device installation or live-server/P14 video acceptance is claimed.


## Changed areas

- Production: `ChatViewController.swift`, `extension/ChatViewController+ArchiveEngine.swift`, `extension/ChatViewController+Dataset.swift`, `extension/ChatViewController+SearchBar.swift`, and `LastChatsViewController+UITableViewDelegate.swift`.
- Harness: `ChatPerformanceFixtureViewController.swift`, `ChatPerformanceIntegrationGate.swift`, `ChatPerformanceRouteHost.swift`, P14 UI expectations.
- Regression coverage: dedicated `ChatOpeningSavedPositionRegressionTests.swift`; existing archive presentation, disappearance, first-frame, recents, anchor, UI-contract and performance tests. Test project registers the dedicated file.

No dependency or storage-schema change. Existing valid saved positions remain supported. No bulk data cleanup or cache reset.


## Safe test-action summary

Failures below count XCTest assertions, not failing methods. RED and baseline failures are described above.

| Action | Methods | Assertions failed | Unexpected |
|---|---:|---:|---:|
| red | 6 | 10 | 0 |
| red2 | 14 | 15 | 0 |
| green | 325 | 53 | 0 |
| baseline | 41 | 52 | 0 |
| long-prefix-red | 2 | 11 | 0 |
| final | 441 | 14 | 0 |
| cold-red | 44 | 2 | 0 |
| final2 | 446 | 2 | 0 |
| final3 | 446 | 0 | 0 |

All nine task logs and nine disposable result bundles were removed after this summary; persistent DerivedData, SourcePackages and PackageCache directories remain.
