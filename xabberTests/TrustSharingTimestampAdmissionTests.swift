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
        XCTAssertEqual(publisher.lastTrustedItemsUpdateTimestamp, "100")
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

    private func publishOwnShare() -> DDXMLElement? {
        let stream = Stream()
        account.xmppStream = stream
        manager.publishOwnTrustedDevices(publisherDeviceId: String(publisherID))
        account.queue.sync { }
        return stream.elements.first?.element(forName: "pubsub", xmlns: "http://jabber.org/protocol/pubsub")?
            .element(forName: "publish")?.element(forName: "item")?.element(forName: "share", xmlns: TrustSharingSignature.xmlns)
    }

    private func publishContactShare() throws -> DDXMLElement {
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
        let advertised = try XMPPMessage(xmlString: "<message xmlns='jabber:client' from='\(account.jid)'><event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:omemo:2:devices'><item id='current'><devices xmlns='urn:xmpp:omemo:2'><device id='41'/><device id='43'/></devices></item></items></event></message>")
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
        let material = try receiver.decrypt(cipher, jid: account.jid, deviceID: publisherID) {
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
