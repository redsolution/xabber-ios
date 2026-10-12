# Используемые методы и интерфейсы Signal в Xabber iOS

Дата проверки: **2026-10-12**. Исходное состояние приложения: `5745521cf3df5ca219702f68a1a7dea57bf262a6`.

Этот документ описывает границу между текущим Xabber iOS и библиотеками Signal: какие операции приложение вызывает, что передаёт, что получает и какие обязанности выполняет само. Охвачены генерация и импорт ключей, подписи, bundles, создание сессий, шифрование, дешифрование, сериализация и callbacks хранения/доверия.

Описание составлено по **кодовым вызовам приложения, публичным заголовкам API, manifests и существующим тестовым вызовам**. Внутренние реализации Signal, восстановительные patches и алгоритмический код библиотек в этом исследовании не читались. Это функциональный аудит существующего consumer, а не предложение копировать API, состояние, код или тестовые векторы Signal в новую библиотеку. Для независимой реализации алгоритмы и wire-форматы следует выводить из опубликованных стандартов; текущая [политика источников XabberCryptoSwift](/Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/SOURCE_POLICY.md) сохраняется. Документ не является доказательством формального clean-room процесса.

## 1. Область и обозначения

| Метка | Что означает |
| --- | --- |
| **O2** | Используется production-путём OMEMO 2. Это дополнение **локальных форков**, а не стандартный API upstream libsignal. |
| **L** | Используется production для legacy identity/bootstrap или чтения старой Signal-истории. |
| **T** | Есть вызов в подключённых XCTest; production-вызов не найден. |
| **U** | Публичный член или код существует, но вызов/чтение в подключённых исходниках приложения и Swift XCTest не найден. |
| **HOST** | Функция/тип Xabber или другого provider; не API Signal. |

«Используемые функции» здесь — прямые вызовы Swift/ObjC/C из Xabber и тестов, реализованные обязательные store callbacks и читаемые публичные свойства. Внутренний граф функций Signal за этой границей не перечисляется. Общие методы `NSObject`/`Foundation`, автоматически вызываемые deinit и `NSSecureCoding` без явных app-вызовов не входят в список.

`Data` — бинарные байты, `NSData` — тот же объект на ObjC-границе; строка Base64 является транспортным представлением, не самим ключом. `UInt32` соответствует `uint32_t`, `Int32` — `int32_t`, `UInt` — `NSUInteger`. Все длины ниже указаны в **байтах**. IK — долговременный identity key, SPK — signed prekey, OPK — one-time prekey, EK — ephemeral key первого обмена, DH — согласование секрета.

Для API с `NSError **` в таблицах приведены **Swift-формы вызова, используемые приложением**. ObjC возвращает `nullable` результат и записывает ошибку; Swift импортирует такой API как `throws`. `OMEMO2Context.verifySignature(...)` и `SignalSessionBuilder.processPreKeyBundle(...)` возвращают ObjC `BOOL`, преобразованный Swift в `Void` при успехе и `throw` при отказе. Legacy helpers без `NSError **` сохраняют optional/обычный результат и не имеют typed `throws`.

### 1.1. Фактически подключённые зависимости

| Библиотека | Версия pod | Локальная revision | Публичная поверхность |
| --- | --- | --- | --- |
| `SignalProtocolC` | `2.3.2` | `29d4e8b66f7539c4731b8c05ebf6fcfa1e786937` | C API + отдельный OMEMO2 profile. |
| `SignalProtocolObjC` | `1.1.0` | `664431049dfa43a43c6ca82e446c1e7332d6f9c8` | Swift-доступные ObjC классы `Signal*` и `OMEMO2*`. |

Их текущие Git HEAD совпадают с [manifest](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/tools/local-dependencies.json). Подключение выполняет [Podfile](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/Podfile), не SwiftPM `Package.resolved`. Номер pod не идентифицирует изменения локального OMEMO2 API без revision.

Основное публичное объявление O2: [OMEMO2.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/OMEMO/OMEMO2.h:1). Вызовы: [XabberOMEMO2Storage.swift](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberOMEMO2Storage.swift:77), [OMEMO2BundleCodec.swift](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/OMEMO2BundleCodec.swift:1), [Omemo2IdentityRepresentation.swift](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/Omemo2IdentityRepresentation.swift:1).

### 1.2. Карта интерфейсов

| Интерфейс | Ответственность | Использование |
| --- | --- | --- |
| `OMEMO2Context` | Ключи, импорт, подпись, проверка, создание/приём/restore сессии. | O2 |
| `OMEMO2IdentityKeyPair`, `OMEMO2KeyPair` | Контейнеры public/private материала. | O2 |
| `OMEMO2Bundle` | Проверенный материал peer с **одним** выбранным OPK. | O2 |
| `OMEMO2Ciphertext` | Разбор и представление бинарного key envelope. | O2 |
| `OMEMO2Session` | Состояние Double Ratchet, key-envelope encrypt/decrypt, secret snapshot. | O2 |
| `SignalStorage`, `SignalContext` | Подключение legacy store и контекста Signal. | L |
| `SignalKeyHelper`, `SignalKeyPair`, `SignalIdentityKeyPair`, `SignalPreKey`, `SignalSignedPreKey` | Legacy bootstrap identity/prekeys/records. | L |
| `SignalAddress`, `SignalCiphertext`, `SignalSessionCipher` | Legacy адресация и чтение существующей истории. | L; encrypt также T |
| `SignalPreKeyBundle`, `SignalSessionBuilder` | Построение legacy Signal сессии. | T |
| `SignalSerializable` | Legacy serialization/deserialization contract. | L/T; deserialization U |
| `SignalStore` и пять родительских store-протоколов | 20 callbacks legacy storage, identity continuity, sender keys. | Реализованы L; sender-key cipher не используется. |

## 2. O2: ключи, импорт, подпись и bundles

### 2.1. Методы `OMEMO2Context`

| № | Метод и входные параметры | Выход | Назначение, ошибки и эффект |
| --- | --- | --- | --- |
| O01 | `OMEMO2Context(error: ())` — app-форма ObjC `initWithError:`; полезных параметров нет. | Новый `OMEMO2Context`; ошибка через `throws`. | Создаёт явный provider OMEMO2; не получает `SignalStorage`, адреса и account. Инициализация может отказать. |
| O02 | `context.generateIdentity()` — без параметров. | `OMEMO2IdentityKeyPair`; `throws`. | Генерирует долговременную identity. Public wire IK — Ed25519 32; private — локальный X25519 scalar 32. Есть генерация случайного материала; библиотека не сохраняет его и не назначает устройству. |
| O03 | `context.identity(withPrivateKey: privateKey)`; `privateKey: Data`, 32. | `OMEMO2IdentityKeyPair`; `throws`. | Восстанавливает identity/public representations из private scalar. Это **не импорт Ed25519 seed**. Используется при migration, restore и подписи; invalid material отклоняется. |
| O04 | `context.generateKeyPair()` — без параметров. | `OMEMO2KeyPair`; `throws`. | Генерирует X25519 пару для SPK/OPK. Метод не назначает ID, timestamp, срок жизни или подпись; это делает host. |
| O05 | `context.keyPair(withPrivateKey: privateKey)`; `privateKey: Data`, 32. | `OMEMO2KeyPair`; `throws`. | Восстанавливает X25519 пару SPK/OPK из private scalar. Используется для private key lookup при первом входящем KEX и для public bundle. |
| O06 | `context.sign(data, identity: identity)`; `data: Data`, произвольные байты; `identity: OMEMO2IdentityKeyPair`. | `Data`, подпись 64; `throws`. | Подписывает **переданные байты** identity, даёт Ed25519-совместимую подпись локального профиля. Для SPK app передаёт raw public SPK 32; для trust sharing — заранее рассчитанный digest. Не выполняет app canonicalization и не устанавливает доверие. |
| O07 | `OMEMO2Context.verifySignature(signature, data: data, identityKey: identityKey)`; `signature: Data`, 64; `data: Data`; `identityKey: Data`, wire Ed25519 32. | Swift `Void` при успехе; `throws` при отказе. ObjC `BOOL`. | Проверяет подпись именно этих байтов под именно этой identity. Bad signature/key/shape даёт отказ. Успех не подтверждает принадлежность IK контакту и не меняет trust/storage. |

Вызовы генерации/импорта/SPK signing: [storage prepare](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberOMEMO2Storage.swift:168), [identity import/sign/verify](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/Omemo2IdentityRepresentation.swift:117). Ошибки импорта, неправильных ключей/подписей и provider failures выражаются `NSError`/`throws`; исчерпывающая привязка каждого внутреннего failure к коду из публичного заголовка не следует.

