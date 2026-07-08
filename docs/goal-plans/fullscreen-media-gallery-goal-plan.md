# Fullscreen Media Gallery Goal Plan

project:: xabber-ios
owner:: xabber-ui
secondary:: xabber-business, xabber-xmpp, xabber-tests
status:: open
created:: 2026-07-08

## Goal Mode Prompt

Use this whole file as the execution prompt for an automatic Codex goal.

Objective:

Implement and verify the fullscreen media sections opened from Contact Info and Group Info:

- Images: fixed three-column fullscreen grid, cell size derived from the actual controller width, fast display-size-aware prefetch.
- Videos: fixed three-column fullscreen grid, valid preview rendering, visible duration on every video item.
- Files: non-empty fullscreen list, layout matching the attachment picker's file list style, and a user action to jump to the containing chat message.
- Voice: fullscreen list with waveform, inline playback, auto-advance to the next voice message after playback finishes, and a user action to jump to the containing chat message.

Scope:

- Work on the separate fullscreen sections only.
- The compact media preview/footer inside the contact/group info card is not the target of this goal. Touch `InfoScreenFooterView` only if a shared model/helper is required for fullscreen entry wiring or compilation, and keep such changes minimal.
- Do not rewrite the chat bubble media renderer. Reuse existing chat playback/prefetch/navigation contracts where possible.
- Do not add third-party dependencies.

Repository:

`/Users/igor.boldin/projects/xabber/fabric/xabber/xabber_ios_whitelabel/xabber/xabber_ios_core`

Knowledge and vault context already relevant to this goal:

- `/Users/igor.boldin/projects/xabber/xabber-knowledge/protocols/XEP-FILES.md`
- `/Users/igor.boldin/projects/xabber/xabber-knowledge/protocols/XEP-VOICE.md`
- `/Users/igor.boldin/projects/xabber/xabber-knowledge/behavioral-specs/chat/message-references.md`
- `/Users/igor.boldin/projects/xabber/xabber-knowledge/architecture/services/media-gallery-api.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/shared/interfaces.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/shared/dependencies.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/ui/context.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/tests/context.md`

Current implementation findings:

- Fullscreen base: `xabber/controllers/chats/info_screens/views/gallery/BaseMediaGalleryForChatViewController.swift`
- Fullscreen images: `xabber/controllers/chats/info_screens/views/gallery/PhotoGalleryForChatViewController.swift`
- Fullscreen videos: `xabber/controllers/chats/info_screens/views/gallery/VideoGalleryForChatViewController.swift`
- Fullscreen files: `xabber/controllers/chats/info_screens/views/gallery/FilesGalleryForChatViewController.swift`
- Fullscreen voice: `xabber/controllers/chats/info_screens/views/gallery/VoiceGalleryForChatViewController.swift`
- Legacy mixed fullscreen controller: `xabber/controllers/chats/info_screens/views/ChatFilesViewController.swift`
- Media storage: `xabber/xmpp/messages/message/MessageMediaAttachmentStorageItem.swift`
- Voice playback coordinator: `xabber/common/audio_manager/VoiceMessagePlaybackCoordinator.swift`
- Existing waveform/audio view code: `xabber/controllers/chats/chat/messages_kit/Views/Cells/inline_views/InlineAudioGridView.swift`
- Attachment picker file list style reference: `xabber/controllers/chats/attachment_picker/ChatAttachmentFileSource.swift`

Observed problems to fix:

- `PhotoGalleryForChatViewController` and `VideoGalleryForChatViewController` use fixed 128 pt item sizes instead of deriving three columns from available width.
- `PhotoGalleryForChatViewController` prefetch downloads original URLs directly without a reusable, bounds-safe, cancelable, display-size-aware prefetch contract.
- `VideoGalleryForChatViewController` currently tries to load `item.url` through Kingfisher as if it were an image; that can mean the video file URL itself, not a preview image. Duration is not part of the base datasource.
- `FilesGalleryForChatViewController.loadDatasource()` sets `datasource = []`, so files never display.
- `VoiceGalleryForChatViewController.loadDatasource()` sets `datasource = []`, uses an image-style cell, and does not connect to the existing voice playback coordinator or waveform renderer.
- Existing chat open-message infrastructure exists, but the current policy suppresses most anchor sources. A deliberate media-gallery jump source or direct honored source is needed for "go to message".

