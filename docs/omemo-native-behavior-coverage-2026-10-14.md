# Native OMEMO behavior coverage

Scope: the XabberCryptoSwift consumer introduced by the [native backend migration](xabbercryptoswift-app-migration-2026-10-14.md). Tests use the pinned public native implementation (`bd5d19dbd8e9de2521c8830f54564d3cc175cba8`), actual XMPP/SCE codecs, and application routing. Protected persistence is replaced with an in-memory fault-injection store where rollback and concurrency are under test; manager/history tests use isolated Realm and generated test owners. Capturing streams do not open sockets. Coverage of a public compatibility entrypoint does not imply a live APNs or server test.

## Behavior matrix

Each row includes successful behavior, rejected inputs, and the applicable state or persistence transition. The existing suites remain part of the gate; the seven new suites fill consumer-level gaps rather than repeating the library's primitive tests.

| Contract | Verified behavior | XCTest suites |
| --- | --- | --- |
| Identity representations and agreement | Explicit Ed25519 seed/scalar import, default representations, generated key round trips, all mixed representation DH pairs, malformed material and signature mutation rejection | `OMEMO2CryptoBackendBehaviorTests`, `OMEMO2IdentityBindingTests`, `OMEMO2CryptoKitConformanceTests` |
| Bundle admission | Wire namespace, canonical encoding, required fields, numeric bounds, duplicate/oversized keys, valid signatures, low-order DH rejection, decoded bundle revalidation, peer-slot cache isolation | `OMEMO2BundleCodecTests`, `OMEMO2BundleDiagnosticsTests`, `OMEMO2BundleCacheIntegrationTests`, `OMEMO2CryptoBackendBehaviorTests`, `OMEMO2ManagerLifecycleBehaviorTests` |
| First session and KEX | Prepared state spends no send counter; snapshot before first send; zero32 control or payload48 only; consumed OPK recovery; bad authentication preserves caller output and retry; only an authenticated reply leaves KEX | `OMEMO2CryptoBackendBehaviorTests`, `OMEMO2CryptoBackendStorageTests`, `OMEMO2XabberCryptoIntegrationTests` |
| Ratchet receive and conflicts | Delayed/reordered packets, repeated KEX, equivalent RFC7748 EK encoding, exact authenticated inner bytes, header/MAC tampering, simultaneous initiation and fresh-KEX rejection without losing the established exchange | `OMEMO2CryptoBackendBehaviorTests`, `OMEMO2NormativeReplayTests`, `OMEMO2XabberCryptoIntegrationTests` |
| Ratchet retention | More than 2001 DH transitions, bounded diagnostic metadata, restart, expired delayed packet denial without state mutation, and continuing current traffic | `OMEMO2CryptoBackendBehaviorTests`, `OMEMO2CryptoBackendStorageTests` |
| Snapshot binding | Owner/peer/device/identity/representation/revision binding, corrupted/truncated/native/prepared/mixed snapshots, duplicate/oversized ratchet metadata, transplanted owner denial | `OMEMO2CryptoBackendBehaviorTests`, `OMEMO2StorageBehaviorTests`, `OMEMO2StateStorageTests` |
| Atomic protected transactions | Initial/current/retained receive branches × validation/identity/policy/save failure; authentic retry; ciphertext/plaintext only after durable commit; observer after unlock; no partial OPK/session/replay changes | `OMEMO2StorageBehaviorTests`, `OMEMO2CryptoBackendStorageTests`, `OMEMO2NormativeReplayTests` |
| Concurrent storage instances | Same-owner outgoing counters and receives have no lost writes; concurrent first receives preserve both peers; one owner blocked in save does not block another owner | `OMEMO2StorageBehaviorTests` |
| Aggregate admission | Version/profile/backend/owner/device/key/counter/queue/replay/replacement/session shape, malformed controls, nonfinite SPK/grace/session dates, invalid OPK/session metadata, no silent regeneration or retired-state reads | `OMEMO2StorageBehaviorTests`, `OMEMO2StateStorageTests`, `OMEMO2OwnDeviceBindingTests` |
| Replay receipts | Same authenticated packet, aliases of unbound outer protobuf/EK fields, restart and pruning, bounded 4096-entry FIFO; changed MAC-covered bytes never alias an authenticated packet | `OMEMO2StorageBehaviorTests`, `OMEMO2NativeProtocolBehaviorTests`, `OMEMO2NormativeReplayTests`, `OMEMO2NormativeReplayHistoryTests`, `OMEMO2CryptoBackendStorageTests` |
| Account crypto deletion | Both standalone and caller-owned Realm transactions remove all eight owner projections and native/retired/legacy credentials, preserve the other owner, and remain idempotent | `OMEMO2AccountDeletionBehaviorTests` |
| Key lifecycle | ID boundaries including `Int32.max`, OPK replenishment/exhaustion and retry, consumed-key grace cleanup, SPK rotation, retained receive-only session after cleanup/restart, maintenance no-op produces no write | `OMEMO2StorageBehaviorTests`, `OMEMO2NormativeKeyMaintenanceTests`, `OMEMO2NormativePreKeyCleanupTests`, `OMEMO2NormativeCleanupRestartTests`, `OMEMO2NormativeSyncCleanupTests` |
| Native payload limits | Exactly 1 MiB UTF8 SCE round trip, one byte above limit, aligned oversized CBC, authenticated non-UTF8 and empty opaque content, malformed CBC lengths, payload/material presence cannot select control fallback | `OMEMO2NativePayloadBoundaryTests`, `OMEMO2PayloadCodecTests`, `OMEMO2CryptoKitConformanceTests` |
| SCE authentication | Protected from/to/time, exact validated original sending time, rpad, XML admission, affix and reference handling, Unicode and file metadata/origin ID, sanitized unprotected fallback | `OMEMO2SCEReceiveTests`, `OMEMO2SCEAffixTests`, `OMEMO2PayloadCodecTests`, `OMEMO2NativeProtocolBehaviorTests`, `OMEMO2OutgoingMetadataTests` |
| Multi-device send | Two contact recipients plus another own device authenticate the same payload/material; colliding numeric RIDs stay within recipient JID groups; self-chat excludes current device; no trusted-contact fallback through own devices | `OMEMO2NativeProtocolBehaviorTests`, `OMEMO2AppIntegrationTests`, `EncryptedChatSendAvailabilityPolicyTests` |
| Fanout failure and ACK | A bad recipient releases no partial outer ciphertext; fresh retry decrypts on every recipient; successful earlier recipient slots may already have committed; every recipient ACKs only the sender, no control loop, subsequent regular traffic | `OMEMO2NativeProtocolBehaviorTests`, `OMEMO2AppIntegrationTests` |
| Receive transport admission | Live/MAM/received-carbon/sent-carbon, exact owner and sender/recipient binding, malformed SID/RID/KEX/payload, nested or mixed transports rejected before mutation/proof, canonical boolean/Base64 replay | `OMEMO2NativeProtocolBehaviorTests`, `OMEMO2ReceiveRoutingTests`, `OMEMO2CompatibilityIngressBehaviorTests` |
| Compatibility ingress | `modifyOmemoStanza`, push preparation, both `modifySyncQuery` adapters, `decryptMessage`, explicit and Account-fallback receiver, preferred/fallback archive helper; content/proof/failure/control/duplicate/plaintext routing | `OMEMO2CompatibilityIngressBehaviorTests` |
| Archive persistence | One actual native row with archive ID, committed replay fingerprint and untrusted-sender warning; provenance remains typed during queued/materialized processing; duplicate queues no new message; query summaries are cumulative | `OMEMO2CompatibilityIngressBehaviorTests`, `OMEMO2NormativeReplayHistoryTests`, `OMEMO2NormativeIncomingTrustStorageTests`, `ChatHistoryRealmMigrationTests` |
| Stream and chat lifecycle | Enabled/disabled × prepared/fresh, disconnected stream, reset request state, own membership before fresh keys, actual Account publication/configuration ACK callbacks and default fresh-bundle fetching with authentication/timeout/cancellation guards, exact encrypted chat row creation/reuse, preserved regular history/drafts, real UI/account queue fallback | `OMEMO2ManagerLifecycleBehaviorTests`, `OMEMO2BootstrapBundleTests`, `OMEMO2NormativeRegistrationTests`, `OmemoSessionLifecycleTests` |
| PEP publication and device scope | Subscriptions/retractions exact node/JID/correlation, device and bundle refresh scoped by owner/peer, validated/malformed bundle headlines, newer/stale/unknown update timestamps, deletion excludes same-ID contact devices | `OMEMO2ManagerLifecycleBehaviorTests`, `OMEMO2NormativeDevicesTests`, `OMEMO2NormativeDeviceProjectionTests`, `OMEMO2NormativeRegistrationTests`, `OMEMO2BundleCacheIntegrationTests` |
| Trust and warnings | Unknown/untrusted/revoked/excluded devices, changed identity and trust-sharing rules, incoming proof and warning rendering/localization, sender warning persisted only for exact authenticated slot | `OMEMO2NativeProtocolBehaviorTests`, `OMEMO2NormativeIncomingTrustTests`, `OMEMO2NormativeIncomingTrustStorageTests`, `OMEMO2NormativeIncomingTrustRenderingTests`, `OMEMO2NormativeIncomingTrustLocalizationTests`, `XEPTrustProtocolTests` |
| Recovery and protected opt-out | Fresh request generation binding, retained sessions, invalid policy fail-closed, pending/resolved watermarks, consent/rejection, transport and UI/localization, no re-encryption on failure | `OMEMO2NormativeSessionRecoveryTests`, `OMEMO2NormativeSessionRecoveryUITests`, `OMEMO2NormativeOptOutTests`, `OMEMO2NormativeOptOutTransportTests`, `OMEMO2NormativeOptOutUITests`, `OMEMO2NormativeOptOutLocalizationTests` |
| Edits, sync and rewrite authority | Authenticated version/time authority, unknown/replayed edits, local history reconciliation, sync previews cannot serialize sender proof or display unauthenticated fallback | `OMEMO2NormativeEditTests`, `OMEMO2NormativeEditedSyncTests`, `OMEMO2NormativeRewriteAuthorityTests`, `OMEMO2CompatibilityIngressBehaviorTests` |
| Hosted-test isolation | Distinct test app identifier, both launch flags required, no production account autoconnect, isolated protected storage/Realm | `AppLaunchEnvironmentPolicyTests`, `ChatSearchGoalSafetyPolicyTests` |

