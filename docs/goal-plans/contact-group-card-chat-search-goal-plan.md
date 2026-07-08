# Contact And Group Card Chat Search Goal Plan

project:: xabber-ios
owner:: xabber-ui
secondary:: xabber-xmpp, xabber-tests
status:: open
created:: 2026-07-08

## Goal Mode Prompt

Use this whole file as the execution prompt for an automatic Codex goal.

Objective:

Implement and verify the desired behavior when the user taps the search button in a Contact Info card or Group Info card:

- the modal Contact Info or Group Info screen is dismissed first;
- the matching chat is opened;
- the chat opens directly in in-chat search mode;
- the top of the chat shows a search input with an explicit search button;
- the bottom of the chat shows a result panel with total/current count and up/down buttons;
- the bottom panel shows a loading indicator while server search or anchor/context history requests are active;
- moving between search results is as smooth as possible;
- when history around a found message must be fetched, or local archive gaps must be repaired, the chat may show a blocking loading overlay and temporarily lock manual scrolling until positioning is safe;
- the search input, search button, bottom panel, and controls use the same native Liquid Glass / `NativeGlassBarStyle` effect family used by the rest of the app.

Manual QA target:

- Use the already running iPhone 16e simulator.
- Use the dialog with `alexey boldin` for runtime verification.
- Do not erase the simulator or reset account state.
- If the simulator is not logged in or the `alexey boldin` dialog is unavailable, record the blocker in the task note and continue with XCTest/build verification.

Repository:

`/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core`

Primary plan file:

`/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/docs/goal-plans/contact-group-card-chat-search-goal-plan.md`

Vault task:

`/Users/igor.boldin/projects/xabber/xabber/projects/xabber/tasks/open/xab-contact-group-card-chat-search-goal-plan.md`

Relevant knowledge and vault context:

- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/shared/interfaces.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/shared/dependencies.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/docs/features/messaging.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/specs/ios-chat-opening-correctness-goal-plan.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/tasks/done/xab-chat-search-server-history-stabilization.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/tasks/done/xab-in-place-native-search-results.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/tasks/done/xab-chat-opening-correctness-goal-plan.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/ui/context.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/xmpp/context.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/tests/context.md`

Current implementation findings:

- `ContactInfoViewController.searchChat(conversationType:)` routes through `routeToChat(... configure:)` and sets `chatVc?.inSearchMode.accept(true)`. It already uses `performAfterResolvedContactInfoExit`, so it can dismiss modal Contact Info before routing.
- `GroupchatInfoViewController.searchChat()` currently only calls `dismiss(animated:) { self.chatStateDelegate?.openSearchBar() }`. That only works if the target chat is already open and is the most likely source of the current broken behavior.
- `ChatViewController.configureSearchBar(...)` currently installs a `UISearchBar` in navigation items and applies manual transparency/shadow tweaks. This does not give a clean, explicit Liquid Glass search input plus search button contract.
- `ModernXabberInputView.SearchPanel` already exists at the bottom and already has `counterLabel`, up/down buttons, and `activityIndicator`. Its loading state is not yet treated as the authoritative in-chat search lifecycle UI.
- `ChatViewController.updateSearchResults(value:)` already scopes in-chat regular/group search to `owner`, `jid`, and `conversationType`, uses MAM search on non-encrypted chats, and local Realm search for encrypted chats.
- `ChatViewController.queueOpenMessageRequest(... source: .search)` is already the correct anchor path for search results. The shared contract says search jumps must use local displayed lookup first, then MAM exact/date-window fallback, final-IQ flush, context prefetch, centered positioning, and optional blocking overlay while context is loading.
- `onSearchPanelSeekUp()` and `onSearchPanelSeekDown()` currently return immediately while `currentPage.locked`, which can make rapid result navigation feel unresponsive instead of queueing the user's latest intent.

Execution rules for every numbered task:

1. Start each task by reading any files named in that task that changed since this plan was written.
2. Run that task's pre-task tests before editing production code.
3. Add or update focused XCTest coverage first.
4. When practical, run the new/changed focused test before production edits and confirm it fails for the intended reason.
5. Implement the smallest production change for the task.
6. Run the task's required tests and adjacent tests named in the task.
7. Run `git diff --check`.
8. Run one app build before closing the task. Prefer the running iPhone 16e simulator for this goal unless a connected physical device is explicitly required by the environment.
9. Update vault notes after each task:
   - `projects/xabber/agents/ui/notes.md`
   - `projects/xabber/agents/tests/notes.md`
   - `projects/xabber/agents/xmpp/notes.md` only when search MAM, final-IQ, archive gaps, or remote history behavior changes.
   - `projects/xabber/shared/interfaces.md` only when a durable cross-layer contract changes.
10. Stage only files changed for the current task.
11. Commit after every task before starting the next one.
12. Do not run `clean`; use `tools/xcodebuild_cached.sh clean-cache` only when explicitly diagnosing cache corruption.

Recommended verification setup:

```bash
export XABBER_SCHEME='Debug (xabber Workspace)'
export XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e,OS=26.0'
```

If the scheme or destination is unavailable:

```bash
xcodebuild -list -workspace xabber.xcworkspace
xcrun simctl list devices available
```

Then set `XABBER_SCHEME` and `XABBER_DESTINATION` to concrete available values and continue.

## Task 1 - Lock The Card Search Routing Contract

Goal:

Make Contact Info and Group Info search buttons follow one explicit route contract: dismiss card first, open the correct chat, then enter chat search mode. This task should not redesign the search UI yet.

Files to inspect/change:

- `xabber/controllers/chats/info_screens/contact_info/ContactInfoViewController+InfoScreenHeaderButtonDelegate.swift`
- `xabber/controllers/chats/info_screens/groupchat_info/GroupchatInfoViewController+InfoScreenHeaderButtonDelegate.swift`
- `xabber/controllers/chats/info_screens/contact_info/ContactInfoViewController.swift`
- `xabber/controllers/chats/info_screens/groupchat_info/GroupchatInfoViewController.swift`
- `xabber/controllers/chats/last_chats_list/LastChatsViewController+UITableViewDelegate.swift`
- any `LeftMenuDelegate` / chat routing protocol that owns `openChatlistWithChat(... configure:)`
- focused tests under `xabberTests/`

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/ContactInfoNavigationTests \
  -only-testing:xabberTests/ChatOpenMessageRequestHandlingPolicyTests \
  -only-testing:xabberTests/ChatNavigationBarStateTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required test changes:

- Add a focused test type such as `InfoCardChatSearchRoutingTests`.
- Cover regular Contact Info search:
  - modal Contact Info resolves to `.dismissThenPerform` when it is the presented card;
  - route target uses the card's `owner`, `jid`, and `.regular`;
  - the created/opened `ChatViewController` receives a durable search-mode activation request.
- Cover encrypted Contact Info search if the card exposes encrypted search:
  - route target uses `.omemo`;
  - account OMEMO init behavior remains unchanged for encrypted chat open.
- Cover Group Info search:
  - route target uses the group `owner`, `jid`, and `.group`;
  - the implementation does not depend on `chatStateDelegate?.openSearchBar()` or an already-open chat;
  - modal Group Info is dismissed before routing.
- Cover left-menu/split routing:
  - both contact and group route through `leftMenuDelegate.openChatlistWithChat(... configure:)` when the delegate exists;
  - `configure` is still called after the actual chat controller exists.
- Cover non-left-menu routing:
  - the fallback creates a new `ChatViewController`;
  - `owner`, `jid`, `conversationType`, and search activation are set before presentation.

Implementation requirements:

- Extract or reuse a small shared routing helper/policy if it makes both Contact Info and Group Info paths consistent without large refactors.
- Replace `GroupchatInfoViewController.searchChat()`'s `chatStateDelegate?.openSearchBar()` dependency with the same open-chat-with-search-mode route used by contact cards.
- Keep `performAfterResolvedContactInfoExit` behavior for Contact Info; add equivalent route-safe dismissal for Group Info if missing.
- Do not change normal `openChat()` behavior.
- Do not start any MAM search request in the card controller; the chat owns search execution after it opens.

Acceptance criteria:

- Tapping search in Contact Info always opens that contact's chat in search mode after dismissing the card.
- Tapping search in Group Info always opens that group's chat in search mode after dismissing the card.
- The group path works even when the group chat was not already open.
- Existing open-chat, invite, mute, leave, and edit actions from cards are unchanged.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/InfoCardChatSearchRoutingTests \
  -only-testing:xabberTests/ContactInfoNavigationTests \
  -only-testing:xabberTests/ChatNavigationBarStateTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build \
  -destination "$XABBER_DESTINATION" \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "fix(chat): route info card search to chat search mode"
```

## Task 2 - Make Chat Search Mode Activation Durable

Goal:

Add a clear Chat-owned search-mode activation API that works whether the chat is already loaded, being pushed, being shown after modal dismissal, or being opened through split routing.

Files to inspect/change:

- `xabber/controllers/chats/chat/ChatViewController.swift`
- `xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift`
- `xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift`
- `xabber/controllers/chats/last_chats_list/LastChatsViewController+UITableViewDelegate.swift`
- files touched by Task 1 routing
- focused tests under `xabberTests/`

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/InfoCardChatSearchRoutingTests \
  -only-testing:xabberTests/ChatOpenMessageRequestHandlingPolicyTests \
  -only-testing:xabberTests/ChatNavigationBarStateTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required test changes:

- Add or extend tests for a method such as `ChatViewController.activateSearchModeFromExternalRoute(...)`.
- Cover activation before `viewDidLoad`:
  - search mode request is retained;
  - when the chat loads/subscribes, the search UI is configured once;
  - keyboard activation is requested only after the view is ready.
- Cover activation while already visible:
  - repeated card-search activation is idempotent;
  - existing search text/results are preserved or reset according to explicit policy, not accidentally duplicated.
- Cover activation during navigation transition:
  - navigation item mutation is deferred or non-animated according to `ChatNavigationTransitionMutationPolicy`;
  - no stale normal-mode avatar/nav buttons survive search mode.
- Cover cancel:
  - cancel exits search mode and restores normal navbar/input state;
  - cancel does not pop or dismiss the chat opened from card search.

Implementation requirements:

- Introduce a named API instead of external callers directly writing `inSearchMode.accept(true)`. Suggested shape:
  - `activateSearchModeFromExternalRoute(activateKeyboard:animated:initialQuery:)`
  - or a small `ChatSearchActivationRequest` model.
- Keep existing `inSearchMode` relay as the internal state if that is the smallest safe change.
- Ensure activation before the view is loaded is not lost.
- Ensure the search input can become first responder only after the chat view is in a window or at least loaded enough to accept focus.
- Keep existing search result anchor behavior untouched.

Acceptance criteria:

- Search mode opens reliably from Contact Info and Group Info on compact and split paths.
- Search mode activation is idempotent.
- Normal chat opening does not enter search mode.
- Search cancel restores the chat to normal mode without closing the chat.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/InfoCardChatSearchRoutingTests \
  -only-testing:xabberTests/ChatSearchModeActivationTests \
  -only-testing:xabberTests/ChatNavigationBarStateTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build \
  -destination "$XABBER_DESTINATION" \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "refactor(chat): add durable search activation"
```

## Task 3 - Replace Top Search Chrome With Native Glass Controls

Goal:

Make the top in-chat search UI a first-class native-glass control surface with an input field and explicit search button, instead of relying on a manually restyled `UISearchBar`.

Files to inspect/change:

- `xabber/controllers/chats/chat/ChatViewController.swift`
- `xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift`
- `xabber/controllers/chats/chat/extension/ChatViewController+Navbar.swift`
- `xabber/controllers/chats/chat/messages_kit/Views/ModernXabberInputView.swift`
- `xabber/common` or existing files that define `NativeGlassBarStyle` / `XabberGlassStyle`
- `xabberTests/XabberGlassStyleTests.swift`
- `xabberTests/ChatNavigationBarStateTests.swift`
- focused new tests under `xabberTests/`

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/ChatSearchModeActivationTests \
  -only-testing:xabberTests/ChatNavigationBarStateTests \
  -only-testing:xabberTests/XabberGlassStyleTests \
  -only-testing:xabberTests/ChatComposerSendButtonIconTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required test changes:

- Add `ChatSearchInputBarViewTests` or equivalent.
- Cover top search control structure:
  - one glass/material surface using shared `NativeGlassBarStyle` / `XabberGlassStyle`;
  - text input is transparent inside the glass surface;
  - explicit search button is icon-only, 44 pt, native glass or clear-on-glass according to local style;
  - cancel/close action is 44 pt and does not share stale navbar background;
  - input and buttons have accessibility identifiers:
    - `chat_search_input`
    - `chat_search_submit`
    - `chat_search_cancel`
- Cover layout:
  - no text clipping at iPhone 16e width;
  - Dynamic Type does not make button text overflow because buttons are icon-based;
  - compact and regular width use stable heights and safe-area/nav constraints;
  - search input does not overlap avatar/title/back items.
- Cover command behavior:
  - tapping the explicit search button submits the current text;
  - pressing return submits the current text;
  - empty/whitespace text clears current search state without firing a server request.

Implementation requirements:

- Prefer a dedicated UIKit view such as `ChatSearchInputBarView` over further manual `UISearchBar` layer/background mutation.
- Use existing shared glass helpers:
  - `NativeGlassBarStyle.makeEffect(interactive:)`
  - `NativeGlassBarStyle.applySurface(...)`
  - `NativeGlassBarStyle.applyIconButtonStyle(...)`
  - `XabberGlassStyle` where that is the app-wide source of truth.
- Keep cards at 8 pt radius or less only if using card-like repeated items; search controls should follow the established app glass bar metrics instead.
- Use SF Symbols / existing `imageLiteral` for search, close/cancel, and arrows; do not introduce custom SVG.
- Remove old iOS 26-only manual `UISearchBar.backgroundImage`, shadow, and `searchTextField.borderStyle` hacks when they are superseded by the new view.
- Keep navigation item ownership centralized through `NavigationBarItemOwnership.apply`.

Acceptance criteria:

- In search mode, the top UI visibly presents an input and explicit search button.
- Top search UI uses the same native Liquid Glass/material fallback family as the rest of the app.
- Search submit works from button and keyboard return.
- Cancel exits search mode.
- No stale normal navbar avatar/title controls remain visible during search mode.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/ChatSearchInputBarViewTests \
  -only-testing:xabberTests/ChatSearchModeActivationTests \
  -only-testing:xabberTests/ChatNavigationBarStateTests \
  -only-testing:xabberTests/XabberGlassStyleTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build \
  -destination "$XABBER_DESTINATION" \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "feat(chat): add native glass search input"
```

