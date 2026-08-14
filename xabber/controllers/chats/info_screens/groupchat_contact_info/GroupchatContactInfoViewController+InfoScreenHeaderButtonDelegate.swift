//
//  Copyright (c) Xabber
//

import Foundation
import UIKit
import CocoaLumberjack
import LetterAvatarKit
import MaterialComponents.MDCPalettes

extension GroupchatContactInfoViewController: InfoScreenHeaderDelegate {
    func onXabberAccount() {}

    func shouldUpdateAvatar() -> UIImage? {
        let configuration = LetterAvatarBuilderConfiguration()
        configuration.username = userNickname.uppercased()
        configuration.size = DefaultAvatarManager.defaultSize
        configuration.backgroundColors = [AccountColorManager.shared.palette(for: owner).tint600]
        return UIImage.makeLetterAvatar(withConfiguration: configuration)
    }

    @objc func onFirstButtonPressed() {
        guard !isMyProfile else {
            let id = isIncognitoGroup
                ? "chat_cant_create_private_yourself"
                : "chat_cant_create_direct_yourself"
            view.makeToast("Can`t create chat with yourself".localizeString(id: id, arguments: []))
            return
        }
        if isIncognitoGroup {
            openPrivateChat()
        } else {
            openChat()
        }
    }

    @objc func onSecondButtonPressed() {
        // Canonical per-author history is not a server operation. The retained
        // button is hidden until the local group-MAM filter is implemented.
    }

    @objc func onThirdButtonPressed() {
        guard canChangeBadge else { return }
        TextViewPresenter().present(
            in: self,
            title: "Change member`s badge".localizeString(id: "groupchats_create_members_badge", arguments: []),
            message: "",
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            set: "Change".localizeString(id: "change", arguments: []),
            currentValue: userBadge,
            animated: true
        ) { [weak self] value in
            self?.updateMember(badge: value ?? "")
        }
    }

    @objc func onFourthButtonPressed() {
        if isBlocked {
            onUnblock()
        } else if isKicked {
            onBlockAlreadyRemovedMember()
        } else {
            onKick()
        }
    }

    func onImageButtonPressed() {
        // Member avatars are URL-metadata only. There is no member-card upload
        // target in the current uploader, so inline/clear controls stay hidden.
    }

    func onTitleButtonPressed() {
        guard canChangeNickname else { return }
        TextViewPresenter().present(
            in: self,
            title: "Change member`s nickname".localizeString(id: "groupchats_change_nickname", arguments: []),
            message: "",
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            set: "Change".localizeString(id: "change", arguments: []),
            currentValue: userNickname,
            animated: true
        ) { [weak self] value in
            self?.updateMember(nickname: value ?? "")
        }
    }

