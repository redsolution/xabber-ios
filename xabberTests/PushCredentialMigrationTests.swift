import Foundation
import XCTest
import SwiftKeychainWrapper
@testable import xabber

final class PushCredentialMigrationTests: XCTestCase {
    private var nodes: [String] = []

    override func tearDown() {
        nodes.forEach { CredentialsManager.shared.removePushCredentials(for: $0) }
        nodes.removeAll()
        super.tearDown()
    }

    func testLegacyCredentialRecordPreservesOpaqueSecretButRequiresFreshHTTPDiscovery() throws {
        let node = try storeFixture([
            "jid": "romeo@example.invalid",
            "host": "example.invalid",
            "secret": "opaque-private-fixture",
            "service": "https://archive.example.invalid",
            "jwt": "opaque-jwt-fixture"
        ])

        let record = try CredentialsManager.shared.getPushCredentials(for: node)

        XCTAssertEqual(record.jid, "romeo@example.invalid")
        XCTAssertEqual(record.secret, "opaque-private-fixture")
        XCTAssertEqual(record.service, "https://archive.example.invalid")
        XCTAssertEqual(record.jwt, "opaque-jwt-fixture")
        XCTAssertNil(record.httpArchive)
        XCTAssertEqual(try CredentialsManager.staticGetPushCredentials(for: node).secret, record.secret)
    }

    func testVersionThreeAtomicallyRoundTripsDiscoveredArchiveGrantAndBinaryKey() throws {
        let node = "push-http-grant-\(UUID().uuidString)"
        nodes.append(node)
        let bytes = Array(UInt8(0)...UInt8(31))
        let grant = archiveGrant()

        try CredentialsManager.shared.storePushCredentials(
            node: node, jid: "romeo@example.invalid", host: "example.invalid",
            secret: Data(bytes).base64EncodedString(), service: "", jwt: "",
            keyEncoding: .base64, grantRevision: "issuance-one", httpArchive: grant
        )
        let record = try CredentialsManager.staticGetPushCredentials(for: node)

        XCTAssertEqual(record.version, 3)
        XCTAssertEqual(record.keyBytes, bytes)
        XCTAssertEqual(record.httpArchive, grant)
        XCTAssertTrue(try XCTUnwrap(record.httpArchive).isUsable(
            forAccount: record.jid, host: record.host, now: grantCheckTime
        ))
    }

    func testVersionTwoRetainsBinaryKeyButNeverPromotesFlatLegacyValuesIntoHTTPGrant() throws {
        var fixture = legacyFixture
        let bytes = Array(UInt8(0)...UInt8(31))
        fixture["version"] = 2
        fixture["keyEncoding"] = "base64"
        fixture["secret"] = Data(bytes).base64EncodedString()
        fixture["httpArchive"] = ["endpoint": "https://example.invalid/untrusted"]
        let node = try storeFixture(fixture)

        let record = try CredentialsManager.staticGetPushCredentials(for: node)

        XCTAssertEqual(record.keyBytes, bytes)
        XCTAssertNil(record.httpArchive)
        XCTAssertEqual(record.service, "https://archive.example.invalid")
    }

    func testDiscoveredArchiveEndpointCanUseAnExplicitlyAdvertisedDifferentHTTPSHost() {
        let grant = archiveGrant(endpoint: "https://archive.example-cdn.invalid/custom/path?tenant=one")

        XCTAssertTrue(grant.isUsable(forAccount: "romeo@example.invalid", host: "example.invalid", now: grantCheckTime))
    }

    func testArchiveGrantRequiresHTTPSAbsoluteEndpointWithoutCredentialsOrFragment() {
        for endpoint in [
            "/iq/archive/id", "http://example.invalid/iq/archive/id", "https:///iq/archive/id",
            "https://user@example.invalid/iq/archive/id", "https://user:password@example.invalid/iq/archive/id",
            "https://example.invalid/iq/archive/id#fragment", "https://example.invalid/path\nother",
            "https://example.invalid/path\u{1}", "https://example.invalid/iq/archive/id?id=existing",
            "https://example.invalid/iq/archive/id?by=other", "https://example.invalid/iq/archive/id?%69d=existing"
        ] {
            XCTAssertFalse(archiveGrant(endpoint: endpoint).isUsable(
                forAccount: "romeo@example.invalid", host: "example.invalid", now: grantCheckTime
            ), endpoint)
        }
    }

