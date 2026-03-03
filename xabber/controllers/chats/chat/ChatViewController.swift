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
    
    struct ChangesetItem: Hashable, Equatable {
        let index: Int
        let primary: String
        
    }
    
    class ChatPage {
        var page: Int
        var minIndex: Int
        
        var maxIndex: Int
        var lowArchivedId: String
        var highArchivedId: String
        var isLoading: Bool = false
        var locked: Bool = false {
            didSet {
                if !locked {
                    print("lockedDidSet")
                }
            }
        }
        var longLock: Bool = false
        
        open var isUnlocked: Bool {
            get {
                return !self.locked
            }
        }
        
        init(page: Int = 0, minIndex: Int = 0, maxIndex: Int = 0, lowArchivedId: String = "", highArchivedId: String = "", isLoading: Bool = false) {
            self.page = page
            self.minIndex = minIndex
            self.maxIndex = maxIndex
            self.lowArchivedId = lowArchivedId
            self.highArchivedId = highArchivedId
            self.isLoading = isLoading
        }
        
        public final func setPage(_ page: Int, in messages: Results<MessageStorageItem>) {
            self.page = page
            
        }
        
        public final func nextPage(autoUnlock: Bool = true, callback: (() -> Void)? = nil) {
            if self.locked {
                return
            }
            self.locked = true
            self.page += 1
            callback?()
            if autoUnlock {
                self.unlock()
            }
        }
        
        public final func prevPage(autoUnlock: Bool = true, callback: (() -> Void)? = nil) {
            if self.locked {
                return
            }
            self.locked = true
            self.page -= 1
            if self.page < 0 {
                self.page = 0
                autoreleasepool {
                    self.locked = false
                }
            } else {
                callback?()
            }
            if autoUnlock {
                self.unlock()
            }
        }
        
        public final func setCustomPage(_ newPage: Int, autoUnlock: Bool = true, callback: (() -> Void)? = nil) {
            if self.locked {
                return
            }
            self.locked = true
            self.page = newPage
            callback?()
            if autoUnlock {
                self.unlock()
            }
        }
        
        public final func prevPage() {
            self.page -= 1
        }
        
        public final func indexInPage(_ index: Int) -> Bool {
            return self.minIndex <= index && index <= self.maxIndex
        }
        
        public final func unlock() {
//            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.locked = false
//            }
        }
    }
    
    struct ChangesWithIndexSet {
        let inserts: IndexSet
        let deletes: IndexSet
        var replaces: IndexSet
        let moves: [(from: IndexPath, to: IndexPath)]
    }
    
    enum ChatDirection {
        case up
        case down
    }
    
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
        case audioPlayer = "audio_player"
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
    
    struct PlayingAudioCell {
        let indexPath: IndexPath
        let isForward: Bool
        let index: Int?
        let messageId: String?
        let isPlaying: Bool
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
        var forwards: [MessageAttachment]
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
        var queryIds: String?
        var isRead: Bool
        var selectedSearchResultId: String? = nil
        var isHadHistoryGap: Bool = false
        var tailed: Bool = false
        var isFakeMessage: Bool = false
        
        var images: [ImageAttachment]
        var videos: [VideoAttachment]
        var files:  [FileAttachment]
        var audios: [AudioAttachment]
        
        var timeMarkerText: NSAttributedString
        
        var indicator: IndicatorType
        
        var avatarUrl: String?
        var attributedAuthor: NSAttributedString? = nil
        
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
                a.selectedSearchResultId == b.selectedSearchResultId &&
                a.queryIds == b.queryIds &&
//                a.tailed == b.tailed &&
                a.indicator == b.indicator &&
                a.editDate == b.editDate &&
                a.avatarUrl == b.avatarUrl
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
        
    let datasourcePageSize: Int = 100
        
    var conversationType: ClientSynchronizationManager.ConversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular

    var currentPage: ChatPage = ChatPage()
    
    var chatScrollDirection: ChatDirection? = nil
    var previousContentOffsetY: CGFloat = .zero
    
    var unreadMessagePositionId: Int? = nil
    
    var messageCorner: MessageStyleConfig.MessageBubbleContainer.CodingKeys = .noTail
    var avatarVerticalPosition: String = "bottom"
    var cornerRadius: String = "16"
    
// datasource
    var messagesObserver: Results<MessageStorageItem>!
    var datasource: [Datasource] = [] {
        didSet {
            print("SETTED")
        }
    }
    
    
    var sharedPlayerPaneldelegae: SharedAudioPlayerPanelDelegate? = nil
// rx
    var bag: DisposeBag = DisposeBag()
    
// senders
    var opponentSender: Sender = Sender(id: "", displayName: "")
    var ownerSender: Sender = Sender(id: "", displayName: "")
    
    var isInSelectionMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
// skeleton
    var showSkeletonObserver: BehaviorRelay<Bool> = BehaviorRelay(value: true)

    var showLoadingIndicator: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    var accountPallete: MDCPalette = MDCPalette.blue

    var contactStatus: String? = nil
    
// gallery
    var isAccessToPhotoGranted: Bool? = nil
    
// Status
    var statusTextObserver: BehaviorRelay<String> = BehaviorRelay(value: " ")
    var shouldShowNormalStatus: Bool = false

// Pin message bar
    internal var pinnedMessageId: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    internal var canUnpinMessage: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var currentPinnedMessageId: String? = nil
    internal var settedPinnedMessageId: String? = nil
    internal var scrollItemIndexPath: IndexPath? = nil

// draft
    var draftMessageText: BehaviorRelay<String?> = BehaviorRelay<String?>(value: nil)
    
// ForwardedMessages
    var forwardedIds: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    var attachedMessagesIds: BehaviorRelay<[String]> = BehaviorRelay(value: [])
    var inTypingMode: BehaviorRelay<Bool?> = BehaviorRelay(value: nil)
    
// edit messages
    var editMessageId: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    
// ChatStates
    var refreshChatStateTimer: Timer? = nil

// signature and encrypted
    var omemoDeviceListTimer: Timer? = nil
    var watchSignatureTimer: Timer? = nil
    var certificateUpdateTimer: Timer? = nil
    var contactWithSigningCertificate: Bool = false
    var blockInputFieldByTimeSignature: BehaviorRelay<Bool> = BehaviorRelay<Bool>(value: false)
    var isTimeSignatureBlockingPanelopen: Bool = false
    var isTrustedDevicesBlockingPanelopen: Bool = false
// burn
    var selectedAfterburnId: Int = 0
// panel
    var topPanelShowed: Bool = false
    var topPanelState: BehaviorRelay<TopPanelState> = BehaviorRelay(value: .none)
// search
    var searchMessagesQueue: [MessageStorageItem] = []
    var searchTextObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    var currentSearchQueryId: String? = nil
    var inSearchMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    var searchSeekDirection: ChatDirection? = nil
    var selectedSearchResultId: String? = nil
// floating date
//    var indexPathOfPinnedDate: IndexPath? = nil
//    var dateViews: [FloatDateView] = []
//    var originalFrames: [CGRect] = []
//    var pinnedDateFrame: CGRect = .zero
//    var pinnedDateIndex: Int? = nil
//    var nextPinnedDateIndex: Int? = nil
    
    internal var updateFloatingDateObserverSignal: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var hideFloatingDateObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var showFloatingDateObserver: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var preventHidingDate: Bool = false
    
    internal var shouldShowInitialMessage: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    internal var canLoadDatasource: Bool = false
    internal var loadDatasourceObserver: BehaviorRelay<Bool> = BehaviorRelay(value: true)
    
    internal var messagesToReadObserver: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set())
    
    internal let pinnedDateView: FloatDateView = {
        let view = FloatDateView(frame: .zero)
        
        return view
    }()
    
    internal lazy var skeletonMessages: [NSAttributedString] = {
        return (0..<30).compactMap {
            _ in
            return NSAttributedString(string: Lorem.words(Int.random(in: (18..<84))))
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

    internal let initialMessageOverlayView: InitialMessageOverlayView = {
        let view = InitialMessageOverlayView(frame: .zero)
        
        view.isHidden = true
        
        return view
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
    
//    let recordingPanel: RecordingPanel = {
//        let view = RecordingPanel(frame: .zero)
//        
//        view.isHidden = true
//        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
//        
//        return view
//    }()
    
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
    
//    internal var searchBar: UISearchBar = {
//        let bar = UISearchBar()
//        
//        bar.placeholder = "Search this chat".localizeString(id: "search_this_chat_hint", arguments: [])
//        bar.showsCancelButton = true
//        
//        return bar
//    }()
    internal var searchBar: UISearchBar = {
        let bar = UISearchBar()
        bar.placeholder = "Search this chat".localizeString(id: "search_this_chat_hint", arguments: [])
        // iOS 26+ : Align with Liquid Glass (translucent, fluid styling)
        if #available(iOS 26.0, iPadOS 26.0, *) {
            bar.tintColor = UIColor.systemBlue  // Matches iOS 26's vibrant accents; adjust for theme
            bar.overrideUserInterfaceStyle = .unspecified  // Ensures adaptation to system translucency
            bar.backgroundImage = UIImage()  // Optional: Makes background more transparent for Liquid Glass effect
        }
        return bar
    }()
    
    internal let userBarButton: UserBarButton = {
        let button = UserBarButton(frame: CGRect(square: 42))
        
        return button
    }()
    
    internal let chatViewLoadingOverlay: UIView = {
        let view = UIView()
        
        view.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        
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
    
    internal var shouldShowScrollDownButton: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    internal var contentOffsetObserver: BehaviorRelay<CGFloat> = BehaviorRelay(value: 0)
    
    internal var currentPlayingView: InlineAudiosGridView.AudioView? = nil
    
    internal let scrollDownButton: UIButton = {
        let button = UIButton(frame: CGRect(square: 38))
        
        button.layer.cornerRadius = 19
        button.layer.masksToBounds = true
        
        button.backgroundColor = .systemGroupedBackground
        
        button.setImage(imageLiteral("chevron.down"), for: .normal)
        
        return button
    }()
    
    internal let dateListContainerView: UIView = {
        let view = UIView()
        
        view.isUserInteractionEnabled = false
        
        return view
    }()
    
//    internal let navbarOverlayView: UIView = {
//        let view = UIView()
//        
//        view.backgroundColor = .systemBackground
//        view.isUserInteractionEnabled = false
//        
//        return view
//    }()
    
    let recordLockIndicator: UIButton = {
        let button = UIButton(frame: CGRect(square: 38))
        
        button.setImage(imageLiteral("lock.open.fill"), for: .normal)
        button.backgroundColor = .systemGroupedBackground
        button.layer.cornerRadius = 19
        button.layer.masksToBounds = true
//        button.layer.borderWidth = 0
//        button.layer.borderColor = UIColor.secondarySystemBackground.cgColor
        
        if #available(iOS 17.0, *) {
            button.isSymbolAnimationEnabled = true
        }
        
        button.isHidden = true
        
        return button
    }()
    
    
    
    internal var xabberInputView: ModernXabberInputView!
    
    internal var shouldRequestChatInfo: Bool = false
    
    open var lastChatsDisplayDelegate: LastChatsDisplayDelegate? = nil
    var leftMenuDelegate: LeftMenuSelectRootScreenDelegate? = nil
    
    internal let sharedAudioPlayerPanel: SharedPlayerView? = {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return nil
        }
        let view = SharedPlayerView(frame: .zero)
        
        return view
    }()
    
    @objc
    internal func showInfo() {
        let vc: BaseViewController
        if self.conversationType == .group {
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
        showModal(vc, parent: self)
        self.removeObservers()
    }
    
    @objc
    internal func onScrollDownChatButtonTouchUpInside(_ sender: UIButton) {
        self.scrollToLastOrUnreadItem()
    }
        
    @objc
    func clearAttachments() {
        self.forwardedIds.accept(Set<String>())
        self.attachedMessagesIds.accept([])
        self.editMessageId.accept(nil)
    }
    
    internal func configureMessagesPanel() {
        self.xabberInputView.forwardPanel.delegate = self
        self.xabberInputView.editPanel.delegate = self
    }
    
    internal func configureSelectionPanel() {
        self.xabberInputView.selectionPanel.delegate = self
        self.cancelSelectionBarButton.target = self
        self.cancelSelectionBarButton.action = #selector(onCancelSelection)
        self.deleteSelectionBarButton.target = self
        self.deleteSelectionBarButton.action = #selector(onDeleteAllMessagesButtonTouchDown)
    }
        

    
    internal let cancelSearchBarButton: UIBarButtonItem = {
        let button = UIBarButtonItem(title: "Cancel", style: .plain, target: nil, action: nil)
        if #available(iOS 26.0, *) {
            button.hidesSharedBackground = true
        }
        return button
    }()
    
    static func getUsernamePalette(for jid: String) -> MDCPalette {
        let palettes: [MDCPalette] = [
            .red,
            .pink,
            .purple,
            .deepPurple,
            .indigo,
            .blue,
            .lightBlue,
            .cyan,
            .teal,
            .green,
            .lightGreen,
            .lime,
            .yellow,
            .amber,
            .orange,
            .deepOrange,
            .brown,
            .grey,
            .blueGrey
        ]
        
        let hash = jid.utf8.reduce(0) { (result, char) in
            return ((result << 5) &+ result) ^ Int(char)
        }
        
        let index = abs(hash) % palettes.count
        
        return palettes[index]
    }
    
    func configureSearchBar() {
        if #available(iOS 26.0, *) {
            self.cancelSearchBarButton.action = #selector(self.pnCancelButtonTouchUp)
            self.cancelSearchBarButton.target = self
            if UIDevice.current.userInterfaceIdiom == .pad {
                self.searchBar.frame = CGRect(width: self.view.bounds.width - 150, height: 44)
                self.cancelSearchBarButton.hidesSharedBackground = true
//                self.searchBar.searchBarStyle = .minimal
                searchBar.backgroundImage = UIImage()  // Strips default background/borders
                searchBar.layer.shadowOpacity = 0      // Removes outer shadow
                searchBar.layer.shadowRadius = 0
                searchBar.layer.shadowOffset = .zero
                searchBar.layer.shadowColor = UIColor.clear.cgColor

                // For iOS 13+ (your case), minimal style enhances clean look
                
                searchBar.searchBarStyle = .default
                searchBar.showsCancelButton = true
                searchBar.searchTextField.layer.shadowOpacity = 0
                searchBar.searchTextField.layer.shadowRadius = 0
                searchBar.searchTextField.layer.shadowOffset = .zero
                searchBar.searchTextField.layer.shadowColor = UIColor.clear.cgColor
                searchBar.searchTextField.backgroundColor = .clear
                searchBar.searchTextField.borderStyle = .roundedRect
                let panel = UIBarButtonItem(customView: searchBar)
                panel.hidesSharedBackground = true
                self.navigationItem.setRightBarButtonItems([self.cancelSearchBarButton, panel], animated: true)
//                self.navigationItem.setRightBarButton(self.cancelSearchBarButton, animated: true)
            } else {
                self.searchBar.sizeToFit()
                let panel = UIBarButtonItem(customView: searchBar)
                panel.hidesSharedBackground = true
                self.navigationItem.setRightBarButton(panel, animated: true)
            }
            self.navigationItem.titleView = nil
            self.searchBar.delegate = self
            self.navigationItem.setHidesBackButton(true, animated: true)
            self.searchBar.becomeFirstResponder()
            self.searchBar.searchTextField.becomeFirstResponder()
            if self.searchMessagesQueue.isEmpty {
                self.xabberInputView.searchPanel.changeState(to: .empty)
            } else {
                self.xabberInputView.searchPanel.changeState(to: .withResults)
            }
            self.xabberInputView.changeState(to: .search)
            self.searchBar.setShowsCancelButton(true, animated: true)
        } else {
            self.cancelSearchBarButton.action = #selector(self.pnCancelButtonTouchUp)
            self.cancelSearchBarButton.target = self
            if UIDevice.current.userInterfaceIdiom == .pad {
                self.searchBar.frame = CGRect(width: self.view.bounds.width - 150, height: 44)
                self.navigationItem.setLeftBarButton(UIBarButtonItem(customView: searchBar), animated: true)
                self.navigationItem.setRightBarButton(self.cancelSearchBarButton, animated: true)
            } else {
                self.searchBar.sizeToFit()
                self.navigationItem.setRightBarButton(UIBarButtonItem(customView: searchBar), animated: true)
            }
            self.navigationItem.titleView = nil
            self.searchBar.delegate = self
            self.navigationItem.setHidesBackButton(true, animated: true)
            self.searchBar.becomeFirstResponder()
            self.searchBar.searchTextField.becomeFirstResponder()
            if self.searchMessagesQueue.isEmpty {
                self.xabberInputView.searchPanel.changeState(to: .empty)
            } else {
                self.xabberInputView.searchPanel.changeState(to: .withResults)
            }
            self.xabberInputView.changeState(to: .search)
            self.searchBar.setShowsCancelButton(true, animated: true)
        }
        
    }
    
    func configureSearchBarT() {
        // Configure cancel button action
        self.cancelSearchBarButton.action = #selector(self.pnCancelButtonTouchUp)
        self.cancelSearchBarButton.target = self
        
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad: Dynamic width based on nav bar (handles iPadOS 26 multitasking/menu bar)
            let navBarWidth = self.navigationController?.navigationBar.frame.width ?? self.view.bounds.width
            self.searchBar.frame = CGRect(x: 0, y: 0, width: navBarWidth - 150, height: 44)
//            self.navigationItem.setLeftBarButton(UIBarButtonItem(customView: searchBar), animated: true)
            
            if #available(iOS 26.0, *) {
                let barButtonItem = UIBarButtonItem(customView: searchBar)
                barButtonItem.sharesBackground = false  // Prevents merging with adjacent buttons
                navigationItem.leftBarButtonItem = barButtonItem
            } else {
                navigationItem.leftBarButtonItem = UIBarButtonItem(customView: searchBar)
            }
            
            self.navigationItem.setRightBarButton(self.cancelSearchBarButton, animated: true)
        } else {
            // iPhone: Auto-size; iOS 26 keeps nav search top by default
            self.searchBar.sizeToFit()
            self.navigationItem.setRightBarButton(UIBarButtonItem(customView: searchBar), animated: true)
        }
        
        // Standard search mode setup
        self.navigationItem.titleView = nil
        self.searchBar.delegate = self
        self.navigationItem.setHidesBackButton(true, animated: true)
        
        // Focus the search bar (single call suffices)
        self.searchBar.becomeFirstResponder()
        
        // Update input view state based on search results
        if self.searchMessagesQueue.isEmpty {
            self.xabberInputView.searchPanel.changeState(to: .empty)
        } else {
            self.xabberInputView.searchPanel.changeState(to: .withResults)
        }
        self.xabberInputView.changeState(to: .search)
        
        // Animate cancel button visibility (iOS 26 enhances fluid animations automatically)
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
    
    var audioIsInLoading: Bool = false
    
    
    internal var recordedReferenceObject: MessageReferenceStorageItem? = nil {
        didSet {
            if recordedReferenceObject == nil {
                print(1)
            }
        }
    }
    internal var currentPlayingUrl: URL? = nil
    
    internal func showSharedAudioPanel() {
        var navbarHeight: CGFloat = 50
        if let topInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
            navbarHeight += topInset
        }
        if UIDevice.current.userInterfaceIdiom == .pad && CommonConfigManager.shared.config.interface_type == "tabs" {
            navbarHeight += 55
        }
        UIView.animate(withDuration: 0.1) {
            self.sharedAudioPlayerPanel?.update(frame: CGRect(
                origin: CGPoint(
                    x: 0,
                    y: navbarHeight
                ),
                size: CGSize(
                    width: self.view.frame.width,
                    height: 44
                )
            ), isHidden: false)
        }
        
    }
    
    internal func hideSharedAudioPanel() {
        var navbarHeight: CGFloat = 50
        if let topInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
            navbarHeight += topInset
        }
        if UIDevice.current.userInterfaceIdiom == .pad && CommonConfigManager.shared.config.interface_type == "tabs" {
            navbarHeight += 55
        }
        UIView.animate(withDuration: 0.1) {
            self.sharedAudioPlayerPanel?.update(frame: CGRect(
                origin: CGPoint(
                    x: 0,
                    y: navbarHeight
                ),
                size: CGSize(
                    width: self.view.frame.width,
                    height: 0
                )
            ), isHidden: true)
        }
        
    }
    
    internal func configureSharedAudioPanel() {
        self.sharedAudioPlayerPanel?.configure(
            title: AudioManager.shared.currentPlayingTitle,
            subtitle: AudioManager.shared.currentPlayingSubtitle
        )
        self.sharedAudioPlayerPanel?.delegate = self
        self.sharedAudioPlayerPanel?.swapState(to: .playing)
        self.showSharedAudioPanel()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
//        updateInsets()  // Recompute and apply as above
    }
    
    private func configure() {
        restorationIdentifier = "CHAT_VIEW_CONTROLLER_RID_\(self.jid)\(self.owner)"
        self.initSender()
        
        self.dateListContainerView.frame = self.view.bounds
                
        accountPallete = AccountColorManager.shared.palette(for: owner)
        self.messagesCollectionView.prefetchDataSource = self
        self.messagesCollectionView.messagesDataSource = self
        self.messagesCollectionView.messageCellDelegate = self
//        self.messagesCollectionView.messagesDisplayDelegate = self
        self.messagesCollectionView.messagesLayoutDelegate = self
        
        self.messagesCollectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
        
        if #available(iOS 11.0, *) {
            messagesCollectionView.contentInsetAdjustmentBehavior = .never
        } else {
            automaticallyAdjustsScrollViewInsets = false
        }

        // Compute nav/status height once (update dynamically if needed, e.g., in viewDidLayoutSubviews)
        let navHeight: CGFloat = {
            let statusBarHeight = view.safeAreaInsets.top
            let navBarHeight = navigationController?.navigationBar.frame.height ?? 0
            return statusBarHeight + navBarHeight
        }()

        // Update insets: top for input (visual bottom), bottom for nav (visual top)
        var inputHeight: CGFloat = 49
        if let bottomInset = UIApplication.shared.windows.first?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        messagesCollectionView.contentInset = UIEdgeInsets(
            top: inputHeight + 8,
            left: 0,
            bottom: navHeight,
            right: 0
        )
        messagesCollectionView.scrollIndicatorInsets = messagesCollectionView.contentInset
        
        self.messagesCollectionView.scrollsToTop = false
        self.scrollsToBottomOnKeybordBeginsEditing = false
        self.maintainPositionOnKeyboardFrameChanged = true
        self.view.addSubview(self.dateListContainerView)
        
        messagesCollectionView.accountPalette = accountPallete
        (self.navigationController as? NavBarController)?.cancelButton.addTarget(self, action: #selector(additionalNavBarPanelCancelButtonTouchUpInside), for: .touchUpInside)
        
        var navbarHeight: CGFloat = 50
        if let topInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
            navbarHeight += topInset
        }
        if UIDevice.current.userInterfaceIdiom == .pad && CommonConfigManager.shared.config.interface_type == "tabs" {
            navbarHeight += 55
        }
