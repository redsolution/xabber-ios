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
import RealmSwift
import RxSwift
import RxCocoa
import SwiftKeychainWrapper
import MaterialComponents.MaterialPalettes

enum AccountStreamLifecyclePhase: String {
    case idle
    case connecting
    case tlsNegotiating
    case authenticating
    case binding
    case postAuthSetup
    case online
    case disconnecting
    case failed

    var allowsNewConnect: Bool {
        switch self {
        case .idle, .failed:
            return true
        case .connecting, .tlsNegotiating, .authenticating, .binding, .postAuthSetup, .online, .disconnecting:
            return false
        }
    }

    var allowsTimeoutRetry: Bool {
        switch self {
        case .connecting, .tlsNegotiating:
            return true
        case .idle, .authenticating, .binding, .postAuthSetup, .online, .disconnecting, .failed:
            return false
        }
    }

    var isConnectionDiagnosticsHeartbeatActive: Bool {
        switch self {
        case .connecting, .tlsNegotiating, .authenticating, .binding, .postAuthSetup:
            return true
        case .idle, .online, .disconnecting, .failed:
            return false
        }
    }
}

enum AccountConnectTrigger: String {
    case initialLoad
    case addExistingAccount
    case restore
    case statusUpdate
    case resourceUpdate
    case timeoutRetry
    case xmppReconnect
    case deviceReregister
    case legacyDirect
    case uiActionOpen
    case uiActionRestore
    case uiActionPerformRequest
}

enum AccountStreamConnectDecision: Equatable {
    case start(attemptID: UInt64)
    case skip(phase: AccountStreamLifecyclePhase, activeAttemptID: UInt64?)
}

enum AccountStreamConnectPreflightSkipReason: String {
    case frameworkActive
    case gateActive
}

enum AccountStreamConnectPreflightDecision: Equatable {
    case start(attemptID: UInt64, stalePhase: AccountStreamLifecyclePhase?)
    case skip(
        phase: AccountStreamLifecyclePhase,
        activeAttemptID: UInt64?,
        reason: AccountStreamConnectPreflightSkipReason
    )
}

struct AccountStreamConnectPreflight {
    static func decide(
        gate: AccountStreamLifecycleGate,
        trigger: AccountConnectTrigger,
        forceReset: Bool,
        frameworkActivePhase: AccountStreamLifecyclePhase?,
        streamIsDisconnected: Bool
    ) -> AccountStreamConnectPreflightDecision {
        if !forceReset, let frameworkActivePhase {
            gate.adoptFrameworkActivePhase(frameworkActivePhase)
            let snapshot = gate.snapshot()
            return .skip(
                phase: snapshot.phase,
                activeAttemptID: snapshot.activeAttemptID,
                reason: .frameworkActive
            )
        }

        let stalePhase = forceReset || !streamIsDisconnected
            ? nil
            : gate.resetIfBlockedByDisconnectedStream()

        switch gate.beginConnect(trigger: trigger, force: forceReset) {
        case .start(let attemptID):
            return .start(attemptID: attemptID, stalePhase: stalePhase)

        case .skip(let phase, let activeAttemptID):
            return .skip(
                phase: phase,
                activeAttemptID: activeAttemptID,
                reason: .gateActive
            )
        }
    }
}

final class AccountStreamLifecycleGate {
    private let lock = NSLock()
    private var nextAttemptID: UInt64 = 0
    private(set) var phase: AccountStreamLifecyclePhase = .idle
    private(set) var activeAttemptID: UInt64?

    func beginConnect(trigger: AccountConnectTrigger, force: Bool = false) -> AccountStreamConnectDecision {
        lock.lock()
        defer { lock.unlock() }

        if force {
            phase = .idle
            activeAttemptID = nil
        }

        guard phase.allowsNewConnect else {
            return .skip(phase: phase, activeAttemptID: activeAttemptID)
        }

        nextAttemptID += 1
        activeAttemptID = nextAttemptID
        phase = .connecting
        return .start(attemptID: nextAttemptID)
    }

    func adoptFrameworkActivePhase(_ phase: AccountStreamLifecyclePhase) {
        lock.lock()
        defer { lock.unlock() }

        guard self.phase.allowsNewConnect else { return }
        self.phase = phase
    }

    func markTLSNegotiating() {
        transition(to: .tlsNegotiating, allowedFrom: [.connecting])
    }

    func markAuthenticating() {
        transition(to: .authenticating, allowedFrom: [.connecting, .tlsNegotiating])
    }

    func markBinding() {
        transition(to: .binding, allowedFrom: [.authenticating, .tlsNegotiating, .connecting])
    }

    func markPostAuthSetup() {
        transition(to: .postAuthSetup, allowedFrom: [.binding, .authenticating, .tlsNegotiating, .connecting])
    }

    func markOnline() {
        transition(to: .online, allowedFrom: [.postAuthSetup, .binding, .authenticating])
    }

    func markDisconnecting() {
        lock.lock()
        phase = .disconnecting
        lock.unlock()
    }

    func markDisconnected() {
        lock.lock()
        phase = .idle
        activeAttemptID = nil
        lock.unlock()
    }

    func resetIfBlockedByDisconnectedStream() -> AccountStreamLifecyclePhase? {
        lock.lock()
        defer { lock.unlock() }

        guard !phase.allowsNewConnect else { return nil }

        let stalePhase = phase
        phase = .idle
        activeAttemptID = nil
        return stalePhase
    }

    func markFailed() {
        lock.lock()
        phase = .failed
        activeAttemptID = nil
        lock.unlock()
    }

    func reset() {
        lock.lock()
        phase = .idle
        activeAttemptID = nil
        lock.unlock()
    }

    func canRetryTimeout(for attemptID: UInt64?) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let attemptID, attemptID != activeAttemptID {
            return false
        }
        return phase.allowsTimeoutRetry
    }

    func snapshot() -> (phase: AccountStreamLifecyclePhase, activeAttemptID: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        return (phase, activeAttemptID)
    }

    private func transition(to newPhase: AccountStreamLifecyclePhase, allowedFrom: Set<AccountStreamLifecyclePhase>) {
        lock.lock()
        if allowedFrom.contains(phase) {
            phase = newPhase
        }
        lock.unlock()
    }
}

private final class AccountConnectRetryContext: NSObject {
    let attemptID: UInt64?
    let trigger: AccountConnectTrigger

    init(attemptID: UInt64?, trigger: AccountConnectTrigger) {
        self.attemptID = attemptID
        self.trigger = trigger
    }
}

enum ConnectionDiagnosticsStreamKind: String {
    case primary
    case uiAction = "ui-action"
    case background
    case register
    case changePassword = "change-password"
    case accountDelete = "account-delete"
    case oneShot = "one-shot"
    case voip
}

struct ConnectionDiagnosticsTiming: Equatable {
    let elapsedMs: Int
    let deltaMs: Int?
}

struct ConnectionDiagnosticsExecutionContext: Equatable {
    let thread: String
    let queue: String

    static func current() -> ConnectionDiagnosticsExecutionContext {
        let threadName: String
        if Thread.isMainThread {
            threadName = "main"
        } else {
            threadName = String(format: "0x%x", pthread_mach_thread_np(pthread_self()))
        }

        let queueLabel = String(cString: __dispatch_queue_get_label(nil), encoding: .utf8) ?? "unknown"
        return ConnectionDiagnosticsExecutionContext(thread: threadName, queue: queueLabel)
    }
}

final class ConnectionDiagnosticsTimeline {
    static let shared = ConnectionDiagnosticsTimeline()

    private struct Key: Hashable {
        let stream: ConnectionDiagnosticsStreamKind
        let jid: String
        let attemptID: UInt64
    }

