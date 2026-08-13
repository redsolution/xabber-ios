//
//  LastChatsPremiumPromotion.swift
//  xabber
//

import Foundation
import UIKit

enum LastChatsPremiumPromotionContent {
    static let key = "premium-promotion"
    static let iconName = "star.circle.fill"

    static var title: String {
        "The Full Experience".localizeString(
            id: "last_chats_premium_promotion_title",
            arguments: []
        )
    }

    static var subtitle: String {
        "Available with Premium.".localizeString(
            id: "last_chats_premium_promotion_subtitle",
            arguments: []
        )
    }
}

enum LastChatsPremiumPromotionVisibilityPolicy {
    static let suppressionInterval: TimeInterval = 7 * 24 * 60 * 60

    static func shouldShow(
        subscriptionsEnabled: Bool,
        hasActivePremiumInClient: Bool,
        hasPurchaseAccount: Bool,
        isRecentChatsFilter: Bool,
        suppressedUntil: Date?,
        now: Date = Date()
    ) -> Bool {
        guard subscriptionsEnabled,
              !hasActivePremiumInClient,
              hasPurchaseAccount,
              isRecentChatsFilter else {
            return false
        }
        return suppressedUntil.map { $0 <= now } ?? true
    }
}

enum LastChatsPremiumPromotionRefreshPolicy {
    static func nextEligibilityCheck(
        suppressedUntil: Date?,
        premiumExpires: Date?,
        now: Date = Date()
    ) -> Date? {
        [suppressedUntil, premiumExpires]
            .compactMap { $0 }
            .filter { $0 > now }
            .min()
    }
}

enum LastChatsPremiumPromotionAnimationPolicy {
    static let rowAnimation: UITableView.RowAnimation = .automatic

    static func shouldAnimateInsertion(
        wasVisible: Bool,
        isVisible: Bool,
        hasCompletedCurrentAppearance: Bool,
        isQuietModeActive: Bool
    ) -> Bool {
        !wasVisible
            && isVisible
            && hasCompletedCurrentAppearance
            && !isQuietModeActive
    }
}

final class LastChatsPremiumPromotionSuppressionStore {
    static let defaultsKey = "last_chats_premium_promotion_suppressed_until_timestamp"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = LastChatsPremiumPromotionSuppressionStore.appUserDefaults()) {
        self.userDefaults = userDefaults
    }

    var suppressedUntil: Date? {
        guard userDefaults.object(forKey: Self.defaultsKey) != nil else {
            return nil
        }
        let timestamp = userDefaults.double(forKey: Self.defaultsKey)
        guard timestamp > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    @discardableResult
    func suppress(from now: Date = Date()) -> Date {
        let date = now.addingTimeInterval(
            LastChatsPremiumPromotionVisibilityPolicy.suppressionInterval
        )
        userDefaults.set(date.timeIntervalSince1970, forKey: Self.defaultsKey)
        return date
    }

    private static func appUserDefaults() -> UserDefaults {
        let suiteName = CredentialsManager.uniqueAccessGroup()
        guard suiteName.isNotEmpty else {
            return .standard
        }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }
}

extension LastChatsViewController {
    internal func suppressPremiumPromotion() {
        premiumPromotionSuppressionStore.suppress()
        schedulePremiumPromotionEligibilityRefresh()
        canUpdateDataset = true
        runDatasetUpdateTask()
    }

    internal func schedulePremiumPromotionEligibilityRefresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.schedulePremiumPromotionEligibilityRefresh()
            }
            return
        }

        premiumPromotionEligibilityTimer?.invalidate()
        premiumPromotionEligibilityTimer = nil

        guard isAppeared,
              CommonConfigManager.shared.config.support_subscribtions,
              filter.value == .chats else {
            return
        }

        let now = Date()
        let nextCheck = LastChatsPremiumPromotionRefreshPolicy.nextEligibilityCheck(
            suppressedUntil: premiumPromotionSuppressionStore.suppressedUntil,
            premiumExpires: SubscribtionsManager.shared.getExpiresDate(),
            now: now
        )
        guard let nextCheck else {
            return
        }

        let timer = Timer(fire: nextCheck, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.premiumPromotionEligibilityTimer = nil
            self.canUpdateDataset = true
            self.runDatasetUpdateTask()
            self.schedulePremiumPromotionEligibilityRefresh()
        }
        timer.tolerance = min(30, max(1, nextCheck.timeIntervalSince(now) * 0.05))
        premiumPromotionEligibilityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    internal func invalidatePremiumPromotionEligibilityRefresh() {
        premiumPromotionEligibilityTimer?.invalidate()
        premiumPromotionEligibilityTimer = nil
    }

    @objc
    internal func premiumPromotionEligibilityDidChange(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.premiumPromotionEligibilityDidChange(notification)
            }
            return
        }
        guard isAppeared else {
            invalidatePremiumPromotionEligibilityRefresh()
            return
        }
        canUpdateDataset = true
        runDatasetUpdateTask()
        schedulePremiumPromotionEligibilityRefresh()
    }
}
