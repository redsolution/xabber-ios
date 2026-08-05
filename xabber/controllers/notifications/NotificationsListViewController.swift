//
//  NotificationsListViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 18.03.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import RealmSwift
import RxSwift
import RxCocoa
import RxRealm
import XMPPFramework.XMPPJID

struct NotificationsListCoordinator {
    struct CategoryItem {
        let title: String
        let icon: String
        let key: String
        let subtitle: String
        let color: UIColor
        let isHeader: Bool
        let isSelectable: Bool
    }

    struct DerivedState {
        let listDatasource: [NotificationsListViewController.Datasource]
        let categoriesDatasource: [[CategoryItem]]
        let counters: NotificationsSupport.Counters
    }

    static func deriveState(
        realm: Realm,
        owners: [String],
        filter: NotificationsListViewController.Filter,
        filterAccount: String?,
        unreadOnly: Bool = false,
        searchQuery: String? = nil,
        headerBuilder: (NotificationsListViewController.Filter) -> NotificationsListViewController.Datasource?,
        listMapper: ([NotificationStorageItem], [String: RosterStorageItem]) -> [NotificationsListViewController.Datasource]
    ) -> DerivedState {
        let selectedOwners = filterAccount.map { [$0] } ?? owners
        let allNotifications = NotificationsSupport.notifications(
            in: realm,
            owners: selectedOwners,
            filter: filter,
            unreadOnly: unreadOnly
        ).toArray()
        let rosterMap = NotificationsSupport.rosterMap(in: realm, for: allNotifications)
        let notifications = allNotifications.filter {
            NotificationsSupport.notification($0, rosterMap: rosterMap, matchesSearchQuery: searchQuery)
        }
        let hasSearchQuery = NotificationsSupport.hasSearchQuery(searchQuery)
        var sections: [NotificationsListViewController.Datasource] = []
        if !hasSearchQuery, let header = headerBuilder(filter) {
            sections.append(header)
        }
        sections.append(contentsOf: listMapper(notifications, rosterMap))

        let counters = NotificationsSupport.unreadCounters(in: realm, owners: owners)
        let visibleCounters = NotificationsSupport.visibleCounters(in: realm, owners: owners)
        let categoriesDatasource = [
            [CategoryItem(title: "Notifications", icon: "bell.fill", key: "all", subtitle: "Manage security alerts, information updates, mentions, and other notifications.", color: .tintColor, isHeader: true, isSelectable: false)],
            [CategoryItem(title: "Notifications", icon: "bell", key: "all", subtitle: "\(visibleCounters.total)", color: .tintColor, isHeader: false, isSelectable: true)],
            [
                CategoryItem(title: "Security", icon: "checkerboard.shield", key: "security", subtitle: "\(visibleCounters.security)", color: .tintColor, isHeader: false, isSelectable: true),
                CategoryItem(title: "Information", icon: "info.circle", key: "info", subtitle: "\(visibleCounters.info)", color: .tintColor, isHeader: false, isSelectable: true),
                CategoryItem(title: "Mentions", icon: "at", key: "mentions", subtitle: "\(visibleCounters.mentions)", color: .tintColor, isHeader: false, isSelectable: true),
            ]
        ]

        return DerivedState(listDatasource: sections.filter { !$0.childs.isEmpty }, categoriesDatasource: categoriesDatasource, counters: counters)
    }
}

extension NotificationsListViewController: LeftMenuRootNavigationChromeRefreshable {
    func refreshLeftMenuRootNavigationChromeAfterModalDismiss() {
        UIView.performWithoutAnimation {
            configureBars(animated: false)
        }
    }
}

enum NotificationsBackAction: Equatable {
    case dismissModal
    case popNavigationStack
    case revealSplitList
    case selectChatsRoot
    case none
}

enum NotificationsBackPolicy {
    static func action(
        exitAction: NavigationExitAction,
        hasChatsRootFallback: Bool
    ) -> NotificationsBackAction {
        switch exitAction {
        case .dismissModal:
            return .dismissModal
        case .popNavigationStack:
            return .popNavigationStack
        case .revealSplitList:
            return .revealSplitList
        case .none:
            return hasChatsRootFallback ? .selectChatsRoot : .none
        }
    }
}

enum NotificationsDetailPresentation: Equatable {
    case modalContainedContactInfo
    case modalContainedDevices
    case mentionChat
    case none
}

enum NotificationsDetailPresentationPolicy {
    static func presentation(
        sectionKey: String,
        category: XMPPNotificationsManager.Category
    ) -> NotificationsDetailPresentation {
        switch sectionKey {
        case "subscribtion_requests":
            return .modalContainedContactInfo
        case "notifications":
            switch category {
            case .contact:
                return .modalContainedContactInfo
            case .device:
                return .modalContainedDevices
            case .mention:
                return .mentionChat
            case .info:
                return .none
            }
        default:
            return .none
        }
    }
}

enum NotificationsMentionRouteAction: Equatable {
    case openChat
    case ignore
}

enum NotificationsMentionRoutePolicy {
    static func action(isBlockedByUnrelatedPresentedModal: Bool) -> NotificationsMentionRouteAction {
        isBlockedByUnrelatedPresentedModal ? .ignore : .openChat
    }
}

enum NotificationsMentionOpenUnavailableReason: Equatable {
    case notificationUnavailable
    case sourceChatUnavailable
    case targetUnavailable
    case deletedTargetHasNoFollowingMention
}

enum NotificationsMentionOpenResolution: Equatable {
    case exact(ChatOpenMessageRequest, invalidatedNotificationPrimary: String?)
    case unavailable(NotificationsMentionOpenUnavailableReason)
}

struct NotificationsMentionOpenSelection: Equatable {
    let resolution: NotificationsMentionOpenResolution
    let selectedNotificationPrimary: String?
}

#if DEBUG || CHAT_PERFORMANCE_LAB
struct NotificationsMentionOpenAttemptDiagnostics: Equatable {
    let tappedNotificationPrimary: String
    let resolution: NotificationsMentionOpenResolution
    let selectedNotificationPrimary: String?
    let didNavigate: Bool
}

enum NotificationsMentionOpenRealmEntryPhase: Equatable {
    case authoritativeCategory
    case mentionResolution
}

struct NotificationsMentionOpenRealmEntryDiagnostics: Equatable {
    let notificationPrimary: String
    let phase: NotificationsMentionOpenRealmEntryPhase
    let claimWasHeld: Bool
}
#endif

enum NotificationsMentionOpenRouter {
    static func resolve(
        notificationPrimary: String,
        in realm: Realm
    ) -> NotificationsMentionOpenResolution {
        resolveSelection(
            notificationPrimary: notificationPrimary,
            in: realm
        ).resolution
    }

    static func resolveSelection(
        notificationPrimary: String,
        in realm: Realm
    ) -> NotificationsMentionOpenSelection {
        guard let notification = realm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: notificationPrimary
        ), notification.isMentionNotification else {
            return NotificationsMentionOpenSelection(
                resolution: .unavailable(.notificationUnavailable),
                selectedNotificationPrimary: nil
            )
        }

        guard let sourceChatJid = notification.sourceChatJid ?? notification.associatedJid,
              sourceChatJid.isNotEmpty else {
            return NotificationsMentionOpenSelection(
                resolution: .unavailable(.sourceChatUnavailable),
                selectedNotificationPrimary: nil
            )
        }

        let tappedOrder = orderKey(for: notification)
        reconcileLocallyMaterializedTargetIfNeeded(notification, in: realm)
        let tappedWasInvalidated = isInvalidated(notification)

        if !tappedWasInvalidated {
            guard let request = NotificationsListViewController.mentionOpenRequest(for: notification) else {
                return NotificationsMentionOpenSelection(
                    resolution: .unavailable(.targetUnavailable),
                    selectedNotificationPrimary: nil
                )
            }
            return NotificationsMentionOpenSelection(
                resolution: .exact(
                    request,
                    invalidatedNotificationPrimary: nil
                ),
                selectedNotificationPrimary: notification.primary
            )
        }

        let candidates = realm.objects(NotificationStorageItem.self)
            .filter(
                "owner == %@ AND category_ == %@ AND isRead == false AND associatedJid == %@",
                notification.owner,
                XMPPNotificationsManager.Category.mention.rawValue,
                sourceChatJid
            )
            .toArray()
            .filter {
                $0.primary != notification.primary
                    && $0.shouldShow
                    && ($0.sourceConversationType ?? .group) == .group
                    && ($0.sourceChatJid ?? $0.associatedJid) == sourceChatJid
                    && orderKey(for: $0) > tappedOrder
            }
            .sorted { orderKey(for: $0) < orderKey(for: $1) }

