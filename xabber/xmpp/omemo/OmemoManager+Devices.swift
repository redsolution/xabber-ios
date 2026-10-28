import Foundation
import RealmSwift
import XMPPFramework

struct OMEMO2DeviceListRequest {
    let jid: String
    let eventRevision: String
    let stream: XMPPStream
}

extension OmemoManager {
    public func getContactDevices(_ stream: XMPPStream, jid: String, force: Bool = false) {
        if let account = AccountManager.shared.find(for: owner),
           account.xmppStream === stream,
           account.deferWorkUntilStartupSynchronizationCompletes(
            key: "omemo.devices.\(jid).\(force)",
            work: { user, currentStream in
                user.omemo.getContactDevices(currentStream, jid: jid, force: force)
            }
           ) { return }
        do {
            let realm = try WRealm.safe()
            let snapshot = OMEMO2DeviceListStorageItem.get(in: realm, owner: owner, jid: jid) ?? OMEMO2DeviceListStorageItem()
            if !force && snapshot.isKnown { return }
            let id = stream.generateUUID
            try realm.write {
                if snapshot.realm == nil {
                    snapshot.primary = OMEMO2DeviceListStorageItem.genPrimary(owner: owner, jid: jid)
                    snapshot.owner = owner; snapshot.jid = jid
                    realm.add(snapshot)
                }
                snapshot.pendingRequestID = id
                snapshot.requestEventRevision = snapshot.eventRevision
            }
            omemo2DeviceListRequests[id] = OMEMO2DeviceListRequest(jid: jid, eventRevision: snapshot.eventRevision, stream: stream)
            let pubsub = DDXMLElement(name: "pubsub", xmlns: OMEMO2DeviceListCodec.pubsub)
            let items = DDXMLElement(name: "items", xmlns: OMEMO2DeviceListCodec.pubsub)
            items.addAttribute(withName: "node", stringValue: NodeType.device.rawValue)
            items.addAttribute(withName: "max_items", stringValue: "1")
            pubsub.addChild(items)
            queryIds.append(id)
            stream.send(XMPPIQ(iqType: .get, to: jid == owner ? nil : XMPPJID(string: jid), elementID: id, child: pubsub))
        } catch { DDLogDebug("OMEMO2 device list request could not be recorded") }
    }

    /// Correlation, sender and current PEP revision are checked before projection.
    internal func onContactDeviceListReceive(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .result, let id = iq.elementID,
              let request = omemo2DeviceListRequests[id], validDeviceListSender(iq, request: request) else { return false }
        guard let pubsub = SCEReceivePolicy.children(of: iq, named: "pubsub", xmlns: OMEMO2DeviceListCodec.pubsub).only,
              let items = SCEReceivePolicy.children(of: pubsub, named: "items", xmlns: OMEMO2DeviceListCodec.pubsub).only,
              items.attributeStringValue(forName: "node") == NodeType.device.rawValue else { return false }
        do {
            let entries = SCEReceivePolicy.children(of: items, named: "item", xmlns: OMEMO2DeviceListCodec.pubsub)
            let decoded: OMEMO2DeviceListCodec.Decoded
            if entries.isEmpty { decoded = .init(element: OMEMO2DeviceListCodec.empty.element, devices: []) }
            else {
                guard entries.count == 1 else { return false }
                decoded = try OMEMO2DeviceListCodec.decode(entries[0])
            }
            guard try consumeDeviceListRequest(id, request: request) else { return true }
            return applyDeviceList(decoded, jid: request.jid, fromMessage: false, stream: request.stream)
        } catch { return true }
    }

    internal func onContactDeviceListErrorReceive(_ iq: XMPPIQ) -> Bool {
        guard iq.iqType == .error, let id = iq.elementID,
              let request = omemo2DeviceListRequests[id], validDeviceListSender(iq, request: request) else { return false }
        do {
            let errors = iq.children?.compactMap { $0 as? DDXMLElement }.filter { $0.localName == "error" && ["jabber:client", ""].contains($0.uri ?? "") } ?? []
            guard let error = errors.only else { return false }
            let notFound = !SCEReceivePolicy.children(of: error, named: "item-not-found", xmlns: "urn:ietf:params:xml:ns:xmpp-stanzas").isEmpty || error.attributeStringValue(forName: "code") == "404"
            guard try consumeDeviceListRequest(id, request: request) else { return true }
            if notFound { _ = applyDeviceList(OMEMO2DeviceListCodec.empty, jid: request.jid, fromMessage: false, stream: request.stream, createNode: true) }
            return true
        } catch { return true }
    }

    private func validDeviceListSender(_ iq: XMPPIQ, request: OMEMO2DeviceListRequest) -> Bool {
        if let from = iq.from?.bare { return from == request.jid }
        return request.jid == owner
    }

