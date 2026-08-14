import XCTest

final class GroupAccountLegacyRoutingHardCutTests: XCTestCase {
    func testAccountOwnsCanonicalGroupRuntimeWithoutLegacyManager() throws {
        let source = try productionSource("models/account/Account.swift")

        XCTAssertTrue(source.contains("let groupchatService: GroupchatService"))
        XCTAssertTrue(source.contains("lazy var groupEventProcessor = GroupEventProcessor"))
        XCTAssertFalse(source.contains("var groupchats: GroupchatManager"))
        XCTAssertFalse(source.contains("GroupchatManager(withOwner:"))
        XCTAssertFalse(source.contains("self.groupchats"))
    }

    func testCanonicalGroupIngressHasNoLegacyAccountRouting() throws {
        let scopedFiles = [
            "models/account/delegates/AccountStreamDelegate.swift",
            "xmpp/messages/messages_manager/MessageManager+CommonReceiver.swift",
            "xmpp/messages/messages_manager/MessageManager+TemporaryReceiver.swift",
            "xmpp/messages/messages_manager/MessageManager+ChatUpdater.swift",
            "xmpp/XEP-0CCC/ClientSynchronizationManager.swift",
            "xmpp/block/BlockManager.swift"
        ]
        let forbidden = [
            ".groupchats",
            "GroupchatManager",
            "GroupchatInvitePersistenceService",
            "GroupchatInviteV3Parser"
        ]
        var violations: [String] = []

        for relativePath in scopedFiles {
            let source = try productionSource(relativePath)
            for token in forbidden where source.contains(token) {
                violations.append("\(relativePath): \(token)")
            }
        }

        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
    }

    func testAccountDeletionDoesNotCallLegacyGroupchatStorageCleanup() throws {
        let source = try productionSource("common/account_manager/AccountManager.swift")

        XCTAssertFalse(source.contains("GroupchatManager.remove"))
    }

    func testStreamRoutesCanonicalGroupStanzasThroughTypedBoundary() throws {
        let source = try productionSource("models/account/delegates/AccountStreamDelegate.swift")

        XCTAssertTrue(source.contains("groupchatService.receive(iq)"))
        XCTAssertTrue(source.contains("routeCanonicalGroupPresence(presence)"))
        XCTAssertTrue(source.contains("routeCanonicalGroupMessage(message)"))
    }

    func testAuxiliaryStreamsHaveNoLegacyGroupManagerRouting() throws {
        let scopedFiles = [
            "common/XMPPUIActionManager/XMPPUIActionManager.swift",
            "common/XMPPUIActionManager/XMPPUIActionManager+Delegate.swift",
            "common/XMPPBackgroundTask/XMPPBackgroundTask+Delegate.swift",
            "xmpp/presence/PresenceManager.swift"
        ]
        let forbidden = [
            "GroupchatManager",
            "GroupchatInvitePersistenceService",
            "self.groupchat",
            "session.groupchat",
            "user.groupchats"
        ]
        var violations: [String] = []

        for relativePath in scopedFiles {
            let source = try productionSource(relativePath)
            for token in forbidden where source.contains(token) {
                violations.append("\(relativePath): \(token)")
            }
        }

        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
        let actionDelegate = try productionSource(
            "common/XMPPUIActionManager/XMPPUIActionManager+Delegate.swift"
        )
        let backgroundDelegate = try productionSource(
            "common/XMPPBackgroundTask/XMPPBackgroundTask+Delegate.swift"
        )
        XCTAssertTrue(actionDelegate.contains("CanonicalAuxiliaryGroupMessageRouter.route"))
        XCTAssertTrue(backgroundDelegate.contains("CanonicalAuxiliaryGroupMessageRouter.route"))
    }

    private func productionSource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("xabber", isDirectory: true)
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
