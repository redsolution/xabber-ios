# Stream Management after relaunch

Xabber loads a protected checkpoint for the primary account before opening the connection. After TLS and SASL, the local XMPPFramework tries XEP-0198 resumption before resource binding. A valid result restores the previous server-bound full JID and existing presence, and the app prepares its local modules without requesting a startup sync. A server rejection or an expired or missing checkpoint takes the normal bind and synchronization path.

On a cold launch, Chats and Unread show the skeleton from the first frame while any enabled launch account is awaiting readiness. An accepted cold checkpoint releases that account immediately. A fresh bind waits for the first correlated server sync page to be applied, including an empty page. A server without XEP-SYNC uses the matched successful initial roster result. Request failure or cancellation leaves the account awaiting readiness. An in-process resume can continue an interrupted fallback sync, which still requires its first page.

On iPad, a five-second presentation deadline retires the skeleton and lets Recents display the saved list while the connection continues its retries. An active sync page can defer list publication until it commits or is cancelled. The first background transition also retires the launch skeleton for the rest of the process, including for a recreated Recents controller.

A checkpoint is written on controlled background transport closure, once the app has sent its available presence, startup is no longer blocked, the observed message/sync queues are settled, and the framework can prove the server acknowledged every outgoing stanza. It stores the resume ID, both counters, server timeout and real bound JID, scoped by account, configured route and a device-local credential epoch. It is single use once binding starts. Account removal, disable and intentional session termination clear it. Auxiliary and notification-extension streams do not participate.

The client retains stored contact presence while the primary stream is connecting and after an accepted resume. A fresh authenticated session clears that account's stale presence resources before processing new presence. A network failure before the resume decision leaves the saved resources in place. Contacts and Recents read statuses from the stored resources.

This version does not journal pending wire XML. An interrupted or busy suspension without a usable checkpoint can require a normal bind. Existing delivery receipts and archive catch-up remain responsible for business-level recovery.

The CocoaPods dependency still uses the local checkout in `XABBER_DEPS_ROOT`. The required XMPPFramework revision is `2b4ecd8` (`codex/ios-sm-cold-resume`).

The original checkpoint work passed 164 isolated hosted tests on iOS 26 Simulator, including loopback XMPP coverage for resumption before bind, rejection, resource and counter restoration, retries, and checkpoint eligibility.

The updated Recents behavior passed 158 isolated hosted tests on iOS 26 Simulator. The run built the app and push extension and covered the first frame, successful cold resume without startup sync, fallback first-page commit, and foreground return during an active sync page. The updated presentation was not checked on a physical iPhone or against a deployed server.
