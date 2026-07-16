# Chat performance final gates

This document is the executable handoff for the G20 chat-performance gate. It
keeps deterministic fixture evidence, simulator trends, reference-device
measurements and live-account QA separate; results from one tier must not be
presented as evidence from another.

## Deterministic fixture tier

`Chat Performance UI Tests` launches the app only when both the explicit UI-test
marker and `--xabber-chat-performance-fixture small|million` are present. The
fixture uses the production `ChatViewController` mapping, layout, datasource,
collection view and composer paths, but does not connect accounts or observe
Realm/XMPP. Both logical scales expose only 80 resident rows, with a hard limit
of 360.

The independent XCUITest scenarios cover:

- first content frame for logical histories of 100 and 1,000,000 messages;
- fast movement in both directions and an incoming row while away from tail;
- optimistic send, edit and delete through the production composer/diff path;
- media prefetch-to-visible reuse with one download, one decode and one cache hit;
- skeleton presentation followed by one content reveal;
- Last Chats search for `test`, resolving the exact fixture target without an
  intermediate latest-message frame.
- portrait to both landscape directions and back, preserving the timeline
  anchor without a delayed correction.

Run with hosted isolation variables unset. The deterministic UI runner uses its
own fixture launch contract and rejects hosted-storage variables fail-closed:

```bash
unset TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT
unset TEST_RUNNER_XABBER_ISOLATED_STORAGE
export XABBER_DESTINATION='platform=iOS Simulator,id=<dedicated-udid>'
export XABBER_XCODE_CACHE_ROOT="$HOME/Library/Caches/XabberCodex/xabber-chat-performance-goal"
tools/run_chat_goal_tests.sh deterministic-ui G20
```

Required deterministic budgets are zero full-history enumerations, at most 360
resident messages, at most one forced layout and one programmatic offset per
initial-frame/target transaction, zero delayed correction, anchor drift at most
one point, and no active resource after teardown.

G20 `focused` is the union of every versioned G00-G19 preflight and focused
selector plus the final integration contracts; a source test prevents it from
shrinking back to the common smoke pack. The final dedicated hosted iPhone 16
Pro Simulator run executed 1,251 tests with zero failures in 380.936 seconds.
The two real-Realm million-scale tests passed in 164.613 and 178.464 seconds.
The separate smoke gate passed 234/234 in 2.596 seconds. The independent
five-scenario XCUITest matrix passed 5/5 in 77.640 seconds and covered both
logical scales, bidirectional movement plus incoming/outgoing mutation, media,
skeleton, exact search routing and portrait/landscape anchor preservation.

The live-account audit found additional defects that the original fixtures did
not expose: stale outgoing presentation after a transient bootstrap state,
strict text geometry, UIKit-owned layout-attribute mutation, blank historical
media, rotation restoration and committed-content-to-skeleton regression.
Each finding received a test-first regression and production fix before the
fixed-build rerun. The final authenticated rerun passed three additional older
MAM data pages, exact Last Chats search routing, history-gap closure, send/edit/
delete, explicit media terminal states, both orientation legs, largest Dynamic
Type and background/foreground without a skeleton or corrective scroll.

## Release Instruments tier

Run with hosted and live variables unset:

```bash
unset TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT
unset TEST_RUNNER_XABBER_ISOLATED_STORAGE
unset XABBER_CHAT_LIVE_QA_MODE
tools/run_chat_goal_tests.sh release-performance G20
```

The runner builds the explicit `CHAT_PERFORMANCE_LAB` Release configuration and
captures Time Profiler for both scales plus Allocations, Animation Hitches and
Network for the million-message fixture. Each probe performs exactly 20 real
append/remove datasource cycles and reports a privacy-safe machine-readable
sample. Raw traces stay outside the repository under the dedicated cache.

