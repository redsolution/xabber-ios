//
//  SearchChatListViewController.swift
//  xabber
//
//  Created by Игорь Болдин on 11.09.2024.
//  Copyright © 2024 Igor Boldin. All rights reserved.
//

import Foundation
import UIKit
import DeepDiff
import RealmSwift
import RxSwift
import RxCocoa
import RxRealm
import CocoaLumberjack
import XMPPFramework

class SearchChatListViewController: SimpleBaseViewController {

    
    
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
        }
        
    }
    
    var datasource: [Datasource] = []
    
    internal var conversationType: ClientSynchronizationManager.ConversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
    
    var searchTextObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    var searchResultsObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    
    internal var isEmptyViewShowed: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    public var searchResultsIds: [String] = []
    public var selectedSearchResultId: String? = nil
    
    internal let tableView: UITableView = {
        let view = UITableView(frame: .zero, style: .plain)
        
        view.register(ChatListTableViewCell.self, forCellReuseIdentifier: ChatListTableViewCell.cellName)
        
        return view
    }()
    
    internal let searchBar: UISearchBar = {
        let bar = UISearchBar()
        
        bar.placeholder = "Search this chat".localizeString(id: "search_this_chat_hint", arguments: [])
        bar.showsCancelButton = true
        
        return bar
    }()
    
    internal let bottomBar: UITabBar = {
        let bar = UITabBar()
        
        bar.barStyle = .default
        
        return bar
    }()
    
    internal let emptyView: EmptyStateView = {
        let view = EmptyStateView()
        
        return view
    }()
    
    internal let searchPanel: ModernXabberInputView.SearchPanel = {
        let panel = ModernXabberInputView.SearchPanel(frame: .zero)
        
        panel.shouldShowSeekUpDownButtons = false
        
        return panel
    }()
    
    
    override func addObservers() {
        super.addObservers()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.keyboardWillShowNotification(_:)),
            name: UIWindow.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.keyboardWillHideNotification(_:)),
            name: UIWindow.keyboardWillHideNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.keyboardWillChangeFrameNotification(_:)),
            name: UIWindow.keyboardWillChangeFrameNotification,
            object: nil
        )
    }
    
    @objc
    func keyboardWillShowNotification(_ notification: Notification) {
        if let userInfo = notification.userInfo {
            if let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
                let frame = frameValue.cgRectValue
                let keyboardVisibleHeight = frame.size.height
                print("keyboardVisibleHeight", keyboardVisibleHeight)
                switch (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber, userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber) {
                case let (.some(duration), .some(curve)):
                    let options = UIView.AnimationOptions(rawValue: curve.uintValue)
                    UIView.animate(
                        withDuration: TimeInterval(duration.doubleValue),
                        delay: 0,
                        options: options,
                        animations: {
                            var inputHeight: CGFloat = 49 + keyboardVisibleHeight
                            let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
                            self.bottomBar.frame = frame
                            return
                        }, completion: { finished in
                    })
                default:
                    
                    break
                }
            }
        }
    }
    
    @objc
    func keyboardWillHideNotification(_ notification: Notification) {
        if let userInfo = notification.userInfo {
            if let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
                let frame = frameValue.cgRectValue
                let keyboardVisibleHeight = frame.size.height
                switch (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber, userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber) {
                case let (.some(duration), .some(curve)):
                    let options = UIView.AnimationOptions(rawValue: curve.uintValue)
                    UIView.animate(
                        withDuration: TimeInterval(duration.doubleValue),
                        delay: 0,
                        options: options,
                        animations: {
                            var inputHeight: CGFloat = 49
                            if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                                inputHeight += bottomInset
                            }
                            
                            let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
                            self.bottomBar.frame = frame
                            return
                        }, completion: { finished in
                    })
                default:
                    
                    break
                }
            }
        }
    }
    
    @objc
    func keyboardWillChangeFrameNotification(_ notification: Notification) {
        
    }
    
    override func activateConstraints() {
        super.activateConstraints()
        self.tableView.fillSuperview()
        self.emptyView.fillSuperview()
        NSLayoutConstraint.activate([
            self.searchPanel.leftAnchor.constraint(equalTo:  self.bottomBar.leftAnchor),
            self.searchPanel.rightAnchor.constraint(equalTo: self.bottomBar.rightAnchor),
            self.searchPanel.topAnchor.constraint(equalTo:   self.bottomBar.topAnchor),
            self.searchPanel.heightAnchor.constraint(equalToConstant: 49)
        ])
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        self.view.addSubview(self.tableView)
        self.emptyView.isHidden = true
        self.view.addSubview(emptyView)
        self.view.bringSubviewToFront(emptyView)
    }
    
    func configureSearchBar() {
//        self.navigationItem.setRightBarButton(UIBarButtonItem(customView: searchBar), animated: true)
        let cancelButton = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(self.onCancelButtonTouchUpInside))
        self.navigationItem.setRightBarButtonItems([cancelButton], animated: true)
        self.searchBar.sizeToFit()
        self.navigationItem.titleView = self.searchBar
        self.searchBar.delegate = self
        self.view.addSubview(self.bottomBar)
        self.bottomBar.addSubview(self.searchPanel)
        self.searchPanel.changeState(to: .empty)
