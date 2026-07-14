# Chat Search Performance Budgets

## Scope

These repository-relative budgets protect Telegram-style in-chat search result preparation and list updates. They cover detached DTO mapping, stable sort/deduplication, immutable snapshot-model construction, visible-body highlighting, and the synchronous UIKit apply segment. Network latency, Realm I/O, avatar downloads, and animation wall time are intentionally excluded.

The measurements below were recorded on the iPhone 16e simulator `7C8F9347-C7DA-4EF2-9DA0-71A52E3B93AF` on 2026-07-14 with `ChatSearchPerformanceTests`. Hosted tests used `TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1` and `TEST_RUNNER_XABBER_ISOLATED_STORAGE=1`.

## Regression budgets

| Operation | Fixture | Budget |
| --- | --- | --- |
| Mapping, ordering, and deduplication | 1,000 unique detached results plus duplicates | median `< 50 ms` |
| Scaling | 1,000 to 2,000 unique detached results plus duplicates | ratio `<= 2.5x` |
| Immutable snapshot-model construction | 1,000 prepared results, 750 previous results | median `< 100 ms` |
| Synchronous UIKit apply | 1,000 prepared results | every measured segment `< 100 ms` |

Preparation must be safe to run off-main. Realm-backed providers must emit detached results from their background work, while the diffable-data-source apply remains main-thread-only. Four incremental pages of 250 results must retain the visible anchor and must not reconfigure unchanged rows. Avatar work remains lazy and cancellable at cell configuration/reuse boundaries.

Highlight formatting is cached only by immutable source/query/locale/style inputs. Re-rendering the same 100 visible long bodies must perform no additional highlighting work; changing one query must invalidate only the affected entry. The bounded cache must remain disposable for memory-pressure handling.

## Task 25B evidence

Current-code baseline before optimization:

- 1,000-result preparation median: `7.743 ms`;
- 2,000-result preparation median: `15.945 ms`;
- scaling ratio: `2.059x`;
- snapshot-model median: `8.758 ms`;
- synchronous main apply maximum: `28.074 ms`.

Final measurement after reusing one immutable prepared batch and caching immutable highlight output:

- 1,000-result preparation median: `7.468 ms`;
- 2,000-result preparation median: `16.222 ms`;
- scaling ratio: `2.172x`;
- snapshot-model median: `0.963 ms`;
- synchronous main apply maximum: `1.984 ms`;
- `XCTClockMetric` pure-preparation average: approximately `8 ms`.

The optimization preserves the pre-existing result ordering and completeness-aware deduplication contract. Do not relax Unicode matching, stable identity, accessibility, or scroll-anchor correctness to satisfy these budgets.
