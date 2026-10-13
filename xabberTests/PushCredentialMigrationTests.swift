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

    func testLegacyCredentialRecordPreservesOpaqueSecretAndHTTPGrant() throws {
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
        XCTAssertEqual(try CredentialsManager.staticGetPushCredentials(for: node).secret, record.secret)
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