//        self.navbarOverlayView.frame = CGRect(
//            width: self.view.bounds.width,
//            height: navbarHeight
//        )
        
//        inputHeight: CGFloat = 49
//        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
//            inputHeight += bottomInset
//        }
        
        let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
        self.xabberInputView = ModernXabberInputView(frame: frame)
        self.xabberInputView.accountPalette = accountPallete
        self.xabberInputView.delegate = self
        
        self.view.addSubview(self.scrollDownButton)
        self.view.addSubview(xabberInputView)
        self.view.bringSubviewToFront(xabberInputView)
        
        xabberInputView.translatesAutoresizingMaskIntoConstraints = false
        let heightConstraint = xabberInputView.heightAnchor.constraint(equalToConstant: inputHeight)
        NSLayoutConstraint.activate([
            xabberInputView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            xabberInputView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            xabberInputView.bottomAnchor.constraint(equalTo: view.bottomAnchor),  // Pins to bottom safe area (home indicator)
            heightConstraint  // Your computed inputHeight (49 + bottomInset)
        ])
        xabberInputView.heightConstraint = heightConstraint
        
        self.messagesCollectionView.keyboardDismissMode = .interactive
        self.messagesCollectionView.contentInset = UIEdgeInsets(top: inputHeight + 8, left: 0, bottom: 0, right: 0)
        
        
        
        self.configureBackground()
        self.configureNavbar()
        if self.inSearchMode.value {
            self.configureSearchBar()
        } else {
            self.searchTextObserver.accept(nil)
        }
        self.configureInputBar()
        self.configureSelectionPanel()
        self.configureMessagesPanel()
        self.configureCertificateUpdateTimer()
        self.configureDataset()
        self.previousFrame = self.view.bounds
        self.view.addSubview(self.chatViewLoadingOverlay)
        self.chatViewLoadingOverlay.fillSuperview()
