import XCTest
@testable import xabber

final class GroupPermissionsUICutoverTests: XCTestCase {
    func testDefaultResetBuildsCompleteCurrentServerBaseline() throws {
        let reset = GroupPermissionResetMutationBuilder.defaults()

        XCTAssertEqual(reset.scope, .defaults)
        XCTAssertNil(reset.target)
        XCTAssertEqual(reset.permissions.map(\.name), [
            "send-messages",
            "send-media",
            "add-members",
            "pin-messages",
            "change-group-info"
        ])
        XCTAssertEqual(reset.permissions.map(\.status), [true, true, true, false, false])
        XCTAssertTrue(reset.permissions.allSatisfy { $0.level == GroupMemberRole.member.rawValue })
        XCTAssertTrue(reset.permissions.allSatisfy { $0.seconds == nil && $0.expires == nil })
        XCTAssertFalse(reset.permissions.contains { $0.name == GroupMemberRole.owner.rawValue })

        let element = try GroupCommandCodec.encode(.setPermissions(reset))
        XCTAssertEqual(element.name, "defaults")
        XCTAssertNil(element.element(forName: "delete"))
        XCTAssertEqual(element.element(forName: "permissions")?.childCount, 5)
    }

    func testPersonalResetCopiesEveryKnownBaselineValueToStableMemberID() throws {
        let baseline = GroupPermissionSet(
            scope: .defaults,
            label: "response-only",
            actor: "member-owner",
            stamp: Date(timeIntervalSince1970: 1_000),
            permissions: [
                GroupPermission(
                    name: "send-messages",
                    level: "member",
                    status: false,
                    expires: 1_900,
                    tag: "messages",
                    fixed: true,
                    display: "Send messages"
                ),
                GroupPermission(
                    name: "send-media",
                    level: "member",
                    status: true,
                    seconds: 600
                ),
                GroupPermission(name: "owner", level: "owner", status: true)
            ]
        )

        let reset = GroupPermissionResetMutationBuilder.personal(
            targetMemberID: "member-7",
            baseline: baseline
        )

        XCTAssertEqual(reset.scope, .direct)
        XCTAssertEqual(reset.target, "member-7")
        XCTAssertNil(reset.label)
        XCTAssertNil(reset.actor)
        XCTAssertNil(reset.stamp)
        XCTAssertEqual(reset.permissions.map(\.name), ["send-messages", "send-media"])
        XCTAssertEqual(reset.permissions.map(\.status), [false, true])
        XCTAssertTrue(reset.permissions.allSatisfy { $0.seconds == nil && $0.expires == nil })
        XCTAssertTrue(reset.permissions.allSatisfy { $0.tag == nil && !$0.fixed && $0.display == nil })

        let element = try GroupCommandCodec.encode(.setPermissions(reset))
        XCTAssertEqual(element.name, "permissions")
        XCTAssertEqual(element.attributeStringValue(forName: "target"), "member-7")
        XCTAssertNil(element.element(forName: "delete"))
    }

    func testAdminPersonalResetUsesCompleteFalseBaselineWithoutMemberPermissions() {
        let reset = GroupPermissionResetMutationBuilder.personal(
            targetMemberID: "member-7",
            baseline: GroupPermissionResetMutationBuilder.adminBaseline
        )

        XCTAssertEqual(reset.permissions.map(\.name), [
            "change-group-settings",
            "change-user-info",
            "delete-messages",
            "change-permissions",
            "change-default-permissions",
            "block-users",
            "create-admins"
        ])
        XCTAssertTrue(reset.permissions.allSatisfy {
            $0.level == GroupMemberRole.admin.rawValue && !$0.status
        })
    }

    func testNewbiesResetIsExplicitEmptyReplacement() throws {
        let reset = GroupPermissionResetMutationBuilder.newbies()

        XCTAssertEqual(reset, GroupPermissionSet(scope: .newbies, permissions: []))
        let element = try GroupCommandCodec.encode(.setPermissions(reset))
        XCTAssertEqual(element.name, "newbies")
        XCTAssertEqual(element.xmlns(), GroupProtocolNamespace.permissions)
        XCTAssertEqual(element.element(forName: "permissions")?.childCount, 0)
        XCTAssertNil(element.element(forName: "delete"))
    }

    func testDefaultsMutationIsPartialAndDropsOwnerAndTemporaryValues() throws {
        let rows = [
            GroupPermissionEditorRow(
                permission: GroupPermission(
                    name: "send-messages",
                    level: "member",
                    status: true,
                    expires: 999,
                    display: "Send messages"
                ),
                status: false,
                seconds: 120,
                changed: true
            ),
            GroupPermissionEditorRow(
                permission: GroupPermission(name: "send-media", level: "member", status: true),
                status: true,
                seconds: nil,
                changed: false
            ),
            GroupPermissionEditorRow(
                permission: GroupPermission(name: "owner", status: false),
                status: true,
                seconds: nil,
                changed: true
            )
        ]

        let set = try XCTUnwrap(
            GroupPermissionMutationBuilder.partial(
                scope: .defaults,
                targetMemberID: nil,
                rows: rows
            )
        )

        XCTAssertEqual(set.scope, .defaults)
        XCTAssertNil(set.target)
        XCTAssertEqual(set.permissions.count, 1)
        XCTAssertEqual(set.permissions.first?.name, "send-messages")
        XCTAssertEqual(set.permissions.first?.status, false)
        XCTAssertNil(set.permissions.first?.seconds)
        XCTAssertNil(set.permissions.first?.expires)
    }

