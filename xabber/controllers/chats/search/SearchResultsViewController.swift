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
import RxCocoa
import RxSwift
import DeepDiff
import XMPPFramework
import XMPPFramework.XMPPJID
import CocoaLumberjack

class SearchResultsViewController: SimpleBaseViewController {
    
    struct Section {
        enum Kind {
            case contacts
            case groups
            case messages
        }
        
        let header: String
        let footer: String
        let kind: Kind
    }

    static var searchPlaceholderText: String {
        "Search messages, contacts and groups".localizeString(id: "search_messages_contacts_groups", arguments: [])
    }

    static func makeSections(hasContacts: Bool, hasGroups: Bool = false, hasMessages: Bool) -> [Section] {
        var sections: [Section] = []
        if hasContacts {
            sections.append(
                Section(
                    header: "Contacts".localizeString(id: "contacts", arguments: []),
                    footer: "",
                    kind: .contacts
                )
            )
        }
        if hasGroups {
            sections.append(
                Section(
                    header: "Groups".localizeString(id: "channel_group_chat_title", arguments: []),
                    footer: "",
                    kind: .groups
                )
            )
        }
        if hasMessages {
            sections.append(
                Section(
                    header: "Messages".localizeString(id: "groupchat_member_messages", arguments: []),
                    footer: "",
                    kind: .messages
                )
            )
        }
        return sections
    }

    internal func updateSections() {
        sections = Self.makeSections(
            hasContacts: chatsDatasource.isNotEmpty,
            hasGroups: groupsDatasource.isNotEmpty,
            hasMessages: messagesDatasource.isNotEmpty
        )
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
        let hasUnreadMention: Bool
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
        let messageArchiveId: String?
        
        static func compareContent(_ a: Datasource, _ b: Datasource) -> Bool {
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
                    && a.hasUnreadMention == b.hasUnreadMention
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
                    && a.messageArchiveId == b.messageArchiveId
        }
    }
    
    var chatsDatasource: [Datasource] = []
    var groupsDatasource: [Datasource] = []
    var messagesDatasource: [Datasource] = []
    
    var isLoadingDone: Bool = true
    
    struct SearchRequest: Hashable, Equatable {
        let owner: String
        let queryId: String
    }
    
    internal var sections: [Section] = []
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .insetGrouped)

        view.register(ChatListTableViewCell.self, forCellReuseIdentifier: ChatListTableViewCell.cellName)
        view.contentInsetAdjustmentBehavior = .scrollableAxes
        
        view.keyboardDismissMode = .interactive
        
        return view
    }()
    
    
    
//    open var delegate: SearchResultsDelegateProtocol? = nil
    
    open weak var presenter: UIViewController? = nil
    
