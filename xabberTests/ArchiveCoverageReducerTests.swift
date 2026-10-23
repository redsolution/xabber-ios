import XCTest
@testable import xabber

final class ArchiveCoverageReducerTests: XCTestCase {
    func testCursorKeepsEveryNonemptyOpaqueIdentifierByteForByte() throws {
        XCTAssertNil(ArchiveCursor(rawValue: ""))
        for raw in ["0", "-1", "archive-7f3c1", "00042", "  uid / A  ", "é/消息"] {
            let value = try XCTUnwrap(ArchiveCursor(rawValue: raw))
            XCTAssertEqual(value.rawValue, raw)
            XCTAssertEqual(try JSONDecoder().decode(ArchiveCursor.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertNotEqual(ArchiveCursor(rawValue: "42"), ArchiveCursor(rawValue: "042"))
        XCTAssertNotEqual(ArchiveCursor(rawValue: "uid"), ArchiveCursor(rawValue: " uid "))
        XCTAssertNotEqual(ArchiveCursor(rawValue: "é"), ArchiveCursor(rawValue: "e\u{301}"))
    }

    func testSessionMAMProofMergesWithinGenerationButChangesAfterReconnect() {
        let first = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 7, queryID: "a")
        let second = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 7, queryID: "b")
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.fingerprint, ArchiveFreshnessToken.sessionMAM(connectionGeneration: 8, queryID: "a").fingerprint)
    }

    func testOpaqueLedgerDefinesMembershipAndOrderWithoutInventingIntermediateIDs() throws {
        let value = try segment(["z-last-lexically", "7", "2", "a"])
        XCTAssertEqual(value.oldest.rawValue, "z-last-lexically")
        XCTAssertEqual(value.newest.rawValue, "a")
        XCTAssertEqual(value.index(of: cursor("2")), 2)
        XCTAssertTrue(value.isBefore(cursor("7"), cursor("2")))
        XCTAssertFalse(value.isBefore(cursor("2"), cursor("7")))
        XCTAssertFalse(value.contains(cursor("5")))
        XCTAssertTrue(value.containsSegment(try segment(["7", "2"])))
        XCTAssertFalse(value.containsSegment(try segment(["7", "a"])))
        XCTAssertFalse(value.containsSegment(try segment(["2", "7"])))
    }

    func testOlderAndNewerPagesRequireExplicitAdjacencyForDisjointLedgers() throws {
        let current = try segment(["b", "3"])
        let older = try segment(["z", "99"])
        XCTAssertEqual(ArchiveCoverageReducer.adding(older, to: [current], adjacency: nil).count, 2)
        let joined = ArchiveCoverageReducer.adding(older, to: [current], adjacency: .older(before: cursor("b")))
        XCTAssertEqual(joined.map(\.orderedArchiveIDs), [["z", "99", "b", "3"].map(cursor)])
        let newer = try segment(["0", "A"])
        let expanded = ArchiveCoverageReducer.adding(newer, to: joined, adjacency: .newer(after: cursor("3")))
        XCTAssertEqual(expanded.first?.orderedArchiveIDs, ["z", "99", "b", "3", "0", "A"].map(cursor))
    }

    func testConsistentOverlappingPagesMergeAndContradictoryOrderDoesNot() throws {
        let first = try segment(["z", "7", "a"])
        let second = try segment(["7", "a", "02"])
        XCTAssertEqual(ArchiveCoverageReducer.normalized([first, second]).first?.orderedArchiveIDs,
                       ["z", "7", "a", "02"].map(cursor))
        XCTAssertEqual(ArchiveCoverageReducer.normalized([first, try segment(["7", "z"])]).count, 2)
    }

