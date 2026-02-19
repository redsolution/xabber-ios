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
    func VoIPCallDidReceiveRejectMessage(_ call: VoIPCall)
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
    
    public var owner: String
    public var jid: String
    public var callId: String
    public var callUUID: UUID
    internal var outgoing: Bool
    internal var password: String?
    
    internal var stream: XMPPStream
    
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
    
    var backgroundUpdateTask: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 0)
    
    internal var state: State {
        willSet {
            print("change voip state to \(newValue)")
            if self.state == .ended && newValue == .disconnected {
                self.state = .ended
            }
            if newValue == .connected {
                self.isMade = true
            }
            DispatchQueue.main.async {
                self.delegate?.VoIPCallDidChangeState(self, to: newValue)
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
            attributes: [.concurrent],
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
        
        self.connect()
        if !outgoing {
            self.confirm()
        }
        
    }
    
    private final func endBackgroundTask() {
        UIApplication.shared.endBackgroundTask(self.backgroundUpdateTask)
        self.backgroundUpdateTask = UIBackgroundTaskIdentifier.invalid
    }
    
    private final func connect() {
        self.stream.myJID = XMPPJID(
            string: self.owner,
            resource: AccountManager.defaultResource + "_voip_\(self.callId)"
        )
        self.queue.async {
            do {
                try self.stream.connect(withTimeout: 5.0)
            } catch {
                DDLogDebug("VoIPCall: \(#function). \(error.localizedDescription)")
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
    
    public final func disconnect() {
        guard let jid = stream.myJID?.bare else { return }
        CredentialsManager.shared.getItem(for: jid).release(error: false)
//        self.queue.asyncAfter(deadline: .now() + 1) {
            self.stream.disconnectAfterSending()
//        }
        VoIPManager.shared.reset()
    }
    
}

extension VoIPCall {
    
    internal final func enqueue(stanza item: DDXMLElement) {
        self.stanzaQueue.append(item)
        self.processStanzaQueue()
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
        
        self.stream.send(message)
        if !self.stream.isAuthenticated {
            self.enqueue(stanza: message)
        }
        return true
    }
    
    internal func onAccept(_ message: XMPPMessage, carbons: Bool = false) -> Bool {
        NotifyManager.shared.showSimpleNotify(withTitle: "VOIP", subtitle: "", body: "receive accept from \(message.from?.full ?? "")")
        func closeCall() {
            self.isMade = true
            self.shouldSendReject = false
            VoIPManager.shared.VoIPCallDidEndWith(self, error: nil, byActiveStream: false)
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
            if outgoing && carbons  && self.state.rawValue < State.accepted.rawValue {
                DispatchQueue.main.async {
                    print("FAIL")
                    self.delegate?.VoIPCallDidEndWith(self, error: VoIPCallError.callAcceptedButNotConfirmed, byActiveStream: true)
                }
                return true
            }
            DispatchQueue.main.async {
                self.delegate?.VoIPCallDidAccepted(self)
            }
        } else {
            closeCall()
        }
        
        return true
    }
    
    // MARK: reject call
    
    public final func rejectCall(reason: MessageStorageItem.VoIPCallState) {
        print(#function)
        if !self.shouldSendReject {
            self.disconnect()
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
            self.enqueue(stanza: message)
        }
    }
    
    public final func onReject(_ message: XMPPMessage) -> Bool {
        NotifyManager.shared.showSimpleNotify(withTitle: "VOIP", subtitle: "", body: "receive reject from \(message.from?.full ?? "")")
        func closeCall() {
            self.isMade = true
            self.shouldSendReject = false
            VoIPManager.shared.VoIPCallDidEndWith(self, error: nil, byActiveStream: false)
        }
        guard let reject = message.element(forName: "reject", xmlns: VoIPCall.namespace),
              let callId = reject.attributeStringValue(forName: "id"),
              self.callId == callId else {
            return false
        }
        
        self.state = .ended
        self.delegate?.VoIPCallDidChangeState(self, to: .ended)
        self.end = Date()
        self.shouldSendReject = false
        
        if let startString = reject.element(forName: "call")?.attributeStringValue(forName: "start"),
           let startDate = Date.parseXMPPFormattedString(startString) {
            self.start = startDate
        }
        if let endString = reject.element(forName: "call")?.attributeStringValue(forName: "end"),
           let endDate = Date.parseXMPPFormattedString(endString) {
            self.end = endDate
        }
        closeCall()
        
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
            if let jid = XMPPJID(string: self.jid),
               !jid.isFull {
                self.start = Date()
                self.state = .accepted
                self.jid = from.full
                DispatchQueue.main.async {
                    self.delegate?.VoIPCallDidUpdateContactJid(self)
                    self.delegate?.VoIPCallDidAccepted(self)
                }
            }
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
    func xmppStreamDidConnect(_ sender: XMPPStream) {
        func invalidate() {
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
            do {
                if let password = creditionalsItem.creditionalString {
                    stream.shouldRequestXToken = false
                    stream.shouldRegisterDevice = false
                    try stream.authenticate(withPassword: password)
                } else {
                    invalidate()
                }
            } catch {
//                reconnect(error)
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
//                    reconnect(error)
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
                        let realm = try WRealm.safe()
                        let deviceUUID = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: stream.myJID?.bare ?? "")?.deviceUuid
                        if stream.supportsOCRAAuthentication {
                            try stream.authenticate(withOCRASecret: secret, validationKey: item.validationKey ?? "", deviceId: deviceUUID ?? "", counter: counter)
                        } else {
                            try stream.authenticate(withHOTPSecret: secret, counter: counter)
                        }
                    } else {
                        item.decrementCounter()
                        invalidate()
                    }
                } catch {
//                    print(error.localizedDescription)
                    item.decrementCounter()
//                    reconnect(error)
                }
            }
        }
    }
    
    func xmppStreamDidAuthenticate(_ sender: XMPPStream) {
        guard let jid = sender.myJID?.bare else { return }
        CredentialsManager.shared.getItem(for: jid).release(error: false)
        self.confirm()
//        sender.send(DDXMLElement(name: "inactive", xmlns: "urn:xmpp:csi:0"))
        sender.send(XMPPIQ(iqType: .set,
                           to: nil,
                           elementID: sender.generateUUID,
                           child: DDXMLElement(name: "enable",
                                               xmlns: "urn:xmpp:carbons:2")))
//        sender.send(XMPPPresence())
        
        self.processStanzaQueue()
    }
    
    func xmppStream(_ sender: XMPPStream, willSend iq: XMPPIQ) -> XMPPIQ? {
        if self.state == .ended {
            return nil
        }
        return iq
    }
    
    func xmppStream(_ sender: XMPPStream, didSend iq: XMPPIQ) {
//        print("VoIP:IQ:SEND: \(iq.prettyXMLString ?? "")")
        DDLogInfo("send: \(iq.prettyXMLString ?? "")")
    }
    
    func xmppStream(_ sender: XMPPStream, didSend message: XMPPMessage) {
//        print("VoIP:Message:SEND: \(message.prettyXMLString ?? "")")
        DDLogInfo("send: \(message.prettyXMLString ?? "")")
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive iq: XMPPIQ) -> Bool {
        print("VoIP:IQ:RECV: \(iq.prettyXMLString ?? "")")
        DDLogInfo(iq.prettyXMLString ?? "")
        print("state", self.state)
        if self.state == .ended {
            return true
        }
        switch true {
        case onConfirmRequest(iq): return true
        case onConfirmResponse(iq): return true
        case onSessionDescription(iq): return true
        case onCandidate(iq): return true
        case onChangeVideoState(iq): return true
        case onPing(iq): return true
        default: return false
        }
    }
    
    func xmppStream(_ sender: XMPPStream, willReceive iq: XMPPIQ) -> XMPPIQ? {
        if iq.iqType == .error {
            return nil
        }
        return iq
    }
    
    func xmppStream(_ sender: XMPPStream, didReceive message: XMPPMessage) {
        print("VoIP:Message:RECV: \(message.prettyXMLString ?? "")")
        DDLogInfo(message.prettyXMLString ?? "")
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
        switch true {
        case onAccept(bareMessage, carbons: isCarbon): return
        case onReject(bareMessage): return
        default: return
        }
    }
    
    func xmppStream(_ sender: XMPPStream, didFailToSend iq: XMPPIQ, error: Error) {
//        print("VoIP:MESSAGE:FAIL: \(error.localizedDescription)")
        self.enqueue(stanza: iq)
        self.doReconnect()
    }
    
    func xmppStream(_ sender: XMPPStream, didFailToSend message: XMPPMessage, error: Error) {
//        print("VoIP:MESSAGE:FAIL: \(error.localizedDescription)")
        
        self.enqueue(stanza: message)
        self.doReconnect()
    }
    
    func xmppStreamDidDisconnect(_ sender: XMPPStream, withError error: Error?) {
        guard let jid = sender.myJID?.bare else { return }
        CredentialsManager.shared.getItem(for: jid).release(error: false)
        if self.state == .ended {
            DispatchQueue.main.async {
                self.delegate?.VoIPCallDidEndWith(self, error: nil, byActiveStream: false)
            }
        }
    }
    
    func xmppStreamDidSendClosingStreamStanza(_ sender: XMPPStream) {
//        print(#function, "CLOSE")
        guard let jid = sender.myJID?.bare else { return }
        CredentialsManager.shared.getItem(for: jid).release(error: false)
    }
}
