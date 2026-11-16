# OMEMO cryptographic dependency

Since 2026-10-14, Xabber iOS uses [XabberCryptoSwift](https://github.com/redsolution/XabberCryptoSwift) through SwiftPM over SSH, pinned to `bd5d19dbd8e9de2521c8830f54564d3cc175cba8`. The product is linked to the app and XCTest target. Xcode requires an SSH key with access to the repository. Its included libsodium XCFramework is part of the package; licenses and component notices are bundled as `XabberCryptoAcknowledgements.txt`.

SignalProtocolC and SignalProtocolObjC Pods, their preparation script/manifest/patches and the external ObjC crypto test source have been removed. The unused WhisperSystems-derived Curve25519Kit Pod and import are also removed from the app, tests and notification extension. Older reports mentioning those dependencies describe the historical backend.

CocoaPods downloads XMPPFramework from the Redsolution GitHub fork at the commit pinned in the `Podfile`. See [the Stream Management dependency and verification](stream-management-cold-resume.md).

Use `pod install --no-repo-update` to update installed Pods. Xcode resolves the pinned package using the committed `xabber.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`; the cached wrapper preserves package/DerivedData caches. Introducing a new dependency requires one explicit resolution before returning to locked verification.

See [consumer migration and verification](xabbercryptoswift-app-migration-2026-10-14.md).

## GitHub Actions simulator build

The workflow runs on GitHub-hosted `macos-26`. The simulator job generates configuration from the tracked `.example` files and installs Pods from the committed `Podfile.lock` with CocoaPods 1.16.2 in deployment mode. It copies the committed `Package.resolved` into the generated workspace before resolving Swift packages. Fork pull requests run the localization tooling checks.

The simulator job requires the `XABBER_CI_CRYPTO_SSH_KEY` Actions secret. Its value is the private half of a read-only deploy key registered on `redsolution/XabberCryptoSwift`. The job uses that key during SwiftPM resolution and removes it before compilation and tests.

The `xabber-simulator-app` artifact contains `xabber.app.zip`. Extract that inner archive to retain the executable permissions on the simulator bundle.