//    internal func updateSearchResults(with text: String) {
//
//    }
    
    internal func subscribeDataset() {

    }
    
    internal var searchObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
        
    internal var searchTextObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    internal var searchResultsObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    internal var currentQueries: Set<SearchRequest> = Set()
    
    internal var messagesQueue: [MessageStorageItem] = []
    
    internal var currentVc: ChatViewController? = nil
    
    internal lazy var enabledAccounts: [String] = {
        do {
            let realm = try WRealm.safe()
            return realm
                .objects(AccountStorageItem.self)
                .filter("enabled == %@", true)
                .compactMap { $0.jid }
        } catch {
            return []
        }
    }()
    
    override func subscribe() {
        super.subscribe()
        self.searchObserver
            .asObservable()
            .distinctUntilChanged()
            .debounce(.milliseconds(250), scheduler: MainScheduler.asyncInstance)
            .subscribe { searchText in
                self.updateDatasource(searchText)
            } onError: { _ in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }.disposed(by: self.bag)

    }
    
    private final func registerSearchRequest(owner: String, queryId: String) {
        let registration = { [weak self] in
            guard let self else { return }
            guard queryId.isNotEmpty else {
                if self.currentQueries.isEmpty {
                    self.isLoadingDone = true
                }
                return
            }

            let request = SearchRequest(owner: owner, queryId: queryId)
            self.currentQueries.insert(request)
            self.isLoadingDone = false
        }
        if Thread.isMainThread {
            registration()
        } else {
            DispatchQueue.main.sync(execute: registration)
        }
    }

    private final func searchForAccount(_ owner: String, search text: String, withUIStream: Bool) {
        guard text.isNotEmpty else { return }
        do {
            let realm = try WRealm.safe()
            realm
                .objects(MessageStorageItem.self)
                .filter(
                    "owner == %@ AND isDeleted == false AND messageType != %@ AND body CONTAINS[cd] %@",
                    owner,
                    MessageStorageItem.MessageDisplayType.system.rawValue,
                    text
                )
                .sorted(byKeyPath: "date", ascending: false)
                .toArray()
                .forEach {
                    item in
                    self.messagesQueue.append(item)
            }
            if withUIStream {
                let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                    onMessage: { [weak self] item, queryId in
                        self?.didReceiveMessage(item, queryId: queryId)
                    },
                    onEndPage: { [weak self] queryId, state, first, last, count in
                        self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                    }
                )
                XMPPUIActionManager.shared.performRequest(owner: owner) { stream, session in
                    let queryId = session.mam?.searchText(
                        stream,
                        conversationType: .regular,
                        text: text,
                        max: 100,
                        loadFull: false,
                        requestCallbacks: requestCallbacks
                    ) ?? ""
                    self.registerSearchRequest(owner: owner, queryId: queryId)
                } fail: {
                    AccountManager.shared.find(for: owner)?.action({ user, stream in
                        let queryId = user.mam.searchText(
                            stream,
                            conversationType: .regular,
                            text: text,
                            max: 100,
                            loadFull: false,
                            requestCallbacks: requestCallbacks
                        )
                        self.registerSearchRequest(owner: owner, queryId: queryId)
                    })
                }
            } else {
                let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                    onMessage: { [weak self] item, queryId in
                        self?.didReceiveMessage(item, queryId: queryId)
                    },
                    onEndPage: { [weak self] queryId, state, first, last, count in
                        self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                    }
                )
                AccountManager.shared.find(for: owner)?.action({ user, stream in
                    let queryId = user.mam.searchText(
                        stream,
                        conversationType: .regular,
                        text: text,
                        max: 100,
                        loadFull: false,
                        requestCallbacks: requestCallbacks
                    )
                    self.registerSearchRequest(owner: owner, queryId: queryId)
                })
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal final func updateMessagesSearchResults() throws {
        self.messagesDatasource = try self.messagesQueue.sorted(by: { $0.date > $1.date }).compactMap { messageItem -> Datasource? in
            
            let realm = try WRealm.safe()
            guard let item = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: messageItem.opponent, owner: messageItem.owner, conversationType: messageItem.conversationType)) else {
                return nil
            }
            
            if (XMPPJID(string: item.jid)?.isServer ?? false) && item.conversationType != .saved {
                return nil
            }
                       
            let date = messageItem.date
            
            var message: String = messageItem.body
            
            var isAttachment: Bool = [
                MessageStorageItem.MessageDisplayType.sticker,
                MessageStorageItem.MessageDisplayType.call].contains(messageItem.displayAs)
            if !isAttachment,
               let authMessageMetadata = messageItem.systemMetadata?["auth_message"] as? Bool,
               authMessageMetadata {
                isAttachment = true
            }
            
            let isInvite = false//item.unread > 0 ? (messageItem.displayAs  == .initial ? true : false) : false
            
            var nickname: String? = nil//messageItem.groupchatDisplayedNickname
//            if messageItem.inlineForwards.isNotEmpty {
//                let sender = messageItem.inlineForwards.first
//                var nick = sender?.forwardNickname
//                if nick == "" || nick == nil {
//                    nick = String(JidManager.shared.prepareJid(jid: sender?.forwardJid ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])))
//                }
//                switch messageItem.inlineForwards.first?.kind {
//                case .text:
//                    nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])): \(messageItem.inlineForwards.first?.body ?? "")"
//                case .images:
//                    nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " image".localizeString(id: "forward_image", arguments: [])
//                case .videos:
//                    nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " video".localizeString(id: "forward_video", arguments: [])
//                case .files:
//                    nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " file".localizeString(id: "forward_file", arguments: [])
//                case .voice:
//                    nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " voice message".localizeString(id: "forward_voice", arguments: [])
//                case .quote:
//                    nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])): \(messageItem.inlineForwards.first?.body ?? "")"
//                case .none:
//                    nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: []))"
//                }
//            }
            
            var isSystemMessage: Bool = [.system].contains(messageItem.displayAs)
            if item.isFreshNotEmptyEncryptedChat {
                message = "Write your encrypted messages here"
                isSystemMessage = true
            }
            
            let username = messageItem.outgoing ? AccountManager.shared.find(for: messageItem.owner)?.username ?? messageItem.opponent : item.rosterItem?.displayName ?? item.jid
            var attributedUsername: NSAttributedString? = nil
            
                            
            if item.conversationType.isEncrypted {
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
                    } else if collectionJid.contains(where: { $0.state == .fingerprintChanged || $0.state == .revoked }) {
                        color = .systemRed
                        indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemRed)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    } else if collectionJid.contains(where: { $0.state != .trusted }) {
                        color = .systemOrange
                        indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemOrange)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    } else if collectionJid.contains(where: { $0.isTrustedByCertificate }) {
                        color = .systemGreen
                        indicatorAttach.image = UIImage(systemName: "lock.circle.fill")?.withTintColor(.systemGreen)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    } else {
                        color = .systemGreen
                        indicatorAttach.image = UIImage(systemName: "lock.fill")?.withTintColor(.systemGreen)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
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
                jid: messageItem.opponent,//item.jid,
                owner: messageItem.owner,
                username: username,
                attributedUsername: attributedUsername,
                message: message,
                date: date,
                state: messageItem.outgoing ? messageItem.state : nil,
                isMute: false,
                isSynced: false,
                status: .offline,//primaryResource?.status ?? .offline,
                entity: .contact,
                conversationType: item.conversationType,
                unread: 0,//messageItem.outgoing ? 0 : item.unread,
                unreadString: isInvite ? "1" : nil,
                hasUnreadMention: item.hasUnreadMention,
                color: AccountManager.shared.users.count <= 1 ? .clear : AccountColorManager.shared.primaryColor(for: item.owner),
                isDraft: false,
                hasAttachment: isAttachment,
                userNickname: nickname,
                isSystemMessage: isSystemMessage,
                isPinned: false,
                subRequest: false,//(XMPPJID(string: item.jid)?.isServer ?? true) ? false :  subscriptionRequest,
                isEncrypted: item.conversationType.isEncrypted,
                avatarUrl: item.rosterItem?.avatarUrl,
                hasErrorInChat: false,
                updateTS: item.updateTS,
                isVerificationActionRequired: false,
                messageArchiveId: messageItem.archivedId
            )
        }
        self.updateSections()
        self.tableView.reloadData()
    }
    
    private func updateDatasource(_ searchText: String?) {
        do {
            self.chatsDatasource = []
            let realm = try WRealm.safe()
            guard let searchText = searchText else {
                return
            }
            let chats = realm
                .objects(LastChatsStorageItem.self)
                .filter("owner IN %@ AND (jid CONTAINS[cd] %@ OR rosterItem.customUsername CONTAINS[cd] %@ OR rosterItem.username CONTAINS[cd] %@)", enabledAccounts, searchText, searchText, searchText)
                .sorted(byKeyPath: "messageDate", ascending: false)
            let roster = realm
                .objects(RosterStorageItem.self)
                .filter("owner IN %@ AND (jid CONTAINS[cd] %@ OR customUsername CONTAINS[cd] %@ OR username CONTAINS[cd] %@)", enabledAccounts, searchText, searchText, searchText)
                .sorted(byKeyPath: "jid", ascending: true)
            let jids = Set(self.chatsDatasource.compactMap { return [$0.owner, $0.jid].prp() })
            self.chatsDatasource = chats.compactMap { item -> Datasource? in
                // TODO: fixme
                if (XMPPJID(string: item.jid)?.isServer ?? false) && item.conversationType != .saved {
                    return nil
                }
                let blankMessageText: String = "Start messaging here".localizeString(id: "chat_message_start_messaging", arguments: [])
                
                let subscriptionRequest: Bool = item.rosterItem?.isThereSubscriptionRequest() ?? false
                
                let primaryResource = item.rosterItem?.getPrimaryResource()
                
                let date = item.messageDate == Date(timeIntervalSince1970: 0) ? nil : item.messageDate
                
                var message: String
                
                if let lastMessage = item.lastMessage {
                    message = lastMessage.displayedBody()
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
                    MessageStorageItem.MessageDisplayType.call].contains(item.lastMessage?.displayAs ?? .text)
                if !isAttachment,
                   let authMessageMetadata = item.lastMessage?.systemMetadata?["auth_message"] as? Bool,
                   authMessageMetadata {
                    isAttachment = true
                }
                
                let isInvite = false//item.unread > 0 ? ((item.lastMessage?.displayAs ?? .text) == .initial ? true : false) : false
                
                var nickname: String? = item.lastMessage?.groupchatDisplayedNickname
//                if item.lastMessage?.inlineForwards.isNotEmpty ?? false {
//                    let sender = item.lastMessage?.inlineForwards.first
//                    var nick = sender?.forwardNickname
//                    if nick == "" || nick == nil {
//                        nick = String(JidManager.shared.prepareJid(jid: sender?.forwardJid ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])))
//                    }
//                    switch item.lastMessage?.inlineForwards.first?.kind {
//                    case .text:
//                        nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])): \(item.lastMessage?.inlineForwards.first?.body ?? "")"
//                    case .images:
//                        nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " image".localizeString(id: "forward_image", arguments: [])
//                    case .videos:
//                        nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " video".localizeString(id: "forward_video", arguments: [])
//                    case .files:
//                        nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " file".localizeString(id: "forward_file", arguments: [])
//                    case .voice:
//                        nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " voice message".localizeString(id: "forward_voice", arguments: [])
//                    case .quote:
//                        nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])): \(item.lastMessage?.inlineForwards.first?.body ?? "")"
//                    case .none:
//                        nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: []))"
//                    }
//                }
                
                var isSystemMessage: Bool = [.system].contains(item.lastMessage?.displayAs ?? .text)
                if item.isFreshNotEmptyEncryptedChat {
                    message = "Write your encrypted messages here"
                    isSystemMessage = true
                }
                if item.lastMessage == nil {
                    isSystemMessage = true
                }
                
                let username = item.rosterItem?.displayName ?? item.jid
                var attributedUsername: NSAttributedString? = nil
                
                var isVerificationActionRequired: Bool = false
                                
                if item.conversationType.isEncrypted {
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
                        } else if collectionJid.contains(where: { $0.state == .fingerprintChanged || $0.state == .revoked }) {
                            color = .systemRed
                            indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemRed)
                            attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                        } else if collectionJid.contains(where: { $0.state != .trusted }) {
                            color = .systemOrange
                            indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemOrange)
                            attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                        } else if collectionJid.contains(where: { $0.isTrustedByCertificate }) {
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
                    hasUnreadMention: item.hasUnreadMention,
                    color: AccountManager.shared.users.count <= 1 ? .clear : AccountColorManager.shared.primaryColor(for: item.owner),
                    isDraft: isDraft,
                    hasAttachment: isAttachment,
                    userNickname: nickname,
                    isSystemMessage: isSystemMessage,
                    isPinned: item.isPinned,
                    subRequest: (XMPPJID(string: item.jid)?.isServer ?? true) ? false :  subscriptionRequest,
                    isEncrypted: item.conversationType.isEncrypted,
                    avatarUrl: item.rosterItem?.avatarMinUrl ?? item.rosterItem?.avatarMaxUrl ?? item.rosterItem?.oldschoolAvatarKey,
                    hasErrorInChat: item.hasErrorInChat,
                    updateTS: item.updateTS,
                    isVerificationActionRequired: isVerificationActionRequired,
                    messageArchiveId: nil
                )
            }
            
            self.chatsDatasource.append(contentsOf: roster.compactMap({ item -> Datasource? in
                if jids.contains([item.owner, item.jid].prp()) { return nil }
                let primaryResource = item.getPrimaryResource()
                return Datasource(
                    jid: item.jid,
                    owner: item.owner,
                    username: item.displayName,
                    attributedUsername: nil,
                    message: "Start messaging here".localizeString(id: "chat_message_start_messaging", arguments: []),
                    date: nil,
                    state: nil,
                    isMute: false,
                    isSynced: true,
                    status: primaryResource?.status ?? .offline,
                    entity: primaryResource?.entity ?? .contact,
                    conversationType: ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular,
                    unread: 0,
                    unreadString: nil,
                    hasUnreadMention: false,
                    color: AccountManager.shared.users.count <= 1 ? .clear : AccountColorManager.shared.primaryColor(for: item.owner),
                    isDraft: false,
                    hasAttachment: false,
                    userNickname: nil,
                    isSystemMessage: true,
                    isPinned: false,
                    subRequest: false,
                    isEncrypted: (ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular).isEncrypted,
                    avatarUrl: item.avatarUrl,
                    hasErrorInChat: false,
                    updateTS: 0,
                    isVerificationActionRequired: false,
                    messageArchiveId: nil
                )
            }))
            self.messagesDatasource = []
            self.messagesQueue = []
            self.isLoadingDone = false
            self.currentQueries = Set()
            self.updateSections()
            if self.enabledAccounts.count == 1 {
                if let jid = enabledAccounts.first {
                    self.searchForAccount(jid, search: searchText, withUIStream: true)
                }
            } else {
                self.enabledAccounts.forEach {
                    self.searchForAccount($0, search: searchText, withUIStream: true)
                }
            }
            self.tableView.reloadData()
        } catch {
            DDLogDebug("SearchResultsViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    
    override func configure() {
        super.configure()
        ContinuousSplitBackgroundExperiment.configureTransparentColumn(self)
        tableView.applyContinuousSplitInsetGroupedAppearance()

        view.addSubview(tableView)
        tableView.fillSuperview()
        
        tableView.dataSource = self
        tableView.delegate = self
    }
}

enum InPlaceSearchHostHelper {
    static func makeSearchController(
        updater: UISearchResultsUpdating,
        placeholder: String = ChatSearchResultsController.placeholderText
    ) -> UISearchController {
        let controller = UISearchController(searchResultsController: nil)

        controller.searchResultsUpdater = updater
        controller.searchBar.searchBarStyle = .default
        controller.searchBar.placeholder = placeholder
        // Apple recommends disabling obscuring when the same controller shows content and in-place results.
        controller.obscuresBackgroundDuringPresentation = false

        return controller
    }

    static func attach(
        searchController: UISearchController,
        to viewController: UIViewController,
        updater: ChatSearchResultsController,
        searchControllerDelegate: UISearchControllerDelegate?,
        searchBarDelegate: UISearchBarDelegate?,
        reload: @escaping () -> Void
    ) {
        let isAlreadyAttached = viewController.navigationItem.searchController === searchController
        if !isAlreadyAttached {
            viewController.navigationItem.searchController = searchController
        }
        if #available(iOS 16.0, *) {
            viewController.navigationItem.preferredSearchBarPlacement = .stacked
        }
        viewController.navigationItem.hidesSearchBarWhenScrolling = true
        searchController.searchResultsUpdater = updater
        updater.onSnapshotChanged = reload
        searchController.delegate = searchControllerDelegate
        searchController.searchBar.delegate = searchBarDelegate
        viewController.definesPresentationContext = true
    }

    static func dismissBeforeResultRoute(
        searchController: UISearchController,
        updater: ChatSearchResultsController,
        reload: () -> Void
    ) {
        UIView.performWithoutAnimation {
            if searchController.isActive {
                searchController.isActive = false
            }
            updater.reset()
            reload()
        }
    }
}

