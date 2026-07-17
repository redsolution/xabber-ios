# Root Section Bottom Bars Goal Plan

created:: 2026-07-13
owner:: xabber-ui
secondary:: xabber-tests
coordination:: xabber-lead
repo:: `/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber-ios-performance-fixes`
branch-at-planning-time:: `feature/performance-fixes`
vault:: `/Users/igor.boldin/projects/xabber/xabber`
status:: ready-for-goal-mode

## Goal Mode Prompt

The following prompt is designed for Codex automatic goal mode. Start it from the repository named above. The official goal workflow is described at <https://learn.chatgpt.com/codex/use-cases/follow-goals>.

```text
/goal Implement all eight tasks in docs/goal-plans/root-section-bottom-bars-goal-plan.md, strictly in order, and keep working until the Final Done Definition is satisfied.

Objective:
Make the lower floating controls on every root section reachable from the Xabber iOS left menu, except Settings, obey one deterministic contract:
- unavailable actions are hidden, not shown disabled;
- hiding an action never moves the remaining controls;
- unread-specific filter/read-all actions disappear when their scoped unread count is zero;
- other filter actions disappear when their current unfiltered scope has no rows to which that filter can apply;
- the last list row remains fully visible above the lower overlay at the maximum scroll position;
- changing overlay/keyboard geometry preserves bottom anchoring without jumping a user who is reading away from the bottom;
- the Search button morphs smoothly and interruptibly into the search field and back.

Authoritative inputs:
- implementation plan: docs/goal-plans/root-section-bottom-bars-goal-plan.md
- source worktree: /Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber-ios-performance-fixes
- knowledge base: /Users/igor.boldin/projects/xabber/xabber-knowledge
- vault task: /Users/igor.boldin/projects/xabber/xabber/projects/xabber/tasks/open/xab-ios-root-section-bottom-bars-goal-plan.md, or the same file after it is moved to tasks/in-progress
- UI/tests handoff: /Users/igor.boldin/projects/xabber/xabber/projects/xabber/handoffs/outgoing/2026-07-13-ui-to-tests-root-section-bottom-bars.md

Execution rules:
1. Read AGENTS.md, the relevant knowledge-base notes, the canonical vault shared docs, and the UI/tests context before Task 01. Re-read them after any resumed/compacted goal turn if the contract is no longer in context.
2. Work only in the source worktree above. Do not accidentally build or commit the canonical xabber_ios_core worktree.
3. Before the first task, run the Common Preflight. The current worktree may not yet contain ignored Pods or xabber.xcworkspace; run pod install only when needed, then verify that generated dependency files remain ignored.
4. Before EACH numbered task, before changing any source or test file, run that task's exact Pre-Task Tests plus both hosted-test safety classes. Record command, destination, count, pass/fail, and first meaningful failure in the vault task execution log.
5. Follow TDD for every behavior change: add or update the focused XCTest first, run it to capture the expected failing assertion or compile-red, then implement the smallest production change that makes it pass. Do not weaken an existing assertion merely to make the suite green.
6. If a pre-task baseline fails, diagnose the first meaningful failure. Continue only when it is fixed in-scope or proven unrelated and recorded with evidence; do not normalize a failing baseline silently.
7. Use only allowlisted -only-testing selectors. Every hosted XCTest command must set TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 and TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 and include AppLaunchEnvironmentPolicyTests and ChatSearchGoalSafetyPolicyTests.
8. Do not run clean, clean-cache, a broad all-tests invocation, simulator erase/reset, uninstall, logout, account removal, Realm deletion, or destructive data setup. Preserve the existing simulator/app container and the shared Xcode caches.
9. Prefer tools/xcodebuild_cached.sh. After the focused post-task tests, run git diff --check and a cached simulator build for every task. A task is not complete if its required build has not passed or its blocker has not been recorded.
10. New Swift/XCTest files must be added to the correct PBX group and Sources phase in xabber.xcodeproj/project.pbxproj. Validate the project file and xcodebuild -list after project-file edits.
11. Keep each source task atomic. Stage only files owned by that task, inspect the staged diff, and create exactly one focused source-repository commit before starting the next task. Never use an empty commit.
12. The source repository and vault are separate git repositories. After each source commit, append its full SHA, tests, build result, and residual risk to the standalone vault task. Commit that task-note update separately in the vault, staging only files owned by this goal. A vault commit does not replace the required source commit.
13. The vault currently may contain unrelated dirty files. Never stage, reset, restore, or overwrite those changes. If a required dashboard or durable-doc file already has unrelated edits, make a narrowly reviewable non-overlapping update only when it can be isolated safely; otherwise record the deferred dashboard reconciliation in the standalone task and continue without staging someone else's work.
14. Preserve all existing accessibility identifiers unless this plan explicitly adds a new one. Hidden controls must also be removed from hit testing and the accessibility tree.
15. Keep regular-width navbar actions behaviorally unchanged. This goal changes lower overlays only; it does not redesign top navigation, left-menu routing, XMPP, persistence, or the unimplemented Start Call flow.
16. When an active filter loses its last applicable row, normalize to the unfiltered state before hiding the filter action. Never leave the user trapped in an empty result with a hidden active filter.
17. Do not proceed to the next task until the current task has: pre-task evidence, TDD evidence, required post-task tests, cached build, focused source commit, and vault log update.
18. At the end, satisfy the Final Done Definition, move the vault task to tasks/done, close the UI-to-tests handoff, and report the eight unique source SHAs. Do not mark the goal complete merely because the tasks were attempted.
```

## Product Scope

### Included root routes

The left-menu datasource and router in `xabber/controllers/split/LeftMenuViewController.swift` expose these root routes:

| Left-menu route | Root list controller | Lower controls today | Goal scope |
| --- | --- | --- | --- |
| Chats | `LastChatsViewController` | Unread filter, Mark all as read, Search | Full visibility, inset, and search-morph contract |
| Calls | `LastCallsViewController` | Compact: Missed, disabled Start Call, Search | Full compact action contract; shared search/inset behavior where the lower search exists |
| Notifications | `NotificationsListViewController` | Compact: Unread, Read all, Search | Full compact action contract; regular navbar stays unchanged |
| Contacts | `ContactsViewController` | Compact: Online, Add Contact, Search | Filter availability plus shared search/inset behavior |
| Groups | `ContactsViewController`, `isGroup = true` | Compact: Online, Create Group, Search | Filter availability plus shared search/inset behavior |
| Archive | `LastChatsViewController`, `.archived` | Search only | Search morph and list-clearance contract |
| Saved Messages | `LastChatsViewController`, `.saved` | Search only when a list is shown | Search morph and list-clearance contract; direct single-service chat routing is unchanged |

`Groups` and `Saved Messages` are conditional product entries. The router also contains a `mentions` branch, but it is not a current left-menu datasource entry and is not a root section for this goal.

### Excluded

