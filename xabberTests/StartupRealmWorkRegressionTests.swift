import RealmSwift
import XCTest
import XMPPFramework
@testable import xabber

final class StartupRealmWorkRegressionTests: XCTestCase {
    private let owner = "startup@example.test"
    private let otherOwner = "other@example.test"
    private var previousConfiguration: Realm.Configuration!
    private var realm: Realm!

    override func setUpWithError() throws {
        previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "startup-work-\(UUID())")
        realm = try WRealm.safe()
    }

    override func tearDownWithError() throws {
        realm = nil
        Realm.Configuration.defaultConfiguration = previousConfiguration
    }

    func testDeviceStartupKeepsCachedIdentityWithoutWritingCleanResources() throws {
        let account = AccountStorageItem()
        account.jid = owner
        account.deviceUuid = "cached-device"
        let device = makeDevice(owner: owner, resource: nil)
        try realm.write {
            realm.add(account)
            realm.add(device)
        }
        var commits = 0
        let token = realm.observe { event, _ in if event == .didChange { commits += 1 } }
        defer { token.invalidate() }

        let manager = XMPPDeviceManager(withOwner: owner)

        XCTAssertEqual(manager.deviceId, account.deviceUuid)
        XCTAssertTrue(manager.isAvailable)
        XCTAssertEqual(commits, 0)
    }

    func testDeviceStartupClearsOnlyTheOwningAccountsStaleResources() throws {
        let stale = makeDevice(owner: owner, resource: "old-session")
        let unrelated = makeDevice(owner: otherOwner, resource: "other-session")
        try realm.write { realm.add([stale, unrelated]) }

        _ = XMPPDeviceManager(withOwner: owner)

        XCTAssertNil(stale.resource)
        XCTAssertEqual(unrelated.resource, "other-session")
    }

    func testSoftChatResetKeepsPrereadFlagWithoutWritingCleanRows() throws {
        let chat = makeChat(owner: owner)
        chat.isPrereaded = true
        try realm.write { realm.add(chat) }
        var commits = 0
        let token = realm.observe { event, _ in if event == .didChange { commits += 1 } }
        defer { token.invalidate() }

        LastChats(withOwner: owner).resetSyncedStatus()
        drainChatReset()

        XCTAssertTrue(chat.isPrereaded)
        XCTAssertEqual(commits, 0)
    }

    func testHardChatResetClearsAllSessionFlagsForItsOwnerOnly() throws {
        let chat = makeChat(owner: owner)
        chat.isPrereaded = true
        chat.isHistoryGapFixedForSession = true
        chat.chatState = .typing
        let unrelated = makeChat(owner: otherOwner)
        unrelated.isPrereaded = true
        unrelated.isHistoryGapFixedForSession = true
        unrelated.chatState = .typing
        try realm.write { realm.add([chat, unrelated]) }

        LastChats(withOwner: owner).resetSyncedStatus(hard: true)
        drainChatReset()

        XCTAssertFalse(chat.isPrereaded)
        XCTAssertFalse(chat.isHistoryGapFixedForSession)
        XCTAssertEqual(chat.chatState, .none)
        XCTAssertTrue(unrelated.isPrereaded)
        XCTAssertTrue(unrelated.isHistoryGapFixedForSession)
        XCTAssertEqual(unrelated.chatState, .typing)
    }

    func testRecoveredOrUnrecoverableOutgoingRowsDoNotCommitAnotherTransaction() throws {
        try storeSendingMessage(id: "recoverable", withStanza: true)
        try storeSendingMessage(id: "missing-stanza", withStanza: false)
        AccountSendCoordinator.restoreRecoverableRegularMessages(owner: owner)
        XCTAssertEqual(realm.objects(OutgoingMessageQueueItem.self).map(\.originId), ["recoverable"])
        var commits = 0
        let token = realm.observe { event, _ in if event == .didChange { commits += 1 } }
        defer { token.invalidate() }

        AccountSendCoordinator.restoreRecoverableRegularMessages(owner: owner)

        XCTAssertEqual(commits, 0)
        XCTAssertEqual(realm.objects(OutgoingMessageQueueItem.self).map(\.originId), ["recoverable"])
    }

    func testReadinessStillRecoversMessagesThatAppearedAfterInitialRecovery() throws {
        AccountSendCoordinator.restoreRecoverableRegularMessages(owner: owner)
        try storeSendingMessage(id: "later", withStanza: true)
        var sentIDs: [String] = []
        let coordinator = AccountSendCoordinator(environment: .init(
            owner: owner, isSendReady: { true }, allowsMessage: { _ in true },
            decorateMessage: { message, _, _ in message },
            sendMessage: { if let id = $0.elementID { sentIDs.append(id) } },
            log: { _, _ in }
        ))

        coordinator.accountDidBecomeSendReady()

        XCTAssertEqual(sentIDs, ["later"])
        XCTAssertEqual(realm.objects(OutgoingMessageQueueItem.self).map(\.originId), ["later"])
    }

    private func makeDevice(owner: String, resource: String?) -> DeviceStorageItem {
        let item = DeviceStorageItem()
        item.owner = owner
        item.uid = "cached-device"
        item.primary = DeviceStorageItem.genPrimary(uid: item.uid, owner: owner)
        item.resource = resource
        return item
    }

    private func makeChat(owner: String) -> LastChatsStorageItem {
        let chat = LastChatsStorageItem()
        chat.jid = "peer@example.test"
        chat.conversationType = .regular
        chat.setPrimary(withOwner: owner)
        return chat
    }

    private func storeSendingMessage(id: String, withStanza: Bool) throws {
        let message = MessageStorageItem()
        message.owner = owner
        message.opponent = "peer@example.test"
        message.primary = MessageStorageItem.genPrimary(messageId: id, owner: owner)
        message.messageId = id
        message.outgoing = true
        message.conversationType = .regular
        message.displayAs = .text
        message.state = .sending
        try realm.write {
            realm.add(message)
            if withStanza {
                let stanza = MessageStanzaStorageItem()
                stanza.set(id, for: owner,
                           with: "<message type='chat' to='peer@example.test' id='\(id)'><body>Test</body></message>",
                           at: message.date, primary: message.primary)
                realm.add(stanza)
            }
        }
    }

    private func drainChatReset() {
        let scheduled = expectation(description: "main-runloop reset block has run")
        RunLoop.main.perform { scheduled.fulfill() }
        wait(for: [scheduled], timeout: 2)
        let deadline = Date().addingTimeInterval(2)
        while realm.isPerformingAsynchronousWriteOperations && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(realm.isPerformingAsynchronousWriteOperations)
    }
}
