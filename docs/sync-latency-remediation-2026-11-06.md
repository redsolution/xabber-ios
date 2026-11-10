# Sync latency remediation — 2026-11-06

Implementation and verification completed on November 9, 2026. This follow-up addresses the numbered findings from the [original investigation](sync-latency-investigation-2026-11-06.md).

## Resulting behavior

- Missing or evicted list previews do not invalidate a completed sync stamp. The initial account snapshot remains paginated; subsequent sessions request changes from the latest processed event stamp.
- Cursor envelopes can request the next page before expensive preparation/application. At most two admitted, uncommitted snapshot pages are retained. Snapshot preparation and ordered Realm application run outside the account receive callback. Push preparation/application still run synchronously on their caller.
- Startup completion still requires every page to commit and roster readiness before actual own available presence and background release. Roster may become ready before the last page. A final response alone cannot open that gate.
- Numeric event stamps are monotonic. Writer-time version checks prevent an older snapshot/push from overwriting newer list state. Exact plaintext replay avoids redundant application; encrypted ingress always retains native replay/trust/key admission.
- List preview DTOs are render-only, versioned, account scoped, asynchronously persisted and bounded. A delayed load cannot replace a newer mutation or revive a cleared account. Cache failure uses the existing local/neutral presentation fallback and never requests a full account snapshot.
- A typed page boundary spans Realm writes and detached preview mutations. Recents defers work during that boundary and validates its captured revision before caching and applying a prepared result. Cached immutable rows/candidate identities avoid repeated unchanged rendering and queries; current model/version changes invalidate them.
- Dataset listeners are owned by the dataset dispose bag. Unrelated typing, old outgoing receipts and irrelevant preview identities do not invalidate the full visible list. Primary resources use one batched lookup.
- Visible MAM work has one bounded reserved wire slot and bypasses background cooldown. A matched raw final releases wire capacity; persistence, accounting, proof validation and receipt completion remain independently owned.
- Preparing a transport query publishes lock-owned metadata before wire send without waiting for earlier persistence. Queue-owned bookkeeping is FIFO before ingress. Reset/teardown cannot revive retired bookkeeping or finish a post-final continuation before its barrier.
- A route captures its exact immutable latest/saved/unread/explicit intent before loading/layout of the chat view. Presentation subscribes to the same actor demand. Terminal controller teardown revokes demand and reconnect work while allowing an already admitted page to finish storage.
- An accepted actor generation cancels the old cache mapping and immediately permits its owned replacement. A stale callback cannot clear the replacement's request identifier.

## Logging and evidence boundaries

The owner's November 6 instruction supersedes the previous app XML formatter policy. XMPPFramework's native wire logger remains unchanged. Additional app XML serialization, XML sanitizers and sink wrappers are removed. Debug OS logging admits the framework's native SEND/RECV_POST flag bits; existing release and persistent logging settings retain their roles. App connection metadata is distinct from framework wire XML.

Numeric QA event 6 denotes a logical cached presentation transaction receipt. Event 2 denotes fresh verified content. Neither alone proves the first physical onscreen frame; video remains necessary for that claim. The earlier successful device video showed real history approximately 100 ms after visible navigation began, while the 2.295 s native receipt measured fresh synchronization. These are prior-run observations, not an after-change benchmark.

Item 14 in the discussion concerned the history skeleton inside the chat, including its existing five-second pending policy. It did not refer to the launch screen. That loading policy is outside this optimization's changes.

## Verification

Dedicated regression suites cover cursor preservation and bounded pages, page/batch mapping work and invalidation, early route dispatch/cache replacement, interactive wire capacity, native log ownership and real transport preparation/reset ownership. A real crypto fixture checks that repeated encrypted preparation still follows native duplicate consumption.

The signed iOS 26 simulator run passed 783 tests in 35 suites with zero failures and zero skips. The app, extension and test target built. The unchanged authentication suite also passed with signing enabled after an unsigned run failed to persist test credentials in Keychain.

The supplied simulator crash came from the new recents cache cleanup calling an asynchronous method that created a weak reference to a deinitializing controller. Deinitialization now clears caches synchronously. The lifecycle regression and all 22 dedicated recents tests passed. The full run also covered fixes discovered during integration, including retry lock reentry, repeat-cursor completion, search final ownership and cancellation of obsolete history demand.

A signed Debug build was installed on the wired iPhone 12 Pro on November 6. All 831 source hashes in the frozen manifest matched, and the installed app container on November 9 matched the November 6 installation. On November 6 the observation-only XCTest activated Xabber, opened the ordinary Alexey Boldin conversation, verified its timeline, checked for recovery status after five seconds and returned to recents. The first attempt stopped at the stale exact-preview selector. The attempt using the current ordinary row passed. Both attempts left the composer untouched.

On November 9 a separate cold launch completed the startup barrier at 3.877 s from the first connection request. The same endpoint was 6.943 s and 8.684 s in the previous candidate's two cold runs. Authentication completed at 2.517 s, roster resolved at 3.791 s, and the presence callback occurred at 3.876 s. These are observed runs with different traffic and timing, so the comparison does not isolate the app-side contribution.

The November 9 UI retry stopped before the test body because XCTest timed out enabling automation mode. The successful November 6 observation retained stills and AX snapshots. A new first-frame or fresh-history timing is unavailable. The November 9 console captured lifecycle milestones without wire XML, so device-side stamp and page count remain unverified. The stamped request behavior and history submission priority passed in regression tests.

The workspace retains the reviewed changes. An independently buildable task-only commit would require pulling in pre-existing archive and telemetry work, including an untracked source dependency. Existing staged work was preserved. Verification and safe timing evidence are linked in the vault task [[projects/xabber/tasks/done/xab-sync-latency-remediation-2026-11-06]].
