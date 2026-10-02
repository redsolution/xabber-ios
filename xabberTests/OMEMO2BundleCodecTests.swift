import CryptoKit
import RealmSwift
import SignalProtocolObjC
import XCTest
import XMPPFramework
@testable import xabber

final class OMEMO2BundleCodecTests: XCTestCase {
    func testRoundTripKeepsRawOMEMOKeysAndPositive31BitIDs() throws {
        let fixture = try makeBundle(deviceID: Int(Int32.max), signedPreKeyID: UInt32(Int32.max))
        let item = try OMEMO2BundleCodec.encode(fixture)
        let decoded = try OMEMO2BundleCodec.decode(item: item)

        XCTAssertEqual(decoded.deviceID, Int(Int32.max))
        XCTAssertEqual(decoded.identityKey, fixture.identityKey)
        XCTAssertEqual(decoded.fingerprintPublicKey, fixture.fingerprintPublicKey)
        XCTAssertEqual(decoded.signedPreKey, fixture.signedPreKey)
        XCTAssertEqual(decoded.signedPreKeyID, UInt32(Int32.max))
        XCTAssertEqual(decoded.signature, fixture.signature)
        XCTAssertEqual(decoded.preKeys.map(\.id), [9, 10])
        XCTAssertEqual(decoded.preKeys.map(\.publicKey), fixture.preKeys.map(\.publicKey))
        XCTAssertEqual(decoded.identityKey.count, 32)
        XCTAssertEqual(decoded.signedPreKey.count, 32)
        XCTAssertNoThrow(try decoded.selectedBundle(preKeyID: 10))
    }

    func testCanonicalFingerprintUsesRawMontgomeryKey() throws {
        let context = try OMEMO2Context(error: ())
        let identity = try context.generateIdentity()

        XCTAssertEqual(try OMEMO2BundleCodec.fingerprintPublicKey(identityKey: identity.publicKey), identity.fingerprintPublicKey)
        let prefixedLegacyKey = Data([5]) + identity.fingerprintPublicKey
        XCTAssertEqual(try OMEMO2BundleCodec.fingerprintPublicKey(storedIdentityKey: prefixedLegacyKey), identity.fingerprintPublicKey)
        XCTAssertEqual(try OMEMO2BundleCodec.fingerprintPublicKey(storedIdentityKey: identity.publicKey), identity.fingerprintPublicKey)
        XCTAssertThrowsError(try OMEMO2BundleCodec.fingerprintPublicKey(storedIdentityKey: Data([4]) + identity.fingerprintPublicKey))
    }

    func testExternalEd25519IdentitySignBitIsPreserved() throws {
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((0..<32).map(UInt8.init)))
        let context = try OMEMO2Context(error: ())
        let spk = try context.generateKeyPair()
        let pk = try context.generateKeyPair()
        let identity = signingKey.publicKey.rawRepresentation
        let fixture = OMEMO2PublishedBundle(
            deviceID: 7, identityKey: identity,
            fingerprintPublicKey: try OMEMO2BundleCodec.fingerprintPublicKey(identityKey: identity),
            signedPreKey: spk.publicKey, signedPreKeyID: 3,
            signature: try signingKey.signature(for: spk.publicKey),
            preKeys: [OMEMO2PublicPreKey(id: 9, publicKey: pk.publicKey)]
        )

        let decoded = try OMEMO2BundleCodec.decode(item: OMEMO2BundleCodec.encode(fixture))

