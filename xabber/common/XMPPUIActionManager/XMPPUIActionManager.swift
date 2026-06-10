//
//  XMPPUIActionManager.swift
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
import SwiftKeychainWrapper

struct XMPPUIActionLifecycleStart: Equatable {
    let owner: String
    let attemptID: UInt64
    let previousOwner: String?
}

enum XMPPUIActionLifecycleDecision: Equatable {
    case start(XMPPUIActionLifecycleStart)
    case skipActive(owner: String, phase: AccountStreamLifecyclePhase, activeAttemptID: UInt64?)
    case noOwner
}

enum XMPPUIActionPerformRequestDecision: Equatable {
    case ready(owner: String)
    case waiting(owner: String, phase: AccountStreamLifecyclePhase, activeAttemptID: UInt64?)
    case start(XMPPUIActionLifecycleStart)
}

enum XMPPUIActionPreparedConnectDecision: Equatable {
    case proceed
    case staleAttempt
    case missingJID
}

final class XMPPUIActionLifecycleCoordinator {
    private let gate: AccountStreamLifecycleGate
    private(set) var currentOwner: String?

    init(gate: AccountStreamLifecycleGate = AccountStreamLifecycleGate()) {
        self.gate = gate
    }

    func beginOpen(
        owner: String,
        force: Bool = false,
        activePhase: AccountStreamLifecyclePhase? = nil
    ) -> XMPPUIActionLifecycleDecision {
        if currentOwner == owner, let activePhase {
            gate.adoptFrameworkActivePhase(activePhase)
            let snapshot = gate.snapshot()
            return .skipActive(owner: owner, phase: snapshot.phase, activeAttemptID: snapshot.activeAttemptID)
        }

        let previousOwner = currentOwner == owner ? nil : currentOwner
        if previousOwner != nil {
            gate.reset()
            currentOwner = nil
        }

        switch gate.beginConnect(trigger: .uiActionOpen, force: force) {
        case .start(let attemptID):
            currentOwner = owner
            return .start(XMPPUIActionLifecycleStart(
                owner: owner,
                attemptID: attemptID,
                previousOwner: previousOwner
            ))
        case .skip(let phase, let activeAttemptID):
            return .skipActive(owner: owner, phase: phase, activeAttemptID: activeAttemptID)
        }
    }

    func beginRestore(
        activePhase: AccountStreamLifecyclePhase?,
        streamIsDisconnected: Bool
    ) -> XMPPUIActionLifecycleDecision {
        guard let owner = currentOwner else { return .noOwner }

        if let activePhase {
            gate.adoptFrameworkActivePhase(activePhase)
            let snapshot = gate.snapshot()
            return .skipActive(owner: owner, phase: snapshot.phase, activeAttemptID: snapshot.activeAttemptID)
        }

        if streamIsDisconnected {
            _ = gate.resetIfBlockedByDisconnectedStream()
        }

        switch gate.beginConnect(trigger: .uiActionRestore) {
        case .start(let attemptID):
            return .start(XMPPUIActionLifecycleStart(
                owner: owner,
                attemptID: attemptID,
                previousOwner: nil
            ))
        case .skip(let phase, let activeAttemptID):
            return .skipActive(owner: owner, phase: phase, activeAttemptID: activeAttemptID)
        }
    }

    func beginPerformRequest(
        owner: String,
        activePhase: AccountStreamLifecyclePhase?,
        isAuthenticated: Bool,
        streamIsDisconnected: Bool
    ) -> XMPPUIActionPerformRequestDecision {
        if currentOwner == owner, isAuthenticated {
            return .ready(owner: owner)
        }

        if currentOwner == owner {
            if let activePhase {
                gate.adoptFrameworkActivePhase(activePhase)
                let snapshot = gate.snapshot()
                return .waiting(owner: owner, phase: snapshot.phase, activeAttemptID: snapshot.activeAttemptID)
            }

            var snapshot = gate.snapshot()
            if streamIsDisconnected, !snapshot.phase.allowsNewConnect {
                _ = gate.resetIfBlockedByDisconnectedStream()
                snapshot = gate.snapshot()
            }
            if !snapshot.phase.allowsNewConnect || !streamIsDisconnected {
                return .waiting(owner: owner, phase: snapshot.phase, activeAttemptID: snapshot.activeAttemptID)
            }
        }

        switch beginOpen(owner: owner, activePhase: activePhase) {
        case .start(let start):
            return .start(start)
        case .skipActive(let owner, let phase, let activeAttemptID):
            return .waiting(owner: owner, phase: phase, activeAttemptID: activeAttemptID)
        case .noOwner:
            return .waiting(owner: owner, phase: gate.snapshot().phase, activeAttemptID: gate.snapshot().activeAttemptID)
        }
    }

