//
//  ChatViewController+VerifyFlow.swift
//  xabber
//
//  Created by Игорь Болдин on 02.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import CocoaLumberjack

extension ChatViewController {
    @objc
    internal func onRequestedVerification(_ sender: UIButton) {
        
    }
    
    @objc
    internal func onEnterCodeVerification(_ sender: UIButton) {
        do {
            let realm = try WRealm.safe()
            let instance = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid).first
            if instance == nil {
                return
            }
            
            let sid = instance!.sid
            let deviceId = String(instance!.opponentDeviceId)
            
            let vc = VerificationViewController()
            vc.owner = self.owner
            vc.jid = self.jid
            vc.sid = sid
            vc.state = .receivedRequestAccept
            vc.deviceId = deviceId
            
            showModal(vc, parent: self)
            
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        
    }
    
    @objc
    internal func onRequestingVerification(_ sender: UIButton) {
        do {
            let realm = try WRealm.safe()
            let instance = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid).first
            if instance == nil {
                return
            }
            
            let sid = instance!.sid
            let deviceId = String(instance!.opponentDeviceId)
            
            let vc = VerificationViewController()
            vc.owner = self.owner
            vc.jid = self.jid
            vc.sid = sid
            vc.deviceId = deviceId
            
            showModal(vc, parent: self)
            
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    @objc
    internal func onShouldRequestVerification(_ sender: UIButton) {
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.akeManager.sendVerificationRequest(jid: self.jid)
        })
        self.topPanelState.accept(.none)
    }
    
    @objc
    internal func onAcceptedVerification(_ sender: UIButton) {
        do {
            let realm = try WRealm.safe()
            let instance = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", self.owner, self.jid).first
            if instance == nil {
                return
            }
            
            let sid = instance!.sid
            let deviceId = String(instance!.opponentDeviceId)
            let code = instance!.code
            
            let vc = VerificationViewController()
            vc.owner = self.owner
            vc.jid = self.jid
            vc.sid = sid
            vc.deviceId = deviceId
            vc.state = .acceptedRequest
            vc.code = code
            
            showModal(vc, parent: self)
            
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
}
