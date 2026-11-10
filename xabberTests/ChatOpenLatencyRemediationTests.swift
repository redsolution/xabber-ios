import XCTest
import UIKit
import RealmSwift
@testable import xabber

/// Exercises the real chat opening boundary with an actor transport and a
/// controlled concurrent mapping queue. No account connects to a server.
@MainActor
final class ChatOpenLatencyRemediationTests: XCTestCase {
    private var previousConfiguration: Realm.Configuration!
    private var realm: Realm!
    private var owner = ""
    private let peer = "latency-peer@example.test"
    private var hostedController: ChatViewController?
    private var window: UIWindow?

    private var conversation: ArchiveConversationKey {
        .init(owner: owner, jid: peer, conversationType: .regular)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier: "ChatOpenLatency-\(UUID().uuidString)"
        )
        realm = try WRealm.safe()
        owner = "latency-owner-\(UUID().uuidString.lowercased())@example.test"
    }

    override func tearDown() {
        hostedController?.datasourceDidSetForTests = nil
        hostedController?.performTerminalChatResourceTeardownForTesting()
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        hostedController = nil
        realm = nil
        Realm.Configuration.defaultConfiguration = previousConfiguration
        previousConfiguration = nil
        super.tearDown()
    }

    func testLatestHistoryTransportStartsBeforeViewLoadingCanFinish() async throws {
        try await assertTransportStartsBeforeViewLoading(targetRequest: nil, expectedLocator: .latest)
    }

    func testExplicitTargetTransportStartsBeforeViewLoadingWithoutSubmittingLatest() async throws {
        let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "owned-explicit-target"))
        let request = ChatOpenMessageRequest(
            chatJid: peer, owner: owner, conversationType: .regular,
            anchor: .init(messagePrimary: nil, archivedId: cursor.rawValue, archiveCursor: cursor,
                messageId: nil, authorId: nil, bodyFingerprint: nil, sourceDate: nil),
            highlight: true, markReadOnVisible: false, source: .search
        )
        try await assertTransportStartsBeforeViewLoading(
            targetRequest: request, expectedLocator: .archiveID(cursor)
        )
    }

    func testSavedPositionTransportStartsBeforeViewLoadingWithoutSubmittingLatest() async throws {
        let cursor = try XCTUnwrap(ArchiveCursor(rawValue: "owned-saved-target"))
        let request = ChatOpenMessageRequest(
            chatJid: peer, owner: owner, conversationType: .regular,
            anchor: .init(messagePrimary: nil, archivedId: cursor.rawValue, archiveCursor: cursor,
                messageId: nil, authorId: nil, bodyFingerprint: nil, sourceDate: nil),
            highlight: false, markReadOnVisible: false, source: .savedVisiblePosition
        )
        try await assertTransportStartsBeforeViewLoading(
            targetRequest: request, expectedLocator: .archiveID(cursor))
    }

    func testUnreadBoundaryTransportStartsBeforeViewLoadingWithoutSubmittingLatest() async throws {
        let boundary = try XCTUnwrap(ArchiveCursor(rawValue: "owned-unread-boundary"))
        let request = ChatOpenMessageRequest(
            chatJid: peer, owner: owner, conversationType: .regular,
            anchor: .init(messagePrimary: nil, archivedId: boundary.rawValue, archiveCursor: boundary,
                messageId: nil, authorId: nil, bodyFingerprint: nil, sourceDate: nil),
            highlight: false, markReadOnVisible: false, source: .initialUnreadBoundary,
            targetResolution: .firstIncomingAfterBoundary(boundary.rawValue)
        )
        try await assertTransportStartsBeforeViewLoading(
            targetRequest: request, expectedLocator: .archiveID(boundary),
            expectedOwnedLocator: .firstUnread(after: boundary), expectedPageSize: 1)
    }

    func testUnresolvedReferenceDoesNotPrefetchAnUnrelatedLatestWindow() async throws {
        let unexpectedRequest = expectation(description: "unresolved route must not request latest")
        unexpectedRequest.isInverted = true
        let transport = ChatOpenLatencyTransport { unexpectedRequest.fulfill() }
        let engine = AccountArchiveEngine(owner: owner, repository: ChatOpenLatencyRepository(),
            transport: transport, admissionProvider: ChatOpenLatencyAdmission(), retryClock: .immediate)
        await engine.connectionDidBecomeReady(generation: 93)
        let account = Account(jid: owner, queue: DispatchQueue(label: "ChatOpenLatency-reference-account"))
        account.archiveEngine = engine
        let previousUsers = AccountManager.shared.users
        AccountManager.shared.users = previousUsers + [account]
        defer {
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
            AccountManager.shared.users = previousUsers
        }
        let controller = ChatViewController()
        configure(controller)
        hostedController = controller
        controller.pendingOpenMessageRequest = .init(
            chatJid: peer, owner: owner, conversationType: .regular,
            anchor: .init(messagePrimary: nil, archivedId: "opaque-stanza-reference",
                messageId: nil, authorId: nil, bodyFingerprint: nil, sourceDate: nil),
            highlight: true, markReadOnVisible: false, source: .search)

        controller.prepareArchiveEngineRequestBeforeLoadingViewIfNeeded()
        await fulfillment(of: [unexpectedRequest], timeout: 0.1)

        XCTAssertFalse(controller.isViewLoaded)
        XCTAssertNil(controller.archivePreparedOpenIntent,
            "Reference resolution retains authority to choose its eventual cursor")
        XCTAssertNil(controller.archiveEnginePresentationDemandID)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        await engine.connectionDidDisconnect()
        await transport.stop()
    }

    func testDirectTerminalTeardownRevokesEarlyDemandAndCannotRestartHistoryOnReconnect() async throws {
        let started = expectation(description: "early request is admitted before terminal teardown")
        started.assertForOverFulfill = false
        let transport = ChatOpenLatencyTransport { started.fulfill() }
        let repository = ChatOpenLatencyRepository()
        let engine = AccountArchiveEngine(owner: owner, repository: repository, transport: transport,
            admissionProvider: ChatOpenLatencyAdmission(), retryClock: .immediate)
        await engine.connectionDidBecomeReady(generation: 94)
        let account = Account(jid: owner, queue: DispatchQueue(label: "ChatOpenLatency-terminal-account"))
        account.archiveEngine = engine
        let previousUsers = AccountManager.shared.users
        AccountManager.shared.users = previousUsers + [account]
        let controller = ChatViewController()
        configure(controller)
        hostedController = controller
        defer {
            controller.stopArchiveEnginePresentationSubscription()
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
            AccountManager.shared.users = previousUsers
        }
        let context = controller.acceptChatOpenPerformanceTrace(purpose: .normalRoute)
        controller.prepareArchiveEngineRequestBeforeLoadingViewIfNeeded()
        let preparation = try XCTUnwrap(controller.archiveEnginePresentationDemandTask)
        await fulfillment(of: [started], timeout: 2)
        await preparation.value
        XCTAssertNotNil(controller.archivePreparedOpenIntent)
        XCTAssertNotNil(controller.archiveEnginePresentationDemandID)

        controller.performTerminalChatResourceTeardownForTesting()

        XCTAssertNil(controller.archivePreparedOpenIntent)
        XCTAssertNil(controller.archiveEnginePresentationDemandID)
        XCTAssertNil(controller.archiveEnginePresentationDemandTask)
        XCTAssertNil(controller.archiveEnginePresentationDemandEngine)
        XCTAssertNil(controller.archiveEnginePresentationDemandConversation)
        XCTAssertNil(controller.archiveInteractiveGateToken)
        XCTAssertFalse(controller.chatOpenPerformanceTraceLifecycle.isCurrent(context))
        // The request already on the wire may still finish storage accounting.
        // Terminal teardown removes its presentation/reconnect ownership only.
        await transport.completeWithEmptyReceipts()
        await engine.waitUntilIdleForTesting()
        let committed = await repository.committedRequestCount
        let detachedState = await engine.currentState(for: conversation)
        XCTAssertEqual(committed, 1)
        XCTAssertNil(detachedState)

        await engine.connectionDidDisconnect()
        await engine.connectionDidBecomeReady(generation: 95)
        await engine.waitUntilIdleForTesting()
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1,
            "A controller that reached its terminal boundary must not reopen history after reconnect")
        let reconnectedState = await engine.currentState(for: conversation)
        XCTAssertNil(reconnectedState)
        await engine.connectionDidDisconnect()
        await transport.stop()
    }

    func testActorSkeletonReplacesCancelledColdLatestCacheMappingBeforeFreshHistory() async throws {
        let primaries = try seedCachedMessages()
        let controller = try await makeHostedLatestController()
        let entered = expectation(description: "exclusive mapping barrier entered")
        let release = DispatchSemaphore(value: 0)
        controller.datasetMappingQueue.async(flags: .barrier) {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        await fulfillment(of: [entered], timeout: 1)
        defer { release.signal() }

        let published = expectation(description: "replacement local latest mapping is visible without MAM")
        published.assertForOverFulfill = false
        controller.datasourceDidSetForTests = { items in
            if items.contains(where: { $0.primary == primaries.last && !$0.isFakeMessage }) {
                published.fulfill()
            }
        }

        controller.setSkeletonVisible(true)
        let firstRequest = try XCTUnwrap(controller.archiveHistoryFailureFallbackRequestID)
        let mappingGeneration = controller.datasetMappingGeneration
        controller.receiveArchiveWindowState(.skeleton(reason: .unverifiedCoverage, target: .latest))
        XCTAssertGreaterThan(controller.datasetMappingGeneration, mappingGeneration,
            "The accepted actor state must actually cancel the first mapping")
        XCTAssertTrue(controller.showSkeletonObserver.value)
        release.signal()

        await fulfillment(of: [published], timeout: 3)
        try await settleStructuralPresentation(controller)
        XCTAssertNil(controller.archiveHistoryFailureFallbackRequestID)
        XCTAssertTrue(controller.archiveHistoryFailureFallbackIsVisible,
            "Cancelling \(firstRequest) must leave a replacement cache render for the current generation")
        XCTAssertFalse(controller.showSkeletonObserver.value)
        assertPresentationHasNoFreshAuthority(controller)
        assertLatestIsBottomAligned(controller)
    }

    #if DEBUG
    func testCachedVisibleAndFreshVerifiedReceiptsHaveDistinctNumericEventsInOneContext() async throws {
        guard DeviceQADiagnostics.shared.isEnabled else {
            throw XCTSkip("Run hosted tests with XABBER_DEVICE_QA_DIAGNOSTICS=1 to verify the existing opt-in file")
        }
        let primaries = try seedCachedMessages()
        let controller = try await makeHostedLatestController()
        let context = controller.acceptChatOpenPerformanceTrace(purpose: .normalRoute)
        let published = expectation(description: "cached rows applied before fresh coverage")
        published.assertForOverFulfill = false
        controller.datasourceDidSetForTests = { items in
            if items.contains(where: { $0.primary == primaries.last && !$0.isFakeMessage }) {
                published.fulfill()
            }
        }

        controller.setSkeletonVisible(true)
        await fulfillment(of: [published], timeout: 3)
        try await settleStructuralPresentation(controller)
        assertPresentationHasNoFreshAuthority(controller)
        XCTAssertFalse(controller.chatOpenPerformanceTraceLifecycle.hasRecordedPresentationReceipt(
            .content, context: context), "A cache frame must not stand in for fresh history completion")
        let cachedRows = try numericRows(context: context)
        XCTAssertEqual(cachedRows.filter { integer($0, "event") == 6 }.count, 1,
            "Event 6 records the first visible cached frame, independently of the fresh receipt")
        XCTAssertTrue(cachedRows.allSatisfy { integer($0, "event") != 2 })

        let freshness = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 92, queryID: "latency-fresh")
        let cursors = try (0..<80).map { try XCTUnwrap(ArchiveCursor(rawValue: "cache-\($0)")) }
        let segment = try XCTUnwrap(ArchiveCoverageSegment(orderedArchiveIDs: cursors,
            reachesArchiveStart: true, reachesLiveEdge: true,
            fingerprint: freshness.fingerprint, isVerified: true))
        try realm.write {
            let coverage = ConversationArchiveCoverageStorageItem.ensure(key: conversation, in: realm)
            coverage.segments = [segment]
            coverage.coverageGeneration = 8
            coverage.archiveFreshnessFingerprint = freshness.fingerprint
        }
        controller.receiveArchiveWindowState(.verified(.init(
            messagePrimaryIDs: primaries, target: .latest, verifiedSegment: segment,
            coverageGeneration: 8, freshnessToken: freshness)))
        for _ in 0..<400 {
            if try numericRows(context: context).contains(where: { integer($0, "event") == 2 }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let rows = try numericRows(context: context)
        let cached = rows.filter { integer($0, "event") == 6 }
        let fresh = rows.filter { integer($0, "event") == 2 }
        XCTAssertEqual(cached.count, 1)
        XCTAssertEqual(fresh.count, 1)
        if let cachedSequence = cached.first.flatMap({ integer($0, "seq") }),
           let freshSequence = fresh.first.flatMap({ integer($0, "seq") }) {
            XCTAssertLessThan(cachedSequence, freshSequence)
        }
        XCTAssertEqual(controller.archiveWindowCommittedCoverageGeneration, 8)
        XCTAssertNotNil(controller.committedTimelineScope())
        XCTAssertTrue(rows.allSatisfy { $0.values.allSatisfy { $0 is NSNumber } })
    }

    private func numericRows(context: ChatOpenPerformanceTraceContext) throws -> [[String: Any]] {
        DeviceQADiagnostics.shared.flush()
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DeviceQADiagnostics.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let conversationCode = DeviceQADiagnostics.shared.conversationCode(for: conversation)
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").compactMap { line in
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return integer(row, "context") == context.traceID &&
                integer(row, "conversation") == conversationCode ? row : nil
        }
    }

    private func integer(_ row: [String: Any], _ key: String) -> UInt64? {
        (row[key] as? NSNumber)?.uint64Value
    }
    #endif

    private func assertTransportStartsBeforeViewLoading(
        targetRequest: ChatOpenMessageRequest?, expectedLocator: ArchiveWindowLocator,
        expectedOwnedLocator: ArchiveWindowLocator? = nil, expectedPageSize: Int? = nil
    ) async throws {
        let started = expectation(description: "owned history request reaches fake transport")
        started.assertForOverFulfill = false
        let signal = DispatchSemaphore(value: 0)
        let transport = ChatOpenLatencyTransport {
            signal.signal()
            started.fulfill()
        }
        let engine = AccountArchiveEngine(owner: owner, repository: ChatOpenLatencyRepository(),
            transport: transport, admissionProvider: ChatOpenLatencyAdmission(), retryClock: .immediate)
        await engine.connectionDidBecomeReady(generation: 91)
        let account = Account(jid: owner, queue: DispatchQueue(label: "ChatOpenLatency-account"))
        account.archiveEngine = engine
        let previousUsers = AccountManager.shared.users
        AccountManager.shared.users = previousUsers + [account]
        defer {
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
            AccountManager.shared.users = previousUsers
        }

        let controller = ChatOpenLatencyHeldLoadController()
        configure(controller)
        hostedController = controller
        controller.pendingOpenMessageRequest = targetRequest
        controller.whileLoadingView = {
            signal.wait(timeout: .now() + 0.5) == .success
        }
        controller.acceptChatOpenPerformanceTrace(
            purpose: targetRequest == nil ? .normalRoute : .explicitTargetRoute)

        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844), completion: {})
        await fulfillment(of: [started], timeout: 2)
        let requests = await transport.requests
        XCTAssertTrue(controller.transportStartedWhileLoadingView,
            "History dispatch must run while main-thread view construction is still held")
        XCTAssertEqual(requests.count, 1, "Preparing the loaded UI must reuse the owned request")
        XCTAssertEqual(requests.first?.conversation, conversation)
        XCTAssertEqual(controller.archiveWindowIntent?.locator, expectedOwnedLocator ?? expectedLocator,
            "The presentation retains its accepted semantic target")
        XCTAssertEqual(requests.first?.locator, expectedLocator,
            "Early dispatch must use the accepted exact target, including explicit routes")
        if let expectedPageSize { XCTAssertEqual(requests.first?.pageSize, expectedPageSize) }
        controller.cancelStackedNavigationPresentationPreparation()
        controller.stopArchiveEnginePresentationSubscription()
        await engine.connectionDidDisconnect()
        await transport.stop()
    }

    private func makeHostedLatestController() async throws -> ChatViewController {
        let controller = ChatViewController()
        configure(controller)
        hostedController = controller
        let hostedWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window = hostedWindow
        hostedWindow.rootViewController = controller
        hostedWindow.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.stopArchiveEnginePresentationSubscription()
        let drained = expectation(description: "view setup mapping drained")
        controller.datasetMappingQueue.async(flags: .barrier) {
            DispatchQueue.main.async { drained.fulfill() }
        }
        await fulfillment(of: [drained], timeout: 2)
        controller.cancelDatasetMappingJobs()
        controller.archiveHistoryFailureVisibleSnapshot = nil
        controller.archiveHistoryFailureFallbackIsVisible = false
        controller.archiveHistoryFailureFallbackRequestID = nil
        controller.pendingOpenMessageRequest = nil
        controller.initialTargetFirstFrameContext = nil
        controller.timelineSession = ChatTimelineSession(
            store: RealmChatTimelineSessionStore(owner: owner, jid: peer, conversationType: .regular),
            pageSize: ArchivePageSizing.history,
            conversationKey: .init(owner: owner, jid: peer, conversationType: .regular),
            observesStoreImmediately: false)
        controller.archiveWindowStateTask = Task {}
        controller.archiveWindowIntent = .init(conversation: conversation, locator: .latest,
            contextBefore: ArchivePageSizing.initial, contextAfter: 0, priority: .visibleIntegrity)
        controller.archiveWindowState = .skeleton(reason: .opening, target: .latest)
        controller.showSkeletonObserver.accept(true)
        controller.applyChatDatasource([], mode: .fullReload(keepOffset: false), animated: false,
            suppressDefaultBottomScroll: true, presentationOwner: .archiveEngine)
        hostedWindow.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        return controller
    }

    private func configure(_ controller: ChatViewController) {
        controller.owner = owner
        controller.jid = peer
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: owner, displayName: owner)
        controller.opponentSender = Sender(id: peer, displayName: peer)
    }

    private func seedCachedMessages() throws -> [String] {
        let rows = (0..<80).map { index -> MessageStorageItem in
            let row = MessageStorageItem()
            row.messageId = "cached-\(index)"
            row.primary = MessageStorageItem.genPrimary(messageId: row.messageId, owner: owner)
            row.owner = owner; row.opponent = peer; row.conversationType = .regular
            row.archivedId = "cache-\(index)"; row.mamArchiveId = row.archivedId
            row.date = Date(timeIntervalSince1970: Double(1000 + index)); row.sentDate = row.date
            row.body = "Cached history row \(index), visible before remote freshness completes."
            row.legacyBody = row.body; row.state = .deliver
            row.historyPositionOrdinal = Int64(index + 1)
            return row
        }
        try realm.write {
            realm.add(rows)
            try ChatLocalHistoryLinkedIndex.rebuildConversation(
                owner: owner, jid: peer, conversationType: .regular, in: realm)
        }
        return rows.map(\.primary)
    }

    private func settleStructuralPresentation(_ controller: ChatViewController) async throws {
        for _ in 0..<400 where controller.isChatDatasourceStructuralTransactionActive {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        controller.messagesCollectionView.layoutIfNeeded()
        // Let the real CATransaction completion publish its presentation receipt.
        let committed = expectation(description: "main presentation transaction committed")
        DispatchQueue.main.async { committed.fulfill() }
        await fulfillment(of: [committed], timeout: 1)
    }

    private func assertPresentationHasNoFreshAuthority(_ controller: ChatViewController,
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(controller.committedTimelineScope(), file: file, line: line)
        XCTAssertNil(controller.archiveWindowCommittedCoverageGeneration, file: file, line: line)
        XCTAssertFalse(controller.canAdvanceReadStateFromVisiblePresentation(), file: file, line: line)
        XCTAssertFalse(controller.canRequestTimelineBoundary(direction: .older), file: file, line: line)
    }

    private func assertLatestIsBottomAligned(_ controller: ChatViewController,
        file: StaticString = #filePath, line: UInt = #line) {
        let collection = controller.messagesCollectionView
        let bottom = max(-collection.adjustedContentInset.top,
            collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom)
        XCTAssertEqual(collection.contentOffset.y, bottom, accuracy: 0.5, file: file, line: line)
    }
}

