# HTTP MAM server response compatibility on iPad

Date: 2026-10-16. Status: implemented and verified with an actual summary push on iPad. The user confirmed the correct text and avatar in the notification.

## Authorization result

The app was returned to summary through the actual notification settings. A new MAM-scoped JWT was issued and read back exactly. The same GET, headers, JWT and archive ID returned HTTP 200 while XMPP was online and after both streams disconnected. Both real summary pushes also returned 200 with that issued JWT.

The earlier 401 is not reproduced. The user confirmed a server change or restart between attempts. The exact earlier validator failure is unobserved; these results do not establish whether code, signing keys, cache or stored token state caused it. No server change was made by the agent, and no client authorization workaround was introduced.

## Client response compatibility

The deployed server returns `Content-Type: text/xml; charset=utf-8` and concatenates a MAM result `message` with its final result `iq/fin`. The reviewed KB XEP-HTTPIQ and XEP-HTTPIQ-MAM describe `application/xml` and one XML root. Before this change, the client rejected the real response at MIME headers and would also reject the two-root body. The user's instruction treats the server as authoritative and forbids server changes.

The shared HTTP archive client now accepts `application/xml` and `text/xml` through the same bounded decoder. It retains the canonical single-document message/error path and additionally accepts the validated two-stanza server response:

- A message followed by a result IQ, with matching full senders and recipients and the selected archive owner.
- The expected archive result ID and matching result query ID, IQ ID and final query ID.
- A final `complete=true|1` and one RSM set whose first/last match the requested ID; optional count must be 1.

Malformed or unrelated sequences, extra stanzas, metadata junk, comments or processing instructions outside message content, DTD/entity declarations, incorrect namespaces/owner/correlation and missing completion are rejected. The existing forwarded-message and OMEMO parsers remain in use. Requests, JWTs, endpoint discovery, scopes, credentials and raw logging are unchanged.

## Verification

- Physical settings test: 1/1 passed; summary selected. Temporary XCUITest source restored byte-for-byte.
- Before implementation: 51 HTTP archive tests exposed two expected valid-pair failures. A separate `text/xml` transport test also failed before implementation.
- Final simulator regressions: 120/120 passed — HTTP archive 55, rich content 26, full payload 38, pipeline integration 1. This action built the app and notification service extension.
- Signed iPad app/extension build and installation passed. The fresh JWT was preserved across installation; both host XMPP streams stayed disconnected under the diagnostic offline launch flag.
- Actual NSE PID 1434, request `51FFEE92-4CCE-4F57-92B3-03E84EAD3C24`, 17:01:20.000–17:01:21.797 +05:00: summary → GET archive ID `1792152079257542` → HTTP 200, `text/xml`, 1689 bytes → correlated pair decoded → message text `6` → saved original avatar URL downloaded → intent donation → completion with `neutralized=false`. Total 1797 ms. JWT fingerprint matched the issued grant.
- The user confirmed that text `6` and the avatar were displayed correctly.

Complete runtime evidence remains outside Git under `/Users/igor.boldin/Library/Logs/XabberPushDiagnostics/2026-10-16/`. The successful source log is `device-files/push-1434-AD05E66B-0FFF-40F5-AC49-653D12A192DA.log`; the prior MIME rejection is `device-files/push-1424-2E8C911C-B6CA-4B7A-B4EF-AF19EFDDF809.log`. Full host console, HTTP control requests/responses and grant evidence remain in `summary-1644/`. Issued tokens and complete private payloads are not committed.
