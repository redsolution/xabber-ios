import Foundation
import RealmSwift
import XMPPFramework
import XCTest
@testable import xabber

/// The ciphertext cache alone is not authentication evidence. These tests use
/// the real receive decoder and persist its typed result beside the same XML.
final class OMEMO2NormativeReplayHistoryTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var loads = 0
        func load(owner: String) throws -> Data? { loads += 1; return records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }
    private struct Fixture {
        let manager: OmemoManager
        let sender: XabberOMEMO2Storage
        let account: Account
        let memory: Memory
        let wire: XMPPMessage
        let fingerprint: Data
    }
    private var originalRealm: Realm.Configuration!
    private var realmKeeper: Realm?
    private var originalUsers: [Account] = []
    private var accounts: [Account] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "N04-history-\(UUID())")
        realmKeeper = try WRealm.safe()
        originalUsers = AccountManager.shared.users
    }
    override func tearDown() {
        AccountManager.shared.users = originalUsers
        for account in accounts {
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
            CredentialsManager.shared.removeDeviceId(for: account.jid)
        }
        accounts.removeAll()
        realmKeeper = nil
        Realm.Configuration.defaultConfiguration = originalRealm
        super.tearDown()
    }

    func testVerifiedOMEMO2ReceiveStoresLocalReplayProofInExistingStanzaTransaction() throws {
        let f = try fixture()
        let item = try verifiedItem(f)
        let realm = try WRealm.safe()
        item.prepareIncomingReplayFingerprint()
        let protectedLoads = f.memory.loads

        try realm.write { item.storeStanza(in: realm) }

        XCTAssertEqual(f.memory.loads, protectedLoads, "Realm persistence must not acquire the protected storage lock")
        let saved = try savedStanza(item)
        XCTAssertEqual(try fingerprint(saved), f.fingerprint)
        XCTAssertTrue(OMEMO2ReplayProtection.hasVerifiedHistory(fingerprint: f.fingerprint, owner: f.manager.owner))
        XCTAssertFalse(OMEMO2ReplayProtection.hasVerifiedHistory(fingerprint: f.fingerprint, owner: "another@example.test"))
    }

    func testVerifiedOMEMO2ReceiveStoresLocalReplayProofThroughStandaloneStanzaStore() throws {
        let f = try fixture()
        let item = try verifiedItem(f)

        item.storeStanza()

        XCTAssertEqual(try fingerprint(savedStanza(item)), f.fingerprint)
    }

    func testRawCiphertextAndNetworkSuccessMarkersNeverGrantHistoryReplayProof() throws {
        let f = try fixture()
        let marker = DDXMLElement(name: "omemo-result__system")
        marker.addAttribute(withName: "success", stringValue: "true")
        f.wire.addChild(marker)
        for provenance in [MessageEncryptionProvenance.plaintext, .unverifiedOMEMO, .failedOMEMO, .authenticatedSCE(profile: .legacySignal)] {
            let item = rawItem(f)
            item.primary += "_\(UUID().uuidString)"
            item.incomingEncryption = provenance

            item.storeStanza()

            XCTAssertNil(try fingerprint(savedStanza(item)))
            XCTAssertFalse(OMEMO2ReplayProtection.hasVerifiedHistory(fingerprint: f.fingerprint, owner: f.manager.owner))
        }
    }

    func testAChangedCiphertextWithNoVerifiedProvenancePreservesPreviousLocalProofOnly() throws {
        let f = try fixture()
        let verified = try verifiedItem(f)
        verified.storeStanza()
        let realm = try WRealm.safe()
        let rewrite = rawItem(f)
        rewrite.primary = verified.primary
        let changed = try XMPPMessage(xmlString: f.wire.xmlString)
        let payload = try XCTUnwrap(changed.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?.element(forName: "payload", xmlns: OmemoManager.xmlns))
        payload.stringValue = Data(repeating: 0x45, count: 48).base64EncodedString()
        rewrite.originalStanza = changed
        rewrite.incomingEncryption = .unverifiedOMEMO
        let other = try XCTUnwrap(OMEMO2ReplayProtection.fingerprint(for: changed, owner: f.manager.owner, localDeviceID: 42))
        XCTAssertNotEqual(other, f.fingerprint)

        try realm.write { rewrite.storeStanza(in: realm) }

        XCTAssertEqual(try fingerprint(savedStanza(rewrite)), f.fingerprint)
        XCTAssertTrue(OMEMO2ReplayProtection.hasVerifiedHistory(fingerprint: f.fingerprint, owner: f.manager.owner))
        XCTAssertFalse(OMEMO2ReplayProtection.hasVerifiedHistory(fingerprint: other, owner: f.manager.owner))
    }

    func testStandaloneUnverifiedStoreDoesNotErasePreviouslyVerifiedProof() throws {
        let f = try fixture()
        let item = try verifiedItem(f)
        item.storeStanza()
        item.incomingEncryption = .failedOMEMO

        item.storeStanza()

        XCTAssertEqual(try fingerprint(savedStanza(item)), f.fingerprint)
    }

    func testStanzaStoreInsideActiveTransactionDoesNotPrepareProofOrReadProtectedStorage() throws {
        let f = try fixture()
        let item = try verifiedItem(f)
        let realm = try WRealm.safe()
        let protectedLoads = f.memory.loads

        try realm.write { item.storeStanza() }

        XCTAssertEqual(f.memory.loads, protectedLoads)
        XCTAssertNil(try fingerprint(savedStanza(item)))
    }

    func testVerifiedHistoryConsumesExactReplayAfterProtectedReceiptAndSessionAreRemoved() throws {
        let f = try fixture()
        try verifiedItem(f).storeStanza()
        try removeProtectedReplayState(f)

        guard case .consumed(.duplicate) = f.manager.prepareIncoming(f.wire) else {
            return XCTFail("Locally authenticated history must recognize the exact ciphertext without a ratchet")
        }
        XCTAssertFalse(try XCTUnwrap(f.manager.omemo2Storage).sessionExists(jid: f.wire.from!.bare, deviceID: 77))
    }

    func testChangedPayloadDoesNotUseVerifiedHistoryAfterProtectedReplayStateIsRemoved() throws {
        let f = try fixture()
        try verifiedItem(f).storeStanza()
        try removeProtectedReplayState(f)
        let before = f.memory.records[f.manager.owner]
        let changed = try XMPPMessage(xmlString: f.wire.xmlString)
        let payload = try XCTUnwrap(changed.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?.element(forName: "payload", xmlns: OmemoManager.xmlns))
        var bytes = try Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(payload.stringValue))
        bytes[0] ^= 1
        payload.stringValue = bytes.base64EncodedString()

        guard case .failed = f.manager.prepareIncoming(changed) else {
            return XCTFail("Changed ciphertext must not acquire replay authentication from history")
        }
        XCTAssertEqual(f.memory.records[f.manager.owner], before)
    }

    func testUnverifiedHistoryCannotConsumeTheFirstAuthenticatedReceive() throws {
        let f = try fixture()
        let raw = rawItem(f)
        raw.incomingEncryption = .unverifiedOMEMO
        raw.storeStanza()

        _ = try verifiedItem(f)

        XCTAssertNil(try fingerprint(savedStanza(raw)))
    }

    func testVerifiedExistingMessageMaterializationPersistsProofWithoutCreatingAnotherRow() throws {
        let f = try fixture()
        let old = rawItem(f)
        old.incomingEncryption = .failedOMEMO
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(old)
            old.storeStanza(in: realm)
        }
        let verified = try verifiedItem(f)

        f.account.messages.save([verified], silentNotifications: true)

        XCTAssertEqual(realm.objects(MessageStorageItem.self).filter("owner == %@", f.manager.owner).count, 1)
        XCTAssertEqual(try fingerprint(savedStanza(verified)), f.fingerprint)
    }

    func testVerifiedProvenanceWithoutTheActualLocalRecipientDoesNotCreateProof() throws {
        let f = try fixture()
        let item = rawItem(f)
        item.incomingEncryption = .authenticatedSCE(profile: .omemo2)
        let encrypted = try XCTUnwrap(f.wire.element(forName: "encrypted", xmlns: OmemoManager.xmlns))
        let key = try XCTUnwrap(encrypted.element(forName: "header", xmlns: OmemoManager.xmlns)?.element(forName: "keys", xmlns: OmemoManager.xmlns)?.element(forName: "key", xmlns: OmemoManager.xmlns))
        key.removeAttribute(forName: "rid")
        key.addAttribute(withName: "rid", integerValue: 99)
        XCTAssertNil(OMEMO2ReplayProtection.fingerprint(for: f.wire, owner: f.manager.owner, localDeviceID: 42))

        item.storeStanza()

        XCTAssertNil(try fingerprint(savedStanza(item)))
    }

    func testSchema23MigrationPreservesCiphertextWithoutInventingAuthenticatedProof() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("N04-history-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.realm")
        let xml = "<message xmlns='jabber:client' id='legacy'><encrypted xmlns='urn:xmpp:omemo:2'/><omemo-result__system success='true'/></message>"
        let date = Date(timeIntervalSince1970: 1_690_000_000)
        try autoreleasepool {
            let old = try Realm(configuration: .init(fileURL: url, schemaVersion: 23, objectTypes: [MessageStanzaStorageItem.self]))
            let row = MessageStanzaStorageItem()
            row.set("legacy", for: "owner@example.test", with: xml, at: date, primary: "message")
            try old.write { old.add(row) }
        }
        var configuration = makeRealmMigrationConfiguration(scheme: XabberRealmSchema.current)
        configuration.fileURL = url
        configuration.objectTypes = [MessageStanzaStorageItem.self]

        let migrated = try Realm(configuration: configuration)

        XCTAssertGreaterThanOrEqual(XabberRealmSchema.current, 24)
        let row = try XCTUnwrap(migrated.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: "message_stanza"))
        XCTAssertEqual(row.stanza, xml)
        XCTAssertEqual(row.owner, "owner@example.test")
        XCTAssertEqual(row.messageId, "legacy")
        XCTAssertEqual(row.timestamp, date)
        XCTAssertNil(try fingerprint(row))
    }

    func testArchiveIngressReusesDurableAuthenticatedPayloadWithoutRatchetAdvance() throws {
        let f = try fixture()
        f.account.messages.unsubscribeReceiver()
        let item = try verifiedItem(f)
        f.account.messages.save([item], silentNotifications: true)
        let realm = try WRealm.safe()
        let stored = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: item.primary))
        let body = stored.body, date = stored.date, sentDate = stored.sentDate
        let metadata = stored.systemMetadata as NSDictionary?
        let stanza = try savedStanza(stored).stanza
        let before = f.memory.records[f.manager.owner]

        let receipt = try archivedReplayReceipt(f)

        XCTAssertEqual(receipt.messagePrimaryIDs, [stored.primary], "An authenticated ordinary replay must remain in the verified archive window")
        XCTAssertEqual(receipt.persistedResultCount, 1)
        XCTAssertEqual(receipt.intentionallyConsumedResultCount, 0, "A payload replay is not a control packet")
        XCTAssertEqual(receipt.failedPersistenceCount, 0)
        try assertVerifiedArchiveWindow(receipt, fixture: f, expectedPrimary: stored.primary)
        realm.refresh()
        XCTAssertEqual(stored.mamArchiveId, "200")
        XCTAssertEqual(stored.body, body)
        XCTAssertEqual(stored.date, date)
        XCTAssertEqual(stored.sentDate, sentDate)
        XCTAssertEqual(stored.systemMetadata as NSDictionary?, metadata)
        XCTAssertEqual(try savedStanza(stored).stanza, stanza)
        XCTAssertEqual(try fingerprint(savedStanza(stored)), f.fingerprint)
        XCTAssertEqual(f.memory.records[f.manager.owner], before, "Archive metadata admission must not decrypt or advance the ratchet again")
        XCTAssertEqual(realm.objects(MessageStorageItem.self).filter("owner == %@", f.manager.owner).count, 1)
    }

    func testArchiveIngressReusesAuthenticatedOwnOtherDeviceCarbon() throws {
        let f = try fixture(ownSender: true)
        f.account.messages.unsubscribeReceiver()
        let item = try verifiedItem(f)
        f.account.messages.save([item], silentNotifications: true)
        let before = f.memory.records[f.manager.owner]
        let receipt = try archivedReplayReceipt(f)
        XCTAssertEqual(receipt.messagePrimaryIDs, [item.primary])
        XCTAssertEqual(receipt.persistedResultCount, 1)
        XCTAssertEqual(receipt.intentionallyConsumedResultCount, 0)
        XCTAssertTrue(try XCTUnwrap(WRealm.safe().object(ofType: MessageStorageItem.self, forPrimaryKey: item.primary)).outgoing)
        XCTAssertEqual(f.memory.records[f.manager.owner], before)
    }

    func testArchiveIngressRejectsChangedOuterIDWithoutAliasingSavedPayload() throws {
        let f = try fixture()
        f.account.messages.unsubscribeReceiver()
        let item = try verifiedItem(f)
        f.account.messages.save([item], silentNotifications: true)
        let changed = try XMPPMessage(xmlString: f.wire.xmlString)
        changed.removeAttribute(forName: "id")
        changed.addAttribute(withName: "id", stringValue: "forged-alias")
        let before = f.memory.records[f.manager.owner]
        let receipt = try archivedReplayReceipt(f, leaf: changed)
        XCTAssertTrue(receipt.messagePrimaryIDs.isEmpty)
        XCTAssertEqual(receipt.persistedResultCount, 0)
        XCTAssertEqual(receipt.intentionallyConsumedResultCount, 1)
        let realm = try WRealm.safe(); realm.refresh()
        XCTAssertEqual(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: item.primary)?.mamArchiveId, "")
        XCTAssertEqual(realm.objects(MessageStorageItem.self).filter("owner == %@", f.manager.owner).count, 1)
        XCTAssertEqual(f.memory.records[f.manager.owner], before)
    }

    func testArchiveIngressCannotRestoreDeletedHiddenOrMissingAuthenticatedRows() throws {
        for state in ["deleted", "hidden", "missing"] {
            let f = try fixture()
            f.account.messages.unsubscribeReceiver()
            let item = try verifiedItem(f)
            f.account.messages.save([item], silentNotifications: true)
            let realm = try WRealm.safe()
            let primary = item.primary
            let saved = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
            try realm.write {
                if state == "deleted" { saved.isDeleted = true }
                if state == "hidden" { saved.isLocallyHiddenByReport = true }
                if state == "missing" { realm.delete(saved) }
            }
            let before = f.memory.records[f.manager.owner]
            let receipt = try archivedReplayReceipt(f)
            XCTAssertTrue(receipt.messagePrimaryIDs.isEmpty, state)
            XCTAssertEqual(receipt.persistedResultCount, 0, state)
            XCTAssertEqual(receipt.intentionallyConsumedResultCount, 1, state)
            realm.refresh()
            let after = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary)
            if state == "missing" { XCTAssertNil(after) }
            else {
                XCTAssertEqual(after?.isDeleted, state == "deleted")
                XCTAssertEqual(after?.isLocallyHiddenByReport, state == "hidden")
                XCTAssertEqual(after?.mamArchiveId, "")
            }
            XCTAssertEqual(f.memory.records[f.manager.owner], before, state)
        }
    }

    func testArchiveIngressKeepsPayloadlessAuthenticatedControlConsumed() throws {
        let f = try fixture()
        f.account.messages.unsubscribeReceiver()
        let item = try verifiedItem(f)
        f.account.messages.save([item], silentNotifications: true)
        let cipher = try f.sender.encrypt(Data(repeating: 0, count: 32), jid: f.manager.owner, deviceID: 42)
        let control = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.sender.owner)/device' to='\(f.manager.owner)' type='chat' id='ack-control'><encrypted xmlns='urn:xmpp:omemo:2'><header sid='77'><keys jid='\(f.manager.owner)'><key rid='42' kex='\(cipher.isKeyExchange ? "true" : "false")'>\(cipher.data.base64EncodedString())</key></keys></header></encrypted></message>")
        guard case .consumed(.control) = f.manager.prepareIncoming(control) else { return XCTFail("The real native payloadless ACK must authenticate as a control") }
        let before = f.memory.records[f.manager.owner]
        let receipt = try archivedReplayReceipt(f, leaf: control)
        XCTAssertTrue(receipt.messagePrimaryIDs.isEmpty)
        XCTAssertEqual(receipt.persistedResultCount, 0)
        XCTAssertEqual(receipt.intentionallyConsumedResultCount, 1)
        XCTAssertEqual(f.memory.records[f.manager.owner], before)
        XCTAssertEqual(try WRealm.safe().objects(MessageStorageItem.self).filter("owner == %@", f.manager.owner).count, 1)
    }

    func testArchiveIngressChangedCiphertextCannotBindResultToAuthenticatedRow() throws {
        let f = try fixture()
        f.account.messages.unsubscribeReceiver()
        let item = try verifiedItem(f)
        f.account.messages.save([item], silentNotifications: true)
        let changed = try XMPPMessage(xmlString: f.wire.xmlString)
        let payload = try XCTUnwrap(changed.element(forName: "encrypted", xmlns: OmemoManager.xmlns)?.element(forName: "payload", xmlns: OmemoManager.xmlns))
        var bytes = try Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(payload.stringValue)); bytes[0] ^= 1
        payload.stringValue = bytes.base64EncodedString()
        let before = f.memory.records[f.manager.owner]
        let receipt = try archivedReplayReceipt(f, leaf: changed)
        XCTAssertFalse(receipt.messagePrimaryIDs.contains(item.primary))
        XCTAssertEqual(receipt.persistedResultCount, 0)
        XCTAssertEqual(receipt.failedPersistenceCount, 1)
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(receipt, for: archiveRequest(f, queryID: receipt.queryID))) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .persistenceFailure)
        }
        let realm = try WRealm.safe(); realm.refresh()
        XCTAssertEqual(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: item.primary)?.mamArchiveId, "")
        XCTAssertEqual(f.memory.records[f.manager.owner], before)
    }

    func testAuthenticatedArchiveProjectionRequiresExactSavedScopeAndSenderProof() throws {
        for change in ["owner", "peer", "type", "auth-owner", "auth-sender", "auth-sid", "auth-identity", "proof", "stored-cipher", "origin", "sender", "recipient"] {
            let f = try fixture()
            f.account.messages.unsubscribeReceiver()
            let item = try verifiedItem(f)
            f.account.messages.save([item], silentNotifications: true)
            let realm = try WRealm.safe()
            let saved = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: item.primary))
            let leaf = try XMPPMessage(xmlString: f.wire.xmlString)
            try realm.write {
                if change == "owner" { saved.owner = "other-owner@example.test" }
                if change == "peer" { saved.opponent = "other-peer@example.test" }
                if change == "type" { saved.conversationType = .regular }
                if change.hasPrefix("auth-") {
                    var metadata = saved.systemMetadata ?? [:]
                    var auth = metadata["omemo_authenticated_sender_v1"] as? [String: Any] ?? [:]
                    if change == "auth-owner" { auth["owner"] = "other-owner@example.test" }
                    if change == "auth-sender" { auth["jid"] = "other-sender@example.test" }
                    if change == "auth-sid" { auth["deviceID"] = 99 }
                    if change == "auth-identity" { auth["fingerprint"] = "invalid" }
                    metadata["omemo_authenticated_sender_v1"] = auth; saved.systemMetadata = metadata
                }
                let proof = try savedStanza(saved)
                if change == "proof" { proof.omemo2ReplayFingerprint = nil }
                if change == "stored-cipher" { proof.stanza = "<message xmlns='jabber:client'/>" }
            }
            if change == "origin" { leaf.addChild(try DDXMLElement(xmlString: "<origin-id xmlns='urn:xmpp:sid:0' id='forged-origin'/>")) }
            if change == "sender" || change == "recipient" {
                let name = change == "sender" ? "from" : "to"
                leaf.removeAttribute(forName: name); leaf.addAttribute(withName: name, stringValue: "other@example.test")
            }
            let before = f.memory.records[f.manager.owner]
            let receipt = try archivedReplayReceipt(f, leaf: leaf)
            XCTAssertFalse(receipt.messagePrimaryIDs.contains(item.primary), change)
            realm.refresh()
            XCTAssertEqual(saved.mamArchiveId, "", change)
            XCTAssertEqual(f.memory.records[f.manager.owner], before, change)
        }
    }

    private func archiveRequest(_ f: Fixture, queryID: String) -> ArchiveTransportRequest {
        ArchiveTransportRequest(queryID: queryID,
            conversation: .init(owner: f.manager.owner,
                jid: f.wire.from!.bare == f.manager.owner ? f.wire.to!.bare : f.wire.from!.bare,
                conversationType: .omemo),
            locator: .latest, connectionGeneration: 1, pageSize: 80, contextBefore: 80, contextAfter: 0,
            proofFingerprint: "session:1", isUnfiltered: true, producesContinuousCoverage: true)
    }

    private func assertVerifiedArchiveWindow(_ receipt: ArchiveTransportReceipt, fixture f: Fixture, expectedPrimary: String) throws {
        let configuration = Realm.Configuration.defaultConfiguration
        let repository = RealmArchiveCoverageRepository { try Realm(configuration: configuration) }
        let request = archiveRequest(f, queryID: receipt.queryID)
        let page = try ArchiveTransportReceiptValidator.validate(receipt, for: request)
        let committed = expectation(description: "normal repository verifies the existing target in the latest window")
        Task {
            do {
                let outcome = try await repository.commit(page, request: request,
                    freshnessToken: .sessionMAM(connectionGeneration: 1, queryID: receipt.queryID))
                guard case .verified(let snapshot) = outcome else {
                    XCTFail("Replayed ordinary content must produce a verified window, not a consumed-only/empty page")
                    committed.fulfill(); return
                }
                XCTAssertEqual(snapshot.messagePrimaryIDs, [expectedPrimary])
                XCTAssertTrue(snapshot.verifiedSegment.reachesLiveEdge)
                XCTAssertEqual(snapshot.target, .latest)
            } catch { XCTFail("Normal archive verification failed: \(error)") }
            committed.fulfill()
        }
        wait(for: [committed], timeout: 3)
    }

    private func archivedReplayReceipt(_ f: Fixture, leaf: XMPPMessage? = nil) throws -> ArchiveTransportReceipt {
        let stream = ReplayArchiveAuthenticatedStream()
        stream.myJID = XMPPJID(string: f.manager.owner, resource: "archive-test")
        f.account.xmppStream = stream
        f.account.sendReadiness.markStreamManagementEnabled()
        let configuration = Realm.Configuration.defaultConfiguration
        let repository = RealmArchiveCoverageRepository { try Realm(configuration: configuration) }
        let adapter = MessageArchiveTransportAdapter(account: f.account, materializationResolver: repository,
            requestTerminalTimeout: 3, persistenceTerminalTimeout: 3)
        let queryID = "archive-replay-\(UUID())"
        let request = archiveRequest(f, queryID: queryID)
        let terminal = expectation(description: "real MAM ingress and persistence reaches final barrier")
        let box = ReplayArchiveReceiptBox()
        Task {
            do { box.set(.success(try await adapter.request(request, priority: .target))) }
            catch { box.set(.failure(error)) }
            terminal.fulfill()
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && !stream.didSendQuery { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(stream.didSendQuery)
        let leaf = leaf ?? f.wire
        let stamp = try XCTUnwrap(getReceivedMessageDate(f.wire, owner: f.manager.owner)).XMPPFormattedDate
        let archive = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.manager.owner)' to='\(f.manager.owner)/archive-test'><result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='200'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='\(stamp)'/>\(leaf.xmlString)</forwarded></result></message>")
        f.account.xmppStream(stream, didReceive: archive)
        let final = try XMPPIQ(xmlString: "<iq type='result' id='\(queryID)'><fin xmlns='urn:xmpp:mam:2' complete='true' queryid='\(queryID)'><set xmlns='http://jabber.org/protocol/rsm'><first>200</first><last>200</last><count>1</count></set></fin></iq>")
        XCTAssertTrue(f.account.mam.read(stream, withIQ: final))
        wait(for: [terminal], timeout: 4)
        return try XCTUnwrap(box.result).get()
    }

    private func fixture(ownSender: Bool = false) throws -> Fixture {
        let owner = "history-owner-\(UUID().uuidString.lowercased())@example.test"
        let senderOwner = ownSender ? owner : "history-sender-\(UUID().uuidString.lowercased())@example.test"
        let recipient = ownSender ? "conversation-peer@example.test" : owner
        let sender = try XabberOMEMO2Storage(owner: senderOwner, persistence: Memory())
        _ = try sender.prepare(deviceID: 77, preKeyCount: 3)
        let memory = Memory()
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        let bundle = try storage.prepare(deviceID: 42, preKeyCount: 3)
        let first = try XCTUnwrap(bundle.preKeys.first)
        try sender.initiateSession(jid: owner, deviceID: 42, bundle: OMEMO2PublishedBundle(bundle).selectedBundle(preKeyID: first.id))
        let manager = OmemoManager(withOwner: owner)
        manager.omemo2Storage = storage
        _ = try manager.ensureOMEMO2Prepared()
        let account = Account(jid: owner, queue: DispatchQueue(label: "N04-history-\(UUID())"))
        account.omemo = manager
        accounts.append(account)
        AccountManager.shared.users = originalUsers + accounts
        let content = "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>verified history</body></content><rpad/><from jid='\(senderOwner)'/><to jid='\(recipient)'/></envelope>"
        let sealed = try Omemo2PayloadCodec.seal(Omemo2PayloadCodec.prepareOutgoingXML(content))
        let ciphertext = try sender.encrypt(sealed.keyAndMAC, jid: owner, deviceID: 42)
        let wire = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(senderOwner)/device' to='\(recipient)/ios' id='\(UUID().uuidString)' type='chat'><time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='\(Date().XMPPFormattedDate)'/><encrypted xmlns='urn:xmpp:omemo:2'><header sid='77'><keys jid='\(owner)'><key rid='42' kex='true'>\(ciphertext.data.base64EncodedString())</key></keys></header><payload>\(sealed.ciphertext.base64EncodedString())</payload></encrypted></message>")
        let fingerprint = try XCTUnwrap(OMEMO2ReplayProtection.fingerprint(for: wire, owner: owner, localDeviceID: 42))
        return Fixture(manager: manager, sender: sender, account: account, memory: memory, wire: wire, fingerprint: fingerprint)
    }
    private func removeProtectedReplayState(_ f: Fixture) throws {
        let storage = try XCTUnwrap(f.manager.omemo2Storage)
        try storage.deleteSessions(jid: f.wire.from!.bare, deviceID: 77)
        let bytes = try XCTUnwrap(f.memory.records[f.manager.owner])
        var state = try XCTUnwrap(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        state.removeValue(forKey: "authenticatedReceiveFingerprints")
        f.memory.records[f.manager.owner] = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }
    private func rawItem(_ f: Fixture) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.configureIncomingMessage(f.wire, owner: f.manager.owner, opponent: f.wire.from!.bare == f.manager.owner ? f.wire.to!.bare : f.wire.from!.bare, outgoing: f.wire.from!.bare == f.manager.owner, isRead: false, date: Date(), isEncrypted: true)
        return item
    }
    private func verifiedItem(_ f: Fixture) throws -> MessageStorageItem {
        // Keep publication/control transport outside this history-store test.
        // The account is restored before materialization persists the proof.
        let users = AccountManager.shared.users
        AccountManager.shared.users = users.filter { $0.jid != f.manager.owner }
        defer { AccountManager.shared.users = users }
        guard case let .verified(message, provenance, sender) = f.manager.prepareIncoming(f.wire) else {
            XCTFail("Fixture must pass real OMEMO2 crypto and SCE validation")
            throw OMEMO2StorageError.invalidState
        }
        let item = MessageStorageItem()
        item.configureIncomingMessage(message, owner: f.manager.owner, opponent: f.wire.from!.bare == f.manager.owner ? f.wire.to!.bare : f.wire.from!.bare, outgoing: f.wire.from!.bare == f.manager.owner, isRead: false, date: Date(), isEncrypted: true)
        item.incomingEncryption = provenance
        item.applyIncomingSenderTrust(sender, encryption: provenance)
        return item
    }
    private func savedStanza(_ item: MessageStorageItem) throws -> MessageStanzaStorageItem {
        try XCTUnwrap(WRealm.safe().object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: item.primary + "_stanza"))
    }
    private func fingerprint(_ row: MessageStanzaStorageItem) throws -> Data? {
        guard row.objectSchema.properties.contains(where: { $0.name == "omemo2ReplayFingerprint" }) else {
            XCTFail("Local authenticated replay proof is absent from the stanza history schema")
            return nil
        }
        return row["omemo2ReplayFingerprint"] as? Data
    }
}

private final class ReplayArchiveAuthenticatedStream: XMPPStream {
    private let captureLock = NSLock()
    private var sentQuery = false
    override var isAuthenticated: Bool { true }
    override func send(_ element: DDXMLElement) {
        if element.element(forName: "query", xmlns: "urn:xmpp:mam:2") != nil {
            captureLock.lock(); sentQuery = true; captureLock.unlock()
        }
    }
    var didSendQuery: Bool { captureLock.lock(); defer { captureLock.unlock() }; return sentQuery }
}
private final class ReplayArchiveReceiptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<ArchiveTransportReceipt, Error>?
    func set(_ result: Result<ArchiveTransportReceipt, Error>) { lock.lock(); stored = result; lock.unlock() }
    var result: Result<ArchiveTransportReceipt, Error>? { lock.lock(); defer { lock.unlock() }; return stored }
}
