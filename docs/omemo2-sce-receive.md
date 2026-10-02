# OM2-01 — Authenticated SCE receive

Implemented 2026-10-02. References: [XEP-0420 0.5.0](https://xmpp.org/extensions/xep-0420.html), [implementation plan](omemo2-implementation-plan.md). Follow-up [OM2-04](omemo2-sce-affixes.md) supplies original-time context and completes affix/padding policy. Outgoing wire, durable inbox/replay recovery and independent peer interoperability remain separately scoped tasks.

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