    private func consumeDeviceListRequest(_ id: String, request: OMEMO2DeviceListRequest) throws -> Bool {
        let realm = try WRealm.safe()
        let snapshot = OMEMO2DeviceListStorageItem.get(in: realm, owner: owner, jid: request.jid)
        let current = snapshot?.pendingRequestID == id && snapshot?.eventRevision == request.eventRevision
        omemo2DeviceListRequests.removeValue(forKey: id); queryIds.remove(id)
        if snapshot?.pendingRequestID == id { try realm.write { snapshot?.pendingRequestID = nil } }
        return current
    }

    public func onContactDeviceListReceiveHeadline(_ message: XMPPMessage) -> Bool {
        guard let jid = message.from?.bare,
              let event = SCEReceivePolicy.children(of: message, named: "event", xmlns: OMEMO2DeviceListCodec.event).only else { return false }
        let removals = ["purge", "delete"].flatMap { SCEReceivePolicy.children(of: event, named: $0, xmlns: OMEMO2DeviceListCodec.event) }
            .filter { $0.attributeStringValue(forName: "node") == NodeType.device.rawValue }
        if removals.count == 1 { return applyDeviceList(OMEMO2DeviceListCodec.empty, jid: jid, fromMessage: true) }
        guard let items = SCEReceivePolicy.children(of: event, named: "items", xmlns: OMEMO2DeviceListCodec.event).only,
              items.attributeStringValue(forName: "node") == NodeType.device.rawValue else { return false }
        let entries = SCEReceivePolicy.children(of: items, named: "item", xmlns: OMEMO2DeviceListCodec.event)
        let retracts = SCEReceivePolicy.children(of: items, named: "retract", xmlns: OMEMO2DeviceListCodec.event)
        if entries.isEmpty && retracts.contains(where: { $0.attributeStringValue(forName: "id") == (try? WRealm.safe()).flatMap { OMEMO2DeviceListStorageItem.get(in: $0, owner: owner, jid: jid)?.itemID } }) {
            return applyDeviceList(OMEMO2DeviceListCodec.empty, jid: jid, fromMessage: true)
        }
        guard entries.count == 1, retracts.isEmpty else { return true }
        return onContactDeviceListReceiveItem(entries[0], jid: jid, fromMessage: true)
    }

    internal func onContactDeviceListReceiveItem(_ item: DDXMLElement, jid: String, fromMessage: Bool = false) -> Bool {
        do { return applyDeviceList(try OMEMO2DeviceListCodec.decode(item), jid: jid, fromMessage: fromMessage) }
        catch { return true } // Malformed publication cannot replace a known snapshot.
    }

