# Summary push: XEP-HTTPIQ и XEP-HTTPIQ-MAM

Дата: 2026-10-15. Реализовано в `ed871c73`, исправление адресации — `ea1db4e9`, удаление проверки входящего from — `81f0d618`. Источники: актуальные XEP-HTTPIQ/XEP-HTTPIQ-MAM в xabber-knowledge и прямые уточнения пользователя. Серверный код не изменялся.

## Текущий контракт

1. После успешного summary push-enable клиент отправляет IQ get с `<endpoints xmlns="https://xabber.com/protocol/http-iq"/>`. В исходящем IQ нет `to` и `from`.
2. Выбирается единственный MAM2 endpoint `by-id` с абсолютным HTTPS URL. Неизвестные ветви игнорируются; путь не строится по шаблону.
3. По тому же аутентифицированному стриму отправляется IQ get с `<token/>`, scope `urn:xmpp:mam:2` и запрашиваемым TTL2592000 (30 суток), также без `to` и `from`.
4. Входящий `from` не проверяется и не переписывается. Сохраняются проверки ID и текущей фазы, primary stream/resource, конфигурации, режима, timeout и получателя. Scope/expiry/содержимое ответа проверяются отдельно.
5. Полный grant (endpoint, token, scopes, expiresAt, discoveryDomain) публикуется атомарно в shared Keychain вместе с прежним AES-ключом и revision. Чтение после записи подтверждает сохранённый контекст.
6. NSE использует точный discovered URL, HTTP GET с encoded id/optional by и Bearer. Принимается одиночный XML MAM message/result либо IQ error, а также проверенная согласованная пара `message + iq/fin` в `application/xml` или `text/xml`; подробнее — [совместимость с ответом сервера](push-http-mam-server-response-2026-10-16.md).

С 2026-10-16 клиент запрашивает срок JWT 30 суток. Сервер может выдать меньший срок; приложение сохраняет фактический `<expires>` ответа. Уже выданные токены автоматически не продлеваются.

Push-enable ACK и HTTP readiness разделены. Ошибка discovery/token не выключает подтверждённый push. Full mode не запускает provisioning; полный payload не зависит от HTTP. Повторный foreground не перезапускает активную цепочку; stale/duplicate/configuration results не публикуются. Shared record v3 сохраняет AES из v1/v2, но legacy flat URL/JWT не повышаются до современного HTTP grant. Expiry, scope/domain и generation-specific invalidation проверяются приложением и extension; redirects не разрешены. Более ранний JWT exp используется только как local scheduling hint.

Основные файлы: `PushHTTPIQ.swift`, `PushNotificationsManager.swift`, `PushCredentialRecord.swift`, `CredentialsManager.swift`, `PushArchiveHTTPClient.swift`, extension `NetworkManager.swift` и `NotificationService.swift`. Регрессии исправления адресации и ответов находятся в `PushHTTPIQProvisioningTests.swift`, `PushLifecycleCapabilityTests.swift`, `PushPipelineIntegrationTests.swift`.

## Проверка после всех уточнений

Финальный simulator test action: **158 тестов, 0 failures, 0 unexpected**, xcodebuild exit0, `TEST SUCCEEDED`. Наборы: provisioning26, HTTP32, migration19, pipeline1, diagnostics19, lifecycle12, mode12, registration37. Test action собрал приложение и embedded NSE. Перед реализацией тесты воспроизвели дефекты: первая RED-проверка39 тестов/28 failures (включая1 unexpected), затем отдельный RED для from —1 тест/16 failures/0 unexpected. Эти RED не прибавляются к итоговым158.

Подписанная Debug-сборка для iPad (Redsolution), iPad Air11-inch M3, iOS26.7.1 прошла; приложение установлено поверх данных и запущено. Последний `xabber.debug.dylib` UUID: `58A155DA-D8E8-3680-A3E4-61BCD00244D3`.

На последней сборке в14:42:15 +05:00 фактически наблюдались оба исходящих IQ без `to`/`from`, успешные ответы endpoints/token с совпадающими ID, реальный JWT со scope `urn:xmpp:mam:2`, TTL3600 и expires `2026-10-15T10:42:15Z` (будущий на момент выдачи). События:

```text
14:42:15.799 HTTP_IQ_ARCHIVE event=token_received scope=urn:xmpp:mam:2
14:42:15.804 HTTP_IQ_ARCHIVE event=grant_stored readback=matched ready=true
```

Минимум пользователя — реальное получение JWT и сохранение/read-back из shared Keychain на iPad — выполнен. Ответ содержит from и обрабатывается без его валидации. После capture приложение нормально перезапущено. Runtime HTTP MAM и push-доставку пользователь проверяет самостоятельно; simulator pipeline отдельно покрывает shared reload → HTTP → MAM preview/route.

## Историческая ошибка и логи

Первоначальные примеры XEP задавали to/from; такой адресованный запрос получил service-unavailable / No module is handling this query. После исправления документации и клиента сервер ответил успешно. Прежний вывод о необходимости изменения серверного обработчика отменён. Ранний успех в14:35 относился к промежуточному ea1db4e9; финальный успех выше подтверждён повторно после81f0d618.

Полное pretty XML логирование сохранено без redaction, escaping и подмен. HTTP_IQ_ARCHIVE печатает полные request/response XML и события в консоль устройства. В этот отчёт значения JWT, ключей, node и личное содержимое не копируются. Xcode caches сохранены; disposable logs/results удаляются после фиксации отчёта. Другие ранее заведённые ограничения XEP-PUSH этой задачей не объявляются исправленными.
