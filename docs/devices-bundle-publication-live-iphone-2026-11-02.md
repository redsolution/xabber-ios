# Live Devices bundle publication on cable-connected iPhone

Date: 2026-11-02. The committed client fix `1027b67e` passed live-account publication on the USB-connected iPhone 12 Pro (iOS 26.6.1). Three separate application processes authenticated and each published a retained OMEMO2 bundle successfully. No `policy-violation` was observed in the captured logs.

## Build and execution

The clean `codex/devices-bundle-policy-violation` worktree at `1027b67e0c11bdcaa30f31e408b87de7f227f368` was built using `tools/xcodebuild_cached.sh build -jobs 2`, with the concrete wired device destination. The app and push extension built successfully; no clean or cache reset was performed. The original tree's unfinished chat/QR work was excluded and preserved.

The existing `xabber.ios` application was updated in place without uninstalling or resetting its container/account. Hosted-test storage and account-autoconnect-disable flags were absent. CoreDevice reported `transportType: wired`, and the USB-only libimobiledevice listing confirmed the same phone. Other network-connected devices were not used.

OS logs hid XML as `<private>`. For the three measured launches, the process-only argument `-developer_logEnabled YES` enabled the existing file logger. It did not persist a preference or alter publication logic. After capture, the app was relaunched successfully without this argument and left running normally. Raw runtime XML was copied privately over USB and excluded from source Git.

## Matched server results

Each measured request was an IQ `set` publishing one item on `urn:xmpp:omemo:2:bundles`. Each successful reply matched the exact request ID, had `type=result`, came from the addressed own bare JID and targeted that session's full JID. Stream-management ACKs and connected-state indicators were not counted as publication success.

| Launch | Publication time (Asia/Yekaterinburg) | Matched server result | Reply latency |
| --- | --- | --- | --- |
| 1 | 16:13:58.632 | result | 581 ms |
| 2 | 16:15:40.780 | result | 225 ms |
| 3 | 16:16:55.850 | result | 145 ms |

All three publications used the same retained SID and identical public identity key (compared by hash). The deduplicated evidence includes three authentication-success events and 508 correlated wire-IQ records. Every recorded bundle publication received a matching successful result; no bundle retraction was emitted in this run. No `policy-violation` appeared in either parsed IQ errors or the complete copied runtime text.

## Evidence and scope

Private evidence is retained in the project vault at `debug/2026-11-02-devices-bundle-live-iphone`: build/launch manifests, copied runtime logs and `wire-summary-final.json`. The parser rejects wrong request IDs, wrong senders, bare rather than full recipients, error replies and absence of a publication; negative controls passed. Duplicated log snapshots were deduplicated before counting requests.

This proves ordinary retained-identity startup and repeated publication on the current live account/server. The current binding already matched; old-SID migration and sibling-collision cases remain covered by the implementation's XCTest regressions rather than by deliberate live-account disruption. No key reset, device revocation, encryption toggle, test message or server deployment was performed.

See [implementation and source-contract report](devices-bundle-publication-policy-2026-11-02.md).
