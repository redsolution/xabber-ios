# XabberCryptoSwift — L04 ratchet and payload

Дата: 2026-10-09. Статус: выполнено в отдельном SwiftPM package на master → origin/master.

Package commit `c412932` — `Implement Double Ratchet and message encryption`, опубликован в origin.

## Результат

Публичный `XabberCryptoEngine` реализует универсальный `CryptoEngine`: generation/import keys/prekeys, bundles, X3DH establishment, arbitrary Data payload encryption/decryption, отдельные seal/open/wrap/unwrap и controls. Приложение владеет transport, trust, association и protected storage. Package не получает XML/XMPP/address/device/account/store types; Signal source/runtime и legacy records не используются.

Собственный classic Double Ratchet выполняет DH/root/chain transitions и Ns/Nr/PN, поддерживает начальный пакет с n>0 при потерях, перестановки, пропущенные ключи нескольких цепочек, повторы и KEX до authenticated reply. При matching EK existing-session path обрабатывает только вложенный authenticated message по pinned XEP0.9.1 §4.3; внешние identity/prekey IDs не меняют authenticated peer identity. Другой EK требует отдельного решения host о новой session. Успешный peer reply удаляет pending KEX/private EK из нового candidate state.

Payload: random key32, HKDF80 с info OMEMO Payload, AES256-CBC/strict PKCS7 и truncated HMAC16(ciphertext). Ratchet переносит key32+MAC16. Control — nil payload и exact zero32 внутри ratchet; empty application payload — nonempty ciphertext и `.payload(Data())`. High-level decrypt/accept возвращает state/content/consumed OPK только после envelope и payload authentication. Low-level unwrap provisional: openPayload должен успешно завершиться до host policy/atomic commit. Ошибки MAC/padding/shape/RNG/outer payload не меняют входное состояние, не расходуют retained skipped key и не возвращают OPK event.

## Ограничения состояния

`RatchetConfiguration` default: retained skipped keys1000, aggregate skipped derivation per packet1000, key lifetime1000 successful receive events, incoming DH transitions4096. Skip budget складывает старый PN gap и новый N gap. FIFO/event age детерминированы; failed receives и sends не продвигают age. Retired DH history не забывается, чтобы старый packet не превращался в новую цепочку после eviction. На transition cap receive новой DH отклоняется с `sessionLimitReached`; продолжение требует явного fresh-session решения host. UInt32 counters/UInt64 receive events проверяют overflow. Payload plaintext capped16MiB, incoming ciphertext shape проверяется до ratchet work.

Snapshot methods вынесены в `SessionStateCoding` без dummy implementation. Собственная serialization/restore validation и restart tests — L05. README остаётся общим описанием.

## Проверки

TDD: focused ratchet/payload/public-engine/configuration tests и independent reference fixtures добавлены до production implementation. Review отдельно проверяет state atomicity, replay/limits и primary profile. Повторный KEX уточнён по primary XEP: RED на изменённых outer IDs/identity с matching EK, затем обработка only nested authenticated message.

- `swift test`: **162/162**, из них L04 ratchet21, public engine13, payload16, independent vectors7, configuration3; ранее реализованные L01–L03 102 также прошли.
- Independent Python/OpenSSL: **9 packets / 18 events / 3 reorder scripts**, exact root/chain/counters/protobuf/CBC/MAC/payload/control соответствуют Swift ratchet и public engine. L03/L04 generators `--check`: passed. Python3.12.14/cryptography50.0.2/OpenSSL4.0.3 — development reference tooling, runtime dependencies отсутствуют.
- `swift build -c release`, public ContractConsumer Debug/Release и ASan, cached generic iOS Simulator **arm64/x86_64** build: passed. Compiler/linker errors и warnings отсутствуют.
- Actual-source parser/model standalone ASan: **8016 deterministic inputs**, три positive packet vectors и semantic checks passed. XCTest discovery helper ASan по-прежнему ограничен macOS platform policy, её не меняли; public executable ASan выполняется успешно.
- Consumer `otool -L`: только system frameworks/libraries. Package.swift dependencies пусты, source imports ограничены Apple SDK и собственным C target.
- Review проверил bounded work/memory, skipped FIFO/age, retired replay history, overflow, MAC-before-CBC, candidate atomicity и matching-EK receive по primary XEP. Disposable temporary logs/binaries удалены, build caches сохранены.

## Следующий этап

L05 должен валидировать при restore keys/AD/counters/configuration, skipped-key uniqueness/age, retired history, pending KEX и role-specific state invariants. Приложение должно сериализовать/CAS операции и атомарно сохранять state/OPK, затем допускать output к использованию. L06 explanatory standalone consumer и L07 peer interoperability/security/release acceptance остаются по плану. App source/manifests/backend не менялись.

Ссылки: [API](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/API.md>), [profile](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/PROFILE.md>), [проверки](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/TESTING.md>), [план](omemo2-independent-library-plan-2026-10-09.md).
