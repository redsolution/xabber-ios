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
import WebRTC
import CocoaAsyncSocket

protocol VoIPCallDelegate {
    func VoIPCallDidChangeState(_ call: VoIPCall, to state: VoIPCall.State)
    func VoIPCallDidAccepted(_ call: VoIPCall)
    func VoIPCallDidExpired(_ call: VoIPCall)
    func VoIPCallDidHeld(_ call: VoIPCall)
    func VoIPCallDidEndWith(_ call: VoIPCall, error: Error?, byActiveStream: Bool)
    func VoIPCallDidReceive(_ call: VoIPCall, sessionDescription: RTCSessionDescription)
    func VoIPCallDidReceive(_ call: VoIPCall, iceCandidate: RTCIceCandidate)
    func VoIPCallDidChangeVideoState(_ call: VoIPCall, to state: VoIPCall.VideoState, myself: Bool)
    func VoIPCallDidUpdateContactJid(_ call: VoIPCall)
    func VoIPCallDidReceiveRejectMessage(_ call: VoIPCall, endReason: String?, callInitiator: String?, isCarbon: Bool, fromCurrentDevice: Bool)
    func VoIPCallDidReceiveJingleError(_ call: VoIPCall, action: String, condition: String?, text: String?)
    func VoIPCallDidSendPropose(_ call: VoIPCall)
    func VoIPCallEndCallAnswerElsewhere(_ call: VoIPCall)
    func VoIPCallEndCallRejected(_ call: VoIPCall)
}

enum VoIPCallError: Error {
    case xmppErrorConnectionFailed
    case xmppErrorInvalidPassword
    case xmppErrorAuthenticationFailed
    case callAcceptedButNotConfirmed
}

final class VoIPCall: NSObject {

    public enum State: Int {
        case initiated = 0
        case proposed
        case confirmed
        case notConfirmed
        case accepted
        case connecting
        case connected
        case disconnected
        case holded
        case ended
    }
    
    public static let namespace: String = "urn:xmpp:jingle-message:0"
    internal static let connectTimeout: TimeInterval = 15.0

    internal enum IncomingIQRoute: Equatable {
        case sessionDescription
        case candidate
        case videoState
        case confirmRequest
        case jingleError
        case acknowledgement
        case unhandled
    }

    internal static func incomingIQRoute(for iq: XMPPIQ) -> IncomingIQRoute {
        if iq.iqType == .set {
            if let action = iq
                .element(forName: "jingle", xmlns: "urn:xmpp:jingle:1")?
                .attributeStringValue(forName: "action") {
                switch action {
                case "session-initiate", "session-update", "session-accept":
                    return .sessionDescription
                case "session-info":
                    return .candidate
                default:
                    return .unhandled
                }
            }
            if iq
                .element(forName: "query", xmlns: VoIPCall.namespace)?
                .element(forName: "video") != nil {
                return .videoState
            }
            return .unhandled
        }
        if iq.iqType == .get,
           iq
            .element(forName: "query", xmlns: VoIPCall.namespace)?
            .element(forName: "session") != nil {
            return .confirmRequest
        }
        if iq.iqType == .error {
            if let action = iq
                .element(forName: "jingle", xmlns: "urn:xmpp:jingle:1")?
                .attributeStringValue(forName: "action") {
                switch action {
                case "session-initiate", "session-update", "session-accept", "session-info":
                    return .jingleError
                default:
                    break
                }
            }
            return .acknowledgement
        }
        if iq.iqType == .result {
            return .acknowledgement
        }
        return .unhandled
    }
    
    public var owner: String
    public var jid: String
    public var callId: String
    public var callUUID: UUID
    internal var outgoing: Bool
    internal var password: String?
    
    internal var stream: XMPPStream
    let authenticationCounterTracker = XMPPAuthenticationCounterTracker()
    
    public var delegate: VoIPCallDelegate?
    
    internal var queue: DispatchQueue
    
    internal var isCancelled: Bool = false
    
    internal var isMade: Bool = false
    
    internal var shouldSendReject: Bool = true
    
    internal var isConfirmationRequestSend: Bool = false
    internal var isConfirmed: Bool = false
    internal var confirmationId: String? = nil
    
    internal var start: Date?
    internal var end: Date?
    
    internal var stanzaQueue: SynchronizedArray<DDXMLElement>
    
    internal var lastPingElementID: String = ""
    internal var lastPingTimer: Timer? = nil
    
    internal var reconnect: XMPPReconnect
    internal var shouldConfirmOnAuthenticate: Bool = false
    internal var shouldDisconnectAfterQueuedRejectSend: Bool = false
    internal var queuedRejectTimeoutWorkItem: DispatchWorkItem?
    internal var queuedRejectDidFinish: (() -> Void)?
    internal var shouldStartSignalingForQueuedReject: Bool = true
    private var hasAuthenticatedStream: Bool = false
    
