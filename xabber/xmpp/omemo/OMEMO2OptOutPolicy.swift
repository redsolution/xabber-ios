import Foundation
import RealmSwift
import XMPPFramework

/// Protected account state is authoritative; this policy's Realm object is
/// only a presentation projection and never grants permission to send.
enum OMEMO2OptOutPolicy {
    enum Decision: String, Codable {
        case none, pending, plaintext, omemo
    }

    static func decision(owner: String, jid: String, realm: Realm,
                         storage: XabberOMEMO2Storage? = nil) throws -> Decision {
        let owner = try bareJID(owner)
        let peer = try bareJID(jid)
        return try source(owner: owner, storage: storage).optOutDecision(jid: peer)
    }

    static func projectedDecision(owner: String, jid: String, realm: Realm) -> Decision {
        guard let owner = try? bareJID(owner), let peer = try? bareJID(jid) else { return .none }
        return realm.object(ofType: OMEMO2OptOutStorageItem.self,
                            forPrimaryKey: OMEMO2OptOutStorageItem.genPrimary(owner: owner, jid: peer))?.decision ?? .none
    }

    static func resolve(owner: String, jid: String, decision: Decision, at: Date,
                        realm: Realm, storage: XabberOMEMO2Storage? = nil) throws {
        let owner = try bareJID(owner)
        let peer = try bareJID(jid)
        let source = try source(owner: owner, storage: storage)
        try source.resolveOptOut(jid: peer, decision: decision, at: at)
        // The protected write has already committed. A UI projection failure
        // cannot roll it back; preparation and later receive retry the mirror.
        do { try mirror(source, in: realm) }
        catch { DDLogDebug("OMEMO2 opt-out projection will be retried") }
    }

    static func allowsOutgoing(_ stanza: DDXMLElement, owner: String, realm: Realm,
                               storage: XabberOMEMO2Storage? = nil) -> Bool {
        allowsOutgoing(stanza, owner: owner, storage: storage)
    }

    static func allowsOutgoing(_ stanza: DDXMLElement, owner: String,
                               storage: XabberOMEMO2Storage? = nil) -> Bool {
        let recipients = outgoingRecipients(stanza)
        return recipients.allSatisfy { allowsMessage(owner: owner, jid: $0, storage: storage) }
    }

    static func allowsMessage(owner: String, jid: String,
                              storage: XabberOMEMO2Storage? = nil) -> Bool {
        do {
            let owner = try bareJID(owner), peer = try bareJID(jid)
            if let storage, storage.owner != owner { throw OMEMO2StorageError.invalidState }
            if peer == owner { return true }
            return try source(owner: owner, storage: storage).optOutDecision(jid: peer) != .pending
        } catch { return false }
    }

    static func requireAllowedMessage(owner: String, jid: String,
                                      storage: XabberOMEMO2Storage? = nil) throws {
        let owner = try bareJID(owner), peer = try bareJID(jid)
        if let storage, storage.owner != owner { throw OMEMO2StorageError.invalidState }
        if peer == owner { return }
        guard try source(owner: owner, storage: storage).optOutDecision(jid: peer) != .pending else {
            throw OMEMO2StorageError.pendingOptOut
        }
    }

    static func bareJID(_ jid: String) throws -> String {
        guard let parsed = XMPPJID(string: jid), !parsed.bare.isEmpty else {
            throw OMEMO2StorageError.invalidState
        }
        return parsed.bare
    }

    private static func source(owner: String, storage: XabberOMEMO2Storage?) throws -> XabberOMEMO2Storage {
        let result: XabberOMEMO2Storage
        if let storage { result = storage }
        else if let existing = AccountManager.shared.find(for: owner)?.omemo.omemo2Storage { result = existing }
        else { result = try XabberOMEMO2Storage(owner: owner) }
        guard result.owner == owner else { throw OMEMO2StorageError.invalidState }
        return result
    }

