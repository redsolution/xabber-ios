import UIKit
import XCTest
import RealmSwift
import notify
@testable import xabber

private let darwinNotifySuccessStatus = UInt32(bitPattern: NOTIFY_STATUS_OK)

final class AppRootColdPushRoutingTests: XCTestCase {
    private var activeCoordinatorAtTestStart: AppRootCoordinator?

    override func setUp() {
        super.setUp()
        activeCoordinatorAtTestStart = AppRootCoordinator.active
    }

    override func tearDown() {
        let activeCoordinatorAtTestEnd = AppRootCoordinator.active
        AppRootCoordinator.active = activeCoordinatorAtTestStart
        XCTAssertTrue(
            activeCoordinatorAtTestEnd === activeCoordinatorAtTestStart,
            "A hosted AppRoot test must restore the process-wide active coordinator"
        )
        activeCoordinatorAtTestStart = nil
        super.tearDown()
    }

    func testColdPushNativeDidShowPreservesCommittedSkeletonUntilContentCommit() {
        XCTAssertEqual(
            ChatOpenRealPipelineNativeDidShowPhasePolicy.phase(
                hasCommittedContent: false,
                hasCommittedBlockingSkeleton: true
            ),
            .skeleton,
            "Native didShow is a navigation acknowledgement, not permission to replace the already-visible skeleton"
        )
        XCTAssertEqual(
            ChatOpenRealPipelineNativeDidShowPhasePolicy.phase(
                hasCommittedContent: false,
                hasCommittedBlockingSkeleton: false
            ),
            .preparing
        )
        XCTAssertEqual(
            ChatOpenRealPipelineNativeDidShowPhasePolicy.phase(
                hasCommittedContent: true,
                hasCommittedBlockingSkeleton: true
            ),
            .content,
            "Only a committed content frame may supersede the bootstrap skeleton"
        )
    }

    @MainActor
    func testColdPushNativeDidShowReleasesDeferredExactAnchorAdmissionOnce() throws {
        let previousActiveCoordinator = AppRootCoordinator.active
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "AppRootColdPushNativeDidShowTests-\(UUID().uuidString)"
        )
        defer {
            AppRootCoordinator.active = previousActiveCoordinator
            Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        }

        let acknowledgementName = try XCTUnwrap(
            ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
                .notificationName(token: UUID().uuidString)
        )
        let descriptor = ChatPerformanceUITestLaunchDescriptor(
            scale: .small,
            openScenario: .coldPushExact,
            externalSkeletonAcknowledgementNotificationName:
                acknowledgementName
        )
        let destination = ChatPerformanceFixtureViewController(
            descriptor: descriptor
        )
        defer { destination.performOpenScenarioTerminalResourceTeardown() }
        let rootCoordinator = AppRootCoordinator(
            window: UIWindow(),
            appDelegate: nil
        )
        let host = ChatPerformanceLastChatsRouteHostViewController(
            descriptor: descriptor,
            destination: destination,
            rootCoordinator: rootCoordinator
        )
        let navigationController = UINavigationController(
            rootViewController: host
        )
        let exactRequest = try XCTUnwrap(destination.pendingOpenMessageRequest)

        destination.shouldDeferPendingOpenMessageRequestUntilNavigationTransitionCompletion =
            true
        destination.performPendingOpenMessageRequestIfNeeded()

        XCTAssertTrue(destination.didDeferOpenMessageRequestForNavigationTransition)
        XCTAssertEqual(destination.chatLifecycleResourceSnapshot.navigationWorkItems, 1)
        XCTAssertEqual(destination.pendingOpenMessageRequest, exactRequest)

        host.navigationController(
            navigationController,
            willShow: destination,
            animated: true
        )
        XCTAssertEqual(destination.chatLifecycleResourceSnapshot.navigationWorkItems, 1)

        host.navigationController(
            navigationController,
            didShow: destination,
            animated: true
        )

