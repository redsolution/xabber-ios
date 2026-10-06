# OMEMO2 N05 — обслуживание SPK и публикации

Завершено 2026-10-06. [XEP-0384 §4.2](https://xmpp.org/extensions/xep-0384.html#protocol-key_exchange) рекомендует периодическую ротацию SPK и хранение старого ключа ещё один период. Это SHOULD, не новое MUST. Сервер и trust exchange не изменены.

## Поведение

- Одна `maintainKeysIfDue` атомарно ротирует due SPK и удаляет expired retired SPK. Identity/SID/session snapshots сохраняются. Период7 дней и grace7 дней — действующая политика клиента.
- Обычные ensure/send/control/receive, auth и foreground используют общий due check с ограничением60 секунд; failed save не закрывает следующую попытку. Public metadata обновляется только по committed bundle. Не создаётся новое устройство, если существующий профиль недоступен.
- Существующий replenish100 и minimum public count сохраняются на publication/KEX boundary; отдельная реализация OPK не вводилась.
- Публикация имеет60 секунд backoff после ошибки и120 секунд timeout IQ. Одна отменяемая work item в существующей owner queue запускает повтор даже на idle authenticated connection. Direct auth publication failure до IQ тоже планирует retry. Закрытый secondary stream не заслоняет authenticated primary.
- Только hash-matched PEP result подтверждает текущий bundle. Старые/expired ACK не отмечают новый SPK published. Configuration error/timeout снимают запрет следующей configure attempt; queued callbacks после disable не публикуют/не конфигурируют node. Disabled account не запускает foreground maintenance и отменяет retries.
- Shared flags/cache/ACK/registration/disable сериализованы одним recursive lock. Перед flushControls lock отпускается, сохраняя sessionQueue→maintenance order. Timer не удерживает account/manager.

## Проверка

Task-specific `OMEMO2NormativeKeyMaintenanceTests.swift`: **25/25** финальных XCTest. Настоящий ciphertext на send/control/raw/verified receive; weekly boundary/idempotence, old-SPK grace/expiry/known-EK, failed protected save, stale ACK, public prekey100, foreground, idle retry/timeout, disable, config error/timeout and direct auth error.

TDD первоначальные12 случаев дали16 meaningful assertions,0 unexpected; первый combined gate119/119 (N05 тогда21 + N02/N04/state/app/outgoing regressions), review gate40/40 (N05 тогда24 + registration16), final25/25 после direct auth error fix. Каждый cached Debug Simulator gate собрал app и push extension; compiler/linker errors отсутствуют. No clean/cache reset; disposable artifacts removed after summaries. Live server interoperability не выполнялся.

Signal C/ObjC не менялись в N05. Согласованные plaintext markers/receipts, fallback body и hints сохранены. N06 остаётся следующей отдельной задачей.