## Regression results and measured coverage

Final verification: **749/749 hosted XCTest passed**, zero failures, unexpected failures or skips, across **53 selected classes**, including **122 new methods in seven suites**. The successful cached Debug test action built the app and push-extension dependency graph on the concrete iOS26.0 Simulator. No separate build or clean was run. No compiler/linker errors or new-suite compiler warnings remained. Initial instrumented baseline: 627/627 across 46 classes.

| New test file | Methods |
| --- | ---: |
| [OMEMO2CryptoBackendBehaviorTests.swift](../xabberTests/OMEMO2CryptoBackendBehaviorTests.swift) | 35 |
| [OMEMO2StorageBehaviorTests.swift](../xabberTests/OMEMO2StorageBehaviorTests.swift) | 25 |
| [OMEMO2NativeProtocolBehaviorTests.swift](../xabberTests/OMEMO2NativeProtocolBehaviorTests.swift) | 12 |
| [OMEMO2NativePayloadBoundaryTests.swift](../xabberTests/OMEMO2NativePayloadBoundaryTests.swift) | 6 |
| [OMEMO2ManagerLifecycleBehaviorTests.swift](../xabberTests/OMEMO2ManagerLifecycleBehaviorTests.swift) | 30 |
| [OMEMO2CompatibilityIngressBehaviorTests.swift](../xabberTests/OMEMO2CompatibilityIngressBehaviorTests.swift) | 12 |
| [OMEMO2AccountDeletionBehaviorTests.swift](../xabberTests/OMEMO2AccountDeletionBehaviorTests.swift) | 2 |

