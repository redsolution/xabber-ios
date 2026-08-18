import XCTest
@testable import xabber

final class ArchiveTransportReceiptTests: XCTestCase {
    private let conversation = ArchiveConversationKey(
        owner: "romeo@example.org",
        jid: "juliet@example.org",
        conversationType: .regular
    )

    func testFlipPageReceiptNormalizesToChronologicalCoverage() throws {
        let boundary = try XCTUnwrap(ArchiveCursor(rawValue: "300"))
        let request = ArchiveTransportRequest(
            queryID: "q1",
            conversation: conversation,
            locator: .older(before: boundary),
            connectionGeneration: 4,
            pageSize: 100,
            contextBefore: 0,
            contextAfter: 0,
            proofFingerprint: "sync-1",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let receipt = ArchiveTransportReceipt(
            queryID: "q1",
            connectionGeneration: 4,
            resultArchiveIDs: ["299", "250", "200"],
            messagePrimaryIDs: ["p299", "p250", "p200"],
            first: "299",
            last: "200",
            complete: false,
            cheapPageCount: 3,
            deliveredResultCount: 3,
            persistedResultCount: 3,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        )

        let validated = try ArchiveTransportReceiptValidator.validate(
            receipt,
            for: request
        )

        XCTAssertEqual(validated.segment?.oldest.rawValue, "200")
        XCTAssertEqual(validated.segment?.newest.rawValue, "299")
        XCTAssertEqual(validated.adjacency, .older(before: boundary))
        XCTAssertEqual(validated.chronologicalArchiveIDs, ["200", "250", "299"])
    }

    func testNewestUnfilteredZeroPageIsAuthoritativeWithoutCounter() throws {
        let request = ArchiveTransportRequest(
            queryID: "q-empty",
            conversation: conversation,
            locator: .latest,
            connectionGeneration: 9,
            pageSize: 80,
            contextBefore: 0,
            contextAfter: 0,
            proofFingerprint: "sync-2",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let receipt = ArchiveTransportReceipt(
            queryID: "q-empty",
            connectionGeneration: 9,
            resultArchiveIDs: [],
            messagePrimaryIDs: [],
            first: "",
            last: "",
            complete: true,
            cheapPageCount: 0,
            deliveredResultCount: 0,
            persistedResultCount: 0,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        )

        let validated = try ArchiveTransportReceiptValidator.validate(
            receipt,
            for: request
        )

        XCTAssertTrue(validated.isAuthoritativeEmpty)
        XCTAssertNil(validated.segment)
    }

    func testCursorOrFilteredZeroPageIsNeverAuthoritativeEmpty() throws {
        let boundary = try XCTUnwrap(ArchiveCursor(rawValue: "100"))
        let request = ArchiveTransportRequest(
            queryID: "q-cursor-empty",
            conversation: conversation,
            locator: .older(before: boundary),
            connectionGeneration: 2,
            pageSize: 100,
            contextBefore: 0,
            contextAfter: 0,
            proofFingerprint: "sync-3",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let receipt = ArchiveTransportReceipt(
            queryID: request.queryID,
            connectionGeneration: request.connectionGeneration,
            resultArchiveIDs: [],
            messagePrimaryIDs: [],
            first: "",
            last: "",
            complete: true,
            cheapPageCount: 0,
            deliveredResultCount: 0,
            persistedResultCount: 0,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        )

        let validated = try ArchiveTransportReceiptValidator.validate(
            receipt,
            for: request
        )
        XCTAssertFalse(validated.isAuthoritativeEmpty)
    }

    func testRejectsResultBeforeFinalPartialPersistenceAndStaleIdentity() throws {
        let request = ArchiveTransportRequest(
            queryID: "expected",
            conversation: conversation,
            locator: .latest,
            connectionGeneration: 7,
            pageSize: 80,
            contextBefore: 0,
            contextAfter: 0,
            proofFingerprint: "sync-4",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )

        var receipt = ArchiveTransportReceipt(
            queryID: "expected",
            connectionGeneration: 7,
            resultArchiveIDs: ["10"],
            messagePrimaryIDs: ["p10"],
            first: "10",
            last: "10",
            complete: true,
            cheapPageCount: 1,
            deliveredResultCount: 1,
            persistedResultCount: 1,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: false
        )
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(receipt, for: request)) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .missingFinal)
        }

        receipt.finalReceived = true
        receipt.persistedResultCount = 0
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(receipt, for: request)) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .incompletePersistenceAccounting)
        }

        receipt.persistedResultCount = 1
        receipt.queryID = "stale"
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(receipt, for: request)) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .staleQuery)
        }
    }

    func testRejectsRepeatedOrWrongDirectionCursorAndMalformedIDs() throws {
        let boundary = try XCTUnwrap(ArchiveCursor(rawValue: "200"))
        let request = ArchiveTransportRequest(
            queryID: "q-direction",
            conversation: conversation,
            locator: .older(before: boundary),
            connectionGeneration: 1,
            pageSize: 100,
            contextBefore: 0,
            contextAfter: 0,
            proofFingerprint: "sync-5",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        var receipt = ArchiveTransportReceipt(
            queryID: request.queryID,
            connectionGeneration: request.connectionGeneration,
            resultArchiveIDs: ["200"],
            messagePrimaryIDs: ["p200"],
            first: "200",
            last: "200",
            complete: false,
            cheapPageCount: 1,
            deliveredResultCount: 1,
            persistedResultCount: 1,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        )
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(receipt, for: request)) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .nonAdvancingCursor)
        }

        receipt.resultArchiveIDs = ["not-numeric"]
        receipt.first = "not-numeric"
        receipt.last = "not-numeric"
        XCTAssertThrowsError(try ArchiveTransportReceiptValidator.validate(receipt, for: request)) {
            XCTAssertEqual($0 as? ArchiveTransportValidationError, .malformedArchiveID)
        }
    }

    func testSearchAndExactAnchorRowsNeverProduceTimelineCoverage() throws {
        let anchor = try XCTUnwrap(ArchiveCursor(rawValue: "42"))
        let request = ArchiveTransportRequest(
            queryID: "q-search",
            conversation: conversation,
            locator: .archiveID(anchor),
            connectionGeneration: 1,
            pageSize: 50,
            contextBefore: 30,
            contextAfter: 30,
            proofFingerprint: "sync-6",
            isUnfiltered: false,
            producesContinuousCoverage: false
        )
        let receipt = ArchiveTransportReceipt(
            queryID: request.queryID,
            connectionGeneration: request.connectionGeneration,
            resultArchiveIDs: ["42"],
            messagePrimaryIDs: ["p42"],
            first: "42",
            last: "42",
            complete: true,
            cheapPageCount: 1,
            deliveredResultCount: 1,
            persistedResultCount: 1,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        )

        let validated = try ArchiveTransportReceiptValidator.validate(receipt, for: request)
        XCTAssertNil(validated.segment)
        XCTAssertFalse(validated.isAuthoritativeEmpty)
    }
}
