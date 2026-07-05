# UI Audit Report

Audit date: 2026-07-05

Target: Xabber iOS, workspace `xabber.xcworkspace`, scheme `Debug (xabber Workspace)`, bundle id `xabber.ios`, simulator `iPhone 16e` / iOS 26.0 (`7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF`).

Audit standards used:
- Apple Human Interface Guidelines: https://developer.apple.com/design/human-interface-guidelines
- Apple HIG Accessibility: https://developer.apple.com/design/human-interface-guidelines/accessibility
- Apple UI Design Dos and Don'ts: https://developer.apple.com/design/tips/

## Summary

The app is UIKit-first with a modern split/root shell and a broad XMPP surface: chats, calls, notifications, contacts, groups, archive, saved messages, account/security settings, and onboarding/sign-in flows. The current logged-in simulator account allowed runtime coverage of most core authenticated screens and several important security/settings states.

The most serious UI risk is not visual polish but presentation containment: multiple screens that visually appear as modal or pushed destinations leave the previous screen active in the accessibility tree, and several Back controls either do not work from the runtime snapshot or require relaunch to escape. This was observed in Create Entity, Contact/Profile-style overlays, Chat Info/Security, Group Create, Notifications detail, and Settings. This affects VoiceOver, keyboard-like automation, navigation trust, and safe use of destructive/security flows.

The second major theme is inconsistent component systems. Empty states, list rows, floating bottom bars, buttons, icon sizes, avatars, and navigation bars are implemented differently across Chats, Calls, Notifications, Contacts, Groups, Archive, Saved messages, and Settings. The app has a newer reusable `EmptyStateView`, but several flows still use custom or blank empty states.

Accessibility is partially covered: many controls expose labels and identifiers, and core lists remain readable at default size. However, tap targets below 44x44 pt, raw SF Symbol labels, typoed labels, destructive custom actions, blank search-empty states, and broken Dynamic Type behavior in Devices need focused cleanup.

## Screen Inventory

