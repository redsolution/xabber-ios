import XCTest
import RealmSwift
@testable import xabber

final class QuitAccountFlowStateTests: XCTestCase {
    func testConfirmingQuitAccountEntersInProgressBeforeCleanupStarts() {
        var flow = QuitAccountCleanupFlowState()

        XCTAssertFalse(flow.isInProgress)
        XCTAssertTrue(flow.beginCleanup())

        XCTAssertTrue(flow.isInProgress)
        XCTAssertFalse(flow.canStartQuit)
    }

    func testQuitAccountCannotStartAgainWhileCleanupIsInProgress() {
        var flow = QuitAccountCleanupFlowState()

        XCTAssertTrue(flow.beginCleanup())
        XCTAssertFalse(flow.beginCleanup())
    }

    func testSessionActionsAreBlockedWhileCleanupIsInProgress() {
        var flow = QuitAccountCleanupFlowState()

        XCTAssertTrue(flow.canPerformSecurityAction)
        XCTAssertTrue(flow.beginCleanup())

        XCTAssertFalse(flow.canPerformSecurityAction)
    }

    func testCompletionRoutesToOnboardingWhenNoAccountsRemain() {
        var flow = QuitAccountCleanupFlowState()

        XCTAssertTrue(flow.beginCleanup())
        XCTAssertEqual(flow.complete(hasRemainingAccounts: false), .onboarding)

        XCTAssertFalse(flow.isInProgress)
        XCTAssertTrue(flow.canStartQuit)
    }

    func testCompletionReturnsToRootWhenOtherAccountsRemain() {
        var flow = QuitAccountCleanupFlowState()

        XCTAssertTrue(flow.beginCleanup())
        XCTAssertEqual(flow.complete(hasRemainingAccounts: true), .root)

        XCTAssertFalse(flow.isInProgress)
        XCTAssertTrue(flow.canStartQuit)
    }

    func testFailureReturnsToRetryableIdleState() {
        var flow = QuitAccountCleanupFlowState()

        XCTAssertTrue(flow.beginCleanup())
        flow.failCleanup()

        XCTAssertFalse(flow.isInProgress)
        XCTAssertTrue(flow.canStartQuit)
        XCTAssertTrue(flow.canPerformSecurityAction)
    }

    func testQuitConfirmationCopySeparatesDeviceCleanupFromServerData() {
        let message = QuitAccountPresenter.confirmationMessage(
            jid: "cleanup@example.test"
        ).lowercased()

        XCTAssertTrue(message.contains("cleanup@example.test"))
        XCTAssertTrue(message.contains("deleted from this device"))
        XCTAssertTrue(message.contains("server"))
        XCTAssertTrue(message.contains("not be affected"))
    }

    @MainActor
    func testProgressStateDisablesDevicesTableAndShowsAccessibleOverlay() {
        let controller = QuitAccountDevicesFixture()
        controller.loadViewIfNeeded()
        controller.configure(for: "cleanup@example.test")

        controller.setAccountQuitProgressVisible(true)

        XCTAssertFalse(controller.tableView.isUserInteractionEnabled)
        XCTAssertFalse(controller.refreshControl.isEnabled)
        XCTAssertTrue(controller.isAccountQuitProgressVisible)
        XCTAssertEqual(
            controller.accountQuitProgressView?.accessibilityLabel,
            "Deleting account data from this device"
        )

        controller.setAccountQuitProgressVisible(false)

        XCTAssertTrue(controller.tableView.isUserInteractionEnabled)
        XCTAssertTrue(controller.refreshControl.isEnabled)
        XCTAssertFalse(controller.isAccountQuitProgressVisible)
    }

    @MainActor
    func testProgressStateClearsOnlyAfterAsyncCleanupCompletion() async throws {
        let controller = QuitAccountDevicesFixture()
        controller.loadViewIfNeeded()
        controller.configure(for: "cleanup@example.test")

        let cleanupStarted = expectation(description: "cleanup starts")
        var capturedCompletion: ((AccountDeletionCleanupResult) -> Void)?
        controller.accountQuitDeletionHandler = { _, completion in
            capturedCompletion = completion
            cleanupStarted.fulfill()
        }
        controller.accountQuitRemainingAccountsProvider = {
            true
        }

        XCTAssertTrue(controller.beginConfirmedQuitAccountCleanup())
        await fulfillment(of: [cleanupStarted], timeout: 2)

        XCTAssertTrue(controller.isAccountQuitProgressVisible)
        XCTAssertFalse(controller.accountQuitFlow.canStartQuit)

        try XCTUnwrap(capturedCompletion)(
            AccountDeletionCleanupResult(
                jid: "cleanup@example.test",
                hard: true,
                succeeded: true,
                failedStage: nil,
                errorDescription: nil,
                storageInvokedOnMainThread: false
            )
        )

        XCTAssertFalse(controller.isAccountQuitProgressVisible)
        XCTAssertTrue(controller.accountQuitFlow.canStartQuit)
    }