    @discardableResult
    private func applyDeviceList(_ decoded: OMEMO2DeviceListCodec.Decoded, jid: String, fromMessage: Bool,
                                 stream: XMPPStream? = nil, createNode: Bool = false) -> Bool {
        do {
            let realm = try WRealm.safe()
            let snapshot = OMEMO2DeviceListStorageItem.get(in: realm, owner: owner, jid: jid) ?? OMEMO2DeviceListStorageItem()
            let ids = Set(decoded.ids)
            let oldDevices = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", owner, jid)
            let xabberDevices = realm.objects(DeviceStorageItem.self).filter("owner == %@", owner)
            try realm.write {
                if snapshot.realm == nil {
                    snapshot.primary = OMEMO2DeviceListStorageItem.genPrimary(owner: owner, jid: jid)
                    snapshot.owner = owner; snapshot.jid = jid; realm.add(snapshot)
                }
                snapshot.deviceIDs.removeAll(); snapshot.deviceIDs.append(objectsIn: decoded.ids)
                snapshot.devicesXML = decoded.element.xmlString; snapshot.itemID = decoded.itemID; snapshot.isKnown = true
                if fromMessage { snapshot.eventRevision = UUID().uuidString }
                oldDevices.forEach { $0.isInDeviceList = ids.contains($0.deviceId) }
                for xml in decoded.devices {
                    let id = xml.attributeIntegerValue(forName: "id")
                    let primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: id)
                    let device = realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary) ?? SignalDeviceStorageItem()
                    if device.realm == nil {
                        device.primary = primary; device.owner = owner; device.jid = jid; device.deviceId = id
                        realm.add(device)
                    }
                    // A label is displayable only with an authenticated cached identity.
                    if !(jid == owner && id == localStore.localDeviceId()) {
                        var label: String?
                        if let value = xml.attributeStringValue(forName: "label"), let encoded = xml.attributeStringValue(forName: "labelsig"),
                           let signature = try? Omemo2PayloadCodec.decodeBase64(encoded),
                           let identity = realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: primary), identity.protocolProfile == Self.xmlns,
                           let encodedKey = identity.identityKey, let key = try? Omemo2PayloadCodec.decodeBase64(encodedKey),
                           Omemo2IdentityRepresentation.verify(signature, data: Data(value.utf8), storedIdentity: key) { label = value }
                        device.name = label
                    }
                    device.isInDeviceList = true; device.freshlyUpdated = true
                }
                if jid == owner {
                    for d in oldDevices {
                        xabberDevices.first(where: { $0.uid.contains("\(d.deviceId)") })?.isEncryptionEnabled = d.isInDeviceList
                    }
                    let account = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner)
                    account?.isOmemoDevicesListReceived = true; account?.encryptionUpdatedTS = Date().timeIntervalSince1970
                } else {
                    let roster = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: jid, owner: owner))
                    roster?.isOmemoDevicesListReceived = true
                    roster?.encryptionUpdatedTS = Date().timeIntervalSince1970
                }
            }
            resumeMissingOMEMO2Sessions(afterDeviceList: jid)
            for id in decoded.ids {
                AccountManager.shared.find(for: owner)?.action { user, stream in user.omemo.getContactBundle(stream, jid: jid, deviceId: id, force: self.isRefreshRequest) }
            }
            isRefreshRequest = false
            if jid == owner {
                onOwnDeviceListUpdated(stream, createNode: createNode)
            }
            return true
        } catch { DDLogDebug("OMEMO2 devices snapshot could not be stored"); return true }
    }

    internal func onOwnDeviceListUpdated(_ stream: XMPPStream?, createNode: Bool = false) {
        guard let stream = stream ?? omemo2RegistrationStream else {
            AccountManager.shared.find(for: owner)?.action { user, stream in user.omemo.onOwnDeviceListUpdated(stream, createNode: createNode) }
            return
        }
        do {
            let realm = try WRealm.safe()
            guard let snapshot = OMEMO2DeviceListStorageItem.get(in: realm, owner: owner, jid: owner), snapshot.isKnown else { return }
            if omemo2FreshRegistrationPending {
                guard isOwnOMEMOEnabled, let storage = omemo2Storage else { return }
                let existing = Set(snapshot.deviceIDs)
                var freeID: Int?
                for _ in 0..<256 {
                    let candidate = omemo2FreshDeviceIDGenerator?() ?? Int(arc4random_uniform(UInt32(Int32.max)) + 1)
                    guard candidate > 0, candidate <= Int(Int32.max) else { throw OMEMO2StorageError.invalidDeviceID }
                    if !existing.contains(candidate) { freeID = candidate; break }
                }
                guard let id = freeID else { throw OMEMO2StorageError.invalidDeviceID }
                // The protected aggregate is the first local identity write.
                // Its existence after restart proves this collision check completed.
                _ = try storage.prepare(deviceID: id)
                omemo2FreshRegistrationPending = false
                configureLocal(stream, for: id)
                return
            }
            let localID = localStore.localDeviceId()
            guard localID > 0 else { return }
            if shouldPublicate {
                try publicateOwnDevice(stream, createNode: createNode)
            } else if isOwnOMEMOEnabled && !snapshot.deviceIDs.contains(localID) {
                try sendOwnDevice(stream, createNode: false)
            } else if !isOwnOMEMOEnabled && snapshot.deviceIDs.contains(localID) {
                try publicateOwnDevice(stream, createNode: createNode)
            }
        } catch { DDLogDebug("OMEMO2 own device registration could not be completed") }
    }

    internal func requestMissingDeviceLists(jid: String) {
        guard let realm = try? WRealm.safe() else { return }
        for target in Set([owner, jid]) {
            let list = OMEMO2DeviceListStorageItem.get(in: realm, owner: owner, jid: target)
            guard list?.isKnown != true, !hasLiveDeviceListRequest(list) else { continue }
            if let request = omemo2DeviceListRequester { request(target) }
            else { AccountManager.shared.find(for: owner)?.action { user, stream in user.omemo.getContactDevices(stream, jid: target, force: true) } }
        }
    }

    internal func refreshDevicesForUnknownSender(jid: String, deviceID: Int) {
        guard let realm = try? WRealm.safe(),
              !OMEMO2DeviceListStorageItem.contains(in: realm, owner: owner, jid: jid, deviceID: deviceID),
              !hasLiveDeviceListRequest(OMEMO2DeviceListStorageItem.get(in: realm, owner: owner, jid: jid)) else { return }
        if let request = omemo2DeviceListRequester { request(jid) }
        else { AccountManager.shared.find(for: owner)?.action { user, stream in user.omemo.getContactDevices(stream, jid: jid, force: true) } }
    }

    private func hasLiveDeviceListRequest(_ snapshot: OMEMO2DeviceListStorageItem?) -> Bool {
        guard let snapshot, let id = snapshot.pendingRequestID,
              let request = omemo2DeviceListRequests[id] else { return false }
        // Realm outlives the manager. A persisted token alone cannot represent
        // an IQ that can still be correlated after process restart.
        return request.jid == snapshot.jid
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
