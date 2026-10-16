# iPad push HTTP MAM test preparation, 2026-10-16

Status: setup complete; awaiting a new user-sent test message. Server unchanged. App launched in Debug offline mode and left running in background; full raw runtime logs remain outside Git.

## Corrected relay ingress

Fifteen real NSE receipts earlier today reached the extension and failed before credentials with missing_or_invalid_payload. The relay copies encrypted/form XML siblings without the parent notification default namespace. The envelope now parses these fragments in the XEP-PUSH namespace context and serializes a copied encrypted child with an explicit local namespace. This fixes both bare relay summary/full and canonical inherited-namespace decryption. Explicitly empty/foreign namespaces, metadata shape, DTD/entity/size, AES/IV/ciphertext and decrypted-event checks remain enforced. Incoming raw logs and server payloads are unchanged.

Changed source: xabber/common/notify_manager/PushPayloadEnvelope.swift. Regressions: xabberTests/PushEventValidationTests.swift (five new cases).

## Verification

Regression-first RED:22 tests,4 assertion failures in3 valid new scenarios,0 unexpected. After the fix, cached isolated iOS26 simulator action passed72/72,0 failures/unexpected: event validation22,full payload38,ingress reconciliation11,pipeline integration1. This built both app and NSE. Independent source review found no blocker. Signed Debug physical app/NSE build and installation on iPad(Redsolution) passed. App debug dylib UUID2B52E6D3-B4DB-38B3-AC54-53AF51DBD143; NSE debug dylib UUIDBB44EC61-09E3-3333-8577-8CF046E0C3BE.

After installing the corrected build, normal bootstrap PID1355 obtained MAM-scoped JWT at14:42:17.295+05:00 and confirmed shared grant_stored readback=matched ready=true at14:42:17.300. Server expiry2026-10-16T10:42:17Z (15:42:17local). A background snapshot confirmed both streams disconnected before offline relaunch.

Final host PID1357 launched with only XABBER_PUSH_DIAGNOSTICS_OFFLINE=1 at14:42:55.311; primary/UI disconnected and a restore attempt blocked. At14:43:11.361 the background snapshot again confirmed primary connected=false/disconnected=true and UI connected=false/disconnected=true. The app remains running, not force-quit. Real Keychain/App Group retained; no fake XCTest/isolation flags or account disable ondevice.

## Live capture and remaining acceptance

Mac directory:/Users/igor.boldin/Library/Logs/XabberPushDiagnostics/2026-10-16/. push-extension-full-live.log mirrors all App Group process files every3seconds; device-files/ retains originals. ipad-push-system-live.log captures APNs/notification activation and app/NSE processes. host-installed-provisioning-console.log retains complete fresh IQ/JWT flow; host-offline-console.log captures the offline host. ready-state.json records the baseline without credentials.

The15 earlier receipts belong to the old rejected-parser baseline. No new push has yet verified the corrected NSE. Required next path: new receive/payload_raw → credentials_loaded/current grant → payload_decrypted summary → archive_fetch → exact discovered by-id GET/Bearer → HTTP200 XML → matching MAM result → render → complete. A full-mode push would verify rendering but would not prove HTTP MAM. Do not claim live delivery before this trace. Disposable build/test artifacts were removed after extracting these results; persistent Xcode caches and raw runtime logs were retained.
