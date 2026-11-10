import XCTest
import UIKit
import RealmSwift
import RxSwift
@testable import xabber

@MainActor
final class ChatSavedPositionCachePresentationTests: XCTestCase {
    private var previousConfiguration: Realm.Configuration!
    private var realm: Realm!
    private var controller: ChatViewController!
    private let peer = "saved-peer@example.test"
    private var owner = ""
    private var request: ChatOpenMessageRequest!
    private var intent: ArchiveWindowIntent!
    private var cached: ChatSavedPositionPresentationWindow!
    private var navigationCompletions = 0
    private var loadedPositioningCalls = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier: "SavedCachePresentation-\(UUID().uuidString)"
        )
        realm = try WRealm.safe()
        owner = "saved-owner-\(UUID().uuidString.lowercased())@example.test"
        let cursors = try (0..<81).map { try XCTUnwrap(ArchiveCursor(rawValue: "opaque-cache-\($0)")) }
        let segment = try XCTUnwrap(ArchiveCoverageSegment(orderedArchiveIDs: cursors,
            reachesArchiveStart: false, reachesLiveEdge: false,
            fingerprint: "session:41", isVerified: true))
        try realm.write {
            for index in 0..<81 {
                let row = MessageStorageItem()
                row.primary = MessageStorageItem.genPrimary(messageId: "saved-message-\(index)", owner: owner)
                row.messageId = "saved-message-\(index)"
                row.owner = owner; row.opponent = peer; row.conversationType = .regular
                row.archivedId = cursors[index].rawValue; row.mamArchiveId = cursors[index].rawValue
                row.date = Date(timeIntervalSince1970: Double(1000 + index)); row.sentDate = row.date
                row.body = "Cached message \(index)"; row.legacyBody = row.body; row.state = .deliver
                realm.add(row)
            }
            let anchor = realm.object(ofType: MessageStorageItem.self,
                forPrimaryKey: MessageStorageItem.genPrimary(messageId: "saved-message-40", owner: owner))!
            let chat = LastChatsStorageItem()
            chat.primary = LastChatsStorageItem.genPrimary(jid: peer, owner: owner, conversationType: .regular)
            chat.owner = owner; chat.jid = peer; chat.conversationType = .regular
            chat.lastMessageId = "tail"; chat.syncSnapshotLastArchiveId = "tail-cursor"
            chat.lastVisibleMessagePrimary = anchor.primary
            chat.lastVisibleMessageId = anchor.messageId
            chat.lastVisibleMessageArchivedId = anchor.mamArchiveId
            chat.lastVisibleMessageDate = anchor.date
            chat.lastVisiblePositionSavedAtLastMessageId = "tail"
            chat.lastVisiblePositionSavedAtSnapshotLastArchiveId = "tail-cursor"
            realm.add(chat)
            let coverage = ConversationArchiveCoverageStorageItem.ensure(
                key: .init(owner: owner, jid: peer, conversationType: .regular), in: realm)
            coverage.segments = [segment]; coverage.coverageGeneration = 7
            coverage.archiveFreshnessFingerprint = "session:41"
        }
        request = .init(chatJid: peer, owner: owner, conversationType: .regular,
            anchor: .init(messagePrimary: MessageStorageItem.genPrimary(messageId: "saved-message-40", owner: owner),
                archivedId: cursors[40].rawValue, messageId: "saved-message-40",
                authorId: nil, bodyFingerprint: nil, sourceDate: Date(timeIntervalSince1970: 1040)),
            highlight: false, markReadOnVisible: false, source: .savedVisiblePosition)
        cached = try XCTUnwrap(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
        intent = .init(conversation: .init(owner: owner, jid: peer, conversationType: .regular),
            locator: .archiveID(cursors[40]), contextBefore: 30, contextAfter: 30, priority: .target)
        controller = ChatViewController()
        controller.owner = owner; controller.jid = peer; controller.conversationType = .regular
        controller.ownerSender = Sender(id: owner, displayName: owner)
        controller.opponentSender = Sender(id: peer, displayName: peer)
        controller.loadViewIfNeeded()
        controller.stopArchiveEnginePresentationSubscription()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        controller.timelineSession = ChatTimelineSession(
            store: RealmChatTimelineSessionStore(owner: owner, jid: peer, conversationType: .regular),
            pageSize: ArchivePageSizing.history,
            conversationKey: .init(owner: owner, jid: peer, conversationType: .regular),
            observesStoreImmediately: false)
        controller.archiveWindowStateTask = Task {}
        controller.archiveWindowIntent = intent
        controller.archiveWindowTargetOpenRequest = request
        controller.archiveWindowState = .skeleton(reason: .loadingTarget, target: intent.locator)
        controller.pendingOpenMessageRequest = request
        controller.initialTargetFirstFrameContext = .init(request: request) { [weak self] in
            self?.navigationCompletions += 1
        }
        controller.isPreparingStackedNavigationPresentation = true
        controller.isStackedNavigationPresentationPreparationCancelled = false
        controller.shouldDeferPendingOpenMessageRequestUntilNavigationTransitionCompletion = false
        controller.loadedAnchorPositioningDriverForTests = { [weak self] completion in
            self?.loadedPositioningCalls += 1
            completion(true)
        }
        controller.showSkeletonObserver.accept(true)
        _ = controller.commitArchiveEngineOpeningSkeletonSynchronously()
    }

    override func tearDown() {
        controller?.datasourceDidSetForTests = nil
        controller?.performTerminalChatResourceTeardownForTesting()
        controller = nil; cached = nil; request = nil; intent = nil; realm = nil
        Realm.Configuration.defaultConfiguration = previousConfiguration
        previousConfiguration = nil
        super.tearDown()
    }

    func testEligibleSavedCachePublishesOneAtomicAlignedFrameWithoutFreshAuthority() async throws {
        try await assertAtomicSavedCachePresentation()
    }

    func testLocalAdjacencySavedCachePublishesAtomicTargetWithoutFreshReadOrPagingAuthority() async throws {
        let previousSegment = try XCTUnwrap(cached.segment)
        try realm.write {
            try ChatLocalHistoryLinkedIndex.rebuildConversation(
                owner: owner, jid: peer, conversationType: .regular, in: realm)
            let coverage = realm.objects(ConversationArchiveCoverageStorageItem.self).first!
            coverage.segments = [ArchiveCoverageSegment(
                orderedArchiveIDs: Array(previousSegment.orderedArchiveIDs.prefix(30)),
                reachesArchiveStart: false, reachesLiveEdge: false,
                fingerprint: "session:41", isVerified: true)!]
        }
        cached = try XCTUnwrap(ChatSavedPositionPresentationCache.read(request: request, realm: realm))
        guard case .localAdjacency(let version, _) = cached.provenance else {
            return XCTFail("The exact saved target is outside the current durable archive ledger")
        }
        XCTAssertEqual(version, ChatLocalHistoryIndexStorageItem.currentVersion)
        XCTAssertNil(cached.segment)

        try await assertAtomicSavedCachePresentation()
    }

    private func assertAtomicSavedCachePresentation() async throws {
        let revealed = expectation(description: "saved target visible only after atomic positioning")
        var revealCount = 0
        var alignmentErrors: [CGFloat] = []
        let subscription = controller.showSkeletonObserver.asObservable().subscribe(onNext: { [weak self] hidden in
            guard !hidden, let self else { return }
            revealCount += 1
            if let frame = self.frame(primary: self.cached.anchorPrimary) {
                let expected = max(0, (self.controller.messagesCollectionView.bounds.height - frame.height) / 2)
                alignmentErrors.append(abs(frame.minY - self.controller.messagesCollectionView.contentOffset.y - expected))
            }
            revealed.fulfill()
        })
        defer { subscription.dispose() }
        let state = controller.archiveWindowState
        let coverageBefore = realm.objects(ConversationArchiveCoverageStorageItem.self).first!.segmentsJSON
        let accepted = presentCache()
        XCTAssertTrue(accepted, "A durable exact saved window can render while current-session MAM repairs authority")
        guard accepted else { return }
        await fulfillment(of: [revealed], timeout: 3)
        try await waitForNavigationCompletion()

        XCTAssertEqual(revealCount, 1)
        XCTAssertEqual(alignmentErrors.count, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(alignmentErrors.first), 1)
        XCTAssertEqual(controller.archiveWindowState, state)
        XCTAssertNil(controller.timelineSession?.verifiedScope)
        XCTAssertTrue(controller.timelineSession?.snapshot.items.isEmpty == true)
        XCTAssertNil(controller.archiveWindowCommittedCoverageGeneration)
        XCTAssertTrue(controller.archiveHistoryFailureFallbackIsVisible)
        XCTAssertFalse(controller.canAdvanceReadStateFromVisiblePresentation())
        XCTAssertFalse(controller.canRequestTimelineBoundary(direction: .older))
        XCTAssertEqual(realm.objects(ConversationArchiveCoverageStorageItem.self).first!.segmentsJSON, coverageBefore)
        XCTAssertEqual(navigationCompletions, 1)
        XCTAssertEqual(loadedPositioningCalls, 0, "No post-visible loaded-anchor correction is permitted")
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.initialTargetFirstFrameContext)
    }

    func testFreshSameSavedTargetKeepsTheReadersViewportWhenEarlierRowsChangeHeight() async throws {
        let accepted = presentCache()
        XCTAssertTrue(accepted)
        guard accepted else { return }
        try await waitForNavigationCompletion()
        controller.messagesCollectionView.contentOffset.y += 100
        controller.messagesCollectionView.layoutIfNeeded()
        let visible = try XCTUnwrap(controller.messagesCollectionView.indexPathsForVisibleItems
            .sorted(by: { $0.section < $1.section }).first { index in
                controller.datasource.indices.contains(index.section) &&
                    !controller.datasource[index.section].isFakeMessage &&
                    cached.rows.contains { $0.primary == controller.datasource[index.section].primary }
            })
        let readingPrimary = controller.datasource[visible.section].primary
        let before = try XCTUnwrap(frame(primary: readingPrimary)).minY - controller.messagesCollectionView.contentOffset.y
        let fresh = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 42, queryID: "fresh-saved-cache")
        let cachedSegment = try XCTUnwrap(cached.segment)
        let segment = try XCTUnwrap(ArchiveCoverageSegment(
            orderedArchiveIDs: cachedSegment.orderedArchiveIDs,
            reachesArchiveStart: false, reachesLiveEdge: false,
            fingerprint: fresh.fingerprint, isVerified: true))
        try realm.write {
            let earlier = realm.object(ofType: MessageStorageItem.self,
                forPrimaryKey: MessageStorageItem.genPrimary(messageId: "saved-message-15", owner: owner))!
            earlier.body = String(repeating: "Updated archived paragraph with a different prepared height.\n", count: 20)
            earlier.legacyBody = earlier.body
            let coverage = realm.objects(ConversationArchiveCoverageStorageItem.self).first!
            coverage.segments = [segment]; coverage.archiveFreshnessFingerprint = fresh.fingerprint
            coverage.coverageGeneration = 8
        }

        controller.receiveArchiveWindowState(.verified(.init(
            messagePrimaryIDs: cached.rows.map(\.primary), target: intent.locator,
            verifiedSegment: segment, coverageGeneration: 8, freshnessToken: fresh)))
        for _ in 0..<600 where controller.archiveWindowCommittedCoverageGeneration != 8 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(controller.archiveWindowCommittedCoverageGeneration, 8)
        XCTAssertNotNil(controller.timelineSession?.verifiedScope)
        let after = try XCTUnwrap(frame(primary: readingPrimary)).minY - controller.messagesCollectionView.contentOffset.y
        XCTAssertEqual(after, before, accuracy: 1, "Fresh proof updates authority without recentering a reader's cached target")
        XCTAssertEqual(navigationCompletions, 1)
        XCTAssertEqual(loadedPositioningCalls, 0)
        XCTAssertFalse(controller.archiveHistoryFailureFallbackIsVisible)
    }

    func testColdPreparationCanQueueCacheBeforeMatchingFirstFrameContextIsInstalled() async throws {
        // Real prepareForStackedNavigationPresentation sets isPreparing, loads
        // the view (which can submit archive work), then installs its context.
        controller.initialTargetFirstFrameContext = nil
        controller.isPreparingStackedNavigationPresentation = true

        let accepted = presentCache()
        XCTAssertTrue(accepted, "The current preparation turn may install its matching context before the async cache apply")
        guard accepted else { return }
        controller.initialTargetFirstFrameContext = .init(request: request) { [weak self] in
            self?.navigationCompletions += 1
        }
        try await waitForNavigationCompletion()

        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertNil(controller.pendingOpenMessageRequest)
        XCTAssertNil(controller.timelineSession?.verifiedScope)
        XCTAssertTrue(controller.archiveHistoryFailureFallbackIsVisible)
        XCTAssertEqual(navigationCompletions, 1)
        XCTAssertEqual(loadedPositioningCalls, 0)
    }

    func testActualColdArchiveStartQueuesSavedCacheBeforeAnyTransportRuns() async throws {
        let previousUsers = AccountManager.shared.users
        let account = Account(jid: owner, queue: DispatchQueue(label: "SavedCacheColdStart-account"))
        AccountManager.shared.users = previousUsers + [account]
        defer {
            controller.stopArchiveEnginePresentationSubscription()
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
            AccountManager.shared.users = previousUsers
        }
        controller.stopArchiveEnginePresentationSubscription()
        controller.pendingOpenMessageRequest = request
        controller.initialTargetFirstFrameContext = .init(request: request) { [weak self] in
            self?.navigationCompletions += 1
        }
        controller.isPreparingStackedNavigationPresentation = true

        controller.startArchiveEnginePresentationIfNeeded()
        // Cancel the fake account's producer tasks before yielding MainActor.
        // The readonly cached UIKit job must not depend on a wire operation.
        controller.archiveEnginePresentationDemandTask?.cancel()
        controller.archiveWindowStateTask?.cancel()
        try await waitForNavigationCompletion()

        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertEqual(navigationCompletions, 1)
        XCTAssertEqual(loadedPositioningCalls, 0)
        XCTAssertTrue(controller.archiveHistoryFailureFallbackIsVisible)
        XCTAssertNil(controller.timelineSession?.verifiedScope)
        XCTAssertNil(controller.archiveWindowCommittedCoverageGeneration)
        XCTAssertEqual(controller.savedPositionCachePresentationContext?.request, request)
    }

    func testAcceptedLoadingSkeletonRequeuesCurrentSavedCacheRendering() async throws {
        let before = controller.archiveWindowApplyGeneration

        controller.receiveArchiveWindowState(.skeleton(reason: .loadingTarget, target: intent.locator))
        try await waitForNavigationCompletion()

        XCTAssertGreaterThan(controller.archiveWindowApplyGeneration, before)
        XCTAssertFalse(controller.showSkeletonObserver.value)
        XCTAssertEqual(navigationCompletions, 1)
        XCTAssertEqual(loadedPositioningCalls, 0)
        XCTAssertNil(controller.timelineSession?.verifiedScope)
        XCTAssertNil(controller.archiveWindowCommittedCoverageGeneration)
        XCTAssertTrue(controller.archiveHistoryFailureFallbackIsVisible)
    }

    func testQueuedCacheCannotRevealAfterAnExplicitTargetWinsOwnership() async {
        let queue = controller.datasetMappingQueue
        let gate = DispatchSemaphore(value: 0)
        let blocked = expectation(description: "cache mapping queue blocked")
        queue.async { blocked.fulfill(); _ = gate.wait(timeout: .now() + 3) }
        await fulfillment(of: [blocked], timeout: 1)
        defer { gate.signal() }
        XCTAssertTrue(presentCache())
        let explicit = ChatOpenMessageRequest(chatJid: peer, owner: owner, conversationType: .regular,
            anchor: request.anchor, highlight: true, markReadOnVisible: false, source: .search)
        controller.pendingOpenMessageRequest = explicit
        controller.initialTargetFirstFrameContext = .init(request: explicit, completion: {})
        controller.archiveWindowTargetOpenRequest = explicit
        controller.archiveWindowIntent = .init(conversation: intent.conversation, locator: intent.locator,
            contextBefore: 30, contextAfter: 30, priority: .target)
        controller.archiveWindowApplyGeneration &+= 1
        let drained = expectation(description: "old mapped cache delivered to main")
        queue.async { DispatchQueue.main.async { drained.fulfill() } }
        gate.signal()
        await fulfillment(of: [drained], timeout: 3)

        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertEqual(controller.pendingOpenMessageRequest, explicit)
        XCTAssertNil(controller.savedPositionCachePresentationContext)
        XCTAssertEqual(navigationCompletions, 0)
    }

    func testCoveredTargetHiddenWhileCacheMappingWaitsCannotBeRevealed() async throws {
        let queue = controller.datasetMappingQueue
        let gate = DispatchSemaphore(value: 0)
        let blocked = expectation(description: "cache mapping queue blocked before visibility change")
        queue.async { blocked.fulfill(); _ = gate.wait(timeout: .now() + 3) }
        await fulfillment(of: [blocked], timeout: 1)
        defer { gate.signal() }
        XCTAssertTrue(presentCache())
        let target = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: cached.anchorPrimary))
        try realm.write { target.isLocallyHiddenByReport = true }
        let drained = expectation(description: "hidden frozen cache mapping delivered to main")
        queue.async { DispatchQueue.main.async { drained.fulfill() } }
        gate.signal()
        await fulfillment(of: [drained], timeout: 3)

        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertEqual(controller.pendingOpenMessageRequest, request)
        XCTAssertNil(controller.timelineSession?.verifiedScope)
        XCTAssertNil(controller.savedPositionCachePresentationContext)
        XCTAssertEqual(navigationCompletions, 0)
    }

    func testNewExplicitTargetRejectsPreviousSavedCacheWindow() {
        let oldGeneration = controller.archiveWindowApplyGeneration
        let oldIntentID = intent.id
        let explicit = ChatOpenMessageRequest(chatJid: peer, owner: owner, conversationType: .regular,
            anchor: request.anchor, highlight: true, markReadOnVisible: false, source: .search)
        controller.pendingOpenMessageRequest = explicit
        controller.initialTargetFirstFrameContext = .init(request: explicit, completion: {})
        controller.archiveWindowIntent = .init(conversation: intent.conversation, locator: intent.locator,
            contextBefore: 30, contextAfter: 30, priority: .target)
        controller.archiveWindowApplyGeneration &+= 1

        XCTAssertFalse(controller.presentSavedPositionCacheWindow(cached,
            expectedIntentID: oldIntentID, expectedApplyGeneration: oldGeneration))
        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertEqual(controller.pendingOpenMessageRequest, explicit)
        XCTAssertEqual(navigationCompletions, 0)
    }

    private func presentCache() -> Bool {
        controller.presentSavedPositionCacheWindow(cached,
            expectedIntentID: intent.id, expectedApplyGeneration: controller.archiveWindowApplyGeneration)
    }

    private func waitForNavigationCompletion() async throws {
        for _ in 0..<600 where navigationCompletions == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(navigationCompletions, 1)
    }

    private func frame(primary: String) -> CGRect? {
        guard let index = controller.datasource.firstIndex(where: { $0.primary == primary && !$0.isFakeMessage }) else { return nil }
        controller.messagesCollectionView.layoutIfNeeded()
        return controller.messagesCollectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: index))?.frame
    }
}
