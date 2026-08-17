import XCTest
@testable import xabber

final class GroupchatSettingsCanonicalCutoverTests: XCTestCase {
    func testProjectionModelUsesCanonicalSnapshotMembersPermissionsAndCapabilities() {
        let defaults = GroupPermissionSet(
            scope: .defaults,
            permissions: [
                GroupPermission(name: "send-messages", status: true),
                GroupPermission(name: "send-media", status: false)
            ]
        )
        let projection = GroupRepositoryProjection(
            state: GroupViewState(
                snapshot: GroupSnapshot(
                    jid: "group@example.org",
                    info: GroupInfo(
                        name: "Canonical group",
                        description: "Server state",
                        avatar: GroupAvatar(url: "https://cdn.example.org/avatar.png"),
                        status: "Shipping"
                    ),
                    settings: GroupSettings(membership: .privateGroup)
                ),
                members: [
                    GroupMember(id: "self", role: .owner),
                    GroupMember(id: "admin", role: .admin),
                    GroupMember(id: "member", role: .member)
                ],
                permissionSets: [defaults],
                selfSubscription: .both
            ),
            selfMemberID: "self",
            capabilities: .derive(role: .owner, permissionSet: nil)
        )

        let model = GroupchatSettingsCanonicalModel(
            projection: projection,
            outgoingInviteCount: 3,
            blockedCount: 2
        )

        XCTAssertEqual(model.name, "Canonical group")
        XCTAssertEqual(model.description, "Server state")
        XCTAssertEqual(model.status, "Shipping")
        XCTAssertEqual(model.avatarURL, "https://cdn.example.org/avatar.png")
        XCTAssertEqual(model.membership, .privateGroup)
        XCTAssertEqual(model.enabledDefaultPermissionCount, 1)
        XCTAssertEqual(model.defaultPermissionCount, 2)
        XCTAssertEqual(model.administratorCount, 2)
        XCTAssertEqual(model.outgoingInviteCount, 3)
        XCTAssertEqual(model.blockedCount, 2)
        XCTAssertTrue(model.isActive)
        XCTAssertTrue(model.canEditInfo)
        XCTAssertTrue(model.canEditSettings)
        XCTAssertTrue(model.canEditDefaultPermissions)
        XCTAssertTrue(model.canManageAdmins)
        XCTAssertTrue(model.canInvite)
        XCTAssertTrue(model.canBlock)
        XCTAssertTrue(model.canDelete)
    }

    func testInactiveProjectionNeverRequestsPermissionsOrEnablesMutations() {
        let projection = GroupRepositoryProjection(
            state: GroupViewState(
                snapshot: GroupSnapshot(
                    jid: "group@example.org",
                    settings: GroupSettings(state: .inactive)
                ),
                selfSubscription: .wait
            ),
            selfMemberID: nil,
            capabilities: .derive(role: nil, permissionSet: nil)
        )

        let model = GroupchatSettingsCanonicalModel(
            projection: projection,
            outgoingInviteCount: 0,
            blockedCount: 0
        )

        XCTAssertFalse(model.isActive)
        XCTAssertFalse(model.shouldRefreshPermissions)
        XCTAssertFalse(model.canEditInfo)
        XCTAssertFalse(model.canDelete)
    }

    func testAuthoritativeInfoResponseBecomesExplicitRepositoryPatch() {
        let info = GroupInfo(
            name: "Server name",
            description: nil,
            avatar: GroupAvatar(
                id: "avatar-id",
                mediaType: "image/png",
                bytes: 42,
                width: 128,
                height: 128,
                url: "https://cdn.example.org/avatar.png"
            ),
            status: "active"
        )

        let patch = GroupchatSettingsCanonicalModel.authoritativeInfoPatch(info)

        XCTAssertEqual(
            patch.info,
            .value(
                GroupInfoPatch(
                    name: .value("Server name"),
                    description: .value(nil),
                    avatar: .value(info.avatar),
                    status: .value("active")
                )
            )
        )
    }

