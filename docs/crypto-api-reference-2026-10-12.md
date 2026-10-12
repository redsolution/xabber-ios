# Методы и интерфейсы криптографической библиотеки

Дата: **2026-10-12**. Профиль: **OMEMO 2**; операции совместимости с прежним профилем выделены отдельно.

Справочник описывает генерацию и импорт ключей, подписи, bundles, создание сессий, шифрование, дешифрование, сериализацию, хранение и доверие. Для каждой операции указаны входы, выходы, назначение и существенные эффекты.

**Имена типов, методов, callbacks и ошибок ниже — условные обозначения операций текущей интеграции.** Они не являются точными исходными именами, существующим API или утверждённым API будущей библиотеки. Swift-подобные и C-подобные записи служат для объяснения контрактов; их нельзя использовать как готовые декларации подключаемого пакета.

Сведения получены из вызовов приложения, публичных контрактов подключённых криптографических слоёв и существующих тестов. Нейтральное именование не изменяет происхождение сведений. Это функциональный каталог интеграции, а не свидетельство независимой разработки реализации. Алгоритмы и wire-форматы собственной реализации следует выводить из опубликованных стандартов.

## 1. Область и обозначения

| Метка | Значение |
| --- | --- |
| **O2** | Операция текущего профиля OMEMO 2. |
| **L** | Операция совместимости: прежняя identity, первоначальная подготовка или чтение старой истории. |
| **T** | Дополнительная операция, вызываемая только подключёнными тестами. |
| **U** | Доступная операция или поле без найденного вызова/чтения в приложении и его тестах. |
| **HOST** | Операция приложения или внешнего provider, вне криптографического ядра. |

Каталог охватывает прямые операции приложения и тестов, обязательные callbacks хранения и читаемые свойства. Внутренний граф функций криптографических слоёв и автоматически вызываемые служебные методы не перечисляются.

`Data` — бинарные bytes; `NSData` — их ObjC-представление. Base64 — транспортное кодирование bytes. `UInt32` соответствует `uint32_t`, `Int32` — `int32_t`, `UInt` — `NSUInteger`. Все длины указаны в **байтах**. IK — долговременная identity; SPK — signed prekey; OPK — one-time prekey; EK — ephemeral key первого обмена; DH — согласование секрета.

В условных Swift-подобных записях `throws` означает канал отказа операции. В наблюдаемом ObjC bridge nullable result + `NSError **` соответствует throwing-вызову; `BOOL` с error output может импортироваться как `Void` при успехе и `throw` при отказе. У старых helpers без error output сохраняется optional/обычный результат.

### Карта интерфейсов — условные обозначения

| Интерфейс | Ответственность | Метка |
| --- | --- | --- |
| `CryptoContext` | Генерация/импорт ключей, подпись/проверка, establishment и restore. | O2 |
| `IdentityKeyPair`, `AgreementKeyPair` | Раздельный public/private материал. | O2 |
| `SelectedPeerBundle` | Проверенный public материал peer с одним выбранным OPK. | O2 |
| `KeyEnvelope` | Разбор бинарного пакета, содержащего зашифрованный key material. | O2 |
| `CryptoSession` | Ratchet, key-envelope encrypt/decrypt и секретный snapshot. | O2 |
| `CompatibilityStoreAdapter`, `CompatibilityContext` | Подключение callbacks и контекста прежнего профиля. | L |
| `CompatibilityKeyGenerator`, `CompatibilityKeyPair`, `CompatibilityIdentityKeyPair`, `CompatibilityPreKey`, `CompatibilitySignedPreKey` | Генерация и records прежнего профиля. | L |
| `SessionLocator`, `CompatibilityEnvelope`, `CompatibilityCipher` | Lookup сессии и чтение старой истории. | L/T |
| `CompatibilitySelectedBundle`, `CompatibilitySessionBuilder` | Дополнительное establishment прежнего профиля для test fixtures. | T |
| `RecordCoding` | Кодирование секретных records прежнего профиля. | L/T |
| `CompatibilityStore` и пять протоколов хранения | 20 обратных вызовов хранения/identity continuity/group sender records. | L |

## 2. O2: ключи, импорт, подпись и bundles

### 2.1. Методы `CryptoContext`

| № | Метод и входные параметры | Выход | Назначение, ошибки и эффект |
| --- | --- | --- | --- |
| O01 | `createContext()`; полезных параметров нет. | Новый `CryptoContext`; ошибка через `throws`. | Создаёт явный provider OMEMO2; не получает `CompatibilityStoreAdapter`, адреса и account. Инициализация может отказать. |
| O02 | `context.generateIdentity()` — без параметров. | `IdentityKeyPair`; `throws`. | Генерирует долговременную identity. Public wire IK — Ed25519 32; private — локальный X25519 scalar 32. Есть генерация случайного материала; библиотека не сохраняет его и не назначает устройству. |
| O03 | `context.identity(withPrivateKey: privateKey)`; `privateKey: Data`, 32. | `IdentityKeyPair`; `throws`. | Восстанавливает identity/public representations из private scalar. Это **не импорт Ed25519 seed**. Используется при migration, restore и подписи; invalid material отклоняется. |
| O04 | `context.generateKeyPair()` — без параметров. | `AgreementKeyPair`; `throws`. | Генерирует X25519 пару для SPK/OPK. Метод не назначает ID, timestamp, срок жизни или подпись; это делает host. |
| O05 | `context.keyPair(withPrivateKey: privateKey)`; `privateKey: Data`, 32. | `AgreementKeyPair`; `throws`. | Восстанавливает X25519 пару SPK/OPK из private scalar. Используется для private key lookup при первом входящем KEX и для public bundle. |
| O06 | `context.sign(data, identity: identity)`; `data: Data`, произвольные байты; `identity: IdentityKeyPair`. | `Data`, подпись 64; `throws`. | Подписывает **переданные байты** identity, даёт Ed25519-совместимую подпись локального профиля. Для SPK app передаёт raw public SPK 32; для trust sharing — заранее рассчитанный digest. Не выполняет app canonicalization и не устанавливает доверие. |
| O07 | `CryptoContext.verifySignature(signature, data: data, identityKey: identityKey)`; `signature: Data`, 64; `data: Data`; `identityKey: Data`, wire Ed25519 32. | Swift `Void` при успехе; `throws` при отказе. ObjC `BOOL`. | Проверяет подпись именно этих байтов под именно этой identity. Bad signature/key/shape даёт отказ. Успех не подтверждает принадлежность IK контакту и не меняет trust/storage. |

