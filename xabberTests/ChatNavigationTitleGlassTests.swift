import XCTest
import UIKit
import RealmSwift
@testable import xabber

@MainActor
final class ChatNavigationTitleGlassTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private var retainedRealm: Realm?

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatNavigationTitleGlassTests-\(name)-\(UUID().uuidString)"
        )
        retainedRealm = try WRealm.safe()
    }

    override func tearDownWithError() throws {
        retainedRealm = nil
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        try super.tearDownWithError()
    }

    func testNormalTitleUsesUntintedNativeGlassAndNavbarButtonCapsuleShape() throws {
        let chat = makeChat()

        chat.configureNavbar()

        let surface = try titleSurface(in: chat)
        XCTAssertTrue(chat.navigationItem.titleView === chat.titleButton)
        XCTAssertTrue(chat.titleStack.superview === surface.contentView)
        XCTAssertFalse(surface.isUserInteractionEnabled, "the existing title button must own taps")
        XCTAssertEqual(surface.backgroundColor, .clear)
        XCTAssertEqual(surface.contentView.backgroundColor, .clear)
        XCTAssertEqual(surface.layer.borderWidth, 0)
        XCTAssertEqual(surface.layer.shadowOpacity, 0)
        XCTAssertEqual(chat.titleButton.intrinsicContentSize.height, 44)

        if #available(iOS 26.0, *) {
            let glass = try XCTUnwrap(surface.effect as? UIGlassEffect)
            XCTAssertNil(glass.tintColor)
            XCTAssertTrue(glass.isInteractive)
            XCTAssertEqual(surface.cornerConfiguration, .capsule())
        } else {
            XCTAssertTrue(surface.effect is UIBlurEffect)
            XCTAssertEqual(surface.layer.cornerRadius, 22, accuracy: 0.001)
        }
    }

    func testLongTitleAndStatusStayInsideGlassAtNarrowAndWideWidths() throws {
        let chat = makeChat()
        chat.configureNavbar()
        let surface = try titleSurface(in: chat)
        chat.titleLabel.attributedText = NSAttributedString(
            string: "A long conversation title that needs to truncate in a narrow navigation bar",
            attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .semibold)]
        )
        chat.statusLabel.text = "A long presence status that needs the same safe inset"
        chat.statusLabel.isHidden = false

        for width: CGFloat in [64, 180, 320] {
            chat.titleButton.frame = CGRect(x: 0, y: 0, width: width, height: 44)
            chat.titleButton.setNeedsLayout()
            chat.titleButton.layoutIfNeeded()
            surface.layoutIfNeeded()

            XCTAssertEqual(surface.frame, chat.titleButton.bounds, "width \(width)")
            XCTAssertEqual(chat.titleStack.frame.minX, 12, accuracy: 0.5, "width \(width)")
            XCTAssertEqual(surface.contentView.bounds.maxX - chat.titleStack.frame.maxX, 12, accuracy: 0.5, "width \(width)")
            XCTAssertGreaterThanOrEqual(chat.titleStack.frame.minY, 3.5, "width \(width)")
            XCTAssertLessThanOrEqual(chat.titleStack.frame.maxY, surface.contentView.bounds.maxY - 3.5, "width \(width)")
            XCTAssertEqual(chat.titleStack.frame.midY, surface.contentView.bounds.midY, accuracy: 0.5)
            XCTAssertEqual(chat.titleLabel.numberOfLines, 1)
            XCTAssertEqual(chat.titleLabel.lineBreakMode, .byTruncatingTail)
            XCTAssertEqual(chat.statusLabel.numberOfLines, 1)
            XCTAssertEqual(chat.statusLabel.lineBreakMode, .byTruncatingTail)
            XCTAssertGreaterThan(chat.titleLabel.bounds.width, 0)
            XCTAssertGreaterThan(chat.statusLabel.bounds.width, 0)
        }
    }

    func testRepeatedNavbarConfigurationKeepsSingleSurfaceConstraintsAndInfoAction() throws {
        let chat = makeChat()
        chat.configureNavbar()
        let surface = try titleSurface(in: chat)
        let initialConstraints = constraintIdentities(in: chat.titleButton, surface.contentView)

        chat.configureNavbar()
        chat.configureNavbar()

        XCTAssertTrue(try titleSurface(in: chat) === surface)
        XCTAssertEqual(chat.titleButton.subviews.compactMap { $0 as? UIVisualEffectView }.count, 1)
        XCTAssertEqual(chat.titleStack.arrangedSubviews.count, 2)
        XCTAssertTrue(chat.titleStack.arrangedSubviews[0] === chat.titleLabel)
        XCTAssertTrue(chat.titleStack.arrangedSubviews[1] === chat.statusLabel)
        XCTAssertEqual(constraintIdentities(in: chat.titleButton, surface.contentView), initialConstraints)
        XCTAssertTrue(chat.titleButton.isUserInteractionEnabled)
        XCTAssertTrue(chat.titleButton.isAccessibilityElement)
        XCTAssertEqual(
            chat.titleButton.actions(forTarget: chat, forControlEvent: .touchUpInside),
            [NSStringFromSelector(#selector(ChatViewController.onTitleButtonTouchUp(_:)))]
        )
    }

    func testSavedMessagesKeepsGlassTitleNoninteractiveAndSearchItemAvailable() throws {
        let chat = makeChat(conversationType: .saved)

        chat.configureNavbar()

        let surface = try titleSurface(in: chat)
        let searchItem = try XCTUnwrap(chat.savedMessagesSearchNavigationItem)
        XCTAssertTrue(chat.navigationItem.titleView === chat.titleButton)
        XCTAssertTrue(chat.navigationItem.rightBarButtonItem === searchItem)
        XCTAssertFalse(chat.titleButton.isUserInteractionEnabled)
        XCTAssertFalse(chat.titleButton.isAccessibilityElement)
        XCTAssertTrue(chat.titleButton.actions(forTarget: chat, forControlEvent: .touchUpInside)?.isEmpty ?? true)
        if #available(iOS 26.0, *) {
            let glass = try XCTUnwrap(surface.effect as? UIGlassEffect)
            XCTAssertFalse(glass.isInteractive)
        }

        chat.configureNavbar()

        XCTAssertTrue(try titleSurface(in: chat) === surface)
        XCTAssertTrue(chat.navigationItem.rightBarButtonItem === searchItem)
    }

    func testSelectionAndSearchRestoreSameGlassTitleWithoutReplacingModeContentEarly() throws {
        let chat = makeChat()
        chat.configureNavbar()
        let surface = try titleSurface(in: chat)

        chat.isInSelectionMode.accept(true)
        chat.navigationItem.titleView = chat.selectionCountLabel
        chat.configureNavbar()
        XCTAssertTrue(chat.navigationItem.titleView === chat.selectionCountLabel)

        chat.isInSelectionMode.accept(false)
        XCTAssertFalse(chat.restoreNormalNavbarAfterSelectionIfNeeded())
        XCTAssertTrue(chat.navigationItem.titleView === chat.titleButton)
        XCTAssertTrue(try titleSurface(in: chat) === surface)

        chat.inSearchMode.accept(true)
        chat.navigationItem.titleView = nil
        chat.configureNavbar()
        XCTAssertNil(chat.navigationItem.titleView)

        chat.inSearchMode.accept(false)
        XCTAssertFalse(chat.restoreNormalNavbarAfterSearchIfNeeded())
        XCTAssertTrue(chat.navigationItem.titleView === chat.titleButton)
        XCTAssertTrue(try titleSurface(in: chat) === surface)
    }

    func testHostedNavigationTitleMatchesRecentChatsSlotAcrossWidths() throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(
            scenes.first { $0.activationState == .foregroundActive } ?? scenes.first,
            "native glass acceptance requires a hosted window scene"
        )
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let root = UIViewController()
        root.navigationItem.title = "Chats"
        root.navigationItem.backButtonDisplayMode = .minimal
        let chat = makeChat()
        let navigationController = UINavigationController(rootViewController: root)
        navigationController.pushViewController(chat, animated: false)
        let host = UIViewController()
        host.addChild(navigationController)
        host.view.addSubview(navigationController.view)
        navigationController.didMove(toParent: host)
        window.rootViewController = host
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        let backdrop = ChatBackgroundBackdropView(frame: chat.view.bounds)
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.configure(document: AppearanceSettingsStore()?.load()
            ?? AppearanceSettingsDocument(profile: .default(accent: .systemBlue)))
        chat.view.insertSubview(backdrop, at: 0)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let bar = navigationController.navigationBar
        func layoutBar() {
            navigationController.view.setNeedsLayout()
            navigationController.view.layoutIfNeeded()
            bar.setNeedsLayout()
            bar.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        let referenceTitle = ListNavigationTitleView(accessibilityIdentifier: "last_chats.navigation.title")
        referenceTitle.titleLabel.text = "Chats"
        let banner = chat.makeRequestingVerificationPanel(isActionEnabled: true)
        if #available(iOS 26.0, *) {
            chat.showTopPanelBubble(with: banner)
        }
        let windowWidth = window.bounds.width
        let widths: [CGFloat] = UIDevice.current.userInterfaceIdiom == .pad
            ? [windowWidth, 393, 700, windowWidth]
            : [windowWidth, 320, windowWidth]
        for width in widths {
            navigationController.view.frame = CGRect(x: 0, y: 0, width: width, height: window.bounds.height)
            layoutBar()
            chat.configureNavbar()
            XCTAssertEqual(bar.bounds.width, width, accuracy: 0.5)
            XCTAssertTrue(bar.backItem === root.navigationItem)
            let avatar = try XCTUnwrap(chat.navigationItem.rightBarButtonItem?.customView)

            // Compare the title views with the very same native Back and avatar items.
            chat.navigationItem.titleView = referenceTitle
            layoutBar()
            let referenceFrame = referenceTitle.convert(referenceTitle.bounds, to: bar)
            XCTAssertTrue(referenceTitle.window === window)
            XCTAssertGreaterThan(referenceFrame.width, 24)

            chat.navigationItem.titleView = chat.titleButton
            for title in ["Alex", "Research planning and project coordination with a very long conversation title"] {
                chat.titleLabel.text = title
                chat.statusLabel.text = "Online"
                chat.statusLabel.isHidden = false
                layoutBar()

                let frame = chat.titleButton.convert(chat.titleButton.bounds, to: bar)
                XCTAssertTrue(chat.titleButton.window === window)
                XCTAssertEqual(frame.minX, referenceFrame.minX, accuracy: 0.5, "width \(width), \(title)")
                XCTAssertEqual(frame.maxX, referenceFrame.maxX, accuracy: 0.5, "width \(width), \(title)")
                XCTAssertEqual(frame.height, 44, accuracy: 0.5)
                XCTAssertEqual(try titleSurface(in: chat).bounds.size, chat.titleButton.bounds.size)
                XCTAssertTrue(avatar.window === window)
                let avatarFrame = avatar.convert(avatar.bounds, to: bar)
                XCTAssertLessThanOrEqual(frame.maxX, avatarFrame.minX)
            }

            if #available(iOS 26.0, *) {
                chat.updateTopPanelNavigationLayout()
                chat.view.layoutIfNeeded()
                let surface = try XCTUnwrap(banner.subviews.flatMap(\.subviews).compactMap { $0 as? UIVisualEffectView }.first)
                let bannerSurfaceFrame = surface.convert(surface.bounds, to: bar)
                let titleFrame = chat.titleButton.convert(chat.titleButton.bounds, to: bar)
                XCTAssertEqual(bannerSurfaceFrame.minX, titleFrame.minX, accuracy: 0.5, "width \(width)")
                XCTAssertEqual(bannerSurfaceFrame.maxX, titleFrame.maxX, accuracy: 0.5, "width \(width)")
            }
        }

        chat.hideTopPanelBubble(animated: false)
        var didDrawWholeWindow = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            didDrawWholeWindow = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(didDrawWholeWindow)
        let attachment = XCTAttachment(image: image)
        attachment.name = "chat-navbar-title-matches-recent-chats"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeChat(
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) -> ChatViewController {
        let chat = TitleOnlyChatViewController()
        chat.owner = "title-glass-owner@example.com"
        chat.jid = "title-glass-contact@example.com"
        chat.conversationType = conversationType
        chat.loadViewIfNeeded()
        return chat
    }

    private func titleSurface(in chat: ChatViewController) throws -> UIVisualEffectView {
        try XCTUnwrap(chat.titleButton.subviews.compactMap { $0 as? UIVisualEffectView }.first)
    }

    private func constraintIdentities(in views: UIView...) -> Set<ObjectIdentifier> {
        Set(views.flatMap(\.constraints).map(ObjectIdentifier.init))
    }

    private final class TitleOnlyChatViewController: ChatViewController {
        override func loadView() {
            view = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
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