| Screen | Flow | How to get there | Status | Screenshot |
|---|---|---|---|---|
| Chats list | Authenticated root | Launch logged-in app | Verified | [10-chats-list.png](screenshots/10-chats-list.png) |
| Left menu | Root navigation | Chats -> sidebar button | Verified | [11-left-menu.png](screenshots/11-left-menu.png) |
| Create entity | New chat/contact/group | Chats -> plus | Verified, navigation issue | [12-create-entity-menu.png](screenshots/12-create-entity-menu.png) |
| Chats search | Search | Chats -> bottom Search | Verified | [13-chats-search-active.png](screenshots/13-chats-search-active.png) |
| Unread chats filter | Chats filter | Chats -> unread filter | Verified | [14-chats-unread-filter.png](screenshots/14-chats-unread-filter.png) |
| Chat thread, empty bot | Chat | Chats/Create entity side effect -> Call Me Bot | Verified | [20-chat-thread-bot-empty.png](screenshots/20-chat-thread-bot-empty.png) |
| Chat attachment gallery | Chat composer | Chat -> attachments | Verified | [21-chat-attachment-gallery.png](screenshots/21-chat-attachment-gallery.png) |
| Chat info | Chat profile | Chat -> title/avatar | Verified, navigation issue | [22-chat-info-bot.png](screenshots/22-chat-info-bot.png) |
| Secure conversation / verify | Chat security | Chat info warning/back target path | Verified, navigation issue | [23-chat-security-verify.png](screenshots/23-chat-security-verify.png) |
| Contacts list | Contacts | Left menu -> Contacts | Verified | [30-contacts-list.png](screenshots/30-contacts-list.png) |
| Contacts search empty | Contacts search | Contacts -> bottom Search -> typed text | Verified | [31-contacts-search.png](screenshots/31-contacts-search.png) |
| Contact profile | Contact | Contacts -> contact row | Verified, navigation issue | [32-contact-profile.png](screenshots/32-contact-profile.png) |
| Groups list | Groups | Left menu -> Groups | Verified | [40-groups-list.png](screenshots/40-groups-list.png) |
| Create public group form | Groups create | Groups -> Create Group | Verified, navigation issue | [41-groups-create-form.png](screenshots/41-groups-create-form.png) |
| Notifications list | Notifications | Left menu -> Notifications | Verified | [50-notifications-list.png](screenshots/50-notifications-list.png) |
| Notification security detail | Notifications detail | Notifications -> security row | Verified, navigation issue | [51-notification-security-detail.png](screenshots/51-notification-security-detail.png) |
| Calls list | Calls | Left menu -> Calls | Verified | [60-calls-list.png](screenshots/60-calls-list.png) |
| Missed calls filter | Calls filter | Calls -> missed filter | Verified | [61-calls-missed-filter.png](screenshots/61-calls-missed-filter.png) |
| Archive list | Archive | Left menu -> Archive | Verified | [70-archive-list.png](screenshots/70-archive-list.png) |
| Saved messages | Saved chat | Left menu -> Saved messages | Verified | [71-saved-messages-empty-chat.png](screenshots/71-saved-messages-empty-chat.png) |
| Settings main | Settings | Left menu -> Settings | Verified, layering issue | [80-settings-main.png](screenshots/80-settings-main.png) |
| Settings lower rows | Settings | Settings -> scroll | Verified | [81-settings-lower.png](screenshots/81-settings-lower.png) |
| Interface settings | Settings -> Interface | Settings -> Interface row | Verified | [82-settings-interface.png](screenshots/82-settings-interface.png) |
| Devices settings | Settings -> Devices | Settings -> Devices row | Verified | [83-settings-devices.png](screenshots/83-settings-devices.png) |
| Dynamic Type Devices | Accessibility | Devices with `accessibility-extra-extra-extra-large` | Verified | [90-dynamic-type-devices.png](screenshots/90-dynamic-type-devices.png) |
| Dynamic Type Chats | Accessibility | Chats with `accessibility-extra-extra-extra-large` | Verified | [91-dynamic-type-chats.png](screenshots/91-dynamic-type-chats.png) |
| Onboarding welcome | Onboarding | No accounts configured | Requires account reset / credentials not found | - |
| Sign in | Onboarding | Onboarding -> existing account | Requires account reset / credentials not found | - |
| Sign up | Onboarding | Onboarding -> Create new account | Requires account reset / credentials not found | - |
| Server feature/error states | Sign in/sign up | Server response dependent | Requires test server state | - |
| Account profile edit | Settings | Settings -> Profile/status/password | Not runtime verified | - |
| Cloud storage | Settings/account | Settings -> Cloud storage | Not runtime verified, toast observed | - |
| Privacy settings | Settings | Settings -> Privacy | Static inventory only | - |
| Premium | Settings | Settings -> Premium | Static inventory only | - |
| Passcode Lock | Settings | Settings -> Passcode Lock | Static inventory only; availability dependent | - |
| Yubikey setup | Settings | Settings -> Yubikey signature | Static inventory only; hardware dependent | - |
| EULA | Settings | Settings -> EULA | Static inventory only | - |
| Safety and Reporting | Settings | Settings -> Safety and Reporting | Static inventory only | - |
| Group info/members/settings | Groups/chat | Open group or group profile | Requires safe group navigation/data | - |
| Chat message context menus | Chat | Long press message | Requires suitable non-sensitive message data | - |
| Swipe actions | Lists | Swipe row | Not verified to avoid data changes | - |
| Dark mode / high contrast | Accessibility | Simulator appearance/settings | Not verified in this pass | - |

## Findings

### H-01 - High - Modal/pushed screens leak underlying UI and can trap navigation

Screens/components: Create Entity, Contact Profile, Chat Info, Chat Security Verify, Group Create, Notifications detail, Settings.

Description: Several screens visually replace or cover the previous screen, but the runtime accessibility snapshot still exposes tappable elements from the previous screen. Back controls also failed or looped in several of these states, requiring app terminate/relaunch to continue the audit.

Why this is a problem: Users relying on VoiceOver can interact with hidden content or miss the actual screen boundary. Sighted users also see inconsistent navigation affordances: screens look modal, pushed, or full-screen at different times.

