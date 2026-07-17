# Post-Merge Chat Regression Repair Goal Plan

created:: 2026-07-17
owner:: xabber-lead
primary-implementation-owner:: xabber-ui
secondary:: xabber-tests, xabber-xmpp
core-repo:: `/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core`
core-branch:: `bugfixes/prod`
merge-baseline:: `0b6b3e54f8ef45bbf2f9b3e262df492dfcf15787`
pre-merge-performance-baseline:: `8e56a466c0217764cf2f76c950eb45b5f79c000f`
status:: ready-for-goal-mode

## Goal Mode Prompt

Скопировать весь блок ниже в автоматический Goal Mode. План должен выполняться целиком и строго по порядку.

```text
Выполни полностью план из docs/goal-plans/post-merge-chat-regression-repair-goal-plan.md.

Цель:
устранить регрессии после merge-коммита 0b6b3e54 на ветке bugfixes/prod, сделать исправление Info.plist воспроизводимым из отслеживаемых источников и вернуть все обязательные post-merge gates в зелёное состояние.

Работай автономно до выполнения Definition of Done, но не расширяй область изменений за пределы плана.

Обязательный порядок:
1. PMR-01 — tracked orientation contract в core.
2. PMR-02 — authoritative orientation source в white-label resource repository.
3. PMR-03 — loaded search anchor должен выигрывать у stale blocking context.
4. PMR-04 — pending search navigation не должна отображаться как committed result.
5. PMR-05 — полный integration/performance gate, отчёт и закрытие.

Правила выполнения каждой задачи:
- До любых изменений выполни все команды из раздела «Pre-task tests» этой задачи.
- Сначала запиши HEAD, git status и исход конкретных тестов в Execution Journal.
- Ожидаемые RED из Known-Red Ledger являются доказательством регрессии, а не причиной остановки. Сигнатура падения должна совпасть с планом.
- Любой новый или изменившийся failure, которого нет в Known-Red Ledger, сначала диагностируй до первого meaningful failure. Production-код до локализации не меняй.
- Для code/config changes сначала добавь или ужесточи XCTest, запусти его и зафиксируй RED; только затем меняй production/configuration source.
- Не ослабляй существующие ожидания и не удаляй failing test ради зелёного результата.
- Выполни все acceptance criteria и post-task tests.
- После каждой завершённой задачи создай отдельный focused commit. Следующую задачу не начинай до успешного commit и проверки git show --stat.
- Не создавай пустые commits. Если задача не может завершиться, запиши BLOCKED и не имитируй completion.
- Никогда не используй git add ., git add -A или широкое staging. Stage только allowlist текущей задачи.
- Не amend/rebase/squash уже завершённые task-коммиты в ходе goal.
- Не push и не создавай PR: это не входит в этот goal.

Защита пользовательских изменений в core worktree:
- Сохрани без изменения и никогда не stage:
  - xabber-push-extension/NotificationService.swift
  - xabber.xcodeproj/xcshareddata/xcschemes/PushNotificationsDevice.xcscheme
  - xabber/xmpp/push_notifications/APNS/APNSManager.swift
- Перед PMR-01 сними их content-safe baseline через git diff --stat и sha256; после каждой задачи докажи, что hashes не изменились.
- Не revert, checkout, restore или stash эти файлы.
- Локальный xabber/Info.plist уже исправлен, но игнорируется Git. Не делай git add -f и не считай этот локальный файл durable fix.

Среда тестирования:
- Core repo: /Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core
- Dedicated Simulator: Xabber Chat Performance iPhone 16 Pro
- Simulator UDID: 8D504C92-1B59-4F9B-8B35-A63E2111FBBB
- Для hosted XCTest всегда установи:
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1
- Для deterministic-ui и release-performance обе hosted-переменные должны быть unset.
- Используй task-specific cache roots из плана и tools/xcodebuild_cached.sh.
- Не выполняй clean и не сбрасывай кэш, если не доказана его порча.
- Не запускай live-account QA, не логинь аккаунт, не трогай fixed-live Simulator и физические устройства без нового явного разрешения владельца.
- Не сохраняй в отчёты credentials, JID, message bodies, реальные IDs, URL или tokens.

Границы реализации:
- Исправляй только подтверждённые merge seams.
- Не переписывай chat anchor/search state machines целиком.
- Не меняй MAM stanza shape, persistence, push routing или performance budgets.
- Не добавляй зависимости.
- Сохрани bounded resident timeline, targeted diffs, один layout/offset на transaction и нулевые delayed corrections.

Политика блокеров:
- Обычный RED, compiler error в изменяемом коде или необходимость локальной диагностики не являются блокером — исправляй и продолжай.
- PMR-02 может стать BLOCKED только если authoritative resource repository/branch недоступен после безопасной проверки доступа или невозможно однозначно доказать source path. В этом случае весь goal не может быть COMPLETE.
- Live account и hardware gates имеют статус NOT_RUN/EXCLUDED, а не BLOCKED.
- Заверши goal только когда все пять task-коммитов существуют, core gates зелёные, resource source исправлен отдельным commit и Definition of Done выполнен.

В финальном отчёте укажи:
- commit hash каждой задачи и repository path;
- точные test/build commands и результаты;
- итоговые counts G20, notification/gap, deterministic UI и Release budgets;
- подтверждение сохранности трёх пользовательских файлов;
- список обновлённых vault/docs notes;
- всё, что осталось NOT_RUN или EXCLUDED.
```

## 1. Scope And Intended Outcome

После merge `8e56a466` в prod-линию source integrity и performance architecture сохранились, но общий Simulator verdict остался красным из-за двух воспроизводимых search/anchor regressions. Дополнительно выяснилось, что исправленная orientation-конфигурация существует только в игнорируемом локальном `xabber/Info.plist` и потому снова потеряется при подготовке нового white-label workspace.

План закрывает ровно три результата:

1. iPhone orientation policy становится отслеживаемой и воспроизводимой из authoritative white-label resources.
2. Уже загруженный точный search anchor больше не блокируется stale context-prefetch state.
3. Pending/loading search target не публикуется в lower panel как committed result до фактического positioning completion.