        for candidate in candidates {
            reconcileLocallyMaterializedTargetIfNeeded(candidate, in: realm)
            guard !isInvalidated(candidate),
                  let request = NotificationsListViewController.mentionOpenRequest(for: candidate) else {
                continue
            }
            MentionNotificationSync.refreshLastChatMentionId(
                owner: notification.owner,
                groupchatJid: sourceChatJid,
                in: realm
            )
            return NotificationsMentionOpenSelection(
                resolution: .exact(
                    request,
                    invalidatedNotificationPrimary: notification.primary
                ),
                selectedNotificationPrimary: candidate.primary
            )
        }

        MentionNotificationSync.refreshLastChatMentionId(
            owner: notification.owner,
            groupchatJid: sourceChatJid,
            in: realm
        )
        return NotificationsMentionOpenSelection(
            resolution: .unavailable(
                notification.mentionLinkStatus == .missing
                    ? .deletedTargetHasNoFollowingMention
                    : .targetUnavailable
            ),
            selectedNotificationPrimary: nil
        )
    }

    private static func isInvalidated(_ notification: NotificationStorageItem) -> Bool {
        notification.mentionLinkStatus == .missing
            || notification.mentionLinkStatus == .invalidated
            || !notification.shouldShow
    }

    private static func reconcileLocallyMaterializedTargetIfNeeded(
        _ notification: NotificationStorageItem,
        in realm: Realm
    ) {
        guard notification.mentionLinkStatus != .missing,
              notification.mentionLinkStatus != .invalidated,
              hasLocallyMaterializedStableTarget(notification, in: realm) else {
            return
        }
        _ = MentionNotificationSync.reconcile(notification: notification, in: realm)
    }

    private static func hasLocallyMaterializedStableTarget(
        _ notification: NotificationStorageItem,
        in realm: Realm
    ) -> Bool {
        guard let sourceChatJid = notification.sourceChatJid ?? notification.associatedJid,
              sourceChatJid.isNotEmpty else {
            return false
        }
        let conversationType = notification.sourceConversationType ?? .group

        if let archivedId = notification.sourceArchivedId,
           archivedId.isNotEmpty,
           realm.objects(MessageStorageItem.self)
            .filter(
                "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND archivedId == %@",
                notification.owner,
                sourceChatJid,
                conversationType.rawValue,
                archivedId
            )
            .first != nil {
            return true
        }

        if let messageId = notification.sourceMessageId,
           messageId.isNotEmpty,
           realm.objects(MessageStorageItem.self)
            .filter(
                "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND messageId == %@",
                notification.owner,
                sourceChatJid,
                conversationType.rawValue,
                messageId
            )
            .first != nil {
            return true
        }

        return false
    }

    private static func orderKey(
        for notification: NotificationStorageItem
    ) -> MentionOrderKey {
        MentionOrderKey(
            date: notification.sourceMessageDate ?? notification.date,
            primary: notification.primary
        )
    }

    private struct MentionOrderKey: Comparable {
        let date: Date
        let primary: String

        static func < (lhs: MentionOrderKey, rhs: MentionOrderKey) -> Bool {
            if lhs.date != rhs.date {
                return lhs.date < rhs.date
            }
            return lhs.primary < rhs.primary
        }
    }
}

enum NotificationsSupport {
    private static let sectionTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    struct Counters {
        let total: Int
        let security: Int
        let mentions: Int
        let info: Int
    }

    static func rosterKey(owner: String, jid: String) -> String {
        [owner, jid].prp()
    }

    static func categoryStrings(for filter: NotificationsListViewController.Filter) -> [String] {
        switch filter {
        case .all:
            return [
                XMPPNotificationsManager.Category.device.rawValue,
                XMPPNotificationsManager.Category.mention.rawValue,
                XMPPNotificationsManager.Category.info.rawValue,
            ]
        case .security:
            return [XMPPNotificationsManager.Category.device.rawValue]
        case .mentions:
            return [XMPPNotificationsManager.Category.mention.rawValue]
        case .info:
            return [XMPPNotificationsManager.Category.info.rawValue]
        }
    }

    static func notifications(
        in realm: Realm,
        owners: [String],
        filter: NotificationsListViewController.Filter = .all,
        unreadOnly: Bool = false,
        visibleOnly: Bool = true
    ) -> Results<NotificationStorageItem> {
        var results = realm.objects(NotificationStorageItem.self)
            .filter("owner IN %@ AND category_ IN %@", owners, categoryStrings(for: filter))

        if visibleOnly {
            results = results.filter("shouldShow == true")
        }

        if unreadOnly {
            results = results.filter("isRead == false")
        }

        return results.sorted(byKeyPath: "date", ascending: false)
    }

    static func counters(in realm: Realm, owners: [String], unreadOnly: Bool) -> Counters {
        let notifications = notifications(in: realm, owners: owners, unreadOnly: unreadOnly)
        return Counters(
            total: notifications.count,
            security: notifications.filter("category_ == %@", XMPPNotificationsManager.Category.device.rawValue).count,
            mentions: notifications.filter("category_ == %@", XMPPNotificationsManager.Category.mention.rawValue).count,
            info: notifications.filter("category_ == %@", XMPPNotificationsManager.Category.info.rawValue).count
        )
    }

    static func visibleCounters(in realm: Realm, owners: [String]) -> Counters {
        counters(in: realm, owners: owners, unreadOnly: false)
    }

    static func unreadCounters(in realm: Realm, owners: [String]) -> Counters {
        counters(in: realm, owners: owners, unreadOnly: true)
    }

    static func unreadVisibleCount(in realm: Realm, owners: [String]) -> Int {
        unreadCounters(in: realm, owners: owners).total
    }

    static func unreadVisibleCount(
        in realm: Realm,
        owners: [String],
        filter: NotificationsListViewController.Filter,
        filterAccount: String?
    ) -> Int {
        let selectedOwners = filterAccount.map { [$0] } ?? owners
        return notifications(in: realm, owners: selectedOwners, filter: filter, unreadOnly: true).count
    }

    static func hasSearchQuery(_ query: String?) -> Bool {
        normalizedSearchQuery(query).isNotEmpty
    }