### 2.2. Читаемые поля key-pair объектов

Все поля `readonly`; входных параметров нет. Обычные `init()`/`new()` у O2 key-pair классов объявлены недоступными: объекты создаёт context.

| Класс / поле | Выход | Для чего читает Xabber |
| --- | --- | --- |
| `OMEMO2IdentityKeyPair.publicKey` | `Data`, Ed25519 wire IK 32. | `<ik>`, signature verification, session identity binding. |
| `OMEMO2IdentityKeyPair.fingerprintPublicKey` | `Data`, raw X25519 public 32. | Проверка continuity legacy identity и app fingerprint. Это public key, не готовая строка fingerprint и не digest. |
| `OMEMO2IdentityKeyPair.privateKey` | `Data`, X25519 private scalar 32. | Защищённое хранение и последующее восстановление/подпись/DH. |
| `OMEMO2KeyPair.publicKey` | `Data`, raw X25519 32. | Подпись public SPK и публикация public SPK/OPK. |
| `OMEMO2KeyPair.privateKey` | `Data`, X25519 private scalar 32. | Защищённое хранение private SPK/OPK и их восстановление. |

### 2.3. `OMEMO2Bundle`: один выбранный OPK

```swift
// Форма публичного вызова в Xabber; функция throwing.
try OMEMO2Bundle(
    identityKey: Data,     // wire Ed25519 IK, 32
    signedPreKey: Data,    // raw X25519 public SPK, 32
    signedPreKeyID: UInt32,
    signature: Data,       // подпись public SPK, 64
    preKey: Data,          // raw X25519 public выбранного OPK, 32
    preKeyID: UInt32
)
```

**O08.** Выход — `OMEMO2Bundle`; при недопустимом материале — `throw` (ObjC `nil` + `NSError`). Конструктор проверяет длины/ключи, обязательный OPK, подпись SPK и положительные 31-битные IDs `1...2^31−1`. Проверка подписи не равна доверенной принадлежности identity. Здесь нет private key, device ID, JID, XML, списка OPKs или публикации на сервере.

`OMEMO2Bundle` публикует `readonly` поля без аргументов:

| Поле | Выход | Статус / смысл |
| --- | --- | --- |
| `identityKey` | `Data`, 32 | O2/T; исходная wire IK peer. |
| `signedPreKey` | `Data`, 32 | O2/T; public SPK, используется и для digest fresh bundle. |
| `signedPreKeyID` | `UInt32` | O2/T; ID SPK peer. |
| `signature` | `Data`, 64 | O2/T; подпись SPK. |
| `preKey` | `Data`, 32 | O2/T; public выбранного OPK; app сохраняет связь с outgoing session. |
| `preKeyID` | `UInt32` | O2/T; ID выбранного OPK. |

Вызов: [OMEMO2PublishedBundle.selectedBundle(preKeyID:)](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/OMEMO2BundleCodec.swift:16). **Публичный bundle со списком ключей** — host-структуры `OMEMO2LocalBundle`/`OMEMO2PublishedBundle`, а не этот library object. App проверяет каждый опубликованный OPK через отдельный `OMEMO2Bundle`.

## 3. O2: сессии, шифрование и дешифрование

### 3.1. Создание, приём и restore

| № | Метод и входы | Выход | Что делает и что остаётся host |
| --- | --- | --- | --- |
| O09 | `context.initiateSession(withIdentity: identity, bundle: bundle)`; локальная `OMEMO2IdentityKeyPair`, проверенный peer `OMEMO2Bundle`. | Новая `OMEMO2Session`; `throws`. | Инициирует криптографическую сессию; её первые пакеты несут KEX до подтверждения. Caller выбирает peer/OPK, применяет trust и сохраняет сессию. Никакого network send. |
| O10 | `context.acceptKeyExchange(ciphertext, identity: identity, signedPreKey: spk, signedPreKeyID: spkID, preKey: opk, preKeyID: opkID, plaintext: &output)`; `ciphertext: OMEMO2Ciphertext` с KEX; локальная identity; private/public пары `OMEMO2KeyPair` для SPK/OPK; IDs `UInt32`; `output: NSData?` — выходной pointer. | `OMEMO2Session` **и** `output` с plaintext key material; `throws`. | Создаёт responder session только после аутентификации первого KEX. Parsed IK ещё не доверенная IK. Lookup private keys, внешняя payload validation, сохранение snapshot и отметка OPK consumed принадлежат app; consumption нельзя делать до проверки. |
| O11 | `context.restoreSession(with: snapshot)`; `snapshot: Data`. | Восстановленная `OMEMO2Session`; `throws`. | Читает versioned **секретный O2 snapshot**, не legacy Signal record. Host отвечает за owner/session association, защищённое хранение и отсутствие rollback. Restore не подтверждает доверие к peer. |

Вызовы O09/O11: [session initiate/encrypt](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberOMEMO2Storage.swift:250). O10: [первый incoming KEX](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberOMEMO2Storage.swift:358).

### 3.2. Методы `OMEMO2Session`

| № | Метод и входы | Выход | Назначение и изменение состояния |
| --- | --- | --- | --- |
| O12 | `session.encryptData(data)`; `data: Data`: **48** байт `payloadKey32 \|\| payloadMAC16` или ровно **32 нулевых** байта для empty control. | `OMEMO2Ciphertext`; `throws`. | Шифрует key envelope выбранной сессией; после успеха ratchet/counters изменены. Не шифрует XML/текст целого сообщения и не выбирает recipients. Snapshot необходимо сохранить перед выпуском outgoing ciphertext. |
| O13 | `session.decryptCiphertext(ciphertext)`; parsed `OMEMO2Ciphertext`. | `Data`; app ожидает key material 48 или control zero32; `throws`. | Проверяет криптографический пакет, расшифровывает и после успеха продвигает ratchet. Parsing/authentication failure не меняет state согласно публичному контракту. Успех ещё не подтверждает MAC отдельного payload, SCE bindings или trust; допустимый размер plaintext дополнительно проверяет app. |
| O14 | `session.serializedData()` — без параметров. | `Data`, secret versioned snapshot; `throws`. | Экспортирует текущее криптографическое состояние для restart. Это не wire ciphertext/public bundle; его нельзя публиковать или декодировать как legacy record. |

Публичный контракт синхронизирует calls **одного** `OMEMO2Session` object. Несколько отдельно restored objects могут работать с одной сохранённой сессией: host обязан сериализовать их read/advance/save. После успеха decrypt library object уже продвинут; app использует **восстановленный candidate**, выполняет `validating(plaintext)` и лишь затем сохраняет snapshot/consumed OPK. Reject отдельного payload не должен сохранять candidate. Protected save не покрывает автоматически network send и запись истории в другой store.

Вызовы: [encrypt](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberOMEMO2Storage.swift:274), [candidate decrypt/validation/save](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberOMEMO2Storage.swift:299).

### 3.3. Поля `OMEMO2Session`

Поля только читаются, аргументов нет; они описывают криптографический state, не доставку сообщения сервером.

| Поле / Swift getter | Тип выхода | Смысл и статус |
| --- | --- | --- |
| `isKeyExchangePending` (ObjC property `keyExchangePending`) | `Bool` | O2; exchange ещё ожидает authenticated reply; host планирует control. |
| `sendCounter` | `UInt32` | O2; состояние счётчика отправляющей цепочки. |
| `receiveCounter` | `UInt32` | O2; состояние счётчика принимающей цепочки. |
| `remotePreKeyID` | `UInt32` | O2; у initiator ID использованного remote OPK, сохраняется после ACK; у responder — 0. Нужен recovery metadata. |
| `ephemeralKey` | `Data`, 32 | O2; EK initiation, host связывает повторные KEX с сохранённой session. |
| `remoteIdentityKey` | `Data`, Ed25519 32 | O2; IK peer, связанная с session; после authenticated receive используется для exact sender trust. До receive она также может быть взята из ранее принятого bundle. |
| `previousCounter` | `UInt32` | U в app/Swift XCTest; состояние previous sending chain counter, объявлено публично. |
| `skippedKeyCount` | `UInt` | U в app/Swift XCTest; число сохранённых skipped message keys. |
| `ratchetKey` | `Data`, 32 | U в app/Swift XCTest; public local ratchet key. App читает одноимённое поле **ciphertext**, а не это поле session. |

Считывание metadata: [XabberOMEMO2Storage.sessionMetadata](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberOMEMO2Storage.swift:480).

### 3.4. `OMEMO2Ciphertext`

