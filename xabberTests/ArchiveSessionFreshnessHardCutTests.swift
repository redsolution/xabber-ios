import XCTest
@testable import xabber

final class ArchiveSessionFreshnessHardCutTests: XCTestCase {
    func testSessionMAMIsTheOnlyRuntimeArchiveFreshnessToken() throws {
        let source = try read("xabber/xmpp/messages/message_archive/engine/ArchiveDomain.swift")

        XCTAssertTrue(source.contains("case sessionMAM(connectionGeneration: UInt64, queryID: String)"))
        XCTAssertFalse(source.contains("case xepSync"))
        XCTAssertFalse(source.contains(".xepSync("))
    }

    func testCoverageRepositoryCannotActivateProvisionalCoverageFromSync() throws {
        let protocolSource = try read(
            "xabber/xmpp/messages/message_archive/engine/ArchiveTransportTypes.swift"
        )
        let repositorySource = try read(
            "xabber/xmpp/messages/message_archive/engine/RealmArchiveCoverageRepository.swift"
        )

        XCTAssertFalse(protocolSource.contains("verifyProvisionalCoverage"))
        XCTAssertFalse(repositorySource.contains("verifyProvisionalCoverage"))
        XCTAssertFalse(repositorySource.contains("ArchiveSyncFingerprint("))
        XCTAssertFalse(repositorySource.contains("XEPSYNC"))
        let domainSource = try read(
            "xabber/xmpp/messages/message_archive/engine/ArchiveDomain.swift"
        )
        XCTAssertFalse(domainSource.contains("static func verifying("))
    }

    func testReconnectChangesProofWhileQueriesInOneSessionShareFingerprint() {
        let firstPage = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: 41,
            queryID: "first"
        )
        let secondPage = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: 41,
            queryID: "second"
        )
        let reconnected = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: 42,
            queryID: "first-after-reconnect"
        )

        XCTAssertEqual(firstPage.fingerprint, secondPage.fingerprint)
        XCTAssertNotEqual(firstPage.fingerprint, reconnected.fingerprint)
        XCTAssertEqual(firstPage.fingerprint, "session:41")
    }

    func testSchemaNineteenMigrationCompatibilityFieldsRemainDurableOnly() throws {
        let storageSource = try read(
            "xabber/xmpp/messages/message_archive/engine/ArchiveCoverageStorage.swift"
        )
        let migrationSource = try read("xabber/migrations/RealmMigrations.swift")

        XCTAssertTrue(storageSource.contains("lastObservedXEPSYNCFingerprint"))
        XCTAssertTrue(storageSource.contains("provisionalSegmentsJSON("))
        XCTAssertTrue(migrationSource.contains("ArchiveSyncFingerprint("))
        XCTAssertTrue(migrationSource.contains("lastObservedXEPSYNCFingerprint"))
    }

    private func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: sourceRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