    private struct Entry {
        let startedAt: TimeInterval
        let lastAt: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    func record(
        stream: ConnectionDiagnosticsStreamKind,
        jid: String?,
        attemptID: UInt64,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> ConnectionDiagnosticsTiming {
        let key = Key(stream: stream, jid: jid ?? "none", attemptID: attemptID)
        lock.lock()
        defer { lock.unlock() }

        if let entry = entries[key] {
            let elapsedMs = Self.milliseconds(from: max(0, now - entry.startedAt))
            let deltaMs = Self.milliseconds(from: max(0, now - entry.lastAt))
            entries[key] = Entry(startedAt: entry.startedAt, lastAt: now)
            return ConnectionDiagnosticsTiming(elapsedMs: elapsedMs, deltaMs: deltaMs)
        }

        entries[key] = Entry(startedAt: now, lastAt: now)
        return ConnectionDiagnosticsTiming(elapsedMs: 0, deltaMs: nil)
    }

    func resetAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    private static func milliseconds(from seconds: TimeInterval) -> Int {
        return Int((seconds * 1000).rounded())
    }
}

struct ConnectionDiagnosticsLogger {
    static let prefix = "CONNECTION_DIAGNOSTICS"
    static let redactedValue = "[redacted]"

    #if DEBUG
    static let rawXMLLoggingEnabled = true
    #else
    static let rawXMLLoggingEnabled = false
    #endif

    static func log(
        event: String,
        stream: ConnectionDiagnosticsStreamKind,
        jid: String?,
        attemptID: UInt64? = nil,
        trigger: AccountConnectTrigger? = nil,
        phase: AccountStreamLifecyclePhase? = nil,
        state: String? = nil,
        details: [String: Any?] = [:],
        rawXML: String? = nil,
        error: Error? = nil,
        includeRawXML: Bool = rawXMLLoggingEnabled
    ) {
        let timing = attemptID.map {
            ConnectionDiagnosticsTimeline.shared.record(
                stream: stream,
                jid: jid,
                attemptID: $0
            )
        }
        DDLogInfo(
            line(
                event: event,
                stream: stream,
                jid: jid,
                attemptID: attemptID,
                trigger: trigger,
                phase: phase,
                state: state,
                details: details,
                rawXML: rawXML,
                error: error,
                includeRawXML: includeRawXML,
                timing: timing,
                executionContext: ConnectionDiagnosticsExecutionContext.current()
            )
        )
    }

    static func line(
        event: String,
        stream: ConnectionDiagnosticsStreamKind,
        jid: String?,
        attemptID: UInt64? = nil,
        trigger: AccountConnectTrigger? = nil,
        phase: AccountStreamLifecyclePhase? = nil,
        state: String? = nil,
        details: [String: Any?] = [:],
        rawXML: String? = nil,
        error: Error? = nil,
        includeRawXML: Bool = rawXMLLoggingEnabled,
        timing: ConnectionDiagnosticsTiming? = nil,
        executionContext: ConnectionDiagnosticsExecutionContext? = nil
    ) -> String {
        var parts: [String] = [
            prefix,
            "event=\(format(event))",
            "stream=\(stream.rawValue)",
            "jid=\(format(jid ?? "none"))"
        ]

        if let attemptID {
            parts.append("attempt=\(attemptID)")
        }
        if let trigger {
            parts.append("trigger=\(trigger.rawValue)")
        }
        if let phase {
            parts.append("phase=\(phase.rawValue)")
        }
        if let state {
            parts.append("state=\(format(state))")
        }
        if let timing {
            parts.append("elapsedMs=\(timing.elapsedMs)")
            if let deltaMs = timing.deltaMs {
                parts.append("deltaMs=\(deltaMs)")
            }
        }
        if let executionContext {
            parts.append("thread=\(format(executionContext.thread))")
            parts.append("queue=\(format(executionContext.queue))")
        }
        if let error {
            let nsError = error as NSError
            parts.append("errorDomain=\(format(nsError.domain))")
            parts.append("errorCode=\(nsError.code)")
            parts.append("errorDescription=\(format(nsError.localizedDescription))")
        }

        for key in details.keys.sorted() {
            guard let value = details[key], let unwrapped = value else { continue }
            parts.append("\(key)=\(format(unwrapped))")
        }

        if includeRawXML, let rawXML {
            parts.append("xml=\(format(redact(rawXML)))")
        }

        return parts.joined(separator: " ")
    }

    static func redact(_ rawXML: String) -> String {
        var output = rawXML

        let sensitiveElements = [
            "auth",
            "response",
            "device-secret",
            "device_secret",
            "deviceSecret",
            "xabberDeviceSecret",
            "validation-key",
            "validation_key",
            "validationKey",
            "encryption-key",
            "encryption_key",
            "encryptionKey",
            "access-token",
            "access_token",
            "accessToken",
            "refresh-token",
            "refresh_token",
            "refreshToken",
            "password",
            "token",
            "secret",
            "jwt"
        ]

        for element in sensitiveElements {
            output = replacing(
                pattern: "(?is)(<\(element)\\b[^>]*>)(.*?)(</\(element)>)",
                in: output,
                with: "$1\(redactedValue)$3"
            )
        }

        output = replacing(
            pattern: "(?i)\\b(device-secret|device_secret|deviceSecret|xabberDeviceSecret|validation-key|validation_key|validationKey|encryption-key|encryption_key|encryptionKey|access-token|access_token|accessToken|refresh-token|refresh_token|refreshToken|password|token|secret|jwt|authorization)\\s*=\\s*\"[^\"]*\"",
            in: output,
            with: "$1=\"\(redactedValue)\""
        )
        output = replacing(
            pattern: "(?i)\\b(device-secret|device_secret|deviceSecret|xabberDeviceSecret|validation-key|validation_key|validationKey|encryption-key|encryption_key|encryptionKey|access-token|access_token|accessToken|refresh-token|refresh_token|refreshToken|password|token|secret|jwt|authorization)\\s*=\\s*'[^']*'",
            in: output,
            with: "$1='\(redactedValue)'"
        )
        output = replacing(
            pattern: "(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]+",
            in: output,
            with: "Bearer \(redactedValue)"
        )

        return output
    }

    static func stateDescription(for stream: XMPPStream) -> String {
        [
            "disconnected=\(stream.isDisconnected)",
            "connected=\(stream.isConnected)",
            "connecting=\(stream.isConnecting)",
            "authenticating=\(stream.isAuthenticating)",
            "authenticated=\(stream.isAuthenticated)"
        ].joined(separator: ",")
    }

    private static func format(_ value: Any) -> String {
        let raw = String(describing: value)
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\"", with: "\\\"")

        if escaped.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines) != nil
            || escaped.contains("=")
            || escaped.contains("<")
            || escaped.contains(">")
            || escaped.contains("\"") {
            return "\"\(escaped)\""
        }
        return escaped
    }

    private static func replacing(pattern: String, in value: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template)
    }
}

final class Account: NSObject {
//  main params
    var jid: String = ""
    override var description: String {
            return "Account \(jid)"
        }
//    var password: String
//    var token: String = ""
    var host: String
    var port: Int
    var username: String
//  settings
    var supportTokens: Bool = false
    var tokenUid: String = ""
    var savePassword: Bool = true
    var useSecureConnection: Bool = false
    var manuallySetHost: Bool = false
    var resource: String = ""
    var priority: Int = 0

//  XMPPFramework params
    var queue: DispatchQueue
    var xmppStream: XMPPStream
    let authenticationCounterTracker = XMPPAuthenticationCounterTracker()
    let connectionGate = AccountStreamLifecycleGate()
//  XMPPFramework modules
    var reconnect: XMPPReconnect
//  custom modules
    var devices: XMPPDeviceManager
    var xTokens: XTokenManager
    var disco: ServerDiscoManager
    var presences: PresenceManager
    var messages: MessageManager
    var roster: RosterManager
    var mam: MessageArchiveManager
    var carbons: CarbonsManager
    var lastChats: LastChats
    var csi: ClientStateIndicateManager
    var push: PushNotificationsManager
    var vcards: VCardManager
    var avatarManager: XmppAvatarManager
    var ping: PingManager
    var cloudStorage: XabberUploadManager
    var avatarUploader: AvatarUploadManager
    var blocked: BlockManager
    var chatStates: ChatStatesManager
    var chatMarkers: ChatMarkersManager
    var attention: AttentionManger
    var globalIndex: GlobalIndexManager
    var groupchats: GroupchatManager
    var deliveryManager: ReliableMessageDeliveryManager
    var msgDeleteManager: MessageDeleteManager
    var syncManager: ClientSynchronizationManager
    var x509Manager: X509XMPPManager
    var omemo: OmemoManager
    var deliveryReceipts: MessageDeliveryReceipts
    var notifications: XMPPNotificationsManager
    var favorites: XMPPFavoritesManager
    var akeManager: AuthenticatedKeyExchangeManager
    var trustSharingManager: TrustSharingManager
    var abuse: XMPPAbuseManager
    
