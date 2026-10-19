# Old OMEMO bundle cleanup — 2026-10-19

Status: old public bundles and local key caches cleared; automatic publication
rechecked after normal launches. Clean exchange remains blocked by old server
membership references and incomplete iPad authentication.

The user explicitly requested old-key/bundle cleanup after the failed
[two-device verification](omemo2-two-device-verification-2026-10-19.md). The user
then correctly clarified that the app automatically republishes at startup.
Waiting for a manual publication signal was unnecessary and is withdrawn.
Operations are scoped to the same two account JIDs.

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

The app publishes its own bundle automatically after authentication. No manual
user publication step is required. For successful clean exchange, fetch
authoritative lists and validate every active trusted bundle.
Require either only the intended devices in membership or usable current bundles
for every remaining active device. An enabled old client can republish its own
bundle, so recheck immediately before sending.

Successful testing still requires fresh OMEMO wire ciphertext and authenticated
recipient plaintext in both directions, then Unicode and receiver-restart cases.
No successful exchange has been claimed after cleanup. No application source changed;
the already verified signed app/NSE build remains installed.

Debuggers were detached and both apps normally relaunched (iPhone PID 2940,
iPad PID 1890). Complete raw captures are retained outside Git under
`~/Library/Logs/XabberOMEMODiagnostics/2026-10-19/`, named
`xabber-omemo-20261019-clean-*-console.log`. No build cache was removed.


## Automatic-publication recheck, 14:18–14:25 +05:00

Both apps were normally restarted. iPhone authenticated and automatically
published current SID `201978182`; IQ `501D7803-ADDF-4FE3-8A20-229090B16C94`
received a matching result. A later forced own-list fetch returned 17 SIDs,
including the old references. No old-bundle republication was observed; fresh old
redsolution bundle requests returned empty results.

New ordinary sender submissions:

| Direction | Message ID | Result |
| --- | --- | --- |
| iPhone → iPad | `CTL66Wx1` | `.error`, `messageErrorCode=omemo`; no matching recipient/wire message |
| iPad → iPhone | `YSShNGBI` | `.error`, `messageErrorCode=omemo`; submitted while unauthenticated, so not a live exchange |

The iPhone's final actual policy is `canSend`, with zero old cached identity
records. Missing bundles remain active server references, so cleanup of public
items has not produced an isolated current-device configuration. Do not infer a
passing fresh cryptographic handshake from local message admission.

The iPad established TLS and selected the stored-secret authentication branch,
but authentication did not complete. Repeated `GCDAsyncSocketErrorDomain` code 4
read timeouts and a code 7 remote close occurred in the authentication phase.
No SASL failure/success or iPad bundle publication was captured. Credential-use
logs show `blocked=false` before attempts and recoverable release after timeouts;
this does not prove a server fault or a transmitted SASL request. The account's
secret, validation key and authentication counter were not read out or changed.
The latest cross-account device-list and current iPad-bundle requests from iPhone
also had no matching response by capture end. The earlier post-clean 5-SID peer
list and valid iPad-bundle results above belong to the prior successful connection.

At final inspection the iPad process was stopped with SIGKILL before a metadata
expression could complete; its termination source is unknown. This is not
classified as a production app crash or an OMEMO failure. Debuggers are closed,
captures ended and both apps normally relaunched (iPhone PID 2994, iPad PID 1910).
Raw `xabber-omemo-20261019-cleancheck-*-console.log` files remain outside Git.

Read-only review of local server `3992d263` found no supported arbitrary-association
clear operation that preserves old authorization devices: existing admin methods
revoke auth devices, device-query update omits `omemo_id`, and PubSub purge/node
deletion do not clear it. A self-retract from each old device or a server-side
metadata correction is needed if those references must be removed without
revocation. Neither auth revocation nor server changes were performed here.
