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

class XMPPDeviceManager: AbstractXMPPManager {
    private static let persistenceQueue = DispatchQueue(
        label: "com.xabber.xmpp.device-manager.persistence",
        qos: .utility
    )

    public var deviceId: String? = nil

    /// Accepted authentication belongs to one concrete bound stream. Cached
    /// Devices metadata and local OMEMO projections never create this proof.
    private final class SessionContext {
        weak var stream: XMPPStream?
        var attempt: UInt64 = 0
        var boundFullJID: Data?
        var acceptedDeviceID: String?
        var acceptedLegacyHOTP = false
        var acceptedGeneration: UInt64?
        var acceptedActive = false
        // XMPPFramework sets isAuthenticated before bind. This records the
        // actual completed bind callback, including non-Devices password binds.
        var boundAuthenticationCompleted = false
        var registrationRequestID: String?
        var registrationAttempt: UInt64?
        var registrationRecipient: Data?
        var registeredDeviceID: String?
        init(stream: XMPPStream) { self.stream = stream }
    }
    private let sessionLock = NSRecursiveLock()
    private var sessionContexts: [ObjectIdentifier: SessionContext] = [:]
    private var nextSessionGeneration: UInt64 = 0
    private struct ListRequest {
        let context: SessionContext
        let attempt: UInt64
        let recipient: Data?
    }
    private var listRequests: [String: ListRequest] = [:]

    private func context(on stream: XMPPStream, create: Bool) -> SessionContext? {
        sessionContexts = sessionContexts.filter { $0.value.stream != nil }
        let key = ObjectIdentifier(stream)
        if let context = sessionContexts[key], context.stream === stream { return context }
        guard create else { return nil }
        let value = SessionContext(stream: stream)
        sessionContexts[key] = value
        return value
    }

    private func clearBinding(_ context: SessionContext) {
        context.boundFullJID = nil
        context.acceptedDeviceID = nil
        context.acceptedLegacyHOTP = false
        context.acceptedGeneration = nil
        context.acceptedActive = false
    }

    @discardableResult
    private func clearRegistration(_ context: SessionContext) -> String? {
        let requestID = context.registrationRequestID
        context.registrationRequestID = nil
        context.registrationAttempt = nil
        context.registrationRecipient = nil
        context.registeredDeviceID = nil
        return requestID
    }

    private func advanceGeneration() -> UInt64 {
        nextSessionGeneration &+= 1
        if nextSessionGeneration == 0 { nextSessionGeneration = 1 }
        return nextSessionGeneration
    }

    internal func beginAuthentication(on stream: XMPPStream) {
        sessionLock.lock()
        let context = context(on: stream, create: true)!
        context.attempt = advanceGeneration()
        context.boundAuthenticationCompleted = false
        let previous = clearRegistration(context)
        let replacedRequests = sessionContexts.values.filter { $0 !== context }.compactMap { other -> String? in
            clearBinding(other)
            other.boundAuthenticationCompleted = true
            return clearRegistration(other)
        }
        context.acceptedActive = false
        let listIDs = Array(listRequests.keys)
        listRequests.removeAll()
        // The previous accepted session is retained only for genuine SM resume;
        // getters deny it while disconnected/unauthenticated.
        sessionLock.unlock()
        if let previous { queryIds.remove(previous) }
        for id in replacedRequests { queryIds.remove(id) }
        for id in listIDs { queryIds.remove(id) }
    }

