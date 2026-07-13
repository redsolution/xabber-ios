//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import UIKit
import RealmSwift
import RxSwift
import RxCocoa
import RxRealm
import DeepDiff
import CocoaLumberjack
import YubiKit
import MaterialComponents.MDCPalettes

protocol ContactsCategoryDelegate {
    func filterDidSelect(category: String?)
    func filterDidSelect(account: String?)
    func filterDidSelect(groups: [String])
}

struct ContactsFilterState: Equatable {
    let category: String?
    let filteredAccounts: Set<String>
    let filteredGroups: Set<String>
    let showOffline: Bool
    let isGroup: Bool
    let searchQuery: String?
}

struct ContactsListCoordinator {
    struct DerivedState {
        let context: ContactsListSupport.Context
        let datasource: [[ContactsViewController.Datasource]]
        let categoryDatasource: [[ContactsCategoryViewController.Datasource]]
        let circleCounts: [(name: String, count: Int)]
    }

    static func deriveState(realm: Realm, state: ContactsFilterState, datasourceBuilder: (ContactsFilterState, ContactsListSupport.Context) -> [[ContactsViewController.Datasource]]) -> DerivedState {
        let context = ContactsListSupport.makeContext(realm: realm, state: state)
        return DerivedState(
            context: context,
            datasource: datasourceBuilder(state, context),
            categoryDatasource: ContactsListSupport.categoryDatasource(context: context),
            circleCounts: ContactsListSupport.circleCounts(context: context)
        )
    }
}

extension ContactsViewController: LeftMenuRootNavigationChromeRefreshable {
    func refreshLeftMenuRootNavigationChromeAfterModalDismiss() {
        UIView.performWithoutAnimation {
            configureBars(animated: false, updateNavigationItems: true)
        }
    }
}

enum ContactsListSupport {

    struct Context {
        let state: ContactsFilterState
        let accountJids: [String]
        let ignoredJids: [String]
        let contactRosterItems: [RosterStorageItem]
        let joinedContactRosterItems: [RosterStorageItem]
        let rosterItemsByPrimary: [String: RosterStorageItem]
        let groupChats: [GroupChatStorageItem]
        let invites: [GroupchatInvitesStorageItem]
        let groups: [RosterGroupStorageItem]
        let groupUsersByGroupId: [String: [GroupchatUserStorageItem]]
        let contactJids: Set<String>
    }

    static func makeContext(realm: Realm, state: ContactsFilterState) -> Context {
        let accountJids = selectedAccountJids(realm: realm, state: state)
        let ignoredJids = buildIgnoredJids(realm: realm, accountJids: accountJids)

        let contactRosterItems = realm
            .objects(RosterStorageItem.self)
            .filter("owner IN %@ AND isHidden == false AND removed == false AND isContact == true AND NOT (jid IN %@)", accountJids, ignoredJids)
            .toArray()
        let joinedContactRosterItems = contactRosterItems.filter {
            ["both", "from", "to"].contains($0.subscription_)
        }

        let allRosterItems = realm
            .objects(RosterStorageItem.self)
            .filter("owner IN %@ AND isHidden == false AND removed == false AND NOT (jid IN %@)", accountJids, ignoredJids)
            .toArray()
        let rosterItemsByPrimary = Dictionary(uniqueKeysWithValues: allRosterItems.map { ($0.primary, $0) })

        let groupChats = realm
            .objects(GroupChatStorageItem.self)
            .filter("owner IN %@", accountJids)
            .toArray()

        let invites = realm
            .objects(GroupchatInvitesStorageItem.self)
            .filter("owner IN %@", accountJids)
            .toArray()

        let groups = realm
            .objects(RosterGroupStorageItem.self)
            .filter("owner IN %@ AND isSystemGroup == false", accountJids)
            .toArray()

        let groupUsers = realm
            .objects(GroupchatUserStorageItem.self)
            .filter("isHidden == false")
            .toArray()
        let groupUsersByGroupId = Dictionary(grouping: groupUsers, by: \.groupchatId)

        let visibleContactJids: Set<String> = Set(joinedContactRosterItems.compactMap { item in
            guard item.subscribtion == .both else {
                return nil
            }
            return item.jid
        })

        return Context(
            state: state,
            accountJids: accountJids,
            ignoredJids: ignoredJids,
            contactRosterItems: contactRosterItems,
            joinedContactRosterItems: joinedContactRosterItems,
            rosterItemsByPrimary: rosterItemsByPrimary,
            groupChats: groupChats,
            invites: invites,
            groups: groups,
            groupUsersByGroupId: groupUsersByGroupId,
            contactJids: visibleContactJids
        )
    }

    static func categoryDatasource(context: Context) -> [[ContactsCategoryViewController.Datasource]] {
        context.state.isGroup ? groupCategoryDatasource(context: context) : contactCategoryDatasource(context: context)
    }

