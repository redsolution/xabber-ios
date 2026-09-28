# План закрытия оставшихся пробелов локализации UI

- Снимок: 2026-09-21
- Репозиторий: `xabber_ios_core`
- Базовый commit: `eb7005e6`
- Статус: готово к поэтапной реализации
- Владельцы: `xabber-lead`, `xabber-ui`
- Смежные владельцы: `xabber-business`, `xabber-xmpp`, `xabber-push`, `xabber-tests`

## Цель

Найти и закрыть весь текст, который может появиться в интерфейсе app или
push-extension, но сейчас не проходит через единое локализационное ядро либо
форматируется не в выбранной in-app locale.

Этот документ является планом реализации, а не изменением поведения. В рамках
текущего аудита Swift-код, String Catalog, project resources и тесты не
изменялись; Simulator не запускался.

## Что считать пробелом локализации

В scope входят:

- заголовки, подписи, footer/header, placeholder и сообщения;
- alert, toast, system-owned sheets с app-supplied текстом;
- `accessibilityLabel`, `accessibilityHint` и `accessibilityValue`;
- app-owned fallback для имени файла, статуса, ошибки и пустого состояния;
- закрытые значения enum/API, если они отображаются пользователю;
- даты, время, числа, проценты, размеры и длительности, если они используют
  системную locale вместо `LocalizationContext.locale`;
- грамматическая композиция, которую сейчас нельзя переставить для RTL или
  другого языка;
- текст, который приходит из XMPP/business/storage и затем отображается без
  типизированного presentation boundary.

Не переводятся:

- `accessibilityIdentifier`;
- JID, домены, URL, имена файлов и пользовательский текст;
- SF Symbols, asset names, MIME/UTType, Realm predicates и XML tokens;
- диагностические строки, логи и assertion messages;
- стабильные wire/persistence identifiers;
- свободный серверный текст, если это пользовательский контент или сервер
  явно прислал локализованную версию для выбранного языка.

## Исходная точка аудита

Статически просмотрены production source roots app и push-extension:

| Область | Swift-файлы | Строки |
|---|---:|---:|
| `xabber/controllers` | 550 | 210 707 |
| `xabber/common` | 47 | 25 531 |
| `xabber/models` | 9 | 10 071 |
| `xabber/xmpp` | 116 | 62 829 |
| `xabber-push-extension` | 5 | 1 688 |
| Все `xabber` + push source roots | 792 | 324 050 |

Также проверены четыре storyboard/XIB-ресурса, обе поверхности локализации
ресурсов, каталог, manifest/config и ранее зафиксированные exclusion-файлы.

Текущий воспроизводимый manifest сообщает:

| Метрика | Значение |
|---|---:|
| active keys | 1 809 |
| active keys без English | 0 |
| catalog keys | 3 331 |
| catalog-only keys | 1 522 |
| unresolved dynamic calls | 0 |
| direct lookup bypasses | 0 |
| hard-coded candidates | 0 |
| Interface Builder strings | 60 |
| Info.plist strings | 10 |

`hard-coded candidates = 0` не означает отсутствия пробелов. Текущий scanner
уверенно проверяет прямые UI sinks, но не отслеживает следующие цепочки:

- literal -> dictionary/model/enum `rawValue` -> UI;
- `error.localizedDescription` или `String(describing:)` -> localized wrapper;
- XMPP `<text>` -> callback -> label/alert;
- literal fallback через `??`;
- persisted body/status -> renderer;
- ручную склейку уже локализованных фрагментов;
- создание `DateFormatter`/`NumberFormatter` вне localization runtime;
- remote/config strings, которые считаются готовым UI-текстом.

Поэтому число `0` сохраняется только как baseline старого правила. Перед
миграцией нужно расширить сам контракт аудита.

Отдельный formatter-аудит дал измеримый baseline:

- 26 пользовательских `DateFormatter()` и ещё 3 пользовательских
  `DateFormatter.localizedString`, обходящих выбранную in-app locale;
- 14 formatter callsites являются корректным parsing/wire/diagnostic scope;
- 4 formatter callsites не имеют живых callers;
- 1 пользовательский `DateComponentsFormatter`;
- 2 прямых пользовательских `NumberFormatter`;
- 4 прямых пользовательских `ByteCountFormatter`;
- 10 `String(format:)` для media duration в 6 функциях;
- 16 raw `0 KiB` defaults в трёх cloud-storage flows;
- 6 ручных percent presentations.

## Архитектурные правила миграции

### 1. Локализация выполняется на presentation boundary

- Domain/XMPP/storage передают enum, code, numeric value или semantic state.
- Controller/presenter превращает semantic state в `L10n.text`,
  `L10n.format` или `L10n.plural`.
- Локализованный текст не записывается в Realm, XMPP `<body>`, payload или
  другой долговечный/wire формат: иначе язык отправителя или прежний язык
  приложения станет частью данных.

### 2. Серверные ошибки не являются готовым переводом приложения

- Из `<text xml:lang>` разрешено показывать только значение, язык которого
  соответствует effective locale, затем English.
