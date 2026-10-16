# iPad push HTTP MAM trace: HTTP authorization rejected

Date:2026-10-16. Result: real APNs ingress, shared credentials and summary decryption passed; HTTP MAM retrieval failed with401. Message XML and rich notification were not obtained. Server/app implementation unchanged during this verification. Corrected app source:d63d223d.

## Observed request

NSE PID1361, request859396DD-3992-4D34-BD33-FA0886391E2F; times below+05:00.

| Time | Stage | Evidence |
| --- | --- | --- |
|14:45:51.480–.482|APNs/NSE|extension_init, receive and raw encrypted/form siblings|
|14:45:51.491–.492|Shared credentials|loaded first attempt, AES key32bytes, exact discovered endpoint, effective expiry15:42:17|
|14:45:51.495|Decryption/dispatch|valid stanza-id1792143950985629, summary, outgoing=false|
|14:45:51.496|Archive request|GET exact discovered URL, no body, own archive so by omitted|
|14:45:51.902|HTTP response|401,text/plain,Content-Length12|
|14:45:51.904–.907|Failure propagation|unauthorized, no transient retry, used generation invalidated|
|14:45:51.922|Completion|generic Xabber/New message notification; no archive preview|

GET URL:https://xmppdev01.xabber.com:5444/iq/archive/by-id/?id=1792143950985629. NSE HTTP stage took about406ms; receive-to-complete about440ms. Header check rejected401 before reading its body; no MAM XML parsing occurred. A preceding complete event with empty request belongs to previous-request cleanup without a handler, not a second delivery of this request.

## JWT and independent HTTP check

The issued token from the installed-build bootstrap and NSE Bearer match byte-for-byte:301bytes,SHA256 d09917bf5727272f39b9296f13de9ba2252e584c88c5dbeabd9c1b31de76deb7. Claims:HS256,expected issuer/account and stable device subject,scope[urn:xmpp:mam:2],iat14:42:17,exp15:42:17. More than56minutes remained at the NSE request. Outgoing endpoints/token IQ omit to/from; endpoint, query and Bearer format agree with current KB protocols. This verifies client construction, not what any proxy delivered to its backend.

One read-only GET replay from Mac with the same URL/JWT at14:47:19 independently returned401,text/plain,body exactly `invalid_auth` (12bytes). This body belongs to the replay; the NSE cancelled at response headers and did not read it. Replay differs in transport/client implementation and is not a second iPad delivery. Raw request/response evidence remains outsideGit.

Current local server checkout3992d263 is older than the deployed endpoints/token implementation. Its validator collapses JWT errors to invalid_auth and can reject stale stored token hashes beforeexpiry; this is a hypothesis source only. It does not establish the deployed root cause. No active XMPP is required by the inspected validator or KB contract. Do not invent a route/header/token workaround or change server code. Needed next evidence is deployed HTTP IQ JWT validation/marker/cache/signature log for14:45:51 and14:47:19, correlated by device/token fingerprint.

## State after failure

Host PID1357 remains running in Debug offline mode with primary/UI connect admission blocked. App Group PushHTTPGrantInvalidations contains a1byte generation marker modified14:45, consistent with the unauthorized callback. The used grant will not be reused by the extension; another ordinary XMPP provisioning flow is needed before retrying HTTP. Do not delete that marker merely to force retries. Capture remains active.

Authoritative complete unmodified NSE file:/Users/igor.boldin/Library/Logs/XabberPushDiagnostics/2026-10-16/device-files/push-1361-91CE2CCA-3CE7-441E-A984-D47158A91D70.log. Aggregate and system/provisioning console files are in the same directory; HTTP replay response metadata/body are http-mam-replay-response.json/.bin. No rawJWT/AES/privatebody committed. This was read-only runtime verification, so no new build/tests were needed; prior72test and signed install evidence is in push-relay-namespace-ipad-2026-10-16.md.