### 2.2. Читаемые поля key-pair объектов

Все перечисленные поля доступны только для чтения; входных параметров нет. Пары ключей создаются генерацией либо явным импортом.

| Класс / поле | Выход | Для чего читает Xabber |
| --- | --- | --- |
| `IdentityKeyPair.publicKey` | `Data`, Ed25519 wire IK 32. | `<ik>`, signature verification, session identity binding. |
| `IdentityKeyPair.fingerprintPublicKey` | `Data`, raw X25519 public 32. | Проверка continuity legacy identity и app fingerprint. Это public key, не готовая строка fingerprint и не digest. |
| `IdentityKeyPair.privateKey` | `Data`, X25519 private scalar 32. | Защищённое хранение и последующее восстановление/подпись/DH. |
| `AgreementKeyPair.publicKey` | `Data`, raw X25519 32. | Подпись public SPK и публикация public SPK/OPK. |
| `AgreementKeyPair.privateKey` | `Data`, X25519 private scalar 32. | Защищённое хранение private SPK/OPK и их восстановление. |

### 2.3. `SelectedPeerBundle`: один выбранный OPK

```swift
// Условная Swift-подобная запись создания выбранного bundle.
try SelectedPeerBundle(
    identityKey: Data,     // wire Ed25519 IK, 32
    signedPreKey: Data,    // raw X25519 public SPK, 32
    signedPreKeyID: UInt32,
    signature: Data,       // подпись public SPK, 64
    preKey: Data,          // raw X25519 public выбранного OPK, 32
    preKeyID: UInt32
)
```

**O08.** Выход — `SelectedPeerBundle`; при недопустимом материале — `throw` (ObjC `nil` + `NSError`). Операция создания проверяет длины/ключи, обязательный OPK, подпись SPK и положительные 31-битные IDs `1...2^31−1`. Проверка подписи не равна доверенной принадлежности identity. Здесь нет private key, device ID, JID, XML, списка OPKs или публикации на сервере.

`SelectedPeerBundle` публикует `readonly` поля без аргументов:

| Поле | Выход | Статус / смысл |
| --- | --- | --- |
| `identityKey` | `Data`, 32 | O2/T; исходная wire IK peer. |
| `signedPreKey` | `Data`, 32 | O2/T; public SPK, используется и для digest fresh bundle. |
| `signedPreKeyID` | `UInt32` | O2/T; ID SPK peer. |
| `signature` | `Data`, 64 | O2/T; подпись SPK. |
| `preKey` | `Data`, 32 | O2/T; public выбранного OPK; app сохраняет связь с outgoing session. |
| `preKeyID` | `UInt32` | O2/T; ID выбранного OPK. |

**Публичный bundle со списком ключей** — host-структуры `OMEMO2LocalBundle`/`OMEMO2PublishedBundle`, а не этот library object. App проверяет каждый опубликованный OPK через отдельный `SelectedPeerBundle`.

## 3. O2: сессии, шифрование и дешифрование

### 3.1. Создание, приём и restore

| № | Метод и входы | Выход | Что делает и что остаётся host |
| --- | --- | --- | --- |
| O09 | `context.initiateSession(withIdentity: identity, bundle: bundle)`; локальная `IdentityKeyPair`, проверенный peer `SelectedPeerBundle`. | Новая `CryptoSession`; `throws`. | Инициирует криптографическую сессию; её первые пакеты несут KEX до подтверждения. Caller выбирает peer/OPK, применяет trust и сохраняет сессию. Никакого network send. |
| O10 | `context.acceptKeyExchange(ciphertext, identity: identity, signedPreKey: spk, signedPreKeyID: spkID, preKey: opk, preKeyID: opkID, plaintext: &output)`; `ciphertext: KeyEnvelope` с KEX; локальная identity; private/public пары `AgreementKeyPair` для SPK/OPK; IDs `UInt32`; `output: NSData?` — выходной pointer. | `CryptoSession` **и** `output` с plaintext key material; `throws`. | Создаёт responder session только после аутентификации первого KEX. Parsed IK ещё не доверенная IK. Lookup private keys, внешняя payload validation, сохранение snapshot и отметка OPK consumed принадлежат app; consumption нельзя делать до проверки. |
| O11 | `context.restoreSession(with: snapshot)`; `snapshot: Data`. | Восстановленная `CryptoSession`; `throws`. | Читает versioned **секретный O2 snapshot**, не record прежнего профиля. Host отвечает за owner/session association, защищённое хранение и отсутствие rollback. Restore не подтверждает доверие к peer. |


### 3.2. Методы `CryptoSession`

| № | Метод и входы | Выход | Назначение и изменение состояния |
| --- | --- | --- | --- |
| O12 | `session.encryptData(data)`; `data: Data`: **48** байт `payloadKey32 \|\| payloadMAC16` или ровно **32 нулевых** байта для empty control. | `KeyEnvelope`; `throws`. | Шифрует key envelope выбранной сессией; после успеха ratchet/counters изменены. Не шифрует XML/текст целого сообщения и не выбирает recipients. Snapshot необходимо сохранить перед выпуском outgoing ciphertext. |
| O13 | `session.decryptCiphertext(ciphertext)`; parsed `KeyEnvelope`. | `Data`; app ожидает key material 48 или control zero32; `throws`. | Проверяет криптографический пакет, расшифровывает и после успеха продвигает ratchet. Parsing/authentication failure не меняет state согласно публичному контракту. Успех ещё не подтверждает MAC отдельного payload, SCE bindings или trust; допустимый размер plaintext дополнительно проверяет app. |
| O14 | `session.serializedData()` — без параметров. | `Data`, secret versioned snapshot; `throws`. | Экспортирует текущее криптографическое состояние для restart. Это не wire ciphertext/public bundle; его нельзя публиковать или декодировать как legacy record. |

Наблюдаемый контракт синхронизирует calls **одного** `CryptoSession` object. Несколько отдельно restored objects могут работать с одной сохранённой сессией: host обязан сериализовать их read/advance/save. После успеха decrypt library object уже продвинут; app использует **восстановленный candidate**, выполняет `validating(plaintext)` и лишь затем сохраняет snapshot/consumed OPK. Reject отдельного payload не должен сохранять candidate. Protected save не покрывает автоматически network send и запись истории в другой store.

### 3.3. Поля `CryptoSession`

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

### 3.4. `KeyEnvelope`