        XCTAssertEqual(try XCTUnwrap(identity.last) & 0x80, 0x80)
        XCTAssertEqual(decoded.identityKey, identity)
        XCTAssertNoThrow(try decoded.selectedBundle(preKeyID: 9))
    }

    func testRejectsLegacySignalKeysInOMEMO2Namespace() throws {
        let item = try OMEMO2BundleCodec.encode(makeBundle())
        let bundle = try XCTUnwrap(item.element(forName: "bundle", xmlns: OmemoManager.xmlns))
        let identity = try XCTUnwrap(bundle.element(forName: "ik"))
        let rawIdentity = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(identity.stringValue)))
        identity.stringValue = (Data([5]) + rawIdentity).base64EncodedString()

        XCTAssertThrowsError(try OMEMO2BundleCodec.decode(item: item))
    }

    func testRejectsBadSignedPreKeySignatureBeforeAcceptingBundle() throws {
        let item = try OMEMO2BundleCodec.encode(makeBundle())
        let signature = try XCTUnwrap(item.element(forName: "bundle", xmlns: OmemoManager.xmlns)?.element(forName: "spks"))
        var bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(signature.stringValue)))
        bytes[0] ^= 1
        signature.stringValue = bytes.base64EncodedString()

        XCTAssertThrowsError(try OMEMO2BundleCodec.decode(item: item))
    }

    func testRejectsInvalidIDsAndDuplicatePreKeys() throws {
        for invalid in ["0", "-1", "2147483648", "1x"] {
            let item = try OMEMO2BundleCodec.encode(makeBundle())
            item.addAttribute(withName: "id", stringValue: invalid)
            XCTAssertThrowsError(try OMEMO2BundleCodec.decode(item: item), invalid)

            let keyItem = try OMEMO2BundleCodec.encode(makeBundle())
            let spk = try XCTUnwrap(keyItem.element(forName: "bundle", xmlns: OmemoManager.xmlns)?.element(forName: "spk"))
            spk.addAttribute(withName: "id", stringValue: invalid)
            XCTAssertThrowsError(try OMEMO2BundleCodec.decode(item: keyItem), invalid)
        }
        let item = try OMEMO2BundleCodec.encode(makeBundle())
        let preKeys = try XCTUnwrap(item.element(forName: "bundle", xmlns: OmemoManager.xmlns)?.element(forName: "prekeys"))
        let duplicate = try XCTUnwrap(preKeys.elements(forName: "pk").first?.copy() as? DDXMLElement)
        preKeys.addChild(duplicate)
        XCTAssertThrowsError(try OMEMO2BundleCodec.decode(item: item))
    }

    func testRejectsEmptyPreKeysDuplicateFieldsAndWrongNamespaces() throws {
        let item = try OMEMO2BundleCodec.encode(makeBundle())
        let preKeys = try XCTUnwrap(item.element(forName: "bundle", xmlns: OmemoManager.xmlns)?.element(forName: "prekeys"))
        preKeys.children?.forEach { $0.detach() }
        XCTAssertThrowsError(try OMEMO2BundleCodec.decode(item: item))

        let duplicateItem = try OMEMO2BundleCodec.encode(makeBundle())
        let bundle = try XCTUnwrap(duplicateItem.element(forName: "bundle", xmlns: OmemoManager.xmlns))
        bundle.addChild(try XCTUnwrap(bundle.element(forName: "ik")?.copy() as? DDXMLElement))
        XCTAssertThrowsError(try OMEMO2BundleCodec.decode(item: duplicateItem))

        let wrongItem = try OMEMO2BundleCodec.encode(makeBundle())
        let wrongBundle = try XCTUnwrap(wrongItem.element(forName: "bundle", xmlns: OmemoManager.xmlns))
        let wrongIdentity = try XCTUnwrap(wrongBundle.element(forName: "ik"))
        wrongIdentity.uri = "urn:wrong"
        XCTAssertThrowsError(try OMEMO2BundleCodec.decode(item: wrongItem))
    }

    func testBase64AcceptsXMLWhitespaceAndRejectsOtherIgnoredCharacters() throws {
        let item = try OMEMO2BundleCodec.encode(makeBundle())
        let identity = try XCTUnwrap(item.element(forName: "bundle", xmlns: OmemoManager.xmlns)?.element(forName: "ik"))
        let original = try XCTUnwrap(identity.stringValue)
        identity.stringValue = " \n\t" + original + "\r "
        XCTAssertNoThrow(try OMEMO2BundleCodec.decode(item: item))
        identity.stringValue = "!" + original
        XCTAssertThrowsError(try OMEMO2BundleCodec.decode(item: item))
    }

    func testPublicationHasRequiredOpenAccessAndMultipleBundleOptions() throws {
        let pubsub = try OMEMO2BundleCodec.publication(makeBundle())
        let publish = try XCTUnwrap(pubsub.element(forName: "publish"))
        let fields = try XCTUnwrap(pubsub.element(forName: "publish-options")?.element(forName: "x", xmlns: "jabber:x:data"))
            .elements(forName: "field")
        let values = Dictionary(uniqueKeysWithValues: fields.compactMap { field -> (String, String)? in
            guard let name = field.attributeStringValue(forName: "var"), let value = field.element(forName: "value")?.stringValue else { return nil }
            return (name, value)
        })

        XCTAssertEqual(publish.attributeStringValue(forName: "node"), "urn:xmpp:omemo:2:bundles")
        XCTAssertEqual(values["FORM_TYPE"], "http://jabber.org/protocol/pubsub#publish-options")
        XCTAssertEqual(values["pubsub#access_model"], "open")
        XCTAssertEqual(values["pubsub#max_items"], "max")
    }

    func testLegacyCacheDoesNotSelectTheNewProfileFromNamespaceAlone() throws {
        let fixture = try makeBundle()
        let identity = SignalIdentityStorageItem()
        identity.deviceId = fixture.deviceID
        identity.identityKey = fixture.identityKey.base64EncodedString()
        identity.signedPreKey = fixture.signedPreKey.base64EncodedString()
        identity.signedPreKeyId = Int(fixture.signedPreKeyID)
        identity.signedPreKeySignature = fixture.signature.base64EncodedString()
        let preKeys = fixture.preKeys.map { value -> SignalPreKeysStorageItem in
            let key = SignalPreKeysStorageItem()
            key.pkId = Int(value.id)
            key.preKey = value.publicKey.base64EncodedString()
            return key
        }

        XCTAssertThrowsError(try OMEMO2BundleCodec.storedBundle(identity, preKeys: preKeys))
        identity.protocolProfile = OMEMO2BundleCodec.namespace
        XCTAssertEqual(try OMEMO2BundleCodec.storedBundle(identity, preKeys: preKeys).identityKey, fixture.identityKey)
    }

    private func makeBundle(deviceID: Int = 7, signedPreKeyID: UInt32 = 3) throws -> OMEMO2PublishedBundle {
        let context = try OMEMO2Context(error: ())
        let identity = try context.generateIdentity()
        let spk = try context.generateKeyPair()
        let preKeys = try [9, 10].map { id in
            OMEMO2PublicPreKey(id: UInt32(id), publicKey: try context.generateKeyPair().publicKey)
        }
        return OMEMO2PublishedBundle(
            deviceID: deviceID, identityKey: identity.publicKey, fingerprintPublicKey: identity.fingerprintPublicKey,
            signedPreKey: spk.publicKey, signedPreKeyID: signedPreKeyID,
            signature: try context.sign(spk.publicKey, identity: identity), preKeys: preKeys
        )
    }
}

