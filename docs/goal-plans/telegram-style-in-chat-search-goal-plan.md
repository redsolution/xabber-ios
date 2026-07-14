# Telegram-style In-Chat Search — Goal Plan

created:: 2026-07-13
status:: ready-for-goal-mode
owner:: xabber-ui
secondary:: xabber-xmpp, xabber-tests
repository:: /Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core
reference-video:: /Users/igor.boldin/Downloads/ScreenRecording_07-13-2026 10-51-31_1.MP4
runtime-device:: iPhone 16e, iOS 26.0, UDID 7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF

## Промпт для автоматического Goal-режима

Скопировать весь блок целиком:

~~~text
Создай и выполни Goal: «Реализовать Telegram-style поиск внутри чата Xabber iOS по плану docs/goal-plans/telegram-style-in-chat-search-goal-plan.md».

Рабочий репозиторий:
/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core

Выполняй задачи строго в таком порядке: Task 00; Task 01–05; Task 05A; Task 06–21; Task 22A–22C; Task 23; Task 25D; Task 25E; Task 24; Task 25A–25C; Task 26A–26C. Это 36 отдельных задач/commit. Task 25D и Task 25E являются аварийными safety-fix, вставленными перед продолжением уже начатого Task 24: первый запрещает ложное удаление аккаунта при локально отсутствующем credential, второй изолирует Keychain hosted XCTest после подтвержденной очистки production service тестовым onboarding. Не объединяй задачи и не переходи к следующей, пока текущая не прошла все свои критерии принятия, focused XCTest, обязательную simulator build и отдельный focused commit. Перед каждой задачей обязательно запускай перечисленные pre-task tests. Для изменения поведения сначала добавляй или обновляй XCTest и, когда текущий код способен проявить дефект, фиксируй ожидаемое red-падение до production-изменения.

После каждой задачи:
1. запусти ее post-task tests;
2. запусти tools/xcodebuild_cached.sh build на указанном iPhone 16e;
3. обнови строку задачи в tracked Execution journal до статуса ready-to-commit и запиши ожидаемый commit subject, но не пытайся записать SHA еще не созданного commit;
4. обнови рабочие vault notes;
5. выполни git diff --check уже после этих documentation edits;
6. добавь в staging только файлы этой задачи;
7. создай ровно один отдельный source-repository commit с указанным message;
8. проверь commit через git show --stat --oneline HEAD;
9. после commit запиши фактический SHA во внешний vault execution ledger, не создавая второго source commit для той же задачи.

Жесткие правила безопасности:
- используй уже запущенный iPhone 16e с UDID 7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF;
- для runtime QA используй диалог Andrew Nenakhov или, если его нет, Alexey Boldin;
- поисковый запрос должен быть ровно test;
- никогда не выполняй simctl erase, simctl uninstall, resetContentAndSettings, удаление контейнера/Realm, logout, remove account, переустановку с предварительным удалением или любой destructive cleanup;
- никогда не удаляй аккаунт и не вводи/не меняй учетные данные;
- hosted unit tests запускай только allowlist-списками с TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 и TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 после Task 00;
- не запускай broad all-tests на account-bearing simulator;
- не запускай live XCUIApplication/manual chat flow до Task 24;
- не выполняй clean и не удаляй Codex DerivedData/SourcePackages/PackageCache;
- не откатывай и не включай в commits чужие локальные изменения.

Продуктовый контракт:
- повтори наблюдаемое Telegram-поведение, геометрию органов управления, список результатов, переходы по результатам, календарь и анимации;
- календарь в референсе — это переход к выбранной дате, а не ограничение текстовой выдачи диапазоном: Done закрывает поиск/list mode и переносит чат к сообщению, найденному по timestamp; X закрывает календарь и сохраняет query/selection;
- regular/group search остается MAM withtext, encrypted search остается локальным;
- все переходы к сообщениям используют безопасный Xabber anchor pipeline и markReadOnVisible=false;
- выполняй независимую UIKit-реализацию наблюдаемого поведения; не копируй исходный код, структуру реализации, ассеты, generated icon paths или брендинг Telegram и не используй private Apple API;
- не добавляй third-party dependencies и не переписывай UIKit flow на SwiftUI.

Не отмечай Goal complete, пока Task 26C не зафиксирует: все focused tests прошли, simulator build прошла, новая сборка установлена поверх существующей без uninstall, сценарий в Andrew Nenakhov/Alexey Boldin с query test записан и сравнен с референсом, аккаунт остался на месте, ложное локальное отсутствие credential не трактуется как подтвержденный server revoke, hosted XCTest не может адресовать production Keychain service, vault task/handoff закрыты, а внешний vault execution ledger содержит отдельный source commit hash для всех 36 задач, включая Task 26C.
~~~

## 1. Цель и границы

Цель — заменить текущий функционально работающий, но визуально иной поиск внутри ChatViewController на UIKit-реализацию с поведенческим и визуальным паритетом референсному Telegram iOS:

- верхняя поисковая строка в отдельной glass-капсуле;
- отдельная круглая кнопка закрытия справа;
- результат непосредственно в timeline с желтой подсветкой совпадений;
- плавающие круглые кнопки перехода к предыдущему/следующему результату справа;
- нижняя левая glass-капсула «календарь + счетчик»;
- нижняя правая glass-капсула Show as List / Show as Chat;
- отдельный список найденных сообщений с аватаром, автором, snippet, датой и delivery state;
- календарный экран с выбором даты и переходом к сообщению;
- совпадающие по характеру, длительности и прерыванию анимации.

Не входит в scope:

- изменение глобального поиска Last Chats/Contacts/Calls;
- изменение серверного XMPP-протокола или backend без отдельно доказанной несовместимости;
- перенос Telegram-кода/ресурсов;
- новый framework или third-party dependency;
- удаление legacy SearchChatListViewController в рамках этой цели: он должен просто перестать быть кандидатом для нового in-chat list;
- изменение account/session lifecycle, кроме узких safety-fix Task 25D/25E, добавленных после подтвержденного ложного удаления аккаунта во время Task 24 и подтвержденной общей Keychain-области hosted tests.

## 2. Источники и метод анализа

### 2.1 Видео

| Параметр | Значение |
|---|---|
| Файл | /Users/igor.boldin/Downloads/ScreenRecording_07-13-2026 10-51-31_1.MP4 |
| Продолжительность | 19.1167 s |
| Размер кадра | 1170 × 2532 px |
| Codec / frames | HEVC / 746 decoded video frames |
| Частота | nominal 59.94 fps; variable stream average около 39.04 fps |
| SHA-256 | 04e9b0d92c5e872cdc5ea59fb2bcc700406c22daf0204e8d721d1ceef6dc918a |
| Анализ | покадровые выборки, scene changes и сравнение ключевых состояний |

### 2.2 Официальный Telegram iOS как дополнительный поведенческий референс

Проверен публичный репозиторий Telegram iOS на commit 6e370e06d147b091b07903071cb1b8a22152492d. Он используется только для проверки геометрии/семантики и не является источником кода для Xabber:

- [верхняя search navigation geometry](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatSearchNavigationContentNode/Sources/ChatSearchNavigationContentNode.swift);
- [нижняя search panel](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Sources/ChatTagSearchInputPanelNode.swift);
- [плавающие navigation buttons](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Sources/ChatHistoryNavigationButtons.swift);
- [inline results list и анимации](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatInlineSearchResultsListComponent/Sources/ChatInlineSearchResultsListComponent.swift);
- [calendar completion semantics](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Sources/ChatControllerOpenCalendarSearch.swift).

## 3. Разбор видео по времени

| Время | Состояние | Наблюдаемое поведение |
|---|---|---|
| 0.00–1.90 | Search активен | Клавиатура открыта; сверху glass search field и отдельная круглая X; timeline остается видимым. |
| 1.94–4.50 | Ввод Test | Результаты обновляются во время ввода; появляется желтая подсветка текста; нижние controls и стрелки появляются без смены экрана. |
| 4.50–9.80 | Chat results | Слева внизу календарь + 1 of 2; справа Show as List; справа над панелью две круглые стрелки; переходы меняют 1 of 2 / 2 of 2 и центрируют сообщение. |
| 10.85–11.00 | Chat → List | Белый results list появляется поверх timeline; его content масштабируется примерно 0.95 → 1.0 и снимается blur; top search, bottom controls и клавиатура остаются неподвижны. |
| 11.00–12.30 | List | Строки newest-first: avatar, bold sender, однострочный plain snippet, delivery check и числовая дата справа; снизу 2 messages и Show as Chat; стрелок нет. |
| 12.35–12.45 | List → Chat | Обратные blur/scale list; query, count и выбранный результат сохраняются. |
| 13.50–14.00 | Calendar in | Клавиатура уходит; фон затемняется; снизу поднимается белая rounded/glass поверхность: Search, X, month navigation, weekday/grid, синяя Done. |
| 14.78–15.05 | Calendar cancel | Поверхность уходит вниз; активный search state остается. |
| 16.60–19.11 | Повторная навигация | Переходы по стрелкам продолжают работать после закрытия календаря. |

## 4. Зафиксированный UI/animation contract

### 4.1 Верхняя панель

- Номинальная высота зоны: 60 pt.
- Search capsule: leading/trailing базово 16 pt, y = 6 pt, height = 44 pt.
- Кнопка X: 44 × 44 pt, gap между field и X = 8 pt, trailing = 16 pt.
- Leading search icon находится внутри capsule; при remote loading его место занимает компактный spinner.
- Текст ищется debounce-обновлением и Return key; отдельной видимой кнопки submit нет.
- После появления текста доступна внутренняя clear-кнопка; X закрывает весь search mode.
- Используется NativeGlassBarStyle/публичный UIVisualEffectView, без private CAFilter.

### 4.2 Нижняя панель

- Высота controls: 40 pt.
- Слева отдельная capsule: 40 pt calendar hit target + animated count.
- В chat mode count: текущий индекс и total, например 1 of 2.
- В list mode count: total, например 2 messages.
- Справа отдельная capsule с текстом Show as List или Show as Chat.
- Панель привязана к keyboardLayoutGuide.topAnchor и всегда находится выше клавиатуры.

### 4.3 Переход между сообщениями

- Две отдельные круглые кнопки 40 × 40 pt справа.
- Вертикальный gap — 12 pt; кнопки располагаются над нижней панелью/клавиатурой, не перекрывая сообщение.
- Они видимы только в chat-results mode при наличии результатов и скрыты в list/calendar/inactive.
- Появление/исчезновение: примерно 0.30 s spring, alpha 0 ↔ 1 и scale 0.2 ↔ 1.
- Нажатие сразу обновляет navigation intent; если context уже грузится, сохраняется последний pending intent.
- Counter и full selection меняются только после успешного позиционирования, чтобы UI не показывал неоткрытый результат.
- `1 of N` — самый новый результат. Верхняя стрелка ведет к более старому (`index + 1`), нижняя — к более новому (`index - 1`).
- Обе кнопки остаются видимы при `N > 0`, но boundary-кнопка disabled с icon alpha около 0.5; cyclic wrap запрещен.

### 4.4 Подсветка

- Все case/diacritic-insensitive вхождения query в видимом body подсвечиваются желтым.
- Подсветка не ломает link/mention/reference attributes и корректно работает с composed Unicode/emoji.
- Активное сообщение не получает текущую синюю заливку всей ячейки; визуальный акцент сосредоточен на совпадении, как в видео.
- При clear/cancel/query replacement старая подсветка удаляется немедленно.

### 4.5 Results list

- Отдельный in-chat list, а не legacy SearchChatListViewController.
- Newest-first, stable identity: archivedId; fallback primary только когда archivedId отсутствует.
- Строка содержит avatar, sender title (You для исходящего), plain single-line snippet, delivery check и localized numeric date справа; желтая query highlight относится только к chat timeline и в list не применяется.
- Белый/system background, тонкие separators, отсутствие generic inset cards.
- Show as List доступен только при наличии committed current result; при нуле результатов показывается No Results без list-mode control.
- Chat → List: scale list sublayer 0.95 → 1.0 около 0.40 s spring и blur 30 → 0 около 0.20 s ease-out; top search, bottom controls, keyboard и timeline остаются неподвижны.
- List → Chat: scale list 1.0 → 0.95 и blur 0 → 30, оба около 0.30 s, затем list удаляется; отдельная alpha-фаза и scale timeline не добавляются.
- Blur реализовать только публичными API: snapshot + UIVisualEffectView/UIViewPropertyAnimator; при Reduce Motion — короткий crossfade.
- Открытие и обычный Chat/List toggle сохраняют текущее состояние клавиатуры; начало interactive list drag завершает editing, после чего следующие toggle сохраняют закрытое состояние.

### 4.6 Календарь

- Это «перейти к дате», хотя пользовательский control воспринимается как календарный фильтр.
- X/cancel: закрыть календарь и полностью сохранить query, results, selected result и chat/list mode.
- Done: закрыть calendar, завершить text search/list mode, найти сообщение по selected day timestamp и перейти через безопасный anchor pipeline.
- Selected `Date` передается в resolver как точный timestamp: при смене дня сохраняются hour/minute исходной selection, как в reference path.
- Поиск timestamp: первое подходящее сообщение в/после выбранного timestamp; если после него сообщений нет — последнее сообщение до этой границы.
- Custom UIKit calendar нужен для одинакового поведения на deployment target iOS 15.6; UICalendarView не должен быть единственной реализацией.
- Внутренняя month grid содержит до 42 slots, но leading/trailing outside-month slots пусты и noninteractive; surface показывает динамически 4–6 недель, а не фиксированную высоту.
- Locale-aware first weekday и DST-safe calendar arithmetic; диапазон навигации от Unix epoch до representable `Int32.max - 1`, поэтому future month/day не блокируются только из-за текущей даты.
- Surface: dim background, rounded top sheet, leading circular X, title Search, disclosure month/year title, prev/next, weekday row, day grid, 52 pt primary Done с horizontal inset около 30 pt.
- Tap по month/year title открывает month/year picker; horizontal swipe меняет месяц с transition 0.30 s и синхронизирует title, grid и picker.
- In: dim alpha 0 → 1 примерно 0.40 s, sheet spring from bottom; out около 0.30 s.
- Outside-tap/drag dismissal запрещены как явная Xabber policy до отдельной runtime-проверки референса; это не заявляется как доказанная Telegram semantics.

## 5. Целевая state machine

Presentation хранит две ортогональные оси, чтобы loading/empty/error не превращались в отдельные, противоречащие друг другу screen modes.

### 5.1 Surface mode

~~~mermaid
stateDiagram-v2
    [*] --> Inactive
    Inactive --> Chat: activate search
    Chat --> List: Show as List, committed current result
    List --> Chat: Show as Chat
    Chat --> Calendar: calendar, origin=chat
    List --> Calendar: calendar, origin=list
    Calendar --> Chat: X, origin=chat
    Calendar --> List: X, origin=list
    Calendar --> DateResolving: Done
    DateResolving --> Inactive: resolve or no match
    Chat --> Inactive: top X
    List --> Inactive: top X
~~~

### 5.2 Result phase

~~~mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Debouncing: normalized query nonempty
    Debouncing --> Searching: debounce or Return
    Searching --> Results: first batch > 0
    Searching --> Empty: terminal, 0 results
    Searching --> Error: typed failure
    Results --> Paging: more cursor
    Paging --> Results: next batch or terminal
    Paging --> Error: typed failure/truncated
    Results --> Debouncing: query replacement
    Empty --> Debouncing: query replacement
    Error --> Debouncing: retry/query replacement
    Debouncing --> Idle: query cleared
    Searching --> Idle: query cleared/cancelled
    Results --> Idle: query cleared
    Empty --> Idle: query cleared
    Error --> Idle: query cleared
~~~

### 5.3 Derived visibility/enabled contract

- Top chrome и bottom action bar видимы в surfaceMode chat/list/calendar; при calendar они остаются под dim, а в dateResolving уже заменены normal chat chrome.
- Calendar control enabled в chat/list при любой resultPhase, включая empty query, searching, empty и error.
- Show as List видим и enabled только при committed current result. Empty/searching/error без сохраненного current result остаются в chat surface; уже открытый list может переживать paging, но query replacement немедленно возвращает chat до появления нового committed result.
- Floating arrows видимы только при surfaceMode chat + resultPhase results/paging + total > 0; enabled state зависит от committed index/boundaries.
- Provider spinner отражает searching/paging; positioning/date-resolution имеют отдельный loading channel.
- Calendar X возвращает исходный surfaceMode и не меняет resultPhase/query/results.

State дополнительно несет:

- normalized query и monotonically increasing generation;
- provider mode: remoteMAM или encryptedLocal;
- resultPhase и отдельные positioning/date-resolution phases;
- ordered detached result DTOs;
- committed selected result и pending navigation intent;
- origin mode для calendar cancel;
- list scroll anchor;
- Reduce Motion policy.

## 6. Аудит текущей реализации Xabber

### Уже можно переиспользовать

- activateSearchModeFromExternalRoute() и routing из Contact/Group Info.
- Query scoping owner + jid + conversationType.
- Regular/group MAM withtext и encrypted local Realm search.
- Newest-first searchMessagesQueue.
- ChatOpenMessageRequest(source: .search, markReadOnVisible: false).
- Anchor pipeline: local displayed lookup → exact archivedId MAM → date-window fallback → centered positioning.
- Existing pending-navigation state и haptic completion.
- NativeGlassBarStyle и keyboard layout infrastructure.

### Требует замены/доработки

- ChatSearchInputBarView сейчас выглядит как composer и содержит отдельную search submit button вместо Telegram-style field + X.
- ModernXabberInputView.SearchPanel содержит cancel и arrows внутри нижнего ряда; listButton скрывается во всех текущих states.
- onSearchPanelChangeChatViewState() пуст.
- Нет отдельного in-chat results list.
- Dataset подсвечивает только одно вхождение и имеет риск case-sensitive mismatch.
- Active result сейчас подсвечивается синей заливкой всей ячейки.
- MAM UI lifecycle может завершить query после первой страницы, хотя lower-level loadFull продолжает paging.
- Нет calendar/timestamp resolver UI contract.
- Большая часть search UI меняет isHidden без parity animations.
- Legacy SearchChatListViewController имеет другой chrome/cell/state и не должен переиспользоваться.

## 7. Архитектурные границы

### xabber-ui

- ChatSearchPresentationState/Reducer.
- Top chrome, bottom action bar, floating arrows.
- Detached ChatSearchResultPresentation mapping для UI.
- Results list/cell.
- Calendar presentation/view; pure visual date-grid model может находиться рядом с UI, но не имеет доступа к Realm/MAM.
- Animation coordinator.

### xabber-business

- Detached local-search provider, Realm mapping и timestamp resolver находятся в xabber/models/chat_search или xabber/common/chat_search.
- UI получает только протоколы/DTO и не открывает Realm напрямую.
- Любая test Realm configuration изолирована и гарантированно восстанавливается в tearDown.

### xabber-xmpp

- MAM search paging, RSM/final-IQ/cancellation/deduplication.
- Timestamp fallback requests.
- Никаких UIKit типов и никакого парсинга XML в UI.

### xabber-tests

- Unit/policy/layout/accessibility tests.
- In-memory Realm only for storage tests with guaranteed restoration of default configuration.
- Optional XCUITest target with explicit live-account opt-in.
- Reference-video QA report.

## 8. Обязательные команды и правила выполнения

Все команды запускать из repository root.

### 8.1 Постоянные параметры

~~~bash
export XABBER_SCHEME='Debug (xabber project)'
export XABBER_DESTINATION='platform=iOS Simulator,id=7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF'
~~~

Перед каждым тестовым запуском non-mutating identity preflight:

~~~bash
xcrun simctl list devices | rg -F 'iPhone 16e (7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF) (Booted)'
xcrun simctl get_app_container 7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF xabber.ios data
~~~

Если указанный simulator не Booted, не создавать/не сбрасывать устройство автоматически: записать blocker и запросить запуск нужного simulator.
Для Tasks 23, 24 и 26 записать data-container path до и после запуска: путь и signed-in state должны сохраниться.

### 8.2 Канонический focused test command

В каждом Task ниже запись TEST[A, B] означает исполнить эту команду, подставив по одному -only-testing для каждого класса:

~~~bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_SCHEME='Debug (xabber project)' \
  XABBER_DESTINATION='platform=iOS Simulator,id=7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/A \
  -only-testing:xabberTests/B \
  ONLY_ACTIVE_ARCH=YES \
  COMPILER_INDEX_STORE_ENABLE=NO
~~~

Запрещено заменять allowlist на полный xabberTests. Для XCUITest после Task 23 используется target xabberUITests.

После Task 00 каждый `TEST[...]` неявно включает `AppLaunchEnvironmentPolicyTests` и `ChatSearchGoalSafetyPolicyTests`, даже если они не повторены в списке Task.

### 8.3 Базовый существующий search regression gate B0

~~~bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
  XABBER_SCHEME='Debug (xabber project)' \
  XABBER_DESTINATION='platform=iOS Simulator,id=7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/InfoCardChatSearchRoutingTests \
  -only-testing:xabberTests/InfoCardSearchAccessibilityTests \
  -only-testing:xabberTests/ChatSearchModeActivationTests \
  -only-testing:xabberTests/ChatInChatSearchQueryLifecycleTests \
  -only-testing:xabberTests/ChatSearchResultNavigationStateTests \
  -only-testing:xabberTests/ChatSearchArchiveGapRepairTests \
  -only-testing:xabberTests/ChatSearchInputBarViewTests \
  -only-testing:xabberTests/ChatSearchBottomPanelTests \
  -only-testing:xabberTests/SearchChatListKeyboardLayoutTests \
  -only-testing:xabberTests/ChatNavigationBarStateTests \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  -only-testing:xabberTests/ChatSearchGoalSafetyPolicyTests \
  ONLY_ACTIVE_ARCH=YES \
  COMPILER_INDEX_STORE_ENABLE=NO
~~~

### 8.4 Обязательная build после каждого Task

~~~bash
env \
  XABBER_SCHEME='Debug (xabber project)' \
  XABBER_DESTINATION='platform=iOS Simulator,id=7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF' \
  tools/xcodebuild_cached.sh build \
  ONLY_ACTIVE_ARCH=YES \
  COMPILER_INDEX_STORE_ENABLE=NO
~~~

### 8.5 Закрытие каждого Task

Для каждого Task без исключений:

1. Проверить git status --short и перечитать названные в Task файлы.
2. Запустить pre-task tests до production edits.
3. Добавить focused XCTest первым; зафиксировать red reason, если defect воспроизводим.
4. Реализовать только scope текущего Task.
5. Запустить post-task tests, затем обязательную build.
6. Удалить только disposable logs/result bundles/video snippets текущего Task; не трогать cache directories.
7. Обновить соответствующую строку tracked Execution journal до `ready-to-commit` и ожидаемого subject; обновить vault notes.
8. Выполнить git diff --check после documentation edits.
9. Проверить diff и stage только файлы текущего Task; запрещен git add . и git add -A.
10. Создать отдельный commit с указанным message.
11. Проверить git status и git show --stat --oneline HEAD.
12. После commit записать actual source SHA во внешний vault execution ledger. Не пытаться дописать SHA в уже созданный source commit и не создавать второй source commit задачи.

Source repository и vault — разные git roots. Source task commit никогда не stage-ит vault-файлы. Vault dashboard-файлы с чужими изменениями нельзя включать целиком: обновления фиксируются отдельным безопасным vault commit только когда их можно изолировать, иначе остаются как явно перечисленные working-tree updates.

Если pre-task tests падают:

- диагностировать первый meaningful failure;
- определить, относится ли он к текущему Task или к чужому незавершенному изменению;
- не маскировать падение broad refactor;
- не делать commit задачи, пока baseline не восстановлен или blocker не записан с доказательством.

## 9. Декомпозиция и зависимости