    static func circleCounts(context: Context) -> [(name: String, count: Int)] {
        let items = context.state.isGroup
            ? visibleJoinedGroupRosterItems(context: context)
            : context.joinedContactRosterItems.filter { filteredGroupsMatch(itemGroups: Set($0.groups), state: context.state) }

        return context.groups
            .map { group in
                let count = items.filter { Set($0.groups).contains(group.name) }.count
                return (name: group.name, count: count)
            }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.count > rhs.count
            }
    }

    static func hasAnyContactAreaContent(context: Context) -> Bool {
        context.joinedContactRosterItems.isNotEmpty ||
        context.contactRosterItems.contains { $0.ask_ == "in" || $0.ask_ == "out" }
    }

    static func hasAnyGroupAreaContent(context: Context) -> Bool {
        visibleJoinedGroupRosterItems(context: context).isNotEmpty ||
        context.invites.contains { $0.isRead == false }
    }

    static func filteredGroupsMatch(itemGroups: Set<String>, state: ContactsFilterState) -> Bool {
        guard state.filteredGroups.isNotEmpty else {
            return true
        }
        return state.filteredGroups.isSubset(of: itemGroups)
    }

    static func includeContact(_ contact: RosterStorageItem, state: ContactsFilterState) -> Bool {
        guard filteredGroupsMatch(itemGroups: Set(contact.groups), state: state) else {
            return false
        }
        guard state.filteredAccounts.isEmpty || state.filteredAccounts.contains(contact.owner) else {
            return false
        }
        guard state.showOffline == false else {
            return true
        }
        guard let primaryResource = contact.getPrimaryResource() else {
            return false
        }
        guard primaryResource.isTemporary == false else {
            return false
        }
        return primaryResource.status != .offline
    }

    static func includeGroup(contact: RosterStorageItem, state: ContactsFilterState) -> Bool {
        guard contact.isContact == false else {
            return false
        }
        guard contact.subscribtion == .both else {
            return false
        }
        guard filteredGroupsMatch(itemGroups: Set(contact.groups), state: state) else {
            return false
        }
        guard state.filteredAccounts.isEmpty || state.filteredAccounts.contains(contact.owner) else {
            return false
        }
        guard state.showOffline == false else {
            return true
        }
        guard let primaryResource = contact.getPrimaryResource() else {
            return false
        }
        guard primaryResource.isTemporary == false else {
            return false
        }
        return primaryResource.status != .offline
    }

    static func hasSearchQuery(_ query: String?) -> Bool {
        normalizedSearchQuery(query) != nil
    }

    static func filteredDatasourceRows(
        _ rows: [ContactsViewController.Datasource],
        searchQuery: String?
    ) -> [ContactsViewController.Datasource] {
        guard let query = normalizedSearchQuery(searchQuery) else {
            return rows
        }

        return rows.filter { item in
            guard !item.isHeader, !item.isButton else {
                return false
            }
            return datasourceItem(item, matches: query)
        }
    }

    private static func datasourceItem(
        _ item: ContactsViewController.Datasource,
        matches query: String
    ) -> Bool {
        let values = [
            item.owner,
            item.jid,
            item.title,
            item.subtitle,
            item.bottomLine ?? "",
            item.descr ?? "",
            item.groups.joined(separator: " "),
            item.members.map(\.name).joined(separator: " "),
            item.members.compactMap(\.jid).joined(separator: " ")
        ]
        return values.contains {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    private static func normalizedSearchQuery(_ query: String?) -> String? {
        let normalized = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    static func memberStats(groupchatJid: String, owner: String, context: Context) -> (members: Int, contacts: Int, membersList: [ContactsViewController.GroupDisplayMember]) {
        let groupId = [groupchatJid, owner].prp()
        let groupUsers = context.groupUsersByGroupId[groupId] ?? []
        let memberIdentifiers = Set(groupUsers.compactMap { user in
            user.jid.isEmpty ? user.userId : user.jid
        })
        let members = groupUsers.compactMap {
            ContactsViewController.GroupDisplayMember(
                name: $0.nickname,
                jid: $0.jid,
                avatarUrl: $0.avatarURI,
                uuid: $0.userId
            )
        }
        return (memberIdentifiers.count, memberIdentifiers.intersection(context.contactJids).count, members)
    }

    static func rosterItem(for jid: String, owner: String, context: Context) -> RosterStorageItem? {
        context.rosterItemsByPrimary[RosterStorageItem.genPrimary(jid: jid, owner: owner)]
    }

    static func groupchat(for jid: String, owner: String, context: Context) -> GroupChatStorageItem? {
        context.groupChats.first {
            $0.owner == owner && $0.jid == jid
        }
    }

    private static func selectedAccountJids(realm: Realm, state: ContactsFilterState) -> [String] {
        if state.filteredAccounts.isNotEmpty {
            return Array(state.filteredAccounts).sorted()
        }
        return realm.objects(AccountStorageItem.self)
            .filter("enabled == true")
            .toArray()
            .compactMap(\.jid)
    }

    private static func buildIgnoredJids(realm: Realm, accountJids: [String]) -> [String] {
        XMPPServiceJidsSupport.ignoredServiceJids(in: realm, accountJids: accountJids)
    }

    private static func contactCategoryDatasource(context: Context) -> [[ContactsCategoryViewController.Datasource]] {
        let contacts = context.joinedContactRosterItems
        let contactsCount = contacts.filter { ($0.getPrimaryResource()?.entity ?? .contact) == .contact }.count
        let subscriptionsCount = context.contactRosterItems.filter { $0.ask_ == "in" }.count
        let requestsCount = context.contactRosterItems.filter { $0.ask_ == "out" }.count

        let circles = circleCounts(context: context).map {
            ContactsCategoryViewController.Datasource(
                title: $0.name,
                icon: "tag",
                key: $0.name,
                subtitle: "\($0.count)",
                color: .tintColor,
                isImportant: false,
                value: $0.count,
                isHeader: false
            )
        }

        return [
            [
                ContactsCategoryViewController.Datasource(title: "Contacts", icon: "person.fill", key: "all", subtitle: "Text about contacts, circles and other", color: .tintColor, isImportant: false, value: 0, isHeader: true, isSelectable: false),
            ],
            [
                ContactsCategoryViewController.Datasource(title: "Contacts", icon: "person.crop.rectangle.stack", key: "all", subtitle: "\(contactsCount)", color: .tintColor, isImportant: false, value: contactsCount, isHeader: false),
            ],
            [
                ContactsCategoryViewController.Datasource(title: "Contact Requests", icon: "person.text.rectangle", key: "subscribtions", subtitle: "\(subscriptionsCount)", color: .tintColor, isImportant: true, value: subscriptionsCount, isHeader: false),
                ContactsCategoryViewController.Datasource(title: "Outgoing Requests", icon: "xabber.person.plus", key: "requests", subtitle: "\(requestsCount)", color: .tintColor, isImportant: false, value: requestsCount, isHeader: false)
            ],
            circles
        ]
    }

    private static func groupCategoryDatasource(context: Context) -> [[ContactsCategoryViewController.Datasource]] {
        let visibleGroups = visibleJoinedGroupRosterItems(context: context)
        let publicCount = visibleGroups.filter {
            groupchat(for: $0.jid, owner: $0.owner, context: context)?.privacy == .publicChat &&
            groupchat(for: $0.jid, owner: $0.owner, context: context)?.peerToPeer == false
        }.count
        let incognitoCount = visibleGroups.filter {
            groupchat(for: $0.jid, owner: $0.owner, context: context)?.privacy == .incognito &&
            groupchat(for: $0.jid, owner: $0.owner, context: context)?.peerToPeer == false
        }.count
        let privateCount = visibleGroups.filter {
            groupchat(for: $0.jid, owner: $0.owner, context: context)?.peerToPeer == true
        }.count
        let invitationsCount = context.invites.filter { $0.isRead == false }.count

        let circles = circleCounts(context: context).map {
            ContactsCategoryViewController.Datasource(
                title: $0.name,
                icon: "tag",
                key: $0.name,
                subtitle: "\($0.count)",
                color: .tintColor,
                isImportant: false,
                value: $0.count,
                isHeader: false
            )
        }

        return [
            [
                ContactsCategoryViewController.Datasource(title: "Groups", icon: "person.2.fill", key: "all", subtitle: "Text about groups, incognito groups and private chats", color: .tintColor, isImportant: false, value: 0, isHeader: true, isSelectable: false),
            ],
            [
                ContactsCategoryViewController.Datasource(title: "Public Groups", icon: "person.2", key: "public", subtitle: "\(publicCount)", color: .tintColor, isImportant: false, value: publicCount, isHeader: false),
                ContactsCategoryViewController.Datasource(title: "Incognito Groups", icon: "xabber.incognito.variant", key: "incognito", subtitle: "\(incognitoCount)", color: .tintColor, isImportant: false, value: incognitoCount, isHeader: false),
                ContactsCategoryViewController.Datasource(title: "Private Chats", icon: "bubble", key: "private", subtitle: "\(privateCount)", color: .tintColor, isImportant: false, value: privateCount, isHeader: false)
            ],
            [
                ContactsCategoryViewController.Datasource(title: "Invitations", icon: "xabber.invite", key: "invitations", subtitle: "\(invitationsCount)", color: .tintColor, isImportant: true, value: invitationsCount, isHeader: false)
            ],
            circles
        ]
    }

    private static func visibleJoinedGroupRosterItems(context: Context) -> [RosterStorageItem] {
        context.groupChats.compactMap { group in
            guard let rosterItem = rosterItem(for: group.jid, owner: group.owner, context: context) else {
                return nil
            }
            guard includeGroup(contact: rosterItem, state: context.state) else {
                return nil
            }
            return rosterItem
        }
    }
}

class ContactsViewController: BaseViewController, LeftMenuFirstPresentationQuieting {
    
    class EmptyView: UIView {
        
        let stack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .center
            stack.distribution = .equalSpacing
            
            return stack
        }()
        
        let centerStack: UIStackView = {
            let stack = UIStackView()
            
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = 16
            
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, bottom: 8, left: 24, right: 24)
            
            return stack
        }()
        
        let titleLabel: UILabel = {
            let label = UILabel()
            
            label.font = UIFont.preferredFont(forTextStyle: .title2)
            //            if #available(iOS 13.0, *) {
            //                label.textColor = .label
            //            } else {
            label.textColor = MDCPalette.grey.tint500//.systemGray
            //            }//MDCPalette.grey.tint900
            
            return label
        }()
        
        let newChatButton: UIButton = {
            let button = UIButton()
            
            button.setTitleColor(MDCPalette.grey.tint500, for: .normal)
            
            return button
        }()
        
        internal var callback: (() -> Void)? = nil
        
        internal func activaateConstraints() {
            //            titleLabel.heightAnchor.constraint(lessThanOrEqualToConstant: 64).isActive = true
        }
        
        open func configure(onCreateChatCallback: @escaping (() -> Void)) {
            if #available(iOS 13.0, *) {
                backgroundColor = .systemBackground
            } else {
                backgroundColor = .white
            }
            addSubview(stack)
            stack.fillSuperview()
            stack.addArrangedSubview(UIStackView())
            stack.addArrangedSubview(centerStack)
            stack.addArrangedSubview(UIStackView())
            centerStack.addArrangedSubview(titleLabel)
//            centerStack.addArrangedSubview(newChatButton)
            titleLabel.text = "You don't have any contacts".localizeString(id: "you_dont_have_any_contacts_message", arguments: [])
            newChatButton.setTitle("Add someone to your contacts, then send some messages.".localizeString(id: "chat_add_contacts_hint", arguments: []), for: .normal)
            newChatButton.titleLabel?.numberOfLines = 0
            newChatButton.titleLabel?.textAlignment = .center
            activaateConstraints()
            callback = onCreateChatCallback
        }
        
        
        @objc
        internal func onButtonPressed(_ sender: UIButton) {
            callback?()
        }
    }
    
    class GroupDisplayMember {
        var name: String
        var jid: String?
        var avatarUrl: String?
        var uuid: String
        
        init(name: String, jid: String?, avatarUrl: String? = nil, uuid: String) {
            self.name = name
            self.jid = jid
            self.avatarUrl = avatarUrl
            self.uuid = uuid
        }
    }
    
    class Datasource: DiffAware, Equatable, Hashable {
        typealias DiffId = String
        
        var diffId: String {
            get {
                return [owner, jid].prp()
            }
        }
        
        static func == (lhs: Datasource, rhs: Datasource) -> Bool {
            return lhs.owner == rhs.owner &&
            lhs.jid == rhs.jid
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(owner)
            hasher.combine(jid)
            hasher.combine(title)
        }
        
        static func compareContent(_ a: ContactsViewController.Datasource, _ b: ContactsViewController.Datasource) -> Bool {
            return a.owner == b.owner &&
            a.jid == b.jid &&
            a.title == b.title &&
            a.avatarUrl == b.avatarUrl &&
            a.groups.sorted().joined() == b.groups.sorted().joined()
        }
        
        enum Kind {
            case contact
        }
        
        var primary: String = ""
        var owner: String
        var jid: String
        var title: String
        var subtitle: String
        var bottomLine: String?
        var groups: [String] = []
        var avatarUrl: String? = nil
        var conversationType: ClientSynchronizationManager.ConversationType = .regular
        
        var isSubscribtionRequest: Bool = false
        var isContactRequest: Bool = false
        var isInvite: Bool = false
        var isButton: Bool = false
        var value: String = ""
        var descr: String? = nil
        var members: [GroupDisplayMember] = []
        var status: ResourceStatus = .online
        var entity: RosterItemEntity = .contact
        var icon: String
        var isHeader: Bool
        
        init(owner: String, title: String, jid: String, subtitle: String, avatarUrl: String? = nil, groups: [String], conversationType: ClientSynchronizationManager.ConversationType, isContactRequest: Bool = false, isSubscribtionRequest: Bool = false, isInvite: Bool = false, isButton: Bool = false, value: String = "", bottomLine: String? = nil, descr: String? = nil, members: [GroupDisplayMember] = [], status: ResourceStatus = .online, entity: RosterItemEntity = .contact, primary: String = "", isHeader: Bool = false, icon: String = "") {
            self.primary = primary
            self.owner = owner
            self.title = title
            self.subtitle = subtitle
            self.jid = jid
            self.avatarUrl = avatarUrl
            self.groups = groups
            self.conversationType = conversationType
            self.isContactRequest = isContactRequest
            self.isSubscribtionRequest = isSubscribtionRequest
            self.isInvite = isInvite
            self.isButton = isButton
            self.value = value
            self.bottomLine = bottomLine
            self.descr = descr
            self.members = members
            self.status = status
            self.entity = entity
            self.isHeader = isHeader
            self.icon = icon
        }
        
    }
    
    struct EnabledAccount {
        let jid: String
        let isCollapsed: Bool
        let contactsCount: Int
    }
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)
        
        view.register(ContactCell.self, forCellReuseIdentifier: ContactCell.cellName)
