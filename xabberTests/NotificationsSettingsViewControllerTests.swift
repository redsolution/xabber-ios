import XCTest
@testable import xabber

final class NotificationsSettingsViewControllerTests: XCTestCase {
    @MainActor
    private final class RootSettingsIconDataSource: NSObject, UITableViewDataSource {
        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            1
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "RootSettingsIcon", for: indexPath)
            cell.imageView?.image = imageLiteral(
                "custom.bell.square.fill",
                dimension: SettingsMenuIconMetrics.dimension
            )
            cell.tintColor = .systemGreen
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    private final class Store: NotificationsSettingsStoring {
        var boolValues: [String: Bool]
        private(set) var boolWrites: [(key: String, value: Bool)] = []

        init(boolValues: [String: Bool] = [
            "notification_in_app_sound": true,
            "notification_in_app_alert_last_chats": false
        ]) {
            self.boolValues = boolValues
        }

        func bool(for key: String, default defaultValue: Bool) -> Bool {
            boolValues[key] ?? defaultValue
        }

        func setBool(_ value: Bool, for key: String) {
            boolValues[key] = value
            boolWrites.append((key: key, value: value))
        }
    }

    @MainActor
    func testNotificationsSettingsShowsTypeInAppAndSystemActionSections() throws {
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
        let inAppSoundCell = cell(from: controller, row: 0, section: 1)
        let systemSettingsCell = cell(from: controller, row: 0, section: 3)

        XCTAssertEqual(messagesCell.accessibilityIdentifier, "notifications.messages")
        XCTAssertEqual(invitesCell.accessibilityIdentifier, "notifications.invites")
        XCTAssertEqual(subscriptionRequestsCell.accessibilityIdentifier, "notifications.subscriptionRequests")
        XCTAssertEqual(inAppSoundCell.accessibilityIdentifier, "notifications.inAppSounds")
        XCTAssertEqual(systemSettingsCell.accessibilityIdentifier, "notifications.systemSettings")
        XCTAssertEqual(
            controller.tableView(controller.tableView, titleForHeaderInSection: 0),
            "Notification Sounds"
        )
        XCTAssertEqual(
            controller.tableView(controller.tableView, titleForFooterInSection: 0),
            "Turn sounds on or off independently for each notification type."
        )
    }

    @MainActor
    func testNotificationTypeSwitchesDefaultOnAndUseSettingsSizedIcons() throws {
        let controller = NotificationsSettingsViewController(store: Store())
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.tableView.reloadData()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let rootSettingsDataSource = RootSettingsIconDataSource()
        let rootSettingsTable = UITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 200),
            style: .insetGrouped
        )
        rootSettingsTable.register(UITableViewCell.self, forCellReuseIdentifier: "RootSettingsIcon")
        rootSettingsTable.dataSource = rootSettingsDataSource
        rootSettingsTable.reloadData()
        rootSettingsTable.layoutIfNeeded()
        let rootSettingsCell = try XCTUnwrap(
            rootSettingsTable.cellForRow(at: IndexPath(row: 0, section: 0))
        )
        let rootSettingsIconView = try XCTUnwrap(rootSettingsCell.imageView)
        XCTAssertNotNil(rootSettingsIconView.image)

        let expectations: [(row: Int, identifier: String, icon: String)] = [
            (0, "notifications.messages", "custom.bubble.square.fill"),
            (1, "notifications.invites", "xabber.invite.square.fill"),
            (2, "notifications.subscriptionRequests", "xabber.person.plus.square.fill")
        ]

        XCTAssertEqual(SettingsMenuIconMetrics.dimension, 24)
        for expectation in expectations {
            let cell = try XCTUnwrap(
                controller.tableView.cellForRow(
                    at: IndexPath(row: expectation.row, section: 0)
                )
            )
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
            XCTAssertEqual(
                typeSwitch.accessibilityLabel,
                "\(cell.textLabel?.text ?? "") Notification Sound"
            )
            XCTAssertFalse(iconView.isAccessibilityElement)
            XCTAssertNotNil(iconView.image)
            XCTAssertEqual(
                iconView.contentMode,
                rootSettingsIconView.contentMode,
                "Notification rows must preserve the root Settings image-view rendering mode"
            )
            XCTAssertEqual(
                iconView.bounds.width,
                rootSettingsIconView.bounds.width,
                accuracy: 1 / UIScreen.main.scale,
                "Notification rows must lay out the icon at the same size as root Settings"
            )
            let renderedImage = try XCTUnwrap(
                iconView.image,
                "The notification icon must render visible pixels"
            )
            XCTAssertGreaterThan(renderedImage.size.width, SettingsMenuIconMetrics.dimension)
            XCTAssertEqual(
                iconView.bounds.height,
                rootSettingsIconView.bounds.height,
                accuracy: 1 / UIScreen.main.scale,
                "Notification icons must have the same visible coloured-square footprint as root Settings"
            )
        }
    }

    @MainActor
    func testSystemSettingsIsLeftAlignedButtonSectionWithoutHeaderIconOrDisclosureIndicator() throws {
        let controller = NotificationsSettingsViewController(store: Store())
        controller.loadViewIfNeeded()
        let systemCell = cell(from: controller, row: 0, section: 3)
        systemCell.bounds = CGRect(x: 0, y: 0, width: 390, height: 60)
        systemCell.setNeedsLayout()
        systemCell.layoutIfNeeded()

        XCTAssertNil(
            controller.tableView(controller.tableView, titleForHeaderInSection: 3)
        )
        XCTAssertEqual(systemCell.textLabel?.text, "Open iOS Notification Settings")
        XCTAssertEqual(systemCell.textLabel?.textAlignment, .left)
        XCTAssertEqual(systemCell.accessoryType, .none)
        XCTAssertNil(systemCell.accessoryView)
        XCTAssertNil(systemCell.imageView?.image)
        XCTAssertNil(
            descendant(
                in: systemCell,
                accessibilityIdentifier: "notifications.systemSettings.icon"
            )
        )
        XCTAssertTrue(systemCell.accessibilityTraits.contains(.button))
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

    func testNotificationSoundPreferencesMapRoutesAndCategoriesIndependently() {
        let values = [
            NotificationSoundPreference.messages.rawValue: false,
            NotificationSoundPreference.invites.rawValue: true,
            NotificationSoundPreference.subscriptionRequests.rawValue: false
        ]
        let preferences = NotificationSoundPreferences { values[$0] }

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

    func testMissingNotificationSoundPreferencesDefaultToEnabled() {
        let preferences = NotificationSoundPreferences { _ in nil }

        XCTAssertTrue(preferences.isEnabled(for: .message))
        XCTAssertTrue(preferences.isEnabled(for: .groupInvite))
        XCTAssertTrue(preferences.isEnabled(for: .subscriptionRequest))
    }

    func testForegroundPresentationKeepsBannerWhenTypeSoundIsDisabled() {
        XCTAssertEqual(
            NotificationForegroundPresentationPolicy.options(
                showsBanner: true,
                playsSound: false
            ),
            [.banner]
        )
        XCTAssertEqual(
            NotificationForegroundPresentationPolicy.options(
                showsBanner: true,
                playsSound: true
            ),
            [.banner, .sound]
        )
        XCTAssertEqual(
            NotificationForegroundPresentationPolicy.options(
                showsBanner: false,
                playsSound: true
            ),
            []
        )
    }

    @MainActor
    func testChangingInAppSoundPersistsExistingNotificationPreference() throws {
        let store = Store()
        let controller = NotificationsSettingsViewController(store: store)
        controller.loadViewIfNeeded()
        let cell = cell(from: controller, row: 0, section: 1)
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
