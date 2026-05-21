//
//  XMPPActionManager.swift
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
import SwiftUI
import CocoaAsyncSocket

protocol XMPPChangePasswordManagerDelegate {
    func didReceiveResponse(title: String, description: String)
}

class XMPPChangePasswordManager: NSObject {
    open class var shared: XMPPChangePasswordManager {
        struct XMPPChangePasswordManagerSingleton {
            static let instance = XMPPChangePasswordManager()
        }
        return XMPPChangePasswordManagerSingleton.instance
    }
    
    var jid: String? = nil
    var password: String? = nil
    var newPassword: String? = nil
    var stream: XMPPStream = XMPPStream()
    var queue: DispatchQueue
    var backgroundUpdateTask: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 0)
    var delegate: XMPPChangePasswordManagerDelegate?
    
    override init() {
        queue = DispatchQueue(
            label: "com.xabber.action.manager.\(UUID().uuidString)",
            qos: .background,
            attributes: [],
            autoreleaseFrequency: .workItem,
            target: nil
        )
        super.init()
    }

    func endBackgroundUpdateTask() {
        UIApplication.shared.endBackgroundTask(self.backgroundUpdateTask)
       self.backgroundUpdateTask = UIBackgroundTaskIdentifier.invalid
    }
    
    public final func changePassword(jid: String, oldPassword: String, newPassword: String, delegate: XMPPChangePasswordManagerDelegate?) {
        self.jid = jid
        self.password = oldPassword
        self.newPassword = newPassword
        self.delegate = delegate
        
        queue.async {
            self.backgroundUpdateTask = UIApplication.shared.beginBackgroundTask(withName: UUID().uuidString, expirationHandler: {
                self.endBackgroundUpdateTask()
            })
            self.stream.myJID = XMPPJID(string: jid, resource: AccountManager.defaultResource + "fast_send")
            self.stream.startTLSPolicy = XMPPStreamStartTLSPolicy.preferred
            self.stream.keepAliveInterval = 60
            self.stream.addDelegate(self, delegateQueue: self.queue)
            self.logConnectionDiagnostics(
                event: "stream_configured",
                details: [
                    "resource": self.stream.myJID?.resource ?? "none",
                    "tlsPolicy": self.stream.startTLSPolicy.rawValue,
                    "keepAlive": self.stream.keepAliveInterval,
                    "oldPasswordPresent": oldPassword.isEmpty == false,
                    "newPasswordPresent": newPassword.isEmpty == false
                ]
            )
            do {
                self.logConnectionDiagnostics(
                    event: "connect_start",
                    details: [
                        "resource": self.stream.myJID?.resource ?? "none",
                        "host": self.stream.hostName ?? "jid-domain",
                        "port": self.stream.hostPort,
                        "timeout": 3
                    ]
                )
                try self.stream.connect(withTimeout: 3)
            } catch {
                self.logConnectionDiagnostics(event: "connect_throw", error: error)
                DDLogDebug("XMPPChangePasswordManager: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
    public func makeNewPasswordIq() -> XMPPIQ? {
        guard let jid = self.jid,
              let username = jid.split(separator: "@").first,
              let domain = jid.split(separator: "@").last else {
            return nil
        }
        let elementId = self.stream.generateUUID
        let query = DDXMLElement(name: "query", xmlns: "jabber:iq:register")
        let usernameChild = DDXMLElement(name: "username", stringValue: String(username))
        let passwordChild = DDXMLElement(name: "password", stringValue: newPassword)
        let key = DDXMLElement(name: "key", stringValue: "dde89e4b361zljrv")
        query.addChild(usernameChild)
        query.addChild(passwordChild)
        //query.addChild(key)
        let iq = XMPPIQ(iqType: .set, to: XMPPJID(string: String(domain)), elementID: elementId, child: query)
        return iq
    }
    
    private func close(_ sender: XMPPStream) {
        self.logConnectionDiagnostics(event: "disconnect_requested")
        sender.disconnect()
        self.logConnectionDiagnostics(event: "disconnect_completed_local")
        sender.myJID = nil
        self.jid = nil
        self.password = nil
        self.endBackgroundUpdateTask()
        self.stream.removeDelegate(self)
        self.stream = XMPPStream()
    }

    final func logConnectionDiagnostics(
        event: String,
        details: [String: Any?] = [:],
        rawXML: String? = nil,
        error: Error? = nil
    ) {
        ConnectionDiagnosticsLogger.log(
            event: event,
            stream: .changePassword,
            jid: self.jid ?? self.stream.myJID?.bare,
            state: ConnectionDiagnosticsLogger.stateDescription(for: self.stream),
            details: details,
            rawXML: rawXML,
            error: error
        )
    }
}

extension XMPPChangePasswordManager: XMPPStreamDelegate {
    func xmppStreamWillConnect(_ sender: XMPPStream) {
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
        self.logConnectionDiagnostics(
            event: "xmpp_stream_connected",
            details: ["resource": sender.myJID?.resource ?? "none"]
        )
        guard let password = password else {
            self.logConnectionDiagnostics(event: "authentication_missing_password")
            self.stream.disconnect()
            self.stream.myJID = nil
            self.jid = nil
            self.password = nil
            return
        }
        do {
            self.logConnectionDiagnostics(
                event: "authentication_branch_selected",
                details: ["credentialKind": "password"]
            )
            try sender.authenticate(withPassword: password)
        } catch {
            self.logConnectionDiagnostics(event: "authentication_start_failed", error: error)
            DDLogDebug("XMPPChangePasswordManager: \(#function). \(error)")
        }
    }
    
    func xmppStreamDidAuthenticate(_ sender: XMPPStream) {
        self.logConnectionDiagnostics(
            event: "authentication_succeeded",
            details: ["resource": sender.myJID?.resource ?? "none"]
        )
        guard let iq = makeNewPasswordIq() else {
            close(sender)
            return
        }
        self.logConnectionDiagnostics(
            event: "stanza_send_iq",
            details: [
                "id": iq.elementID ?? "none",
                "type": iq.type ?? "none",
                "to": iq.to?.bare ?? "none"
            ],
            rawXML: iq.xmlString
        )
        sender.send(iq)
    }
    
    func xmppStream(_ sender: XMPPStream, didNotAuthenticate error: DDXMLElement) {
        self.logConnectionDiagnostics(
            event: "authentication_failed",
            rawXML: error.xmlString
        )
        close(sender)
        guard let text = error.elements(forName: "text").first?.stringValue else {
            return
        }
        delegate?.didReceiveResponse(title: "Authorization error".localizeString(id: "AUTHENTICATION_FAILED", arguments: []), description: text)
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
        
        switch iq.iqType {
        
        case .result:
            close(sender)
            delegate?.didReceiveResponse(title: "Success", description: "Password changed")
        
        case .error:
            close(sender)
            if let language = TranslationsManager.shared.currentLang { //выбран язык
                let code = TranslationsManager.shared.prepareLanCode(language: language)
                if let errorDescriptions = iq.element(forName: "error")?.elements(forName: "text") { //есть описания ошибок
                    if let errorLocalDescription = errorDescriptions.first(where: { $0.attributeStringValue(forName: "lang") == code })?.stringValue { //есть описание, соответствующее выбранному языку
                        delegate?.didReceiveResponse(title: "Error".localizeString(id: "error", arguments: []), description: errorLocalDescription)
                    } else if let errorEnDescription = errorDescriptions.first(where: { $0.attributeStringValue(forName: "lang") == "en" })?.stringValue { //или хотя бы на английском
                        delegate?.didReceiveResponse(title: "Error".localizeString(id: "error", arguments: []), description: errorEnDescription)
                    } else {
                        let errorOnlyDescription = errorDescriptions.first?.stringValue //или хоть какое есть первое попавшееся
                        delegate?.didReceiveResponse(title: "Error".localizeString(id: "error", arguments: []), description: errorOnlyDescription ?? "Unknown error")
                    }
                } else { //нет никаких описаний
                    delegate?.didReceiveResponse(title: "Error".localizeString(id: "error", arguments: []), description: "Unknown error")
                }
            } else if let errorDescriptions = iq.element(forName: "error")?.elements(forName: "text") { //не выбран язык, есть описания ошибок
                if let errorEnDescription = errorDescriptions.first(where: { $0.attributeStringValue(forName: "lang") == "en" })?.stringValue { //есть описание на английском
                    delegate?.didReceiveResponse(title: "Error", description: errorEnDescription)
                } else {
                    let errorOnlyDescription = errorDescriptions.first?.stringValue  //или хоть какое есть первое попавшееся
                    delegate?.didReceiveResponse(title: "Error", description: errorOnlyDescription ?? "Unknown error")
                }
            } else { //не выбран язык и нет никаких описаний
                delegate?.didReceiveResponse(title: "Error", description: "Unknown error")
            }
        
        default: return false
        }
        
        return true
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

    func xmppStream(_ sender: XMPPStream, didReceiveError error: DDXMLElement) {
        self.logConnectionDiagnostics(
            event: "xmpp_stream_error",
            rawXML: error.xmlString
        )
    }

    func xmppStreamDidReceive(_ sender: XMPPStream, streamFeatures features: DDXMLElement) {
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
    }

    func xmppStreamDidDisconnect(_ sender: XMPPStream, withError error: Error?) {
        self.logConnectionDiagnostics(
            event: "tcp_disconnected",
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
}
