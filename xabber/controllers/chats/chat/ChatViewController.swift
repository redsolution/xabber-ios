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

import UIKit
import RealmSwift
import RxSwift
import RxRealm
import RxCocoa
import Kingfisher
import AudioToolbox
import DeepDiff
import MaterialComponents.MDCPalettes
import CocoaLumberjack
import AVFoundation
import XMPPFramework.XMPPJID

class ChatViewController: MessagesViewController {
    
    enum TopPanelState: String {
        case none = "none"
        case pinnedMessage = "pinned"
        case addContact = "add_contact"
        case requestSubscribtion = "request_subscribtion"
        case allowSubscribtion = "allow_subscribtion"
        case requestedVerification = "requested_verification"
        case enterCodeVerification = "enter_code_verification"
        case requestingVerification = "requesting_verification"
        case shouldRequestVerification = "should_request_verification"
        case acceptedVerification = "accepted_verification"
    }
    
    enum InputBarState {
        case short
        case normal
        case selection
    }
    
    enum NavigationBarStyle {
        case normal
        case selection
    }
    
    enum BackgroundColor: String, CaseIterable {
        case purple = "purple"
        case darkRed = "darkRed"
        case lightRed = "lightRed"
        case yellowOrange = "yellowOrange"
        case yellowBlue = "yellowBlue"
        case lightGreen = "lightGreen"
        case greenBlue = "greenBlue"
        case lightBlue = "lightBlue"
    }
    
    class PlayingAudioCell {
        var indexPath: IndexPath
        var isForward: Bool
        var index: Int?
        var messageId: String?
        var isPlaying: Bool
        
        init(indexPath: IndexPath, isForward: Bool, index: Int?, messageId: String?, isPlaying: Bool) {
            self.indexPath = indexPath
            self.isForward = isForward
            self.index = index
            self.messageId = messageId
            self.isPlaying = isPlaying
        }
    }
    
    struct Datasource: MessageType, DiffAware {
        
        var diffId: String {
            get {
                return primary
            }
        }
        
        var primary: String
        var jid: String
        var owner: String
        var outgoing: Bool
        var sender: Sender
        var messageId: String
        var sentDate: Date
        var editDate: Date?
        var kind: MessageKind
        var withAuthor: Bool
        var withAvatar: Bool
        var error: Bool
        var errorType: String
        var canPinMessage: Bool
        var canEditMessage: Bool
        var canDeleteMessage: Bool
        var forwards: [MessageForwardsInlineStorageItem.Model]
        var isOutgoing: Bool
        var isEdited: Bool
        var groupchatAuthorRole: String
        var groupchatAuthorId: String
        var groupchatAuthorNickname: String
        var groupchatAuthorBadge: String
        var isHasAttachedMessages: Bool
        var isDownloaded: Bool
        var state: MessageStorageItem.MessageSendingState
        var searchString: String?
        var errorMetadata: [String: Any]? = nil
        var burnDate: Double
        var afterburnInterval: Double
        var archivedId:  String?
        var isRead: Bool
        var selectedSearchResultId: String? = nil
        var references: [MessageReferenceStorageItem.Model] = []
        
        static func compareContent(_ a: ChatViewController.Datasource, _ b: ChatViewController.Datasource) -> Bool {
            return a.primary == b.primary &&
                a.sentDate == b.sentDate &&
                a.isEdited == b.isEdited &&
                a.state == b.state &&
                a.groupchatAuthorId == b.groupchatAuthorId &&
                a.groupchatAuthorNickname == b.groupchatAuthorNickname &&
                a.groupchatAuthorBadge == b.groupchatAuthorBadge &&
                a.withAuthor == b.withAuthor &&
                a.isDownloaded == b.isDownloaded &&
                a.searchString == b.searchString &&
                a.burnDate == b.burnDate &&
                a.archivedId == b.archivedId &&
                a.isRead == b.isRead &&
                ChatViewController.Datasource.iconForMetadata(for: a.errorMetadata) == ChatViewController.Datasource.iconForMetadata(for: b.errorMetadata) &&
                a.selectedSearchResultId == b.selectedSearchResultId
        }
        
        static func iconForMetadata(for meta: [String: Any]?) -> String? {
            guard let meta = meta else {
                return nil
            }
            let keys = [
                "certValid",
                "certConfirmed",
                "signed",
                "signDecrypted",
                "signValid"]
            var result = true
            keys.forEach {
                key in
                if let value = meta[key] as? Bool,
                   value == false {
                    result = false
                }
            }
            if result {
                return "shield.checkered"
            } else {
                return "exclamationmark.triangle.fill"
            }
        }
    }
    
    var isFirstAppear: Bool = true
    
    public static let datasourcePageSize: Int = 100
    public static let datasourceInitialPageSize: Int = 40
    public final var canUpdateDataset: Bool = true
    
    internal let gapLength: Int = 200
    internal var currentGap: Int = 0
    
    internal var groupchat: Bool {
        get {
            return self.conversationType == .group
        }
    }
    
    
    public var conversationType: ClientSynchronizationManager.ConversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
    public var entity: RosterItemEntity = .contact
    public var groupchatDescr: String = ""
    
    internal var messagesCount: Int = ChatViewController.datasourceInitialPageSize
    internal var lastBottomIndex: Int = 0
    internal var shouldChangeOffsetOnUpdate: Bool = false
    
