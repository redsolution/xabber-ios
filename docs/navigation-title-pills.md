# Navigation title pills

Chat and Recent Chats titles use local glass capsules so their text has its own surface against the continuous split-view wallpaper. `NavigationTitlePillSurface` reuses `XabberGlassStyle`: Chat uses the composer's `clearInputSurface` role; Recent Chats uses the bottom action bar's `bar` role. Chat retains its existing title button, status stack, information action, selection/search transitions, and width cap; text gains 16-point horizontal padding. Recent Chats keeps its native title metadata while presenting an updating, accessible title capsule.

UI owns this task. Added regressions for a single chat title surface after repeated configuration, preserved info action, and stable updating Recent Chats pill. Existing navigation-state coverage is included in verification. Configured Igor knowledge/vault paths remain unavailable locally; this repository note records the durable behavior alongside previous UI task notes.

The iOS 26 top scroll-edge effect is hidden for the message collection and Recent Chats table, removing the broad adaptive gradient where the two columns meet. Title capsule appearance follows the content window's light/dark style so navigation-bar edge adaptation does not force white text onto light glass. Existing navigation-bar button behavior and bottom controls are preserved.

Validation: all 44 selected chat navigation, immediate-control, and Recent Chats appearance tests pass, including title surface idempotence, info action retention, title updates, and hidden top-edge effects.

Signed simulator build succeeded. Installed on iPad and iPhone. Visually verified iPad landscape with Recent Chats and an open conversation: both glass capsules render, chat title contrast is readable, and the wide dark top-edge band is absent. Network loading of the conversation did not affect title presentation.
