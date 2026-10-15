# Summary push: XEP-HTTPIQ и XEP-HTTPIQ-MAM

Дата: 2026-10-15. Исправление заменяет прежнее предположение, что успешный push-enable содержит URL/JWT для архива. Основание: актуальные `protocols/XEP-HTTPIQ.md` и `protocols/XEP-HTTPIQ-MAM.md` в xabber-knowledge и прямые требования пользователя. Локальный старый server checkout не определяет этот wire contract. Сервер не изменяется.

Минимальная проверка пользователя на iPad пока не пройдена: после успешного summary push-enable сервер `xmppdev01.xabber.com` отклонил правильный endpoints IQ с `service-unavailable` и текстом `No module is handling this query`. До запроса и сохранения JWT цепочка не дошла. Ниже отдельно приведены результаты автоматических тестов и фактического запуска.

## Реализованная последовательность

1. Клиент получает коррелированный успешный ответ на push-enable. Сам push считается включённым независимо от готовности HTTP. Если актуальный выбранный режим summary, клиент отправляет IQ get к XMPP domain с `<endpoints xmlns='https://xabber.com/protocol/http-iq'/>` и from текущего bound JID.
2. В ответе выбирается единственный `<protocol var='urn:xmpp:mam:2'><endpoint name='by-id' url='...'/></protocol>`. Неизвестные ветви и имена игнорируются; неоднозначный или неподходящий endpoint не используется. URL должен быть абсолютным HTTPS. Значение берётся из discovery без построения пути по шаблону.
3. Клиент отправляет IQ get к тому же domain: `<token xmlns='https://xabber.com/protocol/http-iq'><scope>urn:xmpp:mam:2</scope><ttl>3600</ttl></token>`. Сервер определяет effective TTL; клиент принимает optional positive ttl и обязательные scopes/value/expires, проверяет MAM scope и будущий XEP-0082 expires.
4. Endpoint и выданный token публикуются одной атомарной записью shared Keychain вместе с прежним AES-ключом, scopes, абсолютным сроком действия, discoveryDomain и локальной revision. Endpoint отдельно от token не публикуется. Readback проверяет сохранённый context. Старый grant не считается отозванным только из-за выдачи нового: протокол разрешает повторное использование до expiry.
5. Extension расшифровывает summary stanza-id, читает типизированный shared grant и отправляет GET к точному discovered endpoint с percent-encoded id и optional by, Authorization Bearer и без body/cookies. URL не получает суффикс /archive. Ответ application/xml — ровно один XML document: MAM message/result или IQ error при HTTP200. Старое оборачивание последовательности message+fin удалено.

Основные файлы: `PushHTTPIQ.swift` (codec), `PushNotificationsManager.swift` (состояния/корреляция), `PushCredentialRecord.swift` и `CredentialsManager.swift` (shared запись), `PushArchiveHTTPClient.swift` (HTTP profile), extension `NetworkManager.swift` и `NotificationService.swift` (использование).

## Состояние и восстановление

- Full-mode enable не запускает discovery/token. Full payload по-прежнему может отображаться без HTTP. Если ранее сохранённый современный grant ещё действителен, его можно использовать для summary payload независимо от текущего предпочтения full/summary.
- Каждая HTTP IQ фаза имеет собственный ID и timeout. Проверяются текущие owner/domain, recipient/resource, primary stream и configuration epoch. Смена режима/конфигурации, disable и clearSession отменяют ожидаемую цепочку. Дубли и поздние ответы не публикуют данные.
- Ошибка endpoints/token или записи Keychain не выключает подтверждённые push. Повторная foreground-проверка не перезапускает ещё ожидаемую цепочку. После ошибки, timeout, expiry или rejection marker следующая попытка может запросить контекст заново.
- Scope/expiry/discovery domain проверяются в приложении и extension. Более ранний JWT exp учитывается только как scheduling hint, не как проверка подписи. Подпись и доступ к архиву проверяет HTTP-сервер.
- Redirect не получает Bearer на новый URL. Ответ ограничен по размеру, времени и числу transient retries; cancel/expiry завершаются однократно. HTTP401 помечает использованную generation, не повреждая более новый grant.

## Миграция

