# Telegram-style in-chat search verification

## Scope and safety contract

- Repository: `/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core`.
- Commit under the Task 26A gate: `e8e518c499a31b913ac29cf507435061f274dbce` (`fix(chat-search): close lifecycle leaks`).
- Simulator: iPhone 16e, iOS 26.0, UDID `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF`.
- Hosted unit tests use bundle `xabber.ios.codex-hosted-tests`, both isolation flags and explicit `-only-testing` selectors. Broad `xabberTests` execution is prohibited.
- Runtime installation is install-over only. Uninstall, erase, reset, logout, account removal, credential entry/change and Realm/container cleanup are prohibited.
- Runtime QA data remains Andrew Nenakhov first, Alexey Boldin fallback, and exact query `test`. Task 26A performs no chat/search parity flow; that belongs to Task 26B.
- A required test failure stops the gate at its first meaningful failure. Product/test repair requires a separate focused red/green task and a complete Task 26A restart. Required scenarios may not be accepted with `XCTSkip`.

## Deduplicated XCTest contract

The final union contains 58 unique suites. Each selector appears exactly once.

### Safety and baseline

- `AppLaunchEnvironmentPolicyTests`
- `ChatSearchGoalSafetyPolicyTests`
- `AccountMissingCredentialPolicyTests`
- `XMPPAuthenticationFailureTests`
- `AccountStreamLifecycleGateTests`
- `AccountDeletionCleanupTests`
- `AccountDeletionCoordinatorTests`
- `InfoCardChatSearchRoutingTests`
- `InfoCardSearchAccessibilityTests`
- `ChatSearchModeActivationTests`
- `ChatInChatSearchQueryLifecycleTests`
- `ChatSearchResultNavigationStateTests`
- `ChatSearchArchiveGapRepairTests`
- `ChatSearchInputBarViewTests`
- `ChatSearchBottomPanelTests`
- `SearchChatListKeyboardLayoutTests`
- `ChatNavigationBarStateTests`

### Foundation and providers

- `ChatSearchPresentationStateTests`
- `ChatSearchResultPresentationTests`
- `ChatSearchSessionStateTests`
- `ChatSearchMAMPagingTests`
- `ChatSearchLocalProviderTests`
- `ChatSearchAnimationSpecTests`

### UI and results list

- `ChatSearchTopChromeTests`
- `ChatSearchBottomActionBarTests`
- `ChatSearchNavigationButtonsTests`
- `ChatSearchHighlightingTests`
- `ChatSearchResultCellTests`
- `ChatSearchResultsListTests`
- `ChatSearchModeSwitchingTests`
- `ChatSearchListTransitionTests`
- `ChatSearchListSelectionTests`

### Calendar and date navigation

- `ChatSearchCalendarModelTests`
- `ChatSearchCalendarViewTests`
- `ChatSearchCalendarPresentationTests`
- `ChatSearchTimestampLocalResolverTests`
- `ChatSearchTimestampMAMResolverTests`
- `ChatSearchCalendarCompletionTests`

### Quality and automation

- `ChatSearchModeTransitionTests`
- `ChatSearchLocalizationTests`
- `ChatSearchAccessibilityTests`
- `ChatSearchAdaptiveLayoutTests`
- `ChatSearchLiveQASafetyPolicyTests`
- `ChatSearchStressStateTests`
- `ChatSearchPerformanceTests`
- `ChatSearchLifecycleTests`

### Supporting chat regressions

- `ChatHistoryPageCompletionPolicyTests`
- `ChatArchiveCoverageCommitPolicyTests`
- `ChatHistoryPagingPolicyTests`
- `ChatRemoteHistoryApplyPolicyTests`
- `ChatOpenMessageRequestHandlingPolicyTests`
- `ChatMessageAnchorPolicyTests`
- `ChatComposerFrameUpdateTests`
- `ChatDiffKeySignatureTests`
- `ChatDisplayModelCacheTests`
- `ChatReloadInvalidationPolicyTests`
- `ChatDatasourceBoundsTests`
- `ChatFirstFrameLocalHistoryRegressionTests`

The executable command is formed from that ordered array by adding one `-only-testing:xabberTests/<Suite>` argument per suite:

```bash
TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
XABBER_DESTINATION='platform=iOS Simulator,id=7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF' \
tools/xcodebuild_cached.sh test "${ARGS[@]}"
```

## Task 26A preflight and first gate

- Preflight main data container: `B606486A-A544-4C2F-8FB8-BCE763C48DA6`.
- Preflight `Documents/default.realm`: inode `171969950`, size `19,087,360` bytes, mtime `2026-07-14T13:46:55+0500`.
- Unique-suite check: 58 suites, no duplicate names.
- First final union: 715 passed, 0 failed, 0 skipped; test duration 24.147 s and Xcode test-operation duration 37.454 s.
- The passing xcresult summary was inspected for `skippedTests=0`, then the disposable result bundle was removed. DerivedData, SourcePackages and PackageCache were preserved.

## Build, install-over and launch evidence

The production build command was:

```bash
XABBER_DESTINATION='platform=iOS Simulator,id=7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF' \
tools/xcodebuild_cached.sh build
```

- Result: `** BUILD SUCCEEDED **`; no compiler or linker error was reported.
- Product: `$HOME/Library/Caches/XabberCodex/xabber-ios-core/DerivedData/Build/Products/Debug-iphonesimulator/xabber.app`.
- `CFBundleIdentifier` was verified as `xabber.ios` before installation.
- Install command: `python3 ... timeout=60 ... xcrun simctl install <UDID> <APP_PATH>`; elapsed time 1.878 s.
- No uninstall, erase, reset or storage cleanup command was executed.
- CoreSimulator rotated the data-container wrapper UUID to `2655ACD4-AA2D-4C57-BE0E-BA9E176209E6`, while the existing Realm kept inode `171969950`, size `19,087,360` bytes and mtime `2026-07-14T13:46:55+0500`. This proves the existing data payload was preserved across install-over despite wrapper-path rotation.
- The main app was launched with both hosted flags explicitly unset; launch returned PID 37633 in 0.213 s.
- The signed-in `Chats` shell rendered with Andrew Nenakhov and Alexey Boldin present. Filtered launch logs contained `authSucceeded` and no `Access revoked`, account-deletion or credential-invalidation event.

## Final Task 26A gate

- The exact deduplicated 58-suite union was repeated after documentation and install-over: 715 passed, 0 failed, 0 skipped. XCTest duration was 24.672 s and Xcode test-operation duration was 32.482 s.
- The second xcresult summary explicitly reported `totalTestCount=715`, `passedTests=715`, `failedTests=0` and `skippedTests=0`. The disposable result bundle was then removed while all Codex build/package caches were preserved.
- The cached production build was repeated after the final union and ended with `** BUILD SUCCEEDED **`; no compiler or linker error was reported.
- The exact simulator remained booted and the main data container remained `2655ACD4-AA2D-4C57-BE0E-BA9E176209E6`. `Documents/default.realm` retained inode `171969950` and size `19,087,360` bytes.
- A final bounded ordinary launch with both hosted flags unset rendered the signed-in Chats shell with Andrew Nenakhov and Alexey Boldin. The launch/synchronization legitimately advanced the Realm mtime to `2026-07-14T15:02:52+0500`; identity and size remained stable.
- Filtered logs still contained `authSucceeded` and no `Access revoked`, account-deletion or credential-invalidation event. Task 26A therefore passes its regression, build, install-over, account-preservation and first-failure-policy criteria.
