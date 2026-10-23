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
        let height = try XCTUnwrap(chat.titleButton.constraints.first {
            $0.firstItem === chat.titleButton && $0.firstAttribute == .height
        })
        XCTAssertEqual(height.constant, 44)

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
        let titleWidth = try XCTUnwrap(chat.titleButton.constraints.first {
            $0.firstItem === chat.titleButton && $0.firstAttribute == .width
        })
        titleWidth.isActive = false
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

    func testGlassTitleKeepsFixedSafeWidthForShortAndLongText() throws {
        let chat = makeChat()
        chat.configureNavbar()
        _ = try titleSurface(in: chat)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: chat.view.bounds.width, height: 44))
        host.addSubview(chat.titleButton)
        NSLayoutConstraint.activate([
            chat.titleButton.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            chat.titleButton.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
        let widthConstraint = try XCTUnwrap(chat.titleButton.constraints.first {
            $0.firstItem === chat.titleButton && $0.firstAttribute == .width
        })
        let expectedWidth = expectedTitleWidth(forNavigationBarWidth: host.bounds.width)
        var renderedWidths: [CGFloat] = []

        for title in ["Alex", "Research planning and project coordination with a very long conversation title"] {
            chat.titleLabel.attributedText = NSAttributedString(
                string: title,
                attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .semibold)]
            )
            chat.statusLabel.text = "Online"
            chat.statusLabel.isHidden = false
            host.setNeedsLayout()
            host.layoutIfNeeded()

            XCTAssertEqual(widthConstraint.relation, .equal)
            XCTAssertEqual(widthConstraint.constant, expectedWidth, accuracy: 0.5)
            XCTAssertEqual(chat.titleButton.frame.height, 44, accuracy: 0.5)
            XCTAssertEqual(chat.titleButton.frame.width, expectedWidth, accuracy: 0.5)
            XCTAssertEqual(chat.titleButton.frame.midX, host.bounds.midX, accuracy: 0.5)
            if UIDevice.current.userInterfaceIdiom == .pad {
                XCTAssertLessThanOrEqual(chat.titleButton.frame.width, 360)
            }
            renderedWidths.append(chat.titleButton.frame.width)
        }
        XCTAssertEqual(renderedWidths[0], renderedWidths[1], accuracy: 0.5)
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

    func testHostedNavigationTitleFitsNativeBarAndCapturesWholeWindow() throws {
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
        window.rootViewController = navigationController
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
        navigationController.view.layoutIfNeeded()
        chat.configureNavbar()
        var renderedTitleWidths: [CGFloat] = []

        for (kind, title) in [
            ("short", "Alex"),
            ("long", "Research planning and project coordination with a very long conversation title")
        ] {
            chat.titleLabel.attributedText = NSAttributedString(
                string: title,
                attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .semibold)]
            )
            chat.statusLabel.text = "Online"
            chat.statusLabel.isHidden = false
            chat.titleButton.invalidateIntrinsicContentSize()
            navigationController.navigationBar.setNeedsLayout()
            window.layoutIfNeeded()
            navigationController.view.layoutIfNeeded()
            navigationController.navigationBar.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))

            let bar = navigationController.navigationBar
            let titleFrame = chat.titleButton.convert(chat.titleButton.bounds, to: bar)
            XCTAssertTrue(chat.titleButton.window === window)
            XCTAssertTrue(bar.backItem === root.navigationItem)
            XCTAssertNotNil(chat.navigationItem.rightBarButtonItem)
            XCTAssertGreaterThan(titleFrame.width, 24, kind)
            XCTAssertEqual(titleFrame.height, 44, accuracy: 0.5, kind)
            XCTAssertEqual(titleFrame.width, expectedTitleWidth(forNavigationBarWidth: bar.bounds.width), accuracy: 0.5, kind)
            XCTAssertEqual(titleFrame.midX, bar.bounds.midX, accuracy: 0.5, kind)
            if UIDevice.current.userInterfaceIdiom == .pad {
                XCTAssertLessThanOrEqual(titleFrame.width, 360, kind)
            }
            renderedTitleWidths.append(titleFrame.width)
            XCTAssertGreaterThanOrEqual(titleFrame.minX, 44, kind)
            XCTAssertLessThanOrEqual(titleFrame.maxX, bar.bounds.maxX - 44, kind)
            XCTAssertGreaterThanOrEqual(titleFrame.minY, bar.bounds.minY - 0.5, kind)
            XCTAssertLessThanOrEqual(titleFrame.maxY, bar.bounds.maxY + 0.5, kind)
            if let avatar = chat.navigationItem.rightBarButtonItem?.customView,
               avatar.window === window {
                let avatarFrame = avatar.convert(avatar.bounds, to: bar)
                XCTAssertLessThanOrEqual(titleFrame.maxX + 4, avatarFrame.minX, kind)
            }
            let surface = try titleSurface(in: chat)
            XCTAssertEqual(surface.bounds.size, chat.titleButton.bounds.size)

            var didDrawWholeWindow = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                didDrawWholeWindow = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(didDrawWholeWindow, "capture the whole native-glass hierarchy")
            let attachment = XCTAttachment(image: image)
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            attachment.name = "chat-navbar-title-glass-\(device)-\(kind)-fixture"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(renderedTitleWidths[0], renderedTitleWidths[1], accuracy: 0.5)
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

    private func expectedTitleWidth(forNavigationBarWidth width: CGFloat) -> CGFloat {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let sideReserve: CGFloat = isPad ? 120 : 88
        let availableWidth = max(0, width - sideReserve * 2)
        return isPad ? min(availableWidth, 360) : availableWidth
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
