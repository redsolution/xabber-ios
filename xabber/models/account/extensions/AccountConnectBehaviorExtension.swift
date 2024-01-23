//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import UIKit
import XMPPFramework
import RealmSwift

extension Account {
    
    func restore() {
//        if self.xmppStream.isAuthenticated && self.xmppStream.isConnected {
//            return
//        }
//        if self.xmppStream.isAuthenticated {
//            return
//        }
//        self.disconnect(hard: true)
//        self.resetStream()
//        self.xmppStream.asyncSocket.disconnect()
        self.asyncConnect()
    }
    
    func didAuthenticate() {
        registerRegularPushForAccount()
//        DispatchQueue.main.async {
//            ToastPresenter(message: "Stream authenticated").present(animated: true)
//        }
        self.configureBase()
//        self.queue.asyncAfter(deadline: .now() + 0.5) {
        XMPPUIActionManager.shared.open(owner: self.jid, force: true)
        if self.sm.didResume {
            AccountManager.shared.markAsConnected(jid: self.jid)
//            self.presence()
//            DispatchQueue.main.async {
//                ToastPresenter(message: "SM did resume").present(animated: true)
//            }
//            self.push.enable(xmppStream: self.xmppStream) { _ in
//                
//            }
            _ = self.syncManager.sync(self.xmppStream)
        } else {
//            DispatchQueue.main.async {
//                ToastPresenter(message: "Synchronization").present(animated: true)
//            }
            self.configureExtensions()
            self.disco.configure(self.xmppStream)
            if self.roster.version != nil {
                if self.syncManager.isAvailable {
                    self.statusMessage.accept("Synchronization")
                }
            }
            self.roster.request(self.xmppStream)
            self.queue.asyncAfter(deadline: .now() + 1) {
                _ = self.syncManager.sync(self.xmppStream)
                self.devices.requestList(self.xmppStream)
            }
        }
//        }
    }
    
    func didReceivePing(withIq iq: XMPPIQ) -> Bool {
        if iq.xmlns() == "jabber:client"
            && iq.iqType == .get
            && iq.element(forName: "ping") != nil {
            self.xmppStream.send(XMPPIQ(iqType: .result, to: iq.from, elementID: iq.elementID))
            return true
        }
        return false
    }
    
    func didReceiveError(_ error: DDXMLElement) {
        func failToConnect(_ errorName: String) {
            self.reconnect.autoReconnect = false
            self.disconnect(hard: true)
            switch errorName {
                case "conflict":
                    if self.devices.isAvailable {
                        self.tokenWasInvalidated()
                    } else {
                        self.updateResource("\(self.resource)\(arc4random() % 16380)")
                    }
                case "credentials-expired":
                    self.tokenWasInvalidated()
                case "policy-violation":
                    if CommonConfigManager.shared.config.should_block_application_when_subscribtion_end {
                        SubscribtionsManager.shared.checkXMPPAccountState(jid: self.jid) {
                            result in
                            if result {
                                self.statusMessage.accept(error.element(forName: "text")?.stringValue ?? "Offline")
                            } else {
                                self.statusMessage.accept("Subscription expired")
                                DispatchQueue.main.async {
                                    SubscribtionsPresenter().present(animated: true)
                                }
                            }
                        }
                    } else {
                        self.statusMessage.accept(error.element(forName: "text")?.stringValue ?? "Offline")
                    }
                case "not-authorized":
//                    if self.devices.isAvailable {
//                        self.tokenWasInvalidated()
//                        return
//                    }
                    if error.element(forName: "text")?.stringValue == "Device was revoked" {
                        self.tokenWasInvalidated()
                        return
                    }
                    self.statusMessage.accept("Incorrect username or password")
                    if self.jid != AccountManager.shared.newAccountJid {
                        self.tokenShouldUpdate()
                    }
                    AccountManager
                        .shared
                        .changeNewUserState(for: self.jid, to: .failure(self.statusMessage.value))
                default:
                    self.statusMessage.accept("Offline")
                    AccountManager
                        .shared
                        .changeNewUserState(for: self.jid, to: .failure(error.element(forName: "text")?.stringValue ?? "Unknown error"))
            }
        }
        
        func tryToReconnect(_ errorName: String) {
            self.reconnect.autoReconnect = true
            self.queue.asyncAfter(deadline: .now() + 1) {
                self.reconnect.manualStart()
            }
        }
        
        if let errorName = error
            .elements(forXmlns: "urn:ietf:params:xml:ns:xmpp-streams")
            .filter({ $0.name != "text" })
            .first?
            .name {
            switch errorName {
                case "conflict",
                    "credentials-expired",
                    "policy-violation",
                    "not-authorized":
                    failToConnect(errorName)
                default:
                    tryToReconnect(errorName)
            }
        }
        if let errorName = error
            .elements(forXmlns: "urn:ietf:params:xml:ns:xmpp-sasl")
            .filter({ $0.name != "text" })
            .first?
            .name {
            switch errorName {
                case "conflict",
                    "credentials-expired",
                    "policy-violation",
                    "not-authorized":
                    failToConnect(errorName)
                default:
                    tryToReconnect(errorName)
            }
        }
        CredentialsManager.shared.getItem(for: self.jid).release(error: true)
        self.resetConfigs()
    }
    
    public final func tokenShouldUpdate() {
        self.reconnect.autoReconnect = false
        self.disconnect(hard: true)
        DispatchQueue.main.async {
            CredentialsExpiredPresenter(jid: self.jid).present(animated: true)
        }
    }
    
    public final func tokenWasInvalidated() {
        NotificationCenter.default.post(name: ApplicationStateManager.tokenWasExpired, object: self.jid)
    }
    
    public final func didReceiveRoster() {
        self.queue.asyncAfter(deadline: .now() + 1) {
            self.presence()
            self.queue.asyncAfter(deadline: .now() + 1) {
                self.updateExtensions()
            }
        }
        if sm.canResumeStream() {
            return
        }
        if self.syncManager.isAvailable {
            self.statusMessage.accept("Synchronization")
        }
        if !self.isSynced,
           !self.syncManager.isAvailable {
            self.isSynced = true
            self.queue.asyncAfter(deadline: .now() + 2) {
                AccountManager.shared.changeNewUserState(for: self.jid, to: .dataLoaded)
            }
            if AccountManager.shared.activeUsers.value.count == 1 {
                XMPPUIActionManager.shared.performRequest(owner: self.jid, action: { (stream, session) in
                    session.retract?.enable(stream)
                }, fail: {
                    self.msgDeleteManager.enable(self.xmppStream)
                })
            } else {
                self.msgDeleteManager.enable(xmppStream)
            }
            if xmppStream.myPresence == nil {
                self.requestInitialMAM()
            }
            
        }
    }
}
