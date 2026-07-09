# ChatView Search Navigation Repair Goal Plan

created:: 2026-07-09
owner:: xabber-ui
secondary:: xabber-xmpp, xabber-tests
repo:: `/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core`
server-source:: `/Users/igor.boldin/projects/xabber/server`
status:: ready-for-goal-mode

## Goal Mode Prompt

Copy-paste this prompt into automatic goal mode:

```text
Implement the plan from docs/goal-plans/chat-view-search-navigation-repair-goal-plan.md in order.

Primary objective:
Fix in-chat search navigation in ChatViewController on iPhone 16e:
- the bottom search status bar must move above the keyboard;
- after server search results arrive, the chat must immediately start opening the active result;
- up/down result navigation must reliably open and position the selected result;
- the full-message selection must stay tied to the active lower-panel result;
- server MAM/search behavior in /Users/igor.boldin/projects/xabber/server is the source of truth.

Hard rules:
- Run the listed pre-task tests before every task and record the result.
- Add or update focused XCTest coverage before changing production behavior.
- Commit after every completed task with only that task's files staged.
- Use the running iPhone 16e simulator for XCTest and manual QA.
- Prefer tools/xcodebuild_cached.sh for local Xcode verification.
- Do not reset caches unless explicitly needed for diagnosis.
- Do not revert unrelated local changes.
- Preserve accessibility identifiers: chat_search_input, chat_search_submit, chat_search_cancel, chat_search_results_panel, chat_search_results_count, chat_search_previous_result, chat_search_next_result, chat_search_loading.
- Keep server stanza shape unchanged unless server analysis proves a client/server mismatch. If server changes are considered, stop and document the mismatch first.

Manual QA target:
Use the Alexey Boldin dialog on the running iPhone 16e. Search for `Тест`.
```

## Evidence To Preserve

- Video: `/Users/igor.boldin/Downloads/ScreenRecording_07-09-2026 11-28-31_1.mov`.
- Log: `/Users/igor.boldin/.codex/attachments/0647b3b9-f581-4dd7-8b87-b6a407ef7d80/pasted-text.txt`.
- Server source of truth:
  - `/Users/igor.boldin/projects/xabber/server/src/mod_mam.erl`
  - `/Users/igor.boldin/projects/xabber/server/src/mod_mam_sql.erl`
  - `/Users/igor.boldin/projects/xabber/server/test/mam_tests.erl`

## Current Findings

### Video Findings

- The keyboard is visible while the bottom search status row remains at the bottom of the screen instead of being pushed above the keyboard.
- The query `Тест` returns UI state `1 of 18`, then a blocking spinner appears over the chat.
- The visible chat stays on the same message area and does not immediately jump to the first active result after search results are received.
- Navigation does not visibly move between results; the lower panel remains stuck in loading/positioning behavior.

### Log Findings

- Search request is sent correctly:

```xml
<query xmlns="urn:xmpp:mam:2" queryid="MAM search: SeCsC_JJ">
  <x xmlns="jabber:x:data" type="submit">
    <field var="FORM_TYPE" type="hidden"><value>urn:xmpp:mam:2</value></field>
    <field var="with"><value>aleksey.boldin@redsolution.com</value></field>
    <field var="withtext"><value>Тест</value></field>
  </x>
  <set xmlns="http://jabber.org/protocol/rsm"><max>250</max><before/></set>
</query>
```

- Server returns 18 results, with RSM `first=1756120975490655`, `last=1783493923727774`.
- Client starts a context request for the chosen search anchor:
  - `MAM jump context newer: xr19rO`
  - `after=1783493923727774`
  - `max=98`
  - `flipPage=true`
- Context messages are received and persisted. The log then says:
  - `ChatViewController: resolved anchor via primary. source=search ... archivedId=1783493923727774`
  - `chatDidReceiveEndPageHandled ... handler=anchorContextPrefetch`
