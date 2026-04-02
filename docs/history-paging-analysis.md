# History Paging Analysis

Analysis date: `2026-03-30`

This document analyzes the current history-loading pipeline across:

- `xabber/xmpp/messages/message_archive/MessageArchiveManager.swift`
- `xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift`
- `xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift`
- `xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift`
- `xabber/controllers/chats/chat/rx/ChatViewController+LowPrioritySubscribtions.swift`
- `xabber/xmpp/XEP-0CCC/ClientSynchronizationManager.swift`

No runtime behavior was changed for this analysis. This is a bug-report and contract document for the current implementation.

## Expected Workflow Baseline

The desired workflow is:

1. If chat is not synced, request exactly one newest archive page.
2. If chat is synced and the user scrolls toward older messages, request the next older page.
3. If the user lands in the middle of history by archived id or date, allow paging in both directions from that point.
4. If the visible data contains a history gap, close only the missing range.
5. Loading state, skeleton state, and paging state must be deterministic and derived from one consistent transport contract.

## Canonical Paging Vocabulary

The current code mixes UI direction, dataset direction, and MAM direction. For the rest of this document, the canonical meaning is:

| Term | Canonical meaning |
| --- | --- |
| `messagesObserver[0]` | newest local message |
| larger observer index | older local message |
| `older` | move toward larger observer indices and request archive `before` the current oldest loaded message |
| `newer` | move toward smaller observer indices and request archive `after` the current newest loaded message in the current window |
| RSM `before` | request older page |
| RSM `after` | request newer page relative to a local middle window |

Current code facts:

- `requestArchive` maps `nextPage -> <before/>` and `prevPage -> <after/>` in `MessageArchiveManager.swift:343-430`.
- `getNextHistory(...)` actually requests `before`, so it means `older`, not “next” in UI chronology (`MessageArchiveManager.swift:708-727`).
- `getPrevHistory(...)` actually requests `after`, so it means `newer`, not “prev” in UI chronology (`MessageArchiveManager.swift:686-705`).
- `ChatDirection.up` is currently used for loading older history, while `ChatDirection.down` is used for loading newer history from a middle slice (`ChatViewController+Dataset.swift:1086-1124`).

Recommended normalization for later implementation:

- Replace `up/down` with `older/newer` in the paging pipeline.
- Replace `getNextHistory/getPrevHistory` with names that match RSM semantics.
- Keep UI scroll direction separate from archive request direction.

## Flow Matrix

