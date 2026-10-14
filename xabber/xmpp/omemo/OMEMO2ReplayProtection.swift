import CryptoKit
import Foundation
import RealmSwift
import XMPPFramework
import XabberCryptoSwift

/// Local evidence of an authenticated packet, never a transport ID or XML
/// success flag. Length framing also distinguishes absent and empty payloads.
enum OMEMO2ReplayProtection {
    static func fingerprint(for message: DDXMLElement, owner: String, localDeviceID: Int) -> Data? {
        guard let path = try? OmemoManager.incomingPath(message, owner: owner),
              let leaf = path.last,
              let from = leaf.attributeStringValue(forName: "from").flatMap({ XMPPJID(string: $0)?.bare }) else { return nil }
        func children(_ element: DDXMLElement, _ name: String) -> [DDXMLElement] {
            SCEReceivePolicy.children(of: element, named: name, xmlns: OmemoManager.xmlns)
        }
        let encrypted = children(leaf, "encrypted")
        guard encrypted.count == 1 else { return nil }
        let headers = children(encrypted[0], "header")
        guard headers.count == 1,
              let sid = try? OMEMO2BundleCodec.keyID(headers[0].attributeStringValue(forName: "sid")) else { return nil }
        let groups = children(headers[0], "keys").filter { $0.attributeStringValue(forName: "jid") == owner }
        guard groups.count == 1 else { return nil }
        let keys = children(groups[0], "key").filter { $0.attributeStringValue(forName: "rid") == String(localDeviceID) }
        guard keys.count == 1, let encoded = keys[0].stringValue,
              let key = try? Omemo2PayloadCodec.decodeBase64(encoded), key.first != 0x33 else { return nil }
        let kex = keys[0].attributeStringValue(forName: "kex")
        guard kex == nil || ["true", "false", "1", "0"].contains(kex!) else { return nil }
        let keyExchange = kex == "true" || kex == "1"
        guard let envelope = try? OMEMOEnvelope(data: key, keyExchange: keyExchange) else { return nil }
        let replayKey: Data
        do {
            switch envelope {
            case .keyExchange(let exchange):
                // Only the unMAC-bound outer KEX encoding is normalized. Exact
                // IK/IDs and authenticated inner bytes/MAC remain in the proof.
                // This keeps aliases duplicate even after their snapshot is pruned.
                replayKey = try OMEMOKeyExchange(preKeyID: exchange.preKeyID,
                    signedPreKeyID: exchange.signedPreKeyID, identityKey: exchange.identityKey,
                    ephemeralKey: OMEMO2PublicKeyRepresentation.canonicalX25519(exchange.ephemeralKey),
                    message: exchange.message).serializedData()
            case .message(let authenticated):
                // serializedData preserves authenticated.message verbatim;
                // never decode/reserialize the MAC-covered inner ratchet bytes.
                replayKey = try authenticated.serializedData()
            }
        } catch { return nil }
        let payloads = children(encrypted[0], "payload")
        guard payloads.count <= 1 else { return nil }
        var payload: Data?
        if let element = payloads.first {
            guard let decoded = try? Omemo2PayloadCodec.decodeBase64(element.stringValue ?? "") else { return nil }
            payload = decoded
        }
        let recipient = leaf.attributeStringValue(forName: "to").flatMap { XMPPJID(string: $0)?.bare } ?? owner
        var framed = Data("XabberCryptoSwift OMEMO2 authenticated receive v2".utf8)
        for value in [Data(owner.utf8), Data(from.utf8), Data(String(sid).utf8), Data(recipient.utf8),
                      Data(String(localDeviceID).utf8), Data([leaf.attributeStringValue(forName: "type") == "groupchat" ? 1 : 0]),
                      Data([keyExchange ? 1 : 0]), replayKey, Data([payload == nil ? 0 : 1]), payload ?? Data()] {
            var length = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
            framed.append(value)
        }
        return Data(SHA256.hash(data: framed))
    }

    static func hasVerifiedHistory(fingerprint: Data, owner: String) -> Bool {
        guard fingerprint.count == 32, let realm = try? WRealm.safe(),
              MessageStanzaStorageItem().objectSchema.properties.contains(where: { $0.name == "omemo2ReplayFingerprint" }) else { return false }
        return !realm.objects(MessageStanzaStorageItem.self)
            .filter("owner == %@ AND omemo2ReplayFingerprint == %@", owner, fingerprint).isEmpty
    }
}
