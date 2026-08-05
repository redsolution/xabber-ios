# Chat-open fixed-rate video evidence

`tools/chat_open_video_evidence.py` is a fail-closed evidence tool. It never boots,
creates, erases, resets, shuts down, or uninstalls a Simulator. A native-window preflight
does perform two read-only measurements immediately before recording: the booted-device
inventory and CoreGraphics ownership of the declared window.

The recorder file, its SHA-256, and its original presentation timestamps are the immutable
authority. A requested FPS is metadata and can never prove the measured stream rate.

## Closed evidence model

1. `analyze` hashes the raw file and proves dimensions, duration, decoded frame count,
   rate fields, first/last PTS, every consecutive delta, and strict PTS monotonicity.
2. `normalize` maps every source sample to the first 60 Hz grid index at or after its PTS.
   Empty indices hold the latest source sample. All earlier samples that collide in one
   16.667 ms interval remain ordered records and lossless PNG authorities. Every raw RGB
   grid frame is committed to framemd5 before H.264/HEVC encoding. FFV1 is opt-in and must
   pass the same conservative space preflight. RGB decoding preserves exactly one output
   sample per source sample with timestamp passthrough, while binding the rawvideo encoder
   to the source stream's proven time base. This prevents both default-sync frame
   duplication/drop and false duplicate-DTS diagnostics caused by a coarser output time
   base. Normalization, independent validation, and offline marker detection use the same
   exact-cardinality command constructor; marker detection adds only its deterministic area
   scale. Missing, non-positive, or out-of-range time bases fail closed.
3. Accepted signpost phases are parsed mechanically from the checked-in production
   `ChatPerformanceSignpostPhase` Swift enum. There is no second Python phase list. An
   obsolete alias such as `open_request` fails; the production value is
   `chat.open_request`.
4. Video/signpost clock correlation is derived from at least two ordered measured marker
   pairs. A least-squares affine fit reports clock drift, maximum/RMS residual, the fixed
   residual bound, the 60 Hz quantization limit, and total bounded uncertainty. No numeric
   clock-origin option exists.
5. `validate` independently re-decodes the raw video, rebuilds every mapping/hash, checks
   one closed visual classification per source sample, verifies the successful capture
   receipt, scans the preserved log for raw private fields independently from the capture
   sanitizer, and hashes raw, derivative, sidecar, framemd5, classifications, signposts,
   calibration, bounded test log, capture receipt, collision set, and every collision PNG.
6. Final acceptance is two-pass. The first validation creates a manifest and returns
   `manifest_created_requires_revalidation`. A second validation against that immutable
   manifest returns `pass`. Any byte change in any authority then fails revalidation.

The default derivative is storage-bounded H.264 and remains an analysis convenience. Raw
VFR stays the lossless authority. Destination paths must be new and distinct. Publication
uses private partial artifacts and exclusive hard links; no output may alias or overwrite
the raw recording.

Reports contain hashes, numeric timing, counts, and closed enums only. They contain no
paths/URLs, owner/account/JID fields, message bodies, credentials, tokens, primary/archive
identity, or stable message/query identifiers. Closed integer enum/counter fields remain
available only as unquoted integers ending in `code`, `count`, `counter`, `index`, or
`ordinal`. Credential/authorization/token/body/JID/owner/path/URL/primary/stable stems never
use that numeric exception, and quoted numeric values are not treated as closed counters.
Collision PNGs remain local sensitive visual evidence.

## Phase and input schemas

Print or save the manifest derived from the current Swift source:

```sh
python3 -B tools/chat_open_video_evidence.py phase-manifest \
  --json-out /absolute/evidence/signpost-phase-manifest.json
```

The signpost exporter copies that manifest's `sha256` and emits only the closed numeric
record schema. Strings, identifiers, payloads, and legacy `{phase, monotonic_nanoseconds}`
events are rejected:

```json
{
  "schema_version": 1,
  "phase_manifest_sha256": "<64 lowercase hex>",
  "phase_count": 36,
  "records": [
    {
      "sequence": 1,
      "record_kind_code": 1,
      "phase_code": 1,
      "trace_id": 10,
      "generation": 20,
      "operation_kind_code": 1,
      "purpose_code": 1,
      "terminal_code": 0,
      "uptime_ns": 100005000000,
      "thread_code": 1,
      "counters": [{"code": 16, "value": 1}]
    }
  ]
}
```

