import XCTest
@testable import xabber

final class ChatAnchorTransactionTests: XCTestCase {
    func testSupersededTransactionRejectsEveryLateAsyncBoundary() {
        let gate = ChatAnchorTransactionGate()
        let transactionA = ChatAnchorTransactionToken(rawValue: "transaction-a")
        let transactionB = ChatAnchorTransactionToken(rawValue: "transaction-b")

        XCTAssertNil(gate.begin(token: transactionA, requestIdentity: "message-a"))
        XCTAssertTrue(gate.acquire(.query("query-a"), token: transactionA))
        XCTAssertEqual(gate.begin(token: transactionB, requestIdentity: "message-b"), transactionA)
        XCTAssertTrue(gate.acquire(.query("query-b"), token: transactionB))

        let lateBoundaries: [ChatAnchorTransactionBoundary] = [
            .remoteFinal(queryId: "query-a"),
            .remoteFailure(queryId: "query-a"),
            .persistence(queryId: "query-a"),
            .mapping,
            .apply,
            .scroll
        ]
        for boundary in lateBoundaries {
            XCTAssertEqual(gate.accept(boundary, token: transactionA), .stale, "late boundary: \(boundary)")
        }

        XCTAssertEqual(gate.accept(.persistence(queryId: "query-b"), token: transactionB), .accepted)
        XCTAssertEqual(gate.accept(.mapping, token: transactionB), .accepted)
        XCTAssertEqual(gate.snapshot.activeToken, transactionB)
        XCTAssertEqual(gate.snapshot.lastTerminalOutcome, .failed(.superseded))
    }

    func testDuplicateFinalAndPositionHooksAreAcceptedOnlyOnceAndInOrder() {
        let gate = ChatAnchorTransactionGate()
        let token = ChatAnchorTransactionToken(rawValue: "transaction")
        _ = gate.begin(token: token, requestIdentity: "message")
        XCTAssertTrue(gate.acquire(.query("query"), token: token))

        XCTAssertEqual(gate.accept(.remoteFinal(queryId: "query"), token: token), .accepted)
        XCTAssertEqual(gate.accept(.remoteFinal(queryId: "query"), token: token), .duplicate)
        XCTAssertTrue(gate.markPositioningStarted(token: token))
        XCTAssertFalse(gate.markPositioningStarted(token: token))
        XCTAssertTrue(gate.finish(token: token))
        XCTAssertFalse(gate.finish(token: token))
        XCTAssertFalse(gate.fail(token: token, failure: .targetMissing))
        XCTAssertEqual(gate.snapshot.lastTerminalOutcome, .positioned)
    }

    func testLifecycleAndTransportCancellationReleaseOnlyOwnedState() {
        let failures: [ChatAnchorTransactionFailure] = [.timeout, .iqError, .disconnected, .disappeared]

        for (index, failure) in failures.enumerated() {
            let gate = ChatAnchorTransactionGate()
            let token = ChatAnchorTransactionToken(rawValue: "transaction-\(index)")
            _ = gate.begin(token: token, requestIdentity: "message-\(index)")
            XCTAssertTrue(gate.acquire(.query("query-\(index)"), token: token))
            XCTAssertTrue(gate.acquire(.loader, token: token))
            XCTAssertTrue(gate.acquire(.scrollLock, token: token))

            XCTAssertTrue(gate.cancel(token: token, failure: failure))
            XCTAssertNil(gate.snapshot.activeToken)
            XCTAssertTrue(gate.snapshot.queryIds.isEmpty)
            XCTAssertFalse(gate.snapshot.ownsLoader)
            XCTAssertFalse(gate.snapshot.ownsScrollLock)
            XCTAssertEqual(gate.snapshot.lastTerminalOutcome, .failed(failure))
        }
    }

    func testStaleCancellationCannotReleaseNewTransactionOwnership() {
        let gate = ChatAnchorTransactionGate()
        let transactionA = ChatAnchorTransactionToken(rawValue: "transaction-a")
        let transactionB = ChatAnchorTransactionToken(rawValue: "transaction-b")
        _ = gate.begin(token: transactionA, requestIdentity: "message-a")
        _ = gate.begin(token: transactionB, requestIdentity: "message-b")
        XCTAssertTrue(gate.acquire(.query("query-b"), token: transactionB))
        XCTAssertTrue(gate.acquire(.loader, token: transactionB))
        XCTAssertTrue(gate.acquire(.scrollLock, token: transactionB))

        XCTAssertFalse(gate.cancel(token: transactionA, failure: .timeout))
        XCTAssertEqual(gate.snapshot.activeToken, transactionB)
        XCTAssertEqual(gate.snapshot.queryIds, ["query-b"])
        XCTAssertTrue(gate.snapshot.ownsLoader)
        XCTAssertTrue(gate.snapshot.ownsScrollLock)
    }

