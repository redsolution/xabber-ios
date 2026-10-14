import Foundation
import RealmSwift
import XMPPFramework
import XCTest
@testable import xabber

/// Public compatibility entrypoints must preserve the real native receive
/// contract, including typed sender proof and archive persistence routing.
final class OMEMO2CompatibilityIngressBehaviorTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
    }
    private struct Fixture {
        let receiver: OmemoManager
        let receiverStore: XabberOMEMO2Storage
        let sender: XabberOMEMO2Storage
        let memory: Memory
        let peer: String
    }
    private var oldRealm: Realm.Configuration!
    private var keeper: Realm!
    private var oldUsers: [Account] = []
    private var accounts: [Account] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment),
            "This suite requires isolated storage and disabled account autoconnect")
        oldRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "CompatibilityIngress-\(UUID())")
        keeper = try WRealm.safe()
        oldUsers = AccountManager.shared.users
    }

    override func tearDown() {
        guard oldRealm != nil else { super.tearDown(); return }
        for account in accounts {
            account.queue.sync {}
            account.omemo.omemo2MaintenanceWorkItem?.cancel()
            account.omemo.omemo2MaintenanceWorkItem = nil
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
            account.xmppTaskScheduler.reset()
            CredentialsManager.shared.removeDeviceId(for: account.jid)
        }
        AccountManager.shared.users = oldUsers
        accounts.removeAll()
        keeper = nil
        Realm.Configuration.defaultConfiguration = oldRealm
        super.tearDown()
    }

    func testModifyAndPushEntrypointsReturnActualSenderProofAndSanitizedNativeContent() throws {
        for route in ["modify", "push"] {
            let f = try fixture()
            let wire = try packet(f)
            inject(wire)

            let result = prepare(wire, f: f, route: route)

            guard case let .verified(clean, proof, sender) = result else { return XCTFail("Expected \(route): \(describe(result))") }
            XCTAssertEqual(clean.body, "native compatibility content")
            XCTAssertEqual(proof, .authenticatedSCE(profile: .omemo2))
            XCTAssertEqual(sender?.owner, f.receiver.owner)
            XCTAssertEqual(sender?.jid, f.peer)
            XCTAssertEqual(sender?.deviceID, 41)
            XCTAssertEqual(sender?.isTrusted, false)
            XCTAssertNil(clean.element(forName: "reference"))
            XCTAssertNil(clean.element(forName: "omemo-result__system"))
            XCTAssertEqual(wire.body, "injected fallback", "Preparation must not mutate its wire input")
            XCTAssertEqual(keeper.objects(MessageStorageItem.self).filter("owner == %@", f.receiver.owner).count, 0)
            XCTAssertEqual(keeper.objects(ConversationArchiveCoverageStorageItem.self).filter("owner == %@", f.receiver.owner).count, 0)
        }
    }

    func testModifyAndPushFailureRollBackNativeStateAndAuthenticRetryRemainsEligible() throws {
        for route in ["modify", "push"] {
            let f = try fixture()
            let original = try packet(f)
            let damaged = try corrupt(original)
            inject(damaged)
            let before = f.memory.records[f.receiver.owner]

            let failed = prepare(damaged, f: f, route: route)

            guard case let .failed(clean, _) = failed else { return XCTFail("Expected failure: \(route)") }
            XCTAssertNil(clean.body)
            XCTAssertNil(clean.element(forName: "reference"))
            XCTAssertNil(failed.authenticatedSender)
            XCTAssertEqual(failed.provenance, .failedOMEMO)
            XCTAssertEqual(f.memory.records[f.receiver.owner], before)
            guard case let .verified(retry, _, _) = prepare(original, f: f, route: route) else {
                return XCTFail("Failed compatibility receive must leave authentic retry eligible")
            }
            XCTAssertEqual(retry.body, "native compatibility content")
        }
    }

    func testModifyAndPushControlReplayAndInvalidTransportNeverExposeDisplayableContent() throws {
        for route in ["modify", "push"] {
            let f = try fixture()
            let control = try packet(f, control: true)
            inject(control)
            guard case .consumed(.control) = prepare(control, f: f, route: route) else { return XCTFail("Expected control") }
            let beforeReplay = f.memory.records[f.receiver.owner]
            let duplicate = prepare(control, f: f, route: route)
            guard case .consumed(.duplicate) = duplicate else { return XCTFail("Expected control replay") }
            XCTAssertNil(duplicate.message)
            XCTAssertNil(duplicate.authenticatedSender)
            XCTAssertEqual(f.memory.records[f.receiver.owner], beforeReplay)
            let ambiguous = try wrapped(control, f: f, route: "received")
            ambiguous.addChild(try XCTUnwrap(control.element(forName: "encrypted")).copy() as! DDXMLElement)
            let invalid = prepare(ambiguous, f: f, route: route)
            guard case .consumed(.invalidTransport) = invalid else { return XCTFail("Expected invalid transport") }
            XCTAssertNil(invalid.message)
            XCTAssertEqual(f.memory.records[f.receiver.owner], beforeReplay)
        }
    }

    func testCompatibilityEntrypointsLeaveOrdinaryPlaintextOnItsExistingRouteWithoutProof() throws {
        let f = try fixture()
        let plain = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.peer)' to='\(f.receiver.owner)' id='plain'><body>ordinary</body><envelope xmlns='urn:xmpp:sce:1'/></message>")
        let before = f.memory.records[f.receiver.owner]
        for route in ["modify", "push"] {
            let result = prepare(plain, f: f, route: route)
            guard case let .notEncrypted(clean) = result else { return XCTFail("Plaintext must stay ordinary") }
            XCTAssertEqual(clean.body, "ordinary")
            XCTAssertNil(clean.element(forName: "envelope"))
            XCTAssertEqual(result.provenance, .plaintext)
            XCTAssertNil(result.authenticatedSender)
        }
        let receiver = messageReceiver(f.receiver.owner)
        XCTAssertFalse(f.receiver.didReceiveOmemoMessage(plain, archivedMessageReceiver: receiver))
        XCTAssertTrue(receiver.performMessageQueueSync { receiver.queuedMessages.isEmpty })
        XCTAssertEqual(f.memory.records[f.receiver.owner], before)
    }

    func testDefaultAndInjectedSyncCompatibilityAdaptersDecryptActualNativeContentOnceWithoutSerializingProof() throws {
        for injected in [false, true] {
            let f = try fixture()
            let wire = try packet(f)
            inject(wire)
            let query = try syncQuery(wire, f: f)
            var calls = 0
            let modified: DDXMLElement
            if injected {
                modified = f.receiver.modifySyncQuery(query, decryptMessage: {
                    calls += 1
                    return try f.receiver.decryptMessage($0)
                })
            } else { modified = f.receiver.modifySyncQuery(query) }
            let leaf = try syncLeaf(modified)
            XCTAssertEqual(leaf.body, "native compatibility content")
            XCTAssertEqual(leaf.from?.bare, f.peer)
            XCTAssertEqual(leaf.to?.bare, f.receiver.owner)
            XCTAssertNil(leaf.element(forName: "reference"))
            XCTAssertNil(leaf.element(forName: "omemo-result__system"))
            XCTAssertEqual(modified.attributeStringValue(forName: "stamp"), "424242")
            XCTAssertEqual(modified.elements(forName: "conversation").count, 2)
            XCTAssertEqual(modified.elements(forName: "conversation").last?.element(forName: "metadata")?.element(forName: "last-message")?.element(forName: "message")?.element(forName: "body")?.stringValue, "ordinary preview")
            if injected { XCTAssertEqual(calls, 1, "Plaintext preview must not enter decrypt callback") }
            let reconstructed = ClientSyncConversationValue(try XCTUnwrap(modified.elements(forName: "conversation").first))
            XCTAssertEqual(reconstructed.lastMessageEncryption, .plaintext, "XML alone carries no native authentication authority")
            XCTAssertNil(reconstructed.lastMessageAuthenticatedSender)
            let after = f.memory.records[f.receiver.owner]
            let repeated = injected ? f.receiver.modifySyncQuery(query, decryptMessage: { try f.receiver.decryptMessage($0) }) : f.receiver.modifySyncQuery(query)
            XCTAssertNil(repeated.elements(forName: "conversation").first?.element(forName: "metadata")?.element(forName: "last-message"))
            XCTAssertEqual(f.memory.records[f.receiver.owner], after)
            XCTAssertEqual(keeper.objects(MessageStorageItem.self).filter("owner == %@", f.receiver.owner).count, 0)
        }
    }

    func testBothSyncCompatibilityAdaptersDiscardFailedOuterPreviewAndAllowAuthenticRetry() throws {
        for injected in [false, true] {
            let f = try fixture()
            let original = try packet(f)
            let damaged = try corrupt(original)
            inject(damaged)
            let before = f.memory.records[f.receiver.owner]
            let query = try syncQuery(damaged, f: f)
            let failed = injected ? f.receiver.modifySyncQuery(query, decryptMessage: { try f.receiver.decryptMessage($0) }) : f.receiver.modifySyncQuery(query)
            let leaf = try syncLeaf(failed)
            XCTAssertNil(leaf.body)
            XCTAssertNil(leaf.element(forName: "reference"))
            XCTAssertNil(leaf.element(forName: "omemo-result__system"))
            XCTAssertEqual(f.memory.records[f.receiver.owner], before)
            let valid = try syncQuery(original, f: f)
            let retry = injected ? f.receiver.modifySyncQuery(valid, decryptMessage: { try f.receiver.decryptMessage($0) }) : f.receiver.modifySyncQuery(valid)
            XCTAssertEqual(try syncLeaf(retry).body, "native compatibility content")
        }
    }

    func testBothSyncCompatibilityAdaptersConsumeActualControlWithoutHistoryOrPreviewBubbles() throws {
        for injected in [false, true] {
            let f = try fixture()
            let query = try syncQuery(packet(f, control: true), f: f)
            let clean = injected ? f.receiver.modifySyncQuery(query, decryptMessage: { try f.receiver.decryptMessage($0) }) : f.receiver.modifySyncQuery(query)
            XCTAssertNil(clean.elements(forName: "conversation").first?.element(forName: "metadata")?.element(forName: "last-message"))
            XCTAssertEqual(clean.elements(forName: "conversation").count, 2)
            XCTAssertEqual(keeper.objects(MessageStorageItem.self).filter("owner == %@", f.receiver.owner).count, 0)
            XCTAssertEqual(keeper.objects(ConversationArchiveCoverageStorageItem.self).filter("owner == %@", f.receiver.owner).count, 0)
        }
    }

    func testDecryptMessageCompatibilityValidatesOriginalTimeBeforeReturningAnEnvelopeFromEveryWrapper() throws {
        let sentAt = Date(timeIntervalSince1970: 1_791_978_245)
        for route in ["live", "mam", "received", "sent"] {
            let f = try fixture(ownSender: route == "sent")
            let wire = try wrapped(packet(f, protectedTime: sentAt), f: f, route: route, delayedAt: sentAt)
            let before = f.memory.records[f.receiver.owner]
            XCTAssertThrowsError(try f.receiver.decryptMessage(wire,
                originalSendingTime: .init(date: sentAt.addingTimeInterval(301), source: .caller)))
            XCTAssertEqual(f.memory.records[f.receiver.owner], before)
            let opened = try XCTUnwrap(f.receiver.decryptMessage(wire,
                originalSendingTime: .init(date: sentAt, source: .caller)))
            XCTAssertEqual(opened.xmlns(), "urn:xmpp:sce:1")
            XCTAssertEqual(opened.element(forName: "content")?.element(forName: "body")?.stringValue, "native compatibility content")
            XCTAssertNil(try f.receiver.decryptMessage(wire, originalSendingTime: .init(date: sentAt, source: .caller)))
        }
    }

    func testCompatibilityReceiverRoutesRealContentAndSenderProofForLiveArchiveAndBothCarbons() throws {
        for route in ["live", "mam", "received", "sent"] {
            let f = try fixture(ownSender: route == "sent")
            let receiver = messageReceiver(f.receiver.owner)
            receiver.archiveQueryIdPersistenceResolver = { $0 == "compat-query" }
            let wire = try wrapped(packet(f), f: f, route: route)
            inject(wire)

            XCTAssertTrue(f.receiver.didReceiveOmemoMessage(wire, fromCCC: true, archivedMessageReceiver: receiver))

            let item = try XCTUnwrap(receiver.performMessageQueueSync { receiver.queuedMessages.first })
            XCTAssertEqual(item.encryption, .authenticatedSCE(profile: .omemo2), route)
            XCTAssertEqual(item.message.body, "native compatibility content", route)
            XCTAssertEqual(item.authenticatedSender?.owner, f.receiver.owner)
            XCTAssertEqual(item.authenticatedSender?.jid, f.peer)
            XCTAssertEqual(item.authenticatedSender?.deviceID, 41)
            XCTAssertEqual(item.authenticatedSender?.isTrusted, false)
            if route == "mam" {
                XCTAssertEqual(item.queryId, "compat-query")
                XCTAssertEqual(item.mamResultID, "compat-archive")
            }
            let row = try materialize(item, receiver: receiver)
            XCTAssertEqual(row.owner, f.receiver.owner)
            XCTAssertEqual(row.opponent, route == "sent" ? "contact@example.test" : f.peer)
            XCTAssertEqual(row.conversationType, .omemo)
            XCTAssertEqual(row.incomingEncryption, .authenticatedSCE(profile: .omemo2))
            XCTAssertEqual(row.messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
            XCTAssertEqual(row.body, "native compatibility content")
            XCTAssertTrue(f.receiver.didReceiveOmemoMessage(wire, archivedMessageReceiver: receiver))
            XCTAssertEqual(receiver.performMessageQueueSync { receiver.queuedMessages.count }, 1)
        }
    }

    func testCompatibilityReceiverConsumesControlReplayWithoutQueueingAndRejectsPlaintextFallbackAfterMACFailure() throws {
        for route in ["live", "mam", "received", "sent"] {
            let f = try fixture(ownSender: route == "sent")
            let receiver = messageReceiver(f.receiver.owner)
            let control = try wrapped(packet(f, control: true), f: f, route: route)
            XCTAssertTrue(f.receiver.didReceiveOmemoMessage(control, archivedMessageReceiver: receiver))
            XCTAssertTrue(f.receiver.didReceiveOmemoMessage(control, archivedMessageReceiver: receiver))
            XCTAssertTrue(receiver.performMessageQueueSync { receiver.queuedMessages.isEmpty })
            let invalid = try wrapped(corrupt(packet(f)), f: f, route: route)
            inject(invalid)
            let before = f.memory.records[f.receiver.owner]
            XCTAssertTrue(f.receiver.didReceiveOmemoMessage(invalid, archivedMessageReceiver: receiver))
            XCTAssertEqual(f.memory.records[f.receiver.owner], before)
            let item = try XCTUnwrap(receiver.performMessageQueueSync { receiver.queuedMessages.first })
            XCTAssertEqual(item.encryption, .failedOMEMO)
            XCTAssertNil(item.authenticatedSender)
            XCTAssertNil(item.message.body)
            let row = try materialize(item, receiver: receiver)
            XCTAssertEqual(row.messageError, "omemo")
            XCTAssertEqual(row.incomingEncryption, .failedOMEMO)
            XCTAssertNil(row.messageWarningText)
        }
    }

    func testImplicitAccountArchiveFallbackPersistsOneNativeRowWithReplayProofAndSenderWarning() throws {
        let f = try fixture()
        let account = Account(jid: f.receiver.owner, queue: DispatchQueue(label: "CompatibilityIngress-account-\(UUID())"))
        account.omemo = f.receiver
        account.messages.unsubscribeReceiver()
        account.messages.archiveQueryIdPersistenceResolver = { $0 == "compat-query" }
        accounts.append(account)
        AccountManager.shared.users = oldUsers + accounts
        let leaf = try packet(f)
        let expectedFingerprint = try XCTUnwrap(OMEMO2ReplayProtection.fingerprint(for: leaf, owner: f.receiver.owner, localDeviceID: 42))
        let wire = try wrapped(leaf, f: f, route: "mam")

        XCTAssertTrue(f.receiver.didReceiveOmemoMessage(wire))
        let queued = try XCTUnwrap(account.messages.performMessageQueueSync { account.messages.queuedMessages.first })
        XCTAssertEqual(queued.encryption, .authenticatedSCE(profile: .omemo2))
        XCTAssertEqual(queued.authenticatedSender?.owner, f.receiver.owner)
        XCTAssertEqual(queued.authenticatedSender?.jid, f.peer)
        XCTAssertEqual(try materialize(queued, receiver: account.messages).incomingEncryption, .authenticatedSCE(profile: .omemo2))
        let summary = account.messages.storeMessagesNowSummary(forQueryId: "compat-query")

        XCTAssertEqual(summary.received, 1)
        XCTAssertEqual(summary.queued, 1)
        XCTAssertEqual(summary.persistedRows, 1)
        let row = try XCTUnwrap(keeper.objects(MessageStorageItem.self).filter("owner == %@", f.receiver.owner).first)
        XCTAssertEqual(row.body, "native compatibility content")
        XCTAssertEqual(row.owner, f.receiver.owner)
        XCTAssertEqual(row.opponent, f.peer)
        XCTAssertEqual(row.conversationType, .omemo)
        XCTAssertEqual(row.mamArchiveId, "compat-archive")
        // incomingEncryption is a transient, Realm-ignored materialization
        // field. Persisted local replay evidence and sender warning below
        // preserve the authenticated receive association across row reloads.
        XCTAssertEqual(row.messageWarningText, MessageStorageItem.omemoUntrustedSenderWarningText)
        let stanza = try XCTUnwrap(keeper.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: row.primary + "_stanza"))
        XCTAssertEqual(stanza.omemo2ReplayFingerprint, expectedFingerprint)
        XCTAssertFalse(stanza.stanza.contains("omemo-result__system"))
        let committedNativeState = f.memory.records[f.receiver.owner]
        guard case .consumed(.duplicate) = f.receiver.prepareIncoming(wire) else {
            return XCTFail("Persisted native archive packet must remain an exact authenticated duplicate")
        }
        XCTAssertTrue(f.receiver.didReceiveOmemoMessage(wire))
        XCTAssertTrue(account.messages.performMessageQueueSync { account.messages.queuedMessages.isEmpty })
        // Per-query summaries are cumulative even when the latest drain is
        // empty. A replay must leave every received/queued/persisted count equal.
        XCTAssertEqual(account.messages.storeMessagesNowSummary(forQueryId: "compat-query"), summary)
        XCTAssertEqual(f.memory.records[f.receiver.owner], committedNativeState)
        XCTAssertEqual(keeper.objects(MessageStorageItem.self).filter("owner == %@", f.receiver.owner).count, 1)
    }

    func testPersistArchivedCompatibilityHelperUsesFallbackOnlyWhenPreferredReceiverIsAbsent() throws {
        for hasPreferred in [false, true] {
            let f = try fixture()
            let primary = messageReceiver(f.receiver.owner)
            let fallback = messageReceiver(f.receiver.owner)
            let result = f.receiver.prepareIncoming(try wrapped(packet(f), f: f, route: "mam"), context: .archive)
            let clean = try XCTUnwrap(result.message)

            OmemoManager.persistDecryptedArchivedMessage(clean, preferredReceiver: hasPreferred ? primary : nil,
                fallbackReceiver: fallback, encryption: result.provenance, authenticatedSender: result.authenticatedSender)

            let selected = hasPreferred ? primary : fallback
            let unselected = hasPreferred ? fallback : primary
            let item = try XCTUnwrap(selected.performMessageQueueSync { selected.queuedMessages.first })
            XCTAssertTrue(unselected.performMessageQueueSync { unselected.queuedMessages.isEmpty })
            XCTAssertEqual(item.queryId, "compat-query")
            XCTAssertEqual(item.mamResultID, "compat-archive")
            XCTAssertEqual(item.encryption, .authenticatedSCE(profile: .omemo2))
            XCTAssertEqual(item.authenticatedSender, result.authenticatedSender)
            XCTAssertEqual(try materialize(item, receiver: selected).body, "native compatibility content")
        }
    }

    private func fixture(ownSender: Bool = false) throws -> Fixture {
        let owner = "compat-owner-\(UUID().uuidString.lowercased())@example.test"
        let peer = ownSender ? owner : "compat-peer-\(UUID().uuidString.lowercased())@example.test"
        let memory = Memory()
        let store = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        let bundle = try store.prepare(deviceID: 42, preKeyCount: 3)
        let sender = try XabberOMEMO2Storage(owner: peer, persistence: Memory())
        _ = try sender.prepare(deviceID: 41, preKeyCount: 3)
        try sender.initiateSession(jid: owner, deviceID: 42,
            bundle: OMEMO2PublishedBundle(bundle).selectedBundle(preKeyID: XCTUnwrap(bundle.preKeys.first).id))
        let receiver = OmemoManager(withOwner: owner)
        receiver.omemo2Storage = store
        _ = try receiver.ensureOMEMO2Prepared(attemptPublication: false)
        return Fixture(receiver: receiver, receiverStore: store, sender: sender, memory: memory, peer: peer)
    }

    private func packet(_ f: Fixture, control: Bool = false, protectedTime: Date? = nil) throws -> XMPPMessage {
        let to = f.peer == f.receiver.owner ? "contact@example.test" : f.receiver.owner
        let time = protectedTime.map { "<time stamp='\($0.XMPPFormattedDate)'/>" } ?? ""
        let xml = "<envelope xmlns='urn:xmpp:sce:1'><content><body xmlns='jabber:client'>native compatibility content</body><origin-id xmlns='urn:xmpp:sid:0' id='\(UUID())'/></content><rpad/><from jid='\(f.peer)'/><to jid='\(to)'/>\(time)</envelope>"
        let sealed = try control ? nil : Omemo2PayloadCodec.seal(xml)
        let wrapped = try f.sender.encrypt(sealed?.keyAndMAC ?? Data(repeating: 0, count: 32), jid: f.receiver.owner, deviceID: 42)
        let payload = sealed.map { "<payload>\($0.ciphertext.base64EncodedString())</payload>" } ?? ""
        return try XMPPMessage(xmlString: "<message xmlns='jabber:client' type='chat' from='\(f.peer)/sender' to='\(to)' id='\(UUID())'><encrypted xmlns='urn:xmpp:omemo:2'><header sid='41'><keys jid='\(f.receiver.owner)'><key rid='42'\(wrapped.isKeyExchange ? " kex='true'" : "")>\(wrapped.data.base64EncodedString())</key></keys></header>\(payload)</encrypted></message>")
    }

    private func wrapped(_ leaf: XMPPMessage, f: Fixture, route: String, delayedAt: Date = Date(timeIntervalSince1970: 1_791_978_245)) throws -> XMPPMessage {
        if route == "live" { return leaf }
        let namespace = route == "mam" ? "urn:xmpp:mam:2" : "urn:xmpp:carbons:2"
        let name = route == "mam" ? "result" : route
        let metadata = route == "mam" ? " queryid='compat-query' id='compat-archive'" : ""
        return try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.receiver.owner)' to='\(f.receiver.owner)'><\(name) xmlns='\(namespace)'\(metadata)><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='\(delayedAt.XMPPFormattedDate)'/>\(leaf.xmlString)</forwarded></\(name)></message>")
    }

    private func syncQuery(_ leaf: XMPPMessage, f: Fixture) throws -> DDXMLElement {
        try DDXMLElement(xmlString: "<query xmlns='https://xabber.com/protocol/synchronization' stamp='424242'><conversation jid='\(f.peer)' type='urn:xmpp:omemo:2'><metadata node='https://xabber.com/protocol/synchronization'><last-message>\(leaf.xmlString)</last-message></metadata></conversation><conversation jid='plain@example.test' type='regular'><metadata node='https://xabber.com/protocol/synchronization'><last-message><message xmlns='jabber:client' from='plain@example.test' to='\(f.receiver.owner)'><body>ordinary preview</body></message></last-message></metadata></conversation></query>")
    }

    private func syncLeaf(_ query: DDXMLElement) throws -> XMPPMessage {
        XMPPMessage(from: try XCTUnwrap(query.elements(forName: "conversation").first?.element(forName: "metadata")?.element(forName: "last-message")?.element(forName: "message")))
    }

    private func corrupt(_ wire: XMPPMessage) throws -> XMPPMessage {
        let copy = XMPPMessage(from: wire.copy() as! DDXMLElement)
        let payload = try XCTUnwrap(copy.element(forName: "encrypted")?.element(forName: "payload"))
        var bytes = try Omemo2PayloadCodec.decodeBase64(XCTUnwrap(payload.stringValue))
        bytes[0] ^= 1
        payload.stringValue = bytes.base64EncodedString()
        return copy
    }

    private func inject(_ wire: XMPPMessage) {
        wire.addBody("injected fallback")
        wire.addChild(try! DDXMLElement(xmlString: "<reference xmlns='https://xabber.com/protocol/references' type='mutable'><file-sharing xmlns='https://xabber.com/protocol/files'/></reference>"))
        wire.addChild(try! DDXMLElement(xmlString: "<omemo-result__system result='true'/>"))
    }

    private func prepare(_ wire: XMPPMessage, f: Fixture, route: String) -> OMEMOReceiveResult {
        route == "push" ? f.receiver.didReceiveOmemoMessageFromPush(wire) : f.receiver.modifyOmemoStanza(message: wire)
    }

    private func messageReceiver(_ owner: String) -> MessageManager {
        let receiver = MessageManager(withOwner: owner, activeStream: false)
        receiver.unsubscribeReceiver()
        return receiver
    }

    private func materialize(_ item: MessageManager.MessageQueueItem, receiver: MessageManager) throws -> MessageStorageItem {
        var batch: MessageManager.ProcessedQueueBatch?
        receiver.processQueue([item]) { batch = $0 }
        return try XCTUnwrap(batch?.messages.first)
    }

    private func describe(_ result: OMEMOReceiveResult) -> String {
        switch result {
        case .notEncrypted: return "not encrypted"
        case .verified: return "verified"
        case .consumed(let reason): return "consumed \(reason)"
        case .failed(_, let error): return "failed \(error)"
        }
    }
}
