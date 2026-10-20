# OMEMO physical verification: redsolution ↔ DXS

**PASS — completed 2026-10-20.** Both devices have the final signed application, code UUID `CB5CD433-38D8-31B3-9190-76D285C09879`. The final signed simulator gate passes **1463/1463 tests**, without failures, unexpected failures or skips. A new clean cold-MAM series passes **300/300 authenticated messages** before and after normal presence restoration and again after ordinary relaunch. Messages remain visible; offline status does not cover them. Actual final SM ACK → unavailable-send → TCP-close is verified on both devices.

The earlier simultaneous **200 messages from each side (400 total)** passed on 2026-10-19, on code `818C208E`. It is historical load-test evidence, separate from today's final-code cold300 proof. Physical testing uses one trusted device per account; three-recipient peer/own-device fanout is covered by native fixtures.

Implementation, automated verification, physical acceptance and cleanup are complete. The exact commit reference is maintained in the [completed vault task](/Users/igor.boldin/projects/xabber/xabber/projects/xabber/tasks/done/xab-omemo-redsolution-dxs-physical-verification-2026-10-19.md).

## Final acceptance

| Requirement | Result |
| --- | --- |
| Latest shared product on both devices | PASS; signed app installed over existing data, actual loaded code UUID matched both |
| Automated affected gate | PASS 1463/1463, signed 78 classes including all 46OMEMO2 classes; zero skipped |
| Fresh cold archive series | PASS 300/300 exact plaintext, authenticated owner/peer/SID, exact trusted fingerprint, replay32 and MAM provenance; missing/bad/duplicate arrays empty |
| Cold isolation and ordinary opening | Recipient main0 before sending; zero expected rows at cold baseline; normal `.chatMessage` route produced 32 real rows / 13 visible cells before explicit latest |
| Actual archive wire | PASS 300 actual bare encrypted sends +300 own-server receipts +300 unique direct MAM results; four owned finished queries 80+100+100+20 |
| Archive stage isolation | Naked/live expected deliveries0 and available presence before last owned fin0; no duplicate, shape, route, query, message-error or date-conflict failures |
| After presence restoration | Normal presence restored after disabling the hold; native 300/300MAM still valid, with no missing/bad/duplicates |
| Stored message dates | PASS sender300/300 + receiver300/300, using only qualified time/delay; maximum deltas 0.000994921s/0.000997066s, below 1 ms formatter precision |
| Offline display | PASS 80 → 80 retained window rows, required latest content kept,12 real visible cells, clipping active, missing/overlaps0, skeleton=false, no read/paging authority |
| Banner geometry | PASS; bannerMaxY146.5, viewportMinY154.5. Floating-header shrink/resize/recovery regression included in final gate; actual screenshot inspected |
| Normal relaunch | PASS; normal launches with arguments=[] and startStopped=false, no test flags. iPhone3378/iPad2214; authenticated/ready, banner hidden, native 300valid, duplicates 0, latest visible |
| Runtime cleanup | Complete; debuggers detached, all captures stopped, presence hold absent, both main apps normally running |

The final normal UI proof reports `pass=true`, `authenticated=true`, `ready=true`, `bannerHidden=true`, expected/valid 300, duplicates 0 and latestVisible=true. Its current resident dataset has37real rows; this is a visible window over300durable checked series rows, not a claim that300bubbles are simultaneously onscreen.

## Actual graceful-close evidence

These are primary-stream actual-send callbacks, not send invocation, native decryption or own-server receipt inference. Both unavailable stanzas are broadcast and neither scope has a failed unavailable.

| Device | Exact request UTC | Actual ACK UTC | Actual unavailable UTC | TCP close UTC |
| --- | --- | --- | --- | --- |
| iPhone |07:44:26.830410 |07:44:26.836956, h1268 |07:44:26.838218 |07:44:26.843581 |
| iPad |07:44:28.680452 |07:44:28.684101, h549 |07:44:28.684747 |07:44:28.690762 |

All times are 2026-10-20UTC and establish transport ordering only. Message dates come exclusively from qualified message time/delay, never console timestamps, IDs or synchronization checkpoints.

## Accounts and preserved state