- XMPP condition/code сначала маппится на закрытый локальный enum.
- Если подходящего server text и известного condition нет, показывается
  локализованная action-specific generic error.
- Не допускаются `first?.stringValue`, `localizedDescription` и
  `String(describing: error)` как пользовательский fallback.
- Оригинальный текст ошибки остаётся в логе.

### 3. Идентификаторы

- Новый формат: `area__screen_or_flow__semantic_role`.
- Существующий key переиспользуется только при полном совпадении смысла, а не
  только English-строки.
- Закрытый enum хранит стабильный raw value и имеет вычисляемое localized
  display value; English не должен быть raw value.
- Full-sentence format key предпочтительнее склейки фрагментов.
- Все placeholders позиционные: `%1$@`, `%2$@`, `%1$lld`.
- Count идёт через native plural String Catalog; отдельно локализовать `one`
  и `many` callsite-ключами нельзя.

### 4. Шесть языков и source English

Каждый новый активный key сразу получает:

- канонический English;
- `ru`, `fr`, `es`, `ar`, `zh-Hans`;
- translator comment с экраном, смыслом и описанием аргументов;
- одинаковую placeholder signature во всех локалях;
- необходимые CLDR plural categories с обязательным `other`.

Имена вымышленных preview-персонажей также получают ID, хотя значения обычно
будут одинаковыми во всех языках. Это делает fixture явным, доступным для
white-label замены и исключает «невидимую» категорию UI-текста.

### 5. Форматирование

- Date/number/percent formatters создаются из immutable
  `LocalizationContext` snapshot.
- Process-static formatter обязан быть revision-aware либо удаляется.
- Парсеры wire/ISO/price могут оставаться POSIX; вывод пользователю — никогда.
- Для byte count нужен string API на `ByteCountFormatStyle` с
  `context.locale`: `ByteCountFormatter` не имеет свойства `locale`, поэтому
  текущая factory-обёртка не гарантирует выбранный in-app язык.
- `ListFormatter` и `RelativeDateTimeFormatter` уже используются через ядро;
  новых обходов для них не найдено.

## Приоритеты

| Приоритет | Значение |
|---|---|
| P0 | Прямой English/app-owned текст реально виден сейчас |
| P1 | Динамический error/server/storage/config text может попасть в UI |
| P2 | Текст переведён частично, но нарушены plural/locale/RTL/VoiceOver |
| R | Target-resident, но путь мёртвый/неподтверждённый; сначала удалить или доказать reachability |

## Реестр P0: прямые активные строки

### Chats, groupchats, media и push

| Callsite | Текущий текст/поведение | Решение | ID/API |
|---|---|---|---|
| `GroupchatBlockAddViewController.swift:208-211` | `Block a specific XMPP address or domain...` | Переиспользовать существующий key; сейчас у него только English, заполнить остальные пять локалей | `groupchat_dialog_block__text`, `text` |
| `GroupchatSettingsNewbiesPermissionsViewController.swift:530-533` | `These temporary permissions are sent...` | Переиспользовать полностью переведённый смысловой key | `groupchat_settings_permissions__table_section_title__new_member_permissions_replace_the_full_temporary_permission_set`, `text` |
| `GroupchatSettingsPromoteAdminViewController.swift:569-572` | `Personal permissions are a partial update...` | Новый footer key | `groupchat_settings__administrators__partial_update_footer`, `text` |
| `CreateNewGroupViewController.swift:83-85` | `Public`, `Local`, `Open` лежат в UI model как raw English | Raw values оставить техническими, labels сделать вычисляемыми; повторный выбор языка должен обновлять их | `groupchat_status_public`, `groupchat_index_type_local`, `groupchat_membership_type_open`, `text` |
| `AccountInfoViewController.swift:217` | Initial status `Offline` | Переиспользовать key до первой model update | `account_state_offline`, `text` |
| `DevicesListViewController+UITableViewDatasource.swift:163` | Device fallback `Undefined` | Переиспользовать существующий key | `devices_list__description__undefined`, `text` |
| `QuotaInfoCell.swift:38-39` | `Unlimited`; `used + " of " + quota` | Локализовать unlimited и весь порядок аргументов | `simple__text__unlimited`, `text`; `cloud_storage__quota__usage_of_limit_format`, `format("%1$@ of %2$@")` |
| `AccountInfoViewController.swift:391-400` | `gallery · used of quota` собирается фрагментами | Два full-format ключа для plan/updating и usage; переводчик управляет разделителем и порядком | `account_info__cloud_storage__gallery_detail_format`, `format("%1$@ · %2$@")`; `account_info__cloud_storage__gallery_usage_format`, `format("%1$@ · %2$@ of %3$@")` |
| `ChatViewController+Dataset.swift:6857` | `timeString + " (edited)"` | Не вставлять отдельный token после строки; дать переводчику полный шаблон | `chat_screen__message__time_edited_format`, `format("%1$@ (edited)")` |
| `GroupchatContactInfoViewController.swift:402-418` | raw English в `dateFormat`, ручные minutes | Форматировать date/time отдельно; minutes — native plural | `groupchat_member__last_seen_minutes_ago`, `plural`; `groupchat_member__last_seen_at_format`, `format`; `groupchat_member__last_seen_on_format`, `format` |
| `ChatAttachmentPreviewViewer.swift:1250-1252` | `1 byte` / `N bytes` | По умолчанию locale-aware byte string; если UX требует exact bytes — native plural | `L10n.byteCountString(...)`; optional `chat_attachment__preview__bytes_count`, `plural` |
| `ChatViewController+Dataset.swift:448-450` | filename fallback `file` | Переиспользовать существующий chat attachment fallback | `chat__attachment__fallback_file`, `text` |
| `FilesGalleryForChatViewController.swift:85-88` | filename fallback `File` | Тот же смысловой fallback, не отдельный casing key | `chat__attachment__fallback_file`, `text` |
| `RichNotificationPresentation.swift:167` | unknown sender `Someone` | Переиспользовать существующий push key | `push_invitation_sender_unknown`, `text` |
| `PushNotificationRouting.swift:565-567` | duration `%d:%02ds` | Общий `MediaDurationFormatter`; убрать English suffix `s` из clock notation | без catalog key |