| Фаза | Tasks | Результат |
|---|---|---|
| Safety/Foundation | 00–05A | Hosted-test account guard, state, DTO, query session, providers, shared motion spec |
| Chat controls | 06–09 | Верхняя/нижняя панели, плавающие arrows, подсветка |
| Results list | 10–14 | Cell, list states, mode switch, motion, row navigation |
| Calendar/date jump | 15–20 | Model, UI, presentation, local/MAM resolver, Done semantics |
| Motion/quality | 21, 22A–22C | Cross-flow choreography, localization, accessibility, adaptive layout |
| Automation/performance | 23–25C | UI target, live smoke, stress/cancellation/performance/lifecycle |
| Closure | 26A–26C | Final gate/install, video QA, docs/vault closure |

### Индекс задач

| Task | Самостоятельный результат |
|---|---|
| 00 | Hosted-test isolated-storage/account safety gate |
| 01 | Pure presentation reducer/state machine |
| 02 | Detached result identity/presentation DTO |
| 03 | Query generation/debounce/cancellation session |
| 04 | Полная remote MAM pagination/final-IQ lifecycle |
| 05 | Encrypted local provider parity |
| 05A | Shared animation timing/Reduce Motion specification |
| 06 | Верхний Telegram-style search chrome |
| 07 | Нижние calendar/count и list/chat capsules |
| 08 | Плавающие boundary-aware arrows |
| 09 | Желтая подсветка всех query occurrences |
| 10 | Dedicated result row |
| 11 | Inline results list/loading/empty/error/paging |
| 12 | Chat/List state switching |
| 13 | Chat/List blur/scale transitions |
| 14 | List row → shared message anchor |
| 15 | Locale/DST-safe calendar model |
| 16 | Custom UIKit calendar view |
| 17 | Calendar overlay and motion |
| 18 | Local timestamp resolver |
| 19 | Bounded MAM timestamp fallback |
| 20 | Calendar Done → date jump |
| 21 | Unified motion/haptics/Reduce Motion |
| 22A | Localization and formatter contract |
| 22B | Accessibility IDs, labels, traits and VoiceOver order |
| 22C | Dynamic Type, RTL, contrast and Reduce Transparency |
| 23 | Guarded XCUITest target |
| 24 | Non-destructive live-account smoke |
| 25A | Stress and cancellation hardening |
| 25B | Search/list/highlight performance hardening |
| 25C | Lifecycle, interruption and leak hardening |
| 26A | Deduplicated final regression, build and bounded install-over |
| 26B | Non-destructive live scenario and reference-video QA |
| 26C | Durable docs, vault closure and execution-ledger audit |

---

## Task 00 — Защитить account-bearing simulator от hosted XCTest

**Owner:** xabber-tests
**Secondary:** xabber-business, xabber-ui
**Depends on:** existing AppLaunchEnvironmentPolicy
**Commit:** test(infrastructure): isolate hosted XCTest storage

### Цель

До любых search-изменений доказать, что allowlisted hosted unit tests не подключают аккаунты и не открывают persistent Realm установленного приложения. Добавить opt-in in-memory storage policy, активную только при одновременном наличии hosted XCTest marker и двух test flags. Обычный launch и будущий live UI flow должны остаться без этого режима.

### Файлы

- xabber/application/AppDelegate.swift;
- при необходимости новый xabber/application/AppLaunchEnvironmentPolicy.swift без UIKit-зависимости;
- новый xabberTests/ChatSearchGoalSafetyPolicyTests.swift;
- дополнить AppLaunchEnvironmentPolicyTests в xabberTests/xabberTests.swift;
- xabber.xcodeproj/project.pbxproj только при добавлении нового production/test файла.

### Pre-task tests

- Non-mutating preflight из §8.1 с exact UDID/device match и записью текущего app data-container path.
- До появления isolated-storage policy выполнить ровно один минимальный hosted baseline только для существующего AppLaunchEnvironmentPolicyTests, с disable-autoconnect flag; broad B0 запрещен на этом шаге:

~~~bash
env \
  TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
  XABBER_SCHEME='Debug (xabber project)' \
  XABBER_DESTINATION='platform=iOS Simulator,id=7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberTests/AppLaunchEnvironmentPolicyTests \
  ONLY_ACTIVE_ARCH=YES \
  COMPILER_INDEX_STORE_ENABLE=NO
~~~

- Эта одноразовая pre-Task-00 проверка может открыть app host/Realm migration path, но не autoconnect account; сравнить container/signed-in state сразу после нее и остановиться при любом account anomaly. Все последующие unit tests используют isolated storage.

### Tests-first

ChatSearchGoalSafetyPolicyTests/AppLaunchEnvironmentPolicyTests должны покрыть:

- normal launch без XCTest marker не может включить isolated storage, даже если одиночный custom flag случайно присутствует;
- hosted XCTest + disable-autoconnect без isolated flag не меняет Realm configuration;
- hosted XCTest + оба flags дает отдельный уникальный in-memory identifier до вызова realmMigrations;
- PushKit/normal application launch сохраняют прежнюю account policy;
- policy не читает/не удаляет persistent Realm URL и не вызывает file deletion;
- original Realm.Configuration.defaultConfiguration сохраняется и восстанавливается тестом через tearDown/defer;
- два test processes получают разные in-memory identifiers;
- live XCUITest/manual process без hosted-unit marker не изолируется и не отключает account autoconnect;
- unit-test command contract требует оба flags, live command contract явно снимает оба flags.

### Реализация

1. Расширить pure AppLaunchEnvironmentPolicy отдельным решением `shouldUseIsolatedTestStorage`/configuration descriptor; оно истинно только для hosted XCTest (`XCTestConfigurationFilePath`) при обоих opt-in flags.
2. В AppDelegate применить уникальную in-memory default Realm configuration до первого `realmMigrations`, сохранив normal launch path неизменным.
3. Не удалять Realm files, app container, credentials, UserDefaults или Keychain и не добавлять cleanup реального storage.
4. Test helper обязан восстанавливать previous default configuration после каждого case.
5. После Task обновить канонические TEST/B0 команды §8 так, чтобы оба flags были обязательны; не export-ить их глобально.

### Критерии принятия

- Allowlisted hosted unit test не autoconnect-ит accounts и использует только уникальный in-memory Realm.
- Обычный installed-app launch и live UI test не меняют storage/account behavior.
- Exact data-container path до и после Task совпадает; это identity guard, а не обещание отсутствия обычных read-state effects в будущей ручной проверке.
- Ни один test/helper не содержит erase/uninstall/logout/remove-account/file-delete действий.
- B0 с обоими flags проходит, затем simulator build проходит.

### Post-task verification

- TEST[AppLaunchEnvironmentPolicyTests, ChatSearchGoalSafetyPolicyTests, InfoCardChatSearchRoutingTests, ChatSearchModeActivationTests].
- Повторить non-mutating exact device/container preflight и сравнить path.
- Обязательная simulator build.
- Обновить tests/business/UI notes и journal, затем git diff --check.

---

## Task 01 — Ввести единую presentation state machine

**Owner:** xabber-ui
**Depends on:** Task 00
**Commit:** refactor(chat-search): add presentation state machine

### Цель

Убрать разрозненные комбинации inSearchMode, SearchPanel.RenderState, isLoading, list flag и calendar overlay из роли неявной state machine. Создать чистую модель/reducer, через которую последующие Tasks смогут детерминированно рендерить controls.

### Файлы

- новый xabber/controllers/chats/chat/search/ChatSearchPresentationState.swift;
- xabber/controllers/chats/chat/ChatViewController.swift;
- xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift;
- новый xabberTests/ChatSearchPresentationStateTests.swift;
- xabber.xcodeproj/project.pbxproj для target membership.

### Pre-task tests

- Запустить B0 полностью.

### Tests-first

ChatSearchPresentationStateTests должен покрыть:

- inactive → surfaceMode.chat + resultPhase.idle;
- queryChanged меняет только resultPhase: idle → debouncing → searching при неизменном surfaceMode.chat;
- searching → results, empty и error без создания новых screen modes;
- chat ↔ list разрешен только при committed current result и не теряет query/results/committed selection;
- empty/searching/error без committed result не показывает и не открывает list;
- openCalendar запоминает origin chat/list, сохраняя resultPhase;
- cancelCalendar возвращает origin и сохраняет все search data;
- completeCalendarDate очищает text-search state и входит в resolvingDate;
- cancelSearch из каждого состояния дает inactive;
- stale event с предыдущей generation игнорируется;
- невозможные transitions (list без committed current result, navigation в calendar) не меняют state;
- derived visibility: top, bottom, arrows, list, calendar, spinner.

### Реализация

1. Создать Equatable value types для ортогональных surfaceMode, resultPhase, positioning/date-resolution phases, origin и event.
2. Сделать reducer чистым и не зависящим от UIKit/Realm/XMPP.
3. Подключить state к текущим callbacks с минимальной адаптацией, пока сохранив существующий UI.
4. Не менять визуальную геометрию в этом Task.
5. Оставить compatibility mapping для SearchPanel.RenderState до Task 07.
6. Все UI apply выполнять на main thread; reducer остается синхронным и тестируемым.
7. Запретить contradictory combinations через reducer invariants/derived properties, а не через разрозненные `isHidden` checks.

### Критерии принятия

- Для любого event существует ровно одно предсказуемое состояние.
- Calendar cancel восстанавливает mode, из которого он был открыт.
- Stale network/query events не могут вернуть старые results.
- Existing activation/navigation/query behavior не изменилось визуально.
- State file не импортирует Realm/XMPP/UI view controllers.

### Post-task verification

- TEST[ChatSearchPresentationStateTests, ChatSearchModeActivationTests, ChatInChatSearchQueryLifecycleTests, ChatSearchResultNavigationStateTests, ChatSearchBottomPanelTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 02 — Ввести detached result identity и presentation DTO

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Task 01
**Commit:** refactor(chat-search): add detached result model

### Цель

Отделить UI/list/navigation от live Realm MessageStorageItem и зафиксировать единый identity/order/mapping contract.

### Файлы

- новый xabber/controllers/chats/chat/search/ChatSearchResult.swift;
- xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift;
- при необходимости read-only mapper рядом с MessageStorageItem;
- новый xabberTests/ChatSearchResultPresentationTests.swift;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchPresentationStateTests, ChatInChatSearchQueryLifecycleTests, ChatSearchResultNavigationStateTests].

### Tests-first

Покрыть:

- archivedId является primary stable identity;
- при пустом archivedId используется primary, но не body/date;
- owner/jid/conversationType scope переносится и проверяется;
- newest-first sort; при одинаковой date порядок стабилен по archivedId/primary;
- outgoing sender title = localized You;
- incoming regular sender = contact display name;
- group incoming sender = stanza author/nickname fallback;
- snippet формируется из body без изменения исходного body;
- delivery state mapping для sent/delivered/read/failed/pending;
- DTO detached: изменение Realm object после mapping не меняет DTO;
- duplicate archivedId схлопывается, более полный item побеждает;
- index/count formatter не допускает 0 of N и out-of-bounds.

### Реализация

1. Создать Sendable там, где это возможно без unsafe annotation.
2. Хранить только значения, необходимые timeline/list/navigation.
3. Сохранить archivedId, primary, date и conversation scope.
4. Вынести deterministic comparator/deduplicator.
5. Адаптировать controller queue через DTO либо временный adapter, не переписывая anchor pipeline.
6. Не выполнять Realm reads на main thread внутри cell.

### Критерии принятия

- List и chat navigation могут использовать один immutable ordered result set.
- Stable identity не зависит от индекса.
- DTO безопасно переживает background callback и Realm refresh.
- Существующие result navigation tests проходят без изменения направления/selection semantics.

### Post-task verification

- TEST[ChatSearchResultPresentationTests, ChatSearchPresentationStateTests, ChatSearchResultNavigationStateTests, ChatSearchArchiveGapRepairTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 03 — Выделить query session, generation и cancellation contract

**Owner:** xabber-ui
**Secondary:** xabber-xmpp, xabber-tests
**Depends on:** Tasks 01–02
**Commit:** refactor(chat-search): isolate query session lifecycle

### Цель

Сделать ввод test, debounce, provider request, stale callback rejection и reset единым session lifecycle до добавления list/paging.

### Файлы

- новый xabber/controllers/chats/chat/search/ChatSearchSession.swift;
- xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift;
- xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift;
- новый xabberTests/ChatSearchSessionStateTests.swift;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchPresentationStateTests, ChatSearchResultPresentationTests, ChatInChatSearchQueryLifecycleTests, ChatSearchResultNavigationStateTests].

### Tests-first

Покрыть:

- whitespace-only query нормализуется в empty и не отправляет request;
- t → te → tes → test создает новую generation на каждое принятое значение;
- debounce 250 ms отправляет только последнюю generation;
- Return key может немедленно flush текущий query без двойного request;
- смена query отменяет previous disposable/callback registration;
- result/final/error старой generation игнорируются;
- cancel search отменяет debounce, request, date resolver и pending navigation;
- одинаковый normalized query не создает duplicate request;
- remote provider и encrypted local provider выбираются только по conversation type;
- first result становится pending target, но committed selection меняется только после positioning success.

### Реализация

1. Ввести protocol provider/session callbacks без UIKit.
2. Generation сделать monotonically increasing UInt64 или UUID и передавать во все callbacks.
3. Сохранить текущий 250 ms debounce.
4. Разделить server searching, paging и anchor context loading.
5. Удалить ad-hoc clear paths только после покрытия tests.
6. Не менять XMPP stanza shape в этом Task.

### Критерии принятия

- Быстрый ввод не смешивает results разных query.
- Cancel гарантированно прекращает дальнейшее UI применение callback.
- Loading spinner отражает provider search, а context-loading не очищает results.
- Query test дает один активный session.

### Post-task verification

- TEST[ChatSearchSessionStateTests, ChatInChatSearchQueryLifecycleTests, ChatSearchPresentationStateTests, ChatSearchResultNavigationStateTests, ChatSearchArchiveGapRepairTests].
- Обязательная simulator build.
- Обновить UI/XMPP/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 04 — Исправить remote MAM search pagination и completion

**Owner:** xabber-xmpp
**Secondary:** xabber-business, xabber-ui, xabber-tests
**Depends on:** Task 03
**Commit:** fix(chat-search): paginate remote MAM results

### Цель

Гарантировать, что list mode получает все доступные страницы текущего withtext query, а UI не объявляет session завершенным после первой страницы.

### Файлы

- xabber/xmpp/messages/message_archive/MessageArchiveManager.swift;
- при необходимости новый xabber/xmpp/messages/message_archive/ChatSearchArchiveSession.swift;
- новый business-level coordinator/protocol в xabber/models/chat_search или xabber/common/chat_search;
- xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift только как presentation adapter;
- xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift;
- новый xabberTests/ChatSearchMAMPagingTests.swift;
- существующие archive request/paging policy tests;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchSessionStateTests, ChatInChatSearchQueryLifecycleTests, ChatSearchArchiveGapRepairTests, ChatHistoryPageCompletionPolicyTests, ChatArchiveCoverageCommitPolicyTests, ChatHistoryPagingPolicyTests].

### Tests-first

Покрыть:

- первая страница меньше/равна max и final complete=true завершает session;
- complete=false с valid RSM cursor запрашивает следующую страницу;
- каждая incremental page добавляется newest-first без повторов;
- duplicated boundary item между страницами схлопывается;
- final IQ обрабатывается после сохранения всех result messages;
- stale final/page callback предыдущей generation игнорируется;
- cancel останавливает дальнейшую pagination;
- network/IQ error дает typed error и снимает spinner;
- malformed/missing RSM не запускает бесконечный loop;
- repeated/no-progress cursor завершает session typed `.truncated`, а не успешным completed;
- любой explicit resource cap возвращает typed `.truncated` с accumulated results и никогда не маскируется как complete;
- zero results корректно дает completed empty;
- search request не коммитит regular archive coverage и не двигает normal history cursors;
- list update не ждет context fetch для первого выбранного message;
- максимальное число pages/защита от повторяющегося cursor предотвращает runaway requests.

### Реализация

1. Ввести query-scoped paging owner с generation/queryId и typed terminal result: completed, failed, cancelled, truncated.
2. Расширить текущий RequestCallbacks (`onMessage`/`onEndPage`) typed `onFailure`/terminal channel именно для search и route server/IQ/transport errors как failure; normal-history policy не менять без отдельного теста.
3. Отменить registered callback/search IDs, invalidировать scheduled continuation и не позволять `asyncAfter` отправить следующую страницу после cancel/query replacement.
4. Явно разделить incrementalResults, persistedPage и terminal completion: final UI completion идет только после сохранения последней страницы.
5. Deduplicate по archivedId/primary до UI и сохранять через существующий archive persistence path ниже presentation слоя.
6. Останавливать paging только на server terminal, typed error/cancel, repeated/no-progress cursor; optional hard cap считается `.truncated`, не success.
7. Не менять server/backend и XML shape withtext; не использовать обычный archiveEnd как доказательство search completeness.

### Критерии принятия

- 251+ результатов доступны list mode через несколько страниц.
- Counter растет согласованно и финализируется только после terminal page/final IQ.
- Нет duplicate rows и stale results.
- Normal MAM sync/coverage не изменены.
- Error/cancel всегда освобождают callbacks и spinner.

### Post-task verification

- TEST[ChatSearchMAMPagingTests, ChatSearchSessionStateTests, ChatInChatSearchQueryLifecycleTests, ChatSearchArchiveGapRepairTests, ChatHistoryPageCompletionPolicyTests, ChatArchiveCoverageCommitPolicyTests, ChatHistoryPagingPolicyTests, ChatRemoteHistoryApplyPolicyTests].
- Обязательная simulator build.
- Обновить XMPP/UI/tests notes, shared/interfaces.md при изменении callback contract, handoff и journal.
- git diff --check после documentation edits.

---

## Task 05 — Выравнять encrypted local search provider

**Owner:** xabber-business
**Secondary:** xabber-ui, xabber-tests
**Depends on:** Tasks 02–04
**Commit:** fix(chat-search): align encrypted local results

### Цель

Дать encrypted chats тот же ordered DTO/list/cancel contract без remote MAM и без обращения к реальной account Realm в tests.

### Файлы

- xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift только как UI adapter;
- новый xabber/models/chat_search/ChatSearchLocalProvider.swift или xabber/common/chat_search/ChatSearchLocalProvider.swift;
- MessageStorageItem query helpers при необходимости;
- новый xabberTests/ChatSearchLocalProviderTests.swift;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchSessionStateTests, ChatSearchResultPresentationTests, ChatInChatSearchQueryLifecycleTests, ChatSearchMAMPagingTests].

### Tests-first

Использовать уникальный in-memory Realm identifier и defer-восстановление Realm.Configuration.defaultConfiguration. Покрыть:

- strict owner/jid/.omemo scope;
- deleted/system/other-conversation items исключены;
- case/diacritic-insensitive test/Test/TEST matching;
- newest-first и deterministic tie break;
- локальная выдача более 250 items отдается pages/chunks без блокировки main thread;
- cancel/query replacement прекращает применение старого result batch;
- empty query не сканирует body;
- duplicate identities схлопываются;
- result DTO detached от Realm thread;
- local provider никогда не вызывает MAM;
- Realm configuration и temporary files восстановлены после каждого test.
- provider API не импортирует UIKit и возвращает только detached DTO/result phase.

### Реализация

1. Выполнять Realm read/filter на выделенной queue/actor в соответствии с текущими Realm правилами проекта.
2. Возвращать detached DTO batches через main-thread session callback.
3. Сохранить encrypted local-only policy.
4. Добавить bounded batch size и cancellation check между batches.
5. Не добавлять schema migration и не менять persisted model.

### Критерии принятия

- Encrypted results имеют те же list/count/navigation semantics.
- UI не зависает при большой локальной истории.
- Никакой test не читает/пишет simulator account Realm.
- Normal regular/group remote search не изменен.
- Realm ownership остается business-layer; controller не выполняет query напрямую.

### Post-task verification