final class EmptySearchResultsUpdater: NSObject, UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {}
}

enum BottomInPlaceSearchHostHelper {
    static func install(
        searchView: BottomSearchHostView,
        in containerView: UIView
    ) {
        guard searchView.superview == nil else {
            containerView.bringSubviewToFront(searchView)
            return
        }

        containerView.addSubview(searchView)
        NSLayoutConstraint.activate([
            searchView.leadingAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.leadingAnchor),
            searchView.trailingAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.trailingAnchor),
            searchView.bottomAnchor.constraint(
                equalTo: containerView.keyboardLayoutGuide.topAnchor,
                constant: -BottomSearchHostView.Metrics.bottomOffset
            ),
            searchView.heightAnchor.constraint(equalToConstant: BottomSearchHostView.Metrics.height)
        ])
        containerView.bringSubviewToFront(searchView)
    }

    static func configure(
        searchView: BottomSearchHostView,
        updater: ChatSearchResultsController,
        placeholder: String = ChatSearchResultsController.placeholderText,
        reload: @escaping () -> Void,
        activeChanged: @escaping (Bool) -> Void
    ) {
        searchView.searchTextField.placeholder = placeholder
        updater.onSnapshotChanged = reload
        searchView.onTransitionPhaseChanged = { [weak searchView] _ in
            guard let searchView else { return }
            activeChanged(searchView.isExpanded)
        }
        searchView.onBegin = { [weak searchView, weak updater] in
            guard let searchView, let updater else { return }
            updater.updateSearchResults(with: searchView.query)
            reload()
        }
        searchView.onQueryChanged = { [weak updater] text in
            guard let updater else { return }
            updater.updateSearchResults(with: text)
            reload()
        }
        searchView.onCancel = { [weak updater] in
            guard let updater else { return }
            updater.reset()
            reload()
        }
    }

    static func shouldShowResults(
        searchView: BottomSearchHostView,
        updater: ChatSearchResultsController
    ) -> Bool {
        updater.shouldShowResults(
            isActive: searchView.isExpanded,
            query: searchView.query
        )
    }

    static func dismiss(
        searchView: BottomSearchHostView,
        updater: ChatSearchResultsController,
        reload: () -> Void,
        activeChanged: (Bool) -> Void
    ) {
        UIView.performWithoutAnimation {
            searchView.setQuery("", notify: false)
            searchView.setExpanded(false, animated: false)
            updater.reset()
            activeChanged(false)
            reload()
        }
    }
}