Вне scope:

- новые chat/search features;
- изменение server MAM semantics или stanza shape;
- рефакторинг всей anchor/search architecture;
- push behavior changes;
- live-account validation;
- физическое устройство, hardware frame/hitch/network gates;
- unrelated warnings и три существующих пользовательских push-изменения.

## 2. Confirmed Starting Evidence

### 2.1 Git And Merge State

| Item | Confirmed value |
| --- | --- |
| Core branch | `bugfixes/prod` |
| Merge HEAD at audit | `0b6b3e54f8ef45bbf2f9b3e262df492dfcf15787` |
| Performance parent | `8e56a466c0217764cf2f76c950eb45b5f79c000f` |
| Prod parent | `d6affcdb` |
| Source merge integrity | PASS |
| G20 unique selectors | 96 current / 96 baseline |
| G20 focused matrix | 1,256 current / 1,251 baseline |
| Smoke matrix | 234 current / 234 baseline |

The goal-plan documentation commit may be above `0b6b3e54`; `0b6b3e54` remains the merge baseline, not an instruction to reset HEAD.

### 2.2 Protected Existing Worktree Changes

These changes predate this repair and belong to the owner:

- `xabber-push-extension/NotificationService.swift`
- `xabber.xcodeproj/xcshareddata/xcschemes/PushNotificationsDevice.xcscheme`
- `xabber/xmpp/push_notifications/APNS/APNSManager.swift`

They are not part of any task allowlist. The executor must preserve their initial content exactly.

### 2.3 Test Baseline After Local Info.plist Alignment

| Gate | Baseline |
| --- | --- |
| G20 preflight/focused | 1,254/1,256 passed; 2 failing tests, 4 assertions |
| G20 smoke | 233/234 passed; stale loaded-anchor failure |
| Notification/history-gap slice | 193/195 passed; same two tests, 4 assertions |
| Orientation unit selector | 1/1 PASS, but it reads ignored local plist |
| Deterministic UI | 5/5 PASS after local plist alignment |
| Debug Simulator build | PASS |
| Release performance | PASS |

### 2.4 Performance Budgets That Must Not Regress

For both logical histories, 100 and 1,000,000 messages:

- resident messages: exactly 80 in the measured scenario, hard cap 360;
- 20 measured cycles;
- zero full-history enumerations;
- exact operation vector: 42 datasource applies, 42 inserts, 42 deletes, 0 moves, 0 reloads;
- no more than one forced layout and one programmatic offset per transaction;
- zero delayed corrections;
- anchor drift no more than 1 point;
- warm RSS growth no more than 10%; audited values were 0.0665% and 0.1537%;
- optimistic local row below 100 ms; audited values were 9.735 ms and 7.429 ms;
- media counters exactly one download, one decode, one visible cache hit;
- teardown leaves no active resources.

## 3. Known-Red Ledger

Only these RED states are accepted before their owner task:

| ID | Selector/static contract | Expected failure before | Owner task | Required green after |
| --- | --- | --- | --- | --- |
| ORIENT-TEMPLATE | tracked `xabber/Info.plist.example` has generic `UIInterfaceOrientationLandscape` and only 2 iPhone entries | PMR-01 | PMR-01 | exact Portrait/Left/Right set; generic Landscape absent |
| LOADED-ANCHOR | `ChatMessageAnchorPolicyTests/testLoadedSearchRequestIgnoresStaleBlockingContextState` | PMR-03 | PMR-03 | hooks `started`, `positioned`; pending/active nil |
| SEARCH-PANEL | `ChatSearchArchiveGapRepairTests/testSearchResultFailureKeepsResultsAndDrainsPendingIntent` | PMR-04 | PMR-04 | panel `current = -1` while target 2 is uncommitted |

Rules:

- Exact signature must be recorded, not merely the non-zero process exit.
- A known RED that unexpectedly passes before its task requires investigation: the working tree or starting commit may have changed.
- Any selector outside this table must remain green throughout.
- Delete an entry from the execution journal only by marking it RESOLVED with its task commit; never hide it with `-skip-testing`.

## 4. Common Execution Protocol

### 4.1 Before Every Task

From the core repository unless the task explicitly says otherwise:

```bash
git branch --show-current
git rev-parse HEAD
git status --short --branch
git diff --check
git diff --stat -- \
  xabber-push-extension/NotificationService.swift \
  xabber.xcodeproj/xcshareddata/xcschemes/PushNotificationsDevice.xcscheme \
  xabber/xmpp/push_notifications/APNS/APNSManager.swift
shasum -a 256 \
  xabber-push-extension/NotificationService.swift \
  xabber.xcodeproj/xcshareddata/xcschemes/PushNotificationsDevice.xcscheme \
  xabber/xmpp/push_notifications/APNS/APNSManager.swift
```

Required assertions:

- branch is `bugfixes/prod`;
- only the three protected tracked files may already be modified before task-owned edits;
- their hashes equal the initial PMR-01 baseline;
- no prior task left unstaged or staged task-owned residue;
- no merge conflict markers exist in tracked task files.

### 4.2 Hosted XCTest Environment

