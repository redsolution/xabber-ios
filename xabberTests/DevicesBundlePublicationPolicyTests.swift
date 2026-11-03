import Foundation
import RealmSwift
import XMPPFramework
import XCTest
@testable import xabber

/// Captures real publication XML; no socket, account login, or server mutation.
final class DevicesBundlePublicationPolicyTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
    }
    private final class CapturingStream: XMPPStream {
        var authenticated = true
        override var isAuthenticated: Bool { authenticated }
        override var isDisconnected: Bool { false }
        var packets: [DDXMLElement] = []
        var onSend: ((DDXMLElement) -> Void)?
        override func send(_ element: DDXMLElement) { packets.append(element.copy() as! DDXMLElement); onSend?(element) }
    }
    private struct Fixture {
        let account: Account
        let stream: CapturingStream
        let storage: XabberOMEMO2Storage
        let uuid: String
        var manager: OmemoManager { account.omemo }
        var owner: String { account.jid }
    }
    private var originalRealm: Realm.Configuration!
    private var keeper: Realm?
    private var originalUsers: [Account] = []
    private var fixtures: [Fixture] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment))
        originalRealm = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "devices-bundle-policy-\(UUID())")
        keeper = try WRealm.safe()
        originalUsers = AccountManager.shared.users
    }
    override func tearDownWithError() throws {
        guard originalRealm != nil else { return }
        for f in fixtures {
            f.account.queue.sync {}
            f.manager.omemo2MaintenanceWorkItem?.cancel()
            f.manager.clearSession()
            f.account.messages.updateSendingMessagesTimer?.invalidate()
            f.account.xmppTaskScheduler.reset()
            CredentialsManager.shared.removeDeviceId(for: f.owner)
        }
        AccountManager.shared.users = originalUsers
        keeper = nil
        Realm.Configuration.defaultConfiguration = originalRealm
        try super.tearDownWithError()
    }

    func testCachedDevicesUUIDDoesNotAuthorizeManagedBundlePublication() throws {
        let f = try fixture(accepted: false)
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        XCTAssertTrue(f.stream.packets.isEmpty)
        XCTAssertTrue(f.manager.omemo2BundlePublications.isEmpty)
    }

    func testAuthenticatedManagedStreamWithoutAcceptedProofDoesNotSpinAccountActions() throws {
        let f = try fixture(accepted: false)
        defer { f.stream.authenticated = false; f.account.queue.sync {} }
        f.manager.shouldPublicate = true
        f.manager.retryOMEMO2BundlePublication()
        let deadline = Date().addingTimeInterval(1)
        while !f.account.isActionQueueQuiescentForTests, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(f.account.isActionQueueQuiescentForTests)
        XCTAssertTrue(f.stream.packets.isEmpty)
        XCTAssertTrue(f.manager.shouldPublicate)
    }

    func testAcceptedDeviceBindingRequiresFreshDevicesMetadataBeforePublishing() throws {
        let f = try fixture()
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: true)
        let query = try latestMetadataRequest(f)
        XCTAssertEqual(query.attributeStringValue(forName: "to"), f.owner)
        XCTAssertTrue(publications(f).isEmpty)
        XCTAssertTrue(retractions(f).isEmpty)
        XCTAssertFalse(try ownIdentity(f).isPublicated)
    }

    func testUnmappedCurrentDevicePublishesRetainedBundleWithoutOptionsOrListWrites() throws {
        let f = try fixture()
        let before = try f.storage.localBundle()
        let id = try begin(f)
        XCTAssertTrue(f.manager.read(withIQ: metadata(f, id: id, currentSID: nil), on: f.stream))
        let item = try XCTUnwrap(publications(f).last)
        XCTAssertEqual(item.attributeStringValue(forName: "id"), "42")
        XCTAssertEqual(try OMEMO2BundleCodec.decode(item: item).identityKey, before.identityKey)
        XCTAssertEqual(try f.storage.localBundle().deviceID, before.deviceID)
        XCTAssertTrue(f.stream.packets.allSatisfy { packet in
            guard let pubsub = packet.element(forName: "pubsub") else { return true }
            return pubsub.element(forName: "configure") == nil && pubsub.element(forName: "create") == nil &&
                pubsub.element(forName: "publish-options") == nil &&
                pubsub.element(forName: "publish")?.attributeStringValue(forName: "node") != OmemoManager.NodeType.device.rawValue
        })
        XCTAssertFalse(try ownIdentity(f).isPublicated)
    }

    func testAlreadyMatchingServerSIDPublishesWithoutRetraction() throws {
        let f = try fixture()
        let id = try begin(f)
        XCTAssertTrue(f.manager.read(withIQ: metadata(f, id: id, currentSID: "42"), on: f.stream))
        XCTAssertEqual(publications(f).count, 1)
        XCTAssertTrue(retractions(f).isEmpty)
    }

    func testMismatchedCurrentDeviceSIDRequiresRecoveryWithoutRetraction() throws {
        let f = try fixture(); let before = try f.storage.identity().publicKey
        let id = try begin(f)
        XCTAssertTrue(f.manager.read(withIQ: metadata(f, id: id, currentSID: "7", siblings: [("sibling", "99")]), on: f.stream))
        XCTAssertTrue(retractions(f).isEmpty); XCTAssertTrue(publications(f).isEmpty)
        XCTAssertEqual(try f.storage.localBundle().deviceID, 42)
        XCTAssertEqual(try f.storage.identity().publicKey, before)
        if case OMEMO2StorageError.devicesStateIDMismatch? = f.manager.omemo2ManagedDevicesPublication.lastError as? OMEMO2StorageError {} else { XCTFail("Expected controlled ID mismatch") }
    }

    func testOldSIDSharedWithSiblingIsNeverRetracted() throws {
        let f = try fixture(); let id = try begin(f)
        _ = f.manager.read(withIQ: metadata(f, id: id, currentSID: "7", siblings: [("sibling", "7")]), on: f.stream)
        XCTAssertTrue(retractions(f).isEmpty)
        XCTAssertTrue(publications(f).isEmpty)
    }

    func testLocalSIDMappedToSiblingCannotBePublishedOrTriggerCleanup() throws {
        for currentSID in [nil, "7"] as [String?] {
            let f = try fixture(); let id = try begin(f)
            _ = f.manager.read(withIQ: metadata(f, id: id, currentSID: currentSID, siblings: [("sibling", "42")]), on: f.stream)
            XCTAssertTrue(publications(f).isEmpty)
            XCTAssertTrue(retractions(f).isEmpty)
        }
    }

    func testDuplicateCurrentDevicesRecordAndMalformedSIDFailClosed() throws {
        for (sid, siblings) in [("7", [("current-device", "7")]), ("0", []), ("2147483648", []), ("bad", [])] {
            let f = try fixture(); let id = try begin(f)
            _ = f.manager.read(withIQ: metadata(f, id: id, currentSID: sid, siblings: siblings), on: f.stream)
            XCTAssertTrue(publications(f).isEmpty)
            XCTAssertTrue(retractions(f).isEmpty)
        }
    }

    func testWrongSenderRecipientOrIQIDDoesNotConsumeTheMetadataRequest() throws {
        let f = try fixture(); let id = try begin(f)
        for response in [metadata(f, id: "other-iq", currentSID: nil),
                         metadata(f, id: id, currentSID: nil, from: "attacker@example.test"),
                         metadata(f, id: id, currentSID: nil, to: f.owner + "/another-resource")] {
            XCTAssertFalse(f.manager.read(withIQ: response, on: f.stream))
            XCTAssertTrue(publications(f).isEmpty)
        }
        XCTAssertTrue(f.manager.read(withIQ: metadata(f, id: id, currentSID: nil), on: f.stream))
        XCTAssertEqual(publications(f).count, 1)
    }

    func testDifferentStreamCannotCompleteMetadataOrPublicationACK() throws {
        let f = try fixture(); let id = try begin(f)
        let other = CapturingStream(); other.myJID = f.stream.myJID
        XCTAssertFalse(f.manager.read(withIQ: metadata(f, id: id, currentSID: nil), on: other))
        XCTAssertTrue(f.manager.read(withIQ: metadata(f, id: id, currentSID: nil), on: f.stream))
        let publicationID = try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)
        XCTAssertFalse(f.manager.read(withIQ: result(f, id: publicationID), on: other))
        XCTAssertFalse(try ownIdentity(f).isPublicated)
        XCTAssertTrue(f.manager.read(withIQ: result(f, id: publicationID), on: f.stream))
        XCTAssertTrue(try ownIdentity(f).isPublicated)
    }

    func testResetOrChangedAuthenticatedUUIDRejectsThePreviousResponse() throws {
        for reset in [true, false] {
            let f = try fixture(); let id = try begin(f)
            let before = try f.storage.identity().publicKey
            if reset { f.manager.clearSession() }
            else { f.account.devices.recordAuthenticatedSession(on: f.stream, deviceID: "changed-device", didResume: false) }
            XCTAssertFalse(f.manager.read(withIQ: metadata(f, id: id, currentSID: nil), on: f.stream))
            XCTAssertTrue(publications(f).isEmpty)
            XCTAssertEqual(try f.storage.identity().publicKey, before)
        }
    }

    func testReauthenticationOnSameStreamAndUUIDRejectsPreviousResponse() throws {
        let f = try fixture(); let id = try begin(f)
        f.account.devices.recordAuthenticatedSession(on: f.stream, deviceID: f.uuid, didResume: false)
        XCTAssertFalse(f.manager.read(withIQ: metadata(f, id: id, currentSID: nil), on: f.stream))
        XCTAssertTrue(publications(f).isEmpty)
    }

    func testMismatchCannotBeRecoveredByUnrelatedACKOrAutomaticRetry() throws {
        let f = try fixture(); let id = try begin(f)
        _ = f.manager.read(withIQ: metadata(f, id: id, currentSID: "7"), on: f.stream)
        XCTAssertFalse(f.manager.read(withIQ: result(f, id: id), on: f.stream))
        let count = f.stream.packets.count
        f.manager.retryOMEMO2BundlePublication(on: f.stream)
        XCTAssertEqual(f.stream.packets.count, count)
        XCTAssertTrue(retractions(f).isEmpty); XCTAssertTrue(publications(f).isEmpty)
    }

    func testPolicyViolationForcesOneFreshReadAndDoesNotRepeatIdenticalPublication() throws {
        let f = try fixture(); var now = Date(timeIntervalSince1970: 1_700_000_000)
        f.manager.omemo2MaintenanceNow = { now }
        let id = try begin(f)
        _ = f.manager.read(withIQ: metadata(f, id: id, currentSID: "42"), on: f.stream)
        let publicationID = try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)
        _ = f.manager.read(withIQ: result(f, id: publicationID, error: true), on: f.stream)
        now.addTimeInterval(OmemoManager.omemo2PublicationRetryInterval + 1)
        f.manager.retryOMEMO2BundlePublication(on: f.stream)
        let refreshID = try XCTUnwrap(latestMetadataRequest(f).attributeStringValue(forName: "id"))
        XCTAssertNotEqual(refreshID, id)
        _ = f.manager.read(withIQ: metadata(f, id: refreshID, currentSID: "42"), on: f.stream)
        XCTAssertEqual(publications(f).count, 1)
        now.addTimeInterval(OmemoManager.omemo2PublicationRetryInterval * 3)
        f.manager.retryOMEMO2BundlePublication(on: f.stream)
        XCTAssertEqual(publications(f).count, 1)
    }

    func testMetadataTimeoutReplacesRequestAndRejectsItsLateReply() throws {
        let f = try fixture(); var now = Date(timeIntervalSince1970: 1_700_000_000)
        f.manager.omemo2MaintenanceNow = { now }
        let old = try begin(f)
        now.addTimeInterval(OmemoManager.omemo2PublicationIQTimeout + 1)
        f.manager.retryOMEMO2BundlePublication(on: f.stream)
        let next = try XCTUnwrap(latestMetadataRequest(f).attributeStringValue(forName: "id"))
        XCTAssertNotEqual(old, next)
        XCTAssertFalse(f.manager.read(withIQ: metadata(f, id: old, currentSID: nil), on: f.stream))
        XCTAssertTrue(f.manager.read(withIQ: metadata(f, id: next, currentSID: nil), on: f.stream))
        XCTAssertEqual(publications(f).count, 1)
    }

    func testActualAccountIQRoutingDeliversOwnedMetadataToPublicationBeforeDeviceProjection() throws {
        let f = try fixture(); let id = try begin(f)
        XCTAssertTrue(f.account.xmppStream(f.stream, didReceive: metadata(f, id: id, currentSID: nil)))
        XCTAssertEqual(publications(f).count, 1)
    }

    func testMissingCurrentUUIDDuplicateSiblingUUIDAndInvalidOMEMONamespacesFailClosed() throws {
        for variant in 0..<4 {
            let f = try fixture(); let id = try begin(f)
            let reply = metadata(f, id: id, currentSID: "7", siblings: [("sibling", "99")])
            let query = try XCTUnwrap(reply.element(forName: "query"))
            let current = try XCTUnwrap(query.elements(forName: "device").first)
            switch variant {
            case 0: current.detach()
            case 1: query.addChild(try XCTUnwrap(query.elements(forName: "device").last?.copy() as? DDXMLElement))
            case 2:
                current.element(forName: "omemo-id")?.detach()
                let foreign = DDXMLElement(name: "omemo-id", xmlns: "urn:foreign"); foreign.stringValue = "7"
                current.addChild(foreign)
            default: current.addChild(DDXMLElement(name: "omemo-id", stringValue: "8"))
            }
            _ = f.manager.read(withIQ: reply, on: f.stream)
            XCTAssertTrue(publications(f).isEmpty)
            XCTAssertTrue(retractions(f).isEmpty)
        }
    }

    func testResourceChangeWhileMetadataIsPendingRejectsItsReply() throws {
        let f = try fixture(); let id = try begin(f)
        let reply = metadata(f, id: id, currentSID: nil)
        f.stream.myJID = XMPPJID(string: f.owner + "/replacement-resource")
        XCTAssertFalse(f.manager.read(withIQ: reply, on: f.stream))
        XCTAssertTrue(publications(f).isEmpty)
    }

    func testCollisionInFreshMetadataCannotAuthorizePublicationOrCleanup() throws {
        let f = try fixture(); let id = try begin(f)
        _ = f.manager.read(withIQ: metadata(f, id: id, currentSID: "42", siblings: [("sibling", "42")]), on: f.stream)
        XCTAssertTrue(publications(f).isEmpty); XCTAssertTrue(retractions(f).isEmpty)
        XCTAssertEqual(try f.storage.localBundle().deviceID, 42)
    }

    func testDisabledManagedDeviceWithdrawsOnlyItsFreshlyProvenUniqueServerSID() throws {
        for collision in [false, true] {
            let f = try fixture(enabled: false)
            try f.manager.publicateOwnDevice(f.stream, createNode: false)
            let id = try XCTUnwrap(latestMetadataRequest(f).attributeStringValue(forName: "id"))
            _ = f.manager.read(withIQ: metadata(f, id: id, currentSID: "42", siblings: [("sibling", collision ? "42" : "99")]), on: f.stream)
            XCTAssertEqual(retractions(f).count, collision ? 0 : 1)
            if !collision {
                let retractID = try XCTUnwrap(f.stream.packets.last?.attributeStringValue(forName: "id"))
                _ = f.manager.read(withIQ: result(f, id: retractID), on: f.stream)
            }
            XCTAssertTrue(publications(f).isEmpty)
            XCTAssertFalse(try ownIdentity(f).isPublicated)
        }
    }

    func testDisabledMismatchedCurrentSIDCannotDeleteEitherDeviceBundle() throws {
        let f = try fixture(enabled: false)
        try f.manager.publicateOwnDevice(f.stream, createNode: false)
        let id = try XCTUnwrap(latestMetadataRequest(f).attributeStringValue(forName: "id"))
        _ = f.manager.read(withIQ: metadata(f, id: id, currentSID: "7", siblings: [("sibling", "42")]), on: f.stream)
        XCTAssertTrue(retractions(f).isEmpty); XCTAssertTrue(publications(f).isEmpty)
    }

    func testUnprovenSecondaryStreamUsesAvailableAcceptedPrimaryForPublicationAndWithdrawal() throws {
        for enabled in [true, false] {
            let f = try fixture(enabled: enabled)
            let secondary = CapturingStream(); secondary.myJID = XMPPJID(string: f.owner + "/unproven-secondary")
            try f.manager.publicateOwnDevice(secondary, createNode: false)
            XCTAssertTrue(secondary.packets.isEmpty)
            XCTAssertNotNil(try latestMetadataRequest(f).attributeStringValue(forName: "id"))
        }
    }

    func testDisableDuringPublicationWaitsForACKThenWithdrawsWithoutGrantingPublication() throws {
        let f = try fixture(); let id = try begin(f)
        _ = f.manager.read(withIQ: metadata(f, id: id, currentSID: "42"), on: f.stream)
        let publicationID = try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)
        try setEnabled(f, false)
        try f.manager.publicateOwnDevice(f.stream, createNode: false)
        XCTAssertTrue(retractions(f).isEmpty)
        _ = f.manager.read(withIQ: result(f, id: publicationID), on: f.stream)
        XCTAssertFalse(try ownIdentity(f).isPublicated)
        let queryID = try XCTUnwrap(latestMetadataRequest(f).attributeStringValue(forName: "id"))
        XCTAssertNotEqual(queryID, id)
        _ = f.manager.read(withIQ: metadata(f, id: queryID, currentSID: "42"), on: f.stream)
        XCTAssertEqual(retractions(f).map { $0.attributeStringValue(forName: "id") }, ["42"])
        XCTAssertEqual(publications(f).count, 1)
    }

    func testReenableWhileWithdrawalIsOnWireWaitsForACKAndRefetchBeforePublishing() throws {
        let f = try fixture(enabled: false)
        try f.manager.publicateOwnDevice(f.stream, createNode: false)
        let id = try XCTUnwrap(latestMetadataRequest(f).attributeStringValue(forName: "id"))
        _ = f.manager.read(withIQ: metadata(f, id: id, currentSID: "42"), on: f.stream)
        let retractID = try XCTUnwrap(f.stream.packets.last?.attributeStringValue(forName: "id"))
        try setEnabled(f, true)
        try f.manager.publicateOwnDevice(f.stream, createNode: false)
        XCTAssertTrue(publications(f).isEmpty)
        _ = f.manager.read(withIQ: result(f, id: retractID), on: f.stream)
        let verifyID = try XCTUnwrap(latestMetadataRequest(f).attributeStringValue(forName: "id"))
        _ = f.manager.read(withIQ: metadata(f, id: verifyID, currentSID: nil), on: f.stream)
        if let refresh = f.manager.omemo2ManagedDevicesPublication.pending,
           case .metadata = refresh.operation {
            _ = f.manager.read(withIQ: metadata(f, id: refresh.id, currentSID: nil), on: f.stream)
        }
        XCTAssertEqual(publications(f).count, 1)
    }

    func testLateOrWrongStreamWithdrawalACKCannotPublishAfterReset() throws {
        let f = try fixture(enabled: false)
        try f.manager.publicateOwnDevice(f.stream, createNode: false)
        let id = try XCTUnwrap(latestMetadataRequest(f).attributeStringValue(forName: "id"))
        _ = f.manager.read(withIQ: metadata(f, id: id, currentSID: "42"), on: f.stream)
        let retractID = try XCTUnwrap(f.stream.packets.last?.attributeStringValue(forName: "id"))
        let other = CapturingStream(); other.myJID = f.stream.myJID
        XCTAssertFalse(f.manager.read(withIQ: result(f, id: retractID), on: other))
        f.manager.clearSession()
        XCTAssertFalse(f.manager.read(withIQ: result(f, id: retractID), on: f.stream))
        XCTAssertTrue(publications(f).isEmpty)
    }

    func testAcceptedLegacyHOTPDoesNotAuthorizePublicationOrWithdrawal() throws {
        let f = try fixture(accepted: false)
        f.account.devices.recordAuthenticatedSession(on: f.stream, deviceID: nil, didResume: false, legacyHOTP: true)
        XCTAssertNil(f.account.devices.authenticatedDeviceID(on: f.stream))
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        XCTAssertTrue(publications(f).isEmpty); XCTAssertTrue(retractions(f).isEmpty)
        XCTAssertFalse(f.manager.read(withIQ: result(f, id: "unowned", error: true), on: f.stream))
        f.manager.shouldPublicate = true; f.manager.omemo2PublicationRetryAt = nil
        f.manager.retryOMEMO2BundlePublication(on: f.stream)
        XCTAssertTrue(publications(f).isEmpty)
    }

    private func setEnabled(_ f: Fixture, _ enabled: Bool) throws {
        let realm = try WRealm.safe()
        try realm.write { realm.object(ofType: AccountStorageItem.self, forPrimaryKey: f.owner)?.isEncryptionEnabled = enabled }
    }

    private func fixture(accepted: Bool = true, enabled: Bool = true) throws -> Fixture {
        let owner = "devices-publication-\(UUID().uuidString.lowercased())@example.test"
        let realm = try WRealm.safe()
        let row = AccountStorageItem(); row.jid = owner; row.deviceUuid = "current-device"; row.isEncryptionEnabled = enabled
        try realm.write { realm.add(row) }
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: Memory())
        _ = try storage.prepare(deviceID: 42, preKeyCount: 2)
        let identity = try storage.identity().publicKey
        try storage.markRegistrationConfirmed(deviceID: 42, identityKey: identity, isCurrent: { true })
        let account = Account(jid: owner, queue: DispatchQueue(label: "devices-publication-tests-\(UUID())"))
        account.omemo.omemo2Storage = storage
        account.omemo.omemo2MaintenanceScheduler = { _, _ in }
        _ = try account.omemo.ensureOMEMO2Prepared(attemptPublication: false)
        let stream = CapturingStream(); stream.myJID = XMPPJID(string: owner + "/ios-test")
        account.xmppStream = stream
        let features = DDXMLElement(name: "features")
        features.addChild(DDXMLElement(name: "devices", xmlns: "https://xabber.com/protocol/devices"))
        account.devices.setAvailable(features)
        let f = Fixture(account: account, stream: stream, storage: storage, uuid: "current-device")
        fixtures.append(f); AccountManager.shared.users = originalUsers + fixtures.map(\.account)
        if accepted { account.devices.recordAuthenticatedSession(on: stream, deviceID: f.uuid, didResume: false) }
        let snapshot = OMEMO2DeviceListStorageItem()
        snapshot.primary = OMEMO2DeviceListStorageItem.genPrimary(owner: owner, jid: owner)
        snapshot.owner = owner; snapshot.jid = owner; snapshot.isKnown = true; snapshot.itemID = "current"
        snapshot.deviceIDs.append(objectsIn: [42, 99])
        snapshot.devicesXML = "<devices xmlns='urn:xmpp:omemo:2'><device id='42'/><device id='99'/></devices>"
        try realm.write { realm.add(snapshot, update: .modified) }
        stream.onSend = { [weak manager = account.omemo, weak stream] packet in
            guard let manager, let stream, packet.attributeStringValue(forName: "type") == "get",
                  let id = packet.attributeStringValue(forName: "id"),
                  let items = packet.element(forName: "pubsub")?.element(forName: "items"),
                  let node = items.attributeStringValue(forName: "node") else { return }
            if case .confirmation = manager.omemo2ManagedDevicesPublication.pending?.operation { return }
            let pubsub = DDXMLElement(name: "pubsub", xmlns: OMEMO2DeviceListCodec.pubsub)
            let resultItems = DDXMLElement(name: "items"); resultItems.addAttribute(withName: "node", stringValue: node)
            if node == OmemoManager.NodeType.device.rawValue {
                let item = DDXMLElement(name: "item"); item.addAttribute(withName: "id", stringValue: "current")
                item.addChild(try! DDXMLElement(xmlString: "<devices xmlns='urn:xmpp:omemo:2'><device id='42'/><device id='99'/></devices>"))
                resultItems.addChild(item)
            }
            pubsub.addChild(resultItems)
            let reply = XMPPIQ(iqType: .result, to: stream.myJID, elementID: id, child: pubsub)
            reply.addAttribute(withName: "from", stringValue: owner)
            _ = manager.read(withIQ: try! XMPPIQ(xmlString: reply.xmlString), on: stream)
        }
        return f
    }
    private func begin(_ f: Fixture) throws -> String {
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        return try XCTUnwrap(latestMetadataRequest(f).attributeStringValue(forName: "id"))
    }
    private func latestMetadataRequest(_ f: Fixture) throws -> DDXMLElement {
        try XCTUnwrap(f.stream.packets.last { $0.attributeStringValue(forName: "type") == "get" &&
            $0.element(forName: "query", xmlns: "https://xabber.com/protocol/devices#items") != nil })
    }
    private func publications(_ f: Fixture) -> [DDXMLElement] { items(f, operation: "publish") }
    private func retractions(_ f: Fixture) -> [DDXMLElement] { items(f, operation: "retract") }
    private func items(_ f: Fixture, operation: String) -> [DDXMLElement] {
        f.stream.packets.flatMap { packet -> [DDXMLElement] in
            guard let operation = packet.element(forName: "pubsub")?.element(forName: operation),
                  operation.attributeStringValue(forName: "node") == OmemoManager.NodeType.bundle.rawValue else { return [] }
            return operation.elements(forName: "item")
        }
    }
    private func metadata(_ f: Fixture, id: String, currentSID: String?, siblings: [(String, String)] = [],
                          from: String? = nil, to: String? = nil) -> XMPPIQ {
        let query = DDXMLElement(name: "query", xmlns: "https://xabber.com/protocol/devices#items")
        for (uuid, sid) in [(f.uuid, currentSID)] + siblings.map({ ($0.0, Optional($0.1)) }) {
            let device = DDXMLElement(name: "device", xmlns: "https://xabber.com/protocol/devices")
            device.addAttribute(withName: "id", stringValue: uuid)
            if let sid { device.addChild(DDXMLElement(name: "omemo-id", stringValue: sid)) }
            query.addChild(device)
        }
        let iq = XMPPIQ(iqType: .result, to: XMPPJID(string: to ?? f.stream.myJID!.full), elementID: id, child: query)
        iq.addAttribute(withName: "from", stringValue: from ?? f.owner)
        return try! XMPPIQ(xmlString: iq.xmlString) // Model the actual parsed wire namespace inheritance.
    }
    private func result(_ f: Fixture, id: String, error: Bool = false) -> XMPPIQ {
        let iq = XMPPIQ(iqType: error ? .error : .result, to: f.stream.myJID, elementID: id)
        iq.addAttribute(withName: "from", stringValue: f.owner)
        if error {
            let e = DDXMLElement(name: "error"); e.addAttribute(withName: "type", stringValue: "cancel")
            e.addChild(DDXMLElement(name: "policy-violation", xmlns: "urn:ietf:params:xml:ns:xmpp-stanzas")); iq.addChild(e)
        }
        return iq
    }
    private func ownIdentity(_ f: Fixture) throws -> SignalIdentityStorageItem {
        try XCTUnwrap(WRealm.safe().object(ofType: SignalIdentityStorageItem.self,
            forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: f.owner, jid: f.owner, deviceId: 42)))
    }
}