    static func notification(
        _ item: NotificationStorageItem,
        rosterMap: [String: RosterStorageItem],
        matchesSearchQuery query: String?
    ) -> Bool {
        let normalizedQuery = normalizedSearchQuery(query)
        guard normalizedQuery.isNotEmpty else {
            return true
        }

        let categoryText: String
        switch item.category {
        case .device:
            categoryText = "security device"
        case .mention:
            categoryText = "mentions mention"
        case .info:
            categoryText = "information info"
        case .contact:
            categoryText = "contact subscription"
        }

        let values: [String?] = [
            titleText(for: item, rosterMap: rosterMap),
            messageText(for: item),
            item.jid,
            displayJid(for: item),
            item.owner,
            item.category.rawValue,
            categoryText
        ]

        return values.contains {
            ($0 ?? "").localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private static func normalizedSearchQuery(_ query: String?) -> String {
        (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rosterMap(in realm: Realm, for items: [NotificationStorageItem]) -> [String: RosterStorageItem] {
        let owners = Array(Set(items.map(\.owner)))
        let jids = Array(Set(items.compactMap { $0.originalSenderJid ?? $0.associatedJid ?? $0.jid }))

        guard owners.isNotEmpty, jids.isNotEmpty else {
            return [:]
        }

        return realm.objects(RosterStorageItem.self)
            .filter("owner IN %@ AND jid IN %@", owners, jids)
            .reduce(into: [String: RosterStorageItem]()) { partialResult, item in
                partialResult[rosterKey(owner: item.owner, jid: item.jid)] = item
            }
    }

    static func displayJid(for item: NotificationStorageItem) -> String {
        item.originalSenderJid ?? item.associatedJid ?? item.jid
    }

    static func displayName(for item: NotificationStorageItem, rosterMap: [String: RosterStorageItem]) -> String {
        let jid = displayJid(for: item)
        if let rosterItem = rosterMap[rosterKey(owner: item.owner, jid: jid)] {
            return rosterItem.displayName
        }
        if let nick = item.displayedNick?.trimmingCharacters(in: .whitespacesAndNewlines), nick.isNotEmpty {
            return nick
        }
        return JidManager.shared.prepareJid(jid: jid)
    }

    static func avatarUrl(for item: NotificationStorageItem, rosterMap: [String: RosterStorageItem]) -> String? {
        let jid = displayJid(for: item)
        return rosterMap[rosterKey(owner: item.owner, jid: jid)]?.avatarUrl
    }

    static func badgeIcon(for category: XMPPNotificationsManager.Category) -> String {
        switch category {
        case .device:
            return "badge-circle-big-security"
        case .mention:
            return "at"
        case .info:
            return "badge-circle-big-info"
        case .contact:
            return "badge-circle-big-bell"
        }
    }

    static func titleText(for item: NotificationStorageItem, rosterMap: [String: RosterStorageItem]) -> String {
        let name = displayName(for: item, rosterMap: rosterMap)
        switch item.category {
        case .device:
            return "New login to server \(name)"
        case .mention:
            return "\(name) mentioned you"
        case .info:
            return "Information from \(name)"
        case .contact:
            return name
        }
    }

    static func messageText(for item: NotificationStorageItem) -> String? {
        switch item.category {
        case .device:
            if let device = item.metadata?["device"] as? String,
               let client = item.metadata?["client"] as? String,
               device.isNotEmpty || client.isNotEmpty {
                return [client, device].filter(\.isNotEmpty).joined(separator: " • ")
            }
            return item.text ?? item.fallbackText
        case .mention:
            return item.text ?? item.fallbackText
        case .info:
            return (item.metadata?["text"] as? String) ?? item.text ?? item.fallbackText
        case .contact:
            return item.text ?? item.fallbackText
        }
    }

    static func sectionTitle(for date: Date) -> String {
        sectionTitleFormatter.string(from: date)
    }

}

class NotificationsListViewController: SimpleBaseViewController {

    internal static func mentionOpenRequest(for notification: NotificationStorageItem) -> ChatOpenMessageRequest? {
        let chatJid = notification.sourceChatJid ?? notification.associatedJid ?? notification.jid
        guard chatJid.isNotEmpty else {
            return nil
        }

        return ChatOpenMessageRequest(
            chatJid: chatJid,
            owner: notification.owner,
            conversationType: notification.sourceConversationType ?? .group,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: notification.sourceArchivedId,
                messageId: notification.sourceMessageId,
                authorId: notification.sourceSenderId,
                bodyFingerprint: notification.sourceBodyFingerprint,
                sourceDate: notification.sourceMessageDate ?? notification.date
            ),
            highlight: true,
            markReadOnVisible: true,
            source: .mentionNotification
        )
    }
    
    let emptyView: EmptyStateView = {
        let view = EmptyStateView()
        
        return view
    }()
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        view.separatorStyle = .singleLine
        view.rowHeight = UITableView.automaticDimension
        view.estimatedRowHeight = 88
        view.cellLayoutMarginsFollowReadableWidth = true
        view.applyContinuousSplitInsetGroupedAppearance()
        
        view.register(NotificationItemCell.self, forCellReuseIdentifier: NotificationItemCell.cellName)
        view.register(NotificationsSubscribtionsListViewController.ContactItemCell.self, forCellReuseIdentifier: NotificationsSubscribtionsListViewController.ContactItemCell.cellName)
        view.register(MenuItemHeaderTableCell.self, forCellReuseIdentifier: MenuItemHeaderTableCell.cellName)
        
        view.allowsSelection = true
        
        return view
    }()
        
    class Datasource {
        let title: String
        let key: String
        var childs: [DatasourceChild]
        
        init(title: String, key: String, childs: [DatasourceChild]) {
            self.title = title
            self.key = key
            self.childs = childs
        }
    }
    
    class DatasourceChild {
        var primary: String
        var category: XMPPNotificationsManager.Category
        var owner: String
        var jid: String
        var title: NSAttributedString
        var message: NSAttributedString?
        var key: String?
        var date: Date
        var avatarUrl: String?
        var badgeIcon: String
        var isRead: Bool
        var isHeader: Bool
        
        init(primary: String, category: XMPPNotificationsManager.Category, owner: String, jid: String, title: NSAttributedString, message: NSAttributedString? = nil, key: String? = nil, date: Date, avatarUrl: String? = nil, badgeIcon: String, isRead: Bool, isHeader: Bool) {
            self.primary = primary
            self.category = category
            self.owner = owner
            self.jid = jid
            self.title = title
            self.message = message
            self.key = key
            self.date = date
            self.avatarUrl = avatarUrl
            self.badgeIcon = badgeIcon
            self.isRead = isRead
            self.isHeader = isHeader
        }
    }
    
    var datasource: [Datasource] = []
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(self.tableView)
        self.tableView.fillSuperviewWithOffset(top: 0, bottom: 0, left: 0, right: 0)
        refreshContinuousSplitBackgroundAppearance()
        
        self.emptyView.isHidden = !self.emptyScreenShowObserver.value
        self.view.addSubview(self.emptyView)
        self.emptyView.fillSuperview()
        self.view.bringSubviewToFront(self.emptyView)
        refreshContinuousSplitBackgroundAppearance()
    }
    
    override func configure() {
        super.configure()
        applyNotificationsNavigationAppearance()
        NavigationLargeTitlePolicy.apply(to: self)
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.title = nil
        } else {
        self.title = "Notifications"
        }
        refreshContinuousSplitBackgroundAppearance()
        self.tableView.dataSource = self
        self.tableView.delegate = self
    }

    private func applyNotificationsNavigationAppearance() {
        NativeSectionNavigationBarPolicy.apply(to: self)
    }

    internal func refreshContinuousSplitBackgroundAppearance() {
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(self)
        tableView.applyContinuousSplitInsetGroupedAppearance()

        switch ContinuousSplitBackgroundExperiment.mode(for: self) {
        case .sharedBackdrop:
            emptyView.backgroundColor = .clear
            emptyView.isOpaque = false
        case .inactive, .deferred, .stockCompact:
            emptyView.backgroundColor = .systemBackground
            emptyView.isOpaque = true
        }
    }
    
    override func loadDatasource() {
        super.loadDatasource()
        self.scheduleDatasourceReload()
    }
    
    var emptyScreenShowObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    enum Filter: String {
        case all = "all"
        case security = "security"
        case mentions = "mentions"
        case info = "info"
    }

    internal static func hasNotificationRows(_ datasource: [Datasource]) -> Bool {
        datasource.contains { section in
            section.childs.contains { !$0.isHeader }
        }
    }

    internal static func emptyStateDescriptor(
        filter: Filter,
        hasResolvedSnapshot: Bool,
        isLoading: Bool,
        hasNotificationRows: Bool
    ) -> CoreListEmptyStateDescriptor? {
        guard hasResolvedSnapshot, !isLoading, !hasNotificationRows else {
            return nil
        }

        switch filter {
        case .all:
            return CoreListEmptyStateDescriptor(
                iconSystemName: "bell.circle",
                title: "No notifications yet".localizeString(id: "notifications_empty_title", arguments: []),
                subtitle: "Security alerts, mentions, and updates will appear here.".localizeString(id: "notifications_empty_subtitle", arguments: []),
                buttonTitle: nil,
                buttonAccessibilityIdentifier: nil,
                action: nil
            )
        case .security:
            return CoreListEmptyStateDescriptor(
                iconSystemName: "shield",
                title: "No security notifications yet".localizeString(id: "notifications_empty_security_title", arguments: []),
                subtitle: "Security alerts for your account will appear here.".localizeString(id: "notifications_empty_security_subtitle", arguments: []),
                buttonTitle: nil,
                buttonAccessibilityIdentifier: nil,
                action: nil
            )
        case .mentions:
            return CoreListEmptyStateDescriptor(
                iconSystemName: "at.circle",
                title: "No mentions yet".localizeString(id: "notifications_empty_mentions_title", arguments: []),
                subtitle: "When someone mentions you in a chat, it will appear here.".localizeString(id: "notifications_empty_mentions_subtitle", arguments: []),
                buttonTitle: nil,
                buttonAccessibilityIdentifier: nil,
                action: nil
            )
        case .info:
            return CoreListEmptyStateDescriptor(
                iconSystemName: "info.circle",
                title: "No information notifications yet".localizeString(id: "notifications_empty_info_title", arguments: []),
                subtitle: "Updates and system messages will appear here.".localizeString(id: "notifications_empty_info_subtitle", arguments: []),
                buttonTitle: nil,
                buttonAccessibilityIdentifier: nil,
                action: nil
            )
        }
    }
    
    var filter: BehaviorRelay<Filter> = BehaviorRelay(value: .all)
    var filterAccount: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    var unreadOnly: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    var filterMenu: UIMenu = UIMenu()
    internal let bottomSearchHostView = BottomSearchHostView(frame: .zero)
    internal let bottomOverlayInsetCoordinator = BottomOverlayInsetCoordinator()
    internal let notificationsCompactBottomBarView = FloatingBottomBarView(frame: .zero)
    private let datasourceQueue = DispatchQueue(label: "com.xabber.notifications.datasource", qos: .userInitiated)
    private var datasourceGeneration: Int = 0
    private var notificationSearchQuery: String = ""
    private var lastConfiguredBarsState: (filter: Filter, account: String?, unreadOnly: Bool)?
    private var claimedMentionOpenNotificationPrimaries: Set<String> = []

#if DEBUG || CHAT_PERFORMANCE_LAB
    internal var mentionOpenAttemptObserverForTests:
        ((NotificationsMentionOpenAttemptDiagnostics) -> Void)?
    internal var mentionOpenDuplicateDropObserverForTests:
        ((String) -> Void)?
    internal var mentionOpenRealmEntryObserverForTests:
        ((NotificationsMentionOpenRealmEntryDiagnostics) -> Void)?

