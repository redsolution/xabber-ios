# Account quit cleanup and crash repair — 2026-10-28

Quit now finishes local cleanup before dismissing account/settings presentation and selecting the next root. The last stored account leads to onboarding; other accounts retain the application root. All local Quit entry points use the checked asynchronous completion and show retryable cleanup failure.

## Confirmed problems and changes

- Background Realm deletion could leave a stale main-thread account count. Refresh before account-presence and last-account PIN decisions.
- Legacy Settings/Account Info paths ignored cleanup results and modal/window ownership. Share checked async cleanup, retain the controller/window until completion and dismiss the whole account/settings stack.
- Cleanup omitted account-owned attachments, history/archive state, profile/avatar/quota, roster, scheduling, abuse and notification rows. Complete the existing categories and finish with an account-owner sweep; preserve other owners/device settings.
- Protected OMEMO deletion errors were swallowed. The account-removal path now throws and cancels the Realm transaction on failure.
- A fresh iPhone crash during cleanup was `RLMVerifyAttached → LastChatsStorageItem.conversationType → mapDataset → preprocessDataset`. Entitlement lookup refreshed cached live Realm after materialization. The mapper now reads one frozen Realm version, including linked message/roster/presence data.

## Source areas

- `xabber/common/account_manager/AccountManager.swift`
- `xabber/controllers/alerts/QuitAccountPresenter.swift`
- `xabber/controllers/settings/SettingsViewController+Flow.swift` and `+InfoScreenHeaderButtonDelegate.swift`
- `xabber/controllers/chats/info_screens/account_info/AccountInfoViewController+InfoScreenHeaderButtonDelegate.swift`
- `xabber/controllers/chats/info_screens/account_info/devices_list/DevicesListViewController.swift` and `+Flow.swift`
- `xabber/application/AppRootCoordinator.swift`, `xabber/common/notify_manager/NotifyManager.swift`
- `xabber/controllers/chats/last_chats_list/LastChatsViewController.swift`, `xabber/xmpp/omemo/OmemoManager.swift`

## Verification

105/105 tests passed, zero failures or skipped cases:

| Suite | Cases |
| --- | ---: |
| AccountDeletionCleanupTests | 12 |
| AccountDeletionCoordinatorTests | 7 |
| QuitAccountFlowStateTests | 12 |
| OMEMO2AccountDeletionBehaviorTests | 3 |
| LastChatsViewControllerBehaviorTests | 71 |

Ran `tools/xcodebuild_cached.sh test` with those five explicit selectors, both `TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1` and `TEST_RUNNER_XABBER_ISOLATED_STORAGE=1`, `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -parallel-testing-enabled NO`, and concrete simulator `91E09D3E-4BBC-4431-9EAF-14D2410E7B98` (iOS26.0). The successful test action built the app and extension dependency graph; compiler/linker output was inspected. `git diff --check` passed. No clean or cache reset.

Initial red tests reproduced residual rows, stale presence and missing scene/modal transition. The snapshot regression reproduces the deletion/live-refresh lifetime from the physical crash. The new build has not been installed or logout repeated on a physical iPhone. Server revocation and APNs delivery were not revalidated. No schema/dependency/signing configuration change.

Vault task, UI/business/test notes, handoffs, behavior contract and sanitized crash evidence were updated. A new KB inbox contribution records the native findings; no curated KB content was modified. Disposable logs/results are removed after recording these results; Xcode caches remain.
