import XCTest
import UIKit
import RealmSwift
@testable import xabber

@MainActor
final class ChatSplitCloseNavigationTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private var previousInterfaceType: String!
    private var retainedRealm: Realm?
    private var hosts: [Host] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        previousInterfaceType = CommonConfigManager.shared.config.interface_type
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatSplitCloseNavigationTests-\(name)-\(UUID().uuidString)"
        )
        retainedRealm = try WRealm.safe()
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
    }

    override func tearDownWithError() throws {
        for host in hosts.reversed() {
            host.list.resetExpandedSplitChatNavigationTransaction(restorePreviousDetail: false)
            host.list.resetChatNavigationTransaction(cancelled: true)
            host.window.isHidden = true
            host.window.rootViewController = nil
            host.previousKeyWindow?.makeKey()
        }
        hosts.removeAll()
        retainedRealm = nil
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        CommonConfigManager.shared.config.interface_type = previousInterfaceType
        previousRealmConfiguration = nil
        previousInterfaceType = nil
        try super.tearDownWithError()
    }

    /// This case intentionally runs on both physical device idioms.
    func testCloseButtonFollowsDevicePolicyAndPreservesNativePushedBack() throws {
        let host = try makeHost()

        if UIDevice.current.userInterfaceIdiom == .pad {
            let item = try closeItem(in: host.chat)
            XCTAssertNotNil(item.image)
            XCTAssertNil(item.customView, "UIKit must render the native navigation button")
            XCTAssertEqual(item.style, .plain)
            XCTAssertTrue(item.target === host.chat)
            XCTAssertEqual(item.action, NSSelectorFromString("onCloseSplitChat:"))
            XCTAssertFalse(item.accessibilityLabel?.isEmpty ?? true)
        } else {
            XCTAssertNil(host.chat.navigationItem.leftBarButtonItem)
            XCTAssertFalse(host.chat.navigationItem.hidesBackButton)
        }

        let root = UIViewController()
        root.navigationItem.backButtonDisplayMode = .minimal
        let pushedChat = makeChat()
        let navigationController = UINavigationController(rootViewController: root)
        navigationController.pushViewController(pushedChat, animated: false)
        navigationController.loadViewIfNeeded()
        pushedChat.configureNavbar()

        XCTAssertNil(pushedChat.navigationItem.leftBarButtonItem)
        XCTAssertFalse(pushedChat.navigationItem.hidesBackButton)
        XCTAssertFalse(pushedChat.navigationItem.leftItemsSupplementBackButton)
        XCTAssertTrue(navigationController.popViewController(animated: false) === pushedChat)
        XCTAssertTrue(navigationController.topViewController === root)
    }

    func testRepeatedConfigurationKeepsSingleNativeCloseItem() throws {
        try requirePad()
        let host = try makeHost()
        let item = try closeItem(in: host.chat)

        host.chat.configureNavbar()
        host.chat.configureNavbar()

        XCTAssertTrue(try closeItem(in: host.chat) === item)
        XCTAssertEqual(host.chat.navigationItem.leftBarButtonItems?.count, 1)
        XCTAssertFalse(host.chat.navigationItem.leftItemsSupplementBackButton)
        XCTAssertTrue(host.chat.navigationItem.titleView === host.chat.titleButton)
    }

    func testCloseReplacesOnlySecondaryAndClearsSelectionAndRetainedChatOwners() throws {
        try requirePad()
        let host = try makeHost()
        let item = try closeItem(in: host.chat)
        seedSelectedChat(in: host)
        let token = UUID()
        _ = host.list.chatNavigationSingleFlight.request(target: target(for: host.chat), token: token)
        host.list.updateChatOpenIntentOwnershipIfNeeded(
            target: target(for: host.chat),
            destinationIdentifier: ObjectIdentifier(host.chat),
            intent: .latest,
            navigationSource: .standard
        )
        capture(host, name: "chat-split-close-ipad-open")

        try activate(item)
        settle(host)

        let emptyNavigation = try XCTUnwrap(
            host.split.viewController(for: .secondary) as? UINavigationController
        )
        let empty = try XCTUnwrap(emptyNavigation.topViewController as? EmptyChatViewController)
        XCTAssertEqual(empty.kind, .emptyChat)
        XCTAssertTrue(host.split.viewController(for: .primary) === host.primary)
        XCTAssertTrue(host.split.viewController(for: .supplementary) === host.listNavigation)
        XCTAssertTrue(host.listNavigation.topViewController === host.list)
        XCTAssertNil(host.list.selectedChatIdentity)
        XCTAssertNil(host.list.tableView.indexPathForSelectedRow)
        XCTAssertNil(host.list.currentChatVC)
        XCTAssertNil(host.list.playerViewToolbar.delegate)
        XCTAssertNil(host.list.chatNavigationSingleFlight.state)
        XCTAssertNil(host.list.chatOpenIntentOwnership)
        XCTAssertNil(host.list.expandedSplitChatNavigationTransaction)
        if ContinuousSplitBackgroundExperiment.mode(for: host.split) == .sharedBackdrop {
            XCTAssertEqual(emptyNavigation.view.backgroundColor, .clear)
            XCTAssertEqual(empty.view.backgroundColor, .clear)
        }
        capture(host, name: "chat-split-close-ipad-empty")
    }

    func testStaleCloseItemCannotReplaceNewChat() throws {
        try requirePad()
        let host = try makeHost()
        let staleItem = try closeItem(in: host.chat)
        let replacement = makeChat(jid: "replacement@example.com")
        replacement.lastChatsDisplayDelegate = host.list
        let replacementNavigation = makeStackedDetailNavigationController(
            rootViewController: replacement,
            splitViewController: host.split
        )
        host.split.setViewController(replacementNavigation, for: .secondary)
        host.list.currentChatVC = replacement
        host.list.playerViewToolbar.delegate = replacement
        host.list.setSelectedChat(
            jid: replacement.jid, owner: replacement.owner,
            conversationType: replacement.conversationType, animated: false
        )
        settle(host)

        try activate(staleItem)

        XCTAssertTrue(host.split.viewController(for: .secondary) === replacementNavigation)
        XCTAssertTrue(replacementNavigation.topViewController === replacement)
        XCTAssertTrue(host.list.currentChatVC === replacement)
        XCTAssertTrue(host.list.playerViewToolbar.delegate === replacement)
        XCTAssertEqual(host.list.selectedChatIdentity?.jid, replacement.jid)
    }

    func testSearchAndSelectionKeepTheirItemsThenRestoreSameCloseItem() throws {
        try requirePad()
        let host = try makeHost()
        let item = try closeItem(in: host.chat)

        host.chat.isInSelectionMode.accept(true)
        NavigationBarItemOwnership.apply(
            to: host.chat.navigationItem,
            left: .item(host.chat.deleteSelectionBarButton),
            right: .item(host.chat.cancelSelectionBarButton), animated: false
        )
        host.chat.navigationItem.titleView = host.chat.selectionCountLabel
        host.chat.configureNavbar()
        try activate(item)
        XCTAssertTrue(host.chat.navigationItem.leftBarButtonItem === host.chat.deleteSelectionBarButton)
        XCTAssertTrue(host.detailNavigation.topViewController === host.chat)
        XCTAssertTrue(host.split.viewController(for: .secondary) === host.detailNavigation)

        host.chat.isInSelectionMode.accept(false)
        XCTAssertFalse(host.chat.restoreNormalNavbarAfterSelectionIfNeeded())
        XCTAssertTrue(try closeItem(in: host.chat) === item)

        host.chat.inSearchMode.accept(true)
        NavigationBarItemOwnership.apply(
            to: host.chat.navigationItem,
            left: NavigationBarItemOwnership.Assignment.none,
            right: NavigationBarItemOwnership.Assignment.none, animated: false
        )
        host.chat.navigationItem.titleView = nil
        host.chat.navigationItem.setHidesBackButton(true, animated: false)
        host.chat.configureNavbar()
        try activate(item)
        XCTAssertNil(host.chat.navigationItem.leftBarButtonItem)
        XCTAssertNil(host.chat.navigationItem.titleView)
        XCTAssertTrue(host.split.viewController(for: .secondary) === host.detailNavigation)

        host.chat.inSearchMode.accept(false)
        XCTAssertFalse(host.chat.restoreNormalNavbarAfterSearchIfNeeded())
        XCTAssertTrue(try closeItem(in: host.chat) === item)
        XCTAssertTrue(host.chat.navigationItem.titleView === host.chat.titleButton)
    }

    func testClosingCancelsPendingExpandedPreparationWithoutRestoringPreviousChat() throws {
        try requirePad()
        let host = try makeHost()
        let item = try closeItem(in: host.chat)
        let preparedChat = makeChat(jid: "prepared@example.com")
        var cancellationCount = 0
        var lateCompletionCount = 0
        let handle = StackedNavigationPresentationPreparationHandle(
            cancellation: { cancellationCount += 1 },
            completion: { lateCompletionCount += 1 }
        )
        let token = UUID()
        host.list.installExpandedSplitChatNavigationTransaction(
            token: token, target: target(for: preparedChat), destination: preparedChat,
            previousVisibleDetail: host.chat,
            previousSecondarySnapshot: .init(
                container: host.detailNavigation, topViewController: host.chat
            ),
            accountEpoch: .init(
                accountIdentifier: ObjectIdentifier(host.accountIdentity), isEnabled: true
            ),
            navigationSource: .standard, activationContext: nil
        )
        XCTAssertTrue(host.list.registerExpandedSplitChatNavigationPreparation(handle, token: token))

        try activate(item)
        handle.finish()

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(lateCompletionCount, 0)
        XCTAssertNil(host.list.expandedSplitChatNavigationTransaction)
        XCTAssertNil(host.list.currentChatVC)
        XCTAssertTrue(secondaryTop(in: host) is EmptyChatViewController)
    }

    func testChatListCanReopenSameChatAfterClose() throws {
        try requirePad()
        let host = try makeHost()
        let item = try closeItem(in: host.chat)
        seedSelectedChat(in: host)
        host.list.expandedSplitChatDestinationFactory = { self.makeChat() }
        host.list.chatOpenIntentDeliveryHandler = { _, _ in }

        try activate(item)
        settle(host)
        XCTAssertTrue(secondaryTop(in: host) is EmptyChatViewController)
        XCTAssertTrue(host.list.stackNewChat(
            owner: host.chat.owner, jid: host.chat.jid,
            conversationType: host.chat.conversationType
        ))
        settle(host)

        let reopened = try XCTUnwrap(secondaryTop(in: host) as? ChatViewController)
        XCTAssertFalse(reopened === host.chat)
        XCTAssertEqual(reopened.owner, host.chat.owner)
        XCTAssertEqual(reopened.jid, host.chat.jid)
        XCTAssertTrue(host.list.currentChatVC === reopened)
        XCTAssertEqual(host.list.selectedChatIdentity?.jid, reopened.jid)
        XCTAssertNotNil(try closeItem(in: reopened))
    }

    private func requirePad() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "Expanded chat closing is an iPad interaction")
    }

    private func closeItem(in chat: ChatViewController) throws -> UIBarButtonItem {
        let item = try XCTUnwrap(chat.navigationItem.leftBarButtonItem, "Expanded iPad chat must expose Close")
        XCTAssertEqual(item.accessibilityIdentifier, "chat.navigation.close")
        return item
    }

    private func activate(_ item: UIBarButtonItem) throws {
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil))
    }

    private func makeChat(jid: String = "close-contact@example.com") -> CloseFixtureChatViewController {
        let chat = CloseFixtureChatViewController()
        chat.owner = "close-owner@example.com"
        chat.jid = jid
        chat.conversationType = .regular
        chat.loadViewIfNeeded()
        chat.configureNavbar()
        XCTAssertNil(chat.navigationItem.leftBarButtonItem, "Preparation before split attachment must not invent a close route")
        XCTAssertFalse(chat.navigationItem.hidesBackButton)
        return chat
    }

    private func target(for chat: ChatViewController) -> LastChatsNavigationSingleFlightCoordinator.Target {
        .init(owner: chat.owner, jid: chat.jid, conversationType: chat.conversationType)
    }

    private func seedSelectedChat(in host: Host) {
        let chat = host.chat
        let row = LastChatsViewController.Datasource(
            jid: chat.jid, owner: chat.owner, username: "Alex", attributedUsername: nil,
            message: "Close returns to the empty state", date: nil, state: nil,
            isMute: false, isSynced: true, status: .offline, entity: .contact,
            conversationType: chat.conversationType, unread: 0, unreadString: nil,
            hasUnreadMention: false, color: .clear, isDraft: false,
            hasAttachment: false, userNickname: nil, isSystemMessage: false,
            isPinned: false, subRequest: false, isEncrypted: false,
            avatarUrl: nil, hasErrorInChat: false, updateTS: 0,
            isVerificationActionRequired: false, specialMessageKind: .none, avatars: []
        )
        let sections = LastChatsViewController.makeDatasourceSections(from: [row], showsSkeleton: false)
        host.list.showSkeleton.accept(false)
        host.list.setDatasource([row], sections: sections, showsSkeleton: false)
        host.list.tableView.reloadData()
        host.list.setSelectedChat(
            jid: chat.jid, owner: chat.owner, conversationType: chat.conversationType, animated: false
        )
        XCTAssertNotNil(host.list.tableView.indexPathForSelectedRow)
    }

    private func makeHost() throws -> Host {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let list = CloseFixtureLastChatsViewController()
        let chat = makeChat()
        let primary = UIViewController()
        primary.view.backgroundColor = .secondarySystemBackground
        let listNavigation = UINavigationController(rootViewController: list)
        let split = UISplitViewController(style: .tripleColumn)
        split.preferredSplitBehavior = .tile
        split.preferredDisplayMode = .twoBesideSecondary
        let detailNavigation = makeStackedDetailNavigationController(rootViewController: chat, splitViewController: split)
        split.setViewController(primary, for: .primary)
        split.setViewController(listNavigation, for: .supplementary)
        split.setViewController(detailNavigation, for: .secondary)
        list.currentChatVC = chat
        list.playerViewToolbar.delegate = chat
        chat.lastChatsDisplayDelegate = list
        list.chatNavigationRouteResolver = { _ in .splitDetailReplacement }
        let accountIdentity = NSObject()
        list.chatNavigationAccountEpochResolver = { _ in
            .init(accountIdentifier: ObjectIdentifier(accountIdentity), isEnabled: true)
        }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = CloseFixtureSplitHost(split: split)
        let host = Host(
            window: window, previousKeyWindow: previousKeyWindow, split: split,
            primary: primary, list: list, chat: chat, listNavigation: listNavigation,
            detailNavigation: detailNavigation, accountIdentity: accountIdentity
        )
        hosts.append(host)
        window.makeKeyAndVisible()
        split.show(.supplementary)
        settle(host)
        XCTAssertFalse(split.isCollapsed, "The fixture must retain separate supplementary and secondary columns")
        chat.titleLabel.attributedText = NSAttributedString(
            string: "Alex", attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .semibold)]
        )
        chat.statusLabel.text = "Online"
        chat.statusLabel.isHidden = false
        settle(host)
        return host
    }

    private func secondaryTop(in host: Host) -> UIViewController? {
        let secondary = host.split.viewController(for: .secondary)
        return (secondary as? UINavigationController)?.topViewController ?? secondary
    }

    private func settle(_ host: Host) {
        host.window.layoutIfNeeded()
        host.window.rootViewController?.view.layoutIfNeeded()
        host.split.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func capture(_ host: Host, name: String) {
        settle(host)
        let image = UIGraphicsImageRenderer(bounds: host.window.bounds).image { _ in
            XCTAssertTrue(host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct Host {
        let window: UIWindow
        let previousKeyWindow: UIWindow?
        let split: UISplitViewController
        let primary: UIViewController
        let list: CloseFixtureLastChatsViewController
        let chat: CloseFixtureChatViewController
        let listNavigation: UINavigationController
        let detailNavigation: UINavigationController
        let accountIdentity: NSObject
    }
}

private final class CloseFixtureSplitHost: UIViewController {
    private let split: UISplitViewController

    init(split: UISplitViewController) {
        self.split = split
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = UIView()
        let backdrop = ChatBackgroundBackdropView()
        backdrop.configure(document: AppearanceSettingsStore()?.load()
            ?? AppearanceSettingsDocument(profile: .default(accent: .systemBlue)))
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)
        addChild(split)
        setOverrideTraitCollection(UITraitCollection(horizontalSizeClass: .regular), forChild: split)
        view.addSubview(split.view)
        split.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.subviews.first?.frame = view.bounds
        // Keep the hierarchy expanded on the phone too, to prove device policy.
        split.view.frame = CGRect(x: 0, y: 0, width: max(1_100, view.bounds.width), height: view.bounds.height)
        split.view.layoutIfNeeded()
    }
}

private final class CloseFixtureLastChatsViewController: LastChatsViewController {
    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.addSubview(tableView)
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        navigationItem.title = "Chats"
    }

    override func viewDidLoad() {}
    override func viewWillAppear(_ animated: Bool) {}
    override func viewDidAppear(_ animated: Bool) {}
    override func viewWillDisappear(_ animated: Bool) {}
    override func viewDidDisappear(_ animated: Bool) {}
    override func viewDidLayoutSubviews() {}
    override func shouldChangeFrame() {}
}

private final class CloseFixtureChatViewController:
    ChatViewController, StackedNavigationPresentationPreparationControlling {
    override func loadView() {
        view = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 820))
        view.backgroundColor = .clear
    }

    override func viewDidLoad() {}
    override func viewWillAppear(_ animated: Bool) { configureNavbar() }
    override func viewDidAppear(_ animated: Bool) {}
    override func viewWillDisappear(_ animated: Bool) {}
    override func viewDidDisappear(_ animated: Bool) {}
    override func viewDidLayoutSubviews() {}
    override func viewSafeAreaInsetsDidChange() {}
    override func viewWillTransition(
        to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator
    ) {}
    override func shouldChangeFrame() {}

    func makeStackedNavigationPresentationPreparation(
        targetBounds: CGRect?, completion: @escaping () -> Void
    ) -> StackedNavigationPresentationPreparationHandle {
        loadViewIfNeeded()
        if let targetBounds { view.frame = targetBounds }
        let handle = StackedNavigationPresentationPreparationHandle(completion: completion)
        handle.finish()
        return handle
    }
}