    func validatePreparedConnect(
        owner: String,
        attemptID: UInt64,
        jidBare: String?,
        resource: String?
    ) -> XMPPUIActionPreparedConnectDecision {
        let snapshot = gate.snapshot()
        guard currentOwner == owner, snapshot.activeAttemptID == attemptID else {
            return .staleAttempt
        }
        guard jidBare == owner,
              resource == "\(AccountManager.defaultResource)_ui_upgrade_task" else {
            return .missingJID
        }
        return .proceed
    }

    func markTLSNegotiating() {
        gate.markTLSNegotiating()
    }

    func markAuthenticating() {
        gate.markAuthenticating()
    }

    func markBinding() {
        gate.markBinding()
    }

    func markOnline() {
        gate.markOnline()
    }

    func markFailed() {
        gate.markFailed()
    }

    func markDisconnected() {
        gate.markDisconnected()
    }

    func reset(clearOwner: Bool = true) {
        gate.reset()
        if clearOwner {
            currentOwner = nil
        }
    }

    func snapshot() -> (phase: AccountStreamLifecyclePhase, activeAttemptID: UInt64?) {
        return gate.snapshot()
    }
}

class XMPPUIActionManager: NSObject {
    
    open class var shared: XMPPUIActionManager {
        struct XMPPUIActionManagerSingleton {
            static let instance = XMPPUIActionManager()
        }
        return XMPPUIActionManagerSingleton.instance
    }
    
    var currentJid: String? = nil
    
    var canSendStanzas: Bool = false
    
    var stream: XMPPStream = XMPPStream()
    let authenticationCounterTracker = XMPPAuthenticationCounterTracker()
    let connectionGate = AccountStreamLifecycleGate()
    lazy var lifecycleCoordinator = XMPPUIActionLifecycleCoordinator(gate: self.connectionGate)
    
    var queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()

    var groupchat: GroupchatManager? = nil
    var avatarUploader: AvatarUploadManager? = nil
    var chatMarkers: ChatMarkersManager? = nil
    var deliveryManager: ReliableMessageDeliveryManager? = nil
    var messages: MessageManager? = nil
    var mam: MessageArchiveManager? = nil
    var preRoutedMamCompletionIQIds: Set<String> = []
    var vcardManager: VCardManager? = nil
    var presences: PresenceManager? = nil
    var blocked: BlockManager? = nil
    var retract: MessageDeleteManager? = nil
    var roster: RosterManager? = nil
//    var sync: ClientSynchronizationManager? = nil
//    var xtokens: XTokenManager? = nil
    var devices: XMPPDeviceManager?  = nil
//    var omemo: OmemoManager? = nil
    var reconnect: XMPPReconnect? = nil
//    var x509: X509XMPPManager? = nil
    var cloudStorage: XabberUploadManager? = nil
    var shouldRecreate: Bool = true
    
    override init() {
        queue = DispatchQueue(
            label: "com.xabber.action.manager.ui",
            qos: .default,
            attributes: [],
            autoreleaseFrequency: .inherit,
            target: DispatchQueue.global()
        )
        super.init()
        queue.setSpecific(key: queueKey, value: ())
    }

    public final func open(owner: String, force: Bool = false) {
        guard XMPPJID(string: owner) != nil else { return }
        self.performOnManagerQueue {
            let activePhase = self.currentJid == owner ? self.frameworkActivePhase() : nil
            let decision = self.lifecycleCoordinator.beginOpen(
                owner: owner,
                force: force,
                activePhase: activePhase
            )
            self.handleConnectDecision(
                decision,
                trigger: .uiActionOpen,
                keepAlive: 60,
                details: ["force": force]
            )
        }
    }