### Settings, Appearance и onboarding

| Callsite | Текущий текст/поведение | Решение | ID/API |
|---|---|---|---|
| `InterfaceSettingsViewController.swift:1671` | raw `Premium` в preview | Переиспользовать существующий key | `settings__title__premium`, `text` |
| `InterfaceSettingsViewController.swift:2905` | `Radius: \(value)` | Locale-aware number argument и полный шаблон | `appearance__bubbles__radius_value_format`, `format("Radius: %1$@")` |
| `InterfaceSettingsViewController.swift:4793-4796,4821` | `Background`, `Accent`, `Messages` являются enum raw values и titles | Stable raw values + localized computed title | `appearance__theme_editor__tab_background`, `...__tab_accent`, `...__tab_messages`, `text` |
| `InterfaceSettingsViewController.swift:1199,1377,3640-3646,4082,4332,4460-4466` | Preview names/titles | Один централизованный fixture provider; ID для каждого display name | См. key ledger ниже |
| `InterfaceSettingsViewController.swift:1671,3640-3646,3754,4460-4466,4545` | Fixed `23:20`, `13:02`, ... | Хранить deterministic `Date`, форматировать `.short` через context; строковых ID не создавать | formatter factory |
| `InterfaceSettingsViewController.swift:4548` | VoiceOver через `name + message + time` | Full accessibility format; time локализовать | `appearance__chat_list_preview__accessibility_label_format`, `format("%1$@, %2$@, %3$@")` |
| `SimpleTableViewController.swift:70` | `+ N` | Locale-aware integer и format key | `settings__passcode__displayed_attempt_offset_format`, `format("+ %1$@")` |
| `AccountCirclesViewController.swift:1172` | `displayName + JID` | Full accessibility format; JID изолировать bidi marks | `settings_circles__member_accessibility_label_format`, `format("%1$@, %2$@")` |
| `ResourceStorageItem.swift:156-160` | raw `Offline` в `displayedStatus` | Переиспользовать существующий key на presentation boundary | `groupchat_status_offline`, `text` |
| `Account.swift:3480` | Initial `statusMessage = "Offline"` | Initial state должен быть semantic/offline либо локализованным при bootstrap | `account_state_offline`, `text` |
| `DevicePrivacyViewController.swift:83` | model + comma + `iOS` + version собраны вручную | Full localized description; model/version — аргументы | `device_privacy__device_description_format`, `format("%1$@, %2$@ %3$@")` |
| `OnboardingViewController.swift:195`; `common_config.plist:68` | Config literal `Open source XMPP client` | Config хранит localization key или six-locale dictionary; default key в каталоге | `onboarding__subtitle`, `text` |

### Preview fixture key ledger

| English | Новый ID | Комментарий переводчику |
|---|---|---|
| Alicia | `appearance__preview_fixture__alicia_name` | First name in appearance message preview |
| Alicia Torreaux | `appearance__preview_fixture__alicia_torreaux_name` | Contact name in appearance previews |
| Roberto | `appearance__preview_fixture__roberto_name` | Contact name in appearance preview |
| Veronica | `appearance__preview_fixture__veronica_name` | Contact name in appearance preview |
| Campus Public Chat | `appearance__preview_fixture__campus_public_chat_name` | Example public group name |
| Animal Videos | `appearance__preview_fixture__animal_videos_name` | Example channel name |
| Little Sister | `appearance__preview_fixture__little_sister_name` | Example incognito chat name |
| Jennie Alpha | `appearance__preview_fixture__jennie_alpha_name` | Example contact and group-message author |
| Bob Harris | `appearance__preview_fixture__bob_harris_name` | Example reply author |

Имена собственные могут остаться без языкового изменения, но описательные
названия `Campus Public Chat`, `Animal Videos`, `Little Sister` должны быть
переведены. Дублирующиеся fixture arrays в одном controller нужно свести к
одному источнику.

## Реестр P1: динамический текст и ошибки

