# Chat screen physical-device QA — 2026-10-26

Testing the installed `xabber.ios` found one high-priority conversation-routing defect on iPad. The main application was not changed, rebuilt or reinstalled. Existing unrelated working-tree edits were preserved.

## Confirmed defect: encrypted Info Search opens the regular chat

On iPad Air 11-inch M3 / iPadOS 26.7.1, open an existing encrypted chat, tap its avatar, then Search in Contact Info. Before a query is entered, the right pane switches to the regular conversation for the same contact. Cancel keeps the regular history and composer, while the encrypted row can remain selected on the left.

Two physical reproductions confirmed this. The focused second test first verified a QA3 marker inside an actual visible encrypted message cell, then failed after Search/Cancel because that marker was replaced by the regular dataset. In the first reproduction the 10 original message/date identities and the 3 regular identities had no overlap. The ordinary-chat iPhone control preserved all 5 identities. Display names hydrated during Contact Info and became identical, so title-only assertions would miss the problem.

The current checkout explains the observed behavior: `ContactInfoViewController.swift:892` calls `searchChat()` without the controller’s `conversationType`; `ContactInfoViewController+InfoScreenHeaderButtonDelegate.swift:191` defaults the argument to `.regular`. The avatar route correctly sets the property, but the Search button ignores it. Existing explicit `.omemo` route-helper tests do not invoke the faulty actual button handler.

This is a high-priority UI conversation-boundary issue. No message was sent, so no plaintext transmission, on-wire encryption downgrade, message loss or cryptographic failure is claimed. A focused UI-owner follow-up, actual-button XCTest recommendation and physical reproduction are recorded in the vault; no production fix was made in this testing task.

## Executed matrix

| Check | iPhone 12 Pro / iOS 26.6.1 | iPad Air 11-inch M3 / iPadOS 26.7.1 |
| --- | --- | --- |
| Installed app activation and initial inspection | PASS | PASS; initial chat-list skeleton resolved before selection |
| Actual message cells, no archive-recovery banner | PASS | PASS in the selected encrypted chat |
| One slow scroll in each direction | PASS | PASS |
| Composer focus, keyboard display, interactive dismissal, unchanged draft | PASS | PASS |
| Home → foreground, messages retained | PASS | PASS |
| Rotate to opposite axis and restore | PASS; 5/5 canonical identities and exact frames restored | PASS; 10/10 identities and exact frames restored |
| Avatar → Info Search → Cancel without query | PASS in ordinary chat | FAIL: encrypted → regular route |
| Known-text search, committed result, list and result tap | PASS; query `WKWebView`, 1 result, disabled boundary arrows, list → actual message jump → Cancel | Not interpreted as an indexing test because the entry route selects the wrong namespace |
| Attachment picker entry | PASS; Photos access request appeared | PASS; Photos access request appeared |
| Attachment dismissal and final restoration | PASS after explicit denial of Photos access; original chat restored | PASS after explicit denial of Photos access; encrypted chat restored |
| Back/Close and reopen | PASS | PASS |

The network iPhone 16 Pro / iOS 26.6.2 remained unavailable to Xcode automation: the first inventory disconnected with CoreDevice4000 and both execution attempts timed out in Connecting/Preparing. iPad (Ирина) and iPhone 12 mini (Andrew) were offline and were not tested.

## Verification and limits

A standalone XCTest UI runner built successfully with cached `build-for-testing`, no `clean`, no app target or dependency, and `UseUITargetAppProvidedByTests=true`. All physical execution used `test-without-building` with actual hardware UDIDs and only the selected test. The resumed execution catalogue contains 23 invocations: 18 completed green, one failed on the confirmed conversation defect, three failed on harness/system-prompt preconditions, and one network destination did not execute. These are invocations of reused test methods, not 23 distinct scenarios; the matrix above defines acceptance scope. Only the runner was installed; app version/source identity was not rebound to the current checkout.

Initial XCTest authentication timeouts were resolved after the user enabled automation and confirmed the device prompts. The first iPhone combined scenario failed only before rotation because XCTest reported unknown physical orientation; an updated runner used the observed interface axis and the actual opposite-axis rotation passed. The earlier scenario’s content, scroll, keyboard and lifecycle assertions had already passed.

The first semantic attachment-dismiss attempt was blocked by the asynchronous system Photos prompt, not an app dismissal defect. The observed English/Russian requests were explicitly declined; no Photos access was granted. Normal picker dismissal then passed on both devices, with the iPad returned to its original encrypted conversation. A coordinate fallback correctly refused to tap through a system alert. These raw harness/precondition failures are retained separately from the confirmed conversation-routing failure.

Some iPad `app.screenshot()` PNGs contain orientation metadata that renders black/cropped in the viewer. A separate native Xcode Devices screenshot shows the complete, correct landscape layout. The capture artifact is not reported as an app layout defect.

No messages, media or voice recordings were sent, no messages were edited/deleted, and no accounts were changed. Full archive boundaries, fresh server paging, background delivery, accessibility/Dynamic Type, network-loss recovery and performance were outside this screen smoke check. Opening chats/search can produce ordinary read-marker, MAM and vCard hydration effects.

## Retained evidence

Private stage screenshots, full accessibility trees, outcome summaries, diagnostic failures, standalone runner source/project/configurations and the detailed bug reproduction are stored in:

`/Users/igor.boldin/projects/xabber/xabber/projects/xabber/debug/2026-10-26-chat-screen-device-qa/`

The main QA task, UI follow-up and handoff are linked there. Disposable duplicate diagnostics are removed after retaining the evidence; Xcode caches are preserved.