| Device | Account | OMEMO SID |
| --- | --- | --- |
| iPhone |`igor.boldin@redsolution.com` |201978182 |
| iPad |`test.omemo.igor@dxs.xabber.com` |504224163 |

The user replaced the original xmppdev01 iPad account with DXS. Its earlier authentication blocker is outside this pair. With explicit authorization, standard revocation removed 18other iPhone-account authentication devices; authoritative current OMEMO lists became 1+1. The current public fingerprints were matched and trusted through normal manual verification. Final install-over preserved accounts, identities, trust and history. No later crypto reset or synthetic history repair was used.

All message destinations are bare JIDs across the eight conversation types. Native fixtures additionally decrypt one stanza/one OMEMO payload for two trusted peer devices and one trusted own-other device, and verify fail-closed behavior for a missing required bundle. That fixture proof is distinct from physical 1+1 testing.

## User-visible corrections

- Archive opening resolves opaque unread/stanza references through an actual owned MAM binding; it never derives dates or archive cursors from raw IDs. Bounded continuation reaches the first eligible incoming row and handles proved exhaustion without an endless skeleton.
- Valid same-conversation content survives loading/error/offline states with display-only authority. Error fallback does not grant new archive coverage, paging or read authority. Live rows and UIKit completion/lifecycle ownership remain guarded.
- Known Recents content survives a stale fresh-session flag; preview selection, unread counters and deletion policy remain authoritative. A genuinely empty encrypted session keeps its invitation without invented content.
- Federated delivery times select actual account authority. Only qualified time/delay supplies message dates; missing preview dates use the existing unknown sentinel, not a synchronization stamp or ID-derived clock.
- A synchronization preview saves bounded protected opening material with its native ratchet. A later exact archive message with no durable authenticated history reruns MAC/SCE/address/time/canonical-identity validation before history admission. It creates no fake sync history or MAM coverage. See [SCE receive](omemo2-sce-receive.md) and [replay retention](omemo2-n04-replay-retention.md).
- Graceful shutdown waits for the matching actual unavailable-send callback after the final SM ACK. A bounded attempt owns stream/SM/ID/deadline and cancels stale work. Banner constraints follow changing floating-header geometry.

## Historical diagnostics and limitation

These earlier stages are **superseded by the final acceptance above**; their status wording is not current work.

| Earlier stage | Historical result and resolution |
| --- | --- |
|2026-10-19 simultaneous load, code 818 |400/400native/live, each side 200exact authenticated messages; actual send overlap 17.525724s. Qualified tag-date proof 804/804. This was not rerun as 400on CB5C |
| Earlier archive300 / empty iPad UI |Crypto/datastore passed but opening/target/offline presentation failed. Target binding, continuation, visible-content and lifecycle fixes were tested and passed final normal UI acceptance |
| Earlier Recents placeholder/unread94 |A stale fresh flag overrode linked real content. Producer and eight presentation consumers were corrected after meaningful RED; physical real-preview proof passed without fabricating counters |
| Earlier offline close |Actual ACK then premature TCPclose caused unavailable send failure. Final current-code actual callback order passes both |
| First 2026-10-20 B93 cold series |Wire300/300 but native299/300: a sync preview committed ratchet state without durable history/replay admission. The missing old QA message `~UgWMMkC` predates the recovery cache and remains unavailable as a history row; its fingerprint alone cannot safely reconstruct its opening material. It was not fabricated or reset. The separate fresh final-code300-ID series passes completely |
| Unsigned expanded simulator gate |Five Keychain cases/eight assertions failed with missing entitlement(-34018). The signed 5-case probe and complete signed 1463 gate passed unchanged, with no skips or weakened assertions |
| Imported simulator fixture crash |The user's report was a hosted-tests simulator fixture trap, corrected before final tests. It was not a physical-device crash. Original and normalized reports remain linked from the vault task |
| Diagnostic helper incidents |Earlier injected JSON/lazy-collection failure and missing JIT symbol were confined to private harnesses; they are not production-code regressions or passed QA attempts |

The intermediate report and full operational journal are retained privately/in the completed vault task. They are diagnostic history, not additional acceptance claims. Original test assertions and namespace/MAM-provenance validation were preserved when older fixtures were corrected.

## Verification and retained evidence

