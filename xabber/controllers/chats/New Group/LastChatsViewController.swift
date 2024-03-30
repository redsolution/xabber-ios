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
import RxRealm
import RxSwift
import RxCocoa
import DeepDiff
import CocoaLumberjack
import MaterialComponents.MDCPalettes
import XMPPFramework.XMPPJID

public final class ChangesWithIndexPath {
    public let inserts: [IndexPath]
    public let deletes: [IndexPath]
    public var replaces: [IndexPath]
    public let moves: [(from: IndexPath, to: IndexPath)]

    public init(inserts: [IndexPath], deletes: [IndexPath], replaces: [IndexPath], moves: [(from: IndexPath, to: IndexPath)]) {
        self.inserts = inserts
        self.deletes = deletes
        self.replaces = replaces
        self.moves = moves
    }
}

class LastChatsViewController: BaseViewController {
    
    enum Filter: Int {
        case chats
        case unread
        case archived
    }
    
    struct Datasource: DiffAware {
        var diffId: String {
            get {
                return [jid, owner].prp()
            }
        }

        let jid: String
        let owner: String
        let username: String
        let message: String
        let date: Date
        let state: MessageStorageItem.MessageSendingState?
        let isMute: Bool
        let isSynced: Bool
        let status: ResourceStatus
        let entity: RosterItemEntity?
        let conversationType: ClientSynchronizationManager.ConversationType
        let unread: Int
        let unreadString: String?
        let color: UIColor
        let isDraft: Bool
        let hasAttachment: Bool
        let userNickname: String?
        let isSystemMessage: Bool
        let isPinned: Bool
        let subRequest: Bool
        let isEncrypted: Bool
        let avatarUrl: String?
        let hasErrorInChat: Bool
        let updateTS: Double
        let verificationSessionSid: String?
        let verificationState: VerificationSessionStorageItem.VerififcationState?
        
        static func compareContent(_ a: LastChatsViewController.Datasource, _ b: LastChatsViewController.Datasource) -> Bool {
            return a.jid == b.jid
                    && a.owner == b.owner
                    && a.username == b.username
                    && a.message == b.message
                    && a.date == b.date
                    && a.state == b.state
                    && a.isMute == b.isMute
                    && a.isSynced == b.isSynced
                    && a.status == b.status
                    && a.entity == b.entity
                    && a.conversationType == b.conversationType
                    && a.unread == b.unread
                    && a.unreadString == b.unreadString
                    && a.color == b.color
                    && a.isDraft == b.isDraft
                    && a.hasAttachment == b.hasAttachment
                    && a.userNickname == b.userNickname
                    && a.isSystemMessage == b.isSystemMessage
                    && a.isPinned == b.isPinned
                    && a.subRequest == b.subRequest
                    && a.isEncrypted == b.isEncrypted
                    && a.avatarUrl == b.avatarUrl
                    && a.hasErrorInChat == b.hasErrorInChat
                    && a.updateTS == b.updateTS
        }
        
    }
    