    internal func recordAuthenticatedSession(on stream: XMPPStream, deviceID: String?,
        didResume: Bool, legacyHOTP: Bool = false) {
        sessionLock.lock()
        let context = context(on: stream, create: true)!
        context.boundAuthenticationCompleted = true
        let previousRequest = clearRegistration(context)
        defer {
            sessionLock.unlock()
            if let previousRequest { queryIds.remove(previousRequest) }
        }
        guard stream.isAuthenticated, !stream.isDisconnected,
              let jid = stream.myJID, jid.bare == XMPPJID(string: owner)?.bare,
              jid.resource?.isEmpty == false else {
            clearBinding(context)
            return
        }
        // This manager represents one account's primary Devices session. A
        // replacement connection cannot leave an old authenticated-looking
        // stream eligible for publication or subsequent resume authority.
        for other in sessionContexts.values where other !== context {
            clearBinding(other)
            other.boundAuthenticationCompleted = true
            if let id = clearRegistration(other) { queryIds.remove(id) }
        }
        let fullJID = Data(jid.full.utf8)
        if didResume {
            let matchesSuppliedMode = deviceID.map {
                !$0.isEmpty && context.acceptedDeviceID == $0 && !legacyHOTP
            } ?? (!legacyHOTP || context.acceptedLegacyHOTP)
            guard context.acceptedGeneration != nil,
                  context.boundFullJID == fullJID, matchesSuppliedMode else {
                clearBinding(context)
                return
            }
            context.acceptedActive = true
            return
        }
        clearBinding(context)
        let strongID = deviceID.flatMap { Self.isValidOpaqueDeviceID($0) ? $0 : nil }
        guard (strongID != nil && !legacyHOTP) || (strongID == nil && legacyHOTP) else { return }
        context.boundFullJID = fullJID
        context.acceptedDeviceID = strongID
        context.acceptedLegacyHOTP = legacyHOTP
        context.acceptedGeneration = advanceGeneration()
        context.acceptedActive = true
    }

    private func authenticatedContext(on stream: XMPPStream) -> SessionContext? {
        guard let context = context(on: stream, create: false),
              context.acceptedGeneration != nil, context.acceptedActive else { return nil }
        guard stream.isAuthenticated, !stream.isDisconnected else {
            context.acceptedActive = false
            return nil
        }
        guard let jid = stream.myJID,
              jid.bare == XMPPJID(string: owner)?.bare, jid.resource?.isEmpty == false,
              context.boundFullJID == Data(jid.full.utf8) else {
            clearBinding(context)
            return nil
        }
        return context
    }

