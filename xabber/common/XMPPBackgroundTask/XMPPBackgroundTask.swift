//
//  XMPPBackgroundTask.swift
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

class XMPPBackgroundTask: NSObject {
    
    static let endFixHistoryTask = Notification.Name("com.xabber.endFixHistoryTask")
    
    struct HistorySyncTaskInfo {
        let jid: String
        let conversationType: ClientSynchronizationManager.ConversationType
    }
    
    enum TaskType {
        case messageHistory(String, ClientSynchronizationManager.ConversationType)
//        case fixHistory(String, ClientSynchronizationManager.ConversationType)
        case historySyncForMultipleJids([HistorySyncTaskInfo ])
        case none
    }
    
    var jid: String
    var password: String
    
    var taskType: TaskType
    
    var stream: XMPPStream = XMPPStream()
    let authenticationCounterTracker = XMPPAuthenticationCounterTracker()
    
    var queue: DispatchQueue
    
    var vcardManager: VCardManager
    var avatarManager: XmppAvatarManager
    
    var mam: MessageArchiveManager
    var messages: MessageManager
    
    var startMoment: TimeInterval = 0.0
    var endTimer: Timer? = nil
    
    public var backgroundUpdateTask: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 0)
    
    init(jid: String, task taskType: TaskType) {
        self.jid = jid
        self.taskType = taskType
        let uniqueServiceName = CredentialsManager.uniqueServiceName()
        let uniqueAccessGroup = CredentialsManager.uniqueAccessGroup()
        let keychain = KeychainWrapper(serviceName: uniqueServiceName,
                                       accessGroup: uniqueAccessGroup)
        self.password = keychain.string(forKey: jid) ?? ""
        self.queue = DispatchQueue(
            label: "com.xabber.background.\(UUID().uuidString)",
            qos: .background,
            attributes: [],
            autoreleaseFrequency: .workItem,
            target: nil
        )
        
        self.vcardManager = VCardManager(withOwner: jid)
        self.avatarManager = XmppAvatarManager(withOwner: jid)
        self.mam = MessageArchiveManager(withOwner: jid)
        self.messages = MessageManager(withOwner: jid, activeStream: false)
        super.init()
        let mamFinalizationQueue = self.queue
        self.mam.pendingArchiveFailureFinalizationDispatcher = { work in
            mamFinalizationQueue.async(execute: work)
        }
        self.messages.archiveQueryIdPersistenceResolver = { [weak self] queryId in
            self?.mam.shouldPersistArchiveQueryId(queryId) ?? false
        }
        self.connect()
        self.mam.backgroundTaskDelegate = self
//        print(self.backgroundUpdateTask, self.taskType, "new background task")
    }
    
    func endBackgroundUpdateTask() {
        UIApplication.shared.endBackgroundTask(self.backgroundUpdateTask)
        self.backgroundUpdateTask = UIBackgroundTaskIdentifier.invalid
    }
    
    final func connect() {
        self.queue.async {
            self.backgroundUpdateTask = UIApplication.shared.beginBackgroundTask(withName: UUID().uuidString, expirationHandler: {
                self.stream.disconnect()
                self.endBackgroundUpdateTask()
            })
            self.stream = XMPPStream()
            self.stream.myJID = XMPPJID(string: self.jid, resource: AccountManager.defaultResource + "_background_task_" + "\(UUID().uuidString.split(separator: "-").first ?? "")".lowercased())
//            self.stream.hostName = "2ztp3tk75olpu3svugvt3nolvbfbn3aej4qjykqmthw7gd36r4rtmkad.onion"
            self.stream.startTLSPolicy = XMPPStreamStartTLSPolicy.preferred
            self.stream.keepAliveInterval = 60
//            self.stream.addDelegate(self.avatarManager, delegateQueue: self.queue)
            self.stream.addDelegate(self, delegateQueue: self.queue)
            self.logConnectionDiagnostics(
                event: "stream_configured",
                details: [
                    "resource": self.stream.myJID?.resource ?? "none",
                    "tlsPolicy": self.stream.startTLSPolicy.rawValue,
                    "keepAlive": self.stream.keepAliveInterval
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
            self.startMoment = Date().timeIntervalSince1970
            self.endTimer = Timer.scheduledTimer(
                timeInterval: 1,
                target: self,
                selector: #selector(self.watchdog),
                userInfo: nil,
                repeats: true
            )
        }
    }
    
    @objc
    private final func watchdog(_ sender: AnyObject?) {
        if (self.startMoment - Date().timeIntervalSince1970) < (UIApplication.shared.backgroundTimeRemaining - 1.5) {
            self.backgroundTaskDidEnd(shouldContinue: true)
        }
    }
    
    public final func disconnect() {
        self.logConnectionDiagnostics(event: "disconnect_requested")
        self.stream.disconnect()
        self.stream.asyncSocket.disconnect()
        self.stream.removeDelegate(self)
        self.stream = XMPPStream()
        self.logConnectionDiagnostics(event: "disconnect_completed_local")
    }

    final func logConnectionDiagnostics(
        event: String,
        details: [String: Any?] = [:],
        rawXML: String? = nil,
        error: Error? = nil
    ) {
        ConnectionDiagnosticsLogger.log(
            event: event,
            stream: .background,
            jid: self.jid,
            state: ConnectionDiagnosticsLogger.stateDescription(for: self.stream),
            details: details,
            rawXML: rawXML,
            error: error
        )
    }
}
