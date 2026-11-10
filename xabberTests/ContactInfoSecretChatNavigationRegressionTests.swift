import XCTest
import UIKit
import RealmSwift
@testable import xabber

@MainActor
final class ContactInfoSecretChatNavigationRegressionTests: XCTestCase {
    private let owner = "juliet@example.com"
    private let peer = "romeo@example.com"

    func testModalContactInfoSecretChatOpensExactTargetWhenFirstFrameIsImmediatelyReady() throws {
        try exerciseProfileRoute(releasePreparationAfterListAppears: false)
    }

    func testModalContactInfoSecretChatOpensExactTargetWhenFirstFrameFinishesAfterListReveal() throws {
        try exerciseProfileRoute(releasePreparationAfterListAppears: true)
    }

    func testRootSelectionSupersedesUnrevealedChatWithoutLaterOpeningOldTarget() throws {
        try exerciseProfileRoute(releasePreparationAfterListAppears: false, directScenario: .replacementRoot)
    }

    func testLatestUnrevealedChatIntentOwnsExactDestinationAndConfiguresOnlyOnce() throws {
        try exerciseProfileRoute(releasePreparationAfterListAppears: false, directScenario: .latestTarget)
    }

    func testCancelledNativeBarrierDiscardsOwnedRootActivationWithoutLaterReplay() throws {
        try exerciseProfileRoute(releasePreparationAfterListAppears: false, directScenario: .cancelledBarrier)
    }

    private enum DirectScenario { case replacementRoot, latestTarget, cancelledBarrier }