The running performance app owns only three visible marker transitions. It records the
unsigned 64-bit uptime at the same display-link publication boundary and cannot author a
video index or PTS:

```json
{
  "schema_version": 1,
  "marker_manifest_sha256": "<64 lowercase hex>",
  "events": [
    {"marker_id": "M1", "visual_code": "vertical_bars", "uptime_ns": 100000000000},
    {"marker_id": "M2", "visual_code": "checkerboard", "uptime_ns": 102000000000},
    {"marker_id": "M3", "visual_code": "concentric_rings", "uptime_ns": 104000000000}
  ]
}
```

Only `derive-calibration` decodes the completed raw video, recognizes the exact magenta
fiducial/pattern runs, and adds `source_index` plus measured raw PTS. Its RGB pipe must emit
exactly one complete scaled frame for every ffprobe source sample under the same
passthrough/source-time-base contract as normalization; default FFmpeg synchronization is
forbidden. It rejects a run under two frames, a near/ambiguous pattern, a missing or
disjoint duplicate marker, wrong order, or less than 500 ms of raw video after M3. The
derived document is hash-bound to raw video, marker events, marker manifest, and the Swift
phase manifest:

```json
{
  "schema_version": 1,
  "raw_video_sha256": "<64 lowercase hex>",
  "marker_event_sha256": "<64 lowercase hex>",
  "marker_manifest_sha256": "<64 lowercase hex>",
  "phase_manifest_sha256": "<64 lowercase hex>",
  "markers": [
    {
      "marker_id": "M1",
      "visual_code": "vertical_bars",
      "source_index": 42,
      "source_pts_seconds": "0.700000000",
      "uptime_ns": 100000000000,
      "detection_score_milli": 990,
      "run_frame_count": 6
    }
  ]
}
```

All three markers are required. Marker recognition alone is not a publishable calibration:
`derive-calibration` runs the same affine clock gate as final validation before its
new-file-only write. The fixed one-frame residual and 10,000 ppm drift bounds are unchanged.

The rate claim must also be identifiable rather than a lucky fit. Both the M1→M3 source
span and uptime span must be at least:

```text
2 * maximum residual * 1,000,000 / maximum drift ppm
= 3.333333533... seconds
```

The display-link fixture therefore holds M1 and M2 for 2.0 seconds each, producing a
minimum four-second onset span. A shorter capture is rejected during derivation even when
its point estimates happen to fit unit slope; no calibration JSON is published. The report
states the ~16.667 ms video quantization separately from finer signpost timing and never
claims sub-frame visual precision.

Classifications contain every source index exactly once:

```json
{
  "schema_version": 1,
  "samples": {
    "0": {"visual_state": "skeleton", "forbidden_frame": false, "calibration_marker": true},
    "1": {"visual_state": "content", "forbidden_frame": false, "calibration_marker": false}
  }
}
```

Allowed states are `skeleton`, `content`, `empty`, `retry`, `stable`, `transition`,
`forbidden`, and `other_safe`. `calibration_marker=true` must identify exactly the source
indices in the measured calibration artifact, so a caller cannot silently assign the clock
fit to unrelated frames. Free text and identifiers are rejected.

## Offline analysis and normalization

```sh
python3 -B tools/chat_open_video_evidence.py analyze \
  --raw /absolute/evidence/raw.mov \
  --requested-fps 60 \
  --json-out /absolute/evidence/raw-analysis.json \
  --markdown-out /absolute/evidence/raw-analysis.md

python3 -B tools/chat_open_video_evidence.py normalize \
  --raw /absolute/evidence/raw.mov \
  --derivative /absolute/evidence/cfr60.mp4 \
  --sidecar /absolute/evidence/source-to-grid.json \
  --framemd5 /absolute/evidence/cfr60-pre-encode.framemd5 \
  --collision-directory /absolute/evidence/collisions \
  --codec h264

python3 -B tools/chat_open_video_evidence.py derive-calibration \
  --raw /absolute/evidence/raw.mov \
  --marker-events /absolute/evidence/capture/marker-events.json \
  --calibration-out /absolute/evidence/calibration.json
```