//        self.view.addSubview(self.navbarOverlayView)
//        self.view.addSubview(floatingDateView)
        self.scrollDownButton.addTarget(self, action: #selector(self.onScrollDownChatButtonTouchUpInside), for: .touchUpInside)
        self.view.addSubview(self.messageLoadingActivityIndicator)
        self.messageLoadingActivityIndicator.startAnimating()
        self.messageLoadingActivityIndicator.isHidden = true
        self.view.addSubview(self.initialMessageOverlayView)
        if self.sharedAudioPlayerPanel != nil {
            self.view.addSubview(self.sharedAudioPlayerPanel!)
            AudioManager.shared.addMulticastDelegate(self.sharedAudioPlayerPanel)
        }
//    case avatarChatPosition = "avatar_chat_vertical_position"
//    case avatarCornerStyle = "avatar_corner_style"
        self.updateCornerStyle()
        
//        self.navigationItem.title = "Chat"
//        self.navigationController?.navigationBar
//        if #available(iOS 26.0, *) {
//            let button = UIBarButtonItem(image: imageLiteral("person"), style: .prominent, target: nil, action: nil)
//            self.navigationItem.setRightBarButton(button, animated: true)
//        } else {
            // Fallback on earlier versions
//        }
        
//        self.self.navigationController?.navigationBar.isTranslucent = true
//        button./
        self.view.addSubview(self.pinnedDateView)
    }
    
    @objc
    internal func updateCornerStyle() {
        let cornerRaw = SettingManager.shared.getString(for: "message_corner_style") ?? "no_tail"
        self.cornerRadius = SettingManager.shared.getString(for: "message_corner_radius") ?? "16"
        self.messageCorner = MessageStyleConfig.MessageBubbleContainer.nameFromVerbose(cornerRaw)
        self.avatarVerticalPosition = SettingManager.shared.getString(for: "avatar_chat_vertical_position")?.lowercased() ?? "bottom"
    }
    