## Task 4 - Make Bottom Search Panel State Authoritative

Goal:

Make the bottom search panel the single visible source for result count, up/down navigation, and loading state during in-chat search.

Files to inspect/change:

- `xabber/controllers/chats/chat/messages_kit/Views/ModernXabberInputView.swift`
- `xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift`
- `xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift`
- `xabber/controllers/chats/chat/ChatViewController.swift`
- existing `NativeGlassBarStyle` / `XabberGlassStyle` definitions
- focused tests under `xabberTests/`

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/ChatSearchInputBarViewTests \
  -only-testing:xabberTests/ChatComposerSendButtonIconTests \
  -only-testing:xabberTests/XEPMessageScheduleUITests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required test changes:

- Add `ChatSearchBottomPanelTests`.
- Cover panel states:
  - empty query: panel shows no count/up/down and no spinner;
  - active query, no results yet, server request in flight: spinner visible;
  - active query, results present, no request in flight: count and up/down visible, spinner hidden;
  - active query, results present, context fetch in flight for selected result: spinner visible, count may remain visible if design chooses, up/down disabled or hidden by policy;
  - final no-result state: `0 found` visible, spinner hidden, up/down hidden.
- Cover accessibility identifiers:
  - `chat_search_results_panel`
  - `chat_search_results_count`
  - `chat_search_previous_result`
  - `chat_search_next_result`
  - `chat_search_loading`
- Cover visual metrics:
  - panel uses shared glass effect/fallback;
  - up/down buttons are 44 pt hit targets;
  - count text fits at iPhone 16e width and does not resize the panel unexpectedly.

Implementation requirements:

- Extend `ModernXabberInputView.SearchPanel` with an explicit render state if needed, for example:
  - `.idle`
  - `.loading`
  - `.emptyResults`
  - `.results(current:total:isLoadingContext:)`
- Do not infer every state only from `searchMessagesQueue.isEmpty`; server loading and context loading are separate.
- Wire `searchTextObserver`, MAM search callbacks, and anchor/context loading to this panel state.
- Keep result count stable while a context load is in progress unless the query itself changes.
- Ensure the panel remains the active bottom input state while the keyboard is hidden or shown.
- Preserve existing selection panel, record panel, composer, scheduled-message, and context-preview states outside search mode.

Acceptance criteria:

- The bottom panel always tells the user whether search is idle, loading, empty, or has results.
- Loading indicator appears for server search queries.
- Loading indicator appears while fetching history around a selected result or repairing a gap for search positioning.
- Up/down controls are unavailable while a navigation request cannot safely accept another immediate jump, unless Task 6's pending-intent queue is ready.
- The panel uses native Liquid Glass/material fallback consistently.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatSearchInputBarViewTests \
  -only-testing:xabberTests/ChatComposerSendButtonIconTests \
  -only-testing:xabberTests/XEPMessageScheduleUITests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build \
  -destination "$XABBER_DESTINATION" \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "feat(chat): show search loading in results panel"
