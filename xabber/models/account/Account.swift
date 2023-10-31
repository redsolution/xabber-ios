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
    var httpUploads: UploadManagerProtocol //HTTPUploadsManager
    var xUploads: UploadManagerProtocol //XabberUploadManager
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
    
    var isRequestedAway: Bool = false
    var isBinded: Bool = false
    
    var isRegularPushRequestSended: Bool = false
    var isVoIPPushRequestSended: Bool = false
    
    var isSubscribedOnStateChange: Bool = false
    var isSynced: Bool = false
    var isConfigured: Bool = false
    
    var deviceName: String = ""
    
    public var isNewAccount: Bool = false
    
    init(jid: String, queue: DispatchQueue) {
        // set default connection fields
        self.jid = jid
        self.host = ""
        self.port = 5222
        // try to set default username
        self.username = "\(self.jid.split(separator: "@").first!)"
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
        self.httpUploads = HTTPUploadsManager(withOwner: self.jid)
        self.xUploads = XabberUploadManager(withOwner: self.jid)
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
        // start init NSObject
        super.init()
        self.registerModules()
        self.lastChats.resetSyncedStatus()
        self.groupchats.reset()
        self.load()
//        xuploads.confi-gure()
//        self.asyncConnect()
    }
    
    func getDefaultUploader() -> UploadManagerProtocol? {
        let uploaders = [self.xUploads, self.httpUploads] //в порядке уменьшения приоритета
        
        for uploader in uploaders {
            if uploader.isAvailable() {
                return uploader
            }
        }
        return nil
    }
    
    func configureStream() {
        self.xmppStream.shouldRequestXToken = false
        self.xmppStream.shouldRegisterDevice = false
        self.xmppStream.xabberClientInfo = "Xabber"
        self.xmppStream.xabberPublicLabel = self.deviceName
        self.xmppStream.xabberDeviceInfo = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
        self.xmppStream.myJID = XMPPJID(string: jid, resource: AccountManager.defaultResource)
        self.xmppStream.startTLSPolicy = XMPPStreamStartTLSPolicy.preferred
        self.xmppStream.keepAliveInterval = 60
        self.xmppStream.removeDelegate(self, delegateQueue: self.queue)
        self.xmppStream.removeDelegate(self)
        self.xmppStream.addDelegate(self, delegateQueue: self.queue)
    }
    
    func resetStream() {
        self.statusState.accept(.offline)
        self.statusMessage.accept(RosterUtils.shared.convertStatus(.offline))
        self.xmppStream.abortConnecting()
        self.xmppStream.disconnect()
        self.xmppStream.asyncSocket.disconnect()
        self.xmppStream.removeDelegate(self)
        self.xmppStream = XMPPStream()
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
    }
    
    public final func registerRegularPushForAccount() {
        if !self.isRegularPushRequestSended {
            self.isRegularPushRequestSended = true
            DispatchQueue.global(qos: .background).async {
                self.isRegularPushRequestSended = APNSManager.shared.sendRegistrationRequest(forJid: self.jid, voip: false)
            }
        }
    }
    
    public final func registerVoIPPushForAccount() {
        if !self.isVoIPPushRequestSended {
            self.isVoIPPushRequestSended = true
            DispatchQueue.global(qos: .background).async {
                self.isVoIPPushRequestSended = APNSManager.shared.sendRegistrationRequest(forJid: self.jid, voip: true)
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
        if isConfigured {
            return
        }
        isConfigured = true
        self.reconnect.activate(self.xmppStream)
        self.reconnect.addDelegate(self, delegateQueue: self.queue)
        self.reconnect.autoReconnect = true
        self.reconnect.reconnectDelay = 1
        self.reconnect.reconnectTimerInterval = 1

        self.sm.autoResume = true
        self.sm.activate(self.xmppStream)
        self.sm.addDelegate(self, delegateQueue: self.queue)
        self.sm.automaticallyRequestAcks(afterStanzaCount: 8, orTimeout: 20)
        self.sm.enable(withResumption: true, maxTimeout: 3600)
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
            self.deliveryReceipts
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
    @objc
    public final func connect() {
        if self.delayedConnectTimer != nil {
            self.delayedConnectTimer?.invalidate()
            self.delayedConnectTimer = nil
        }
        if self.xmppStream.isConnecting {
            return
        }
        if self.xmppStream.isConnected {
            return
        }
        if self.xmppStream.isAuthenticated {
            return
        }
        if self.xmppStream.isAuthenticating {
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
            try self.xmppStream.connect(withTimeout: 1)
        } catch {
            DDLogDebug("cant conenct: \(error.localizedDescription)")
            self.statusMessage.accept("Offline")
            AccountManager.shared.changeNewUserState(for: self.jid, to: .failure("Server not found"))
            AccountManager.shared.markAsConnected(jid: self.jid)
            if self.delayedConnectTimer == nil {
                self.delayedConnectTimer?.invalidate()
                self.delayedConnectTimer = Timer(timeInterval: 2, target: self, selector: #selector(self.connect), userInfo: nil, repeats: false)
                RunLoop.main.add(self.delayedConnectTimer!, forMode: RunLoop.Mode.default)
            }
        }
        self.isBinded = false
    }
    
/**
 *    open XMPPStream in special thread
 **/
    func asyncConnect() {
        self.configureStream()
        self.connect()
    }
    
/**
 *    stop user XMPP session, change account status to offline
 *    if @hard is true, session close without sending unavailable presence to server
 **/
    func disconnect(hard: Bool = false) {
        print(#function)
        self.statusState.accept(.offline)
        self.statusMessage.accept(RosterUtils.shared.convertStatus(.offline))
        self.resetModules()
        if hard {
            self.xmppStream.disconnect()
//            self.xmppStream.asyncSocket.disconnect()
        } else {
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
                    self.asyncConnect()
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
        self.asyncConnect()
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
                item.colorKey = AccountColorManager.shared.colorItem(for: self.jid).key
                item.username = self.username
                item.node = self.push.node
                item.service = self.push.service
                item.statusMessage = self.statusMessage.value
                item.xTokenSupport = self.supportTokens
                item.xTokenUID = self.tokenUid
                item.createdAt = Date()
                self.deviceName = NickGenerator.shared.genRandomNick()
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
            [unowned self] in
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
        self.resetModules()
        self.statusMessage.accept("Offline")
        self.showReconnectStatus(connectionFlags: connectionFlags)
    }
    
    func xmppReconnect(_ sender: XMPPReconnect, shouldAttemptAutoReconnect connectionFlags: SCNetworkConnectionFlags) -> Bool {
        DDLogDebug("ShouldAttemptAutoReconnect. Connection flags \(connectionFlags)")
//        if UInt32(connectionFlags) == 3 {
//            return false
//        }
//        self.showReconnectStatus(connectionFlags: connectionFlags)
//        DispatchQueue.main.async {
//            ToastPresenter(message: "Reconnect: flag \(UInt32(connectionFlags))").present(animated: true)
//        }
        if self.xmppStream.isAuthenticated {
            return false
        }
        
        return sender.autoReconnect
    }
    
}
