# OM2-04 — SCE routing, original time and padding

## Contract

Protected affixes use localName + namespace URI `urn:xmpp:sce:1`. Optional `from` and `to`, when present, must be unique empty affixes with an unqualified `jid` and a canonical bare JID matching the original encrypted leaf. Expected full JIDs are compared as bare JIDs. A present binding with no valid expected route is rejected. Group messages retain the existing required matching `to`; standard MUC sender mapping remains OM2-14.

Optional `time` must be unique, empty, and have an unqualified XEP-0082 `stamp`: explicit timezone, valid calendar fields, complete input, optional fractional seconds. Parsing preserves fractions to Foundation Date precision. Nested affix elements and non-whitespace text are rejected. Foreign namespace affixes have no binding semantics.

`OMEMOOriginalSendingTime` carries the Date and source independently of XML/provenance. The receive pipeline derives it from the validated original transport path, before reconstruction/decrypt:

| Source | Scope |
| --- | --- |
| `xabberDelivery` | Original encrypted leaf `{https://xabber.com/protocol/delivery}time`; select the actual account owner's marker when federation supplies several authorities |
| `forwardedDelay` | Nearest validated original `{urn:xmpp:forward:0}forwarded/{urn:xmpp:delay}delay` |
| `stanzaDelay` | Original encrypted leaf `{urn:xmpp:delay}delay`; fallback only when selected delivery time and forwarded archive delay are both absent |
| `caller` | Explicit internal context supplied by a caller |

Federation can attach separate Xabber delivery times from the sender's and recipient's account archives. Every delivery marker must have a valid stamp and no nested element. A present `by` must be one unqualified attribute containing a canonical bare JID. If there are several markers, every marker must have `by`, all authorities must be distinct, and exactly one must match the actual receiving account owner passed by the receive path. That account's time is selected regardless of element order. Missing owner context, missing owner marker, repeated authority, or malformed `by` rejects the stanza. The historical single-marker format, including an absent `by`, remains accepted.

The selected account delivery time and a validated forwarded archive delay must describe exactly the same instant when both exist. A direct leaf delay can instead describe stream-management resend or offline queue insertion, so it is always validated but is only a fallback when neither selected delivery time nor forwarded archive delay exists. It is not compared for equality with a higher-priority archive observation. Different federation authorities' times are not compared as if they were one archive observation. Duplicate delay metadata or malformed known metadata is rejected, including unused direct-delay metadata. This correction reads message timestamps only from `time` and `delay` tags; stanza IDs, query/sync/conversation metadata, notification receipt time and the current clock are not timestamp substitutes. Live, MAM/search, both carbons, background/UI-action, sync snapshot/push, modify and app push use the common receive preparation. The opaque TrustSharing adapter retains its inner forwarded delay and uses the same decoder; signatures/authorization/applyShare rules are unchanged. Selecting external delivery metadata does not grant authenticated-content provenance.

## Time policy

The client allows **300 seconds inclusive in either direction** between protected time and known original sending time. This is a client parameter, not a number required by XEP-0420. An established mismatch fails receive, strips unprotected client content and produces the existing local OMEMO error. It is not a duplicate or a request to reset keys.

The codec returns `timeValidation`: `.absent` for missing optional protected time, `.unavailable` when original sending time is unknown, or `.verified(originalTime)` after comparison. Unknown original time still requires syntactically valid protected time; no comparison with Date.now is fabricated. Verified decrypt/provenance does not imply a timestamp was available.

OMEMO2 crypto, routing and time validation run in the existing decrypt transaction before ratchet state is saved. Tests retry unchanged ciphertext after a failed time/binding check. The inherited legacy Signal reader validates using the same codec but its decrypt already mutates legacy state; this task does not add transactional rollback to that reader.

## Outgoing padding and time

The builder uses current encryption time instead of queued `sentDate`. The final `encryptMessage` writer refreshes the protected time immediately before sealing new ciphertext. An exact retransmission of prepared ciphertext preserves its original protected time. Long deferred ciphertext delivery/reprepare policy remains OM2-09.

