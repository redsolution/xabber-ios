import Foundation
import RealmSwift
import XMPPFramework
import XCTest
@testable import xabber

/// Real manager fanout and receive admission against isolated native sessions.
/// Each device has independent protected persistence, including devices sharing a JID.
final class OMEMO2NativeProtocolBehaviorTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
    }

    private final class CapturingStream: XMPPStream {
        var messages: [XMPPMessage] = []
        var onMessage: (() -> Void)?
        override func send(_ element: DDXMLElement) {
            guard let message = element as? XMPPMessage else { return }
            messages.append(message.copy() as! XMPPMessage)
            onMessage?()
        }
    }

    private struct Device {
        let manager: OmemoManager
        let storage: XabberOMEMO2Storage
        let memory: Memory
        let bundle: OMEMO2LocalBundle
        var owner: String { manager.owner }
        var id: Int { bundle.deviceID }
    }

    private struct Fixture {
        let alice: Device
        let bob: Device
        let bobOther: Device
        let aliceOther: Device
        let deliveryStamp = Date().XMPPFormattedDate
        var recipients: [Device] { [bob, bobOther, aliceOther] }
    }

    private var originalRealm: Realm.Configuration!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment),
            "This suite requires isolated storage and disabled account autoconnect")
        originalRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "NativeProtocol-\(UUID())")
    }

    override func tearDown() {
        guard originalRealm != nil else { super.tearDown(); return }
        Realm.Configuration.defaultConfiguration = originalRealm
        super.tearDown()
    }

    func testMultiDeviceFanoutAuthenticatesOnePayloadAndTheSameMaterialForEveryRecipient() throws {
        let f = try fixture()
        let encrypted = try send(f, body: "Один payload для всех 🔐")
        let header = try XCTUnwrap(encrypted.element(forName: "header", xmlns: OmemoManager.xmlns))
        XCTAssertEqual(header.attributeIntegerValue(forName: "sid"), f.alice.id)
        XCTAssertEqual(recipientIDs(encrypted, jid: f.bob.owner), [f.bob.id, f.bobOther.id])
        XCTAssertEqual(recipientIDs(encrypted, jid: f.alice.owner), [f.aliceOther.id])
        XCTAssertEqual(header.elements(forName: "keys").count, 2)
        XCTAssertEqual(encrypted.elements(forName: "payload").count, 1)
        let payload = try payloadBytes(encrypted)
        var materials: [Data] = []

        for recipient in f.recipients {
            let wrapped = try ciphertext(encrypted, recipient: recipient)
            let material = try recipient.storage.decrypt(wrapped, jid: f.alice.owner, deviceID: f.alice.id) {
                _ = try Omemo2PayloadCodec.openVerified(payload, keyAndMAC: $0,
                    expectedFrom: f.alice.owner, expectedTo: f.bob.owner)
            }
            materials.append(material)
            let opened = try XCTUnwrap(Omemo2PayloadCodec.openVerified(payload, keyAndMAC: material,
                expectedFrom: f.alice.owner, expectedTo: f.bob.owner))
            XCTAssertEqual(opened.content.element(forName: "body", xmlns: "jabber:client")?.stringValue,
                "Один payload для всех 🔐")
            XCTAssertTrue(try recipient.storage.sessionExists(jid: f.alice.owner, deviceID: f.alice.id))
        }
        XCTAssertEqual(materials.count, 3)
        XCTAssertEqual(materials[0], materials[1])
        XCTAssertEqual(materials[0], materials[2])
        XCTAssertEqual(materials[0].count, 48)
        XCTAssertFalse(try f.alice.storage.sessionExists(jid: f.alice.owner, deviceID: f.alice.id))
    }

    func testProductionSenderEmitsOneBareJIDStanzaWhoseSinglePayloadDecryptsOnEveryTrustedDevice() throws {
        let f = try fixture()
        let account = Account(jid: f.alice.owner, queue: DispatchQueue(label: "NativeFanout-account-\(UUID())"))
        account.omemo = f.alice.manager
        account.chatMarkers = ChatMarkersManager(withOwner: f.alice.owner, withoutAfterburnTimer: true)
        account.sendReadiness.onReadinessChanged = nil
        account.sendReadiness.markStreamManagementEnabled()
        let stream = CapturingStream()
        account.xmppStream = stream
        let oldUsers = AccountManager.shared.users
        AccountManager.shared.users = oldUsers + [account]
        defer {
            account.queue.sync {}
            AccountManager.shared.users = oldUsers
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
        }

        let roster = RosterStorageItem()
        roster.owner = f.alice.owner; roster.jid = f.bob.owner
        roster.primary = RosterStorageItem.genPrimary(jid: roster.jid, owner: roster.owner)
        let resource = ResourceStorageItem()
        resource.owner = f.alice.owner; resource.jid = f.bob.owner; resource.resource = "preferred-phone"
        resource.primary = ResourceStorageItem.genPrimary(jid: resource.jid, owner: resource.owner, resource: resource.resource)
        let item = MessageStorageItem()
        item.owner = f.alice.owner; item.opponent = f.bob.owner
        item.messageId = UUID().uuidString
        item.primary = MessageStorageItem.genPrimary(messageId: item.messageId, owner: item.owner)
        item.conversationType = .omemo
        item.body = "One production stanza for three trusted devices 🔐"
        item.legacyBody = item.body; item.outgoing = true
        item.date = Date(); item.sentDate = item.date
        let realm = try WRealm.safe()
        try realm.write { realm.add(roster); realm.add(resource); realm.add(item) }
        XCTAssertEqual(roster.getPrimaryResource()?.resource, resource.resource)
        let sent = expectation(description: "one production fanout stanza")
        stream.onMessage = { sent.fulfill() }

        XCTAssertTrue(account.messages.processSender(item: item.primary))
        wait(for: [sent], timeout: 3)
        account.queue.sync {}

        XCTAssertEqual(stream.messages.count, 1)
        let wire = try XCTUnwrap(stream.messages.first)
        XCTAssertEqual(wire.to?.full, f.bob.owner)
        XCTAssertNil(wire.to?.resource)
        XCTAssertEqual(wire.elementID, item.messageId)
        XCTAssertEqual(getOriginId(wire), item.messageId)
        let encryptedElements = SCEReceivePolicy.children(of: wire, named: "encrypted", xmlns: OmemoManager.xmlns)
        XCTAssertEqual(encryptedElements.count, 1)
        let encrypted = try XCTUnwrap(encryptedElements.first)
        XCTAssertEqual(SCEReceivePolicy.children(of: encrypted, named: "payload", xmlns: OmemoManager.xmlns).count, 1)
        XCTAssertEqual(recipientIDs(encrypted, jid: f.bob.owner), [f.bob.id, f.bobOther.id])
        XCTAssertEqual(recipientIDs(encrypted, jid: f.alice.owner), [f.aliceOther.id])
        XCTAssertEqual(encrypted.element(forName: "header")?.elements(forName: "keys").count, 2)
        XCTAssertFalse(recipientIDs(encrypted, jid: f.alice.owner).contains(f.alice.id))
        let capturedXML = wire.xmlString

        for recipient in f.recipients {
            recipient.manager.omemo2ControlSender = { _ in }
            // The captured outbound stanza stays exact. This copy simulates
            // the receiving account server adding its delivery metadata.
            let delivered = wire.copy() as! XMPPMessage
            addServerTime(to: delivered, owner: recipient.owner, stamp: f.deliveryStamp)
            let incoming: XMPPMessage
            if recipient.owner == f.alice.owner {
                incoming = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.alice.owner)' to='\(f.alice.owner)'><sent xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='\(f.deliveryStamp)'/>\(delivered.xmlString)</forwarded></sent></message>")
            } else {
                incoming = delivered
            }
            let result = recipient.manager.prepareIncoming(incoming, context: recipient.owner == f.alice.owner ? .carbon : .live)
            guard case let .verified(clean, proof, sender) = result else {
                return XCTFail("The same captured production stanza must decrypt for \(recipient.owner)/\(recipient.id): \(describe(result))")
            }
            let leaf = recipient.owner == f.alice.owner ? try XCTUnwrap(getCarbonCopyMessageContainer(clean)) : clean
            XCTAssertEqual(leaf.body, item.body)
            XCTAssertEqual(proof, .authenticatedSCE(profile: .omemo2))
            XCTAssertEqual(sender?.deviceID, f.alice.id)
            XCTAssertEqual(sender?.isTrusted, true)
            XCTAssertEqual(wire.xmlString, capturedXML)
        }
    }

    func testContactAndOwnDevicesWithTheSameRIDRemainScopedToTheirKeyGroups() throws {
        let f = try fixture(ownOtherID: 42)
        let encrypted = try send(f, body: "RID collision is owner scoped")
        XCTAssertEqual(recipientIDs(encrypted, jid: f.bob.owner), [42, 43])
        XCTAssertEqual(recipientIDs(encrypted, jid: f.alice.owner), [42])
        let contactKey = try key(encrypted, recipient: f.bob)
        let ownKey = try key(encrypted, recipient: f.aliceOther)
        XCTAssertNotEqual(contactKey.stringValue, ownKey.stringValue)

        let live = f.bob.manager.prepareIncoming(message(encrypted, f: f))
        let own = f.aliceOther.manager.prepareIncoming(try sentCarbon(encrypted, f: f), context: .carbon)
        guard case let .verified(liveMessage, _, liveSender) = live,
              case let .verified(carbonMessage, _, ownSender) = own else {
            return XCTFail("Both independently addressed native recipients must decrypt; live=\(describe(live)), own=\(describe(own))")
        }
        XCTAssertEqual(liveMessage.body, "RID collision is owner scoped")
        XCTAssertEqual(getCarbonCopyMessageContainer(carbonMessage)?.body, liveMessage.body)
        XCTAssertEqual(liveSender?.owner, f.bob.owner)
        XCTAssertEqual(ownSender?.owner, f.alice.owner)
        XCTAssertEqual(ownSender?.deviceID, f.alice.id)
    }

    func testSelfConversationFanoutExcludesTheCurrentDeviceAndAuthenticatesOnTheOtherOwnDevice() throws {
        let f = try fixture()
        let prepared = try XCTUnwrap(f.alice.manager.prepareStanzaContent(message: "own-device note", date: Date(),
            jid: f.alice.owner, additionalContent: [], ignoreTimeSignature: true))
        let encrypted = try XCTUnwrap(f.alice.manager.encryptMessage(message: prepared, to: f.alice.owner))
        XCTAssertEqual(recipientIDs(encrypted, jid: f.alice.owner), [f.aliceOther.id])
        XCTAssertEqual(encrypted.element(forName: "header")?.elements(forName: "keys").count, 1)
        XCTAssertFalse(try f.alice.storage.sessionExists(jid: f.alice.owner, deviceID: f.alice.id))
        let incoming = XMPPMessage(type: "chat", to: XMPPJID(string: f.alice.owner), elementID: UUID().uuidString)
        incoming.addAttribute(withName: "from", stringValue: f.alice.owner + "/ios")
        incoming.addChild(encrypted)
        addServerTime(to: incoming, owner: f.alice.owner, stamp: f.deliveryStamp)

        guard case let .verified(clean, proof, sender) = f.aliceOther.manager.prepareIncoming(incoming) else {
            return XCTFail("Own-device synchronization uses an authenticated native session")
        }
        XCTAssertEqual(clean.body, "own-device note")
        XCTAssertEqual(proof, .authenticatedSCE(profile: .omemo2))
        XCTAssertEqual(sender?.jid, f.alice.owner)
        XCTAssertEqual(sender?.isTrusted, true)
    }

    func testEveryFanoutRecipientAcknowledgesOnlyTheSenderAndAllSessionsLeaveKEXWithoutLoops() throws {
        let f = try fixture()
        let encrypted = try send(f, body: "confirm all recipients")
        var echoed: [XMPPMessage] = []
        f.alice.manager.omemo2ControlSender = { echoed.append($0) }
        for recipient in f.recipients {
            var controls: [XMPPMessage] = []
            recipient.manager.omemo2ControlSender = { controls.append($0) }
            let wire = try recipient.owner == f.alice.owner ? sentCarbon(encrypted, f: f) : message(encrypted, f: f)
            let result = recipient.manager.prepareIncoming(wire)
            guard case .verified = result else {
                return XCTFail("Expected first native payload for \(recipient.owner)/\(recipient.id): \(describe(result))")
            }
            XCTAssertEqual(controls.count, 1)
            let ack = try XCTUnwrap(controls.first)
            XCTAssertEqual(ack.to?.bare, f.alice.owner)
            XCTAssertNil(ack.body)
            let ackEncrypted = try XCTUnwrap(ack.element(forName: "encrypted", xmlns: OmemoManager.xmlns))
            XCTAssertNil(ackEncrypted.element(forName: "payload"))
            XCTAssertEqual(recipientIDs(ackEncrypted, jid: f.alice.owner), [f.alice.id])
            XCTAssertEqual(ackEncrypted.element(forName: "header")?.elements(forName: "keys").count, 1)
            ack.addAttribute(withName: "from", stringValue: recipient.owner + "/peer")
            guard case .consumed(.control) = f.alice.manager.prepareIncoming(ack) else {
                return XCTFail("Every recipient's authenticated ACK must remain invisible")
            }
            let afterACK = f.alice.memory.records[f.alice.owner]
            guard case .consumed(.duplicate) = f.alice.manager.prepareIncoming(ack) else {
                return XCTFail("Repeated ACK must be consumed as exact replay")
            }
            XCTAssertEqual(f.alice.memory.records[f.alice.owner], afterACK)
            XCTAssertFalse(try XCTUnwrap(f.alice.storage.sessionMetadata(jid: recipient.owner, deviceID: recipient.id)).keyExchangePending)
        }
        XCTAssertTrue(echoed.isEmpty)
        let regular = try send(f, body: "all recipients confirmed")
        for recipient in f.recipients { XCTAssertFalse(try ciphertext(regular, recipient: recipient).isKeyExchange) }
    }

    func testManagerRoundTripPreservesUnicodeFileMetadataReferencesAndOriginIDForEveryDevice() throws {
        let f = try fixture()
        let body = "Привет & <мир> 👨‍👩‍👧‍👦\nالعربية 日本語 e\u{301}"
        let reference = try DDXMLElement(xmlString: """
        <r:reference xmlns:r='https://xabber.com/protocol/references' type='mutable'>
          <f:file-sharing xmlns:f='https://xabber.com/protocol/files'>
            <f:file><f:media-type>application/pdf</f:media-type><f:name>Документ &amp; 日本語.pdf</f:name><f:size>1234567</f:size></f:file>
            <f:sources><f:uri>https://files.example.test/document?one=1&amp;two=2</f:uri></f:sources>
          </f:file-sharing>
        </r:reference>
        """)
        let origin = try DDXMLElement(xmlString: "<origin-id xmlns='urn:xmpp:sid:0' id='native-origin-42'/>")
        let prepared = try XCTUnwrap(f.alice.manager.prepareStanzaContent(message: body, date: Date(),
            jid: f.bob.owner, additionalContent: [reference, origin], ignoreTimeSignature: true))
        let encrypted = try XCTUnwrap(f.alice.manager.encryptMessage(message: prepared, to: f.bob.owner))
        XCTAssertFalse(encrypted.xmlString.contains("Документ"))
        XCTAssertFalse(encrypted.xmlString.contains("files.example.test"))

        for recipient in f.recipients {
            let wire = try recipient.owner == f.alice.owner ? sentCarbon(encrypted, f: f) : message(encrypted, f: f)
            let result = recipient.manager.prepareIncoming(wire, context: recipient.owner == f.alice.owner ? .carbon : .live)
            guard case let .verified(clean, proof, sender) = result else {
                return XCTFail("Expected authenticated fanout for \(recipient.owner)/\(recipient.id): \(describe(result))")
            }
            let leaf = recipient.owner == f.alice.owner ? try XCTUnwrap(getCarbonCopyMessageContainer(clean)) : clean
            XCTAssertEqual(proof, .authenticatedSCE(profile: .omemo2))
            XCTAssertEqual(leaf.body, body)
            XCTAssertEqual(sender?.jid, f.alice.owner)
            XCTAssertEqual(sender?.deviceID, f.alice.id)
            XCTAssertEqual(sender?.isTrusted, true)
            XCTAssertEqual(leaf.element(forName: "origin-id", xmlns: "urn:xmpp:sid:0")?.attributeStringValue(forName: "id"), "native-origin-42")
            let refs = SCEReceivePolicy.children(of: leaf, named: "reference", xmlns: "https://xabber.com/protocol/references")
            XCTAssertEqual(refs.count, 1)
            let sharing = try XCTUnwrap(refs.first?.element(forName: "file-sharing", xmlns: "https://xabber.com/protocol/files"))
            XCTAssertEqual(sharing.element(forName: "file")?.element(forName: "name")?.stringValue, "Документ & 日本語.pdf")
            XCTAssertEqual(sharing.element(forName: "file")?.element(forName: "size")?.stringValue, "1234567")
            XCTAssertEqual(sharing.element(forName: "sources")?.element(forName: "uri")?.stringValue, "https://files.example.test/document?one=1&two=2")
            XCTAssertNil(leaf.element(forName: "omemo-result__system"))
        }
    }

    func testUntrustedContactDeviceIsExcludedWithoutAdvancingItsExistingNativeSession() throws {
        for state: SignalDeviceStorageItem.TrustState in [.unknown, .ignore, .distrusted, .revoked, .fingerprintChanged] {
            let f = try fixture()
            _ = try send(f, body: "before exclusion")
            let before = try XCTUnwrap(f.alice.storage.sessionMetadata(jid: f.bob.owner, deviceID: f.bobOther.id))
            try setTrust(f.bobOther, asSeenBy: f.alice, state: state)

            let encrypted = try send(f, body: "after exclusion")

            XCTAssertEqual(recipientIDs(encrypted, jid: f.bob.owner), [f.bob.id], state.rawValue)
            XCTAssertEqual(recipientIDs(encrypted, jid: f.alice.owner), [f.aliceOther.id])
            let after = try XCTUnwrap(f.alice.storage.sessionMetadata(jid: f.bob.owner, deviceID: f.bobOther.id))
            XCTAssertEqual(after.sendCounter, before.sendCounter)
            XCTAssertEqual(after.ephemeralKey, before.ephemeralKey)
            guard case let .verified(clean, _, _) = f.bob.manager.prepareIncoming(message(encrypted, f: f)) else {
                return XCTFail("The remaining trusted contact device must still receive")
            }
            XCTAssertEqual(clean.body, "after exclusion")
        }
    }

    func testDeviceListRemovalExcludesOnlyTheRemovedDeviceAndKeepsTrustAndNativeSession() throws {
        let f = try fixture()
        _ = try send(f, body: "before removal")
        let before = try XCTUnwrap(f.alice.storage.sessionMetadata(jid: f.bob.owner, deviceID: f.bobOther.id))
        try advertise(to: f.alice.manager, jid: f.bob.owner, ids: [f.bob.id])

        let encrypted = try send(f, body: "after removal")

        XCTAssertEqual(recipientIDs(encrypted, jid: f.bob.owner), [f.bob.id])
        XCTAssertEqual(recipientIDs(encrypted, jid: f.alice.owner), [f.aliceOther.id])
        XCTAssertEqual(try f.alice.storage.sessionMetadata(jid: f.bob.owner, deviceID: f.bobOther.id)?.sendCounter, before.sendCounter)
        let device = try projectedDevice(f.bobOther, asSeenBy: f.alice)
        XCTAssertEqual(device.state, .trusted)
        XCTAssertFalse(device.isInDeviceList)
        XCTAssertTrue(try f.alice.storage.sessionExists(jid: f.bob.owner, deviceID: f.bobOther.id))
    }

    func testNoTrustedContactRecipientCannotUseOwnDeviceFanoutAsASendFallback() throws {
        let f = try fixture()
        _ = try send(f, body: "establish all slots")
        try setTrust(f.bob, asSeenBy: f.alice, state: .distrusted)
        try setTrust(f.bobOther, asSeenBy: f.alice, state: .revoked)
        let before = f.alice.memory.records[f.alice.owner]

        XCTAssertThrowsError(try f.alice.manager.encryptMessage(message: envelope(f, body: "must not send"), to: f.bob.owner)) {
            XCTAssertEqual($0 as? OmemoManagerError, .noTrustedRecipientDevices)
        }

        XCTAssertEqual(f.alice.memory.records[f.alice.owner], before)
    }

    func testOneRecipientBundleFailureReleasesNoPartialCiphertextAndFreshRetryDecryptsOnAllDevices() throws {
        let f = try fixture()
        let realm = try WRealm.safe()
        let primary = SignalIdentityStorageItem.genRpimary(owner: f.alice.owner, jid: f.bob.owner, deviceId: f.bobOther.id)
        let identity = try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: primary))
        let validSignature = identity.signedPreKeySignature
        try realm.write { identity.signedPreKeySignature = Data(repeating: 0, count: 64).base64EncodedString() }
        var released: DDXMLElement?

        XCTAssertThrowsError(released = try f.alice.manager.encryptMessage(message: envelope(f, body: "all or no wire"), to: f.bob.owner))
        XCTAssertNil(released)
        XCTAssertFalse(try f.alice.storage.sessionExists(jid: f.bob.owner, deviceID: f.bobOther.id))
        XCTAssertFalse(try f.alice.storage.sessionExists(jid: f.alice.owner, deviceID: f.aliceOther.id))
        // Earlier recipient candidates may already be protected commits. A
        // retry must continue those counters and use a newly sealed payload.
        let committedCounter = try f.alice.storage.sessionMetadata(jid: f.bob.owner, deviceID: f.bob.id)?.sendCounter ?? 0
        try realm.write { identity.signedPreKeySignature = validSignature }
        let retry = try send(f, body: "retry after bundle repair")
        XCTAssertEqual(try ciphertext(retry, recipient: f.bob).counter, UInt32(committedCounter))

        for recipient in f.recipients {
            let wire = try recipient.owner == f.alice.owner ? sentCarbon(retry, f: f) : message(retry, f: f)
            let result = recipient.manager.prepareIncoming(wire)
            guard case let .verified(clean, _, _) = result else {
                return XCTFail("A rejected partial fanout must not poison \(recipient.owner)/\(recipient.id): \(describe(result))")
            }
            let leaf = recipient.owner == f.alice.owner ? getCarbonCopyMessageContainer(clean) : clean
            XCTAssertEqual(leaf?.body, "retry after bundle repair")
        }
    }

    func testMissingTrustedOwnBundleReleasesNoCiphertextAfterPreparingContactRecipients() throws {
        let f = try fixture()
        let realm = try WRealm.safe()
        let primary = SignalIdentityStorageItem.genRpimary(owner: f.alice.owner, jid: f.alice.owner, deviceId: f.aliceOther.id)
        let identity = try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: primary))
        try realm.write {
            realm.delete(identity)
            realm.delete(realm.objects(SignalPreKeysStorageItem.self)
                .filter("owner == %@ AND jid == %@ AND deviceId == %@", f.alice.owner, f.alice.owner, f.aliceOther.id))
        }
        let ownDevice = try projectedDevice(f.aliceOther, asSeenBy: f.alice)
        XCTAssertEqual(ownDevice.state, .trusted)
        XCTAssertTrue(ownDevice.isInDeviceList)
        var released: DDXMLElement?

        XCTAssertThrowsError(released = try f.alice.manager.encryptMessage(message: envelope(f, body: "all trusted devices are required"), to: f.bob.owner)) {
            XCTAssertEqual($0 as? OmemoManagerError, .bundleNotFound)
        }

        XCTAssertNil(released)
        XCTAssertTrue(try f.alice.storage.sessionExists(jid: f.bob.owner, deviceID: f.bob.id))
        XCTAssertTrue(try f.alice.storage.sessionExists(jid: f.bob.owner, deviceID: f.bobOther.id))
        XCTAssertFalse(try f.alice.storage.sessionExists(jid: f.alice.owner, deviceID: f.aliceOther.id))
        try cache(f.aliceOther.bundle, owner: f.alice.owner, jid: f.alice.owner)
        try advertise(to: f.alice.manager, jid: f.alice.owner, ids: [f.alice.id, f.aliceOther.id])
        let retry = try send(f, body: "retry after own bundle recovery")
        for recipient in f.recipients {
            let incoming = try recipient.owner == f.alice.owner ? sentCarbon(retry, f: f) : message(retry, f: f)
            guard case let .verified(clean, _, _) = recipient.manager.prepareIncoming(incoming) else {
                return XCTFail("The recovered own bundle must preserve decryptability for every trusted device")
            }
            let leaf = recipient.owner == f.alice.owner ? getCarbonCopyMessageContainer(clean) : clean
            XCTAssertEqual(leaf?.body, "retry after own bundle recovery")
        }
    }

    func testMalformedRecipientAdmissionNeverCommitsProofAndTheOriginalPacketRemainsDecryptable() throws {
        let mutations: [(String, (XMPPMessage, DDXMLElement, DDXMLElement, DDXMLElement, DDXMLElement) throws -> Void)] = [
            ("missing sender", { message, _, _, _, _ in message.removeAttribute(forName: "from") }),
            ("missing header", { _, _, header, _, _ in header.detach() }),
            ("duplicate header", { _, encrypted, header, _, _ in encrypted.addChild(header.copy() as! DDXMLElement) }),
            ("missing SID", { _, _, header, _, _ in header.removeAttribute(forName: "sid") }),
            ("zero SID", { _, _, header, _, _ in Self.attribute("sid", value: "0", on: header) }),
            ("negative SID", { _, _, header, _, _ in Self.attribute("sid", value: "-41", on: header) }),
            ("overflow SID", { _, _, header, _, _ in Self.attribute("sid", value: "2147483648", on: header) }),
            ("nonnumeric SID", { _, _, header, _, _ in Self.attribute("sid", value: "forty-one", on: header) }),
            ("missing key group owner", { _, _, _, group, _ in group.removeAttribute(forName: "jid") }),
            ("wrong key group owner", { _, _, _, group, _ in Self.attribute("jid", value: "other@example.test", on: group) }),
            ("resource-qualified key group owner", { _, _, _, group, _ in Self.attribute("jid", value: (group.attributeStringValue(forName: "jid") ?? "") + "/resource", on: group) }),
            ("duplicate own key group", { _, _, header, group, _ in header.addChild(group.copy() as! DDXMLElement) }),
            ("missing RID", { _, _, _, _, key in key.removeAttribute(forName: "rid") }),
            ("wrong RID", { _, _, _, _, key in Self.attribute("rid", value: "99", on: key) }),
            ("noncanonical RID", { _, _, _, _, key in Self.attribute("rid", value: "042", on: key) }),
            ("duplicate matching recipient key", { _, _, _, group, key in group.addChild(key.copy() as! DDXMLElement) }),
            ("noncanonical KEX boolean", { _, _, _, _, key in Self.attribute("kex", value: "TRUE", on: key) }),
            ("out of range KEX boolean", { _, _, _, _, key in Self.attribute("kex", value: "2", on: key) }),
            ("empty KEX boolean", { _, _, _, _, key in Self.attribute("kex", value: "", on: key) }),
            ("KEX declared regular", { _, _, _, _, key in Self.attribute("kex", value: "false", on: key) }),
            ("invalid key base64", { _, _, _, _, key in key.stringValue = "%%%" }),
            ("empty key base64", { _, _, _, _, key in key.stringValue = "" }),
            ("truncated native envelope", { _, _, _, _, key in key.stringValue = Data([1, 2, 3]).base64EncodedString() }),
            ("missing user payload", { _, encrypted, _, _, _ in encrypted.element(forName: "payload")?.detach() }),
            ("duplicate payload", { _, encrypted, _, _, _ in encrypted.addChild(try XCTUnwrap(encrypted.element(forName: "payload")).copy() as! DDXMLElement) }),
            ("empty payload", { _, encrypted, _, _, _ in encrypted.element(forName: "payload")?.stringValue = "" }),
            ("invalid payload base64", { _, encrypted, _, _, _ in encrypted.element(forName: "payload")?.stringValue = "%%%" }),
            ("partial AES block", { _, encrypted, _, _, _ in encrypted.element(forName: "payload")?.stringValue = Data(repeating: 1, count: 15).base64EncodedString() })
        ]
        for (name, mutate) in mutations {
            let f = try fixture()
            let encrypted = try send(f, body: "authentic packet after \(name)")
            let invalid = message(encrypted, f: f)
            let changed = try XCTUnwrap(invalid.element(forName: "encrypted", xmlns: OmemoManager.xmlns))
            let header = try XCTUnwrap(changed.element(forName: "header"))
            let group = try XCTUnwrap(header.elements(forName: "keys").first { $0.attributeStringValue(forName: "jid") == f.bob.owner })
            let key = try XCTUnwrap(group.elements(forName: "key").first { $0.attributeStringValue(forName: "rid") == String(f.bob.id) })
            try mutate(invalid, changed, header, group, key)
            let before = f.bob.memory.records[f.bob.owner]
            let preKeys = try f.bob.storage.localBundle().preKeys
            let device = try projectedDevice(f.alice, asSeenBy: f.bob)
            let fingerprint = device.fingerprint
            var controls: [XMPPMessage] = []
            f.bob.manager.omemo2ControlSender = { controls.append($0) }
            invalid.addBody("forged visible fallback")

            let failed = f.bob.manager.prepareIncoming(invalid)

            guard case let .failed(clean, _) = failed else { return XCTFail("Expected rejection: \(name)") }
            XCTAssertEqual(failed.provenance, .failedOMEMO, name)
            XCTAssertNil(failed.authenticatedSender, name)
            XCTAssertNil(clean.body, name)
            XCTAssertTrue(controls.isEmpty, name)
            XCTAssertEqual(f.bob.memory.records[f.bob.owner], before, name)
            XCTAssertEqual(try f.bob.storage.localBundle().preKeys, preKeys, name)
            XCTAssertFalse(try f.bob.storage.sessionExists(jid: f.alice.owner, deviceID: f.alice.id), name)
            XCTAssertEqual(device.state, .trusted, name)
            XCTAssertEqual(device.fingerprint, fingerprint, name)
            guard case let .verified(retry, _, sender) = f.bob.manager.prepareIncoming(message(encrypted, f: f)) else {
                return XCTFail("Rejected metadata must not consume the authentic packet: \(name)")
            }
            XCTAssertEqual(retry.body, "authentic packet after \(name)")
            XCTAssertEqual(sender?.isTrusted, true)
        }
    }

    func testRecognizedKEXBooleanAndBase64WhitespaceHaveTheSameAuthenticatedReplayIdentity() throws {
        let f = try fixture()
        let encrypted = try send(f, body: "XML lexical aliases")
        let original = message(encrypted, f: f)
        guard case .verified = f.bob.manager.prepareIncoming(original) else { return XCTFail("Expected initial decrypt") }
        let committed = f.bob.memory.records[f.bob.owner]
        let alias = message(encrypted, f: f)
        let changed = try XCTUnwrap(alias.element(forName: "encrypted"))
        let matching = try key(changed, recipient: f.bob)
        Self.attribute("kex", value: "1", on: matching)
        matching.stringValue = " \n\t" + (matching.stringValue ?? "") + "\r "
        let payload = try XCTUnwrap(changed.element(forName: "payload"))
        payload.stringValue = " \n" + (payload.stringValue ?? "") + "\t\r "

        guard case .consumed(.duplicate) = f.bob.manager.prepareIncoming(alias) else {
            return XCTFail("Equivalent accepted XML encodings must be one receive")
        }
        XCTAssertEqual(f.bob.memory.records[f.bob.owner], committed)
    }

    func testNestedArchiveCarbonAndMixedCiphertextAreRejectedBeforeNativeStateMutation() throws {
        for kind in ["nested archive", "archive and leaf ciphertext", "nested carbon"] {
            let f = try fixture()
            let encrypted = try send(f, body: "one unambiguous leaf")
            let inner = message(encrypted, f: f)
            let archive = "<result xmlns='urn:xmpp:mam:2' id='archive-id' queryid='query-id'><forwarded xmlns='urn:xmpp:forward:0'>\(inner.xmlString)</forwarded></result>"
            let wire: XMPPMessage
            if kind == "nested archive" {
                let nested = "<message xmlns='jabber:client' from='\(f.bob.owner)' to='\(f.bob.owner)'>\(archive)</message>"
                wire = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.bob.owner)' to='\(f.bob.owner)'><received xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>\(nested)</forwarded></received></message>")
            } else if kind == "nested carbon" {
                let carbon = try sentCarbon(encrypted, f: f).xmlString
                wire = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.bob.owner)' to='\(f.bob.owner)'><result xmlns='urn:xmpp:mam:2'><forwarded xmlns='urn:xmpp:forward:0'>\(carbon)</forwarded></result></message>")
            } else {
                wire = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.bob.owner)' to='\(f.bob.owner)'>\(archive)\(encrypted.xmlString)</message>")
            }
            let before = f.bob.memory.records[f.bob.owner]

            guard case .consumed(.invalidTransport) = f.bob.manager.prepareIncoming(wire, context: .archive) else {
                return XCTFail("Ambiguous nested routing must be consumed: \(kind)")
            }
            XCTAssertEqual(f.bob.memory.records[f.bob.owner], before, kind)
            guard case let .verified(clean, _, _) = f.bob.manager.prepareIncoming(inner) else {
                return XCTFail("Rejected wrapper must leave the native leaf usable")
            }
            XCTAssertEqual(clean.body, "one unambiguous leaf")
        }
    }

    private func fixture(ownOtherID: Int = 44) throws -> Fixture {
        let suffix = UUID().uuidString.lowercased()
        let alice = try device(owner: "alice-\(suffix)@example.test", id: 41)
        let bob = try device(owner: "bob-\(suffix)@example.test", id: 42)
        let bobOther = try device(owner: bob.owner, id: 43)
        let aliceOther = try device(owner: alice.owner, id: ownOtherID)
        for recipient in [bob, bobOther, aliceOther] {
            try cache(recipient.bundle, owner: alice.owner, jid: recipient.owner)
            try cache(alice.bundle, owner: recipient.owner, jid: alice.owner)
        }
        try advertise(to: alice.manager, jid: alice.owner, ids: [alice.id, aliceOther.id])
        try advertise(to: alice.manager, jid: bob.owner, ids: [bob.id, bobOther.id])
        for recipient in [bob, bobOther] {
            try advertise(to: recipient.manager, jid: bob.owner, ids: [bob.id, bobOther.id])
            try advertise(to: recipient.manager, jid: alice.owner, ids: [alice.id, aliceOther.id])
        }
        try advertise(to: aliceOther.manager, jid: alice.owner, ids: [alice.id, aliceOther.id])
        return Fixture(alice: alice, bob: bob, bobOther: bobOther, aliceOther: aliceOther)
    }

    private func device(owner: String, id: Int) throws -> Device {
        let memory = Memory()
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        let bundle = try storage.prepare(deviceID: id, preKeyCount: 3)
        let manager = OmemoManager(withOwner: owner)
        manager.omemo2Storage = storage
        _ = try manager.ensureOMEMO2Prepared(attemptPublication: false)
        return Device(manager: manager, storage: storage, memory: memory, bundle: bundle)
    }

    private func cache(_ bundle: OMEMO2LocalBundle, owner: String, jid: String) throws {
        let identity = SignalIdentityStorageItem()
        identity.owner = owner; identity.jid = jid; identity.deviceId = bundle.deviceID
        identity.primary = SignalIdentityStorageItem.genRpimary(owner: owner, jid: jid, deviceId: bundle.deviceID)
        identity.protocolProfile = OmemoManager.xmlns
        identity.identityKey = bundle.identityKey.base64EncodedString()
        identity.signedPreKey = bundle.signedPreKey.base64EncodedString()
        identity.signedPreKeyId = Int(bundle.signedPreKeyID)
        identity.signedPreKeySignature = bundle.signature.base64EncodedString()
        let device = SignalDeviceStorageItem()
        device.owner = owner; device.jid = jid; device.deviceId = bundle.deviceID
        device.primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: bundle.deviceID)
        device.state = .trusted
        device.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey)
        let preKeys = bundle.preKeys.map { key -> SignalPreKeysStorageItem in
            let row = SignalPreKeysStorageItem()
            row.owner = owner; row.jid = jid; row.deviceId = bundle.deviceID
            row.pkId = Int(key.id); row.preKey = key.publicKey.base64EncodedString()
            row.keyUUID = UUID().uuidString; row.primary = row.keyUUID
            return row
        }
        let realm = try WRealm.safe()
        try realm.write { realm.add(identity, update: .modified); realm.add(device, update: .modified); realm.add(preKeys) }
    }

    private func advertise(to manager: OmemoManager, jid: String, ids: [Int]) throws {
        let devices = ids.map { "<device id='\($0)'/>" }.joined()
        let wire = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(jid)' type='headline'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:devices'><item id='current'><devices xmlns='urn:xmpp:omemo:2'>\(devices)</devices></item></items></event></message>")
        XCTAssertTrue(manager.onContactDeviceListReceiveHeadline(wire))
    }

    private func projectedDevice(_ device: Device, asSeenBy observer: Device) throws -> SignalDeviceStorageItem {
        let primary = SignalDeviceStorageItem.genPrimary(owner: observer.owner, jid: device.owner, deviceId: device.id)
        return try XCTUnwrap(WRealm.safe().object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary))
    }

    private func setTrust(_ device: Device, asSeenBy observer: Device, state: SignalDeviceStorageItem.TrustState) throws {
        let row = try projectedDevice(device, asSeenBy: observer)
        let realm = try WRealm.safe()
        try realm.write { row.state = state }
    }

    private func envelope(_ f: Fixture, body: String) throws -> String {
        try XCTUnwrap(f.alice.manager.prepareStanzaContent(message: body, date: Date(), jid: f.bob.owner,
            additionalContent: [], ignoreTimeSignature: true))
    }

    private func send(_ f: Fixture, body: String) throws -> DDXMLElement {
        try XCTUnwrap(f.alice.manager.encryptMessage(message: envelope(f, body: body), to: f.bob.owner))
    }

    private func recipientIDs(_ encrypted: DDXMLElement, jid: String) -> [Int] {
        encrypted.element(forName: "header")?.elements(forName: "keys")
            .first { $0.attributeStringValue(forName: "jid") == jid }?.elements(forName: "key")
            .compactMap { Int($0.attributeStringValue(forName: "rid") ?? "") }.sorted() ?? []
    }

    private func key(_ encrypted: DDXMLElement, recipient: Device) throws -> DDXMLElement {
        try XCTUnwrap(encrypted.element(forName: "header")?.elements(forName: "keys")
            .first { $0.attributeStringValue(forName: "jid") == recipient.owner }?.elements(forName: "key")
            .first { $0.attributeStringValue(forName: "rid") == String(recipient.id) })
    }

    private func ciphertext(_ encrypted: DDXMLElement, recipient: Device) throws -> OMEMO2Ciphertext {
        let row = try key(encrypted, recipient: recipient)
        let bytes = try Omemo2PayloadCodec.decodeBase64(try XCTUnwrap(row.stringValue))
        return try OMEMO2Ciphertext(data: bytes, keyExchange: row.attributeBoolValue(forName: "kex"))
    }

    private func payloadBytes(_ encrypted: DDXMLElement) throws -> Data {
        try Omemo2PayloadCodec.decodeBase64(XCTUnwrap(encrypted.element(forName: "payload")?.stringValue))
    }

    private func message(_ encrypted: DDXMLElement, f: Fixture) -> XMPPMessage {
        let message = XMPPMessage(type: "chat", to: XMPPJID(string: f.bob.owner), elementID: UUID().uuidString)
        // Standalone serialized stanzas need their explicit stream namespace
        // before embedding below forwarded's different default namespace.
        message.addNamespace(DDXMLNode.namespace(withName: "", stringValue: "jabber:client") as! DDXMLNode)
        message.addAttribute(withName: "from", stringValue: f.alice.owner + "/ios")
        message.addChild(encrypted.copy() as! DDXMLElement)
        addServerTime(to: message, owner: f.bob.owner, stamp: f.deliveryStamp)
        return message
    }

    private func sentCarbon(_ encrypted: DDXMLElement, f: Fixture) throws -> XMPPMessage {
        try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(f.alice.owner)' to='\(f.alice.owner)'><sent xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='\(f.deliveryStamp)'/>\(message(encrypted, f: f).xmlString)</forwarded></sent></message>")
    }

    private func addServerTime(to message: XMPPMessage, owner: String, stamp: String) {
        let time = DDXMLElement(name: "time", xmlns: "https://xabber.com/protocol/delivery")
        time.addAttribute(withName: "by", stringValue: owner)
        time.addAttribute(withName: "stamp", stringValue: stamp)
        message.addChild(time)
    }

    private static func attribute(_ name: String, value: String, on element: DDXMLElement) {
        element.removeAttribute(forName: name)
        element.addAttribute(withName: name, stringValue: value)
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