Expected standard: A presented destination should own focus, hide inactive underlying content from accessibility, and provide a clear 44x44 pt dismiss/back control that reliably returns to the previous screen.

Screenshot: [12-create-entity-menu.png](screenshots/12-create-entity-menu.png), [22-chat-info-bot.png](screenshots/22-chat-info-bot.png), [41-groups-create-form.png](screenshots/41-groups-create-form.png), [51-notification-security-detail.png](screenshots/51-notification-security-detail.png), [80-settings-main.png](screenshots/80-settings-main.png)

Likely code: `xabber/controllers/split/LeftMenuViewController.swift`, `xabber/application/AppRootCoordinator.swift`, `xabber/controllers/chats/create_new_entity/CreateNewEntityViewController.swift`, `xabber/controllers/chats/info_screens/contact_info/ContactInfoViewController.swift`, `xabber/controllers/settings/SettingsViewController.swift`, `xabber/controllers/notifications/NotificationsListViewController.swift`.

### H-02 - High - Tap targets below 44x44 pt on common and security controls

Screens/components: Chat request/invitation close buttons, Settings top icon buttons, Devices Verify button.

Description: Runtime frames showed close buttons at about 36x36 pt, Settings top icon buttons at about 36x36 pt, and the Devices Verify button at about 68x34 pt.

Why this is a problem: Apple's touch target guidance is at least 44x44 pt. Smaller controls are harder to tap and create an accessibility failure for motor-impaired users.

Expected standard: Every tappable control should have an effective hit area of at least 44x44 pt, even when the visible glyph is smaller.

Screenshot: [10-chats-list.png](screenshots/10-chats-list.png), [80-settings-main.png](screenshots/80-settings-main.png), [83-settings-devices.png](screenshots/83-settings-devices.png)

Likely code: `xabber/controllers/chats/last_chats_list/LastChatsViewController.swift`, `xabber/controllers/chats/last_chats_list/LastChatsViewController+UITableViewDataSource.swift`, `xabber/controllers/settings/SettingsViewController.swift`, `xabber/controllers/chats/info_screens/account_info/devices_list/device_edit/DevicesListViewController.swift`.

### H-03 - High - Devices screen degrades badly at maximum Dynamic Type

Screens/components: Settings -> Devices.

Description: With `accessibility-extra-extra-extra-large`, Devices shows very large headings and helper text that consume most of the viewport. The destructive "Terminate all other sessions" action becomes visually dominant, while active device content is pushed off-screen.

Why this is a problem: A security-critical flow becomes hard to scan and easy to operate incorrectly at an accessibility text size.

Expected standard: Dynamic Type should preserve hierarchy, avoid clipping/overlap, and keep destructive actions clearly separated from informational text.

Screenshot: [90-dynamic-type-devices.png](screenshots/90-dynamic-type-devices.png)

Likely code: `xabber/controllers/chats/info_screens/account_info/devices_list/device_edit/DevicesListViewController.swift`, `xabber/controllers/ake/TrustedDevicesViewController.swift`, `xabber/controllers/settings/SettingsViewController.swift`.

### H-04 - High - Destructive Devices actions are exposed too broadly in accessibility

Screens/components: Settings -> Devices.

Description: The Devices hierarchy exposes a `Revoke token` custom action on device rows and also on static text areas including warning/help content. The "Terminate all other sessions" row is a static text element with destructive semantics.

Why this is a problem: Destructive account/session actions must be unambiguous and scoped to the exact control. Broad custom actions increase the risk of accidental session termination for VoiceOver users.

Expected standard: Destructive actions should be explicit controls with clear labels, confirmation, and no duplicate exposure on non-actionable text.

Screenshot: [83-settings-devices.png](screenshots/83-settings-devices.png), [90-dynamic-type-devices.png](screenshots/90-dynamic-type-devices.png)

Likely code: `xabber/controllers/chats/info_screens/account_info/devices_list/device_edit/DevicesListViewController.swift`.

