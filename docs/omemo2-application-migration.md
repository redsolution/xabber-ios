# OMEMO2 application binding and state migration

This stage connects the explicit OMEMO2 provider in the existing local SignalProtocolC and SignalProtocolObjC forks to Xabber iOS. No additional dependency is localized or upgraded. The dependency implementation and pins remain documented in [omemo2-dependency-profile.md](omemo2-dependency-profile.md).

## Migration contract

- Existing device ID and the checked X25519 private identity scalar are preserved. The new public identity uses raw Ed25519 bytes; the displayed fingerprint is the raw X25519 public key, grouped for readability.
- Old Signal snapshots are never imported into the new ratchet. They remain separately tagged `legacy-signal`; successfully decrypted chat history is retained. An old v3 Signal frame with an existing legacy session selects the explicit history receiver. A failed OMEMO2 MAC never selects Signal.
- A single protected Keychain item per account contains profile/version, local private keys, consumed OPKs, session snapshots and pending controls. Load/authentication/SCE validation/write failures do not replace the persisted state. Production uses the configured shared Keychain group and `AfterFirstUnlockThisDeviceOnly`; only explicitly isolated hosted XCTest omits the access group.
- Realm schema 22 marks pre-existing bundle/session records as legacy. Only public metadata enters Realm. Manual device trust survives a representation change when the canonical X25519 keys match. A different key revokes trust and clears active sessions. A certificate signature covering only a timestamp cannot grant device trust.
- Missing or inconsistent identity/state fails closed. Re-running preparation is idempotent; migration does not regenerate an existing identity. After migration the aggregate supplies the device ID and private scalar even if legacy credentials are missing or stale.

## Wire and session behavior

| Path | New behavior |
| --- | --- |
| Outgoing user content | Trusted devices only; IDs are scoped by JID. New sessions require a validated raw Ed32/X32 bundle, mandatory OPK and identity matching the trusted fingerprint. Existing matching sessions survive bundle-cache eviction or a stale bundle. |
| Repeated outgoing KEX | Same EK and advanced counter until an authenticated reply; `kex=true` alone is not a session reset. |
| Incoming content | Validate strict XML/Base64/IDs, inner MAC, payload MAC and SCE structure/from/to before committing ratchet and OPK consumption. Archived/receive-only KEX cannot replace current identity metadata or trust. |
| Empty control | Exactly 32 zero bytes, absent payload; no chat text or notification content. ACK targets only the original sender device; authenticated regular ACK ends KEX without a reply loop. |
| Heartbeat | Persistent first-observed remote DH marker at counter >=53; receive-only and archived sessions cannot confirm the current session. |
| Bundle publication | Correct raw keys and replenished OPKs. Only matching IQ result and current bundle hash mark it published; precondition failure configures then retries. |
| Trust/AKE | Transport Ed25519 identity remains separate from X25519 ECDH/fingerprint. New signature failures have no legacy verifier fallback. |

Local resource policies: at most 64 retained snapshots per peer/device (oldest archived snapshots pruned), 1000 observed ratchet keys per snapshot, 1000 advertised OPKs. Signed prekeys rotate on preparation after seven days; retired SPKs remain for another seven days. Consumed OPKs are excluded from published bundles and retained privately for archive recovery.

## Verification and remaining boundaries

Dedicated XCTest covers state migration, checked Keychain persistence, profile separation, corruption, delayed/replayed KEX, OPK reuse, SPK rotation, heartbeat, bundle intake/publication, identity/signature compatibility, payload/SCE validation and actual manager send/receive/ACK routing. The final signed Simulator gate on 2026-10-02 passed all 124 selected tests and built the app and push extension.

The current archive subsystem exposes persistence-confirmed per-page completion, but no account-wide catch-up barrier. `finishCatchUp()` is deliberately not called from raw MAM `<fin>`, per-page completion or chat-list synchronization. Used OPK cleanup needs a proven archive-completion coordinator; retaining keys is the safe migration policy for this stage.

OM2-04 adds comparison with reliable original stanza/forwarded send time, with typed unavailable when that context is absent, strict routing/time affixes and minimum outgoing padding; see [the contract](omemo2-sce-affixes.md). Legacy Signal decrypt still has its inherited non-transactional state behavior. Live server and web/iOS interoperability has not been exercised here. A peer still publishing legacy Signal bundles under `urn:xmpp:omemo:2` cannot establish a new OMEMO2 sending session. This stage does not assert complete client conformance beyond the covered paths. The inherited C curve arithmetic UBSan limitation from the dependency stage remains recorded separately.

## Final verification — 2026-10-02

| XCTest suite | Passed |
| --- | ---: |
| OMEMO2AppIntegrationTests | 18 |
| OMEMO2BundleCacheIntegrationTests | 10 |
| OMEMO2BundleCodecTests | 10 |
| OMEMO2StateStorageTests | 29 |
| OMEMO2IdentityBindingTests | 23 |
| OMEMO2PayloadCodecTests | 12 |
| OMEMO2CryptoKitConformanceTests | 5 |
| OmemoSessionLifecycleTests | 5 |
| ChatHistoryRealmMigrationTests | 8 |
| ClientSynchronizationPaginationTests, selected affected cases | 4 |
| **Total** | **124** |

Command: `tools/xcodebuild_cached.sh test` with the listed XCTest selections, concrete iPhone 16 Pro Simulator UUID `91E09D3E-4BBC-4431-9EAF-14D2410E7B98`, `CODE_SIGNING_ALLOWED=YES`, `CODE_SIGN_IDENTITY=-`, and both `TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1` / `TEST_RUNNER_XABBER_ISOLATED_STORAGE=1`. The successful test action built the affected targets; no separate Debug build is required. `python3 tools/local_dependencies.py check` verifies both existing Signal repositories; `git diff --check` passes.

Final review regressions additionally prove that a stale bundle cannot create a session for a different trusted fingerprint, a correct current session continues despite a stale bundle, and a delayed old KEX decrypts history without replacing the trusted current identity. The device-ID resolver reuses the aggregate when legacy credentials are missing or different and refuses fresh IDs for lost/corrupt migrated state.

Disposable logs/result bundles are removed after recording the result. Stable Codex DerivedData, SourcePackages and PackageCache are retained.
