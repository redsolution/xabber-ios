# OMEMO2 N06 — конечное удаление использованных private OPK

Завершено 2026-10-06.

## Основание и границы

[XEP-0384 §5.6](https://xmpp.org/extensions/xep-0384.html#usecases-receiving) требует eventual deletion использованного private PreKey. [§6](https://xmpp.org/extensions/xep-0384.html#rules) рекомендует отсрочку до завершения catch-up и требует empty reply при этой отсрочке. [§8](https://xmpp.org/extensions/xep-0384.html#security) допускает немедленное удаление. Сроки, UUID и локальные барьеры ниже — решение реализации клиента, а не дополнительные требования XEP.

Сервер сохранён как источник транспортной истины: существующий MAM `fin` завершает страницу, но не подтверждает decrypt/Realm persistence в приложении. Trust exchange, markers/receipts, fallback body и hints не изменены. Signal C/ObjC в N06 не меняются.

## Реализация

- `OMEMO2PreKeyCleanupCoordinator` принадлежит одному account. В памяти он отслеживает actual logical archive chains, отдельные регистрации query UUID и текущие receive ingress. Ключевой материал и consumed IDs остаются в protected aggregate.
- Storage уведомляет coordinator только после успешного crypto/SCE/identity transaction и освобождения owner lock. Удаление принимает конкретные ID и повторно проверяет `consumed` внутри атомарного protected save. Unused OPK, identity, SID, session snapshots и pending empty replies сохраняются.
- Основной, background и UI-action streams держат ingress от подготовки сообщения до archive routing/control accounting. Sync snapshot и push держат один дополнительный ingress на весь preview batch: разные отправители могут использовать один опубликованный OPK до получения empty reply.
- Современный archive engine держит ключи между страницами/retry до logical terminal. Adapter освобождает отдельную query только через существующий persistence/materialization terminal; отмена chain не снимает оставшийся query/ingress hold.
- Legacy/standalone/search registration получает отдельный token; stale terminal не снимает новую регистрацию с тем же query ID. Самостоятельный запрос имеет30 секунд ожидания transport terminal и30 секунд partial persistence после отказа/таймаута. Эти сроки повторяют существующую archive policy.
- Legacy continuation начинается после persistence предыдущей страницы и существующего2-секундного gap. Reset epoch защищает от возобновления отменённой chain; несвязанный запрос в gap её не отменяет. Registry retirement всегда выполняется асинхронно, чтобы не блокировать MessageManager queue на lifecycle lock. Nonfinal persistence timeout сообщает failure и завершает исходный callback ровно один раз; reset также завершает уже popped caller без новой страницы.
- Поздний control/duplicate accounting обновляет уже sealed proof и точное число materialization ingress. Изменение ожидания и парковка persistence pump синхронизируются, чтобы последний control не оставил обработку ждать несуществующее сообщение.
- Restart усыновляет persisted consumed IDs на фактической query/chain registration или authenticated maintenance/startup boundary. Plaintext/failed ingress сам по себе старые ID не усыновляет. Незарегистрированная гипотетическая будущая загрузка не удерживает private OPK бессрочно; persisted account-wide catch-up proof не вводился.
- Неудачное удаление не превращает успешный decrypt в ошибку. Eligibility остаётся для следующего maintenance/receive terminal. Уже известный EK расшифровывается через сохранённый snapshot после удаления OPK; новый EK с удалённым OPK отклоняется. Существующий durable empty reply остаётся обязательным и использует обычный control sender.

## Проверка

Task-specific XCTest сначала, production после compiling runtime RED27 tests/37 assertions,0 unexpected. Основная suite использует реальные storage/ciphertext и actual engine/MAM hooks; отдельные sync и restart suites проверяют actual manager boundaries.

- Финальный focused gate: **36/36** (`OMEMO2NormativePreKeyCleanupTests`30 + `OMEMO2NormativeSyncCleanupTests`3 + `OMEMO2NormativeCleanupRestartTests`3).
- Первый full focused32case прогон выявил реальную гонку late-control budget/parking и слишком быстрый yield-only wait в engine fixture. Точный budget recheck и established1ms bounded polling исправлены; production engine semantics не менялись для исправления fixture. Дополнительный review RED4cases воспроизвёл restart retention и потерю legacy timeout callback/failure,0 unexpected; две negative restart проверки уже проходили.
- Affected gate охватил **561** сценарий/30 classes: все OMEMO2 tests, engine/consumed continuation/transport receipt/search/hard-cut/primary stanza queue. **560 прошли**, один старый N04 fixture повторно использовал уже consumed OPK для новой сессии вне catch-up. Fixture переведён на актуальный public bundle с отдельной проверкой нового OPK ID; multi-candidate replay assertion сохранён. Финальный повтор всей replay suite **9/9 прошёл**. После broad gate production код не менялся; все проверяемые регрессии имеют успешный финальный результат.
- `tools/xcodebuild_cached.sh test`, Debug, iPhone16Pro iOS26 (`91E09D3E-4BBC-4431-9EAF-14D2410E7B98`), isolated hosted runner; app и push extension compiled/linked. Actual compiler/linker errors отсутствуют. Без clean/cache reset; disposable logs/result bundles удалены после фиксации результатов.
- `git diff --check` и `python3 tools/local_dependencies.py check` прошли. Независимый final source review auth cleanup, async retirement, once-only continuation terminals и budget parking не выявил оставшихся actionable defects.

Live server interoperability в этой задаче не выполнялся. Старый storage `finishCatchUp()` остаётся test compatibility API; production использует selective IDs через coordinator. Нет заявления о persisted глобальном catch-up proof или расширения trust exchange.