    var smStorage: XMPPStreamManagementMemoryStorage
    var sm: XMPPStreamManagement
    
    
    var carbonsEnabled: Bool = false
    var pushWasReceived: Bool {
        didSet {
            DDLogDebug("pushWasReceived was changed from \(oldValue)to \(self.pushWasReceived)")
        }
    }
    var pushLastMAMId: String
//  notification part
    var completionHandler: (() -> Void)?
    var completionHandlerTimer: Timer?
    var isInitialMAMRequestSend: Bool = false
//  Observable
    var statusState: BehaviorRelay<ResourceStatus> = BehaviorRelay(value: ResourceStatus.offline)
    var statusMessage: BehaviorRelay<String> = BehaviorRelay(value: "Offline")
    var pushStatusMessage: BehaviorRelay<Bool> = BehaviorRelay(value: false)
//  service data
    var delayedConnectTimer: Timer?
    var isPresenceUpdateRequestSend: Bool = false
    var watchConnectionTimer: Timer?
    let connectionDiagnosticsLock = NSLock()
    var connectionDiagnosticsHeartbeatID: UInt64 = 0
    var startTLSStallWatchID: UInt64 = 0
    var startTLSDelegateCallbackWatchID: UInt64?
    
    var isRequestedAway: Bool = false
    var isBinded: Bool = false
    
    var isRegularPushRequestSended: Bool = false
    var isVoIPPushRequestSended: Bool = false
    
    var isSubscribedOnStateChange: Bool = false
    var isSynced: Bool = false
    var isConfigured: Bool = false
    
    var deviceName: String = ""
    
    public var isNewAccount: Bool = false

    static func username(from jid: String) -> String {
        String(jid.split(separator: "@").first ?? "")
    }
    
    init(jid: String, queue: DispatchQueue) {
        // set default connection fields
        self.jid = jid
        self.host = ""
        self.port = 5222
        // try to set default username
        self.username = Account.username(from: jid)
        // default push variables
        self.pushWasReceived = false
        self.pushLastMAMId = ""
        // set pointer to queue, in which application worked
        self.queue = queue
        // setting XMPPStream
        self.xmppStream = XMPPStream()
        self.presences = PresenceManager(withOwner: self.jid)
        self.messages = MessageManager(withOwner: self.jid, activeStream: true)
        self.roster = RosterManager(withOwner: self.jid)
        self.mam = MessageArchiveManager(withOwner: self.jid)
        self.carbons = CarbonsManager(withOwner: self.jid)
        self.lastChats = LastChats(withOwner: self.jid)
        self.blocked = BlockManager(withOwner: self.jid)
        self.vcards = VCardManager(withOwner: self.jid)
        self.avatarManager = XmppAvatarManager(withOwner: self.jid)
//        self.vCardAvatars = vCardAvatarManager(withOwner: self.j2id)
//        self.PEPAvatars = PEPAvatarManager(withOwner: self.jid)
        self.disco = ServerDiscoManager(withOwner: self.jid)
        self.cloudStorage = XabberUploadManager(withOwner: self.jid)
        self.avatarUploader = AvatarUploadManager(withOwner: self.jid)
        self.chatStates = ChatStatesManager(withOwner: self.jid)
        self.chatMarkers = ChatMarkersManager(withOwner: self.jid)
        self.attention = AttentionManger(withOwner: self.jid)
        self.ping = PingManager(withOwner: self.jid)
        self.csi = ClientStateIndicateManager(withOwner: self.jid)
        self.push = PushNotificationsManager(withOwner: self.jid)
        self.xTokens = XTokenManager(withOwner: self.jid)
        self.devices = XMPPDeviceManager(withOwner: self.jid)
        self.reconnect = XMPPReconnect(dispatchQueue: queue)
        self.globalIndex = GlobalIndexManager(withOwner: self.jid)
        self.groupchats = GroupchatManager(withOwner: self.jid)
        self.deliveryManager = ReliableMessageDeliveryManager(withOwner: self.jid)
        self.msgDeleteManager = MessageDeleteManager(withOwner: self.jid)
        self.syncManager = ClientSynchronizationManager(withOwner: self.jid)
        self.omemo = OmemoManager(withOwner: self.jid)
        self.x509Manager = X509XMPPManager(withOwner: self.jid)
        self.smStorage = XMPPStreamManagementMemoryStorage()
        self.sm = XMPPStreamManagement(storage: self.smStorage, dispatchQueue: queue)
        self.deliveryReceipts = MessageDeliveryReceipts(withOwner: self.jid)
        self.notifications = XMPPNotificationsManager(withOwner: self.jid)
        self.favorites = XMPPFavoritesManager(withOwner: self.jid)
        self.akeManager = AuthenticatedKeyExchangeManager(withOwner: self.jid)
        self.trustSharingManager = TrustSharingManager(withOwner: self.jid)
        self.abuse = XMPPAbuseManager(withOwner: self.jid)
        // start init NSObject
        super.init()
        self.registerModules()
        self.lastChats.resetSyncedStatus()
        self.groupchats.reset()
        self.load()
//        xuploads.confi-gure()
//        self.asyncConnect()
    }
    
    func configureStream() {
        let privacyLevelRaw = SettingManager.shared.getString(for: "privacy_level") ?? CommonConfigManager.shared.config.default_privacy_level
        let privacyLevel = SettingManager.PrivacyLevel(rawValue: privacyLevelRaw) ?? .incognito
        self.xmppStream.shouldRequestXToken = false
        self.xmppStream.shouldRegisterDevice = false
        self.xmppStream.xabberClientInfo = CommonConfigManager.shared.config.app_name
        if privacyLevel == .serverContacts{
            self.xmppStream.xabberPublicLabel = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
        } else {
            self.xmppStream.xabberPublicLabel = self.deviceName
        }
        if privacyLevel == .incognito {
            self.xmppStream.xabberDeviceInfo = self.deviceName
        } else {
            self.xmppStream.xabberDeviceInfo = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
        }
        self.xmppStream.myJID = XMPPJID(string: jid, resource: AccountManager.defaultResource)
        self.xmppStream.startTLSPolicy = XMPPStreamStartTLSPolicy.preferred
        self.xmppStream.keepAliveInterval = 60
        self.xmppStream.removeDelegate(self, delegateQueue: self.queue)
        self.xmppStream.removeDelegate(self)
        self.xmppStream.addDelegate(self, delegateQueue: self.queue)
        DDLogDebug("configured primary stream jid=\(self.jid) resource=\(self.xmppStream.myJID?.resource ?? "none") delegateAssigned=true streamState=\(self.streamStateDescription)")
        self.logConnectionDiagnostics(
            event: "stream_configured",
            details: [
                "resource": self.xmppStream.myJID?.resource ?? "none",
                "tlsPolicy": self.xmppStream.startTLSPolicy.rawValue,
                "keepAlive": self.xmppStream.keepAliveInterval
            ]
        )
    }
    
    func resetStream() {
        self.logConnectionDiagnostics(event: "reset_stream_requested")
        self.cancelDelayedConnectTimer()
        self.connectionGate.reset()
        self.statusState.accept(.offline)
        self.statusMessage.accept(RosterUtils.shared.convertStatus(.offline))
        self.xmppStream.abortConnecting()
        self.xmppStream.disconnect()
        self.xmppStream.asyncSocket.disconnect()
        self.xmppStream.removeDelegate(self)
        self.xmppStream = XMPPStream()
        self.logConnectionDiagnostics(event: "reset_stream_completed")
    }
    
    func registerModules() {
        self.disco.register(mam)
        self.disco.register(csi)
        self.disco.register(push)
        self.disco.register(carbons)
        self.disco.register(chatMarkers)
        self.disco.register(presences)
        self.disco.register(avatarManager)
        self.disco.register(devices)
        self.disco.register(omemo)
        self.disco.register(x509Manager)
        self.disco.register(trustSharingManager)
    }
    