- Settings and every Settings subflow.
- Top navigation/filter parity changes on regular-width Calls, Notifications, Contacts, and Groups.
- Left-menu selection/transition animation changes.
- A new Start Call flow. The current lower Start Call action has no target and remains unavailable, so it must be hidden.
- XMPP stanza, synchronization, Realm schema, push, calls-session, or backend changes.
- Replacing UIKit tables with collection views. The affected root lists are currently `UITableView` based; the requirement applies to their scroll content regardless of the word “collection”.
- A new XCUITest target. Use focused hosted XCTest plus non-destructive manual simulator QA.

## Locked Semantics

### “Inactive” versus “not selected”

- An action is **unavailable/inactive** when tapping it cannot perform a valid operation in the current state. It must be hidden.
- A filter that is available but currently **not selected** remains visible and enabled. Its unselected appearance is not an inactive state.
- A visible lower action is always enabled. The goal must not leave a visible-but-dimmed disabled lower button.
- Hidden action slots retain their constraints. Hiding a slot must not recenter, stretch, or shift any other slot.
- Hiding the center action means hiding its entire `centerEffectView`, not just `centerButton`.
- A transparent action-bar container with no visible action must pass touches through to the list and must expose no hidden accessibility elements.

### Filter-data source of truth

Availability must be derived independently of the currently filtered/search result so that a filter does not disappear merely because it produced zero visible rows.

| Root | Availability source | Must ignore | When an active filter loses availability |
| --- | --- | --- | --- |
| Chats | Count of unread, non-archived chats owned by currently enabled accounts | Local search and current `.unread` list contents | Set the list filter to `.chats`, then hide Unread and Mark all |
| Notifications | Count of unread visible notifications matching current category and account scope | Local search and `unreadOnly` itself | Set `unreadOnly` to `false`, then hide Unread and Read all |
| Calls | `CallsListCoordinator.DerivedState.counters.missed` for enabled accounts, calculated before selected filter and search | Current Missed selection and local search | Reset the internal Missed filter to All, then hide Missed |
| Contacts | Count of actual roster/contact rows in the current account/category/circle scope to which Online can apply, evaluated with `showOffline = true` and no search query | Current Online selection and local search | Set `showOffline = true`, then hide Online |
| Groups | Count of joined group roster rows in the current account/category/circle scope to which Online can apply, evaluated with `showOffline = true` and no search query | Current Online selection, local search, invitation-only rows | Set `showOffline = true`, then hide Online |

For Contacts/Groups, `currentFeatureHasAnyContent` is not sufficient: it includes contact requests or group invitations, but the Online filter cannot filter those rows. Add a dedicated filterable-row count/boolean to the derived snapshot. Do not query the currently rendered datasource as the source of truth.

### Expected lower-action matrix

| Root state | Left action | Center action | Search |
| --- | --- | --- | --- |
| Chats, unread = 0 | Hidden | Hidden | Visible in its existing right slot |
| Chats, unread > 0, no enabled account connecting | Visible Unread | Visible Mark all | Visible in its existing right slot |
| Chats, unread > 0, an enabled account connecting | Visible Unread | Hidden Mark all | Visible in its existing right slot |
| Archive list | Hidden | Hidden | Visible |
| Saved Messages list | Hidden | Hidden | Visible |
| Contacts, filterable rows = 0 | Hidden | Visible Add Contact when its existing flow is available | Visible |
| Contacts, filterable rows > 0 | Visible Online | Visible Add Contact | Visible |
| Groups, filterable rows = 0 | Hidden | Visible Create Group when its existing flow is available | Visible |
| Groups, filterable rows > 0 | Visible Online | Visible Create Group | Visible |
| Calls, missed count = 0 | Hidden | Hidden because Start Call is unavailable | Visible |
| Calls, missed count > 0 | Visible Missed | Hidden because Start Call is unavailable | Visible |
| Notifications, matching unread = 0 | Hidden | Hidden | Visible |
| Notifications, matching unread > 0 | Visible Unread | Visible Read all | Visible |

When a compact action bar is not used in regular width, the table must preserve the existing regular navigation items. The shared bottom-search behavior is changed only on screens/layouts where that bottom search already exists; this goal does not introduce a new regular-width Notifications search surface.

### Search transition contract

- The collapsed search control starts at its existing right-aligned circular frame.
- Expansion is a geometric morph into the full-width capsule: the visible surface bounds, corner radius/mask, search icon, text field, and Cancel control transition as one continuous presentation.
- Do not implement expansion as an abrupt `isHidden` swap between two already-final frames plus alpha only.
- Use an interruptible `UIViewPropertyAnimator` or an equivalent interruptible UIKit animator that begins from the current presentation state.
- During expansion, the action bar remains underneath the expanding surface and is hidden only after expansion completes. During collapse, restore the action bar underneath before shrinking the search surface so controls are revealed without moving or popping.
- Do not set the outgoing view hidden until animation completion. A cancelled/reversed animation must end with exactly one interactive surface.
- `becomeFirstResponder`/`resignFirstResponder`, the `keyboardLayoutGuide`, and the width morph must be coordinated so the control does not jump between model frames.
- Rapid Expand → Cancel → Expand sequences must settle deterministically without duplicate callbacks, stale hidden states, or constraint warnings.
- Cancel clears the query and causes one owner-level cancel/reset transaction. It must not first emit a query-change reload and then emit a second cancel reload.
- Respect Reduce Motion with a deterministic non-spatial or shortened transition while preserving final geometry and callbacks.
- Preserve the iOS 26 native-glass path and the material fallback for the iOS 15 deployment target.

### Scroll clearance and offset contract

Replace the duplicated fixed `60` point assignments with one shared, testable overlay-inset policy/coordinator.

- Preserve the scroll view's baseline `contentInset` and `verticalScrollIndicatorInsets`; add/remove only the overlay contribution.
- Compute required effective bottom clearance from the top of the lowest visible overlay in scroll-container coordinates, not from a hard-coded constant alone.
- Required clearance is the distance from the scroll viewport's bottom to the overlay's visible `minY`, plus `12` points.
- Convert effective clearance into explicit `contentInset.bottom` by subtracting the system contribution represented by `adjustedContentInset.bottom - contentInset.bottom`, never producing less than the baseline bottom inset.
- Use the topmost applicable visible lower overlay when Search/action surfaces overlap. Hidden or fully noninteractive overlays do not reserve space.
- Update on initial installation, layout/safe-area changes, horizontal-size-class changes, action visibility changes, search transition completion, and keyboard-layout-guide movement.
- Before an inset change, calculate whether the scroll view is at its old maximum offset with a small tolerance. If it is, move it non-animated to the new maximum offset after applying the inset so the last row remains fully visible.
- If the user is not at the bottom, preserve their content offset; do not pull them to the bottom or visibly jump their reading position.
- Clamp offsets for empty/short content and for inset removal. Do not create overscroll outside the valid min/max range.
- Compose with Last Chats' pinned voice-player top inset; do not overwrite unrelated top/side insets.
- Apply the same overlay contribution to the vertical scroll indicator.

For a typical iPhone safe-area layout, the formula may still result in an explicit `60` points, but that value must be a consequence of geometry (`44` height + `4` offset + `12` clearance after system inset accounting), not the controlling assumption. Expanded search above the keyboard must reserve its actual raised position.

