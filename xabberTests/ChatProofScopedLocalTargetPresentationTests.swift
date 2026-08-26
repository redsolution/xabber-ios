import XCTest
@testable import xabber

final class ChatProofScopedLocalTargetPresentationTests: XCTestCase {
    func testTargetInsideVerifiedScopeUsesStagedAtomicUIKitApplyBeforePositionWithoutMAM() throws {
        let scope = try makeScope(oldest: "100", newest: "900")
        let request = makeRequest(archiveID: "250")

        XCTAssertEqual(
            ChatProofScopedOpenTargetAdmission.route(
                request: request,
                verifiedScope: scope
            ),
            .local(try XCTUnwrap(ArchiveCursor(rawValue: "250")))
        )

        let source = try searchBarSource()
        let queue = try methodBody(
            named: "internal func queueOpenMessageRequest(",
            in: source,
            endingBefore: "private func handleSuppressedOpenMessageRequest"
        )
        XCTAssertOrdered(
            "startProofScopedLocalOpenMessageRequestIfPossible(",
            before: "submitArchiveEngineTarget(request)",
            in: queue
        )

        let localRoute = try methodBody(
            named: "private func startProofScopedLocalOpenMessageRequestIfPossible(",
            in: source,
            endingBefore: "private func receiveProofScopedLocalTargetPreparation("
        )
        XCTAssertTrue(localRoute.contains("prepareVerifiedLocalTarget("))
        XCTAssertFalse(
            localRoute.contains("submitArchiveEngineTarget"),
            "A target already covered by the current proof must not submit MAM"
        )

        XCTAssertTrue(source.contains("inspectPreparedVerifiedLocalTarget(prepared)"))
        XCTAssertTrue(source.contains("presentationCommitMode: .atomicInitialFrame"))
        XCTAssertTrue(source.contains("transactionCommitAuthorization:"))
        XCTAssertTrue(source.contains("commitPreparedVerifiedLocalTarget(prepared)"))
        XCTAssertTrue(source.contains(".mapping, token: context.transactionToken"))
        XCTAssertTrue(source.contains(".apply, token: context.transactionToken"))

        let proofAuthorization = try methodBody(
            named: "private func isCurrentProofScopedLocalTargetPresentation(",
            in: source,
            endingBefore: "private func retryProofScopedLocalTargetIfCurrent("
        )
        XCTAssertTrue(proofAuthorization.contains(
            "allowsPendingLiveEdgeAdmission:"
        ))
        XCTAssertTrue(proofAuthorization.contains("localPresentationID != nil"))

        let completion = try methodBody(
            named: "private func completeProofScopedLocalTargetApply(",
            in: source,
            endingBefore: "private func failProofScopedLocalTargetPreparation("
        )
        XCTAssertTrue(
            completion.contains("performLoadedOpenMessageRequestIfPossible(context.request)"),
            "The atomic window apply must finish through the existing exact positioning/highlight path"
        )
        XCTAssertFalse(
            completion.contains("proofScopedLocalTargetRequest = nil"),
            "The local presentation token must remain held through exact positioning/highlight"
        )
        XCTAssertFalse(
            completion.contains("finishCommittedTimelineLocalPresentation"),
            "Only the terminal anchor success/failure/cancel path may release the token"
        )
        XCTAssertFalse(completion.contains("submitArchiveEngineTarget"))

        let terminal = try methodBody(
            named: "private func finishActiveAnchorExecution(",
            in: source,
            endingBefore: "private func failActiveAnchorExecution("
        )
        XCTAssertOrdered(
            "let localPresentationID = self.proofScopedLocalTargetRequest?.id",
            before: "self.proofScopedLocalTargetRequest = nil",
            in: terminal
        )
        XCTAssertOrdered(
            "self.proofScopedLocalTargetRequest = nil",
            before: "self.finishCommittedTimelineLocalPresentation(",
            in: terminal
        )
    }