| Workflow | Trigger and entrypoint | Current MAM call(s) | Request parameters | State mutations | Current issues |
| --- | --- | --- | --- | --- | --- |
| `1. Open unsynced chat` | `ChatViewController.viewWillAppear` calls `subscribe()` and then `loadInitialDatasource()` when `datasource.isEmpty` (`ChatViewController.swift:1839-1872`) | `subscribe()` always calls `syncChat(...)` (`ChatViewController+HighPrioritySubscribtions.swift:89-95`). `loadInitialDatasource()` separately calls `getHistoryByDate(... reversed: true)` when `isSynced == false` (`ChatViewController+Dataset.swift:898-937`) | `syncChat` unsynced request: `start=archiveStart`, `end=nil`, `nextPage=""`, `prevPage=nil`, `flipPage=true`, `max=pageSize(50)`, `isNormalSynchronousTask=true` (`MessageArchiveManager.swift:618-624`). `loadInitialDatasource` request: `start=dateLimit`, `end=nil`, `nextPage=""`, `prevPage=nil`, `flipPage=true`, `max=250`, `isNormalSynchronousTask=true` (`MessageArchiveManager.swift:261-280`) | `MessageArchiveManager.read` sets `fullArchiveLoaded`, `isInitialArchiveLoaded`, `isSynced`, and `lastLoadedMessageHistoryId` for non-continuation requests (`MessageArchiveManager.swift:225-231`). UI sets skeleton true and immediately reloads empty dataset (`ChatViewController+Dataset.swift:899-900`) | Bootstrap is not single-owned. Chat open can trigger two different newest-page request paths with different `max` values and different boundary logic. |
| `2. Open already-synced chat` | `subscribe()` still calls `syncChat(...)` on every open (`ChatViewController+HighPrioritySubscribtions.swift:89-95`) | `syncChat(...)` scans the full local history for query-id discontinuities and issues one request per gap (`MessageArchiveManager.swift:517-608`) | Gap-fix requests use `start=gap.endDate`, `end=gap.startDate`, `nextPage=nil`, `prevPage=nil`, `flipPage=false`, `max=250`, `isContinues=true` (`MessageArchiveManager.swift:589-607`) | No skeleton from `loadInitialDatasource()` if `isSynced == true` (`ChatViewController+Dataset.swift:939-940`). Gap-fix requests still mutate `lastLoadedMessageHistoryId` and may continue loading with delay through `continueLoadHistory` (`MessageArchiveManager.swift:177-217`, `794-821`) | Chat open does background gap repair even before user scrolls. Gap repair uses a brittle local heuristic and a trimmed date range. |
| `3. Scroll from newest toward older history` | Collection-view bottom-edge heuristic calls `onTouchEndPage(direction: .up)` when `(contentSize.height - contentOffset.y) < view.bounds.height` (`ChatViewController+HighPrioritySubscribtions.swift:214-218`) | `loadDatasource(direction: .up)` either expands local window or calls `getNextHistory(...)` (`ChatViewController+Dataset.swift:948-1124`) | Local window for `.up` increases `maxIndex` by `pageSize` (`ChatDatasetCoordinator.nextWindow`, `ChatViewController+Dataset.swift:126-132`, `973-985`). Remote older-page request is `nextPage=archivedId`, which becomes RSM `<before>` and uses `max=250`, `flipPage=true`, `isNormalSynchronousTask=true` (`MessageArchiveManager.swift:708-727`, `343-430`) | UI sets `currentPage.locked`, shows `chatViewLoadingOverlay` and `messageLoadingActivityIndicator`, disables interaction, then completion waits for `messagesObserver.count > previousCount` or times out (`ChatViewController.swift:466-495`, `ChatViewController+Dataset.swift:959-970`, `1081-1124`) | Older paging can return early before checking server archive availability (`ChatViewController+Dataset.swift:999-1009`). Older-page requests also mark `isInitialArchiveLoaded/fullArchiveLoaded` because `getNextHistory` is flagged as `isNormalSynchronousTask=true`. |
| `4. Scroll back toward newer history after paging older` | Top-bounce heuristic calls `onTouchStartPage(direction: .down)` when `contentOffset.y < 0`, `currentPage.minIndex > 0`, and the visible slice is not already at the newest message (`ChatViewController+HighPrioritySubscribtions.swift:220-228`) | `loadDatasource(direction: .down)` either shrinks to a newer local window or calls `getPrevHistory(...)` (`ChatViewController+Dataset.swift:948-1124`) | Local window for `.down` subtracts `pageSize` from `minIndex` (`ChatViewController+Dataset.swift:126-132`, `973-985`). Remote newer-page request is `prevPage=archivedId`, which becomes RSM `<after>` and uses `max=250`, `flipPage=true`, `isNormalSynchronousTask=false` (`MessageArchiveManager.swift:686-705`, `343-430`) | Same loading UI path as older paging. `getPrevHistory` does not mutate `fullArchiveLoaded` or `isInitialArchiveLoaded` because `isNormalSynchronousTask=false` | Trigger is bounce-based rather than based on crossing a logical newest boundary. Direction naming is inverted and easy to misuse. |
| `5. Jump to archived id or date` | Search/external result calls `scrollToMessage(archivedId:date:direction:)` (`ChatViewController+SearchBar.swift:31-89`, `92-152`, `212-239`) | If target is already local: no MAM request. If not: first `getHistoryByDate(start:nil,end:date,reversed:true)`, then `getHistoryByDate(start:date,end:nil,reversed:false)` (`ChatViewController+SearchBar.swift:52-73`) | First request: `start=nil`, `end=date`, `nextPage=""`, `flipPage=true`, `max=250`. Second request: `start=date`, `end=nil`, `nextPage=nil`, `flipPage=true`, `max=250` (`MessageArchiveManager.swift:261-280`) | UI disables datasource loading and shows loading overlay before remote fetch (`ChatViewController+SearchBar.swift:76-88`). If target is found, it replaces window around the observer index and then full-reloads the collection (`ChatViewController+SearchBar.swift:31-49`, `92-99`, `121-124`, `149-152`) | `direction` argument is ignored for deciding which side to load. The code always loads both sides around the date. If target is still absent, loading UI is not restored (`ChatViewController+SearchBar.swift:32-36`). |
| `6. Close a history gap` | Either local window scan inside `loadDatasource(...)` or full-history scan inside `syncChat(...)` | Local gap path calls `getNextHistory(...)` or `getPrevHistory(...)` by endpoint archived id (`ChatViewController+Dataset.swift:1048-1124`). Full-history gap path issues `requestArchive(start: gap.endDate, end: gap.startDate, flipPage:false, isContinues:true)` (`MessageArchiveManager.swift:535-608`) | Local-gap requests use endpoint archived ids with `max=250`. Full-gap repair uses trimmed date ranges with `±600s` in `HistoryGap.init` (`MessageArchiveManager.swift:503-514`) | Local gap completion depends on count increase in `messagesObserver`. Full-gap repair autoloads continuation pages after a forced `2s` delay (`MessageArchiveManager.swift:215-217`) | Gap closure is inferred from `queryIds` overlap rather than explicit page boundaries. Small gaps can be skipped entirely by date trimming. |