    var backgroundUpdateTask: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 0)
    
    internal var state: State {
        didSet {
            guard oldValue != state else { return }
            print("change voip state to \(state)")
            if state == .connected {
                self.isMade = true
            }
            DispatchQueue.main.async {
                self.delegate?.VoIPCallDidChangeState(self, to: self.state)
            }
        }
    }
    
    init(owner: String, fullJid jid: String, callId: String, callUUID: UUID, outgoing: Bool) {
        self.owner = owner
        self.jid = jid
        self.callId = callId
        self.callUUID = callUUID
        self.outgoing = outgoing
        self.password = nil
        self.stream = XMPPStream()
        self.queue = DispatchQueue(
            label: "com.xabber.voip_signal_queue.\(self.callId)",
            qos: .userInteractive,
            attributes: [],
            autoreleaseFrequency: .workItem,
            target: nil
        )
        self.reconnect = XMPPReconnect(dispatchQueue: queue)
        
        self.stanzaQueue = SynchronizedArray<DDXMLElement>()
        self.state = .initiated
        super.init()
        
        self.stream.startTLSPolicy = XMPPStreamStartTLSPolicy.preferred
        self.stream.keepAliveInterval = 60
        self.stream.addDelegate(self, delegateQueue: self.queue)
        self.stream.asyncSocket.autoDisconnectOnClosedReadStream = true
        
        self.reconnect.activate(self.stream)
    }
    
    private final func endBackgroundTask() {
        UIApplication.shared.endBackgroundTask(self.backgroundUpdateTask)
        self.backgroundUpdateTask = UIBackgroundTaskIdentifier.invalid
    }
    
    private final func connect() {
        guard !self.stream.isConnecting,
              !self.stream.isConnected,
              !self.stream.isAuthenticating,
              !self.stream.isAuthenticated else {
            DDLogDebug("VoIPCall: skip duplicate stream connect owner=\(owner) callId=\(callId) state=\(streamStateDescription)")
            self.logConnectionDiagnostics(
                event: "connect_request_skipped_framework_active",
                details: [
                    "callId": self.callId,
                    "callState": self.state,
                    "queuedStanzas": self.stanzaQueue.count
                ]
            )
            return
        }

        self.hasAuthenticatedStream = false
        self.stream.myJID = XMPPJID(
            string: self.owner,
            resource: self.voipResource
        )
        let hostMode = self.applyAccountConnectionSettings()
        self.logConnectionDiagnostics(
            event: "stream_configured",
            details: [
                "callId": self.callId,
                "resource": self.stream.myJID?.resource ?? "none",
                "tlsPolicy": self.stream.startTLSPolicy.rawValue,
                "keepAlive": self.stream.keepAliveInterval,
                "hostMode": hostMode,
                "queuedStanzas": self.stanzaQueue.count
            ]
        )
        self.queue.async {
            do {
                DDLogDebug("VoIPCall: stream connect start owner=\(self.owner) callId=\(self.callId) resource=\(self.voipResource) hostMode=\(hostMode) queued=\(self.stanzaQueue.count) timeout=\(Self.connectTimeout)")
                self.logConnectionDiagnostics(
                    event: "connect_start",
                    details: [
                        "callId": self.callId,
                        "resource": self.voipResource,
                        "hostMode": hostMode,
                        "host": self.stream.hostName ?? "jid-domain",
                        "port": self.stream.hostPort,
                        "timeout": Self.connectTimeout,
                        "queuedStanzas": self.stanzaQueue.count
                    ]
                )
                try self.stream.connect(withTimeout: Self.connectTimeout)
            } catch {
                DDLogDebug("VoIPCall: \(#function). \(error.localizedDescription)")
                self.logConnectionDiagnostics(
                    event: "connect_throw",
                    details: ["callId": self.callId],
                    error: error
                )
                DispatchQueue.main.async {
                    self.delegate?.VoIPCallDidEndWith(self, error: VoIPCallError.xmppErrorConnectionFailed, byActiveStream: false)
                }
            }
        }
    }
    
    internal final func doReconnect() {
        self.stream.disconnect()
        self.connect()
    }

    public final func start(shouldConfirmOnAuthenticate: Bool) {
        self.shouldConfirmOnAuthenticate = shouldConfirmOnAuthenticate
        self.connect()
    }

    private final func startSignalingIfNeededForQueuedSend() {
        guard shouldStartSignalingForQueuedReject,
              !stream.isAuthenticated,
              !stream.isConnected,
              !stream.isConnecting else {
            return
        }
        self.shouldConfirmOnAuthenticate = false
        self.connect()
    }
    
    public final func disconnect() {
        guard let jid = stream.myJID?.bare else { return }
        self.logConnectionDiagnostics(
            event: "disconnect_requested",
            details: ["callId": self.callId]
        )
        queuedRejectTimeoutWorkItem?.cancel()
        queuedRejectTimeoutWorkItem = nil
        CredentialsManager.shared.getItem(for: jid).release(.authFailedRecoverable)
//        self.queue.asyncAfter(deadline: .now() + 1) {
            self.stream.disconnectAfterSending()
//        }
    }
    
}

extension VoIPCall {
    internal var voipResource: String {
        return AccountManager.defaultResource + "_voip_\(self.callId)"
    }

    internal var streamStateDescription: String {
        return ConnectionDiagnosticsLogger.stateDescription(for: self.stream)
    }

    internal final func logConnectionDiagnostics(
        event: String,
        details: [String: Any?] = [:],
        rawXML: String? = nil,
        error: Error? = nil
    ) {
        ConnectionDiagnosticsLogger.log(
            event: event,
            stream: .voip,
            jid: self.owner,
            state: self.streamStateDescription,
            details: details,
            rawXML: rawXML,
            error: error
        )
    }

    @discardableResult
    internal final func applyAccountConnectionSettings() -> String {
        guard let account = AccountManager.shared.find(for: owner),
              account.manuallySetHost else {
            return "default"
        }

        self.stream.hostName = account.host
        self.stream.hostPort = UInt16(account.port)
        return "manual"
    }

    internal final func hasQueuedPropose() -> Bool {
        return self.stanzaQueue.contains { item in
            guard let message = item as? XMPPMessage else { return false }
            return self.isMatchingProposeMessage(message)
        }
    }
    
    internal final func enqueue(stanza item: DDXMLElement) {
        self.stanzaQueue.append(item)
        self.processStanzaQueue()
    }

    internal final func isMatchingProposeMessage(_ message: XMPPMessage) -> Bool {
        guard let propose = message.element(forName: "propose", xmlns: VoIPCall.namespace) else {
            return false
        }
        return propose.attributeStringValue(forName: "id") == self.callId
    }

    internal final func clearQueuedPropose() {
        while let index = self.stanzaQueue.index(where: { item in
            guard let message = item as? XMPPMessage else { return false }
            return self.isMatchingProposeMessage(message)
        }) {
            self.stanzaQueue.remove(at: index)
        }
    }
    
    internal final func processStanzaQueue() {
        if !self.stream.isAuthenticated { return }
        self.stanzaQueue
            .filter{ $0.name == "message" }
            .forEach {
                self.stream.send($0)
                self.stanzaQueue.remove($0)
            }
        self.stanzaQueue.removeFirst { (item) in
            if let item = item {
                self.stream.send(item)
                if self.stanzaQueue.isNotEmpty {
                    self.processStanzaQueue()
                }
            }
        }
    }
    
    // MARK: Session confirmation
    