    var oldestMessageId: String? = nil
    var newestMessageId: String? = nil
    
    internal var bottomVisibleMessageId: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    
    internal var messagesObserver: Results<MessageStorageItem>? = nil
    
    internal var datasource: [Datasource] = []
    
    internal var bag: DisposeBag = DisposeBag()
    internal var pinBag: DisposeBag = DisposeBag()
    internal var messagesBag: DisposeBag = DisposeBag()
    internal var messagesUpdaterBag: DisposeBag = DisposeBag()
    
    var opponentSender: Sender = Sender(id: "", displayName: "")
    var ownerSender: Sender = Sender(id: "", displayName: "")
    
    var isInSelectionMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    var showSkeletonObserver: BehaviorRelay<Bool> = BehaviorRelay(value: true)
//    var isSkeletonHided: Bool = false
    
    var showLoadingIndicator: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    var canLoadPage: Bool = true
    
    var accountPallete: MDCPalette = MDCPalette.blue
    var tmpUploadString: String = ""
    
    var contactStatus: String? = nil
    
    var isChatSynced: Bool = false
    
    var isAccessToPhotoGranted: Bool? = nil
    
// Status
    var statusTextObserver: BehaviorRelay<String> = BehaviorRelay(value: " ")
    var shouldShowNormalStatus: Bool = false
// Search mode
    enum SearchSeekDirection {
        case up
        case down
    }
    public var inSearchMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    public var searchResultsFinObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var searchSeekDirection: SearchSeekDirection? = nil
//    public var searchResultsIds: [String] = []
    public var selectedSearchResultId: String? = nil
// Pin message bar
    internal var pinnedMessageId: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    internal var canUnpinMessage: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var currentPinnedMessageId: String? = nil
    internal var settedPinnedMessageId: String? = nil
    internal var scrollItemIndexPath: IndexPath? = nil
//    Audio messages
    internal var recordedFileUrl: URL? = nil
    internal var recordedFileDate: Date? = nil
    internal var recordedFileReference: MessageReferenceStorageItem? = nil
    internal var isAudioMessageSendProcess: Bool = false
    internal var playingMessageIndexPath: PlayingAudioCell? = nil
    internal var playingMessageUpdateTimer: Timer? = nil
    internal var lastRecordingNotificationRequestDate: Date? = nil
//    ForwardedMessages
    var forwardedIds: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    var attachedMessagesIds: BehaviorRelay<[String]> = BehaviorRelay(value: [])
    
    var draftMessageText: BehaviorRelay<String?> = BehaviorRelay<String?>(value: nil)
//    var previousDraftMessageText: String? = nil
    var inTypingMode: BehaviorRelay<Bool?> = BehaviorRelay(value: nil)
    
    var showMyNickname: Bool = false
    
    var contactUsename: String = ""
    
    var editMessageId: BehaviorRelay<String?> = BehaviorRelay(value: nil)
//    ChatStates
    var refreshChatStateTimer: Timer? = nil
    
    var toolsButtonStateObserver: BehaviorRelay<ToolsButton.ToolsState> = BehaviorRelay(value: .hidden)
    
//    var topMenuShowObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    var searchTextObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
//    var searchTextBouncerObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    
    var messagesListDisposable: Disposable? = nil
    
    var isInitiallyDeletedGroup: Bool? = nil
    
//    var shouldUpdateMessagesCount: Bool = true
    
    var isInviteViewControllerShowed: Bool = false
    
    var omemoDeviceListTimer: Timer? = nil
    
    var watchSignatureTimer: Timer? = nil
    
    var certificateUpdateTimer: Timer? = nil
    var contactWithSigningCertificate: Bool = false
    
    var blockInputFieldByTimeSignature: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: false)
    var isTimeSignatureBlockingPanelopen: Bool = false
    
    var isTrustedDevicesBlockingPanelopen: Bool = false
    
    var shouldUpdatePreviousMessage = false
    
    var appInBackground: Bool = false
    
    var lastReadMessageId: String? = nil
    
    var selectedAfterburnId: Int = 0
    
    
    //// panel
    var topPanelShowed: Bool = false
    var topPanelState: BehaviorRelay<TopPanelState> = BehaviorRelay(value: .none)
    //MAM
    var hasActiveMamArchiveRequest: Bool = false
    var searchMessagesQueue: [MessageStorageItem] = [] {
        didSet {
            print("A")
        }
    }
    var currentSearchQueryId: String? = nil
    
    var lastVelocityYSign = 0
    var isLoadNextPage: Bool = false
    
    internal let skeletonMessages: [NSAttributedString] = {
        return (0..<30).compactMap {
            _ in
            return NSAttributedString(string: Lorem.words(Int.random(in: (4..<32))))
        }
    }()
    
    internal let updateQueue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "com.xabber.chat.updater",
            qos: .userInteractive,
            attributes: [],// [.concurrent],
            autoreleaseFrequency: .never,
            target: nil
        )
        return queue
    }()
    
    let sectionsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        
        return formatter
    }()
    
    let messageDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        
        formatter.dateFormat = "HH:mm"
        
        return formatter
    }()

    var titleButton: UIButton = {
        let button = UIButton(frame: .zero)
        
        button.backgroundColor = .clear
        
        return button
    }()
    
    var titleStack: UIStackView = {
        let stack = UIStackView()
        
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        
        return stack
    }()
    
    var titleLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.preferredFont(forTextStyle: .body).bold()
        
        return label
    }()
    
    var statusLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.preferredFont(forTextStyle: .caption2)
        if #available(iOS 13.0, *) {
            label.textColor = .secondaryLabel
        } else {
            label.textColor = .darkText
        }
        
        return label
    }()
    