**O15.** `try KeyEnvelope(data: Data, keyExchange: Bool)` — разбирает binary protobuf envelope. Выход — `KeyEnvelope`; malformed bytes/shape дают `throw`. `keyExchange` сообщает ожидаемый тип envelope; приложение получает его из validated transport `<key kex=...>`. Сам парсер **не аутентифицирует** peer и не устанавливает trust. Пакет должен создаваться явным разбором bytes либо шифрованием.

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

## 4. Низкоуровневые операции ключей и lifetime

Имена и C-подобные объявления ниже условные; это описание границы ответственности, а не существующий C ABI.

```c
int crypto_context_create(CryptoContextHandle **context, void *user_data);
void crypto_context_destroy(CryptoContextHandle *context);
void crypto_object_release(CryptoObjectHandle *instance);
int crypto_identity_public_key_decode(PublicKeyHandle **key, const uint8_t input[32], CryptoContextHandle *context);
int crypto_public_key_encode(uint8_t output[32], const PublicKeyHandle *key);
int crypto_public_key_decode(PublicKeyHandle **key, const uint8_t input[32], CryptoContextHandle *context);
int crypto_private_key_decode(PrivateKeyHandle **key, const uint8_t *input, size_t length, CryptoContextHandle *context);
int crypto_calculate_agreement(uint8_t output[32], const PublicKeyHandle *public_key, const PrivateKeyHandle *private_key);
```

| № | Операция и входы | Выходы и ownership | Назначение / отказ |
| --- | --- | --- | --- |
| C01 | `crypto_context_create`; `context` — выходной pointer, `user_data` — opaque caller value, в наблюдаемом вызове `nil`. | Status 0 при успехе / отрицательный код; новый handle через `*context`. | Создать контекст. Caller проверяет non-null результат и обеспечивает C02. |
| C02 | `crypto_context_destroy(context)`; созданный context handle. | `void`; handle больше не используется. | Освободить context. |
| C03 | `crypto_object_release(instance)`; refcounted key/object handle. | `void`; снять ссылку, последняя освобождает объект. | Управлять lifetime; это не удаление prekey из persistent store. |
| C04 | `crypto_identity_public_key_decode`; wire Ed25519 IK32, context, выходной key pointer. | Status и новый public handle; caller освобождает через C03. | Декодировать identity для agreement representation; не устанавливает trust. |
| C05 | `crypto_public_key_encode`; public handle и writable output32. | Status и raw X25519 public32. | Экспортировать agreement public bytes без prefix; применяется после C04. |
| C06 | `crypto_public_key_decode`; raw X25519 public32, context, выходной pointer. | Status и public key handle; ownership C03. | Импортировать public peer point для DH. |
| C07 | `crypto_private_key_decode`; private bytes, explicit length, context, выходной pointer. | Status и private key handle; ownership C03. | Импортировать private scalar; приложение проверяет length32 перед вызовом. |
| C08 | `crypto_calculate_agreement`; peer public handle, local private handle и output32. | Status и shared secret32. | DH; наблюдаемый контракт отклоняет all-zero secret и очищает output при failure. KDF выполняется отдельно. |

В C параметр `input[32]`/`output[32]` в ABI является pointer, а не автоматически проверяемым массивом. Размер буфера и длину `Data` до unsafe call обеспечивает caller. Наблюдаемый status adapter принимает только 0 и переводит остальные коды в ошибку криптографической операции.

## 5. Прежний криптографический профиль: контекст, ключи и records

Этот раздел описывает операции высокоуровневого адаптера прежнего профиля. Legacy identity/bootstrap остаётся переходным источником текущего приложения; исходящая production-переписка использует O2. Новый независимый package не обязан поддерживать старые records/scalar identity/history.

### 5.1. Создание контекста и адреса

| № | Используемый вызов / вход | Выход / ошибки | Назначение и статус |
| --- | --- | --- | --- |
| L01 | `CompatibilityStoreAdapter(store: store)`; `store: CompatibilityStore`, в app `XabberAxolotlStorage`. | Nonoptional `CompatibilityStoreAdapter`; без `NSError`/`throws`. | L; подключает один объект, реализующий пять callback-протоколов. |
| L02 | `CompatibilityContext(storage: storage)`; `CompatibilityStoreAdapter`. | `CompatibilityContext?`; `nil` при отказе, без `NSError`/`throws`. | L; создаёт legacy context со storage; production force-unwrap. |
| L03 | `SessionLocator(name: name, deviceId: deviceId)`; `name: String`, app bare JID; `deviceId: Int32`. | Nonoptional `SessionLocator`; без typed error. | L; идентифицирует peer/device для session/identity store. Нормализация имени/owner scoping — host. |
| L04 | `CompatibilityKeyGenerator(context: context)`; `CompatibilityContext`. | `CompatibilityKeyGenerator?`; `nil` при отказе, без `NSError`/`throws`. | L; generator legacy identity/prekeys; не сохраняет их в app автоматически. |

### 5.2. Генерация и импорт

| № | Метод / входные параметры | Выход | Комментарий |
| --- | --- | --- | --- |
| L05 | `helper.generateIdentityKeyPair()` — без аргументов. | `CompatibilityIdentityKeyPair?`; без `throws`. | L; генерирует legacy identity. В app public encoding — `0x05 \|\| raw X25519` (33), private scalar 32. Production force-unwrap. |
| L06 | `helper.generatePreKeys(withStartingPreKeyId: start, count: count)`; `start: UInt`, `count: UInt`. | `[CompatibilityPreKey]`; без `NSError`/`throws`. | L; массив legacy OPK records с IDs и private/public pair. Production передаёт `start=1`, `count=100`. Наблюдаемый контракт не определяет полноту результата при partial generation failure. |
| L07 | `helper.generateSignedPreKey(withIdentity: identity, signedPreKeyId: id)`; `identity: CompatibilityIdentityKeyPair`, `id: UInt32`. | `CompatibilitySignedPreKey?`; без `throws`. | L; создаёт SPK keypair и подпись supplied identity, ID/timestamp record. Production ID=1 и force-unwrap результата. Не смешивать legacy signature profile с wire O2 signing. |
| L08 | `try CompatibilityIdentityKeyPair(publicKey: publicKey, privateKey: privateKey)`; оба `Data`: legacy public33, private32. | `CompatibilityIdentityKeyPair`; `throws` (ObjC nullable + error). | L; унаследованный `CompatibilityKeyPair.initWithPublicKey:privateKey:error:` восстанавливает legacy pair. Header сам по себе не обещает проверку correspondence public/private; app отдельно выводит O2 fingerprint public из scalar и сравнивает. |
| L09 | `preKey.serializedData()`; receiver `CompatibilityPreKey`, без аргументов. | `Data?`; без error output. | L/T; opaque secret legacy PreKey record для store, **не public preKey bytes**. |
| L10 | `signedPreKey.serializedData()`; receiver `CompatibilitySignedPreKey`, без аргументов. | `Data?`; без error output. | L/T; opaque secret signed-prekey record для store, **не public bundle**. |