//        view.register(GroupCell.self, forCellReuseIdentifier: GroupCell.cellName)
        view.register(AddContactCell.self, forCellReuseIdentifier: AddContactCell.cellName)
        view.register(GroupInviteCell.self, forCellReuseIdentifier: GroupInviteCell.cellName)
        view.register(RequestContactCell.self, forCellReuseIdentifier: RequestContactCell.cellName)
        view.register(ButtonTableCell.self, forCellReuseIdentifier: ButtonTableCell.cellName)
        view.register(MenuItemHeaderTableCell.self, forCellReuseIdentifier: MenuItemHeaderTableCell.cellName)
        
        view.separatorStyle = .singleLine
        view.applyContinuousSplitInsetGroupedAppearance()
        
        return view
    }()
    
    internal let emptyView: EmptyStateView = {
        let view = EmptyStateView()
        
        return view
    }()
    
    internal var isCellTapped: Bool = false
    
    var statusBarView: UIView?
    var blurredEffectView: UIVisualEffectView?
    
    internal var topAccountJid: String = ""
    
    internal var isEmptyViewShowed: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal var bag: DisposeBag = DisposeBag()
    internal var accountsBag: DisposeBag = DisposeBag()
    internal var enabledAccounts: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set())
    
    internal var datasource: [[Datasource]] = []
    internal var datasetGeneration: Int = 0
    internal var currentFeatureHasAnyContent: Bool = false
    internal var currentSnapshotIsResolved: Bool = false
    
    var pinnedAccount: Int = 0
    
    var lastScrollPosition: CGFloat = 0
    
    var collapsedAccounts: Set<String> = Set<String>()
    
    var showOffline: Bool = true
    open var isGroup: Bool = false {
        didSet {
            searchController.searchBar.placeholder = contactsSearchPlaceholderText
            bottomSearchHostView.searchTextField.placeholder = contactsSearchPlaceholderText
        }
    }
    
    internal var isFirstLayout: Bool = false
    
    open var categoryDelegate: ContactsCategoryDelegate? = nil
    
    internal let updateQueue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "com.xabber.contacts.updater",
            qos: .utility,
            attributes: [],
            autoreleaseFrequency: .never,
            target: nil
        )
        return queue
    }()
    
    private let localSearchResultsUpdater = EmptySearchResultsUpdater()
    internal var contactsSearchQuery: String? = nil

    internal lazy var searchController: UISearchController = {
        InPlaceSearchHostHelper.makeSearchController(
            updater: localSearchResultsUpdater,
            placeholder: contactsSearchPlaceholderText
        )
    }()

    internal let bottomSearchHostView = BottomSearchHostView(frame: .zero)
    internal let bottomOverlayInsetCoordinator = BottomOverlayInsetCoordinator()

    internal let contactsCompactBottomBarView = FloatingBottomBarView(frame: .zero)
    
    internal let addButton: UIBarButtonItem = {
        let button = UIBarButtonItem(barButtonSystemItem: .add, target: nil, action: nil)
        button.tintColor = .systemGray
        return button
    }()
    
    internal let accountNavButton: AccountNavButton = {
        let button = AccountNavButton(frame: CGRect(width: 64, height: 40))
        
        return button
    }()
    
    internal let customTitleLabel: UILabel = {
        let label = UILabel()
        
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 18, weight: UIFont.Weight.medium)
        
        return label
    }()
    
    override func resetState() {
        super.resetState()
        self.filteredGroups.removeAll()
        self.filteredAccounts.removeAll()
    }
    
    internal final func updateSectionHeaders(for accounts: [EnabledAccount]) {
        for (index, element) in accounts.enumerated() {
            guard let accountHeaderView = self.tableView.headerView(forSection: index) as? SectionHeader else {
                return
            }
            DispatchQueue.main.async {
                LeftMenuFirstPresentationPolicy.performWithoutAnimationsIfNeeded(
                    isQuietModeActive: self.isLeftMenuFirstPresentationQuietModeActive
                ) {
                    self.tableView.performBatchUpdates {
                        accountHeaderView.configure(collapsed: element.isCollapsed,
                                                    title: AccountManager.shared.find(for: element.jid)?.username ?? element.jid,
                                                    jid: element.jid,
                                                    subtitle: "\(element.contactsCount)",
                                                    color: AccountColorManager.shared.palette(for: element.jid).tint700)
                        accountHeaderView.layoutIfNeeded()
                    }
                }
            }
            
        }
    }
    
    var filteredAccounts: Set<String> = Set()
    var filteredGroups: Set<String> = Set()
    var category: String? = nil //{
    //        didSet {
    //            if UIDevice.current.userInterfaceIdiom == .pad {
    //                self.navigationItem.title = nil
    //            } else {
    //                switch self.category {
    //                    case "all": self.navigationItem.title = "All"
    //                    case "online": self.navigationItem.title = "Online"
    //                    case "subscribtions": self.navigationItem.title = "Contact requests"
    //                    case "requests": self.navigationItem.title = "Outgoing requests"
    //                    default: self.navigationItem.title = "All"
    //                }
    //            }
    //        }
    //    }
    
    var hasContactsRequestSection: Bool = false

    internal var contactsSearchPlaceholderText: String {
        isGroup
            ? "Search groups".localizeString(id: "groups_search_hint", arguments: [])
            : "Search contacts".localizeString(id: "contact_search_hint", arguments: [])
    }
    
    internal func currentFilterState() -> ContactsFilterState {
        ContactsFilterState(
            category: category,
            filteredAccounts: filteredAccounts,
            filteredGroups: filteredGroups,
            showOffline: showOffline,
            isGroup: isGroup,
            searchQuery: contactsSearchQuery
        )
    }

    internal final var isContactsCompactBottomBarHidden: Bool {
        contactsCompactBottomBarView.superview == nil || contactsCompactBottomBarView.isHidden
    }

    internal final var contactsCompactBottomBarCenterTitle: String? {
        contactsCompactBottomBarView.centerButton.title(for: .normal)
    }

    internal final var isContactsCompactOnlineFilterActive: Bool {
        showOffline == false
    }

    internal final var contactsCompactBottomBarFilterButton: UIButton {
        contactsCompactBottomBarView.leftButton
    }

    internal final var contactsCompactBottomBarPrimaryButton: UIButton {
        contactsCompactBottomBarView.centerButton
    }

    internal static func visibleDatasourceIsEmpty(_ datasource: [[Datasource]]) -> Bool {
        !datasource.contains { section in
            section.contains { !$0.isHeader }
        }
    }

    internal static func emptyStateDescriptor(
        isGroup: Bool,
        category: String?,
        filteredGroups: Set<String>,
        hasResolvedSnapshot: Bool,
        visibleDatasourceIsEmpty: Bool,
        featureHasAnyContent: Bool,
        isSearchActive: Bool
    ) -> CoreListEmptyStateDescriptor? {
        guard hasResolvedSnapshot, visibleDatasourceIsEmpty, !isSearchActive else {
            return nil
        }

        if !featureHasAnyContent {
            if isGroup {
                return CoreListEmptyStateDescriptor(
                    iconSystemName: "person.2.circle",
                    title: "No groups yet".localizeString(id: "groups_empty_title", arguments: []),
                    subtitle: "Create a public group to start a shared conversation.".localizeString(id: "groups_empty_subtitle", arguments: []),
                    buttonTitle: "Create Public Group".localizeString(id: "groups_empty_create_public_group", arguments: []),
                    buttonAccessibilityIdentifier: "groups_empty_create_public_group_button",
                    action: .createPublicGroup
                )
            }

            return CoreListEmptyStateDescriptor(
                iconSystemName: "person.crop.circle.badge.plus",
                title: "No contacts yet".localizeString(id: "contacts_empty_title", arguments: []),
                subtitle: "Add your first contact to start messaging and calling.".localizeString(id: "contacts_empty_subtitle", arguments: []),
                buttonTitle: "Add Contact".localizeString(id: "contacts_empty_add_contact", arguments: []),
                buttonAccessibilityIdentifier: "contacts_empty_add_contact_button",
                action: .addContact
            )
        }

        return CoreListEmptyStateDescriptor(
            iconSystemName: isGroup ? "person.2.circle" : "person.crop.circle",
            title: emptyStateTitle(isGroup: isGroup, category: category, filteredGroups: filteredGroups),
            subtitle: "",
            buttonTitle: nil,
            buttonAccessibilityIdentifier: nil,
            action: nil
        )
    }

    internal static func emptyStateTitle(isGroup: Bool, category: String?, filteredGroups: Set<String>) -> String {
        let groupsString = filteredGroups.sorted().joined(separator: ", ")
        switch category {
        case "all":
            return filteredGroups.isNotEmpty ? "No contacts found for \(groupsString)" : "No contacts found"
        case "online":
            return filteredGroups.isNotEmpty ? "No online contacts found for \(groupsString)" : "No contacts online"
        case "subscriptions", "subscribtions":
            return "No contact requests"
        case "requests":
            return "No outgoing contact requests"
        case "public":
            return filteredGroups.isNotEmpty ? "No public groups found for \(groupsString)" : "No public groups found"
        case "incognito":
            return filteredGroups.isNotEmpty ? "No incognito groups found for \(groupsString)" : "No incognito groups found"
        case "private":
            return filteredGroups.isNotEmpty ? "No private chats found for \(groupsString)" : "No private chats found"
        case "invitations":
            return "No invitations found"
        default:
            if isGroup {
                return filteredGroups.isNotEmpty ? "No groups found for \(groupsString)" : "No groups found"
            }
            return filteredGroups.isNotEmpty ? "No contacts found for \(groupsString)" : "No contacts found"
        }
    }
    
    private final func mapDataset(state: ContactsFilterState, context: ContactsListSupport.Context) -> [[Datasource]] {
        do {
            if state.isGroup {
                return try self.mapDatasetGroups(state: state, context: context)
            } else {
                return try self.mapDatasetContacts(state: state, context: context)
            }
        } catch {
            return [[]]
        }
        
    }
    
    private final func mapDatasetContacts(state: ContactsFilterState, context: ContactsListSupport.Context) throws -> [[Datasource]] {
        hasContactsRequestSection = false
        var categoryHeader: [Datasource] = []
        var out: [Datasource] = []
        
        let requests = context.contactRosterItems.filter { $0.ask_ == "in" }
        let outgoingRequests = context.contactRosterItems.filter { $0.ask_ == "out" }
        
        if state.category == nil && state.filteredGroups.isEmpty {
            if requests.isNotEmpty {
                hasContactsRequestSection = true
                out.append(Datasource(
                    owner: "",
                    title: "Contact requests",
                    jid: "",
                    subtitle: "\(requests.count)",
                    groups: [],
                    conversationType: .regular,
                    isButton: true,
                    value: "show_all_contacts"
                ))
            }
            out.append(contentsOf: requests.sorted(by: { $0.jid > $1.jid }).prefix(3).compactMap {
                contact in
                return Datasource(
                    owner: contact.owner,
                    title: contact.displayName,
                    jid: contact.jid,
                    subtitle: contact.jid,
                    avatarUrl: contact.avatarUrl,
                    groups: Array(Set((contact.groups).toArray())).sorted(),
                    conversationType: ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular,
                    isSubscribtionRequest: true
                )
            })
            
        }
        if state.category == "subscribtions" {
            categoryHeader.append(Datasource(
                owner: "",
                title: "Contact Requests",
                jid: "",
                subtitle: "List of incoming contact requests. After accepting, contacts can message freely and share presence information.",
                groups: [],
                conversationType: .regular,
                isHeader: true,
                icon: "custom.person.text.rectangle.square.fill"
            ))
            out.append(contentsOf: requests.sorted(by: { $0.jid > $1.jid }).compactMap {
                contact in
                return Datasource(
                    owner: contact.owner,
                    title: contact.displayName,
                    jid: contact.jid,
                    subtitle: contact.jid,
                    avatarUrl: contact.avatarUrl,
                    groups: Array(Set((contact.groups).toArray())).sorted(),
                    conversationType: ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular,
                    isSubscribtionRequest: true
                )
            })
        }
        if state.category == "requests" {
            categoryHeader.append(Datasource(
                owner: "",
                title: "Outgoing Requests",
                jid: "",
                subtitle: "List of outgoing contact requests. After accepting, contacts would start sharing presence information.",
                groups: [],
                conversationType: .regular,
                isHeader: true,
                icon: "xabber.person.plus.square.fill"
            ))
            out.append(contentsOf: outgoingRequests.sorted(by: { $0.jid > $1.jid }).compactMap {
                contact in
                return Datasource(
                    owner: contact.owner,
                    title: contact.displayName,
                    jid: contact.jid,
                    subtitle: contact.jid,
                    avatarUrl: contact.avatarUrl,
                    groups: Array(Set((contact.groups).toArray())).sorted(),
                    conversationType: ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular,
                    isContactRequest: true
                )
            })
        }
        if state.category == nil || state.category == "online" || state.category == "all" {
            out.append(contentsOf: context.joinedContactRosterItems
                .sorted(by: { ($0.displayName.lowercased() < $1.displayName.lowercased()) })
                .compactMap({
                    contact in
                    guard ContactsListSupport.includeContact(contact, state: state) else {
                        return nil
                    }
                    let status = contact.getPrimaryResource()?.status ?? .offline
                    let entity = contact.getPrimaryResource()?.entity ?? .contact
                    return Datasource(
                        owner: contact.owner,
                        title: contact.displayName,
                        jid: contact.jid,
                        subtitle: contact.jid,
                        avatarUrl: contact.avatarUrl,
                        groups: Array(Set((contact.groups).toArray())).sorted(),
                        conversationType: ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular,
                        isSubscribtionRequest: false,
                        status: status,
                        entity: entity
                    )
                }))
        }
        
        if categoryHeader.isNotEmpty {
            if ContactsListSupport.hasSearchQuery(state.searchQuery) {
                return [ContactsListSupport.filteredDatasourceRows(out, searchQuery: state.searchQuery)]
            }
            return [categoryHeader, ContactsListSupport.filteredDatasourceRows(out, searchQuery: state.searchQuery)]
        } else {
            return [ContactsListSupport.filteredDatasourceRows(out, searchQuery: state.searchQuery)]
        }
    }
    
    private final func mapDatasetGroups(state: ContactsFilterState, context: ContactsListSupport.Context) throws -> [[Datasource]] {
//        public incognito private invitations
        hasContactsRequestSection = false
        
        var categoryHeader: [Datasource] = []
        var out: [Datasource] = []
        
        let requests = context.invites.filter { $0.isRead == false }
        
        if state.category == nil && state.filteredGroups.isEmpty {
            if requests.isNotEmpty {
                hasContactsRequestSection = true
                out.append(Datasource(
                    owner: "",
                    title: "Invites",
                    jid: "",
                    subtitle: "show all",
                    groups: [],
                    conversationType: .regular,
                    isButton: true,
                    value: "show_all_invites"
                ))
            }
            out.append(contentsOf: requests.sorted(by: { $0.jid > $1.jid }).prefix(3).compactMap {
                invite in
                let groupInstance = ContactsListSupport.groupchat(for: invite.groupchat, owner: invite.owner, context: context)
                let memberStats = ContactsListSupport.memberStats(groupchatJid: invite.groupchat, owner: invite.owner, context: context)
                let rosterItem = ContactsListSupport.rosterItem(for: invite.groupchat, owner: invite.owner, context: context)
                let invitedBy = ContactsListSupport.rosterItem(for: invite.jid, owner: invite.owner, context: context)?.displayName ?? invite.jid
                var entity: RosterItemEntity = .groupchat
                if groupInstance?.privacy == .incognito {
                    entity = .incognitoChat
                }
                if (groupInstance?.peerToPeer ?? false) {
                    entity = .privateChat
                }
                
                return Datasource(
                    owner: invite.owner,
                    title: groupInstance?.name ?? invite.jid,
                    jid: invite.groupchat,
                    subtitle: invite.reason ?? "",
                    avatarUrl: rosterItem?.avatarUrl,
                    groups: [],
                    conversationType: .group,
                    isInvite: true,
                    value: invitedBy,
                    bottomLine: String.membersAndContactsString(members: groupInstance?.members ?? memberStats.members, contacts: memberStats.contacts),
                    descr: groupInstance?.descr,
                    members: memberStats.membersList,
                    status: rosterItem?.getPrimaryResource()?.status ?? .away,
                    entity: rosterItem?.getPrimaryResource()?.entity ?? entity,
                    primary: invite.primary
                )
            })
        }
        
        if state.category == "invitations" {
            categoryHeader.append(Datasource(
                owner: "",
                title: "Invitations",
                jid: "",
                subtitle: "View the list of received invitations to join both public and incognito groups.",
                groups: [],
                conversationType: .regular,
                isHeader: true,
                icon: "xabber.invite.square.fill"
            ))
            out.append(contentsOf: requests.sorted(by: { $0.date.timeIntervalSince1970 > $1.date.timeIntervalSince1970 }).compactMap {
                invite in
                let groupInstance = ContactsListSupport.groupchat(for: invite.groupchat, owner: invite.owner, context: context)
                let memberStats = ContactsListSupport.memberStats(groupchatJid: invite.groupchat, owner: invite.owner, context: context)
                let rosterItem = ContactsListSupport.rosterItem(for: invite.groupchat, owner: invite.owner, context: context)
                let invitedBy = ContactsListSupport.rosterItem(for: invite.jid, owner: invite.owner, context: context)?.displayName ?? invite.jid
                var entity: RosterItemEntity = .groupchat
                if groupInstance?.privacy == .incognito {
                    entity = .incognitoChat
                }
                if (groupInstance?.peerToPeer ?? false) {
                    entity = .privateChat
                }
                
                return Datasource(
                    owner: invite.owner,
                    title: groupInstance?.name ?? invite.jid,
                    jid: invite.groupchat,
                    subtitle: invite.reason ?? "",
                    avatarUrl: rosterItem?.avatarUrl,
                    groups: [],
                    conversationType: .group,
                    isInvite: true,
                    value: invitedBy,
                    bottomLine: String.membersAndContactsString(members: groupInstance?.members ?? memberStats.members, contacts: memberStats.contacts),
                    descr: groupInstance?.descr,
                    members: memberStats.membersList,
                    status: rosterItem?.getPrimaryResource()?.status ?? .away,
                    entity: rosterItem?.getPrimaryResource()?.entity ?? entity,
                    primary: invite.primary
                )
            })
        }
        if state.category == "public" {
            let groups = context.groupChats.filter {
                $0.privacy == .publicChat && $0.peerToPeer == false && !context.ignoredJids.contains($0.jid)
            }
            categoryHeader.append(Datasource(
                owner: "",
                title: "Public Groups",
                jid: "",
                subtitle: "In public groups, members can see XMPP IDs of other participants.",
                groups: [],
                conversationType: .regular,
                isHeader: true,
                icon: "custom.person.2.square.fill"
            ))
            out.append(contentsOf: groups.sorted(by: { $0.jid > $1.jid }).compactMap {
                group in
                guard let contact = ContactsListSupport.rosterItem(for: group.jid, owner: group.owner, context: context) else {
                    return nil
                }
                guard ContactsListSupport.includeGroup(contact: contact, state: state) else {
                    return nil
                }
                let memberStats = ContactsListSupport.memberStats(groupchatJid: group.jid, owner: group.owner, context: context)
                var entity: RosterItemEntity = .groupchat
                if group.privacy == .incognito {
                    entity = .incognitoChat
                }
                if group.peerToPeer {
                    entity = .privateChat
                }
                
                return Datasource(
                    owner: group.owner,
                    title: group.name,
                    jid: contact.jid,
                    subtitle: group.descr,
                    avatarUrl: contact.avatarUrl,
                    groups: Array(Set(contact.groups.toArray())).sorted(),
                    conversationType: .group,
                    bottomLine: String.membersAndContactsString(members: memberStats.members, contacts: memberStats.contacts),
                    status: contact.getPrimaryResource()?.status ?? group.statusDisplayed,
                    entity: contact.getPrimaryResource()?.entity ?? entity
                )
            })
        }
        if state.category == "incognito" {
            let groups = context.groupChats.filter {
                $0.privacy == .incognito && $0.peerToPeer == false && !context.ignoredJids.contains($0.jid)
            }
            categoryHeader.append(Datasource(
                owner: "",
                title: "Incognito Groups",
                jid: "",
                subtitle: "In incognito groups, members use pseudonyms, hiding XMPP IDs from others.",
                groups: [],
                conversationType: .regular,
                isHeader: true,
                icon: "xabber.incognito.square.fill"
            ))
            out.append(contentsOf: groups.sorted(by: { $0.jid > $1.jid }).compactMap {
                group in
                guard let contact = ContactsListSupport.rosterItem(for: group.jid, owner: group.owner, context: context) else {
                    return nil
                }
                guard ContactsListSupport.includeGroup(contact: contact, state: state) else {
                    return nil
                }
                let memberStats = ContactsListSupport.memberStats(groupchatJid: group.jid, owner: group.owner, context: context)
                var entity: RosterItemEntity = .groupchat
                if group.privacy == .incognito {
                    entity = .incognitoChat
                }
                if group.peerToPeer {
                    entity = .privateChat
                }
                return Datasource(
                    owner: group.owner,
                    title: group.name,
                    jid: contact.jid,
                    subtitle: group.descr,
                    avatarUrl: contact.avatarUrl,
                    groups: Array(Set(contact.groups.toArray())).sorted(),
                    conversationType: .group,
                    bottomLine: String.membersAndContactsString(members: memberStats.members, contacts: memberStats.contacts),
                    status: contact.getPrimaryResource()?.status ?? group.statusDisplayed,
                    entity: contact.getPrimaryResource()?.entity ?? entity
                )
            })
        }
        if state.category == "private" {
            let groups = context.groupChats.filter {
                $0.peerToPeer == true && !context.ignoredJids.contains($0.jid)
            }
            categoryHeader.append(Datasource(
                owner: "",
                title: "Private Chats",
                jid: "",
                subtitle: "One-on-one chats with users of incognito groups, with real XMPP IDs hidden.",
                groups: [],
                conversationType: .regular,
                isHeader: true,
                icon: "custom.bubble.square.fill"
            ))
            out.append(contentsOf: groups.sorted(by: { $0.jid > $1.jid }).compactMap {
                group in
                guard let contact = ContactsListSupport.rosterItem(for: group.jid, owner: group.owner, context: context) else {
                    return nil
                }
                guard ContactsListSupport.includeGroup(contact: contact, state: state) else {
                    return nil
                }
                let memberStats = ContactsListSupport.memberStats(groupchatJid: group.jid, owner: group.owner, context: context)
                var entity: RosterItemEntity = .groupchat
                if group.privacy == .incognito {
                    entity = .incognitoChat
                }
                if group.peerToPeer {
                    entity = .privateChat
                }
                
                return Datasource(
                    owner: group.owner,
                    title: group.name,
                    jid: contact.jid,
                    subtitle: group.descr,
                    avatarUrl: contact.avatarUrl,
                    groups: Array(Set(contact.groups.toArray())).sorted(),
                    conversationType: .group,
                    bottomLine: String.membersAndContactsString(members: memberStats.members, contacts: memberStats.contacts),
                    status: group.statusDisplayed,
                    entity: entity
                )
            })
        }
        if state.category == nil || state.category == "all" {
            let groups = context.groupChats.filter {
                $0.peerToPeer == false && !context.ignoredJids.contains($0.jid)
            }
            
            out.append(contentsOf: groups.sorted(by: { $0.name < $1.name })
                .compactMap({
                    group in
                    if group.name.isEmpty {
                        return nil
                    }
                    guard let contact = ContactsListSupport.rosterItem(for: group.jid, owner: group.owner, context: context) else {
                        return nil
                    }
                    guard ContactsListSupport.includeGroup(contact: contact, state: state) else {
                        return nil
                    }
                    let memberStats = ContactsListSupport.memberStats(groupchatJid: group.jid, owner: group.owner, context: context)
                    var entity: RosterItemEntity = .groupchat
                    if group.privacy == .incognito {
                        entity = .incognitoChat
                    }
                    if group.peerToPeer {
                        entity = .privateChat
                    }
                    return Datasource(
                        owner: group.owner,
                        title: group.name,
                        jid: group.jid,
                        subtitle: group.descr,
                        avatarUrl: contact.avatarUrl,
                        groups: Array(Set(contact.groups.toArray())).sorted(),
                        conversationType: .group,
                        bottomLine: String.membersAndContactsString(members: memberStats.members, contacts: memberStats.contacts),
                        status: contact.getPrimaryResource()?.status ?? group.statusDisplayed,
                        entity: entity
                    )
                }))
        }
        out = out.sorted(by: { $0.isHeader == true && $0.status.statusToSortedItem() > $1.status.statusToSortedItem() })
        if categoryHeader.isNotEmpty {
            if ContactsListSupport.hasSearchQuery(state.searchQuery) {
                return [ContactsListSupport.filteredDatasourceRows(out, searchQuery: state.searchQuery)]
            }
            return [categoryHeader, ContactsListSupport.filteredDatasourceRows(out, searchQuery: state.searchQuery)]
        } else {
            return [ContactsListSupport.filteredDatasourceRows(out, searchQuery: state.searchQuery)]
        }
    }
    
    public final func initializeDataset() {
        
    }

    
    public final func runDatasetUpdateTask(force: Bool = false) {
        let generation = datasetGeneration + 1
        datasetGeneration = generation
        let state = currentFilterState()
        
        updateQueue.async { [weak self] in
            guard let self = self else { return }
            let realm = try? WRealm.safe()
            let result: (datasource: [[Datasource]], featureHasAnyContent: Bool, hasResolvedSnapshot: Bool) = realm.map {
                let derivedState = ContactsListCoordinator.deriveState(
                    realm: $0,
                    state: state,
                    datasourceBuilder: self.mapDataset(state:context:)
                )
                let featureState = ContactsFilterState(
                    category: nil,
                    filteredAccounts: [],
                    filteredGroups: [],
                    showOffline: true,
                    isGroup: state.isGroup,
                    searchQuery: nil
                )
                let featureContext = ContactsListSupport.makeContext(realm: $0, state: featureState)
                let featureHasAnyContent = state.isGroup
                    ? ContactsListSupport.hasAnyGroupAreaContent(context: featureContext)
                    : ContactsListSupport.hasAnyContactAreaContent(context: featureContext)
                let hasResolvedSnapshot = derivedState.context.accountJids.isNotEmpty || featureContext.accountJids.isNotEmpty

                return (
                    datasource: derivedState.datasource,
                    featureHasAnyContent: featureHasAnyContent,
                    hasResolvedSnapshot: hasResolvedSnapshot
                )
            } ?? (datasource: [[]], featureHasAnyContent: false, hasResolvedSnapshot: false)
            
            DispatchQueue.main.async {
                guard self.datasetGeneration == generation else { return }
                self.applyMappedDataset(
                    result.datasource,
                    featureHasAnyContent: result.featureHasAnyContent,
                    hasResolvedSnapshot: result.hasResolvedSnapshot,
                    forceFullReload: force
                )
                self.postprocessDataset()
            }
        }
    }
    
    internal final func applyMappedDataset(_ newDatasource: [[Datasource]], featureHasAnyContent: Bool, hasResolvedSnapshot: Bool, forceFullReload: Bool) {
        currentFeatureHasAnyContent = featureHasAnyContent
        currentSnapshotIsResolved = hasResolvedSnapshot

        func refreshEmptyStateAfterDatasourceUpdate() {
            self.updateEmptyState(
                for: self.datasource,
                featureHasAnyContent: featureHasAnyContent,
                hasResolvedSnapshot: hasResolvedSnapshot,
                isSearchActive: self.bottomSearchHostView.isExpanded
            )
        }

        func forceReload() {
            LeftMenuFirstPresentationPolicy.performWithoutAnimationsIfNeeded(
                isQuietModeActive: self.isLeftMenuFirstPresentationQuietModeActive
            ) {
                self.datasource = newDatasource
                self.tableView.reloadData()
            }
        }
        func reloadCompatibleSections(_ sections: IndexSet) {
            self.datasource = newDatasource
            guard !sections.isEmpty else { return }
            UIView.performWithoutAnimation {
                self.tableView.reloadSections(sections, with: .none)
            }
        }
        if forceFullReload {
            forceReload()
            refreshEmptyStateAfterDatasourceUpdate()
        } else if newDatasource.isEmpty {
            forceReload()
            refreshEmptyStateAfterDatasourceUpdate()
        } else if self.datasource.count != newDatasource.count {
            forceReload()
            refreshEmptyStateAfterDatasourceUpdate()
        } else {
            guard let lastPartOldDatasource = self.datasource.last,
                  !(lastPartOldDatasource.first?.isHeader ?? false),
                  let lastPartNewDatasource = newDatasource.last,
                  !(lastPartNewDatasource.first?.isHeader ?? false) else {
                forceReload()
                refreshEmptyStateAfterDatasourceUpdate()
                return
            }
            let changes = diff(old: lastPartOldDatasource, new: lastPartNewDatasource)
            let indexPaths = self.convertChangeset(changes: changes, section: newDatasource.count - 1)
            let changedPrefixSections = self.changedNonContentSections(newDatasource: newDatasource)
            UIView.performWithoutAnimation {
                self.apply(changes: indexPaths) {
                    self.datasource = newDatasource
                }
            }
            if !changedPrefixSections.isEmpty {
                reloadCompatibleSections(changedPrefixSections)
            }
            refreshEmptyStateAfterDatasourceUpdate()
        }
    }

    internal final func refreshEmptyStateVisibility(isSearchActive: Bool? = nil) {
        updateEmptyState(
            for: datasource,
            featureHasAnyContent: currentFeatureHasAnyContent,
            hasResolvedSnapshot: currentSnapshotIsResolved,
            isSearchActive: isSearchActive ?? bottomSearchHostView.isExpanded
        )
    }

    private final func updateEmptyState(for datasource: [[Datasource]], featureHasAnyContent: Bool, hasResolvedSnapshot: Bool, isSearchActive: Bool) {
        let descriptor = Self.emptyStateDescriptor(
            isGroup: isGroup,
            category: category,
            filteredGroups: filteredGroups,
            hasResolvedSnapshot: hasResolvedSnapshot,
            visibleDatasourceIsEmpty: Self.visibleDatasourceIsEmpty(datasource),
            featureHasAnyContent: featureHasAnyContent,
            isSearchActive: isSearchActive
        )

        if let descriptor = descriptor {
            configureEmptyView(with: descriptor)
        }

        let shouldShowEmptyState = descriptor != nil
        if isEmptyViewShowed.value != shouldShowEmptyState {
            isEmptyViewShowed.accept(shouldShowEmptyState)
        }
        emptyView.isHidden = !shouldShowEmptyState
    }

    private final func configureEmptyView(with descriptor: CoreListEmptyStateDescriptor) {
        emptyView.accessibilityIdentifier = isGroup ? "groups_empty_view" : "contacts_empty_view"
        emptyView.configure(descriptor: descriptor) { [weak self] in
            self?.performEmptyStateAction(descriptor.action)
        }
    }

    private final func performEmptyStateAction(_ action: CoreListEmptyStateAction?) {
        switch action {
        case .addContact:
            openAddContactFlow()
        case .createPublicGroup:
            openCreatePublicGroupFlow()
        case .startCall, .none:
            break
        }
    }

    private final func changedNonContentSections(newDatasource: [[Datasource]]) -> IndexSet {
        guard datasource.count == newDatasource.count, datasource.count > 1 else {
            return []
        }

        var changedSections = IndexSet()
        for section in 0..<(newDatasource.count - 1) {
            let oldSection = datasource[section]
            let newSection = newDatasource[section]
            guard oldSection.count == newSection.count else {
                changedSections.insert(section)
                continue
            }
            if zip(oldSection, newSection).contains(where: { $0 != $1 || !ContactsViewController.Datasource.compareContent($0, $1) }) {
                changedSections.insert(section)
            }
        }
        return changedSections
    }
    
    private final func apply(changes: ChangesWithIndexPath, prepare: @escaping (() -> Void)) {
        
        if changes.deletes.isEmpty &&
            changes.inserts.isEmpty &&
            changes.moves.isEmpty &&
            changes.replaces.isEmpty {
            prepare()
            return
        }
        
        let rowAnimation = LeftMenuFirstPresentationPolicy.rowAnimation(
            requested: .automatic,
            isQuietModeActive: isLeftMenuFirstPresentationQuietModeActive
        )
        LeftMenuFirstPresentationPolicy.performWithoutAnimationsIfNeeded(
            isQuietModeActive: isLeftMenuFirstPresentationQuietModeActive
        ) {
            self.tableView.performBatchUpdates({
                prepare()
                if !changes.deletes.isEmpty {
                    self.tableView.deleteRows(at: changes.deletes, with: rowAnimation)
                }
                if !changes.inserts.isEmpty {
                    self.tableView.insertRows(at: changes.inserts, with: rowAnimation)
                }
                if changes.moves.isNotEmpty {
                    changes.moves.forEach {
                        (from, to) in
                        self.tableView.moveRow(at: from, to: to)
                    }
                }
            }, completion: { result in
                if changes.replaces.isEmpty { return }
                UIView.performWithoutAnimation {
                    //may be increase performance
                    self.tableView.reconfigureRows(at: changes.replaces)
//                    self.tableView.reloadRows(at: changes.replaces, with: .none)
                }
            })
        }
    }
    
    private final func postprocessDataset() {
        
    }
    
    private final func convertChangeset(changes: [Change<Datasource>], section: Int) -> ChangesWithIndexPath {
        let inserts =  changes.compactMap { return $0.insert?.index }.compactMap({ return IndexPath(row:$0, section:  section)})
        let deletes =  changes.compactMap { return $0.delete?.index }.compactMap({ return IndexPath(row:$0, section:  section )})
        var replaces = changes.compactMap { return $0.replace?.index }.compactMap({ return IndexPath(row:$0, section: section )})
        
        let moves = changes.compactMap({ $0.move }).map({
          (
            from: IndexPath(item: $0.fromIndex, section: section),
            to: IndexPath(item: $0.toIndex, section: section)
          )
        })
        if section != 0 {
            replaces.append(IndexPath(row: 0, section: 0))
        }
        return ChangesWithIndexPath(
            inserts: inserts,
            deletes: deletes,
            replaces: replaces,
            moves: moves
        )
    }
    
    internal func subscribe() {
        accountsBag = DisposeBag()
        bag = DisposeBag()
        do {
            let realm = try  WRealm.safe()
            let accountsCollection = realm.objects(AccountStorageItem.self).filter("enabled == true")
            let rosterCollection = realm.objects(RosterStorageItem.self)
            let groupchatCollection = realm.objects(GroupChatStorageItem.self)
            let groupUsersCollection = realm.objects(GroupchatUserStorageItem.self).filter("isHidden == false")
            let groupsCollection = realm.objects(RosterGroupStorageItem.self).filter("isSystemGroup == false")
            
            var invalidations: [Observable<Void>] = [
                Observable.collection(from: accountsCollection).map { _ in () },
                Observable.collection(from: rosterCollection).map { _ in () },
                Observable.collection(from: groupsCollection).map { _ in () }
            ]
            
            if isGroup {
                let invitesCollection = realm.objects(GroupchatInvitesStorageItem.self)
                invalidations.append(Observable.collection(from: invitesCollection).map { _ in () })
                invalidations.append(Observable.collection(from: groupchatCollection).map { _ in () })
                invalidations.append(Observable.collection(from: groupUsersCollection).map { _ in () })
            }
            
            Observable.merge(invalidations)
                .debounce(.milliseconds(150), scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { [weak self] in
                    self?.runDatasetUpdateTask()
                })
                .disposed(by: self.bag)
        } catch {
            DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
        }
        
        AccountManager
            .shared
            .connectingUsers
            .asObservable()
            .debounce(.milliseconds(250), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                DispatchQueue.main.async {
                    self.updateTitle()
                }
            })
            .disposed(by: accountsBag)
        
        isEmptyViewShowed
            .asObservable()
            .subscribe(onNext: { (value) in
                self.emptyView.isHidden = !value
            })
            .disposed(by: bag)
        
        
        
    }
    
    internal func unsubscribe() {
        accountsBag = DisposeBag()
        bag = DisposeBag()
    }
    
    @objc
    internal func onAccountNavButtonPress(_ sender: UIButton) {
        let vc = SettingsViewController() //AccountInfoViewController()
        vc.jid = self.topAccountJid
        self.navigationController?.pushViewController(vc, animated: true)
    }
    
    internal let bottomBar: BottomBarView = {
        let view = BottomBarView(frame: .zero)
        
        return view
    }()
    
    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil
    
    @objc
    private final func onBackButtonTouchUpInside(_ sender: UIBarButtonItem) {
        self.leftMenuDelegate?.selectRootScreenAndCategory(screen: "chat", category: nil)
    }
    
    @objc
    private func onSidebarButtonTouchUp(_ sender: UIBarButtonItem) {
        self.splitViewController?.show(.primary)
    }
    
    internal let securityButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: UIImage(named: "security"), style: UIBarButtonItem.Style.plain, target: nil, action: nil)
        
        button.tintColor = .systemGray
        
        return button
    }()
    
    @objc
    func showSettings(_ sender: AnyObject) {
        let vc = SettingsViewController()
        vc.jid = AccountManager.shared.users.first?.jid ?? ""
        vc.owner = AccountManager.shared.users.first?.jid ?? ""
        showModal(vc, parent: self)
    }
    
    @objc
    func onAddButtonTouchUpInside(_ sender: AnyObject) {
        let vc = CreateNewEntityViewController()
        
        showModal(vc, parent: self)
    }

    internal func openAddContactFlow() {
        showModal(makeAddContactFlowViewController(), parent: self)
    }

    internal func openCreatePublicGroupFlow() {
        showModal(makeCreatePublicGroupFlowViewController(), parent: self)
    }

    internal func makeAddContactFlowViewController() -> UIViewController {
        let vc = AddNewContactViewController()
        vc.leftMenuSelectRootCategoryDelegate = leftMenuDelegate
        return vc
    }

    internal func makeCreatePublicGroupFlowViewController() -> UIViewController {
        let vc = CreateNewGroupViewController()
        vc.createIncognitoGroup = false
        vc.leftMenuSelectRootCategoryDelegate = leftMenuDelegate
        return vc
    }
    
    internal final func showRegisterYubikeyDialog() {
        if SignatureManager.shared.certificate != nil {
            let vc = YubikeySetupViewController()
            vc.isFromOnboarding = false
            vc.isModal = true
            vc.owner = AccountManager.shared.users.first?.jid ?? ""
            self.navigationController?.pushViewController(vc, animated: true)
        } else {
            SignatureManager.shared.delegate = self
            FeedbackManager.shared.tap()
            if #available(iOS 13.0, *) {
                if YubiKitDeviceCapabilities.supportsISO7816NFCTags {
                    YubiKitExternalLocalization.nfcScanAlertMessage = "Register Yubikey for account"
                    YubiKitManager.shared.startNFCConnection()
                    YubiKitManager.shared.delegate = SignatureManager.shared
                    SignatureManager.shared.currentAction = .certificate
                }
            }
        }
    }
    
    @objc
    internal func onRegisterYubikey() {
        showRegisterYubikeyDialog()
    }
    
    enum Filter: String {
        case all = "all"
        case online = "online"
        case subscribtions = "subscribtions"
        case requests = "requests"
    }
    
    var filter: BehaviorRelay<Filter> = BehaviorRelay(value: .all)
    var filterAccount: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    var filterMenu: UIMenu = UIMenu()

    private var contactsNavigationPrefix: String {
        isGroup ? "groups" : "contacts"
    }

    private lazy var contactsBackButton: UIBarButtonItem = {
        let button = UIBarButtonItem(
            image: imageLiteral("chevron.left"),
            style: .plain,
            target: self,
            action: #selector(onBackButtonTouchUpInside)
        )
        button.accessibilityIdentifier = "\(contactsNavigationPrefix)_back_to_chats_button"
        return button
    }()

    private lazy var contactsFilterButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), style: .plain, target: self, action: nil)
        button.accessibilityIdentifier = "\(contactsNavigationPrefix)_filter_menu_button"
        return button
    }()

    private lazy var contactsAddButton: UIBarButtonItem = {
        let button = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(onAddButtonTouchUpInside)
        )
        button.accessibilityIdentifier = "\(contactsNavigationPrefix)_add_button"
        return button
    }()

    private func makeContactsBackButton() -> UIBarButtonItem {
        contactsBackButton
    }

    private func makeContactsFilterButton() -> UIBarButtonItem {
        contactsFilterButton
    }

    private func makeContactsAddButton() -> UIBarButtonItem {
        contactsAddButton
    }

    private var shouldUseContactsCompactBottomBar: Bool {
        effectiveHorizontalSizeClass == .compact
    }

    private var effectiveHorizontalSizeClass: UIUserInterfaceSizeClass {
        if let navigationSizeClass = navigationController?.traitCollection.horizontalSizeClass,
           navigationSizeClass != .unspecified {
            return navigationSizeClass
        }
        return traitCollection.horizontalSizeClass
    }

    private var contactsCompactBottomBarPrimaryTitle: String {
        if isGroup {
            return "Create Group".localizeString(id: "create_group", arguments: [])
        }
        return "Add Contact".localizeString(id: "contacts_empty_add_contact", arguments: [])
    }

    internal final func installContactsCompactBottomBarIfNeeded() {
        guard isViewLoaded, shouldUseContactsCompactBottomBar else { return }
        guard contactsCompactBottomBarView.superview == nil else {
            view.bringSubviewToFront(contactsCompactBottomBarView)
            view.bringSubviewToFront(bottomSearchHostView)
            return
        }

        view.addSubview(contactsCompactBottomBarView)
        contactsCompactBottomBarView.leftButton.addTarget(
            self,
            action: #selector(onContactsCompactFilterButtonTouchUpInside),
            for: .touchUpInside
        )
        contactsCompactBottomBarView.centerButton.addTarget(
            self,
            action: #selector(onContactsCompactPrimaryButtonTouchUpInside),
            for: .touchUpInside
        )

        NSLayoutConstraint.activate([
            contactsCompactBottomBarView.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -FloatingBottomBarView.Metrics.bottomOffset
            ),
            contactsCompactBottomBarView.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: FloatingBottomBarView.Metrics.horizontalInset
            ),
            contactsCompactBottomBarView.trailingAnchor.constraint(
                equalTo: bottomSearchHostView.collapsedButton.leadingAnchor,
                constant: -NativeGlassBarStyle.interItemSpacing
            ),
            contactsCompactBottomBarView.heightAnchor.constraint(equalToConstant: FloatingBottomBarView.Metrics.height)
        ])

        view.bringSubviewToFront(contactsCompactBottomBarView)
        view.bringSubviewToFront(bottomSearchHostView)
    }

    internal final func updateContactsCompactBottomBarState() {
        guard isViewLoaded else { return }

        if shouldUseContactsCompactBottomBar {
            installContactsCompactBottomBarIfNeeded()
        }

        let prefix = contactsNavigationPrefix
        let active = isContactsCompactOnlineFilterActive
        contactsCompactBottomBarView.leftButton.accessibilityIdentifier = "\(prefix)_online_filter_button"
        contactsCompactBottomBarView.leftButton.accessibilityLabel = isGroup ? "Online groups filter" : "Online contacts filter"
        contactsCompactBottomBarView.updateLeftButton(
            imageName: active ? "person.fill" : "person",
            isActive: active
        )

        contactsCompactBottomBarView.setCenterButtonTitle(
            contactsCompactBottomBarPrimaryTitle,
            accessibilityIdentifier: isGroup
                ? "groups_create_group_bottom_button"
                : "contacts_add_contact_bottom_button",
            accessibilityLabel: contactsCompactBottomBarPrimaryTitle
        )
        contactsCompactBottomBarView.setCenterButtonEnabled(true)
        contactsCompactBottomBarView.isHidden = !shouldUseContactsCompactBottomBar ||
            bottomSearchHostView.hidesUnderlyingActions
        contactsCompactBottomBarView.refreshAppearance()

        if contactsCompactBottomBarView.superview != nil {
            view.bringSubviewToFront(contactsCompactBottomBarView)
            view.bringSubviewToFront(bottomSearchHostView)
        }
        updateTableInsetsForBottomSearch()
    }

    @objc
    private final func onContactsCompactFilterButtonTouchUpInside(_ sender: UIButton) {
        if isGroup {
            showOffline.toggle()
            runDatasetUpdateTask(force: true)
            updateContactsCompactBottomBarState()
            return
        }

        shouldFilterBy(category: isContactsCompactOnlineFilterActive ? Filter.all.rawValue : Filter.online.rawValue)
    }

    @objc
    private final func onContactsCompactPrimaryButtonTouchUpInside(_ sender: UIButton) {
        if isGroup {
            openCreatePublicGroupFlow()
        } else {
            openAddContactFlow()
        }
    }

    func configureBars(animated: Bool = false, updateNavigationItems: Bool = true) {
        switch CommonConfigManager.shared.interfaceType {
            case .tabs:
                break
            case .split:
//                break
//                self.splitViewController?.navigationItem.setLeftBarButtonItems([], animated: true)

                if UIDevice.current.userInterfaceIdiom != .pad {
//                    self.navigationItem.setHidesBackButton(true, animated: false)
                    if updateNavigationItems {
                        NavigationBarItemOwnership.setIfChanged(
                            .item(makeContactsBackButton()),
                            on: navigationItem,
                            side: .left,
                            animated: animated
                        )
                    }
                }
        }
        securityButton.target = self
        securityButton.action = #selector(onRegisterYubikey)
        
        let button = makeContactsFilterButton()
        var childs: [UIMenuElement] = []
        if isGroup {
            childs = [
                UIMenu(title: "", subtitle: nil, image: nil, identifier: nil, options: .displayInline, children: [
                    UIAction(
                        title: "Public",
                        image: imageLiteral("person.2"),
                        identifier: .none,
                        discoverabilityTitle: "Show all contacts",
                        attributes: [],
                        state: filter.value == .all ? .on : .off,
                        handler: { action in
                            self.shouldFilterBy(category: "public")
                        }),
                    UIAction(
                        title: "Incognito",
                        image: imageLiteral("xabber.incognito.variant"),
                        identifier: .none,
                        discoverabilityTitle: "Show only online",
                        attributes: [],
                        state: filter.value == .online ? .on : .off,
                        handler: { action in
                            self.shouldFilterBy(category: "incognito")
                        }),
                    UIAction(
                        title: "Private chats",
                        image: imageLiteral("bubble"),
                        identifier: .none,
                        discoverabilityTitle: "Show only online",
                        attributes: [],
                        state: filter.value == .online ? .on : .off,
                        handler: { action in
                            self.shouldFilterBy(category: "private")
                        })
                ]),
                UIMenu(title: "", subtitle: nil, image: nil, identifier: nil, options: .displayInline, children: [
                    UIAction(
                        title: "Invitations",
                        image: imageLiteral("xabber.invite"),
                        identifier: .none,
                        discoverabilityTitle: "Show contact requests",
                        attributes: [],
                        state: filter.value == .subscribtions ? .on : .off,
                        handler: { action in
                            self.shouldFilterBy(category: "invitations")
                        })
                ]),
            ]
        } else {
//            if isGroup {
//                childs = [
//                    UIMenu(title: "", subtitle: nil, image: nil, identifier: nil, options: .displayInline, children: [
//                        UIAction(
//                            title: "Create group",
//                            image: imageLiteral("plus"),
//                            identifier: .none,
//                            discoverabilityTitle: "Create group",
//                            attributes: [],
//                            state: .off,
//                            handler: { action in
//                                let vc = CreateNewEntityViewController()
//                                vc.filterGroupCreation = true
//                                showModal(vc, parent: self)
//                            }),
//                    ]),
//                ]
//            } else {
//                childs = [
//                    UIMenu(title: "", subtitle: nil, image: nil, identifier: nil, options: .displayInline, children: [
//                        UIAction(
//                            title: "Add contact",
//                            image: imageLiteral("plus"),
//                            identifier: .none,
//                            discoverabilityTitle: "Add contact",
//                            attributes: [],
//                            state: .off,
//                            handler: { action in
//                                let vc = CreateNewEntityViewController()
//                                vc.filterGroupCreation = false
//                                showModal(vc, parent: self)
//                            }),
//                    ]),
//                ]
//            }
            childs.append(contentsOf: [
                UIMenu(title: "", subtitle: nil, image: nil, identifier: nil, options: .displayInline, children: [
                    UIAction(
                        title: "Contacts",
                        image: imageLiteral("person.crop.rectangle.stack"),
                        identifier: .none,
                        discoverabilityTitle: "Show all contacts",
                        attributes: [],
                        state: filter.value == .all ? .on : .off,
                        handler: { action in
                            self.shouldFilterBy(category: Filter.all.rawValue)
                        }),
                    UIAction(
                        title: "Online",
                        image: imageLiteral("person"),
                        identifier: .none,
                        discoverabilityTitle: "Show only online",
                        attributes: [],
                        state: filter.value == .online ? .on : .off,
                        handler: { action in
                            self.shouldFilterBy(category: Filter.online.rawValue)
                        }),
                ]),
                UIMenu(title: "", subtitle: nil, image: nil, identifier: nil, options: .displayInline, children: [
                    UIAction(
                        title: "Contact requests",
                        image: imageLiteral("xabber.person.plus"),
                        identifier: .none,
                        discoverabilityTitle: "Show contact requests",
                        attributes: [],
                        state: filter.value == .subscribtions ? .on : .off,
                        handler: { action in
                            self.shouldFilterBy(category: Filter.subscribtions.rawValue)
                        }),
                    UIAction(
                        title: "Outgoing requests",
                        image: imageLiteral("person.text.rectangle"),
                        identifier: .none,
                        discoverabilityTitle: "Show outgoing requests",
                        attributes: [],
                        state: filter.value == .requests ? .on : .off,
                        handler: { action in
                            self.shouldFilterBy(category: Filter.requests.rawValue)
                        })
                ]),
            ])
        }
        
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
            let derivedState = ContactsListCoordinator.deriveState(
                realm: realm,
                state: currentFilterState(),
                datasourceBuilder: self.mapDataset(state:context:)
            )
            let accounts: [UIMenuElement] = realm
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
                        state: filteredAccounts.contains(item.jid) ? .on : .off,
                        handler: { action in
                            self.shouldFilterBy(account: item.jid)
                            action.state = self.filteredAccounts.contains(item.jid) ? .on : .off
                        }
                    )
                })
            
            
