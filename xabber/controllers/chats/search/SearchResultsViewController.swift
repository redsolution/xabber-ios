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
import XMPPFramework.XMPPJID
import CocoaLumberjack

class SearchResultsViewController: SimpleBaseViewController {
    
    struct Section {
        enum Kind {
            case contacts
            case messages
        }
        
        let header: String
        let footer: String
        let kind: Kind
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
    var messagesDatasource: [Datasource] = []
    
    var isLoadingDone: Bool = true
    
    struct SearchRequest: Hashable, Equatable {
        let owner: String
        let queryId: String
    }
    
    internal var sections: [Section] = []
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .plain)

        view.register(ChatListTableViewCell.self, forCellReuseIdentifier: ChatListTableViewCell.cellName)
        view.register(ContactsViewController.ContactCell.self, forCellReuseIdentifier: ContactsViewController.ContactCell.cellName)
        
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
    
    internal lazy var enabledAccounts: [String] = {
        do {
            let realm = try WRealm.safe()
            return realm
                .objects(AccountStorageItem.self)
                .filter("enabled == %@", true)
                .toArray()
                .compactMap { $0.jid }
        } catch {
            return []
        }
    }()
    
    override func subscribe() {
        super.subscribe()
        self.searchObserver
            .asObservable()
            .debounce(.microseconds(200), scheduler: MainScheduler.asyncInstance)
            .subscribe { searchText in
                self.updateDatasource(searchText)
            } onError: { _ in
                
            } onCompleted: {
                
            } onDisposed: {
                
            }.disposed(by: self.bag)

    }
    
    private final func searchForAccount(_ owner: String, search text: String, withUIStream: Bool) {
        guard text.isNotEmpty else { return }
        do {
            let realm = try WRealm.safe()
            realm
                .objects(MessageStorageItem.self)
                .filter(
                    "owner == %@ AND isDeleted == false AND conversationType_ == %@ AND messageType != %@ AND messageType != %@ AND messageType != %@ AND body CONTAINS[cd] %@",
                    owner,
                    ClientSynchronizationManager.ConversationType.omemo.rawValue,
                    MessageStorageItem.MessageDisplayType.initial.rawValue,
                    MessageStorageItem.MessageDisplayType.system.rawValue,
                    MessageStorageItem.MessageDisplayType.voice.rawValue,
                    text
                )
                .sorted(byKeyPath: "date", ascending: false)
                .toArray()
                .forEach {
                    item in
                    self.messagesQueue.append(item)
                }
            if withUIStream {
                XMPPUIActionManager.shared.performRequest(owner: owner) { stream, session in
                    session.mam?.temporaryMessageReceiverDelegate = self
                    let queryId = session.mam?.searchText(stream, conversationType: .regular, text: text, max: 100, loadFull: false) ?? ""
                    self.currentQueries.insert(SearchRequest(owner: owner, queryId: queryId))
                } fail: {
                    AccountManager.shared.find(for: owner)?.action({ user, stream in
                        user.mam.temporaryMessageReceiverDelegate = self
                        let queryId = user.mam.searchText(stream, conversationType: .regular, text: text, max: 100, loadFull: false)
                        self.currentQueries.insert(SearchRequest(owner: owner, queryId: queryId))
                    })
                }
            } else {
                AccountManager.shared.find(for: owner)?.action({ user, stream in
                    user.mam.temporaryMessageReceiverDelegate = self
                    let queryId = user.mam.searchText(stream, conversationType: .regular, text: text, max: 100, loadFull: false)
                    self.currentQueries.insert(SearchRequest(owner: owner, queryId: queryId))
                })
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal final func updateMessagesSearchResults() throws {
        self.messagesDatasource = try self.messagesQueue.sorted(by: { $0.date > $1.date }).compactMap {
            messageItem in
            
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
                MessageStorageItem.MessageDisplayType.files,
                MessageStorageItem.MessageDisplayType.images,
                MessageStorageItem.MessageDisplayType.voice,
                MessageStorageItem.MessageDisplayType.call].contains(messageItem.displayAs)
            if !isAttachment,
               let authMessageMetadata = messageItem.systemMetadata?["auth_message"] as? Bool,
               authMessageMetadata {
                isAttachment = true
            }
            
            let isInvite = item.unread > 0 ? (messageItem.displayAs  == .initial ? true : false) : false
            
            var nickname: String? = nil//messageItem.groupchatDisplayedNickname
            if messageItem.inlineForwards.isNotEmpty {
                let sender = messageItem.inlineForwards.first
                var nick = sender?.forwardNickname
                if nick == "" || nick == nil {
                    nick = String(JidManager.shared.prepareJid(jid: sender?.forwardJid ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])))
                }
                switch messageItem.inlineForwards.first?.kind {
                case .text:
                    nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])): \(messageItem.inlineForwards.first?.body ?? "")"
                case .images:
                    nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " image".localizeString(id: "forward_image", arguments: [])
                case .videos:
                    nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " video".localizeString(id: "forward_video", arguments: [])
                case .files:
                    nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " file".localizeString(id: "forward_file", arguments: [])
                case .voice:
                    nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])):" + " voice message".localizeString(id: "forward_voice", arguments: [])
                case .quote:
                    nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])): \(messageItem.inlineForwards.first?.body ?? "")"
                case .none:
                    nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: []))"
                }
            }
            
            var isSystemMessage: Bool = [.system, .initial].contains(messageItem.displayAs)
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
            self.chatsDatasource = chats.compactMap {
                item in
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
                    isEncrypted: item.conversationType.isEncrypted,
                    avatarUrl: item.rosterItem?.avatarMinUrl ?? item.rosterItem?.avatarMaxUrl ?? item.rosterItem?.oldschoolAvatarKey,
                    hasErrorInChat: item.hasErrorInChat,
                    updateTS: item.updateTS,
                    isVerificationActionRequired: isVerificationActionRequired,
                    messageArchiveId: nil
                )
            }
            
            self.chatsDatasource.append(contentsOf: roster.compactMap ({
                item in
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
            self.sections = []
            if self.chatsDatasource.count  > 0 {
                self.sections.append(Section(header: "Contacts".localizeString(id: "contacts", arguments: []), footer: "", kind: .contacts))
            }
            self.sections.append(Section(header: "Messages".localizeString(id: "groupchat_member_messages", arguments: []), footer: "", kind: .messages))
            self.messagesDatasource = []
            self.messagesQueue = []
            self.isLoadingDone = false
            self.currentQueries = Set()
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
        view.addSubview(tableView)
        tableView.fillSuperview()
        
        tableView.dataSource = self
        tableView.delegate = self
    }
}

extension SearchResultsViewController: TemporaryMessageReceiverProtocol {
    func didReceiveEndPage(queryId: String, fin: Bool, first: String, last: String, count: Int) {
        if self.currentQueries.contains(where: { $0.queryId == queryId }) {
            print("FIN")
            DispatchQueue.main.async {
                self.isLoadingDone = true
                try? self.updateMessagesSearchResults()
            }
        }
    }
    
    func didReceiveMessage(_ item: MessageStorageItem, queryId: String) {
        if self.currentQueries.contains(where: { $0.queryId == queryId }) {
            self.messagesQueue.append(item)
            self.searchResultsObserver.accept(item.primary)
        }
    }
}
