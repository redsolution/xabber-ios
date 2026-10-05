# OM2-N01 — authoritative device membership

Completed 2026-10-05. XEP-0384 recipient membership is independent of persisted identity/trust.

- Realm schema 23 adds a known/unknown PEP snapshot and an active-device UI projection. Migration retains existing trust, identity, sessions and history; old rows do not prove membership.
- Expanded QName parsing accepts prefixed devices, ignores foreign names and rejects duplicate/invalid IDs. `current` is recommended rather than mandatory; matching retractions, purge/delete and empty IQ results remove membership without deleting keys.
- IQ ownership/sender/latest request and PEP revision checks prevent stale responses from restoring removed devices. Own replies may omit `from` only for correlated own requests.
- Content encryption requires known own/peer lists and selects trusted advertised devices, excluding the local device. Direct nonzero-key ratchet calls also enforce membership before session mutation. Zero-key protocol controls still target the actual sender.
- Unknown membership initiates discovery and fails closed; a valid unknown incoming SID refreshes its sender list without granting membership. Chat/share/device indicators use active projections while trust history remains stored.

Verification: expected failing XCTest before implementation; final cached Debug isolated simulator run 89/89 passed (N01 19, UI projection 4, app integration 18, outgoing metadata 14, state storage 29, session lifecycle 5). App and push extension built by test action. No live server interoperability run. N02 handles own publication/registration; N03 handles edits.