    internal var claimedMentionOpenNotificationPrimariesForTests: Set<String> {
        claimedMentionOpenNotificationPrimaries
    }

    /// Applies a production-derived datasource in focused entrypoint tests.
    /// Canonical P13 evidence must still use the real async datasource path.
    internal func applyMentionOpenDatasourceForTests(
        _ datasource: [Datasource]
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.datasource = datasource
        tableView.reloadData()
        reconcileMentionOpenClaimsAfterApplying(datasource)
    }
#endif

    internal final var isNotificationsCompactBottomBarHidden: Bool {
        notificationsCompactBottomBarView.superview == nil || notificationsCompactBottomBarView.isHidden
    }

    internal final var notificationsCompactBottomBarCenterTitle: String? {
        notificationsCompactBottomBarView.centerButton.title(for: .normal)
    }

    internal final var notificationsCompactBottomBarFilterButton: UIButton {
        notificationsCompactBottomBarView.leftButton
    }

    internal final var notificationsCompactBottomBarPrimaryButton: UIButton {
        notificationsCompactBottomBarView.centerButton
    }

    internal final var isNotificationsCompactUnreadFilterActive: Bool {
        unreadOnly.value
    }

    internal final var isNotificationsCompactReadAllButtonEnabled: Bool {
        notificationsCompactBottomBarView.centerButton.isEnabled
    }

    private var shouldUseNotificationsCompactBottomBar: Bool {
        effectiveHorizontalSizeClass == .compact
    }

    private var effectiveHorizontalSizeClass: UIUserInterfaceSizeClass {
        if let navigationSizeClass = navigationController?.traitCollection.horizontalSizeClass,
           navigationSizeClass != .unspecified {
            return navigationSizeClass
        }
        return traitCollection.horizontalSizeClass
    }

    struct DatasourceSnapshot {
        let datasource: [Datasource]
        let hasResolvedSnapshot: Bool
    }

    internal static func enabledOwnerJids(in realm: Realm) -> [String] {
        realm.objects(AccountStorageItem.self)
            .filter("enabled == true")
            .toArray()
            .compactMap { $0.jid }
    }

    private func matchingEnabledOwners(in realm: Realm) -> [String] {
        let owners = Self.enabledOwnerJids(in: realm)
        if let filterAccount = filterAccount.value {
            return owners.contains(filterAccount) ? [filterAccount] : []
        }
        return owners
    }

    private func matchingUnreadNotificationCount() -> Int {
        do {
            let realm = try WRealm.safe()
            return NotificationsSupport.unreadVisibleCount(
                in: realm,
                owners: matchingEnabledOwners(in: realm),
                filter: filter.value,
                filterAccount: nil
            )
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
            return 0
        }
    }

    internal final func configureNotificationsBottomSearchIfNeeded() {
        guard isViewLoaded else { return }

        guard shouldUseNotificationsCompactBottomBar else {
            let hadSearchQuery = notificationSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty
            if bottomSearchHostView.superview != nil {
                bottomSearchHostView.setExpanded(false, animated: false)
                bottomSearchHostView.setQuery(nil, notify: false)
                bottomSearchHostView.isHidden = true
            }
            notificationSearchQuery = ""
            notificationsCompactBottomBarView.isHidden = true
            updateNotificationsTableInsetsForBottomSearch()
            if hadSearchQuery {
                scheduleDatasourceReload()
            }
            return
        }

        BottomInPlaceSearchHostHelper.install(
            searchView: bottomSearchHostView,
            in: view
        )
        bottomSearchHostView.isHidden = false
        bottomSearchHostView.searchTextField.placeholder = "Search".localizeString(id: "search", arguments: [])
        bottomSearchHostView.onTransitionPhaseChanged = { [weak self] _ in
            self?.notificationBottomSearchPresentationStateDidChange()
        }
        bottomSearchHostView.onBegin = nil
        bottomSearchHostView.onQueryChanged = { [weak self] query in
            guard let self else { return }
            self.notificationSearchQuery = query ?? ""
            self.scheduleDatasourceReload()
        }
        bottomSearchHostView.onCancel = { [weak self] in
            guard let self else { return }
            self.notificationSearchQuery = ""
            self.scheduleDatasourceReload()
        }
        updateNotificationsTableInsetsForBottomSearch()
    }

    private func notificationBottomSearchPresentationStateDidChange() {
        updateNotificationsCompactBottomBarState()
        if isViewLoaded {
            view.bringSubviewToFront(bottomSearchHostView)
        }
    }

