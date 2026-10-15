# Проверка клиента по актуальному XEP-PUSH

Дата: 2026-10-15. Исходная версия приложения: `958b7e07`. Спецификация: `/Users/igor.boldin/projects/xabber/xabber-knowledge/protocols/XEP-PUSH.md`, Draft 0.1, SHA256 `bf691b1027d2a38ccbf1b1685d38286c0d28450edf9d04ff47958ba18bb4c2c4`.

Работающий сервер вернул `bad-request` с текстом `Missing tag <encryption/> qualified by namespace 'https://xabber.com/protocol/push'`. Это прямо подтверждает несовместимость отправленного enable. Прежняя проверка локального server checkout `3992d263` описывала старый код и не доказывала контракт работающего сервера. Сервер в этой задаче не меняется.

## Исправления этой задачи

| Раздел XEP | Найдено | Изменение |
| --- | --- | --- |
| 6, 9 | `security cipher='urn:xmpp:ciphers:aes-256cbc'` с `encryption-key` | Ровно один `encryption algorithm='urn:xmpp:ciphers:aes-256-cbc'`, содержащий один `key`; оба элемента в namespace push. |
| 9 | Риск двойного base64 при переходе на новый тег | На wire передаются base64 ровно тех 32 bytes, которые сохранены в Keychain; повторная регистрация, refresh и смена full/summary сохраняют ключ. |
| 12 | Disable содержал `jid/node` и требовал локальный endpoint | Отправляется пустой session-scoped disable для своего аккаунта, даже без сохранённых node/service. |
| 14 и диагностика | Новый `key` не скрывался текущим XML-логгером | Маскируется текст `key`, включая prefixed XML и отражённый запрос в IQ error. Структура и причина ошибки остаются видны. |

Основной код: `xabber/xmpp/push_notifications/APNS/PushNotificationsManager.swift` и `xabber/models/account/Account.swift`.

Пример ожидаемой структуры (ключ намеренно скрыт):

```xml
<enable xmlns='https://xabber.com/protocol/push'
        jid='push.example.invalid' node='fixture-node' mode='summary'>
  <encryption algorithm='urn:xmpp:ciphers:aes-256-cbc'>
    <key>[redacted]</key>
  </encryption>
</enable>
```

Это исправляет конкретный формат, отвергнутый сервером. Новый успешный ответ и фактическая доставка push пока не получены.

## Уже реализованная часть

- Раздел 5: custom namespace определяется отдельно от стандартного XEP-0357; owner capabilities разрешают регистрацию.
- Разделы 6–7: mode явно передаётся как full или summary. Локальный default summary допустим, поскольку атрибут не опускается. Пустой IQ-result признаётся успешной регистрацией; HTTP grant не обязателен для enable.
- Раздел 9: AES-256-CBC использует 32-byte ключ из SecRandomCopyBytes; приём разделяет IV и ciphertext, расшифровывает без PKCS7 и удаляет конечные нули. Клиент не запрашивает Blowfish, поэтому его реализация не обязательна.
- Разделы 8, 10–11: общий app/NSE decoder понимает canonical notification и relay representation; проверяет encrypted namespace и единственную result data form push#info. Читает type, default message; dispatch выбирается по расшифрованному XML.
- Summary stanza-id/displayed/subscribe/JMI и full message поддерживаются. Full message может отображаться без HTTP grant; summary message использует архив. Это статическая проверка реализации, а не доказательство живой доставки.

## Оставшиеся ограничения

Полное соответствие XEP-PUSH после этой правки не заявляется.

| Приоритет | Ограничение | Код и необходимая проверка |
| --- | --- | --- |
| P2 | Открытое дополнительное поле outgoing может подавить расшифрованное событие; при некорректном значении envelope отвергается до decrypt. Это расходится с приоритетом encrypted payload по разделу 11. | `PushPayloadEnvelope.swift` и `NotificationService.action(for:)`. Убрать авторитет поля; проверять направление по расшифрованной stanza/архиву. Регрессии для конфликтующих metadata и plaintext. |
| P2 | Декодер требует один XML root, хотя раздел 9 допускает конкатенацию элементов. | `PushPayloadXML.element`. Нужны ограниченный parser fragments и явные правила неоднозначности для нескольких событий, тесты valid/invalid/mixed fragments. |
| P3 | iv-length сравнивается со строкой 16, а не с десятичным числом; запись 016 будет отклонена. | `PushPayloadXML.decrypt`. Нужны проверки decimal lexical form, длины 16 и границ ciphertext. |
| P3 | Для subscribe from проверяется непустая строка без полноценной проверки JID. | `PushPayloadXML.classify`. Нужны корректный sender JID и malformed sender fixtures. |

Эти пункты зафиксированы отдельно в vault; в данное исправление регистрации не включены. XEP-HTTPIQ и XEP-HTTPIQ-MAM этим отчётом не объявляются полностью реализованными.

## Проверка

Существующие тесты исправлены до production-кода: PushRegistrationContractTests, PushPayloadModeRegistrationTests, PushEnableDiagnosticsTests, PushLifecycleCapabilityTests. Добавлены три случая регистрации/disable и один случай key redaction в ConnectionDiagnosticsLoggerTests. Проверки покрывают namespace/cardinality, оба режима, binary key без double base64, reuse/retry/refresh, пустой disable без конфигурации и отказ чужому аккаунту, отражённый/prefixed key в XML-логе.

`git diff --check` проходит. Независимый обзор production diff выполнен отдельно. XCTest, xcodebuild и запуск на устройстве не выполнялись: пользователь попросил самостоятельно собрать и запустить приложение. Обновлённые тесты не считаются пройденными. Для следующей проверки нужны suites выше, затем IQ-result для нового enable и full/summary APNs fixtures на устройстве.
