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
import CocoaAsyncSocket

extension Account: XMPPStreamDelegate {

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
        guard sender === self.xmppStream else {
            DDLogDebug("ignore stale primary stream willConnect jid=\(self.jid)")
            return
        }
        DDLogDebug("primary stream willConnect jid=\(self.jid) resource=\(sender.myJID?.resource ?? "none") hostPresent=\(sender.hostName?.isEmpty == false) port=\(sender.hostPort) phase=\(self.connectionGate.snapshot().phase.rawValue)")
        self.logConnectionDiagnostics(
            event: "tcp_will_connect",
            details: [
                "resource": sender.myJID?.resource ?? "none",
                "hostPresent": sender.hostName?.isEmpty == false,
                "host": sender.hostName ?? "jid-domain",
                "port": sender.hostPort
            ]
        )
    }

    func xmppStream(_ sender: XMPPStream, socketDidConnect socket: GCDAsyncSocket) {
        guard sender === self.xmppStream else {
            DDLogDebug("ignore stale primary stream socketDidConnect jid=\(self.jid)")
            return
        }
        self.logConnectionDiagnostics(
            event: "tcp_socket_connected",
            details: [
                "connectedHost": socket.connectedHost ?? "unknown",
                "connectedPort": socket.connectedPort
            ]
        )
    }

    func xmppStreamDidStartNegotiation(_ sender: XMPPStream) {
        guard sender === self.xmppStream else {
            DDLogDebug("ignore stale primary stream startNegotiation jid=\(self.jid)")
            return
        }
        self.logConnectionDiagnostics(event: "xmpp_negotiation_started")
    }

    func xmppStreamDidSecure(_ sender: XMPPStream) {
        guard sender === self.xmppStream else {
            DDLogDebug("ignore stale primary stream didSecure jid=\(self.jid)")
            return
        }
        self.logConnectionDiagnostics(event: "tls_secure")
    }

    func xmppStreamDidConnect(_ stream: XMPPStream) {
        guard stream === self.xmppStream else {
            DDLogDebug("ignore stale primary stream didConnect jid=\(self.jid)")
            return
        }
        DDLogDebug("primary stream didConnect jid=\(self.jid) resource=\(stream.myJID?.resource ?? "none") phase=\(self.connectionGate.snapshot().phase.rawValue)")
        self.logConnectionDiagnostics(
            event: "xmpp_stream_connected",
            details: ["resource": stream.myJID?.resource ?? "none"]
        )
        AccountManager.shared.changeNewUserState(for: self.jid, to: .startConnection)
        func reconnect(_ error: Error) {
            self.logConnectionDiagnostics(event: "authentication_start_failed", error: error)
            self.statusMessage.accept("Offline")
            self.connectionGate.markFailed()
            self.scheduleConnectRetry(after: 3, trigger: .timeoutRetry, attemptID: nil)
            AccountManager.shared.changeNewUserState(for: self.jid, to: .failure(error.localizedDescription))
        }
        
        func invalidate() {
            self.tokenWasInvalidated()
        }
        delayedConnectTimer?.invalidate()
        delayedConnectTimer = nil
        self.connectionGate.markAuthenticating()
        self.sendReadiness.markAuthenticating()
//        DispatchQueue.main.async {
//            ToastPresenter(message: "Stream connected").present(animated: true)
//        }
        let creditionalsItem = CredentialsManager.shared.getItem(for: self.jid)
        switch creditionalsItem.kind {
        case .password:
            self.logConnectionDiagnostics(
                event: "authentication_branch_selected",
                details: [
                    "credentialKind": "password",
                    "supportsHOTP": stream.supportsHOTPAuthentication,
                    "supportsXToken": stream.supportsXTokenAuthentication
                ]
            )
            do {
                if let password = creditionalsItem.creditionalString {
                    if stream.supportsHOTPAuthentication {
                        if let secret = creditionalsItem.getSecret() {
//                            if let deviceId = self.devices.deviceId {
//                                stream.xabberDeviceId = deviceId
//                            }
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
                    DDLogDebug("missing password credential for primary stream jid=\(self.jid)")
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
                        AccountManager.shared.changeNewUserState(for: self.jid, to: .connect)
                    case .missingCredential:
                        self.authenticationCounterTracker.authenticationDidFail()
                        item.release(.authFailedRecoverable)
                        self.tokenShouldUpdate()
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
//                    DispatchQueue.main.async {
//                        ToastPresenter(message: "Stream try get secret").present(animated: true)
//                    }
                    switch try XMPPStoredCredentialAuthenticator.authenticate(
                        stream: stream,
                        storage: item,
                        ownerJID: self.jid,
                        counterTracker: self.authenticationCounterTracker
                    ) {
                    case .started:
                        AccountManager.shared.changeNewUserState(for: self.jid, to: .connect)
//                        DispatchQueue.main.async {
//                            ToastPresenter(message: "Stream try auth").present(animated: true)
//                        }
                    case .missingCredential:
                        self.authenticationCounterTracker.authenticationDidFail()
                        item.release(.authFailedRecoverable)
                        self.tokenShouldUpdate()
//                        DispatchQueue.main.async {
//                            ToastPresenter(message: "Stream invalidated").present(animated: true)
//                        }
                    }
                } catch {
                    self.authenticationCounterTracker.authenticationDidFail()
                    item.release(.authFailedRecoverable)
                    reconnect(error)
//                    DispatchQueue.main.async {
//                        ToastPresenter(message: "Stream try reconnect").present(animated: true)
//                    }
                }
            }
            
        }
    }

    func xmppStreamConnectDidTimeout(_ sender: XMPPStream) {
        guard sender === self.xmppStream else {
            DDLogDebug("ignore stale primary stream timeout jid=\(self.jid)")
            return
        }
        DDLogDebug("primary stream connect timeout jid=\(self.jid) phase=\(self.connectionGate.snapshot().phase.rawValue)")
        self.logConnectionDiagnostics(event: "tcp_connect_timeout")
        self.handleConnectTimeout()
    }

    func xmppStreamDidAuthenticate(_ sender: XMPPStream) {
        guard sender === self.xmppStream else {
            DDLogDebug("ignore stale primary stream didAuthenticate jid=\(self.jid)")
            return
        }
        DDLogDebug("primary stream didAuthenticate jid=\(self.jid) resource=\(sender.myJID?.resource ?? "none") phase=\(self.connectionGate.snapshot().phase.rawValue)")
        self.logConnectionDiagnostics(
            event: "authentication_succeeded",
            details: ["resource": sender.myJID?.resource ?? "none"]
        )
        var resumedStanzaIds: NSArray?
        var resumeResponse: DDXMLElement?
        let didResume = self.sm.didResume(withAckedStanzaIds: &resumedStanzaIds, serverResponse: &resumeResponse)
        self.logConnectionDiagnostics(
            event: didResume ? "stream_management_resume_succeeded" : "stream_management_resume_not_used",
            details: [
                "ackedCount": resumedStanzaIds?.count ?? 0,
                "response": resumeResponse?.name ?? "none"
            ],
            rawXML: resumeResponse?.xmlString
        )
        let ackedIds = (resumedStanzaIds as? [Any])?.compactMap { $0 as? String } ?? []
        if didResume {
            _ = self.primaryStreamStanzaTracker.noteResumeSucceeded(ackedIds: ackedIds)
        } else {
            _ = self.primaryStreamStanzaTracker.noteResumeFailedOrFullReconnect()
        }
        self.cancelDelayedConnectTimer()
        self.connectionGate.markPostAuthSetup()
        self.logConnectionDiagnostics(event: "post_auth_setup_started")
        self.didAuthenticate()
        if let resource = sender.myJID?.resource {
            self.devices.updateMyDevice(resource: resource)
        }
        let credentialsItem = CredentialsManager.shared.getItem(for: self.jid)
        self.authenticationCounterTracker.authenticationDidSucceed(using: credentialsItem)
        credentialsItem.release(.authSucceeded)
        AccountManager.shared.markAsAuthencticated(jid: self.jid)
        AccountManager.shared.changeNewUserState(for: self.jid, to: .auth)
        PushNotificationsManager.setAccountStateForPush(jid: self.jid, active: true)
        
    }

    
    func xmppStreamDidReceive(_ sender: XMPPStream, streamFeatures features: DDXMLElement) {
        guard sender === self.xmppStream else {
            DDLogDebug("ignore stale primary stream features jid=\(self.jid)")
            return
        }
        let hasStartTLS = features.element(forName: "starttls", xmlns: "urn:ietf:params:xml:ns:xmpp-tls") != nil
        let hasBind = features.element(forName: "bind", xmlns: "urn:ietf:params:xml:ns:xmpp-bind") != nil
        let hasDevices = features.element(forName: "devices", xmlns: devices.getPrimaryNamespace()) != nil
        DDLogDebug("primary stream features jid=\(self.jid) startTLS=\(hasStartTLS) bind=\(hasBind) devices=\(hasDevices)")
        self.logConnectionDiagnostics(
            event: "xmpp_stream_features",
            details: [
                "startTLS": hasStartTLS,
                "bind": hasBind,
                "devices": hasDevices
            ],
            rawXML: features.xmlString
        )
        if hasStartTLS {
            self.connectionGate.markTLSNegotiating()
            self.sendReadiness.markTLSNegotiating()
            self.logConnectionDiagnostics(
                event: "starttls_required_detected",
                details: [
                    "startTLSPolicy": sender.startTLSPolicy.rawValue
                ]
            )
            self.beginStartTLSDiagnosticsWatch()
            self.logConnectionDiagnostics(event: "tls_negotiation_required")
        }
        if hasBind {
            self.connectionGate.markBinding()
            self.sendReadiness.markBinding()
            self.logConnectionDiagnostics(event: "resource_binding_available")
        }
        syncManager.checkAvailability(features)
        devices.setAvailable(features)
    }
    
    
    
    func xmppStream(_ sender: XMPPStream, alternativeResourceForConflictingResource conflictingResource: String) -> String? {
        return "\(conflictingResource)_\(UUID().uuidString)"
    }
    
    func xmppStream(_ sender: XMPPStream, didNotAuthenticate error: DDXMLElement) {
        guard sender === self.xmppStream else {
            DDLogDebug("ignore stale primary stream auth failure jid=\(self.jid)")
            return
        }
        DDLogDebug("primary stream didNotAuthenticate jid=\(self.jid) error=\(self.streamErrorName(error)) phase=\(self.connectionGate.snapshot().phase.rawValue)")
        self.logConnectionDiagnostics(
            event: "authentication_failed",
            details: ["streamError": self.streamErrorName(error)],
            rawXML: error.xmlString
        )
        self.didReceiveError(error)
        self.sendReadiness.markStreamError(self.streamErrorName(error))
    }
    
    func xmppStreamWasTold(toDisconnect sender: XMPPStream) {
        guard sender === self.xmppStream else {
            DDLogDebug("ignore stale primary stream told-to-disconnect jid=\(self.jid)")
            return
        }
        DDLogDebug("primary stream toldToDisconnect jid=\(self.jid) phase=\(self.connectionGate.snapshot().phase.rawValue)")
        self.logConnectionDiagnostics(event: "disconnect_told")
//        self.statusMessage.accept("Disconnect")
        self.cancelDelayedConnectTimer()
        self.statusMessage.accept("Offline")
        self.statusState.accept(.offline)
        self.resetConfigs()
        self.carbonsEnabled = false
        self.connectionGate.markDisconnected()
        let cause = self.pendingDisconnectCause ?? .serverStreamError
        self.pendingDisconnectCause = nil
        self.sendReadiness.markDisconnected(cause: cause)
        self.sendCoordinator.streamDidDisconnect(canResume: self.sm.canResumeStream())
        self.connectionResilience.streamDidDisconnect(cause: cause)
    }
    
    func xmppStream(_ sender: XMPPStream, didReceiveError error: DDXMLElement) {
        guard sender === self.xmppStream else {
            DDLogDebug("ignore stale primary stream error jid=\(self.jid)")
            return
        }
        DDLogDebug("primary stream received error jid=\(self.jid) error=\(self.streamErrorName(error)) phase=\(self.connectionGate.snapshot().phase.rawValue)")
        self.logConnectionDiagnostics(
            event: "xmpp_stream_error",
            details: ["streamError": self.streamErrorName(error)],
            rawXML: error.xmlString
        )
        self.didReceiveError(error)
        self.sendReadiness.markStreamError(self.streamErrorName(error))
    }
    
    func xmppStreamDidDisconnect(_ sender: XMPPStream, withError error: Error?) {
        guard sender === self.xmppStream else {
            DDLogDebug("ignore stale primary stream disconnect jid=\(self.jid)")
            return
        }
        DDLogDebug("primary stream didDisconnect jid=\(self.jid) error=\(self.disconnectErrorDescription(error)) phase=\(self.connectionGate.snapshot().phase.rawValue)")
        self.logConnectionDiagnostics(
            event: "tcp_disconnected",
            details: ["disconnectError": self.disconnectErrorDescription(error)],
            error: error
        )
        self.cancelDelayedConnectTimer()
        self.xmppTaskScheduler.reset()
        self.discardBootstrapQueuedPrimaryStanzas(reason: "streamDisconnect")
        CredentialsManager.shared.getItem(for: self.jid).release(.authFailedRecoverable)
        self.statusState.accept(.offline)
        self.statusMessage.accept("Offline")
        if let nserror = error as? NSError {
            if ["kCFStreamErrorDomainNetServices", "kCFStreamErrorDomainNetDB"].contains(nserror.domain) {
                AccountManager.shared.changeNewUserState(for: self.jid, to: .failure("Server not found"))
            }
        }
        self.connectionGate.markDisconnected()
        AccountManager.shared.markAsNotConnecting(
            jid: self.jid,
            reason: "stream_disconnect",
            clearAuthentication: true
        )
        let cause = self.pendingDisconnectCause ?? .accidentalSocket
        self.pendingDisconnectCause = nil
        self.sendReadiness.markDisconnected(cause: cause)
        self.sendCoordinator.streamDidDisconnect(canResume: self.sm.canResumeStream())
        self.primaryStreamStanzaTracker.noteStreamDidDisconnect(canResume: self.sm.canResumeStream())
        self.connectionResilience.streamDidDisconnect(cause: cause)
    }

    func xmppStream(_ sender: XMPPStream, willSend iq: XMPPIQ) -> XMPPIQ? {
        guard sender === self.xmppStream else { return iq }
        return self.preparePrimaryStreamStanzaForSend(iq) ? iq : nil
    }
    
    func xmppStream(_ sender: XMPPStream, didSend iq: XMPPIQ) {
        self.notePrimaryStreamStanzaDidSend(iq)
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
        if SettingManager.logEnabled {
            DDLogInfo("S. IQ: to \(iq.to?.bare ?? "none"), from \(iq.from?.bare ?? "none"), type \(iq.element(forName: "query")?.xmlns() ?? iq.children?.first?.name ?? "none")")
        }
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
        let isTrackedPingResult = self.ping.isTrackedResult(iq)
        if !isTrackedPingResult {
            self.connectionResilience.noteInboundActivity("iq")
        }
        switch true {
            case self.syncManager.read(withIQ: iq):
                AccountManager.shared.markAsConnected(jid: jid)
                _ = self.syncManager.checkNextPage(sender, in: iq)
                break
            case self.avatarManager.read(withIQ: iq): break
            case self.avatarUploader.read(withIQ: iq): break
            case self.roster.read(withIQ: iq): break
            case self.mam.read(sender, withIQ: iq):
                self.messages.scheduleQueuedMessagesDrainWithoutWaiting()
                break
            case self.push.read(withIQ: iq):
                break
            case self.devices.read(withIQ: iq):
                self.omemo.checkInfo()
                break
            case XabberAccountManager.shared.read(sender, with: iq): break
            case self.cloudStorage.read(withIQ: iq): break
            case self.xTokens.read(withIQ: iq): break
            case self.groupchats.read(sender, withIQ: iq): break
            case self.blocked.read(withIQ: iq): break
            case self.msgDeleteManager.read(withIQ: iq): break
            case self.messageSchedule.read(withIQ: iq): break
            case self.vcards.read(withIQ: iq):
                _ = self.avatarManager.readFromVcard(iq)
                break
            case self.ping.read(withIQ: iq):
                if isTrackedPingResult {
                    self.connectionResilience.notePingResult(success: true)
                }
                break
            case self.disco.read(withIQ: iq):
                AccountManager.shared.markAsConnected(jid: jid)
                break
            case self.omemo.read(withIQ: iq): break
            case self.notifications.read(withIQ: iq): break
            case self.x509Manager.read(withIQ: iq): break
            case self.trustSharingManager.read(withIQ: iq): break
            default: return false
        }
        return true
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
        self.connectionResilience.noteInboundActivity("presence")
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
    
    func xmppStream(_ sender: XMPPStream, willSend presence: XMPPPresence) -> XMPPPresence? {
        guard sender === self.xmppStream else { return presence }
        let scope = [
            presence.type ?? "available",
            presence.to?.bare ?? "broadcast"
        ].joined(separator: ":")
        return self.preparePrimaryStreamStanzaForSend(
            presence,
            replayPolicy: .latestPresence(scope: scope)
        ) ? presence : nil
    }

    func xmppStream(_ sender: XMPPStream, didSend presence: XMPPPresence) {
        self.notePrimaryStreamStanzaDidSend(presence)
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
        if self.groupchats.success(presence: presence) {
            return
        }
        //self.presences.read(outgoingPresence: presence)
        if SettingManager.logEnabled {
            DDLogInfo("S. presence: to \(presence.to?.bare ?? "none"), from \(presence.from?.bare ?? "none")")
        }
    }
    
    func xmppStream(_ sender: XMPPStream, willReceive message: XMPPMessage) -> XMPPMessage? {
//        print("MESSAGE")
        return message
    }
   
    func xmppStreamDidFilterStanza(_ sender: XMPPStream) {
//        print(#function)
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive message: XMPPMessage) {

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
        self.connectionResilience.noteInboundActivity("message")
        if SettingManager.logEnabled {
            DDLogInfo("R. message: to \(message.to?.bare ?? "none"), from \(message.from?.bare ?? "none"), id \(message.elementID ?? "none")")
        }
        //pass delayed message from offline storage, cos it doesnt have unique stanza id
        if message.delayedDeliveryReasonDescription == "Offline Storage" {
            return
        }
        
        switch message.messageType ?? .chat {
            case .chat, .normal:

            if self.mam.readMessage(message) {
                return
            }
            
            if self.notifications.read(withMessage: message) {
                return
            }
            if self.groupchats.readMessage(withMessage: message) {
                return
            }
            if self.chatStates.read(withMessage: message) {
                return
            } else if isArchivedMessage(message) {
                
                if let bareMessage = getArchivedMessageContainer(message) {
                    if bareMessage.to?.bare == AccountManager.shared.find(for: self.jid)?.favorites.node {
                        AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                            user.favorites.receiveSaved(message: bareMessage)
                        })
                        
                        return
                    }
                    if self.akeManager.didReceivedVerificationMessage(message: bareMessage) {
                        return
                    }
                    
                    if self.trustSharingManager.didReceivedListOfContactsDevices(message: bareMessage) {
                        return
                    }
                    if VoIPManager.shared.onReceiveMessage(bareMessage, owner: self.jid, archivedDate: getDeliveryTime(bareMessage, owner: self.jid) ?? getDelayedDate(message)) {
                        return
                    }
                    if self.groupchats.readArchivedInviteEnvelope(message, isRead: nil) {
                        return
                    }
                    if self.xTokens.receive(sender, withMessage: bareMessage) {
                        return
                    }
                }
                if self.chatMarkers.read(withMessage: message) {
                    return
                } else if self.omemo.didReceiveOmemoMessage(message) {
                    return
                } else {
                    self.messages.receiveArchived(message)
                }
            } else if isPriorityMessage(message) {
                if let bareMessage = getPriorityMessageContainer(message) {
                    if self.akeManager.didReceivedVerificationMessage(message: bareMessage) {
                        return
                    }
                }
            } else if isCarbonCopy(message) {
                if let bareMessage = getCarbonCopyMessageContainer(message) {
                    if bareMessage.to?.bare == AccountManager.shared.find(for: self.jid)?.favorites.node {
                        AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                            user.favorites.receiveSaved(message: bareMessage)
                        })
                        
                        return
                    }
                    if self.akeManager.didReceivedVerificationMessage(message: bareMessage) {
                        return
                    }
                    if self.chatStates.read(withMessage: bareMessage) {
                        return
                    } else if VoIPManager.shared.onReceiveMessage(bareMessage, owner: self.jid, archivedDate: getDeliveryTime(bareMessage, owner: self.jid) ?? getDelayedDate(message), runtime: true, outgoing: true) {
                        return
                    } else if self.groupchats.readInvite(in: bareMessage, date: getDelayedDate(message) ?? Date(), isRead: nil) {
                        return
                    }
                }
                if self.chatMarkers.read(withMessage: message) {
                    return
                } else if self.omemo.didReceiveOmemoMessage(message) {
                    return
                } else {
                    self.messages.receiveCarbon(message)
                }
                
            } else if isCarbonForwarded(message) {
                if let bareMessage = getCarbonForwardedMessageContainer(message) {
                    if bareMessage.to?.bare == AccountManager.shared.find(for: self.jid)?.favorites.node {
                        AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                            user.favorites.receiveSaved(message: bareMessage)
                        })
                        
                        return
                    }
                    if self.akeManager.didReceivedVerificationMessage(message: bareMessage) {
                        return
                    }
                    if VoIPManager.shared.onReceiveMessage(bareMessage, owner: self.jid, archivedDate: getDeliveryTime(bareMessage, owner: self.jid) ?? getDelayedDate(message), runtime: true, outgoing: true) {
                        return
                    } else if self.deliveryReceipts.read(withMessage: bareMessage) {
                        return
                    } else if self.chatStates.read(withMessage: bareMessage) {
                        return
                    } else if self.groupchats.readInvite(in: bareMessage, date: getDelayedDate(message) ?? Date(), isRead: nil) {
                        return
                    }
                }
                if self.omemo.didReceiveOmemoMessage(message) {
                    return
                } else if self.chatMarkers.read(withMessage: message) {
                    return
                } else {
                    self.messages.receiveCarbonForwarded(message)
                }
            } else {
                if message.to?.bare == AccountManager.shared.find(for: self.jid)?.favorites.node {
                    AccountManager.shared.find(for: self.jid)?.action({ user, stream in
                        user.favorites.receiveSaved(message: message)
                    })
                    
                    return
                }
                if self.akeManager.didReceivedVerificationMessage(message: message) {
                    return
                }
                if self.chatMarkers.read(withMessage: message) {
                    return
                }
                if VoIPManager.shared.onReceiveMessage(message, owner: self.jid, archivedDate: nil, runtime: true) {
                    return
                }
                if self.deliveryReceipts.read(withMessage: message) {
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
                } else if self.akeManager.didReceivedVerificationMessage(message: message) {
                    return
                } else if self.trustSharingManager.didReceivedListOfContactsDevices(message: message) {
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
            if self.akeManager.didReceivedVerificationMessage(message: message) {
                return
            }
            if isPriorityMessage(message) {
                if let bareMessage = getPriorityMessageContainer(message) {
                    if self.akeManager.didReceivedVerificationMessage(message: bareMessage) {
                        return
                    }
                }
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
            if self.omemo.onEncryptionUpdateReceiveHeadline(message) {
                return
            }
            if self.avatarManager.readMessage(message) {
                return
            }
            if self.msgDeleteManager.read(headline: message) {
                return
            }
            if self.messageSchedule.read(headline: message) {
                return
            }
            if self.trustSharingManager.didReceivedTrustedSharingEvent(message: message) {
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
    }

    func xmppStream(_ sender: XMPPStream, willSend message: XMPPMessage) -> XMPPMessage? {
        guard sender === self.xmppStream else { return message }
        return self.preparePrimaryStreamStanzaForSend(message) ? message : nil
    }
    
    func xmppStream(_ sender: XMPPStream, didSend message: XMPPMessage) {
        self.notePrimaryStreamStanzaDidSend(message)
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
        if SettingManager.logEnabled {
            DDLogInfo("S. message: to \(message.to?.bare ?? "none"), from \(message.from?.bare ?? "none"), id \(message.elementID ?? "none")")
        }
    }
    
    func xmppStream(_ sender: XMPPStream, didFailToSend message: XMPPMessage, error: Error) {
        self.notePrimaryStreamStanzaDidFailToSend(message)
        self.logConnectionDiagnostics(
            event: "stanza_send_failed_message",
            details: [
                "id": message.elementID ?? "none",
                "type": message.type ?? "chat"
            ],
            rawXML: message.xmlString,
            error: error
        )
//        self.messages.changeMessageState(message, to: .error)
        if self.sendCoordinator.localSendFailed(message: message, error: error) {
            return
        }
        self.messages.fail(message: message)
    }

    func xmppStream(_ sender: XMPPStream, didFailToSend iq: XMPPIQ, error: Error) {
        self.notePrimaryStreamStanzaDidFailToSend(iq)
        self.logConnectionDiagnostics(
            event: "stanza_send_failed_iq",
            details: [
                "id": iq.elementID ?? "none",
                "type": iq.type ?? "none"
            ],
            rawXML: iq.xmlString,
            error: error
        )
        if self.groupchats.fail(iq: iq) {
            return
        }
    }

    func xmppStream(_ sender: XMPPStream, didFailToSend presence: XMPPPresence, error: Error) {
        self.notePrimaryStreamStanzaDidFailToSend(presence)
        self.logConnectionDiagnostics(
            event: "stanza_send_failed_presence",
            details: [
                "id": presence.elementID ?? "none",
                "type": presence.type ?? "available"
            ],
            rawXML: presence.xmlString,
            error: error
        )
        if self.groupchats.fail(presence: presence) {
            return
        }
    }

    func xmppStreamWasTold(toAbortConnect sender: XMPPStream) {
        guard sender === self.xmppStream else {
            DDLogDebug("ignore stale primary stream told-to-abort-connect jid=\(self.jid)")
            return
        }
        self.logConnectionDiagnostics(event: "connect_abort_told")
    }

    func xmppStreamDidSendClosingStreamStanza(_ sender: XMPPStream) {
        guard sender === self.xmppStream else {
            DDLogDebug("ignore stale primary stream closing-stream-stanza jid=\(self.jid)")
            return
        }
        self.logConnectionDiagnostics(event: "disconnect_closing_stream_sent")
    }
    
    
    func xmppStream(_ sender: XMPPStream, willSecureWithSettings settings: NSMutableDictionary) {
        self.markStartTLSDelegateCallbackEntered()
        self.logConnectionDiagnostics(
            event: "tls_delegate_callback_entered",
            details: [
                "willSetManualTrustEvaluation": false,
                "tlsPeer": sender.effectiveCertificatePeerName ?? "none"
            ]
        )
        self.logConnectionDiagnostics(
            event: "tls_will_secure",
            details: [
                "manualTrustEvaluation": false,
                "tlsPeer": sender.effectiveCertificatePeerName ?? "none"
            ]
        )
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
//        print(trust)
        self.logConnectionDiagnostics(event: "tls_trust_callback_entered")
        let shouldTrust = XMPPStreamTLSTrustEvaluator.evaluate(
            trust,
            peerName: sender.effectiveCertificatePeerName
        )
        self.logConnectionDiagnostics(
            event: "tls_trust_evaluated",
            details: [
                "shouldTrust": shouldTrust,
                "tlsPeer": sender.effectiveCertificatePeerName ?? "none"
            ]
        )
        self.logConnectionDiagnostics(
            event: "tls_trust_completion_called",
            details: ["shouldTrust": shouldTrust]
        )
        completionHandler(shouldTrust)
        
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
        self.logConnectionDiagnostics(
            event: "xtoken_requested",
            details: ["id": elementId]
        )
        self.xTokens.tokensSupport = true
        self.xTokens.queryIds.insert(elementId)
    }
    
    func xmppStreamResponseXToken(_ iq: XMPPIQ) {
        self.logConnectionDiagnostics(
            event: "xtoken_response",
            details: ["id": iq.elementID ?? "none"],
            rawXML: iq.xmlString
        )
        _ = self.xTokens.read(withIQ: iq)
    }
    
    func xmppStreamRequestDeviceRegistration(_ elementId: String) {
        self.logConnectionDiagnostics(
            event: "device_registration_requested",
            details: ["id": elementId]
        )
        self.devices.queryIds.insert(elementId)
    }
    
    func xmppStreamResponseDeviceRegistration(_ iq: XMPPIQ) {
        self.logConnectionDiagnostics(
            event: "device_registration_response",
            details: ["id": iq.elementID ?? "none"],
            rawXML: iq.xmlString
        )
        _ = self.devices.read(withIQ: iq)
    }
}


extension Account: XMPPStreamManagementDelegate {
    
    func xmppStreamManagement(_ sender: XMPPStreamManagement, wasEnabled enabled: DDXMLElement) {
        self.logConnectionDiagnostics(
            event: "stream_management_enabled",
            rawXML: enabled.xmlString
        )
        self.sendReadiness.markStreamManagementEnabled()
        self.connectionResilience.noteInboundActivity("stream-management-enabled")
    }
    
    func xmppStreamManagement(_ sender: XMPPStreamManagement, wasNotEnabled failed: DDXMLElement) {
        self.logConnectionDiagnostics(
            event: "stream_management_not_enabled",
            rawXML: failed.xmlString
        )
        self.sendReadiness.markStreamManagementEnableFailed(reason: failed.name)
//        AccountManager.shared.markAsConnecting(jid: self.jid)
//        self.smStorage.removeAll(for: self.xmppStream)
//        self.disconnect(hard: true)
//        self.resetStream()
//        self.asyncConnect()
        if failed.element(forName: "item-not-found") != nil {
            DispatchQueue.main.async {
                ToastPresenter().presentError(message: "SM session not found")
            }
        } else {
            DispatchQueue.main.async {
                ToastPresenter().presentError(message: "SM session error. \(failed.children?.compactMap({ return $0.name }).reduce(" ", +) ?? "" )")
            }
        }
        DDLogDebug("strict send readiness keeps account gated after stream management enable failure jid=\(self.jid)")
    }

    func xmppStreamManagementDidRequestAck(_ sender: XMPPStreamManagement) {
        self.logConnectionDiagnostics(event: "stream_management_ack_requested")
    }

    func xmppStreamManagement(_ sender: XMPPStreamManagement, didReceiveAckForStanzaIds stanzaIds: [Any]) {
        let ackedIds = stanzaIds.compactMap { $0 as? String }
        _ = self.primaryStreamStanzaTracker.noteAck(ids: ackedIds)
        self.logConnectionDiagnostics(
            event: "stream_management_ack_received",
            details: ["ackedCount": stanzaIds.count]
        )
        self.connectionResilience.noteStreamManagementAck()
    }

    func xmppStreamManagement(_ sender: XMPPStreamManagement, stanzaIdForSentElement element: XMPPElement) -> Any? {
        PrimaryStreamStanzaIdentifier.ensureID(on: element)
    }
}
