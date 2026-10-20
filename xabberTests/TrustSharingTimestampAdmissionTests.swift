import CryptoKit
import Foundation
import RealmSwift
import XCTest
import XMPPFramework
@testable import xabber

/// Real signed PEP ingress must not let rejected shares consume the publisher cursor.
final class TrustSharingTimestampAdmissionTests: XCTestCase {
    private final class Stream: XMPPStream {
        var elements: [DDXMLElement] = []
        override func send(_ element: DDXMLElement) { elements.append(element.copy() as! DDXMLElement) }
    }
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        func load(owner: String) throws -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
    }
    private let publisherID = 41
    private let targetID = 42
    private var previousRealm: Realm.Configuration!
    private var previousUsers: [Account] = []
    private var realm: Realm!
    private var account: Account!
    private var manager: TrustSharingManager!
    private var identity: CryptoKit.Curve25519.Signing.PrivateKey!
    private var publisher: SignalDeviceStorageItem!
    private var target: SignalDeviceStorageItem!
    private var peer: String!

    override func setUpWithError() throws {
        previousRealm = Realm.Configuration.defaultConfiguration
        previousUsers = AccountManager.shared.users
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "TrustSharingAdmission-\(UUID())")
        realm = try WRealm.safe()
        let owner = "trust-owner-\(UUID().uuidString.lowercased())@example.test"
        peer = "publisher@example.test"
        account = Account(jid: owner, queue: DispatchQueue(label: "TrustSharingAdmission-account"))
        AccountManager.shared.users = previousUsers + [account]
        manager = account.trustSharingManager
        let localStorage = try XabberOMEMO2Storage(owner: owner, persistence: Memory())
        _ = try localStorage.prepare(deviceID: 71, preKeyCount: 2)
        account.omemo.omemo2Storage = localStorage
        try account.omemo.localStore.bindExistingDevice(deviceID: 71)
        account.omemo.reconcileLocalOMEMO2Metadata()
        identity = CryptoKit.Curve25519.Signing.PrivateKey()

        publisher = device(owner: owner, jid: peer, id: publisherID)
        publisher.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: identity.publicKey.rawRepresentation)
        publisher.state = .trusted
        target = device(owner: owner, jid: peer, id: targetID)
        let targetKey = CryptoKit.Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        target.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: targetKey)
        let storedIdentity = SignalIdentityStorageItem()
        storedIdentity.owner = owner
        storedIdentity.jid = peer
        storedIdentity.deviceId = publisherID
        storedIdentity.primary = SignalIdentityStorageItem.genRpimary(owner: owner, jid: peer, deviceId: publisherID)
        storedIdentity.identityKey = identity.publicKey.rawRepresentation.base64EncodedString()
        let storedTarget = SignalIdentityStorageItem()
        storedTarget.owner = owner
        storedTarget.jid = peer
        storedTarget.deviceId = targetID
        storedTarget.primary = target.primary
        storedTarget.identityKey = targetKey.base64EncodedString()
        try realm.write {
            realm.add(publisher)
            realm.add(target)
            realm.add(storedIdentity)
            realm.add(storedTarget)
        }
    }

    override func tearDown() {
        account.messages.updateSendingMessagesTimer?.invalidate()
        account.messages.updateSendingMessagesTimer = nil
        AccountManager.shared.users = previousUsers
        account = nil
        manager = nil
        publisher = nil
        target = nil
        realm = nil
        Realm.Configuration.defaultConfiguration = previousRealm
        super.tearDown()
    }

    func testInvalidFutureSignatureCannotSuppressLaterValidShare() throws {
        let invalid = try share(timestamp: 900, entryTimestamp: 900)
        invalid.element(forName: "signature")?.stringValue = Data(repeating: 0, count: 64).base64EncodedString()

        try receive(invalid)

        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 0)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "")
        XCTAssertEqual(target.state, .unknown)
        try receive(share(timestamp: 100, entryTimestamp: 100))
        XCTAssertEqual(target.state, .trusted)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "100")
    }

    func testMalformedCanonicalEntryCannotConsumePublisherTimestamp() throws {
        let malformed = try share(timestamp: 900, entryTimestamp: 900)
        malformed.element(forName: "trust-list")?.element(forName: "trust")?.removeAttribute(forName: "timestamp")

        try receive(malformed)

        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 0)
        XCTAssertEqual(target.state, .unknown)
        try receive(share(timestamp: 100, entryTimestamp: 100))
        XCTAssertEqual(target.state, .trusted)
    }

    func testMalformedKeyCannotSuppressLaterValidShare() throws {
        let malformed = try share(timestamp: 900, entryTimestamp: 900)
        malformed.element(forName: "trust-list")?.element(forName: "trust")?.stringValue = "!invalid-base64!"
        try receive(malformed)

        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 0)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "")
        XCTAssertEqual(target.state, .unknown)
        try receive(share(timestamp: 100, entryTimestamp: 100))
        XCTAssertEqual(target.state, .trusted)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "100")
    }

    func testSignedUnknownTargetCannotConsumePublisherTimestamp() throws {
        try receive(share(timestamp: 900, entryTimestamp: 900, id: 999))

        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 0)
        try receive(share(timestamp: 100, entryTimestamp: 100))
        XCTAssertEqual(target.state, .trusted)
    }

    func testValidShareCommitsCursorAndTrustAndRejectsOlderUpdate() throws {
        try receive(share(timestamp: 200, entryTimestamp: 200))

        XCTAssertEqual(target.state, .trusted)
        XCTAssertEqual(target.trustedByDeviceId, String(publisherID))
        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 0)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "200")
        try receive(share(timestamp: 100, entryTimestamp: 100, state: "distrust"))
        XCTAssertEqual(target.state, .trusted)
        XCTAssertEqual(target.lastTrustSharingTimestamp, 200)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "200")
    }

    func testPublisherSelfEntryIsAppliedBeforeItsContainerCursorIsCommitted() throws {
        try receive(share(timestamp: 100, entryTimestamp: 100, id: publisherID, state: "distrust"))

        XCTAssertEqual(publisher.state, .distrusted)
        XCTAssertNil(publisher.trustedByDeviceId)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "100")
    }

    func testMixedMalformedSignedListCannotPartiallyTrustOrConsumeCursor() throws {
        let packet = try share(timestamp: 900, entryTimestamp: 900)
        let invalid = DDXMLElement(name: "distrust", stringValue: "!invalid-base64!")
        invalid.addAttribute(withName: "timestamp", integerValue: 901)
        packet.element(forName: "trust-list")?.addChild(invalid)

        try receive(packet)

        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(target.lastTrustSharingTimestamp, 0)
        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 0)
        try receive(share(timestamp: 100, entryTimestamp: 100))
        XCTAssertEqual(target.state, .trusted)
    }

    func testStaleFingerprintCannotTrustAReplacementIdentityUnderTheSameSID() throws {
        let oldFingerprint = target.fingerprint
        let replacement = CryptoKit.Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        try realm.write {
            target.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: replacement)
            realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: target.primary)?.identityKey = replacement.base64EncodedString()
        }
        let staleKey = "\(targetID)::\(oldFingerprint.replacingOccurrences(of: " ", with: ""))"

        try receive(share(timestamp: 900, entryTimestamp: 900, value: Data(staleKey.utf8).base64EncodedString()))

        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 0)
        try receive(share(timestamp: 100, entryTimestamp: 100))
        XCTAssertEqual(target.state, .trusted)
    }

    func testMissingTargetIdentityCannotBeTrustedFromFingerprintProjectionAlone() throws {
        try realm.write {
            realm.delete(try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: target.primary)))
        }

        try receive(share(timestamp: 100, entryTimestamp: 100))

        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(target.lastTrustSharingTimestamp, 0)
        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 0)
    }

    func testUnknownSigningPublisherCannotApplyUntilLocallyTrusted() throws {
        try realm.write { publisher.state = .unknown }
        let packet = try share(timestamp: 100, entryTimestamp: 100)

        try receive(packet.copy() as! DDXMLElement)

        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 0)
        try realm.write { publisher.state = .trusted }
        try receive(packet)
        XCTAssertEqual(target.state, .trusted)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "100")
    }

    func testDistrustedSigningPublisherCannotApplyOrConsumeCursor() throws {
        try realm.write { publisher.state = .distrusted }

        try receive(share(timestamp: 100, entryTimestamp: 100))

        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 0)
    }

    func testExactLocalIdentityCanAuthorizeItsOwnShareWithoutRemoteTrustBootstrap() throws {
        try useLocalPublisher(localID: publisherID, publisherJID: account.jid)

        try receive(share(timestamp: 100, entryTimestamp: 100))

        XCTAssertEqual(target.state, .trusted)
        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 0)
        XCTAssertEqual(TrustSharingManager.publisherDiagnosticTimestamp(publisher), 100)
    }

    func testLocalIdentityUnderRemoteJIDCannotBypassPublisherTrust() throws {
        try useLocalPublisher(localID: publisherID, publisherJID: peer)

        try receive(share(timestamp: 100, entryTimestamp: 100))

        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 0)
    }

    func testLocalIdentityUnderAnotherSIDCannotBypassPublisherTrust() throws {
        try useLocalPublisher(localID: 999, publisherJID: account.jid)

        try receive(share(timestamp: 100, entryTimestamp: 100))

        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 0)
    }

    func testAnotherIdentityUnderLocalSIDCannotBypassPublisherTrust() throws {
        try useLocalPublisher(localID: publisherID, publisherJID: account.jid, useLocalKey: false)

        try receive(share(timestamp: 100, entryTimestamp: 100))

        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 0)
    }

    func testPublisherListCursorDoesNotConsumeItsLaterSelfDecision() throws {
        try receive(share(timestamp: 300, entryTimestamp: 100))

        try receive(share(timestamp: 400, entryTimestamp: 200, id: publisherID, state: "distrust"))

        XCTAssertEqual(publisher.state, .distrusted)
        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 200)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "400")
    }

    func testNewerPublisherTrustDecisionDoesNotSuppressItsUnseenOlderList() throws {
        try realm.write { publisher.lastTrustSharingTimestamp = 900 }

        try receive(share(timestamp: 200, entryTimestamp: 100))

        XCTAssertEqual(target.state, .trusted)
        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 900)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "200")
    }

    func testTargetDecisionDoesNotOverwriteItsIndependentPublisherListCursor() throws {
        try realm.write {
            target.lastTrustSharingTimestamp = 100
            target.lastTrustedItemsUpdateTimestamp = "500"
        }

        try receive(share(timestamp: 600, entryTimestamp: 200))

        XCTAssertEqual(target.state, .trusted)
        XCTAssertEqual(target.lastTrustSharingTimestamp, 200)
        XCTAssertEqual(target.lastTrustedItemsUpdateTimestamp, "500")
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "600")
    }

    func testNewerListCannotReplaceANewerTargetDecisionWithOlderTrust() throws {
        try realm.write {
            target.state = .distrusted
            target.lastTrustSharingTimestamp = 300
        }

        try receive(share(timestamp: 500, entryTimestamp: 200))

        XCTAssertEqual(target.state, .distrusted)
        XCTAssertEqual(target.lastTrustSharingTimestamp, 300)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "500")
    }

    func testPublicationPreservesSavedDecisionTimestampAcrossRepublishing() throws {
        try useLocalPublisher(localID: publisherID, publisherJID: account.jid)
        try realm.write {
            publisher.state = .trusted
            publisher.trustDate = Date(timeIntervalSince1970: 100)
            publisher.lastTrustSharingTimestamp = 123
        }

        for _ in 0..<2 {
            let share = try XCTUnwrap(publishOwnShare())
            let list = try XCTUnwrap(share.element(forName: "trust-list"))
            XCTAssertEqual(share.attributeStringValue(forName: "protocol"), "urn:xmpp:omemo:2")
            XCTAssertNil(share.attribute(forName: "usage"))
            XCTAssertEqual(list.attributeStringValue(forName: "timestamp"), "123")
            XCTAssertEqual(list.element(forName: "trust")?.attributeStringValue(forName: "timestamp"), "123")
        }
    }

    func testPublicationUsesActualTrustDateWhenNoSharedDecisionExists() throws {
        try useLocalPublisher(localID: publisherID, publisherJID: account.jid)
        try realm.write {
            publisher.state = .trusted
            publisher.trustDate = Date(timeIntervalSince1970: 100)
        }

        let share = try XCTUnwrap(publishOwnShare())

        XCTAssertEqual(share.element(forName: "trust-list")?.element(forName: "trust")?.attributeStringValue(forName: "timestamp"), "100")
    }

    func testPublicationCannotRoundAnExistingDecisionIntoANewerSecond() throws {
        try useLocalPublisher(localID: publisherID, publisherJID: account.jid)
        for savedTimestamp: Int64 in [100, 0] {
            try realm.write {
                publisher.state = .trusted
                publisher.lastTrustSharingTimestamp = savedTimestamp
                publisher.trustDate = Date(timeIntervalSince1970: 100.9)
            }

            let share = try XCTUnwrap(publishOwnShare())
            let list = try XCTUnwrap(share.element(forName: "trust-list"))

            XCTAssertEqual(list.attributeStringValue(forName: "timestamp"), "100")
            XCTAssertEqual(list.element(forName: "trust")?.attributeStringValue(forName: "timestamp"), "100")
        }
    }

    func testPublicationCannotInventDecisionTimeWhenNoDecisionClockExists() throws {
        try useLocalPublisher(localID: publisherID, publisherJID: account.jid)
        try realm.write { publisher.state = .trusted }

        XCTAssertNil(publishOwnShare())
    }

    func testOwnPublicationPropagatesExplicitNegativeDecisionsWithoutPublishingUnknownState() throws {
        try useLocalPublisher(localID: publisherID, publisherJID: account.jid)
        let negative = device(owner: account.jid, jid: account.jid, id: targetID)
        negative.fingerprint = target.fingerprint
        negative.lastTrustSharingTimestamp = 123
        let unknown = device(owner: account.jid, jid: account.jid, id: 43)
        unknown.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: CryptoKit.Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        unknown.state = .unknown
        unknown.lastTrustSharingTimestamp = 999
        try realm.write {
            publisher.state = .trusted
            publisher.lastTrustSharingTimestamp = 100
            realm.add(negative)
            realm.add(unknown)
        }

        for state in [SignalDeviceStorageItem.TrustState.distrusted, .revoked] {
            try realm.write { negative.state = state }

            let share = try XCTUnwrap(publishOwnShare())
            let list = try XCTUnwrap(share.element(forName: "trust-list"))
            let decisions = list.elements(forName: "distrust")
            XCTAssertEqual(decisions.count, 1, "Explicit own-device revocation must reach siblings")
            XCTAssertEqual(decisions.first?.attributeStringValue(forName: "timestamp"), "123")
            XCTAssertEqual(decisions.first?.stringValue,
                           Data("\(targetID)::\(negative.fingerprint.replacingOccurrences(of: " ", with: "").lowercased())".utf8).base64EncodedString())
            XCTAssertEqual(list.attributeStringValue(forName: "timestamp"), "123", "Unknown or ambiguous state cannot author a new decision")
            XCTAssertEqual(list.elements(forName: "trust").count, 1)
            XCTAssertEqual(list.children?.compactMap { $0 as? DDXMLElement }.count, 2)
            let canonical = try XCTUnwrap(TrustSharingSignature.canonicalString(for: [list]))
            let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(share.element(forName: "signature")?.stringValue)))
            XCTAssertTrue(Omemo2IdentityRepresentation.verify(signature,
                data: TrustSharingSignature.hashCanonicalString(canonical), storedIdentity: identity.publicKey.rawRepresentation))
        }
    }

    func testOwnPublicationOmitsMalformedOrUnboundSavedTrustWithoutMigratingRows() throws {
        try useLocalPublisher(localID: publisherID, publisherJID: account.jid)
        try realm.write { publisher.state = .trusted; publisher.lastTrustSharingTimestamp = 100 }
        let malformed = device(owner: account.jid, jid: account.jid, id: 6032)
        malformed.state = .trusted
        malformed.lastTrustSharingTimestamp = 123
        let unbound = device(owner: account.jid, jid: account.jid, id: 6033)
        unbound.state = .trusted
        unbound.fingerprint = target.fingerprint
        unbound.lastTrustSharingTimestamp = 124
        let invalidSID = device(owner: account.jid, jid: account.jid, id: 0)
        invalidSID.state = .trusted
        invalidSID.fingerprint = target.fingerprint
        invalidSID.lastTrustSharingTimestamp = 125
        let malformedNegative = device(owner: account.jid, jid: account.jid, id: 6035)
        malformedNegative.state = .distrusted
        malformedNegative.lastTrustSharingTimestamp = 126
        let oversizedNegative = device(owner: account.jid, jid: account.jid, id: Int(Int32.max) + 1)
        oversizedNegative.state = .distrusted
        oversizedNegative.fingerprint = target.fingerprint
        oversizedNegative.lastTrustSharingTimestamp = 127
        try realm.write { realm.add([malformed, unbound, invalidSID, malformedNegative, oversizedNegative]) }

        let share = try XCTUnwrap(publishOwnShare())
        let list = try XCTUnwrap(share.element(forName: "trust-list"))

        XCTAssertEqual(list.elements(forName: "trust").count, 1)
        XCTAssertEqual(list.elements(forName: "distrust").count, 0)
        XCTAssertEqual(list.attributeStringValue(forName: "timestamp"), "100")
        XCTAssertEqual(malformed.state, .trusted)
        XCTAssertEqual(malformed.fingerprint, "")
        XCTAssertEqual(malformed.lastTrustSharingTimestamp, 123)
        XCTAssertEqual(unbound.state, .trusted)
        XCTAssertEqual(invalidSID.deviceId, 0)
        XCTAssertEqual(malformedNegative.state, .distrusted)
        XCTAssertEqual(malformedNegative.lastTrustSharingTimestamp, 126)
        XCTAssertEqual(oversizedNegative.deviceId, Int(Int32.max) + 1)
        XCTAssertNotNil(realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: malformed.primary))
    }

    func testEncryptedContactPublicationOmitsHistoricalEmptyFingerprintsAndRetainsValidDecisions() throws {
        try useLocalPublisher(localID: publisherID, publisherJID: account.jid)
        let historical = device(owner: account.jid, jid: target.jid, id: 6032)
        historical.state = .trusted
        historical.lastTrustSharingTimestamp = 123
        let negative = device(owner: account.jid, jid: target.jid, id: 6034)
        negative.state = .distrusted
        negative.fingerprint = target.fingerprint
        negative.lastTrustSharingTimestamp = 124
        try realm.write {
            publisher.state = .trusted
            publisher.lastTrustSharingTimestamp = 100
            target.state = .trusted
            target.lastTrustSharingTimestamp = 101
            realm.add([historical, negative])
        }

        let share = try publishContactShare()
        let list = try XCTUnwrap(share.element(forName: "trust-list"))

        XCTAssertEqual(list.attributeStringValue(forName: "owner"), target.jid)
        XCTAssertEqual(list.elements(forName: "trust").count, 1, "A historical empty fingerprint cannot poison the signed atomic list")
        XCTAssertEqual(list.elements(forName: "distrust").count, 1, "A valid explicit negative does not need a currently discovered identity")
        XCTAssertEqual(list.element(forName: "trust")?.stringValue,
                       Data("\(targetID)::\(target.fingerprint.replacingOccurrences(of: " ", with: "").lowercased())".utf8).base64EncodedString())
        XCTAssertEqual(historical.fingerprint, "")
        XCTAssertEqual(historical.state, .trusted)
        XCTAssertEqual(historical.lastTrustSharingTimestamp, 123)
        XCTAssertFalse(historical.isInDeviceList)
    }

    func testEmptySignedListAdvancesPublisherCursorWithoutChangingDecisions() throws {
        let packet = try share(timestamp: 100, entryTimestamp: 90)
        packet.element(forName: "trust-list")?.element(forName: "trust")?.detach()
        try sign(packet)

        try receive(packet)

        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "100")
        XCTAssertEqual(publisher.lastTrustSharingTimestamp, 0)
        XCTAssertEqual(target.state, .unknown)
    }

    func testRetiredUsageAttributeCannotAuthorizeAModernSignedList() throws {
        let packet = try share(timestamp: 100, entryTimestamp: 90)
        packet.removeAttribute(forName: "protocol")
        packet.addAttribute(withName: "usage", stringValue: "urn:xmpp:omemo:2")

        try receive(packet)

        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "")
    }

    func testUnauthenticatedShareTimestampCannotSuppressLaterSignedList() throws {
        let packet = try share(timestamp: 100, entryTimestamp: 90)
        packet.addAttribute(withName: "timestamp", stringValue: "9999999999")
        try receive(packet)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "100")

        try receive(share(timestamp: 200, entryTimestamp: 150, state: "distrust"))

        XCTAssertEqual(target.state, .distrusted)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "200")
    }

    func testPubSubItemIDCannotFallBackToAnotherSigningDevice() throws {
        for itemID in ["99", "not-a-number", ""] {
            try receive(share(timestamp: 100, entryTimestamp: 90), itemID: itemID)
            XCTAssertEqual(target.state, .unknown)
            XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "")
        }
    }

    func testOppositeEqualTimeDecisionQuarantinesExistingTrust() throws {
        try realm.write {
            target.state = .trusted
            target.trustDate = Date(timeIntervalSince1970: 100)
            target.lastTrustSharingTimestamp = 100
            target.trustedByDeviceId = "another-trusted-publisher"
        }

        try receive(share(timestamp: 200, entryTimestamp: 100, state: "distrust"))

        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(target.lastTrustSharingTimestamp, 100)
        XCTAssertEqual(target.trustDate.timeIntervalSince1970, -1)
        XCTAssertNil(target.trustedByDeviceId)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "200")
    }

    func testSamePublisherEqualTimeConflictCannotLeaveOrRestoreTrust() throws {
        try receive(share(timestamp: 100, entryTimestamp: 100))
        XCTAssertEqual(target.state, .trusted)

        try receive(share(timestamp: 100, entryTimestamp: 100, state: "distrust"))
        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "100")
        try receive(share(timestamp: 200, entryTimestamp: 100))
        XCTAssertEqual(target.state, .unknown)

        try receive(share(timestamp: 300, entryTimestamp: 101))
        XCTAssertEqual(target.state, .trusted)
        XCTAssertEqual(target.lastTrustSharingTimestamp, 101)
    }

    func testIndependentDecisionsInTheSameSecondCanShareAPublisherCursor() throws {
        try receive(share(timestamp: 100, entryTimestamp: 100))
        let key = CryptoKit.Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let next = device(owner: account.jid, jid: peer, id: 43)
        next.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: key)
        let identity = SignalIdentityStorageItem()
        identity.owner = account.jid
        identity.jid = peer
        identity.deviceId = 43
        identity.primary = next.primary
        identity.identityKey = key.base64EncodedString()
        try realm.write { realm.add(next); realm.add(identity) }
        let trustedKey = "43::\(next.fingerprint.replacingOccurrences(of: " ", with: ""))"

        try receive(share(timestamp: 100, entryTimestamp: 100, id: 43, value: Data(trustedKey.utf8).base64EncodedString()))

        XCTAssertEqual(target.state, .trusted)
        XCTAssertEqual(next.state, .trusted)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "100")
    }

    func testUnseenContactOwnerIsNotSuppressedByNewerOwnOwnerList() throws {
        try receive(share(timestamp: 500, entryTimestamp: 100))
        let contact = try addTarget(jid: "other-contact@example.test", id: 43)
        let packet = try share(timestamp: 200, entryTimestamp: 150, id: 43,
            value: Data("43::\(canonicalFingerprint(contact.fingerprint))".utf8).base64EncodedString())
        packet.element(forName: "trust-list")?.addAttribute(withName: "owner", stringValue: contact.jid)
        try sign(packet)

        try receive(packet)

        XCTAssertEqual(contact.state, .trusted)
        XCTAssertEqual(contact.lastTrustSharingTimestamp, 150)
        XCTAssertEqual(target.state, .trusted)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "500", "Independent owner admission must not regress diagnostic max")
    }

    func testLegacyPublisherScalarDoesNotBecomeAnOwnerWatermark() throws {
        try realm.write { publisher.lastTrustedItemsUpdateTimestamp = "900" }

        try receive(share(timestamp: 200, entryTimestamp: 100))

        XCTAssertEqual(target.state, .trusted)
        XCTAssertEqual(target.lastTrustSharingTimestamp, 100)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "900")
    }

    func testPerOwnerEmptyWatermarkPersistsAcrossManagerAndRealmRecreation() throws {
        let empty = try share(timestamp: 500, entryTimestamp: 100)
        for child in empty.element(forName: "trust-list")?.children ?? [] { child.detach() }
        try sign(empty)
        try receive(empty)
        let contact = try addTarget(jid: "persisted-contact@example.test", id: 43)
        let current = try share(timestamp: 200, entryTimestamp: 100, id: 43,
            value: Data("43::\(canonicalFingerprint(contact.fingerprint))".utf8).base64EncodedString())
        current.element(forName: "trust-list")?.addAttribute(withName: "owner", stringValue: contact.jid)
        try sign(current)
        try receive(current)
        XCTAssertEqual(contact.state, .trusted)
        let configuration = Realm.Configuration.defaultConfiguration
        let primary = contact.primary
        let reread = try DispatchQueue(label: "TrustSharingAdmission-independent-read").sync { () throws -> String? in
            let independent = try Realm(configuration: configuration)
            independent.refresh()
            return independent.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary)?.state_
        }
        XCTAssertEqual(reread, SignalDeviceStorageItem.TrustState.trusted.rawValue)
        manager = TrustSharingManager(withOwner: account.jid)
        let stale = try share(timestamp: 150, entryTimestamp: 150, id: 43, state: "distrust",
            value: Data("43::\(canonicalFingerprint(contact.fingerprint))".utf8).base64EncodedString())
        stale.element(forName: "trust-list")?.addAttribute(withName: "owner", stringValue: contact.jid)
        try sign(stale)

        try receive(stale)

        XCTAssertEqual(contact.state, .trusted, "An older owner list cannot use a newer-looking record to replace accepted owner state")
        XCTAssertEqual(contact.lastTrustSharingTimestamp, 100)
    }

    func testDistinctHistoricalAndCurrentFingerprintsUnderOneSIDAreAccepted() throws {
        try useLocalPublisher(localID: publisherID, publisherJID: account.jid)
        let oldFingerprint = canonicalFingerprint(try Omemo2IdentityRepresentation.fingerprint(for: CryptoKit.Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        let packet = try share(timestamp: 300, entryTimestamp: 200)
        let historical = DDXMLElement(name: "distrust", xmlns: TrustSharingSignature.xmlns)
        historical.addAttribute(withName: "timestamp", integerValue: 300)
        historical.stringValue = Data("\(targetID)::\(oldFingerprint)".utf8).base64EncodedString()
        packet.element(forName: "trust-list")?.addChild(historical)
        try sign(packet)

        try receive(packet)

        XCTAssertEqual(target.state, .trusted)
        XCTAssertEqual(target.lastTrustSharingTimestamp, 200, "An old identity's negative clock belongs to that distinct TrustedKey")
        let published = try publishContactShare()
        let list = try XCTUnwrap(published.elements(forName: "trust-list").first { $0.attributeStringValue(forName: "owner") == target.jid })
        XCTAssertEqual(list.elements(forName: "trust").map { $0.stringValue ?? "" }, [Data("\(targetID)::\(canonicalFingerprint(target.fingerprint))".utf8).base64EncodedString()])
        XCTAssertEqual(list.elements(forName: "distrust").map { $0.stringValue ?? "" }, [Data("\(targetID)::\(oldFingerprint)".utf8).base64EncodedString()])
        XCTAssertEqual(list.elements(forName: "distrust").first?.attributeStringValue(forName: "timestamp"), "300")
    }

    func testHistoricalNegativeSurvivesSignerDeletionWithoutChangingCurrentIdentity() throws {
        let oldFingerprint = canonicalFingerprint(try Omemo2IdentityRepresentation.fingerprint(for: CryptoKit.Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        let currentFingerprint = target.fingerprint
        try receive(share(timestamp: 300, entryTimestamp: 300, state: "distrust",
            value: Data("\(targetID)::\(oldFingerprint)".utf8).base64EncodedString()))
        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(target.fingerprint, currentFingerprint)
        XCTAssertEqual(target.lastTrustSharingTimestamp, 0)
        let signingPrimary = publisher.primary
        try realm.write {
            realm.delete(publisher)
            realm.delete(try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: signingPrimary)))
        }
        manager = TrustSharingManager(withOwner: account.jid)

        let published = try publishContactShare()

        let list = try XCTUnwrap(published.elements(forName: "trust-list").first { $0.attributeStringValue(forName: "owner") == target.jid })
        XCTAssertEqual(list.elements(forName: "distrust").first?.stringValue,
            Data("\(targetID)::\(oldFingerprint)".utf8).base64EncodedString())
        XCTAssertEqual(list.elements(forName: "distrust").first?.attributeStringValue(forName: "timestamp"), "300")
    }

    func testNewSignerIdentityDoesNotInheritOldSignerOwnerWatermarkOrAuthority() throws {
        try receive(share(timestamp: 500, entryTimestamp: 100))
        let replacement = CryptoKit.Curve25519.Signing.PrivateKey()
        try realm.write {
            publisher.state = .unknown
            publisher.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: replacement.publicKey.rawRepresentation)
            realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: publisher.primary)?.identityKey = replacement.publicKey.rawRepresentation.base64EncodedString()
        }
        identity = replacement
        try receive(share(timestamp: 200, entryTimestamp: 150, state: "distrust"))
        XCTAssertEqual(target.state, .trusted, "A new unknown signer must not inherit authority from its previous SID occupant")
        try realm.write { publisher.state = .trusted }

        try receive(share(timestamp: 200, entryTimestamp: 150, state: "distrust"))

        XCTAssertEqual(target.state, .distrusted, "The explicitly trusted replacement is a distinct signing source with independent owner clocks")
        XCTAssertEqual(target.lastTrustSharingTimestamp, 150)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "500")
    }

    func testMissingLocalIdentityAnchorCannotApplyASignedShare() throws {
        let localID = try XCTUnwrap(account.omemo.omemo2Storage).localBundle().deviceID
        let localPrimary = SignalDeviceStorageItem.genPrimary(owner: account.jid, jid: account.jid, deviceId: localID)
        try realm.write { realm.delete(try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: localPrimary))) }

        try receive(share(timestamp: 100, entryTimestamp: 100))

        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "")
    }

    func testUnboundLocalEdIdentityCannotConsumeASignedShare() throws {
        let localID = try XCTUnwrap(account.omemo.omemo2Storage).localBundle().deviceID
        let localPrimary = SignalDeviceStorageItem.genPrimary(owner: account.jid, jid: account.jid, deviceId: localID)
        try realm.write {
            realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: localPrimary)?.identityKey = CryptoKit.Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        }

        try receive(share(timestamp: 100, entryTimestamp: 100))

        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "")
    }

    func testNewlyAcceptedPEPTrustContinuesTheTrustChainWithoutReplayLoop() throws {
        let stream = Stream()
        account.xmppStream = stream

        try receive(share(timestamp: 100, entryTimestamp: 100))
        account.queue.sync { }

        let requests = stream.elements.filter { element in
            element.attributeStringValue(forName: "type") == "get"
                && element.attributeStringValue(forName: "to") == self.target.jid
                && element.element(forName: "pubsub")?.element(forName: "items")?.attributeStringValue(forName: "node") == TrustSharingSignature.node
        }
        XCTAssertEqual(requests.count, 1)
        try receive(share(timestamp: 100, entryTimestamp: 100))
        account.queue.sync { }
        XCTAssertEqual(stream.elements.count, requests.count, "Stable accepted trust must not recursively refetch on identical replay")
    }

    func testMissingTargetBundleIsFetchedAndSignedShareRetriesAfterNormalBundleCommit() throws {
        let receiver = try XabberOMEMO2Storage(owner: peer, persistence: Memory())
        let bundle = try receiver.prepare(deviceID: targetID, preKeyCount: 2)
        try realm.write {
            target.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey)
            realm.delete(try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: target.primary)))
        }
        let stream = Stream(); account.xmppStream = stream
        let packet = try share(timestamp: 100, entryTimestamp: 100)
        try receive(packet)
        account.queue.sync { }
        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "", "Pending valid input cannot consume its owner watermark")
        let request = try XCTUnwrap(stream.elements.first { $0.element(forName: "pubsub")?.element(forName: "items")?.attributeStringValue(forName: "node") == OmemoManager.xmlns + ":bundles" })
        let items = DDXMLElement(name: "items")
        items.addAttribute(withName: "node", stringValue: OmemoManager.xmlns + ":bundles")
        items.addChild(try OMEMO2BundleCodec.encode(OMEMO2PublishedBundle(bundle)))
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        pubsub.addChild(items)
        let response = XMPPIQ(iqType: .result, elementID: request.attributeStringValue(forName: "id"), child: pubsub)
        response.addAttribute(withName: "from", stringValue: peer)

        XCTAssertTrue(account.omemo.onContactBundleReceive(response))
        let accepted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.target.state == .trusted }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [accepted], timeout: 3), .completed)

        XCTAssertEqual(target.lastTrustSharingTimestamp, 100)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "100")
    }

    func testRejectedSignerCannotAmplifyBundleFetchForUnresolvedTargets() throws {
        try realm.write { realm.delete(try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: target.primary))) }
        let stream = Stream(); account.xmppStream = stream
        let invalid = try share(timestamp: 100, entryTimestamp: 100)
        invalid.element(forName: "signature")?.stringValue = Data(repeating: 0, count: 64).base64EncodedString()
        try receive(invalid)
        try realm.write { publisher.state = .distrusted }
        try receive(share(timestamp: 100, entryTimestamp: 100))
        account.queue.sync { }
        XCTAssertTrue(stream.elements.isEmpty)
        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "")
    }

    func testHistoricalFullKeyFloorSurvivesNewSignerAndCurrentIdentityRotation() throws {
        let oldKey = CryptoKit.Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let oldFingerprint = canonicalFingerprint(try Omemo2IdentityRepresentation.fingerprint(for: oldKey))
        try receive(share(timestamp: 300, entryTimestamp: 300, state: "distrust",
            value: Data("\(targetID)::\(oldFingerprint)".utf8).base64EncodedString()))
        let newSigner = CryptoKit.Curve25519.Signing.PrivateKey()
        try realm.write {
            publisher.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: newSigner.publicKey.rawRepresentation)
            realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: publisher.primary)?.identityKey = newSigner.publicKey.rawRepresentation.base64EncodedString()
            target.fingerprint = oldFingerprint
            target.state = .fingerprintChanged
            target.lastTrustSharingTimestamp = 9999 // Clock of the previous, different fingerprint.
            realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: target.primary)?.identityKey = oldKey.base64EncodedString()
        }
        identity = newSigner
        manager = TrustSharingManager(withOwner: account.jid)
        try receive(share(timestamp: 400, entryTimestamp: 200))
        XCTAssertEqual(target.state, .distrusted)
        XCTAssertEqual(target.lastTrustSharingTimestamp, 300, "The retained full-key floor, not the previous SID occupant's clock, applies")
        try receive(share(timestamp: 401, entryTimestamp: 300))
        XCTAssertEqual(target.state, .unknown, "Opposite equal-time accepted decisions are ambiguous")
        manager = TrustSharingManager(withOwner: account.jid)
        try receive(share(timestamp: 402, entryTimestamp: 300))
        XCTAssertEqual(target.state, .unknown, "A repeated positive cannot restore an ambiguous full-key decision")
        try receive(share(timestamp: 403, entryTimestamp: 301))
        XCTAssertEqual(target.state, .trusted)
        XCTAssertEqual(target.lastTrustSharingTimestamp, 301)
    }

    func testNestedSignaturePayloadCannotApplyOtherwiseValidSignedShare() throws {
        let packet = try share(timestamp: 100, entryTimestamp: 100)
        let signature = try XCTUnwrap(packet.element(forName: "signature"))
        let bytes = try XCTUnwrap(signature.stringValue)
        signature.stringValue = nil
        let nested = DDXMLElement(name: "unexpected", xmlns: TrustSharingSignature.xmlns)
        nested.stringValue = bytes
        signature.addChild(nested)
        try receive(packet)
        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "")
    }

    func testUppercaseTrustedKeyCannotApplySignatureOverNoncanonicalBytes() throws {
        let key = "\(targetID)::\(canonicalFingerprint(target.fingerprint).uppercased())"
        try receive(share(timestamp: 100, entryTimestamp: 100, value: Data(key.utf8).base64EncodedString()))
        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "")
    }

    func testUnknownTargetNegativeProjectsAfterNormalBundleCommit() throws {
        let item = try acceptedFutureNegativeAndNormalBundle()
        XCTAssertEqual(item.state, .distrusted)
        XCTAssertEqual(item.lastTrustSharingTimestamp, 5_000_000_000)
        let floor = try manager.acceptedDecisionTimestamp(in: realm, jid: item.jid, deviceID: item.deviceId,
            fingerprint: canonicalFingerprint(item.fingerprint))
        XCTAssertEqual(floor, 5_000_000_000)
    }

    func testAKEActionOutranksRetainedExactTargetLedgerFloorAfterProjectionClockLoss() throws {
        let item = try acceptedFutureNegativeAndNormalBundle()
        try realm.write { item.state = .unknown; item.lastTrustSharingTimestamp = 0 }
        XCTAssertTrue(account.akeManager.writeTrustedDevice(jid: item.jid, deviceId: item.deviceId))
        XCTAssertEqual(item.state, .trusted)
        XCTAssertGreaterThan(item.lastTrustSharingTimestamp, 5_000_000_000)
    }

    func testManualLocalActionOutranksRetainedExactTargetLedgerFloorAfterProjectionClockLoss() throws {
        let item = try acceptedFutureNegativeAndNormalBundle()
        for state in [SignalDeviceStorageItem.TrustState.distrusted, .unknown] {
            try realm.write {
                item.state = .unknown; item.lastTrustSharingTimestamp = 0
                XCTAssertTrue(DeviceDetailLocalTrustDecision.apply(to: item, state: state,
                    at: Date(timeIntervalSince1970: 100)))
            }
            XCTAssertEqual(item.state, state)
            XCTAssertGreaterThan(item.lastTrustSharingTimestamp, 5_000_000_000)
        }
    }

    func testCanonicalOwnerResolvesExistingALabelStorageWithoutRenamingRows() throws {
        let rawJID = "juliet@xn--bcher-kva.example"
        let item = try addTarget(jid: rawJID, id: 43)
        let primary = item.primary
        let packet = try share(timestamp: 200, entryTimestamp: 100, id: 43,
            value: Data("43::\(canonicalFingerprint(item.fingerprint))".utf8).base64EncodedString())
        packet.element(forName: "trust-list")?.addAttribute(withName: "owner", stringValue: "juliet@bücher.example")
        try sign(packet)
        try receive(packet)
        XCTAssertEqual(item.state, .trusted)
        XCTAssertEqual(item.jid, rawJID)
        XCTAssertEqual(item.primary, primary)
    }

    func testLifecycleClearCancelsValidatedQueuedBundleFetch() throws {
        try realm.write { realm.delete(try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: target.primary))) }
        let stream = Stream(); account.xmppStream = stream
        account.queue.suspend()
        do {
            try receive(share(timestamp: 100, entryTimestamp: 100))
            manager.clearSession()
        } catch {
            account.queue.resume(); throw error
        }
        account.queue.resume()
        account.queue.sync { }
        XCTAssertTrue(stream.elements.isEmpty)
        XCTAssertEqual(target.state, .unknown)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "")
    }

    func testNormalBundleMismatchCannotCreateUnboundedPendingFetchLoop() throws {
        let receiver = try XabberOMEMO2Storage(owner: peer, persistence: Memory())
        let replacement = try receiver.prepare(deviceID: targetID, preKeyCount: 2)
        try realm.write { realm.delete(try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: target.primary))) }
        let stream = Stream(); account.xmppStream = stream
        try receive(share(timestamp: 100, entryTimestamp: 100))
        account.queue.sync { }
        let before = stream.elements.filter { $0.element(forName: "pubsub")?.element(forName: "items")?.attributeStringValue(forName: "node") == OmemoManager.xmlns + ":bundles" }.count
        XCTAssertEqual(before, 1)
        let items = DDXMLElement(name: "items")
        items.addAttribute(withName: "node", stringValue: OmemoManager.xmlns + ":bundles")
        items.addChild(try OMEMO2BundleCodec.encode(OMEMO2PublishedBundle(replacement)))
        XCTAssertTrue(try account.omemo.onContactBundleReceive(items: items, jid: peer))
        account.queue.sync { }
        let after = stream.elements.filter { $0.element(forName: "pubsub")?.element(forName: "items")?.attributeStringValue(forName: "node") == OmemoManager.xmlns + ":bundles" }.count
        XCTAssertEqual(after, 1, "A normal bundle that cannot resolve an old signed positive must not create a fetch/response loop")
        XCTAssertNotEqual(target.state, .trusted)
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "")
    }

    private func acceptedFutureNegativeAndNormalBundle() throws -> SignalDeviceStorageItem {
        let receiver = try XabberOMEMO2Storage(owner: peer, persistence: Memory())
        let bundle = try receiver.prepare(deviceID: 60, preKeyCount: 2)
        let fingerprint = canonicalFingerprint(try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey))
        try receive(share(timestamp: 5_000_000_100, entryTimestamp: 5_000_000_000, id: 60, state: "distrust",
            value: Data("60::\(fingerprint)".utf8).base64EncodedString()))
        let primary = SignalDeviceStorageItem.genPrimary(owner: account.jid, jid: peer, deviceId: 60)
        XCTAssertNil(realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary), "Historical full keys do not manufacture current-device rows")
        let items = DDXMLElement(name: "items")
        items.addAttribute(withName: "node", stringValue: OmemoManager.xmlns + ":bundles")
        items.addChild(try OMEMO2BundleCodec.encode(OMEMO2PublishedBundle(bundle)))
        XCTAssertTrue(try account.omemo.onContactBundleReceive(items: items, jid: peer))
        return try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary))
    }

    private func canonicalFingerprint(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "").lowercased()
    }

    private func addTarget(jid: String, id: Int) throws -> SignalDeviceStorageItem {
        let key = CryptoKit.Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let result = device(owner: account.jid, jid: jid, id: id)
        result.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: key)
        let stored = SignalIdentityStorageItem()
        stored.owner = account.jid; stored.jid = jid; stored.deviceId = id
        stored.primary = result.primary; stored.identityKey = key.base64EncodedString()
        try realm.write { realm.add(result); realm.add(stored) }
        return result
    }

    private func publishOwnShare() -> DDXMLElement? {
        let stream = Stream()
        account.xmppStream = stream
        manager.publishOwnTrustedDevices(publisherDeviceId: String(publisherID))
        account.queue.sync { }
        return stream.elements.first?.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?
            .element(forName: "publish")?.element(forName: "item")?.element(forName: "share", xmlns: TrustSharingSignature.xmlns)
    }

    private func publishContactShare() throws -> DDXMLElement {
        let sendingDeviceID = try XCTUnwrap(account.omemo.omemo2Storage).localBundle().deviceID
        let receiver = try XabberOMEMO2Storage(owner: account.jid, persistence: Memory())
        let bundle = try receiver.prepare(deviceID: 43, preKeyCount: 2)
        _ = try account.omemo.ensureOMEMO2Prepared(attemptPublication: false)
        let items = DDXMLElement(name: "items", xmlns: "http://jabber.org/protocol/pubsub")
        items.addAttribute(withName: "node", stringValue: OmemoManager.xmlns + ":bundles")
        items.addChild(try OMEMO2BundleCodec.encode(OMEMO2PublishedBundle(bundle)))
        XCTAssertTrue(try account.omemo.onContactBundleReceive(items: items, jid: account.jid))
        let sibling = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self,
            forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: account.jid, jid: account.jid, deviceId: 43)))
        try realm.write { sibling.state = .trusted }
        let advertised = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(account.jid)'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:devices'><item id='current'><devices xmlns='urn:xmpp:omemo:2'><device id='\(sendingDeviceID)'/><device id='43'/></devices></item></items></event></message>")
        XCTAssertTrue(account.omemo.onContactDeviceListReceiveHeadline(advertised))
        let stream = Stream()
        account.xmppStream = stream

        manager.sendListOfContactsDevices()
        account.queue.sync { }

        func encryptedDescendant(_ element: DDXMLElement) -> DDXMLElement? {
            if SCEReceivePolicy.matches(element, name: "encrypted", namespace: OmemoManager.xmlns) { return element }
            for child in element.children?.compactMap({ $0 as? DDXMLElement }) ?? [] {
                if let encrypted = encryptedDescendant(child) { return encrypted }
            }
            return nil
        }
        let encrypted = try XCTUnwrap(stream.elements.compactMap(encryptedDescendant).first)
        let payload = try Omemo2PayloadCodec.decodeBase64(XCTUnwrap(encrypted.element(forName: "payload")?.stringValue))
        let key = try XCTUnwrap(encrypted.element(forName: "header")?.elements(forName: "keys")
            .first { $0.attributeStringValue(forName: "jid") == account.jid }?.elements(forName: "key")
            .first { $0.attributeStringValue(forName: "rid") == "43" })
        let cipher = try OMEMO2Ciphertext(data: Omemo2PayloadCodec.decodeBase64(XCTUnwrap(key.stringValue)),
            keyExchange: key.attributeBoolValue(forName: "kex"))
        let material = try receiver.decrypt(cipher, jid: account.jid, deviceID: sendingDeviceID) {
            _ = try Omemo2PayloadCodec.openVerified(payload, keyAndMAC: $0, expectedFrom: account.jid, expectedTo: account.jid)
        }
        let opened = try XCTUnwrap(Omemo2PayloadCodec.openVerified(payload, keyAndMAC: material,
            expectedFrom: account.jid, expectedTo: account.jid))
        return try XCTUnwrap(opened.content.element(forName: "share", xmlns: TrustSharingSignature.xmlns))
    }

    private func receive(_ share: DDXMLElement, itemID: String? = nil) throws {
        let items = DDXMLElement(name: "items")
        items.addAttribute(withName: "node", stringValue: TrustSharingSignature.node)
        let item = DDXMLElement(name: "item")
        item.addAttribute(withName: "id", stringValue: itemID ?? String(publisherID))
        item.addChild(share)
        items.addChild(item)
        let pubsub = DDXMLElement(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")
        pubsub.addChild(items)
        let iq = XMPPIQ(iqType: .result, child: pubsub)
        iq.addAttribute(withName: "from", stringValue: peer)
        XCTAssertTrue(manager.read(withIQ: iq))
    }

    private func share(timestamp: Int, entryTimestamp: Int, id: Int? = nil,
                       state: String = "trust", value: String? = nil) throws -> DDXMLElement {
        let container = DDXMLElement(name: "trust-list", xmlns: TrustSharingSignature.xmlns)
        container.addAttribute(withName: "timestamp", integerValue: timestamp)
        container.addAttribute(withName: "owner", stringValue: target.jid)
        let entry = DDXMLElement(name: state, xmlns: TrustSharingSignature.xmlns)
        entry.addAttribute(withName: "timestamp", integerValue: entryTimestamp)
        let fingerprint = (id == publisherID ? publisher.fingerprint : target.fingerprint).replacingOccurrences(of: " ", with: "").lowercased()
        entry.stringValue = value ?? Data("\(id ?? targetID)::\(fingerprint)".utf8).base64EncodedString()
        container.addChild(entry)
        let share = DDXMLElement(name: "share", xmlns: TrustSharingSignature.xmlns)
        share.addAttribute(withName: "protocol", stringValue: "urn:xmpp:omemo:2")
        share.addAttribute(withName: "timestamp", integerValue: timestamp)
        let identityElement = DDXMLElement(name: "identity", xmlns: TrustSharingSignature.xmlns)
        identityElement.addAttribute(withName: "id", integerValue: publisherID)
        identityElement.stringValue = publisher.fingerprint
        share.addChild(identityElement)
        share.addChild(container)
        let signature = DDXMLElement(name: "signature", xmlns: TrustSharingSignature.xmlns)
        share.addChild(signature)
        try sign(share)
        return share
    }

    private func sign(_ share: DDXMLElement) throws {
        let canonical = try XCTUnwrap(TrustSharingSignature.canonicalString(for: TrustSharingSignature.trustedItems(from: share)))
        share.element(forName: "signature")?.stringValue = try identity.signature(for: TrustSharingSignature.hashCanonicalString(canonical)).base64EncodedString()
    }

    private func useLocalPublisher(localID: Int, publisherJID: String, useLocalKey: Bool = true) throws {
        let storage = try XabberOMEMO2Storage(owner: account.jid, persistence: Memory())
        _ = try storage.prepare(deviceID: localID, preKeyCount: 2)
        account.omemo.omemo2Storage = storage
        if useLocalKey {
            identity = try CryptoKit.Curve25519.Signing.PrivateKey(rawRepresentation: storage.identity().privateKey)
        }
        let next = device(owner: account.jid, jid: publisherJID, id: publisherID)
        next.fingerprint = try Omemo2IdentityRepresentation.fingerprint(for: identity.publicKey.rawRepresentation)
        let stored = SignalIdentityStorageItem()
        stored.owner = account.jid
        stored.jid = publisherJID
        stored.deviceId = publisherID
        stored.primary = next.primary
        stored.identityKey = identity.publicKey.rawRepresentation.base64EncodedString()
        let previousPrimary = publisher.primary
        try realm.write {
            realm.delete(publisher)
            realm.delete(try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: previousPrimary)))
            realm.add(next)
            realm.add(stored)
        }
        publisher = next
        peer = publisherJID
    }

    private func device(owner: String, jid: String, id: Int) -> SignalDeviceStorageItem {
        let device = SignalDeviceStorageItem()
        device.owner = owner
        device.jid = jid
        device.deviceId = id
        device.primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: jid, deviceId: id)
        return device
    }
}
