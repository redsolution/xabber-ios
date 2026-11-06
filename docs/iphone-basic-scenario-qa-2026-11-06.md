# Physical iPhone basic chat scenario — 2026-11-06

The requested scenario completed on the wired **Alex’s iPhone (iPhone 12 Pro)** in the ordinary **Alexey Boldin** conversation: launch, synchronize, open the chat, synchronize its history, send one test message, and return to recent chats. Sending and navigation passed. The requested instantaneous synchronization was not observed.

## Observed results

| Boundary | Result |
| --- | --- |
| Connection attempt → authenticated | 1.388 s in the final run |
| Connection attempt → final sixth synchronization response | 7.074 s in the final run; 6.307 s in an earlier run |
| Connection attempt → own available presence / background release | Background release at 7.127 s in the final run; 6.377 s in the earlier run |
| Native chat-open event → verified live-edge archive commit | 2.169 s; successful commit with 80 message records |
| Native chat-open event → content presentation event | 2.295 s |
| Outgoing message → server reliable receipt | 0.237 s after the matching native `didSend` event |
| Outgoing message → peer received marker | 1.180 s after the matching native `didSend` event |
| Return to recent chats | Passed; the exact new message appears as the Alexey Boldin preview |

Exactly one harmless QA message was sent at 15:23 local time. The composer cleared. A matching peer `received` marker and the green single delivery tick confirm delivery; no matching read/displayed marker was established. No send retry was performed.

## Verification

- Standalone `BasicAlexeyQA` physical-device `build-for-testing`: **passed** with existing signing and a dedicated retained Xcode cache.
- `BasicAlexeyQAUITests/testProbeCurrentUI`: **1/1 passed** after the owner confirmed the device's XCTest passcode prompt.
- `BasicAlexeyQAUITests/testBasicAlexeyScenario`: **1/1 passed**, 48.684 s including XCTest, accessibility queries, screenshots, and deliberate observation waits.
- Screenshots and accessibility evidence confirm the ordinary target chat, the outgoing message, a cleared composer, its delivery status, and the final recent-chats preview.
- Numeric app diagnostics and matched protocol receipts provide the timings above. Test-command duration is not app latency.

The runner operated the already installed `xabber.ios` version 1.0 (build 1). This QA did not rebuild or reinstall the product app and does not establish the installed binary's exact source revision. Existing unrelated staged and unstaged production changes were preserved. No product source change was required to execute this investigation.

## Timing limits and follow-up

Connection timings start at the native connection attempt, not process creation. The installed binary did not emit a dedicated `snapshotComplete` event: final matched synchronization response and the later startup background-release gate are separate measured boundaries. Response intervals include transport and client dispatch; they do not isolate server processing time. Chat content timing uses correlated numeric events from the same process and presentation context. No stable-frame or repeated-run distribution is claimed.

The open performance findings are startup synchronization across six sequential pages and the approximately 2.3 s delay before chat content. This task records those findings without attributing a cause or changing startup ordering.

Private evidence and the standalone runner are retained in the project vault under `projects/xabber/debug/2026-11-06-iphone-basic-alexey/`. See the task `projects/xabber/tasks/done/xab-iphone-basic-alexey-2026-11-06.md`. Raw personal message data and wire XML are excluded from this report and commit.
