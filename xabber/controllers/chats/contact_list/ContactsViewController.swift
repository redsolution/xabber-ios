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

class ContactsViewController: BaseViewController {
    
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
    
    var pinnedAccount: Int = 0
    
    var lastScrollPosition: CGFloat = 0
    
    var collapsedAccounts: Set<String> = Set<String>()
    
    var showOffline: Bool = true
    open var isGroup: Bool = false {
        didSet {
            print("set")
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
    
    internal var searchController: UISearchController = {
        let searchResults = SearchResultsViewController()
        let controller = UISearchController(searchResultsController: searchResults)
        
        controller.searchResultsUpdater = searchResults
        controller.searchBar.searchBarStyle = .minimal
        controller.searchBar.placeholder = "Search contacts and messages".localizeString(id: "search_contacts_and_messages", arguments: [])
        controller.searchBar.isTranslucent = true
        controller.hidesNavigationBarDuringPresentation = true
        controller.hidesBottomBarWhenPushed = true
        controller.definesPresentationContext = true
        
        return controller
    }()
    
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
    
    private final func mapDataset() -> [[Datasource]] {
        do {
            if isGroup {
                return try self.mapDatasetGroups()
            } else {
                return try self.mapDatasetContacts()
            }
        } catch {
            return [[]]
        }
        
    }
    
    private final func mapDatasetContacts() throws -> [[Datasource]] {
        let realm = try WRealm.safe()
        var jids = realm.objects(AccountStorageItem.self).filter("enabled == true").toArray().compactMap { $0.jid }
        
        if filteredAccounts.isNotEmpty {
            jids = Array(self.filteredAccounts)
        }
        var ignoredJids: [String] = AccountManager.shared.users.compactMap { $0.notifications.node }
        ignoredJids.append(contentsOf: AccountManager.shared.users.compactMap { $0.favorites.node })
        ignoredJids.append(contentsOf: jids)
        var ignoredAbuse = Set(realm.objects(XMPPAbuseConfigStorageItem.self).toArray().compactMap({ $0.abuseAddress }))
        ignoredAbuse.insert(CommonConfigManager.shared.config.default_report_address)
        ignoredJids.append(contentsOf: Array(ignoredAbuse))
        if CommonConfigManager.shared.config.support_jid.isNotEmpty {
            ignoredJids.append(CommonConfigManager.shared.config.support_jid)
        }
        let collection = realm
            .objects(RosterStorageItem.self)
            .filter("owner IN %@ AND isHidden == false AND removed == false AND subscription_ IN %@ AND isContact == true AND NOT (jid IN %@)", jids, ["both", "from", "to"], ignoredJids)
            .toArray()
        
        hasContactsRequestSection = false
        var categoryHeader: [Datasource] = []
        var out: [Datasource] = []
        
        if category == nil && self.filteredGroups.isEmpty {
            let requests = realm
                .objects(RosterStorageItem.self)
                .filter("owner IN %@ AND isHidden == false AND removed == false AND ask_ == %@ AND isContact == true AND NOT (jid IN %@)", jids, "in", ignoredJids)
                .toArray()
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
        if category == "subscribtions" {
            let requests = realm
                .objects(RosterStorageItem.self)
                .filter("owner IN %@ AND isHidden == false AND removed == false AND ask_ == %@ AND isContact == true AND NOT (jid IN %@)", jids, "in", ignoredJids)
                .toArray()
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
        if category == "requests" {
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
            let requests = realm
                .objects(RosterStorageItem.self)
                .filter("owner IN %@ AND isHidden == false AND removed == false AND ask_ == %@ AND isContact == true AND NOT (jid IN %@)", jids, "out", ignoredJids)
                .toArray()
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
                    isContactRequest: true
                )
            })
        }
        if category == nil || category == "online" || category == "all" {
            out.append(contentsOf: collection.sorted(by: { ($0.displayName.lowercased() < $1.displayName.lowercased()) })
                .compactMap({
                    contact in
                    if filteredAccounts.isNotEmpty {
                        if !filteredAccounts.contains(contact.owner) {
                            return nil
                        }
                    }
                    if filteredGroups.isNotEmpty {
                        if !filteredGroups.isSubset(of: Set(contact.groups)) {
                            return nil
                        }
                    }
                    if !showOffline {
                        let primaryResource = contact.getPrimaryResource()
                        if primaryResource == nil {
                            return nil
                        }
                        if (primaryResource?.isTemporary ?? false) {
                            return nil
                        }
                        if primaryResource?.status == .offline {
                            return nil
                        }
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
            return [categoryHeader, out]
        } else {
            return [out]
        }
    }
    
    private final func mapDatasetGroups() throws -> [[Datasource]] {
        let realm = try WRealm.safe()
        var jids = realm.objects(AccountStorageItem.self).filter("enabled == true").toArray().compactMap { $0.jid }
        
        if filteredAccounts.isNotEmpty {
            jids = Array(self.filteredAccounts)
        }
        var ignoredJids: [String] = AccountManager.shared.users.compactMap { $0.notifications.node }
        ignoredJids.append(contentsOf: AccountManager.shared.users.compactMap { $0.favorites.node })
        if CommonConfigManager.shared.config.support_jid.isNotEmpty {
            ignoredJids.append(CommonConfigManager.shared.config.support_jid)
        }
        var ignoredAbuse = Set(realm.objects(XMPPAbuseConfigStorageItem.self).toArray().compactMap({ $0.abuseAddress }))
        ignoredAbuse.insert(CommonConfigManager.shared.config.default_report_address)
        ignoredJids.append(contentsOf: Array(ignoredAbuse))
        ignoredJids.append(contentsOf: jids)
        let contacts = Set(realm
            .objects(RosterStorageItem.self)
            .filter("owner IN %@ AND isHidden == false AND removed == false AND subscription_ IN %@ AND isContact == true AND NOT (jid IN %@)", jids, ["both"], ignoredJids)
            .toArray()
            .compactMap { $0.jid })
        
//        public incognito private invitations
        hasContactsRequestSection = false
        
        var categoryHeader: [Datasource] = []
        var out: [Datasource] = []
        
        if category == nil && self.filteredGroups.isEmpty {
            let requests = realm
                .objects(GroupchatInvitesStorageItem.self)
                .filter("owner IN %@ AND isRead == false", jids)
                .toArray()
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
                
                
                let groupInstance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: invite.groupchat, owner: invite.owner))
                let members = realm.objects(GroupchatUserStorageItem.self).filter("groupchatId == %@ AND isHidden == false", [invite.groupchat, invite.owner].prp()).toArray().compactMap {
                    return GroupDisplayMember(name: $0.nickname, jid: $0.jid, avatarUrl: $0.avatarURI, uuid: $0.userId)
                }
                let membersJids = Set(realm.objects(GroupchatUserStorageItem.self).filter("groupchatId == %@ AND isHidden == false", [invite.groupchat, invite.owner].prp()).toArray().compactMap { $0.jid.isEmpty ? $0.userId : $0.jid })
                let rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: invite.groupchat, owner: invite.owner))
                let invitedBy = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: invite.jid, owner: invite.owner))?.displayName ?? invite.jid
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
                    bottomLine: String.membersAndContactsString(members: groupInstance?.members ?? 0, contacts: membersJids.intersection(contacts).count),
                    descr: groupInstance?.descr,
                    members: members,
                    status: rosterItem?.getPrimaryResource()?.status ?? .away,
                    entity: rosterItem?.getPrimaryResource()?.entity ?? entity,
                    primary: invite.primary
                )
            })
        }
        
        if category == "invitations" {
            
            let requests = realm
                .objects(GroupchatInvitesStorageItem.self)
                .filter("owner IN %@ AND isRead == false", jids)
                .toArray()
            
            requests.forEach {
                request in
                let owner = request.owner
                let groupchat = request.groupchat
                AccountManager.shared.find(for: owner)?.action { user, stream in
                    user.groupchats.getGroupInfo(stream, groupchat: groupchat)
                    user.groupchats.requestUsers(stream, groupchat: groupchat)
                }
            }
            
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
                let groupInstance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: invite.groupchat, owner: invite.owner))
                let members = realm.objects(GroupchatUserStorageItem.self).filter("groupchatId == %@ AND isHidden == false", [invite.groupchat, invite.owner].prp()).toArray().compactMap {
                    return GroupDisplayMember(name: $0.nickname, jid: $0.jid, avatarUrl: $0.avatarURI, uuid: $0.userId)
                }
                let membersJids = Set(realm.objects(GroupchatUserStorageItem.self).filter("groupchatId == %@ AND isHidden == false", [invite.groupchat, invite.owner].prp()).toArray().compactMap { $0.jid.isEmpty ? $0.userId : $0.jid })
                let rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: invite.groupchat, owner: invite.owner))
                let invitedBy = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: invite.jid, owner: invite.owner))?.displayName ?? invite.jid
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
                    bottomLine: String.membersAndContactsString(members: groupInstance?.members ?? 0, contacts: membersJids.intersection(contacts).count),
                    descr: groupInstance?.descr,
                    members: members,
                    status: rosterItem?.getPrimaryResource()?.status ?? .away,
                    entity: rosterItem?.getPrimaryResource()?.entity ?? entity,
                    primary: invite.primary
                )
            })
        }
        if category == "public" {
            let groups = realm
                .objects(GroupChatStorageItem.self)
                .filter("owner IN %@ AND privacy_ == %@ AND NOT (jid IN %@) AND peerToPeer == %@", jids, GroupChatStorageItem.Privacy.publicChat.rawValue, ignoredJids, false)
                .toArray()
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
                guard let contact = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: group.jid, owner: group.owner)) else {
                    return nil
                }
                if contact.isContact {
                    return nil
                }
                if contact.subscribtion != .both {
                    return nil
                }
                if contact.removed {
                    return nil
                }
                if contact.isHidden {
                    return nil
                }
                if filteredAccounts.isNotEmpty {
                    if !filteredAccounts.contains(contact.owner) {
                        return nil
                    }
                }
                if filteredGroups.isNotEmpty {
                    if !filteredGroups.isSubset(of: Set(contact.groups)) {
                        return nil
                    }
                }
