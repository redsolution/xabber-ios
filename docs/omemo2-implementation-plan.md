# План приведения Xabber iOS к OMEMO2

**Статус 2026-10-05:** для дальнейшей реализации действует [ограниченный план подтверждённых нормативных gaps](omemo2-standard-compliance-plan.md), OM2-N01–N09. Этот широкий план сохранён как история предложений; journal/outbox/atomic batch/дополнительные QA и MUC не входят в текущий объём. Следующая задача — OM2-N01.

Дата: 2026-10-02. Основание: [аудит текущей реализации](omemo2-conformance-status-2026-10-02.md). Production baseline: app `524f46ba`, Signal C `7552b1be`, ObjC `d142b4db`.

[Реестр самостоятельных задач в vault](/Users/igor.boldin/projects/xabber/xabber/projects/xabber/docs/architecture/omemo2-implementation-plan-without-trust-exchange-2026-10-02.md).

## Цель и границы

Привести криптографический, XML, device/session и recovery слои iOS к XEP-0384 0.9.1 и XEP-0420 0.5.0. Существующий API доверия является внешним входом: отправка content по-прежнему требует trusted устройства и совпадающего ключа. AKE, проверка кодов, авторизация/канонизация TrustSharing и способы установления доверия отложены по прямому указанию пользователя.

Общая OMEMO упаковка существующего encrypted custom content может быть исправлена: payload и процесс обмена доверием остаются прежними. Новые session reset, opt-out и indication ошибок относятся к поведению OMEMO. При изменении identity сохраняется действующая политика key-change, без новых способов выдавать trust.

Основные13 задач включают применимые требования 1:1/own-device sync, рекомендации XEP, надёжность интеграции и нашу приёмку. Это не перечень13 обязательных норм стандарта. OM2-14 описывает стандартный MUC отдельно: его требования действуют при поддержке этого сценария. Custom Xabber Groups не равны MUC. Этот план не обещает поддержку всех необязательных функций XMPP.

## Нормативное основание и инженерный объём

