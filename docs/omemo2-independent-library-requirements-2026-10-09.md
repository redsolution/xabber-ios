# Собственная библиотека OMEMO 2 без Signal: зависимости и список реализации

Дата проверки: 2026-10-09. iOS source baseline: `ce05bf57`. Это исследование и предлагаемый план реализации; production-код и зависимости не изменены. Исторические результаты проверок не являются проверкой будущего backend.

## 1. Основной вывод и границы

Реализация возможна. В Xabber уже есть собственное ядро OMEMO 2, размещённое внутри локальных форков SignalProtocolC/SignalProtocolObjC. Оно использует отдельные wire-сообщения и состояние OMEMO 2, но зависит от Signal context, объектов ключей, buffers, crypto provider и унаследованной арифметики кривых. Самостоятельная библиотека должна заменить этот backend и убрать эти зависимости, сохранив полезную XMPP-интеграцию.

**Уточнение пользователя от 2026-10-09:** обратная совместимость с реализацией на libsignal не требуется; библиотека должна поставляться отдельным CocoaPod или SwiftPM package. В обязательный scope не входят импорт старых identity/sessions/snapshots и чтение Signal v3 ciphertexts. Предлагается новый профиль локального состояния и fresh Ed25519 identity. Совместимость по wire с другими клиентами стандартного OMEMO 2 остаётся требованием.

Отказ от библиотеки Signal не отменяет алгоритмы X3DH и классического Double Ratchet: они входят в выбранный профиль OMEMO 2. Собственный несовместимый handshake или ratchet уже не будет этой реализацией OMEMO 2. Новые PQXDH, Triple Ratchet и другие современные расширения Signal не входят автоматически в этот профиль.

Предлагаемая граница: самостоятельный `XabberCryptoSwift` без XMPPFramework, Realm, UIKit и Signal; криптографические providers; адаптер к существующему приложению. Имя XabberCryptoSwift и отдельный каталог утверждены пользователем; структура SwiftPM реализована в L01. Для Apple платформ разумно использовать Swift для state machine и CryptoKit для native Ed25519 identities, X25519, SHA/HMAC/HKDF; отдельно понадобится проверенное Ed25519→X25519 преобразование. Старый XEdDSA signer больше не нужен. При требовании одного native ядра для iOS/web/Android нужно отдельно выбрать portable C/Rust backend и способ подключения, а не считать iOS CryptoKit переносимым решением.

Рекомендация по доставке: SwiftPM как основной package, `.podspec` над теми же sources для текущего CocoaPods приложения. Выбор пользователя допускает один из форматов; поддержка обоих удобна, но не является обязательным условием первой версии.

**Последнее уточнение пользователя:** универсальный package знает только keys/bundles, arbitrary bytes, crypto sessions/envelopes и state. XML/XMPP/PEP/SCE, адреса/JID/SID и persistence принадлежат consumer. [Актуальный neutral API](independent-crypto-library-api-2026-10-09.md) отделяет core от приведённых ниже Xabber integration checks и заменяет namespace-oriented трактовку package.

Здесь различаются:

- **Нормы протокола:** wire/crypto и lifecycle из выбранных XEP.
- **Существующее поведение:** код проекта, включая сохранение identity и истории.
- **Проектирование реализации:** транзакции, собственные snapshots, serialisation, лимиты и recovery.
- **Проверка:** тесты, vectors, sanitizers, fuzzing, interoperability и review.

## 2. Проверенные зависимости

