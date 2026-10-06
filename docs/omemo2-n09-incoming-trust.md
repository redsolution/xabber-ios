# OM2-N09 — доверие фактическому отправителю

## Норма и границы

[XEP-0384 §8](https://xmpp.org/extensions/xep-0384.html#security): при приёме через недоверенную сессию клиент SHOULD показать её недоверенный характер; пустые сообщения — исключение. Это выполнение рекомендации, а не устранение нарушения MUST.

Оценка read-only, по существующим trust state и fingerprint фактического authenticated identity key. Trust/code exchange и выдача доверия не меняются. Сервер не меняется; plaintext markers/receipts, fallback body и hints сохранены.

## Контракт

Typed `OMEMOAuthenticatedSender` передаётся отдельно от XML/provenance. Exact candidate remoteIdentityKey раскрывается после protected save во всех трёх ветках decrypt, после owner unlock и до cleanup. Trust predicate только читает scoped existing trusted state + exact fingerprint; membership/current session key не заменяют actual key архивной сессии. Controls, duplicate, failure и legacy profile не создают companion.

Локальный receive-time sender snapshot сохраняется в существующей `systemMetadata_`; он показывает предупреждение и не восстанавливает encryption provenance. Outgoing skipped-recipient warning остаётся отдельной metadata, две warning строки могут отображаться вместе. Новая Realm schema не нужна.

Normal/search materializers и verified encrypted rewrite (включая deferred retry) применяют snapshot к фактической leaf stanza. Existing-row merge требует owner/peer/type, body/legacyBody, stable reference content и exact XML. Owner-scoped persisted stanza позволяет корректный direct-saved restart; другой cached body/reference с тем же ID не получает snapshot. Persisted-only inline forwards без исходного объекта не дают нового доказательства; прежняя local warning сохраняется. Sync internal value удерживает companion, XML serialization его не восстанавливает; detached conversation preview не является timeline row и proof cache не получает. Saved forwarded history не наследует outer proof.

Найден конкретный UI gap у существующих persisted sticker rows: отдельная cell/layout не показывала warning. Существующие `.system` timer/history rows имеют тот же gap. Rendering6 FIRST проверяют размер, configure/chrome/reuse и сохранение обычной date/sticker geometry. Image/thumbnail size сохраняется.

## Соответствие нормы и проверки

| Условие XEP-0384 §8 / граница реализации | Проверка |
| --- | --- |
| Read-only indication доверия фактическому authenticated identity | Trusted/unknown/distrusted/mismatch; missing projection и removed membership |
| Историческая session не подменяется current key | Archived regular snapshots и receive-only KEX с настоящим ciphertext |
| Только успешный decrypt создаёт companion | Protected-save rollback, MAC failure, callback после commit/outside lock/before cleanup |
| Empty/control/replay не создают warning/bubble | Control и authenticated duplicate tests |
| Один sender snapshot в разных маршрутах | Live, MAM, sent/received carbon, search, attachment-only; sync internal value/serialization |
| XML не устанавливает trust | Outer trust/success marker, unsupported proof и owner/from/SID mismatch |
| Local persistence не переносит proof на другое содержимое | Restart, cached body/reference count/metadata collisions, saved direct/forward, rewrite |
| Предупреждение видно и не остаётся после reuse | Sticker/system layout и configure/chrome/reuse; independent outgoing warning |
| Локализованная copy действительно собрана | Catalog и compiled app/push resources во всех шести языках |

Background/UI-action handoffs проверены статически; ciphertext tests исполняют общий receiver, а не сами stream delegates. Sync companion остаётся в typed value; detached preview не получает timeline warning. Это не новое требование XEP к preview.

## Проверка

TDD выполнялся по этапам: valid storage control дал 2 expected missing-callback assertions; согласованные protected/transport dates довели ciphertext fixtures до missing-warning RED; async search callback ожидался отдельно. Rendering/cache FIRST выявили отсутствие предупреждений и неверную привязку по одному ID. Reference-only FIRST подтвердил две ложные привязки для разных geoloc/contact metadata при пустом body; exact rich positives прошли. Затем восстановлено сравнение stable reference content. Невалидный PDF fixture заменён реально разбираемым geoloc, отдельная ошибка sticker container margin исправлена в существующем override.

Narrow corrections3/3 и focused N09 38/38 прошли, 0 failures. Affected gate40 classes завершил679 tests:677 passed,2 methods failed с5 assertions,0unexpected. Оба fixture failure существовали до N09: obsolete schema22 при current25, rewrite wrapperfrom/uppercase generated owner против действующего owning-JID guard. Исправлены только test fixtures; повтор всего ClientSynchronizationPaginationTests из-за общего owner setup дал50/50,0failures. Production guard/schema не менялись. Все679 выбранных сценариев имеют passing latest result по этим двум gates; единого679/679 run после fixture correction не выполнялось. Localization manifest:1826 active keys, missing English/hardcoded/unresolved0; одна новая copy во всех шести языках проверена и в catalog, и в compiled app/push resources. Existing fallbackConflicts16 — неизменённая baseline manifest. `tools/xcodebuild_cached.sh test`, scheme Debug, iPhone16 Pro iOS26, isolated storage/account autoconnect disabled; без clean/reset cache. Успешные test actions собрали приложение и встроенный push extension, ошибок компиляции/линковки нет. Отдельная Debug build не выполнялась. Live server interoperability не выполнялся. Нативные Signal C/ObjC в N09 не менялись.

## Файлы и завершение

Core: `OMEMOReceive.swift`, `OmemoManager.swift`, `XabberOMEMO2Storage.swift`. Передача: main/background/UI-action delegates, queue/common receiver, MAM/search, sync, rewrite и favorites. Persistence/warning: `MessageStorageItem.swift`, общий label factory, text/sticker/system cells и layout. Один copy key в `Localizable.xcstrings`/active manifest. Четыре task-specific XCTest файла зарегистрированы в project; существующие receive result patterns обновлены для третьего associated value. Sync tests получили только описанные fixture corrections.

Shared interfaces, owner UI/XMPP/business/tests notes, standalone task/handoff и contributor KB inbox отражают результат. Native repos/server чистые; N09 не меняет trust exchange, profile/wire, plaintext markers/receipts, fallback/hints. Непроверенными остаются live cross-client/server interoperability и отдельный запуск background/UI-action delegates; их typed handoffs проверены статически. Известные шесть generic localization baseline failures вне выбранного gate описаны в [N07](omemo2-n07-session-recovery.md); N09 localized copy прошла.