**O15.** `try OMEMO2Ciphertext(data: Data, keyExchange: Bool)` — разбирает binary protobuf envelope. Выход — `OMEMO2Ciphertext`; malformed bytes/shape дают `throw`. `keyExchange` сообщает ожидаемый тип envelope; приложение получает его из validated transport `<key kex=...>`. Сам парсер **не аутентифицирует** peer и не устанавливает trust. Обычный `init()/new()` недоступен.

| Поле / Swift getter | Тип выхода | Значение и использование |
| --- | --- | --- |
| `data` | `Data` | O2/T; binary wire bytes, app кодирует их в Base64 для `<key>`. |
| `isKeyExchange` (ObjC property `keyExchange`) | `Bool` | O2/T; KEX envelope или regular envelope; управляет receive path и outgoing `kex`. |
| `counter` | `UInt32` | O2; packet counter, в том числе replay/lifetime accounting. |
| `previousCounter` | `UInt32` | U в app/Swift XCTest; counter предыдущей цепочки из header. |
| `ratchetKey` | `Data`, 32 | O2/T; public DH ratchet key packet, app отслеживает incoming ratchet transitions. |
| `ephemeralKey` | `Data?`, 32 если KEX | O2/T; EK из KEX; regular packet не имеет этого поля. |
| `identityKey` | `Data?`, Ed25519 32 если KEX | T; public IK из разобранного KEX, **ещё не authenticated** самим parse. Production использует `session.remoteIdentityKey` после проверки. |
| `signedPreKeyID` | `UInt32` | O2/T; ID SPK для first KEX private lookup; meaningful для KEX. |
| `preKeyID` | `UInt32` | O2/T; ID OPK для first KEX lookup/consumption; meaningful для KEX. |

Вызов parser и отдельные legacy/O2 paths: [OmemoManager.decryptIncoming](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/OmemoManager.swift:1207). Test-only чтение parsed IK: [OMEMO2CryptoKitConformanceTests.swift](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabberTests/OMEMO2CryptoKitConformanceTests.swift:130).

## 4. Прямые функции `SignalProtocolC`

Их вызывает `Omemo2IdentityRepresentation`, а не только ObjC wrapper. Четыре OMEMO helper являются публичными дополнениями локального C fork. Здесь описана C-граница, не внутренняя реализация.

```c
int signal_context_create(signal_context **context, void *user_data);
void signal_context_destroy(signal_context *context);
void signal_type_unref(signal_type_base *instance);
int omemo_identity_key_decode(ec_public_key **key, const uint8_t input[32], signal_context *context);
int omemo_public_key_encode(uint8_t output[32], const ec_public_key *key);
int omemo_public_key_decode(ec_public_key **key, const uint8_t input[32], signal_context *context);
int curve_decode_private_point(ec_private_key **private_key, const uint8_t *key_data, size_t key_len, signal_context *global_context);
int omemo_calculate_agreement(uint8_t output[32], const ec_public_key *public_key, const ec_private_key *private_key);
```

| № | Функция / входы | Выходы и ownership | Назначение / отказ |
| --- | --- | --- | --- |
| C01 | `signal_context_create`; `context` — pointer для результата; `user_data` — opaque caller value, app передаёт `nil`. | `int`: 0 успех / отрицательный код; через `*context` новый context. | Создаёт C context, освобождаемый C02. App отдельно проверяет non-null result. |
| C02 | `signal_context_destroy`; `context: signal_context *`. | `void`; context больше нельзя использовать. | Освобождает C context; app вызывает в `defer`. |
| C03 | `signal_type_unref`; `instance: signal_type_base *`, app передаёт созданные public/private point objects. | `void`; refcount уменьшается, при последней ссылке object освобождается. | Освобождение объектов ключей. Это не операция удаления prekey из app storage. |
| C04 | `omemo_identity_key_decode`; вход wire Ed25519 public IK `input[32]`, context; `key` — pointer результата. | Код 0 / отрицательная ошибка; `*key: ec_public_key *`, освобождается C03. | Декодирует/конвертирует wire IK в используемую Curve25519 public representation. Не проверяет доверие или подпись сообщения. |
| C05 | `omemo_public_key_encode`; `key: const ec_public_key *`; `output[32]` — caller buffer. | Код 0 / отрицательная ошибка; raw X25519 public bytes в output. | Даёт raw X25519 key без legacy prefix; app использует после C04 для fingerprint/DH. |
| C06 | `omemo_public_key_decode`; raw X25519 public `input[32]`, context; `key` — pointer результата. | Код 0 / отрицательная ошибка; `*key: ec_public_key *`, ownership C03. | Импорт public peer point для DH. |
| C07 | `curve_decode_private_point`; private `key_data`, `key_len: size_t` (app проверяет 32), context; `private_key` — pointer результата. | Код 0 / отрицательная ошибка; `*private_key: ec_private_key *`, ownership C03. | Импорт private scalar для DH. Объявленная variable length не означает, что app разрешает произвольные длины. |
| C08 | `omemo_calculate_agreement`; `public_key` peer, `private_key` local; `output[32]` — caller buffer. | Код 0 / отрицательная ошибка; shared secret 32. | Выполняет DH; публичный контракт отклоняет all-zero shared secret и очищает output при ошибке. Host применяет KDF; этот результат не готовый AES key. |

Сигнатуры: [signal_protocol.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolC/src/signal_protocol.h:61), [context API](/Users/igor.boldin/projects/xabber/deps/SignalProtocolC/src/signal_protocol.h:703), [curve.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolC/src/curve.h:36), [omemo_keys.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolC/src/omemo_keys.h:14). Direct calls: [identity conversion](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/Omemo2IdentityRepresentation.swift:50), [DH](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/Omemo2IdentityRepresentation.swift:91), [context lifetime](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/Omemo2IdentityRepresentation.swift:138). C01–C03/C06–C08 также вызываются Swift XCTest для проверки CryptoKit interoperability.

`omemo_key_pair_from_private`, `omemo_identity_key_encode`, `omemo_identity_sign`, `omemo_identity_verify`, C session/ratchet functions и crypto/store registration functions **не вызываются напрямую** app/Swift XCTest. Их объявленная доступность или использование за ObjC boundary не делает их отдельной app-зависимостью; они не включены в direct inventory.

В C параметр `input[32]`/`output[32]` в ABI является pointer, а не автоматически проверяемым массивом. Размер буфера и длину `Data` до unsafe call обеспечивает caller. App helper `requireSuccess(_ result: Int32)` принимает только 0 и преобразует любой другой код в `Omemo2IdentityRepresentationError.cryptoFailure(result)`.

## 5. Legacy Signal: контекст, ключи и records

Эти API принадлежат `SignalProtocolObjC`. Legacy identity/bootstrap остаётся переходным источником текущего приложения; исходящая production-переписка использует O2. Новый независимый package не обязан поддерживать старые records/scalar identity/history.

### 5.1. Создание контекста и адреса

| № | Используемый вызов / вход | Выход / ошибки | Назначение и статус |
| --- | --- | --- | --- |
| L01 | `SignalStorage(signalStore: store)`; `store: SignalStore`, в app `XabberAxolotlStorage`. | Nonoptional `SignalStorage`; без `NSError`/`throws`. | L; подключает один объект, реализующий пять callback-протоколов. |
| L02 | `SignalContext(storage: storage)`; `SignalStorage`. | `SignalContext?`; `nil` при отказе, без `NSError`/`throws`. | L; создаёт legacy context со storage; production force-unwrap. |
| L03 | `SignalAddress(name: name, deviceId: deviceId)`; `name: String`, app bare JID; `deviceId: Int32`. | Nonoptional `SignalAddress`; без typed error. | L; идентифицирует peer/device для session/identity store. Нормализация имени/owner scoping — host. |
| L04 | `SignalKeyHelper(context: context)`; `SignalContext`. | `SignalKeyHelper?`; `nil` при отказе, без `NSError`/`throws`. | L; generator legacy identity/prekeys; не сохраняет их в app автоматически. |

Публичные объявления: [SignalStorage.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/Storage/SignalStorage.h:16), [SignalContext.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/SignalContext.h:13), [SignalAddress.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/Models/SignalAddress.h:12), [SignalKeyHelper.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/SignalKeyHelper.h:16). Вызовы: [OmemoManager init](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/OmemoManager.swift:132), [legacy bootstrap](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberAxolotlStorage.swift:114).

### 5.2. Генерация и импорт