    public final func disable(_ owner: String) {
        self.performOnManagerQueue {
            guard self.currentJid == owner else { return }
            self.logConnectionDiagnostics(event: "disable_requested")
            self.shouldRecreate = false
            self.disconnectCurrentStreamOnManagerQueue(
                soft: false,
                disconnect: true,
                resetLifecycle: true,
                clearOwner: true,
                logEvents: false
            )
            self.logConnectionDiagnostics(event: "disable_completed", jid: owner)
        }
    }

    public final func close(soft: Bool = false, disconnect: Bool = false) {
        self.performOnManagerQueue {
            if !CommonConfigManager.shared.config.supports_multiaccounts && !disconnect {
                return
            }
            self.disconnectCurrentStreamOnManagerQueue(
                soft: soft,
                disconnect: disconnect,
                resetLifecycle: true,
                clearOwner: true,
                logEvents: true
            )
        }
    }

    public final func restore() {
        self.performOnManagerQueue {
            let decision = self.lifecycleCoordinator.beginRestore(
                activePhase: self.frameworkActivePhase(),
                streamIsDisconnected: self.stream.isDisconnected
            )
            self.handleConnectDecision(
                decision,
                trigger: .uiActionRestore,
                keepAlive: 10
            )
        }
    }

    public final func performRequest(owner: String, action: @escaping ((XMPPStream, XMPPUIActionManager) -> Void), fail: @escaping (() -> Void), retryCounter: Int = 0) {
        guard XMPPJID(string: owner) != nil else {
            fail()
            return
        }
        self.performOnManagerQueue {
            let isSameOwner = self.currentJid == owner
            let decision = self.lifecycleCoordinator.beginPerformRequest(
                owner: owner,
                activePhase: isSameOwner ? self.frameworkActivePhase() : nil,
                isAuthenticated: isSameOwner && self.stream.isAuthenticated,
                streamIsDisconnected: isSameOwner ? self.stream.isDisconnected : true
            )

            switch decision {
            case .ready:
                action(self.stream, self)

            case .start(let start):
                guard retryCounter <= 3 else {
                    self.logConnectionDiagnostics(
                        event: "perform_request_failed_waiting_for_auth",
                        details: ["retryCounter": retryCounter]
                    )
                    fail()
                    return
                }
                self.startUIActionStream(
                    start,
                    trigger: .uiActionPerformRequest,
                    keepAlive: 60,
                    details: ["retryCounter": retryCounter]
                )
                self.schedulePerformRequestRetry(
                    owner: owner,
                    action: action,
                    fail: fail,
                    retryCounter: retryCounter
                )

            case .waiting(let waitingOwner, let phase, let activeAttemptID):
                guard retryCounter <= 3 else {
                    self.logConnectionDiagnostics(
                        event: "perform_request_failed_waiting_for_auth",
                        phase: phase,
                        details: [
                            "retryCounter": retryCounter,
                            "activeAttempt": activeAttemptID.map(String.init) ?? "none"
                        ]
                    )
                    fail()
                    return
                }
                self.logConnectionDiagnostics(
                    event: "ui_action_perform_request_waiting",
                    phase: phase,
                    details: [
                        "owner": waitingOwner,
                        "retryCounter": retryCounter,
                        "activeAttempt": activeAttemptID.map(String.init) ?? "none"
                    ]
                )
                self.schedulePerformRequestRetry(
                    owner: owner,
                    action: action,
                    fail: fail,
                    retryCounter: retryCounter
                )
            }
        }
    }

