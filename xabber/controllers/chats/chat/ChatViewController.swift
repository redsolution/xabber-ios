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

class ChatViewController: MessagesViewController {
    
    enum InputBarState {
        case short
        case normal
        case selection
    }
    
    enum NavigationBarStyle {
        case normal
        case selection
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
                ChatViewController.Datasource.iconForMetadata(for: a.errorMetadata) == ChatViewController.Datasource.iconForMetadata(for: b.errorMetadata)
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
                return "security"
            } else {
                return "alert"
            }
        }
    }
    
    public static let datasourcePageSize: Int = 100
    public static let datasourceInitialPageSize: Int = 40
    public final var canUpdateDataset: Bool = true
    
    //internal var isDatasourceLoaded: Bool = false
    internal let gapLength: Int = 200
    internal var currentGap: Int = 0
//
//    public var jid: String = ""
//    public var owner: String = ""
    internal var groupchat: Bool {
        get {
            return self.conversationType == .group
        }
    }
    
    
    public var conversationType: ClientSynchronizationManager.ConversationType = ClientSynchronizationManager.ConversationType(rawValue: CommonConfigManager.shared.config.locked_conversation_type) ?? .regular
    public var entity: RosterItemEntity = .contact
    public var groupchatDescr: String = ""
    
    internal var messagesCount: Int = ChatViewController.datasourceInitialPageSize
    internal var shouldChangeOffsetOnUpdate: Bool = false
    

    internal var messagesObserver: Results<MessageStorageItem>? = nil
//    internal var messagesDataset: Results<MessageStorageItem>? = nil
    
    internal var datasource: [Datasource] = []
    
    internal var bag: DisposeBag = DisposeBag()
    internal var pinBag: DisposeBag = DisposeBag()
    internal var messagesBag: DisposeBag = DisposeBag()
    internal var messagesUpdaterBag: DisposeBag = DisposeBag()
    
    var opponentSender: Sender = Sender(id: "", displayName: "")
    var ownerSender: Sender = Sender(id: "", displayName: "")
    
    var isInSelectionMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)
    
    var showSkeletonObserver: BehaviorRelay<Bool> = BehaviorRelay(value: true)
    var isSkeletonHided: Bool = false
        
    var canLoadPage: Bool = true
//    {
//        didSet {
//            DispatchQueue.main.async {
//                UIApplication.shared.isNetworkActivityIndicatorVisible = !self.canLoadPage
//            }
//        }
//    }
    
    var accountPallete: MDCPalette = MDCPalette.blue
    var tmpUploadString: String = ""
    
    var contactStatus: String? = nil
    
    var isChatSynced: Bool = false
    
    var isAccessToPhotoGranted: Bool? = nil
    
// Status
    var statusTextObserver: BehaviorRelay<String> = BehaviorRelay(value: " ")
    var shouldShowNormalStatus: Bool = false
// Search mode
    public var inSearchMode: BehaviorRelay<Bool> = BehaviorRelay(value: false)
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
    var searchTextBouncerObserver: BehaviorRelay<String?> = BehaviorRelay(value: nil)
    
    var messagesListDisposable: Disposable? = nil
    
    var isInitiallyDeletedGroup: Bool? = nil
    
    var shouldUpdateMessagesCount: Bool = true
    
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
    
//    var navbarBackgroundBar: UITabBar = {
//        let bar = UITabBar()
//
//        bar.barStyle = .default
//        bar.backgroundImage = nil
//
//        return bar
//    }()
    
    var pinMessageView: PinMessageView = {
        let view = PinMessageView(frame: .zero)
        
        
        return view
    }()
    
    var pinMessageBar: UITabBar = {
        let bar = UITabBar()
        
        bar.barStyle = .default
        bar.backgroundImage = nil
        
        return bar
    }()
    
