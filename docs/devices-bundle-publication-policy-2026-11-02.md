# Devices-bound OMEMO bundle publication

Date: 2026-11-02. The client fix passed 293/293 isolated Simulator tests, including the affected application build. Live-server/device publication was not exercised during this task.

The password-authentication branch previously enabled pre-bind device registration only for HOTP, so a DEVICES-OCRA-only server could bind a password session without a Devices identity. It now enables registration for either supported mechanism and records the actual accepted registration or OCRA identity before startup publication.

A retained iOS OMEMO identity can have a different SID from the SID still associated with its authenticated Xabber Devices record. Previously iOS published that retained bundle directly. The server rejects the different SID with `policy-violation`; changing PubSub configuration does not resolve that binding conflict.

The corrected strong Devices path reads the current authenticated device's server metadata before publication. It preserves the local private identity, SID and ratchet state. If migration is necessary, it withdraws only the uniquely attributed old bundle, waits for its correlated result, reads the metadata again, and then publishes the retained bundle. Server-managed device membership remains server-owned.

## References and scope

The reviewed local server repository is `/Users/igor.boldin/projects/xabber/server`, unchanged at `c1a431d022dcfa7678383cee18a928074808e422`. This identifies the checked-out source contract; it does not identify the version deployed by a particular account's server.

The knowledge-base reference is `xabber-knowledge/protocols/XEP-DEVICES.md`, section 10, alongside the existing managed-node contract and the 2026-10-21 bundle-node preconfiguration note. Devices manages the account's OMEMO membership and associates bundle item IDs with device metadata; bundle format remains XEP-0384.

Relevant server boundaries:

- `src/mod_devices.erl:186–196` rejects prohibited own-account publication before PubSub processing.
- `src/mod_devices.erl:602–638` forbids client device-list publication and accepts a bundle SID only when the current authenticated device is unmapped or already has that SID.
- `src/mod_devices.erl:640–663` resolves the Devices identity through the actual sender's full resource and server session metadata.
- `src/mod_pubsub.erl:1794–1800` handles publish-options mismatch as `conflict/precondition-not-met`, a different error class.
- `src/mod_pubsub.erl:3246–3259` supplies public, persistent managed OMEMO node defaults with multiple bundle items.

No server source, configuration, database or deployment was modified during this task. No live device registration, revocation or bundle mutation was performed. In particular, the fix does not bypass Devices by changing the IQ destination or weakening server policy.

## Accepted session proof

A cached Devices UUID, a stored OMEMO SID, capability availability, or `stream.isAuthenticated` alone is insufficient to authorize managed publication. The Devices manager records actual accepted authentication against a weak reference to the exact bound stream, owner, full resource and authentication generation. A new full authentication replaces the generation even when it reuses the same stream object and UUID. Valid SM resumption can preserve accepted authentication; a changed owner/resource or suspended authentication cannot supply proof.

Publication requests additionally capture the OMEMO manager's transport generation and the retained local SID. Incoming managed metadata, retraction and publication results must match the exact request, live stream, owner service, recipient resource, authentication generation and current local SID. A queued write, a stream-management acknowledgement, or a UI Devices projection is not publication authority.

Both account IQ dispatch and the UI-action IQ route pass the actual receiving stream. Owned publication metadata is handled before generic Devices-list projection, and remains a value-only snapshot separate from mutable Realm display records.

An unproven secondary stream can use an available accepted primary stream. If no eligible stream exists, publication remains pending for later authenticated activity; it does not recursively enqueue `Account.action` work.

## Strong Devices publication sequence

1. Read `https://xabber.com/protocol/devices#items` from the account's bare JID using the accepted stream.
2. Resolve the exact authenticated Devices UUID in that fresh response. Reject missing or duplicate UUIDs, malformed/ambiguous OMEMO IDs and wrong namespaces.
3. Before publishing, require that the retained local SID is not assigned to another Devices UUID. Before retracting an old SID, require that the old SID is unique to the current Devices UUID.
4. If the current device has no SID, or already has the retained local SID, publish the retained bundle item.
5. If its old SID differs, retract only that exact old item. Wait for the matching retraction result and fetch fresh metadata again. A result alone is insufficient: the reviewed server's retraction hook can acknowledge an item operation without proving that a different device's metadata changed.
6. Publish only after the second response proves a cleared or matching binding with no new collision. Unchanged or unexpectedly replaced metadata stops the repair instead of causing repeated retractions.
7. Mark the bundle published only after its correlated server result and existing current-bundle hash validation succeed.