### YubiKey NFC system sheet

`SignatureManager.swift` передаёт English напрямую в
`NFCISO7816TagReaderSession.stopWithErrorMessage`. Это пользовательский UI,
несмотря на то что лист рисует система.

| Callsite | English | Новый ID/API |
|---|---|---|
| `431,438,445,483,492,505,529` | Connection error. Please try again | `yubikey__nfc__connection_error`, `text` |
| `456` | Invalid certificate | `yubikey__nfc__invalid_certificate`, `text` |
| `469` | Unexpected error | `yubikey__nfc__unexpected_error`, `text` |
| `514` without JID | Incorrect YubiKey. Please use the key issued for your account. | `yubikey__nfc__incorrect_key`, `text` |
| `514` with JID | Incorrect YubiKey. Please use the key issued for %1$@. | `yubikey__nfc__incorrect_key_for_account`, `format` |
| `524` | Account successfully verified | `yubikey__nfc__account_verified`, `text` |

JID в formatted варианте должен получить bidi isolation для Arabic.

### Appearance errors

`AppearanceStoreError` и wallpaper errors сейчас достигают alert через
`localizedDescription`. Добавить `AppearanceErrorPresentation`, который
маппит semantic error на локализованное сообщение, а underlying error оставляет
для логов.

| Semantic error | Новый ID |
|---|---|
| `emptyThemeName` | `appearance__error__empty_theme_name` |
| `duplicateThemeName` | `appearance__error__duplicate_theme_name` |
| `themeNotFound` | `appearance__error__theme_not_found` |
| `builtInThemeImmutable` | `appearance__error__built_in_theme_immutable` |
| `encodingFailed` | `appearance__error__encoding_failed` |
| invalid wallpaper image | `appearance__wallpaper__error__invalid_image` |
| wallpaper encoding failed | `appearance__wallpaper__error__encoding_failed` |

Активные sinks: `InterfaceSettingsViewController.swift:254,376,439,2011,3970,
4785,5001,5370`. Transport/upload description не показывать; использовать
существующую generic upload failure copy, подробность логировать.

### Circles

`AccountCirclesViewController.swift:101,115,447,465,514,816` показывает
`localizedDescription` или `String(describing:)`. Ввести единый
`RosterCircleErrorPresentation`:

| Semantic state | ID |
|---|---|
| storage unavailable | `settings_circles_error_storage` |
| no connection | `settings_circles_error_connection` |
| timeout | `settings_circles_error_timeout` |
| server rejected mutation | `settings_circles_error_server_rejected` |
| unknown | `settings_circles_error_unknown` |

Существующие validation keys для empty/duplicate/no members/not found
сохранить. `RosterCircleMutationError.server(String)` должен хранить technical
condition/server text отдельно от пользовательской presentation.

### Sign-in, registration, password и account deletion

| Callsite | Проблема | Решение |
|---|---|---|
| `SignInCreditionalsViewController.swift:695-700` | protocol token превращается в English заменой `-/_` на пробел | `SignInFailurePresentation`: known conditions -> keys; unknown -> `signin__error__server_rejected` |
| `SignUpSelectPasswordViewController.swift:164-167`; `XMPPRegisterManager.swift:276-287` | arbitrary server text сразу становится subtitle | Выбрать matching `xml:lang`, затем known condition, затем `registration__error__request_rejected` |
| `AccountStreamDelegate.swift:116`; `AccountConnectBehaviorExtension.swift:138,147,165,320-404` | raw status/error text попадает в account state | Semantic connection state; localized display вычисляется в UI |
| `XMPPAuthenticationFailure.swift:319-325,371-376,395-405` | arbitrary SASL `<text>` переносится в failure/status/revocation UI | Сохранить condition + diagnostic server text; отображать через typed mapper |
| `XMPPChangePasswordManager.swift:269-284` | arbitrary first `<text>` либо `Unknown error` | Matching locale/English, затем `change_password__error__request_rejected` |
| `XMPPAccountDeleteManager.swift:259-274` | то же | Matching locale/English, затем `account_delete__error__request_rejected` |

Known sign-in/registration condition keys добавляются только после
автоматически зафиксированного списка реально emitted error codes. Не создавать
key из humanized runtime token.

Минимальный общий ledger typed connection errors:

| Semantic state | Новый ID | Canonical English |
|---|---|---|
| authentication failed | `account__connection_error__authentication_failed` | Authentication failed. Please try again. |
| temporarily unavailable | `account__connection_error__temporarily_unavailable` | Authentication is temporarily unavailable. Try again. |
| server rejected | `account__connection_error__server_rejected` | The server rejected the connection. |
| unknown/connectivity | `account__connection_error__unknown` | Couldn’t connect to the server. |
| registration rejected | `registration__error__request_rejected` | The server rejected the registration request. |
| password request rejected | `change_password__error__request_rejected` | Couldn’t change the password. |
| account deletion rejected | `account_delete__error__request_rejected` | Couldn’t delete the account. |

Если существующий active key имеет строго тот же смысл, перед добавлением нового
ID переиспользовать его и зафиксировать alias decision в manifest.

