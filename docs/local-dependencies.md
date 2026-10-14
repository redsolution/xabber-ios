# OMEMO cryptographic dependency

Since 2026-10-14, Xabber iOS uses [XabberCryptoSwift](https://github.com/redsolution/XabberCryptoSwift) through SwiftPM over SSH, pinned to `bd5d19dbd8e9de2521c8830f54564d3cc175cba8`. The product is linked to the app and XCTest target. Xcode requires an SSH key with access to the repository. Its included libsodium XCFramework is part of the package; licenses and component notices are bundled as `XabberCryptoAcknowledgements.txt`.

SignalProtocolC and SignalProtocolObjC Pods, their preparation script/manifest/patches and the external ObjC crypto test source have been removed. Older reports mentioning those dependencies describe the historical backend.

The remaining local XMPPFramework Pod keeps its existing checkout in `XABBER_DEPS_ROOT` (default `../../../../../deps`). No new local cryptographic checkout or preparation is needed.

Use `pod install --no-repo-update` to update installed Pods. Xcode resolves the pinned package using the committed `xabber.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`; the cached wrapper preserves package/DerivedData caches. Introducing a new dependency requires one explicit resolution before returning to locked verification.

See [consumer migration and verification](xabbercryptoswift-app-migration-2026-10-14.md).