Stop when derivation fails. An older raw captured with 100 ms M1/M2 dwell must be
recaptured after the affected app and UI-test targets are rebuilt; never edit its raw,
marker export, or derived calibration to satisfy the clock gate.

The first validation creates the manifest but deliberately does not pass the final gate:

```sh
python3 -B tools/chat_open_video_evidence.py validate \
  --raw /absolute/evidence/raw.mov \
  --derivative /absolute/evidence/cfr60.mp4 \
  --sidecar /absolute/evidence/source-to-grid.json \
  --framemd5 /absolute/evidence/cfr60-pre-encode.framemd5 \
  --collision-directory /absolute/evidence/collisions \
  --classifications /absolute/evidence/classifications.json \
  --signposts /absolute/evidence/capture/signposts.json \
  --marker-events /absolute/evidence/capture/marker-events.json \
  --calibration /absolute/evidence/calibration.json \
  --test-log /absolute/evidence/capture/test.log \
  --capture-receipt /absolute/evidence/capture/capture-receipt.json \
  --json-out /absolute/evidence/manifest-candidate.json \
  --markdown-out /absolute/evidence/manifest-candidate.md
```

Revalidate unchanged bytes into new output paths:

```sh
python3 -B tools/chat_open_video_evidence.py validate \
  --raw /absolute/evidence/raw.mov \
  --derivative /absolute/evidence/cfr60.mp4 \
  --sidecar /absolute/evidence/source-to-grid.json \
  --framemd5 /absolute/evidence/cfr60-pre-encode.framemd5 \
  --collision-directory /absolute/evidence/collisions \
  --classifications /absolute/evidence/classifications.json \
  --signposts /absolute/evidence/capture/signposts.json \
  --marker-events /absolute/evidence/capture/marker-events.json \
  --calibration /absolute/evidence/calibration.json \
  --test-log /absolute/evidence/capture/test.log \
  --capture-receipt /absolute/evidence/capture/capture-receipt.json \
  --expected-artifact-manifest /absolute/evidence/manifest-candidate.json \
  --json-out /absolute/evidence/final-report.json \
  --markdown-out /absolute/evidence/final-report.md
```

Only the second unchanged pass can return `status=pass`, and only when no source sample is
forbidden.

## One-Simulator capture boundary

Native window capture accepts only locked simulator
`C3023207-3B9C-417F-8C17-F1A671277C08`, named
`Xabber Chat Fixed Live QA iPhone 16 Pro`. Immediately before launch it requires:

- exactly that one simulator is `Booted`;
- exactly one CoreGraphics match for the numeric window ID;
- owner application `Simulator`;
- a visible layer-zero window title matching the locked device.

The read-only CoreGraphics inventory is executed through the installed `/usr/bin/swift`
runtime and serialized with Foundation `JSONSerialization`. Do not replace it with the JXA
`ObjC.deepUnwrap` bridge: on macOS 26 the `CFArray` returned by
`CGWindowListCopyWindowInfo` is not a JavaScript array, so that bridge exits before the
strict window validator can inspect the result.

The XCTest command grammar is also closed: `/usr/bin/env`, the repository's absolute
`tools/xcodebuild_cached.sh`, action `test`, the exact C302 destination, explicit
single-selector `-only-testing:xabberChatPerformanceUITests/ChatPerformanceUITests/test…`,
the exact ordered safety fragment
`-jobs 1 -parallel-testing-enabled NO -collect-test-diagnostics never`, and the isolated
`xabber.ios.codex-chat-performance` app/extension bundle pair. `booted`, arbitrary
executables, broad selectors, production bundle `xabber.ios`, `clean`, `erase`, `reset`,
`uninstall`, `shutdown`, parallel execution, and every other UUID fail closed. The sole
non-simulator exception is an app-container UUID already present in the exact
`resolve(strict=True)` data-container result: it is accepted only in the three fixed
data-container/signpost/marker-event assignments after those paths match the capture
declarations and both exports prove they are new descendants of that container. A UUID in
an export filename, destination, wrapper, selector, extra argument, or capture command is
still rejected.
The selector must be one of the 25 checked-in `*VideoRoute` entries in
`CHAT_OPEN_VIDEO_ROUTE_MANIFEST`; a second selector, a syntactically plausible unknown
selector, and legacy/non-video tests are rejected. The selected test name, public matrix
route code, and public fixture scenario are copied into the capture receipt and both-stage
artifact manifest. The app-authored signpost export repeats the route/scenario pair, and a
mismatch invalidates capture finalization.

