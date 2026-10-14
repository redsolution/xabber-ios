import Foundation
import RealmSwift
import XCTest
@testable import xabber

/// Uses real Realm snapshots and write locks without accounts or network streams.
final class FavoritesConcurrentCreationTests: XCTestCase {
    private final class Errors {
        private let lock = NSLock()
        private var stored: [String] = []

        func append(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            stored.append(String(describing: error))
        }

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private var originalConfiguration: Realm.Configuration?
    private var realmKeeper: Realm?
    private let owner = "favorites-concurrency-owner@example.test"
    private let service = "saved.example.test"

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment),
            "Favorites concurrency tests require isolated storage and disabled account autoconnect"
        )
        originalConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(
            inMemoryIdentifier: "favorites-concurrency-\(UUID().uuidString)"
        )
        realmKeeper = try WRealm.safe()
    }

    override func tearDownWithError() throws {
        if let originalConfiguration {
            realmKeeper = nil
            Realm.Configuration.defaultConfiguration = originalConfiguration
            self.originalConfiguration = nil
        }
        try super.tearDownWithError()
    }

    func testStaleRealmSnapshotCreationPreservesConcurrentSavedRow() throws {
        let primary = savedPrimary(owner: owner)
        let snapshotOpened = expectation(description: "Worker owns a read snapshot without the saved chat")
        let workerFinished = expectation(description: "Saved chat creation finishes on the original Realm thread")
        let writerCommitted = DispatchSemaphore(value: 0)
        let errors = Errors()
        let worker = DispatchQueue(label: "test.favorites.stale-snapshot")
        let owner = self.owner
        let service = self.service

        worker.async {
            autoreleasepool {
                defer { workerFinished.fulfill() }
                do {
                    // Keep this Realm and the entire operation in one async
                    // block: a dispatch queue may use a different thread for
                    // separate blocks, which would hide the stale-snapshot bug.
                    let realm = try WRealm.safe()
                    realm.autorefresh = false
                    let manager = XMPPFavoritesManager(withOwner: owner)
                    manager.node = service
                    XCTAssertNil(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary))
                    snapshotOpened.fulfill()
                    guard writerCommitted.wait(timeout: .now() + 5) == .success else {
                        XCTFail("The second Realm did not commit its saved chat")
                        return
                    }
                    XCTAssertNil(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary))
                    let cachedRealm = try WRealm.safe()
                    XCTAssertNil(cachedRealm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary),
                        "The public entry point must encounter the deliberately stale thread-cached Realm")

                    try manager.createLastChatsStorageItem()

                    XCTAssertEqual(realm.objects(LastChatsStorageItem.self).count, 1)
                    let existing = try XCTUnwrap(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary))
                    self.assertPopulatedChat(existing, owner: owner)
                } catch {
                    errors.append(error)
                }
            }
        }

        defer { writerCommitted.signal() }
        wait(for: [snapshotOpened], timeout: 2)
        try populateSavedChat(in: XCTUnwrap(realmKeeper), owner: owner)
        writerCommitted.signal()
        wait(for: [workerFinished], timeout: 7)
        XCTAssertTrue(errors.values.isEmpty, errors.values.joined(separator: "\n"))
        let realm = try XCTUnwrap(realmKeeper)
        realm.refresh()
        XCTAssertEqual(realm.objects(LastChatsStorageItem.self).count, 1)
        assertPopulatedChat(try XCTUnwrap(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary)), owner: owner)
    }

    func testConcurrentSameOwnerCreatorsProduceOneSavedChat() throws {
        let finished = expectation(description: "Every concurrent creator finishes")
        let errors = Errors()
        let owner = self.owner
        let service = self.service

        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: 32) { _ in
                autoreleasepool {
                    do {
                        let manager = XMPPFavoritesManager(withOwner: owner)
                        manager.node = service
                        try manager.createLastChatsStorageItem()
                    } catch {
                        errors.append(error)
                    }
                }
            }
            finished.fulfill()
        }

        wait(for: [finished], timeout: 10)
        XCTAssertTrue(errors.values.isEmpty, errors.values.joined(separator: "\n"))
        let realm = try XCTUnwrap(realmKeeper)
        realm.refresh()
        XCTAssertEqual(realm.objects(LastChatsStorageItem.self).count, 1)
        let chat = try XCTUnwrap(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: savedPrimary(owner: owner)))
        XCTAssertEqual(chat.owner, owner)
        XCTAssertEqual(chat.jid, service)
        XCTAssertEqual(chat.conversationType, .saved)
        XCTAssertFalse(chat.isSynced)
    }

    func testRepeatedStandaloneCreationRetainsSavedHistoryReadStatePinAndDraft() throws {
        let realm = try XCTUnwrap(realmKeeper)
        try populateSavedChat(in: realm, owner: owner)
        let manager = favorites(owner: owner)

        try manager.createLastChatsStorageItem()
        try manager.createLastChatsStorageItem()

        XCTAssertEqual(realm.objects(LastChatsStorageItem.self).count, 1)
        assertPopulatedChat(try XCTUnwrap(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: savedPrimary(owner: owner))), owner: owner)
    }

    func testCallerOwnedWriteCreatesAndReusesChatWithoutCommittingOrResettingIt() throws {
        let realm = try XCTUnwrap(realmKeeper)
        let manager = favorites(owner: owner)
        let primary = savedPrimary(owner: owner)

        try realm.write {
            try manager.createLastChatsStorageItem(commitTransaction: false)
            XCTAssertTrue(realm.isInWriteTransaction)
            let chat = try XCTUnwrap(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary))
            chat.draftMessage = "Keep the caller's draft"
            chat.unread = 9
            chat.isPinned = true
            chat.pinnedPosition = 4

            try manager.createLastChatsStorageItem(commitTransaction: false)

            XCTAssertTrue(realm.isInWriteTransaction)
            XCTAssertEqual(chat.draftMessage, "Keep the caller's draft")
            XCTAssertEqual(chat.unread, 9)
            XCTAssertTrue(chat.isPinned)
            XCTAssertEqual(chat.pinnedPosition, 4)
        }

        XCTAssertFalse(realm.isInWriteTransaction)
        XCTAssertEqual(realm.objects(LastChatsStorageItem.self).count, 1)
        let chat = try XCTUnwrap(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary))
        XCTAssertEqual(chat.draftMessage, "Keep the caller's draft")
        XCTAssertEqual(chat.unread, 9)
        XCTAssertTrue(chat.isPinned)
        XCTAssertEqual(chat.pinnedPosition, 4)
    }

    func testCallerOwnedTransactionCanRollBackSavedChatCreation() throws {
        let realm = try XCTUnwrap(realmKeeper)
        let manager = favorites(owner: owner)
        try realm.beginWrite()
        defer { if realm.isInWriteTransaction { realm.cancelWrite() } }

        try manager.createLastChatsStorageItem(commitTransaction: false)

        XCTAssertTrue(realm.isInWriteTransaction)
        XCTAssertNotNil(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: savedPrimary(owner: owner)))
        realm.cancelWrite()
        XCTAssertNil(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: savedPrimary(owner: owner)))
        XCTAssertEqual(realm.objects(LastChatsStorageItem.self).count, 0)
    }

    func testSameServiceIsScopedByOwnerAndConversationType() throws {
        let realm = try XCTUnwrap(realmKeeper)
        let otherOwner = "other-favorites-owner@example.test"
        try populateSavedChat(in: realm, owner: owner)
        let regular = LastChatsStorageItem()
        regular.owner = owner
        regular.jid = service
        regular.conversationType = .regular
        regular.primary = LastChatsStorageItem.genPrimary(jid: service, owner: owner, conversationType: .regular)
        regular.draftMessage = "Regular conversation"
        try realm.write { realm.add(regular) }

        try favorites(owner: owner).createLastChatsStorageItem()
        try favorites(owner: otherOwner).createLastChatsStorageItem()
        try favorites(owner: otherOwner).createLastChatsStorageItem()

        XCTAssertEqual(realm.objects(LastChatsStorageItem.self).count, 3)
        assertPopulatedChat(try XCTUnwrap(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: savedPrimary(owner: owner))), owner: owner)
        let other = try XCTUnwrap(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: savedPrimary(owner: otherOwner)))
        XCTAssertEqual(other.owner, otherOwner)
        XCTAssertEqual(other.jid, service)
        XCTAssertEqual(other.conversationType, .saved)
        XCTAssertFalse(other.isSynced)
        XCTAssertNil(other.lastMessage)
        XCTAssertNil(other.draftMessage)
        XCTAssertEqual(regular.draftMessage, "Regular conversation")
        XCTAssertEqual(regular.conversationType, .regular)
    }

    func testMissingFavoritesServiceRejectsCreationWithoutWritingRows() throws {
        let manager = XMPPFavoritesManager(withOwner: owner)

        XCTAssertThrowsError(try manager.createLastChatsStorageItem()) { error in
            guard case XMPPFavoritesManager.ManagerErrorType.notAvailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try XCTUnwrap(realmKeeper).objects(LastChatsStorageItem.self).count, 0)
    }

    private func favorites(owner: String) -> XMPPFavoritesManager {
        let manager = XMPPFavoritesManager(withOwner: owner)
        manager.node = service
        return manager
    }

    private func savedPrimary(owner: String) -> String {
        LastChatsStorageItem.genPrimary(jid: service, owner: owner, conversationType: .saved)
    }

    private func populateSavedChat(in realm: Realm, owner: String) throws {
        let roster = RosterStorageItem()
        roster.owner = owner
        roster.jid = service
        roster.primary = RosterStorageItem.genPrimary(jid: service, owner: owner)
        roster.username = "Saved messages retained"
        let message = MessageStorageItem()
        message.owner = owner
        message.opponent = service
        message.conversationType = .saved
        message.messageId = "retained-saved-message"
        message.primary = MessageStorageItem.genPrimary(messageId: message.messageId, owner: owner)
        message.archivedId = "retained-archive-id"
        message.body = "Saved content must survive discovery"
        message.date = Date(timeIntervalSince1970: 141)
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = service
        chat.conversationType = .saved
        chat.primary = savedPrimary(owner: owner)
        chat.rosterItem = roster
        chat.lastMessage = message
        chat.lastMessageId = message.messageId
        chat.messageDate = message.date
        chat.lastReadMessageDate = Date(timeIntervalSince1970: 140)
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        chat.isHistoryGapFixedForSession = true
        chat.isArchived = true
        chat.fullArchiveLoaded = true
        chat.retractVersion = "retained-retract-version"
        chat.mentionId = "retained-mention"
        chat.lastReadId = "retained-last-read"
        chat.displayedId = "retained-displayed"
        chat.deliveredId = "retained-delivered"
        chat.lastLoadedMessageHistoryId = "retained-history-id"
        chat.syncUnreadCount = 12
        chat.runtimeUnreadCount = 5
        chat.unread = 17
        chat.syncUnreadAfterId = "retained-unread-after"
        chat.syncSnapshotLastArchiveId = "retained-snapshot-id"
        chat.isPrereaded = true
        chat.isPinned = true
        chat.pinnedPosition = 3.25
        chat.draftMessage = "Draft must survive discovery"
        chat.isAllHistoryLoaded = true
        chat.lastVisibleMessagePrimary = message.primary
        chat.lastVisibleMessageArchivedId = message.archivedId
        chat.lastVisibleMessageId = message.messageId
        chat.lastVisibleMessageDate = message.date
        chat.lastVisiblePositionSavedAtLastMessageId = message.messageId
        chat.lastVisiblePositionSavedAtSnapshotLastArchiveId = "retained-position-snapshot"
        chat.lastVisiblePositionUpdatedAt = Date(timeIntervalSince1970: 150)
        chat.updateTS = 123456
        try realm.write { realm.add(chat) }
    }

    private func assertPopulatedChat(
        _ chat: LastChatsStorageItem,
        owner: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(chat.primary, savedPrimary(owner: owner), file: file, line: line)
        XCTAssertEqual(chat.owner, owner, file: file, line: line)
        XCTAssertEqual(chat.jid, service, file: file, line: line)
        XCTAssertEqual(chat.conversationType, .saved, file: file, line: line)
        XCTAssertEqual(chat.rosterItem?.primary, RosterStorageItem.genPrimary(jid: service, owner: owner), file: file, line: line)
        XCTAssertEqual(chat.rosterItem?.username, "Saved messages retained", file: file, line: line)
        let messagePrimary = MessageStorageItem.genPrimary(messageId: "retained-saved-message", owner: owner)
        XCTAssertEqual(chat.lastMessage?.primary, messagePrimary, file: file, line: line)
        XCTAssertEqual(chat.lastMessage?.owner, owner, file: file, line: line)
        XCTAssertEqual(chat.lastMessage?.opponent, service, file: file, line: line)
        XCTAssertEqual(chat.lastMessage?.body, "Saved content must survive discovery", file: file, line: line)
        XCTAssertEqual(chat.lastMessage?.archivedId, "retained-archive-id", file: file, line: line)
        XCTAssertEqual(chat.lastMessageId, "retained-saved-message", file: file, line: line)
        XCTAssertEqual(chat.messageDate, Date(timeIntervalSince1970: 141), file: file, line: line)
        XCTAssertEqual(chat.lastReadMessageDate, Date(timeIntervalSince1970: 140), file: file, line: line)
        XCTAssertTrue(chat.isSynced, file: file, line: line)
        XCTAssertTrue(chat.isInitialArchiveLoaded, file: file, line: line)
        XCTAssertTrue(chat.isHistoryGapFixedForSession, file: file, line: line)
        XCTAssertTrue(chat.isArchived, file: file, line: line)
        XCTAssertTrue(chat.fullArchiveLoaded, file: file, line: line)
        XCTAssertEqual(chat.retractVersion, "retained-retract-version", file: file, line: line)
        XCTAssertEqual(chat.mentionId, "retained-mention", file: file, line: line)
        XCTAssertEqual(chat.lastReadId, "retained-last-read", file: file, line: line)
        XCTAssertEqual(chat.displayedId, "retained-displayed", file: file, line: line)
        XCTAssertEqual(chat.deliveredId, "retained-delivered", file: file, line: line)
        XCTAssertEqual(chat.lastLoadedMessageHistoryId, "retained-history-id", file: file, line: line)
        XCTAssertEqual(chat.syncUnreadCount, 12, file: file, line: line)
        XCTAssertEqual(chat.runtimeUnreadCount, 5, file: file, line: line)
        XCTAssertEqual(chat.unread, 17, file: file, line: line)
        XCTAssertEqual(chat.syncUnreadAfterId, "retained-unread-after", file: file, line: line)
        XCTAssertEqual(chat.syncSnapshotLastArchiveId, "retained-snapshot-id", file: file, line: line)
        XCTAssertTrue(chat.isPrereaded, file: file, line: line)
        XCTAssertTrue(chat.isPinned, file: file, line: line)
        XCTAssertEqual(chat.pinnedPosition, 3.25, file: file, line: line)
        XCTAssertEqual(chat.draftMessage, "Draft must survive discovery", file: file, line: line)
        XCTAssertTrue(chat.isAllHistoryLoaded, file: file, line: line)
        XCTAssertEqual(chat.lastVisibleMessagePrimary, messagePrimary, file: file, line: line)
        XCTAssertEqual(chat.lastVisibleMessageArchivedId, "retained-archive-id", file: file, line: line)
        XCTAssertEqual(chat.lastVisibleMessageId, "retained-saved-message", file: file, line: line)
        XCTAssertEqual(chat.lastVisibleMessageDate, Date(timeIntervalSince1970: 141), file: file, line: line)
        XCTAssertEqual(chat.lastVisiblePositionSavedAtLastMessageId, "retained-saved-message", file: file, line: line)
        XCTAssertEqual(chat.lastVisiblePositionSavedAtSnapshotLastArchiveId, "retained-position-snapshot", file: file, line: line)
        XCTAssertEqual(chat.lastVisiblePositionUpdatedAt, Date(timeIntervalSince1970: 150), file: file, line: line)
        XCTAssertEqual(chat.updateTS, 123456, file: file, line: line)
    }
}