    public final func registerRegularPushForAccount() {
        if !self.isRegularPushRequestSended {
            self.isRegularPushRequestSended = true
            DispatchQueue.global(qos: .background).async {
                let didStart = APNSManager.shared.sendRegistrationRequest(forJid: self.jid, voip: false) { success in
                    self.isRegularPushRequestSended = success
                }
                if !didStart {
                    self.isRegularPushRequestSended = false
                }
            }
        }
    }
    
    public final func registerVoIPPushForAccount() {
        if !self.isVoIPPushRequestSended {
            self.isVoIPPushRequestSended = true
            DispatchQueue.global(qos: .background).async {
                let didStart = APNSManager.shared.sendRegistrationRequest(forJid: self.jid, voip: true) { success in
                    self.isVoIPPushRequestSended = success
                }
                if !didStart {
                    self.isVoIPPushRequestSended = false
                }
            }
        }
    }
    
/**
*    calls after roster populating
*    sets normal state for reconnect, synced vcards and message history
*    sends register for push notification request
**/
    func configureBase() {
//        DefaultAvatarManager.shared.updateAvatars(for: self.jid)
        self.sm.autoResume = true
        self.sm.activate(self.xmppStream)
        self.sm.addDelegate(self, delegateQueue: self.queue)
        self.sm.automaticallyRequestAcks(afterStanzaCount: 1, orTimeout: 4)
        self.sm.enable(withResumption: true, maxTimeout: 3600)
        self.logConnectionDiagnostics(
            event: "stream_management_configured",
            details: [
                "autoResume": self.sm.autoResume,
                "resumptionTimeout": 3600
            ]
        )
        if isConfigured {
            return
        }
        isConfigured = true
        self.reconnect.activate(self.xmppStream)
        self.reconnect.addDelegate(self, delegateQueue: self.queue)
        self.reconnect.autoReconnect = true
        self.reconnect.reconnectDelay = 1
        self.reconnect.reconnectTimerInterval = 2
        self.logConnectionDiagnostics(
            event: "reconnect_configured",
            details: [
                "autoReconnect": self.reconnect.autoReconnect,
                "delay": self.reconnect.reconnectDelay,
                "timerInterval": self.reconnect.reconnectTimerInterval
            ]
        )

        
    }
    
/**
 *    calls after base configuration
 *    enables XMPP features: message carbons, push notifications
 **/
    func configureExtensions() {
        self.carbons.set(xmppStream, to: .enabled)
        self.push.enable(xmppStream: self.xmppStream) {
            result in
            self.pushStatusMessage.accept(result)
        }
        
//        ApplicationStateManager.shared.checkApplicationBlockedState(for: self.jid)
    }
    
    func updateExtensions() {
        if self.xmppStream.isDisconnected {
            
        }
        let extensions: [AbstractXMPPManager] = [
            self.devices,
            self.xTokens,
            self.disco,
            self.presences,
            self.messages,
            self.roster,
            self.mam,
            self.carbons,
            self.lastChats,
            self.csi,
            self.push,
            self.vcards,
            self.avatarManager,
            self.ping,
            self.avatarUploader,
            self.blocked,
            self.chatStates,
            self.chatMarkers,
            self.attention,
            self.globalIndex,
            self.groupchats,
            self.deliveryManager,
            self.msgDeleteManager,
            self.syncManager,
            self.x509Manager,
            self.omemo,
            self.deliveryReceipts,
            self.akeManager,
            self.trustSharingManager,
        ]
        extensions.forEach {
            [unowned self] module in
            module.onStreamPrepared(self.xmppStream)
        }
    }
    
/**
 *    open CocoaAsyncSocket and create XMPP session for JID with resource
 *    properties @manuallySetResource and @manuallySetHost sets in connection settings screen
 *    XMPPStream creates in specialized queue, not in main thread
 *    all DB  write operations must perform in thread, which contains XMPPStream
 *    to put XMPPStream into special thread, this method must been calls from DispatchQueue.global(qos: ).async {}
 **/
    @discardableResult
    final func requestConnect(
        trigger: AccountConnectTrigger,
        forceReset: Bool = false,
        prepareStream: (() -> Void)? = nil
    ) -> Bool {
        let frameworkActivePhase = forceReset ? nil : self.frameworkActivePhase()
        let decision = AccountStreamConnectPreflight.decide(
            gate: self.connectionGate,
            trigger: trigger,
            forceReset: forceReset,
            frameworkActivePhase: frameworkActivePhase,
            streamIsDisconnected: self.xmppStream.isDisconnected
        )

        switch decision {
        case .start(let attemptID, let stalePhase):
            if let stalePhase {
                DDLogDebug("reset stale account connection gate jid=\(self.jid) trigger=\(trigger.rawValue) stalePhase=\(stalePhase.rawValue) streamState=\(self.streamStateDescription)")
                self.logConnectionDiagnostics(
                    event: "connect_gate_reset_stale",
                    trigger: trigger,
                    details: ["stalePhase": stalePhase.rawValue]
                )
            }
            self.logConnectionDiagnostics(
                event: "connect_request_started",
                attemptID: attemptID,
                trigger: trigger,
                details: ["forceReset": forceReset]
            )
            prepareStream?()
            self.performConnect(attemptID: attemptID, trigger: trigger)
            return true

        case .skip(let phase, let activeAttemptID, let reason):
            DDLogDebug("skip duplicate account connect jid=\(self.jid) trigger=\(trigger.rawValue) phase=\(phase.rawValue) attempt=\(activeAttemptID.map(String.init) ?? "none") streamState=\(self.streamStateDescription)")
            let details: [String: Any?] = [
                "activeAttempt": activeAttemptID.map(String.init) ?? "none",
                "forceReset": forceReset,
                "reason": reason.rawValue,
                "configurationSkipped": true,
                "activePhase": frameworkActivePhase?.rawValue
            ]
            if reason == .frameworkActive {
                self.logConnectionDiagnostics(
                    event: "connect_request_skipped_framework_active",
                    trigger: trigger,
                    phase: phase,
                    details: details
                )
            } else {
                self.logConnectionDiagnostics(
                    event: "connect_request_skipped_gate",
                    trigger: trigger,
                    phase: phase,
                    details: details
                )
            }
            self.logConnectionDiagnostics(
                event: "connect_request_skipped_before_configuration",
                trigger: trigger,
                phase: phase,
                details: details
            )
            return false
        }
    }

    @objc
    final func connect() {
        self.requestConnect(trigger: .legacyDirect)
    }

    final func cancelDelayedConnectTimer() {
        if self.delayedConnectTimer != nil {
            self.delayedConnectTimer?.invalidate()
            self.delayedConnectTimer = nil
        }
    }

    final func handleConnectTimeout() {
        let attemptID = self.connectionGate.snapshot().activeAttemptID
        guard self.connectionGate.canRetryTimeout(for: attemptID) else {
            DDLogDebug("skip account timeout retry jid=\(self.jid) phase=\(self.connectionGate.snapshot().phase.rawValue) attempt=\(attemptID.map(String.init) ?? "none") streamState=\(self.streamStateDescription)")
            self.logConnectionDiagnostics(
                event: "connect_timeout_retry_skipped",
                details: ["timeoutAttempt": attemptID.map(String.init) ?? "none"]
            )
            AccountManager.shared.markAsNotConnecting(
                jid: self.jid,
                reason: "connect_timeout_retry_skipped",
                clearAuthentication: true
            )
            return
        }

        self.logConnectionDiagnostics(
            event: "connect_timeout_retry_scheduled",
            details: ["timeoutAttempt": attemptID.map(String.init) ?? "none"]
        )
        self.scheduleConnectRetry(after: 1, trigger: .timeoutRetry, attemptID: attemptID)
    }

