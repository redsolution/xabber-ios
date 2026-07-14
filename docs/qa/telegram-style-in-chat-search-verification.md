# Telegram-style in-chat search verification

## Scope and safety contract

- Repository: `/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core`.
- Latest commit under the required Task 26A repeat: `f166b88ea7973dff062eda2caba23d3b31bd72b0` (`fix(chat-search): center search magnifier vertically`). The original Task 26A evidence commit remains `1c38717c1382f1301ff9a07195ab8cf576098fbc`.
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

## Required Task 26A repeat after strict magnifier centering

- After Task 26B-F3 commit `f166b88ea7973dff062eda2caba23d3b31bd72b0`, the exact 58-suite union passed twice: 715/715 before install-over and 715/715 after it, with 0 failures and 0 skips in both runs.
- Both production cached builds succeeded on the exact iPhone 16e. The product bundle was `xabber.ios`.
- Install-over completed in 1.440 s without uninstall. CoreSimulator rotated the wrapper from `22E02524-3FFE-4DFF-9D34-A11F396AF1B2` to `EE3D98C8-C970-44AE-8831-CD35685C780A`; `Documents/default.realm` retained inode `171969950` and size `19,087,360` bytes.
- The final ordinary launch remained signed in and showed Andrew Nenakhov and Alexey Boldin. Logs contained `authSucceeded` and no revoke/deletion signal. No duplicate Task 26A source commit was created.

## Task 26B live execution evidence

### Preconditions and automated verification

