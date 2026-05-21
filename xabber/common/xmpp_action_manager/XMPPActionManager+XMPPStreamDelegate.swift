//
//  XMPPActionManager+XMPPStreamDelegate.swift
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

extension XMPPActionManager: XMPPStreamDelegate {
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
            DDLogDebug("XMPPActionManager: \(#function). \(error)")
        }
    }
    
    func xmppStreamDidAuthenticate(_ sender: XMPPStream) {
        self.logConnectionDiagnostics(
            event: "authentication_succeeded",
            details: [
                "resource": sender.myJID?.resource ?? "none",
                "queuedStanzas": stanzaQueue.count
            ]
        )
        stanzaQueue.forEach {
            self.logConnectionDiagnostics(
                event: "stanza_send",
                details: ["element": $0.name ?? "unknown"],
                rawXML: $0.xmlString
            )
            sender.send($0)
        }
        self.logConnectionDiagnostics(event: "disconnect_requested", details: ["reason": "queuedStanzasSent"])
        sender.disconnectAfterSending()
        sender.myJID = nil
        self.jid = nil
        self.password = nil
        self.stanzaQueue = []
        self.endBackgroundUpdateTask()
//        self.stream.removeDelegate(self)
//        self.stream = XMPPStream()
    }

    func xmppStream(_ sender: XMPPStream, didNotAuthenticate error: DDXMLElement) {
        self.logConnectionDiagnostics(
            event: "authentication_failed",
            rawXML: error.xmlString
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

    func xmppStream(_ sender: XMPPStream, didSend message: XMPPMessage) {
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

    func xmppStream(_ sender: XMPPStream, didSend presence: XMPPPresence) {
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

    func xmppStream(_ sender: XMPPStream, didFailToSend message: XMPPMessage, error: Error) {
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

    func xmppStream(_ sender: XMPPStream, didFailToSend presence: XMPPPresence, error: Error) {
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
