# Summary push: XEP-HTTPIQ и XEP-HTTPIQ-MAM

Дата: 2026-10-15. Исправление заменяет прежнее предположение, что успешный push-enable содержит URL/JWT для архива. Основание: актуальные `protocols/XEP-HTTPIQ.md` и `protocols/XEP-HTTPIQ-MAM.md` в xabber-knowledge и прямые требования пользователя. Локальный старый server checkout не определяет этот wire contract. Сервер не изменяется.

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

Полное pretty XML логирование стрима сохранено без redaction, escaping и подмен по прямому требованию пользователя. Поэтому endpoints/token IQ видны в CONNECTION_DIAGNOSTICS как обычные станзы. Дополнительный HTTP_IQ_ARCHIVE сообщает timeout/rejected/invalid context/credential publication и grant_stored ready=true|false. ready относится к локально проверенной HTTP-готовности, а не доказывает успешный запрос сообщения на устройстве.

## Проверка

Сначала написаны/обновлены соответствующие XCTest, затем production-код. Новый PushHTTPIQProvisioningTests содержит24 теста; HTTPArchiveByIDTests —32; PushCredentialMigrationTests —19. Также обновлены registration/mode/diagnostics/lifecycle и интеграционный pipeline enable → endpoints → token → reload shared credentials → HTTP → MAM preview/route. Эти количества обозначают написанные случаи, а не выполненные тесты.

Статическая проверка: `xcrun swiftc -frontend -parse` для17 изменённых Swift-файлов прошла; `plutil -lint xabber.xcodeproj/project.pbxproj` и `git diff --check` прошли. Независимые source reviews покрыли codec/manager и shared credentials/NSE. Проверка синтаксиса не проверяет типизацию и не заменяет сборку.

По просьбе пользователя XCTest, xcodebuild и запуск на устройстве не выполнялись. Новый успешный live token/result и фактическое APNs summary → HTTP preview ещё не наблюдались. Ручная проверка: summary enable ACK → endpoints result с MAM by-id → token result с MAM scope/expires → grant_stored ready=true → входящий summary push и archive preview. Отдельно проверить full без HTTP, expiry/401 и logout во время запроса.

Оставшиеся отдельные ограничения XEP-PUSH (outgoing metadata, несколько XML payload fragments, lexical iv-length, subscribe JID) не объявляются исправленными этой задачей; они уже заведены отдельно в vault.
