# OM2-N08 — проверенный opt-out и запрет отправки

## Норма и границы

[XEP-0384 §5.7](https://xmpp.org/extensions/xep-0384.html#opt-out): проверенный opt-out требует решения пользователя; до него все исходящие сообщения контакту запрещены (MUST). Показ запроса и сохранение sessions — SHOULD. Явный выбор «сохранить шифрование» использует разрешённый возврат к OMEMO; это политика клиента.

Сервер остаётся источником истины и не меняется. Trust/code exchange сохраняется. Delivery/read markers и receipts остаются открытыми; pending gate запрещает отправку до решения, не меняя их формат. Fallback body и store hints сохраняются. Нового outbox/journal нет.

## Контракт

- Только успешно проверенное SCE с QName `{urn:xmpp:omemo:2}opt-out` от фактического peer создаёт pending. Внешнее XML, foreign namespace, failed decrypt и own sent carbon разрешения не дают.
- `optOutDecisions` — небольшое optional поле существующего protected account state. Pending, ratchet, replay proof и consumed OPK сохраняются одним существующим aggregate write после crypto/SCE validation. Ошибка сохранения откатывает всё и оставляет retry допустимым.
- Realm `OMEMO2OptOutStorageItem` — scoped UI projection. Send permission читает защищённый источник; устаревшая/отсутствующая projection не разблокирует отправку. Недоступный защищённый источник закрывает gate, отсутствующий state позволяет обычные сообщения.
- Resolution сохраняет cryptographic state. Exact authenticated replay не отменяет решение; protected SCE time и resolved watermark защищают от ранее не полученного старого archive. Timestamp-less historical request после решения консервативно не открывает новый pending. Последние две границы — клиентская политика, не дополнительные нормы XEP.
- Pending проверяется до шифрования, queue reservation, edit/persist/upload/schedule и на конечных stream send callbacks. Known rewrite/schedule/XEN IQ проверяются по фактическому peer, включая реально создаваемые и сериализованные формы. Отфильтрованная stanza снимает tracker/receipt timeout и нейтрально возвращает не отправленную queue reservation, не расходуя retry attempt.
- Composer сохраняет draft и предлагает Cancel / Keep encryption / Continue unencrypted. Решение записывается на account queue. После plaintext новые отправки идут через обычный chat route, старый OMEMO chat/history и ratchets сохраняются.

## Фактическое поведение сервера

`mod_mam.erl:505–559` определяет conversation_type по EME, отсутствие EME — обычная переписка; `mod_sync.erl:487` проецирует её как `urn:xabber:chat`. `mod_retract.erl:547–573` при редактировании сохраняет старый conversation_type. Поэтому подтверждение не переписывает encrypted history и не делает plaintext override существующего OMEMO controller. Server edits старой encrypted history по-прежнему шифруются.

VoIP получает только final outgoing send policy. Incoming decrypt и ratchet к VoIP stream не подключаются.

## Проверка

Выполнено 2026-10-06. TDD: initial core23/UI11 (34cases/61 expected assertions), actual wrapper2 (7assertions), pure/control+transport+copy12 (34assertions), early sender4 + owner binding и две tracker-generation регрессии, deferred-upload1/UI-admission2 воспроизведены до реализации. Realm immutable-primary projection исправлена; scene-attached UIKit fixture восстановил реальные navigation связи. Core33/UI12/copy1 прошли промежуточный gate; core34 и transport9 прошли итоговый.

Итоговый affected gate: 392 cases, 390 passed; два новых UI admission теста остановились на offline archive skeleton в fixture. Исправлены только условия fixture, production guard и проверки черновика сохранены. Последний focused UI/composer gate: 50/50, включая все 14 N08 UI cases. Все затронутые случаи имеют успешный последний результат; core34, transport9 и copy1 прошли affected gate. App и push extension собраны cached Debug Simulator test action. Manifest1825active keys,0missingEnglish/hardcoded/unresolved;6новых copy keys во всех6locale, существующие значения не менялись. Полный generic LocalizationTests повторно не запускался:6прежних failures классифицированы в N07report, вне этой задачи. Проверка завершена; отдельная Debug build не нужна после успешного test action. Live server interoperability не выполнялся.