The Release report is backed by the production `ChatRenderOperationCounter`,
reset after the initial fixture frame and sampled only after all probe
transactions finish. The accepted operation vector is exactly 42 datasource
applies, 42 structural inserts, 42 structural deletes, zero moves and zero
reloads. There are 21 append/remove pairs (20 paging cycles plus optimistic
send); each deliberately crosses a date boundary and therefore changes both a
message row and a date-separator row. Any extra or missing apply, structural
item, move or reload fails the analyzer.

Simulator timing and RSS are trends, not hardware gates. Xcode 26 does not
support Animation Hitches or Network Connections on the iOS Simulator; the
runner accepts only the exact tool errors and records `simulator-unsupported`.
It must never convert those limitations into a pass. The hardware frame,
hitch and network gates remain `not-measured` until a Release run on the
reference iPhone 16 Pro is attached.

The owner subsequently restricted this work to Simulator only. No physical
device may be installed, launched or profiled for this task. Reference-device
metrics are now `excluded-by-owner: simulator-only`, not `pass`; this scope
change cannot be used to claim hardware-equivalent frame or hitch evidence.

The final iPhone 16 Pro Simulator trend measured 100/80 and 1,000,000/80
logical/resident rows. Warmed cycles 6-20 grew 0.0620% and 0.0360% over cycle 5;
optimistic rows appeared in 5.237 ms and 4.788 ms. Simulator first-stable timing
was 758.020 ms versus 338.739 ms and fails the absolute reference-device delta
formula by 419.281 ms / 55.313%; as required, this remains published as
non-gating simulator evidence rather than being promoted to a hardware pass.
The million scale being faster also demonstrates that total history does not
increase the bounded UI workload, but it is not a hardware latency claim. Both
scales emitted the same measured operation vector: 42 applies, 42 inserts, 42
deletes, zero moves and zero reloads. Both emitted one media download, one
decode and one visible cache hit.

Reference-device budgets after five warmups and twenty recorded runs:

- 100 versus 1,000,000 open delta no more than 10% and 50 ms;
- no main-thread stall over 100 ms;
- warm-scroll hitch ratio below 1%, with no frame over 33 ms;
- cycle 5 to maximum of cycles 6–20 resident-memory growth no more than 10%;
- optimistic local row visible within 100 ms;
- media visible request reuses the prefetched artifact.

## Live-account tier

Live QA is an explicit manual gate against only the dialog authorized by the
owner. Account credentials must be entered in the app by the owner or supplied
by an approved out-of-process secret provider. They must never appear in source,
argv, environment, launch arguments, a scheme, screenshots, reports or logs.

Read-only and mutation are separate sessions and separate reports. Both launch
the normal main app with hosted/fixture variables unset. Neither session may
logout, reset storage, delete an account or touch another dialog.

Read-only checklist:

1. Open the authorized dialog and wait for its stable first content frame.
2. Scroll older and newer through local and MAM boundaries, including fast
   direction reversals; record anchor jumps, flicker, duplicate rows and loaders.
3. Search for `test` from Last Chats and verify the exact result is centered in
   the first content frame with no latest-frame flash or corrective scroll.
4. Open visible text and media rows, then exercise rotation, the largest Dynamic
   Type category and background/foreground. Record Simulator network tracing as
   unsupported and pair the report with the deterministic app-layer
   disconnect/late-final/retry gate.
5. Record any read marker or MAM-side effect; create, edit or delete nothing.

Mutation checklist:

1. Generate a unique `chat-perf-qa-<run-id>-` prefix before creating anything.
2. Create only prefixed messages in the authorized dialog and record every
   server/message ID returned for this run.
3. Exercise optimistic send, acknowledgement, edit, delete and media rendering.
4. Delete only IDs in the run registry. Refuse a deletion if the ID was not
   registered by this run.
5. Verify the registry is empty and record server delete, tombstone, MAM and read
   marker effects. Never clean up pre-existing messages.

After completing the templates below outside the repository, validate them with:

```bash
XABBER_CHAT_LIVE_QA_MODE=read-only \
XABBER_LIVE_QA_REPORT=/absolute/path/read-only-report.txt \
tools/run_chat_goal_tests.sh live-read-only G20

XABBER_CHAT_LIVE_QA_MODE=mutation \
XABBER_LIVE_QA_REPORT=/absolute/path/mutation-report.txt \
tools/run_chat_goal_tests.sh live-mutation G20
```