### Groupchat errors

Следующие controllers оборачивают raw `error.localizedDescription` в уже
локализованное `Error: %@`, но аргумент остаётся нелокализованным:

- `GroupchatSettingsViewControllerT.swift:744,997`;
- `GroupchatSettingsPromoteAdminViewController.swift:404,494`;
- `GroupchatSettingsNewbiesPermissionsViewController.swift:382,456`;
- `GroupchatSettingsPermissionsViewController.swift:402,476`;
- `GroupchatSettingsMembershipViewController.swift:144`.

Создать `GroupchatErrorPresentation` для connection, timeout, forbidden,
conflict, item-not-found, server-rejected и unknown. Существующие screen-specific
wrapper keys сохранить; в `%@` передавать локализованный detail.

Первый implementation slice должен отказаться от generic `Error: %@` в пользу
action-specific full copy:

| Действие | Новый ID | Canonical English |
|---|---|---|
| save base group settings | `group_settings__error__save` | Couldn’t save group settings. |
| delete group | `group_settings__error__delete` | Couldn’t delete the group. |
| update administrators | `group_settings__administrators__save_error` | Couldn’t update administrators. |
| reset administrator permissions | `group_settings__administrators__reset_error` | Couldn’t reset administrator permissions. |
| update new-member permissions | `group_settings__new_members__save_error` | Couldn’t update new-member permissions. |
| reset new-member permissions | `group_settings__new_members__reset_error` | Couldn’t reset new-member permissions. |
| update permissions | `group_settings__permissions__save_error` | Couldn’t update permissions. |
| reset permissions | `group_settings__permissions__reset_error` | Couldn’t reset permissions. |
| update membership type | `group_settings__membership__update_error` | Couldn’t update the group type. |

`GroupchatContactInfoViewController.swift:241` не должен показывать
`partial.failedStage.rawValue`. Для первого этапа заменить на новый generic
`groupchat__moderation__partial_failure`; если product требует stage, добавить
закрытый mapping `kick`, `block`, `role`, а не форматировать raw value.

### Message deletion

`MessageDeleteManager.swift:374-382,394` позволяет произвольному server `<text>`
заменить mapped condition, затем показывает/сохраняет его. Активный toast —
`ChatViewController+SelectionPanel.swift:373-378`.

- UI получает typed `MessageDeletionIssue`, а не строку.
- Unknown/server-rejected показывает
  `chat__message_delete__failed = "Couldn’t delete the message."`.
- Server text разрешён только при matching language contract; в
  `messageError` сохраняется technical condition, не локализованная copy.

### Premium remote copy

| Callsite | Источник | Контракт |
|---|---|---|
| `PremiumSubscribtionViewController.swift:289,981` | `APIProductPrice.name` | API возвращает stable period code; app маппит `monthly/yearly` на `premium__plan__monthly/yearly`; unknown -> `premium__plan__unknown` |
| `SubscribtionsManager.swift:1133` | `period.capitalized` | Удалить presentation из business fallback; хранить stable period |
| `PremiumSubscribtionViewController.swift:1300-1311` | `APIProduct.includes` | Предпочтительно stable feature codes -> catalog keys; альтернативно API обязан вернуть locale-tagged copy для effective language |
| `PremiumSubscribtionViewController.swift:1567` | raw product ID fallback | `premium__plan__unknown`, не product ID |

До реализации этого batch нужно снять один production/example API payload и
зафиксировать полный bounded список plan/feature codes. Это единственный пункт,
где конкретные feature IDs нельзя честно придумать по текущему client code.

### OMEMO/decryption

`OmemoManager.swift:980,1008,1031,1073,1103,1131,1156` вставляет
`"Failed to decrypt"` в message body. Такой текст затем хранится/передаётся и
показывается как контент сообщения.

Порядок миграции:

1. Тестом разделить настоящую failure от успешного attachment-only decrypt с
   `nil` body.
2. Хранить стабильный semantic failure marker/state, не локализованный body.
3. На message rendering boundary показывать
   `chat__message__decryption_failed = "Unable to decrypt this message."`.
4. Начальные переводы механически взять из полностью переведённого
   `otr_not_decrypted_message` без изменения смысла.
5. Legacy записи с literal `Failed to decrypt` распознавать как старый marker,
   но не переписывать историю массово.

### Push и persisted diagnostics

- `RichNotificationPresentation` требует только уже указанного unknown sender;
  остальные raw reason branches недостижимы после payload validation и должны
  быть защищены тестом, а не новыми переводами.
- `VoiceMessagePlaybackCoordinator.failed(error:)` сейчас не выводит error;
  оставить диагностическим и добавить guard-test, чтобы raw error не попал в
  label в будущем.
- Sensitive media analysis сохраняет diagnostic error, но найденного UI sink
  нет; оставить в review-категории.
- `MessageStorageItem.createLegacyBody` формирует canonical/wire fallback для
  старых клиентов; его нельзя локализовать языком отправителя.

## Реестр P2: plural, locale, RTL и VoiceOver

### Plural migrations