## Current Implementation Evidence

- Shared action/search views: `xabber/controllers/bars/bottom_bar/FloatingBottomBarView.swift`.
  - `setCenterButtonEnabled` currently dims a disabled action instead of hiding it.
  - `BottomSearchHostView.updateVisibility` currently toggles `isHidden` inside an alpha animation between a round button and a full-size surface; no geometry morph occurs.
  - Cancel currently calls both query-change and cancel callbacks.
- Shared search installation helper: `xabber/controllers/chats/search/SearchResultsViewController.swift`, `BottomInPlaceSearchHostHelper`.
- Chats/Archive/Saved: `xabber/controllers/chats/last_chats_list/LastChatsViewController.swift` and `LastChatsViewController+Search.swift`.
- Contacts/Groups: `xabber/controllers/chats/contact_list/ContactsViewController.swift` and `ContactsViewController+Search.swift`.
- Calls: `xabber/controllers/calls/last_calls/LastCallsViewController.swift`, `LastCallsViewController+Search.swift`, and `CallsListCoordinator.swift`.
- Notifications: `xabber/controllers/notifications/NotificationsListViewController.swift`.
- Each affected controller currently writes `0` or a fixed `60` directly to table/indicator bottom inset.
- Existing focused test seams:
  - `xabberTests/FloatingBottomBarViewTests.swift`
  - `xabberTests/LastChatsViewControllerBehaviorTests.swift`
  - `xabberTests/ContactsListAppearanceTests.swift`
  - `xabberTests/CallsListCoordinatorTests.swift`
  - `xabberTests/NotificationsListAppearanceTests.swift`
  - `xabberTests/LeftMenuSelectionPresentationPolicyTests.swift`

## Common Preflight

Run this once before Task 01 and repeat the status/destination checks after any goal resume:

```bash
cd /Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber-ios-performance-fixes

git status --short --branch
git rev-parse --show-toplevel
git branch --show-current

test -d Pods && test -d xabber.xcworkspace || pod install
git status --short --branch

xcodebuild -list -workspace xabber.xcworkspace
xcrun simctl list devices booted
```

Select an already-booted iPhone simulator, preferring the existing iPhone 16e. If none is booted, boot an existing installed iPhone simulator without erasing or recreating it. Record the selected UDID in the vault task, then export:

```bash
export XABBER_SCHEME='Debug'
export XABBER_DESTINATION='platform=iOS Simulator,id=<BOOTED_IPHONE_UDID>'
export TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1
export TEST_RUNNER_XABBER_ISOLATED_STORAGE=1
```

Every test command below assumes those variables. Append these build settings to routine test/build commands unless a diagnosed compiler issue requires otherwise:

