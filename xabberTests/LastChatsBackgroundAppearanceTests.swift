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

    func testRecentChatsTitleUsesBottomBarGlassPillAndUpdatesInPlace() throws {
        let controller = LastChatsViewController()
        controller.loadViewIfNeeded()
        let pill = try XCTUnwrap(controller.navigationItem.titleView as? NavigationTitlePillView)
        controller.updateTitle(controller.filter.value)
        XCTAssertTrue(controller.navigationItem.titleView === pill)
        XCTAssertEqual(pill.accessibilityLabel, controller.title)
        XCTAssertNotNil(pill.subviews.first { $0 is UIVisualEffectView })
        XCTAssertGreaterThanOrEqual(pill.intrinsicContentSize.height, 42)
        if #available(iOS 26.0, *) {
            XCTAssertTrue(controller.tableView.topEdgeEffect.isHidden)
        }
    }

    func testTitlePillUsesBottomPillWidthWithNavigationRoom() {
        XCTAssertEqual(NavigationTitlePillSizing.width(columnWidth: 393, bottomPillWidth: 257), 257)
        XCTAssertEqual(NavigationTitlePillSizing.width(columnWidth: 700, bottomPillWidth: 560), 560)
        XCTAssertEqual(NavigationTitlePillSizing.width(columnWidth: 240, bottomPillWidth: 180), 128)
    }

    func testNavigationShadowsCanCrossColumnBoundaryWithoutUnclippingScrollContent() {
        let splitHost = UIView()
        let column = UIView()
        let navigationHost = UIView()
        let bar = UINavigationBar()
        let list = UITableView()
        splitHost.addSubview(column)
        column.addSubview(navigationHost)
        navigationHost.addSubview(bar)
        navigationHost.addSubview(list)
        for view in [splitHost, column, navigationHost, bar] { view.clipsToBounds = true }
        list.clipsToBounds = true
        ContinuousSplitNavigationShadowPolicy.allowOverflow(from: bar, through: splitHost)
        for view in [splitHost, column, navigationHost, bar] { XCTAssertFalse(view.clipsToBounds) }
        XCTAssertTrue(list.clipsToBounds)
    }

    func testShadowClippingRestoresOriginalValuesForCompactLayout() {
        let root = UIView()
        let column = UIView()
        let bar = UINavigationBar()
        root.addSubview(column)
        column.addSubview(bar)
        root.clipsToBounds = false
        column.clipsToBounds = true
        bar.clipsToBounds = false
        ContinuousSplitNavigationShadowPolicy.allowOverflow(from: bar, through: root)
        ContinuousSplitNavigationShadowPolicy.allowOverflow(from: bar, through: root)
        ContinuousSplitNavigationShadowPolicy.restoreClipping(in: root)
        XCTAssertFalse(root.clipsToBounds)
        XCTAssertTrue(column.clipsToBounds)
        XCTAssertFalse(bar.clipsToBounds)
    }

    func testSharedBackdropHidesOnlyBoundaryDividerOutsideContentAndRestoresIt() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let left = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        let right = UIView(frame: CGRect(x: 300, y: 0, width: 500, height: 600))
        let divider = UIView(frame: CGRect(x: 299.5, y: 0, width: 1, height: 600))
        let contentLine = UIView(frame: CGRect(x: 299, y: 0, width: 1, height: 600))
        root.addSubview(left)
        root.addSubview(right)
        root.addSubview(divider)
        left.addSubview(contentLine)
        ContinuousSplitNavigationShadowPolicy.hideBoundaryDividers(in: root, columnViews: [left, right])
        XCTAssertTrue(divider.isHidden)
        XCTAssertFalse(contentLine.isHidden)
        XCTAssertFalse(left.isHidden)
        XCTAssertFalse(right.isHidden)
        ContinuousSplitNavigationShadowPolicy.restoreClipping(in: root)
        XCTAssertFalse(divider.isHidden)
    }

    func testShadowPolicyDoesNotModifyUnrelatedViewTrees() {
        let bar = UINavigationBar()
        let unrelatedRoot = UIView()
        bar.clipsToBounds = true
        ContinuousSplitNavigationShadowPolicy.allowOverflow(from: bar, through: unrelatedRoot)
        XCTAssertTrue(bar.clipsToBounds)
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