//    var bottomSearchBar: SearchBar = {
//        let bar = SearchBar()
//        
//        bar.barStyle = .default
////        bar.backgroundImage = nil
//        
//        return bar
//    }()
    
    let recordingPanel: RecordingPanel = {
        let view = RecordingPanel(frame: .zero)
        
        view.isHidden = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        return view
    }()
    
    internal let toolsButton: ToolsButton = {
        let button = ToolsButton(frame: CGRect(square: 36))
        
        return button
    }()
    
    let cancelSelectionBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(barButtonSystemItem: .cancel, target: nil, action: nil)
        
        return button
    }()
    
    
    let deleteSelectionBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Clear chat", style: .done, target: nil, action: nil)
        
        return button
    }()
    
    let selectionCountLabel: UILabel = {
        let label = UILabel()
        
        label.font = UIFont.systemFont(ofSize: 17, weight: .regular)
        
        return label
    }()
    
    internal var searchBar: UISearchBar = {
        let bar = UISearchBar()
        
        bar.placeholder = "Search this chat".localizeString(id: "search_this_chat_hint", arguments: [])
        bar.showsCancelButton = true
        
        return bar
    }()
    
    internal let userBarButton: UserBarButton = {
        let button = UserBarButton(frame: CGRect(square: 42))
        
        return button
    }()
    
    internal let chatViewLoadingOverlay: UIView = {
        let view = UIView()
        
        let indicator = UIActivityIndicatorView(style: .large)
        
        indicator.startAnimating()
        
        let indicatorBackground = UIView(frame: CGRect(square: 128))
        indicatorBackground.layer.cornerRadius = 24
        indicatorBackground.layer.masksToBounds = true
        indicatorBackground.addSubview(indicator)
        indicator.centerInSuperview()
        view.addSubview(indicatorBackground)
        
        indicatorBackground.centerInSuperview()
        indicatorBackground.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.95)
        
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: indicatorBackground.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: indicatorBackground.centerYAnchor),
            indicatorBackground.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            indicatorBackground.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            indicatorBackground.widthAnchor.constraint(equalToConstant: 128),
            indicatorBackground.heightAnchor.constraint(equalToConstant: 128),
        ])
        
        view.isHidden = true
        
        return view
    }()
    
    internal var xabberInputView: ModernXabberInputView!
    
    internal var shouldRequestChatInfo: Bool = false
    
    @objc
    internal func showInfo() {
        let vc: BaseViewController
        if groupchat {
            vc = GroupchatInfoViewController()
            (vc as! GroupchatInfoViewController).footerView.chatsDelegate = self
            (vc as! GroupchatInfoViewController).chatStateDelegate = self
        } else {
            vc = ContactInfoViewController()
            (vc as! ContactInfoViewController).footerView.chatsDelegate = self
            (vc as! ContactInfoViewController).conversationType = self.conversationType
            (vc as! ContactInfoViewController).chatStateDelegate = self
        }
        vc.owner = self.owner
        vc.jid = self.jid
        showModal(vc)
    }
        
    @objc
    func clearAttachments() {
        self.forwardedIds.accept(Set<String>())
        self.attachedMessagesIds.accept([])
        self.editMessageId.accept(nil)
    }
    
    internal func configureMessagesPanel() {
        self.xabberInputView.forwardPanel.delegate = self
    }
    
    internal func configureSelectionPanel() {
        self.xabberInputView.selectionPanel.delegate = self
        self.cancelSelectionBarButton.target = self
        self.cancelSelectionBarButton.action = #selector(onCancelSelection)
        self.deleteSelectionBarButton.target = self
        self.deleteSelectionBarButton.action = #selector(onDeleteAllMessagesButtonTouchDown)
    }
        
    internal func configureRecordingPanel() {
        self.recordingPanel.cancelCallback = onCancelRecord
        self.recordingPanel.deleteCallback = onDeleteRecord
        self.recordingPanel.onPlayCallback = onRecordingPanelWillPlay
        self.recordingPanel.onPauseCallback = onRecordingPanelWillPause
        self.recordingPanel.onEndPlayingCallback = onRecordingPanelWillEnd
    }
    
    internal let cancelSearchBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(systemItem: .cancel, primaryAction: nil, menu: nil)
        
        return button
    }()
    
    func configureSearchBar() {
        self.cancelSearchBarButton.action = #selector(self.pnCancelButtonTouchUp)
        self.cancelSearchBarButton.target = self
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.searchBar.frame = CGRect(width: self.view.bounds.width - 150, height: 44)
            self.navigationItem.setLeftBarButton(UIBarButtonItem(customView: searchBar), animated: true)
            self.navigationItem.setRightBarButton(self.cancelSearchBarButton, animated: true)
//            self.navigationItem.setRightBarButtonItems([self.cancelSearchBarButton, UIBarButtonItem(customView: searchBar)], animated: true)
//            self.cancelSearchBarButton.sizeToFit()
//            self.searchBar.sizeToFit()
//            var size = self.searchBar.frame.size
//            self.searchBar.frame = CGRect(
//                origin: self.searchBar.frame.origin,
//                size: CGSize(width: size.width - 72,//self.cancelSearchBarButton.width,
//                             height: size.height)
//            )
        } else {
            self.searchBar.sizeToFit()
            self.navigationItem.setRightBarButton(UIBarButtonItem(customView: searchBar), animated: true)
        }
        self.navigationItem.titleView = nil
        self.searchBar.delegate = self
        self.navigationItem.setHidesBackButton(true, animated: true)