### Instrumented app coverage

Coverage is for the 19 source files under `xabber/xmpp/omemo/` in the `xabber.app` target; package, test and unrelated app sources are excluded. Line counts include compiler-emitted closure regions. They establish execution, not all branch combinations or complete correctness.

| Source file | Baseline covered / executable | Final covered / executable | Final line coverage |
| --- | ---: | ---: | ---: |
| `OMEMO2BundleCodec.swift` | 209/213 | 209/213 | 98.12% |
| `OMEMO2BundleDiagnostics.swift` | 28/29 | 28/29 | 96.55% |
| `OMEMO2CryptoBackend.swift` | 241/246 | 246/246 | 100.00% |
| `OMEMO2DeviceList.swift` | 34/34 | 34/34 | 100.00% |
| `OMEMO2OptOutPolicy.swift` | 183/188 | 183/188 | 97.34% |
| `OMEMO2PreKeyCleanupCoordinator.swift` | 191/191 | 191/191 | 100.00% |
| `OMEMO2ReplayProtection.swift` | 74/76 | 74/76 | 97.37% |
| `OMEMOReceive.swift` | 18/18 | 18/18 | 100.00% |
| `Omemo2IdentityRepresentation.swift` | 56/62 | 59/62 | 95.16% |
| `Omemo2PayloadCodec.swift` | 239/248 | 240/248 | 96.77% |
| `OmemoManager+BundlePublication.swift` | 423/485 | 455/485 | 93.81% |
| `OmemoManager+Devices.swift` | 278/287 | 278/287 | 96.86% |
| `OmemoManager+Encryption.swift` | 632/691 | 651/691 | 94.21% |
| `OmemoManager.swift` | 1074/1532 | 1434/1538 | 93.24% |
| `SignalDeviceStorageItem.swift` | 31/32 | 31/32 | 96.88% |
| `SignalIdentityStorageItem.swift` | 19/19 | 19/19 | 100.00% |
| `SignalPreKeyStorageItem.swift` | 13/13 | 13/13 | 100.00% |
| `XabberAxolotlStorage.swift` | 45/48 | 45/48 | 93.75% |
| `XabberOMEMO2Storage.swift` | 1114/1143 | 1141/1162 | 98.19% |