    func testArchiveGrantRequiresUnexpiredMAMScopeAndOriginalDiscoveryDomain() {
        let variants = [
            archiveGrant(scopes: []), archiveGrant(scopes: ["vcard-temp"]),
            archiveGrant(expiresAt: grantCheckTime), archiveGrant(expiresAt: grantCheckTime.addingTimeInterval(-1)),
            archiveGrant(discoveryDomain: "other.invalid"), archiveGrant(token: ""),
            archiveGrant(token: "token\r\nInjected: value"), archiveGrant(token: "token\u{0}tail"),
            archiveGrant(token: "token\u{7f}tail")
        ]
        for grant in variants {
            XCTAssertFalse(grant.isUsable(forAccount: "romeo@example.invalid", host: "example.invalid", now: grantCheckTime))
        }
        let grant = archiveGrant(scopes: ["vcard-temp", "urn:xmpp:mam:2"])
        XCTAssertFalse(grant.isUsable(forAccount: "romeo@other.invalid", host: "example.invalid", now: grantCheckTime))
        XCTAssertFalse(grant.isUsable(forAccount: "romeo@example.invalid", host: "other.invalid", now: grantCheckTime))
        XCTAssertTrue(grant.isUsable(forAccount: "romeo@EXAMPLE.invalid/device", host: "example.invalid", now: grantCheckTime))
    }

    func testNewArchiveGrantExpirationUsesEffectiveServerExpiryAndEarlierJWTExpiryAsSchedulingHints() {
        let serverExpiry = grantCheckTime.addingTimeInterval(3600)
        let opaqueRecord = record(archiveGrant(expiresAt: serverExpiry))
        let earlier = grantCheckTime.addingTimeInterval(1200)
        let earlierJWTRecord = record(archiveGrant(token: jwt(expiration: earlier), expiresAt: serverExpiry))
        let laterJWTRecord = record(archiveGrant(token: jwt(expiration: serverExpiry.addingTimeInterval(3600)), expiresAt: serverExpiry))

        XCTAssertEqual(opaqueRecord.tokenExpiresAt, serverExpiry)
        XCTAssertEqual(earlierJWTRecord.tokenExpiresAt, earlier)
        XCTAssertEqual(laterJWTRecord.tokenExpiresAt, serverExpiry)
    }

    func testArchiveGrantGenerationCoversEveryDiscoveredCredentialFieldAndLocalRevision() {
        let original = record(archiveGrant())
        let variants = [
            record(archiveGrant(endpoint: "https://archive.example.invalid/alternate")),
            record(archiveGrant(token: "replacement-token")),
            record(archiveGrant(scopes: ["urn:xmpp:mam:2", "vcard-temp"])),
            record(archiveGrant(expiresAt: grantCheckTime.addingTimeInterval(7200))),
            record(archiveGrant(discoveryDomain: "other.invalid")),
            record(archiveGrant(), revision: "next-issuance"), record(nil)
        ]

        XCTAssertEqual(original.tokenGeneration, record(archiveGrant()).tokenGeneration)
        for variant in variants { XCTAssertNotEqual(original.tokenGeneration, variant.tokenGeneration) }
    }

    func testUnknownFutureRecordVersionCannotBeReadAsLegacyCredentials() throws {
        var fixture = legacyFixture
        fixture["version"] = 99
        let node = try storeFixture(fixture)

        XCTAssertThrowsError(try CredentialsManager.shared.getPushCredentials(for: node))
        XCTAssertThrowsError(try CredentialsManager.staticGetPushCredentials(for: node))
    }

    func testUnknownExplicitKeyEncodingCannotBeReadAsLegacyUTF8() throws {
        var fixture = legacyFixture
        fixture["version"] = 1
        fixture["keyEncoding"] = "unknown-future-encoding"
        let node = try storeFixture(fixture)

        XCTAssertThrowsError(try CredentialsManager.shared.getPushCredentials(for: node))
        XCTAssertThrowsError(try CredentialsManager.staticGetPushCredentials(for: node))
    }

