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
import CocoaAsyncSocket

enum CanonicalAuxiliaryGroupMessageRouting: Equatable {
    case notGroup
    case validatedMessage
    case consumed
}

/// Canonical-only group ingress for secondary XMPP streams.
///
/// These streams never own group commands or request correlation. They only
/// validate ordinary group messages and apply unsolicited canonical events
/// (most importantly invite previews) through the repository-backed reducer.
enum CanonicalAuxiliaryGroupMessageRouter {
    static func route(
        _ message: XMPPMessage,
        owner: String
    ) -> CanonicalAuxiliaryGroupMessageRouting {
        do {
            guard let event = try GroupStanzaRouter.route(message) else {
                return .notGroup
            }
            let processor = GroupEventProcessor(
                owner: owner,
                repository: {
                    GroupRepository(realm: try WRealm.safe())
                }
            )
            switch try processor.process(event) {
            case .message:
                return .validatedMessage
            case .handled, .invite, .ignored:
                return .consumed
            }
        } catch {
            DDLogDebug("Canonical auxiliary group stanza rejected: \(error)")
            return .consumed
        }
    }
}

extension XMPPUIActionManager: XMPPStreamDelegate {
    private func isCurrentStream(_ sender: XMPPStream, callback: String) -> Bool {
        guard sender === self.stream else {
            self.logConnectionDiagnostics(
                event: "ui_action_stale_attempt_ignored",
                details: ["callback": callback]
            )
            return false
        }
        return true
    }

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
        guard self.isCurrentStream(sender, callback: "willConnect") else { return }
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
        guard self.isCurrentStream(sender, callback: "socketDidConnect") else { return }
        self.logConnectionDiagnostics(
            event: "tcp_socket_connected",
            details: [
                "connectedHost": socket.connectedHost ?? "unknown",
                "connectedPort": socket.connectedPort
            ]
        )
    }

    func xmppStreamDidStartNegotiation(_ sender: XMPPStream) {
        guard self.isCurrentStream(sender, callback: "didStartNegotiation") else { return }
        self.logConnectionDiagnostics(event: "xmpp_negotiation_started")
    }

    func xmppStreamDidSecure(_ sender: XMPPStream) {
        guard self.isCurrentStream(sender, callback: "didSecure") else { return }
        self.logConnectionDiagnostics(event: "tls_secure")
    }

    func xmppStreamConnectDidTimeout(_ sender: XMPPStream) {
        guard self.isCurrentStream(sender, callback: "connectDidTimeout") else { return }
        self.logConnectionDiagnostics(event: "tcp_connect_timeout")
        self.lifecycleCoordinator.markFailed()
    }

    func xmppStreamDidConnect(_ sender: XMPPStream) {
        guard self.isCurrentStream(sender, callback: "didConnect") else { return }
        self.logConnectionDiagnostics(
            event: "xmpp_stream_connected",
            details: ["resource": sender.myJID?.resource ?? "none"]
        )
        canSendStanzas = false
        self.lifecycleCoordinator.markAuthenticating()
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
            self.logConnectionDiagnostics(event: "authentication_start_failed", error: error)
            self.close(soft: false)
        }
        
        func invalidate() {
            self.close(soft: false)
//            fatalError()
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
                        ownerJID: jid,
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
                        ownerJID: jid,
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
//                    print(error.localizedDescription)
                    self.authenticationCounterTracker.authenticationDidFail()
                    item.release(.authFailedRecoverable)
                    reconnect(error)
                }
            }
        }
