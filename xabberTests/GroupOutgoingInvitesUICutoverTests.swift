import XCTest
@testable import xabber

final class GroupOutgoingInvitesUICutoverTests: XCTestCase {
    func testOutgoingInviteScreensUseOnlyTypedService() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "xabber/controllers/chats/groupchats/invite/GroupchatInviteViewController+Flow.swift",
            "xabber/controllers/chats/groupchats/invited_list/GroupchatInviteListViewController.swift"
        ]
        let forbidden = [
            "user.groupchats",
            "session.groupchat",
            "XMPPUIActionManager",
            "GroupchatInvitedUsersStorageItem",
            "willInvite(",
            "didInvite(",
            "cancelInvite("
        ]

        for path in paths {
            let source = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("groupchatService"), path)
            for token in forbidden {
                XCTAssertFalse(source.contains(token), "\(path): \(token)")
            }
        }
    }

    func testInviteErrorMappingPreservesCanonicalStanzaConditions() {
        XCTAssertEqual(
            CanonicalGroupInviteErrorPresentation.condition(
                for: GroupchatServiceError.iq(
                    GroupIQStanzaError(
                        type: "cancel",
                        condition: "conflict",
                        text: nil,
                        payload: nil
                    )
                )
            ),
            "conflict"
        )
        XCTAssertEqual(
            CanonicalGroupInviteErrorPresentation.condition(
                for: GroupchatServiceError.iq(
                    GroupIQStanzaError(
                        type: "auth",
                        condition: "not-allowed",
                        text: nil,
                        payload: nil
                    )
                )
            ),
            "not-allowed"
        )
    }

    func testInviteScreenPassesCanonicalPrivacyAndCannotChooseRawSendFlag() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "xabber/controllers/chats/groupchats/invite/GroupchatInviteViewController+Flow.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("repository.projection("))
        XCTAssertTrue(source.contains("privacy: privacy"))
        XCTAssertFalse(source.contains("send:"))
    }
}
