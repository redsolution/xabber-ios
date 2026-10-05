# OMEMO2 — план исправления подтверждённых недоработок по стандарту

Дата: 2026-10-05. Production baseline: app `f9bbfe47`, Signal C `7552b1b`, Signal ObjC `d142b4d`; app HEAD перед планированием `592a06bc` менял только документы. Проверены оригиналы [XEP-0384 0.9.1](https://xmpp.org/extensions/xep-0384.html) и [XEP-0420 0.5.0](https://xmpp.org/extensions/xep-0420.html), KB и три независимых read-only source reviews.

Это **активный ограниченный план** по запросу пользователя. Он заменяет широкий [предыдущий план](omemo2-implementation-plan.md) для дальнейшей реализации. Включены только подтверждённые нормативные gaps: MUST отдельно от SHOULD. Способ реализации описан для каждой задачи, но не объявляется частью XEP.

## Границы

- Scope: существующие 1:1, own-device sync и редактирование их encrypted content. Identity, device ID, история и существующее доверие сохраняются.
- По указанию пользователя: markers/receipts открытые, fallback body остаётся, новых store hints нет; процесс обмена доверием не меняется. Эти исключения не входят в новый backlog; полное буквальное SCE sending conformance с ними не заявляется.
- Journal/inbox/outbox, all-recipient atomic rollback, exact retry/transport ACK, persisted account-wide catch-up proof, отдельные fuzz/sanitizer/interop-hardening задачи исключены. Необходимые небольшие metadata/migrations допустимы как реализация конкретной нормы.
- TTL, retract/server rewrite wrapper, optional labels и standard MUC не включены: для первых нет подтверждённого нарушения общей нормы в их server/client семантике; MUC — отдельная возможность.
- OM2-01 receive/provenance, OM2-02 EME и OM2-04 affixes/padding завершены. Replenish100/min25, initial empty reply, heartbeat, generic decrypt warning, chat-open devices refresh уже есть; не ставить их повторную реализацию как новые задачи.

## Нормативная матрица

| Задача | Прямая норма | Уровень |
| --- | --- | --- |
| N01: devices | Актуальный devices list и recipients из него: [§5.2/5.5.2](https://xmpp.org/extensions/xep-0384.html#encrypt); unknown SID refresh: [§6](https://xmpp.org/extensions/xep-0384.html#rules). | MUST; refresh SHOULD |
| N02: own registration | Collision check, own-ID reannounce; deactivation cleanup: [§5.3.1/6](https://xmpp.org/extensions/xep-0384.html#devices). | MUST; cleanup SHOULD |
| N03: encrypted edit | Защита sensitive content: [SCE §7/9](https://xmpp.org/extensions/xep-0420.html#sending), [OMEMO §5.5](https://xmpp.org/extensions/xep-0384.html#usecases-messagesend). | Применение общего обязательного правила |
| N04: replay/keys | Silent known duplicate; конечное хранение skipped keys: [§4.3/6](https://xmpp.org/extensions/xep-0384.html#protocol-double_ratchet). | MUST; retention SHOULD NOT |
| N05: SPK | Периодическая ротация и grace: [§4.2](https://xmpp.org/extensions/xep-0384.html#protocol-key_exchange). | SHOULD |
| N06: consumed OPK | Eventual private-key deletion; delayed cleanup и empty reply: [§5.6/6/8](https://xmpp.org/extensions/xep-0384.html#usecases-receiving). | MUST; delay SHOULD; reply при отсрочке MUST |
| N07: session replacement | Manual replacement; no-session recovery; no automatic reset on decrypt error: [§6/8](https://xmpp.org/extensions/xep-0384.html#rules). | MUST; recovery SHOULD; auto-reset MUST NOT |
| N08: opt-out | Подтверждение перехода на plaintext и send block: [§5.7](https://xmpp.org/extensions/xep-0384.html#opt-out). | MUST; display/session preservation SHOULD |
| N09: incoming trust indication | Отображение недоверенного authenticated sender: [§8](https://xmpp.org/extensions/xep-0384.html#security). | SHOULD |

N05/N09 — недоработки рекомендаций, а не нарушения MUST. Рекомендательные части остальных задач также проверяются отдельно.

## OM2-N01

**Статус:** выполнено; [реализация и проверка](omemo2-n01-devices.md), 89/89 XCTest.

**Актуальный devices list и корректный набор получателей.** Старый OM2-05. Владелец: xmpp. Зависимости: нет.

**Пробел:** `OmemoManager+Encryption.swift:281–301` выбирает trusted rows без node membership; rows также создаются из bundle (`OmemoManager.swift:850`) и incoming (`:1259`). Parser `:551` выбирает child по имени. IQ/event updates не защищены от старого IQ, перезаписывающего новый PEP list. Direct unknown-SID refresh отсутствует; chat-open force fetch и +notify уже существуют.

**Реализация:** общий QName parser devices; authoritative snapshot membership отдельно от существующего trust/key predicate. Bundle/incoming не добавляют membership. Unknown snapshot требует fetch, verified empty/removed list исключает recipients. Старый IQ не заменяет более новый PEP snapshot. Unknown SID запускает direct fetch без eager user-content session creation. Миграция сохраняет trust/history, не считает legacy identity rows доказательством membership. Cache TTL и новый subscribe mechanism не обязательны и не планируются сами по себе.

**Файлы:** `OmemoManager.swift`, `OmemoManager+Encryption.swift`, device/snapshot model; `RealmMigrations.swift` только при изменении модели.

**XCTest:** `OMEMO2NormativeDevicesTests.swift` — trusted unsolicited bundle вне node, removed/empty list, foreign/prefixed QName, stale IQ после PEP, unknown SID refresh, own devices исключают local ID; тест захватывает фактические recipients отправки.

## OM2-N02

**Статус:** выполнено; [реализация и проверка](omemo2-n02-registration.md), 16/16 focused XCTest.

**Регистрация собственного устройства и reannounce.** Старый OM2-06. Владелец: xmpp. Зависимость: N01.

**Пробел:** fresh ID выбирается до own-list (`Encryption:145–165`); own headline без local ID не вызывает reannounce (`OmemoManager:638`). Disable вызывает публикацию bundle (`BundlePublication:233–234`); retract method `:204` не подключён.

**Реализация:** до фиксации fresh SID/первой bundle publication получить own node и выбрать свободный ID; restart незавершённой регистрации не обходит проверку. Existing/migrated ID не менять. Пока OMEMO включён, own PEP без local ID → полученный список + local ID → публикация. Не использовать identity rows вместо server list. Disable удаляет local ID из node и retract own bundle, сохраняя локальные ключи/history; subsequent own PEP не вызывает reannounce выключенного устройства. Optional neighboring labels не становятся отдельной нормативной задачей.

**Файлы:** `OmemoManager.swift`, `OmemoManager+Encryption.swift`, `OmemoManager+BundlePublication.swift`, `AccountEncryptionInfoViewController.swift`.

**XCTest:** `OMEMO2NormativeRegistrationTests.swift` — deterministic collision, existing-ID continuity, empty own node, reannounce с сохранением остальных IDs, restart до first publication, disable без повторной bundle publication.

## OM2-N03

**Защищённый текст редактирования.** Ограниченный старый OM2-03. Владелец: xmpp/business. Зависимость для завершения: N01; sender работу можно начинать независимо.

**Пробел:** `MessageManager+CommonSender.swift:757–775` создаёт plaintext edit body/references; `MessageDeleteManager.swift:541–560` отправляет replacement как есть даже для encrypted conversation. Это раскрывает новый пользовательский текст. Receive для nested rewrite уже подготовлен (`OmemoManager:1066–1082`).

**Реализация:** embedded replacement message в encrypted conversation проходит существующий SCE/OMEMO builder и EME normalization. Сохранить server-visible rewrite IQ, target IDs и routing. Обычный plaintext edit не меняется. Encrypt failure отменяет отправку replacement. Не шифровать server wrapper и не переносить TTL/retract по предположению.

**Файлы:** `MessageManager+CommonSender.swift`, `MessageDeleteManager.swift`, существующий OMEMO sender adapter. Signal forks не нужны.

**XCTest:** `OMEMO2NormativeEditTests.swift` — final rewrite IQ не раскрывает новый text/references; настоящий decrypt восстанавливает edit; IDs/routing и обычное редактирование сохранены; encryption failure не отправляет plaintext replacement.

## OM2-N04

**Подтверждённые повторы и skipped-key retention.** Ограниченный старый OM2-07. Владелец: xmpp. Зависимости: нет; можно параллельно N01.

**Пробел:** C `omemo_session.c:417–427` old-DH replay может завершаться MAC failure; `:424` объявляет duplicate по счётчику до MAC. Swift candidate loop `XabberOMEMO2Storage.swift:319–333` теряет duplicate. FIFO/MAX_SKIP уже есть, но skipped keys без возрастной/event policy могут сохраняться бессрочно (`omemo_session.c:13–31,339–357,636–649`).

**Реализация:** duplicate разрешён только для точно ранее проверенного encrypted key+payload с привязкой к owner/sender/device. Небольшой authenticated receipt metadata в существующем protected state и доказанно проверенный ciphertext истории допустимы; MAM ID и счётчик не доказательство. C duplicate outcome считается кандидатом, пока нет такой проверки. Проверку записать после crypto+SCE/bindings; не терять её при переборе snapshots. Изменённый MAC/payload остаётся ошибкой.

Для skipped keys выбрать конечную политику по числу последующих успешно принятых сообщений/ratchet transitions; добавить event age и snapshot version с чтением v1 без reset. Конкретная граница — параметр клиента. Crypto/SCE failure не продвигает committed age. Полный inbox/journal не добавляется.

**Файлы/пакеты:** `XabberOMEMO2Storage.swift`, `OmemoManager.swift`; Signal C `src/omemo_session.c` и `tests/test_omemo_session.c`. ObjC только при необходимости API change; app pins/patches обновляются с соответствующим fork commit.

**Тесты:** C regression первым; `OMEMO2NormativeReplayTests.swift` — DH change, KEX/regular, несколько snapshots, restart, live/MAM/carbon; modified MAC/key/payload не silent duplicate. Out-of-order до retention boundary, удаление после него, v1 migration, FIFO/MAX_SKIP и rollback при failed SCE.

## OM2-N05

**Работающая периодическая ротация SPK.** Рекомендательная часть старого OM2-10. Владелец: xmpp. Зависимость: N02 для общего publication lifecycle.

**Пробел:** rotation/grace существуют (`Storage:394–410`), но due check только в `prepare` (`:150`); обычный `ensureOMEMO2Prepared` читает `localBundle` (`Encryption:169–184`). Длительное соединение не обеспечивает ротацию. Обычная publication error оставляет флаг без ближайшей повторной попытки.

**Реализация:** одна idempotent due-maintenance операция на существующих auth/foreground/send/receive hooks с ограничением частоты. Сохранить выбранный weekly interval и grace, подключить существующую bundle publication после изменения; использовать её pending/retry lifecycle при ошибке/timeout. Не переписывать работающие replenish100/min25, hash ACK и config retry. Не вводить новый scheduler/outbox.

**Файлы:** `XabberOMEMO2Storage.swift`, `OmemoManager+Encryption.swift`, `OmemoManager+BundlePublication.swift`, существующий account lifecycle hook.

**XCTest:** `OMEMO2NormativeKeyMaintenanceTests.swift` — длительное соединение, due foreground/send, delayed old-SPK KEX в grace, failed publish→retry, stale hash ACK; регрессия опубликованного bundle≥25.

## OM2-N06

**Конечное удаление использованных private OPK.** Ограниченный старый OM2-11. Владелец: xmpp. Зависимости: N04/N05 для совместимых snapshots/key lifecycle.

**Пробел:** `XabberOMEMO2Storage.finishCatchUp:385` вызывается только тестами. Used private OPK в production остаётся бессрочно. Empty reply при delayed cleanup уже сформирован и отправляется существующим control sender; это не новая control implementation task.

**Реализация:** сохранить текущую delayed policy, связав consumed OPK с соответствующей существующей catch-up/query chain. Очистка — после завершения chain и принятия её decrypt через existing archive accounting/ingress barrier; не по отдельному raw `<fin>`/page/sync. Существующий global cleanup не вызывать, пока другие ключи имеют незавершённый охват; дать storage конкретные eligible OPK. Возобновление или окончательное прекращение chain не оставляет keys бессрочно. Known-EK snapshots остаются для позднего KEX. Для неархивного ingress без незавершённого catch-up очистить после успешного сохранения session.

Немедленное deletion разрешено XEP §8, но новый план сохраняет рекомендованную отсрочку для активного catch-up. Persisted account-wide proof/history+outbox transaction не вводится.

**Файлы:** `XabberOMEMO2Storage.swift`, `OmemoManager.swift`, `MessageArchiveManager`/delegate и существующие query accounting hooks.

**XCTest:** `OMEMO2NormativePreKeyCleanupTests.swift` — несколько pages/chains, controls-only page, interruption/restart и terminal completion; consumed key сохраняется до eligible boundary и затем удаляется; known-EK KEX работает после удаления; unknown-EK с удалённым OPK отклоняется; existing empty reply не создаёт bubble.

## OM2-N07

**Ручная замена session и missing-session recovery.** Часть старого OM2-12. Владелец: xmpp/UI. Зависимости: N01/N04.

**Пробел:** `deleteSessions:354` используется только при key change; пользовательской команды нет. `makeOMEMO2Control` требует session (`Encryption:316`), missing-session ingress возвращает failed.

**Реализация:** одна явная manual replacement команда в существующем encryption settings; global reset достаточен, per-chat UX не обязательный deliverable. Инвалидировать current outgoing sessions, сохранить identity/device ID/trust/history; existing archived snapshots оставить receive-only как проектное решение сохранения delayed history. Перед следующей отправкой принудительно получить свежий bundle и построить новую session, без повторного выбора уже использованного cached OPK и без выдачи trust.

SHOULD recovery: только при доказанном отсутствии session для валидного non-KEX создать eligible empty KEX/control через существующий builder. MAC/format/identity/storage failure и receive-only state не равны missing session; они не запускают автоматический reset. User content через untrusted sessions по-прежнему запрещён. Generic decrypt warnings уже существуют; отдельная error-taxonomy/UX задача не нужна.

**Файлы:** `XabberOMEMO2Storage.swift`, `OmemoManager.swift`, `OmemoManager+Encryption.swift`, `AccountEncryptionInfoViewController.swift`.

**XCTest:** `OMEMO2NormativeSessionRecoveryTests.swift` — новый EK после manual command, сохранение identity/trust/history и delayed receives, save failure без частичного reset; missing-session получает empty control; genuine MAC/invalid SCE не меняют session, no content/no trust grant.

## OM2-N08

**Проверенный opt-out и запрет отправки до решения.** Часть старого OM2-12. Владелец: xmpp/business/UI. Зависимости: N01/N03/N04 (общие sender paths и подтверждённые повторы).

**Пробел:** opt-out receive/state отсутствует; send availability учитывает trust, без pending opt-out gate.

**Реализация:** распознавать QName `{urn:xmpp:omemo:2}opt-out` только из verified SCE от фактического peer; outgoing sent-carbon не считать просьбой peer. Pending decision привязан к peer/account conversation и переживает restart; существующие ratchets сохраняются. Блокировать все исходящие message для данного peer до явного подтверждения, а не только composer: основной send, attachments, edit, retry/scheduled и message extensions проходят один gate. Markers/receipts не шифруются; pending gate не является новым требованием их шифрования. Не создавать неописанное исключение для system/control sends: проверить их порядок относительно activation/confirmation. Подтверждение разрешает plaintext, отказ/возврат к OMEMO сохраняет session; повтор archive/carbon не отменяет более позднее решение. Sender/UI для инициирования opt-out не обязателен и не входит в задачу.

**Файлы:** `OmemoManager.swift`, receive metadata, `OmemoManager+Encryption.swift`, `MessageManager+CommonSender.swift`, existing send availability/conversation settings.

**XCTest:** `OMEMO2NormativeOptOutTests.swift` — verified vs outer/foreign/failed-decrypt opt-out; sent-carbon не выдаёт own request за peer request; все message send routes; restart, подтверждение и archive/carbon replay; сохраняемые ratchets; plaintext разрешён только явным решением.

## OM2-N09

**Признак недоверенного отправителя входящего сообщения.** Рекомендательная часть старого OM2-12. Владелец: xmpp/UI. Зависимости: N01/N04.

**Пробел:** authenticated incoming допускается через untrusted session, но provenance/materialization не передаёт доверие фактического sender key. Исходящая warning о пропущенных untrusted devices это не заменяет.

**Реализация:** read-only оценка фактического authenticated sender identity по существующему trust/key predicate; отдельные внутренние receive metadata → обычный и search materializers → существующее warning presentation. Device ID и network XML сами по себе не устанавливают trusted. Для archived snapshot оценивать его actual key, а не автоматически current key. Trust exchange/коды/выдачу доверия не менять.

**Файлы:** `MessageEncryptionProvenance`/receive metadata, `OmemoManager.swift`, `MessageManager+CommonReceiver.swift`, search materializer и существующий message warning renderer/model.

**XCTest:** `OMEMO2NormativeIncomingTrustTests.swift` — trusted/untrusted actual key, changed key/archived snapshot, live/MAM/carbon/search; controls/duplicates без bubbles/warnings; внешнее XML не задаёт trust indication.

## Порядок реализации

1. **N01 → N02:** получатели и собственная PEP registration. N04 можно начать параллельно в Signal C, сериализуя изменения общего storage.
2. **N03:** убрать plaintext replacement при edit; использовать уже работающий SCE/EME.
3. **N04 → N05 → N06:** подтверждённые повторы/retention, due SPK lifecycle и finite consumed-OPK cleanup.
4. **N07 → N08 → N09:** manual/missing-session recovery, opt-out gate и incoming trust indication.

Следующая задача — **OM2-N01**. Приоритет MUST внутри смешанных задач выше SHOULD; N05/N09 можно выполнить после обязательных частей, не называя их MUST violations. Не добавлять зависимости на отложенные journal/outbox/MUC/trust-exchange задачи.

## Проверка каждой реализации

Focused test сначала → воспроизводимое падение при возможности → production fix → affected tests. App: `tools/xcodebuild_cached.sh test`, scheme `Debug`, concrete Simulator; successful test action с affected app/push build выполняет build gate. C: affected CTest regression; relevant analyzer/sanitizer только для изменённых C paths. Fork commits → app pins/patches → app test. Без clean/cache reset.

Final XML, настоящие ciphertext, реальный route, restart/migration проверяются там, где это доказывает конкретную норму. Единую traceability table вести внутри задач: clause → failing path → focused test → result. Отдельного QA implementation task нет. Каждый завершённый fix получает отдельный focused commit и vault update.

**Завершение ограниченного плана:** подтверждённые MUST gaps закрыты, SHOULD gaps реализованы либо имеют явное обоснование; сохраняются согласованные исключения и отложенный optional scope. Нет заявления, что этот список — полный повторный аудит всех строк XEP или доказательство live interop.

## Результат планирования

Production/dependency/test код не менялся, build/test не запускались: запрос касался отбора и планирования. Новые implementation tasks остаются open; эта planning task завершена. Результаты прежних XCTest не выдаются за проверку будущих исправлений.
