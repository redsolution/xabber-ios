# Универсальная криптографическая библиотека: границы и API

Дата: 2026-10-09. Статус: API proposal уточнён реализацией L01–L05; XabberCryptoEngine реализует ключи/bundles/session/message/control и собственный snapshot codec/validated restore.
Уточнение пользователя: пакет подключается к любому приложению и предоставляет генерацию ключей/bundles, шифрование и расшифрование. Пакет ничего не знает о XML, XMPP и другом транспорте. Возможности аналогичны используемой библиотеке Signal, но API, типы, состояние и реализация разрабатываются самостоятельно, без копирования Signal.

## Контракт

Выбранное пользователем имя: `XabberCryptoSwift`, отдельный SwiftPM package, optional podspec над теми же sources. Первым поддерживаемым криптографическим профилем является совместимый с OMEMO 2 набор алгоритмов и binary envelopes. Это не XMPP client и не OMEMO transport module: namespace, stanza, PEP, SCE, MAM, адреса/JID, device SID, аккаунты, UI и сеть отсутствуют в public API и core.

Совместимость криптографического профиля сохраняет точные KDF labels, X3DH с OPK, классический ratchet, binary protobuf envelopes и CBC/HMAC. Приложение может доставлять эти байты через HTTP, WebSocket, XMPP, файлы либо другой канал. Произвольно настраиваемые algorithms/KDF/wire profiles в первую версию не входят.

## Public models

| Модель | Содержание |
| --- | --- |
| `IdentityKeyPair` / `IdentityPublicKey` | Ed25519 seed/public и проверенная DH representation; private material явно отделён от public |
| `SignedPreKey` | Криптографический key ID, DH keypair и identity signature |
| `OneTimePreKey` | Криптографический key ID и DH keypair |
| `PublicBundle` | Public identity, public signed prekey/signature и **список public OPKs**; никаких private keys или адресов |
| `SelectedPeerBundle` | Проверенный набор для одного establishment с **одним** выбранным OPK |
| `SessionState` | Только секретное криптографическое состояние X3DH/ratchet, counters, keys, AD/EK и pending exchange |
| `EncryptedMessage` | Binary encrypted payload + cryptographic key envelope, без транспортного container |
| `EncryptionTransition` / `DecryptionTransition` | Результат операции и candidate next state; для initial receive — authenticated consumed OPK ID |
| `SessionSnapshot` | Собственный versioned secret binary state; не Signal record |

Названия — proposal, не копия интерфейса Signal. Идентификаторы prekeys являются частью криптографических records; приложение выбирает их, хранит и разрешает. Пакет не назначает identity владельцу, пользователю или устройству.

## Возможности API

Ниже смысл операций, а не скомпилированные Swift declarations:

```text
generateIdentity()                          -> IdentityKeyPair
importIdentitySeed(seed)                    -> IdentityKeyPair
generateSignedPreKey(id, identity)          -> SignedPreKey
generateOneTimePreKeys(ids)                 -> [OneTimePreKey]
makePublicBundle(identity, signed, prekeys) -> PublicBundle
validateBundle(bundle)                     -> ValidatedPublicBundle
selectPeerBundle(bundle, preKeyID)          -> SelectedPeerBundle
initiateSession(localIdentity, peerBundle) -> SessionState

encryptMessage(bytes, state)               -> EncryptionTransition
decryptMessage(message, state)             -> DecryptionTransition
acceptInitialMessage(message, localKeys)    -> InitialDecryptionTransition

serializeState(state)                      -> SessionSnapshot
restoreState(snapshot)                     -> SessionState
```

Identity `sign(bytes)` / `verify(bytes, signature, publicKey)` доступны для использования приложением. Bundle generation возвращает private prekey records отдельно от публикуемого public bundle. Проверка bundle означает валидность ключей/подписи; подтверждение принадлежности public identity адресату и доверие остаются у приложения.

## Произвольные сообщения и несколько получателей

High-level `encryptMessage` принимает произвольные bytes (`Data`), а `decryptMessage` возвращает bytes. Пакет не интерпретирует их как текст, JSON, XML или чат.

Для первого профиля arbitrary payload шифруется отдельным payload AE. Ratchet шифрует только secret payload key32 + MAC16, а не arbitrary message напрямую. Это скрыто за high-level API и сохраняет совместимый криптографический формат. Низкоуровневые `sealPayload/openPayload` и `wrapPayloadKey/unwrapPayloadKey` могут быть доступны для композиции.

Для нескольких получателей payload шифруется один раз, затем key material оборачивается для каждой session. Приложение само сопоставляет envelopes адресатам; библиотеке не передаются JID, device IDs или recipient lists. Cryptographic empty-control envelope — отдельная операция; автоматическая отправка ACK/heartbeat библиотекой отсутствует.

## Состояние и ошибки

Основная схема — immutable input state и candidate next state. Crypto/parser/provider failure не изменяет исходное состояние. Для initial receive OPK считается consumed только после криптографической аутентификации; библиотека возвращает событие/ID, а host фиксирует consumption совместно с session state.

Результат `decrypt` подтверждает криптографическую целостность bytes. Он не подтверждает бизнес-правила, формат payload или доверие к identity. Host может проверить bytes и отклонить candidate transition без изменения committed state.

