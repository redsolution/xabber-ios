import XCTest
@testable import xabber

final class GroupChatCanonicalMembersUITests: XCTestCase {
    func testCommonMemberCellUsesCanonicalRoleAndHasNoLegacyRightsDelegateSurface() throws {
        let root = repositoryRoot()
        let cell = try source(
            root,
            "xabber/controllers/chats/info_screens/cells/CommonMemberTableCell.swift"
        )
        let legacyRights = root.appendingPathComponent(
            "xabber/xmpp/groupchat/GroupchatRightsDelegateProtocol.swift"
        )

        XCTAssertTrue(cell.contains("role: GroupMemberRole"))
        XCTAssertFalse(cell.contains("GroupchatUserStorageItem"))
        XCTAssertFalse(cell.contains("GroupchatPermission"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRights.path))
    }

    func testMentionCandidatesUseCanonicalMemberStorageAndTypedRefresh() throws {
        let root = repositoryRoot()
        let chat = try source(
            root,
            "xabber/controllers/chats/chat/ChatViewController.swift"
        )
        let subscriptions = try source(
            root,
            "xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift"
        )

        XCTAssertTrue(chat.contains("canonicalMentionMembers()"))
        XCTAssertTrue(chat.contains(".projection(owner: owner, groupJID: jid)"))
        XCTAssertTrue(chat.contains("groupchatService.refreshMembers"))
        XCTAssertTrue(chat.contains("GroupRepository(realm: WRealm.safe()).replaceMembers"))
        XCTAssertFalse(chat.contains("Results<GroupchatUserStorageItem>"))
        XCTAssertTrue(subscriptions.contains("previousState?.members != state.members"))
        XCTAssertFalse(subscriptions.contains("groupchats.requestMyPermissions"))
        XCTAssertFalse(subscriptions.contains("groupchats.getDefaultPermissions"))
    }

    func testGroupCopyAndEditPresentationNeverReadsMutableLegacyMemberCards() throws {
        let root = repositoryRoot()
        let copy = try source(
            root,
            "xabber/controllers/chats/chat/extension/ChatViewController+SelectionPanel.swift"
        )
        let edit = try source(
            root,
            "xabber/controllers/chats/chat/rx/ChatViewController+LowPrioritySubscribtions.swift"
        )

        XCTAssertFalse(copy.contains("GroupchatUserStorageItem"))
        XCTAssertTrue(copy.contains("groupchatAuthorNickname"))
        XCTAssertFalse(edit.contains("GroupchatUserStorageItem"))
        XCTAssertTrue(edit.contains("canonicalGroupProjectionState"))
        XCTAssertTrue(edit.contains(".selfMember?"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ root: URL, _ relativePath: String) throws -> String {
        try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