Every hosted XCTest command uses:

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='<task-specific-cache-root>' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  <selectors>
```

Use the exact cache root stated by each task. Do not prepend `clean` and do not call `clean-cache` during routine work.

### 4.3 Test-First Rule

For each code/config task:

1. Run unchanged baseline tests.
2. Add or tighten the narrowest regression XCTest.
3. Run it before production/config changes and preserve the expected RED signature.
4. Make the smallest production/config change that satisfies the new test.
5. Run focused tests, adjacent contracts, build and any task-specific gate.
6. Inspect the first meaningful failure before making any additional change.

Tests should use Arrange–Act–Assert and cover happy, edge, failure/cancellation semantics relevant to the seam. Async tests must wait for the actual state transition and must not use arbitrary long sleeps.

### 4.4 Commit Protocol After Every Task

Each task has a strict allowlist. Then run:

```bash
git diff --check -- <task-allowlist>
git diff -- <task-allowlist>
git add -- <task-allowlist>
git diff --cached --check
git diff --cached --name-only
git diff --cached
git commit -m '<task commit subject>'
git show --stat --oneline --decorate HEAD
git status --short --branch
```

Acceptance rules:

- staged names exactly equal the task allowlist subset actually changed;
- no protected user file is staged;
- no ignored `xabber/Info.plist` is force-added;
- commit succeeds and has a non-empty diff;
- after commit, only the original protected changes may remain in core status;
- task commit hash and tests are added to the Execution Journal before continuing.

## 5. Ordered Implementation Tasks

## PMR-01 — Make The Core Orientation Contract Tracked

### Goal

Turn the locally corrected orientation policy into a tracked, reviewable core contract. A clean clone must be able to detect a stale white-label plist before runtime UI testing.

### Why This Is A Regression Risk

- `.gitignore` ignores `xabber/Info.plist`.
- The project build uses `INFOPLIST_FILE = xabber/Info.plist`.
- The existing orientation test reads only that ignored runtime file.
- The local runtime file now has Portrait, LandscapeLeft and LandscapeRight, so the test is green locally.
- The tracked `xabber/Info.plist.example` still has Portrait plus generic `UIInterfaceOrientationLandscape`.
- Therefore the current green result is machine-local and cannot survive a fresh workspace assembly.

### Dependencies

None. This is the first task.

### Files In Scope

- `xabber/Info.plist.example`
- `xabberTests/ChatFinalIntegrationGateTests.swift`

### Do Not Change

- ignored `xabber/Info.plist` except read-only validation;
- `UISupportedInterfaceOrientations~ipad`;
- `MessagesViewController.shouldAutorotate` unless a new test disproves the audited behavior;
- project build settings;
- white-label resource repository; that is PMR-02.

### Pre-Task Tests

Cache root:

`/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr01`

Run the Common Execution Protocol, then:

```bash
git check-ignore -v xabber/Info.plist
git ls-files --error-unmatch xabber/Info.plist.example
plutil -lint xabber/Info.plist
plutil -lint xabber/Info.plist.example
plutil -extract UISupportedInterfaceOrientations raw -o - xabber/Info.plist
plutil -extract UISupportedInterfaceOrientations raw -o - xabber/Info.plist.example

env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr01' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/ChatFinalIntegrationGateTests/testChatSupportsPortraitAndBothLandscapeOrientations
```

Expected baseline:

- runtime plist count is 3 and existing runtime selector passes;
- tracked template count is 2;
- tracked template contains generic `UIInterfaceOrientationLandscape` and lacks explicit left/right entries;
- this mismatch is ORIENT-TEMPLATE known RED.

If the template is already correct, stop and determine which commit changed it; do not create a redundant edit or empty commit.

### Tests First / Expected RED

1. Keep `testChatSupportsPortraitAndBothLandscapeOrientations()` as the runtime/build-input contract.
2. Add a separate test named `testTrackedInfoPlistTemplateDeclaresPortraitAndBothLandscapeOrientations()`.
3. Extract one test helper that reads the iPhone array and asserts the exact set:
   - `UIInterfaceOrientationPortrait`
   - `UIInterfaceOrientationLandscapeLeft`
   - `UIInterfaceOrientationLandscapeRight`
4. Explicitly reject:
   - generic `UIInterfaceOrientationLandscape`;
   - `UIInterfaceOrientationPortraitUpsideDown` for iPhone;
   - duplicates and extra values.
5. Do not apply this exact iPhone assertion to the separate iPad array.
6. Run the whole class before editing the template:

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr01' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/ChatFinalIntegrationGateTests
```

Expected RED: only the new tracked-template test fails, reporting the generic/two-entry iPhone orientation set. The existing runtime test remains green.

### Implementation

1. In `xabber/Info.plist.example`, replace the generic iPhone Landscape entry with explicit `LandscapeLeft` and `LandscapeRight`.
2. Keep Portrait.
3. Preserve the iPad array byte-for-byte except unavoidable plist formatting; preferably do not reformat the file.
4. Re-run `plutil -lint` immediately.
5. Confirm the tracked template and local runtime plist now expose the same exact iPhone orientation set.
6. Do not force-add the ignored runtime plist.

### Acceptance Criteria

- [ ] A clean checkout has a tracked testable iPhone orientation policy.
- [ ] `Info.plist.example` contains exactly Portrait, LandscapeLeft and LandscapeRight for iPhone.
- [ ] Generic Landscape and PortraitUpsideDown are absent from the iPhone array.
- [ ] The iPad orientation array is unchanged.
- [ ] Runtime plist is still validated separately.
- [ ] Controller source still allows autorotation.
- [ ] The new test is demonstrated RED before the template edit and GREEN after it.
- [ ] Full deterministic UI is 5/5, including portrait → left → right → portrait with no anchor drift.
- [ ] Debug Simulator build succeeds without compiler or linker errors.
- [ ] Ignored `xabber/Info.plist` is not in the index or commit.

### Required Post-Task Tests

```bash
plutil -lint xabber/Info.plist
plutil -lint xabber/Info.plist.example

env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr01' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/ChatFinalIntegrationGateTests

env \
  -u TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT \
  -u TEST_RUNNER_XABBER_ISOLATED_STORAGE \
  -u XABBER_CHAT_LIVE_QA_MODE \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr01' \
  tools/run_chat_goal_tests.sh deterministic-ui G20

env \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr01' \
  tools/run_chat_goal_tests.sh build G20

git diff --check -- \
  xabber/Info.plist.example \
  xabberTests/ChatFinalIntegrationGateTests.swift
```

### Commit

Allowlist:

```text
xabber/Info.plist.example
xabberTests/ChatFinalIntegrationGateTests.swift
```

Commit subject:

```text
fix(config): track chat orientation contract
```

### Blocker Policy

