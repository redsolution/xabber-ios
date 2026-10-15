# Native OMEMO verification on a physical iPhone

Date: 2026-10-14. Status: in progress; live peer exchange is not yet verified.

## Startup and native encryption

The cached signed `Debug` device build succeeded and was explicitly installed from
`~/Library/Caches/XabberCodex/xabber-ios-core/DerivedData/Build/Products/Debug-iphoneos/xabber.app`.
The MCP default device-product lookup returned an older product, so it was not used.
The installed ARM64 debug image UUID was `26F8F46D-C07E-3DE1-86B9-9E43448B3CE0`.
Its framework graph contained no SignalProtocol or Curve25519Kit dependency.

Startup, authentication and discovery were observed on the connected iPhone after
the saved-chat Realm fix `ea3728e6`; the previously reported Realm creation crash
was not reproduced. Debugger pauses and log-capture termination are diagnostic
interventions and are not evidence of a production crash.

A RAM-only native crypto smoke inside the installed application passed signed
bundle verification, initial key exchange and SCE encryption/decryption, rejection
of modified initial messages and payloads, authenticated ACK clearing pending key
exchange, established-session SCE, rejection of a modified regular message and a
successful retry of its valid counterpart. It used temporary keys without touching
real account keys, Realm, Keychain, trust or transport.

One temporary LLDB probe stopped inside `NSUserDefaults.setObject` at a recursive
CFPreferences lock; its stack originated in the injected expression. The process
was restarted and subsequent probes wrote a dedicated temporary text file instead.
This diagnostic interruption is retained here rather than hidden in a claim that
every debugger session was uninterrupted.

## Authorized encrypted chat

The user selected Alexey Boldin and requested encrypted-chat initialization. The
unique matching contact was resolved from the device roster rather than a guessed
JID. The normal `OmemoManager.initChat(jid:)` flow created or reused its `.omemo`
conversation and requested devices. Private JIDs and message contents are omitted
from this report. No test application message has been sent.

The exact protected native SID matches the registration mirror. Its local device
row exists and is trusted. Both own and contact device-list snapshots are known,
with no pending fetch: 16 active own devices are unknown, and the contact list is
empty. The new local SID is absent from the confirmed server list. Normal sending
is therefore blocked by own-device trust and independently by absence of a trusted
contact device. No trust override or device/history deletion is part of this task.

## Server publication failure

The account and publication streams were authenticated. A normal registration
retry retained the same protected SID; a direct standard publication completed
without a Swift error. A one-shot breakpoint in the matching bundle-publication
response handler then established the actual server response:

- IQ type: error; error type: wait; code: 500.
- Condition: resource-constraint.
- Text: `Unknown field 'pubsub#max_items' of type 'http://jabber.org/protocol/pubsub#publish-options'`.

This is the same Xabber server-owned-node transport issue already fixed in the Web
client. XEP-DEVICES section 10 and the server's bundle hook assign membership
updates to the server and reject client device-list writes. The iOS fix separates
that path from standard PEP: Xabber publishes only bundle items; standard PEP keeps
its open/max forms and configuration recovery. The native crypto payload, protected
SID, matching IQ/hash acceptance proof and trust policy remain the contract.

References: knowledge inbox `2026-10-08-web-omemo-xabber-item-publication.md`,
`protocols/XEP-DEVICES.md` section 10, server `mod_devices.erl` bundle hook and
`process_packet_payload`, Web `packages/core/src/omemo/server.js` `_publish`.
The standard PEP form is specified in
[XEP-0384 section 5.3.2](https://xmpp.org/extensions/xep-0384.html#usecases-announcing-bundles).

## Transport regression verification

The new item-only publication test failed before the production change because the
wire still contained `publish-options`. After the scoped fix, 128 tests in seven
affected suites passed without failures or skips. The simulator action built the
app and notification extension. Eight new lifecycle methods cover Xabber bundle
publication, matching ACK without fabricated membership, retries after three
server errors, queued configuration fallback, direct membership writes, missing
local SID, bundle-only disable and unchanged standard PEP setup/options.

Suites: `OMEMO2BundleCacheIntegrationTests`, `OMEMO2BundleCodecTests`,
`OMEMO2ManagerLifecycleBehaviorTests`, `OMEMO2NormativeDevicesTests`,
`OMEMO2NormativeKeyMaintenanceTests`, `OMEMO2NormativeRegistrationTests`,
`OMEMO2OwnDeviceBindingTests`. Verification used the cached wrapper, isolated
hosted-test storage and disabled account autoconnect on the concrete iOS 26
simulator. An independent source review found no blocking issue.

The mode boundary uses the existing `Account.devices.isAvailable` contract, which
can also be restored from a registered device UUID. It does not introduce a new
server-detection layer. Current advertised devices support must be confirmed on
the physical connection as part of live validation.

## Remaining verification

Rebuild/install the physical app and confirm
that the server accepts the native bundle and publishes the current SID. Remove
temporary diagnostic artifacts and leave the final app running. A live encrypted
exchange still requires a compatible published contact device and normal key
verification; receipt alone is not proof of authenticated decryption.