    internal func authenticatedDeviceID(on stream: XMPPStream) -> String? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return authenticatedContext(on: stream)?.acceptedDeviceID
    }

    internal func authenticatedLegacyHOTP(on stream: XMPPStream) -> Bool {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return authenticatedContext(on: stream)?.acceptedLegacyHOTP ?? false
    }

    internal func authenticatedSessionGeneration(on stream: XMPPStream) -> UInt64? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return authenticatedContext(on: stream)?.acceptedGeneration
    }

    internal func authenticationAttemptGeneration(on stream: XMPPStream) -> UInt64? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard let context = context(on: stream, create: false), context.attempt != 0 else { return nil }
        return context.attempt
    }

    private static func isValidOpaqueDeviceID(_ id: String) -> Bool {
        !id.isEmpty && id.utf16.count <= 512 &&
            id.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
    }

    internal func beginDeviceRegistration(on stream: XMPPStream, requestID: String,
        authenticationGeneration: UInt64? = nil) {
        guard !requestID.isEmpty, !stream.isDisconnected,
              stream.myJID?.bare == XMPPJID(string: owner)?.bare else { return }
        sessionLock.lock()
        let context = context(on: stream, create: true)!
        guard !context.boundAuthenticationCompleted,
              authenticationGeneration == nil || context.attempt == authenticationGeneration else {
            sessionLock.unlock()
            return
        }
        let previous = clearRegistration(context)
        if context.attempt == 0 { context.attempt = advanceGeneration() }
        context.registrationRequestID = requestID
        context.registrationAttempt = context.attempt
        context.registrationRecipient = stream.myJID.map { Data($0.full.utf8) }
        sessionLock.unlock()
        if let previous { queryIds.remove(previous) }
        queryIds.insert(requestID)
    }

    internal func registeredDeviceID(on stream: XMPPStream) -> String? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard !stream.isDisconnected, stream.myJID?.bare == XMPPJID(string: owner)?.bare,
              let context = context(on: stream, create: false),
              context.registrationAttempt == context.attempt,
              !context.boundAuthenticationCompleted else { return nil }
        return context.registeredDeviceID
    }

    /// No pending query crosses a transport break. The accepted witness is
    /// inactive until a genuine same-session SM resume explicitly restores it.
    internal func suspendSessionForReconnect() {
        sessionLock.lock()
        for context in sessionContexts.values {
            _ = clearRegistration(context)
            context.acceptedActive = false
        }
        listRequests.removeAll()
        sessionLock.unlock()
        queryIds.removeAll()
    }

    override func clearSession() {
        sessionLock.lock()
        sessionContexts.removeAll()
        listRequests.removeAll()
        sessionLock.unlock()
        queryIds.removeAll()
        super.clearSession()
    }

    private func isOwnerServerReply(_ iq: XMPPIQ, recipient: Data?) -> Bool {
        guard let ownerJID = XMPPJID(string: owner) else { return false }
        if let from = iq.from,
           !(from.resource?.isEmpty != false && (from.bare == ownerJID.bare || from.full == ownerJID.domain)) {
            return false
        }
        if let to = iq.to, to.full != ownerJID.bare && Data(to.full.utf8) != recipient { return false }
        // A response from the local server may omit routing attributes.
        return true
    }

    override func namespaces() -> [String] {
        return [
            "https://xabber.com/protocol/devices",
        ]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }
    
    public var isAvailable: Bool = false
    
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
        self.update()
    }
    
    public final func setAvailable(_ features: DDXMLElement) {
        if isAvailable {
            return
        }
        if features.element(forName: "starttls") != nil { return }
        
        guard let synchronization = features.element(forName: "devices"),
            synchronization.xmlns() == getPrimaryNamespace() else {
                isAvailable = false
                return
        }
        isAvailable = true
    }
    
    override func onStreamPrepared(_ stream: XMPPStream) {
        self.requestList(stream)
    }
    
    public final func update() {
        do {
            let realm = try WRealm.safe()
            deviceId = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)?.deviceUuid
            if let myDeviceId = deviceId,
               myDeviceId.isNotEmpty {
                self.isAvailable = true
            }
            try realm.write {
                realm
                    .objects(DeviceStorageItem.self)
                    .filter("owner == %@", self.owner)
                    .forEach { $0.resource = nil }
            }
        } catch {
            DDLogDebug("XMPPDeviceManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    public var deviceElement: DDXMLElement? {
        get {
            guard let id = deviceId else { return nil }
            let element = DDXMLElement(name: "device", xmlns: getPrimaryNamespace())
            element.addAttribute(withName: "id", stringValue: id)
            return element
        }
    }
    
    public final func updateMyDevice(resource: String) {
        let owner = self.owner
        let resource = resource

        Self.persistenceQueue.async {
            autoreleasepool {
                do {
                    let realm = try WRealm.safe()
                    guard let deviceId = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)?.deviceUuid else {
                        return
                    }

                    let deviceInstance = realm.object(
                        ofType: DeviceStorageItem.self,
                        forPrimaryKey: DeviceStorageItem.genPrimary(uid: deviceId, owner: owner)
                    )
                    let resourceInstance = realm.object(
                        ofType: ResourceStorageItem.self,
                        forPrimaryKey: ResourceStorageItem.genPrimary(jid: owner, owner: owner, resource: resource)
                    )

                    guard deviceInstance != nil || resourceInstance != nil else {
                        return
                    }

                    try realm.write {
                        deviceInstance?.resource = resource
                        resourceInstance?.deviceId = deviceId
                    }
                } catch {
                    DDLogDebug("XMPPDeviceManager: \(#function). \(error.localizedDescription)")
                }
            }
        }
    }
    
    open func requestList(_ xmppStream: XMPPStream) {
        if !isAvailable { return }
        if let account = AccountManager.shared.find(for: owner),
           account.xmppStream === xmppStream,
           account.deferWorkUntilStartupSynchronizationCompletes(
            key: "devices.list",
            work: { user, currentStream in user.devices.requestList(currentStream) }
           ) { return }
        let elementID = xmppStream.generateUUID
        guard xmppStream.myJID?.bare == XMPPJID(string: owner)?.bare else { return }
        sessionLock.lock()
        let context = context(on: xmppStream, create: true)!
        listRequests[elementID] = ListRequest(context: context, attempt: context.attempt,
            recipient: xmppStream.myJID.map { Data($0.full.utf8) })
        sessionLock.unlock()
        queryIds.insert(elementID)
        xmppStream.send(
            XMPPIQ(
                iqType: .get,
                to: xmppStream.myJID?.domainJID,
                elementID: elementID,
                child: DDXMLElement(
                    name: "query",
                    xmlns: [getPrimaryNamespace(),"items"].joined(separator: "#")
                )
            )
        )
    }
    
    public final func update(_ xmppStream: XMPPStream, descr newDescr: String?) {
        let device = DDXMLElement(name: "device")
        let descr = DDXMLElement(name: "description", stringValue: newDescr)
        do {
            let realm = try WRealm.safe()
            guard let uid = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.deviceUuid else {
                return
            }
            device.addAttribute(withName: "id", stringValue: uid)
            
            device.addChild(descr)
            let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
            query.addChild(device)
            let elementId = xmppStream.generateUUID
            xmppStream.send(XMPPIQ(iqType: .set, to: xmppStream.myJID?.domainJID, elementID: elementId, child: query))
            self.queryIds.insert(elementId)
            if let instance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [uid, self.owner].prp()) {
                try realm.write {
                    instance.descr = newDescr ?? ""
                }
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    open func revokeAll(_ xmppStream: XMPPStream) {
//        if !isAvailable { return }
        let elementId = xmppStream.generateUUID
        let revokeAll = DDXMLElement(name: "revoke-all", xmlns: getPrimaryNamespace())
        xmppStream.send(XMPPIQ(iqType: .set, to: xmppStream.myJID?.domainJID, elementID: elementId, child: revokeAll))
        queryIds.insert(elementId)
        do {
            let realm = try WRealm.safe()
            guard let currentToken = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.deviceUuid else {
                return
            }
            let collection = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND uid != %@", owner, currentToken)
            let deviceIds: [Int] = collection.compactMap {
                return $0.omemoDeviceId
            }
            try realm.write {
                realm.delete(collection)
                realm.delete(realm.objects(SignalDeviceStorageItem.self).filter("deviceId IN %@", deviceIds))
                realm.delete(realm.objects(SignalIdentityStorageItem.self).filter("deviceId IN %@", deviceIds))
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    open func revoke(_ xmppStream: XMPPStream, uids: [String]) {
//        if !isAvailable { return }
        let elementId = xmppStream.generateUUID
        let revoke = DDXMLElement(name: "revoke", xmlns: getPrimaryNamespace())
        uids.compactMap {
            uid in
            let element = DDXMLElement(name: "device")
            element.addAttribute(withName: "id", stringValue: uid)
            return element
        }.forEach {
            revoke.addChild($0)
        }
        xmppStream.send(XMPPIQ(iqType: .set, to: xmppStream.myJID?.domainJID, elementID: elementId, child: revoke))
        queryIds.insert(elementId)
        do {
            let realm = try WRealm.safe()
//            var query: [DeviceStorageItem] = []
//            uids.forEach {
//                if let instance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [$0, owner].prp()) {
//                    query.append(instance)
//                }
//            }
            let collection = realm.objects(DeviceStorageItem.self).filter("uid IN %@", uids)
            let deviceIds: [Int] = collection.compactMap {
                return $0.omemoDeviceId
            }
            
            let instances = realm.objects(SignalDeviceStorageItem.self).filter("deviceId IN %@", deviceIds)
            instances.forEach { instance in
                do {
                    try realm.write {
                        instance.state = .revoked
                    }
                } catch {
                    DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
                }
            }
            
            try realm.write {
                realm.delete(collection)
//                realm.delete(realm.objects(SignalDeviceStorageItem.self).filter("deviceId IN %@", deviceIds))
                realm.delete(realm.objects(SignalIdentityStorageItem.self).filter("deviceId IN %@", deviceIds))
                
                
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    
    public final func read(withPresence presence: XMPPPresence, commitTransaction: Bool) -> Bool {
        func transaction(on realm: Realm, _ block: (() -> Void)) throws {
            if realm.isInWriteTransaction || !commitTransaction {
                block()
            } else {
                try realm.write(block)
            }
        }
        if presence.presenceType == .unavailable {
            guard let from = presence.from,
                  let resource = from.resource else {
                return false
            }
            do {
                let realm = try WRealm.safe()
                
                if let instance =  realm.objects(DeviceStorageItem.self).filter("owner == %@ AND resource == %@", from.bare, resource).first {
                    try transaction(on: realm) {
                        instance.resource = nil
                    }
                }
                
                if let instance = realm.object(ofType: ResourceStorageItem.self, forPrimaryKey: ResourceStorageItem.genPrimary(jid: from.bare, owner: owner, resource: resource)) {
                    try transaction(on: realm) {
                        instance.deviceId = nil
                    }
                }
            } catch {
                DDLogDebug("XMPPDeviceManager: \(#function). \(error.localizedDescription)")
            }
            
            return true
        }
        guard let from = presence.from,
              let resource = from.resource,
              let device = presence.element(forName: "device", xmlns: getPrimaryNamespace()),
              let deviceId = device.attributeStringValue(forName: "id") else {
            return false
        }
        
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [deviceId, from.bare].prp()) {
                try transaction(on: realm) {
                    instance.resource = resource
                }
            }
            if let instance = realm.object(ofType: ResourceStorageItem.self, forPrimaryKey: ResourceStorageItem.genPrimary(jid: from.bare, owner: owner, resource: resource)) {
                try transaction(on: realm) {
                    instance.deviceId = deviceId
                }
            }
        } catch {
            DDLogDebug("XMPPDeviceManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    public final func readBatch(_ presences: [XMPPPresence], commitTransaction: Bool) {
        func transaction(_ block: (() -> Void)) {
            do {
                let realm = try WRealm.safe()
                if commitTransaction {
                    try realm.write(block)
                } else {
                    block()
                }
            } catch {
                DDLogDebug("XMPPDeviceManager: \(#function). \(error.localizedDescription)")
            }
        }
        transaction {
            presences.forEach {
                _ = read(withPresence: $0, commitTransaction: false)
            }
        }
        
        presences.forEach {
            onNewDeviceAnnouncedInPresence($0)
        }
    }
    
    private final func onNewDeviceAnnouncedInPresence(_ presence: XMPPPresence) {
        if let deviceUuid = presence.element(forName: "device", xmlns: getPrimaryNamespace())?.attributeStringValue(forName: "id"),
           let jid = presence.from?.bare,
           jid != owner,
           let deviceIdInteger = Int(deviceUuid.prefix(8)) {
            do {
                let realm = try WRealm.safe()
                if !(realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner))?.isOmemoDevicesListReceived ?? false) {
                    if realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: deviceIdInteger)) == nil {
//                        AccountManager.shared.find(for: owner)?.action({ user, stream in
//                            user.omemo.getContactDevices(stream, jid: jid)
//                        })
                    }
                }
            } catch {
                DDLogDebug("XMPPDeviceManager: \(#function). \(error.localizedDescription)")
            }
        }
    }
    
    
    internal func readMessage(message: XMPPMessage) {
        guard (message.from?.isServer ?? false),
        message.element(forName: "device", xmlns: getPrimaryNamespace()) != nil else {
            return
        }
        AccountManager.shared.find(for: self.owner)?.unsafeAction({ user, stream in
            if AccountManager.shared.newAccountJid != self.owner {
                user.devices.requestList(stream)
                user.omemo.getOwnDevices(stream)
            }
        })
    }
    
    /*<message xmlns="jabber:client" to="andrew@clandestino.chat/clandestino-ios-3F02F22F" from="clandestino.chat" type="headline" id="1437221776883290598">
     <revoke xmlns="https://xabber.com/protocol/devices">
       <device id="079329357b74be246cdc88c82950e7f6"/>
     </revoke>
   </message>*/
    internal func readHeadline(_ message: XMPPMessage) -> Bool {
        guard let revoke = message.element(forName: "revoke") else {
            return false
        }
        let deviceId = revoke
            .element(forName: "device")?
            .attributeStringValue(forName: "id")
        do {
            let realm = try WRealm.safe()
            let myDeviceId = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)?.deviceUuid

            let disposition = AccountAuthenticationSafetyPolicy.disposition(
                for: .deviceHeadlineRevocation(
                    isServerSender: message.from?.isServer ?? false,
                    isHeadline: message.attributeStringValue(forName: "type") == "headline",
                    namespaceMatches: revoke.xmlns() == getPrimaryNamespace(),
                    revokedDeviceID: deviceId,
                    currentDeviceID: myDeviceId,
                    eventID: message.elementID ?? "device-headline-\(deviceId ?? "missing")"
                )
            )
            if case .authoritativeRevocation(let evidence) = disposition {
                let request = AccountRevocationRequest(
                    jid: self.owner,
                    message: "Access to account \(self.owner) was revoked. Locally stored data deleted.".localizeString(
                        id: "account_access_to_account_was_revoked",
                        arguments: [self.owner]
                    ),
                    evidence: evidence
                )
                NotificationCenter.default.post(
                    name: ApplicationStateManager.tokenWasExpired,
                    object: request
                )
            }
        } catch {
            DDLogDebug("XMPPDeviceManager: failed to validate device revocation headline")
        }
        
        return true
    }
    
    internal func read(withIQ iq: XMPPIQ, on stream: XMPPStream) -> Bool {
        if readRegisterDevice(iq, on: stream) { return true }
        return readList(iq, on: stream)
    }

    override func read(withIQ iq: XMPPIQ) -> Bool {
        switch true {
        case readRegisterDevice(iq): return true
        case readList(iq): return true
        default: return false
        }
    }
    

    

    
    internal func readList(_ iq: XMPPIQ, on incomingStream: XMPPStream? = nil) -> Bool {
        guard iq.iqType == .result, let id = iq.elementID,
              let query = iq.element(forName: "query", xmlns: [getPrimaryNamespace(), "items"].joined(separator: "#")) else { return false }
        sessionLock.lock()
        guard let request = listRequests[id], let stream = request.context.stream,
              incomingStream == nil || incomingStream === stream,
              request.attempt == request.context.attempt, stream.isAuthenticated, !stream.isDisconnected,
              stream.myJID?.bare == XMPPJID(string: owner)?.bare,
              stream.myJID.map({ Data($0.full.utf8) }) == request.recipient,
              isOwnerServerReply(iq, recipient: request.recipient) else {
            sessionLock.unlock()
            return false
        }
        listRequests.removeValue(forKey: id)
        sessionLock.unlock()
        queryIds.remove(id)
        
        do {
            let realm = try WRealm.safe()
            let uids = query
                .elements(forName: "device")
                .compactMap { $0.attributeStringValue(forName: "id") }
            try realm.write {
                let tokensToDelete = realm.objects(DeviceStorageItem.self).filter("owner == %@ AND NOT uid IN %@", self.owner, uids)
                
                realm.delete(tokensToDelete)
                let notificationInstances = realm.objects(NotificationStorageItem.self).filter("owner == %@ AND category_ == %@ AND shouldShow == false", self.owner, XMPPNotificationsManager.Category.device.rawValue)
                query.elements(forName: "device").forEach { item in
                    if let uid = item.attributeStringValue(forName: "id"),
                       let client = item.element(forName: "client")?.stringValue,
                       let expire = item.element(forName: "expire")?.stringValueAsDouble(),
                       let ip = item.element(forName: "ip")?.stringValue,
                       let lastAuth = item.element(forName: "last-auth")?
                        .stringValueAsDouble() {
                        let device = item.element(forName: "info")?.stringValue ?? ""
                        let omemoId = item.element(forName: "omemo-id")?.stringValueAsNSInteger()
                        let descr = item.element(forName: "description")?.stringValue
                        
                        if let notification = notificationInstances.first(where: { $0.metadata?["deviceId"] as? String == uid }) {
                            var metadata = notification.metadata
                            metadata?["ip"] = ip
                            metadata?["client"] = client
                            metadata?["device"] = device
                            notification.metadata = metadata
                            notification.shouldShow = true
                        }
                        if let instance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: [uid, self.owner].prp()) {
                            instance.client = client
                            instance.device = device
                            instance.descr = descr ?? ""
                            instance.ip = ip
                            instance.omemoDeviceId = omemoId ?? -1
                            instance.expire = Date(timeIntervalSince1970: TimeInterval(expire))
                            instance.authDate = Date(timeIntervalSince1970: TimeInterval(lastAuth))
                        } else {
                            let instance = DeviceStorageItem()
                            instance.configure(
                                for: self.owner,
                                uid: uid,
                                ip: ip,
                                client: client,
                                device: device,
                                expire: expire,
                                authDate: lastAuth,
                                descr: descr ?? ""
                            )
                            instance.omemoDeviceId = omemoId ?? -1
                            realm.add(instance)
                        }
                    }
                }
                realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)?.isDevicesListReceived = true
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
    private func registrationText(_ name: String, in device: DDXMLElement) -> String? {
        let elements = (device.children ?? []).compactMap { $0 as? DDXMLElement }
            .filter { $0.localName == name }
        guard elements.count == 1, let element = elements.first,
              element.uri == getPrimaryNamespace(),
              !(element.children ?? []).contains(where: { $0 is DDXMLElement }),
              let text = element.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    internal func acceptDeviceRegistration(_ iq: XMPPIQ, on stream: XMPPStream,
        authenticationGeneration: UInt64) -> Bool {
        readRegisterDevice(iq, on: stream, authenticationGeneration: authenticationGeneration)
    }

    private final func readRegisterDevice(_ iq: XMPPIQ, on incomingStream: XMPPStream? = nil,
        authenticationGeneration: UInt64? = nil) -> Bool {
        guard let elementId = iq.elementID, iq.iqType == .result || iq.iqType == .error,
              let ownerJID = XMPPJID(string: owner) else { return false }
        sessionLock.lock()
        let matching = sessionContexts.values.first {
            $0.registrationRequestID == elementId && $0.registrationAttempt == $0.attempt
        }
        guard let context = matching, let stream = context.stream,
              incomingStream === stream, !context.boundAuthenticationCompleted,
              authenticationGeneration == nil || context.attempt == authenticationGeneration,
              !stream.isDisconnected, stream.myJID?.bare == ownerJID.bare else {
            sessionLock.unlock()
            return false
        }
        guard iq.localName == "iq", [nil, "", "jabber:client"].contains(iq.uri),
              iq.from?.full == ownerJID.bare,
              isOwnerServerReply(iq, recipient: context.registrationRecipient) else {
            sessionLock.unlock()
            return false
        }
        if iq.iqType == .error {
            _ = clearRegistration(context)
            sessionLock.unlock()
            queryIds.remove(elementId)
            return true
        }
        let payloads = (iq.children ?? []).compactMap { $0 as? DDXMLElement }
        guard payloads.count == 1, let device = payloads.first,
              device.localName == "device", device.uri == getPrimaryNamespace(),
              let deviceId = device.attributeStringValue(forName: "id"), Self.isValidOpaqueDeviceID(deviceId),
              let secret = registrationText("secret", in: device),
              let validationKey = registrationText("validation-key", in: device),
              let rawExpire = registrationText("expire", in: device),
              let expire = Double(rawExpire), expire.isFinite else {
            sessionLock.unlock()
            return false
        }
        context.registeredDeviceID = deviceId
        context.registrationRequestID = nil
        sessionLock.unlock()
        queryIds.remove(elementId)
//        print(self.deviceId, deviceId)
        self.deviceId = deviceId
        CredentialsManager.shared.setXabberDeviceId(for: owner, deviceId: deviceId)
        CredentialsManager.shared.setItem(for: owner, validationKey: validationKey, secret: secret)
        let deviceInfo = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
        let clientInfo = CommonConfigManager.shared.config.app_name
        let descr = UIDevice.current.name
        let instance = DeviceStorageItem()
        instance.configure(
            for: owner,
            uid: deviceId,
            ip: "",
            client: clientInfo,
            device: deviceInfo,
            expire: expire,
            authDate: Date().timeIntervalSince1970,
            descr: descr
        )
        if let omemoDeviceId = CredentialsManager.shared.getDeviceId(for: self.owner) {
            instance.omemoDeviceId = omemoDeviceId
        }
        do {
            let realm = try WRealm.safe()
            
            if let oldInstance = realm.object(ofType: DeviceStorageItem.self, forPrimaryKey: instance.primary) {
                try realm.write {
                    realm.delete(oldInstance)
                }
            }
            
            try realm.write {
                realm.add(instance)
            }
            if let account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner) {
                try realm.write {
                    account.deviceUuid = deviceId
                    account.xTokenUID = deviceId
                    account.xTokenSupport = true
                }
            }
        } catch {
            DDLogDebug("XTokenManager: \(#function). \(error.localizedDescription)")
        }
        
        return true
    }
    
}
