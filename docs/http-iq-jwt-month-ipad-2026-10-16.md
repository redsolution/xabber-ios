# Month-long HTTP IQ JWT verified on iPad

Date: 2026-10-16. Times are Asia/Yekaterinburg (+05:00). Source build: `cc97c708`.

The signed Debug app and push extension were built with the shared Xcode cache and installed over existing iPad data. The app was started as a fresh normal process in persisted summary mode, issued a new JWT and saved it with `readback=matched ready=true`. The final app process was then restored to the diagnostic offline flag and left in the background with both XMPP streams disconnected. Full host console and push extension App Group mirroring remain active. Server code was not changed.

## Actual server lifetime

Token IQ `0178BF64-9879-4F10-89BE-BA066197430D` omitted `to`/`from`, requested scope `urn:xmpp:mam:2` and TTL `2592000`. The correlated server result returned the same effective TTL and `<expires>2026-11-15T12:44:38Z</expires>`.

- JWT `iat`: `1792154678` — 16 October 2026, 17:44:38.
- JWT `exp`: `1794746678` — 15 November 2026, 17:44:38.
- Actual lifetime: **2,592,000 seconds, exactly 30 days**.
- New token SHA256: `e5d422bda63a7482f4d9dab6b5d56809077a73d2c7f83168f150091e22737f6c`; distinct from the previous hour-long grant.
- `token_received` at 17:44:45.564459; shared publication/readback at 17:44:45.569923.

## Transient HTTP authorization discrepancy

Read-only controls used the same discovered endpoint, archive ID, method, non-Authorization headers and empty body. Only the Bearer token differed.

| Time | Token | HTTP result |
| --- | --- | --- |
| 17:45:36 / 17:46:42 | New month JWT | 401 `invalid_auth` |
| 17:46:01 / 17:46:43 | Previous hour JWT, still unexpired | 200 |
| 17:47:05 | Previous hour JWT expired | No request |
| 17:47:18.324115 | Same unchanged month JWT | 200, 1694 bytes |

No token was reissued and no app, credential or server changes occurred between these controls. The month-long JWT is accepted by HTTP MAM. The timing strongly suggests stale server authorization cache state retained until the old token expired. This matches the read-only local `mod_http_iq.erl` cache algorithm, but deployed cache state was not inspected, so the exact mechanism remains an inference. This new evidence narrows the authorization issue without proving the precise cause of the earlier 14:45 failure.

## Final device and evidence

Online bootstrap PID 1440; final offline host PID 1442. Foreground and background diagnostics confirm primary disconnected and UI stream disconnected, with the primary restore connection blocked. App dylib UUID `C2A8F511-87CA-35D3-8B1D-EAE70BCC1119`; unchanged NSE dylib UUID `0BA49E4E-36E0-3890-9BC4-0055DBEF0A3F`. Signed build/install succeeded. The implementation task already passed 26/26 simulator provisioning tests; no unchanged tests were rerun for this device-only verification.

Complete private raw evidence is outside Git under `/Users/igor.boldin/Library/Logs/XabberPushDiagnostics/2026-10-16/jwt-month-ipad/`: `online-console.log`, `offline-console.log`, `fresh-grant.json`, full HTTP control request/response files and `verification-summary.md`. Issued JWTs and personal payloads are not committed. Only the disposable build log was removed after extracting verification; Xcode caches and runtime logs were retained. The App Group mirror PID 45853 remains active.

No actual new push was requested in this token-lifetime round. The previous actual summary push remains separately verified; the current month JWT has been checked with the HTTP control endpoint.
