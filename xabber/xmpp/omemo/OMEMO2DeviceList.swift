import Foundation
import RealmSwift
import XMPPFramework

/// The current PEP membership is independent of retained identities and trust.
/// Unknown and a verified empty list have different sending semantics.
final class OMEMO2DeviceListStorageItem: Object {
    @objc dynamic var primary = ""
    @objc dynamic var owner = ""
    @objc dynamic var jid = ""
    @objc dynamic var isKnown = false
    let deviceIDs = List<Int>()
    @objc dynamic var devicesXML = ""
    @objc dynamic var itemID: String?
    @objc dynamic var eventRevision = ""
    @objc dynamic var pendingRequestID: String?
    @objc dynamic var requestEventRevision = ""

    override static func primaryKey() -> String? { "primary" }
    static func genPrimary(owner: String, jid: String) -> String { [owner, jid].prp() }
    static func get(in realm: Realm, owner: String, jid: String) -> OMEMO2DeviceListStorageItem? {
        realm.object(ofType: Self.self, forPrimaryKey: genPrimary(owner: owner, jid: jid))
    }
    static func contains(in realm: Realm, owner: String, jid: String, deviceID: Int) -> Bool {
        guard let list = get(in: realm, owner: owner, jid: jid), list.isKnown else { return false }
        return list.deviceIDs.contains(deviceID)
    }
}

enum OMEMO2DeviceListCodec {
    static let pubsub = "http://jabber.org/protocol/pubsub"
    static let event = "http://jabber.org/protocol/pubsub#event"
    struct Decoded {
        let element: DDXMLElement
        let devices: [DDXMLElement]
        var itemID: String? = nil
        var ids: [Int] { devices.map { $0.attributeIntegerValue(forName: "id") } }
    }
    static func decode(_ item: DDXMLElement) throws -> Decoded {
        let lists = SCEReceivePolicy.children(of: item, named: "devices", xmlns: OmemoManager.xmlns)
        guard lists.count == 1 else { throw OmemoManagerError.invalidEncryptedPayload }
        let devices = SCEReceivePolicy.children(of: lists[0], named: "device", xmlns: OmemoManager.xmlns)
        let ids = try devices.map { Int(try OMEMO2BundleCodec.keyID($0.attributeStringValue(forName: "id"))) }
        guard Set(ids).count == ids.count else { throw OMEMO2BundleCodec.Error.invalidKeyID }
        // Do not republish foreign elements when merging our own list later.
        let canonical = DDXMLElement(name: "devices", xmlns: OmemoManager.xmlns)
        devices.forEach { canonical.addChild(SCEReceivePolicy.canonicalElementCopy($0)) }
        return Decoded(element: canonical, devices: devices, itemID: item.attributeStringValue(forName: "id"))
    }
    static var empty: Decoded { Decoded(element: DDXMLElement(name: "devices", xmlns: OmemoManager.xmlns), devices: []) }
}
