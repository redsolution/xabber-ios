import XCTest
import UIKit
@testable import xabber

final class ChatArchiveTerminalFailureRecoveryRegressionTests: XCTestCase {
    private let conversation = ArchiveConversationKey(owner: "owner@example.org",
        jid: "peer@example.org", conversationType: .regular)

    @MainActor
    func testTerminalAdmissionFailureOffersRetryInsteadOfNeutralPending() throws {
        let controller = makeController()
        let intent = ArchiveWindowIntent(conversation: conversation, locator: .latest,
            contextBefore: 80, contextAfter: 0, priority: .target)
        controller.archiveWindowIntent = intent
        controller.archiveWindowStateTask = Task { }
        defer { controller.archiveWindowStateTask?.cancel() }

        controller.receiveArchiveWindowState(.retryableFailure(
            .init(message: "group admission failed", retryCount: 8, canRetry: false),
            target: .latest))

        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertFalse(controller.archiveHistoryRecoveryStatusView.isHidden,
            "An actual terminal failure must be actionable, rather than look like an indefinitely pending archive")
        XCTAssertTrue(controller.archiveHistoryPendingLabel.isHidden)
        let retry = try XCTUnwrap(retryButton(controller))
        XCTAssertTrue(retry.isEnabled)
        XCTAssertTrue(controller.archiveHistoryRecoveryStatusView.isUserInteractionEnabled)
        XCTAssertTrue(controller.datasource.isEmpty)
        XCTAssertNil(controller.committedTimelineScope())
        XCTAssertEqual(controller.archiveWindowIntent?.id, intent.id)
    }