| Компонент | Фактическое подключение | Что требуется при замене |
| --- | --- | --- |
| SignalProtocolC | CocoaPods 2.3.2, локальный `/Users/igor.boldin/projects/xabber/deps/SignalProtocolC`; manifest prepared commit `29d4e8b66f7539c4731b8c05ebf6fcfa1e786937` | Заменить OMEMO key/wire/session backend и все `signal_*`/`ec_*` объекты. После переключения удалить pod, старый reader и local-dependency links. |
| SignalProtocolObjC | CocoaPods 1.1.0, локальный `/Users/igor.boldin/projects/xabber/deps/SignalProtocolObjC`; prepared `664431049dfa43a43c6ca82e446c1e7332d6f9c8` | Заменить `OMEMO2Context`, key/bundle/ciphertext/session models и старые `SignalContext`/`SignalStorage` вызовы. |
| Curve25519Kit | 2.1.0, fork `redsolution/Curve25519Kit`, pinned `412b1f9e209cb97a2fa092ac5ac9443274d5e0f4` | Отдельно проверить legacy signatures, credentials и target membership. Происхождение от WhisperSystems: для полного удаления Signal-derived кода двух предыдущих pods недостаточно. |
| CryptoSwift | 1.8.1 | Уже используется для AES-CBC payload и push envelope. Может остаться; отказ от Signal не требует удалять CryptoSwift. |
| CryptoKit / Security | Системные Apple frameworks | Уже используются для SHA/HMAC/HKDF, независимой проверки ключей и CSPRNG. Могут стать основой provider без новой сторонней зависимости. |
| OpenSSL-Universal | 3.3.3001 | Не является обязательной библиотекой OMEMO 2; имеет другие потребители. Не удалять как побочный эффект. |
| XMPPFramework / KissXML | Локальный XMPPFramework, KissXML 5.3.1 | Сохранить transport/XML/PEP integration вне crypto core. |
| RealmSwift / SwiftKeychainWrapper | 10.46.0 / 4.0.1 | Сохранить protected secret state и публичные projections; новый core не должен знать о Realm/Keychain. |
| SwiftPM | Четыре audio packages в `Package.resolved` | Signal/OMEMO через SwiftPM сейчас не подключены. |

Источник: [Podfile](../Podfile), [Podfile.lock](../Podfile.lock), [local dependencies manifest](../tools/local-dependencies.json), [Package.resolved](../xabber.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved). Версии pods сами по себе не идентифицируют внесённые локальные изменения: нужны commits/patches.

Основной app и XCTest подключают Signal pods. Push extension подключает CryptoSwift/Curve25519Kit, но не SignalProtocolC/ObjC; сейчас она расшифровывает Xabber push envelope, а не ведёт Double Ratchet OMEMO. Это важно для объёма интеграции и требований к межпроцессным locks.

**Два возможных значения «без Signal»:** отсутствие link/import/runtime зависимости от libsignal; либо также отсутствие перенесённого кода Signal/WhisperSystems. Простое выделение нынешних `omemo_*.c` сокращает работу, но требует переписать используемые primitives/types и проверить происхождение переносимых частей. Для самостоятельной реализации по спецификации нужно документировать provenance и лицензии; переименование форка не делает его независимым.

## 3. Что уже есть и должно сохраниться

| Слой | Текущая реализация | Действие |
| --- | --- | --- |
| Key agreement / ratchet / binary wire | `SignalProtocolC/src/omemo_keys.c`, `omemo_wire.c`, `omemo_session.c`; ObjC `Classes/OMEMO/OMEMO2.h/.m` | Заменить ядро; использовать текущие API/fixtures как карту поведения. |
| XML bundles | [OMEMO2BundleCodec.swift](../xabber/xmpp/omemo/OMEMO2BundleCodec.swift) | Сохранить строгий codec; отвязать модель bundle от ObjC backend. |
| Payload и SCE | [Omemo2PayloadCodec.swift](../xabber/xmpp/omemo/Omemo2PayloadCodec.swift), `SCEReceivePolicy` | Сохранить уже реализованные authentication, padding и affix checks; опционально вынести payload AE в core без XML. |
| PEP / devices / publication | `OmemoManager.swift`, `OmemoManager+Devices.swift`, `OmemoManager+BundlePublication.swift` | Не переписывать transport при замене crypto. Сохранить standard PEP и существующий Xabber server profile. |
| Protected session storage | [XabberOMEMO2Storage.swift](../xabber/xmpp/omemo/storage/XabberOMEMO2Storage.swift) | Сохранить полезные policies; новые backend types, собственный versioned snapshot/namespace и explicit cutover без старого importer. |
| Identity / fingerprint / trust bridge | [Omemo2IdentityRepresentation.swift](../xabber/xmpp/omemo/Omemo2IdentityRepresentation.swift) | Убрать C/ObjC Signal calls; новые native Ed identities и canonical X25519 fingerprint. Legacy representation adapter не нужен. |
| Controls / replay / key maintenance | `OMEMO2ReplayProtection`, `OMEMO2PreKeyCleanupCoordinator`, `OMEMO2OptOutPolicy` и storage | Сохранить current lifecycle и semantics; проверить через новый provider. |
| Legacy history | `OmemoManager.swift` распознаёт Signal v3 frame `0x33`, читает только существующие legacy sessions | Удалить старый reader по решению пользователя; не пытаться принять старый ciphertext новым core. |

