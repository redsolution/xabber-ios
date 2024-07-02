//
//  ChatViewController+AdditionalNavbarPanel.swift
//  xabber
//
//  Created by Игорь Болдин on 01.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

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
            
            let blockButton = UIButton()
            var blockConfiguration = UIButton.Configuration.plain()
            blockConfiguration.title = "Block".localizeString(id: "contact_bar_block", arguments: [])
            blockConfiguration.baseForegroundColor = .systemRed
            blockButton.configuration = blockConfiguration
            
            stack.addArrangedSubview(addButton)
            stack.addArrangedSubview(blockButton)
        })
    }
    
    internal func applyRequestSubscribtionPanel() {
        (self.navigationController as? NavBarController)?.configureAdditionalPanel({ barVc, stack in
            barVc.indicatorIcon.setImage(UIImage(systemName: "person.wave.2.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            barVc.indicatorIcon.tintColor = .tintColor
            let requestButton = UIButton()
            var configuration = UIButton.Configuration.plain()
            configuration.title = "Request subscription".localizeString(id: "request_subscription", arguments: [])
            configuration.baseForegroundColor = .tintColor
            requestButton.configuration = configuration
            
            stack.addArrangedSubview(requestButton)
        })
    }
    
    internal func applyAllowSubscribtion() {
        (self.navigationController as? NavBarController)?.configureAdditionalPanel({ barVc, stack in
            barVc.indicatorIcon.setImage(UIImage(systemName: "person.wave.2.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            barVc.indicatorIcon.tintColor = .tintColor
            let acceptButton = UIButton()
            var configuration = UIButton.Configuration.plain()
            configuration.title = "Incoming subscription request".localizeString(id: "incoming_subscription_request", arguments: [])
            configuration.baseForegroundColor = .tintColor
            acceptButton.configuration = configuration
            
            stack.addArrangedSubview(acceptButton)
        })
    }
    
    internal func applyEnterCodePanel() {
        (self.navigationController as? NavBarController)?.configureAdditionalPanel({ barVc, stack in
            barVc.indicatorIcon.setImage(UIImage(systemName: "entry.lever.keypad.trianglebadge.exclamationmark.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            barVc.indicatorIcon.tintColor = .systemOrange
            let enterButton = UIButton()
            var configuration = UIButton.Configuration.plain()
            configuration.title = "Enter verification code"
            configuration.baseForegroundColor = .tintColor
            enterButton.configuration = configuration
            
            stack.addArrangedSubview(enterButton)
        })
    }
    
    internal func applyRequestedVerificationPanel() {
        (self.navigationController as? NavBarController)?.configureAdditionalPanel({ barVc, stack in
            barVc.indicatorIcon.setImage(UIImage(systemName: "exclamationmark.triangle.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
            barVc.indicatorIcon.tintColor = .systemOrange
            let acceptButton = UIButton()
            var configuration = UIButton.Configuration.plain()
            configuration.title = "Incoming verification request"
            configuration.baseForegroundColor = .tintColor
            acceptButton.configuration = configuration
            
            stack.addArrangedSubview(acceptButton)
        })
    }
    
    @objc
    final func additionalNavBArPanelCancelButtonTouchUpInside(_ sender: UIButton) {
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
        }
        (self.navigationController as? NavBarController)?.hideAdditionalPanel(animated: true)
    }
}
