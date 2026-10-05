# OM2-N03 — Protected message edits with the existing Xabber server

Implemented in iOS only. The server is the implementation reference, per the user's instruction; no server or Signal library files are changed.

## Sending

The final rewrite sender determines encryption from the persisted conversation. New body/references and client content use the existing OMEMO2 SCE builder, recipient membership/trust checks and EME normalization. Encryption failure transmits no replacement and registers no IQ. The outer rewrite IQ and its archive target remain open; fallback body, plaintext receipts/markers and existing hints remain as agreed.

The pinned server codec accepts the nested message/body in `https://xabber.com/protocol/rewrite`, and emits notifications in `https://xabber.com/protocol/rewrite#notify`. The sender adapts this transport namespace separately from the authenticated SCE `jabber:client` body. Available original routing, origin ID and thread are recovered from the in-memory stanza or app-private persisted XML. Missing or unusable original XML uses known account/conversation bindings without inventing an original XML ID/resource/thread; the server preserves archived core routing.

## Receiving and version time

The common receiver recognizes exact rewrite message QNames, including legacy `jabber:client` transport. Foreign names remain inactive. Ordinary server rewrite bodies are translated to client body semantics only inside the recognized notification; encrypted content comes exclusively from verified SCE. An encrypted rewrite can mutate history/cursors only under the owning account-server wrapper.

The server replaces archived XML while retaining creation/archive timestamps. The fresh SCE time is checked against the server replacement version timestamp, before ratchet state commit. The original Delivery/delay metadata remains unchanged. Replacement metadata must have the exact namespace and one valid stamp. Direct peer XML and forged wrappers cannot supply this override, and failed decrypt never restores the marker. Protected replacement markers in legacy history retain their previous semantics.

Sync snapshot and push strip archive wrappers on the server. Their receivers pass internal `OMEMOReceiveServerContext.accountServer` only after account-server ownership checks; snapshots also require the existing tracked request/generation. Ordinary raw sync preparation defaults to unverified. This context grants timestamp authority, never decryption success. Preview authentication continues to require the typed receive result; controls/duplicates do not replace visible previews or create messages.

## Server evidence

Read-only checkout: `/Users/igor.boldin/projects/xabber/server`, HEAD `cc0dfcd27c6dbb6aef172bd89dccb902acaafee0`.

- `src/mod_retract.erl`, `do_replace_message`: archive body/subelements change; old stanza routing and archive timestamp remain.
- `src/mod_mam.erl`, archived message conversion: Delivery/archive dates retain creation time.
- `src/mod_sync.erl`, `convert_message`, snapshot result and sync push: current XML is embedded directly; own-account IQ routing supplies server ownership.
- [Pinned rewrite codec, commit37c58c9](https://github.com/redsolution/xmpplibrary/blob/37c58c935464d8c2b7fa67b85fba3bed0eaeeba1/src/xep_rewrite.erl): message/body encoding at772–798, decoding at879–907. Replacement from/to are optional and echoed; XML id/type are not replacement record fields.

The KB's stricter full-resource/immutable-field requirements are not implemented by this server. They were not imposed as additional iOS preconditions.

## Verification

Tests were added first with real ciphertext and final serialized IQ checks. Initial edit tests exposed plaintext replacements; authority tests exposed peer-wrapper archive mutation; edited-sync tests exposed the old-creation/new-version time mismatch. Actual server-QName and missing-source tests failed before the compatibility fixes.

Test files: `OMEMO2NormativeEditTests.swift`, `OMEMO2NormativeRewriteAuthorityTests.swift`, `OMEMO2NormativeEditedSyncTests.swift`. Live interoperation with a running server is not exercised by the simulator fixtures.

Final cached Debug Simulator gate: **351/351 passed**, including N01 devices22 + UI4, N02 registration16, N03 edit14 + authority3 + editedSync8, crypto/payload/identity/state/SCE/live/MAM/carbon routing,11 sync-preview regressions,8 unchanged trust-protocol cases and25 push cases. App and push extension compiled/linked; no compiler/linker errors. Used isolated storage/autoconnect-off and Simulator91E09D3E-4BBC-4431-9EAF-14D2410E7B98. No clean/cache reset or extra Debug build.

The first combined348 gate passed345 cases and exposed two pre-existing push thumbnail failures. Actual server/XEP-0264 QName repair is isolated in commit `7d3598a2`; standard/prefixed thumbnails now work, legacy files thumbnails remain supported, foreign thumbnails cannot produce preview/download candidates. Re-running the same gate with three added thumbnail regressions passed351/351.
