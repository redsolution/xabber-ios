//
//  LanguageSettingsViewControllerTests.swift
//  xabberTests
//

import XCTest
import UIKit
@testable import xabber

final class LanguageSettingsViewControllerTests: XCTestCase {
    func testRowsExposeSystemAndExactlySixSupportedLanguagesInProductOrder() {
        let rows = LanguageSettingsRow.makeRows(systemTitle: "System")

        XCTAssertEqual(
            rows.map(\.selection),
            [
                .system,
                .fixed(.english),
                .fixed(.russian),
                .fixed(.french),
                .fixed(.spanish),
                .fixed(.arabic),
                .fixed(.simplifiedChinese)
            ]
        )
        XCTAssertEqual(
            rows.map(\.title),
            ["System", "English", "Русский", "Français", "Español", "العربية", "简体中文"]
        )
        XCTAssertEqual(
            rows.map(\.accessibilityIdentifier),
            [
                "settings.language.system",
                "settings.language.en",
                "settings.language.ru",
                "settings.language.fr",
                "settings.language.es",
                "settings.language.ar",
                "settings.language.zh-Hans"
            ]
        )
    }

    func testSystemRowRemainsSelectedWhenEffectiveLanguageIsEnglish() {
        let controller = makeController(selection: .system)
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 0), 7)
        XCTAssertEqual(
            cell(in: controller, row: 0).accessoryType,
            .checkmark
        )
        XCTAssertEqual(
            cell(in: controller, row: 1).accessoryType,
            .none
        )
    }

    func testEveryLanguageCellHasStableAccessibilityIdentityAndSelectedTrait() {
        let controller = makeController(selection: .fixed(.arabic))
        controller.loadViewIfNeeded()

        for row in 0..<controller.tableView.numberOfRows(inSection: 0) {
            let cell = cell(in: controller, row: row)
            XCTAssertEqual(cell.accessibilityIdentifier, controller.rows[row].accessibilityIdentifier)
            XCTAssertEqual(
                cell.accessibilityTraits.contains(.selected),
                controller.rows[row].selection == .fixed(.arabic)
            )
        }
    }

    func testSelectingDifferentLanguageAppliesTypedSelectionOnce() {
        var appliedSelections: [AppLanguageSelection] = []
        let controller = makeController(selection: .system) { selection, _ in
            appliedSelections.append(selection)
            return true
        }
        controller.loadViewIfNeeded()

        controller.tableView(
            controller.tableView,
            didSelectRowAt: IndexPath(row: 2, section: 0)
        )

        XCTAssertEqual(appliedSelections, [.fixed(.russian)])
    }

    func testSelectingCurrentLanguageDoesNotReapplyOrRebuild() {
        var applicationCount = 0
        let controller = makeController(selection: .fixed(.french)) { _, _ in
            applicationCount += 1
            return true
        }
        controller.loadViewIfNeeded()

        controller.tableView(
            controller.tableView,
            didSelectRowAt: IndexPath(row: 3, section: 0)
        )

        XCTAssertEqual(applicationCount, 0)
    }

    func testFailedApplicationKeepsOriginalCheckmark() {
        let controller = makeController(selection: .fixed(.spanish)) { _, _ in false }
        controller.loadViewIfNeeded()

        controller.tableView(
            controller.tableView,
            didSelectRowAt: IndexPath(row: 5, section: 0)
        )

        XCTAssertEqual(
            cell(in: controller, row: 4).accessoryType,
            .checkmark
        )
        XCTAssertEqual(
            cell(in: controller, row: 5).accessoryType,
            .none
        )
    }

    func testUIKitDirectionMapsOnlyArabicToRightToLeft() {
        XCTAssertEqual(
            LocalizationUIKitDirection.semanticAttribute(for: .leftToRight),
            .forceLeftToRight
        )
        XCTAssertEqual(
            LocalizationUIKitDirection.semanticAttribute(for: .rightToLeft),
            .forceRightToLeft
        )
    }

    func testUIKitDirectionAppliesToWindowAndRootView() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = UIViewController()

        LocalizationUIKitDirection.apply(directionContext(.arabic), to: window)
        XCTAssertEqual(window.semanticContentAttribute, .forceRightToLeft)
        XCTAssertEqual(
            window.rootViewController?.view.semanticContentAttribute,
            .forceRightToLeft
        )

        LocalizationUIKitDirection.apply(directionContext(.english), to: window)
        XCTAssertEqual(window.semanticContentAttribute, .forceLeftToRight)
        XCTAssertEqual(
            window.rootViewController?.view.semanticContentAttribute,
            .forceLeftToRight
        )
    }

    private func makeController(
        selection: AppLanguageSelection,
        apply: @escaping LanguageSettingsViewController.SelectionApplier = { _, _ in true }
    ) -> LanguageSettingsViewController {
        LanguageSettingsViewController(
            selectionProvider: { selection },
            selectionApplier: apply,
            systemTitleProvider: { "System" }
        )
    }

    private func cell(
        in controller: LanguageSettingsViewController,
        row: Int
    ) -> UITableViewCell {
        controller.tableView(
            controller.tableView,
            cellForRowAt: IndexPath(row: row, section: 0)
        )
    }

    private func directionContext(_ language: SupportedLanguage) -> LocalizationContext {
        let locale = language.locale(basedOn: Locale(identifier: "en_US"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        return LocalizationContext(
            selection: .fixed(language),
            resolvedLanguage: language,
            source: .fixed,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone,
            localizedBundle: Bundle(),
            englishBundle: Bundle(),
            layoutDirection: language.layoutDirection,
            revision: 1
        )
    }
}

final class LocalizationApplicationCoordinatorTests: XCTestCase {
    func testRepeatedSelectionDoesNotSaveRefreshOrRebuild() {
        var events: [String] = []
        let coordinator = LocalizationApplicationCoordinator(
            selectionProvider: { .fixed(.french) },
            selectionSaver: { _ in
                events.append("save")
                return true
            },
            dependentStateRefresher: { events.append("refresh") },
            rootRebuilder: { _ in events.append("rebuild") }
        )

        XCTAssertTrue(
            coordinator.apply(
                selection: .fixed(.french),
                sourceWindow: nil
            )
        )
        XCTAssertTrue(events.isEmpty)
    }

    func testSuccessfulSelectionAppliesInRequiredOrderAndReopensSourceScene() {
        var events: [String] = []
        let window = UIWindow(frame: .zero)
        let coordinator = LocalizationApplicationCoordinator(
            selectionProvider: { .system },
            selectionSaver: { selection in
                XCTAssertEqual(selection, .fixed(.arabic))
                events.append("save")
                return true
            },
            dependentStateRefresher: { events.append("refresh") },
            rootRebuilder: { sourceWindow in
                XCTAssertTrue(sourceWindow === window)
                events.append("rebuild")
            }
        )

        XCTAssertTrue(
            coordinator.apply(
                selection: .fixed(.arabic),
                sourceWindow: window
            )
        )
        XCTAssertEqual(events, ["save", "refresh", "rebuild"])
    }

    func testFailedPersistenceDoesNotRefreshOrRebuild() {
        var events: [String] = []
        let coordinator = LocalizationApplicationCoordinator(
            selectionProvider: { .system },
            selectionSaver: { _ in
                events.append("save")
                return false
            },
            dependentStateRefresher: { events.append("refresh") },
            rootRebuilder: { _ in events.append("rebuild") }
        )

        XCTAssertFalse(
            coordinator.apply(
                selection: .fixed(.spanish),
                sourceWindow: nil
            )
        )
        XCTAssertEqual(events, ["save"])
    }
}