- A deterministic UI failure outside rotation is unexpected and must be diagnosed.
- If local runtime plist is no longer exact, repair it only with explicit confirmation that it is the intended local build input; never force-add it.
- PMR-01 is not the authoritative product-resource fix by itself. Continue to PMR-02.

## PMR-02 — Fix The Authoritative White-Label Resource

### Goal

Make the source copied by `prepare_workspace.sh` produce the same exact iPhone orientation set, so a freshly assembled workspace cannot reintroduce the regression.

### Why This Requires A Separate Repository And Commit

`/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/prepare_workspace.sh`:

1. clones `git@github.com:redsolution/xabber_ios_whitelabel_res.git`;
2. checks out the requested white-label branch;
3. copies that repository over `xabber_ios_core/xabber/`;
4. removes the resource clone.

Therefore `xabber/Info.plist.example` protects the core contract, but the authoritative production `Info.plist` comes from a different repository. Both commits are required.

### Dependencies

- PMR-01 committed and green.

### Repositories And Files In Scope

- Core repository: read-only tests and validation only.
- Resource repository: `git@github.com:redsolution/xabber_ios_whitelabel_res.git`.
- White-label branch used for this product; expected candidate is `xabber`, but it must be confirmed from workspace provenance and remote branches.
- Exact resource path which maps to core `xabber/Info.plist` under the copy rule; normally repository-root `Info.plist`.

### Do Not Change

- any other branding, bundle, entitlement, URL, signing or credential fields;
- core source/test files in this task;
- local parent workspace through `prepare_workspace.sh`;
- resource branches for other products;
- secrets or signing material.

### Safety Warning

Do not run the parent `prepare_workspace.sh` in the existing white-label directory. It starts with recursive removal of its `xabber` directory and would destroy the current nested workspace. Use read-only inspection and a separate resource checkout.

### Pre-Task Tests

Run the Common Execution Protocol in core, then prove PMR-01 remains green:

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr02' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/ChatFinalIntegrationGateTests
```

Prepare or inspect a dedicated resource checkout at:

`/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber_ios_whitelabel_res_goal`

Read-only discovery requirements:

```bash
git -C /Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber_ios_whitelabel_res_goal status --short --branch
git -C /Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber_ios_whitelabel_res_goal remote -v
git -C /Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber_ios_whitelabel_res_goal branch --show-current
git -C /Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber_ios_whitelabel_res_goal ls-files | rg '(^|/)Info\.plist$'
```

If the checkout does not exist, clone it without modifying the core repository, then check out the confirmed product branch. Do not log plist values other than orientation keys.

Expected pre-task state:

- resource working tree clean;
- product branch unambiguous;
- authoritative plist parses with `plutil`;
- its iPhone orientation array still contains generic Landscape or otherwise differs from the exact tracked core contract;
- this is the pre-task expected RED.

If the resource already contains the correct exact set, find the introducing commit and verify that the currently used product branch includes it. If so, record PMR-02 as ALREADY-SATISFIED rather than creating an empty commit, but the final goal still requires a durable hash/reference to that resource commit.

### Tests First / Expected RED

Before editing the resource plist:

1. Validate syntax with `plutil -lint`.
2. Extract only `UISupportedInterfaceOrientations`.
3. Assert that the count is 3 and the exact values are Portrait/Left/Right.
4. Assert generic Landscape is absent.
5. Compare the orientation array with core `xabber/Info.plist.example` and local runtime `xabber/Info.plist`.

Expected RED: authoritative resource does not satisfy the exact three-value iPhone contract. No core XCTest may regress.

### Implementation

1. Edit only the authoritative resource plist for the confirmed product branch.
2. Replace generic Landscape with explicit LandscapeLeft and LandscapeRight.
3. Preserve Portrait.
4. Keep the iPad array unchanged.
5. Do not normalize or rewrite unrelated plist keys.
6. Re-run syntax and exact-set validation.
7. Compare only the orientation subtrees against core template/runtime input; do not publish the full resource plist.
8. Confirm through the copy semantics that this file becomes core `xabber/Info.plist` in a newly prepared workspace.
9. Simulate that overlay in a disposable directory created with `mktemp -d`: create its `xabber/` destination, copy the resource repository payload there while excluding `.git`, and validate the resulting `<temporary-root>/xabber/Info.plist`. The resulting orientation subtree must equal the tracked core template.
10. Do not run the destructive assembly script in the current parent checkout.
11. After the core build, inspect only the built app's `UISupportedInterfaceOrientations` and prove it has the same exact set. Locate the built plist under the PMR-02 cache with `rg --files ... | rg '/xabber\.app/Info\.plist$'`; do not dump unrelated built configuration.

### Acceptance Criteria

- [ ] The exact product resource branch is identified and recorded.
- [ ] The exact resource file copied into core `xabber/Info.plist` is identified.
- [ ] Resource iPhone orientations are exactly Portrait, LandscapeLeft and LandscapeRight.
- [ ] Generic Landscape and PortraitUpsideDown are absent from the iPhone array.
- [ ] The iPad array and all unrelated resource keys are unchanged.
- [ ] Core tracked template, local runtime input and authoritative resource agree on the orientation set.
- [ ] A disposable non-destructive resource overlay produces `xabber/Info.plist` with that exact set.
- [ ] The built Simulator app plist contains the same exact iPhone orientation set.
- [ ] PMR-01 core test remains green.
- [ ] Deterministic rotation UI remains green with zero anchor drift.
- [ ] Debug Simulator build remains green.
- [ ] Resource change has its own focused commit in the resource repository.
- [ ] Core repository receives no task-owned diff in PMR-02.

### Required Post-Task Tests

Run resource syntax/exact-set checks, then from core:

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr02' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/ChatFinalIntegrationGateTests

env \
  -u TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT \
  -u TEST_RUNNER_XABBER_ISOLATED_STORAGE \
  -u XABBER_CHAT_LIVE_QA_MODE \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr02' \
  tools/run_chat_goal_tests.sh deterministic-ui G20

env \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr02' \
  tools/run_chat_goal_tests.sh build G20
```

