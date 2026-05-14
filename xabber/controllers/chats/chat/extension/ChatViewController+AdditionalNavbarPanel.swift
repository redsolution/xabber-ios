//
//  ChatViewController+AdditionalNavbarPanel.swift
//  xabber
//
//  Created by Игорь Болдин on 01.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
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
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = color
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
        button.configuration = configuration
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    internal func applyPinMessagePanel() {
        let label = UILabel()
        label.text = "Pinned message".localizeString(id: "group_chat__pinned_message", arguments: [])
        label.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .label
        label.lineBreakMode = .byTruncatingTail
        let panel = makeFloatingPanel(
            icon: UIImage(systemName: "pin.fill"),
            tintColor: .tintColor,
            contentViews: [label]
        )
        showTopPanelBubble(with: panel)
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
        let button = makeFloatingPanelButton(
            title: "Incoming subscription request".localizeString(id: "incoming_subscription_request", arguments: []),
            action: #selector(onAllowSubscribtion)
        )
        let panel = makeFloatingPanel(
            icon: UIImage(systemName: "person.wave.2.fill"),
            tintColor: .tintColor,
            contentViews: [button]
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
        let button = makeFloatingPanelButton(
            title: "Accept verification request",
            action: #selector(onRequestingVerification)
        )
        do {
            let realm = try WRealm.safe()
            guard let deviceId = AccountManager.shared.find(for: self.owner)?.omemo.localStore.localDeviceId() else {
                return
            }
            let instance = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: self.owner, jid: self.owner, deviceId: deviceId))
            
            // if the device doesnt have published bundle, it cant accept the verification request
            if instance == nil {
                button.isEnabled = false
            }

        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        let panel = makeFloatingPanel(
            icon: UIImage(systemName: "exclamationmark.triangle.fill"),
            tintColor: .systemOrange,
            contentViews: [button]
        )
        showTopPanelBubble(with: panel)
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
