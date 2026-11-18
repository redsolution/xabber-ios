import Foundation
import RealmSwift
import XCTest
import XMPPFramework
@testable import xabber

@MainActor
final class ScheduledOMEMO2Tests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
    }

    private final class Stream: XMPPStream {
        weak var account: Account?
        var hold = false
        var queued: [XMPPIQ] = []
        var sent: [XMPPIQ] = []
        override var isAuthenticated: Bool { true }
        override func send(_ element: DDXMLElement) {
            guard let iq = element as? XMPPIQ else { return }
            if hold { queued.append(iq) }
            else { transmit(iq) }
        }
        func transmit(_ iq: XMPPIQ) {
            guard let account, account.xmppStream(self, willSend: iq) != nil else { return }
            sent.append(iq)
            account.xmppStream(self, didSend: iq)
        }
    }

    private struct Device {
        let manager: OmemoManager
        let storage: XabberOMEMO2Storage
        let memory: Memory
        let bundle: OMEMO2LocalBundle
        var owner: String { manager.owner }
    }

    private var oldRealm: Realm.Configuration!
    private var realm: Realm!
    private var oldUsers: [Account] = []
    private var accounts: [Account] = []
    private var directory: URL!
    private var previews: ScheduledOMEMO2PreviewStore!

    override func setUpWithError() throws {
        try XCTSkipUnless(HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment))
        oldRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "ScheduledOMEMO2-\(UUID())")
        realm = try WRealm.safe()
        oldUsers = AccountManager.shared.users
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        previews = ScheduledOMEMO2PreviewStore(directory: directory, keyProvider: { _, _ in Data(repeating: 7, count: 32) })
    }

    override func tearDown() {
        for account in accounts {
            account.messageSchedule.clearSession()
            account.queue.sync {}
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
        }
        AccountManager.shared.users = oldUsers
        accounts.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        previews = nil
        directory = nil
        realm = nil
        if let oldRealm { Realm.Configuration.defaultConfiguration = oldRealm }
        super.tearDown()
    }

    func testScheduleIQContainsOnlyCiphertextAndRemoteListCannotRevealThePreview() throws {
        let (sender, recipient) = try devices()
        let (account, stream) = account(for: sender)
        let due = Date().addingTimeInterval(3600)
        let plaintext = message(from: sender.owner, to: recipient.owner, body: "confidential schedule 🧪")
        let id = try XCTUnwrap(account.messageSchedule.scheduleOMEMO2Message(
            stream, conversation: recipient.owner, deliverAt: due, plaintext: plaintext, omemo: sender.manager
        ))
        let iq = try XCTUnwrap(stream.sent.first)
        XCTAssertEqual(iq.to?.bare, sender.owner)
        XCTAssertFalse(iq.xmlString.contains("confidential schedule"))
        let inner = try encryptedMessage(in: iq)
        XCTAssertNil(inner.body)
        XCTAssertTrue(SCEReceivePolicy.hasOMEMO2(inner))
        XCTAssertTrue(realm.objects(OutgoingMessageQueueItem.self).isEmpty)
        XCTAssertTrue(realm.objects(XMPPMessageScheduleStorageItem.self).isEmpty)
        let ack = try XMPPIQ(xmlString: """
        <iq type='result' from='\(sender.owner)' id='\(id)'>
          <scheduled xmlns='\(XMPPMessageScheduleManager.namespace)' id='accepted' conversation='\(recipient.owner)' type='urn:xmpp:omemo:2' deliver-at='\(wireTime(due))'/>
        </iq>
        """)
        XCTAssertTrue(account.messageSchedule.read(withIQ: ack))
        let row = try XCTUnwrap(realm.objects(XMPPMessageScheduleStorageItem.self).first)
        XCTAssertFalse(row.messageXML.contains("confidential schedule"))
        let local = previews.preview(owner: sender.owner, conversation: recipient.owner, deliverAt: due, messageXML: row.messageXML)
        let localXML = try XCTUnwrap(local)
        XCTAssertEqual(try XMPPMessage(xmlString: localXML).body, plaintext.body)
        XCTAssertNil(previews.preview(owner: recipient.owner, conversation: sender.owner, deliverAt: due, messageXML: row.messageXML))
        XCTAssertNil(previews.preview(owner: sender.owner, conversation: recipient.owner, deliverAt: due.addingTimeInterval(120), messageXML: row.messageXML))
    }

    func testRecipientRevocationAtFinalSendNeverDispatchesTheSchedule() throws {
        let (sender, recipient) = try devices()
        let (account, stream) = account(for: sender)
        stream.hold = true
        var error: XMPPMessageScheduleManager.ScheduleError?
        let query = account.messageSchedule.scheduleOMEMO2Message(
            stream, conversation: recipient.owner, deliverAt: Date().addingTimeInterval(3600),
            plaintext: message(from: sender.owner, to: recipient.owner, body: "revoke before dispatch"),
            omemo: sender.manager
        ) { if case .failure(let failure) = $0 { error = failure } }
        XCTAssertNotNil(query)
        let frame = try XCTUnwrap(stream.queued.first)
        let projection = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self,
            forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: sender.owner, jid: recipient.owner, deviceId: recipient.bundle.deviceID)))
        try realm.write { projection.state = .revoked }
        stream.transmit(frame)
        XCTAssertTrue(stream.sent.isEmpty)
        XCTAssertEqual(error, .sendRejected)
        XCTAssertTrue(realm.objects(XMPPMessageScheduleStorageItem.self).isEmpty)
    }

    func testDelayedCiphertextAuthenticatesAfterNewerTrafficAndRecipientRestart() throws {
        let (sender, recipient) = try devices()
        recipient.manager.omemo2ControlSender = { _ in }
        let now = Date()
        let due = now.addingTimeInterval(3600)
        let warmup = try encryptedNow("warmup", sender: sender, recipient: recipient)
        XCTAssertEqual(try receivedBody(warmup, recipient: recipient.manager, at: now), "warmup")
        let scheduled = try ScheduledOMEMO2.makeEncryptedMessage(
            plaintext: message(from: sender.owner, to: recipient.owner, body: "hour later"),
            conversation: recipient.owner, deliverAt: due, omemo: sender.manager
        )
        let later = try encryptedNow("later ratchet arrives first", sender: sender, recipient: recipient)
        XCTAssertEqual(try receivedBody(later, recipient: recipient.manager, at: now), "later ratchet arrives first")

        let restored = OmemoManager(withOwner: recipient.owner)
        restored.omemo2Storage = try XabberOMEMO2Storage(owner: recipient.owner, persistence: recipient.memory)
        restored.omemo2ControlSender = { _ in }
        let delayed = delivered(scheduled, recipient: recipient.owner, due: due, at: due)
        let late = delivered(scheduled, recipient: recipient.owner, due: due, at: due.addingTimeInterval(900))
        let beforeFailure = recipient.memory.records[recipient.owner]
        guard case .failed = restored.prepareIncoming(late) else { return XCTFail("Clock skew must still fail closed") }
        XCTAssertEqual(recipient.memory.records[recipient.owner], beforeFailure)
        guard case .verified(let clean, _, _) = restored.prepareIncoming(delayed) else {
            return XCTFail("An on-time scheduled packet must authenticate after newer traffic")
        }
        XCTAssertEqual(clean.body, "hour later")
        XCTAssertNotNil(clean.element(forName: "deferred", xmlns: XMPPMessageScheduleManager.namespace))
        guard case .consumed(.duplicate) = restored.prepareIncoming(delayed) else {
            return XCTFail("The delivered scheduled packet must use the ordinary replay path")
        }
    }

    func testDurablePreviewRequiresTheSameDeviceKeyAndExactPacket() throws {
        let (sender, recipient) = try devices()
        let due = Date().addingTimeInterval(3600)
        let plaintext = message(from: sender.owner, to: recipient.owner, body: "preview stays sealed")
        let sealed = try ScheduledOMEMO2.makeEncryptedMessage(
            plaintext: plaintext, conversation: recipient.owner, deliverAt: due, omemo: sender.manager)
        try previews.save(plaintext: plaintext, sealed: sealed, owner: sender.owner, conversation: recipient.owner, deliverAt: due)
        let restored = ScheduledOMEMO2PreviewStore(directory: directory, keyProvider: { _, _ in Data(repeating: 7, count: 32) })
        XCTAssertNotNil(restored.preview(owner: sender.owner, conversation: recipient.owner, deliverAt: due, messageXML: sealed.xmlString))
        let otherDevice = ScheduledOMEMO2PreviewStore(directory: directory, keyProvider: { _, _ in Data(repeating: 8, count: 32) })
        XCTAssertNil(otherDevice.preview(owner: sender.owner, conversation: recipient.owner, deliverAt: due, messageXML: sealed.xmlString))
        let second = try ScheduledOMEMO2.makeEncryptedMessage(plaintext: plaintext, conversation: recipient.owner, deliverAt: due, omemo: sender.manager)
        XCTAssertNil(restored.preview(owner: sender.owner, conversation: recipient.owner, deliverAt: due, messageXML: second.xmlString))
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        let contents = try XCTUnwrap(files).compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        XCTAssertEqual(contents.count, 1)
        let disk = try Data(contentsOf: try XCTUnwrap(contents.first))
        XCTAssertNil(disk.range(of: Data("preview stays sealed".utf8)))
    }

    func testCreatingDeviceRestoresOnlyExactAuthenticatedServerEcho() throws {
        let (sender, recipient) = try devices()
        let (account, stream) = account(for: sender)
        let due = Date().addingTimeInterval(3600)
        let plaintext = message(from: sender.owner, to: recipient.owner, body: "own delivery")
        let unsignedShare = DDXMLElement(name: "share", xmlns: "https://xabber.com/protocol/files")
        plaintext.addChild(unsignedShare)
        _ = try XCTUnwrap(account.messageSchedule.scheduleOMEMO2Message(
            stream, conversation: recipient.owner, deliverAt: due, plaintext: plaintext, omemo: sender.manager
        ))
        let wire = try encryptedMessage(in: XCTUnwrap(stream.sent.first))
        let echo = delivered(wire, recipient: sender.owner, due: due, at: due)
        let before = sender.memory.records[sender.owner]
        guard case .failed = sender.manager.prepareIncoming(echo) else {
            return XCTFail("An unverified carrier must not open a local preview")
        }
        guard case .verified(let clean, _, _) = sender.manager.prepareIncoming(echo, authenticatedScheduleDelivery: true) else {
            return XCTFail("The original installation must show its own delivered ciphertext without a self key")
        }
        XCTAssertEqual(clean.body, "own delivery")
        XCTAssertNil(clean.element(forName: "share", xmlns: "https://xabber.com/protocol/files"))
        XCTAssertNotNil(clean.element(forName: "deferred", xmlns: XMPPMessageScheduleManager.namespace))
        XCTAssertEqual(sender.memory.records[sender.owner], before, "Local echo projection does not advance an incoming ratchet")
        let forged = delivered(wire, recipient: sender.owner, due: due.addingTimeInterval(60), at: due)
        guard case .failed = sender.manager.prepareIncoming(forged, authenticatedScheduleDelivery: true) else {
            return XCTFail("An echo with a different scheduled instant cannot open the bound local draft")
        }
    }

    func testProtectedFilesAndPublicStickersAreAdmittedWhileClearUploadsAreRejected() throws {
        let (sender, recipient) = try devices()
        let base = "https://gallery.example.test/opaque"
        let key = Data(repeating: 2, count: 32).base64EncodedString()
        let iv = Data(repeating: 1, count: 16).base64EncodedString()
        let protection = "<encrypted xmlns='urn:xmpp:esfs:0'><key>\(key)</key><iv>\(iv)</iv></encrypted>"
        func packet(protection: String, sticker: Bool = false) throws -> XMPPMessage {
            let share = """
            <file-sharing xmlns='https://xabber.com/protocol/files'><file><size>9</size>\(protection)</file>
              <sources><uri>\(base)</uri></sources>
            </file-sharing>
            """
            let content = sticker ? "<sticker xmlns='https://xabber.com/protocol/stickers'>\(share)</sticker>" : share
            return try XMPPMessage(xmlString: """
            <message xmlns='jabber:client' type='chat' to='\(recipient.owner)' from='\(sender.owner)'>
              <body>caption</body><reference xmlns='https://xabber.com/protocol/references' type='mutable'>\(content)</reference>
            </message>
            """)
        }
        let due = Date().addingTimeInterval(3600)
        XCTAssertThrowsError(try ScheduledOMEMO2.makeEncryptedMessage(
            plaintext: packet(protection: ""), conversation: recipient.owner, deliverAt: due, omemo: sender.manager
        ))
        for plaintext in [try packet(protection: protection), try packet(protection: "", sticker: true)] {
            let sealed = try ScheduledOMEMO2.makeEncryptedMessage(
                plaintext: plaintext, conversation: recipient.owner, deliverAt: due, omemo: sender.manager
            )
            XCTAssertFalse(sealed.xmlString.contains(base))
            XCTAssertFalse(sealed.xmlString.contains(key))
            XCTAssertFalse(sealed.xmlString.contains("caption"))
        }
    }

    private func message(from: String, to: String, body: String) -> XMPPMessage {
        let result = XMPPMessage(type: "chat", to: XMPPJID(string: to), elementID: UUID().uuidString)
        result.setXmlns("jabber:client")
        result.addAttribute(withName: "from", stringValue: from)
        result.addBody(body)
        return result
    }

    private func wireTime(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func encryptedMessage(in iq: XMPPIQ) throws -> XMPPMessage {
        let envelope = try XCTUnwrap(iq.element(forName: "schedule", xmlns: XMPPMessageScheduleManager.namespace))
        let inner = try XCTUnwrap(envelope.element(forName: "message", xmlns: "jabber:client"))
        return XMPPMessage(from: inner)
    }

    private func delivered(_ source: XMPPMessage, recipient: String, due: Date, at: Date) -> XMPPMessage {
        let copy = source.copy() as! XMPPMessage
        let delivery = DDXMLElement(name: "time", xmlns: "https://xabber.com/protocol/delivery")
        delivery.addAttribute(withName: "by", stringValue: recipient)
        delivery.addAttribute(withName: "stamp", stringValue: wireTime(at))
        copy.addChild(delivery)
        let marker = DDXMLElement(name: "deferred", xmlns: XMPPMessageScheduleManager.namespace)
        marker.addAttribute(withName: "id", stringValue: "server-schedule")
        marker.addAttribute(withName: "deliver-at", stringValue: wireTime(due))
        copy.addChild(marker)
        return copy
    }

    private func encryptedNow(_ body: String, sender: Device, recipient: Device) throws -> XMPPMessage {
        let envelope = try XCTUnwrap(sender.manager.prepareStanzaContent(message: body, date: Date(), jid: recipient.owner,
            additionalContent: [], ignoreTimeSignature: true))
        let ciphertext = try sender.manager.encryptPreparedMessage(message: envelope, to: recipient.owner)
        let result = message(from: sender.owner, to: recipient.owner, body: "")
        result.addChild(ciphertext.element)
        return result
    }

    private func receivedBody(_ message: XMPPMessage, recipient: OmemoManager, at: Date) throws -> String? {
        let delivery = DDXMLElement(name: "time", xmlns: "https://xabber.com/protocol/delivery")
        delivery.addAttribute(withName: "by", stringValue: recipient.owner)
        delivery.addAttribute(withName: "stamp", stringValue: wireTime(at))
        message.addChild(delivery)
        guard case .verified(let clean, _, _) = recipient.prepareIncoming(message) else {
            XCTFail("Expected authenticated recipient data")
            return nil
        }
        return clean.body
    }

    private func devices() throws -> (Device, Device) {
        let suffix = UUID().uuidString.lowercased()
        let sender = try device(owner: "schedule-sender-\(suffix)@example.test", id: 41)
        let recipient = try device(owner: "schedule-recipient-\(suffix)@example.test", id: 42)
        try cache(recipient, observer: sender)
        try cache(sender, observer: recipient)
        for observer in [sender, recipient] {
            try advertise(sender, observer: observer)
            try advertise(recipient, observer: observer)
        }
        return (sender, recipient)
    }

    private func account(for device: Device) -> (Account, Stream) {
        let account = Account(jid: device.owner, queue: DispatchQueue(label: "scheduled-omemo-tests"))
        account.omemo = device.manager
        account.chatMarkers = ChatMarkersManager(withOwner: device.owner, withoutAfterburnTimer: true)
        account.sendReadiness.onReadinessChanged = nil
        account.sendReadiness.markStreamManagementEnabled()
        account.messageSchedule.isAvailable = true
        account.messageSchedule.omemo2OptOutStorage = device.storage
        account.messageSchedule.omemo2Previews = previews
        let stream = Stream()
        stream.myJID = XMPPJID(string: "\(device.owner)/ios")
        stream.account = account
        account.xmppStream = stream
        AccountManager.shared.users.append(account)
        accounts.append(account)
        return (account, stream)
    }

    private func device(owner: String, id: Int) throws -> Device {
        let memory = Memory()
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: memory)
        let bundle = try storage.prepare(deviceID: id, preKeyCount: 4)
        let manager = OmemoManager(withOwner: owner)
        manager.omemo2Storage = storage
        _ = try manager.ensureOMEMO2Prepared(attemptPublication: false)
        return Device(manager: manager, storage: storage, memory: memory, bundle: bundle)
    }

    private func cache(_ device: Device, observer: Device) throws {
        let bundle = device.bundle
        let identity = SignalIdentityStorageItem()
        identity.primary = SignalIdentityStorageItem.genRpimary(owner: observer.owner, jid: device.owner, deviceId: bundle.deviceID)
        identity.owner = observer.owner; identity.jid = device.owner; identity.deviceId = bundle.deviceID
        identity.protocolProfile = OmemoManager.xmlns; identity.cryptoBackend = XabberOMEMO2Storage.backend
        identity.identityKey = bundle.identityKey.base64EncodedString()
        identity.signedPreKey = bundle.signedPreKey.base64EncodedString()
        identity.signedPreKeyId = Int(bundle.signedPreKeyID)
        identity.signedPreKeySignature = bundle.signature.base64EncodedString()
        let projection = SignalDeviceStorageItem()
        projection.owner = observer.owner; projection.jid = device.owner; projection.deviceId = bundle.deviceID
        projection.primary = SignalDeviceStorageItem.genPrimary(owner: observer.owner, jid: device.owner, deviceId: bundle.deviceID)
        projection.state = .trusted
        projection.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey)
        let prekeys = bundle.preKeys.map { key -> SignalPreKeysStorageItem in
            let row = SignalPreKeysStorageItem()
            row.owner = observer.owner; row.jid = device.owner; row.deviceId = bundle.deviceID
            row.pkId = Int(key.id); row.preKey = key.publicKey.base64EncodedString()
            row.keyUUID = UUID().uuidString; row.primary = row.keyUUID
            return row
        }
        try realm.write {
            realm.add(identity, update: .modified)
            realm.add(projection, update: .modified)
            realm.add(prekeys)
        }
    }

    private func advertise(_ device: Device, observer: Device) throws {
        let wire = try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(device.owner)' type='headline'>
          <event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:devices'><item id='current'>
            <devices xmlns='urn:xmpp:omemo:2'><device id='\(device.bundle.deviceID)'/></devices>
          </item></items></event>
        </message>
        """)
        XCTAssertTrue(observer.manager.onContactDeviceListReceiveHeadline(wire))
    }
}