| № | Метод / входные параметры | Выход | Комментарий |
| --- | --- | --- | --- |
| L05 | `helper.generateIdentityKeyPair()` — без аргументов. | `SignalIdentityKeyPair?`; без `throws`. | L; генерирует legacy identity. В app public encoding — `0x05 \|\| raw X25519` (33), private scalar 32. Production force-unwrap. |
| L06 | `helper.generatePreKeys(withStartingPreKeyId: start, count: count)`; `start: UInt`, `count: UInt`. | `[SignalPreKey]`; без `NSError`/`throws`. | L; массив legacy OPK records с IDs и private/public pair. Production передаёт `start=1`, `count=100`. Публичный header не определяет полноту результата при partial generation failure. |
| L07 | `helper.generateSignedPreKey(withIdentity: identity, signedPreKeyId: id)`; `identity: SignalIdentityKeyPair`, `id: UInt32`. | `SignalSignedPreKey?`; без `throws`. | L; создаёт SPK keypair и подпись supplied identity, ID/timestamp record. Production ID=1 и force-unwrap результата. Не смешивать legacy signature profile с wire O2 signing. |
| L08 | `try SignalIdentityKeyPair(publicKey: publicKey, privateKey: privateKey)`; оба `Data`: legacy public33, private32. | `SignalIdentityKeyPair`; `throws` (ObjC nullable + error). | L; унаследованный `SignalKeyPair.initWithPublicKey:privateKey:error:` восстанавливает legacy pair. Header сам по себе не обещает проверку correspondence public/private; app отдельно выводит O2 fingerprint public из scalar и сравнивает. |
| L09 | `preKey.serializedData()`; receiver `SignalPreKey`, без аргументов. | `Data?`; без error output. | L/T; opaque secret legacy PreKey record для store, **не public preKey bytes**. |
| L10 | `signedPreKey.serializedData()`; receiver `SignalSignedPreKey`, без аргументов. | `Data?`; без error output. | L/T; opaque secret signed-prekey record для store, **не public bundle**. |

L09/L10 реализуют `SignalSerializable`. Другой его required метод — ObjC `initWithSerializedData:error:` — доступен как deserialization contract, но **прямых app/Swift XCTest вызовов не найдено (U)**. Сериализацию `NSSecureCoding` этих классов приложение явно не вызывает.

Источники: [SignalKeyPair.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/Models/SignalKeyPair.h:14), [SignalIdentityKeyPair.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/Models/SignalIdentityKeyPair.h:13), [SignalSerializable.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/Models/SignalSerializable.h:12), [bootstrap generation/store](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberAxolotlStorage.swift:129), [reconstruction](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberAxolotlStorage.swift:222).

### 5.3. Поля legacy объектов

Все перечисленные поля `readonly`, без входных параметров. Поля `keyPair` могут быть `nil`; app обязан отличать это от существующей key pair.

| Поле | Выход | Использование / смысл |
| --- | --- | --- |
| `SignalAddress.name` | `String` | L/T; имя peer для storage callback. |
| `SignalAddress.deviceId` | `Int32` | L/T; device ID для storage callback. |
| `SignalKeyPair.publicKey`, в том числе у `SignalIdentityKeyPair` | `Data`, в app legacy33 | L/T; public legacy identity/SPK/OPK для app projection или test bundle. |
| `SignalKeyPair.privateKey`, в том числе у `SignalIdentityKeyPair` | `Data`, в app32 | L/T; private scalar для credentials. |
| `SignalPreKey.preKeyId` | `UInt32` | L/T; ID OPK record. |
| `SignalPreKey.keyPair` | `SignalKeyPair?` | L/T; public/private пара OPK. |
| `SignalSignedPreKey.preKeyId` | `UInt32` | L/T; ID SPK record; имя поля тоже `preKeyId`. |
| `SignalSignedPreKey.signature` | `Data` | L/T; legacy подпись SPK, не O2 wire подпись автоматически. |
| `SignalSignedPreKey.keyPair` | `SignalKeyPair?` | L/T; public/private SPK пара. |
| `SignalSignedPreKey.timestamp` | `Date` | U; публично объявлен, app/test Swift чтение не найдено. |
| `SignalContext.storage` | `SignalStorage` | U; публичная ссылка context→store, прямое чтение не найдено. |
| `SignalKeyHelper.context` | `SignalContext` | U; public helper→context, прямое чтение не найдено. |

Поля prekeys: [SignalPreKey.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/Models/SignalPreKey.h:14), [SignalSignedPreKey.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/Models/SignalSignedPreKey.h:14).

`SignalKeyHelper.generateRegistrationId() -> UInt32` **не вызывается (U)**. Header описывает 0 как failure. Текущий app сам выбирает registration ID через `arc4random_uniform(...) + 1`, с лимитом 16380. Registration ID и OMEMO device ID — разные сущности; O2 bundle выше registration ID не содержит.

## 6. Legacy Signal: дешифрование истории и тестовая отправка

### 6.1. Production history receive

| № | Вызов / входы | Выход / ошибки | Назначение и эффект |
| --- | --- | --- | --- |
| L11 | `SignalSessionCipher(address: address, context: context)`; `SignalAddress`, legacy `SignalContext`. | Nonoptional `SignalSessionCipher`; без typed error в initializer. | L; cipher привязан к peer/device и callback storage. |
| L12 | `SignalCiphertext(data: data, type: type)`; `data: Data`, `type: SignalCiphertextType`. | Nonoptional `SignalCiphertext`; без typed error. | L; container legacy bytes с ожидаемым видом `.preKeyMessage` или `.message`. Публичный initializer не обещает parsing/authentication. |
| L13 | `try cipher.decryptCiphertext(ciphertext)`; `SignalCiphertext`. | Plaintext `Data`; `throws`. | L; аутентифицирует/дешифрует legacy packet. Legacy store callbacks могут продвинуть persisted state до последующей проверки external payload. Это не O2 candidate transaction. |

Текущий [receiver](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/OmemoManager.swift:1225) выбирает L-путь только для `data.first == 0x33` и существующей legacy session. O2 authentication failure не переключает профиль. Производственного построения новых outgoing legacy сессий не найдено.

Источники: [SignalSessionCipher.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/SignalSessionCipher.h:15), [SignalCiphertext.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/Models/SignalCiphertext.h:11).

`SignalCiphertextType` содержит `.unknown = 0`, `.message = 1`, `.preKeyMessage = 2`. App использует последние два; это тип container, не байтовое значение version header.

| Читаемый getter | Выход | Статус |
| --- | --- | --- |
| `SignalCiphertext.type` | `SignalCiphertextType` | T; fixture выбирает transport `kex` flag. |
| `SignalCiphertext.data` | `Data` | T; fixture переносит legacy wire bytes в XML. |
| `SignalSessionCipher.address` | `SignalAddress` | T; создание legacy builder и проверка сохранённой session. |
| `SignalSessionCipher.context` | `SignalContext` | U; прямое чтение не найдено. |

### 6.2. Дополнительные вызовы XCTest

Эти вызовы нужны для fixture старой истории в [OMEMO2SCEReceiveTests.swift](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabberTests/OMEMO2SCEReceiveTests.swift:661); это не production sender.

**T01.** `try SignalPreKeyBundle(registrationId: UInt32, deviceId: UInt32, preKeyId: UInt32, preKeyPublic: Data, signedPreKeyId: UInt32, signedPreKeyPublic: Data, signature: Data, identityKey: Data)`.

- Вход: registration/device IDs peer; один OPK ID/public; SPK ID/public/signature; public IK. Legacy public bytes fixture берёт из generated `SignalKeyPair`.
- Выход: `SignalPreKeyBundle`; ObjC nullable + `NSError`, в Swift `throws`.
- Смысл: собирает legacy материал peer для session builder. Public header не даёт полного validation contract; нельзя приписывать ему проверки O2 constructor.
- Его readonly getters `registrationId`, `deviceId`, `preKeyId`, `preKeyPublic`, `signedPreKeyId`, `signedPreKeyPublic`, `signature`, `identityKey` имеют те же типы; прямого чтения их из app/Swift XCTest не найдено (U). Передача объекта builder не равна прямому app-чтению getter.
- Объявление: [SignalPreKeyBundle.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/Models/SignalPreKeyBundle.h:23).