### M-01 - Medium - Floating bottom bars overlap or visually compete with list content

Screens/components: Chats, Calls, Notifications, Archive, Dynamic Type Chats.

Description: Bottom controls are implemented as floating glass bars that sit over the list. In default Chats and especially Dynamic Type Chats, rows and badges are partly obscured by the bottom bar and toast.

Why this is a problem: Primary content and primary actions compete for the same safe area. Users can lose context near the bottom of a list, and tap targets visually overlap row content.

Expected standard: Lists should reserve bottom content inset equal to the floating bar height plus safe area and avoid toast/bottom-bar overlap.

Screenshot: [10-chats-list.png](screenshots/10-chats-list.png), [50-notifications-list.png](screenshots/50-notifications-list.png), [60-calls-list.png](screenshots/60-calls-list.png), [70-archive-list.png](screenshots/70-archive-list.png), [91-dynamic-type-chats.png](screenshots/91-dynamic-type-chats.png)

Likely code: `xabber/controllers/bars/bottom_bar/FloatingBottomBarView.swift`, `xabber/controllers/chats/last_chats_list/LastChatsViewController.swift`, `xabber/controllers/calls/last_calls/LastCallsViewController.swift`, `xabber/controllers/notifications/NotificationsListViewController.swift`.

### M-02 - Medium - Empty states are inconsistent and sometimes blank

Screens/components: Contacts search, Saved messages, Chats empty, Calls empty, Notifications empty.

Description: The repo contains a reusable `EmptyStateView`, but runtime Contacts search produced a blank empty list and Saved messages opened to an empty chat with only a composer. Static code shows Last Chats still has its own custom `EmptyView`, Calls has both legacy and new empty implementations, and Notifications uses `EmptyStateView`.

Why this is a problem: Empty, search-empty, and no-data states do not teach the user what happened or what to do next.

Expected standard: Core lists should use one empty state system with icon, title, explanatory text, and one relevant action where appropriate.

Screenshot: [31-contacts-search.png](screenshots/31-contacts-search.png), [71-saved-messages-empty-chat.png](screenshots/71-saved-messages-empty-chat.png)

Likely code: `xabber/controllers/base/views/EmptyStateView.swift`, `xabber/controllers/chats/last_chats_list/LastChatsViewController+EmptyView.swift`, `xabber/controllers/calls/last_calls/LastCallsViewController.swift`, `xabber/controllers/calls/last_calls/LastCallsViewController+EmptyView.swift`, `xabber/controllers/chats/contact_list/ContactsViewController+UITableViewDataSource.swift`, `xabber/controllers/notifications/NotificationsListViewController.swift`.

### M-03 - Medium - Search patterns vary and search-empty feedback is weak

Screens/components: Chats search, Contacts search, Calls/Notifications bottom search.

Description: Core search is triggered from a bottom bar rather than a standard navigation search affordance. Contacts search with no results showed no visible title/subtitle/clear empty copy. Chats search kept the list visible under the bottom field.

Why this is a problem: Users cannot easily distinguish "no query", "no matches", and "loading results". The bottom search field is also nonstandard for iOS list search and competes with list controls.

Expected standard: Search should have clear active/inactive states, result counts or empty feedback, and consistent placement across list screens.

Screenshot: [13-chats-search-active.png](screenshots/13-chats-search-active.png), [31-contacts-search.png](screenshots/31-contacts-search.png)

Likely code: `xabber/controllers/chats/last_chats_list/LastChatsViewController+Search.swift`, `xabber/controllers/chats/contact_list/ContactsViewController+Search.swift`, `xabber/controllers/calls/last_calls/LastCallsViewController.swift`, `xabber/controllers/notifications/NotificationsListViewController.swift`.

### M-04 - Medium - Navigation bars and icon buttons use inconsistent sizing and meaning

Screens/components: Chats, Contact Profile, Create Entity, Settings, Interface, Devices.

Description: The app mixes circular glass nav buttons, plain nav rows, hidden/no-title screens, and top-right icons. Some icons expose raw labels such as `paintpalette`, `qr code`, `warning`, and `questionmark.app.dashed`; one composer label is typoed as `attachements`.

