# XabberCryptoSwift — L02 primitives and identity

Дата: 2026-10-09. Статус: выполнено в отдельном SwiftPM package.

Пакет: `/Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift`, ветка `master`, upstream `origin/master`. Коммит `cb00c3d` — `Add Apple cryptographic primitives and key operations`, опубликован в origin.

## Реализовано

- Публичный `KeyOperations`: генерация/import native Ed25519 identity seed, проверка связанных Ed/X public keys, подпись/проверка произвольных Data, генерация/import independent X25519 keys с canonical clamping.
- Внутренний AppleCryptoProvider: CryptoKit Ed25519/X25519/SHA/HMAC/HKDF, Security RNG с проверкой status, CommonCrypto AES256-CBC, Darwin timing-safe comparison.
- Собственная Ed25519-to-X25519 public-point conversion: canonical encoding, on-curve recovery, negative-zero rejection, small/mixed-order rejection, exact prime-subgroup check. Обе допустимые Ed sign encodings дают одинаковый X key; исходные Ed bytes не заменяются.
- Secret identity derivation через Apple SHA512 и clamp. Собственная field/group arithmetic обрабатывает только публичные данные.
- Полная проверка PKCS7 suffix до возврата plaintext. Протокол обязан аутентифицировать ciphertext до CBC decrypt.
- Ограничения RNG/HKDF и ошибка провайдера не приводят к возврату результата. Writable временные secret buffers очищаются; копии Data и память внутри Apple frameworks не охвачены обещанием zeroization.
- README содержит только общее описание пакета. Этапы остаются в отдельном документе. Новых third-party runtime dependencies и Signal-derived source нет.

## Проверки

- TDD: primitive/conversion/key-operation tests добавлены до implementation; missing implementation и nonzero-index Data-slice import дали воспроизводимые RED, затем GREEN.
- `swift test`: 44/44 XCTest — 12 structural, 18 provider, 9 conversion, 5 public key operations.
- RFC8032/7748/4231/5869 и NIST SHA/AES fixed vectors; invalid points, signature scalar malleability, DH zero output, RNG failure, HKDF bounds, malformed CBC lengths и PKCS7 suffix.
- Native ASan/UBSan: boundary checks, in-place conversion, padding mutations и 1024 deterministic inputs; ошибок нет.
- Independent Python bigint/OpenSSL differential check: 452 public-point cases, 0 расхождений; input preservation и output clearing проверены. Отдельная arithmetic review: 62,028 field comparisons, 0 расхождений.
- `swift build -c release`, отдельный public ContractConsumer Debug/Release: passed. Consumer использует обычный import и реальные key/signature APIs.
- Cached `xcodebuild` для generic iOS Simulator: BUILD SUCCEEDED, arm64/x86_64, compiler/linker errors и warnings отсутствуют.

CryptoKit рандомизирует Ed25519 signing; тесты проверяют fixed RFC signatures и валидность native signatures, без требования byte-identical generated signatures. Verifier принимает только canonical S<L и canonical nonidentity prime-subgroup A/R; это более строгая package policy, чем базовый RFC8032.

## Граница результата

Key/signature API готов к использованию отдельно от транспорта. Generation/validation prekeys и bundles, X3DH, envelopes, ratchet, message encryption/decryption и snapshots относятся к L03–L05. Полная protocol interoperability и external security review ещё не выполнены. Xabber app продолжает использовать существующий backend; app source/manifests не менялись. Release tag и выбор лицензии остаются последующей работой.

Ссылки: [публичный API](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/API.md>), [проверки](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/TESTING.md>), [provenance](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/NOTICE.md>), [план](omemo2-independent-library-plan-2026-10-09.md).
