# Git-репозитории зависимостей вне redsolution

Список происхождения зависимостей CocoaPods/SPM и required submodule. OMEMO с 2026-10-14 использует [XabberCryptoSwift через SwiftPM](local-dependencies.md); SignalProtocolC/ObjC удалены.

Вне redsolution находятся 20 source/packaging repository:

| Репозиторий | Пакет | Новое локальное подключение для OMEMO |
| --- | --- | --- |
| [Alamofire/Alamofire](https://github.com/Alamofire/Alamofire) | Alamofire | Нет |
| [hyperoslo/Cache](https://github.com/hyperoslo/Cache) | Cache | Нет |
| [robbiehanson/CocoaAsyncSocket](https://github.com/robbiehanson/CocoaAsyncSocket) | CocoaAsyncSocket | Нет |
| [CocoaLumberjack/CocoaLumberjack](https://github.com/CocoaLumberjack/CocoaLumberjack) | CocoaLumberjack | Нет |
| [krzyzanowskim/CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift) | CryptoSwift | Нет |
| [onmyway133/DeepDiff](https://github.com/onmyway133/DeepDiff) | DeepDiff | Нет |
| [robbiehanson/KissXML](https://github.com/robbiehanson/KissXML) | KissXML | Нет |
| [vpeschenkov/LetterAvatarKit](https://github.com/vpeschenkov/LetterAvatarKit) | LetterAvatarKit | Нет |
| [chrisballinger/libidn-framework](https://github.com/chrisballinger/libidn-framework) | libidn | Нет |
| [material-components/material-components-ios](https://github.com/material-components/material-components-ios) | MaterialComponents | Нет |
| [krzyzanowskim/OpenSSL](https://github.com/krzyzanowskim/OpenSSL) | OpenSSL-Universal | Нет |
| [gumob/PunycodeSwift](https://github.com/gumob/PunycodeSwift) | Punycode | Нет |
| [realm/realm-swift](https://github.com/realm/realm-swift) | Realm, RealmSwift | Нет |
| [ReactiveX/RxSwift](https://github.com/ReactiveX/RxSwift) | RxCocoa, RxRelay, RxSwift | Нет |
| [jrendel/SwiftKeychainWrapper](https://github.com/jrendel/SwiftKeychainWrapper) | SwiftKeychainWrapper | Нет |
| [webrtc-sdk/Specs](https://github.com/webrtc-sdk/Specs) | WebRTC-SDK | Нет |
| [Yubico/yubikit-ios](https://github.com/Yubico/yubikit-ios) | YubiKit | Нет |
| [vector-im/ogg-swift](https://github.com/vector-im/ogg-swift) | ogg-swift | Нет |
| [vector-im/opus-swift](https://github.com/vector-im/opus-swift) | opus-swift | Нет |
| [xiph/opus](https://github.com/xiph/opus) | xiph-opus | Нет |


## Существующие локальные forks

До этой задачи существовали `XMPPFramework`, `RxRealm`, `Klingfisher` с origin в `whspr`. Их прежние origin и ветки сохранены. Источники подключений RxRealm/Kingfisher указывают redsolution; уже активный локальный XMPPFramework использует whspr checkout. Эти forks не получают новых рабочих веток в рамках подготовки OMEMO.

## Бинарные движки и встроенный код

- [realm/realm-core](https://github.com/realm/realm-core), 13.26.0; [openssl/openssl](https://github.com/openssl/openssl), 3.3.3; [WebRTC](https://webrtc.googlesource.com/src) — движки бинарных distributions. Packaging repositories в таблице не являются их полными исходниками.
- Встроенный Toast-Swift и Base64-код, производный от [lemire/fastbase64](https://github.com/lemire/fastbase64) и [client9/stringencoders](https://github.com/client9/stringencoders), уже находятся в app source.
- Неинициализированные developer-tool submodules MaterialComponents не используются Palettes и не входят в этот список runtime-подключений.

Дополнительные checkout, локальные бинарные копии и рабочие ветки, ошибочно созданные при первоначальном слишком широком толковании задачи, удалены. Подключения и pins остальных пакетов восстановлены.


## XabberCryptoSwift

SwiftPM SSH dependency `git@github.com:redsolution/XabberCryptoSwift.git`, pinned `bd5d19dbd8e9de2521c8830f54564d3cc175cba8`. Its authorized bundled libsodium1.0.22 uses upstream [jedisct1/libsodium](https://github.com/jedisct1/libsodium); artifact/source/license hashes are in the package inventory. App includes ISC/BSD notices. CryptoSwift and Curve25519Kit remain for unrelated AKE/push APIs.