```

## Task 5 - Stabilize In-Chat Search Query Lifecycle

Goal:

Make in-chat search query lifecycle generation-safe, scoped to the current chat, and correctly reflected in the bottom panel.

Files to inspect/change:

- `xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift`
- `xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift`
- `xabber/controllers/chats/chat/ChatViewController.swift`
- `xabber/xmpp/message_archive` and MAM search helpers if needed
- `xabber/controllers/chats/search/SearchResultsViewController.swift`
- `xabber/controllers/chats/search/SearchResultsViewController+SearchResultsUpdater.swift`
- `xabberTests/xabberTests.swift` existing search completion tests
- focused new tests under `xabberTests/`

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatSearchServerHistoryStabilizationTests \
  -only-testing:xabberTests/ChatOpenMessageRequestHandlingPolicyTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required test changes:

- Add `ChatInChatSearchQueryLifecycleTests`.
- Cover generation behavior:
  - query A starts, query B starts, late A messages/end-page are ignored;
  - query cancel clears current query id and ignores late callbacks;
  - empty query clears results and loading;
  - same query text is debounced/deduped.
- Cover scope:
  - regular chat search sends MAM with current `jid` and `.regular`;
  - group chat search sends MAM with current `jid` and `.group`;
  - encrypted chat search does local Realm only and does not send regular MAM search.
- Cover persistence and final-IQ behavior:
  - final IQ flush runs before result application;
  - search results only include rows for current owner/JID/conversation type;
  - stale remote callback does not append to `searchMessagesQueue`.
- Cover bottom panel:
  - loading starts when a non-empty query is submitted;
  - loading ends on current query final/error/cancel;
  - no-result current query shows `0 found`.

Implementation requirements:

- Represent in-chat search query generation explicitly; `currentSearchQueryId` alone may be sufficient if it is cleared/compared everywhere.
- Make MAM search callback acceptance check both query id and current chat identity.
- Ensure `registerRemoteHistoryPersistenceSource` / `unregisterRemoteHistoryPersistenceSource` are balanced for current and canceled queries.
- Route MAM errors through the same loading cleanup path as final IQ.
- Do not change global Last Chats search behavior except for shared helpers that remain backward-compatible.

Acceptance criteria:

- In-chat search never mixes stale results from an older query.
- Group search is scoped to the group chat, not global messages.
- Contact search is scoped to the one-to-one chat.
- Encrypted chat search stays local.
- Bottom panel loading cannot hang after final/error/cancel.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/ChatInChatSearchQueryLifecycleTests \
  -only-testing:xabberTests/ChatSearchServerHistoryStabilizationTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatOpenMessageRequestHandlingPolicyTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build \
  -destination "$XABBER_DESTINATION" \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "fix(chat): stabilize scoped search queries"
```

## Task 6 - Smooth Result Navigation And Pending Intent Queue

Goal:

Make up/down navigation between search results feel responsive while preserving archive correctness. Local results should move immediately; remote/context loads should show loading UI and apply the latest requested result when ready.

Files to inspect/change:

- `xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift`
- `xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift`
- `xabber/controllers/chats/chat/ChatViewController.swift`
- `xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift`
- existing anchor/context prefetch policy tests
- focused new tests under `xabberTests/`

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatSearchServerHistoryStabilizationTests \
  -only-testing:xabberTests/ChatMessageAnchorPolicyTests \
  -only-testing:xabberTests/ChatFirstFrameLocalHistoryRegressionTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required test changes:

- Add `ChatSearchResultNavigationStateTests`.
- Cover local navigation:
  - if selected result is already in current datasource, up/down positions it without showing blocking overlay;
  - result count updates before or at the same time as positioning;
  - highlight happens after the target row is positioned.
- Cover remote/context navigation:
  - when anchor/context fetch starts, bottom panel enters loading state;
  - collection scrolling is locked only while blocking search context loading is active;
  - overlay/activity indicator is visible while archive context is required;
  - overlay and scroll lock are removed on success, failure, cancel, and search exit.
- Cover pending intent behavior:
  - pressing next while a previous search anchor is loading records the latest desired index instead of being dropped;
  - repeated next/previous taps coalesce to the latest intended result;
  - when the active load finishes, the latest pending result is opened if it differs from the current positioned result;
  - no infinite loop when pending target fails.
- Cover wraparound policy:
  - previous from the first result wraps to the last only if existing UX requires wraparound;
  - next from the last wraps to the first only if existing UX requires wraparound;
  - document and test whichever behavior is chosen.

Implementation requirements:

- Replace bare `if self.currentPage.locked { return }` behavior in search seek actions with an explicit search navigation state:
  - idle
  - positioning(index)
  - loadingContext(index)
  - pending(index)
- Continue to use `queueOpenMessageRequest(source: .search)` for actual positioning.
- Keep `ChatAnchorContextPrefetchModePolicy.mode(source: .search, ...) == .blocking` unless a local-hit immediate path is proven safe.
- Do not mark messages read merely because search navigation opened them.
- Keep `preventHidingDate` balanced for success/failure paths.

Acceptance criteria:

- Up/down taps are not silently lost while a search context load is active.
- Local result moves are immediate and animated smoothly.
- Remote/context result moves show a bounded loading state and land on the requested result without latest-first correction.
- Manual scrolling is restored after every success/failure/cancel path.
- Result count and selected index stay consistent with the target being opened.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatSearchServerHistoryStabilizationTests \
  -only-testing:xabberTests/ChatMessageAnchorPolicyTests \
  -only-testing:xabberTests/ChatFirstFrameLocalHistoryRegressionTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build \
  -destination "$XABBER_DESTINATION" \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "fix(chat): smooth search result navigation"