`E04` is bound only to
`testChatOpenE04UnsyncedStaleLocalRowsVideoRoute` and
`bootstrap-stale-local-to-content`; the superficially similar E02 empty-local route is not
accepted as evidence for stale-local suppression.

`X01` is bound only to `testChatOpenX01SearchExactLocalVideoRoute` and
`search-exact-local`. Its terminal receipt proves that the accepted local viewport request
has search provenance, requests highlight, keeps `markReadOnVisible=false`, and performs no
archive/gap transaction or later correction. That receipt does not by itself prove the
visible highlight overlay lifecycle; the sealed frame audit remains the visual authority.

`P13` is bound only to
`testChatOpenP13DeletedMentionAdvancesVideoRoute` and
`mention-deleted-advance`. The route starts on the real Realm-backed Notifications list,
taps the still-visible notification whose ordinal-120 message has become deleted, and
passes through the weak scene coordinator and real Last Chats single-flight into one
native animated Chat push. The ordinal-120 notification must be invalidated once, the
valid same-group ordinal-160 notification must be the only admitted exact target, and an
unrelated group must remain untouched. The first and only real frame has
`mention-notification` provenance, no skeleton/latest fallback, and the
`initial-local-content` trace contract. The no-following branch remains a separate hosted
selector and must produce typed unavailable with no navigation; it is not overloaded into
the video route.

`P14` is bound only to
`testChatOpenP14LastChatsSeededMentionVideoRoute` and
`last-chats-seeded-mention-exact`. The route starts on a visible production Last Chats row,
admits no destination or pending-open request before the single row tap, and resolves the
persisted unread mention before first-frame preparation. Its terminal evidence must prove
the explicit mention anchor won over the distinct unread, saved-position, and latest
candidates; the first and only real frame is exact within one point; and the persisted
notification remains unread through the initial commit before production read-visible
reconciliation marks it read exactly once. `V01`, `P01`, `P02`, `P11`, `P13`, arbitrary
P14-named selectors, and cross-swapped route/scenario bindings are not P14 evidence.

`capture-run` repeats the window/device measurement after it owns the global lock and
immediately before recorder spawn. The receipt preserves ordered monotonic-nanosecond
timestamps for the window measurement, pre-spawn boundary, and completed spawn; a missing
or reordered bracket cannot pass final validation.

Native capture also fails closed on window geometry. The exact CoreGraphics snapshot must
contain finite integral bounds, at least `400x850` points, with portrait `width / height`
between `0.440` and `0.480`. The known-good window-204 smoke measured `456x996`; the failed
N01 attempt measured only `49x143` and produced unusable H.264 `50x144`. The recorder
explicitly requests one output pixel per measured window point, independent of Retina
backing scale, and H.264 may align an odd requested dimension upward to the next even pixel.
The receipt embeds the bounds, complete policy, expected aligned pixel dimensions, snapshot
hash, policy hash, and geometry hash. Final validation requires ffprobe dimensions to match
that receipt exactly, so a post-preflight resize cannot silently become accepted evidence.
The tool never resizes or scales a recording to make it pass.

If preflight reports that the window is below the evidence minimum, restore only the
already-open locked Simulator window: choose **Window → Pixel Accurate** (`⌘2`). On this
locked host/window-204 setup that command measures the known-good `456x996`. **Fit Screen**
(`⌘3`) is not an accepted fallback here: it measured `1368x2792` and correctly failed the
maximum portrait ratio. **Physical Size** (`⌘1`) measured only `286x656` and correctly
failed the minimum. A System Events resize request was ignored, so do not use scripted or
manual resizing as geometry evidence. Do not boot, clone, erase, reset, reinstall, or target
another simulator. Then rerun the read-only preflight with a fresh nonexistent raw path and
the current exact window ID before attempting `capture-run`:

```sh
python3 -B tools/chat_open_video_evidence.py capture-preflight \
  --simulator-id C3023207-3B9C-417F-8C17-F1A671277C08 \
  --raw-output /ABSOLUTE/NEW/chat-window-preflight.mov \
  --capture-command-json '["/usr/bin/swift","/ABSOLUTE/REPO/tools/chat_open_window_recorder.swift","--window-id","204","--output","/ABSOLUTE/NEW/chat-window-preflight.mov"]'
```

This command queries inventory/window metadata only; the declared raw must remain absent.

The lead-owned preflight resolves the already-installed isolated app data container with
read-only `simctl get_app_container` for the exact locked UDID and bundle. Both app-authored
exports must be distinct files in the existing writable
`Library/Caches`; arbitrary host `/tmp` exports are rejected. The absolute preflight
container is deliberately **not** forwarded to `XCUIApplication`: `xcodebuild test` may
reinstall the isolated fixture and replace that container UUID before the app launches.
The installed UI-test runner also does not inherit arbitrary environment variables from
the parent xcodebuild process. Every checked-in `*VideoRoute` method therefore supplies its
own manifest matrix-route code and constructs exactly
`Library/Caches/chat-open-<route>-signposts.json` plus
`Library/Caches/chat-open-<route>-markers.json` inside the runner. The app resolves that
relative pair against its actual runtime `NSHomeDirectory()` and never accepts an absolute
destination, legacy container assignment, mismatched pair or arbitrary cache filename.

Repeated standalone VideoRoute runs may leave this deterministic regular-file pair. The
app removes only the exact matched pair at the next session start; unrelated cache files
are untouched. The host still rejects links and proves that accepted files were created
after the current XCTest spawn boundary.

After XCTest exits, `capture-run` resolves the exact performance bundle's current data
container again. It reconstructs only the same two verified relative descendants, rejects
links, stale pre-XCTest files, non-regular files, empty files and files over 16 MiB, then
copies them through no-follow file descriptors into a private staging directory. Cleanup
removes only the exact device/inode pairs successfully staged by this run; a stale or
replaced file is preserved and the capture fails closed. Missing exports still produce a
bounded failure evidence package without writing placeholders into a deleted or stale app
container. Thus a container UUID change is expected transport behavior, not authority to
scan another sandbox.

Build the one selected route before any recorder exists. `build-for-testing-run` accepts
only the exact cached-wrapper `build-for-testing` grammar, refuses an active capture lock,
and seals a path-free receipt containing the command hash plus the exact locked-arm64
`.xctestrun` and all runnable products it references. The selected plist must match
`Chat Performance UI Tests_iphonesimulator<SDK>-arm64.xctestrun`; stale universal or foreign
scheme plists are not authority for the locked arm64 destination. System `/usr/bin/plutil`
decodes the plist through an argv-only, bounded, no-shell command.

The xctestrun target schema is closed to `xabberChatPerformanceUITests`. Its app, runner,
nested UI-test bundle and push-extension references must be exactly the known
`__TESTROOT__`/`__TESTHOST__` products. The collector resolves them under cached
`Build/Products`, parses each `Info.plist` to bind the expected bundle identifier and
executable, then recursively hashes every regular file in all four bundles. Missing files,
links, non-regular entries, path escapes, unexpected dependencies, incompatible metadata,
unbounded inventories and files that change while decoded/hashed all fail closed. The
receipt publishes only hashed path identities, bundle identifiers, roles, byte/file counts,
executable hashes and aggregate manifests; no filesystem path is published. For N01 use:

```sh
python3 -B tools/chat_open_video_evidence.py build-for-testing-run \
  --simulator-id C3023207-3B9C-417F-8C17-F1A671277C08 \
  --build-receipt /tmp/chat-route-prebuilt.json \
  --build-command-json '["/usr/bin/env","-u","TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT","-u","TEST_RUNNER_XABBER_ISOLATED_STORAGE","-u","XABBER_CHAT_LIVE_QA_MODE","XABBER_SCHEME=Chat Performance UI Tests","XABBER_DESTINATION=platform=iOS Simulator,id=C3023207-3B9C-417F-8C17-F1A671277C08","/ABSOLUTE/REPO/tools/xcodebuild_cached.sh","build-for-testing","-jobs","1","-parallel-testing-enabled","NO","-collect-test-diagnostics","never","-only-testing:xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenN01PreloadedLatestVideoRoute","XABBER_APP_BUNDLE_IDENTIFIER=xabber.ios.codex-chat-performance","XABBER_PUSH_EXTENSION_BUNDLE_IDENTIFIER=xabber.ios.codex-chat-performance.xabber-push-extension"]'
```

Only after that command succeeds may capture start. Export basenames must match the
selected route exactly, and the test action must be `test-without-building`; ordinary
`test`, `build`, and `build-for-testing` are rejected inside the recorder scope:

```sh
python3 -B tools/chat_open_video_evidence.py capture-run \
  --simulator-id C3023207-3B9C-417F-8C17-F1A671277C08 \
  --raw-output /tmp/chat-route-raw.mov \
  --capture-evidence-directory /tmp/chat-route-capture \
  --signpost-export /ABSOLUTE/LOCKED_APP_DATA_CONTAINER/Library/Caches/chat-open-N01-signposts.json \
  --marker-event-export /ABSOLUTE/LOCKED_APP_DATA_CONTAINER/Library/Caches/chat-open-N01-markers.json \
  --build-receipt /tmp/chat-route-prebuilt.json \
  --capture-command-json '["/usr/bin/swift","/ABSOLUTE/REPO/tools/chat_open_window_recorder.swift","--window-id","12345","--output","/tmp/chat-route-raw.mov"]' \
  --test-command-json '["/usr/bin/env","-u","TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT","-u","TEST_RUNNER_XABBER_ISOLATED_STORAGE","-u","XABBER_CHAT_LIVE_QA_MODE","XABBER_SCHEME=Chat Performance UI Tests","XABBER_DESTINATION=platform=iOS Simulator,id=C3023207-3B9C-417F-8C17-F1A671277C08","XABBER_CHAT_ARTIFACT_DATA_CONTAINER_PATH=/ABSOLUTE/LOCKED_APP_DATA_CONTAINER","XABBER_CHAT_SIGNPOST_EXPORT_PATH=/ABSOLUTE/LOCKED_APP_DATA_CONTAINER/Library/Caches/chat-open-N01-signposts.json","XABBER_CHAT_VIDEO_CALIBRATION_EXPORT_PATH=/ABSOLUTE/LOCKED_APP_DATA_CONTAINER/Library/Caches/chat-open-N01-markers.json","/ABSOLUTE/REPO/tools/xcodebuild_cached.sh","test-without-building","-jobs","1","-parallel-testing-enabled","NO","-collect-test-diagnostics","never","-only-testing:xabberChatPerformanceUITests/ChatPerformanceUITests/testChatOpenN01PreloadedLatestVideoRoute","XABBER_APP_BUNDLE_IDENTIFIER=xabber.ios.codex-chat-performance","XABBER_PUSH_EXTENSION_BUNDLE_IDENTIFIER=xabber.ios.codex-chat-performance.xabber-push-extension"]' \
  --timeout-seconds 300
```

`capture-run` re-hashes the receipt and complete referenced-product inventory during route
preflight, then repeats that proof under the capture lock after the final window/source
measurement and immediately before recorder spawn. A stale receipt or any app, runner,
UI-test bundle, extension, metadata, resource or executable byte/mode change is rejected
before ScreenCaptureKit or XCTest can start. The route, simulator, bundles, selector and
safety flags must match the no-build test exactly. The final capture receipt records
`test_without_building=true`, the no-build command hash, prebuild command/receipt hashes and
the path-free build-products manifest hash. It also records a closed binary-provenance bit,
arm64 selection policy, exact `1` xctestrun / `4` products / `4` runnable executables,
bounded unique regular-file/byte counts and the referenced-files manifest hash. Receipts
from the former xctestrun-only schema are rejected by final package validation.
Compilation and package resolution therefore occur outside the raw video; the recording
contains only no-build test preparation, app install/launch and the selected scenario.