    static func mirror(_ storage: XabberOMEMO2Storage, in realm: Realm) throws {
        let records = try storage.optOutRecords()
        let existing = realm.objects(OMEMO2OptOutStorageItem.self).filter("owner == %@", storage.owner)
        let desired = Set(records.map { OMEMO2OptOutStorageItem.genPrimary(owner: storage.owner, jid: $0.jid) })
        let obsolete = existing.filter { !desired.contains($0.primary) }
        let changed = records.filter { record in
            guard let item = realm.object(ofType: OMEMO2OptOutStorageItem.self,
                forPrimaryKey: OMEMO2OptOutStorageItem.genPrimary(owner: storage.owner, jid: record.jid)) else { return true }
            return item.decisionRaw != record.decision.rawValue || item.reason != record.reason || item.updatedAt != record.updatedAt
        }
        guard !changed.isEmpty || !obsolete.isEmpty else { return }
        let apply = {
            realm.delete(obsolete)
            for record in changed {
                let primary = OMEMO2OptOutStorageItem.genPrimary(owner: storage.owner, jid: record.jid)
                let item = realm.object(ofType: OMEMO2OptOutStorageItem.self, forPrimaryKey: primary) ?? OMEMO2OptOutStorageItem()
                if item.realm == nil {
                    item.owner = storage.owner; item.jid = record.jid; item.primary = primary
                }
                item.decisionRaw = record.decision.rawValue; item.reason = record.reason; item.updatedAt = record.updatedAt
                realm.add(item, update: .modified)
            }
        }
        if realm.isInWriteTransaction { apply() } else { try realm.write { apply() } }
    }

    private static func outgoingRecipients(_ stanza: DDXMLElement) -> [String] {
        func children(_ parent: DDXMLElement, name: String, namespaces: [String]) -> [DDXMLElement] {
            (parent.children?.compactMap { $0 as? DDXMLElement } ?? []).filter {
                $0.localName == name && namespaces.contains($0.uri ?? "")
            }
        }
        func to(_ element: DDXMLElement) -> [String] {
            element.attributeStringValue(forName: "to").map { [$0] } ?? []
        }
        // One-shot queues contain generic DDXMLElement, not XMPPMessage.
        if stanza.localName == "message", ["", "jabber:client"].contains(stanza.uri ?? "") { return to(stanza) }
        guard stanza.localName == "iq", ["", "jabber:client"].contains(stanza.uri ?? "") else { return [] }
        var recipients: [String] = []
        let rewrite = "https://xabber.com/protocol/rewrite"
        for wrapper in children(stanza, name: "replace", namespaces: [rewrite]) {
            for message in children(wrapper, name: "message", namespaces: [rewrite, "jabber:client", ""]) {
                recipients.append(contentsOf: to(message))
            }
        }
        let schedule = "https://xabber.com/protocol/schedule"
        for wrapper in children(stanza, name: "schedule", namespaces: [schedule]) {
            if let conversation = wrapper.attributeStringValue(forName: "conversation") { recipients.append(conversation) }
            for message in children(wrapper, name: "message", namespaces: ["jabber:client", ""]) {
                recipients.append(contentsOf: to(message))
            }
        }
        for notify in children(stanza, name: "notify", namespaces: ["urn:xabber:xen:0"]) {
            for addresses in children(notify, name: "addresses", namespaces: ["http://jabber.org/protocol/address"]) {
                for address in children(addresses, name: "address", namespaces: ["http://jabber.org/protocol/address", ""]) {
                    if address.attributeStringValue(forName: "type") == "to", let jid = address.attributeStringValue(forName: "jid") {
                        recipients.append(jid)
                    }
                }
            }
            for notification in children(notify, name: "notification", namespaces: ["urn:xabber:xen:0", ""]) {
                for forwarded in children(notification, name: "forwarded", namespaces: ["urn:xmpp:forward:0"]) {
                    // Existing XEN builds a nil-URI inner message; its wire
                    // QName inherits forward:0. Both are server-accepted forms.
                    for message in children(forwarded, name: "message", namespaces: ["jabber:client", "urn:xmpp:forward:0", ""]) {
                        recipients.append(contentsOf: to(message))
                    }
                }
            }
        }
        return recipients
    }
}

struct OMEMO2OptOutRequest {
    let jid: String
    let fingerprint: Data
    let protectedDate: Date?
    let reason: String?
    let historical: Bool
}

struct OMEMO2OptOutRecord: Codable {
    let jid: String
    var decision: OMEMO2OptOutPolicy.Decision
    var requestFingerprint: Data
    var protectedRequestDate: Date?
    var reason: String?
    var resolvedWatermark: Date?
    var updatedAt: Date
}

final class OMEMO2OptOutStorageItem: Object {
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var primary: String = ""
    @objc dynamic var decisionRaw: String = OMEMO2OptOutPolicy.Decision.none.rawValue
    @objc dynamic var reason: String? = nil
    @objc dynamic var updatedAt: Date = Date(timeIntervalSince1970: 0)

    var decision: OMEMO2OptOutPolicy.Decision {
        OMEMO2OptOutPolicy.Decision(rawValue: decisionRaw) ?? .none
    }

    static func genPrimary(owner: String, jid: String) -> String {
        [owner, jid].prp()
    }

    override static func primaryKey() -> String? { "primary" }
}