| № | Вызов / входы | Выход | Смысл / эффект |
| --- | --- | --- | --- |
| T02 | `SignalSessionBuilder(address: SignalAddress, context: SignalContext)` | Nonoptional builder, без typed error. | Привязывает legacy session builder к peer/context. |
| T03 | `try builder.processPreKeyBundle(bundle)`; `bundle: SignalPreKeyBundle`. | Swift `Void`, ObjC `BOOL`; при отказе `throws`. | Создаёт outgoing legacy session через callback stores. Нельзя выдавать за active O2 establishment. |
| T04 | `try cipher.encryptData(data)`; произвольная plaintext `Data`. | `SignalCiphertext`; `throws`. | Legacy session encryption, state/store advance. В fixture обрабатывает bootstrap text и затем payload key material. В отличие от O2 `encryptData`, старый public contract не ограничен key48/zero32. |

Объявление builder: [SignalSessionBuilder.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/SignalSessionBuilder.h:17). Его public getters `address`/`context` имеют типы `SignalAddress`/`SignalContext`, прямых app/test чтений не найдено (U).

## 7. Все реализованные callbacks `SignalStore`

`SignalStore` объединяет **20 required методов** пяти протоколов. App реализует их в `XabberAxolotlStorage`; O2 context этот интерфейс не использует. Это обратные вызовы library→host, хотя некоторые app/tests вызывают их и напрямую. Ни один из callbacks не имеет `NSError **` или `throws`.

Сериализованные records — **opaque secret storage bytes**, не raw public key. `(address.name, address.deviceId)` дополняется app `owner`. Realm primary-key convention/Keychain layout не является частью crypto протокола.

### 7.1. `SignalSessionStore` — 6 методов

Объявление: [SignalSessionStore.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/Storage/SignalSessionStore.h:13). Реализация: [session callbacks](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberAxolotlStorage.swift:230).

| № | Точная Swift-сигнатура; входы | Выход / действие / фактический отказ |
| --- | --- | --- |
| S01 | `sessionRecord(for address: SignalAddress) -> Data?` | Возвращает serialized legacy session для адреса; отсутствие, другой профиль или Realm error → `nil`. |
| S02 | `storeSessionRecord(_ recordData: Data, for address: SignalAddress) -> Bool` | Создаёт/заменяет opaque record. `true` при Realm write; `false` при ошибке или конфликте существующего профиля. |
| S03 | `sessionRecordExists(for address: SignalAddress) -> Bool` | Проверяет наличие row `legacy-signal`; Realm failure → `false`. Не проверяет содержимое record на валидность. |
| S04 | `deleteSessionRecord(for address: SignalAddress) -> Bool` | Удаляет row; `true` при найденной и удалённой записи, `false` если отсутствует/ошибка. **App не фильтрует профиль при удалении.** |
| S05 | `allDeviceIds(forAddressName addressName: String) -> [NSNumber]` | IDs legacy session rows для имени peer/owner; Realm error → `[]`. Header не задаёт порядок списка. |
| S06 | `deleteAllSessions(forAddressName addressName: String) -> Int32` | Число удалённых rows, `-1` при ошибке. **App не фильтрует профиль при удалении.** |

### 7.2. `SignalPreKeyStore` — 4 метода

Объявление: [SignalPreKeyStore.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/Storage/SignalPreKeyStore.h:12). Реализация: [OPK callbacks](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberAxolotlStorage.swift:361).

| № | Точная Swift-сигнатура; входы | Выход / действие / фактический отказ |
| --- | --- | --- |
| S07 | `loadPreKey(withId preKeyId: UInt32) -> Data?` | Serialized local OPK record из CredentialsManager; нет доступной записи → `nil`. |
| S08 | `storePreKey(_ preKey: Data, preKeyId: UInt32) -> Bool` | Записывает record, возвращает результат `containsPreKey`. Проверяется наличие, не равенство записанных bytes и не отдельный Keychain status. |
| S09 | `containsPreKey(withId preKeyId: UInt32) -> Bool` | Доступны ли bytes record по local OPK ID. |
| S10 | `deletePreKey(withId preKeyId: UInt32) -> Bool` | По интерфейсу — удалить OPK. **Production реализация no-op, всегда `true`, удаление закомментировано.** Это факт legacy adapter, не требование новой библиотеки. |

### 7.3. `SignalSignedPreKeyStore` — 4 метода

Объявление: [SignalSignedPreKeyStore.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/Storage/SignalSignedPreKeyStore.h:12). Реализация: [SPK callbacks](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberAxolotlStorage.swift:388).

| № | Точная Swift-сигнатура; входы | Выход / действие / фактический отказ |
| --- | --- | --- |
| S11 | `loadSignedPreKey(withId signedPreKeyId: UInt32) -> Data?` | Serialized local SPK record; отсутствие/недоступность → `nil`. |
| S12 | `storeSignedPreKey(_ signedPreKey: Data, signedPreKeyId: UInt32) -> Bool` | Записывает SPK, затем проверяет наличие record. Не подтверждает equality/durable transaction. |
| S13 | `containsSignedPreKey(withId signedPreKeyId: UInt32) -> Bool` | Доступны ли bytes SPK record по ID. |
| S14 | `removeSignedPreKey(withId signedPreKeyId: UInt32) -> Bool` | Вызывает CredentialsManager remove; **возвращает `true` без подтверждения результата Keychain deletion**. |

### 7.4. `SignalIdentityKeyStore` — 4 метода

Объявление: [SignalIdentityKeyStore.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/Storage/SignalIdentityKeyStore.h:14). Реализация: [identity callbacks](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberAxolotlStorage.swift:410).

| № | Точная Swift-сигнатура; входы | Выход / действие / фактический отказ |
| --- | --- | --- |
| S15 | `getIdentityKeyPair() -> SignalIdentityKeyPair` | Без входа; local legacy pair. Если credentials отсутствуют/не декодируются — **`preconditionFailure`**, не optional/throw; автоматического keygen нет. |
| S16 | `getLocalRegistrationId() -> UInt32` | Без входа; registration ID credentials. Недоступен, `<=0` или `>UInt32.max` → **0**. Комментарий header про negative failure несовместим с unsigned типом; app использует zero sentinel. |
| S17 | `saveIdentity(_ address: SignalAddress, identityKey: Data?) -> Bool` | Public candidate IK или `nil`; сохраняет identity binding. `nil` очищает key bytes в row, но cached bundle может остаться fallback lookup. Эквивалентный migrated Ed key сохраняется без downgrade. Другой ключ → invalidation и `false`; Realm error → `false`. |
| S18 | `isTrustedIdentity(_ address: SignalAddress, identityKey: Data) -> Bool` | Проверяет **continuity identity/TOFU**: нет старого key → `true`; эквивалентный → `true`; изменился/Realm error → `false`. При смене ключа вызывает invalidation. **Не проверяет пользовательский `.trusted` trust state.** |

Эквивалентность здесь: exact byte equality либо equality canonical X25519 public representations (`legacy33`/`O2 Ed32`). При реальной смене IK app ставит `.fingerprintChanged`, очищает trust date/source/certificate metadata и удаляет stale legacy session/trusted-binding row. Это policy приложения, а не автоматическое установление доверия библиотекой.

### 7.5. `SignalSenderKeyStore` — 2 метода

Объявление: [SignalSenderKeyStore.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/Storage/SignalSenderKeyStore.h:13). Реализация: [sender-key callbacks](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberAxolotlStorage.swift:571).

| № | Точная Swift-сигнатура; входы | Выход / действие / фактический отказ |
| --- | --- | --- |
| S19 | `storeSenderKey(_ senderKey: Data, address: SignalAddress, groupId: String) -> Bool` | Opaque sender-key record и scope sender/device/group; Realm upsert → `true`, ошибка → `false`. |
| S20 | `loadSenderKey(for address: SignalAddress, groupId: String) -> Data?` | Record bytes по тому же scope или `nil`. |

Callbacks реализованы как required conformances; вызовов группового Signal sender-key cipher в приложении/Swift XCTest **не найдено**. Нельзя выводить из этих двух методов, что group OMEMO использует SenderKey; используемая отправка построена на per-device session fanout.

Legacy callbacks не являются общим atomic commit API. O2 app хранит свой aggregate secret state отдельно, через checked persistence и owner lock. В XCTest `LegacyKeyStore` реализует те же 20 callbacks в памяти; его `deletePreKey` действительно удаляет запись, в отличие от production legacy adapter.

## 8. Доверие, fingerprints и функции приложения вокруг Signal

Криптографическая проверка отвечает на вопрос, какие bytes подписала identity или какая identity связана с authenticated session. Решение доверять этому ключу для конкретного контакта/устройства принимает **Xabber**. Публичный O2 API не содержит store trust callback, `trustDevice`, certificate policy, кодов верификации или trust-sharing transport.

### 8.1. Преобразование identity и fingerprint — HOST