    private func performConnect(attemptID: UInt64, trigger: AccountConnectTrigger) {
        self.cancelDelayedConnectTimer()
        if self.xmppStream.isConnecting
            || self.xmppStream.isConnected
            || self.xmppStream.isAuthenticated
            || self.xmppStream.isAuthenticating {
            self.connectionGate.adoptFrameworkActivePhase(self.frameworkActivePhase() ?? .connecting)
            DDLogDebug("skip duplicate account connect jid=\(self.jid) trigger=\(trigger.rawValue) phase=\(self.connectionGate.snapshot().phase.rawValue) attempt=\(attemptID) streamState=\(self.streamStateDescription)")
            self.logConnectionDiagnostics(
                event: "connect_perform_skipped_stream_active",
                attemptID: attemptID,
                trigger: trigger
            )
            return
        }
        if self.resource.isNotEmpty {
            self.xmppStream.myJID = XMPPJID(string: self.jid, resource: self.resource)
        } else {
            self.xmppStream.myJID = XMPPJID(string: self.jid, resource: AccountManager.defaultResource)
        }
        if self.manuallySetHost {
            self.xmppStream.hostName = self.host
            self.xmppStream.hostPort = UInt16(self.port)
        }
        if self.push.node != "" && self.push.service != "" {
            self.pushStatusMessage.accept(true)
//            Account§Manager.shared.markAsConnecting(jid: self.jid)
        }
        do {
            DDLogDebug("primary stream connect jid=\(self.jid) trigger=\(trigger.rawValue) attempt=\(attemptID) resource=\(self.xmppStream.myJID?.resource ?? "none") manualHost=\(self.manuallySetHost) hostPresent=\(self.xmppStream.hostName?.isEmpty == false) port=\(self.xmppStream.hostPort) streamState=\(self.streamStateDescription)")
            self.logConnectionDiagnostics(
                event: "connect_start",
                attemptID: attemptID,
                trigger: trigger,
                details: [
                    "resource": self.xmppStream.myJID?.resource ?? "none",
                    "manualHost": self.manuallySetHost,
                    "hostPresent": self.xmppStream.hostName?.isEmpty == false,
                    "host": self.xmppStream.hostName ?? "jid-domain",
                    "port": self.xmppStream.hostPort,
                    "timeout": 15
                ]
            )
            self.beginConnectionDiagnosticsHeartbeat()
            AccountManager.shared.markAsConnecting(jid: self.jid)
            try self.xmppStream.connect(withTimeout: 15)
        } catch {
            DDLogDebug("cant connect: \(error.localizedDescription)")
            self.logConnectionDiagnostics(
                event: "connect_throw",
                attemptID: attemptID,
                trigger: trigger,
                error: error
            )
            self.connectionGate.markFailed()
            self.statusMessage.accept("Offline")
            AccountManager.shared.changeNewUserState(for: self.jid, to: .failure("Server not found"))
            AccountManager.shared.markAsNotConnecting(
                jid: self.jid,
                reason: "connect_throw",
                clearAuthentication: true
            )
//            this.$store.state.current_org_id
        }
        self.isBinded = false
    }

    final func scheduleConnectRetry(after delay: TimeInterval, trigger: AccountConnectTrigger, attemptID: UInt64?) {
        guard self.delayedConnectTimer == nil else { return }
        self.logConnectionDiagnostics(
            event: "connect_retry_timer_scheduled",
            trigger: trigger,
            details: [
                "delay": delay,
                "retryAttempt": attemptID.map(String.init) ?? "none"
            ]
        )
        let context = AccountConnectRetryContext(attemptID: attemptID, trigger: trigger)
        self.delayedConnectTimer = Timer(
            timeInterval: delay,
            target: self,
            selector: #selector(self.delayedConnectTimerDidFire(_:)),
            userInfo: context,
            repeats: false
        )
        RunLoop.main.add(self.delayedConnectTimer!, forMode: RunLoop.Mode.default)
    }

    @objc
    private func delayedConnectTimerDidFire(_ timer: Timer) {
        let context = timer.userInfo as? AccountConnectRetryContext
        self.delayedConnectTimer = nil

        if let attemptID = context?.attemptID,
           !self.connectionGate.canRetryTimeout(for: attemptID) {
            DDLogDebug("skip stale account retry jid=\(self.jid) trigger=\(context?.trigger.rawValue ?? "unknown") attempt=\(attemptID) phase=\(self.connectionGate.snapshot().phase.rawValue) streamState=\(self.streamStateDescription)")
            self.logConnectionDiagnostics(
                event: "connect_retry_timer_skipped_stale",
                trigger: context?.trigger ?? .timeoutRetry,
                details: ["retryAttempt": attemptID]
            )
            return
        }

        self.logConnectionDiagnostics(
            event: "connect_retry_timer_fired",
            trigger: context?.trigger ?? .timeoutRetry,
            details: ["retryAttempt": context?.attemptID.map(String.init) ?? "none"]
        )
        self.resetStream()
        self.requestConnect(
            trigger: context?.trigger ?? .timeoutRetry,
            forceReset: true,
            prepareStream: { self.configureStream() }
        )
    }

    private func frameworkActivePhase() -> AccountStreamLifecyclePhase? {
        if self.xmppStream.isAuthenticated {
            return .online
        }
        if self.xmppStream.isAuthenticating {
            return .authenticating
        }
        if self.xmppStream.isConnected {
            return .postAuthSetup
        }
        if self.xmppStream.isConnecting {
            return .connecting
        }
        return nil
    }

    private var streamStateDescription: String {
        return ConnectionDiagnosticsLogger.stateDescription(for: self.xmppStream)
    }

    final func logConnectionDiagnostics(
        event: String,
        attemptID: UInt64? = nil,
        trigger: AccountConnectTrigger? = nil,
        phase: AccountStreamLifecyclePhase? = nil,
        details: [String: Any?] = [:],
        rawXML: String? = nil,
        error: Error? = nil
    ) {
        let snapshot = self.connectionGate.snapshot()
        ConnectionDiagnosticsLogger.log(
            event: event,
            stream: .primary,
            jid: self.jid,
            attemptID: attemptID ?? snapshot.activeAttemptID,
            trigger: trigger,
            phase: phase ?? snapshot.phase,
            state: self.streamStateDescription,
            details: details,
            rawXML: rawXML,
            error: error
        )
    }

    final func beginConnectionDiagnosticsHeartbeat() {
        connectionDiagnosticsLock.lock()
        connectionDiagnosticsHeartbeatID += 1
        let heartbeatID = connectionDiagnosticsHeartbeatID
        connectionDiagnosticsLock.unlock()
        self.scheduleConnectionDiagnosticsHeartbeat(id: heartbeatID)
    }

    final func beginStartTLSDiagnosticsWatch() {
        let snapshot = self.connectionGate.snapshot()
        connectionDiagnosticsLock.lock()
        startTLSStallWatchID += 1
        let watchID = startTLSStallWatchID
        startTLSDelegateCallbackWatchID = nil
        connectionDiagnosticsLock.unlock()

        let attemptID = snapshot.activeAttemptID
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self else { return }
            guard self.shouldLogStartTLSStall(watchID: watchID, attemptID: attemptID) else { return }
            let snapshot = self.connectionGate.snapshot()
            ConnectionDiagnosticsLogger.log(
                event: "tls_stall_detected",
                stream: .primary,
                jid: self.jid,
                attemptID: attemptID,
                phase: snapshot.phase,
                details: [
                    "reason": "tlsDelegateCallbackNotObservedWithin2s",
                    "watchID": watchID
                ]
            )
        }
    }

    final func markStartTLSDelegateCallbackEntered() {
        connectionDiagnosticsLock.lock()
        startTLSDelegateCallbackWatchID = startTLSStallWatchID
        connectionDiagnosticsLock.unlock()
    }

    private func scheduleConnectionDiagnosticsHeartbeat(id: UInt64) {
        let expectedAt = ProcessInfo.processInfo.systemUptime + 1
        self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            guard self.isCurrentConnectionDiagnosticsHeartbeat(id: id) else { return }

            let now = ProcessInfo.processInfo.systemUptime
            let delayMs = Int((max(0, now - expectedAt) * 1000).rounded())
            if delayMs > 1500 {
                self.logConnectionDiagnostics(
                    event: "account_queue_heartbeat_delayed",
                    details: [
                        "delayMs": delayMs,
                        "heartbeatID": id
                    ]
                )
            }

            guard self.connectionGate.snapshot().phase.isConnectionDiagnosticsHeartbeatActive else {
                return
            }
            self.scheduleConnectionDiagnosticsHeartbeat(id: id)
        }
    }

    private func isCurrentConnectionDiagnosticsHeartbeat(id: UInt64) -> Bool {
        connectionDiagnosticsLock.lock()
        defer { connectionDiagnosticsLock.unlock() }
        return connectionDiagnosticsHeartbeatID == id
    }

    private func shouldLogStartTLSStall(watchID: UInt64, attemptID: UInt64?) -> Bool {
        connectionDiagnosticsLock.lock()
        let isCurrentWatch = startTLSStallWatchID == watchID
        let callbackObserved = startTLSDelegateCallbackWatchID == watchID
        connectionDiagnosticsLock.unlock()

        guard isCurrentWatch, !callbackObserved else { return false }
        let snapshot = self.connectionGate.snapshot()
        guard snapshot.phase == .tlsNegotiating else { return false }
        if let attemptID {
            return snapshot.activeAttemptID == attemptID
        }
        return true
    }
    