```

## Task 7 - Preserve Archive Gap Repair And Search Anchor Correctness

Goal:

Ensure search result navigation uses the existing archive positioning pipeline correctly when the local archive has gaps or missing context around the found message.

Files to inspect/change:

- `xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift`
- `xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift`
- `xabber/controllers/chats/chat/datasource/ChatViewController+Datasource.swift`
- `xabber/xmpp/message_archive`
- `xabber/xmpp/messages/messages_manager`
- existing archive coverage/gap tests under `xabberTests/`

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatArchiveCoverageCommitPolicyTests \
  -only-testing:xabberTests/ChatHistoryPageCompletionPolicyTests \
  -only-testing:xabberTests/ChatRemoteHistoryApplyPolicyTests \
  -only-testing:xabberTests/ChatHistoryPagingPolicyTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required test changes:

- Add `ChatSearchArchiveGapRepairTests` or extend the existing archive/search suite.
- Cover exact archived-id search target:
  - local miss triggers exact archived-id fetch first;
  - date-window fallback runs only if exact fetch cannot resolve the target;
  - final-IQ flush happens before datasource apply/positioning.
- Cover known gap behavior:
  - search positioning does not locally page across a known archive gap;
  - gap repair MAM request uses server archive cursors and current conversation type;
  - loading overlay remains until gap repair/context apply is complete.
- Cover failure behavior:
  - server error clears loading state and keeps the user in search mode;
  - failed target does not clear the whole result list;
  - pending navigation intent can move to another result after failure.
- Cover search read semantics:
  - opening a result from search does not call read-all/latest-read paths;
  - existing visible-message read observation remains the only automatic read path.

Implementation requirements:

- Reuse the existing anchor fetch/context prefetch/gap repair path; do not add a second search-specific archive fetch implementation unless a small wrapper is required.
- Keep query-source scoped persistence proof for UI-managed MAM.
- Keep `unregisterRemoteHistoryPersistenceSource` balanced for anchor remote fetch and context prefetch query ids.
- Make bottom panel/context loading state respond to both exact fetch and gap repair query lifecycle.
- Avoid broad datasource reloads that break smooth scroll when a targeted apply is sufficient.

Acceptance criteria:

- Search can position a result not currently in local datasource.
- Search can fetch context around a result without showing latest first.
- Search can repair a local archive gap before positioning.
- Server failure leaves search mode usable and clears all loaders.
- Archive coverage is not advanced without query-scoped proof.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatArchiveCoverageCommitPolicyTests \
  -only-testing:xabberTests/ChatHistoryPageCompletionPolicyTests \
  -only-testing:xabberTests/ChatRemoteHistoryApplyPolicyTests \
  -only-testing:xabberTests/ChatHistoryPagingPolicyTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build \
  -destination "$XABBER_DESTINATION" \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "fix(chat): keep search anchors archive-safe"
```

## Task 8 - Add UI Automation Hooks For Card Search

Goal:

Add stable accessibility identifiers and UI-test helpers so the card-search flow can be tested on the running iPhone 16e simulator with the `alexey boldin` dialog.

Files to inspect/change:

- `xabber/controllers/chats/info_screens/contact_info/ContactInfoViewController.swift`
- `xabber/controllers/chats/info_screens/groupchat_info/GroupchatInfoViewController.swift`
- `xabber/controllers/chats/info_screens/views/InfoScreenHeaderView.swift` or equivalent header button view
- `xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift`
- `xabber/controllers/chats/chat/messages_kit/Views/ModernXabberInputView.swift`
- XCUITest target files if present; otherwise add focused UI-test documentation/helpers under `xabberTests/` only if the app target supports it.

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/InfoCardChatSearchRoutingTests \
  -only-testing:xabberTests/ChatSearchInputBarViewTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required test changes:

- Add `InfoCardSearchAccessibilityTests`.
- Cover stable identifiers:
  - contact card search button: `contact_info_search_button`
  - group card search button: `group_info_search_button`
  - chat search input: `chat_search_input`
  - search submit: `chat_search_submit`
  - search cancel: `chat_search_cancel`
  - bottom result panel: `chat_search_results_panel`
  - result count: `chat_search_results_count`
  - previous result: `chat_search_previous_result`
  - next result: `chat_search_next_result`
  - loading indicator: `chat_search_loading`
- Cover identifiers survive state changes:
  - entering search mode;
  - submitting a query;
  - loading;
  - results;
  - cancel.