    func testCurrentRecordCannotOmitItsExplicitKeyEncoding() throws {
        var fixture = legacyFixture
        fixture["version"] = 2
        let node = try storeFixture(fixture)
        XCTAssertThrowsError(try CredentialsManager.staticGetPushCredentials(for: node))
    }

    func testRawBinaryKeyRoundTripsWithExplicitEncoding() throws {
        let node = "push-raw-key-\(UUID().uuidString)"
        nodes.append(node)
        let bytes = Array(UInt8(0)...UInt8(31))
        try CredentialsManager.shared.storePushCredentials(
            node: node, jid: "romeo@example.invalid", host: "example.invalid",
            secret: Data(bytes).base64EncodedString(), service: "https://archive.example.invalid",
            jwt: "opaque", keyEncoding: .base64
        )
        let record = try CredentialsManager.staticGetPushCredentials(for: node)
        XCTAssertEqual(record.keyBytes, bytes)
        XCTAssertEqual(record.keyEncoding, .base64)
    }

    func testLegacyUTF8KeyAndStableGrantGeneration() throws {
        let node = try storeFixture(legacyFixture)
        let first = try CredentialsManager.staticGetPushCredentials(for: node)
        let second = try CredentialsManager.staticGetPushCredentials(for: node)
        XCTAssertEqual(first.keyBytes, Array(String(repeating: "a", count: 32).utf8))
        XCTAssertEqual(first.tokenGeneration, second.tokenGeneration)
        let changed = PushCredentialRecord(host: first.host, secret: first.secret, jid: first.jid,
                                           service: first.service, jwt: "replacement")
        XCTAssertNotEqual(changed.tokenGeneration, first.tokenGeneration)
    }

    func testJWTExpiryIsASchedulingHintAndOpaqueTokensRemainReadable() throws {
        let payload = Data("{\"exp\":2000000000}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let record = PushCredentialRecord(host: "example.invalid", secret: "fixture", jid: "r@example.invalid",
                                          service: "https://archive.example.invalid", jwt: "header.\(payload).signature")
        XCTAssertEqual(record.tokenExpiresAt, Date(timeIntervalSince1970: 2000000000))
        let node = try storeFixture(legacyFixture)
        XCTAssertNil(try CredentialsManager.staticGetPushCredentials(for: node).tokenExpiresAt)
    }