Источник всех методов ниже: [Omemo2IdentityRepresentation.swift](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/Omemo2IdentityRepresentation.swift:17). Это **app wrappers**, не новые функции Signal. Они объясняют, зачем нужны O03/O06/O07 и C04–C08.

| Функция / входы | Выход | Комментарий |
| --- | --- | --- |
| `curvePublicKey(from wireIdentity: Data) throws -> Data` | Raw X25519 public32. | Вход должен быть wire Ed25519 IK32; C04→C05 выполняют преобразование. |
| `canonicalCurvePublicKey(fromLegacyOrOMEMO2Identity identity: Data) throws -> Data` | Raw X25519 public32. | `33` bytes с prefix `0x05` → убрать prefix; **эта ветка не валидирует public point**. Иначе Ed32 проходит C decode/convert; invalid shape или decoder failure → error. |
| `rawX25519(identityKey: Data) throws -> Data` | Raw X25519 public32. | Alias для **wire Ed** входа через `curvePublicKey`. |
| `canonicalRawX25519(storedIdentityKey: Data) throws -> Data` | Raw X25519 public32. | Alias для dual legacy/O2 stored representation. |
| `fingerprint(for identity: Data) throws -> String` | Lowercase hex canonical X25519 public, по 4 bytes в группе, разделитель пробел. | Это hex public key32 **без хеширования**. Не метод Signal. |
| `sharedSecret(privateKey: Data, peerIdentity: Data) throws -> Data` | DH shared secret32. | Local scalar32 + peer legacy33/Ed32; C06/C07/C08. Bad key/all-zero result → error; KDF выполняется выше. |
| `sign(_ data: Data, privateKey: Data) throws -> Data` | Signature64. | O03 восстанавливает identity из local scalar; O06 подписывает точные bytes. |
| `verify(_ signature: Data, data: Data, storedIdentity: Data) -> Bool` | `true` только при успешной проверке. | Signature должна быть64. Ed32 → O07; ошибка не выбирает legacy verifier. Legacy33 с prefix05 → отдельный `Curve25519Kit.Ed25519.verifySignature`. |
| `localIdentityPrivateKey(owner: String, storage: XabberOMEMO2Storage? = nil, legacyPrivateKey: (() -> Data?)? = nil) throws -> Data` | Local scalar32. | Читает authoritative O2 identity; legacy credentials допустимы только при отсутствии подготовленного O2 aggregate, не при corruption/access failure нового state. Owner lookup — app. |

**Отличающийся legacy app fingerprint:** `Data.formattedFingerprint() -> String` считает SHA256 входных bytes, делает uppercase hex и группирует по 8 hex chars. Используется legacy bootstrap/fallback; его нельзя считать эквивалентом O2 fingerprint выше. Источник: [Data+HexadecimalString.swift](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/utils/Data/Data+HexadecimalString.swift:52).

Replay fingerprint сообщения — ещё одна отдельная сущность: `OMEMO2ReplayProtection.fingerprint(for:owner:localDeviceID:) -> Data?` хеширует framed packet/transport association, а не identity для ручного доверия. Источник: [OMEMO2ReplayProtection.swift](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/OMEMO2ReplayProtection.swift:9).

### 8.2. Пользовательское доверие — HOST

`SignalDeviceStorageItem` несмотря на имя является **Realm-моделью Xabber**, а не library interface. Её [TrustState](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/SignalDeviceStorageItem.swift:25) содержит `.unknown`, `.ignore`, `.trusted` (stored `"trust"`), `.distrusted` (`"distrust"`), `.revoked`, `.fingerprintChanged`.

| App функция / входы | Выход / эффект | Связь с crypto API |
| --- | --- | --- |
| `AuthenticatedKeyExchangeManager.getUsersPublicKey(jid: String, deviceId: Int) -> [UInt8]` | Canonical X25519 public bytes; при недоступности `[]`. | Читает public identity и вызывает app conversion. Не устанавливает trust. |
| `AuthenticatedKeyExchangeManager.getUsersIdentityKey(jid: String, deviceId: Int) -> Data?` | Исходная сохранённая Ed32/legacy33 identity или `nil`. | Проверяет допустимость representation, сохраняя original wire bytes. |
| `AuthenticatedKeyExchangeManager.writeTrustedDevice(jid: String, deviceId: Int)` | `Void`; обновляет `.trusted`, trust date и source device в scoped Realm row; errors журналируются. | Результат **app verification flow**. Не `isTrustedIdentity` из SignalStore. |
| `OmemoManager.authenticatedOMEMO2Sender(identity: Data, jid: String, deviceID: Int) throws -> OMEMOAuthenticatedSender` | Exact authenticated identity fingerprint + `isTrusted`. | Сравнивает fingerprint этой identity со scoped existing device: только `.trusted` + совпадение ключа → trusted. Realm failure → untrusted. Не выдаёт trust на основании membership/current session. |
| `TrustSharingSignature.canonicalString(for containers: [DDXMLElement]) -> String?` | Canonical string или `nil` при invalid timestamps/entries. | App сериализация подписываемого trust payload; Signal этого формата не знает. |
| `TrustSharingSignature.hashCanonicalString(_ canonical: String) -> Data` | SHA256 UTF8 canonical string, 32. | Именно этот digest передаётся в identity sign/verify. |
| `TrustSharingManager.checkItemSignature(jid: String, deviceId: Int, signature: Data, itemsList: [DDXMLElement]) -> Bool` | Bool signature check после canonicalization/identity lookup. | Вызывает app verify, O07 либо explicit legacy verifier. Успешная подпись сама по себе ещё не применяет список trust. |
| `TrustSharingManager.signCanonicalString(_ canonical: String) -> Data?` | Signature64 или `nil`. | Local identity lookup, digest выше, O03/O06. Private app helper. |

Callsites: [AKE trust/public-key methods](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/ake/AuthenticatedKeyExchangeManager.swift:599), [authenticated receive trust](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/OmemoManager.swift:1303), [trust canonicalization/hash](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/trust_sharing/TrustSharingManager.swift:28), [signature check](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/trust_sharing/TrustSharingManager.swift:188), [trust sign](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/trust_sharing/TrustSharingManager.swift:709).

Текущий trust-sharing admission проверяет namespace/usage, publisher/device ID, fingerprint, timestamp и signature. В [applyShare](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/trust_sharing/TrustSharingManager.swift:367) нет отдельного gate `publisher device.state == .trusted`; каталог не подтверждает полноту авторизации применения trust-решений. Certificate trust, кодовый exchange, полномочия изменения доверия, trust revocation, выбор разрешённых устройств и UI warnings принадлежат app. Одного O07 или S18 для этого недостаточно.

## 9. Шифрование целого сообщения и bundle lifecycle — HOST

Этот раздел дополняет список Signal: он показывает операции, которые **не выполняет** `OMEMO2Session`. Перечень host helpers здесь ориентир по границе ответственности, не полный каталог всех внутренних функций Xabber.

### 9.1. Основные app wrappers

