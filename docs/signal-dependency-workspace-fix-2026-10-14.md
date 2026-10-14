# Signal-family dependency cleanup and Xcode workspace

The reported SignalProtocolC/SignalProtocolObjC missing-xcconfig errors came from the workspace open in Xcode under `/Users/igor.boldin/projects.migration-backup-20261012/`, on `codex/ios-local-dependencies`. Its old Pods project referred to configurations under the current `/Users/igor.boldin/projects/` path. Those configuration paths alone did not identify the open checkout.

The active repository is `/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core` (`projects` resolves to `/Volumes/Whisper/Development/projects`), branch `codex/omemo-xabbercryptoswift`. Its workspace was opened in Xcode and verified by the native window URL/branch. XabberCryptoSwift revision `bd5d19d` is visible in package dependencies and linked to the application. The current Pods target list contains no SignalProtocolC, SignalProtocolObjC or Curve25519Kit. The backup checkout was not modified.

An additional audit found the unused WhisperSystems-derived Curve25519Kit dependency in the active app/tests/extension Pods graph. Its only app reference was an unused CredentialsManager import. Both Pod declarations and the import are removed; CocoaPods regenerated using `pod install --no-repo-update`. Comparing the before/after lock structures verified that only Curve25519Kit entries and the Podfile checksum changed. The existing repository ignores Podfile.lock/Pods; the local lock and manifest were regenerated and match. SwiftPM pins and other dependency versions remain unchanged.

Dead whitespace rules for retired Signal preparation patches and the incorrect documentation claim that Curve25519Kit served AKE/push were removed. CryptoSwift retains its separate existing AKE/push uses; OMEMO uses XabberCryptoSwift.

## Verification

- Added [OMEMO2DependencyIsolationTests.swift](../xabberTests/OMEMO2DependencyIsolationTests.swift) before removal. Both methods initially failed: Curve25519Kit was present in the installed app bundle and in actual loaded Mach-O images.
- After removal, **751/751 hosted XCTest passed across54classes**, zero failures/unexpected/skips, including both new dependency tests and the previous749-case OMEMO gate. The cached Debug test action built app+notification extension on iOS26.0 Simulator `91E09D3E-4BBC-4431-9EAF-14D2410E7B98`, both hosted storage/autoconnect isolation flags, ad-hoc signing, no clean.
- New tests inspect real app/NSE framework inventories and the running host's dyld images, require embedded/executable/loaded XabberCryptoSwift, and reject all three retired framework families. `otool -L` separately verified no retired links in the app executable, app debug dylib or extension executable; the app debug dylib links the native SwiftPM product.
- Current Podfile/local lock/manifest/generated Pods project/configurations and app project contain no dependency references to any of the three retired libraries. Compiler/linker errors and test skips were checked; none. Project lint and Git whitespace checks passed.
- Removed only the obsolete Curve25519Kit framework copies from the cached app and test bundle before rebuilding. CocoaPods embed scripts copy current dependencies but can leave old embedded output behind during incremental migration. DerivedData, SourcePackages and PackageCache directories remain intact. Disposable logs/result bundles were removed after recording evidence.

No cryptographic API, state/schema, signing or secret resource changed. This verifies simulator build, native crypto behavior and packaged/loaded dependency isolation; it adds no physical-device or live XMPP/APNs evidence.
