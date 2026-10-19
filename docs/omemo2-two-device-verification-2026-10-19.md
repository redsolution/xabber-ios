# Two-device OMEMO verification — 2026-10-19

Status: current app installed on both devices; live message exchange blocked by
existing own-device trust decisions. Encryption/decryption acceptance is pending.

## Installed product

Clean source revision: `38ab79f9`. The cached `Debug` signed iOS build succeeded
using `tools/xcodebuild_cached.sh build -allowProvisioningUpdates` with destination
`generic/platform=iOS`. No clean or cache reset was performed. The app and push
extension built successfully, with no compiler or linker errors.

The explicit cached `Debug-iphoneos/xabber.app` was installed over the existing
application on both wired devices, preserving accounts and storage. Its bundle ID
is `xabber.ios`; version/build remains `1.0 (1)`, so the current binary is identified
by source revision and ARM64 debug-image UUID
`C2A8F511-87CA-35D3-8B1D-EAE70BCC1119`, rather than the unchanged version label.

| Device | Account domain | Native SID | Other active own devices without trust |
| --- | --- | --- | --- |
| Alex’s iPhone, iPhone 12 Pro | redsolution.com | 201978182 | 16 |
| iPad (Redsolution), iPad Air 11-inch M3 | xmppdev01.xabber.com | 267862439 | 4 |

Both ordinary account sessions authenticated. The previous process-only offline
push-diagnostics flag was not supplied.

## Positive live evidence

- iPhone bundle publication received correlated IQ result
  `A2B2D39B-559B-4662-96BF-4C338D37077F`.
- iPad bundle publication received correlated IQ result
  `8C35434F-5B0A-4B78-8C32-F552C04E3A3C`.
- Current own SIDs appear in server device lists. Both clients also received the
  opposite account’s list including the connected peer’s current SID.
- Each device’s authoritative protected local bundle public fingerprint matches
  the opposite client’s exact peer-device projection. Both peer projections are
  active and currently `unknown`; local device projections are trusted.

This supplies the previously missing physical publication/membership evidence
from [the October 14 verification](omemo2-physical-verification-2026-10-14.md).
It does not establish message encryption/decryption acceptance.

## Sending blocker

Evaluating the actual `OmemoSendAvailabilityPolicy` against each application’s
real Realm returns `blockedByOwnUntrustedDevices` in both directions. All 16 other
redsolution devices and all 4 other xmppdev01 devices have unknown trust. No trust
decisions, keys, device memberships or message history were changed. Normal
encrypted chat initialization/discovery was invoked for the authorized pair.

The policy requires every active own device to be trusted and at least one active
contact device to be trusted. Trusting old own devices also includes them in
outgoing encryption; it is not merely a UI acknowledgement. Two older redsolution
device bundle requests (SID `1095114224`, `413506100`) returned successful IQs with
no bundle, which could be a further sending blocker after trust is resolved.
Other captured bundles are not claimed cryptographically valid from XML shape.

The user was asked how to handle existing unverified devices. No test message was
sent and no send-policy bypass was attempted. Captured historical Sync/MAM
ciphertext is excluded from live-test evidence.

## Diagnostic limitations and cleanup

A temporary guarded physical XCUITest inspection probe failed before running a
test: `Timed out while enabling automation mode`. It provides no UI assertion or
passed test. Its original source was restored byte-for-byte, SHA256
`b8c996101f35c2129dc5835a2a48311a867a312e5099b8ce687c5568818baa12`.

A subsequent temporary LLDB UIKit screenshot expression was interrupted by
`EXC_BAD_ACCESS`; LLDB reported restoring the state before evaluation. This was an
injected diagnostic expression, not an observed ordinary app crash. Debuggers were
detached, console captures ended and both apps were normally relaunched (final
iPhone PID 2875, iPad PID 1879). No further runtime injection remains active.

Raw console captures and the failed UI result bundle are retained outside Git in
`~/Library/Logs/XabberOMEMODiagnostics/2026-10-19/`. The successful disposable build
log is removed; cached DerivedData, SourcePackages and PackageCache are retained.

## Remaining acceptance

Resolve existing own-device trust through the user’s decision, verify the current
peer keys through the normal trust flow, then send marked messages in both
directions. Require current wire `urn:xmpp:omemo:2` ciphertext without test plaintext
and authenticated plaintext in the recipient’s OMEMO conversation. Unicode and
receiver-restart cases remain untested as well.
