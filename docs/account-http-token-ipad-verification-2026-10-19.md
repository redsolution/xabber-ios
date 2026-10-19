# Account HTTP token flow: physical iPad verification

2026-10-19, Asia/Yekaterinburg. Change under verification: `6f635746`.

## Device and build

- iPad (Redsolution), iPad Air 11-inch M3, iOS 26.7.1.
- Cached signed `Debug` device build succeeded and was installed over existing `xabber.ios` data, including the push extension.
- Device destination: `00008122-000A60363CE9001C`. CoreDevice identifier works for installation/launch but was rejected as an Xcode build destination.
- Installed and running debug dylib UUID: `93F17C77-CD08-3781-A513-9D1BC0542AB1`.
- Build uses the current checkout, including existing unrelated local changes; only the account bootstrap commit is assessed here.

## Observed result

The account `test.omemo.igor@dxs.xabber.com` was authenticated and already had a usable token. To verify fresh issuance, the existing `requestToken(for:callback:)` method was invoked through LLDB without deleting the previous token or changing XMPP credentials.

| Stage | Actual result, local time |
| --- | --- |
| HTTP code request | `16:40:52.113771`, status `201`, waiting for confirmation |
| XMPP HTTP-auth confirmation | `16:40:53.929290`, matched pending request and account |
| IQ acknowledgement | Outgoing IQ result found with the confirmation stanza ID |
| HTTP token exchange | `16:40:54.077585`, status `201`, success |
| Keychain read-back | Returned token equals stored token; expiry is in the future |
| Previous token | New token differs from the previous stored value |
| Legacy account-create IQ | Zero occurrences in the complete captured stream |

The callback recorded only result booleans and expiry metadata. No token or confirmation code is included in this report. Raw XML capture and structured evidence are retained outside Git under `/Users/igor.boldin/Library/Logs/XabberAccountDiagnostics/2026-10-19/`.

## Scope and cleanup

This verifies real HTTP/XMPP exchange and credential persistence on the device. It does not claim a new-account cold start: the physical account already had a token, and missing-token Settings branching is covered by the simulator XCTest suite (20/20 from the implementation task).

A supplemental LLDB expression for opening Settings and taking a screenshot was interrupted with `EXC_BAD_ACCESS`; LLDB returned the process to its previous state. No screenshot/UI pass is claimed. The debugger was detached, the capture process ended, and the main app was relaunched normally at `16:42:53`, PID `1973`, without debug arguments or injected application environment.

Disposable build/control logs were removed after results were recorded. Stable Xcode caches and the outside-Git runtime evidence are retained. No production source changes were needed during device verification.