enum SearchResultOpenRequestFactory {
    static func request(for item: SearchResultsViewController.Datasource) -> ChatOpenMessageRequest? {
        guard let archivedId = item.messageArchiveId,
              archivedId.isNotEmpty else {
            return nil
        }

        return ChatOpenMessageRequest(
            chatJid: item.jid,
            owner: item.owner,
            conversationType: item.conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: archivedId,
                messageId: nil,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: item.date ?? Date()
            ),
            highlight: true,
            markReadOnVisible: true,
            source: .search
        )
    }
}

enum SearchRemoteQueryCompletionPolicy {
    typealias SearchRequest = SearchResultsViewController.SearchRequest

    struct EndPageDecision: Equatable {
        let remainingQueries: Set<SearchRequest>
        let isStale: Bool
        let isLoadingDone: Bool
    }

    static func endPageDecision(
        queryId: String,
        currentQueries: Set<SearchRequest>
    ) -> EndPageDecision {
        guard currentQueries.contains(where: { $0.queryId == queryId }) else {
            return EndPageDecision(
                remainingQueries: currentQueries,
                isStale: true,
                isLoadingDone: currentQueries.isEmpty
            )
        }

        let remainingQueries = currentQueries.filter { $0.queryId != queryId }
        return EndPageDecision(
            remainingQueries: remainingQueries,
            isStale: false,
            isLoadingDone: remainingQueries.isEmpty
        )
    }

    static func shouldAcceptMessage(
        queryId: String,
        currentQueries: Set<SearchRequest>
    ) -> Bool {
        currentQueries.contains(where: { $0.queryId == queryId })
    }
}

enum InPlaceSearchResultRouteHelper {
    typealias OpenNewChat = (
        _ item: SearchResultsViewController.Datasource,
        _ openMessageRequest: ChatOpenMessageRequest?,
        _ completion: @escaping (ChatViewController?) -> Void
    ) -> Void

    static func open(
        _ item: SearchResultsViewController.Datasource,
        updater: ChatSearchResultsController,
        dismissSearch: @escaping () -> Void,
        reload: @escaping () -> Void,
        openNewChat: OpenNewChat
    ) {
        dismissSearch()

        if let vc = updater.currentVc,
           vc.jid == item.jid,
           vc.owner == item.owner,
           vc.conversationType == item.conversationType {
            showArchiveJumpIfNeeded(for: item, in: vc)
            return
        }

        let openMessageRequest = SearchResultOpenRequestFactory.request(for: item)
        openNewChat(item, openMessageRequest) { chatVc in
            guard let chatVc else { return }
            updater.currentVc = chatVc
        }
    }

