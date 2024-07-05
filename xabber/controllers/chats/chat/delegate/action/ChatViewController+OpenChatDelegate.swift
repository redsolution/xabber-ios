//
//  ChatViewController+OpenChatDelegate.swift
//  xabber
//
//  Created by Игорь Болдин on 05.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation

extension ChatViewController: OpenChatDelegate {
    func open(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType, forwarded messages: [String]) {
        let vc = ChatViewController()
        vc.jid = jid
        vc.owner = owner
        vc.conversationType = conversationType
        vc.attachedMessagesIds.accept(messages)
        switch CommonConfigManager.shared.interfaceType {
            case .split:
                self.navigationController?.setViewControllers([vc], animated: true)
            case .tabs:
                if let rootVc = self.navigationController?.viewControllers.first {
                    self.navigationController?.setViewControllers([rootVc, vc], animated: true)
                } else {
                    self.navigationController?.setViewControllers([vc], animated: true)
                }
        }
    }
}