    func testTypedFailuresDistinguishMissingDeletedAmbiguousAndBoundedResolution() {
        let failures: [ChatAnchorTransactionFailure] = [
            .targetMissing,
            .targetDeleted,
            .ambiguous(candidateCount: 2),
            .candidateLimitExceeded(limit: 65)
        ]

        XCTAssertEqual(Set(failures).count, 4)
    }

    func testCenteringPolicyPlacesTargetMidpointAtViewportMidpoint() {
        XCTAssertEqual(
            ChatAnchorCenteringPolicy.viewportRelativeMinY(viewportHeight: 800, targetHeight: 120),
            340,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ChatAnchorCenteringPolicy.viewportRelativeMinY(viewportHeight: 80, targetHeight: 120),
            0,
            accuracy: 0.001
        )
    }

    func testPositionVerificationRequiresExactIdentityAndCenterTolerance() {
        XCTAssertTrue(
            ChatAnchorPositionVerificationPolicy.isPositioned(
                expectedPrimary: "message",
                expectedArchivedId: "archive",
                actualPrimary: "message",
                actualArchivedId: "archive",
                actualOffsetY: 319.4,
                targetOffsetY: 320
            )
        )
        XCTAssertFalse(
            ChatAnchorPositionVerificationPolicy.isPositioned(
                expectedPrimary: "message",
                expectedArchivedId: "archive",
                actualPrimary: "replacement",
                actualArchivedId: "archive",
                actualOffsetY: 320,
                targetOffsetY: 320
            )
        )
        XCTAssertFalse(
            ChatAnchorPositionVerificationPolicy.isPositioned(
                expectedPrimary: "message",
                expectedArchivedId: "archive",
                actualPrimary: "message",
                actualArchivedId: "archive",
                actualOffsetY: 322,
                targetOffsetY: 320
            )
        )
    }

    func testRetainedMediaAnchorUpdatesRevisionButRejectsIdentityReuseAndUserDrag() {
        let anchor = ChatRetainedMessageAnchor(
            primary: "message",
            archivedId: "archive",
            displayRevision: "revision-1",
            viewportRelativeMinY: 320
        )

        XCTAssertEqual(
            ChatRetainedMessageAnchorPolicy.resolve(
                anchor: anchor,
                nextPrimary: "message",
                nextArchivedId: "archive",
                nextDisplayRevision: "revision-2",
                isUserInteracting: false
            ),
            .retain(
                ChatRetainedMessageAnchor(
                    primary: "message",
                    archivedId: "archive",
                    displayRevision: "revision-2",
                    viewportRelativeMinY: 320
                )
            )
        )
        XCTAssertEqual(
            ChatRetainedMessageAnchorPolicy.resolve(
                anchor: anchor,
                nextPrimary: "message",
                nextArchivedId: "different-archive",
                nextDisplayRevision: "revision-2",
                isUserInteracting: false
            ),
            .drop
        )
        XCTAssertEqual(
            ChatRetainedMessageAnchorPolicy.resolve(
                anchor: anchor,
                nextPrimary: "message",
                nextArchivedId: "archive",
                nextDisplayRevision: "revision-2",
                isUserInteracting: true
            ),
            .drop
        )
    }

    @MainActor
    func testMessageCellReuseRemovesTransactionScopedHighlight() {
        let cell = MessageContentCell(frame: CGRect(x: 0, y: 0, width: 320, height: 80))
        ChatAnchorHighlightOverlay.install(
            on: cell,
            primary: "message-a",
            revision: "revision-a"
        )

        XCTAssertEqual(ChatAnchorHighlightOverlay.representedPrimary(in: cell), "message-a")
        XCTAssertEqual(ChatAnchorHighlightOverlay.representedRevision(in: cell), "revision-a")

        cell.prepareForReuse()

        XCTAssertNil(ChatAnchorHighlightOverlay.representedPrimary(in: cell))
        XCTAssertNil(ChatAnchorHighlightOverlay.representedRevision(in: cell))
    }

    func testPositioningSourceContainsNoDirectionalStagingOrFixedDelayCompletion() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift"
            ),
            encoding: .utf8
        )
        let positioningSource = try XCTUnwrap(
            source.components(separatedBy: "private func positionMessage(").dropFirst().first?
                .components(separatedBy: "private func centeredContentOffsetY").first
        )

        XCTAssertFalse(source.contains("enum ChatDirectionalScrollStagingPolicy"))
        XCTAssertFalse(positioningSource.contains("prepareDirectionalSearchScrollIfNeeded"))
        XCTAssertFalse(positioningSource.contains("asyncAfter"))
        XCTAssertFalse(positioningSource.contains("0.35"))
    }
}