    @MainActor
    func testSettingsCleanupFailureKeepsRootAndRestoresRetryableInteraction() async throws {
        let window = try makeQuitAccountTestWindow()
        let controller = UIViewController()
        let navigation = UINavigationController(rootViewController: controller)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer {
            navigation.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        let cleanupStarted = expectation(description: "settings cleanup starts")
        var cleanupCompletion: ((AccountDeletionCleanupResult) -> Void)?
        var unsubscribeCount = 0
        let presenter = QuitAccountPresenter(jid: "cleanup@example.test")
        let deletion: QuitAccountPresenter.CleanupHandler = { _, completion in
            cleanupCompletion = completion
            cleanupStarted.fulfill()
        }

        XCTAssertTrue(presenter.beginCleanup(in: controller, beforeCleanup: {
            unsubscribeCount += 1
        }, deletionHandler: deletion))
        XCTAssertFalse(presenter.beginCleanup(in: controller, deletionHandler: deletion))
        await fulfillment(of: [cleanupStarted], timeout: 2)
        XCTAssertEqual(unsubscribeCount, 1)
        XCTAssertFalse(controller.view.isUserInteractionEnabled)
        XCTAssertTrue(navigation.isModalInPresentation)
        XCTAssertTrue(window.rootViewController === navigation)
        XCTAssertNil(navigation.presentedViewController)

        try XCTUnwrap(cleanupCompletion)(.failure(
            jid: "cleanup@example.test",
            hard: true,
            failedStage: .postCleanup,
            error: NSError(domain: "QuitAccountTests", code: 1),
            storageInvokedOnMainThread: false
        ))

        XCTAssertTrue(window.rootViewController === navigation)
        XCTAssertTrue(controller.view.isUserInteractionEnabled)
        XCTAssertFalse(navigation.isModalInPresentation)
        XCTAssertFalse(controller.navigationItem.hidesBackButton)
        XCTAssertTrue(controller.presentedViewController is UIAlertController)
    }

    @MainActor
    func testLastAccountCleanupRebuildsTheOwningWindowAfterCompletion() async throws {
        let previousCoordinator = AppRootCoordinator.active
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        let appDelegate = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let previousWindow = appDelegate.window
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "QuitAccountNavigation-\(UUID().uuidString)"
        )
        let realm = try openQuitAccountTestRealm()
        let window = try makeQuitAccountTestWindow()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            AppRootCoordinator.active = previousCoordinator
            appDelegate.window = previousWindow
            Realm.Configuration.defaultConfiguration = previousConfiguration
            withExtendedLifetime(realm) {}
        }

        let root = UIViewController()
        let coordinator = AppRootCoordinator(window: window, appDelegate: nil)
        window.rootViewController = root
        window.makeKeyAndVisible()
        let controller = QuitAccountDevicesFixture()
        controller.configure(for: "cleanup@example.test")
        let navigation = UINavigationController(rootViewController: controller)
        root.present(navigation, animated: false)
        coordinator.currentPresentedVc = navigation
        // Scene-owned windows must not depend on the legacy app-delegate window.
        appDelegate.window = nil
        let cleanupStarted = expectation(description: "cleanup starts")
        var cleanupCompletion: ((AccountDeletionCleanupResult) -> Void)?
        controller.accountQuitDeletionHandler = { _, completion in
            cleanupCompletion = completion
            cleanupStarted.fulfill()
        }
        controller.accountQuitRemainingAccountsProvider = { false }

        XCTAssertTrue(controller.beginConfirmedQuitAccountCleanup())
        await fulfillment(of: [cleanupStarted], timeout: 2)
        XCTAssertTrue(window.rootViewController === root)
        XCTAssertTrue(root.presentedViewController === navigation)

        try XCTUnwrap(cleanupCompletion)(.success(
            jid: "cleanup@example.test", hard: true, storageInvokedOnMainThread: false
        ))
        let navigationFinished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (window.rootViewController as? UINavigationController)?.viewControllers.first is OnboardingViewController
                && root.presentedViewController == nil
        }, object: nil)
        await fulfillment(of: [navigationFinished], timeout: 3)

        let onboarding = window.rootViewController as? UINavigationController
        XCTAssertTrue(onboarding?.viewControllers.first is OnboardingViewController)
        XCTAssertNil(root.presentedViewController)
        XCTAssertNil(coordinator.currentPresentedVc)
    }

    @MainActor
    func testRemainingAccountCleanupDismissesAccountSettingsModal() async throws {
        let previousCoordinator = AppRootCoordinator.active
        let window = try makeQuitAccountTestWindow()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            AppRootCoordinator.active = previousCoordinator
        }
        let root = UIViewController()
        let coordinator = AppRootCoordinator(window: window, appDelegate: nil)
        window.rootViewController = root
        window.makeKeyAndVisible()
        let settings = UIViewController()
        let controller = QuitAccountDevicesFixture()
        controller.configure(for: "cleanup@example.test")
        let navigation = UINavigationController(rootViewController: settings)
        navigation.pushViewController(controller, animated: false)
        root.present(navigation, animated: false)
        coordinator.currentPresentedVc = navigation
        let cleanupStarted = expectation(description: "cleanup starts")
        var cleanupCompletion: ((AccountDeletionCleanupResult) -> Void)?
        controller.accountQuitDeletionHandler = { _, completion in
            cleanupCompletion = completion
            cleanupStarted.fulfill()
        }
        controller.accountQuitRemainingAccountsProvider = { true }

        XCTAssertTrue(controller.beginConfirmedQuitAccountCleanup())
        await fulfillment(of: [cleanupStarted], timeout: 2)
        try XCTUnwrap(cleanupCompletion)(.success(
            jid: "cleanup@example.test", hard: true, storageInvokedOnMainThread: false
        ))
        let navigationFinished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            root.presentedViewController == nil
        }, object: nil)
        await fulfillment(of: [navigationFinished], timeout: 3)

        XCTAssertTrue(window.rootViewController === root)
        XCTAssertNil(root.presentedViewController)
        XCTAssertNil(coordinator.currentPresentedVc)
    }

}


// Keep real cleanup/navigation behavior without starting XMPP UI-action requests.
private final class QuitAccountDevicesFixture: DevicesListViewController {
    override func viewDidLoad() {}
    override func viewWillAppear(_ animated: Bool) {}
}

private func openQuitAccountTestRealm() throws -> Realm { try Realm() }

@MainActor
private func makeQuitAccountTestWindow() throws -> UIWindow {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    return UIWindow(windowScene: scene)
}