/**
 *    open XMPPStream in special thread
 **/
    func asyncConnect(shouldReregisterDFevice: Bool = false, trigger: AccountConnectTrigger = .initialLoad) {
        let connectTrigger: AccountConnectTrigger = shouldReregisterDFevice ? .deviceReregister : trigger
        DDLogDebug("account async connect jid=\(self.jid) trigger=\(connectTrigger.rawValue) reregisterDevice=\(shouldReregisterDFevice) deviceIdPresent=\(self.devices.deviceId?.isEmpty == false) manualHost=\(self.manuallySetHost) hostPresent=\(self.host.isEmpty == false) port=\(self.port) resourcePresent=\(self.resource.isEmpty == false) phase=\(self.connectionGate.snapshot().phase.rawValue) streamState=\(self.streamStateDescription)")
        self.logConnectionDiagnostics(
            event: "async_connect_requested",
            trigger: connectTrigger,
            details: [
                "reregisterDevice": shouldReregisterDFevice,
                "deviceIdPresent": self.devices.deviceId?.isEmpty == false,
                "manualHost": self.manuallySetHost,
                "hostPresent": self.host.isEmpty == false,
                "port": self.port,
                "resourcePresent": self.resource.isEmpty == false
            ]
        )
        if shouldReregisterDFevice {
            if let deviceId = self.devices.deviceId {
                self.logConnectionDiagnostics(
                    event: "device_reregister_reset_stream",
                    trigger: connectTrigger,
                    details: ["deviceIdPresent": deviceId.isEmpty == false]
                )
                self.resetStream()
                self.xmppStream.xabberDeviceId = deviceId
                self.sm.storage.removeAll(for: self.xmppStream)
                self.smStorage.removeAll(for: self.xmppStream)
                self.smStorage.setResumptionId(nil, timeout: 0, lastDisconnect: nil, for: self.xmppStream)
            }
        }
        self.requestConnect(
            trigger: connectTrigger,
            forceReset: shouldReregisterDFevice,
            prepareStream: { self.configureStream() }
        )
    }
    
/**
 *    stop user XMPP session, change account status to offline
 *    if @hard is true, session close without sending unavailable presence to server
 **/
    func disconnect(hard: Bool = false) {
        let wasDisconnected = self.xmppStream.isDisconnected
        DDLogDebug("account disconnect requested jid=\(self.jid) hard=\(hard) phase=\(self.connectionGate.snapshot().phase.rawValue) streamState=\(self.streamStateDescription)")
        self.logConnectionDiagnostics(
            event: "disconnect_requested",
            details: [
                "hard": hard,
                "wasDisconnected": wasDisconnected
            ]
        )
        self.cancelDelayedConnectTimer()
        AccountManager.shared.markAsNotConnecting(
            jid: self.jid,
            reason: hard ? "local_hard_disconnect" : "local_soft_disconnect",
            clearAuthentication: true
        )
        if wasDisconnected {
            self.connectionGate.markDisconnected()
            DDLogDebug("account disconnect completed locally jid=\(self.jid) hard=\(hard) reason=streamAlreadyDisconnected")
            self.logConnectionDiagnostics(
                event: "disconnect_completed_local",
                details: [
                    "hard": hard,
                    "reason": "streamAlreadyDisconnected"
                ]
            )
        } else {
            self.connectionGate.markDisconnecting()
        }
        self.statusState.accept(.offline)
        self.statusMessage.accept(RosterUtils.shared.convertStatus(.offline))
        self.resetModules()
        XMPPUIActionManager.shared.close(disconnect: true)
        if hard {
            guard !wasDisconnected else { return }
            self.xmppStream.disconnect()
//            self.xmppStream.asyncSocket.disconnect()
        } else {
            self.reconnect.autoReconnect = false
            guard !wasDisconnected else { return }
            self.xmppStream.send(XMPPPresence(type: .unavailable))
            self.xmppStream.disconnectAfterSending()
//            self.xmppStream.asyncSocket.disconnectAfterReadingAndWriting()
        }
    }
    
/**
 *    update presence status by last setted in settings
 **/
    func presence(_ opponentJid: XMPPJID? = nil) {
        do {
            let realm = try  WRealm.safe()
            if let instance = realm
                .object(ofType: AccountStorageItem.self,
                        forPrimaryKey: self.jid)?
                .resource {
                self.presences.updateMyself(self.xmppStream,
                                            with: instance,
                                            ver: self.disco.generateVer(),
                                            to: opponentJid)
                self.statusState.accept(instance.status)
                self.statusMessage.accept(instance.statusMessage.isNotEmpty ? instance.statusMessage : RosterUtils.shared.convertStatus(instance.status))
            } else {
                let instance = ResourceStorageItem()
                instance.owner = self.jid
                instance.jid = self.jid
                instance.isCurrentResourceForAccount = true
                instance.resource = self.resource
                instance.client = ""
                instance.priority = 0
                instance.status = .online
                instance.statusMessage = ""
                instance.isTemporary = false
                instance.primary = ResourceStorageItem.genPrimary(jid: self.jid, owner: self.jid, resource: self.resource)
                if !realm.isInWriteTransaction {
                    try realm.write {
                        realm.add(instance, update: .modified)
                        realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid)?.resource = instance
                    }
                }
                self.presences.updateMyself(xmppStream, with: instance, ver: self.disco.generateVer(), to: opponentJid)
                self.statusState.accept(.online)
                self.statusMessage.accept(RosterUtils.shared.convertStatus(.online))
            }
        } catch {
            DDLogDebug("cant load status item instance for jid \(self.jid)")
        }
    }
    
/**
 *    update account status in subscription, in realm instance and send XMPPPresence to server
 **/
    func updateStatus(_ newStatus: ResourceStatus, with newMessage: String?) {
        func send(_ instance: ResourceStorageItem) {
            if newStatus == .offline {
                return
            } else {
                if self.xmppStream.isAuthenticated {
                    if newMessage == nil {
                        self.statusMessage.accept(RosterUtils.shared.convertStatus(newStatus))
                    } else {
                        self.statusMessage.accept(newMessage!.isNotEmpty ? newMessage! : RosterUtils.shared.convertStatus(newStatus))
                    }
                    self.statusState.accept(newStatus)
                    self.presences.updateMyself(self.xmppStream,
                                                with: instance,
                                                ver: self.disco.generateVer(),
                                                to: nil)
                } else {
                    self.asyncConnect(trigger: .statusUpdate)
                }
            }
        }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: ResourceStorageItem.self, forPrimaryKey: [jid, resource, jid].prp()) {
                if newStatus != .offline {
                    if !realm.isInWriteTransaction {
                        try realm.write {
                            instance.status = newStatus
                            instance.statusMessage = newMessage ?? ""
                            instance.timestamp = Date()
                            instance.isCurrentResourceForAccount = true
                        }
                    }
                }
                send(instance)
            } else {
                if newStatus != .offline {
                    let instance = ResourceStorageItem()
                    instance.owner = jid
                    instance.jid = jid
                    instance.isCurrentResourceForAccount = true
                    instance.resource = resource
                    instance.status = newStatus
                    instance.statusMessage = newMessage ?? ""
                    instance.timestamp = Date()
                    instance.isTemporary = false
                    instance.primary = ResourceStorageItem.genPrimary(jid: jid, owner: jid, resource: resource)
                    if !realm.isInWriteTransaction {
                        try realm.write {
                            realm.add(instance, update: .modified)
                            realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid)?.resource = instance
                        }
                    }
                    send(instance)
                }
            }
        } catch {
            DDLogDebug("cant update presence for account \(jid)")
        }
    }
    
