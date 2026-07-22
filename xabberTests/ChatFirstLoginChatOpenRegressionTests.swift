import XCTest
import UIKit
@testable import xabber

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

    private func makeController() -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = "first-login-owner@example.com"
        controller.jid = "first-login-peer@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Peer")
        controller.messagesCollectionView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.showSkeletonObserver.accept(true)
        return controller
    }
}
