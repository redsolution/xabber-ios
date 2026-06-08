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
        self.asyncConnect(trigger: .restore)
    }
    
    func didAuthenticate() {
        registerRegularPushForAccount()
        registerVoIPPushForAccount()
        self.configureBase()
        let didResume = self.sm.didResume
        if didResume {
            self.sendReadiness.markStreamManagementResumeSucceeded()
            self.sendCoordinator.streamManagementResumeSucceeded()
            AccountManager.shared.markAsConnected(jid: self.jid)
//            self.presence()
            DispatchQueue.main.async {
                ToastPresenter().presentSuccess(message: "SM did resume")
            }
            _ = self.syncManager.sync(self.xmppStream)
        } else {
            DispatchQueue.main.async {
                ToastPresenter().present(message: "Synchronization", image: imageLiteral("cloud"))
            }
            self.configureExtensions()
            self.disco.configure(self.xmppStream)
            if self.roster.version != nil {
                if self.syncManager.isAvailable {
                    self.statusMessage.accept("Synchronization")
                }
            }
            self.roster.request(self.xmppStream)
            self.sendCoordinator.streamManagementResumeFailed()
        }
        self.connectionResilience.streamManagementResumeCompleted(
            didResume: didResume,
            responseName: didResume ? "resumed" : "full-auth"
        )
        self.connectionGate.markOnline()
        AccountManager.shared.markAsNotConnecting(
            jid: self.jid,
            reason: "online",
            clearAuthentication: false
        )
        SensitiveMediaAnalysisStartupScheduler.shared.accountDidReachOnline(jid: self.jid)
        SubscribtionsManager.shared.checkXMPPAccountStateAfterConnection(
            jid: self.jid,
            connectionAttemptID: self.connectionGate.snapshot().activeAttemptID
        )
        self.queue.asyncAfter(deadline: .now() + 0.2) {
            let phase = self.connectionGate.snapshot().phase
            guard phase == .online else {
                DDLogDebug("skip ui-action stream open jid=\(self.jid) primaryPhase=\(phase.rawValue)")
                return
            }
        }
        self.queue.asyncAfter(deadline: .now() + 1) {
            _ = self.syncManager.sync(self.xmppStream)
            let requestDevices = {
                self.devices.requestList(self.xmppStream)
            }
            if !self.syncManager.deferPostBootstrapWorkIfNeeded(requestDevices) {
                requestDevices()
            }
        }
    }
    
    func didReceivePing(withIq iq: XMPPIQ) -> Bool {
        if iq.xmlns() == "jabber:client"
            && iq.iqType == .get
            && iq.element(forName: "ping") != nil {
            self.sendPrimaryStanza(
                XMPPIQ(iqType: .result, to: iq.from, elementID: iq.elementID),
                replayPolicy: .notReplayable
            )
            return true
        }
        return false
    }
    
    func didReceiveError(_ error: DDXMLElement) {
        if self.handleAuthenticationFailure(error) {
            return
        }

        func failToConnect(_ errorName: String) {
            self.reconnect.autoReconnect = false
            self.disconnect(hard: true, cause: .permanentAuthFailure)
            switch errorName {
                case "conflict":
                    self.updateResource("\(self.resource)\(arc4random() % 16380)")
                case "credentials-expired":
                    self.tokenShouldUpdate()
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
            self.connectionGate.markDisconnected()
            self.connectionResilience.scheduleReconnect(cause: .serverStreamError, trigger: .resilienceRetry)
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
        CredentialsManager.shared.getItem(for: self.jid).release(.authFailedRecoverable)
        self.resetConfigs()
    }

    @discardableResult
    func handleAuthenticationFailure(_ error: DDXMLElement) -> Bool {
        guard let failure = XMPPAuthenticationFailure(element: error) else {
            return false
        }
        self.handleAuthenticationFailure(failure)
        return true
    }

    func handleAuthenticationFailure(_ failure: XMPPAuthenticationFailure) {
        let credentialsItem = CredentialsManager.shared.getItem(for: self.jid)
        let resolution = XMPPAuthenticationFailureResolution.resolve(
            failure: failure,
            credentialKind: credentialsItem.kind
        )
        if resolution.shouldLogRawFailure {
            DDLogDebug("XMPP auth failure for \(self.jid): \(failure.rawXML)")
        }

        self.authenticationCounterTracker.authenticationDidFail()
        self.reconnect.autoReconnect = false
        self.cancelDelayedConnectTimer()
        credentialsItem.release(resolution.releaseOutcome)
        self.resetConfigs()
        self.statusMessage.accept(resolution.statusMessage)

        switch resolution.action {
        case .retryAuthentication:
            self.disconnect(hard: true, cause: .retryableAuthFailure)
            AccountManager.shared.changeNewUserState(for: self.jid, to: .failure(resolution.statusMessage))

        case .removeAccount(let alertMessage):
            self.disconnect(hard: true, cause: .permanentAuthFailure)
            ApplicationStateManager.shared.removeAccountForAuthenticationFailure(
                jid: self.jid,
                message: alertMessage
            )

        case .refreshDeviceSecret:
            self.disconnect(hard: true, cause: .permanentAuthFailure)
            self.tokenShouldUpdate()

        case .rejectPassword(let message):
            self.disconnect(hard: true, cause: .permanentAuthFailure)
            self.statusMessage.accept(message)
            AccountManager
                .shared
                .changeNewUserState(for: self.jid, to: .failure(message))

        case .reportGeneric(let message):
            self.disconnect(hard: true, cause: .permanentAuthFailure)
            self.statusMessage.accept(message)
            AccountManager
                .shared
                .changeNewUserState(for: self.jid, to: .failure(message))
        }
    }
    
    public final func tokenShouldUpdate() {
        self.reconnect.autoReconnect = false
        self.disconnect(hard: true, cause: .permanentAuthFailure)
        DispatchQueue.main.async {
            CredentialsExpiredPresenter(jid: self.jid).present(animated: true)
        }
    }
    
    public final func tokenWasInvalidated() {
        NotificationCenter.default.post(name: ApplicationStateManager.tokenWasExpired, object: self.jid)
    }
    
    public final func didReceiveRoster() {
        self.queue.asyncAfter(deadline: .now() + 1) {
            let finishRosterBootstrap = {
                if !self.sm.didResume {
                    self.presence()
                }
                self.queue.asyncAfter(deadline: .now() + 1) {
                    self.updateExtensions()
                }
            }
            if !self.syncManager.deferPostBootstrapWorkIfNeeded(finishRosterBootstrap) {
                finishRosterBootstrap()
            }
        }
//        if self.sm.canResumeStream() {
//            return
//        }
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
                self.msgDeleteManager.enable(self.xmppStream)
            }
            if self.xmppStream.myPresence == nil {
                self.requestInitialMAM()
            }
            
        }
        let updatePostBootstrapArchives = {
            self.notifications.update(self.xmppStream)
            self.favorites.update(self.xmppStream)
        }
        if !self.syncManager.deferPostBootstrapWorkIfNeeded(updatePostBootstrapArchives) {
            updatePostBootstrapArchives()
        }
    }
}
