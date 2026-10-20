# OM2-01 — Authenticated SCE receive

Implemented 2026-10-02. References: [XEP-0420 0.5.0](https://xmpp.org/extensions/xep-0420.html), [implementation plan](omemo2-implementation-plan.md). Follow-up [OM2-04](omemo2-sce-affixes.md) supplies original-time context and completes affix/padding policy. The 2026-10-20 follow-up below adds narrowly scoped protected sync-preview recovery for first archive admission. General durable inbox recovery and independent peer interoperability remain separately scoped tasks.

## Receive contract

`OmemoManager.prepareIncoming(_:context:)` returns one of:

| Result | Meaning | Downstream action |
| --- | --- | --- |
| `notEncrypted` | Ordinary message; plaintext SCE envelopes and wire success markers removed | Existing plaintext routing |
| `verified` | Payload cryptography, XML structure and existing SCE bindings passed | Reconstructed message plus `MessageEncryptionProvenance` |
| `consumed(control/duplicate)` | Protocol control or genuine provider duplicate | No message, preview, notification or semantic action; MAM accounts for intentional consumption |
| `consumed(invalidTransport)` | Ambiguous/malformed encrypted wrapper | No crypto transaction or semantic action |
| `failed` | Decrypt or payload validation failed | Sanitized history/error projection; skip extension handlers |

The OMEMO2 payload codec returns the checked `content` alongside the validated envelope. Its checks run inside the existing protected-state decrypt transaction, before ratchet state is saved. A payload MAC failure remains a failure. Legacy Signal frames are accepted only through an existing legacy session; a new-profile authentication failure never selects the legacy provider.

Authentication is an in-process value. It travels through live/archive/carbon receivers, MAM search, `MessageQueueItem`, Saved Messages, rewrite retries and `ClientSyncConversationValue`. It is never encoded in XML, a global cache or notification `userInfo`. Realm's `incomingEncryption` is transient and ignored by its schema. Reconstructing an XML document from its serialization cannot recreate authenticated provenance.

## XML policy

All protected content is selected by local name and namespace URI. Prefixes are canonicalized for existing consumers while expanded QNames and attributes are preserved. `body` has meaning only in `jabber:client`; references, file/source metadata, nested forwards, edits and previews also validate their QNames.

External body, references, TTL, markers, receipts, signatures, plaintext SCE envelope and `omemo-result__system` are removed. The original encrypted element and transport attributes remain available for history/routing. Only these explicit server metadata pairs remain outside:

| Namespace | Names |
| --- | --- |
| `urn:xmpp:hints` | `store`, `no-store`, `no-permanent-store`, `no-copy` |
| `urn:xmpp:sid:0` | `stanza-id` |
| `http://jabber.org/protocol/address` | `addresses`, `address` |
| `urn:xmpp:eme:0` | `encryption` |
| `urn:xmpp:delay` | `delay` |
| `https://xabber.com/protocol/delivery` | `time`, `received`, `retry` |

These elements are removed from protected content. Protected `origin-id` is retained. Foreign metadata lookalikes do not select IDs/dates. Peer content cannot impersonate server `rewrite#notify` mutation events; the protected client edit marker uses `https://xabber.com/protocol/rewrite`.

Supported receive wrappers are unique MAM/carbon, direct forwarding, priority and server rewrite containers. Their IDs, query ownership and delay metadata are retained. Invalid cardinality, mixed ciphertext placement and carbon owner mismatch are rejected before decrypt. No arbitrary recursive transport interpretation grants authentication.

## Routes and projections

- Main, background and UI-action streams prepare messages before notifications, chat states, markers/receipts, VoIP, favorites and other semantic handlers. Both history materializers use the separate provenance; a time signature cannot override an OMEMO error.
- Sync snapshot and sync push prepare embedded `last-message` identically. A control/replay cannot replace the previous visible preview. Ambiguous embedded messages cannot mix one message's authentication with another message's body.
- Attachment-only success projects verified references after removing external body. Failure produces local neutral text. Ordinary plaintext server previews remain ordinary plaintext.
- Raw push parsing detects OMEMO before text, references, invitations or verification. MAM/carbon/XEN wrappers require an unambiguous message; unresolved OMEMO produces neutral content and no download candidates while preserving routing and ciphertext.
- The notification extension has no ratchet access. Local app notifications require a separate authenticated projection; serialized XML and `userInfo` cannot authorize rich content.
- The dedicated VoIP stream only strips unverified OMEMO commands before `accept/reject`. It does not load secret state or decrypt packets.
- TrustSharing reuses already prepared content without a second ratchet operation. Its opaque XEN payload continues through the compatibility `decryptMessage` adapter and the existing signature/trust rules.

## Regression evidence

Task-specific `OMEMO2SCEReceiveTests` uses real provider ciphertext for injected external extensions, payload MAC/XML rollback, MAM/carbon/forward/priority/rewrite, prefixed and old transport namespaces, control/replay and ambiguous sync bindings. It also verifies actual legacy Signal `0x33` archive packets/replays and actual bodyless media through production sync and local notification projections. `OMEMO2ReceiveRoutingTests` covers queue/search/Saved Messages, internal provenance, VoIP suppression and TrustSharing compatibility. Sync, push, attachment and existing protocol suites provide projection and plaintext regressions.

Final cached Simulator gate: **527 tests, zero failures**, scheme `Debug`, iPhone 16 Pro / iOS 26, 2026-10-02. Hosted storage/account isolation was enabled, signing used `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`. The successful test action built both the application and push extension; no separate build or cache clean was run. The gate selected 23 relevant XCTest classes, including archive accounting, queue synchronization, rewrite, notifications and VoIP compatibility.

One independently known hosted UI test, `PushNotificationRoutingTests.testDuplicateTapProducesOneNavigationAnchorAndReadVisibleEffect`, was explicitly excluded. It failed at first-frame/window readiness in the initial full routing run (13 cascading assertions), with `stanza: nil`; the same failure was already recorded on 2026-09-16 at commit `133d6a5e`. Its UI fixture is outside OM2-01. No other test was excluded.

Static route/QName review and `git diff --check` passed. Production references to `omemo-result__system` remain only in removal guards; no stream uses the old decrypt-and-dispatch adapter. The precise gate selectors/results are recorded in the completed vault task. No Signal C/ObjC, dependency pins, identity/device migration or trust authorization rules were changed for this task.

## Sync-preview recovery before first history admission (2026-10-20)

A successful encrypted synchronization preview may precede its first history row. Its native ratchet commit now atomically retains optional protected `pendingSyncReceives`: the 32-byte authenticated packet fingerprint, exact peer address, original native identity, 48-byte payload key/MAC material and a 32-byte canonical message-identity digest. The identity is `getUniqueMessageId` on the SCE-sanitized verified leaf; domain separation and UTF-8 byte-length framing precede SHA-256. Arbitrarily long raw identifiers are not retained in this protected field. The entry is saved in the same protected aggregate transaction as the ratchet, survives storage recreation/consumed-prekey cleanup and is pruned with the existing bounded 4096-fingerprint ledger. The optional field preserves decoding of older state; malformed, duplicate or ledger-unbound entries are rejected.

Only archive ingress without existing durable authenticated history may use the exact matching pending entry. It reruns payload MAC, SCE, sender/recipient and time validation, then checks the canonical identity digest before restoring the original authenticated native sender identity. Recovery neither advances/rewinds the ratchet nor grants trust. Live/carbon replays, already durable history and controls remain consumed. Invalid attempts and history-persistence gaps do not evict valid pending material early. Preparation alone creates no synchronization history row, MAM provenance, archive coverage or paging/read authority.

This addresses the physical B93 failure in which a preview committed native state but the later identical archive ciphertext was consumed, leaving 299/300 history rows. The pre-cache missing packet cannot be reconstructed safely from its fingerprint alone; no plaintext fabrication or crypto-state reset is used. Acceptance used a wholly new final-code300-ID cold series, which passed; the older pre-cache packet remains historical.

Meaningful TDD: initial seven tests had five expected failures; the next three-case RED had two meaningful failures plus one MAM-container accessor fixture error, corrected without relaxing assertions. A long opaque-ID regression failed two assertions before the fixed-size digest correction. Final narrow gate is **45/45 PASS**, zero failures/unexpected, terminal0: SCE receive42 (13 new) plus synchronization cleanup3; app/test targets built. Final signed integration passes **1463/1463**, zero failures/unexpected/skips, across all 78 classes including all 46 OMEMO2 classes. The new CB5CD433 physical cold series passes300/300 native authenticated MAM rows and independent wire proof, before and after normal presence restoration; runtime tag dates pass600/600 within1ms. Final ordinary relaunch/UI and cleanup also pass; the completed task records exact evidence. See the [current physical verification report](omemo2-redsolution-dxs-verification-2026-10-19.md).
