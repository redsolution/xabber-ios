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
import CocoaAsyncSocket

extension XMPPBackgroundTask: XMPPStreamDelegate {
    private func streamErrorName(_ error: DDXMLElement) -> String {
        if let errorName = error
            .elements(forXmlns: "urn:ietf:params:xml:ns:xmpp-streams")
            .filter({ $0.name != "text" })
            .first?
            .name {
            return errorName
        }
        if let errorName = error
            .elements(forXmlns: "urn:ietf:params:xml:ns:xmpp-sasl")
            .filter({ $0.name != "text" })
            .first?
            .name {
            return errorName
        }
        return error.name ?? "unknown"
    }

    private func disconnectErrorDescription(_ error: Error?) -> String {
        guard let error = error else { return "none" }
        let nsError = error as NSError
        return "\(nsError.domain):\(nsError.code):\(nsError.localizedDescription)"
    }

    func xmppStreamWillConnect(_ sender: XMPPStream) {
        guard sender === self.stream else { return }
        self.logConnectionDiagnostics(
            event: "tcp_will_connect",
            details: [
                "resource": sender.myJID?.resource ?? "none",
                "host": sender.hostName ?? "jid-domain",
                "port": sender.hostPort
            ]
        )
    }

    func xmppStream(_ sender: XMPPStream, socketDidConnect socket: GCDAsyncSocket) {
        guard sender === self.stream else { return }
        self.logConnectionDiagnostics(
            event: "tcp_socket_connected",
            details: [
                "connectedHost": socket.connectedHost ?? "unknown",
                "connectedPort": socket.connectedPort
            ]
        )
    }

    func xmppStreamDidStartNegotiation(_ sender: XMPPStream) {
        guard sender === self.stream else { return }
        self.logConnectionDiagnostics(event: "xmpp_negotiation_started")
    }

    func xmppStreamDidSecure(_ sender: XMPPStream) {
        guard sender === self.stream else { return }
        self.logConnectionDiagnostics(event: "tls_secure")
    }

    func xmppStreamConnectDidTimeout(_ sender: XMPPStream) {
        guard sender === self.stream else { return }
        self.logConnectionDiagnostics(event: "tcp_connect_timeout")
    }