The successful signed test action built the affected application/test targets; no extra simulator build or clean was used. The final generic-iOS signed build succeeded and the same product was installed on both devices. The complete source freeze has 37 files and hashes; it records baseline HEAD `0a48a76d` and preserves prior authentication commits rather than altering them.

Current evidence is outside Git in `/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20`:

- [Final1463 structured result](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/final-recovery-signed-summary.json), [retained integration log](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/xabber-omemo-final-signed-20261020.log), [signed device build log](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/xabber-omemo-final-device-20261020.log).
- [Code/product proof](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/final-code-build-proof.json) and [source/hash manifest](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/final-recovery-source-manifest.json).
- [Before-presence wire audit](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/archive300-02-wire-audit.json), [postrestore wire audit](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/archive300-02-wire-postrestore.json), [combined300 proof](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/archive300-02-proof-summary.json).
- [Current phone SM proof](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/actual-sm-current-CB5C-iphone.json), [current iPad SM proof](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/actual-sm-current-CB5C-ipad.json), [normal UI readback](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/final-normal-ui-proof.json).
- [Cold archive screenshot](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/ipad-final-cold300-latest.png), [offline banner screenshot](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/ipad-final-offline-banner.png), [normal relaunch screenshot](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/ipad-final-normal-latest.png), each inspected by the lead.
- [Root artifact cleanup index](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/root-build-artifact-cleanup.json) and [initial-resume cleanup index](/Users/igor.boldin/Library/Logs/XabberOMEMODiagnostics/2026-10-20/initial-resume-artifact-cleanup.json). Sixteen disposable result bundles were removed after compact retention: root four, initial-resume five, UI two and XMPP five. Raw logs, compact summaries and hashes are preserved in root/resume cleanup indexes. Codex DerivedData, SourcePackages and PackageCache are preserved. Current device captures/manifests/proofs remain private.

The read-only host auditor checks actual stanza direction, bare destination, OMEMO shape/SID/RIDs/payload/plaintext absence, query/result/fin ownership and qualified time metadata. Its nine positive/negative checks and older retained-corpus validation passed. Overlap across different owned MAM queries is normal telemetry; same-query duplicates fail. Native exact body/trust/replay/date/UI proof is independently supplied by runtime readback.

## Changed files

The source freeze comprises 22 production files and 15 test files; the five repository documents are listed separately. Vault/KB operational memory is outside this Git repository.

### UI —10 files

- [xabber/controllers/chats/chat/ChatViewController.swift](../xabber/controllers/chats/chat/ChatViewController.swift)
- [xabber/controllers/chats/chat/extension/ChatViewController+AdditionalNavbarPanel.swift](../xabber/controllers/chats/chat/extension/ChatViewController+AdditionalNavbarPanel.swift)
- [xabber/controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift](../xabber/controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift)
- [xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift](../xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift)
- [xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift](../xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift)
- [xabber/controllers/chats/last_chats_list/LastChatsViewController.swift](../xabber/controllers/chats/last_chats_list/LastChatsViewController.swift)
- [xabber/controllers/chats/search/SearchResultsViewController.swift](../xabber/controllers/chats/search/SearchResultsViewController.swift)
- [xabber/controllers/chats/search/search_chat_list/SearchChatListViewController.swift](../xabber/controllers/chats/search/search_chat_list/SearchChatListViewController.swift)
- [xabber/controllers/chats/share/ShareDialogController.swift](../xabber/controllers/chats/share/ShareDialogController.swift)
- [xabber/controllers/chats/share/search/ShareDialogSearchController.swift](../xabber/controllers/chats/share/search/ShareDialogSearchController.swift)

### Protocol, storage and lifecycle —12 files

