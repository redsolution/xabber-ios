import XCTest
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
        let controller = DevicesListViewController()
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
    func testProgressStateClearsOnlyAfterAsyncCleanupCompletion() {
        let controller = DevicesListViewController()
        controller.loadViewIfNeeded()
        controller.configure(for: "cleanup@example.test")

        var capturedCompletion: ((AccountDeletionCleanupResult) -> Void)?
        controller.accountQuitDeletionHandler = { _, completion in
            capturedCompletion = completion
        }
        controller.accountQuitRemainingAccountsProvider = {
            true
        }

        XCTAssertTrue(controller.beginConfirmedQuitAccountCleanup())
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(controller.isAccountQuitProgressVisible)
        XCTAssertFalse(controller.accountQuitFlow.canStartQuit)

        capturedCompletion?(
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
}