- After that, observer refresh applies the normal current/latest path:
  - `observerRefreshDecision ... action=openLatest ...`
  - `chatDatasourceApplyStart ... anchorRestorePhase=none anchorPrimary=-`
  - `chatDatasourceApplyFinish ... autoScrollToBottom=true ... anchorRestoredInTransaction=false`
- This means search anchor resolution happened, but the datasource apply/positioning path did not become an anchored search positioning transaction. It was overwritten or bypassed by the ordinary observer refresh path.
- Later navigation repeats context requests for the same nearby anchors, but the logs still show resolved anchor lines without a reliable final scroll/selection completion.

### Client Implementation Findings

- `ChatViewController` installs `xabberInputView.bottomAnchor.constraint(equalTo: view.bottomAnchor)`. `ModernXabberInputView.update(screenHeight:keyboardHeight:)` then grows the input container height by `keyboardHeight`. This mixed frame/constraint strategy is fragile in search mode and differs from `SearchChatListViewController`, which pins its bottom search bar to `view.keyboardLayoutGuide.topAnchor`.
- `ModernXabberInputView.updateBottomPanels(withOffset:)` lays out `searchPanel` inside the input view. If the input view does not correctly expose the search row above the keyboard, the bottom search panel is hidden or visually detached.
- `applySearchResults(emptyList:)` sorts `searchMessagesQueue` newest-first, sets `selectedSearchResultId` immediately, updates the panel directly, and manually queues a `ChatOpenMessageRequest(source: .search)`.
- That initial `applySearchResults` path does not use the same `openSearchResult(at:direction:)` state machine as result navigation and does not pass `onPositioningStarted`.
- `applySearchFirstFrameWindowIfNeeded(isSynced:)` positions a search first-frame anchor but currently does not call `hooks?.onPositioningStarted?()` before `positionMessage(...)`. This can leave search navigation state/panel completion out of sync in the bootstrap/first-frame path.
- The normal observer refresh path in `ChatViewController+Dataset.swift` can choose `openLatest` while a search anchor context has just completed. The log shows this exact problem: search anchor was resolved, then datasource apply ran with `anchorRestorePhase=none`.

### Server Source-Of-Truth Findings

- `mod_mam_sql:extended_fields/0` includes `withtext`.
- `mod_mam:parse_query/2` decodes MAM xdata fields into the query form.
- `mod_mam_sql:make_sql_query/4` implements `withtext` as PostgreSQL full-text search:
  - `to_tsvector(txt) @@ plainto_tsquery(<query>)`
- RSM semantics in server SQL:
  - `after` means `timestamp > ID`;
  - `before` means `timestamp < ID`;
  - default and `after` pages are ordered `timestamp ASC`;
  - `before` pages select newest rows by `timestamp DESC` internally, then return them as `timestamp ASC`.
- Therefore server result stanzas are chronological from older to newer. iOS may present `1 of N` as newest-first, but it must explicitly normalize the server order and bind every UI index to a concrete archived id.

## Implementation Tasks

### Task 1 - Lock Server MAM Search Contract And Client Result Ordering

Purpose: make the server/iOS search contract explicit before touching UI state. This prevents fixing navigation against an incorrect assumption about result order.

Pre-task tests:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/ChatInChatSearchQueryLifecycleTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests
```

Implementation:

- Add or update focused XCTest coverage around MAM search result normalization.
- Use fixture archived ids from the attached log:
  - oldest side: `1756120975490655`
  - newest side: `1783493923727774`
- Assert that server chronological input is normalized to the UI queue order expected by the bottom panel.
- Assert that UI index `0` maps to the newest result when the product shows `1 of N` as the first active result.
- Assert that each search result's selection identity prefers `archivedId`, then falls back to `primary`.
- Add a short code comment or test fixture note that server MAM search returns chronological results, while the chat search UI presents newest-first.
- Do not change server code in this task.

Acceptance criteria:

- Tests prove that server chronological MAM results become deterministic iOS search result ordering.
- Search result queue order, bottom panel index, and archived id identity are all tested together.
- No UI behavior changes are mixed into this task.

Required tests after implementation:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/ChatInChatSearchQueryLifecycleTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests

git diff --check
```

