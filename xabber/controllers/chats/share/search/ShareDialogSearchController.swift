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

class ShareDialogSearchController: BaseViewController {
    
    internal var forwardIds: [String] = []
    
    internal var chatsDataset: Results<LastChatsStorageItem>? = nil
    internal var rosterDataset: Results<RosterStorageItem>? = nil
    
    internal var datasource: [ShareDialogController.Datasource] = []
    
    internal var delegate: OpenChatDelegate? = nil
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .plain)
        
        view.register(ChatListTableViewCell.self, forCellReuseIdentifier: ChatListTableViewCell.cellName)
        
        view.tableFooterView = UIView()
        
        return view
    }()
    
    internal func load(_ jidFilter: String = "") {
        do {
            let realm = try WRealm.safe()
            chatsDataset = realm
                .objects(LastChatsStorageItem.self)
                .filter("owner == %@ AND (jid CONTAINS[cd] %@ OR rosterItem.customUsername CONTAINS[cd] %@ OR rosterItem.username CONTAINS[cd] %@)", owner, jidFilter, jidFilter, jidFilter)
                .sorted(byKeyPath: "messageDate", ascending: false)
            rosterDataset = realm
                .objects(RosterStorageItem.self)
                .filter("owner == %@ AND (jid CONTAINS[cd] %@ OR customUsername CONTAINS[cd] %@ OR username CONTAINS[cd] %@)", owner, jidFilter, jidFilter, jidFilter)
                .sorted(byKeyPath: "jid", ascending: true)
        } catch {
            fatalError()
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
            return ShareDialogController.Datasource(
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
        
        self.datasource.append(contentsOf: self.rosterDataset?.compactMap({ item in
            if datasource.contains(where: {$0.jid == item.jid}) {
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
            
            return ShareDialogController.Datasource(
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
    
    internal func activateConstraints() {
        
    }
    
    open func configure(owner: String, forwardIds: [String]) {
        self.owner = owner
        self.forwardIds = forwardIds
        load()
        view.addSubview(tableView)
        tableView.fillSuperview()
        tableView.dataSource = self
        tableView.delegate = self
        self.title = "Forward".localizeString(id: "chat_froward", arguments: [])
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        activateConstraints()
        
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
        updateDatasource()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }
}

extension ShareDialogSearchController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let filter = searchController.searchBar.text ?? ""
        load(filter)
        updateDatasource()
    }
}

extension ShareDialogSearchController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatListTableViewCell.cellName, for: indexPath) as? ChatListTableViewCell else {
            fatalError()
        }
        let item = datasource[indexPath.row]
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
        
        let view = UIView()
        view.backgroundColor = AccountColorManager.shared.palette(for: item.owner).tint50 | AccountColorManager.shared.palette(for: item.owner).tint900
        cell.selectedBackgroundView = view
        return cell
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource.count
    }
}

extension ShareDialogSearchController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 76
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = datasource[indexPath.row]
        self.dismiss(animated: true) {
            self.delegate?
                .open(
                    owner: item.owner,
                    jid: item.jid,
                    conversationType: item.conversationType,
                    forwarded: self.forwardIds
                )
        }
    }
    
}

protocol ShareDialogControllerDelegate {
    func onOpen(_ jid: String)
}
