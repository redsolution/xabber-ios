import XCTest
import UIKit
@testable import xabber

final class NotificationsPushPayloadModeTests: XCTestCase {
    private final class SoundStore: NotificationsSettingsStoring {
        private(set) var writes: [(String, Bool)] = []

        func bool(for key: String, default defaultValue: Bool) -> Bool {
            defaultValue
        }

        func setBool(_ value: Bool, for key: String) {
            writes.append((key, value))
        }
    }

    private final class ModeStore {
        var value: PushPayloadMode
        private(set) var writes: [PushPayloadMode] = []

        init(_ value: PushPayloadMode) {
            self.value = value
        }

        func set(_ value: PushPayloadMode) {
            self.value = value
            writes.append(value)
        }
    }

    @MainActor
    func testPayloadChoicesExposeFullAndPartialWithoutReplacingExistingSettings() throws {
        let controller = NotificationsSettingsViewController(store: SoundStore())
        controller.loadViewIfNeeded()

        let cells = allCells(in: controller)
        let payloadCells = cells.filter {
            $0.accessibilityIdentifier?.hasPrefix("notifications.payloadMode.") == true
        }

        XCTAssertEqual(payloadCells.map(\.accessibilityIdentifier), [
            "notifications.payloadMode.full",
            "notifications.payloadMode.partial"
        ])
        for identifier in [
            "notifications.messages", "notifications.invites",
            "notifications.subscriptionRequests", "notifications.inAppSounds",
            "notifications.bannersOnChats", "notifications.systemSettings"
        ] {
            XCTAssertEqual(cells.filter { $0.accessibilityIdentifier == identifier }.count, 1)
        }
    }

    @MainActor
    func testExactlyOnePayloadChoiceIsSelectedAndVoiceOverIdentifiesBothChoices() throws {
        let controller = NotificationsSettingsViewController(store: SoundStore())
        controller.loadViewIfNeeded()
        let full = try choiceCell(in: controller, identifier: "notifications.payloadMode.full")
        let partial = try choiceCell(in: controller, identifier: "notifications.payloadMode.partial")

        XCTAssertEqual([full, partial].filter { $0.accessoryType == .checkmark }.count, 1)
        for cell in [full, partial] {
            XCTAssertTrue(cell.isAccessibilityElement)
            XCTAssertFalse(cell.accessibilityLabel?.isEmpty ?? true)
            XCTAssertTrue(cell.accessibilityTraits.contains(.button))
            XCTAssertEqual(cell.accessibilityTraits.contains(.selected), cell.accessoryType == .checkmark)
        }
    }

    @MainActor
    func testPayloadChoicesUseWrappingDynamicTypeLabels() throws {
        let controller = NotificationsSettingsViewController(store: SoundStore())
        controller.loadViewIfNeeded()

        for identifier in ["notifications.payloadMode.full", "notifications.payloadMode.partial"] {
            let cell = try choiceCell(in: controller, identifier: identifier)
            let label = try XCTUnwrap(cell.textLabel)
            XCTAssertTrue(label.adjustsFontForContentSizeCategory)
            XCTAssertEqual(label.numberOfLines, 0)
        }
    }

    @MainActor
    func testSummaryPreferenceSelectsPartialAndFullPreferenceSelectsFull() throws {
        for mode in [PushPayloadMode.summary, .full] {
            let controller = makeController(mode: ModeStore(mode))
            controller.loadViewIfNeeded()

            let full = try choiceCell(in: controller, identifier: "notifications.payloadMode.full")
            let partial = try choiceCell(in: controller, identifier: "notifications.payloadMode.partial")
            XCTAssertEqual(full.accessoryType, mode == .full ? .checkmark : .none)
            XCTAssertEqual(partial.accessoryType, mode == .summary ? .checkmark : .none)
            XCTAssertEqual(full.textLabel?.text, L10n.text("notifications_settings__payload_mode__full", fallback: "Full"))
            XCTAssertEqual(partial.textLabel?.text, L10n.text("notifications_settings__payload_mode__partial", fallback: "Partial"))
        }
    }

    @MainActor
    func testSelectingPayloadModesPublishesTypedPreferenceOnceAndKeepsSoundSettingsIndependent() throws {
        let modes = ModeStore(.summary)
        let sounds = SoundStore()
        let controller = makeController(mode: modes, sounds: sounds)
        controller.loadViewIfNeeded()

        try select("notifications.payloadMode.full", in: controller)

        XCTAssertEqual(modes.writes, [.full])
        XCTAssertEqual(try choiceCell(in: controller, identifier: "notifications.payloadMode.full").accessoryType, .checkmark)
        XCTAssertEqual(try choiceCell(in: controller, identifier: "notifications.payloadMode.partial").accessoryType, .none)
        XCTAssertTrue(sounds.writes.isEmpty)

        try select("notifications.payloadMode.partial", in: controller)

        XCTAssertEqual(modes.writes, [.full, .summary])
        XCTAssertEqual(try choiceCell(in: controller, identifier: "notifications.payloadMode.partial").accessoryType, .checkmark)
        XCTAssertEqual(try choiceCell(in: controller, identifier: "notifications.payloadMode.full").accessoryType, .none)
        XCTAssertTrue(sounds.writes.isEmpty)
    }