    func testNewbiesMutationIsAFullReplacementUsingSeconds() {
        let rows = [
            GroupPermissionEditorRow(
                permission: GroupPermission(name: "send-messages", level: "member", status: true),
                status: false,
                seconds: 3600,
                changed: true
            ),
            GroupPermissionEditorRow(
                permission: GroupPermission(name: "send-media", level: "member", status: true),
                status: true,
                seconds: 7200,
                changed: false
            ),
            GroupPermissionEditorRow(
                permission: GroupPermission(name: "owner", status: false),
                status: true,
                seconds: nil,
                changed: false
            )
        ]

        let set = GroupPermissionMutationBuilder.newbiesReplacement(rows: rows)

        XCTAssertEqual(set.scope, .newbies)
        XCTAssertNil(set.target)
        XCTAssertEqual(set.permissions.map(\.name), ["send-messages", "send-media"])
        XCTAssertEqual(set.permissions.map(\.seconds), [3600, 7200])
        XCTAssertTrue(set.permissions.allSatisfy { $0.expires == nil })
    }

    func testDirectMutationTargetsStableMemberIDAndNeverSendsOwnerPermission() throws {
        let rows = [
            GroupPermissionEditorRow(
                permission: GroupPermission(name: "create-admins", level: "admin", status: false),
                status: true,
                seconds: 300,
                changed: true
            ),
            GroupPermissionEditorRow(
                permission: GroupPermission(name: "owner", status: false),
                status: true,
                seconds: nil,
                changed: true
            )
        ]

        let set = try XCTUnwrap(
            GroupPermissionMutationBuilder.partial(
                scope: .direct,
                targetMemberID: "member-7",
                rows: rows
            )
        )

        XCTAssertEqual(set.scope, .direct)
        XCTAssertEqual(set.target, "member-7")
        XCTAssertEqual(set.permissions.map(\.name), ["create-admins"])
        XCTAssertEqual(set.permissions.first?.seconds, 300)
        XCTAssertNil(set.permissions.first?.expires)
    }

    func testPartialMutationWithNoCanonicalChangesIsNil() {
        let rows = [
            GroupPermissionEditorRow(
                permission: GroupPermission(name: "owner", status: false),
                status: true,
                seconds: nil,
                changed: true
            ),
            GroupPermissionEditorRow(
                permission: GroupPermission(name: "send-messages", status: true),
                status: true,
                seconds: nil,
                changed: false
            )
        ]

        XCTAssertNil(
            GroupPermissionMutationBuilder.partial(
                scope: .defaults,
                targetMemberID: nil,
                rows: rows
            )
        )
    }

    func testAuthoritativeExpiryIsReadAsRemainingDurationButNeverEchoedAsExpires() throws {
        let permission = GroupPermission(
            name: "send-messages",
            level: "member",
            status: false,
            expires: 10_900
        )
        let seconds = GroupPermissionMutationBuilder.durationSeconds(
            for: permission,
            now: 10_000
        )
        let mutation = try XCTUnwrap(
            GroupPermissionMutationBuilder.partial(
                scope: .direct,
                targetMemberID: "member-7",
                rows: [
                    GroupPermissionEditorRow(
                        permission: permission,
                        status: true,
                        seconds: seconds,
                        changed: true
                    )
                ]
            )
        )

        XCTAssertEqual(seconds, 900)
        XCTAssertEqual(mutation.permissions.first?.seconds, 900)
        XCTAssertNil(mutation.permissions.first?.expires)
    }

    func testAdminDemotionStripsResponseFieldsAndConvertsAbsoluteExpiry() throws {
        let baseline = GroupPermissionSet(
            scope: .direct,
            target: "response-target",
            label: "Administrator",
            actor: "owner-member",
            stamp: Date(timeIntervalSince1970: 9_500),
            permissions: [
                GroupPermission(
                    name: "create-admins",
                    level: "admin",
                    status: true,
                    expires: 10_900,
                    tag: "moderation",
                    fixed: true,
                    display: "Create administrators"
                ),
                GroupPermission(
                    name: "send-messages",
                    level: "member",
                    status: true,
                    expires: 9_900,
                    tag: "messages",
                    display: "Send messages"
                ),
                GroupPermission(name: "owner", status: true)
            ]
        )

        let mutation = CanonicalAdminDemotionMutation.make(
            baseline: baseline,
            targetMemberID: "member-7",
            now: 10_000
        )

        XCTAssertEqual(mutation.scope, .direct)
        XCTAssertEqual(mutation.target, "member-7")
        XCTAssertNil(mutation.label)
        XCTAssertNil(mutation.actor)
        XCTAssertNil(mutation.stamp)
        XCTAssertEqual(mutation.permissions.map(\.name), [
            "create-admins", "send-messages"
        ])
        XCTAssertEqual(mutation.permissions.map(\.status), [false, true])
        XCTAssertEqual(mutation.permissions.map(\.seconds), [900, nil])
        XCTAssertTrue(mutation.permissions.allSatisfy { $0.expires == nil })
        XCTAssertTrue(mutation.permissions.allSatisfy { $0.tag == nil })
        XCTAssertTrue(mutation.permissions.allSatisfy { !$0.fixed })
        XCTAssertTrue(mutation.permissions.allSatisfy { $0.display == nil })
        XCTAssertNoThrow(
            try GroupCommandCodec.encode(.setPermissions(mutation))
        )
    }

