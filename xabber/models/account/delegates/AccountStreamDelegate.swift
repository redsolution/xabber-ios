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
import XMPPFramework
import UserNotifications
import Alamofire

extension Account: XMPPStreamDelegate {
    
    
    func xmppStreamDidConnect(_ stream: XMPPStream) {
        AccountManager.shared.changeNewUserState(for: self.jid, to: .startConnection)
        func reconnect(_ error: Error) {
            self.statusMessage.accept("Offline")
            self.delayedConnectTimer?.invalidate()
            self.delayedConnectTimer = Timer(timeInterval: 3,
                                             target: self,
                                             selector: #selector(self.connect),
                                             userInfo: nil,
                                             repeats: false)
            RunLoop.main.add(self.delayedConnectTimer!, forMode: RunLoop.Mode.default)
            AccountManager.shared.changeNewUserState(for: self.jid, to: .failure(error.localizedDescription))
        }
        
        func invalidate() {
//            self.tokenWasInvalidated()
        }
        delayedConnectTimer?.invalidate()
        delayedConnectTimer = nil
//        DispatchQueue.main.async {
//            ToastPresenter(message: "Stream connected").present(animated: true)
//        }
        let creditionalsItem = CredentialsManager.shared.getItem(for: self.jid)
        switch creditionalsItem.kind {
        case .password:
            do {
                if let password = creditionalsItem.creditionalString {
                    if stream.supportsHOTPAuthentication {
                        if let secret = creditionalsItem.getSecret() {
                            stream.xabberDeviceSecret = secret
                        }
                        stream.shouldRegisterDevice = true
                        stream.shouldRequestXToken = false
                    } else if stream.supportsXTokenAuthentication {
                        stream.shouldRequestXToken = true
                        stream.shouldRegisterDevice = false
                    } else {
                        stream.shouldRequestXToken = false
                        stream.shouldRegisterDevice = false
                    }
                    try stream.authenticate(withPassword: password)
                    AccountManager.shared.changeNewUserState(for: self.jid, to: .connect)
                } else {
                    invalidate()
                }
            } catch {
                reconnect(error)
            }
            break
        case .token:
            creditionalsItem.use {
                [unowned self] (isInvalidated, item) in
                if isInvalidated {
                    invalidate()
                }
                do {
                    if let token = item.creditionalString {
                        creditionalsItem.incrementCounter()
                        stream.shouldRequestXToken = false
                        stream.shouldRegisterDevice = false
                        try stream.authenticate(withXabberToken: token, counter: item.counter)
                        
                        AccountManager.shared.changeNewUserState(for: self.jid, to: .connect)
                    } else {
                        invalidate()
                    }
                } catch {
                    item.decrementCounter()
                    reconnect(error)
                }
            }
            break
        case .secret:
            creditionalsItem.use {
                [unowned self] (isInvalidated, item) in
                if isInvalidated {
                    invalidate()
                }
                do {
//                    DispatchQueue.main.async {
//                        ToastPresenter(message: "Stream try get secret").present(animated: true)
//                    }
                    if let secret = item.creditionalString {
                        creditionalsItem.incrementCounter()
                        let counter = creditionalsItem.counter
//                        DispatchQueue.main.async {
//                            ToastPresenter(message: "Stream increment counter").present(animated: true)
//                        }
                        stream.shouldRegisterDevice = false
                        stream.shouldRequestXToken = false
                        try stream.authenticate(withHOTPSecret: secret, counter: counter)
                        AccountManager.shared.changeNewUserState(for: self.jid, to: .connect)
//                        DispatchQueue.main.async {
//                            ToastPresenter(message: "Stream try auth").present(animated: true)
//                        }
                    } else {
                        invalidate()
                        
//                        DispatchQueue.main.async {
//                            ToastPresenter(message: "Stream invalidated").present(animated: true)
//                        }
                    }
                } catch {
                    item.decrementCounter()
                    reconnect(error)
//                    DispatchQueue.main.async {
//                        ToastPresenter(message: "Stream try reconnect").present(animated: true)
//                    }
                }
            }
            
        }
    }