N01–N09 в [активном нормативном плане](omemo2-standard-compliance-plan.md) уже завершены в согласованных границах. Старый `omemo2-remaining-work-2026-10-05.md` описывает более широкий исторический backlog и не является списком того, что нужно реализовать заново.

## 4. Нормативная база

Проверены live originals: [XEP-0384 0.9.1, 2026-04-06](https://xmpp.org/extensions/xep-0384.html), [XEP-0420 0.5.0, 2026-06-23](https://xmpp.org/extensions/xep-0420.html). Оба имеют статус Experimental. Протокольный профиль нужно закрепить версией в исходниках, fixtures и conformance matrix.

Зависимые первичные документы: [X3DH](https://signal.org/docs/specifications/x3dh/), [Double Ratchet](https://signal.org/docs/specifications/doubleratchet/), [RFC 7748](https://www.rfc-editor.org/rfc/rfc7748), [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032), [RFC 5869](https://www.rfc-editor.org/rfc/rfc5869). [XEdDSA](https://signal.org/docs/specifications/xeddsa/) проверен как объяснение нынешнего backend; выбранной native Ed-seed реализации signer XEdDSA не нужен. Для XMPP интеграции также PEP/PubSub (XEP-0163/0060), EME (0380), MAM (0313), Carbons (0280) и stanza provenance/SCE. Это integration dependencies, а не новые crypto algorithms.

В KB есть устаревший snapshot SCE 0.4.1: для новой реализации ориентироваться на live 0.5.0. В существующем приложении сознательно оставлены fallback body, открытые markers/receipts и прежняя политика hints. Полное буквальное SCE sending conformance с этими исключениями не заявляется. Замена crypto backend сама по себе не меняет эти продуктовые решения.

## 5. Полный список необходимых компонентов

### 5.1. Контракт, типы и providers

- [ ] Закрепить совместимый с OMEMO 2 набор algorithms/KDF/binary envelopes и версии спецификаций; namespace `urn:xmpp:omemo:2` используется только внешним XMPP adapter. Legacy `0x05` key encoding / Signal v3 исключены.
- [ ] Определить независимые types: identity, DH keypair, signed prekey, one-time prekey, validated bundle, parsed ciphertext, authenticated result, session state и snapshot.
- [ ] Явно различать Ed25519 seed, производный X25519 scalar, Ed wire public и X public: одинаковая длина не делает их взаимозаменяемыми. Импорт старого Signal scalar отсутствует.
- [ ] `CryptoProvider`: RNG, X25519, identity conversion/sign/verify, SHA256/SHA512, HMAC, HKDF, AES-CBC/PKCS7, constant-time compare, secret-buffer lifecycle.
- [ ] Candidate-transition contract: input state неизменен, output + nextState provisional; persistence и version/CAS/commit у host. Core не вызывает Keychain/Realm/XMPP и не требует обязательный store. Optional convenience store/callback должен оставаться generic.
- [ ] Структурированные crypto errors: invalid input/bundle/signature, no session/key, authentication failure, duplicate, gap limit, stale/replacement KEX, unsupported snapshot. Storage errors принадлежат host. Без plaintext fallback на ошибке.
- [ ] Metadata доступна после parse, но не получает trust/authentication authority до успешной проверки.

### 5.2. Primitives и новые identity

**Ответ на уточнение пользователя «Ed25519 наша или сторонняя?»** В предложенном варианте реализация Ed25519 — системная Apple CryptoKit, а не собственная арифметика кривой. Собственными являются протокольное ядро OMEMO2 и identity conversion. Отсутствие Signal не означает, что AES/SHA/Ed25519 реализуются с нуля.

| Участок нового пакета | Предлагаемый исполнитель |
| --- | --- |
| Ed25519 signing/verification, X25519, SHA256/SHA512/HMAC/HKDF | Apple CryptoKit |
| AES256-CBC/PKCS7 | Apple CommonCrypto |
| CSPRNG | Apple Security |
| Ed seed→X private и validated Ed public→X public | Собственный проверенный conversion adapter |
| X3DH, classic DoubleRatchet, OMEMO2 protobuf/payload composition и state | Собственный код пакета |

Если требуется полностью собственный Ed25519 primitive, отдельно добавляются field/scalar arithmetic, point operations/basepoint multiplication, encoding/decoding, SHA512-based nonce/signing, strict verification, constant-time review и независимые adversarial vectors. Это не включено как требование: текущий вопрос уточняет происхождение, а не запрашивает реализацию primitive с нуля. [Apple Ed25519 signing API](https://developer.apple.com/documentation/cryptokit/curve25519/signing/privatekey).

- [ ] X25519: RFC7748 scalar decoding/clamping, little-endian public encoding, правильный импорт и DH; отказ от all-zero shared secret.
- [ ] Identity signature: Ed25519-compatible raw64, Ed wire public raw32; строгие длины и согласованная policy canonical/scalar/subgroup validation.
- [ ] Публичное преобразование Edwards → Montgomery с сохранением исходных Ed bytes для AD, включая remote sign bit 1 и недопустимые точки/нулевой знаменатель. Обратное преобразование для выбранных native Ed identities не требуется.
- [ ] Для native Ed-seed identities: SHA512 seed expansion, правильный private conversion к X25519 и проверка соответствия публичных форм. Не генерировать два независимых ключа для подписи и DH.
- [ ] Хранить native Ed25519 seed с explicit key kind/version; не принимать прежний X25519 scalar как seed. XEdDSA и импорт старой identity исключены из scope.
- [ ] SHA256/SHA512, HMAC-SHA256, HKDF-SHA256 с проверенными salt/info/output lengths, AES256-CBC с PKCS7; проверять MAC до CBC decrypt и возвращать общую authentication error.
- [ ] Системный RNG с проверкой ошибки; отсутствие production deterministic RNG. Dependency injection deterministic sources только в тестах.
- [ ] Ограничить копирование secret material, lifetime и очистку buffers; обычный Swift `Data` с copy-on-write не даёт самостоятельной гарантии zeroization.

CryptoKit подходит для стандартных X25519/Ed25519 операций, HMAC/HKDF/SHA. Публичный Ed→X conversion не предоставляется готовым OMEMO API: нужен отдельно проверенный участок field arithmetic и validation. Приватный conversion выполняется SHA512 expansion seed с правильным clamping. Ed→X→Ed теряет sign bit, поэтому исходные remote Ed bytes сохраняются отдельно для verification/AD. Для самостоятельного package без сторонних runtime dependencies предлагается системный CommonCrypto AES-CBC. Использование CryptoSwift допустимо, поскольку он уже есть в приложении, но тогда станет явной dependency пакета.

Новая локальная identity меняет fingerprint и требует новой публикации и проверки доверия со стороны других устройств. Это явное следствие выбранного пользователем отказа от совместимости; на ошибках нового protected state автоматическую повторную генерацию identity всё равно делать нельзя.

### 5.3. X3DH и establishment

- [ ] Проверять bundle signature, ключи, положительные 31-bit IDs и обязательный OPK до establishment; no-OPK вариант базового X3DH не принимать в OMEMO 2.
- [ ] Alice: новый EK; DH1=`DH(IK_A,SPK_B)`, DH2=`DH(EK_A,IK_B)`, DH3=`DH(EK_A,SPK_B)`, DH4=`DH(EK_A,OPK_B)`.
- [ ] SK = HKDF-SHA256 с IKM `FF×32 || DH1 || DH2 || DH3 || DH4`, zero32 salt, info `OMEMO X3DH`, L=32.
- [ ] AD = исходные Ed wire bytes `IK_A || IK_B` в порядке initiator/responder; не переставлять на ответном направлении и не заменять canonical X fingerprint bytes.
- [ ] Alice создаёт новый ratchet DH отдельно от EK; Bob initial ratchet использует SPK. Очистить промежуточные secrets.
- [ ] Bob проверяет совпадение SPK/OPK IDs и аутентифицирует первый пакет до возврата usable session/потребления OPK.
- [ ] Сохранять EK и pending KEX metadata. Повторный KEX с тем же EK продолжает session/counters; другой EK проходит существующую explicit replacement policy.
- [ ] KEX metadata сохраняется на последующих отправках до аутентифицированного ответа; ACK loss/reorder не создаёт сессию заново.

### 5.4. Double Ratchet

- [ ] State: роль, local DH pair, remote DH, RK, sending/receiving CK, Ns/Nr/PN, identities/AD, EK, KEX/prekey metadata и skipped keys.
- [ ] Root KDF: HKDF-SHA256, salt=RK, IKM=DH, info `OMEMO Root Chain`, output RK32 + CK32.
- [ ] Chain KDF: HMAC(CK,byte01)=MK; HMAC(CK,byte02)=next CK.
- [ ] DH ratchet transition, previous-chain skipped-key extraction, current-chain skip, проверка counters/overflow и обе роли.
- [ ] Skipped-key addressing по DH public key + message counter; одноразовое использование после authentication. Ограничить total retention и максимальную работу на одном gap; FIFO и конечная deterministic retention policy.
- [ ] Работать на копии state; parse/MAC/padding/crypto error не меняет input session. Host commit failure не заменяет committed state candidate-версией. Не удалять skipped key на неаутентифицированном пакете.
- [ ] Duplicate/replay и old chain не допускают повторного пользовательского сообщения; eviction, reset и restore не возрождают consumed keys.

### 5.5. Binary wire и authenticated encryption

- [ ] Реализовать три protobuf messages из XEP §12: `OMEMOMessage`, `OMEMOAuthenticatedMessage`, `OMEMOKeyExchange`; точные field numbers/types и raw32 keys.
- [ ] Не использовать `SignalMessage`/`PreKeySignalMessage` и Signal version-byte framing.
- [ ] Parser: bounded varints/lengths, required fields, duplicate singular fields, wrong wire types, truncation, integer bounds, допустимые unknown fields. Bounds — implementation policy.
- [ ] Сохранить исходные inner protobuf bytes; MAC считать по ним, без parse→reserialize normalization.
- [ ] Ratchet material: HKDF(MK,zero32,`OMEMO Message Key Material`,80) → AES key32 + HMAC key32 + IV16; AES256-CBC/PKCS7; tag=first16 HMAC(AD || exact inner message bytes).
- [ ] Payload material: случайный key32; HKDF(key,zero32,`OMEMO Payload`,80); тот же split; AES-CBC/PKCS7; payload tag=first16 HMAC(payload ciphertext).
- [ ] Одно ciphertext для arbitrary bytes payload; `key32 || payloadMAC16` оборачивается отдельно каждой crypto session. Сопоставление sessions адресатам/устройствам и XML stanza выполняет приложение.
- [ ] Empty control: ratchet plaintext ровно zero32, payload отсутствует; отличать от user-content plaintext48. Нельзя подменить CBC/HMAC на AES-GCM ради удобства API.

### 5.6. Собственное состояние и переключение приложения

Snapshot codec и candidate transitions принадлежат core. Переключение backend, защищённое хранение, доверие и commit/retry policy ниже — задачи внешнего приложения.

- [ ] Определить собственный versioned snapshot: role, exact Ed identities/AD, DH keys, RK/CK, counters, EK, pending KEX/SPK/OPK IDs, skipped keys и retention metadata.
- [ ] Strict decoder с invariants/size caps и unknown-version rejection. Формат storage не является protobuf wire и не должен зависеть от Signal records.
- [ ] Ввести отдельный namespace/epoch защищённого local state, отличающий новый backend от старого aggregate. Не интерпретировать старые 32-byte keys или blobs как новый формат.
- [ ] Генерировать native Ed identity, SPK/OPK и новые sessions; initial registration/SID policy реализуется host adapter с collision check и подтверждённой публикацией. Устаревшее объявление локального устройства заменяется/удаляется по выбранному server profile.
- [ ] При переключении invalidate старый собственный fingerprint, доверие к прежнему собственному ключу и связанные controls/session references; показывать новый fingerprint и использовать existing key-change verification flow. Не менять доверие к посторонним peer keys без причины.
- [ ] Создание identity допустимо только для подтверждённого отсутствия нового state. Corrupt/locked/inaccessible Keychain — error, а не повод автоматически перевыпустить ключи.
- [ ] Секреты, protected state и OPK private keys остаются в host-owned Keychain/store; core возвращает provisional output и candidate transition. Host атомарно фиксирует transition до отправки ciphertext или использования plaintext; core не скрывает уже возвращённые bytes до внешнего commit.
- [ ] OPK consumption, session snapshot и receive authentication фиксируются совместно. Failed crypto/payload/save не меняет committed ratchet.
- [ ] Host сериализует операции restored sessions и применяет version/CAS checks. Core не знает storage addressing. В Xabber adapter ключ owner + bare peer JID + device SID остаётся исключительно app-level association.
- [ ] Запретить writable downgrade к устаревшему checkpoint после продвижения ratchet; rollback старого state может повторно использовать message keys.
- [ ] Определить поведение restart/crash/retry: plaintext после secret commit до записи history, partial multi-recipient failure и retirement controls до network send сейчас имеют gaps. Их нельзя выдавать за гарантии нового package.
- [ ] Сохранить чтение уже расшифрованной локальной истории. Старые encrypted пакеты libsignal, незагруженная legacy MAM история и packets прежних sessions новый core не расшифровывает — выбранная пользователем граница.
- [ ] Если ratchet впоследствии используется в NSE, добавить межпроцессную координацию. Сейчас extension не ведёт OMEMO ratchet, поэтому этот объём условный.

**Исключено по уточнению пользователя:** importer/exporter старых native `OMEMO2S` v1/v2, перенос прежних RK/CK/EK/counters/skipped keys, поддержка X-scalar identity/XEdDSA, legacy Signal v3 decoder и continuity active sessions старого backend. Текущие форматы проверены в аудите только для установления границы удаления.

Полный journal/inbox/outbox, multi-recipient atomic rollback и exact network retries — отдельные engineering tasks. Они не становятся новыми обязательными XEP clauses, однако для production backend следует явно определить crash consistency и reuse/retry semantics.

### 5.7. Интеграция приложения и lifecycle

- [ ] Provider seam в `OmemoManager`/storage; убрать eager `SignalContext`/`SignalStorage` construction и legacy decrypt route.
- [ ] Перевести `Omemo2IdentityRepresentation` на новые key types; удалить legacy `XabberAxolotlStorage` bridge из crypto path. Realm-модели с именем `Signal*` сами по себе не являются binary dependency; переименование отдельно от backend cutover.
- [ ] Сохранить authoritative devices membership отдельно от bundle/trust rows, own-device fanout, collision/reannounce/disable и accepted publication checks.
- [ ] Сохранить SPK rotation/grace, OPK replenishment/consumption/cleanup, ACK/heartbeat/recovery, manual replacement и opt-out.
- [ ] Сохранить authenticated SCE reconstruction/affixes/time, MAM/Carbons/rewrite provenance, incoming trust indication и отсутствие bubbles для controls.
- [ ] Не включать новый trust-exchange UX, standard MUC, files/calls encryption как побочное изменение. Если нужны группы/attachments/calls, определить отдельный scope и peer capabilities; новый crypto core не обеспечивает их автоматически.
- [ ] Удалить pod entries, imports, Xcode references, native wrapper test links и local-dependency manifest/patch/bootstrap links после подключения new core; проверить app, tests и extension separately.
- [ ] Не удалять unrelated CryptoSwift/OpenSSL/XMPPFramework dependencies; проверить transitive dependencies и binary symbols для заявленной границы «без Signal».

SCE padding минимум512 и allowance±300s — нынешние client parameters, а не численные требования XEP. Xabber server-specific item publication и standard PEP setup также должны оставаться разными profiles.

## 6. Проверки до переключения production

| Gate | Минимальный набор |
| --- | --- |
| Primitives | RFC7748 X25519, RFC8032 Ed25519, RFC5869 HKDF, AES/HMAC known-answer; Ed seed→X conversion, обе remote identity sign-bit формы, invalid/small-order/noncanonical inputs и zero DH. |
| X3DH | Independent fixed-vector DH1–4/SK/AD, tampered SPK, missing OPK, wrong IDs, remote Ed-seed identity и совместимый remote X-origin Ed wire key. Последнее — wire interoperability, не импорт прежнего local scalar. |
| Ratchet/wire | Alice↔Bob, DH transition, simultaneous establishment policy, counters/overflow, skipped keys/FIFO, replay/out of order, повторный KEX и lost ACK, tampered raw protobuf/MAC, unknown fields. |
| Payload/SCE | Existing payload/SCE suites с новым core, tampered payload/tag/padding/affixes, empty controls, no user-content admission до полной проверки. |
| New state / cutover | Fresh Ed identity, new state namespace, подтверждённая публикация, stale legacy state ignored/rejected, peer key-change handling; new snapshot roundtrip/restart, pending KEX, consumed/retired keys; corrupt/locked store и запрет writable rollback. |
| Storage failures | Injected RNG/provider/save failures: zero committed mutation и zero released ciphertext/plaintext; stale concurrent writer, разные restored sessions, multi-recipient partial failure semantics. |
| App regression | Все применимые existing OMEMO2 XCTest suites: devices, registration, edits, replay/retention, maintenance, cleanup, recovery, opt-out, trust, history и receive routes. |
| Независимость | Expected bytes вычисляются независимым backend; нельзя ограничиться roundtrip новой библиотеки с самой собой или двумя clients с тем же core. |
| Interoperability | Новый iOS↔нынешний web OMEMO2 в обе стороны через новые sessions; минимум один независимый peer с подтверждённым `urn:xmpp:omemo:2`, не просто названием «OMEMO». MAM/offline/restart/own-devices/reorder/ACK loss. |
| Robustness | Fuzz binary wire/snapshot/XML seams, resource caps, ASan/UBSan для собственного native участка, static analysis, secret lifetime/constant-time review. Унаследованный Donna signed-shift UB нельзя переносить как доказанно безопасный primitive. |
| Build/distribution | Narrow XCTest/TDD first, Simulator app build via cached wrapper (successful test build counts), extension build при затронутом linkage; package build/cutover fixtures, symbol/dependency audit и воспроизводимые pins. |

Уже есть [CryptoKit conformance XCTest](../xabberTests/OMEMO2CryptoKitConformanceTests.swift), C `tests/test_omemo_keys.c`, `test_omemo_wire.c`, `test_omemo_session.c`, ObjC `OMEMO2Tests.m` и независимый `/Users/igor.boldin/projects/xabber/deps/SignalProtocolC/tests/omemo/reference_vector.py`. Их следует перенести/адаптировать; это уже полезная база. Последние vault записи сообщают C↔JS vectors/snapshots, но live two-client acceptance остаётся незавершённым; его нельзя заменить совпадением fixture.

## 7. Поставка отдельным package

Предпочтительный вариант: самостоятельный source SwiftPM package с library product `XabberCryptoSwift`; `.podspec` можно добавить над теми же исходниками. Текущий app уже сочетает CocoaPods и SwiftPM. Для первой версии достаточно одного выбранного формата; основной план использует SPM.

- [ ] Отдельный repository/directory, `Package.swift`, README, LICENSE/NOTICE, semantic versions/tags и changelog. Path: `/Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift`; свежий Git repository и SwiftPM skeleton созданы отдельной задачей L01.
- [ ] Minimum iOS15.0 совместим с Podfile15.0 и app/test deployment15.6; macOS host support для `swift test` объявить явно, если package tests запускаются на Mac.
- [ ] Swift public API не экспортирует Signal types/ObjC wrapper classes, Realm или XMPP XML; явно документирует provisional output + candidate state и ответственность host за commit до использования output.
- [ ] Core/Security providers отделены от app adapter. Test RNG/in-memory state находятся в test targets; production store полностью принадлежит приложению и не обязателен для core API.
- [ ] Если Ed→X conversion на C: отдельный C target с public headers и Swift target, зависящий от него. Swift и C files не складывать в один target на используемой версии toolchain.
- [ ] CryptoKit, Security и CommonCrypto — Apple SDK/libSystem; не требуются Signal/CryptoSwift/OpenSSL pods. Не добавлять абсолютные SDK modulemap paths.
- [ ] Отдельные unit tests с fixtures/resources: crypto vectors, codec, state machine, snapshot/restart/failure; persistence/commit fault tests находятся в host adapter, XCTest app integration сохраняется в app target.
- [ ] Проверить `swift build`/`swift test` на host, iOS Simulator consumer и Release library; app cached test/build подтверждает интеграцию, package tests сами по себе не собирают iOS app.
- [ ] Если выбирается CocoaPod: `XabberCryptoSwift.podspec`, source tag, deployment target, Swift version, public module/headers, test spec, framework linkage и lint/consumer gate. Использовать тот же source tree; не иметь две расходящиеся копии реализации.
- [ ] Если поддерживаются оба managers: CI проверяет оба consumers; каждый использует одну pinned version, двойное подключение одного module к app запрещено.
- [ ] Provenance и dependency/symbol audit подтверждают отсутствие Signal-derived runtime components в заявленной границе.

Локальный Swift6.2 toolchain совместим с manifest tools5.9 и отдельными Swift/C targets. CommonCrypto — SDK C module с routines в libSystem, а не framework для `.linkedFramework("CommonCrypto")`. Если позже добавляется podspec для двух SPM targets, module/header topology надо отдельно проверить (conversion subspec/pod либо единый mixed framework с условным import). Primary references: [SwiftPM target model](https://docs.swift.org/main/documentation/packagemanagerdocs/creatingmixedlanguagetargets/), [Apple CommonCrypto](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/CCCryptorUpdate.3cc.html), [CocoaPods podspec](https://guides.cocoapods.org/syntax/podspec.html).

## 8. Предлагаемые этапы и условия готовности

После transport-neutral уточнения актуальный library/consumer split зафиксирован в [API proposal](independent-crypto-library-api-2026-10-09.md) и [L01–L07](omemo2-independent-library-plan-2026-10-09.md). App cutover — внешняя задача consumer, standalone package acceptance не требует XMPP внутри библиотеки.

После обсуждения происхождения primitives, browser API и лицензий составлен [подробный execution plan L01–L07](omemo2-independent-library-plan-2026-10-09.md). Он разделяет первый wire/X3DH packet и полную ratchet state machine, уточняет границы host/package и оставляет самостоятельный web package отдельным scope.

1. **Package/API.** Создать отдельный SPM package (либо pod по выбранному варианту), типы/provider/candidate-transition contracts и test fixtures. Результат: independent compile и API без Signal, XML или обязательного store.
2. **Primitives/identity.** Native Ed seed, Apple providers и проверенный conversion. Результат: RFC/independent vectors и корректные signatures/DH/AD.
3. **Core.** Собственные protobuf codec, X3DH, classic ratchet и payload AE; dedicated tests до implementation. Результат: independent expected bytes и fail-without-mutation guarantees.
4. **New state.** Versioned own snapshot, restart/corruption/failure tests; concurrency/commit fault tests отдельно у host. Результат: new sessions продолжаются после корректного restore; старый state не импортируется.
5. **Neutral consumer.** Пример keys/bundles/arbitrary bytes encrypt/decrypt без Xabber/XMPP. После готовности package отдельно подключить Xabber adapter с fresh identity/registration, existing XMPP/SCE и local history.
6. **Interoperability/release.** Live web/independent peer через новые sessions, robustness review, semantic release tag и dependency audit; optional podspec consumer gate. Результат: отдельный usable package без Signal.

Наиболее трудные части после отказа от обратной совместимости: безопасный identity conversion, ratchet state machine, hostile wire parsing и failure/crash semantics. Импорт старых snapshots и XEdDSA больше не определяют объём. Сроки без выбора API/providers и package acceptance gates были бы недостоверны.

## 9. Что проверено в этом исследовании

Проверены manifests/lockfiles, локальные C/ObjC API и snapshot format, Swift integration/storage/identity/payload, tests, текущие планы и KB/vault; версии XEP сверены с live первичными источниками. Три parallel read-only review покрыли dependencies, normative profile и migration/tests. Production edits, новые dependencies, live account mutations и builds/tests не выполнялись: новый backend ещё не реализован. Полная runtime conformance, поведение cutover на реальном аккаунте и новый provider остаются работой реализации.

## Реализация после аудита

Пользователь поручил L01 и назвал package `XabberCryptoSwift`. [Отчёт L01](xabber-crypto-swift-l01-2026-10-09.md) отделяет реализованные structural models/contracts от будущей криптографии L02–L05. Результаты исходного аудита выше описывают baseline до начала новой реализации.
