import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatObserverLifecycleTests: XCTestCase {

    func testDuplicateAppearanceRegistrationsDeliverSingleNotificationCallbacks() {
        let controller = CountingChatObserverViewController()
        defer { controller.removeObservers() }

        controller.addObservers()
        controller.addObservers()

        postObservedNotifications(on: controller.chatNotificationCenter)

        XCTAssertTrue(controller.chatObserversRegistered)
        XCTAssertEqual(controller.keyboardWillShowCount, 1)
        XCTAssertEqual(controller.foregroundCount, 1)
        XCTAssertEqual(controller.backgroundCount, 1)
        XCTAssertEqual(controller.meteringCount, 1)
    }

    func testDisappearAndReappearRegistersOneFreshObserverSet() {
        let controller = CountingChatObserverViewController()
        defer { controller.removeObservers() }

        controller.addObservers()
        postObservedNotifications(on: controller.chatNotificationCenter)
        XCTAssertEqual(controller.keyboardWillShowCount, 1)
        XCTAssertEqual(controller.foregroundCount, 1)
        XCTAssertEqual(controller.backgroundCount, 1)
        XCTAssertEqual(controller.meteringCount, 1)

        controller.removeObservers()
        XCTAssertFalse(controller.chatObserversRegistered)

        controller.addObservers()
        postObservedNotifications(on: controller.chatNotificationCenter)

        XCTAssertTrue(controller.chatObserversRegistered)
        XCTAssertEqual(controller.keyboardWillShowCount, 2)
        XCTAssertEqual(controller.foregroundCount, 2)
        XCTAssertEqual(controller.backgroundCount, 2)
        XCTAssertEqual(controller.meteringCount, 2)
    }

    func testDuplicateRemoveIsSafeAndLeavesNoActiveCallbacks() {
        let controller = CountingChatObserverViewController()

        controller.removeObservers()
        controller.addObservers()
        controller.removeObservers()
        controller.removeObservers()

        postObservedNotifications(on: controller.chatNotificationCenter)

        XCTAssertFalse(controller.chatObserversRegistered)
        XCTAssertEqual(controller.keyboardWillShowCount, 0)
        XCTAssertEqual(controller.foregroundCount, 0)
        XCTAssertEqual(controller.backgroundCount, 0)
        XCTAssertEqual(controller.meteringCount, 0)
    }

    private func postObservedNotifications(on notificationCenter: NotificationCenter) {
        notificationCenter.post(
            name: UIWindow.keyboardWillShowNotification,
            object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: CGRect(x: 0, y: 640, width: 390, height: 204))
            ]
        )
        notificationCenter.post(
            name: UIApplication.willEnterForegroundNotification,
            object: UIApplication.shared
        )
        notificationCenter.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: UIApplication.shared
        )
        notificationCenter.post(
            name: .recorderDidUpdateMeteringLevelNotification,
            object: nil,
            userInfo: [AudioRecorder.audioPercentageUserInfoKey: Float(0.5)]
        )
    }
}

private final class CountingChatObserverViewController: ChatViewController {
    private(set) var keyboardWillShowCount = 0
    private(set) var foregroundCount = 0
    private(set) var backgroundCount = 0
    private(set) var meteringCount = 0

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        chatNotificationCenter = NotificationCenter()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        chatNotificationCenter = NotificationCenter()
    }

    override func keyboardWillShowNotification(_ notification: Notification) {
        keyboardWillShowCount += 1
    }

    override func willEnterForeground() {
        foregroundCount += 1
    }

    override func handleApplicationDidEnterBackground() {
        backgroundCount += 1
    }

    override func onMeteringLevelDidUpdate(_ notification: Notification) {
        meteringCount += 1
    }
}
