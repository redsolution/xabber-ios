# OMEMO bundle profile and device visibility

The 2026-10-06 runtime report contains 191 rejected publications with 33-byte IK/SPK and 64-byte signatures. 190 fail key length; one fails key ID. The log has no raw XML, so this evidence identifies the length mismatch without proving the first byte or each runtime publisher.

## Wire contract

For `urn:xmpp:omemo:2`, decoded IK is 32-byte Ed25519, SPK/OPKs are 32-byte X25519 and the signature is 64-byte EdDSA. [XEP-0384 §4.2](https://xmpp.org/extensions/xep-0384.html#protocol-key_exchange) defines the encodings via [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032#section-5.1.5) and [RFC 7748](https://www.rfc-editor.org/rfc/rfc7748#section-5). This requirement was already present at the 0.8.0 introduction of the modern namespace. Legacy Signal prefixed Curve keys are incompatible; removing a byte does not convert identity/signature schemes.

## Own device association

Fresh XMPP session registration can complete before the protected OMEMO2 SID. The current DeviceStorageItem then retains -1, and server list refresh can clear omemoDeviceId when omemo-id is omitted. UI bundle lookup uses that association; the own SID is also excluded from unmapped-device presentation.

Rebuild the exact current session association from AccountStorageItem.deviceUuid and the committed protected localBundle. Do this both during preparation and after devices responses. Do not create a session row or mutate remote devices/PEP membership. A binding-only repair leaves accepted publication/trust flags intact and schedules no republish. This repair reads existing keys; it does not create or rotate them.

## Original stanza XML in debug logs

The user explicitly requires that diagnostic stanza XML remain unchanged. Debug builds emit `OMEMO_BUNDLE_XML` using the complete original stanza's `xmlString`: incoming bundle IQs before admission, complete bundle headlines, the actual outgoing own-publish IQ, and its matched response. The logger performs no reconstruction, field removal, redaction, Base64 normalization, or truncation; all advertised prekeys and extensions remain present. Diagnostic metadata is outside the XML.

The scope is the existing bundle routes. Global full-stanza logging remains disabled. Default bundle XML logging is disabled in Release. `outcome=observed` records transport evidence; accepted publication, trusted identity and session readiness remain separate authorities. Strict codec failures do not prevent the original incoming stanza from appearing in the Debug log.

## Changed files

- `xabber/xmpp/omemo/OmemoManager.swift`: original incoming/headline XML and post-device-list binding reconciliation.
- `xabber/xmpp/omemo/OmemoManager+Encryption.swift`: committed-profile-only current-device metadata repair.
- `xabber/xmpp/omemo/OmemoManager+BundlePublication.swift`: original outgoing own IQ and matching result/error XML.
- `xabber/xmpp/omemo/OMEMO2BundleDiagnostics.swift`: original stanza pass-through and separate diagnostic metadata.
- `xabberTests/OMEMO2OwnDeviceBindingTests.swift`: five own-association/publication-proof regressions.
- `xabberTests/OMEMO2BundleDiagnosticsTests.swift`: seven original-stanza equality regressions.
- `xabber.xcodeproj/project.pbxproj`: source/test registration.
- This report.

## Verification

Own-binding TDD RED confirmed five cases with four expected failures before implementation. Original-stanza tests exposed the previous diagnostic serializer before replacing it; seven cases check complete IQ/headline/publish, additional attributes/elements, namespace prefixes, Base64 whitespace, all 1000 prekeys and the Debug switch. Final cached Debug Simulator test action passed 151/151 cases (including five own-binding and seven exact-stanza cases), with app and push extension built and no compiler/linker errors. No separate build followed the successful test action. Live server publication/interoperability remains unverified; incompatible peer bundles require publisher migration.

Verification command uses `tools/xcodebuild_cached.sh test`, scheme Debug, destination `platform=iOS Simulator,id=91E09D3E-4BBC-4431-9EAF-14D2410E7B98`, `-parallel-testing-enabled NO`, `CODE_SIGNING_ALLOWED=NO`, and these ten class filters: OMEMO2OwnDeviceBindingTests, OMEMO2BundleDiagnosticsTests, OMEMO2BundleCodecTests, OMEMO2BundleCacheIntegrationTests, OMEMO2BootstrapBundleTests, OMEMO2NormativeRegistrationTests, OMEMO2NormativeKeyMaintenanceTests, OMEMO2NormativeDevicesTests, OMEMO2NormativeDeviceProjectionTests, OMEMO2NormativeSessionRecoveryTests. Disposable verification logs/results are removed after recording the result; stable Xcode caches remain.
