# Saved Messages Contract

Saved Messages is the iOS client surface for XEP-FAVORITES.

- Namespace and conversation type: `urn:xabber:favorites:0`.
- Conversation identity: the discovered favorites service JID, not the original author JID.
- `LastChatsStorageItem.jid` and `MessageStorageItem.opponent` for saved rows must equal the favorites service JID.
- `LastChatsStorageItem.conversationType` and `MessageStorageItem.conversationType` must be `.saved`.
- Discovery is authoritative. Saved UI rows are visible only for owners with a discovered non-empty favorites service JID matching the saved row JID.
- MAM and sync operations for saved conversations use the favorites service JID and the saved conversation type. Saved MAM must not run before service discovery.
- Forwarded saved messages preserve original author metadata in forwarded/reference/display data. The outer saved wrapper is presentation/routing metadata, not the stored conversation opponent.
- Display strips only the outer saved envelope. Direct notes authored in Saved Messages render as current-user messages.
- Re-forwarding from Saved Messages strips only the outer saved wrapper; direct saved notes forward normally.
- Saved state indicators are saved-specific: direct/self-authored saved rows can show delivered/displayed service proof, while rows originally authored by others should not show ordinary peer read markers.

The focused contract coverage currently lives in `FavoritesFeatureTests`, `ClientSynchronizationManagerTests`, `MessageArchiveRequestClassificationTests`, `LastChatsViewControllerBehaviorTests`, and search/action tests in `xabberTests.swift`.
