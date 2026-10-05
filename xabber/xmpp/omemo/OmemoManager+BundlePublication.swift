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
        guard isOwnOMEMOEnabled else { return }
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
        self.shouldPublicate = false
        self.queryIds.insert(elementID)
        xmppStream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementID, child: pubsub))
    }

    /// PEP acceptance is the publication proof. A queued write alone cannot
    /// mark a bundle as public or suppress a later OPK replenishment.
    internal func onOMEMO2PublicationResult(_ iq: XMPPIQ) -> Bool {
        guard let elementID = iq.elementID, iq.iqType == .result || iq.iqType == .error else { return false }
        if elementID == self.omemo2BundleConfigurationRequestID {
            self.omemo2BundleConfigurationRequestID = nil
            guard !isOwnOMEMOExplicitlyDisabled else { self.shouldPublicate = false; return true }
            if iq.iqType == .result {
                AccountManager.shared.find(for: self.owner)?.action { user, stream in
                    do { try user.omemo.sendOwnDeviceBundle(stream, createNode: false) }
                    catch { user.omemo.shouldPublicate = true }
                }
            } else {
                self.shouldPublicate = true
            }
            return true
        }
        guard let expectedHash = self.omemo2BundlePublications.removeValue(forKey: elementID) else { return false }
        guard !isOwnOMEMOExplicitlyDisabled else { self.shouldPublicate = false; return true }
        guard iq.iqType == .result else {
            self.shouldPublicate = true
            if !self.omemo2PublicationReconfigured,
               iq.element(forName: "error")?.element(forName: "precondition-not-met", xmlns: "http://jabber.org/protocol/pubsub#errors") != nil {
                self.omemo2PublicationReconfigured = true
                AccountManager.shared.find(for: self.owner)?.action { user, stream in
                    user.omemo.omemo2BundleConfigurationRequestID = user.omemo.configureNode(stream, node: .bundle)
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
        } catch {
            self.shouldPublicate = true
        }
        return true
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
