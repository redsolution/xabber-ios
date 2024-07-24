//
//  XabberActivityViewController.swift
//  xabber
//
//  Created by Admin on 18.07.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import RealmSwift
import RxSwift
import CocoaLumberjack
import XMPPFramework
import Kingfisher

class XabberActivityViewController: SimpleBaseViewController {
    class Datasource {
        let jid: String
        let owner: String
        let username: String
        let attributedUsername: NSAttributedString?
        let message: String?
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
        var isSelected = false
        
        init(jid: String, owner: String, username: String, attributedUsername: NSAttributedString?, message: String, date: Date? = nil, state: MessageStorageItem.MessageSendingState? = nil, isMute: Bool, isSynced: Bool, status: ResourceStatus, entity: RosterItemEntity?, conversationType: ClientSynchronizationManager.ConversationType, unread: Int, unreadString: String? = nil, color: UIColor, isDraft: Bool, hasAttachment: Bool, userNickname: String?, isSystemMessage: Bool, isPinned: Bool, subRequest: Bool, isEncrypted: Bool, avatarUrl: String?, hasErrorInChat: Bool, updateTS: Double) {
            self.jid = jid
            self.owner = owner
            self.username = username
            self.attributedUsername = attributedUsername
            self.message = message
            self.date = date
            self.state = state
            self.isMute = isMute
            self.isSynced = isSynced
            self.status = status
            self.entity = entity
            self.conversationType = conversationType
            self.unread = unread
            self.unreadString = unreadString
            self.color = color
            self.isDraft = isDraft
            self.hasAttachment = hasAttachment
            self.userNickname = userNickname
            self.isSystemMessage = isSystemMessage
            self.isPinned = isPinned
            self.subRequest = subRequest
            self.isEncrypted = isEncrypted
            self.avatarUrl = avatarUrl
            self.hasErrorInChat = hasErrorInChat
            self.updateTS = updateTS
        }
    }
    
    internal var datasource = [Datasource]()
    internal var chatsDataset: Results<LastChatsStorageItem>? = nil
    internal var activityItems = [Any]()
    internal var activity: UIActivity? = nil
    
    internal let containerView: UIView = {
        let view = UIView(frame: .zero)
        
        return view
    }()
    
    internal let button: UIButton = {
        let button = UIButton()
        var config = UIButton.Configuration.filled()
        config.title = "Send"
        config.baseBackgroundColor = .systemBlue
        button.configuration = config
        button.isEnabled = false
        
        return button
    }()
    
    internal let tableView: UITableView = {
        let view = UITableView()
        view.register(ChatListTableViewCell.self, forCellReuseIdentifier: ChatListTableViewCell.cellName)
        view.backgroundColor = .white
        view.allowsMultipleSelection = true
        
        return view
    }()
    
    internal var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.searchBar.placeholder = "Search"
        
        controller.searchBar.searchBarStyle = .prominent
        controller.searchBar.placeholder = "Search contacts and messages".localizeString(id: "search_contacts_and_messages", arguments: [])
        controller.searchBar.isTranslucent = true
        controller.hidesNavigationBarDuringPresentation = true
        controller.definesPresentationContext = true
        
