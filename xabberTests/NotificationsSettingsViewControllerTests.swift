import XCTest
@testable import xabber

final class NotificationsSettingsViewControllerTests: XCTestCase {
    private final class Store: NotificationsSettingsStoring {
        var boolValues: [String: Bool]
        var stringValues: [String: String]
        private(set) var boolWrites: [(key: String, value: Bool)] = []

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
            boolWrites.append((key: key, value: value))
        }

        func string(for key: String) -> String? {
            stringValues[key]
        }
    }

    @MainActor
    func testNotificationsSettingsShowsTypeSoundInAppAndSystemSections() throws {
        let controller = NotificationsSettingsViewController(store: Store())
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.tableView.numberOfSections, 4)
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 0), 3)
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 1), 2)
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 2), 2)
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 3), 1)

        let messagesCell = cell(from: controller, row: 0, section: 0)
        let invitesCell = cell(from: controller, row: 1, section: 0)
        let subscriptionRequestsCell = cell(from: controller, row: 2, section: 0)
        let messageSoundCell = cell(from: controller, row: 0, section: 1)
        let inAppSoundCell = cell(from: controller, row: 0, section: 2)
        let systemSettingsCell = cell(from: controller, row: 0, section: 3)

        XCTAssertEqual(messagesCell.accessibilityIdentifier, "notifications.messages")
        XCTAssertEqual(invitesCell.accessibilityIdentifier, "notifications.invites")
        XCTAssertEqual(subscriptionRequestsCell.accessibilityIdentifier, "notifications.subscriptionRequests")
        XCTAssertEqual(messageSoundCell.accessibilityIdentifier, "notifications.messageSound")
        XCTAssertEqual(inAppSoundCell.accessibilityIdentifier, "notifications.inAppSounds")
        XCTAssertEqual(systemSettingsCell.accessibilityIdentifier, "notifications.systemSettings")
    }

    @MainActor
    func testNotificationTypeSwitchesDefaultOnAndUseSettingsSizedIcons() throws {
        let controller = NotificationsSettingsViewController(store: Store())
        controller.loadViewIfNeeded()

        let expectations: [(row: Int, identifier: String, icon: String)] = [
            (0, "notifications.messages", "custom.bubble.square.fill"),
            (1, "notifications.invites", "xabber.invite.square.fill"),
            (2, "notifications.subscriptionRequests", "xabber.person.plus.square.fill")
        ]

        XCTAssertEqual(SettingsMenuIconMetrics.dimension, 24)
        for expectation in expectations {
            let cell = cell(from: controller, row: expectation.row, section: 0)
            let typeSwitch = try XCTUnwrap(cell.accessoryView as? UISwitch)
            let iconView = try XCTUnwrap(cell.imageView)

            XCTAssertEqual(
                typeSwitch.accessibilityIdentifier,
                expectation.identifier + ".switch"
            )
            XCTAssertEqual(
                iconView.accessibilityIdentifier,
                expectation.identifier + ".icon"
            )

            XCTAssertTrue(typeSwitch.isOn)
            XCTAssertFalse(cell.isAccessibilityElement)
            XCTAssertTrue(typeSwitch.isAccessibilityElement)
            XCTAssertEqual(typeSwitch.accessibilityLabel, cell.textLabel?.text)
            XCTAssertFalse(iconView.isAccessibilityElement)
            let renderedImage = try XCTUnwrap(iconView.image)
            let settingsImage = try XCTUnwrap(
                imageLiteral(
                    expectation.icon,
                    dimension: SettingsMenuIconMetrics.dimension
                )
            )
            XCTAssertEqual(
                renderedImage.size,
                settingsImage.size
            )
        }
    }

    @MainActor
    func testChangingNotificationTypesPersistsEachIndependentPreference() throws {
        let store = Store(boolValues: [
            "notification_message_enabled": true,
            "notification_invite_enabled": false,
            "notification_subscription_request_enabled": true
        ])
        let controller = NotificationsSettingsViewController(store: store)
        controller.loadViewIfNeeded()

        let changes: [(row: Int, identifier: String, value: Bool, key: String)] = [
            (0, "notifications.messages", false, "notification_message_enabled"),
            (1, "notifications.invites", true, "notification_invite_enabled"),
            (2, "notifications.subscriptionRequests", false, "notification_subscription_request_enabled")
        ]

        for change in changes {
            let cell = cell(from: controller, row: change.row, section: 0)
            let typeSwitch = try XCTUnwrap(cell.accessoryView as? UISwitch)
            XCTAssertEqual(
                typeSwitch.accessibilityIdentifier,
                change.identifier + ".switch"
            )
            XCTAssertEqual(
                typeSwitch.isOn,
                store.boolValues[change.key],
                "The switch must render its independently persisted initial value"
            )
            typeSwitch.setOn(change.value, animated: false)
            typeSwitch.sendActions(for: .valueChanged)
        }

        XCTAssertEqual(store.boolWrites.count, 3)
        for (index, change) in changes.enumerated() {
            XCTAssertEqual(store.boolWrites[index].key, change.key)
            XCTAssertEqual(store.boolWrites[index].value, change.value)
            XCTAssertEqual(store.boolValues[change.key], change.value)
        }
    }

    func testNotificationAlertPreferencesMapRoutesAndCategoriesIndependently() {
        let values = [
            NotificationAlertPreference.messages.rawValue: false,
            NotificationAlertPreference.invites.rawValue: true,
            NotificationAlertPreference.subscriptionRequests.rawValue: false
        ]
        let preferences = NotificationAlertPreferences { values[$0] }

        XCTAssertFalse(preferences.isEnabled(for: .message))
        XCTAssertTrue(preferences.isEnabled(for: .groupInvite))
        XCTAssertFalse(preferences.isEnabled(for: .subscriptionRequest))
        XCTAssertTrue(preferences.isEnabled(for: .verificationRequest))
        XCTAssertFalse(
            preferences.isEnabled(
                forCategoryIdentifier: PushNotificationCategory.message
            )
        )
        XCTAssertFalse(
            preferences.isEnabled(
                forCategoryIdentifier: PushNotificationCategory.pushMessage
            )
        )
        XCTAssertTrue(
            preferences.isEnabled(
                forCategoryIdentifier: PushNotificationCategory.invite
            )
        )
        XCTAssertFalse(
            preferences.isEnabled(
                forCategoryIdentifier: PushNotificationCategory.subscription
            )
        )
        XCTAssertTrue(
            preferences.isEnabled(
                forCategoryIdentifier: PushNotificationCategory.verification
            )
        )
        XCTAssertTrue(
            preferences.isEnabled(
                routeKind: .message,
                categoryIdentifier: PushNotificationCategory.invite
            ),
            "A known category must win over legacy route inference"
        )
        XCTAssertTrue(
            preferences.isEnabled(
                routeKind: .message,
                categoryIdentifier: PushNotificationCategory.verification
            ),
            "Verification alerts are outside the user-controlled types"
        )
    }

    func testMissingNotificationAlertPreferencesDefaultToEnabled() {
        let preferences = NotificationAlertPreferences { _ in nil }

        XCTAssertTrue(preferences.isEnabled(for: .message))
        XCTAssertTrue(preferences.isEnabled(for: .groupInvite))
        XCTAssertTrue(preferences.isEnabled(for: .subscriptionRequest))
    }

    @MainActor
    func testChangingInAppSoundPersistsExistingNotificationPreference() throws {
        let store = Store()
        let controller = NotificationsSettingsViewController(store: store)
        controller.loadViewIfNeeded()
        let cell = cell(from: controller, row: 0, section: 2)
        let soundSwitch = try XCTUnwrap(
            descendant(in: cell, accessibilityIdentifier: "notifications.inAppSounds.switch") as? UISwitch
        )

        soundSwitch.setOn(false, animated: false)
        soundSwitch.sendActions(for: .valueChanged)

        XCTAssertEqual(store.boolValues["notification_in_app_sound"], false)
    }

    @MainActor
    private func cell(
        from controller: NotificationsSettingsViewController,
        row: Int,
        section: Int
    ) -> UITableViewCell {
        controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: row, section: section)
        )
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