Execution rules for every numbered task:

1. Start by reading any files named in that task that have changed since this plan was written.
2. Run the task's pre-task tests before editing production code.
3. Add or update focused XCTest coverage first.
4. When practical, run the new or changed focused test before production edits and confirm it fails for the intended reason.
5. Implement the smallest production change for the task.
6. Run the task's required tests and adjacent tests named in the task.
7. Run `git diff --check`.
8. Run one Debug app build before closing the task. Prefer a connected iPhone destination if available; otherwise use a simulator.
9. Update vault notes:
   - `projects/xabber/agents/ui/notes.md`
   - `projects/xabber/agents/tests/notes.md`
   - update `shared/interfaces.md` only when a cross-layer navigation/playback contract changes.
10. Stage only files changed for the current task.
11. Commit before starting the next task.
12. Do not run `clean`; use `tools/xcodebuild_cached.sh clean-cache` only if explicitly diagnosing cache corruption.

Recommended local verification setup:

```bash
export XABBER_SCHEME='Debug (xabber Workspace)'
export XABBER_DESTINATION='platform=iOS Simulator,name=iPhone 16e,OS=26.0'
```

If the scheme or destination is unavailable, run:

```bash
xcodebuild -list -workspace xabber.xcworkspace
xcrun simctl list devices available
```

Then set `XABBER_SCHEME` and `XABBER_DESTINATION` to concrete available values and continue.

## Task 1 - Fullscreen Gallery Foundation

Goal:

Create a testable shared foundation for fullscreen media galleries without changing final visible behavior yet.

Files to inspect/change:

- `xabber/controllers/chats/info_screens/views/gallery/BaseMediaGalleryForChatViewController.swift`
- `xabber/controllers/chats/info_screens/views/gallery/PhotoGalleryForChatViewController.swift`
- `xabber/controllers/chats/info_screens/views/gallery/VideoGalleryForChatViewController.swift`
- `xabber/controllers/chats/info_screens/views/gallery/FilesGalleryForChatViewController.swift`
- `xabber/controllers/chats/info_screens/views/gallery/VoiceGalleryForChatViewController.swift`
- `xabber/xmpp/messages/message/MessageMediaAttachmentStorageItem.swift`
- New or existing focused tests under `xabberTests/`

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/ChatCollectionPrefetchTests \
  -only-testing:xabberTests/ChatAttachmentFileSourceTests \
  -only-testing:xabberTests/VoiceMessagePlaybackCoordinatorTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required test changes:

- Add `MediaGalleryFullscreenLayoutPolicyTests`.
- Add `MediaGalleryFullscreenDataSourceTests`.
- Cover a pure layout policy for square grid cells:
  - three columns exactly;
  - cell width derived from collection/controller width, section insets, and interitem spacing;
  - stable output for 320, 375, 390, 430, and iPad widths;
  - no mutation of `collectionView.collectionViewLayout` inside `sizeForItemAt`.
- Cover a datasource mapper that can expose, at minimum:
  - `primary`
  - `kind`
  - `url`
  - `messagePrimary`
  - `archiveId` or equivalent anchor id
  - `filename`
  - `byteSize` and formatted size
  - `durationSeconds` and formatted duration
  - `previewURL` or preview cache identity for videos when available
  - `verySmallThumb` / decoded thumb for image placeholders
  - `isSensitive` / session reveal state
  - voice `decodedURL`, `isDownloaded`, `pcm` / waveform levels when available
- Cover that `.file` and `.voice` kinds use the base Realm query path and are not emptied by subclass `loadDatasource()` overrides.

Implementation requirements:

- Move width calculation into a pure policy type, for example `MediaGalleryGridLayoutPolicy`.
- Move Realm item to fullscreen datasource mapping into a pure helper where possible, for example `MediaGalleryDatasourceMapper`.
- Keep Realm observation in the base controller; keep mapping and layout policy testable without opening a real UI.
- Extend `BaseMediaGalleryForChatViewController.Datasource` instead of adding separate incompatible datasource structs for each fullscreen section.
- Preserve sorting by newest first unless product requirements or existing code clearly say otherwise.
- Keep sensitive media reveal state session-local through `revealedSensitiveMediaPrimaries`.
- Add defensive index handling in collection data source/prefetch methods so stale index paths cannot crash during diff/reload.