L09/L10 используют контракт `RecordCoding`. Дополнительная операция восстановления record из serialized bytes существует в прежнем интерфейсе, но прямых app/test вызовов не найдено (U). Не включать её в перечень реально вызываемых entrypoints.

### 5.3. Поля legacy объектов

Все перечисленные поля `readonly`, без входных параметров. Поля `keyPair` могут быть `nil`; app обязан отличать это от существующей key pair.

| Поле | Выход | Использование / смысл |
| --- | --- | --- |
| `SessionLocator.name` | `String` | L/T; имя peer для storage callback. |
| `SessionLocator.deviceId` | `Int32` | L/T; device ID для storage callback. |
| `CompatibilityKeyPair.publicKey`, в том числе у `CompatibilityIdentityKeyPair` | `Data`, в app legacy33 | L/T; public legacy identity/SPK/OPK для app projection или test bundle. |
| `CompatibilityKeyPair.privateKey`, в том числе у `CompatibilityIdentityKeyPair` | `Data`, в app32 | L/T; private scalar для credentials. |
| `CompatibilityPreKey.preKeyId` | `UInt32` | L/T; ID OPK record. |
| `CompatibilityPreKey.keyPair` | `CompatibilityKeyPair?` | L/T; public/private пара OPK. |
| `CompatibilitySignedPreKey.preKeyId` | `UInt32` | L/T; ID SPK record; имя поля тоже `preKeyId`. |
| `CompatibilitySignedPreKey.signature` | `Data` | L/T; legacy подпись SPK, не O2 wire подпись автоматически. |
| `CompatibilitySignedPreKey.keyPair` | `CompatibilityKeyPair?` | L/T; public/private SPK пара. |
| `CompatibilitySignedPreKey.timestamp` | `Date` | U; доступен в наблюдаемой интеграции, app/test Swift чтение не найдено. |
| `CompatibilityContext.storage` | `CompatibilityStoreAdapter` | U; публичная ссылка context→store, прямое чтение не найдено. |
| `CompatibilityKeyGenerator.context` | `CompatibilityContext` | U; public helper→context, прямое чтение не найдено. |

`CompatibilityKeyGenerator.generateRegistrationId() -> UInt32` **не вызывается (U)**. Header описывает 0 как failure. Текущий app сам выбирает registration ID через `arc4random_uniform(...) + 1`, с лимитом 16380. Registration ID и OMEMO device ID — разные сущности; O2 bundle выше registration ID не содержит.

## 6. Прежний криптографический профиль: дешифрование истории и тестовая отправка

### 6.1. Production history receive

| № | Вызов / входы | Выход / ошибки | Назначение и эффект |
| --- | --- | --- | --- |
| L11 | `CompatibilityCipher(address: address, context: context)`; `SessionLocator`, legacy `CompatibilityContext`. | Nonoptional `CompatibilityCipher`; без typed error в initializer. | L; cipher привязан к peer/device и callback storage. |
| L12 | `CompatibilityEnvelope(data: data, type: type)`; `data: Data`, `type: CompatibilityEnvelopeType`. | Nonoptional `CompatibilityEnvelope`; без typed error. | L; container legacy bytes с ожидаемым видом `.preKeyMessage` или `.message`. Наблюдаемый initializer не обещает parsing/authentication. |
| L13 | `try cipher.decryptCiphertext(ciphertext)`; `CompatibilityEnvelope`. | Plaintext `Data`; `throws`. | L; аутентифицирует/дешифрует legacy packet. Legacy store callbacks могут продвинуть persisted state до последующей проверки external payload. Это не O2 candidate transaction. |

Текущий receiver выбирает L-путь только для `data.first == 0x33` и существующей legacy session. O2 authentication failure не переключает профиль. Производственного построения новых outgoing legacy сессий не найдено.

`CompatibilityEnvelopeType` содержит `.unknown = 0`, `.message = 1`, `.preKeyMessage = 2`. App использует последние два; это тип container, не байтовое значение version header.

| Читаемый getter | Выход | Статус |
| --- | --- | --- |
| `CompatibilityEnvelope.type` | `CompatibilityEnvelopeType` | T; fixture выбирает transport `kex` flag. |
| `CompatibilityEnvelope.data` | `Data` | T; fixture переносит legacy wire bytes в XML. |
| `CompatibilityCipher.address` | `SessionLocator` | T; создание legacy builder и проверка сохранённой session. |
| `CompatibilityCipher.context` | `CompatibilityContext` | U; прямое чтение не найдено. |

### 6.2. Дополнительные вызовы XCTest

Эти вызовы нужны для fixture старой истории в OMEMO2SCEReceiveTests.swift; это не production sender.

**T01.** `try CompatibilitySelectedBundle(registrationId: UInt32, deviceId: UInt32, preKeyId: UInt32, preKeyPublic: Data, signedPreKeyId: UInt32, signedPreKeyPublic: Data, signature: Data, identityKey: Data)`.

- Вход: registration/device IDs peer; один OPK ID/public; SPK ID/public/signature; public IK. Legacy public bytes fixture берёт из generated `CompatibilityKeyPair`.
- Выход: `CompatibilitySelectedBundle`; ObjC nullable + `NSError`, в Swift `throws`.
- Смысл: собирает legacy материал peer для session builder. Наблюдаемый контракт не даёт полного validation contract; нельзя приписывать ему проверки O2 constructor.
- Его readonly getters `registrationId`, `deviceId`, `preKeyId`, `preKeyPublic`, `signedPreKeyId`, `signedPreKeyPublic`, `signature`, `identityKey` имеют те же типы; прямого чтения их из app/Swift XCTest не найдено (U). Передача объекта builder не равна прямому app-чтению getter.

