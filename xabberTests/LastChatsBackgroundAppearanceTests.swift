import XCTest
import UIKit
import RealmSwift
@testable import xabber

@MainActor
final class LastChatsBackgroundAppearanceTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private var previousInterfaceType: String!

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        previousInterfaceType = CommonConfigManager.shared.config.interface_type
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "LastChatsBackgroundAppearanceTests-\(UUID().uuidString)"
        )
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.tabs.rawValue
    }

    override func tearDown() {
        CommonConfigManager.shared.config.interface_type = previousInterfaceType
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        previousInterfaceType = nil
        super.tearDown()
    }

    func testRecentChatsRendersActiveChatWallpaperBehindTransparentTable() throws {
        let controller = LastChatsViewController()
        controller.loadViewIfNeeded()

        let backdrop = try XCTUnwrap(controller.tableView.backgroundView as? ChatBackgroundBackdropView)

        XCTAssertEqual(backdrop.representedWallpaper, activeWallpaper)
        XCTAssertEqual(controller.tableView.backgroundColor, .clear)
        XCTAssertFalse(controller.tableView.isOpaque)
    }

    func testEmptyListKeepsChatWallpaperVisible() {
        let controller = LastChatsViewController()
        controller.loadViewIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
        }

        XCTAssertNotNil(controller.tableView.backgroundView as? ChatBackgroundBackdropView)
        XCTAssertEqual(controller.emptyView.backgroundColor, .clear)
        XCTAssertFalse(controller.emptyView.isOpaque)
    }

    func testWallpaperNotificationRefreshesExistingBackdropFromActiveAppearance() throws {
        let controller = LastChatsViewController()
        controller.loadViewIfNeeded()
        let backdrop = try XCTUnwrap(controller.tableView.backgroundView as? ChatBackgroundBackdropView)
        var preview = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
        preview.profile.wallpaper = .gradient(
            stops: [AppearanceColor(hex: "#123456")!], pattern: nil, intensity: 0
        )
        backdrop.configure(document: preview)
        XCTAssertEqual(backdrop.representedWallpaper, preview.profile.wallpaper)

        NotificationCenter.default.post(name: .chatBackgroundChanged, object: nil)

        XCTAssertTrue(controller.tableView.backgroundView === backdrop)
        XCTAssertEqual(backdrop.representedWallpaper, activeWallpaper)
    }

    func testRepeatedAppearanceAndLayoutKeepWallpaperAndTransparentSurfaces() throws {
        let controller = LastChatsViewController()
        controller.loadViewIfNeeded()
        let backdrop = try XCTUnwrap(controller.tableView.backgroundView as? ChatBackgroundBackdropView)

        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        for appearing in [true, false, true] {
            controller.beginAppearanceTransition(appearing, animated: false)
            controller.endAppearanceTransition()
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
        }

        XCTAssertTrue(controller.tableView.backgroundView === backdrop)
        XCTAssertEqual(controller.tableView.backgroundColor, .clear)
        XCTAssertFalse(controller.tableView.isOpaque)
        XCTAssertEqual(controller.emptyView.backgroundColor, .clear)
    }

    func testArchivedChatsUsesTheSameActiveWallpaper() throws {
        let controller = LastChatsViewController()
        controller.archivedMode = true
        controller.loadViewIfNeeded()

        let backdrop = try XCTUnwrap(controller.tableView.backgroundView as? ChatBackgroundBackdropView)

        XCTAssertEqual(backdrop.representedWallpaper, activeWallpaper)
        XCTAssertEqual(controller.tableView.backgroundColor, .clear)
    }

    func testSectionListsAndCategoriesUseActiveWallpaper() throws {
        let contacts = ContactsViewController()
        let calls = LastCallsViewController()
        let notifications = NotificationsListViewController()
        let contactsCategories = ContactsCategoryViewController()
        let callsCategories = CallsCategoriesViewController()
        let notificationsCategories = NotificationsCategoriesViewController()
        let sections: [(UIViewController, () -> UITableView)] = [
            (contacts, { contacts.tableView }),
            (calls, { calls.tableView }),
            (notifications, { notifications.tableView }),
            (contactsCategories, { contactsCategories.tableView }),
            (callsCategories, { callsCategories.tableView }),
            (notificationsCategories, { notificationsCategories.tableView })
        ]
        for (controller, table) in sections {
            controller.loadViewIfNeeded()
            let backdrop = try XCTUnwrap(table().backgroundView as? ChatBackgroundBackdropView,
                                        "Missing wallpaper for \(type(of: controller))")
            XCTAssertEqual(backdrop.representedWallpaper, activeWallpaper)
            XCTAssertEqual(table().backgroundColor, .clear)
            XCTAssertFalse(table().isOpaque)
            var preview = AppearanceSettingsDocument(profile: .default(accent: .systemBlue))
            preview.profile.wallpaper = .gradient(stops: [AppearanceColor(hex: "#123456")!], pattern: nil, intensity: 0)
            backdrop.configure(document: preview)
            NotificationCenter.default.post(name: .chatBackgroundChanged, object: nil)
            XCTAssertEqual(backdrop.representedWallpaper, activeWallpaper)
            controller.beginAppearanceTransition(true, animated: false)
            controller.endAppearanceTransition()
            controller.view.layoutIfNeeded()
            XCTAssertTrue(table().backgroundView === backdrop)
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
        }
        for empty in [contacts.emptyView, calls.emptyView, notifications.emptyView] {
            XCTAssertEqual(empty.backgroundColor, .clear)
            XCTAssertFalse(empty.isOpaque)
        }
    }

    private var activeWallpaper: AppearanceWallpaper {
        AppearanceSettingsStore()?.load().profile.wallpaper
            ?? AppearanceProfile.default(accent: .systemBlue).wallpaper
    }
}