Why this is a problem: Users need consistent meaning for navigation, secondary actions, and security warnings. Raw symbol names also reduce VoiceOver clarity.

Expected standard: Use consistent navigation bar patterns per flow, meaningful localized accessibility labels, and 44x44 pt effective button targets.

Screenshot: [12-create-entity-menu.png](screenshots/12-create-entity-menu.png), [32-contact-profile.png](screenshots/32-contact-profile.png), [80-settings-main.png](screenshots/80-settings-main.png), [82-settings-interface.png](screenshots/82-settings-interface.png)

Likely code: `xabber/controllers/bars/XabberGlassStyle.swift`, `xabber/controllers/bars/NavigationBarItemOwnership.swift`, `xabber/controllers/chats/create_new_entity/CreateNewEntityViewController.swift`, `xabber/controllers/chats/chat/ChatViewController.swift`, `xabber/controllers/settings/SettingsViewController.swift`.

### M-05 - Medium - List row metrics and text behavior differ across similar lists

Screens/components: Chats, Calls, Notifications, Contacts, Groups, Archive, Settings.

Description: Chats use large avatar rows; Calls use denser rows; Groups allow very long descriptions to create tall rows; Notifications display long security messages in variable-height rows; Settings uses 52-60 pt rows. Similar "list of entities" screens therefore feel unrelated.

Why this is a problem: Users cannot transfer scanning habits from one core list to another. Long strings can dominate the screen and hurt row-to-row comparison.

Expected standard: Define shared row families and constraints: avatar size, title/subtitle typography, metadata alignment, max lines, and spacing.

Screenshot: [10-chats-list.png](screenshots/10-chats-list.png), [40-groups-list.png](screenshots/40-groups-list.png), [50-notifications-list.png](screenshots/50-notifications-list.png), [60-calls-list.png](screenshots/60-calls-list.png), [80-settings-main.png](screenshots/80-settings-main.png)

Likely code: `xabber/controllers/chats/last_chats_list/*`, `xabber/controllers/chats/contact_list/*`, `xabber/controllers/calls/last_calls/*`, `xabber/controllers/notifications/*`, `xabber/controllers/settings/*`.

### M-06 - Medium - Create Entity flow looks detached from the rest of the app

Screens/components: Create Entity.

Description: The flow uses a large "Reporting for duty!" heading, rounded grouped cards, oversized blue icons, and no visible back/dismiss affordance in the captured state. It does not match Settings, Contacts, or regular list screens.

Why this is a problem: This is a high-frequency creation flow, but it feels like a separate app surface and has unclear navigation containment.

Expected standard: Use the same navigation and list row tokens as other creation/settings flows, with a visible close/back control.

Screenshot: [12-create-entity-menu.png](screenshots/12-create-entity-menu.png)

Likely code: `xabber/controllers/chats/create_new_entity/CreateNewEntityViewController.swift`.

### M-07 - Medium - Dynamic Type exposes bottom-bar and toast overlap in Chats

Screens/components: Chats at accessibility text size.

Description: At maximum Dynamic Type, chat rows remain mostly readable, but the bottom floating bar and a "Cloud storage is inactive" toast obscure lower list content.

Why this is a problem: Assistive text sizes require more vertical space; overlays need stronger safe-area/content-inset rules.

Expected standard: Toasts and floating controls should stack or move so primary content remains readable.

Screenshot: [91-dynamic-type-chats.png](screenshots/91-dynamic-type-chats.png)

Likely code: `xabber/controllers/bars/bottom_bar/FloatingBottomBarView.swift`, `xabber/controllers/alerts/ToastPresenter.swift`, `xabber/controllers/chats/last_chats_list/LastChatsViewController.swift`.

### L-01 - Low - Avatar and badge styles are inconsistent

Screens/components: Chats, Contacts, Groups, Settings, Dynamic Type Chats.

Description: Avatar shapes vary between circles, rounded squares, large account avatars, cyan initials, photo crops, and multiple badge overlays. Group/public/incognito badges also differ in placement and scale.