    private func exerciseProfileRoute(releasePreparationAfterListAppears: Bool,
                                      directScenario: DirectScenario? = nil) throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        let previousInterface = CommonConfigManager.shared.config.interface_type
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ContactInfoSecretChatRoute-\(UUID().uuidString)"
        )
        CommonConfigManager.shared.config.interface_type = CommonConfigManager.InterfaceType.split.rawValue
        defer {
            Realm.Configuration.defaultConfiguration = previousConfiguration
            CommonConfigManager.shared.config.interface_type = previousInterface
        }
        let realm = try Realm()
        let account = AccountStorageItem()
        account.jid = owner
        account.enabled = true
        try realm.write { realm.add(account) }

        let scene = try requireHostedForegroundWindowScene()
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = CompactWindow(windowScene: scene)
        let menu = LeftMenuViewController()
        menu.previousSelectedKey = "contacts"
        let contacts = ContactsViewController()
        let contactsNavigation = UINavigationController(rootViewController: contacts)
        let chats = AppearanceObservedChats()
        let destination = ControlledChat()
        destination.finishesImmediately = !releasePreparationAfterListAppears
        destination.presenterSnapshot = { [weak chats, weak window] in
            guard let chats else { return [:] }
            let navigation = chats.navigationController
            return [
                "appeared": chats.isAppeared,
                "attached": chats.viewIfLoaded?.window === window,
                "top": navigation?.topViewController === chats,
                "foreground": chats.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
                "selectedHierarchy": LastChatsNavigationPresenterHierarchyPolicy.isInSelectedTabHierarchy(chats),
                "pushRoute": stackedNavigationRoute(for: chats) == .currentNavigationPush,
                "presentedModal": chats.presentedViewController != nil || navigation?.presentedViewController != nil,
                "nativeTransition": chats.transitionCoordinator != nil || navigation?.transitionCoordinator != nil
            ]
        }
        menu.chatsVc = chats
        menu.contactsVc = contacts
        chats.compactChatDestinationFactory = { destination }
        let split = UISplitViewController(style: .tripleColumn)
        let splitDelegate = try XCTUnwrap(AppRootCoordinator.active)
        MainSplitLayout.apply(to: split)
        split.preferredDisplayMode = .oneBesideSecondary
        split.preferredSplitBehavior = .displace
        split.displayModeButtonVisibility = .never
        split.delegate = splitDelegate
        split.setViewController(menu, for: .primary)
        split.setViewController(contactsNavigation, for: .supplementary)
        split.setViewController(EmptyChatViewController(), for: .secondary)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = split
        window.makeKeyAndVisible()
        split.loadViewIfNeeded()
        split.show(.supplementary)
        window.layoutIfNeeded()
        XCTAssertTrue(waitUntil { contacts.viewIfLoaded?.window === window })
        XCTAssertEqual(stackedNavigationRoute(for: split), .currentNavigationPush)
        defer {
            split.dismiss(animated: false)
            chats.resetChatNavigationTransaction(cancelled: true)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        if let directScenario {
            if directScenario == .cancelledBarrier {
                XCTAssertTrue(menu.didSelectRootScreenBy(key: "chat"))
                XCTAssertTrue(waitUntil { chats.didCompleteAppearance && chats.viewIfLoaded?.window === window })
                let target = LastChatsNavigationSingleFlightCoordinator.Target(
                    owner: owner, jid: peer, conversationType: .omemo
                )
                var activationCount = 0
                chats.isNavigationTransitionActive = true
                XCTAssertTrue(chats.deferRootChatActivationIfNeeded(target: target) {
                    activationCount += 1
                })
                XCTAssertEqual(activationCount, 0)

                chats.completeNavigationTransitionDeferral(cancelled: true)
                XCTAssertFalse(chats.isNavigationTransitionActive)
                XCTAssertEqual(activationCount, 0,
                               "a cancelled native barrier must discard its captured root operation")
                chats.completeNavigationTransitionDeferral(cancelled: false)
                XCTAssertEqual(activationCount, 0,
                               "a later normal completion must not resurrect the cancelled target")

                let activateFresh = { activationCount += 1 }
                if !chats.deferRootChatActivationIfNeeded(target: target, activate: activateFresh) {
                    activateFresh()
                }
                XCTAssertEqual(activationCount, 1)
                XCTAssertEqual(destination.preparationCount, 0)
                XCTAssertNil(chats.chatNavigationSingleFlight.state)
                return
            }
            var firstConfigurationCount = 0
            var latestConfigurationCount = 0
            XCTAssertTrue(menu.openChatlistWithChat(
                owner: owner, jid: peer, conversationType: .omemo,
                openMessageRequest: nil, navigationSource: .standard,
                configure: { _ in firstConfigurationCount += 1 }
            ))
            switch directScenario {
            case .replacementRoot:
                XCTAssertTrue(menu.didSelectRootScreenBy(key: "contacts"))
                XCTAssertTrue(waitUntil { contacts.viewIfLoaded?.window === window })
                XCTAssertEqual(menu.previousSelectedKey, "contacts")
                XCTAssertEqual(firstConfigurationCount, 0,
                               "superseded root activation must never configure its old destination")
                XCTAssertEqual(destination.preparationCount, 0)
                XCTAssertNil(chats.chatNavigationSingleFlight.state)
            case .cancelledBarrier:
                XCTFail("cancellation scenario must be handled before starting a chat")
            case .latestTarget:
                let latestOwner = "benvolio@example.com"
                let latestPeer = "mercutio@example.com"
                XCTAssertTrue(menu.openChatlistWithChat(
                    owner: latestOwner, jid: latestPeer, conversationType: .regular,
                    openMessageRequest: nil, navigationSource: .standard,
                    configure: { _ in latestConfigurationCount += 1 }
                ))
                XCTAssertTrue(waitUntil {
                    (split.viewController(for: .supplementary) as? UINavigationController)?
                        .topViewController === destination &&
                        chats.chatNavigationSingleFlight.state?.phase == .presented
                })
                XCTAssertEqual(destination.owner, latestOwner)
                XCTAssertEqual(destination.jid, latestPeer)
                XCTAssertEqual(destination.conversationType, .regular)
                XCTAssertEqual(destination.preparationCount, 1)
                XCTAssertEqual(firstConfigurationCount, 0)
                XCTAssertEqual(latestConfigurationCount, 1)
            }
            return
        }

        // This is the same modal ContactInfo route used by the Contacts table.
        let info = ContactInfoViewController()
        info.owner = owner
        info.jid = peer
        info.leftMenuDelegate = menu
        let infoNavigation = UINavigationController(rootViewController: info)
        contacts.present(infoNavigation, animated: false)
        XCTAssertTrue(waitUntil { info.viewIfLoaded?.window === window })

        info.openChat(conversationType: .omemo)

        XCTAssertTrue(waitUntil { destination.preparationCount == 1 },
                      "the ordinary profile action must prepare one exact destination")
        XCTAssertEqual(destination.owner, owner)
        XCTAssertEqual(destination.jid, peer)
        XCTAssertEqual(destination.conversationType, .omemo)
        if releasePreparationAfterListAppears {
            XCTAssertTrue(waitUntil { chats.isAppeared && chats.viewIfLoaded?.window === window })
            destination.finishPreparation()
        }
        XCTAssertTrue(waitUntil {
            guard let navigation = split.viewController(for: .supplementary) as? UINavigationController else { return false }
            return navigation.topViewController === destination &&
                chats.chatNavigationSingleFlight.state?.phase == .presented
        }, "switching from Contacts must open the requested chat, not leave only Chats list; presenterAtPreparation=\(destination.observedPresenterSnapshot)")
        let navigation = try XCTUnwrap(split.viewController(for: .supplementary) as? UINavigationController)
        XCTAssertIdentical(navigation.viewControllers.first, chats)
        XCTAssertIdentical(navigation.topViewController, destination)
        XCTAssertNil(contacts.presentedViewController)
        XCTAssertEqual(destination.preparationCount, 1)
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private final class AppearanceObservedChats: LastChatsViewController {
        private(set) var didCompleteAppearance = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            didCompleteAppearance = true
        }
    }

    private final class CompactWindow: UIWindow {
        override var traitCollection: UITraitCollection {
            UITraitCollection(traitsFrom: [super.traitCollection,
                                          UITraitCollection(horizontalSizeClass: .compact)])
        }
    }

    private final class ControlledChat: ChatViewController,
                                        StackedNavigationPresentationPreparationControlling {
        var finishesImmediately = false
        private(set) var preparationCount = 0
        var presenterSnapshot: (() -> [String: Bool])?
        private(set) var observedPresenterSnapshot: [String: Bool] = [:]
        private var handle: StackedNavigationPresentationPreparationHandle?
        func makeStackedNavigationPresentationPreparation(
            targetBounds: CGRect?, completion: @escaping () -> Void
        ) -> StackedNavigationPresentationPreparationHandle {
            preparationCount += 1
            observedPresenterSnapshot = presenterSnapshot?() ?? [:]
            let handle = StackedNavigationPresentationPreparationHandle(completion: completion)
            self.handle = handle
            if finishesImmediately { handle.finish() }
            return handle
        }
        func finishPreparation() {
            guard let handle else { XCTFail("matching destination preparation missing"); return }
            self.handle = nil
            handle.finish()
        }
    }
}