//            if accounts.count > 1 {
//                childs.append(UIMenu(title: "Accounts", subtitle: " ", image: nil, identifier: nil, options: .displayInline, children: accounts))
//            }
            
            
            
            if !(CommonConfigManager.shared.interfaceType == .split && UIDevice.current.userInterfaceIdiom == .pad) {
                let groups : [UIMenuElement] = derivedState.circleCounts.compactMap({
                    group in
                    return UIAction(
                        title: group.name,
                        subtitle: "\(group.count)",
                        image: imageLiteral("tag"),
                        identifier: .none,
                        discoverabilityTitle: group.name,
                        attributes: [],
                        state: self.filteredGroups.contains(group.name) ? .on : .off,
                        handler: { action in
                            if self.filteredGroups.contains(group.name) {
                                self.filteredGroups.remove(group.name)
                            } else {
                                self.filteredGroups.insert(group.name)
                            }
                            self.shouldFilterBy(groups: Array(self.filteredGroups))
                        }
                    )
                })
                childs.append(UIMenu(title: "Circles", subtitle: " ", image: nil, identifier: nil, options: .displayInline, children: groups))
            }
        } catch {
            DDLogDebug("NotificationsListViewController: \(#function). \(error.localizedDescription)")
        }
        
        filterMenu = UIMenu(options: [.singleSelection], children: childs)
        button.menu = filterMenu

        updateContactsCompactBottomBarState()

        if shouldUseContactsCompactBottomBar {
            if updateNavigationItems {
                NavigationBarItemOwnership.setIfChanged(
                    .none,
                    on: navigationItem,
                    side: .right,
                    animated: animated
                )
            }
            return
        }
        
        let addBarButton = makeContactsAddButton()
        let rightAssignment: NavigationBarItemOwnership.Assignment
        if isGroup {
            if childs.count > 0 {
                rightAssignment = .items([button, addBarButton])
            } else {
                rightAssignment = .item(addBarButton)
            }
        } else {
            if childs.count > 0 {
                rightAssignment = .items([button, addBarButton])
            } else {
                rightAssignment = .items([addBarButton])
            }
        }
        if updateNavigationItems {
            NavigationBarItemOwnership.setIfChanged(
                rightAssignment,
                on: navigationItem,
                side: .right,
                animated: animated
            )
        }
    }
    
    @objc
    internal func showOfflineSelector(_ sender: UIBarButtonItem) {
        let result = self.changeOfflineVisibilityState()
        if result {
            sender.image = imageLiteral("person")
        } else {
            sender.image = imageLiteral("person.fill")
        }
    }
    
    func onLeftBarButtonTouchUp() {
//        self.showOffline = !self.showOffline
//        self.bottomBar.leftButton.setImage(UIImage(systemName: self.showOffline ? "circle" : "circle.fill")?.upscale(dimension: 24), for: .normal)
        
//        if #available(iOS 17.0, *) {
//            if let image = UIImage(systemName: self.showOffline ? "circle" : "circle.fill")?.upscale(dimension: 24).withRenderingMode(.alwaysTemplate) {
//                self.bottomBar.leftButton.imageView?.setSymbolImage(image, contentTransition: .replace)
//            }
//        } else {
        self.bottomBar.leftButton.setImage(UIImage(systemName: self.showOffline ? "person.crop.circle" : "person.crop.circle.badge")?.upscale(dimension: 24).withRenderingMode(.alwaysTemplate), for: .normal)
//        }
        
        self.runDatasetUpdateTask(force: true)
    }
    
    override func shouldChangeFrame() {
        super.shouldChangeFrame()
        var inputHeight: CGFloat = 49
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        
        let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
        bottomBar.updateFrame(to: frame)
        updateContactsCompactBottomBarState()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTableInsetsForBottomSearch()
    }
    
    internal func updateTitle() {
//        if AccountManager.shared.connectingUsers.value.isNotEmpty {
//            customTitleLabel.text = "Connecting...".localizeString(id: "account_state_connecting", arguments: [])
//            customTitleLabel.sizeToFit()
//            customTitleLabel.layoutIfNeeded()
//            return
//        }
//        customTitleLabel.text = "Contacts".localizeString(id: "contacts", arguments: [])
//        
//        customTitleLabel.sizeToFit()
//        customTitleLabel.layoutIfNeeded()
        
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.title = nil
        } else {
            switch self.category ?? "" {
                
                case "all":
                  self.title = "Contacts"
                case "online":
                  self.title = "Online contacts"
                case "subscribtions":
                  self.title = "Contact requests"
                case "requests":
                  self.title = "Outgoing requests"
                case "public":
                  self.title = "Public groups"
                case "incognito":
                  self.title = "Incognito groups"
                case "private":
                  self.title = "Private groups"
                case "invitations":
                  self.title = "Group invitations"
                default:
                    if isGroup {
                        self.title = "Public groups"
                    } else {
                        self.title = "Contacts"
                    }
            }
        }
        
    }
    
    internal func configure() {
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(self)
        NavigationLargeTitlePolicy.apply(to: self)
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.applyContinuousSplitInsetGroupedAppearance()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 92
        
        emptyView.isHidden = true
        emptyView.backgroundColor = ContinuousSplitBackgroundExperiment.isActive ? .clear : .systemBackground
        emptyView.isOpaque = !ContinuousSplitBackgroundExperiment.isActive
        view.addSubview(emptyView)
        emptyView.fillSuperview()
        view.bringSubviewToFront(emptyView)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
        configureSearchBar()
        updateContactsCompactBottomBarState()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
        configureBars(animated: false)
        if self.category == nil {
            if isGroup {
                self.category = "public"
                self.categoryDelegate?.filterDidSelect(category: "public")
            } else {
                self.category = "all"
                self.categoryDelegate?.filterDidSelect(category: "all")
            }
        }
        self.runDatasetUpdateTask(force: true)
        self.updateTitle()
    }
    
    override func reloadDatasource() {
        tableView.reloadData()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(self)
        tableView.applyContinuousSplitInsetGroupedAppearance()
        NavigationLargeTitlePolicy.apply(to: self)
        emptyView.backgroundColor = ContinuousSplitBackgroundExperiment.isActive ? .clear : .systemBackground
        emptyView.isOpaque = !ContinuousSplitBackgroundExperiment.isActive
        let updateNavigationItems = !isSearchHostNavigationTransitionActive
        configureBars(animated: false, updateNavigationItems: updateNavigationItems)
        if !updateNavigationItems {
            deferConfigureBarsUntilSearchHostNavigationTransitionCompletes()
        }
        subscribe()
        NotifyManager.shared.setLastChats(displayed: false)
        updateTitle()
        self.tabBarController?.tabBar.isHidden = false
        self.tabBarController?.tabBar.layoutIfNeeded()
        if SignatureManager.shared.certificate != nil {
            self.securityButton.tintColor = .systemGreen
        } else {
            self.securityButton.tintColor = .systemRed
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard previousTraitCollection?.horizontalSizeClass != effectiveHorizontalSizeClass else {
            return
        }

        configureBars(animated: false)
        updateContactsCompactBottomBarState()
    }

    private var isSearchHostNavigationTransitionActive: Bool {
        transitionCoordinator != nil ||
            navigationController?.transitionCoordinator != nil ||
            splitViewController?.transitionCoordinator != nil
    }

    private func deferConfigureBarsUntilSearchHostNavigationTransitionCompletes() {
        guard let coordinator = transitionCoordinator
            ?? navigationController?.transitionCoordinator
            ?? splitViewController?.transitionCoordinator else {
            return
        }

        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.configureBars(animated: false, updateNavigationItems: true)
            self?.updateTitle()
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        updateTitle()
        super.viewDidAppear(animated)
//        self.navigationController?.setNavigationBarHidden(true, animated: false)
        if #available(iOS 14.0, *) {
            navigationItem.backButtonDisplayMode = .minimal
        }
//        self.navigationItem.backButtonTitle = "Contacts".localizeString(id: "contacts", arguments: [])
        isFirstLayout = true
        AccountManager.shared.users.compactMap { $0.jid }.forEach {
            activeUser in
            AccountManager.shared.find(for: activeUser)?.action({ user, stream in
                user.vcards.lazyLoadMissedVCards(stream)
            })
        }
        completeLeftMenuFirstPresentationQuietModeAfterFirstStableFrame()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        endLeftMenuFirstPresentationQuietMode()
        self.navigationController?.setNavigationBarHidden(false, animated: true)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    deinit {
        unsubscribe()
    }
}