//    var topMenuPanelBar: UITabBar = {
//        let bar = UITabBar()
//
//        bar.barStyle = .default
//        bar.backgroundImage = nil
//
//        return bar
//    }()
    
    var bottomSearchBar: SearchBar = {
        let bar = SearchBar()
        
        bar.barStyle = .default
//        bar.backgroundImage = nil
        
        return bar
    }()
    
    var subscribtionBarView: SubscribtionBarView = {
        let view = SubscribtionBarView(frame: .zero)
        
        return view
    }()
    
    var subscribtionBar: UITabBar = {
        let bar = UITabBar()
        
        bar.barStyle = .default
        bar.backgroundImage = nil
        
        return bar
    }()
    
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
    
    internal var xabberInputView: ModernXabberInputView!
    
    internal var shouldRequestChatInfo: Bool = false
    
    @objc
    internal func showInfo() {
        let vc: BaseViewController
        if groupchat {
            vc = GroupchatInfoViewController()
            (vc as! GroupchatInfoViewController).footerView.chatsDelegate = self
        } else {
            vc = ContactInfoViewController()
            (vc as! ContactInfoViewController).footerView.chatsDelegate = self
            (vc as! ContactInfoViewController).conversationType = self.conversationType
        }
        vc.owner = self.owner
        vc.jid = self.jid
        self.title = " "
//        self.topMenuShowObserver.accept(false)
        self.navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        self.navigationController?.navigationBar.shadowImage = UIImage()
        self.navigationController?.navigationBar.layoutIfNeeded()
        self.navigationController?.pushViewController(vc, animated: true)
    }
        
    @objc
    func clearAttachments() {
        print("Call empty", #function)
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
        recordingPanel.cancelCallback = onCancelRecord
        recordingPanel.deleteCallback = onDeleteRecord
        recordingPanel.onPlayCallback = onRecordingPanelWillPlay
        recordingPanel.onPauseCallback = onRecordingPanelWillPause
        recordingPanel.onEndPlayingCallback = onRecordingPanelWillEnd
    }
    
    func configurePinMessagePanel() {
//        pinMessageBar.addSubview(pinMessageView)
        pinMessageView.fillSuperview()
        pinMessageView.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: 64)
        pinMessageBar.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: 64)
        self.pinMessageBar.alpha = 0
