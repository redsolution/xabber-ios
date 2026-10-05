# OM2-N02 — own-device registration and PEP lifecycle

Completed 2026-10-05. Uses the authoritative own-node snapshot introduced by N01.

- Fresh startup fetches the current own node before selecting a positive31-bit device ID or creating any secret. Cached known data does not bypass this fetch. Collisions are retried before atomic protected-state preparation; failed fetch/save publishes nothing.
- Restart before the checked protected commit keeps no fresh SID. A committed aggregate follows existing identity/SID continuity. No registration journal or SID reassignment was introduced.
- Existing protected or migrated IDs remain stable. An absent shared SID mirror is rebuilt after successful protected preparation; fresh OM2 registration creates no legacy identity/SPK/OPK secrets.
- Device publication merges the received expanded-QName XML with local membership, preserving neighbours and their signed labels. Historical identity/trust rows cannot add members. Enabled own-node omission reannounces the local ID.
- Disable publishes the snapshot minus the local ID and retracts its bundle while preserving local keys/history. Direct bundle publication and late configuration/publication results cannot republish an explicitly disabled account.
- Existing explicit deletion paths supply the excluded device ID to the merge.

Verification: meaningful failing startup/collision/merge/disable tests before implementation. Integration gate210/210 passed, including N02 16 tests. After the final shared-SID mirror change, the N02 suite16/16 passed again; additional N03 authority tests in that run failed as intended before their fix. App/push compiled and linked. No live server run.