    func xmppStreamConnectDidTimeout(_ sender: XMPPStream) {
//        resetStream()
//        configureStream()
        do {
            try sender.connect(withTimeout: 1)
        } catch {
            self.delayedConnectTimer?.invalidate()
            self.delayedConnectTimer = nil
            if self.delayedConnectTimer == nil {
                self.delayedConnectTimer = Timer(timeInterval: 3, target: self, selector: #selector(self.connect), userInfo: nil, repeats: false)
                RunLoop.main.add(self.delayedConnectTimer!, forMode: RunLoop.Mode.default)
            }
        }
        
    }
    
    func xmppStreamWillConnect(_ sender: XMPPStream) {
        AccountManager.shared.markAsConnecting(jid: self.jid)
        let reachabilityManager = NetworkReachabilityManager()
        reachabilityManager?.startListening()
        reachabilityManager?.listener = {
            _ in
            if let isNetworkReachable = reachabilityManager?.isReachable, isNetworkReachable == true {
                if self.xmppStream.isDisconnected {
//                    self.asyncConnect()
                }
            } else {
//                self.statusMessage.accept("Wait for network")
//                self.statusMessage.accept("Connecting")
                if self.delayedConnectTimer == nil {
                    self.delayedConnectTimer = Timer(timeInterval: 3, target: self, selector: #selector(self.connect), userInfo: nil, repeats: false)
                    RunLoop.main.add(self.delayedConnectTimer!, forMode: RunLoop.Mode.default)
                }
            }
        }
        
    }

    func xmppStreamDidAuthenticate(_ sender: XMPPStream) {
        self.didAuthenticate()
        if let resource = sender.myJID?.resource {
            self.devices.updateMyDevice(resource: resource)
        }
        CredentialsManager.shared.getItem(for: self.jid).release(error: false)
        AccountManager.shared.markAsAuthencticated(jid: self.jid)
        AccountManager.shared.changeNewUserState(for: self.jid, to: .auth)
        PushNotificationsManager.setAccountStateForPush(jid: self.jid, active: true)
        
    }

    
    func xmppStreamDidReceive(_ sender: XMPPStream, streamFeatures features: DDXMLElement) {
        print("Features:", features.prettyXMLString())
        syncManager.checkAvailability(features)
        devices.setAvailable(features)
    }
    
    
    
    func xmppStream(_ sender: XMPPStream, alternativeResourceForConflictingResource conflictingResource: String) -> String? {
        return "\(conflictingResource)_\(UUID().uuidString)"
    }
    
    func xmppStream(_ sender: XMPPStream, didNotAuthenticate error: DDXMLElement) {
        CredentialsManager.shared.getItem(for: self.jid).release(error: true)
        self.statusState.accept(.offline)
        self.resetConfigs()
//        self.xmppStream.abortConnecting()
//        self.disconnect()
        self.didReceiveError(error)
    }

    func xmppStreamWasTold(toDisconnect sender: XMPPStream) {
//        self.statusMessage.accept("Disconnect")
        self.statusMessage.accept("Offline")
        self.statusState.accept(.offline)
        self.resetConfigs()
        self.carbonsEnabled = false
//        self.lastChats.resetSyncedStatus()
        self.groupchats.reset()
    }
    
    func xmppStream(_ sender: XMPPStream, didReceiveError error: DDXMLElement) {
        AccountManager.shared.changeNewUserState(for: sender.myJID?.bare ?? self.jid, to: .streamError(error.elements(forXmlns: "urn:ietf:params:xml:ns:xmpp-streams").first?.name ?? "error"))
        if self.devices.isAvailable {
            if error.element(forName: "conflict") != nil && error.element(forName: "conflict") != nil && error.element(forName: "text")?.stringValue == "Device was revoked"{
                tokenWasInvalidated()
//                sender.disconnect()
//                sender.abortConnecting()
                self.reconnect.autoReconnect = false
                self.reconnectTimer?.invalidate()
                self.reconnectTimer = nil
            }
        }
        if error.element(forName: "policy-violation") != nil {
            if AccountManager.shared.newAccountJid != sender.myJID?.bare {
                ApplicationStateManager.shared.checkApplicationBlockedState(for: sender.myJID!.bare)
            }
            
//            AccountManager.shared.disable(jid: self.jid)
            self.reconnectTimer?.invalidate()
            self.reconnectTimer = nil
            self.delayedConnectTimer?.invalidate()
            self.delayedConnectTimer = nil
//            self.disconnect(hard: true)
            self.reconnect.stop()
            XMPPUIActionManager.shared.disable(self.jid)
        }
    }
    
    func xmppStreamDidDisconnect(_ sender: XMPPStream, withError error: Error?) {
        let nserror = error as NSError?
        CredentialsManager.shared.getItem(for: self.jid).release(error: false)
        PushNotificationsManager.setAccountStateForPush(jid: self.jid, active: false)
//        RunLoop.main.perform {
//            self.presences.resetResources(commitTransaction: true)
//        }
        self.isPresenceUpdateRequestSend = false
        self.resetModules()
        self.resetConfigs()
        self.statusState.accept(.offline)
        if ["kCFStreamErrorDomainNetServices", "kCFStreamErrorDomainNetDB"].contains(nserror?.domain ?? "none") {
            self.statusMessage.accept("offline")
            AccountManager.shared.changeNewUserState(for: self.jid, to: .failure("Server not found"))
        } else {
            self.statusMessage.accept("Offline")
            if error != nil {
                self.delayedConnectTimer = Timer(timeInterval: 3, target: self, selector: #selector(self.connect), userInfo: nil, repeats: false)
                RunLoop.main.add(self.delayedConnectTimer!, forMode: RunLoop.Mode.default)
            }
        }
//        ClientSynchronizationManager.makeAllChatsNotSynced(for: self.jid)
    }
    
    func xmppStream(_ sender: XMPPStream, didSend iq: XMPPIQ) {
        if SettingManager.logEnabled {
            DDLogInfo("S. IQ: to \(iq.to?.bare ?? "none"), from \(iq.from?.bare ?? "none"), type \(iq.element(forName: "query")?.xmlns() ?? iq.children?.first?.name ?? "none")")
        }
    }

    func xmppStream(_ sender: XMPPStream, didReceive iq: XMPPIQ) -> Bool {
        switch true {
        case self.syncManager.read(withIQ: iq):
            _ = self.syncManager.checkNextPage(sender, in: iq)
            break
        case self.avatarManager.read(withIQ: iq): break
        case self.roster.read(withIQ: iq): break
        case self.mam.read(sender, withIQ: iq):
            self.messages.storeMessagesNow()
            break
        case self.push.read(withIQ: iq):
//            AccountManager.shared.markAsConnected(jid: jid)
            break
        case self.devices.read(withIQ: iq):
//            AccountManager.shared.markAsConnected(jid: jid)
            self.omemo.checkInfo()
            break
        case self.xTokens.read(withIQ: iq): break
        case self.groupchats.read(withIQ: iq): break
        case (self.httpUploads as! AbstractXMPPManager).read(withIQ: iq): break
        case self.blocked.read(withIQ: iq): break
        case self.msgDeleteManager.read(withIQ: iq): break
        case self.vcards.read(withIQ: iq):
            _ = self.avatarManager.readFromVcard(iq)
            break
        case self.ping.read(withIQ: iq): break
        case self.disco.read(withIQ: iq):
            AccountManager.shared.markAsConnected(jid: jid)
            break
        case (self.xUploads as! AbstractXMPPManager).read(withIQ: iq): break
        case self.omemo.read(withIQ: iq): break
        case self.x509Manager.read(withIQ: iq): break
        default: return false
        }
        return true
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive presence: XMPPPresence) {
        if presence.from?.bare == sender.myJID?.bare {
            _ = self.devices.read(withPresence: presence, commitTransaction: true)
        }
        if self.groupchats.read(sender, withPresence: presence){
            return
        }
        if self.presences.read(withPresence: presence) {
            return
        }
        if SettingManager.logEnabled {
            DDLogInfo("R. presence: to \(presence.to?.bare ?? "none"), from \(presence.from?.bare ?? "none")")
        }
    }
    
    func xmppStream(_ sender: XMPPStream, didSend presence: XMPPPresence) {
        if self.groupchats.success(presence: presence) {
            return
        }
        //self.presences.read(outgoingPresence: presence)
        if SettingManager.logEnabled {
            DDLogInfo("S. presence: to \(presence.to?.bare ?? "none"), from \(presence.from?.bare ?? "none")")
        }
    }
    
    func xmppStream(_ sender: XMPPStream, willReceive message: XMPPMessage) -> XMPPMessage? {
        print("MESSAGE")
        return message
    }
   
    func xmppStreamDidFilterStanza(_ sender: XMPPStream) {
        print(#function)
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive message: XMPPMessage) {
        print("MESSAGE RECV")
//        DispatchQueue(
//            label: "com.xabber.queue.m.\(message.elementID ?? xmppStream.generateUUID)",
//            qos: .background,
//            attributes: [],//.concurrent,
//            autoreleaseFrequency: .workItem,
//            target: queue
//        ).async {
            if SettingManager.logEnabled {
                DDLogInfo("R. message: to \(message.to?.bare ?? "none"), from \(message.from?.bare ?? "none"), id \(message.elementID ?? "none")")
            }
            //pass delayed message from offline storage, cos it doesnt have unique stanza id
            if message.delayedDeliveryReasonDescription == "Offline Storage" {
                return
            }
            
            switch message.messageType ?? .chat {
                case .chat, .normal:

                if self.groupchats.readMessage(withMessage: message) {
                    return
                }
                if self.chatStates.read(withMessage: message) {
                    return
                } else if isArchivedMessage(message) {
                    
                    if let bareMessage = getArchivedMessageContainer(message) {
                        if VoIPManager.shared.onReceiveMessage(bareMessage, owner: self.jid, archivedDate: getDeliveryTime(bareMessage, owner: self.jid) ?? getDelayedDate(message)) {
                            return
                        } else if self.groupchats.readInvite(in: bareMessage, date: getDelayedDate(message) ?? Date(), isRead: nil) {
                            return
                        }
                        if self.xTokens.receive(sender, withMessage: bareMessage) {
                            
                        }
                    }
                    if self.omemo.didReceiveOmemoMessage(message) {
                        return
                    } else if self.chatMarkers.read(withMessage: message) {
                        return
                    } else {
                        self.messages.receiveArchived(message)
                    }
                } else if isCarbonCopy(message) {
                    if let bareMessage = getCarbonCopyMessageContainer(message) {
                        if self.chatStates.read(withMessage: bareMessage) {
                            return
                        } else if VoIPManager.shared.onReceiveMessage(bareMessage, owner: self.jid, archivedDate: getDeliveryTime(bareMessage, owner: self.jid) ?? getDelayedDate(message), runtime: true, outgoing: true) {
                            return
                        }
                    }
                    if self.omemo.didReceiveOmemoMessage(message) {
                        return
                    } else {
                        self.messages.receiveCarbon(message)
                    }
                    
                } else if isCarbonForwarded(message) {
                    if let bareMessage = getCarbonForwardedMessageContainer(message) {
                        if VoIPManager.shared.onReceiveMessage(bareMessage, owner: self.jid, archivedDate: getDeliveryTime(bareMessage, owner: self.jid) ?? getDelayedDate(message), runtime: true, outgoing: true) {
                            return
                        } else if self.deliveryReceipts.read(withMessage: bareMessage) {
                            return
                        } else if self.chatMarkers.read(withMessage: message) {
                            return
                        } else if self.chatStates.read(withMessage: bareMessage) {
                            return
                        } else if self.groupchats.readInvite(in: bareMessage, date: getDelayedDate(message) ?? Date(), isRead: nil) {
                            return
                        }
                    }
                    if self.omemo.didReceiveOmemoMessage(message) {
                        return
                    } else {
                        self.messages.receiveCarbonForwarded(message)
                    }
                } else {
                    if VoIPManager.shared.onReceiveMessage(message, owner: self.jid, archivedDate: nil, runtime: true) {
                        return
                    }
                    if self.deliveryReceipts.read(withMessage: message) {
                        return
                    }
                    if self.chatMarkers.read(withMessage: message) {
                        return
                    }
                    if self.groupchats.readInvite(in: message, date: Date(), isRead: false) {
                        return
                    }
                    self.devices.readMessage(message: message)
                    if self.xTokens.receive(sender, withMessage: message) {
                        
                    }
                    if self.omemo.didReceiveOmemoMessage(message) {
                        return
                    } else {
                        self.messages.receiveRuntime(message)
                    }
                }
            case .groupchat:
                break
            case .headline:
                if self.deliveryManager.read(headline: message) {
                    return
                }
                if self.devices.readHeadline(message) {
                    return
                }
                if self.x509Manager.readHeadline(message) {
                    return
                }
                if self.omemo.onContactDeviceListReceiveHeadline(message) {
                    return
                }
                if self.omemo.onContactDeviceReceiveHeadline(message) {
                    return
                }
                if self.avatarManager.readMessage(message) {
                    return
                }
                if self.msgDeleteManager.read(headline: message) {
                    return
                }
            case .error:
                if self.deliveryManager.read(error: message) {
                    return
                }
                if self.messages.read(error: message) {
                    return
                }
            }
//        }
    }

    func xmppStream(_ sender: XMPPStream, willSend message: XMPPMessage) -> XMPPMessage? {
        return message
    }
    
    func xmppStream(_ sender: XMPPStream, didSend message: XMPPMessage) {
        if SettingManager.logEnabled {
            DDLogInfo("S. message: to \(message.to?.bare ?? "none"), from \(message.from?.bare ?? "none"), id \(message.elementID ?? "none")")
        }
    }
    
    func xmppStream(_ sender: XMPPStream, didFailToSend message: XMPPMessage, error: Error) {
//        self.messages.changeMessageState(message, to: .error)
        self.messages.fail(message: message)
    }

    func xmppStream(_ sender: XMPPStream, didFailToSend iq: XMPPIQ, error: Error) {
        if self.groupchats.fail(iq: iq) {
            return
        }
    }

    func xmppStream(_ sender: XMPPStream, didFailToSend presence: XMPPPresence, error: Error) {
        if self.groupchats.fail(presence: presence) {
            return
        }
    }

    func xmppStreamWasTold(toAbortConnect sender: XMPPStream) {

    }
    
    
    func xmppStream(_ sender: XMPPStream, willSecureWithSettings settings: NSMutableDictionary) {
        settings[GCDAsyncSocketManuallyEvaluateTrust] = true
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
//        print(trust)
        completionHandler(true)
        
//        if !(SettingManager.shared.getKey(for: self.jid, scope: .trustCertificatePolicy, key: "allowed") ?? "" == "true") {
//            let domain = sender.myJID?.domain ?? ""
//            let jid = self.jid
//            DispatchQueue.main.async {
//                if let vc = UIApplication.getTopMostViewController() {
//                    TrustCertificatePresenter(domain: domain, jid: jid).present(in: vc, animated: true, completion: completionHandler)
//                }
//            }
//        } else {
//            completionHandler(true)
//        }
    }
    
    func xmppStreamRequestXToken(_ elementId: String) {
        self.xTokens.tokensSupport = true
        self.xTokens.queryIds.insert(elementId)
    }
    
    func xmppStreamResponseXToken(_ iq: XMPPIQ) {
        _ = self.xTokens.read(withIQ: iq)
    }
    
    func xmppStreamRequestDeviceRegistration(_ elementId: String) {
        self.devices.queryIds.insert(elementId)
    }
    
    func xmppStreamResponseDeviceRegistration(_ iq: XMPPIQ) {
        _ = self.devices.read(withIQ: iq)
    }
    
    func xmppStream(_ sender: XMPPStream, didReceiveCustomElement element: DDXMLElement) {
        if element.name == "resumed" {
//            DispatchQueue.main.async {
//                ToastPresenter(message: "Resumed received").present(animated: true)
//            }
        }
    }
    
}


extension Account: XMPPStreamManagementDelegate {
    func xmppStreamManagement(_ sender: XMPPStreamManagement, wasEnabled enabled: DDXMLElement) {
//        DispatchQueue.main.async {
//            ToastPresenter(message: "SM session enabled").present(animated: true)
//        }
    }
    
    func xmppStreamManagement(_ sender: XMPPStreamManagement, wasNotEnabled failed: DDXMLElement) {
        AccountManager.shared.markAsConnecting(jid: self.jid)
        
        self.presence()
        if failed.element(forName: "item-not-found") != nil {
            DispatchQueue.main.async {
                ToastPresenter(message: "SM session not found").present(animated: true)
            }
        } else {
            DispatchQueue.main.async {
                ToastPresenter(message: "SM session error. \(failed.children?.compactMap({ return $0.name }).reduce(" ", +) ?? "" )").present(animated: true)
            }
        }
        self.roster.request(xmppStream)
        self.queue.asyncAfter(deadline: .now() + 1) {
            _ = self.syncManager.sync(self.xmppStream)
            self.devices.requestList(self.xmppStream)
        }
    }
}