After the build, locate the one relevant built app plist without printing other configuration:

```bash
rg --files \
  /Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr02/DerivedData/Build/Products \
  | rg '/xabber\.app/Info\.plist$'
```

Validate the exact orientation set in that file and in the disposable overlay. If multiple `xabber.app` products are found, select the Debug iPhone Simulator product explicitly and record why; do not accept an arbitrary first match.

### Commit

Repository: dedicated `xabber_ios_whitelabel_res` checkout.

Allowlist: only the confirmed authoritative product `Info.plist`.

Commit subject:

```text
fix(ios): declare both landscape orientations
```

Record the resource repository absolute path, branch and commit hash in the core Execution Journal. Do not stage or commit anything in core for PMR-02.

### Blocker Policy

- If SSH/network access or the required branch remains unavailable after safe read-only checks, mark PMR-02 BLOCKED and the whole goal incomplete.
- If more than one source plist could map to the runtime file, stop and document the ambiguity; do not guess a brand branch.
- Lack of permission to push is not a blocker because this plan requires a local commit, not push.

## PMR-03 — Let A Loaded Exact Search Anchor Bypass Stale Context State

### Goal

When the exact requested search target is already present in the displayed datasource, position it immediately and finish the transaction even if an old same-request execution state still contains pending context query IDs.

### Confirmed Root Cause

In `ChatViewController+SearchBar.swift`, `queueOpenMessageRequest` currently checks:

```text
same request + non-empty contextPrefetchPendingQueryIds -> early return
```

before it calls `performLoadedOpenMessageRequestIfPossible`. The loaded target therefore never reaches the local fast path. Hooks are not called and pending/execution state remains alive.

The intended precedence is:

1. suppress unsupported request sources;
2. cancel a different active request when superseded;
3. preserve initial-first-frame retarget when the visible datasource is genuinely unavailable;
4. resolve an exact loaded target locally;
5. only then wait on same-request context work when the target is still not loaded.

### Dependencies

- PMR-01 committed.
- PMR-02 committed or explicitly BLOCKED; if BLOCKED, code investigation may continue, but the final goal cannot complete.

### Files In Scope

- `xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift`
- `xabberTests/xabberTests.swift`, limited to `ChatMessageAnchorPolicyTests` and its existing private fixtures.

Using the existing test class is preferred here because its loaded-controller fixture and internal transaction state are already colocated. Do not move unrelated tests out of the large file in this task.

### Do Not Change

- MAM request format or paging semantics;
- context coverage calculation;
- persistence callbacks;
- generic transaction gate implementation;
- first-frame windowing;
- search presentation counter logic; that is PMR-04;
- push routing.

### Pre-Task Tests

Cache root:

`/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr03`

Run Common Execution Protocol, then the exact known RED:

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr03' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/ChatMessageAnchorPolicyTests/testLoadedSearchRequestIgnoresStaleBlockingContextState
```

Required baseline signature:

- `events == []` instead of `['started', 'positioned']`;
- `pendingOpenMessageRequest` remains non-nil;
- `activeAnchorExecutionState` remains non-nil.

Then run adjacent green contracts separately:

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr03' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/ChatMessageAnchorPolicyTests/testLoadedSearchRequestCallsPositioningStartedBeforePositioned \
  -only-testing:xabberTests/ChatMessageAnchorPolicyTests/testPendingSearchResumeOpensWindowAroundPrimaryWhenArchiveConflicts \
  -only-testing:xabberTests/ChatMessageAnchorPolicyTests/testSearchContextPrefetchRunsInBackgroundWhenLocalAnchorExists \
  -only-testing:xabberTests/ChatMessageAnchorPolicyTests/testExplicitRemoteAnchorContextPrefetchStillBlocksWhenLocalAnchorIsMissing
```

All adjacent selectors must pass before production edits.

### Tests First / Expected RED

Before production changes, extend `ChatMessageAnchorPolicyTests` to prove all seam boundaries:

1. Existing loaded/stale test:
   - loaded target matches exact archived/message identity;
   - hooks occur exactly once and in order: `started`, then `positioned`;
   - pending request is nil;
   - active execution state is nil.
2. Add resource cleanup assertions or a focused test:
   - stale context query ownership is removed;
   - timeout work item is cancelled/removed;
   - persistence source is unregistered or late final is rejected through existing aborted-query/transaction-token protection;
   - no new remote fetch is issued.
3. Preserve unloaded behavior:
   - same request with a genuinely missing local target continues waiting for pending context query IDs;
   - no positioning hooks fire prematurely.
4. Preserve supersession:
   - a different request cancels the old transaction before opening the new loaded target;
   - late old completion cannot finish or move the new transaction.
5. Preserve first-frame behavior:
   - an empty/unready displayed datasource still takes bounded first-frame retarget path;
   - it does not falsely claim the target is loaded.

Run the new/strengthened exact tests before production changes. The loaded/stale cases must remain RED with the same early-return cause; adjacent missing-target and first-frame cases must remain GREEN.

### Implementation

1. Make a narrow ordering change in `queueOpenMessageRequest`.
2. Ensure a different active request is still cancelled before adopting a new request.
3. Preserve `shouldRetargetPendingInitialFirstFrame` for a genuinely empty/unready datasource.
4. Give `performLoadedOpenMessageRequestIfPossible(request, hooks:)` priority over the same-request pending-context early return when the exact target is resident.
5. Leave the early wait in place for non-loaded targets.
6. Reuse existing `finishActiveAnchorExecution` and `cleanupAnchorExecutionResources`; do not manually nil only part of the state.
7. Ensure cleanup invalidates old query token/timeout/persistence ownership so a late callback is harmless.
8. Do not start another context MAM fetch for an already loaded exact target.
9. Do not invoke positioning hooks more than once.

### Acceptance Criteria