The outgoing minimum is **512 bytes of the complete serialized UTF-8 SCE envelope**, then crypto-random **0…200 ASCII characters inclusive**. These are client parameters. Rpad uses Security random bytes and an XML-safe 64-character alphabet. The extra length uses rejection sampling. Existing padding is replaced, so builder and final writer do not accumulate padding. Multibyte content, XML escaping and the expanded/empty rpad serialization count toward the minimum. Large content needs no minimum fill. Incoming rpad has no outgoing minimum or maximum length requirement; short legacy padding and long peer padding remain readable.

Time, padding and XML serialization failure abort encryption before recipient ratchets advance. Control packets have no SCE payload and are unchanged. Identity, device IDs, persisted history, trust exchange, fallback body and existing hints remain intact. Delivery/read markers and receipts continue to be sent without encryption.

## Compatibility

Existing packets with protected queue creation time more than five minutes away from known server sending time now fail explicitly. The timestamp is not silently removed and state is not reset. No storage migration or dependency changes are needed. This task does not claim complete OMEMO2 conformance or independent web/iOS interoperability.

## Basis and verification

Current final verification on2026-10-20 passes **1463/1463 signed simulator tests**, zero failures/unexpected/skips. Both physical apps run code `CB5CD433-38D8-31B3-9190-76D285C09879`; the wholly new cold300series passes native authenticated MAM/wire/receipt proof,600qualified-tag stored dates, normal presence restoration, actual graceful ACK→unavailable→TCPclose both, nonoverlapping offline content and ordinary relaunch. Runtime cleanup is complete. Historical simultaneous400was on2026-10-19 code818, not a new final-code load run. See the [completed physical report](omemo2-redsolution-dxs-verification-2026-10-19.md) for scopes and the old pre-cache QA-message limitation.

### Historical verification snapshots — superseded by the final acceptance above

