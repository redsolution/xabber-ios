import Foundation
import RealmSwift
import SignalProtocolObjC
import XMPPFramework
import XCTest
@testable import xabber

/// Exercises the existing admission, persistence and encryption routes with
/// final forwarding carriers, including recovery after the source changes.
@MainActor
final class ForwardSendLifecycleTests: XCTestCase {
    private let referencesNS = "https://xabber.com/protocol/references"
    private let forwardNS = "urn:xmpp:forward:0"
    private var previousConfiguration: Realm.Configuration!
    private var realm: Realm!
    private var managers: [MessageManager] = []
    private var owner = ""
    private let peer = "recipient@example.test"

    override func setUp() {
        super.setUp()
        previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "ForwardSendLifecycle-\(UUID())")
        realm = try! WRealm.safe()
        owner = "forward-lifecycle-\(UUID().uuidString.lowercased())@example.test"
    }

    override func tearDown() {
        for manager in managers {
            manager.updateSendingMessagesTimer?.invalidate()
            manager.updateSendingMessagesTimer = nil
        }
        managers.removeAll()
        realm = nil
        Realm.Configuration.defaultConfiguration = previousConfiguration
        super.tearDown()
    }

    func testMultiunitAdmissionPublishesChronologicalCarriersWithDistinctTransportIDs() throws {
        let newer = try donatedSource(id: "newer", body: "second secret", at: 2)
        let older = try donatedSource(id: "older", body: "first secret", at: 1)
        let manager = try makeManager()
        var admissions: [ChatTimelineLocalOutgoingAdmission] = []
        manager.localOutgoingAdmissionPublisher = { admissions.append($0) }

        let returnedID = manager.sendSimpleMessage("my comment", to: peer + "/phone",
            forwarded: [newer, older], conversationType: .regular)

        XCTAssertEqual(admissions.count, 3)
        XCTAssertEqual(Set(admissions.map(\.primaryID)).count, 3)
        let rows = try admittedRows(admissions)
        let prepared = try rows.map { try XCTUnwrap(MessageManager.preparedForwardingContent(for: $0, in: realm)) }
        XCTAssertEqual(try prepared.flatMap { try forwardedMessages($0).map { $0.attributeStringValue(forName: "id") } },
                       ["original-older", "original-newer"])
        XCTAssertEqual(prepared.last?.body, "my comment")
        XCTAssertEqual(returnedID, rows.last?.messageId, "Existing composer success identifies the last admitted carrier")
        XCTAssertEqual(Set(rows.map(\.messageId)).count, 3)
        for (row, message) in zip(rows, prepared) {
            XCTAssertEqual(row.owner, owner)
            XCTAssertEqual(row.opponent, peer)
            XCTAssertEqual(message.attributeStringValue(forName: "from"), owner)
            XCTAssertEqual(message.to?.bare, peer)
            XCTAssertEqual(message.elementID, row.messageId)
            XCTAssertEqual(getOriginId(message), row.messageId)
            XCTAssertEqual(row.primary, MessageStorageItem.genPrimary(messageId: row.messageId, owner: owner))
            XCTAssertEqual(admissions.first?.conversation.jid, peer)
        }
    }

    func testEntireBatchAndFinalStanzasExistBeforeFirstLocalAdmissionPublication() throws {
        let selected = try donatedSource(id: "selected", body: "original", at: 1)
        let manager = try makeManager()
        var rowCounts: [Int] = []
        var stanzaCounts: [Int] = []
        manager.localOutgoingAdmissionPublisher = { [self] _ in
            let rows = outgoingRows()
            rowCounts.append(rows.count)
            stanzaCounts.append(rows.filter { row in
                realm.object(ofType: MessageStanzaStorageItem.self,
                    forPrimaryKey: row.primary + "_stanza") != nil
            }.count)
        }

        XCTAssertFalse(manager.sendSimpleMessage("typed comment", to: peer,
            forwarded: [selected], conversationType: .regular).isEmpty)

        XCTAssertEqual(rowCounts, [2, 2])
        XCTAssertEqual(stanzaCounts, [2, 2], "Publication must never expose a partially prepared batch")
    }

    func testExplicitReplyIntentAdmitsOneCarrierWithOriginalAndNewComment() throws {
        let selected = try donatedSource(id: "selected", body: "original", at: 1)
        let manager = try makeManager()
        var admissions: [ChatTimelineLocalOutgoingAdmission] = []
        manager.localOutgoingAdmissionPublisher = { admissions.append($0) }

        _ = manager.sendSimpleMessage("reply comment", to: peer, forwarded: [selected],
            conversationType: .regular, forwardIntent: .reply)

        XCTAssertEqual(admissions.count, 1)
        let row = try XCTUnwrap(try admittedRows(admissions).first)
        let prepared = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm))
        XCTAssertEqual(try forwardedMessages(prepared).map { $0.attributeStringValue(forName: "id") }, ["original-selected"])
        XCTAssertTrue(prepared.body?.hasSuffix("reply comment") == true)
    }

    func testExplicitMediaReplyIntentKeepsOriginalAndNewAttachmentInOneCarrier() throws {
        let selected = try donatedSource(id: "selected", body: "original", at: 1)
        let manager = try makeManager()
        let attachment = uploadedAttachment()
        var admissions: [ChatTimelineLocalOutgoingAdmission] = []
        manager.localOutgoingAdmissionPublisher = { admissions.append($0) }

        let primary = try XCTUnwrap(manager.willSendMediaMessage([attachment], to: peer,
            forwarded: [selected], conversationType: .regular, body: "reply caption", legacyBody: "reply caption",
            forwardIntent: .reply))

        XCTAssertEqual(admissions.map(\.primaryID), [primary])
        let row = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
        let prepared = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm))
        XCTAssertEqual(try forwardedMessages(prepared).map { $0.attributeStringValue(forName: "id") }, ["original-selected"])
        XCTAssertTrue(prepared.body?.contains("reply caption") == true)
        XCTAssertEqual(directReferences(prepared).filter {
            $0.element(forName: "file-sharing", xmlns: "https://xabber.com/protocol/files") != nil
        }.count, 1)
    }

    func testMissingTextSourceRejectsAdmissionWithoutPersistingValidSubsetOrComment() throws {
        let valid = try donatedSource(id: "valid", body: "original", at: 1)
        let manager = try makeManager()
        var admissions: [ChatTimelineLocalOutgoingAdmission] = []
        manager.localOutgoingAdmissionPublisher = { admissions.append($0) }
        let initialStanzaCount = realm.objects(MessageStanzaStorageItem.self).count

        let result = manager.sendSimpleMessage("must remain a draft", to: peer,
            forwarded: [valid, "missing-source"], conversationType: .regular)

        XCTAssertEqual(result, "")
        XCTAssertTrue(outgoingRows().isEmpty)
        XCTAssertTrue(admissions.isEmpty)
        XCTAssertTrue(realm.objects(OutgoingMessageQueueItem.self).isEmpty)
        XCTAssertEqual(realm.objects(MessageStanzaStorageItem.self).count, initialStanzaCount)
    }

    func testMalformedSourceRejectsWholeAdmissionBeforeFirstWrite() throws {
        let valid = try donatedSource(id: "valid", body: "original", at: 1)
        let invalid = try persistSource(id: "foreign-message-namespace", at: 2, xml: """
            <message xmlns='urn:example:foreign' from='author@example.test/resource' to='\(owner)' id='foreign'>
              <body>Not a client message</body>
            </message>
            """)
        let manager = try makeManager()
        var admissions: [ChatTimelineLocalOutgoingAdmission] = []
        manager.localOutgoingAdmissionPublisher = { admissions.append($0) }

        let result = manager.sendSimpleMessage("comment", to: peer,
            forwarded: [valid, invalid], conversationType: .regular)

        XCTAssertEqual(result, "")
        XCTAssertTrue(outgoingRows().isEmpty)
        XCTAssertTrue(admissions.isEmpty)
    }

    func testMissingMediaSourceCreatesNoUploadingCarrierOrAttachmentAdmission() throws {
        let valid = try donatedSource(id: "valid", body: "original", at: 1)
        let manager = try makeManager()
        let attachment = uploadedAttachment()
        var admissions: [ChatTimelineLocalOutgoingAdmission] = []
        manager.localOutgoingAdmissionPublisher = { admissions.append($0) }

        let result = manager.willSendMediaMessage([attachment], to: peer,
            forwarded: [valid, "missing-source"], conversationType: .regular,
            body: "caption", legacyBody: "caption")

        XCTAssertNil(result)
        XCTAssertTrue(outgoingRows().isEmpty)
        XCTAssertTrue(realm.objects(MessageReferenceStorageItem.self).isEmpty)
        XCTAssertTrue(admissions.isEmpty)
        XCTAssertNil(attachment.realm)
    }

    func testForwardAndNewMediaShareOnePreparedBatchAndReturnUploadingFinalCarrier() throws {
        let selected = try donatedSource(id: "selected", body: "original", at: 1)
        let manager = try makeManager()
        let attachment = uploadedAttachment()
        var admissions: [ChatTimelineLocalOutgoingAdmission] = []
        manager.localOutgoingAdmissionPublisher = { admissions.append($0) }

        let primary = try XCTUnwrap(manager.willSendMediaMessage([attachment], to: peer,
            forwarded: [selected], conversationType: .regular,
            body: "caption", legacyBody: "caption"))

        let rows = try admittedRows(admissions)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(primary, rows.last?.primary, "Upload continuation belongs to the final new-media carrier")
        let media = try XCTUnwrap(rows.last)
        XCTAssertEqual(media.state, .uploading)
        XCTAssertTrue(rows.dropLast().allSatisfy { $0.state != .uploading })
        XCTAssertTrue(rows.dropLast().allSatisfy { row in
            !row.references.contains(where: { [.media, .voice].contains($0.kind) })
        })
        XCTAssertEqual(media.references.count, 1)
        XCTAssertTrue(media.references.first?.isUploaded == true, "A remote URL stays reusable without another upload")
        let donorRow = try XCTUnwrap(rows.first)
        let donor = try XCTUnwrap(MessageManager.preparedForwardingContent(for: donorRow, in: realm))
        let final = try XCTUnwrap(MessageManager.preparedForwardingContent(for: media, in: realm))
        XCTAssertEqual(try forwardedMessages(donor).first?.attributeStringValue(forName: "id"), "original-selected")
        XCTAssertTrue(try forwardedMessages(final).isEmpty)
        XCTAssertTrue(final.body?.contains("caption") == true)
        XCTAssertTrue(final.body?.contains(try XCTUnwrap(attachment.url)) == true)
        XCTAssertEqual(directReferences(final).filter {
            $0.element(forName: "file-sharing", xmlns: "https://xabber.com/protocol/files") != nil
        }.count, 1)
        XCTAssertEqual(media.systemMetadata?["forwardBatchPrimaryIDs"] as? [String], admissions.map(\.primaryID))
        XCTAssertEqual(media.systemMetadata?["forwardUploadPending"] as? Bool, true)
    }

    func testRetryKeepsFrozenContentAfterSourceMutationDeletionAndReturnedCloneMutation() throws {
        let source = try donatedSource(id: "selected", body: "original secret", at: 1)
        let manager = try makeManager()
        var admissions: [ChatTimelineLocalOutgoingAdmission] = []
        manager.localOutgoingAdmissionPublisher = { admissions.append($0) }
        _ = manager.sendSimpleMessage("", to: peer, forwarded: [source], conversationType: .regular)
        let row = try XCTUnwrap(try admittedRows(admissions).first)
        let before = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm))
        let frozenContent = contentSignature(before)
        let carrierID = row.messageId
        let delay = try XCTUnwrap(directReferences(before).first?
            .element(forName: "forwarded", xmlns: forwardNS)?.element(forName: "delay", xmlns: "urn:xmpp:delay")?.xmlString)
        let sourceRow = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: source))
        let sourceStanza = try XCTUnwrap(realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: source + "_stanza"))
        try realm.write {
            sourceRow.body = "edited source"
            sourceStanza.stanza = "<message xmlns='jabber:client' from='changed@example.test' to='\(owner)'><body>edited source</body></message>"
        }
        XCTAssertEqual(contentSignature(try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm))), frozenContent)
        try realm.write { realm.delete(sourceStanza); realm.delete(sourceRow) }
        before.element(forName: "body", xmlns: "jabber:client")?.stringValue = "mutated returned clone"
        directReferences(before).first?.detach()

        manager.retrySending(item: row.primary)

        let after = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm))
        XCTAssertEqual(contentSignature(after), frozenContent)
        XCTAssertEqual(row.messageId, carrierID)
        XCTAssertEqual(after.elementID, carrierID)
        XCTAssertEqual(getOriginId(after), carrierID)
        XCTAssertEqual(directReferences(after).first?.element(forName: "forwarded", xmlns: forwardNS)?
            .element(forName: "delay", xmlns: "urn:xmpp:delay")?.xmlString, delay)
        XCTAssertEqual(try forwardedMessages(after).first?.attributeStringValue(forName: "id"), "original-selected")
        XCTAssertEqual(admissions.count, 1, "Retry must reuse an admitted row")
        XCTAssertEqual(outgoingRows().count, 1)
    }

    func testGateClosingAfterPreparationLeavesAllCarriersRecoverableWithoutReadmission() throws {
        let selected = try donatedSource(id: "selected", body: "original", at: 1)
        let memory = Memory()
        let manager = try makeManager(memory: memory)
        var admissions: [ChatTimelineLocalOutgoingAdmission] = []
        manager.localOutgoingAdmissionPublisher = { admission in
            admissions.append(admission)
            // A protected-state read failure uses the real fail-closed gate.
            // It begins after the atomic local preparation, before transport.
            memory.failReads = true
        }

        let result = manager.sendForwardingMessage("typed comment", to: peer,
            forwarded: [selected], conversationType: .regular)

        let rows = try admittedRows(admissions)
        guard case let .admitted(admission, submission) = result else {
            return XCTFail("Preparation completed before the gate closed")
        }
        XCTAssertEqual(rows.count, 2)
        let first = try XCTUnwrap(rows.first)
        let second = try XCTUnwrap(rows.dropFirst().first)
        XCTAssertEqual(admission.messageIDs.last, rows.last?.messageId)
        XCTAssertEqual(submission.units.map(\.state), [.blocked, .unsubmitted])
        XCTAssertTrue(submission.handedOffPrimaryIDs.isEmpty)
        XCTAssertEqual(submission.blockedPrimaryIDs, [first.primary])
        XCTAssertEqual(submission.unsubmittedPrimaryIDs, [second.primary])
        let frozen = try rows.map { contentSignature(try XCTUnwrap(MessageManager.preparedForwardingContent(for: $0, in: realm))) }
        XCTAssertTrue(realm.objects(OutgoingMessageQueueItem.self).isEmpty, "Blocked content must not reach transport admission")
        memory.failReads = false
        rows.forEach { manager.retrySending(item: $0.primary) }
        XCTAssertEqual(try rows.map { contentSignature(try XCTUnwrap(MessageManager.preparedForwardingContent(for: $0, in: realm))) }, frozen)
        XCTAssertEqual(admissions.count, 2)
        XCTAssertEqual(outgoingRows().count, 2)
        XCTAssertEqual(Set(realm.objects(OutgoingMessageQueueItem.self).map(\.messagePrimary)), Set(rows.map(\.primary)),
                       "Every text carrier reuses the existing regular text queue policy")
    }

    func testEncryptedFinalCarrierAndRetryProtectForwardedContentWithActualOMEMO2Provider() throws {
        let f = try cryptoFixture()
        let selected = try donatedSource(id: "encrypted", body: "original secret", at: 1,
            sourceOwner: f.alice.owner, includeCard: true)
        let account = Account(jid: f.alice.owner, queue: DispatchQueue(label: "ForwardLifecycle-account-\(UUID())"))
        account.omemo = f.alice
        account.chatMarkers = ChatMarkersManager(withOwner: f.alice.owner, withoutAfterburnTimer: true)
        account.sendReadiness.onReadinessChanged = nil
        account.sendReadiness.markStreamManagementEnabled()
        account.messages.omemo2OptOutStorage = f.alice.omemo2Storage
        let stream = CapturingStream()
        account.xmppStream = stream
        let previousUsers = AccountManager.shared.users
        AccountManager.shared.users = previousUsers + [account]
        defer {
            AccountManager.shared.users = previousUsers
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
        }
        var admissions: [ChatTimelineLocalOutgoingAdmission] = []
        account.messages.localOutgoingAdmissionPublisher = { admissions.append($0) }
        let firstSent = expectation(description: "encrypted prepared carrier")
        stream.onMessage = { _ in firstSent.fulfill() }

        let carrierID = account.messages.sendSimpleMessage("", to: f.bob.owner,
            forwarded: [selected], conversationType: .omemo)
        wait(for: [firstSent], timeout: 3)

        XCTAssertEqual(admissions.count, 1)
        let row = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: try XCTUnwrap(admissions.first).primaryID))
        let firstWire = try XCTUnwrap(stream.messages.first)
        let firstClean = try verified(firstWire, by: f.bob)
        try assertEncryptedCarrier(firstWire, clean: firstClean, row: row, sender: f.alice.owner, recipient: f.bob.owner)
        XCTAssertEqual(carrierID, row.messageId)
        let sourceRow = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: selected))
        let sourceXML = try XCTUnwrap(realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: selected + "_stanza"))
        try realm.write { realm.delete(sourceXML); realm.delete(sourceRow) }
        let retrySent = expectation(description: "encrypted logical retry")
        stream.onMessage = { _ in retrySent.fulfill() }

        account.messages.processSender(item: row.primary, retry: true)
        wait(for: [retrySent], timeout: 3)

        XCTAssertEqual(stream.messages.count, 2)
        let retryWire = try XCTUnwrap(stream.messages.last)
        let retryClean = try verified(retryWire, by: f.bob)
        try assertEncryptedCarrier(retryWire, clean: retryClean, row: row, sender: f.alice.owner, recipient: f.bob.owner)
        XCTAssertEqual(contentSignature(retryClean), contentSignature(firstClean))
        XCTAssertEqual(retryWire.elementID, firstWire.elementID)
        XCTAssertEqual(getOriginId(retryWire), getOriginId(firstWire))
        XCTAssertNotEqual(retryWire.element(forName: "encrypted", xmlns: "urn:xmpp:omemo:2")?.xmlString,
                          firstWire.element(forName: "encrypted", xmlns: "urn:xmpp:omemo:2")?.xmlString,
                          "A logical retry encrypts the same frozen content again")
        XCTAssertEqual(admissions.count, 1)
    }

    // MARK: - Persisted wire fixtures

    private func makeManager(memory: Memory = Memory()) throws -> MessageManager {
        let manager = MessageManager(withOwner: owner, activeStream: false)
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        _ = try storage.prepare(deviceID: 41, preKeyCount: 3)
        manager.omemo2OptOutStorage = storage
        managers.append(manager)
        return manager
    }

    private func outgoingRows() -> [MessageStorageItem] {
        Array(realm.objects(MessageStorageItem.self).filter("owner == %@ AND outgoing == true", owner))
    }

    private func admittedRows(_ admissions: [ChatTimelineLocalOutgoingAdmission]) throws -> [MessageStorageItem] {
        try admissions.map { try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: $0.primaryID)) }
    }

    private func donatedSource(id: String, body: String, at time: TimeInterval,
                               sourceOwner: String? = nil, includeCard: Bool = false) throws -> String {
        let account = sourceOwner ?? owner
        let fallback = "> Alice:\n> \(body)\n"
        let end = fallback.xmlEscaping(reverse: false).unicodeScalars.count
        let card = includeCard ? """
            <reference xmlns='https://xabber.com/protocol/references' type='data'>
              <vcard xmlns='urn:ietf:params:xml:ns:vcard-4.0'>
                <fn><text>Alice</text></fn><impp><uri>xmpp:author@example.test</uri></impp>
              </vcard>
            </reference>
            """ : ""
        return try persistSource(id: id, at: time, sourceOwner: account, xml: """
            <message xmlns='jabber:client' from='relay@example.test/desktop' to='\(account)/phone' type='chat' id='carrier-\(id)'>
              <body>\(fallback.xmlEscaping(reverse: false))</body>
              <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='\(end)'>
                <forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2023-11-14T22:13:20Z'/>
                  <message xmlns='jabber:client' from='author@example.test/laptop' to='relay@example.test/desktop' type='chat' id='original-\(id)'>
                    <body>\(body.xmlEscaping(reverse: false))</body><custom xmlns='urn:example:original'>keep</custom>
                  </message>
                </forwarded>
              </reference>\(card)
            </message>
            """)
    }

    private func persistSource(id: String, at time: TimeInterval, sourceOwner: String? = nil, xml: String) throws -> String {
        let account = sourceOwner ?? owner
        let message = try XMPPMessage(xmlString: xml)
        let row = MessageStorageItem()
        row.owner = account
        row.opponent = "relay@example.test"
        row.messageId = message.elementID ?? "source-\(id)"
        row.primary = MessageStorageItem.genPrimary(messageId: row.messageId, owner: account)
        row.body = message.body ?? ""
        row.legacyBody = row.body
        row.date = Date(timeIntervalSince1970: time)
        row.sentDate = row.date
        let raw = MessageStanzaStorageItem()
        raw.set(row.messageId, for: account, with: xml, at: row.date, primary: row.primary)
        try realm.write { realm.add(row); realm.add(raw) }
        return row.primary
    }

    private func uploadedAttachment() -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.kind = .media
        reference.mimeType = "image/jpeg"
        reference.isUploaded = true
        let uri = "https://files.example.test/new-image.jpg"
        reference.url = uri
        reference.metadata = ["filename": "new-image.jpg", "media-type": "image/jpeg", "uri": uri]
        return reference
    }

    private func directReferences(_ message: DDXMLElement) -> [DDXMLElement] {
        SCEReceivePolicy.children(of: message, named: "reference", xmlns: referencesNS)
    }

    private func forwardedMessages(_ message: DDXMLElement) throws -> [DDXMLElement] {
        try directReferences(message).compactMap { reference in
            guard let forwarded = reference.element(forName: "forwarded", xmlns: forwardNS) else { return nil }
            return try XCTUnwrap(forwarded.element(forName: "message", xmlns: "jabber:client"))
        }
    }

    private func contentSignature(_ message: XMPPMessage) -> [String] {
        [message.body ?? ""] + directReferences(message).map(\.xmlString)
    }

    // MARK: - Actual provider fixture, isolated from credentials and sockets

    private final class CapturingStream: XMPPStream {
        var messages: [XMPPMessage] = []
        var onMessage: ((XMPPMessage) -> Void)?
        override func send(_ element: DDXMLElement) {
            guard let message = element as? XMPPMessage else { return }
            let copy = message.copy() as! XMPPMessage
            messages.append(copy)
            onMessage?(copy)
        }
    }

    private final class Memory: OMEMO2StatePersistence {
        private var records: [String: Data] = [:]
        var failReads = false
        func load(owner: String) throws -> Data? {
            if failReads { throw OMEMO2StorageError.persistenceFailed }
            return records[owner]
        }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }

    private struct CryptoFixture {
        let alice: OmemoManager
        let bob: OmemoManager
    }

    private func cryptoFixture() throws -> CryptoFixture {
        let memory = Memory()
        let alice = OmemoManager(withOwner: "alice-forward-\(UUID().uuidString.lowercased())@example.test")
        let bob = OmemoManager(withOwner: "bob-forward-\(UUID().uuidString.lowercased())@example.test")
        let aliceStore = try XabberOMEMO2Storage(owner: alice.owner, persistence: memory)
        let bobStore = try XabberOMEMO2Storage(owner: bob.owner, persistence: memory)
        _ = try aliceStore.prepare(deviceID: 41, preKeyCount: 3)
        let bobBundle = try bobStore.prepare(deviceID: 42, preKeyCount: 3)
        let preKey = try XCTUnwrap(bobBundle.preKeys.first)
        try aliceStore.initiateSession(jid: bob.owner, deviceID: 42, bundle: OMEMO2Bundle(
            identityKey: bobBundle.identityKey, signedPreKey: bobBundle.signedPreKey,
            signedPreKeyID: bobBundle.signedPreKeyID, signature: bobBundle.signature,
            preKey: preKey.publicKey, preKeyID: preKey.id))
        alice.omemo2Storage = aliceStore
        bob.omemo2Storage = bobStore
        try alice.ensureOMEMO2Prepared()
        try bob.ensureOMEMO2Prepared()
        let device = SignalDeviceStorageItem()
        device.owner = alice.owner
        device.jid = bob.owner
        device.deviceId = 42
        device.primary = SignalDeviceStorageItem.genPrimary(owner: alice.owner, jid: bob.owner, deviceId: 42)
        device.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: bobBundle.identityKey)
        device.state = .trusted
        try realm.write { realm.add(device, update: .modified) }
        try advertiseDevices(to: alice, jid: alice.owner, ids: [41])
        try advertiseDevices(to: alice, jid: bob.owner, ids: [42])
        try advertiseDevices(to: bob, jid: bob.owner, ids: [42])
        try advertiseDevices(to: bob, jid: alice.owner, ids: [41])
        return CryptoFixture(alice: alice, bob: bob)
    }

    private func advertiseDevices(to manager: OmemoManager, jid: String, ids: [Int]) throws {
        let devices = ids.map { "<device id='\($0)'/>" }.joined()
        let headline = try XMPPMessage(xmlString: """
            <message xmlns='jabber:client' from='\(jid)' type='headline'>
              <event xmlns='http://jabber.org/protocol/pubsub#event'>
                <items node='urn:xmpp:omemo:2:devices'><item id='current'>
                  <devices xmlns='urn:xmpp:omemo:2'>\(devices)</devices>
                </item></items>
              </event>
            </message>
            """)
        XCTAssertTrue(manager.onContactDeviceListReceiveHeadline(headline))
    }

    private func verified(_ wire: XMPPMessage, by recipient: OmemoManager) throws -> XMPPMessage {
        guard case let .verified(clean, _, _) = recipient.prepareIncoming(wire) else {
            XCTFail("Expected an authenticated OMEMO2 final carrier")
            throw OMEMO2StorageError.invalidState
        }
        return clean
    }

    private func assertEncryptedCarrier(_ wire: XMPPMessage, clean: XMPPMessage, row: MessageStorageItem,
                                        sender: String, recipient: String) throws {
        XCTAssertNotNil(wire.element(forName: "encrypted", xmlns: "urn:xmpp:omemo:2"))
        XCTAssertTrue(directReferences(wire).isEmpty, "Forwarded originals and cards belong inside SCE content")
        XCTAssertFalse(wire.body?.contains("original secret") == true)
        XCTAssertEqual(wire.elementID, row.messageId)
        XCTAssertEqual(getOriginId(wire), row.messageId)
        XCTAssertEqual(wire.from?.bare, sender)
        XCTAssertEqual(wire.to?.bare, recipient)
        XCTAssertEqual(SCEReceivePolicy.children(of: wire, named: "encryption", xmlns: "urn:xmpp:eme:0")
            .first?.attributeStringValue(forName: "namespace"), "urn:xmpp:omemo:2")
        let original = try XCTUnwrap(try forwardedMessages(clean).first)
        XCTAssertEqual(original.attributeStringValue(forName: "from"), "author@example.test/laptop")
        XCTAssertEqual(original.attributeStringValue(forName: "id"), "original-encrypted")
        XCTAssertEqual(original.element(forName: "body", xmlns: "jabber:client")?.stringValue, "original secret")
        XCTAssertEqual(original.element(forName: "custom", xmlns: "urn:example:original")?.stringValue, "keep")
        XCTAssertEqual(directReferences(clean).filter { $0.attributeStringValue(forName: "type") == "data" }.count, 1)
        XCTAssertEqual(clean.from?.bare, sender, "Outer authentication does not rewrite the nested original author")
    }
}
