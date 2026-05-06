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
        headerBuilder: (NotificationsListViewController.Filter) -> NotificationsListViewController.Datasource?,
        listMapper: ([NotificationStorageItem], [String: RosterStorageItem]) -> [NotificationsListViewController.Datasource]
    ) -> DerivedState {
        let selectedOwners = filterAccount.map { [$0] } ?? owners
        let notifications = NotificationsSupport.notifications(in: realm, owners: selectedOwners, filter: filter).toArray()
        let rosterMap = NotificationsSupport.rosterMap(in: realm, for: notifications)
        var sections: [NotificationsListViewController.Datasource] = []
        if let header = headerBuilder(filter) {
            sections.append(header)
        }
        sections.append(contentsOf: listMapper(notifications, rosterMap))

        let counters = NotificationsSupport.unreadCounters(in: realm, owners: owners)
        let visibleCounters = NotificationsSupport.visibleCounters(in: realm, owners: owners)
        let categoriesDatasource = [
            [CategoryItem(title: "Notifications", icon: "bell.fill", key: "all", subtitle: "Manage security alerts, information updates, mentions, and other notifications.", color: .tintColor, isHeader: true)],
            [CategoryItem(title: "Notifications", icon: "bell", key: "all", subtitle: "\(visibleCounters.total)", color: .tintColor, isHeader: false)],
            [
                CategoryItem(title: "Security", icon: "checkerboard.shield", key: "security", subtitle: "\(visibleCounters.security)", color: .tintColor, isHeader: false),
                CategoryItem(title: "Information", icon: "info.circle", key: "info", subtitle: "\(visibleCounters.info)", color: .tintColor, isHeader: false),
                CategoryItem(title: "Mentions", icon: "at", key: "mentions", subtitle: "\(visibleCounters.mentions)", color: .tintColor, isHeader: false),
            ]
        ]

        return DerivedState(listDatasource: sections.filter { !$0.childs.isEmpty }, categoriesDatasource: categoriesDatasource, counters: counters)
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
        
        self.emptyView.isHidden = !self.emptyScreenShowObserver.value
        self.view.addSubview(self.emptyView)
        self.emptyView.fillSuperview()
        self.view.bringSubviewToFront(self.emptyView)
    }
    
    override func configure() {
        super.configure()
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.title = nil
        } else {
        self.title = "Notifications"
        }
        self.tableView.dataSource = self
        self.tableView.delegate = self
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
        isLoading: Bool,
        hasNotificationRows: Bool
    ) -> CoreListEmptyStateDescriptor? {
        guard !isLoading, !hasNotificationRows else {
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
    var filterMenu: UIMenu = UIMenu()
    private let datasourceQueue = DispatchQueue(label: "com.xabber.notifications.datasource", qos: .userInitiated)
    private var datasourceGeneration: Int = 0
    private var lastConfiguredBarsState: (filter: Filter, account: String?)?
    
    func configureBars() {
        lastConfiguredBarsState = (filter: filter.value, account: filterAccount.value)
        let button = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), style: .plain, target: self, action: nil)
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
        if childs.count <= 1 {
            self.navigationItem.setRightBarButtonItems([readAllNotificationsButton], animated: true)
        } else {
            self.navigationItem.setRightBarButtonItems([button, readAllNotificationsButton], animated: true)
        }
    }
        
    @objc
    private func onReadAllNotifications(_ sender: UIBarButtonItem) {
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
            let owners = filterAccount.value.map { [$0] } ?? AccountManager.shared.users.map { $0.jid }
            let allNotifications = NotificationsSupport.notifications(
                in: realm,
                owners: owners,
                filter: self.filter.value
            )
            var messagePrimariesByOwner: [String: Set<String>] = [:]
            var affectedChatsByOwner: [String: Set<String>] = [:]
            try realm.write {
                allNotifications.forEach {
                    $0.isRead = true
                    guard $0.category == .mention else {
                        return
                    }
                    if let sourceChatJid = MentionNotificationSync.groupchatJidForLastChatMentionState(from: $0) {
                        affectedChatsByOwner[$0.owner, default: []].insert(sourceChatJid)
                    }
                    let result = MentionNotificationSync.reconcile(notification: $0, in: realm)
                    if let messagePrimary = result.linkedMessagePrimaryToMarkRead {
                        messagePrimariesByOwner[$0.owner, default: []].insert(messagePrimary)
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
                .filter { owners.contains($0.jid) }
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

    func buildDatasourceSnapshot(filter: Filter, filterAccount: String?) -> [Datasource] {
        do {
            let realm = try WRealm.safe()
            let owners = AccountManager.shared.users.map { $0.jid }
            return NotificationsListCoordinator.deriveState(
                realm: realm,
                owners: owners,
                filter: filter,
                filterAccount: filterAccount,
                headerBuilder: self.headerSection(for:),
                listMapper: self.mapResultByDate(_:rosterMap:)
            ).listDatasource
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
            return []
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

    private func updateBarsIfNeeded(filter: Filter, filterAccount: String?) {
        let state = (filter: filter, account: filterAccount)
        guard lastConfiguredBarsState?.filter != state.filter || lastConfiguredBarsState?.account != state.account else {
            return
        }
        lastConfiguredBarsState = state
        configureBars()
    }

    private func scheduleDatasourceReload() {
        datasourceGeneration += 1
        let generation = datasourceGeneration
        let filter = self.filter.value
        let filterAccount = self.filterAccount.value

        datasourceQueue.async {
            let snapshot = self.buildDatasourceSnapshot(filter: filter, filterAccount: filterAccount)
            DispatchQueue.main.async {
                guard generation == self.datasourceGeneration else {
                    return
                }
                let previousDatasource = self.datasource
                let isCompatible = self.compatibleSectionShape(old: previousDatasource, new: snapshot)
                self.datasource = snapshot
                let descriptor = Self.emptyStateDescriptor(
                    filter: filter,
                    isLoading: false,
                    hasNotificationRows: Self.hasNotificationRows(snapshot)
                )
                if let descriptor = descriptor {
                    self.emptyView.accessibilityIdentifier = "notifications_empty_view"
                    self.emptyView.configure(descriptor: descriptor, onButtonTouchUp: nil)
                }
                let shouldShowEmptyState = descriptor != nil
                self.emptyScreenShowObserver.accept(shouldShowEmptyState)
                self.emptyView.isHidden = !shouldShowEmptyState
                self.updateBarsIfNeeded(filter: filter, filterAccount: filterAccount)
                guard isCompatible else {
                    self.tableView.reloadData()
                    return
                }

                let changes = self.changedSectionsAndRows(old: previousDatasource, new: snapshot)
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
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.tabBarController?.tabBar.isHidden = false
        self.tabBarController?.tabBar.layoutIfNeeded()
//        if CommonConfigManager.shared.config.use_large_title {
//            self.navigationItem.largeTitleDisplayMode = .automatic
//        } else {
            self.navigationItem.largeTitleDisplayMode = .never
//        }
        self.navigationController?.navigationBar.prefersLargeTitles = false//CommonConfigManager.shared.config.use_large_title
        switch CommonConfigManager.shared.interfaceType {
            case .tabs:
                break
            case .split:
//                self.splitViewController?.navigationItem.setLeftBarButtonItems([], animated: true)
                
                let sidebarButton = UIBarButtonItem(image: imageLiteral("chevron.left"), style: .plain, target: self, action: #selector(onBackButtonTouchUpInside))
                
                if UIDevice.current.userInterfaceIdiom != .pad {
                    self.navigationItem.setHidesBackButton(true, animated: false)
                    self.navigationItem.setLeftBarButton(sidebarButton, animated: true)
                }
        }
    }
    
    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil
    
    @objc
    private final func onBackButtonTouchUpInside(_ sender: UIBarButtonItem) {
        self.leftMenuDelegate?.selectRootScreenAndCategory(screen: "chat", category: nil)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.configureBars()
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
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func subscribe() {
        super.subscribe()
        
        let jids = AccountManager.shared.users.map { $0.jid }
        
        do {
            let realm = try WRealm.safe()
            let collectionObserver = realm.objects(NotificationStorageItem.self).filter("owner IN %@ AND shouldShow == true", jids)
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
            
            
            Observable
                .collection(from: collectionObserver)
                .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
                .skip(1)
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
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if section == 0 && self.filter.value != .all {
            return .leastNormalMagnitude
        }
        return 34
    }
    
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 0
    }
    
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
//        section.childs[indexPath.row].isRead = true
        switch section.key {
            case "subscribtion_requests":
                let vc = ContactInfoViewController()
                vc.conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
                vc.owner = item.owner
                vc.jid = item.jid
                showModal(vc, parent: self)
//                if let cell = tableView.cellForRow(at: indexPath) as? NotificationsSubscribtionsListViewController.ContactItemCell {
//                    cell.updateReadState(true, animated: true)
//                }
            case "notifications":
                do {
                    let realm = try WRealm.safe()
                    let currentItem = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: item.primary)
                    switch currentItem?.category ?? item.category {
                    case .device:
                        let vc = DevicesListViewController()
                        vc.configure(for: currentItem?.owner ?? item.owner)
                        showModal(vc, parent: self)
                    case .mention:
                        guard let notification = currentItem else {
                            break
                        }
                        guard let request = Self.mentionOpenRequest(for: notification) else {
                            self.view.makeToast("Original chat is unavailable")
                            break
                        }
                        self.leftMenuDelegate?.openChatlistWithChat(
                            owner: request.owner,
                            jid: request.chatJid,
                            conversationType: request.conversationType
                        ) { vc in
                            vc?.queueOpenMessageRequest(request)
                        }
                    default:
                        break
                    }
                } catch {
                    DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
                }
//                if let cell = tableView.cellForRow(at: indexPath) as? NotificationItemCell {
//                    cell.updateReadState(true, animated: true)
//                }
            default:
                break
        }
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
    }
    
    func shouldFilterBy(category: String?) {
        if category == "all" {
            self.filter.accept(.all)
        } else if let category = category {
            let filterValue = Filter(rawValue: category) ?? .all
            self.filter.accept(self.filter.value == filterValue ? .all : filterValue)
        } else {
            self.filter.accept(.all)
        }
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
