import XCTest
import UIKit
@testable import xabber

@MainActor
final class LastChatsPremiumPromotionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testVisibilityShowsPromotionForRecentChatsWhenSubscriptionsAreEnabledAndClientHasNoPremium() {
        XCTAssertTrue(
            LastChatsPremiumPromotionVisibilityPolicy.shouldShow(
                subscriptionsEnabled: true,
                hasActivePremiumInClient: false,
                hasPurchaseAccount: true,
                isRecentChatsFilter: true,
                suppressedUntil: nil,
                now: now
            )
        )
    }

    func testVisibilityHidesPromotionWhenSubscriptionsAreDisabled() {
        XCTAssertFalse(
            LastChatsPremiumPromotionVisibilityPolicy.shouldShow(
                subscriptionsEnabled: false,
                hasActivePremiumInClient: false,
                hasPurchaseAccount: true,
                isRecentChatsFilter: true,
                suppressedUntil: nil,
                now: now
            )
        )
    }

    func testVisibilityHidesPromotionWhenAnyClientAccountHasPremium() {
        XCTAssertFalse(
            LastChatsPremiumPromotionVisibilityPolicy.shouldShow(
                subscriptionsEnabled: true,
                hasActivePremiumInClient: true,
                hasPurchaseAccount: true,
                isRecentChatsFilter: true,
                suppressedUntil: nil,
                now: now
            )
        )
    }

    func testVisibilityRequiresPurchaseAccountAndRecentChatsFilter() {
        XCTAssertFalse(
            LastChatsPremiumPromotionVisibilityPolicy.shouldShow(
                subscriptionsEnabled: true,
                hasActivePremiumInClient: false,
                hasPurchaseAccount: false,
                isRecentChatsFilter: true,
                suppressedUntil: nil,
                now: now
            )
        )
        XCTAssertFalse(
            LastChatsPremiumPromotionVisibilityPolicy.shouldShow(
                subscriptionsEnabled: true,
                hasActivePremiumInClient: false,
                hasPurchaseAccount: true,
                isRecentChatsFilter: false,
                suppressedUntil: nil,
                now: now
            )
        )
    }

    func testVisibilityResumesAtExactSuppressionExpiration() {
        XCTAssertFalse(
            LastChatsPremiumPromotionVisibilityPolicy.shouldShow(
                subscriptionsEnabled: true,
                hasActivePremiumInClient: false,
                hasPurchaseAccount: true,
                isRecentChatsFilter: true,
                suppressedUntil: now.addingTimeInterval(1),
                now: now
            )
        )
        XCTAssertTrue(
            LastChatsPremiumPromotionVisibilityPolicy.shouldShow(
                subscriptionsEnabled: true,
                hasActivePremiumInClient: false,
                hasPurchaseAccount: true,
                isRecentChatsFilter: true,
                suppressedUntil: now,
                now: now
            )
        )
    }

    func testRefreshPolicySchedulesTheEarliestFutureEligibilityBoundary() {
        let suppressionExpiration = now.addingTimeInterval(300)
        let premiumExpiration = now.addingTimeInterval(600)

        XCTAssertEqual(
            LastChatsPremiumPromotionRefreshPolicy.nextEligibilityCheck(
                suppressedUntil: suppressionExpiration,
                premiumExpires: premiumExpiration,
                now: now
            ),
            suppressionExpiration
        )
        XCTAssertNil(
            LastChatsPremiumPromotionRefreshPolicy.nextEligibilityCheck(
                suppressedUntil: now,
                premiumExpires: now.addingTimeInterval(-1),
                now: now
            )
        )
    }

    func testSuppressionStorePersistsAnAbsoluteTimestampForSevenDays() throws {
        let suiteName = "LastChatsPremiumPromotionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LastChatsPremiumPromotionSuppressionStore(userDefaults: defaults)

        let suppressedUntil = store.suppress(from: now)
        let reloadedStore = LastChatsPremiumPromotionSuppressionStore(userDefaults: defaults)

        XCTAssertEqual(
            suppressedUntil,
            now.addingTimeInterval(LastChatsPremiumPromotionVisibilityPolicy.suppressionInterval)
        )
        XCTAssertEqual(reloadedStore.suppressedUntil, suppressedUntil)
        XCTAssertEqual(
            defaults.double(forKey: LastChatsPremiumPromotionSuppressionStore.defaultsKey),
            suppressedUntil.timeIntervalSince1970
        )
    }

    func testSpecialMessageCellUsesPremiumCopyPurpleFilledStarAndCloseKey() {
        let cell = SpecialMessageTableViewCell(style: .default, reuseIdentifier: nil)

        cell.configurePremiumPromotion()

        XCTAssertEqual(cell.titleLabel.text, "The Full Experience")
        XCTAssertEqual(cell.subtitleLabel.text, "Available with Premium.")
        XCTAssertEqual(cell.titleLabel.text, LastChatsPremiumPromotionContent.title)
        XCTAssertEqual(cell.subtitleLabel.text, LastChatsPremiumPromotionContent.subtitle)
        XCTAssertNotNil(cell.leadingIconImageView.image)
        XCTAssertEqual(cell.leadingIconImageView.tintColor, .systemPurple)
        XCTAssertFalse(cell.leadingIconImageView.isHidden)
        XCTAssertTrue(cell.avatarStack.isHidden)
        XCTAssertEqual(cell.key, LastChatsPremiumPromotionContent.key)
        XCTAssertEqual(LastChatsPremiumPromotionContent.iconName, "star.circle.fill")
    }

    func testRuntimeAppearanceUsesClassicAutomaticTableInsertionAnimation() {
        XCTAssertEqual(LastChatsPremiumPromotionAnimationPolicy.rowAnimation, .automatic)
        XCTAssertTrue(
            LastChatsPremiumPromotionAnimationPolicy.shouldAnimateInsertion(
                wasVisible: false,
                isVisible: true,
                hasCompletedCurrentAppearance: true,
                isQuietModeActive: false
            )
        )
        XCTAssertFalse(
            LastChatsPremiumPromotionAnimationPolicy.shouldAnimateInsertion(
                wasVisible: false,
                isVisible: true,
                hasCompletedCurrentAppearance: false,
                isQuietModeActive: false
            )
        )
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
