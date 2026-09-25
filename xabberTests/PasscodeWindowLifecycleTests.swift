import UIKit
import XCTest
@testable import xabber

final class PasscodeWindowLifecycleTests: XCTestCase {
    func testUnlockCompletionRequiresForegroundPINWindow() {
        XCTAssertTrue(PasscodeUnlockPresentationPolicy.canComplete(
            isLocked: true,
            isPINWindow: true,
            sceneState: .foregroundActive,
            wipePending: false
        ))
        XCTAssertFalse(PasscodeUnlockPresentationPolicy.canComplete(
            isLocked: true,
            isPINWindow: true,
            sceneState: .foregroundInactive,
            wipePending: false
        ))
        XCTAssertFalse(PasscodeUnlockPresentationPolicy.canComplete(
            isLocked: true,
            isPINWindow: true,
            sceneState: .background,
            wipePending: false
        ))
        XCTAssertFalse(PasscodeUnlockPresentationPolicy.canComplete(
            isLocked: true,
            isPINWindow: false,
            sceneState: .foregroundActive,
            wipePending: false
        ))
        XCTAssertFalse(PasscodeUnlockPresentationPolicy.canComplete(
            isLocked: true,
            isPINWindow: true,
            sceneState: .foregroundActive,
            wipePending: true
        ))
    }

    func testAutoLockUsesBackgroundElapsedTimeAndNever() {
        let now = Date(timeIntervalSince1970: 1_000)
        let leftAt = now.addingTimeInterval(-299)

        XCTAssertFalse(PasscodeAutoLockPolicy.shouldLockOnResume(
            period: 300,
            leftAt: leftAt,
            now: now
        ))
        XCTAssertTrue(PasscodeAutoLockPolicy.shouldLockOnResume(
            period: 300,
            leftAt: now.addingTimeInterval(-300),
            now: now
        ))
        XCTAssertFalse(PasscodeAutoLockPolicy.shouldLockOnResume(
            period: 0,
            leftAt: nil,
            now: now
        ))
        XCTAssertTrue(PasscodeAutoLockPolicy.shouldLockOnResume(
            period: 300,
            leftAt: nil,
            now: now
        ))
        XCTAssertTrue(PasscodeAutoLockPolicy.shouldLockOnResume(
            period: 300,
            leftAt: now.addingTimeInterval(1),
            now: now
        ))
    }

    func testAccountStoreRecoveryCannotBypassExpiredAutoLock() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(PasscodeAccountStoreRecoveryPolicy.requiresPIN(
            hasEnrolledPIN: true,
            period: 300,
            wasDueWhenForegrounded: false,
            pendingBackgroundAt: now.addingTimeInterval(-301),
            now: now
        ))
        XCTAssertTrue(PasscodeAccountStoreRecoveryPolicy.requiresPIN(
            hasEnrolledPIN: true,
            period: 300,
            wasDueWhenForegrounded: true,
            pendingBackgroundAt: nil,
            now: now
        ))
        XCTAssertFalse(PasscodeAccountStoreRecoveryPolicy.requiresPIN(
            hasEnrolledPIN: true,
            period: 300,
            wasDueWhenForegrounded: false,
            pendingBackgroundAt: now.addingTimeInterval(-299),
            now: now
        ))
        XCTAssertFalse(PasscodeAccountStoreRecoveryPolicy.requiresPIN(
            hasEnrolledPIN: true,
            period: 300,
            wasDueWhenForegrounded: false,
            pendingBackgroundAt: nil,
            now: now.addingTimeInterval(1_000)
        ))
        XCTAssertFalse(PasscodeAccountStoreRecoveryPolicy.requiresPIN(
            hasEnrolledPIN: true,
            period: 0,
            wasDueWhenForegrounded: true,
            pendingBackgroundAt: now.addingTimeInterval(-301),
            now: now
        ))
    }

    @MainActor
    func testLockDetachesContentAndRestoresItAfterUnlock() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
        )
        let priorKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let coordinator = PasscodeLockCoordinator()
        let mainWindow = UIWindow(windowScene: scene)
        let content = UIViewController()
        content.view.accessibilityIdentifier = "private.content"
        mainWindow.rootViewController = content
        mainWindow.makeKeyAndVisible()
        defer {
            coordinator.hide(animated: false)
            mainWindow.isHidden = true
            priorKeyWindow?.makeKeyAndVisible()
        }

        XCTAssertTrue(coordinator.show(
            animated: true,
            mainWindow: mainWindow,
            onUnlock: {}
        ))

        let lockWindow = try XCTUnwrap(coordinator.visibleWindow)
        XCTAssertTrue(lockWindow.windowScene === scene)
        XCTAssertTrue(lockWindow.rootViewController is PasscodeOrBiometricViewController)
        XCTAssertNil(lockWindow.rootViewController?.presentingViewController)
        XCTAssertEqual(lockWindow.alpha, 1)
        XCTAssertTrue(lockWindow.accessibilityViewIsModal)
        XCTAssertTrue(coordinator.isProtected)
        XCTAssertTrue(mainWindow.accessibilityElementsHidden)
        XCTAssertFalse(mainWindow.rootViewController === content)
        XCTAssertEqual(
            mainWindow.rootViewController?.view.accessibilityIdentifier,
            "passcode.neutralRoot"
        )
        XCTAssertNil(content.view.window)

        coordinator.hide(animated: false)

        XCTAssertTrue(mainWindow.rootViewController === content)
        XCTAssertFalse(mainWindow.accessibilityElementsHidden)
        XCTAssertFalse(coordinator.isProtected)
        XCTAssertNil(coordinator.visibleWindow)
    }

    @MainActor
    func testRecoveredAccountStoreBlockerSwapsToPINBeforeRevealingContent() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
        )
        let priorKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let coordinator = PasscodeLockCoordinator()
        let mainWindow = UIWindow(windowScene: scene)
        let content = UIViewController()
        content.view.accessibilityIdentifier = "private.content"
        mainWindow.rootViewController = content
        mainWindow.makeKeyAndVisible()
        defer {
            coordinator.hide(animated: false)
            mainWindow.isHidden = true
            priorKeyWindow?.makeKeyAndVisible()
        }

        XCTAssertTrue(coordinator.showAccountStoreBlocker(
            mainWindow: mainWindow,
            onRetry: {}
        ))
        let blockerWindow = try XCTUnwrap(coordinator.visibleWindow)
        XCTAssertTrue(coordinator.isShowingAccountStoreBlocker)
        XCTAssertNil(content.view.window)

        XCTAssertTrue(coordinator.show(
            animated: false,
            mainWindow: mainWindow,
            onUnlock: {}
        ))

        XCTAssertTrue(coordinator.visibleWindow === blockerWindow)
        XCTAssertTrue(blockerWindow.rootViewController is PasscodeOrBiometricViewController)
        XCTAssertFalse(coordinator.isShowingAccountStoreBlocker)
        XCTAssertTrue(mainWindow.accessibilityElementsHidden)
        XCTAssertNil(content.view.window)
        XCTAssertEqual(
            mainWindow.rootViewController?.view.accessibilityIdentifier,
            "passcode.neutralRoot"
        )
    }
}