Acceptance criteria:

- Shared fullscreen datasource can represent images, videos, files, and voices.
- `FilesGalleryForChatViewController` and `VoiceGalleryForChatViewController` no longer override `loadDatasource()` to empty the list.
- Layout calculation is deterministic and test-covered.
- No compact footer behavior is intentionally changed.
- Existing image/video fullscreen sections still compile and render with their old cells until their dedicated tasks change them.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/MediaGalleryFullscreenLayoutPolicyTests \
  -only-testing:xabberTests/MediaGalleryFullscreenDataSourceTests \
  -only-testing:xabberTests/ChatCollectionPrefetchTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "refactor(media-gallery): add fullscreen gallery foundation"
```

## Task 2 - Fullscreen Images Grid And Prefetch

Goal:

Fix the fullscreen image section so it always displays a three-column grid and preloads image thumbnails quickly without overfetching original-size images.

Files to inspect/change:

- `xabber/controllers/chats/info_screens/views/gallery/PhotoGalleryForChatViewController.swift`
- `xabber/controllers/chats/info_screens/views/gallery/BaseMediaGalleryForChatViewController.swift`
- Shared helper files created in Task 1
- `xabberTests/MediaGalleryFullscreenLayoutPolicyTests.swift`
- New or existing image prefetch tests under `xabberTests/`

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/MediaGalleryFullscreenLayoutPolicyTests \
  -only-testing:xabberTests/MediaGalleryFullscreenDataSourceTests \
  -only-testing:xabberTests/ChatCollectionPrefetchTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required test changes:

- Add `MediaGalleryImagePrefetchTests`.
- Cover that image prefetch:
  - ignores index paths outside current datasource bounds;
  - prefers thumbnail/preview URL when present and falls back to full URL only when no thumbnail exists;
  - uses a request identity including URL, target display size, and screen scale;
  - uses Kingfisher downsampling/background decode options or an equivalent display-size-aware request;
  - deduplicates already active prefetch work;
  - cancels work in `cancelPrefetchingForItemsAt` and on controller deinit/disappear if a cancel hook exists.
- Add or update cell reuse tests so late image callbacks cannot update a reused image cell for a different datasource item.

Implementation requirements:

- Replace fixed `PhotoGalleryForChatViewController.FlowLayout.itemSize = 128` with the Task 1 layout policy.
- Ensure `minimumInteritemSpacing`, `minimumLineSpacing`, and `sectionInset` are owned by the layout once, not mutated in `sizeForItemAt`.
- Use `collectionView(_:layout:sizeForItemAt:)` or layout invalidation in a stable way so rotation/split width changes recalculate item size.
- Add `collectionView(_:cancelPrefetchingForItemsAt:)`.
- Prefer a lightweight reusable prefetch helper over inline calls to `ImageDownloader.default.downloadImage`.
- Keep the existing sensitive media overlay and first-step reveal flow.
- Keep tapping an image opening the existing `PhotoGallery`.

Acceptance criteria:

- Fullscreen images always render exactly three columns at every supported width.
- Cell size is derived from collection/controller width and section insets.
- Rotation or split width changes invalidate the layout and keep three columns.
- Prefetch warms the same image variant the grid needs, not arbitrary original dimensions.
- Prefetch is bounds-safe and cancelable.
- Sensitive image reveal still works.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/MediaGalleryFullscreenLayoutPolicyTests \
  -only-testing:xabberTests/MediaGalleryImagePrefetchTests \
  -only-testing:xabberTests/MediaGalleryFullscreenDataSourceTests \
  -only-testing:xabberTests/ChatCollectionPrefetchTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "fix(media-gallery): stabilize fullscreen image grid"
```

## Task 3 - Fullscreen Videos Preview And Duration

Goal:

Fix fullscreen video section layout, preview rendering, and visible video duration.

Files to inspect/change:

- `xabber/controllers/chats/info_screens/views/gallery/VideoGalleryForChatViewController.swift`
- `xabber/controllers/chats/info_screens/views/gallery/BaseMediaGalleryForChatViewController.swift`
- `xabber/xmpp/messages/message/MessageMediaAttachmentStorageItem.swift`
- Shared helpers from Tasks 1-2
- `xabber/controllers/chats/attachment_picker/ChatAttachmentGalleryGrid.swift` for duration formatting precedent
- `xabberTests/ChatAttachmentGalleryGridTests.swift` for existing duration expectations

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/MediaGalleryFullscreenLayoutPolicyTests \
  -only-testing:xabberTests/MediaGalleryImagePrefetchTests \
  -only-testing:xabberTests/ChatAttachmentGalleryGridTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required test changes:

- Add `MediaGalleryVideoCellStateTests`.
- Add `MediaGalleryVideoPrefetchTests` or extend `MediaGalleryImagePrefetchTests` with video preview resources.
- Cover video datasource mapping:
  - `duration` from metadata/storage maps to `m:ss` or `h:mm:ss`;
  - missing duration hides or leaves the duration label empty without layout breakage;
  - `previewURL`, `videoPreviewKey`, local thumbnail, or very-small thumbnail is selected before the video file URL for grid preview;
  - if no preview exists, the cell renders a deterministic video placeholder and play icon.
- Cover that prefetch requests preview resources only and never tries to download the raw video file as an image.
- Cover that sensitive video reveal still routes to the first-step confirmation and then plays the video.

Implementation requirements:

- Replace fixed 128 pt video item size with the same three-column layout policy as images.
- Split video playback URL from video preview image source in the datasource/cell API.
- Do not call Kingfisher on the raw video URL unless that URL is known to be a preview image.
- Display a play affordance and duration label over every video grid cell.
- Use duration formatting consistent with attachment picker video durations.
- Keep `AVPlayerViewController` playback on tap.
- Keep sensitive media overlay and report context menu behavior.

Acceptance criteria:

- Fullscreen videos always render exactly three columns at every supported width.
- Every video cell displays a valid preview image or a deterministic placeholder, plus a play icon.
- Every video with known duration shows a formatted duration badge.
- Prefetch warms preview images, not video files.
- Tapping a video still opens playback.
- Sensitive video reveal still works.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/MediaGalleryFullscreenLayoutPolicyTests \
  -only-testing:xabberTests/MediaGalleryVideoCellStateTests \
  -only-testing:xabberTests/MediaGalleryVideoPrefetchTests \
  -only-testing:xabberTests/ChatAttachmentGalleryGridTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "fix(media-gallery): render fullscreen video previews"
```

## Task 4 - Media Gallery Jump-To-Message Contract

Goal:

Add a reusable navigation contract for fullscreen media gallery rows that need to jump to the chat message containing the selected file or voice message.

Files to inspect/change:

- `xabber/controllers/chats/info_screens/views/gallery/BaseMediaGalleryForChatViewController.swift`
- `xabber/controllers/chats/chat/ChatViewController.swift`
- `xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift`
- `xabber/controllers/chats/last_chats_list/LastChatsViewController+UITableViewDelegate.swift`
- Any info-screen delegate or routing file that presents the fullscreen gallery from contact/group info
- `xabberTests/xabberTests.swift` if existing open-message policy tests still live there
- Prefer a dedicated new test file if practical

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/ChatOpenMessageRequestHandlingPolicyTests \
  -only-testing:xabberTests/ChatMessageAnchorPolicyTests \
  -only-testing:xabberTests/ChatOpenAtMessageEntrypointTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required test changes:

- Add `MediaGalleryMessageNavigationTests`.
- Cover a request builder from gallery datasource item to `ChatOpenMessageRequest`:
  - owner, JID, and conversation type are preserved;
  - `messagePrimary` is set when available;
  - `archivedId` is set from `archiveId` when available;
  - `sourceDate` is set from media/message date;
  - highlight is enabled;
  - mark-read-on-visible is false.
- Add or update `ChatOpenMessageRequestHandlingPolicyTests` so the new source is honored even while unrelated anchors remain suppressed.
- If using existing `.directOpenAtMessage` instead of a new source, explicitly test that only deliberate gallery/direct user actions become honored and that push/mention behavior does not change accidentally.
- Cover route behavior from an info/gallery controller:
  - same active chat can scroll/highlight locally;
  - inactive chat builds an open request for the navigation stack;
  - missing route fields disable the jump action instead of crashing.

Implementation requirements:

- Prefer adding a specific `ChatOpenMessageRequestSource.mediaGallery` if this avoids widening behavior of existing suppressed sources.
- Route through the existing chat open-message/jump pipeline, not a new parallel scroll implementation.
- Keep search and unread-boundary semantics unchanged.
- Use the existing anchor fetch/context path for messages not currently loaded.
- Keep the route independent of file open/playback behavior.
- Expose a simple gallery-level method, for example `openContainingMessage(for:)`, that Files and Voice can call.

Acceptance criteria:

- Files and Voice tasks can call one shared jump-to-message API.
- The jump request is honored by policy and reaches the existing chat anchor pipeline.
- The action highlights the target message when the chat opens or scrolls.
- The action does not mark the message read by itself.
- No existing search, push, mention, pinned, composer, or unread-boundary route changes unless tests prove the intended behavior.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/MediaGalleryMessageNavigationTests \
  -only-testing:xabberTests/ChatOpenMessageRequestHandlingPolicyTests \
  -only-testing:xabberTests/ChatMessageAnchorPolicyTests \
  -only-testing:xabberTests/ChatOpenAtMessageEntrypointTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "feat(media-gallery): add jump to containing message"
```

