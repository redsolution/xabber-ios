# Saved-chat creation crash in Realm

## Live diagnosis

On 2026-10-14, the physical application was inspected while paused in the running Xcode debugger. The open workspace was the current checkout on `codex/omemo-xabbercryptoswift`. The failing thread was an XMPP stream queue, processing the favorites service discovery response after connecting.

The stack was `Account.didReceiveIQ` → `ServerDiscoManager` favorites discovery → `XMPPFavoritesManager.configure` → `createLastChatsStorageItem` → `Realm.write` → `Realm.add` → `RLMException(std::exception const&)` → `realm::Exception::what()`. Xcode stopped with `EXC_BAD_ACCESS (code=2)` while Realm formatted the exception. Read-only LLDB inspection of the exception established its dynamic type as `realm::ObjectAlreadyExists`, with the reason:

```text
Attempting to create an object of type 'LastChatsStorageItem' with an existing primary key value '<service>_<owner>_urn:xabber:favorites:0'
```

The service/owner above are redacted. This identifies saved-chat persistence as the trigger; the inspected stack contains no crypto operation. The physical process was left paused without resuming, stopping or relaunching it.

## Cause and correction

The saved-chat existence check previously ran before opening a Realm write transaction. A background Realm could retain an older read snapshot in which the chat was absent. Another writer could commit that same chat; beginning the original writer's transaction refreshed its snapshot, then its unconditional `add` attempted to insert an existing primary key.

`createLastChatsStorageItem` now resolves the saved chat inside the write transaction using the existing `savedLastChat(in:favoritesNode:)` helper. An existing row is reused without changing its last message, roster link, unread/read/archive state, pin, draft, timestamps or scroll anchors. `commitTransaction: false` retains caller-owned transaction and rollback semantics. New rows retain the previous defaults and owner/service/conversation-type identity. No schema change or data reset is needed.

## Regression verification

The dedicated `FavoritesConcurrentCreationTests` was written before the production correction. Its stale-snapshot test holds a real background Realm on one thread, disables automatic refresh, commits a populated saved chat from another Realm, then invokes the public creation method on the stale thread. Against the original implementation, the isolated test host crashed with the same `EXC_BAD_ACCESS (code=2)`, `realm::Exception::what()` / `RLMException` / `Realm.add` / favorites-creation stack as the physical report.

Seven dedicated cases cover:

| Scenario | Required result |
| --- | --- |
| Stale read snapshot followed by another writer's commit | One row; populated history and all chat metadata preserved |
| 32 concurrent creators for one owner/service | One coherent saved chat |
| Repeated standalone creation | Existing history, read state, pin and draft retained |
| Creation/reuse inside the caller's transaction | Transaction remains open; caller's changes retained |
| Caller rolls back | No newly created row survives |
| Same service across owners and conversation types | Exact owner/type isolation |
| Missing favorites service | `notAvailable`; no row written |

The first broader run also exposed four existing `ClientSynchronizationManagerTests` failures (five assertions). Running those cases with the original favorites implementation reproduced all five failures. Their XML messages inherited the synchronization/forwarding namespace rather than specifying `jabber:client`, which the existing production parser requires. Those fixtures now explicitly declare the client namespace.

Once the saved message was accepted, its manually specified forward range also produced a truncated preview. That fixture now uses the real `ForwardSendPlanner` producer to create a coherent forwarded fallback plus the original expected own comment. It retains the original nested message identity/content, list-only assertions and exact expected preview, without changing production parsers or manually duplicating their offset calculation.

Final verification covers **206 unique affected XCTest cases across eight classes**, using the final two test actions:

- Seven classes / **167 cases passed** in the affected-suite action: favorites concurrency7, favorites feature77, discovery12, queue45, archive isolation8 and launch/isolation18. That action still failed the older saved-preview fixture in the remaining synchronization class; no production change followed it.
- After the fixture correction, the complete synchronization class was rerun narrowly: **39/39 passed**, zero failures, unexpected failures or skips; `TEST SUCCEEDED` and exit0.
- Cached `Debug` test actions used iOS26.0 Simulator `91E09D3E-4BBC-4431-9EAF-14D2410E7B98`, `TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT=1`, `TEST_RUNNER_XABBER_ISOLATED_STORAGE=1`, ad-hoc signing and disabled parallel testing. They built the affected app/test/notification-extension dependency graph. No separate Debug build or clean was needed.
- Compiler/linker output, XCTest totals/skips, Git whitespace checks and project-file lint were inspected. Disposable logs, crash diagnostics and result bundles were removed after recording evidence; Xcode cache directories were preserved.

The physical device has not run the corrected binary; its currently paused process still contains the previous implementation and needs a rebuild/relaunch to validate the real-account startup path.

## Files

- `xabber/xmpp/favorites/XMPPFavoritesManager.swift`: resolve/create saved chat atomically.
- `xabberTests/FavoritesConcurrentCreationTests.swift`: seven real Realm regression cases.
- `xabberTests/xabberTests.swift`: correct four existing synchronization fixtures.
- `xabber.xcodeproj/project.pbxproj`: register the dedicated XCTest file.
- This report: diagnosis, scenario matrix and verification evidence.