    @MainActor
    func testSelectingCurrentPayloadModeDoesNotPublishAnotherPreferenceChange() throws {
        for (mode, identifier) in [(PushPayloadMode.full, "notifications.payloadMode.full"), (.summary, "notifications.payloadMode.partial")] {
            let modes = ModeStore(mode)
            let controller = makeController(mode: modes)
            controller.loadViewIfNeeded()

            try select(identifier, in: controller)
            try select(identifier, in: controller)

            XCTAssertTrue(modes.writes.isEmpty)
            XCTAssertEqual(try choiceCell(in: controller, identifier: identifier).accessoryType, .checkmark)
        }
    }

    @MainActor
    func testReturningToSettingsReadsChangedPreferenceInsteadOfRetainingOldSelection() throws {
        let modes = ModeStore(.summary)
        let controller = makeController(mode: modes)
        controller.loadViewIfNeeded()
        XCTAssertEqual(try choiceCell(in: controller, identifier: "notifications.payloadMode.partial").accessoryType, .checkmark)

        modes.value = .full
        controller.viewWillAppear(false)

        XCTAssertEqual(try choiceCell(in: controller, identifier: "notifications.payloadMode.full").accessoryType, .checkmark)
        XCTAssertEqual(try choiceCell(in: controller, identifier: "notifications.payloadMode.partial").accessoryType, .none)
    }

    @MainActor
    func testRecreatedSettingsReadsDurablyStoredSummaryWireValueAsPartial() throws {
        let suiteName = "tests.notifications.payload-mode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "notification_push_payload_mode"
        defaults.set(PushPayloadMode.full.rawValue, forKey: key)
        let controller = NotificationsSettingsViewController(
            store: SoundStore(),
            payloadModeProvider: { PushPayloadMode(rawValue: defaults.string(forKey: key) ?? "") ?? .summary },
            payloadModeSetter: { defaults.set($0.rawValue, forKey: key) }
        )
        controller.loadViewIfNeeded()

        try select("notifications.payloadMode.partial", in: controller)

        XCTAssertEqual(defaults.string(forKey: key), "summary")
        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let reopened = NotificationsSettingsViewController(
            store: SoundStore(),
            payloadModeProvider: { PushPayloadMode(rawValue: reopenedDefaults.string(forKey: key) ?? "") ?? .summary },
            payloadModeSetter: { reopenedDefaults.set($0.rawValue, forKey: key) }
        )
        reopened.loadViewIfNeeded()
        XCTAssertEqual(try choiceCell(in: reopened, identifier: "notifications.payloadMode.partial").accessoryType, .checkmark)
        XCTAssertEqual(try choiceCell(in: reopened, identifier: "notifications.payloadMode.full").accessoryType, .none)
    }

    @MainActor
    private func makeController(mode: ModeStore, sounds: SoundStore = SoundStore()) -> NotificationsSettingsViewController {
        NotificationsSettingsViewController(
            store: sounds,
            payloadModeProvider: { mode.value },
            payloadModeSetter: { mode.set($0) }
        )
    }

    @MainActor
    private func select(_ identifier: String, in controller: NotificationsSettingsViewController) throws {
        let sections = 0..<controller.numberOfSections(in: controller.tableView)
        let indexPaths = sections.flatMap { section in
            (0..<controller.tableView(controller.tableView, numberOfRowsInSection: section)).map { row in
                IndexPath(row: row, section: section)
            }
        }
        let indexPath = try XCTUnwrap(indexPaths.first {
            controller.tableView(controller.tableView, cellForRowAt: $0).accessibilityIdentifier == identifier
        })
        controller.tableView(controller.tableView, didSelectRowAt: indexPath)
    }

    @MainActor
    private func allCells(in controller: NotificationsSettingsViewController) -> [UITableViewCell] {
        (0..<controller.numberOfSections(in: controller.tableView)).flatMap { section in
            (0..<controller.tableView(controller.tableView, numberOfRowsInSection: section)).map { row in
                controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: row, section: section))
            }
        }
    }

    @MainActor
    private func choiceCell(in controller: NotificationsSettingsViewController, identifier: String) throws -> UITableViewCell {
        try XCTUnwrap(allCells(in: controller).first { $0.accessibilityIdentifier == identifier })
    }
}