- Hosted pre-task allowlist: the required ten suites passed 124/124 with 0 failures/skips, account autoconnect disabled and isolated storage enabled.
- Non-opt-in UI safety gate: both live cases skipped before `XCUIApplication` construction, 2/2 expected skips. This run did not launch or mutate the main app.
- Signed-in preflight used wrapper `EE3D98C8-C970-44AE-8831-CD35685C780A`; Realm inode `171969950` and size `19,087,360` bytes were intact, and Andrew Nenakhov/Alexey Boldin were visible.
- Guarded live run: 2/2 passed, 0 failures/skips. `testCalendarDateJumpForKnownResult()` took 50.128 s; `testTelegramStyleInChatSearchLiveSmoke()` took 176.493 s. The test bundle used iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF`, Andrew Nenakhov and exact lowercase query `test`.
- The full flow found 261 results, proved 1→2→1 navigation, oldest 261/261 without wrap, keyboard dismissal, newest-first list presentation, list/chat restoration, calendar grid/month picker/X restoration and final chat restoration. The separate Calendar Done case selected the single preselected civil day `chat_search_calendar_day.1.2026.7.14`, then proved search/list/calendar dismissal and safe date anchoring in the same signed-in chat.
- Teardown only terminated the test process. No message was sent, edited or deleted; no login/logout, account removal, uninstall, erase, reset, credential operation, Realm cleanup or container cleanup ran.
- Post-task hosted allowlist passed 89/89 with 0 failures/skips under the same two isolation flags.
- Mandatory cached production build ended with `** BUILD SUCCEEDED **`; no compiler or linker error was reported. The first rejected command only supplied duplicate wrapper arguments and exited before build; the corrected wrapper invocation above is the acceptance build.

### Retained evidence

- Accepted Xabber video: `/Users/igor.boldin/Downloads/Xabber_Search_Parity_2026-07-14_strict-center-goal-qa.mp4`; H.264, 1170×2532, 240.843333 s, 8,762 frames, average rate `2628600/72253`; SHA-256 `6566e4bd15eee3dab90ee7f380d821841cad47bbda49810e092a7328fcf24c91`.
- Accepted copied result bundle: `/Users/igor.boldin/Downloads/Xabber_Search_Parity_2026-07-14_strict-center-goal-qa.xcresult`; XCTest summary reports 2 passed, 0 failed, 0 skipped on the exact simulator. A deterministic hash over its sorted file hashes is `c335b152197b1c646d78488daa7e8c4bebade66fc36d6e16d4ea7e6b33fcef0b`.
- Reference: `/Users/igor.boldin/Downloads/ScreenRecording_07-13-2026 10-51-31_1.MP4`; HEVC, 1170×2532, 19.116667 s, 747 frames, nominal `60000/1001`, average `149400/3827`; SHA-256 `04e9b0d92c5e872cdc5ea59fb2bcc700406c22daf0204e8d721d1ceef6dc918a`.
- Extracted accepted frames are under `/Users/igor.boldin/Downloads/Xabber_Search_Parity_2026-07-14_strict-center-frames`; reference frames are under `/Users/igor.boldin/Downloads/Telegram_Search_Reference_2026-07-13-frames`. PTS, not frame ordinal, is the comparison key because both recordings are variable-frame-rate.
- `/Users/igor.boldin/Downloads/Xabber_Search_Parity_2026-07-14_1610_goal-qa.mp4` and its matching xcresult remain rejected defect evidence only: they contain the superseded `-4 pt` magnifier offset and are not cited as acceptance evidence.

### Side-by-side visual and motion disposition

Absolute screen Y differs because the two apps have different status/navigation chrome. Geometry below is compared in each search surface's local coordinate space; data-dependent dates, result counts and message content are not treated as geometry defects.

| State/contract | Reference PTS/evidence | Xabber PTS/evidence | Reference / actual / delta | Disposition |
| --- | --- | --- | --- | --- |
| Search top surface and newest result | 3.5 s, `pts-3_5.png`, SHA `87846857…` | 110 s, `pts-110.png`, SHA `1f920caa…` | surface 60/60/0 pt; field and X 44/44/0 pt; base inset 16/16/0 pt; gap 8/8/0 pt | pass |
| Magnifier vertical center | 3.5 s, centered inside the reference field | 110 s, full-resolution accepted frame; focused geometry contract `top=0`, `bottom=0`, offset `0 pt` | 0/0/0 pt; 44×44 hit target retained | pass; this is the user-requested strict midpoint |
| Result navigation and oldest boundary | 6.5 s, `pts-6_5.png`, SHA `a43d3090…` | 190 s, `pts-190.png`, SHA `d242f78f…` | arrows 40/40/0 pt; gap 12/12/0 pt; disabled boundary ≈0.5/0.5 | pass; 1→2→1 and 261/261 no-wrap asserted |
| Bottom controls with keyboard | 3.5 s reference | 110 s accepted frame | control height 40/40/0 pt; both remain above keyboard | pass |
| Results list stable | 11.0 s, `pts-11_0.png`, SHA `490c4eeb…` | 125 s newest-first and 195 s scrolled, `pts-195.png`, SHA `d47f7094…` | sender/avatar/snippet/date/status hierarchy matches; row contents/counts are data-dependent | pass |
| List in motion | reference-derived contract and 11.0 s stable frame | shared animation-spec XCTest plus 125 s stable frame | scale 0.95→1.0: 0.40/0.40/0.00 s; blur 30→0: 0.20/0.20/0.00 s | pass; PTS proves endpoints, XCTest proves deterministic duration |
| List out motion | 12.5 s restored chat frame | live chat/list restoration plus shared animation-spec XCTest | scale/blur 0.30/0.30/0.00 s | pass |
| Calendar grid | 14.0 s, `pts-14_0.png`, SHA `93870743…` | 223 s, `pts-223.png`, SHA `26dbc90e…` | leading X, dynamic rows, blank outside-month slots, future-day policy and ≈30 pt Done inset all present | pass; selected day is data/time-dependent |
| Calendar month/year picker | reference calendar header contract | 225 s/230 s, `pts-230.png`, SHA `596e27d…` | month/year picker and Apply/Close hierarchy present; swipe 0.30/0.30/0.00 s | pass |
| Calendar X restoration | 15.5 s, `pts-15_5.png`, SHA `d37feab…` | 235 s, `pts-235.png`, SHA `9f937af5…` | query/current result/list origin preserved; keyboard remains dismissed | pass |
| Calendar Done/date anchor | reference semantics: Done exits search and jumps by selected timestamp | 60 s, `pts-60.png`, SHA `6d463abe…`, plus passed dedicated live case | exactly one civil day selected; Done closes calendar/search/list and uses safe `markReadOnVisible=false` anchor | pass |

The reference visibly uses `Test`, while acceptance intentionally uses exact lowercase `test`; this is a required test-data difference. Reference count 2 versus Xabber count 261 and different message dates/content are archive-data differences. Neither changes navigation semantics, ordering or layout, so both are accepted functional deviations rather than visual defects. Yellow match highlighting remains timeline-only, while list snippets remain plain.

### Accessibility and account disposition

- Static live inspection covered normal iPhone 16e geometry. VoiceOver order, maximum Dynamic Type, RTL, Reduce Motion and Reduce Transparency were not toggled during the signed-in recording, so the recording is not claimed as evidence for those modes.
- `ChatSearchAccessibilityTests` and `ChatSearchAdaptiveLayoutTests` passed in both the 124-test preflight and 89-test postflight. The suites cover semantic order/labels, 44 pt hit targets, RTL mirroring, Dynamic Type growth and reduced-motion/transparency policy. `ChatSearchModeTransitionTests` covers the reduced-motion choreography.
- Final ordinary launch used wrapper `EACCA696-16C1-4CDB-9B1D-C7FAD40F2B54`. Realm retained inode `171969950` and size `19,087,360` bytes; its mtime advanced normally to `2026-07-14T16:42:40+0500` during signed-in runtime activity. The Chats screen still showed Andrew Nenakhov and Alexey Boldin. The account therefore remained present after all tests and the acceptance build.