- [xabber/models/account/Account.swift](../xabber/models/account/Account.swift)
- [xabber/models/account/delegates/AccountStreamDelegate.swift](../xabber/models/account/delegates/AccountStreamDelegate.swift)
- [xabber/xmpp/XEP-0CCC/ClientSynchronizationManager.swift](../xabber/xmpp/XEP-0CCC/ClientSynchronizationManager.swift)
- [xabber/xmpp/messages/message_archive/MessageArchiveManager.swift](../xabber/xmpp/messages/message_archive/MessageArchiveManager.swift)
- [xabber/xmpp/messages/message_archive/engine/AccountArchiveEngine.swift](../xabber/xmpp/messages/message_archive/engine/AccountArchiveEngine.swift)
- [xabber/xmpp/messages/message_archive/engine/ArchiveDomain.swift](../xabber/xmpp/messages/message_archive/engine/ArchiveDomain.swift)
- [xabber/xmpp/messages/message_archive/engine/ArchiveTransportTypes.swift](../xabber/xmpp/messages/message_archive/engine/ArchiveTransportTypes.swift)
- [xabber/xmpp/messages/message_archive/engine/MessageArchiveTransportAdapter.swift](../xabber/xmpp/messages/message_archive/engine/MessageArchiveTransportAdapter.swift)
- [xabber/xmpp/messages/message_archive/engine/RealmArchiveCoverageRepository.swift](../xabber/xmpp/messages/message_archive/engine/RealmArchiveCoverageRepository.swift)
- [xabber/xmpp/messages/messages_manager/MessageManager+CommonSender.swift](../xabber/xmpp/messages/messages_manager/MessageManager+CommonSender.swift)
- [xabber/xmpp/omemo/OmemoManager.swift](../xabber/xmpp/omemo/OmemoManager.swift)
- [xabber/xmpp/omemo/storage/XabberOMEMO2Storage.swift](../xabber/xmpp/omemo/storage/XabberOMEMO2Storage.swift)

### Tests —15 files

- [xabberTests/AccountArchiveEngineTests.swift](../xabberTests/AccountArchiveEngineTests.swift)
- [xabberTests/AccountPrimaryStreamStanzaQueueTests.swift](../xabberTests/AccountPrimaryStreamStanzaQueueTests.swift)
- [xabberTests/ArchiveTransportReceiptTests.swift](../xabberTests/ArchiveTransportReceiptTests.swift)
- [xabberTests/ChatArchiveEnginePresentationTests.swift](../xabberTests/ChatArchiveEnginePresentationTests.swift)
- [xabberTests/ChatArchiveEngineUIContractTests.swift](../xabberTests/ChatArchiveEngineUIContractTests.swift)
- [xabberTests/ChatArchiveLegacyPagingHardCutTests.swift](../xabberTests/ChatArchiveLegacyPagingHardCutTests.swift)
- [xabberTests/ChatArchiveVirtualTimelineIntegrationTests.swift](../xabberTests/ChatArchiveVirtualTimelineIntegrationTests.swift)
- [xabberTests/ChatViewportReadBoundaryTests.swift](../xabberTests/ChatViewportReadBoundaryTests.swift)
- [xabberTests/ClientSynchronizationPaginationTests.swift](../xabberTests/ClientSynchronizationPaginationTests.swift)
- [xabberTests/LastChatsViewControllerBehaviorTests.swift](../xabberTests/LastChatsViewControllerBehaviorTests.swift)
- [xabberTests/OMEMO2NativeProtocolBehaviorTests.swift](../xabberTests/OMEMO2NativeProtocolBehaviorTests.swift)
- [xabberTests/OMEMO2NormativeEditTests.swift](../xabberTests/OMEMO2NormativeEditTests.swift)
- [xabberTests/OMEMO2SCEAffixTests.swift](../xabberTests/OMEMO2SCEAffixTests.swift)
- [xabberTests/OMEMO2SCEReceiveTests.swift](../xabberTests/OMEMO2SCEReceiveTests.swift)
- [xabberTests/xabberTests.swift](../xabberTests/xabberTests.swift)

### Repository documents —5 files

- [docs/omemo2-n04-replay-retention.md](../docs/omemo2-n04-replay-retention.md)
- [docs/omemo2-old-bundle-cleanup-2026-10-19.md](../docs/omemo2-old-bundle-cleanup-2026-10-19.md)
- [docs/omemo2-sce-affixes.md](../docs/omemo2-sce-affixes.md)
- [docs/omemo2-sce-receive.md](../docs/omemo2-sce-receive.md)
- [docs/omemo2-redsolution-dxs-verification-2026-10-19.md](../docs/omemo2-redsolution-dxs-verification-2026-10-19.md)
