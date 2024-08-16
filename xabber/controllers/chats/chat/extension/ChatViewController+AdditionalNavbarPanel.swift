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
    internal func applyPinMessagePanel() {
        (self.navigationController as? NavBarController)?.configureAdditionalPanel({ barVc, stack in
            barVc.indicatorIcon.setImage(UIImage(systemName: "pin.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            barVc.indicatorIcon.tintColor = .tintColor
        })
    }
    
    internal func applyAddContactPanel() {
        (self.navigationController as? NavBarController)?.configureAdditionalPanel({ barVc, stack in
            barVc.indicatorIcon.setImage(UIImage(systemName: "person.fill.badge.plus")?.withRenderingMode(.alwaysTemplate), for: .normal)
            barVc.indicatorIcon.tintColor = .tintColor
            let addButton = UIButton()
            var addConfiguration = UIButton.Configuration.plain()
            addConfiguration.title = "Add Contact".localizeString(id: "add_contact", arguments: [])
            addConfiguration.baseForegroundColor = .tintColor
            addButton.configuration = addConfiguration
            
            addButton.addTarget(self, action: #selector(self.onAddContact), for: .touchUpInside)
            
            let blockButton = UIButton()
            var blockConfiguration = UIButton.Configuration.plain()
            blockConfiguration.title = "Block".localizeString(id: "contact_bar_block", arguments: [])
            blockConfiguration.baseForegroundColor = .systemRed
            blockButton.configuration = blockConfiguration
            
            blockButton.addTarget(self, action: #selector(self.onBlockContact), for: .touchUpInside)
            
            stack.addArrangedSubview(addButton)
            stack.addArrangedSubview(blockButton)
        })
    }
    
    internal func applyRequestSubscribtionPanel() {
        (self.navigationController as? NavBarController)?.configureAdditionalPanel({ barVc, stack in
            barVc.indicatorIcon.setImage(UIImage(systemName: "person.wave.2.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            barVc.indicatorIcon.tintColor = .tintColor
            let button = UIButton()
            var configuration = UIButton.Configuration.plain()
            configuration.title = "Request subscription".localizeString(id: "request_subscription", arguments: [])
            configuration.baseForegroundColor = .tintColor
            button.configuration = configuration
            
            button.addTarget(self, action: #selector(onRequestSubscribtion), for: .touchUpInside)
            
            stack.addArrangedSubview(button)
        })
    }
    
    internal func applyAllowSubscribtion() {
        (self.navigationController as? NavBarController)?.configureAdditionalPanel({ barVc, stack in
            barVc.indicatorIcon.setImage(UIImage(systemName: "person.wave.2.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            barVc.indicatorIcon.tintColor = .tintColor
            let button = UIButton()
            var configuration = UIButton.Configuration.plain()
            configuration.title = "Incoming subscription request".localizeString(id: "incoming_subscription_request", arguments: [])
            configuration.baseForegroundColor = .tintColor
            button.configuration = configuration
            
            button.addTarget(self, action: #selector(onAllowSubscribtion), for: .touchUpInside)
            
            stack.addArrangedSubview(button)
        })
    }
    
    internal func applyEnterCodePanel() {
        (self.navigationController as? NavBarController)?.configureAdditionalPanel({ barVc, stack in
            barVc.indicatorIcon.setImage(UIImage(systemName: "entry.lever.keypad.trianglebadge.exclamationmark.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            barVc.indicatorIcon.tintColor = .systemOrange
            let button = UIButton()
            var configuration = UIButton.Configuration.plain()
            configuration.title = "Enter verification code"
            configuration.baseForegroundColor = .tintColor
            button.configuration = configuration
            
            stack.addArrangedSubview(button)
            
            button.addTarget(self, action: #selector(onEnterCodeVerification), for: .touchUpInside)
        })
    }
    
    internal func applyRequestedVerificationPanel() {
        (self.navigationController as? NavBarController)?.configureAdditionalPanel({ barVc, stack in
            barVc.indicatorIcon.setImage(UIImage(systemName: "exclamationmark.triangle.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            barVc.indicatorIcon.tintColor = .systemOrange
            let button = UIButton()
            var configuration = UIButton.Configuration.plain()
            configuration.title = "Outgoing verification request"
            configuration.baseForegroundColor = .tintColor
            button.configuration = configuration
            
            stack.addArrangedSubview(button)
            
            button.addTarget(self, action: #selector(onRequestedVerification), for: .touchUpInside)
        })
    }
    
    internal func applyRequestingVerificationPanel() {
        (self.navigationController as? NavBarController)?.configureAdditionalPanel({ barVc, stack in
            barVc.indicatorIcon.setImage(UIImage(systemName: "exclamationmark.triangle.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            barVc.indicatorIcon.tintColor = .systemOrange
            let button = UIButton()
            var configuration = UIButton.Configuration.plain()
            configuration.title = "Accept verification request"
            configuration.baseForegroundColor = .tintColor
            button.configuration = configuration
            
            stack.addArrangedSubview(button)
            
            button.addTarget(self, action: #selector(onRequestingVerification), for: .touchUpInside)
            
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
        })
    }
    
    internal func applyShouldRequestVerificationPanel(){
        (self.navigationController as? NavBarController)?.configureAdditionalPanel({ barVc, stack in
            barVc.indicatorIcon.setImage(UIImage(systemName: "exclamationmark.triangle.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            barVc.indicatorIcon.tintColor = .systemOrange
            let button = UIButton()
            var configuration = UIButton.Configuration.plain()
            configuration.title = "Verify contact"
            configuration.baseForegroundColor = .tintColor
            button.configuration = configuration
            
            stack.addArrangedSubview(button)
            
            button.addTarget(self, action: #selector(onShouldRequestVerification), for: .touchUpInside)
        })
    }
    
    internal func applyAcceptedVerification() {
        (self.navigationController as? NavBarController)?.configureAdditionalPanel({ barVc, stack in
//            barVc.indicatorIcon.setImage(UIImage(systemName: "exclamationmark.triangle.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
//            barVc.indicatorIcon.tintColor = .systemOrange
            let button = UIButton()
            var configuration = UIButton.Configuration.plain()
            configuration.title = "Show verification code"
            configuration.baseForegroundColor = .tintColor
            button.configuration = configuration
            
            stack.addArrangedSubview(button)
            
            button.addTarget(self, action: #selector(onAcceptedVerification), for: .touchUpInside)
        })
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
        }
        (self.navigationController as? NavBarController)?.hideAdditionalPanel(animated: true)
    }
}
