//
//  XMPPRegisterManager.swift
//  clandestino
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

protocol XMPPRegistrationManagerDelegate {
    func xmppRegistrationManagerReady()
    func xmppRegistrationManagerCheckUsername(available: Bool)
    func xmppRegistrationManagerSuccess()
    func xmppRegistrationManagerFail(error: String)
}

class XMPPRegistrationManager: NSObject {
    
    open class var shared: XMPPRegistrationManager {
        struct XMPPRegistrationManagerSingleton {
            static let instance = XMPPRegistrationManager()
        }
        return XMPPRegistrationManagerSingleton.instance
    }
    
    enum State {
        case none
        case started
        case checking
        case registration
        case closed
    }
    
    public var delegate: XMPPRegistrationManagerDelegate? = nil
    
    var stream: XMPPStream? = nil
    var reconnect: XMPPReconnect? = nil
    
    var host: String? = nil
    
    var queue: DispatchQueue
    
    var state: State = .none
    
    var pingTimer: Timer? = nil
    
    override init()  {
        self.queue = DispatchQueue(
            label: "com.redsolution.xabber.registration",
            qos: .utility,
            attributes: [],
            autoreleaseFrequency: .workItem,
            target: nil
        )
        super.init()
    }
    
    static var isDefaultHostLocked: Bool {
        get {
            return CommonConfigManager.shared.get().locked_host.isNotEmpty
        }
    }
    
    static func getDefaultHost() -> String {
        if CommonConfigManager.shared.get().locked_host.isNotEmpty {
            return CommonConfigManager.shared.get().locked_host
        } else {
            guard let host = CommonConfigManager.shared.get().allowed_hosts.first else {
                fatalError("allowed_hosts in common_config.plist is empty. Please check client configuration")
            }
            return host
        }
    }
    
    static func allowedHosts() -> [String] {
        return CommonConfigManager.shared.get().allowed_hosts
    }
    
    public final func start(host: String) throws  {
        self.host = host
        self.stream?.disconnect()
        self.stream?.abortConnecting()
        self.stream = XMPPStream()
//        self.stream?.hostName = host
        self.stream?.addDelegate(self, delegateQueue: self.queue)
        self.stream?.myJID = XMPPJID(string: host)
        self.stream?.startTLSPolicy = XMPPStreamStartTLSPolicy.preferred
        self.stream?.keepAliveInterval = 5
        self.stream?.registrationKey = CommonConfigManager.shared.config.server_registration_url
        self.reconnect = XMPPReconnect(dispatchQueue: self.queue)
        self.reconnect?.activate(self.stream!)
        self.reconnect?.addDelegate(self, delegateQueue: self.queue)
        self.reconnect?.autoReconnect = true
        self.reconnect?.reconnectDelay = 2
        self.reconnect?.reconnectTimerInterval = 2
        self.logConnectionDiagnostics(
            event: "stream_configured",
            details: [
                "host": host,
                "tlsPolicy": self.stream?.startTLSPolicy.rawValue ?? 0,
                "keepAlive": self.stream?.keepAliveInterval ?? 0,
                "reconnectAuto": self.reconnect?.autoReconnect ?? false,
                "reconnectDelay": self.reconnect?.reconnectDelay ?? 0
            ]
        )
        self.logConnectionDiagnostics(
            event: "connect_start",
            details: [
                "host": self.stream?.hostName ?? "jid-domain",
                "port": self.stream?.hostPort ?? 0,
                "timeout": 15
            ]
        )
        do {
            try self.stream?.connect(withTimeout: 15)
        } catch {
            self.logConnectionDiagnostics(event: "connect_throw", error: error)
            throw error
        }
//        self.pingTimer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(self.sendPing), userInfo: nil, repeats: true)
//        RunLoop.main.add(self.pingTimer!, forMode: .default)
        
    }
    
    public final func close() {
        self.logConnectionDiagnostics(event: "disconnect_requested")
        self.pingTimer?.fire()
        self.pingTimer?.invalidate()
        self.pingTimer = nil
        self.state = .none
        self.stream?.disconnectAfterSending()
        self.stream?.removeDelegate(self)
        self.stream = nil
        self.logConnectionDiagnostics(event: "disconnect_completed_local")
    }
    
    public final func check(username: String) throws {
        try self.stream?.checkUsernameAwailable(username)
        self.state = .checking
    }
    
    public final func register(username: String, password: String) throws {
        try self.stream?.registerUser(username, password: password)
        self.state = .registration
    }

    final func logConnectionDiagnostics(
        event: String,
        details: [String: Any?] = [:],
        rawXML: String? = nil,
        error: Error? = nil
    ) {
        ConnectionDiagnosticsLogger.log(
            event: event,
            stream: .register,
            jid: self.host ?? self.stream?.myJID?.bare,
            state: self.stream.map { ConnectionDiagnosticsLogger.stateDescription(for: $0) },
            details: details,
            rawXML: rawXML,
            error: error
        )
    }
}