- TEST[ChatSearchLocalProviderTests, ChatSearchSessionStateTests, ChatSearchResultPresentationTests, ChatInChatSearchQueryLifecycleTests, ChatSearchMAMPagingTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 05A — Зафиксировать shared animation specification

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Tasks 01–05
**Commit:** refactor(chat-search): add animation specification

### Цель

До создания visual controls собрать durations, spring parameters, initial/final transforms и accessibility fallbacks в один testable value contract. Это предотвращает расхождение Tasks 06–17 и оставляет Task 21 только для cross-flow interruption/haptic coordination.

### Файлы

- новый xabber/controllers/chats/chat/search/ChatSearchAnimationSpec.swift;
- новый xabberTests/ChatSearchAnimationSpecTests.swift;
- xabber.xcodeproj/project.pbxproj.

### Pre-task tests

- TEST[ChatSearchPresentationStateTests, ChatSearchSessionStateTests, ChatSearchLocalProviderTests, ChatSearchMAMPagingTests].

### Tests-first

ChatSearchAnimationSpecTests должен проверить:

- floating buttons: 0.30 s spring, scale 0.2 ↔ 1.0 и alpha 0 ↔ 1;
- list in: sublayer scale 0.95 → 1.0 за 0.40 s spring, blur 30 → 0 за 0.20 s ease-out;
- list out: scale 1.0 → 0.95 и blur 0 → 30 за 0.30 s;
- calendar dim/sheet in около 0.40 s spring, out около 0.30 s;
- month swipe duration 0.30 s и direction зависит от semantic month direction/RTL;
- Reduce Motion заменяет transforms/blur коротким crossfade и не оставляет intermediate state;
- Reduce Transparency запрещает blur и выбирает opaque system material fallback;
- все durations доступны через injected spec, а не захардкожены в views.

### Реализация

1. Создать immutable spec/value types без private API и без запуска UIView animations в самой модели.
2. Добавить production default и deterministic immediate/test spec.
3. Не создавать controls и не менять текущий visual layout в этом Task.
4. Зафиксировать independent-reimplementation provenance: только наблюдаемые параметры, без Telegram source structure/assets.

### Критерии принятия

- Все последующие animation consumers могут получить единый spec через dependency/default.
- В production нет private CAFilter/makeBlurFilter/generated Telegram icon paths.
- Reduce Motion/Transparency behavior определено до visual implementation.
- Existing UI визуально не изменился в этом Task.

### Post-task verification

- TEST[ChatSearchAnimationSpecTests, ChatSearchPresentationStateTests, ChatSearchSessionStateTests, ChatSearchBottomPanelTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal, затем git diff --check.

---

## Task 06 — Перестроить верхний Telegram-style search chrome

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Task 05A
**Commit:** feat(chat-search): add Telegram-style top search chrome

### Цель

Заменить composer-like ChatSearchInputBarView на фиксированную 60 pt navigation surface: 44 pt glass search capsule, leading search/loading control, internal clear и отдельная 44 pt X справа.

### Файлы

- xabber/controllers/chats/chat/ChatViewController.swift;
- xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift;
- новый или выделенный xabber/controllers/chats/chat/search/ChatSearchNavigationView.swift;
- xabber/controllers/bars/XabberGlassStyle.swift только если нужен совместимый public hook; global defaults не менять;
- новый xabberTests/ChatSearchTopChromeTests.swift;
- обновить ChatSearchInputBarViewTests/InfoCardSearchAccessibilityTests;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchPresentationStateTests, ChatSearchSessionStateTests, ChatSearchInputBarViewTests, InfoCardSearchAccessibilityTests, ChatNavigationBarStateTests, ChatComposerFrameUpdateTests].

### Tests-first

Покрыть:

- nominal container height 60 pt;
- field frame при width 390: x 16, y 6, height 44, right edge за 8 pt до X;
- X frame 44 × 44, trailing 16;
- safe-area left/right insets добавляются к базовым 16;
- search icon/submit proxy внутри leading area; chat_search_submit сохраняется как automation identifier, но не является отдельной capsule;
- remote searching заменяет icon spinner с chat_search_loading и не сдвигает text;
- text non-empty показывает chat_search_clear; clear очищает query, results/highlight, но оставляет search mode и keyboard;
- X имеет chat_search_cancel и полностью закрывает search;
- Return key flush-ит query один раз;
- Dynamic Type не увеличивает панель выше 60 pt: input остается single-line и горизонтально scrollable;
- repeated configureSearchBar idempotent;
- navigation transition не оставляет avatar/title/back button поверх search chrome;
- first responder запрашивается только после появления view в window;
- iOS 15.6 fallback и iOS 26 glass используют одну геометрию.

### Реализация

1. Выделить ChatSearchNavigationView с layout constants и публичным render(state:).
2. Перенести cancel из bottom panel в X верхней панели.
3. Оставить visible search icon внутри capsule; существующий chat_search_submit перенести на leading UIButton/control с невидимой дополнительной capsule.
4. Добавить clear button внутри правой части field с отдельным chat_search_clear.
5. Ограничить input одной строкой; удалить composer auto-height behavior из search path.
6. Привязать surface к safeArea top/nav replacement без frame hacks.
7. Для iOS 26 использовать NativeGlassBarStyle; fallback — public blur/vibrancy.
8. Не менять bottom panel в этом Task, кроме временного скрытия duplicate cancel после подключения верхнего X.

### Критерии принятия

- Layout tests фиксируют nominal 60/44/16/8 geometry contract; measured tolerance к reference video проверяется только в Task 26B.
- Нет отдельной видимой submit capsule.
- X закрывает search, clear оставляет search открытым.
- Spinner не меняет ширину/позицию текста.
- Existing external activation и keyboard focus работают.
- Нет private API и новых ассетов Telegram.

### Post-task verification

- TEST[ChatSearchTopChromeTests, ChatSearchInputBarViewTests, InfoCardSearchAccessibilityTests, ChatSearchModeActivationTests, ChatNavigationBarStateTests, ChatSearchSessionStateTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 07 — Перестроить нижнюю action bar и animated counter

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Tasks 05A, 06
**Commit:** feat(chat-search): add bottom calendar and list controls

### Цель

Сделать нижнюю 40 pt панель из двух независимых glass capsules: calendar + count слева и Show as List/Show as Chat справа. Удалить из нее cancel и arrows.

### Файлы

- xabber/controllers/chats/chat/messages_kit/Views/ModernXabberInputView.swift;
- при необходимости новый xabber/controllers/chats/chat/search/ChatSearchBottomActionBar.swift;
- xabber/controllers/chats/chat/ChatViewController.swift;
- xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift;
- новый xabberTests/ChatSearchBottomActionBarTests.swift;
- обновить ChatSearchBottomPanelTests/SearchChatListKeyboardLayoutTests;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchPresentationStateTests, ChatSearchTopChromeTests, ChatSearchBottomPanelTests, SearchChatListKeyboardLayoutTests, ChatComposerFrameUpdateTests].

### Tests-first

Покрыть:

- intrinsic height 40 pt;
- leading capsule начинается от safe-area leading и имеет minimum 40 pt;
- chat_search_calendar hit target не меньше 40 × 40;
- chat_search_results_count показывает 1 of 2 в chat mode и 2 messages в list mode;
- zero/one/plural localized forms;
- current/total меняются через numeric transition, без пересоздания hierarchy;
- trailing chat_search_view_mode_control имеет title Show as List/Show as Chat и minimum height 40;
- right control скрыт при отсутствии committed current result и доступен только при `total > 0`;
- calendar доступен при active search независимо от result count;
- no-query/loading/empty/results/list render states не оставляют stale count;
- cancel/arrows отсутствуют в bottom hierarchy;
- панель pinned к keyboardLayoutGuide.topAnchor при keyboard shown/hidden/interactive dismissal;
- home indicator/safe-area учитываются без двойного bottom inset;
- rotation/width change не вызывает overlap capsules.

### Реализация

1. Разделить surfaceView на leading и trailing glass hosts.
2. Заменить list icon на text mode control.
3. Добавить calendar control и callbacks.
4. Перенести legacy cancel ownership только в top chrome.
5. Удалить seekUp/seekDown из bottom constraints, но сами callbacks пока сохранить до Task 08.
6. Добавить lightweight numeric label transition через ChatSearchAnimationSpec; при Reduce Motion — immediate/crossfade.
7. Привязать container к keyboard layout guide.
8. Сохранить chat_search_results_panel/count identifiers и добавить calendar/view-mode identifiers.

### Критерии принятия

- Layout policy фиксирует структуру/высоту по reference contract; числовой visual tolerance проверяется только в Task 26B по записанному simulator video.
- Клавиатура никогда не перекрывает controls.
- Chat/list titles и count всегда соответствуют state.
- Нет duplicate X или arrows внизу.
- Empty/loading states не скачут по ширине.

### Post-task verification

- TEST[ChatSearchBottomActionBarTests, ChatSearchBottomPanelTests, SearchChatListKeyboardLayoutTests, ChatComposerFrameUpdateTests, ChatSearchPresentationStateTests, ChatSearchTopChromeTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 08 — Вынести плавающие previous/next buttons

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Tasks 03, 05A, 07
**Commit:** feat(chat-search): add floating result navigation

### Цель

Создать отдельный right-side floating control stack с Telegram-подобной геометрией, boundary state и pending-intent behavior.

### Файлы

- новый xabber/controllers/chats/chat/search/ChatSearchNavigationButtonsView.swift;
- xabber/controllers/chats/chat/ChatViewController.swift;
- xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift;
- ModernXabberInputView.swift для удаления legacy arrow ownership;
- новый xabberTests/ChatSearchNavigationButtonsTests.swift;
- обновить ChatSearchResultNavigationStateTests/ChatSearchBottomPanelTests;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchResultNavigationStateTests, ChatSearchBottomActionBarTests, ChatSearchPresentationStateTests, ChatSearchArchiveGapRepairTests].

### Tests-first

Покрыть:

- две кнопки 40 × 40 и vertical gap 12;
- trailing safe-area inset и bottom anchor над bottom bar/keyboard;
- arrows видимы только при surfaceMode.chat + committed results и скрыты в inactive/searching без current result/empty/list/calendar;
- один terminal result: обе кнопки disabled; если доказан older-page cursor, upper может оставаться enabled для guarded paging;
- newest-first mapping: upper/earlier идет к следующему более старому result; lower/later — к более новому;
- у terminal oldest upper disabled, у newest lower disabled; нет cyclic wrap;
- у oldest currently loaded result с valid older-page cursor upper инициирует не более одной guarded page request на generation, затем positioning первого нового older result;
- repeated/no-progress/terminal cursor переводит upper в disabled без wrap;
- нажатие disabled button не меняет state;
- во время positioning/context load последнее нажатие заменяет pending intent;
- committed counter/id меняется только в positioning success callback;
- positioning failure сохраняет предыдущий committed selection и снимает busy;
- query replacement очищает pending intent;
- accessibility identifiers chat_search_previous_result/chat_search_next_result сохранены;
- animation state alpha/scale не оставляет hidden-but-hittable view.

### Реализация

1. Создать standalone view с двумя detached NativeGlassBarStyle buttons.
2. Разместить поверх message timeline, но ниже top search и выше bottom action bar.
3. Связать с ChatSearchPresentationState derived visibility/enabled state.
4. Перевести onSearchPanelSeekUp/Down на explicit earlier/later semantics.
5. Убрать cyclic nextSearchResultIndex behavior.
6. Сохранить existing anchor queue/latest-intent mechanism.
7. Использовать 0.30 s spring alpha/scale из ChatSearchAnimationSpec и сразу соблюдать его Reduce Motion/Transparency policy.
8. Разделить `atKnownOldest` и `atTerminalOldest`; не выдавать network paging как navigation wrap.

### Критерии принятия

- Layout tests фиксируют 40 pt/12 pt geometry contract; измеренный допуск к reference video проверяется в Task 26B.
- Navigation не wrap-ится и корректно disabled на границах.
- Rapid taps не открывают stale result.
- List/calendar не показывают arrows.
- Весь existing local/MAM anchor safety остается.

### Post-task verification

- TEST[ChatSearchNavigationButtonsTests, ChatSearchResultNavigationStateTests, ChatSearchArchiveGapRepairTests, ChatOpenMessageRequestHandlingPolicyTests, ChatMessageAnchorPolicyTests, ChatSearchPresentationStateTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 09 — Реализовать Telegram-style query highlighting

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Tasks 02–03
**Commit:** fix(chat-search): highlight every query occurrence

### Цель

Подсвечивать все совпадения query желтым, убрать синюю заливку active cell и гарантировать корректную очистку/Unicode behavior.

### Файлы

- xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift;
- xabber/controllers/chats/chat/messages_kit/Views/Cells/MessageContentCell.swift;
- xabber/controllers/chats/chat/delegate/action/ChatViewController+CellDelegate.swift;
- новый xabber/controllers/chats/chat/search/ChatSearchHighlighting.swift;
- новый xabberTests/ChatSearchHighlightingTests.swift;
- существующие search selection/clear tests;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchResultPresentationTests, ChatSearchSessionStateTests, ChatSearchResultNavigationStateTests, InfoCardSearchAccessibilityTests].

### Tests-first

Покрыть:

- все occurrences в Test test TEST;
- diacritic-insensitive matching;
- composed Unicode/emoji не разрезается неверным NSRange;
- overlapping policy детерминирован и не зацикливается;
- multiline body;
- query в URL/link/mention сохраняет исходный attribute и добавляет background;
- unsupported/non-text message не падает;
- empty/whitespace query дает no ranges;
- query replacement удаляет старые ranges;
- cancel/list transition/reused cell очищают stale attributes;
- active result больше не устанавливает full-cell blue background;
- selected message identity не влияет на ranges других results;
- dynamic light/dark highlight colors имеют достаточный contrast.

### Реализация

1. Вынести pure range finder на NSString/NSRange с localized case/diacritic options.
2. Применять background/foreground attributes поверх копии attributed text.
3. Не удалять semantic attributes links/mentions/references.
4. Обновлять все visible matching cells при query/selection changes.
5. Удалить search-specific whole-cell blue selection, не затрагивая reply/mention/other selection states.
6. Гарантировать reset в prepareForReuse/cancel.

### Критерии принятия

- В query test каждое видимое вхождение подсвечено желтым.
- Нет blue cell wash.
- Links/mentions остаются tappable и стилистически корректны.
- После cancel нет ни одного stale highlight.
- Нет crash на emoji/Unicode.

### Post-task verification

- TEST[ChatSearchHighlightingTests, ChatSearchResultNavigationStateTests, ChatSearchSessionStateTests, ChatDiffKeySignatureTests, ChatDisplayModelCacheTests, ChatReloadInvalidationPolicyTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 10 — Создать dedicated search result cell

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Tasks 02, 05A, 09
**Commit:** feat(chat-search): add result list cell

### Цель

Создать самостоятельную UIKit row, визуально соответствующую Telegram list и не использующую legacy chat-list cell.

### Файлы

- новый xabber/controllers/chats/chat/search/ChatSearchResultCell.swift;
- ChatSearchResult.swift mapper при необходимости;
- shared AvatarView/date/delivery icon helpers без изменения их contracts;
- новый xabberTests/ChatSearchResultCellTests.swift;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchResultPresentationTests, ChatSearchHighlightingTests, ChatSearchTopChromeTests, ChatSearchBottomActionBarTests].

### Tests-first

Покрыть:

- reuse identifier и prepareForReuse полностью очищают avatar/text/date/status;
- avatar frame, sender/snippet/date baselines и separator insets при standard width;
- sender bold/semibold, snippet single-line truncating tail;
- outgoing sender = localized You;
- group author/avatar и fallback initials;
- date formatter для today/this year/older year и locale;
- reference parity: outgoing check находится непосредственно перед numeric date; incoming не показывает outgoing check;
- Xabber delivery mapping pending/sent/delivered/read/failed тестируется как явно обозначенное enhancement, не как доказанное видео-поведение;
- snippet остается plain и не применяет желтую query highlight;
- asynchronous avatar completion проверяет represented identity и не ставит чужой avatar;
- Dynamic Type до accessibility category не вызывает overlap: row может увеличить height по policy;
- RTL зеркалит content/date/status корректно;
- selected/highlighted cell state не рисует generic blue background;
- accessibility element объединяет sender, snippet, date и status; identifier включает stable result identity.

### Реализация

1. Использовать UITableViewCell с systemBackground.
2. Добавить avatar, senderLabel, snippetLabel, dateLabel, statusImageView и separator.
3. Layout выполнить Auto Layout или детерминированной layout policy, тестируемой без screenshot dependency.
4. Не читать Realm из cell.
5. Avatar requests отменять/валидировать на reuse.
6. Использовать Xabber-owned/SF Symbols, не Telegram assets.

### Критерии принятия

- Row содержит все наблюдаемые элементы и не выглядит generic card.
- Reuse не показывает чужие данные.
- Newest/author/date/status читаемы в light/dark mode.
- Accessibility label дает полное содержание строки.
- Cell не зависит от ChatViewController.

### Post-task verification

- TEST[ChatSearchResultCellTests, ChatSearchResultPresentationTests, ChatSearchHighlightingTests, ChatDisplayModelCacheTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 11 — Создать in-chat results list и его состояния

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Tasks 01–05, 10
**Commit:** feat(chat-search): add inline results list

### Цель

Реализовать отдельный child view/controller для newest-first search results с incremental paging, loading, empty и error states.

### Файлы

- новый xabber/controllers/chats/chat/search/ChatSearchResultsListViewController.swift;
- ChatSearchResultCell.swift;
- ChatSearchPresentationState.swift;
- xabber/controllers/chats/chat/ChatViewController.swift для containment hook;
- новый xabberTests/ChatSearchResultsListTests.swift;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchResultCellTests, ChatSearchResultPresentationTests, ChatSearchMAMPagingTests, ChatSearchLocalProviderTests, ChatSearchPresentationStateTests].

### Tests-first

Покрыть:

- proper child containment add/remove lifecycle;
- plain/system background и no generic cards;
- results sorted newest-first независимо от callback order;
- diffable snapshot использует stable identity и не reload-ит неизмененные rows;
- incremental page append сохраняет visible scroll anchor;
- duplicate results не создают duplicate rows;
- loading first page, loading next page, empty, error и populated states;
- partial results остаются видимыми во время next-page loading;
- stale generation snapshot игнорируется;
- table contentInsets учитывают 60 pt top chrome, 40 pt bottom bar, keyboard guide и safe areas;
- keyboard остается first responder при открытии list;
- chat_search_results_list, chat_search_result_row, chat_search_results_empty, chat_search_results_error, chat_search_results_paging identifiers;
- row selection callback передает stable identity, не index;
- list освобождает avatar tasks/data source после removal;
- 0, 1, 250 и 1000 synthetic rows не вызывают bounds crash.

### Реализация

1. Использовать UIKit UITableView и UITableViewDiffableDataSource.
2. Принимать immutable render model/generation.
3. Создать lightweight empty/error views с localized text и retry callback для active query.
4. Paging indicator показывать без блокировки уже видимых rows.
5. List не должен самостоятельно вызывать XMPP/Realm; только callbacks в session/controller.
6. Не встраивать legacy SearchChatListViewController.
7. Поддержать programmatic scroll к selected identity.

### Критерии принятия

- List показывает те же result DTO, что counter/navigation.
- Newest result находится сверху.
- Paging не сбрасывает scroll.
- Internal empty/error/loading render models детерминированы; пользователь не может открыть empty list без current result.
- Containment корректен при многократном open/close.

### Post-task verification

- TEST[ChatSearchResultsListTests, ChatSearchResultCellTests, ChatSearchMAMPagingTests, ChatSearchLocalProviderTests, ChatSearchPresentationStateTests, ChatDatasourceBoundsTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 12 — Подключить Show as List / Show as Chat

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Tasks 07, 08, 11
**Commit:** feat(chat-search): switch between chat and list modes

### Цель

Реализовать пустой сейчас onSearchPanelChangeChatViewState() через state machine, сохранив query/results/selection/keyboard и list scroll.

### Файлы

- xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift;
- xabber/controllers/chats/chat/ChatViewController.swift;
- ChatSearchPresentationState.swift;
- ChatSearchResultsListViewController.swift;
- ChatSearchBottomActionBar/SearchPanel;
- новый xabberTests/ChatSearchModeSwitchingTests.swift;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchResultsListTests, ChatSearchBottomActionBarTests, ChatSearchNavigationButtonsTests, ChatSearchPresentationStateTests, ChatSearchResultNavigationStateTests].

### Tests-first

Покрыть:

- chatResults + Show as List → listResults;
- listResults + Show as Chat → chatResults;
- query, generation, result identities и committed selection сохраняются;
- keyboard first responder сохраняется, если был открыт;
- keyboard closed остается closed;
- list scroll anchor сохраняется при list → chat → list;
- selected row автоматически видим при первом открытии list;
- arrows скрыты в list и возвращаются с boundary state в chat;
- bottom count меняется 1 of N ↔ N messages;
- title меняется Show as List ↔ Show as Chat;
- при отсутствии committed current result Show as List скрыт/disabled и reducer отклоняет переход;
- loading next page не запрещает mode switch;
- cancel из list полностью закрывает search;
- query change в list немедленно возвращает chat surface; новый list control появляется только после нового committed result;
- calendar origin запоминает list mode;
- repeated rapid toggles не создают несколько child controllers.

### Реализация

1. Подключить bottom mode callback к reducer event.
2. Создавать list child lazily один раз на active search session.
3. Держать timeline/list hierarchy в одном ChatViewController.
4. Переключать visibility/interactivity атомарно; анимация будет в Task 13.
5. Сохранять list content offset через stable top identity + offset, не сырой index.
6. Не dismiss keyboard при обычном mode switch; начало interactive drag в list вызывает endEditing, и последующие switches сохраняют закрытое состояние.
7. При cancel удалить child и reset retained scroll state.

### Критерии принятия

- Кнопка реально переключает два вида и никогда не теряет query.
- Counter/title/arrows соответствуют текущему mode.
- Повторное открытие list возвращает прежнюю позицию.
- Нет duplicate view/controllers или callbacks.
- Existing message anchor/navigation продолжает работать в chat mode.

### Post-task verification

- TEST[ChatSearchModeSwitchingTests, ChatSearchResultsListTests, ChatSearchBottomActionBarTests, ChatSearchNavigationButtonsTests, ChatSearchResultNavigationStateTests, SearchChatListKeyboardLayoutTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 13 — Реализовать Chat ↔ List transition choreography

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Tasks 05A, 12
**Commit:** feat(chat-search): animate result mode transitions

### Цель

Реализовать наблюдаемую scale/blur choreography средствами публичных UIKit API по shared spec. Полная cross-flow interruption coordination остается в Task 21.

### Файлы

- новый xabber/controllers/chats/chat/search/ChatSearchModeTransitionCoordinator.swift;
- ChatViewController+SearchBar.swift;
- ChatSearchResultsListViewController.swift;
- ChatSearchPresentationState.swift;
- новый xabberTests/ChatSearchListTransitionTests.swift;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchModeSwitchingTests, ChatSearchResultsListTests, ChatSearchPresentationStateTests, ChatSearchNavigationButtonsTests].

### Tests-first

Покрыть transition plan как pure values:

- chat → list: list sublayer scale 0.95→1 duration 0.40 spring; public blur radius/intensity equivalent 30→0 около 0.20; top/bottom/keyboard/timeline stationary;
- list → chat: list scale 1→0.95 и blur 0→30 около 0.30, затем removal; без отдельной alpha-фазы и без timeline transform;
- Reduce Motion: no scale/blur, crossfade не дольше 0.20;
- animated=false: immediate final hierarchy;
- interruption list-in → chat-out и reverse оставляет один final mode;
- repeated taps coalesce к последнему requested mode;
- transition completion не применяет stale generation;
- keyboard/safe-area constraint frames не анимируются через неверный layout;
- list removed only after out completion;
- timeline userInteraction disabled только на transition, затем восстановлен;
- no private filter class/name используется.

### Реализация

1. Создать coordinator с injectable animator factory для tests.
2. Для blur использовать snapshot/UIVisualEffectView и UIViewPropertyAnimator.
3. Взять snapshot только list content area, исключив top/bottom controls и не трансформируя timeline.
4. Удалять snapshot/blur view в completion и cancellation.
5. Синхронизировать alpha/transform с layoutIfNeeded до старта.
6. Учитывать UIAccessibility.isReduceMotionEnabled.
7. Не трогать MAM/session lifecycle при визуальном switch.

### Критерии принятия

- Transition plan и final hierarchy совпадают с reference contract; измеренный temporal tolerance ±0.05 s проверяется только Task 26B по presentation timestamps VFR-видео.
- Top search, bottom controls и keyboard не мигают.
- Нет private API/App Store risk.
- Interrupt/reverse не оставляет blur overlay или transform.
- Reduce Motion дает спокойный usable crossfade.

### Post-task verification

- TEST[ChatSearchListTransitionTests, ChatSearchModeSwitchingTests, ChatSearchResultsListTests, ChatSearchPresentationStateTests].
- Обязательная simulator build.
- git diff --check.
- Не запускать live/manual chat flow в этом Task; runtime smoke разрешен только после guarded XCUITest infrastructure в Task 24.
- Обновить UI/tests notes и journal.

---

## Task 14 — Подключить выбор строки list к anchor pipeline

**Owner:** xabber-ui
**Secondary:** xabber-xmpp, xabber-tests
**Depends on:** Tasks 11–13
**Commit:** feat(chat-search): open selected list result

### Цель

При tap по строке вернуться в chat mode и открыть именно выбранное сообщение через существующий безопасный anchor pipeline, не помечая его прочитанным автоматически.

### Файлы

- ChatSearchResultsListViewController.swift;
- ChatViewController+SearchBar.swift;
- ChatSearchPresentationState.swift;
- existing ChatOpenMessageRequest/anchor helpers;
- новый xabberTests/ChatSearchListSelectionTests.swift;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchModeSwitchingTests, ChatSearchListTransitionTests, ChatSearchResultNavigationStateTests, ChatSearchArchiveGapRepairTests, ChatOpenMessageRequestHandlingPolicyTests, ChatMessageAnchorPolicyTests].

### Tests-first

Покрыть:

- tap передает stable identity и находит актуальный index;
- list mode закрывается, query/results сохраняются;
- request source = .search и markReadOnVisible=false;
- local displayed result позиционируется без blocking loader;
- archivedId gap идет exact MAM/context path;
- empty archivedId использует documented primary/date fallback;
- committed selection/count меняется только после positioning success;
- context loading показывает loader, но не очищает results;
- positioning failure сохраняет прежний committed result и дает retry/reopen list;
- stale tap после query generation change игнорируется;
- rapid taps выбирают последний intent;
- row tap во время paging работает по уже известному DTO;
- selected row остается list scroll anchor при возврате;
- no read marker/send/delete side effect.

### Реализация

1. Передать identity callback из list в controller.
2. Resolve identity только в current generation results.
3. Начать list → chat transition и queueOpenMessageRequest через общий path.
4. Синхронизировать pending/committed selection с existing navigation state.
5. Для failed anchor снять busy и оставить recoverable UI.
6. Не создавать отдельный message-fetch механизм для list.

### Критерии принятия

- Нажатая строка открывает правильное сообщение.
- Поведение одинаково для loaded/local gap/remote context.
- Нет ложного counter advance.
- Search остается активным после list row selection.
- Message не помечается прочитанным только из-за search navigation.

### Post-task verification

- TEST[ChatSearchListSelectionTests, ChatSearchModeSwitchingTests, ChatSearchListTransitionTests, ChatSearchResultNavigationStateTests, ChatSearchArchiveGapRepairTests, ChatOpenMessageRequestHandlingPolicyTests, ChatMessageAnchorPolicyTests].
- Обязательная simulator build.
- Обновить UI/XMPP/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 15 — Зафиксировать calendar/date-selection model

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Tasks 01, 05A
**Commit:** feat(chat-search): add calendar selection model

### Цель

Создать чистую, locale/time-zone safe модель календаря с month navigation и однозначной семантикой «перейти к дате».

### Файлы

