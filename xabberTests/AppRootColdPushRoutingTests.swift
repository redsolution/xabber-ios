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
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
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
        destination.performPendingOpenMessageRequestIfNeeded(trigger: .manual)

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
    func testColdPushNativeDidShowResumesPreViewExactAnchorAdmissionOnce()
        throws {
        let previousActiveCoordinator = AppRootCoordinator.active
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "AppRootColdPushPreViewDidShowTests-\(UUID().uuidString)"
        )
        defer {
            AppRootCoordinator.active = previousActiveCoordinator
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
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
        let fixtureTransportProvider = try XCTUnwrap(
            destination.performanceFixtureArchiveTransportProvider
        )
        var admittedTransportRequests:
            [ChatPerformanceFixtureArchiveTransportRequest] = []
        destination.performanceFixtureArchiveTransportProvider = { request in
            admittedTransportRequests.append(request)
            return fixtureTransportProvider(request)
        }

        // Production notification routing owns the request before UIKit asks
        // the destination to load. With no timeline yet, this first attempt is
        // intentionally retained but cannot enqueue transition work.
        XCTAssertFalse(destination.isViewLoaded)
        destination.performPendingOpenMessageRequestIfNeeded(trigger: .manual)
        XCTAssertNil(destination.timelineSession)
        XCTAssertNil(destination.activeAnchorExecutionState)
        XCTAssertEqual(
            destination.chatLifecycleResourceSnapshot.navigationWorkItems,
            0
        )
        XCTAssertEqual(destination.pendingOpenMessageRequest, exactRequest)
        XCTAssertTrue(admittedTransportRequests.isEmpty)

        destination.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
            completion: {}
        )

        XCTAssertTrue(destination.isViewLoaded)
        XCTAssertNotNil(destination.timelineSession)
        XCTAssertTrue(
            destination
                .shouldDeferPendingOpenMessageRequestUntilNavigationTransitionCompletion
        )
        XCTAssertFalse(destination.didDeferOpenMessageRequestForNavigationTransition)
        XCTAssertEqual(
            destination.chatLifecycleResourceSnapshot.navigationWorkItems,
            0,
            "The pre-view attempt must not manufacture a queued transition closure"
        )
        XCTAssertNil(destination.activeAnchorExecutionState)
        XCTAssertEqual(destination.pendingOpenMessageRequest, exactRequest)

        host.navigationController(
            navigationController,
            willShow: destination,
            animated: true
        )
        host.navigationController(
            navigationController,
            didShow: destination,
            animated: true
        )

        XCTAssertEqual(admittedTransportRequests.count, 1)
        let admittedRequest = try XCTUnwrap(admittedTransportRequests.first)
        XCTAssertEqual(admittedRequest.kind, .detachedPage)
        XCTAssertEqual(admittedRequest.queryIds.count, 1)
        XCTAssertEqual(
            admittedRequest.queryIds,
            Set(admittedRequest.descriptorsByQueryId.keys)
        )
        XCTAssertEqual(admittedRequest.descriptorsByQueryId.count, 1)
        let admittedDescriptor = try XCTUnwrap(
            admittedRequest.descriptorsByQueryId.values.first
        )
        XCTAssertEqual(admittedDescriptor.requestKind, .exactAnchor)
        XCTAssertEqual(admittedDescriptor.archivePurpose, .jump)
        XCTAssertEqual(admittedDescriptor.leasePurpose, .anchorTransaction)
        XCTAssertEqual(admittedDescriptor.semanticRouteClass, .exactTarget)
        XCTAssertEqual(admittedDescriptor.requestSource, .pushNotification)
        XCTAssertEqual(admittedDescriptor.maximumResultCount, 1)
        XCTAssertEqual(
            destination.anchorTransactionGate.snapshot.transactionBeginCount,
            1
        )
        XCTAssertEqual(
            destination.anchorTransactionGate.snapshot.queryIds,
            admittedRequest.queryIds
        )
        XCTAssertEqual(destination.pendingOpenMessageRequest, exactRequest)
        XCTAssertTrue(
            destination.activeAnchorExecutionState?.isRemoteFetchInFlight == true
        )

        host.navigationController(
            navigationController,
            didShow: destination,
            animated: true
        )
        XCTAssertEqual(
            admittedTransportRequests.count,
            1,
            "Repeated didShow must not dispatch a second exact-target request"
        )
        XCTAssertEqual(
            destination.anchorTransactionGate.snapshot.transactionBeginCount,
            1
        )
    }

    @MainActor
    func testColdPushExactPersistenceRematerializesBlockedSessionBeforeContextPublication()
        throws {
        let previousActiveCoordinator = AppRootCoordinator.active
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "AppRootColdPushExactRematerializationTests-\(UUID().uuidString)"
        )
        defer {
            AppRootCoordinator.active = previousActiveCoordinator
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
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
        let exactPrimary = try XCTUnwrap(exactRequest.anchor.messagePrimary)
        let productionTransportDidStart = try XCTUnwrap(
            destination.performanceFixtureArchiveTransportDidStartHandler
        )
        var heldContextRequests:
            [ChatPerformanceFixtureArchiveTransportRequest] = []
        destination.performanceFixtureArchiveTransportDidStartHandler = {
            request in
            let semanticClasses = Set(
                request.descriptorsByQueryId.values.map(\.semanticRouteClass)
            )
            if semanticClasses == [.anchorContext] {
                heldContextRequests.append(request)
            } else {
                productionTransportDidStart(request)
            }
        }

        var realDatasourcePublicationCount = 0
        destination.datasourceDidSetForTests = { datasource in
            if datasource.contains(where: { !$0.isFakeMessage }) {
                realDatasourcePublicationCount &+= 1
            }
        }
        defer { destination.datasourceDidSetForTests = nil }

        destination.prepareForStackedNavigationPresentation(
            targetBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
            completion: {}
        )
        host.navigationController(
            navigationController,
            willShow: destination,
            animated: true
        )
        host.navigationController(
            navigationController,
            didShow: destination,
            animated: true
        )

        XCTAssertTrue(waitUntil(timeout: 4) {
            destination
                .isOpenScenarioExternalSkeletonAcknowledgementArmedForTesting
        })
        let session = try XCTUnwrap(destination.timelineSession)
        let blockedGeneration = session.snapshot.generation
        guard case .blockedMissingTarget =
                destination.initialLocalFirstFramePhase else {
            return XCTFail(
                "Cold exact route must retain its skeleton while the target is missing"
            )
        }
        XCTAssertFalse(session.hasActiveStoreObservationForTests)
        XCTAssertEqual(realDatasourcePublicationCount, 0)
        XCTAssertNil(session.snapshot.residentIndex.index(primary: exactPrimary))

        // This is the production fixture transport: the exact MAM envelope is
        // delivered through MessageArchiveManager and persisted by
        // MessageManager. The test deliberately leaves the controller's
        // production onSnapshot callback untouched and never activates or
        // emits a store observer event.
        XCTAssertTrue(destination.acknowledgeOpenScenarioSkeletonForTesting())
        XCTAssertTrue(waitUntil(timeout: 4) {
            heldContextRequests.isNotEmpty
        })

        let rematerialized = session.snapshot
        XCTAssertEqual(rematerialized.generation, blockedGeneration + 1)
        XCTAssertNotNil(
            rematerialized.residentIndex.index(primary: exactPrimary)
        )
        XCTAssertLessThanOrEqual(
            rematerialized.items.count,
            ChatInitialFirstFrameHistoryConfiguration.pageSize
        )
        XCTAssertEqual(realDatasourcePublicationCount, 0)
        XCTAssertEqual(destination.initialFirstContentApplyCount, 0)
        XCTAssertTrue(destination.showSkeletonObserver.value)

        let contextRequests = heldContextRequests
        heldContextRequests.removeAll()
        contextRequests.forEach(productionTransportDidStart)

        XCTAssertTrue(waitUntil(timeout: 6) {
            destination.pendingOpenMessageRequest == nil &&
                destination.initialFirstContentApplyCount == 1
        })
        XCTAssertEqual(realDatasourcePublicationCount, 1)
        XCTAssertTrue(destination.datasource.contains {
            !$0.isFakeMessage && $0.primary == exactPrimary
        })
        XCTAssertLessThanOrEqual(
            destination.datasource.lazy.filter { !$0.isFakeMessage }.count,
            ChatInitialFirstFrameHistoryConfiguration.pageSize
        )
        XCTAssertLessThanOrEqual(
            session.snapshot.items.count,
            ChatInitialFirstFrameHistoryConfiguration.pageSize
        )
        XCTAssertEqual(
            destination.anchorTransactionGate.snapshot.transactionBeginCount,
            1
        )
    }

    @MainActor
    func testFixtureTerminalTeardownBeforeQueuedConfigureCannotContaminateMatchingOpen()
        throws {
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "AppRootFixtureTerminalIsolationTests-\(UUID().uuidString)"
        )
        defer {
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        }

        let descriptor = ChatPerformanceUITestLaunchDescriptor(
            scale: .small,
            openScenario: .bootstrapEmptyToContent
        )
        let first = ChatPerformanceFixtureViewController(descriptor: descriptor)
        var firstDatasourcePublicationCount = 0
        first.datasourceDidSetForTests = { _ in
            firstDatasourcePublicationCount &+= 1
        }
        first.loadViewIfNeeded()
        let firstDatasourcePublicationBaseline =
            firstDatasourcePublicationCount

        XCTAssertTrue(
            first.isOpenScenarioArchiveTransportReadyForRouteAdmissionForTesting
        )
        first.performTerminalChatResourceTeardownForTesting()

        let second = ChatPerformanceFixtureViewController(descriptor: descriptor)
        XCTAssertEqual(first.owner, second.owner)
        XCTAssertEqual(first.jid, second.jid)
        let window = UIWindow(frame: UIScreen.main.bounds)
        defer {
            first.datasourceDidSetForTests = nil
            first.performOpenScenarioTerminalResourceTeardown()
            second.performOpenScenarioTerminalResourceTeardown()
            window.isHidden = true
            window.rootViewController = nil
        }
        window.rootViewController = UINavigationController(
            rootViewController: second
        )
        window.makeKeyAndVisible()
        second.loadViewIfNeeded()

        XCTAssertTrue(
            waitUntil(timeout: 14) {
                second.openScenarioStableReceipt?.isStable == true
            },
            "The matching second fixture must stabilize without joining " +
                "post-terminal work from the first fixture"
        )
        RunLoop.current.run(
            mode: .default,
            before: Date().addingTimeInterval(0.1)
        )

        XCTAssertEqual(
            first.openScenarioInitialBootstrapRequestInvocationCountForTesting,
            0,
            "A queued configure turn must not start bootstrap after terminal teardown"
        )
        XCTAssertEqual(
            firstDatasourcePublicationCount,
            firstDatasourcePublicationBaseline,
            "A queued configure turn must not publish a datasource after teardown"
        )
        XCTAssertFalse(
            first.isOpenScenarioArchiveTransportReadyForRouteAdmissionForTesting,
            "Terminal teardown must synchronously revoke fixture transport ownership"
        )
        let receipt = try XCTUnwrap(second.openScenarioStableReceipt)
        XCTAssertEqual(receipt.productionBootstrapLeaseStartCount, 1)
        XCTAssertEqual(receipt.productionBootstrapLeaseJoinCount, 0)
        XCTAssertEqual(receipt.productionBootstrapTransportStartCount, 1)
        XCTAssertEqual(receipt.activeProductionWorkCount, 0)
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
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
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
        destination.performPendingOpenMessageRequestIfNeeded(trigger: .manual)

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

    @MainActor
    func testColdPushPreSkeletonExactRouteDefersBootstrapToAnchorTransaction() throws {
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "AppRootColdPushPreSkeletonOwnershipTests-\(UUID().uuidString)"
        )
        defer {
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        }

        let controller = ChatPerformanceFixtureViewController(descriptor: .init(
            scale: .small,
            openScenario: .coldPushExact,
            externalSkeletonAcknowledgementNotificationName:
                ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
                    .notificationName(token: UUID().uuidString)
        ))
        defer { controller.performTerminalChatResourceTeardown() }
        let request = try XCTUnwrap(controller.pendingOpenMessageRequest)

        XCTAssertEqual(request.source, .pushNotification)
        XCTAssertFalse(controller.isViewLoaded)
        XCTAssertFalse(controller.isShowingBootstrapPlaceholder)
        XCTAssertTrue(
            controller.shouldDeferInitialBootstrapArchiveForAnchorTransaction(
                controller.currentInitialBootstrapTargetFingerprint.target
            ),
            "A pre-skeleton exact push target belongs to the anchor transaction; " +
                "account bootstrap must not reinterpret it as saved-position work"
        )
    }

    @MainActor
    func testColdPushPreparingExactRouteDefersBootstrapDespiteStructuralAdmission() throws {
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier:
                "AppRootColdPushPreparingOwnershipTests-\(UUID().uuidString)"
        )
        defer {
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        }

        let controller = ChatViewController()
        controller.owner = "cold-push-preparing-owner@invalid"
        controller.jid = "cold-push-preparing-peer@invalid"
        controller.conversationType = .regular
        controller.loadViewIfNeeded()
        controller.configureDataset()
        defer { controller.performTerminalChatResourceTeardown() }

        let request = ChatOpenMessageRequest(
            chatJid: controller.jid,
            owner: controller.owner,
            conversationType: controller.conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: "cold-push-target-primary",
                archivedId: "cold-push-target-archive-id",
                messageId: "cold-push-target-message-id",
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            highlight: true,
            markReadOnVisible: true,
            source: .pushNotification
        )
        controller.pendingOpenMessageRequest = request
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: controller.owner,
            jid: controller.jid,
            conversationType: controller.conversationType
        )
        controller.initialLocalFirstFramePhase = .preparing(descriptor)

        XCTAssertTrue(controller.isViewLoaded)
        XCTAssertEqual(controller.timelineSession?.snapshot.items.count, 0)
        XCTAssertTrue(
            controller.hasLocalAnchorForBootstrap(request),
            "Structural admission is not proof that the target is resident"
        )
        XCTAssertTrue(
            controller.shouldDeferInitialBootstrapArchiveForAnchorTransaction(
                controller.currentInitialBootstrapTargetFingerprint.target
            ),
            "The preparing exact target must remain owned by the anchor transaction"
        )
    }

    @MainActor
    func testColdPushWithAlreadyPresentMatchingAccountStillRoutesAndConsumesOnce() throws {
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        let previousActiveCoordinator = AppRootCoordinator.active
        let previousInterfaceType =
            CommonConfigManager.shared.config.interface_type
        let previousUsers = AccountManager.shared.users
        let previousActiveUsers = AccountManager.shared.activeUsers.value
        let previousAuthenticatedUsers =
            AccountManager.shared.authenticatedUsers.value
        let previousConnectingUsers =
            AccountManager.shared.connectingUsers.value
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        defer {
            previousKeyWindow?.makeKey()
            NotifyManager.shared
                .resetPendingMessageNotificationChatRouteForTesting()
            AccountManager.shared.users = previousUsers
            AccountManager.shared.activeUsers.accept(previousActiveUsers)
            AccountManager.shared.authenticatedUsers.accept(
                previousAuthenticatedUsers
            )
            AccountManager.shared.connectingUsers.accept(
                previousConnectingUsers
            )
            CommonConfigManager.shared.config.interface_type =
                previousInterfaceType
            AppRootCoordinator.active = previousActiveCoordinator
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration =
                previousRealmConfiguration
        }
        Realm.Configuration.defaultConfiguration =
            makeRealmMigrationConfiguration(
                scheme: XabberRealmSchema.current,
                inMemoryIdentifier:
                    "AppRootExistingAccountColdPushTests-\(UUID().uuidString)"
            )
        NotifyManager.shared.resetPendingMessageNotificationChatRouteForTesting()

        let owner =
            "chat-open-fixture-\(ChatOpenRealPipelineFixtureScenario.coldPushExact.rawValue)-owner@invalid"
        let realmLease = try WRealm.safe()
        defer { withExtendedLifetime(realmLease) {} }
        try realmLease.write {
            let account = AccountStorageItem()
            account.jid = owner
            account.enabled = true
            account.savePassword = false
            realmLease.add(account, update: .modified)
        }
        AccountManager.shared.add(withJid: owner, autoConnect: false)
        AccountManager.shared.markAsConnected(jid: owner)
        XCTAssertNotNil(AccountManager.shared.find(for: owner))

        let acknowledgementToken = UUID().uuidString
        let acknowledgementName = try XCTUnwrap(
            ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
                .notificationName(token: acknowledgementToken)
        )
        let descriptor = ChatPerformanceUITestLaunchDescriptor(
            scale: .small,
            openScenario: .coldPushExact,
            externalSkeletonAcknowledgementNotificationName:
                acknowledgementName
        )
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let coordinator = AppRootCoordinator(window: window, appDelegate: nil)
        coordinator.startChatPerformanceProductionRouteFixture(
            descriptor: descriptor
        )
        let tabController = try XCTUnwrap(
            window.rootViewController as? XabberTabBarViewController
        )
        let navigationController = try XCTUnwrap(
            tabController.viewControllers?.first as? UINavigationController
        )
        let host = try XCTUnwrap(
            navigationController.viewControllers.first as?
                ChatPerformanceLastChatsRouteHostViewController
        )
        let destination = try XCTUnwrap(
            host.compactChatDestinationFactory()
                as? ChatPerformanceFixtureViewController
        )
        let exactRequest = try XCTUnwrap(
            NotifyManager.shared.performancePendingMessageNotificationChatRoute?
                .openMessageRequest
        )
        let productionDelivery = host.chatOpenIntentDeliveryHandler
        var deliveredIntents: [LastChatsResolvedChatOpenIntent] = []
        host.chatOpenIntentDeliveryHandler = { intent, controller in
            deliveredIntents.append(intent)
            productionDelivery(intent, controller)
        }

        defer {
            navigationController.delegate = nil
            destination.performOpenScenarioTerminalResourceTeardown()
            window.isHidden = true
            window.rootViewController = nil
        }

        window.makeKeyAndVisible()
        XCTAssertTrue(waitUntil(timeout: 5) {
            navigationController.topViewController === destination &&
                host.performanceRouteHostDiagnosticsSnapshot.nativePushCount == 1
        })
        RunLoop.current.run(
            mode: .default,
            before: Date().addingTimeInterval(0.05)
        )
        XCTAssertNotNil(
            NotifyManager.shared.performancePendingMessageNotificationChatRoute
        )
        XCTAssertEqual(
            host.performanceRouteHostDiagnosticsSnapshot
                .accountMaterializationCount,
            1
        )
        XCTAssertEqual(
            host.performanceRouteHostDiagnosticsSnapshot.routeAttemptCount,
            1
        )
        XCTAssertEqual(deliveredIntents, [.message(exactRequest)])
        XCTAssertEqual(
            host.performanceRouteHostDiagnosticsSnapshot
                .coldConsumeBeforeStableCount,
            0
        )
        XCTAssertTrue(waitUntil(timeout: 4) {
            destination
                .isOpenScenarioExternalSkeletonAcknowledgementArmedForTesting
        })
        _ = try requireHostedForegroundWindowScene()

        XCTAssertEqual(
            acknowledgementName.withCString { notify_post($0) },
            darwinNotifySuccessStatus
        )
        XCTAssertTrue(waitUntil(timeout: 8) {
            NotifyManager.shared
                .performancePendingMessageNotificationChatRoute == nil &&
                host.performanceRouteHostDiagnosticsSnapshot
                    .coldConsumeAfterStableCount == 1 &&
                destination.openScenarioStableReceipt?.isStable == true
        })
        XCTAssertEqual(deliveredIntents, [.message(exactRequest)])
        XCTAssertEqual(navigationController.viewControllers.count, 2)
        XCTAssertTrue(
            destination.openScenarioStableReceipt?.routeHost
                .isAccepted(for: .coldPushExact) == true
        )
        XCTAssertFalse(host.pendingMessageNotificationRouteRetryHandler())
        XCTAssertEqual(
            host.performanceRouteHostDiagnosticsSnapshot
                .coldConsumeAfterStableCount,
            1
        )
    }

    @MainActor
    func testColdPushSurvivesRootAndAccountStartupAndOpensExactTargetOnce() throws {
        let previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        let previousActiveCoordinator = AppRootCoordinator.active
        let previousInterfaceType =
            CommonConfigManager.shared.config.interface_type
        let previousUsers = AccountManager.shared.users
        let previousActiveUsers = AccountManager.shared.activeUsers.value
        let previousAuthenticatedUsers =
            AccountManager.shared.authenticatedUsers.value
        let previousConnectingUsers =
            AccountManager.shared.connectingUsers.value
        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        defer {
            previousKeyWindow?.makeKey()
            NotifyManager.shared
                .resetPendingMessageNotificationChatRouteForTesting()
            AccountManager.shared.users = previousUsers
            AccountManager.shared.activeUsers.accept(previousActiveUsers)
            AccountManager.shared.authenticatedUsers.accept(
                previousAuthenticatedUsers
            )
            AccountManager.shared.connectingUsers.accept(
                previousConnectingUsers
            )
            CommonConfigManager.shared.config.interface_type =
                previousInterfaceType
            AppRootCoordinator.active = previousActiveCoordinator
            ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
            Realm.Configuration.defaultConfiguration =
                previousRealmConfiguration
        }
        Realm.Configuration.defaultConfiguration =
            makeRealmMigrationConfiguration(
                scheme: XabberRealmSchema.current,
                inMemoryIdentifier:
                    "AppRootColdPushRoutingTests-\(UUID().uuidString)"
            )
        NotifyManager.shared.resetPendingMessageNotificationChatRouteForTesting()
        XCTAssertNil(
            NotifyManager.shared.performancePendingMessageNotificationChatRoute
        )

        let acknowledgementToken = UUID().uuidString
        let acknowledgementName = try XCTUnwrap(
            ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
                .notificationName(token: acknowledgementToken)
        )
        let descriptor = ChatPerformanceUITestLaunchDescriptor(
            scale: .small,
            openScenario: .coldPushExact,
            externalSkeletonAcknowledgementNotificationName:
                acknowledgementName
        )
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let coordinator = AppRootCoordinator(
            window: window,
            appDelegate: nil
        )
        coordinator.startChatPerformanceProductionRouteFixture(
            descriptor: descriptor
        )
        let tabController = try XCTUnwrap(
            window.rootViewController as? XabberTabBarViewController
        )
        let navigationController = try XCTUnwrap(
            tabController.viewControllers?.first as? UINavigationController
        )
        let host = try XCTUnwrap(
            navigationController.viewControllers.first as?
                ChatPerformanceLastChatsRouteHostViewController
        )
        let destination = try XCTUnwrap(
            host.compactChatDestinationFactory()
                as? ChatPerformanceFixtureViewController
        )
        XCTAssertFalse(
            destination.isViewLoaded,
            "This assertion must cover the production pre-view intent boundary"
        )
        XCTAssertTrue(
            destination
                .isOpenScenarioArchiveTransportReadyForRouteAdmissionForTesting,
            "The exact route may be delivered before viewDidLoad, so its " +
                "isolated archive transport must already own that boundary"
        )
        let pendingBeforeRootVisibility = try XCTUnwrap(
            NotifyManager.shared.performancePendingMessageNotificationChatRoute
        )
        let exactRequest = try XCTUnwrap(
            pendingBeforeRootVisibility.openMessageRequest
        )
        XCTAssertEqual(pendingBeforeRootVisibility.owner, destination.owner)
        XCTAssertEqual(pendingBeforeRootVisibility.jid, destination.jid)
        XCTAssertEqual(
            pendingBeforeRootVisibility.conversationType,
            destination.conversationType
        )
        assertCompleteExactPushRequest(
            exactRequest,
            owner: destination.owner,
            jid: destination.jid,
            conversationType: destination.conversationType
        )
        XCTAssertEqual(
            host.performanceRouteHostDiagnosticsSnapshot.coldPendingBeforeRoot,
            1
        )
        XCTAssertEqual(
            host.performanceRouteHostDiagnosticsSnapshot.routeAttemptCount,
            0
        )

        let productionDelivery = host.chatOpenIntentDeliveryHandler
        var deliveredIntents: [LastChatsResolvedChatOpenIntent] = []
        host.chatOpenIntentDeliveryHandler = { intent, controller in
            deliveredIntents.append(intent)
            productionDelivery(intent, controller)
        }

        defer {
            navigationController.delegate = nil
            destination.performOpenScenarioTerminalResourceTeardown()
            window.isHidden = true
            window.rootViewController = nil
        }

        window.makeKeyAndVisible()
        XCTAssertTrue(waitUntil {
            navigationController.topViewController === destination &&
                host.performanceRouteHostDiagnosticsSnapshot.nativePushCount == 1
        })
        RunLoop.current.run(
            mode: .default,
            before: Date().addingTimeInterval(0.05)
        )
        XCTAssertEqual(navigationController.viewControllers.count, 2)
        XCTAssertTrue(navigationController.viewControllers.first === host)
        XCTAssertTrue(navigationController.viewControllers.last === destination)
        XCTAssertTrue(
            host.performanceRouteHostDiagnosticsSnapshot
                .lastChatsVisibleBeforeRoute
        )
        XCTAssertEqual(deliveredIntents, [.message(exactRequest)])
        XCTAssertEqual(
            destination.chatOpenPerformanceTraceTargetFingerprint,
            .message(exactRequest)
        )
        XCTAssertFalse(
            destination.hasStableChatOpenAcknowledgement(for: exactRequest)
        )
        XCTAssertNotNil(
            NotifyManager.shared.performancePendingMessageNotificationChatRoute,
            "Native attachment and push completion must not consume P04"
        )
        XCTAssertEqual(
            host.performanceRouteHostDiagnosticsSnapshot
                .coldConsumeBeforeStableCount,
            0
        )
        XCTAssertEqual(
            host.performanceRouteHostDiagnosticsSnapshot
                .coldConsumeAfterStableCount,
            0
        )
        XCTAssertTrue(waitUntil(timeout: 4) {
            destination
                .isOpenScenarioExternalSkeletonAcknowledgementArmedForTesting
        })
        _ = try requireHostedForegroundWindowScene()

        let postStatus = acknowledgementName.withCString { notify_post($0) }
        XCTAssertEqual(postStatus, darwinNotifySuccessStatus)
        XCTAssertTrue(waitUntil(timeout: 8) {
            NotifyManager.shared
                .performancePendingMessageNotificationChatRoute == nil &&
                host.performanceRouteHostDiagnosticsSnapshot
                    .coldConsumeAfterStableCount == 1 &&
                destination.openScenarioStableReceipt?.isStable == true
        })

        let stableReceipt = try XCTUnwrap(
            destination.openScenarioStableReceipt
        )
        XCTAssertTrue(
            destination.hasStableChatOpenAcknowledgement(for: exactRequest)
        )
        XCTAssertEqual(deliveredIntents, [.message(exactRequest)])
        XCTAssertEqual(navigationController.viewControllers.count, 2)
        XCTAssertEqual(stableReceipt.committedRouteCount, 1)
        XCTAssertEqual(stableReceipt.targetMatchCount, 1)
        XCTAssertEqual(stableReceipt.latestVisualCommitCount, 0)
        XCTAssertEqual(stableReceipt.previousOrBlankRealFrameCount, 0)
        XCTAssertEqual(stableReceipt.postCommitOffsetMutationCount, 0)
        XCTAssertEqual(stableReceipt.correctionCount, 0)
        XCTAssertTrue(stableReceipt.routeHost.isAccepted(for: .coldPushExact))

        XCTAssertFalse(
            host.pendingMessageNotificationRouteRetryHandler(),
            "A duplicate stable wake cannot consume or bookkeep twice"
        )
        XCTAssertNil(
            NotifyManager.shared.performancePendingMessageNotificationChatRoute
        )
        XCTAssertEqual(deliveredIntents, [.message(exactRequest)])
        XCTAssertEqual(
            host.performanceRouteHostDiagnosticsSnapshot
                .coldConsumeAfterStableCount,
            1
        )
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