Shared record v3 содержит optional httpArchive {endpoint, token, scopes, expiresAt, discoveryDomain}. Старые v1/v2 записи сохраняют AES keyBytes, но их flat service/jwt не дают HTTP-ready и не преобразуются в предполагаемый endpoint. Новый путь не использует grant form из push-enable. Flat поля остаются для чтения старых данных/source compatibility и очищаются при публикации нового контекста. Старые бинарники с decoder только v1/v2 не читают v3; rollback не проверялся.

## Логи

Полное pretty XML логирование стрима сохранено без redaction, escaping и подмен по прямому требованию пользователя. Поэтому endpoints/token IQ видны в CONNECTION_DIAGNOSTICS как обычные станзы. Дополнительный HTTP_IQ_ARCHIVE выводит через NSLog события и полные request/response XML для консоли физического устройства, сообщает timeout/rejected/invalid context/credential publication и grant_stored readback=matched ready=true|false. ready относится к локально проверенной HTTP-готовности, а не доказывает успешный запрос сообщения на устройстве. В этот отчёт значения ключей, JWT, push node и личное содержимое не копируются; сами XML-логи приложение не редактирует.

## Проверка

Сначала написаны/обновлены соответствующие XCTest, затем production-код. Реализация закреплена коммитом `ed871c73`. Узкий simulator run прошёл: **76/76 тестов**, без ошибок — PushHTTPIQProvisioningTests 24, HTTPArchiveByIDTests 32, PushCredentialMigrationTests 19, PushPipelineIntegrationTests 1. Интеграционный тест проходит enable → endpoints → token → reload shared credentials → HTTP → MAM preview/route на изолированном тестовом транспорте.

Статическая проверка: `xcrun swiftc -frontend -parse` для17 изменённых Swift-файлов прошла; `plutil -lint xabber.xcodeproj/project.pbxproj` и `git diff --check` прошли. Независимые source reviews покрыли codec/manager и shared credentials/NSE. Проверка синтаксиса не проверяет типизацию и не заменяет сборку.

В первом affected run два lifecycle-сценария содержали устаревшее предположение о повторном enable во время ожидающего endpoints. Fixtures исправлены: сначала отклоняется коррелированный endpoints IQ, затем проверяется foreground retry. Узкая перепроверка PushLifecycleCapabilityTests прошла 12/12. Итоговый единый affected run прошёл **80/80**, без ошибок: PushEnableDiagnosticsTests 19, PushLifecycleCapabilityTests 12, PushPayloadModeRegistrationTests 12, PushRegistrationContractTests 37. Итого **156 разных тестов (76 + 80)**; повторённые 12 lifecycle-тестов отдельно к сумме не прибавляются.

Первоначальная оговорка об отсутствии сборки и запуска по желанию пользователя устарела: последующая прямая инструкция требует проверять на подключённом iPad. Debug simulator test action собрал приложение и extension. Подписанная Debug-сборка для физического iPad также прошла, включая `xabber` и встроенный `xabber-push-extension`; приложение установлено поверх существующего и запущено. Устройство: iPad (Redsolution), iPad Air 11-inch (M3), iOS 26.7.1. UUID последнего установленного `xabber.debug.dylib`: `62FA6DB4-BC79-3A3D-9C1B-32F4848C5401`.

На iPad воспроизведено несколько раз: после принятого summary push-enable клиент посылает IQ `get` на `xmppdev01.xabber.com` с `<endpoints xmlns='https://xabber.com/protocol/http-iq'/>`; сервер отвечает IQ `error`, `service-unavailable`, `No module is handling this query`. Адресат — XMPP domain, from — текущий bound JID. Отдельный token IQ не отправлялся; новый JWT не получен и новый typed shared grant не опубликован. Успешная сборка и simulator pipeline не заменяют отсутствующее подтверждение на устройстве.

Продолжение после доступности серверного обработчика: endpoints result с MAM by-id → token result с MAM scope и будущим expires → атомарная запись shared Keychain и `grant_stored readback=matched ready=true`. Именно получение JWT и его сохранение — обязательный минимум пользователя. Серверный код не изменялся; локальный checkout не доказывает версию развёрнутого обработчика. Реальную push-доставку пользователь проверяет самостоятельно.

Оставшиеся отдельные ограничения XEP-PUSH (outgoing metadata, несколько XML payload fragments, lexical iv-length, subscribe JID) не объявляются исправленными этой задачей; они уже заведены отдельно в vault.
