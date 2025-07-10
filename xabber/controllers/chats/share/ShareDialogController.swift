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
import RxRealm
import CocoaLumberjack
import DeepDiff
import XMPPFramework.XMPPJID


class ShareDialogController: SimpleBaseViewController, UISearchBarDelegate, UISearchControllerDelegate {
    
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
        
        static func compareContent(_ a: ShareDialogController.Datasource, _ b: ShareDialogController.Datasource) -> Bool {
            return a.jid == b.jid
                    && a.owner == b.owner
                    && a.username == b.username
                    && a.attributedUsername?.string == b.attributedUsername?.string
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
    
    internal var forwardIds: [String] = []
        
    internal var chatsDataset: Results<LastChatsStorageItem>? = nil
    internal var rosterDataset: Results<RosterStorageItem>? = nil
    
    internal var datasource: [Datasource] = []
    
    open var delegate: OpenChatDelegate? = nil
    
    open var lastChatsDisplayDelegate: LastChatsDisplayDelegate? = nil
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .plain)
        
        view.register(ChatListTableViewCell.self, forCellReuseIdentifier: ChatListTableViewCell.cellName)
        
        return view
    }()
    
    internal var searchController: UISearchController? = nil
    
    internal func load(_ jidFilter: String = "") {
        do {
            let realm = try WRealm.safe()
            
            chatsDataset = realm
                .objects(LastChatsStorageItem.self)
                .filter("owner == %@", owner)
                .sorted(by: [
                    SortDescriptor(keyPath: "isPinned", ascending: false),
                    SortDescriptor(keyPath: "pinnedPosition", ascending: true),
                    SortDescriptor(keyPath: "messageDate", ascending: false)
                ])
            
            rosterDataset = realm
                .objects(RosterStorageItem.self)
                .filter("owner == %@", owner)
                .sorted(byKeyPath: "jid", ascending: true)
            
        } catch {
            DDLogDebug("ShareDialogController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal func updateDatasource() {
        datasource = chatsDataset?.map { item in
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
            
            let isInvite = false
            
            let nickname: String? = item.lastMessage?.groupchatDisplayedNickname
            if item.lastMessage?.inlineForwards.isNotEmpty ?? false {
                let sender = item.lastMessage?.inlineForwards.first
                var nick = sender?.forwardNickname
                if nick == "" || nick == nil {
                    nick = String(JidManager.shared.prepareJid(jid: sender?.forwardJid ?? "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])))
                }
            }
            
            var isSystemMessage: Bool = [.system].contains(item.lastMessage?.displayAs ?? .text)
            if isSystemMessage == false {
                isSystemMessage = item.lastMessage?.shouldShowAsSystemMessage() ?? false
            }
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
                isVerificationActionRequired: isVerificationActionRequired
            )
        } ?? []
        
        if let favoritesChatIndex = datasource.firstIndex(where: { $0.conversationType == .saved }) {
//            datasource.swapAt(favoritesChat, 0)
            datasource.insert(datasource.remove(at: favoritesChatIndex), at: 0) 
        }
        
        self.datasource.append(contentsOf: self.rosterDataset?.compactMap({ item in
            if datasource.contains(where: {$0.jid == item.jid && $0.owner == item.owner}) {
                return nil
            }
            let blankMessageText: String = "Start messaging here".localizeString(id: "chat_message_start_messaging", arguments: [])
            
            let primaryResource = item.getPrimaryResource()
            let entity = primaryResource?.entity ?? .contact
            var conversationType: ClientSynchronizationManager.ConversationType = .regular
            switch entity {
                case .groupchat, .privateChat, .incognitoChat:
                    conversationType = .group
                default:
                    conversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
            }
            let username = item.displayName
            var attributedUsername: NSAttributedString? = nil
            
            var isVerificationActionRequired: Bool = false
                            
            if conversationType.isEncrypted {
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
                username: item.displayName,
                attributedUsername: attributedUsername,
                message: blankMessageText,
                date: Date(),
                state: nil,
                isMute: false,
                isSynced: true,
                status: primaryResource?.status ?? .offline,
                entity: primaryResource?.entity ?? .contact,
                conversationType: conversationType,
                unread: 0,
                unreadString: nil,
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
                isVerificationActionRequired: isVerificationActionRequired
            )
        }) ?? [])
        self.tableView.reloadData()
    }
        
    internal func configureSearchBar() {
        let searchUpdater = ShareDialogSearchController()
        searchUpdater.configure(owner: owner, forwardIds: forwardIds)
        
        searchController = UISearchController(searchResultsController: searchUpdater)
        
        searchController?.searchResultsUpdater = searchUpdater
        searchController?.obscuresBackgroundDuringPresentation = false
        searchController?.searchBar.searchBarStyle = .default
        searchController?.searchBar.placeholder = "Search contacts".localizeString(id: "contact_search_hint", arguments: [])
        searchController?.searchBar.isTranslucent = true
        searchController?.hidesNavigationBarDuringPresentation = false
        searchController?.hidesBottomBarWhenPushed = false
        searchController?.delegate = self
        searchController?.searchBar.delegate = self
        
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        (searchController?.searchResultsUpdater as? ShareDialogSearchController)?.delegate = self.delegate
        
        definesPresentationContext = true
    }
    
    override func configure() {
        super.configure()
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
        configureSearchBar()
        self.title = "Select chat".localizeString(id: "select_chat", arguments: [])
        self.navigationItem.setHidesBackButton(true, animated: false)
        self.navigationItem.setLeftBarButton(UIBarButtonItem(title: "Cancel".localizeString(id: "cancel", arguments: []),
                                                             style: .plain,
                                                             target: self,
                                                             action: #selector(dismissScreen)), animated: true)
        load()
    }
    
    @objc
    internal func dismissScreen() {
        self.dismiss(animated: true, completion: nil)
    }


    
    override func reloadDatasource() {
        tableView.reloadData()
    }
    
    override func onAppear() {
        super.onAppear()
        updateDatasource()
    }
}
