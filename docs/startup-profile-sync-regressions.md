# Startup profile and sync regressions (2026-10-06)

A fresh login must materialize chat-list pages and hydrate the account profile and roster avatars. Profile discovery is background enrichment, scheduled through account readiness and the initial-sync/interactive gates. A failed history connection retains the unresolved archive proof and shows a localized status while the existing automatic recovery waits for connectivity.

- Client synchronization requests 40 conversations per page. Finality uses the tracked request maximum and advancing response cursors; overlapping conversation pages remain idempotent.
- VCard stream preparation schedules the own-account profile. Avatar preparation schedules own then active roster PEP metadata; existing cooldown/readiness gates apply.
- Own senderless PEP responses are accepted only through matching recorded request ownership. Peer senderless replies, mismatched publishers, nodes, item IDs and device IDs are rejected. Disconnect/reset invalidates outstanding ordinary avatar and bundle request contexts.
- PEP URL/data avatars take priority over vCard PHOTO. Correlated data results replace an older URL only when current metadata still names that item without a URL. A newer metadata notification invalidates old in-flight metadata/data.
- Own binary PEP data outranks queued roster metadata after own metadata has been received; it still waits for initial sync/readiness.
- A response containing multiple PEP nodes is dispatched only to its recorded requested node.
- Ordinary bundle request state is lock guarded; reset cancels projections that have not started. No queue/transport/Realm/protected storage operation runs while holding that lock.
- Cached metadata alone does not prove image bytes remain in the avatar cache. Missing bytes permit refetch.
- Offline/retryable history shows a localized status over the skeleton. Automatic actor retries and reconnect remain; no manual Retry affordance or inferred confirmed-empty/readiness is introduced.
- OMEMO bundle crypto/profile validation is unchanged. Rejection diagnostics expose only reason category, decoded public-field byte lengths and prekey count, never XML or key/signature bytes.

## Evidence and limits

The supplied user log had max=15, 24 pages for advertised 308 conversations with overlaps. The first response callback followed request-send completion by 11.85 seconds; page application took 19 ms. More conversations per page reduces continuation round trips; it does not prove the initial network/server/delegate-queue delay is resolved.

Own vCard/avatar requests were absent. There were 128 generic OMEMO rejection messages, with no bundle XML because connection diagnostics have rawXMLLoggingEnabled=false. Their cause cannot be inferred from this attachment. Senderless-own handling is a reproduced client defect, while incompatible bundle shapes remain a possible separate cause to diagnose with the new fields.

Both Andrew chat attempts failed DNS before MAM admission. Initial DNS had succeeded in 270 ms and authentication completed; about 120 seconds later the socket disconnected, reconnect DNS failed, then NWPath was unsatisfied. No hardcoded DNS endpoint or provider substitution was added.

## Verification

Test-first runs reproduced pagination/profile/bundle failures. The pagination test fixture now creates an in-memory account directly because unsigned Simulator AppGroup wipe-marker registration fails; production wipe policy stays intact. Final cached Debug Simulator verification:270 distinct focused scenarios passed across the integrated run and scoped rerun. The integrated run passed256 non-profile cases; after correcting a test-only completeness assertion that imposed unrelated request order, all14 ProfileHydrationTests passed. App and xabber-push-extension built successfully during these test actions, with no compiler/linker errors. No separate Debug build or cache reset was run. Real-device/server login remains unverified; see the live latency/bundle diagnostics follow-up.
