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

class XMPPActionManager: NSObject {
    open class var shared: XMPPActionManager {
        struct XMPPActionManagerSingleton {
            static let instance = XMPPActionManager()
        }
        return XMPPActionManagerSingleton.instance
    }
    
    var jid: String? = nil
    var password: String? = nil
    
    var stanzaQueue: [DDXMLElement] = []
    
    var stream: XMPPStream = XMPPStream()
    
    var queue: DispatchQueue
    
    var backgroundUpdateTask: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 0)
    
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
    
    public final func sendStanzas(jid: String, stanzas: [DDXMLElement]) {
        self.stanzaQueue = stanzas
        self.jid = jid
        let uniqueServiceName = CredentialsManager.uniqueServiceName()
        let uniqueAccessGroup = CredentialsManager.uniqueAccessGroup()
        let keychain = KeychainWrapper(serviceName: uniqueServiceName,
                                       accessGroup: uniqueAccessGroup)
        self.password = keychain.string(forKey: jid)
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
                    "queuedStanzas": stanzas.count,
                    "passwordPresent": self.password?.isEmpty == false
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
                DDLogDebug("XMPPActionManager: \(#function). \(error.localizedDescription)")
            }
        }
    }

    final func logConnectionDiagnostics(
        event: String,
        details: [String: Any?] = [:],
        rawXML: String? = nil,
        error: Error? = nil
    ) {
        ConnectionDiagnosticsLogger.log(
            event: event,
            stream: .oneShot,
            jid: self.jid ?? self.stream.myJID?.bare,
            state: ConnectionDiagnosticsLogger.stateDescription(for: self.stream),
            details: details,
            rawXML: rawXML,
            error: error
        )
    }
}
