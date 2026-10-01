# Профиль OMEMO2 в зависимостях iOS

В локальных SignalProtocolC и SignalProtocolObjC реализован отдельный криптографический профиль [XEP-0384 0.9.1](https://xmpp.org/extensions/xep-0384.html), namespace `urn:xmpp:omemo:2`. Он предоставляет ядро обмена ключами и Double Ratchet для следующего этапа миграции iOS. Текущий OMEMO-код приложения продолжает вызывать прежний Signal API; выбор нового профиля в приложении ещё не выполнен.

Изменены только два подготовленных пакета. Версии CocoaPods 2.3.2 и 1.1.0 сохранены; конкретные локальные реализации закрепляются commits и восстановительными patches в [manifest](../tools/local-dependencies.json). Эти patches предназначены для локальных forks и не означают публикацию новых CocoaPods releases.

## Соответствие протоколу

| Требование | Реализация и проверка |
| --- | --- |
| Wire identity Ed25519 32 байта, остальные public keys X25519 32 байта | `omemo_keys`; XEdDSA с Ed25519-совместимой подписью. RFC8032 и независимый CryptoKit проверяют подписи, включая remote identity со sign bit 1. |
| RFC7748 scalar decoding и защита от недопустимого DH | Импорт ключей и agreement clamp-ят копию scalar; all-zero shared secret отклоняется. Положительный RFC7748 вектор выявил и защищает от ошибки legacy Donna при импорте ключей. |
| Обязательный OPK, проверка signed PreKey | Bundle требует оба ключа, валидную подпись и IDs `1..2^31-1` согласно §5.3.2. Тип `uint32` в protobuf не расширяет семантический диапазон ID. |
| X3DH и инициализация Double Ratchet | Четыре DH, F из 32 байт FF, 32-byte SK, новый Alice DH отдельно от EK; Bob начинает со SPK. Независимый вектор проверяет SK-derived root/chain и первый пакет. |
| HKDF SHA256 | `OMEMO X3DH`, `OMEMO Root Chain`, `OMEMO Message Key Material`; локальная RFC5869 реализация с корректной очисткой при отказе callback. |
| Wire protobuf | Три схемы XEP, raw keys, отсутствие Signal version byte. Проверяются повреждённые/повторные обязательные поля и допустимые unknown fields. MAC проверяется по исходным inner bytes. |
| AES256 CBC PKCS7 и MAC16 | Message key material — key32, authentication key32, IV16. HMAC SHA256 по ordered wire identities AD и исходному inner protobuf, первые 16 байт. Независимые ожидаемые AES/protobuf/MAC bytes. |
| Повторный KEX | Тот же EK и та же сессия при счётчиках `0,1,2`; восстановление продолжает счётчик. `kex=true` сохраняется до аутентифицированного ответа. |
| Ошибки, replay, out of order | Операции работают на копии состояния и фиксируют его после успеха. Ошибка MAC, malformed wire, неверные KEX headers или отказ provider не меняют сессию. Skipped keys ограничены 1000, FIFO. |
| Persistence | Отдельный secret snapshot с magic `OMEMO2S` и version 1; роли, AD, EK, ratchet keys/counters и skipped keys. Legacy Signal records и некорректные инварианты отклоняются. |

## API и ответственность приложения

Публичные C-заголовки: `omemo_keys.h`, `omemo_wire.h`, `omemo_session.h`. Objective-C экспортирует `OMEMO2Context`, модели ключей/bundle/ciphertext и `OMEMO2Session`. Новый context не использует `SignalStorage`.

`encryptData` принимает 48 байт `content key32 || payload MAC16` либо 32 нулевых байта для пустого control/ACK сообщения. Шифрование SCE payload, XML, PEP и маршрутизация ACK остаются на стороне приложения.

Приложение должно выбирать профиль явно, хранить legacy и OMEMO2 состояние раздельно, проверять доверие к peer identity и находить существующую сессию по peer/EK перед обработкой повторного KEX. Повторный вызов начального builder для каждого сообщения снова создал бы сессию даже с правильным ядром.

После успешной операции необходимо атомарно сохранить snapshot до отправки ciphertext или принятия plaintext. При первом входящем KEX сохранение сессии и потребление OPK входят в одну транзакцию. Snapshot содержит секреты: защищённое хранилище и защита от отката — ответственность приложения. Wrapper синхронизирует операции над одним объектом; конкурирующие восстановленные объекты требуют общей сериализации на стороне хранилища.

## Проверка

- CMake собирает три standalone suite: keys, wire, session. Проверки `assert` остаются включёнными в Release. Новая тестовая цель не требует установки Check.
- [reference_vector.py](/Users/igor.boldin/projects/xabber/deps/SignalProtocolC/tests/omemo/reference_vector.py) воспроизводит ожидаемые X3DH/ratchet/AES/protobuf/MAC значения через Python stdlib, RFC7748 ladder и OpenSSL CLI; библиотека не используется для ожидаемых значений.
- [OMEMO2Tests.m](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Testing/SignalProtocolTests/OMEMO2Tests.m) проверяет wrapper, SHA512, bundle, KEX, persistence/rollback и immutable inputs.
- [OMEMO2CryptoKitConformanceTests.swift](../xabberTests/OMEMO2CryptoKitConformanceTests.swift) проверяет X25519 и Ed25519 независимым Apple backend. Дополнительно запускаются прежние `OmemoSessionLifecycleTests`.
- Новый C-код проверен строгим Clang и static analyzer.

Проверено 2026-10-01: CMake `ctest` — 3/3 suite, exit 0. В Debug iOS 26.0 Simulator на Xcode 26.0 — `TEST SUCCEEDED`, 17/17 XCTest: 5 CryptoKit, 7 wrapper и 5 прежних lifecycle. App и push extension собраны; compiler/linker errors отсутствуют. Стабильные Xcode caches сохранены, disposable logs/result bundles удалены после фиксации результата.

```sh
TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1 \
TEST_RUNNER_XABBER_ISOLATED_STORAGE=1 \
XABBER_DESTINATION='platform=iOS Simulator,id=91E09D3E-4BBC-4431-9EAF-14D2410E7B98' \
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/OMEMO2Tests \
  -only-testing:xabberTests/OMEMO2CryptoKitConformanceTests \
  -only-testing:xabberTests/OmemoSessionLifecycleTests CODE_SIGNING_ALLOWED=NO
```

Commits зависимостей: C `7552b1be9685524c6a8a16e228554e879f11f3be`, ObjC `d142b4db2aab57d2686bce7f4c1298ca1a9322b9`. Ветки `codex/ios-local-dependencies`, push не выполнялся.

## Ограничения проверки

Полная UBSan-проверка обнаруживает существующие signed-shift UB в унаследованной Donna/Ed25519 арифметике. Assertions проходят, ошибок ASan не обнаружено; вся библиотека не считается UBSan-clean. Это отдельная задача ревизии базовых примитивов, зафиксированная в проектной памяти.

Parser/signature cap 1 MiB — локальный ресурсный лимит. Ed25519 verifier дополнительно требует canonical encodings/scalars и nonzero prime-subgroup identity/R. Прямой обмен iOS с web или другим внешним клиентом ещё не запускался; тестовые векторы и независимый backend не заменяют такую проверку.