- [ ] Exact loaded target is positioned despite stale same-request context query IDs.
- [ ] Hooks fire exactly once in strict `started` → `positioned` order.
- [ ] Pending request, active execution state and active hooks are cleared after positioning.
- [ ] Stale query timeout/token/persistence ownership is cleaned safely.
- [ ] A late stale callback cannot affect a finished or newer transaction.
- [ ] Missing local target still waits for genuinely outstanding context work.
- [ ] Different request still supersedes/cancels the prior transaction.
- [ ] Empty initial frame still uses bounded retarget/bootstrap behavior.
- [ ] No extra MAM request, full-history enumeration, reload, layout or delayed correction is introduced.
- [ ] Full `ChatMessageAnchorPolicyTests` passes.
- [ ] G20 smoke passes 234/234.
- [ ] Debug Simulator build passes.

### Required Post-Task Tests

Focused class:

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr03' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/ChatMessageAnchorPolicyTests
```

Smoke and build:

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr03' \
  tools/run_chat_goal_tests.sh smoke G20

env \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr03' \
  tools/run_chat_goal_tests.sh build G20

git diff --check -- \
  xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift \
  xabberTests/xabberTests.swift
```

Do not require G20 focused to be fully green yet: SEARCH-PANEL remains the declared PMR-04 known RED. All failures other than that exact selector are forbidden.

### Commit

Allowlist:

```text
xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift
xabberTests/xabberTests.swift
```

Commit subject:

```text
fix(chat): prefer loaded anchors over stale context
```

### Blocker Policy

- If the loaded target is not actually in the displayed datasource, do not broaden lookup to an unbounded Realm observer; treat it as the missing-target path.
- If the minimal reorder breaks first-frame or missing-target tests, fix precedence explicitly rather than bypassing those contracts.
- Do not silence late callbacks by globally disabling MAM completion handling.

## PMR-04 — Keep Pending Search Navigation Uncommitted In The Panel

### Goal

The lower search results panel must display only a result that has actually completed positioning. A queued, positioning or context-loading target is intent, not committed presentation.

### Confirmed Root Cause

`currentSearchResultIndexForPanel()` first uses `searchPresentationState.committedResultIndex`, then falls back to `searchResultNavigationState.currentIndex`. During pending-intent drain, the async next navigation moves to `.loadingContext(index: 2)`, and this fallback publishes `current = 2` even though result 2 has not been committed.

The required ownership rule is:

```text
panel current index = valid committedResultIndex only; otherwise -1
```

Navigation state still owns intent/loading/button busy state, but never the committed counter.

### Dependencies

- PMR-03 committed and `ChatMessageAnchorPolicyTests` green.

### Files In Scope

- `xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift`
- `xabber/controllers/chats/chat/search/ChatSearchPresentationState.swift` only if a test proves the reducer itself violates the contract; avoid changing it if the controller fallback is the sole cause.
- `xabberTests/xabberTests.swift`, limited to search presentation/navigation/gap-repair tests.

### Do Not Change

- search result ordering or identity rules;
- selected message identity before commit;
- pending intent coalescing;
- context MAM/gap repair requests;
- haptic/accessibility commit feedback timing;
- anchor code fixed in PMR-03;
- server behavior.

### Pre-Task Tests

Cache root:

`/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr04`

Run Common Execution Protocol and prove PMR-03 stays green:

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr04' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/ChatMessageAnchorPolicyTests/testLoadedSearchRequestIgnoresStaleBlockingContextState
```

Run the exact known RED:

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr04' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests/testSearchResultFailureKeepsResultsAndDrainsPendingIntent
```

Required baseline signature:

- queue count remains 3;
- selected identity remains result 0;
- navigation reaches `.loadingContext(index: 2)`;
- actual panel state has `current = 2`;
- expected panel state has `current = -1`.

Then run adjacent green search state tests. They must pass before production edits:

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr04' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/ChatSearchPresentationStateTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests
```

### Tests First / Expected RED

Before production changes, add/strengthen coverage for these states:

1. Pending intent after a previous completion:
   - queue and old selection stay present;
   - next target is loading context;
   - panel shows total and spinner but `current = -1`.
2. Positioning without commit:
   - `.positioning(index: N)` must not expose N as panel current.
3. Loading context without commit:
   - `.loadingContext(index: N)` must not expose N as panel current.
4. Successful commit:
   - after `.resultCommitted(index: N)`, panel current becomes N;
   - selection identity changes at the same commit boundary;
   - loading clears.
5. Invalid/stale committed index:
   - if queue no longer contains the committed index, panel current is -1.
6. Failure/pending drain:
   - results are retained;
   - latest valid pending intent wins;
   - no future-index flash occurs;
   - stale generation cannot commit.
7. Cancel:
   - loading clears and the last truly committed counter is restored only when it is still valid.

Keep Arrange–Act–Assert explicit. Run these tests before production edits; uncommitted-state assertions must be RED for the current fallback, while already committed success remains GREEN.

### Implementation

1. Make `currentSearchResultIndexForPanel()` return only a valid `searchPresentationState.committedResultIndex`.
2. Return `-1` when there is no valid committed result.
3. Remove the fallback to `searchResultNavigationState.currentIndex`.
4. Keep navigation state as the source for busy/loading/buttons, not counter identity.
5. Keep `selectedSearchResultId` unchanged until existing commit callback succeeds.
6. Continue draining the latest pending intent asynchronously; do not discard/coerce it merely to make the panel green.
7. Use `applySearchResultsPanelState`/presentation state as the single panel rendering boundary; do not add a second direct future-index write.
8. Avoid reducer changes unless new tests show an independent reducer bug.

### Acceptance Criteria

- [ ] Pending, positioning and loading-context indexes never appear as current before commit.
- [ ] Panel uses valid committed index only; otherwise current is -1.
- [ ] Result total and loading spinner remain correct while current is -1.
- [ ] Successful positioning commits and displays the target index atomically.
- [ ] Failure keeps existing result data and drains the latest pending intent.
- [ ] Old selection identity does not jump to an unpositioned result.
- [ ] Invalid committed index falls back to -1 safely.
- [ ] Cancel/failure paths do not leave spinner or busy buttons stuck.
- [ ] Accessibility and haptic completion remain tied to real commit.
- [ ] Search presentation, navigation and gap-repair suites pass together.
- [ ] Notification/gap slice passes 195/195 after PMR-03 and PMR-04.
- [ ] Debug Simulator build passes.

### Required Post-Task Tests

Focused search suites:

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr04' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/ChatSearchPresentationStateTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests
```

