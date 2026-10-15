# Split navigation shadow blending

The continuous wallpaper spans tablet columns, but UIKit's enclosing navigation/split wrappers can clip the glass navigation controls' shadows at column edges. In shared-backdrop mode, the background root now clears clipping on the attached navigation-bar ancestor path up to the split root. This uses public UIView clipping properties and does not inspect private class names or modify unrelated descendants. Scroll views and transition/content containers on sibling paths retain their clipping; compact phone layouts keep existing behavior.

UI owns this task. Added regression coverage for unclipped chrome ancestors, preserved list clipping, and unrelated view-tree isolation. Existing chat navigation and shared wallpaper regressions are included in verification. External Igor knowledge/vault paths remain unavailable; this repository note records the implementation and result.

Original clipping flags are stored with weak UIView keys and restored when leaving shared-backdrop mode. Repeated layout passes retain the first value, preventing expanded/compact resize cycles from leaking the overflow policy into compact navigation.

The visual check also exposed UIKit's separate boundary hairline. Shared-backdrop mode suppresses only noninteractive divider views at column boundaries that are at most one point wide and span at least 90% of the split height. Traversal stops at app-owned column content roots, preserving message/list separators and scroll indicators. Original visibility is weakly recorded and restored with clipping on return to compact mode. No private class names or private APIs are used.

Verification: all 45 selected tests pass and the signed simulator build succeeded. Compared the same landscape boundary before/after divider suppression; the bright hairline disappears. Visually checked portrait and landscape with the sidebar open and closed. Shared wallpaper remains continuous, while table/message content stays inside its columns. Both simulator installations updated; iPad left in landscape with the sidebar open.