    public final func confirm() {
        let elementId = stream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: VoIPCall.namespace)
        let session = DDXMLElement(name: "session")
        session.addAttribute(withName: "id", stringValue: self.callId)
        query.addChild(session)
        let iq = XMPPIQ(iqType: .get, to: XMPPJID(string: self.jid), elementID: elementId, child: query)
        if self.stream.isAuthenticated {
            self.stream.send(iq)
        } else {
            self.enqueue(stanza: iq)
        }
        self.isConfirmationRequestSend = true
        self.confirmationId = elementId
    }
    
    public func confirmResponse(_ iq: XMPPIQ, error: Bool) {
        if error {
            let error = DDXMLElement(name: "error", xmlns: VoIPCall.namespace)
            let iq = XMPPIQ(
                iqType: .error,
                to: iq.from,
                elementID: iq.elementID,
                child: error
            )
            self.stream.send(iq)
        } else {
            let session = DDXMLElement(name: "session")
            session.addAttribute(withName: "id", stringValue: self.callId)
            let query = DDXMLElement(name: "query", xmlns: VoIPCall.namespace)
            query.addChild(session)
            let iq = XMPPIQ(
                iqType: .result,
                to: iq.from,
                elementID: iq.elementID,
                child: query
            )
            self.stream.send(iq)
//            self.stream.send(XMPPPresence())
        }
    }
    
    internal final func onConfirmResponse(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
              let confirmationId = self.confirmationId,
              confirmationId == elementId else {
            return false
        }
        
        switch iq.iqType {
        case .result:
            if let callId = iq
                .element(forName: "query", xmlns: VoIPCall.namespace)?
                .element(forName: "session")?
                .attributeStringValue(forName: "id"),
               self.callId == callId {
                self.isConfirmed = true
                self.state = .confirmed
//                self.stream.send(XMPPPresence())
            } else {
                DispatchQueue.main.async {
                    self.delegate?.VoIPCallDidExpired(self)
                }
            }
        case .error:
            DispatchQueue.main.async {
                self.delegate?.VoIPCallDidExpired(self)
            }
        default: return false
        }
        
        return true
    }
    
    internal final func onConfirmRequest(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .get,
              let elementId = iq.elementID,
              let query = iq.element(forName: "query", xmlns: VoIPCall.namespace),
              let callId = query.element(forName: "session")?.attributeStringValue(forName: "id"),
              self.callId == callId else {
            return false
        }
        
        if self.isCancelled {
            self.isConfirmed = false
            self.state = .notConfirmed
        } else {
            self.isConfirmed = true
            self.state = .confirmed
        }
        self.confirmationId = elementId
        
        self.confirmResponse(iq, error: self.isCancelled)
        
        return true
    }
    
    // MARK: propose call
    
    public final func proposeCall() {
        let propose = DDXMLElement(name: "propose", xmlns: VoIPCall.namespace)
        propose.addAttribute(withName: "id", stringValue: self.callId)
        let description = DDXMLElement(name: "description", xmlns: "urn:xmpp:jingle:apps:rtp:1")
        description.addAttribute(withName: "media", stringValue: "audio")
        
        let message = XMPPMessage(
            messageType: .chat,
            to: XMPPJID(string: self.jid)?.bareJID,
            elementID: self.callId,
            child: propose
        )
        
        message.addStorageHint(.noStore)
        message.addThread(self.callId)
        message.addOriginId(self.callId)
        
        if let device = AccountManager.shared.find(for: owner)?.devices.deviceElement {
            message.addChild(device)
        }
        
        if self.stream.isAuthenticated {
            self.stream.send(message)
        } else {
            self.enqueue(stanza: message)
        }
        
        self.state = .proposed
        self.isConfirmed = false
        self.isCancelled = false
    }
    
    // MARK: accept call
    
    public final func acceptCall() -> Bool {
        guard !self.outgoing,
              let jid = XMPPJID(string: self.jid),
              jid.isFull else {
            return false
        }
        
        let date = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss:SSS"
        print("ACCEPT CALL AT: \(formatter.string(from: date))")
        
        let accept = DDXMLElement(name: "accept", xmlns: VoIPCall.namespace)
        accept.addAttribute(withName: "id", stringValue: callId)
        let elementId = self.stream.generateUUID
        let message = XMPPMessage(
            messageType: .chat,
            to: jid,
            elementID: elementId,
            child: accept
        )
        
        message.addBody("accept body")
//        message.addStorageHint(.store)
        message.addStorageHint(.noStore)
        message.addOriginId(elementId)
        message.addThread(callId)
        if let device = AccountManager.shared.find(for: owner)?.devices.deviceElement {
            message.addChild(device)
        }
        
        self.start = Date()
        self.state = .accepted
        
        if self.stream.isAuthenticated {
            self.stream.send(message)
        } else {
            self.enqueue(stanza: message)
        }
        return true
    }
    
    internal func onAccept(_ message: XMPPMessage, carbons: Bool = false) -> Bool {
//        NotifyManager.shared.showSimpleNotify(withTitle: "VOIP", subtitle: "", body: "receive accept from \(message.from?.full ?? "")")
        func closeCall() {
            self.isMade = true
            self.shouldSendReject = false
            DispatchQueue.main.async {
                self.delegate?.VoIPCallEndCallAnswerElsewhere(self)
            }
        }
        guard let accept = message.element(forName: "accept", xmlns: VoIPCall.namespace),
              let callId = accept.attributeStringValue(forName: "id"),
              let from = message.from else {
            return false
        }
        if self.callId == callId {
            if carbons {
                if !self.outgoing {
                    closeCall()
                    return true
                }
                return true
            }
            if self.state.rawValue < State.accepted.rawValue {
                if !self.outgoing {
                    closeCall()
                    return true
                }
            }
            self.start = Date()
            self.state = .accepted
            self.jid = from.full
            
            DispatchQueue.main.async {
                self.delegate?.VoIPCallDidUpdateContactJid(self)
            }
            DispatchQueue.main.async {
                self.delegate?.VoIPCallDidAccepted(self)
            }
        } else {
            return false
        }
        
        return true
    }
    
    // MARK: reject call
    
    public final func rejectCall(reason: MessageStorageItem.VoIPCallState) {
        print(#function)
        if !self.shouldSendReject {
            self.disconnect()
            self.delegate?.VoIPCallEndCallRejected(self)
//            self.delegate?.VoIPCallDidEndWith(self, error: nil, byActiveStream: true)
            return
        }
        guard let jid = XMPPJID(string: self.jid) else { return }
        self.state = .ended
        self.stanzaQueue.removeAll()
        
        let elementId = UUID().uuidString
        let call = DDXMLElement(name: "call")
        call.addAttribute(withName: "initiator", stringValue: outgoing ? self.owner : XMPPJID(string: self.jid)?.bare ?? self.jid)
        if self.end == nil {
            self.end = Date()
        }
        let endCall: Date = self.end!
        
        if let start = self.start {
            call.addAttribute(
                withName: "duration",
                doubleValue: Double(Int(endCall.timeIntervalSince1970 - start.timeIntervalSince1970))
            )
        }
        
        
        switch reason {
        case .missed:
            call.addAttribute(withName: "end-reason", stringValue: "missed")
        case .noanswer:
            call.addAttribute(withName: "end-reason", stringValue: "noanswer")
        case .busy:
            call.addAttribute(withName: "end-reason", stringValue: "busy")
        default:
            call.addAttribute(
                withName: "end",
                stringValue: (end ?? Date()).XMPPFormattedDate
            )
        }
        
        if let start = self.start {
            call.addAttribute(
                withName: "start",
                stringValue: start.XMPPFormattedDate
            )
        }
        
        let reject = DDXMLElement(name: "reject", xmlns: VoIPCall.namespace)
        reject.addAttribute(withName: "id", stringValue: self.callId)
        reject.addChild(call)
        
        let message = XMPPMessage(
            messageType: .chat,
            to: jid,
            elementID: elementId,
            child: reject
        )
        
        if let device = AccountManager.shared.find(for: owner)?.devices.deviceElement {
            message.addChild(device)
        }
        
        message.addStorageHint(.store)
        message.addOriginId(elementId)
        message.addThread(self.callId)
        if self.stream.isAuthenticated {
            self.stream.send(message)
            self.disconnect()
        } else {
            self.shouldDisconnectAfterQueuedRejectSend = true
            self.startSignalingIfNeededForQueuedSend()
            let timeout = DispatchWorkItem { [weak self] in
                self?.finishQueuedRejectSend()
            }
            self.queuedRejectTimeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: timeout)
            self.enqueue(stanza: message)
        }
    }

    internal final func finishQueuedRejectSend() {
        queuedRejectTimeoutWorkItem?.cancel()
        queuedRejectTimeoutWorkItem = nil
        shouldDisconnectAfterQueuedRejectSend = false
        stanzaQueue.removeAll()
        let completion = queuedRejectDidFinish
        queuedRejectDidFinish = nil
        disconnect()
        completion?()
    }
    
    public final func onReject(_ message: XMPPMessage, carbons: Bool = false, fromCurrentDevice: Bool = false) -> Bool {
//        NotifyManager.shared.showSimpleNotify(withTitle: "VOIP", subtitle: "", body: "receive reject from \(message.from?.full ?? "")")
        guard let reject = message.element(forName: "reject", xmlns: VoIPCall.namespace),
              let callId = reject.attributeStringValue(forName: "id"),
              self.callId == callId else {
            return false
        }
        let call = reject.element(forName: "call")
        
        self.state = .ended
        self.end = Date()
        self.shouldSendReject = false
        
        if let startString = call?.attributeStringValue(forName: "start"),
           let startDate = Date.parseXMPPFormattedString(startString) {
            self.start = startDate
        }
        if let endString = call?.attributeStringValue(forName: "end"),
           let endDate = Date.parseXMPPFormattedString(endString) {
            self.end = endDate
        }
        DispatchQueue.main.async {
            self.delegate?.VoIPCallDidReceiveRejectMessage(
                self,
                endReason: call?.attributeStringValue(forName: "end-reason"),
                callInitiator: call?.attributeStringValue(forName: "initiator"),
                isCarbon: carbons,
                fromCurrentDevice: fromCurrentDevice
            )
        }
        
        return true
    }
    
    
    // MARK: sessionDescription
    
    public final func sessionDescription(sessionDescription: RTCSessionDescription) {
        let jingle = DDXMLElement(name: "jingle", xmlns: "urn:xmpp:jingle:1")

        switch sessionDescription.type {
            case .offer:
                jingle.addAttribute(withName: "action", stringValue: "session-initiate")
            case .prAnswer:
                jingle.addAttribute(withName: "action", stringValue: "session-update")
            case .answer:
                jingle.addAttribute(withName: "action", stringValue: "session-accept")
            case .rollback:
                break
            @unknown default:
                break
        }
        
        if self.state == .ended { return }
        
        jingle.addAttribute(
            withName: "initiator",
            stringValue: self.outgoing ? self.jid : self.stream.myJID?.full ?? self.owner
        )
        jingle.addAttribute(withName: "sid", stringValue: self.callId)
        
        let content = DDXMLElement(name: "content")
        content.addAttribute(withName: "creator", stringValue: "initiator")
        content.addAttribute(withName: "name", stringValue: "voice")
        
        let description = DDXMLElement(name: "description",
                                       xmlns: "urn:xmpp:jingle:apps:rtp:1")

        description.addAttribute(withName: "media", stringValue: "audio")

        let sdpElement = DDXMLElement(name: "sdp")
        sdpElement.stringValue = sessionDescription.sdp
        description.addChild(sdpElement)
        
        let security = DDXMLElement(name: "security",
                                    xmlns: "urn:xmpp:jingle:security:stub:0")
        
        content.addChild(description)
        content.addChild(security)
        
        jingle.addChild(content)
        stream.send(
            XMPPIQ(
                iqType: .set,
                to: XMPPJID(string: self.jid),
                elementID: stream.generateUUID,
                child: jingle
            )
        )
    }
    
    internal final func onSessionDescription(_ iq: XMPPIQ) -> Bool {
        print(#function, self.callId, iq)
        guard let from = iq.from,
              let jingle = iq.element(forName: "jingle", xmlns: "urn:xmpp:jingle:1"),
              let callId = jingle.attributeStringValue(forName: "sid"),
              self.callId == callId,
              let action = jingle.attributeStringValue(forName: "action"),
              let sdpString = jingle.element(forName: "content")?
                .element(forName: "description",
                         xmlns: "urn:xmpp:jingle:apps:rtp:1")?
                .element(forName: "sdp")?
                .stringValue else {
            return false
        }
        if self.state == .ended {
            return false
        }
        switch action {
        case "session-initiate":
            let sdp = RTCSessionDescription(type: .offer, sdp: sdpString)
            DispatchQueue.main.async {
                self.delegate?.VoIPCallDidReceive(self, sessionDescription: sdp)
            }
        case "session-update":
            let sdp = RTCSessionDescription(type: .prAnswer, sdp: sdpString)
            DispatchQueue.main.async {
                self.delegate?.VoIPCallDidReceive(self, sessionDescription: sdp)
            }
        case "session-accept":
            let sdp = RTCSessionDescription(type: .answer, sdp: sdpString)
            DispatchQueue.main.async {
                self.delegate?.VoIPCallDidReceive(self, sessionDescription: sdp)
            }
        default:
            return false
        }
        self.result(iq)
        return true
    }
    
    // MARK: ICE Transport candidates
    
    public final func candidate(iceCandidate: RTCIceCandidate) {
        let jingle = DDXMLElement(name: "jingle", xmlns: "urn:xmpp:jingle:1")

        jingle.addAttribute(withName: "action", stringValue: "session-info")
        
        jingle.addAttribute(
            withName: "initiator",
            stringValue: self.outgoing ? self.jid : self.stream.myJID?.full ?? self.owner
        )
        
        jingle.addAttribute(withName: "sid", stringValue: self.callId)
        
        let content = DDXMLElement(name: "content")
        content.addAttribute(withName: "creator", stringValue: "initiator")
        content.addAttribute(withName: "name", stringValue: "voice")
        
        let description = DDXMLElement(name: "description",
                                       xmlns: "urn:xmpp:jingle:apps:rtp:1")

        description.addAttribute(withName: "media", stringValue: "audio")

        let transport = DDXMLElement(name: "transport",
                                     xmlns: "urn:xmpp:jingle:transports:ice-udp:1")
        
        let candidateElement = DDXMLElement(name: "candidate")
        candidateElement.stringValue = iceCandidate.sdp
        candidateElement.addAttribute(withName: "sdpMLineIndex",
                               intValue: iceCandidate.sdpMLineIndex)
        if let sdpMid = iceCandidate.sdpMid {
            candidateElement.addAttribute(withName: "sdpMid",
                                   stringValue: sdpMid)
        }
        
        content.addChild(description)
        content.addChild(transport)
        transport.addChild(candidateElement)
        
        jingle.addChild(content)
        
        if self.state == .ended { return }
        
        stream.send(
            XMPPIQ(
                iqType: .set,
                to: XMPPJID(string: self.jid),
                elementID: stream.generateUUID,
                child: jingle
            )
        )
    }
    
    internal final func onCandidate(_ iq: XMPPIQ) -> Bool {
        guard let jingle = iq.element(forName: "jingle", xmlns: "urn:xmpp:jingle:1"),
              let callId = jingle.attributeStringValue(forName: "sid"),
              self.callId == callId,
              let action = jingle.attributeStringValue(forName: "action"),
              action == "session-info",
              let candidate = jingle.element(forName: "content")?
                .element(forName: "transport", xmlns: "urn:xmpp:jingle:transports:ice-udp:1")?
                .element(forName: "candidate"),
              let sdpString = candidate.stringValue else {
                  print("fail to load data from candidate")
            return false
        }
        
        if self.state == .ended {
            return false
        }
        
        let sdpMLineIndex = candidate.attributeInt32Value(forName: "sdpMLineIndex")
        let sdpMid = candidate.attributeStringValue(forName: "sdpMid")
        
        let iceCandidate = RTCIceCandidate(sdp: sdpString, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        DispatchQueue.main.async {
            self.delegate?.VoIPCallDidReceive(self, iceCandidate: iceCandidate)
        }
        self.result(iq)
        return true
    }

    internal final func onJingleError(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .error,
              let jingle = iq.element(forName: "jingle", xmlns: "urn:xmpp:jingle:1"),
              let callId = jingle.attributeStringValue(forName: "sid"),
              self.callId == callId,
              let action = jingle.attributeStringValue(forName: "action") else {
            return false
        }

        let error = iq.element(forName: "error")
        let condition = Self.stanzaErrorCondition(from: error)
        let text = error?
            .element(forName: "text", xmlns: "urn:ietf:params:xml:ns:xmpp-stanzas")?
            .stringValue ?? error?.element(forName: "text")?.stringValue

        DispatchQueue.main.async {
            self.delegate?.VoIPCallDidReceiveJingleError(self, action: action, condition: condition, text: text)
        }
        return true
    }

    internal static func stanzaErrorCondition(from error: DDXMLElement?) -> String? {
        return error?
            .children?
            .compactMap { $0 as? DDXMLElement }
            .first {
                $0.xmlns() == "urn:ietf:params:xml:ns:xmpp-stanzas" && $0.name != "text"
            }?
            .name
    }
    
    internal final func result(_ iq: XMPPIQ) {
        guard let elementId = iq.elementID else {
            return
        }
        self.stream.send(XMPPIQ(iqType: .result, to: iq.from, elementID: elementId, child: nil))
    }
    
    // MARK: Video
    
    enum VideoState {
        case enabled
        case disabled
    }
    
    public final func changeVideoState(to state: VideoState) -> Bool {
        guard let jid = XMPPJID(string: self.jid),
              jid.isFull else {
            return false
        }
        let video = DDXMLElement(name: "video")
        switch state {
        case .enabled:
            video.addAttribute(withName: "state", stringValue: "enable")
        case .disabled:
            video.addAttribute(withName: "state", stringValue: "disable")
        }
        video.addAttribute(withName: "id", stringValue: self.callId)
        let query = DDXMLElement(name: "query", xmlns: VoIPCall.namespace)
        query.addChild(video)
        let iq = XMPPIQ(
            iqType: .set,
            to: XMPPJID(string: self.jid),
            elementID: UUID().uuidString,
            child: query
        )
        if self.stream.isAuthenticated {
            self.stream.send(iq)
        } else {
            self.enqueue(stanza: iq)
        }
        
        DispatchQueue.main.async {
            self.delegate?.VoIPCallDidChangeVideoState(self, to: state, myself: true)
        }
        return true
    }
    
    internal final func onChangeVideoState(_ iq: XMPPIQ) -> Bool {
        guard let video = iq
                .element(forName: "query", xmlns: VoIPCall.namespace)?
                .element(forName: "video"),
              let callId = video.attributeStringValue(forName: "id"),
              self.callId == callId,
              let state = video.attributeStringValue(forName: "state"),
              ["enable", "disable"].contains(state) else {
            return false
        }
        
        switch state {
        case "enable":
            DispatchQueue.main.async {
                self.delegate?.VoIPCallDidChangeVideoState(self, to: .enabled, myself: false)
            }
        case "disable":
            DispatchQueue.main.async {
                self.delegate?.VoIPCallDidChangeVideoState(self, to: .disabled, myself: false)
            }
        default:
            return false
        }
        self.result(iq)
        return true
    }
    
    public final func sendPing() {
        self.lastPingElementID = self.stream.generateUUID
        self.stream.send(XMPPIQ(
            iqType: .get,
            to: self.stream.myJID?.domainJID,
            elementID: self.lastPingElementID,
            child: DDXMLElement(name: "ping", xmlns: "urn:xmpp:ping")
        ))
    }
    
    internal final func onPing(_ iq: XMPPIQ) -> Bool {
        guard let elementId = iq.elementID,
              iq.isResultIQ,
              let from = iq.from,
                iq.element(forName: "ping", xmlns: "urn:xmpp:ping") != nil else {
            return false
        }
        
        self.stream.send(XMPPIQ(iqType: .result, to: from, elementID: elementId, child: nil))
        
        return true
    }
    
}

extension VoIPCall: XMPPStreamDelegate {
    func xmppStreamWillConnect(_ sender: XMPPStream) {
        guard sender === self.stream else { return }
        self.logConnectionDiagnostics(
            event: "tcp_will_connect",
            details: [
                "callId": self.callId,
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
                "callId": self.callId,
                "connectedHost": socket.connectedHost ?? "unknown",
                "connectedPort": socket.connectedPort
            ]
        )
    }

    func xmppStreamDidStartNegotiation(_ sender: XMPPStream) {
        guard sender === self.stream else { return }
        self.logConnectionDiagnostics(
            event: "xmpp_negotiation_started",
            details: ["callId": self.callId]
        )
    }

    func xmppStreamDidSecure(_ sender: XMPPStream) {
        guard sender === self.stream else { return }
        self.logConnectionDiagnostics(
            event: "tls_secure",
            details: ["callId": self.callId]
        )
    }

    func xmppStreamConnectDidTimeout(_ sender: XMPPStream) {
        guard sender === self.stream else { return }
        self.logConnectionDiagnostics(
            event: "tcp_connect_timeout",
            details: ["callId": self.callId]
        )
    }

    func xmppStreamDidConnect(_ sender: XMPPStream) {
        DDLogDebug("VoIPCall: stream didConnect owner=\(owner) callId=\(callId) resource=\(sender.myJID?.resource ?? "none") queued=\(stanzaQueue.count)")
        self.logConnectionDiagnostics(
            event: "xmpp_stream_connected",
            details: [
                "callId": self.callId,
                "resource": sender.myJID?.resource ?? "none",
                "queuedStanzas": self.stanzaQueue.count
            ]
        )

        func invalidate() {
            self.logConnectionDiagnostics(
                event: "authentication_invalidated",
                details: ["callId": self.callId]
            )
            self.stream.disconnect()
            self.stream.myJID = nil
            self.password = nil
            DispatchQueue.main.async {
                self.delegate?.VoIPCallDidEndWith(self, error: VoIPCallError.xmppErrorAuthenticationFailed, byActiveStream: false)
            }
        }
        
        let creditionalsItem = CredentialsManager.shared.getItem(for: self.owner)
        switch creditionalsItem.kind {
        case .password:
            self.logConnectionDiagnostics(
                event: "authentication_branch_selected",
                details: ["credentialKind": "password", "callId": self.callId]
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
                self.logConnectionDiagnostics(
                    event: "authentication_start_failed",
                    details: ["callId": self.callId],
                    error: error
                )
//                reconnect(error)
            }
            break
        case .token:
            self.logConnectionDiagnostics(
                event: "authentication_branch_selected",
                details: ["credentialKind": "token", "callId": self.callId]
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
	                        ownerJID: self.owner,
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
                        self.logConnectionDiagnostics(
                            event: "authentication_start_failed",
                            details: ["callId": self.callId],
                            error: error
                        )
	//                    reconnect(error)
	                }
	            }
            break
        case .secret:
            self.logConnectionDiagnostics(
                event: "authentication_branch_selected",
                details: ["credentialKind": "secret", "callId": self.callId]
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
	                        ownerJID: self.owner,
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
                        self.logConnectionDiagnostics(
                            event: "authentication_start_failed",
                            details: ["callId": self.callId],
                            error: error
                        )
	//                    reconnect(error)
	                }
	            }
        }
    }
    
	    func xmppStreamDidAuthenticate(_ sender: XMPPStream) {
	        guard let jid = sender.myJID?.bare else { return }
	        self.hasAuthenticatedStream = true
	        DDLogDebug("VoIPCall: stream didAuthenticate owner=\(owner) callId=\(callId) resource=\(sender.myJID?.resource ?? "none") queued=\(stanzaQueue.count)")
            self.logConnectionDiagnostics(
                event: "authentication_succeeded",
                details: [
                    "callId": self.callId,
                    "resource": sender.myJID?.resource ?? "none",
                    "queuedStanzas": self.stanzaQueue.count
                ]
            )
	        let credentialsItem = CredentialsManager.shared.getItem(for: jid)
	        authenticationCounterTracker.authenticationDidSucceed(using: credentialsItem)
	        credentialsItem.release(.authSucceeded)
	        if self.shouldConfirmOnAuthenticate {
	            self.confirm()
	        }
//        sender.send(DDXMLElement(name: "inactive", xmlns: "urn:xmpp:csi:0"))
        sender.send(XMPPIQ(iqType: .set,
                           to: nil,
                           elementID: sender.generateUUID,
                           child: DDXMLElement(name: "enable",
                                               xmlns: "urn:xmpp:carbons:2")))
//        sender.send(XMPPPresence())
        
        self.processStanzaQueue()
    }

    func xmppStreamDidReceive(_ sender: XMPPStream, streamFeatures features: DDXMLElement) {
        guard sender === self.stream else { return }
        let hasStartTLS = features.element(forName: "starttls", xmlns: "urn:ietf:params:xml:ns:xmpp-tls") != nil
        let hasBind = features.element(forName: "bind", xmlns: "urn:ietf:params:xml:ns:xmpp-bind") != nil
        self.logConnectionDiagnostics(
            event: "xmpp_stream_features",
            details: [
                "callId": self.callId,
                "startTLS": hasStartTLS,
                "bind": hasBind
            ],
            rawXML: features.xmlString
        )
        if hasStartTLS {
            self.logConnectionDiagnostics(event: "tls_negotiation_required", details: ["callId": self.callId])
        }
        if hasBind {
            self.logConnectionDiagnostics(event: "resource_binding_available", details: ["callId": self.callId])
        }
    }

	    func xmppStream(_ sender: XMPPStream, didNotAuthenticate error: DDXMLElement) {
	        authenticationCounterTracker.authenticationDidFail()
	        let credentialsItem = CredentialsManager.shared.getItem(for: owner)
	        DDLogDebug("VoIPCall: stream didNotAuthenticate owner=\(owner) callId=\(callId) resource=\(sender.myJID?.resource ?? "none") queued=\(stanzaQueue.count)")
            self.logConnectionDiagnostics(
                event: "authentication_failed",
                details: ["callId": self.callId],
                rawXML: error.xmlString
            )
	        if let failure = XMPPAuthenticationFailure(element: error) {
	            let resolution = XMPPAuthenticationFailureResolution.resolve(
	                failure: failure,
	                credentialKind: credentialsItem.kind,
	                source: .secondaryStream
	            )
	            if resolution.shouldLogRawFailure {
	                DDLogDebug("XMPP VoIP auth failure for \(owner): \(failure.rawXML)")
	            }
	        } else {
	            DDLogDebug("XMPP VoIP auth failure for \(owner): \(error.xmlString)")
	        }
	        credentialsItem.release(.authFailedRecoverable)
	        self.stream.disconnect()
	        DispatchQueue.main.async {
	            self.delegate?.VoIPCallDidEndWith(self, error: VoIPCallError.xmppErrorAuthenticationFailed, byActiveStream: false)
        }
    }
    
    func xmppStream(_ sender: XMPPStream, willSend iq: XMPPIQ) -> XMPPIQ? {
        if self.state == .ended {
            return nil
        }
        return iq
    }
    
    func xmppStream(_ sender: XMPPStream, didSend iq: XMPPIQ) {
//        print("VoIP:IQ:SEND: \(iq.prettyXMLString ?? "")")
        self.logConnectionDiagnostics(
            event: "stanza_send_iq",
            details: [
                "callId": self.callId,
                "id": iq.elementID ?? "none",
                "type": iq.type ?? "none",
                "to": iq.to?.bare ?? "none",
                "from": iq.from?.bare ?? "none"
            ],
            rawXML: iq.xmlString
        )
        DDLogInfo("send: \(iq.prettyXMLString ?? "")")
    }
    
    func xmppStream(_ sender: XMPPStream, didSend message: XMPPMessage) {
//        print("VoIP:Message:SEND: \(message.prettyXMLString ?? "")")
        self.logConnectionDiagnostics(
            event: "stanza_send_message",
            details: [
                "callId": self.callId,
                "id": message.elementID ?? "none",
                "type": message.type ?? "chat",
                "to": message.to?.bare ?? "none",
                "from": message.from?.bare ?? "none"
            ],
            rawXML: message.xmlString
        )
        DDLogInfo("send: \(message.prettyXMLString ?? "")")
        if isMatchingProposeMessage(message) {
            DDLogDebug("VoIPCall: sent propose owner=\(owner) callId=\(callId) resource=\(sender.myJID?.resource ?? "none")")
            DispatchQueue.main.async {
                self.delegate?.VoIPCallDidSendPropose(self)
            }
        }
        if shouldDisconnectAfterQueuedRejectSend,
           let reject = message.element(forName: "reject", xmlns: VoIPCall.namespace),
           reject.attributeStringValue(forName: "id") == self.callId {
            DispatchQueue.main.async {
                self.finishQueuedRejectSend()
            }
        }
    }

    func xmppStream(_ sender: XMPPStream, didSend presence: XMPPPresence) {
        self.logConnectionDiagnostics(
            event: "stanza_send_presence",
            details: [
                "callId": self.callId,
                "id": presence.elementID ?? "none",
                "type": presence.type ?? "available",
                "to": presence.to?.bare ?? "none",
                "from": presence.from?.bare ?? "none"
            ],
            rawXML: presence.xmlString
        )
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive iq: XMPPIQ) -> Bool {
        print("VoIP:IQ:RECV: \(iq.prettyXMLString ?? "")")
        DDLogInfo(iq.prettyXMLString ?? "")
        self.logConnectionDiagnostics(
            event: "stanza_receive_iq",
            details: [
                "callId": self.callId,
                "id": iq.elementID ?? "none",
                "type": iq.type ?? "none",
                "to": iq.to?.bare ?? "none",
                "from": iq.from?.bare ?? "none"
            ],
            rawXML: iq.xmlString
        )
        print("state", self.state)
        if self.state == .ended {
            return true
        }
        switch Self.incomingIQRoute(for: iq) {
        case .sessionDescription:
            if onSessionDescription(iq) { return true }
        case .candidate:
            if onCandidate(iq) { return true }
        case .videoState:
            if onChangeVideoState(iq) { return true }
        case .confirmRequest:
            if onConfirmRequest(iq) { return true }
        case .jingleError:
            if onJingleError(iq) { return true }
            return true
        case .acknowledgement:
            if onConfirmResponse(iq) { return true }
            if onPing(iq) { return true }
            return true
        case .unhandled:
            break
        }
        print("VOIP FAIL STANZA \(iq.prettyXMLString)")
        return false
    }
    
    func xmppStream(_ sender: XMPPStream, willReceive iq: XMPPIQ) -> XMPPIQ? {
        return iq
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive message: XMPPMessage) {
        print("VoIP:Message:RECV: \(message.prettyXMLString ?? "")")
        DDLogInfo(message.prettyXMLString ?? "")
        self.logConnectionDiagnostics(
            event: "stanza_receive_message",
            details: [
                "callId": self.callId,
                "id": message.elementID ?? "none",
                "type": message.type ?? "chat",
                "to": message.to?.bare ?? "none",
                "from": message.from?.bare ?? "none"
            ],
            rawXML: message.xmlString
        )
        var bareMessage: XMPPMessage
        var isCarbon: Bool = false
        if isCarbonCopy(message) {
            isCarbon = true
            bareMessage = getCarbonCopyMessageContainer(message)!// ?? message
        } else if isCarbonForwarded(message) {
            bareMessage = getCarbonForwardedMessageContainer(message)!// ?? message
        } else if isForwardedMessage(message) {
            bareMessage = getForwardedMessage(message)!// ?? message
        } else {
            bareMessage = message
        }
        let fromDeviceId = bareMessage.element(forName: "device")?.attributeStringValue(forName: "id")
        let currentDeviceId = AccountManager.shared.find(for: owner)?.devices.deviceId
        let fromCurrentDevice = fromDeviceId != nil && fromDeviceId == currentDeviceId
        switch true {
            case onAccept(bareMessage, carbons: isCarbon): return
            case onReject(bareMessage, carbons: isCarbon, fromCurrentDevice: fromCurrentDevice): return
            default: return
        }
    }

    func xmppStream(_ sender: XMPPStream, didReceive presence: XMPPPresence) {
        self.logConnectionDiagnostics(
            event: "stanza_receive_presence",
            details: [
                "callId": self.callId,
                "id": presence.elementID ?? "none",
                "type": presence.type ?? "available",
                "to": presence.to?.bare ?? "none",
                "from": presence.from?.bare ?? "none"
            ],
            rawXML: presence.xmlString
        )
    }
    
    func xmppStream(_ sender: XMPPStream, didFailToSend iq: XMPPIQ, error: Error) {
//        print("VoIP:MESSAGE:FAIL: \(error.localizedDescription)")
        self.logConnectionDiagnostics(
            event: "stanza_send_failed_iq",
            details: [
                "callId": self.callId,
                "id": iq.elementID ?? "none",
                "type": iq.type ?? "none"
            ],
            rawXML: iq.xmlString,
            error: error
        )
        self.enqueue(stanza: iq)
        self.doReconnect()
    }
    
    func xmppStream(_ sender: XMPPStream, didFailToSend message: XMPPMessage, error: Error) {
//        print("VoIP:MESSAGE:FAIL: \(error.localizedDescription)")
        self.logConnectionDiagnostics(
            event: "stanza_send_failed_message",
            details: [
                "callId": self.callId,
                "id": message.elementID ?? "none",
                "type": message.type ?? "chat"
            ],
            rawXML: message.xmlString,
            error: error
        )
        
        self.enqueue(stanza: message)
        self.doReconnect()
    }

    func xmppStream(_ sender: XMPPStream, didFailToSend presence: XMPPPresence, error: Error) {
        self.logConnectionDiagnostics(
            event: "stanza_send_failed_presence",
            details: [
                "callId": self.callId,
                "id": presence.elementID ?? "none",
                "type": presence.type ?? "available"
            ],
            rawXML: presence.xmlString,
            error: error
        )
        self.enqueue(stanza: presence)
        self.doReconnect()
    }
    
	    func xmppStreamDidDisconnect(_ sender: XMPPStream, withError error: Error?) {
	        DDLogDebug("VoIPCall: stream didDisconnect owner=\(owner) callId=\(callId) resource=\(sender.myJID?.resource ?? "none") authenticatedOnce=\(hasAuthenticatedStream) queued=\(stanzaQueue.count) hasQueuedPropose=\(hasQueuedPropose()) state=\(state) error=\(error?.localizedDescription ?? "none")")
            self.logConnectionDiagnostics(
                event: "tcp_disconnected",
                details: [
                    "callId": self.callId,
                    "resource": sender.myJID?.resource ?? "none",
                    "authenticatedOnce": self.hasAuthenticatedStream,
                    "queuedStanzas": self.stanzaQueue.count,
                    "hasQueuedPropose": self.hasQueuedPropose(),
                    "callState": self.state
                ],
                error: error
            )
	        guard let jid = sender.myJID?.bare else { return }
	        CredentialsManager.shared.getItem(for: jid).release(.authFailedRecoverable)
	        if !self.hasAuthenticatedStream && self.hasQueuedPropose() {
	            DDLogDebug("VoIPCall: pre-auth disconnect while outgoing propose remains queued owner=\(owner) callId=\(callId)")
	        }
	        if self.state == .ended {
	            DispatchQueue.main.async {
	                self.delegate?.VoIPCallDidEndWith(self, error: nil, byActiveStream: false)
	            }
	        }
	    }
    
	    func xmppStreamDidSendClosingStreamStanza(_ sender: XMPPStream) {
	//        print(#function, "CLOSE")
            self.logConnectionDiagnostics(
                event: "disconnect_closing_stream_sent",
                details: ["callId": self.callId]
            )
	        guard let jid = sender.myJID?.bare else { return }
	        CredentialsManager.shared.getItem(for: jid).release(.authFailedRecoverable)
	    }

    func xmppStream(_ sender: XMPPStream, didReceiveError error: DDXMLElement) {
        self.logConnectionDiagnostics(
            event: "xmpp_stream_error",
            details: ["callId": self.callId],
            rawXML: error.xmlString
        )
    }

    func xmppStream(_ sender: XMPPStream, willSecureWithSettings settings: NSMutableDictionary) {
        guard sender === self.stream else { return }
        self.logConnectionDiagnostics(
            event: "tls_will_secure",
            details: [
                "callId": self.callId,
                "manualTrustEvaluation": settings[GCDAsyncSocketManuallyEvaluateTrust] as? Bool ?? false
            ]
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
            details: [
                "callId": self.callId,
                "shouldTrust": shouldTrust
            ]
        )
        completionHandler(shouldTrust)
    }
}