        return controller
    }()
    
    override func subscribe() {
        load()
        loadDatasource()
    }
    
    override func setupSubviews() {
        title = "Share"
        
        view.backgroundColor = .systemBackground
        
        navigationItem.searchController = searchController
        if #available(iOS 16.0, *) {
            navigationItem.preferredSearchBarPlacement = .stacked
        }
        navigationItem.hidesSearchBarWhenScrolling = false
        
        searchController.searchResultsUpdater = self
        
        let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom ?? 0
        
        view.addSubview(tableView)
        tableView.fillSuperviewWithOffset(top: 0, bottom: 44 + 16 + bottomInset, left: 0, right: 0)
        tableView.dataSource = self
        tableView.delegate = self
        
        view.addSubview(containerView)
        containerView.addSubview(button)
        button.addTarget(self, action: #selector(onButtonPressed), for: .touchUpInside)
    }
    
    override func loadDatasource() {
        datasource = chatsDataset?.map { item in
            let username = item.rosterItem?.displayName ?? item.jid
            var attributedUsername: NSAttributedString? = nil
                            
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
                } catch {
                    DDLogDebug("XabberActivityViewController: \(#function). \(error.localizedDescription)")
                }
                
                attributedTitle.append(NSAttributedString(string: username, attributes: [
                    .foregroundColor: color,
                    .font: UIFont.systemFont(ofSize: 17, weight: .medium)
                ]))
                attributedUsername = attributedTitle as NSAttributedString
            }
            
            let primaryResource = item.rosterItem?.getPrimaryResource()
            
            var message: String? = nil
            if let messageItem = item.lastMessage {
                if messageItem.references.isNotEmpty {
                    message = messageItem.references.last?.mimeType ?? "file" + " " + (item.lastMessage?.references.last?.sizeInBytes ?? "")
                } else {
                    message = messageItem.body
                }
            }
            
            return Datasource(
                jid: item.jid,
                owner: item.owner,
                username: username,
                attributedUsername: attributedUsername,
                message: message ?? "No messages",
                date: item.messageDate,
                state: item.lastMessage?.state,
                isMute: item.isMuted,
                isSynced: item.isSynced,
                status: primaryResource?.status ?? .offline,
                entity: primaryResource?.entity ?? .contact,
                conversationType: item.conversationType,
                unread: item.unread,
                color: AccountManager.shared.users.count <= 1 ? .clear : AccountColorManager.shared.primaryColor(for: item.owner),
                isDraft: item.draftMessage != nil,
                hasAttachment: item.lastMessage?.isHasAttachedMessages ?? false,
                userNickname: item.lastMessage?.groupchatDisplayedNickname,
                isSystemMessage: [.system, .initial].contains(item.lastMessage?.displayAs),
                isPinned: item.isPinned,
                subRequest: false,
                isEncrypted: [.omemo, .axolotl, .omemo1].contains(item.conversationType),
                avatarUrl: item.rosterItem?.avatarMinUrl ?? item.rosterItem?.avatarMaxUrl ?? item.rosterItem?.oldschoolAvatarKey,
                hasErrorInChat: item.hasErrorInChat,
                updateTS: item.updateTS
            )
        } ?? []
    }
    
    internal func load(jidFilter: String? = nil) {
        do {
            if let jidFilter = jidFilter,
               jidFilter != "" {
                let realm = try WRealm.safe()
                chatsDataset = realm.objects(LastChatsStorageItem.self).filter("owner IN %@ AND (jid CONTAINS[cd] %@ OR rosterItem.customUsername CONTAINS[cd] %@ OR rosterItem.username CONTAINS[cd] %@)", AccountManager.shared.users, jidFilter, jidFilter,  jidFilter)
                    .sorted(byKeyPath: "messageDate", ascending: false)
            } else {
                let realm = try WRealm.safe()
                chatsDataset = realm.objects(LastChatsStorageItem.self).filter("owner == %@", self.owner)
                    .sorted(byKeyPath: "messageDate", ascending: false)
            }
        } catch {
            DDLogDebug("XabberActivityViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func onAppear() {
        navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        navigationController?.navigationBar.shadowImage = nil
        
        let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom ?? 0
        containerView.frame = CGRect(x: 0, y: view.bounds.height - 44 - bottomInset, width: self.view.bounds.width, height: 44)
        
        button.fillSuperviewWithOffset(top: 0, bottom: 0, left: 10, right: 10)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        activity?.activityDidFinish(true)
    }
    
    @objc
    func onButtonPressed() {
        var url: NSURL? = nil
        var image: UIImage? = nil
        
        activityItems.forEach { item in
            if let itemUrl = item as? NSURL {
                url = itemUrl
                
            } else if let itemImage = item as? UIImage {
                image = itemImage
                
            }
        }
        
        guard let url = url?.absoluteURL,
              let image = image else {
            return
        }
        
        for chat in datasource {
            if !chat.isSelected {
                continue
            }
            
            let item = MessageReferenceStorageItem()
            item.kind = .media
            item.owner = chat.owner
            item.jid = chat.jid
            item.conversationType = chat.conversationType
            item.mimeType = MimeIcon(MimeType(url: url).value).value.rawValue
            item.temporaryData = image.jpegData(compressionQuality: 0.9)
            item.metadata = [
                "name": "Image".localizeString(id: "chat_message_image", arguments: []),
                "filename": url.lastPathComponent,
                "size": item.temporaryData?.count ?? 0,
                "media-type": "image/jpeg",
                "uri": url.absoluteString,
                "width": image.size.width,
                "height": image.size.height,
            ]
            
            ImageCache.default.store(image, forKey: url.absoluteString)
            item.primary = UUID().uuidString
            item.localFileUrl = item.temporaryData?.saveToTemporaryDir(name: url.lastPathComponent)
            
            AccountManager.shared.find(for: chat.owner)?.action({ user, stream in
                user.messages.sendMediaMessage([item], to: chat.jid, forwarded: [], conversationType: chat.conversationType)
            })
            
        }
        
        activity?.activityDidFinish(true)
    }
}

extension XabberActivityViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let filter = searchController.searchBar.text
        load(jidFilter: filter)
        loadDatasource()
        tableView.reloadData()
    }
}