    private func performOnManagerQueue(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.async(execute: work)
        }
    }

    private func schedulePerformRequestRetry(
        owner: String,
        action: @escaping ((XMPPStream, XMPPUIActionManager) -> Void),
        fail: @escaping (() -> Void),
        retryCounter: Int
    ) {
        self.queue.asyncAfter(deadline: .now() + 2) {
            self.performRequest(
                owner: owner,
                action: action,
                fail: fail,
                retryCounter: retryCounter + 1
            )
        }
    }

    private func handleConnectDecision(
        _ decision: XMPPUIActionLifecycleDecision,
        trigger: AccountConnectTrigger,
        keepAlive: TimeInterval,
        details: [String: Any?] = [:]
    ) {
        switch decision {
        case .start(let start):
            self.startUIActionStream(
                start,
                trigger: trigger,
                keepAlive: keepAlive,
                details: details
            )

        case .skipActive(let owner, let phase, let activeAttemptID):
            DDLogDebug("skip active ui-action stream jid=\(owner) phase=\(phase.rawValue) attempt=\(activeAttemptID.map(String.init) ?? "none") streamState=\(self.streamStateDescription)")
            var logDetails = details
            logDetails["activeAttempt"] = activeAttemptID.map(String.init) ?? "none"
            self.logConnectionDiagnostics(
                event: "ui_action_connect_skipped_active_owner",
                trigger: trigger,
                phase: phase,
                details: logDetails
            )

        case .noOwner:
            self.logConnectionDiagnostics(
                event: "connect_request_skipped_gate",
                trigger: trigger,
                details: ["reason": "noOwner"]
            )
        }
    }

    private func startUIActionStream(
        _ start: XMPPUIActionLifecycleStart,
        trigger: AccountConnectTrigger,
        keepAlive: TimeInterval,
        details: [String: Any?] = [:]
    ) {
        if let previousOwner = start.previousOwner {
            self.logConnectionDiagnostics(
                event: "ui_action_owner_switch",
                attemptID: start.attemptID,
                trigger: trigger,
                details: [
                    "previousOwner": previousOwner,
                    "owner": start.owner
                ]
            )
        }

        self.currentJid = start.owner
        DDLogDebug("ui-action stream open jid=\(start.owner) attempt=\(start.attemptID)")
        self.logConnectionDiagnostics(
            event: "connect_request_started",
            attemptID: start.attemptID,
            trigger: trigger,
            details: details
        )
        let preparedStream = self.prepareNewStreamForAttempt(
            owner: start.owner,
            trigger: trigger,
            keepAlive: keepAlive
        )
        self.connectPreparedStream(
            preparedStream,
            owner: start.owner,
            attemptID: start.attemptID,
            trigger: trigger
        )
    }

    private func prepareNewStreamForAttempt(
        owner: String,
        trigger: AccountConnectTrigger,
        keepAlive: TimeInterval
    ) -> XMPPStream {
        self.detachAndDisconnectCurrentStreamForReplacement()
        self.canSendStanzas = false

        let preparedStream = XMPPStream()
        self.stream = preparedStream
        preparedStream.addDelegate(self, delegateQueue: self.queue)

        self.groupchat = GroupchatManager(withOwner: owner)
        self.avatarUploader = AvatarUploadManager(withOwner: owner)
        self.chatMarkers = ChatMarkersManager(withOwner: owner, withoutAfterburnTimer: true)
        self.deliveryManager = ReliableMessageDeliveryManager(withOwner: owner)
        let messages = MessageManager(withOwner: owner, activeStream: false)
        let mam = MessageArchiveManager(withOwner: owner)
        messages.archiveQueryIdPersistenceResolver = { [weak mam] queryId in
            mam?.shouldPersistArchiveQueryId(queryId) ?? false
        }
        self.messages = messages
        self.mam = mam
        self.vcardManager = VCardManager(withOwner: owner)
        self.presences = PresenceManager(withOwner: owner, withoutSubscribtion: true)
        self.blocked = BlockManager(withOwner: owner)
        self.retract = MessageDeleteManager(withOwner: owner)
        self.roster = RosterManager(withOwner: owner)
        self.devices = XMPPDeviceManager(withOwner: owner)
        self.reconnect?.stop()
        self.reconnect = nil
        self.cloudStorage = XabberUploadManager(withOwner: owner)

        preparedStream.myJID = XMPPJID(string: owner, resource: AccountManager.defaultResource + "_ui_upgrade_task")
        preparedStream.startTLSPolicy = XMPPStreamStartTLSPolicy.preferred
        preparedStream.keepAliveInterval = keepAlive
        self.logConnectionDiagnostics(
            event: "stream_configured",
            trigger: trigger,
            details: [
                "resource": preparedStream.myJID?.resource ?? "none",
                "tlsPolicy": preparedStream.startTLSPolicy.rawValue,
                "keepAlive": preparedStream.keepAliveInterval
            ]
        )
        return preparedStream
    }

    private func connectPreparedStream(
        _ preparedStream: XMPPStream,
        owner: String,
        attemptID: UInt64,
        trigger: AccountConnectTrigger
    ) {
        guard preparedStream === self.stream else {
            self.logConnectionDiagnostics(
                event: "ui_action_stale_attempt_ignored",
                attemptID: attemptID,
                trigger: trigger,
                details: ["reason": "streamReplaced"]
            )
            return
        }

        switch self.lifecycleCoordinator.validatePreparedConnect(
            owner: owner,
            attemptID: attemptID,
            jidBare: preparedStream.myJID?.bare,
            resource: preparedStream.myJID?.resource
        ) {
        case .proceed:
            break
        case .staleAttempt:
            self.logConnectionDiagnostics(
                event: "ui_action_stale_attempt_ignored",
                attemptID: attemptID,
                trigger: trigger,
                details: ["reason": "staleAttempt"]
            )
            return
        case .missingJID:
            self.lifecycleCoordinator.markFailed()
            self.logConnectionDiagnostics(
                event: "connect_request_skipped_gate",
                attemptID: attemptID,
                trigger: trigger,
                details: ["reason": "missingPreparedJID"]
            )
            return
        }

        do {
            DDLogDebug("ui-action stream connect jid=\(owner) resource=\(preparedStream.myJID?.resource ?? "none")")
            self.logConnectionDiagnostics(
                event: "connect_start",
                attemptID: attemptID,
                trigger: trigger,
                details: [
                    "resource": preparedStream.myJID?.resource ?? "none",
                    "host": preparedStream.hostName ?? "jid-domain",
                    "port": preparedStream.hostPort,
                    "timeout": 15
                ]
            )
            try preparedStream.connect(withTimeout: 15)
        } catch {
            self.lifecycleCoordinator.markFailed()
            self.logConnectionDiagnostics(
                event: "connect_throw",
                attemptID: attemptID,
                trigger: trigger,
                error: error
            )
            DDLogDebug("XMPPActionManager: \(#function). \(error.localizedDescription)")
        }
    }

    private func detachAndDisconnectCurrentStreamForReplacement() {
        let oldStream = self.stream
        oldStream.removeDelegate(self, delegateQueue: self.queue)
        oldStream.removeDelegate(self)
        oldStream.abortConnecting()
        oldStream.disconnect()
        oldStream.asyncSocket.disconnect()
        self.clearFeatureManagers()
    }

    private func disconnectCurrentStreamOnManagerQueue(
        soft: Bool,
        disconnect: Bool,
        resetLifecycle: Bool,
        clearOwner: Bool,
        logEvents: Bool
    ) {
        let owner = self.currentJid ?? self.stream.myJID?.bare
        let oldStream = self.stream
        let oldState = ConnectionDiagnosticsLogger.stateDescription(for: oldStream)

        if logEvents {
            self.logConnectionDiagnostics(
                event: "disconnect_requested",
                jid: owner,
                state: oldState,
                details: [
                    "soft": soft,
                    "disconnect": disconnect
                ]
            )
        }

        oldStream.removeDelegate(self, delegateQueue: self.queue)
        oldStream.removeDelegate(self)
        self.stream = XMPPStream()
        if soft {
            oldStream.disconnectAfterSending()
        } else {
            oldStream.abortConnecting()
            oldStream.disconnect()
            oldStream.asyncSocket.disconnect()
        }
        if resetLifecycle {
            self.lifecycleCoordinator.reset(clearOwner: clearOwner)
        }
        if clearOwner {
            self.currentJid = nil
        }
        self.canSendStanzas = false
        self.clearFeatureManagers()

        if logEvents {
            self.logConnectionDiagnostics(
                event: "disconnect_completed_local",
                jid: owner,
                state: oldState
            )
        }
    }

    private func clearFeatureManagers() {
        self.reconnect?.stop()
        self.reconnect = nil
        self.groupchat = nil
        self.avatarUploader = nil
        self.chatMarkers = nil
        self.deliveryManager = nil
        self.messages = nil
        self.mam = nil
        self.preRoutedMamCompletionIQIds.removeAll()
        self.cloudStorage = nil
        self.roster = nil
        self.presences = nil
        self.retract = nil
        self.blocked = nil
        self.vcardManager = nil
        self.devices = nil
    }

    private func frameworkActivePhase() -> AccountStreamLifecyclePhase? {
        if self.stream.isAuthenticated {
            return .online
        }
        if self.stream.isAuthenticating {
            return .authenticating
        }
        if self.stream.isConnected {
            return .postAuthSetup
        }
        if self.stream.isConnecting {
            return .connecting
        }
        return nil
    }

    private var streamStateDescription: String {
        return ConnectionDiagnosticsLogger.stateDescription(for: self.stream)
    }

    final func logConnectionDiagnostics(
        event: String,
        attemptID: UInt64? = nil,
        trigger: AccountConnectTrigger? = nil,
        phase: AccountStreamLifecyclePhase? = nil,
        jid: String? = nil,
        state: String? = nil,
        details: [String: Any?] = [:],
        rawXML: String? = nil,
        error: Error? = nil
    ) {
        let snapshot = self.connectionGate.snapshot()
        ConnectionDiagnosticsLogger.log(
            event: event,
            stream: .uiAction,
            jid: jid ?? self.currentJid ?? self.stream.myJID?.bare,
            attemptID: attemptID ?? snapshot.activeAttemptID,
            trigger: trigger,
            phase: phase ?? snapshot.phase,
            state: state ?? self.streamStateDescription,
            details: details,
            rawXML: rawXML,
            error: error
        )
    }
    
    func tokenWasInvalidated() {
//        NotificationCenter.default.post(name: ApplicationStateManager.tokenWasExpired, object: self.stream.myJID!.bare)
    }
    
    func didReceiveError(_ error: DDXMLElement) {
        if let failure = XMPPAuthenticationFailure(element: error) {
            self.handleAuthenticationFailure(failure)
            return
        }

        func failToConnect(_ errorName: String) {
            guard let jid = self.currentJid else {
                self.close(disconnect: true)
                return
            }
            CredentialsManager.shared.getItem(for: jid).release(.authFailedRecoverable)
            self.close(disconnect: true)
            switch errorName {
                case "conflict":
                    break
                case "credentials-expired":
                    AccountManager.shared.find(for: jid)?.tokenShouldUpdate()
                case "policy-violation":
                    self.disable(jid)
                case "not-authorized":
                    break
                default:
                    break
            }
        }
        
        func tryToReconnect(_ errorName: String) {
            self.restore()
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
    }

    private func handleAuthenticationFailure(_ failure: XMPPAuthenticationFailure) {
        self.authenticationCounterTracker.authenticationDidFail()
        guard let jid = self.currentJid else {
            self.close(disconnect: true)
            return
        }

        let account = AccountManager.shared.find(for: jid)
        let credentialsItem = CredentialsManager.shared.getItem(for: jid)
        let resolution = XMPPAuthenticationFailureResolution.resolve(
            failure: failure,
            credentialKind: credentialsItem.kind,
            source: .secondaryStream
        )
        if resolution.shouldLogRawFailure {
            DDLogDebug("XMPP UI auth failure for \(jid): \(failure.rawXML)")
        }

        self.reconnect?.stop()
        credentialsItem.release(.authFailedRecoverable)
        self.close(disconnect: true)

        switch resolution.action {
        case .retryAuthentication(let message):
            AccountManager.shared.changeNewUserState(for: jid, to: .failure(message))
        case .removeAccount(let message):
            AccountManager.shared.changeNewUserState(for: jid, to: .failure(message))
        case .refreshDeviceSecret:
            account?.tokenShouldUpdate()
        case .rejectPassword(let message),
             .reportGeneric(let message):
            AccountManager.shared.changeNewUserState(for: jid, to: .failure(message))
        }
    }
    
    deinit {
//        print("UI DEINIT")
    }
}

extension XMPPUIActionManager: XMPPReconnectDelegate {
    func xmppReconnect(_ sender: XMPPReconnect, shouldAttemptAutoReconnect connectionFlags: SCNetworkConnectionFlags) -> Bool {
        self.logConnectionDiagnostics(
            event: "connect_request_skipped_gate",
            trigger: .uiActionRestore,
            details: ["reason": "uiActionReconnectDisabled"]
        )
        return false
    }
}