    private static func showArchiveJumpIfNeeded(
        for item: SearchResultsViewController.Datasource,
        in chatViewController: ChatViewController
    ) {
        guard let request = SearchResultOpenRequestFactory.request(for: item) else { return }
        chatViewController.queueOpenMessageRequest(
            request,
            hooks: ChatAnchorExecutionHooks(
                direction: .up,
                animatedScroll: true,
                onFailed: {},
                onPositioned: nil
            )
        )
    }
}

final class ChatSearchResultsController: NSObject, UISearchResultsUpdating, TemporaryMessageReceiverProtocol {
    typealias Section = SearchResultsViewController.Section
    typealias Datasource = SearchResultsViewController.Datasource
    typealias SearchRequest = SearchResultsViewController.SearchRequest

    static var placeholderText: String {
        SearchResultsViewController.searchPlaceholderText
    }

    internal var chatsDatasource: [Datasource] = []
    internal var groupsDatasource: [Datasource] = []
    internal var messagesDatasource: [Datasource] = []
    internal var isLoadingDone: Bool = true
    internal var sections: [Section] = []
    internal weak var currentVc: ChatViewController?
    internal var onSnapshotChanged: (() -> Void)?

    private let bag = DisposeBag()
    private let searchObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    private var usesInjectedSnapshot: Bool = false
    private var activeInputQuery: String?
    private var pipeline = LastChatsSearchPipeline()
    private var localPageCancellations: [LastChatsSearchProviderID: LastChatsSearchCancellationToken] = [:]
    private var presentationByStableID: [String: (revision: UInt64, datasource: Datasource)] = [:]

    private struct RemotePageContext {
        let request: LastChatsSearchPageRequest
        var items: [LastChatsSearchItem]
    }

    private var remotePagesByQueryID: [String: RemotePageContext] = [:]

    internal lazy var enabledAccounts: [String] = {
        do {
            let realm = try WRealm.safe()
            return realm
                .objects(AccountStorageItem.self)
                .filter("enabled == %@", true)
                .compactMap { $0.jid }
        } catch {
            return []
        }
    }()

    override init() {
        super.init()
        subscribe()
    }

    func updateSearchResults(for searchController: UISearchController) {
        updateSearchResults(with: searchController.searchBar.text)
    }

    internal func updateSearchResults(with text: String?) {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if activeInputQuery != normalized {
            cancelActiveSearch(clearPresentation: normalized.isEmpty)
            activeInputQuery = normalized.isEmpty ? nil : normalized
        }
        searchObserver.accept(text)

        guard text?.isEmpty ?? true else { return }
        reset()
    }

    internal func shouldShowResults(for searchController: UISearchController) -> Bool {
        shouldShowResults(
            isActive: searchController.isActive,
            query: searchController.searchBar.text
        )
    }

    internal func shouldShowResults(isActive: Bool, query: String?) -> Bool {
        (isActive || usesInjectedSnapshot)
            && (query?.isNotEmpty ?? false)
    }

    internal func reset() {
        cancelActiveSearch(clearPresentation: true)
        activeInputQuery = nil
        usesInjectedSnapshot = false
        chatsDatasource = []
        groupsDatasource = []
        messagesDatasource = []
        sections = []
        isLoadingDone = true
        onSnapshotChanged?()
    }

    internal func replaceSnapshot(
        chats: [Datasource] = [],
        groups: [Datasource] = [],
        messages: [Datasource] = [],
        isLoadingDone: Bool = true
    ) {
        cancelActiveSearch(clearPresentation: true)
        usesInjectedSnapshot = true
        chatsDatasource = chats
        groupsDatasource = groups
        messagesDatasource = messages
        self.isLoadingDone = isLoadingDone
        updateSections()
        onSnapshotChanged?()
    }

    internal func numberOfSections() -> Int {
        sections.count
    }

    internal func numberOfRows(in section: Int) -> Int {
        guard sections.indices.contains(section) else { return 0 }
        switch sections[section].kind {
        case .contacts:
            return chatsDatasource.count
        case .groups:
            return groupsDatasource.count
        case .messages:
            return messagesDatasource.count
        }
    }

    internal func titleForHeader(in section: Int) -> String? {
        guard sections.indices.contains(section) else { return nil }
        return sections[section].header
    }

    internal func item(at indexPath: IndexPath) -> Datasource? {
        guard sections.indices.contains(indexPath.section) else { return nil }
        switch sections[indexPath.section].kind {
        case .contacts:
            guard chatsDatasource.indices.contains(indexPath.row) else {
                return nil
            }
            return chatsDatasource[indexPath.row]
        case .groups:
            guard groupsDatasource.indices.contains(indexPath.row) else {
                return nil
            }
            return groupsDatasource[indexPath.row]
        case .messages:
            guard messagesDatasource.indices.contains(indexPath.row) else {
                return nil
            }
            return messagesDatasource[indexPath.row]
        }
    }

    internal func configureSearchResultCell(_ cell: ChatListTableViewCell, at indexPath: IndexPath) {
        guard let item = item(at: indexPath) else { return }
        configureSearchResultCell(cell, with: item)
    }

    internal func configureSearchResultCell(_ cell: ChatListTableViewCell, with item: Datasource) {
        cell.configure(
            item.jid,
            owner: item.owner,
            username: item.username,
            attributedUsername: item.attributedUsername,
            message: item.message,
            date: item.date,
            deliveryState: item.state,
            isMute: item.isMute,
            isSynced: item.isSynced,
            isGroupchat: [.groupchat, .incognitoChat].contains(item.entity),
            status: item.status,
            entity: item.entity,
            conversationType: item.conversationType,
            unread: item.unread,
            unreadString: item.unreadString,
            hasUnreadMention: item.hasUnreadMention,
            indicator: item.color,
            isDraft: item.isDraft,
            isAttachment: item.hasAttachment,
            groupchatNickname: item.userNickname,
            isSystem: item.isSystemMessage,
            isPinned: item.isPinned,
            subRequest: item.subRequest,
            avatarUrl: item.avatarUrl,
            hasErrorInChat: item.hasErrorInChat,
            verAction: item.isVerificationActionRequired
        )
        cell.setMask()

        let isSelected = isCurrentSearchResult(item)
        cell.applyPlainGroupedSystemBackground(
            selectedColor: isSelected
                ? AccountSelectionHighlightStyle.tint50(
                    owner: item.owner,
                    fallbackOwners: Set(enabledAccounts)
                )
                : nil,
            isSelected: isSelected,
            usesHighlightedStateForSelection: false,
            usesStateDrivenSelection: false
        )
    }

