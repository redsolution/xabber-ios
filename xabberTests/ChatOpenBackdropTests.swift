import UIKit
import XCTest
import RealmSwift
@testable import xabber

final class ChatOpenBackdropTests: XCTestCase {
    func testManualNativeBackLaunchPolicyRequiresOneDedicatedFlagAndNoOpenScenario() {
        let environment = [
            ChatPerformanceUITestLaunchPolicy.uiTestMarkerKey: "1"
        ]
        let baseArguments = [
            "xabber",
            ChatPerformanceUITestLaunchPolicy.launchArgument,
            ChatPerformanceFixtureScale.small.rawValue
        ]

        XCTAssertFalse(ChatPerformanceManualNativeBackLaunchPolicy.isEnabled(
            arguments: baseArguments,
            environment: environment
        ))
        XCTAssertTrue(ChatPerformanceManualNativeBackLaunchPolicy.isEnabled(
            arguments: baseArguments + [
                ChatPerformanceManualNativeBackLaunchPolicy.launchArgument
            ],
            environment: environment
        ))
        XCTAssertFalse(ChatPerformanceManualNativeBackLaunchPolicy.isEnabled(
            arguments: baseArguments + [
                ChatPerformanceManualNativeBackLaunchPolicy.launchArgument,
                ChatPerformanceManualNativeBackLaunchPolicy.launchArgument
            ],
            environment: environment
        ))
        XCTAssertFalse(ChatPerformanceManualNativeBackLaunchPolicy.isEnabled(
            arguments: baseArguments + [
                ChatPerformanceUITestLaunchPolicy.openScenarioLaunchArgument,
                ChatOpenRealPipelineFixtureScenario.lastChatsAnimatedPush.rawValue,
                ChatPerformanceManualNativeBackLaunchPolicy.launchArgument
            ],
            environment: environment
        ))
    }

    @MainActor
    func testManualNativeBackFixtureStartsAtOneRealLastChatsRowWithoutAutoPush() throws {
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
        var previousKeyWindow: UIWindow?
        Realm.Configuration.defaultConfiguration =
            makeRealmMigrationConfiguration(
                scheme: XabberRealmSchema.current,
                inMemoryIdentifier:
                    "ChatOpenManualNativeBackTests-\(UUID().uuidString)"
            )

        let scene = try requireHostedForegroundWindowScene()
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let descriptor = ChatPerformanceUITestLaunchDescriptor(scale: .small)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let coordinator = AppRootCoordinator(window: window, appDelegate: nil)
        coordinator.startChatPerformanceManualNativeBackFixture(
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
                ChatPerformanceManualNativeBackLastChatsHostViewController
        )

        defer {
            navigationController.delegate = nil
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
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
            Realm.Configuration.defaultConfiguration =
                previousRealmConfiguration
        }

        window.makeKeyAndVisible()
        XCTAssertTrue(waitUntil(timeout: 3) {
            host.tableView.numberOfRows(inSection: 0) == 1 &&
                host.tableView.cellForRow(at: IndexPath(row: 0, section: 0))?
                    .accessibilityIdentifier ==
                    ChatPerformanceManualNativeBackAccessibility.row
        })
        XCTAssertEqual(navigationController.viewControllers.count, 1)
        XCTAssertTrue(navigationController.topViewController === host)
        XCTAssertEqual(
            tabController.view.accessibilityIdentifier,
            ChatPerformanceManualNativeBackAccessibility.tabShell
        )
        XCTAssertEqual(
            navigationController.view.accessibilityIdentifier,
            ChatPerformanceManualNativeBackAccessibility.navigationShell
        )
        XCTAssertEqual(
            host.view.accessibilityIdentifier,
            ChatPerformanceManualNativeBackAccessibility.lastChatsScreen
        )
    }

