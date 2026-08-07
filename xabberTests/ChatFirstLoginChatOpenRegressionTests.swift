import XCTest
import UIKit
import RealmSwift
import XMPPFramework
@testable import xabber

private final class ChatRetryTransportEvidence: @unchecked Sendable {
    struct Snapshot {
        let queryId: String?
        let startCount: Int
    }

    private let lock = NSLock()
    private var queryId: String?
    private var startCount = 0

    func recordQuery(_ queryId: String) {
        lock.lock()
        self.queryId = queryId
        lock.unlock()
    }

    func recordStart() {
        lock.lock()
        startCount += 1
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(queryId: queryId, startCount: startCount)
    }
}

/// End-to-end contract seams for the first chat opening after account login.
///
/// Lower-level persistence and MAM ordering remain covered by their dedicated
/// suites. These tests keep the user-visible decision chain in one place:
/// local content, blocking skeleton, confirmed empty, or retry.
@MainActor
final class ChatFirstLoginChatOpenRegressionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
    }

    override func tearDown() {
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        super.tearDown()
    }

    func testDurablySyncedLocalRowsRenderContentWithoutStartingBootstrapArchive() {
        let loadingState = ChatBootstrapLoadingReducer.resolve(.init(
            messageCount: 80,
            isSynced: true,
            isInitialArchiveLoaded: true,
            isInitialBootstrapInFlight: false,
            hasPendingInitialAnchorRequest: false,
            allowsStaleLocalHistory: false,
            hasTerminalFailure: false
        ))

        XCTAssertEqual(loadingState, .content)
        XCTAssertFalse(MessageArchiveManager.ChatBootstrapRequestPolicy.shouldStartInitialBootstrap(
            isSynced: true,
            isInitialArchiveLoaded: true,
            localMessageCount: 80
        ))
    }

    func testLegacyReadyFlagsWithOldLocalRowAndMissingCurrentCoverageShowSkeletonAndStartRepair() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatStrictReadinessMissingCoverage-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "strict-readiness-owner@example.com"
        let jid = "strict-readiness-peer@example.com"
        let fixture = try insertLegacyReadyConversation(
            owner: owner,
            jid: jid,
            snapshotArchiveId: "900",
            unreadAfterArchiveId: "500",
            loadedRange: ("100", "100")
        )
        XCTAssertFalse(
            ConversationArchiveDurableReadinessPolicy.isReady(
                chat: fixture.chat,
                archiveState: fixture.archiveState,
                conversationType: .regular,
                localMessageCount: 1
            ),
            "legacy flags plus an unrelated old row must not prove the current snapshot"
        )

        let controller = makeController(owner: owner, jid: jid)
        controller.loadViewIfNeeded()
        controller.configureDataset()
        defer {
            controller.performTerminalChatResourceTeardownForTesting()
        }

        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        guard case .start(let repairLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "strict-readiness-live-repair",
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("inconsistent legacy readiness must reserve one repair lease")
        }
        XCTAssertTrue(controller.currentBootstrapRequiresArchiveConfirmation())
        XCTAssertEqual(controller.currentBootstrapLoadingState(), .blockingArchive)
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )
        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        let committedSkeletonPrimaries = controller.datasource.map(\.primary)
        let committedSkeletonOffset = controller.messagesCollectionView.contentOffset
        let committedSkeletonSize = controller.messagesCollectionView.contentSize

        controller.loadInitialDatasource()
        controller.loadInitialDatasource()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(controller.datasource.map(\.primary), committedSkeletonPrimaries)
        XCTAssertEqual(
            controller.messagesCollectionView.contentOffset.y,
            committedSkeletonOffset.y,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.messagesCollectionView.contentSize.height,
            committedSkeletonSize.height,
            accuracy: 0.001
        )
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 0)
        XCTAssertFalse(controller.hasCommittedRealContentInCurrentLifecycle)
        guard case .joined(let joinedLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "must-not-start-second-live-repair",
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("repeated lifecycle load must join the existing repair")
        }
        XCTAssertEqual(joinedLease.queryId, repairLease.queryId)
        XCTAssertTrue(coordinator.isActive(key: key, queryId: repairLease.queryId))
        XCTAssertTrue(coordinator.complete(key: key, queryId: repairLease.queryId))

        let manager = MessageArchiveManager(withOwner: owner)
        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: jid,
                conversationType: .regular,
                pageSize: 80,
                queryId: "strict-readiness-repair",
                target: .latest,
                callback: nil
            ),
            .bootstrapStarted(queryId: "strict-readiness-repair")
        )
    }

    func testCurrentSnapshotAndUnreadCoverageKeepLocalContentAndDoNotStartDuplicateRepair() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatStrictReadinessCurrentCoverage-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "strict-ready-owner@example.com"
        let jid = "strict-ready-peer@example.com"
        let fixture = try insertLegacyReadyConversation(
            owner: owner,
            jid: jid,
            snapshotArchiveId: "900",
            unreadAfterArchiveId: "500",
            loadedRange: ("100", "900")
        )
        XCTAssertTrue(
            ConversationArchiveDurableReadinessPolicy.isReady(
                chat: fixture.chat,
                archiveState: fixture.archiveState,
                conversationType: .regular,
                localMessageCount: 1
            )
        )

        let controller = makeController(owner: owner, jid: jid)
        controller.loadViewIfNeeded()
        controller.configureDataset()
        defer {
            controller.performTerminalChatResourceTeardownForTesting()
        }
        XCTAssertFalse(controller.currentBootstrapRequiresArchiveConfirmation())
        XCTAssertEqual(controller.currentBootstrapLoadingState(), .content)

        let manager = MessageArchiveManager(withOwner: owner)
        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: jid,
                conversationType: .regular,
                pageSize: 80,
                queryId: "must-not-start-duplicate-repair",
                target: .latest,
                callback: nil
            ),
            .noop
        )
        XCTAssertTrue(manager.callbacksQueue.isEmpty)
    }

    func testRetryClearsStaleFailureWhenForegroundArchiveReadinessIsAlreadySatisfied() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatForegroundRetryAlreadyReady-\(name)"
        )
        defer {
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "foreground-retry-ready-owner@example.com"
        let jid = "foreground-retry-ready-peer@example.com"
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: .regular
        )
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .regular
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        try realm.write {
            realm.add(chat, update: .modified)
            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: jid,
                conversationType: .regular,
                in: realm
            )
            archiveState.newerLiveEdgeReached = true
        }
        let controller = makeController(owner: owner, jid: jid)
        controller.loadViewIfNeeded()
        controller.configureDataset()
        defer {
            controller.performTerminalChatResourceTeardownForTesting()
        }
        controller.loadInitialDatasource()
        XCTAssertTrue(waitUntil {
            controller.currentInitialFrameReadinessProof()?
                .hasDurableArchiveReadiness == true
        })
        XCTAssertFalse(controller.currentBootstrapRequiresArchiveConfirmation())

        controller.appliedBootstrapLoadingState = .failure(fallback: .empty)
        controller.allowsBootstrapFailureFallback = true
        controller.setBootstrapFailureVisible(true)
        let retryButton = try XCTUnwrap(
            descendants(of: controller.bootstrapFailureView)
                .compactMap { $0 as? UIButton }
                .first { $0.accessibilityIdentifier == "chat.bootstrap.retry" }
        )

        retryButton.sendActions(for: .touchUpInside)

        XCTAssertFalse(
            controller.isInitialBootstrapInFlight,
            "durable foreground readiness must not manufacture another MAM lease"
        )
        XCTAssertNil(
            ChatInitialBootstrapRequestCoordinator.shared.readiness(
                for: controller.initialBootstrapRequestKey
            )
        )
        XCTAssertEqual(controller.appliedBootstrapLoadingState, .empty)
        XCTAssertTrue(controller.bootstrapFailureView.isHidden)
        XCTAssertFalse(controller.bootstrapFailureView.isRetrying)
        XCTAssertTrue(retryButton.isEnabled)
        XCTAssertFalse(controller.preservesBootstrapFailureOverlayUntilRetryCommit)
    }

    func testConfirmedEmptyWithoutKnownRemoteBoundaryDoesNotEnterRepairLoop() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatStrictReadinessConfirmedEmpty-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "strict-empty-owner@example.com"
        let jid = "strict-empty-peer@example.com"
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: .regular
        )
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .regular
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        var archiveState: RegularChatArchiveSyncStateStorageItem!
        try realm.write {
            realm.add(chat, update: .modified)
            archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: jid,
                conversationType: .regular,
                in: realm
            )
            archiveState.newerLiveEdgeReached = true
        }

        XCTAssertTrue(
            ConversationArchiveDurableReadinessPolicy.isReady(
                chat: chat,
                archiveState: archiveState,
                conversationType: .regular,
                localMessageCount: 0
            )
        )

        let controller = makeController(owner: owner, jid: jid)
        controller.loadViewIfNeeded()
        controller.configureDataset()
        defer {
            controller.performTerminalChatResourceTeardownForTesting()
        }
        controller.loadInitialDatasource()
        XCTAssertTrue(waitUntil {
            controller.currentInitialFrameReadinessProof()?
                .hasDurableArchiveReadiness == true
        }, "the off-main initial-frame proof must confirm durable empty history")
        XCTAssertFalse(controller.currentBootstrapRequiresArchiveConfirmation())
        XCTAssertEqual(controller.currentBootstrapLoadingState(), .empty)

        let manager = MessageArchiveManager(withOwner: owner)
        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: jid,
                conversationType: .regular,
                pageSize: 80,
                queryId: "must-not-repair-confirmed-empty",
                target: .latest,
                callback: nil
            ),
            .noop
        )
    }

    func testSnapshotMessageIdFallbackRequiresTheMaterializedLastMessage() {
        let chat = LastChatsStorageItem()
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        chat.lastMessageId = "different-message"
        let archiveState = RegularChatArchiveSyncStateStorageItem()
        archiveState.newerLiveEdgeReached = true
        archiveState.lastSnapshotMessageId = "snapshot-message"

        XCTAssertFalse(
            ConversationArchiveDurableReadinessPolicy.isReady(
                chat: chat,
                archiveState: archiveState,
                conversationType: .regular,
                localMessageCount: 1
            )
        )

        chat.lastMessageId = "snapshot-message"
        XCTAssertTrue(
            ConversationArchiveDurableReadinessPolicy.isReady(
                chat: chat,
                archiveState: archiveState,
                conversationType: .regular,
                localMessageCount: 1
            )
        )
    }

    func testUnsyncedKnownSnapshotCommitsThirtySkeletonRowsAndReservesOneArchiveTransaction() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.configureDataset()

        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )

        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertEqual(
            controller.messagesCollectionView.numberOfSections,
            controller.datasource.count,
            "the first-frame receipt must describe rows already committed to the collection view"
        )
        XCTAssertTrue(MessageArchiveManager.ChatBootstrapRequestPolicy.shouldStartInitialBootstrap(
            isSynced: false,
            isInitialArchiveLoaded: false,
            localMessageCount: 0,
            hasKnownRemoteBoundary: true
        ))

        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        let first = coordinator.acquire(
            key: key,
            proposedQueryId: "first-login-interactive",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let firstLease) = first else {
            controller.performTerminalChatResourceTeardownForTesting()
            return XCTFail("the first open must reserve the archive transaction")
        }

        let reopen = coordinator.acquire(
            key: key,
            proposedQueryId: "first-login-duplicate",
            timeout: 45
        ) { _, _, _ in }
        guard case .joined(let joinedLease) = reopen else {
            controller.performTerminalChatResourceTeardownForTesting()
            return XCTFail("a repeated open must join instead of reserving a duplicate transaction")
        }
        XCTAssertEqual(joinedLease.queryId, firstLease.queryId)

        XCTAssertTrue(coordinator.complete(key: key, queryId: firstLease.queryId))
        controller.performTerminalChatResourceTeardownForTesting()
    }

    func testPersistenceLeaseDominatesStaleReadyFlagsAndPreventsFalseEmptyState() {
        let loadingState = ChatBootstrapLoadingReducer.resolve(.init(
            messageCount: 0,
            isSynced: true,
            isInitialArchiveLoaded: true,
            isInitialBootstrapInFlight: false,
            hasPendingInitialAnchorRequest: false,
            allowsStaleLocalHistory: false,
            hasTerminalFailure: false,
            archiveReadiness: ConversationArchiveReadiness(
                phase: .persistence,
                hasDurableCoverage: false,
                confirmsEmptyConversation: false,
                persistedVisibleRowCount: 0
            )
        ))

        XCTAssertEqual(loadingState, .blockingArchive)
    }

    func testConfirmedEmptyRequiresCommittedDurableZeroResult() {
        let unproven = ChatBootstrapLoadingReducer.resolve(.init(
            messageCount: 0,
            isSynced: true,
            isInitialArchiveLoaded: true,
            isInitialBootstrapInFlight: false,
            hasPendingInitialAnchorRequest: false,
            allowsStaleLocalHistory: false,
            hasTerminalFailure: false,
            archiveReadiness: ConversationArchiveReadiness(
                phase: .committed,
                hasDurableCoverage: false,
                confirmsEmptyConversation: false,
                persistedVisibleRowCount: 0
            )
        ))
        let confirmedEmpty = ChatBootstrapLoadingReducer.resolve(.init(
            messageCount: 0,
            isSynced: true,
            isInitialArchiveLoaded: true,
            isInitialBootstrapInFlight: false,
            hasPendingInitialAnchorRequest: false,
            allowsStaleLocalHistory: false,
            hasTerminalFailure: false,
            archiveReadiness: ConversationArchiveReadiness(
                phase: .committed,
                hasDurableCoverage: true,
                confirmsEmptyConversation: true,
                persistedVisibleRowCount: 0
            )
        ))

        XCTAssertEqual(unproven, .blockingArchive)
        XCTAssertEqual(confirmedEmpty, .empty)
    }

    func testArchiveFailureProducesRetryStateInsteadOfPlainEmpty() {
        let loadingState = ChatBootstrapLoadingReducer.resolve(.init(
            messageCount: 0,
            isSynced: false,
            isInitialArchiveLoaded: false,
            isInitialBootstrapInFlight: false,
            hasPendingInitialAnchorRequest: false,
            allowsStaleLocalHistory: false,
            hasTerminalFailure: true,
            archiveReadiness: ConversationArchiveReadiness(
                phase: .failed,
                hasDurableCoverage: false,
                confirmsEmptyConversation: false,
                persistedVisibleRowCount: 0
            )
        ))

        XCTAssertEqual(loadingState, .failure(fallback: .empty))
        XCTAssertTrue(loadingState.showsRetry)
    }

    func testSnapshotRepairAndInteractiveOpenShareTheSameConversationLease() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "shared-lease-owner@example.com",
            jid: "shared-lease-peer@example.com",
            conversationType: .regular
        )
        let background = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "snapshot-repair-lease",
            timeout: 45,
            purpose: .snapshotRepair,
            observer: { _, _, _ in }
        )
        guard case .start(let snapshotLease) = background else {
            return XCTFail("snapshot repair must reserve the first lease")
        }

        let interactive = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "must-not-start-interactive-duplicate",
            timeout: 45,
            observer: { _, _, _ in }
        )
        guard case .joined(let joinedLease) = interactive else {
            return XCTFail("chat open must join the snapshot transaction")
        }

        XCTAssertEqual(joinedLease.queryId, snapshotLease.queryId)
        XCTAssertEqual(joinedLease.purpose, .snapshotRepair)
        XCTAssertEqual(
            key.schedulerDeduplicationKey,
            MessageArchiveManager.SnapshotRepairTarget(
                jid: key.jid,
                conversationType: .regular
            ).deduplicationKey(owner: key.owner)
        )
    }

    func testSnapshotPumpDelegatesPersistenceAndCommitToConversationCoordinator() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/xmpp/messages/message_archive/MessageArchiveManager.swift"
            ),
            encoding: .utf8
        )
        let methodStart = try XCTUnwrap(
            source.range(of: "private func enqueueSnapshotArchiveRepair(")
        )
        let methodEnd = try XCTUnwrap(
            source.range(
                of: "private func finishSnapshotRepairPump(",
                range: methodStart.upperBound..<source.endIndex
            )
        )
        let method = String(source[methodStart.lowerBound..<methodEnd.lowerBound])

        XCTAssertTrue(method.contains("acquireOrJoin("))
        XCTAssertTrue(method.contains("coordinator.observe("))
        XCTAssertTrue(method.contains("preparePersistenceSource("))
        XCTAssertFalse(method.contains("finishArchiveQueryBatchAsync("))
        XCTAssertFalse(method.contains("commitAfterPersistence("))
    }

    func testIdleBootstrapReleasesWireFromSynchronousRawFinalDispatcher() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/xmpp/messages/message_archive/MessageArchiveManager.swift"
            ),
            encoding: .utf8
        )
        let methodStart = try XCTUnwrap(
            source.range(of: "private func startNextRegularIdleBackfillIfNeeded()")
        )
        let methodEnd = try XCTUnwrap(
            source.range(
                of: "internal func archiveRequestGenerationSnapshot()",
                range: methodStart.upperBound..<source.endIndex
            )
        )
        let method = String(source[methodStart.lowerBound..<methodEnd.lowerBound])

        XCTAssertTrue(method.contains("MessageArchiveEndPageDispatcher.register("))
        XCTAssertTrue(method.contains("delivery: .synchronous"))
        XCTAssertTrue(method.contains("releaseWire()"))
    }

    private func makeController(
        owner: String = "first-login-owner@example.com",
        jid: String = "first-login-peer@example.com"
    ) -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Peer")
        controller.messagesCollectionView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.showSkeletonObserver.accept(true)
        return controller
    }

    private func insertLegacyReadyConversation(
        owner: String,
        jid: String,
        snapshotArchiveId: String,
        unreadAfterArchiveId: String,
        loadedRange: (first: String, last: String)
    ) throws -> (
        chat: LastChatsStorageItem,
        archiveState: RegularChatArchiveSyncStateStorageItem
    ) {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: .regular
        )
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .regular
        chat.messageDate = Date(timeIntervalSince1970: 100)
        chat.isSynced = true
        chat.isInitialArchiveLoaded = true
        chat.syncSnapshotLastArchiveId = snapshotArchiveId
        chat.syncUnreadCount = 1
        chat.syncUnreadAfterId = unreadAfterArchiveId

        let oldMessage = MessageStorageItem()
        oldMessage.primary = MessageStorageItem.genPrimary(
            messageId: "legacy-old-message",
            owner: owner
        )
        oldMessage.owner = owner
        oldMessage.opponent = jid
        oldMessage.conversationType = .regular
        oldMessage.messageId = "legacy-old-message"
        oldMessage.archivedId = "100"
        oldMessage.date = Date(timeIntervalSince1970: 100)

        var archiveState: RegularChatArchiveSyncStateStorageItem!
        try realm.write {
            realm.add(chat, update: .modified)
            realm.add(oldMessage, update: .modified)
            archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: jid,
                conversationType: .regular,
                in: realm
            )
            archiveState.lastSnapshotArchiveId = snapshotArchiveId
            archiveState.newerLiveEdgeReached = true
            archiveState.mergeLoadedRange(
                first: loadedRange.first,
                last: loadedRange.last,
                updateKind: .bootstrapNewest
            )
        }
        return (chat, archiveState)
    }
}