Aggregate OMEMO source coverage increased from **4902/5555 (88.24%)** to **5349/5580 (95.86%)**. Native adapter: **100%**; protected storage: **98.19%**; manager: **93.24%**.

The adapter has no unexecuted functions in the final report. Remaining uncovered app lines include legacy/default shims, some error/optional callback paths and display-error localization; forced native-provider faults and exhaustive scheduling/environment combinations are outside this measurement. The protocol/state behavior matrix above remains the acceptance contract.

Four production defects were reproduced before their fixes:

- Protected control addresses accepted empty JIDs and device IDs outside `1...Int32.max`. Aggregate admission now matches the public address contract.
- Binary plists can decode NaN/infinite dates; accepted SPK/grace/session dates could suppress rotation/cleanup or mutate a corrupted aggregate. All three lifecycle date families must now be finite before key derivation, restore or mutation.
- Own-device deletion filtered by owner and numeric ID, deleting contact devices with the same ID. Its predicate now includes the own JID.
- Account crypto deletion omitted the Realm opt-out projection. Both transaction modes now remove that exact owner's opt-out rows while retaining other owners.

Changed production files: [OmemoManager.swift](../xabber/xmpp/omemo/OmemoManager.swift) and [XabberOMEMO2Storage.swift](../xabber/xmpp/omemo/storage/XabberOMEMO2Storage.swift). The [Xcode project](../xabber.xcodeproj/project.pbxproj) registers the seven dedicated test files. No dependency, key format, snapshot version or Realm schema changed.

Runtime test fixture corrections retained the production checks: explicit `jabber:client` namespace inside forwarded XML, actual Xcode-forwarded isolation keys, known own-device membership before publication, transient Realm provenance assertions before persistence, cumulative query-summary semantics, and explicit Realm refresh after cross-queue writer completion. None changed cryptographic admission.

## Reproduction and practical limits

Use `tools/xcodebuild_cached.sh test -enableCodeCoverage YES` with `TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1`, `TEST_RUNNER_XABBER_ISOLATED_STORAGE=1`, and a concrete `XABBER_DESTINATION`. The recorded run uses iOS26.0 Simulator `91E09D3E-4BBC-4431-9EAF-14D2410E7B98`, `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -parallel-testing-enabled NO`, the 46 class selectors in the migration report, and one `-only-testing:xabberTests/<class>` selector for each new suite listed below. Use a fresh `-resultBundlePath` to extract coverage with `xcrun xccov view --report --json <result>.xcresult`. Xcode strips the `TEST_RUNNER_` forwarding prefix when setting the application environment.

New suites (122 methods): `OMEMO2AccountDeletionBehaviorTests`, `OMEMO2CryptoBackendBehaviorTests`, `OMEMO2StorageBehaviorTests`, `OMEMO2NativePayloadBoundaryTests`, `OMEMO2NativeProtocolBehaviorTests`, `OMEMO2ManagerLifecycleBehaviorTests`, `OMEMO2CompatibilityIngressBehaviorTests`.

The successful hosted test action builds the application and push-extension dependency graph. No separate build or cache reset is required. Disposable logs/result bundles are removed after the verified counts and coverage are recorded here; persistent Xcode caches are retained.

Account-wide Keychain removal and Realm deletion retain their existing separate-store orchestration; tests verify successful exact-owner cleanup, not a cross-store transaction under external Keychain failure. In-memory storage tests independently cover injected failed removals.

Live XMPP server exchange, APNs delivery, cross-client end-to-end server routing and the minimum iOS15.6 runtime remain unexecuted in this task. The prior native package's 392 tests and independent Twomemo interoperability verification are recorded in the migration report; they are not counted as new consumer tests here. Exhaustive coverage of every possible input, scheduling interleaving and environment is not implied by this behavior matrix or the line-coverage percentages.
