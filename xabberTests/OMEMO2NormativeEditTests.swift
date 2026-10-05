import Foundation
import RealmSwift
import SignalProtocolObjC
import XMPPFramework
import XCTest
@testable import xabber

/// N03 exercises the final rewrite sender, including real provider ciphertext.
/// The server-visible IQ stays open; replacement user content is protected.
final class OMEMO2NormativeEditTests: XCTestCase {
    private let referenceNamespace = "https://xabber.com/protocol/references"
    private var previousRealm: Realm.Configuration!

    override func setUp() {
        super.setUp()
        previousRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "NormativeEdit-\(UUID().uuidString)")
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousRealm
        super.tearDown()
    }

    func testEncryptedReplacementUsesRealCiphertextAndPreservesRewriteRoutingForEveryEncryptedKind() throws {
        for type in [ClientSynchronizationManager.ConversationType.omemo, .omemo1, .axolotl] {
            let fixture = try fixture()
            try withAccount(fixture.alice) { account in
                let item = try storedMessage(owner: fixture.alice.owner, jid: fixture.bob.owner, type: type)
                let replacement = try replacementMessage(item: item, body: "private corrected text")
                let originalXML = replacement.xmlString
                let stream = CapturingStream()

                account.msgDeleteManager.editMessage(stream, primary: item.primary, editedMessage: replacement, conversationType: type)

                XCTAssertEqual(stream.iqs.count, 1, type.rawValue)
                let iq = try XCTUnwrap(stream.iqs.first)
                let replace = try XCTUnwrap(iq.element(forName: "replace", xmlns: MessageDeleteManager.namespace))
                let wire = try replacementWire(in: iq)
                XCTAssertEqual(wire.uri, MessageDeleteManager.namespace, "Pinned server codec decodes the replacement message in the rewrite namespace")
                XCTAssertEqual(SCEReceivePolicy.children(of: wire, named: "body", xmlns: MessageDeleteManager.namespace).count, 1, "Fallback is the server codec's replacement body")
                XCTAssertTrue(SCEReceivePolicy.children(of: wire, named: "body", xmlns: "jabber:client").isEmpty)
                XCTAssertEqual(replace.attributeStringValue(forName: "id"), item.archivedId)
                XCTAssertEqual(replace.attributeStringValue(forName: "type"), type.rawValue)
                XCTAssertEqual(iq.to?.bare, item.owner)
                XCTAssertEqual(iq.from?.bare, item.owner)
                XCTAssertEqual(wire.from?.bare, item.owner)
                XCTAssertEqual(wire.to?.bare, item.opponent)
                XCTAssertEqual(wire.elementID, item.messageId)
                XCTAssertEqual(getOriginId(wire), item.messageId)
                XCTAssertEqual(getStanzaId(wire, owner: item.owner), item.archivedId)
                XCTAssertFalse(iq.xmlString.contains("private corrected text"))
                XCTAssertFalse(iq.xmlString.contains("https://example.test/private-edit.jpg"))
                XCTAssertTrue(SCEReceivePolicy.children(of: wire, named: "reference", xmlns: referenceNamespace).isEmpty)
                XCTAssertNotNil(wire.body, "Existing encrypted-message fallback remains")
                XCTAssertNil(wire.element(forName: "store", xmlns: "urn:xmpp:hints"))
                XCTAssertEqual(wire.element(forName: "encryption", xmlns: "urn:xmpp:eme:0")?.attributeStringValue(forName: "namespace"), "urn:xmpp:omemo:2")
                XCTAssertNotNil(wire.element(forName: "encrypted", xmlns: "urn:xmpp:omemo:2"))
                XCTAssertNil(SCEReceivePolicy.children(of: iq, named: "encryption", xmlns: "urn:xmpp:eme:0").first)
                XCTAssertEqual(replacement.xmlString, originalXML, "Sender must not mutate the caller's draft")
                guard case let .verified(clean, proof) = fixture.bob.prepareIncoming(wire) else {
                    return XCTFail("Expected a genuine decryptable replacement for \(type.rawValue)")
                }
                XCTAssertTrue(proof.isAuthenticated)
                XCTAssertEqual(clean.body, "private corrected text")
                let reference = try XCTUnwrap(SCEReceivePolicy.children(of: clean, named: "reference", xmlns: referenceNamespace).first)
                XCTAssertTrue(reference.xmlString.contains("https://example.test/private-edit.jpg"))
                XCTAssertEqual(getOriginId(clean), item.messageId)
            }
        }
    }

    func testEncryptionFailureDoesNotSendReplacementOrRegisterRequest() throws {
        let fixture = try fixture()
        try withAccount(fixture.alice) { account in
            let item = try storedMessage(owner: fixture.alice.owner, jid: fixture.bob.owner, type: .omemo)
            let replacement = try replacementMessage(item: item, body: "must never escape")
            let realm = try WRealm.safe()
            let devices = realm.objects(SignalDeviceStorageItem.self).filter("owner == %@ AND jid == %@", fixture.alice.owner, fixture.bob.owner)
            try realm.write { devices.forEach { $0.state = .distrusted } }
            let stream = CapturingStream()
            let pendingBefore = account.msgDeleteManager.queryIds.filter { _ in true }

            account.msgDeleteManager.editMessage(stream, primary: item.primary, editedMessage: replacement, conversationType: .omemo)

            XCTAssertTrue(stream.iqs.isEmpty)
            XCTAssertEqual(account.msgDeleteManager.queryIds.filter { _ in true }, pendingBefore)
            XCTAssertEqual(item.messageErrorCode, "omemo")
        }
    }

    func testUIEditBuilderReachesEncryptedRewriteSenderWithOriginalIdentifiersAndReferences() throws {
        let fixture = try fixture()
        try withAccount(fixture.alice) { account in
            let item = try storedMessage(owner: fixture.alice.owner, jid: fixture.bob.owner, type: .omemo)
            try storeOriginal(item, xmlID: item.messageId, originID: item.messageId, from: item.owner, to: item.opponent)
            let reference = MessageReferenceStorageItem()
            reference.kind = .media
            reference.begin = 0
            reference.end = 0
            reference.metadata = ["uri": "https://example.test/private-edit.jpg", "name": "private-edit.jpg", "media-type": "image/jpeg"]
            let stream = CapturingStream()
            let ui = XMPPUIActionManager.shared
            let previousOwner = ui.currentJid
            let previousStream = ui.stream
            let previousRetract = ui.retract
            let previousMessages = ui.messages
            let previousMAM = ui.mam
            // The lifecycle coordinator owns a separate currentOwner. The
            // existing pending-auth seam stages it without opening a socket;
            // an authenticated capture stream then uses the real ready path.
            ui.preparePendingAuthenticationForTests(owner: fixture.alice.owner, stream: stream, archiveManager: account.mam, messageManager: account.messages)
            ui.queue.sync {
                ui.retract = account.msgDeleteManager
            }
            defer {
                ui.resetPendingAuthenticationForTests()
                ui.queue.sync {
                    ui.currentJid = previousOwner
                    ui.stream = previousStream
                    ui.retract = previousRetract
                    ui.messages = previousMessages
                    ui.mam = previousMAM
                }
            }
            let sent = expectation(description: "UI edit reaches final rewrite IQ")
            stream.onIQ = { _ in sent.fulfill() }

            account.messages.editSimpleMessage("private UI correction", primary: item.primary, references: [reference])
            wait(for: [sent], timeout: 3)

            let iq = try XCTUnwrap(stream.iqs.first)
            let replace = try XCTUnwrap(iq.element(forName: "replace", xmlns: MessageDeleteManager.namespace))
            let wire = try replacementWire(in: iq)
            XCTAssertEqual(wire.elementID, item.messageId)
            XCTAssertEqual(wire.from?.bare, item.owner)
            XCTAssertEqual(wire.to?.bare, item.opponent)
            XCTAssertEqual(getOriginId(wire), item.messageId)
            XCTAssertFalse(iq.xmlString.contains("private UI correction"))
            XCTAssertFalse(iq.xmlString.contains("https://example.test/private-edit.jpg"))
            guard case let .verified(clean, _) = fixture.bob.prepareIncoming(wire) else { return XCTFail("Expected decryptable UI edit") }
            XCTAssertEqual(clean.body, "private UI correction")
            XCTAssertEqual(SCEReceivePolicy.children(of: clean, named: "reference", xmlns: referenceNamespace).count, 1)
        }
    }

    func testUIEditRestoresPersistedOriginalResourcesWireIDOriginAndThreadAfterRematerialization() throws {
        for legacyStreamNamespace in [false, true] {
            let f = try fixture()
            try withAccount(f.alice) { account in
                let item = try storedMessage(owner: f.alice.owner, jid: f.bob.owner, type: .omemo)
                let from = "\(item.owner)/original-phone"
                let to = "\(item.opponent)/original-desktop"
                let raw = try storeOriginal(item, xmlID: "original-xml-id", originID: item.messageId, from: from, to: to, thread: "original-thread")
                if legacyStreamNamespace {
                    let realm = try WRealm.safe()
                    try realm.write { raw.stanza = raw.stanza.replacingOccurrences(of: " xmlns='jabber:client'", with: "") }
                }
                item.originalStanza = nil
                XCTAssertNil(item.originalStanza)
                let stream = CapturingStream()
                try withUIActionStream(account, stream: stream) {
                    let sent = expectation(description: "Persisted original identity reaches rewrite IQ")
                    stream.onIQ = { _ in sent.fulfill() }

                    account.messages.editSimpleMessage("corrected after reopening", primary: item.primary)
                    wait(for: [sent], timeout: 3)

                    let iq = try XCTUnwrap(stream.iqs.first)
                    let replace = try XCTUnwrap(iq.element(forName: "replace", xmlns: MessageDeleteManager.namespace))
                    let wire = try replacementWire(in: iq)
                    XCTAssertEqual(wire.from?.full, from)
                    XCTAssertEqual(wire.to?.full, to)
                    XCTAssertEqual(wire.elementID, "original-xml-id", "XML id and origin-id are distinct identifiers")
                    XCTAssertEqual(getOriginId(wire), item.messageId)
                    XCTAssertEqual(SCEReceivePolicy.children(of: wire, named: "thread", xmlns: "jabber:client").first?.stringValue, "original-thread", "Immutable server-visible thread is preserved")
                    XCTAssertEqual(replace.attributeStringValue(forName: "id"), item.archivedId)
                    XCTAssertEqual(raw.stanza.contains("original-xml-id"), true)
                    guard case let .verified(clean, _) = f.bob.prepareIncoming(wire) else { return XCTFail("Expected authentic persisted-identity edit") }
                    XCTAssertEqual(clean.body, "corrected after reopening")
                    XCTAssertEqual(SCEReceivePolicy.children(of: clean, named: "thread", xmlns: "jabber:client").first?.stringValue, "original-thread")
                }
            }
        }
    }

    func testEncryptedUIEditWithoutUsableOriginalXMLUsesKnownConversationRoutingWithoutInventingMetadata() throws {
        let unavailableOriginals: [String?] = [nil, "<message", "<message xmlns='urn:foreign' from='alice@example.test' to='bob@example.test' id='foreign-id'/>"]
        for unavailable in unavailableOriginals {
            let f = try fixture()
            try withAccount(f.alice) { account in
                let item = try storedMessage(owner: f.alice.owner, jid: f.bob.owner, type: .omemo)
                item.originalStanza = nil
                if let unavailable {
                    let raw = MessageStanzaStorageItem()
                    raw.set(item.messageId, for: item.owner, with: unavailable, at: item.date, primary: item.primary)
                    let realm = try WRealm.safe()
                    try realm.write { realm.add(raw) }
                }
                let stream = CapturingStream()
                try withUIActionStream(account, stream: stream) {
                    let sent = expectation(description: "Known archive and conversation permit encrypted replacement")
                    stream.onIQ = { _ in sent.fulfill() }

                    account.messages.editSimpleMessage("protected correction without raw XML", primary: item.primary)
                    wait(for: [sent], timeout: 3)

                    let iq = try XCTUnwrap(stream.iqs.first)
                    let replace = try XCTUnwrap(iq.element(forName: "replace", xmlns: MessageDeleteManager.namespace))
                    let wire = try replacementWire(in: iq)
                    XCTAssertEqual(replace.attributeStringValue(forName: "id"), item.archivedId)
                    XCTAssertEqual(wire.from?.full, item.owner)
                    XCTAssertEqual(wire.to?.full, item.opponent)
                    XCTAssertNil(wire.elementID, "No unknown original XML identifier is synthesized")
                    XCTAssertTrue(SCEReceivePolicy.children(of: wire, named: "origin-id", xmlns: "urn:xmpp:sid:0").isEmpty)
                    XCTAssertTrue(SCEReceivePolicy.children(of: wire, named: "thread", xmlns: "jabber:client").isEmpty)
                    XCTAssertFalse(iq.xmlString.contains("protected correction without raw XML"))
                    guard case let .verified(clean, _) = f.bob.prepareIncoming(wire) else { return XCTFail("Expected authentic edit using known bare routing") }
                    XCTAssertEqual(clean.body, "protected correction without raw XML")
                    XCTAssertTrue(SCEReceivePolicy.children(of: clean, named: "origin-id", xmlns: "urn:xmpp:sid:0").isEmpty)
                    XCTAssertTrue(SCEReceivePolicy.children(of: clean, named: "thread", xmlns: "jabber:client").isEmpty)
                }
            }
        }
    }

    func testEncryptedRewriteNotificationAndMAMUseReplacementTimeAndRetainOriginalArchiveTime() throws {
        for route in ["rewrite", "mam"] {
            let fixture = try fixture()
            try withAccount(fixture.alice) { account in
                let item = try storedMessage(owner: fixture.alice.owner, jid: fixture.bob.owner, type: .omemo)
                let stream = CapturingStream()
                account.msgDeleteManager.editMessage(stream, primary: item.primary, editedMessage: try replacementMessage(item: item, body: "edited one hour later"), conversationType: .omemo)
                let iq = try XCTUnwrap(stream.iqs.first)
                let replacement = try XCTUnwrap(iq.element(forName: "replace", xmlns: MessageDeleteManager.namespace))
                let wire = try serverMessage(from: replacementWire(in: iq), xmlns: route == "rewrite" ? "https://xabber.com/protocol/rewrite#notify" : "jabber:client")
                XCTAssertNotNil(wire.element(forName: "encrypted", xmlns: "urn:xmpp:omemo:2"))
                let originalStamp = Date().addingTimeInterval(-3_600).XMPPFormattedDate
                let replacementStamp = Date().XMPPFormattedDate
                let replacementDate = try XCTUnwrap(replacementStamp.xmppDate)
                wire.addChild(try DDXMLElement(xmlString: "<time xmlns='https://xabber.com/protocol/delivery' stamp='\(originalStamp)'/>"))
                wire.addChild(try DDXMLElement(xmlString: "<r:replaced xmlns:r='\(MessageDeleteManager.namespace)' stamp='\(replacementStamp)'/>"))
                let packet: XMPPMessage
                if route == "rewrite" {
                    packet = XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' from='\(fixture.bob.owner)' to='\(fixture.bob.owner)' type='headline'><replace xmlns='https://xabber.com/protocol/rewrite#notify' conversation='\(fixture.alice.owner)' type='urn:xmpp:omemo:2' id='\(item.archivedId)' version='2'>\(wire.xmlString)</replace></message>"))
                } else {
                    packet = XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' from='\(fixture.bob.owner)' to='\(fixture.bob.owner)'><result xmlns='urn:xmpp:mam:2' id='edited-archive' queryid='edit-query'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='\(originalStamp)'/>\(wire.xmlString)</forwarded></result></message>"))
                }

                XCTAssertEqual(try OmemoManager.originalSendingTime(for: packet, owner: fixture.bob.owner)?.date, replacementDate, route)
                guard case let .verified(clean, proof) = fixture.bob.prepareIncoming(packet, context: route == "mam" ? .archive : .live) else {
                    return XCTFail("Expected authentic edit despite original archive time being an hour old: \(route)")
                }
                let inner: XMPPMessage
                if route == "rewrite" {
                    let replace = try XCTUnwrap(SCEReceivePolicy.children(of: clean, named: "replace", xmlns: "https://xabber.com/protocol/rewrite#notify").first)
                    inner = XMPPMessage(from: try XCTUnwrap(SCEReceivePolicy.children(of: replace, named: "message", xmlns: "https://xabber.com/protocol/rewrite#notify").first))
                    let received = try storedMessage(owner: fixture.bob.owner, jid: fixture.alice.owner, type: .omemo)
                    let receiver = MessageDeleteManager(withOwner: fixture.bob.owner)
                    XCTAssertTrue(receiver.readRewriteNotify(clean, encryption: proof))
                    XCTAssertEqual(received.body, "edited one hour later")
                    XCTAssertEqual(received.editDate, replacementDate)
                    XCTAssertTrue(proof.isAuthenticated)
                    XCTAssertEqual(replace.attributeStringValue(forName: "version"), "2")
                } else {
                    inner = try XCTUnwrap(getArchivedMessageContainer(clean))
                    XCTAssertEqual(getMAMQueryId(clean), "edit-query")
                    XCTAssertTrue(clean.xmlString.contains("stamp=\"\(originalStamp)\""), "MAM's original timeline date is preserved")
                }
                XCTAssertEqual(inner.body, "edited one hour later")
                XCTAssertEqual(SCEReceivePolicy.children(of: inner, named: "time", xmlns: "https://xabber.com/protocol/delivery").first?.attributeStringValue(forName: "stamp"), originalStamp)
                XCTAssertEqual(SCEReceivePolicy.children(of: inner, named: "replaced", xmlns: MessageDeleteManager.namespace).first?.attributeStringValue(forName: "stamp"), replacementStamp)
                XCTAssertEqual(getStanzaId(inner, owner: item.owner), item.archivedId)
            }
        }
    }

    func testDirectExternalReplacementMarkerCannotAffectAuthenticatedMessageSemantics() throws {
        for namespace in [MessageDeleteManager.namespace, "urn:foreign"] {
            let f = try fixture()
            let wire = try sentEncryptedReplacement(f, body: "ordinary authenticated content")
            let originalStamp = Date().XMPPFormattedDate
            wire.addChild(try DDXMLElement(xmlString: "<time xmlns='https://xabber.com/protocol/delivery' stamp='\(originalStamp)'/>"))
            wire.addChild(try DDXMLElement(xmlString: "<r:replaced xmlns:r='\(namespace)' stamp='2001-01-01T00:00:00Z'/>"))

            XCTAssertEqual(try OmemoManager.originalSendingTime(for: wire, owner: f.bob.owner)?.date, originalStamp.xmppDate)
            guard case let .verified(clean, proof) = f.bob.prepareIncoming(wire) else { return XCTFail("External direct marker must remain semantically inactive") }
            XCTAssertTrue(proof.isAuthenticated)
            XCTAssertEqual(clean.body, "ordinary authenticated content")
            XCTAssertTrue(SCEReceivePolicy.children(of: clean, named: "replaced", xmlns: namespace).isEmpty)
            XCTAssertFalse(MessageDeleteManager(withOwner: f.bob.owner).readRewriteNotify(clean, encryption: proof))
        }
    }

    func testUntrustedDirectRewriteAndMAMReplacementMarkersCannotBypassOriginalTimeBinding() throws {
        for route in ["direct", "rewrite", "mam"] {
            let f = try fixture()
            let wire = try sentEncryptedReplacement(f, body: "fresh ciphertext")
            let originalStamp = Date().addingTimeInterval(-3_600).XMPPFormattedDate
            wire.addChild(try DDXMLElement(xmlString: "<time xmlns='https://xabber.com/protocol/delivery' stamp='\(originalStamp)'/>"))
            wire.addChild(try DDXMLElement(xmlString: "<replaced xmlns='\(MessageDeleteManager.namespace)' stamp='\(Date().XMPPFormattedDate)'/>"))
            let packet = try serverPacket(route: route, fixture: f, wire: wire, from: f.alice.owner, originalStamp: originalStamp)
            let before = f.memory.records[f.bob.owner]

            XCTAssertEqual(try OmemoManager.originalSendingTime(for: packet, owner: f.bob.owner)?.date, originalStamp.xmppDate, route)
            guard case let .failed(clean, _) = f.bob.prepareIncoming(packet, context: route == "mam" ? .archive : .live) else { return XCTFail("Untrusted \(route) metadata must not authorize the fresh edit time") }
            XCTAssertEqual(f.memory.records[f.bob.owner], before)
            let leaf = try receiveLeaf(clean, route: route)
            XCTAssertNil(leaf.body)
            XCTAssertTrue(SCEReceivePolicy.children(of: leaf, named: "replaced", xmlns: MessageDeleteManager.namespace).isEmpty)
        }
    }

    func testForeignReplacementMarkerInTrustedTransportCannotProvideTimeBinding() throws {
        for route in ["rewrite", "mam"] {
            let f = try fixture()
            let wire = try sentEncryptedReplacement(f, body: "fresh ciphertext")
            let originalStamp = Date().addingTimeInterval(-3_600).XMPPFormattedDate
            wire.addChild(try DDXMLElement(xmlString: "<time xmlns='https://xabber.com/protocol/delivery' stamp='\(originalStamp)'/>"))
            wire.addChild(try DDXMLElement(xmlString: "<replaced xmlns='urn:foreign' stamp='\(Date().XMPPFormattedDate)'/>"))
            let packet = try serverPacket(route: route, fixture: f, wire: wire, originalStamp: originalStamp)
            let before = f.memory.records[f.bob.owner]

            XCTAssertEqual(try OmemoManager.originalSendingTime(for: packet, owner: f.bob.owner)?.date, originalStamp.xmppDate, route)
            guard case let .failed(clean, _) = f.bob.prepareIncoming(packet, context: route == "mam" ? .archive : .live) else { return XCTFail("Foreign QName cannot mark an archived replacement") }
            XCTAssertEqual(f.memory.records[f.bob.owner], before)
            XCTAssertTrue(SCEReceivePolicy.children(of: try receiveLeaf(clean, route: route), named: "replaced", xmlns: "urn:foreign").isEmpty)
        }
    }

    func testMalformedServerReplacementMetadataFailsBeforeRatchetCommit() throws {
        let validStamp = Date().XMPPFormattedDate
        let malformed = [
            "<replaced xmlns='\(MessageDeleteManager.namespace)' stamp='not-a-date'/>",
            "<replaced xmlns='\(MessageDeleteManager.namespace)'/>",
            "<replaced xmlns='\(MessageDeleteManager.namespace)' stamp='\(validStamp)'><body xmlns='jabber:client'>fake</body></replaced>",
            "<replaced xmlns='\(MessageDeleteManager.namespace)' stamp='\(validStamp)'/><replaced xmlns='\(MessageDeleteManager.namespace)' stamp='\(validStamp)'/>"
        ]
        for metadata in malformed {
            let f = try fixture()
            let wire = try sentEncryptedReplacement(f, body: "authenticated ciphertext")
            let originalStamp = Date().XMPPFormattedDate
            wire.addChild(try DDXMLElement(xmlString: "<time xmlns='https://xabber.com/protocol/delivery' stamp='\(originalStamp)'/>"))
            let holder = try DDXMLElement(xmlString: "<holder>\(metadata)</holder>")
            for child in holder.children?.compactMap({ $0 as? DDXMLElement }) ?? [] { wire.addChild(child.copy() as! DDXMLElement) }
            let packet = try serverPacket(route: "rewrite", fixture: f, wire: wire, originalStamp: originalStamp)
            let before = f.memory.records[f.bob.owner]

            XCTAssertThrowsError(try OmemoManager.originalSendingTime(for: packet, owner: f.bob.owner), metadata)
            guard case let .failed(clean, _) = f.bob.prepareIncoming(packet) else { return XCTFail("Malformed server replacement metadata must fail closed") }
            XCTAssertEqual(f.memory.records[f.bob.owner], before)
            let leaf = try receiveLeaf(clean, route: "rewrite")
            XCTAssertNil(leaf.body)
            XCTAssertTrue(SCEReceivePolicy.children(of: leaf, named: "replaced", xmlns: MessageDeleteManager.namespace).isEmpty)
        }
    }

    func testMissingProviderFailsClosedForEncryptedReplacement() throws {
        let owner = "no-provider-\(UUID().uuidString.lowercased())@example.test"
        let item = try storedMessage(owner: owner, jid: "bob@example.test", type: .omemo)
        let manager = MessageDeleteManager(withOwner: owner)
        let stream = CapturingStream()

        manager.editMessage(stream, primary: item.primary, editedMessage: try replacementMessage(item: item, body: "private"), conversationType: .omemo)

        XCTAssertTrue(stream.iqs.isEmpty)
        XCTAssertTrue(manager.queryIds.isEmpty)
        XCTAssertEqual(item.messageErrorCode, "omemo")
    }

    func testStoredEncryptedKindCannotBeDowngradedByCallerConversationArgument() throws {
        let owner = "no-provider-\(UUID().uuidString.lowercased())@example.test"
        let item = try storedMessage(owner: owner, jid: "bob@example.test", type: .omemo)
        let manager = MessageDeleteManager(withOwner: owner)
        let stream = CapturingStream()

        manager.editMessage(stream, primary: item.primary, editedMessage: try replacementMessage(item: item, body: "private"), conversationType: .regular)

        XCTAssertTrue(stream.iqs.isEmpty, "Stored conversation identity controls encryption")
    }

    func testOrdinaryReplacementRemainsPlaintextWithOriginalReferencesAndRouting() throws {
        let item = try storedMessage(owner: "alice@example.test", jid: "bob@example.test", type: .regular)
        let replacement = try replacementMessage(item: item, body: "ordinary correction")
        let manager = MessageDeleteManager(withOwner: item.owner)
        let stream = CapturingStream()

        manager.editMessage(stream, primary: item.primary, editedMessage: replacement, conversationType: .regular)

        let iq = try XCTUnwrap(stream.iqs.first)
        let replace = try XCTUnwrap(iq.element(forName: "replace", xmlns: MessageDeleteManager.namespace))
        let wire = try replacementWire(in: iq)
        XCTAssertEqual(wire.uri, MessageDeleteManager.namespace)
        XCTAssertEqual(SCEReceivePolicy.children(of: wire, named: "body", xmlns: MessageDeleteManager.namespace).first?.stringValue, "ordinary correction")
        XCTAssertEqual(replace.attributeStringValue(forName: "id"), item.archivedId)
        XCTAssertEqual(replace.attributeStringValue(forName: "type"), ClientSynchronizationManager.ConversationType.regular.rawValue)
        XCTAssertEqual(iq.to?.bare, item.owner)
        XCTAssertEqual(wire.body, "ordinary correction")
        XCTAssertNotNil(wire.element(forName: "reference", xmlns: referenceNamespace))
        XCTAssertNil(wire.element(forName: "encrypted"))
        XCTAssertNil(wire.element(forName: "encryption", xmlns: "urn:xmpp:eme:0"))
        XCTAssertEqual(getOriginId(wire), item.messageId)
    }

    func testActualServerPlaintextRewriteNotifyBodyIsAppliedAndForeignQNameStaysInactive() throws {
        for bodyNamespace in ["https://xabber.com/protocol/rewrite#notify", "urn:foreign"] {
            let owner = "notify-bob-\(UUID().uuidString.lowercased())@example.test"
            let peer = "alice@example.test"
            let item = try storedMessage(owner: owner, jid: peer, type: .regular)
            let originalBody = item.body
            let originalEditDate = item.editDate
            let stamp = Date().addingTimeInterval(1).XMPPFormattedDate
            // Pinned xmpplibrary 37c58c935464d8c2b7fa67b85fba3bed0eaeeba1
            // xep_rewrite.erl772–798 encodes a notify message/body in its wrapper
            // namespace and transmits optional from/to, without XML id/type.
            let packet = XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' from='\(owner)' to='\(owner)' type='headline'><replace xmlns='https://xabber.com/protocol/rewrite#notify' conversation='\(peer)' type='\(ClientSynchronizationManager.ConversationType.regular.rawValue)' id='\(item.archivedId)' version='2'><message from='\(peer)' to='\(owner)'><body xmlns='\(bodyNamespace)'>server plain correction</body><replaced xmlns='\(MessageDeleteManager.namespace)' stamp='\(stamp)'/></message></replace></message>"))
            let receiver = MessageDeleteManager(withOwner: owner)

            let handled = receiver.readRewriteNotify(packet)

            if bodyNamespace == "urn:foreign" {
                XCTAssertEqual(item.body, originalBody, "Foreign body cannot trigger an edit")
                XCTAssertEqual(item.editDate, originalEditDate)
            } else {
                XCTAssertTrue(handled)
                XCTAssertEqual(item.body, "server plain correction")
                XCTAssertEqual(item.editDate, stamp.xmppDate)
            }
        }
    }

    private func storedMessage(owner: String, jid: String, type: ClientSynchronizationManager.ConversationType) throws -> MessageStorageItem {
        let item = MessageStorageItem()
        item.owner = owner
        item.opponent = jid
        item.messageId = "original-\(UUID().uuidString)"
        item.primary = MessageStorageItem.genPrimary(messageId: item.messageId, owner: owner)
        item.archivedId = "archive-original"
        item.conversationType = type
        item.body = "before correction"
        item.legacyBody = item.body
        item.outgoing = true
        item.date = Date()
        item.sentDate = item.date
        item.editDate = item.date
        let realm = try WRealm.safe()
        try realm.write { realm.add(item) }
        return item
    }

    private func replacementMessage(item: MessageStorageItem, body: String) throws -> XMPPMessage {
        let message = XMPPMessage(type: "chat", to: XMPPJID(string: item.opponent), elementID: item.messageId)
        message.addNamespace(DDXMLNode.namespace(withName: "", stringValue: "jabber:client") as! DDXMLNode)
        message.addAttribute(withName: "from", stringValue: item.owner)
        let bodyElement = DDXMLElement(name: "body", xmlns: "jabber:client")
        bodyElement.stringValue = body
        message.addChild(bodyElement)
        message.addOriginId(item.messageId)
        let reference = try DDXMLElement(xmlString: "<reference xmlns='\(referenceNamespace)' type='mutable'><file-sharing xmlns='https://xabber.com/protocol/files'><file><name>private-edit.jpg</name></file><sources><uri>https://example.test/private-edit.jpg</uri></sources></file-sharing></reference>")
        message.addChild(reference)
        let id = DDXMLElement(name: "stanza-id", xmlns: "urn:xmpp:sid:0")
        id.addAttribute(withName: "by", stringValue: item.owner)
        id.addAttribute(withName: "id", stringValue: item.archivedId)
        message.addChild(id)
        return message
    }

    private func withAccount(_ omemo: OmemoManager, body: (Account) throws -> Void) throws {
        let account = Account(jid: omemo.owner, queue: DispatchQueue(label: "NormativeEdit-account-\(UUID().uuidString)"))
        account.omemo = omemo
        let previous = AccountManager.shared.users
        AccountManager.shared.users = previous + [account]
        defer {
            AccountManager.shared.users = previous
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
        }
        try body(account)
    }

    @discardableResult
    private func storeOriginal(_ item: MessageStorageItem, xmlID: String, originID: String, from: String, to: String, thread: String? = nil) throws -> MessageStanzaStorageItem {
        let threadXML = thread.map { "<thread>\($0)</thread>" } ?? ""
        let raw = MessageStanzaStorageItem()
        raw.set(item.messageId, for: item.owner, with: "<message xmlns='jabber:client' type='chat' from='\(from)' to='\(to)' id='\(xmlID)'><origin-id xmlns='urn:xmpp:sid:0' id='\(originID)'/>\(threadXML)<body>before correction</body></message>", at: item.date, primary: item.primary)
        let realm = try WRealm.safe()
        try realm.write { realm.add(raw, update: .modified) }
        return raw
    }

    private func withUIActionStream(_ account: Account, stream: CapturingStream, body: () throws -> Void) rethrows {
        let ui = XMPPUIActionManager.shared
        let previousOwner = ui.currentJid
        let previousStream = ui.stream
        let previousRetract = ui.retract
        let previousMessages = ui.messages
        let previousMAM = ui.mam
        ui.preparePendingAuthenticationForTests(owner: account.jid, stream: stream, archiveManager: account.mam, messageManager: account.messages)
        ui.queue.sync { ui.retract = account.msgDeleteManager }
        defer {
            ui.resetPendingAuthenticationForTests()
            ui.queue.sync {
                ui.currentJid = previousOwner
                ui.stream = previousStream
                ui.retract = previousRetract
                ui.messages = previousMessages
                ui.mam = previousMAM
            }
        }
        try body()
    }

    private func sentEncryptedReplacement(_ fixture: Fixture, body: String) throws -> XMPPMessage {
        var output: XMPPMessage?
        try withAccount(fixture.alice) { account in
            let item = try storedMessage(owner: fixture.alice.owner, jid: fixture.bob.owner, type: .omemo)
            let stream = CapturingStream()
            account.msgDeleteManager.editMessage(stream, primary: item.primary, editedMessage: try replacementMessage(item: item, body: body), conversationType: .omemo)
            let iq = try XCTUnwrap(stream.iqs.first)
            output = try serverMessage(from: replacementWire(in: iq), xmlns: "jabber:client")
        }
        return try XCTUnwrap(output)
    }

    private func serverPacket(route: String, fixture: Fixture, wire: XMPPMessage, from: String? = nil, originalStamp: String) throws -> XMPPMessage {
        if route == "direct" { return wire }
        let content: String
        if route == "rewrite" {
            let notified = try serverMessage(from: wire, xmlns: "https://xabber.com/protocol/rewrite#notify")
            content = "<replace xmlns='https://xabber.com/protocol/rewrite#notify' conversation='\(fixture.alice.owner)' type='urn:xmpp:omemo:2' id='archive-original' version='2'>\(notified.xmlString)</replace>"
        } else {
            content = "<result xmlns='urn:xmpp:mam:2' id='edited-archive' queryid='edit-query'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='\(originalStamp)'/>\(wire.xmlString)</forwarded></result>"
        }
        return XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' from='\(from ?? fixture.bob.owner)' to='\(fixture.bob.owner)' type='\(route == "rewrite" ? "headline" : "normal")'>\(content)</message>"))
    }

    private func receiveLeaf(_ message: XMPPMessage, route: String) throws -> XMPPMessage {
        if route == "direct" { return message }
        if route == "mam" { return try XCTUnwrap(getArchivedMessageContainer(message)) }
        let replace = try XCTUnwrap(SCEReceivePolicy.children(of: message, named: "replace", xmlns: "https://xabber.com/protocol/rewrite#notify").first)
        return XMPPMessage(from: try XCTUnwrap(SCEReceivePolicy.children(of: replace, named: "message", xmlns: "https://xabber.com/protocol/rewrite#notify").first))
    }

    /// Inspect expanded QNames after the final IQ has actually been serialized.
    private func replacementWire(in iq: XMPPIQ) throws -> XMPPMessage {
        let serialized = try DDXMLElement(xmlString: iq.xmlString)
        let replace = try XCTUnwrap(SCEReceivePolicy.children(of: serialized, named: "replace", xmlns: MessageDeleteManager.namespace).first)
        return XMPPMessage(from: try XCTUnwrap(SCEReceivePolicy.children(of: replace, named: "message", xmlns: MessageDeleteManager.namespace).first))
    }

    /// Fixtures follow pinned xep_rewrite's notify record and mod_retract's
    /// preserved archived stanza: notify omits XML id/type, archive retains them.
    private func serverMessage(from source: XMPPMessage, xmlns: String) throws -> XMPPMessage {
        let message = DDXMLElement(name: "message", xmlns: xmlns)
        let isNotification = xmlns == "https://xabber.com/protocol/rewrite#notify"
        for attribute in source.attributes ?? [] {
            if isNotification && ["id", "type"].contains(attribute.localName ?? "") { continue }
            message.addAttribute(attribute.copy() as! DDXMLNode)
        }
        for child in source.children ?? [] {
            guard let element = child as? DDXMLElement else { continue }
            if element.localName == "body" && ["jabber:client", MessageDeleteManager.namespace].contains(element.uri ?? "") {
                let body = DDXMLElement(name: "body", xmlns: xmlns)
                body.stringValue = element.stringValue
                message.addChild(body)
            } else {
                message.addChild(SCEReceivePolicy.canonicalElementCopy(element))
            }
        }
        return XMPPMessage(from: try DDXMLElement(xmlString: message.xmlString))
    }

    private final class CapturingStream: XMPPStream {
        var iqs: [XMPPIQ] = []
        var onIQ: ((XMPPIQ) -> Void)?
        override var isAuthenticated: Bool { true }
        override func send(_ element: DDXMLElement) {
            if let iq = element as? XMPPIQ {
                let copy = iq.copy() as! XMPPIQ
                iqs.append(copy)
                onIQ?(copy)
            }
        }
    }

    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) throws -> (publicKey: Data, privateKey: Data)? { nil }
        func legacyDeviceID(owner: String) -> Int? { nil }
    }

    private struct Fixture {
        let alice: OmemoManager
        let bob: OmemoManager
        let memory: Memory
    }

    private func fixture() throws -> Fixture {
        let persistence = Memory()
        let alice = OmemoManager(withOwner: "edit-alice-\(UUID().uuidString.lowercased())@example.test")
        let bob = OmemoManager(withOwner: "edit-bob-\(UUID().uuidString.lowercased())@example.test")
        let aliceStore = try XabberOMEMO2Storage(owner: alice.owner, persistence: persistence)
        let bobStore = try XabberOMEMO2Storage(owner: bob.owner, persistence: persistence)
        _ = try aliceStore.prepare(deviceID: 41, preKeyCount: 3)
        let bundle = try bobStore.prepare(deviceID: 42, preKeyCount: 3)
        let preKey = try XCTUnwrap(bundle.preKeys.first)
        try aliceStore.initiateSession(jid: bob.owner, deviceID: 42, bundle: OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey, signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature, preKey: preKey.publicKey, preKeyID: preKey.id))
        alice.omemo2Storage = aliceStore
        bob.omemo2Storage = bobStore
        _ = try alice.ensureOMEMO2Prepared()
        _ = try bob.ensureOMEMO2Prepared()
        let device = SignalDeviceStorageItem()
        device.owner = alice.owner
        device.jid = bob.owner
        device.deviceId = 42
        device.primary = SignalDeviceStorageItem.genPrimary(owner: alice.owner, jid: bob.owner, deviceId: 42)
        device.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey)
        device.state = .trusted
        let realm = try WRealm.safe()
        try realm.write { realm.add(device, update: .modified) }
        try seedDevices(alice, jid: alice.owner, ids: [41])
        try seedDevices(alice, jid: bob.owner, ids: [42])
        try seedDevices(bob, jid: bob.owner, ids: [42])
        try seedDevices(bob, jid: alice.owner, ids: [41])
        return Fixture(alice: alice, bob: bob, memory: persistence)
    }

    private func seedDevices(_ manager: OmemoManager, jid: String, ids: [Int]) throws {
        let children = ids.map { "<device id='\($0)'/>" }.joined()
        let message = XMPPMessage(from: try DDXMLElement(xmlString: "<message xmlns='jabber:client' from='\(jid)' to='\(manager.owner)' type='headline'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:devices'><item id='current'><devices xmlns='urn:xmpp:omemo:2'>\(children)</devices></item></items></event></message>"))
        XCTAssertTrue(manager.onContactDeviceListReceiveHeadline(message))
    }
}
