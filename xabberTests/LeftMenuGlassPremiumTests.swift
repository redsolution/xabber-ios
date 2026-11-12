import XCTest
import UIKit
import RealmSwift
@testable import xabber

@MainActor
final class LeftMenuGlassPremiumTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private var retainedRealm: Realm?
    private var previousSubscriptionsEnabled = false
    private var previousLocalizationContext: LocalizationContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "LeftMenuGlassPremiumTests-\(UUID().uuidString)"
        )
        retainedRealm = try WRealm.safe()
        previousSubscriptionsEnabled = CommonConfigManager.shared.config.support_subscribtions
        CommonConfigManager.shared.config.support_subscribtions = true
        previousLocalizationContext = LocalizationRuntime.shared.context
        selectLanguage(.english)
    }

    override func tearDownWithError() throws {
        LocalizationRuntime.shared.replaceContext(previousLocalizationContext)
        CommonConfigManager.shared.config.support_subscribtions = previousSubscriptionsEnabled
        retainedRealm = nil
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        try super.tearDownWithError()
    }

    func testAllOrdinaryActionsShareOneSectionBeforeTheSeparatePremiumSection() throws {
        let controller = makeMenu()

        let premium = try premiumIndexPath(in: controller)

        XCTAssertEqual(premium, IndexPath(row: 0, section: 1))
        XCTAssertEqual(controller.datasource[premium.section].count, 1)
        XCTAssertEqual(controller.datasource[premium.section][premium.row].title, "Xabber Premium")
        XCTAssertEqual(controller.datasource[0].first?.key, "chat")
        XCTAssertEqual(controller.datasource[0].last?.key, "settings")
    }

    func testPremiumSectionIsAbsentWhenSubscriptionsAreDisabled() {
        CommonConfigManager.shared.config.support_subscribtions = false

        let controller = makeMenu()

        XCTAssertFalse(controller.datasource.flatMap { $0 }.contains { $0.key == "premium" })
        XCTAssertEqual(controller.datasource.count, 1)
        XCTAssertEqual(controller.datasource[0].first?.key, "chat")
        XCTAssertEqual(controller.datasource[0].last?.key, "settings")
    }

    func testPremiumCellHasGoldenStarLocalizedMultilineCopyAndAccessibleAction() throws {
        let controller = makeMenu()
        let path = try premiumIndexPath(in: controller)

        let cell = controller.tableView(controller.tableView, cellForRowAt: path)
        let title = try XCTUnwrap(labels(in: cell).first { $0.text == "Xabber Premium" })
        let description = try XCTUnwrap(labels(in: cell).first { $0.text == premiumDescription })
        let background = try XCTUnwrap(cell.backgroundConfiguration)
        let goldenIcons = descendants(of: cell).compactMap { $0 as? UIImageView }
            .filter { $0.image != nil && $0.tintColor == .systemYellow }

        XCTAssertFalse(premiumDescription.isEmpty)
        XCTAssertTrue(description.numberOfLines == 0 || description.numberOfLines >= 3)
        XCTAssertNotNil(background.visualEffect)
        XCTAssertTrue(title.isDescendant(of: cell.contentView))
        XCTAssertTrue(description.isDescendant(of: cell.contentView))
        XCTAssertEqual(goldenIcons.count, 1)
        XCTAssertEqual(cell.accessibilityIdentifier, "left_menu_premium_row")
        XCTAssertTrue(cell.isAccessibilityElement)
        XCTAssertTrue(cell.accessibilityTraits.contains(.button))
        XCTAssertTrue(cell.accessibilityLabel?.contains("Xabber Premium") == true)
        XCTAssertTrue(cell.accessibilityLabel?.contains(premiumDescription) == true)
    }

    func testPremiumUsesSystemInsetGroupedBackgroundWithoutCustomCornerGeometry() throws {
        let controller = makeMenu()
        let path = try premiumIndexPath(in: controller)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        controller.tableView.reloadData()
        window.layoutIfNeeded()
        controller.tableView.scrollToRow(at: path, at: .none, animated: false)
        window.layoutIfNeeded()
        let cell = try XCTUnwrap(controller.tableView.cellForRow(at: path) as? LeftMenuGlassTableViewCell)
        let background = try XCTUnwrap(cell.backgroundConfiguration)
        var systemBackground: UIBackgroundConfiguration
        if #available(iOS 18.0, *) {
            systemBackground = .listCell()
        } else {
            systemBackground = .listGroupedCell()
        }
        systemBackground = systemBackground.updated(for: cell.configurationState)

        XCTAssertTrue(cell.window === window)
        XCTAssertEqual(controller.tableView.style, .insetGrouped)
        XCTAssertEqual(background.cornerRadius, systemBackground.cornerRadius)
        XCTAssertEqual(background.backgroundInsets, systemBackground.backgroundInsets)
        XCTAssertNil(background.customView)
        XCTAssertNotNil(background.visualEffect)
        XCTAssertNil(cell.glassSurfaceView.effect)
        XCTAssertEqual(cell.glassSurfaceView.layer.cornerRadius, 0)
        if #available(iOS 26.0, *) {
            XCTAssertEqual(cell.glassSurfaceView.cornerConfiguration, UIVisualEffectView(effect: nil).cornerConfiguration)
            let glass = try XCTUnwrap(background.visualEffect as? UIGlassEffect)
            XCTAssertFalse(glass.isInteractive)
            XCTAssertNil(glass.tintColor)
        } else {
            XCTAssertTrue(background.visualEffect is UIBlurEffect)
        }
    }

    func testOrdinaryRowsShareOneNativeGlassBackdropAndKeepTheirOwnBackgroundsTransparent() throws {
        let controller = makeMenu()
        controller.tableView.reloadData()
        controller.view.layoutIfNeeded()
        controller.tableView.layoutIfNeeded()
        controller.viewDidLayoutSubviews()
        let groupSurfaces = descendants(of: controller.tableView).compactMap { $0 as? UIVisualEffectView }
            .filter { $0.accessibilityIdentifier == "left_menu_main_section_surface" }
        let groupSurface = try XCTUnwrap(groupSurfaces.first)
        let mainRows = controller.datasource[0]
        let firstFrame = controller.tableView.rectForRow(at: IndexPath(row: 0, section: 0))
        let lastFrame = controller.tableView.rectForRow(at: IndexPath(row: mainRows.count - 1, section: 0))
        let firstCell = try XCTUnwrap(controller.tableView.cellForRow(at: IndexPath(row: 0, section: 0)))
        let lastCell = try XCTUnwrap(controller.tableView.cellForRow(at: IndexPath(row: mainRows.count - 1, section: 0)))
        let firstContentFrame = firstCell.contentView.convert(firstCell.contentView.bounds, to: controller.tableView)
        let lastContentFrame = lastCell.contentView.convert(lastCell.contentView.bounds, to: controller.tableView)
        let groupFrame = groupSurface.convert(groupSurface.bounds, to: controller.tableView)

        XCTAssertEqual(groupSurfaces.count, 1)
        XCTAssertFalse(groupSurface.isUserInteractionEnabled)
        XCTAssertLessThanOrEqual(groupFrame.minX, firstContentFrame.minX + 0.5)
        XCTAssertGreaterThanOrEqual(groupFrame.maxX, lastContentFrame.maxX - 0.5)
        XCTAssertLessThanOrEqual(groupFrame.minY, firstFrame.minY + 4.5)
        XCTAssertGreaterThanOrEqual(groupFrame.maxY, lastFrame.maxY - 4.5)
        XCTAssertEqual(controller.tableView.backgroundColor, .clear)
        if #available(iOS 26.0, *) {
            let glass = try XCTUnwrap(groupSurface.effect as? UIGlassEffect)
            XCTAssertFalse(glass.isInteractive)
            XCTAssertNil(glass.tintColor)
        } else {
            XCTAssertTrue(groupSurface.effect is UIBlurEffect)
        }
        for (row, item) in mainRows.enumerated() {
            let cell = try XCTUnwrap(controller.tableView.cellForRow(at: IndexPath(row: row, section: 0)))
            let title = try XCTUnwrap(labels(in: cell).first { $0.text == item.title })
            let surfaces = effectSurfaces(in: cell)
            XCTAssertEqual(cell.backgroundColor, .clear, item.key)
            XCTAssertEqual(cell.contentView.backgroundColor, .clear, item.key)
            XCTAssertEqual(surfaces.count, 1, item.key)
            XCTAssertTrue(surfaces.allSatisfy { $0.effect == nil }, item.key)
            XCTAssertTrue(title.isDescendant(of: try XCTUnwrap(surfaces.first).contentView), item.key)
        }
    }

    func testPremiumCopyChangesLanguageWhileBrandRemainsFixed() throws {
        var descriptions: [String] = []
        for language in [SupportedLanguage.english, .russian] {
            selectLanguage(language)
            let controller = makeMenu()
            let path = try premiumIndexPath(in: controller)
            let cell = controller.tableView(controller.tableView, cellForRowAt: path)

            XCTAssertEqual(controller.datasource[path.section][path.row].title, "Xabber Premium")
            XCTAssertFalse(premiumDescription.isEmpty)
            XCTAssertTrue(labels(in: cell).contains { $0.text == premiumDescription })
            descriptions.append(premiumDescription)
            try attachScreenshot(of: controller, language: language.rawValue)
        }
        XCTAssertNotEqual(descriptions[0], descriptions[1])
    }

    func testShortSidebarCanScrollAndPremiumUsesContentDrivenHeight() throws {
        let controller = makeMenu()
        controller.view.frame.size = CGSize(width: 300, height: 260)
        let path = try premiumIndexPath(in: controller)
        let cell = controller.tableView(controller.tableView, cellForRowAt: path)

        let height = controller.tableView(controller.tableView, heightForRowAt: path)
        let fittingHeight = cell.systemLayoutSizeFitting(
            CGSize(width: 268, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height

        XCTAssertTrue(controller.tableView.isScrollEnabled)
        XCTAssertEqual(height, UITableView.automaticDimension)
        XCTAssertGreaterThan(fittingHeight, 60)
    }

    func testPremiumTapOpensPurchaseWithoutChangingSelectionOrExistingChat() throws {
        let controller = PremiumRouteSpyViewController()
        controller.loadViewIfNeeded()
        controller.configure()
        let chatsController = LastChatsViewController()
        let currentChat = ChatViewController()
        chatsController.currentChatVC = currentChat
        controller.chatsVc = chatsController
        controller.previousSelectedKey = "contacts"
        let path = try premiumIndexPath(in: controller)

        controller.tableView(controller.tableView, didSelectRowAt: path)

        XCTAssertEqual(controller.purchasePresentationCount, 1)
        XCTAssertEqual(controller.previousSelectedKey, "contacts")
        XCTAssertTrue(controller.chatsVc === chatsController)
        XCTAssertTrue(controller.chatsVc?.currentChatVC === currentChat)
    }

    func testSidebarOutsideSharedSplitKeepsTheCommonChatBackdropAcrossLayout() throws {
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        defer { CommonConfigManager.shared.config.interface_type = previousInterfaceType }
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.tabs.rawValue
        let controller = makeMenu()
        let backdrop = try XCTUnwrap(controller.tableView.backgroundView as? ChatBackgroundBackdropView)

        controller.viewDidLayoutSubviews()
        controller.viewDidLayoutSubviews()

        XCTAssertTrue(controller.tableView.backgroundView === backdrop)
        XCTAssertEqual(controller.tableView.backgroundColor, .clear)
        XCTAssertFalse(controller.tableView.isOpaque)
    }

    func testWindowAttachmentUsesPlatformHeaderAndCompactRestoresLocalBackdrop() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Window trait overrides require iOS 17") }
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        defer { CommonConfigManager.shared.config.interface_type = previousInterfaceType }
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        let controller = makeMenu()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.traitOverrides.horizontalSizeClass = .regular
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.layoutIfNeeded()
        controller.viewDidLayoutSubviews()
        let appName = CommonConfigManager.shared.config.app_name.capitalized
        let headerLabel = try XCTUnwrap(labels(in: controller.view).first { $0.text == appName })
        let headerSurface = effectSurfaces(in: controller.view).first {
            headerLabel.isDescendant(of: $0.contentView)
        }

        XCTAssertNil(controller.tableView.backgroundView)
        if controller.traitCollection.userInterfaceIdiom == .pad {
            XCTAssertNil(headerSurface)
            XCTAssertEqual(headerLabel.textAlignment, .natural)
            XCTAssertTrue(headerLabel.font.fontDescriptor.symbolicTraits.contains(.traitBold))
            XCTAssertTrue(headerLabel.adjustsFontForContentSizeCategory)
            XCTAssertTrue(headerLabel.accessibilityTraits.contains(.header))
            XCTAssertEqual(
                headerLabel.font.pointSize,
                UIFont.preferredFont(forTextStyle: .largeTitle, compatibleWith: controller.traitCollection).pointSize,
                accuracy: 2
            )
        } else {
            XCTAssertEqual(headerSurface?.isHidden, false)
        }

        window.traitOverrides.horizontalSizeClass = .compact
        window.setNeedsLayout()
        window.layoutIfNeeded()
        controller.viewDidLayoutSubviews()

        XCTAssertTrue(controller.tableView.backgroundView is ChatBackgroundBackdropView)
        XCTAssertTrue(headerLabel.isHidden || headerLabel.window == nil || headerSurface?.isHidden == true)
        XCTAssertEqual(controller.tableView.tableHeaderView?.frame.height ?? 0, 0, accuracy: 0.5)
    }

    func testExpandedIPadMenuSurfaceStartsAtSameHeightAsChats() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        guard scene.traitCollection.userInterfaceIdiom == .pad else {
            throw XCTSkip("Requires an iPad split view")
        }
        let previousInterfaceType = CommonConfigManager.shared.config.interface_type
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
            CommonConfigManager.shared.config.interface_type = previousInterfaceType
        }

        let menu = makeMenu()
        // UIKit can resolve section metrics while the split's primary column
        // is detached. Revealing it must replace those metrics automatically.
        menu.tableView.reloadData()
        _ = menu.tableView.rectForRow(at: IndexPath(row: 0, section: 0))
        let chats = ChatsTableFixtureViewController()
        let rows = ChatsTableFixtureDataSource()
        chats.loadViewIfNeeded()
        chats.tableView.dataSource = rows
        let split = UISplitViewController(style: .tripleColumn)
        MainSplitLayout.apply(to: split)
        split.preferredSplitBehavior = .tile
        split.preferredDisplayMode = .oneBesideSecondary
        split.setViewController(menu, for: .primary)
        split.setViewController(UINavigationController(rootViewController: chats), for: .supplementary)
        split.setViewController(UIViewController(), for: .secondary)
        menu.chatsVc = chats
        window.rootViewController = split
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        split.show(.primary)
        let deadline = Date().addingTimeInterval(2)
        while (menu.view.window !== window || chats.view.window !== window) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(try XCTUnwrap(menu.view.window) === window)
        XCTAssertTrue(try XCTUnwrap(chats.view.window) === window)
        chats.configureBars()
        window.layoutIfNeeded()
        menu.tableView.layoutIfNeeded()
        chats.tableView.layoutIfNeeded()

        let surface = try XCTUnwrap(descendants(of: menu.tableView).compactMap { $0 as? UIVisualEffectView }.first {
            $0.accessibilityIdentifier == "left_menu_main_section_surface"
        })
        let firstChat = try XCTUnwrap(chats.tableView.cellForRow(at: IndexPath(row: 0, section: 0)))
        let appName = CommonConfigManager.shared.config.app_name.capitalized
        let title = try XCTUnwrap(labels(in: menu.view).first { $0.text == appName && !$0.isHidden })
        XCTAssertTrue(surface.window === window)
        XCTAssertTrue(firstChat.window === window)
        XCTAssertLessThan(title.convert(title.bounds, to: window).maxY, surface.convert(surface.bounds, to: window).minY)
        XCTAssertEqual(
            surface.convert(surface.bounds, to: window).minY,
            firstChat.convert(firstChat.bounds, to: window).minY,
            accuracy: 1
        )
    }

    private var premiumDescription: String {
        L10n.text("left_menu__premium__description", fallback: "")
    }

    private func selectLanguage(_ language: SupportedLanguage) {
        let context = LocalizationRuntime.shared.context
        LocalizationRuntime.shared.replaceContext(
            selection: .fixed(language),
            preferredLanguages: [language.rawValue],
            locale: context.locale,
            calendar: context.calendar,
            timeZone: context.timeZone
        )
    }

    private func makeMenu() -> LeftMenuViewController {
        let controller = MenuFixtureViewController()
        controller.loadViewIfNeeded()
        controller.configure()
        return controller
    }

    private func premiumIndexPath(in controller: LeftMenuViewController) throws -> IndexPath {
        try XCTUnwrap(controller.datasource.enumerated().compactMap { section, rows in
            rows.firstIndex { $0.key == "premium" }.map { IndexPath(row: $0, section: section) }
        }.first)
    }

    private func labels(in view: UIView) -> [UILabel] {
        descendants(of: view).compactMap { $0 as? UILabel }
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func effectSurfaces(in view: UIView) -> [UIVisualEffectView] {
        if let surface = view as? UIVisualEffectView { return [surface] }
        return view.subviews.flatMap { effectSurfaces(in: $0) }
    }

    private func attachScreenshot(of controller: LeftMenuViewController, language: String) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.navigationBar.prefersLargeTitles = true
        let sidebarHost = UIViewController()
        sidebarHost.addChild(navigationController)
        sidebarHost.view.addSubview(navigationController.view)
        navigationController.view.translatesAutoresizingMaskIntoConstraints = false
        let sidebarWidth = min(window.bounds.width, 280)
        NSLayoutConstraint.activate([
            navigationController.view.leadingAnchor.constraint(equalTo: sidebarHost.view.leadingAnchor),
            navigationController.view.topAnchor.constraint(equalTo: sidebarHost.view.topAnchor),
            navigationController.view.bottomAnchor.constraint(equalTo: sidebarHost.view.bottomAnchor),
            navigationController.view.widthAnchor.constraint(equalToConstant: sidebarWidth)
        ])
        navigationController.didMove(toParent: sidebarHost)
        window.rootViewController = sidebarHost
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        controller.tableView.reloadData()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let premiumPath = try premiumIndexPath(in: controller)
        controller.tableView.scrollToRow(at: premiumPath, at: .none, animated: false)
        window.layoutIfNeeded()
        let renderedCell = try XCTUnwrap(controller.tableView.cellForRow(at: premiumPath))
        renderedCell.layoutIfNeeded()
        let description = try XCTUnwrap(labels(in: renderedCell).first { $0.text == premiumDescription })
        let font = try XCTUnwrap(description.font)
        // Match UILabel's line metrics while removing the displayed label's line cap.
        let completeTextLabel = UILabel()
        completeTextLabel.font = font
        completeTextLabel.text = description.text
        completeTextLabel.numberOfLines = 0
        completeTextLabel.lineBreakMode = .byWordWrapping
        let completeTextHeight = completeTextLabel.sizeThatFits(
            CGSize(width: description.bounds.width, height: .greatestFiniteMagnitude)
        ).height
        XCTAssertGreaterThan(description.bounds.width, 0, language)
        XCTAssertGreaterThanOrEqual(description.bounds.height + 0.5, font.lineHeight * 2, language)
        XCTAssertEqual(description.numberOfLines, 3, language)
        XCTAssertGreaterThanOrEqual(description.bounds.height + 1, completeTextHeight,
                                   "The hosted \(language) explanation must display its complete text without truncation")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "left-menu-glass-premium-\(language)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private class MenuFixtureViewController: LeftMenuViewController {
        override func loadView() {
            view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        }
        override func viewDidLoad() {}
        override func viewWillAppear(_ animated: Bool) {}
        override func viewDidAppear(_ animated: Bool) {}
        override func viewWillDisappear(_ animated: Bool) {}
        override func viewDidDisappear(_ animated: Bool) {}
    }

    private final class ChatsTableFixtureViewController: LastChatsViewController {
        override func viewDidLoad() {
            view.addSubview(tableView)
            tableView.fillSuperview()
        }

        override func viewWillAppear(_ animated: Bool) {}
        override func viewDidAppear(_ animated: Bool) {}
        override func viewWillDisappear(_ animated: Bool) {}
        override func viewDidDisappear(_ animated: Bool) {}
        override func viewDidLayoutSubviews() {}
        override func viewSafeAreaInsetsDidChange() {}
    }

    private final class ChatsTableFixtureDataSource: NSObject, UITableViewDataSource {
        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            UITableViewCell()
        }
    }

    private final class PremiumRouteSpyViewController: MenuFixtureViewController {
        private(set) var purchasePresentationCount = 0

        override func presentPremiumPurchase() -> Bool {
            purchasePresentationCount += 1
            return true
        }
    }

}