    internal func isCurrentSearchResult(_ item: Datasource) -> Bool {
        guard let currentVc else { return false }

        return currentVc.jid == item.jid
            && currentVc.owner == item.owner
            && currentVc.conversationType == item.conversationType
    }

    private func subscribe() {
        searchObserver
            .asObservable()
            .skip(1)
            .distinctUntilChanged()
            .debounce(.milliseconds(250), scheduler: MainScheduler.asyncInstance)
            .subscribe { [weak self] searchText in
                self?.updateDatasource(searchText)
            } onError: { _ in

            } onCompleted: {

            } onDisposed: {

            }
            .disposed(by: bag)
    }

    private func updateSections() {
        sections = SearchResultsViewController.makeSections(
            hasContacts: chatsDatasource.isNotEmpty,
            hasGroups: groupsDatasource.isNotEmpty,
            hasMessages: messagesDatasource.isNotEmpty
        )
    }

    private static func isGroupSearchResult(_ item: Datasource) -> Bool {
        guard item.conversationType == .group || item.conversationType == .channel else {
            if let entity = item.entity {
                return [.groupchat, .incognitoChat, .privateChat].contains(entity)
            }
            return false
        }
        return true
    }

    private func cancelActiveSearch(clearPresentation: Bool) {
        pipeline.cancel()
        localPageCancellations.values.forEach { $0.cancel() }
        localPageCancellations.removeAll(keepingCapacity: false)
        remotePagesByQueryID.removeAll(keepingCapacity: false)
        if clearPresentation {
            presentationByStableID.removeAll(keepingCapacity: false)
        }
    }

    private func updateDatasource(_ searchText: String?) {
        let normalized = searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard normalized.isNotEmpty else {
            reset()
            return
        }

        cancelActiveSearch(clearPresentation: true)
        activeInputQuery = normalized
        usesInjectedSnapshot = false
        let requests = pipeline.begin(
            query: normalized,
            providers: LastChatsSearchProviderPlan.make(enabledOwners: enabledAccounts)
        )
        isLoadingDone = requests.isEmpty
        applyPipelineSnapshot()
        requests.forEach(startPage)
    }

    private func startPage(_ request: LastChatsSearchPageRequest) {
        switch request.provider {
        case .remoteArchive:
            startRemotePage(request)
        case .localDirectory, .localMessages, .encryptedMessages:
            startLocalPage(request)
        }
    }

    private func startLocalPage(_ request: LastChatsSearchPageRequest) {
        localPageCancellations[request.provider]?.cancel()
        let loader = LastChatsSearchLocalPageLoader(enabledOwners: enabledAccounts)
        let executor = LastChatsSearchBackgroundPageExecutor(loader: loader.load)
        localPageCancellations[request.provider] = executor.load(request: request) { [weak self] page in
            guard let self else { return }
            self.localPageCancellations.removeValue(forKey: request.provider)
            self.receive(.page(page))
            if page.nextCursor == nil {
                self.receive(.finished(request))
            }
        }
    }