## State Contract Matrix

| Flag | Intended meaning under desired workflow | Current writers | Current readers | Current contract problem |
| --- | --- | --- | --- | --- |
| `isSynced` | The chat has completed its initial newest-page bootstrap and can leave skeleton mode, but it may still have older history available. | Default `true` in model (`LastChatsStorageItem.swift:51`); bootstrap success path (`MessageArchiveManager.swift:230`); `syncChat` completion (`MessageArchiveManager.swift:636`); unsynced instance creation (`MessageArchiveManager.swift:660`); encrypted sync backpressure in `ClientSynchronizationManager` (`ClientSynchronizationManager.swift:964-1009`); new last-chat creation via message save (`MessageStorageItem.swift:1003`) | `loadInitialDatasource()` (`ChatViewController+Dataset.swift:898`); initial chat UI subscription (`ChatViewController+HighPrioritySubscribtions.swift:323`); later skeleton gate (`ChatViewController+HighPrioritySubscribtions.swift:463`); initial-message visibility (`ChatViewController+LowPrioritySubscribtions.swift:381`); `syncChat()` branch choice (`MessageArchiveManager.swift:521-522`) | The flag is overloaded. It is used as transport bootstrap state, chat-list badge state, and encrypted sync freshness state. It is also set too early on partial bootstrap pages. |
| `isInitialArchiveLoaded` | The first archive bootstrap page for this chat has been fetched and persisted. | Set in non-continuation requests only when `isNormalSynchronousTask == true` (`MessageArchiveManager.swift:226-229`); also set in `syncChat` completion (`MessageArchiveManager.swift:636-637`) | `syncChat()` branch choice (`MessageArchiveManager.swift:521`); chat skeleton gate (`ChatViewController+HighPrioritySubscribtions.swift:463`) | The flag depends on a transport-specific boolean (`isNormalSynchronousTask`) instead of a real bootstrap contract. Older-page fetches through `getNextHistory` also qualify as “initial archive” because that method uses `isNormalSynchronousTask=true`. |
| `fullArchiveLoaded` | The server has confirmed there are no older pages left for this chat. | Continuation completion when `isNormalSynchronousTask == true` (`MessageArchiveManager.swift:185-200`); non-continuation requests when `isNormalSynchronousTask == true` (`MessageArchiveManager.swift:226-227`) | Local paging early checks (`ChatViewController+Dataset.swift:1025-1046`); `checkShouldLoadFullHistory` (`MessageArchiveManager.swift:730-752`) | The flag is updated asymmetrically. `getNextHistory` uses `isNormalSynchronousTask=true`, but `getPrevHistory` does not. It is also written on partial bootstrap flows that are not purely “load older until complete.” |
| `isAllHistoryLoaded` | All fixable local gaps were closed for the session and no more background history repair is needed. | Only helper `makeInitialMessageVisible(...)` writes it (`MessageArchiveManager.swift:145-161`) | `checkShouldLoadFullHistory` (`MessageArchiveManager.swift:735`) | The intended writer is not active. The calls that should invoke `makeInitialMessageVisible(...)` are commented out in `MessageArchiveManager.swift:235`, `241`, and earlier continuation paths, so the flag behaves like dead state. |

Additional state note:

- `lastLoadedMessageHistoryId` is written in `MessageArchiveManager.swift:201` and `231`, but there are no active readers in the project. It is effectively write-only and does not participate in paging decisions.

## Gap And Completion Audit

