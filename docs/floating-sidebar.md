# Floating main menu

The main menu follows the Floating sidebar concept approved on 2026-10-15.

- Keep the existing datasource, custom icons, labels, ordering, badge counts, feature gates, and navigation actions.
- Place the menu in one native regular Liquid Glass surface on iOS 26; retain the existing thin-material fallback on older systems.
- Show the configured chat wallpaper through the surface. Use the continuous root wallpaper in regular iPad split mode and a local instance of the same wallpaper renderer in compact mode.
- Use current column bounds and safe-area insets, with a 350-point maximum width and 16-point outer margins. Fit height to menu content; enable scrolling in short windows and at large Dynamic Type sizes.
- Move the existing Premium star into the panel header and highlight the current destination with translucent green.
- Preserve split-column selection and modal recovery behavior. Restore the previous navigation-bar visibility when leaving the menu.

Ownership: UI; affected coverage: LeftMenuSurfaceEffectFactoryTests (phone/tablet geometry, short-window bounds, native glass and fallback).

The AGENTS.md knowledge-base and Obsidian locations under /Users/igor.boldin/projects/xabber are absent on this machine; this note records the local task context instead.

Original implementation verification (2026-10-15):

- Cached Debug build for generic iOS Simulator succeeded (arm64 and x86_64).
- Isolated hosted XCTest run on iPhone 17 Pro / iOS 26 succeeded: all 6 LeftMenuSurfaceEffectFactoryTests passed, including geometry cases for phone and tablet columns and short windows.
- `git diff --check` passed.
- No signed-in visual review or physical-device check was performed. Tablet geometry is covered by unit tests; the test host ran on a phone simulator.


## Port to Igor's latest version

Based on origin/codex/omemo-xabbercryptoswift at d33c588a, fetched 2026-10-15. This version includes ce05bf57 (inset grouped recent chats at every width) and 012b1582 (wallpaper behind recent chats). Ported the existing menu commit while retaining the new chat navigation route resolver and current localization behavior. No chat-list implementation was replaced.

The prior branch and its commits remain intact. The two pre-existing local edits (Podfile path and Realm migration property guard) were saved in a named Git stash. The migration safeguard was reapplied locally to retain compatibility with this simulator's existing database. The newer Podfile uses XABBER_DEPS_ROOT, pointed at a local dependency-directory symlink. Updated installed Pods according to upstream's declared dependency graph and synchronized the workspace package lock from the committed project lock. The ignored local Info.plist explicitly selects the actual signed Keychain entitlement through upstream's newer access-group resolver, preserving simulator login without reapplying the old credential implementation.

Owner: UI; secondary verification: simulator integration. Local knowledge-base README reviewed at /Users/andrew.nenakhov/Projects/xabber-knowledge. Original Igor vault paths remain unavailable.

Port verification completed (2026-10-15):

- All 18 selected tests passed: LeftMenuSurfaceEffectFactoryTests, LeftMenuSelectionPresentationPolicyTests, and LastChatsBackgroundAppearanceTests.
- Signed Debug build succeeded for iPhone 17 Pro / iOS 26.
- Installed and launched the updated app with Igor's existing signed-in account intact; no new login was needed.
- Visually verified the new inset-grouped chats over green wallpaper and the floating menu over the same green wallpaper. Existing icons, labels, order, badges, and upstream availability rules were retained. The menu remains open in the simulator.
- Phone/tablet layout and split-selection policies are covered by the selected tests. No separate physical-device or live iPad run was performed.
- `git diff --check` passed. No chat-list source changes exist relative to the fetched upstream version.

## Single surface in expanded tablet sidebars

Expanded split sidebars use UIKit's existing full-height column material. The menu content fills that column and adds no second glass effect, tint, inset card, or rounded rectangle. Safe-area padding still protects the title and rows. Compact/collapsed layouts retain the content-sized floating glass card. The decision follows split/window presentation state rather than device idiom, so narrow iPad windows follow the compact policy.

UI owns this refinement. Added regression checks for full-column geometry and absence of a second material, preserving existing compact geometry and selection-policy checks. Configured Igor vault paths remain unavailable; this repository note records the decision alongside the existing implementation notes.

Verification: 15 focused sidebar tests passed and the signed simulator build succeeded. Visually checked expanded iPad Pro 11-inch: a single full-height glass surface, no inset inner card. iPhone 17 Pro retains its content-sized floating card. Both simulators left on the updated menus.

## Compact menu over current content

Compact sidebar buttons now capture the visible split content immediately before UIKit shows the primary column. A transient view capture under a full-screen thick-material blur preserves the visible screen and scroll position behind the floating menu. The capture is noninteractive, hidden from accessibility, replaced on each opening, released on menu disappearance, and never written to disk. Menu selection and tap-outside still use existing split navigation. Expanded tablet sidebars continue using UIKit's single column surface. A fresh launch without a captured screen retains the wallpaper fallback.

All explicit sidebar entry points use `showXabberSidebar()` so Chats, Contacts, Notifications, Calls, and their category/detail screens share the same behavior. Added capture replacement/release and heavy-blur regression checks alongside existing geometry and navigation policy tests. UI owns this work; configured external vault paths remain unavailable, so durable notes are kept here.

Verification: 17 focused sidebar tests passed and the normal signed simulator build succeeded. Visually checked the iPhone menu over the captured chat list, selected Chats to restore the original list, and reopened the menu successfully. Left the updated phone menu open for review. Expanded-column geometry/effect and compact selection policy regressions passed.

## Preserve the green floating-sidebar composition

The full-screen thick-material blur made captured chat content appear gray/white, contrary to the original floating-sidebar reference. Replaced that material with a clamped Gaussian image blur (14 points) that preserves source colors. The transient blurred screen blends at 50% over the active wallpaper, leaving softened chat-card shapes visible while retaining the green field. Compact cards use 84% of screen width (350-point maximum) and 62-point rows; expanded sidebars retain 54-point rows and full-column geometry.

Added a pixel regression proving a saturated green input stays green and opaque after blur, and a compact geometry assertion ensuring exposed content remains visible at the right edge. Previous capture lifetime and expanded-column checks remain. UI owns this correction; unavailable external vault paths are documented above.

Verification: all 18 sidebar tests passed, including the color-preservation pixel check. Signed simulator build succeeded. Visually checked iPhone: green wallpaper remains visible around the narrower glass card, with softened current-screen content behind it and no full-screen gray material. Left the revised menu open for comparison with the supplied reference.