Exact notification/history-gap slice from the audit:

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr04' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/PushNotificationRoutingTests \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests \
  -only-testing:xabberTests/ChatArchiveBoundaryGapPagingPolicyTests \
  -only-testing:xabberTests/ChatMessageAnchorPolicyTests \
  -only-testing:xabberTests/ChatFirstFrameLocalHistoryRegressionTests \
  -only-testing:xabberTests/ChatBootstrapStateTests \
  -only-testing:xabberTests/ChatOpenMessageRequestHandlingPolicyTests \
  -only-testing:xabberTests/LastChatsSearchProvenanceRouteTests
```

Expected result: 195/195, with all 14 push-routing tests still green.

Build:

```bash
env \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr04' \
  tools/run_chat_goal_tests.sh build G20

git diff --check -- \
  xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift \
  xabber/controllers/chats/chat/search/ChatSearchPresentationState.swift \
  xabberTests/xabberTests.swift
```

### Commit

Default allowlist:

```text
xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift
xabberTests/xabberTests.swift
```

Add `xabber/controllers/chats/chat/search/ChatSearchPresentationState.swift` to staging only if tests proved and implementation required an independent reducer correction. Record why in the journal.

Commit subject:

```text
fix(chat-search): keep pending results uncommitted
```

### Blocker Policy

- Do not “fix” the test by changing expected `-1` to the future target.
- Do not clear the queue or pending intent just to prevent the flash.
- If direct panel writes still expose a future index after removing the fallback, identify and consolidate that exact rendering boundary before expanding reducer scope.

## PMR-05 — Run Full Gates, Publish Evidence, And Close The Repair

### Goal

Prove the combined tree fixes the merge regressions without losing functional, orientation or performance guarantees, then publish a privacy-safe durable report.

### Dependencies

- PMR-01 committed and green.
- PMR-02 resource commit exists and is recorded.
- PMR-03 committed and green.
- PMR-04 committed and green.
- No task-owned uncommitted core changes remain.

### Files In Scope

- new `docs/testing/chat-post-merge-regression-repair.md`;
- `docs/testing/chat-performance-final-gates.md` only for current post-merge evidence/status links;
- vault task, UI/tests/lead notes and original audit follow-up outside the core Git commit.

No production or XCTest change is permitted in PMR-05. If a gate finds a real defect, return to a new test-first implementation task and create another focused code commit before resuming PMR-05.

### Pre-Task Tests

Cache root:

`/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr05`

Run Common Execution Protocol, then the three exact repaired contracts before editing docs:

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr05' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/ChatFinalIntegrationGateTests/testChatSupportsPortraitAndBothLandscapeOrientations \
  -only-testing:xabberTests/ChatFinalIntegrationGateTests/testTrackedInfoPlistTemplateDeclaresPortraitAndBothLandscapeOrientations \
  -only-testing:xabberTests/ChatMessageAnchorPolicyTests/testLoadedSearchRequestIgnoresStaleBlockingContextState \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests/testSearchResultFailureKeepsResultsAndDrainsPendingIntent
```

Required result: all selected tests pass. Any RED means PMR-05 must not edit closure docs.

### Required Post-Task Tests / Full Verification Sequence

Run in this order and retain complete logs outside the repository.

#### 1. G20 Preflight

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr05' \
  tools/run_chat_goal_tests.sh preflight G20
```

Required: 1,256/1,256 or a larger non-shrunk matrix if task tests were added; zero failures. Record exact count.

#### 2. G20 Focused

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr05' \
  tools/run_chat_goal_tests.sh focused G20
```

Required: same complete selector union, zero failures, no selector shrink.

#### 3. G20 Smoke

```bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr05' \
  tools/run_chat_goal_tests.sh smoke G20
```

Required: at least 234/234 plus any deliberately added smoke tests; zero failures.

#### 4. Notification/History-Gap Matrix

Repeat the exact eight-class PMR-04 slice. Required: at least 195/195, all 14 push-routing tests green.

#### 5. Debug Simulator Build

```bash
env \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr05' \
  tools/run_chat_goal_tests.sh build G20
```

Required: `BUILD SUCCEEDED`, zero compiler errors, zero linker errors. Record warnings separately; do not call warnings pass/fail assertions unless they are new and task-related.

#### 6. Deterministic UI

```bash
env \
  -u TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT \
  -u TEST_RUNNER_XABBER_ISOLATED_STORAGE \
  -u XABBER_CHAT_LIVE_QA_MODE \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr05' \
  tools/run_chat_goal_tests.sh deterministic-ui G20
```

Required: 5/5 or larger declared matrix, including exact search routing and both landscape directions; anchor drift no more than 1 point; zero delayed correction.

#### 7. Release Performance

```bash
env \
  -u TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT \
  -u TEST_RUNNER_XABBER_ISOLATED_STORAGE \
  -u XABBER_CHAT_LIVE_QA_MODE \
  XABBER_DESTINATION='platform=iOS Simulator,id=8D504C92-1B59-4F9B-8B35-A63E2111FBBB' \
  XABBER_XCODE_CACHE_ROOT='/Users/igor.boldin/Library/Caches/XabberCodex/xabber-post-merge-regression-pmr05' \
  tools/run_chat_goal_tests.sh release-performance G20
```

Required: every budget in section 2.4 passes. Simulator timing/RSS are reported as Simulator evidence, not hardware claims. Animation Hitches/Network Simulator limitations remain `simulator-unsupported`, not PASS.

#### 8. Source And Privacy Audit

```bash
git diff --check
git status --short --branch
git log --oneline --decorate -8
git show --stat --oneline HEAD
rg -n '^(<<<<<<<|=======|>>>>>>>)' \
  xabber \
  xabberTests \
  tools \
  docs || true
```

