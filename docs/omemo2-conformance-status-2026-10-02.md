# OMEMO2: выполненные изменения и оставшиеся работы

Исторический аудит baseline `524f46ba`. После него выполнены OM2-01/02 в согласованном объёме/04; актуальный остаток на `f9bbfe47` — [сверка 2026-10-05](omemo2-remaining-work-2026-10-05.md).

Дата проверки: 2026-10-02. Область: локальные SignalProtocolC/ObjC и Xabber iOS на коммите `524f46ba`. Аудит исходников, требований и тестовых сценариев; production/test код в этой задаче не менялся.

## Вывод

Криптографический профиль OMEMO2 и его подключение к приложению реализованы. Полного соответствия клиента заявлять пока нельзя: остаются обязательные требования к SCE/XML, списку устройств, обработке повторов, очистке ключей и восстановлению сессий. Дополнительно сохраняются критические проблемы собственного механизма установления доверия Xabber и окна потери данных при сбоях.

Две завершённые стадии существенно изменили исходное положение: новые сообщения уже не используют обычный Signal wire/MAC8 под namespace OMEMO2. Следующая работа преимущественно находится в приложении; C потребуется для replay и срока хранения skipped keys. Оснований заново переписывать HKDF/MAC/protobuf нет.

## Нормативная база и расхождение с KB