/**
 *    sets configs and flags to initial state
 *    calls after any kind of disconnect
 **/
    func resetConfigs() {
        self.isRequestedAway = false
        self.isInitialMAMRequestSend = false
    }
    
/**
 *    sets modules to initial state
 *    calls after any kind of disconnect
 **/
    func resetModules() {
//        self.statusMessage.accept("Waiting for network")
        self.statusMessage.accept("Offline")
        self.mam.didResetState()
        self.presences.didResetState()
        self.msgDeleteManager.clearSession()
        self.devices.clearSession()
        self.groupchats.reset()
        self.syncManager.reset()
    }

/**
 *    returns account status based on XMPPStream state
 **/
    func status() -> ResourceStatus {
        if self.xmppStream.isAuthenticated {
            return ResourceStatus.online
        } else {
            return ResourceStatus.offline
        }
    }
    
/**
 *    sends request to XMPP Message archive (XEP-0313)
 *    if its first request for account, it perform request for all contacts in roster by 1 message
 *    if it calls after initial state, when some last chats are exists,
 *    it perform request from last message delivery date to current moment by 50 message.
 *    if query size more than contains in one page, all other chats updates by individual request by 1 message
 **/
    func requestInitialMAM() {
//        if mam.isInitialArchiveRequested {
//            mam.requestAfterLastMessage(xmppStream, sync: true)
//        } else {
//            mam.requestForRoster(xmppStream)
//        }
        self.isInitialMAMRequestSend = true
        self.isRequestedAway = true
    }
    
/**
 *    used by push notification
 *    when push notification come, method compare last away date with current moment
 **/
    
//    func syncForPush() {
//        mam.requestAfterLastMessage(xmppStream, sync: false)
//    }
    
/**
 *    get stored properties about account from Realm
 **/
    func load() {
        do {
            let realm = try  WRealm.safe()
            if let item = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.jid) {
                self.jid = item.jid
                self.host = item.host
                self.supportTokens = item.xTokenSupport
                self.tokenUid = item.xTokenUID
                self.savePassword = item.savePassword
                self.manuallySetHost = item.manuallySetHost
                self.port = item.port
                self.deviceName = item.deviceName
                if let resource = item.resource?.resource {
                    self.resource = resource
                }
                self.username = item.username
                self.push.node = item.node
                self.push.service = item.service
            }
            if  self.deviceName.isEmpty {
                self.deviceName = NickGenerator.shared.genRandomNick()
            }
        } catch {
            DDLogDebug("cant load user \(self.jid) from db")
        }
    }
    
/**
 *    to enable push notification, you need register on App server
 *    response of App server contains information about node and service
 *    calls to update push service information
 *    @node - address, which associated with your jid on pubsub
 *    @service - jid of pubsub, which should send push notification to App server
 *    this properties must update at done of any auth process for account
 *    but, client can use stored in Realm properties values
 **/
    func update(forPushNode node: String, withService service: String) {
        self.push.configure(node: node, service: service)
        do {
            let realm = try  WRealm.safe()
            if let item = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.jid) {
                try realm.write {
                    item.node = node
                    item.service = service
                }
            }
        } catch {
            DDLogDebug("cant update push info for user \(jid)")
        }
    }
    
/**
 *    save token to keychain, override password
 */

    
/**
 *    change username and store it in db
 **/
    func updateUsername(_ username: String) {
        self.username = username
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.jid) {
                if !realm.isInWriteTransaction {
                    try realm.write {
                        instance.username = username
                    }
                }
            }
        } catch {
            DDLogDebug("cant change username for account \(self.jid)")
        }
    }
    
/**
 *    update creditionals and make reconnect. if success, error message is nil
 **/
    func updateResource(_ resource: String, callback: ((String?) -> Void)? = nil) {
        print(#function)
        disconnect(hard: true)
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: ResourceStorageItem.self,
                                           forPrimaryKey: [self.jid, self.resource, self.jid].prp()) {
                let newStatus = ResourceStorageItem()
                newStatus.owner = jid
                newStatus.jid = jid
                newStatus.isCurrentResourceForAccount = true
                newStatus.resource = resource
                let status = instance.status_
                let message = instance.statusMessage
                let priority = instance.priority
                newStatus.status_ = status
                newStatus.statusMessage = message
                newStatus.priority = priority
                newStatus.isTemporary = false
                newStatus.primary = ResourceStorageItem.genPrimary(jid: jid, owner: jid, resource: resource)
                if !realm.isInWriteTransaction {
                    try realm.write {
                        realm.delete(instance)
                        realm.add(newStatus, update: .all)
                        realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid)?.resource = newStatus
                    }
                }
            } else {
                let instance = ResourceStorageItem()
                instance.owner = jid
                instance.jid = jid
                instance.isCurrentResourceForAccount = true
                instance.resource = resource
                instance.status_ = ResourceStatus.online.rawValue
                instance.statusMessage = ""
                instance.priority = 0
                instance.isTemporary = false
                instance.primary = ResourceStorageItem.genPrimary(jid: jid, owner: jid, resource: resource)
                if !realm.isInWriteTransaction {
                    try realm.write {
                        realm.add(instance, update: .modified)
                        realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid)?.resource = instance
                    }
                }
            }
        } catch {
            DDLogDebug("cant update creditionals for account \(jid)")
            callback?("Error during password or resource update".localizeString(id: "error_during_password_resource_update", arguments: []))
        }
        self.resource = resource.isEmpty ? AccountManager.defaultResource : resource
        self.asyncConnect(trigger: .resourceUpdate)
        callback?(nil)
    }
    
/**
 *    save account properties in Realm
 **/
    func create() {
        autoreleasepool {
            do {
                let realm = try  WRealm.safe()
                let item = AccountStorageItem()
                item.order = realm.objects(AccountStorageItem.self).count
                item.jid = self.jid
                item.host = self.host
                item.savePassword = self.savePassword
                item.manuallySetHost = self.manuallySetHost
                item.port = self.port
                if CommonConfigManager.shared.config.locked_account_color.isNotEmpty {
                    item.colorKey = CommonConfigManager.shared.config.locked_account_color
                } else {
                    item.colorKey = AccountColorManager.shared.colorItem(for: self.jid).key
                }
                
                item.username = self.username
                item.node = self.push.node
                item.service = self.push.service
                item.statusMessage = self.statusMessage.value
                item.xTokenSupport = self.supportTokens
                item.xTokenUID = self.tokenUid
                item.createdAt = Date()
                
                item.deviceName = self.deviceName
                if let deviceId = self.devices.deviceId {
                    item.deviceUuid = deviceId
                }
                
                try realm.write {
                    realm.add(item, update: .modified)
                }
            } catch {
                DDLogDebug("cant update push info for user \(self.jid)")
            }
        }
    }
    
    func disable() {
        self.xmppStream.removeDelegate(self)
        self.push.disable(xmppStream: xmppStream)
        APNSManager.shared.sendDeleteRequest(jid: jid, voip: true)
        APNSManager.shared.sendDeleteRequest(jid: jid, voip: false)
        PushNotificationsManager.removeDefaultsForPush(target: push.node, jid: jid)
        self.disconnect(hard: false)
    }
    
/**
 *    delete all stored data
 **/
    func dropData() {
        self.xmppStream.removeDelegate(self)
        if self.supportTokens {
            self.xTokens.revoke(self.xmppStream, uids: [self.tokenUid])
        }
        self.disconnect(hard: false)
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        APNSManager.shared.sendDeleteRequest(jid: owner, voip: true)
        APNSManager.shared.sendDeleteRequest(jid: owner, voip: false)
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        
        _ = keychain.removeObject(forKey: owner)
        _ = keychain.removeObject(forKey: [owner, "token"].prp())
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner) {
                PushNotificationsManager.removeDefaultsForPush(target: instance.node, jid: owner)
                if commitTransaction {
                    if !realm.isInWriteTransaction {
                        try realm.write {
                            if instance.isInvalidated { return }
                            realm.delete(instance)
                        }
                    }
                } else {
                    if instance.isInvalidated { return }
                    realm.delete(instance)
                }
            }
        } catch {
            DDLogDebug("cant delete server disco for account \(owner)")
        }
    }
    
