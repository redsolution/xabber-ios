# OMEMO2 — оставшиеся работы после OM2-04

Статическая сверка 2026-10-05: app `f9bbfe47`, Signal C `7552b1b`, ObjC `d142b4d`; все три checkout чистые до обновления этих документов. Основание — [план](omemo2-implementation-plan.md), текущие production paths, база знаний, опубликованные [XEP-0384 0.9.1](https://xmpp.org/extensions/xep-0384.html) и [XEP-0420 0.5.0](https://xmpp.org/extensions/xep-0420.html). Версии XSF проверены сегодня. KB snapshot XEP-0420 остаётся 0.4.1; его обновление принадлежит curator.

## Выполненные стадии

Готовы [crypto profile в Signal C/ObjC](omemo2-dependency-profile.md), [подключение и миграция protected state](omemo2-application-migration.md), **OM2-01** (общий проверенный SCE receive/provenance), **OM2-02 в согласованном EME объёме**, **OM2-04** (original from/to/time и UTF-8 minimum padding). Отсутствующий original time остаётся typed unavailable; legacy Signal transactional rollback не добавлен.

Сохраняются правила Xabber: delivery/read markers и receipts открытые, fallback body остаётся, новых store hints нет; trust exchange отложен. Полное буквальное соответствие отправке XEP-0420 с этими исключениями отдельно не заявляется. Исключения не являются новыми задачами без изменения согласованного scope.

## Остаток — 10 основных задач + условный standard MUC

| ID | Что завершить | Подтверждение / существующие части |
| --- | --- | --- |
| **OM2-03** | Шифрование изменённого текста/mentions/references при edit; TTL внутри SCE; проверка вспомогательных sender paths и серверного rewrite transport. | `MessageManager+CommonSender.swift:733–772` строит открытое edit body; `MessageDeleteManager.swift:541–552` отправляет embedded message в replace IQ. TTL добавлен снаружи после encrypt (`CommonSender:410–415`) и удаляется новым receive. Обычные references/mentions/forwarded уже защищены. Серверный retract IQ не объявлять автоматически клиентским encrypted payload. |
| **OM2-05** | Strict devices codec, authoritative membership отдельно от trust, freshness/unknown SID refresh, stale-IQ защита. | `OmemoManager.swift:551` children по имени; `Encryption.swift:281–301` trusted recipients без membership. Rows создаются также из bundle/receive; cache fetch без TTL (`OmemoManager:323–339`). ID bounds/duplicates и signed labels уже проверяются. |
| **OM2-06** | Fresh own-ID collision check, own-list merge/reannounce, publication races/retry/restart; disable/retract без повторной bundle publication. | `Encryption:145–165` ID до own-list; `OmemoManager:638` нет reannounce на own headline; `BundlePublication:177–193,233–234` cached list/disable flow. Config max/open, bundle-hash ACK и precondition retry уже есть. |
| **OM2-07** | Old-DH/EK replay как duplicate, устойчивый receipt index, сохранение duplicate при переборе candidates, skipped-key expiry и совместимые snapshots. | `SignalProtocolC/src/omemo_session.c:409–424` смена ratchet при старом DH; `Storage:319–333` следующий error перекрывает duplicate. Snapshot v1 без возраста skipped keys. Single-session rollback, FIFO/MAX_SKIP и current-chain replay уже есть. Настоящий MAC failure не объявлять duplicate. |
| **OM2-08** | Crash-safe inbox: ratchet + verified content/receipt в одном commit; восстановимая идемпотентная запись истории. | `Storage:101,327` protected state без inbox, save до возврата plaintext; `CommonReceiver:1544` → memory queue `MessageManager:412`. Atomic single-ratchet save/SCE validation уже есть. Crash до history может потерять принятый текст. |
| **OM2-09** | Atomic recipients batch + final stanza, durable encrypted outbox, exact retries; controls до transport completion/ACK; eligibility и delayed-time policy. | `Encryption:292` sequential recipients, `Storage:237` save каждого; failure второго не откатывает первый. `Storage:241` снимает control-needed до send (`Encryption:332`). `CommonSender:397,519` OMEMO вне durable regular queue. Initial ACK/heartbeat и pending control addresses уже есть; encrypt/save не равен send/ACK. |
| **OM2-10** | Due SPK rotation при долгом соединении/foreground/send/receive, replenish/publication retry и min25 available published OPK под сбоями. | Rotation/grace есть (`Storage:394–410`), due check только prepare (`:150`). Replenish100 перед publish/после KEX уже есть. В текущем соединении нет гарантированного due/retry lifecycle. |
| **OM2-11** | Persisted account-wide archive catch-up proof, затем consumed-private-OPK cleanup с учётом history/outbox. | `Storage:383` finishCatchUp реализован и unit-tested, production callers нет. Raw MAM fin/page/sync не доказывают catch-up. Consumed OPK не публикуются, private часть остаётся. |
| **OM2-12** | Manual session reset с сохранением delayed receives/history/identity/trust; verified opt-out + persisted send block; eligible no-session empty recovery; различимые ошибки/UI. | `Storage:354` удаляет все snapshots только при key change; manual reset нет. Gate `Encryption:101–120` trust-only; opt-out state/handler нет. Control `Encryption:316` требует session; sender error `CommonSender:282–286` объединяет причины. |
| **OM2-13** | Applicable MUST/SHOULD matrix; реальный new web↔iOS + независимый peer; restart/archive/out-of-order/device races; final static/sanitizer/fuzz gates. | Independent vectors/CryptoKit уже есть, external interop не выполнен. Inherited Donna/Ed25519 signed-shift UB не закрыт; whole-library UBSan-clean не подтверждён. Это пробел проверки и hardening, не причина переписывать готовый crypto profile. |
| **OM2-14, условно** | Standard non-anonymous MUC: offline members/admins/owners, affiliations, все real-JID devices, multi-JID batch и verified sender/room bindings. | `Encryption:281–302` один peer + own devices; receive использует from.bare, не room/nick→real JID. Custom Xabber Groups не эквивалентны standard MUC. При scope 1:1 + own-device sync это отдельная возможность. |

Имена файлов таблицы относятся к `xabber/xmpp/omemo/OmemoManager.swift`, `OmemoManager+Encryption.swift`, `OmemoManager+BundlePublication.swift`, `storage/XabberOMEMO2Storage.swift`, `xabber/xmpp/messages/messages_manager/MessageManager+CommonSender.swift`, `MessageManager+CommonReceiver.swift`, `MessageManager.swift`, `xabber/xmpp/XEP-0RRR/MessageDeleteManager.swift`; C — `/Users/igor.boldin/projects/xabber/deps/SignalProtocolC/src/omemo_session.c`. Line references проверены на указанном baseline.

## Порядок / пакеты

Следующая компактная задача — **OM2-03**, особенно edit и TTL. Параллельно возможен **OM2-07** в C. Далее **OM2-05 → OM2-06 → OM2-08 → OM2-09 → OM2-10 → OM2-11 → OM2-12**, затем **OM2-13**. Сохраняются зависимости исходного плана; OM2-14 — при включении standard MUC.

Основной остаток — приложение: omemo/storage/sender/rewrite/archive/policy/UI. **SignalProtocolC** нужен для replay/expiry и inherited UB; **SignalProtocolObjC** — только если понадобится изменение C API/snapshot interface. Новых зависимостей не требуется.

## Verification scope

Сверка исходников выполнена тремя независимыми read-only обзорами и root review. Production/dependency/test код не менялся, новые test/build/live gates не запускались. Последние OM2-04 результаты от 2026-10-02: 256/256 + final83/83, app/push dependency build. Числа тестов не являются процентом code/branch/protocol coverage. Исторический [аудит 2026-10-02](omemo2-conformance-status-2026-10-02.md) описывает прежний baseline, не текущий остаток.
