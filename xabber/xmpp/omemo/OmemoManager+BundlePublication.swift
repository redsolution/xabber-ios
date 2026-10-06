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
import SignalProtocolObjC
import RealmSwift
import Network

extension OmemoManager {

    internal var isOwnOMEMOEnabled: Bool {
        (try? WRealm.safe()).flatMap { $0.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)?.isEncryptionEnabled } ?? false
    }

    private var isOwnOMEMOExplicitlyDisabled: Bool {
        (try? WRealm.safe()).flatMap { $0.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)?.isEncryptionEnabled } == false
    }
    
    internal final func createNode(_ xmppStream: XMPPStream, node: OmemoManager.NodeType) {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let create = DDXMLElement(name: "create")
        create.addAttribute(withName: "node", stringValue: node.rawValue)
        pubsub.addChild(create)
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: pubsub))
        self.queryIds.insert(elementId)
    }
    
    @discardableResult
    internal final func configureNode(_ xmppStream: XMPPStream, node: OmemoManager.NodeType) -> String {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub#owner")
        let configure = DDXMLElement(name: "configure")
        configure.addAttribute(withName: "node", stringValue: node.rawValue)
        let x = DDXMLElement(name: "x", xmlns: "jabber:x:data")
        x.addAttribute(withName: "type", stringValue: "submit")
        let form: [[String: String]] = [
            [
                "var": "FORM_TYPE",
                "type": "hidden",
                "value": "http://jabber.org/protocol/pubsub#node_config"
            ],
            [
                "var": "pubsub#access_model",
                "value": "open"
            ],
            [
                "var": "pubsub#max_items",
                "value": node == .bundle ? "max" : ((node == .update || node == .device) ? "1" : "32")
            ]
        ]
        
        form.compactMap {
                dict -> DDXMLElement in
                let field = DDXMLElement(name: "field")
                
                if let varAttr = dict["var"] {
                    field.addAttribute(withName: "var", stringValue: varAttr)
                }
                if let typeAttr = dict["type"] {
                    field.addAttribute(withName: "type", stringValue: typeAttr)
                }
                if let value = dict["value"] {
                    let valueElement = DDXMLElement(name: "value", stringValue: value)
                    field.addChild(valueElement)
                }
                
                return field
            }.forEach { Field in
                x.addChild(Field)
            }
        configure.addChild(x)
        pubsub.addChild(configure)
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: pubsub))
        self.queryIds.insert(elementId)
        return elementId
    }
    
    internal final func sendOwnDeviceBundle(_ xmppStream: XMPPStream, createNode: Bool) throws {
        omemo2MaintenanceLock.lock()
        var enabledAttempt = false
        var queued = false
        defer {
            if enabledAttempt && !queued {
                shouldPublicate = true
                omemo2PublicationRetryAt = omemo2MaintenanceNow().addingTimeInterval(Self.omemo2PublicationRetryInterval)
            }
            scheduleOMEMO2PublicationMaintenance()
            omemo2MaintenanceLock.unlock()
        }
        guard isOwnOMEMOEnabled else { return }
        enabledAttempt = true
        self.omemo2MaintenancePublicationStream = xmppStream
        let realm = try WRealm.safe()
        guard OMEMO2DeviceListStorageItem.get(in: realm, owner: owner, jid: owner)?.isKnown == true else {
            getContactDevices(xmppStream, jid: owner, force: true)
            throw OMEMO2StorageError.stateUnavailable
        }
        guard let storage = self.omemo2Storage else { throw OmemoManagerError.sessionCreationFailed }
        let value = OMEMO2PublishedBundle(try storage.replenishPreKeys(minimumCount: 100))
        let pubsub = try OMEMO2BundleCodec.publication(value)
        if let signature = SignatureManager.shared.signatureElement,
           let certificate = SignatureManager.shared.certificate {
            var commonName: CFString?
            SecCertificateCopyCommonName(certificate, &commonName)
            if (commonName as String?) == self.owner,
               let bundle = pubsub.element(forName: "publish")?.element(forName: "item")?.element(forName: "bundle", xmlns: getPrimaryNamespace()),
               let detachedSignature = signature.copy() as? DDXMLElement {
                bundle.addChild(detachedSignature)
            }
        }
        guard let publicationXML = try OMEMO2BundleCodec.encode(value).compactXMLString else {
            throw OMEMO2BundleCodec.Error.invalidBundle
        }
        let publicationHash = Data(publicationXML.utf8).sha256Data
        let elementID = xmppStream.generateUUID
        self.omemo2BundlePublications[elementID] = publicationHash
        self.omemo2BundlePublicationStartedAt[elementID] = omemo2MaintenanceNow()
        self.omemo2MaintenancePublicationStream = xmppStream
        self.omemo2PublicationRetryAt = nil
        self.shouldPublicate = false
        self.queryIds.insert(elementID)
        queued = true
        let iq = XMPPIQ(iqType: .set, to: nil, elementID: elementID, child: pubsub)
        logOMEMO2BundleStanza(iq, jid: owner, source: "own-publication")
        xmppStream.send(iq)
    }

    /// PEP acceptance is the publication proof. A queued write alone cannot
    /// mark a bundle as public or suppress a later OPK replenishment.
    internal func onOMEMO2PublicationResult(_ iq: XMPPIQ) -> Bool {
        omemo2MaintenanceLock.lock()
        defer {
            scheduleOMEMO2PublicationMaintenance()
            omemo2MaintenanceLock.unlock()
        }
        guard let elementID = iq.elementID, iq.iqType == .result || iq.iqType == .error else { return false }
        if elementID == self.omemo2BundleConfigurationRequestID {
            self.omemo2BundleConfigurationRequestID = nil
            self.omemo2BundleConfigurationStartedAt = nil
            self.queryIds.remove(elementID)
            guard !isOwnOMEMOExplicitlyDisabled else { self.shouldPublicate = false; return true }
            if iq.iqType == .result {
                self.shouldPublicate = true
                self.omemo2PublicationRetryAt = nil
                retryOMEMO2BundlePublication()
            } else {
                self.shouldPublicate = true
                self.omemo2PublicationReconfigured = false
                self.omemo2PublicationRetryAt = omemo2MaintenanceNow().addingTimeInterval(Self.omemo2PublicationRetryInterval)
            }
            return true
        }
        guard let expectedHash = self.omemo2BundlePublications.removeValue(forKey: elementID) else { return false }
        logOMEMO2BundleStanza(iq, jid: owner, source: "own-publication-response")
        self.omemo2BundlePublicationStartedAt.removeValue(forKey: elementID)
        self.queryIds.remove(elementID)
        guard !isOwnOMEMOExplicitlyDisabled else { self.shouldPublicate = false; return true }
        guard iq.iqType == .result else {
            self.shouldPublicate = true
            self.omemo2PublicationRetryAt = omemo2MaintenanceNow().addingTimeInterval(Self.omemo2PublicationRetryInterval)
            if !self.omemo2PublicationReconfigured,
               iq.element(forName: "error")?.element(forName: "precondition-not-met", xmlns: "http://jabber.org/protocol/pubsub#errors") != nil {
                self.omemo2PublicationReconfigured = true
                if let stream = authenticatedOMEMO2PublicationStream() {
                    self.omemo2BundleConfigurationRequestID = configureNode(stream, node: .bundle)
                    self.omemo2BundleConfigurationStartedAt = omemo2MaintenanceNow()
                } else {
                    AccountManager.shared.find(for: self.owner)?.action { user, stream in
                        guard stream.isAuthenticated else { return }
                        user.omemo.omemo2MaintenanceLock.lock()
                        defer { user.omemo.omemo2MaintenanceLock.unlock() }
                        guard user.omemo.isOwnOMEMOEnabled,
                              user.omemo.omemo2PublicationReconfigured,
                              user.omemo.omemo2BundleConfigurationRequestID == nil else { return }
                        user.omemo.omemo2MaintenancePublicationStream = stream
                        user.omemo.omemo2BundleConfigurationRequestID = user.omemo.configureNode(stream, node: .bundle)
                        user.omemo.omemo2BundleConfigurationStartedAt = user.omemo.omemo2MaintenanceNow()
                        user.omemo.scheduleOMEMO2PublicationMaintenance()
                    }
                }
            }
            return true
        }
        do {
            guard let storage = self.omemo2Storage else { throw OmemoManagerError.sessionCreationFailed }
            let value = OMEMO2PublishedBundle(try storage.localBundle())
            guard let publicationXML = try OMEMO2BundleCodec.encode(value).compactXMLString else {
                throw OMEMO2BundleCodec.Error.invalidBundle
            }
            let currentHash = Data(publicationXML.utf8).sha256Data
            guard expectedHash == currentHash else {
                self.shouldPublicate = true
                self.omemo2PublicationRetryAt = nil
                return true
            }
            let realm = try WRealm.safe()
            try realm.write {
                realm.object(ofType: SignalIdentityStorageItem.self,
                             forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: owner, jid: owner, deviceId: value.deviceID))?.isPublicated = true
                realm.object(ofType: SignalDeviceStorageItem.self,
                             forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: owner, deviceId: value.deviceID))?.isPublicated = true
            }
            self.omemo2PublicationReconfigured = false
            self.shouldPublicate = false
            self.omemo2PublicationRetryAt = nil
            for requestID in self.omemo2BundlePublications.keys { self.queryIds.remove(requestID) }
            self.omemo2BundlePublications.removeAll()
            self.omemo2BundlePublicationStartedAt.removeAll()
        } catch {
            self.shouldPublicate = true
            self.omemo2PublicationRetryAt = omemo2MaintenanceNow().addingTimeInterval(Self.omemo2PublicationRetryInterval)
        }
        return true
    }

    /// The existing publication hash remains the acceptance proof. Deadlines
    /// only release abandoned IQs and authorize another attempt.
    internal func retryOMEMO2BundlePublication(on suppliedStream: XMPPStream? = nil) {
        omemo2MaintenanceLock.lock()
        defer {
            scheduleOMEMO2PublicationMaintenance()
            omemo2MaintenanceLock.unlock()
        }
        let time = omemo2MaintenanceNow()
        for (requestID, startedAt) in omemo2BundlePublicationStartedAt
        where time.timeIntervalSince(startedAt) >= Self.omemo2PublicationIQTimeout {
            omemo2BundlePublicationStartedAt.removeValue(forKey: requestID)
            omemo2BundlePublications.removeValue(forKey: requestID)
            queryIds.remove(requestID)
            shouldPublicate = true
            omemo2PublicationRetryAt = nil
        }
        if let requestID = omemo2BundleConfigurationRequestID,
           let startedAt = omemo2BundleConfigurationStartedAt,
           time.timeIntervalSince(startedAt) >= Self.omemo2PublicationIQTimeout {
            omemo2BundleConfigurationRequestID = nil
            omemo2BundleConfigurationStartedAt = nil
            omemo2PublicationReconfigured = false
            queryIds.remove(requestID)
            shouldPublicate = true
            omemo2PublicationRetryAt = nil
        }
        guard isOwnOMEMOEnabled else { return }
        if let suppliedStream, suppliedStream.isAuthenticated { omemo2MaintenancePublicationStream = suppliedStream }
        guard let stream = authenticatedOMEMO2PublicationStream(suppliedStream) else {
            if shouldPublicate {
                AccountManager.shared.find(for: owner)?.action { account, stream in
                    guard stream.isAuthenticated else { return }
                    account.omemo.retryOMEMO2BundlePublication(on: stream)
                }
            }
            return
        }
        guard shouldPublicate, omemo2BundleConfigurationRequestID == nil,
              omemo2PublicationRetryAt.map({ time >= $0 }) ?? true else { return }
        do {
            guard let storage = omemo2Storage else { throw OMEMO2StorageError.stateUnavailable }
            let value = OMEMO2PublishedBundle(try storage.localBundle())
            guard let xml = try OMEMO2BundleCodec.encode(value).compactXMLString else { throw OMEMO2BundleCodec.Error.invalidBundle }
            guard !omemo2BundlePublications.values.contains(Data(xml.utf8).sha256Data) else { return }
            try sendOwnDeviceBundle(stream, createNode: false)
        } catch {
            shouldPublicate = true
            omemo2PublicationRetryAt = time.addingTimeInterval(Self.omemo2PublicationRetryInterval)
            DDLogDebug("OMEMO2 bundle publication will be retried")
        }
    }

    /// One active retry/watchdog runs on the existing owner queue, including
    /// otherwise idle authenticated connections. No account or manager is kept
    /// alive by scheduled work; disabled/disconnected accounts stop scheduling.
    internal func scheduleOMEMO2PublicationMaintenance() {
        let time = omemo2MaintenanceNow()
        let pending = omemo2BundlePublicationStartedAt.values.map { $0.addingTimeInterval(Self.omemo2PublicationIQTimeout) }
        var deadlines = pending
        if let startedAt = omemo2BundleConfigurationStartedAt {
            deadlines.append(startedAt.addingTimeInterval(Self.omemo2PublicationIQTimeout))
        } else if shouldPublicate, let retryAt = omemo2PublicationRetryAt {
            deadlines.append(retryAt)
        }
        guard isOwnOMEMOEnabled,
              authenticatedOMEMO2PublicationStream() != nil,
              let deadline = deadlines.min() else {
            omemo2MaintenanceWorkItem?.cancel()
            omemo2MaintenanceWorkItem = nil
            omemo2MaintenanceWorkDeadline = nil
            omemo2MaintenanceWorkID = nil
            return
        }
        if let current = omemo2MaintenanceWorkDeadline, current <= deadline { return }
        omemo2MaintenanceWorkItem?.cancel()
        let workID = UUID()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.omemo2MaintenanceLock.lock()
            guard self.omemo2MaintenanceWorkID == workID else { self.omemo2MaintenanceLock.unlock(); return }
            self.omemo2MaintenanceWorkItem = nil
            self.omemo2MaintenanceWorkDeadline = nil
            self.omemo2MaintenanceWorkID = nil
            let stream = self.authenticatedOMEMO2PublicationStream()
            self.omemo2MaintenanceLock.unlock()
            self.performOMEMO2KeyMaintenance(stream)
        }
        omemo2MaintenanceWorkItem = work
        omemo2MaintenanceWorkDeadline = deadline
        omemo2MaintenanceWorkID = workID
        let delay = max(0, deadline.timeIntervalSince(time))
        if let scheduler = omemo2MaintenanceScheduler { scheduler(delay, work) }
        else if let account = AccountManager.shared.find(for: owner) {
            account.queue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            work.cancel()
            omemo2MaintenanceWorkItem = nil
            omemo2MaintenanceWorkDeadline = nil
            omemo2MaintenanceWorkID = nil
        }
    }

    private func authenticatedOMEMO2PublicationStream(_ supplied: XMPPStream? = nil) -> XMPPStream? {
        [supplied, omemo2MaintenancePublicationStream, omemo2RegistrationStream]
            .compactMap { $0 }.first { $0.isAuthenticated }
    }

    internal final func sendOwnDevice(_ xmppStream: XMPPStream, createNode: Bool, excludingIDs: Set<Int> = []) throws {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let realm = try WRealm.safe()
        guard let snapshot = OMEMO2DeviceListStorageItem.get(in: realm, owner: owner, jid: owner), snapshot.isKnown else {
            getContactDevices(xmppStream, jid: owner, force: true)
            throw OMEMO2StorageError.stateUnavailable
        }
        let received = try DDXMLElement(xmlString: snapshot.devicesXML)
        let receivedItem = DDXMLElement(name: "item", xmlns: OMEMO2DeviceListCodec.pubsub)
        receivedItem.addChild(received)
        let decoded = try OMEMO2DeviceListCodec.decode(receivedItem)
        guard Set(decoded.ids) == Set(snapshot.deviceIDs) else { throw OmemoManagerError.invalidEncryptedPayload }
        let isOmemoEnabled = isOwnOMEMOEnabled
        let localID = localStore.localDeviceId()
        let publish = DDXMLElement(name: "publish")
        publish.addAttribute(withName: "node", stringValue: "\(getPrimaryNamespace()):devices")
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "id", stringValue: "current")
        let devices = DDXMLElement(name: "devices", xmlns: getPrimaryNamespace())
        
        for device in decoded.devices {
            let id = device.attributeIntegerValue(forName: "id")
            guard !excludingIDs.contains(id), isOmemoEnabled || id != localID else { continue }
            // Copy received signed labels as well as IDs. Retained local identity
            // rows neither add members nor replace a neighbour's server metadata.
            devices.addChild(SCEReceivePolicy.canonicalElementCopy(device))
        }
        if isOmemoEnabled && localID > 0 && localID <= Int(Int32.max) && !excludingIDs.contains(localID) && !decoded.ids.contains(localID) {
            let local = DDXMLElement(name: "device", xmlns: getPrimaryNamespace())
            local.addAttribute(withName: "id", integerValue: localID)
            devices.addChild(local)
        }
        
        item.addChild(devices)
        publish.addChild(item)
        pubsub.addChild(publish)
        pubsub.addChild(OMEMO2BundleCodec.publishOptions(maxItems: "1"))
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: pubsub))
        self.queryIds.insert(elementId)
    }
    
    public final func sendRetractOwnDevice(_ xmppStream: XMPPStream) {
        guard localStore.localDeviceId() > 0 else { return }
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        let retract = DDXMLElement(name: "retract")
        retract.addAttribute(withName: "node", stringValue: NodeType.bundle.rawValue)
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "id", integerValue: Int(self.localStore.localDeviceId()))
        retract.addChild(item)
        pubsub.addChild(retract)
        let elementId = xmppStream.generateUUID
        xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: pubsub))
        self.queryIds.insert(elementId)
    }
    
    public final func updateMyDevice(_ stream: XMPPStream) {
        omemo2MaintenanceLock.lock()
        defer { omemo2MaintenanceLock.unlock() }
        omemo2RegistrationStream = stream
        self.shouldPublicate = true
        if localStore.localDeviceId() <= 0 {
            beginOMEMO2Registration(stream)
        } else if (try? WRealm.safe()).flatMap({ OMEMO2DeviceListStorageItem.get(in: $0, owner: owner, jid: owner)?.isKnown }) != true {
            getContactDevices(stream, jid: owner, force: true)
        } else {
            try? self.publicateOwnDevice(stream, createNode: true)
        }
    }
    
    public final func publicateOwnDevice(_ xmppStream: XMPPStream, createNode: Bool) throws {
        omemo2MaintenanceLock.lock()
        defer {
            scheduleOMEMO2PublicationMaintenance()
            omemo2MaintenanceLock.unlock()
        }
        guard localStore.localDeviceId() > 0 else { return }
        let realm = try WRealm.safe()
        guard OMEMO2DeviceListStorageItem.get(in: realm, owner: owner, jid: owner)?.isKnown == true else {
            getContactDevices(xmppStream, jid: owner, force: true)
            return
        }
        let enabled = isOwnOMEMOEnabled
        if createNode {
            self.createNode(xmppStream, node: .device)
            self.configureNode(xmppStream, node: .device)
            if enabled {
                self.createNode(xmppStream, node: .bundle)
                self.configureNode(xmppStream, node: .bundle)
            }
        }
        if enabled {
            try self.sendOwnDeviceBundle(xmppStream, createNode: createNode)
            try self.sendOwnDevice(xmppStream, createNode: createNode)
        } else {
            try self.sendOwnDevice(xmppStream, createNode: createNode)
            self.sendRetractOwnDevice(xmppStream)
            self.shouldPublicate = false
            self.omemo2PublicationRetryAt = nil
            for requestID in self.omemo2BundlePublications.keys { self.queryIds.remove(requestID) }
            self.omemo2BundlePublications.removeAll()
            self.omemo2BundlePublicationStartedAt.removeAll()
            if let requestID = self.omemo2BundleConfigurationRequestID { self.queryIds.remove(requestID) }
            self.omemo2BundleConfigurationRequestID = nil
            self.omemo2BundleConfigurationStartedAt = nil
            try realm.write {
                let id = localStore.localDeviceId()
                realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: owner, jid: owner, deviceId: id))?.isPublicated = false
                realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: owner, deviceId: id))?.isPublicated = false
            }
        }
    }
    
    public final func getOwnDevices(_ xmppStream: XMPPStream) {
        self.getContactDevices(xmppStream, jid: self.owner)
    }
}
