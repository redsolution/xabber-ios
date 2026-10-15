# Push extension: запуск диагностики на iPad

2026-10-15. Final103/103 tests passed, zero failures/unexpected: HTTP36, hosted isolation10, logger4, rich content26, provisioning26, pipeline1. Simulator test action built app and NSE; signed physical Debug build/install/launch also passed. Latest app debug dylib UUID ABBA2ADC-787B-334F-B33B-20886CEA5422; NSE UUID CDF115C8-CA36-35AA-BE43-9DF140495633. On iPad(Redsolution), final host PID1002 logged at2026-10-15 16:15:18 +05:00 primary connected=false/disconnected=true, uiConnected=false/uiDisconnected=true; a primary restore attempt was explicitly blocked. At16:15:39 background snapshot confirmed both streams still disconnected. App is left running in background without force-quitting.

Debug-процесс запущен с XABBER_PUSH_DIAGNOSTICS_OFFLINE=1: основные и вспомогательные XMPP-подключения запрещены, реальные данные/Keychain/регистрация пушей сохранены. Обычный перезапуск без флага возвращает стандартное поведение. Приложение оставлено в фоне; сервер не менялся.

NSE пишет raw APNs payload, расшифрованный XML, этапы Keychain/full-summary/HTTP/парсинга/рендера/fallback/completion/expiry. HTTP URL/Bearer/headers и принятые raw bytes не редактируются. Полные записи находятся в App Group Library/Logs/PushExtension, отдельный файл на процесс; NSLog дублируется частями до700UTF8байт. Callback HTTP завершается после записи диагностики. В Release новые диагностические режимы выключены.

Полные файлы непрерывно копируются на Mac каждые3секунды:

- /Users/igor.boldin/Library/Logs/XabberPushDiagnostics/push-extension-full-live.log — общий журнал.
- /Users/igor.boldin/Library/Logs/XabberPushDiagnostics/device-files/ — полные файлы процессов.
- ipad-push-live-2026-10-15.log — дополнительный системный захват, не заменяет файлы NSE.

На момент подготовки фактический запуск NSE и доставка пуша ещё не наблюдались. Настройка готова к тестовому push; его результат нужно оценить по следующему trace. Raw диагностические файлы не входят в Git. Изменены NSE NotificationService/NetworkManager, shared PushExtensionDiagnostics/PushArchiveHTTPClient, Debug host launch/connect gates и соответствующие XCTest.