//    @objc
//    interna;
    
    var previousFrame: CGRect = .zero
    
    
    
    final func configureDataset() {
        do {
            let realm = try WRealm.safe()
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
            origin: CGPoint(x: 0, y: ((UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top ?? 0) + (self.navigationController?.navigationBar.frame.maxY ?? 0)),
            size: self.view.bounds.size
        )
        backgroundImage.frame = self.backgroundView.bounds
        
        gradientView.frame = self.view.bounds
        gradient.frame = self.view.bounds
        gradient.startPoint = CGPoint(x: 0.0, y: 1.0)
        gradient.endPoint = CGPoint(x: 1.0, y: 0.0)
        
        updateBackground()
        
//        self.navigationController?.navigationBar
        
        gradientView.layer.addSublayer(gradient)
        backgroundView.addSubview(gradientView)
        backgroundView.addSubview(backgroundImage)
        backgroundView.bringSubviewToFront(backgroundImage)
        self.messagesCollectionView.backgroundColor = .clear
        self.view.addSubview(backgroundView)
        self.view.sendSubviewToBack(backgroundView)
    }
    
    final func configureNavbar() {
        self.navigationItem.setRightBarButtonItems([], animated: false)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = .systemBackground
        appearance.backgroundImage = UIImage()
        appearance.shadowImage = UIImage()
        appearance.shadowColor = .clear

        let scrollEdgeAppearance = UINavigationBarAppearance()
        scrollEdgeAppearance.configureWithDefaultBackground()
        scrollEdgeAppearance.backgroundColor = .systemBackground  // For scroll edge (iPadOS favors this)
        scrollEdgeAppearance.backgroundImage = UIImage()
        scrollEdgeAppearance.shadowImage = UIImage()
        scrollEdgeAppearance.shadowColor = .clear

        let compactAppearance = UINavigationBarAppearance()
        compactAppearance.configureWithDefaultBackground()
        compactAppearance.backgroundColor = .systemBackground  // Match standard for iPad/landscape consistency
        compactAppearance.backgroundImage = UIImage()
        compactAppearance.shadowImage = UIImage()
        compactAppearance.shadowColor = .clear

        // Apply per-VC (scoped, no global conflicts)
        self.navigationItem.standardAppearance = appearance
        self.navigationItem.compactAppearance = compactAppearance
        self.navigationItem.scrollEdgeAppearance = scrollEdgeAppearance

        navigationController?.navigationBar.isTranslucent = false  // Locks solid on iOS 16

        navigationItem.largeTitleDisplayMode = .never
        
        // Custom title setup (use constraints instead of frame for better layout)
        userBarButton.gradient.colors = [UIColor.white.cgColor,
                                         AccountColorManager.shared.palette(for: self.owner).tint700.cgColor]
        
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(statusLabel)
        titleButton.addSubview(titleStack)
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleStack.topAnchor.constraint(equalTo: titleButton.topAnchor),
            titleStack.leadingAnchor.constraint(equalTo: titleButton.leadingAnchor),
            titleStack.trailingAnchor.constraint(equalTo: titleButton.trailingAnchor),
            titleStack.bottomAnchor.constraint(equalTo: titleButton.bottomAnchor)
        ])
        
        navigationItem.setLeftBarButton(nil, animated: true)
        let gesture = UITapGestureRecognizer(target: self, action: #selector(showInfo))
        userBarButton.addGestureRecognizer(gesture)
        let accountButton = UIBarButtonItem(customView: userBarButton)
        if #available(iOS 26.0, *) {  // Fixed: iOS 16+, not 26 (typo?)
            accountButton.hidesSharedBackground = true
        }
        navigationItem.setRightBarButtonItems([accountButton], animated: false)
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.leftItemsSupplementBackButton = true
        titleStack.isUserInteractionEnabled = false
        
        titleButton.addTarget(self, action: #selector(onTitleButtonTouchUp(_:)), for: .touchUpInside)
        navigationItem.titleView = titleButton
        
        // Remove manual frame; let Auto Layout handle (titleButton will size to content + available width)
        titleLabel.attributedText = updateTitle()
        initStatus()
        
        userBarButton.configure(owner: owner, jid: jid)
        if conversationType == .saved {
            userBarButton.avatar.image = imageLiteral(XMPPFavoritesManagerStorageItem.imageName, dimension: 16)
            userBarButton.avatar.tintColor = AccountColorManager.shared.palette(for: owner).tint900
            userBarButton.avatar.backgroundColor = AccountColorManager.shared.palette(for: owner).tint100
            userBarButton.avatar.contentMode = .center
        }
    }
    
    final func configureInputBar() {
        if self.conversationType.isEncrypted {
            self.xabberInputView.shouldHideTimer = false
            self.xabberInputView.timerButton.isHidden = self.xabberInputView.shouldHideTimer
            self.xabberInputView.timerButton.isEnabled = true
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
        self.view.addSubview(self.recordLockIndicator)
        self.recordLockIndicator.tintColor = self.accountPallete.tint500
        
    }
    
    override func shouldChangeFrame() {
        super.shouldChangeFrame()
        var navbarHeight: CGFloat = 50
        if let topInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
            navbarHeight += topInset
        }
        if UIDevice.current.userInterfaceIdiom == .pad && CommonConfigManager.shared.config.interface_type == "tabs" {
            navbarHeight += 55
        }
        
        if AudioManager.shared.player != nil {
            self.configureSharedAudioPanel()
        } else {
            self.hideSharedAudioPanel()
        }
        if previousFrame == self.view.bounds {
            return
        }
        self.topPanelState.accept(self.topPanelState.value)
        previousFrame = self.view.bounds
        backgroundView.frame = CGRect(
            origin: CGPoint(x: 0, y: 0),//((UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top ?? 0) + (self.navigationController?.navigationBar.frame.height ?? 0)),
            size: self.view.bounds.size
        )
        backgroundImage.frame = self.view.bounds
        
        gradientView.frame = self.view.bounds
        
        gradient.frame = self.view.bounds
        
        
//        self.navbarOverlayView.frame = CGRect(
//            width: self.view.bounds.width,
//            height: navbarHeight
//        )
//        
        self.messageLoadingActivityIndicator.frame = CGRect(width: 64, height: 64)
        self.messageLoadingActivityIndicator.center = CGPoint(x: self.view.center.x, y: navbarHeight + 32)
        
        var inputHeight: CGFloat = 49 + self.xabberInputView.keyboardHeight
        if let bottomInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.bottom {
            inputHeight += bottomInset
        }
        
        let frame = CGRect(origin: CGPoint(x: 0, y: self.view.bounds.height - inputHeight), size: CGSize(width: self.view.bounds.width, height: inputHeight))
        self.xabberInputView.setupFrames(frame)
        
        self.recordLockIndicator.frame = CGRect(
            origin: CGPoint(x: self.view.frame.width - 42, y: self.view.frame.height - 48 - inputHeight),
            size: CGSize(square: 38)
        )
        
        self.scrollDownButton.frame = CGRect(
            origin: CGPoint(x: self.view.frame.width - 42, y: self.view.frame.height - 48 - inputHeight),
            size: CGSize(square: 38)
        )
        
        (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?
            .cache.invalidate()
        self.messagesCollectionView.reloadData()
    }
    
    private func unsubscribe() {
        NotifyManager.shared.currentDialog = nil
        self.bag = DisposeBag()
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
            selector: #selector(reloadDatasource),
            name: .newMaskSelected,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadDatasource),
            name: .chatInterfaceChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateBackground),
            name: .chatBackgroundChanged,
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.onMeteringLevelDidUpdate(_:)),
            name: .recorderDidUpdateMeteringLevelNotification,
            object: nil
        )
    }
    
    var recordedPCM: [Float] = []
    
    @objc
    internal func willEnterForeground() {
        NotifyManager.shared.currentDialog = [self.jid, self.owner].prp()
        AccountManager.shared.find(for: self.owner)?.chatMarkers.updateDeleteEphemeralMessagesTimer()
    }
    
    @objc
    private func didEnterBackground() {
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
//        NotificationCenter.default.removeObserver(self)
        
        
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.willEnterForegroundNotification,
            object: UIApplication.shared
        )
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.didEnterBackgroundNotification,
            object: UIApplication.shared
        )
        NotificationCenter.default.removeObserver(
            self,
            name: .newMaskSelected,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: .chatInterfaceChanged,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: .chatBackgroundChanged,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: UIWindow.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: UIWindow.keyboardWillHideNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: UIWindow.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: .recorderDidUpdateMeteringLevelNotification,
            object: nil
        )
    }
    