//        print("UI STREAM CONNECTED")
    }
    
    func xmppStreamDidAuthenticate(_ sender: XMPPStream) {
        guard self.isCurrentStream(sender, callback: "didAuthenticate") else { return }
        guard let jid = sender.myJID?.bare else { return }
        self.logConnectionDiagnostics(
            event: "authentication_succeeded",
            details: ["resource": sender.myJID?.resource ?? "none"]
        )
        let credentialsItem = CredentialsManager.shared.getItem(for: jid)
        authenticationCounterTracker.authenticationDidSucceed(using: credentialsItem)
        credentialsItem.release(.authSucceeded)
        self.lifecycleCoordinator.markOnline()
        self.logConnectionDiagnostics(event: "post_auth_setup_completed")
        canSendStanzas = true
        self.resumePendingPerformRequests(owner: jid)
//        print("UI STREAM AUTHENTICATED")
    }

    func xmppStreamDidReceive(_ sender: XMPPStream, streamFeatures features: DDXMLElement) {
        guard self.isCurrentStream(sender, callback: "streamFeatures") else { return }
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
            self.lifecycleCoordinator.markTLSNegotiating()
            self.logConnectionDiagnostics(event: "tls_negotiation_required")
        }
        if hasBind {
            self.lifecycleCoordinator.markBinding()
            self.logConnectionDiagnostics(event: "resource_binding_available")
        }
    }
    
    func xmppStream(_ sender: XMPPStream, didNotAuthenticate error: DDXMLElement) {
        guard self.isCurrentStream(sender, callback: "didNotAuthenticate") else { return }
        self.logConnectionDiagnostics(
            event: "authentication_failed",
            details: ["streamError": self.streamErrorName(error)],
            rawXML: error.xmlString
        )
        self.didReceiveError(error)
//        else {
//            self.restore()
//        }
    }
    
    func xmppStream(_ sender: XMPPStream, didReceiveError error: DDXMLElement) {
        guard self.isCurrentStream(sender, callback: "didReceiveError") else { return }
        self.logConnectionDiagnostics(
            event: "xmpp_stream_error",
            details: ["streamError": self.streamErrorName(error)],
            rawXML: error.xmlString
        )
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
        guard self.isCurrentStream(sender, callback: "willReceiveIQ") else {
            return iq
        }
        if let routingId = self.mamCompletionRoutingId(for: iq),
           self.routeMamCompletionIQIfNeeded(sender, iq: iq, stage: "willReceive") {
            self.preRoutedMamCompletionIQIds.insert(routingId)
            self.messages?.scheduleQueuedMessagesDrainWithoutWaiting()
        }
        return iq
    }

    private func mamCompletionRoutingId(for iq: XMPPIQ) -> String? {
        if iq.iqType == .result,
           let fin = MessageArchiveManager.mamFinalElement(in: iq),
           let queryId = fin.attributeStringValue(forName: "queryid") {
            return queryId
        }

        if iq.iqType == .error,
           let elementId = iq.elementID,
           MessageArchiveManager.isMamCompletionIQ(iq, owner: self.currentJid) {
            return elementId
        }

        return nil
    }

    private func routeMamCompletionIQIfNeeded(_ sender: XMPPStream, iq: XMPPIQ, stage: String) -> Bool {
        guard MessageArchiveManager.isMamCompletionIQ(iq, owner: self.currentJid) else {
            return false
        }

        let mamPresent = self.mam != nil
        let handledByMam = self.mam?.read(sender, withIQ: iq) ?? false
        var fallbackDelivered = false
        if !handledByMam,
           let owner = self.currentJid,
           let event = MessageArchiveManager.unroutedEndPageEvent(
                owner: owner,
                iq: iq,
                streamKind: .uiAction
           ) {
            fallbackDelivered = MessageArchiveEndPageDispatcher.publish(event)
            DDLogDebug(
                "XMPPUIActionManager.uiActionMamFinalRoute unrouted owner=\(owner) queryId=\(event.queryId) source=\(event.source.rawValue) delivered=\(fallbackDelivered)"
            )
        }

        self.logConnectionDiagnostics(
            event: "uiActionMamFinalRoute",
            details: [
                "id": iq.elementID ?? "none",
                "mamPresent": mamPresent,
                "handledByMam": handledByMam,
                "fallbackDelivered": fallbackDelivered,
                "stage": stage
            ],
            rawXML: iq.xmlString
        )
        return true
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive iq: XMPPIQ) -> Bool {
        guard self.isCurrentStream(sender, callback: "didReceiveIQ") else { return false }
//        print("UI RECV: \(iq.prettyXMLString ?? "")" )
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
        if let routingId = self.mamCompletionRoutingId(for: iq),
           self.preRoutedMamCompletionIQIds.remove(routingId) != nil {
            self.logConnectionDiagnostics(
                event: "uiActionMamFinalRouteSkipped",
                details: [
                    "id": iq.elementID ?? "none",
                    "routingId": routingId,
                    "reason": "preRouted"
                ],
                rawXML: iq.xmlString
            )
            self.messages?.scheduleQueuedMessagesDrainWithoutWaiting()
            return true
        }
        if self.routeMamCompletionIQIfNeeded(sender, iq: iq, stage: "didReceive") {
            self.messages?.scheduleQueuedMessagesDrainWithoutWaiting()
            return true
        }
        switch true {
//        case (self.sync?.read(withIQ: iq) ?? false): return true
        case (self.mam?.read(sender, withIQ: iq) ?? false):
                self.messages?.scheduleQueuedMessagesDrainWithoutWaiting()
                return true
        case (AccountManager.shared.find(for: self.currentJid ?? "")?.omemo.read(withIQ: iq) ?? false):
            return true
        case (self.vcardManager?.read(withIQ: iq) ?? false): return true
        case (self.avatarUploader?.read(withIQ: iq) ?? false): return true
        case (self.blocked?.read(withIQ: iq) ?? false): return true
        case (self.retract?.read(withIQ: iq) ?? false): return true
//        case (self.xtokens?.read(withIQ: iq) ?? false): return true
        case (self.devices?.read(withIQ: iq) ?? false): return true

        case (self.roster?.read(withIQ: iq) ?? false): return true
//        case ((self.httpUploader as? AbstractXMPPManager)?.read(withIQ: iq) ?? false): return true

//        case (self.omemo?.read(withIQ: iq) ?? false): return true
        default: return false
        }
    }
    
    func xmppStream(_ sender: XMPPStream, didSend iq: XMPPIQ) {
        guard self.isCurrentStream(sender, callback: "didSendIQ") else { return }
//        print("UI SEND: \(iq.prettyXMLString ?? "")")
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
    
    func xmppStream(_ sender: XMPPStream, didFailToSend iq: XMPPIQ, error: Error) {
        guard self.isCurrentStream(sender, callback: "didFailToSendIQ") else { return }
        self.logConnectionDiagnostics(
            event: "stanza_send_failed_iq",
            details: [
                "id": iq.elementID ?? "none",
                "type": iq.type ?? "none"
            ],
            rawXML: iq.xmlString,
            error: error
        )
//        print("FAIL", iq.prettyXMLString())
    }
    
    func xmppStream(_ sender: XMPPStream, willSend message: XMPPMessage) -> XMPPMessage? {
        guard self.isCurrentStream(sender, callback: "willSendMessage") else { return nil }
//        print("UI STREAM WILL SEND MESSAGE \(message.prettyXMLString!)")
        return message
    }

    func xmppStream(_ sender: XMPPStream, didSend message: XMPPMessage) {
        guard self.isCurrentStream(sender, callback: "didSendMessage") else { return }
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
    
    func xmppStream(_ sender: XMPPStream, didReceive message: XMPPMessage) {
        guard self.isCurrentStream(sender, callback: "didReceiveMessage") else { return }
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
        let archiveManager = self.mam
        let didObserveArchiveResult =
            archiveManager?.recordDeferredArchiveResultDelivery(message) ??
            false
        var didRouteArchiveResultToPersistence = false
        var didIntentionallyConsumeArchiveResult = false
        defer {
            if didObserveArchiveResult,
               didIntentionallyConsumeArchiveResult,
               !didRouteArchiveResultToPersistence {
                _ = archiveManager?
                    .recordDeferredArchiveControlConsumption(message)
            }
        }
        let canonicalGroupRouting = CanonicalAuxiliaryGroupMessageRouter.route(
            message,
            owner: sender.myJID?.bare ?? currentJid ?? ""
        )
        if canonicalGroupRouting == .consumed {
            didIntentionallyConsumeArchiveResult = true
            return
        }
        
        switch message.messageType ?? .chat {
        case .chat, .normal:
            if self.mam?.readMessage(message) ?? false {
                didIntentionallyConsumeArchiveResult = true
                return
            }
            if self.chatMarkers?.read(withMessage: message) ?? false {
                didIntentionallyConsumeArchiveResult = true
                return
            }
            if isArchivedMessage(message) {
                if let bareMessage = getArchivedMessageContainer(message) {
                    if let favoritesNode = AccountManager.shared.find(for: currentJid ?? "")?.favorites.node,
                       [bareMessage.to?.bare, bareMessage.from?.bare].contains(favoritesNode) {
                        AccountManager.shared.find(for: currentJid ?? "")?.action({ user, stream in
                            user.favorites.receiveSaved(message: message)
                        })
                        
                        didIntentionallyConsumeArchiveResult = true
                        return
                    }
                    
                    if VoIPManager.shared.onReceiveMessage(bareMessage, owner: sender.myJID!.bare, archivedDate: getDeliveryTime(message, owner: sender.myJID!.bare) ?? getDelayedDate(message)) {
                        didIntentionallyConsumeArchiveResult = true
                        return
                    }
                }
                if (AccountManager.shared.find(for: sender.myJID!.bare)?.omemo.didReceiveOmemoMessage(
                    message,
                    archivedMessageReceiver: self.messages
                ) ?? false) {
                    didRouteArchiveResultToPersistence = true
                    return
                } else {
                    if let messages = self.messages {
                        didRouteArchiveResultToPersistence = true
                        messages.receiveArchived(message)
                    }
                }
            } else {
                if VoIPManager.shared.onReceiveMessage(message, owner: sender.myJID!.bare, archivedDate: nil, runtime: true) {
                    return
                }
                if message.body?.isNotEmpty ?? false {
                    self.messages?.receiveRuntime(message)
                }
            }
        case .groupchat:
            break
        case .headline:
            _ = self.deliveryManager?.read(headline: message)
            _ = self.retract?.read(headline: message)
        case .error:
            _ = self.deliveryManager?.read(error: message)
        }
        
    }

    func xmppStream(_ sender: XMPPStream, didFailToSend message: XMPPMessage, error: Error) {
        guard self.isCurrentStream(sender, callback: "didFailToSendMessage") else { return }
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
        guard self.isCurrentStream(sender, callback: "didReceivePresence") else { return }
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
        guard self.isCurrentStream(sender, callback: "didSendPresence") else { return }
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

    func xmppStream(_ sender: XMPPStream, didFailToSend presence: XMPPPresence, error: Error) {
        guard self.isCurrentStream(sender, callback: "didFailToSendPresence") else { return }
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
    
//    func xmppStreamDidReceive(_ sender: XMPPStream, streamFeatures features: DDXMLElement) {
//        sync?.checkAvailability(features)
//    }
    
    func xmppStreamDidDisconnect(_ sender: XMPPStream, withError error: Error?) {
        guard self.isCurrentStream(sender, callback: "didDisconnect") else { return }
        let disconnectError = self.disconnectErrorDescription(error)
        let pendingMamQueryIds = self.mam?.pendingArchiveRequestQueryIds() ?? []
        self.logConnectionDiagnostics(
            event: "tcp_disconnected",
            details: ["disconnectError": disconnectError],
            error: error
        )
        self.logConnectionDiagnostics(
            event: "ui_action_mam_pending_on_disconnect",
            details: [
                "pendingMamQueryCount": pendingMamQueryIds.count,
                "pendingMamQueryIds": pendingMamQueryIds.joined(separator: ","),
                "disconnectError": disconnectError
            ],
            error: error
        )
        let failureEvents = self.mam?.publishPendingArchiveRequestFailures(
            streamKind: .uiAction,
            reason: .uiActionDisconnect,
            errorDescription: disconnectError
        ) ?? []
        self.failPendingPerformRequests(
            owner: sender.myJID?.bare ?? self.currentJid,
            reason: "streamDisconnect"
        )
        failureEvents.forEach { event in
            ChatArchiveDebugTrace.log("interactiveRemoteArchiveDisconnect", [
                ("owner", event.owner),
                ("queryId", event.queryId),
                ("streamKind", event.streamKind.rawValue),
                ("disconnectError", event.errorDescription ?? "none"),
                ("pendingQueryCount", event.pendingQueryCount)
            ])
        }
        guard let jid = sender.myJID?.bare else { return }
        CredentialsManager.shared.getItem(for: jid).release(.authFailedRecoverable)
        self.lifecycleCoordinator.markDisconnected()
    }

    func xmppStream(_ sender: XMPPStream, willSecureWithSettings settings: NSMutableDictionary) {
        guard self.isCurrentStream(sender, callback: "willSecure") else { return }
        self.logConnectionDiagnostics(
            event: "tls_will_secure",
            details: ["manualTrustEvaluation": settings[GCDAsyncSocketManuallyEvaluateTrust] as? Bool ?? false]
        )
    }

    func xmppStream(_ sender: XMPPStream, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        guard self.isCurrentStream(sender, callback: "didReceiveTrust") else {
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
