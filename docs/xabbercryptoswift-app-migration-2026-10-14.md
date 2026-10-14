# XabberCryptoSwift app integration

The app replaces SignalProtocolC/SignalProtocolObjC with the public API of XabberCryptoSwift at immutable revision `bd5d19dbd8e9de2521c8830f54564d3cc175cba8`. SwiftPM fetches the user's repository over SSH. App-owned OMEMO types adapt key generation, bundle validation, envelope candidates and snapshots; XMPP/SCE, trust, routing and durable Keychain storage remain in Xabber.

The prior accepted cutover policy excludes import of previous libsignal identities/snapshots and legacy ciphertext decoding. Existing protected pending/plaintext/OMEMO opt-out decisions migrate through a domain-only DTO (version/profile/owner/decision records); old key/session fields are never decoded. Pending decisions remain authoritative before native preparation, and invalid/inaccessible policy blocks sends rather than becoming absence. A separate protected state namespace creates a fresh Ed25519 seed identity and native sessions. Fingerprints change and devices must be verified again; previously decrypted local history is preserved by additive Realm schema26. Old Realm type names are retained to preserve database compatibility.

The previous Signal Pods, bootstrap manifests/patches, Signal runtime contexts/store protocols and archive reader are removed. The package carries its own authorized libsodium1.0.22 binary; ISC/BSD redistribution notices are included in app resources.

The protected aggregate keeps serialization per owner and commits candidate state and OPK changes together before releasing ciphertext/plaintext. Native snapshots bind exact owner/peer/device slot and local/peer identities. Initial native EK replaces the prepared placeholder in one save. Local device credentials are updated to the committed new SID after fresh registration.

RFC7748 public-coordinate equality is used only for session routing and diagnostic DH tracking. Cryptographic verification retains exact received bytes. Replay evidence normalizes unMAC-bound outer envelope semantics while preserving the exact authenticated inner message/MAC, so EK/protobuf aliases cannot reaccept an already authenticated packet after snapshot pruning. The native skipped-key receive-event horizon also bounds app mirror metadata; a1002-DH regression protects delayed-chain counters.

## Files

- `Podfile`, Xcode project and SwiftPM lock: pinned native dependency, Signal removal and licenses.
- `OMEMO2CryptoBackend.swift`, OMEMO manager/bundle/payload/identity helpers: native API adapter and crypto calls.
- `XabberOMEMO2Storage.swift`, `CredentialsManager.swift`, Realm migration/identity model: protected native state and domain cutover.
- `OMEMO2ReplayProtection.swift`: stable exact-inner replay evidence.
- `OMEMO2XabberCryptoIntegrationTests.swift`, `OMEMO2CryptoBackendStorageTests.swift` and affected existing suites: consumer/regression coverage.
- Retired Signal preparation files, store callbacks, commented legacy manager and external ObjC tests were removed.

## Verification

Final verification2026-10-14: 627/627 hosted XCTest passed across46 selected classes using cached Debug test action, concrete iOS26.0 Simulator91E09D3E-4BBC-4431-9EAF-14D2410E7B98, both account-autoconnect-disabled/isolated-storage flags and ad-hoc code signing. This successful action built app+push-extension dependency graph, so no separate Debug build was run. Native package392/392; independent export suite7/7 and actual Twomemo18 packet accepts/10 payload opens/6 replay rejections,6 fresh signatures and12 mutations rejected. Git whitespace/project lint and package/notice inventories passed. Built app dynamically links XabberCryptoSwift, has no SignalProtocol frameworks/imports/linkage, and contains the required license notices. Live XMPP exchange and minimum iOS15.6 runtime were not executed.


Hosted command: `TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 XABBER_DESTINATION="platform=iOS Simulator,id=91E09D3E-4BBC-4431-9EAF-14D2410E7B98" tools/xcodebuild_cached.sh test` with one `-only-testing:xabberTests/<class>` per selection below, `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -parallel-testing-enabled NO`.

<details>
<summary>Verified XCTest classes</summary>

```text
AKESystemMessageLocalizationTests
AppLaunchEnvironmentPolicyTests
ChatHistoryRealmMigrationTests
ChatSearchGoalSafetyPolicyTests
EncryptedChatSendAvailabilityPolicyTests
ForwardSendLifecycleTests
OMEMO2AppIntegrationTests
OMEMO2BootstrapBundleTests
OMEMO2BundleCacheIntegrationTests
OMEMO2BundleCodecTests
OMEMO2BundleDiagnosticsTests
OMEMO2CryptoBackendStorageTests
OMEMO2CryptoKitConformanceTests
OMEMO2IdentityBindingTests
OMEMO2NormativeCleanupRestartTests
OMEMO2NormativeDeviceProjectionTests
OMEMO2NormativeDevicesTests
OMEMO2NormativeEditTests
OMEMO2NormativeEditedSyncTests
OMEMO2NormativeIncomingTrustLocalizationTests
OMEMO2NormativeIncomingTrustRenderingTests
OMEMO2NormativeIncomingTrustStorageTests
OMEMO2NormativeIncomingTrustTests
OMEMO2NormativeKeyMaintenanceTests
OMEMO2NormativeOptOutLocalizationTests
OMEMO2NormativeOptOutTests
OMEMO2NormativeOptOutTransportTests
OMEMO2NormativeOptOutUITests
OMEMO2NormativePreKeyCleanupTests
OMEMO2NormativeRegistrationTests
OMEMO2NormativeReplayHistoryTests
OMEMO2NormativeReplayTests
OMEMO2NormativeRewriteAuthorityTests
OMEMO2NormativeSessionRecoveryTests
OMEMO2NormativeSessionRecoveryUITests
OMEMO2NormativeSyncCleanupTests
OMEMO2OutgoingMetadataTests
OMEMO2OwnDeviceBindingTests
OMEMO2PayloadCodecTests
OMEMO2ReceiveRoutingTests
OMEMO2SCEAffixTests
OMEMO2SCEReceiveTests
OMEMO2StateStorageTests
OMEMO2XabberCryptoIntegrationTests
OmemoSessionLifecycleTests
XEPTrustProtocolTests
```

</details>