| Callsite/семейство | Изменение |
|---|---|
| `ChatAttachmentPreviewViewer.swift:1155-1158`; key в `ChatAttachmentSourceBar.swift:36,132` | `chat_attachment_preview_duration_seconds` сделать native plural и вызывать `L10n.plural` |
| `ChatAttachmentPreviewViewer.swift:373-380` | one/many preview keys -> один native plural |
| `ChatAttachmentStatusFeedback.swift:113-128` | one/many -> native plural |
| `ChatGroupProjectionAdapter.swift:75-98` | Сохранить semantic zero; positive count -> native plural |
| `ChatViewController+LowPrioritySubscribtions.swift:163-165` | forwarded message count -> native plural |
| `AccountCirclesViewController.swift:158-160,231-233,798-800,1127-1129` | String count arguments -> native plurals и locale-aware digits |
| `GroupchatContactInfoViewController.swift:408-413` | minutes ago -> native plural |

### Даты и время

Создать один `CompactDateTimePresentation` поверх `L10n.formatters` и
использовать его вместо дублирующихся fixed patterns.

| Surface | Callsite | Требуемое изменение |
|---|---|---|
| AKE list/details | `VerifyListTableViewCell.swift:121-134`; `VerificationViewController.swift:350-353` | Context date/time styles, без fixed English patterns |
| Notifications | `NotificationsListViewController+ItemCell.swift:18-20,99` | Убрать process-static formatter; revision-aware `jmmss` |
| Chat message time | `controllers/chats/chat/ChatViewController.swift:3951-3954`; `ChatViewController+Datasource.swift:153` | Factory snapshot controller context |
| New chat dataset | `ChatViewController+Dataset.swift:1595-1601,5448-5460,6676,6722,6852,8789` | Один immutable formatter snapshot для mapping job |
| Search | `SearchResultsViewController+MessageCell.swift:203-210` | Shared compact-date policy |
| Calls | `LastCallsViewController+ItemCell.swift:30-50,176-187` | Убрать четыре process-static formatters; revision-aware cache |
| Devices | `DevicesListViewController+ExpandItemCell.swift:109-124`; `DeviceDetailViewController.swift:385-427`; `ContactDeviceDetailViewController.swift:73-78` | Shared styles `.medium/.short` |
| Resource/group member | `ResourceInfoViewController.swift:98-108`; `GroupchatMembersListViewController.swift:45-49` | Не использовать system `localizedString`; брать context |
| Gallery | `PhotoGallery.swift:95-101` | Убрать `dd.MM.YYYY` (`YYYY` — week-year bug) и `H:mm` |
| Attachment month | `ChatAttachmentGalleryGrid.swift:135-140` | Не использовать POSIX+UTC для видимого `MMM y` |
| Voice gallery | `VoiceGalleryForChatViewController.swift:173-177` | Context `.short/.short` |
| Scheduled messages | `ChatScheduledMessageModels.swift:184-198`; `ScheduledMessagesViewController.swift:197-199,253` | Production default из current context; revision-aware lifecycle |
| Copy selection | `ChatViewController+SelectionPanel.swift:116-136` | Context snapshot и localized templates |
| Abuse metadata | `AbuseReportViewController.swift:234` | Context `.medium/.short` |
| Birthday | `AccountEditViewController+VcardEditedItem.swift:27-32,120,129` | Разделить POSIX `yyyy-MM-dd` codec и localized presentation |
| Yubi expiry | `controllers/privacy/YubikeySetupViewController.swift:262-264` | Context-aware duration components formatter |

`MessageKitDateFormatter.swift:23-58` и неиспользуемый
`ChatViewController.sectionsDateFormatter` удалить после доказательства
отсутствия callers; ID для dead code не создавать.

### Числа, размеры и проценты

| Surface | Callsite | Требуемое изменение |
|---|---|---|
| Premium fallback price | `PremiumSubscribtionViewController.swift:1845-1855` | POSIX только parse; display через context number/currency formatter |
| Server subscription price | `SubscribtionsManager.swift:1301-1318` | Хранить Decimal+currency, не готовую POSIX display string |
| Quota sizes | `AccountQuotaStorageItem.swift:91-101` | Убрать ручные decimal/unit replacements; byte API |
| Message sizes | `MessageType.swift:212-215,293-295`; `MessageReferenceStorageItem.swift:633-643` | Тот же byte API |
| Raw zero sizes | `CloudStorageGalleryViewController.swift:639,672`; `CloudStorageViewController.swift:467-472,578-583`; `CloudStorageDeleteViewController+UICollectionViewDataSource.swift:68,91` | Форматировать numeric zero, не хранить `0 KiB` |
| Upload progress | `InlineFilesGridView.swift:166-167`; `VoiceGalleryForChatViewController.swift:154` | Percent number formatter |
| Cleanup progress | `CloudStorageViewController+TableViewDelegate.swift:57`; `CloudStorageDeleteViewController+UICollectionViewDataSource.swift:113`; `FileDeletionConfirmation.swift:291` | Передавать локализованный percent; убрать ручной `%` |
| Premium savings | `PremiumSubscribtionViewController.swift:1871-1874` | Percent formatter вместо `String(percent)` |
| Storage plan count | `XabberUploadManager.swift:187-189` | Existing IDs, locale-aware numeric argument |
| Numeric VoiceOver | `InterfaceSettingsViewController.swift:3054,3061,3742,4533`; `SettingsViewController+UITableViewDataSource.swift:127` | Number formatter перед передачей в label/value |