//        self.searchPanel.fillSuperview()
        self.navigationItem.setHidesBackButton(true, animated: true)
        self.searchBar.becomeFirstResponder()
        self.searchBar.searchTextField.becomeFirstResponder()
        self.searchPanel.onChangeViewStateCallback = self.onChangeChatViewState
    }
    
    @objc
    private func onCancelButtonTouchUpInside(_ sender: AnyObject) {
        let vcs = self.navigationController?.viewControllers ?? []
        if vcs.count > 1 {
            let vc = vcs[vcs.count - 2] as? ChatViewController
            vc?.inSearchMode.accept(false)
            vc?.searchBar.text = nil
            vc?.searchTextBouncerObserver.accept(nil)
            vc?.searchTextObserver.accept(nil)
            vc?.updateSearchResults(value: nil)
            vc?.canUpdateDataset = true
            vc?.runDatasetUpdateTask()
        }
        self.navigationController?.popViewController(animated: true)
    }
    
    @objc
    private func onChangeChatViewState() {
        let vcs = self.navigationController?.viewControllers ?? []
        if vcs.count > 1 {
            let vc = vcs[vcs.count - 2] as? ChatViewController
            vc?.inSearchMode.accept(true)
            vc?.searchBar.text = self.searchBar.text
            vc?.searchTextBouncerObserver.accept(self.searchBar.text)
            vc?.searchTextObserver.accept(self.searchBar.text)
            vc?.updateSearchResults(value: self.searchBar.text)
            vc?.canUpdateDataset = true
            vc?.runDatasetUpdateTask()
        }
        self.navigationController?.popViewController(animated: true)
    }

    override func configure() {
        super.configure()
        self.configureSearchBar()
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.tableView.keyboardDismissMode = .interactive
        self.title = "Search messages"
        
        emptyView.configure(
            image:  imageLiteral( "rectangle.and.text.magnifyingglass", dimension: 160),
            title: "Search messages",
            subtitle: "Try to start search for this chat",
            buttonTitle: ""
        ) {
            
        }
    }
    
    override func onAppear() {
        super.onAppear()
        var inputHeight: CGFloat = 49
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        
        let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
        self.bottomBar.frame = frame
    }
    
    internal func mapDatasource(_ results: Array<MessageStorageItem>) throws -> [Datasource] {
        return try results.sorted(by: { $0.date > $1.date }).compactMap {
            messageItem in
            
            let realm = try WRealm.safe()
            guard let item = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: messageItem.opponent, owner: messageItem.owner, conversationType: messageItem.conversationType)) else {
                return nil
            }
            
            if (XMPPJID(string: item.jid)?.isServer ?? false) && item.conversationType != .saved {
                return nil
            }
            
            let subscriptionRequest: Bool = item.rosterItem?.isThereSubscriptionRequest() ?? false
            
            let primaryResource = item.rosterItem?.getPrimaryResource()
            
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
                state: messageItem.outgoing ? messageItem.state : nil,
                isMute: item.isMuted,
                isSynced: item.isSynced,
                status: primaryResource?.status ?? .offline,
                entity: primaryResource?.entity ?? .contact,
                conversationType: item.conversationType,
                unread: messageItem.outgoing ? 0 : item.unread,
                unreadString: isInvite ? "1" : nil,
                color: AccountManager.shared.users.count <= 1 ? .clear : AccountColorManager.shared.primaryColor(for: item.owner),
                isDraft: false,
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
    }
    
    var currentQueryId: String? = nil
    var messagesQueue: [MessageStorageItem] = []
    
    override func subscribe() {
        super.subscribe()
        
        isEmptyViewShowed
            .asObservable()
            .subscribe(onNext: { (value) in
                self.emptyView.isHidden = !value
            })
            .disposed(by: bag)
        
        searchTextObserver
            .asObservable()
            .debounce(.milliseconds(250), scheduler: MainScheduler.asyncInstance)
            .subscribe(onNext: { (value) in
                if value == nil {
                    self.searchPanel.changeState(to: .empty)
                    self.datasource = []
                    self.tableView.reloadData()
                    if !self.isEmptyViewShowed.value {
                        self.isEmptyViewShowed.accept(true)
                    }
                } else {
                    self.searchPanel.changeState(to: .withResults)
                    if self.isEmptyViewShowed.value {
                        self.isEmptyViewShowed.accept(false)
                    }
                }
                
                if let value = value {
                    self.messagesQueue = []
                    XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                        session.mam?.temporaryMessageReceiverDelegate = self
                        self.currentQueryId = session.mam?.searchText(stream, jid: self.jid, conversationType: self.conversationType, text: value)
                    } fail: {
                        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                            user.mam.temporaryMessageReceiverDelegate = self
                            self.currentQueryId = user.mam.searchText(stream, jid: self.jid, conversationType: self.conversationType, text: value)
                        })
                    }
                }
            })
            .disposed(by: bag)
        
        searchResultsObserver
            .asObservable()
            .debounce(.milliseconds(100), scheduler: MainScheduler.asyncInstance)
            .subscribe { _ in
                do {
                    self.datasource = try self.mapDatasource(self.messagesQueue)
                    self.tableView.reloadData()
                    self.searchPanel.updateResults(current: -1, total: self.datasource.count)
                } catch {
                    DDLogDebug("SearchChatListViewController: \(error.localizedDescription). \(#function)")
                }
            }
            .disposed(by: bag)

    }
    
}

extension SearchChatListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 84
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        self.navigationController?.popViewController(animated: true)
    }
}

extension SearchChatListViewController: TemporaryMessageReceiverProtocol {
    func didReceiveMessage(_ item: MessageStorageItem, queryId: String) {
        if queryId == self.currentQueryId {
            self.messagesQueue.append(item)
            self.searchResultsObserver.accept(item.primary)
        }
    }
    
    
}

extension SearchChatListViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return datasource.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatListTableViewCell.cellName, for: indexPath) as? ChatListTableViewCell else {
            fatalError()
        }
        
        let item = self.datasource[indexPath.row]
        
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
    
    
}

extension SearchChatListViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
//        searchBar.resignFirstResponder()
    }
    
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        searchBar.endEditing(true)
        self.becomeFirstResponder()
    }
    
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        print(searchText)
        searchTextObserver.accept(searchText.isEmpty ? nil : searchText)
    }
}
