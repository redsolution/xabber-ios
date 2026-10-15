# Section list wallpaper

Contacts (including Groups), Calls, Notifications, and their category screens now use the active chat wallpaper behind their existing inset rows. Empty states remain transparent. Wallpaper changes refresh existing renderers through `chatBackgroundChanged`.

`UIViewController.applyChatWallpaper(to:emptyView:)` reuses `ChatBackgroundBackdropView`. Compact windows and tab layouts own a table background; regular split windows expose the root's continuous backdrop. Applying the policy during layout handles attachment and window-size changes without adding layered wallpapers. Existing cell, navigation, search, and filtering behavior stays intact.

UI owns this task; Calls and Tests are affected. The configured Igor knowledge/vault locations are unavailable on this machine; the local knowledge README was reviewed and this repository note records the durable result.

Validation: the new regression first failed on Contacts' missing wallpaper, then passed for all six screens, wallpaper updates, repeated appearances, and transparent empty states. 131 focused tests passed, including phone/tablet Contacts, Notifications, Calls and category appearance checks. Two existing Contacts title tests are excluded because upstream renders “Public Groups” while their assertions expect “Public groups”; the wallpaper change does not touch titles.

The isolated hosted tests build a separate app identifier. A normal signed build is used only to install and visually inspect the existing logged-in simulator session.

Signed simulator build succeeded. Visually checked populated Contacts and Notifications plus the Calls empty state on iPhone 17 Pro / iOS 26. The existing green gradient/pattern remains visible around inset groups and behind empty states; app left on Notifications.