| Rule | Location | Classification | Why |
| --- | --- | --- | --- |
| Local gap detection by `queryIds` intersection | `ChatViewController+Dataset.swift:1052-1062` | `false-gap-prone`, `directionally incorrect` | It assumes continuity if adjacent messages share at least one `queryId`. That is not a stable paging boundary model and breaks for mixed local/runtime inserts. It also contains a duplicate token check for `"runtime_send"`. |
| Full-history gap scan by `queryIds` intersection | `MessageArchiveManager.swift:535-549` | `false-gap-prone` | Same heuristic is used globally on the entire local history, so any query-id noise can schedule unnecessary gap repair or miss real gaps. |
| Gap repair with `±600s` trimming | `MessageArchiveManager.swift:509-513` | `false-gap-prone` | For a small or adjacent gap, trimming both ends by 10 minutes can eliminate the missing interval entirely and skip legitimate messages. |
| Completion by `messagesObserver.count > previousCount` | `ChatViewController+Dataset.swift:959-970` | `duplicate-prone`, `timeout-prone` | Duplicate-only fetches or successful gap closures that do not increase count still look like “no completion” until retries are exhausted. |
| Search jump guard on missing target | `ChatViewController+SearchBar.swift:32-36` | `timeout-prone`, `UX-bug` | If the fetched target still is not present, the method returns without restoring loading indicator state or datasource loading state. |
| Continuous continuation delay | `MessageArchiveManager.swift:215-217` | `performance-prone` | Every continuation page waits 2 seconds before requesting the next page, regardless of network or merge state. |
| Scroll-trigger detection by bounce / content size | `ChatViewController+HighPrioritySubscribtions.swift:214-228` | `directionally incorrect` | Paging is triggered by raw collection offset heuristics instead of by explicit oldest/newest visible message boundaries. |

## Prioritized Bug Report

### Correctness

- **[P0] Older-history paging can stop at the end of the local cache even when the server still has older messages**
  Workflow: `3`
  Refs: `ChatViewController+Dataset.swift:999-1009`
  Observable failure: when the current visible window already reaches `messagesObserver.count - 1`, the method returns before it checks `fullArchiveLoaded` and before it can issue `getNextHistory(...)`.
  Root cause: “reached end of local results” is treated as equivalent to “archive fully loaded.”
  Expected behavior: if `fullArchiveLoaded == false`, reaching the local end should request one older page from MAM.
  Suggested fix direction: move the early exit behind archive-end evaluation and separate local-slice exhaustion from remote-archive exhaustion.

- **[P0] `isSynced` is promoted on partial bootstrap pages**
  Workflow: `1`, `2`
  Refs: `MessageArchiveManager.swift:225-231`
  Observable failure: a single partial archive page can mark the chat as synced and hide skeleton even when bootstrap is not logically complete.
  Root cause: non-continuation MAM success sets `instance.isSynced = true` unconditionally, regardless of `complete`.
  Expected behavior: the first-page-loaded state and the “chat is fully bootstrapped enough for UI” state should be explicit and should not be inferred from any non-error MAM result.
  Suggested fix direction: gate `isSynced` behind a dedicated bootstrap contract instead of the raw non-continuation callback.

- **[P1] Chat open can launch two competing newest-page bootstrap paths**
  Workflow: `1`
  Refs: `ChatViewController.swift:1843-1872`, `ChatViewController+HighPrioritySubscribtions.swift:89-95`, `MessageArchiveManager.swift:517-625`, `ChatViewController+Dataset.swift:898-937`
  Observable failure: opening an unsynced chat can cause both `syncChat(...)` and `loadInitialDatasource()` to own bootstrap, with different request shapes and different page sizes.
  Root cause: bootstrap responsibility is split between chat subscriptions and chat dataset initialization.
  Expected behavior: there should be exactly one owner of newest-page bootstrap.
  Suggested fix direction: pick one bootstrap owner and make the other path consume state instead of issuing its own request.

- **[P1] Search/date jump always fetches both sides of the target and ignores requested direction**
  Workflow: `5`
  Refs: `ChatViewController+SearchBar.swift:31-89`
  Observable failure: jumping to a target message loads both `end=date` and `start=date` ranges even when only one side is missing.
  Root cause: the `direction` parameter is unused for request selection.
  Expected behavior: load only the missing side needed to place the target into the visible window, then resume normal bidirectional paging from there.
  Suggested fix direction: separate “target not loaded” from “which side of the target is missing.”

