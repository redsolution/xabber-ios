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

Verification (2026-10-15):

- Cached Debug build for generic iOS Simulator succeeded (arm64 and x86_64).
- Isolated hosted XCTest run on iPhone 17 Pro / iOS 26 succeeded: all 6 LeftMenuSurfaceEffectFactoryTests passed, including geometry cases for phone and tablet columns and short windows.
- `git diff --check` passed.
- No signed-in visual review or physical-device check was performed. Tablet geometry is covered by unit tests; the test host ran on a phone simulator.