- новый xabber/controllers/chats/chat/search/ChatSearchCalendarModel.swift;
- ChatSearchPresentationState.swift;
- новый xabberTests/ChatSearchCalendarModelTests.swift;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchPresentationStateTests, ChatSearchModeSwitchingTests, ChatSearchListSelectionTests].

### Tests-first

Использовать injected Calendar, TimeZone и Clock. Покрыть:

- initial visible/selected day = injected today;
- initial selected Date = injected now; выбор другого civil day сохраняет hour/minute/time-zone components исходной selection;
- internal snapshot содержит до 42 slots, но leading/trailing outside-month slots имеют hidden/noninteractive presentation;
- visible rowCount динамически равен 4, 5 или 6 по реально занимаемым неделям;
- locale firstWeekday Sunday и Monday;
- February leap/non-leap;
- переход December ↔ January;
- DST spring/fall day replacement выполняется Calendar date components/arithmetic, не добавлением 86400 seconds;
- navigation range начинается не раньше Unix epoch и заканчивается representable timestamp `Int32.max - 1`;
- next/previous enabled вплоть до границ этого диапазона; future months/days доступны;
- choosing enabled day обновляет selection, но не меняет search query;
- Done enabled только для valid selected day;
- month title формируется DateFormatter с locale;
- month-title disclosure открывает/закрывает month/year picker и синхронизирует выбранные month/year;
- horizontal swipe вычисляет previous/next month с semantic direction и RTL-aware visual direction;
- calendar cancel event возвращает origin mode;
- completion event несет exact selected timestamp и очищает search state только на уровне reducer;
- selected `2026-07-13 10:51` после смены day не превращается в `00:00`;
- Equatable snapshots детерминированы.

### Реализация

1. Создать value model month/day cells без UIKit.
2. Использовать Calendar dateComponents/date(from:)/date(byAdding:) и сохранять time components; не нормализовать selection до midnight.
3. Inject now, calendar, locale/timeZone для tests.
4. Minimum по умолчанию — Unix epoch; maximum — Date(timeIntervalSince1970: TimeInterval(Int32.max - 1)), если product resolver не докажет более строгий representable limit.
5. В model не выполнять Realm/MAM search.
6. Явно назвать semantics dateJump, не dateRangeFilter.

### Критерии принятия

- Calendar корректен во всех tested locales/time zones.
- Future selection и month navigation доступны в пределах representable range.
- Model не зависит от UIKit/XMPP/Realm.
- Calendar X и Done дают разные reducer events.
- Термин «filter» в UI не обещает диапазонную фильтрацию, которой нет в Telegram reference.

### Post-task verification

- TEST[ChatSearchCalendarModelTests, ChatSearchPresentationStateTests, ChatSearchModeSwitchingTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 16 — Создать Telegram-style calendar UIKit view

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Task 15
**Commit:** feat(chat-search): add calendar date picker view

### Цель

Построить custom UIKit calendar surface с header, month navigation, weekday/day grid и primary Done, совместимую с iOS 15.6.

### Файлы

- новый xabber/controllers/chats/chat/search/ChatSearchCalendarView.swift;
- новый xabber/controllers/chats/chat/search/ChatSearchCalendarDayCell.swift;
- ChatSearchCalendarModel.swift;
- новый xabberTests/ChatSearchCalendarViewTests.swift;
- localization resources при необходимости;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchCalendarModelTests, ChatSearchTopChromeTests, ChatSearchBottomActionBarTests].

### Tests-first

Покрыть:

- root surface rounded top corners/system background/public glass fallback;
- header title Search centered;
- detached/circular X расположен leading/top-left, hit target 44 × 44 и identifier chat_search_calendar_close;
- month title является disclosure control с identifier chat_search_calendar_month и открывает month/year picker;
- previous/next buttons не меньше 44 × 44 и корректно enabled/disabled;
- weekday labels = 7, internal day slots ≤ 42; outside-month slots не рисуют число и не получают interaction/accessibility element;
- grid/sheet height динамически меняется между 4–6 week rows без clipped intermediate frame;
- cell selected/today/disabled visual states; future day не disabled только из-за текущей даты;
- selected day имеет blue filled circle и readable contrast;
- grid width не превышает 390 pt и равномерно делится на 7 columns;
- layout помещается на iPhone 16e portrait без clipping;
- month/year picker имеет отдельные month/year controls, выбранное значение и детерминированное close/apply behavior;
- horizontal swipe меняет месяц за 0.30 s по ChatSearchAnimationSpec; одновременно синхронизируются title/grid/picker;
- primary Done height 52 pt, horizontal inset около 30 pt, bottom safe-area inset;
- identifiers chat_search_calendar, chat_search_calendar_previous_month, chat_search_calendar_next_month, chat_search_calendar_day, chat_search_calendar_done;
- Dynamic Type title/button labels не overlap grid;
- RTL меняет direction month controls/grid consistently;
- light/dark/high-contrast colors;
- reuse day cell очищает selection/today state.

### Реализация

1. Использовать UICollectionView с fixed 7-column layout либо custom grid layout.
2. View получает immutable model snapshot и callbacks.
3. Использовать system/SF symbols или Xabber assets.
4. Не использовать UICalendarView как единственную implementation; один custom path для parity.
5. Done оформить Xabber blue primary button, height 52.
6. Не добавлять time/repeat/scheduling controls.

### Критерии принятия

- Layout policy фиксирует reference hierarchy/nominal metrics; измеренный допуск ≤ 2 pt подтверждается только Task 26B.
- Все internal slots стабильны; видимы только 4–6 current-month rows, outside-month slots blank/noninteractive.
- Экран usable на iOS 15.6+.
- Нет Telegram assets/branding/private API.
- VoiceOver может различить selected/today/disabled days.

### Post-task verification

- TEST[ChatSearchCalendarViewTests, ChatSearchCalendarModelTests, ChatSearchTopChromeTests, ChatSearchBottomActionBarTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 17 — Реализовать calendar overlay и его transition

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Tasks 05A, 07, 12–13, 15–16
**Commit:** feat(chat-search): present calendar overlay

### Цель

Открывать calendar из leading bottom control поверх chat/list, согласованно убирать keyboard и анимировать dim/sheet.

### Файлы

- новый xabber/controllers/chats/chat/search/ChatSearchCalendarViewController.swift;
- ChatSearchCalendarView.swift;
- ChatViewController+SearchBar.swift;
- ChatSearchPresentationState.swift;
- новый xabberTests/ChatSearchCalendarPresentationTests.swift;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchCalendarViewTests, ChatSearchCalendarModelTests, ChatSearchModeSwitchingTests, ChatSearchListTransitionTests, SearchChatListKeyboardLayoutTests].

### Tests-first

Покрыть:

- calendar button из chat/list dispatches openCalendar с правильным origin;
- keyboard resign выполняется до sheet final layout;
- underlying chat/list/query/results/selection остаются неизменны;
- dim alpha target 0.5 и in duration около 0.40;
- sheet начинается ниже screen и приходит spring-анимацией;
- X out duration около 0.30 и возвращает origin;
- после X keyboard автоматически не появляется, как в видео, но input может получить focus по tap;
- tap outside/interactive drag не закрывает overlay по явной Xabber policy; не маркировать это как подтвержденную Telegram semantics;
- presentation idempotent: второй tap не создает второй overlay;
- rotation/safe-area update сохраняет selected month/day;
- app background/foreground during animation заканчивается в валидном state;
- Reduce Motion использует fade/short slide;
- out completion удаляет dim/controller containment;
- accessibility focus переходит на title/selected day и возвращается на calendar button после X.

### Реализация

1. Использовать over-current-context child/presentation внутри ChatViewController без новой navigation stack.
2. Сначала endEditing/resignFirstResponder и layout bottom guide.
3. Добавить dim view и bottom rounded surface.
4. Animator сделать interruptible и generation-aware.
5. X вызывает cancelCalendar; не вызывает provider/timestamp resolver.
6. Скрыть arrows на время calendar, оставить top/bottom under dim.
7. Не очищать query/list on cancel.

### Критерии принятия

- Presentation plan соответствует reference contract; measured geometry/timing подтверждается только в Task 26B.
- Calendar доступен из chat и list.
- X полностью сохраняет search state и selected result.
- После закрытия стрелки снова работают.
- Нет orphan dim/sheet после interruption.

### Post-task verification

- TEST[ChatSearchCalendarPresentationTests, ChatSearchCalendarViewTests, ChatSearchCalendarModelTests, ChatSearchModeSwitchingTests, ChatSearchListTransitionTests, ChatSearchNavigationButtonsTests, SearchChatListKeyboardLayoutTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 18 — Реализовать local timestamp resolver

**Owner:** xabber-business
**Secondary:** xabber-xmpp, xabber-ui, xabber-tests
**Depends on:** Tasks 02, 04, 15
**Commit:** feat(chat-search): resolve date jumps locally

### Цель

Найти лучший local message anchor для selected day без main-thread Realm и с deterministic fallback.

### Файлы

- новый xabber/models/chat_search/ChatSearchTimestampResolver.swift или xabber/common/chat_search/ChatSearchTimestampResolver.swift;
- MessageStorageItem query helpers;
- ChatSearchResult identity DTO либо отдельный anchor DTO;
- новый xabberTests/ChatSearchTimestampLocalResolverTests.swift;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchCalendarModelTests, ChatSearchResultPresentationTests, ChatMessageAnchorPolicyTests, ChatFirstFrameLocalHistoryRegressionTests].

### Tests-first

Использовать isolated in-memory Realm и восстановление config. Покрыть:

- scope owner/jid/conversationType;
- deleted/system/other chat items исключены;
- выбирается earliest message at/after exact selected timestamp;
- если после timestamp нет message — latest message before exact timestamp;
- message точно на selected timestamp включается;
- same-date tie deterministic по archivedId/primary;
- displayed datasource candidate может быть использован без Realm query;
- local archive coverage proof сообщает, достаточен ли local answer;
- encrypted chat всегда завершает resolver локально;
- regular/group incomplete coverage возвращает needsRemote с bounded candidates, а не ложный final;
- DST/locale boundaries;
- resolver возвращает detached identity/date;
- cancellation до Realm completion не применяет result;
- никакой real account Realm не затронут.
- resolver API не импортирует UIKit и возвращает detached anchor DTO/typed outcome.

### Реализация

1. Ввести typed outcome: resolvedLocal, needsRemote, noMessage, cancelled.
2. Сначала проверить displayed/current dataset.
3. Затем background Realm query.
4. Опираться на существующий archive coverage только как proof, не модифицировать его.
5. Не открывать message и не менять UI внутри resolver.
6. Для OMEMO не делать remote fallback.
7. UI adapter получает resolver через protocol/injection и не выполняет Realm query.

### Критерии принятия

- Resolver детерминирован для date with/without messages.
- Incomplete regular/group local archive не выдается за complete.
- Encrypted date jump не утечет в MAM.
- Нет main-thread Realm scan.
- Все тесты изолированы от simulator account.

### Post-task verification

- TEST[ChatSearchTimestampLocalResolverTests, ChatSearchCalendarModelTests, ChatMessageAnchorPolicyTests, ChatFirstFrameLocalHistoryRegressionTests, ChatArchiveCoverageCommitPolicyTests].
- Обязательная simulator build.
- Обновить UI/XMPP/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 19 — Добавить MAM timestamp fallback

**Owner:** xabber-xmpp
**Secondary:** xabber-ui, xabber-tests
**Depends on:** Tasks 04, 18
**Commit:** feat(chat-search): resolve date jumps through MAM

### Цель

Когда local archive недостаточен, найти message around selected timestamp через bounded MAM requests, не меняя text-search query shape и normal archive coverage.

### Файлы

- MessageArchiveManager.swift;
- при необходимости ChatSearchArchiveSession/новый ChatTimestampArchiveResolver.swift;
- ChatSearchTimestampResolver.swift boundary;
- новый xabberTests/ChatSearchTimestampMAMResolverTests.swift;
- существующие archive request classification/paging/completion tests;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchTimestampLocalResolverTests, ChatSearchMAMPagingTests, ChatHistoryPageCompletionPolicyTests, ChatArchiveCoverageCommitPolicyTests, ChatRemoteHistoryApplyPolicyTests, ChatMessageAnchorPolicyTests].

### Tests-first

Покрыть:

- remote path только для regular/group with incomplete local coverage;
- request 1 ищет first message at/after exact selected timestamp с owner/jid scope, max=1 и без withtext;
- если after-result отсутствует, request 2 ищет latest before selected timestamp, max=1;
- direction-specific stanza test для first-at/after проверяет `start` boundary, forward RSM/max=1 и отсутствие `withtext`/before flip;
- direction-specific stanza test для latest-before проверяет `end` boundary, reverse/before RSM/max=1 и отсутствие `withtext`/after cursor;
- final IQ без result корректно завершает attempt;
- archivedId/primary/date возвращаются после persistence proof;
- terminal callback не выдается до завершения существующего archive persistence path и последующего detached lookup;
- stale generation/cancel игнорируют page/final callbacks;
- error снимает loading и не запускает infinite fallback;
- repeated RSM/callback не вызывает duplicate completion;
- request purpose не обновляет regular archive coverage/history cursor;
- encrypted conversation никогда не отправляет request;
- server stanza остается XEP-0313 start/end/RSM совместимым;
- no result обоих направлений дает noMessage.

### Реализация

1. Добавить отдельный request purpose/consumer callback для timestamp lookup, не смешивая withtext session.
2. Переиспользовать requestArchive start/end/max/flipPage, но зафиксировать в request-plan/stanza tests точное направление и RSM shape каждого из двух запросов.
3. Дождаться final IQ/persistence перед callback.
4. Ограничить максимум двумя одноэлементными запросами и generation guard.
5. Не менять backend/server.
6. Не коммитить archive coverage на основании lookup.

### Критерии принятия

- Date jump работает при отсутствии нужного диапазона локально.
- Максимум два bounded MAM request.
- Text query test не передается в date lookup.
- Нет contamination normal sync state.
- Cancel/error/no-result всегда terminal.

### Post-task verification

- TEST[ChatSearchTimestampMAMResolverTests, ChatSearchTimestampLocalResolverTests, ChatSearchMAMPagingTests, ChatHistoryPageCompletionPolicyTests, ChatArchiveCoverageCommitPolicyTests, ChatRemoteHistoryApplyPolicyTests, ChatMessageAnchorPolicyTests].
- Обязательная simulator build.
- Обновить XMPP/UI/tests notes, shared/interfaces.md, handoff и journal.
- git diff --check после documentation edits.

---

## Task 20 — Подключить Calendar Done к date jump

**Owner:** xabber-ui
**Secondary:** xabber-xmpp, xabber-tests
**Depends on:** Tasks 17–19
**Commit:** feat(chat-search): navigate to selected calendar date

### Цель

Завершить Telegram semantics: Done закрывает calendar и text search/list, resolves timestamp и открывает target через existing anchor pipeline; X по-прежнему ничего не сбрасывает.

### Файлы

- ChatSearchCalendarViewController/View;
- ChatViewController+SearchBar.swift;
- ChatSearchPresentationState.swift;
- ChatSearchTimestampResolver.swift;
- existing ChatOpenMessageRequest helpers;
- новый xabberTests/ChatSearchCalendarCompletionTests.swift;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchCalendarPresentationTests, ChatSearchTimestampLocalResolverTests, ChatSearchTimestampMAMResolverTests, ChatOpenMessageRequestHandlingPolicyTests, ChatMessageAnchorPolicyTests, ChatSearchModeSwitchingTests].

### Tests-first

Покрыть:

- X: zero resolver calls, query/results/selection/origin сохранены;
- Done с valid day: calendar out начинается один раз, search/list очищаются, composer/nav state восстанавливаются;
- Done показывает resolvingDate loading без блокировки account/session;
- local resolved target queues ChatOpenMessageRequest source .search, markReadOnVisible=false;
- remote resolved target использует тот же anchor pipeline;
- result position centered и без text highlight после search exit;
- noMessage: loader снимается, chat остается на прежней позиции и VoiceOver получает localized announcement; никаких destructive side effects;
- error: loader снимается, nonblocking recoverable indication, no retry loop;
- cancel/navigation away/background отменяют resolver;
- double Done не создает duplicate request;
- stale completion после нового chat/search игнорируется;
- calendar from list также сбрасывает list on successful Done;
- normal X search cancel без calendar остается неизменным.

### Реализация

1. Done dispatches completeCalendarDate(exactSelectedTimestamp), сохраняя hour/minute selection.
2. Закрыть overlay и перевести presentation state в resolvingDate.
3. Restore normal chat chrome/composer по Telegram parity до/во время lookup.
4. Запустить local resolver, затем bounded remote fallback при needsRemote.
5. Queue existing search anchor request с markReadOnVisible=false.
6. Завершить loading на success/no-result/error/cancel.
7. Не добавлять новый read/send/delete behavior.

### Критерии принятия

- Calendar X сохраняет search; Done завершает search и прыгает к дате.
- Поведение одинаково из chat/list origins.
- No result/error не оставляют spinner или broken UI.
- Anchor safety, unread state и account state сохранены.
- Flow X/cancel vs Done и exact timestamp resolver соответствуют наблюдаемому reference contract.

### Post-task verification

- TEST[ChatSearchCalendarCompletionTests, ChatSearchCalendarPresentationTests, ChatSearchTimestampLocalResolverTests, ChatSearchTimestampMAMResolverTests, ChatOpenMessageRequestHandlingPolicyTests, ChatMessageAnchorPolicyTests, ChatSearchModeActivationTests].
- Обязательная simulator build.
- Обновить UI/XMPP/tests notes, shared/interfaces.md и journal.
- git diff --check после documentation edits.

---

## Task 21 — Унифицировать search/navigation animation choreography

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Tasks 05A, 06–08, 13, 17, 20
**Commit:** feat(chat-search): match search motion choreography

### Цель

Подключить уже существующий ChatSearchAnimationSpec ко всем controls и довести cross-flow interruption, cleanup и haptic sequencing. В этом Task не переопределять базовые durations Tasks 05A/13/17.

### Файлы

- существующий xabber/controllers/chats/chat/search/ChatSearchAnimationSpec.swift;
- ChatSearchModeTransitionCoordinator.swift;
- ChatSearchCalendarViewController.swift;
- ChatSearchNavigationView/BottomActionBar/NavigationButtonsView;
- ChatViewController+SearchBar.swift;
- новый xabberTests/ChatSearchModeTransitionTests.swift;
- project.pbxproj.

### Pre-task tests

- TEST[ChatSearchTopChromeTests, ChatSearchBottomActionBarTests, ChatSearchNavigationButtonsTests, ChatSearchListTransitionTests, ChatSearchCalendarPresentationTests, ChatSearchResultNavigationStateTests].

### Tests-first

Покрыть:

- search enter/exit animation consumers и final transforms/alpha используют injected shared spec;
- top field/X и bottom capsules появляются согласованно, без layout jump;
- calendar/count control insertion: alpha 0→1, scale 0.01→1; removal reverse;
- arrows: 0.30 s spring, scale 0.2↔1;
- counter digit transition 0.25 s ease-in-out и правильное направление old/new digits;
- result navigation haptic только после successful positioning, не на tap/failure/stale completion;
- list in/out plan из Task 13 не меняется;
- calendar/month-swipe plan из Tasks 16–17 не меняется;
- active navigation transition или first-frame preparation может потребовать non-animated mutation;
- interactive keyboard dismissal обновляет bottom/floating constraints без double animation;
- Reduce Motion выключает spring/scale/blur и сохраняет короткий fade;
- animation interrupted by cancel/query/list/calendar/background ends in reducer state;
- completion callbacks generation-guarded;
- no animation object/closure retain cycle.

### Реализация

1. Удалить оставшиеся локальные magic durations и читать constants/curves из ChatSearchAnimationSpec, созданного Task 05A.
2. Использовать UIViewPropertyAnimator/spring timing, где нужно interruption.
3. Применять transforms к content hosts, не Auto Layout-owned root frames.
4. Добавить единый cleanupAnimations(finalState:).
5. Уважать UIAccessibility.isReduceMotionEnabled и navigation mutation policy.
6. Haptic generator prepare до ожидаемого success, selectionChanged только после commit.
7. Не анимировать network wait duration.

### Критерии принятия

- Все consumers используют один reference-derived timing contract; измеренный допуск ±0.05 s проверяется Task 26B.
- Нет flicker/jump top/bottom/keyboard.
- Rapid switch/cancel всегда заканчивается в правильном state.
- Haptic соответствует реально открытому message.
- Reduce Motion полностью usable.

### Post-task verification