        XCTAssertFalse(
            destination
                .shouldDeferPendingOpenMessageRequestUntilNavigationTransitionCompletion
        )
        XCTAssertFalse(destination.didDeferOpenMessageRequestForNavigationTransition)
        XCTAssertEqual(destination.chatLifecycleResourceSnapshot.navigationWorkItems, 0)
        XCTAssertEqual(destination.pendingOpenMessageRequest, exactRequest)

        host.navigationController(
            navigationController,
            didShow: destination,
            animated: true
        )
        XCTAssertEqual(
            destination.chatLifecycleResourceSnapshot.navigationWorkItems,
            0,
            "Repeated didShow must not replay the exact-anchor admission"
        )
    }

    @MainActor
    func testColdPushCancelledNativeTransitionDropsDeferredExactAnchorAdmissionWithoutStartingArchive()
        throws {
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "AppRootColdPushCancelledTransitionTests-\(UUID().uuidString)"
        )
        defer {
            Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        }

        let acknowledgementName = try XCTUnwrap(
            ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
                .notificationName(token: UUID().uuidString)
        )
        let destination = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: .coldPushExact,
            externalSkeletonAcknowledgementNotificationName:
                acknowledgementName
        ))
        defer { destination.performOpenScenarioTerminalResourceTeardown() }
        let exactRequest = try XCTUnwrap(destination.pendingOpenMessageRequest)

        destination.shouldDeferPendingOpenMessageRequestUntilNavigationTransitionCompletion =
            true
        destination.performPendingOpenMessageRequestIfNeeded()

        XCTAssertTrue(destination.didDeferOpenMessageRequestForNavigationTransition)
        XCTAssertEqual(destination.chatLifecycleResourceSnapshot.navigationWorkItems, 1)

        destination.completeNavigationTransitionDeferral(cancelled: true)

        let resources = destination.chatLifecycleResourceSnapshot
        XCTAssertFalse(
            destination
                .shouldDeferPendingOpenMessageRequestUntilNavigationTransitionCompletion
        )
        XCTAssertFalse(destination.didDeferOpenMessageRequestForNavigationTransition)
        XCTAssertEqual(resources.navigationWorkItems, 0)
        XCTAssertEqual(resources.anchorTransactions, 0)
        XCTAssertEqual(resources.anchorQueries, 0)
        XCTAssertEqual(resources.activeRemoteQueries, 0)
        XCTAssertEqual(destination.pendingOpenMessageRequest, exactRequest)
    }

    func testColdPushStartupGateRejectsPrematureOrDuplicateConsumption() {
        var startup = ChatPerformanceColdPushStartupGate()
        XCTAssertTrue(startup.retainPendingExactRoute())
        XCTAssertFalse(startup.shouldAttemptProductionRoute)
        XCTAssertFalse(startup.recordProductionRouteAttempt())

        startup.recordRootInstalled()
        startup.recordLastChatsVisible()
        startup.recordAccountMaterialized()
        XCTAssertTrue(startup.shouldAttemptProductionRoute)
        XCTAssertTrue(startup.recordProductionRouteAttempt())
        XCTAssertFalse(startup.recordProductionRouteAttempt())
        startup.recordNativePresentationCompleted()
        XCTAssertFalse(startup.consumePendingRouteIfEligible(
            hasStableTargetAcknowledgement: false
        ))
        startup.recordStableTargetAcknowledgement()
        XCTAssertTrue(startup.consumePendingRouteIfEligible(
            hasStableTargetAcknowledgement: true
        ))
        XCTAssertFalse(startup.consumePendingRouteIfEligible(
            hasStableTargetAcknowledgement: true
        ))
        XCTAssertEqual(startup.productionRouteAttemptCount, 1)
        XCTAssertEqual(startup.pendingRouteConsumeCount, 1)
        XCTAssertEqual(startup.consumeBeforeStableCount, 0)
    }

    @MainActor
    func testStableTargetAcknowledgementRejectsAFrameFromSupersededExactRoute() {
        let chat = ChatViewController()
        chat.owner = "owner@example.com"
        chat.jid = "peer@example.com"
        chat.conversationType = .regular
        let firstRequest = makeRequest(archivedId: "100", messageId: "m-100")
        let replacementRequest = makeRequest(
            archivedId: "200",
            messageId: "m-200"
        )
        let firstTarget = ChatOpenPerformanceSemanticTargetFingerprint
            .message(firstRequest)
        let replacementTarget = ChatOpenPerformanceSemanticTargetFingerprint
            .message(replacementRequest)
        let firstContext = chat.acceptChatOpenPerformanceTrace(
            purpose: .notificationRoute,
            semanticTargetFingerprint: firstTarget
        )
        XCTAssertTrue(chat.chatOpenPerformanceTraceLifecycle
            .recordPresentationReceipt(
                .content,
                context: firstContext,
                schedulesStableFrame: true
            ))

        let replacementContext = chat.acceptChatOpenPerformanceTrace(
            purpose: .notificationRoute,
            semanticTargetFingerprint: replacementTarget
        )
        XCTAssertNotEqual(firstContext, replacementContext)
        XCTAssertTrue(chat.chatOpenPerformanceTraceLifecycle
            .recordPresentationReceipt(
                .content,
                context: replacementContext,
                schedulesStableFrame: true
            ))
        var acknowledgedTargets:
            [ChatOpenPerformanceSemanticTargetFingerprint] = []
        chat.chatOpenStableVisibilityAcknowledgementHandler = {
            _, semanticTarget in
            acknowledgedTargets.append(semanticTarget)
        }

        XCTAssertFalse(chat.consumeChatOpenStableFrame(
            context: firstContext,
            semanticTarget: firstTarget,
            eligibility: .eligible
        ))
        XCTAssertFalse(chat.hasStableChatOpenAcknowledgement(
            for: replacementRequest
        ))
        XCTAssertTrue(chat.consumeChatOpenStableFrame(
            context: replacementContext,
            semanticTarget: replacementTarget,
            eligibility: .eligible
        ))
        XCTAssertFalse(chat.consumeChatOpenStableFrame(
            context: replacementContext,
            semanticTarget: replacementTarget,
            eligibility: .eligible
        ))
        XCTAssertEqual(acknowledgedTargets, [replacementTarget])
        XCTAssertTrue(chat.hasStableChatOpenAcknowledgement(
            for: replacementRequest
        ))
        XCTAssertFalse(chat.hasStableChatOpenAcknowledgement(for: firstRequest))
        chat.cancelChatOpenPerformanceTrace()
    }

    private func assertCompleteExactPushRequest(
        _ request: ChatOpenMessageRequest,
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(request.owner, owner, file: file, line: line)
        XCTAssertEqual(request.chatJid, jid, file: file, line: line)
        XCTAssertEqual(
            request.conversationType,
            conversationType,
            file: file,
            line: line
        )
        XCTAssertNotNil(request.anchor.archivedId, file: file, line: line)
        XCTAssertNotNil(request.anchor.messageId, file: file, line: line)
        XCTAssertNotNil(request.anchor.sourceDate, file: file, line: line)
        XCTAssertEqual(
            request.source,
            .pushNotification,
            file: file,
            line: line
        )
        XCTAssertTrue(request.highlight, file: file, line: line)
        XCTAssertTrue(request.markReadOnVisible, file: file, line: line)
    }

    private func makeRequest(
        archivedId: String,
        messageId: String
    ) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: "peer@example.com",
            owner: "owner@example.com",
            conversationType: .regular,
            anchor: ChatMessageAnchorRef(
                messagePrimary: "primary-\(archivedId)",
                archivedId: archivedId,
                messageId: messageId,
                authorId: "author@example.com",
                bodyFingerprint: "body-\(archivedId)",
                sourceDate: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            highlight: true,
            markReadOnVisible: true,
            source: .pushNotification
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }
        return condition()
    }
}