Commit:

```bash
git add xabberTests xabber/controllers/chats/chat
git commit -m "Lock chat search MAM result ordering"
```

### Task 2 - Make The Bottom Search Bar Keyboard-Owned, Not Screen-Bottom-Owned

Purpose: the lower search status bar must move with the keyboard exactly like a composer row.

Pre-task tests:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/SearchChatListKeyboardLayoutTests \
  -only-testing:xabberTests/ChatComposerFrameUpdateTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests
```

Implementation:

- Add `ChatSearchKeyboardAvoidanceTests` or extend the closest existing chat keyboard layout tests.
- Cover the real `ChatViewController` search-mode layout, not only `SearchChatListViewController`.
- Decide on one keyboard strategy for chat search:
  - preferred: when `xabberInputView.state == .search`, pin the visible search row/container to `view.keyboardLayoutGuide.topAnchor`, using `SearchChatListViewController.installBottomBarKeyboardConstraintsIfNeeded()` as the reference pattern;
  - acceptable alternative: keep the existing bottom anchor only if tests prove the search panel frame is above the keyboard for all keyboard frames, with no double height or hidden row.
- Avoid mixing a `keyboardLayoutGuide` bottom constraint with a height that still includes `keyboardHeight` unless the tests prove it is intentional and stable.
- Keep normal composer behavior unchanged for `.normal`, `.record`, `.edit`, `.forward`, and mention states.
- Ensure `updateChatCollectionInsets` uses the visible search row height and keyboard-safe bottom inset, so the active result is not hidden behind the bottom panel/keyboard.

Acceptance criteria:

- With the keyboard open on iPhone 16e, `chat_search_results_panel` is fully visible above the keyboard.
- The lower search row has the same width boundaries as the normal composer row.
- The collection bottom inset leaves enough space for the search row above the keyboard.
- Normal composer keyboard movement still passes existing tests.

Required tests after implementation:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/ChatSearchKeyboardAvoidanceTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatComposerFrameUpdateTests \
  -only-testing:xabberTests/SearchChatListKeyboardLayoutTests

git diff --check
```

Manual check:

- Open Alexey Boldin chat on iPhone 16e.
- Enter search mode.
- Focus the top search input so the keyboard opens.
- Verify the bottom search bar is above the keyboard and not clipped.

Commit:

```bash
git add xabberTests xabber/controllers/chats/chat
git commit -m "Move chat search panel with keyboard"
```

### Task 3 - Route Initial Search Results Through The Same Search Navigation State Machine

Purpose: after MAM search results arrive, chat must immediately start opening the active result through the same code path as up/down navigation.

Pre-task tests:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/ChatInChatSearchQueryLifecycleTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests
```

Implementation:

- Add a focused regression test for `applySearchResults(emptyList:)`:
  - given 18 current-query results;
  - when search final is handled;
  - then index `0` is opened immediately through `openSearchResult(at: 0, direction: ...)` or an equivalent single state-machine entry point;
  - and the resulting `ChatOpenMessageRequest` uses `.search`, `markReadOnVisible == false`, and the selected result archived id.
- Refactor `applySearchResults(emptyList:)` so it does not duplicate search open logic.
- Use one internal method for both initial result open and lower-panel up/down navigation.
- Do not directly finish/clear context loading in `applySearchResults`; the anchor positioning path must own completion.
- For the initial search result:
  - set the lower panel to `1 of N` plus context-loading spinner while the anchor is being opened;
  - if the result is already visible/loaded, positioning may complete immediately;
  - if context/archive is required, keep the loading indication until actual positioning completes.
- Ensure empty search still shows `no results` and clears active selection.

Acceptance criteria:

- After server final for search `Тест`, the client immediately schedules/open-starts the newest active result.
- Initial search result opening and next/previous navigation share the same state transitions.
- The panel does not get stuck because initial result opening bypassed `onPositioningStarted` or `onPositioned`.

Required tests after implementation:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/ChatInChatSearchQueryLifecycleTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests

git diff --check
```