[XEP-0420](https://xmpp.org/extensions/xep-0420.html), [XEP-0082](https://xmpp.org/extensions/xep-0082.html), [knowledge base XEP-DELIVERY](/Users/igor.boldin/projects/xabber/xabber-knowledge/protocols/XEP-DELIVERY.md), [implementation plan](omemo2-implementation-plan.md).

Final 2026-10-19 verification for the federation and queue-delay corrections passed **107 tests / 0 failures**: SCE affixes 64 (9 new), SCE receive 29 (1 new native receive) and normative edits 14. Tests-first RED exposed the old multiple-authority rejection; follow-up RED confirmed two extraction failures and a native receive failure from direct queue-delay equality. The native regression uses a direct queue delay 3,600 seconds later while retaining protected-time comparison to the valid archive timestamp. The signed physical build succeeded; both installed devices report UUID `E451DE72-2697-3084-BCE1-8855287D483C`. Fresh-session ordinary encrypted sends passed authenticated recipient read-back in both directions, including Unicode. The closed-recipient test failed with service-unavailable and exposed a separate full-JID routing defect, addressed by the later combined gate below. See [current physical pair report](omemo2-redsolution-dxs-verification-2026-10-19.md) for IDs and staged evidence. The results below belong to the original OM2-04 implementation.

After the bare-JID routing correction, the combined final affected gate passed **144 tests / 0 failures** across seven suites, including all 107 timestamp cases above plus routing, native fanout, outgoing metadata and encrypted send availability. Cached signed physical build passed and both installed processes then reported UUID `C5975C55-FAB4-3A35-BBDD-792A12FDE2E1`; startup authentication, bundle ACKs and device lists1+1 are verified. Current-binary physical wire/native/datastore checks passed400/400 simultaneous live messages and300/300 first MAM-decrypted offline/archive messages, each with exact authenticated plaintext and zero missing/duplicate/error rows. After normal relaunch the user reports an empty encrypted chat and error on iPad: visible archive restoration remains unverified/failed and task closure is reopened. Initial presence was held only as debugger test isolation until archive proof; normal presence was restored and proof repeated. Debuggers detached, both apps normally relaunched, disposable build/test artifacts removed and Codex caches preserved. Physical scope is1+1devices;3recipient fanout remains a native in-memory fixture. The then-open UI failure is recorded as a resolved historical stage in the linked final report.

At that historical stage, the subsequent empty-chat/archive-opening correction passed **611/611tests,0failures** across27affected classes, including presentation104,read27 and sync98. Raw unread IDs resolve through actual persisted outer MAM identity or owned query binding; no ID-derived message time. Bounded first-unread continuation and valid same-conversation display on error preserve archive/read/paging proof guards. First-frame/context lifecycle cases pass after tests-first repairs. Cached signed build passed and the same main product is installed on both devices: main UUID `3F217697-5070-300E-92A2-25DEB06D52C8`, code dylib `1A6F1850-2475-3EB0-ACAD-509425EB156F`. Initial normal iPad UIKit/screenshot passed before any explicit latest request with55real/55resident rows; both baseline directions and fresh400live native/wire proof passed; late-error watch, error-banner, fresh300archive and ordinary relaunch were still unverified at that stage. Those checks later completed as scoped in the final report. The prior C5975C55physical crypto/store evidence does not satisfy these new visible acceptance gates.

Tests-first RED: 72 selected tests compiled with 90 failures (including 23 unexpected). The real-ciphertext receive suite alone exposed 10 expected failures in missing time/source checks. KissXML optional serialization and the expected-error test helper were corrected during fixture stabilization. The first GREEN exposed missing programmatic child namespaces in the builder; explicit SCE namespaces fixed that production issue.

Final cached Simulator verification: **256 tests / 0 failures**, then **83 tests / 0 failures** on the final source revision. The latter rerun covers strict unqualified timestamp attributes and removal of the temporary RED initializer default; it is not an additional 83 distinct scenarios. Dedicated affix suite: 55; SCE receive suite: 28 (12 added in this task). Regression suites: payload codec13, app integration18, outgoing metadata14, receive routing25, trust protocol8, queue synchronization45, client sync pagination50.

`Debug` test actions on iPhone16Pro / iOS26.0 built the app with its push extension dependency. Compiler/linker/test errors are absent in the successful gates; no separate Debug build or cache clean was run. Static audit confirmed all production codec callers supply original-time context and the final encryption writer normalizes time/padding before sealing. `git diff --check` passes. No live server or independent peer test was performed.

```sh
TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
XABBER_DESTINATION='platform=iOS Simulator,id=91E09D3E-4BBC-4431-9EAF-14D2410E7B98' \
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/OMEMO2SCEAffixTests \
  -only-testing:xabberTests/OMEMO2SCEReceiveTests \
  -only-testing:xabberTests/OMEMO2PayloadCodecTests \
  -only-testing:xabberTests/OMEMO2AppIntegrationTests \
  -only-testing:xabberTests/OMEMO2ReceiveRoutingTests \
  -only-testing:xabberTests/OMEMO2OutgoingMetadataTests \
  -only-testing:xabberTests/XEPTrustProtocolTests \
  -only-testing:xabberTests/MessageManagerQueueSynchronizationTests \
  -only-testing:xabberTests/ClientSynchronizationPaginationTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```


Historical physical qualification after611: intentional iPad offline/latest hid279valid rows (0real,skeletontrue,fallbackfalse,canReadtrue), exposing an uncovered offline-skeleton path. At that stage visibility acceptance reopened and required another regression/fix/gate/build. The final1463gate and current-code physical proof above now resolve that failure. Initial/live400native proofs remain valid components, but a last-message service-unavailable132.457msafter unavailable is separately under ACK diagnosis; native crypto failure is not inferred. The fresh300series had not started then; the separate final-code series is now complete.
