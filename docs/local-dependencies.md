# Локальные пакеты для изменений OMEMO

В этой задаче локально подключены только два пакета, которые обязательно потребуют изменений по [плану миграции](/Users/igor.boldin/projects/xabber/xabber/projects/xabber/docs/architecture/ios-omemo-standard-migration-plan-2026-10-01.md).

| Пакет | Версия | Checkout | Ветка | Git источник |
| --- | --- | --- | --- | --- |
| SignalProtocolC | 2.3.2 | `projects/xabber/deps/SignalProtocolC` | `codex/ios-local-dependencies` | [WhisperSystems/libsignal-protocol-c](https://github.com/WhisperSystems/libsignal-protocol-c) |
| SignalProtocolObjC | 1.1.0 | `projects/xabber/deps/SignalProtocolObjC` | `codex/ios-local-dependencies` | [redsolution/SignalProtocol-ObjC](https://github.com/redsolution/SignalProtocol-ObjC) |

SignalProtocolC содержит криптографическое ядро, HKDF, Double Ratchet, protobuf и MAC. SignalProtocolObjC содержит Objective-C API, модели сообщений/ключей и связь с ядром. Добавлен явный OMEMO2 API согласно [описанию профиля](omemo2-dependency-profile.md). Приложение пока использует прежний Signal API; подключение нового профиля и миграция storage остаются отдельным этапом.

## Подключение

Podfile подключает оба пакета через `:path`; локальный podspec должен иметь версию из [manifest](../tools/local-dependencies.json). Базовые commits сохранены: C — `4a137eaf4eb4421949e2e1dde9f11ec7bc07b88f`, ObjC — `597bb713d9cadda855f150f6066c50521481213f`. Подготовительный commit C — `c84fa08be27d1898fd607c4f568f4d6ceb897147`.

В C добавлен отсутствующий upstream root podspec из resolved спецификации 2.3.2; внутренние header paths настроены в `pod_target_xcconfig` через `PODS_TARGET_SRCROOT`. [Patch](../tools/local-dependencies/patches/SignalProtocolC.patch) позволяет восстановить подготовку на новом checkout. Оба восстановительных patches теперь содержат полный проверенный OMEMO2 профиль и тесты. Точные commits C/ObjC сохранены в manifest; bootstrap воспроизводит изменения поверх прежних pinned bases.

```bash
python3 tools/local_dependencies.py check
python3 tools/local_dependencies.py bootstrap
pod install --no-repo-update
XABBER_DESTINATION='platform=iOS Simulator,id=<available-UUID>' tools/xcodebuild_cached.sh build CODE_SIGNING_ALLOWED=NO
```

Корень по умолчанию — `../../../../../deps` относительно iOS-проекта. Утилита и Podfile поддерживают `XABBER_DEPS_ROOT`. Утилита создаёт только отсутствующие checkout, сохраняет существующие изменения/ветки и проверяет подготовку; push не выполняется.

Остальные CocoaPods, Xcode SPM references и Package.resolved возвращены к прежнему подключению и закреплённым версиям. XMPPFramework сохраняет уже активный до задачи локальный путь и исходную ветку `light`: это не новое локальное подключение. Существующие RxRealm/Klingfisher возвращены на исходные ветки. Созданные по ошибке checkout остальных библиотек удалены вместе с их подготовительными patches.

Curve25519Kit в плане имеет условные изменения; сейчас он остаётся на прежнем подключении. Изменение CryptoSwift, Realm, OpenSSL и транспортных пакетов для указанного плана не требуется.

## Репозитории вне redsolution в составе подготовки OMEMO

Один: [WhisperSystems/libsignal-protocol-c](https://github.com/WhisperSystems/libsignal-protocol-c), пакет SignalProtocolC. GitHub может перенаправлять прежнее имя организации. SignalProtocolObjC уже использует репозиторий redsolution. Отдельно сохранён [общий список Git-источников остальных зависимостей](dependency-repositories.md); он не расширяет состав локальной подготовки.

## Проверка

Проверено 2026-10-01:

- `python3 tools/local_dependencies.py check` — оба Signal checkout на ожидаемой ветке и подготовленной базе; рабочие деревья чистые.
- `pod install --no-repo-update` — успешно. Новые `:path` только у двух Signal; XMPPFramework сохраняет исходный local source. Версии root/subspec, Git checkout pins и spec checksums остальных библиотек совпадают с исходным lock.
- Xcode SPM references и Package.resolved совпадают с исходной версией проекта.
- `XABBER_DESTINATION='platform=iOS Simulator,id=91E09D3E-4BBC-4431-9EAF-14D2410E7B98' tools/xcodebuild_cached.sh build CODE_SIGNING_ALLOWED=NO` — `BUILD SUCCEEDED`, exit0; Debug, Xcode26.0, iOS26.0 Simulator. Собраны приложение и push extension; output проверен без compiler/linker errors.
- `py_compile` и `git diff --check` — прошли. Сохранённые Git/preparation routines ранее проверены на отказе неподготовленного baseline/чужой ветки, сохранении dirty work и принятии replay patch с будущими edits.

Для нового профиля проверены 3 C-suite и 17 XCTest на Simulator, включая независимый CryptoKit backend и прежний lifecycle (см. [отчёт](omemo2-dependency-profile.md)). Межклиентный обмен остаётся непроверенным. Disposable logs/result bundles удалены; стабильные Xcode caches сохранены. Ветки не отправлены на сервер.