Commit:

```bash
git add xabberTests xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift
git commit -m "Open initial chat search result through navigation state"
```

### Task 4 - Complete Search Anchor Context Prefetch Into Anchored Datasource Apply

Purpose: context MAM final must lead to anchored search positioning, not normal observer `openLatest`.

Pre-task tests:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests \
  -only-testing:xabberTests/ChatAnchorExecutionPolicyTests \
  -only-testing:xabberTests/ChatRemoteHistoryApplyPolicyTests
```

Implementation:

- Add focused tests around search anchor/context completion:
  - context final flushes query-scoped messages;
  - the resolved search anchor calls `mapAndApplyTimelineAnchor` or equivalent anchored apply;
  - observer refresh does not choose `openLatest` while a search anchor is pending/active;
  - duplicate final IQ does not clear or restart active search positioning.
- Add a regression for `applySearchFirstFrameWindowIfNeeded(isSynced:)`:
  - when it positions a search request, `hooks?.onPositioningStarted?()` fires before `positionMessage(...)`.
- In `ChatViewController+Dataset.swift`, guard the observer refresh decision while search anchor work is active:
  - pending `.search` open request;
  - active search anchor execution;
  - search context prefetch query ids waiting for final;
  - search navigation state busy.
- During that guard, prefer resuming `performPendingOpenMessageRequestIfNeeded(trigger: .observerRefresh)` or keeping current no-scroll state over `mapAndApplyTimelineLatest`.
- Ensure `anchorRestorePhase`/anchor metadata are visible in debug trace when search anchored apply runs, so future logs prove whether positioning happened.
- Keep existing non-search latest stabilization behavior unchanged.

Acceptance criteria:

- The log for a search context final no longer shows `observerRefreshDecision action=openLatest` followed by `anchorRestorePhase=none` as the only datasource apply.
- Search context final leads to actual `positionMessage` for the target archived id.
- `onPositioningStarted` fires in loaded, resume-after-context, and search-first-frame paths.
- Duplicate final IQs are idempotent.

Required tests after implementation:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests \
  -only-testing:xabberTests/ChatAnchorExecutionPolicyTests \
  -only-testing:xabberTests/ChatRemoteHistoryApplyPolicyTests \
  -only-testing:xabberTests/ChatFirstFrameLocalHistoryRegressionTests

git diff --check
```

Manual log check:

- Search `Тест` in Alexey Boldin.
- Confirm logs show search anchor positioning after `MAM jump context ...` final.
- Confirm no normal latest apply overwrites the search anchor before positioning.

Commit:

```bash
git add xabberTests xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift
git commit -m "Finish search context loads into anchor positioning"
```

### Task 5 - Repair Up/Down Search Navigation State And Direction

Purpose: lower-panel up/down buttons must reliably move to the requested result and scroll in the requested visual direction, including wraparound.

Pre-task tests:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests
```

Implementation:

- Add or update tests for:
  - pressing up from `1 of 18` opens `2 of 18` as an older visual result and scrolls up;
  - pressing down from `2 of 18` opens `1 of 18` and scrolls down;
  - pressing up from `18 of 18` wraps to `1 of 18` and scrolls down;
  - pressing down from `1 of 18` wraps to `18 of 18` and scrolls up;
  - during active context loading, repeated taps either stay disabled by design or coalesce into the latest pending target; whichever behavior is implemented must be deterministic and tested.
- Keep `selectedSearchResultId` bound to the active positioned/positioning result, not a future pending target that has not started.
- If a pending target is recorded, keep the current active counter until the target actually starts positioning, but show the lower-panel loading spinner.
- Store the calculated `scrollDirection` with each pending target and use that stored direction when the pending target drains.
- Ensure failure/completion drains the latest pending target without clearing the active selected cell first.
- Add privacy-safe trace lines for:
  - result navigation tap;
  - base index;
  - target index;
  - requested direction;
  - resolved scroll direction;
  - pending/coalesced/drained status.

Acceptance criteria:

- Up/down buttons are visible and actionable after the initial result has positioned.
- Navigation moves to the result shown by the counter.
- Scroll animation direction matches the pressed button except the documented wraparound cases.
- Navigation cannot get stuck with spinner forever after a successful context final.

Required tests after implementation:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests

git diff --check
```

