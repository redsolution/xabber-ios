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

protocol ShareViewControllerDelegate {
    func open(owner: String, jid: String, forwarded messages: [String])
}

class ShareDialogController: BaseViewController {
    
    struct Datasource {
        let jid: String
        let owner: String
        let username: String
        let message: String
        let date: Date?
        let deliveryState: MessageStorageItem.MessageSendingState?
        let isMute: Bool
        let isSynced: Bool
        let isGroupchat: Bool
        let status: ResourceStatus
        let entity: RosterItemEntity
        let conversationType: ClientSynchronizationManager.ConversationType
        let unread: Int
        let unreadString: String?
        let indicator: UIColor
        let isDraft: Bool
        let isAttachment: Bool
        let groupchatNickname: String?
        let isSystem: Bool
    }
    
    internal var forwardIds: [String] = []
    
    internal var bag: DisposeBag = DisposeBag()
    
    internal var chatsDataset: Results<LastChatsStorageItem>? = nil
    internal var rosterDataset: Results<RosterStorageItem>? = nil
    
    internal var datasource: [Datasource] = []
    
    open var delegate: ShareViewControllerDelegate? = nil
    
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
                .sorted(byKeyPath: "messageDate", ascending: false)
            
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
            var blankMessageText: String = "No messages".localizeString(id: "no_messages", arguments: [])
            if item.messagesCount != 0 {
                blankMessageText = (item.retractVersion == "0" && item.retractVersion != "") ? "No messages".localizeString(id: "no_messages", arguments: []) :
                "Message retracted".localizeString(id: "recent_chat__last_message_retracted", arguments: [])
            }
            
            
            let primaryResource = item.rosterItem?.getPrimaryResource()
            
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
//                nickname = "Forwarded message"
            }
            
            return Datasource(
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
                entity: primaryResource?.entity ?? .contact,
                conversationType: item.conversationType,
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
            
            
            return Datasource(
                jid: item.jid,
                owner: item.owner,
                username: item.displayName,
                message: item.jid,
                date: nil,
                deliveryState: nil,
                isMute: false,
                isSynced: true,
                isGroupchat: [.groupchat, .privateChat, .incognitoChat].contains(entity),
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
        
        if #available(iOS 11.0, *) {
            navigationItem.searchController = searchController
            navigationItem.hidesSearchBarWhenScrolling = false
        } else {
            tableView.tableHeaderView = searchController?.searchBar
        }
        (searchController?.searchResultsUpdater as? ShareDialogSearchController)?.delegate = self
        
        definesPresentationContext = true
    }
    
    public final func configure() {
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

    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
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