- If an XCUITest target exists, add a focused UI test that can run against the simulator state without hardcoding localized labels where identifiers are available.

Implementation requirements:

- Prefer identifiers over localized text matching.
- Keep existing VoiceOver labels meaningful; identifiers are for automation and should not replace user-facing accessibility labels.
- Do not remove existing identifiers used by current tests.
- Add helper methods only when repeated UI actions remain readable.

Acceptance criteria:

- The flow can be automated without fragile localized text selectors.
- Accessibility labels remain user-meaningful.
- The added identifiers do not change visual layout.
- Existing UI/unit tests keep passing.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/InfoCardSearchAccessibilityTests \
  -only-testing:xabberTests/InfoCardChatSearchRoutingTests \
  -only-testing:xabberTests/ChatSearchInputBarViewTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build \
  -destination "$XABBER_DESTINATION" \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "test(chat): add card search automation hooks"
```

## Task 9 - Runtime QA On iPhone 16e With Alexey Boldin

Goal:

Verify the complete flow on the already running iPhone 16e simulator using the `alexey boldin` dialog, then record evidence and any remaining runtime-only issues.

Files to inspect/change:

- no production files unless runtime QA exposes a bug;
- update only vault notes and, if useful, `docs/goal-plans/contact-group-card-chat-search-goal-plan.md` with final QA notes after the implementation tasks are complete.

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/InfoCardChatSearchRoutingTests \
  -only-testing:xabberTests/ChatSearchModeActivationTests \
  -only-testing:xabberTests/ChatSearchInputBarViewTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatInChatSearchQueryLifecycleTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests \
  -only-testing:xabberTests/InfoCardSearchAccessibilityTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Manual QA procedure:

1. Confirm the target simulator:

```bash
xcrun simctl list devices booted
```

2. Build and install/run on the booted iPhone 16e:

```bash
tools/xcodebuild_cached.sh build \
  -destination "$XABBER_DESTINATION" \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

3. Open the app on the running simulator.
4. Navigate to the chat/dialog with `alexey boldin`.
5. Open the contact card for Alexey Boldin from the chat header/avatar or existing info action.
6. Tap the contact-card search button.
7. Verify:
   - Contact Info card dismisses;
   - Alexey Boldin chat opens or remains open;
   - chat is in search mode;
   - top native-glass search input and search button are visible;
   - bottom native-glass result panel is visible;
   - keyboard focus is on the search input when expected.
8. Search for a term known to exist in the Alexey Boldin dialog. Prefer a term visible in recent/local history first.
9. Verify:
   - loading indicator appears while search runs;
   - result count appears after results;
   - first result positions smoothly and highlights after positioning;
   - latest is not shown first as a corrective intermediate state.
10. Tap next/previous rapidly.
11. Verify:
   - local result moves are smooth;
   - remote/context loads show loading instead of freezing;
   - latest requested direction/result wins after a blocking load;
   - manual scrolling is restored.
12. If available, test a result outside the resident local window by choosing a search term from older history.
13. Verify:
   - overlay/loading appears while history around the result is fetched;
   - archive gap repair does not expose an incoherent jump;
   - result lands centered/highlighted.
14. Open a group card from a group dialog if available in the same simulator state.
15. Tap group-card search and repeat a short scoped search.
16. Cancel search and confirm the chat returns to normal mode.

Required evidence:

- Record the exact simulator/device name and OS.
- Record the app build/scheme used.
- Record the search terms used for Alexey Boldin.
- Record pass/fail for:
  - contact card dismiss/open/search mode;
  - top search glass;
  - bottom panel count/buttons/loading;
  - server search loading;
  - local result navigation;
  - remote/context result navigation;
  - cancel restore.
- If screenshots are captured, store them under a suitable debug/docs folder and link them from vault notes.

Acceptance criteria:

- Alexey Boldin contact-card search flow passes on iPhone 16e.
- In-chat search UI matches the requested top/bottom structure.
- Loading states are visible during server query and remote/context fetch.
- Result navigation is smooth for local hits and bounded for remote/context hits.
- No modal Contact Info or Group Info remains visible after search routing.
- Any limitation is documented with a concrete blocker and next task.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/InfoCardChatSearchRoutingTests \
  -only-testing:xabberTests/ChatSearchModeActivationTests \
  -only-testing:xabberTests/ChatSearchInputBarViewTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatInChatSearchQueryLifecycleTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests \
  -only-testing:xabberTests/InfoCardSearchAccessibilityTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build \
  -destination "$XABBER_DESTINATION" \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "test(chat): verify card search flow on simulator"