    struct DatasourceChangeset {
        public let needReload: Bool
        public let deleted: [Int]
        public let inserted: [Int]
        public let updated: [Int]
    }
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .plain)
        
        view.register(ChatListTableViewCell.self, forCellReuseIdentifier: ChatListTableViewCell.cellName)
        view.register(ArchivedCell.self, forCellReuseIdentifier: ArchivedCell.cellName)
        view.register(SkeletonCell.self, forCellReuseIdentifier: SkeletonCell.cellName)
        
        view.tableFooterView = UIView(frame: .zero)
        view.allowsMultipleSelection = false
        view.allowsMultipleSelectionDuringEditing = false
        view.cellLayoutMarginsFollowReadableWidth = false
        
        return view
    }()
    
    internal let emptyView: EmptyStateView = {
        let view = EmptyStateView()
        
        return view
    }()
    
    internal let customTitleLabel: UILabel = {
        let label = UILabel()
        
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 18, weight: UIFont.Weight.medium)
        
        return label
    }()
    
    internal let dropDownButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: #imageLiteral(resourceName: "chevron-down").withRenderingMode(.alwaysTemplate),
                                     style: .plain,
                                     target: nil,
                                     action: nil)
        button.tintColor = MDCPalette.grey.tint600
        return button
    }()
    
    internal let addButton: UIBarButtonItem = {
        let button = UIBarButtonItem(barButtonSystemItem: .add, target: nil, action: nil)
        button.tintColor = .systemGray
        return button
    }()
    
    internal let securityButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: UIImage(named: "security"), style: UIBarButtonItem.Style.plain, target: nil, action: nil)
        
        button.tintColor = .systemGray
        
        return button
    }()
    
    internal let unreadAllMessagesButton: UIButton = {
        let button = UIButton()
        
        button.tintColor = .white
        button.layer.cornerRadius = 18
        button.setTitle("Mark all as read".localizeString(id: "mark_all_as_read_button", arguments: []), for: .normal)
        button.isHidden = true
        
        return button
    }()
    
    internal let accountNavButton: AccountNavButton = {
        let button = AccountNavButton(frame: CGRect(width: 64, height: 40))
        
        return button
    }()
    
    internal let refreshControl: UIRefreshControl = {
        let control = UIRefreshControl()
        
        control.attributedTitle = nil
        control.tintColor = .clear
        
        return control
    }()
    
    internal var searchController: UISearchController = {
        let searchResults = SearchResultsViewController()
        let controller = UISearchController(searchResultsController: searchResults)
        
        controller.searchResultsUpdater = searchResults
        controller.searchBar.searchBarStyle = .prominent
        controller.searchBar.placeholder = "Search contacts and messages".localizeString(id: "search_contacts_and_messages", arguments: [])
        controller.searchBar.isTranslucent = true
        controller.hidesNavigationBarDuringPresentation = true
        controller.hidesBottomBarWhenPushed = true
        controller.definesPresentationContext = true
        
        return controller
    }()
    
    internal let pullDownTableHeaderView: PullDownTableHeaderView = {
        let view = PullDownTableHeaderView(frame: .zero)
        
        view.alpha = 0.0
        
        return view
    }()
    
    internal var isFirstLayout: Bool = false
    internal var isFirstLayoutSearchController: Bool = false
    
    internal var isAppeared: Bool = false
    
    internal var datasource: [Datasource] = []
    
    internal var bag: DisposeBag = DisposeBag()
    internal var datasetBag: DisposeBag = DisposeBag()
    internal var chatsObserver: Results<LastChatsStorageItem>? = nil
    internal var filter: BehaviorRelay<Filter> = BehaviorRelay(value: .chats)
    internal var isEmptyViewShowed: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal var archivedChats: Results<LastChatsStorageItem>? = nil
    
    internal var enabledAccounts: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    
    internal var showArchivedSection: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: false)
    internal var isArchivedSectionShowed: Bool = false
    internal var unreadArchivedChatsCount: Int = 0
    internal var archivedSectionSubtitleText: NSAttributedString = NSAttributedString()
    
    internal var editedIndexPath: IndexPath? = nil
    
    public var archivedMode: Bool = false
    
    internal var showSkeleton: BehaviorRelay<Bool> = BehaviorRelay(value: true)
    
    internal var topAccountJid: String = ""
    
    internal let updateQueue: DispatchQueue = DispatchQueue(label: "com.xabber.background.lastchats", qos: .background)
    
    internal var isSkeletonShowed: Bool = false
    
    internal func updateTitle(_ value: Filter) {
        DispatchQueue.main.async {
            do {
                let realm = try WRealm.safe()
                let accounts = Set(realm.objects(AccountStorageItem.self).toArray().compactMap { return $0.jid })
                let filteredConnectingUsers = AccountManager.shared.connectingUsers.value.filter({ accounts.contains($0) })
                if filteredConnectingUsers.isNotEmpty {
                    self.customTitleLabel.text = "Connecting...".localizeString(id: "account_state_connecting", arguments: [])
                    self.customTitleLabel.sizeToFit()
                    self.customTitleLabel.layoutIfNeeded()
                    return
                }
            } catch {
                
            }
            
            switch value {
                case .chats:
                    self.customTitleLabel.text = "Chats".localizeString(id: "toolbar__menu_item__chats", arguments: [])
                    getAppTabBar()?.tabBar.items?.first?.title = "Chats".localizeString(id: "toolbar__menu_item__chats", arguments: [])
                case .unread:
                    self.customTitleLabel.text = "Unread".localizeString(id: "unread_chats", arguments: [])
                    getAppTabBar()?.tabBar.items?.first?.title = "Unread".localizeString(id: "unread_chats", arguments: [])
                case .archived:
                    self.customTitleLabel.text = "Archived".localizeString(id: "archived_chats", arguments: [])
                    getAppTabBar()?.tabBar.items?.first?.title = "Archived".localizeString(id: "archived_chats", arguments: [])
            }
            self.customTitleLabel.sizeToFit()
            self.customTitleLabel.layoutIfNeeded()
        }
    }
    
    internal func updateDatasource(_ value: Filter) {
        do {
            let realm = try  WRealm.safe()

            let predicate: NSPredicate
            
            var pinnedChatsSorting: Bool = false
            
            switch value {
            case .chats:
                predicate = NSPredicate(format: "isArchived == %@ AND owner IN %@", argumentArray: [false, Array(enabledAccounts.value)])
                pinnedChatsSorting = true
            case .unread:
                showArchivedSection.accept(false)
                predicate = NSPredicate(format: "isArchived == %@ AND (unread > %@ OR rosterItem.ask_ IN %@) AND owner IN %@",
                                        argumentArray: [false,
                                                        0,
                                                        [RosterStorageItem.Ask.in.rawValue, RosterStorageItem.Ask.both.rawValue],
                                                        Array(enabledAccounts.value)])
                tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
            case .archived:
                predicate = NSPredicate(format: "isArchived == %@ AND owner IN %@", argumentArray: [true, Array(enabledAccounts.value)])

                getAppTabBar()?.hide()
            }
            chatsObserver = realm
                .objects(LastChatsStorageItem.self)
                .filter(predicate)
            
            if pinnedChatsSorting {
                chatsObserver = chatsObserver?.sorted(by: [
                    SortDescriptor(keyPath: "isPinned", ascending: false),
                    SortDescriptor(keyPath: "pinnedPosition", ascending: true),
                    SortDescriptor(keyPath: "messageDate", ascending: false)
                ])
            } else {
                chatsObserver = chatsObserver?.sorted(by: [
                    SortDescriptor(keyPath: "messageDate", ascending: false)
                ])
            }
            
            archivedChats = realm
                .objects(LastChatsStorageItem.self)
                .filter( "isArchived == %@ AND owner IN %@", true, Array(enabledAccounts.value))
                .sorted(byKeyPath: "messageDate", ascending: false)
            
            datasetBag = DisposeBag()
            
            self.showSkeleton
                .asObservable()
//                .debounce(.milliseconds(50), scheduler: MainScheduler.asyncInstance)
                .skip(1)
                .subscribe { _ in
                    
                    print(#function, "show skeleton")
                    self.runDatasetUpdateTask()
                }
                .disposed(by: self.bag)
            
            Observable
                .collection(from: chatsObserver!)
                .debounce(.milliseconds(400), scheduler: MainScheduler.asyncInstance)
                .skip(1)
                .subscribe { (results) in
                    print(#function, "show skeleton")
                    self.runDatasetUpdateTask()
                } onError: { (error) in
                    DDLogDebug("LastChatsViewController: \(#function). RX error: \(error.localizedDescription)")
                } onCompleted: {
                    DDLogDebug("LastChatsViewController: \(#function). RX state: completed")
                } onDisposed: {
                    DDLogDebug("LastChatsViewController: \(#function). RX state: disposed")
                }
                .disposed(by: datasetBag)
            
            let predicateForVerifySessions = NSPredicate(format: "state_ IN %@ AND (owner IN %@ OR jid IN %@)",
                                        argumentArray: [
                                            [VerificationSessionStorageItem.VerififcationState.sentRequest.rawValue,
                                             VerificationSessionStorageItem.VerififcationState.receivedRequest.rawValue,
                                             VerificationSessionStorageItem.VerififcationState.acceptedRequest.rawValue,
                                             VerificationSessionStorageItem.VerififcationState.receivedRequestAccept.rawValue],
                                            Array(enabledAccounts.value),
                                            Array(enabledAccounts.value)
                                        ])
            Observable
                .collection(from: realm.objects(VerificationSessionStorageItem.self).filter(predicateForVerifySessions))
                .debounce(.milliseconds(400), scheduler: MainScheduler.asyncInstance)
                .subscribe { (results) in
                    self.runDatasetUpdateTask()
                } onError: { (error) in
                    DDLogDebug("LastChatsViewController: \(#function). RX error: \(error.localizedDescription)")
                } onCompleted: {
                    DDLogDebug("LastChatsViewController: \(#function). RX state: completed")
                } onDisposed: {
                    DDLogDebug("LastChatsViewController: \(#function). RX state: disposed")
                }
                .disposed(by: datasetBag)

            canUpdateDataset = true
            runDatasetUpdateTask()
            
            Observable
                .collection(from: chatsObserver!)
                .subscribe(onNext: { (results) in
                    if results.isEmpty {
                        if !self.isEmptyViewShowed.value {
                            self.isEmptyViewShowed.accept(true)
                        }
                    } else {
                        if self.isEmptyViewShowed.value {
                            self.isEmptyViewShowed.accept(false)
                        }
                    }
                    if self.filter.value == .unread {
                        UIView.animate(withDuration: 0.1) {
                            self.unreadAllMessagesButton.isHidden = self.filter.value == .unread ? results.filter{ $0.unread != 0 }.isEmpty : false
                            self.unreadAllMessagesButton.isEnabled = AccountManager.shared.connectingUsers.value.isEmpty
                            self.unreadAllMessagesButton.backgroundColor = AccountManager.shared.connectingUsers.value.isNotEmpty ? MDCPalette.grey.tint500 : AccountColorManager.shared.topPalette().tint500
                        }

                    } else {
                        self.unreadAllMessagesButton.isHidden = true
                    }
                })
                .disposed(by: datasetBag)
            
            if archivedChats != nil {
                Observable
                    .collection(from: archivedChats!)
                    .debounce(.milliseconds(200), scheduler: MainScheduler.asyncInstance)
                    .subscribe(onNext: { (results) in
                        self.archivedSectionSubtitleText = self.updateArchivedSectionTitle()
                        self.unreadArchivedChatsCount = results.toArray().filter({ $0.unread > 0 }).compactMap{ return $0.unread }.reduce(0, +)
                        if self.showArchivedSection.value {
                            UIView.performWithoutAnimation {
                                self.tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
                            }
                        }
                    })
                    .disposed(by: datasetBag)
            }
            
        } catch {
            DDLogDebug("cant change filter for last chats")
        }
    }
    
    private final func mapDataset() -> [Datasource] {
        if self.showSkeleton.value {
            return (0..<(self.chatsObserver?.count ?? 10)).compactMap {
                return Datasource(
                    jid: "\($0)",
                    owner: "",
                    username: "",
                    message: "",
                    date: Date(),
                    state: nil,
                    isMute: false,
                    isSynced: false,
                    status: .away,
                    entity: .bot,
                    conversationType: .axolotl,
                    unread: 0,
                    unreadString: nil,
                    color: .white,
                    isDraft: false,
                    hasAttachment: false,
                    userNickname: nil,
                    isSystemMessage: false,
                    isPinned: false,
                    subRequest: false,
                    isEncrypted: false,
                    avatarUrl: nil,
                    hasErrorInChat: false,
                    updateTS: 0,
                    verificationSessionSid: nil,
                    verificationState: nil
                )
            }
        }
        do {
            let realm = try  WRealm.safe()
            let predicate: NSPredicate
            var pinnedChatsSorting: Bool = false
            switch self.filter.value {
            case .chats:
                if let lockedType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) {
                    predicate = NSPredicate(
                        format: "isArchived == %@ AND owner IN %@ AND (conversationType_ == %@ OR jid IN %@)",
                        argumentArray: [
                            false,
                            Array(enabledAccounts.value),
                            lockedType.rawValue,
                            Array(enabledAccounts.value).compactMap({XMPPJID(string: $0)!.domain})
                        ]
                    )
                } else {
                    predicate = NSPredicate(format: "isArchived == %@ AND owner IN %@", argumentArray: [false, Array(enabledAccounts.value)])
                }
                pinnedChatsSorting = true
            case .unread:
                if let lockedType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) {
                    predicate = NSPredicate(
                        format: "isArchived == %@ AND owner IN %@ AND (conversationType_ == %@ OR jid IN %@) AND (unread > %@ OR rosterItem.ask_ IN %@)",
                        argumentArray: [
                            false,
                            Array(enabledAccounts.value),
                            lockedType.rawValue,
                            Array(enabledAccounts.value).compactMap({XMPPJID(string: $0)!.domain}),
                            0,
                            [RosterStorageItem.Ask.in.rawValue, RosterStorageItem.Ask.both.rawValue],
                        ]
                    )
                } else {
                    predicate = NSPredicate(format: "isArchived == %@ AND (unread > %@ OR rosterItem.ask_ IN %@) AND owner IN %@",
                                            argumentArray: [false,
                                                            0,
                                                            [RosterStorageItem.Ask.in.rawValue, RosterStorageItem.Ask.both.rawValue],
                                                            Array(enabledAccounts.value)])
                    
                }
            case .archived:
                if let lockedType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) {
                    predicate = NSPredicate(
                        format: "isArchived == %@ AND owner IN %@ AND (conversationType_ == %@ OR jid IN %@)",
                        argumentArray: [
                            true,
                            Array(enabledAccounts.value),
                            lockedType.rawValue,
                            Array(enabledAccounts.value).compactMap({XMPPJID(string: $0)!.domain})
                        ]
                    )
                } else {
                    predicate = NSPredicate(format: "isArchived == %@ AND owner IN %@", argumentArray: [true, Array(enabledAccounts.value)])
                }
            }
            var collection = realm
                .objects(LastChatsStorageItem.self)
                .filter(predicate)
            
            if pinnedChatsSorting {
                collection = collection.sorted(by: [
                    SortDescriptor(keyPath: "isPinned", ascending: false),
                    SortDescriptor(keyPath: "pinnedPosition", ascending: true),
                    SortDescriptor(keyPath: "messageDate", ascending: false)
                ])
            } else {
                collection = collection.sorted(by: [
                    SortDescriptor(keyPath: "messageDate", ascending: false)
                ])
            }
            
            return collection.compactMap {
                item in
                
                var blankMessageText: String = "No messages".localizeString(id: "no_messages", arguments: [])
                if item.messagesCount != 0 {
                    blankMessageText = (item.retractVersion == "0" && item.retractVersion != "") ? "No messages".localizeString(id: "no_messages", arguments: []) : "No messages".localizeString(id: "no_messages", arguments: [])

                }
                
                let subscriptionRequest: Bool
                if let rosterItem = item.rosterItem {
                    subscriptionRequest = rosterItem.isThereSubscriptionRequest()
                } else {
                    subscriptionRequest = false
                }
                
                let primaryResource = item.rosterItem?.getPrimaryResource()
                
                var message: String
                
                if let lastMessage = item.lastMessage {
                    message = lastMessage.displayedBody(entity: primaryResource?.entity ?? .contact)
                    if message.isEmpty {
                        message = subscriptionRequest ? "Incoming chat request" : blankMessageText
                    }
                    if lastMessage.isDeleted {
                        message = blankMessageText
                    }
                } else {
                    message = subscriptionRequest ? "Incoming chat request" : blankMessageText
                }
                
                var isDraft: Bool = false
                if let draft = item.draftMessage {
                    message = draft
                    isDraft = true
                }
                if item.conversationType != .group {
                    if let action = CommonChatStatesManager.shared.actionText(for: item.jid, owner: item.owner) {
                        message = action
                    }
                }
                var isAttachment: Bool = [
                    MessageStorageItem.MessageDisplayType.sticker,
                    MessageStorageItem.MessageDisplayType.files,
                    MessageStorageItem.MessageDisplayType.images,
                    MessageStorageItem.MessageDisplayType.voice,
                    MessageStorageItem.MessageDisplayType.call].contains(item.lastMessage?.displayAs ?? .text)
                if !isAttachment,
                   let authMessageMetadata = item.lastMessage?.systemMetadata?["auth_message"] as? Bool,
                   authMessageMetadata {
                    isAttachment = true
                }
                
                let isInvite = item.unread > 0 ? ((item.lastMessage?.displayAs ?? .text) == .initial ? true : false) : false
                
                var nickname: String? = item.lastMessage?.groupchatDisplayedNickname
                if item.lastMessage?.inlineForwards.isNotEmpty ?? false {
                    let sender = item.lastMessage?.inlineForwards.first
                    var nick = sender?.forwardNickname
                    if nick == "" || nick == nil {
                        nick = String(JidManager.shared.prepareJid(jid: sender?.forwardJid ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])))
                    }
                    switch item.lastMessage?.inlineForwards.first?.kind {
                    case .text:
                        nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])): \(item.lastMessage?.inlineForwards.first?.body ?? "")"
                    case .images:
                        nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " image".localizeString(id: "forward_image", arguments: [])
                    case .videos:
                        nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " video".localizeString(id: "forward_video", arguments: [])
                    case .files:
                        nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " file".localizeString(id: "forward_file", arguments: [])
                    case .voice:
                        nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " voice message".localizeString(id: "forward_voice", arguments: [])
                    case .quote:
                        nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])): \(item.lastMessage?.inlineForwards.first?.body ?? "")"
                    case .none:
                        nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: []))"
                    }
                }
                
                var isSystemMessage: Bool = [.system, .initial].contains(item.lastMessage?.displayAs ?? .text)
                if item.isFreshNotEmptyEncryptedChat {
                    message = "Write your encrypted messages here"
                    isSystemMessage = true
                }
                return Datasource(
                    jid: item.jid,
                    owner: item.owner,
                    username: item.rosterItem?.displayName ?? item.jid,
                    message: message,
                    date: item.messageDate,
                    state: item.lastMessage?.outgoing ?? true ? item.lastMessage?.state ?? nil : nil,
                    isMute: item.isMuted,
                    isSynced: item.isSynced,
                    status: primaryResource?.status ?? .offline,
                    entity: primaryResource?.entity ?? .contact,
                    conversationType: item.conversationType,
                    unread: item.lastMessage?.outgoing ?? false ? 0 : item.unread,
                    unreadString: isInvite ? "1" : nil,
                    color: AccountManager.shared.users.count <= 1 ? .clear : AccountColorManager.shared.primaryColor(for: item.owner),
                    isDraft: isDraft,
                    hasAttachment: isAttachment,
                    userNickname: nickname,
                    isSystemMessage: isSystemMessage,
                    isPinned: item.isPinned,
                    subRequest: (XMPPJID(string: item.jid)?.isServer ?? true) ? false :  subscriptionRequest,
                    isEncrypted: [.omemo, .axolotl, .omemo1].contains(item.conversationType),
                    avatarUrl: item.rosterItem?.avatarMinUrl ?? item.rosterItem?.avatarMaxUrl ?? item.rosterItem?.oldschoolAvatarKey,
                    hasErrorInChat: item.hasErrorInChat,
                    updateTS: item.updateTS,
                    verificationSessionSid: nil,
                    verificationState: nil
                )
            }
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
        }
        return []
    }
    
    public final var canUpdateDataset = true
    
    
    private final func convertChangeset(changes: [Change<Datasource>]) -> ChangesWithIndexPath {
        let inserts =  changes.compactMap { return $0.insert?.index }.compactMap({ return IndexPath(row:$0, section: 0)})
        let deletes =  changes.compactMap { return $0.delete?.index }.compactMap({ return IndexPath(row:$0, section: 0 )})
        let replaces = changes.compactMap { return $0.replace?.index }.compactMap({ return IndexPath(row:$0, section: 0 )})
        
        let moves = changes.compactMap({ $0.move }).map({
          (
            from: IndexPath(item: $0.fromIndex, section: 0),
            to: IndexPath(item: $0.toIndex, section: 0)
          )
        })
        
        return ChangesWithIndexPath(
            inserts: inserts,
            deletes: deletes,
            replaces: replaces,
            moves: moves
        )
    }
    
    public final func initializeDataset() {
        
    }
    
    public final func runDatasetUpdateTask() {
        preprocessDataset()
        postprocessDataset()
    }
    
    private final func preprocessDataset() {
        if !canUpdateDataset { return }
        if showSkeleton.value {
            self.canUpdateDataset = false
            self.datasource = self.mapDataset()
            self.datasource = self.getVerifySessionItems() + self.datasource
            self.tableView.reloadData()
            self.canUpdateDataset = true
            return
        }
        self.updateQueue.sync {
            self.canUpdateDataset = false
            let newDataset = self.getVerifySessionItems() + self.mapDataset()
            let changes = diff(old: self.datasource, new: newDataset)
            let indexPaths = self.convertChangeset(changes: changes)
            DispatchQueue.main.async {
                if !self.isFirstLayout {
                    UIView.performWithoutAnimation {
                        self.apply(changes: indexPaths) {
                            self.datasource = newDataset
                        }
                    }
                } else {
                    let updatesCount = indexPaths.deletes.count + indexPaths.inserts.count + indexPaths.moves.count
                    if updatesCount < 4 {
                        self.apply(changes: indexPaths) {
                            self.datasource = newDataset
                        }
                    } else {
                        UIView.performWithoutAnimation {
                            self.apply(changes: indexPaths) {
                                self.datasource = newDataset
                            }
                        }
                    }
                }
            }
        }
    }
    
    private final func postprocessDataset() {
        
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
    
    internal func subscribe() {
        bag = DisposeBag()
        
        do {
            let realm = try  WRealm.safe()
            Observable
                .collection(from: realm.objects(AccountStorageItem.self).filter("enabled == %@", true))
                .subscribe(onNext: { (results) in
                    let jids: [String] = results.compactMap{ return $0.jid }
                    if jids.count != self.enabledAccounts.value.count {
                        self.enabledAccounts.accept(Set(jids))
                    }
                })
                .disposed(by: bag)
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
        }
        
        AccountManager
            .shared
            .connectingUsers
            .asObservable()
//            .debounce(.milliseconds(70), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (results) in
                do {
                    let realm = try WRealm.safe()
                    let accounts = Set(realm.objects(AccountStorageItem.self).toArray().compactMap { return $0.jid })
                    let filteredConnectingUsers = results.filter({ accounts.contains($0) })
                    self.updateTitle(self.filter.value)
                    self.unreadAllMessagesButton.isEnabled = filteredConnectingUsers.isEmpty
                    UIView.animate(withDuration: 0.1) {
                        self.unreadAllMessagesButton.backgroundColor = filteredConnectingUsers.isNotEmpty ? MDCPalette.grey.tint500 : AccountColorManager.shared.topPalette().tint500
                    }
                    if self.isSkeletonShowed { return }
                    if filteredConnectingUsers.isNotEmpty {
                        if !self.showSkeleton.value {
                            self.showSkeleton.accept(true)
                        }
                    } else {
                        if self.showSkeleton.value {
                            self.showSkeleton.accept(false)
                            self.isSkeletonShowed = true
                        }
                    }
                } catch {
                    
                }
                
                
            })
            .disposed(by: bag)
        
        enabledAccounts
            .asObservable()
            .subscribe(onNext: { (values) in
                self.filter.accept(self.filter.value)
                do {
                    let realm = try  WRealm.safe()
                    self.archivedChats = realm
                        .objects(LastChatsStorageItem.self)
                        .filter("isArchived == true AND owner IN %@", Array(values))
                        .sorted(byKeyPath: "messageDate", ascending: false)
                } catch {
                    DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
                }
            })
            .disposed(by: bag)
        
        filter
            .asObservable()
            .debounce(.milliseconds(1), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (value) in
                switch value {
                case .chats:
                    self.emptyView.update(
                        image:  #imageLiteral(resourceName: "buffer160").withRenderingMode(.alwaysTemplate),
                        title: "Chats list is empty".localizeString(id: "chats_list_is_empty", arguments: []),
                        subtitle: "Try to start a new chat".localizeString(id: "try_to_start_new_chat", arguments: []),
                        buttonTitle: "Start new chat".localizeString(id: "start_new_chat", arguments: [])
                    )
                    break
                case .unread:
                    self.emptyView.update(
                        image:  #imageLiteral(resourceName: "buffer160").withRenderingMode(.alwaysTemplate),
                        title: "No unread chats".localizeString(id: "unreaded_chats_list_empty", arguments: []),
                        subtitle: " ",
                        buttonTitle: " "
                    )
                    break
                case .archived:
                    self.emptyView.update(
                        image:  #imageLiteral(resourceName: "buffer160").withRenderingMode(.alwaysTemplate),
                        title: "Your archived chats list is empty".localizeString(id: "archived_chats_list_empty", arguments: []),
                        subtitle: " ",
                        buttonTitle: " "
                    )
                    break
                }
                self.updateDatasource(value)
                self.updateTitle(value)
            })
            .disposed(by: bag)
        
        isEmptyViewShowed
            .asObservable()
            .subscribe(onNext: { (value) in
                self.emptyView.isHidden = !value
            })
            .disposed(by: bag)

        CommonChatStatesManager
            .shared
            .observed
            .asObservable()
            .debounce(.milliseconds(150), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (result) in
                func updateDatasource() {
                    self.tableView.reloadRows(at: result.compactMap {
                        item in
                        if let row = self.datasource.firstIndex(where: { $0.jid == item.jid && $0.owner == item.owner }) {
                            return IndexPath(row: row, section: 0)
                        }
                        return nil
                    }, with: .none)
                }
                if #available(iOS 11.0, *) {
                    self.tableView.performBatchUpdates({
                        updateDatasource()
                    }, completion: nil)
                } else {
                    self.tableView.beginUpdates()
                    updateDatasource()
                    self.tableView.endUpdates()
                }
            })
            .disposed(by: bag)
        
        showArchivedSection
            .asObservable()
            .subscribe(onNext: { (value) in
                if value && (self.archivedChats?.isEmpty ?? true) {
                    self.isArchivedSectionShowed = false
                    self.showArchivedSection.accept(false)
                    return
                }
                if value == self.isArchivedSectionShowed { return }
                if value {
                    self.pullDownTableHeaderView.changeState(to: .disabled)
                    self.tableView.insertRows(at: [IndexPath(row: 0, section: 0)], with: .top)
                } else {
                    self.pullDownTableHeaderView.changeState(to: .normal)
                    UIView.performWithoutAnimation {
                        self.tableView.deleteRows(at: [IndexPath(row: 0, section: 0)], with: .none)
                    }
                }
                self.isArchivedSectionShowed = value
            })
            .disposed(by: bag)
        
        do {
            let realm = try  WRealm.safe()
            let collection = realm
                .objects(AccountStorageItem.self)
                .filter("enabled == true")
                .sorted(byKeyPath: "order", ascending: true)
            self.accountNavButton.update(jid: self.topAccountJid, status: collection.first?.resource?.status ?? .offline)
            Observable
                .collection(from: collection)
                .debounce(.milliseconds(500), scheduler: MainScheduler.asyncInstance)
                .skip(1)
                .subscribe(onNext: { (results) in
                    if let item = results.first {
                        self.topAccountJid = item.jid
                        self.accountNavButton.update(jid: self.topAccountJid, status: item.resource?.status ?? .offline)
                        self.unreadAllMessagesButton.isEnabled = AccountManager.shared.connectingUsers.value.isEmpty
                        getAppTabBar()?.updateColor()
                        self.customTitleLabel.textColor = AccountColorManager.shared.topColor()
                        self.addButton.tintColor = AccountColorManager.shared.topColor()
                        self.unreadAllMessagesButton.backgroundColor = AccountManager.shared.connectingUsers.value.isNotEmpty ? MDCPalette.grey.tint500 : AccountColorManager.shared.topPalette().tint500
                    }
                }).disposed(by: bag)
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
        }
        
        addObservers()
    }
    
    internal func unsubscribe() {
        bag = DisposeBag()
        datasetBag = DisposeBag()
        removeObservers()
    }
    
    private func addObservers() {
        NotificationCenter
            .default
            .addObserver(self,
                         selector: #selector(willEnterForeground),
                         name: UIApplication.willEnterForegroundNotification,
                         object: UIApplication.shared)
    }
    
    @objc
    private func willEnterForeground() {
        print(#function)
        NotifyManager.shared.clearAllNotifications()
    }
    
    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
    }
    
    internal func activateConstraints() {
        
    }
    
    internal func configure() {
        title = " "
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        
        if #available(iOS 13.0, *) {
            tableView.backgroundColor = .systemBackground
        } else {
            tableView.backgroundColor = .white
        }
        
        emptyView.configure(image: #imageLiteral(resourceName: "buffer160").withRenderingMode(.alwaysTemplate),
                            title: "Chats list is empty".localizeString(id: "chats_list_is_empty", arguments: []),
                            subtitle: "Try to start a new chat".localizeString(id: "try_to_start_new_chat", arguments: []),
                            buttonTitle: "Start new chat".localizeString(id: "start_new_chat", arguments: [])) {
            self.showAddDialog()
        }
        
        emptyView.isHidden = true
        view.addSubview(emptyView)
        emptyView.fillSuperview()
        view.bringSubviewToFront(emptyView)
        
        if !archivedMode {
            configurePullToArchived()
        }
        do {
            let realm = try  WRealm.safe()
            let collection = realm
                .objects(AccountStorageItem.self)
                .filter("enabled == true")
                .sorted(byKeyPath: "order", ascending: true)
            
            enabledAccounts.accept(Set(collection.compactMap { return $0.jid }))
            
            if let item = collection.first {
                self.topAccountJid = item.jid
                self.accountNavButton.update(jid: self.topAccountJid, status: item.resource?.status ?? .offline)
                self.unreadAllMessagesButton.isEnabled = AccountManager.shared.connectingUsers.value.isEmpty
                getAppTabBar()?.updateColor()
                self.customTitleLabel.textColor = AccountColorManager.shared.topColor()
                self.addButton.tintColor = AccountColorManager.shared.topColor()
                self.unreadAllMessagesButton.backgroundColor = AccountManager.shared.connectingUsers.value.isNotEmpty ? MDCPalette.grey.tint500 : AccountColorManager.shared.topPalette().tint500
            }
            
            
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
        }
        configureNavbar()
    }

    internal func configureNavbar() {
        if !archivedMode {
            addButton.target = self
            addButton.action = #selector(onAddContact)
            securityButton.target = self
            securityButton.action = #selector(onRegisterYubikey)
            if CommonConfigManager.shared.config.use_yubikey {
                navigationItem.setRightBarButtonItems([addButton, securityButton], animated: true)
            } else {
                navigationItem.setRightBarButtonItems([addButton], animated: true)
            }
            let leftButton = UIBarButtonItem(customView: accountNavButton)
            accountNavButton.addTarget(self, action: #selector(onAccountNavButtonPress), for: .touchUpInside)
            navigationItem.setLeftBarButton(leftButton, animated: true)
            unreadAllMessagesButton.frame = CGRect(
                x: (view.frame.width - 156) / 2,
                y: view.frame.height - 96 - (UIDevice.needBottomOffset ? 32 : 0),
                width: 156,
                height: 36
            )
            unreadAllMessagesButton.addTarget(self, action: #selector(self.onReadAllMessages), for: .touchUpInside)
            view.addSubview(unreadAllMessagesButton)
        }
        navigationController?
            .navigationBar
            .titleTextAttributes = [NSAttributedString.Key.foregroundColor: AccountColorManager.shared.topColor()]
        
        customTitleLabel.textColor = AccountColorManager.shared.topColor()
        self.navigationItem.titleView = customTitleLabel
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        AccountManager.shared.users.forEach {
            user in
            user.action { user, _ in
                user.cloudStorage.getStats()
            }
        }
        
        NotifyManager.shared.setLastChats(displayed: true)
        title = " "
        configure()
        configureSearchBar()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reloadDatasource),
                                               name: .newMaskSelected,
                                               object: nil)
//        do {
//            let realm = try WRealm.safe()
//            realm.objects(LastChatsStorageItem.self).forEach {
//                DefaultAvatarManager.shared.getAvatar(jid: $0.jid, owner: $0.owner, size: 56) { image in
//                    self.avatarView.image = image
//                }
//            }
//        } catch {
//            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
//        }
        
    }
    
    override func reloadDatasource() {
        tableView.reloadData()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        searchController.isActive = false
        navigationController?.setNavigationBarHidden(false, animated: true)
        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        navigationController?.navigationBar.shadowImage = nil
        NotifyManager.shared.setLastChats(displayed: true)
        isAppeared = true
        self.tabBarController?.tabBar.isHidden = false
        self.tabBarController?.tabBar.layoutIfNeeded()
        subscribe()
        if SignatureManager.shared.certificate != nil {
            self.securityButton.tintColor = .systemGreen
        } else {
            self.securityButton.tintColor = .systemRed
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateTitle(filter.value)
        if let appDelegate = (UIApplication.shared.delegate as? AppDelegate) {
            appDelegate.appTabBarTitlesInit()
        }
        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        self.navigationController?.navigationBar.shadowImage = nil
        self.navigationController?.navigationBar.superview?.bringSubviewToFront(self.navigationController!.navigationBar)
        self.navigationController?.navigationBar.layoutIfNeeded()
        if #available(iOS 14.0, *) {
            navigationItem.backButtonDisplayMode = .minimal
        }
        self.navigationItem.backButtonTitle = "Chats"
        if let selected = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: selected, animated: true)
        }
        NotifyManager.shared.setLastChats(displayed: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound, .badge]) {
                (granted, error) in
                
            }
        }
        isFirstLayout = true
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotifyManager.shared.setLastChats(displayed: false)
        isAppeared = false
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unsubscribe()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    deinit {
        unsubscribe()
    }
}