- Актуальный [XEP-0384](https://xmpp.org/extensions/xep-0384.html): **0.9.1, 2026-04-06**, Experimental. Локальный KB snapshot соответствует этой версии.
- Актуальный [XEP-0420](https://xmpp.org/extensions/xep-0420.html): **0.5.0, 2026-06-23**, Experimental. KB содержит **0.4.1**, сохранённую 2026-04-11.
- Текущий SCE уточняет минимальную цель padding, допустимость длинного rpad, DateTime, проверку time, размещение EME и запрет fallback body. Старого KB snapshot недостаточно для актуальной оценки; канонический snapshot не редактировался, предложение направлено в KB inbox.
- Xabber AKE/TrustSharing — отдельные протоколы. OMEMO не предписывает их формат. Их уязвимости всё равно блокируют безопасное применение OMEMO, поскольку они меняют флаг доверия, который разрешает отправку.

Подробные требования OMEMO сверены с локальным `xabber-knowledge/protocols/standard/xep-0384-omemo-encryption.md`; новые требования SCE — с текущим первичным источником. MUST ниже обозначает обязательную норму; SHOULD — рекомендацию; надёжность/валидация — самостоятельные критерии качества реализации.

## Что уже сделано

| Слой | Реализовано | Подтверждение |
| --- | --- | --- |
| Зависимости | Локально изменены только SignalProtocolC и SignalProtocolObjC, отдельные ветки `codex/ios-local-dependencies`, воспроизводимые pins/patches. Другие Pods/SPM не переводились на локальные форки. | C `7552b1be`, ObjC `d142b4db`, app `3c4bfdf5`; `tools/local_dependencies.py check` |
| Ключи и X3DH | Raw Ed25519 identity32, raw X25519 остальные ключи32, EdDSA-compatible XEdDSA, проверка SPK, обязательный OPK, четыре DH, RFC7748 clamping, отказ от all-zero DH. | `SignalProtocolC/src/omemo_keys.c:53–221`, `omemo_session.c:175–266`; CryptoKit interoperability tests |
| Ratchet и wire | OMEMO-specific HKDF labels, CBC/PKCS7, MAC16, исходные байты protobuf и правильный AD; отдельный versioned snapshot. | `omemo_session.c:146–172,274–465,532–657`, `omemo_wire.c:151–383` |
| Продолжение сессии | Повторный KEX сохраняет EK и двигает counter; authenticated ответ прекращает KEX. `kex=true` сам по себе не означает новую сессию. | State/AppIntegration tests; `omemo_session.c:296–328,428–465` |
| Подключение приложения | Новый provider применяется в user send, receive, bundle и control paths; plaintext payload: key32+MAC16, control: zero32 без payload. | App `524f46ba`, `OmemoManager+Encryption.swift:211–328`, `OmemoManager.swift:1188–1249` |
| Миграция | Сохраняются проверенный private identity scalar, device ID, история и manual trust при совпадении canonical X25519 fingerprint. Legacy Signal snapshots отделены и не импортируются в новый ratchet. Realm schema22. | `XabberOMEMO2Storage.swift:143–186`; migration/identity tests |
| Секретное состояние | Один binary PropertyList aggregate в защищённом Keychain item на account; строгие ошибки чтения/записи; corrupt/lost migrated state не заменяется новым. Lock между экземплярами в одном процессе. | `CredentialsManager.swift`, `XabberOMEMO2Storage.swift:456–517`; реальные Keychain tests |
| Транзакция расшифрования | Inner MAC, payload MAC и SCE affixes проверяются до secret commit/OPK consumption; failure сохраняет предыдущий snapshot. | `XabberOMEMO2Storage.swift:251–333`, `Omemo2PayloadCodec.swift:32–80` |
| Сессии и controls | Известный старый EK остаётся доступен; новый EK с consumed OPK становится receive-only. ACK адресует только sender device, не вызывает ACK-loop, control не создаёт текст сообщения. | Storage/AppIntegration tests |
| Bundle/trust | Strict raw-key XML/Base64/IDs/signature, публикация100 OPKs, open/max options, IQ-result/hash подтверждение. Изменение ключа отзывает trust; timestamp-only certificate больше не даёт auto-trust. | BundleCodec/BundleCacheIntegration tests; `OmemoManager.swift:795–885` |
| SCE | Payload CBC/MAC16, structural XML validation, from/to binding, optional affixes, синтаксис time, фильтрация трёх server namespaces. | 12 PayloadCodec tests; полнота SCE ещё не достигнута |

Подробности стадий: [dependency profile](omemo2-dependency-profile.md), [application migration](omemo2-application-migration.md). Формулировка «archived KEX не меняет identity» доказана для **уже известного archived EK или consumed OPK**, а не для любого впервые встретившегося исторического KEX.

## Подтверждённые обязательные пробелы

### 1. Целостность SCE и конечный XML — срочно, приложение

**Приём.** После decrypt к исходному stanza добавляются decrypted extensions, но чувствительные незашифрованные siblings не удаляются. Внешние `reference`, `ephemeral` и другие поля могут влиять на вложения/forward/autodelete. Локальный `omemo-result__system` также нельзя принимать с wire как доказательство decrypt. Нужна единая реконструкция stanza с доверенной provenance для live/carbon/MAM/push, до всех sensitive routers.

- Reinjection: `OmemoManager.swift:982–998,1060–1179`.
- Потребители: `MessageManager+CommonReceiver.swift:1669–1677`, `MessageReferenceParser.swift:376,445`.
- Проверять все content elements по local name **и** URI; запрещённые server elements отбрасывать внутри, sensitive elements игнорировать снаружи. Текущая внутренняя фильтрация `Omemo2PayloadCodec.swift:77` не включает EME.

**Отправка.** Реальный CommonSender добавляет fallback body и не добавляет store hint; TrustSharing повторяет fallback. Это generic уведомление об encryption, а не утечка настоящего message body, но конечный XML не соответствует SCE. EME имеется в обычной отправке, однако его namespace берётся из conversation kind: `.omemo1/.axolotl` могут объявлять legacy scheme для нового OMEMO2 ciphertext. ACK содержит store и не содержит body; EME у него отсутствует, применимость правила к control path следует закрепить тестом/profile policy.

- `MessageManager+CommonSender.swift:330,367–373,504–519`.
- `TrustSharingManager.swift:530–539`; `OmemoManager+Encryption.swift:302–310`.
- Изменять нужно final sender, а не только `encryptMessage()`: нынешние manager tests не проверяют окончательно отправленный user stanza.

**Namespace consistency.** Codec проверяет content по localName+URI, но последующие consumers повторно выбирают `element(forName:"content")`, а sync-preview берёт body без URI (`OmemoManager.swift:945–946`). Foreign-namespace content перед правильным SCE content может перекрыть валидированный контейнер. Передавать проверенный content напрямую; добавить prefixed/foreign-sibling cases. Devices intake тоже требует строгого отдельного codec: namespace/cardinality/items/duplicateIDs (`OmemoManager.swift:436,465,546`); не переносить строгость bundle parser на devices как уже доказанную.

### 2. PEP device lifecycle и выбор получателей — приложение

- Нет проверки **fresh device ID collision** по актуальному own devices node перед первой публикацией (`Encryption.swift:129–147`, `OmemoManager.swift:131–138`, `BundlePublication.swift:217–234`). Мигрированный ID сохранять; этот repair относится к fresh registration.
- Own PEP update без local ID не вызывает **reannounce**: headline идёт с `fromMessage:true`, а публикация условна на `!fromMessage` (`OmemoManager.swift:491,558,633`). Нужен merge без перезаписи соседних устройств.
- Отправка выбирает все trusted Realm device rows без отдельного доказательства актуального **devices-node membership** (`Encryption.swift:265–284`). Unsolicited bundle/unknown incoming SID могут создать row без membership (`OmemoManager.swift:845–852,1255–1267`); затем AKE/manual trust разрешает send. Trust и membership нужно хранить раздельно.
- Labels уже проверяются по labelsig, unsigned/invalid labels игнорируются (`OmemoManager.swift:582–592`). PEP subscription через advertised devices+notify/caps присутствует: полного отсутствия subscriptions нет. Эти требования не включаем в список незавершённых исправлений.

### 3. Повторные пакеты — SignalProtocolC и приложение

Два самостоятельных дефекта:

1. Replay уже принятого пакета **старой DH-chain** возвращает INVALID_MAC вместо DUPLICATE_MESSAGE (`omemo_session.c:409–427`). Узкий C repro: KEX → ACK → новый DH → replay первого KEX. Сегодня получено `-1004`, ожидаемый duplicate `-1001`; snapshot не изменился. Rollback работает, silent replay classification — нет.
2. При нескольких retained EK snapshots Duplicate от правильного кандидата может быть перезаписан InvalidMAC от следующего (`XabberOMEMO2Storage.swift:319–333`). Manager игнорирует только итоговый duplicate (`OmemoManager.swift:1235`).

Нужно сохраняемое ограниченное распознавание **ранее аутентифицированных** пакетов и агрегирование ошибок кандидатов. Нельзя объявлять любой неизвестный DH или любой MAC failure повтором: это скроет повреждение. Требуются replay tests после DH/EK changes, restart и реального MAM wrapper.

### 4. OPK cleanup после доказанного catch-up — приложение и archive coordinator

`finishCatchUp()` существует и тестируется, но production caller отсутствует (`XabberOMEMO2Storage.swift:385`, единственный вызов — тест). Consumed private OPK остаются навсегда; eventual deletion пока не обеспечена.

Нужен account-wide catch-up barrier с подтверждённым сохранением archive pages и всех охваченных потоков, затем cleanup. Raw MAM fin, одна страница или XEP-SYNC completion такого доказательства не дают. До его появления текущая задержка удаления сохраняет decryptability истории; механически подключать cleanup к fin нельзя.

### 5. Проверка времени — приложение, SCE и archive/carbon context

`Omemo2PayloadCodec.swift:71–76` проверяет только синтаксис. `time`, если присутствует, должен проверяться относительно original sending time stanza с согласованным margin. Нужно передать проверенный original-time context через live/MAM/carbon, alert/reject при mismatch. Сравнение старого MAM timestamp с `Date.now` неверно. Отправка берёт переданный `date` (`OmemoManager.swift:204–226`); при queue/retry отдельно проверить, соответствует ли он времени encryption.

### 6. Ручное восстановление и opt-out — приложение/UI/send policy

Storage API удаления сессий есть, пользовательского OMEMO2 reset нет: вызовы только key-change paths (`OmemoManager.swift:809`, `Encryption.swift:223`). Нужен доступный reset broken session без удаления identity, trust и истории; следующий send создаёт новый EK.

Обработка encrypted opt-out отсутствует: поиск по приложению не обнаружил реализации; decrypted элемент остаётся неизвестным extension. Нужны явный persisted pending decision и блокировка всех outgoing messages до подтверждения перехода на plaintext. Нельзя считать внешний plaintext opt-out доверенным; текущие ratchet sessions сохранять.

## Доверие: отдельный незавершённый слой

Миграция исправила Ed/X representation, подписи нового identity и certificate-only auto-trust. Это **не исправило** ранее обнаруженные AKE/TrustSharing defects:

- `AuthenticatedKeyExchangeManager.processSuccess:969–986` принимает любой nonterminal responder session. `receivedRequest` проходит: `request → success` может установить trusted без acceptance/code/verify и без полного peer binding.
- Шестизначный code exchange содержит offline verifier: key = SHA256(DH || code || SID), challenge32 зашифрован CBC/PKCS7. Знающий собственный private identity инициатор может проверять кандидаты code по полному padding block; обычный rate limit это не устраняет.
- TrustSharing: signer не обязан быть trusted; owner не входит в signed canonical input; target fingerprint не применяется при изменении trust; replay watermark пишется до signature success (`TrustSharingManager.swift:28–64,319–345,372–386,411–431`).

Это source-level findings; live exploitation и скорость code recovery не измерялись. AKE/TrustSharing — custom protocols, но автоматическое повышение trust в этих ветвях делает OMEMO trust gate недостаточным. Нужна самостоятельная стадия hardening с state/peer/fingerprint/expiry tests и решением о безопасном совместимом code protocol.

## Надёжность, которой сейчас не хватает

| Риск | Текущая граница | Следующее изменение |
| --- | --- | --- |
| Потеря принятого plaintext при crash/Realm failure | Keychain ratchet commit происходит до постановки текста в очередь и async message persistence: Storage308/330 → Manager1094/1179 → CommonReceiver1437/1522,1083–1124. Replay затем подавляется. | Durable decrypted inbox/journal в согласованной ratchet transaction; удалять запись только после history commit. Restart/failure regression. |
| Потеря pending ACK/heartbeat | `controlsNeeded` удаляется при encrypt/save, до `stream.send`: Storage239–244 → Encryption328. Тест с названием SuccessfulSendCommit проверяет Keychain write, не delivery. | Durable prepared ciphertext outbox и определённый enqueue/delivery completion; retry после crash/disconnect. Archive ACK при отложенном OPK deletion — обязательная часть policy; обычный auto-ACK — SHOULD. |
| Частичное продвижение outbound counters | Каждый recipient сохраняется отдельно; поздняя ошибка другого recipient отменяет stanza, но сохраняет первые counters (`Encryption.swift:275,284`). | Preflight/batch commit либо durable prepared stanza/outbox; failure второго recipient после успеха первого. |
| Неизвестный старый KEX из MAM становится current | При unconsumed OPK неизвестный EK обновляет identity/current; archive context отсутствует (Storage298–305). | Определить порядок восстановления/identity projection и тест first-seen historical EK после trusted live replacement. Не менять MUST replacement механически. |
| Realm/Keychain не одна транзакция | Realm identity callback проходит до Keychain secret save; поздний save failure не откатывает публичную projection. | Явный cross-store recovery contract и failure второго store. Не заявлять общую атомарность обоих stores. |

Эти пункты не все являются отдельными MUST нарушениями XEP, но обязательны для надёжного восстановления, заявленного приложением.

## SHOULD, scope и дополнительные проверки

- SPK rotation реализована только при `prepare()`: соединение без reconnect больше месяца не обеспечивает периодическую rotation. Проверять по расписанию/активности, публиковать новый bundle, сохранять старый на выбранный grace period.
- Skipped message keys в C удаляются при use/FIFO1000; отдельного срока по deterministic events нет (`omemo_session.c:331–357,409–414`). Добавить поколение/возраст, snapshot compatibility и тесты.
- Unknown SID требует актуализации devices node; не путать такую загрузку с доверением устройству.
- SCE padding пока random0..199 без fixed minimum target (`OmemoManager.swift:227–229`). Выбрать/document minimum, затем дополнительную random length; длинный rpad при приёме не запрещать. Стандарт не задаёт конкретное числовое значение minimum, его нельзя выдумывать как нормативное.
- При отключении encryption local ID исключается из devices list, но bundle сначала перепубликуется и не retracts (`AccountEncryptionInfoViewController.swift:223–237`, `BundlePublication.swift:182–185,233–234`). Добавить SHOULD cleanup bundle, сохраняя требуемую историю локально.
- Индикация incoming untrusted/fingerprintChanged identity не подтверждена: receiver не переносит trust sender device в message metadata. Проверить SHOULD warning в UI отдельно; outgoing warnings этого не доказывают.
- Heartbeat реализован по буквальной трактовке **first observed packet for DH has counter>=53**. Сценарий первого packet53 покрыт; обычная0→53 последовательность и внешний peer — нет. Не отмечаем трактовку как доказанный defect без согласования.
- MUC/group fanout не реализован: `.groupchat: break` в `AccountStreamDelegate.swift:862`, encryption принимает один JID. Это отдельная неподдержанная возможность; не blocker ограниченного1:1 scope, но заявлять OMEMO MUC support нельзя. Xabber custom groups не равны стандартному MUC.
- Унаследованный signed-shift UB в Donna/Ed25519 остаётся отдельной задачей. Не утверждаем, что вся C библиотека прошла UBSan. Fuzzing protobuf/snapshot parser и независимые peers нужны как security/interop verification, не как найденная ошибка MAC.

## Покрытие тестами и пределы доказательства

Предыдущая реализация на том же baseline прошла **124/124** выбранных XCTest и построила app + push extension на signed Simulator. Сегодня этот gate не запускался повторно. Сегодня отдельно выполнен read-only C replay repro и dependency pin check2/2.

| Область | Имеющееся доказательство | Не хватает |
| --- | --- | --- |
| Crypto | 3 C suites; независимые Python/OpenSSL first-message/payload vectors; 5 CryptoKit cases; wrapper/session tests предыдущей стадии | Full-session exchange с независимым Ed25519-internal peer в обе стороны, successive DH, long out-of-order, fuzzing |
| State | 29 StateStorage tests | Production catch-up, crash between stores/history, live continuous rotation, durable control delivery, multi-recipient failure |
| Identity | 23 IdentityBinding tests | Fresh own/local ID collision, own-list overwrite/reannounce, authoritative membership |
| Bundle | 10 codec + 10 cache tests | Hostile devices XML, actual PEP/caps/server events and races |
| Payload/SCE | 12 codec tests | Final wire body/store/EME for all chat kinds, outer injection/provenance, EME filtering, minimum padding, original-time mismatch |
| Manager | 18 AppIntegration tests | Old-DH replay, regular replay with2 snapshots, actual MAM historical unknown EK, real final sender, opt-out/manual reset |
| Compatibility/history | 5 legacy lifecycle, 8 Realm migration, 4 affected sync-preview cases | Real mixed peers/server, migration with offline delivery/restart, lost/out-of-order controls |
| Trust/code | Identity/signature adaptation tests; older format/localization tests | Forged early success, full handshake transitions, signer authorization, signed owner/target, replay watermark, manual distrust precedence |

124 — количество выполненных сценариев, **не процент code/branch/protocol coverage**. Coverage instrumentation отчёта нет; полный suite проекта и live new-web↔iOS обмен не выполнялись. Успешные codec/storage tests не подтверждают final outgoing XML, account-wide archive lifecycle или network delivery.

## План следующих стадий

1. **Доверие и SCE integrity — блокируют безопасный ввод профиля.** Hardening AKE/TrustSharing; единый authenticated stanza reconstruction/provenance; final bodyless user send + store + correct EME. App/XMPP, UI и tests.
2. **PEP/device conformance.** Fresh collision, reannounce, authoritative membership, signed labels и encrypted opt-out/manual session recovery. App/XMPP + UI/send policy.
3. **Replay и recovery transaction.** C authenticated replay bookkeeping + app candidate handling; durable inbox/outbox и batch send policy. C + app/business/persistence/tests.
4. **Archive/time/key lifecycle.** Account-wide persisted catch-up proof, delayed private OPK deletion, original-time comparison, scheduled SPK rotation, deterministic skipped-key expiry. App/archive + C.
5. **Независимая interoperability gate.** iOS→new web и new web→iOS, third-party conformant peer, Ed/X identity variants, same numericID/differentJID, OPK collisions/reuse, ACK loss, heartbeat, restart, MAM/carbon, device-list race. Group support отдельно при необходимости.

**Пакеты:** SignalProtocolC нужен для replay/expiry и отдельного UB hardening. SignalProtocolObjC сейчас не требует новой замены crypto profile; менять wrapper/API только если это потребуется C changes. Основной остаток находится в `xabber/xmpp/omemo`, messages sender/receiver, AKE/TrustSharing, archive coordination и UI recovery/send policy. Новые сторонние библиотеки для перечисленных исправлений не требуются.

## Проверки этой задачи

- Параллельный read-only source review: C/ObjC crypto, lifecycle, XML/PEP/SCE; дополнительно повторно проверены прежние trust findings.
- Primary spec versions проверены на xmpp.org 2026-10-02.
- `python3 tools/local_dependencies.py check`: SignalProtocolC/ObjC2/2.
- Узкий временный Release C repro: old-DH replay = INVALID_MAC вместо DUPLICATE_MESSAGE, secret snapshot unchanged. Это новая проверка, не новое полное C/XCTest выполнение.
- Code не менялся, поэтому новая simulator сборка не запускалась; прежняя успешная124-test сборка относится к неизменённому production baseline.
