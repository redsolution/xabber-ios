# PEP loading, request deduplication and stanza logging

Task: 2026-10-29 follow-up to [runtime log investigation](runtime-log-noise-2026-10-29.md).

## Behavior

Avatar metadata and ordinary OMEMO device/bundle updates use the existing PEP subscriptions. Preparing a stream does not enumerate the roster for avatar metadata, and an ordinary device-list notification does not fetch every bundle again.

Explicit missing-data requests remain available. Avatar image bytes are fetched only when metadata identifies an uncached data item. Explicit secret-chat preparation and protected recovery remain separate from unsolicited PEP updates; fresh correlated recovery IQs retain their authority requirements.

Explicit chat/send demand can promote an already pending ordinary device-list request instead of sending a second IQ. Lost device-list requests expire rather than blocking demand indefinitely. A forced device-list refresh without bundle-demand coalescing retains a new IQ ID and the existing latest-request-wins rule.

Equivalent avatar requests share one pending request for the same bare JID/node/item. Queue execution checks session and current metadata so a PEP update can supersede unsent metadata or old image-data work. Sent requests expire after 30 seconds on subsequent demand/response processing; errors and session reset release ownership. A late response cannot replace a newer PEP update.

Ordinary bundle requests share pending ownership for the same bare JID/device, including different stream resources. Ownership is reserved before startup deferral and retained through response projection, with a maximum of 256 ordinary requests and a 120-second timeout. Error, empty completion, reset and expiry release the reservation. Startup release checks whether PEP already supplied the validated identity. Fresh recovery uses its separately correlated request and is not swallowed by ordinary deduplication.

Every device item in a bundle PEP notification is validated independently. A malformed item does not hide valid siblings or a later corrected item. Crypto validation, membership/trust admission, key formats and persistence schema are unchanged.

Late extension preparation preserves PEP work already queued after initial presence. A real session reset invalidates queued publications, ordinary request ownership and explicit fetching intent.

## One XML owner

`ConnectionDiagnosticsLogger` preserves the complete supplied stanza serialization, including unknown fields, keys and long payloads, without redaction, truncation or string escaping. Identical wire frames are still logged separately; there is no global XML/content/ID deduplication.

The following routine metadata is quiet when it carries neither XML nor an error: healthy connection snapshots, per-stanza activity/outbound/correlation observations, SM acknowledgement counters and tracker timeouts explicitly marked `diagnosticOnly`. Actual errors, stale state, lifecycle events and unknown event types remain visible. Filtering happens before connection snapshot formatting and timeline work.

The secondary OMEMO observation logger no longer emits a second XML copy or a successful-observation summary. Bundle rejection diagnostics remain separate from the stream XML.

Primary custom send callbacks and received SM `a`/`r` frames retain complete XML. Their raw-counter and processed-ack metadata no longer produce additional routine log lines.

UIAction MAM completion has one XML emission whether it arrives through `willReceive`, `didReceive`, or both. Standard one-shot stanzas use their send callback, while custom XML retains its existing fallback. VoIP and background authentication use the canonical stream logger rather than additional `print`/DDLog XML copies. Failed-send XML remains complete.

## Validation

Test-first runs reproduce the old sweep, duplicate requests, missed PEP sibling item, repeated healthy diagnostics and supplemental XML copies. The test matrix covers PEP-first startup, exact item identity, concurrent duplicate submission, pending/queued cancellation, expiry/reset/error cleanup, strict sender correlation, fresh recovery, multiple PEP items, callback bypass and complete repeated wire frames.

Final cached Debug iOS 26.0 Simulator gate: **354/354 tests passed in 18 classes**, exit 0 / `TEST SUCCEEDED`. App and push extension built during the test action; no compiler/linker errors. No additional Debug build followed the successful test action.

| Suite | Tests |
|---|---:|
| ProfileHydrationTests | 25 |
| OMEMO2BootstrapBundleTests | 24 |
| OMEMO2ManagerLifecycleBehaviorTests | 49 |
| PEPDiagnosticLoggingTests | 7 |
| SupplementalStreamXMLLoggingTests | 6 |
| ConnectionDiagnosticsLoggerTests / AppLoggingPolicyTests | 12 |
| OMEMO2NormativeDevicesTests | 22 |
| OMEMO2NormativeRegistrationTests | 16 |
| OMEMO2NormativeSessionRecoveryTests | 37 |
| OMEMO2BundleCodecTests / OMEMO2BundleDiagnosticsTests / OMEMO2OwnDeviceBindingTests | 24 |
| AccountConnectionResilienceCoordinatorTests | 25 |
| AccountSendReadinessCoordinatorTests | 6 |
| AccountPrimaryStreamStanzaQueueTests | 77 |
| AccountGracefulStreamManagementAckTests | 12 |
| MessageArchiveQueryCallbackTests | 12 |

Command: `tools/xcodebuild_cached.sh test` with `XABBER_SCHEME=Debug`, destination `platform=iOS Simulator,id=91E09D3E-4BBC-4431-9EAF-14D2410E7B98`, both `TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1` and `TEST_RUNNER_XABBER_ISOLATED_STORAGE=1`, `-parallel-testing-enabled NO`, `-collect-test-diagnostics never`, `CODE_SIGNING_ALLOWED=NO`, and `-only-testing:xabberTests/<suite>` for the 18 classes above. No clean or cache reset. Disposable run logs/results were removed after recording the outcome; cached DerivedData/SourcePackages/PackageCache remain.

No physical-device or live-server verification was performed. A reduction in end-to-end runtime-log volume or network latency has not been measured on a new device capture. Incompatible incoming bundles still fail the existing strict codec.

## Changed areas

- AvatarReceiverManager and ProfileHydrationTests: PEP startup, request identity and lifetime.
- OmemoManager, Devices and BundlePublication extensions: ordinary fetch ownership, explicit demand, PEP projection and removal of the secondary XML observer. Bootstrap/lifecycle tests cover the protocol behavior.
- Account / AccountStreamDelegate: routine-event policy and complete custom/SM XML.
- UIAction, one-shot, background and VoIP stream delegates: one XML owner per callback path.
- Dedicated PEPDiagnosticLoggingTests / SupplementalStreamXMLLoggingTests and Xcode test-source registration.
