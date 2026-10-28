# Sync-first account startup — 2026-10-28

## User-visible order

After a full authentication, finish every XEP-SYNC page, transmit the account's initial available presence, and only then start automatic OMEMO, avatars/vCards, MAM, account-device queries, push registration and component/gallery discovery. A cached completed snapshot still requires the new authenticated session's stamped sync. Cached UI remains visible and committed pages can appear incrementally; UI rendering is not gated on background loading.

This explicit user instruction supersedes the prior roster-only presence rule and the removed global send guard. The ordering leak came from the removed primary-send guard, roster-driven presence/module preparation, and a delayed independent sync/device startup. Protection now begins at authenticated-session preparation, before SM readiness and before the first sync request.

## Implementation

- `Account` owns startup operation retention, the primary-send guard, roster/presence release, generation cancellation and scheduler admission.
- `ClientSynchronizationManager` retains a session startup-pending boundary across request errors and retries. Only a final committed page, including an authoritative empty result, completes it; the first page does not. Final snapshot stamps retain their existing final-page behavior.
- Own presence requires sync and roster readiness. Its actual `didSend` callback opens automatic background work. Modules are prepared before deferred producer operations so registration cannot invalidate a request started earlier in the drain.
- Primary MAM scheduler admission waits for startup even for restored visible intents carrying interactive priority; their terminal timer cannot start while XML is held for sync.
- Request producers defer before creating pending IDs, timeout metadata or push timers. Final primary `willSend` also guards direct callers. Already-owned durable user messages preserve their tracking policy across the second delegate boundary and retain their original prepared transport.
- Required roster, root/self disco, sync continuations, IQ result/error, SM/liveness and unavailable disconnect traffic remain admissible. Secondary interactive UI-action streams retain their own ownership.
- Disconnect/reset invalidates queued packets, deferred operations, cancellation callbacks and delayed retries. SM resume preserves actual transmitted presence and prior resolved roster; an interrupted startup still waits for its missing boundaries, without resending an already transmitted initial presence.
- A startup sync request without response times out after 60 seconds. Retry backoff is 1, 2, 4, 8, 16, then 30 seconds, scoped to the same startup/stream. Errors and timeouts never release background as if sync had succeeded.

No schema, dependency, crypto protocol, raw-XML logging or page-size change (40) is included. The sync page applier remains list-only; Account lifecycle release does not launch timeline work from page persistence.

## Files

Account orchestration: `Account.swift`, `AccountPrimaryStreamStanzaTracker.swift`, `AccountStreamDelegate.swift`, `AccountConnectBehaviorExtension.swift`.

XMPP producers: `ClientSynchronizationManager.swift`, `XMPPDeviceManager.swift`, `ServerDisco.swift`, `OmemoManager.swift`, `OmemoManager+Devices.swift`, `OmemoManager+Encryption.swift`, `PushNotificationsManager.swift`.

Tests: new dedicated `InitialSyncTrafficOrderingTests.swift`, its project registration, updated superseded startup assertions in `AccountPrimaryStreamStanzaQueueTests.swift`, `ClientSynchronizationPaginationTests.swift` and `xabberTests.swift`.

## Verification

Test-first baseline reproduced early presence/background dispatch. The initial 10-test run reported 32 assertions; one durable-message fixture assertion required in-memory protected policy state because the unsigned Simulator host cannot access production protected storage. The focused fixture was corrected without changing fail-closed crypto policy. A subsequent SM-resume fixture hang was sampled: fake synchronous main-thread `didSend` waited for the SM/account queue while that queue waited for Realm. Fake wire callbacks now use the real SDK's account delegate queue.

Final cached Debug Simulator test action passed 336/336 across InitialSyncTrafficOrderingTests (19), AccountXMPPTaskSchedulerTests (19), ClientSynchronizationPaginationTests (57), ClientSynchronizationManagerTests (44), ClientSynchronizationArchiveIsolationContractTests (8), AccountPrimaryStreamStanzaQueueTests (77), AccountGracefulStreamManagementAckTests (12), ProfileHydrationTests (14), PushPayloadModeRegistrationTests (12), OMEMO2NormativeSessionRecoveryTests (37), OMEMO2NormativeDevicesTests (22), and OMEMO2BootstrapBundleTests (15). App, push extension and test targets built successfully; no compiler/linker errors. iOS 26.0 Simulator, 91E09D3E-4BBC-4431-9EAF-14D2410E7B98, isolated storage/autoconnect disabled, code signing disabled. No separate build or cache reset.

Standalone PushRegistrationContractTests were attempted in the earlier integration run and failed in protected credential storage before the changed registration code (pushStorageFailure / unsigned host lacks AppGroup Keychain entitlement). They are not represented as passing; injected payload-mode registration tests pass. The old avatar fixture was updated from reset-as-success to actual final-page commit/presence. Live device/account/server latency was not measured and no speedup claim is made.

The restored-visible MAM admission regression failed with two expected assertions before the scheduler change, then passed. Requests time out only after actual scheduler admission; the startup sync response watchdog remains 60 seconds. Build logs, diagnostic fixture sample and result bundles were removed after recording evidence; reusable DerivedData, SourcePackages and PackageCache remain.