- **[P1] Gap closure uses query-id overlap instead of stable archive boundaries**
  Workflow: `3`, `4`, `6`
  Refs: `ChatViewController+Dataset.swift:1052-1062`, `MessageArchiveManager.swift:535-549`
  Observable failure: gaps can be falsely detected, missed, or re-requested when local/runtime inserts or mixed query ids are present.
  Root cause: continuity is inferred from a transport tag (`queryIds`) rather than from a persistent paging boundary model.
  Expected behavior: history continuity should be determined from archived ids, persisted page boundaries, or explicit gap records.
  Suggested fix direction: replace query-id intersection heuristics with a dedicated history-boundary model.

- **[P1] Gap repair trims 10 minutes from both ends and can skip small missing ranges**
  Workflow: `6`, `7`
  Refs: `MessageArchiveManager.swift:509-513`
  Observable failure: a narrow gap can disappear completely once both ends are trimmed by `600` seconds, so no repair request can ever include the missing messages.
  Root cause: gap repair uses time trimming instead of exact archive boundaries.
  Expected behavior: repairing a gap should never shrink the requested interval past the known missing range.
  Suggested fix direction: request by exact archived ids or use untrimmed date boundaries with deduplication.

### State-Contract

- **[P1] `isInitialArchiveLoaded` depends on `isNormalSynchronousTask`, not on actual bootstrap**
  Workflow: `1`, `3`
  Refs: `MessageArchiveManager.swift:226-229`, `686-727`, `708-727`
  Observable failure: `getNextHistory(...)` older-page loads can mark `isInitialArchiveLoaded` because they are flagged as normal synchronous tasks, while `getPrevHistory(...)` newer-page loads cannot.
  Root cause: transport call classification leaks directly into bootstrap state.
  Expected behavior: initial-archive state should only be written by the dedicated newest-page bootstrap path.
  Suggested fix direction: remove bootstrap-state writes from generic paging helpers.

- **[P1] Skeleton contract is inconsistent between initial subscription and later updates**
  Workflow: `1`, `2`
  Refs: `ChatViewController+HighPrioritySubscribtions.swift:322-323`, `463-467`
  Observable failure: initial setup uses `!chat.isSynced`, but later updates use `!(item.isSynced || item.isInitialArchiveLoaded)`.
  Root cause: the initial and reactive UI paths use different truth conditions for the same skeleton.
  Expected behavior: skeleton visibility should be derived from one single contract.
  Suggested fix direction: route both the initial and reactive path through the same computed archive/bootstrap state.

- **[P2] `isAllHistoryLoaded` is effectively dead state**
  Workflow: `6`
  Refs: `MessageArchiveManager.swift:145-161`, `235`, `241`, `735`
  Observable failure: the flag is checked in `checkShouldLoadFullHistory(...)` but the active code never writes it because the intended call sites are commented out.
  Root cause: unfinished refactor / commented-out completion hook.
  Expected behavior: either remove the flag or restore one real writer with a clear contract.
  Suggested fix direction: decide whether this flag still matters; if yes, reconnect it to a live completion path.

- **[P2] `lastLoadedMessageHistoryId` is write-only**
  Workflow: `1`, `3`, `6`
  Refs: `LastChatsStorageItem.swift:64`, `MessageArchiveManager.swift:201`, `231`
  Observable failure: state is persisted but not consumed anywhere in active paging logic.
  Root cause: stale transport bookkeeping.
  Expected behavior: either use it as a real page boundary pointer or remove it from the contract.
  Suggested fix direction: audit whether the field is still needed for resume/boundary logic.

### UX / Loading

- **[P1] Search jump can leave loading UI and datasource loading disabled**
  Workflow: `5`, `9`
  Refs: `ChatViewController+SearchBar.swift:32-36`, `76-88`
  Observable failure: if the requested archived id is still absent after the fetch, `update()` returns early without restoring loading indicators or datasource-loading state.
  Root cause: missing failure/empty-result cleanup path after remote fetch.
  Expected behavior: all search jump outcomes should end in a deterministic loading-state reset.
  Suggested fix direction: add an explicit “target not found after fetch” completion branch.

- **[P1] Page completion depends on count growth instead of transport completion**
  Workflow: `3`, `4`, `6`
  Refs: `ChatViewController+Dataset.swift:959-970`
  Observable failure: duplicate-only fetches, deduplicated inserts, or successful gap closures with no net-new rows look like “no completion” until retries expire.
  Root cause: page completion is inferred from `messagesObserver.count > previousCount`.
  Expected behavior: paging completion should be driven by transport completion and boundary changes, not only by local row count.
  Suggested fix direction: complete on callback + boundary validation instead of count-only growth.