Why this is a problem: The app loses a consistent identity hierarchy for person, group, bot, account, and status.

Expected standard: Define avatar sizes/shapes and badge positions per context.

Screenshot: [10-chats-list.png](screenshots/10-chats-list.png), [30-contacts-list.png](screenshots/30-contacts-list.png), [32-contact-profile.png](screenshots/32-contact-profile.png), [80-settings-main.png](screenshots/80-settings-main.png)

Likely code: `xabber/controllers/chats/*`, `xabber/controllers/settings/SettingsViewController+AccountCell.swift`, `xabber/controllers/chats/info_screens/*`.

### L-02 - Low - Copy and localization tone are mixed

Screens/components: Create Entity, Notifications, Chat, Devices.

Description: Copy ranges from playful ("Reporting for duty!") to security-critical prose, with mixed English/Russian content from data and strings such as "his/her" and the typo `attachements`.

Why this is a problem: Tone shifts reduce trust in security and account flows, and typos lower perceived quality.

Expected standard: Use localized, precise, user-centered labels, especially for navigation, destructive actions, and security states.

Screenshot: [12-create-entity-menu.png](screenshots/12-create-entity-menu.png), [23-chat-security-verify.png](screenshots/23-chat-security-verify.png), [50-notifications-list.png](screenshots/50-notifications-list.png)

Likely code: `xabber/controllers/chats/create_new_entity/CreateNewEntityViewController.swift`, `xabber/controllers/chats/chat/*`, `xabber/controllers/notifications/*`, localization strings.

### L-03 - Low - Secondary metadata alignment varies

Screens/components: Chats, Calls, Archive, Notifications.

Description: Dates, unread counters, delivery marks, pin/status badges, and secondary metadata are aligned differently across list rows and sometimes compete for right-edge space.

Why this is a problem: Dense messenger lists depend on predictable scanning of sender, preview, time, and unread state.

Expected standard: Use shared right-accessory rules for time, status, pin, unread count, and selection states.

Screenshot: [10-chats-list.png](screenshots/10-chats-list.png), [14-chats-unread-filter.png](screenshots/14-chats-unread-filter.png), [50-notifications-list.png](screenshots/50-notifications-list.png), [70-archive-list.png](screenshots/70-archive-list.png)

Likely code: `xabber/controllers/chats/last_chats_list/*`, `xabber/controllers/calls/last_calls/*`, `xabber/controllers/notifications/*`.

## Inconsistencies Matrix