| № | Вызов / входы | Выход | Смысл / эффект |
| --- | --- | --- | --- |
| T02 | `CompatibilitySessionBuilder(address: SessionLocator, context: CompatibilityContext)` | Nonoptional builder, без typed error. | Привязывает legacy session builder к peer/context. |
| T03 | `try builder.processPreKeyBundle(bundle)`; `bundle: CompatibilitySelectedBundle`. | Swift `Void`, ObjC `BOOL`; при отказе `throws`. | Создаёт outgoing legacy session через callback stores. Нельзя выдавать за active O2 establishment. |
| T04 | `try cipher.encryptData(data)`; произвольная plaintext `Data`. | `CompatibilityEnvelope`; `throws`. | Legacy session encryption, state/store advance. В fixture обрабатывает bootstrap text и затем payload key material. В отличие от O2 `encryptData`, старый public contract не ограничен key48/zero32. |

## 7. Все реализованные callbacks `CompatibilityStore`

`CompatibilityStore` объединяет **20 required методов** пяти протоколов. App реализует их в `XabberAxolotlStorage`; Контекст O2 этот callback-интерфейс не использует. Это обратные вызовы library→host, хотя некоторые app/tests вызывают их и напрямую. Ни один из callbacks не имеет `NSError **` или `throws`.

Сериализованные records — **opaque secret storage bytes**, не raw public key. `(address.name, address.deviceId)` дополняется app `owner`. Realm primary-key convention/Keychain layout не является частью crypto протокола.

### 7.1. `SessionRecordStore` — 6 методов

| № | Условная Swift-подобная сигнатура; входы | Выход / действие / фактический отказ |
| --- | --- | --- |
| S01 | `sessionRecord(for address: SessionLocator) -> Data?` | Возвращает serialized legacy session для адреса; отсутствие, другой профиль или Realm error → `nil`. |
| S02 | `storeSessionRecord(_ recordData: Data, for address: SessionLocator) -> Bool` | Создаёт/заменяет opaque record. `true` при Realm write; `false` при ошибке или конфликте существующего профиля. |
| S03 | `sessionRecordExists(for address: SessionLocator) -> Bool` | Проверяет наличие записи прежнего криптографического профиля; Realm failure → `false`. Не проверяет содержимое record на валидность. |
| S04 | `deleteSessionRecord(for address: SessionLocator) -> Bool` | Удаляет row; `true` при найденной и удалённой записи, `false` если отсутствует/ошибка. **App не фильтрует профиль при удалении.** |
| S05 | `allDeviceIds(forAddressName addressName: String) -> [NSNumber]` | IDs legacy session rows для имени peer/owner; Realm error → `[]`. Header не задаёт порядок списка. |
| S06 | `deleteAllSessions(forAddressName addressName: String) -> Int32` | Число удалённых rows, `-1` при ошибке. **App не фильтрует профиль при удалении.** |

### 7.2. `OneTimePreKeyStore` — 4 метода

| № | Условная Swift-подобная сигнатура; входы | Выход / действие / фактический отказ |
| --- | --- | --- |
| S07 | `loadPreKey(withId preKeyId: UInt32) -> Data?` | Serialized local OPK record из CredentialsManager; нет доступной записи → `nil`. |
| S08 | `storePreKey(_ preKey: Data, preKeyId: UInt32) -> Bool` | Записывает record, возвращает результат `containsPreKey`. Проверяется наличие, не равенство записанных bytes и не отдельный Keychain status. |
| S09 | `containsPreKey(withId preKeyId: UInt32) -> Bool` | Доступны ли bytes record по local OPK ID. |
| S10 | `deletePreKey(withId preKeyId: UInt32) -> Bool` | По интерфейсу — удалить OPK. **Production реализация no-op, всегда `true`, удаление закомментировано.** Это факт legacy adapter, не требование новой библиотеки. |

### 7.3. `SignedPreKeyStore` — 4 метода

| № | Условная Swift-подобная сигнатура; входы | Выход / действие / фактический отказ |
| --- | --- | --- |
| S11 | `loadSignedPreKey(withId signedPreKeyId: UInt32) -> Data?` | Serialized local SPK record; отсутствие/недоступность → `nil`. |
| S12 | `storeSignedPreKey(_ signedPreKey: Data, signedPreKeyId: UInt32) -> Bool` | Записывает SPK, затем проверяет наличие record. Не подтверждает equality/durable transaction. |
| S13 | `containsSignedPreKey(withId signedPreKeyId: UInt32) -> Bool` | Доступны ли bytes SPK record по ID. |
| S14 | `removeSignedPreKey(withId signedPreKeyId: UInt32) -> Bool` | Вызывает CredentialsManager remove; **возвращает `true` без подтверждения результата Keychain deletion**. |

### 7.4. `IdentityBindingStore` — 4 метода

| № | Условная Swift-подобная сигнатура; входы | Выход / действие / фактический отказ |
| --- | --- | --- |
| S15 | `getIdentityKeyPair() -> CompatibilityIdentityKeyPair` | Без входа; local legacy pair. Если credentials отсутствуют/не декодируются — **`preconditionFailure`**, не optional/throw; автоматического keygen нет. |
| S16 | `getLocalRegistrationId() -> UInt32` | Без входа; registration ID credentials. Недоступен, `<=0` или `>UInt32.max` → **0**. Комментарий header про negative failure несовместим с unsigned типом; app использует zero sentinel. |
| S17 | `saveIdentity(_ address: SessionLocator, identityKey: Data?) -> Bool` | Public candidate IK или `nil`; сохраняет identity binding. `nil` очищает key bytes в row, но cached bundle может остаться fallback lookup. Эквивалентный migrated Ed key сохраняется без downgrade. Другой ключ → invalidation и `false`; Realm error → `false`. |
| S18 | `isTrustedIdentity(_ address: SessionLocator, identityKey: Data) -> Bool` | Проверяет **continuity identity/TOFU**: нет старого key → `true`; эквивалентный → `true`; изменился/Realm error → `false`. При смене ключа вызывает invalidation. **Не проверяет пользовательский `.trusted` trust state.** |

Эквивалентность здесь: exact byte equality либо equality canonical X25519 public representations (`legacy33`/`O2 Ed32`). При реальной смене IK app ставит `.fingerprintChanged`, очищает trust date/source/certificate metadata и удаляет stale legacy session/trusted-binding row. Это policy приложения, а не автоматическое установление доверия библиотекой.

### 7.5. `GroupSenderKeyStore` — 2 метода

