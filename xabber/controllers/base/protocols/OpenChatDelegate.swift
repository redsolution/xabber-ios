//
//  OpenChatDelegate.swift
//  xabber
//
//  Created by Игорь Болдин on 05.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation

protocol OpenChatDelegate {
    func open(owner: String, jid: String, conversationType: ClientSynchronizationManager.ConversationType, forwarded messages: [String])
}
