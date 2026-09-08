import XCTest
@testable import xabber

final class NotificationsSettingsViewControllerTests: XCTestCase {
    private final class Store: NotificationsSettingsStoring {
        var boolValues: [String: Bool]
        var stringValues: [String: String]

        init(
            boolValues: [String: Bool] = [
                "notification_in_app_sound": true,
                "notification_in_app_alert_last_chats": false
            ],
            stringValues: [String: String] = [:]
        ) {
            self.boolValues = boolValues
            self.stringValues = stringValues
        }

        func bool(for key: String, default defaultValue: Bool) -> Bool {
            boolValues[key] ?? defaultValue
        }

        func setBool(_ value: Bool, for key: String) {
            boolValues[key] = value
        }

        func string(for key: String) -> String? {
            stringValues[key]
        }
    }

    @MainActor
    func testNotificationsSettingsShowsMessageInAppAndSystemSections() throws {
        let controller = NotificationsSettingsViewController(store: Store())
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.tableView.numberOfSections, 3)
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 0), 2)
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 1), 2)
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 2), 1)

        let messagesCell = try XCTUnwrap(controller.tableView.cellForRow(at: IndexPath(row: 0, section: 0)))
        let inAppSoundCell = try XCTUnwrap(controller.tableView.cellForRow(at: IndexPath(row: 0, section: 1)))
        let systemSettingsCell = try XCTUnwrap(controller.tableView.cellForRow(at: IndexPath(row: 0, section: 2)))

        XCTAssertEqual(messagesCell.accessibilityIdentifier, "notifications.messages")
        XCTAssertEqual(inAppSoundCell.accessibilityIdentifier, "notifications.inAppSounds")
        XCTAssertEqual(systemSettingsCell.accessibilityIdentifier, "notifications.systemSettings")
    }

    @MainActor
    func testChangingInAppSoundPersistsExistingNotificationPreference() throws {
        let store = Store()
        let controller = NotificationsSettingsViewController(store: store)
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        let cell = try XCTUnwrap(controller.tableView.cellForRow(at: IndexPath(row: 0, section: 1)))
        let soundSwitch = try XCTUnwrap(
            descendant(in: cell, accessibilityIdentifier: "notifications.inAppSounds.switch") as? UISwitch
        )

        soundSwitch.setOn(false, animated: false)
        soundSwitch.sendActions(for: .valueChanged)

        XCTAssertEqual(store.boolValues["notification_in_app_sound"], false)
    }

    private func descendant(in root: UIView, accessibilityIdentifier: String) -> UIView? {
        if root.accessibilityIdentifier == accessibilityIdentifier {
            return root
        }
        for subview in root.subviews {
            if let match = descendant(in: subview, accessibilityIdentifier: accessibilityIdentifier) {
                return match
            }
        }
        return nil
    }
}