| № | Условная Swift-подобная сигнатура; входы | Выход / действие / фактический отказ |
| --- | --- | --- |
| S19 | `storeSenderKey(_ senderKey: Data, address: SessionLocator, groupId: String) -> Bool` | Opaque sender-key record и scope sender/device/group; Realm upsert → `true`, ошибка → `false`. |
| S20 | `loadSenderKey(for address: SessionLocator, groupId: String) -> Data?` | Record bytes по тому же scope или `nil`. |

Callbacks реализованы как required conformances; вызовов группового sender-key cipher в приложении/Swift XCTest **не найдено**. Нельзя выводить из этих двух методов, что group OMEMO использует SenderKey; используемая отправка построена на per-device session fanout.

Legacy callbacks не являются общим atomic commit API. O2 app хранит свой aggregate secret state отдельно, через checked persistence и owner lock. В XCTest `LegacyKeyStore` реализует те же 20 callbacks в памяти; его `deletePreKey` действительно удаляет запись, в отличие от production legacy adapter.

## 8. Доверие, fingerprints и функции приложения

Криптографическая проверка отвечает на вопрос, какие bytes подписала identity или какая identity связана с authenticated session. Решение доверять этому ключу для конкретного контакта/устройства принимает **Xabber**. Публичный O2 API не содержит store trust callback, `trustDevice`, certificate policy, кодов верификации или trust-sharing transport.

### 8.1. Преобразование identity и fingerprint — HOST

| Функция / входы | Выход | Комментарий |
| --- | --- | --- |
| `curvePublicKey(from wireIdentity: Data) throws -> Data` | Raw X25519 public32. | Вход должен быть wire Ed25519 IK32; C04→C05 выполняют преобразование. |
| `canonicalCurvePublicKey(fromLegacyOrOMEMO2Identity identity: Data) throws -> Data` | Raw X25519 public32. | `33` bytes с prefix `0x05` → убрать prefix; **эта ветка не валидирует public point**. Иначе Ed32 проходит C decode/convert; invalid shape или decoder failure → error. |
| `rawX25519(identityKey: Data) throws -> Data` | Raw X25519 public32. | Alias для **wire Ed** входа через `curvePublicKey`. |
| `canonicalRawX25519(storedIdentityKey: Data) throws -> Data` | Raw X25519 public32. | Alias для dual legacy/O2 stored representation. |
| `fingerprint(for identity: Data) throws -> String` | Lowercase hex canonical X25519 public, по 4 bytes в группе, разделитель пробел. | Это hex public key32 **без хеширования**; формат задаёт приложение. |
| `sharedSecret(privateKey: Data, peerIdentity: Data) throws -> Data` | DH shared secret32. | Local scalar32 + peer legacy33/Ed32; C06/C07/C08. Bad key/all-zero result → error; KDF выполняется выше. |
| `sign(_ data: Data, privateKey: Data) throws -> Data` | Signature64. | O03 восстанавливает identity из local scalar; O06 подписывает точные bytes. |
| `verify(_ signature: Data, data: Data, storedIdentity: Data) -> Bool` | `true` только при успешной проверке. | Signature должна быть64. Ed32 → O07; ошибка не выбирает legacy verifier. Legacy33 с prefix05 → отдельный `Curve25519Kit.Ed25519.verifySignature`. |
| `localIdentityPrivateKey(owner: String, storage: XabberOMEMO2Storage? = nil, legacyPrivateKey: (() -> Data?)? = nil) throws -> Data` | Local scalar32. | Читает authoritative O2 identity; legacy credentials допустимы только при отсутствии подготовленного O2 aggregate, не при corruption/access failure нового state. Owner lookup — app. |

**Отличающийся legacy app fingerprint:** `Data.formattedFingerprint() -> String` считает SHA256 входных bytes, делает uppercase hex и группирует по 8 hex chars. Используется legacy bootstrap/fallback; его нельзя считать эквивалентом O2 fingerprint выше. Источник: Data+HexadecimalString.swift.

Replay fingerprint сообщения — ещё одна отдельная сущность: `OMEMO2ReplayProtection.fingerprint(for:owner:localDeviceID:) -> Data?` хеширует framed packet/transport association, а не identity для ручного доверия. Источник: OMEMO2ReplayProtection.swift.

### 8.2. Пользовательское доверие — HOST

`DeviceTrustRecord` — условное обозначение **Realm-модели Xabber**, а не интерфейса криптографической библиотеки. Её TrustState содержит `.unknown`, `.ignore`, `.trusted` (stored `"trust"`), `.distrusted` (`"distrust"`), `.revoked`, `.fingerprintChanged`.

| App функция / входы | Выход / эффект | Связь с crypto API |
| --- | --- | --- |
| `AuthenticatedKeyExchangeManager.getUsersPublicKey(jid: String, deviceId: Int) -> [UInt8]` | Canonical X25519 public bytes; при недоступности `[]`. | Читает public identity и вызывает app conversion. Не устанавливает trust. |
| `AuthenticatedKeyExchangeManager.getUsersIdentityKey(jid: String, deviceId: Int) -> Data?` | Исходная сохранённая Ed32/legacy33 identity или `nil`. | Проверяет допустимость representation, сохраняя original wire bytes. |
| `AuthenticatedKeyExchangeManager.writeTrustedDevice(jid: String, deviceId: Int)` | `Void`; обновляет `.trusted`, trust date и source device в scoped Realm row; errors журналируются. | Результат **app verification flow**. Не `isTrustedIdentity` из CompatibilityStore. |
| `OmemoManager.authenticatedOMEMO2Sender(identity: Data, jid: String, deviceID: Int) throws -> OMEMOAuthenticatedSender` | Exact authenticated identity fingerprint + `isTrusted`. | Сравнивает fingerprint этой identity со scoped existing device: только `.trusted` + совпадение ключа → trusted. Realm failure → untrusted. Не выдаёт trust на основании membership/current session. |
| `TrustSharingSignature.canonicalString(for containers: [DDXMLElement]) -> String?` | Canonical string или `nil` при invalid timestamps/entries. | App сериализация подписываемого trust payload; криптографический слой этого формата не знает. |
| `TrustSharingSignature.hashCanonicalString(_ canonical: String) -> Data` | SHA256 UTF8 canonical string, 32. | Именно этот digest передаётся в identity sign/verify. |
| `TrustSharingManager.checkItemSignature(jid: String, deviceId: Int, signature: Data, itemsList: [DDXMLElement]) -> Bool` | Bool signature check после canonicalization/identity lookup. | Вызывает app verify, O07 либо explicit legacy verifier. Успешная подпись сама по себе ещё не применяет список trust. |
| `TrustSharingManager.signCanonicalString(_ canonical: String) -> Data?` | Signature64 или `nil`. | Local identity lookup, digest выше, O03/O06. Private app helper. |

