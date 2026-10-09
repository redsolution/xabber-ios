# XabberCryptoSwift — L01 package/API

Дата: 2026-10-09. Scope: standalone package skeleton и own API contracts.
Пользователь утвердил имя и каталог `/Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift` и начало L01. Repository инициирован с нуля на `codex/l01-package`; source не копируется из Signal.

## Результат

- SwiftPM library/test targets, iOS15+/macOS12+, tools5.9, без сторонних dependencies.
- Length-checked key/seed/signature inputs, positive31-bit key IDs, public bundles и выбор OPK. Shape checks не заявляют crypto validity.
- Private/public records разделены; derived pairs, validated bundle, session и authenticated result не имеют public произвольных constructors.
- Public CryptoEngine contract и internal CryptoProvider seam; opaque SessionState с exact identity metadata, envelope kind и provisional candidate transitions.
- Seal/open/wrap/unwrap contracts позволяют один payload для нескольких sessions; host mapping/trust/persistence/transport остаются вне core.
- Explicit secret exports и redacted diagnostics/reflection; synthetic structural fixtures, XCTest и independent public ContractConsumer.
- README/API/milestones/source provenance и licensing-status metadata. C conversion target и Apple primitive implementations — L02, concrete engine не создан.

## Verification

- TDD: focused XCTest до production types; исходный compile failure на отсутствующих models. Дополнительные review tests также сначала failed на новых contracts.
- `swift test`: 12 tests passed.
- `swift build -c release`: passed.
- Debug/Release ContractConsumer с обычным `import XabberCryptoSwift`: passed, без @testable или fake crypto engine.
- Package dependency graph: empty; source imports Foundation only.
- iOS Simulator package build: **BUILD SUCCEEDED** (arm64/x86_64). Для `-packageCachePath` Xcode требует абсолютный путь; первый invocation исправлен без clean/cache reset.
- Независимое read-only API/test review завершено; actionable gaps закрыты (authenticated peer identity, envelope discriminator, multi-session payload composition, private prekey public-record invariant).

App source/manifests/linkage не менялись. Library crypto interoperability, actual generation/signing/encrypt/decrypt и secure snapshot restore ещё не проверяются: это L02–L07. License selection/version tag/remote отсутствуют до release work.

Links: [package README](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/README.md>), [public API](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Sources/XabberCryptoSwift/CryptoEngine.swift>), [L01 tests](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Tests/XabberCryptoSwiftTests/L01ModelTests.swift>), [execution plan](omemo2-independent-library-plan-2026-10-09.md).

## Commit

Первый commit package: `bba64e9671ad2b37b900e50a5703d60bd85a437e` (`codex/l01-package`). 19 own-source/test/doc files; build caches ignored.
