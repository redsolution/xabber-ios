//
//  XMPPUIActionManager+Delegate.swift
//  xabber
//
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

extension XMPPUIActionManager: XMPPStreamDelegate {
    func xmppStreamDidConnect(_ sender: XMPPStream) {
        canSendStanzas = false
        guard let jid = currentJid else {
            self.stream.disconnect()
            self.stream.myJID = nil
            self.currentJid = nil
//            self.password = nil
            return
        }
        func reconnect(_ error: Error) {
//            fatalError()
//            sender.disconnect()
//            try? sender.connect(withTimeout: 5)
            self.close(soft: false)
        }
        
        func invalidate() {
            self.close(soft: false)
//            fatalError()
        }
        
        let creditionalsItem = CredentialsManager.shared.getItem(for: jid)
        switch creditionalsItem.kind {
        case .password:
            do {
                if let password = creditionalsItem.creditionalString {
                    stream.shouldRequestXToken = false
                    stream.shouldRegisterDevice = false
                    try stream.authenticate(withPassword: password)
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
                        
                    } else {
                        item.decrementCounter()
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
                    if let secret = item.creditionalString {
                        creditionalsItem.incrementCounter()
                        let counter = creditionalsItem.counter
                        stream.shouldRegisterDevice = false
                        stream.shouldRequestXToken = false
                        try stream.authenticate(withHOTPSecret: secret, counter: counter)
                    } else {
                        item.decrementCounter()
                        invalidate()
                    }
                } catch {
                    print(error.localizedDescription)
                    item.decrementCounter()
                    reconnect(error)
                }
            }
        }
        print("UI STREAM CONNECTED")
    }
    
    func xmppStreamDidAuthenticate(_ sender: XMPPStream) {
        guard let jid = sender.myJID?.bare else { return }
        CredentialsManager.shared.getItem(for: jid).release(error: false)
        canSendStanzas = true
        print("UI STREAM AUTHENTICATED")
    }
    
    func xmppStream(_ sender: XMPPStream, didNotAuthenticate error: DDXMLElement) {
        self.didReceiveError(error)
//        else {
//            self.restore()
//        }
    }
    
    func xmppStream(_ sender: XMPPStream, didReceiveError error: DDXMLElement) {
//        if error.element(forName: "policy-violation") != nil {
//            self.disable(self.currentJid ?? "")
//        }
//        if (AccountManager.shared.find(for: sender.myJID!.bare)?.devices.isAvailable ?? false) {
//            if error.element(forName: "conflict") != nil && error.element(forName: "text")?.stringValue == "Device was revoked" {
//                tokenWasInvalidated()
//                sender.disconnect()
////                sender.abortConnecting()
//            }
//        }
        self.didReceiveError(error)
    }
    
//    func xmppStream(_ sender: XMPPStream, willSend iq: XMPPIQ) -> XMPPIQ? {
//        print("UI SEND: \(iq.prettyXMLString ?? "")")
//        return iq
//    }
    
    func xmppStream(_ sender: XMPPStream, willReceive iq: XMPPIQ) -> XMPPIQ? {
//        print("WILL REC IQ: \(iq.prettyXMLString ?? "")")
        return iq
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive iq: XMPPIQ) -> Bool {
//        print("UI RECV: \(iq.prettyXMLString ?? "")" )
        switch true {
//        case (self.sync?.read(withIQ: iq) ?? false): return true
        case (self.mam?.read(stream, withIQ: iq) ?? false):
                self.messages?.storeMessagesNow()
                return true
        case (self.groupchat?.read(sender, withIQ: iq) ?? false): return true
        case (AccountManager.shared.find(for: self.currentJid ?? "")?.omemo.read(withIQ: iq) ?? false):
            return true
        case (self.vcardManager?.read(withIQ: iq) ?? false): return true
        case (self.blocked?.read(withIQ: iq) ?? false): return true
        case (self.retract?.read(withIQ: iq) ?? false): return true
        case (self.xtokens?.read(withIQ: iq) ?? false): return true
        case (self.devices?.read(withIQ: iq) ?? false): return true

        case (self.roster?.read(withIQ: iq) ?? false): return true
        case ((self.httpUploader as? AbstractXMPPManager)?.read(withIQ: iq) ?? false): return true

        case (self.omemo?.read(withIQ: iq) ?? false): return true
        default: return false
        }
    }
    
    func xmppStream(_ sender: XMPPStream, didSend iq: XMPPIQ) {
//        print("UI SEND: \(iq.prettyXMLString ?? "")")
    }
    
    func xmppStream(_ sender: XMPPStream, didFailToSend iq: XMPPIQ, error: Error) {
        _ = self.groupchat?.fail(iq: iq)
//        print("FAIL", iq.prettyXMLString())
    }
    
    func xmppStream(_ sender: XMPPStream, willSend message: XMPPMessage) -> XMPPMessage? {
//        print("UI STREAM WILL SEND MESSAGE \(message.prettyXMLString!)")
        return message
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive message: XMPPMessage) {
        if message.delayedDeliveryReasonDescription == "Offline Storage" {
            return
        }
        
        switch message.messageType ?? .chat {
        case .chat:
            if self.groupchat?.readMessage(withMessage: message) ?? false {
                return
            }
            if self.chatMarkers?.read(withMessage: message) ?? false {
                return
            }
            if isArchivedMessage(message) {
                if let bareMessage = getArchivedMessageContainer(message) {
                    if VoIPManager.shared.onReceiveMessage(bareMessage, owner: sender.myJID!.bare, archivedDate: getDeliveryTime(message, owner: sender.myJID!.bare) ?? getDelayedDate(message)) {
                        return
                    } else if self.groupchat?.readInvite(in: bareMessage, date: getDelayedDate(message) ?? Date(), isRead: nil) ?? false {
                        return
                    }
                }
                if (AccountManager.shared.find(for: sender.myJID!.bare)?.omemo.didReceiveOmemoMessage(message) ?? false) {
                    return
                } else {
                    self.messages?.receiveArchived(message)
                }
            } else {
                if VoIPManager.shared.onReceiveMessage(message, owner: sender.myJID!.bare, archivedDate: nil, runtime: true) {
                    return
                }
                if message.body?.isNotEmpty ?? false {
                    self.messages?.receiveRuntime(message)
                }
            }
        case .normal:
            break
        case .groupchat:
            break
        case .headline:
            _ = self.deliveryManager?.read(headline: message)
            _ = self.retract?.read(headline: message)
        case .error:
            _ = self.deliveryManager?.read(error: message)
        }
        
    }
    
    func xmppStreamDidReceive(_ sender: XMPPStream, streamFeatures features: DDXMLElement) {
        sync?.checkAvailability(features)
    }
    
    func xmppStreamDidDisconnect(_ sender: XMPPStream, withError error: Error?) {
        guard let jid = sender.myJID?.bare else { return }
        CredentialsManager.shared.getItem(for: jid).release(error: false)
    }
}
