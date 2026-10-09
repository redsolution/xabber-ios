# XabberCryptoSwift — L03 wire and X3DH

Дата: 2026-10-09. Статус: выполнено в отдельном SwiftPM package на master → origin/master.

Package commit `64bc57c` — `Implement prekeys, X3DH and initial key exchange`, опубликован в origin.

## Результат

Публичный KeyOperations реализует PreKeyOperations: generation/import signed и one-time prekeys, создание public bundle и cryptographic selected-bundle validation. Подпись покрывает exact raw32 SPK. Identity Ed bytes/sign bit сохраняются; signature validation не заменяет external identity trust. OPK signature отсутствует по выбранному профилю. Библиотека принимает nonempty bundle; publisher pool/rotation/storage остаются у приложения.

Собственные три protobuf codecs соответствуют pinned XEP-0384 0.9.1 §12. Parser ограничен 1 MiB и 1024 fields на layer, проверяет shortest varints, lengths, required/duplicate fields, wire types, UInt32 counters и int31 IDs. Unknown wire0/1/2/5 допустимы, groups отклоняются. Exact inner bytes сохраняются для MAC, включая field order и unknown fields.

X3DH использует обязательный OPK и четыре DH с FF32 prefix, zero32 salt и info OMEMO X3DH. AD состоит из оригинальных Ed identity bytes в порядке Alice/Bob. Alice EK и initial ratchet DH различны. Bob аутентифицирует первый key packet, затем создаёт fresh sending DH. Возврат state/consumed-OPK candidate происходит только после MAC, strict PKCS7, plaintext48 и RNG success. Host input state/private records неизменяемы; key unwrap требует payload authentication перед external commit.

Внутренний first-packet helper поддерживает n=pn=0, ciphertext64/plaintext48. Alice EK pair сохраняется с pending KEX согласно pinned profile; удаление при authenticated reply — L04. X25519 canonical u<p и strict Ed subgroup validation являются explicit policies, более строгими, чем permissive RFC decoders.

## Проверки

- TDD перед implementation: prekeys, codecs, initial state и key validation; ephemeral pair state requirement подтверждён отдельным RED → GREEN.
- `swift test`: **102/102** — L01/L02 44, L03 key validation4, codec14, initial session12, prekeys14, independent X3DH14.
- Три независимых known-answer vectors: native/native, native → X-origin signbit1 peer и X-origin signbit1 → native. Exact DH1–4/SK/AD/roots/chains/CBC/MAC/whole KEX и negative signature/identity/key/ID/tag/padding/RNG cases.
- Independent Python generator `--check`: passed в reference environment cryptography/OpenSSL; зависимости tooling отсутствуют в runtime package.
- Codec XCTest: 1603 deterministic hostile inputs/mutations. Standalone actual Swift parser/model ASan host: **8016 inputs**, fixed positive vectors и semantic checks passed.
- `swift test --sanitize address` не запустил тесты: macOS отклонила sanitizer dylib в platform-signed discovery helper. Standalone host проверил actual source под ASan; platform policy не менялась. После этого обычный full XCTest прошёл повторно.
- `swift build -c release`, public ContractConsumer Debug/Release и cached generic iOS Simulator arm64/x86_64 build: passed; compiler/linker errors и warnings отсутствуют.
- Stale consumer dependency-file-list cache исправлен `--disable-build-manifest-caching`, без удаления caches. Package runtime dependencies пусты; consumer linkage содержит только system libraries/frameworks.

## Граница этапа

Ключи/prekeys/bundles доступны через public API. Complete CryptoEngine ещё не реализован: subsequent ratchet transitions, skipped keys/replay/reorder/repeated KEX/controls/payload sealing относятся к L04, snapshots — L05. Первый пакет проверен по независимым байтам; live peer interoperability и external security acceptance остаются L07. App source/manifests/backend не менялись. README сохраняет общее описание без milestones.

Ссылки: [API](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/API.md>), [profile](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/PROFILE.md>), [reproducible checks](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/TESTING.md>), [план](omemo2-independent-library-plan-2026-10-09.md).