```text
ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Before every task also run:

```bash
git status --short --branch
git -C /Users/igor.boldin/projects/xabber/xabber status --short --branch
```

Do not start a task if unrelated source changes overlap its files. Preserve unrelated vault changes and stage vault paths explicitly.

## Per-Task Completion Loop

Apply this loop to Tasks 01–08 without exception:

1. Record source HEAD, source status, vault status, simulator destination, and task start time.
2. Run the task's Pre-Task Tests before editing.
3. Add/update the listed tests first and capture expected red evidence.
4. Implement only the task's production scope.
5. Run the task's Required Verification.
6. Inspect compiler output for the first real error if verification fails; do not broad-refactor around it.
7. Run `git diff --check` and inspect `git diff --stat` plus `git diff`.
8. Run `tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO`.
9. Remove disposable result bundles/logs created for the task; preserve cached DerivedData, SourcePackages, and PackageCache.
10. Stage only task-owned source/test/project files, inspect `git diff --cached`, and create the listed focused source commit.
11. Append evidence and the full source SHA to the standalone vault task; create a separate focused vault commit containing only this goal's note/handoff/doc updates.
12. Confirm both repositories' status and only then start the next task.

## Task 01 — Stable Action Visibility and Fixed Slots

### Purpose

Create one shared lower-action presentation contract before changing any screen-specific availability rules.

### Owner and files

- Owner: `xabber-ui`; secondary: `xabber-tests`.
- Production: `xabber/controllers/bars/bottom_bar/FloatingBottomBarView.swift`.
- Tests: `xabberTests/FloatingBottomBarViewTests.swift`.
- Project file only if a new source/test file is introduced: `xabber.xcodeproj/project.pbxproj`.

### Pre-Task Tests

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/FloatingBottomBarViewTests \
  -only-testing:xabberTests/BottomSearchHostViewTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

### XCTest work first

Add focused coverage equivalent to:

- `testHidingLeftActionKeepsCenterFrameUnchanged`.
- `testHidingCenterActionKeepsLeftFrameUnchanged`.
- `testHidingCenterActionHidesEntireEffectSurface`.
- `testVisibleActionIsEnabledAndAccessible`.
- `testHiddenActionIsDisabledAndAbsentFromAccessibility`.
- `testHiddenLeftSlotPassesTouchesThrough`.
- `testHiddenCenterSlotPassesTouchesThrough`.
- `testFullyHiddenActionContainerPassesTouchesThrough`.
- `testRestoringActionReusesOriginalFrameAndAccessibilityIdentifier`.

Lay out the component in a deterministic fixed-size host before comparing frames. Capture compile-red or assertion-red for the missing shared presentation API and hit-testing behavior.

### Implementation requirements

- Add a small state/API that independently presents left and center slots as hidden or visible/enabled. Exact type names may follow repository style, but one apply call must be able to update both slots atomically.
- A visible slot must be enabled with normal alpha. A hidden slot must be disabled, hidden, non-accessible, and non-hit-testable.
- Preserve the current Auto Layout constraints. Do not convert this view to `UIStackView`; hidden arranged subviews would move remaining controls.
- Hide `centerEffectView` together with `centerButton`.
- Override hit testing narrowly so the transparent container only intercepts points belonging to visible action surfaces.
- Preserve current labels, identifiers, target/action wiring, native glass/material styling, dimensions, and inter-item spacing.
- Keep legacy configuration methods temporarily if required by unmigrated controllers, but mark their transitional role in code. All root controllers must use the new availability API by Task 08, after which unused legacy disabled-visible behavior should be removed.

### Acceptance criteria

- [ ] Left and center visibility can change independently in one state update.
- [ ] Hiding either slot does not change the other slot's frame.
- [ ] Hidden center glass is not visible.
- [ ] A hidden slot cannot receive a touch and is absent from the accessibility tree.
- [ ] An all-hidden action container does not block table interaction.
- [ ] Visible actions retain their current identifiers, targets, styling, and fixed positions.
- [ ] No root-controller domain behavior is opportunistically redesigned in this task.

### Required Verification

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/FloatingBottomBarViewTests \
  -only-testing:xabberTests/BottomSearchHostViewTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO

git diff --check
tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

### Source commit

```text
refactor(bottom-bar): add stable action visibility
```

## Task 02 — Interruptible Search Button-to-Field Morph

### Purpose

Replace the current hidden-state crossfade with a smooth, reversible geometry transition shared by every existing bottom-search owner.

### Owner and files

- Owner: `xabber-ui`; secondary: `xabber-tests`.
- Shared production:
  - `xabber/controllers/bars/bottom_bar/FloatingBottomBarView.swift`
  - `xabber/controllers/chats/search/SearchResultsViewController.swift`
- Owner integration:
  - `xabber/controllers/chats/last_chats_list/LastChatsViewController+Search.swift`
  - `xabber/controllers/chats/last_chats_list/LastChatsViewController.swift`
  - `xabber/controllers/chats/contact_list/ContactsViewController+Search.swift`
  - `xabber/controllers/chats/contact_list/ContactsViewController.swift`
  - `xabber/controllers/calls/last_calls/LastCallsViewController+Search.swift`
  - `xabber/controllers/calls/last_calls/LastCallsViewController.swift`
  - `xabber/controllers/notifications/NotificationsListViewController.swift`
- Tests:
  - `xabberTests/FloatingBottomBarViewTests.swift`
  - the four focused controller test files listed in Current Implementation Evidence.

### Pre-Task Tests

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/FloatingBottomBarViewTests \
  -only-testing:xabberTests/BottomSearchHostViewTests \
  -only-testing:xabberTests/LastChatsViewControllerBehaviorTests \
  -only-testing:xabberTests/ContactsListAppearanceTests \
  -only-testing:xabberTests/CallsVisualStyleTests \
  -only-testing:xabberTests/NotificationsListAppearanceTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

### XCTest work first

Add component tests equivalent to:

- `testExpansionStartsFromCollapsedButtonGeometry`.
- `testExpansionEndsAtFullWidthSurfaceGeometry`.
- `testOutgoingSurfaceIsNotHiddenAtAnimationStart`.
- `testExpansionAndCollapseUseOneContinuousVisibleSurface`.
- `testExpandThenImmediateCollapseSettlesCollapsed`.
- `testCollapseThenImmediateExpandSettlesExpanded`.
- `testCancelClearsQueryWithOneOwnerResetCallback`.
- `testHitTestingFollowsPresentationSurfaceDuringTransition`.
- `testReduceMotionProducesCorrectFinalStateAndCallbackCount`.
- `testRepeatedSetExpandedToSameValueIsIdempotent`.

Add/adjust controller tests proving:

- the action bar is not removed before the expanding surface covers it;
- action slots are restored underneath before collapse begins;
- Chats, Contacts, Groups, Calls, and Notifications do not perform duplicate reloads on Cancel;
- Archive and Saved-list search use the same transition even though no action bar is present.

Use an injected animator factory/duration or another deterministic seam; do not make tests sleep for UIKit timing.

### Implementation requirements

- Animate the search surface from the collapsed button's current frame to the expanded inset capsule frame, including corner geometry/mask as necessary.
- Crossfade/reposition magnifier, text field, and Cancel control as part of the same animator.
- Use `UIViewPropertyAnimator` with begin-from-current-state/reversal semantics or an equivalent interruptible approach. Repeated input must stop/continue from the presentation state, not snap to a stale model frame.
- Keep exactly one logical `isExpanded` result and one interactive surface after completion or interruption.
- Add explicit transition-phase coordination for owners if needed. Expansion should activate search data at the start, but the underlying action bar should become hidden only at expansion completion. Collapse should reveal the action bar under the surface before reverse animation.
- Coordinate first-responder changes with the transition and `keyboardLayoutGuide`; avoid forcing an intermediate final layout before the animator begins.
- Change Cancel so clearing text does not emit a separate owner query-change transaction immediately before `onCancel`.
- Preserve route-dismiss behavior with `animated: false`, placeholder text, current accessibility identifiers, local-search semantics, and keyboard dismissal.
- Keep regular-width navbar behavior unchanged.

### Acceptance criteria

- [ ] Search visibly grows from the round button into the field and shrinks back with no pop or frame jump.
- [ ] Rapid reversal ends in a coherent state with no duplicate surface, hidden interactive view, or Auto Layout warning.
- [ ] Underlying actions never move; they are progressively covered/revealed by the search surface.
- [ ] Cancel produces one query reset/reload at each owner.
- [ ] Keyboard appearance and search expansion form one smooth transition.
- [ ] Reduce Motion has deterministic final states and accessible focus.
- [ ] All existing bottom-search identifiers and search behavior remain intact.

### Required Verification

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/FloatingBottomBarViewTests \
  -only-testing:xabberTests/BottomSearchHostViewTests \
  -only-testing:xabberTests/LastChatsViewControllerBehaviorTests \
  -only-testing:xabberTests/ContactsListAppearanceTests \
  -only-testing:xabberTests/CallsVisualStyleTests \
  -only-testing:xabberTests/NotificationsListAppearanceTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO

git diff --check
tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Manual smoke after automated verification:

- On the existing iPhone simulator, expand/cancel Search repeatedly on Chats and at least one other root without entering or changing live data.
- Record whether width, keyboard lift, Cancel, and reverse motion are free of visible jumps.

### Source commit

```text
fix(bottom-search): animate search field morph
```

## Task 03 — Geometry-Based Overlay Insets and Bottom-Offset Preservation

### Purpose

Guarantee that the last row and scroll indicator remain above the visible lower overlay in every root list, including raised search above the keyboard.

### Owner and files

- Owner: `xabber-ui`; secondary: `xabber-tests`.
- New preferred shared source: `xabber/controllers/bars/bottom_bar/BottomOverlayInsetCoordinator.swift`.
- Integrations:
  - `xabber/controllers/chats/last_chats_list/LastChatsViewController.swift`
  - `xabber/controllers/chats/last_chats_list/LastChatsViewController+Search.swift`
  - `xabber/controllers/chats/contact_list/ContactsViewController.swift`
  - `xabber/controllers/chats/contact_list/ContactsViewController+Search.swift`
  - `xabber/controllers/calls/last_calls/LastCallsViewController.swift`
  - `xabber/controllers/calls/last_calls/LastCallsViewController+Search.swift`
  - `xabber/controllers/notifications/NotificationsListViewController.swift`
- New preferred tests: `xabberTests/RootBottomBarInsetPolicyTests.swift`.
- Project: `xabber.xcodeproj/project.pbxproj` for new files.

### Pre-Task Tests

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/FloatingBottomBarViewTests \
  -only-testing:xabberTests/BottomSearchHostViewTests \
  -only-testing:xabberTests/LastChatsPinnedPlayerInsetPolicyTests \
  -only-testing:xabberTests/LastChatsViewControllerBehaviorTests \
  -only-testing:xabberTests/ContactsListAppearanceTests \
  -only-testing:xabberTests/CallsVisualStyleTests \
  -only-testing:xabberTests/NotificationsListAppearanceTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

### XCTest work first

Create pure policy/coordinator tests equivalent to:

- `testNoOverlayRestoresBaselineBottomInsets`.
- `testSafeAreaZeroComputesOverlayClearance`.
- `testSafeAreaThirtyFourSubtractsAutomaticSystemContribution`.
- `testCollapsedBarLeavesTwelvePointClearanceAboveOverlay`.
- `testKeyboardRaisedSearchUsesActualOverlayMinY`.
- `testTopmostOfMultipleVisibleOverlaysWins`.
- `testHiddenOverlayDoesNotReserveSpace`.
- `testExistingTopAndSideInsetsArePreserved`.
- `testExistingBaselineBottomInsetIsPreserved`.
- `testAtBottomMovesToNewMaximumOffsetAfterInsetIncrease`.
- `testAtBottomMovesToNewMaximumOffsetAfterInsetDecrease`.
- `testAwayFromBottomKeepsContentOffset`.
- `testShortContentOffsetIsClampedToValidRange`.
- `testRepeatedIdenticalUpdateIsIdempotent`.
- `testVerticalIndicatorReceivesSameOverlayContribution`.

Add view-controller integration assertions for each root controller showing that its table uses the shared coordinator rather than writing a literal `60`.

### Implementation requirements

- Separate pure calculations from UIKit application so geometry and offset rules are unit-testable.
- Track only the coordinator's previously applied bottom contribution, allowing unrelated baseline inset changes to compose rather than be overwritten.
- Calculate old min/max offsets before mutation and new min/max offsets after mutation using adjusted insets.
- Treat “at bottom” with a documented small tolerance; do not mistake ordinary overscroll for a reading-position request.
- Apply inset and offset without animation. Avoid repeated table reloads or layout cycles.
- Wire updates through existing `shouldChangeFrame()`/`viewDidLayoutSubviews` paths and explicit search/action state changes. Add the equivalent layout hook to Notifications, which currently lacks one.
- Use converted overlay frames after layout. During keyboard movement, update from `keyboardLayoutGuide`/layout callbacks so the required clearance follows the actual search surface.
- Remove the four duplicated hard-coded bottom-inset implementations after all integrations compile.
- Preserve Last Chats pinned voice-player top inset behavior.

### Acceptance criteria

- [ ] At maximum scroll, the last row's bottom is at least 12 points above the visible lower overlay.
- [ ] A list already at the bottom remains bottom-anchored across search expansion, keyboard movement, action hide/show, rotation, and safe-area changes.
- [ ] A list away from the bottom keeps its reading offset.
- [ ] Empty and short lists never receive an invalid offset.
- [ ] Content and scroll-indicator baseline insets are preserved.
- [ ] All four root-list implementations use the shared policy; no behavior is governed by an unconditional literal 60.

### Required Verification

```bash
plutil -lint xabber.xcodeproj/project.pbxproj
xcodebuild -list -workspace xabber.xcworkspace

tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/RootBottomBarInsetPolicyTests \
  -only-testing:xabberTests/LastChatsPinnedPlayerInsetPolicyTests \
  -only-testing:xabberTests/LastChatsViewControllerBehaviorTests \
  -only-testing:xabberTests/ContactsListAppearanceTests \
  -only-testing:xabberTests/CallsVisualStyleTests \
  -only-testing:xabberTests/NotificationsListAppearanceTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO

git diff --check
tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

### Source commit

```text
fix(bottom-bar): preserve list clearance and offset
```

## Task 04 — Chats, Archive, and Saved Messages Availability

### Purpose

Apply the new lower-action contract to every left-menu route backed by `LastChatsViewController`.

### Owner and files

- Owner: `xabber-ui`; secondary: `xabber-tests`.
- Production:
  - `xabber/controllers/chats/last_chats_list/LastChatsViewController.swift`
  - `xabber/controllers/chats/last_chats_list/LastChatsViewController+Search.swift` only if integration adjustment is necessary.
- Tests: `xabberTests/LastChatsViewControllerBehaviorTests.swift`.

### Pre-Task Tests

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/FloatingBottomBarViewTests \
  -only-testing:xabberTests/BottomSearchHostViewTests \
  -only-testing:xabberTests/RootBottomBarInsetPolicyTests \
  -only-testing:xabberTests/LastChatsViewControllerBehaviorTests \
  -only-testing:xabberTests/LeftMenuSelectionPresentationPolicyTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

### XCTest work first

Add/replace focused tests equivalent to:

- `testZeroUnreadHidesUnreadFilterAndMarkAllWithoutMovingSearch`.
- `testUnreadShowsUnreadFilterAndMarkAll`.
- `testConnectingAccountHidesMarkAllButKeepsUnreadFilter`.
- `testDisconnectedAccountRestoresMarkAllWhenUnreadRemains`.
- `testActiveUnreadFilterResetsToChatsWhenLastUnreadDisappears`.
- `testSearchQueryDoesNotChangeUnreadActionAvailability`.
- `testArchiveRouteIsSearchOnly`.
- `testSavedListRouteIsSearchOnly`.
- `testSavedDirectChatRoutingRemainsUnchanged` in the existing left-menu policy tests if needed.
- `testHiddenChatActionsDoNotMoveCollapsedSearchFrame`.
- `testLastChatRowRemainsAboveSearchAtMaximumOffset`.

Update the existing enabled/disabled assertion so it checks hidden/visible availability. Do not preserve the obsolete expectation that Mark all remains visible while disabled.

### Implementation requirements

- Store/apply one presentation state from the unread count and `hasConnectingEnabledAccounts`; do not make independent calls that can briefly show contradictory actions.
- For `.chats`, show both unread actions only according to the Expected lower-action matrix.
- If `.unread` is active and unread count becomes zero from Realm observation or a Mark all action, switch to `.chats` before hiding the filter; perform at most one required datasource refresh.
- Connecting state hides Mark all because the operation is unavailable, but it does not hide the Unread filter while unread rows still exist.
- `.archived`, `.saved`, or `shouldShowBottomBar == false` remain action-free/search-only.
- Preserve Mark all target selection: unread, non-archived chats for enabled accounts only.
- Preserve search identifiers, unread observer lifecycle, route behavior, title, and Last Chats pinned-player inset.

### Acceptance criteria

- [ ] Zero unread produces a search-only lower surface.
- [ ] Nonzero unread produces Unread + Mark all + Search when account state allows Mark all.
- [ ] Connecting hides only unavailable Mark all.
- [ ] Losing the final unread row cannot leave a hidden `.unread` filter active.
- [ ] Archive and Saved-list remain search-only; direct Saved chat routing is unchanged.
- [ ] Search never changes its collapsed frame when chat actions hide/show.
- [ ] Last row clearance and bottom anchoring satisfy Task 03.

### Required Verification

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/FloatingBottomBarViewTests \
  -only-testing:xabberTests/BottomSearchHostViewTests \
  -only-testing:xabberTests/RootBottomBarInsetPolicyTests \
  -only-testing:xabberTests/LastChatsViewControllerBehaviorTests \
  -only-testing:xabberTests/LeftMenuSelectionPresentationPolicyTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO

git diff --check
tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

### Source commit

```text
fix(chats): hide unavailable bottom actions
```

## Task 05 — Contacts and Groups Filter Availability

### Purpose