[Разделение по задачам и ссылки на оригинальные XEP](omemo2-remaining-work-2026-10-05.md#нормы-протокола-и-предложенная-реализация) уточнено 2026-10-05. MUST обозначает обязанность, SHOULD — рекомендацию. Детали предлагаемой реализации и критерии наших тестов не становятся требованиями XEP из-за включения в задачу.

- OM2-08 и архитектурная часть OM2-09 (journal, atomic recipient batch, outbox, transport ACK) — надёжность приложения; OMEMO/SCE не предписывают эти структуры. Peer empty replies/heartbeat рассматриваются отдельно, с их MUST/SHOULD.
- Persisted account-wide catch-up proof в OM2-11 — выбранная delayed-cleanup стратегия. Eventual private-OPK deletion обязательна; задержка до catch-up рекомендована, немедленное удаление разрешено.
- OM2-13 — методы нашей приёмки, включая независимый обмен, XCTest, fuzz и sanitizers. Это не отдельные wire требования.
- Xabber edit/rewrite/TTL требуют применения общего SCE правила и проверки серверного контракта; таких расширений по имени в XEP нет. Для TTL сначала установить client/server семантику.
- Per-chat reset, weekly rotation, 512-byte minimum и ±300-second margin — решения клиента. XEP допускает global manual reset и не фиксирует выбранные padding/margin числа.

Минимальный объём соответствия протоколу и дополнительный инженерный объём следует оценивать отдельно; число открытых задач не равно числу нарушенных обязательных норм.

## Сохраняемые инварианты

- Existing/migrated identity scalar, device ID, manual trust при том же canonical ключе и локальная история сохраняются.
- Legacy Signal snapshots остаются отдельно; ошибки нового MAC не выбирают legacy decoder и не создают новую identity/session автоматически.
- До user-content send проверяются текущие membership и существующий trust/key predicate. Empty ratchet controls имеют отдельную eligibility policy.
- Replay и control не становятся пользовательским текстом. Valid message не теряется между secret commit и history persistence.
- Corrupt/inaccessible/unknown-version protected state завершает операцию ошибкой; миграция никогда не начинается с пустой identity вместо сохранённой.
- Все schema/snapshot migrations проверяются на реальных v1 fixtures. Проекты/forks обновляются согласованно с pins/patches.

## Порядок выполнения

| Этап | Задачи | Результат |
| --- | --- | --- |
| 1 | OM2-01 → OM2-02 | Проверенный приём и корректный final wire |
| 2 | OM2-03, OM2-04 | Все используемые sensitive extensions в SCE; affixes/time/padding |
| 3 | OM2-05 → OM2-06 | Актуальные получатели и корректная регистрация/PEP repair |
| 4 | OM2-07 → OM2-08 | Replay/snapshot migration и восстанавливаемый plaintext inbox |
| 5 | OM2-09 → OM2-10 | Атомарные recipient batches, control outbox и key maintenance |
| 6 | OM2-11 → OM2-12 | Доказанный catch-up cleanup, session recovery и opt-out |
| 7 | OM2-13 | Матрица требований, static checks и независимый обмен |
| 8 | OM2-14 | Standard MUC при включении этой возможности |

Независимо можно начинать OM2-01 и OM2-07. Parser/snapshot части OM2-05 можно готовить параллельно, а интеграция receive hooks следует за OM2-01. Изменения одного файла/контракта сериализуются. OM2-13 формирует acceptance matrix с первого этапа; финальное peer испытание проводится после core tasks. Этапы не являются обещанием календарного срока.

## Задачи и критерии завершения

### OM2-01 — Единый проверенный приём SCE

**Уровень:** MUST. **Владелец:** xmpp. **Зависимости:** нет.

**Реализация:** [контракт проверенного приёма](omemo2-sce-receive.md), 2026-10-02. Подготовка live/MAM/carbon/sync/push, внутренний provenance и QName consumers реализованы; результаты финального Simulator gate находятся в завершённой задаче vault. Следующая задача — OM2-03; OM2-02 выполнена в уточнённом объёме.

**Компоненты:** `Omemo2PayloadCodec.swift`, `OmemoManager.swift`, `AccountStreamDelegate.swift`, `MessageManager+CommonReceiver.swift`, `MessageReferenceParser.swift`.

- Возвращать типизированный результат: проверенное содержимое, control, duplicate или ошибка; provenance передавать вне сетевого XML.
- Выбирать элементы по localName+URI; игнорировать plaintext envelope, внешние sensitive extensions и wire omemo-result__system; удалить server-processed элементы внутри SCE, включая EME.
- Провести live, MAM, carbon, sync-preview, push и modify через общий decoder/reconstruction до специальных клиентских routers; сохранить проверенные routing/archive metadata.

**Приёмка:**

- Подлинный ciphertext с внешними reference/ephemeral/markers/internal success marker не меняет содержимое, TTL и статус decrypt.
- Foreign/prefixed content/body, attachment-only payload и malformed XML; реальные forwarded wrappers; controls/replays не создают bubbles.

### OM2-02 — EME по фактическому профилю отправки

**Уровень:** MUST для EME. **Владелец:** xmpp. **Зависимости:** OM2-01.

**Реализовано:** [EME contract и проверка](omemo2-outgoing-eme.md), 2026-10-02. 126 focused XCTest прошли; app и push extension собраны.

**Уточнение пользователя, 2026-10-02:** выполнить согласование EME. Fallback `body` сохраняется; новые `store` hints не добавляются, существующие hints остаются. Маркеры доставки, квитанции и маркеры прочтения не шифруются по явному контракту пользователя; существующий markable hook сохраняется. Типы чатов и процесс обмена доверием не меняются.

**Компоненты:** `MessageManager+CommonSender.swift`, `OmemoManager+Encryption.swift`, `ChatMarkers.swift`, `TrustSharingManager.swift`.

- Формировать EME из QName фактического direct `encrypted`, независимо от исторического conversation kind. Для известных OMEMO URI optional `name` отсутствует.
- Нормализовать EME основного sender после delivery hooks перед отправкой; повторная отправка использует то же правило.
- Согласовать EME шифрованного непрозрачного TrustSharing payload и payloadless ratchet controls; не менять payload/доверие.
- Открытый displayed marker не заявляет шифрование через EME. Его существующие hints и conversation metadata сохраняются. Маркеры прочтения остаются открытыми по контракту проекта.

**Приёмка:**

- Все три encrypted conversation kinds отправляют EME с `urn:xmpp:omemo:2`, как текущий provider; plaintext сообщения без ciphertext не получают EME.
- Fallback body, hints, ID и ciphertext остаются неизменными при нормализации; повторная нормализация не дублирует EME.
- Реальный control остаётся bodyless/decryptable; prefixed QName работает, foreign/nested encrypted не помечает наружную stanza.

### OM2-03 — SCE для вспомогательных сообщений

**Уровень:** MUST при использовании расширений. **Владелец:** xmpp. **Зависимости:** OM2-01, OM2-02.

**Компоненты:** `MessageManager+CommonSender.swift`, `OMEMO senders correction/retraction/ephemeral/references`.

- Составить и реализовать таблицу OMEMO send paths: correction, retraction, ephemeral, references/mentions. Маркеры доставки, квитанции и маркеры прочтения остаются открытыми по контракту проекта (уточнение пользователя, 2026-10-02); не переносить chat-markers/receipts в SCE.
- Передавать sensitive client extensions через encrypted content общего builder и маршрутизировать только из проверенного результата.
- Сохранить открытый транспорт маркеров доставки, квитанций и маркеров прочтения, включая взаимодействие с XEP-SYNC. Для остальных расширений оставлять снаружи документированные server-processed элементы; custom retry разрешать по подтверждённой серверной спецификации. Не путать encrypted extension-only payload с payloadless ratchet ACK.

**Приёмка:**

- Проверка final wire и receiver effects для защищаемых расширений; plaintext injection в их внешние копии не вызывает действий. Маркеры доставки, квитанции и маркеры прочтения продолжают работать открыто через существующие обработчики.
- Encrypted extension-only сообщения работают без пустого пользовательского bubble; retry сохраняет ID и ciphertext.

### OM2-04 — SCE affixes: время и padding

**Статус:** выполнено 2026-10-02; [контракт времени и padding](omemo2-sce-affixes.md). Focused XCTest: 256/256, затем 83/83 на final source; приложение и dependency push extension собраны в cached Simulator test action.

**Уровень:** MUST / профиль реализации. **Владелец:** xmpp. **Зависимости:** OM2-01, OM2-02.

**Компоненты:** `Omemo2PayloadCodec.swift`, `OmemoManager.prepareStanzaContent`, `MAM/carbon/live receive context`.

- Ввести типизированный receive context: исходные from/to/type, provenance и original sending time с источником; проверить from/to/time до ratchet commit.
- Формировать outgoing encryption time при шифровании; не использовать возраст очереди. Для exact ciphertext retry сохранять исходный защищённый time.
- Выбрать и документировать minimum-size padding + random0..200; принимать длинный rpad. Сформулировать clock margin и поведение при отсутствии надёжного original time.

**Приёмка:**

- Historic MAM, carbon, live без delay, mismatch/skew boundary; оригинальное время не сравнивается с Date.now для истории.
- Границы minimum padding, Unicode/UTF8 и long incoming rpad; optional affixes и group to binding сохраняются.

### OM2-05 — Devices codec, membership и актуальность

**Уровень:** MUST + SHOULD refresh. **Владелец:** xmpp. **Зависимости:** OM2-01.

**Компоненты:** `новый OMEMO2DevicesCodec.swift`, `OmemoManager.swift`, `OmemoManager+Encryption.swift`, `SignalDeviceStorageItem или новая node-snapshot model`, `RealmMigrations.swift`, `OmemoSendAvailabilityPolicy`.

- Ввести строгий parser devices/item/id/namespace/cardinality; сохранить уже работающую labelsig validation и caps+notify.
- Хранить authoritative devices-node snapshot отдельно от identity/bundle/trust. Старым rows назначить membership unknown до успешного fetch, сохраняя trust и историю.
- Выбирать content recipients по membership + существующему trust/key predicate; unknown SID вызывает refresh. Предусмотреть freshness без mutual presence и защиту stale IQ после нового PEP event.

**Приёмка:**

- Unsolicited bundle или incoming unknown SID, затем existing/manual trust: до membership content не отправляется.
- Empty/retracted list, malformed/duplicate/foreign children, removed trusted device, same ID/different JID, no-presence refresh и stale-IQ/event race.

### OM2-06 — Собственная регистрация и PEP publication lifecycle

**Уровень:** MUST + SHOULD deactivate cleanup. **Владелец:** xmpp. **Зависимости:** OM2-05.

**Компоненты:** `OmemoManager+BundlePublication.swift`, `OmemoManager.configureLocal/updateMyDevice`, `AccountEncryptionInfoViewController.swift`.

- Fresh registration: загрузить own devices, выбрать свободный positive31bit ID, подтвердить отсутствие коллизии до первой публикации; existing/migrated ID сохранять.
- На own update без local ID merge/reannounce; не терять соседние devices/labels, обрабатывать concurrent publication, IQ failure, restart и reconnect.
- При deactivation убрать own ID и retract own bundle без перепубликации; сохранить локальные ключи/историю согласно политике восстановления. Проверить open/max/configure retry и current-hash publication acknowledgement.

**Приёмка:**

- Fresh collision и restart до publish, concurrent2 devices, own headline без local ID, empty own list, stale IQ, publication failure.
- Disable/re-enable не меняет identity/migrated ID и не оставляет объявленный выключенный device; bundle config не ограничивается одним item.

### OM2-07 — Replay, skipped keys и совместимые C snapshots

**Уровень:** MUST duplicate / SHOULD expiry. **Владелец:** xmpp. **Зависимости:** нет.

**Компоненты:** `SignalProtocolC/src/omemo_session.c`, `SignalProtocolC tests`, `SignalProtocolObjC/Classes/OMEMO/OMEMO2.m при изменении API`, `XabberOMEMO2Storage.swift`, `local dependency pins/patches`.

- Распознавать ранее аутентифицированный old-DH replay в сохраняемом bounded C fast-cache, дополняемом durable app receipt index/history; не подавлять неизвестные DH/MAC failures. Отпечаток связывать с authenticated packet/address, не с изменяемой внешней MAM wrapper.
- Сохранить genuine duplicate outcome при переборе EK candidates, если позднее не найдено успешного decrypt.
- Добавить deterministic skipped-key expiry и secure erasure; версионировать C snapshot, читать v1 без сброса EK/counters/skipped keys. Определить границы replay history и миграции старых metadata.

**Приёмка:**

- KEX→ACK→новый DH→old packet replay; несколько EK и повтор regular; restore/restart, corruption и state unchanged.
- v1 fixture migration с сохранёнными counters/keys; FIFO/MAX_SKIP, expiry по событиям, настоящий MAC failure остаётся ошибкой; replay вне C fast-cache сопоставляется с durable authenticated receipts/history без доверия к mutable server IDs.

### OM2-08 — Защищённый journal и сохраняемый входящий inbox

**Уровень:** надёжность интеграции. **Владелец:** business-logic. **Зависимости:** OM2-01, OM2-04, OM2-07.

**Компоненты:** `XabberOMEMO2Storage.swift`, `CredentialsManager.swift`, `OmemoManager.swift`, `MessageManager+CommonReceiver.swift`, `history persistence barrier`.

- Версионировать aggregate и мигрировать v1 с сохранением identity/device/ratchet/OPKs. Расширить существующий protected aggregate bounded inbox records.
- Одним save фиксировать advanced ratchet, consumption, authenticated packet receipt и проверенное содержимое/provenance; идемпотентно материализовать Realm history, после подтверждения убирать inbox запись.
- Публичную identity projection восстанавливать идемпотентно с прежней key-change/trust policy. Ввести backpressure при лимитах/save failure, не вытеснять неприменённый plaintext.

**Приёмка:**

- Crash до/после Keychain commit, до enqueue/history, Realm failure и restart: текст восстанавливается без потери и дублей.
- Повтор из live/MAM/carbon доставляет journal entry; lost/corrupt state не генерирует identity; failure публичной projection восстанавливается.

### OM2-09 — Атомарная отправка получателям и сохраняемый outbox

**Уровень:** надёжность интеграции + MUST/SHOULD peer controls. **Владелец:** business-logic. **Зависимости:** OM2-02, OM2-03, OM2-05, OM2-07, OM2-08.

Общий initial empty reply — SHOULD; heartbeat и empty reply при выбранной отсрочке OPK cleanup — MUST. XEP-0198 transport ACK не равен peer reply; outbox/atomic batch ниже — предлагаемые инженерные решения, не буквальные требования OMEMO.

**Компоненты:** `XabberOMEMO2Storage.swift`, `OmemoManager+Encryption.swift`, `MessageManager+CommonSender.swift`, `AccountStreamDelegate.swift:1127`, `ReliableMessageDelivery.swift`.

- Подготовить ciphertext для всех адресатов в candidate aggregate; одним save сохранить все counters и exact final stanza в outbox. Ошибка любого адресата отменяет batch.
- ACK/heartbeat переводить pending→prepared только вместе с outbox; допустимые retries отправляют прежний ciphertext/stanza ID. Перед content release учитывать текущие membership/trust/opt-out. При отзыве eligibility terminal cancel старого packet, без правки ciphertext/отката counters; новый batch получает новый packet ID и сохраняет logical message identity. Empty controls используют отдельную policy.
- Связать retirement с XEP0198 stanza ack либо подтверждённым существующим server-delivery contract; stream.send не completion. Для server без SM согласовать fallback/retry policy и recovery незавершённых records.

**Приёмка:**

- Первый recipient успешен, второй падает; ни один counter не меняется. Crash между save/send/ack и после restart не теряет packet.
- KEX ACK loss, archived KEX ACK, heartbeat first-observed53, no loop, reconnect/resume, server без SM, policy change перед retry, delayed retry/SCE time и новый packet после cancellation.

### OM2-10 — Обслуживание SPK/OPK и bundle

**Уровень:** MUST publication/min OPKs + SHOULD rotation. **Владелец:** xmpp. **Зависимости:** OM2-06, OM2-08, OM2-09.

**Компоненты:** `XabberOMEMO2Storage.swift`, `OmemoManager+BundlePublication.swift`, `account foreground/stream preparation`.

- Проверять rotation/replenishment при reconnect, foreground, отправке/приёме и due activity; не полагаться только на prepare или таймер suspended app.
- Сохранить weekly SPK interval и retired grace по одной rotation; поддерживать около100 published OPKs и никогда не публиковать собственный bundle с менее25.
- Сериализовать consume/replenish/publish/rotation, повторять failed публикации и учитывать актуальный bundle hash; consumed OPKs отдельно от available.

**Приёмка:**

- Непрерывное соединение дольше недели, foreground после suspension, clock rollback, delayed old-SPK KEX и grace boundary.
- Consume burst, concurrent operations, bundle write/publication failure: ключи не переиспользованы, минимум собственных published OPK соблюдён.

### OM2-11 — Catch-up proof и удаление consumed OPK

**Уровень:** MUST eventual deletion / SHOULD delayed cleanup. **Владелец:** xmpp. **Зависимости:** OM2-04, OM2-08, OM2-09, OM2-10.

**Компоненты:** `MessageArchiveManager.swift и Delegate`, `archive coordination/checkpoints`, `XabberOMEMO2Storage.finishCatchUp`, `OMEMO journal/materialization`.

- Определить охват catch-up для consumed OPK: источники/границы, поколения соединений, persisted pages/results и новые запросы. Сохранять checkpoint, не считать fin/page/Sync/pending-empty общим completion.
- Зафиксировать порядок first-seen historical EK и более новой live сессии; не объявлять каждый MAM KEX receive-only и не выдавать trust и сохранять прежнюю key-change policy.
- После принятия catch-up KEX сохранять обязательный initial ACK и немедленно предпринимать отправку; failure сохраняет outbox для retry. Prepared ciphertext не считается выполненной отправкой. Cleanup после доказанного catch-up учитывает transport dispatch/completion по OM2-09, не требует recipient decrypt ACK; сохраняет known EK history. Определить retirement policy для permanently abandoned history.

**Приёмка:**

- Pagination/concurrent conversations, controls-only page, history failure, interrupted/reconnected generation и stale proof: преждевременного deletion нет.
- First-seen old MAM KEX после нового live EK, OPK reuse, завершённый catch-up и повтор cleanup; успешная история переживает key deletion.

### OM2-12 — Ручной reset, opt-out и ошибки протокола

**Уровень:** MUST reset/opt-out + SHOULD errors/recovery. **Владелец:** ui. **Зависимости:** OM2-01, OM2-05, OM2-08, OM2-09, OM2-11.

**Компоненты:** `OMEMO manager/storage`, `conversation/contact encryption UI`, `central send policy/queue`, `localization`, `message decrypt metadata`.

- Добавить manual per-chat/device session replacement, сохраняя identity/device ID/trust/history; новый EK создаётся непосредственно перед следующим send.
- Authenticated opt-out сохраняет pending decision и блокирует весь user-content send для соответствующего peer conversation, включая retry/scheduled/attachments, до явного выбора; controls сохраняют protocol policy, ratchet не удалять.
- Manual reset отсоединяет broken current session с сохранением archived receive snapshots по retention policy. Разделить no session, broken/auth failure, duplicate и no recipient key. Реализовать no-session SHOULD empty recovery без auto-reset существующей broken session; отобразить ошибки и untrusted incoming metadata, только читая текущее trust state.

**Приёмка:**

- Reset→fresh bundle/new EK, поздние old packets, restart; ни MAC failure, ни malformed message не запускают автоматический reset.
- Encrypted vs plaintext opt-out, pending restart и все send paths; confirm/refuse/re-enable; controls не вызывают plaintext transition.
- Missing-session recovery, в том числе untrusted device: только eligible empty control, content остаётся запрещён; missing recipient warning, authentic duplicate silent, untrusted incoming indicator без новых решений о доверии.

### OM2-13 — Полная матрица и независимый обмен

**Уровень:** приёмка / static security quality. **Владелец:** tests. **Зависимости:** OM2-01, OM2-02, OM2-03, OM2-04, OM2-05, OM2-06, OM2-07, OM2-08, OM2-09, OM2-10, OM2-11, OM2-12.

**Компоненты:** `C tests/analyzer/sanitizers`, `focused OMEMO XCTest`, `actual server/new web/iOS flows`, `existing inherited curve UB task`.

- Сопоставить каждое применимое MUST/SHOULD с кодом и automated/live сценарием; уже выполненный crypto profile принимать через независимые vectors, не переписывать HKDF/MAC/protobuf.
- Проверить new web↔iOS и независимый conformant peer в обе стороны, Ed-internal/X-internal identity variants, long out-of-order/restart/archive/device races.
- Статически проверить новые C/ObjC/Swift paths, sanitizers и bounded parser fuzz/corpus. Закрыть или отдельно точно зафиксировать inherited Donna/Ed25519 UB; не утверждать whole-library UBSan success до его исправления.

**Приёмка:**

- Все применимые обязательные строки matrix закрыты доказательствами; 1:1 и own-device sync проходят независимый обмен без trust-handshake dependency.
- Focused Simulator tests строят app+push; fork pins/patches воспроизводимы; diagnostics не раскрывают secrets/plaintext; unresolved scope отражён явно.

### OM2-14 — Стандартный OMEMO MUC

**Уровень:** условно обязательно при поддержке MUC. **Владелец:** xmpp. **Зависимости:** OM2-05, OM2-09, OM2-11, OM2-12, OM2-13.

**Компоненты:** `standard MUC membership/affiliation`, `OMEMO multi-JID recipient batch`, `group receive context/UI`.

- Для стандартных non-anonymous rooms получать members/admins/owners, включая offline recipients; следить за affiliation changes.
- Получать devices/bundles всех real bare JID, отправлять общий payload через per-device ratchet batch; protected to=room, verified real sender, собственные другие devices.
- Применять существующие trust gates, не менять механизм доверия. Развести поддержку standard MUC и custom Xabber Groups.

**Приёмка:**

- Offline member, affiliation add/remove/ban, nickname/real-JID binding, devices change, room→private conversion и untrusted device policy.
- Если эта возможность не реализуется, declaration остаётся 1:1+own-device sync; MUC не обозначается supported.

## Решения, которые фиксируются внутри соответствующих задач

1. **Padding/time (OM2-04):** выбраны 512 serialized UTF-8 bytes + random0…200 ASCII и ±300 секунд включительно; это параметры клиента. Original sending time извлекается из оригинальной stanza/forwarded delay; отсутствие отмечается typed unavailable, установленный mismatch отклоняется до OM2 ratchet commit. Удаление time для обхода проверки не считается исправлением. [Реализованный контракт](omemo2-sce-affixes.md).
2. **Replay/expiry (OM2-07):** event/window bounds и чтение old snapshots. C cache не должен быть единственным основанием replay guarantee: durable inbox/history receipts дополняют его после eviction. Старый v1 не содержит полной истории authenticated packets; доступные history receipts можно backfill, неизвестный MAC failure нельзя объявлять duplicate. Уточнить receipt retention/tombstones и доказать обязательное duplicate поведение до final gate.
3. **Journal (OM2-08/09):** рекомендуемый первый вариант — bounded inbox/outbox в существующем protected aggregate, чтобы state+record сохранялись одним replacement. Задать лимит bytes/records, backpressure и recovery; не удалять незавершённый plaintext/ciphertext ради места. Проверить размер и latency. Если aggregate не выдерживает ожидаемую нагрузку, отдельным решением перейти к единой encrypted transaction store с key в Keychain и полной миграцией, без split-write псевдоатомарности.
4. **Delivery (OM2-09):** использовать существующий XEP0198 ack hook; для no-SM server определить проверяемый fallback completion/retry. Server acceptance отличается от recipient decrypt ACK; оба состояния различаются. Для длительно отложенного prepared packet определить policy совместно с OM2-04: не обновлять защищённый time в старом ciphertext. При необходимости cancel/reprepare создаёт новый packet с новым encryption time и тем же logical message key, сохраняет исходный content и не откатывает использованные counters.
5. **Catch-up (OM2-11):** proof относится к конкретным источникам/границам/consumed OPK и подтверждённому сохранению результатов. Восстановление неизвестного исторического EK не может механически переопределять current; правила new-session replacement/receive-only сохраняются.
6. **Heartbeat/control policy (OM2-09/13):** first-observed DH counter≥53 остаётся текущей буквальной трактовкой до независимого теста; не менять её как «доказанный bug». EME для control без SCE envelope фиксируется отдельно от обычного user stanza.

## Правила реализации и проверки

Каждый task: focused test сначала → воспроизводимое падение текущего поведения при возможности → минимальная реализация → affected tests/build → документация и focused commit. Для C/ObjC API изменения отдельные commits в локальных forks, затем обновление app pins/patches. Не подключать новые сторонние библиотеки.

- C: narrow CTest suites и новый regression первым; relevant clang analyzer/ASan/UBSan для C tasks, сохранять точные boundaries inherited arithmetic failure.
- iOS: `tools/xcodebuild_cached.sh test`, concrete Simulator, `Debug`, isolated account/storage flags. Successful test action с app/push build выполняет build gate; separate clean/build после него не нужен.
- Для OM2-01/02/03 тест захватывает окончательный XML и настоящий route, а не только результат codec.
- Для OM2-08/09/11 нужны fault injection, restart и подтверждённые persistence/transport barriers.
- Финальная acceptance matrix: requirement → production path → test/vector → peer/server evidence. Все применимые MUST закрыты; SHOULD реализованы либо имеют обоснованное и проверенное ограничение. Unsupported optional scope явно отмечен.
- Сохранить прежние124 regression scenarios; их число не использовать как coverage percentage. Live exchange не заменять тестами двух экземпляров той же библиотеки.
- Приёмка OMEMO использует уже заданное/manual test trust состояние; AKE handshake не является зависимостью данного плана.

## Definition of done

1. Core13 tasks выполнены; применимые обязательные строки matrix не имеют неизвестного статуса.
2. Новые сообщения и поддерживаемые расширения имеют правильный OMEMO2/SCE final wire во всех фактически используемых routes.
3. Ratchet, identity, membership, OPK/SPK lifecycle и crash recovery соответствуют принятому контракту; migration/restart не теряют сообщения и ключи.
4. New web↔iOS и независимый peer проходят в обе стороны; ошибки и ограничения фиксируются, а не маскируются fallback.
5. Target builds, pins и code/static/regression gates воспроизводимы. Trust-exchange protocol остаётся самостоятельной отложенной областью.
6. Если OM2-14 не выполнена, MUC support не заявляется. Базовое 1:1/own-device соответствие описывается с явными согласованными исключениями Xabber (fallback/hints/markers), без заявления полного буквального SCE sending conformance.

## Статус этого документа

Сверено 2026-10-05 на `f9bbfe47`: OM2-01, OM2-02 в согласованном EME-only объёме и OM2-04 выполнены. Crypto profile и application migration выполнены до этого плана. [Актуальные остатки с production evidence](omemo2-remaining-work-2026-10-05.md): 10 задач плана OM2-03/05–13 (нормы + инженерная надёжность + приёмка), условный standard MUC OM2-14. Следующая задача — OM2-03; параллельно допустим OM2-07 в C. Сохраняются явные правила пользователя: маркеры/квитанции открыты, fallback body остаётся, новых store hints нет, trust exchange отложен.

Пересмотр изменяет только документы. Последние XCTest gates принадлежат OM2-04 (256/256 + final83/83); новый build/test/live gate 2026-10-05 не запускался. Прежние124/124 и C replay repro относятся к исходному аудиту, а не к текущему подтверждению всех открытых задач.
