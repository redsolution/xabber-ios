# OM2-04 — SCE routing, original time and padding

## Contract

Protected affixes use localName + namespace URI `urn:xmpp:sce:1`. Optional `from` and `to`, when present, must be unique empty affixes with an unqualified `jid` and a canonical bare JID matching the original encrypted leaf. Expected full JIDs are compared as bare JIDs. A present binding with no valid expected route is rejected. Group messages retain the existing required matching `to`; standard MUC sender mapping remains OM2-14.

Optional `time` must be unique, empty, and have an unqualified XEP-0082 `stamp`: explicit timezone, valid calendar fields, complete input, optional fractional seconds. Parsing preserves fractions to Foundation Date precision. Nested affix elements and non-whitespace text are rejected. Foreign namespace affixes have no binding semantics.

`OMEMOOriginalSendingTime` carries the Date and source independently of XML/provenance. The receive pipeline derives it from the validated original transport path, before reconstruction/decrypt:

| Source | Scope |
| --- | --- |
| `xabberDelivery` | Original encrypted leaf `{https://xabber.com/protocol/delivery}time` |
| `forwardedDelay` | Nearest validated original `{urn:xmpp:forward:0}forwarded/{urn:xmpp:delay}delay` |
| `stanzaDelay` | Original encrypted leaf `{urn:xmpp:delay}delay` |
| `caller` | Explicit internal context supplied by a caller |

Multiple available sources must describe the same instant. Xabber Delivery specifies that its timestamp equals the archive forwarded delay. Duplicate or malformed known metadata is rejected. Outer MAM/carbon/XEN receipt time, query/sync/conversation time, notification receipt time and the current clock are not substituted. Live, MAM/search, both carbons, background/UI-action, sync snapshot/push, modify and app push use the common receive preparation. The opaque TrustSharing adapter retains its inner forwarded delay and uses the same decoder; signatures/authorization/applyShare rules are unchanged.

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

[XEP-0420](https://xmpp.org/extensions/xep-0420.html), [XEP-0082](https://xmpp.org/extensions/xep-0082.html), [knowledge base XEP-DELIVERY](/Users/igor.boldin/projects/xabber/xabber-knowledge/protocols/XEP-DELIVERY.md), [implementation plan](omemo2-implementation-plan.md).

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
