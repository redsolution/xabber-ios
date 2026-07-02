import XCTest
import RealmSwift
@testable import xabber

final class ChatSendButtonReadinessTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private let owner = "owner@example.com"
    private let jid = "romeo@example.com"

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatSendButtonReadinessTests-\(name)-\(UUID().uuidString)"
        )
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept(Set<String>())
        AccountManager.shared.connectingUsers.accept(Set<String>())
        AccountManager.shared.authenticatedUsers.accept(Set<String>())
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    override func tearDown() {
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept(Set<String>())
        AccountManager.shared.connectingUsers.accept(Set<String>())
        AccountManager.shared.authenticatedUsers.accept(Set<String>())
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testRegularChatPendingMessageDoesNotDisableSendButton() throws {
        XCTAssertTrue(ChatSendButtonReadinessPolicy.isEnabled(
            conversationType: .regular,
            isSkeletonVisible: false,
            isAccountConnecting: false,
            hasPendingOrFailedMessage: true
        ))
    }

    func testRegularChatErrorMessageDoesNotDisableSendButton() throws {
        XCTAssertTrue(ChatSendButtonReadinessPolicy.isEnabled(
            conversationType: .regular,
            isSkeletonVisible: false,
            isAccountConnecting: false,
            hasPendingOrFailedMessage: true
        ))
    }

    func testEncryptedChatPendingMessageStillDisablesSendButton() throws {
        XCTAssertFalse(ChatSendButtonReadinessPolicy.isEnabled(
            conversationType: .omemo,
            isSkeletonVisible: false,
            isAccountConnecting: false,
            hasPendingOrFailedMessage: true,
            omemoAvailability: .canSend
        ))
    }

    func testOmemoNoTrustedContactDevicesStillBlocksSending() {
        let availability = OmemoSendAvailabilityPolicy.evaluate(
            conversationType: .omemo,
            ownDeviceStates: [.trusted],
            contactDeviceStates: [.unknown, .distrusted]
        )

        XCTAssertFalse(availability.canSend)
    }

    func testConnectingAccountStillDisablesSendButton() {
        XCTAssertFalse(ChatSendButtonReadinessPolicy.isEnabled(
            conversationType: .regular,
            isSkeletonVisible: false,
            isAccountConnecting: true,
            hasPendingOrFailedMessage: false
        ))
    }

    func testMediaPreparationBlockerStillDisablesSendButton() {
        XCTAssertFalse(ChatSendButtonReadinessPolicy.isEnabled(
            conversationType: .regular,
            isSkeletonVisible: false,
            isAccountConnecting: false,
            hasPendingOrFailedMessage: false,
            hasMediaPreparationBlocker: true
        ))
    }

    func testDisconnectedRegularMessageSendStillPersistsQueuedOptimisticRow() throws {
        let manager = MessageManager(withOwner: owner, activeStream: false)
        defer {
            manager.updateSendingMessagesTimer?.invalidate()
            manager.updateSendingMessagesTimer = nil
        }

        let originId = manager.sendSimpleMessage(
            "Hello",
            to: jid,
            forwarded: [],
            conversationType: .regular
        )

        let realm = try WRealm.safe()
        let message = try XCTUnwrap(realm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: MessageStorageItem.genPrimary(messageId: originId, owner: owner)
        ))
        XCTAssertEqual(message.state, .sending)
        XCTAssertEqual(message.body, "Hello")
        XCTAssertEqual(
            realm.objects(OutgoingMessageQueueItem.self)
                .filter("owner == %@ AND originId == %@", owner, originId)
                .count,
            1
        )
    }

}
