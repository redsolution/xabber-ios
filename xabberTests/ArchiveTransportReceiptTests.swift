import XCTest
@testable import xabber

final class ArchiveTransportReceiptTests: XCTestCase {
    func testTransportRegistersSynchronousRawFinalRouteBeforeMAMSendAndCleansItUp() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/xmpp/messages/message_archive/engine/MessageArchiveTransportAdapter.swift"
            ),
            encoding: .utf8
        )
        let transactionStart = try XCTUnwrap(
            source.range(of: "func start(on stream: XMPPStream)")
        )
        let finalHandler = try XCTUnwrap(
            source.range(
                of: "private func handleFinal(",
                range: transactionStart.upperBound..<source.endIndex
            )
        )
        let startBody = String(
            source[transactionStart.lowerBound..<finalHandler.lowerBound]
        )

        let registration = try XCTUnwrap(
            startBody.range(
                of: "MessageArchiveEndPageDispatcher.register("
            )
        )
        let send = try XCTUnwrap(
            startBody.range(of: "account.mam.requestArchive(")
        )
        XCTAssertLessThan(registration.lowerBound, send.lowerBound)
        XCTAssertTrue(startBody.contains("delivery: .synchronous"))
        XCTAssertTrue(source.contains("MessageArchiveEndPageDispatcher.unregister(token)"))
    }

    func testContinuationBoxRetainsTransactionUntilTerminalResume() {
        final class LifetimeProbe {}

        let continuationBox = ArchiveTransportContinuationBox()
        var probe: LifetimeProbe? = LifetimeProbe()
        weak var weakProbe = probe

        continuationBox.retainUntilTerminal(probe!)
        probe = nil

        XCTAssertNotNil(weakProbe)

        continuationBox.resume(throwing: ArchiveTransportError.timeout)

        XCTAssertNil(weakProbe)
    }

    func testPersistenceAccountingAcceptsAlreadyMaterializedDuplicateRows() {
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.received = 3
        summary.skipped = 3

        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: summary,
            deliveredArchiveIDs: ["10", "20", "30"],
            explicitlyConsumedArchiveIDs: [],
            materializedMessages: [
                ArchiveMaterializedMessageIdentity(archiveID: "10", primaryID: "p10"),
                ArchiveMaterializedMessageIdentity(archiveID: "20", primaryID: "p20"),
                ArchiveMaterializedMessageIdentity(archiveID: "30", primaryID: "p30"),
            ]
        )

        XCTAssertEqual(accounting.persistedResultCount, 3)
        XCTAssertEqual(accounting.failedPersistenceCount, 0)
    }

    func testPersistenceAccountingStillReportsActualStorageFailure() {
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.received = 3
        summary.savedNew = 2
        summary.failed = 1

        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: summary,
            deliveredArchiveIDs: ["10", "20", "30"],
            explicitlyConsumedArchiveIDs: [],
            materializedMessages: [
                ArchiveMaterializedMessageIdentity(archiveID: "10", primaryID: "p10"),
                ArchiveMaterializedMessageIdentity(archiveID: "20", primaryID: "p20"),
            ]
        )

        XCTAssertEqual(accounting.persistedResultCount, 2)
        XCTAssertEqual(accounting.failedPersistenceCount, 1)
    }

    func testPersistenceAccountingAcceptsDurableIdentityAfterCurrentSaveFailure() {
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.received = 1
        summary.failed = 1

        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: summary,
            deliveredArchiveIDs: ["10"],
            explicitlyConsumedArchiveIDs: [],
            materializedMessages: [
                ArchiveMaterializedMessageIdentity(archiveID: "10", primaryID: "p10"),
            ]
        )

        XCTAssertEqual(accounting.persistedResultCount, 1)
        XCTAssertEqual(accounting.messagePrimaryIDs, ["p10"])
        XCTAssertEqual(accounting.failedPersistenceCount, 0)
    }

    func testPersistenceAccountingCountsOnlyConsumedResultsWithoutDurableRows() {
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.received = 3

        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: summary,
            deliveredArchiveIDs: ["10", "20", "30"],
            explicitlyConsumedArchiveIDs: ["10", "20"],
            materializedMessages: [
                ArchiveMaterializedMessageIdentity(archiveID: "10", primaryID: "p10"),
                ArchiveMaterializedMessageIdentity(archiveID: "30", primaryID: "p30"),
            ]
        )

        XCTAssertEqual(accounting.persistedResultCount, 2)
        XCTAssertEqual(accounting.intentionallyConsumedResultCount, 1)
        XCTAssertEqual(accounting.messagePrimaryIDs, ["p10", "p30"])
        XCTAssertEqual(accounting.failedPersistenceCount, 0)
    }

    func testPersistenceAccountingTreatsQueryScopedSkippedArchiveIDsAsConsumed() {
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.received = 2
        summary.skipped = 2
        summary.recordSkippedArchiveId("10")
        summary.recordSkippedArchiveId("20")

        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: summary,
            deliveredArchiveIDs: ["10", "20"],
            explicitlyConsumedArchiveIDs: summary.skippedArchiveIds,
            materializedMessages: []
        )

        XCTAssertEqual(accounting.persistedResultCount, 0)
        XCTAssertEqual(accounting.intentionallyConsumedResultCount, 2)
        XCTAssertEqual(accounting.messagePrimaryIDs, [])
        XCTAssertEqual(accounting.failedPersistenceCount, 0)
    }

    func testCanonicalGroupRegularShadowRowsAreConsumedWithoutEnteringGroupTimeline() {
        let group = ArchiveConversationKey(
            owner: "romeo@example.org",
            jid: "stage@example.org",
            conversationType: .group
        )
        var summary = MessageManager.ArchivePersistenceSummary()
        summary.received = 2
        summary.updatedExisting = 2
        summary.recordPersistedArchiveId(
            "10",
            owner: group.owner,
            jid: group.jid,
            conversationType: .regular
        )
        summary.recordPersistedArchiveId(
            "20",
            owner: group.owner,
            jid: group.jid,
            conversationType: .regular
        )

        let consumed = ArchiveTransportShadowConsumptionPolicy.archiveIDs(
            summary: summary,
            conversation: group
        )
        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: summary,
            deliveredArchiveIDs: ["10", "20"],
            explicitlyConsumedArchiveIDs: consumed,
            materializedMessages: []
        )

        XCTAssertEqual(consumed, ["10", "20"])
        XCTAssertEqual(accounting.persistedResultCount, 0)
        XCTAssertEqual(accounting.intentionallyConsumedResultCount, 2)
        XCTAssertEqual(accounting.failedPersistenceCount, 0)
    }

    func testPersistenceAccountingRejectsMissingUnconsumedResult() {
        let accounting = ArchiveTransportPersistenceAccounting.make(
            summary: MessageManager.ArchivePersistenceSummary(),
            deliveredArchiveIDs: ["10", "20"],
            explicitlyConsumedArchiveIDs: ["10"],
            materializedMessages: [
                ArchiveMaterializedMessageIdentity(archiveID: "10", primaryID: "p10"),
            ]
        )

        XCTAssertEqual(accounting.persistedResultCount, 1)
        XCTAssertEqual(accounting.intentionallyConsumedResultCount, 0)
        XCTAssertEqual(accounting.failedPersistenceCount, 1)
    }

    func testPersistenceRoutingOverridesConsumptionAcrossDelegates() {
        var consumedFirst = MessageArchiveManager.DeferredArchiveTransportProof()
        consumedFirst.record(resultId: "10")
        consumedFirst.recordIntentionalConsumption(resultId: "10")
        consumedFirst.recordPersistenceRouting(resultId: "10")

        XCTAssertEqual(consumedFirst.intentionallyConsumedResultCount, 0)

        var persistedFirst = MessageArchiveManager.DeferredArchiveTransportProof()
        persistedFirst.record(resultId: "10")
        persistedFirst.recordPersistenceRouting(resultId: "10")
        persistedFirst.recordIntentionalConsumption(resultId: "10")

        XCTAssertEqual(persistedFirst.intentionallyConsumedResultCount, 0)
        XCTAssertTrue(persistedFirst.hasConsistentControlDisposition)
    }

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
            guard case let .incompletePersistenceAccounting(
                delivered,
                persisted,
                consumed,
                resultArchiveIDs,
                messagePrimaryIDs
            ) = $0 as? ArchiveTransportValidationError else {
                return XCTFail("Expected accounting diagnostics, got \($0)")
            }
            XCTAssertEqual(delivered, 1)
            XCTAssertEqual(persisted, 0)
            XCTAssertEqual(consumed, 0)
            XCTAssertEqual(resultArchiveIDs, 1)
            XCTAssertEqual(messagePrimaryIDs, 1)
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

    func testIncompleteGapPageJoinsTheKnownNewerSegmentForNextCursorAdvance() throws {
        let older = try XCTUnwrap(ArchiveCursor(rawValue: "100"))
        let newer = try XCTUnwrap(ArchiveCursor(rawValue: "300"))
        let request = ArchiveTransportRequest(
            queryID: "q-gap-page",
            conversation: conversation,
            locator: .gap(olderBoundary: older, newerBoundary: newer),
            connectionGeneration: 11,
            pageSize: ArchivePageSizing.history,
            contextBefore: ArchivePageSizing.history,
            contextAfter: ArchivePageSizing.history,
            proofFingerprint: "sync-gap",
            isUnfiltered: true,
            producesContinuousCoverage: true
        )
        let receipt = ArchiveTransportReceipt(
            queryID: request.queryID,
            connectionGeneration: request.connectionGeneration,
            resultArchiveIDs: ["299", "250", "201"],
            messagePrimaryIDs: ["p299", "p250", "p201"],
            first: "299",
            last: "201",
            complete: false,
            cheapPageCount: 3,
            deliveredResultCount: 3,
            persistedResultCount: 3,
            intentionallyConsumedResultCount: 0,
            failedPersistenceCount: 0,
            finalReceived: true
        )

        let page = try ArchiveTransportReceiptValidator.validate(receipt, for: request)

        XCTAssertEqual(page.segment?.oldest, ArchiveCursor(rawValue: "201"))
        XCTAssertEqual(page.adjacency, .older(before: newer))
        XCTAssertFalse(page.requestComplete)
    }
}
