import UIKit
import RealmSwift

extension ChatViewController {
    func didTapOnForwardAuthor(message messagePrimary: String, card: ForwardCardSnapshot) {
        guard !showSkeletonObserver.value, !isInSelectionMode.value,
              card.owner == owner, presentedViewController == nil,
              datasource.contains(where: { row in
                  row.forwards.contains { $0.primary == messagePrimary && $0.forwardCard == card }
              }) else { return }
        let controller = makeForwardCardInfoController(for: card)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        presentContainedNavigationModal(
            navigation, rootViewController: controller,
            presentedContentViewController: controller, from: self,
            modalPresentationStyle: .pageSheet
        )
        refreshForwardGroupCard(controller)
    }

    /// Construction is local and testable; only explicitly displaying a group queries its details.
    internal func makeForwardCardInfoController(for card: ForwardCardSnapshot) -> ForwardCardInfoViewController {
        weak var currentController: ForwardCardInfoViewController?
        let controller = ForwardCardInfoViewController(
            snapshot: card, primaryAction: forwardCardPrimaryAction(card),
            onAction: { [weak self] action in
                guard let self, let controller = currentController else { return }
                self.performForwardCardAction(action, in: controller)
            },
            onOpenGroup: { [weak self] in
                guard let self, let controller = currentController,
                      controller.snapshot.owner == self.owner,
                      let groupCard = controller.snapshot.sourceGroupCard,
                      let navigation = controller.navigationController else { return }
                let groupController = self.makeForwardCardInfoController(for: groupCard)
                navigation.pushViewController(groupController, animated: true)
                self.refreshForwardGroupCard(groupController)
            }
        )
        currentController = controller
        return controller
    }