    func xmppStreamDidConnect(_ sender: XMPPStream) {
        guard sender === self.stream else { return }
        self.logConnectionDiagnostics(
            event: "xmpp_stream_connected",
            details: ["resource": sender.myJID?.resource ?? "none"]
        )
        func reconnect(_ error: Error) {
//            fatalError()
            self.logConnectionDiagnostics(event: "authentication_start_failed", error: error)
            self.backgroundTaskStop()
        }
        
        func invalidate() {
//            fatalError()
            self.backgroundTaskStop()
        }
        
        let creditionalsItem = CredentialsManager.shared.getItem(for: jid)
        switch creditionalsItem.kind {
        case .password:
            self.logConnectionDiagnostics(
                event: "authentication_branch_selected",
                details: ["credentialKind": "password"]
            )
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
            self.logConnectionDiagnostics(
                event: "authentication_branch_selected",
                details: ["credentialKind": "token"]
            )
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
            self.logConnectionDiagnostics(
                event: "authentication_branch_selected",
                details: ["credentialKind": "secret"]
            )
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
        guard sender === self.stream else { return }
        self.logConnectionDiagnostics(
            event: "authentication_succeeded",
            details: ["resource": sender.myJID?.resource ?? "none"]
        )
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

    func xmppStreamDidReceive(_ sender: XMPPStream, streamFeatures features: DDXMLElement) {
        guard sender === self.stream else { return }
        let hasStartTLS = features.element(forName: "starttls", xmlns: "urn:ietf:params:xml:ns:xmpp-tls") != nil
        let hasBind = features.element(forName: "bind", xmlns: "urn:ietf:params:xml:ns:xmpp-bind") != nil
        self.logConnectionDiagnostics(
            event: "xmpp_stream_features",
            details: [
                "startTLS": hasStartTLS,
                "bind": hasBind
            ],
            rawXML: features.xmlString
        )
        if hasStartTLS {
            self.logConnectionDiagnostics(event: "tls_negotiation_required")
        }
        if hasBind {
            self.logConnectionDiagnostics(event: "resource_binding_available")
        }
    }
    
    func xmppStream(_ sender: XMPPStream, didNotAuthenticate error: DDXMLElement) {
        guard sender === self.stream else { return }
        self.logConnectionDiagnostics(
            event: "authentication_failed",
            details: ["streamError": self.streamErrorName(error)],
            rawXML: error.xmlString
        )
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
        self.logConnectionDiagnostics(
            event: "stanza_send_iq",
            details: [
                "id": iq.elementID ?? "none",
                "type": iq.type ?? "none",
                "to": iq.to?.bare ?? "none",
                "from": iq.from?.bare ?? "none"
            ],
            rawXML: iq.xmlString
        )
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive iq: XMPPIQ) -> Bool {
        self.logConnectionDiagnostics(
            event: "stanza_receive_iq",
            details: [
                "id": iq.elementID ?? "none",
                "type": iq.type ?? "none",
                "to": iq.to?.bare ?? "none",
                "from": iq.from?.bare ?? "none"
            ],
            rawXML: iq.xmlString
        )
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
        self.logConnectionDiagnostics(
            event: "stanza_receive_message",
            details: [
                "id": message.elementID ?? "none",
                "type": message.type ?? "chat",
                "to": message.to?.bare ?? "none",
                "from": message.from?.bare ?? "none"
            ],
            rawXML: message.xmlString
        )
        if message.delayedDeliveryReasonDescription == "Offline Storage" {
            return
        }
        let didObserveArchiveResult =
            self.mam.recordDeferredArchiveResultDelivery(message)
        var didRouteArchiveResultToPersistence = false
        var didIntentionallyConsumeArchiveResult = false
        defer {
            if didObserveArchiveResult {
                if didRouteArchiveResultToPersistence {
                    _ = self.mam
                        .recordDeferredArchivePersistenceRouting(message)
                } else if didIntentionallyConsumeArchiveResult {
                    _ = self.mam
                        .recordDeferredArchiveControlConsumption(message)
                }
            }
        }
        let canonicalGroupRouting = CanonicalAuxiliaryGroupMessageRouter.route(
            message,
            owner: sender.myJID?.bare ?? jid
        )
        if canonicalGroupRouting == .consumed {
            didIntentionallyConsumeArchiveResult = true
            return
        }
        
        switch message.messageType ?? .chat {
        case .chat, .normal:
            if self.mam.readMessage(message) {
                didIntentionallyConsumeArchiveResult = true
                return
            }
            if AccountManager.shared.find(for: sender.myJID!.bare)?
                .chatMarkers
                .read(withMessage: message) == true {
                didIntentionallyConsumeArchiveResult = true
                return
            }
            if isArchivedMessage(message) {
                if let bareMessage = getArchivedMessageContainer(message) {
                    if VoIPManager.shared.onReceiveMessage(bareMessage, owner: sender.myJID!.bare, archivedDate: getDeliveryTime(message, owner: sender.myJID!.bare) ?? getDelayedDate(message)) {
                        didIntentionallyConsumeArchiveResult = true
                        return
                    }
                }
                if AccountManager.shared.find(for: sender.myJID!.bare)?.omemo.didReceiveOmemoMessage(
                    message,
                    archivedMessageReceiver: self.messages
                ) ?? false {
                    didRouteArchiveResultToPersistence = true
                } else {
                    didRouteArchiveResultToPersistence = true
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

    func xmppStream(_ sender: XMPPStream, didSend message: XMPPMessage) {
        self.logConnectionDiagnostics(
            event: "stanza_send_message",
            details: [
                "id": message.elementID ?? "none",
                "type": message.type ?? "chat",
                "to": message.to?.bare ?? "none",
                "from": message.from?.bare ?? "none"
            ],
            rawXML: message.xmlString
        )
    }

    func xmppStream(_ sender: XMPPStream, didFailToSend message: XMPPMessage, error: Error) {
        self.logConnectionDiagnostics(
            event: "stanza_send_failed_message",
            details: [
                "id": message.elementID ?? "none",
                "type": message.type ?? "chat"
            ],
            rawXML: message.xmlString,
            error: error
        )
    }

    func xmppStream(_ sender: XMPPStream, didReceive presence: XMPPPresence) {
        self.logConnectionDiagnostics(
            event: "stanza_receive_presence",
            details: [
                "id": presence.elementID ?? "none",
                "type": presence.type ?? "available",
                "to": presence.to?.bare ?? "none",
                "from": presence.from?.bare ?? "none"
            ],
            rawXML: presence.xmlString
        )
    }

    func xmppStream(_ sender: XMPPStream, didSend presence: XMPPPresence) {
        self.logConnectionDiagnostics(
            event: "stanza_send_presence",
            details: [
                "id": presence.elementID ?? "none",
                "type": presence.type ?? "available",
                "to": presence.to?.bare ?? "none",
                "from": presence.from?.bare ?? "none"
            ],
            rawXML: presence.xmlString
        )
    }

    func xmppStream(_ sender: XMPPStream, didFailToSend iq: XMPPIQ, error: Error) {
        self.logConnectionDiagnostics(
            event: "stanza_send_failed_iq",
            details: [
                "id": iq.elementID ?? "none",
                "type": iq.type ?? "none"
            ],
            rawXML: iq.xmlString,
            error: error
        )
    }

    func xmppStream(_ sender: XMPPStream, didFailToSend presence: XMPPPresence, error: Error) {
        self.logConnectionDiagnostics(
            event: "stanza_send_failed_presence",
            details: [
                "id": presence.elementID ?? "none",
                "type": presence.type ?? "available"
            ],
            rawXML: presence.xmlString,
            error: error
        )
    }

    func xmppStreamDidDisconnect(_ sender: XMPPStream, withError error: Error?) {
        guard sender === self.stream else { return }
        self.logConnectionDiagnostics(
            event: "tcp_disconnected",
            details: ["disconnectError": self.disconnectErrorDescription(error)],
            error: error
        )
        CredentialsManager.shared.getItem(for: jid).release(.authFailedRecoverable)
    }

    func xmppStream(_ sender: XMPPStream, willSecureWithSettings settings: NSMutableDictionary) {
        guard sender === self.stream else { return }
        self.logConnectionDiagnostics(
            event: "tls_will_secure",
            details: ["manualTrustEvaluation": settings[GCDAsyncSocketManuallyEvaluateTrust] as? Bool ?? false]
        )
    }

    func xmppStream(_ sender: XMPPStream, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        guard sender === self.stream else {
            completionHandler(false)
            return
        }
        let shouldTrust = true
        self.logConnectionDiagnostics(
            event: "tls_trust_evaluated",
            details: ["shouldTrust": shouldTrust]
        )
        completionHandler(shouldTrust)
    }
}