### Duration formatter

Свести clock durations в один `MediaDurationFormatter`, не создавая catalog
keys для нейтральной записи `m:ss`/`h:mm:ss`:

- `TimeIntervalExtension.swift:25-31`;
- `ChatAttachmentMediaPreparation.swift:232-241`;
- `ChatAttachmentFileSource.swift:289-298`;
- `ChatAttachmentGalleryGrid.swift:340-359`;
- `MediaGalleryFullscreenFoundation.swift:373-384`;
- `MessageReferenceStorageItem.swift:211-218`;
- `PushNotificationRouting.swift:565-567`.

`prettyMinuteFormatedString` в `TimeIntervalExtension.swift:34-46`, видимый в
`ChatViewController+Datasource.swift:168` и
`ChatViewController+Dataset.swift:6854`, заменить существующими plurals:

- `chat__self_destruct_timer__seconds_count`;
- `chat__self_destruct_timer__minutes_count`.

### Full-string accessibility/RTL composition

Помимо двух новых accessibility keys выше, заменить ручные joins на полные
локализуемые шаблоны или `ListFormatter`:

- `ChatAttachmentPreviewViewer.swift:1130,1175`;
- `ChatAttachmentFileSource.swift:859-875`;
- `FilesGalleryForChatViewController.swift:111-113`;
- `VoiceGalleryForChatViewController.swift:187-189`;
- `DeviceInfoTableCell.swift:297`;
- `DeviceDetailViewController.swift:175-178`;
- `FilesMediaCollectionCell.swift:178-182`.

Для JID/domain/URL/filename в Arabic применять Unicode bidi isolation на
аргументе, не добавлять directional marks в перевод.

## Review-категория: не создавать ключи вслепую

| Источник | Решение |
|---|---|
| `ChatFilesViewController.swift:56-60,114-115` (`Images/Videos/Files/Voice`) | Файл входит в target, но production caller/storyboard reference не найден. Если экран сохраняется — stable enum + существующие `images/videos/files/voice`; иначе удалить dead screen |
| `ModernXabberInputView.swift:3177` hidden sample title/message | Panel стартует hidden и получает реальные данные перед показом; удалить placeholder или доказать invariant тестом, не переводить sample |
| `RandomTitleManager.swift:205,211` fallback `Ready to rock?` | Сейчас недостижим, потому что шесть locale corpus непусты; заменить fallback на `motivating_oneliner_fallback` либо брать первый элемент локализованного corpus |
| `NotifyManager.swift:1040-1049` `showSimpleNotify` date suffix | Живых callers не найдено; удалить helper либо оставить exact dormant exclusion. Если вернётся caller — форматировать через context |
| `SettingsViewController+UITableViewDataSource.swift` `Expired`/`Trial` | Rows закомментированы; удалить ветки либо оставить fail-closed exclusion |
| `controllers/privacy/YubikeySetupViewController.swift` delete branch | Dead branch; удалить после reachability test, ID не создавать |
| `DDCell.xib` `Archived` | XIB не входит в app target; не добавлять key, отдельно удалить/архивировать resource |
| Onboarding logo asset | Может содержать текст; визуально проверить source asset/white-label variants. Bitmap-текст каталогом не исправляется |
| Typography specimen `A` | Не обычная строка. В отдельном design task решить script-aware specimen (`A`/`ع`/`字`), а не translation key |

## План реализации

### Этап 0 — усилить воспроизводимый аудит

Сначала RED tests, затем scanner changes.

1. Добавить fixture-тесты для:
   - enum/dictionary/model literals, уходящих в UI;
   - `?? "fallback"` в presentation producer;
   - `localizedDescription`/`String(describing:)` в alert/toast/label;
   - XMPP `<text>` и protocol token -> UI;
   - custom system sheet `stopWithErrorMessage`;
   - raw `DateFormatter`, `NumberFormatter`, `ByteCountFormatter`, percent/unit
     composition в presentation sources;
   - config/API text -> UI;
   - persisted app-owned fallback -> renderer.
2. Расширить manifest категориями:
   - `dynamicPresentationCandidates`;
   - `localeFormattingCandidates`;
   - `catalogCompositionCandidates`;
   - `reviewCandidates` с fail-closed reason/path/symbol.
3. Пересмотреть 210 текущих exact exclusions: proper preview names больше не
   исключать; wire/asset/log exclusions сохранить.
4. Baseline считается закрытым только при `0 unclassified` во всех четырёх
   категориях, а не только `hardcodedCandidates`.

### Этап 1 — прямые P0 literals