## Task 5 - Fullscreen Files List

Goal:

Make the fullscreen files section display real files, use attachment-picker-like row layout, and expose file opening plus jump-to-message actions.

Files to inspect/change:

- `xabber/controllers/chats/info_screens/views/gallery/FilesGalleryForChatViewController.swift`
- `xabber/controllers/chats/info_screens/views/gallery/BaseMediaGalleryForChatViewController.swift`
- `xabber/controllers/chats/attachment_picker/ChatAttachmentFileSource.swift` for visual style
- `xabber/controllers/chats/info_screens/footerInfoView/FilesMediaCollectionCell.swift` only if a reusable row component is extracted
- Tests created in Tasks 1 and 4

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/MediaGalleryFullscreenDataSourceTests \
  -only-testing:xabberTests/MediaGalleryMessageNavigationTests \
  -only-testing:xabberTests/ChatAttachmentFileSourceTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required test changes:

- Add `MediaGalleryFilesListTests`.
- Cover that `.file` media items from `MessageMediaAttachmentStorageItem` produce visible rows.
- Cover file filtering:
  - `kind == .file` appears in Files;
  - image/video/voice items do not appear in Files;
  - hidden-by-report items remain excluded by the base query.
- Cover row state:
  - filename is visible and middle-truncated when long;
  - size uses `AccountQuotaStorageItem.beautify(size:)` or the same formatter as the attachment picker;
  - icon is selected from MIME/kind consistently with the attachment picker file list;
  - row height is stable and self-contained;
  - repeated configure/reuse does not duplicate arranged subviews or constraints.
- Cover actions:
  - tapping/opening a file still offers existing file open/share behavior when URL is valid;
  - "Go to message" action calls the Task 4 route;
  - invalid URL disables file opening but not message jump when anchor data exists.

Implementation requirements:

- Remove the empty datasource override in `FilesGalleryForChatViewController`.
- Use a list-style collection or table layout with full-width rows, not square grid cells.
- Match the attachment picker's file visual language:
  - system/list content style or equivalent;
  - icon at leading edge;
  - filename primary text;
  - formatted size secondary text;
  - normal iOS row selection behavior.
- Keep UIKit-first implementation.
- Prefer `UIListContentConfiguration` on iOS versions where available; use availability checks if deployment target requires fallback.
- Add a context menu or explicit trailing action for "Go to message". If only one tap action is possible, make the primary tap open the file and expose jump through context menu/accessory.
- Add accessibility labels and identifiers for file rows and jump actions.

Acceptance criteria:

- Files fullscreen section is no longer empty when matching file media exists.
- File rows visually align with the attachment picker file source style.
- Files can be opened/shared through the existing app mechanism when URL is valid.
- Each file row exposes a reliable jump-to-message action.
- Empty state still appears when there are no files.
- No image/video/voice item leaks into the Files section.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/MediaGalleryFilesListTests \
  -only-testing:xabberTests/MediaGalleryFullscreenDataSourceTests \
  -only-testing:xabberTests/MediaGalleryMessageNavigationTests \
  -only-testing:xabberTests/ChatAttachmentFileSourceTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "fix(media-gallery): show fullscreen files"
