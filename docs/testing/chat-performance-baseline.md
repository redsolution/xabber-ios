# Chat performance measurement contract

This document defines how the ChatViewController optimization goal separates deterministic complexity proof from device performance measurements. It is the G00 baseline contract; later tasks must add scenario-specific counter limits before changing the corresponding production path.

## Evidence layers

1. Deterministic XCTest gates prove bounded work. They count enumerated rows, materialized candidates, rich snapshots, text measurements, cache hits/misses, reload/layout/offset mutations, cell bind masks, media work, and active tasks/timers. These gates are required in CI.
2. Simulator Release/Debug runs publish non-gating timing and memory trends. Simulator frame rate and wall-clock values are never used as 60/120 Hz acceptance gates.
3. Physical-device Release traces provide frame, hitch, stall, and resident-memory gates. A trace is comparable only when commit, dSYM, device, OS, thermal state, orientation, text size, fixture, and network profile are recorded.

Timing cannot compensate for an O(N) operation count. A fast run that enumerates the whole conversation fails.

## Fixed environments

The simulator trend environment established on 2026-07-14 is:

- dedicated `Xabber Chat Audit 2026-07-14` simulator;
- iPhone 17 Pro class, iOS 26.0 (`23A343`);
- Xcode 26.0 (`17A324`);
- Apple silicon host, macOS 26.0 (`25A354`);
- dedicated cache `$HOME/Library/Caches/XabberCodex/xabber-chat-performance-goal`;
- hosted tests with account autoconnect disabled and isolated storage enabled.

The physical reference class discovered on 2026-07-14 is:

- iPhone 16 Pro, model identifier `iPhone17,1`;
- iOS 26.5 (`23F77`) at baseline discovery;
- ProMotion, maximum 120 Hz;
- Release configuration with matching dSYM.

The report must use the actual OS/build at capture time. An OS, Xcode, device class, refresh-rate mode, or compiler configuration change starts a new baseline series; it must not silently replace the previous series. Device names and UDIDs are not committed.

## Fixtures

`ChatPerformanceFixtureGenerator` supports 100, 10,000, 100,000, and 1,000,000 thin rows. It generates and persists one row at a time inside bounded batches. The in-memory XCTest store proves that generation does not allocate a million-element Swift array. The Realm adapter accepts only an in-memory Realm and deletes all generated rows on success or failure.

The separate rich fixture covers short and long text, UTF-16 markup, forwarded content, one and five images, video, location, contact, voice, edited, read, and error states. It is small by design: total persisted history must not determine the number of rich UI models.

Fixtures compile only in Debug and must never point at an account Realm or production storage.

## Deterministic gates

G00 establishes these immediately enforceable invariants:

- fixture requested count equals persisted count;
- maximum generated thin rows retained by the generator is one;
- cleanup leaves zero fixture rows, including after a write failure;
- instrumentation uses a closed enum and integer values only;
- disabled counter autoclosures are not evaluated;
- counters are lossless under concurrent recording;
- gauges never become negative;
- a typed `ChatRenderOperationBudget` fails only operations above their declared maxima;
- operation and signpost field names contain no account, JID, body, URL, path, stanza, archive, or message identifiers.

Scenario owners add exact maxima in G01–G20. At minimum, the completed architecture must enforce:

- one logical datasource update issues at most one forced layout flush and one programmatic offset mutation after snapshot/layout readiness;
- teardown returns active task and timer gauges to zero;
- dataset size 100 versus 1,000,000 does not change viewport-bounded operation counts;
- prefetch-to-visible does not increment download or decode for the same media key;
- a stale generation cannot increment datasource, loader, offset, or highlight mutations.

## Signpost vocabulary

The stable privacy-safe phases are:

- open request, local snapshot ready, first content committed, first stable frame;
- page plan, query, persist, and apply;
- anchor received, resolved, and centered;
- media prefetch and visible hit;
- existing mapping, datasource, layout, scrolling, persistence, cache, and observer phases.

Signposts carry phase identity only. Correlation with a specific test scenario belongs in the external report, never in private payload strings.

## Scenario matrix

For each history size, record warm open, older-page prepend, newer-page append, fast bidirectional scroll, optimistic send, rich-media completion, local search jump, and one-page remote search jump. Use the same conversation shape, viewport, orientation, content size category, theme, and network profile.

For physical baselines:

1. Reboot or otherwise establish the documented thermal/memory state.
2. Install the Release build with matching dSYM and prepare the fixture without capturing.
3. Discard five warm-up repetitions.
4. Record twenty repetitions for every latency distribution.
5. Record Time Profiler, Animation Hitches, and Allocations separately so each trace contains one named scenario only.
6. Repeat paging twenty times and compare resident memory after cycle 5 with the maximum of cycles 6–20.
7. Export the report and preserve traces outside the repository.

The target contract is:

- p95 open-to-first-stable-content difference between 100 and 1,000,000 rows is at most 10% and at most 50 ms absolute;
- zero main-thread stalls above 100 ms during open, paging, send, and search jump;
- warm scripted scroll has zero frames above 33 ms and hitch-time ratio below 1%;
- physical p95 frame time is at most 16.67 ms at 60 Hz and 8.33 ms at 120 Hz;
- prepend, trim, and media-completion anchor drift is at most 1 pt;
- resident growth after cycle 5 is at most 10%, with task/timer gauges returning to baseline;
- optimistic text send to local row has p95 at most 100 ms without `reloadData`.

These hardware values remain non-gating until the first valid 20-run Release series is attached to the goal task. Deterministic gates are active immediately.

## Commands

Prepare an external report directory:

```bash
tools/run_chat_performance_baseline.sh prepare /path/outside/repo/chat-baseline
```

Build Release with a dedicated cache. Override `XABBER_PERF_DESTINATION` for a specific signed device destination when required:

```bash
tools/run_chat_performance_baseline.sh build /path/outside/repo/chat-baseline
```

Launch the Release app manually, prepare exactly one scenario, then capture it. The device identifier is consumed by `xctrace` but is not written to metadata:

```bash
XABBER_PERF_DEVICE='<device name or UDID>' \
XABBER_PERF_PROCESS_NAME='<running process>' \
tools/run_chat_performance_baseline.sh capture \
  /path/outside/repo/chat-baseline \
  open_1m \
  'Animation Hitches'
```

The generated report contains run validity, latency/frame/memory results, deterministic counts, anchor/lifecycle checks, trace inventory, verdict, and the first meaningful regression. It intentionally excludes credentials and chat content.