//        let barFrame = self.view.inputAccessoryView?.frame
//        self.bottomSearchBar.frame = barFrame ?? .zero
        self.searchBar.becomeFirstResponder()
        self.searchBar.searchTextField.becomeFirstResponder()
//        self.xabberInputView.searchPanel.isInLoadingState = false
//        self.showLoadingIndicator.accept(false)
        if self.searchMessagesQueue.isEmpty {
            self.xabberInputView.searchPanel.changeState(to: .empty)
        } else {
            self.xabberInputView.searchPanel.changeState(to: .withResults)
        }
        self.xabberInputView.changeState(to: .search)
        self.searchBar.setShowsCancelButton(true, animated: true)
        
    }
    
    public func onSearchPanelChangeConversationType(_ oldConversationType: ClientSynchronizationManager.ConversationType) {
        let vc = ChatViewController()
        vc.owner = self.owner
        vc.jid = self.jid
        switch oldConversationType {
            case .regular: vc.conversationType = .omemo
            case .omemo: vc.conversationType = .regular
            default: vc.conversationType = self.conversationType
        }
        if let rootVc = self.navigationController?.viewControllers[0] {
            self.navigationController?.setViewControllers([rootVc, vc], animated: true)
        } else {
            self.navigationController?.pushViewController(vc, animated: true)
        }
        vc.inSearchMode.accept(true)
    }
    
    func initStatus() {
        if conversationType == .saved {
            let usersCount = AccountManager.shared.users.count
            
            if usersCount > 1 {
                self.contactStatus = self.owner
                self.statusLabel.text = self.contactStatus
            }
            
            return
            
        } else if (XMPPJID(string: self.jid)?.isServer ?? false) {
            self.contactStatus = "Server"
            self.statusLabel.text = self.contactStatus
            return
            
        }
        
        do {
            let realm = try WRealm.safe()
            
            if let item = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: RosterStorageItem.genPrimary(jid: self.jid, owner: self.owner)) {
                    switch item.subscribtion {
                        case .none:
                            switch item.ask {
                                case .in, .both:
                                    self.topPanelState.accept(.allowSubscribtion)
                                default:
                                    if [.addContact, .requestSubscribtion].contains(self.topPanelState.value) {
                                        self.topPanelState.accept(.none)
                                    }
                            }
                        case .to:
                            switch item.ask {
                                case .in:
                                    self.topPanelState.accept(.addContact)
                                default:
                                    if [.addContact, .requestSubscribtion].contains(self.topPanelState.value) {
                                        self.topPanelState.accept(.none)
                                    }
                            }
                        case .undefined:
                            switch item.ask {
                                case .in:
                                    self.topPanelState.accept(.requestSubscribtion)
                                default:
                                    if [.addContact, .requestSubscribtion].contains(self.topPanelState.value) {
                                        self.topPanelState.accept(.none)
                                    }
                            }
                        default:
                            if [.addContact, .requestSubscribtion].contains(self.topPanelState.value) {
                                self.topPanelState.accept(.none)
                            }
                    }
                    self.shouldShowNormalStatus = false
                    switch item.subscribtion {
                    case .from:
                        switch item.ask {
                            case .none:
                                self.contactStatus = "Receives your presence updates"
                                    .localizeString(id: "chat_receives_presence_updates", arguments: [])
                            case .out:
                                self.contactStatus = "Subscription request pending..."
                                    .localizeString(id: "chat_subscription_request_pending", arguments: [])
                            default:
                                break
                        }
                    case .none:
                        switch item.ask {
                        case .out, .both:
                            self.contactStatus = "Subscription request pending..."
                                .localizeString(id: "chat_subscription_request_pending", arguments: [])
                        case .in:
                            self.contactStatus = "In your contacts"
                                .localizeString(id: "contact_state_in_contact_list", arguments: [])
                        case .none:
                            self.contactStatus = "In your contacts"
                                .localizeString(id: "contact_state_in_contact_list", arguments: [])
                        }
                    case .undefined:
                        self.contactStatus = "Not in your contacts"
                            .localizeString(id: "contact_state_not_in_contact_list", arguments: [])
                    default:
                        self.shouldShowNormalStatus = true
                        break
                    }
                
            } else {
                self.contactStatus = "Not in your contacts"
                    .localizeString(id: "contact_state_not_in_contact_list", arguments: [])
//                    self.showSubscribtionBar(animated: true, state: .notInRoster)
                self.topPanelState.accept(.addContact)
                self.updateStatusText()
                return
            }
            
            let results = realm
                            .objects(ResourceStorageItem.self)
                            .filter("owner == %@ AND jid == %@", self.owner, self.jid)
                            .sorted(by: [SortDescriptor(keyPath: "timestamp", ascending: false),
                                         SortDescriptor(keyPath: "priority", ascending: false)])
            let nickname = self.opponentSender.displayName
            let offlineStatus = "last seen recently".localizeString(id: "last_seen_recently", arguments: [])
            let status = (results.first?.statusMessage.isEmpty ?? true) ? RosterUtils.shared.convertStatus(results.first?.status ?? .offline, customOfflineStatus: offlineStatus) : results.first?.statusMessage ?? RosterUtils.shared.convertStatus(results.first?.status ?? .offline, customOfflineStatus: offlineStatus)
            self.contactUsename = nickname
            self.titleLabel.attributedText = self.updateTitle()
            let statusStr = AccountManager.shared.connectingUsers.value.contains(self.owner) ? "Waiting for network...".localizeString(id: "waiting_for_network", arguments: []) : status
            if self.statusLabel.text == " " {
                self.statusLabel.text = statusStr
            }
            if self.shouldShowNormalStatus {
                self.statusTextObserver.accept(statusStr)
                self.contactStatus = status
                self.statusLabel.layoutIfNeeded()
            }
            self.titleLabel.sizeToFit()
            self.titleLabel.layoutIfNeeded()
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }

    }
    

    
    override var disablesAutomaticKeyboardDismissal: Bool {
        get {
            return true
        }
    }
    
    internal let gradient = CAGradientLayer()
    internal let backgroundView = UIView()
    internal let backgroundImage = UIImageView()
    internal let gradientView = UIView()
    
    private func configure() {
        restorationIdentifier = "CHAT_VIEW_CONTROLLER_RID"
        self.initSender()
        
        accountPallete = AccountColorManager.shared.palette(for: owner)
//        
        
        
        
        self.messagesCollectionView.prefetchDataSource = self
        self.messagesCollectionView.messagesDataSource = self
        self.messagesCollectionView.messageCellDelegate = self
        self.messagesCollectionView.messagesDisplayDelegate = self
        self.messagesCollectionView.messagesLayoutDelegate = self
        
        self.messagesCollectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
        
        
        self.messagesCollectionView.scrollsToTop = false
        self.scrollsToBottomOnKeybordBeginsEditing = false
        self.maintainPositionOnKeyboardFrameChanged = true
        
        messagesCollectionView.accountPalette = accountPallete
        
        
        (self.navigationController as? NavBarController)?.cancelButton.addTarget(self, action: #selector(additionalNavBarPanelCancelButtonTouchUpInside), for: .touchUpInside)
        
        
        toolsButton.delegate = self
        toolsButton.frame = CGRect(
            x: self.view.bounds.width - 44,
            y: self.view.bounds.height - 88 - (UIDevice.needBottomOffset ? 44 : 0),
            width: 36,
            height: 44
        )
        
        var inputHeight: CGFloat = 49
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        
        let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
        self.xabberInputView = ModernXabberInputView(frame: frame)
        self.xabberInputView.delegate = self
        self.view.addSubview(xabberInputView)
        self.view.bringSubviewToFront(xabberInputView)
        self.messagesCollectionView.keyboardDismissMode = .interactive
        self.messagesCollectionView.contentInset = UIEdgeInsets(top: inputHeight + 8, left: 0, bottom: 0, right: 0)
        if self.inSearchMode.value {
            self.configureSearchBar()
        } else {
            self.searchTextObserver.accept(nil)
            self.configureNavbar()
        }
        self.configureBackground()
        self.configureNavbar()
        self.configureInputBar()
        self.configureSelectionPanel()
        self.configureMessagesPanel()
        self.configureCertificateUpdateTimer()
        self.configureDataset()
        self.previousFrame = self.view.bounds
        self.view.addSubview(self.chatViewLoadingOverlay)
        self.chatViewLoadingOverlay.fillSuperview()
    }
    
    var previousFrame: CGRect = .zero
    
    final func configureDataset() {
        do {
            let realm = try  WRealm.safe()
            self.messagesObserver = realm
                .objects(MessageStorageItem.self)
                .filter("owner == %@ AND opponent == %@ AND isDeleted == false AND conversationType_ == %@", self.owner, self.jid, self.conversationType.rawValue)
                .sorted(byKeyPath: "date", ascending: false)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    final func configureBackground() {
        backgroundView.frame = CGRect(
            origin: CGPoint(x: 0, y: ((UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top ?? 0) + (self.navigationController?.navigationBar.frame.height ?? 0)),
            size: self.view.bounds.size
        )
//        backgroundView.frame = self.view.bounds
        backgroundImage.frame = self.view.bounds
        
        gradientView.frame = self.view.bounds
        
        gradient.frame = self.view.bounds
        
        gradient.startPoint = CGPoint(x: 0.0, y: 1.0)
        gradient.endPoint = CGPoint(x: 1.0, y: 0.0)
        
        let backgroundResourceName = SettingManager.shared.getString(for: "chat_chooseBackground") ?? "None"
        if backgroundResourceName != "None" {
            backgroundImage.image = UIImage(named: backgroundResourceName.lowercased())?
                .withRenderingMode(.alwaysTemplate)
                .resizableImage(withCapInsets: UIEdgeInsets.zero,
                                resizingMode: .tile)
            backgroundImage.tintColor = .systemBackground
            backgroundImage.alpha = 0.1
            backgroundImage.contentMode = .scaleAspectFill
        } else {
            backgroundImage.image = nil
        }
        
        if conversationType.isEncrypted {
            gradient.colors = [
                CGColor(red: 253/255, green: 216/255, blue: 25/255, alpha: 1.0),
                CGColor(red: 232/255, green: 5/255, blue: 5/255, alpha: 1.0)
            ]
        } else {
            let backgroundResourceColor = SettingManager.shared.getString(for: "chat_chooseBackgroundColor") ?? "None"
            gradient.colors = ChatViewController.getColorsForGradient(forColor: BackgroundColor(rawValue: backgroundResourceColor) ?? .purple)
        }
        
        gradientView.layer.addSublayer(gradient)
        backgroundView.addSubview(gradientView)
        backgroundView.addSubview(backgroundImage)
        backgroundView.bringSubviewToFront(backgroundImage)
//        messagesCollectionView.backgroundView =  backgroundView
        self.messagesCollectionView.backgroundColor = .clear
        self.view.addSubview(backgroundView)
        self.view.sendSubviewToBack(backgroundView)
        
    }
    
    final func configureNavbar() {
//        self.navigationController?.navigationBar.prefersLargeTitles = false
//        self.navigationController?.navigationItem.largeTitleDisplayMode = .never
//        self.navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
//        self.navigationController?.navigationBar.shadowImage = UIImage()
//        self.navigationController?.navigationBar.superview?.bringSubviewToFront(self.navigationController!.navigationBar)
//        self.navigationController?.navigationBar.layoutIfNeeded()

        userBarButton.gradient.colors = [UIColor.white.cgColor,
                                         AccountColorManager.shared.palette(for: self.owner).tint700.cgColor]
        
        self.titleStack.addArrangedSubview(titleLabel)
        self.titleStack.addArrangedSubview(statusLabel)
        self.titleButton.addSubview(titleStack)
        self.titleStack.fillSuperview()
        self.titleButton.bringSubviewToFront(titleStack)
        
        self.navigationItem.setLeftBarButton(nil, animated: true)
        let gesture = UITapGestureRecognizer(target: self, action: #selector(self.showInfo))
        self.userBarButton.addGestureRecognizer(gesture)
        self.navigationItem.setRightBarButton(UIBarButtonItem(customView: self.userBarButton), animated: true)
        self.navigationItem.backButtonDisplayMode = .minimal
        self.title = ""
        self.navigationItem.leftItemsSupplementBackButton = true
        self.titleStack.isUserInteractionEnabled = false
        
        self.titleButton.addTarget(self, action: #selector(self.onTitleButtonTouchUp(_:)), for: .touchUpInside)
        self.navigationItem.titleView = titleButton
        
        self.titleButton.frame = CGRect(width: self.view.frame.width - 64, height: 40)
        self.titleLabel.attributedText = self.updateTitle()
        self.initStatus()
        
        userBarButton.configure(owner: owner, jid: jid)
        if self.conversationType == .saved {
            userBarButton.avatar.image = imageLiteral(XMPPFavoritesManagerStorageItem.imageName, dimension: 16)
            userBarButton.avatar.tintColor = AccountColorManager.shared.palette(for: owner).tint900
            userBarButton.avatar.backgroundColor = AccountColorManager.shared.palette(for: owner).tint100
            userBarButton.avatar.contentMode = .center
        }
    }
    
    final func configureInputBar() {
        if self.conversationType.isEncrypted {
            self.xabberInputView.timerButton.isHidden = self.xabberInputView.shouldHideTimer
            self.xabberInputView.timerButton.isEnabled = true
            self.xabberInputView.shouldHideTimer = false
        } else {
            self.xabberInputView.shouldHideTimer = true
            self.xabberInputView.timerButton.isHidden = true
            self.xabberInputView.timerButton.isEnabled = false
        }
        self.xabberInputView.update(screenHeight: UIScreen.main.bounds.height, keyboardHeight: 0)
        self.xabberInputView.searchPanel.conversationType = self.conversationType
        self.xabberInputView.searchPanel.onChangeConversationTypeCallback = onSearchPanelChangeConversationType
        self.xabberInputView.searchPanel.onSeekUpCallback = self.onSearchPanelSeekUp
        self.xabberInputView.searchPanel.onSeekDownCallback = self.onSearchPanelSeekDown
        self.xabberInputView.searchPanel.onChangeViewStateCallback = self.onSearchPanelChangeChatViewState
    }
    
    override func shouldChangeFrame() {
        super.shouldChangeFrame()
        if previousFrame == self.view.bounds {
            return
        }
        self.topPanelState.accept(self.topPanelState.value)
        previousFrame = self.view.bounds
//        backgroundView.frame = self.view.bounds
        backgroundView.frame = CGRect(
            origin: CGPoint(x: 0, y: ((UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top ?? 0) + (self.navigationController?.navigationBar.frame.height ?? 0)),
            size: self.view.bounds.size
        )
        backgroundImage.frame = self.view.bounds
        
        gradientView.frame = self.view.bounds
        
        gradient.frame = self.view.bounds
        toolsButton.frame = CGRect(
            x: self.view.bounds.width - 44,
            y: self.view.bounds.height - 88 - (UIDevice.needBottomOffset ? 44 : 0),
            width: 36,
            height: 44
        )
        
        var inputHeight: CGFloat = 49 + self.xabberInputView.keyboardHeight
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        
        let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
        self.xabberInputView.setupFrames(frame)
        
        (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?
            .cache.invalidate()
        self.messagesCollectionView.reloadData()
    }
    
    private func unsubscribe() {
        NotifyManager.shared.currentDialog = nil
        self.bag = DisposeBag()
        self.messagesBag = DisposeBag()
    }
    
    override public func addObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: UIApplication.shared
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: UIApplication.shared
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.didReceiveEndOfFixHistoryTask),
            name: XMPPBackgroundTask.endFixHistoryTask,
            object: nil 
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadDatasource),
            name: .newMaskSelected,
            object: nil
        )
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
    private func didReceiveEndOfFixHistoryTask(_ notification: Notification) {
//        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
//            self.userBarButton.stopAnimation()
//        }
    }
    
    @objc
    internal func willEnterForeground() {
        NotifyManager.shared.currentDialog = [self.jid, self.owner].prp()
        appInBackground = false
        AccountManager.shared.find(for: self.owner)?.chatMarkers.updateDeleteEphemeralMessagesTimer()
//        self.updateQueue
//            .asyncAfter(deadline: .now() + 3) {
//            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
//                user.messages.readLastMessage(jid: self.jid, conversationType: self.conversationType)
//            })
//                DispatchQueue.main.async {
//                    self.canUpdateDataset = true
//                    self.runDatasetUpdateTask()
//                }
//        }
    }
    
    @objc
    private func didEnterBackground() {
//        self.unsubscribe()
        appInBackground = true
        NotifyManager.shared.currentDialog = nil
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.owner, owner: self.jid, conversationType: self.conversationType)) {
                try realm.write {
                    instance.isPrereaded = false
                }
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    override func removeObservers() {
        super.removeObservers()
        NotificationCenter.default.removeObserver(self)
    }
    
    internal func addMeteringObservers() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(didUpdateMeteringLevel),
                                               name: .recorderDidUpdateMeteringLevelNotification,
                                               object: AudioRecorder.shared)
    }
    
    internal func removeMeteringObservers() {
        NotificationCenter.default.removeObserver(self,
                                                  name: .recorderDidUpdateMeteringLevelNotification,
                                                  object: UIApplication.shared)
    }
    
    private final func initSender() {
        self.ownerSender = Sender(
            id: self.owner,
            displayName: AccountManager.shared.find(for: owner)?.username ?? ""
        )
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: RosterStorageItem.self,
                                           forPrimaryKey: [jid, owner].prp()) {
                self.opponentSender = Sender(id: jid, displayName: instance.displayName)
            } else if let instance = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: jid) {
                self.opponentSender = Sender(id: jid, displayName: instance.generatedNickname)
            } else {
                self.opponentSender = Sender(id: jid, displayName: jid)
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    var scrollToMessageTaskId: String? = nil
    var scrollToMessageArchivedId: String? = nil
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.configure()
    }
    
    override func reloadDatasource() {
        userBarButton.setMask()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        do {
            try self.subscribe()
            try self.groupSubscribtions()
            try self.encryptedSubscribtions()
            try self.subscribeOnDatasetChanges()
            self.addObservers()
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        self.shouldChangeFrame()
        var inputHeight: CGFloat = 49
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        self.messagesCollectionView.contentInset = UIEdgeInsets(top: inputHeight + 8, left: 0, bottom: 40, right: 0)
        
//        (self.navigationController as? NavBarController)?.cancelButton.addTarget(self, action: #selector(additionalNavBarPanelCancelButtonTouchUpInside), for: .touchUpInside)
        
        self.initializeDataset()
        self.lowPrioritySubscribtions()
        if self.conversationType.isEncrypted {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                if CommonConfigManager.shared.config.required_time_signature_for_messages {
                    user.x509Manager.retrieveCert(stream, for: self.jid)
                }
            })
            AccountManager.shared.find(for: self.owner)?.omemo.prepareSecretChat(wit: self.jid, success: {
                
            }, fail: {
                DispatchQueue.main.async {
                    self.showToast(error: "Can`t find any OMEMO device".localizeString(id: "message_manager_error_no_omemo", arguments: []))
                }
            })
            self.startWatchingSignatureTimer()
            if SignatureManager.shared.isSignatureSetted {
                self.onUpdateTimeSignatureBlockState(!SignatureManager.shared.isSignatureValid())
            }
        }
//        self.syncChat()
    }
    
    final func syncChat() {
        func callback() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                self.showSkeletonObserver.accept(false)
                self.oldestMessageId = self.getMessageIdAtPostionOrLast(index: self.messagesCount)
                self.newestMessageId = self.getMessageIdAtPostionOrLast(index: self.lastBottomIndex)
                self.runDatasetUpdateTask(shouldScrollToLastMessage: false)
            }
        }
        XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { stream, session in
            session.mam?.syncChat(stream, jid: self.jid, conversationType: self.conversationType, callback: callback)
        }) {
            AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                user.mam.syncChat(stream, jid: self.jid, conversationType: self.conversationType, callback: callback)
            })
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard self.isFirstAppear else { return }
        self.syncChat()
        self.canLoadPage = true
        do {
            let realm = try WRealm.safe()
            print(self.messagesCollectionView.contentOffset)
            var inputHeight: CGFloat = 57
            if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
                inputHeight += bottomInset
            }
            if let offset = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType))?.lastChatOffset {
                self.messagesCollectionView.setContentOffset(CGPoint(x: 0.0, y: offset == 0 ? -inputHeight : CGFloat(offset)), animated: false)
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }

        do {
            let realm = try WRealm.safe()
            let chat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType))
            
            if (chat?.isFreshNotEmptyEncryptedChat ?? false) {
                if (chat?.unread ?? 0) > 0 {
                    let messageId = chat?.lastMessageId ?? ""
                    AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                        user.chatMarkers.displayedById(stream, jid: self.jid, messageId: messageId)
                    })
                    try realm.write {
                        chat?.unread = 0
                    }
                }
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        self.isFirstAppear = false
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.navigationItem.backButtonDisplayMode = .minimal
//        self.navigationItem.backButtonTitle = self.titleLabel.text
        omemoDeviceListTimer?.invalidate()
        omemoDeviceListTimer = nil
        AccountManager.shared.find(for: owner)?.mam.allowHistoryFixTask = false
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.messages.readLastMessage(jid: self.jid, conversationType: self.conversationType)
        })
        LastChats.updateErrorState(for: self.jid, owner: self.owner, conversationType: self.conversationType)
        do {
            let realm = try WRealm.safe()
            let offset = self.messagesCollectionView.contentOffset.y
            try realm.write {
                realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType)
                )?.lastChatOffset = Float(offset)
                realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: self.jid,
                        owner: self.owner,
                        conversationType: self.conversationType
                    )
                )?.lastReadId = self.messagesObserver?.first?.messageId
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        
        unsubscribe()
        removeObservers()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        XMPPUIActionManager.shared.mam?.endLoadHistory(jid: self.jid, conversationType: conversationType)
        AccountManager.shared.find(for: self.owner)?.mam.endLoadHistory(jid: self.jid, conversationType: conversationType)
    }
    
    internal final func scrollToLastUnreadMessage(select: Bool = false) {
        do {
            let realm = try WRealm.safe()
            if let unreadId = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType))?.lastReadId {
                if let primary = realm.objects(MessageStorageItem.self).filter("owner == %@ AND opponent == %@ AND archivedId == %@", self.owner, self.jid, unreadId).first?.primary {
                    if let index = self.messagesObserver?.firstIndex(where: { $0.primary == primary }), index != 0 {
                        if self.messagesCollectionView.indexPathsForVisibleItems.compactMap({ return $0.section }).contains(index) {
                            return
                        }
                        let offset = (0...index).compactMap ({
                            return (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?.sizeForItem(at: IndexPath(row: 0, section: $0)).height
                        }).reduce(0, +) - ((self.view.bounds.height / 4) * 3)
                        self.messagesCollectionView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    }
                }
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    static func getColorsForGradient(forColor color: BackgroundColor) -> [CGColor] {
        switch color {
        case .purple:
            return [
                CGColor(red: 255/255, green: 122/255, blue: 245/255, alpha: 1),
                CGColor(red: 81/255, green: 49/255, blue: 98/255, alpha: 1)
            ]
            
        case .darkRed:
            return [
                CGColor(red: 205/255, green: 92/255, blue: 92/255, alpha: 0.5),
                CGColor(red: 220/255, green: 20/255, blue: 60/255, alpha: 1)
            ]
            
        case .lightRed:
            return [
                CGColor(red: 250/255, green: 128/255, blue: 114/255, alpha: 0.5),
                CGColor(red: 250/255, green: 128/255, blue: 114/255, alpha: 1)
            ]
            
        case .yellowOrange:
            return [
                CGColor(red: 255/255, green: 215/255, blue: 0/255, alpha: 1),
                CGColor(red: 255/255, green: 69/255, blue: 0/255, alpha: 1)
            ]
            
        case .yellowBlue:
            return [
                CGColor(red: 255/255, green: 215/255, blue: 0/255, alpha: 0.5),
                CGColor(red: 30/255, green: 144/255, blue: 255/255, alpha: 0.5)
            ]
            
        case .lightGreen:
            return [
                CGColor(red: 155/255, green: 255/255, blue: 150/255, alpha: 0.5),
                CGColor(red: 155/255, green: 255/255, blue: 150/255, alpha: 0.5)
            ]
            
        case .greenBlue:
            return [
                CGColor(red: 155/255, green: 255/255, blue: 150/255, alpha: 0.5),
                CGColor(red: 0/255, green: 192/255, blue: 255/255, alpha: 0.5)
            ]
            
        case .lightBlue:
            return [
                CGColor(red: 0/255, green: 192/255, blue: 255/255, alpha: 0.5),
                CGColor(red: 0/255, green: 192/255, blue: 255/255, alpha: 0.5)
            ]
            
        default:
            break
        }
    }
    
    deinit {
        self.unsubscribe()
        self.removeObservers()
        self.clearMemoryCache()
    }
}

protocol TappedPhotoInMediaGalleryDelegate {
    func didTapPhotoFromChat(primary: String)
    func didTapPhotoFromGallery(primary: String)
    func showInputBar()
}

extension ChatViewController: TappedPhotoInMediaGalleryDelegate {
    
    func showInputBar() {
        
    }
    
    func didTapPhotoFromChat(primary: String) {
//        scrollToMessage(primary: primary)
    }
    
    func didTapPhotoFromGallery(primary: String) {
//        scrollToMessage(primary: primary)
        navigationController?.popViewController(animated: true)
    }
    
}