Текущий trust-sharing admission проверяет namespace/usage, publisher/device ID, fingerprint, timestamp и signature. В applyShare нет отдельного gate `publisher device.state == .trusted`; каталог не подтверждает полноту авторизации применения trust-решений. Certificate trust, кодовый exchange, полномочия изменения доверия, trust revocation, выбор разрешённых устройств и UI warnings принадлежат app. Одного O07 или S18 для этого недостаточно.

## 9. Шифрование целого сообщения и bundle lifecycle — HOST

Этот раздел дополняет каталог криптографических операций функциями приложения. Перечень host helpers здесь ориентир по границе ответственности, не полный каталог всех внутренних функций Xabber.

### 9.1. Основные app wrappers

| Функция / входы | Выход | Назначение / отказ |
| --- | --- | --- |
| `XabberOMEMO2Storage.prepare(deviceID: Int, preKeyCount: Int = 100) throws -> OMEMO2LocalBundle` | Public local bundle. | Создаёт/подготавливает aggregate, сохраняет identity/device continuity, SPK/signature и OPKs. Новая identity через O02 либо checked legacy scalar import O03. IDs/count проверяет app. |
| `XabberOMEMO2Storage.identity() throws -> IdentityKeyPair` | O2 identity. | O03 из protected scalar; storage error не означает key regeneration. |
| `XabberOMEMO2Storage.localBundle() throws -> OMEMO2LocalBundle` | IK, fingerprint public, SPK/ID/signature, список unconsumed public OPKs и deviceID. | Public representation из protected private material; не содержит private keys. |
| `XabberOMEMO2Storage.replenishPreKeys(minimumCount: Int = 100) throws -> OMEMO2LocalBundle` | Обновлённый public bundle. | O04 создаёт недостающие OPKs; IDs/consumed flags/persistence — app. |
| `XabberOMEMO2Storage.maintainKeysIfDue() throws -> Bool` | Был ли обновлён сохранённый key state. | App schedules SPK rotation/grace/pruning, O04/O06 создают pair/signature. |
| `OMEMO2PublishedBundle.selectedBundle(preKeyID: UInt32) throws -> SelectedPeerBundle` | O08 с выбранным OPK. | Lookup выбранного ID в public списке; absent → app error. |
| `OMEMO2BundleCodec.decode(item: DDXMLElement) throws -> OMEMO2PublishedBundle` | Public parsed bundle. | XML/Base64/IDs/namespace/count/uniqueness; validation каждого OPK через O08. |
| `OMEMO2BundleCodec.encode(_ value: OMEMO2PublishedBundle) throws -> DDXMLElement` | XML `<item>` с public `<bundle>`. | Проверка и сериализация public fields, без private bytes. |
| `OMEMO2BundleCodec.publication(_ bundle: OMEMO2PublishedBundle) throws -> DDXMLElement` | PubSub XML. | Подготавливает publication; подтверждение сервера/retry — другие функции приложения. |
| `OmemoManager.doubleRatchet(hmac: Data, jid: String, deviceId: Int) throws -> DDXMLElement` | XML `<key rid=... [kex=true]>`. | Trust/identity/membership/opt-out gate, создание session при необходимости, storage encrypt O12. Имя `hmac` историческое: параметр — key48/control32, не только MAC. |
| `OmemoManager.encryptMessage(message: String, to jid: String) throws -> DDXMLElement?` | XML `<encrypted>` либо ошибка. | Подготовка SCE, payload seal один раз, per-device wrapping для trusted recipients/own devices. Нет trusted recipient → error. |
| `OmemoManager.makeOMEMO2Control(jid: String, deviceID: Int) throws -> XMPPMessage` | Empty control stanza. | O12 для zero32, без `<payload>`; network send/ACK scheduling — app. |
| `OmemoManager.decryptMessage(_ message: XMPPMessage, originalSendingTime: OMEMOOriginalSendingTime? = nil) throws -> DDXMLElement?` | Verified SCE envelope; `nil` для control/duplicate. | Explicit profile selection, candidate crypto receive, outer MAC/SCE validation. Ошибки не разрешают plaintext fallback. |

### 9.2. Payload и внешние providers

| App helper | Вход | Выход / смысл |
| --- | --- | --- |
| `secureRandom(_ count: Int) throws -> Data` | Положительное число bytes. | `count` CSPRNG bytes; RNG failure → `encryptionFailed`. |
| `seal(_ xml: String, randomBytes: (Int) throws -> Data = secureRandom) throws -> SealedPayload` | SCE XML в UTF8 и injectable RNG. | `{ciphertext: Data, keyAndMAC: Data}`; keyAndMAC48 для O12. Generated key32, payload HKDF/AES/HMAC выполняются здесь. |
| `openVerified(_ payload: Data?, keyAndMAC: Data, expectedFrom: String?, expectedTo: String?, requireTo: Bool = false, originalSendingTime: OMEMOOriginalSendingTime? = nil) throws -> OpenedPayload?` | Ciphertext payload + раскрытый material, ожидаемые app bindings. | `{envelope, content, timeValidation}`; `nil` только для отсутствующего payload + exact zero32 control. Проверяет MAC **до** decrypt, затем UTF8/XML/SCE/from/to/time. |
| `open(...) throws -> DDXMLElement?` | Те же параметры, что `openVerified`. | Envelope-only projection; `nil` control. |
| Private `derive(_ key: Data) throws -> [UInt8]` | Content key32. | HKDF output80: AES key32, HMAC key32, IV16. Это app helper, вне криптографического ядра. |

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

AKE также вызывает эти AES/RNG/hash/HMAC providers: AuthenticatedKeyExchangeManager.swift. Его `calculateSharedKey(jid:deviceId:) -> [UInt8]?` использует C08 через app wrapper; `calculateEncryptionKey(sharedKey:code:sid:) -> [UInt8]` получает SHA256 от shared bytes и app verification context. Это code-verification flow Xabber, отдельный от Double Ratchet.

### 9.3. Обозримые границы транзакций

