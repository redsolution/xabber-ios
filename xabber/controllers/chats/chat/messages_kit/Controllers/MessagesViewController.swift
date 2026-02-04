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
                return 360
            }
        }
    }
    
    /// The `MessagesCollectionView` managed by the messages view controller object.
    var messagesCollectionView = MessagesCollectionView()

    /// The `MessageInputBar` used as the `inputAccessoryView` in the view controller.
//    var messageInputBar = MessageInputBar()
//    final let xabberInputBar: XabberInputBar = XabberInputBar()
    
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
//        return xabberInputBar
        return nil
    }

    override var shouldAutorotate: Bool {
        return false
    }

    private var isFirstLayout: Bool = true
    
    internal var selectedIndexPathForMenu: IndexPath?

//    internal var messageCollectionViewBottomInset: CGFloat = 50 {
//        didSet {
////            messagesCollectionView.contentInset.bottom = messageCollectionViewBottomInset
////            messagesCollectionView.scrollIndicatorInsets.bottom = messageCollectionViewBottomInset
//        }
//    }
    
    open var messageCollectionViewLastKBPosition: CGFloat = 0
    
    // MARK: - View Life Cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupDefaults()
        setupSubviews()
        setupConstraints()
        setupDelegates()
        addObservers()
    }
    
    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        (messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?.cache.invalidate()
    }
    
    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    open override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
    }

    deinit {
        removeObservers()
        clearMemoryCache()
    }

    private final func setupDefaults() {
        extendedLayoutIncludesOpaqueBars = true
        edgesForExtendedLayout = [.bottom]
        view.backgroundColor = .systemBackground
        messagesCollectionView.keyboardDismissMode = .interactive
        messagesCollectionView.alwaysBounceVertical = true
        
        messagesCollectionView.contentInsetAdjustmentBehavior = .never
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
        
        messagesCollectionView.fillSuperview()
        
//        let top = messagesCollectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
//        let bottom = messagesCollectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
//        let leading = messagesCollectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor)
//        let trailing = messagesCollectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
//        NSLayoutConstraint.activate([top, bottom, trailing, leading])
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
            case.attributedText, .emoji:
                let cell = messagesCollectionView.dequeueReusableCell(TextMessageCell.self, for: indexPath)
                cell.configure(with: message, at: indexPath, and: messagesCollectionView)
                cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
                return cell
            case .system(_), .date, .unread, .call(_):
                let cell = messagesCollectionView.dequeueReusableCell(SystemMessageCell.self, for: indexPath)
                cell.configure(with: message, at: indexPath, and: messagesCollectionView)
                cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
                return cell
//            case .call(_):
//                let cell = messagesCollectionView.dequeueReusableCell(VoIPCallMessageCell.self, for: indexPath)
//                cell.configure(with: message, at: indexPath, and: messagesCollectionView)
//                cell.contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
//                return cell
            case .sticker(_):
                let cell = messagesCollectionView.dequeueReusableCell(StickerMessageCell.self, for: indexPath)
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
        }
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {

        return MessageReusableView()
        
//        guard let messagesCollectionView = collectionView as? MessagesCollectionView else {
//            fatalError(MessageKitError.notMessagesCollectionView)
//        }

//        guard let displayDelegate = messagesCollectionView.messagesDisplayDelegate else {
//            fatalError(MessageKitError.nilMessagesDisplayDelegate)
//        }
//
//        switch kind {
//        case UICollectionView.elementKindSectionHeader:
//            return displayDelegate.messageHeaderView(for: indexPath, in: messagesCollectionView)
//        case UICollectionView.elementKindSectionFooter:
//            return displayDelegate.messageFooterView(for: indexPath, in: messagesCollectionView)
//        default:
//            fatalError(MessageKitError.unrecognizedSectionKind)
//        }
    }
    
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
//        selectedIndexPathForMenu = indexPath
        return true
    }

    func collectionView(_ collectionView: UICollectionView, canPerformAction action: Selector, forItemAt indexPath: IndexPath, withSender sender: Any?) -> Bool {
//        return [
//            NSSelectorFromString("copy:"),
//            NSSelectorFromString("shareMessage:"),
//            NSSelectorFromString("replyMessage:"),
//            NSSelectorFromString("deleteMessage:"),
//            NSSelectorFromString("moreAction:")
//        ].contains(action)
        return false
    }

    func collectionView(_ collectionView: UICollectionView, performAction action: Selector, forItemAt indexPath: IndexPath, withSender sender: Any?) {
//        guard let cell = collectionView.cellForItem(at: indexPath) as? MessageCollectionViewCell else { return }
//        messagesCollectionView.messageCellDelegate?.onCopyMessage(cell: cell)
    }

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
