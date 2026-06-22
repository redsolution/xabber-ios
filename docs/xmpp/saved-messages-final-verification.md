# Saved Messages Final Verification

Date: 2026-06-22

Simulator: iPhone 16e, iOS Simulator 26.0, `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF`

## XCTest

- Focused saved/favorites suite:
  - `FavoritesFeatureTests`
  - `AppLaunchEnvironmentPolicyTests`
  - Result: 64 passed, 0 failed.
  - Test runner env: `TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1`.
- Affected archive/sync/LastChats/search/delete suite:
  - `MessageArchiveRequestClassificationTests`
  - `MessageArchivePagingRequestTests`
  - `MessageArchiveQueryCallbackTests`
  - `ClientSynchronizationManagerTests`
  - `ClientSynchronizationPaginationTests`
  - `LastChatsViewControllerBehaviorTests`
  - `LastChatsSeparatorAppearanceTests`
  - `SavedMessagesEntryPointTests`
  - `MessageDeleteManagerRegressionTests`
  - Result: 205 passed, 0 failed.
  - Test runner env: `TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1`.

`SavedMessagesEntryPointTests.testSavedFilterShowsOnlySavedConversationRows` was updated to seed a discovered favorites service row before asserting saved-filter visibility. This matches the Task 11 contract that cached saved rows remain hidden until service discovery proves the owner/service node.

## Build And Checks

- `git diff --check`: passed.
- `plutil -lint xabber.xcodeproj/project.pbxproj`: passed.
- XcodeBuildMCP `build_run_sim`: passed.
- Build log: `/Users/igor.boldin/Library/Developer/XcodeBuildMCP/workspaces/xabber_ios_core-aa5e3c0a5771/logs/build_run_sim_2026-06-22T08-45-06-517Z_pid4113_2524ab72.log`
- Runtime log: `/Users/igor.boldin/Library/Developer/XcodeBuildMCP/workspaces/xabber_ios_core-aa5e3c0a5771/logs/xabber.ios_2026-06-22T08-45-14-935Z_helperpid96211_ownerpid4113_21e67c2d.log`
- OS log: `/Users/igor.boldin/Library/Developer/XcodeBuildMCP/workspaces/xabber_ios_core-aa5e3c0a5771/logs/xabber.ios_oslog_2026-06-22T08-45-17-295Z_helperpid96260_ownerpid4113_d0e3ab12.log`

## Manual Smoke

- Last Chats launched after final build/run.
- `Saved messages` was visible in the left menu, proving the current account has a discovered favorites service entry.
- `Alexey Boldin` opened from Last Chats; message history and composer were visible.
- Screenshots:
  - `/var/folders/p3/yw9pshw16rg1qc1_20gr7n_80000gn/T/screenshot_optimized_65709556-7e8a-4d76-ae3f-a31c7714b37f.jpg`
  - `/var/folders/p3/yw9pshw16rg1qc1_20gr7n_80000gn/T/screenshot_optimized_1e8f66ef-b8e5-4ef6-b0cf-bedeb5fb9bbb.jpg`

## Manual Smoke Limitations

The UI automation snapshot exposed `Saved messages` as text-only in the left menu, with no actionable tap target. The same limitation was observed in Tasks 10 and 11. Message long-press/tap automation in `Alexey Boldin` did not expose the message action menu, and no coordinate tap helper was available (`cliclick` missing; `simctl io` supports screenshot/video only).

The following final manual checklist items are therefore covered by XCTest rather than direct manual UI automation in this pass:

- open Saved Messages after forwarding;
- forward normal message from `Alexey Boldin` to Saved Messages;
- instant forward behavior;
- direct note in Saved Messages;
- re-forward from Saved Messages back to `Alexey Boldin`;
- saved search context open;
- safe delete/pin checks;
- relaunch/reopen saved history.
