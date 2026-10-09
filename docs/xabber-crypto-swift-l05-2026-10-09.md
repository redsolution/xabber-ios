# XabberCryptoSwift — L05 snapshots and restart

Дата: 2026-10-09. Статус: реализация и проверки завершены в отдельном SwiftPM package на master → origin/master.

Package commit `845f90f` — `Add versioned session snapshots and restore validation`.

## Результат

`XabberCryptoEngine` реализует `SessionStateCoding`: `serializeState` возвращает собственный versioned
secret snapshot, `restoreState` восстанавливает проверенный immutable state. Пакет сохраняет исходные
Ed25519 identity bytes/AD, root/chain/private ratchet keys, pending KEX/private EK, counters, policy,
retired DH history и skipped-key FIFO/receive-event ages. Новый engine продолжает тот же обмен после
перезапуска. Transport, trust, session association и storage остаются у приложения; runtime dependencies
не добавлены, Signal records/source и legacy importer отсутствуют.

Собственный canonical v1 format: magic `XCSSTATE`, BE version/body length, ordered bounded body,
SHA256(header+body). Максимум complete snapshot — 3 MiB. Размеры/counts проверяются до allocation/native
key work. Encoding/restore не сортирует записи, не нормализует private scalars, не меняет policy и
не запрашивает RNG. Corruption/invalid state → `invalidSnapshot`; корректный envelope неизвестной
версии → `unsupportedSnapshotVersion`; native provider failure сохраняет `providerFailure`.

Restore проверяет Ed points, canonical safe X25519 keys, clamped private/public consistency, точный AD
и role/phase relationships. Pending initiator не имеет receive history; mature state имеет обе chains,
точное число retired keys, допустимые counters/events. Skipped records проверяются по chain/N, birth,
expiry, FIFO order и budget. Terminal counters сохраняются; дальнейшие операции по-прежнему проверяют
overflow. Произвольные root/chain/message key32 допустимы: валидатор не доказывает прошлые derivations.

## Граница хранения и commit

Snapshot содержит **plaintext secrets**. SHA256 выявляет случайное повреждение, не обеспечивает
authenticity/confidentiality и не обнаруживает rollback; изменивший bytes может пересчитать checksum.
Host предоставляет authenticated protected storage, правильную session association, rollback policy,
serialized/CAS updates и atomic state/OPK consumption. Пакет не выполняет storage writes/locks/reset.

Outgoing candidate сохраняется перед использованием ciphertext; после delivery failure повторяется
сохранённый ciphertext. Incoming content остаётся provisional до host policy и atomic commit. Ошибка
restore/commit или отказ от ещё не использованного candidate сохраняет предыдущий committed state.
Ошибка protected state не должна автоматически создавать новую identity. Repeated matching-EK KEX
после восстановления не требует повторного OPK lookup/consumption. Snapshot validation не является
проверкой принадлежности состояния конкретной записи host storage.

## Проверки

Core codec/validator и public restart tests написаны первыми; RED подтверждён отсутствующими codec/
validation/public methods, затем реализация дала GREEN. Независимые fixtures созданы отдельным Python
генератором до чтения Swift codec. Первый запуск independent XCTest состоялся уже после параллельного
появления codec; отдельный RED этого набора не заявляется.

- `swift test`: **224/224**, включая codec27, validation19, independent snapshots6, public restart10
  и прежние162 tests.
- Independent reference: **34 snapshots**, точные canonical bytes/state fields, все18 conversation
  events,9 reorder deliveries и3+3 FIFO/lifetime states. `GenerateL05Vectors.py --check` прошёл.
  Reference struct/hashlib и собственные L03/L04 equations не используют Swift encoder/Signal.
- `swift build -c release`, external ContractConsumer Debug/Release/ASan и cached iOS Simulator
  **arm64/x86_64**: passed. Consumer использует только public imports и fresh-engine restore на
  send/receive checkpoints. Compiler/linker errors и warnings отсутствуют.
- Standalone **actual-source Swift/C ASan: 6753 inputs**, включая34 mandatory positive vectors,
  raw/rechecksummed corruption/truncation, coherent AD/malformed keys, flags/config/count bombs,
  unknown versions, Data slices и garbage. Любой принятый input canonical re-encodes/re-restores.
  System policy/signing не менялись; signed XCTest discovery helper restriction обходится отдельным
  host executable без изменения платформы.
- Source review проверил cheap checks before native crypto, private-key consistency, pending/mature
  invariants, bounded lists, checksum/version dispatch и FIFO/expiry/history preservation. Package.swift
  dependencies пусты; consumer linkage только system frameworks/libraries.

Disposable logs/binaries удаляются после проверки, build caches сохраняются. Xabber app source/backend/
manifests не менялись. L06 explanatory consumer/host workflow и L07 live-peer/security/release acceptance
остаются отдельными этапами; L05 не означает готовый audited release или host storage implementation.

Ссылки: [API](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/API.md>),
[snapshot format](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/SNAPSHOT_FORMAT.md>),
[проверки](</Users/igor.boldin/projects/xabber/deps/XabberCryptoSwift/Documentation/TESTING.md>),
[план](omemo2-independent-library-plan-2026-10-09.md).