### Read-only report template

```text
mode: read-only
hosted_flags_unset: true
credentials_transport: manual-or-protected-provider
authorized_dialog_only: true
search_query: test
exact_search_target_first_frame: pass
bidirectional_paging: pass
media_rendering: pass
rotation: pass
dynamic_type_largest: pass
background_foreground: pass
network_throttling_recovery: simulator-unsupported
deterministic_network_recovery: pass
network_recovery_tier: deterministic-simulator
foreign_mutations: 0
logout_reset_delete_account: false
read_or_mam_side_effects: <observed effects or none>
result: pass
```

### Mutation report template

```text
mode: mutation
hosted_flags_unset: true
credentials_transport: manual-or-protected-provider
authorized_dialog_only: true
run_prefix: chat-perf-qa-<unique-run-id>-
created_run_owned_ids: [<ids without message bodies>]
optimistic_send_edit_delete: pass
media_rendering: pass
deleted_only_run_owned_ids: true
remaining_run_owned_ids: []
server_delete_effects: <observed effects or none>
mam_tombstone_effects: <observed effects or none>
read_marker_effects: <observed effects or none>
read_or_mam_side_effects_recorded: true
foreign_mutations: 0
logout_reset_delete_account: false
result: pass
```

## Live audit result on the dedicated Simulator

The final independent rerun used the manually authenticated normal Release app
on the fixed-live iPhone 16 Pro Simulator. Installation was in-place and did not
uninstall the app, erase storage, clear keychain data, log out or automate
credentials. The Realm inode remained unchanged across the approved update and
the authenticated account opened directly afterward. No physical device was
used.

Read-only evidence passed:

- three additional older MAM data pages committed 250, 247 and 250 visible rows;
  every page advanced its cursor and retained the viewport anchor;
- Last Chats query `test` opened the exact historical result in the first Chat
  content frame, with no latest-window flash, empty frame or delayed correction;
- a deliberately fragmented neighborhood changed from 944 rows, three ranges
  and two gaps to 984 rows, one range and zero gaps before centering the target;
- push and local-notification routes opened the exact referenced message,
  including late-arriving targets and target neighborhoods containing gaps;
- historical file content rendered ready, while a missing historical image
  rendered an explicit unavailable state and gallery fallback instead of a
  blank terminal cell;
- portrait to landscape and back retained the same message anchor; largest
  Dynamic Type and background/foreground retained content and composer state;
- committed content never regressed to skeleton during fast older/newer motion.

Mutation evidence passed. A fresh run-owned message appeared immediately in an
already-open historical window, its edit appeared immediately with edited state,
and symmetric deletion removed it. Cleanup queried every run-owned original and
edited body/ID variant and found zero remaining local rows or latest-message
links. All four IDs registered over the final cleanup sequence were removed;
foreign mutations were zero.

During validation the privacy-safe reports stayed outside source at
`/tmp/g20-live-read-only-report.txt` and
`/tmp/g20-live-mutation-report.txt`. Both fail-closed validators accepted them,
after which the temporary reports and their run-owned identifiers were deleted.
Xcode 26 still does not support Network Connections or Animation Hitches on
Simulator. Those capabilities are recorded as `simulator-unsupported`; the
deterministic app-layer disconnect/retry/late-final tests pass, and hardware
metrics remain `excluded-by-owner: simulator-only`, never hardware-pass.

## Crash-report regression

The attached pre-G06 report dated 2026-07-14 23:01 showed
`RLMRealm verifyThread` while an asynchronous local page indexed resident
messages. The focused G06 commit at 23:21 freezes the resident session window
before background preparation. The exact newer-page regression now asserts
that session rows are frozen and has passed twenty consecutive iterations on
the dedicated simulator. Keep that test in the versioned matrix; a recurrence
is a hard failure, not a performance fluctuation.
