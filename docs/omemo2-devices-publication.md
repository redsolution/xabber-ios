# OMEMO2 publication bound to the authenticated Devices record

Implementation under final verification, updated 2026-11-03. Reference: web `12659fe2` (`docs/omemo2-devices-publication.md`, core runtime/server/devices-publication/devices-session), Devices §7/10 and server `c1a431d0` `mod_devices.erl`. The explicit user contract supersedes the earlier automatic-retraction migration and UUID-less HOTP publication introduced in `1027b67e`.

## Authority and wire lifecycle

Managed publication requires the exact Devices UUID accepted by pre-bind registration or mutually verified DEVICES-OCRA for the current account, stream, full JID and authentication generation. Cached UUIDs, UI metadata, UUID numeric prefixes and post-bind registration are not current-resource authority. Fresh owned Devices#items is required before each publication. The detached response must pass request, namespace, route, UUID, SID, duplicate/collision and lifetime checks. Ordinary PEP retains its separate lifecycle.

An existing server omemo-id determines the publication item ID. A previously unassigned device retains initial registration: choose an available local SID and let the server bind its first publication. Bundle-only item writes are permitted; managed membership and node configuration remain server-owned. Publication ACK is followed by a fresh own membership read; startup requires its own SID to be present. A qualified optional XEP-0059 RSM result can accompany PubSub items; its cursor/count never provides membership or identity authority. Duplicate, foreign and malformed metadata remains rejected.

## Protected state

Matching retained state keeps its ID, private identity and ratchets. Assigned server ID without local secrets requires a strict own-public-identity read before private-key generation. An existing published identity requires recovery. Used state with a different ID remains intact and fails through a controlled preparation/send error; no automatic key reset or retract remaps it.

Only explicitly unused pending registration can adopt a different assigned SID. The old SID must be absent from current authoritative membership and have no published identity; the target must be unpublished or have the same identity. Protected state must have no session/replay/control/key-use/admitted-identity/opt-out evidence; separate persisted replay and opt-out evidence is also checked. Merely fetching an untrusted public peer bundle does not use local private keys and must not block adoption. Public caches and trust decisions are preserved. A whole-state digest/incarnation plus owner-lock checks revalidate state and accepted authentication at commit; adoption changes only ID and publication-dirty metadata. Older aggregates lacking explicit pending evidence are conservatively non-adoptable. Additive optional protected metadata needs no Realm schema change. The transaction boundary is the existing in-process owner lock and atomic protected-item replacement; no cross-process Keychain CAS is claimed.

Explicit disable may withdraw only the local SID after fresh proof that this current Devices UUID owns it. Re-enable retains keys/sessions, checks own public identity and re-runs publication even for a clean bundle. A server binding established before a PubSub storage failure is retried using the same pending private identity/SID.

## Failure and diagnostics

An actual correlated policy-violation causes one fresh Devices read and blocks the same automatic publication for the accepted authentication, surviving manager resets within that authentication. A new accepted authentication can retry. No automatic retract clears a server mapping or deletes siblings. Existing timeout values and trust checks remain.

Genuine SM resume preserves the accepted authentication witness and its publication block. It still re-enters managed publication after resumed send readiness and completed initial-sync admission, since module reset revoked publication readiness. Interrupted initial sync continues through its existing release path. Publication ACK, SM delivery acknowledgement and membership confirmation are separate events.

Sensitive registration/SASL/private-key/verification payloads must be omitted at the app diagnostic boundary and both CocoaLumberjack OS/file sinks, including framework XML traces. Public bundle and unrelated stanza diagnostics remain available. No raw registration response or private secret belongs in source reports.

## Verification

Initial test-first action: 30 XCTest methods executed against unchanged production, with 62 expected assertion failures and 0 unexpected failures; app/push/test targets built. The storage test file was written before its new APIs but excluded from that baseline. Later coverage-first cases are not all claimed as separately executed RED.

The latest combined focused run passed **102/102** methods: 29 publication, 38 protected-storage, 18 authentication, 8 privacy, 5 guarded key-maintenance and 4 actual Account SM-resume cases. It includes real native cryptographic session continuity, atomic-state races and actual mutual OCRA HMAC checks; network I/O remains simulated. The SM regression was independently reproduced before its Account hook: 8 cases ran, with 3 expected failures and 0 unexpected failures.

A final public-cache regression then reproduced 2 expected failures in 1 case before the predicate change. The subsequent complete publication suite passed **30/30**, including that case. These actions successfully built the app, push extension and test targets without compiler/linker errors, using the cached Debug iOS 26.0 Simulator workflow without cleaning the cache. The 30-method run overlaps the combined focused run and is not an additional 30 distinct cases.

The final broader affected-scenario gate passed **1071/1071** methods across **72 classes**, with 0 failures and 0 skips, and successfully built the app, push extension and tests. Its preceding run exposed 5 assertions in 3 methods: standard-PEP retained receive had skipped existing due key maintenance, and expired non-policy managed IQ work incurred an extra publication backoff. Minimal production corrections preserved the existing assertions and timer values; the two affected suites first passed **52/52** before the full rerun. Final evidence: `green-affected72-final.log` and `.xcresult` in the private vault directory `debug/2026-11-02-devices-web-contract/`.

Original-tree integration verification passed **234/234** methods across **11 classes**, with 0 failures, and built the affected app/push/test targets. The focused task patch was staged separately from pre-existing chat/QR work. No clean or redundant simulator Debug build was run after the successful test actions.

No live server or physical-device success is established for this replacement implementation. The earlier three successful iPhone publications of `1027b67e` tested the superseded implementation. The newly requested phone/tablet/web acceptance is a separate task; its results must identify the tested binaries and account/transport conditions.

A live iPhone startup exposed the legal RSM-plus-items server envelope missing from the original transport fixtures. The focused regression reproduced 9 expected failures across 5 new methods before the parser fix. After explicit independent startup/publication identity checkpoints, the affected 5-suite gate passed **120/120** with the original key/session preservation and actual decrypt assertions. Physical retest of this follow-up is recorded in the separate live QA epoch.