    internal final func installNotificationsCompactBottomBarIfNeeded() {
        guard isViewLoaded, shouldUseNotificationsCompactBottomBar else { return }
        guard bottomSearchHostView.superview != nil else { return }

        guard notificationsCompactBottomBarView.superview == nil else {
            view.bringSubviewToFront(notificationsCompactBottomBarView)
            view.bringSubviewToFront(bottomSearchHostView)
            return
        }

        view.addSubview(notificationsCompactBottomBarView)
        notificationsCompactBottomBarView.leftButton.addTarget(
            self,
            action: #selector(onNotificationsCompactUnreadFilterButtonTouchUpInside),
            for: .touchUpInside
        )
        notificationsCompactBottomBarView.centerButton.addTarget(
            self,
            action: #selector(onNotificationsCompactReadAllButtonTouchUpInside),
            for: .touchUpInside
        )

        NSLayoutConstraint.activate([
            notificationsCompactBottomBarView.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -FloatingBottomBarView.Metrics.bottomOffset
            ),
            notificationsCompactBottomBarView.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: FloatingBottomBarView.Metrics.horizontalInset
            ),
            notificationsCompactBottomBarView.trailingAnchor.constraint(
                equalTo: bottomSearchHostView.collapsedButton.leadingAnchor,
                constant: -NativeGlassBarStyle.interItemSpacing
            ),
            notificationsCompactBottomBarView.heightAnchor.constraint(equalToConstant: FloatingBottomBarView.Metrics.height)
        ])

        view.bringSubviewToFront(notificationsCompactBottomBarView)
        view.bringSubviewToFront(bottomSearchHostView)
    }

    internal final func updateNotificationsCompactBottomBarState() {
        guard isViewLoaded else { return }

        if shouldUseNotificationsCompactBottomBar {
            configureNotificationsBottomSearchIfNeeded()
            installNotificationsCompactBottomBarIfNeeded()
        } else {
            configureNotificationsBottomSearchIfNeeded()
        }

        let hasMatchingUnreadNotifications = matchingUnreadNotificationCount() > 0
        if !hasMatchingUnreadNotifications, unreadOnly.value {
            unreadOnly.accept(false)
        }

        let isActive = unreadOnly.value
        notificationsCompactBottomBarView.leftButton.accessibilityIdentifier = "notifications_unread_filter_button"
        notificationsCompactBottomBarView.leftButton.accessibilityLabel = "Unread notifications filter"
        notificationsCompactBottomBarView.updateLeftButton(
            imageName: isActive ? "bell.badge.fill" : "bell",
            isActive: isActive
        )

        let readAllTitle = "Read all".localizeString(id: "notifications_read_all_button", arguments: [])
        notificationsCompactBottomBarView.setCenterButtonTitle(
            readAllTitle,
            accessibilityIdentifier: "notifications_read_all_bottom_button",
            accessibilityLabel: readAllTitle
        )
        notificationsCompactBottomBarView.applyActionPresentation(
            .init(
                isLeftVisible: hasMatchingUnreadNotifications,
                isCenterVisible: hasMatchingUnreadNotifications
            )
        )
        notificationsCompactBottomBarView.isHidden = !shouldUseNotificationsCompactBottomBar ||
            bottomSearchHostView.hidesUnderlyingActions
        notificationsCompactBottomBarView.refreshAppearance()

        if notificationsCompactBottomBarView.superview != nil {
            view.bringSubviewToFront(notificationsCompactBottomBarView)
            view.bringSubviewToFront(bottomSearchHostView)
        }
        updateNotificationsTableInsetsForBottomSearch()
    }

    internal final func updateNotificationsTableInsetsForBottomSearch() {
        bottomOverlayInsetCoordinator.apply(
            to: tableView,
            in: view,
            overlays: [notificationsCompactBottomBarView, bottomSearchHostView]
        )
    }

    @objc
    private final func onNotificationsCompactUnreadFilterButtonTouchUpInside(_ sender: UIButton) {
        unreadOnly.accept(!unreadOnly.value)
        updateNotificationsCompactBottomBarState()
    }

    @objc
    private final func onNotificationsCompactReadAllButtonTouchUpInside(_ sender: UIButton) {
        markMatchingUnreadNotificationsRead()
    }
    
    func configureBars(animated: Bool = false) {
        lastConfiguredBarsState = (filter: filter.value, account: filterAccount.value, unreadOnly: unreadOnly.value)
        let button = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), style: .plain, target: self, action: nil)
        button.accessibilityIdentifier = "notifications_filter_menu_button"
        var childs: [UIMenuElement] = [
            UIAction(
                title: "All",
                image: imageLiteral("bell"),
                identifier: .none,
                discoverabilityTitle: "Displays all notifications",
                attributes: [],
                state: filter.value == .all ? .on : .off,
                handler: { action in
                    self.shouldFilterBy(category: Filter.all.rawValue)
                }),
            UIAction(
                title: "Security",
                image: imageLiteral("shield"),
                identifier: .none,
                discoverabilityTitle: nil,
                attributes: [],
                state: filter.value == .security ? .on : .off,
                handler: { action in
                    self.shouldFilterBy(category: Filter.security.rawValue)
                }),
            UIAction(
                title: "Mentions",
                image: imageLiteral("at"),
                identifier: .none,
                discoverabilityTitle: nil,
                attributes: [],
                state: filter.value == .mentions ? .on : .off,
                handler: { action in
                    self.shouldFilterBy(category: Filter.mentions.rawValue)
                }),
            UIAction(
                title: "Information",
                image: imageLiteral("info.circle"),
                identifier: .none,
                discoverabilityTitle: nil,
                attributes: [],
                state: filter.value == .info ? .on : .off,
                handler: { action in
                    self.shouldFilterBy(category: Filter.info.rawValue)
                }),
        ]
        switch CommonConfigManager.shared.interfaceType {
        case .tabs:
            break
        case .split:
            if UIDevice.current.userInterfaceIdiom == .pad {
                childs = []
            }
        }
        do {
            let realm = try WRealm.safe()
            let accountActions: [UIMenuElement] = realm
                .objects(AccountStorageItem.self)
                .filter("enabled == true")
                .toArray()
                .compactMap ({
                    item in
                    return UIAction(
                        title: item.username,
                        image: imageLiteral("person.crop.circle"),
                        identifier: .none,
                        discoverabilityTitle: nil,
                        attributes: [],
                        state: self.filterAccount.value == item.jid ? .on : .off,
                        handler: { action in
                            self.shouldFilterBy(account: item.jid)
                        }
                    )
                })

            if accountActions.count > 1 {
                childs.append(
                    UIMenu(
                        title: "Accounts",
                        options: [.displayInline],
                        children: accountActions
                    )
                )
            }
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
        
        filterMenu = UIMenu(children: childs)
        
        button.menu = filterMenu
        
        let readAllNotificationsButton = UIBarButtonItem(image: imageLiteral("checkmark"), style: .plain, target: self, action: #selector(onReadAllNotifications))
        readAllNotificationsButton.accessibilityIdentifier = "notifications_mark_all_read_button"
        updateNotificationsCompactBottomBarState()
        if shouldUseNotificationsCompactBottomBar {
            self.navigationItem.setRightBarButtonItems([], animated: animated)
            return
        }
        if childs.isEmpty {
            self.navigationItem.setRightBarButtonItems([readAllNotificationsButton], animated: animated)
        } else {
            self.navigationItem.setRightBarButtonItems([button, readAllNotificationsButton], animated: animated)
        }
    }
        
    @objc
    private func onReadAllNotifications(_ sender: AnyObject) {
        markMatchingUnreadNotificationsRead()
    }

    private func markMatchingUnreadNotificationsRead() {
        self.datasource.forEach {
            $0.childs.forEach {
                $0.isRead = true
            }
        }
        self.tableView.visibleCells.forEach {
            ($0 as? NotificationsSubscribtionsListViewController.ContactItemCell)?.updateReadState(true, animated: true)
            ($0 as? NotificationItemCell)?.updateReadState(true, animated: true)
        }
        do {
            let realm = try WRealm.safe()
            let owners = matchingEnabledOwners(in: realm)
            let targetPrimaries = NotificationsSupport.notifications(
                in: realm,
                owners: owners,
                filter: self.filter.value,
                unreadOnly: true
            ).map(\.primary)
            var messagePrimariesByOwner: [String: Set<String>] = [:]
            var affectedChatsByOwner: [String: Set<String>] = [:]
            var affectedOwners = Set<String>()
            try realm.write {
                targetPrimaries.forEach { primary in
                    guard let item = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: primary),
                          item.isRead == false else {
                        return
                    }
                    item.isRead = true
                    affectedOwners.insert(item.owner)
                    guard item.category == .mention else {
                        return
                    }
                    if let sourceChatJid = MentionNotificationSync.groupchatJidForLastChatMentionState(from: item) {
                        affectedChatsByOwner[item.owner, default: []].insert(sourceChatJid)
                    }
                    let result = MentionNotificationSync.reconcile(notification: item, in: realm)
                    if let messagePrimary = result.linkedMessagePrimaryToMarkRead {
                        messagePrimariesByOwner[item.owner, default: []].insert(messagePrimary)
                    }
                }
                affectedChatsByOwner.forEach { owner, chats in
                    MentionNotificationSync.refreshLastChatMentionIds(owner: owner, groupchatJids: chats, in: realm)
                }
            }
            messagePrimariesByOwner.forEach { owner, primaries in
                primaries.forEach {
                    AccountManager.shared.find(for: owner)?.messages.readMessage($0, last: false)
                }
            }
            AccountManager.shared.users
                .filter { affectedOwners.contains($0.jid) }
                .forEach { user in
                if user.xmppStream.isAuthenticated {
                    user.action { user, stream in
                        user.notifications.readAll(stream)
                    }
                }
            }
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
        updateNotificationsCompactBottomBarState()
        scheduleDatasourceReload()
    }

    private func headerSection(for filter: Filter) -> Datasource? {
        switch filter {
        case .all:
            return nil
        case .security:
            return Datasource(title: "", key: "", childs: [
                DatasourceChild(
                    primary: "security_item_header",
                    category: .device,
                    owner: "",
                    jid: "",
                    title: NSAttributedString(string: "Security"),
                    message: NSAttributedString(string: "Notifications about new logins, device changes, and activity on your account."),
                    key: nil,
                    date: Date(),
                    avatarUrl: nil,
                    badgeIcon: "custom.shield.pattern.checkered.square.fill",
                    isRead: true,
                    isHeader: true
                )
            ])
        case .mentions:
            return Datasource(title: "", key: "", childs: [
                DatasourceChild(
                    primary: "mention_item_header",
                    category: .mention,
                    owner: "",
                    jid: "",
                    title: NSAttributedString(string: "Mentions"),
                    message: NSAttributedString(string: "Alerts when you are tagged in conversations, helping you stay aware of relevant discussions."),
                    key: nil,
                    date: Date(),
                    avatarUrl: nil,
                    badgeIcon: "custom.at.square.fill",
                    isRead: true,
                    isHeader: true
                )
            ])
        case .info:
            return Datasource(title: "", key: "", childs: [
                DatasourceChild(
                    primary: "info_item_header",
                    category: .info,
                    owner: "",
                    jid: "",
                    title: NSAttributedString(string: "Information"),
                    message: NSAttributedString(string: "Updates, tips, and system messages from server operators and various contacts to keep you informed about features, maintenance, and app-related news."),
                    key: nil,
                    date: Date(),
                    avatarUrl: nil,
                    badgeIcon: "info.square.fill",
                    isRead: true,
                    isHeader: true
                )
            ])
        }
    }

    private func notificationItemToDatasourceChild(_ item: NotificationStorageItem, rosterMap: [String: RosterStorageItem]) -> DatasourceChild? {
        guard item.category != .contact else {
            return nil
        }

        let title = NSAttributedString(
            string: NotificationsSupport.titleText(for: item, rosterMap: rosterMap),
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
        )
        let message = NotificationsSupport.messageText(for: item).map {
            NSAttributedString(
                string: $0,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel
                ]
            )
        }

        return DatasourceChild(
            primary: item.primary,
            category: item.category,
            owner: item.owner,
            jid: item.jid,
            title: title,
            message: message,
            key: item.jid,
            date: item.date,
            avatarUrl: NotificationsSupport.avatarUrl(for: item, rosterMap: rosterMap),
            badgeIcon: NotificationsSupport.badgeIcon(for: item.category),
            isRead: item.isRead,
            isHeader: false
        )
    }

    private func mapResultByDate(_ items: [NotificationStorageItem], rosterMap: [String: RosterStorageItem]) -> [Datasource] {
        var currentDate: String? = nil
        var out: [Datasource] = []

        items.forEach { item in
            let newDate = NotificationsSupport.sectionTitle(for: item.date)
            guard let child = notificationItemToDatasourceChild(item, rosterMap: rosterMap) else {
                return
            }

            if newDate != currentDate {
                currentDate = newDate
                out.append(
                    Datasource(
                        title: newDate,
                        key: "notifications",
                        childs: [child]
                    )
                )
            } else {
                out.last?.childs.append(child)
            }
        }

        return out
    }

    func buildDatasourceSnapshot(
        filter: Filter,
        filterAccount: String?,
        unreadOnly: Bool = false,
        searchQuery: String? = nil
    ) -> DatasourceSnapshot {
        do {
            let realm = try WRealm.safe()
            let owners = Self.enabledOwnerJids(in: realm)
            let datasource = NotificationsListCoordinator.deriveState(
                realm: realm,
                owners: owners,
                filter: filter,
                filterAccount: filterAccount,
                unreadOnly: unreadOnly,
                searchQuery: searchQuery,
                headerBuilder: self.headerSection(for:),
                listMapper: self.mapResultByDate(_:rosterMap:)
            ).listDatasource
            return DatasourceSnapshot(datasource: datasource, hasResolvedSnapshot: filterAccount != nil || owners.isNotEmpty)
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
            return DatasourceSnapshot(datasource: [], hasResolvedSnapshot: false)
        }
    }

    private func childNeedsReload(old: DatasourceChild, new: DatasourceChild) -> Bool {
        old.primary != new.primary ||
        old.category != new.category ||
        old.owner != new.owner ||
        old.jid != new.jid ||
        old.title.string != new.title.string ||
        old.message?.string != new.message?.string ||
        old.key != new.key ||
        old.date != new.date ||
        old.avatarUrl != new.avatarUrl ||
        old.badgeIcon != new.badgeIcon ||
        old.isRead != new.isRead ||
        old.isHeader != new.isHeader
    }

    private func compatibleSectionShape(old: [Datasource], new: [Datasource]) -> Bool {
        guard old.count == new.count else { return false }
        return zip(old, new).allSatisfy { oldSection, newSection in
            oldSection.key == newSection.key &&
            oldSection.childs.count == newSection.childs.count &&
            zip(oldSection.childs, newSection.childs).allSatisfy { $0.primary == $1.primary }
        }
    }

    private func changedSectionsAndRows(old: [Datasource], new: [Datasource]) -> (sections: IndexSet, rows: [IndexPath]) {
        var changedSections = IndexSet()
        var changedRows: [IndexPath] = []

        for (sectionIndex, pair) in zip(old.indices, zip(old, new)) {
            let oldSection = pair.0
            let newSection = pair.1

            if oldSection.title != newSection.title || oldSection.key != newSection.key {
                changedSections.insert(sectionIndex)
                continue
            }

            for (rowIndex, childPair) in zip(oldSection.childs.indices, zip(oldSection.childs, newSection.childs)) {
                if childNeedsReload(old: childPair.0, new: childPair.1) {
                    changedRows.append(IndexPath(row: rowIndex, section: sectionIndex))
                }
            }
        }

        return (changedSections, changedRows)
    }

    private func updateBarsIfNeeded(filter: Filter, filterAccount: String?, unreadOnly: Bool) {
        let state = (filter: filter, account: filterAccount, unreadOnly: unreadOnly)
        guard lastConfiguredBarsState?.filter != state.filter ||
            lastConfiguredBarsState?.account != state.account ||
            lastConfiguredBarsState?.unreadOnly != state.unreadOnly else {
            return
        }
        lastConfiguredBarsState = state
        configureBars(animated: false)
    }

    private func scheduleDatasourceReload() {
        datasourceGeneration += 1
        let generation = datasourceGeneration
        let filter = self.filter.value
        let filterAccount = self.filterAccount.value
        let unreadOnly = self.unreadOnly.value
        let searchQuery = self.notificationSearchQuery

        datasourceQueue.async {
            let snapshot = self.buildDatasourceSnapshot(
                filter: filter,
                filterAccount: filterAccount,
                unreadOnly: unreadOnly,
                searchQuery: searchQuery
            )
            DispatchQueue.main.async {
                guard generation == self.datasourceGeneration else {
                    return
                }
                let previousDatasource = self.datasource
                let isCompatible = self.compatibleSectionShape(old: previousDatasource, new: snapshot.datasource)
                self.datasource = snapshot.datasource
                self.reconcileMentionOpenClaimsAfterApplying(
                    snapshot.datasource
                )
                let descriptor = Self.emptyStateDescriptor(
                    filter: filter,
                    hasResolvedSnapshot: snapshot.hasResolvedSnapshot,
                    isLoading: false,
                    hasNotificationRows: Self.hasNotificationRows(snapshot.datasource)
                )
                if let descriptor = descriptor {
                    self.emptyView.accessibilityIdentifier = "notifications_empty_view"
                    self.emptyView.configure(descriptor: descriptor, onButtonTouchUp: nil)
                }
                let shouldShowEmptyState = descriptor != nil
                self.emptyScreenShowObserver.accept(shouldShowEmptyState)
                self.emptyView.isHidden = !shouldShowEmptyState
                self.updateBarsIfNeeded(filter: filter, filterAccount: filterAccount, unreadOnly: unreadOnly)
                self.updateNotificationsCompactBottomBarState()
                guard isCompatible else {
                    self.tableView.reloadData()
                    return
                }

                let changes = self.changedSectionsAndRows(old: previousDatasource, new: snapshot.datasource)
                if changes.sections.isEmpty && changes.rows.isEmpty {
                    return
                }

                UIView.performWithoutAnimation {
                    if !changes.sections.isEmpty {
                        self.tableView.reloadSections(changes.sections, with: .none)
                    }
                    let rowReloads = changes.rows.filter { !changes.sections.contains($0.section) }
                    if rowReloads.isNotEmpty {
                        self.tableView.reloadRows(at: rowReloads, with: .none)
                    }
                }
            }
        }
    }
    
    private func makeNotificationsBackButton() -> UIBarButtonItem {
        let button = UIBarButtonItem(
            image: imageLiteral("chevron.left"),
            style: .plain,
            target: self,
            action: #selector(onBackButtonTouchUpInside)
        )
        button.accessibilityIdentifier = "notifications_back_to_chats_button"
        return button
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateNotificationsTableInsetsForBottomSearch()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.tabBarController?.tabBar.isHidden = false
        self.tabBarController?.tabBar.layoutIfNeeded()
        NavigationLargeTitlePolicy.apply(to: self)
        switch CommonConfigManager.shared.interfaceType {
            case .tabs:
                break
            case .split:
//                self.splitViewController?.navigationItem.setLeftBarButtonItems([], animated: true)
                
                if UIDevice.current.userInterfaceIdiom != .pad {
                    self.navigationItem.setHidesBackButton(true, animated: false)
                    self.navigationItem.setLeftBarButton(makeNotificationsBackButton(), animated: false)
                }
        }
        configureNotificationsBottomSearchIfNeeded()
        updateNotificationsCompactBottomBarState()
        configureBars(animated: false)
    }
    
    weak var leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil
    
    @objc
    private final func onBackButtonTouchUpInside(_ sender: UIBarButtonItem) {
        performNotificationsBackAction(resolveNotificationsBackAction())
    }

    private func resolveNotificationsBackAction() -> NotificationsBackAction {
        let exitAction = NavigationExitPolicy.action(
            for: NavigationExitPolicyContext(destination: self, route: .currentNavigationPush)
        )
        return NotificationsBackPolicy.action(
            exitAction: exitAction,
            hasChatsRootFallback: leftMenuDelegate != nil
        )
    }

    private func performNotificationsBackAction(_ action: NotificationsBackAction) {
        switch action {
        case .dismissModal:
            dismiss(animated: true)
        case .popNavigationStack:
            navigationController?.popViewController(animated: true)
        case .revealSplitList:
            splitViewController?.show(.primary)
        case .selectChatsRoot:
            leftMenuDelegate?.selectRootScreenAndCategory(screen: "chat", category: nil)
        case .none:
            break
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshContinuousSplitBackgroundAppearance()
        NavigationLargeTitlePolicy.apply(to: self)
        configureNotificationsBottomSearchIfNeeded()
        self.configureBars(animated: false)
        updateNotificationsCompactBottomBarState()
        self.tabBarController?.tabBar.isHidden = false
        self.tabBarController?.tabBar.layoutIfNeeded()
        AccountManager.shared.users.forEach {
            user in
            if user.xmppStream.isAuthenticated {
                user.action { user, stream in
                    user.notifications.update(stream)
//                    user.notifications.readAll(stream)
                }
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard previousTraitCollection?.horizontalSizeClass != effectiveHorizontalSizeClass else {
            return
        }

        configureNotificationsBottomSearchIfNeeded()
        configureBars(animated: false)
        updateNotificationsCompactBottomBarState()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        claimedMentionOpenNotificationPrimaries.removeAll()
#if DEBUG || CHAT_PERFORMANCE_LAB
        mentionOpenAttemptObserverForTests = nil
        mentionOpenDuplicateDropObserverForTests = nil
        mentionOpenRealmEntryObserverForTests = nil
#endif
    }
    
    override func subscribe() {
        super.subscribe()

        do {
            let realm = try WRealm.safe()
            let accountsObserver = realm.objects(AccountStorageItem.self).filter("enabled == true")
            let notificationObserver = realm.objects(NotificationStorageItem.self).filter("shouldShow == true")
            self.filter
                .asObservable()
                .distinctUntilChanged()
                .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
                .subscribe { _ in
                    self.scheduleDatasourceReload()
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)
            
            self.filterAccount
                .asObservable()
                .distinctUntilChanged { $0 == $1 }
                .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
                .subscribe { _ in
                    self.scheduleDatasourceReload()
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)

            self.unreadOnly
                .asObservable()
                .distinctUntilChanged()
                .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
                .subscribe { _ in
                    self.scheduleDatasourceReload()
                    self.updateNotificationsCompactBottomBarState()
                } onError: { _ in

                } onCompleted: {

                } onDisposed: {

                }.disposed(by: self.bag)
            
            
            Observable
                .merge([
                    Observable.collection(from: accountsObserver).map { _ in () },
                    Observable.collection(from: notificationObserver).map { _ in () }
                ])
                .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
                .subscribe { _ in
                    self.scheduleDatasourceReload()
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)
            
            self.emptyScreenShowObserver
                .asObservable()
                .debounce(.milliseconds(1), scheduler: MainScheduler.asyncInstance)
                .subscribe { value in
                    self.emptyView.isHidden = !value
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)
            
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
}

extension NotificationsListViewController: UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return self.datasource.count
    }
    
//    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
//        if section == 0 && self.filter.value != .all {
//            return
//        }
//        var configuration = UIListContentConfiguration.sidebarHeader()
//
//        configuration.text = self.datasource[section].title
//        
//        configuration.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 6, bottom: 0, trailing: 6)
//        
//        (view as? UITableViewHeaderFooterView)?.contentConfiguration = configuration
//    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 && self.filter.value != .all {
            return nil
        }
        return self.datasource[section].title
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return nil
    }
    
//    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
//        if section == 0 && self.filter.value != .all {
//            return nil
//        }
//        let frame = CGRect(
//            origin: CGPoint(
//                x: 0,
//                y: 0
//            ),
//            size: CGSize(
//                width: self.view.bounds.width,
//                height: 34
//            )
//        )
//        let view = ChatViewController.FloatDateView(frame: frame)
//        view.configure(NSAttributedString(
//            string: self.datasource[section].title,
//            attributes: [
//                .font: UIFont.preferredFont(forTextStyle: .caption1),
//                .foregroundColor: UIColor.black,
//            ])
//        )
//        view.messageLabel.backgroundColor = UIColor.black.withAlphaComponent(0.1)
//        return view
//    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if self.datasource[section].key == "contact" {
            return self.datasource[section].childs.count > 2 ? 2 : self.datasource[section].childs.count
        }
        return self.datasource[section].childs.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section = self.datasource[indexPath.section]
        let item = section.childs[indexPath.row]
        if item.isHeader {
            guard let cell = tableView.dequeueReusableCell(withIdentifier: MenuItemHeaderTableCell.cellName, for: indexPath) as? MenuItemHeaderTableCell else {
                fatalError()
            }
            
            cell.configure(title: item.title.string, subtitle: item.message?.string ?? "", icon: item.badgeIcon, color: .tintColor)

            cell.selectionStyle = .none
            cell.applyContinuousSplitGlassBackground()

            return cell
        }
        switch section.key {
            case "subscribtion_requests":
                guard let cell = tableView.dequeueReusableCell(withIdentifier: NotificationsSubscribtionsListViewController.ContactItemCell.cellName, for: indexPath) as? NotificationsSubscribtionsListViewController.ContactItemCell else {
                    fatalError()
                }
                
                cell.selectionStyle = .none
                cell.configure(
                    owner: item.owner,
                    username: item.title,
                    jid: item.jid,
                    message: item.message,
                    icon: item.badgeIcon,
                    avatarUrl: item.avatarUrl,
                    uuid: item.key ?? "",
                    isRead: item.isRead
                )
                
                cell.addButtonAction = self.addButtonAction
                cell.declineButtonAction = self.declineButtonAction
                
//                let view = UIView()
//                view.backgroundColor = AccountColorManager.shared.palette(for: item.owner).tint50 | AccountColorManager.shared.palette(for: item.owner).tint900
//                cell.selectedBackgroundView = view
                
                cell.accessoryType = .detailButton
                cell.applyPlainGroupedSystemBackground()
                
                return cell
            case "notifications":
                guard let cell = tableView.dequeueReusableCell(withIdentifier: NotificationItemCell.cellName, for: indexPath) as? NotificationItemCell else {
                    fatalError()
                }
                cell.selectionStyle = .none
                cell.configure(
                    jid: item.jid,
                    owner: item.owner,
                    avatarUrl: item.avatarUrl,
                    icon: item.badgeIcon,
                    title: item.title,
                    message: item.message,
                    date: item.date,
                    isRead: item.isRead
                )
                
//                let view = UIView()
//                view.backgroundColor = AccountColorManager.shared.palette(for: item.owner).tint50 | AccountColorManager.shared.palette(for: item.owner).tint900
//                cell.selectedBackgroundView = view
                
                cell.accessoryType = .none
                cell.applyPlainGroupedSystemBackground()
                
                return cell
            default:
                fatalError()
        }
    }
}

