import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

@MainActor
final class ForwardOwnMediaProjectionTests: XCTestCase {
    private var previous: Realm.Configuration!
    private var realm: Realm!
    private var managers: [MessageManager] = []
    private let owner = "forward-media-owner@example.test"
    private let peer = "recipient@example.test"

    override func setUp() {
        super.setUp()
        previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: name)
        realm = try! WRealm.safe()
    }

    override func tearDown() {
        for manager in managers {
            manager.updateSendingMessagesTimer?.invalidate()
            manager.updateSendingMessagesTimer = nil
        }
        realm = nil
        Realm.Configuration.defaultConfiguration = previous
        super.tearDown()
    }

    func testExistingAttachmentFallbackWithMatchingWireRangeIsNotAppendedAgain() {
        let row = MessageStorageItem()
        row.legacyBody = "caption 😀 & text\nhttps://files.example.test/a.jpg"
        let reference = mediaReference()
        reference.begin = "caption 😀 & text\n".xmlEscaping(reverse: false).unicodeScalars.count
        reference.end = row.legacyBody.xmlEscaping(reverse: false).unicodeScalars.count
        row.references.append(reference)

        row.createLegacyBody()
        row.createLegacyBody()

        XCTAssertEqual(row.legacyBody, "caption 😀 & text\nhttps://files.example.test/a.jpg")
        XCTAssertEqual(reference.begin, "caption 😀 & text\n".xmlEscaping(reverse: false).unicodeScalars.count)
        XCTAssertEqual(reference.end, row.legacyBody.xmlEscaping(reverse: false).unicodeScalars.count)
    }

    func testCaptionEqualToAttachmentURLStillGetsItsOwnFallback() {
        let row = MessageStorageItem()
        row.legacyBody = "https://files.example.test/a.jpg"
        let reference = mediaReference()
        row.references.append(reference)

        row.createLegacyBody()

        XCTAssertEqual(row.legacyBody, "https://files.example.test/a.jpg\nhttps://files.example.test/a.jpg")
        XCTAssertEqual(reference.begin, "https://files.example.test/a.jpg\n".unicodeScalars.count)
    }

    func testQuoteDecorationCannotErasePreparedBodyOrOwnFileFallback() {
        let row = MessageStorageItem()
        row.systemMetadata = ["forwardPreparedVersion": 1]
        row.body = "caption"
        row.legacyBody = "> author:\n> original\ncaption"
        row.references.append(mediaReference())
        let quote = MessageReferenceStorageItem()
        quote.kind = .quote
        quote.begin = 0
        quote.end = 7
        row.references.append(quote)

        row.createLegacyBody()

        XCTAssertEqual(row.legacyBody, "> author:\n> original\ncaption\nhttps://files.example.test/a.jpg")
    }

    func testForwardAndOwnReadyMediaKeepOneFallbackAndElideItFromLocalCaption() throws {
        let source = try persistSource(media: false)
        let manager = makeManager()
        let primary = try XCTUnwrap(manager.willSendMediaMessage([mediaReference()], to: peer,
            forwarded: [source], conversationType: .regular, body: "caption", legacyBody: "caption"))
        let row = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
        let raw = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm))

        XCTAssertEqual(row.body, "caption")
        XCTAssertEqual(admittedInlineForwardReferences(in: raw).count, 1)
        XCTAssertEqual((raw.body ?? "").components(separatedBy: "https://files.example.test/a.jpg").count - 1, 1)
        XCTAssertEqual(row.references.filter { $0.kind == .media }.count, 1)
        XCTAssertEqual(row.references.first { $0.kind == .media }?.primary,
                       (row.systemMetadata?["forwardOwnReferencePrimaryIDs"] as? [String])?.first)
    }

    func testHideSenderCarriedRemoteFileIsAlreadyUploadedAndKeepsEncryptionMetadata() throws {
        let source = try persistSource(media: true)
        let manager = makeManager()
        let id = manager.sendSimpleMessage("", to: peer, forwarded: [source], conversationType: .regular,
            forwardOptions: .init(hideSender: true))
        let row = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self,
            forPrimaryKey: MessageStorageItem.genPrimary(messageId: id, owner: owner)))
        let file = try XCTUnwrap(row.references.first { $0.kind == .media })

        XCTAssertTrue(file.isUploaded)
        XCTAssertFalse(MessageManager.retryRequiresMediaUpload(row))
        XCTAssertEqual(file.metadata?["encryption-key"] as? String, "carried-key")
        XCTAssertEqual(file.metadata?["iv"] as? String, "carried-iv")
        XCTAssertEqual(row.body, "original caption")
        manager.retrySending(item: row.primary)
        let raw = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm))
        XCTAssertEqual((raw.body ?? "").components(separatedBy: "https://files.example.test/carried.jpg").count - 1, 1)
    }

    func testHideSenderMixedFilesNeverDuplicateOrReuploadCarriedURL() throws {
        let source = try persistSource(media: true)
        let manager = makeManager()
        let primary = try XCTUnwrap(manager.willSendMediaMessage([mediaReference()], to: peer,
            forwarded: [source], conversationType: .regular, body: "my caption", legacyBody: "my caption",
            forwardOptions: .init(hideSender: true)))
        let row = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
        let raw = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm))
        let ids = try XCTUnwrap(row.systemMetadata?["forwardBatchPrimaryIDs"] as? [String])
        let rows = try ids.map { try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: $0)) }
        let raws = try rows.map { try XCTUnwrap(MessageManager.preparedForwardingContent(for: $0, in: realm)) }

        for uri in ["https://files.example.test/carried.jpg", "https://files.example.test/a.jpg"] {
            XCTAssertEqual(raws.reduce(0) { $0 + (($1.body ?? "").components(separatedBy: uri).count - 1) }, 1)
        }
        XCTAssertEqual(rows.count, 2, "The selected plain content precedes the newly authored media caption")
        XCTAssertEqual(rows.flatMap { Array($0.references).filter { $0.kind == .media } }.count, 2)
        XCTAssertTrue(rows.flatMap { Array($0.references).filter { $0.kind == .media } }.allSatisfy(\.isUploaded))
        XCTAssertTrue(rows.allSatisfy { !MessageManager.retryRequiresMediaUpload($0) })
        XCTAssertTrue(rows.allSatisfy { !$0.body.contains("https://files.example.test/") })
        XCTAssertEqual(rows.first?.body, "original caption")
        XCTAssertEqual(row.body, "my caption")
        XCTAssertEqual(row.state, .uploading)
        XCTAssertEqual(row.systemMetadata?["forwardOwnReferencePrimaryIDs"] as? [String],
                       Array(row.references).filter { $0.kind == .media }.map(\.primary))
        XCTAssertTrue(raw.body?.contains("my caption") == true)
    }

    func testHideSenderOwnFileWithoutCommentFinalizesAlongsideCarriedFileExactlyOnce() throws {
        let source = try persistSource(media: true)
        let manager = makeManager()
        let primary = try XCTUnwrap(manager.willSendMediaMessage([mediaReference()], to: peer,
            forwarded: [source], conversationType: .regular, forwardOptions: .init(hideSender: true)))
        let row = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
        XCTAssertEqual((row.systemMetadata?["forwardBatchPrimaryIDs"] as? [String])?.count, 1)
        XCTAssertEqual(row.references.filter { $0.kind == .media }.count, 2)
        XCTAssertEqual((row.systemMetadata?["forwardOwnReferencePrimaryIDs"] as? [String])?.count, 1)

        manager.retrySending(item: primary)

        let raw = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm))
        for uri in ["https://files.example.test/carried.jpg", "https://files.example.test/a.jpg"] {
            XCTAssertEqual((raw.body ?? "").components(separatedBy: uri).count - 1, 1)
        }
        XCTAssertEqual(row.body, "original caption")
        XCTAssertEqual(row.references.filter { $0.kind == .media }.count, 2)
        XCTAssertTrue(row.references.filter { $0.kind == .media }.allSatisfy(\.isUploaded))
        XCTAssertEqual(row.systemMetadata?["forwardUploadPending"] as? Bool, false)
    }

    func testRetryOfMediaTailWaitsForBlockedDonorThenResumesExistingBatchInOrder() throws {
        let original = try persistSource(media: false)
        let sourceRaw = try XCTUnwrap(realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: original + "_stanza"))
        let source = try XMPPMessage(xmlString: sourceRaw.stanza)
        let donated = try XCTUnwrap(ForwardSendPlanner.plan(sources: [ForwardSourceSnapshot(message: source,
            date: Date(timeIntervalSince1970: 1), selectionID: original)], comment: "").first)
        let wrapper = XMPPMessage(messageType: .chat, to: XMPPJID(string: owner), elementID: "donor", child: nil)
        wrapper.setXmlns("jabber:client")
        wrapper.addAttribute(withName: "from", stringValue: "relay@example.test")
        donated.appendContent(to: wrapper)
        try realm.write { sourceRaw.stanza = wrapper.xmlString }
        let manager = makeManager()
        let primary = try XCTUnwrap(manager.willSendMediaMessage([mediaReference()], to: peer,
            forwarded: [original], conversationType: .regular))
        let row = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
        let ids = try XCTUnwrap(row.systemMetadata?["forwardBatchPrimaryIDs"] as? [String])
        XCTAssertEqual(ids.count, 2)
        let donor = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: try XCTUnwrap(ids.first)))
        let donorRaw = try XCTUnwrap(MessageManager.preparedForwardingContent(for: donor, in: realm)).xmlString
        let pendingRaw = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm)).xmlString
        // A regular text predecessor can be queued without an account. Give
        // this predecessor an actually unavailable encrypted transport so the
        // retry must stop before finalizing or submitting its media tail.
        try realm.write { donor.conversationType = .omemo }

        manager.retrySending(item: primary)

        XCTAssertEqual(donor.state, .error)
        XCTAssertEqual(row.systemMetadata?["forwardUploadPending"] as? Bool, true)
        XCTAssertEqual(row.state, .uploading)
        XCTAssertTrue(realm.objects(OutgoingMessageQueueItem.self).isEmpty)
        XCTAssertEqual(try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm)).xmlString, pendingRaw)

        // Restore an available transport in the fixture. Retrying the tail
        // resumes its unsubmitted donor first using the already admitted IDs.
        try realm.write {
            donor.conversationType = .regular
            donor.messageError = nil
            donor.messageErrorCode = nil
        }
        manager.retrySending(item: primary)

        XCTAssertEqual(row.systemMetadata?["forwardUploadPending"] as? Bool, false)
        XCTAssertEqual(row.state, .sending)
        XCTAssertEqual(try XCTUnwrap(MessageManager.preparedForwardingContent(for: donor, in: realm)).xmlString, donorRaw)
        XCTAssertEqual(row.systemMetadata?["forwardBatchPrimaryIDs"] as? [String], ids)
        XCTAssertEqual(realm.objects(OutgoingMessageQueueItem.self).sorted(byKeyPath: "createdOrder").map(\.messagePrimary), ids)
        XCTAssertEqual(realm.objects(MessageStorageItem.self).filter("owner == %@ AND outgoing == true", owner).count, 2)

        manager.retrySending(item: primary)

        XCTAssertEqual(realm.objects(OutgoingMessageQueueItem.self).sorted(byKeyPath: "createdOrder").map(\.messagePrimary), ids)
    }

    func testUploadFinalizationKeepsWireMarkupAndRebasesLocalCaptionMarkup() throws {
        let source = try persistSource(media: false)
        let manager = makeManager()
        let markup = MessageReferenceStorageItem()
        markup.kind = .markup
        markup.begin = 0
        markup.end = 7
        markup.metadata = ["styles": ["bold"]]
        let primary = try XCTUnwrap(manager.willSendMediaMessage([markup, mediaReference()], to: peer,
            forwarded: [source], conversationType: .regular, body: "caption", legacyBody: "caption"))
        let row = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
        let before = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm))
        let beforeMarkup = try XCTUnwrap(SCEReceivePolicy.children(of: before, named: "reference",
            xmlns: "https://xabber.com/protocol/references").first { getReferenceType($0) == "markup" })
        XCTAssertGreaterThan(beforeMarkup.attributeIntegerValue(forName: "begin"), 0)

        manager.retrySending(item: primary)

        XCTAssertEqual(row.systemMetadata?["forwardUploadPending"] as? Bool, false)
        XCTAssertEqual(row.body, "caption")
        let local = try XCTUnwrap(row.references.first { $0.kind == .markup })
        XCTAssertEqual(local.begin, 0)
        XCTAssertEqual(local.end, 7)
        let after = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm))
        let afterMarkup = try XCTUnwrap(SCEReceivePolicy.children(of: after, named: "reference",
            xmlns: "https://xabber.com/protocol/references").first { getReferenceType($0) == "markup" })
        XCTAssertEqual(afterMarkup.attributeIntegerValue(forName: "begin"), beforeMarkup.attributeIntegerValue(forName: "begin"))
        XCTAssertEqual(afterMarkup.attributeIntegerValue(forName: "end"), beforeMarkup.attributeIntegerValue(forName: "end"))
        XCTAssertEqual((after.body ?? "").components(separatedBy: "https://files.example.test/a.jpg").count - 1, 1)
        XCTAssertEqual(admittedInlineForwardReferences(in: after).count, 1)
    }

    func testOversizedOwnFileDescriptorRejectsWholeBatchBeforePersistenceOrPublication() throws {
        let source = try persistSource(media: false)
        let manager = makeManager()
        let file = mediaReference()
        file.metadata = ["media-type": "image/jpeg", "name": String(repeating: "😀&", count: 10_000)]
        var admissions: [ChatTimelineLocalOutgoingAdmission] = []
        manager.localOutgoingAdmissionPublisher = { admissions.append($0) }

        let primary = manager.willSendMediaMessage([file], to: peer, forwarded: [source],
            conversationType: .regular, body: "caption", legacyBody: "caption")

        XCTAssertNil(primary)
        XCTAssertTrue(realm.objects(MessageStorageItem.self).filter("owner == %@ AND outgoing == true", owner).isEmpty)
        XCTAssertTrue(admissions.isEmpty)
        XCTAssertNil(file.realm)
        XCTAssertTrue(realm.objects(MessageReferenceStorageItem.self).isEmpty)
        XCTAssertEqual(realm.objects(MessageStanzaStorageItem.self).count, 1)
    }

    func testOversizedDescriptorAfterUploadKeepsPendingSnapshotAndCannotReachTransport() throws {
        let source = try persistSource(media: false)
        let manager = makeManager()
        let primary = try XCTUnwrap(manager.willSendMediaMessage([mediaReference()], to: peer, forwarded: [source],
            conversationType: .regular, body: "caption", legacyBody: "caption"))
        let row = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
        let before = try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm)).xmlString
        let file = try XCTUnwrap(row.references.first { $0.kind == .media })
        try realm.write {
            var metadata = file.metadata ?? [:]
            metadata["name"] = String(repeating: "😀&", count: 10_000)
            file.metadata = metadata
        }

        manager.retrySending(item: primary)

        XCTAssertEqual(row.systemMetadata?["forwardUploadPending"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(MessageManager.preparedForwardingContent(for: row, in: realm)).xmlString, before)
        XCTAssertTrue(realm.objects(OutgoingMessageQueueItem.self).filter("messagePrimary == %@", primary).isEmpty)
    }

    private func makeManager() -> MessageManager {
        let manager = MessageManager(withOwner: owner, activeStream: false)
        managers.append(manager)
        return manager
    }

    private func persistSource(media: Bool) throws -> String {
        let uri = "https://files.example.test/carried.jpg"
        let caption = "original caption"
        let body = media ? caption + "\n" + uri : caption
        let file = media ? """
        <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='\((caption + "\n").unicodeScalars.count)' end='\(body.unicodeScalars.count)'>
          <file-sharing xmlns='https://xabber.com/protocol/files'><file><media-type>image/jpeg</media-type>
            <name>carried.jpg</name><encrypted xmlns='urn:xmpp:esfs:0'><key>carried-key</key><iv>carried-iv</iv></encrypted>
          </file><sources><uri>\(uri)</uri></sources></file-sharing>
        </reference>
        """ : ""
        let xml = "<message xmlns='jabber:client' from='author@example.test/phone' to='\(owner)' type='chat' id='source'><body>\(body)</body>\(file)</message>"
        let row = MessageStorageItem()
        row.primary = "source-primary"
        row.owner = owner
        row.opponent = "author@example.test"
        row.messageId = "source"
        row.sentDate = Date(timeIntervalSince1970: 1)
        let raw = MessageStanzaStorageItem()
        raw.set(row.messageId, for: owner, with: xml, at: row.sentDate, primary: row.primary)
        try realm.write { realm.add(row); realm.add(raw) }
        return row.primary
    }

    private func mediaReference() -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.kind = .media
        reference.mimeType = "image/jpeg"
        reference.metadata = ["media-type": "image/jpeg", "name": "a.jpg"]
        reference.isUploaded = true
        reference.url = "https://files.example.test/a.jpg"
        return reference
    }
}