extension LastChatsViewController {
    func getVerifySessionItems() -> [Datasource] {
        let predicateForVerifySessions = NSPredicate(format: "state_ IN %@ AND (owner IN %@ OR jid IN %@)",
                                    argumentArray: [
                                        [VerificationSessionStorageItem.VerififcationState.sentRequest.rawValue,
                                         VerificationSessionStorageItem.VerififcationState.receivedRequest.rawValue,
                                         VerificationSessionStorageItem.VerififcationState.acceptedRequest.rawValue,
                                         VerificationSessionStorageItem.VerififcationState.receivedRequestAccept.rawValue,
                                         VerificationSessionStorageItem.VerififcationState.failed.rawValue,
                                         VerificationSessionStorageItem.VerififcationState.rejected.rawValue,
                                         VerificationSessionStorageItem.VerififcationState.trusted.rawValue],
                                        Array(enabledAccounts.value),
                                        Array(enabledAccounts.value)
                                    ])
        do {
            let realm = try WRealm.safe()
            let verifyStorageList = realm.objects(VerificationSessionStorageItem.self).filter(predicateForVerifySessions)
            if verifyStorageList.isEmpty {
                return []
            }
            return verifyStorageList.compactMap { item in
                Datasource(jid: item.jid, owner: item.owner, username: item.jid, message: "Verification session", date: Date(timeIntervalSince1970: Double(item.timestamp)!), state: nil, isMute: false, isSynced: false, status: .online, entity: nil, conversationType: .regular, unread: 0, unreadString: "", color: UIColor.blue, isDraft: false, hasAttachment: false, userNickname: nil, isSystemMessage: true, isPinned: false, subRequest: false, isEncrypted: false, avatarUrl: nil, hasErrorInChat: false, updateTS: 0, verificationSessionSid: item.sid, verificationState: item.state)
            }
        } catch {
            fatalError()
        }
    }
}