    func testMarkerInvalidatesOnlyTheRejectedNodeAndGeneration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PushTokenInvalidationStore(directory: directory)
        XCTAssertFalse(try store.contains(node: "node", generation: "old"))
        try store.invalidate(node: "node", generation: "old")
        XCTAssertTrue(try store.contains(node: "node", generation: "old"))
        XCTAssertFalse(try store.contains(node: "node", generation: "new"))
        XCTAssertFalse(try store.contains(node: "other-node", generation: "old"))
        try store.invalidate(node: "node", generation: "old")
        XCTAssertTrue(try store.contains(node: "node", generation: "old"))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains(where: { $0.contains("node") || $0.contains("old") }))
    }

    func testFailedDurableWriteIsReported() {
        let manager = FailingPushCredentialWriter()
        XCTAssertThrowsError(try manager.storePushCredentials(
            node: "fixture", jid: "romeo@example.invalid", host: "example.invalid",
            secret: "fixture", service: "", jwt: ""
        ))
    }

    func testSameJWTReissuedByAuthenticatedServerHasANewLocalGeneration() throws {
        let node = "push-local-grant-revision-\(UUID().uuidString)"
        nodes.append(node)
        try CredentialsManager.shared.storePushCredentials(node: node, jid: "r@example.invalid", host: "example.invalid",
            secret: String(repeating: "a", count: 32), service: "https://example.invalid", jwt: "same-token",
            grantRevision: "first-issuance")
        let old = try CredentialsManager.staticGetPushCredentials(for: node)
        try CredentialsManager.shared.storePushCredentials(node: node, jid: old.jid, host: old.host,
            secret: old.secret, service: old.service, jwt: old.jwt, grantRevision: "next-issuance")
        let new = try CredentialsManager.staticGetPushCredentials(for: node)
        XCTAssertNotEqual(old.tokenGeneration, new.tokenGeneration)
        XCTAssertEqual(new.tokenGeneration, try CredentialsManager.staticGetPushCredentials(for: node).tokenGeneration)
    }

    func testInvalidationRetentionPreservesCurrentRejectedGrantAndIsolatesNodes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PushTokenInvalidationStore(directory: directory)
        try store.invalidate(node: "node", generation: "current")
        for index in 0..<100 {
            try store.invalidate(node: "node", generation: "late-old-\(index)", preservingGeneration: "current")
        }
        XCTAssertTrue(try store.contains(node: "node", generation: "current"))
        XCTAssertLessThanOrEqual(try FileManager.default.subpathsOfDirectory(atPath: directory.path).count, 65)
        try store.invalidate(node: "other-node", generation: "current")
        try store.removeAll(node: "node")
        XCTAssertFalse(try store.contains(node: "node", generation: "current"))
        XCTAssertTrue(try store.contains(node: "other-node", generation: "current"))
    }

    func testAccountPushCleanupRevokesOnlyItsOwnedKeychainSnapshot() throws {
        let node = try storeFixture(legacyFixture)
        PushNotificationsManager.removeDefaultsForPush(target: node, jid: "other@example.invalid")
        XCTAssertNoThrow(try CredentialsManager.staticGetPushCredentials(for: node))
        PushNotificationsManager.removeDefaultsForPush(target: node, jid: "romeo@example.invalid")
        XCTAssertThrowsError(try CredentialsManager.staticGetPushCredentials(for: node))
    }

    private final class FailingPushCredentialWriter: CredentialsManager {
        override func writePushCredential(_ json: String, node: String) -> Bool { false }
    }

    private var grantCheckTime: Date { Date(timeIntervalSince1970: 2_000_000_000) }

    private func archiveGrant(endpoint: String = "https://archive.example.invalid/custom/by-id",
                              token: String = "opaque-server-token", scopes: [String] = ["urn:xmpp:mam:2"],
                              expiresAt: Date? = nil, discoveryDomain: String = "example.invalid") -> PushHTTPArchiveGrant {
        PushHTTPArchiveGrant(endpoint: endpoint, token: token, scopes: scopes,
                             expiresAt: expiresAt ?? grantCheckTime.addingTimeInterval(3600),
                             discoveryDomain: discoveryDomain)
    }

    private func record(_ grant: PushHTTPArchiveGrant?, revision: String = "issuance-one") -> PushCredentialRecord {
        PushCredentialRecord(host: "example.invalid", secret: String(repeating: "a", count: 32),
                             jid: "romeo@example.invalid", service: "", jwt: "",
                             grantRevision: revision, httpArchive: grant)
    }

    private func jwt(expiration: Date) -> String {
        let payload = Data("{\"exp\":\(expiration.timeIntervalSince1970)}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "header.\(payload).signature"
    }

    private var legacyFixture: [String: Any] {
        [
            "jid": "romeo@example.invalid",
            "host": "example.invalid",
            "secret": String(repeating: "a", count: 32),
            "service": "https://archive.example.invalid",
            "jwt": "opaque-jwt-fixture"
        ]
    }

    private func storeFixture(_ fixture: [String: Any]) throws -> String {
        let node = "push-migration-fixture-\(UUID().uuidString)"
        nodes.append(node)
        let data = try JSONSerialization.data(withJSONObject: fixture, options: .sortedKeys)
        let string = try XCTUnwrap(String(data: data, encoding: .utf8))
        let keychain = KeychainWrapper(
            serviceName: CredentialsManager.uniqueServiceName(),
            accessGroup: CredentialsManager.uniqueKeychainAccessGroup()
        )
        XCTAssertTrue(keychain.set(string, forKey: node, withAccessibility: .afterFirstUnlock))
        return node
    }
}
