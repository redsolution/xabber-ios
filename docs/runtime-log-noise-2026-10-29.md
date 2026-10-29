# Разбор шума runtime-лога — 2026-10-29

Исправление по следующему запросу пользователя: [PEP, дедупликация запросов и единый XML-вывод](pep-fetch-dedup-and-xml-logging-2026-10-29.md), 354/354 simulator tests. Ниже сохранён исходный разбор до исправления.

Основной объём создаёт само приложение: массовые стартовые PEP-запросы умножаются на несколько Info-событий на каждую stanza, полный XML и отдельный повторный вывод OMEMO XML. При этом в выводе есть реальные ошибки UI и обработки групп. Сокращение одних сообщений не исправит эти ошибки или лишний сетевой трафик.

## Данные и метод

- Фрагмент физического устройства: 29 октября 2026, 16:52:33.200–16:55:01.225, UTC+05:00; около 148 секунд.
- 6 269 741 байт, 47 341 физическая строка, 6 341 логическая запись. Границы записей определены по завершающим строкам `Type:`; многострочный XML считается частью одной записи. Доли рассчитаны по исходным байтам с сохранением CRLF.
- SHA256 оригинального вложения: `c8c94970eee4869c6b0690b2f68cc88f9d3c5bbaef6a912045aac0b023f85b60`.
- Код сопоставлен с checkout `7564a2ce`. Версия бинарника из вложения не установлена: его DerivedData находится по другому пути. Источники ниже соответствуют текущему коду, а не доказанной идентичности той сборки.
- Исходный лог остаётся в приватном вложении. Здесь нет содержимого переписки, адресов пользователей, ключей и токенов.

| Источник | Записей | Байт | Доля файла |
|---|---:|---:|---:|
| `CONNECTION_DIAGNOSTICS`, включая XML | 5 632 | 5 295 294 | 84,46% |
| Отдельный `OMEMO_BUNDLE_XML` | 102 | 680 129 | 10,85% |
| UIKit: конфликтующие constraints | 55 | 147 441 | 2,35% |
| Остальное | 552 | 146 877 | 2,34% |

Пик в 16:54:14: **997 записей и 1 332 268 байт за секунду**. Это измерение объёма вывода; CPU-затраты и влияние на задержки по этому логу не измерены.

## 1. Постоянная диагностика размножает каждую stanza

`ConnectionDiagnosticsLogger.log` в `xabber/models/account/Account.swift:3132–3177` безусловно вызывает `DDLogInfo`. Нет runtime-переключателя или ограничения частоты. `rawXMLLoggingEnabled = true` на строке 3136.

`AppLoggingPolicy` в `xabber/application/AppDelegate.swift:31–40` допускает `.debug` в обычной сборке и `.info` в Release. Следовательно, по текущему коду `CONNECTION_DIAGNOSTICS` попадает и в Release OS logging. `SettingManager.logEnabled` управляет файловым logger (`AppDelegate.swift:170–182`) и частью старых сообщений; глобальную диагностику он не отключает.

Одна входящая stanza обычно создаёт полный XML, `resilience_activity_observed` и `connection_health_snapshot`; IQ-ответ дополнительно создаёт `primary_stream_iq_response_correlated`. Исходящая stanza создаёт XML, outbound activity и health snapshot.

- Входящие IQ/presence/message: `xabber/models/account/delegates/AccountStreamDelegate.swift:558–566`, `:630`, `:698`.
- Activity и публикация health: `xabber/models/account/Account.swift:1855`; outbound: `:1356`; логирование snapshot: `:3406`.
- 1 595 `connection_health_snapshot`, 1 171 `resilience_activity_observed`, 421 `resilience_outbound_stanza_observed` = **3 187 сообщений и 1 817 157 байт, 28,98% всего файла**, ещё до XML.
- Все 1 595 health snapshot имеют `isSuspectedStale=false`.
- Один SM ack диагностируется на двух стадиях: raw ack (`AccountStreamDelegate.swift:461`) и обработанные IDs (`:1204`). 53 подтверждения дают 106 activity и 106 health snapshot. Это повторная диагностика, не повторная передача ack по сети.

