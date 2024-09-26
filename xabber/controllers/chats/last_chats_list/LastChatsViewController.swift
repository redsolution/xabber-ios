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
        case saved
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
        let attributedUsername: NSAttributedString?
        let message: String
        let date: Date?
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
        let isVerificationActionRequired: Bool
        
        static func compareContent(_ a: LastChatsViewController.Datasource, _ b: LastChatsViewController.Datasource) -> Bool {
            return a.jid == b.jid
                    && a.owner == b.owner
                    && a.username == b.username
                    && a.attributedUsername == b.attributedUsername
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
//        view.allowsMultipleSelection = false
//        view.allowsMultipleSelectionDuringEditing = false
//        view.cellLayoutMarginsFollowReadableWidth = false
        
        return view
    }()
    
    internal let emptyView: EmptyStateView = {
        let view = EmptyStateView()
        
        return view
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
        
//        button.isUserInteractionEnabled = false
        
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
    
    internal let bottomBar: BottomBarView = {
        let view = BottomBarView(frame: .zero)
        
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
    
//    internal var showArchivedSection: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: false)
    internal var isArchivedSectionShowed: Bool = false
    internal var unreadArchivedChatsCount: Int = 0
    internal var archivedSectionSubtitleText: NSAttributedString = NSAttributedString()
    
    internal var editedIndexPath: IndexPath? = nil
    
    public var archivedMode: Bool = false
    
    internal var showSkeleton: BehaviorRelay<Bool> = BehaviorRelay(value: true)
    
    internal var topAccountJid: String = ""
    
    internal let updateQueue: DispatchQueue = DispatchQueue(label: "com.xabber.background.lastchats", qos: .background)
    
    internal var isSkeletonShowed: Bool = false
    
    open var splitDelegate: SplitViewControllerDelegate? = nil
    
    internal func updateTitle(_ value: Filter) {
        do {
            let realm = try WRealm.safe()
            let accounts = Set(realm.objects(AccountStorageItem.self).toArray().compactMap { return $0.jid })
            let filteredConnectingUsers = AccountManager.shared.connectingUsers.value.filter({ accounts.contains($0) })
            if filteredConnectingUsers.isNotEmpty {
                self.bottomBar.connectionState = .connecting
            } else {
                self.bottomBar.connectionState = .normal
            }
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
        }
        switch value {
        case .chats, .saved:
                self.title = "Chats".localizeString(id: "toolbar__menu_item__chats", arguments: [])
            case .unread:
                self.title = "Unread".localizeString(id: "unread_chats", arguments: [])
            case .archived:
                self.title = "Archived".localizeString(id: "archived_chats", arguments: [])
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
//                showArchivedSection.accept(false)
                predicate = NSPredicate(format: "isArchived == %@ AND unread > %@ AND owner IN %@",
                                        argumentArray: [false,
                                                        0,
                                                        Array(enabledAccounts.value)])
                tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
            case .archived:
                predicate = NSPredicate(format: "isArchived == %@ AND owner IN %@", argumentArray: [true, Array(enabledAccounts.value)])
            case .saved:
                predicate = NSPredicate(format: "owner IN %@ AND conversationType_ == %@", argumentArray: [Array(enabledAccounts.value), ClientSynchronizationManager.ConversationType.saved.rawValue])
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
                .debounce(.milliseconds(70), scheduler: MainScheduler.asyncInstance)
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
                    do {
                        try self.updateBottomTitle()
                    } catch {
                        DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
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
//                        if self.showArchivedSection.value {
//                            UIView.performWithoutAnimation {
//                                self.tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
//                            }
//                        }
                    })
                    .disposed(by: datasetBag)
            }
            
        } catch {
            DDLogDebug("cant change filter for last chats")
        }
    }
    
    var unreadedJids: [String] = []
    
    private final func mapDataset() -> [Datasource] {
        if self.showSkeleton.value {
            return (0..<(self.chatsObserver?.count ?? 10)).compactMap {
                return Datasource(
                    jid: "\($0)",
                    owner: "",
                    username: "",
                    attributedUsername: nil,
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
                    isVerificationActionRequired: false
                )
            }
        }
        do {
            let realm = try  WRealm.safe()
            let predicate: NSPredicate
            var pinnedChatsSorting: Bool = false
            switch self.filter.value {
            case .chats:
                self.unreadedJids = []
                if let lockedType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) {
                    var excludedJids = Array(enabledAccounts.value).compactMap({XMPPJID(string: $0)!.domain})
                    excludedJids.append(CommonConfigManager.shared.config.support_jid)
                    predicate = NSPredicate(
                        format: "isArchived == %@ AND owner IN %@ AND (conversationType_ == %@ OR jid IN %@)",
                        argumentArray: [
                            false,
                            Array(enabledAccounts.value),
                            lockedType.rawValue,
                            excludedJids
                        ]
                    )
                } else {
                    predicate = NSPredicate(format: "isArchived == %@ AND owner IN %@", argumentArray: [false, Array(enabledAccounts.value)])
                }
                pinnedChatsSorting = true
            case .unread:
                if let lockedType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) {
                    
                    var excludedJids = Array(enabledAccounts.value).compactMap({XMPPJID(string: $0)!.domain})
                    excludedJids.append(CommonConfigManager.shared.config.support_jid)
                    let basePredicate = NSPredicate(
                        format: "isArchived == %@ AND owner IN %@ AND (conversationType_ == %@ OR jid IN %@) AND unread > %@",
                        argumentArray: [
                            false,
                            Array(enabledAccounts.value),
                            lockedType.rawValue,
                            excludedJids,
                            0
                        ]
                    )
                    let unreadedJidsNew = Array(Set(realm
                        .objects(LastChatsStorageItem.self)
                        .filter(basePredicate)
                        .compactMap({ return $0.jid })))
                    self.unreadedJids.append(contentsOf: unreadedJidsNew)
                    self.unreadedJids = Array(Set(self.unreadedJids))
                    print(unreadedJids)
                    predicate = NSPredicate(
                        format: "isArchived == %@ AND owner IN %@ AND (conversationType_ == %@ OR jid IN %@) AND (unread > %@ OR jid IN %@)",
                        argumentArray: [
                            false,
                            Array(enabledAccounts.value),
                            lockedType.rawValue,
                            excludedJids,
                            0,
                            unreadedJids
                        ]
                    )
                } else {
                    let basePredicate = NSPredicate(format: "isArchived == %@ AND unread > %@ AND owner IN %@",
                                                    argumentArray: [false,
                                                                    0,
                                                                    Array(enabledAccounts.value)])
                    let unreadedJidsNew = Array(Set(realm
                        .objects(LastChatsStorageItem.self)
                        .filter(basePredicate)
                        .compactMap({ return $0.jid })))
                    self.unreadedJids.append(contentsOf: unreadedJidsNew)
                    self.unreadedJids = Array(Set(self.unreadedJids))
                    predicate = NSPredicate(
                        format: "isArchived == %@ AND (unread > %@ OR jid IN %@) AND owner IN %@",
                        argumentArray: [false,
                                        0,
                                        unreadedJids,
                                        Array(enabledAccounts.value)
                                       ]
                    )
                    
                }
            case .archived:
                self.unreadedJids = []
                if let lockedType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) {
                    var excludedJids = Array(enabledAccounts.value).compactMap({XMPPJID(string: $0)!.domain})
                    excludedJids.append(CommonConfigManager.shared.config.support_jid)
                    predicate = NSPredicate(
                        format: "isArchived == %@ AND owner IN %@ AND (conversationType_ == %@ OR jid IN %@)",
                        argumentArray: [
                            true,
                            Array(enabledAccounts.value),
                            lockedType.rawValue,
                            excludedJids
                        ]
                    )
                } else {
                    predicate = NSPredicate(format: "isArchived == %@ AND owner IN %@", argumentArray: [true, Array(enabledAccounts.value)])
                }
            case .saved:
                predicate = NSPredicate(format: "owner IN %@ AND conversationType_ == %@", argumentArray: [Array(enabledAccounts.value), ClientSynchronizationManager.ConversationType.saved.rawValue])
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
                
                if (XMPPJID(string: item.jid)?.isServer ?? false) && item.conversationType != .saved {
                    return nil
                }
                let blankMessageText: String = "Start messaging here".localizeString(id: "chat_message_start_messaging", arguments: [])
                
                let subscriptionRequest: Bool = item.rosterItem?.isThereSubscriptionRequest() ?? false
                
                let primaryResource = item.rosterItem?.getPrimaryResource()
                
                let date = item.messageDate == Date(timeIntervalSince1970: 0) ? nil : item.messageDate
                
                var message: String
                
                if let lastMessage = item.lastMessage {
                    message = lastMessage.displayedBody(entity: primaryResource?.entity ?? .contact)
                    if message.isEmpty {
                        message = blankMessageText
                    }
                    if lastMessage.isDeleted {
                        message = blankMessageText
                    }
                } else if item.conversationType == .saved {
                    let usersCount = AccountManager.shared.users.count
                    message = usersCount > 1 ? item.owner : "Save messages here"
                } else {
                    message = blankMessageText
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
                if item.lastMessage == nil && item.messagesCount == 0 {
                    isSystemMessage = true
                }
                
                let username = item.rosterItem?.displayName ?? item.jid
                var attributedUsername: NSAttributedString? = nil
                
                var isVerificationActionRequired: Bool = false
                                
                if [.omemo, .omemo1, .axolotl].contains(item.conversationType) {
                    let attributedTitle: NSMutableAttributedString = NSMutableAttributedString()
                    let indicatorAttach = NSTextAttachment()
                    var color: UIColor = .label
                    do {
                        let realm = try WRealm.safe()
                        let collectionJid = realm
                            .objects(SignalDeviceStorageItem.self)
                            .filter("jid == %@ AND owner == %@", item.jid, item.owner)
                        if collectionJid.count == 0 {
                            color = .secondaryLabel
                            indicatorAttach.image = UIImage(systemName: "lock.fill")?.withTintColor(.secondaryLabel)
                            attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                        } else if collectionJid.toArray().filter({ $0.state == .fingerprintChanged || $0.state == .revoked }).count > 0 {
                            color = .systemRed
                            indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemRed)
                            attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                        } else if collectionJid.toArray().filter({ $0.state != .trusted }).count > 0 {
                            color = .systemOrange
                            indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemOrange)
                            attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                        } else if collectionJid.toArray().filter({ $0.isTrustedByCertificate }).count > 0 {
                            color = .systemGreen
                            indicatorAttach.image = UIImage(systemName: "lock.circle.fill")?.withTintColor(.systemGreen)
                            attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                        } else {
                            color = .systemGreen
                            indicatorAttach.image = UIImage(systemName: "lock.fill")?.withTintColor(.systemGreen)
                            attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                        }
                        
                        let verificationInstance = realm.objects(VerificationSessionStorageItem.self).filter("owner == %@ AND jid == %@", item.owner, item.jid).first
                        if verificationInstance != nil &&
                            [.receivedRequest, .receivedRequestAccept].contains((verificationInstance! as VerificationSessionStorageItem).state) {
                           isVerificationActionRequired = true
                        }
                        
                    } catch {
                        DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
                    }
                    
                    attributedTitle.append(NSAttributedString(string: username, attributes: [
                        .foregroundColor: color,
                        .font: UIFont.systemFont(ofSize: 17, weight: .medium)
                    ]))
                    attributedUsername = attributedTitle as NSAttributedString
                }
                return Datasource(
                    jid: item.jid,
                    owner: item.owner,
                    username: username,
                    attributedUsername: attributedUsername,
                    message: message,
                    date: date,
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
                    isVerificationActionRequired: isVerificationActionRequired
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
        self.canUpdateDataset = false
        if showSkeleton.value {
            self.canUpdateDataset = false
            self.datasource = self.mapDataset()
            self.tableView.reloadData()
            self.canUpdateDataset = true
            return
        }
        self.updateQueue.sync {
            let newDataset = self.mapDataset()
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
            let predicate = NSPredicate(
                format: "isArchived == %@ AND unread > %@ AND owner IN %@",
                argumentArray: [
                    false,
                    0,
                    Array(enabledAccounts.value)
                ]
            )
            let unreadCollection = realm.objects(LastChatsStorageItem.self).filter(predicate)
            Observable
                .collection(from: unreadCollection)
                .debounce(.microseconds(50), scheduler: MainScheduler.asyncInstance)
                .subscribe { results in
                    self.bottomBar.leftButton.isEnabled = results.count > 0
                } onError: { _ in
                    
                } onCompleted: {
                    
                } onDisposed: {
                    
                }.disposed(by: bag)

            
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
                        image:  imageLiteral( "buffer160")?.withRenderingMode(.alwaysTemplate),
                        title: "Chats list is empty".localizeString(id: "chats_list_is_empty", arguments: []),
                        subtitle: "Try to start a new chat".localizeString(id: "try_to_start_new_chat", arguments: []),
                        buttonTitle: "Start new chat".localizeString(id: "start_new_chat", arguments: [])
                    )
                    break
                case .unread:
                    self.emptyView.update(
                        image:  imageLiteral( "buffer160")?.withRenderingMode(.alwaysTemplate),
                        title: "No unread chats".localizeString(id: "unreaded_chats_list_empty", arguments: []),
                        subtitle: " ",
                        buttonTitle: " "
                    )
                    break
                case .archived:
                    self.emptyView.update(
                        image:  imageLiteral( "buffer160")?.withRenderingMode(.alwaysTemplate),
                        title: "Your archived chats list is empty".localizeString(id: "archived_chats_list_empty", arguments: []),
                        subtitle: " ",
                        buttonTitle: " "
                    )
                    break
                default:
                    break
                }
                self.updateDatasource(value)
                self.updateTitle(value)
                self.bottomBar.leftButton.setImage(imageLiteral(self.filter.value == .unread ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")?.upscale(dimension: 24).withRenderingMode(.alwaysTemplate), for: .normal)
                do {
                    try self.updateBottomTitle()
                } catch {
                    DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
                }
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
        self.restorationIdentifier = "LastChatsViewController"
        self.restoresFocusAfterTransition = true
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        
//        tableView.backgroundColor = .clear
        
        
        emptyView.configure(image: imageLiteral( "buffer160")?.withRenderingMode(.alwaysTemplate),
                            title: "Chats list is empty".localizeString(id: "chats_list_is_empty", arguments: []),
                            subtitle: "Try to start a new chat".localizeString(id: "try_to_start_new_chat", arguments: []),
                            buttonTitle: "Start new chat".localizeString(id: "start_new_chat", arguments: [])) {
            let vc = CreateNewEntityViewController()
            showModal(vc)
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
                self.unreadAllMessagesButton.backgroundColor = AccountManager.shared.connectingUsers.value.isNotEmpty ? MDCPalette.grey.tint500 : AccountColorManager.shared.topPalette().tint500
            }
            
            
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
        }
//        configureNavbar()
    }
    
    @objc
    private func onSidebarButtonTouchUp(_ sender: UIBarButtonItem) {
        self.splitViewController?.show(.primary)
    }
    
    open var shouldShowBottomBar: Bool = true
    
    internal func configureBars() {
        self.title = "Chats"
        self.navigationController?.navigationBar.prefersLargeTitles = true
        if #available(iOS 16.0, *) {
            self.navigationItem.preferredSearchBarPlacement = .stacked
        }
        securityButton.target = self
        securityButton.action = #selector(onRegisterYubikey)
        switch CommonConfigManager.shared.interfaceType {
            case .tabs:
                let addBarButton = UIBarButtonItem(
                    image: UIImage(systemName: "plus")?
                        .upscale(dimension: 24)
                        .withRenderingMode(.alwaysTemplate),
                    style: .done,
                    target: self,
                    action: #selector(onAddButtonTouchUpInside)
                )
                let filterButton = UIBarButtonItem(
                    image: imageLiteral("line.3.horizontal.decrease.circle")?
                        .upscale(dimension: 24)
                        .withRenderingMode(.alwaysTemplate),
                    style: .done,
                    target: self,
                    action: #selector(onFilterButtonTouchUpInside)
                )
                if CommonConfigManager.shared.config.use_yubikey {
                    self.navigationItem.setRightBarButtonItems([filterButton, addBarButton, securityButton], animated: true)
                } else {
                    self.navigationItem.setRightBarButtonItems([filterButton, addBarButton], animated: true)
                }
                let leftBarButton = UIBarButtonItem(customView: accountNavButton)
//                leftBarButton.target = self
//                leftBarButton.action = #selector(showSettings)
                self.navigationItem.setLeftBarButton(leftBarButton, animated: true)
                accountNavButton.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
            case .split:
                self.bottomBar.splitViewController = self.splitViewController
                self.view.addSubview(bottomBar)
                self.view.bringSubviewToFront(bottomBar)
                var inputHeight: CGFloat = 49
                if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                    inputHeight += bottomInset
                }
                
                let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
                bottomBar.updateFrame(to: frame)
                self.splitViewController?.navigationItem.setLeftBarButtonItems([], animated: true)
                
                let sidebarButton = UIBarButtonItem(image: imageLiteral("sidebar.left"), style: .plain, target: self, action: #selector(onSidebarButtonTouchUp))
                
                if UIDevice.current.userInterfaceIdiom != .pad {
                    self.navigationItem.setHidesBackButton(true, animated: false)
                    self.navigationItem.setLeftBarButton(sidebarButton, animated: true)
                }
                bottomBar.leftCallback = self.onLeftBarButtonTapped
                self.bottomBar.leftButton.setImage(imageLiteral(self.filter.value == .unread ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")?.upscale(dimension: 24).withRenderingMode(.alwaysTemplate), for: .normal)
                self.bottomBar.titleCallback = self.onTitleBarButtonTapped
                self.bottomBar.isHidden = !shouldShowBottomBar
        }
        
    }
    
    var normalState: Filter = .chats
    
    func onTitleBarButtonTapped() {
        if self.filter.value == .unread {
            do {
                let realm = try  WRealm.safe()
                let collection = realm
                    .objects(LastChatsStorageItem.self)
                    .filter("isArchived == false AND unread > 0 AND owner IN %@", Array(self.enabledAccounts.value))
                    .sorted(byKeyPath: "messageDate", ascending: false)

                try realm.write {
                    collection.forEach { $0.unread = 0 }
                }
                self.enabledAccounts.value.forEach {
                    AccountManager.shared.find(for: $0)?.unsafeAction({ user, stream in
                        user.messages.readAllMessages()
                    })
                }
                self.canUpdateDataset = true
                self.runDatasetUpdateTask()
            } catch {
                DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
            }
            self.filter.accept(normalState)
        }
    }
    
    func updateBottomTitle() {
        var title = ""
        switch self.filter.value {
            case .archived:
                title = CommonConfigManager.shared.config.app_name
                bottomBar.titleButton.setTitleColor(.label, for: .normal)
            case .unread:
                title = "Mark all as read".localizeString(id: "mark_all_as_read_button", arguments: [])
                bottomBar.titleButton.setTitleColor(.systemBlue, for: .normal)
            case .chats:
                title = CommonConfigManager.shared.config.app_name
                bottomBar.titleButton.setTitleColor(.label, for: .normal)
        case .saved:
            bottomBar.isHidden = true
        }
        bottomBar.titleButton.setTitle(title, for: .normal)
    }
    
    @objc
    func showSettings(_ sender: AnyObject) {
        let vc = SettingsViewController()
        vc.jid = AccountManager.shared.users.first?.jid ?? ""
        vc.owner = AccountManager.shared.users.first?.jid ?? ""
        showModal(vc)
    }
    
    @objc
    func onAddButtonTouchUpInside(_ sender: AnyObject) {
        let vc = CreateNewEntityViewController()
        showModal(vc)
    }
    
    @objc
    func onFilterButtonTouchUpInside(_ sender: AnyObject) {
        onLeftBarButtonTapped()
    }
    
    func onLeftBarButtonTapped() {
        if self.filter.value != .unread {
            self.normalState = self.filter.value
            self.filter.accept(.unread)
        } else {
            self.filter.accept(self.normalState)
        }
        self.bottomBar.leftButton.setImage(UIImage(systemName: self.filter.value == .unread ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")?.upscale(dimension: 24).withRenderingMode(.alwaysTemplate), for: .normal)
        do {
            try self.updateBottomTitle()
        } catch {
            DDLogDebug("LastChatsViewController: \(#function). \(error.localizedDescription)")
        }
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
    }
    
    override func reloadDatasource() {
        tableView.reloadData()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        searchController.isActive = false
        self.navigationItem.backButtonDisplayMode = .minimal
        self.navigationController?.navigationBar.prefersLargeTitles = true
        self.navigationController?.navigationItem.largeTitleDisplayMode = .always
//        navigationController?.setNavigationBarHidden(false, animated: true)
//        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
//        navigationController?.navigationBar.shadowImage = nil
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
        configureBars()
//        self.navigationController?.navigationBar.prefersLargeTitles = true
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateTitle(filter.value)
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
