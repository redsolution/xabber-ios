//
//  XMPPBackgroundTask+Delegate.swift
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

extension XMPPBackgroundTask: XMPPStreamDelegate {
    func xmppStreamDidConnect(_ sender: XMPPStream) {
        func reconnect(_ error: Error) {
//            fatalError()
            self.backgroundTaskStop()
        }
        
        func invalidate() {
//            fatalError()
            self.backgroundTaskStop()
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
                    item.release(.credentialRevoked)
                    invalidate()
                    return
                }
                do {
                    switch try XMPPStoredCredentialAuthenticator.authenticate(
                        stream: stream,
                        storage: item,
                        ownerJID: self.jid,
                        counterTracker: self.authenticationCounterTracker
                    ) {
                    case .started:
                        break
                    case .missingCredential:
                        self.authenticationCounterTracker.authenticationDidFail()
                        item.release(.authFailedRecoverable)
                        invalidate()
                    }
                } catch {
                    self.authenticationCounterTracker.authenticationDidFail()
                    item.release(.authFailedRecoverable)
                    reconnect(error)
                }
            }
            break
        case .secret:
            creditionalsItem.use {
                [unowned self] (isInvalidated, item) in
                if isInvalidated {
                    item.release(.credentialRevoked)
                    invalidate()
                    return
                }
                do {
                    switch try XMPPStoredCredentialAuthenticator.authenticate(
                        stream: stream,
                        storage: item,
                        ownerJID: self.jid,
                        counterTracker: self.authenticationCounterTracker
                    ) {
                    case .started:
                        break
                    case .missingCredential:
                        self.authenticationCounterTracker.authenticationDidFail()
                        item.release(.authFailedRecoverable)
                        invalidate()
                    }
                } catch {
                    self.authenticationCounterTracker.authenticationDidFail()
                    item.release(.authFailedRecoverable)
                    reconnect(error)
                }
            }
        }
    }
    
    func xmppStreamDidAuthenticate(_ sender: XMPPStream) {
        let credentialsItem = CredentialsManager.shared.getItem(for: jid)
        authenticationCounterTracker.authenticationDidSucceed(using: credentialsItem)
        credentialsItem.release(.authSucceeded)
        switch self.taskType {
//        case .pubsubAvatarsRequests(let value):
//            value.forEach {
//                self.avatarManager.requestPubSubItem(sender, node: .data, jid: $0.jid, by: $0.itemId)
//                self.vcardManager.requestItem(sender, jid: $0.jid)
//            }
//            break
//        case .messageHistory(let jid, let conversationType):
//            _ = mam.loadFullChatHistory(sender, jid: jid, conversationType: conversationType)
//            mam.fixHistory(sender, jid: jid, conversationType: conversationType)
//            break
//        case .fixHistory(let jid, let conversationType):
//            print("FIX HIOSTORY")
//        case .historySyncForMultipleJids(let tasks):
//            tasks.forEach {
//                mam.loadMissedChatHistory(sender, jid: $0.jid, conversationType: $0.conversationType)
//            }
//            break
        default: break
        }
    }
    
    func xmppStream(_ sender: XMPPStream, didNotAuthenticate error: DDXMLElement) {
        print(#function, error)
        authenticationCounterTracker.authenticationDidFail()
        let credentialsItem = CredentialsManager.shared.getItem(for: jid)
        if let failure = XMPPAuthenticationFailure(element: error) {
            let resolution = XMPPAuthenticationFailureResolution.resolve(
                failure: failure,
                credentialKind: credentialsItem.kind,
                source: .secondaryStream
            )
            if resolution.shouldLogRawFailure {
                DDLogDebug("XMPP background auth failure for \(jid): \(failure.rawXML)")
            }
        } else {
            DDLogDebug("XMPP background auth failure for \(jid): \(error.xmlString)")
        }
        credentialsItem.release(.authFailedRecoverable)
        self.disconnect()
        self.endBackgroundUpdateTask()
    }
    
    func xmppStream(_ sender: XMPPStream, didSend iq: XMPPIQ) {
//        print("IQ:SEND:BG: \(iq.prettyXMLString!)")
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive iq: XMPPIQ) -> Bool {
        if self.mam.read(withIQ: iq) {
            return true
        }
        if self.avatarManager.read(withIQ: iq) {
            return true
        }
        if self.vcardManager.read(withIQ: iq) {
            return true
        }
        return true
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive message: XMPPMessage) {
//        print("MSG:REC: \(message.prettyXMLString!)")
        if message.delayedDeliveryReasonDescription == "Offline Storage" {
            return
        }
        
        switch message.messageType ?? .chat {
        case .chat:
            if isArchivedMessage(message) {
                if let bareMessage = getArchivedMessageContainer(message) {
                    if VoIPManager.shared.onReceiveMessage(bareMessage, owner: sender.myJID!.bare, archivedDate: getDeliveryTime(message, owner: sender.myJID!.bare) ?? getDelayedDate(message)) {
                        return
                    }
                }
                if !(AccountManager.shared.find(for: sender.myJID!.bare)?.omemo.didReceiveOmemoMessage(message) ?? false) {
                    self.messages.receiveArchived(message)
                }
                
            } else {
                if VoIPManager.shared.onReceiveMessage(message, owner: sender.myJID!.bare, archivedDate: nil, runtime: true) {
                    return
                }
                if message.body?.isNotEmpty ?? false {
                    self.messages.receiveRuntime(message)
                }
            }
        default:
            break
        }
    }
    func xmppStreamDidDisconnect(_ sender: XMPPStream, withError error: Error?) {
        CredentialsManager.shared.getItem(for: jid).release(.authFailedRecoverable)
    }
}