- **[P2] Scroll-trigger detection is based on bounce heuristics instead of visible logical boundaries**
  Workflow: `3`, `4`
  Refs: `ChatViewController+HighPrioritySubscribtions.swift:214-228`
  Observable failure: paging depends on raw collection view offsets and top/bottom bounce behavior, which is sensitive to layout, insets, and short datasets.
  Root cause: no explicit “oldest visible message” / “newest visible message” paging contract.
  Expected behavior: page triggers should fire only when the user reaches the relevant logical boundary of the currently loaded window.
  Suggested fix direction: compute paging triggers from visible message ids or visible window indices, not raw offset thresholds.

### Performance / Overfetch

- **[P2] Network page size is inconsistent with UI page size**
  Workflow: `1`, `3`, `4`, `5`, `6`
  Refs: `MessageArchiveManager.swift:108`, `261-280`, `686-727`
  Observable failure: the manager’s default page size is `50`, but history/date/prev/next requests use `250`, so one network page can be five UI windows.
  Root cause: UI window size and transport page size have diverged.
  Expected behavior: one transport page should align with the intended UI window or be explicitly decoupled with a documented buffering policy.
  Suggested fix direction: choose one page-size contract and apply it consistently.

- **[P2] Continuation paging adds a forced 2-second delay per page**
  Workflow: `2`, `6`
  Refs: `MessageArchiveManager.swift:215-217`
  Observable failure: long gap repair or multi-page continuation waits 2 seconds between pages independent of server speed or merge completion.
  Root cause: hard-coded timer in continuation path.
  Expected behavior: continuation should be driven by actual completion and backpressure, not by a fixed sleep.
  Suggested fix direction: replace timer-based continuation with completion-driven scheduling.

- **[P2] `syncChat()` performs full-history gap scanning on every chat open**
  Workflow: `2`
  Refs: `ChatViewController+HighPrioritySubscribtions.swift:89-95`, `MessageArchiveManager.swift:517-608`
  Observable failure: opening a chat triggers a scan across all local messages and may schedule multiple repair requests before the user scrolls.
  Root cause: chat-open lifecycle is coupled to gap-fix lifecycle.
  Expected behavior: chat-open should bootstrap current viewport state first; full-history repair should be decoupled or throttled.
  Suggested fix direction: run gap repair opportunistically or in background policy, not inline with every chat-open subscription.

## Acceptance Grid

| Scenario | Current status | Blocking issues |
| --- | --- | --- |
| `1. Unsynced chat with no local messages requests exactly one newest page` | Fails | partial-sync promotion, dual bootstrap ownership, page-size mismatch |
| `2. Unsynced chat with some local messages avoids query-id bootstrap heuristics` | Fails | dual bootstrap ownership, query-id gap inference |
| `3. Synced chat at newest position pages older history on demand` | Partially fails | local-end early return, bounce-based scroll trigger |
| `4. After loading older pages, scrolling back loads only newer history` | Partially fails | bootstrap-state leakage into paging, bounce-based scroll trigger |
| `5. Jump to archived id/date fetches only the missing side and restores normal paging` | Fails | direction-agnostic jump loading, stuck loading-state cleanup |
| `6. Duplicate-only or gap-closing fetches still complete correctly` | Fragile | query-id gap inference, count-based completion |
| `7. Small gaps under 20 minutes are not skipped` | Fails | 10-minute gap trimming |
| `8. Gap closure stops only when archive is truly complete` | Fragile | query-id gap inference, dead `isAllHistoryLoaded`, forced continuation delay, chat-open gap scan |
| `9. Search seek up/down preserves direction and never leaves loading stuck` | Fails | direction-agnostic jump loading, stuck loading-state cleanup, bounce-based scroll trigger |
| `10. Skeleton and loading indicators map deterministically to archive state` | Fails | partial-sync promotion, bootstrap-state leakage, inconsistent skeleton contract, stuck loading-state cleanup |

## Conclusions

The current implementation does not have one authoritative history-paging contract. Bootstrap, gap repair, scroll paging, and search jump each make their own paging decisions, and the shared state flags are overloaded enough that UI and transport semantics drift apart.

The highest-value fix order is:

1. Make newest-page bootstrap single-owned and redefine `isSynced` / `isInitialArchiveLoaded`.
2. Replace ambiguous direction names with `older/newer` and align MAM helper names to actual RSM behavior.
3. Remove early local-end exits that block server paging.
4. Replace `queryIds` gap inference with a real history-boundary model.
5. Make jump-to-message directional and failure-safe.