@MainActor
private final class ChatOpenLatencyHeldLoadController: ChatViewController {
    var whileLoadingView: (() -> Bool)?
    private(set) var transportStartedWhileLoadingView = false

    override func loadView() {
        transportStartedWhileLoadingView = whileLoadingView?() ?? false
        super.loadView()
    }
}

private actor ChatOpenLatencyAdmission: ArchiveConversationAdmissionProviding {
    func connectionDidBecomeReady(generation: UInt64) async {}
    func connectionDidDisconnect() async {}
    func admit(_ conversation: ArchiveConversationKey,
        connectionGeneration: UInt64) async throws -> ArchiveConversationAdmissionResult { .notRequired }
}

private actor ChatOpenLatencyRepository: ArchiveCoverageRepository {
    private(set) var committedRequestCount = 0
    func verifiedAdmission(for intent: ArchiveWindowIntent,
        freshnessToken: ArchiveFreshnessToken) async throws -> ArchiveRepositoryAdmission? { nil }
    func materializedAnchor(conversation: ArchiveConversationKey, locator: ArchiveWindowLocator,
        candidateArchiveIDs: [String]) async throws -> ArchiveMaterializedAnchor? { nil }
    func commit(_ page: ValidatedArchiveTransportPage, request: ArchiveTransportRequest,
        freshnessToken: ArchiveFreshnessToken) async throws -> ArchiveRepositoryCommit {
        committedRequestCount += 1
        return page.isAuthoritativeEmpty ? .authoritativeEmpty : .materializedWithoutCoverage
    }
    func commitAnchorWindow(intent: ArchiveWindowIntent, anchor: ArchiveMaterializedAnchor,
        exactPage: ValidatedArchiveTransportPage, olderPage: ValidatedArchiveTransportPage,
        newerPage: ValidatedArchiveTransportPage,
        freshnessToken: ArchiveFreshnessToken) async throws -> ArchiveWindowSnapshot {
        throw ArchiveTransportError.protocolViolation
    }
    func extendLiveEdge(for intent: ArchiveWindowIntent, primaryID: String,
        freshnessToken: ArchiveFreshnessToken) async throws -> ArchiveWindowSnapshot? { nil }
}