    func testTargetOutsideVerifiedScopeFallsThroughToExistingArchiveIDMAM() throws {
        let scope = try makeScope(oldest: "100", newest: "900")
        let request = makeRequest(archiveID: "901")

        XCTAssertEqual(
            ChatProofScopedOpenTargetAdmission.route(
                request: request,
                verifiedScope: scope
            ),
            .remote
        )

        let searchSource = try searchBarSource()
        let queue = try methodBody(
            named: "internal func queueOpenMessageRequest(",
            in: searchSource,
            endingBefore: "private func handleSuppressedOpenMessageRequest"
        )
        XCTAssertTrue(queue.contains("submitArchiveEngineTarget(request)"))

        let archiveSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
        )
        let remote = try methodBody(
            named: "internal func submitArchiveEngineTarget(",
            in: archiveSource,
            endingBefore: "internal func canRequestTimelineBoundary("
        )
        XCTAssertTrue(remote.contains("locator = .archiveID(cursor)"))
        XCTAssertTrue(remote.contains("account.archiveEngine.submit(intent)"))
    }

    func testStaleOrDisconnectedPreparationCannotCommitAndKeepsPendingTargetForFreshProof() throws {
        let searchSource = try searchBarSource()
        XCTAssertTrue(searchSource.contains("session.snapshot.generation == context.baseGeneration"))
        XCTAssertTrue(searchSource.contains("session.verifiedScope == context.scope"))
        XCTAssertTrue(searchSource.contains("archiveWindowApplyGeneration == context.applyGeneration"))
        XCTAssertTrue(searchSource.contains("pendingOpenMessageRequest == context.request"))
        XCTAssertTrue(searchSource.contains("invalidateProofScopedLocalTargetPreparation()"))

        let invalidation = try methodBody(
            named: "internal func invalidateProofScopedLocalTargetPreparation()",
            in: searchSource,
            endingBefore: "private func proofScopedLocalTargetContext("
        )
        XCTAssertTrue(invalidation.contains("proofScopedLocalTargetRequest = nil"))
        XCTAssertFalse(
            invalidation.contains("pendingOpenMessageRequest = nil"),
            "Disconnect must revoke the stale receipt while preserving the target for a fresh session proof"
        )

        let archiveSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
        )
        XCTAssertTrue(
            archiveSource.contains("invalidateProofScopedLocalTargetPreparation()")
        )
    }

    func testProofLocalReleaseCannotReenterPendingRouteBeforeFailureDecision() throws {
        let searchSource = try searchBarSource()
        let archiveSource = try productionSource(
            "controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift"
        )
        let finishLocal = try methodBody(
            named: "internal func finishCommittedTimelineLocalPresentation(",
            in: archiveSource,
            endingBefore: "internal func drainTimelinePresentationLanesAfterAnchorTerminal()"
        )
        XCTAssertFalse(finishLocal.contains("performPendingOpenMessageRequestIfNeeded"))
        XCTAssertFalse(finishLocal.contains("submitArchiveEngineTarget"))
        XCTAssertFalse(finishLocal.contains("drainTimelinePresentationLanesAfterAnchorTerminal"))

        let failure = try methodBody(
            named: "private func failProofScopedLocalTargetPreparation(",
            in: searchSource,
            endingBefore: "internal func invalidateProofScopedLocalTargetPreparation()"
        )
        XCTAssertOrdered(
            "proofScopedLocalTargetRequest = nil",
            before: "finishCommittedTimelineLocalPresentation(id: context.id)",
            in: failure
        )
        XCTAssertFalse(failure.contains("performPendingOpenMessageRequestIfNeeded"))
        XCTAssertFalse(failure.contains("submitArchiveEngineTarget"))

        let invalidation = try methodBody(
            named: "internal func invalidateProofScopedLocalTargetPreparation()",
            in: searchSource,
            endingBefore: "private func proofScopedLocalTargetContext("
        )
        XCTAssertFalse(invalidation.contains("performPendingOpenMessageRequestIfNeeded"))
        XCTAssertFalse(invalidation.contains("submitArchiveEngineTarget"))

        let retry = try methodBody(
            named: "private func retryProofScopedLocalTargetIfCurrent(",
            in: searchSource,
            endingBefore: "private func resumePendingOpenMessageRequestThroughCurrentRoute()"
        )
        XCTAssertEqual(
            retry.components(
                separatedBy: "startProofScopedLocalOpenMessageRequestIfPossible("
            ).count - 1,
            1,
            "A preserved proof-local target gets exactly one fresh local retry"
        )
        XCTAssertFalse(retry.contains("submitArchiveEngineTarget"))
    }

    private func makeRequest(archiveID: String) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: "juliet@example.org",
            owner: "romeo@example.org",
            conversationType: .regular,
            anchor: ChatMessageAnchorRef(
                messagePrimary: "primary-\(archiveID)",
                archivedId: archiveID,
                messageId: "message-\(archiveID)",
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: nil
            ),
            highlight: true,
            markReadOnVisible: false,
            source: .search
        )
    }

    private func makeScope(
        oldest: String,
        newest: String
    ) throws -> ChatTimelineVerifiedScope {
        let conversation = ChatTimelineConversationKey(
            owner: "romeo@example.org",
            jid: "juliet@example.org",
            conversationType: .regular
        )
        let token = ArchiveFreshnessToken.sessionMAM(
            connectionGeneration: 7,
            queryID: "query-7"
        )
        let segment = try XCTUnwrap(ArchiveCoverageSegment(
            oldest: try XCTUnwrap(ArchiveCursor(rawValue: oldest)),
            newest: try XCTUnwrap(ArchiveCursor(rawValue: newest)),
            reachesArchiveStart: false,
            reachesLiveEdge: true,
            fingerprint: token.fingerprint,
            isVerified: true
        ))
        return try XCTUnwrap(ChatTimelineVerifiedScope(
            conversationKey: conversation,
            segment: segment,
            coverageGeneration: 3,
            freshnessToken: token
        ))
    }

    private func searchBarSource() throws -> String {
        try productionSource(
            "controllers/chats/chat/extension/ChatViewController+SearchBar.swift"
        )
    }

    private func productionSource(_ relativePath: String) throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath)
        let root = testsURL.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("xabber/\(relativePath)"),
            encoding: .utf8
        )
    }

    private func methodBody(
        named startToken: String,
        in source: String,
        endingBefore endToken: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startToken)?.lowerBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endToken)?.lowerBound)
        return String(suffix[..<end])
    }

    private func XCTAssertOrdered(
        _ first: String,
        before second: String,
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let firstRange = source.range(of: first),
              let secondRange = source.range(of: second) else {
            return XCTFail(
                "Missing ordered tokens: \(first), \(second)",
                file: file,
                line: line
            )
        }
        XCTAssertLessThan(
            firstRange.lowerBound,
            secondRange.lowerBound,
            file: file,
            line: line
        )
    }
}
