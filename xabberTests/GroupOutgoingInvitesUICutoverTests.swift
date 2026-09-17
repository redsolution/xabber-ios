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

    func testInviteSuccessMessageUsesNativePluralLocalizationKey() throws {
        let source = try productionSource(
            "xabber/controllers/chats/groupchats/invite/GroupchatInviteViewController+Flow.swift"
        )

        XCTAssertTrue(source.contains("L10n.plural("))
        XCTAssertTrue(source.contains("\"groupchat__toast__invitations_sent\""))
        XCTAssertTrue(source.contains("let invitationCount = max(1, self.invitedJidsCount)"))
        XCTAssertTrue(source.contains("count: invitationCount"))
        XCTAssertFalse(source.contains("groupchat__toast__invitations_sent["))
    }

    func testAmbiguousProductionFallbacksUseDedicatedKeys() throws {
        let devices = try productionSource(
            "xabber/controllers/chats/info_screens/account_info/devices_list/DevicesListViewController.swift"
        )
        let sessions = try productionSource(
            "xabber/controllers/chats/info_screens/account_info/AccountInfoViewController.swift"
        )
        let signIn = try productionSource(
            "xabber/controllers/onboarding/signin/SignInServerFeaturesViewController.swift"
        )
        let notifications = try productionSource(
            "xabber/common/notify_manager/RichNotificationPresentation.swift"
        )

        XCTAssertTrue(devices.contains("\"settings_account__label_active_devices\""))
        XCTAssertFalse(devices.contains("\"settings_account__label_active_sessions\""))
        XCTAssertTrue(sessions.contains("\"settings_account__label_active_sessions\""))
        XCTAssertTrue(signIn.contains("\"signin_server_capabilities_retryable_subtitle\""))
        XCTAssertTrue(signIn.contains("\"signin_server_capabilities_partial_failure_subtitle\""))
        XCTAssertTrue(notifications.contains("\"push_invitation_sender_unknown\""))
        XCTAssertTrue(notifications.contains("\"push_sender_unknown\""))
        XCTAssertFalse(notifications.contains("\"somebody\""))
    }

    func testTypedFormattingCallsitesPassTheirRequiredArguments() throws {
        let certificate = try productionSource(
            "xabber/controllers/alerts/TrustCertificatePresenter.swift"
        )
        let editContact = try productionSource(
            "xabber/controllers/chats/edit_contact/EditContactViewController+UITextFieldDelegate.swift"
        )
        let contactInfo = try productionSource(
            "xabber/controllers/chats/info_screens/contact_info/ContactInfoViewController+InfoScreenHeaderButtonDelegate.swift"
        )

        XCTAssertTrue(certificate.contains("L10n.format("))
        XCTAssertTrue(certificate.contains("arguments: [domain]"))
        XCTAssertTrue(editContact.contains("L10n.format("))
        XCTAssertTrue(editContact.contains("arguments: [groupName]"))
        XCTAssertTrue(contactInfo.contains("L10n.format("))
        XCTAssertTrue(contactInfo.contains("arguments: [displayedName]"))
    }

    private func productionSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