extension XMPPRegistrationManager: XMPPStreamDelegate {
    
    func xmppStreamWillConnect(_ sender: XMPPStream) {
        self.logConnectionDiagnostics(
            event: "tcp_will_connect",
            details: [
                "host": sender.hostName ?? "jid-domain",
                "port": sender.hostPort
            ]
        )
        if self.state == .closed {
            self.logConnectionDiagnostics(event: "connect_abort_told", details: ["reason": "registrationClosed"])
            sender.abortConnecting()
        }
    }

    func xmppStream(_ sender: XMPPStream, socketDidConnect socket: GCDAsyncSocket) {
        self.logConnectionDiagnostics(
            event: "tcp_socket_connected",
            details: [
                "connectedHost": socket.connectedHost ?? "unknown",
                "connectedPort": socket.connectedPort
            ]
        )
    }

    func xmppStreamDidStartNegotiation(_ sender: XMPPStream) {
        self.logConnectionDiagnostics(event: "xmpp_negotiation_started")
    }

    func xmppStreamDidSecure(_ sender: XMPPStream) {
        self.logConnectionDiagnostics(event: "tls_secure")
    }

    func xmppStreamConnectDidTimeout(_ sender: XMPPStream) {
        self.logConnectionDiagnostics(event: "tcp_connect_timeout")
    }
    
    func xmppStreamDidConnect(_ sender: XMPPStream) {
        self.logConnectionDiagnostics(event: "xmpp_stream_connected")
        if sender.supportsInBandRegistration {
            self.logConnectionDiagnostics(event: "registration_ready")
            self.delegate?.xmppRegistrationManagerReady()
            self.state = .started
        }
    }
    
    func xmppStream(_ sender: XMPPStream, didReceiveError error: DDXMLElement) {
//        print("registration error: \(error.prettyXMLString!)")
        self.logConnectionDiagnostics(
            event: "xmpp_stream_error",
            rawXML: error.xmlString
        )
        do {
            self.logConnectionDiagnostics(
                event: "connect_start",
                details: [
                    "reason": "streamErrorReconnect",
                    "timeout": 15
                ]
            )
            try sender.connect(withTimeout: 15)
        } catch {
            self.logConnectionDiagnostics(event: "connect_throw", error: error)
//            print("asd")
        }
    }
    
    func xmppStreamHandleRegistration(_ sender: XMPPStream, with iq: XMPPIQ) {
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
        if let query = iq.element(forName: "query", xmlns: "jabber:iq:register") {
            switch state {
            case .none:
                break
            case .started:
                break
            case .checking:
                if query.element(forName: "username") != nil {
                    self.delegate?.xmppRegistrationManagerCheckUsername(available: query.element(forName: "registered") == nil)
                } else {
                    self.delegate?.xmppRegistrationManagerCheckUsername(available: true)
                }
            case .registration:
                if let error = iq.element(forName: "error") {
                    if let text = error.element(forName: "text")?.stringValue {
                        self.delegate?.xmppRegistrationManagerFail(error: text)
                    } else {
                        self.delegate?.xmppRegistrationManagerFail(error: "Internal error. Try again later.")
                    }
                } else {
                    if query.element(forName: "registered") == nil {
                        self.delegate?.xmppRegistrationManagerSuccess()
                        self.close()
                    } else {
                        self.delegate?.xmppRegistrationManagerFail(error: "Account already exist")
                    }
                }
            case .closed:
                break
            }
        } else {
            if state == .registration {
                self.delegate?.xmppRegistrationManagerSuccess()
                self.close()
            }
        }
        
    }
    
    func xmppStreamDidDisconnect(_ sender: XMPPStream, withError error: Error?) {
        if state == .closed { return }
        self.logConnectionDiagnostics(
            event: "tcp_disconnected",
            error: error
        )
        do {
            self.logConnectionDiagnostics(
                event: "connect_start",
                details: [
                    "reason": "disconnectReconnect",
                    "timeout": 15
                ]
            )
            try sender.connect(withTimeout: 15)
        } catch {
            self.logConnectionDiagnostics(event: "connect_throw", error: error)
        }
    }

    func xmppStream(_ sender: XMPPStream, didSend iq: XMPPIQ) {
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

    func xmppStream(_ sender: XMPPStream, willSecureWithSettings settings: NSMutableDictionary) {
        self.logConnectionDiagnostics(
            event: "tls_will_secure",
            details: ["manualTrustEvaluation": settings[GCDAsyncSocketManuallyEvaluateTrust] as? Bool ?? false]
        )
    }

    func xmppStream(_ sender: XMPPStream, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        let shouldTrust = true
        self.logConnectionDiagnostics(
            event: "tls_trust_evaluated",
            details: ["shouldTrust": shouldTrust]
        )
        completionHandler(shouldTrust)
    }
    
    @objc
    private func sendPing() {
        self.stream?.sendPreRegisterPing()
    }
    
}
