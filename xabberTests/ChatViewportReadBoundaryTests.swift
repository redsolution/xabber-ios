import XCTest
import RealmSwift
import UIKit
@testable import xabber

final class ChatViewportReadBoundaryTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private let owner = "owner@example.com"
    private let jid = "romeo@example.com"

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatViewportReadBoundaryTests-\(name)-\(UUID().uuidString)"
        )
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept(Set<String>())
        AccountManager.shared.connectingUsers.accept(Set<String>())
        AccountManager.shared.authenticatedUsers.accept(Set<String>())
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    override func tearDown() {
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept(Set<String>())
        AccountManager.shared.connectingUsers.accept(Set<String>())
        AccountManager.shared.authenticatedUsers.accept(Set<String>())
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testBottommostVisibleIncomingAdvancesBoundary() {
        let target = ChatViewportReadBoundaryPolicy.nextVisibleIncomingTarget(
            visiblePrimaries: ["incoming-old", "incoming-new"],
            orderedMessages: [
                orderedMessage(primary: "incoming-old", orderIndex: 1),
                orderedMessage(primary: "outgoing-between", orderIndex: 2, outgoing: true),
                orderedMessage(primary: "incoming-new", orderIndex: 3)
            ],
            currentBoundaryIndex: nil
        )

        XCTAssertEqual(target?.primary, "incoming-new")
        XCTAssertEqual(target?.orderIndex, 3)
    }

    func testVisibleOutgoingDoesNotAdvanceIncomingBoundary() {
        let target = ChatViewportReadBoundaryPolicy.nextVisibleIncomingTarget(
            visiblePrimaries: ["incoming-old", "outgoing-new"],
            orderedMessages: [
                orderedMessage(primary: "incoming-old", orderIndex: 1),
                orderedMessage(primary: "outgoing-new", orderIndex: 4, outgoing: true)
            ],
            currentBoundaryIndex: nil
        )

        XCTAssertEqual(target?.primary, "incoming-old")
        XCTAssertEqual(target?.orderIndex, 1)
    }

    func testBackwardScrollingDoesNotRegressBoundary() {
        let target = ChatViewportReadBoundaryPolicy.nextVisibleIncomingTarget(
            visiblePrimaries: ["incoming-old"],
            orderedMessages: [
                orderedMessage(primary: "incoming-old", orderIndex: 1),
                orderedMessage(primary: "incoming-current", orderIndex: 5)
            ],
            currentBoundaryIndex: 5
        )

        XCTAssertNil(target)
    }

    func testUnresolvedMarkerTargetIsNoOpUntilLoadedInOrder() {
        let orderedMessages = [
            orderedMessage(primary: "incoming-old", orderIndex: 1),
            orderedMessage(primary: "incoming-new", orderIndex: 2)
        ]

        XCTAssertNil(ChatViewportReadBoundaryPolicy.resolvedDisplayedMarkerTarget(
            primary: "missing",
            orderedMessages: orderedMessages,
            currentBoundaryIndex: nil
        ))

        let target = ChatViewportReadBoundaryPolicy.resolvedDisplayedMarkerTarget(
            primary: "incoming-new",
            orderedMessages: orderedMessages,
            currentBoundaryIndex: nil
        )
        XCTAssertEqual(target?.primary, "incoming-new")
        XCTAssertEqual(target?.orderIndex, 2)
    }

    func testPendingFlushUsesLoadedOrderInsteadOfSentDate() throws {
        let account = Account(jid: owner, queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.account"))
        AccountManager.shared.users.append(account)
        let controller = makeController()
        try seedOutOfOrderDateUnreadChat()
        controller.datasource = [
            makeDatasource(primary: "incoming-old", archivedId: "100", sentDate: Date(timeIntervalSince1970: 300)),
            makeDatasource(primary: "incoming-new", archivedId: "200", sentDate: Date(timeIntervalSince1970: 100))
        ]
        controller.messagesToReadObserver.accept(["incoming-old", "incoming-new"])
        authorizeReadVisiblePresentation(controller)

        XCTAssertTrue(controller.flushPendingVisibleReadTarget())

        let chat = try storedChat()
        XCTAssertEqual(chat.syncUnreadCount, 0)
        XCTAssertEqual(chat.unread, 0)
        XCTAssertEqual(chat.lastReadId, "200")
    }

    func testPendingFlushWaitsForStructurallyVisiblePresentationReceipt() throws {
        let account = Account(jid: owner, queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.pending"))
        AccountManager.shared.users.append(account)
        let controller = makeController()
        try seedOutOfOrderDateUnreadChat()
        controller.datasource = [
            makeDatasource(primary: "incoming-old", archivedId: "100", sentDate: Date(timeIntervalSince1970: 300)),
            makeDatasource(primary: "incoming-new", archivedId: "200", sentDate: Date(timeIntervalSince1970: 100))
        ]
        controller.messagesToReadObserver.accept(["incoming-old", "incoming-new"])
        controller.readVisiblePresentationSnapshotProvider = {
            self.readVisiblePresentationSnapshot(isTopNavigationDestination: true)
        }

        XCTAssertFalse(controller.flushPendingVisibleReadTarget())
        XCTAssertEqual(controller.messagesToReadObserver.value, ["incoming-old", "incoming-new"])

        controller.readVisiblePresentationCoordinator.recordPresentationReceipt()
        XCTAssertTrue(controller.flushPendingVisibleReadTarget())
    }

    func testOrdinaryViewportReadWaitsForCommittedInitialFrameAndStructuralTransactionCompletion() throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.initial-presentation")
        )
        AccountManager.shared.users.append(account)
        try seedUnreadChat()
        let controller = makeController()
        _ = configureReadGeometry(
            for: controller,
            primary: "incoming-last",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80),
            archivedId: "200",
            sentDate: Date(timeIntervalSince1970: 200),
            usesDetachedTimeline: false
        )
        let timelineSession = try openReadTargetInProductionTimelineSession(
            for: controller,
            primary: "incoming-last"
        )
        authorizeReadVisiblePresentation(controller)
        let descriptor = ChatLocalFirstFrameDescriptor(
            target: .latest,
            request: nil
        )

        controller.initialLocalFirstFramePhase = .presenting(descriptor)
        controller.isChatDatasourceStructuralTransactionActive = false
        enqueueOrdinaryViewportRead(on: controller)
        XCTAssertTrue(controller.messagesToReadObserver.value.isEmpty)
        XCTAssertNil(currentViewportReadBoundaryIndex(for: controller))
        try assertUnreadLastMessageRemainsUnchanged()

        controller.initialLocalFirstFramePhase = .committed(descriptor)
        controller.isChatDatasourceStructuralTransactionActive = true
        enqueueOrdinaryViewportRead(on: controller)
        XCTAssertTrue(controller.messagesToReadObserver.value.isEmpty)
        XCTAssertNil(currentViewportReadBoundaryIndex(for: controller))
        try assertUnreadLastMessageRemainsUnchanged()

        controller.isChatDatasourceStructuralTransactionActive = false
        enqueueOrdinaryViewportRead(on: controller)
        XCTAssertEqual(controller.messagesToReadObserver.value, ["incoming-last"])
        let orderedMessages = controller.orderedViewportReadMessages()
        let incomingLastOrderIndex = try XCTUnwrap(
            orderedMessages.first(where: { $0.primary == "incoming-last" })
        ).orderIndex
        XCTAssertEqual(
            controller.currentViewportReadBoundaryIndex(in: orderedMessages),
            incomingLastOrderIndex
        )
        XCTAssertEqual(
            timelineSession.snapshot.readBoundary?.primary,
            "incoming-last",
            "ordinary viewport ingress must advance the production session boundary"
        )
        XCTAssertTrue(controller.flushPendingVisibleReadTarget())
        XCTAssertTrue(controller.messagesToReadObserver.value.isEmpty)

        let committedChat = try storedChat()
        XCTAssertEqual(committedChat.lastReadId, "200")
        XCTAssertEqual(committedChat.syncUnreadCount, 0)
        XCTAssertEqual(committedChat.unread, 0)
        XCTAssertNil(committedChat.displayedId)

        enqueueOrdinaryViewportRead(on: controller)
        XCTAssertFalse(controller.flushPendingVisibleReadTarget())
        XCTAssertTrue(controller.messagesToReadObserver.value.isEmpty)
    }

    func testOrdinaryViewportReadWaitsForActiveAnchorExecutionToFinish() throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.anchor-presentation")
        )
        AccountManager.shared.users.append(account)
        try seedUnreadChat()
        let controller = makeController()
        _ = configureReadGeometry(
            for: controller,
            primary: "incoming-last",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80),
            archivedId: "200",
            sentDate: Date(timeIntervalSince1970: 200),
            usesDetachedTimeline: false
        )
        let timelineSession = try openReadTargetInProductionTimelineSession(
            for: controller,
            primary: "incoming-last"
        )
        authorizeReadVisiblePresentation(controller)
        controller.initialLocalFirstFramePhase = .committed(
            ChatLocalFirstFrameDescriptor(target: .latest, request: nil)
        )
        let request = ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: .regular,
            anchor: ChatMessageAnchorRef(
                messagePrimary: "incoming-last",
                archivedId: "200",
                messageId: "incoming-last",
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: Date(timeIntervalSince1970: 200)
            ),
            highlight: false,
            markReadOnVisible: false,
            source: .external
        )
        controller.pendingOpenMessageRequest = request
        controller.activeAnchorExecutionState = ChatAnchorExecutionState(
            request: request
        )

        enqueueOrdinaryViewportRead(on: controller)
        XCTAssertTrue(controller.messagesToReadObserver.value.isEmpty)
        XCTAssertNil(currentViewportReadBoundaryIndex(for: controller))
        try assertUnreadLastMessageRemainsUnchanged()

        controller.pendingOpenMessageRequest = nil
        controller.activeAnchorExecutionState = nil
        enqueueOrdinaryViewportRead(on: controller)
        XCTAssertEqual(controller.messagesToReadObserver.value, ["incoming-last"])
        XCTAssertEqual(
            timelineSession.snapshot.readBoundary?.primary,
            "incoming-last",
            "anchor completion must release the read through the production session"
        )
        XCTAssertTrue(controller.flushPendingVisibleReadTarget())

        let committedChat = try storedChat()
        XCTAssertEqual(committedChat.lastReadId, "200")
        XCTAssertEqual(committedChat.syncUnreadCount, 0)
        XCTAssertEqual(committedChat.unread, 0)
        XCTAssertNil(committedChat.displayedId)

        enqueueOrdinaryViewportRead(on: controller)
        XCTAssertFalse(controller.flushPendingVisibleReadTarget())
    }

    func testExplicitMarkAllRemainsSeparateAllowedProducer() throws {
        let account = Account(jid: owner, queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.account"))
        AccountManager.shared.users.append(account)
        try seedUnreadChat()

        let viewportTarget = ChatViewportReadBoundaryPolicy.nextVisibleIncomingTarget(
            visiblePrimaries: Set<String>(),
            orderedMessages: [
                orderedMessage(primary: "incoming-old", orderIndex: 1),
                orderedMessage(primary: "incoming-last", orderIndex: 2)
            ],
            currentBoundaryIndex: nil
        )
        XCTAssertNil(viewportTarget)

        account.messages.readLastMessage(jid: jid, conversationType: .regular)

        let chat = try storedChat()
        XCTAssertEqual(chat.syncUnreadCount, 0)
        XCTAssertEqual(chat.runtimeUnreadCount, 0)
        XCTAssertEqual(chat.unread, 0)
        XCTAssertEqual(chat.lastReadId, "200")
    }

    @MainActor
    func testPresentationReceiptHandoffResamplesOrdinaryRowRejectedBeforeReceiptAndReadsOnce()
        throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(
                label: "ChatViewportReadBoundaryTests.ordinary.presentation-handoff"
            )
        )
        AccountManager.shared.users.append(account)
        try seedUnreadChat()
        let controller = makeController()
        _ = configureReadGeometry(
            for: controller,
            primary: "incoming-last",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80),
            archivedId: "200",
            sentDate: Date(timeIntervalSince1970: 200),
            usesDetachedTimeline: false
        )
        _ = try openReadTargetInProductionTimelineSession(
            for: controller,
            primary: "incoming-last"
        )
        controller.readVisiblePresentationSnapshotProvider = {
            self.readVisiblePresentationSnapshot(
                isTopNavigationDestination: true
            )
        }

        enqueueOrdinaryViewportRead(on: controller)
        XCTAssertTrue(
            controller.messagesToReadObserver.value.isEmpty,
            "a pre-receipt row must not become an authorized read target"
        )
        try assertUnreadLastMessageRemainsUnchanged()

        var committedMutationCount = 0
        account.messages.readMessageDurableMutationObserverForTests = { event in
            guard event.primary == "incoming-last",
                  event.phase == .committed else {
                return
            }
            committedMutationCount += 1
        }
        let handoff = controller.recordReadVisiblePresentationReceiptHandoff()
        controller.enqueuePendingReadStateRetry(for: handoff)
        drainMainQueue(description: "ordinary receipt resample")

        let chat = try storedChat()
        XCTAssertEqual(chat.syncUnreadCount, 0)
        XCTAssertEqual(chat.runtimeUnreadCount, 0)
        XCTAssertEqual(chat.unread, 0)
        XCTAssertEqual(chat.lastReadId, "200")
        XCTAssertTrue(try storedMessage(primary: "incoming-last").isRead)
        XCTAssertTrue(controller.messagesToReadObserver.value.isEmpty)
        XCTAssertEqual(committedMutationCount, 1)

        controller.enqueuePendingReadStateRetry(for: handoff)
        drainMainQueue(description: "duplicate ordinary receipt resample")
        XCTAssertEqual(committedMutationCount, 1)
    }

    @MainActor
    func testNavigationTransitionCompletionResamplesVisibleOrdinaryRowAfterReceipt()
        throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(
                label: "ChatViewportReadBoundaryTests.ordinary.transition-handoff"
            )
        )
        AccountManager.shared.users.append(account)
        try seedUnreadChat()
        let controller = makeController()
        _ = configureReadGeometry(
            for: controller,
            primary: "incoming-last",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80),
            archivedId: "200",
            sentDate: Date(timeIntervalSince1970: 200),
            usesDetachedTimeline: false
        )
        _ = try openReadTargetInProductionTimelineSession(
            for: controller,
            primary: "incoming-last"
        )
        controller.isNavigationTransitionActive = true
        controller.readVisiblePresentationSnapshotProvider = { [weak controller] in
            self.readVisiblePresentationSnapshot(
                isTopNavigationDestination: true,
                isTransitionActive:
                    controller?.isNavigationTransitionActive ?? true
            )
        }

        var committedMutationCount = 0
        account.messages.readMessageDurableMutationObserverForTests = { event in
            guard event.primary == "incoming-last",
                  event.phase == .committed else {
                return
            }
            committedMutationCount += 1
        }
        let handoff = controller.recordReadVisiblePresentationReceiptHandoff()
        controller.enqueuePendingReadStateRetry(for: handoff)
        drainMainQueue(description: "transition-blocked receipt retry")

        try assertUnreadLastMessageRemainsUnchanged()
        XCTAssertEqual(committedMutationCount, 0)
        XCTAssertTrue(controller.messagesToReadObserver.value.isEmpty)

        controller.completeNavigationTransitionDeferral(cancelled: false)
        drainMainQueue(description: "navigation transition read retry")

        let chat = try storedChat()
        XCTAssertEqual(chat.syncUnreadCount, 0)
        XCTAssertEqual(chat.runtimeUnreadCount, 0)
        XCTAssertEqual(chat.unread, 0)
        XCTAssertEqual(chat.lastReadId, "200")
        XCTAssertTrue(try storedMessage(primary: "incoming-last").isRead)
        XCTAssertEqual(committedMutationCount, 1)

        controller.completeNavigationTransitionDeferral(cancelled: false)
        drainMainQueue(description: "duplicate navigation transition terminal")
        XCTAssertEqual(committedMutationCount, 1)
    }

    @MainActor
    func testPresentationReceiptHandoffReplacesOutstandingMentionWakeupAndCommitsOnce()
        throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(
                label: "ChatViewportReadBoundaryTests.mention.presentation-handoff"
            )
        )
        AccountManager.shared.users.append(account)
        let controller = makeController(conversationType: .group)
        _ = configureReadGeometry(
            for: controller,
            primary: "mention-message",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80)
        )
        try seedUnreadMention(
            notificationPrimary: "mention-notification",
            messagePrimary: "mention-message"
        )
        controller.readVisiblePresentationSnapshotProvider = {
            self.readVisiblePresentationSnapshot(
                isTopNavigationDestination: true
            )
        }
        controller.readVisiblePresentationCoordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "mention-notification",
                messagePrimary: "mention-message"
            )
        ])

        // A pre-receipt attempt may still own this slot while its callback is
        // being consumed or cancelled. The appearance receipt must publish a
        // fresh wakeup instead of treating non-nil as proof of future work.
        let outstandingPreReceiptWakeup = DispatchWorkItem {}
        controller.visibleUnreadMentionReconciliationWorkItem =
            outstandingPreReceiptWakeup

        let committed = expectation(
            description: "presentation handoff commits the pending mention"
        )
        var firstPersistentMutationCount = 0
        var terminalOutcomes: [Bool] = []
        controller.visibleMentionReadAfterFirstPersistentMutationBarrierForTests = {
            firstPersistentMutationCount += 1
        }
        controller.visibleMentionReadTerminalForTests = { didCommit in
            terminalOutcomes.append(didCommit)
            committed.fulfill()
        }

        let firstHandoff = controller
            .recordReadVisiblePresentationReceiptHandoff()
        let duplicateHandoff = controller
            .recordReadVisiblePresentationReceiptHandoff()

        XCTAssertTrue(
            controller.readVisiblePresentationCoordinator.hasPresentationReceipt
        )
        let beforeFreshWakeupRealm = try WRealm.safe()
        XCTAssertFalse(try XCTUnwrap(beforeFreshWakeupRealm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: "mention-notification"
        )).isRead)
        XCTAssertFalse(try XCTUnwrap(beforeFreshWakeupRealm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: "mention-message"
        )).isRead)
        XCTAssertEqual(firstPersistentMutationCount, 0)
        XCTAssertFalse(outstandingPreReceiptWakeup.isCancelled)
        XCTAssertTrue(
            controller.visibleUnreadMentionReconciliationWorkItem ===
                outstandingPreReceiptWakeup
        )

        controller.enqueuePendingReadStateRetry(for: firstHandoff)
        controller.enqueuePendingReadStateRetry(for: duplicateHandoff)
        wait(for: [committed], timeout: 2)

        let realm = try WRealm.safe()
        realm.refresh()
        XCTAssertTrue(try XCTUnwrap(realm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: "mention-notification"
        )).isRead)
        XCTAssertTrue(try XCTUnwrap(realm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: "mention-message"
        )).isRead)
        XCTAssertTrue(outstandingPreReceiptWakeup.isCancelled)
        XCTAssertEqual(firstPersistentMutationCount, 1)
        XCTAssertEqual(terminalOutcomes, [true])
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            1
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            0
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.inFlightFlushCount,
            0
        )
        XCTAssertNil(controller.visibleUnreadMentionReconciliationWorkItem)
        XCTAssertNil(controller.readVisibleStableLayoutRetryWorkItem)
    }

    @MainActor
    func testSupersededPresentationReceiptHandoffCannotWakeLaterGeneration()
        throws {
        let controller = makeController(conversationType: .group)
        _ = configureReadGeometry(
            for: controller,
            primary: "mention-message",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80)
        )
        try seedUnreadMention(
            notificationPrimary: "mention-notification",
            messagePrimary: "mention-message"
        )
        controller.readVisiblePresentationSnapshotProvider = {
            self.readVisiblePresentationSnapshot(
                isTopNavigationDestination: true
            )
        }
        let candidate = ChatPendingMentionReadCandidate(
            notificationPrimary: "mention-notification",
            messagePrimary: "mention-message"
        )
        controller.readVisiblePresentationCoordinator.enqueue([candidate])

        let staleHandoff = controller
            .recordReadVisiblePresentationReceiptHandoff()

        controller.readVisiblePresentationCoordinator.invalidatePresentation()
        controller.readVisiblePresentationCoordinator.enqueue([candidate])
        controller.readVisiblePresentationCoordinator.recordPresentationReceipt()
        let laterGenerationWakeup = DispatchWorkItem {}
        controller.visibleUnreadMentionReconciliationWorkItem =
            laterGenerationWakeup
        controller.enqueuePendingReadStateRetry(for: staleHandoff)

        let staleHandoffTurnDrained = expectation(
            description: "superseded receipt handoff main turn drained"
        )
        DispatchQueue.main.async {
            staleHandoffTurnDrained.fulfill()
        }
        wait(for: [staleHandoffTurnDrained], timeout: 1)

        let realm = try WRealm.safe()
        XCTAssertFalse(try XCTUnwrap(realm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: "mention-notification"
        )).isRead)
        XCTAssertFalse(try XCTUnwrap(realm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: "mention-message"
        )).isRead)
        XCTAssertFalse(laterGenerationWakeup.isCancelled)
        XCTAssertTrue(
            controller.visibleUnreadMentionReconciliationWorkItem ===
                laterGenerationWakeup
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            1
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.inFlightFlushCount,
            0
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            0
        )

        laterGenerationWakeup.cancel()
        controller.visibleUnreadMentionReconciliationWorkItem = nil
        controller.readVisiblePresentationCoordinator.invalidatePresentation()
    }

    func testInvalidationAfterMentionFlushCaptureBeforeRealmCommitProducesZeroReadMutations() throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.mention.invalidated")
        )
        AccountManager.shared.users.append(account)
        let controller = makeController(conversationType: .group)
        let layout = configureReadGeometry(
            for: controller,
            primary: "mention-message",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80)
        )
        _ = layout
        try seedUnreadMention(
            notificationPrimary: "mention-notification",
            messagePrimary: "mention-message"
        )
        authorizeReadVisiblePresentation(controller)
        controller.readVisiblePresentationCoordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "mention-notification",
                messagePrimary: "mention-message"
            )
        ])

        let permitBoundaryEntered = expectation(description: "flush captured before commit permit")
        let staleWorkFinished = expectation(description: "stale mutation rejected")
        let releasePermitBoundary = DispatchSemaphore(value: 0)
        var linkedReadMessageCount = 0
        var uiRefreshCount = 0
        var retryCount = 0
        controller.visibleMentionReadCommitBarrierForTests = {
            permitBoundaryEntered.fulfill()
            XCTAssertEqual(releasePermitBoundary.wait(timeout: .now() + 2), .success)
        }
        controller.visibleMentionReadMessageWillExecuteForTests = { _ in
            linkedReadMessageCount += 1
        }
        controller.visibleMentionReadUIRefreshForTests = {
            uiRefreshCount += 1
        }
        controller.visibleMentionReadRetryForTests = {
            retryCount += 1
        }
        controller.visibleMentionReadTerminalForTests = { didCommit in
            XCTAssertFalse(didCommit)
            staleWorkFinished.fulfill()
        }

        controller.flushPendingVisibleUnreadMentionReconciliationIfPossible()
        wait(for: [permitBoundaryEntered], timeout: 1)

        controller.readVisiblePresentationCoordinator.invalidatePresentation()
        releasePermitBoundary.signal()
        wait(for: [staleWorkFinished], timeout: 2)

        let realm = try WRealm.safe()
        let notification = try XCTUnwrap(
            realm.object(
                ofType: NotificationStorageItem.self,
                forPrimaryKey: "mention-notification"
            )
        )
        let message = try XCTUnwrap(
            realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: "mention-message"
            )
        )
        let chat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .group
                )
            )
        )

        XCTAssertFalse(notification.isRead)
        XCTAssertTrue(notification.shouldShow)
        XCTAssertEqual(notification.mentionLinkStatus, .resolved)
        XCTAssertFalse(message.isRead)
        XCTAssertEqual(message.state, .deliver)
        XCTAssertLessThanOrEqual(message.readDate, 1)
        XCTAssertEqual(chat.syncUnreadCount, 1)
        XCTAssertEqual(chat.unread, 1)
        XCTAssertEqual(chat.lastReadId, "100")
        XCTAssertEqual(chat.mentionId, "200")
        XCTAssertNil(chat.displayedId)
        XCTAssertEqual(linkedReadMessageCount, 0)
        XCTAssertEqual(uiRefreshCount, 0)
        XCTAssertEqual(retryCount, 0)
        XCTAssertEqual(controller.readVisiblePresentationCoordinator.successfulFlushCount, 0)
        XCTAssertEqual(controller.readVisiblePresentationCoordinator.pendingCandidateCount, 0)
        XCTAssertNil(controller.visibleUnreadMentionReconciliationWorkItem)
    }

    func testBackgroundAfterMentionFlushCaptureSuspendsWithoutMutationAndCommitsOnceAfterForegroundReceipt() throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.mention.background")
        )
        AccountManager.shared.users.append(account)
        let controller = makeController(conversationType: .group)
        _ = configureReadGeometry(
            for: controller,
            primary: "mention-message",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80)
        )
        try seedUnreadMention(
            notificationPrimary: "mention-notification",
            messagePrimary: "mention-message"
        )
        authorizeReadVisiblePresentation(controller)
        controller.readVisiblePresentationCoordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "mention-notification",
                messagePrimary: "mention-message"
            )
        ])

        let firstPermitBoundaryEntered = expectation(
            description: "captured flush reaches pre-permit boundary"
        )
        let suspendedFlushRejected = expectation(
            description: "background-revoked flush is rejected"
        )
        let foregroundFlushCommitted = expectation(
            description: "preserved candidate commits after foreground receipt"
        )
        let releaseFirstPermitBoundary = DispatchSemaphore(value: 0)
        let observationLock = NSLock()
        var barrierVisitCount = 0
        var linkedReadMessageCount = 0
        var uiRefreshCount = 0
        var retryCount = 0
        var terminalOutcomes: [Bool] = []

        controller.visibleMentionReadCommitBarrierForTests = {
            observationLock.lock()
            barrierVisitCount += 1
            let shouldSuspendAtThisBoundary = barrierVisitCount == 1
            observationLock.unlock()
            guard shouldSuspendAtThisBoundary else {
                return
            }
            firstPermitBoundaryEntered.fulfill()
            XCTAssertEqual(
                releaseFirstPermitBoundary.wait(timeout: .now() + 2),
                .success
            )
        }
        controller.visibleMentionReadMessageWillExecuteForTests = { _ in
            observationLock.lock()
            linkedReadMessageCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadUIRefreshForTests = {
            observationLock.lock()
            uiRefreshCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadRetryForTests = {
            observationLock.lock()
            retryCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadTerminalForTests = { didCommit in
            observationLock.lock()
            terminalOutcomes.append(didCommit)
            observationLock.unlock()
            if didCommit {
                foregroundFlushCommitted.fulfill()
            } else {
                suspendedFlushRejected.fulfill()
            }
        }

        let generationBeforeBackground =
            controller.readVisiblePresentationCoordinator.generation
        controller.flushPendingVisibleUnreadMentionReconciliationIfPossible()
        wait(for: [firstPermitBoundaryEntered], timeout: 1)

        controller.handleApplicationDidEnterBackground()
        let suspendedGeneration =
            controller.readVisiblePresentationCoordinator.generation
        XCTAssertEqual(suspendedGeneration, generationBeforeBackground &+ 1)
        XCTAssertFalse(
            controller.readVisiblePresentationCoordinator.hasPresentationReceipt
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            1,
            "background suspension must requeue the captured candidate"
        )

        controller.handleApplicationDidEnterBackground()
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.generation,
            suspendedGeneration,
            "repeated background notifications must be idempotent"
        )
        controller.readVisiblePresentationCoordinator.recordPresentationReceipt()
        XCTAssertFalse(
            controller.readVisiblePresentationCoordinator.hasPresentationReceipt,
            "viewDidAppear-style receipt recording must not bypass suspension"
        )

        releaseFirstPermitBoundary.signal()
        wait(for: [suspendedFlushRejected], timeout: 2)

        do {
            let realm = try WRealm.safe()
            let notification = try XCTUnwrap(
                realm.object(
                    ofType: NotificationStorageItem.self,
                    forPrimaryKey: "mention-notification"
                )
            )
            let message = try XCTUnwrap(
                realm.object(
                    ofType: MessageStorageItem.self,
                    forPrimaryKey: "mention-message"
                )
            )
            let chat = try XCTUnwrap(
                realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: jid,
                        owner: owner,
                        conversationType: .group
                    )
                )
            )

            XCTAssertFalse(notification.isRead)
            XCTAssertTrue(notification.shouldShow)
            XCTAssertEqual(notification.mentionLinkStatus, .resolved)
            XCTAssertFalse(message.isRead)
            XCTAssertEqual(message.state, .deliver)
            XCTAssertLessThanOrEqual(message.readDate, 1)
            XCTAssertEqual(chat.syncUnreadCount, 1)
            XCTAssertEqual(chat.unread, 1)
            XCTAssertEqual(chat.lastReadId, "100")
            XCTAssertEqual(chat.mentionId, "200")
            XCTAssertNil(chat.displayedId)
        }

        observationLock.lock()
        let suspendedLinkedReadCount = linkedReadMessageCount
        let suspendedUIRefreshCount = uiRefreshCount
        let suspendedRetryCount = retryCount
        let suspendedTerminalOutcomes = terminalOutcomes
        observationLock.unlock()
        XCTAssertEqual(suspendedLinkedReadCount, 0)
        XCTAssertEqual(suspendedUIRefreshCount, 0)
        XCTAssertEqual(suspendedRetryCount, 0)
        XCTAssertEqual(suspendedTerminalOutcomes, [false])
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            0
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            1
        )

        let structurallyRejectedResumeProcessed = expectation(
            description: "foreground without structural destination stays suspended"
        )
        controller.readVisiblePresentationSnapshotProvider = {
            self.readVisiblePresentationSnapshot(
                isTopNavigationDestination: false
            )
        }
        controller.didBecomeActive()
        DispatchQueue.main.async {
            structurallyRejectedResumeProcessed.fulfill()
        }
        wait(for: [structurallyRejectedResumeProcessed], timeout: 1)
        XCTAssertFalse(
            controller.readVisiblePresentationCoordinator.hasPresentationReceipt
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            1
        )

        controller.readVisiblePresentationSnapshotProvider = {
            self.readVisiblePresentationSnapshot(
                isTopNavigationDestination: true
            )
        }
        controller.didBecomeActive()
        wait(for: [foregroundFlushCommitted], timeout: 2)

        let finalRealm = try WRealm.safe()
        finalRealm.refresh()
        let finalNotification = try XCTUnwrap(
            finalRealm.object(
                ofType: NotificationStorageItem.self,
                forPrimaryKey: "mention-notification"
            )
        )
        let finalMessage = try XCTUnwrap(
            finalRealm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: "mention-message"
            )
        )
        let finalChat = try XCTUnwrap(
            finalRealm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .group
                )
            )
        )

        XCTAssertTrue(finalNotification.isRead)
        XCTAssertTrue(finalMessage.isRead)
        XCTAssertEqual(finalMessage.state, .read)
        XCTAssertGreaterThan(finalMessage.readDate, 1)
        XCTAssertEqual(finalChat.syncUnreadCount, 0)
        XCTAssertEqual(finalChat.unread, 0)
        XCTAssertEqual(finalChat.lastReadId, "200")
        XCTAssertNil(finalChat.mentionId)

        observationLock.lock()
        let finalBarrierVisitCount = barrierVisitCount
        let finalLinkedReadCount = linkedReadMessageCount
        let finalUIRefreshCount = uiRefreshCount
        let finalRetryCount = retryCount
        let finalTerminalOutcomes = terminalOutcomes
        observationLock.unlock()
        XCTAssertEqual(finalBarrierVisitCount, 2)
        XCTAssertEqual(finalLinkedReadCount, 1)
        XCTAssertEqual(finalUIRefreshCount, 1)
        XCTAssertEqual(finalRetryCount, 0)
        XCTAssertEqual(finalTerminalOutcomes, [false, true])
        XCTAssertTrue(
            controller.readVisiblePresentationCoordinator.hasPresentationReceipt
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            1
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            0
        )
        XCTAssertNil(controller.visibleUnreadMentionReconciliationWorkItem)
    }

    func testBackgroundAfterMentionPermitClaimBeforeFirstRealmMutationRevokesWithoutEffectsAndReplaysOnce() throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.mention.post-claim")
        )
        AccountManager.shared.users.append(account)
        let controller = makeController(conversationType: .group)
        _ = configureReadGeometry(
            for: controller,
            primary: "mention-message",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80)
        )
        try seedUnreadMention(
            notificationPrimary: "mention-notification",
            messagePrimary: "mention-message"
        )
        authorizeReadVisiblePresentation(controller)
        controller.readVisiblePresentationCoordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "mention-notification",
                messagePrimary: "mention-message"
            )
        ])

        let claimedPermitBoundaryEntered = expectation(
            description: "permit claimed before first Realm mutation"
        )
        let revokedFlushRejected = expectation(
            description: "post-claim flush rejected before mutation"
        )
        let foregroundFlushCommitted = expectation(
            description: "post-claim candidate replays once in foreground"
        )
        let releaseClaimedPermitBoundary = DispatchSemaphore(value: 0)
        let observationLock = NSLock()
        var postClaimVisitCount = 0
        var linkedReadMessageCount = 0
        var uiRefreshCount = 0
        var retryCount = 0
        var terminalOutcomes: [Bool] = []

        controller.visibleMentionReadPostClaimBarrierForTests = {
            observationLock.lock()
            postClaimVisitCount += 1
            let shouldSuspendAtThisBoundary = postClaimVisitCount == 1
            observationLock.unlock()
            guard shouldSuspendAtThisBoundary else {
                return
            }
            claimedPermitBoundaryEntered.fulfill()
            XCTAssertEqual(
                releaseClaimedPermitBoundary.wait(timeout: .now() + 2),
                .success
            )
        }
        controller.visibleMentionReadMessageWillExecuteForTests = { _ in
            observationLock.lock()
            linkedReadMessageCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadUIRefreshForTests = {
            observationLock.lock()
            uiRefreshCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadRetryForTests = {
            observationLock.lock()
            retryCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadTerminalForTests = { didCommit in
            observationLock.lock()
            terminalOutcomes.append(didCommit)
            observationLock.unlock()
            if didCommit {
                foregroundFlushCommitted.fulfill()
            } else {
                revokedFlushRejected.fulfill()
            }
        }

        controller.flushPendingVisibleUnreadMentionReconciliationIfPossible()
        wait(for: [claimedPermitBoundaryEntered], timeout: 1)

        controller.handleApplicationDidEnterBackground()
        XCTAssertFalse(
            controller.readVisiblePresentationCoordinator.hasPresentationReceipt
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            1
        )
        releaseClaimedPermitBoundary.signal()
        wait(for: [revokedFlushRejected], timeout: 2)

        do {
            let realm = try WRealm.safe()
            let notification = try XCTUnwrap(
                realm.object(
                    ofType: NotificationStorageItem.self,
                    forPrimaryKey: "mention-notification"
                )
            )
            let message = try XCTUnwrap(
                realm.object(
                    ofType: MessageStorageItem.self,
                    forPrimaryKey: "mention-message"
                )
            )
            XCTAssertFalse(notification.isRead)
            XCTAssertTrue(notification.shouldShow)
            XCTAssertFalse(message.isRead)
            XCTAssertEqual(message.state, .deliver)
            XCTAssertLessThanOrEqual(message.readDate, 1)
        }

        observationLock.lock()
        let suspendedLinkedReadCount = linkedReadMessageCount
        let suspendedUIRefreshCount = uiRefreshCount
        let suspendedRetryCount = retryCount
        let suspendedTerminalOutcomes = terminalOutcomes
        observationLock.unlock()
        XCTAssertEqual(suspendedLinkedReadCount, 0)
        XCTAssertEqual(suspendedUIRefreshCount, 0)
        XCTAssertEqual(suspendedRetryCount, 0)
        XCTAssertEqual(suspendedTerminalOutcomes, [false])
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            0
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            1
        )

        controller.didBecomeActive()
        wait(for: [foregroundFlushCommitted], timeout: 2)

        let finalRealm = try WRealm.safe()
        finalRealm.refresh()
        let finalNotification = try XCTUnwrap(
            finalRealm.object(
                ofType: NotificationStorageItem.self,
                forPrimaryKey: "mention-notification"
            )
        )
        let finalMessage = try XCTUnwrap(
            finalRealm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: "mention-message"
            )
        )
        XCTAssertTrue(finalNotification.isRead)
        XCTAssertTrue(finalMessage.isRead)
        XCTAssertEqual(finalMessage.state, .read)

        observationLock.lock()
        let finalPostClaimVisitCount = postClaimVisitCount
        let finalLinkedReadCount = linkedReadMessageCount
        let finalUIRefreshCount = uiRefreshCount
        let finalRetryCount = retryCount
        let finalTerminalOutcomes = terminalOutcomes
        observationLock.unlock()
        XCTAssertEqual(finalPostClaimVisitCount, 2)
        XCTAssertEqual(finalLinkedReadCount, 1)
        XCTAssertEqual(finalUIRefreshCount, 1)
        XCTAssertEqual(finalRetryCount, 0)
        XCTAssertEqual(finalTerminalOutcomes, [false, true])
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            1
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            0
        )
    }

    func testBackgroundAfterFirstRealmMutationCompletesOnceWithoutForegroundReplay() throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.mention.started")
        )
        AccountManager.shared.users.append(account)
        let controller = makeController(conversationType: .group)
        _ = configureReadGeometry(
            for: controller,
            primary: "mention-message",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80)
        )
        try seedUnreadMention(
            notificationPrimary: "mention-notification",
            messagePrimary: "mention-message"
        )
        authorizeReadVisiblePresentation(controller)
        controller.readVisiblePresentationCoordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "mention-notification",
                messagePrimary: "mention-message"
            )
        ])

        let firstRealmMutationApplied = expectation(
            description: "first Realm mutation wins linearization"
        )
        let startedFlushFinished = expectation(
            description: "started transaction completes while presentation is suspended"
        )
        let foregroundResumeProcessed = expectation(
            description: "foreground resume processed without replay"
        )
        let releaseStartedTransaction = DispatchSemaphore(value: 0)
        let observationLock = NSLock()
        var firstMutationBarrierCount = 0
        var linkedReadMessageCount = 0
        var uiRefreshCount = 0
        var retryCount = 0
        var terminalOutcomes: [Bool] = []

        controller.visibleMentionReadAfterFirstPersistentMutationBarrierForTests = {
            observationLock.lock()
            firstMutationBarrierCount += 1
            observationLock.unlock()
            firstRealmMutationApplied.fulfill()
            XCTAssertEqual(
                releaseStartedTransaction.wait(timeout: .now() + 2),
                .success
            )
        }
        controller.visibleMentionReadBackgroundSuspendedForTests = {
            releaseStartedTransaction.signal()
        }
        controller.visibleMentionReadMessageWillExecuteForTests = { _ in
            observationLock.lock()
            linkedReadMessageCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadUIRefreshForTests = {
            observationLock.lock()
            uiRefreshCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadRetryForTests = {
            observationLock.lock()
            retryCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadTerminalForTests = { didCommit in
            observationLock.lock()
            terminalOutcomes.append(didCommit)
            observationLock.unlock()
            startedFlushFinished.fulfill()
        }

        controller.flushPendingVisibleUnreadMentionReconciliationIfPossible()
        wait(for: [firstRealmMutationApplied], timeout: 1)

        controller.handleApplicationDidEnterBackground()
        wait(for: [startedFlushFinished], timeout: 2)

        let backgroundRealm = try WRealm.safe()
        backgroundRealm.refresh()
        let backgroundNotification = try XCTUnwrap(
            backgroundRealm.object(
                ofType: NotificationStorageItem.self,
                forPrimaryKey: "mention-notification"
            )
        )
        let backgroundMessage = try XCTUnwrap(
            backgroundRealm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: "mention-message"
            )
        )
        XCTAssertTrue(backgroundNotification.isRead)
        XCTAssertTrue(backgroundMessage.isRead)
        XCTAssertEqual(backgroundMessage.state, .read)
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            0,
            "a flush that won the first-mutation boundary must not be requeued"
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            1
        )

        controller.didBecomeActive()
        DispatchQueue.main.async {
            foregroundResumeProcessed.fulfill()
        }
        wait(for: [foregroundResumeProcessed], timeout: 1)
        controller.flushPendingVisibleUnreadMentionReconciliationIfPossible()
        controller.retryPendingVisibleUnreadMentionReconciliation()

        observationLock.lock()
        let finalFirstMutationBarrierCount = firstMutationBarrierCount
        let finalLinkedReadCount = linkedReadMessageCount
        let finalUIRefreshCount = uiRefreshCount
        let finalRetryCount = retryCount
        let finalTerminalOutcomes = terminalOutcomes
        observationLock.unlock()
        XCTAssertEqual(finalFirstMutationBarrierCount, 1)
        XCTAssertEqual(finalLinkedReadCount, 1)
        XCTAssertEqual(finalUIRefreshCount, 0)
        XCTAssertEqual(finalRetryCount, 0)
        XCTAssertEqual(finalTerminalOutcomes, [true])
        XCTAssertTrue(
            controller.readVisiblePresentationCoordinator.hasPresentationReceipt
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            0
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            1
        )
        XCTAssertNil(controller.visibleUnreadMentionReconciliationWorkItem)
    }

    func testMissingMentionNotificationCompletesAsNoOpWithoutDeclaringPersistentMutation() throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.mention.no-op")
        )
        AccountManager.shared.users.append(account)
        let controller = makeController(conversationType: .group)
        _ = configureReadGeometry(
            for: controller,
            primary: "mention-message",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80)
        )
        try seedUnreadMention(
            notificationPrimary: "mention-notification",
            messagePrimary: "mention-message"
        )
        let seedRealm = try WRealm.safe()
        try seedRealm.write {
            if let notification = seedRealm.object(
                ofType: NotificationStorageItem.self,
                forPrimaryKey: "mention-notification"
            ) {
                seedRealm.delete(notification)
            }
        }
        authorizeReadVisiblePresentation(controller)
        controller.readVisiblePresentationCoordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "mention-notification",
                messagePrimary: "mention-message"
            )
        ])

        let noOpCompleted = expectation(
            description: "missing notification resolves as terminal no-op"
        )
        var firstPersistentMutationCount = 0
        var linkedReadMessageCount = 0
        var uiRefreshCount = 0
        controller.visibleMentionReadAfterFirstPersistentMutationBarrierForTests = {
            firstPersistentMutationCount += 1
        }
        controller.visibleMentionReadMessageWillExecuteForTests = { _ in
            linkedReadMessageCount += 1
        }
        controller.visibleMentionReadUIRefreshForTests = {
            uiRefreshCount += 1
        }
        controller.visibleMentionReadTerminalForTests = { succeeded in
            XCTAssertTrue(succeeded)
            noOpCompleted.fulfill()
        }

        controller.flushPendingVisibleUnreadMentionReconciliationIfPossible()
        wait(for: [noOpCompleted], timeout: 2)

        let finalRealm = try WRealm.safe()
        finalRealm.refresh()
        let message = try XCTUnwrap(
            finalRealm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: "mention-message"
            )
        )
        let chat = try XCTUnwrap(
            finalRealm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .group
                )
            )
        )
        XCTAssertFalse(message.isRead)
        XCTAssertEqual(message.state, .deliver)
        XCTAssertEqual(chat.syncUnreadCount, 1)
        XCTAssertEqual(chat.unread, 1)
        XCTAssertEqual(chat.lastReadId, "100")
        XCTAssertEqual(chat.mentionId, "200")
        XCTAssertEqual(firstPersistentMutationCount, 0)
        XCTAssertEqual(linkedReadMessageCount, 0)
        XCTAssertEqual(uiRefreshCount, 0)
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            0,
            "a provably absent stale notification is consumed as a terminal no-op"
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            1
        )
    }

    func testMentionTargetLeavesMeaningfulViewportAfterFlushCaptureBeforeRealmMutationProducesZeroReadEffects() throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.mention.geometry")
        )
        AccountManager.shared.users.append(account)
        let controller = makeController(conversationType: .group)
        let layout = configureReadGeometry(
            for: controller,
            primary: "mention-message",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80)
        )
        try seedUnreadMention(
            notificationPrimary: "mention-notification",
            messagePrimary: "mention-message"
        )
        authorizeReadVisiblePresentation(controller)
        controller.readVisiblePresentationCoordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "mention-notification",
                messagePrimary: "mention-message"
            )
        ])

        let capturedBeforeGeometryAdmission = expectation(
            description: "mention flush captured before current geometry admission"
        )
        let offscreenFlushRejected = expectation(
            description: "offscreen captured flush is rejected without mutation"
        )
        let visibleRetryCommitted = expectation(
            description: "later genuinely visible sample commits once"
        )
        let releaseCapturedFlush = DispatchSemaphore(value: 0)
        let observationLock = NSLock()
        var captureCount = 0
        var linkedReadMessageCount = 0
        var uiRefreshCount = 0
        var retryCount = 0
        var terminalOutcomes: [Bool] = []

        controller.visibleMentionReadCommitBarrierForTests = {
            observationLock.lock()
            captureCount += 1
            let shouldPause = captureCount == 1
            observationLock.unlock()
            guard shouldPause else {
                return
            }
            capturedBeforeGeometryAdmission.fulfill()
            XCTAssertEqual(releaseCapturedFlush.wait(timeout: .now() + 2), .success)
        }
        controller.visibleMentionReadMessageWillExecuteForTests = { _ in
            observationLock.lock()
            linkedReadMessageCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadUIRefreshForTests = {
            observationLock.lock()
            uiRefreshCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadRetryForTests = {
            observationLock.lock()
            retryCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadTerminalForTests = { didCommit in
            observationLock.lock()
            terminalOutcomes.append(didCommit)
            observationLock.unlock()
            if didCommit {
                visibleRetryCommitted.fulfill()
            } else {
                offscreenFlushRejected.fulfill()
            }
        }

        controller.flushPendingVisibleUnreadMentionReconciliationIfPossible()
        wait(for: [capturedBeforeGeometryAdmission], timeout: 1)

        let targetIndexPath = IndexPath(item: 0, section: 0)
        layout.frames[targetIndexPath] = CGRect(x: 0, y: 95, width: 320, height: 80)
        layout.invalidateLayout()
        releaseCapturedFlush.signal()
        wait(for: [offscreenFlushRejected], timeout: 2)

        do {
            let realm = try WRealm.safe()
            let notification = try XCTUnwrap(
                realm.object(
                    ofType: NotificationStorageItem.self,
                    forPrimaryKey: "mention-notification"
                )
            )
            let message = try XCTUnwrap(
                realm.object(
                    ofType: MessageStorageItem.self,
                    forPrimaryKey: "mention-message"
                )
            )
            let chat = try XCTUnwrap(
                realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: jid,
                        owner: owner,
                        conversationType: .group
                    )
                )
            )
            XCTAssertFalse(notification.isRead)
            XCTAssertTrue(notification.shouldShow)
            XCTAssertFalse(message.isRead)
            XCTAssertEqual(message.state, .deliver)
            XCTAssertLessThanOrEqual(message.readDate, 1)
            XCTAssertEqual(chat.syncUnreadCount, 1)
            XCTAssertEqual(chat.unread, 1)
            XCTAssertEqual(chat.lastReadId, "100")
            XCTAssertEqual(chat.mentionId, "200")
            XCTAssertNil(chat.displayedId)
        }

        observationLock.lock()
        let rejectedCaptureCount = captureCount
        let rejectedLinkedReadCount = linkedReadMessageCount
        let rejectedUIRefreshCount = uiRefreshCount
        let rejectedRetryCount = retryCount
        let rejectedTerminalOutcomes = terminalOutcomes
        observationLock.unlock()
        XCTAssertEqual(rejectedCaptureCount, 1)
        XCTAssertEqual(rejectedLinkedReadCount, 0)
        XCTAssertEqual(rejectedUIRefreshCount, 0)
        XCTAssertEqual(rejectedRetryCount, 0, "geometry rejection must not busy-retry")
        XCTAssertEqual(rejectedTerminalOutcomes, [false])
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            0
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            1,
            "the unread mention remains eligible for a later visible sample"
        )
        XCTAssertNil(controller.visibleUnreadMentionReconciliationWorkItem)

        layout.frames[targetIndexPath] = CGRect(x: 0, y: 20, width: 320, height: 80)
        layout.invalidateLayout()
        controller.retryPendingVisibleUnreadMentionReconciliation()
        wait(for: [visibleRetryCommitted], timeout: 2)

        let finalRealm = try WRealm.safe()
        finalRealm.refresh()
        XCTAssertTrue(try XCTUnwrap(finalRealm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: "mention-notification"
        )).isRead)
        XCTAssertTrue(try XCTUnwrap(finalRealm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: "mention-message"
        )).isRead)

        observationLock.lock()
        let finalCaptureCount = captureCount
        let finalLinkedReadCount = linkedReadMessageCount
        let finalUIRefreshCount = uiRefreshCount
        let finalRetryCount = retryCount
        let finalTerminalOutcomes = terminalOutcomes
        observationLock.unlock()
        XCTAssertEqual(finalCaptureCount, 2)
        XCTAssertEqual(finalLinkedReadCount, 1)
        XCTAssertEqual(finalUIRefreshCount, 1)
        XCTAssertEqual(finalRetryCount, 0)
        XCTAssertEqual(finalTerminalOutcomes, [false, true])
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            1
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            0
        )
    }

    func testSamePrimaryReplacementAfterMentionFlushCaptureCannotAuthorizeOldFlush() throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.mention.identity")
        )
        AccountManager.shared.users.append(account)
        let controller = makeController(conversationType: .group)
        _ = configureReadGeometry(
            for: controller,
            primary: "mention-message",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80)
        )
        let originalRow = try XCTUnwrap(controller.datasource.first)
        try seedUnreadMention(
            notificationPrimary: "mention-notification",
            messagePrimary: "mention-message"
        )
        authorizeReadVisiblePresentation(controller)
        controller.readVisiblePresentationCoordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "mention-notification",
                messagePrimary: "mention-message"
            )
        ])

        let capturedBeforeIdentityAdmission = expectation(
            description: "mention flush captured with original row identity"
        )
        let replacementRejected = expectation(
            description: "same-primary replacement cannot authorize old flush"
        )
        let restoredOriginalCommitted = expectation(
            description: "restored original logical row commits once"
        )
        let releaseCapturedFlush = DispatchSemaphore(value: 0)
        let observationLock = NSLock()
        var captureCount = 0
        var linkedReadMessageCount = 0
        var uiRefreshCount = 0
        var terminalOutcomes: [Bool] = []

        controller.visibleMentionReadCommitBarrierForTests = {
            observationLock.lock()
            captureCount += 1
            let shouldPause = captureCount == 1
            observationLock.unlock()
            guard shouldPause else {
                return
            }
            capturedBeforeIdentityAdmission.fulfill()
            XCTAssertEqual(releaseCapturedFlush.wait(timeout: .now() + 2), .success)
        }
        controller.visibleMentionReadMessageWillExecuteForTests = { _ in
            observationLock.lock()
            linkedReadMessageCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadUIRefreshForTests = {
            observationLock.lock()
            uiRefreshCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadTerminalForTests = { didCommit in
            observationLock.lock()
            terminalOutcomes.append(didCommit)
            observationLock.unlock()
            if didCommit {
                restoredOriginalCommitted.fulfill()
            } else {
                replacementRejected.fulfill()
            }
        }

        controller.flushPendingVisibleUnreadMentionReconciliationIfPossible()
        wait(for: [capturedBeforeIdentityAdmission], timeout: 1)

        var replacementRow = originalRow
        replacementRow.messageId = "same-primary-replacement-message-id"
        replacementRow.sentDate = Date(timeIntervalSince1970: 200)
        controller.datasource = [replacementRow]
        releaseCapturedFlush.signal()
        wait(for: [replacementRejected], timeout: 2)

        let rejectedRealm = try WRealm.safe()
        XCTAssertFalse(try XCTUnwrap(rejectedRealm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: "mention-notification"
        )).isRead)
        XCTAssertFalse(try XCTUnwrap(rejectedRealm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: "mention-message"
        )).isRead)
        observationLock.lock()
        let rejectedLinkedReadCount = linkedReadMessageCount
        let rejectedUIRefreshCount = uiRefreshCount
        let rejectedTerminalOutcomes = terminalOutcomes
        observationLock.unlock()
        XCTAssertEqual(rejectedLinkedReadCount, 0)
        XCTAssertEqual(rejectedUIRefreshCount, 0)
        XCTAssertEqual(rejectedTerminalOutcomes, [false])
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            0
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            1
        )

        controller.datasource = [originalRow]
        controller.retryPendingVisibleUnreadMentionReconciliation()
        wait(for: [restoredOriginalCommitted], timeout: 2)

        let finalRealm = try WRealm.safe()
        finalRealm.refresh()
        XCTAssertTrue(try XCTUnwrap(finalRealm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: "mention-notification"
        )).isRead)
        XCTAssertTrue(try XCTUnwrap(finalRealm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: "mention-message"
        )).isRead)
        observationLock.lock()
        let finalCaptureCount = captureCount
        let finalLinkedReadCount = linkedReadMessageCount
        let finalUIRefreshCount = uiRefreshCount
        let finalTerminalOutcomes = terminalOutcomes
        observationLock.unlock()
        XCTAssertEqual(finalCaptureCount, 2)
        XCTAssertEqual(finalLinkedReadCount, 1)
        XCTAssertEqual(finalUIRefreshCount, 1)
        XCTAssertEqual(finalTerminalOutcomes, [false, true])
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            1
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            0
        )
    }

    func testMentionTargetLeavesMeaningfulViewportAfterPermitClaimBeforeFirstRealmMutationProducesZeroReadEffects() throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.mention.post-claim-geometry")
        )
        AccountManager.shared.users.append(account)
        let controller = makeController(conversationType: .group)
        let layout = configureReadGeometry(
            for: controller,
            primary: "mention-message",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80)
        )
        try seedUnreadMention(
            notificationPrimary: "mention-notification",
            messagePrimary: "mention-message"
        )
        authorizeReadVisiblePresentation(controller)
        controller.readVisiblePresentationCoordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "mention-notification",
                messagePrimary: "mention-message"
            )
        ])

        let permitClaimedBeforeFirstMutation = expectation(
            description: "permit claimed before first Realm mutation"
        )
        let staleClaimRejected = expectation(
            description: "geometry epoch revokes unstarted claimed permit"
        )
        let visibleRetryCommitted = expectation(
            description: "later visible geometry commits exactly once"
        )
        let releaseClaimedPermit = DispatchSemaphore(value: 0)
        let observationLock = NSLock()
        var postClaimCount = 0
        var firstPersistentMutationCount = 0
        var linkedReadMessageCount = 0
        var uiRefreshCount = 0
        var retryCount = 0
        var terminalOutcomes: [Bool] = []

        controller.visibleMentionReadPostClaimBarrierForTests = {
            observationLock.lock()
            postClaimCount += 1
            let shouldPause = postClaimCount == 1
            observationLock.unlock()
            guard shouldPause else {
                return
            }
            permitClaimedBeforeFirstMutation.fulfill()
            XCTAssertEqual(releaseClaimedPermit.wait(timeout: .now() + 2), .success)
        }
        controller.visibleMentionReadAfterFirstPersistentMutationBarrierForTests = {
            observationLock.lock()
            firstPersistentMutationCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadMessageWillExecuteForTests = { _ in
            observationLock.lock()
            linkedReadMessageCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadUIRefreshForTests = {
            observationLock.lock()
            uiRefreshCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadRetryForTests = {
            observationLock.lock()
            retryCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadTerminalForTests = { didCommit in
            observationLock.lock()
            terminalOutcomes.append(didCommit)
            observationLock.unlock()
            if didCommit {
                visibleRetryCommitted.fulfill()
            } else {
                staleClaimRejected.fulfill()
            }
        }

        controller.flushPendingVisibleUnreadMentionReconciliationIfPossible()
        wait(for: [permitClaimedBeforeFirstMutation], timeout: 1)

        let targetIndexPath = IndexPath(item: 0, section: 0)
        layout.frames[targetIndexPath] = CGRect(x: 0, y: 95, width: 320, height: 80)
        layout.invalidateLayout()
        controller.viewDidLayoutSubviews()
        releaseClaimedPermit.signal()
        wait(for: [staleClaimRejected], timeout: 2)

        do {
            let realm = try WRealm.safe()
            let notification = try XCTUnwrap(realm.object(
                ofType: NotificationStorageItem.self,
                forPrimaryKey: "mention-notification"
            ))
            let message = try XCTUnwrap(realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: "mention-message"
            ))
            let chat = try XCTUnwrap(realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .group
                )
            ))
            XCTAssertFalse(notification.isRead)
            XCTAssertTrue(notification.shouldShow)
            XCTAssertFalse(message.isRead)
            XCTAssertEqual(message.state, .deliver)
            XCTAssertLessThanOrEqual(message.readDate, 1)
            XCTAssertEqual(chat.syncUnreadCount, 1)
            XCTAssertEqual(chat.unread, 1)
            XCTAssertEqual(chat.lastReadId, "100")
            XCTAssertEqual(chat.mentionId, "200")
            XCTAssertNil(chat.displayedId)
        }

        observationLock.lock()
        let rejectedPostClaimCount = postClaimCount
        let rejectedFirstMutationCount = firstPersistentMutationCount
        let rejectedLinkedReadCount = linkedReadMessageCount
        let rejectedUIRefreshCount = uiRefreshCount
        let rejectedRetryCount = retryCount
        let rejectedTerminalOutcomes = terminalOutcomes
        observationLock.unlock()
        XCTAssertEqual(rejectedPostClaimCount, 1)
        XCTAssertEqual(rejectedFirstMutationCount, 0)
        XCTAssertEqual(rejectedLinkedReadCount, 0)
        XCTAssertEqual(rejectedUIRefreshCount, 0)
        XCTAssertEqual(rejectedRetryCount, 0, "geometry revocation must not busy-retry")
        XCTAssertEqual(rejectedTerminalOutcomes, [false])
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            0
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            1
        )
        XCTAssertNil(controller.visibleUnreadMentionReconciliationWorkItem)

        layout.frames[targetIndexPath] = CGRect(x: 0, y: 20, width: 320, height: 80)
        layout.invalidateLayout()
        controller.viewDidLayoutSubviews()
        controller.retryPendingVisibleUnreadMentionReconciliation()
        wait(for: [visibleRetryCommitted], timeout: 2)

        let finalRealm = try WRealm.safe()
        finalRealm.refresh()
        XCTAssertTrue(try XCTUnwrap(finalRealm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: "mention-notification"
        )).isRead)
        XCTAssertTrue(try XCTUnwrap(finalRealm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: "mention-message"
        )).isRead)
        observationLock.lock()
        let finalPostClaimCount = postClaimCount
        let finalFirstMutationCount = firstPersistentMutationCount
        let finalLinkedReadCount = linkedReadMessageCount
        let finalUIRefreshCount = uiRefreshCount
        let finalRetryCount = retryCount
        let finalTerminalOutcomes = terminalOutcomes
        observationLock.unlock()
        XCTAssertEqual(finalPostClaimCount, 2)
        XCTAssertEqual(finalFirstMutationCount, 1)
        XCTAssertEqual(finalLinkedReadCount, 1)
        XCTAssertEqual(finalUIRefreshCount, 1)
        XCTAssertEqual(finalRetryCount, 0)
        XCTAssertEqual(finalTerminalOutcomes, [false, true])
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            1
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            0
        )
    }

    func testPostClaimGeometryChangeThatKeepsTargetMeaningfullyVisibleRetriesOnceAfterStableLayoutReceipt() throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.mention.stable-layout")
        )
        AccountManager.shared.users.append(account)
        let controller = makeController(conversationType: .group)
        let layout = configureReadGeometry(
            for: controller,
            primary: "mention-message",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80)
        )
        try seedUnreadMention(
            notificationPrimary: "mention-notification",
            messagePrimary: "mention-message"
        )
        authorizeReadVisiblePresentation(controller)
        controller.readVisiblePresentationCoordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "mention-notification",
                messagePrimary: "mention-message"
            )
        ])

        let firstPermitClaimed = expectation(
            description: "first geometry owns a revocable permit"
        )
        let revokedWorkerFinished = expectation(
            description: "old geometry worker terminates without mutation"
        )
        let stableLayoutCommitted = expectation(
            description: "stable meaningful layout receipt retries exactly once"
        )
        let releaseFirstPermit = DispatchSemaphore(value: 0)
        let observationLock = NSLock()
        var postClaimCount = 0
        var firstPersistentMutationCount = 0
        var linkedReadMessageCount = 0
        var uiRefreshCount = 0
        var retryCount = 0
        var terminalOutcomes: [Bool] = []

        controller.visibleMentionReadPostClaimBarrierForTests = {
            observationLock.lock()
            postClaimCount += 1
            let shouldPause = postClaimCount == 1
            observationLock.unlock()
            guard shouldPause else {
                return
            }
            firstPermitClaimed.fulfill()
            XCTAssertEqual(releaseFirstPermit.wait(timeout: .now() + 2), .success)
        }
        controller.visibleMentionReadAfterFirstPersistentMutationBarrierForTests = {
            observationLock.lock()
            firstPersistentMutationCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadMessageWillExecuteForTests = { _ in
            observationLock.lock()
            linkedReadMessageCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadUIRefreshForTests = {
            observationLock.lock()
            uiRefreshCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadRetryForTests = {
            observationLock.lock()
            retryCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadTerminalForTests = { didCommit in
            observationLock.lock()
            terminalOutcomes.append(didCommit)
            observationLock.unlock()
            if didCommit {
                stableLayoutCommitted.fulfill()
            } else {
                revokedWorkerFinished.fulfill()
            }
        }

        controller.flushPendingVisibleUnreadMentionReconciliationIfPossible()
        wait(for: [firstPermitClaimed], timeout: 1)

        let targetIndexPath = IndexPath(item: 0, section: 0)
        layout.frames[targetIndexPath] = CGRect(x: 0, y: 10, width: 320, height: 90)
        layout.invalidateLayout()
        controller.viewDidLayoutSubviews()
        releaseFirstPermit.signal()
        wait(
            for: [revokedWorkerFinished, stableLayoutCommitted],
            timeout: 2,
            enforceOrder: false
        )

        let finalRealm = try WRealm.safe()
        finalRealm.refresh()
        XCTAssertTrue(try XCTUnwrap(finalRealm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: "mention-notification"
        )).isRead)
        XCTAssertTrue(try XCTUnwrap(finalRealm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: "mention-message"
        )).isRead)
        observationLock.lock()
        let finalPostClaimCount = postClaimCount
        let finalFirstMutationCount = firstPersistentMutationCount
        let finalLinkedReadCount = linkedReadMessageCount
        let finalUIRefreshCount = uiRefreshCount
        let finalRetryCount = retryCount
        let finalTerminalOutcomes = terminalOutcomes
        observationLock.unlock()
        XCTAssertEqual(finalPostClaimCount, 2)
        XCTAssertEqual(finalFirstMutationCount, 1)
        XCTAssertEqual(finalLinkedReadCount, 1)
        XCTAssertEqual(finalUIRefreshCount, 1)
        XCTAssertEqual(finalRetryCount, 0, "stable-layout receipt is not a timer retry")
        XCTAssertEqual(finalTerminalOutcomes.filter { !$0 }.count, 1)
        XCTAssertEqual(finalTerminalOutcomes.filter { $0 }.count, 1)
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            1
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            0
        )
        XCTAssertNil(controller.visibleUnreadMentionReconciliationWorkItem)
        XCTAssertNil(controller.readVisibleStableLayoutRetryWorkItem)
    }

    func testPostClaimGeometryRevocationDuringStructuralTransactionRetriesAtStableTerminalWithSameGeometry() throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.mention.structural-terminal")
        )
        AccountManager.shared.users.append(account)
        let controller = makeController(conversationType: .group)
        let layout = configureReadGeometry(
            for: controller,
            primary: "mention-message",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80)
        )
        try seedUnreadMention(
            notificationPrimary: "mention-notification",
            messagePrimary: "mention-message"
        )
        authorizeReadVisiblePresentation(controller)
        controller.readVisiblePresentationCoordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "mention-notification",
                messagePrimary: "mention-message"
            )
        ])

        let firstPermitClaimed = expectation(
            description: "first permit claimed before structural geometry change"
        )
        let revokedWorkerFinished = expectation(
            description: "structurally revoked worker terminates"
        )
        let structuralTerminalCommitted = expectation(
            description: "real structural terminal resamples unchanged geometry once"
        )
        let releaseFirstPermit = DispatchSemaphore(value: 0)
        let observationLock = NSLock()
        var postClaimCount = 0
        var firstPersistentMutationCount = 0
        var linkedReadMessageCount = 0
        var uiRefreshCount = 0
        var terminalOutcomes: [Bool] = []

        controller.visibleMentionReadPostClaimBarrierForTests = {
            observationLock.lock()
            postClaimCount += 1
            let shouldPause = postClaimCount == 1
            observationLock.unlock()
            guard shouldPause else {
                return
            }
            firstPermitClaimed.fulfill()
            XCTAssertEqual(releaseFirstPermit.wait(timeout: .now() + 2), .success)
        }
        controller.visibleMentionReadAfterFirstPersistentMutationBarrierForTests = {
            observationLock.lock()
            firstPersistentMutationCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadMessageWillExecuteForTests = { _ in
            observationLock.lock()
            linkedReadMessageCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadUIRefreshForTests = {
            observationLock.lock()
            uiRefreshCount += 1
            observationLock.unlock()
        }
        controller.visibleMentionReadTerminalForTests = { didCommit in
            observationLock.lock()
            terminalOutcomes.append(didCommit)
            observationLock.unlock()
            if didCommit {
                structuralTerminalCommitted.fulfill()
            } else {
                revokedWorkerFinished.fulfill()
            }
        }

        controller.flushPendingVisibleUnreadMentionReconciliationIfPossible()
        wait(for: [firstPermitClaimed], timeout: 1)

        controller.isChatDatasourceStructuralTransactionActive = true
        let targetIndexPath = IndexPath(item: 0, section: 0)
        layout.frames[targetIndexPath] = CGRect(x: 0, y: 10, width: 320, height: 90)
        layout.invalidateLayout()
        controller.viewDidLayoutSubviews()
        XCTAssertNil(
            controller.readVisibleStableLayoutRetryWorkItem,
            "a structurally blocked layout must not schedule a retry"
        )
        releaseFirstPermit.signal()
        wait(for: [revokedWorkerFinished], timeout: 2)

        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            1
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            0
        )
        controller.finishChatDatasourceStructuralTransaction()
        wait(for: [structuralTerminalCommitted], timeout: 2)

        let finalRealm = try WRealm.safe()
        finalRealm.refresh()
        XCTAssertTrue(try XCTUnwrap(finalRealm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: "mention-notification"
        )).isRead)
        XCTAssertTrue(try XCTUnwrap(finalRealm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: "mention-message"
        )).isRead)
        observationLock.lock()
        let finalPostClaimCount = postClaimCount
        let finalFirstMutationCount = firstPersistentMutationCount
        let finalLinkedReadCount = linkedReadMessageCount
        let finalUIRefreshCount = uiRefreshCount
        let finalTerminalOutcomes = terminalOutcomes
        observationLock.unlock()
        XCTAssertEqual(finalPostClaimCount, 2)
        XCTAssertEqual(finalFirstMutationCount, 1)
        XCTAssertEqual(finalLinkedReadCount, 1)
        XCTAssertEqual(finalUIRefreshCount, 1)
        XCTAssertEqual(finalTerminalOutcomes.filter { !$0 }.count, 1)
        XCTAssertEqual(finalTerminalOutcomes.filter { $0 }.count, 1)
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.successfulFlushCount,
            1
        )
        XCTAssertEqual(
            controller.readVisiblePresentationCoordinator.pendingCandidateCount,
            0
        )
        XCTAssertNil(controller.readVisibleStableLayoutRetryWorkItem)
    }

    func testCurrentVisibleMentionFlushCommitsExactlyOnceAcrossCompletionCallbacks() throws {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "ChatViewportReadBoundaryTests.mention.current")
        )
        AccountManager.shared.users.append(account)
        let controller = makeController(conversationType: .group)
        let layout = configureReadGeometry(
            for: controller,
            primary: "mention-message",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80)
        )
        _ = layout
        try seedUnreadMention(
            notificationPrimary: "mention-notification",
            messagePrimary: "mention-message"
        )
        authorizeReadVisiblePresentation(controller)
        controller.readVisiblePresentationCoordinator.enqueue([
            ChatPendingMentionReadCandidate(
                notificationPrimary: "mention-notification",
                messagePrimary: "mention-message"
            )
        ])

        let committed = expectation(description: "current mention committed")
        var linkedReadMessageCount = 0
        var uiRefreshCount = 0
        var retryCount = 0
        var terminalCount = 0
        controller.visibleMentionReadMessageWillExecuteForTests = { _ in
            linkedReadMessageCount += 1
        }
        controller.visibleMentionReadUIRefreshForTests = {
            uiRefreshCount += 1
        }
        controller.visibleMentionReadRetryForTests = {
            retryCount += 1
        }
        controller.visibleMentionReadTerminalForTests = { didCommit in
            XCTAssertTrue(didCommit)
            terminalCount += 1
            committed.fulfill()
        }

        controller.flushPendingVisibleUnreadMentionReconciliationIfPossible()
        wait(for: [committed], timeout: 2)
        controller.flushPendingVisibleUnreadMentionReconciliationIfPossible()
        controller.retryPendingVisibleUnreadMentionReconciliation()

        let realm = try WRealm.safe()
        let notification = try XCTUnwrap(
            realm.object(
                ofType: NotificationStorageItem.self,
                forPrimaryKey: "mention-notification"
            )
        )
        let message = try XCTUnwrap(
            realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: "mention-message"
            )
        )
        let chat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: owner,
                    conversationType: .group
                )
            )
        )

        XCTAssertTrue(notification.isRead)
        XCTAssertTrue(message.isRead)
        XCTAssertEqual(message.state, .read)
        XCTAssertGreaterThan(message.readDate, 1)
        XCTAssertEqual(chat.syncUnreadCount, 0)
        XCTAssertEqual(chat.unread, 0)
        XCTAssertEqual(chat.lastReadId, "200")
        XCTAssertNil(chat.mentionId)
        XCTAssertEqual(linkedReadMessageCount, 1)
        XCTAssertEqual(uiRefreshCount, 1)
        XCTAssertEqual(retryCount, 0)
        XCTAssertEqual(terminalCount, 1)
        XCTAssertEqual(controller.readVisiblePresentationCoordinator.successfulFlushCount, 1)
        XCTAssertEqual(controller.readVisiblePresentationCoordinator.pendingCandidateCount, 0)
    }

    func testViewportReadBoundaryRejectsSliverUntilTargetIsMeaningfullyVisible() throws {
        let controller = makeController()
        let layout = configureReadGeometry(
            for: controller,
            primary: "incoming-visible",
            frame: CGRect(x: 0, y: 90, width: 320, height: 80)
        )
        authorizeReadVisiblePresentation(controller)
        let targetIndexPath = IndexPath(item: 0, section: 0)
        let sliverGeometry = try XCTUnwrap(
            controller.readVisibleRowGeometryDiagnosticsForTesting(
                at: targetIndexPath
            )
        )

        XCTAssertEqual(sliverGeometry.itemFrame, CGRect(x: 0, y: 90, width: 320, height: 80))
        XCTAssertEqual(sliverGeometry.viewport, CGRect(x: 0, y: 0, width: 320, height: 100))
        XCTAssertEqual(sliverGeometry.intersection, CGRect(x: 0, y: 90, width: 320, height: 10))
        XCTAssertEqual(sliverGeometry.requiredWidth, 44)
        XCTAssertEqual(sliverGeometry.requiredHeight, 44)
        XCTAssertFalse(sliverGeometry.isMeaningfullyVisible)
        XCTAssertEqual(sliverGeometry.messageIdentity?.primary, "incoming-visible")

        XCTAssertFalse(
            controller.advanceReadBoundaryFromVisibleMessages(
                indexPaths: [targetIndexPath]
            )
        )
        XCTAssertTrue(controller.messagesToReadObserver.value.isEmpty)

        layout.frames[targetIndexPath] = CGRect(x: 0, y: 40, width: 320, height: 80)
        layout.invalidateLayout()
        controller.messagesCollectionView.layoutIfNeeded()
        let meaningfulGeometry = try XCTUnwrap(
            controller.readVisibleRowGeometryDiagnosticsForTesting(
                at: targetIndexPath
            )
        )

        XCTAssertEqual(meaningfulGeometry.itemFrame, CGRect(x: 0, y: 40, width: 320, height: 80))
        XCTAssertEqual(meaningfulGeometry.viewport, sliverGeometry.viewport)
        XCTAssertEqual(meaningfulGeometry.intersection, CGRect(x: 0, y: 40, width: 320, height: 60))
        XCTAssertEqual(meaningfulGeometry.requiredHeight, 44)
        XCTAssertTrue(meaningfulGeometry.isMeaningfullyVisible)
        XCTAssertEqual(
            meaningfulGeometry.messageIdentity,
            sliverGeometry.messageIdentity,
            "the same realized presentation identity must cross the threshold"
        )

        XCTAssertTrue(
            controller.advanceReadBoundaryFromVisibleMessages(
                indexPaths: [targetIndexPath]
            )
        )
        XCTAssertEqual(controller.messagesToReadObserver.value, ["incoming-visible"])
        XCTAssertFalse(
            controller.advanceReadBoundaryFromVisibleMessages(
                indexPaths: [targetIndexPath]
            ),
            "the already-advanced target must remain idempotent"
        )
    }

    func testViewportReadBoundaryRevalidatesTargetThatLeavesMeaningfulViewportBeforeMutation() {
        let controller = makeController()
        let targetIndexPath = IndexPath(item: 0, section: 0)
        let layout = configureReadGeometry(
            for: controller,
            primary: "incoming-delayed",
            frame: CGRect(x: 0, y: 20, width: 320, height: 80)
        )
        authorizeReadVisiblePresentation(controller)
        var precommitCount = 0
        controller.readBoundaryPrecommitBarrierForTests = { target in
            XCTAssertEqual(target.primary, "incoming-delayed")
            precommitCount += 1
            layout.frames[targetIndexPath] = CGRect(x: 0, y: 95, width: 320, height: 80)
            layout.invalidateLayout()
        }

        XCTAssertFalse(
            controller.advanceReadBoundaryFromVisibleMessages(
                indexPaths: [targetIndexPath]
            )
        )

        XCTAssertEqual(precommitCount, 1)
        XCTAssertTrue(controller.messagesToReadObserver.value.isEmpty)
    }

    private func orderedMessage(
        primary: String,
        orderIndex: Int,
        outgoing: Bool = false,
        isRead: Bool = false,
        isFakeMessage: Bool = false,
        rowKind: ChatVisiblePositionPolicy.RowKind = .message
    ) -> ChatViewportReadBoundaryPolicy.OrderedMessage {
        ChatViewportReadBoundaryPolicy.OrderedMessage(
            primary: primary,
            orderIndex: orderIndex,
            isOutgoing: outgoing,
            isRead: isRead,
            rowKind: rowKind,
            isFakeMessage: isFakeMessage
        )
    }

    private func currentViewportReadBoundaryIndex(
        for controller: ChatViewController
    ) -> Int? {
        let orderedMessages = controller.orderedViewportReadMessages()
        return controller.currentViewportReadBoundaryIndex(in: orderedMessages)
    }

    private func enqueueOrdinaryViewportRead(on controller: ChatViewController) {
        let indexPath = IndexPath(item: 0, section: 0)
        controller.collectionView(
            controller.messagesCollectionView,
            willDisplay: UICollectionViewCell(),
            forItemAt: indexPath
        )
        controller.flushPendingScrollWork()
    }

    private func makeController(
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = conversationType
        controller.ownerSender = Sender(id: owner, displayName: owner)
        controller.opponentSender = Sender(id: jid, displayName: jid)
        return controller
    }

    @discardableResult
    private func configureReadGeometry(
        for controller: ChatViewController,
        primary: String,
        frame: CGRect,
        archivedId: String? = nil,
        sentDate: Date = Date(timeIntervalSince1970: 100),
        usesDetachedTimeline: Bool = true
    ) -> ChatReadGeometryLayout {
        controller.loadViewIfNeeded()
        // This helper exercises detached viewport geometry. Loading the view
        // installs a real (empty) timeline session whose identity must not be
        // mixed with the synthetic row below; otherwise read-boundary
        // admission correctly rejects a row the session does not own.
        controller.cancelStackedNavigationPresentationPreparation()
        if usesDetachedTimeline {
            controller.timelineSession = nil
        }
        controller.isStackedNavigationPresentationPreparationCancelled = false
        controller.messagesCollectionView.contentInsetAdjustmentBehavior = .never
        controller.messagesCollectionView.frame = CGRect(x: 0, y: 0, width: 320, height: 100)
        controller.messagesCollectionView.contentInset = .zero
        controller.messagesCollectionView.contentOffset = .zero
        controller.datasource = [
            makeDatasource(
                primary: primary,
                archivedId: archivedId ??
                    (primary == "mention-message" ? "200" : "100"),
                sentDate: sentDate
            )
        ]
        controller.initialLocalFirstFramePhase = .committed(
            ChatLocalFirstFrameDescriptor(target: .latest, request: nil)
        )
        controller.initialFirstContentApplyCount = 1
        controller.appliedBootstrapLoadingState = .content
        controller.showSkeletonObserver.accept(false)
        controller.loadDatasourceObserver.accept(true)
        let indexPath = IndexPath(item: 0, section: 0)
        let layout = ChatReadGeometryLayout(frames: [indexPath: frame])
        controller.messagesCollectionView.setCollectionViewLayout(layout, animated: false)
        layout.invalidateLayout()
        controller.messagesCollectionView.layoutIfNeeded()
        // Installing a layout is allowed to restore production-owned bounds
        // or clamp the previous offset. This detached geometry fixture owns
        // an explicit 320x100 top-origin viewport, so establish the complete
        // bounds only after UIKit has accepted the layout/content-size change.
        controller.messagesCollectionView.frame = CGRect(
            x: 0,
            y: 0,
            width: 320,
            height: 100
        )
        controller.messagesCollectionView.bounds = CGRect(
            x: 0,
            y: 0,
            width: 320,
            height: 100
        )
        controller.messagesCollectionView.setContentOffset(.zero, animated: false)
        controller.messagesCollectionView.layoutIfNeeded()
        controller.readVisibleItemFrameProviderForTests = { [weak layout] indexPath in
            layout?.layoutAttributesForItem(at: indexPath)?.frame
        }
        return layout
    }

    private func authorizeReadVisiblePresentation(_ controller: ChatViewController) {
        controller.readVisiblePresentationSnapshotProvider = {
            self.readVisiblePresentationSnapshot(isTopNavigationDestination: true)
        }
        controller.readVisiblePresentationCoordinator.recordPresentationReceipt()
    }

    /// `loadViewIfNeeded()` configures the same real timeline session used by
    /// production. A fixture that publishes only `datasource` rows leaves that
    /// session empty, so the production read-boundary branch correctly rejects
    /// a target it does not own. Open the seeded Realm window through the
    /// session itself and keep the visual/session identities in lockstep.
    @discardableResult
    private func openReadTargetInProductionTimelineSession(
        for controller: ChatViewController,
        primary: String
    ) throws -> ChatTimelineSession {
        let session = try XCTUnwrap(controller.timelineSession)
        let snapshot = session.openLatest(limit: controller.datasourcePageSize)
        let target = try XCTUnwrap(snapshot.item(primary: primary))
        let targetIndex = try XCTUnwrap(snapshot.residentIndex.index(primary: primary))
        let visible = try XCTUnwrap(
            controller.datasource.first(where: { $0.primary == primary })
        )
        let visibleWindow = ChatDatasetWindow(
            minIndex: targetIndex,
            maxIndex: targetIndex + 1
        )

        controller.syncCurrentPage(with: visibleWindow)
        // Production publishes the datasource after committing the session.
        // Rebuild metadata in that order so its position is derived from the
        // committed target rather than from a detached visual surrogate.
        controller.rebuildScrollResidentMetadata()

        XCTAssertTrue(controller.timelineSession === session)
        XCTAssertTrue(target.isFrozen)
        XCTAssertEqual(controller.visibleWindow(), visibleWindow)
        XCTAssertEqual(visible.owner, target.owner)
        XCTAssertEqual(visible.jid, target.opponent)
        XCTAssertEqual(visible.messageId, target.messageId)
        XCTAssertEqual(visible.archivedId, target.archivedId)
        XCTAssertEqual(visible.sentDate, target.sentDate)
        XCTAssertEqual(
            controller.scrollResidentMetadata.position(primary: primary),
            ChatTimelinePositionKey(message: target),
            "the visible row and timeline target must share one position identity"
        )
        return session
    }

    private func readVisiblePresentationSnapshot(
        isTopNavigationDestination: Bool,
        isTransitionActive: Bool = false
    ) -> ChatReadVisiblePresentationSnapshot {
        ChatReadVisiblePresentationSnapshot(
            isApplicationActive: true,
            isWindowAttached: true,
            isWindowSceneForegroundActive: true,
            isKeyWindow: true,
            isTopNavigationDestination: isTopNavigationDestination,
            isVisibleSplitSecondary: false,
            hasCoveringPresentation: false,
            isTransitionActive: isTransitionActive
        )
    }

    private func drainMainQueue(description: String) {
        let drained = expectation(description: description)
        DispatchQueue.main.async {
            drained.fulfill()
        }
        wait(for: [drained], timeout: 1)
    }

    private func makeDatasource(
        primary: String,
        archivedId: String,
        sentDate: Date
    ) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: primary,
            jid: jid,
            owner: owner,
            outgoing: false,
            sender: Sender(id: jid, displayName: jid),
            messageId: primary,
            sentDate: sentDate,
            editDate: nil,
            kind: .attributedText(NSAttributedString(string: "Hello")),
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: true,
            canEditMessage: false,
            canDeleteMessage: true,
            forwards: [],
            isOutgoing: false,
            isEdited: false,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: true,
            state: .deliver,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: archivedId,
            queryIds: nil,
            isRead: false,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: false,
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: .none,
            avatarUrl: nil,
            attributedAuthor: nil
        )
    }

    private func seedUnreadChat() throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .regular
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .regular)
        chat.syncUnreadCount = 1
        chat.syncUnreadAfterId = "100"
        chat.syncSnapshotLastArchiveId = "100"
        chat.lastReadId = "100"
        chat.runtimeUnreadCount = 1
        chat.unread = 2

        let old = makeMessage(primary: "incoming-old", archivedId: "100", date: Date(timeIntervalSince1970: 100))
        let last = makeMessage(
            primary: "incoming-last",
            archivedId: "200",
            date: Date(timeIntervalSince1970: 200),
            unreadCounterBucket: .runtime
        )
        chat.lastMessage = last
        chat.lastMessageId = last.messageId
        chat.messageDate = last.sentDate

        try realm.write {
            realm.add([old, last], update: .modified)
            realm.add(chat, update: .modified)
        }
    }

    private func seedOutOfOrderDateUnreadChat() throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .regular
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .regular)
        chat.syncUnreadCount = 1
        chat.syncUnreadAfterId = "50"
        chat.syncSnapshotLastArchiveId = "200"
        chat.lastReadId = "50"
        chat.runtimeUnreadCount = 0
        chat.unread = 1

        let old = makeMessage(primary: "incoming-old", archivedId: "100", date: Date(timeIntervalSince1970: 300))
        let newestByOrder = makeMessage(primary: "incoming-new", archivedId: "200", date: Date(timeIntervalSince1970: 100))
        chat.lastMessage = newestByOrder
        chat.lastMessageId = newestByOrder.messageId
        chat.messageDate = newestByOrder.sentDate

        try realm.write {
            realm.add([old, newestByOrder], update: .modified)
            realm.add(chat, update: .modified)
        }
    }

    private func seedUnreadMention(
        notificationPrimary: String,
        messagePrimary: String
    ) throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = .group
        chat.primary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: .group
        )
        chat.groupchatMyId = "current-member"
        chat.syncUnreadCount = 1
        chat.syncUnreadAfterId = "100"
        chat.syncSnapshotLastArchiveId = "200"
        chat.lastReadId = "100"
        chat.unread = 1
        chat.mentionId = "200"

        let message = MessageStorageItem()
        message.primary = messagePrimary
        message.owner = owner
        message.opponent = jid
        message.conversationType = .group
        message.body = "Hello @current-member"
        message.legacyBody = message.body
        message.displayAs = .text
        message.messageId = "mention-message-id"
        message.archivedId = "200"
        message.date = Date(timeIntervalSince1970: 100)
        message.sentDate = message.date
        message.outgoing = false
        message.isRead = false
        message.state = .deliver
        message.unreadCounterBucket = .none
        let mentionReference = MessageReferenceStorageItem()
        mentionReference.kind = .mention
        mentionReference.metadata = [
            "memberId": "current-member",
            "groupchatJid": jid,
            "uri": "xmpp:\(jid)?members;id=current-member"
        ]
        message.references.append(mentionReference)

        let notification = NotificationStorageItem()
        notification.primary = notificationPrimary
        notification.owner = owner
        notification.category = .mention
        notification.isRead = false
        notification.shouldShow = true
        notification.sourceConversationType = .group
        notification.sourceChatJid = jid
        notification.sourceArchivedId = message.archivedId
        notification.sourceMessageId = message.messageId
        notification.sourceMessageDate = message.date
        notification.mentionTargetUserId = "current-member"
        notification.mentionLinkStatus = .resolved

        chat.lastMessage = message
        chat.lastMessageId = message.messageId
        chat.messageDate = message.sentDate

        try realm.write {
            realm.add(message, update: .modified)
            realm.add(notification, update: .modified)
            realm.add(chat, update: .modified)
        }
    }

    private func makeMessage(
        primary: String,
        archivedId: String,
        date: Date,
        unreadCounterBucket: MessageStorageItem.UnreadCounterBucket = .none
    ) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.primary = primary
        message.owner = owner
        message.opponent = jid
        message.conversationType = .regular
        message.body = "hello"
        message.legacyBody = "hello"
        message.displayAs = .text
        message.messageId = primary
        message.archivedId = archivedId
        message.date = date
        message.sentDate = date
        message.outgoing = false
        message.isRead = false
        message.state = .deliver
        message.unreadCounterBucket = unreadCounterBucket
        return message
    }

    private func storedChat() throws -> LastChatsStorageItem {
        try XCTUnwrap(try WRealm.safe().object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .regular)
        ))
    }

    private func storedMessage(primary: String) throws -> MessageStorageItem {
        try XCTUnwrap(try WRealm.safe().object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: primary
        ))
    }

    private func assertUnreadLastMessageRemainsUnchanged() throws {
        let realm = try WRealm.safe()
        let chat = try XCTUnwrap(realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: .regular
            )
        ))
        let message = try XCTUnwrap(realm.object(
            ofType: MessageStorageItem.self,
            forPrimaryKey: "incoming-last"
        ))
        XCTAssertEqual(chat.lastReadId, "100")
        XCTAssertEqual(chat.syncUnreadCount, 1)
        XCTAssertEqual(chat.unread, 2)
        XCTAssertNil(chat.displayedId)
        XCTAssertFalse(message.isRead)
        XCTAssertEqual(message.state, .deliver)
        XCTAssertLessThanOrEqual(message.readDate, 1)
    }
}

private final class ChatReadGeometryLayout: UICollectionViewLayout {
    var frames: [IndexPath: CGRect]

    init(frames: [IndexPath: CGRect]) {
        self.frames = frames
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var collectionViewContentSize: CGSize {
        CGSize(
            width: frames.values.map(\.maxX).max() ?? 0,
            height: frames.values.map(\.maxY).max() ?? 0
        )
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        frames.compactMap { indexPath, frame in
            guard frame.intersects(rect) else {
                return nil
            }
            return attributes(indexPath: indexPath, frame: frame)
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let frame = frames[indexPath] else {
            return nil
        }
        return attributes(indexPath: indexPath, frame: frame)
    }

    private func attributes(
        indexPath: IndexPath,
        frame: CGRect
    ) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frame
        return attributes
    }
}
