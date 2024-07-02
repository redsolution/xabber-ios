//
//  ChatViewController+VerifyFlow.swift
//  xabber
//
//  Created by Игорь Болдин on 02.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit

extension ChatViewController {
    @objc
    internal func onRequestedVerification(_ sender: UIButton) {
        
    }
    
    @objc
    internal func onEnterCodeVerification(_ sender: UIButton) {
        
    }
    
    @objc
    internal func onRequestingVerification(_ sender: UIButton) {
        
    }
    
    @objc
    internal func onShouldRequestVerification(_ sender: UIButton) {
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.akeManager.sendVerificationRequest(jid: self.jid)
        })
        self.topPanelState.accept(.requestedVerification)
    }
    
}
