# План реализации самостоятельной библиотеки OMEMO 2

Дата: 2026-10-09. Статус: предлагаемый execution plan; реализация не начата.
Основание: [проверенные зависимости, нормативная база и 70 пунктов требований](omemo2-independent-library-requirements-2026-10-09.md).

## Результат первой версии

Отдельный source SwiftPM package `XabberOMEMOCore` для iOS15+ с самостоятельным ядром `urn:xmpp:omemo:2`, без SignalProtocolC/ObjC и без импорта состояния предыдущего backend. CocoaPods podspec над теми же sources — дополнительный вариант доставки при необходимости; пользователь допускает pod **или** SPM, не требует оба.

Предлагаемый каталог: `/Users/igor.boldin/projects/xabber/deps/XabberOMEMOCore`. Название, каталог и SPM primary — техническая рекомендация. Сейчас package/repository не создавался.

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
| Keychain/Realm, owner/session serialisation, commit и app recovery | Xabber host storage adapter |

Public API не экспортирует Signal/Realm/XMPPFramework/UIKit types. Payload AE обрабатывает bytes; библиотека не становится XML/SCE authority. Сохранение candidate ratchet/OPK transitions и принятие plaintext/ciphertext привязаны к явному host commit contract.

## Последовательность работ

| Этап | Реализация | Критерий завершения |
| --- | --- | --- |
| **L01 — Package/API** | `Package.swift`, library/test targets, собственные key/bundle/session/error types, provider/store contracts, fixtures, README и license/provenance metadata. При C conversion — отдельный C target. | Package собирается самостоятельно; тесты запускаются без app/account/Keychain; API не зависит от Signal. |
| **L02 — Primitives/identity** | Native Ed25519 seed, X25519, signing/verification, HMAC/HKDF, AES-CBC, checked RNG, identity conversion и secret lifetime policy. | RFC и независимые positive/negative vectors; Ed seed→X обе стороны дают ожидаемый DH; исходные remote Ed bytes/sign bit сохраняются для signature/AD. |
| **L03 — Wire/X3DH** | Три protobuf codecs, strict bounded parser, exact raw-byte MAC, bundle/SPK verification, обязательный OPK, 4-DH establishment, initial Alice/Bob state и первый authenticated packet. | Independent expected DH/SK/AD/ciphertext/protobuf bytes; malformed bundle/wire/MAC не создаёт usable session и не потребляет OPK. |
| **L04 — Double Ratchet/payload** | DH/chain transitions, Ns/Nr/PN, repeated KEX до authenticated reply, skipped keys/retention, replay, empty controls, payload key32+MAC16 и payload authentication. | Exchange в обе стороны, потеря/reorder/duplicate/old chain/MAX_SKIP, KEX/ACK loss и tampering. Failed auth/provider call не меняет committed state. |
| **L05 — New state/transactions** | Собственный versioned snapshot и state namespace, restore validation, prepare→validate→commit, version/CAS/session serialisation; no writable rollback. | Snapshot roundtrip/restart, pending KEX и skipped keys, concurrent restored objects, corrupt/locked state и injected save failure. Нет release plaintext/ciphertext при неуспешном commit. |
| **L06 — iOS integration/cutover** | Provider seam в manager/storage/codecs; fresh Ed identity и registration; существующие PEP/devices/SCE/trust/maintenance policies. Удалить legacy reader/imports/Signal pods/patch connections; Curve25519Kit — после проверки других usages. | Focused app XCTest с новым backend, новый fingerprint/publication, old state не интерпретируется новым core, локальная расшифрованная история доступна. Simulator app/test build проходит; extension проверяется при изменении linkage. |
| **L07 — Acceptance/release** | Реальный exchange с web OMEMO2 и независимым peer, hostile-parser fuzz/native sanitizers, crypto/state review, dependency/symbol audit, README/API examples и versioned release. Optional podspec — отдельный consumer test. | Fresh interoperable sessions, offline/MAM/restart/own devices/reorder/ACK loss; нет Signal runtime linkage; standalone package воспроизводимо подключается к consumer. |

L03/L04 разделены, чтобы сначала доказать корректность первого пакета независимыми bytes, затем проверять сложную state machine. На каждом этапе сначала focused tests, затем implementation, narrow verification и отдельный reviewable commit. Собственная успешная encrypt→decrypt пара не заменяет independent vectors/peer.

## Переключение с предыдущего backend

- Нет старого Signal v3 reader, X-scalar identity/XEdDSA signer, native snapshot importer и переноса старых sessions/counters/skipped keys.
- Новая identity означает новый fingerprint и peer trust verification. Local cryptographic device/registration policy должна явно завершить прежние объявления, controls и retries; старые ожидающие ciphertexts не отправляются через новые sessions.
- Не удаляем уже расшифрованную локальную историю. Необработанные старые offline/MAM ciphertexts новый backend не расшифровывает — согласованная граница совместимости.
- Ошибка доступа или corruption **нового** protected state не запускает автоматическую генерацию очередной identity.
- Lifecycle задачи N01–N09, выполненные в прежнем app scope, переносим как existing policy/regressions, а не объявляем повторной реализацией всего XMPP слоя.

## Надёжность, которую нужно определить до integration

Package transaction и app/network transaction — разные boundaries. API должен документировать, когда state считается committed, а ciphertext/plaintext допустим к использованию. До L06 необходимо определить:

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

## Первое конкретное действие

После перехода к реализации — L01: отдельный package skeleton, typed API и test harness. Затем L02: independent vectors и primitives. Никакой production backend или зависимости в этой planning-задаче не изменяются; сроки оцениваются после L01/L02, когда определены API/conversion и стоимость verification.