```

## Task 10 - Final Documentation And Integration Check

Goal:

Finalize durable documentation, run the integrated verification slice, and close the vault task with clear results.

Files to inspect/change:

- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/tasks/open/xab-contact-group-card-chat-search-goal-plan.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/ui/notes.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/tests/notes.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/xmpp/notes.md` if XMPP/search MAM behavior changed
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/shared/interfaces.md` if any contract changed
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/docs/features/messaging.md` if the user-facing search behavior is now stable enough for feature docs
- this plan file if final status/evidence needs to be appended

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/InfoCardChatSearchRoutingTests \
  -only-testing:xabberTests/ChatSearchModeActivationTests \
  -only-testing:xabberTests/ChatSearchInputBarViewTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatInChatSearchQueryLifecycleTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests \
  -only-testing:xabberTests/InfoCardSearchAccessibilityTests \
  -only-testing:xabberTests/ChatSearchServerHistoryStabilizationTests \
  -only-testing:xabberTests/ChatOpenMessageRequestHandlingPolicyTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required documentation changes:

- Move the vault task note from `tasks/open/` to `tasks/done/` when all implementation and QA are complete.
- Record:
  - task list completed;
  - commit hashes for each task;
  - exact tests/builds run;
  - Alexey Boldin runtime QA result;
  - any residual risk.
- Update `docs/features/messaging.md` if the behavior is now considered stable:
  - Contact/Group Info search opens the target chat in in-chat search mode;
  - top search input/search button and bottom result panel are the UI contract;
  - search jumps use archive-safe anchor positioning.
- Update `shared/interfaces.md` only if the implementation changed cross-layer behavior beyond what is already documented.

Acceptance criteria:

- All required focused tests pass.
- `git diff --check` passes.
- Final app build passes.
- Vault notes and task state match the real result.
- The final commit contains only documentation/status updates for this closing task.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -destination "$XABBER_DESTINATION" \
  -only-testing:xabberTests/InfoCardChatSearchRoutingTests \
  -only-testing:xabberTests/ChatSearchModeActivationTests \
  -only-testing:xabberTests/ChatSearchInputBarViewTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatInChatSearchQueryLifecycleTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests \
  -only-testing:xabberTests/InfoCardSearchAccessibilityTests \
  -only-testing:xabberTests/ChatSearchServerHistoryStabilizationTests \
  -only-testing:xabberTests/ChatOpenMessageRequestHandlingPolicyTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build \
  -destination "$XABBER_DESTINATION" \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "docs(chat): record card search implementation"
```

## Completion Record

Completed on 2026-07-08 through Task 10.

Implementation commits:

- `c7f281c7` - `fix(chat): route info card search to chat search mode`
- `f92a01ea` - `refactor(chat): add durable search activation`
- `8381f108` - `feat(chat): add native glass search input`
- `00233af3` - `feat(chat): show search loading in results panel`
- `d6e2a0a0` - `fix(chat): stabilize scoped search queries`
- `970f7ee9` - `fix(chat): smooth search result navigation`
- `989a85b3` - `fix(chat): keep search anchors archive-safe`
- `65c5062c` - `fix(chat): avoid unloaded search input crash`
- `af48745c` - `test(chat): add card search automation hooks`
- `4dd4468a` - `test(chat): verify card search flow on simulator`

Final runtime QA:

- Simulator: `iPhone 16e`, iOS 26.0.
- Contact dialog: Alexey Boldin.
- Contact-card search: passed. The Contact Info modal dismissed and the already-open Alexey Boldin chat entered in-chat search mode instead of presenting another modal route.
- Query used: `Тест`; result panel showed `1 of 18`; next/previous navigation moved through results and cancel restored normal chat chrome.
- Group-card smoke: `xabber developers` Group Info search dismissed the card and entered search mode in the current group chat.
- Loading limitation: the live server query completed too quickly to capture a visible loading frame during manual QA; the `chat_search_loading` state remains covered by XCTest.

Final verification:

```bash
tools/xcodebuild_cached.sh test \
  -destination 'platform=iOS Simulator,name=iPhone 16e,OS=26.0' \
  -only-testing:xabberTests/InfoCardChatSearchRoutingTests \
  -only-testing:xabberTests/ChatSearchModeActivationTests \
  -only-testing:xabberTests/ChatSearchInputBarViewTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/ChatInChatSearchQueryLifecycleTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests \
  -only-testing:xabberTests/InfoCardSearchAccessibilityTests \
  -only-testing:xabberTests/ChatSearchServerHistoryStabilizationTests \
  -only-testing:xabberTests/ChatOpenMessageRequestHandlingPolicyTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Result: `50` tests passed with `0` failures.

Additional final verification also passed:

- `git diff --check`
- cached simulator Debug build for `iPhone 16e`, iOS 26.0
- XcodeBuildMCP build/run on the booted `iPhone 16e`