    internal func openPrivateChat() {
        guard currentMember?.allowsPeerToPeer == true,
              let account = AccountManager.shared.find(for: owner) else { return }
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            view.makeToastActivity(.center)
            defer { view.hideToastActivity() }
            do {
                let snapshot = try await CanonicalGroupP2PFlow.createOrJoin(
                    owner: owner,
                    parentJID: jid,
                    repository: GroupRepository(realm: try WRealm.safe()),
                    create: {
                        try await account.groupchatService.createP2P(
                            parentJID: self.jid,
                            memberID: self.userId
                        )
                    },
                    joinExisting: {
                        try account.groupchatService.sendJoin(groupJID: $0)
                    }
                )
                guard let p2pJID = snapshot.jid else {
                    throw GroupchatServiceError.missingCreatedGroupJID
                }
                let chat = ChatViewController()
                chat.owner = owner
                chat.jid = p2pJID
                chat.conversationType = .group
                showDetail(chat, currentVc: self)
            } catch {
                presentCanonicalError(error)
            }
        }
    }

    internal func openChat() {
        guard let targetJID = currentMember?.jid else { return }
        let chat = ChatViewController()
        chat.owner = owner
        chat.jid = targetJID
        chat.conversationType = ClientSynchronizationManager.ConversationType(
            rawValue: CommonConfigManager.shared.config.locked_conversation_type
        ) ?? .regular
        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        navigationController?.navigationBar.shadowImage = nil
        showDetail(chat, currentVc: self)
    }

    internal func onKick() {
        let displayName = currentMember?.nickname?.isNotEmpty == true
            ? currentMember!.nickname!
            : userId
        let values = [
            ActionSheetPresenter.Item(
                destructive: true,
                title: "Kick".localizeString(id: "groupchat_kick", arguments: []),
                value: "kick"
            ),
            ActionSheetPresenter.Item(
                destructive: true,
                title: "Kick and Block".localizeString(id: "groupchat_kick_and_block", arguments: []),
                value: "block"
            ),
        ]
        ActionSheetPresenter().present(
            in: self,
            title: "Kick member".localizeString(id: "groupchat_kick_member", arguments: []),
            message: "Do you really want to kick member \(displayName)?".localizeString(
                id: "groupchat_do_you_really_want_to_kick_membername",
                arguments: [displayName]
            ),
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            values: values,
            animated: true
        ) { [weak self] value in
            guard let self else { return }
            value == "block" ? blockAndKick() : kickOnly()
        }
    }

    internal func onUnblock() {
        guard let targetJID = currentMember?.jid,
              let account = AccountManager.shared.find(for: owner) else { return }
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            view.makeToastActivity(.center)
            defer { view.hideToastActivity() }
            do {
                let blocklist = try await account.groupchatService.unblock(
                    groupJID: jid,
                    target: targetJID
                )
                try applyModerationState(members: nil, blocklist: blocklist)
            } catch {
                presentCanonicalError(error)
            }
        }
    }

    internal func onBlockAlreadyRemovedMember() {
        guard let targetJID = currentMember?.jid,
              let account = AccountManager.shared.find(for: owner) else { return }
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            view.makeToastActivity(.center)
            defer { view.hideToastActivity() }
            do {
                let blocklist = try await account.groupchatService.block(
                    groupJID: jid,
                    targets: [targetJID]
                )
                try applyModerationState(members: nil, blocklist: blocklist)
            } catch {
                presentCanonicalError(error)
            }
        }
    }

    internal func onSave() {
        let controller = GroupchatSettingsPermissionsViewController()
        controller.owner = owner
        controller.jid = jid
        navigationController?.pushViewController(controller, animated: true)
    }

    /// Kept for the image-picker delegate compiled with this screen. No picker
    /// is exposed because canonical member avatar mutation requires uploaded URL
    /// metadata and must never serialize inline image data.
    func onUpdateAvatar(_ image: UIImage?) {
        guard image != nil else { return }
        view.makeToast(
            "Member avatar upload is unavailable".localizeString(
                id: "groupchats_member_avatar_no_permission",
                arguments: []
            )
        )
    }

    private func updateMember(nickname: String? = nil, badge: String? = nil) {
        guard let account = AccountManager.shared.find(for: owner) else { return }
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            view.makeToastActivity(.center)
            defer { view.hideToastActivity() }
            do {
                let members = try await account.groupchatService.updateMember(
                    groupJID: jid,
                    update: GroupMemberUpdate(
                        memberID: userId,
                        nickname: nickname,
                        badge: badge
                    )
                )
                try applyModerationState(members: members, blocklist: nil)
            } catch {
                presentCanonicalError(error)
            }
        }
    }

    private func kickOnly() {
        guard let member = currentMember,
              let account = AccountManager.shared.find(for: owner) else { return }
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            view.makeToastActivity(.center)
            defer { view.hideToastActivity() }
            do {
                let members = try await account.groupchatService.kickMember(
                    groupJID: jid,
                    member: member
                )
                try applyModerationState(members: members, blocklist: nil)
            } catch let partial as GroupModerationPartialFailure {
                do {
                    try applyModerationState(
                        members: partial.members,
                        blocklist: nil
                    )
                } catch {
                    DDLogDebug("Group kick projection: \(error.localizedDescription)")
                }
                presentCanonicalError(partial)
            } catch {
                presentCanonicalError(error)
            }
        }
    }

    private func blockAndKick() {
        guard let targetJID = currentMember?.jid,
              let account = AccountManager.shared.find(for: owner) else { return }
        Task { @MainActor [weak self, weak account] in
            guard let self, let account else { return }
            view.makeToastActivity(.center)
            defer { view.hideToastActivity() }
            do {
                let demotion = try await demotionBaselineIfNeeded(account: account)
                let result = try await account.groupchatService.blockMember(
                    groupJID: jid,
                    targetJID: targetJID,
                    demotionPermissions: demotion
                )
                try applyModerationState(
                    members: result.members,
                    blocklist: result.blocklist
                )
            } catch let partial as GroupModerationPartialFailure {
                do {
                    try applyModerationState(
                        members: partial.members,
                        blocklist: partial.blocklist
                    )
                } catch {
                    DDLogDebug("Group moderation projection: \(error.localizedDescription)")
                }
                presentCanonicalError(partial)
            } catch {
                presentCanonicalError(error)
            }
        }
    }

    private func demotionBaselineIfNeeded(account: Account) async throws -> GroupPermissionSet? {
        guard currentMember?.role == .admin else { return nil }
        let baseline = try await account.groupchatService.getPermissions(
            groupJID: jid,
            scope: .direct,
            targetMemberID: userId
        )
        return CanonicalAdminDemotionMutation.make(
            baseline: baseline,
            targetMemberID: userId
        )
    }
}

extension GroupchatContactInfoViewController: AvatarPickerViewControllerDelegate {
    func onReceiveAvatar(image: UIImage, emoji: String?, currentPalette: MDCPalette?) {
        onUpdateAvatar(image)
    }
}