    private func forwardCardPrimaryAction(
        _ card: ForwardCardSnapshot, access: ForwardCardGroupAccess = .unknown
    ) -> ForwardCardPrimaryAction? {
        let realm = try? WRealm.safe()
        let hasContact = card.jid.map { jid in
            realm?.object(ofType: RosterStorageItem.self,
                          forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: card.owner))?.isContact == true
        } ?? false
        let hasChat = card.jid.map { jid in
            realm?.objects(LastChatsStorageItem.self)
                .filter("owner == %@ AND jid == %@", card.owner, jid).isEmpty == false
        } ?? false
        let groupJID = card.kind == .group ? card.jid : card.sourceGroup?.jid
        let hasGroup = groupJID.map { jid in
            realm?.object(ofType: GroupSelfMembershipStorageItem.self,
                          forPrimaryKey: GroupStorageKey.groupPrimary(owner: card.owner, groupJID: jid))?
                .stateRaw == GroupSelfMembershipState.both.rawValue
        } ?? false
        return ForwardCardActionPolicy.primaryAction(
            for: card, hasContact: hasContact, hasChat: hasChat,
            hasGroup: hasGroup, groupAccess: access
        )
    }

    private func refreshForwardGroupCard(_ controller: ForwardCardInfoViewController) {
        let card = controller.snapshot
        guard card.kind == .group, card.owner == owner, let jid = card.jid,
              let account = AccountManager.shared.find(for: card.owner) else { return }
        controller.refreshTask?.cancel()
        controller.refreshTask = Task { @MainActor [weak self, weak controller] in
            do {
                let group = try await account.groupchatService.refreshGroup(groupJID: jid)
                guard !Task.isCancelled, let self, let controller,
                      self.owner == card.owner,
                      group.jid.map({ GroupStorageKey.bareJID($0) == jid }) != false else { return }
                let privacy: ForwardContactCard.Privacy?
                switch group.privacy {
                case .publicGroup: privacy = .public
                case .incognito: privacy = .incognito
                case nil: privacy = nil
                }
                controller.updateSnapshot(ForwardCardSnapshot(
                    kind: .group, owner: card.owner,
                    name: group.info?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                        .nilIfEmpty ?? card.name,
                    jid: jid,
                    avatarURL: ForwardCardSnapshot.hostedAvatarURL(group.info?.avatar?.url),
                    privacy: privacy
                ))
                let access: ForwardCardGroupAccess
                switch group.settings?.membership {
                case .open: access = .open
                case .privateGroup: access = .restricted
                case nil: access = .unknown
                }
                controller.updatePrimaryAction(self.forwardCardPrimaryAction(controller.snapshot, access: access))
            } catch {
                guard !Task.isCancelled, let self, let controller, self.owner == card.owner else { return }
                let access: ForwardCardGroupAccess
                if case let GroupchatServiceError.iq(error) = error,
                   ["forbidden", "not-allowed"].contains(error.condition ?? "") {
                    access = .restricted
                } else {
                    access = .unavailable
                }
                controller.updatePrimaryAction(self.forwardCardPrimaryAction(card, access: access))
            }
        }
    }

    private func performForwardCardAction(_ action: ForwardCardAction, in controller: ForwardCardInfoViewController) {
        let card = controller.snapshot
        guard card.owner == owner, controller.primaryAction?.kind == action,
              controller.primaryAction?.isEnabled == true else { return }
        switch action {
        case .openChat:
            guard let jid = card.jid else { return }
            let type = forwardCardConversationType(owner: card.owner, jid: jid)
            controller.dismissSheet { [weak self] in
                self?.openForwardCardChat(owner: card.owner, jid: jid, type: type)
            }
        case .addContact:
            guard let jid = card.jid else { return }
            controller.dismissSheet { [weak self] in
                guard let self, self.owner == card.owner else { return }
                let contact = AddNewContactViewController()
                contact.accountJid = card.owner
                contact.contactJid.accept(jid)
                showModal(contact, parent: self)
            }
        case .openGroup:
            guard let jid = card.kind == .group ? card.jid : card.sourceGroup?.jid,
                  forwardCardPrimaryAction(card)?.kind == .openGroup else { return }
            controller.dismissSheet { [weak self] in
                self?.openForwardCardChat(owner: card.owner, jid: jid, type: .group)
            }
        case .joinGroup:
            guard card.kind == .group, let jid = card.jid,
                  let account = AccountManager.shared.find(for: card.owner) else { return }
            controller.updatePrimaryAction(.init(kind: .joinGroup, isEnabled: false))
            controller.refreshTask?.cancel()
            controller.refreshTask = Task { @MainActor [weak self, weak controller] in
                do {
                    try await CanonicalGroupMembershipLifecycle.join(account: account, groupJID: jid)
                    guard !Task.isCancelled, let self, let controller, self.owner == card.owner else { return }
                    controller.dismissSheet { [weak self] in
                        self?.openForwardCardChat(owner: card.owner, jid: jid, type: .group)
                    }
                } catch {
                    guard !Task.isCancelled, let self, let controller, self.owner == card.owner else { return }
                    controller.updatePrimaryAction(self.forwardCardPrimaryAction(card, access: .open))
                    ErrorMessagePresenter().present(
                        in: controller, message: CanonicalGroupMembershipLifecycle.localizedErrorMessage(error),
                        animated: true, completion: nil
                    )
                }
            }
        case .requestToJoin: break
        }
    }

    private func forwardCardConversationType(owner: String, jid: String) -> ClientSynchronizationManager.ConversationType {
        if owner == self.owner, jid == self.jid { return conversationType }
        return (try? WRealm.safe())?.objects(LastChatsStorageItem.self)
            .filter("owner == %@ AND jid == %@", owner, jid).first?.conversationType
            ?? ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type)
            ?? .regular
    }

    private func openForwardCardChat(owner: String, jid: String,
                                     type: ClientSynchronizationManager.ConversationType) {
        guard self.owner == owner else { return }
        if self.jid == jid, conversationType == type { return }
        if let leftMenuDelegate {
            leftMenuDelegate.openChatlistWithChat(owner: owner, jid: jid, conversationType: type, configure: nil)
        } else {
            let chat = ChatViewController()
            chat.owner = owner
            chat.jid = jid
            chat.conversationType = type
            showStacked(chat, in: self)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