@MainActor
final class OMEMO2BundleCacheIntegrationTests: XCTestCase {
    private final class MemoryPersistence: OMEMO2StatePersistence {
        var records: [String: Data] = [:]
        var failWrites = false
        var legacy: (publicKey: Data, privateKey: Data)?
        var legacyDevice: Int?
        func load(owner: String) -> Data? { records[owner] }
        func save(_ data: Data, owner: String) throws {
            if failWrites { throw OMEMO2StorageError.persistenceFailed }
            records[owner] = data
        }
        func remove(owner: String) { records.removeValue(forKey: owner) }
        func legacyIdentity(owner: String) -> (publicKey: Data, privateKey: Data)? { legacy }
        func legacyDeviceID(owner: String) -> Int? { legacyDevice }
    }
    private var originalConfiguration: Realm.Configuration!
    private var realm: Realm!
    private let owner = "bundle-codec-owner@example.test"
    private let peer = "bundle-codec-peer@example.test"

    override func setUpWithError() throws {
        originalConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "OMEMO2BundleCache-" + UUID().uuidString)
        realm = try WRealm.safe()
    }

    override func tearDownWithError() throws {
        realm = nil
        Realm.Configuration.defaultConfiguration = originalConfiguration
    }

    func testMalformedPublicationPreservesCachedIdentityDeviceAndTrust() throws {
        let identity = try OMEMO2Context(error: ()).generateIdentity()
        try cacheLegacyIdentity(identity)
        let beforeIdentity = realm.objects(SignalIdentityStorageItem.self).first?.identityKey
        let item = try makeItem(identity: identity)
        item.element(forName: "bundle", xmlns: OmemoManager.xmlns)?.element(forName: "spks")?.stringValue = Data(repeating: 0, count: 64).base64EncodedString()
        let manager = OmemoManager(withOwner: owner)

        XCTAssertThrowsError(try manager.onContactBundleReceive(items: items(item), jid: peer))

        XCTAssertEqual(realm.objects(SignalIdentityStorageItem.self).first?.identityKey, beforeIdentity)
        XCTAssertEqual(realm.objects(SignalDeviceStorageItem.self).first?.state, .trusted)
        XCTAssertEqual(realm.objects(SignalTrustedIdentityStoreageItem.self).count, 1)
        XCTAssertEqual(realm.objects(SessionRecordStorageItem.self).count, 1)
    }

    func testEquivalentLegacyIdentityPreservesTrustAndTheReadOnlyLegacySession() throws {
        let identity = try OMEMO2Context(error: ()).generateIdentity()
        try cacheLegacyIdentity(identity)
        let manager = OmemoManager(withOwner: owner)

        XCTAssertTrue(try manager.onContactBundleReceive(items: items(makeItem(identity: identity)), jid: peer))

        XCTAssertEqual(realm.objects(SignalIdentityStorageItem.self).first?.protocolProfile, OmemoManager.xmlns)
        XCTAssertEqual(realm.objects(SignalIdentityStorageItem.self).first?.identityKey, identity.publicKey.base64EncodedString())
        XCTAssertEqual(realm.objects(SignalDeviceStorageItem.self).first?.state, .trusted)
        XCTAssertEqual(realm.objects(SignalDeviceStorageItem.self).first?.fingerprint, try Omemo2IdentityRepresentation.fingerprint(for: identity.publicKey))
        XCTAssertEqual(realm.objects(SignalTrustedIdentityStoreageItem.self).first?.identity, identity.publicKey)
        XCTAssertEqual(realm.objects(SessionRecordStorageItem.self).count, 1)
        XCTAssertEqual(realm.objects(SessionRecordStorageItem.self).first?.profile_, SessionRecordStorageItem.legacyProfile)
    }

    func testEquivalentLegacyIdentityDoesNotCarryCertificateOnlyTrustIntoOMEMO2() throws {
        let identity = try OMEMO2Context(error: ()).generateIdentity()
        try cacheLegacyIdentity(identity)
        let device = try XCTUnwrap(realm.objects(SignalDeviceStorageItem.self).first)
        try realm.write {
            device.isTrustedByCertificate = true
            device.trustedByDeviceId = nil
        }
        let manager = OmemoManager(withOwner: owner)

        XCTAssertTrue(try manager.onContactBundleReceive(items: items(makeItem(identity: identity)), jid: peer))

        XCTAssertEqual(device.state, .unknown)
        XCTAssertFalse(device.isTrustedByCertificate)
        XCTAssertNil(device.trustedByDeviceId)
        XCTAssertEqual(device.fingerprint, try Omemo2IdentityRepresentation.fingerprint(for: identity.publicKey))
        XCTAssertEqual(realm.objects(SessionRecordStorageItem.self).count, 1)
    }

    func testEquivalentIdentityKeepsExplicitManualTrustDespiteLegacyCertificateMetadata() throws {
        let identity = try OMEMO2Context(error: ()).generateIdentity()
        try cacheLegacyIdentity(identity)
        let device = try XCTUnwrap(realm.objects(SignalDeviceStorageItem.self).first)
        try realm.write {
            device.isTrustedByCertificate = true
            device.trustedByDeviceId = "manual"
        }
        let manager = OmemoManager(withOwner: owner)

        XCTAssertTrue(try manager.onContactBundleReceive(items: items(makeItem(identity: identity)), jid: peer))

        XCTAssertEqual(device.state, .trusted)
        XCTAssertEqual(device.trustedByDeviceId, "manual")
        XCTAssertFalse(device.isTrustedByCertificate)
    }

    func testChangedIdentityRevokesTrustAndClearsTheLegacySession() throws {
        let context = try OMEMO2Context(error: ())
        try cacheLegacyIdentity(context.generateIdentity())
        let replacement = try context.generateIdentity()
        let manager = OmemoManager(withOwner: owner)

        XCTAssertTrue(try manager.onContactBundleReceive(items: items(makeItem(identity: replacement)), jid: peer))

        XCTAssertEqual(realm.objects(SignalDeviceStorageItem.self).first?.state, .fingerprintChanged)
        XCTAssertEqual(realm.objects(SignalTrustedIdentityStoreageItem.self).count, 0)
        XCTAssertEqual(realm.objects(SessionRecordStorageItem.self).count, 0)
    }

    func testChangedIdentityClearsOnlyThatPeerDeviceOMEMO2Sessions() throws {
        let context = try OMEMO2Context(error: ())
        let previous = try context.generateIdentity()
        try cacheLegacyIdentity(previous)
        let persistence = MemoryPersistence()
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        _ = try storage.prepare(deviceID: 1, preKeyCount: 1)
        let peerBundle = try OMEMO2BundleCodec.decode(item: makeItem(identity: previous)).selectedBundle(preKeyID: 9)
        try storage.initiateSession(jid: peer, deviceID: 7, bundle: peerBundle)
        try storage.initiateSession(jid: peer, deviceID: 8, bundle: peerBundle)
        let manager = OmemoManager(withOwner: owner)
        manager.omemo2Storage = storage

        XCTAssertTrue(try manager.onContactBundleReceive(items: items(makeItem(identity: context.generateIdentity())), jid: peer))

        XCTAssertFalse(try storage.sessionExists(jid: peer, deviceID: 7))
        XCTAssertTrue(try storage.sessionExists(jid: peer, deviceID: 8))
        XCTAssertEqual(realm.objects(SignalDeviceStorageItem.self).first?.state, .fingerprintChanged)
    }

    func testFailedSessionInvalidationLeavesCachedKeysAndTrustUnchanged() throws {
        let context = try OMEMO2Context(error: ())
        let previous = try context.generateIdentity()
        try cacheLegacyIdentity(previous)
        let persistence = MemoryPersistence()
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        _ = try storage.prepare(deviceID: 1, preKeyCount: 1)
        let peerBundle = try OMEMO2BundleCodec.decode(item: makeItem(identity: previous)).selectedBundle(preKeyID: 9)
        try storage.initiateSession(jid: peer, deviceID: 7, bundle: peerBundle)
        let snapshot = persistence.records[owner]
        let manager = OmemoManager(withOwner: owner)
        manager.omemo2Storage = storage
        persistence.failWrites = true

        XCTAssertThrowsError(try manager.onContactBundleReceive(items: items(makeItem(identity: context.generateIdentity())), jid: peer))

        XCTAssertEqual(persistence.records[owner], snapshot)
        XCTAssertTrue(try storage.sessionExists(jid: peer, deviceID: 7))
        XCTAssertEqual(realm.objects(SignalIdentityStorageItem.self).first?.identityKey, (Data([5]) + previous.fingerprintPublicKey).base64EncodedString())
        XCTAssertEqual(realm.objects(SignalDeviceStorageItem.self).first?.state, .trusted)
        XCTAssertEqual(realm.objects(SignalTrustedIdentityStoreageItem.self).count, 1)
        XCTAssertEqual(realm.objects(SessionRecordStorageItem.self).count, 1)
    }

    func testFailedAndUnownedPublicationResultsCannotMarkPublicationSuccess() throws {
        let manager = OmemoManager(withOwner: owner)
        manager.shouldPublicate = false
        manager.omemo2BundlePublications["pending"] = Data(repeating: 1, count: 32)

        XCTAssertFalse(manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .result, to: nil, elementID: "unknown")))
        XCTAssertFalse(manager.shouldPublicate)
        XCTAssertTrue(manager.onOMEMO2PublicationResult(XMPPIQ(iqType: .error, to: nil, elementID: "pending")))
        XCTAssertTrue(manager.shouldPublicate)
        XCTAssertTrue(manager.omemo2BundlePublications.isEmpty)
        XCTAssertTrue(realm.objects(SignalDeviceStorageItem.self).isEmpty)
    }

    func testPreparedProfileBindsOwnPublicMetadataWithoutChangingLegacyCredentials() throws {
        let identity = try OMEMO2Context(error: ()).generateIdentity()
        let legacyPublic = Data([5]) + identity.fingerprintPublicKey
        let persistence = MemoryPersistence()
        persistence.legacy = (legacyPublic, identity.privateKey)
        persistence.legacyDevice = 31
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        let bundle = try storage.prepare(deviceID: 31, preKeyCount: 2)
        let oldIdentity = SignalIdentityStorageItem()
        oldIdentity.owner = owner
        oldIdentity.jid = owner
        oldIdentity.deviceId = 31
        oldIdentity.primary = SignalIdentityStorageItem.genRpimary(owner: owner, jid: owner, deviceId: 31)
        oldIdentity.identityKey = legacyPublic.base64EncodedString()
        oldIdentity.isPublicated = true
        let oldDevice = SignalDeviceStorageItem()
        oldDevice.owner = owner
        oldDevice.jid = owner
        oldDevice.deviceId = 31
        oldDevice.primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: owner, deviceId: 31)
        oldDevice.state = .trusted
        oldDevice.fingerprint = legacyPublic.formattedFingerprint()
        oldDevice.isPublicated = true
        try realm.write { realm.add(oldIdentity); realm.add(oldDevice) }
        let publicCredential = CredentialsManager.shared.getIdentityKeyPublicKey(for: owner)
        let privateCredential = CredentialsManager.shared.getIdentityKeyPrivateKey(for: owner)
        let deviceCredential = CredentialsManager.shared.getDeviceId(for: owner)
        let manager = OmemoManager(withOwner: owner)
        manager.omemo2Storage = storage

        XCTAssertTrue(try manager.ensureOMEMO2Prepared() === storage)

        let publicRecord = try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self, forPrimaryKey: oldIdentity.primary))
        let deviceRecord = try XCTUnwrap(realm.object(ofType: SignalDeviceStorageItem.self, forPrimaryKey: oldDevice.primary))
        XCTAssertEqual(publicRecord.protocolProfile, OmemoManager.xmlns)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(publicRecord.identityKey)), bundle.identityKey)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(publicRecord.signedPreKey)), bundle.signedPreKey)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(publicRecord.signedPreKeySignature)), bundle.signature)
        XCTAssertEqual(publicRecord.signedPreKeyId, Int(bundle.signedPreKeyID))
        XCTAssertEqual(deviceRecord.fingerprint, try Omemo2IdentityRepresentation.fingerprint(for: bundle.identityKey))
        XCTAssertEqual(deviceRecord.state, .trusted)
        XCTAssertFalse(publicRecord.isPublicated)
        XCTAssertFalse(deviceRecord.isPublicated)
        XCTAssertEqual(persistence.legacy?.publicKey, legacyPublic)
        XCTAssertEqual(persistence.legacy?.privateKey, identity.privateKey)
        XCTAssertEqual(CredentialsManager.shared.getIdentityKeyPublicKey(for: owner), publicCredential)
        XCTAssertEqual(CredentialsManager.shared.getIdentityKeyPrivateKey(for: owner), privateCredential)
        XCTAssertEqual(CredentialsManager.shared.getDeviceId(for: owner), deviceCredential)
    }

    func testRepeatedOwnBindingIsIdempotentAndPreservesOtherAccountsSessionsAndTrust() throws {
        let context = try OMEMO2Context(error: ())
        let peerIdentity = try context.generateIdentity()
        try cacheLegacyIdentity(peerIdentity)
        let persistence = MemoryPersistence()
        let storage = try XabberOMEMO2Storage(owner: owner, persistence: persistence)
        _ = try storage.prepare(deviceID: 31, preKeyCount: 2)
        let peerBundle = try OMEMO2BundleCodec.decode(item: makeItem(identity: peerIdentity)).selectedBundle(preKeyID: 9)
        try storage.initiateSession(jid: peer, deviceID: 7, bundle: peerBundle)
        let otherIdentity = SignalIdentityStorageItem()
        otherIdentity.owner = "other-account@example.test"
        otherIdentity.jid = otherIdentity.owner
        otherIdentity.deviceId = 91
        otherIdentity.primary = SignalIdentityStorageItem.genRpimary(owner: otherIdentity.owner, jid: otherIdentity.jid, deviceId: 91)
        otherIdentity.identityKey = Data([5, 6, 7]).base64EncodedString()
        let otherDevice = SignalDeviceStorageItem()
        otherDevice.owner = otherIdentity.owner
        otherDevice.jid = otherIdentity.jid
        otherDevice.deviceId = 91
        otherDevice.primary = SignalDeviceStorageItem.genPrimary(owner: otherDevice.owner, jid: otherDevice.jid, deviceId: 91)
        otherDevice.state = .revoked
        otherDevice.fingerprint = "other-account-fingerprint"
        try realm.write { realm.add(otherIdentity); realm.add(otherDevice) }
        let secretSnapshot = persistence.records[owner]
        let manager = OmemoManager(withOwner: owner)
        manager.omemo2Storage = storage

        _ = try manager.ensureOMEMO2Prepared()
        let firstOwnRecord = try XCTUnwrap(realm.object(ofType: SignalIdentityStorageItem.self,
            forPrimaryKey: SignalIdentityStorageItem.genRpimary(owner: owner, jid: owner, deviceId: 31)))
        let firstIdentity = firstOwnRecord.identityKey
        let firstSPK = firstOwnRecord.signedPreKey
        let firstSignature = firstOwnRecord.signedPreKeySignature
        _ = try manager.ensureOMEMO2Prepared()

        XCTAssertEqual(firstOwnRecord.identityKey, firstIdentity)
        XCTAssertEqual(firstOwnRecord.signedPreKey, firstSPK)
        XCTAssertEqual(firstOwnRecord.signedPreKeySignature, firstSignature)
        XCTAssertEqual(persistence.records[owner], secretSnapshot)
        XCTAssertTrue(try storage.sessionExists(jid: peer, deviceID: 7))
        XCTAssertEqual(realm.objects(SessionRecordStorageItem.self).count, 1)
        XCTAssertEqual(realm.objects(SignalTrustedIdentityStoreageItem.self).first?.identity, Data([5]) + peerIdentity.fingerprintPublicKey)
        XCTAssertEqual(realm.object(ofType: SignalDeviceStorageItem.self,
            forPrimaryKey: SignalDeviceStorageItem.genPrimary(owner: owner, jid: peer, deviceId: 7))?.state, .trusted)
        XCTAssertEqual(otherIdentity.identityKey, Data([5, 6, 7]).base64EncodedString())
        XCTAssertEqual(otherIdentity.protocolProfile, "legacy-signal")
        XCTAssertEqual(otherDevice.state, .revoked)
        XCTAssertEqual(otherDevice.fingerprint, "other-account-fingerprint")
    }

    private func cacheLegacyIdentity(_ key: OMEMO2IdentityKeyPair) throws {
        let legacy = Data([5]) + key.fingerprintPublicKey
        let identity = SignalIdentityStorageItem()
        identity.owner = owner
        identity.jid = peer
        identity.deviceId = 7
        identity.primary = SignalIdentityStorageItem.genRpimary(owner: owner, jid: peer, deviceId: 7)
        identity.identityKey = legacy.base64EncodedString()
        let device = SignalDeviceStorageItem()
        device.owner = owner
        device.jid = peer
        device.deviceId = 7
        device.primary = SignalDeviceStorageItem.genPrimary(owner: owner, jid: peer, deviceId: 7)
        device.state = .trusted
        let trusted = SignalTrustedIdentityStoreageItem()
        trusted.owner = owner
        trusted.jid = peer
        trusted.deviceId = 7
        trusted.primary = SignalTrustedIdentityStoreageItem.genPrimary(owner: owner, jid: peer, deviceId: 7)
        trusted.identity = legacy
        let session = SessionRecordStorageItem()
        session.owner = owner
        session.jid = peer
        session.deviceId = 7
        session.primary = SessionRecordStorageItem.genPrimary(owner: owner, jid: peer, deviceId: 7)
        session.record = Data([1, 2, 3])
        try realm.write {
            realm.add(identity)
            realm.add(device)
            realm.add(trusted)
            realm.add(session)
        }
    }

    private func makeItem(identity: OMEMO2IdentityKeyPair) throws -> DDXMLElement {
        let context = try OMEMO2Context(error: ())
        let spk = try context.generateKeyPair()
        let pk = try context.generateKeyPair()
        return try OMEMO2BundleCodec.encode(OMEMO2PublishedBundle(
            deviceID: 7, identityKey: identity.publicKey, fingerprintPublicKey: identity.fingerprintPublicKey,
            signedPreKey: spk.publicKey, signedPreKeyID: 3, signature: context.sign(spk.publicKey, identity: identity),
            preKeys: [OMEMO2PublicPreKey(id: 9, publicKey: pk.publicKey)]
        ))
    }

    private func items(_ item: DDXMLElement) -> DDXMLElement {
        let items = DDXMLElement(name: "items")
        items.addAttribute(withName: "node", stringValue: OmemoManager.NodeType.bundle.rawValue)
        items.addChild(item)
        return items
    }
}