Manual check:

- In Alexey Boldin, search `Тест`.
- After `1 of 18` is positioned, tap up repeatedly.
- Verify movement to older messages and visible upward scroll.
- Tap down repeatedly.
- Verify movement to newer messages and visible downward scroll.
- Verify `18 -> 1` scrolls down and `1 -> 18` scrolls up.

Commit:

```bash
git add xabberTests xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift
git commit -m "Repair chat search result navigation"
```

### Task 6 - Keep Active Selection Stable Across Loading, Datasource Applies, And Visible Cell Reuse

Purpose: the highlighted message must not disappear while context is loading, and only the active lower-panel result may have full-message selection.

Pre-task tests:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatDiffKeySignatureTests \
  -only-testing:xabberTests/ChatDisplayModelCacheTests
```

Implementation:

- Add tests that model:
  - active result selected;
  - context loading starts for a pending/next result;
  - datasource applies new context rows;
  - previous active result remains selected until the new target actually starts positioning;
  - once positioning starts, only the new active result is selected.
- Ensure `MessageCellDelegate.isSelected(primary:)` and `chatDatasourceItem(_:matchesSearchSelection:)` select only the current active search result id.
- Ensure visible cell reuse calls `refreshVisibleSearchSelection()` after:
  - result list application;
  - search active target change;
  - datasource apply completion;
  - `positionMessage` completion;
  - search cancel/clear.
- Preserve attributed text occurrence highlighting for every visible matching message.
- Do not use full-message selection for all results in `searchMessagesQueue`.

Acceptance criteria:

- Active full-message selection does not disappear during server/context loading.
- Non-active search matches keep only text occurrence highlighting.
- After moving to a new result, old visible selected cell is cleared.
- Selection state survives collection view cell reuse and targeted diffs.

Required tests after implementation:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatDiffKeySignatureTests \
  -only-testing:xabberTests/ChatDisplayModelCacheTests

git diff --check
```

Commit:

```bash
git add xabberTests xabber/controllers/chats/chat
git commit -m "Stabilize active chat search selection"
```

### Task 7 - Add Simulator Regression Coverage For The Full Alexey Boldin Search Flow

Purpose: cover the real user-visible path that keeps regressing.

Pre-task tests:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/InfoCardChatSearchRoutingTests \
  -only-testing:xabberTests/InfoCardSearchAccessibilityTests \
  -only-testing:xabberTests/ChatSearchInputBarViewTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests
```

Implementation:

- Add the narrowest practical UI/integration coverage for:
  - search mode exposes top input, search submit button, bottom cancel/status/up/down panel;
  - keyboard open keeps the bottom panel visible;
  - submitting `Тест` starts loading, then shows results;
  - first result starts anchor positioning;
  - up/down controls move the active result after positioning;
  - bottom cancel exits search mode.
- Prefer XCUITest/accessibility identifiers if an app UI test target is available.
- If no suitable UI test target exists, add a documented simulator QA script/checklist in the repo and keep XCTest coverage at the unit/integration layer.
- Capture runtime evidence:
  - screenshot with keyboard open and bottom panel above it;
  - screenshot after `1 of 18` is positioned;
  - short note of up/down movement;
  - relevant trace excerpts showing search MAM final, context final, positioning started, positioned.

Acceptance criteria:

- The running iPhone 16e simulator reproduces the fixed flow in Alexey Boldin.
- The bottom search bar follows the keyboard.
- Search `Тест` moves to the first result after server results.
- Up/down navigation visibly moves between results.
- Cancel exits search mode.

Required tests after implementation:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/InfoCardChatSearchRoutingTests \
  -only-testing:xabberTests/InfoCardSearchAccessibilityTests \
  -only-testing:xabberTests/ChatSearchInputBarViewTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatInChatSearchQueryLifecycleTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests

git diff --check
```