| Функция / входы | Выход | Назначение / отказ |
| --- | --- | --- |
| `XabberOMEMO2Storage.prepare(deviceID: Int, preKeyCount: Int = 100) throws -> OMEMO2LocalBundle` | Public local bundle. | Создаёт/подготавливает aggregate, сохраняет identity/device continuity, SPK/signature и OPKs. Новая identity через O02 либо checked legacy scalar import O03. IDs/count проверяет app. |
| `XabberOMEMO2Storage.identity() throws -> OMEMO2IdentityKeyPair` | O2 identity. | O03 из protected scalar; storage error не означает key regeneration. |
| `XabberOMEMO2Storage.localBundle() throws -> OMEMO2LocalBundle` | IK, fingerprint public, SPK/ID/signature, список unconsumed public OPKs и deviceID. | Public representation из protected private material; не содержит private keys. |
| `XabberOMEMO2Storage.replenishPreKeys(minimumCount: Int = 100) throws -> OMEMO2LocalBundle` | Обновлённый public bundle. | O04 создаёт недостающие OPKs; IDs/consumed flags/persistence — app. |
| `XabberOMEMO2Storage.maintainKeysIfDue() throws -> Bool` | Был ли обновлён сохранённый key state. | App schedules SPK rotation/grace/pruning, O04/O06 создают pair/signature. |
| `OMEMO2PublishedBundle.selectedBundle(preKeyID: UInt32) throws -> OMEMO2Bundle` | O08 с выбранным OPK. | Lookup выбранного ID в public списке; absent → app error. |
| `OMEMO2BundleCodec.decode(item: DDXMLElement) throws -> OMEMO2PublishedBundle` | Public parsed bundle. | XML/Base64/IDs/namespace/count/uniqueness; validation каждого OPK через O08. |
| `OMEMO2BundleCodec.encode(_ value: OMEMO2PublishedBundle) throws -> DDXMLElement` | XML `<item>` с public `<bundle>`. | Проверка и сериализация public fields, без private bytes. |
| `OMEMO2BundleCodec.publication(_ bundle: OMEMO2PublishedBundle) throws -> DDXMLElement` | PubSub XML. | Подготавливает publication; подтверждение сервера/retry — другие app функции, не Signal. |
| `OmemoManager.doubleRatchet(hmac: Data, jid: String, deviceId: Int) throws -> DDXMLElement` | XML `<key rid=... [kex=true]>`. | Trust/identity/membership/opt-out gate, создание session при необходимости, storage encrypt O12. Имя `hmac` историческое: параметр — key48/control32, не только MAC. |
| `OmemoManager.encryptMessage(message: String, to jid: String) throws -> DDXMLElement?` | XML `<encrypted>` либо ошибка. | Подготовка SCE, payload seal один раз, per-device wrapping для trusted recipients/own devices. Нет trusted recipient → error. |
| `OmemoManager.makeOMEMO2Control(jid: String, deviceID: Int) throws -> XMPPMessage` | Empty control stanza. | O12 для zero32, без `<payload>`; network send/ACK scheduling — app. |
| `OmemoManager.decryptMessage(_ message: XMPPMessage, originalSendingTime: OMEMOOriginalSendingTime? = nil) throws -> DDXMLElement?` | Verified SCE envelope; `nil` для control/duplicate. | Explicit profile selection, candidate crypto receive, outer MAC/SCE validation. Ошибки не разрешают plaintext fallback. |

Источники: [storage preparation/lifecycle](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/storage/XabberOMEMO2Storage.swift:168), [bundle codec](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/OMEMO2BundleCodec.swift:80), [ratchet XML wrapper](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/OmemoManager+Encryption.swift:293), [whole-message sender](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/OmemoManager+Encryption.swift:369), [message receiver](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/OmemoManager.swift:1179).

### 9.2. Payload и используемые providers вне Signal

Источник: [Omemo2PayloadCodec.swift](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/Omemo2PayloadCodec.swift:136).

| App helper | Вход | Выход / смысл |
| --- | --- | --- |
| `secureRandom(_ count: Int) throws -> Data` | Положительное число bytes. | `count` CSPRNG bytes; RNG failure → `encryptionFailed`. |
| `seal(_ xml: String, randomBytes: (Int) throws -> Data = secureRandom) throws -> SealedPayload` | SCE XML в UTF8 и injectable RNG. | `{ciphertext: Data, keyAndMAC: Data}`; keyAndMAC48 для O12. Generated key32, payload HKDF/AES/HMAC выполняются здесь. |
| `openVerified(_ payload: Data?, keyAndMAC: Data, expectedFrom: String?, expectedTo: String?, requireTo: Bool = false, originalSendingTime: OMEMOOriginalSendingTime? = nil) throws -> OpenedPayload?` | Ciphertext payload + раскрытый material, ожидаемые app bindings. | `{envelope, content, timeValidation}`; `nil` только для отсутствующего payload + exact zero32 control. Проверяет MAC **до** decrypt, затем UTF8/XML/SCE/from/to/time. |
| `open(...) throws -> DDXMLElement?` | Те же параметры, что `openVerified`. | Envelope-only projection; `nil` control. |
| Private `derive(_ key: Data) throws -> [UInt8]` | Content key32. | HKDF output80: AES key32, HMAC key32, IV16. Это app helper, не Signal API. |

| Provider / используемая функция | Вход | Выход / назначение |
| --- | --- | --- |
| Security `SecRandomCopyBytes(kSecRandomDefault, count, buffer)` | RNG, число bytes, writable buffer. | `OSStatus` (`errSecSuccess` при успехе) и заполненный buffer. Payload key/padding и AKE IV; caller проверяет status. |
| CryptoSwift `HKDF(password:salt:info:keyLength:variant:).calculate()` | IKM content key32, salt zero32, info UTF8 `"OMEMO Payload"`, length80, SHA256. | `[UInt8]`80; `throws`. Payload key expansion. |
| CryptoSwift `CBC(iv:)` | IV16. | Block-mode object для AES. |
| CryptoSwift `AES(key:blockMode:padding:)` | Key32, CBC mode, `.pkcs7` для payload. | AES cipher object; `throws`. |
| CryptoSwift `aes.encrypt(_:)` | Plaintext `[UInt8]`. | Ciphertext `[UInt8]`, `throws`; с PKCS7 длина кратна16. |
| CryptoSwift `aes.decrypt(_:)` | Ciphertext `[UInt8]`. | Plaintext `[UInt8]`, `throws`; host отдельно проверяет authentication. |
| CryptoKit `SymmetricKey(data:)` | Symmetric key bytes. | Key object для HMAC. |
| CryptoKit `HMAC<SHA256>.authenticationCode(for:using:)` | Data и `SymmetricKey`. | Authentication code32; payload app передаёт первые16 в ratchet envelope. AKE HMAC использует полный digest. |
| CryptoKit `SHA256.hash(data:)` | Произвольная `Data`. | Digest32; trust-sharing digest, AKE key derivation, bundle/replay digest. |
| Curve25519Kit `Ed25519.verifySignature(signature, publicKey: publicKey, data: data)` | Signature64, **legacy raw Curve25519** public32, signed bytes. | `Bool`; explicit legacy verification. Это отдельная зависимость с историческим naming; не O2 Ed32 API и не CryptoKit Ed25519 verifier. |

Публичный legacy verifier: [Ed25519.h](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/Pods/Curve25519Kit/Classes/Ed25519.h:35), callsite [Omemo2IdentityRepresentation.verify](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/omemo/Omemo2IdentityRepresentation.swift:123). Этот header описывает inputs/signature64/Bool и содержит неполное упоминание exception, без полноценного контракта её типа/условий. App wrapper отсекает неправильные длины до вызова, но не превращает ObjC exception в Swift `throws`.

AKE также вызывает эти AES/RNG/hash/HMAC providers: [AuthenticatedKeyExchangeManager.swift](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber/xmpp/ake/AuthenticatedKeyExchangeManager.swift:1209). Его `calculateSharedKey(jid:deviceId:) -> [UInt8]?` использует C08 через app wrapper; `calculateEncryptionKey(sharedKey:code:sid:) -> [UInt8]` получает SHA256 от shared bytes и app verification context. Это code-verification flow Xabber, отдельный от Double Ratchet.

### 9.3. Обозримые границы транзакций

1. **Public bundle:** O04/O06 дают материал; app назначает IDs/rotation policy, сохраняет private records и публикует только public fields. Library не выполняет PEP запросов.
2. **Outgoing:** app один раз `seal`s payload, затем O12 оборачивает key48 отдельно для каждой session. O14 + protected save должны завершиться до выпуска ciphertext. Network retry и multi-device partial failures принадлежат host.
3. **Incoming:** O15 parse → O10 для первого KEX либо O13 существующей session → outer MAC/payload/SCE validation → save snapshot + OPK consumed/replay state → использование plaintext и exact peer identity. Повторный KEX с известным EK обрабатывается существующей session.
4. **Trust:** successful parse ≠ authenticated peer; successful signature/decrypt ≠ user trust. Для outgoing recipients требуется app trust/key binding; incoming может быть криптографически корректным и помечаться untrusted.

## 10. Ошибки и отказ

Общий публичный enum: [SignalError.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC/Classes/Utility/SignalError.h:13). C constants: [signal_protocol.h](/Users/igor.boldin/projects/xabber/deps/SignalProtocolC/src/signal_protocol.h:19). Это доступные классы ошибок, **не исчерпывающая таблица достижимых ошибок для каждого метода**.

