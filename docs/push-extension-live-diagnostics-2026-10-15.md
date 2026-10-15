# Push extension: запуск диагностики на iPad

2026-10-15. Final103/103 tests passed, zero failures/unexpected: HTTP36, hosted isolation10, logger4, rich content26, provisioning26, pipeline1. Simulator test action built app and NSE; signed physical Debug build/install/launch also passed. Latest app debug dylib UUID ABBA2ADC-787B-334F-B33B-20886CEA5422; NSE UUID CDF115C8-CA36-35AA-BE43-9DF140495633. On iPad(Redsolution), final host PID1002 logged at2026-10-15 16:15:18 +05:00 primary connected=false/disconnected=true, uiConnected=false/uiDisconnected=true; a primary restore attempt was explicitly blocked. At16:15:39 background snapshot confirmed both streams still disconnected. App is left running in background without force-quitting.

Debug-процесс запущен с XABBER_PUSH_DIAGNOSTICS_OFFLINE=1: основные и вспомогательные XMPP-подключения запрещены, реальные данные/Keychain/регистрация пушей сохранены. Обычный перезапуск без флага возвращает стандартное поведение. Приложение оставлено в фоне; сервер не менялся.

NSE пишет raw APNs payload, расшифрованный XML, этапы Keychain/full-summary/HTTP/парсинга/рендера/fallback/completion/expiry. HTTP URL/Bearer/headers и принятые raw bytes не редактируются. Полные записи находятся в App Group Library/Logs/PushExtension, отдельный файл на процесс; NSLog дублируется частями до700UTF8байт. Callback HTTP завершается после записи диагностики. В Release новые диагностические режимы выключены.

Полные файлы непрерывно копируются на Mac каждые3секунды:

- /Users/igor.boldin/Library/Logs/XabberPushDiagnostics/push-extension-full-live.log — общий журнал.
- /Users/igor.boldin/Library/Logs/XabberPushDiagnostics/device-files/ — полные файлы процессов.
- ipad-push-live-2026-10-15.log — дополнительный системный захват, не заменяет файлы NSE.

На момент подготовки фактический запуск NSE и доставка пуша ещё не наблюдались. Настройка готова к тестовому push; его результат нужно оценить по следующему trace. Raw диагностические файлы не входят в Git. Изменены NSE NotificationService/NetworkManager, shared PushExtensionDiagnostics/PushArchiveHTTPClient, Debug host launch/connect gates и соответствующие XCTest.


## Проверка после тестового сообщения, 16:25–16:30 +05:00

Пользователь сообщил об отправленном сообщении. Повторное чтение самого App Group на iPad подтвердило только два файла процессов хоста: PID919 (256bytes) и PID1002 (927bytes). Агрегат1302bytes; новых файлов NSE, `extension_init`, `receive`, `payload_raw`, HTTP GET/response/parser/render/completion нет. Сборщик жив и успешно читает устройство каждые3секунды. Поэтому получение APNs/вход в NSE и HTTP MAM **не подтверждены**; нельзя объявлять ошибкой MAM или JWT цепочку, которая не дошла до расширения.

Подпись physical app/NSE корректна; общий App Group и Keychain совпадают. Principal class/extension point корректны. В физической debug.dylib присутствуют диагностические строки; вызов `record()` из `log()` подтверждён дизассемблированием. NSE executable UUID CDF115C8-CA36-35AA-BE43-9DF140495633 и отдельная NSE debug.dylib UUID EE006D98-A884-3B8F-ACE5-E5B0C38B0D45 относятся к одной сборке. В доступном systemCrashLogs нет файлов с xabber в имени; это не исключает ошибку активации без crash report.

В16:26:30 начат дополнительный live-захват apsd/usernotificationsd/SpringBoard/runningboardd в `/Users/igor.boldin/Library/Logs/XabberPushDiagnostics/ipad-push-system-live-2026-10-15.log`. Исторический `log collect --device-udid` недоступен безroot; noninteractive sudo также недоступен. Этот захват не покрывает момент первоначальной отправки. В новом окне наблюдаются повторные закрытия development/production APNs через utun5: например16:28:30 `Disconnected in response to connection failure`, lower protocol error57 после TLS handshake, затем переподключение. Причинная связь с конкретным сообщением не установлена; системный `<private>` оставлен как выдан ОС, это не редактирование клиентского XML.

HTTP-путь для этого сообщения остаётся непроверенным на всех этапах: APNs input → decrypted summary/id+by → current shared grant → GET by-id/Bearer → response XML → exact archive result → rendered notification. Известная успешная выдача JWT в14:42 не подтверждает актуальность токена в16:30; последнее наблюдавшееся expiry15:42 уже прошло, а возможный refresh обычного запуска16:06 не попал в текущие файлы. Не подменять это выводом о текущем истёкшем grant без чтения нового snapshot.

Приложение оставлено в фоне в том же offline-процессе; сервер и приложение в этой проверке не менялись, сборщики продолжают работу. Для следующего сообщения одновременно готовы App Group и системный захваты. Изменены только отчёты; повторная сборка/тесты для read-only проверки не требовались.
