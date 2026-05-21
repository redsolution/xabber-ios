//
//  ChatViewController+AdditionalNavbarPanel.swift
//  xabber
//
//  Created by Игорь Болдин on 01.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift
import CocoaLumberjack

extension ChatViewController {
    private func makeFloatingPanel(
        icon: UIImage?,
        tintColor: UIColor,
        contentViews: [UIView],
        showsCloseButton: Bool = true
    ) -> ChatFloatingActionPanelView {
        let panel = ChatFloatingActionPanelView(
            icon: icon,
            tintColor: tintColor,
            showsCloseButton: showsCloseButton
        )
        panel.addCloseTarget(self, action: #selector(additionalNavBarPanelCancelButtonTouchUpInside(_:)))
        panel.setContentViews(contentViews)
        return panel
    }

    private func makeFloatingPanelButton(
        title: String,
        color: UIColor = .tintColor,
        action: Selector
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = .clear
        button.isOpaque = false
        button.layer.borderWidth = 0
        button.layer.borderColor = nil
        button.layer.shadowColor = nil
        button.layer.shadowOpacity = 0
        button.layer.shadowRadius = 0
        button.layer.shadowOffset = .zero
        button.layer.shadowPath = nil
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = color
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
        configuration.titleLineBreakMode = .byTruncatingTail
        button.configuration = configuration
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.titleLabel?.adjustsFontSizeToFitWidth = false
        button.contentHorizontalAlignment = .center
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.heightAnchor.constraint(equalToConstant: NativeGlassBarStyle.buttonSize).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    internal func applyPinMessagePanel() {
        hideTopPanelBubble(animated: false)
        refreshPinnedMessagePanelIfNeeded()
    }

    internal func updatePinnedMessagePanelState(pinnedMessageId: String?, canUnpin: Bool) {
        let normalizedPinnedMessageId: String?
        if let pinnedMessageId,
           pinnedMessageId.isNotEmpty,
           pinnedMessageId != "0" {
            normalizedPinnedMessageId = pinnedMessageId
        } else {
            normalizedPinnedMessageId = nil
        }

        canUnpinMessage.accept(canUnpin)
        self.pinnedMessageId.accept(normalizedPinnedMessageId)
        currentPinnedMessageId = normalizedPinnedMessageId

        guard normalizedPinnedMessageId != nil else {
            hidePinnedMessagePanel(animated: true)
            return
        }

        refreshPinnedMessagePanelIfNeeded()
    }

    internal func refreshPinnedMessagePanelIfNeeded() {
        guard let messageId = currentPinnedMessageId,
              messageId.isNotEmpty else {
            hidePinnedMessagePanel(animated: false)
            return
        }

        renderPinnedMessagePanel(messageId: messageId)
    }

    private func renderPinnedMessagePanel(messageId: String) {
        let panel = pinnedMessagePanelView ?? makePinnedMessagePanelView()
        pinnedMessagePanelView = panel

        let presentation = pinnedMessagePanelPresentation(messageId: messageId)
        panel.configure(
            title: presentation.title,
            preview: presentation.preview,
            showsUnpinButton: canUnpinMessage.value
        )

        let contentHeight = panel.preferredContentHeight(width: pinnedMessagePanelAvailableWidth())
        pinnedMessageBubbleView.setHostedView(panel, contentHeight: contentHeight)
        pinnedMessageBubbleView.isHidden = false
        updateFloatingBubblesVisibility(animated: true)
    }

    private func makePinnedMessagePanelView() -> ChatPinnedMessagePanelView {
        let panel = ChatPinnedMessagePanelView(frame: .zero)
        panel.addTarget(self, action: #selector(onPinnedMessagePanelTouchUpInside(_:)), for: .touchUpInside)
        panel.unpinButton.addTarget(self, action: #selector(onPinnedMessageUnpinButtonTouchUpInside(_:)), for: .touchUpInside)
        return panel
    }

    private func hidePinnedMessagePanel(animated: Bool) {
        settedPinnedMessageId = nil
        pinnedMessageBubbleView.isHidden = true
        updateFloatingBubblesVisibility(animated: animated)
    }

    private func pinnedMessagePanelAvailableWidth() -> CGFloat {
        let stackHorizontalInset: CGFloat = 24
        let bubbleHorizontalContentInset: CGFloat = 20
        let screenWidth = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        let safeAreaInset = view.safeAreaInsets.left + view.safeAreaInsets.right
        return max(0, screenWidth - safeAreaInset - stackHorizontalInset - bubbleHorizontalContentInset)
    }

    private struct PinnedMessagePanelPresentation {
        let title: NSAttributedString?
        let preview: String
        let messagePrimary: String?
        let messageId: String?
        let authorId: String?
        let bodyFingerprint: String?
        let sourceDate: Date
    }

    private func pinnedMessagePanelPresentation(messageId pinnedArchivedId: String) -> PinnedMessagePanelPresentation {
        do {
            let realm = try WRealm.safe()
            if let message = realm.objects(MessageStorageItem.self)
                .filter(
                    "owner == %@ AND opponent == %@ AND archivedId == %@ AND conversationType_ == %@",
                    owner,
                    jid,
                    pinnedArchivedId,
                    conversationType.rawValue
                )
                .first {
                let preview = pinnedMessagePreview(for: message)
                return PinnedMessagePanelPresentation(
                    title: pinnedMessageTitle(for: message),
                    preview: preview,
                    messagePrimary: message.primary,
                    messageId: message.messageId.isNotEmpty ? message.messageId : nil,
                    authorId: message.groupchatAuthorId?.isNotEmpty == true ? message.groupchatAuthorId : nil,
                    bodyFingerprint: MentionNotificationSync.normalizedBodyFingerprint(preview),
                    sourceDate: message.date
                )
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }

        return PinnedMessagePanelPresentation(
            title: NSAttributedString(
                string: "Pinned message".localizeString(id: "group_chat__pinned_message", arguments: []),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: UIColor.secondaryLabel
                ]
            ),
            preview: "Loading pinned message...".localizeString(id: "group_chat__pinned_message__loading", arguments: []),
            messagePrimary: nil,
            messageId: nil,
            authorId: nil,
            bodyFingerprint: nil,
            sourceDate: Date()
        )
    }

    private func pinnedMessageTitle(for message: MessageStorageItem) -> NSAttributedString? {
        if conversationType == .group {
            let nickname = message.groupchatAuthorNickname ?? ""
            if nickname.isNotEmpty {
                return ContactChatMetadataManager
                    .shared
                    .get(
                        nickname,
                        for: owner,
                        badge: message.groupchatAuthorBadge ?? "",
                        role: message.groupchatMetadata?["role"] as? String ?? "member"
                    )
                    .getAttributedNickname([
                        .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: UIColor.secondaryLabel
                    ])
            }
        }

        let title = message.outgoing ? ownerSender.displayName : opponentSender.displayName
        guard title.isNotEmpty else {
            return NSAttributedString(
                string: "Pinned message".localizeString(id: "group_chat__pinned_message", arguments: []),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: UIColor.secondaryLabel
                ]
            )
        }
        return NSAttributedString(
            string: title,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
    }

    private func pinnedMessagePreview(for message: MessageStorageItem) -> String {
        let preview = message.displayedBody().trimmingCharacters(in: .whitespacesAndNewlines)
        if preview.isNotEmpty {
            return preview
        }
        return "Pinned message".localizeString(id: "group_chat__pinned_message", arguments: [])
    }

    internal func pinnedMessageOpenRequest() -> ChatOpenMessageRequest? {
        guard let archivedId = currentPinnedMessageId,
              archivedId.isNotEmpty else {
            return nil
        }

        let presentation = pinnedMessagePanelPresentation(messageId: archivedId)
        return ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: presentation.messagePrimary,
                archivedId: archivedId,
                messageId: presentation.messageId,
                authorId: presentation.authorId,
                bodyFingerprint: presentation.bodyFingerprint,
                sourceDate: presentation.sourceDate
            ),
            highlight: true,
            markReadOnVisible: false,
            source: .pinnedMessage
        )
    }

    @objc
    final func onPinnedMessagePanelTouchUpInside(_ sender: ChatPinnedMessagePanelView) {
        guard let request = pinnedMessageOpenRequest() else {
            return
        }
        queueOpenMessageRequest(
            request,
            hooks: ChatAnchorExecutionHooks(
                direction: .up,
                animatedScroll: true,
                onFailed: nil,
                onPositioned: nil
            )
        )
    }

    @objc
    final func onPinnedMessageUnpinButtonTouchUpInside(_ sender: UIButton) {
        guard canUnpinMessage.value else {
            return
        }
        ActionSheetPresenter().present(
            in: self,
            title: nil,
            message: nil,
            cancel: "Cancel".localizeString(id: "cancel", arguments: []),
            values: [
                ActionSheetPresenter.Item(
                    destructive: true,
                    title: "Unpin".localizeString(id: "group_chat__pinned_message__tooltip_unpin", arguments: []),
                    value: "unpin"
                )
            ],
            animated: true
        ) { value in
            guard value == "unpin" else {
                return
            }
            self.performPinnedMessageUnpin()
        }
    }

    private func performPinnedMessageUnpin() {
        DispatchQueue.main.async {
            self.view.makeToastActivity(self.view.center)
            XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { stream, session in
                session.groupchat?.unpinMessage(stream, groupchat: self.jid) { error in
                    self.handlePinnedMessageUnpinResult(error)
                }
            }) {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.groupchats.unpinMessage(stream, groupchat: self.jid) { error in
                        self.handlePinnedMessageUnpinResult(error)
                    }
                })
            }
        }
    }

    private func handlePinnedMessageUnpinResult(_ error: String?) {
        DispatchQueue.main.async {
            self.view.hideToastActivity()
            if let error {
                var message = "Internal error: \(error)"
                    .localizeString(id: "message_manager_internal_error_message", arguments: ["\(error)"])
                if error == "not-allowed" {
                    message = "You don't have permission to unpin messages"
                        .localizeString(id: "groupchats_no_unpin_permission", arguments: [])
                }
                self.view.makeToast(message, danger: true)
                return
            }
            self.updatePinnedMessagePanelState(pinnedMessageId: nil, canUnpin: self.canUnpinMessage.value)
        }
    }
    
    internal func applyAudioPlayerPanel() {
        configureSharedAudioPanel()
    }
    
    internal func applyAddContactPanel() {
        let addButton = makeFloatingPanelButton(
            title: "Add Contact".localizeString(id: "add_contact", arguments: []),
            action: #selector(self.onAddContact)
        )
        let blockButton = makeFloatingPanelButton(
            title: "Block".localizeString(id: "contact_bar_block", arguments: []),
            color: .systemRed,
            action: #selector(self.onBlockContact)
        )
        let panel = makeFloatingPanel(
            icon: UIImage(systemName: "person.fill.badge.plus"),
            tintColor: .tintColor,
            contentViews: [addButton, blockButton]
        )
        showTopPanelBubble(with: panel)
    }
    
    internal func applyRequestSubscribtionPanel() {
        let button = makeFloatingPanelButton(
            title: "Request subscription".localizeString(id: "request_subscription", arguments: []),
            action: #selector(onRequestSubscribtion)
        )
        let panel = makeFloatingPanel(
            icon: UIImage(systemName: "person.wave.2.fill"),
            tintColor: .tintColor,
            contentViews: [button]
        )
        showTopPanelBubble(with: panel)
    }
    
    internal func applyAllowSubscribtion() {
        let allowButton = makeFloatingPanelButton(
            title: "Incoming subscription request".localizeString(id: "incoming_subscription_request", arguments: []),
            action: #selector(onAllowSubscribtion)
        )
        let blockButton = makeFloatingPanelButton(
            title: "Block".localizeString(id: "contact_bar_block", arguments: []),
            color: .systemRed,
            action: #selector(self.onBlockContact)
        )
        let panel = makeFloatingPanel(
            icon: UIImage(systemName: "person.wave.2.fill"),
            tintColor: .tintColor,
            contentViews: [allowButton, blockButton]
        )
        showTopPanelBubble(with: panel)
    }
    
    internal func applyEnterCodePanel() {
        let button = makeFloatingPanelButton(
            title: "Enter verification code",
            action: #selector(onEnterCodeVerification)
        )
        let panel = makeFloatingPanel(
            icon: UIImage(systemName: "entry.lever.keypad.trianglebadge.exclamationmark.fill"),
            tintColor: .systemOrange,
            contentViews: [button]
        )
        showTopPanelBubble(with: panel)
    }
    
    internal func applyRequestedVerificationPanel() {
        let button = makeFloatingPanelButton(
            title: "Outgoing verification request",
            action: #selector(onRequestedVerification)
        )
        let panel = makeFloatingPanel(
            icon: UIImage(systemName: "exclamationmark.triangle.fill"),
            tintColor: .systemOrange,
            contentViews: [button]
        )
        showTopPanelBubble(with: panel)
    }
    
    internal func applyRequestingVerificationPanel() {
        var isActionEnabled = true
        do {
            let realm = try WRealm.safe()
            guard let deviceId = AccountManager.shared.find(for: self.owner)?.omemo.localStore.localDeviceId() else {
                return
            }
            let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: deviceId))
            
            isActionEnabled = instance != nil

        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        let panel = makeRequestingVerificationPanel(isActionEnabled: isActionEnabled)
        showTopPanelBubble(with: panel)
    }

    internal func makeRequestingVerificationPanel(isActionEnabled: Bool) -> ChatFloatingActionPanelView {
        let button = makeFloatingPanelButton(
            title: "Accept verification request",
            action: #selector(onRequestingVerification)
        )
        button.isEnabled = isActionEnabled
        let panel = makeFloatingPanel(
            icon: UIImage(systemName: "exclamationmark.triangle.fill"),
            tintColor: .systemOrange,
            contentViews: [button]
        )
        return panel
    }
    
    internal func applyShouldRequestVerificationPanel(){
        let button = makeFloatingPanelButton(
            title: "Verify contact",
            action: #selector(onShouldRequestVerification)
        )
        let panel = makeFloatingPanel(
            icon: UIImage(systemName: "exclamationmark.triangle.fill"),
            tintColor: .systemOrange,
            contentViews: [button]
        )
        showTopPanelBubble(with: panel)
    }
    
    internal func applyAcceptedVerification() {
        let button = makeFloatingPanelButton(
            title: "Show verification code",
            action: #selector(onAcceptedVerification)
        )
        let panel = makeFloatingPanel(
            icon: UIImage(systemName: "checkmark.shield.fill"),
            tintColor: .systemGreen,
            contentViews: [button]
        )
        showTopPanelBubble(with: panel)
    }
    
    @objc
    final func additionalNavBarPanelCancelButtonTouchUpInside(_ sender: UIButton) {
        switch topPanelState.value {
            case .none:
                break
            case .pinnedMessage:
                break
            case .addContact:
                break
            case .requestSubscribtion:
                break
            case .allowSubscribtion:
                break
            case .requestedVerification:
                break
            case .enterCodeVerification:
                break
            case .requestingVerification:
                break
            case .shouldRequestVerification:
                break
            case .acceptedVerification:
                break
            case .audioPlayer:
                break
        }
        hideTopPanelBubble(animated: true)
    }
}