private actor ChatOpenLatencyTransport: ArchiveTransport {
    private let onRequest: @Sendable () -> Void
    private var continuations: [(ArchiveTransportRequest, CheckedContinuation<ArchiveTransportReceipt, Error>)] = []
    private var completesImmediately = false
    private(set) var requests: [ArchiveTransportRequest] = []

    init(onRequest: @escaping @Sendable () -> Void) { self.onRequest = onRequest }

    func request(_ request: ArchiveTransportRequest,
        priority: ArchiveIntentPriority) async throws -> ArchiveTransportReceipt {
        requests.append(request)
        onRequest()
        if completesImmediately { return emptyReceipt(for: request) }
        return try await withCheckedThrowingContinuation { continuations.append((request, $0)) }
    }
    func searchPage(_ request: ArchiveSearchTransportRequest,
        priority: ArchiveIntentPriority) async throws -> ArchiveSearchTransportReceipt {
        throw ArchiveTransportError.protocolViolation
    }
    func promote(descriptor: ArchiveIntentDescriptor, connectionGeneration: UInt64,
        to priority: ArchiveIntentPriority) async {}
    func stop() {
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.1.resume(throwing: ArchiveTransportError.disconnected) }
    }

    func completeWithEmptyReceipts() {
        completesImmediately = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.1.resume(returning: emptyReceipt(for: $0.0)) }
    }

    private func emptyReceipt(for request: ArchiveTransportRequest) -> ArchiveTransportReceipt {
        .init(queryID: request.queryID, connectionGeneration: request.connectionGeneration,
            resultArchiveIDs: [], messagePrimaryIDs: [], first: "", last: "", complete: true,
            cheapPageCount: 0, deliveredResultCount: 0, persistedResultCount: 0,
            intentionallyConsumedResultCount: 0, failedPersistenceCount: 0, finalReceived: true)
    }
}
