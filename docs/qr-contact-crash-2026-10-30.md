# QR contact-add crash — 2026-10-30

Status: confirmed user-reported crash, recorded for a future fix. No production change or automated contact/subscription request is included.

## Evidence

After the wired first-ten chat QA, the user reported a crash while adding a contact through a QR code. A single matching `xabber` crash report was retrieved read-only from the same cable-connected iPhone 12 Pro / iOS26.6.1 system crash-log domain. The report records16:42:18.977+05:00, main process7210, `EXC_BREAKPOINT` / `SIGTRAP` on thread0. That process is the app left running at the end of QA. The actual crash image UUID matches the cached `xabber.debug.dylib` from source `847b4f93`; symbolication uses the matching binary and the load address from the report.

The stack resolves to:

1. Swift `_assertionFailure`.
2. `showStackedImplementation(...)`, `UIViewController+Modal.swift:853`.
3. `showStacked(...)`, same file:817.
4. The dismissal completion in `AddNewContactViewController.closeAndDisplayContact(jid:owner:)`, `AddNewContactViewController.swift:212`.

No debugger was attached during this user incident. This is an ordinary app crash, separate from earlier diagnostic/helper failures.

## Immediate failure and route

The crash line reads target bounds through `navigationController?.view.bounds ?? presenter.view.bounds` in the current-navigation route. This includes an implicit unwrap of UIKit's view. The caller dismisses the Add Contact controller and only inside the dismissal completion obtains `self.presentationController.presentingViewController` for `showStacked`. That presentation relationship is no longer a reliable owner after dismissal. A missing or detached presenter is a strongly supported lifetime mechanism; a focused regression must establish the exact transition and guard it.

Within the inspected production path, `closeAndDisplayContact` is called after the roster setter reports success and local chat initialization runs. Thus the recorded crash is in navigation after the Add flow, rather than evidence that QR decoding or the camera failed. The matching built app contains a camera usage description. This report does not verify final server roster state and does not repeat the real contact-add operation.

## Future TDD and verification

Add a focused regression for the contact-add completion reached through QR: preserve the intended account and navigation delegate, close the modal once, retain or resolve a live presentation owner before/after dismissal safely, and open the intended conversation once. Cover an unavailable presentation owner without a trap. Inspect the scanner's repeated metadata callbacks and delegate forwarding as related risks; neither is established as the trigger by this stack alone.

Make the smallest UIKit navigation fix after the regression fails on current code, run the narrow tests and required cached app build, then validate the route on the wired device with controlled data. The current QA only records and diagnoses the defect.

Private evidence: `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/debug/2026-10-30-qr-contact-crash/` (`xabber-2026-10-30-164220.ips`, parsed body, exact UUID/base-address symbolication, scanner source audit). Actual contact/account identifiers and raw crash data are excluded from source Git. A separate P1 task and UI/Tests handoff in the vault track the future fix.