1. Chats/groupchat direct strings и existing-key reuse.
2. Appearance fixture registry, tabs, radius и preview dates.
3. Initial status/file/device fallbacks.
4. Onboarding subtitle config contract.
5. После каждого slice: catalog values для шести языков, translator comments,
   manifest regeneration и CSV regeneration.

### Этап 2 — typed error presentation

1. `AppearanceErrorPresentation`.
2. `RosterCircleErrorPresentation`.
3. Общий XMPP language-aware error extractor + action-specific presenters для
   sign-in/register/change-password/account-delete.
4. `GroupchatErrorPresentation` и generic moderation partial failure.
5. YubiKey NFC app-supplied messages.
6. Unit tests доказывают, что unknown technical text остаётся в логе и не
   попадает в UI.

### Этап 3 — semantic storage/wire boundary

1. OMEMO failure state и legacy compatibility.
2. Account status defaults как semantic state.
3. Premium plan/feature stable code contract.
4. Push duration и unknown sender parity с app.

### Этап 4 — plural и locale formatting

1. Native plural families.
2. Revision-aware shared date/time policies.
3. Locale-aware number/percent/currency output.
4. `ByteCountFormatStyle` string API и миграция прямых/factory callsites.
5. Unified media duration formatter.
6. Удаление доказанного dead formatter code.

### Этап 5 — VoiceOver и RTL

1. Full-sentence accessibility templates.
2. `ListFormatter` для списков.
3. Bidi isolation для технических аргументов.
4. Проверка leading/trailing и semantic content direction на Arabic.

### Этап 6 — перевод и редакторская QA

1. English утверждается как source copy.
2. Перевести новые/изменённые keys на `ru/fr/es/ar/zh-Hans`.
3. Native/product review отдельно для:
   - Arabic/RTL;
   - Simplified Chinese;
   - security/privacy/destructive error copy;
   - premium marketing copy.
4. Обновить `docs/localization/active-translations.csv`.
5. Проверить placeholder signatures, plural categories и отсутствие empty
   target values.

## Предлагаемая разбивка на focused commits

1. `test(localization): detect indirect UI and formatter bypasses`
2. `feat(localization): migrate direct UI copy and preview fixtures`
3. `feat(localization): add typed localized error presentation`
4. `feat(localization): localize semantic message and remote states`
5. `feat(localization): unify locale-aware UI formatting`
6. `feat(localization): complete remaining six-language UI copy`
7. `ci(localization): require zero presentation and formatter gaps`

Каждый commit должен быть green отдельно и не смешивать catalog migration с
несвязанным UI refactor.

## Тестовая матрица реализации

### Python/tooling

- scanner fixtures для каждого нового blind spot;
- deterministic manifest generation;
- stale review/exclusion rejection;
- six-locale non-empty coverage;
- exact placeholder signatures;
- valid CLDR plurals;
- CSV parity.

### XCTest

- direct presentation policies возвращают все шесть переводов;
- server error выбирается по effective language и не берёт arbitrary first
  `<text>`;
- technical error/token никогда не становится UI fallback;
- OMEMO failure отображается на текущем языке и не меняет persisted/wire body;
- date/number/percent/byte output меняется вместе с context revision;
- static caches не сохраняют старый язык;
- Russian/Arabic plural categories и Arabic bidi composition;
- preview fixture timestamps и VoiceOver labels;
- app/push parity для shared keys/formatters.

### Integration/UI

- смена `en -> ar -> ru` без перезапуска на Settings, chat, group settings,
  quota, calls, device details и NFC preparation surface;
- Dynamic Type и VoiceOver labels;
- LTR/RTL order в quota/gallery/error formats;
- config-driven onboarding subtitle;
- no flash of English initial `Offline`/`Undefined`.

Hosted XCTest запускать только на отдельном временном simulator, без ручного
открытия UI, затем удалять только task-owned device/data/result bundles.

## Критерии приёмки

- `0` unclassified direct UI strings.
- `0` unclassified indirect/dynamic presentation strings.
- `0` raw `localizedDescription`, `String(describing: error)` или arbitrary
  server `<text>` на пользовательском UI boundary.
- `0` presentation `DateFormatter`/`NumberFormatter`/`ByteCountFormatter`
  вне разрешённых context-aware wrappers; parser allowlist точный и reasoned.
- `0` ручных English unit suffixes и fragment concatenation, где порядок
  зависит от языка.
- Все активные keys имеют непустые `en`, `ru`, `fr`, `es`, `ar`, `zh-Hans`.
- Все count callsites используют native plural или доказанно locale-neutral
  clock notation.
- Все accessibility labels/hints/values локализованы; identifiers стабильны.
- Wire/persistence/user/server-authored content не локализуется на стороне
  хранения/отправки.
- `localization_manifest.py check`, catalog validators, CSV check, focused
  XCTest, app build и push-extension build проходят.

## Порядок практического старта

Следующий implementation task должен брать только **Этап 0 + первый P0 slice
(groupchat direct strings)**. Это даст новый fail-closed scanner contract и
маленький вертикальный пример до массовой миграции Settings/errors/formatters.
После него можно выполнять остальные этапы независимо по указанным batches.