    func testRetainedPermissionsControllersHaveNoLegacyTransportOrRealmModels() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "GroupchatSettingsMembershipViewController.swift",
            "GroupchatSettingsPermissionsViewController.swift",
            "GroupchatSettingsNewbiesPermissionsViewController.swift",
            "GroupchatSettingsPromoteAdminViewController.swift"
        ]
        let folder = repositoryRoot.appendingPathComponent(
            "xabber/controllers/chats/groupchats/groupchat_settings/managed"
        )
        let forbidden = [
            "GroupChatStorageItem",
            "GroupchatPermission",
            "GroupchatUserStorageItem",
            "XMPPUIActionManager",
            "session.groupchat",
            "user.groupchats",
            "realm.write",
            "updateDefaultPermissions",
            "updateNewbiesPermissions",
            "updateUserPermissions",
            "defaultRestrictions",
            "DefaultRights"
        ]
        var violations: [String] = []

        for file in files {
            let contents = try String(
                contentsOf: folder.appendingPathComponent(file),
                encoding: .utf8
            )
            for token in forbidden where contents.contains(token) {
                violations.append("\(file): \(token)")
            }
        }

        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
    }

    func testRetainedPermissionsControllersExposeTypedResetActionsWithoutDeleteWire() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pathsAndRequiredCalls = [
            (
                "xabber/controllers/chats/groupchats/groupchat_settings/managed/GroupchatSettingsPermissionsViewController.swift",
                "groupchatService.resetDefaultPermissions("
            ),
            (
                "xabber/controllers/chats/groupchats/groupchat_settings/managed/GroupchatSettingsNewbiesPermissionsViewController.swift",
                "groupchatService.resetNewbiesPermissions("
            ),
            (
                "xabber/controllers/chats/groupchats/groupchat_settings/managed/GroupchatSettingsPromoteAdminViewController.swift",
                "groupchatService.resetPersonalPermissions("
            )
        ]

        for (path, requiredCall) in pathsAndRequiredCalls {
            let contents = try String(
                contentsOf: repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            XCTAssertTrue(contents.contains(requiredCall), "\(path) must expose \(requiredCall)")
            XCTAssertTrue(
                contents.contains("groupchat_permissions_reset_action"),
                "\(path) must localize the reset action"
            )
            XCTAssertFalse(contents.contains("<delete"), "\(path) must not emit delete XML")
            XCTAssertFalse(contents.contains(".deletePermissions"), "\(path) must not call delete")
        }
    }

    func testPermissionResetLocalizationExistsInEnglishAndRussian() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let requiredKeys = [
            "groupchat_permissions_reset_action",
            "groupchat_permissions_reset_defaults_confirmation",
            "groupchat_permissions_reset_personal_confirmation",
            "groupchat_permissions_reset_newbies_confirmation",
            "groupchat_permissions_reset_success"
        ]

        for locale in ["en", "ru"] {
            let contents = try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "xabber/translations/\(locale).lproj/Localizable.strings"
                ),
                encoding: .utf8
            )
            for key in requiredKeys {
                XCTAssertTrue(
                    contents.contains("\"\(key)\" ="),
                    "Missing \(locale) localization for \(key)"
                )
            }
        }
    }

    func testEveryRetainedKickUIUsesTypedMemberOrchestration() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "xabber/controllers/chats/groupchats/info/GroupchatMembersListViewController.swift",
            "xabber/controllers/chats/info_screens/groupchat_contact_info/GroupchatContactInfoViewController+InfoScreenHeaderButtonDelegate.swift"
        ]

        for path in paths {
            let contents = try String(
                contentsOf: repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            XCTAssertTrue(
                contents.contains("groupchatService.kickMember("),
                "\(path) must use the typed demote-then-kick orchestration"
            )
            XCTAssertFalse(
                contents.contains("groupchatService.kick("),
                "\(path) must not bypass admin demotion"
            )
        }
    }

    func testOpeningGroupChatDoesNotEagerlyFetchPermissions() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let subscriptions = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift"
            ),
            encoding: .utf8
        )
        let chat = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/ChatViewController.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(subscriptions.contains("func groupSubscribtions("))
        XCTAssertFalse(chat.contains("groupSubscribtions()"))
        XCTAssertFalse(
            subscriptions.contains("groupchatService.getPermissions("),
            "The chat-open subscription path only observes persisted projection; permissions are loaded by explicit info/settings flows"
        )
    }
}