The live metadata authorization can be reused for ordinary OPK updates in the same accepted session. Policy failure, reset, withdrawal or changed binding revokes it. A managed `policy-violation` triggers a fresh metadata read; unchanged rejected mapping is blocked from identical automatic publication retries in the retained publication cycle.

The publication XML remains one `urn:xmpp:omemo:2:bundles` item with the retained local SID. This path emits no node creation, configuration, publish-options negotiation or client OMEMO device-list publication.

## Disable and concurrent lifecycle changes

Managed encryption disable uses the same accepted binding and fresh metadata to withdraw only the current device's uniquely attributed server SID. A sibling's item is preserved, including when that sibling happens to use the retained local SID while the current device has a different uniquely attributed old SID. No replacement bundle is published while encryption is disabled.

An already-issued bundle publication or retraction is not treated as cancelled merely because the setting changes. Disable waits for an outstanding publication boundary before reading its withdrawal mapping. Re-enable during a withdrawal waits for the retraction boundary and fresh metadata before republishing. A late result after reset, changed authentication or a different receiving stream grants no authority.

Existing publication deadlines and the owner-queue watchdog bound outstanding requests. The watchdog can finish a pending disable withdrawal without running key maintenance while encryption is disabled. Failed disabled cleanup does not start an endless automatic publication loop.

## Legacy HOTP compatibility

An actually accepted legacy HOTP authentication may not expose a strong Devices UUID. That mode retains the existing managed item-only publication and ordinary acknowledged OPK update behavior, with stream/generation-scoped results. It never guesses a UUID from the OMEMO SID, cached metadata, decimal prefixes or a reused secret.

This compatibility path does not perform automatic old-SID migration cleanup. A `policy-violation` stops identical automatic publication attempts for its retained publication transport cycle. The block is ephemeral: manager reset clears that cycle, so this is not a promise of a block persisting across all SM-resume/reset paths or application restarts.

The compatibility path preserves the pre-existing explicit own-local-SID disable withdrawal. It cannot provide the strong UUID path's global sibling-SID attribution guarantee. That limitation is explicit; solving it requires authenticated server identity evidence, not speculative metadata matching or a new key reset.

## Standard PEP compatibility and verification

Ordinary non-managed PEP publication retains its existing node setup, normative publish-options and correlated configuration-retry path. The managed Devices gate does not change crypto wire format or create user trust from a public bundle.

`DevicesBundlePublicationPolicyTests` covers actual account IQ routing, fresh metadata and safe SID migration, sender/recipient/namespace/stream/generation fences, collisions introduced during refetch, timeouts, disabled cleanup, setting changes while operations are on wire, legacy HOTP and bounded waiting without accepted proof. Existing managed lifecycle fixtures now model accepted authentication and metadata results instead of treating a capability flag as authority. Their standard PEP fixtures remain unchanged.

The initial 15 publication cases exposed 16 expected failing assertions before implementation. Additional cases were written before their corresponding implementation changes; no separate failing-run claim is made for those later cases. Final verification: 293/293 tests passed in one cached Debug Simulator action on iOS 26.0/iPhone 16 Pro, with isolated hosted storage and account autoconnect disabled. This includes 22 authentication-binding, 27 publication-policy, 49 lifecycle, 21 authentication-failure tests and the existing key-maintenance/device/bundle/registration regressions. The action built the app, push extension and test target; no clean or separate redundant build was run. The first combined action exposed fixture XML namespace inheritance and a standard-PEP fallback-timing regression; parsed-wire fixtures and managed-only primary fallback corrected both before this passing run. No production server or physical device publication result is claimed.

After integration into the original working tree, the five affected suites passed again: 126/126 tests, including the affected application build. Unfinished chat/QR changes were preserved outside this task’s commit.
