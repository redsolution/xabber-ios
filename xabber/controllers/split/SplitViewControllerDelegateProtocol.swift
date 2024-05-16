//
//  SplitViewControllerDelegateProtocol.swift
//  xabber
//
//  Created by Игорь Болдин on 16.04.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation

protocol SplitViewControllerDelegate {
    func onOpenChat(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType)
}