| Pattern | Observed variants | Risk | Evidence |
|---|---|---|---|
| Buttons | Circular glass nav buttons, 36 pt icon buttons, 52 pt settings rows, 34 pt Verify button, red static destructive row | Mixed tap targets and semantics | [10](screenshots/10-chats-list.png), [80](screenshots/80-settings-main.png), [83](screenshots/83-settings-devices.png) |
| Icons | SF Symbol labels, custom blue outline icons, security badge icons, raw symbol VoiceOver labels | Inconsistent meaning and accessibility labels | [12](screenshots/12-create-entity-menu.png), [23](screenshots/23-chat-security-verify.png), [83](screenshots/83-settings-devices.png) |
| Avatars | Person photos, cyan initials, circular/squircle shapes, large account avatar, bot icons, group badges | Weak entity taxonomy | [10](screenshots/10-chats-list.png), [30](screenshots/30-contacts-list.png), [32](screenshots/32-contact-profile.png), [80](screenshots/80-settings-main.png) |
| List rows | Chats large rows, Calls dense rows, Settings 52 pt rows, Groups variable tall descriptions, Notifications long variable rows | Scanning inconsistency | [40](screenshots/40-groups-list.png), [50](screenshots/50-notifications-list.png), [60](screenshots/60-calls-list.png), [80](screenshots/80-settings-main.png) |
| Navigation bars | Sidebar button, Back button, hidden/no visible back, large circular glass buttons, overlay profile actions | Navigation uncertainty | [12](screenshots/12-create-entity-menu.png), [22](screenshots/22-chat-info-bot.png), [51](screenshots/51-notification-security-detail.png), [82](screenshots/82-settings-interface.png) |
| Forms | Create group form overlays list, Settings details push normally, Devices uses dense cards/actions | Inconsistent containment and focus | [41](screenshots/41-groups-create-form.png), [82](screenshots/82-settings-interface.png), [83](screenshots/83-settings-devices.png) |
| Empty states | Reusable `EmptyStateView`, LastChats custom empty, blank Contacts search, Saved messages blank chat, static split placeholder | Users get different no-data guidance | [31](screenshots/31-contacts-search.png), [71](screenshots/71-saved-messages-empty-chat.png) |
| Chat bubbles | Interface preview uses chat bubble tokens, actual empty bot chat has no bubble content, security panel uses long card copy | Settings preview and runtime chat states diverge | [20](screenshots/20-chat-thread-bot-empty.png), [23](screenshots/23-chat-security-verify.png), [82](screenshots/82-settings-interface.png) |
| Settings cells | Account header, setting rows, value cells, devices cards, destructive static text | Mixed role/semantic model | [80](screenshots/80-settings-main.png), [81](screenshots/81-settings-lower.png), [83](screenshots/83-settings-devices.png), [90](screenshots/90-dynamic-type-devices.png) |
| Bottom bars | Chats Search/Unread/Mark all, Calls Search/Missed, Notifications Search/Unread/Read all, Archive Search only | Similar surfaces expose different control weight/spacing | [10](screenshots/10-chats-list.png), [50](screenshots/50-notifications-list.png), [60](screenshots/60-calls-list.png), [70](screenshots/70-archive-list.png) |

## Screenshots

![Chats list](screenshots/10-chats-list.png)

![Left menu](screenshots/11-left-menu.png)

![Create entity](screenshots/12-create-entity-menu.png)

![Chats search active](screenshots/13-chats-search-active.png)

![Chats unread filter](screenshots/14-chats-unread-filter.png)

![Chat thread, empty bot](screenshots/20-chat-thread-bot-empty.png)

![Chat attachment gallery](screenshots/21-chat-attachment-gallery.png)

![Chat info bot](screenshots/22-chat-info-bot.png)

![Chat security verify](screenshots/23-chat-security-verify.png)

![Contacts list](screenshots/30-contacts-list.png)

![Contacts search empty](screenshots/31-contacts-search.png)

![Contact profile](screenshots/32-contact-profile.png)

![Groups list](screenshots/40-groups-list.png)

![Groups create form](screenshots/41-groups-create-form.png)

![Notifications list](screenshots/50-notifications-list.png)

![Notification security detail](screenshots/51-notification-security-detail.png)

![Calls list](screenshots/60-calls-list.png)

![Calls missed filter](screenshots/61-calls-missed-filter.png)

![Archive list](screenshots/70-archive-list.png)

![Saved messages empty chat](screenshots/71-saved-messages-empty-chat.png)

![Settings main](screenshots/80-settings-main.png)

![Settings lower](screenshots/81-settings-lower.png)

![Settings interface](screenshots/82-settings-interface.png)

![Settings devices](screenshots/83-settings-devices.png)

![Dynamic Type devices](screenshots/90-dynamic-type-devices.png)

![Dynamic Type chats](screenshots/91-dynamic-type-chats.png)

## Recommended Fix Order

1. Fix presentation containment and accessibility focus for modal/pushed screens: hidden underlying content, reliable Back/Dismiss, and one active screen at a time.
2. Raise all effective tap targets to at least 44x44 pt, starting with close buttons, Settings icon buttons, and Devices Verify/destructive controls.
3. Rework Devices Dynamic Type and destructive action semantics before broader polish; this is a security-critical surface.
4. Standardize bottom-bar safe-area insets and toast stacking so list content is never obscured.
5. Consolidate empty/search-empty states on `EmptyStateView` or a successor component.
6. Define shared row/avatar/icon/navigation tokens for Chats, Contacts, Groups, Calls, Notifications, Archive, and Settings.
7. Clean accessibility labels and copy: replace raw symbol labels, fix `attachements`, and normalize tone in create/security flows.