extension NotificationsListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    private func synchronizeMentionNotificationRead(
        primary: String,
        deleteAfterAcknowledgement: Bool = false
    ) {
        do {
            let realm = try WRealm.safe()
            var messagePrimariesByOwner: [String: Set<String>] = [:]
            var affectedChatsByOwner: [String: Set<String>] = [:]
            try realm.write {
                guard let instance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: primary) else {
                    return
                }
                if let sourceChatJid = MentionNotificationSync.groupchatJidForLastChatMentionState(from: instance) {
                    affectedChatsByOwner[instance.owner, default: []].insert(sourceChatJid)
                }
                instance.isRead = true
                let result = MentionNotificationSync.reconcile(notification: instance, in: realm)
                if let messagePrimary = result.linkedMessagePrimaryToMarkRead {
                    messagePrimariesByOwner[instance.owner, default: []].insert(messagePrimary)
                }
                if deleteAfterAcknowledgement {
                    realm.delete(instance)
                }
                affectedChatsByOwner.forEach { owner, chats in
                    MentionNotificationSync.refreshLastChatMentionIds(owner: owner, groupchatJids: chats, in: realm)
                }
            }
            messagePrimariesByOwner.forEach { owner, primaries in
                primaries.forEach {
                    AccountManager.shared.find(for: owner)?.messages.readMessage($0, last: false)
                }
            }
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        let section = self.datasource[indexPath.section]
        if section.childs[indexPath.row].category == .mention {
            return indexPath
        }
        section.childs[indexPath.row].isRead = true
        let primary = section.childs[indexPath.row].primary
        DispatchQueue.global(qos: .utility).async {
            do {
                let realm = try WRealm.safe()
                try realm.write {
                    realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: primary)?.isRead = true
                }
            } catch {
                DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
            }
        }
        
        switch section.key {
            case "subscribtion_requests":
                if let cell = tableView.cellForRow(at: indexPath) as? NotificationsSubscribtionsListViewController.ContactItemCell {
                    cell.updateReadState(true, animated: true)
                }
            case "notifications":
                if let cell = tableView.cellForRow(at: indexPath) as? NotificationItemCell {
                    cell.updateReadState(true, animated: true)
                }
            default:
                break
        }
        return indexPath
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let section = self.datasource[indexPath.section]
        let item = section.childs[indexPath.row]
        let preclaimedNotificationRow: Bool
        if section.key == "notifications" {
            guard claimMentionOpenNotification(
                primary: item.primary
            ) else {
                return
            }
            preclaimedNotificationRow = true
        } else {
            preclaimedNotificationRow = false
        }