История: безусловный Info logger появился в `4f89add8` от 21 мая; полный XML по умолчанию включён в `958b7e07` от 15 октября; текущая передача полного pretty XML закреплена в `130b2d3a`.

## 2. Стартовый обход аватаров добавляет трафик поверх PEP

В логе **324 явных IQ get avatar metadata к 324 разным адресатам**, по одному на адресат. Это обход всего ростера, а не зацикленный retry одного адреса. Запросы идут с 16:54:08.172 до конца фрагмента 16:55:01.177.

Источник: `xabber/xmpp/avatar/AvatarReceiverManager.swift:49–63`. `onStreamPrepared` очищает session state, запрашивает metadata владельца и каждого неудалённого roster-контакта. Очередь на строках 398–428 имеет background priority и generation/deduplication key, но не отменяет сам массовый обход. Формирование IQ — строки 431–455.

Пользователь уточнил ожидаемое поведение: **PEP присылает items после presence как для аватаров, так и для бандлов**. Это общий механизм PEP: initial presence с соответствующим interest/caps вызывает notification, при соблюдении доступа. Стандарт требует как минимум последний item и допускает дополнительные; получение всех device items нельзя выводить только из наличия одного headline. См. [XEP-0163 §4.3.3–4.3.4](https://xmpp.org/extensions/xep-0163.html#notifications-last).

Клиент уже объявляет `urn:xmpp:avatar:metadata+notify` (`AvatarReceiverManager.swift:90–94`) и принимает metadata headline (`:380–389`). `OmemoManager.swift:35–42` объявляет `+notify` для devices и bundles. Поэтому массовые metadata get нельзя считать обязательным условием работы PEP. Поиск отсутствующих данных должен быть отделён от безусловного опроса всех контактов.

Обход добавлен в `9cae2c79` от 6 октября, «Fix startup sync and profile hydration regressions». Соответствующие старые заметки называют его hydration; это расходится с уточнённым пользователем приоритетом PEP и требует отдельного исправления/регрессионного сценария.

532 появления XML-тега metadata `max_items=1` — это 324 исходящих запроса и 208 отражённых копий в ответах, не 532 отправленных IQ. Входящие IQ всего фрагмента включают 165 `item-not-found`, 22 `remote-server-timeout`, 18 `not-authorized`; эти счётчики не ограничены одной avatar-ноды.

По [XEP-0084 §3.3–3.4](https://xmpp.org/extensions/xep-0084.html#proto-notify), после metadata notification клиент проверяет кэш и получает сами данные только при необходимости; отдельный IQ за недостающим avatar data не равен повторному metadata get.

## 3. OMEMO печатается повторно

`xabber/xmpp/omemo/OmemoManager.swift:836–840` выводит отдельно `OMEMO_BUNDLE` summary и `OMEMO_BUNDLE_XML`. `OMEMO2BundleDiagnostics.swift:12–16` включает XML в Debug.

Найдено 102 summary и 102 XML: 69 received, 31 headline, одна собственная публикация и один ответ на неё. 97 XML содержат bundle payload, и во всех 97 случаях тот же материал уже есть в глобальном XML logger. Проверка выполнена локальным сравнением хешей нормализованных значений без вывода ключей. 66 полных IQ также совпадают после нормализации межтеговых пробелов; все 71 IQ-запись сопоставлены с глобальными sent/received ID.

В сети видны **69 bundle GET и одна собственная bundle PUBLISH (SET)**. Предварительный подсчёт 70 относился ко всем исходящим IQ этой ноды, а не только к GET. Сетевое дублирование и повторный вывод одного XML — разные явления: совпадение двух logger не означает два сетевых запроса.

### Подтверждённые пересечения PEP и явных запросов

Подсчёт только по глобальным входящим XML, без повторного OMEMO logger:

| PEP node | Входящих событий | Явных GET |
|---|---:|---:|
| Avatar metadata | 82 | 324 |
| OMEMO devices | 39 | 2 |
| OMEMO bundles | 31 | 69 |

- **61 avatar GET** отправлен после metadata push того же контакта/ноды; 71 пересекается с push где-либо в записи.
- **14 bundle GET** отправлены после push того же контакта **и device item**; 15 пересекаются без учёта порядка. Все 15 ответов содержат тот же bundle payload, что соответствующий headline. Само получение push ещё не доказывает успешное прохождение strict validation и запись в cache.
- 69 bundle GET приходятся на 53 уникальные пары контакт/device: **16 повторных GET**. Один и тот же список из восьми устройств пришёл трижды в 16:54:14.315/.335/.348 и вызвал 24 запроса вместо восьми, до первых ответов.
- 62 запроса имеют более ранний push той же ноды/контакта, но объявлять их все лишними нельзя: у ноды могут быть разные device items. Все 31 bundle headline в этом фрагменте содержат один item с настоящим payload.

Причина повторных bundle GET: PEP devices headline вызывает `applyDeviceList` (`xabber/xmpp/omemo/OmemoManager+Devices.swift:93–111`), а цикл `:166–168` планирует `getContactBundle` для каждого device ID даже при повторном списке. Проверка существующей identity в `OmemoManager.swift:460–468` не объединяет ещё не завершённые запросы и не имеет cooldown после отклонения.

Есть **91 отклонение входящих bundle** с текстом `rejected OMEMO2 bundle publication` (это не ошибки собственной публикации): 90 `invalidBase64OrKeyLength`, одно `invalidKeyID`. Во всех диагностируются `ikBytes=33 spkBytes=33`; текущий `OMEMO2BundleCodec.swift:88–99` требует 32 байта для IK/SPK/prekeys. Конкретный первый сбой длины мог относиться к prekey, который проверяется раньше; один случай имеет отдельную причину invalidKeyID. Неудачная валидация объясняет отсутствие этих payload в валидном identity cache: данные уже пришли, но не приняты, а явный GET может снова вернуть ту же несовместимую публикацию. 15 совпадений payload между headline и GET подтверждают повторную передачу одинакового материала, не успешную crypto-валидацию.

Дополнительное возможное окно: обработка push bundle откладывается через `RunLoop.main.perform` (`OmemoManager.swift:688–705`), поэтому даже ещё не обработанный payload не виден обычной проверке cache. Вклад именно этой задержки по логу не измерен. Ослаблять crypto-валидацию или механически преобразовывать ключи для устранения шума оснований нет.

Отдельный recovery flow (`OmemoManager+Encryption.swift:553–581`) уже объединяет запросы по адресу/generation на 120 секунд и требует свежий коррелированный IQ для снятия reset. Это самостоятельная authority-проверка; нельзя удалить все bundle GET только на основании наличия PEP. Обычное получение доступного item через PEP и специальное recovery должны быть разными сценариями.

Цикл массового bundle-fetch и `+notify` исторически сосуществовали ещё в `519d3586` от 27 декабря 2023; текущий device-list код переработан в `84a8fe9b` от 5 октября 2026. Изменение `f0d0cbd6` от 28 октября откладывает фоновую загрузку до startup sync, но не объединяет повторные запросы после открытия очереди.

Действующий проектный контракт требует сохранять полный исходный XML. Направление сокращения — убрать повторный канал вывода и частые служебные события, сохранив один полный XML, а не менять или обрезать XML.

## 4. Реальные ошибки, которые нельзя просто скрыть

**55 конфликтов Auto Layout.** Лог показывает `UITableViewCellContentView.height == 44`, внутри вертикальный stack с отступами 2+2 и `bottomStack.height == 44`, плюс верхняя строка. UIKit вынужден ломать ограничения.

Совпадающая конструкция: `xabber/controllers/chats/common_cells/ChatListTableViewCell.swift:89`, `:642`, `:725`, `:732`. `layoutIfNeeded()` вызывается при настройке ячейки (`:690`), ещё до штатной высоты строки 84/48 (`LastChatsViewController+UITableViewDelegate.swift:284`). Ранний layout — сильный кандидат причины; точное исправление требует воспроизведения, а не одного снижения priority.

**53 `Group presence rejected: missingGroup` для 53 разных групп**, уже после `snapshotComplete` в 16:54:07.965. Available presence содержит group info/pinned/settings. `GroupStanzaRouter.swift:265–285` направляет его как patch; `GroupRepository.swift:94–98` требует существующий canonical snapshot. При его отсутствии stanza поглощается с Error (`AccountGroupchatIntegration.swift:955`). Это проблема начального состояния/гидратации, а не доказательство сетевого разрыва.

**8 `Group message rejected: ambiguousShape`** относятся к архивной старой форме invite с namespace `https://xabber.com/protocol/groups#invite` и group `x/privacy`. Текущий router направляет этот `x` в author decoder (`xabber/xmpp/groupchat/transport/GroupStanzaRouter.swift:544–552`), ожидающий ровно один прямой `user` (`GroupProtocolCodec.swift:155–159`). Нужен отдельный разбор совместимости старой формы; ослаблять проверку всех входящих group message нельзя.

**3 предупреждения multiple scroll observers.** В логе одна таблица Last Chats наблюдается двумя UINavigationController; UIKit снимает предыдущего observer. Это отдельный вопрос жизненного цикла navigation container; точный инициатор без call stack не доказан.

## 5. Остальные предупреждения и вводящие в заблуждение названия

- **24 `resilience_primary_stream_ack_timeout`** имеют `action=diagnosticOnly`. Tracker timeout — 5 секунд (`AccountPrimaryStreamStanzaTracker.swift:735–738`), обработчик `Account.swift:1368` не закрывает stream. Первый запрос: 16:54:08.221; timeout: 16:54:13.228; ответ: 16:54:13.835. Нет `tcp_disconnected`, фактического `stream_management_ack_timeout` или `connection_health_suspected_stale` в этом фрагменте.
- `stream_management_resume_failed response=full-auth` не доказывает неудачный вход: код называет так любое `didResume=false`, затем выполняет обычную полную подготовку (`Account.swift:1440–1456`).
- Один HTTP timeout `-1001` относится к Realm debug telemetry. Локальный источник: `Pods/Realm/Realm/RLMAnalytics.mm:395–417`, endpoint `data.mongodb-api.com`; существующее отключение — environment `REALM_DISABLE_ANALYTICS=1`. Это не ошибка XMPP или Xabber API.
- Пустой dSYM: одно предупреждение LLDB. Причина для чужого build artifact не доказана. Один из возможных вариантов — новая схема Xcode с основным кодом в debug dylib: [Apple: build product layout](https://developer.apple.com/documentation/xcode/understanding-build-product-layout-changes). Менять build settings по одному предупреждению оснований нет.
- App Group preferences: одно сообщение CoreFoundation; MediaAnalysis XPC: два; Network path: два. Их малое количество не объясняет объём. Этот лог сам по себе не доказывает поломку App Group или потерю настроек.
- Ещё один snapshot до render, один layout таблицы вне view hierarchy и шесть NSStringEncoding notices. Для точного источника последних нужен stack trace.

## Предлагаемый порядок исправлений

1. Устранить безусловный roster-wide metadata sweep, принимая PEP как основной источник. Bundle-fetch отдельно разделить на массовый обход и адресные запросы действительно отсутствующего device item; объединять одинаковые in-flight запросы и не перезапрашивать неизменившийся уже отклонённый payload при каждом device-list событии. При этом должны оставаться обновления PEP, invalidation и отдельная fresh-IQ recovery authority.
2. Health/activity/outbound/correlation выводить по значимому изменению или в явно включённом подробном режиме. Только три частых типа уже занимают 29% файла.
3. Оставить один полный XML-вывод каждой stanza, устранить повторный OMEMO XML. Текущий полный XML-контракт сохранить.
4. Отдельными регрессиями исправить layout ячеек, начальное group snapshot/patch и старые архивные invites. Scroll observers проверить с call stack.

## Проверка и границы

Это расследование: выполнены полный подсчёт вложения, сравнение повторного XML, поиск emitters и git blame, независимая проверка источников. Production-код и настройки не изменены. Сборка, XCTest и запуск на устройстве не выполнялись; исправления и измерение производительности не заявляются. Raw capture в Git не добавлен.
