# In-chat search

## Product behavior

Xabber's UIKit chat screen provides a Telegram-style search mode implemented independently with Xabber components, symbols and state. Search does not copy reference-app source code, implementation structure, generated icon paths, assets or branding. It uses public UIKit APIs only and adds no third-party dependency.

The observable contract is:

- The top search surface is 60 pt high. Its field and close action are 44 pt high with 16 pt base horizontal insets and an 8 pt gap. The decorative leading magnifier uses a 44×44 layout slot, an 8 pt leading content inset and strict `0 pt` vertical offset (`top=0`, `bottom=0`); it has no tap or VoiceOver action.
- Editing changes only `draftQuery`. The submitted `query`, results, timeline highlighting and committed selection stay unchanged until Search is pressed on the keyboard. Search resigns the field, submits exactly once and invalidates work for the previous query generation. An empty submission clears the presentation without calling a provider; Clear immediately clears both the draft and the current results.
- Chat mode shows the committed match as `current of total`, with upper=older and lower=newer 40 pt arrows separated by 12 pt. Boundaries are disabled and never wrap.
- Idle, loading, empty and error states show only a 40×40 pt circular calendar surface. Its glyph fits within 24×24 pt while the real hit and accessibility target remains at least 44×44 pt. The first positive result expands the surface to a 144 pt capsule and shows `N messages`; only successful timeline positioning changes it to `current of total`. `No messages` is never rendered or exposed to accessibility.
- `Show as List` presents detached results newest-first. Rows show avatar, semibold sender, one-line plain snippet, date and an outgoing delivery status where applicable. Yellow match highlighting belongs to the timeline only.
- `Show as Chat` restores the committed timeline result. Interactive list dragging may dismiss the keyboard; ordinary chat/list toggles preserve reducer-owned keyboard intent.
- Calendar X closes only the calendar and restores its chat/list origin, query, results and committed selection without automatically restoring the keyboard. Calendar Done exits search/list mode and navigates to the message resolved for the selected timestamp; it does not filter the text result set to a date range.

## State, results and provider ownership

One active `ChatSearchPresentationState`/session generation owns the independent draft and submitted query, detached results, committed selection, provider terminal state, loading, chat/list/calendar origin and keyboard intent. Reducer events that navigate or change presentation preserve the draft, and UI transitions consume reducer output rather than inferring state from view visibility.

Provider boundaries are fixed:

- Regular and group text search uses paged MAM `withtext`. Search persistence is query scoped and does not advance normal archive coverage, archive-end proof or history cursors.
- Encrypted text search uses `ChatSearchLocalProvider` only. It performs exact owner/JID/conversation-type filtering off-main and returns detached newest-first deduplicated results.
- Both providers emit detached presentation values and typed terminal outcomes. Cancellation/query replacement rejects stale batches, final IQs and scheduled continuation work.
- On-demand older-page navigation expedites only the existing MAM continuation for the active generation/cursor. UI never constructs another search stanza.

All result opens use the established Xabber anchor pipeline through `ChatOpenMessageRequest(source: .search, markReadOnVisible: false)`. The committed result changes only after successful positioning. List selection prefers archive ID and carries bounded fallback identity when needed.

## Calendar date navigation

Calendar selection is a timestamp-navigation feature, not a result filter:

1. The local timestamp resolver first considers displayed detached candidates, then reads the injected Realm configuration off-main.
2. Encrypted conversations always resolve locally or return no message.
3. Incomplete regular/group history may return `.needsRemote` with bounded nearest candidates.
4. Remote fallback uses a distinct MAM timestamp lookup with at most two one-message requests: earliest at/after exact `start`, then latest before exact `end` only when needed. These requests never contain `withtext`.
5. Success opens a `.search` anchor with `highlight=false` and `markReadOnVisible=false`. Empty, failure, cancel, background, duplicate Done and stale-generation paths are terminal.

Timestamp resolution does not mutate normal archive coverage, history cursors or the active text-search paging session.

## Motion and accessibility

All new motion consumes the injectable `ChatSearchAnimationSpec`:

- Search chrome uses the shared 0.30 s spring. The calendar-only surface expands or collapses with an interruptible 0.30 s spring plus synchronized counter alpha; repeated count/index updates do not start another animation.
- Counter text changes atomically only after positioning is committed. It has no digit transition, vertical movement or independent animation channel. Result navigation performs one normal animated `scrollToItem` and never applies a preliminary content-offset jump.
- List presentation uses scale 0.95→1.0 over 0.40 s and blur 30→0 over 0.20 s; dismissal uses 0.30 s.
- Calendar presentation/dismissal and month travel use the shared plans, including a 0.30 s month transition.
- Reduce Motion applies capsule geometry immediately and uses only a short counter alpha transition while still applying final state. Reduce Transparency removes blur in favor of an opaque system treatment. Runtime accessibility-setting changes re-resolve the production animation specification.

Controls keep localized labels, deterministic semantic order and at least 44 pt hit targets. Layout mirrors in RTL, supports Dynamic Type growth and maintains bottom controls above the keyboard. UIKit presentation uses public `UIVisualEffectView`/snapshot/property-animation paths only; private filters and private Apple APIs are prohibited.

## Safety and verification

Hosted XCTest must use explicit allowlists with both `TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1` and `TEST_RUNNER_XABBER_ISOLATED_STORAGE=1`. The hosted bundle uses an isolated Realm and a hosted-only Keychain service; broad tests must not run on an account-bearing simulator.

Live QA is explicitly gated to the approved simulator, Andrew Nenakhov with Alexey Boldin fallback, and exact query `test`. Teardown may close search and terminate the process only. Simulator erase/uninstall/reset, container or Realm deletion, logout, account removal and credential input/change are prohibited.

The final unit/build/install/account and PTS-based reference comparison is recorded in [Telegram-style in-chat search verification](../qa/telegram-style-in-chat-search-verification.md). Performance budgets are recorded in [Chat Search Performance Budgets](../testing/chat-search-performance-budgets.md).
