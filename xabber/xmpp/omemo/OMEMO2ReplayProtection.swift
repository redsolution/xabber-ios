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

    /// Reuses local authentication only for the same saved ordinary message.
    /// Transport IDs and XML success flags cannot select another row. This never
    /// decrypts, creates a message, changes content/trust, or grants archive coverage.
    static func authenticatedArchiveHistoryMessage(
        for message: XMPPMessage, owner: String, localDeviceID: Int, in realm: Realm
    ) -> MessageStorageItem? {
        guard isArchivedMessage(message), message.from?.bare == owner,
              message.to?.bare == owner,
              getMAMQueryId(message)?.isNotEmpty == true,
              getMAMResultID(message)?.isNotEmpty == true,
              let path = try? OmemoManager.incomingPath(message, owner: owner),
              let rawLeaf = path.last else { return nil }
        let leaf = XMPPMessage(from: rawLeaf)
        guard ["chat", "normal"].contains(leaf.type ?? "chat"),
              let sender = leaf.from?.bare, let recipient = leaf.to?.bare,
              sender == owner || recipient == owner,
              let fingerprint = Self.fingerprint(for: message, owner: owner, localDeviceID: localDeviceID),
              let encrypted = SCEReceivePolicy.children(of: leaf, named: "encrypted", xmlns: OmemoManager.xmlns).first,
              SCEReceivePolicy.children(of: encrypted, named: "payload", xmlns: OmemoManager.xmlns).count == 1,
              let header = SCEReceivePolicy.children(of: encrypted, named: "header", xmlns: OmemoManager.xmlns).first,
              let sid = header.attributeStringValue(forName: "sid").flatMap(Int.init)
        else { return nil }
        let proofs = realm.objects(MessageStanzaStorageItem.self)
            .filter("owner == %@ AND omemo2ReplayFingerprint == %@", owner, fingerprint)
        guard proofs.count == 1, let proof = proofs.first, proof.primary.hasSuffix("_stanza"),
              let savedXML = try? XMPPMessage(xmlString: proof.stanza),
              Self.fingerprint(for: savedXML, owner: owner, localDeviceID: localDeviceID) == fingerprint,
              let savedPath = try? OmemoManager.incomingPath(savedXML, owner: owner),
              let savedRawLeaf = savedPath.last else { return nil }
        let savedLeaf = XMPPMessage(from: savedRawLeaf)
        let primary = String(proof.primary.dropLast("_stanza".count))
        let peer = sender == owner ? recipient : sender
        guard let row = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary),
              row.owner == owner, row.opponent == peer, row.conversationType == .omemo,
              row.outgoing == (sender == owner), !row.isDeleted, !row.isLocallyHiddenByReport,
              row.primary == MessageStorageItem.genPrimary(messageId: row.messageId, owner: owner),
              proof.messageId == row.messageId,
              getUniqueMessageId(leaf, owner: owner) == row.messageId,
              getUniqueMessageId(savedLeaf, owner: owner) == row.messageId,
              leaf.elementID == savedLeaf.elementID,
              let auth = row.systemMetadata?["omemo_authenticated_sender_v1"] as? [String: Any],
              auth["owner"] as? String == owner, auth["jid"] as? String == sender,
              auth["deviceID"] as? Int == sid, auth["trusted"] is Bool,
              let identity = auth["fingerprint"] as? String,
              identity.replacingOccurrences(of: " ", with: "").count == 64,
              identity.replacingOccurrences(of: " ", with: "").range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
        else { return nil }
        return row
    }

    static func hasVerifiedHistory(fingerprint: Data, owner: String) -> Bool {
        guard fingerprint.count == 32, let realm = try? WRealm.safe(),
              MessageStanzaStorageItem().objectSchema.properties.contains(where: { $0.name == "omemo2ReplayFingerprint" }) else { return false }
        return !realm.objects(MessageStanzaStorageItem.self)
            .filter("owner == %@ AND omemo2ReplayFingerprint == %@", owner, fingerprint).isEmpty
    }
}
