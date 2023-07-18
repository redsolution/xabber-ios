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
        self.stream?.hostName = host
        self.stream?.addDelegate(self, delegateQueue: self.queue)
        self.stream?.myJID = XMPPJID(string: host)
        self.stream?.startTLSPolicy = XMPPStreamStartTLSPolicy.preferred
        self.stream?.keepAliveInterval = 5
        self.stream?.registrationKey = "ae69770abdqzzzkg"
        self.reconnect = XMPPReconnect(dispatchQueue: self.queue)
        self.reconnect?.activate(self.stream!)
        self.reconnect?.addDelegate(self, delegateQueue: self.queue)
        self.reconnect?.autoReconnect = true
        self.reconnect?.reconnectDelay = 2
        self.reconnect?.reconnectTimerInterval = 2
        try self.stream?.connect(withTimeout: 15)
//        self.pingTimer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(self.sendPing), userInfo: nil, repeats: true)
//        RunLoop.main.add(self.pingTimer!, forMode: .default)
        
    }
    
    public final func close() {
        self.pingTimer?.fire()
        self.pingTimer?.invalidate()
        self.pingTimer = nil
        self.state = .none
        self.stream?.disconnectAfterSending()
        self.stream?.removeDelegate(self)
        self.stream = nil
    }
    
    public final func check(username: String) throws {
        try self.stream?.checkUsernameAwailable(username)
        self.state = .checking
    }
    
    public final func register(username: String, password: String) throws {
        try self.stream?.registerUser(username, password: password)
        self.state = .registration
    }
}

extension XMPPRegistrationManager: XMPPStreamDelegate {
    
    func xmppStreamWillConnect(_ sender: XMPPStream) {
        if self.state == .closed {
            sender.abortConnecting()
        }
    }
    
    func xmppStreamDidConnect(_ sender: XMPPStream) {
        if sender.supportsInBandRegistration {
            self.delegate?.xmppRegistrationManagerReady()
            self.state = .started
        }
    }
    
    func xmppStream(_ sender: XMPPStream, didReceiveError error: DDXMLElement) {
        print("registration error: \(error.prettyXMLString!)")
        do {
            try sender.connect(withTimeout: 15)
        } catch {
            print("asd")
        }
    }
    
    func xmppStreamHandleRegistration(_ sender: XMPPStream, with iq: XMPPIQ) {
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
        try? sender.connect(withTimeout: 5)
    }
    
    @objc
    private func sendPing() {
        self.stream?.sendPreRegisterPing()
    }
    
}