Hide the Online filter only when the current unfiltered contact/group scope has no applicable roster rows, while keeping primary and Search slots stationary.

### Owner and files

- Owner: `xabber-ui`; secondary: `xabber-tests`.
- Production:
  - `xabber/controllers/chats/contact_list/ContactsViewController.swift`
  - `xabber/controllers/chats/contact_list/ContactsViewController+Search.swift` only if integration adjustment is necessary.
- Tests: `xabberTests/ContactsListAppearanceTests.swift`.

### Pre-Task Tests

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/FloatingBottomBarViewTests \
  -only-testing:xabberTests/BottomSearchHostViewTests \
  -only-testing:xabberTests/RootBottomBarInsetPolicyTests \
  -only-testing:xabberTests/ContactsListAppearanceTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

### XCTest work first

Use in-memory Realm fixtures or a pure derived-state seam to add coverage equivalent to:

- `testContactsOnlineFilterHiddenWhenCurrentUnfilteredScopeHasNoRosterRows`.
- `testContactsRequestOnlyScopeDoesNotCountAsOnlineFilterData`.
- `testContactsOnlineFilterVisibleWithOfflineOnlyContact`.
- `testContactsOnlineFilterAvailabilityIgnoresSearchQuery`.
- `testContactsOnlineFilterAvailabilityIgnoresCurrentOnlineFilterResult`.
- `testContactsActiveOnlineFilterResetsWhenLastApplicableContactDisappears`.
- `testGroupsOnlineFilterHiddenWhenCurrentUnfilteredScopeHasNoJoinedGroups`.
- `testGroupsInvitationOnlyScopeDoesNotCountAsOnlineFilterData`.
- `testGroupsOnlineFilterVisibleWithOfflineOnlyJoinedGroup`.
- `testGroupsActiveOnlineFilterResetsWhenLastApplicableGroupDisappears`.
- `testCategoryAccountAndCircleScopeDriveFilterableRowCount`.
- `testHidingOnlineFilterDoesNotMovePrimaryOrSearchFrames`.
- `testRegularWidthNavbarActionsRemainUnchanged`.

Include empty, offline-only, request/invitation-only, search-zero-result, and active-filter-loses-data cases. The red test must demonstrate why `currentFeatureHasAnyContent` is too broad.

### Implementation requirements

- Extend the asynchronous derived dataset result with a filterable presence-row count/boolean calculated for the current account/category/circle scope with `showOffline = true` and no search query.
- Contacts filterable rows are actual applicable roster/contact rows, not headers, buttons, incoming/outgoing request rows, or service entries.
- Groups filterable rows are joined group roster rows to which presence filtering applies, not invitations alone.
- Keep the count detached from Realm before returning to the main queue.
- Store it alongside the resolved snapshot and use it in `updateContactsCompactBottomBarState()`.
- If Online is active and the count becomes zero, normalize `showOffline = true` before presenting the hidden filter state. Avoid a recursive/redundant dataset update loop.
- Add Contact/Create Group remain visible only while their existing action remains available; do not alter or expand those flows.
- Compact-only action behavior remains compact-only. Regular navbar actions stay unchanged.

### Acceptance criteria

- [ ] Empty or request/invitation-only scopes hide Online.
- [ ] At least one applicable offline row keeps Online visible because the filter can still meaningfully act on it.
- [ ] Search producing zero visible rows does not hide Online.
- [ ] Selecting Online and filtering all rows out does not make the filter disappear while applicable base rows still exist.
- [ ] Removing the final applicable row resets Online to All before hiding it.
- [ ] Primary and Search positions never move when Online hides/shows.
- [ ] Contacts and Groups both retain existing actions, titles, categories, and regular-width navigation.

### Required Verification

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/FloatingBottomBarViewTests \
  -only-testing:xabberTests/BottomSearchHostViewTests \
  -only-testing:xabberTests/RootBottomBarInsetPolicyTests \
  -only-testing:xabberTests/ContactsListAppearanceTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO

git diff --check
tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

### Source commit

```text
fix(contacts): hide empty presence filters
```

## Task 06 — Calls Missed Filter and Unavailable Start Call Action

### Purpose

Make Calls lower actions reflect unfiltered missed-call availability and remove the permanently disabled Start Call control from presentation.

### Owner and files

- Owner: `xabber-ui`; secondary: `xabber-tests`.
- Production:
  - `xabber/controllers/calls/last_calls/CallsListCoordinator.swift`
  - `xabber/controllers/calls/last_calls/LastCallsViewController.swift`
  - `xabber/controllers/calls/last_calls/LastCallsViewController+Search.swift` only if integration adjustment is necessary.
- Tests: `xabberTests/CallsListCoordinatorTests.swift` (`CallsListCoordinatorTests` and `CallsVisualStyleTests`).

### Pre-Task Tests

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/FloatingBottomBarViewTests \
  -only-testing:xabberTests/BottomSearchHostViewTests \
  -only-testing:xabberTests/RootBottomBarInsetPolicyTests \
  -only-testing:xabberTests/CallsListCoordinatorTests \
  -only-testing:xabberTests/CallsVisualStyleTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

### XCTest work first

Add/replace tests equivalent to:

- `testCountersRemainUnfilteredBySelectedCategoryAndSearch`.
- `testMissedFilterHiddenWhenUnfilteredMissedCountIsZero`.
- `testMissedFilterVisibleWhenMissedCountIsPositiveEvenIfSearchHasNoRows`.
- `testActiveMissedFilterResetsToAllWhenLastMissedCallDisappears`.
- `testNonMissedCallsDoNotKeepMissedFilterVisible`.
- `testStartCallActionIsHiddenWhileItHasNoTarget`.
- `testHiddenCallsActionsDoNotMoveSearchFrame`.
- `testCallsCollapsedSearchPassesTouchesThroughHiddenActionSlots`.
- `testCallsRegularWidthNavbarAndCategoryControllerRemainUnchanged`.
- `testCallsLastRowRemainsAboveBottomSearchAtMaximumOffset`.

Update obsolete tests that expect a visible disabled Start Call button. Preserve the title/identifier configuration only if it remains useful for a future available state; it must not be accessible while hidden.

### Implementation requirements

- Retain the latest `CallsListCoordinator.DerivedState.counters` in the controller or pass a detached availability state directly to the bar update.
- Determine Missed availability from `counters.missed > 0`, computed before current filter and local search.
- If the internal Missed filter is active and `missed` becomes zero, normalize to All and apply the correct datasource without recursive reloads or a visible empty trapped state.
- Hide the Start Call center slot because it has no target and is always disabled today. Do not invent a target or route.
- Search remains in the original right slot whether one or both action slots are hidden.
- Preserve Calls category counts, 50-row list limit, account scoping, local search, regular category controller, and navbar behavior.

### Acceptance criteria

- [ ] Zero missed calls hides Missed even when other call rows exist.
- [ ] Positive missed count shows Missed independently of search/current filter result.
- [ ] Losing the final missed call resets All before Missed hides.
- [ ] Start Call is not visible, hit-testable, or accessible while unavailable.
- [ ] Search remains stationary and fully interactive.
- [ ] Regular-width Calls behavior and coordinator counters do not regress.

