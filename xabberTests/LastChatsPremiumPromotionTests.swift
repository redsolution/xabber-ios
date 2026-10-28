import XCTest
import UIKit
import RealmSwift
@testable import xabber

@MainActor
final class LastChatsPremiumPromotionTests: XCTestCase {
    private let promotionKey = "premium-promotion"
    private let suppressionKey = "last_chats_premium_promotion_suppressed_until_timestamp"
    private var previousRealmConfiguration: Realm.Configuration!
    private var previousSubscriptionsEnabled = false
    private var previousSuppression: Any?
    private var promotionDefaults: UserDefaults!
    private var realm: Realm!

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "LastChatsPremiumPromotionTests-\(UUID().uuidString)"
        )
        realm = try Realm()
        previousSubscriptionsEnabled = CommonConfigManager.shared.config.support_subscribtions
        CommonConfigManager.shared.config.support_subscribtions = true
        let suiteName = CredentialsManager.uniqueAccessGroup()
        promotionDefaults = suiteName.isEmpty ? .standard : UserDefaults(suiteName: suiteName)
        previousSuppression = promotionDefaults.object(forKey: suppressionKey)
        promotionDefaults.removeObject(forKey: suppressionKey)
    }

    override func tearDownWithError() throws {
        promotionDefaults.set(previousSuppression, forKey: suppressionKey)
        CommonConfigManager.shared.config.support_subscribtions = previousSubscriptionsEnabled
        realm = nil
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        try super.tearDownWithError()
    }

    func testRecentChatsContainsOnlyConversationWhenPremiumOfferWouldBeEligible() throws {
        let controller = try makeController(includeChat: true)

        let rows = controller.mapDataset(
            in: realm,
            showsSpecialMessageBanners: true,
            dismissedInvitePrimaries: []
        )
        let sections = LastChatsViewController.makeDatasourceSections(from: rows, showsSkeleton: false)

        XCTAssertEqual(rows.map(\.jid), ["peer@example.test"])
        XCTAssertFalse(rows.contains { $0.jid == promotionKey })
        XCTAssertEqual(sections.map(\.kind), [.chats])
    }

    func testEmptyChatListDoesNotBecomePremiumOfferAfterSuppressionExpires() throws {
        let controller = try makeController(includeChat: false)
        promotionDefaults.set(Date().addingTimeInterval(-1).timeIntervalSince1970, forKey: suppressionKey)

        let rows = controller.mapDataset(
            in: realm,
            showsSpecialMessageBanners: true,
            dismissedInvitePrimaries: []
        )
        let sections = LastChatsViewController.makeDatasourceSections(from: rows, showsSkeleton: false)

        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(sections.map(\.kind), [.chats])
        XCTAssertTrue(sections[0].rows.isEmpty)
    }

    func testRemovingPremiumOfferPreservesRequestAndInviteBannersAndConversation() throws {
        let controller = try makeController(includeChat: true)
        let roster = RosterStorageItem()
        roster.owner = "owner@example.test"
        roster.jid = "requester@example.test"
        roster.primary = RosterStorageItem.genPrimary(jid: roster.jid, owner: roster.owner)
        roster.username = "Requester"
        let request = UINotificationStorageItem()
        request.owner = roster.owner
        request.jid = roster.jid
        request.primary = UINotificationStorageItem.genPrimary(owner: request.owner, jid: request.jid)
        request.kind_ = UINotificationStorageItem.Kind.contactRequest.rawValue
        request.isRead = false
        try realm.write {
            realm.add(roster)
            realm.add(request)
        }
        try GroupRepository(realm: realm).storeInvite(
            GroupInviteRecord(
                groupJID: "group@example.test",
                direction: .incoming,
                target: "inviter"
            ),
            owner: "owner@example.test"
        )

        let rows = controller.mapDataset(
            in: realm,
            showsSpecialMessageBanners: true,
            dismissedInvitePrimaries: []
        )
        let sections = LastChatsViewController.makeDatasourceSections(from: rows, showsSkeleton: false)

        XCTAssertEqual(rows.filter { $0.specialMessageKind == .contact }.count, 1)
        XCTAssertEqual(rows.filter { $0.specialMessageKind == .invite }.count, 1)
        XCTAssertEqual(rows.filter { $0.specialMessageKind == .none }.map(\.jid), ["peer@example.test"])
        XCTAssertFalse(rows.contains { $0.jid == promotionKey })
        XCTAssertEqual(sections.map(\.kind), [.specialMessages, .chats])
    }

    private func makeController(includeChat: Bool) throws -> LastChatsViewController {
        let account = AccountStorageItem()
        account.jid = "owner@example.test"
        let chat = LastChatsStorageItem()
        chat.owner = account.jid
        chat.jid = "peer@example.test"
        chat.conversationType = .regular
        chat.setPrimary(withOwner: account.jid)
        try realm.write {
            realm.add(account)
            if includeChat { realm.add(chat) }
        }
        let controller = LastChatsViewController()
        controller.enabledAccounts.accept([account.jid])
        controller.showSkeleton.accept(false)
        return controller
    }

    func testContainedNavigationModalAcceptsPageSheetOverride() {
        let presenter = RecordingModalPresenter()
        let root = UIViewController()
        let navigationController = UINavigationController(rootViewController: root)
        var currentController: UIViewController?

        let didPresent = presentContainedNavigationModal(
            navigationController,
            rootViewController: root,
            presentedContentViewController: root,
            from: presenter,
            modalPresentationStyle: .pageSheet,
            currentControllerAccess: ModalPresentationCurrentControllerAccess(
                get: { currentController },
                set: { currentController = $0 }
            )
        )

        XCTAssertTrue(didPresent)
        XCTAssertEqual(navigationController.modalPresentationStyle, .pageSheet)
        XCTAssertTrue(presenter.recordedPresentedViewController === navigationController)
    }
}

@MainActor
private final class RecordingModalPresenter: UIViewController {
    private(set) var recordedPresentedViewController: UIViewController?

    override func present(
        _ viewControllerToPresent: UIViewController,
        animated flag: Bool,
        completion: (() -> Void)? = nil
    ) {
        recordedPresentedViewController = viewControllerToPresent
        completion?()
    }
}
