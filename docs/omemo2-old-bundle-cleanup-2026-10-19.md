# Old OMEMO bundle cleanup — 2026-10-19

Status: old public bundles and local key caches cleared; clean exchange awaits
the user’s republication and authoritative device-list readiness.

The user explicitly requested old-key/bundle cleanup after the failed
[two-device verification](omemo2-two-device-verification-2026-10-19.md), and said
they would republish. Operations are scoped to the same two account JIDs.

## Server bundle cleanup

Normal `deleteDeviceOrBundle(..., node: .bundle)` requests excluded the current
physical iPhone SID `201978182` and iPad SID `267862439`.

- 16 old redsolution SIDs: 14 correlated IQ results and 2 `item-not-found`
  responses (`1095114224`, `413506100`), whose items were already absent.
- 4 old xmppdev01 SIDs: all received correlated IQ results on retry through
  the normal authenticated `Account.action` path. The first four attempts ran
  during a disconnected stream and had no response; they were not counted as
  successful deletions.
- Total: **18 confirmed item removals; 2 items already absent**.

Authorization devices were not revoked. The current physical identities and
account/message history were preserved. No server code/database change or direct
client publication of a device list was performed.

## Local cleanup

On each physical app, exact owner/JID/SID filtering excluded the two current SIDs
and removed 3 old cached identity/bundle records and 300 cached public prekeys.
Matching legacy session/trusted-identity tables had zero rows to remove.

Old protected outgoing sessions were cleared with `deleteSessions(jid:deviceID:)`;
normal `replaceOMEMO2Sessions()` then prepared the current pair for a new outgoing
session/fresh-bundle flow. This preserves identity, trust and decrypted history;
the API can retain receive-only snapshots for history during explicit replacement.
It is not a secure wipe of historical private material.

Device membership projections were kept authoritative rather than filtered to
make the send gate pass. Cleanup intentionally removes key caches even while the
server continues listing the corresponding old SIDs; this does not claim those
SIDs have disappeared from membership.

Final read-back on each app confirms zero old cached identity/bundle records and
zero old public-prekey rows in this scope. Both current cached bundles pass full
native codec validation, and protected local IDs remain unchanged. All four
post-clean server GETs also return the current bundles with 32-byte public keys,
64-byte signatures and 100 32-byte prekeys each. No old-bundle republication was
observed in this capture.

## Remaining server membership

Fresh responses on both clients still list **17 redsolution SIDs and 5 xmppdev01
SIDs**, including the old entries. A bundle-retract ACK does not establish device
membership removal.

This matches the locally inspected `mod_devices.erl` behavior: bundle retraction
clears `omemo_id` only for the current authenticated device when its SID matches;
an arbitrary older SID can lose its PubSub item while remaining in auth-device
metadata. The deployed responses confirm the remaining list entries; the local
source explains the likely mechanism without proving the exact deployed revision.

## Clean-check gate

The user was asked to signal when republication is complete. Before sending new
test messages, fetch authoritative lists and validate every active trusted bundle.
Require either only the intended devices in membership or usable current bundles
for every remaining active device. An enabled old client can republish its own
bundle, so recheck immediately before sending.

Successful testing still requires fresh OMEMO wire ciphertext and authenticated
recipient plaintext in both directions, then Unicode and receiver-restart cases.
No new exchange has been claimed after cleanup. No application source changed;
the already verified signed app/NSE build remains installed.

Debuggers were detached and both apps normally relaunched (iPhone PID 2940,
iPad PID 1890). Complete raw captures are retained outside Git under
`~/Library/Logs/XabberOMEMODiagnostics/2026-10-19/`, named
`xabber-omemo-20261019-clean-*-console.log`. No build cache was removed.