## Unverified / Blocked

| Area | Reason |
|---|---|
| Onboarding, sign-in, sign-up | Simulator already had a logged-in account; no test credentials/password were found in README, knowledge base, or vault. Safe audit avoided logout, keychain reset, or account deletion. |
| Login server feature/error states | Requires controlled server responses and credentials. |
| True empty Chats/Contacts/Groups/Calls/Notifications | Current account had data. Empty states were partly audited statically and via search/saved-message runtime states. |
| Loading states | Not reproducibly reachable without network manipulation or data reset. |
| Chat message context menus and swipe destructive actions | Avoided to prevent changes to real message/contact data. |
| Full attachment picker tabs | Gallery captured; File/Location/Contacts tabs not opened to avoid permissions/data side effects. |
| Group info, members, moderation/settings | Group list and create form captured; deeper group management requires safe test group state. |
| Account profile edit, cloud storage, premium, passcode, Yubikey, EULA, Safety and Reporting, Privacy | Inventory confirmed statically from Settings datasource; runtime coverage limited to Interface and Devices. |
| Dark mode and increased contrast | This pass used light mode and default contrast. |
| Broad Dynamic Type matrix | Representative pass only for Chats and Devices at `accessibility-extra-extra-extra-large`. |

Known audit side effect: opening one notification detail changed the Left Menu unread notification count from 2072 to 2071, likely marking one notification as read. No production code, dependencies, signing, settings, or project files were modified.

## Verification

Build/run:

```text
XcodeBuildMCP session defaults:
workspace = /Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core/xabber.xcworkspace
scheme = Debug (xabber Workspace)
configuration = Debug
simulator = iPhone 16e / iOS 26.0 / 7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF
bundleId = xabber.ios
derivedDataPath = /Users/igor.boldin/Library/Caches/XabberCodex/xabber-ios-core/DerivedData
```

```text
XcodeBuildMCP build_run_sim extra args:
-clonedSourcePackagesDirPath /Users/igor.boldin/Library/Caches/XabberCodex/xabber-ios-core/SourcePackages
-packageCachePath /Users/igor.boldin/Library/Caches/XabberCodex/xabber-ios-core/PackageCache
-skipPackageUpdates
-onlyUsePackageVersionsFromResolvedFile
```

Result: `SUCCEEDED`. The app built and launched on the configured simulator. No XCTest was run because this was documentation-only runtime audit work.

Simulator normalization and screenshots:

```sh
xcrun simctl status_bar 7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
xcrun simctl ui 7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF appearance light
xcrun simctl ui 7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF content_size large
xcrun simctl ui 7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF increase_contrast disabled
xcrun simctl io 7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF screenshot docs/ui-audit/screenshots/<name>.png
xcrun simctl ui 7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF content_size accessibility-extra-extra-extra-large
xcrun simctl ui 7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF content_size large
```

Screenshot validation:

```sh
find docs/ui-audit/screenshots -maxdepth 1 -type f -name '*.png' -print | sort
for f in docs/ui-audit/screenshots/*.png; do
  size=$(stat -f%z "$f")
  dims=$(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | awk '/pixelWidth|pixelHeight/{print $2}' | paste -sdx -)
  printf '%s %s bytes %s\n' "$f" "$size" "$dims"
done
```

Result: 26 screenshots exist, all non-empty, all `1170x2532` PNGs.

Static inventory checks used `rg` over:

```text
xabber/application/AppRootCoordinator.swift
xabber/controllers/split/LeftMenuViewController.swift
xabber/controllers/settings
xabber/controllers/base/views/EmptyStateView.swift
xabber/controllers/chats/last_chats_list
xabber/controllers/chats/contact_list
xabber/controllers/chats/create_new_entity
xabber/controllers/calls/last_calls
xabber/controllers/notifications
```

Cleanup:

```sh
xcrun simctl ui 7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF content_size large
xcrun simctl ui 7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF increase_contrast disabled
xcrun simctl ui 7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF appearance light
```

Status bar override was cleared after the audit.
