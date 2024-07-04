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
    
    struct ChatsDatasource: DiffAware {
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
        
        static func compareContent(_ a: ChatsDatasource, _ b: ChatsDatasource) -> Bool {
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
    
    struct ContactsDatasource: DiffAware {
        var diffId: String {
            get {
                return [jid, owner].prp()
            }
        }
        
        
        var owner: String
        var jid: String
        var title: String? = nil
        var subtitle: String? = nil
        var status: ResourceStatus? = nil
        var entity: RosterItemEntity? = nil
        var avatarUrl: String? = nil
        let conversationType: ClientSynchronizationManager.ConversationType

        static func compareContent(_ a: ContactsDatasource, _ b: ContactsDatasource) -> Bool {
            a.owner == b.owner
            && a.jid == b.jid
            && a.title == b.title
            && a.subtitle == b.subtitle
            && a.status == b.status
            && a.entity == b.entity
            && a.avatarUrl == b.avatarUrl
            && a.conversationType == b.conversationType
        }
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
    
    internal func updateSearchResults(with text: String) {
//        do {
//            let realm = try WRealm.safe()
//            filteredContacts = realm
//                .objects(RosterStorageItem.self)
//                .filter("username CONTAINS[c] %@ OR jid CONTAINS[cd] %@ OR customUsername CONTAINS[c] %@",
//                        text, text, text)
//            
//            filteredMessages = realm
//                .objects(MessageStorageItem.self)
//                .filter("isDeleted == %@ AND body CONTAINS[cd] %@", false, text)
//                .sorted(byKeyPath: "date", ascending: false)
//            
//            subscribeDataset()
//        } catch {
//            DDLogDebug("cant update search results")
//        }
    }
    
    internal func subscribeDataset() {
//        datasetBag = DisposeBag()
//        if filteredContacts != nil {
//            Observable
//                .collection(from: filteredContacts!)
//                .subscribe(onNext: { (results) in
//                    self.isContactsHidden = results.isEmpty
//                    self.tableView.reloadData()
//                })
//                .disposed(by: datasetBag)
//        }
//        if filteredMessages != nil {
//            Observable
//                .collection(from: filteredMessages!)
//                .subscribe(onNext: { (results) in
//                    do {
//                        let realm = try WRealm.safe()
//                        self.messagesMetadata = results.toArray().reduce(into: [String: Any]()) {
//                            let item = realm
//                                .object(
//                                    ofType: LastChatsStorageItem.self,
//                                    forPrimaryKey: LastChatsStorageItem.genPrimary(
//                                        jid: $1.opponent,
//                                        owner: $1.owner,
//                                        conversationType: $1.conversationType
//                                    )
//                                )
//                            $0[[$1.opponent, $1.owner, "username"].prp()] = item?.rosterItem?.displayName ?? $1.opponent
//                            $0[[$1.opponent, $1.owner, "groupchat"].prp()] = item?.conversationType == .group
//                        }
//                    } catch {
//                        DDLogDebug("cant update usernames for search results")
//                    }
//                    self.isMessagesHidden = results.isEmpty
//                    self.tableView.reloadData()
//                })
//                .disposed(by: datasetBag)
//        }
    }
    
    internal var searchObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    
    internal var chatsDatasource: [ChatsDatasource] = []
    internal var contactsDatasource: [ContactsDatasource] = []
    
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
    
    private func updateDatasource(_ searchText: String?) {
        do {
            self.chatsDatasource = []
            self.contactsDatasource = []
            let realm = try WRealm.safe()
            let enabledAccounts = realm
                .objects(AccountStorageItem.self)
                .filter("enabled == %@", true)
                .toArray()
                .compactMap { $0.jid }
            if let searchText = searchText {
                let contacts = realm
                    .objects(RosterStorageItem.self)
                    .filter(
                        "owner IN %@ AND username CONTAINS[c] %@ OR jid CONTAINS[cd] %@ OR customUsername CONTAINS[c] %@",
                        enabledAccounts,
                        searchText,
                        searchText,
                        searchText
                    )
                self.contactsDatasource = contacts.compactMap({
                    item in
                    do {
                        let realm = try WRealm.safe()
                        let resource = item.getPrimaryResource()
                        let conversationTypes = Set(realm
                            .objects(LastChatsStorageItem.self)
                            .filter("jid == %@ AND owner == %@", item.jid, item.owner)
                            .toArray()
                            .compactMap{ $0.conversationType })
                        
                        var conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
                        
                        if !conversationTypes.contains(conversationType) {
                            conversationType = conversationTypes.first ?? conversationType
                        }
                        
                        return ContactsDatasource(
                            owner: item.owner,
                            jid: item.jid,
                            title: item.displayName,
                            subtitle: item.jid,
                            status: resource?.status ?? .offline,
                            entity: resource?.entity ?? .contact,
                            avatarUrl: item.avatarUrl,
                            conversationType: conversationType
                        )
                    } catch {
                        DDLogDebug("SearchResultsViewController: \(#function). \(error.localizedDescription)")
                    }
                    return nil
                })
                self.chatsDatasource = realm
                    .objects(MessageStorageItem.self)
                    .filter(
                        "owner IN %@ AND isDeleted == %@ AND messageType != %@ AND messageType != %@ AND messageType != %@ AND body CONTAINS[cd] %@",
                        enabledAccounts,
                        false,
                        MessageStorageItem.MessageDisplayType.initial.rawValue,
                        MessageStorageItem.MessageDisplayType.system.rawValue,
                        MessageStorageItem.MessageDisplayType.voice.rawValue,
                        searchText
                    )
                    .sorted(byKeyPath: "date", ascending: false)
                    .toArray()
                    .compactMap({
                        lastMessage in
                        
                        do {
                            let realm = try WRealm.safe()
                            if let item = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: lastMessage.opponent, owner: lastMessage.owner, conversationType: lastMessage.conversationType)) {
                                var blankMessageText: String = "No messages".localizeString(id: "no_messages", arguments: [])
                                if item.messagesCount != 0 {
                                    blankMessageText = (item.retractVersion == "0" && item.retractVersion != "") ? "No messages".localizeString(id: "no_messages", arguments: []) : "No messages".localizeString(id: "no_messages", arguments: [])

                                }
                                
                                let subscriptionRequest: Bool = false
                                
                                let primaryResource = item.rosterItem?.getPrimaryResource()
                                
                                var message: String
                                
                                message = lastMessage.displayedBody(entity: primaryResource?.entity ?? .contact)
                                if message.isEmpty {
                                    message = blankMessageText
                                }
                                if lastMessage.isDeleted {
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
                                    MessageStorageItem.MessageDisplayType.call].contains(lastMessage.displayAs)
                                if !isAttachment,
                                   let authMessageMetadata = lastMessage.systemMetadata?["auth_message"] as? Bool,
                                   authMessageMetadata {
                                    isAttachment = true
                                }
                                
                                let isInvite = item.unread > 0 ? ((lastMessage.displayAs) == .initial ? true : false) : false
                                
                                var nickname: String? = lastMessage.groupchatDisplayedNickname
                                if lastMessage.inlineForwards.isNotEmpty {
                                    let sender = lastMessage.inlineForwards.first
                                    var nick = sender?.forwardNickname
                                    if nick == "" || nick == nil {
                                        nick = String(JidManager.shared.prepareJid(jid: sender?.forwardJid ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])))
                                    }
                                    switch lastMessage.inlineForwards.first?.kind {
                                    case .text:
                                        nickname = "\(nick ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])): \(lastMessage.inlineForwards.first?.body ?? "")"
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
                                
                                var isSystemMessage: Bool = [.system, .initial].contains(lastMessage.displayAs)
                                if item.isFreshNotEmptyEncryptedChat {
                                    message = "Write your encrypted messages here"
                                    isSystemMessage = true
                                }
                                
                                let username = item.rosterItem?.displayName ?? item.jid
                                var attributedUsername: NSAttributedString? = nil
                                                
                                if [.omemo, .omemo1, .axolotl].contains(item.conversationType) {
                                    let attributedTitle: NSMutableAttributedString = NSMutableAttributedString()
                                    let indicatorAttach = NSTextAttachment()
                                    var color: UIColor = .label
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
                                    
                                    attributedTitle.append(NSAttributedString(string: username, attributes: [
                                        .foregroundColor: color,
                                        .font: UIFont.systemFont(ofSize: 17, weight: .medium)
                                    ]))
                                    attributedUsername = attributedTitle as NSAttributedString
                                }
                                
                                return ChatsDatasource(
                                    jid: item.jid,
                                    owner: item.owner,
                                    username: username,
                                    attributedUsername: attributedUsername,
                                    message: message,
                                    date: lastMessage.date,
                                    state: lastMessage.outgoing ? lastMessage.state : nil,
                                    isMute: item.isMuted,
                                    isSynced: item.isSynced,
                                    status: primaryResource?.status ?? .offline,
                                    entity: primaryResource?.entity ?? .contact,
                                    conversationType: item.conversationType,
                                    unread: lastMessage.outgoing ? 0 : item.unread,
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
                            DDLogDebug("SearchResultsViewController: \(#function). \(error.localizedDescription)")
                        }
                        return nil
                        
                    })
            }
        } catch {
            DDLogDebug("SearchResultsViewController: \(#function). \(error.localizedDescription)")
        }
        self.sections = []
        if self.contactsDatasource.isNotEmpty {
            self.sections.append(Section(header: "Contacts".localizeString(id: "contacts", arguments: []), footer: "", kind: .contacts))
        }
        if self.chatsDatasource.isNotEmpty {
            self.sections.append(Section(header: "Messages".localizeString(id: "groupchat_member_messages", arguments: []), footer: "", kind: .messages))
        }
        self.tableView.reloadData()
    }
    
    
    override func configure() {
        super.configure()
        view.addSubview(tableView)
        tableView.fillSuperview()
        
        tableView.dataSource = self
        tableView.delegate = self
                
    }
}