    @MainActor
    func testAnimatedPushHasOpaqueDestinationBackdropBeforeFirstRowAndNeverUsesDirectChatRoot() throws {
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
        var previousKeyWindow: UIWindow?
        Realm.Configuration.defaultConfiguration =
            makeRealmMigrationConfiguration(
                scheme: XabberRealmSchema.current,
                inMemoryIdentifier:
                    "ChatOpenBackdropTests-\(UUID().uuidString)"
            )
        NotifyManager.shared.resetPendingMessageNotificationChatRouteForTesting()

        let scene = try requireHostedForegroundWindowScene()
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let descriptor = ChatPerformanceUITestLaunchDescriptor(
            scale: .small,
            openScenario: .lastChatsAnimatedPush
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
        XCTAssertTrue(navigationController.viewControllers.first === host)
        XCTAssertFalse(window.rootViewController is ChatViewController)
        XCTAssertEqual(
            ChatPerformanceFixtureRootPolicy.mode(
                for: .lastChatsAnimatedPush
            ),
            .lastChatsNativeRoute
        )

        let productionDelivery = host.chatOpenIntentDeliveryHandler
        var deliveredIntents: [LastChatsResolvedChatOpenIntent] = []
        host.chatOpenIntentDeliveryHandler = { intent, controller in
            deliveredIntents.append(intent)
            productionDelivery(intent, controller)
        }

        defer {
            navigationController.delegate = nil
            destination.performTerminalChatResourceTeardown()
            window.isHidden = true
            window.rootViewController = nil
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

        window.makeKeyAndVisible()
        XCTAssertTrue(waitUntil(timeout: 5) {
            navigationController.topViewController === destination &&
                destination.openScenarioStableReceipt?.isStable == true
        })
        let backdrop = destination
            .chatDestinationBackdropInstallationReceipt
        let receipt = try XCTUnwrap(destination.openScenarioStableReceipt)

        XCTAssertEqual(navigationController.viewControllers.count, 2)
        XCTAssertTrue(navigationController.viewControllers.first === host)
        XCTAssertTrue(navigationController.viewControllers.last === destination)
        XCTAssertEqual(deliveredIntents, [.latest])
        XCTAssertTrue(backdrop.isOpaque)
        XCTAssertEqual(backdrop.priorDatasourceRowCount, 0)
        XCTAssertTrue(backdrop.isOpaqueBeforeFirstDatasourceRow)
        XCTAssertEqual(receipt.previousOrBlankRealFrameCount, 0)
        XCTAssertEqual(receipt.realDatasourceApplyCount, 1)
        XCTAssertEqual(receipt.visualCommitCount, 1)
        XCTAssertEqual(receipt.postCommitOffsetMutationCount, 0)
        XCTAssertEqual(receipt.correctionCount, 0)
        XCTAssertTrue(
            receipt.routeHost.isAccepted(for: .lastChatsAnimatedPush)
        )
        XCTAssertEqual(receipt.routeHost.nativePushCount, 1)
        XCTAssertEqual(receipt.routeHost.lastChatsExposureCount, 0)
        XCTAssertTrue(receipt.routeHost.destinationOpaqueBeforeFirstRow)
    }

    func testNativePushBackdropPolicyRejectsDirectRootTransparencyAndOldRows() {
        XCTAssertTrue(ChatPerformanceNativePushBackdropPolicy.isAdmissible(
            rootIsRealLastChatsHost: true,
            usesProductionStackNewChat: true,
            usesNativeAnimatedPush: true,
            destinationViewIsAttached: true,
            destinationBackdropIsOpaque: true,
            destinationBackdropInstalledBeforeFirstRow: true,
            priorDatasourceRowCount: 0,
            lastChatsExposureCount: 0
        ))
        XCTAssertFalse(ChatPerformanceNativePushBackdropPolicy.isAdmissible(
            rootIsRealLastChatsHost: false,
            usesProductionStackNewChat: true,
            usesNativeAnimatedPush: true,
            destinationViewIsAttached: true,
            destinationBackdropIsOpaque: true,
            destinationBackdropInstalledBeforeFirstRow: true,
            priorDatasourceRowCount: 0,
            lastChatsExposureCount: 0
        ))
        XCTAssertFalse(ChatPerformanceNativePushBackdropPolicy.isAdmissible(
            rootIsRealLastChatsHost: true,
            usesProductionStackNewChat: true,
            usesNativeAnimatedPush: true,
            destinationViewIsAttached: true,
            destinationBackdropIsOpaque: false,
            destinationBackdropInstalledBeforeFirstRow: false,
            priorDatasourceRowCount: 24,
            lastChatsExposureCount: 1
        ))
    }

    func testNotificationRequiresNativeAttachmentAndMatchingStableTargetFrame() {
        let request = ChatOpenMessageRequest(
            chatJid: "peer@example.com",
            owner: "owner@example.com",
            conversationType: .regular,
            anchor: ChatMessageAnchorRef(
                messagePrimary: "primary-1",
                archivedId: "archive-1",
                messageId: "message-1",
                authorId: "author@example.com",
                bodyFingerprint: "fingerprint-1",
                sourceDate: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            highlight: true,
            markReadOnVisible: true,
            source: .pushNotification
        )
        XCTAssertFalse(LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
            navigationSource: .notification,
            request: request,
            isStableVisibleDestination: true,
            hasStableTargetAcknowledgement: false
        ))
        XCTAssertFalse(LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
            navigationSource: .notification,
            request: request,
            isStableVisibleDestination: false,
            hasStableTargetAcknowledgement: true
        ))
        XCTAssertTrue(LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
            navigationSource: .notification,
            request: request,
            isStableVisibleDestination: true,
            hasStableTargetAcknowledgement: true
        ))
        XCTAssertTrue(LastChatsChatOpenAcknowledgementPolicy.shouldAcknowledge(
            navigationSource: .standard,
            request: nil,
            isStableVisibleDestination: false,
            hasStableTargetAcknowledgement: false
        ))
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
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
