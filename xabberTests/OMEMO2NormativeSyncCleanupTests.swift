import Foundation
import RealmSwift
import XMPPFramework
import XCTest
@testable import xabber

/// A sync IQ is an actual receive batch: different peers can have selected
/// the same published OPK before either receives the client's empty reply.
final class OMEMO2NormativeSyncCleanupTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var deletionSessionCounts: [String: [Int]] = [:]

        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws {
            let next = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            if let previous = records[owner].flatMap({ try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }),
               let oldKeys = previous["preKeys"] as? [[String: Any]],
               let newKeys = next?["preKeys"] as? [[String: Any]] {
                let consumed = Set(oldKeys.filter { $0["consumed"] as? Bool == true }
                    .compactMap { ($0["id"] as? NSNumber)?.uint32Value })
                let retained = Set(newKeys.compactMap { ($0["id"] as? NSNumber)?.uint32Value })
                if !consumed.subtracting(retained).isEmpty {
                    deletionSessionCounts[owner, default: []].append((next?["sessions"] as? [String: Any])?.count ?? 0)
                }
            }
            records[owner] = data
        }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }

    private struct Fixture {
        let receiver: OmemoManager
        let storage: XabberOMEMO2Storage
        let memory: Memory
        let query: DDXMLElement
        let preKeyID: UInt32
    }
    private var originalRealm: Realm.Configuration!
    private var keeper: Realm?
    private var owners: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "N06-sync-\(UUID())")
        keeper = try WRealm.safe()
    }

    override func tearDown() {
        owners.forEach { CredentialsManager.shared.removeDeviceId(for: $0) }
        owners.removeAll()
        keeper = nil
        Realm.Configuration.defaultConfiguration = originalRealm
        super.tearDown()
    }

    func testSnapshotBatchDecryptsDifferentPeersWithTheSameOPKBeforePrivateKeyCleanup() throws {
        let f = try fixture()

        let previews = f.receiver.prepareSyncConversations(f.query, serverContext: .accountServer)

        XCTAssertEqual(previews.map(\.lastMessageEncryption), [.authenticatedSCE(profile: .omemo2), .authenticatedSCE(profile: .omemo2)])
        XCTAssertEqual(try previews.map(body), ["first peer", "second peer"])
        XCTAssertTrue(try f.storage.consumedPreKeyIDs().isEmpty)
        XCTAssertEqual(f.memory.deletionSessionCounts[f.receiver.owner], [2], "Delete the shared OPK only after both receive transactions finish")
    }

    func testSnapshotBatchTerminalPreservesAnAlreadyActiveCatchUpHold() throws {
        let f = try fixture()
        let chain = UUID()
        f.receiver.omemo2PreKeyCleanup.beginCatchUp(id: chain)

        let previews = f.receiver.prepareSyncConversations(f.query, serverContext: .accountServer)

        XCTAssertEqual(try previews.map(body), ["first peer", "second peer"])
        XCTAssertEqual(try f.storage.consumedPreKeyIDs(), [f.preKeyID])
        XCTAssertNil(f.memory.deletionSessionCounts[f.receiver.owner])
        f.receiver.omemo2PreKeyCleanup.finishCatchUp(id: chain)
        XCTAssertTrue(try f.storage.consumedPreKeyIDs().isEmpty)
        XCTAssertEqual(f.memory.deletionSessionCounts[f.receiver.owner], [2])
    }

    func testRejectedSecondPreviewDoesNotPersistAnotherSessionOrKeepTheBatchHold() throws {
        let f = try fixture()
        let conversation = try XCTUnwrap(f.query.elements(forName: "conversation").last)
        let payload = try XCTUnwrap(conversation.element(forName: "metadata")?
            .element(forName: "last-message")?.element(forName: "message", xmlns: "jabber:client")?
            .element(forName: "encrypted", xmlns: OmemoManager.xmlns)?
            .element(forName: "payload", xmlns: OmemoManager.xmlns))
        var bytes = try Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(payload.stringValue))
        bytes[0] ^= 1
        payload.stringValue = bytes.base64EncodedString()

        let previews = f.receiver.prepareSyncConversations(f.query, serverContext: .accountServer)

        XCTAssertEqual(previews.map(\.lastMessageEncryption), [.authenticatedSCE(profile: .omemo2), .failedOMEMO])
        XCTAssertEqual(try body(previews[0]), "first peer")
        XCTAssertNil(try body(previews[1]))
        XCTAssertTrue(try f.storage.consumedPreKeyIDs().isEmpty)
        XCTAssertEqual(f.memory.deletionSessionCounts[f.receiver.owner], [1])
    }

    private func fixture() throws -> Fixture {
        let token = UUID().uuidString.lowercased()
        let owner = "sync-recipient-\(token)@example.test"
        owners.append(owner)
        let memory = Memory()
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        let bundle = try storage.prepare(deviceID: 42, preKeyCount: 3)
        let preKey = try XCTUnwrap(bundle.preKeys.first)
        let selected = try OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey,
            signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature,
            preKey: preKey.publicKey, preKeyID: preKey.id)
        let receiver = OmemoManager(withOwner: owner)
        receiver.omemo2Storage = storage
        _ = try receiver.ensureOMEMO2Prepared(attemptPublication: false)
        var conversations: [String] = []
        for (index, text) in ["first peer", "second peer"].enumerated() {
            let senderOwner = "sync-sender-\(index)-\(token)@example.test"
            let senderID = 41 + index * 2
            let sender = try XabberOMEMO2Storage(owner: senderOwner, persistence: memory)
            _ = try sender.prepare(deviceID: senderID, preKeyCount: 3)
            try sender.initiateSession(jid: owner, deviceID: 42, bundle: selected)
            let envelope = "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>\(text)</body></content><rpad/><from jid='\(senderOwner)'/><to jid='\(owner)'/></envelope>"
            let payload = try Omemo2PayloadCodec.seal(Omemo2PayloadCodec.prepareOutgoingXML(envelope))
            let ciphertext = try sender.encrypt(payload.keyAndMAC, jid: owner, deviceID: 42)
            let message = "<message xmlns='jabber:client' from='\(senderOwner)/device' to='\(owner)/ios' id='\(UUID())' type='chat'><time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='\(Date().XMPPFormattedDate)'/><encrypted xmlns='urn:xmpp:omemo:2'><header sid='\(senderID)'><keys jid='\(owner)'><key rid='42' kex='true'>\(ciphertext.data.base64EncodedString())</key></keys></header><payload>\(payload.ciphertext.base64EncodedString())</payload></encrypted></message>"
            conversations.append("<conversation jid='\(senderOwner)' type='urn:xmpp:omemo:2'><metadata node='https://xabber.com/protocol/synchronization'><last-message>\(message)</last-message></metadata></conversation>")
        }
        let query = try DDXMLElement(xmlString: "<query xmlns='https://xabber.com/protocol/synchronization'>\(conversations.joined())</query>")
        return Fixture(receiver: receiver, storage: storage, memory: memory, query: query, preKeyID: preKey.id)
    }

    private func body(_ value: ClientSyncConversationValue) throws -> String? {
        let element = try XCTUnwrap(value.materializedElement())
        return element.element(forName: "metadata")?.element(forName: "last-message")?
            .element(forName: "message", xmlns: "jabber:client")?.element(forName: "body", xmlns: "jabber:client")?.stringValue
    }
}