extension ContactsViewController: ContactsControllerFilterProtocol {
    func changeOfflineVisibilityState() -> Bool {
        self.showOffline = !self.showOffline
        self.runDatasetUpdateTask(force: true)
        self.updateContactsCompactBottomBarState()
        return self.showOffline
    }
    
    func shouldFilterBy(groups: [String]) {
        self.filteredGroups = Set(groups)
        self.categoryDelegate?.filterDidSelect(groups: groups)
        self.runDatasetUpdateTask(force: true)
        self.updateContactsCompactBottomBarState()
    }
    
    func shouldFilterBy(account: String?) {
        if let account = account {
            if self.filteredAccounts.contains(account) {
                self.filteredAccounts.remove(account)
            } else {
                self.filteredAccounts.removeAll()
                self.filteredAccounts.insert(account)
            }
        } else {
            self.filteredAccounts = Set()
        }
        self.categoryDelegate?.filterDidSelect(account: self.filteredAccounts.first)
        self.runDatasetUpdateTask(force: true)
        self.configureBars(animated: false)
        self.updateContactsCompactBottomBarState()
    }
    
    func shouldFilterBy(category: String?) {
        self.category = category
        if category == "all" {
            self.showOffline = true
        }
        if category == nil {
            self.showOffline = true
        }
        if category == "online" {
            self.showOffline = false
        }
        self.categoryDelegate?.filterDidSelect(category: category)
        self.runDatasetUpdateTask(force: true)
        if let category = category,
           let filter = Filter(rawValue: category) {
            self.filter.accept(filter)
        } else {
            self.filter.accept(.all)
        }
        self.configureBars(animated: false)
        self.updateContactsCompactBottomBarState()
        self.updateTitle()
    }
}