| Swift `SignalError` / raw value | C constant / value | Смысл класса |
| --- | --- | --- |
| `.unknown` / 0 | `SG_ERR_UNKNOWN` / −1000 | Неуточнённая ошибка. |
| `.noMemory` / 1 | `SG_ERR_NOMEM` / −12 | Ошибка выделения памяти. |
| `.invalidArgument` / 2 | `SG_ERR_INVAL` / −22 | Недопустимый аргумент. |
| `.duplicateMessage` / 3 | `SG_ERR_DUPLICATE_MESSAGE` / −1001 | Повтор уже обработанного пакета. |
| `.invalidKey` / 4 | `SG_ERR_INVALID_KEY` / −1002 | Недопустимый ключ. |
| `.invalidKeyId` / 5 | `SG_ERR_INVALID_KEY_ID` / −1003 | Недопустимый/недоступный key ID. |
| `.invalidMAC` / 6 | `SG_ERR_INVALID_MAC` / −1004 | Не прошла authentication tag/MAC проверка. |
| `.invalidMessage` / 7 | `SG_ERR_INVALID_MESSAGE` / −1005 | Недопустимый message. |
| `.invalidVersion` / 8 | `SG_ERR_INVALID_VERSION` / −1006 | Недопустимая protocol version. |
| `.legacyMessage` / 9 | `SG_ERR_LEGACY_MESSAGE` / −1007 | Legacy message error. |
| `.noSession` / 10 | `SG_ERR_NO_SESSION` / −1008 | Нет session. |
| `.staleKeyExchange` / 11 | `SG_ERR_STALE_KEY_EXCHANGE` / −1009 | Устаревший/неподходящий exchange. |
| `.untrustedIdentity` / 12 | `SG_ERR_UNTRUSTED_IDENTITY` / −1010 | Identity не допущена trust callback/policy. |
| `.invalidProtoBuf` / 13 | `SG_ERR_INVALID_PROTO_BUF` / −1100 | Ошибка protobuf structure. |
| `.fingerprintVersionMismatch` / 14 | `SG_ERR_FP_VERSION_MISMATCH` / −1200 | Несовпадение fingerprint version. |
| `.fingerprintIdentityMismatch` / 15 | `SG_ERR_FP_IDENT_MISMATCH` / −1201 | Несовпадение fingerprint identity. |
| В ObjC enum отдельного члена нет | `SG_ERR_VRF_SIG_VERIF_FAILED` / −1011 | C VRF verification error; app напрямую этот код не обрабатывает. |

Для int-status API `SG_SUCCESS = 0`; Swift enum `.unknown.rawValue == 0` означает **ошибку unknown**, а не успешный C status. Нельзя смешивать эти числовые пространства.

`SignalErrorDomain` — публичная константа `"org.whispersystems.SignalProtocol"`. App прямо использует её с `.duplicateMessage.rawValue` для terminal duplicate в legacy receiver. Public conversion helpers `SignalErrorFromCode`, `SignalErrorDescription`, `ErrorFromSignalErrorCode`, `ErrorFromSignalError` не вызываются напрямую app/Swift XCTest (U); mapping конкретных O2 failures из внутреннего code здесь не исследован.

Вне Signal app имеет собственные `OMEMO2StorageError`, `OmemoManagerError`, `OMEMO2BundleCodec.Error` и `Omemo2IdentityRepresentationError`. Например storage недоступен/сессия отсутствует, payload MAC не прошёл, устройство не trusted или bundle profile не тот — это не обязательно library `SignalError`. Host должен сохранить различие между parser/crypto/storage/policy failure.

## 11. Что не входит в действующий список

| Найденный API/код | Причина исключения из active inventory |
| --- | --- |
| `SignalStorage.initWithSessionStore:preKeyStore:signedPreKeyStore:identityKeyStore:senderKeyStore:` | U; public alternative constructor из пяти разных stores; app пользуется L01. |
| `SignalCommonCryptoProvider.cryptoProvider() -> signal_crypto_provider` и 11 public C crypto-provider callbacks | U как direct app API. App не создаёт provider callbacks и не регистрирует их напрямую. По headers нельзя восстановить внутренний граф вызовов wrapper. |
| `SignalMessage`, `SignalPreKeyMessage` constructors | Не найдено прямых app/Swift XCTest вызовов; legacy receive пользуется `SignalCiphertext`. Некоторые headers private. |
| C session/wire/protobuf/key-helper/store-registration APIs | Не вызываются напрямую app/Swift XCTest. Не требуется переносить внутреннюю C-структуру для замены consumer boundary. |
| `OmemoManager.generatePreKeys() throws -> [SignalPreKey]` | U/dead app helper, нет caller. Создаёт 101 default `SignalPreKey()`, не вызывает key generator; нельзя считать рабочей генерацией. |
| `OmemoManager.doubleUnratched(_:jid:deviceId:keyExchange:) throws -> Data` | U/dead app wrapper; parser/decrypt внутри есть, но caller не найден. |
| Старый файл `OmemoManagerTest.swift`: `SignalClient`/`SignalCoreKit`, `InMemorySignalProtocolStore`, `ProtocolAddress`, `PrivateKey.generate`, `PreKeyRecord`, `SignedPreKeyRecord`, `PreKeyBundle`, `processPreKeyBundle`, `signalEncrypt`, `signalDecryptPreKey`, `PreKeySignalMessage.serialize` | **Исторический файл вне target membership**; этих зависимостей нет в действующем Podfile/lock. Его точные актуальные library signatures не подтверждены; не смешивать со списком C/ObjC выше. |

Проверка membership: [project.pbxproj](/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber.xcodeproj/project.pbxproj:3821) содержит explicit `omemo` group; упоминаний `OmemoManagerTest.swift` нет. Auto-synced source group относится к push extension. Неподключённый код нельзя считать функциями текущего backend.

## 12. Как использовать этот каталог для независимой библиотеки

Каталог фиксирует **60 записей вызываемых операций/инициализаторов/receiver-вариантов/callbacks**: O01–O15, C01–C08, L01–L13, T01–T04 и S01–S20. Дополнительно перечислены используемые getters и явно отмеченные unused members. Это не число внутренних функций Signal и не требование воспроизводить 60 одинаковых entrypoints.

Новая библиотека должна предоставлять необходимые **возможности**, а свой API, snapshot/state format и tests проектировать независимо. Текущие app integration требования и алгоритмические стандарты имеют разные роли:

| Наблюдаемая потребность consumer | Что нужно обеспечить собственной реализацией |
| --- | --- |
| Identity, DH pairs, SPK/OPK, arbitrary-byte signature/verify | Независимые key types и primitive operations; явное различие private/public representations. |
| Public bundle list и selected peer material | Генерация/проверка public material без private leakage; криптографическая проверка отдельно от trust/address assignment. |
| Initiator/responder session | Establishment по выбранному опубликованному профилю; authenticated first packet, подтверждённое OPK consumption event. |
| Stateful encrypt/decrypt | Собственная ratchet state machine, обработка порядка/replay, отказ без повреждения committed state. |
| Whole payload + per-session key wrapping | Универсальные binary payload operations; fanout association, XML/SCE/PEP остаются внешним consumer. |
| Restart | Собственный versioned protected snapshot contract; persistence/serialization/CAS/rollback policy у host. |
| Exact peer identity after successful receive | Crypto library возвращает достаточное доказанное identity metadata; app отдельно применяет trust. |
| Legacy records и adapters | Их текущая интеграция описана для полноты. Обратная совместимость с legacy Signal state не является требованием согласованного независимого package. |

Для алгоритмов использовать первичные нормативные источники, проверенные 2026-10-12:

- [XEP-0384 OMEMO Encryption, 0.9.1 (2026-04-06)](https://xmpp.org/extensions/xep-0384.html): выбранный криптографический профиль, wire/bundle/envelope requirements; app transport следует отделять от reusable core.
- [The X3DH Key Agreement Protocol](https://signal.org/docs/specifications/x3dh/): опубликованное описание agreement, не код библиотеки.
- [The Double Ratchet Algorithm, revision 4 (2025-11-04)](https://signal.org/docs/specifications/doubleratchet/): для этого профиля нужен классический раздел 3 с конкретизацией OMEMO; новые PQ-разделы не означают автоматическую смену профиля.
- [RFC 7748](https://www.rfc-editor.org/rfc/rfc7748), [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032), [RFC 5869](https://www.rfc-editor.org/rfc/rfc5869): primitive/encoding/KDF определения и независимые стандартные векторы.

## 13. Проверка документа и пределы результата

- Инвентаризация выполнена по production source и подключённым Swift XCTest, публичным headers и pinned dependency revisions. Три независимых read-only обзора покрыли keys/bundles/C calls, sessions/ciphertext и stores/trust.
- Проверены полнота прямых API в этой границе, типы/входы/выходы, callbacks, пометки active/legacy/test/unused, локальные ссылки и Markdown diff.
- Production Swift/ObjC/C, зависимости и `XabberCryptoSwift` не изменялись. Новый build/test для документационного аудита не запускался.
- Это справочник публичной интеграции, а не новое подтверждение runtime conformance, security review или live interoperability. Existing XCTest упомянуты как источник callsites; их library-generated fixtures не становятся источником независимых expected outputs.
