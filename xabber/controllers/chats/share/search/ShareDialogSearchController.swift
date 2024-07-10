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

class ShareDialogSearchController: BaseViewController {
    
    internal var forwardIds: [String] = []
    
    internal var chatsDataset: Results<LastChatsStorageItem>? = nil
    internal var rosterDataset: Results<RosterStorageItem>? = nil
    
    internal var datasource: [ShareDialogController.Datasource] = []
    
    internal var delegate: ShareDialogControllerDelegate? = nil
    
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
            var blankMessageText: String = "No messages".localizeString(id: "no_messages", arguments: [])
            if item.messagesCount != 0 {
                blankMessageText = (item.retractVersion == "0" && item.retractVersion != "") ? "No messages".localizeString(id: "no_messages", arguments: []) :
                "Message retracted".localizeString(id: "recent_chat__last_message_retracted", arguments: [])
            }
            
            let primaryResource = item.rosterItem?.getPrimaryResource()
            let entity = primaryResource?.entity ?? .contact
            var conversationType: ClientSynchronizationManager.ConversationType = .regular
            switch entity {
            case .contact, .bot, .server, .issue:
                conversationType = .regular
            case .groupchat, .privateChat, .incognitoChat:
                conversationType = .group
            case .encryptedChat:
                conversationType = .omemo
            }
            
            var message: String = item.lastMessage?.displayedBody(entity: primaryResource?.entity ?? .contact) ?? blankMessageText
            
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
                nickname = "Forwarded message".localizeString(id: "chat_message_forwarded_message", arguments: [])
            }
            
            return ShareDialogController.Datasource (
                jid: item.jid,
                owner: item.owner,
                username: item.rosterItem?.displayName ?? item.jid,
                message: message,
                date: item.messageDate,
                deliveryState: item.lastMessage?.outgoing ?? true ? item.lastMessage?.state ?? nil : nil,
                isMute: item.isMuted,
                isSynced: true,
                isGroupchat: item.conversationType == .group,
                status: primaryResource?.status ?? .offline,
                entity: entity,
                conversationType: conversationType,
                unread: item.unread,
                unreadString: isInvite ? "1" : nil,
                indicator: .clear,
                isDraft: isDraft,
                isAttachment: isAttachment,
                groupchatNickname: nickname,
                isSystem: [.system, .initial].contains(item.lastMessage?.displayAs ?? .text)
            )
            
        } ?? []
        
        self.datasource.append(contentsOf: self.rosterDataset?.compactMap({ item in
            if datasource.contains(where: {$0.jid == item.jid}) {
                return nil
            }
            
            let primaryResource = item.getPrimaryResource()
            
            let entity = primaryResource?.entity ?? .contact
            var conversationType: ClientSynchronizationManager.ConversationType = .regular
            switch entity {
            case .contact, .bot, .server, .issue:
                conversationType = .regular
            case .groupchat, .privateChat, .incognitoChat:
                conversationType = .group
            case .encryptedChat:
                conversationType = .omemo
            }
            
            return ShareDialogController.Datasource (
                jid: item.jid,
                owner: item.owner,
                username: item.displayName,
                message: item.jid,
                date: nil,
                deliveryState: nil,
                isMute: false,
                isSynced: true,
                isGroupchat: [.groupchat, .privateChat, .incognitoChat].contains(primaryResource?.entity ?? .contact),
                status: primaryResource?.status ?? .offline,
                entity: entity,
                conversationType: conversationType,
                unread: 0,
                unreadString: nil,
                indicator: .clear,
                isDraft: false,
                isAttachment: false,
                groupchatNickname: nil,
                isSystem: false
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
            attributedUsername: nil,
            message: item.message,
            date: item.date,
            deliveryState: item.deliveryState,
            isMute: item.isMute,
            isSynced: item.isSynced,
            isGroupchat: item.isGroupchat,
            status: item.status,
            entity: item.entity,
            conversationType: item.conversationType,
            unread: item.unread,
            unreadString: item.unreadString,
            indicator: item.indicator,
            isDraft: item.isDraft,
            isAttachment: item.isAttachment,
            groupchatNickname: item.groupchatNickname,
            isSystem: item.isSystem,
            subRequest: false,
            avatarUrl: nil,
            hasErrorInChat: false,
            verAction: false
        )
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
        delegate?.onOpen(item.jid)
    }
    
}

protocol ShareDialogControllerDelegate {
    func onOpen(_ jid: String)
}