### Required Verification

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/FloatingBottomBarViewTests \
  -only-testing:xabberTests/BottomSearchHostViewTests \
  -only-testing:xabberTests/RootBottomBarInsetPolicyTests \
  -only-testing:xabberTests/CallsListCoordinatorTests \
  -only-testing:xabberTests/CallsVisualStyleTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO

git diff --check
tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

### Source commit

```text
fix(calls): hide unavailable bottom actions
```

## Task 07 — Notifications Unread Filter and Read All Availability

### Purpose

Hide both unread-specific lower actions whenever no unread notification remains in the current category/account scope.

### Owner and files

- Owner: `xabber-ui`; secondary: `xabber-tests`.
- Production: `xabber/controllers/notifications/NotificationsListViewController.swift`.
- Tests: `xabberTests/NotificationsListAppearanceTests.swift`.

### Pre-Task Tests

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/FloatingBottomBarViewTests \
  -only-testing:xabberTests/BottomSearchHostViewTests \
  -only-testing:xabberTests/RootBottomBarInsetPolicyTests \
  -only-testing:xabberTests/NotificationsListAppearanceTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

### XCTest work first

Use existing in-memory Realm helpers to add/replace tests equivalent to:

- `testZeroMatchingUnreadHidesUnreadFilterAndReadAll`.
- `testMatchingUnreadShowsUnreadFilterAndReadAll`.
- `testReadNotificationInAnotherCategoryDoesNotAffectCurrentAvailability`.
- `testUnreadNotificationInAnotherAccountDoesNotAffectPinnedAccountScope`.
- `testLocalSearchDoesNotChangeUnreadActionAvailability`.
- `testActiveUnreadFilterResetsWhenLastMatchingUnreadBecomesRead`.
- `testReadAllHidesBothActionsAfterMatchingRowsAreMarkedRead`.
- `testMarkAllStillTargetsOnlyCurrentCategoryAndAccountScope`.
- `testHiddenNotificationActionsDoNotMoveSearchFrame`.
- `testRegularWidthNavbarReadAllAndFiltersRemainUnchanged`.
- `testNotificationsLastRowRemainsAboveBottomSearchAtMaximumOffset`.

Update the obsolete expectation that Read all remains visible but disabled at zero. Verify both `isHidden` and accessibility/hit-testing behavior.

### Implementation requirements

- Evaluate `matchingUnreadNotificationCount()` once per state update and apply one coherent lower-bar presentation.
- The count continues to use enabled owner, current category, and current account scope. It must ignore the local search query and `unreadOnly` itself.
- If `unreadOnly` is active and the count reaches zero, accept `false` before hiding actions. Guard against a reactive/reload loop and duplicate Realm reads.
- At count zero, hide both Unread and Read all. At count greater than zero, show both and keep Read all enabled.
- Preserve `markMatchingUnreadNotificationsRead()` scoping and the regular-width navbar behavior.
- Preserve local search and notification snapshot scheduling.

### Acceptance criteria

- [ ] No matching unread produces a search-only compact lower surface.
- [ ] Matching unread produces Unread + Read all + Search.
- [ ] Category/account scoping is exact and search-independent.
- [ ] Reading the final matching item resets `unreadOnly` before both actions hide.
- [ ] Read all never appears visible-disabled in the compact lower bar.
- [ ] Search frame, regular navbar, and mark-read targeting do not regress.

### Required Verification

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/FloatingBottomBarViewTests \
  -only-testing:xabberTests/BottomSearchHostViewTests \
  -only-testing:xabberTests/RootBottomBarInsetPolicyTests \
  -only-testing:xabberTests/NotificationsListAppearanceTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO

git diff --check
tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

### Source commit

```text
fix(notifications): hide empty unread actions
```

## Task 08 — Cross-Root Regression Matrix, Accessibility, Runtime QA, and Documentation

### Purpose

Prove the seven routed root scenarios behave consistently, remove transitional APIs, and record the final durable contract.

### Owner and files

- Owner: `xabber-ui`; secondary: `xabber-tests`; coordination: `xabber-lead`.
- Preferred new test: `xabberTests/RootBottomBarIntegrationTests.swift`.
- Existing affected tests as needed:
  - `xabberTests/FloatingBottomBarViewTests.swift`
  - `xabberTests/LastChatsViewControllerBehaviorTests.swift`
  - `xabberTests/ContactsListAppearanceTests.swift`
  - `xabberTests/CallsListCoordinatorTests.swift`
  - `xabberTests/NotificationsListAppearanceTests.swift`
  - `xabberTests/LeftMenuSelectionPresentationPolicyTests.swift`
- Production only for integration defects exposed by the new tests; do not start unrelated cleanup.
- Project: `xabber.xcodeproj/project.pbxproj` for the new test.
- Vault durable docs after source verification:
  - `projects/xabber/docs/features/calls.md`
  - `projects/xabber/docs/features/notifications.md`
  - a new or existing root-list UI contract doc if needed
  - owner/tests notes and the standalone task/handoff when they can be updated without staging unrelated dirty changes.

### Pre-Task Tests

Run the complete affected allowlist before adding the final integration test:

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/FloatingBottomBarViewTests \
  -only-testing:xabberTests/BottomSearchHostViewTests \
  -only-testing:xabberTests/RootBottomBarInsetPolicyTests \
  -only-testing:xabberTests/LastChatsViewControllerBehaviorTests \
  -only-testing:xabberTests/ContactsListAppearanceTests \
  -only-testing:xabberTests/CallsListCoordinatorTests \
  -only-testing:xabberTests/CallsVisualStyleTests \
  -only-testing:xabberTests/NotificationsListAppearanceTests \
  -only-testing:xabberTests/LeftMenuSelectionPresentationPolicyTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

### XCTest work first

Add a matrix-level test fixture covering:

- all left-menu root keys resolve to the expected list/search contract, with Settings explicitly excluded;
- Chats zero/nonzero/connecting states;
- Archive and Saved-list search-only states;
- Contacts and Groups zero/nonzero applicable data;
- Calls zero/nonzero missed count with Start Call hidden;
- Notifications zero/nonzero scoped unread;
- stable frames of remaining controls for every left/center visibility combination;
- hidden controls absent from accessibility and hit testing;
- collapsed/expanded/rapidly reversed Search final states;
- compact and regular trait transitions, preserving regular navbar behavior;
- list clearance at bottom and unchanged offset away from bottom;
- material fallback configuration and native-glass configuration without duplicating private implementation details.

Add a source assertion/test or remove the transitional API so no root controller can still present a visible disabled action through the old `setCenterButtonEnabled(false)` path.

### Implementation and cleanup requirements

