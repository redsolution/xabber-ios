# OMEMO2 N04 — подтверждённые повторы и срок skipped keys

Завершено 2026-10-06. Сервер, trust exchange, plaintext markers/receipts, fallback body и hints не изменены.

## Норма и реализация

[XEP-0384 §4.3/6](https://xmpp.org/extensions/xep-0384.html#protocol-double_ratchet): известный повтор поглощается без bubble, но старый счётчик сам по себе не подтверждает подлинность. [Skipped-key policy](https://xmpp.org/extensions/xep-0384.html#protocol-double_ratchet) рекомендует конечное хранение на основе событий. Конкретные границы ниже — политика клиента.

- SHA-256 с framing связывает owner, bare sender/SID, actual local recipient ID, ожидаемый to/groupchat, режим KEX, точные decoded key и payload; отсутствие payload отличается от наличия. Transport IDs/dates/XML success markers доказательством не являются.
- До crypto допускается только exact match с одним из последних4096 подтверждений в protected state. Новое подтверждение сохраняется в одной транзакции с ratchet только после crypto/SCE/bindings/identity validation. Failed payload/save не создаёт proof.
- Verified history имеет отдельное optional Data поле, Realm schema24. Старые строки получают nil; сырой XML, plaintext, failed/legacy provenance proof не создают. History fallback используется при нерасшифрованном кандидате либо consumed KEX; новые packets не сканируют историю. Existing-row materialization тоже сохраняет proof. Actual SID и digest вычисляются до Realm write, чтобы не инвертировать storage/Realm locks.
- C counter-only duplicate остаётся неподтверждённым кандидатом и становится failed в OMEMO2 receive. Изменённые MAC/payload/recipient не поглощаются.
- Signal C snapshot v2 хранит возраст skipped MK. Удаление после1000 последующих успешных receives, MAX_SKIP1000/FIFO сохранены. Send/failed crypto/duplicate не старят MK. App SCE/save failures откатываются вместе с кандидатом. v1 import сохраняет keys/chains/EK/counters/pending и даёт полную event grace, без reset. UInt64 overflow перебазируется с сохранением возраста.

Пакет C `c775eb7`, ObjC `d142b4d` без изменений. Prepared pin и полный base→prepared patch обновлены; `tools/local_dependencies.py check` прошёл.

## Проверка

- TDD: 6 meaningful replay failures до app fix; schema assertion red. Первые history fixtures были malformed (missing rpad), исправлены до проверки результата; их ошибки не считаются доказательством дефекта.
- `OMEMO2NormativeReplayTests`9 + `OMEMO2NormativeReplayHistoryTests`12: настоящие ciphertext, tamper, old DH/KEX/regular, restart, candidates, live/MAM/carbon, controls, rollback, nil migration, raw marker rejection, history fallback без sessions/receipts, existing row, lock boundaries.
- Cached Debug iPhone16Pro iOS26 simulator gate **181/181**: эти21 + identity23, routing25, affixes55, receive28, state29. App и push extension compiled/linked; actual compiler/linker errors отсутствуют.
- Final completeness review добавил подготовку proof в поштучный fallback; повторный focused gate21/21 прошёл с app/push build.
- C CTest3/3 обычный и ASan, независимый reference vector, strict Clang syntax и narrow analyzer0 diagnostics (agent verification). Legacy Check suite не запускалась: Check pkg-config/library отсутствует.

Live interoperability не выполнялся. История без прежнего локального authenticated proof не объявляется duplicate по одному архивному ID. Полного journal и глобального cache нет.
