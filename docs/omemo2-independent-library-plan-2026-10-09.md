# План реализации самостоятельной библиотеки OMEMO 2

Дата: 2026-10-09. Статус: L01 и L02 выполнены в отдельном package; L03–L07 ещё не выполнены.
Основание: [проверенные зависимости, нормативная база и 70 пунктов требований](omemo2-independent-library-requirements-2026-10-09.md).

## Результат первой версии

Отдельный source SwiftPM package `XabberCryptoSwift` для iOS15+ с универсальным криптографическим API и первым криптографическим профилем, совместимым с OMEMO 2, без SignalProtocolC/ObjC и без импорта состояния предыдущего backend. CocoaPods podspec над теми же sources — дополнительный вариант доставки при необходимости; пользователь допускает pod **или** SPM, не требует оба.

Пользователь утвердил имя и каталог `/Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift`; создан новый Git repository и SwiftPM skeleton. SPM выбран для L01; optional podspec позже.

**Последнее уточнение пользователя:** package не знает XML/XMPP/другого транспорта, адресов, устройств и структуры сообщения приложения. [Neutral API и границы](independent-crypto-library-api-2026-10-09.md) уточняют этот контракт. Xabber — отдельный consumer, а не часть package.

Используем стандартные криптопримитивы Apple, самостоятельно реализуем протокол и состояние OMEMO 2. Полная собственная реализация Ed25519/AES/SHA с нуля не входит в этот план. X3DH и классический Double Ratchet обязательны для wire-совместимости OMEMO 2, хотя библиотека Signal не используется.

## Границы ответственности

| Участок | Владелец |
| --- | --- |
| Типы ключей/bundle/ciphertext, protobuf, X3DH, ratchet, payload AE, candidate state transitions и versioned snapshots | Новый package |
| Ed25519/X25519/SHA/HMAC/HKDF | Apple CryptoKit provider |
| AES256-CBC/PKCS7 | Apple CommonCrypto provider |
| RNG | Apple Security provider |
| Seed→X private и checked Ed public→X public | Самостоятельный проверенный conversion adapter |
| XMPP/XML/PEP, устройства, SCE affixes/provenance, policy доверия, UI | Xabber host adapter |
| Любой persistence backend, сопоставление адресатов с sessions, сериализация операций, commit и app recovery | Внешнее приложение; Xabber adapter — один пример |

Public API содержит только ключи, bundles, crypto sessions, binary messages/bytes, snapshots и state transitions. Нет адресов/JID/SID, device lists, аккаунтов, Signal/Realm/XMPPFramework/UIKit types. `PublicBundle` содержит список public OPKs, `SelectedPeerBundle` — один OPK для establishment. Crypto operations возвращают provisional output и candidate state; host сам проверяет bytes, атомарно сохраняет state/OPK consumption и допускает output к использованию. Core не обещает скрыть уже возвращённые bytes до внешнего commit.

## Последовательность работ

| Этап | Реализация | Критерий завершения |
| --- | --- | --- |
| **L01 — Package/API** | `Package.swift`, library/test targets, собственные key/public-bundle/selected-bundle/session/error types, provider и candidate-transition contracts, fixtures, README и license/provenance metadata. При C conversion — отдельный C target. | Package собирается самостоятельно; structural key/bundle и public contract tests запускаются без app/account/Keychain/XML/network; actual crypto generation/encrypt/decrypt — L02–L04; API не зависит от Signal. |
| **L02 — Primitives/identity** | Native Ed25519 seed, X25519, signing/verification, HMAC/HKDF, AES-CBC, checked RNG, identity conversion и secret lifetime policy. | RFC и независимые positive/negative vectors; Ed seed→X обе стороны дают ожидаемый DH; исходные remote Ed bytes/sign bit сохраняются для signature/AD. |
| **L03 — Wire/X3DH** | Три protobuf codecs, strict bounded parser, exact raw-byte MAC, bundle/SPK verification, обязательный OPK, 4-DH establishment, initial Alice/Bob state и первый authenticated packet. | Independent expected DH/SK/AD/ciphertext/protobuf bytes; malformed bundle/wire/MAC не создаёт usable session и не потребляет OPK. |
| **L04 — Double Ratchet/payload** | DH/chain transitions, Ns/Nr/PN, repeated KEX до authenticated reply, skipped keys/retention, replay, empty controls, payload key32+MAC16 и payload authentication. | Exchange в обе стороны, потеря/reorder/duplicate/old chain/MAX_SKIP, KEX/ACK loss и tampering. Failed auth/provider call не меняет committed state. |
| **L05 — New state/transactions** | Собственный versioned crypto snapshot, restore validation, immutable input и candidate state transitions, authenticated consumed OPK event. External storage/locks/CAS — host. | Snapshot roundtrip/restart, pending KEX/skipped keys, corruption rejection и failed crypto без state mutation. Host adapter отдельно проверяет commit/CAS failures и не использует provisional bytes до сохранения. |
| **L06 — Neutral consumer** | Самостоятельный пример двух участников: generate keys/bundles, new sessions, arbitrary bytes encrypt/decrypt и host-owned state. Без Xabber/XMPP/network code. | Пример подключается как обычный SPM/pod consumer, меняет delivery channel без изменения crypto API; package tests и consumer build проходят. |
| **L07 — Acceptance/release** | Independent crypto peer/vectors, hostile-parser fuzz/native sanitizers, crypto/state review, dependency/symbol audit, README/API examples и versioned release. Transported OMEMO exchange проверяется внешним adapter. Optional podspec — отдельный consumer test. | Fresh compatible crypto sessions, restart/reorder/exchange-reply loss; нет Signal runtime linkage и transport imports; standalone package воспроизводимо подключается к независимому consumer. |