    @MainActor
    func testPendingSavedTargetCannotOfferRetryWhenOnlyPresentationDeadlineExpires() throws {
        let controller = makeController()
        let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "saved-cursor"))
        controller.archiveWindowIntent = ArchiveWindowIntent(conversation: conversation,
            locator: .archiveID(cursor), contextBefore: 30, contextAfter: 30, priority: .target)
        controller.pendingOpenMessageRequest = ChatOpenMessageRequest(
            chatJid: conversation.jid, owner: conversation.owner,
            conversationType: .regular,
            anchor: .init(messagePrimary: "saved-primary", archivedId: "saved-id",
                messageId: "saved-message", authorId: nil, bodyFingerprint: nil,
                sourceDate: nil),
            highlight: false, markReadOnVisible: false, source: .savedVisiblePosition)
        controller.archiveWindowState = .skeleton(reason: .loadingTarget, target: .archiveID(cursor))
        controller.showSkeletonObserver.accept(true)

        controller.refreshArchiveHistoryRecoveryPresentation()
        controller.expireArchiveOpeningWaitForTesting()
        controller.refreshArchiveHistoryRecoveryPresentation()

        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertTrue(controller.archiveHistoryRecoveryStatusView.isHidden)
        XCTAssertNil(retryButton(controller))
        XCTAssertNotNil(controller.pendingOpenMessageRequest)
        controller.stopArchiveEnginePresentationSubscription()
    }

    @MainActor
    func testOlderTerminalFailureOffersRetryWithoutReplacingCommittedRowsOrAuthority() throws {
        let controller = makeController()
        let fixture = try prepareBoundary(on: controller)
        let primaries = controller.datasource.map(\.primary)
        let offset = controller.messagesCollectionView.contentOffset
        let committed = controller.archiveWindowState

        controller.receiveArchiveBoundaryTerminal(ArchiveBoundaryTerminalOutcome(
            requestID: fixture.intent.id, descriptor: fixture.intent.semanticDescriptor,
            result: .failed(.init(message: "persistence validation failed", retryCount: 1,
                canRetry: false, recoveryAction: .retry))))

        XCTAssertEqual(controller.datasource.map(\.primary), primaries)
        XCTAssertEqual(controller.archiveWindowState, committed)
        XCTAssertEqual(controller.archiveWindowCommittedCoverageGeneration, 1)
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.messagesCollectionView.contentOffset, offset)
        XCTAssertNil(controller.timelineBoundaryRequest)
        XCTAssertFalse(controller.archiveHistoryRecoveryStatusView.isHidden)
        XCTAssertNotNil(retryButton(controller),
            "A retained actor budget must not silently make every later older pull inert")
    }

    @MainActor
    func testStaleBoundaryFailureCannotExposeRetryForCurrentRequest() throws {
        let controller = makeController()
        let fixture = try prepareBoundary(on: controller)

        controller.receiveArchiveBoundaryTerminal(.init(requestID: UUID(),
            descriptor: fixture.intent.semanticDescriptor,
            result: .failed(.init(message: "stale failure", retryCount: 1, canRetry: false))))

        XCTAssertEqual(controller.timelineBoundaryRequest?.remoteIntentID, fixture.intent.id)
        XCTAssertTrue(controller.archiveHistoryRecoveryStatusView.isHidden)
        XCTAssertNil(retryButton(controller))
    }

    @MainActor
    func testPassiveBoundaryPrefetchFailureDoesNotInterruptCommittedContent() throws {
        let controller = makeController()
        let fixture = try prepareBoundary(on: controller)
        let primaries = controller.datasource.map(\.primary)
        var request = try XCTUnwrap(controller.timelineBoundaryRequest)
        request.isVisible = false
        controller.timelineBoundaryRequest = request

        controller.receiveArchiveBoundaryTerminal(.init(requestID: fixture.intent.id,
            descriptor: fixture.intent.semanticDescriptor,
            result: .failed(.init(message: "prefetch failed", retryCount: 1, canRetry: false))))

        XCTAssertTrue(controller.archiveHistoryRecoveryStatusView.isHidden)
        XCTAssertNil(retryButton(controller))
        XCTAssertNil(controller.timelineBoundaryRequest)
        XCTAssertEqual(controller.datasource.map(\.primary), primaries)
        XCTAssertEqual(controller.archiveWindowCommittedCoverageGeneration, 1)
    }

    @MainActor
    func testTerminalReferenceResolutionOffersRetryForSameExactPendingRequest() throws {
        let controller = makeController()
        let request = ChatOpenMessageRequest(chatJid: conversation.jid,
            owner: conversation.owner, conversationType: .regular,
            anchor: .init(messagePrimary: "saved-primary", archivedId: "saved-id",
                messageId: "saved-message", authorId: nil, bodyFingerprint: nil, sourceDate: nil),
            highlight: false, markReadOnVisible: false, source: .savedVisiblePosition)
        let intent = ArchiveWindowIntent(conversation: conversation, locator: .latest,
            contextBefore: 80, contextAfter: 0, priority: .target)
        let resolutionID = UUID()
        controller.pendingOpenMessageRequest = request
        controller.archiveWindowIntent = intent
        controller.archiveReferenceResolutionID = resolutionID
        controller.archiveReferenceResolutionTask = Task { }

        let accepted = controller.failArchiveReferenceResolution(.timeout, request: request,
            resolutionID: resolutionID, expectedIntentID: intent.id)

        XCTAssertTrue(accepted)
        XCTAssertEqual(controller.archiveReferenceFailureRetryRequest(), request,
            "This terminal has no window retry budget: only its exact owned reference-resolution request may restart")
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertFalse(controller.archiveHistoryRecoveryStatusView.isHidden)
        XCTAssertNotNil(retryButton(controller))
        controller.stopArchiveEnginePresentationSubscription()
    }

    @MainActor
    func testPendingReferenceAndUnrelatedWindowFailureCannotSelectReferenceRetry() throws {
        let controller = makeController()
        let request = ChatOpenMessageRequest(chatJid: conversation.jid,
            owner: conversation.owner, conversationType: .regular,
            anchor: .init(messagePrimary: nil, archivedId: "saved-id", messageId: nil,
                authorId: nil, bodyFingerprint: nil, sourceDate: nil),
            highlight: false, markReadOnVisible: false, source: .savedVisiblePosition)
        controller.pendingOpenMessageRequest = request
        controller.archiveWindowIntent = ArchiveWindowIntent(conversation: conversation,
            locator: .latest, contextBefore: 80, contextAfter: 0, priority: .target)
        controller.archiveReferenceResolutionID = UUID()
        controller.archiveWindowState = .skeleton(reason: .loadingTarget, target: .latest)
        XCTAssertNil(controller.archiveReferenceFailureRetryRequest())

        controller.archiveReferenceResolutionID = nil
        controller.archiveWindowState = .retryableFailure(.init(message: "window failed",
            retryCount: 1, canRetry: false), target: .latest)
        XCTAssertNil(controller.archiveReferenceFailureRetryRequest(),
            "A rejected actor retry cannot be converted into a new reference-resolution loop")
    }

    @MainActor
    private func makeController() -> ChatViewController {
        let controller = ChatViewController()
        controller.view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        controller.owner = conversation.owner
        controller.jid = conversation.jid
        controller.conversationType = .regular
        controller.messagesCollectionView.messagesDataSource = controller
        controller.messagesCollectionView.frame = CGRect(x: 0, y: 100, width: 390, height: 650)
        controller.xabberInputView = ModernXabberInputView(frame: CGRect(x: 0, y: 800, width: 390, height: 44))
        return controller
    }

    @MainActor
    private func prepareBoundary(on controller: ChatViewController) throws -> (intent: ArchiveWindowIntent, scope: ChatTimelineVerifiedScope) {
        let oldest = try XCTUnwrap(ArchiveCursor(rawValue: "20"))
        let newest = try XCTUnwrap(ArchiveCursor(rawValue: "30"))
        let segment = try XCTUnwrap(ArchiveCoverageSegment(oldest: oldest, newest: newest,
            reachesArchiveStart: false, reachesLiveEdge: true, fingerprint: "session:1",
            isVerified: true, orderedArchiveIDs: [oldest, newest]))
        let freshness = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: "committed")
        let scope = try XCTUnwrap(ChatTimelineVerifiedScope(conversationKey: controller.chatTimelineConversationKey,
            segment: segment, coverageGeneration: 1, freshnessToken: freshness))
        let item = MessageStorageItem()
        item.primary = "retained-primary"
        item.messageId = "retained-message"
        item.owner = conversation.owner
        item.opponent = conversation.jid
        item.conversationType = .regular
        item.archivedId = "20"
        item.mamArchiveId = "20"
        item.body = "Previously committed text"
        item.legacyBody = item.body
        item.date = Date(timeIntervalSince1970: 20)
        controller.datasource = controller.mapDataset(dataset: [item])
        controller.showSkeletonObserver.accept(false)
        controller.archiveWindowState = .verified(.init(messagePrimaryIDs: [item.primary],
            target: .latest, verifiedSegment: segment, coverageGeneration: 1, freshnessToken: freshness))
        controller.archiveWindowCommittedCoverageGeneration = 1
        let intent = ArchiveWindowIntent(conversation: conversation, locator: .older(before: oldest),
            contextBefore: 100, contextAfter: 80, priority: .visibleIntegrity)
        controller.archiveWindowIntent = intent
        controller.timelineBoundaryRequest = ChatTimelineBoundaryRequestContext(id: intent.id,
            direction: .older, scope: scope, locator: intent.locator, baseGeneration: 1,
            applyGeneration: 1, anchor: nil, owningPresentationIntentID: intent.id,
            isVisible: true, phase: .waitingRemote, remoteIntentID: intent.id)
        return (intent, scope)
    }

    @MainActor
    private func retryButton(_ controller: ChatViewController) -> UIButton? {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        return descendants(controller.archiveHistoryRecoveryStatusView)
            .compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "chat.archiveHistory.retry" }
    }
}
