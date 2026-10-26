# Chat screen physical-device QA — 2026-10-26

Status: blocked before chat scenarios. No product acceptance result is claimed.

| Device | Result |
| --- | --- |
| Alex’s iPhone, iPhone 12 Pro, iOS 26.6.1 | UI runner started; initialization timed out enabling automation. Current device screenshot shows “Enter iPhone Passcode for XCTest — Enable UI Automation.” |
| iPad (Redsolution), iPad Air 11-inch M3, iPadOS 26.7.1 | Both the standalone and existing project UI runners timed out enabling automation. Current screenshot shows “Touch ID для XCTest — Enable UI Automation.” |
| Network iPhone, iPhone 16 Pro, iOS 26.6.2 | CoreDevice disconnected during app inventory; Xcode subsequently timed out with “Device is busy (Connecting to iPhone).” |
| iPad (Ирина), iPhone 12 mini (Andrew) | Unavailable; not tested. |

The standalone XCTest UI runner built successfully without an application target or dependency. It activates the installed `xabber.ios` by bundle identifier. Its two valid inspection attempts failed during UI automation initialization, before a test body executed. A confirmation attempt using the existing project runner on iPad failed at the same initialization step. The failures are infrastructure errors, not failed chat assertions.

Both wired devices report Developer Mode enabled and `unlockedSinceBoot=true`; the separate XCTest authentication request still requires local confirmation. No passcode or biometric input was performed.

The main app was neither rebuilt nor installed. No messages were sent or deleted, no account settings were changed, and pre-existing source/project/test edits were preserved. Only the test runner was installed. Initial harness attempts using CoreDevice identifiers instead of hardware UDIDs, and an incomplete standalone xctestrun configuration, were corrected before the valid runs above. Standalone UI execution requires `UseUITargetAppProvidedByTests=true`.

## Resume

After local XCTest authentication on both devices, run inspection first and select the actual visible chat and controls. Prepared checks cover visible message content, scrolling in both directions, keyboard focus/dismissal without typing, attachment picker open/dismiss without selection, search open/cancel, background/foreground, rotation/restoration and Back/reopen. None of these checks has executed yet. Opening a real chat can produce ordinary read-marker and MAM effects.

Restore a stable Xcode connection before including the network iPhone.

Private screenshots, three initialization-failure result bundles, the network failure, summaries, standalone runner source/project and resume instructions are retained in:

`/Users/igor.boldin/projects/xabber/xabber/projects/xabber/debug/2026-10-26-chat-screen-device-qa/`

Task and UI handoff are recorded in the project vault. Xcode caches are preserved; no cache reset was performed.