L03/L04 разделены, чтобы сначала доказать корректность первого пакета независимыми bytes, затем проверять сложную state machine. На каждом этапе сначала focused tests, затем implementation, narrow verification и отдельный reviewable commit. Собственная успешная encrypt→decrypt пара не заменяет independent vectors/peer.

## Внешняя интеграция Xabber и переключение с предыдущего backend

Этот раздел — задачи consumer-приложения после готовности package; они не входят в API/core библиотеки. Xabber adapter связывает свои адреса/devices с sessions, генерирует/читает XML, применяет SCE/trust, публикует bundles и хранит state. Его отдельные XCTest/Simulator build и live web exchange подтверждают интеграцию.

- Нет старого Signal v3 reader, X-scalar identity/XEdDSA signer, native snapshot importer и переноса старых sessions/counters/skipped keys.
- Новая identity означает новый fingerprint и peer trust verification. Local cryptographic device/registration policy должна явно завершить прежние объявления, controls и retries; старые ожидающие ciphertexts не отправляются через новые sessions.
- Не удаляем уже расшифрованную локальную историю. Необработанные старые offline/MAM ciphertexts новый backend не расшифровывает — согласованная граница совместимости.
- Ошибка доступа или corruption **нового** protected state не запускает автоматическую генерацию очередной identity.
- Lifecycle задачи N01–N09, выполненные в прежнем app scope, переносим как existing policy/regressions, а не объявляем повторной реализацией всего XMPP слоя.

## Надёжность, которую нужно определить до integration

Package transaction и app/network transaction — разные boundaries. API должен документировать, когда state считается committed, а ciphertext/plaintext допустим к использованию. При разработке внешнего host adapter необходимо определить:

- поведение crash между protected state commit и сохранением полученной истории;
- retry identity и сохранение уже созданного ciphertext;
- partial failure при нескольких recipient devices;
- retirement empty controls и network send failure;
- stale concurrent writer и downgrade/backup restore.

Journal/outbox либо их компактный эквивалент — engineering choice, не новая норма XEP. Если конкретная guarantee не реализована, её нельзя обещать в public API или release acceptance. Сейчас NSE не ведёт OMEMO ratchet; межпроцессные writers добавляются только при отдельном scope.

## Браузерная реализация

Обсуждение JS primitives не означает выбор общего JS ядра или browser deliverable первой версии. Предлагается сначала native iOS package. Web client используется для wire interoperability acceptance; новый самостоятельный web core — отдельный этап при соответствующем запросе.

Для такого этапа кандидаты: native WebCrypto там, где Ed25519/X25519 поддержаны, либо `@noble/curves`/`@noble/hashes` как providers. Их MIT LICENSE проверен по upstream; это сторонние primitives, а own protocol core остаётся отдельным. iOS CryptoKit и JS provider должны проходить общие fixtures и policy validation. JS runtime в iOS не предполагается.

Ссылки: [noble-curves](https://github.com/paulmillr/noble-curves), [MIT LICENSE](https://github.com/paulmillr/noble-curves/blob/main/LICENSE), [Web Crypto](https://www.w3.org/TR/webcrypto-2/#ed25519), [XEP-0384](https://xmpp.org/extensions/xep-0384.html).

## Выполненные этапы

L01 выполнен в отдельном `XabberCryptoSwift`: typed API, structural tests и standalone consumer. [Отчёт L01](xabber-crypto-swift-l01-2026-10-09.md) фиксирует результат. L02 добавляет Apple primitives, публичные identity/agreement key operations и проверяемую Ed-to-X conversion; [отчёт L02](xabber-crypto-swift-l02-2026-10-09.md) фиксирует проверки. Следующий этап — L03: binary codecs, cryptographic bundle validation и X3DH. Existing app backend и зависимости не меняются.