extension ChatFirstLoginChatOpenRegressionTests {
    func testLateContentSuccessAfterRetryCommitsOnceAndRemovesRetry() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatCoordinatorFailureRetryRegression-\(name)"
        )
        defer {
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "terminal-failure-owner@example.com"
        let jid = "terminal-failure-peer@example.com"
        try insertUnsyncedChat(owner: owner, jid: jid)
        let controller = makeController(
            owner: owner,
            jid: jid
        )
        controller.loadViewIfNeeded()
        controller.configureDataset()
        defer {
            controller.performanceFixtureArchiveTransportProvider = nil
            controller.performanceFixtureArchiveTransportExecutor = nil
            controller.performanceFixtureArchiveTransportDidStartHandler = nil
            controller.datasourceDidSetForTests = nil
            controller.performTerminalChatResourceTeardownForTesting()
        }
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )

        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        guard case .start(let failedLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "terminal-failure-query",
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("test setup must reserve a lease that can fail")
        }
        controller.beginInitialBootstrapTracking(
            queryId: failedLease.queryId,
            timeout: nil
        )
        let skeletonPrimariesBeforeFailure = controller.datasource.map(\.primary)
        XCTAssertEqual(skeletonPrimariesBeforeFailure.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))

        let failedMessages = MessageManager(withOwner: owner, activeStream: false)
        failedMessages.updateSendingMessagesTimer?.invalidate()
        failedMessages.updateSendingMessagesTimer = nil
        failedMessages.unsubscribeSender()
        defer {
            failedMessages.updateSendingMessagesTimer?.invalidate()
            failedMessages.updateSendingMessagesTimer = nil
            failedMessages.unsubscribeReceiver()
            failedMessages.unsubscribeSender()
        }
        failedMessages.archiveQueryIdPersistenceResolver = {
            $0 == failedLease.queryId
        }
        let failedMAM = MessageArchiveManager(withOwner: owner)
        let failedStream = XMPPStream()
        XCTAssertEqual(
            failedMAM.syncChat(
                failedStream,
                jid: jid,
                conversationType: .regular,
                pageSize: 80,
                queryId: failedLease.queryId,
                target: .latest,
                callback: nil
            ),
            .bootstrapStarted(queryId: failedLease.queryId)
        )
        coordinator.resolveStart(
            key: key,
            queryId: failedLease.queryId,
            result: .bootstrapStarted(queryId: failedLease.queryId),
            messages: failedMessages,
            archiveManager: failedMAM,
            cancelTransport: {}
        )
        controller.initialFramePresentationApplicationStateProvider = {
            .background
        }
        controller.handleApplicationDidEnterBackground()
        XCTAssertTrue(failedMAM.read(
            failedStream,
            withIQ: try archiveErrorIQ(queryId: failedLease.queryId)
        ))
        XCTAssertTrue(waitUntil {
            controller.appliedBootstrapLoadingState?.showsRetry == true &&
                !controller.bootstrapFailureView.isHidden
        })
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .failed)
        XCTAssertFalse(controller.isInitialBootstrapInFlight)
        let skeletonPrimariesAtRetry = controller.datasource.map(\.primary)
        XCTAssertEqual(skeletonPrimariesAtRetry, skeletonPrimariesBeforeFailure)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))

        let retryButtons = descendants(of: controller.bootstrapFailureView)
            .compactMap { $0 as? UIButton }
            .filter { $0.accessibilityIdentifier == "chat.bootstrap.retry" }
        XCTAssertEqual(retryButtons.count, 1)
        XCTAssertFalse(controller.bootstrapFailureView.isRetrying)
        XCTAssertTrue(retryButtons[0].isEnabled)

        controller.willEnterForeground()
        XCTAssertFalse(
            controller.isInitialFramePresentationLifecycleEligible,
            "willEnterForeground can arrive while UIApplication still reports background"
        )
        controller.initialFramePresentationApplicationStateProvider = { .active }
        controller.didBecomeActive()
        XCTAssertTrue(controller.isInitialFramePresentationLifecycleEligible)

        let successfulMessages = MessageManager(withOwner: owner, activeStream: false)
        successfulMessages.updateSendingMessagesTimer?.invalidate()
        successfulMessages.updateSendingMessagesTimer = nil
        successfulMessages.unsubscribeSender()
        defer {
            successfulMessages.updateSendingMessagesTimer?.invalidate()
            successfulMessages.updateSendingMessagesTimer = nil
            successfulMessages.unsubscribeReceiver()
            successfulMessages.unsubscribeSender()
        }
        let successfulMAM = MessageArchiveManager(withOwner: owner)
        let successfulStream = XMPPStream()
        let retryTransportQueue = DispatchQueue(
            label: "ChatLateSuccessRetryTransport"
        )
        defer {
            retryTransportQueue.sync {}
        }
        let retryTransportEvidence = ChatRetryTransportEvidence()
        controller.performanceFixtureArchiveTransportProvider = { request in
            guard request.kind == .initialBootstrap,
                  let queryId = request.queryIds.first else {
                return nil
            }
            retryTransportEvidence.recordQuery(queryId)
            successfulMessages.archiveQueryIdPersistenceResolver = {
                $0 == queryId
            }
            return ChatPerformanceFixtureArchiveTransportSession(
                stream: successfulStream,
                archiveManager: successfulMAM,
                messageManager: successfulMessages
            )
        }
        controller.performanceFixtureArchiveTransportExecutor = { work in
            retryTransportQueue.async(execute: work)
        }
        controller.performanceFixtureArchiveTransportDidStartHandler = { _ in
            retryTransportEvidence.recordStart()
        }

        retryButtons[0].sendActions(for: .touchUpInside)
        XCTAssertTrue(
            controller.bootstrapFailureView.isRetrying,
            "an accepted foreground Retry must acknowledge the tap immediately"
        )
        XCTAssertFalse(
            retryButtons[0].isEnabled,
            "the admitted single-flight retry must not remain visually actionable"
        )
        XCTAssertTrue(waitUntil {
            let evidence = retryTransportEvidence.snapshot
            guard let queryId = evidence.queryId else { return false }
            return evidence.startCount == 1 &&
                controller.initialBootstrapQueryId == queryId &&
                coordinator.isActive(key: key, queryId: queryId)
        })
        let retryEvidence = retryTransportEvidence.snapshot
        let retryQueryId = try XCTUnwrap(retryEvidence.queryId)
        XCTAssertEqual(retryEvidence.startCount, 1)
        XCTAssertNotEqual(retryQueryId, failedLease.queryId)
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .transport)
        XCTAssertEqual(controller.datasource.map(\.primary), skeletonPrimariesAtRetry)
        XCTAssertFalse(
            controller.bootstrapFailureView.isHidden,
            "Retry must remain the committed overlay until durable content replaces it"
        )
        retryButtons[0].sendActions(for: .touchUpInside)
        XCTAssertFalse(
            controller.bootstrapFailureView.isHidden,
            "Repeated Retry while the same transport is active must not expose an intermediate frame"
        )
        XCTAssertEqual(retryTransportEvidence.snapshot.startCount, 1)

        let envelope = try persistedArchiveResultMessage(
            owner: owner,
            peer: jid,
            queryId: retryQueryId,
            archiveId: "900",
            messageId: "late-success-message"
        )
        XCTAssertTrue(successfulMAM.recordDeferredArchiveResultDelivery(envelope))
        successfulMessages.receiveArchived(envelope)
        XCTAssertEqual(controller.datasource.map(\.primary), skeletonPrimariesAtRetry)
        XCTAssertFalse(controller.bootstrapFailureView.isHidden)

        var realDatasourceCommitCount = 0
        controller.datasourceDidSetForTests = { datasource in
            if datasource.contains(where: { !$0.isFakeMessage }) {
                realDatasourceCommitCount += 1
            }
        }
        let finalIQ = try archiveFinalIQ(
            queryId: retryQueryId,
            complete: true,
            count: 1,
            first: "900",
            last: "900"
        )
        XCTAssertTrue(successfulMAM.read(successfulStream, withIQ: finalIQ))

        XCTAssertTrue(waitUntil {
            controller.appliedBootstrapLoadingState == .content &&
                controller.bootstrapFailureView.isHidden &&
                !controller.isInitialBootstrapInFlight &&
                !controller.showSkeletonObserver.value &&
                controller.datasource.contains(where: { !$0.isFakeMessage })
        }, "a durable, materialized archive page must atomically replace Retry")
        XCTAssertEqual(realDatasourceCommitCount, 1)
        XCTAssertEqual(controller.datasource.filter { !$0.isFakeMessage }.count, 1)
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .committed)
        XCTAssertFalse(controller.bootstrapFailureView.isRetrying)
        XCTAssertTrue(retryButtons[0].isEnabled)

        let committedPrimaries = controller.datasource.map(\.primary)
        let committedGeneration = controller.timelineSession?.snapshot.generation
        _ = successfulMAM.read(successfulStream, withIQ: finalIQ)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(controller.datasource.map(\.primary), committedPrimaries)
        XCTAssertEqual(controller.timelineSession?.snapshot.generation, committedGeneration)
        XCTAssertEqual(realDatasourceCommitCount, 1)
        XCTAssertTrue(controller.bootstrapFailureView.isHidden)
    }

    func testPresentationFailureRetryKeepsOverlayAndRepeatedTapDoesNotStartParallelBootstrap() {
        let owner = "presentation-retry-owner@example.com"
        let jid = "presentation-retry-peer@example.com"
        let controller = makeController(owner: owner, jid: jid)
        controller.loadViewIfNeeded()
        let descriptor = ChatLocalFirstFrameDescriptor(
            target: .latest,
            request: nil
        )
        controller.initialLocalFirstFramePhase = .failedPresentation(descriptor)
        controller.appliedBootstrapLoadingState = .failure(fallback: .empty)
        controller.allowsBootstrapFailureFallback = true
        controller.setBootstrapFailureVisible(true)

        var localRetryScheduleCount = 0
        controller.initialLocalFirstFrameRetryScheduledForTests = {
            localRetryScheduleCount += 1
        }
        defer {
            controller.initialLocalFirstFrameRetryScheduledForTests = nil
            controller.cancelStackedNavigationPresentationPreparation()
            controller.performTerminalChatResourceTeardownForTesting()
        }

        controller.retryInitialBootstrapAfterFailure()

        XCTAssertEqual(localRetryScheduleCount, 1)
        XCTAssertTrue(controller.preservesBootstrapFailureOverlayUntilRetryCommit)
        XCTAssertFalse(controller.bootstrapFailureView.isHidden)
        XCTAssertFalse(controller.isInitialBootstrapInFlight)
        XCTAssertNil(
            ChatInitialBootstrapRequestCoordinator.shared.readiness(
                for: controller.initialBootstrapRequestKey
            )
        )

        controller.retryInitialBootstrapAfterFailure()

        XCTAssertEqual(
            localRetryScheduleCount,
            1,
            "Repeated Retry must join the local presentation retry"
        )
        XCTAssertTrue(controller.preservesBootstrapFailureOverlayUntilRetryCommit)
        XCTAssertFalse(controller.bootstrapFailureView.isHidden)
        XCTAssertFalse(controller.isInitialBootstrapInFlight)
        XCTAssertNil(
            ChatInitialBootstrapRequestCoordinator.shared.readiness(
                for: controller.initialBootstrapRequestKey
            ),
            "A repeated local presentation retry must not start a parallel MAM lease"
        )
    }

    func testTerminalTeardownClearsRetryOverlayAndPreservationOwnership() {
        let controller = makeController(
            owner: "retry-teardown-owner@example.com",
            jid: "retry-teardown-peer@example.com"
        )
        controller.loadViewIfNeeded()
        controller.appliedBootstrapLoadingState = .failure(fallback: .empty)
        controller.preservesBootstrapFailureOverlayUntilRetryCommit = true
        controller.setBootstrapFailureVisible(true)
        XCTAssertFalse(controller.bootstrapFailureView.isHidden)
        controller.bootstrapFailureView.setRetrying(true)
        XCTAssertTrue(controller.bootstrapFailureView.isRetrying)

        controller.performTerminalChatResourceTeardownForTesting()

        XCTAssertTrue(controller.bootstrapFailureView.isHidden)
        XCTAssertFalse(controller.bootstrapFailureView.isRetrying)
        XCTAssertFalse(controller.preservesBootstrapFailureOverlayUntilRetryCommit)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func insertUnsyncedChat(
        owner: String,
        jid: String,
        snapshotArchiveId: String? = nil,
        unreadAfterArchiveId: String? = nil
    ) throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: .regular
        )
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .regular
        chat.messageDate = Date()
        chat.isSynced = false
        chat.isInitialArchiveLoaded = false
        chat.syncSnapshotLastArchiveId = snapshotArchiveId
        if let unreadAfterArchiveId {
            chat.syncUnreadCount = 1
            chat.syncUnreadAfterId = unreadAfterArchiveId
        }
        try realm.write {
            realm.add(chat, update: .modified)
            let state = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: jid,
                conversationType: .regular,
                in: realm
            )
            state.lastSnapshotArchiveId = snapshotArchiveId
            state.newerLiveEdgeReached = false
        }
    }

    private func archiveFinalIQ(
        queryId: String,
        complete: Bool,
        count: Int,
        first: String,
        last: String
    ) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: """
        <iq type='result' id='\(queryId)'>
          <fin xmlns='urn:xmpp:mam:2' complete='\(complete ? "true" : "false")' queryid='\(queryId)'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>\(count)</count>
              <first>\(first)</first>
              <last>\(last)</last>
            </set>
          </fin>
        </iq>
        """, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }

    private func persistedArchiveResultMessage(
        owner: String,
        peer: String,
        queryId: String,
        archiveId: String,
        messageId: String
    ) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: """
        <message to='\(owner)' from='\(owner)'>
          <result xmlns='urn:xmpp:mam:2' queryid='\(queryId)' id='\(archiveId)'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message xmlns='jabber:client' from='\(peer)' to='\(owner)' type='chat' id='\(messageId)'>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='\(archiveId)'/>
                <origin-id xmlns='urn:xmpp:sid:0' id='\(messageId)'/>
                <body>late durable success</body>
              </message>
              <delay xmlns='urn:xmpp:delay' from='example.com' stamp='2026-08-01T10:00:00Z'/>
            </forwarded>
          </result>
        </message>
        """, options: 0)
        return try XMPPMessage(from: XCTUnwrap(document.rootElement()))
    }

    private func archiveErrorIQ(queryId: String) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: """
        <iq type='error' id='\(queryId)'>
          <fin xmlns='urn:xmpp:mam:2' queryid='\(queryId)'/>
          <error type='wait'>
            <service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
          </error>
        </iq>
        """, options: 0)
        return try XMPPIQ(from: XCTUnwrap(document.rootElement()))
    }
}


final class ChatInteractiveOpenGateRegressionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        ChatRemoteHistoryCompletionCoordinator.resetPersistenceFlushesForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
    }

    override func tearDown() {
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        ChatRemoteHistoryCompletionCoordinator.resetPersistenceFlushesForTests()
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        super.tearDown()
    }

    func testGateIsReferenceCountedAndNeverOutlivesFiveSecondBudget() {
        let becameInactive = expectation(description: "gate expires")
        let gate = AccountInteractiveChatOpenGate(
            maximumDuration: 0.05,
            onChange: { isActive in
                if !isActive {
                    becameInactive.fulfill()
                }
            }
        )

        let first = gate.acquire()
        let second = gate.acquire()

        XCTAssertTrue(gate.isActive)
        XCTAssertEqual(gate.activeTokenCount, 2)
        XCTAssertTrue(gate.release(first))
        XCTAssertTrue(gate.isActive)
        XCTAssertEqual(gate.activeTokenCount, 1)

        wait(for: [becameInactive], timeout: 1)
        XCTAssertFalse(gate.isActive)
        XCTAssertEqual(gate.activeTokenCount, 0)
        XCTAssertFalse(gate.release(second), "an expired token must already be terminal")
    }

    func testGateHardExpiryDoesNotDependOnMainQueueProgress() {
        let becameInactive = expectation(description: "gate expires off main")
        let gate = AccountInteractiveChatOpenGate(
            maximumDuration: 0.03,
            onChange: { isActive in
                if !isActive {
                    becameInactive.fulfill()
                }
            }
        )

        _ = gate.acquire()
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertFalse(gate.isActive)
        wait(for: [becameInactive], timeout: 1)
    }

    func testLaterTokenCannotExtendTheAccountGateBeyondItsOriginalBudget() {
        let becameInactive = expectation(description: "shared gate window expires")
        let startedAt = CFAbsoluteTimeGetCurrent()
        let gate = AccountInteractiveChatOpenGate(
            maximumDuration: 0.2,
            onChange: { isActive in
                if !isActive {
                    becameInactive.fulfill()
                }
            }
        )

        _ = gate.acquire()
        Thread.sleep(forTimeInterval: 0.12)
        let laterToken = gate.acquire()

        wait(for: [becameInactive], timeout: 1)
        XCTAssertLessThan(
            CFAbsoluteTimeGetCurrent() - startedAt,
            0.27,
            "repeated opens must not extend one account's background pause beyond the original 5-second window"
        )
        XCTAssertFalse(gate.isActive)
        XCTAssertFalse(gate.release(laterToken))
    }

    func testArchiveOperationTraceSamplingPreservesCorrelationAndDropsStrings() {
        let lock = NSLock()
        var lines: [String] = []
        ChatArchiveDebugTrace.configureForTesting(
            enabled: true,
            sampleEvery: 2
        ) { line in
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        defer {
            ChatArchiveDebugTrace.resetTestingConfiguration()
        }

        ChatArchiveDebugTrace.logOperation(
            "archiveLoadEnqueue",
            traceID: 1,
            [
                ("purposeCode", 1),
                ("owner", "must-not-appear@example.com")
            ]
        )
        ChatArchiveDebugTrace.logOperation(
            "archiveLoadEnqueue",
            traceID: 2,
            [
                ("purposeCode", 1),
                ("phaseCode", 1),
                ("waitMs", 0),
                ("hasPredecessor", false),
                ("queryId", "must-not-appear")
            ]
        )
        ChatArchiveDebugTrace.logOperation(
            "archiveLoadCommit",
            traceID: 2,
            [
                ("purposeCode", 1),
                ("phaseCode", 4),
                ("waitMs", 27),
                ("hasPredecessor", false)
            ]
        )

        lock.lock()
        let captured = lines
        lock.unlock()
        XCTAssertEqual(captured.count, 2)
        XCTAssertTrue(captured.allSatisfy { $0.contains("traceID=2") })
        XCTAssertTrue(captured.allSatisfy { $0.contains("purposeCode=1") })
        XCTAssertTrue(captured.contains { $0.contains("phaseCode=1") })
        XCTAssertTrue(captured.contains { $0.contains("phaseCode=4") })
        XCTAssertFalse(captured.joined().contains("must-not-appear"))
        XCTAssertFalse(captured.joined().contains("owner="))
        XCTAssertFalse(captured.joined().contains("queryId="))
    }

    func testConversationTraceLinksRetryToItsPredecessorWithoutIdentifiers() {
        let lock = NSLock()
        var lines: [String] = []
        ChatArchiveDebugTrace.configureForTesting(
            enabled: true,
            sampleEvery: 1
        ) { line in
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        defer {
            ChatArchiveDebugTrace.resetTestingConfiguration()
        }

        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "private-owner@example.com",
            jid: "private-peer@example.com",
            conversationType: .regular
        )
        guard case .start(let firstLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "private-query-one",
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("first operation must start")
        }
        XCTAssertTrue(coordinator.recordFailure(
            key: key,
            event: MessageArchiveRequestFailureEvent(
                owner: key.owner,
                queryId: firstLease.queryId,
                streamKind: .primary,
                reason: .requestStartFailed,
                errorDescription: nil,
                pendingQueryCount: 1
            ),
            publishEvent: false
        ))
        coordinator.clearTerminal(key: key)
        guard case .start = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "private-query-two",
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("retry operation must start")
        }

        lock.lock()
        let captured = lines
        lock.unlock()
        let retryEnqueue = try? XCTUnwrap(
            captured.last(where: { $0.contains("event=archiveLoadEnqueue") })
        )
        XCTAssertNotNil(retryEnqueue)
        XCTAssertTrue(retryEnqueue?.contains("traceID=2") == true)
        XCTAssertTrue(retryEnqueue?.contains("hasPredecessor=true") == true)
        XCTAssertTrue(retryEnqueue?.contains("predecessorTraceID=1") == true)
        XCTAssertFalse(captured.joined().contains(key.owner))
        XCTAssertFalse(captured.joined().contains(key.jid))
        XCTAssertFalse(captured.joined().contains("private-query"))
    }

    func testAccountGatePausesOnlyPlannedBackgroundWorkAndDoesNotAffectAnotherAccount() {
        var firstAccountGateActive = true
        let backgroundStateLock = NSLock()
        var didStartBlockedBackground = false
        let firstScheduler = AccountXMPPTaskScheduler(
            configuration: .test(defaultMaxConcurrent: 2, defaultCooldown: 0),
            interactiveChatOpenGate: { firstAccountGateActive }
        )
        let secondScheduler = AccountXMPPTaskScheduler(
            configuration: .test(defaultCooldown: 0),
            interactiveChatOpenGate: { false }
        )

        firstScheduler.enqueue(
            priority: .background,
            resource: .avatar,
            deduplicationKey: "first.background"
        ) { finish in
            backgroundStateLock.lock()
            didStartBlockedBackground = true
            backgroundStateLock.unlock()
            finish()
        }

        let foregroundStarted = expectation(description: "same-account foreground continues")
        firstScheduler.enqueue(
            priority: .foreground,
            resource: .vcard,
            deduplicationKey: "first.foreground"
        ) { finish in
            foregroundStarted.fulfill()
            finish()
        }

        let otherAccountStarted = expectation(description: "other account remains isolated")
        secondScheduler.enqueue(
            priority: .background,
            resource: .avatar,
            deduplicationKey: "second.background"
        ) { finish in
            otherAccountStarted.fulfill()
            finish()
        }

        wait(for: [foregroundStarted, otherAccountStarted], timeout: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        backgroundStateLock.lock()
        let startedWhileGated = didStartBlockedBackground
        backgroundStateLock.unlock()
        XCTAssertFalse(startedWhileGated)

        firstAccountGateActive = false
        firstScheduler.interactiveChatOpenGateDidChange()
        XCTAssertTrue(waitUntil {
            backgroundStateLock.lock()
            let result = didStartBlockedBackground
            backgroundStateLock.unlock()
            return result
        }
        )
    }

    func testUnreadSavedAndLatestTargetsProduceDifferentPlansButShareConversationLease() {
        XCTAssertEqual(
            ConversationArchiveLoadPurpose.interactiveBootstrap.persistencePriority,
            .interactive
        )
        XCTAssertEqual(
            ConversationArchiveLoadPurpose.snapshotRepair.persistencePriority,
            .background
        )
        let boundary = "1711283295000000"
        let savedDate = Date(timeIntervalSince1970: 1_711_283_295)
        let latestTarget = MessageArchiveManager.ChatBootstrapPageTarget.latest
        let unreadTarget = MessageArchiveManager.ChatBootstrapPageTarget.firstUnread(
            afterArchiveId: boundary
        )
        let savedTarget = MessageArchiveManager.ChatBootstrapPageTarget.savedPosition(
            messagePrimary: "saved-primary",
            archivedId: "1711283294000000",
            messageId: "saved-message",
            sourceDate: savedDate
        )

        let latestPlan = MessageArchiveManager.regularBootstrapRequestPlan(
            jid: "peer@example.com",
            pageSize: 80,
            target: latestTarget
        )
        let unreadPlan = MessageArchiveManager.regularBootstrapRequestPlan(
            jid: "peer@example.com",
            pageSize: 80,
            target: unreadTarget
        )
        let savedPlan = MessageArchiveManager.regularBootstrapRequestPlan(
            jid: "peer@example.com",
            pageSize: 80,
            target: savedTarget
        )

        XCTAssertEqual(latestPlan.nextPage, "")
        XCTAssertNil(latestPlan.prevPage)
        XCTAssertNil(latestPlan.start)
        XCTAssertNil(latestPlan.end)

        XCTAssertNil(unreadPlan.nextPage)
        XCTAssertEqual(unreadPlan.prevPage, boundary)
        XCTAssertEqual(unreadPlan.coverageUpdateKind, .pageNewer(cursorArchiveId: boundary))

        XCTAssertNil(savedPlan.nextPage)
        XCTAssertNil(savedPlan.prevPage)
        XCTAssertEqual(savedPlan.ids, ["1711283294000000"])
        XCTAssertNil(savedPlan.start)
        XCTAssertNil(savedPlan.end)
        XCTAssertEqual(savedPlan.coverageUpdateKind, .disjointWindow)
        XCTAssertEqual(savedPlan.max, 1)
        XCTAssertTrue(savedPlan.usesServerArchiveId)

        let conversationKey = ChatInitialBootstrapRequestKey(
            owner: "owner@example.com",
            jid: "peer@example.com",
            conversationType: .regular
        )
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let latestFingerprint = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: latestTarget,
            boundary: nil
        )
        let unreadFingerprint = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: unreadTarget,
            boundary: nil
        )
        let first = coordinator.acquireOrJoin(
            key: conversationKey,
            proposedQueryId: "latest-query",
            timeout: 45,
            purpose: .snapshotRepair,
            targetFingerprint: latestFingerprint,
            observer: { _, _, _ in }
        )
        let second = coordinator.acquireOrJoin(
            key: conversationKey,
            proposedQueryId: "must-not-run-in-parallel",
            timeout: 45,
            targetFingerprint: unreadFingerprint,
            observer: { _, _, _ in }
        )
        guard case .start(let firstLease) = first,
              case .joined(let joinedLease) = second else {
            return XCTFail("a target change must join the conversation single-flight")
        }
        _ = coordinator.acquireOrJoin(
            key: conversationKey,
            proposedQueryId: "background-must-not-override-interactive-target",
            timeout: 45,
            purpose: .snapshotRepair,
            targetFingerprint: latestFingerprint,
            observer: { _, _, _ in }
        )
        XCTAssertEqual(firstLease.queryId, joinedLease.queryId)
        XCTAssertEqual(firstLease.purpose, .snapshotRepair)
        XCTAssertEqual(firstLease.targetFingerprint, latestFingerprint)
        XCTAssertEqual(
            coordinator.pendingFollowUpTarget(for: conversationKey),
            unreadFingerprint
        )
        let pendingInteractiveTarget = coordinator.pendingFollowUpRequest(
            for: conversationKey
        )
        XCTAssertEqual(
            ChatInitialBootstrapFollowUpTargetPolicy.target(
                coordinatorRequest: pendingInteractiveTarget
            ),
            unreadTarget
        )
        XCTAssertFalse(
            ChatInitialBootstrapFollowUpTargetPolicy.consumesSnapshotRepairBudget(
                coordinatorRequest: pendingInteractiveTarget
            )
        )

        coordinator.recordCommittedPageForTesting(
            key: conversationKey,
            queryId: firstLease.queryId,
            hasDurableCoverage: true,
            resultCount: 1
        )
        XCTAssertFalse(coordinator.readiness(for: conversationKey)?.hasDurableCoverage ?? true)
        XCTAssertTrue(coordinator.acknowledgeCommittedReceipt(
            key: conversationKey,
            queryId: firstLease.queryId
        ))
        let targetFollowUp = coordinator.acquireOrJoin(
            key: conversationKey,
            proposedQueryId: "unread-follow-up",
            timeout: 45,
            targetFingerprint: unreadFingerprint,
            observer: { _, _, _ in }
        )
        guard case .start(let unreadLease) = targetFollowUp else {
            return XCTFail("the requested unread target must run after the joined predecessor")
        }
        XCTAssertEqual(unreadLease.targetFingerprint.target, unreadTarget)
        XCTAssertEqual(
            ChatInitialBootstrapFollowUpTargetPolicy.target(
                coordinatorRequest: nil
            ),
            .latest
        )
        XCTAssertTrue(
            ChatInitialBootstrapFollowUpTargetPolicy.consumesSnapshotRepairBudget(
                coordinatorRequest: nil
            )
        )
    }

    func testSavedPositionBootstrapUsesMessageIdBeforeDateAndDateOnlyAsFallback() {
        let savedDate = Date(timeIntervalSince1970: 1_711_283_295)
        let messageIdPlan = MessageArchiveManager.regularBootstrapRequestPlan(
            jid: "peer@example.com",
            pageSize: 80,
            target: .savedPosition(
                messagePrimary: "saved-primary",
                archivedId: nil,
                messageId: "saved-message",
                sourceDate: savedDate
            )
        )

        XCTAssertEqual(messageIdPlan.ids, ["saved-message"])
        XCTAssertNil(messageIdPlan.start)
        XCTAssertNil(messageIdPlan.end)
        XCTAssertEqual(messageIdPlan.max, 1)
        XCTAssertFalse(messageIdPlan.usesServerArchiveId)
        XCTAssertEqual(messageIdPlan.coverageUpdateKind, .disjointWindow)

        let dateFallbackPlan = MessageArchiveManager.regularBootstrapRequestPlan(
            jid: "peer@example.com",
            pageSize: 80,
            target: .savedPosition(
                messagePrimary: "saved-primary",
                archivedId: nil,
                messageId: nil,
                sourceDate: savedDate
            )
        )

        XCTAssertNil(dateFallbackPlan.ids)
        XCTAssertEqual(
            dateFallbackPlan.start,
            savedDate.addingTimeInterval(-ChatAnchorFetchPolicy.windowPadding)
        )
        XCTAssertEqual(
            dateFallbackPlan.end,
            savedDate.addingTimeInterval(ChatAnchorFetchPolicy.windowPadding)
        )
        XCTAssertEqual(dateFallbackPlan.max, 80)
        XCTAssertFalse(dateFallbackPlan.usesServerArchiveId)
        XCTAssertEqual(dateFallbackPlan.coverageUpdateKind, .disjointWindow)
    }

    func testTargetRowsStayVisibleWhileLatestCoverageFollowUpRuns() {
        XCTAssertFalse(ChatInitialBootstrapCompletionPolicy.shouldFinish(
            didReceiveEndPage: true,
            hasMessages: true,
            didConfirmEmpty: false,
            isMessagePipelineIdle: true,
            isArchivePagePersisted: true,
            hasCommittedContent: false,
            requiresObserverSettle: false,
            didObservePostIdleTick: false
        ))
        XCTAssertTrue(ChatInitialBootstrapCompletionPolicy.shouldFinish(
            didReceiveEndPage: true,
            hasMessages: true,
            didConfirmEmpty: false,
            isMessagePipelineIdle: true,
            isArchivePagePersisted: true,
            hasCommittedContent: true,
            requiresObserverSettle: false,
            didObservePostIdleTick: false
        ))
        XCTAssertEqual(
            ChatBootstrapCoverageFollowUpPresentationPolicy.loadingState(
                hasCommittedTargetRows: true
            ),
            .content
        )
        XCTAssertEqual(
            ChatBootstrapCoverageFollowUpPresentationPolicy.loadingState(
                hasCommittedTargetRows: false
            ),
            .blockingArchive
        )
        XCTAssertFalse(
            ChatBootstrapCoverageFollowUpPresentationPolicy.shouldRefreshDatasource(
                isLatestCoverageFollowUp: true,
                isSupersededByPendingTarget: false,
                hasCommittedTargetRows: true,
                hasPersistedPageContent: true
            ),
            "coverage repair must not replace the target-aligned page with a latest-aligned page"
        )
        XCTAssertTrue(
            ChatBootstrapCoverageFollowUpPresentationPolicy.shouldRefreshDatasource(
                isLatestCoverageFollowUp: false,
                isSupersededByPendingTarget: false,
                hasCommittedTargetRows: false,
                hasPersistedPageContent: true
            )
        )
    }

    func testSameLatestPendingFollowUpMaterializesPersistedFirstPageBeforeRepair() {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatSameLatestFollowUpPresentation-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let controller = makeController(
            owner: "same-latest-owner@example.com",
            jid: "same-latest-peer@example.com"
        )
        controller.loadViewIfNeeded()
        controller.configureDataset()
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )
        defer {
            controller.performTerminalChatResourceTeardownForTesting()
        }

        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        let latestFingerprint = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: .latest,
            boundary: nil
        )
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "same-latest-first-page",
            timeout: 45,
            purpose: .interactiveBootstrap,
            targetFingerprint: latestFingerprint,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("the first latest page must own a fresh lease")
        }
        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: false,
            resultCount: 80,
            confirmsEmptyConversation: false,
            hasPresentationMaterialization: true,
            recommendedFollowUpTarget: .latest
        )

        controller.initialBootstrapQueryId = lease.queryId
        controller.initialBootstrapLeaseKey = key
        controller.initialBootstrapTargetFingerprint = latestFingerprint
        controller.isInitialBootstrapInFlight = true

        XCTAssertTrue(controller.handleInitialBootstrapEndPageIfNeeded(
            queryId: lease.queryId,
            state: MessageArchivePageEndState(
                queryExhausted: false,
                archiveEnded: false,
                persistedMessageCount: 80
            ),
            count: 80,
            persistedMessageCount: 80,
            persistedRowsForQuery: 80,
            visibleRowsForConversation: 80
        ))

        XCTAssertEqual(
            controller.initialBootstrapScopedRefreshQueryId,
            lease.queryId,
            "a same-target coverage repair must wait behind materialization of the persisted first page"
        )
        XCTAssertTrue(
            controller.isInitialBootstrapInFlight,
            "the first lease remains presentation-active until its atomic frame receipt"
        )
        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.initialFirstContentApplyCount, 0)
    }

    func testDifferentPendingTargetStillSupersedesPersistedLatestPage() {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatDifferentPendingTargetPresentation-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let controller = makeController(
            owner: "different-target-owner@example.com",
            jid: "different-target-peer@example.com"
        )
        controller.loadViewIfNeeded()
        controller.configureDataset()
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )
        defer {
            controller.performTerminalChatResourceTeardownForTesting()
        }

        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        let latestFingerprint = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: .latest,
            boundary: nil
        )
        let unreadTarget = MessageArchiveManager.ChatBootstrapPageTarget
            .firstUnread(afterArchiveId: "unread-boundary")
        let unreadFingerprint = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: unreadTarget,
            boundary: nil
        )
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "latest-before-unread-target",
            timeout: 45,
            purpose: .snapshotRepair,
            targetFingerprint: latestFingerprint,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("the latest page must own a fresh lease")
        }
        guard case .joined = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "pending-unread-target",
            timeout: 45,
            purpose: .interactiveBootstrap,
            targetFingerprint: unreadFingerprint,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("the requested unread target must join as a follow-up")
        }
        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: false,
            resultCount: 80,
            confirmsEmptyConversation: false,
            hasPresentationMaterialization: true
        )

        controller.initialBootstrapQueryId = lease.queryId
        controller.initialBootstrapLeaseKey = key
        controller.initialBootstrapTargetFingerprint = latestFingerprint
        controller.isInitialBootstrapInFlight = true

        XCTAssertTrue(controller.handleInitialBootstrapEndPageIfNeeded(
            queryId: lease.queryId,
            state: MessageArchivePageEndState(
                queryExhausted: false,
                archiveEnded: false,
                persistedMessageCount: 80
            ),
            count: 80,
            persistedMessageCount: 80,
            persistedRowsForQuery: 80,
            visibleRowsForConversation: 80
        ))

        XCTAssertNil(
            controller.initialBootstrapScopedRefreshQueryId,
            "a page for a different target must not replace the requested unread frame"
        )
        XCTAssertFalse(controller.isInitialBootstrapInFlight)
        XCTAssertEqual(controller.initialBootstrapFollowUpTargetOverride, unreadTarget)
        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
    }

    func testTargetJoiningRetainedCommittedReceiptNotifiesAndStartsFollowUp() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "retained-target-owner@example.com",
            jid: "retained-target-peer@example.com",
            conversationType: .regular
        )
        let latestFingerprint = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: .latest,
            boundary: nil
        )
        let savedFingerprint = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: .savedPosition(
                messagePrimary: "saved-primary",
                archivedId: "500",
                messageId: "saved-message",
                sourceDate: Date(timeIntervalSince1970: 500)
            ),
            boundary: nil
        )
        guard case .start(let latestLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "retained-latest",
            timeout: 45,
            purpose: .snapshotRepair,
            targetFingerprint: latestFingerprint,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("latest request must reserve the conversation lease")
        }
        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: latestLease.queryId,
            hasDurableCoverage: true,
            resultCount: 1
        )

        var observedReadiness: [ConversationArchiveReadiness?] = []
        let observation = coordinator.observe(key: key) {
            observedReadiness.append($0)
        }
        defer {
            coordinator.detach(key: key, observation: observation)
        }

        guard case .joined(let joinedLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "must-join-retained-receipt",
            timeout: 45,
            purpose: .interactiveBootstrap,
            targetFingerprint: savedFingerprint,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("a new target must join the retained conversation receipt")
        }
        XCTAssertEqual(joinedLease.queryId, latestLease.queryId)
        XCTAssertEqual(
            coordinator.pendingFollowUpTarget(for: key),
            savedFingerprint
        )
        XCTAssertFalse(
            coordinator.readiness(for: key)?.hasDurableCoverage ?? true,
            "the retained page cannot be terminal presentation proof for a different target"
        )
        XCTAssertTrue(ChatInitialBootstrapCompletionPolicy.shouldFinish(
            didReceiveEndPage: true,
            hasMessages: true,
            didConfirmEmpty: false,
            isMessagePipelineIdle: true,
            isArchivePagePersisted: true,
            hasCommittedContent: false,
            isSupersededByDifferentTarget: true,
            requiresObserverSettle: false,
            didObservePostIdleTick: false
        ))
        XCTAssertFalse(
            ChatBootstrapCoverageFollowUpPresentationPolicy.shouldRefreshDatasource(
                isLatestCoverageFollowUp: false,
                isSupersededByPendingTarget: true,
                hasCommittedTargetRows: false,
                hasPersistedPageContent: true
            )
        )
        XCTAssertEqual(observedReadiness.count, 2)
        let latestObservedReadiness = observedReadiness.compactMap { $0 }.last
        XCTAssertEqual(latestObservedReadiness?.phase, .committed)
        XCTAssertFalse(latestObservedReadiness?.hasDurableCoverage ?? true)

        XCTAssertTrue(coordinator.acknowledgeCommittedReceipt(
            key: key,
            queryId: latestLease.queryId
        ))
        guard case .start(let targetLease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "saved-follow-up",
            timeout: 45,
            purpose: .interactiveBootstrap,
            targetFingerprint: savedFingerprint,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("acknowledging the superseded receipt must admit the target request")
        }
        XCTAssertEqual(targetLease.targetFingerprint, savedFingerprint)
    }

    func testPendingTargetAdmitsArchiveRequestAfterDurableRetainedReceipt() {
        XCTAssertFalse(ChatInitialBootstrapRequestAdmissionPolicy.shouldAcquire(
            requiresArchiveConfirmation: false,
            hasUncommittedLease: false,
            hasPendingTargetPage: false
        ))
        XCTAssertTrue(ChatInitialBootstrapRequestAdmissionPolicy.shouldAcquire(
            requiresArchiveConfirmation: false,
            hasUncommittedLease: false,
            hasPendingTargetPage: true
        ))
    }

    func testPrimarySchedulerUnavailableTerminatesActiveBootstrapLease() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "xabber/controllers/chats/chat/rx/ChatViewController+HighPrioritySubscribtions.swift"
            ),
            encoding: .utf8
        )
        let enqueueStart = try XCTUnwrap(
            source.range(
                of: "let enqueuePrimaryTransport: (Account) -> Void"
            )
        )
        let enqueueEnd = try XCTUnwrap(
            source.range(
                of: "let transport = ChatInitialBootstrapTransportPolicy.resolve",
                range: enqueueStart.upperBound..<source.endIndex
            )
        )
        let enqueueBody = source[enqueueStart.lowerBound..<enqueueEnd.lowerBound]
        XCTAssertTrue(enqueueBody.contains("unavailable:"))
        XCTAssertTrue(enqueueBody.contains("streamKind: .primary"))
        XCTAssertTrue(enqueueBody.contains("reason: .requestStartFailed"))
        XCTAssertTrue(enqueueBody.contains("coordinator.recordFailure("))
    }

    func testSavedAndTruncatedUnreadPagesDoNotClaimNewestReadiness() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatTargetCoverageRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        XCTAssertFalse(MessageArchiveManager.bootstrapPageReachesNewestLiveEdge(
            coverageUpdateKind: .disjointWindow,
            queryExhausted: true
        ))
        XCTAssertFalse(MessageArchiveManager.bootstrapPageReachesNewestLiveEdge(
            coverageUpdateKind: .pageNewer(cursorArchiveId: "100"),
            queryExhausted: false
        ))

        let savedOwner = "saved-target-owner@example.com"
        let savedJid = "saved-target-peer@example.com"
        try insertUnsyncedChat(
            owner: savedOwner,
            jid: savedJid,
            snapshotArchiveId: "900"
        )
        let savedManager = MessageArchiveManager(withOwner: savedOwner)
        let savedQueryId = "saved-target-query"
        XCTAssertEqual(
            savedManager.syncChat(
                XMPPStream(),
                jid: savedJid,
                conversationType: .regular,
                pageSize: 80,
                queryId: savedQueryId,
                target: .savedPosition(
                    messagePrimary: "saved-primary",
                    archivedId: "500",
                    messageId: "saved-message",
                    sourceDate: Date(timeIntervalSince1970: 500)
                ),
                callback: nil
            ),
            .bootstrapStarted(queryId: savedQueryId)
        )
        XCTAssertTrue(savedManager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQ(
                queryId: savedQueryId,
                complete: true,
                count: 1,
                first: "500",
                last: "500"
            )
        ))
        XCTAssertEqual(
            savedManager.commitAfterPersistence(
                queryId: savedQueryId,
                persistenceSummary: persistenceSummary(
                    owner: savedOwner,
                    jid: savedJid,
                    visibleRows: 1,
                    persistedArchiveIds: ["500"]
                )
            ),
            .committedNeedsFollowUpRepair
        )
        try assertChatReadinessIsFalse(
            owner: savedOwner,
            jid: savedJid,
            expectedNewestCoverage: false
        )

        let unreadOwner = "unread-target-owner@example.com"
        let unreadJid = "unread-target-peer@example.com"
        try insertUnsyncedChat(
            owner: unreadOwner,
            jid: unreadJid,
            snapshotArchiveId: "900",
            unreadAfterArchiveId: "100"
        )
        let unreadManager = MessageArchiveManager(withOwner: unreadOwner)
        let unreadQueryId = "unread-target-query"
        XCTAssertEqual(
            unreadManager.syncChat(
                XMPPStream(),
                jid: unreadJid,
                conversationType: .regular,
                pageSize: 80,
                queryId: unreadQueryId,
                target: .firstUnread(afterArchiveId: "100"),
                callback: nil
            ),
            .bootstrapStarted(queryId: unreadQueryId)
        )
        XCTAssertTrue(unreadManager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQ(
                queryId: unreadQueryId,
                complete: false,
                count: 81,
                first: "101",
                last: "180"
            )
        ))
        XCTAssertEqual(
            unreadManager.commitAfterPersistence(
                queryId: unreadQueryId,
                persistenceSummary: persistenceSummary(
                    owner: unreadOwner,
                    jid: unreadJid,
                    visibleRows: 80,
                    persistedArchiveIds: ["101", "180"]
                )
            ),
            .committedNeedsFollowUpRepair
        )
        try assertChatReadinessIsFalse(
            owner: unreadOwner,
            jid: unreadJid,
            expectedNewestCoverage: false
        )
    }

    func testSnapshotRepairZeroDeliveredPageWithNonzeroServerCountRequiresLatestMaterialization() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatSnapshotZeroDeliveryRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "snapshot-zero-owner@example.com"
        let jid = "snapshot-zero-peer@example.com"
        let archiveCursor = "500"
        try insertUnsyncedChat(
            owner: owner,
            jid: jid,
            snapshotArchiveId: archiveCursor
        )
        let realm = try WRealm.safe()
        try realm.write {
            let state = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: jid,
                conversationType: .regular,
                in: realm
            )
            state.mergeLoadedRange(
                first: archiveCursor,
                last: archiveCursor,
                updateKind: .bootstrapNewest
            )
            state.newerLiveEdgeReached = false
        }

        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "snapshot-zero-delivered"
        XCTAssertEqual(
            manager.startSnapshotArchiveRepair(
                XMPPStream(),
                target: .init(jid: jid, conversationType: .regular),
                queryId: queryId
            ),
            queryId
        )
        XCTAssertTrue(manager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQ(
                queryId: queryId,
                complete: true,
                count: 81,
                first: "",
                last: ""
            )
        ))

        let persistenceSummary = MessageManager.ArchivePersistenceSummary()
        XCTAssertEqual(
            manager.commitAfterPersistence(
                queryId: queryId,
                persistenceSummary: persistenceSummary
            ),
            .committedNeedsFollowUpRepair,
            """
            RSM count is the server result-set size, so the after-cursor page
            proves the live edge. It does not prove that a zero-row local
            timeline is presentable; a newest-page materialization must follow.
            """
        )

        realm.refresh()
        let chat = try XCTUnwrap(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: .regular
            )
        ))
        let archiveState = try XCTUnwrap(realm.object(
            ofType: RegularChatArchiveSyncStateStorageItem.self,
            forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: .regular
            )
        ))
        XCTAssertFalse(chat.isSynced)
        XCTAssertFalse(chat.isInitialArchiveLoaded)
        XCTAssertTrue(archiveState.newerLiveEdgeReached)
        XCTAssertTrue(archiveState.containsArchiveId(archiveCursor))
        let consumerProof = try XCTUnwrap(
            manager.consumeCommittedArchiveConsumerProof(queryId: queryId)
        )
        XCTAssertEqual(consumerProof.deliveredResultCount, 0)
        XCTAssertEqual(consumerProof.serverResultCount, 81)
        XCTAssertFalse(consumerProof.confirmsEmptyConversation)
        XCTAssertFalse(consumerProof.hasPresentationMaterialization)
        XCTAssertEqual(
            consumerProof.recommendedFollowUpTarget,
            .latest
        )
    }

    func testContinuesRequestTerminatesEmptyDeliveredPageDespiteNonzeroServerCount() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatContinuesEmptyPageRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "continues-empty-owner@example.com"
        let jid = "continues-empty-peer@example.com"
        let queryId = "continues-empty-query"
        let requestedCursor = "older-page-cursor"
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        var receivedCount: Int?
        var receivedState: MessageArchivePageEndState?
        let endPageExpectation = expectation(
            description: "empty delivered page terminates"
        )

        manager.requestArchive(
            stream,
            jid: jid,
            isContinues: true,
            conversationType: .regular,
            purpose: .pageOlder,
            queryId: queryId,
            nextPage: requestedCursor,
            deferCoverageCommitUntilConsumerProof: true,
            requestCallbacks: .init(
                onEndPage: { _, state, _, _, count in
                    receivedState = state
                    receivedCount = count
                    endPageExpectation.fulfill()
                }
            )
        )

        let disposition = MessageArchiveManager.archivePageFinalDisposition(
            deliveredResultCount: 0,
            serverResultCount: 81,
            complete: false,
            requestedPageCursor: requestedCursor,
            responseLastCursor: nil
        )
        XCTAssertEqual(disposition.deliveredResultCount, 0)
        XCTAssertEqual(disposition.serverResultCount, 81)
        XCTAssertTrue(disposition.queryExhausted)
        XCTAssertFalse(disposition.shouldContinue)

        XCTAssertTrue(manager.read(
            stream,
            withIQ: try archiveFinalIQ(
                queryId: queryId,
                complete: false,
                count: 81,
                first: "",
                last: ""
            )
        ))
        wait(for: [endPageExpectation], timeout: 1)
        XCTAssertEqual(
            receivedCount,
            0,
            "RSM count is archive cardinality metadata, not this page's delivered row count"
        )
        XCTAssertTrue(receivedState?.queryExhausted ?? false)
    }

    func testDeferredBootstrapMaterializationDetectsExistingRealmRowWithEmptyQuerySummary() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatExistingMaterializationRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "existing-materialization-owner@example.com"
        let jid = "existing-materialization-peer@example.com"
        let queryId = "existing-materialization-query"
        try insertUnsyncedChat(owner: owner, jid: jid)

        let existingMessage = MessageStorageItem()
        existingMessage.primary = MessageStorageItem.genPrimary(
            messageId: "existing-materialization-message",
            owner: owner
        )
        existingMessage.owner = owner
        existingMessage.opponent = jid
        existingMessage.conversationType = .regular
        existingMessage.messageId = "existing-materialization-message"
        existingMessage.archivedId = "existing-materialization-archive-id"
        existingMessage.date = Date(timeIntervalSince1970: 1)
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(existingMessage, update: .modified)
        }

        let manager = MessageArchiveManager(withOwner: owner)
        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: jid,
                conversationType: .regular,
                pageSize: 80,
                queryId: queryId,
                callback: nil
            ),
            .bootstrapStarted(queryId: queryId)
        )
        XCTAssertTrue(manager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQ(
                queryId: queryId,
                complete: true,
                count: 0,
                first: "",
                last: ""
            )
        ))
        XCTAssertEqual(
            manager.commitAfterPersistence(
                queryId: queryId,
                persistenceSummary: MessageManager.ArchivePersistenceSummary()
            ),
            .committed
        )

        let proof = try XCTUnwrap(
            manager.consumeCommittedArchiveConsumerProof(queryId: queryId)
        )
        XCTAssertTrue(proof.hasPresentationMaterialization)
        XCTAssertFalse(proof.confirmsEmptyConversation)
        XCTAssertNil(proof.recommendedFollowUpTarget)
    }

    func testTargetedBootstrapZeroRowsRequiresLatestMaterialization() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatTargetedZeroMaterializationRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "targeted-zero-owner@example.com"
        let jid = "targeted-zero-peer@example.com"
        try insertUnsyncedChat(
            owner: owner,
            jid: jid,
            snapshotArchiveId: "900",
            unreadAfterArchiveId: "100"
        )
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "targeted-zero-query"
        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: jid,
                conversationType: .regular,
                pageSize: 80,
                queryId: queryId,
                target: .firstUnread(afterArchiveId: "100"),
                callback: nil
            ),
            .bootstrapStarted(queryId: queryId)
        )
        XCTAssertTrue(manager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQ(
                queryId: queryId,
                complete: true,
                count: 81,
                first: "",
                last: ""
            )
        ))

        XCTAssertEqual(
            manager.commitAfterPersistence(
                queryId: queryId,
                persistenceSummary: MessageManager.ArchivePersistenceSummary()
            ),
            .committedNeedsFollowUpRepair
        )
        let proof = try XCTUnwrap(
            manager.consumeCommittedArchiveConsumerProof(queryId: queryId)
        )
        XCTAssertFalse(proof.hasPresentationMaterialization)
        XCTAssertFalse(proof.confirmsEmptyConversation)
        XCTAssertEqual(proof.recommendedFollowUpTarget, .latest)
        try assertChatReadinessIsFalse(
            owner: owner,
            jid: jid,
            expectedNewestCoverage: true
        )
    }

    func testSnapshotLatestFollowUpForcesNewestTransportInsteadOfRepeatingAfterCursor() {
        XCTAssertEqual(
            MessageArchiveManager.SnapshotArchiveRepairTransportTarget
                .followUpTarget(
                    current: .incremental,
                    recommended: .latest,
                    hasNewSnapshotGeneration: false
                ),
            .latest
        )
        XCTAssertEqual(
            MessageArchiveManager.SnapshotArchiveRepairTransportTarget
                .followUpTarget(
                    current: .latest,
                    recommended: .latest,
                    hasNewSnapshotGeneration: true
                ),
            .incremental,
            "a genuinely new snapshot starts a fresh incremental generation"
        )

        let incrementalPlan = MessageArchiveManager.snapshotRepairRequestPlan(
            jid: "snapshot-plan-peer@example.com",
            conversationType: .regular,
            newestLoadedArchiveId: "500",
            pageSize: 80,
            transportTarget: .incremental
        )
        let latestPlan = MessageArchiveManager.snapshotRepairRequestPlan(
            jid: "snapshot-plan-peer@example.com",
            conversationType: .regular,
            newestLoadedArchiveId: "500",
            pageSize: 80,
            transportTarget: .latest
        )

        XCTAssertNil(incrementalPlan.nextPage)
        XCTAssertEqual(incrementalPlan.prevPage, "500")
        XCTAssertEqual(
            incrementalPlan.coverageUpdateKind,
            .pageNewer(cursorArchiveId: "500")
        )

        XCTAssertEqual(latestPlan.nextPage, "")
        XCTAssertNil(latestPlan.prevPage)
        XCTAssertEqual(latestPlan.coverageUpdateKind, .bootstrapNewest)
    }

    func testSnapshotLatestTransportCanCommitConfirmedEmpty() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatSnapshotLatestEmptyRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "snapshot-latest-empty-owner@example.com"
        let jid = "snapshot-latest-empty-peer@example.com"
        try insertUnsyncedChat(owner: owner, jid: jid)
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "snapshot-latest-empty-query"
        XCTAssertEqual(
            manager.startSnapshotArchiveRepair(
                XMPPStream(),
                target: .init(jid: jid, conversationType: .regular),
                queryId: queryId,
                transportTarget: .latest
            ),
            queryId
        )
        XCTAssertTrue(manager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQ(
                queryId: queryId,
                complete: true,
                count: 0,
                first: "",
                last: ""
            )
        ))

        XCTAssertEqual(
            manager.commitAfterPersistence(
                queryId: queryId,
                persistenceSummary: MessageManager.ArchivePersistenceSummary()
            ),
            .committed
        )
        let proof = try XCTUnwrap(
            manager.consumeCommittedArchiveConsumerProof(queryId: queryId)
        )
        XCTAssertTrue(proof.confirmsEmptyConversation)
        XCTAssertFalse(proof.hasPresentationMaterialization)
        XCTAssertNil(proof.recommendedFollowUpTarget)
        try assertNewestReadinessIsTrue(owner: owner, jid: jid)
    }

    func testSnapshotLatestTransportReachesLiveEdgeWhenOlderArchiveRemains() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatSnapshotLatestNonterminalPageRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "snapshot-latest-page-owner@example.com"
        let jid = "snapshot-latest-page-peer@example.com"
        try insertUnsyncedChat(
            owner: owner,
            jid: jid,
            snapshotArchiveId: "80"
        )
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "snapshot-latest-page-query"
        XCTAssertEqual(
            manager.startSnapshotArchiveRepair(
                XMPPStream(),
                target: .init(jid: jid, conversationType: .regular),
                queryId: queryId,
                transportTarget: .latest
            ),
            queryId
        )
        for resultId in ["80", "1"] {
            XCTAssertTrue(manager.recordDeferredArchiveResultDelivery(
                try archiveResultMessage(
                    queryId: queryId,
                    resultId: resultId
                )
            ))
        }
        XCTAssertTrue(manager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQ(
                queryId: queryId,
                complete: false,
                count: 81,
                first: "80",
                last: "1"
            )
        ))

        XCTAssertEqual(
            manager.commitAfterPersistence(
                queryId: queryId,
                persistenceSummary: persistenceSummary(
                    owner: owner,
                    jid: jid,
                    visibleRows: 2,
                    persistedArchiveIds: ["80", "1"]
                )
            ),
            .committed,
            """
            A forced newest page reaches the live edge even when older archive
            rows remain. It must not schedule another latest repair or leave
            first-open presentation in skeleton/retry.
            """
        )
        let proof = try XCTUnwrap(
            manager.consumeCommittedArchiveConsumerProof(queryId: queryId)
        )
        XCTAssertTrue(proof.hasPresentationMaterialization)
        XCTAssertNil(proof.recommendedFollowUpTarget)
        try assertNewestReadinessIsTrue(owner: owner, jid: jid)
    }

    func testBootstrapFinalWithoutOptionalRSMCountStillCommitsConfirmedEmpty() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatOptionalRSMCountRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "optional-count-owner@example.com"
        let jid = "optional-count-peer@example.com"
        try insertUnsyncedChat(owner: owner, jid: jid)
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "optional-count-query"
        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: jid,
                conversationType: .regular,
                pageSize: 80,
                queryId: queryId,
                callback: nil
            ),
            .bootstrapStarted(queryId: queryId)
        )
        XCTAssertTrue(manager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQWithoutCount(
                queryId: queryId,
                complete: true
            )
        ))
        XCTAssertEqual(
            manager.commitAfterPersistence(
                queryId: queryId,
                persistenceSummary: MessageManager.ArchivePersistenceSummary()
            ),
            .committed
        )
        let proof = try XCTUnwrap(
            manager.consumeCommittedArchiveConsumerProof(queryId: queryId)
        )
        XCTAssertNil(proof.serverResultCount)
        XCTAssertEqual(proof.deliveredResultCount, 0)
        XCTAssertTrue(proof.confirmsEmptyConversation)
    }

    func testCoordinatorCarriesInvisiblePageOlderTargetIntoNextLease() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "follow-up-owner@example.com",
            jid: "follow-up-peer@example.com",
            conversationType: .regular
        )
        let acquisition = coordinator.acquire(
            key: key,
            proposedQueryId: "invisible-page",
            timeout: 45
        ) { _, _, _ in }
        guard case .start(let lease) = acquisition else {
            return XCTFail("expected a fresh lease")
        }

        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: false,
            resultCount: 80,
            confirmsEmptyConversation: false,
            recommendedFollowUpTarget: .older(beforeArchiveId: "1")
        )

        let followUp = coordinator.pendingFollowUpRequest(for: key)
        XCTAssertEqual(followUp?.fingerprint.target, .older(beforeArchiveId: "1"))
        XCTAssertEqual(followUp?.purpose, .interactiveBootstrap)
        XCTAssertFalse(
            coordinator.readiness(for: key)?.hasDurableCoverage ?? true
        )
        XCTAssertFalse(
            coordinator.readiness(for: key)?.confirmsEmptyConversation ?? true
        )
    }

    func testCoordinatorSynthesizesLatestFollowUpForCommittedPageWithoutPresentationProof() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "materialization-owner@example.com",
            jid: "materialization-peer@example.com",
            conversationType: .regular
        )
        let acquisition = coordinator.acquire(
            key: key,
            proposedQueryId: "materialization-query",
            timeout: 45,
            purpose: .snapshotRepair
        ) { _, _, _ in }
        guard case .start(let lease) = acquisition else {
            return XCTFail("expected a fresh snapshot lease")
        }

        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: true,
            resultCount: 0,
            confirmsEmptyConversation: false,
            hasPresentationMaterialization: false
        )

        let readiness = coordinator.readiness(for: key)
        XCTAssertEqual(readiness?.phase, .committed)
        XCTAssertFalse(readiness?.hasDurableCoverage ?? true)
        XCTAssertFalse(readiness?.confirmsEmptyConversation ?? true)
        XCTAssertEqual(
            coordinator.pendingFollowUpRequest(for: key)?.fingerprint.target,
            .latest
        )
        XCTAssertEqual(
            coordinator.pendingFollowUpRequest(for: key)?.purpose,
            .snapshotRepair
        )
    }

    func testGenericLatestRepairCannotReplaceQueuedInteractiveUnreadTarget() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "follow-up-precedence-owner@example.com",
            jid: "follow-up-precedence-peer@example.com",
            conversationType: .regular
        )
        let latestFingerprint = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: .latest,
            boundary: nil
        )
        let unreadTarget = MessageArchiveManager.ChatBootstrapPageTarget
            .firstUnread(afterArchiveId: "unread-boundary")
        let unreadFingerprint = MessageArchiveManager.ChatBootstrapTargetFingerprint(
            target: unreadTarget,
            boundary: nil
        )

        let background = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "background-latest",
            timeout: 45,
            purpose: .snapshotRepair,
            targetFingerprint: latestFingerprint,
            observer: { _, _, _ in }
        )
        guard case .start(let lease) = background else {
            return XCTFail("snapshot repair must own the first lease")
        }
        guard case .joined = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "interactive-unread",
            timeout: 45,
            purpose: .interactiveBootstrap,
            targetFingerprint: unreadFingerprint,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("interactive open must join the conversation lease")
        }

        coordinator.recordCommittedPageForTesting(
            key: key,
            queryId: lease.queryId,
            hasDurableCoverage: false,
            resultCount: 0,
            confirmsEmptyConversation: false,
            hasPresentationMaterialization: false
        )

        let followUp = coordinator.pendingFollowUpRequest(for: key)
        XCTAssertEqual(followUp?.fingerprint, unreadFingerprint)
        XCTAssertEqual(followUp?.purpose, .interactiveBootstrap)
    }

    func testJoiningBackgroundPersistencePromotesRegisteredBatchToInteractive() {
        let coordinator = ChatInitialBootstrapRequestCoordinator(
            automaticallySchedulesTimeouts: false
        )
        let key = ChatInitialBootstrapRequestKey(
            owner: "persistence-promotion-owner@example.com",
            jid: "persistence-promotion-peer@example.com",
            conversationType: .regular
        )
        let manager = MessageManager(withOwner: key.owner, activeStream: false)
        manager.updateSendingMessagesTimer?.invalidate()
        manager.updateSendingMessagesTimer = nil
        manager.unsubscribeSender()
        manager.unsubscribeReceiver()
        defer {
            _ = coordinator.complete(
                key: key,
                queryId: "background-persistence",
                unregisterPersistenceSource: true
            )
        }

        let background = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "background-persistence",
            timeout: 45,
            purpose: .snapshotRepair,
            observer: { _, _, _ in }
        )
        guard case .start(let lease) = background else {
            return XCTFail("snapshot repair must own the first lease")
        }
        coordinator.preparePersistenceSource(
            key: key,
            queryId: lease.queryId,
            messages: manager
        )
        manager.archivePersistenceSchedulingLock.lock()
        let priorityBeforeOpen =
            manager.archivePersistencePriorityByQueryId[lease.queryId]
        manager.archivePersistenceSchedulingLock.unlock()
        XCTAssertEqual(priorityBeforeOpen, .background)

        guard case .joined = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "interactive-must-join",
            timeout: 45,
            purpose: .interactiveBootstrap,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("interactive open must join background persistence")
        }
        XCTAssertTrue(coordinator.promote(key: key))

        manager.archivePersistenceSchedulingLock.lock()
        let priorityAfterOpen =
            manager.archivePersistencePriorityByQueryId[lease.queryId]
        manager.archivePersistenceSchedulingLock.unlock()
        XCTAssertEqual(priorityAfterOpen, .interactive)
    }

    func testLegacyCommitRequiresPersistenceProofBeforePublishingContentOrEmpty() {
        let owner = "legacy-proof-owner@example.com"
        let jid = "legacy-proof-peer@example.com"
        let terminalState = MessageArchivePageEndState(
            queryExhausted: true,
            archiveEnded: true,
            persistedMessageCount: 0
        )
        let emptyEvent = MessageArchiveEndPageEvent(
            owner: owner,
            queryId: "legacy-empty-query",
            state: terminalState,
            first: "",
            last: "",
            count: 0,
            streamKind: .primary,
            source: .unroutedFinalIQ
        )

        let unroutedProof = ChatLegacyArchivePresentationProofPolicy.resolve(
            event: emptyEvent,
            persistenceSummary: MessageManager.ArchivePersistenceSummary(),
            owner: owner,
            jid: jid,
            conversationType: .regular,
            hasPersistenceSource: false
        )
        XCTAssertFalse(unroutedProof.hasPresentationMaterialization)
        XCTAssertFalse(
            unroutedProof.confirmsEmptyConversation,
            "an unrouted optional-count final has no durable empty proof"
        )

        var invisibleSummary = MessageManager.ArchivePersistenceSummary()
        invisibleSummary.received = 1
        invisibleSummary.queued = 1
        invisibleSummary.savedNew = 1
        let invisibleProof = ChatLegacyArchivePresentationProofPolicy.resolve(
            event: emptyEvent,
            persistenceSummary: invisibleSummary,
            owner: owner,
            jid: jid,
            conversationType: .regular,
            hasPersistenceSource: true
        )
        XCTAssertFalse(invisibleProof.hasPresentationMaterialization)
        XCTAssertFalse(invisibleProof.confirmsEmptyConversation)

        let nonzeroEvent = MessageArchiveEndPageEvent(
            owner: owner,
            queryId: "legacy-nonzero-query",
            state: terminalState,
            first: "archive-1",
            last: "archive-1",
            count: 1,
            streamKind: .primary,
            source: .localCallback
        )
        let nonzeroInvisibleProof =
            ChatLegacyArchivePresentationProofPolicy.resolve(
                event: nonzeroEvent,
                persistenceSummary: invisibleSummary,
                owner: owner,
                jid: jid,
                conversationType: .regular,
                hasPersistenceSource: true
            )
        XCTAssertFalse(nonzeroInvisibleProof.hasPresentationMaterialization)
        XCTAssertFalse(nonzeroInvisibleProof.confirmsEmptyConversation)

        let confirmedEmptyProof =
            ChatLegacyArchivePresentationProofPolicy.resolve(
                event: emptyEvent,
                persistenceSummary:
                    MessageManager.ArchivePersistenceSummary(),
                owner: owner,
                jid: jid,
                conversationType: .regular,
                hasPersistenceSource: true
            )
        XCTAssertTrue(confirmedEmptyProof.confirmsEmptyConversation)
    }

    func testUnroutedFinalWithoutCountCannotSynthesizeEmptyProof() throws {
        let queryId = "unrouted-optional-count-query"
        let iq = try archiveFinalIQWithoutCount(
            queryId: queryId,
            complete: true
        )

        XCTAssertNil(
            MessageArchiveManager.unroutedEndPageEvent(
                owner: "unrouted-optional-count-owner@example.com",
                iq: iq,
                streamKind: .uiAction
            ),
            """
            Without the active manager's wire ledger, an omitted optional RSM
            count is unknown rather than zero. The retained lease must retry
            instead of publishing a false confirmed-empty page.
            """
        )
    }

    func testEveryArchiveStreamRecordsEnvelopeBeforeConsumerRouting() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "xabber/models/account/delegates/AccountStreamDelegate.swift",
            "xabber/common/XMPPUIActionManager/XMPPUIActionManager+Delegate.swift",
            "xabber/common/XMPPBackgroundTask/XMPPBackgroundTask+Delegate.swift"
        ]

        for relativePath in relativePaths {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let methodStart = try XCTUnwrap(source.range(
                of: "func xmppStream(_ sender: XMPPStream, didReceive message: XMPPMessage)"
            ))
            let methodSource = source[methodStart.lowerBound...]
            let recordRange = try XCTUnwrap(methodSource.range(
                of: "recordDeferredArchiveResultDelivery(message)"
            ))
            let persistenceRange = try XCTUnwrap(methodSource.range(
                of: "receiveArchived(message)"
            ))
            XCTAssertLessThan(
                recordRange.lowerBound,
                persistenceRange.lowerBound,
                "\(relativePath) must record the outer result before any consumer can return"
            )
            XCTAssertTrue(methodSource.contains(
                "recordDeferredArchiveControlConsumption(message)"
            ))
            XCTAssertTrue(
                methodSource.contains("case .chat, .normal:"),
                "\(relativePath) must route normal MAM wrappers exactly like chat wrappers"
            )
            XCTAssertTrue(
                methodSource.contains("chatMarkers"),
                "\(relativePath) must classify archived chat markers as intentional controls"
            )
        }
    }

    func testRawFinalDeferredCommitSurvivesStateResetUntilPersistenceConsumerTerminal() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatPostWireResetRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "post-wire-reset-owner@example.com"
        let jid = "post-wire-reset-peer@example.com"
        let queryId = "post-wire-reset-query"
        try insertUnsyncedChat(owner: owner, jid: jid)

        let manager = MessageArchiveManager(withOwner: owner)
        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: jid,
                conversationType: .regular,
                queryId: queryId,
                callback: nil
            ),
            .bootstrapStarted(queryId: queryId)
        )
        XCTAssertTrue(manager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQWithoutCount(
                queryId: queryId,
                complete: true
            )
        ))
        XCTAssertTrue(
            manager.hasDeferredCommit(queryId: queryId),
            "raw final must leave coverage/readiness owned by the persistence terminal"
        )

        manager.didResetState()

        XCTAssertTrue(
            manager.hasDeferredCommit(queryId: queryId),
            "a stream reset after raw final must not erase the in-flight persistence transaction"
        )
        XCTAssertEqual(
            manager.commitAfterPersistence(
                queryId: queryId,
                persistenceSummary: MessageManager.ArchivePersistenceSummary()
            ),
            .committed
        )

        manager.didResetState()

        let proof = try XCTUnwrap(
            manager.consumeCommittedArchiveConsumerProof(queryId: queryId),
            "reset must preserve the committed receipt until the coordinator consumes it"
        )
        XCTAssertTrue(proof.confirmsEmptyConversation)
    }

    func testCancelledArchiveRequestCannotLeakWireProofIntoReusedQueryId() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatCancelledWireProofRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "cancelled-proof-owner@example.com"
        let jid = "cancelled-proof-peer@example.com"
        let queryId = "reused-query-id"
        try insertUnsyncedChat(owner: owner, jid: jid)
        let manager = MessageArchiveManager(withOwner: owner)
        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: jid,
                conversationType: .regular,
                queryId: queryId,
                callback: nil
            ),
            .bootstrapStarted(queryId: queryId)
        )
        XCTAssertTrue(manager.recordDeferredArchiveResultDelivery(
            try archiveResultMessage(queryId: queryId, resultId: "stale")
        ))
        XCTAssertTrue(manager.cancelPendingArchiveRequest(queryId: queryId))

        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: jid,
                conversationType: .regular,
                queryId: queryId,
                callback: nil
            ),
            .bootstrapStarted(queryId: queryId)
        )
        XCTAssertTrue(manager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQWithoutCount(
                queryId: queryId,
                complete: true
            )
        ))
        XCTAssertEqual(
            manager.commitAfterPersistence(
                queryId: queryId,
                persistenceSummary: MessageManager.ArchivePersistenceSummary()
            ),
            .committed
        )
        XCTAssertEqual(
            manager.consumeCommittedArchiveConsumerProof(
                queryId: queryId
            )?.deliveredResultCount,
            0
        )
    }

    func testServiceMarkerMayBeRSMBoundaryWhenVisibleMessagesPersisted() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatServiceMarkerBoundaryRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "marker-boundary-owner@example.com"
        let jid = "marker-boundary-peer@example.com"
        try insertUnsyncedChat(owner: owner, jid: jid)

        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "marker-boundary-query"
        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: jid,
                conversationType: .regular,
                pageSize: 80,
                queryId: queryId,
                callback: nil
            ),
            .bootstrapStarted(queryId: queryId)
        )
        for resultId in ["80", "79", "terminal-marker"] {
            XCTAssertTrue(manager.recordDeferredArchiveResultDelivery(
                try archiveResultMessage(queryId: queryId, resultId: resultId)
            ))
        }
        XCTAssertTrue(manager.recordDeferredArchiveControlConsumption(
            try archiveResultMessage(
                queryId: queryId,
                resultId: "terminal-marker"
            )
        ))
        XCTAssertTrue(manager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQ(
                queryId: queryId,
                complete: false,
                count: 81,
                first: "80",
                last: "terminal-marker"
            )
        ))
        XCTAssertEqual(
            manager.expectedPersistenceResultCount(queryId: queryId),
            2,
            "persistence waits for delivered message envelopes, excluding the consumed service marker and ignoring the server's whole-archive count"
        )

        XCTAssertEqual(
            manager.commitAfterPersistence(
                queryId: queryId,
                persistenceSummary: persistenceSummary(
                    owner: owner,
                    jid: jid,
                    visibleRows: 2,
                    persistedArchiveIds: ["80", "79"]
                )
            ),
            .committed,
            "RSM boundaries identify delivered result wrappers; a consumed service marker need not become MessageStorageItem"
        )
        let consumerProof = try XCTUnwrap(
            manager.consumeCommittedArchiveConsumerProof(queryId: queryId)
        )
        XCTAssertEqual(consumerProof.deliveredResultCount, 3)
        XCTAssertEqual(consumerProof.serverResultCount, 81)
        XCTAssertFalse(consumerProof.confirmsEmptyConversation)
        XCTAssertNil(consumerProof.recommendedFollowUpTarget)
    }

    func testNonDeferredRegularFinalPublishesPageLocalIngressBudgetAndCleansIt()
        throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier:
                "ChatNonDeferredIngressBudgetRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "nondeferred-budget-owner@example.com"
        let jid = "nondeferred-budget-peer@example.com"
        let queryId = "nondeferred-budget-query"
        try insertUnsyncedChat(owner: owner, jid: jid)

        let manager = MessageArchiveManager(withOwner: owner)
        XCTAssertEqual(
            manager.startRegularArchiveRequest(
                XMPPStream(),
                plan: MessageArchiveManager.regularExactAnchorRequestPlan(
                    jid: jid,
                    archivedId: "visible-result"
                ),
                queryId: queryId,
                flipPage: false,
                joinDuplicateRequests: false
            ),
            queryId
        )
        for resultId in ["visible-result", "service-marker"] {
            XCTAssertTrue(manager.recordDeferredArchiveResultDelivery(
                try archiveResultMessage(
                    queryId: queryId,
                    resultId: resultId
                )
            ))
        }
        XCTAssertTrue(manager.recordDeferredArchiveControlConsumption(
            try archiveResultMessage(
                queryId: queryId,
                resultId: "service-marker"
            )
        ))
        XCTAssertTrue(manager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQ(
                queryId: queryId,
                complete: true,
                count: 2,
                first: "visible-result",
                last: "service-marker"
            )
        ))

        XCTAssertFalse(
            manager.hasDeferredCommit(queryId: queryId),
            "the regression must exercise the generic non-deferred route"
        )
        XCTAssertEqual(
            manager.expectedPersistenceResultCount(queryId: queryId),
            1,
            "wire ingress waits for the visible envelope and excludes the consumed control envelope"
        )

        manager.discardPersistenceIngressExpectation(queryId: queryId)
        XCTAssertNil(manager.expectedPersistenceResultCount(queryId: queryId))
    }

    func testNewestPageCoveringAdvancedSnapshotDoesNotRepeatLatestQuery() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatAdvancedSnapshotCoveredRegression-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "advanced-snapshot-owner@example.com"
        let jid = "advanced-snapshot-peer@example.com"
        try insertUnsyncedChat(
            owner: owner,
            jid: jid,
            snapshotArchiveId: "900"
        )

        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "advanced-snapshot-covered-query"
        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: jid,
                conversationType: .regular,
                pageSize: 80,
                queryId: queryId,
                callback: nil
            ),
            .bootstrapStarted(queryId: queryId)
        )

        let realm = try WRealm.safe()
        let chat = try XCTUnwrap(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: .regular
            )
        ))
        let archiveState = try XCTUnwrap(realm.object(
            ofType: RegularChatArchiveSyncStateStorageItem.self,
            forPrimaryKey:
                RegularChatArchiveSyncStateStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .regular
                )
        ))
        try realm.write {
            chat.syncSnapshotLastArchiveId = "950"
            archiveState.lastSnapshotArchiveId = "950"
        }

        for resultId in ["1000", "900"] {
            XCTAssertTrue(manager.recordDeferredArchiveResultDelivery(
                try archiveResultMessage(
                    queryId: queryId,
                    resultId: resultId
                )
            ))
        }
        XCTAssertTrue(manager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQ(
                queryId: queryId,
                complete: false,
                count: 81,
                first: "1000",
                last: "900"
            )
        ))

        XCTAssertEqual(
            manager.commitAfterPersistence(
                queryId: queryId,
                persistenceSummary: persistenceSummary(
                    owner: owner,
                    jid: jid,
                    visibleRows: 2,
                    persistedArchiveIds: ["1000", "900"]
                )
            ),
            .committed
        )
        let proof = try XCTUnwrap(
            manager.consumeCommittedArchiveConsumerProof(queryId: queryId)
        )
        XCTAssertNil(
            proof.recommendedFollowUpTarget,
            "the merged newest range already covers snapshot 950"
        )
        try assertNewestReadinessIsTrue(owner: owner, jid: jid)
    }

    func testInvisibleBootstrapPageContinuesOlderWithoutClaimingReadiness() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatInvisiblePageContinuationRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "invisible-page-owner@example.com"
        let jid = "invisible-page-peer@example.com"
        try insertUnsyncedChat(owner: owner, jid: jid)

        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "invisible-page-query"
        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: jid,
                conversationType: .regular,
                pageSize: 80,
                queryId: queryId,
                callback: nil
            ),
            .bootstrapStarted(queryId: queryId)
        )
        for resultId in ["80", "1"] {
            XCTAssertTrue(manager.recordDeferredArchiveResultDelivery(
                try archiveResultMessage(queryId: queryId, resultId: resultId)
            ))
        }
        XCTAssertTrue(manager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQ(
                queryId: queryId,
                complete: false,
                count: 160,
                first: "80",
                last: "1"
            )
        ))

        XCTAssertEqual(
            manager.commitAfterPersistence(
                queryId: queryId,
                persistenceSummary: persistenceSummary(
                    owner: owner,
                    jid: jid,
                    receivedRows: 2,
                    visibleRows: 0,
                    persistedArchiveIds: ["80", "1"]
                )
            ),
            .committedNeedsFollowUpRepair
        )
        let consumerProof = try XCTUnwrap(
            manager.consumeCommittedArchiveConsumerProof(queryId: queryId)
        )
        XCTAssertFalse(consumerProof.confirmsEmptyConversation)
        XCTAssertEqual(
            consumerProof.recommendedFollowUpTarget,
            .older(beforeArchiveId: "1")
        )
        try assertChatReadinessIsFalse(
            owner: owner,
            jid: jid,
            expectedNewestCoverage: true
        )
    }

    func testInvisibleTerminalBootstrapPageConfirmsEmptyOnlyAtArchiveEnd() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatInvisibleTerminalPageRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let owner = "invisible-terminal-owner@example.com"
        let jid = "invisible-terminal-peer@example.com"
        try insertUnsyncedChat(owner: owner, jid: jid)

        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "invisible-terminal-query"
        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: jid,
                conversationType: .regular,
                pageSize: 80,
                queryId: queryId,
                callback: nil
            ),
            .bootstrapStarted(queryId: queryId)
        )
        for resultId in ["2", "1"] {
            XCTAssertTrue(manager.recordDeferredArchiveResultDelivery(
                try archiveResultMessage(queryId: queryId, resultId: resultId)
            ))
        }
        XCTAssertTrue(manager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQ(
                queryId: queryId,
                complete: true,
                count: 2,
                first: "2",
                last: "1"
            )
        ))

        XCTAssertEqual(
            manager.commitAfterPersistence(
                queryId: queryId,
                persistenceSummary: persistenceSummary(
                    owner: owner,
                    jid: jid,
                    receivedRows: 2,
                    visibleRows: 0,
                    persistedArchiveIds: ["2", "1"]
                )
            ),
            .committed
        )
        let consumerProof = try XCTUnwrap(
            manager.consumeCommittedArchiveConsumerProof(queryId: queryId)
        )
        XCTAssertEqual(consumerProof.deliveredResultCount, 2)
        XCTAssertTrue(consumerProof.confirmsEmptyConversation)
        XCTAssertNil(consumerProof.recommendedFollowUpTarget)
        try assertNewestReadinessIsTrue(owner: owner, jid: jid)
    }

    func testDurableLatestThenSavedTargetKeepsReadinessWithoutThirdLatest() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatLatestThenTargetRegressionTests-\(name)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        XCTAssertTrue(
            MessageArchiveManager.durableNewestCoverageAfterBootstrapPage(
                previousHasDurableNewestCoverage: true,
                boundaryChanged: false,
                pageReachesNewestLiveEdge: false,
                computedHasDurableNewestCoverage: false
            ),
            "a target-only page must not invalidate a durable latest proof for the same boundary"
        )
        XCTAssertFalse(
            MessageArchiveManager.durableNewestCoverageAfterBootstrapPage(
                previousHasDurableNewestCoverage: false,
                boundaryChanged: false,
                pageReachesNewestLiveEdge: false,
                computedHasDurableNewestCoverage: false
            ),
            "without a predecessor proof the target page must still require latest repair"
        )
        XCTAssertFalse(
            MessageArchiveManager.durableNewestCoverageAfterBootstrapPage(
                previousHasDurableNewestCoverage: true,
                boundaryChanged: true,
                pageReachesNewestLiveEdge: false,
                computedHasDurableNewestCoverage: false
            ),
            "a changed boundary invalidates the predecessor proof"
        )
        XCTAssertTrue(
            MessageArchiveManager.durableNewestCoverageAfterBootstrapPage(
                previousHasDurableNewestCoverage: false,
                boundaryChanged: true,
                pageReachesNewestLiveEdge: true,
                computedHasDurableNewestCoverage: true
            ),
            """
            a newest page that already covers the current post-merge boundary
            must not schedule an identical second latest query
            """
        )

        let owner = "latest-target-owner@example.com"
        let jid = "latest-target-peer@example.com"
        try insertUnsyncedChat(
            owner: owner,
            jid: jid,
            snapshotArchiveId: "900"
        )
        let manager = MessageArchiveManager(withOwner: owner)
        let latestQueryId = "latest-before-target"
        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: jid,
                conversationType: .regular,
                pageSize: 80,
                queryId: latestQueryId,
                target: .latest,
                callback: nil
            ),
            .bootstrapStarted(queryId: latestQueryId)
        )
        XCTAssertTrue(manager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQ(
                queryId: latestQueryId,
                complete: true,
                count: 1,
                first: "900",
                last: "900"
            )
        ))
        XCTAssertEqual(
            manager.commitAfterPersistence(
                queryId: latestQueryId,
                persistenceSummary: persistenceSummary(
                    owner: owner,
                    jid: jid,
                    visibleRows: 1,
                    persistedArchiveIds: ["900"]
                )
            ),
            .committed
        )
        let persistedLatestMessage = MessageStorageItem()
        persistedLatestMessage.primary = MessageStorageItem.genPrimary(
            messageId: "latest-before-target-message",
            owner: owner
        )
        persistedLatestMessage.owner = owner
        persistedLatestMessage.opponent = jid
        persistedLatestMessage.conversationType = .regular
        persistedLatestMessage.messageId = "latest-before-target-message"
        persistedLatestMessage.archivedId = "900"
        persistedLatestMessage.date = Date(timeIntervalSince1970: 900)
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(persistedLatestMessage, update: .modified)
        }
        try assertNewestReadinessIsTrue(owner: owner, jid: jid)

        let savedQueryId = "saved-after-durable-latest"
        XCTAssertEqual(
            manager.syncChat(
                XMPPStream(),
                jid: jid,
                conversationType: .regular,
                pageSize: 80,
                queryId: savedQueryId,
                target: .savedPosition(
                    messagePrimary: "saved-primary",
                    archivedId: "500",
                    messageId: "saved-message",
                    sourceDate: Date(timeIntervalSince1970: 500)
                ),
                callback: nil
            ),
            .bootstrapStarted(queryId: savedQueryId)
        )
        XCTAssertTrue(manager.read(
            XMPPStream(),
            withIQ: try archiveFinalIQ(
                queryId: savedQueryId,
                complete: true,
                count: 1,
                first: "500",
                last: "500"
            )
        ))
        XCTAssertEqual(
            manager.commitAfterPersistence(
                queryId: savedQueryId,
                persistenceSummary: persistenceSummary(
                    owner: owner,
                    jid: jid,
                    visibleRows: 1,
                    persistedArchiveIds: ["500"]
                )
            ),
            .committed,
            "the requested target is terminal; another latest page would be redundant"
        )
        try assertNewestReadinessIsTrue(owner: owner, jid: jid)
    }

    func testPresentationCompletionCannotCommitArchiveLiveEdge() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent(
                    "xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift"
                ),
            encoding: .utf8
        )
        let methodStart = try XCTUnwrap(
            source.range(of: "internal func completeInitialBootstrapIfNeeded()")
        )
        let methodEnd = try XCTUnwrap(
            source.range(
                of: "internal func scheduleInitialBootstrapLocalHistoryFallbackIfNeeded()",
                range: methodStart.upperBound..<source.endIndex
            )
        )
        let method = source[methodStart.lowerBound..<methodEnd.lowerBound]
        XCTAssertFalse(method.contains("markNewerLiveEdgeReached: true"))
        XCTAssertFalse(method.contains("applyChatArchiveStateIfNeeded("))
    }

    @MainActor
    func testUnsyncedNavigationPreparationCommitsSkeletonBeforeReturningReceipt() {
        let controller = ChatViewController()
        controller.owner = "first-frame-owner@example.com"
        controller.jid = "first-frame-peer@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Peer")
        var completionCount = 0

        controller.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
        ) {
            completionCount += 1
        }

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertTrue(controller.hasCommittedBootstrapSkeletonRows)
        XCTAssertEqual(
            controller.messagesCollectionView.numberOfSections,
            controller.datasource.count
        )
        controller.performTerminalChatResourceTeardownForTesting()
    }

    @MainActor
    func testTargetFollowUpPreservesOriginalGateTokenAndPresentationDeadline() {
        let controller = ChatViewController()
        controller.owner = "gate-continuation-owner@example.com"
        controller.jid = "gate-continuation-peer@example.com"
        controller.conversationType = .regular
        let gate = AccountInteractiveChatOpenGate(maximumDuration: 1)
        let token = gate.acquire()
        let deadline = Date().addingTimeInterval(0.5)
        controller.interactiveChatOpenGate = gate
        controller.interactiveChatOpenGateToken = token
        controller.initialBootstrapPresentationDeadline = deadline
        controller.beginInitialBootstrapTracking(
            queryId: "target-page",
            timeout: nil
        )

        controller.resetInitialBootstrapTracking(
            preserveInteractiveChatOpenGate: true
        )

        XCTAssertTrue(gate.isActive)
        XCTAssertEqual(controller.interactiveChatOpenGateToken, token)
        XCTAssertEqual(controller.initialBootstrapPresentationDeadline, deadline)

        controller.resetInitialBootstrapTracking()
        XCTAssertFalse(gate.isActive)
        XCTAssertNil(controller.interactiveChatOpenGateToken)
        XCTAssertNil(controller.initialBootstrapPresentationDeadline)
    }

    @MainActor
    func testFiveSecondPresentationWatchdogKeepsQueuedSkeletonAndActiveLease() {
        XCTAssertEqual(
            ChatInitialBootstrapPresentationWatchdogPolicy.timeout(
                hasCommittedPage: false,
                remainingTransportTimeout: 45
            ),
            5
        )

        let controller = ChatViewController()
        controller.owner = "watchdog-owner@example.com"
        controller.jid = "watchdog-peer@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Peer")
        controller.loadViewIfNeeded()
        controller.configureDataset()
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )

        let key = controller.initialBootstrapRequestKey
        guard case .start(let lease) = ChatInitialBootstrapRequestCoordinator.shared.acquireOrJoin(
            key: key,
            proposedQueryId: "soft-watchdog-query",
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            return XCTFail("test setup must reserve a lease")
        }
        let initialSkeletonPrimaries = controller.datasource.map(\.primary)
        XCTAssertEqual(initialSkeletonPrimaries.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        controller.beginInitialBootstrapTracking(queryId: lease.queryId, timeout: 0.02)

        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        XCTAssertEqual(
            ChatInitialBootstrapRequestCoordinator.shared.readiness(for: key)?.phase,
            .queued
        )
        XCTAssertEqual(controller.appliedBootstrapLoadingState, .blockingArchive)
        XCTAssertTrue(controller.bootstrapFailureView.isHidden)
        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.datasource.map(\.primary), initialSkeletonPrimaries)
        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertTrue(controller.isInitialBootstrapInFlight)
        XCTAssertTrue(
            ChatInitialBootstrapRequestCoordinator.shared.isActive(
                key: key,
                queryId: lease.queryId
            ),
            "the presentation SLA must not cancel transport or persistence"
        )
        controller.performTerminalChatResourceTeardownForTesting()
    }

    func testFiveSecondPresentationWatchdogKeepsTransportSkeletonAndActiveLease() {
        let controller = makeController(
            owner: "transport-watchdog-owner@example.com",
            jid: "transport-watchdog-peer@example.com"
        )
        controller.loadViewIfNeeded()
        controller.configureDataset()
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )

        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "transport-watchdog-query",
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            controller.performTerminalChatResourceTeardownForTesting()
            return XCTFail("test setup must reserve a transport lease")
        }
        let manager = MessageManager(withOwner: key.owner, activeStream: false)
        manager.updateSendingMessagesTimer?.invalidate()
        manager.updateSendingMessagesTimer = nil
        manager.unsubscribeSender()
        manager.unsubscribeReceiver()
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: manager,
            cancelTransport: {}
        )
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .transport)

        let initialSkeletonPrimaries = controller.datasource.map(\.primary)
        controller.beginInitialBootstrapTracking(queryId: lease.queryId, timeout: 0.02)
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .transport)
        XCTAssertEqual(controller.appliedBootstrapLoadingState, .blockingArchive)
        XCTAssertTrue(controller.bootstrapFailureView.isHidden)
        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.datasource.map(\.primary), initialSkeletonPrimaries)
        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertTrue(controller.isInitialBootstrapInFlight)
        XCTAssertTrue(coordinator.isActive(key: key, queryId: lease.queryId))
        controller.performTerminalChatResourceTeardownForTesting()
    }


    @MainActor
    func testRawFinDuringBlockedPersistenceDoesNotDisarmPresentationWatchdog() {
        let controller = ChatViewController()
        controller.owner = "raw-fin-watchdog-owner@example.com"
        controller.jid = "raw-fin-watchdog-peer@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Peer")
        controller.loadViewIfNeeded()
        controller.configureDataset()
        controller.applyBootstrapLoadingState(
            .blockingArchive,
            forceRender: true,
            synchronousSkeletonCommit: true
        )

        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let key = controller.initialBootstrapRequestKey
        guard case .start(let lease) = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: "raw-fin-blocked-persistence",
            timeout: 45,
            observer: { _, _, _ in }
        ) else {
            controller.performTerminalChatResourceTeardownForTesting()
            return XCTFail("test setup must reserve one bootstrap lease")
        }
        let manager = MessageManager(withOwner: key.owner, activeStream: false)
        manager.updateSendingMessagesTimer?.invalidate()
        manager.updateSendingMessagesTimer = nil
        manager.unsubscribeSender()
        manager.unsubscribeReceiver()
        coordinator.resolveStart(
            key: key,
            queryId: lease.queryId,
            result: .bootstrapStarted(queryId: lease.queryId),
            messages: manager,
            cancelTransport: {}
        )

        manager.queue.suspend()
        var isQueueSuspended = true
        defer {
            if isQueueSuspended {
                manager.queue.resume()
            }
            controller.performTerminalChatResourceTeardownForTesting()
        }

        controller.beginInitialBootstrapTracking(
            queryId: lease.queryId,
            timeout: 0.02
        )
        let final = MessageArchiveEndPageEvent(
            owner: key.owner,
            queryId: lease.queryId,
            state: MessageArchivePageEndState(
                queryExhausted: true,
                archiveEnded: true,
                persistedMessageCount: 0
            ),
            first: "",
            last: "",
            count: 0,
            streamKind: .primary,
            source: .unroutedFinalIQ
        )
        XCTAssertTrue(MessageArchiveEndPageDispatcher.publish(final))
        XCTAssertEqual(coordinator.readiness(for: key)?.phase, .persistence)

        let initialSkeletonPrimaries = controller.datasource.map(\.primary)
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        XCTAssertEqual(controller.appliedBootstrapLoadingState, .blockingArchive)
        XCTAssertTrue(controller.bootstrapFailureView.isHidden)
        XCTAssertTrue(controller.showSkeletonObserver.value)
        XCTAssertEqual(controller.datasource.map(\.primary), initialSkeletonPrimaries)
        XCTAssertEqual(controller.datasource.count, 30)
        XCTAssertTrue(controller.datasource.allSatisfy(\.isFakeMessage))
        XCTAssertTrue(controller.isInitialBootstrapInFlight)
        XCTAssertTrue(coordinator.isActive(key: key, queryId: lease.queryId))

        manager.queue.resume()
        isQueueSuspended = false
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
    }

    private func makeController(
        owner: String,
        jid: String
    ) -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = .regular
        controller.ownerSender = Sender(
            id: controller.owner,
            displayName: "Owner"
        )
        controller.opponentSender = Sender(
            id: controller.jid,
            displayName: "Peer"
        )
        controller.messagesCollectionView.frame = CGRect(
            x: 0,
            y: 0,
            width: 390,
            height: 844
        )
        controller.showSkeletonObserver.accept(true)
        return controller
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func insertUnsyncedChat(
        owner: String,
        jid: String,
        snapshotArchiveId: String? = nil,
        unreadAfterArchiveId: String? = nil
    ) throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: .regular
        )
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .regular
        chat.messageDate = Date()
        chat.isSynced = false
        chat.isInitialArchiveLoaded = false
        chat.syncSnapshotLastArchiveId = snapshotArchiveId
        if let unreadAfterArchiveId {
            chat.syncUnreadCount = 1
            chat.syncUnreadAfterId = unreadAfterArchiveId
        }
        try realm.write {
            realm.add(chat, update: .modified)
            let state = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: jid,
                conversationType: .regular,
                in: realm
            )
            state.lastSnapshotArchiveId = snapshotArchiveId
            state.newerLiveEdgeReached = false
        }
    }

    private func archiveFinalIQ(
        queryId: String,
        complete: Bool,
        count: Int,
        first: String,
        last: String
    ) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: """
        <iq type='result' id='\(queryId)'>
          <fin xmlns='urn:xmpp:mam:2' complete='\(complete ? "true" : "false")' queryid='\(queryId)'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>\(count)</count>
              <first>\(first)</first>
              <last>\(last)</last>
            </set>
          </fin>
        </iq>
        """, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }

    private func archiveResultMessage(
        queryId: String,
        resultId: String
    ) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: """
        <message>
          <result xmlns='urn:xmpp:mam:2' queryid='\(queryId)' id='\(resultId)'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <delay xmlns='urn:xmpp:delay' stamp='2026-07-22T11:13:53Z'/>
              <message from='peer@example.com' to='owner@example.com' type='chat'/>
            </forwarded>
          </result>
        </message>
        """, options: 0)
        return XMPPMessage(from: try XCTUnwrap(document.rootElement()))
    }

    private func archiveFinalIQWithoutCount(
        queryId: String,
        complete: Bool
    ) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: """
        <iq type='result' id='\(queryId)'>
          <fin xmlns='urn:xmpp:mam:2' complete='\(complete ? "true" : "false")' queryid='\(queryId)'>
            <set xmlns='http://jabber.org/protocol/rsm'/>
          </fin>
        </iq>
        """, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }

    private func persistenceSummary(
        owner: String,
        jid: String,
        receivedRows: Int? = nil,
        visibleRows: Int,
        persistedArchiveIds: [String]
    ) -> MessageManager.ArchivePersistenceSummary {
        var summary = MessageManager.ArchivePersistenceSummary()
        let receivedRows = max(0, receivedRows ?? visibleRows)
        summary.received = receivedRows
        summary.queued = receivedRows
        summary.savedNew = receivedRows
        for _ in 0..<visibleRows {
            summary.recordVisibleRow(
                owner: owner,
                jid: jid,
                conversationType: .regular
            )
        }
        persistedArchiveIds.forEach {
            summary.recordPersistedArchiveId(
                $0,
                owner: owner,
                jid: jid,
                conversationType: .regular
            )
        }
        return summary
    }

    private func assertChatReadinessIsFalse(
        owner: String,
        jid: String,
        expectedNewestCoverage: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let realm = try WRealm.safe()
        let chat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .regular
                )
            ),
            file: file,
            line: line
        )
        let state = try XCTUnwrap(
            realm.object(
                ofType: RegularChatArchiveSyncStateStorageItem.self,
                forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .regular
                )
            ),
            file: file,
            line: line
        )
        XCTAssertEqual(
            state.newerLiveEdgeReached,
            expectedNewestCoverage,
            "Coverage and presentation readiness are separate: an invisible newest page may cover the live edge while the chat remains unready until an older visible page is committed.",
            file: file,
            line: line
        )
        XCTAssertFalse(chat.isSynced, file: file, line: line)
        XCTAssertFalse(chat.isInitialArchiveLoaded, file: file, line: line)
    }

    private func assertNewestReadinessIsTrue(
        owner: String,
        jid: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let realm = try WRealm.safe()
        let chat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .regular
                )
            ),
            file: file,
            line: line
        )
        let state = try XCTUnwrap(
            realm.object(
                ofType: RegularChatArchiveSyncStateStorageItem.self,
                forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .regular
                )
            ),
            file: file,
            line: line
        )
        XCTAssertTrue(state.newerLiveEdgeReached, file: file, line: line)
        XCTAssertTrue(chat.isSynced, file: file, line: line)
        XCTAssertTrue(chat.isInitialArchiveLoaded, file: file, line: line)
    }
}