Commit:

```bash
git add xabberTests docs xabber/controllers/chats
git commit -m "Cover chat search navigation on iPhone 16e"
```

### Task 8 - Final Documentation, Build, And Handoff

Purpose: close the goal with durable documentation and a full enough regression pass.

Pre-task tests:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/ChatSearchInputBarViewTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatInChatSearchQueryLifecycleTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests \
  -only-testing:xabberTests/InfoCardChatSearchRoutingTests \
  -only-testing:xabberTests/InfoCardSearchAccessibilityTests
```

Implementation:

- Update durable docs if behavior changed:
  - `docs/features/messaging.md` for user-visible in-chat search behavior;
  - vault UI/XMPP/tests notes for the final contract;
  - shared interfaces only if a cross-layer contract changed beyond the already documented search anchor pipeline.
- Record the server contract confirmed from `/Users/igor.boldin/projects/xabber/server/src/mod_mam_sql.erl`:
  - `withtext` full-text search;
  - chronological MAM result order;
  - iOS newest-first UI normalization.
- Run final verification:
  - focused search regression slice;
  - `git diff --check`;
  - cached Debug build on iPhone 16e.
- Do not leave disposable result bundles/log files in the repo.

Acceptance criteria:

- Documentation states the final expected behavior clearly.
- Search UI, search lifecycle, anchor positioning, result navigation, and card routing tests pass together.
- Cached Debug build passes on iPhone 16e.
- Manual QA evidence is recorded in the task/vault note.

Required tests/build after implementation:

```bash
XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/ChatSearchInputBarViewTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatInChatSearchQueryLifecycleTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests \
  -only-testing:xabberTests/InfoCardChatSearchRoutingTests \
  -only-testing:xabberTests/InfoCardSearchAccessibilityTests

git diff --check

XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e' \
  tools/xcodebuild_cached.sh build
```

Commit:

```bash
git add docs xabberTests xabber/controllers /Users/igor.boldin/projects/xabber/xabber/projects/xabber
git commit -m "Document fixed chat search navigation"
```

## Final Manual QA Checklist

- Open running iPhone 16e simulator.
- Open Alexey Boldin chat.
- Enter chat search from the current route used in the bug report.
- Tap top search input; keyboard opens.
- Verify bottom status bar is above keyboard.
- Search `Тест`.
- Wait for server results.
- Verify chat moves to `1 of 18` without needing an extra tap.
- Verify only the active result has full-message selection.
- Tap up:
  - counter changes to `2 of 18`;
  - scroll moves visually upward to older content.
- Tap down:
  - counter changes back to `1 of 18`;
  - scroll moves visually downward to newer content.
- Navigate to wraparound:
  - `18 -> 1` scrolls down;
  - `1 -> 18` scrolls up.
- While a server/context request is in progress:
  - lower panel shows spinner;
  - current active result remains selected until new positioning starts.
- Tap bottom-left cancel.
- Verify normal chat composer/nav state is restored.

## Expected Final Log Shape

The final fixed flow should contain trace events equivalent to:

- search MAM request send with `withtext=Тест`;
- search MAM final with `count=18`;
- search result queue normalized newest-first;
- initial search result open requested for archived id `1783493923727774`;
- if context is required, context MAM request/final;
- context final flush with query-scoped persistence proof;
- search anchor positioning started for the active archived id;
- anchored datasource apply, not `openLatest` with `anchorRestorePhase=none`;
- `positionMessage` completion;
- lower panel context loading cleared and navigation controls enabled.