1. **Public bundle:** O04/O06 дают материал; app назначает IDs/rotation policy, сохраняет private records и публикует только public fields. Library не выполняет PEP запросов.
2. **Outgoing:** app один раз `seal`s payload, затем O12 оборачивает key48 отдельно для каждой session. O14 + protected save должны завершиться до выпуска ciphertext. Network retry и multi-device partial failures принадлежат host.
3. **Incoming:** O15 parse → O10 для первого KEX либо O13 существующей session → outer MAC/payload/SCE validation → save snapshot + OPK consumed/replay state → использование plaintext и exact peer identity. Повторный KEX с известным EK обрабатывается существующей session.
4. **Trust:** successful parse ≠ authenticated peer; successful signature/decrypt ≠ user trust. Для outgoing recipients требуется app trust/key binding; incoming может быть криптографически корректным и помечаться untrusted.

## 10. Ошибки и отказ

Нейтральный `CryptoErrorKind` обозначает классы ошибок. Ниже сохранены наблюдаемые категории; это не утверждённая нумерация ошибок новой библиотеки и не обещание, что каждый метод выдаёт каждую категорию.

| Категория | Смысл |
| --- | --- |
| `unknown` | Неуточнённая ошибка. |
| `noMemory` | Ошибка выделения памяти. |
| `invalidArgument` | Недопустимый аргумент. |
| `duplicateMessage` | Повтор уже обработанного пакета. |
| `invalidKey` | Недопустимый ключ. |
| `invalidKeyId` | Недопустимый либо недоступный key ID. |
| `invalidMAC` | Не прошла authentication tag/MAC проверка. |
| `invalidMessage` | Недопустимый message. |
| `invalidVersion` | Недопустимая protocol version. |
| `legacyMessage` | Ошибка обработки прежнего формата. |
| `noSession` | Нет session. |
| `staleKeyExchange` | Устаревший либо неподходящий exchange. |
| `untrustedIdentity` | Identity не допущена binding/trust policy. |
| `invalidProtoBuf` | Ошибка protobuf structure. |
| `fingerprintVersionMismatch` | Несовпадение fingerprint version. |
| `fingerprintIdentityMismatch` | Несовпадение fingerprint identity. |
| `proofSignatureVerificationFailed` | Отказ проверки VRF-подписи низкоуровневого слоя; приложение напрямую эту категорию не обрабатывает. |

Int-status успех и error-kind enumeration — разные числовые пространства. В наблюдаемом низкоуровневом слое status0 означает успех, тогда как error-kind0 может означать `unknown`. Нельзя смешивать их при преобразовании ошибок.

Прежний history receiver распознаёт duplicate по **домену ошибок соответствующего provider и категории**, а не только по числу. Это terminal duplicate, без повторного продвижения session.

Приложение отдельно различает недоступный storage, отсутствующую session, внешний payload MAC failure, отсутствие trusted recipients, запрещённый профиль и corruption. Эти ошибки могут возникнуть вне криптографического ядра; host сохраняет различие между parser/crypto/storage/policy failure.

## 11. Операции вне действующего пути

| Операция или участок | Статус |
| --- | --- |
| Сборка `CompatibilityStoreAdapter` из пяти отдельных stores | U; приложение использует единый объект L01. |
| Настройка callbacks platform crypto provider из приложения | U как direct app API; внутренний provider call graph не включён в каталог. |
| Отдельные constructors старых regular/prekey messages | Прямых app/test вызовов не найдено; history receive использует L12. |
| Внутренние низкоуровневые session/wire/helper/store-registration операции | Не вызываются напрямую приложением/его тестами. |
| App helper `generatePreKeys()` без generator call | U; caller отсутствует, создаёт 101 default objects и не является рабочим keygen. |
| App wrapper `doubleUnratched(...)` | U; содержит parser/decrypt, но caller не найден. |
| Исторический экспериментальный manager вне target membership | Не участвует в current backend; его непроверенные методы не включаются в active API. |

## 12. Использование каталога для самостоятельной реализации

Каталог содержит **60 записей операций/инициализаторов/receiver-вариантов/callbacks**: O01–O15, C01–C08, L01–L13, T01–T04 и S01–S20. Getters и unused members отмечены отдельно. Это не требование воспроизводить 60 одинаковых entrypoints.

Собственной библиотеке нужны соответствующие **возможности**; конкретный API, snapshot/state format и tests проектируются независимо. Факты поведения старого adapter, включая no-op deletion или неполное подтверждение storage success, не являются требованиями к новой реализации.

| Потребность consumer | Требуемая возможность |
| --- | --- |
| Identity, DH, SPK/OPK, подписи | Типы ключей с явным разделением private/public representation; генерация/импорт/sign/verify. |
| Public bundle list и selected peer material | Генерация/проверка public material без private leakage; validation отдельно от trust/address assignment. |
| Initiator/responder session | Establishment по опубликованному профилю; authenticated first packet и OPK consumption event. |
| Encrypt/decrypt | Собственная ratchet state machine, порядок/replay и отказ без повреждения committed state. |
| Whole payload и per-session key wrapping | Binary payload operations; fanout association/XML/SCE/PEP остаются host. |
| Restart | Собственный versioned snapshot; protected persistence, serialization/CAS/rollback policy у host. |
| Exact peer identity после successful receive | Доказанное identity metadata для внешнего trust policy. |
| Старые records/adapters | Описаны для полноты текущей интеграции; backward compatibility не является требованием согласованного независимого package. |

Первичные источники выбранного профиля:

- [XEP-0384 OMEMO Encryption, 0.9.1](https://xmpp.org/extensions/xep-0384.html): криптографический профиль, X3DH/classic Double Ratchet, bundles и binary envelopes; reusable core отделён от app transport.
- [RFC 7748](https://www.rfc-editor.org/rfc/rfc7748): X25519 и представления public keys.
- [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032): Ed25519 и стандартные signature vectors.
- [RFC 5869](https://www.rfc-editor.org/rfc/rfc5869): HKDF и стандартные vectors.

## 13. Проверка и пределы результата

- Операции/inputs/outputs/effects исходного каталога сохранены; новые имена явно помечены условными. История аудита и исходные ссылки сохранены отдельно в проектной памяти и Git history.
- Проверены 60 catalog IDs, 20 storage callbacks, нейтральность текста/URL/имён выданных файлов, GFM tables и balanced code fences.
- Production code, зависимости и самостоятельный криптографический package не изменяются. Для Markdown-only правки новый build/runtime test не запускается.
- Справочник не является новым security review, доказательством runtime conformance или live interoperability. Existing tests служили источником callsites, а не независимыми expected-output fixtures.
