# OM2-02 — EME исходящей stanza

## Объём

По уточнению пользователя от 2026-10-02 задача ограничена согласованием EME с фактическим шифрованием. Fallback body сохраняется. Новые store hints не добавляются; ранее существовавшие hints остаются. Исторические типы чатов, identity/device/session и процесс доверия не меняются.

## Контракт

`OmemoManager.synchronizeOutgoingEncryptionMetadata` рассматривает direct `encrypted` по localName + namespace URI. Для единственного известного OMEMO ciphertext заменяет direct EME на один элемент `encryption` в `urn:xmpp:eme:0` с `namespace` фактического encrypted и без optional `name`. Префиксы допустимы. Вложенный, чужой или неоднозначный encrypted не позволяет выбрать профиль; такие входы helper не изменяет. Другие схемы шифрования не затрагиваются.

Текущий writer использует OMEMO2 (`urn:xmpp:omemo:2`) для `.omemo`, `.omemo1` и `.axolotl`. Исторический тип conversation не является криптографическим профилем; legacy Signal остаётся reader.

| Путь | EME policy |
| --- | --- |
| Основной content sender / retry | Нормализация после ReliableMessageDelivery hook, до выбора primary/auxiliary stream |
| TrustSharing | Тот же helper на зашифрованном inner message до XEN wrapper; opaque payload/подписи/доверие прежние |
| Payloadless ratchet control | EME OMEMO2; без body/payload; existing store сохраняется |
| Plaintext displayed marker | EME отсутствует; existing store/conversation прежние |
| Обычный plaintext / вложенный forward | Helper не добавляет внешнего утверждения шифрования |

EME — описание схемы, не подтверждение decrypt и не средство шифрования. Маркеры доставки, квитанции и маркеры прочтения в Xabber не шифруются по явному указанию пользователя. Существующий markable hook сохраняется. OM2-03 не переносит chat-markers/receipts в SCE. Сохранение fallback body и текущих hints является явным ограничением этой итерации; задача не заявляет полного соответствия отправки XEP-0420.

XEP-SYNC использует серверную обработку chat markers для display state. Открытый транспорт сохраняется; EME у plaintext displayed удаляется, поскольку его ciphertext отсутствует.

## Основание

[База знаний: XEP-0380](/Users/igor.boldin/projects/xabber/xabber-knowledge/protocols/standard/xep-0380-explicit-message-encryption.md), [XEP-0380](https://xmpp.org/extensions/xep-0380.html), [XEP-0420](https://xmpp.org/extensions/xep-0420.html#sending).

## Проверка

- XCTest написан первым. Канонический RED: 14 тестов, 32 ожидаемые ошибки EME, 0 unexpected; фикстуры исправлены до этого прогона.
- GREEN: **126 тестов / 0 ошибок**. `OMEMO2OutgoingMetadataTests` — 14; `OMEMO2AppIntegrationTests` — 18; `OMEMO2SCEReceiveTests` — 16; `OMEMO2ReceiveRoutingTests` — 25; `XEPTrustProtocolTests` — 8; `MessageManagerQueueSynchronizationTests` — 45.
- Cached `Debug` test action на iPhone 16 Pro / iOS 26.0 собрал приложение и push extension. Build/test errors отсутствуют; отдельный Debug build не выполнялся.
- Новый suite захватывает реальный production sender для трёх conversation kinds × send/retry, проверяет QName, идемпотентность, fallback/hints/IDs/ciphertext, сохранение ratchet state, настоящее decrypt/control и открытый displayed.
- TrustSharing regression: реальный provider ciphertext с trust-shaped payload через production XEN wrapper; private sender/signing/authorization не вызываются новым тестом, его подключение к helper проверено статически. Существующие trust tests проходят.
- Static audit: EME создаётся только в общем helper; main, TrustSharing и control используют его. Последующие hooks EME не меняют. `git diff --check` проходит.

```sh
TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
XABBER_DESTINATION='platform=iOS Simulator,id=91E09D3E-4BBC-4431-9EAF-14D2410E7B98' \
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/OMEMO2OutgoingMetadataTests \
  -only-testing:xabberTests/OMEMO2AppIntegrationTests \
  -only-testing:xabberTests/OMEMO2SCEReceiveTests \
  -only-testing:xabberTests/OMEMO2ReceiveRoutingTests \
  -only-testing:xabberTests/XEPTrustProtocolTests \
  -only-testing:xabberTests/MessageManagerQueueSynchronizationTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```