- Fix only integration defects demonstrated by the new matrix.
- Remove unused transitional disabled-visible APIs/calls after all roots use the shared availability state.
- Preserve every established accessibility identifier:
  - `bottom_search_button`
  - `bottom_search_text_field`
  - `bottom_search_cancel_button`
  - `last_chats_filter_button`
  - `last_chats_mark_all_read_button`
  - `contacts_online_filter_button`
  - `contacts_add_contact_bottom_button`
  - `groups_online_filter_button`
  - `groups_create_group_bottom_button`
  - `calls_missed_filter_button`
  - `calls_start_call_bottom_button` when/if the hidden future slot is configured, but never expose it while unavailable
  - `notifications_unread_filter_button`
  - `notifications_read_all_bottom_button`
- Update Calls documentation: compact Start Call is hidden while unavailable; Missed is shown only with scoped missed data.
- Update Notifications documentation: compact Unread and Read all are both hidden at zero matching unread, not visible-disabled.
- Document the shared active-filter normalization and geometry-based inset contract in one durable UI note/doc rather than duplicating it across agents.

### Manual simulator QA

Use the existing non-destructive simulator/app state. Do not erase, reinstall, log out, remove accounts, or delete storage.

For every available root route (Chats, Calls, Notifications, Contacts, Groups, Archive, Saved-list when the product configuration shows it):

1. Open it from the left menu and confirm the expected collapsed controls.
2. Confirm hidden controls leave visible controls in exactly their original positions.
3. Scroll to the final row and confirm it is fully above the lower surface with visible clearance.
4. Move several rows away from the bottom, expand/cancel Search, and confirm reading position does not jump.
5. At the bottom, expand Search and open the keyboard; confirm bottom anchoring and last-row clearance follow the raised field.
6. Repeat Expand → Cancel → Expand rapidly and confirm no snap, duplicate surface, missed tap, or constraint warning.
7. Check VoiceOver focus does not land on hidden actions and Search/Cancel labels remain correct.
8. Check Reduce Motion final states and an accessibility Dynamic Type size for clipping.
9. Exercise compact width. If an existing iPad/regular simulator is available, verify trait transition and unchanged navbar behavior there; do not create or erase a device solely for this check. Trait-level XCTest remains mandatory either way.
10. Record which data-dependent states were observed manually. Automated fixtures are the acceptance authority for states that cannot be reached without mutating live account data.

### Acceptance criteria

- [ ] All seven routed root scenarios and Settings exclusion are covered by the final matrix.
- [ ] No visible disabled lower action remains in any root controller.
- [ ] Remaining controls never shift when a sibling action hides.
- [ ] Search morph, interruption, keyboard movement, hit testing, and Reduce Motion pass component/integration tests.
- [ ] Maximum-scroll clearance and non-bottom offset preservation pass on every table owner.
- [ ] Compact/regular transitions preserve existing top-navigation behavior.
- [ ] The affected allowlist and cached simulator build pass.
- [ ] Manual QA evidence and limitations are recorded.
- [ ] Calls/Notifications durable docs match the new behavior.
- [ ] Vault task contains eight unique source SHAs and is moved to `tasks/done` only after every gate passes.

### Required Verification

```bash
plutil -lint xabber.xcodeproj/project.pbxproj
xcodebuild -list -workspace xabber.xcworkspace

tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  -only-testing:xabberTests/FloatingBottomBarViewTests \
  -only-testing:xabberTests/BottomSearchHostViewTests \
  -only-testing:xabberTests/RootBottomBarInsetPolicyTests \
  -only-testing:xabberTests/RootBottomBarIntegrationTests \
  -only-testing:xabberTests/LastChatsViewControllerBehaviorTests \
  -only-testing:xabberTests/ContactsListAppearanceTests \
  -only-testing:xabberTests/CallsListCoordinatorTests \
  -only-testing:xabberTests/CallsVisualStyleTests \
  -only-testing:xabberTests/NotificationsListAppearanceTests \
  -only-testing:xabberTests/LeftMenuSelectionPresentationPolicyTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO

git diff --check
tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Inspect the build log for compiler/linker errors even when the command's final status is successful. Remove only disposable task logs/result bundles.

### Source commit

```text
test(bottom-bar): cover root section behavior
```

The final source commit must contain real integration tests and/or narrowly proven cleanup; never create an empty “final” commit.

## Execution Log Template

Maintain the log in the standalone vault task, not by rewriting completed source commits:

| Task | Source HEAD before | Pre-task tests | TDD red | Post-task tests | Build | Manual | Source SHA | Vault SHA | Risks/notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 01 |  |  |  |  |  | n/a |  |  |  |
| 02 |  |  |  |  |  |  |  |  |  |
| 03 |  |  |  |  |  |  |  |  |  |
| 04 |  |  |  |  |  |  |  |  |  |
| 05 |  |  |  |  |  |  |  |  |  |
| 06 |  |  |  |  |  |  |  |  |  |
| 07 |  |  |  |  |  |  |  |  |  |
| 08 |  |  |  |  |  |  |  |  |  |

For every row, record exact `-only-testing` selectors, selected simulator/OS, selected-test count, failure count, first meaningful error if any, build result, and full 40-character commit SHA.

## Known Risks and Guardrails

- The source worktree was clean at planning time, but its ignored CocoaPods workspace/dependencies were absent. Preflight must install them in this worktree rather than building a different worktree.
- The vault contained many unrelated modified/untracked files at planning time. Stage only this goal's standalone note/handoff and explicitly reviewed durable-doc hunks; never commit the whole vault status.
- Existing vault docs describe Calls Start Call as visible-disabled and Notifications Read all as disabled at zero. The new user requirement supersedes those statements; update them only after implementation is verified.
- Realm/Rx callbacks can cause re-entrant state updates. Normalize an invalid active filter once, guard repeated accepts/reloads, and apply one coherent presentation on the main thread.
- Contacts/Groups requests and invitations are content but not Online-filterable content. Do not reuse the broad empty-state boolean.
- Search animation and keyboard movement use different UIKit systems. Tests need deterministic animator seams; manual QA remains required for perceived smoothness.
- The current deployment target is iOS 15 while current simulator evidence may be iOS 26. Preserve both material fallback and native glass paths.
- A fixed inset may look correct on one phone but fail with keyboard/safe-area/regular layouts. Acceptance is geometry based, not snapshotting the number 60.

## Final Done Definition

The goal is complete only when all conditions below are true:

1. Tasks 01–08 ran in order and each has pre-task baseline evidence recorded before its edits.
2. Every behavior task has tests-first red evidence and green focused coverage.
3. Each task has exactly one non-empty, focused source commit; all eight full SHAs are unique and recorded.
4. Every task's required cached simulator build passed, or the goal remains open/blocked with the first meaningful build blocker recorded.
5. The final affected allowlist passes with both hosted-test isolation flags and both safety test classes.
6. All root-section action states match the Expected lower-action matrix.
7. Search morph and list clearance pass automated tests plus recorded non-destructive simulator QA.
8. Regular-width navbar behavior, left-menu routing, XMPP/persistence, and unrelated UI remain unchanged.
9. Calls/Notifications durable docs describe hidden unavailable actions correctly.
10. The standalone vault task is moved from `tasks/in-progress` to `tasks/done`, the UI-to-tests handoff is closed, and unrelated vault changes remain untouched.