//    internal func addMeteringObservers() {
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(didUpdateMeteringLevel),
//                                               name: .recorderDidUpdateMeteringLevelNotification,
//                                               object: AudioRecorder.shared)
//    }
    
    internal func removeMeteringObservers() {
        NotificationCenter.default.removeObserver(self,
                                                  name: .recorderDidUpdateMeteringLevelNotification,
                                                  object: UIApplication.shared)
    }
    
    private final func initSender() {
        self.ownerSender = Sender(
            id: self.owner,
            displayName: self.owner//AccountManager.shared.find(for: owner)?.username ?? ""
        )
        self.opponentSender = Sender(
            id: jid,
            displayName: jid
        )
    }
    
    internal let messageLoadingActivityIndicator: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        
        return view
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.configure()
    }
    
    @objc func updateBackground() {
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
    }
    
    override func reloadDatasource() {
        updateCornerStyle()
        userBarButton.setMask()
        self.messagesCollectionView.reloadData()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        print(#function)
        do {
            try self.subscribe()
            if self.conversationType == .group {
                try self.groupSubscribtions()
            }
            if self.conversationType.isEncrypted {
                try self.encryptedSubscribtions()
            }
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
        
        self.recordLockIndicator.frame = CGRect(
            origin: CGPoint(x: self.view.frame.width - 42, y: self.view.frame.height - 52 - inputHeight),
            size: CGSize(square: 38)
        )
        
        self.lowPrioritySubscribtions()
        self.setupEncryptedChat()
        if self.datasource.isEmpty {
            self.showFloatingDateObserver.accept(false)
            self.loadInitialDatasource { array in
                self.datasource = self.mapDataset(dataset: array)
                self.messagesCollectionView.reloadData()
            }
        }
        self.configureNavbar()
        if self.inSearchMode.value {
            self.configureSearchBar()
        } else {
            self.searchTextObserver.accept(nil)
        }
    }
    
    
    internal func setupEncryptedChat() {
        if self.conversationType.isEncrypted {
            AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
                if CommonConfigManager.shared.config.required_time_signature_for_messages {
                    user.x509Manager.retrieveCert(stream, for: self.jid)
                }
            })
            AccountManager.shared.find(for: self.owner)?.omemo.prepareSecretChat(wit: self.jid, success: {
                
            }, fail: {
                DispatchQueue.main.async {
//                    self.showToast(error: "Can`t find any OMEMO device".localizeString(id: "message_manager_error_no_omemo", arguments: []))
                }
            })
            self.startWatchingSignatureTimer()
            if SignatureManager.shared.isSignatureSetted {
                self.onUpdateTimeSignatureBlockState(!SignatureManager.shared.isSignatureValid())
            }
        }
        self.showFloatingDateObserver.accept(false)
        self.pinnedDateView.hide(withoutAnimation: true)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.shouldChangeFrame()
        self.willUpdateFloatingDate()
        self.hideFloatingDateObserver.accept(true)
        self.showFloatingDateObserver.accept(false)
        self.pinnedDateView.hide(withoutAnimation: true)
        self.addObservers()
//        self.topPanelState.accept(.audioPlayer)
        
//        DispatchQueue.main.async {
//                guard self.messagesCollectionView.numberOfSections > 0,
//                      let lastIndexPath = self.messagesCollectionView.indexPathsForVisibleItems.max(by: { $0.section < $1.section || ($0.section == $1.section && $0.item < $1.item) }),
//                      self.messagesCollectionView.contentSize.height > self.messagesCollectionView.bounds.height else { return }
//                
//                // Scroll to visual bottom (last message) with flip: negative y offset
//                let bottomOffset = CGPoint(
//                    x: 0,
//                    y: -(self.messagesCollectionView.contentSize.height - self.messagesCollectionView.bounds.height)
//                )
//                self.messagesCollectionView.setContentOffset(bottomOffset, animated: false)
//            }
    }
    
    
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        omemoDeviceListTimer?.invalidate()
        omemoDeviceListTimer = nil
        AccountManager.shared.find(for: owner)?.mam.allowHistoryFixTask = false
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.mam.allowHistoryFixTask = false
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
    
//    internal final func scrollToLastUnreadMessage(select: Bool = false) {
//        do {
//            let realm = try WRealm.safe()
//            if let unreadId = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType))?.lastReadId {
//                if let primary = realm.objects(MessageStorageItem.self).filter("owner == %@ AND opponent == %@ AND archivedId == %@", self.owner, self.jid, unreadId).first?.primary {
//                    if let index = self.messagesObserver?.firstIndex(where: { $0.primary == primary }), index != 0 {
//                        if self.messagesCollectionView.indexPathsForVisibleItems.compactMap({ return $0.section }).contains(index) {
//                            return
//                        }
//                        let offset = (0...index).compactMap ({
//                            return (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?.sizeForItem(at: IndexPath(row: 0, section: $0)).height
//                        }).reduce(0, +) - ((self.view.bounds.height / 4) * 3)
//                        self.messagesCollectionView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
//                    }
//                }
//            }
//        } catch {
//            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
//        }
//    }
    
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
        
    }
    
    func didTapPhotoFromGallery(primary: String) {
        navigationController?.popViewController(animated: true)
    }
    
}