    private func receive(_ event: LastChatsSearchProviderEvent) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.receive(event)
            }
            return
        }
        guard pipeline.receive(event) else { return }
        applyPipelineSnapshot()
    }

    internal func loadNextSearchPageIfNeeded(at indexPath: IndexPath) {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].kind == .messages,
              indexPath.row >= max(0, messagesDatasource.count - 12) else {
            return
        }
        LastChatsSearchProviderPlan.make(enabledOwners: enabledAccounts).forEach { provider in
            guard let request = pipeline.requestNextPage(for: provider) else { return }
            startPage(request)
        }
    }

    private func startRemotePage(_ request: LastChatsSearchPageRequest) {
        guard case .remoteArchive(let owner, let conversationTypeRawValue) = request.provider,
              let conversationType = ClientSynchronizationManager.ConversationType(
                rawValue: conversationTypeRawValue
              ) else {
            receive(.failed(request, reason: .providerUnavailable))
            return
        }

        let callbacks = MessageArchiveManager.RequestCallbacks(
            onMessage: { [weak self] item, queryId in
                self?.didReceiveMessage(item, queryId: queryId)
            },
            onEndPage: { [weak self] queryId, state, first, last, count in
                self?.didReceiveEndPage(
                    queryId: queryId,
                    state: state,
                    first: first,
                    last: last,
                    count: count
                )
            }
        )

        let register: (MessageArchiveManager, XMPPStream) -> Void = { [weak self] manager, stream in
            guard let self else { return }
            let queryId = manager.searchText(
                stream,
                conversationType: conversationType,
                text: request.query,
                max: request.limit,
                loadFull: false,
                pageCursor: request.cursor?.opaque,
                requestCallbacks: callbacks
            )
            let registration = {
                guard request.generation == self.pipeline.snapshot.generation else { return }
                self.remotePagesByQueryID[queryId] = RemotePageContext(
                    request: request,
                    items: []
                )
            }
            if Thread.isMainThread {
                registration()
            } else {
                DispatchQueue.main.async(execute: registration)
            }
        }

        XMPPUIActionManager.shared.performRequest(owner: owner) { stream, session in
            guard let manager = session.mam else {
                DispatchQueue.main.async { [weak self] in
                    self?.receive(.failed(request, reason: .providerUnavailable))
                }
                return
            }
            register(manager, stream)
        } fail: { [weak self] in
            guard let account = AccountManager.shared.find(for: owner) else {
                DispatchQueue.main.async {
                    self?.receive(.failed(request, reason: .providerUnavailable))
                }
                return
            }
            account.action { user, stream in
                register(user.mam, stream)
            }
        }
    }

    internal final func replaceMessageStorageItemsForTesting(
        _ messageItems: [MessageStorageItem]
    ) throws {
        var seenMessagePrimaries: Set<String> = []
        messagesDatasource = try messageItems.compactMap { messageItem -> Datasource? in
            guard seenMessagePrimaries.insert(messageItem.primary).inserted else {
                return nil
            }
            let realm = try WRealm.safe()
            guard let item = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: messageItem.opponent,
                    owner: messageItem.owner,
                    conversationType: messageItem.conversationType
                )
            ) else {
                return nil
            }

            if (XMPPJID(string: item.jid)?.isServer ?? false) && item.conversationType != .saved {
                return nil
            }

            let date = messageItem.date
            var message: String = messageItem.body
            var isAttachment: Bool = [
                MessageStorageItem.MessageDisplayType.sticker,
                MessageStorageItem.MessageDisplayType.call
            ].contains(messageItem.displayAs)
            if !isAttachment,
               let authMessageMetadata = messageItem.systemMetadata?["auth_message"] as? Bool,
               authMessageMetadata {
                isAttachment = true
            }

            let isInvite = false
            var nickname: String? = nil
            var isSystemMessage: Bool = [.system].contains(messageItem.displayAs)
            if item.isFreshNotEmptyEncryptedChat {
                message = "Write your encrypted messages here"
                isSystemMessage = true
            }

            let username = item.rosterItem?.displayName ?? item.jid
            var attributedUsername: NSAttributedString? = nil
            let primaryResource = item.rosterItem?.getPrimaryResource()
            let entity: RosterItemEntity = {
                if item.conversationType == .group {
                    return primaryResource?.entity ?? .groupchat
                }
                return primaryResource?.entity ?? .contact
            }()

            if item.conversationType.isEncrypted {
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
                    } else if collectionJid.contains(where: { $0.state == .fingerprintChanged || $0.state == .revoked }) {
                        color = .systemRed
                        indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemRed)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    } else if collectionJid.contains(where: { $0.state != .trusted }) {
                        color = .systemOrange
                        indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemOrange)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    } else if collectionJid.contains(where: { $0.isTrustedByCertificate }) {
                        color = .systemGreen
                        indicatorAttach.image = UIImage(systemName: "lock.circle.fill")?.withTintColor(.systemGreen)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    } else {
                        color = .systemGreen
                        indicatorAttach.image = UIImage(systemName: "lock.fill")?.withTintColor(.systemGreen)
                        attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                    }
                } catch {
                    DDLogDebug("ChatSearchResultsController: \(#function). \(error.localizedDescription)")
                }

                attributedTitle.append(NSAttributedString(string: username, attributes: [
                    .foregroundColor: color,
                    .font: UIFont.systemFont(ofSize: 17, weight: .medium)
                ]))
                attributedUsername = attributedTitle as NSAttributedString
            }

            return Datasource(
                jid: messageItem.opponent,
                owner: messageItem.owner,
                username: username,
                attributedUsername: attributedUsername,
                message: message,
                date: date,
                state: messageItem.outgoing ? messageItem.state : nil,
                isMute: false,
                isSynced: false,
                status: primaryResource?.status ?? .offline,
                entity: entity,
                conversationType: item.conversationType,
                unread: 0,
                unreadString: isInvite ? "1" : nil,
                hasUnreadMention: item.hasUnreadMention,
                color: AccountManager.shared.users.count <= 1 ? .clear : AccountColorManager.shared.primaryColor(for: item.owner),
                isDraft: false,
                hasAttachment: isAttachment,
                userNickname: nickname,
                isSystemMessage: isSystemMessage,
                isPinned: false,
                subRequest: false,
                isEncrypted: item.conversationType.isEncrypted,
                avatarUrl: item.rosterItem?.avatarUrl,
                hasErrorInChat: false,
                updateTS: item.updateTS,
                isVerificationActionRequired: false,
                messageArchiveId: messageItem.archivedId
            )
        }
        updateSections()
        onSnapshotChanged?()
    }

    private func applyPipelineSnapshot() {
        do {
            usesInjectedSnapshot = false
            chatsDatasource = []
            groupsDatasource = []
            let snapshot = pipeline.snapshot
            guard snapshot.query?.isNotEmpty == true else {
                messagesDatasource = []
                isLoadingDone = true
                updateSections()
                onSnapshotChanged?()
                return
            }

            let realm = try WRealm.safe()
            let chats = snapshot.items.compactMap { projection -> LastChatsStorageItem? in
                guard projection.kind == .conversation else { return nil }
                return realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: projection.storagePrimary
                )
            }
            let roster = snapshot.items.compactMap { projection -> RosterStorageItem? in
                guard projection.kind == .roster else { return nil }
                return realm.object(
                    ofType: RosterStorageItem.self,
                    forPrimaryKey: projection.storagePrimary
                )
            }

            let chatResults: [Datasource] = chats.compactMap { item -> Datasource? in
                if (XMPPJID(string: item.jid)?.isServer ?? false) && item.conversationType != .saved {
                    return nil
                }
                let blankMessageText: String = "Start messaging here".localizeString(id: "chat_message_start_messaging", arguments: [])
                let subscriptionRequest: Bool = item.rosterItem?.isThereSubscriptionRequest() ?? false
                let primaryResource = item.rosterItem?.getPrimaryResource()
                let entity = primaryResource?.entity ?? (item.conversationType == .group ? RosterItemEntity.groupchat : .contact)
                let date = item.messageDate == Date(timeIntervalSince1970: 0) ? nil : item.messageDate
                var message: String

                if let lastMessage = item.lastMessage {
                    message = lastMessage.displayedBody()
                    if message.isEmpty || lastMessage.isDeleted {
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
                    MessageStorageItem.MessageDisplayType.call
                ].contains(item.lastMessage?.displayAs ?? .text)
                if !isAttachment,
                   let authMessageMetadata = item.lastMessage?.systemMetadata?["auth_message"] as? Bool,
                   authMessageMetadata {
                    isAttachment = true
                }

                let isInvite = false
                let nickname: String? = item.lastMessage?.groupchatDisplayedNickname
                var isSystemMessage: Bool = [.system].contains(item.lastMessage?.displayAs ?? .text)
                if item.isFreshNotEmptyEncryptedChat {
                    message = "Write your encrypted messages here"
                    isSystemMessage = true
                }
                if item.lastMessage == nil {
                    isSystemMessage = true
                }

                let username = item.rosterItem?.displayName ?? item.jid
                var attributedUsername: NSAttributedString? = nil
                var isVerificationActionRequired: Bool = false

                if item.conversationType.isEncrypted {
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
                        } else if collectionJid.contains(where: { $0.state == .fingerprintChanged || $0.state == .revoked }) {
                            color = .systemRed
                            indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemRed)
                            attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                        } else if collectionJid.contains(where: { $0.state != .trusted }) {
                            color = .systemOrange
                            indicatorAttach.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemOrange)
                            attributedTitle.append(NSAttributedString(attachment: indicatorAttach))
                        } else if collectionJid.contains(where: { $0.isTrustedByCertificate }) {
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
                        DDLogDebug("ChatSearchResultsController: \(#function). \(error.localizedDescription)")
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
                    entity: entity,
                    conversationType: item.conversationType,
                    unread: item.lastMessage?.outgoing ?? false ? 0 : item.unread,
                    unreadString: isInvite ? "1" : nil,
                    hasUnreadMention: item.hasUnreadMention,
                    color: AccountManager.shared.users.count <= 1 ? .clear : AccountColorManager.shared.primaryColor(for: item.owner),
                    isDraft: isDraft,
                    hasAttachment: isAttachment,
                    userNickname: nickname,
                    isSystemMessage: isSystemMessage,
                    isPinned: item.isPinned,
                    subRequest: (XMPPJID(string: item.jid)?.isServer ?? true) ? false : subscriptionRequest,
                    isEncrypted: item.conversationType.isEncrypted,
                    avatarUrl: item.rosterItem?.avatarMinUrl ?? item.rosterItem?.avatarMaxUrl ?? item.rosterItem?.oldschoolAvatarKey,
                    hasErrorInChat: item.hasErrorInChat,
                    updateTS: item.updateTS,
                    isVerificationActionRequired: isVerificationActionRequired,
                    messageArchiveId: nil
                )
            }

            chatsDatasource = chatResults.filter { !Self.isGroupSearchResult($0) }
            groupsDatasource = chatResults.filter { Self.isGroupSearchResult($0) }

            let jids = Set((chatsDatasource + groupsDatasource).compactMap { [$0.owner, $0.jid].prp() })
            let rosterResults: [Datasource] = roster.compactMap({ item -> Datasource? in
                if jids.contains([item.owner, item.jid].prp()) { return nil }
                let primaryResource = item.getPrimaryResource()
                let conversationType = item.isContact
                    ? ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
                    : .group
                let entity = primaryResource?.entity ?? (item.isContact ? RosterItemEntity.contact : .groupchat)
                return Datasource(
                    jid: item.jid,
                    owner: item.owner,
                    username: item.displayName,
                    attributedUsername: nil,
                    message: "Start messaging here".localizeString(id: "chat_message_start_messaging", arguments: []),
                    date: nil,
                    state: nil,
                    isMute: false,
                    isSynced: true,
                    status: primaryResource?.status ?? .offline,
                    entity: entity,
                    conversationType: conversationType,
                    unread: 0,
                    unreadString: nil,
                    hasUnreadMention: false,
                    color: AccountManager.shared.users.count <= 1 ? .clear : AccountColorManager.shared.primaryColor(for: item.owner),
                    isDraft: false,
                    hasAttachment: false,
                    userNickname: nil,
                    isSystemMessage: true,
                    isPinned: false,
                    subRequest: false,
                    isEncrypted: conversationType.isEncrypted,
                    avatarUrl: item.avatarUrl,
                    hasErrorInChat: false,
                    updateTS: 0,
                    isVerificationActionRequired: false,
                    messageArchiveId: nil
                )
            })
            chatsDatasource.append(contentsOf: rosterResults.filter { !Self.isGroupSearchResult($0) })
            groupsDatasource.append(contentsOf: rosterResults.filter { Self.isGroupSearchResult($0) })
            let messageItems = snapshot.items.compactMap { projection -> MessageStorageItem? in
                guard projection.kind == .message else { return nil }
                return realm.object(
                    ofType: MessageStorageItem.self,
                    forPrimaryKey: projection.storagePrimary
                )
            }
            isLoadingDone = !snapshot.isLoading
            try replaceMessageStorageItemsForTesting(messageItems)
        } catch {
            DDLogDebug("ChatSearchResultsController: \(#function). \(error.localizedDescription)")
        }
    }

    func didReceiveEndPage(queryId: String, state: MessageArchivePageEndState, first: String, last: String, count: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let context = self.remotePagesByQueryID.removeValue(forKey: queryId) else {
                return
            }
            let nextCursor = !state.queryExhausted && last.isNotEmpty
                ? LastChatsSearchCursor(opaque: last)
                : nil
            let page = LastChatsSearchProviderPage(
                request: context.request,
                items: Array(context.items.prefix(context.request.limit)),
                nextCursor: nextCursor
            )
            self.receive(.page(page))
            if nextCursor == nil {
                self.receive(.finished(context.request))
            }
        }
    }

    func didReceiveMessage(_ item: MessageStorageItem, queryId: String) {
        let projection = LastChatsSearchLocalPageLoader.messageProjection(item)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  var context = self.remotePagesByQueryID[queryId],
                  context.request.generation == self.pipeline.snapshot.generation else {
                return
            }
            if context.items.count < context.request.limit {
                context.items.append(projection)
                self.remotePagesByQueryID[queryId] = context
            }
        }
    }
}

extension SearchResultsViewController: TemporaryMessageReceiverProtocol {
    func didReceiveEndPage(queryId: String, state: MessageArchivePageEndState, first: String, last: String, count: Int) {
        DispatchQueue.main.async {
            let decision = SearchRemoteQueryCompletionPolicy.endPageDecision(
                queryId: queryId,
                currentQueries: self.currentQueries
            )
            guard !decision.isStale else {
                return
            }

            self.currentQueries = decision.remainingQueries
            self.isLoadingDone = decision.isLoadingDone
            try? self.updateMessagesSearchResults()
        }
    }
    
    func didReceiveMessage(_ item: MessageStorageItem, queryId: String) {
        DispatchQueue.main.async {
            guard SearchRemoteQueryCompletionPolicy.shouldAcceptMessage(
                queryId: queryId,
                currentQueries: self.currentQueries
            ) else {
                return
            }

            self.messagesQueue.append(item)
            self.searchResultsObserver.accept(item.primary)
        }
    }
}