```

## Task 6 - Fullscreen Voice Playback, Waveform, And Jump

Goal:

Make the fullscreen voice section display voice messages with waveform, play/pause/download states, auto-advance, and jump-to-message action.

Files to inspect/change:

- `xabber/controllers/chats/info_screens/views/gallery/VoiceGalleryForChatViewController.swift`
- `xabber/controllers/chats/info_screens/views/gallery/BaseMediaGalleryForChatViewController.swift`
- `xabber/common/audio_manager/VoiceMessagePlaybackCoordinator.swift`
- `xabber/controllers/chats/chat/messages_kit/Views/Cells/inline_views/InlineAudioGridView.swift`
- `xabber/controllers/chats/chat/Waveforms/` if reusable waveform view types live there
- Tests around `VoiceMessagePlaybackCoordinatorTests`

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/VoiceMessagePlaybackCoordinatorTests \
  -only-testing:xabberTests/MediaGalleryMessageNavigationTests \
  -only-testing:xabberTests/MediaGalleryFullscreenDataSourceTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required test changes:

- Add `MediaGalleryVoiceListTests`.
- Add `MediaGalleryVoicePlaybackTests`.
- Cover voice datasource mapping:
  - `.voice` items appear in Voice and non-voice media do not;
  - remote URL, decoded URL, duration, downloaded flag, message primary, archive id, and PCM/waveform levels map into a `VoiceMessageDescriptor`;
  - missing waveform produces deterministic fallback bars, not a blank cell.
- Cover cell rendering:
  - play/download/pause states are derived from `VoiceMessagePlaybackCoordinator.state`;
  - waveform progress reflects playing/paused state;
  - duration label shows total duration and current progress when playing/paused;
  - repeated configure/reuse does not duplicate subviews, gestures, observers, or constraints.
- Cover playback behavior with a fake coordinator/player where possible:
  - tap not-downloaded voice enqueues/downloads through the coordinator;
  - tap downloaded voice starts playback;
  - tap playing voice pauses;
  - playback state changes update visible cells;
  - after one visible voice finishes, the next visible locally available/downloaded voice starts automatically;
  - leaving/deinit removes observers and does not keep updating dead cells.
- Cover jump-to-message action uses Task 4 route.

Implementation requirements:

- Remove the empty datasource override in `VoiceGalleryForChatViewController`.
- Replace the image-style voice cell with a list row that embeds or shares the existing waveform/audio rendering behavior.
- Reuse `VoiceMessagePlaybackCoordinator`; do not recreate an independent AVAudioPlayer flow inside the fullscreen gallery.
- Feed the gallery's ordered visible voice descriptors into `VoiceMessagePlaybackCoordinator.setVisibleVoiceMessages(_)` so auto-advance follows the visible fullscreen order.
- Register one playback observer per controller and update only affected visible cells.
- Use the existing `AudioVisualizationView`/waveform style where practical.
- Keep row height stable and touch targets at least 44 pt.
- Provide a context menu or explicit action for "Go to message".
- Ensure playback continues or stops consistently with the existing app-level voice player behavior. If product behavior is ambiguous, preserve the coordinator's current global playback semantics.

Acceptance criteria:

- Voice fullscreen section is no longer empty when matching voice media exists.
- Each voice row has a waveform, play/download/pause affordance, duration/progress text, sender/date metadata if available, and a jump-to-message action.
- Playback works directly inside the fullscreen voice section.
- When a played voice message ends, the next visible/downloaded voice message starts automatically.
- Download, failure, retry/cancel states remain driven by `VoiceMessagePlaybackCoordinator`.
- Voice rows are reusable without duplicated subviews/observers/gestures.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/MediaGalleryVoiceListTests \
  -only-testing:xabberTests/MediaGalleryVoicePlaybackTests \
  -only-testing:xabberTests/VoiceMessagePlaybackCoordinatorTests \
  -only-testing:xabberTests/MediaGalleryMessageNavigationTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "feat(media-gallery): play fullscreen voice messages"
```

## Task 7 - Fullscreen Media Gallery Integration Verification

Goal:

Run a final end-to-end verification pass and document the durable fullscreen media gallery contract.

Files to inspect/change:

- All files touched in Tasks 1-6
- `xabberTests/` focused tests added during this goal
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/ui/notes.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/agents/tests/notes.md`
- `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/shared/interfaces.md` if Task 4 added a durable route source
- Optional curated docs under `/Users/igor.boldin/projects/xabber/xabber/projects/xabber/docs/` if the final contract is broadly useful

Pre-task tests:

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/MediaGalleryFullscreenLayoutPolicyTests \
  -only-testing:xabberTests/MediaGalleryFullscreenDataSourceTests \
  -only-testing:xabberTests/MediaGalleryImagePrefetchTests \
  -only-testing:xabberTests/MediaGalleryVideoCellStateTests \
  -only-testing:xabberTests/MediaGalleryFilesListTests \
  -only-testing:xabberTests/MediaGalleryVoiceListTests \
  -only-testing:xabberTests/MediaGalleryVoicePlaybackTests \
  -only-testing:xabberTests/MediaGalleryMessageNavigationTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Required test changes:

- Add or update a final integration test, for example `MediaGalleryFullscreenIntegrationTests`, that covers:
  - all four fullscreen gallery classes can build/apply datasource snapshots without crashing;
  - image/video sections use three-column grid policy;
  - file/voice sections use full-width list policy;
  - hidden-by-report media is excluded;
  - sensitive image/video reveal state remains per-session;
  - route-bearing file/voice rows expose jump actions;
  - gallery datasource sorting is consistent across all sections.

Implementation/documentation requirements:

- Fix any wiring bugs found by the final tests.
- Run the final focused suite and an adjacent chat/media suite.
- Run a Debug app build.
- If a connected device is available, run the final build on device; otherwise record the simulator fallback.
- Update vault notes with:
  - final user-visible behavior;
  - tests run;
  - build destination;
  - any manual QA not performed;
  - any residual risks.
- If a new `ChatOpenMessageRequestSource.mediaGallery` or equivalent becomes a durable cross-layer contract, update `shared/interfaces.md`.
- Do not leave disposable xcresult/log/archive artifacts outside normal Xcode cache folders.

Acceptance criteria:

- Fullscreen Images, Videos, Files, and Voice sections pass their focused tests together.
- App build passes after all tasks.
- New/changed navigation contract is documented.
- Vault UI/tests notes are updated.
- All task commits exist and the final task has its own commit.

Required verification:

```bash
tools/xcodebuild_cached.sh test \
  -only-testing:xabberTests/MediaGalleryFullscreenLayoutPolicyTests \
  -only-testing:xabberTests/MediaGalleryFullscreenDataSourceTests \
  -only-testing:xabberTests/MediaGalleryImagePrefetchTests \
  -only-testing:xabberTests/MediaGalleryVideoCellStateTests \
  -only-testing:xabberTests/MediaGalleryVideoPrefetchTests \
  -only-testing:xabberTests/MediaGalleryFilesListTests \
  -only-testing:xabberTests/MediaGalleryVoiceListTests \
  -only-testing:xabberTests/MediaGalleryVoicePlaybackTests \
  -only-testing:xabberTests/MediaGalleryMessageNavigationTests \
  -only-testing:xabberTests/MediaGalleryFullscreenIntegrationTests \
  -only-testing:xabberTests/ChatCollectionPrefetchTests \
  -only-testing:xabberTests/ChatAttachmentFileSourceTests \
  -only-testing:xabberTests/VoiceMessagePlaybackCoordinatorTests \
  -only-testing:xabberTests/ChatOpenMessageRequestHandlingPolicyTests \
  ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
git diff --check
tools/xcodebuild_cached.sh build ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Commit:

```bash
git commit -m "test(media-gallery): verify fullscreen media sections"
```

## Final Done Definition

The goal is complete only when:

- Each numbered task above has a focused commit.
- The final commit includes passing verification notes.
- Fullscreen Images always use a three-column width-derived grid and fast prefetch.
- Fullscreen Videos always use a three-column width-derived grid, preview rendering, and duration display.
- Fullscreen Files display real file rows and provide jump-to-message.
- Fullscreen Voice displays waveform rows, supports playback in-place, auto-advances, and provides jump-to-message.
- The compact info-card footer was not intentionally redesigned.
- The final response reports tests, build destination, changed files, and any residual risk.
