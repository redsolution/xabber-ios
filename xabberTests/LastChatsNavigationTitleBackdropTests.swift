import XCTest
import UIKit
import RealmSwift
@testable import xabber

@MainActor
final class LastChatsNavigationTitleBackdropTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private var retainedRealm: Realm?
    private var previousInterfaceType = ""
    private var previousUseYubikey = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "LastChatsNavigationTitleBackdropTests-\(name)-\(UUID().uuidString)"
        )
        retainedRealm = try WRealm.safe()
        previousInterfaceType = CommonConfigManager.shared.config.interface_type
        previousUseYubikey = CommonConfigManager.shared.config.use_yubikey
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.tabs.rawValue
        CommonConfigManager.shared.config.use_yubikey = true
    }

    override func tearDownWithError() throws {
        CommonConfigManager.shared.config.interface_type = previousInterfaceType
        CommonConfigManager.shared.config.use_yubikey = previousUseYubikey
        retainedRealm = nil
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        try super.tearDownWithError()
    }

    func testTitleHasOneNoninteractiveGlassCapsuleAndAccessibleLocalizedHeader() throws {
        let controller = makeController()

        controller.updateTitle(.chats)

        let title = try XCTUnwrap(controller.navigationItem.titleView)
        let surface = try titleSurface(in: title)
        let label = try titleLabel(in: title)
        title.bounds = CGRect(x: 0, y: 0, width: 240, height: 44)
        title.setNeedsLayout()
        title.layoutIfNeeded()

        XCTAssertTrue(label.isDescendant(of: surface.contentView))
        XCTAssertEqual(label.text, controller.title)
        XCTAssertEqual(label.textAlignment, .center)
        XCTAssertTrue(label.isAccessibilityElement)
        XCTAssertTrue(label.accessibilityTraits.contains(.header))
        XCTAssertFalse(surface.isUserInteractionEnabled)
        XCTAssertEqual(surface.backgroundColor, .clear)
        XCTAssertEqual(surface.contentView.backgroundColor, .clear)
        XCTAssertEqual(surface.bounds.width, title.bounds.width, accuracy: 0.5)
        XCTAssertEqual(surface.bounds.height, 44, accuracy: 0.5)

        if #available(iOS 26.0, *) {
            let glass = try XCTUnwrap(surface.effect as? UIGlassEffect)
            XCTAssertNil(glass.tintColor)
            XCTAssertFalse(glass.isInteractive)
            XCTAssertEqual(surface.cornerConfiguration, .capsule())
        } else {
            XCTAssertTrue(surface.effect is UIBlurEffect)
            XCTAssertEqual(surface.layer.cornerRadius, 22, accuracy: 0.5)
        }
    }

    func testRepeatedTitleUpdatesPreserveSurfaceAndNativeNavbarActions() throws {
        let controller = makeController()
        controller.configureBars()
        let title = try XCTUnwrap(controller.navigationItem.titleView)
        let surface = try titleSurface(in: title)
        let leadingItems = items(on: controller.navigationItem, leading: true)
        let trailingItems = items(on: controller.navigationItem, leading: false)
        let originalTargets = (leadingItems + trailingItems).map(\.target)
        let originalActions = (leadingItems + trailingItems).map(\.action)

        for filter in [LastChatsViewController.Filter.unread, .archived, .saved, .chats] {
            controller.updateTitle(filter)
            controller.configureBars(updateNavigationItems: false)

            XCTAssertTrue(controller.navigationItem.titleView === title)
            XCTAssertTrue(try titleSurface(in: title) === surface)
            XCTAssertEqual(try titleLabel(in: title).text, controller.title)
            let currentItems = items(on: controller.navigationItem, leading: true)
                + items(on: controller.navigationItem, leading: false)
            XCTAssertEqual(currentItems.count, leadingItems.count + trailingItems.count)
            for (index, item) in currentItems.prefix(originalTargets.count).enumerated() {
                XCTAssertTrue(item === (leadingItems + trailingItems)[index])
                XCTAssertTrue(item.target === originalTargets[index])
                XCTAssertEqual(item.action, originalActions[index])
            }
        }
    }

    func testBackdropFillsAvailableWidthBetweenButtonsAtPhoneAndWideColumnSizes() throws {
        try withNativeNavigationFixture(trailingButtonCount: 1) { fixture in
            for width in [CGFloat(320), 393, 700] {
                fixture.resize(to: width)
                try assertFillsAvailableTitleRegion(in: fixture, context: "width=\(width)")
                if width == 393 { attachScreenshot(of: fixture, name: "last-chats-title-backdrop-regular-buttons") }
            }
        }
    }

    func testBackdropResizesBetweenAsymmetricButtonsAndKeepsWidthForShortAndLongTitles() throws {
        try withNativeNavigationFixture(trailingButtonCount: 2) { fixture in
            let label = try titleLabel(in: fixture.title)
            for width in [CGFloat(393), 320, 700, 393] {
                fixture.resize(to: width)
                var renderedWidths: [CGFloat] = []
                for text in ["Chats", "A very long localized chat-list heading that must truncate between navigation buttons"] {
                    label.attributedText = nil
                    label.text = text
                    label.invalidateIntrinsicContentSize()
                    fixture.title.invalidateIntrinsicContentSize()
                    fixture.layout()

                    try assertFillsAvailableTitleRegion(in: fixture, context: "width=\(width), title=\(text)")
                    renderedWidths.append(fixture.title.bounds.width)
                }
                XCTAssertEqual(renderedWidths[0], renderedWidths[1], accuracy: 0.5)
            }
            attachScreenshot(of: fixture, name: "last-chats-title-backdrop-asymmetric-buttons")
        }
    }

    private func attachScreenshot(of fixture: NativeNavigationFixture, name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: fixture.window.bounds)
        var didDraw = false
        let image = renderer.image { _ in
            didDraw = fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(didDraw)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertFillsAvailableTitleRegion(
        in fixture: NativeNavigationFixture,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bar = fixture.navigationController.navigationBar
        let titleFrame = fixture.title.convert(fixture.title.bounds, to: bar)
        let leadingFrame = fixture.leadingButton.convert(fixture.leadingButton.bounds, to: bar)
        let trailingFrames = fixture.trailingButtons.map { $0.convert($0.bounds, to: bar) }
        let nearestTrailingEdge = try XCTUnwrap(trailingFrames.map(\.minX).min(), file: file, line: line)
        let leadingGap = titleFrame.minX - leadingFrame.maxX
        let trailingGap = nearestTrailingEdge - titleFrame.maxX

        XCTAssertTrue(fixture.title.window === fixture.window, context, file: file, line: line)
        XCTAssertEqual(bar.bounds.width, fixture.width, accuracy: 0.5, context, file: file, line: line)
        XCTAssertGreaterThan(titleFrame.width, 24, context, file: file, line: line)
        XCTAssertEqual(titleFrame.height, 44, accuracy: 0.5, context, file: file, line: line)
        XCTAssertGreaterThanOrEqual(leadingGap, -0.5, context, file: file, line: line)
        XCTAssertGreaterThanOrEqual(trailingGap, -0.5, context, file: file, line: line)
        XCTAssertLessThanOrEqual(leadingGap, 24, context, file: file, line: line)
        XCTAssertLessThanOrEqual(trailingGap, 24, context, file: file, line: line)
        let surface = try titleSurface(in: fixture.title)
        XCTAssertEqual(surface.bounds.size, fixture.title.bounds.size, context, file: file, line: line)
        let label = try titleLabel(in: fixture.title)
        let labelFrame = label.convert(label.bounds, to: fixture.title)
        XCTAssertGreaterThanOrEqual(labelFrame.minX, 0, context, file: file, line: line)
        XCTAssertLessThanOrEqual(labelFrame.maxX, fixture.title.bounds.width + 0.5, context, file: file, line: line)
    }

    private func withNativeNavigationFixture(
        trailingButtonCount: Int,
        body: (NativeNavigationFixture) throws -> Void
    ) throws {
        let controller = makeController()
        controller.updateTitle(.chats)
        let title = try XCTUnwrap(controller.navigationItem.titleView)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIViewController()
        host.view.backgroundColor = .systemGroupedBackground
        let root = UIViewController()
        root.view.backgroundColor = .systemGroupedBackground
        root.navigationItem.title = controller.title
        root.navigationItem.titleView = title
        root.navigationItem.largeTitleDisplayMode = .never
        let leadingButton = makeNavigationButton(symbol: "person.crop.circle")
        let trailingButtons = (0..<trailingButtonCount).map { makeNavigationButton(symbol: $0 == 0 ? "plus" : "lock") }
        root.navigationItem.leftBarButtonItem = UIBarButtonItem(customView: leadingButton)
        root.navigationItem.rightBarButtonItems = trailingButtons.map { UIBarButtonItem(customView: $0) }
        let navigationController = UINavigationController(rootViewController: root)
        navigationController.navigationBar.prefersLargeTitles = false
        host.addChild(navigationController)
        host.view.addSubview(navigationController.view)
        navigationController.didMove(toParent: host)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        let fixture = NativeNavigationFixture(
            window: window,
            navigationController: navigationController,
            title: title,
            leadingButton: leadingButton,
            trailingButtons: trailingButtons
        )
        fixture.resize(to: 393)
        try body(fixture)
    }

    private func makeNavigationButton(symbol: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])
        return button
    }

    private func titleSurface(in title: UIView) throws -> UIVisualEffectView {
        let surfaces = effectSurfaces(in: title)
        XCTAssertEqual(surfaces.count, 1)
        return try XCTUnwrap(surfaces.first)
    }

    private func effectSurfaces(in view: UIView) -> [UIVisualEffectView] {
        if let surface = view as? UIVisualEffectView { return [surface] }
        return view.subviews.flatMap { effectSurfaces(in: $0) }
    }

    private func titleLabel(in title: UIView) throws -> UILabel {
        let labels = descendants(of: title).compactMap { $0 as? UILabel }
        return try XCTUnwrap(labels.first)
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func items(on item: UINavigationItem, leading: Bool) -> [UIBarButtonItem] {
        if leading {
            return item.leftBarButtonItems ?? item.leftBarButtonItem.map { [$0] } ?? []
        }
        return item.rightBarButtonItems ?? item.rightBarButtonItem.map { [$0] } ?? []
    }

    private func makeController() -> LastChatsViewController {
        let controller = TitleOnlyLastChatsViewController()
        controller.loadViewIfNeeded()
        controller.configureBars()
        return controller
    }

    private final class NativeNavigationFixture {
        let window: UIWindow
        let navigationController: UINavigationController
        let title: UIView
        let leadingButton: UIButton
        let trailingButtons: [UIButton]
        private(set) var width: CGFloat = 393

        init(
            window: UIWindow,
            navigationController: UINavigationController,
            title: UIView,
            leadingButton: UIButton,
            trailingButtons: [UIButton]
        ) {
            self.window = window
            self.navigationController = navigationController
            self.title = title
            self.leadingButton = leadingButton
            self.trailingButtons = trailingButtons
        }

        func resize(to width: CGFloat) {
            self.width = width
            navigationController.view.frame = CGRect(x: 0, y: 0, width: width, height: 640)
            layout()
        }

        func layout() {
            window.setNeedsLayout()
            window.layoutIfNeeded()
            navigationController.view.setNeedsLayout()
            navigationController.view.layoutIfNeeded()
            navigationController.navigationBar.setNeedsLayout()
            navigationController.navigationBar.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private final class TitleOnlyLastChatsViewController: LastChatsViewController {
        override func loadView() {
            view = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 640))
        }

        override func viewDidLoad() {}
        override func viewDidLayoutSubviews() {}
        override func viewSafeAreaInsetsDidChange() {}
        override func viewWillAppear(_ animated: Bool) {}
        override func viewDidAppear(_ animated: Bool) {}
        override func viewWillDisappear(_ animated: Bool) {}
        override func viewDidDisappear(_ animated: Bool) {}
        override func shouldChangeFrame() {}
    }
}