One global lock prevents a second recorder. Success, XCTest failure, timeout, SIGINT,
SIGTERM, and SIGHUP all stop and finalize the raw recording, preserve a privacy-redacted
bounded combined test log, signpost/marker-event exports (or explicit unavailable
placeholders), terminal receipt, and capture artifact manifest. Missing/unavailable exports
cannot pass final validation. SIGKILL and host power loss remain outside process guarantees.
The bundled ScreenCaptureKit helper emits the fixed `READY` record only after recording has
actually started; `capture-run` will not launch XCTest before that record arrives. The
helper independently rechecks the exact numeric `SCWindow` owner, locked-device title,
layer and visibility before applying a desktop-independent-window filter.
The private no-overwrite staging filename keeps `.mov` as its final extension because
AVFoundation rejects an extensionless/non-MOV destination before readiness. Recorder
startup stderr is consumed only to a 4 KiB memory bound; reports expose only one fixed
allowlisted `RECORDER_ERROR` code and never echo compiler output, file paths, or raw stderr.

Before publication, a successful capture validates every signpost record and counter against
the complete closed numeric schema, the production-derived phase manifest, and the selected
route binding; checking only top-level fields is insufficient. Marker events must also pass
their exact closed schema. On failure, timeout, or cancellation, malformed, private, or
otherwise non-closed exports are not copied: fixed `available=false` placeholders replace
them. A valid closed numeric diagnostic export may still be preserved.

The capture-log privacy gate covers bare `key=value`, bare colon fields, quoted JSON keys,
spaced and bracketed keys, pretty-printed multiline JSON objects/arrays, escaped JSON strings,
and multiline message-body continuations. The sanitizer structurally replaces the direct
field/identity forms it can normalize.
Direct owner/account/JID/message/query/primary/archive/stable identity, body, authorization
and credential values are replaced without copying the raw value into an error or report;
opaque escaped/truncated forms are rejected by the next gate.
Finalization then runs a separate raw-field detector, including recursive embedded-JSON
decoding with fixed depth/work limits, over the exact bounded bytes it will publish;
`validate` repeats that detector over the sealed `test.log`. A sanitizer miss, including an
escaped or truncated embedded JSON key/value, therefore fails closed instead of being
accepted or necessarily normalized merely because sanitizing the file again is idempotent.
Megabyte lines are scanned
linearly. Publication truncates only at a complete newline boundary (or emits a fixed omission
record), so it cannot split UTF-8 or a redaction token.

The capture receipt hashes only the published `test.log`; it never emits a digest of the raw
private stream. Its provenance separates collected raw bytes, observed raw bytes, raw
collection truncation, published-log bounding, and their combined `truncated` result. A log
that merely shrinks or expands during redaction is not mislabeled as collection truncation.

macOS 26 `screencapture -v -l<window>` is rejected: despite its option grammar, it creates
one still sample and exits instead of remaining a window-video recorder. The bundled native
helper uses ScreenCaptureKit and requests a 60 Hz minimum frame interval, but that request is
still not rate evidence. Bundled AXe supports only 1–30 FPS despite a wider wrapper schema.
Every fresh raw must pass `analyze`; otherwise retain it as VFR authority and use the
attributed CFR60 derivative.

## Source-only verification

```sh
python3 -B -W error::ResourceWarning -m unittest -v \
  tools.tests.test_chat_open_video_evidence
```

The suite uses stdlib mocks plus a bounded 32×32 ffmpeg-generated VFR fixture. The fixture
reproduces rawvideo timestamp quantization, proves that default sync would change the source
sample count, and requires exact source SHA-256 and CFR-grid MD5 agreement after independent
re-decode. The suite also exercises success, failure, timeout, signal finalization,
structured privacy redaction, independent raw-field rejection, bounded runtime/byte
publication, safe failure placeholders, strict success-export validation, and closed
numeric counter preservation; it does not invoke Simulator, XCTest, `xcodebuild`,
`screencapture`, application runtime, or a real recording.
