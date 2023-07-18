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

/// A subclass of `UIViewController` with a `MessagesCollectionView` object
/// that is used to display conversation interfaces.
class MessagesViewController: BaseViewController,
UICollectionViewDelegateFlowLayout, UICollectionViewDataSource {

    public static var maxWidthForMessages: CGFloat {
        get {
            let width = UIScreen.main.bounds.width
//            if width <= 320 {
//                return 274
//            } else
            if width <= 414 {
                return width - 32
            } else {
                return 420
            }
        }
    }
    
    /// The `MessagesCollectionView` managed by the messages view controller object.
    var messagesCollectionView = MessagesCollectionView()

    /// The `MessageInputBar` used as the `inputAccessoryView` in the view controller.
//    var messageInputBar = MessageInputBar()
    final let xabberInputBar: XabberInputBar = XabberInputBar()
    
    /// A Boolean value that determines whether the `MessagesCollectionView` scrolls to the
    /// bottom whenever the `InputTextView` begins editing.
    ///
    /// The default value of this property is `false`.
    var scrollsToBottomOnKeybordBeginsEditing: Bool = false
    
    /// A Boolean value that determines whether the `MessagesCollectionView`
    /// maintains it's current position when the height of the `MessageInputBar` changes.
    ///
    /// The default value of this property is `false`.
    var maintainPositionOnKeyboardFrameChanged: Bool = false
    
    var shouldSetRequiredTopInsetAtFirstLayout: Bool = true

    final var isKeyboardShowed: Bool = false
        
    override var canBecomeFirstResponder: Bool {
        return true
    }

    override var inputAccessoryView: UIView? {
        return xabberInputBar
    }

    override var shouldAutorotate: Bool {
        return false
    }

    private var isFirstLayout: Bool = true
    
    internal var isMessagesControllerBeingDismissed: Bool = false

    internal var selectedIndexPathForMenu: IndexPath?

    internal var messageCollectionViewBottomInset: CGFloat = 16 { //54 {
        didSet {
            messagesCollectionView.contentInset.bottom = messageCollectionViewBottomInset
            messagesCollectionView.scrollIndicatorInsets.bottom = messageCollectionViewBottomInset
        }
    }
    
    open var accessoryViewSearchCorrectionConstant: CGFloat = 0
    open var accessoryViewCorrectionConstant: CGFloat = 0
    
    open var messageCollectionViewTopInset: CGFloat = 54 {
        didSet {
            if messagesCollectionView.bounds.height > messagesCollectionView.contentSize.height {
                messagesCollectionView.contentInset.bottom = max(
                    0,
                    messagesCollectionView.bounds.height - messagesCollectionView.contentSize.height - 54)
            } else {
                messagesCollectionView.contentInset.bottom = 54
            }
            
            let bottomOffset: CGFloat = UIDevice.needBottomOffset ? 86 : 54
            
            messagesCollectionView.contentInset.top = messageCollectionViewTopInset + bottomOffset - accessoryViewCorrectionConstant
            messagesCollectionView.scrollIndicatorInsets.top = messageCollectionViewTopInset + bottomOffset - accessoryViewCorrectionConstant
        }
    }
    
    open var messageCollectionViewLastKBPosition: CGFloat = 0
    
    // MARK: - View Life Cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        
        messageCollectionViewLastKBPosition = 0
        
        setupDefaults()
        setupSubviews()
        setupConstraints()
        setupDelegates()
        addMenuControllerObservers()
        addObservers()
    }
    
    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !isFirstLayout {
            addKeyboardObservers()
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        (messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?.cache.invalidate()
        isMessagesControllerBeingDismissed = false
    }
    
    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isMessagesControllerBeingDismissed = true
        removeKeyboardObservers()
    }
    
    open override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isMessagesControllerBeingDismissed = false
    }
    
    override func viewDidLayoutSubviews() {
        if isFirstLayout {
            defer { isFirstLayout = false }
            addKeyboardObservers()
//            messageCollectionViewBottomInset = 72
            if shouldSetRequiredTopInsetAtFirstLayout {
                messageCollectionViewTopInset = requiredInitialScrollViewBottomInset()
            }
        }
    }
    
    open override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if shouldSetRequiredTopInsetAtFirstLayout {
            messageCollectionViewTopInset = requiredInitialScrollViewBottomInset()
        }
    }
    
    public final func updateObserverState() {
        removeKeyboardObservers()
        addKeyboardObservers()
    }

    public final func updateTopInsetAfterModal() {
        messageCollectionViewTopInset = 0
    }
    
    // MARK: - Initializers

    deinit {
        removeKeyboardObservers()
        removeMenuControllerObservers()
        removeObservers()
        clearMemoryCache()
    }

    // MARK: - Methods [Private]

    private final func setupDefaults() {
        extendedLayoutIncludesOpaqueBars = true
//        automaticallyAdjustsScrollViewInsets = false
        if #available(iOS 13.0, *) {
            view.backgroundColor = .systemBackground
        } else {
            view.backgroundColor = .white
        }
        messagesCollectionView.keyboardDismissMode = .interactive
        messagesCollectionView.alwaysBounceVertical = true
        initialBottomOffsetUpdate()
    }

    private final func setupDelegates() {
        messagesCollectionView.delegate = self
        messagesCollectionView.dataSource = self
    }

    private final func setupSubviews() {
        view.addSubview(messagesCollectionView)
    }

    
    private final func setupConstraints() {
        messagesCollectionView.translatesAutoresizingMaskIntoConstraints = false
        
        let top = messagesCollectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        let bottom = messagesCollectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        let leading = messagesCollectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor)
        let trailing = messagesCollectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        NSLayoutConstraint.activate([top, bottom, trailing, leading])
    }

    // MARK: - UICollectionViewDataSource

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        guard let collectionView = collectionView as? MessagesCollectionView else {
            fatalError(MessageKitError.notMessagesCollectionView)
        }
        return collectionView.messagesDataSource?.numberOfSections(in: collectionView) ?? 0
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard let collectionView = collectionView as? MessagesCollectionView else {
            fatalError(MessageKitError.notMessagesCollectionView)
        }
        return collectionView.messagesDataSource?.numberOfItems(inSection: section, in: collectionView) ?? 0
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {

        guard let messagesCollectionView = collectionView as? MessagesCollectionView else {
            fatalError(MessageKitError.notMessagesCollectionView)
        }

        guard let messagesDataSource = messagesCollectionView.messagesDataSource else {
            fatalError(MessageKitError.nilMessagesDataSource)
        }

        let message = messagesDataSource.messageForItem(at: indexPath, in: messagesCollectionView)

        switch message.kind {
        case .text, .attributedText, .emoji:
            let cell = messagesCollectionView.dequeueReusableCell(TextMessageCell.self, for: indexPath)
            cell.configure(with: message, at: indexPath, and: messagesCollectionView)
            cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
            return cell
        case .system(_):
            let cell = messagesCollectionView.dequeueReusableCell(SystemMessageCell.self, for: indexPath)
            cell.configure(with: message, at: indexPath, and: messagesCollectionView)
            cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
            return cell
        case .photos(_):
            let cell = messagesCollectionView.dequeueReusableCell(ImageMessageCell.self, for: indexPath)
            cell.configure(with: message, at: indexPath, and: messagesCollectionView)
            cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
            return cell
        case .files(let files), .videos(let files):
            if files[0].mimeType == "video" {
                let cell = messagesCollectionView.dequeueReusableCell(VideoMessageCell.self, for: indexPath)
                cell.configure(with: message, at: indexPath, and: messagesCollectionView)
                cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
                return cell
            } else {
                let cell = messagesCollectionView.dequeueReusableCell(FileMessageCell.self, for: indexPath)
                cell.configure(with: message, at: indexPath, and: messagesCollectionView)
                cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
                return cell
            }
        case .audio(_):
            let cell = messagesCollectionView.dequeueReusableCell(AudioMessageCell.self, for: indexPath)
            cell.configure(with: message, at: indexPath, and: messagesCollectionView)
            cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
            return cell
        case .call(_):
            let cell = messagesCollectionView.dequeueReusableCell(VoIPCallMessageCell.self, for: indexPath)
            cell.configure(with: message, at: indexPath, and: messagesCollectionView)
            cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
            return cell
        case .sticker(_):
            let cell = messagesCollectionView.dequeueReusableCell(StickerMessageCell.self, for: indexPath)
            cell.configure(with: message, at: indexPath, and: messagesCollectionView)
            cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
            return cell
        case .quote(_,_):
            let cell = messagesCollectionView.dequeueReusableCell(QuoteMessageCell.self, for: indexPath)
            cell.configure(with: message, at: indexPath, and: messagesCollectionView)
            cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
            return cell
        case .initial(_):
            let cell = messagesCollectionView.dequeueReusableCell(InitialMessageCell.self, for: indexPath)
            cell.configure(with: message, at: indexPath, and: messagesCollectionView)
            cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
            return cell
        case .skeleton(_):
            let cell = messagesCollectionView.dequeueReusableCell(SkeletonMessageCell.self, for: indexPath)
            cell.configure(with: message, at: indexPath, and: messagesCollectionView)
            cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
            return cell
        default:
            fatalError(MessageKitError.customDataUnresolvedCell)
        }
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {

        guard let messagesCollectionView = collectionView as? MessagesCollectionView else {
            fatalError(MessageKitError.notMessagesCollectionView)
        }

        guard let displayDelegate = messagesCollectionView.messagesDisplayDelegate else {
            fatalError(MessageKitError.nilMessagesDisplayDelegate)
        }

        switch kind {
        case UICollectionView.elementKindSectionHeader:
            return displayDelegate.messageHeaderView(for: indexPath, in: messagesCollectionView)
        case UICollectionView.elementKindSectionFooter:
            return displayDelegate.messageFooterView(for: indexPath, in: messagesCollectionView)
        default:
            fatalError(MessageKitError.unrecognizedSectionKind)
        }
    }

    // MARK: - UICollectionViewDelegateFlowLayout

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        guard let messagesFlowLayout = collectionViewLayout as? MessagesCollectionViewFlowLayout else { return .zero }
        return messagesFlowLayout.sizeForItem(at: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {

        guard let messagesCollectionView = collectionView as? MessagesCollectionView else {
            fatalError(MessageKitError.notMessagesCollectionView)
        }
        guard let layoutDelegate = messagesCollectionView.messagesLayoutDelegate else {
            fatalError(MessageKitError.nilMessagesLayoutDelegate)
        }
        return layoutDelegate.headerViewSize(for: section, in: messagesCollectionView)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForFooterInSection section: Int) -> CGSize {
        
        guard let messagesCollectionView = collectionView as? MessagesCollectionView else {
            fatalError(MessageKitError.notMessagesCollectionView)
        }
        guard let layoutDelegate = messagesCollectionView.messagesLayoutDelegate else {
            fatalError(MessageKitError.nilMessagesLayoutDelegate)
        }
        return layoutDelegate.footerViewSize(for: section, in: messagesCollectionView)
    }

    func collectionView(_ collectionView: UICollectionView, shouldShowMenuForItemAt indexPath: IndexPath) -> Bool {
        selectedIndexPathForMenu = indexPath
        return true
    }

    func collectionView(_ collectionView: UICollectionView, canPerformAction action: Selector, forItemAt indexPath: IndexPath, withSender sender: Any?) -> Bool {
        return [
            NSSelectorFromString("copy:"),
            NSSelectorFromString("shareMessage:"),
            NSSelectorFromString("replyMessage:"),
            NSSelectorFromString("deleteMessage:"),
            NSSelectorFromString("moreAction:")
        ].contains(action)
    }

    func collectionView(_ collectionView: UICollectionView, performAction action: Selector, forItemAt indexPath: IndexPath, withSender sender: Any?) {
        guard let cell = collectionView.cellForItem(at: indexPath) as? MessageCollectionViewCell else { return }
        messagesCollectionView.messageCellDelegate?.onCopyMessage(cell: cell)
    }

    // MARK: - Helpers
    
    /// A CGFloat value that adds to (or, if negative, subtracts from) the automatically
    /// computed value of `messagesCollectionView.contentInset.bottom`. Meant to be used
    /// as a measure of last resort when the built-in algorithm does not produce the right
    /// value for your app. Please let us know when you end up having to use this property.
    
    var currentContentInset: CGFloat {
        get {
            return messageCollectionViewTopInset // - automaticallyAddedBottomInset
        }
    }
    
    var additionalBottomInset: CGFloat = 0 {
        didSet {
            let delta = additionalBottomInset - oldValue
            messageCollectionViewBottomInset += delta
        }
    }
    
    var additionalTopInset: CGFloat = 0
//    {
//        didSet {
//            let delta = additionalTopInset - oldValue
//            messageCollectionViewTopInset += delta
//        }
//    }
    
    public func addObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clearMemoryCache),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    public func removeObservers() {
        NotificationCenter.default.removeObserver(self, name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
    
    @objc
    public final func clearMemoryCache() {
        MessageStyle.bubbleImageCache.removeAllObjects()
    }
}
