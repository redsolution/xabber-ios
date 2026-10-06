# OMEMO2 N07 — ручная замена и восстановление отсутствующей сессии

Дата: 2026-10-06. Основание: [XEP-0384 §6/8](https://xmpp.org/extensions/xep-0384.html#rules). Ручная замена — MUST, ответ при отсутствии session — SHOULD; автоматический reset при ошибке decrypt запрещён. Ограничения времени/числа запросов и устройство UI — политика клиента.

## Изменения

- Настройки шифрования аккаунта предлагают замену всех его исходящих сессий с явным подтверждением. Protected owner state сохраняется одной атомарной записью: snapshots становятся receive-only, current pointers и pending controls очищаются. Identity, device ID, SPK/OPK, replay proofs, доверие и история сохраняются; save failure не меняет состояние.
- Следующая отправка ждёт свежий bundle. Correlated IQ связан с account/peer/SID, reset generation и digest фактических IK/SPK/OPK. Headline/cache, чужой sender/device, устаревший или ошибочный IQ не разрешают отправку. Защита сохраняется после restart. Новый EK создаётся после проверки bundle; уже выбранные OPK исключаются.
- При строго разобранном regular ciphertext и доказанном отсутствии **всех** snapshots запрашивается свежий bundle и отправляется только empty KEX. Архивные/receive-only sessions, MAC, format, SCE, identity и storage errors не запускают автоматическую замену. Untrusted identity не получает доверия и не разрешает user content.
- Неизвестный SID сначала проходит обновление authoritative devices list. Принятое обновление продолжает recovery без следующего сообщения; removed SID не восстанавливается. Volatile candidates ограничены 256 адресами/120 секундами, fresh IQ — 120 секундами. Они не содержат XML/текст и не являются outbox.
- Новый bundle с другим IK отзывает существующее доверие, сохраняя snapshots ручной замены для delayed receives. AES payload framing проверяется до missing-session recovery.

## Миграция

Protected schema version 1 получает optional replacement metadata и public outgoing OPK metadata без сброса старых sessions. Для snapshots без public metadata read-only Signal accessor возвращает ID удалённого OPK только для инициатора, включая подтверждённую/восстановленную сессию; responder возвращает 0. Фильтр связывает ID с фактическим remote identity. Криптография и формат C snapshots не меняются. Неповреждённые старые записи позволяют исключить OPK после ACK. Если сохранённый provider snapshot вообще не восстанавливается, явная manual replacement может продолжить только после проверенного fresh bundle, сохраняя плохой blob; определить его неизвестный старый OPK невозможно. Повреждение aggregate/current/nonmanual state не игнорируется.

## Проверка

TDD: initial meaningful RED26 (19 failed/7 passed), дополнительные RED для unknown-SID continuation, expired IQ, changed-IK archive preservation и malformed CBC framing; UI RED2/3. Исправлены test-only JID normalization, throwing XCTUnwrap и wire QName fixtures до принятия результатов.

Промежуточный cached Debug/iPhone16Pro/iOS26 gate: 33 core +3 UI =36/36; app и push extension собраны. Финальный affected gate: 290/290 OMEMO/app/UI cases прошли (37 task core +3 UI внутри прогона332). Readonly migration getter: C29d4e8b / ObjC6644310; CTest3/3. После добавления трёх отсутствующих активных переводов финальный focused locale/UI gate9/9, включая все7keys ×6languages и compiled app/push resources. Task UI теперь4/4, core37/37; app/push собраны через cached simulator test actions. local_dependencies.py check2/2, diff checks прошли.

Общий332gate имел27assertions в7LocalizationCatalog methods: реальная missing-English проверка исправлена и прошла; остальные6methods/25assertions относятся к неизменённым прежним переводам и test-only parser escaped %% (подтверждено сравнением целых catalog entries с HEAD). Их ожидания не обновлялись в этой задаче. Это ограничение общего localization gate, не падение OMEMO tests. Standalone ObjC test scheme не запускался; реальный wrapper проверен Swift migration cases.

Перегенерирован localization manifest для четырёх новых UI keys; убраны четыре устаревших scanner exclusions после предыдущей QName-нормализации, восемь точных protocol-token exclusions классифицированы без исключения UI copy.

Server и trust/code exchange не меняются. Markers/receipts остаются plaintext; fallback body/hints сохраняются. Live interoperability не проверялась. [План](omemo2-standard-compliance-plan.md).
