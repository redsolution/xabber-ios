# XabberCryptoSwift: происхождение реализации

Дата: 2026-10-09. Основание: пользователь требует независимую от libsignal реализацию с проверяемым
происхождением кода. Проверен package на implementation commit845f90f; production code не менялся.

## Обязательное правило

Разработка опирается на опубликованные protocol/algorithm specifications, стандарты и Apple SDK APIs.
Libsignal/SignalProtocolC/ObjC и их форки запрещены как implementation reference, шаблон API/state,
источник code/tests/fixtures/patches/reference scripts или oracle для expected bytes. Нельзя получить
независимый код переименованием, переводом в Swift или переписыванием library implementation.
Published X3DH/Double Ratchet specifications на signal.org — отдельные algorithm documents.

Expected bytes создаются стандартными атрибутированными vectors и собственными независимыми tools
поверх объявленных primitive providers. Runtime и reference-tooling dependencies различаются явно.
External imports требуют provenance/terms/attribution до использования; добавление стороннего source
или runtime dependency — отдельного разрешения maintainers. Distribution license ещё не выбрана.

## Проверка

- `swift package show-dependencies --format json`: empty dependencies. Production imports — Apple
  SDK и собственный CXabberCrypto; binary/vendor/Signal target отсутствует.
- L03/L04/L05 generators используют Python stdlib, объявленный cryptography/OpenSSL primitive backend
  и только собственные sibling generators. Нет Signal imports, source reads, subprocess oracle или
  network fetch. Package source не используется как independent reference.
- Fixture metadata фиксирует standard/synthetic origins; ссылки signal.org — specification URLs.
  В package source/tools/fixtures не найдено undeclared libsignal dependence. История — собственные
  отдельные implementation commits; snapshot record свой.

Первоначальный dependency/migration audit исследовал существующую Signal integration. Поэтому весь
процесс не называется формальным clean-room, где разработчики никогда не видели прошлую реализацию.
Ранняя рекомендация адаптировать её tests/reference script отменена в requirements и execution plan.
Отсутствие dependency/import не является доказательством авторства каждой строки или юридической
оценкой; сохраняем provenance и разрешаем выявленные вопросы до release.

L02 conversion metadata содержит исторические ссылки на libsodium docs и test source
`core_ed25519.c`, при заявленной independent affine derivation. L02 generator не сохранён в Tools.
Это не libsignal dependency, но самостоятельный provenance/reproducibility gap: перед L07 release
нужны сохранённый standards-based generator и review boundary origin/attribution. Метаданные не
переписывались для косметического удаления ссылок. В текущей проверке внешние implementation sources
не открывались; source comparison и юридическая экспертиза не выполнялись.

Правило закреплено в package AGENTS.md, NOTICE.md и
[SOURCE_POLICY.md](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/SOURCE_POLICY.md>).
README и runtime implementation не менялись; новые test/build runs для документации не требуются.
L05 verification224/34 independent snapshots/ASan6753 остаётся предыдущим результатом без повторного
заявления о новой проверке кода. Лицензия release и provenance acceptance остаются gates L07.
