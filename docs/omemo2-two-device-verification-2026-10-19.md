# Two-device OMEMO verification — 2026-10-19

Status: current app installed on both devices; both normal encrypted-send tests
failed locally with `bundleNotFound`. All active devices of the authorized accounts
are trusted as explicitly requested. Successful live encryption/decryption
acceptance remains unfulfilled.

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

| Device | Account domain | Native SID | Other active own devices |
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

## Trust authorization and actual send result

The initial `blockedByOwnUntrustedDevices` result was resolved after the user
explicitly instructed: “Считай все устройства обоих аккаунтов доверенными”. Normal
`writeTrustedDevice` semantics were applied only to active rows of the two
specified accounts on each physical device, followed by ordinary own/contact
trust-sharing updates. Final read-back on each device: **22 active rows, 22 trusted**,
normal send availability `canSend`. Keys and server membership were preserved.

Two marked messages were submitted through the ordinary
`MessageManager.sendSimpleMessage(..., conversationType: .omemo)` path:

| Direction | Message ID | Local result | Recipient result |
| --- | --- | --- | --- |
| iPhone → iPad | `UgF7jiUo` | `.error` / `messageErrorCode=omemo` | No matching incoming row |
| iPad → iPhone | `UTtW3H8K` | `.error` / `messageErrorCode=omemo` | No matching incoming row |

Neither ID occurs in either raw wire capture, and neither current sender SID
appears in a live encrypted-message header. The original ID returned by the send
API proves local admission, not delivery. One normal retry of each existing row
hit the `createSession` missing-identity guard (`OmemoManager+Encryption.swift:328`,
`bundleNotFound`) and returned `false`; no additional test rows were created.
Breakpoint parameters were unavailable, so no exact failing SID is claimed from
that frame. All breakpoints were removed and both expressions completed normally.

A read-only full public-bundle validation over the 22 active device projections on
each app finds 5 usable bundles and **17 missing local identity/bundle records**.
Both current physical-device bundles validate with 100 prekeys each. Other usable
SIDs: redsolution `1787628586`, xmppdev01 `1316274069` and `234993657`.

Fresh representative server replies explain why old devices remain unusable:

| Account / SID | Public key lengths: ik / spk / signature | Prekeys |
| --- | --- | --- |
| xmppdev01 `15103` | 33 / 33 / 64 bytes | 100 × 33 bytes |
| xmppdev01 `4623362` | 33 / 33 / 64 bytes | 99 × 33 bytes |
| redsolution `6032` | 33 / 33 / 64 bytes | 100 × 33 bytes |
| redsolution `1095114224`, `413506100` | IQ result contains no bundle | — |
| Current iPad `267862439` | 32 / 32 / 64 bytes | 100 × 32 bytes |
| Current iPhone `201978182` | 32 / 32 / 64 bytes | 100 × 32 bytes |

The current codec requires 32-byte identity, signed-prekey and prekey values. The
representative old 33-byte bundles fail decoding before signature verification;
this is not evidence of an invalid signature. Marking devices trusted does not
convert their keys or supply absent bundles.

Encryption includes all active trusted contact devices and other own devices.
A missing usable bundle aborts the entire send. `failEncryptedSend` preserves the
failed message row and returns before network send; no plaintext fallback was
used. No trust-policy bypass, old-device deletion or server change was performed.

## Diagnostic limitations and cleanup

A temporary guarded physical XCUITest inspection probe failed before running a
test: `Timed out while enabling automation mode`. It provides no UI assertion or
passed test. Its original source was restored byte-for-byte, SHA256
`b8c996101f35c2129dc5835a2a48311a867a312e5099b8ce687c5568818baa12`.

A subsequent temporary LLDB UIKit screenshot expression was interrupted by
`EXC_BAD_ACCESS`; LLDB reported restoring the state before evaluation. This was an
injected diagnostic expression, not an observed ordinary app crash. Debuggers were
detached, console captures ended and both apps were normally relaunched (final
iPhone PID 2926, iPad PID 1886). No further runtime injection remains active.

Raw console captures and the failed UI result bundle are retained outside Git in
`~/Library/Logs/XabberOMEMODiagnostics/2026-10-19/`. The successful disposable build
log is removed; cached DerivedData, SourcePackages and PackageCache are retained.

## Remaining acceptance

Successful exchange requires resolving the active legacy/missing bundles, either
by updating the affected clients and publications or by an explicit decision to
revoke obsolete devices. The trust instruction does not authorize deleting devices
or inventing identity material. After that resolution, repeat normal sends and
require current wire `urn:xmpp:omemo:2` ciphertext plus authenticated plaintext on
the recipient. Unicode and receiver-restart acceptance remain unverified.

No application code changed during this verification. The already successful
signed app/NSE build remains the tested product; a documentation-only update does
not require another build. Full raw round-two captures are retained alongside the
initial diagnostics outside Git.