//        section.childs[indexPath.row].isRead = true
        let routeCategory: XMPPNotificationsManager.Category = {
            guard section.key == "notifications" else {
                return item.category
            }

            do {
#if DEBUG || CHAT_PERFORMANCE_LAB
                self.mentionOpenRealmEntryObserverForTests?(
                    NotificationsMentionOpenRealmEntryDiagnostics(
                        notificationPrimary: item.primary,
                        phase: .authoritativeCategory,
                        claimWasHeld:
                            self.claimedMentionOpenNotificationPrimaries
                                .contains(item.primary)
                    )
                )
#endif
                let realm = try WRealm.safe()
                return realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: item.primary)?.category ?? item.category
            } catch {
                DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
                return item.category
            }
        }()

        let presentation = NotificationsDetailPresentationPolicy.presentation(
            sectionKey: section.key,
            category: routeCategory
        )
        if preclaimedNotificationRow,
           presentation != .mentionChat {
            releaseMentionOpenNotificationClaim(
                primary: item.primary
            )
        }

        switch presentation {
            case .modalContainedContactInfo:
                let vc = ContactInfoViewController()
                vc.conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
                vc.owner = item.owner
                vc.jid = item.jid
                showModal(vc, parent: self)
//                if let cell = tableView.cellForRow(at: indexPath) as? NotificationsSubscribtionsListViewController.ContactItemCell {
//                    cell.updateReadState(true, animated: true)
//                }
            case .modalContainedDevices:
                do {
                    let realm = try WRealm.safe()
                    let currentItem = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: item.primary)
                    let vc = DevicesListViewController()
                    vc.configure(for: currentItem?.owner ?? item.owner)
                    showModal(vc, parent: self)
                } catch {
                    DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
                }
            case .mentionChat:
                if !preclaimedNotificationRow {
                    guard claimMentionOpenNotification(
                        primary: item.primary
                    ) else {
                        return
                    }
                }
                do {
#if DEBUG || CHAT_PERFORMANCE_LAB
                    self.mentionOpenRealmEntryObserverForTests?(
                        NotificationsMentionOpenRealmEntryDiagnostics(
                            notificationPrimary: item.primary,
                            phase: .mentionResolution,
                            claimWasHeld:
                                self.claimedMentionOpenNotificationPrimaries
                                    .contains(item.primary)
                        )
                    )
#endif
                    let realm = try WRealm.safe()
                    switch NotificationsMentionRoutePolicy.action(isBlockedByUnrelatedPresentedModal: hasUnrelatedPresentedModal()) {
                    case .openChat:
                        var selection = NotificationsMentionOpenSelection(
                            resolution: .unavailable(.notificationUnavailable),
                            selectedNotificationPrimary: nil
                        )
                        var sourceRemainsInAppliedDatasource = false
                        try realm.write {
                            selection = NotificationsMentionOpenRouter.resolveSelection(
                                notificationPrimary: item.primary,
                                in: realm
                            )
                            sourceRemainsInAppliedDatasource = realm.object(
                                ofType: NotificationStorageItem.self,
                                forPrimaryKey: item.primary
                            )?.shouldShow == true
                        }
                        var didNavigate = false
                        switch selection.resolution {
                        case .exact(let request, _):
                            didNavigate = self.leftMenuDelegate?.openChatlistWithChat(
                                owner: request.owner,
                                jid: request.chatJid,
                                conversationType: request.conversationType,
                                openMessageRequest: request,
                                configure: nil
                            ) ?? false
                        case .unavailable:
                            self.view.makeToast("Original mention is unavailable")
                        }
#if DEBUG || CHAT_PERFORMANCE_LAB
                        self.mentionOpenAttemptObserverForTests?(
                            NotificationsMentionOpenAttemptDiagnostics(
                                tappedNotificationPrimary: item.primary,
                                resolution: selection.resolution,
                                selectedNotificationPrimary:
                                    selection.selectedNotificationPrimary,
                                didNavigate: didNavigate
                            )
                        )
#endif
                        if !didNavigate && sourceRemainsInAppliedDatasource {
                            releaseMentionOpenNotificationClaim(
                                primary: item.primary
                            )
                        }
                    case .ignore:
                        releaseMentionOpenNotificationClaim(
                            primary: item.primary
                        )
                        break
                    }
                } catch {
                    releaseMentionOpenNotificationClaim(
                        primary: item.primary
                    )
                    DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
                }