- TEST[ChatSearchModeTransitionTests, ChatSearchListTransitionTests, ChatSearchCalendarPresentationTests, ChatSearchNavigationButtonsTests, ChatSearchBottomActionBarTests, ChatSearchTopChromeTests, ChatSearchResultNavigationStateTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal.
- git diff --check после documentation edits.

---

## Task 22A — Локализовать search flow и форматирование

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Task 21
**Commit:** feat(chat-search): localize search interface

### Цель

Удалить hard-coded visible copy и создать единый locale-aware contract для counter, дат, календаря, sender title и error/empty states. Не смешивать эту задачу с VoiceOver/layout fixes.

### Файлы

- ChatSearch views/models/formatters, содержащие visible strings;
- xabber/translations/*/Localizable.strings и существующие pluralization resources проекта;
- при необходимости новый xabber/controllers/chats/chat/search/ChatSearchFormatting.swift;
- новый xabberTests/ChatSearchLocalizationTests.swift;
- xabber.xcodeproj/project.pbxproj.

### Pre-task tests

- TEST[ChatSearchResultPresentationTests, ChatSearchBottomActionBarTests, ChatSearchResultCellTests, ChatSearchCalendarModelTests, ChatSearchCalendarViewTests, ChatSearchCalendarCompletionTests].

### Tests-first

ChatSearchLocalizationTests должен покрыть:

- production search flow не содержит hard-coded `Show as List`, `Show as Chat`, `Search`, `Done`, `No Results`, `Error`, `You`;
- singular/plural для `1 message`, `2 messages`, zero/many во всех существующих plural categories системы проекта;
- `current of total` формируется locale-aware и не создает `0 of N`;
- numeric date list row соответствует locale, но сохраняет compact reference hierarchy;
- month title/weekday labels используют injected locale/calendar;
- outgoing sender title `You` и accessibility-facing earlier/later terms локализованы;
- error/no-message/retry announcements имеют отдельные keys;
- missing translation имеет deterministic development fallback без пустой кнопки;
- форматтеры кешируются безопасно и не шарятся между несовместимыми locale/time-zone values;
- смена locale в injected tests не меняет stable identifiers/state identity.

### Реализация

1. Добавить keys в реальный путь `xabber/translations/<locale>.lproj/Localizable.strings`; не использовать Base.lproj, которого flow не применяет для strings.
2. Использовать существующий Xabber localization API и String Catalog/.stringsdict только если он уже принят проектом.
3. Вынести DateFormatter/NumberFormatter/Calendar construction в injectable formatter boundary.
4. Не переводить accessibility identifiers и stable result IDs.
5. Зафиксировать terminology: UI control называется calendar/date jump, а не date-range filter.

### Критерии принятия

- Все visible strings flow получаются из localization resources.
- Counts/date/month/weekdays корректны минимум для en и ru test locales.
- List row сохраняет plain snippet и compact numeric date.
- Missing key не приводит к пустому/неинтерактивному control.
- Изменение locale не меняет query/result/navigation state.

### Post-task verification

- TEST[ChatSearchLocalizationTests, ChatSearchResultPresentationTests, ChatSearchBottomActionBarTests, ChatSearchResultCellTests, ChatSearchResultsListTests, ChatSearchCalendarModelTests, ChatSearchCalendarViewTests, ChatSearchCalendarCompletionTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal, затем git diff --check.

---

## Task 22B — Зафиксировать accessibility semantics и automation identifiers

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Task 22A
**Commit:** feat(chat-search): add accessible search semantics

### Цель

Сделать search/list/calendar полностью управляемыми VoiceOver и предоставить стабильные semantic hooks для будущего XCUITest, не полагаясь на видимый текст.

### Файлы

- все ChatSearch controls/cells/view controllers;
- entry search button в ChatViewController/Info Card routing;
- новый xabberTests/ChatSearchAccessibilityTests.swift;
- InfoCardSearchAccessibilityTests;
- xabber.xcodeproj/project.pbxproj.

### Pre-task tests

- TEST[ChatSearchLocalizationTests, InfoCardSearchAccessibilityTests, ChatSearchTopChromeTests, ChatSearchBottomActionBarTests, ChatSearchNavigationButtonsTests, ChatSearchResultCellTests, ChatSearchCalendarViewTests].

### Tests-first

Покрыть стабильные identifiers и отсутствие дублей:

- `chat_search_entry`, `chat_search_top_bar`, `chat_search_input`, `chat_search_submit`, `chat_search_clear`, `chat_search_cancel`, `chat_search_loading`;
- `chat_search_results_panel`, `chat_search_results_count`, `chat_search_view_mode_control`, `chat_search_calendar_button`;
- `chat_search_previous_result`, `chat_search_next_result`;
- `chat_search_results_list`, `chat_search_result_row`, `chat_search_results_empty`, `chat_search_results_error`, `chat_search_results_paging`;
- `chat_search_calendar`, `chat_search_calendar_close`, `chat_search_calendar_month`, `chat_search_calendar_previous_month`, `chat_search_calendar_next_month`, `chat_search_calendar_month_year_picker`, `chat_search_calendar_day`, `chat_search_calendar_done`.

Также проверить:

- каждый interactive control имеет localized label, актуальный value, button/selected/disabled traits и полезный hint только там, где он не дублирует label;
- counter accessibilityValue обновляется только после committed positioning;
- arrows названы семантически: предыдущий/более старый и следующий/более новый result; boundary disabled объявляется;
- `1 of N` соответствует newest; row accessibility объединяет sender, plain snippet, date и Xabber delivery state;
- outside-month blank calendar slots отсутствуют в accessibility tree;
- selected/today day различимы не только цветом;
- VoiceOver order: top field → top X → timeline/list → floating arrows → bottom calendar/count → mode control;
- calendar focus при открытии переходит на title/selected day, после X возвращается на calendar button;
- hidden/animated-out controls не hittable и не accessibility elements;
- UI automation может пройти flow только по identifiers и values, не используя visible localized copy.

### Реализация

1. Сохранить legacy identifiers, перенеся их на семантически эквивалентные новые controls.
2. Добавить недостающие identifiers один раз в ближайшем owning view.
3. Настроить accessibilityElement ordering/containers для chat/list/calendar.
4. Добавить localized announcements для no result, date noMessage и positioning failure без избыточного chatter.
5. Не запускать live-account VoiceOver flow до Task 24; здесь использовать unit/layout harness.

### Критерии принятия

- Все действия search/list/arrows/calendar достижимы по VoiceOver semantics.
- Stable IDs достаточно для XCUITest без text matching.
- Counter/current/day values соответствуют committed state.
- Hidden controls не остаются в VoiceOver tree.
- Existing Info Card → chat search automation contract сохранен.

### Post-task verification

- TEST[ChatSearchAccessibilityTests, ChatSearchLocalizationTests, InfoCardSearchAccessibilityTests, ChatSearchTopChromeTests, ChatSearchBottomActionBarTests, ChatSearchNavigationButtonsTests, ChatSearchResultCellTests, ChatSearchResultsListTests, ChatSearchCalendarViewTests, ChatSearchCalendarPresentationTests].
- Обязательная simulator build.
- Обновить UI/tests notes и journal, затем git diff --check.

---

## Task 22C — Адаптировать Dynamic Type, RTL, contrast и transparency

**Owner:** xabber-ui
**Secondary:** xabber-tests
**Depends on:** Task 22B
**Commit:** fix(chat-search): harden adaptive search layout

### Цель

Зафиксировать usable layout и visual affordances при больших шрифтах, RTL, Increase Contrast, Differentiate Without Color, Reduce Transparency и Reduce Motion, сохранив reference hierarchy.

### Файлы

- ChatSearchNavigationView/BottomActionBar/NavigationButtonsView;
- ChatSearchResultCell/ResultsListViewController;
- ChatSearchCalendarView/DayCell/ViewController;
- ChatSearchAnimationSpec/transition coordinators;
- новый xabberTests/ChatSearchAdaptiveLayoutTests.swift;
- xabber.xcodeproj/project.pbxproj.

### Pre-task tests

- TEST[ChatSearchAccessibilityTests, ChatSearchLocalizationTests, ChatSearchTopChromeTests, ChatSearchBottomActionBarTests, ChatSearchResultCellTests, ChatSearchCalendarViewTests, ChatSearchAnimationSpecTests, ChatSearchModeTransitionTests].

### Tests-first

Покрыть:

- Dynamic Type от default до accessibilityExtraExtraExtraLarge: top input single-line scrollable, controls не имеют zero/overlapping hit frames;
- result row увеличивает height по policy либо приоритетно truncates snippet, не скрывая sender/date/status;
- calendar title/picker/weekdays/day circles и Done не clip при large content size;
- visible 40 pt circles имеют minimum 44 × 44 accessibility hit area;
- RTL зеркалит leading/trailing layout, month swipe visual direction и disclosure/picker, но earlier/older vs later/newer semantics не меняются;
- Increase Contrast сохраняет границы glass capsules и readable selection;
- Differentiate Without Color добавляет non-color selected/today cue;
- Reduce Transparency выбирает opaque system-material fallback и не запускает blur animator;
- Reduce Motion использует shared short crossfade/immediate final states;
- light/dark/high-contrast colors проходят проектный contrast policy;
- rotation/compact width/keyboard interactive dismissal не создают constraint warnings или overlap.

### Реализация

1. Настроить contentCompressionResistance/hugging/minimum hit areas и trait-change rendering.
2. Использовать leading/trailing/semanticContentAttribute вместо ручного зеркального frame math.
3. Подключить ChatSearchAnimationSpec accessibility variants ко всем consumers.
4. Сохранить nominal reference geometry для default category; adaptive отклонения документировать как accessibility requirement.
5. Не добавлять отдельный alternate screen или горизонтальный scroll всей панели.

### Критерии принятия

- Flow usable при максимальном Dynamic Type без недоступных controls.
- RTL сохраняет правильную смысловую навигацию и calendar direction.
- State различим без reliance only on color/transparency/motion.
- Нет private blur API и Auto Layout warnings в tested matrices.
- Nominal/default layout остается неизменным относительно Tasks 06–17.

### Post-task verification

- TEST[ChatSearchAdaptiveLayoutTests, ChatSearchAccessibilityTests, ChatSearchLocalizationTests, ChatSearchTopChromeTests, ChatSearchBottomActionBarTests, ChatSearchNavigationButtonsTests, ChatSearchResultCellTests, ChatSearchResultsListTests, ChatSearchCalendarViewTests, ChatSearchCalendarPresentationTests, ChatSearchAnimationSpecTests, ChatSearchModeTransitionTests].
- Обязательная simulator build.
- Обновить UI/tests notes, durable accessibility contract при необходимости и journal, затем git diff --check.

---

## Task 23 — Добавить безопасный opt-in XCUITest target

**Owner:** xabber-tests
**Secondary:** xabber-ui
**Depends on:** Task 22C
**Commit:** test(chat-search): add guarded UI test target

### Цель

Создать xabberUITests target и safety gate, который по умолчанию skip-ает live-account scenarios до app.launch и не содержит destructive setup/teardown.

### Файлы

- xabber.xcodeproj/project.pbxproj;
- tracked shared scheme `xabber.xcodeproj/xcshareddata/xcschemes/Debug.xcscheme` (в workspace отображается как `Debug (xabber project)`);
- новый каталог xabberUITests/;
- новый xabberUITests/ChatSearchLiveQASafetyGate.swift;
- новый xabberUITests/ChatSearchLiveSmokeTests.swift со skeleton skip;
- новый xabberTests/ChatSearchLiveQASafetyPolicyTests.swift.

### Pre-task tests

- Запустить B0.
- TEST[ChatSearchAccessibilityLocalizationTests, ChatSearchModeTransitionTests, ChatSearchCalendarCompletionTests].

### Tests-first

Так как target отсутствует, TDD последовательность для project scaffolding:

1. Добавить policy unit tests и убедиться, что они red из-за отсутствующей policy.
2. Реализовать policy.
3. Добавить UI target/skeleton и проверить compile/skip path.

Покрыть:

- env XABBER_LIVE_SEARCH_QA отсутствует/не равен 1 → XCTSkip до создания и launch XCUIApplication;
- opt-in требует expected simulator UDID либо explicit override;
- safety policy запрещает launch arguments/env, содержащие reset, erase, logout, remove-account, delete-data, clean-realm;
- target не имеет test setup, которое удаляет app/container;
- compile-only/non-opt-in path не запускает app и не меняет data-container identity;
- dialog candidates фиксированы как Andrew Nenakhov, затем Alexey Boldin;
- query фиксирован как test;
- при live opt-in missing signed-in state/dialog дает explicit failure/blocker, а не login automation; без opt-in остается ранний XCTSkip;
- teardown только cancel search/terminate process, без data cleanup;
- UI bundle компилируется и normal non-opt-in run дает skipped test.

### Реализация

1. Добавить UI testing bundle target `xabberUITests`, host/target application `xabber`, deployment target 15.6, уникальный test bundle identifier и explicit target dependency.
2. Включить target в tracked `xabber.xcodeproj/xcshareddata/xcschemes/Debug.xcscheme` TestAction; не опираться на ignored user-local scheme.
3. Не добавлять test plan с resetApplicationData.
4. Safety gate проверить до создания/launch XCUIApplication.
5. Добавить source comments с абсолютными запретами.
6. Не запускать UI test executable даже ради ожидаемого XCTSkip: compile target через build-for-testing, чтобы до Task 24 приложение не install/launch-илось.

### Критерии принятия

- xabberUITests target виден в scheme и компилируется.
- Guard policy unit tests доказывают default explicit skip; UI bundle compile-only verification не запускает приложение.
- Data-container path существующей app не меняется.
- Нет destructive commands/launch flags.
- Unit policy tests защищают guard от будущего ослабления.
- Existing unit target/build не сломаны.

### Post-task verification

- TEST[ChatSearchLiveQASafetyPolicyTests, ChatSearchAccessibilityLocalizationTests, InfoCardSearchAccessibilityTests].
- Compile-only UI target с теми же cache paths, потому что wrapper не поддерживает `build-for-testing`:

~~~bash
XABBER_CACHE_ROOT="${XABBER_XCODE_CACHE_ROOT:-$HOME/Library/Caches/XabberCodex/xabber-ios-core}"
xcodebuild \
  -workspace xabber.xcworkspace \
  -scheme 'Debug (xabber project)' \
  -destination 'platform=iOS Simulator,id=7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF' \
  -derivedDataPath "$XABBER_CACHE_ROOT/DerivedData" \
  -clonedSourcePackagesDirPath "$XABBER_CACHE_ROOT/SourcePackages" \
  -packageCachePath "$XABBER_CACHE_ROOT/PackageCache" \
  -skipPackageUpdates \
  -onlyUsePackageVersionsFromResolvedFile \
  build-for-testing \
  -parallel-testing-enabled NO \
  -only-testing:xabberUITests/ChatSearchLiveSmokeTests \
  ONLY_ACTIVE_ARCH=YES \
  COMPILER_INDEX_STORE_ENABLE=NO
~~~

- Подтвердить `** TEST BUILD SUCCEEDED **`; не вызывать `test-without-building` в этом Task.
- Сравнить exact data-container path до/после compile-only run.
- Обязательная simulator build.
- Обновить tests/UI notes и journal.
- git diff --check после documentation edits.

---

## Task 24 — Реализовать non-destructive live search smoke

**Owner:** xabber-tests
**Secondary:** xabber-ui
**Depends on:** Task 25E
**Commit:** test(chat-search): cover live search parity flow

### Цель

Автоматизировать non-destructive navigation/search scenario на уже существующем аккаунте iPhone 16e и приложить screenshots ключевых states. Открытие реального чата может штатно изменить last-read position, unread badge или отправить обычный displayed/read receipt; это разрешенные read-effects. Запрещены send/edit/delete, logout/remove account, credential changes и любой reset/storage cleanup.

### Файлы

- xabberUITests/ChatSearchLiveSmokeTests.swift;
- xabberUITests/ChatSearchLiveQASafetyGate.swift;
- production accessibility identifiers только если обнаружен пробел;
- новый/обновленный xabberTests/ChatSearchLiveQASafetyPolicyTests.swift.

### Pre-task tests

- TEST[ChatSearchLiveQASafetyPolicyTests, ChatSearchAccessibilityTests, ChatSearchLocalizationTests, ChatSearchModeSwitchingTests, ChatSearchCalendarCompletionTests].
- Guarded UI test без opt-in должен снова skip до app launch.

### Tests-first

Live test должен:

1. Проверить opt-in и simulator identity до app.launch.
2. Запустить xabber без reset arguments.
3. Если виден login/onboarding — XCTFail + durable blocker; не вводить credentials.
4. Найти Andrew Nenakhov; fallback Alexey Boldin; если обоих нет — XCTFail + durable blocker, без login/contact creation/recovery.
5. Открыть chat, не отправлять message.
6. Открыть search через chat_search_entry.
7. Ввести ровно test.
8. Дождаться одного terminal outcome с bounded predicate wait: committed count при исчезнувшем provider paging/loading indicator, No Results или typed error; incremental count сам по себе не считается terminal. Error — failure.
9. Если Andrew дает No Results, закрыть search/chat обычными UI controls и повторить ровно в Alexey. Если оба дают zero results — XCTFail + blocker; Task/Goal не закрывать.
10. Приложить screenshot chat result и применить deterministic branch:
    - ровно 1 result: counter `1 of 1`, обе arrows visible/disabled, list содержит ровно одну row и `1 message`;
    - 2+ results: на `1 of N` lower/newer disabled, upper/older enabled; перейти к более старому, вернуть newer, затем через last list row проверить oldest boundary и отсутствие wrap;
    - 0 results: list control отсутствует и выполняется fallback policy предыдущего пункта.
11. Нажать Show as List, проверить newest-first row order/list count/plain snippets и приложить screenshot.
12. Начать interactive drag list и доказать dismissal keyboard; вернуться Show as Chat, затем обычным tap input восстановить keyboard и проверить, что последующие mode switches сохраняют текущее keyboard state.
13. Открыть calendar, проверить leading X, dynamic 4–6-row grid, month/year disclosure, future next-month availability и Done; приложить screenshot.
14. Закрыть calendar через X и проверить, что query test/current result сохранились, а keyboard автоматически не восстановилась.
15. Закрыть search через top X.
16. Проверить, что chat остается открыт и login/onboarding screen не появился.

Отдельно покрыть helper/predicate behavior:

- exact timeout policy: app shell 30 s; dialog lookup 20 s на candidate; search entry/input 10/5 s; terminal results 45 s; each mode/calendar transition 5 s; final signed-in shell 10 s; global live test budget 180 s;
- каждый timeout использует predicate/waitForExistence и прикладывает hierarchy screenshot + current identifiers; `sleep` запрещен;
- fallback dialog ordering;
- parser count values 1 of 2 / N messages;
- no visible-text-only lookup, если identifier доступен;
- teardown не нажимает send/delete/logout.
- Добавить второй `testCalendarDateJumpForKnownResult` с отдельным gate `XABBER_LIVE_SEARCH_DATE_JUMP_QA=1`: в Task 24 он только компилируется/skip-ается до app launch; фактически запускается и записывается Task 26B после final install.

### Реализация

1. Использовать XCTestExpectation/NSPredicate waits с указанными exact timeout values, без sleep.
2. Делать screenshot attachments с именами 01-chat, 02-list, 03-calendar, 04-restored.
3. Не выбирать Calendar Done в live smoke до final controlled QA; X достаточно для state-preservation test.
4. В date-jump helper подготовить выбор даты из committed result row и exact-timestamp assertions, но защитить вторым opt-in до Task 26B.
5. После failure выполнить только app.terminate; не нажимать destructive recovery controls.
6. Не скрывать server/data blocker как product pass.

### Критерии принятия

- Test проходит на существующем iPhone 16e в одном из двух диалогов с query test; оба zero-results являются blocker, не pass/skip.
- Account остается на месте; допускаются только обычные read-position/unread/displayed-receipt effects от открытия чата.
- Screenshots фиксируют все три визуальных mode.
- No sleeps/flaky text-only hooks.
- Missing signed-in account/dialog дает failure + durable blocker, не destructive recovery.
- Ветви 1 result и 2+ results имеют отдельные assertions; arrows не wrap-ятся.

### Post-task verification

- TEST[ChatSearchLiveQASafetyPolicyTests, ChatSearchAccessibilityTests, ChatSearchLocalizationTests].
- Запустить opt-in:

~~~bash
env \
  -u TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT \
  -u TEST_RUNNER_XABBER_ISOLATED_STORAGE \
  XABBER_LIVE_SEARCH_QA=1 \
  XABBER_EXPECTED_SIMULATOR_UDID='7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF' \
  XABBER_SCHEME='Debug (xabber project)' \
  XABBER_DESTINATION='platform=iOS Simulator,id=7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberUITests/ChatSearchLiveSmokeTests \
  ONLY_ACTIVE_ARCH=YES \
  COMPILER_INDEX_STORE_ENABLE=NO
~~~

- Проверить account still signed in; отдельно записать, что обычные read-effects разрешены и не являются storage-reset defect.
- Сравнить simctl get_app_container path до/после run.
- Обязательная simulator build.
- Обновить tests/UI notes и journal; любой live blocker/failure записать в vault task и не закрывать Task.
- git diff --check после documentation edits.

---

## Task 25A — Harden stress и cancellation races

**Owner:** xabber-ui
**Secondary:** xabber-xmpp, xabber-business, xabber-tests
**Depends on:** Task 24
**Commit:** fix(chat-search): harden cancellation races

### Цель

Доказать terminal/cancellation behavior при быстрых query, paging, navigation и прерванных transitions до performance tuning. Любая старая generation должна терять право менять UI и persistence completion state.

### Файлы

- ChatSearchSession/presentation reducer;
- remote/local provider coordinators и timestamp resolver;
- mode/calendar transition coordinators;
- новый xabberTests/ChatSearchStressStateTests.swift;
- существующие paging/navigation/cancellation policy tests;
- xabber.xcodeproj/project.pbxproj.

### Pre-task tests

- TEST[ChatSearchSessionStateTests, ChatSearchMAMPagingTests, ChatSearchLocalProviderTests, ChatSearchResultNavigationStateTests, ChatSearchModeTransitionTests, ChatSearchCalendarCompletionTests, ChatSearchLiveQASafetyPolicyTests].

### Tests-first

Покрыть deterministic virtual-clock/fake-provider scenarios:

- 100 последовательных query replacements, включая t/te/tes/test, применяют только последнюю generation;
- cancel до debounce fire не отправляет request;
- cancel между MAM final IQ и persistence completion не публикует results/completed;
- cancel инвалидирует registered callback/search IDs и scheduled continuation следующей MAM page;
- repeated/no-progress cursor дает ровно один `.truncated` terminal;
- cancel между local Realm batches не публикует следующий detached batch;
- cancel между local `needsRemote` и первым/вторым timestamp MAM request не запускает лишний direction;
- 100 alternating arrow intents во время anchor load коалесцируются к последнему допустимому target;
- 20 rapid chat/list toggles и calendar open/cancel заканчиваются в последнем reducer state с одним child/overlay;
- cancel во время list/calendar/property animator cleanup удаляет snapshot/dim и восстанавливает hit testing;
- provider error + user retry не вызывает duplicate terminal callback;
- query replacement из list возвращает chat и не оставляет stale row/count;
- every cancellation path снимает searching/paging/positioning/resolving flags.

### Реализация

1. Использовать generation/cancellation token через все async boundaries, включая persistence completion и animator completion.
2. Сделать unregister/invalidating idempotent.
3. Coalesce intents только в рамках одной generation и проверять boundary после получения новых pages.
4. Не исправлять performance без измерения; scope этой задачи — correctness under stress.
5. Не добавлять sleeps в tests: fake clock/manual callbacks.

### Критерии принятия

- Ни один stale callback/animation completion не меняет committed UI.
- Каждый request получает ровно один typed terminal outcome.
- Cancel освобождает callbacks/continuations/loaders и оставляет валидную hierarchy.
- Rapid actions завершаются в последнем допустимом requested state.
- Existing normal history/search behavior проходит regressions.

### Post-task verification

- TEST[ChatSearchStressStateTests, ChatSearchSessionStateTests, ChatSearchMAMPagingTests, ChatSearchLocalProviderTests, ChatSearchResultNavigationStateTests, ChatSearchModeSwitchingTests, ChatSearchModeTransitionTests, ChatSearchCalendarCompletionTests, ChatHistoryPageCompletionPolicyTests, ChatRemoteHistoryApplyPolicyTests].
- Обязательная simulator build.
- Обновить UI/XMPP/business/tests notes и journal, затем git diff --check.

---

## Task 25B — Измерить и оптимизировать large-result performance

**Owner:** xabber-ui
**Secondary:** xabber-business, xabber-tests
**Depends on:** Task 25A
**Commit:** perf(chat-search): optimize large result flows

### Цель

Измерить mapping/dedup/highlighting/diffable snapshot и main-thread apply для 1000+ results, устранить только доказанные bottlenecks и зафиксировать воспроизводимый budget на iPhone 16e simulator.

### Файлы

- ChatSearchResult mapper/deduplicator;
- ChatSearchLocalProvider/remote aggregation;
- ChatSearchHighlighting;
- ChatSearchResultsListViewController/diffable snapshot builder;
- новый xabberTests/ChatSearchPerformanceTests.swift;
- signpost helper только если проект уже использует os_signpost;
- xabber.xcodeproj/project.pbxproj.

### Pre-task tests

- TEST[ChatSearchStressStateTests, ChatSearchResultPresentationTests, ChatSearchLocalProviderTests, ChatSearchHighlightingTests, ChatSearchResultsListTests, ChatReloadInvalidationPolicyTests, ChatDisplayModelCacheTests].

### Tests-first

Покрыть и сначала записать measured red/baseline:

- mapping/sort/dedup 1000 detached results и scaling ratio 1000→2000 не хуже 2.5×;
- highlight 100 visible long bodies ограничен видимыми cells и не пересчитывает unchanged query/model;
- incremental snapshots 4 × 250 сохраняют top visible identity/offset и не reload-ят unchanged rows;
- pure mapping median < 50 ms и snapshot model construction median < 100 ms на указанном simulator при повторяемом XCTClockMetric setup; если baseline среды нестабилен, зафиксировать более строгий repository-relative regression threshold, но не объявлять pass без чисел;
- один synchronous main-thread apply segment < 100 ms;
- avatar work lazy/cancellable и не блокирует snapshot;
- Realm read/mapping выполняется off-main; UIKit apply выполняется main-only;
- network latency/animation wall time исключены из pure performance metrics;
- result ordering/dedup correctness совпадает до и после optimization.

### Реализация

1. Добавить measure/signpost evidence до production optimization.
2. Устранить обнаруженные O(n²), duplicate mapping и unnecessary snapshot rebuilds.
3. Batch/coalesce background DTO construction и main-thread diffable apply без потери intermediate paging correctness.
4. Кешировать ranges/formatting только по immutable query/model keys и инвалидировать при change.
5. Не снижать Unicode correctness, stable ordering или accessibility ради benchmark.

### Критерии принятия

- 1000 rows формируются и применяются в зафиксированном budget.
- 2000-item scaling не указывает на quadratic regression.
- List scroll anchor/selection сохраняются при incremental pages.
- Нет main-thread Realm access или single stall > 100 ms.
- Optimization имеет before/after evidence в test output/vault notes.

### Post-task verification

- TEST[ChatSearchPerformanceTests, ChatSearchStressStateTests, ChatSearchResultPresentationTests, ChatSearchLocalProviderTests, ChatSearchHighlightingTests, ChatSearchResultsListTests, ChatReloadInvalidationPolicyTests, ChatDatasourceBoundsTests, ChatDisplayModelCacheTests].
- Обязательная simulator build.
- Обновить UI/business/tests notes, docs/testing при durable budget и journal, затем git diff --check.

---

## Task 25C — Закрыть lifecycle и leak risks

**Owner:** xabber-ui
**Secondary:** xabber-business, xabber-tests
**Depends on:** Task 25B
**Commit:** fix(chat-search): close lifecycle leaks

### Цель

Проверить deallocation и восстановление валидного UI при уходе из чата, background/foreground, rotation, memory warning и повторных open/close после stress/performance changes.

### Файлы

- ChatViewController search ownership/extensions;
- ChatSearchSession/providers/list/calendar/transition objects;
- avatar/task/observer ownership;
- новый xabberTests/ChatSearchLifecycleTests.swift;
- существующие chat first-frame/datasource/navigation policy tests;
- xabber.xcodeproj/project.pbxproj.

### Pre-task tests

- TEST[ChatSearchPerformanceTests, ChatSearchStressStateTests, ChatSearchModeTransitionTests, ChatSearchCalendarPresentationTests, ChatSearchResultsListTests, ChatFirstFrameLocalHistoryRegressionTests, ChatDatasourceBoundsTests].

### Tests-first

Покрыть:

- 50 activate/cancel cycles не накапливают child list/calendar/blur views, callbacks или notification observers;
- weak session/list/calendar/transition coordinator/avatar task становятся nil после chat deinit/cancel;
- navigation away во время remote/local/timestamp load отменяет callbacks и не обращается к deallocated controller;
- background/foreground во время debouncing/searching/paging/positioning/list-in/calendar-in/resolvingDate заканчивается в reducer-consistent final state;
- rotation/trait change во время interruptible transition выполняет cleanup и новый layout без orphan snapshots;
- memory warning очищает expendable avatar/snapshot caches, но не query/result identity state активного flow;
- keyboard first responder/keyboardLayoutGuide constraints не удерживают removed search views;
- смена chat/account scope инвалидирует generation и не показывает results предыдущего peer;
- app/session notification observers снимаются ровно один раз;
- normal chat composer/navigation восстанавливаются после cancel/deinit.

### Реализация

1. Свести ownership к одному search lifecycle owner в ChatViewController.
2. Использовать weak captures/cancellation tokens и explicit teardown, где lifecycle не гарантирует автоматическую отмену.
3. Сделать animation/containment cleanup idempotent.
4. Не очищать persistent account data/caches, не связанные с transient search UI.
5. Добавить deallocation assertions без arbitrary sleeps.

### Критерии принятия

- Search objects и transient UIKit hierarchy освобождаются после cancel/chat deinit.
- Background/rotation/navigation interruption не оставляют loader/overlay/stale results.
- Peer/account scope никогда не пересекается.
- Normal chat first frame/composer/navigation regressions отсутствуют.
- Нет destructive storage cleanup.

### Post-task verification

- TEST[ChatSearchLifecycleTests, ChatSearchPerformanceTests, ChatSearchStressStateTests, ChatSearchSessionStateTests, ChatSearchModeTransitionTests, ChatSearchCalendarPresentationTests, ChatSearchResultsListTests, ChatNavigationBarStateTests, ChatComposerFrameUpdateTests, ChatFirstFrameLocalHistoryRegressionTests, ChatDatasourceBoundsTests].
- Обязательная simulator build.
- Обновить UI/business/tests notes и journal, затем git diff --check.

---

## Task 25D — Не удалять аккаунт при неподтвержденном отзыве credential

**Owner:** xabber-xmpp
**Secondary:** xabber-business, xabber-tests, xabber-ui
**Depends on:** Task 23
**Commit:** fix(auth): preserve accounts for missing credentials

### Причина добавления

Task добавлен по прямому требованию пользователя после runtime-инцидента Task 24. Приложение запустилось с существующей строкой аккаунта, выбрало primary password-auth, но Keychain lookup вернул `present=false`. `AccountStreamDelegate` вызвал `tokenWasInvalidated()` без server stanza; `ApplicationStateManager` воспринял нетипизированное notification как подтвержденный revoke, синхронно вызвал `AccountManager.deleteAccount(by:)` и показал `Access revoked`. В этом пути OCRA/HOTP counter не читался и не резервировался, поэтому рассинхронизация счетчика не является причиной наблюдаемого удаления.

### Цель

Разделить локально отсутствующий/поврежденный credential, неоднозначный auth failure и криптографически/протокольно подтвержденный server revoke. Ни отсутствие password/token/secret/validation key/device id в Keychain/Realm, ни локальный invalidated flag, ни transport/auth-start error не должны автоматически удалять аккаунт, Realm или историю и не должны показывать текст о подтвержденном отзыве. Деструктивный путь разрешен только для явно типизированного текущего primary-stream `account-disabled` либо server headline revoke, чей device id совпал с текущим device id.

### Файлы

- `xabber/models/account/delegates/AccountStreamDelegate.swift`;
- `xabber/models/account/extensions/XMPPAuthenticationFailure.swift` и новый узкий typed disposition/policy рядом с ним;
- `xabber/common/state/ApplicationStateManager.swift`;
- `xabber/xmpp/device/XMPPDeviceManager.swift` только для передачи типизированного authoritative source;
- secondary stream delegates только если общий policy требует выравнивания без изменения их non-destructive ownership;
- новый `xabberTests/AccountMissingCredentialPolicyTests.swift`;
- `XMPPAuthenticationFailureTests`, `AccountStreamLifecycleGateTests`, `AccountDeletionCleanupTests`, `AccountDeletionCoordinatorTests`;
- `xabber.xcodeproj/project.pbxproj`;
- durable auth safety notes/spec и этот Execution journal.

### Pre-task tests

- TEST[XMPPAuthenticationFailureTests, AccountStreamLifecycleGateTests, AccountConnectionResilienceCoordinatorTests, AccountDeletionCleanupTests, AccountDeletionCoordinatorTests, AppLaunchEnvironmentPolicyTests, ChatSearchLiveQASafetyPolicyTests].
- Использовать оба hosted safety flags и только allowlist; broad tests и live account mutation запрещены.
- Зафиксировать текущие counter-reservation ожидания: reservation сохраняет `N+1` до отправки SASL и не откатывается после неоднозначного network/auth outcome, но отсутствующий credential не создает reservation.

### Tests-first

До production-изменения добавить/обновить XCTest и зафиксировать ожидаемый red там, где текущий код способен проявить defect:

- primary password branch с отсутствующим Keychain password возвращает typed `.missingLocalCredential`, останавливает текущую попытку и не публикует revoke event;
- missing token/secret/validation key/device id использует recoverable re-auth/device-secret-update disposition, не удаляет account/Realm/history и не утверждает, что server отозвал доступ;
- локальный `isInvalidated` без текущего authoritative server evidence не превращается в account deletion;
- auth-start throw, socket close, timeout, `temporary-auth-failure`, malformed/unknown SASL и secondary-stream failure никогда не вызывают delete/revoke presenter;
- primary current-stream SASL `<account-disabled/>` остается отдельным authoritative disposition; stale/secondary stream не получает права удалить account;
- headline `<revoke/>` разрешает authoritative event только при server sender/namespace validation и exact current-device-id match; чужой, пустой или stale device id безопасно игнорируется;
- `ApplicationStateManager` принимает typed revocation evidence, а не голый JID notification; `.missingLocalCredential` и `.reauthenticationRequired` не достигают `AccountManager.deleteAccount`;
- пользовательское сообщение для missing credential сообщает о необходимости повторного входа/восстановления credential без ложной фразы `Access revoked` и без утверждения, что локальные данные удалены;
- password missing, token missing и incomplete OCRA material не вызывают `reserveCounterForAuthentication` и не меняют persisted counter;
- один начатый token/secret SASL attempt делает ровно одну monotonic reservation; ambiguous failure не rollback-ит ее и не создает вторую reservation без нового attempt;
- повторная доставка одного authoritative revoke idempotent: account cleanup/presenter не выполняются дважды;
- diagnostics содержат redacted source/reason/credential kind/counter-reservation state, но не password, token, secret, validation key, raw SASL response или message content;
- isolated hosted Realm/credential fakes доказывают сохранение account row и unrelated chat/message rows для всех non-authoritative outcomes.

### Реализация

1. Ввести typed auth/revocation disposition с явными source и authority: local credential state, primary SASL current stream, secondary stream, verified current-device headline.
2. Удалить вызов `tokenWasInvalidated()` из ветки missing password и других локальных pre-auth paths; завершать attempt как recoverable и переводить UI в re-auth flow без cleanup.
3. Заменить нетипизированный `ApplicationStateManager.tokenWasExpired` для account deletion на typed API/event, который требует authoritative evidence. Не позволять произвольному JID notification вызывать deletion.
4. Сохранить существующий monotonic OCRA reservation contract: counter резервируется только после полной локальной credential preflight и непосредственно перед SASL send; ambiguous outcome не откатывает потенциально consumed counter.
5. Сделать destructive cleanup idempotent и доступным только для подтвержденного current-device revoke. Не менять ручной logout/delete-account flow.
6. Не читать и не логировать credential values. Не мигрировать и не очищать пользовательское хранилище в этой задаче.
7. Обновить knowledge/vault durable contract: отсутствие локального credential — client storage inconsistency/re-auth condition, а не server revocation evidence.

### Критерии принятия

- Missing/недоступный local credential не удаляет account, Realm, chats или messages и не показывает `Access revoked`.
- Transport, ambiguous auth, stale callback и любой secondary stream остаются non-destructive.
- Только доказанный current primary `account-disabled` или validated matching-device headline может войти в destructive revoke policy.
- Counter не меняется до полного credential preflight; начатая token/secret SASL попытка имеет ровно одну monotonic reservation без unsafe rollback.
- Existing signed-in account переживает два обычных последовательных запуска новой сборки; install-over/launch выполняются только в разрешенном non-destructive QA gate и без изменения credentials.
- Все diagnostics redacted; manual logout/account delete semantics не изменены.
- Focused XCTest и обязательная simulator build проходят; пользовательский account остается на месте.

### Post-task verification

- TEST[AccountMissingCredentialPolicyTests, XMPPAuthenticationFailureTests, AccountStreamLifecycleGateTests, AccountConnectionResilienceCoordinatorTests, AccountDeletionCleanupTests, AccountDeletionCoordinatorTests, AppLaunchEnvironmentPolicyTests, ChatSearchLiveQASafetyPolicyTests].
- Обязательная cached simulator build на iPhone 16e без clean.
- После подтвержденного пользователем signed-in состояния выполнить только bounded install-over/launch survival check: два запуска, тот же data-container, account остается signed in; не удалять приложение, контейнер, Realm или credential и не вводить учетные данные.
- Обновить XMPP/business/tests/UI notes, auth durable spec, handoff и journal; записать red/green и runtime evidence, затем git diff --check.

---

## Task 25E — Изолировать Keychain hosted XCTest от пользовательского аккаунта

**Owner:** xabber-tests
**Secondary:** xabber-business, xabber-lead
**Depends on:** Task 25D
**Commit:** test(infrastructure): isolate hosted XCTest credentials

### Причина добавления

После Task 25D два обычных запуска основной сборки успешно авторизовали существующий аккаунт. Следующий allowlisted hosted XCTest запустил отдельное приложение `xabber.ios.codex-hosted-tests` с изолированным пустым Realm, но с теми же значениями `credential_store.plist`: service `xabber.ios` и access group `group.xabber.ios`. Пустой Realm активировал onboarding; при выключенном multi-account режиме его `removeAllKeys()` был ограничен service/access-group, но этот service совпадал с production. Следующий запуск основной сборки поэтому увидел `password present=false`. Сервер токен не отзывал, OCRA/HOTP counter причиной не был: password-auth branch не использует counter, а до hosted run credential присутствовал.

### Цель

Связать изоляцию Realm и Keychain одним exact hosted-XCTest gate. Обычный launch и неполные/custom flags должны продолжать использовать неизменные bundled service/access group. Только hosted process с XCTest marker и обоими safety flags должен использовать стабильный test-only service `xabber.ios.hosted-xctest` в том же разрешенном access group. Очистка onboarding тогда может затрагивать только test credentials, но не основной аккаунт.

### Файлы

- `xabber/common/CredentialsManager/CredentialsManager.swift`;
- `xabber/application/AppDelegate.swift`;
- новый `xabberTests/HostedCredentialIsolationTests.swift`;
- `xabber.xcodeproj/project.pbxproj`;
- этот plan/Execution journal и рабочие vault notes.

### Pre-task tests

- Зафиксировать exact main data-container path и inode/size Realm без чтения credential values.
- Запустить compile-only `build-for-testing` существующего `ChatSearchGoalSafetyPolicyTests` на exact iPhone 16e и подтвердить `TEST BUILD SUCCEEDED`; не install/launch main app.
- Не выполнять pre-fix hosted XCTest runtime: подтвержденный reproducer удаляет production Keychain credential. Использовать tests-first compile red как безопасное доказательство отсутствующего контракта.

### Tests-first

До production-изменения добавить отдельный XCTest suite и зафиксировать compile red на отсутствующих API:

- обычный environment возвращает exact bundled service/access group;
- оба custom safety flags без XCTest marker не меняют namespace;
- XCTest marker с неполным opt-in не меняет namespace;
- exact hosted marker + оба safety flags добавляют только `.hosted-xctest` к service и сохраняют authorized access group;
- test service стабилен между разными hosted process identifiers, чтобы test-only cleanup мог удалить собственные остатки прошлого запуска;
- реальный hosted process с обоими flags фактически получает test service и не может адресовать bundled production service.

### Реализация

1. Вынести Foundation-only `HostedXCTestIsolationPolicy` с теми же тремя exact runtime keys, которые уже защищают isolated Realm.
2. Разрешать изоляцию только при одновременном наличии XCTest marker и значений `1` у disable-autoconnect/isolated-storage; один пользовательский/custom flag не должен менять production namespace.
3. Загружать bundled credential store один раз на вызов и резолвить его через общий policy.
4. Для exact hosted process использовать стабильный suffix `.hosted-xctest`; не включать PID в service и не менять access group/entitlements.
5. Перевести `AppLaunchEnvironmentPolicy.isolatedStorageDescriptor` на общий exact policy, чтобы Realm и Keychain невозможно было разнести разными условиями.
6. Не менять onboarding, обычную авторизацию, credential contents, Keychain access group или ручные logout/delete-account semantics.

### Критерии принятия

- Все шесть новых контрактов проходят в реальном hosted test process.
- Existing AppLaunchEnvironmentPolicy, search safety и auth safety suites проходят с обоими hosted flags.
- Hosted run больше не может адресовать service `xabber.ios`; test cleanup ограничен `xabber.ios.hosted-xctest`.
- После hosted run main data-container и Realm inode остаются теми же, а bounded обычный launch показывает signed-in Chats shell.
- Фильтрованные main logs показывают `credential present=true` и `authSucceeded`, без revoke/account deletion/`Access revoked`.
- В код, тесты, логи и docs не попадают credential values; uninstall/reset/logout/storage cleanup не выполняются.
- Обязательная cached simulator build проходит без clean.

### Post-task verification

- TEST[HostedCredentialIsolationTests, AppLaunchEnvironmentPolicyTests, ChatSearchGoalSafetyPolicyTests, AccountMissingCredentialPolicyTests, XMPPAuthenticationFailureTests, AccountStreamLifecycleGateTests] только с обоими hosted safety flags и exact allowlist.
- Обязательная `tools/xcodebuild_cached.sh build` на iPhone 16e без clean.
- Повторно проверить main container/Realm inode; выполнить один bounded ordinary launch без hosted flags и без account mutation, подтвердить signed-in shell и redacted auth success.
- Обновить tests/business/lead notes, debug note, task/handoff и journal; затем `git diff --check`.

---

## Task 26A — Выполнить final allowlisted regression, build и install-over

**Owner:** xabber-lead
**Secondary:** xabber-ui, xabber-xmpp, xabber-business, xabber-tests
**Depends on:** Task 25C
**Commit:** test(chat-search): record final regression gate

### Цель

Выполнить один дедуплицированный final XCTest gate, обязательную simulator build и bounded install поверх существующего приложения. На этом этапе не проводить визуальную приемку и не исправлять найденные defects внутри verification commit.

### Файлы

- этот plan/Execution journal;
- новый docs/qa/telegram-style-in-chat-search-verification.md с разделом build/test/install evidence;
- production/tests не изменять; при defect создать новый focused follow-up Task/commit и затем перезапустить Task 26A с начала.

### Pre-task tests

В одном allowlisted run выполнить каждый suite ровно один раз; full `xabberTests` запрещен:

- safety/baseline: AppLaunchEnvironmentPolicyTests, ChatSearchGoalSafetyPolicyTests, AccountMissingCredentialPolicyTests, XMPPAuthenticationFailureTests, AccountStreamLifecycleGateTests, AccountDeletionCleanupTests, AccountDeletionCoordinatorTests, InfoCardChatSearchRoutingTests, InfoCardSearchAccessibilityTests, ChatSearchModeActivationTests, ChatInChatSearchQueryLifecycleTests, ChatSearchResultNavigationStateTests, ChatSearchArchiveGapRepairTests, ChatSearchInputBarViewTests, ChatSearchBottomPanelTests, SearchChatListKeyboardLayoutTests, ChatNavigationBarStateTests;
- foundation/providers: ChatSearchPresentationStateTests, ChatSearchResultPresentationTests, ChatSearchSessionStateTests, ChatSearchMAMPagingTests, ChatSearchLocalProviderTests, ChatSearchAnimationSpecTests;
- UI/list: ChatSearchTopChromeTests, ChatSearchBottomActionBarTests, ChatSearchNavigationButtonsTests, ChatSearchHighlightingTests, ChatSearchResultCellTests, ChatSearchResultsListTests, ChatSearchModeSwitchingTests, ChatSearchListTransitionTests, ChatSearchListSelectionTests;
- calendar/date: ChatSearchCalendarModelTests, ChatSearchCalendarViewTests, ChatSearchCalendarPresentationTests, ChatSearchTimestampLocalResolverTests, ChatSearchTimestampMAMResolverTests, ChatSearchCalendarCompletionTests;
- quality/automation: ChatSearchModeTransitionTests, ChatSearchLocalizationTests, ChatSearchAccessibilityTests, ChatSearchAdaptiveLayoutTests, ChatSearchLiveQASafetyPolicyTests, ChatSearchStressStateTests, ChatSearchPerformanceTests, ChatSearchLifecycleTests;
- supporting regressions: ChatHistoryPageCompletionPolicyTests, ChatArchiveCoverageCommitPolicyTests, ChatHistoryPagingPolicyTests, ChatRemoteHistoryApplyPolicyTests, ChatOpenMessageRequestHandlingPolicyTests, ChatMessageAnchorPolicyTests, ChatComposerFrameUpdateTests, ChatDiffKeySignatureTests, ChatDisplayModelCacheTests, ChatReloadInvalidationPolicyTests, ChatDatasourceBoundsTests, ChatFirstFrameLocalHistoryRegressionTests.

Использовать TEST[...] contract с обоими hosted safety flags. Сохранить xcresult/log вне repository только на время диагностики; после pass удалить disposable result bundle, сохранив Codex caches.

### Tests-first

- Final gate запускается до documentation/install edits.
- Любое падение блокирует Task; диагностировать первый meaningful failure.
- Исправление требует нового отдельного red/green follow-up Task и commit, после чего весь Task 26A начинается заново.
- `XCTSkip` внутри unit gate не считается pass, если skipped scenario относится к обязательному contract.

### Реализация

1. Записать exact simulator/container preflight, commit under test и полный deduplicated suite list в verification.md.
2. Запустить обязательную cached simulator build без clean и проверить `** BUILD SUCCEEDED **`, compiler/linker errors и product path.
3. Проверить bundle до install:

~~~bash
UDID='7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF'
APP_PATH="$HOME/Library/Caches/XabberCodex/xabber-ios-core/DerivedData/Build/Products/Debug-iphonesimulator/xabber.app"
test -d "$APP_PATH"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")" = 'xabber.ios'
~~~

4. Выполнить install-over через executor watchdog 60 s, без uninstall:

~~~bash
python3 -c 'import subprocess,sys; subprocess.run(sys.argv[1:], check=True, timeout=60)' \
  xcrun simctl install "$UDID" "$APP_PATH"
~~~

5. Выполнить launch через watchdog 30 s с явно снятыми hosted-unit flags:

~~~bash
env -u TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT \
  -u TEST_RUNNER_XABBER_ISOLATED_STORAGE \
  python3 -c 'import subprocess,sys; subprocess.run(sys.argv[1:], check=True, timeout=30)' \
  xcrun simctl launch "$UDID" xabber.ios
~~~

6. При timeout собрать process/simctl diagnostics и terminate только зависший `xabber.ios` process при необходимости; не erase/uninstall/remove container. Повторять install/launch только после понятной причины.
7. Сравнить data-container path и signed-in shell до/после; path — identity guard, обычные read effects здесь не требуются.

### Критерии принятия

- Каждый suite final union прошел без скрытого broad-test запуска.
- Cached simulator build прошла без compiler/linker errors.
- Bundle ID/product path доказаны до установки.
- Install выполнен поверх existing app и уложился в watchdog; uninstall/erase не вызывались.
- Data-container identity и signed-in account сохранены; обычные launches не показывают ложный `Access revoked` и не удаляют account при отсутствии server-revoke evidence.
- verification.md содержит commands, durations, first failure policy и pass evidence.

### Post-task verification

- Повторить тот же deduplicated final union после documentation/install steps; если он отличается/падает, Task не коммитить.
- Обязательная simulator build: повторить cached build после final union.
- Повторить exact device/container check; обновить journal/verification/vault notes, затем git diff --check.

---

## Task 26B — Провести live/video parity QA

**Owner:** xabber-ui
**Secondary:** xabber-tests, xabber-lead
**Depends on:** Task 26A
**Commit:** docs(chat-search): record visual parity evidence

### Цель

Записать полный non-destructive runtime flow на указанном iPhone 16e, сравнить его с reference по presentation timestamps и принять либо отклонить каждую geometry/motion/behavior delta.

### Файлы

- docs/qa/telegram-style-in-chat-search-verification.md;
- этот plan/Execution journal;
- video/screenshot binaries хранятся только вне git, например в /Users/igor.boldin/Downloads;
- production/tests не менять; любой defect оформляется отдельным follow-up Task/commit и требует повторения 26A–26B.

### Pre-task tests

- TEST[ChatSearchLiveQASafetyPolicyTests, AccountMissingCredentialPolicyTests, XMPPAuthenticationFailureTests, ChatSearchModeTransitionTests, ChatSearchListTransitionTests, ChatSearchCalendarPresentationTests, ChatSearchCalendarCompletionTests, ChatSearchAccessibilityTests, ChatSearchAdaptiveLayoutTests, ChatSearchLifecycleTests].
- Повторить exact device/container/signed-in preflight и non-opt-in safety gate; не запускать, если account missing.

### Tests-first

- Runtime evidence является обязательным integration test, но не заменяет XCTest.
- Использовать Task 24 XCUITest helpers и отдельный opt-in date-jump flow; query всегда lowercase `test`, хотя reference video визуально вводит `Test`.
- Andrew Nenakhov проверяется первым. Zero results → обычный cancel и ровно одна попытка Alexey Boldin. Zero в обоих → failure/blocker, Goal не закрывать.
- One-result branch проверяет одну row и обе disabled arrows. Multi-result branch проверяет newest/oldest boundaries и no-wrap.
- Открытие чата может штатно изменить read position/unread/displayed receipt; send/edit/delete/logout/reset запрещены.

### Реализация

1. Записать видео и выполнить live test в одном shell session. Recorder обязан завершаться SIGINT даже при test failure:

~~~bash
UDID='7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF'
VIDEO='/Users/igor.boldin/Downloads/Xabber_Search_Parity_2026-07-13_goal-qa.mp4'
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$VIDEO" &
RECORDER_PID=$!
finish_recording() {
  kill -INT "$RECORDER_PID" 2>/dev/null || true
  wait "$RECORDER_PID" 2>/dev/null || true
}
trap finish_recording EXIT INT TERM
TEST_STATUS=0
env \
  -u TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT \
  -u TEST_RUNNER_XABBER_ISOLATED_STORAGE \
  XABBER_LIVE_SEARCH_QA=1 \
  XABBER_LIVE_SEARCH_DATE_JUMP_QA=1 \
  XABBER_EXPECTED_SIMULATOR_UDID='7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF' \
  XABBER_SCHEME='Debug (xabber project)' \
  XABBER_DESTINATION='platform=iOS Simulator,id=7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF' \
  tools/xcodebuild_cached.sh test \
  -parallel-testing-enabled NO \
  -only-testing:xabberUITests/ChatSearchLiveSmokeTests \
  ONLY_ACTIVE_ARCH=YES \
  COMPILER_INDEX_STORE_ENABLE=NO || TEST_STATUS=$?
finish_recording
trap - EXIT INT TERM
test "$TEST_STATUS" -eq 0
~~~

2. Записать chat result, both boundaries, list in/stable/out, interactive keyboard dismissal, calendar in/stable/month picker/swipe/X, restored query и final date jump через Done по дате существующего result.
3. Calendar Done test выбирает civil day result, сохраняя current selection time components, и проверяет exact-timestamp resolver, search exit и safe anchor. Не отправлять message.
4. Проверить ffprobe decode/duration/resolution и SHA-256 завершенного video; не commit-ить binary.
5. Из reference и Xabber video извлечь одинаковые PTS states: chat result, arrow boundary, list-in midpoint/stable/list-out, calendar-in/stable/picker/swipe/X, Done/date anchor.
6. Reference VFR считать по presentation timestamps: nominal 59.94 fps, tool-reported average `149400/3827` ≈ 39.04 fps. Не сравнивать «номер кадра к номеру кадра».
7. В verification.md заполнить side-by-side table: state, reference PTS, Xabber PTS, geometry reference/actual/delta, duration reference/actual/delta, screenshot paths/SHA, disposition.
8. Выполнить static accessibility inspection/test-harness verification для VoiceOver order, максимального Dynamic Type, RTL, Reduce Motion/Transparency; если инструмент недоступен, соответствующий automated suite обязателен, limitation не превращать в visual pass.

### Критерии принятия

- Top surface: nominal 60 pt, field/X 44 pt, base 16 pt insets и 8 pt gap; measured geometry delta ≤ 2 pt.
- Bottom controls 40 pt; arrows 40 pt с 12 pt gap; controls не перекрыты keyboard.
- `1 of N` newest; upper=older, lower=newer; disabled boundary alpha около 0.5; no wrap.
- List rows newest-first, avatar/bold sender/plain one-line snippet/check-before-numeric-date; yellow highlight остается только timeline.
- List in: scale 0.95→1.0 за 0.40 s spring, blur 30→0 за 0.20 s; out scale/blur 0.30 s; top/bottom/keyboard/timeline stationary. Duration delta ≤ 0.05 s.
- Calendar: leading X, dynamic 4–6 rows, blank outside-month slots, future dates, month/year picker, swipe 0.30 s, Done inset около 30 pt.
- Calendar X сохраняет query/current/list origin и не восстанавливает keyboard автоматически; Done завершает search и выполняет exact timestamp jump.
- Account остается signed in; send/delete/logout/reset не происходят.
- Каждая delta получает pass/fix/accepted-accessibility-deviation disposition; молчаливых отклонений нет.

### Post-task verification

- TEST[ChatSearchLiveQASafetyPolicyTests, ChatSearchModeTransitionTests, ChatSearchListTransitionTests, ChatSearchCalendarPresentationTests, ChatSearchCalendarCompletionTests, ChatSearchAccessibilityTests, ChatSearchAdaptiveLayoutTests, ChatSearchLifecycleTests].
- Обязательная simulator build.
- Проверить video/verification links, exact container/account state, journal/vault notes, затем git diff --check.

---

## Task 26C — Закрыть durable docs, vault и execution ledger

**Owner:** xabber-lead
**Secondary:** xabber-ui, xabber-xmpp, xabber-business, xabber-tests
**Depends on:** Task 26B
**Commit:** docs(chat-search): close Telegram parity goal

### Цель

Свести стабильный behavior/architecture/test contract в source docs и vault, закрыть task/handoff и доказать наличие 36 отдельных source commits без попытки вписать собственный будущий SHA в tracked commit.

### Файлы

- docs/qa/telegram-style-in-chat-search-verification.md;
- docs/features/messaging.md или более узкий existing feature doc;
- этот plan/Execution journal;
- vault task/handoff/external execution ledger;
- agents ui/xmpp/business-logic/tests notes/tasks/decisions по ownership;
- shared/interfaces.md при подтвержденном cross-layer provider/resolver contract.

### Pre-task tests

- TEST[AppLaunchEnvironmentPolicyTests, ChatSearchGoalSafetyPolicyTests, AccountMissingCredentialPolicyTests, XMPPAuthenticationFailureTests, ChatSearchPresentationStateTests, ChatSearchCalendarCompletionTests, ChatSearchAccessibilityTests, ChatSearchLifecycleTests, ChatSearchLiveQASafetyPolicyTests].
- Проверить, что Task 26A final gate/build и Task 26B live/video evidence имеют pass, а не pending/skip.

### Tests-first

- Это documentation-only closure; production behavior не меняется.
- Проверить все absolute/relative links, 36 journal rows, expected commit subjects и evidence paths скриптом/rg до commit.
- Проверить `git log --format` и `git show --stat` для предыдущих 34 source task commits; unrelated commits не засчитываются.
- Любой новый code defect/изменение запрещено прятать в docs commit: создать follow-up Task и повторить 26A–26C.

### Реализация

1. Обновить durable source feature/QA docs: observable UI, state machine, provider ownership, calendar exact-timestamp semantics, Xabber-independent implementation/no private API, tests и known accepted deviations.
2. В tracked Execution journal для Task 26C записать `ready-to-commit` + expected subject; actual SHA там не требуется.
3. Обновить vault owner/secondary agent notes/tasks, shared interface, standalone handoff; переместить standalone task `tasks/open` → `tasks/done` только после всех checks.
4. Создать/обновить внешний vault execution ledger с 34 уже существующими source SHA и placeholder `awaiting Task 26C source commit`.
5. Source и vault — отдельные dirty git roots: source commit stage-ит только source docs; vault commit stage-ит только точно проверенные task/handoff/ledger/docs paths. Не stage-ить целиком dashboard-файлы с чужими hunks.
6. После source commit Task 26C получить actual SHA, заменить только vault placeholder и сделать отдельный focused vault commit. Это не дополнительный source task commit.
7. Goal complete разрешен только после проверки 36 unique source SHA во внешнем ledger и чистого staged state относительно наших файлов.

### Критерии принятия

- Все 36 Task labels выполнены последовательно и имеют отдельный unique source SHA во внешнем vault ledger.
- Source journal содержит final test/build/status/expected subjects без логической попытки self-record SHA.
- Verification doc содержит final unit/build/install/live/video/accessibility evidence.
- Vault task находится done, handoff закрыт, ownership notes/shared contract обновлены без захвата чужих изменений.
- Account все еще signed in; нет uninstall/erase/logout/remove-account evidence.
- Source и vault commits имеют точный allowlisted file set.

### Post-task verification

- TEST[AppLaunchEnvironmentPolicyTests, ChatSearchGoalSafetyPolicyTests, ChatSearchPresentationStateTests, ChatSearchCalendarCompletionTests, ChatSearchAccessibilityTests, ChatSearchLifecycleTests, ChatSearchLiveQASafetyPolicyTests].
- Обязательная simulator build.
- Проверить links, `git diff --check`, source staged diff и commit; после source commit проверить `git show --stat --oneline HEAD`.
- Записать Task 26C SHA во внешний vault ledger, проверить 36 unique hashes и сделать безопасный vault commit; только затем отметить Goal complete.

---

## 10. Общий Definition of Done

Goal завершен только когда одновременно выполнено все:

- Все 36 Task labels (00; 01–05; 05A; 06–21; 22A–22C; 23; 25D; 25E; 24; 25A–25C; 26A–26C) выполнены строго в зафиксированном порядке и не объединены.
- У каждого Task есть отдельный source commit; tracked journal заполнен до `ready-to-commit`, а actual SHA записан во внешнем vault execution ledger.
- Перед каждым Task в journal записан результат pre-task tests.
- Для каждого behavioral change существует focused red/green XCTest или явно доказанная причина невозможности red phase.
- Все post-task tests и build прошли до commit.
- Нет незакрытых stale callback, loader, overlay, child controller или animation states.
- Regular/group MAM и encrypted local search дают один UI contract.
- Calendar X сохраняет search, Calendar Done завершает search и выполняет date jump.
- Calendar использует exact selected timestamp, dynamic 4–6 week rows, blank outside-month slots, future dates и month/year picker.
- Simulator account не удален, не разлогинен и не сброшен.
- Финальный runtime flow выполнен с query test в Andrew Nenakhov либо Alexey Boldin.
- Финальное видео сравнено с reference по ключевым states.
- Accessibility/localization/RTL/Dynamic Type/Reduce Motion приняты.
- Vault task, handoff, agent notes и shared contract обновлены.

## 11. Риски и обязательная реакция

| Риск | Признак | Реакция |
|---|---|---|
| MAM first-page false completion | list count останавливается на max/page boundary | Не обходить UI-лимитом; закрыть Task 04 через final-IQ/RSM tests. |
| Stale callbacks | results старого query появляются после test | Generation guard в Tasks 03–05/19, Task не принимать. |
| Realm thread violation | crash/exception при list/local/date lookup | Только detached DTO и isolated Realm tests; не ловить exception как normal flow. |
| Anchor regression | counter сменился, message не открылся | Commit selection только после positioning success; Tasks 08/14. |
| Private blur API | использование CAFilter по имени | Запрещено; только public UIVisualEffectView/snapshot animator. |
| Calendar semantic drift | query фильтруется датой вместо date jump | Считать product defect; Telegram parity contract зафиксирован в Tasks 15–20. |
| Keyboard overlap | bottom bar под keyboard | keyboardLayoutGuide tests и runtime evidence обязательны. |
| UI target портит account | reset/uninstall/login automation | Safety gates Tasks 00/23; немедленно остановить live run при подозрении. |
| Legacy list reuse | SearchChatListViewController попадает в new flow | Запрещено; dedicated list/cell Tasks 10–11. |
| Large list jank | main-thread stall/dropped interactions | Task 25B profiling, batching/coalescing; не скрывать spinner-ом. |
| Dirty worktree | чужие изменения попадают в commit | Stage explicit files, inspect cached diff; не commit-ить чужое. |
| Live data unavailable | нет диалога/results/network | XCTest/build evidence сохранить; runtime step отметить failed/blocked, Goal не закрывать. Не создавать account/contact/message для обхода. |
| Reference/licence provenance | implementation начинает повторять source structure/assets/private API | Только independent reimplementation observable contract; Telegram code/assets/branding не переносить. Совместимость лицензий считать нерешенной до отдельного review. |

## 12. Допустимые отклонения

- Xabber colors, typography tokens и owned SF Symbols могут заменить Telegram proprietary assets, но размеры, hierarchy, semantics и motion должны оставаться эквивалентными.
- Public UIKit blur может визуально отличаться от private/internal Telegram filter; принимать только после side-by-side review.
- Server/network latency не сравнивается с видео; сравнивается реакция UI после получения state.
- Если iOS 15.6 fallback не может дать native iOS 26 glass, он обязан сохранить geometry, contrast, hit targets и transitions.
- Любое другое отклонение требует отдельной записи в verification.md с причиной, screenshot и явным решением accept/fix; молчаливое отклонение запрещено.

## 13. Execution journal

Обновлять строку текущего Task до его source commit. Формат Tests: pre → post; Build: pass/fail + destination; Notes: red reason/runtime evidence. Перед staging строка получает status `ready-to-commit` и expected subject. Actual SHA после commit записывается во внешний vault execution ledger; tracked journal не пытается хранить SHA собственного будущего commit.

| Task | Status | Pre tests | Red evidence | Post tests | Build | Expected subject | Notes |
|---|---|---|---|---|---|---|---|
| 00 | ready-to-commit | Exact UDID/container preflight; one pre-isolation AppLaunchEnvironmentPolicyTests baseline: 3/3 pass | Expected compile red: isolated-storage descriptor, runtime flag keys and in-memory Realm configuration APIs absent | Focused safety/search slice: 27/27 pass; B0 repeat after fixing leaked test Realm default: 102/102 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | test(infrastructure): isolate hosted XCTest storage | `TEST_RUNNER_` prefix is stripped in hosted process. Pre-isolation host install exposed real-account autoconnect and changed the app-container UUID; no account action was performed. The protected focused/B0/build sequence used `xabber.ios.codex-hosted-tests`, reported no installed-account autoconnect, and preserved the main `xabber.ios` container at `357416B1-CE86-4630-A585-F148692604DB` before/after. First B0 run found a test-only default-Realm leak; restoration was added and B0 reran green. |
| 01 | ready-to-commit | B0: 102/102 pass | Expected compile red: `ChatSearchPresentationState` and reducer events absent | Task selector + implicit safety classes: 76/76 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | refactor(chat-search): add presentation state machine | Pure Foundation reducer covers active/surface/result/positioning/calendar-origin/generation state, impossible transitions and derived visibility. Current activation/query/result/failure/navigation callbacks feed the state; legacy panel rendering remains behind a compatibility adapter. No geometry or live UI flow changed; main container remained `357416B1-CE86-4630-A585-F148692604DB`. |
| 02 | ready-to-commit | Task selector + implicit safety classes: 60/60 pass | Expected compile red: detached `ChatSearchResult`, mapping context, mapper, deterministic collection and position formatter APIs absent | Task selector + implicit safety classes: 66/66 pass; dedicated DTO/safety slice: 25/25 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | refactor(chat-search): add detached result model | Added immutable Sendable value DTO with archive-first stable identity, conversation scope, anchor values, sender/snippet/delivery presentation, deterministic newest-first ordering and completeness-aware deduplication. The controller keeps the DTO set synchronized through a temporary adapter while existing safe anchor navigation remains Realm-backed and `markReadOnVisible=false`. Realm-refresh detachment is covered; main container remained `357416B1-CE86-4630-A585-F148692604DB`; no live UI flow was run. |
| 03 | ready-to-commit | Required state/result/lifecycle/navigation selector + safety: 72/72 pass | Expected compile red: `ChatSearchSession`, generation/request/effect lifecycle and provider-event APIs absent | Pure session/safety slice: 24/24 pass; controller integration slice: 38/38 pass; required post selector + safety: 74/74 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | refactor(chat-search): isolate query session lifecycle | Added one 250 ms generation-scoped session for normalized input, immediate Return flush, provider selection, stale callback rejection, result/selection lifecycle and cancellation effects. Regular/group remain MAM `withtext`; encrypted remains local; no stanza shape changed. Provider spinner and context loading are independent. Main container remained `357416B1-CE86-4630-A585-F148692604DB`; no live UI flow was run. |
| 04 | ready-to-commit | Required session/lifecycle/archive paging selector + safety: 109/109 pass | Expected compile reds recorded in two stages: paging session/policies absent; then manager generation, typed terminal and cancellation APIs absent | Pure paging slice: 23/23 pass; manager integration: 33/33 pass; manager/archive callback regression: 79/79 pass; required post selector + safety: 141/141 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | fix(chat-search): paginate remote MAM results | Added generation/query-scoped multi-page `withtext` search with incremental newest-first deduplication, persistence-gated final completion, RSM `first` continuation, typed failure/cancel/truncation, explicit caps and no-progress protection. Search does not advance regular history coverage/cursors; cancellation removes callbacks and scheduled continuations. Main container remained `357416B1-CE86-4630-A585-F148692604DB`; no live UI flow was run. |
| 05 | ready-to-commit | Required session/result/lifecycle/MAM selector + implicit safety: 72/72 pass | Expected compile red: `ChatSearchLocalProvider` API absent; first green attempt then exposed an invalid test-only in-memory Realm fixture, independently confirmed by three attached crash reports at `ChatSearchLocalProviderTests.swift:36` and corrected without production/storage changes | Provider + safety slice: 22/22 pass; required post selector + safety: 81/81 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | fix(chat-search): align encrypted local results | Encrypted search now owns strict scoped Realm filtering in a business-layer provider, returns detached newest-first deduplicated batches on main, performs the Realm read off-main, and suppresses stale/cancelled events. Empty/unsupported requests do not open Realm; regular/group MAM remains unchanged. The fixture uses a unique in-memory Realm and restores the prior default. Main container remained `357416B1-CE86-4630-A585-F148692604DB`; no live UI flow was run. |
| 05A | ready-to-commit | Required presentation/session/local/MAM selector + implicit safety: 68/68 pass | Expected compile red: `ChatSearchAnimationSpec` and its immutable transition/timing/accessibility APIs absent | Focused animation spec + safety: 23/23 pass; required post selector + safety: 56/56 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | refactor(chat-search): add animation specification | Added one injectable Foundation value contract for floating controls, list scale/blur, calendar dim/sheet, semantic RTL-aware month travel, deterministic immediate timing, final-state completion, and Reduce Motion/Transparency fallbacks. It records only observed timing/geometry behavior and uses no UIKit animation, private API, source structure, generated paths, assets, or branding from the reference app. Existing controls/layout remain unchanged; main container remained `357416B1-CE86-4630-A585-F148692604DB`; no live UI flow was run. |
| 06 | ready-to-commit | Required top-chrome/navigation/session selector + safety: 61/61 pass | Expected compile red: `ChatSearchNavigationLayout`, `ChatSearchNavigationView`, render/focus callbacks and controller top-chrome APIs absent. First green attempt then exposed the legacy bottom Cancel becoming visible after repeated configure; the focused failing case plus safety reran 14/14 after the invariant was fixed. | Required post-task allowlist: 61/61 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | feat(chat-search): add Telegram-style top search chrome | Added a fixed 60 pt top search row with a 44 pt unified glass field, internal search/spinner/clear controls and detached X at reference iPhone 16e geometry. Query edits debounce through the existing session, Return/leading control flush without dismissing focus, clear preserves search mode, X exits, and repeated configuration clears stale navigation items without duplicating constraints. Native iOS 26 glass and public blur fallback share geometry; accessibility identifiers and single-line Dynamic Type behavior are covered. The legacy bottom Cancel is hidden while top chrome is installed. Main container remained `357416B1-CE86-4630-A585-F148692604DB`; no live UI flow was run. |
| 07 | ready-to-commit | Required presentation/top/bottom/keyboard/composer allowlist + safety: 57/57 pass | Expected compile red: two glass hosts, calendar/mode controls, safe-area layout/count formatter, surface-mode rendering and numeric-transition APIs absent | Focused first green: 28/28 pass; required post-task allowlist: 63/63 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | feat(chat-search): add bottom calendar and list controls | Rebuilt the keyboard-owned 40 pt bottom action bar as two independent glass capsules: calendar/count and Show as List/Chat. The right capsule requires a committed current result; idle/loading/empty states clear stale counts. Legacy bottom X/arrows are absent from the hierarchy while compatibility seek callbacks remain for Task 08. Safe-area and rotation geometry avoid double insets/overlap. Count changes use the shared animation spec for vertical push or a 0.15 s Reduce Motion crossfade. Main container remained `357416B1-CE86-4630-A585-F148692604DB`; no live UI flow was run. |
| 08 | ready-to-commit | Initial required allowlist: 64/66 pass; fixture-aligned rerun: 65/66 pass, with the remaining Task 07-superseded spinner expectation corrected in Task 08 | Expected compile red: detached floating navigation view, layout/render policy, older-page gate and controller ownership APIs absent | First focused green: 59/59 pass; final required post-task allowlist: 132/132 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | feat(chat-search): add floating result navigation | Added two detached 40 pt glass arrow buttons with a 12 pt gap, safe-area trailing/input-bar bottom anchoring, stable accessibility identifiers, shared spring/Reduce Motion transitions, newest-first non-wrapping boundaries and busy-state gating. Reaching the oldest loaded result may request exactly one offered MAM continuation; generation/cursor/no-progress/terminal guards suppress duplicates, and the first newly appended result opens through the existing safe anchor pipeline with `markReadOnVisible=false`. Final post initially exposed one stale anchor fixture that expected local search to block on impossible context-prefetch state; it was aligned to the established background-prefetch contract. Main container remained `357416B1-CE86-4630-A585-F148692604DB`; no live UI flow was run. |
| 09 | ready-to-commit | Required presentation/session/navigation/accessibility allowlist + implicit safety: 58/58 pass | Expected runtime red: the committed search result still returned whole-cell selection (`XCTAssertFalse` failed). Expected compile red: query range finder, highlight style and reversible highlighter APIs absent. | Focused highlight + safety slice: 27/27 pass; first required post run: 80/82 pass with two Task 09-superseded whole-cell-selection expectations; updated-contract rerun: 82/82 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | fix(chat-search): highlight every query occurrence | Added deterministic non-overlapping case/diacritic-insensitive UTF-16 ranges, all-occurrence light/dark yellow highlighting, reversible attribute backups that preserve links/mentions/semantic colors, safe empty/non-text handling, and reuse/cancel cleanup. Active search identity remains in search state but no longer drives the blue whole-cell wash; ordinary selection mode is unchanged. Another worktree replaced the main app container before this task's hosted test, from the previously observed UUID to `C8E2B598-D51B-4A19-96D6-F44167573221`; this task performed no main-app install/uninstall or live UI flow, and read-only inspection found the existing `Documents/default.realm` at 22,315,008 bytes. |
| 10 | ready-to-commit | Required result/highlight/top/bottom allowlist + implicit safety: 63/63 pass | Expected compile red: dedicated result cell, layout/date/delivery/avatar contracts and project membership absent | Focused cell + safety: 25/25 pass; required post-task allowlist: 55/55 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | feat(chat-search): add result list cell | Added a dedicated 64 pt UIKit row with deterministic iPhone 16e geometry, semibold sender, one-line plain snippet, locale-aware date, outgoing-only explicit Xabber delivery symbols, detached contact/group avatar descriptors, fallback avatars, reuse cancellation and represented-identity protection. Dynamic Type may grow the row, RTL mirrors content, selection stays neutral, and one stable accessibility element exposes sender/snippet/date/status. No Realm or `ChatViewController` dependency exists in the cell; no Telegram assets/branding or private API were used. The first implementation run exposed one fixture that reused the same avatar identity for both stale/current callbacks; the fixture now uses distinct JIDs and the protection passes. This task performed no main-app install/uninstall or live UI flow. During verification another worktree replaced the main container from `C8E2B598-D51B-4A19-96D6-F44167573221` to `BEC303B1-8A3A-4A57-A699-28371F79622D`; read-only inspection found the existing `Documents/default.realm` preserved at 22,315,008 bytes. |
| 11 | ready-to-commit | Required result-cell/presentation/MAM/local/state allowlist plus safety: 81/81 pass | Expected compile red: inline results-list controller, immutable render model, snapshot/anchor/inset policies and containment APIs absent | Focused list plus safety: 27/27 pass; required post-task allowlist: 91/91 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | feat(chat-search): add inline results list | Added a detached UIKit diffable results list with newest-first stable identity, completeness-aware deduplication, loading/paging/empty/error/populated states, stale-generation rejection, partial-result paging, preserved stable scroll anchor, programmatic selected-ID scrolling, safe-area/keyboard chrome insets, stable accessibility IDs, idempotent child containment and explicit cleanup. The list performs no Realm/XMPP access. First implementation compile exposed a mismatched existing normalization method name and was corrected; one identical rerun was cancelled by a neighboring worktree locking the shared build DB, then reran green without cache cleanup. Main container remained `BEC303B1-8A3A-4A57-A699-28371F79622D` with the existing 22,315,008-byte Realm; no live UI flow ran. |
| 12 | ready-to-commit | Required list/bottom/navigation/presentation/keyboard allowlist plus safety: 88/88 pass | Expected runtime red: 21 tests ran with 9 expected assertion failures because the mode callback only changed reducer state and never installed or removed the list child, changed hierarchy/counter/arrows, preserved mode scroll, or completed cancel cleanup. The first implementation run passed 7/8 feature cases; its remaining first-responder assertion was an invalid hosted-app fixture, so keyboard preservation was made deterministic through pending-focus intent plus the explicit interactive-drag dismissal policy. | Final focused mode/safety slice: 22/22 pass; required post-task allowlist: 89/89 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | feat(chat-search): switch between chat and list modes | The bottom control now lazily installs and reuses one inline list child, atomically switches timeline/list interaction, preserves query/generation/committed identity and stable visible list anchor, defers selected-row scrolling until the table enters a window, keeps current keyboard intent across ordinary toggles, dismisses only on interactive list drag, restores counters/arrows, and removes list state on cancel. Query replacement immediately returns to chat; missing committed identity rejects list; paging and calendar list-origin remain valid. Two reruns were cancelled before tests by a neighboring worktree locking the shared build DB and were repeated without interruption or cache cleanup. Main container remained `BEC303B1-8A3A-4A57-A699-28371F79622D` with the existing 22,315,008-byte Realm; no live UI flow ran. |
| 13 | ready-to-commit | Required mode/list/presentation/navigation allowlist plus safety: 64/64 pass | Expected compile red: transition plan/coordinator, injectable animator factory and animation protocol APIs absent | Focused transition plus safety: 21/21 pass; required post-task allowlist: 57/57 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | feat(chat-search): animate result mode transitions | Added a public-UIKit-only transition coordinator with shared-spec list-content snapshots, 0.95→1 spring plus material-blur presentation, 1→0.95 blur dismissal, Reduce Motion crossfade, immediate non-animated final states, repeated-request coalescing, interruption/reverse cleanup and generation-guarded completion. Timeline/top/bottom/keyboard geometry remains stationary; list removal occurs only after out completion, and overlays/transforms are removed on completion/reset. No private filter class/name or live UI flow was used. The three supplied Realm crash reports were re-read and match the already resolved Task 05 test-fixture default-configuration defect; current safety tests remained green. Main container remained `BEC303B1-8A3A-4A57-A699-28371F79622D` with the unchanged 22,315,008-byte Realm. |
| 14 | ready-to-commit | Required list/mode/transition/navigation/archive/anchor allowlist plus safety: 122/122 pass | Authoritative expected compile red after correcting two test-fixture mistakes: `handleChatSearchListResultSelection` and `makeSearchResultOpenMessageRequest` absent | Focused selection plus safety: 21/21 pass; first required post run: 121/130 pass with 9 existing legacy-only navigation fixture failures; compatibility repair slice: 42/42 pass; final required post allowlist: 130/130 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | feat(chat-search): open selected list result | Stable-ID/generation-scoped row selection closes list, retains tapped-row scroll anchor and enters the existing coalescing navigation state without changing the committed counter before positioning success. Detached result scope is validated; archived ID is preferred, with primary/message/date fallback, and every request uses the shared anchor pipeline with `source=.search`, highlight and `markReadOnVisible=false`. A bounded legacy request fallback preserves pre-detached arrow fixtures. Main container remained `BEC303B1-8A3A-4A57-A699-28371F79622D`; Realm remained 22,315,008 bytes with unchanged mtime; no live UI flow ran. |
| 15 | ready-to-commit | Required presentation/mode/list-selection allowlist plus safety: 43/43 pass | Expected compile red: `ChatSearchCalendarClock`, `ChatSearchCalendarModel`, calendar snapshots/navigation/picker and date-jump event APIs absent | Focused calendar model plus safety: 28/28 pass; required post-task allowlist: 50/50 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | feat(chat-search): add calendar selection model | Added a deterministic Foundation-only date-jump model with injected Calendar/Locale/TimeZone/Clock, 4–6 occupied week rows and hidden outside-month slots, civil-day selection that preserves wall-clock time across DST, locale weekday/title formatting, Unix epoch…`Int32.max - 1` bounds, future navigation, RTL-aware swipe plans, month/year picker state and distinct cancel/completion reducer events. No Realm/MAM/UI work occurs. Main container remained `BEC303B1-8A3A-4A57-A699-28371F79622D`; Realm remained 22,315,008 bytes with unchanged mtime; no live UI flow ran. |
| 16 | ready-to-commit | Required calendar-model/top-chrome/bottom-bar allowlist plus safety: 52/52 pass | Expected compile red: `ChatSearchCalendarView`, `ChatSearchCalendarDayCell` and layout policy absent | First focused runtime: 27/28 with one XCTest-only `Optional.none` inference error; explicit enum fixture correction then focused view/safety 28/28 pass; required post-task allowlist 67/67 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | feat(chat-search): add calendar date picker view | Added an immutable-snapshot custom UIKit sheet for iOS 15.6+: rounded public material/system surface, centered Search header, 44 pt X/month controls, semantic RTL navigation, localized weekday row, stable 7-column/4–6-row day grid, blank outside-month slots, selected/today/disabled/VoiceOver states, separate month/year pickers and 52 pt Done. Month renders use the shared 0.30 s slide or Reduce Motion crossfade while synchronizing title/grid/pickers. No `UICalendarView`-only path, private API, external asset, dependency, Realm/XMPP access or live UI flow was added. Main container remained `BEC303B1-8A3A-4A57-A699-28371F79622D`; Realm remained 22,315,008 bytes with unchanged mtime. |
| 17 | ready-to-commit | Required calendar-view/model/mode/list/keyboard allowlist plus safety: 65/65 pass | Expected compile red: calendar presentation request/plan/controller and owned overlay transition APIs absent | Focused presentation/state plus safety: 37/37 pass; required post-task allowlist: 91/91 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | feat(chat-search): present calendar overlay | Added one over-current-context child overlay with a 0.5 dim, bottom sheet, shared 0.40 s spring-in/0.30 s out, Reduce Motion fade, keyboard-before-layout preparation, chat/list origin preservation, explicit X-only dismissal, no automatic keyboard restore, idempotent presentation, generation/lifecycle interruption cleanup, adaptive relayout and accessibility focus transfer/return. Top and bottom chrome remain under the dim; arrows hide. Done only emits the selected timestamp for Task 19 and invokes no resolver. Main container remained `BEC303B1-8A3A-4A57-A699-28371F79622D`; Realm remained 22,315,008 bytes with unchanged mtime; no live UI flow ran. |
| 18 | ready-to-commit | Required calendar/result/anchor/first-frame allowlist plus safety: 140/140 pass | Expected compile red: timestamp request, detached anchor, coverage proof, typed outcome and resolver APIs absent | Focused resolver plus safety: 26/26 pass; required post-task allowlist: 145/145 pass | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | feat(chat-search): resolve date jumps locally | Added an injected background-Realm resolver that first evaluates displayed detached candidates, selects earliest at/after the exact timestamp or latest before it with numeric archive/primary tie ordering, and returns only detached typed outcomes. Read-only archive coverage distinguishes a final local answer from bounded `needsRemote` candidates for incomplete regular/group history; encrypted conversations always finish locally and never request MAM. Cancellation suppresses late Realm completion, scope/deletion/system/report filters are strict, and no UI or anchor opening occurs. Main container remained `BEC303B1-8A3A-4A57-A699-28371F79622D`; Realm remained 22,315,008 bytes with unchanged mtime; no live UI flow ran. |
| 19 | ready-to-commit | Required local/MAM/history/coverage/remote-apply/anchor allowlist plus safety: 136/136 passed | Expected compile-red: timestamp MAM request-plan/resolver/purpose/manager APIs absent | Focused timestamp MAM + safety: 32/32 passed; required post allowlist + safety: 155/155 passed | Passed on iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | `feat(chat-search): resolve date jumps through MAM` | Added at most two one-message XEP-0313 timestamp requests: exact `start` first, then exact `end` + empty `before` + `flip-page`; no `withtext`. Direct/group scope, final-IQ and persistence proof, generation/cancel/error guards, encrypted rejection, and no archive-coverage/history-cursor contamination are covered. Main container/Realm unchanged; no live UI flow. |
| 20 | ready-to-commit | Required calendar/local/MAM/open-anchor/mode selector plus safety: 128/128 passed | Expected compile-red: calendar completion coordinator/request/controller/factory APIs absent | First focused production run 24/24; final focused completion/safety selector 25/25; required post selector plus safety 139/139 passed | Passed on iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | `feat(chat-search): navigate to selected calendar date` | X preserves query/results/selection and invokes no resolver. Done dismisses once, captures the exact timestamp, clears search/list chrome, restores the composer, resolves local then bounded remote, and queues only the safe `.search` anchor with `highlight=false` and `markReadOnVisible=false`. Empty/error/cancel/background/duplicate paths are terminal. Main container/Realm unchanged; no live UI flow. |
| 21 | ready-to-commit | Required top/bottom/navigation/list/calendar/result-state allowlist plus safety: 92/92 passed | Expected runtime red: bottom counter timing remained 0.30 s instead of the reference 0.25 s (24/25); expected compile-red: shared chrome/counter transition, mutation policy, interruption coordinator and success-positioned haptic contracts absent | Focused motion/bottom/safety selector: 37/37 passed; required post selector plus safety: 104/104 passed | Passed on iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | `feat(chat-search): match search motion choreography` | One injected animation spec now drives top/bottom chrome, arrows, counter, list, calendar and month transitions. Chrome uses alpha 0↔1 and scale 0.01↔1 over the 0.30 s spring; arrows retain 0.2↔1; directional counter digits use 0.25 s ease-in-out. Generation-guarded property animators, navigation/first-frame/keyboard mutation policy and one reducer-final lifecycle cleanup prevent stale transforms or double animation. Haptic fires only after successful positioned commit. Reduce Motion is alpha-only; list/calendar plans are unchanged. Main container `BEC303B1-8A3A-4A57-A699-28371F79622D` and Realm remained unchanged; no live UI flow ran. |
| 22A | ready-to-commit | Required result/bottom/cell/calendar selector plus safety: 91/91 passed | Expected compile-red: centralized localization keys, six-form plural resources, formatting context/cache and localized formatting APIs absent | Focused localization/safety selector: 23/23 passed; required post selector plus safety: 115/115 passed; changed top-navigation accessibility regression slice: 40/40 passed | Passed on iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | `feat(chat-search): localize search interface` | Added one injectable localization/formatting boundary for every visible search, result-list and calendar term; en/ru resources include all six project plural forms. Position/count/date/month/weekday formatting is locale-, calendar- and timezone-aware with isolated reusable formatter caches and deterministic non-empty fallbacks. Locale changes preserve stable result/calendar identities; invalid positions never render `0 of N`. Hard-coded flow copy remains only as centralized development fallbacks. Main container `BEC303B1-8A3A-4A57-A699-28371F79622D` and 22,315,008-byte Realm with mtime `2026-07-13T23:37:37+0500` remained unchanged; no live UI flow ran. |
| 22B | ready-to-commit | Required localization/Info Card/top/bottom/navigation/result/calendar selector plus safety: 91/91 passed | Expected compile-red: centralized identifier catalog, dynamic row/day identity, semantic calendar configuration and controller ordering APIs absent. First implementation-focused run exposed two focused issues (19/21): loading required a dedicated accessibility proxy and one plain-label assertion was invalid; both were corrected. Additional expected compile-red captured the missing localized terminal-announcement/deduplication contract. | Final accessibility/safety selector: 22/22 passed; accessibility/calendar-completion regression: 35/35 passed; required post selector plus safety: 126/126 passed | Passed on iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | `feat(chat-search): add accessible search semantics` | Added one stable identifier catalog, localized labels/values/traits/hints, committed-only counter positions, older/newer boundary semantics, newest-first row positions, combined plain row announcements, unique day identities, selected/today non-color semantics, explicit search/list/calendar VoiceOver order, calendar focus transfer/return and immediate hiding of animated-out controls. Terminal no-result/date/search/positioning announcements are event/generation-deduplicated. Existing Info Card identifiers remain unchanged. The three supplied crash reports are duplicate evidence of the already fixed Task 05 test-only Realm default-configuration defect; all current runs used isolated hosted storage. Main container `BEC303B1-8A3A-4A57-A699-28371F79622D` and 22,315,008-byte Realm with mtime `2026-07-13T23:37:37+0500` remained unchanged; no live UI flow ran. |
| 22C | ready-to-commit | Required accessibility/localization/top/bottom/result/calendar/motion selector plus safety: 106/106 passed | Expected compile-red: shared adaptive environment/appearance/layout/contrast policies, consumer trait application, RTL geometry, opaque Reduce Transparency surfaces, expanded hit frames and vertically scrollable calendar overflow were absent. First focused implementation run was 20/23 with native glass still attached to two bottom surfaces and one semantic-color contrast failure; focused correction reran 23/23. First full post run was 155/156 because the accessible selected fill changed an existing nominal `systemBlue` contract; the fill was restored and foreground contrast made trait-adaptive. | Focused adaptive/safety selector: 23/23 passed; required post selector plus safety: 156/156 passed | Passed on iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | `fix(chat-search): harden adaptive search layout` | Added one shared UIKit adaptive policy for maximum Dynamic Type, RTL, Increase Contrast, Differentiate Without Color, Reduce Transparency and Reduce Motion. Nominal geometry remains unchanged; result rows and calendar grow vertically, landscape calendar overflow scrolls only vertically, visible controls expose at least 44 pt accessibility frames, selected/today states gain non-color cues, semantic colors are contrast-checked and opaque surfaces remove iOS 26 glass deterministically. Main container `BEC303B1-8A3A-4A57-A699-28371F79622D` and 22,315,008-byte Realm with mtime `2026-07-13T23:37:37+0500` remained unchanged; no live UI flow ran. |
| 23 | ready-to-commit | Initial B0 exposed one stale reducer fixture (96/97); fixture-focused rerun passed 14/14, repaired B0 passed 97/97, and required accessibility/localization/mode/calendar selector plus safety passed 57/57 | Expected compile-red: `ChatSearchLiveQASafetyPolicy` and its opt-in/destination/destructive-input/account/teardown contracts were absent | Focused policy/safety selector: 21/21 passed; required post selector plus real accessibility/localization classes and safety: 43/43 passed; UI smoke target compile-only `build-for-testing` reported `TEST BUILD SUCCEEDED` | Passed on iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | `test(chat-search): add guarded UI test target` | Added a deployment-15.6 `xabberUITests` bundle with an explicit `xabber` dependency and shared-scheme membership. The pure gate requires exact opt-in and simulator identity, rejects reset/erase/logout/account/data/Realm cleanup inputs, fixes dialog candidates to Andrew Nenakhov then Alexey Boldin and query to `test`, forbids login/account mutation, and limits teardown to search cancellation/process termination. The skeleton evaluates the gate before any `XCUIApplication` can exist and then skips until Task 24. No UI executable was run. Compile-only verification preserved main container `BEC303B1-8A3A-4A57-A699-28371F79622D` and the 22,315,008-byte Realm with mtime `2026-07-13T23:37:37+0500`. |
| 25D | ready-to-commit | Initial required allowlist: 80/81 passed; isolated rerun reproduced the same existing zero-delay scheduler fixture failure. After fixture correction, full post selector passed 95/95. | Expected compile-red: typed authentication safety/revocation evidence, notification parser and processing gate were absent. Behavioral red: replacement credential still retained the local invalidated state (13/14). | Focused policy green: 14/14; required post selector: 95/95. | Passed — cached build on iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` without clean. | `fix(auth): preserve accounts for missing credentials` | Missing local password/token/secret and local invalidation now require recoverable re-authentication without account/history deletion or false `Access revoked`; only typed current-primary `account-disabled` or validated matching-device server headline can request idempotent destructive revoke. Fixed bundle install-over preserved data container `FEAE8E9A-E87A-4039-AB49-AFC70F15FECD` and Realm inode `171969950`. After owner login, two ordinary process launches at 12:13:58 and 12:14:20 both returned to the signed-in Chats shell with Andrew Nenakhov and Alexey Boldin present; the container/inode stayed unchanged and filtered logs contained no revocation, account deletion or `Access revoked` event. No uninstall, storage cleanup, logout or automated credential entry occurred. |
| 25E | ready-to-commit | Main container `1D6CF842-ED1C-43DD-8A58-581D958DD486` and Realm inode `171969950` recorded; safe compile-only existing safety preflight reported `TEST BUILD SUCCEEDED`. Confirmed destructive hosted reproducer was deliberately not rerun pre-fix. | Expected compile-red: `resolvedCredentialsStore` and `hostedXCTestServiceSuffix` were absent. First production compile then exposed that app-only policy was unavailable to the shared push target, so the exact gate was moved to a Foundation-only shared policy. | New hosted credential suite: 6/6 passed; required hosted auth/safety post allowlist: 61/61 passed. A bounded ordinary main launch after each hosted run remained signed in and logged redacted `credential present=true` plus `authSucceeded`. | Passed — cached build on iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` without clean; main container, Realm inode/size/mtime remained unchanged by the build. | `test(infrastructure): isolate hosted XCTest credentials` | Exact hosted marker plus both safety flags now select stable service `xabber.ios.hosted-xctest` while normal/incomplete environments keep bundled `xabber.ios`; the authorized access group is unchanged. Realm and credential isolation use one shared gate. Hosted onboarding cleanup therefore cannot address the user's service. Post-hosted main launches preserved the same container/Realm and signed-in Chats shell; no uninstall, reset, logout, account mutation or credential-value access occurred. |
| 24 | ready-to-commit | Resumed hosted pre-task allowlist passed 56/56 with both isolation flags; the no-opt-in UI smoke skipped 1/1 before application construction | Expected red/failure evidence: glass styling forced the manually framed search buttons back into Auto Layout (`translatesAutoresizingMaskIntoConstraints=false`), collapsing/overlapping the leading magnifier; a moved-ancestor accessibility regression exposed stale cached arrow frames; early live attempts exposed stale arrow hit frames, 261-row eager enumeration, keyboard-blocked list scrolling and a 194 s budget overrun | Focused magnifier plus safety selector passed 14/14; moved-ancestor accessibility regression passed; final hosted post allowlist passed 49/49; guarded live smoke passed 1/1 in 170.592 s with four xcresult screenshots | Passed on iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | `test(chat-search): cover live search parity flow` | Guarded live QA used Andrew Nenakhov and exact query `test`, found 261 results, verified 1→2→1 navigation, non-wrapping 261/261 boundary, interactive keyboard dismissal, chat/list transitions, calendar month/grid and X preservation, then restored the signed-in chat shell. The compact optically inset magnifier now stays inside its 44 pt manual hit frame; navigation arrows derive dynamic accessibility frames after ancestor movement. Teardown only terminated the process. No uninstall/reset/logout/account/storage/credential mutation ran. Install-over rotated the app container UUID to `B606486A-A544-4C2F-8FB8-BCE763C48DA6` while preserving Realm inode `171969950`; the bounded post-hosted main launch still showed Andrew Nenakhov and Alexey Boldin, proving the account remained present. |
| 25A | ready-to-commit | Required session/MAM/local/navigation/mode/calendar allowlist passed 102/102 with both hosted-isolation flags | Expected compile-red: `ChatSearchLocalProvider.Phase.cancelled` was absent. The first focused production run then exposed an uninitialized search-panel dereference during pre-view-load arrow coalescing; the focused regression fixed that lifecycle edge. | Focused stress/safety selector passed 24/24; required post-task allowlist passed 129/129 | Passed on iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | `fix(chat-search): harden cancellation races` | Query retries after failure receive a fresh generation; replaced/cancelled local and timestamp requests emit one typed cancellation and suppress stale batches, persistence completions and callbacks. Stress coverage proves 100 query replacements, debounce/final-IQ cancellation, repeated-cursor termination, Realm batch cancellation, timestamp replacement, 100 coalesced arrow intents and 20 interrupted list/calendar transitions without sleeps. Pre-view-load navigation no longer dereferences an absent input panel. Hosted tests used isolated Realm/Keychain and disabled account autoconnect; no live UI, uninstall, reset, logout, credential or production-storage mutation ran. |
| 25B | ready-to-commit | Required stress/presentation/local/highlighting/list/reload/cache pre-task allowlist passed 75/75 with both hosted-isolation flags | Measured current-code baseline passed 4/4 and recorded 7.743 ms/15.945 ms preparation, 2.059x scaling, 8.758 ms snapshot construction and 28.074 ms main apply. Expected compile-red then proved immutable prepared-result reuse, list ownership and bounded highlight-cache contracts were absent. | Focused performance/highlighting/list slice passed 34/34; final performance slice passed 8/8 with 7.468 ms/16.222 ms preparation, 2.172x scaling, 0.963 ms snapshot construction and 1.984 ms main apply; required post allowlist plus result-cell/safety regressions passed 118/118 | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | perf(chat-search): optimize large result flows | Added one immutable normalized result batch reused by render model, snapshot plan and controller, eliminating duplicate mapping/dedup/index construction. Added bounded immutable highlighting reuse for unchanged source/query/locale/style, preserved four-page anchors and unchanged-row behavior, and kept avatar work lazy/cancellable. Preparation remains off-main-capable and UIKit apply main-only; ordering/dedup correctness is unchanged. Durable budgets and before/after numbers are recorded in `docs/testing/chat-search-performance-budgets.md`. No live UI, install, reset, logout, credential or production-storage operation ran. |
| 25C | ready-to-commit | Required performance/stress/mode/calendar/list/first-frame/datasource pre-task allowlist passed 102/102 with both hosted-isolation flags | Expected compile-red: lifecycle interruption/session-scope/cache/observer-removal APIs were absent. First implementation run passed 22/25 and exposed retained removed list/keyboard hierarchy; after constraint cleanup and deterministic autorelease boundaries, 9/10 passed and exposed the remaining controller retain cycle through composer delegates and search-panel method callbacks. | Focused lifecycle suite passed 10/10; required post-task allowlist plus safety passed 154/154 | pass — `tools/xcodebuild_cached.sh build`, iPhone 16e `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` | fix(chat-search): close lifecycle leaks | Added one idempotent lifecycle owner for navigation, background/foreground, rotation, memory warning and scope changes. It cancels debounce/local/MAM/timestamp work, unregisters callbacks, releases child controllers/constraints/avatar requests, clears only expendable search caches and restores normal chat UI. Remote callbacks and composer/search-panel ownership are weak; 50 open/cancel cycles and weak deallocation assertions pass without sleeps. No live UI, install, uninstall, reset, logout, credential or production-storage operation ran. |
| 26A | pending | — | — | — | — | — | — |
| 26B | pending | — | — | — | — | — | — |
| 26C | pending | — | — | — | — | — | — |

## 14. Durable project links

- Vault task: /Users/igor.boldin/projects/xabber/xabber/projects/xabber/tasks/open/xab-telegram-style-in-chat-search-goal-plan.md
- Handoff: /Users/igor.boldin/projects/xabber/xabber/projects/xabber/handoffs/outgoing/2026-07-13-ui-to-xmpp-tests-telegram-style-in-chat-search.md
- Shared interfaces: /Users/igor.boldin/projects/xabber/xabber/projects/xabber/shared/interfaces.md
- UI context: /Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/ui/context.md
- XMPP context: /Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/xmpp/context.md
- Tests context: /Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/tests/context.md
- Knowledge archive strategy: /Users/igor.boldin/projects/xabber/xabber-knowledge/architecture/message-archive-strategy.md
- Knowledge chat open behavior: /Users/igor.boldin/projects/xabber/xabber-knowledge/behavioral-specs/chat/chat-open-and-scroll-behavior.md
