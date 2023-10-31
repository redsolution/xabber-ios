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
    
    var queue: DispatchQueue

    var groupchat: GroupchatManager? = nil
    var httpUploader: UploadManagerProtocol? = nil // HTTPUploadsManager? = nil
    var xUploader: UploadManagerProtocol? = nil // XabberUploadManager? = nil
    var avatarUploader: AvatarUploadManager? = nil
    var chatMarkers: ChatMarkersManager? = nil
    var deliveryManager: ReliableMessageDeliveryManager? = nil
    var messages: MessageManager? = nil
    var mam: MessageArchiveManager? = nil
    var vcardManager: VCardManager? = nil
    var presences: PresenceManager? = nil
    var blocked: BlockManager? = nil
    var retract: MessageDeleteManager? = nil
    var roster: RosterManager? = nil
    var sync: ClientSynchronizationManager? = nil
    var xtokens: XTokenManager? = nil
    var devices: XMPPDeviceManager?  = nil
    var omemo: OmemoManager? = nil
    var reconnect: XMPPReconnect? = nil
    var x509: X509XMPPManager? = nil
    var shouldRecreate: Bool = true
    
    override init() {
//        queue = DispatchQueue.global(qos: .default)
        queue = DispatchQueue(
            label: "com.xabber.action.manager.ui",
            qos: .default,
            attributes: [.concurrent],
            autoreleaseFrequency: .inherit,
            target: DispatchQueue.global()
        )
        super.init()
    }
    
    func getDefaultUploader() -> UploadManagerProtocol? {
        let uploaders = [self.xUploader, self.httpUploader].compactMap { $0 } //в порядке уменьшения приоритета
        
        for uploader in uploaders {
            if uploader.isAvailable() {
                return uploader
            }
        }
        return nil
    }
    
    public final func open(owner: String, force: Bool = false) {

//        return
//        print("UI CONNECTION START OPEN!!!!!!")
        guard XMPPJID(string: owner) != nil else { return }
//        if !force {
//            if self.currentJid == owner {
//                return
//            }
//
//        } else {
//            if !shouldRecreate {
//                return
//            }
//        }
        if self.currentJid == owner && self.stream.isAuthenticated {
            return
        }
        print("UI CONNECTION OPEN!!!!!!")
        if self.currentJid != nil {
            self.close(disconnect: true)
        }
        self.stream = XMPPStream()
        self.stream.addDelegate(self, delegateQueue: self.queue)
        
        self.currentJid = owner
        self.groupchat = GroupchatManager(withOwner: owner)
        self.httpUploader = HTTPUploadsManager(withOwner: owner)
        self.xUploader = XabberUploadManager(withOwner: owner)
        self.avatarUploader = AvatarUploadManager(withOwner: owner)
        self.chatMarkers = ChatMarkersManager(withOwner: owner)
        self.deliveryManager = ReliableMessageDeliveryManager(withOwner: owner)
        self.messages = MessageManager(withOwner: owner, activeStream: false)
        self.mam = MessageArchiveManager(withOwner: owner)
        self.chatMarkers = ChatMarkersManager(withOwner: owner)
        self.vcardManager = VCardManager(withOwner: owner)
        self.presences = PresenceManager(withOwner: owner, withoutSubscribtion: true)
        self.blocked = BlockManager(withOwner: owner)
        self.retract = MessageDeleteManager(withOwner: owner)
        self.roster = RosterManager(withOwner: owner)
        self.sync = ClientSynchronizationManager(withOwner: owner)
        self.xtokens = XTokenManager(withOwner: owner)
        self.devices = XMPPDeviceManager(withOwner: owner)
        self.reconnect = XMPPReconnect(dispatchQueue: self.queue)
        self.x509 = X509XMPPManager(withOwner: owner)
        
        self.stream.myJID = XMPPJID(string: owner, resource: AccountManager.defaultResource + "_ui_upgrade_task")
        self.stream.startTLSPolicy = XMPPStreamStartTLSPolicy.preferred
//        self.stream.skipStartSession = true
        self.stream.keepAliveInterval = 60
//        self.stream.que
        self.reconnect?.activate(self.stream)
        queue.async {
            do {
                try self.stream.connect(withTimeout: 5)
            } catch {
                DDLogDebug("XMPPActionManager: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
    public final func disable(_ owner: String) {
//        return
        print("UI CONNECTION DISABLE!!!!!!")
        if self.currentJid != owner {
            return
        }
        self.shouldRecreate = false
        self.reconnect?.stop()
        self.stream.abortConnecting()
        self.stream.disconnect()
        self.stream.asyncSocket.disconnect()
        self.groupchat = nil
        self.httpUploader = nil
        self.xUploader = nil
        self.chatMarkers = nil
        self.deliveryManager = nil
        self.messages = nil
        self.mam = nil
        self.chatMarkers = nil
        self.roster = nil
        self.presences = nil
        self.retract = nil
        self.blocked = nil
        self.vcardManager = nil
        self.sync = nil
        self.xtokens = nil
        self.devices = nil
        self.omemo = nil
        self.x509 = nil
//        self.stream.removeDelegate(self, delegateQueue: self.queue)
    }
    
    public final func close(soft: Bool = false, disconnect: Bool = false) {
//        return
        print("UI CONNECTION CLOSE!!!!!!")
        if !CommonConfigManager.shared.config.supports_multiaccounts && !disconnect {
            return
        }
        if soft {
            self.stream.disconnectAfterSending()
//            self.stream.asyncSocket.disconnectAfterReadingAndWriting()
        } else {
            self.stream.disconnect()
//            self.stream.asyncSocket.disconnect()
        }
        self.currentJid = nil
        self.groupchat = nil
        self.httpUploader = nil
        self.xUploader = nil
        self.chatMarkers = nil
        self.deliveryManager = nil
        self.messages = nil
        self.mam = nil
        self.roster = nil
        self.presences = nil
        self.retract = nil
        self.blocked = nil
        self.vcardManager = nil
        self.sync = nil
        self.xtokens = nil
        self.devices = nil
        self.omemo = nil
        self.x509 = nil
//        self.stream.removeDelegate(self, delegateQueue: self.queue)
    }
    
    public final func restore() {
        print("UI CONNECTION RESTORE")
        guard let owner = self.currentJid else { return }
        stream.disconnect()
        stream.asyncSocket.disconnect()
//        self.stream.removeDelegate(self)
//        self.stream.addDelegate(self, delegateQueue: self.queue)
        queue.async {
            self.stream.myJID = XMPPJID(string: owner, resource: AccountManager.defaultResource + "_ui_upgrade_task")
            self.stream.startTLSPolicy = XMPPStreamStartTLSPolicy.allowed
            self.stream.keepAliveInterval = 10
            do {
                try self.stream.connect(withTimeout: 3)
            } catch {
                DDLogDebug("XMPPActionManager: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
    public final func performRequest(owner: String, action: @escaping ((XMPPStream, XMPPUIActionManager) -> Void), fail: @escaping (() -> Void), retryCounter: Int = 0) {
        self.open(owner: owner, force: false)
//        print("UI STREAM STATE", stream.isConnected, "is in auth process:", stream.isAuthenticating, "auth", stream.isAuthenticated)
        
        if !self.stream.isAuthenticated {
            if retryCounter > 3 {
                fail()
                return
            } else {
                if !(self.stream.isConnecting || self.stream.isAuthenticating || self.stream.isConnected) {
                    self.restore()
                }
                self.queue.asyncAfter(deadline: .now() + 2) {
                    self.performRequest(owner: owner, action: action, fail: fail, retryCounter: retryCounter + 1)
                }
            }
            return
        }
        action(self.stream, self)
    }
    
    func tokenWasInvalidated() {
        NotificationCenter.default.post(name: ApplicationStateManager.tokenWasExpired, object: self.currentJid!)
        self.close(soft: false, disconnect: true)
    }
    
    deinit {
        print("UI DEINIT")
    }
}

extension XMPPUIActionManager: XMPPReconnectDelegate {
    func xmppReconnect(_ sender: XMPPReconnect, shouldAttemptAutoReconnect connectionFlags: SCNetworkConnectionFlags) -> Bool {
        return true
    }
}