    func testRetainedSettingsScreenHasCanonicalSingleRepositoryPath() throws {
        let source = try productionSource()
        let forbidden = [
            "GroupChatStorageItem",
            "GroupchatUserStorageItem",
            "GroupchatPermission",
            "GroupchatInvitedUsersStorageItem",
            "XMPPUIActionManager",
            "session.groupchat",
            "user.groupchats",
            "RosterStorageItem",
            "customUsername",
            "Observable.collection",
            "realm.write",
            "[String: Any]"
        ]

        XCTAssertTrue(source.contains("GroupRepositoryProjection"))
        XCTAssertTrue(source.contains("observeProjection"))
        XCTAssertTrue(source.contains("groupchatService.updateInfo"))
        XCTAssertTrue(source.contains("repository.applyPatch"))
        XCTAssertTrue(source.contains("groupchatService.refreshInvites"))
        XCTAssertTrue(source.contains("groupchatService.refreshBlocklist"))
        XCTAssertTrue(source.contains("groupchatService.delete"))
        XCTAssertTrue(source.contains("repository.recordDeletion"))
        for token in forbidden {
            XCTAssertFalse(source.contains(token), token)
        }
    }

    func testInfoMutationAppliesOnlyAuthoritativeResponseAndAvatarHasNoClearPath() throws {
        let source = try productionSource()
        let update = try XCTUnwrap(source.range(of: "groupchatService.updateInfo"))
        let apply = try XCTUnwrap(source.range(of: "repository.applyPatch"))

        XCTAssertLessThan(
            source.distance(from: source.startIndex, to: update.lowerBound),
            source.distance(from: source.startIndex, to: apply.lowerBound)
        )
        XCTAssertTrue(source.contains("setGroupAvatar"))
        XCTAssertFalse(source.contains("onClearAvatar"))
        XCTAssertFalse(source.contains("sendClearMetadata"))
        XCTAssertFalse(source.contains("account_clear_avatar"))
        XCTAssertFalse(source.contains("updateGroupAvatar"))
    }

    func testStatusUsesCanonicalInfoMutationAndRetainedSettingsEntryPoint() throws {
        let source = try productionSource()
        XCTAssertTrue(source.contains("statusObserver"))
        XCTAssertTrue(source.contains("status: statusObserver.value"))
        XCTAssertTrue(source.contains("key: \"status\""))

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entryPoint = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/info_screens/groupchat_info/GroupchatInfoViewController+InfoScreenHeaderButtonDelegate.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(entryPoint.range(of: "func setStatus()"))
        let end = try XCTUnwrap(
            entryPoint.range(of: "@objc\n    func showQRCode", range: start.upperBound..<entryPoint.endIndex)
        )
        let statusFlow = String(entryPoint[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(statusFlow.contains("showSettings()"))
        XCTAssertFalse(statusFlow.contains("GroupchatSettingsViewController"))
        XCTAssertFalse(statusFlow.contains("//"))
    }

    func testGroupAvatarUploadDoesNotOptimisticallyWriteRosterProjection() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/xmpp/avatar/AvatarUploadManager.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func handleGroupAvatarUploadSuccess"))
        let end = try XCTUnwrap(
            source.range(of: "fileprivate func posAvatarUpdate", range: start.upperBound..<source.endIndex)
        )
        let groupFlow = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(groupFlow.contains("sendImageMetadata"))
        XCTAssertTrue(groupFlow.contains("groupchatService.updateGroupAvatar"))
        XCTAssertTrue(groupFlow.contains("repository.applySnapshot"))
        XCTAssertFalse(groupFlow.contains("RosterStorageItem"))
        XCTAssertFalse(groupFlow.contains("oldschoolAvatarKey"))
        XCTAssertFalse(groupFlow.contains("avatarMaxUrl"))
        XCTAssertFalse(groupFlow.contains("realm.write"))
    }

    func testGroupInfoAvatarFlowDoesNotPollRosterForUploadedMetadata() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/info_screens/groupchat_info/GroupchatInfoViewController+InfoScreenHeaderButtonDelegate.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("setGroupAvatar"))
        XCTAssertFalse(source.contains("uploadedAvatarMetadata"))
        XCTAssertFalse(source.contains("RosterStorageItem"))
        XCTAssertFalse(source.contains("avatarMaxUrl"))
    }

    private func productionSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/groupchats/groupchat_settings/GroupchatSettingsViewControllerT.swift"
            ),
            encoding: .utf8
        )
    }
}
