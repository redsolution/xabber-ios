import XCTest
@testable import xabber

final class ArchiveCoverageReducerTests: XCTestCase {
    func testCursorAcceptsOnlyPositiveUInt64AndPreservesRawValue() {
        XCTAssertNil(ArchiveCursor(rawValue: ""))
        XCTAssertNil(ArchiveCursor(rawValue: "0"))
        XCTAssertNil(ArchiveCursor(rawValue: "-1"))
        XCTAssertNil(ArchiveCursor(rawValue: "message-id"))
        XCTAssertNotNil(ArchiveCursor(rawValue: String(UInt64.max)))

        let cursor = ArchiveCursor(rawValue: " 00042 ")
        XCTAssertEqual(cursor?.rawValue, "00042")
        XCTAssertEqual(cursor?.numericValue, 42)
    }

    func testSessionMAMProofMergesWithinGenerationButChangesAfterReconnect() {
        let firstPage = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: 7,
            queryID: "page-a"
        )
        let secondPage = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: 7,
            queryID: "page-b"
        )
        let reconnected = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: 8,
            queryID: "page-a"
        )

        XCTAssertEqual(firstPage.fingerprint, secondPage.fingerprint)
        XCTAssertNotEqual(firstPage.fingerprint, reconnected.fingerprint)
        XCTAssertNotEqual(firstPage, secondPage)
    }

    func testOlderPageMergesOnlyThroughExplicitExistingBoundary() throws {
        let current = try segment("100", "200", fingerprint: "sync-a", verified: true)
        let older = try segment("20", "99", fingerprint: "sync-a", verified: true)

        let withoutAdjacency = ArchiveCoverageReducer.adding(
            older,
            to: [current],
            adjacency: nil
        )
        XCTAssertEqual(withoutAdjacency.count, 2)

        let withAdjacency = ArchiveCoverageReducer.adding(
            older,
            to: [current],
            adjacency: .older(before: try cursor("100"))
        )
        XCTAssertEqual(withAdjacency, [try segment("20", "200", fingerprint: "sync-a", verified: true)])
    }

    func testSegmentsWithDifferentProofNeverMerge() throws {
        let older = try segment("1", "49", fingerprint: "sync-a", verified: true)
        let newer = try segment("50", "100", fingerprint: "sync-b", verified: true)

        let result = ArchiveCoverageReducer.adding(
            older,
            to: [newer],
            adjacency: .older(before: try cursor("50"))
        )

        XCTAssertEqual(result, [older, newer])
    }

    func testCompletedBoundedGapProofBridgesBothVerifiedSegments() throws {
        let older = try segment("1", "10", fingerprint: "sync-a", verified: true)
        let newer = try segment("30", "40", fingerprint: "sync-a", verified: true)
        let materializedGap = try segment("11", "29", fingerprint: "sync-a", verified: true)

        let result = ArchiveCoverageReducer.adding(
            materializedGap,
            to: [older, newer],
            adjacency: .gap(
                olderBoundary: try cursor("10"),
                newerBoundary: try cursor("30")
            )
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].oldest, try cursor("1"))
        XCTAssertEqual(result[0].newest, try cursor("40"))
    }

    func testBoundedGapProofDoesNotBridgeMissingOrMismatchedBoundary() throws {
        let older = try segment("1", "9", fingerprint: "sync-a", verified: true)
        let newer = try segment("31", "40", fingerprint: "sync-a", verified: true)
        let materializedGap = try segment("11", "29", fingerprint: "sync-a", verified: true)

        let result = ArchiveCoverageReducer.adding(
            materializedGap,
            to: [older, newer],
            adjacency: .gap(
                olderBoundary: try cursor("10"),
                newerBoundary: try cursor("30")
            )
        )

        XCTAssertEqual(result.count, 3)
    }

    func testGapsAreDerivedAndNotStoredSeparately() throws {
        let segments = [
            try segment("1", "10", fingerprint: "sync", verified: true),
            try segment("30", "40", fingerprint: "sync", verified: true),
            try segment("80", "90", fingerprint: "sync", verified: false),
        ]

        XCTAssertEqual(
            ArchiveCoverageReducer.gaps(in: segments),
            [
                ArchiveCoverageGap(olderBoundary: try cursor("10"), newerBoundary: try cursor("30")),
                ArchiveCoverageGap(olderBoundary: try cursor("40"), newerBoundary: try cursor("80")),
            ]
        )
    }

    func testAdmissionRequiresOneVerifiedSegmentAndCurrentFingerprint() throws {
        let verified = try segment("100", "200", fingerprint: "sync-a", verified: true)
        let provisional = try segment("300", "400", fingerprint: "sync-a", verified: false)

        XCTAssertTrue(
            ArchiveCoverageReducer.containsVerifiedWindow(
                oldest: try cursor("120"),
                newest: try cursor("180"),
                fingerprint: "sync-a",
                segments: [verified, provisional]
            )
        )
        XCTAssertFalse(
            ArchiveCoverageReducer.containsVerifiedWindow(
                oldest: try cursor("180"),
                newest: try cursor("320"),
                fingerprint: "sync-a",
                segments: [verified, provisional]
            )
        )
        XCTAssertFalse(
            ArchiveCoverageReducer.containsVerifiedWindow(
                oldest: try cursor("120"),
                newest: try cursor("180"),
                fingerprint: "sync-b",
                segments: [verified]
            )
        )
    }

    func testInvalidOrReversedSegmentIsRejected() {
        XCTAssertNil(ArchiveCoverageSegment(
            oldest: ArchiveCursor(rawValue: "200")!,
            newest: ArchiveCursor(rawValue: "100")!,
            reachesArchiveStart: false,
            reachesLiveEdge: false,
            fingerprint: "sync",
            isVerified: true
        ))
    }

    private func cursor(_ value: String) throws -> ArchiveCursor {
        try XCTUnwrap(ArchiveCursor(rawValue: value))
    }

    private func segment(
        _ oldest: String,
        _ newest: String,
        fingerprint: String,
        verified: Bool
    ) throws -> ArchiveCoverageSegment {
        try XCTUnwrap(ArchiveCoverageSegment(
            oldest: cursor(oldest),
            newest: cursor(newest),
            reachesArchiveStart: false,
            reachesLiveEdge: false,
            fingerprint: fingerprint,
            isVerified: verified
        ))
    }
}