//        view.addSubview(pinMessageBar)
    }
    
    func configureSubscribtionPanel() {
        subscribtionBar.addSubview(subscribtionBarView)
        subscribtionBarView.fillSuperview()
        self.subscribtionBarView.isHidden = true
        subscribtionBar.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: 64)
        view.addSubview(subscribtionBar)
        
        subscribtionBar.isHidden = true
    }
    
    func configureSearchBar() {
        navigationItem.setRightBarButton(UIBarButtonItem(customView: searchBar), animated: true)
        searchBar.sizeToFit()
        searchBar.delegate = self
        navigationItem.setHidesBackButton(true, animated: true)
        let barFrame = self.view.inputAccessoryView?.frame
        self.bottomSearchBar.frame = barFrame ?? .zero
    }
    
    func configureNavigationBar() {
        self.navigationController?.setNavigationBarHidden(false, animated: false)
        
        self.navigationItem.setLeftBarButton(nil, animated: true)
        let gesture = UITapGestureRecognizer(target: self, action: #selector(self.showInfo))
        self.userBarButton.addGestureRecognizer(gesture)
        self.navigationItem.setRightBarButton(UIBarButtonItem(customView: self.userBarButton), animated: true)
        self.navigationItem.setHidesBackButton(false, animated: false)
        self.title = " "
        
        self.titleStack.isUserInteractionEnabled = false
        
        self.titleButton.addTarget(self, action: #selector(self.onTitleButtonTouchUp(_:)), for: .touchUpInside)
        self.navigationItem.titleView = titleButton
        
        self.titleButton.frame = CGRect(width: self.view.frame.width - 64, height: 40)
//        self.xabberInputBar.becomeFirstResponder()
    }
    
    override var disablesAutomaticKeyboardDismissal: Bool {
        get {
            return true
        }
    }
    
    private func configure() {
        restorationIdentifier = "CHAT_VIEW_CONTROLLER_RID"
        ownerSender = Sender(
            id: owner,
            displayName: AccountManager.shared.find(for: owner)?.username ?? ""
        )
        accountPallete = AccountColorManager.shared.palette(for: owner)
                
        self.messagesCollectionView.prefetchDataSource = self
        self.messagesCollectionView.messagesDataSource = self
        self.messagesCollectionView.messageCellDelegate = self
        self.messagesCollectionView.messagesDisplayDelegate = self
        self.messagesCollectionView.messagesLayoutDelegate = self
        
        self.messagesCollectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
        self.titleStack.addArrangedSubview(titleLabel)
        self.titleStack.addArrangedSubview(statusLabel)
        self.titleButton.addSubview(titleStack)
        self.titleStack.fillSuperview()
        self.titleButton.bringSubviewToFront(titleStack)
        
        self.messagesCollectionView.scrollsToTop = false
        self.scrollsToBottomOnKeybordBeginsEditing = false
        self.maintainPositionOnKeyboardFrameChanged = true
        
        messagesCollectionView.accountPalette = accountPallete
        if conversationType == .omemo {
            titleLabel.textColor = MDCPalette.green.tint700
        } else {
            titleLabel.textColor = accountPallete.tint700
        }
        
        let backgroundView = UIView(frame: self.view.bounds)
        let backgroundImage = UIImageView(frame: self.view.bounds)
        
        let gradientView = UIView(frame: self.view.bounds)
        
        let gradient = CAGradientLayer()
        gradient.frame = self.view.bounds
        
        gradient.startPoint = CGPoint(x: 0.0, y: 1.0)
        gradient.endPoint = CGPoint(x: 1.0, y: 0.0)
        
        let backgroundResourceName = SettingManager.shared.getString(for: "chat_chooseBackground") ?? "None"
        if backgroundResourceName != "None" {
            backgroundImage.image = UIImage(imageLiteralResourceName: backgroundResourceName.lowercased())
                .withRenderingMode(.alwaysTemplate)
                .resizableImage(withCapInsets: UIEdgeInsets.zero,
                                resizingMode: .tile)
            backgroundImage.tintColor = UIColor.white
            backgroundImage.alpha = 0.1
            backgroundImage.contentMode = .scaleAspectFill
        } else {
            backgroundImage.image = nil
        }
        
        if conversationType == .omemo {
            gradient.colors = [
                CGColor(red: 253/255, green: 216/255, blue: 25/255, alpha: 1.0),
                CGColor(red: 232/255, green: 5/255, blue: 5/255, alpha: 1.0)
            ]
        } else {
            gradient.colors = [
                CGColor(red: 255/255, green: 122/255, blue: 245/255, alpha: 1.0),
                CGColor(red: 81/255, green: 49/255, blue: 98/255, alpha: 1.0)
            ]
        }
        
        gradientView.layer.addSublayer(gradient)
        backgroundView.addSubview(gradientView)
        backgroundView.addSubview(backgroundImage)
        backgroundView.bringSubviewToFront(backgroundImage)
        messagesCollectionView.backgroundView =  backgroundView
        
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
        self.messagesCollectionView.contentInset = UIEdgeInsets(top: inputHeight + 8, left: 0, bottom: 100, right: 0)
        
        userBarButton.configure(owner: owner, jid: jid)
        configureSubscribtionPanel()
        configurePinMessagePanel()
        configureRecordingPanel()
        configureSelectionPanel()
        configureMessagesPanel()
        configureCertificateUpdateTimer()
        
        if self.conversationType == .omemo {
            AccountManager.shared.find(for: self.owner)?.omemo.prepareSecretChat(wit: self.jid, success: {
                
            }, fail: {
                DispatchQueue.main.async {
                    self.showToast(error: "Can`t find any OMEMO device".localizeString(id: "message_manager_error_no_omemo", arguments: []))
                }
            })
        }
        if CommonConfigManager.shared.config.required_time_signature_for_messages {
            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                session.x509?.retrieveCert(stream, for: self.jid)
            } fail: {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.x509Manager.retrieveCert(stream, for: self.jid)
                })
            }
        }
        
        
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.userBarButton.stopAnimation()
        }
    }
    
    @objc
    internal func willEnterForeground() {
        NotifyManager.shared.currentDialog = [self.jid, self.owner].prp()
        appInBackground = false
        
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { stream, session in
                session.mam?.syncChat(stream, jid: self.jid, conversationType: self.conversationType)
                session.messages?.readLastMessage(jid: self.jid, conversationType: self.conversationType)
            }) {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.mam.syncChat(stream, jid: self.jid, conversationType: self.conversationType)
                    user.messages.readLastMessage(jid: self.jid, conversationType: self.conversationType)
                })
            }
        }
    }
    
    @objc
    private func didEnterBackground() {
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
    
    internal func loadDatasource() {
        do {
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: RosterStorageItem.self,
                                           forPrimaryKey: [jid, owner].prp()) {
                opponentSender = Sender(id: jid, displayName: instance.displayName)
            } else if let instance = realm.object(ofType: vCardStorageItem.self, forPrimaryKey: jid) {
                opponentSender = Sender(id: jid, displayName: instance.generatedNickname)
            } else {
                opponentSender = Sender(id: jid, displayName: jid)
            }
//            if let lastChat = realm.object(
//                ofType: LastChatsStorageItem.self,
//                forPrimaryKey: LastChatsStorageItem.genPrimary(
//                    jid: self.jid,
//                    owner: self.owner,
//                    conversationType: self.conversationType
//                )
//            ) {
//                self.previousDraftMessageText = lastChat.draftMessage
//            }            
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    @objc
    internal func checkForGaps(_ from: Int = 0) {
        if let count = messagesObserver?.count,
            count != 0,
            from >= count { return }
    }
    
    func scrollToMessage(primary: String) {
        //item always = 0, section = message
        if let index = self.datasource.firstIndex(where: { $0.primary == primary }) {
            if self.messagesCollectionView.indexPathsForVisibleItems.compactMap({ return $0.section }).contains(index) {
                return
            }
            self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: index), at: .centeredVertically, animated: false)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.loadDatasource()
        self.configure()
        self.addObservers()
        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        self.navigationController?.navigationBar.shadowImage = nil
        self.navigationController?.navigationBar.superview?.bringSubviewToFront(self.navigationController!.navigationBar)
        self.navigationController?.navigationBar.layoutIfNeeded()

        userBarButton.gradient.colors = [UIColor.white.cgColor,
                                         AccountColorManager.shared.palette(for: self.owner).tint700.cgColor]
        
        if [.omemo, .omemo1, .axolotl].contains(self.conversationType) {
            self.xabberInputView.timerButton.isHidden = self.xabberInputView.shouldHideTimer
            self.xabberInputView.timerButton.isEnabled = true
            self.xabberInputView.shouldHideTimer = false
        } else {
            self.xabberInputView.shouldHideTimer = true
            self.xabberInputView.timerButton.isHidden = true
            self.xabberInputView.timerButton.isEnabled = false
        }
        
        
    }
    
    override func reloadDatasource() {
        userBarButton.setMask()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        do {
            try self.subscribe()
            self.addObservers()
            let realm = try WRealm.safe()
            let chat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType))
            
            self.xabberInputView.textField.text = chat?.draftMessage
            self.xabberInputView.textViewDidChange()
            self.showSkeletonObserver.accept(!(chat?.isSynced ?? true))
            self.isSkeletonHided = !self.showSkeletonObserver.value
            self.initializeDataset()
            
            if [.omemo, .omemo1, .axolotl].contains(conversationType) {
                self.startWatchingSignatureTimer()
                if SignatureManager.shared.certificate != nil {
                    self.onUpdateTimeSignatureBlockState(!SignatureManager.shared.isSignatureValid())
                }
                let realm = try Realm()
                if realm.objects(SignalDeviceStorageItem.self)
                    .filter("owner == %@ AND jid == %@ AND state_ == %@", self.owner, self.jid, SignalDeviceStorageItem.TrustState.trusted.rawValue)
                    .count == 0 {
                    self.onUpdateTrustedDevicesBlockState(true)
                } else if realm
                    .objects(SignalDeviceStorageItem.self)
                    .filter(
                        "owner == %@ AND jid == %@ AND state_ != %@",
                        self.owner,
                        self.owner,
                        SignalDeviceStorageItem.TrustState.trusted.rawValue)
                        .count > 0 {
                    self.onUpdateTrustedDevicesBlockState(true)
                }
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        AccountManager.shared.find(for: self.owner)?.action({ (user, stream) in
            user.messages.readLastMessage(jid: self.jid, conversationType: self.conversationType)
        })
        self.xabberInputView.isSendButtonEnabled = false
        self.xabberInputView.updateSendButtonState()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.lowPrioritySubscribtions()
        self.navigationController?.navigationBar.setBackgroundImage(nil, for: .default)
        self.navigationController?.navigationBar.shadowImage = nil
        self.navigationController?.navigationBar.superview?.bringSubviewToFront(self.navigationController!.navigationBar)
        self.navigationController?.navigationBar.layoutIfNeeded()
        
        self.canLoadPage = true
        self.messagesCollectionView.indexPathsForVisibleItems.forEach {
            if (self.messagesObserver?.count ?? 0) <= $0.section { return }
            self.messagesObserver?[$0.section].references.forEach { item in
                let messageId = item.messageId
                let jid = item.jid
                let metadata = item.metadata_
                MessageReferenceStorageItem.prepareVoice(for: messageId, jid: jid, metadata: metadata)
                if item.mimeType == "video" {
                    MessageReferenceStorageItem.prepareVideo(messageId: messageId, jid: jid, metadata: metadata)
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            XMPPUIActionManager.shared.performRequest(owner: self.owner, action: { stream, session in
                session.mam?.syncChat(stream, jid: self.jid, conversationType: self.conversationType)
            }) {
                AccountManager.shared.find(for: self.owner)?.action({ user, stream in
                    user.mam.syncChat(stream, jid: self.jid, conversationType: self.conversationType)
                })
            }
        }
        do {
            let realm = try WRealm.safe()
            if !(realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType
                )
            )?.isHistoryGapFixedForSession ?? true) {
                self.userBarButton.startAnimation()
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
        if [.omemo, .omemo1, .axolotl].contains(self.conversationType) {
            self.omemoDeviceListTimer?.fire()
            self.omemoDeviceListTimer?.invalidate()
            self.omemoDeviceListTimer = nil
            self.omemoDeviceListTimer = Timer.scheduledTimer(
                timeInterval: 30,
                target: self,
                selector: #selector(omemoDeviceListPolling),
                userInfo: nil,
                repeats: true
            )
//            self.xabberInputView.timerButton.isHidden = false
//            self.xabberInputView.timerButton.isEnabled = true
//            self.xabberInputView.shouldHideTimer = false
            RunLoop.main.add(self.omemoDeviceListTimer!, forMode: .default)
        } else {
//            self.xabberInputView.shouldHideTimer = true
//            self.xabberInputView.timerButton.isHidden = true
//            self.xabberInputView.timerButton.isEnabled = false
        }
        self.xabberInputView.update(screenHeight: self.view.bounds.height, keyboardHeight: 0)
    }
    
    @objc
    private func omemoDeviceListPolling(_ sennder: AnyObject) {
        AccountManager.shared.find(for: self.owner)?.action({ user, stream in
            user.omemo.getContactDevices(stream, jid: self.jid, force: true)
        })
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.navigationItem.backButtonDisplayMode = .minimal
        self.navigationItem.backButtonTitle = self.titleLabel.text
//        self.deleteRecord()
        omemoDeviceListTimer?.invalidate()
        omemoDeviceListTimer = nil

        AccountManager.shared.find(for: owner)?.mam.allowHistoryFixTask = false
                
//        self.topMenuShowObserver.accept(false)
        LastChats.updateErrorState(for: self.jid, owner: self.owner, conversationType: self.conversationType)
        do {
            let realm = try WRealm.safe()
            try realm.write {
                realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType))?.lastReadId = self.messagesObserver?.first?.messageId
            }
        } catch {
            
        }
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
//        self.topMenuShowObserver.accept(false)
        unsubscribe()
        XMPPUIActionManager.shared.mam?.endLoadHistory(jid: self.jid, conversationType: conversationType)
        AccountManager.shared.find(for: self.owner)?.mam.endLoadHistory(jid: self.jid, conversationType: conversationType)
        removeObservers()
    }
    
    open func prepareDataset() -> Results<MessageStorageItem> {
        do {
            let realm = try  WRealm.safe()
            let dataset: Results<MessageStorageItem>
            dataset = realm
                .objects(MessageStorageItem.self)
                .filter ("owner == %@ AND opponent == %@ AND isDeleted == false AND conversationType_ == %@", self.owner, self.jid, self.conversationType.rawValue)
                .sorted (byKeyPath: "date", ascending: false)
            realm.refresh()
            return dataset
        } catch {
            fatalError()
        }
    }
    
    open func reloadDataset(withSearchText value: String?) {
        DispatchQueue.main.async {
            do {
                let realm = try  WRealm.safe()
                self.messagesObserver = realm
                    .objects(MessageStorageItem.self)
                    .filter("owner == %@ AND opponent == %@ AND isDeleted == false AND conversationType_ == %@", self.owner, self.jid, self.conversationType.rawValue)
                    .sorted(byKeyPath: "date", ascending: false)
                realm.refresh()
                self.subscribeOnDatasetChanges()
            } catch {
                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            }
        }
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
    
    deinit {
        self.unsubscribe()
        self.removeObservers()
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
        scrollToMessage(primary: primary)
    }
    
    func didTapPhotoFromGallery(primary: String) {
        scrollToMessage(primary: primary)
        navigationController?.popViewController(animated: true)
    }
    
}