//                let groupInstance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: contact.jid, owner: contact.owner))
                let members = Set(realm.objects(GroupchatUserStorageItem.self).filter("groupchatId == %@ AND isHidden == false", [group.jid, group.owner].prp()).toArray().compactMap { $0.jid.isEmpty ? $0.userId : $0.jid })
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
                    bottomLine: String.membersAndContactsString(members: members.count, contacts: members.intersection(contacts).count),
                    status: contact.getPrimaryResource()?.status ?? group.statusDisplayed,
                    entity: contact.getPrimaryResource()?.entity ?? entity
                )
            })
        }
        if category == "incognito" {
            let groups = realm
                .objects(GroupChatStorageItem.self)
                .filter("owner IN %@ AND privacy_ == %@ AND NOT (jid IN %@) AND peerToPeer == %@", jids, GroupChatStorageItem.Privacy.incognito.rawValue, ignoredJids, false)
                .toArray()
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
//                let groupInstance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: contact.jid, owner: contact.owner))
                guard let contact = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: group.jid, owner: group.owner)) else {
                    return nil
                }
                if contact.isContact {
                    return nil
                }
                if contact.subscribtion != .both {
                    return nil
                }
                if contact.removed {
                    return nil
                }
                if contact.isHidden {
                    return nil
                }
                if filteredAccounts.isNotEmpty {
                    if !filteredAccounts.contains(contact.owner) {
                        return nil
                    }
                }
                if filteredGroups.isNotEmpty {
                    if !filteredGroups.isSubset(of: Set(contact.groups)) {
                        return nil
                    }
                }
                let members = Set(realm.objects(GroupchatUserStorageItem.self).filter("groupchatId == %@ AND isHidden == false", [group.jid, group.owner].prp()).toArray().compactMap { $0.jid.isEmpty ? $0.userId : $0.jid })
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
                    bottomLine: String.membersAndContactsString(members: members.count, contacts: members.intersection(contacts).count),
                    status: contact.getPrimaryResource()?.status ?? group.statusDisplayed,
                    entity: contact.getPrimaryResource()?.entity ?? entity
                )
            })
        }
        if category == "private" {
            let groups = realm
                .objects(GroupChatStorageItem.self)
                .filter("owner IN %@ AND peerToPeer == %@ AND NOT (jid IN %@)", jids, true, ignoredJids)
                .toArray()
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
//                let groupInstance = realm.object(ofType: GroupChatStorageItem.self, forPrimaryKey: GroupChatStorageItem.genPrimary(jid: contact.jid, owner: contact.owner))
                guard let contact = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: group.jid, owner: group.owner)) else {
                    return nil
                }
                if contact.isContact {
                    return nil
                }
                if contact.subscribtion != .both {
                    return nil
                }
                if contact.removed {
                    return nil
                }
                if contact.isHidden {
                    return nil
                }
                if filteredAccounts.isNotEmpty {
                    if !filteredAccounts.contains(contact.owner) {
                        return nil
                    }
                }
                if filteredGroups.isNotEmpty {
                    if !filteredGroups.isSubset(of: Set(contact.groups)) {
                        return nil
                    }
                }
                let members = Set(realm.objects(GroupchatUserStorageItem.self).filter("groupchatId == %@ AND isHidden == false", [group.jid, group.owner].prp()).toArray().compactMap { $0.jid.isEmpty ? $0.userId : $0.jid })
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
                    bottomLine: String.membersAndContactsString(members: members.count, contacts: members.intersection(contacts).count),
                    status: group.statusDisplayed,
                    entity: entity
                )
            })
        }
        if category == nil || category == "all" {
            let groups = realm
                .objects(GroupChatStorageItem.self)
                .filter("owner IN %@ AND peerToPeer == %@ AND NOT (jid IN %@)", jids, false, ignoredJids)
                .toArray()
            
            out.append(contentsOf: groups.sorted(by: { $0.name < $1.name })
                .compactMap({
                    group in
                    if group.name.isEmpty {
                        return nil
                    }
                    guard let contact = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: group.jid, owner: group.owner)) else {
                        return nil
                    }
                    if contact.isContact {
                        return nil
                    }
                    if contact.subscribtion != .both {
                        return nil
                    }
                    if contact.removed {
                        return nil
                    }
                    if contact.isHidden {
                        return nil
                    }
                    if filteredAccounts.isNotEmpty {
                        if !filteredAccounts.contains(contact.owner) {
                            return nil
                        }
                    }
                    if filteredGroups.isNotEmpty {
                        if !filteredGroups.isSubset(of: Set(contact.groups)) {
                            return nil
                        }
                    }
                    
                    let members = Set(realm.objects(GroupchatUserStorageItem.self).filter("groupchatId == %@ AND isHidden == false", [group.jid, group.owner].prp()).toArray().compactMap { $0.jid.isEmpty ? $0.userId : $0.jid })
                    
                    if !showOffline {
                        let primaryResource = contact.getPrimaryResource()
                        if primaryResource == nil {
                            return nil
                        }
                        if (primaryResource?.isTemporary ?? false) {
                            return nil
                        }
                        if primaryResource?.status == .offline {
                            return nil
                        }
                    }
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
                        bottomLine: String.membersAndContactsString(members: members.count, contacts: members.intersection(contacts).count),
                        status: contact.getPrimaryResource()?.status ?? group.statusDisplayed,
                        entity: entity
                    )
                }))
        }
        out = out.sorted(by: { $0.isHeader == true && $0.status.statusToSortedItem() > $1.status.statusToSortedItem() })
        if categoryHeader.isNotEmpty {
            return [categoryHeader, out]
        } else {
            return [out]
        }
    }
    
    public final var canUpdateDataset = true
    
        
    public final func initializeDataset() {
        
    }

    
    public final func runDatasetUpdateTask(force: Bool = false) {
        print(#function)
        preprocessDataset(changeCategory: false)
        postprocessDataset()
    }
    
    internal final func preprocessDataset(changeCategory: Bool) {
        let newDatasource = self.mapDataset()
        if let lastPart = newDatasource.last {
            if lastPart.count == 0 {
                if !self.isEmptyViewShowed.value {
                    emptyView.configure(image: imageLiteral( "person.3")?.upscale(dimension: 100).withRenderingMode(.alwaysTemplate),
                                        title: getEmptyStateString() ?? "",
                                        subtitle: "",
                                        buttonTitle: "Add contact".localizeString(id: "application_action_no_contacts", arguments: [])) {
                        
                    }
                    self.isEmptyViewShowed.accept(true)
                }
            } else if lastPart.first?.isHeader == true {
                if !self.isEmptyViewShowed.value {
                    self.isEmptyViewShowed.accept(true)
                }
            } else {
                if self.isEmptyViewShowed.value {
                    self.isEmptyViewShowed.accept(false)
                }
            }
        }
        func forceReload() {
//            UIView.performWithoutAnimation {
            DispatchQueue.main.async {
                self.datasource = newDatasource
                self.tableView.reloadData()
            }
                
//            }
        }
        if changeCategory {
            forceReload()
        } else if newDatasource.isEmpty {
            forceReload()
        } else if self.datasource.count != newDatasource.count {
            forceReload()
        } else {
            guard let lastPartOldDatasource = self.datasource.last,
                  !(lastPartOldDatasource.first?.isHeader ?? false),
                  let lastPartNewDatasource = newDatasource.last,
                  !(lastPartNewDatasource.first?.isHeader ?? false) else {
                forceReload()
                return
            }
            let changes = diff(old: lastPartOldDatasource, new: lastPartNewDatasource)
            var indexPaths = self.convertChangeset(changes: changes, section: newDatasource.count - 1)
            UIView.performWithoutAnimation {
                self.apply(changes: indexPaths) {
                    self.datasource = newDatasource
                }
            }
        }
    }
    
    private final func apply(changes: ChangesWithIndexPath, prepare: @escaping (() -> Void)) {
        
        if changes.deletes.isEmpty &&
            changes.inserts.isEmpty &&
            changes.moves.isEmpty &&
            changes.replaces.isEmpty {
            prepare()
            self.canUpdateDataset = true
            return
        }
        
        self.tableView.performBatchUpdates({
            prepare()
            if !changes.deletes.isEmpty {
                self.tableView.deleteRows(at: changes.deletes, with: .automatic)
            }
            if !changes.inserts.isEmpty {
                self.tableView.insertRows(at: changes.inserts, with: .automatic)
            }
            if changes.moves.isNotEmpty {
                changes.moves.forEach {
                    (from, to) in
                    self.tableView.moveRow(at: from, to: to)
                }
            }
        }, completion: { result in
            self.canUpdateDataset = true
            if changes.replaces.isEmpty { return }
            UIView.performWithoutAnimation {
                //may be increase performance
                self.tableView.reconfigureRows(at: changes.replaces)
//                self.tableView.reloadRows(at: changes.replaces, with: .none)
            }
        })
    }
    
    private final func postprocessDataset() {
        
    }
    
    private final func subscribeToDataset() {
        self.bag = DisposeBag()
        do {
            let realm = try  WRealm.safe()
            let jids = realm.objects(AccountStorageItem.self).filter("enabled == true").toArray().compactMap { $0.jid }
            let collection = realm
                .objects(RosterStorageItem.self)
                .filter("subscription_ == %@ AND removed == false AND isHidden == false AND isContact == true AND owner IN %@", "both", jids)
                
            Observable
                .collection(from: collection)
                .debounce(.milliseconds(300), scheduler: MainScheduler.asyncInstance)
                .subscribe { (results) in
                    self.runDatasetUpdateTask()
                }.disposed(by: bag)

        } catch {
            DDLogDebug("ContactsViewController: \(#function). \(error.localizedDescription)")
        }
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
        do {
            let realm = try  WRealm.safe()
//            let accounts = realm.objects(AccountStorageItem.self)
//                .filter("enabled == true")
//                .sorted(byKeyPath: "order", ascending: true)


            var jids = realm.objects(AccountStorageItem.self).filter("enabled == true").toArray().compactMap { $0.jid }
            
            
            if isGroup {
                let invitesCollection = realm.objects(GroupchatInvitesStorageItem.self).filter("owner IN %@", jids)
                invitesCollection.toArray().forEach {
                    item in
//                    if !item.isGroupInfoLoaded {
//                        let groupchat = item.groupchat
//                        let owner = item.owner
//                        AccountManager.shared.find(for: owner)?.action({ user, stream in
//                            user.presences.probe(stream, jid: groupchat)
//                            user.groupchats.requestUsers(stream, groupchat: groupchat, userId: nil)
//                            user.vcards.requestIfMissed(stream, jid: groupchat)
//                        })
//                    }
                }
                Observable.collection(from: invitesCollection).debounce(.milliseconds(500), scheduler: MainScheduler.asyncInstance).subscribe { results in
                    results.forEach {
                        item in
//                        if !item.isGroupInfoLoaded {
//                            AccountManager.shared.find(for: item.owner)?.action({ user, stream in
//                                user.groupchats.requestUsers(stream, groupchat: item.groupchat, userId: nil)
//                                user.vcards.requestIfMissed(stream, jid: item.groupchat)
//                                user.presences.probe(stream, jid: item.groupchat)
//                            })
//                        }
                    }
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)

            }
            
            if filteredAccounts.isNotEmpty {
                jids = Array(self.filteredAccounts)
            }
            var ignoredJids: [String] = AccountManager.shared.users.compactMap { $0.notifications.node }
            ignoredJids.append(contentsOf: AccountManager.shared.users.compactMap { $0.favorites.node })
            if CommonConfigManager.shared.config.support_jid.isNotEmpty {
                ignoredJids.append(CommonConfigManager.shared.config.support_jid)
            }
            var ignoredAbuse = Set(realm.objects(XMPPAbuseConfigStorageItem.self).toArray().compactMap({ $0.abuseAddress }))
            ignoredAbuse.insert(CommonConfigManager.shared.config.default_report_address)
            ignoredJids.append(contentsOf: Array(ignoredAbuse))
            var ignoredAccounts = realm.objects(AccountStorageItem.self).filter("enabled == true").toArray().compactMap { $0.jid }
            ignoredJids.append(contentsOf: ignoredAccounts)
            let collection = realm
                .objects(RosterStorageItem.self)
                .filter("owner IN %@ AND isHidden == false AND removed == false AND subscription_ IN %@ AND isContact == true AND NOT (jid IN %@)", jids, ["both", "from", "to"], ignoredJids)
                
            Observable
                .collection(from: collection)
                .debounce(.milliseconds(10), scheduler: MainScheduler.asyncInstance)
                .subscribe { collection in
                    self.preprocessDataset(changeCategory: false)
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: self.bag)
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
       
        self.subscribeToDataset()
        
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
        
    func configureBars() {
        self.title = nil
        self.navigationItem.largeTitleDisplayMode = .never
        self.navigationController?.navigationBar.prefersLargeTitles = false//CommonConfigManager.shared.config.use_large_title
        switch CommonConfigManager.shared.interfaceType {
            case .tabs:
                break
            case .split:
//                break
//                self.splitViewController?.navigationItem.setLeftBarButtonItems([], animated: true)
                
                let sidebarButton = UIBarButtonItem(image: imageLiteral("chevron.left"), style: .plain, target: self, action: #selector(onBackButtonTouchUpInside))
                
                if UIDevice.current.userInterfaceIdiom != .pad {
//                    self.navigationItem.setHidesBackButton(true, animated: false)
                    self.navigationItem.setLeftBarButton(sidebarButton, animated: true)
                }
        }
        if #available(iOS 16.0, *) {
            self.navigationItem.preferredSearchBarPlacement = .stacked
        }
        securityButton.target = self
        securityButton.action = #selector(onRegisterYubikey)
        
        let button = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), style: .done, target: self, action: nil)
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
            childs = [
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
            ]
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
            
            
            if accounts.count > 1 {
                childs.append(UIMenu(title: "Accounts", subtitle: " ", image: nil, identifier: nil, options: .displayInline, children: accounts))
            }
            
            
            
            if !(CommonConfigManager.shared.interfaceType == .split && UIDevice.current.userInterfaceIdiom == .pad) {
                let jids = realm.objects(AccountStorageItem.self).filter("enabled == true").toArray().compactMap({ $0.jid })
                
                let groupsRaw = realm
                    .objects(RosterGroupStorageItem.self)
                    .filter("owner IN %@ AND isSystemGroup == false", jids)
                    .sorted(byKeyPath: "name")
                let contacts = realm
                    .objects(RosterStorageItem.self)
                    .filter("subscription_ == %@ AND removed == false AND isHidden == false AND isContact == false AND owner IN %@", "both", jids)
                    .toArray()
                let groups : [UIMenuElement] = groupsRaw.compactMap ({
                    group in
                    let count = contacts.filter({ Set($0.groups).contains(group.name) }).count
                    return UIAction(
                        title: group.name,
                        subtitle: "\(count)",
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
        
        let addBarButton = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(onAddButtonTouchUpInside)
        )
        let offlineButton = UIBarButtonItem(image: imageLiteral("person"), style: .plain, target: self, action: #selector(showOfflineSelector))
        if isGroup {
            if childs.count > 0 {
                self.navigationItem.setRightBarButtonItems([button, addBarButton], animated: true)
            } else {
                self.navigationItem.setRightBarButton(addBarButton, animated: true)
            }
        } else {
            if childs.count > 0 {
                self.navigationItem.setRightBarButtonItems([button, addBarButton, offlineButton], animated: true)
            } else {
                self.navigationItem.setRightBarButtonItems([addBarButton, offlineButton], animated: true)
            }
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
        
        self.canUpdateDataset = true
        self.runDatasetUpdateTask()
    }
    
    override func shouldChangeFrame() {
        super.shouldChangeFrame()
        var inputHeight: CGFloat = 49
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        
        let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
        bottomBar.updateFrame(to: frame)
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
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
        self.tableView.tableFooterView = UIView()
        
        emptyView.configure(image: imageLiteral( "person.3")?.upscale(dimension: 100).withRenderingMode(.alwaysTemplate),
                            title: getEmptyStateString() ?? "",
                            subtitle: "",
                            buttonTitle: "Add contact".localizeString(id: "application_action_no_contacts", arguments: [])) {
            
        }
        
        emptyView.isHidden = true
        view.addSubview(emptyView)
        emptyView.fillSuperview()
        view.bringSubviewToFront(emptyView)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
//        configureSearchBar()
        self.navigationItem.title = nil
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
        configureBars()
        if self.category == nil {
            if isGroup {
                self.category = "public"
                self.categoryDelegate?.filterDidSelect(category: "public")
            } else {
                self.category = "all"
                self.categoryDelegate?.filterDidSelect(category: "all")
            }
        }
        self.canUpdateDataset = true
        self.runDatasetUpdateTask()
        self.updateTitle()
    }
    
    override func reloadDatasource() {
        tableView.reloadData()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureBars()
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
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
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
        self.preprocessDataset(changeCategory: true)
        return self.showOffline
    }
    
    func shouldFilterBy(groups: [String]) {
        self.filteredGroups = Set(groups)
        self.preprocessDataset(changeCategory: true)
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
        self.preprocessDataset(changeCategory: true)
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
        self.preprocessDataset(changeCategory: true)
        if let category = category,
           let filter = Filter(rawValue: category) {
            self.filter.accept(filter)
        } else {
            self.filter.accept(.all)
        }
        self.updateTitle()
    }
}