/**
 *    delete stored messages
 *    @jid - remove messages for contact of account
 *    @forAll - remove all messages for account
 **/
    func removeMessages(forJid jid: String = "", commitTransaction: Bool) {
        do {
            let realm = try  WRealm.safe()
            var messages = realm.objects(MessageStorageItem.self).filter("owner == %@", self.jid)
            if jid.isNotEmpty {
                messages = messages.filter("opponent == %@", jid)
            }
//            var attaches: [MessageAttachmentStorageItem] = []
            var stanzas: [MessageStanzaStorageItem] = []
            messages.forEach {
                message in
                if let instance = realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: "\(message.primary)_stanza") {
                    stanzas.append(instance)
                }
            }
            let inlines = realm.objects(MessageForwardsInlineStorageItem.self).filter("owner == %@", self.jid)
            let refs = realm.objects(MessageReferenceStorageItem.self).filter("owner == %@", self.jid)
            var calls = realm.objects(CallMetadataStorageItem.self).filter("owner == %@", self.jid)
            if jid.isNotEmpty {
                calls = calls.filter("opponent == %@", jid)
            }
            if commitTransaction {
                try realm.write {
                    realm.delete(messages)
                    realm.delete(inlines)
                    realm.delete(refs)
                    realm.delete(stanzas)
                    realm.delete(calls)
                }
            } else {
                realm.delete(messages)
                realm.delete(inlines)
                realm.delete(refs)
                realm.delete(stanzas)
                realm.delete(calls)
            }
            
        } catch {
            DDLogDebug("cant remove messages for account \(self.jid)")
        }
    }

/**
 *    change state flag of push service for account and notify all subscribers
 **/
    func setPushState(state: Bool, callback: ()->Void) {
        self.pushWasReceived = state
        callback()
    }

/**
 *    set completion handler for catch end of push notification message loader
 **/
    func setCompletionHandler(completionHandler: (() -> Void)?) {
        self.completionHandler = completionHandler
    }

    func initiateCompleteRequest() {
        if self.completionHandlerTimer != nil {
            self.completionHandlerTimer!.invalidate()
            self.completionHandlerTimer = nil
        }
    }

/**
 *    notify application, that all messages, downloaded by push notify request, has been saved
 **/
    @objc func callCompletionHandler() {
        if self.completionHandler != nil {
            self.pushWasReceived = false
            self.completionHandler!()
            DDLogDebug("call completion handler")
        }
    }
    
/**
 *    emulate point to perform action from account
 *    example -
 *    user.action {
 *       (user, xmppStream) in
 *       your code here
 *    }
 **/
    func action(_ toExecute: @escaping ((Account, XMPPStream) -> Void)) {
        self.queue.async {
//            [unowned self] in
            toExecute(self, self.xmppStream)
        }
    }
    
    func delayedAction(delay: TimeInterval, toExecute: @escaping ((Account, XMPPStream) -> Void)) {
        DispatchQueue(
            label: "com.xabber.action.delayed.\(jid).\(UUID().uuidString)",
            qos: .background,
            attributes: .concurrent,
            autoreleaseFrequency: .workItem,
            target: nil
        ).asyncAfter(deadline: .now() + delay ) {
            [unowned self] in
            toExecute(self, self.xmppStream)
        }
    }
    
    func unsafeAction(_ toExecute: @escaping (Account, XMPPStream) -> Void) {
        toExecute(self, self.xmppStream)
    }
}

extension Account: XMPPReconnectDelegate {
    func showReconnectStatus(connectionFlags: SCNetworkConnectionFlags) {
        switch connectionFlags{
        case UInt32(kSCNetworkFlagsTransientConnection):
            DDLogDebug("kSCNetworkFlagsTransientConnection")
            break
        case UInt32(kSCNetworkFlagsReachable):
            DDLogDebug("kSCNetworkFlagsReachable")
            break
        case UInt32(kSCNetworkFlagsConnectionRequired):
            DDLogDebug("kSCNetworkFlagsConnectionRequired")
            break
        case UInt32(kSCNetworkFlagsConnectionAutomatic):
            DDLogDebug("kSCNetworkFlagsConnectionAutomatic")
            break
        case UInt32(kSCNetworkFlagsInterventionRequired):
            DDLogDebug("kSCNetworkFlagsInterventionRequired")
            break
        case UInt32(kSCNetworkFlagsIsLocalAddress):
            DDLogDebug("kSCNetworkFlagsIsLocalAddress")
            break
        case UInt32(kSCNetworkFlagsIsDirect):
            DDLogDebug("kSCNetworkFlagsIsDirect")
            break
        default:
            DDLogDebug("none flag")
        }
    }
    
    func xmppReconnect(_ sender: XMPPReconnect, didDetectAccidentalDisconnect connectionFlags: SCNetworkConnectionFlags) {
        DDLogDebug("DidDetectDisconnect. Connection flags \(connectionFlags)")
        self.logConnectionDiagnostics(
            event: "reconnect_detected_accidental_disconnect",
            details: ["connectionFlags": UInt32(connectionFlags)]
        )
        self.resetModules()
        self.statusMessage.accept("Offline")
        self.showReconnectStatus(connectionFlags: connectionFlags)
        AccountManager.shared.markAsConnecting(jid: self.jid)
    }
    
    func xmppReconnect(_ sender: XMPPReconnect, shouldAttemptAutoReconnect connectionFlags: SCNetworkConnectionFlags) -> Bool {
        DDLogDebug("ShouldAttemptAutoReconnect. Connection flags \(connectionFlags)")
        self.logConnectionDiagnostics(
            event: "reconnect_should_attempt",
            trigger: .xmppReconnect,
            details: [
                "connectionFlags": UInt32(connectionFlags),
                "autoReconnect": sender.autoReconnect
            ]
        )
//        if UInt32(connectionFlags) == 3 {
//            return false
//        }
//        self.showReconnectStatus(connectionFlags: connectionFlags)
//        DispatchQueue.main.async {
//            ToastPresenter(message: "Reconnect: flag \(UInt32(connectionFlags))").present(animated: true)
//        }
        if self.xmppStream.isAuthenticated {
            self.logConnectionDiagnostics(
                event: "reconnect_skipped_authenticated",
                trigger: .xmppReconnect,
                details: ["connectionFlags": UInt32(connectionFlags)]
            )
            return false
        }
        if self.xmppStream.isConnected || self.xmppStream.isConnecting || self.xmppStream.isAuthenticating {
            DDLogDebug("skip duplicate account reconnect jid=\(self.jid) streamState=\(self.streamStateDescription)")
            self.logConnectionDiagnostics(
                event: "reconnect_skipped_stream_active",
                trigger: .xmppReconnect,
                details: ["connectionFlags": UInt32(connectionFlags)]
            )
            return false
        }

        guard sender.autoReconnect else {
            self.logConnectionDiagnostics(
                event: "reconnect_skipped_disabled",
                trigger: .xmppReconnect,
                details: ["connectionFlags": UInt32(connectionFlags)]
            )
            return false
        }

        switch self.connectionGate.beginConnect(trigger: .xmppReconnect) {
        case .start(let attemptID):
            DDLogDebug("primary stream reconnect jid=\(self.jid) attempt=\(attemptID)")
            self.logConnectionDiagnostics(
                event: "reconnect_allowed",
                attemptID: attemptID,
                trigger: .xmppReconnect,
                details: ["connectionFlags": UInt32(connectionFlags)]
            )
            self.beginConnectionDiagnosticsHeartbeat()
            AccountManager.shared.markAsConnecting(jid: self.jid)
            return true

        case .skip(let phase, let activeAttemptID):
            DDLogDebug("skip duplicate account reconnect jid=\(self.jid) phase=\(phase.rawValue) attempt=\(activeAttemptID.map(String.init) ?? "none")")
            self.logConnectionDiagnostics(
                event: "reconnect_skipped_gate",
                trigger: .xmppReconnect,
                phase: phase,
                details: [
                    "connectionFlags": UInt32(connectionFlags),
                    "activeAttempt": activeAttemptID.map(String.init) ?? "none"
                ]
            )
            return false
        }
    }
    
}