    func testCompletedGapJoinsOnlyItsExactKnownBoundaryLedgers() throws {
        let older = try segment(["z", "99"])
        let newer = try segment(["a", "3"])
        let middle = try segment(["01", "B"])
        let joined = ArchiveCoverageReducer.adding(middle, to: [older, newer],
            adjacency: .gap(olderBoundary: cursor("99"), newerBoundary: cursor("a")))
        XCTAssertEqual(joined.first?.orderedArchiveIDs, ["z", "99", "01", "B", "a", "3"].map(cursor))
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(ArchiveCoverageReducer.adding(middle, to: [older, newer],
            adjacency: .gap(olderBoundary: cursor("missing"), newerBoundary: cursor("a"))).count, 3)
    }

    func testDifferentProofsAndUnorderedDisjointPagesNeverImplyCoverageOrGaps() throws {
        let first = try segment(["z", "a"])
        let otherProof = try segment(["a", "b"], fingerprint: "another")
        XCTAssertEqual(ArchiveCoverageReducer.normalized([first, otherProof]).count, 2)
        XCTAssertTrue(ArchiveCoverageReducer.gaps(in: [first, try segment(["0", "1"])]).isEmpty)
        XCTAssertFalse(ArchiveCoverageReducer.containsVerifiedWindow(oldest: cursor("a"), newest: cursor("b"),
            fingerprint: "session", segments: [first, otherProof]))
    }

    func testDuplicateLedgerAndMismatchedEndpointsAreRejected() {
        XCTAssertNil(ArchiveCoverageSegment(orderedArchiveIDs: [cursor("a"), cursor("a")],
            reachesArchiveStart: false, reachesLiveEdge: false, fingerprint: "session", isVerified: true))
        XCTAssertNil(ArchiveCoverageSegment(oldest: cursor("a"), newest: cursor("b"),
            reachesArchiveStart: false, reachesLiveEdge: false, fingerprint: "session", isVerified: true,
            orderedArchiveIDs: [cursor("b"), cursor("a")]))
    }

    func testLegacyEndpointOnlyJSONRemainsProvisionalAndDoesNotGrantMembership() throws {
        let json = Data("""
        {"oldest":"100","newest":"200","reachesArchiveStart":true,"reachesLiveEdge":true,"fingerprint":"session","isVerified":true}
        """.utf8)
        let value = try JSONDecoder().decode(ArchiveCoverageSegment.self, from: json)
        XCTAssertFalse(value.isVerified)
        XCTAssertTrue(value.orderedArchiveIDs.isEmpty)
        XCTAssertFalse(value.contains(cursor("150")))
        let restored = try JSONDecoder().decode(ArchiveCoverageSegment.self, from: JSONEncoder().encode(value))
        XCTAssertFalse(restored.isVerified)
        XCTAssertEqual(restored.oldest.rawValue, "100")
        XCTAssertEqual(restored.newest.rawValue, "200")
    }


    func testCachedOrderingFingerprintFramesOpaqueIDsAndDetectsReorderedOrSplitValues() throws {
        XCTAssertNotEqual(try segment(["ab", "c"]).orderedArchiveFingerprint,
                          try segment(["a", "bc"]).orderedArchiveFingerprint)
        XCTAssertNotEqual(try segment(["z", "2"]).orderedArchiveFingerprint,
                          try segment(["2", "z"]).orderedArchiveFingerprint)
        let value = try segment(["z", "2", "a"])
        let decoded = try JSONDecoder().decode(ArchiveCoverageSegment.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(value.orderedArchiveFingerprint, decoded.orderedArchiveFingerprint)
        XCTAssertEqual(value, decoded)
    }

    private func cursor(_ value: String) -> ArchiveCursor { ArchiveCursor(rawValue: value)! }

    private func segment(_ values: [String], fingerprint: String = "session") throws -> ArchiveCoverageSegment {
        try XCTUnwrap(ArchiveCoverageSegment(orderedArchiveIDs: values.map(cursor), reachesArchiveStart: false,
            reachesLiveEdge: false, fingerprint: fingerprint, isVerified: true))
    }
}