**Граница гарантий:** функциональный API уже возвращает provisional ciphertext/plaintext вместе с candidate state; он не может физически скрыть их до внешнего storage commit. Host документированно выполняет `prepare → validate bytes → atomic persist → use output`. Guarantee отсутствия use до успешного commit проверяется в host adapter. Отдельный convenience layer с injected commit callback допустим позже, но не должен вводить XML, Keychain/Realm или обязательный storage backend в core.

Сопоставление sessions приложению, locks/CAS, защищённое хранение, retry/outbox, часы/rotation schedules, публикация bundles и очистка использованных ключей — host responsibilities. Библиотека предоставляет key operations, криптографические events и snapshot codec.

## План после уточнения

1. Standalone package/API и тесты только keys/bytes/in-memory state.
2. Apple crypto providers и checked identity conversion.
3. Bundle/key generation, binary envelopes и independent X3DH first-packet vectors.
4. Ratchet/payload encrypt/decrypt, loss/reorder/replay/failure vectors.
5. Собственный snapshot и candidate transitions, corruption/restart tests.
6. Пример отдельного consumer: два участника обмениваются arbitrary bytes без Xabber/XMPP; package tests/consumer build.
7. Independent crypto interoperability/robustness, API docs и package release.

Подключение к Xabber — **внешняя задача первого consumer**, с собственными adapters, SCE/PEP/trust/store tests и Simulator build. Она не добавляет XMPP concepts в library API. Отказ от старого libsignal state и отдельная web реализация сохраняют ранее согласованные границы.

References: [execution plan](omemo2-independent-library-plan-2026-10-09.md), [requirements/audit](omemo2-independent-library-requirements-2026-10-09.md).

## Реализация L01

Пакет создан в `/Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift`. Фактические декларации — [Package API](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/API.md>). Они уточняют proposal: shape-selected bundle отделён от `ValidatedPeerBundle`; receive transitions и `SessionState.info` возвращают exact peer identity; `KeyEnvelopeKind` описывает crypto framing; seal/open/wrap/unwrap дают композицию для нескольких sessions. Конкретных криптоопераций в L01 нет.

## Реализация L02

`IdentityOperations` отделён от session/message API; `KeyOperations` даёт работающие generate/import identity, sign/verify и independent X25519 key generation/import. `CryptoEngine` наследует identity contract, но concrete session backend остаётся последующей работой. Внутренний AppleCryptoProvider реализует Ed25519/X25519, checked RNG, SHA256/512, HMAC/HKDF-SHA256, AES256-CBC/strict PKCS7 и constant-time comparison. Public-point conversion независимо реализована в C; secret signing/DH используют Apple APIs. [Отчёт L02](xabber-crypto-swift-l02-2026-10-09.md).

## Реализация L03

`KeyOperations` также реализует `PreKeyOperations`: generate/import prekeys, makePublicBundle и validatePeerBundle. `CryptoEngine` наследует оба operational contracts. Внутренние bounded codecs сохраняют exact raw MAC bytes. X3DH/initial-session helpers реализуют четыре DH, exact Ed AD, initial Alice/Bob state и первый authenticated key packet; bad parse/MAC/padding/RNG не возвращают responder state/OPK event. Это не complete public ratchet/message backend; последующие пакеты, controls/payload и snapshots остаются L04–L05. [Отчёт L03](xabber-crypto-swift-l03-2026-10-09.md).

## Реализация L04

`XabberCryptoEngine` реализует operational `CryptoEngine`: ключи/prekeys/bundles, establishment, произвольные байты payload, low-level seal/open/wrap/unwrap и controls. Full classic DH/chain ratchet обрабатывает loss/reorder/repeated KEX и replay с ограниченной памятью/работой. High-level receive возвращает content/state/OPK event только после аутентификации envelope и payload; low-level unwrap остаётся provisional до успешного openPayload. Nil payload означает control с exact zero32, empty user bytes имеют настоящий CBC ciphertext. Host отвечает за trust и сериализацию/атомарный commit каждой session.

Snapshot operations выделены из `CryptoEngine` в отдельный `SessionStateCoding`: контракт существует, codec/restore — L05. `RatchetConfiguration` сохраняется в session; default skip retention/work/lifetime1000, transition cap4096. Retired-chain history не забывается, при cap требуется явное создание новой session. [Отчёт L04](xabber-crypto-swift-l04-2026-10-09.md), [фактический API и limits](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/API.md>).

## Реализация L05

`XabberCryptoEngine` также реализует `SessionStateCoding`. Собственный bounded canonical v1 snapshot
сохраняет exact identities/AD, keys, pending KEX, counters, per-session policy, retired history и
skipped FIFO/event ages. Restore проверяет структуру/relationships/native key consistency без RNG,
clamp normalization или identity regeneration. Unknown checksummed version имеет отдельную ошибку;
повреждённый/несогласованный state не возвращает partial session.

Snapshot — plaintext secret export. SHA256 checksum выявляет corruption, не даёт authenticity или
rollback detection. Host хранит его в authenticated protected storage с session association и
serialized/CAS atomic state/OPK commit. Public consumer продолжает обмен после fresh-engine restore;
host storage workflow остаётся внешним. [Отчёт L05](xabber-crypto-swift-l05-2026-10-09.md),
[формат](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/SNAPSHOT_FORMAT.md>).
