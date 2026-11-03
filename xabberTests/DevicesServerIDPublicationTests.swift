import Foundation
import RealmSwift
import XMPPFramework
import XCTest
@testable import xabber

/// Real native OMEMO storage and serialization; only network I/O is captured.
final class DevicesServerIDPublicationTests: XCTestCase {
    private final class Memory: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var onLoad: (() -> Void)?
        func load(owner: String) throws -> Data? { onLoad?(); return records[owner] }
        func save(_ data: Data, owner: String) throws { records[owner] = data }
        func remove(owner: String) throws { records.removeValue(forKey: owner) }
    }
    private final class Stream: XMPPStream {
        var authenticated = true
        override var isAuthenticated: Bool { authenticated }
        override var isDisconnected: Bool { false }
        var packets: [DDXMLElement] = []
        override func send(_ element: DDXMLElement) { packets.append(element.copy() as! DDXMLElement) }
    }
    private struct Fixture {
        let account: Account
        let stream: Stream
        let storage: XabberOMEMO2Storage
        let persistence: Memory
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
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "server-id-publication-\(UUID())")
        keeper = try WRealm.safe(); originalUsers = AccountManager.shared.users
    }
    override func tearDownWithError() throws {
        guard originalRealm != nil else { return }
        for f in fixtures {
            f.account.queue.sync {}; f.manager.omemo2MaintenanceWorkItem?.cancel(); f.manager.clearSession()
            f.account.messages.updateSendingMessagesTimer?.invalidate(); f.account.xmppTaskScheduler.reset()
            CredentialsManager.shared.removeDeviceId(for: f.owner)
        }
        AccountManager.shared.users = originalUsers; keeper = nil
        Realm.Configuration.defaultConfiguration = originalRealm
        try super.tearDownWithError()
    }

    func testMismatchedServerSIDNeverRetractsOrMutatesRetainedState() throws {
        let f = try fixture(); let before = f.persistence.records[f.owner]
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        let query = try latest(f, namespace: metadataNS)
        _ = f.manager.read(withIQ: metadata(f, id: query.attributeStringValue(forName: "id")!, sid: 7), on: f.stream)
        XCTAssertTrue(retractions(f).isEmpty)
        XCTAssertTrue(publications(f).isEmpty)
        XCTAssertTrue(f.persistence.records[f.owner] == before, "Retained protected state must remain byte-identical")
        XCTAssertEqual(try f.storage.localBundle().deviceID, 42)
    }

    func testEveryPublicationRefreshesDevicesRatherThanReusingPreviousAuthorization() throws {
        let f = try fixture()
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        try drive(f, sid: 42, members: [42, 99], untilPublications: 1)
        let id = try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)
        _ = f.manager.read(withIQ: result(f, id: id), on: f.stream)
        try drive(f, sid: 42, members: [42, 99], untilPublications: 2, stopBeforePublication: true)
        let oldCount = metadataRequests(f).count
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        XCTAssertGreaterThan(metadataRequests(f).count, oldCount)
        XCTAssertEqual(publications(f).count, 1)
    }

    func testFreshRegistrationReadsBindingBeforeGeneratingPrivateIdentity() throws {
        let f = try fixture(localSID: nil)
        f.manager.beginOMEMO2Registration(f.stream)
        if let request = membershipRequests(f).last {
            _ = f.manager.read(withIQ: membership(f, id: request.attributeStringValue(forName: "id")!, ids: [99]), on: f.stream)
        }
        XCTAssertNil(try f.persistence.load(owner: f.owner))
        XCTAssertEqual(metadataRequests(f).count, 1)
        XCTAssertTrue(publications(f).isEmpty)
    }

    func testAssignedServerSIDWithoutLocalStateChecksPublishedIdentityBeforeGenerating() throws {
        let f = try fixture(localSID: nil)
        f.manager.beginOMEMO2Registration(f.stream)
        try drive(f, sid: 7, members: [7, 99], untilIdentityRead: true)
        let request = try XCTUnwrap(identityRequests(f).last)
        XCTAssertEqual(request.element(forName: "pubsub")?.element(forName: "items")?.element(forName: "item")?.attributeStringValue(forName: "id"), "7")
        XCTAssertNil(try f.persistence.load(owner: f.owner))
        XCTAssertTrue(publications(f).isEmpty)
    }

    func testAssignedPublishedIdentityWithoutPrivateStateRequiresRecoveryWithoutOverwrite() throws {
        let f = try fixture(localSID: nil)
        let other = try fixture(localSID: 7)
        let remote = OMEMO2PublishedBundle(try other.storage.localBundle())
        f.manager.beginOMEMO2Registration(f.stream)
        try drive(f, sid: 7, members: [7, 99], identity: remote)
        XCTAssertNil(try f.persistence.load(owner: f.owner))
        XCTAssertFalse(f.manager.isOmemoPrepared)
        XCTAssertTrue(publications(f).isEmpty)
        XCTAssertTrue(retractions(f).isEmpty)
    }

    func testAssignedUnpublishedServerSIDCreatesFirstIdentityWithThatExactID() throws {
        let f = try fixture(localSID: nil)
        f.manager.omemo2FreshDeviceIDGenerator = { 42 }
        f.manager.beginOMEMO2Registration(f.stream)
        try drive(f, sid: 7, members: [7, 99], untilPublications: 1)
        XCTAssertEqual(try f.storage.localBundle().deviceID, 7)
        XCTAssertEqual(publications(f).map { $0.attributeStringValue(forName: "id") }, ["7"])
        XCTAssertTrue(retractions(f).isEmpty)
    }

    func testUnassignedFreshRegistrationAvoidsAuthoritativeMemberIDs() throws {
        let f = try fixture(localSID: nil)
        var candidates = [42, 77]
        f.manager.omemo2FreshDeviceIDGenerator = { candidates.removeFirst() }
        f.manager.beginOMEMO2Registration(f.stream)
        try drive(f, sid: nil, members: [42, 99], untilPublications: 1)
        XCTAssertEqual(try f.storage.localBundle().deviceID, 77)
        XCTAssertEqual(publications(f).map { $0.attributeStringValue(forName: "id") }, ["77"])
    }

    func testBundleACKDoesNotFinishManagedStartupBeforeFreshMembershipContainsOwnID() throws {
        let f = try fixture(); f.manager.isOmemoPrepared = false
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        try drive(f, sid: 42, members: [42, 99], untilPublications: 1)
        let count = membershipRequests(f).count
        let id = try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)
        _ = f.manager.read(withIQ: result(f, id: id), on: f.stream)
        XCTAssertFalse(f.manager.isOmemoPrepared)
        XCTAssertGreaterThan(membershipRequests(f).count, count)
        let request = try XCTUnwrap(membershipRequests(f).last)
        _ = f.manager.read(withIQ: membership(f, id: request.attributeStringValue(forName: "id")!, ids: [42, 99]), on: f.stream)
        XCTAssertTrue(f.manager.isOmemoPrepared)
    }

    func testPostPublicationMembershipWithoutOwnIDDoesNotFinishStartup() throws {
        let f = try fixture(); f.manager.isOmemoPrepared = false
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        try drive(f, sid: 42, members: [42, 99], untilPublications: 1)
        let count = membershipRequests(f).count
        _ = f.manager.read(withIQ: result(f, id: try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)), on: f.stream)
        XCTAssertGreaterThan(membershipRequests(f).count, count)
        if let request = membershipRequests(f).last {
            _ = f.manager.read(withIQ: membership(f, id: request.attributeStringValue(forName: "id")!, ids: [99]), on: f.stream)
        }
        XCTAssertFalse(f.manager.isOmemoPrepared)
    }

    func testServerRSMAllowsRetainedIdentityPublicationAndFreshConfirmationWithoutResettingCrypto() throws {
        for beforeItems in [true, false] {
            let f = try fixture(); let peer = try fixture(localSID: 202)
            try establishSession(f, peer: peer)
            let originalIdentity = try f.storage.identity()
            let originalBundle = try f.storage.localBundle()
            let originalSession = try XCTUnwrap(f.storage.sessionMetadata(jid: peer.owner, deviceID: 202))
            let originalSnapshot = try XCTUnwrap(f.storage.registrationSnapshot())
            f.manager.beginOMEMO2Registration(f.stream)
            let startupMetadataID = try XCTUnwrap(metadataRequests(f).last?.attributeStringValue(forName: "id"))
            _ = f.manager.read(withIQ: metadata(f, id: startupMetadataID, sid: 42), on: f.stream)
            let startupMembershipID = try XCTUnwrap(membershipRequests(f).last?.attributeStringValue(forName: "id"))
            _ = f.manager.read(withIQ: try addingRSM(to: membership(f, id: startupMembershipID, ids: [42, 99]),
                                                   beforeItems: beforeItems), on: f.stream)
            let startupIdentity = try XCTUnwrap(identityRequests(f).last)
            let startupIdentityID = try XCTUnwrap(startupIdentity.attributeStringValue(forName: "id"))
            XCTAssertEqual(identityRequests(f).count, 1, "Startup must perform exactly one owned identity check")
            XCTAssertEqual(startupIdentity.attributeStringValue(forName: "to"), f.owner)
            XCTAssertEqual(startupIdentity.element(forName: "pubsub")?.element(forName: "items")?
                .element(forName: "item")?.attributeStringValue(forName: "id"), "42")
            let startupPending = try XCTUnwrap(f.manager.omemo2ManagedDevicesPublication.pending)
            guard case .identity(let startupFlow, let startupSID, .retained) = startupPending.operation else {
                return XCTFail("Startup identity response must belong to its pending owned flow")
            }
            XCTAssertEqual(startupPending.id, startupIdentityID)
            XCTAssertTrue(startupFlow.intent == .startup)
            XCTAssertEqual(startupSID, 42)
            XCTAssertEqual(startupFlow.binding.fullJID, f.stream.myJID?.full)
            XCTAssertTrue(startupFlow.snapshot?.hasSameIdentity(as: originalSnapshot) == true)
            let startupResponse = try identity(f, id: startupIdentityID, deviceID: 42,
                                               bundle: OMEMO2PublishedBundle(originalBundle))
            _ = f.manager.read(withIQ: try addingRSM(to: startupResponse, beforeItems: beforeItems), on: f.stream)

            // Setup consumes its own authority. Publication must obtain a new
            // Devices binding and its separate retained-identity check.
            XCTAssertTrue(publications(f).isEmpty)
            XCTAssertEqual(identityRequests(f).map { $0.attributeStringValue(forName: "id") }, [startupIdentityID])
            XCTAssertEqual(metadataRequests(f).count, 2)
            let publicationMetadataID = try XCTUnwrap(metadataRequests(f).last?.attributeStringValue(forName: "id"))
            XCTAssertNotEqual(publicationMetadataID, startupMetadataID)
            let publicationMetadataPending = try XCTUnwrap(f.manager.omemo2ManagedDevicesPublication.pending)
            guard case .metadata(.publication) = publicationMetadataPending.operation else {
                return XCTFail("Publication must refresh its own Devices binding after setup")
            }
            XCTAssertEqual(publicationMetadataPending.id, publicationMetadataID)
            _ = f.manager.read(withIQ: metadata(f, id: publicationMetadataID, sid: 42), on: f.stream)
            let publicationIdentities = identityRequests(f).filter { $0.attributeStringValue(forName: "id") != startupIdentityID }
            XCTAssertEqual(publicationIdentities.count, 1, "The fresh publication flow must have exactly one identity check")
            let publicationIdentity = try XCTUnwrap(publicationIdentities.first)
            let publicationIdentityID = try XCTUnwrap(publicationIdentity.attributeStringValue(forName: "id"))
            XCTAssertNotEqual(publicationIdentityID, startupIdentityID)
            XCTAssertEqual(publicationIdentity.attributeStringValue(forName: "to"), f.owner)
            XCTAssertEqual(publicationIdentity.element(forName: "pubsub")?.element(forName: "items")?
                .element(forName: "item")?.attributeStringValue(forName: "id"), "42")
            let publicationPending = try XCTUnwrap(f.manager.omemo2ManagedDevicesPublication.pending)
            guard case .identity(let publicationFlow, let publicationSID, .retained) = publicationPending.operation else {
                return XCTFail("The second identity response must belong to the new publication flow")
            }
            XCTAssertEqual(publicationPending.id, publicationIdentityID)
            XCTAssertTrue(publicationFlow.intent == .publication)
            XCTAssertEqual(publicationSID, 42)
            XCTAssertEqual(publicationFlow.binding.fullJID, f.stream.myJID?.full)
            XCTAssertTrue(publicationFlow.snapshot?.hasSameIdentity(as: originalSnapshot) == true)
            let publicationResponse = try identity(f, id: publicationIdentityID, deviceID: 42,
                                                   bundle: OMEMO2PublishedBundle(originalBundle))
            _ = f.manager.read(withIQ: try addingRSM(to: publicationResponse, beforeItems: beforeItems), on: f.stream)
            XCTAssertEqual(publications(f).map { $0.attributeStringValue(forName: "id") }, ["42"])
            XCTAssertFalse(f.manager.isOmemoPrepared)
            let publicationID = try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)
            _ = f.manager.read(withIQ: result(f, id: publicationID), on: f.stream)
            XCTAssertFalse(f.manager.isOmemoPrepared, "Bundle ACK alone cannot finish startup")
            let confirmation = try XCTUnwrap(membershipRequests(f).last?.attributeStringValue(forName: "id"))
            _ = f.manager.read(withIQ: try addingRSM(to: membership(f, id: confirmation, ids: [42, 99]),
                                                   beforeItems: beforeItems), on: f.stream)
            XCTAssertTrue(f.manager.isOmemoPrepared)
            let retainedIdentity = try f.storage.identity()
            XCTAssertTrue(retainedIdentity.privateKey == originalIdentity.privateKey, "RSM parsing must preserve private identity")
            XCTAssertTrue(retainedIdentity.publicKey == originalIdentity.publicKey)
            let retainedBundle = try f.storage.localBundle()
            XCTAssertTrue(retainedBundle.signedPreKey == originalBundle.signedPreKey)
            XCTAssertEqual(retainedBundle.signedPreKeyID, originalBundle.signedPreKeyID)
            let retainedSession = try XCTUnwrap(f.storage.sessionMetadata(jid: peer.owner, deviceID: 202))
            XCTAssertTrue(retainedSession.remoteIdentityKey == originalSession.remoteIdentityKey)
            XCTAssertTrue(retainedSession.ephemeralKey == originalSession.ephemeralKey)
            XCTAssertEqual(retainedSession.sendCounter, originalSession.sendCounter)
            XCTAssertEqual(retainedSession.receiveCounter, originalSession.receiveCounter)
            XCTAssertEqual(retainedSession.receiveOnly, originalSession.receiveOnly)
            XCTAssertEqual(retainedSession.keyExchangePending, originalSession.keyExchangePending)
            XCTAssertTrue(retractions(f).isEmpty)
            let material = Data(repeating: 0x65, count: 48)
            let packet = try f.storage.encrypt(material, jid: peer.owner, deviceID: 202)
            XCTAssertTrue(try peer.storage.decrypt(packet, jid: f.owner, deviceID: 42) == material,
                          "The actual retained native ratchet must remain decryptable")
        }
    }

    func testServerRSMEmptyIdentityResultPreservesAssignedFirstRegistrationAndRequiresConfirmation() throws {
        let f = try fixture(localSID: nil)
        f.manager.beginOMEMO2Registration(f.stream)
        try drive(f, sid: 7, members: [7, 99], untilIdentityRead: true, rsmBeforeItems: true)
        XCTAssertNil(f.persistence.records[f.owner], "RSM membership cannot skip the assigned identity read")
        XCTAssertEqual(identityRequests(f).count, 1)
        try drive(f, sid: 7, members: [7, 99], untilPublications: 1, rsmBeforeItems: true)
        XCTAssertEqual(try? f.storage.localBundle().deviceID, 7)
        XCTAssertEqual(publications(f).map { $0.attributeStringValue(forName: "id") }, ["7"])
        let publicationID = try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)
        _ = f.manager.read(withIQ: result(f, id: publicationID), on: f.stream)
        XCTAssertFalse(f.manager.isOmemoPrepared)
        let confirmation = try XCTUnwrap(membershipRequests(f).last?.attributeStringValue(forName: "id"))
        _ = f.manager.read(withIQ: try addingRSM(to: membership(f, id: confirmation, ids: [7, 99]),
                                               beforeItems: false), on: f.stream)
        XCTAssertTrue(f.manager.isOmemoPrepared)
        XCTAssertTrue(retractions(f).isEmpty)
    }

    func testRSMCursorCannotSubstituteForOwnIDInFreshPostACKMembership() throws {
        let f = try fixture()
        f.manager.beginOMEMO2Registration(f.stream)
        try drive(f, sid: 42, members: [42, 99], untilPublications: 1, rsmBeforeItems: true)
        let publicationID = try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)
        _ = f.manager.read(withIQ: result(f, id: publicationID), on: f.stream)
        let before = f.persistence.records[f.owner]
        let confirmation = try XCTUnwrap(membershipRequests(f).last?.attributeStringValue(forName: "id"))
        let rsm = "<set xmlns='http://jabber.org/protocol/rsm'><count>1</count><first index='0'>42</first><last>42</last></set>"
        _ = f.manager.read(withIQ: try addingRSM(to: membership(f, id: confirmation, ids: [99]),
                                               beforeItems: true, xml: rsm), on: f.stream)
        XCTAssertFalse(f.manager.isOmemoPrepared)
        XCTAssertTrue(f.persistence.records[f.owner] == before, "RSM cursor text cannot confirm or rewrite protected registration")
    }

    func testMalformedOrAmbiguousRSMCannotAuthorizeManagedMembership() throws {
        let malformed = [
            "<set xmlns='urn:foreign'><count>1</count></set>",
            "<set xmlns='http://jabber.org/protocol/rsm'><count>1</count><count>1</count></set>",
            "<set xmlns='http://jabber.org/protocol/rsm'><count xmlns='urn:foreign'>1</count></set>",
            "<set xmlns='http://jabber.org/protocol/rsm'><count><nested/></count></set>",
            "<set xmlns='http://jabber.org/protocol/rsm'><count>invalid</count></set>",
            "<set xmlns='http://jabber.org/protocol/rsm'><count>-1</count></set>",
            "<set xmlns='http://jabber.org/protocol/rsm'><first index='-1'>cursor</first></set>",
            "<set xmlns='http://jabber.org/protocol/rsm'><max>1</max></set>",
            "<set xmlns='http://jabber.org/protocol/rsm' extra='1'><count>1</count></set>",
            "<set xmlns='http://jabber.org/protocol/rsm'><count extra='1'>1</count></set>",
            "<set xmlns='http://jabber.org/protocol/rsm'/><set xmlns='http://jabber.org/protocol/rsm'/>"
        ]
        for xml in malformed {
            let f = try fixture(); let before = f.persistence.records[f.owner]
            f.manager.beginOMEMO2Registration(f.stream)
            let metadataID = try XCTUnwrap(metadataRequests(f).last?.attributeStringValue(forName: "id"))
            _ = f.manager.read(withIQ: metadata(f, id: metadataID, sid: 42), on: f.stream)
            let membershipID = try XCTUnwrap(membershipRequests(f).last?.attributeStringValue(forName: "id"))
            _ = f.manager.read(withIQ: try addingRSM(to: membership(f, id: membershipID, ids: [42, 99]),
                                                   beforeItems: true, xml: xml), on: f.stream)
            XCTAssertTrue(identityRequests(f).isEmpty)
            XCTAssertTrue(publications(f).isEmpty)
            XCTAssertFalse(f.manager.isOmemoPrepared)
            XCTAssertTrue(f.persistence.records[f.owner] == before, "Rejected RSM must leave protected state byte-identical")
        }
    }

    func testRSMCannotHideDifferentPublishedIdentityBehindItsCount() throws {
        let f = try fixture(); let peer = try fixture(localSID: 202); let other = try fixture(localSID: 42)
        try establishSession(f, peer: peer)
        let before = f.persistence.records[f.owner]
        f.manager.beginOMEMO2Registration(f.stream)
        let metadataID = try XCTUnwrap(metadataRequests(f).last?.attributeStringValue(forName: "id"))
        _ = f.manager.read(withIQ: metadata(f, id: metadataID, sid: 42), on: f.stream)
        let membershipID = try XCTUnwrap(membershipRequests(f).last?.attributeStringValue(forName: "id"))
        _ = f.manager.read(withIQ: try addingRSM(to: membership(f, id: membershipID, ids: [42, 99]),
                                               beforeItems: true), on: f.stream)
        let identityID = try XCTUnwrap(identityRequests(f).last?.attributeStringValue(forName: "id"))
        let response = try identity(f, id: identityID, deviceID: 42, bundle: OMEMO2PublishedBundle(other.storage.localBundle()))
        _ = f.manager.read(withIQ: try addingRSM(to: response, beforeItems: false,
                                               xml: "<set xmlns='http://jabber.org/protocol/rsm'><count>0</count></set>"), on: f.stream)
        XCTAssertTrue(publications(f).isEmpty)
        XCTAssertFalse(f.manager.isOmemoPrepared)
        XCTAssertTrue(f.persistence.records[f.owner] == before, "RSM metadata cannot override the own identity check")
        let material = Data(repeating: 0x66, count: 48)
        let packet = try f.storage.encrypt(material, jid: peer.owner, deviceID: 202)
        XCTAssertTrue(try peer.storage.decrypt(packet, jid: f.owner, deviceID: 42) == material)
    }

    func testExplicitDisableCannotRetractDifferentServerSID() throws {
        let f = try fixture(enabled: false)
        try f.manager.publicateOwnDevice(f.stream, createNode: false)
        let query = try latest(f, namespace: metadataNS)
        _ = f.manager.read(withIQ: metadata(f, id: query.attributeStringValue(forName: "id")!, sid: 7), on: f.stream)
        XCTAssertTrue(retractions(f).isEmpty)
        XCTAssertTrue(publications(f).isEmpty)
    }

    func testLegacyHOTPCannotAuthorizeManagedPublicationOrRetraction() throws {
        let f = try fixture(accepted: false)
        f.account.devices.recordAuthenticatedSession(on: f.stream, deviceID: nil, didResume: false, legacyHOTP: true)
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        XCTAssertTrue(publications(f).isEmpty)
        try setEnabled(f, false)
        f.manager.sendRetractOwnDevice(f.stream)
        XCTAssertTrue(retractions(f).isEmpty)
    }

    func testPolicyViolationRefreshesOnceAndBlocksEvenIfMappingChanges() throws {
        let f = try fixture()
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        try drive(f, sid: 42, members: [42, 99], untilPublications: 1)
        let count = metadataRequests(f).count
        _ = f.manager.read(withIQ: result(f, id: try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first), condition: "policy-violation"), on: f.stream)
        XCTAssertEqual(metadataRequests(f).count, count + 1)
        if let request = metadataRequests(f).last {
            _ = f.manager.read(withIQ: metadata(f, id: request.attributeStringValue(forName: "id")!, sid: 7), on: f.stream)
        }
        let refreshed = metadataRequests(f).count
        for _ in 0..<3 {
            f.manager.shouldPublicate = true; f.manager.omemo2PublicationRetryAt = nil
            f.manager.retryOMEMO2BundlePublication(on: f.stream)
        }
        XCTAssertEqual(metadataRequests(f).count, refreshed)
        XCTAssertEqual(publications(f).count, 1)
        XCTAssertTrue(retractions(f).isEmpty)
    }

    func testPolicyBlockSurvivesManagerResetWithinSameAcceptedAuthentication() throws {
        let f = try fixture()
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        try drive(f, sid: 42, members: [42, 99], untilPublications: 1)
        _ = f.manager.read(withIQ: result(f, id: try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first), condition: "policy-violation"), on: f.stream)
        f.manager.clearSession()
        f.manager.beginOMEMO2Registration(f.stream)
        try drive(f, sid: 42, members: [42, 99])
        XCTAssertEqual(publications(f).count, 1)
    }

    func testNonPolicyStorageFailureRetainsIdentityAndRetriesSameAssignedSID() throws {
        let f = try fixture(); let identity = try f.storage.identity().publicKey
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        try drive(f, sid: nil, members: [42, 99], untilPublications: 1)
        _ = f.manager.read(withIQ: result(f, id: try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first), condition: "internal-server-error"), on: f.stream)
        f.manager.omemo2PublicationRetryAt = nil; f.manager.shouldPublicate = true
        f.manager.retryOMEMO2BundlePublication(on: f.stream)
        try drive(f, sid: 42, members: [42, 99], untilPublications: 2)
        XCTAssertEqual(publications(f).map { $0.attributeStringValue(forName: "id") }, ["42", "42"])
        XCTAssertEqual(try f.storage.identity().publicKey, identity)
        XCTAssertTrue(retractions(f).isEmpty)
    }

    func testUnusedPendingRegistrationAdoptsOnlyAfterAuthoritativeAbsenceAndIdentityReads() throws {
        let f = try fixture(); let identity = try f.storage.identity().publicKey
        f.manager.beginOMEMO2Registration(f.stream)
        try drive(f, sid: 7, members: [7, 99], untilPublications: 1)
        XCTAssertEqual(try f.storage.localBundle().deviceID, 7)
        XCTAssertEqual(try f.storage.identity().publicKey, identity)
        XCTAssertEqual(publications(f).map { $0.attributeStringValue(forName: "id") }, ["7"])
        XCTAssertTrue(identityRequests(f).contains { $0.element(forName: "pubsub")?.element(forName: "items")?.element(forName: "item")?.attributeStringValue(forName: "id") == "42" })
        XCTAssertTrue(identityRequests(f).contains { $0.element(forName: "pubsub")?.element(forName: "items")?.element(forName: "item")?.attributeStringValue(forName: "id") == "7" })
        XCTAssertTrue(retractions(f).isEmpty)
    }

    func testUsedMismatchedStatePreservesUsableRealCryptoSession() throws {
        let f = try fixture(); let peer = try fixture(localSID: 202)
        try establishSession(f, peer: peer)
        let before = f.persistence.records[f.owner]
        f.manager.beginOMEMO2Registration(f.stream)
        try drive(f, sid: 7, members: [7, 99])
        XCTAssertTrue(f.persistence.records[f.owner] == before, "Rejected mismatch must preserve protected state")
        XCTAssertEqual(try f.storage.localBundle().deviceID, 42)
        XCTAssertTrue(publications(f).isEmpty); XCTAssertTrue(retractions(f).isEmpty)
        let material = Data(repeating: 2, count: 48)
        let packet = try f.storage.encrypt(material, jid: peer.owner, deviceID: 202)
        XCTAssertEqual(try peer.storage.decrypt(packet, jid: f.owner, deviceID: 42), material)
    }

    func testExplicitDisableReenableKeepsRealSessionAndRepublishesAfterOwnIdentityProbe() throws {
        let f = try fixture(); let peer = try fixture(localSID: 202)
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        try drive(f, sid: 42, members: [42, 99], untilPublications: 1)
        _ = f.manager.read(withIQ: result(f, id: try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)), on: f.stream)
        try drive(f, sid: 42, members: [42, 99])
        try establishSession(f, peer: peer)
        let identity = try f.storage.identity().publicKey
        try setEnabled(f, false); try f.manager.publicateOwnDevice(f.stream, createNode: false)
        try drive(f, sid: 42, members: [42, 99])
        let retractPacket = try XCTUnwrap(f.stream.packets.last { $0.element(forName: "pubsub")?.element(forName: "retract") != nil })
        _ = f.manager.read(withIQ: result(f, id: retractPacket.attributeStringValue(forName: "id")!), on: f.stream)
        try setEnabled(f, true)
        let identityReads = identityRequests(f).count
        f.manager.updateMyDevice(f.stream)
        try drive(f, sid: nil, members: [99], untilPublications: 2)
        XCTAssertEqual(publications(f).map { $0.attributeStringValue(forName: "id") }, ["42", "42"])
        XCTAssertGreaterThan(identityRequests(f).count, identityReads)
        XCTAssertEqual(try f.storage.identity().publicKey, identity)
        let material = Data(repeating: 3, count: 48)
        let packet = try f.storage.encrypt(material, jid: peer.owner, deviceID: 202)
        XCTAssertEqual(try peer.storage.decrypt(packet, jid: f.owner, deviceID: 42), material)
    }

    func testStaleStreamOrAuthenticationCannotCompleteAssignedIdentityProbe() throws {
        let f = try fixture(localSID: nil)
        f.manager.beginOMEMO2Registration(f.stream)
        try drive(f, sid: 7, members: [7], untilIdentityRead: true)
        let request = try XCTUnwrap(identityRequests(f).last)
        let reply = try identity(f, id: request.attributeStringValue(forName: "id")!, deviceID: 7, bundle: nil)
        let other = Stream(); other.myJID = f.stream.myJID
        XCTAssertFalse(f.manager.read(withIQ: reply, on: other))
        f.account.devices.recordAuthenticatedSession(on: f.stream, deviceID: "current-device", didResume: false)
        XCTAssertFalse(f.manager.read(withIQ: reply, on: f.stream))
        XCTAssertNil(try f.persistence.load(owner: f.owner))
    }

    func testIdentityErrorOrMalformedIdentityCannotBeTreatedAsUnpublished() throws {
        for malformed in [false, true] {
            let f = try fixture(localSID: nil)
            f.manager.beginOMEMO2Registration(f.stream)
            try drive(f, sid: 7, members: [7], untilIdentityRead: true)
            let request = try XCTUnwrap(identityRequests(f).last)
            let id = request.attributeStringValue(forName: "id")!
            var reply = result(f, id: id, condition: "internal-server-error")
            if malformed {
                reply = try identity(f, id: id, deviceID: 7, bundle: nil)
                let item = DDXMLElement(name: "item", xmlns: OMEMO2DeviceListCodec.pubsub); item.addAttribute(withName: "id", stringValue: "7")
                let bundle = DDXMLElement(name: "bundle", xmlns: "urn:xmpp:omemo:2")
                bundle.addChild(DDXMLElement(name: "ik", stringValue: "AAAA")); item.addChild(bundle)
                reply.element(forName: "pubsub")?.element(forName: "items")?.addChild(item)
            }
            _ = f.manager.read(withIQ: reply, on: f.stream)
            XCTAssertNil(try f.persistence.load(owner: f.owner))
            XCTAssertTrue(publications(f).isEmpty)
        }
    }

    func testConcurrentLocalCreationDuringServerIdentityReadIsNeverReplaced() throws {
        let f = try fixture(localSID: nil)
        f.manager.beginOMEMO2Registration(f.stream)
        try drive(f, sid: 7, members: [7], untilIdentityRead: true)
        let request = try XCTUnwrap(identityRequests(f).last)
        _ = try f.storage.prepare(deviceID: 77, preKeyCount: 2)
        let before = f.persistence.records[f.owner]
        _ = f.manager.read(withIQ: try identity(f, id: request.attributeStringValue(forName: "id")!, deviceID: 7, bundle: nil), on: f.stream)
        XCTAssertTrue(f.persistence.records[f.owner] == before, "Concurrent local state must not be replaced")
        XCTAssertEqual(try f.storage.localBundle().deviceID, 77)
        XCTAssertTrue(publications(f).isEmpty)
    }

    func testStrictMetadataRejectsUnknownFieldsNestedDataAndForeignRootPayload() throws {
        for variant in 0..<4 {
            let f = try fixture()
            try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
            let request = try latest(f, namespace: metadataNS)
            let reply = metadata(f, id: request.attributeStringValue(forName: "id")!, sid: 42)
            let device = try XCTUnwrap(reply.element(forName: "query")?.element(forName: "device"))
            switch variant {
            case 0: device.addChild(DDXMLElement(name: "unknown-field", xmlns: "https://xabber.com/protocol/devices"))
            case 1: device.element(forName: "omemo-id")?.addChild(DDXMLElement(name: "nested"))
            case 2: reply.addChild(DDXMLElement(name: "extra", xmlns: "urn:foreign"))
            default: device.addAttribute(withName: "id", stringValue: "current device")
            }
            _ = f.manager.read(withIQ: reply, on: f.stream)
            XCTAssertTrue(publications(f).isEmpty); XCTAssertTrue(retractions(f).isEmpty)
        }
    }

    func testBundleAdvanceAfterACKCannotConfirmAnOlderPublicationAsClean() throws {
        let f = try fixture(); f.manager.isOmemoPrepared = false
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        try drive(f, sid: 42, members: [42, 99], untilPublications: 1)
        _ = f.manager.read(withIQ: result(f, id: try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)), on: f.stream)
        let request = try XCTUnwrap(membershipRequests(f).last)
        _ = try f.storage.replenishPreKeys(minimumCount: 120)
        _ = f.manager.read(withIQ: membership(f, id: request.attributeStringValue(forName: "id")!, ids: [42,99]), on: f.stream)
        XCTAssertFalse(f.manager.isOmemoPrepared)
        XCTAssertTrue(f.manager.shouldPublicate)
    }

    func testSameSIDProtectedIdentityReplacementCannotUseAnEarlierPublicationProof() throws {
        let f = try fixture()
        let retained = OMEMO2PublishedBundle(try f.storage.localBundle())
        let replacementMemory = Memory()
        let replacement = try XabberOMEMO2Storage(owner: f.owner, persistence: replacementMemory)
        _ = try replacement.prepare(deviceID: 42, preKeyCount: 2)
        let replacementBytes = try XCTUnwrap(replacementMemory.records[f.owner])
        var replaced = false
        f.persistence.onLoad = {
            if !replaced && f.manager.omemo2ManagedDevicesPublication.authorization != nil {
                replaced = true
                f.persistence.records[f.owner] = replacementBytes
            }
        }
        defer { f.persistence.onLoad = nil }
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        try drive(f, sid: 42, members: [42,99], identity: retained)
        XCTAssertTrue(replaced)
        XCTAssertTrue(publications(f).isEmpty, "A proof for the old identity must never overwrite the published identity")
        XCTAssertTrue(f.persistence.records[f.owner] == replacementBytes, "Rejected replacement must remain unchanged")
        XCTAssertFalse(f.manager.isOmemoPrepared)
    }

    func testRealmReplayOrPendingOptOutEvidencePreventsPendingSIDAdoption() throws {
        for replay in [true, false] {
            let f = try fixture()
            let realm = try WRealm.safe()
            try realm.write {
                if replay {
                    let row = MessageStanzaStorageItem(); row.primary = "replay-" + UUID().uuidString
                    row.owner = f.owner; row.omemo2ReplayFingerprint = Data(repeating: 1, count: 32); realm.add(row)
                } else {
                    let row = OMEMO2OptOutStorageItem(); row.owner = f.owner; row.jid = "peer@example.test"
                    row.primary = OMEMO2OptOutStorageItem.genPrimary(owner: f.owner, jid: row.jid)
                    row.decisionRaw = OMEMO2OptOutPolicy.Decision.pending.rawValue; realm.add(row)
                }
            }
            let before = f.persistence.records[f.owner]
            f.manager.beginOMEMO2Registration(f.stream)
            try drive(f, sid: 7, members: [7,99])
            XCTAssertEqual(try f.storage.localBundle().deviceID, 42)
            XCTAssertTrue(f.persistence.records[f.owner] == before)
            XCTAssertTrue(publications(f).isEmpty); XCTAssertTrue(retractions(f).isEmpty)
        }
    }

    func testRepeatedUnusedPendingAdoptionIgnoresOnlyItsExactNonpublishedOwnIdentityProjections() throws {
        let f = try fixture(); let key = try f.storage.identity().publicKey
        f.manager.beginOMEMO2Registration(f.stream)
        try drive(f, sid: 7, members: [7,99], untilPublications: 1)
        XCTAssertEqual(try f.storage.localBundle().deviceID, 7)
        _ = f.manager.read(withIQ: result(f, id: try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first), condition: "internal-server-error"), on: f.stream)
        f.manager.beginOMEMO2Registration(f.stream)
        try drive(f, sid: 8, members: [8,99], untilPublications: 2)
        XCTAssertEqual(try f.storage.localBundle().deviceID, 8)
        XCTAssertEqual(try f.storage.identity().publicKey, key)
        XCTAssertEqual(publications(f).map { $0.attributeStringValue(forName: "id") }, ["7", "8"])
        XCTAssertTrue(retractions(f).isEmpty)
    }

    func testPolicyRefreshValidatesMalformedDevicesMetadataWithoutLiftingBlock() throws {
        let f = try fixture()
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        try drive(f, sid: 42, members: [42,99], untilPublications: 1)
        _ = f.manager.read(withIQ: result(f, id: try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first), condition: "policy-violation"), on: f.stream)
        let refresh = try XCTUnwrap(metadataRequests(f).last)
        let malformed = metadata(f, id: refresh.attributeStringValue(forName: "id")!, sid: 42)
        malformed.element(forName: "query")?.element(forName: "device")?.addChild(DDXMLElement(name: "unknown", xmlns: "urn:foreign"))
        _ = f.manager.read(withIQ: malformed, on: f.stream)
        XCTAssertEqual(f.manager.omemo2ManagedDevicesPublication.policyRefreshValidated, false)
        f.manager.shouldPublicate = true; f.manager.omemo2PublicationRetryAt = nil
        f.manager.retryOMEMO2BundlePublication(on: f.stream)
        XCTAssertEqual(publications(f).count, 1)
        XCTAssertTrue(retractions(f).isEmpty)
    }

    func testMembershipConfirmationFlushesRealPendingControlAfterReleasingMaintenanceLock() throws {
        let f = try fixture(); let peer = try fixture(localSID: 202)
        try establishSession(f, peer: peer)
        try f.storage.markControlNeeded(jid: peer.owner, deviceID: 202, needed: true)
        XCTAssertEqual(try f.storage.pendingControlAddresses().count, 1)
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        try drive(f, sid: 42, members: [42,99], untilPublications: 1)
        _ = f.manager.read(withIQ: result(f, id: try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)), on: f.stream)
        let request = try XCTUnwrap(membershipRequests(f).last)
        let response = membership(f, id: request.attributeStringValue(forName: "id")!, ids: [42,99])
        let sent = expectation(description: "real pending control prepared after confirmation")
        let finished = expectation(description: "membership callback completes without lock inversion")
        f.manager.omemo2ControlSender = { packet in
            XCTAssertNotNil(packet.element(forName: "encrypted", xmlns: "urn:xmpp:omemo:2"))
            sent.fulfill()
        }
        defer { f.manager.omemo2ControlSender = nil }
        DispatchQueue(label: "managed-confirmation-with-control").async {
            _ = f.manager.read(withIQ: response, on: f.stream)
            finished.fulfill()
        }
        wait(for: [sent, finished], timeout: 3)
        XCTAssertTrue(f.manager.isOmemoPrepared)
        XCTAssertTrue(try f.storage.pendingControlAddresses().isEmpty)
    }

    func testReadyMaintenanceRejectsProtectedIdentityReplacementDuringRotation() throws {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        var duringRotation: (() -> Void)?
        let f = try fixture(now: { duringRotation?(); return clock })
        try f.manager.sendOwnDeviceBundle(f.stream, createNode: false)
        try drive(f, sid: 42, members: [42,99], untilPublications: 1)
        _ = f.manager.read(withIQ: result(f, id: try XCTUnwrap(f.manager.omemo2BundlePublications.keys.first)), on: f.stream)
        try drive(f, sid: 42, members: [42,99]); f.account.queue.sync {}
        XCTAssertTrue(f.manager.isOmemoPrepared)
        clock.addTimeInterval(XabberOMEMO2Storage.signedPreKeyRotationInterval + 1)
        let replacementMemory = Memory()
        let replacement = try XabberOMEMO2Storage(owner: f.owner, persistence: replacementMemory, now: { clock })
        _ = try replacement.prepare(deviceID: 42, preKeyCount: 2)
        let replacementBytes = try XCTUnwrap(replacementMemory.records[f.owner])
        var replaced = false
        duringRotation = {
            duringRotation = nil; replaced = true
            f.persistence.records[f.owner] = replacementBytes
        }
        f.manager.omemo2LastMaintenanceAt = nil
        XCTAssertThrowsError(try f.manager.ensureOMEMO2Prepared(attemptPublication: false))
        XCTAssertTrue(replaced)
        XCTAssertTrue(f.persistence.records[f.owner] == replacementBytes, "Stale readiness must not mutate replacement private state")
        XCTAssertEqual(publications(f).count, 1)
        XCTAssertFalse(f.manager.isOmemoPrepared)
    }

    func testStartupSetupCannotPinAReplacementAggregateAfterEarlierIdentityValidation() throws {
        let f = try fixture()
        let original = try XCTUnwrap(f.storage.registrationSnapshot())
        let binding = try XCTUnwrap(f.manager.managedDevicesBinding(on: f.stream, localSID: 42))
        let flow = OMEMO2ManagedDevicesPublication.Flow(binding: binding, intent: .startup, serverSID: 42, snapshot: original)
        let replacementMemory = Memory()
        let replacement = try XabberOMEMO2Storage(owner: f.owner, persistence: replacementMemory)
        _ = try replacement.prepare(deviceID: 42, preKeyCount: 2)
        let bytes = try XCTUnwrap(replacementMemory.records[f.owner])
        f.persistence.records[f.owner] = bytes
        let current = try XCTUnwrap(f.storage.registrationSnapshot())
        XCTAssertThrowsError(try f.manager.validateManagedDevicesSetupSnapshot(flow, current: current))
        XCTAssertTrue(f.persistence.records[f.owner] == bytes)
        XCTAssertTrue(publications(f).isEmpty)
    }

    func testFetchedUntrustedPublicBundleCacheDoesNotPreventUnusedPendingSIDAdoption() throws {
        let f = try fixture(); let peer = try fixture(localSID: 202)
        let localIdentity = try f.storage.identity().publicKey
        let beforeCache = f.persistence.records[f.owner]
        let publicBundle = OMEMO2PublishedBundle(try peer.storage.localBundle())
        let items = DDXMLElement(name: "items", xmlns: OMEMO2DeviceListCodec.pubsub)
        items.addAttribute(withName: "node", stringValue: OmemoManager.NodeType.bundle.rawValue)
        items.addChild(try OMEMO2BundleCodec.encode(publicBundle))
        XCTAssertTrue(try f.manager.onContactBundleReceive(items: DDXMLElement(xmlString: items.xmlString), jid: peer.owner))
        XCTAssertTrue(f.persistence.records[f.owner] == beforeCache, "Fetching a public bundle does not use local private keys")
        XCTAssertTrue(try XCTUnwrap(f.storage.registrationSnapshot()).isUnusedPending)
        let realm = try WRealm.safe()
        let primary = SignalDeviceStorageItem.genPrimary(owner: f.owner, jid: peer.owner, deviceId: 202)
        let cachedDevice = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: primary))
        let cachedIdentity = try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: primary))
        let peerKey = cachedIdentity.identityKey; let peerFingerprint = cachedDevice.fingerprint
        XCTAssertEqual(cachedDevice.state, .unknown)
        XCTAssertFalse(peerFingerprint.isEmpty)
        f.manager.beginOMEMO2Registration(f.stream)
        try drive(f, sid: 7, members: [7,99], untilPublications: 1)
        XCTAssertEqual(try f.storage.localBundle().deviceID, 7)
        XCTAssertEqual(try f.storage.identity().publicKey, localIdentity)
        XCTAssertEqual(publications(f).map { $0.attributeStringValue(forName: "id") }, ["7"])
        XCTAssertEqual(cachedIdentity.identityKey, peerKey)
        XCTAssertEqual(cachedDevice.fingerprint, peerFingerprint)
        XCTAssertEqual(cachedDevice.state, .unknown)
        XCTAssertTrue(retractions(f).isEmpty)
    }

    private func establishSession(_ f: Fixture, peer: Fixture) throws {
        let bundle = try peer.storage.localBundle(); let key = try XCTUnwrap(bundle.preKeys.first)
        let remote = try OMEMO2Bundle(identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey,
            signedPreKeyID: bundle.signedPreKeyID, signature: bundle.signature, preKey: key.publicKey, preKeyID: key.id)
        try f.storage.initiateSession(jid: peer.owner, deviceID: bundle.deviceID, bundle: remote)
        let material = Data(repeating: 1, count: 48)
        let packet = try f.storage.encrypt(material, jid: peer.owner, deviceID: bundle.deviceID)
        XCTAssertEqual(try peer.storage.decrypt(packet, jid: f.owner, deviceID: try f.storage.localBundle().deviceID), material)
    }

    private let metadataNS = "https://xabber.com/protocol/devices#items"
    private func fixture(localSID: Int? = 42, accepted: Bool = true, enabled: Bool = true,
                         now: @escaping () -> Date = Date.init) throws -> Fixture {
        let owner = "server-id-\(UUID().uuidString.lowercased())@example.test"
        let realm = try WRealm.safe(); let row = AccountStorageItem()
        row.jid = owner; row.deviceUuid = "current-device"; row.isEncryptionEnabled = enabled
        try realm.write { realm.add(row) }
        let persistence = Memory(); let storage = try XabberOMEMO2Storage(owner: owner, persistence: persistence, now: now)
        if let localSID { _ = try storage.prepare(deviceID: localSID, preKeyCount: 2) }
        let account = Account(jid: owner, queue: DispatchQueue(label: "server-id-tests-\(UUID())"))
        account.omemo.omemo2Storage = storage; account.omemo.omemo2MaintenanceScheduler = { _, _ in }
        if localSID != nil { _ = try account.omemo.ensureOMEMO2Prepared(attemptPublication: false) }
        else { account.omemo.isOmemoPrepared = false }
        let stream = Stream(); stream.myJID = XMPPJID(string: owner + "/ios-test"); account.xmppStream = stream
        let features = DDXMLElement(name: "features")
        features.addChild(DDXMLElement(name: "devices", xmlns: "https://xabber.com/protocol/devices"))
        account.devices.setAvailable(features)
        let f = Fixture(account: account, stream: stream, storage: storage, persistence: persistence)
        fixtures.append(f); AccountManager.shared.users = originalUsers + fixtures.map(\.account)
        if accepted { account.devices.recordAuthenticatedSession(on: stream, deviceID: "current-device", didResume: false) }
        let ids = localSID.map { [$0,99] } ?? [99]
        let snapshot = OMEMO2DeviceListStorageItem(); snapshot.primary = OMEMO2DeviceListStorageItem.genPrimary(owner: owner, jid: owner)
        snapshot.owner = owner; snapshot.jid = owner; snapshot.isKnown = true; snapshot.itemID = "current"
        snapshot.deviceIDs.append(objectsIn: ids)
        snapshot.devicesXML = "<devices xmlns='urn:xmpp:omemo:2'>" + ids.map { "<device id='\($0)'/>" }.joined() + "</devices>"
        try realm.write { realm.add(snapshot, update: .modified) }
        return f
    }
    private func setEnabled(_ f: Fixture, _ enabled: Bool) throws {
        let realm = try WRealm.safe()
        try realm.write { realm.object(ofType: AccountStorageItem.self, forPrimaryKey: f.owner)?.isEncryptionEnabled = enabled }
    }
    private func metadataRequests(_ f: Fixture) -> [DDXMLElement] {
        f.stream.packets.filter { $0.attributeStringValue(forName: "type") == "get" && $0.element(forName: "query", xmlns: metadataNS) != nil }
    }
    private func membershipRequests(_ f: Fixture) -> [DDXMLElement] { requests(f, node: OmemoManager.NodeType.device.rawValue) }
    private func identityRequests(_ f: Fixture) -> [DDXMLElement] { requests(f, node: OmemoManager.NodeType.bundle.rawValue) }
    private func requests(_ f: Fixture, node: String) -> [DDXMLElement] {
        f.stream.packets.filter { $0.attributeStringValue(forName: "type") == "get" && $0.element(forName: "pubsub")?.element(forName: "items")?.attributeStringValue(forName: "node") == node }
    }
    private func latest(_ f: Fixture, namespace: String) throws -> DDXMLElement { try XCTUnwrap(metadataRequests(f).last) }
    private func publications(_ f: Fixture) -> [DDXMLElement] { items(f, operation: "publish") }
    private func retractions(_ f: Fixture) -> [DDXMLElement] { items(f, operation: "retract") }
    private func items(_ f: Fixture, operation: String) -> [DDXMLElement] {
        f.stream.packets.flatMap { packet -> [DDXMLElement] in
            guard let operation = packet.element(forName: "pubsub")?.element(forName: operation), operation.attributeStringValue(forName: "node") == OmemoManager.NodeType.bundle.rawValue else { return [] }
            return operation.elements(forName: "item")
        }
    }
    private func envelope(_ f: Fixture, id: String, child: DDXMLElement? = nil) -> XMPPIQ {
        let iq = XMPPIQ(iqType: .result, to: f.stream.myJID, elementID: id, child: child)
        iq.addAttribute(withName: "from", stringValue: f.owner)
        return try! XMPPIQ(xmlString: iq.xmlString)
    }
    private func metadata(_ f: Fixture, id: String, sid: Int?) -> XMPPIQ {
        let query = DDXMLElement(name: "query", xmlns: metadataNS)
        let device = DDXMLElement(name: "device", xmlns: "https://xabber.com/protocol/devices")
        device.addAttribute(withName: "id", stringValue: "current-device")
        if let sid { device.addChild(DDXMLElement(name: "omemo-id", stringValue: String(sid))) }
        query.addChild(device); return envelope(f,id:id,child:query)
    }
    private func membership(_ f: Fixture, id: String, ids: [Int]) -> XMPPIQ {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: OMEMO2DeviceListCodec.pubsub)
        let items = DDXMLElement(name: "items"); items.addAttribute(withName: "node", stringValue: OmemoManager.NodeType.device.rawValue)
        let item = DDXMLElement(name: "item"); item.addAttribute(withName: "id", stringValue: "current")
        let devices = DDXMLElement(name: "devices", xmlns: "urn:xmpp:omemo:2")
        for id in ids { let d=DDXMLElement(name:"device");d.addAttribute(withName:"id",stringValue:String(id));devices.addChild(d) }
        item.addChild(devices);items.addChild(item);pubsub.addChild(items);return envelope(f,id:id,child:pubsub)
    }
    private func addingRSM(to response: XMPPIQ, beforeItems: Bool, xml: String? = nil) throws -> XMPPIQ {
        let response = try XMPPIQ(xmlString: response.xmlString)
        let pubsub = try XCTUnwrap(response.element(forName: "pubsub", xmlns: OMEMO2DeviceListCodec.pubsub))
        let rsm = xml ?? "<set xmlns='http://jabber.org/protocol/rsm'><count>1</count><first index='0'>opaque-cursor</first><last>opaque-cursor</last></set>"
        let wrapper = try DDXMLElement(xmlString: "<wrapper>\(rsm)</wrapper>")
        let nodes = wrapper.elements(forName: "set").map { $0.copy() as! DDXMLElement }
        for node in nodes.reversed() {
            if beforeItems { pubsub.insertChild(node, at: 0) }
            else { pubsub.addChild(node) }
        }
        return try XMPPIQ(xmlString: response.xmlString)
    }
    private func identity(_ f: Fixture, id: String, deviceID: Int, bundle: OMEMO2PublishedBundle?) throws -> XMPPIQ {
        let pubsub = DDXMLElement(name: "pubsub", xmlns: OMEMO2DeviceListCodec.pubsub)
        let items = DDXMLElement(name: "items"); items.addAttribute(withName:"node",stringValue:OmemoManager.NodeType.bundle.rawValue)
        if let bundle { items.addChild(try OMEMO2BundleCodec.encode(bundle)) }
        pubsub.addChild(items);return envelope(f,id:id,child:pubsub)
    }
    private func result(_ f: Fixture, id: String, condition: String? = nil) -> XMPPIQ {
        guard let condition else { return envelope(f,id:id) }
        let iq=XMPPIQ(iqType:.error,to:f.stream.myJID,elementID:id);iq.addAttribute(withName:"from",stringValue:f.owner)
        let e=DDXMLElement(name:"error");e.addAttribute(withName:"type",stringValue:"cancel")
        e.addChild(DDXMLElement(name:condition,xmlns:"urn:ietf:params:xml:ns:xmpp-stanzas"));iq.addChild(e)
        return try! XMPPIQ(xmlString:iq.xmlString)
    }
    private func drive(_ f: Fixture, sid: Int?, members: [Int], identity bundle: OMEMO2PublishedBundle? = nil,
                       untilPublications target: Int? = nil, untilIdentityRead: Bool = false, stopBeforePublication: Bool = false,
                       rsmBeforeItems: Bool? = nil) throws {
        var handled = Set<String>()
        for _ in 0..<40 {
            if let target, publications(f).count >= target { return }
            let pending = f.stream.packets.filter { p in
                p.attributeStringValue(forName:"type")=="get" && p.attributeStringValue(forName:"id").map { !handled.contains($0) } == true
            }
            guard let request=pending.first,let id=request.attributeStringValue(forName:"id") else { return }
            handled.insert(id)
            if request.element(forName:"query",xmlns:metadataNS) != nil {
                if stopBeforePublication {
                    if f.manager.omemo2ManagedDevicesPublication.pending?.id == id { return }
                    continue
                }
                _=f.manager.read(withIQ:metadata(f,id:id,sid:sid),on:f.stream)
            } else if request.element(forName:"pubsub")?.element(forName:"items")?.attributeStringValue(forName:"node")==OmemoManager.NodeType.device.rawValue {
                let reply = membership(f,id:id,ids:members)
                _=f.manager.read(withIQ:try rsmBeforeItems.map { try addingRSM(to: reply, beforeItems: $0) } ?? reply,on:f.stream)
            } else {
                if untilIdentityRead { return }
                let wanted=request.element(forName:"pubsub")?.element(forName:"items")?.element(forName:"item")?.attributeIntegerValue(forName:"id") ?? 0
                let reply = try identity(f,id:id,deviceID:wanted,bundle:bundle)
                _=f.manager.read(withIQ:try rsmBeforeItems.map {
                    try addingRSM(to: reply, beforeItems: $0, xml: bundle == nil
                        ? "<set xmlns='http://jabber.org/protocol/rsm'><count>0</count></set>" : nil)
                } ?? reply,on:f.stream)
            }
        }
    }
}