Also verify:

- G20 selector union did not shrink;
- resource commit hash is recorded;
- protected user file hashes match PMR-01 baseline;
- reports contain no credentials, JID, message body, real IDs, URL or tokens;
- disposable logs/result bundles are outside the repo;
- no live-account or physical-device action occurred.

### Implementation: Documentation And Vault Updates

Create `docs/testing/chat-post-merge-regression-repair.md` with:

- starting merge/baseline hashes;
- the three root causes;
- core and resource task commit hashes;
- exact final test counts and commands;
- deterministic UI and Release budgets;
- explicit NOT_RUN/EXCLUDED tiers;
- preserved-user-change statement;
- links to the existing final-gates document, without private runtime artifacts.

Update `docs/testing/chat-performance-final-gates.md` only where necessary to point to the new post-merge evidence and state that the two merge regressions are closed. Do not rewrite historical evidence as if it were produced by the new HEAD.

Update the external vault:

- move the repair task note to `tasks/done/`;
- update `agents/lead/notes.md` and task dashboards;
- update `agents/ui/notes.md` with the two UI/anchor seam fixes;
- update `agents/tests/notes.md` with exact regression matrix and counts;
- update `agents/xmpp/notes.md` only to state that MAM transport was unchanged and its gap slice stayed green;
- add a follow-up link to the original 2026-07-17 post-merge audit report.

External vault files are not staged in the core repository commit.

### Acceptance Criteria

- [ ] PMR-01 through PMR-04 commits exist with exact scoped diffs.
- [ ] PMR-02 resource commit exists on the confirmed product branch.
- [ ] Both original failing selectors are green.
- [ ] Orientation contract is tracked and authoritative resource agrees.
- [ ] G20 preflight and focused are fully green with no matrix shrink.
- [ ] G20 smoke is fully green.
- [ ] Notification/history-gap matrix is at least 195/195 and push routing is 14/14.
- [ ] Debug Simulator build succeeds.
- [ ] Deterministic UI is at least 5/5.
- [ ] Release performance satisfies every deterministic budget.
- [ ] No live-account or hardware result is misreported.
- [ ] Three protected user files are byte-identical to initial baseline and uncommitted/un-staged.
- [ ] Source report and vault notes are complete and privacy-safe.
- [ ] No disposable artifacts are added to the repository.

### Commit

Allowlist:

```text
docs/testing/chat-post-merge-regression-repair.md
docs/testing/chat-performance-final-gates.md
```

Stage only files actually changed. Do not include external vault paths.

Commit subject:

```text
docs(chat): close post-merge regression repair
```

### Blocker Policy

- Never publish a PASS report while any required gate is red.
- If a failure requires production/test changes, create a new test-first repair task and separate commit; do not hide code inside the documentation commit.
- PMR-05 cannot complete without the PMR-02 resource commit/reference.

## 6. Dependency And Commit Matrix

| Order | Task | Depends on | Repository | Expected commit |
| ---: | --- | --- | --- | --- |
| 1 | PMR-01 tracked core orientation contract | none | core | `fix(config): track chat orientation contract` |
| 2 | PMR-02 authoritative resource orientation | PMR-01 | `xabber_ios_whitelabel_res` | `fix(ios): declare both landscape orientations` |
| 3 | PMR-03 loaded anchor vs stale context | PMR-01; PMR-02 may be pending but final cannot close | core | `fix(chat): prefer loaded anchors over stale context` |
| 4 | PMR-04 pending search presentation | PMR-03 | core | `fix(chat-search): keep pending results uncommitted` |
| 5 | PMR-05 full verification and docs | PMR-01…PMR-04 | core | `docs(chat): close post-merge regression repair` |

No task may share a commit with another task.

## 7. Execution Journal Template

Fill this section during Goal Mode. Do not predeclare PASS.

### PMR-01

- start HEAD:
- protected file hashes:
- pre-task test results:
- expected RED evidence:
- implementation summary:
- post-task tests/counts:
- build/UI result:
- commit hash:
- residual status:

### PMR-02

- resource repository path:
- confirmed product branch:
- authoritative plist path:
- pre-task exact orientation result:
- post-task exact orientation result:
- core contract/build/UI result:
- resource commit hash:
- core residual status:

### PMR-03

- start HEAD:
- pre-task RED signature:
- adjacent-green baseline:
- test-first additions:
- implementation summary:
- focused/smoke/build results:
- commit hash:
- protected file hash check:

### PMR-04

- start HEAD:
- pre-task RED signature:
- adjacent-green baseline:
- test-first additions:
- implementation summary:
- focused/notification-gap/build results:
- commit hash:
- protected file hash check:

### PMR-05

- start HEAD:
- exact repaired selectors:
- G20 preflight:
- G20 focused:
- G20 smoke:
- notification/history-gap:
- Debug build:
- deterministic UI:
- Release small budgets:
- Release million budgets:
- privacy/source audit:
- docs/vault updates:
- commit hash:
- final protected file hashes:

## 8. Definition Of Done

The goal is complete only when all statements are true:

- Five ordered tasks have been resolved and each completed task has its own focused commit; PMR-02 may reference an already-existing correct resource commit only when this is proven and no empty commit is created.
- Core orientation contract is tracked; authoritative white-label resource and runtime input agree.
- Both confirmed merge-regression selectors pass without weakened expectations.
- Loaded exact search anchor takes the local fast path and safely closes stale transaction resources.
- Pending search navigation remains uncommitted until successful positioning.
- G20 preflight/focused/smoke, notification-gap, Debug build, deterministic UI and Release performance gates pass.
- Performance operation, memory, layout, anchor and media budgets remain within section 2.4.
- No live-account or physical-device work was performed or implied.
- The original three owner changes are unmodified, unstaged and absent from all task commits.
- Core report and vault memory describe actual evidence, hashes, limits and remaining exclusions.
- `git diff --check` is clean for all task-owned files, no conflict markers or temporary artifacts remain, and final core status contains only the original protected changes.