//                if let cell = tableView.cellForRow(at: indexPath) as? NotificationItemCell {
//                    cell.updateReadState(true, animated: true)
//                }
            case .none:
                break
        }
    }

    private func hasUnrelatedPresentedModal() -> Bool {
        guard let activePresentedController = ModalPresentationCurrentControllerAccess.application.get() else {
            return false
        }

        if activePresentedController === self {
            return false
        }

        if let navigationController,
           activePresentedController === navigationController {
            return false
        }

        return true
    }

    private func claimMentionOpenNotification(primary: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !claimedMentionOpenNotificationPrimaries.contains(primary) else {
#if DEBUG || CHAT_PERFORMANCE_LAB
            mentionOpenDuplicateDropObserverForTests?(primary)
#endif
            return false
        }
        claimedMentionOpenNotificationPrimaries.insert(primary)
        return true
    }

    private func releaseMentionOpenNotificationClaim(primary: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        claimedMentionOpenNotificationPrimaries.remove(primary)
    }

    private func reconcileMentionOpenClaimsAfterApplying(
        _ datasource: [Datasource]
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !claimedMentionOpenNotificationPrimaries.isEmpty else {
            return
        }
        let materializedPrimaries = Set(
            datasource.flatMap { section in
                section.childs.map(\.primary)
            }
        )
        claimedMentionOpenNotificationPrimaries.formIntersection(
            materializedPrimaries
        )
    }
}

extension NotificationsListViewController {
    public func addButtonAction(_ jid: String, _ owner: String, _ uuid: String) {
        AccountManager.shared.find(for: owner)?.action({ user, stream in
            user.presences.subscribe(stream, jid: jid)
            user.presences.subscribed(stream, jid: jid, storePreaproved: false)
            user.roster.setContact(stream, jid: jid, nickname: nil, groups: [], callback: nil)
        })
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: owner, jid: jid, uniqueId: uuid)) {
                try realm.write {
                    realm.delete(instance)
                }
            }
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    public func declineButtonAction(_ jid: String, _ owner: String, _ uuid: String) {
        AccountManager.shared.find(for: owner)?.action({ user, stream in
            user.presences.unsubscribed(stream, jid: jid)
        })
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: NotificationStorageItem.genPrimary(owner: owner, jid: jid, uniqueId: uuid)) {
                try realm.write {
                    realm.delete(instance)
                }
            }
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
    }
}

extension NotificationsListViewController: NotificationsControllerFilterProtocol {
    func shouldFilterBy(account: String?) {
        if let account = account {
            self.filterAccount.accept(self.filterAccount.value == account ? nil : account)
        } else {
            self.filterAccount.accept(nil)
        }
        updateNotificationsCompactBottomBarState()
    }
    
    func shouldFilterBy(category: String?) {
        guard let category,
              category != Filter.all.rawValue,
              let filterValue = Filter(rawValue: category) else {
            filter.accept(.all)
            updateNotificationsCompactBottomBarState()
            return
        }
        filter.accept(filterValue)
        updateNotificationsCompactBottomBarState()
    }
}

extension NotificationsListViewController {
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item = self.datasource[indexPath.section].childs[indexPath.row]
        let deleteAction = UIContextualAction(style: .destructive,
                                              title: "Delete".localizeString(id: "delete", arguments: [])) {
            (action, view, handler) in
            
            let item = self.datasource[indexPath.section].childs[indexPath.row]
            if item.category == .mention {
                self.synchronizeMentionNotificationRead(primary: item.primary, deleteAfterAcknowledgement: true)
            } else {
                do {
                    let realm = try WRealm.safe()
                    try realm.write {
                        if let instance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: item.primary) {
                            realm.delete(instance)
                        }
                    }
                } catch {
                    DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
                }
            }
            handler(true)
        }
        
        let readAction = UIContextualAction(style: .destructive,
                                              title: "Read".localizeString(id: "action_mark_as_read", arguments: [])) {
            (action, view, handler) in
            let item = self.datasource[indexPath.section].childs[indexPath.row]
            if item.category == .mention {
                self.synchronizeMentionNotificationRead(primary: item.primary)
            } else {
                do {
                    let realm = try WRealm.safe()
                    try realm.write {
                        if let instance = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: item.primary) {
                            instance.isRead = true
                        }
                    }
                } catch {
                    DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
                }
            }
            handler(true)
        }
        
        deleteAction.image = imageLiteral( "trash")
        readAction.image = imageLiteral("checkmark")
        deleteAction.backgroundColor = .systemRed
        readAction.backgroundColor = .systemBlue
        if item.isRead {
            return UISwipeActionsConfiguration(actions: [deleteAction])
        } else {
            return UISwipeActionsConfiguration(actions: [deleteAction, readAction])
        }
    }
}
