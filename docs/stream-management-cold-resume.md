# Stream Management after relaunch

Xabber loads a protected checkpoint for the primary account before opening the connection. After TLS and SASL, the local XMPPFramework tries XEP-0198 resumption before resource binding. A valid result restores the previous server-bound full JID and existing presence; the new process still obtains a current synchronization or legacy roster response for Recents. A server rejection or expired/missing checkpoint takes the normal bind and synchronization path.

A checkpoint is written on controlled background transport closure, once the app has sent its available presence, startup is no longer blocked, the observed message/sync queues are settled, and the framework can prove the server acknowledged every outgoing stanza. It stores the resume ID, both counters, server timeout and real bound JID, scoped by account, configured route and a device-local credential epoch. It is single use once binding starts. Account removal, disable and intentional session termination clear it. Auxiliary and notification-extension streams do not participate.

This version does not journal pending wire XML. An interrupted or busy suspension without a usable checkpoint can require a normal bind. Existing delivery receipts and archive catch-up remain responsible for business-level recovery.

The CocoaPods dependency still uses the local checkout in `XABBER_DEPS_ROOT`. The required XMPPFramework revision is `2b4ecd8` (`codex/ios-sm-cold-resume`).

Verification: 164 isolated hosted tests passed on iOS 26 Simulator, including a real loopback XMPP connection proving that `<resume/>` follows SASL before bind, rejection, resource/counter restoration, transport retry, persisted checkpoint eligibility and the app's Recents boundary. The test run built the app and push extension. No physical iPhone or deployed-server acceptance was run.
