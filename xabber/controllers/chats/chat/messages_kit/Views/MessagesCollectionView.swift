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
import MaterialComponents.MDCPalettes

class MessagesCollectionView: UICollectionView {

    // MARK: - Properties

    weak var messagesDataSource: MessagesDataSource?


    weak var messagesLayoutDelegate: MessagesLayoutDelegate?

    weak var messageCellDelegate: MessageCellDelegate?

    var accountPalette: MDCPalette = MDCPalette.grey
    
    private var indexPathForLastItem: IndexPath? {
        let lastSection = numberOfSections - 1
        guard lastSection >= 0, numberOfItems(inSection: lastSection) > 0 else { return nil }
        return IndexPath(item: numberOfItems(inSection: lastSection) - 1, section: lastSection)
    }

    // MARK: - Initializers

    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        super.init(frame: frame, collectionViewLayout: layout)
//        backgroundColor = .white
        registerReusableViews()
        setupGestureRecognizers()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    convenience init() {
        self.init(frame: .zero, collectionViewLayout: MessagesCollectionViewFlowLayout())
    }

    // MARK: - Methods
    
    private func registerReusableViews() {
        register(TextMessageCell.self)
//        register(ImageMessageCell.self)
//        register(VideoMessageCell.self)
//        register(FileMessageCell.self)
//        register(AudioMessageCell.self)
        register(VoIPCallMessageCell.self)
        register(SystemMessageCell.self)
        register(StickerMessageCell.self)
//        register(QuoteMessageCell.self)
        register(InitialMessageCell.self)
        register(SkeletonMessageCell.self)
        register(AtivityIndicatorCell.self)
        register(MessageReusableView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader)
        register(MessageReusableView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter)
    }
    
    private func setupGestureRecognizers() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapGesture(_:)))
        tapGesture.delaysTouchesBegan = true
        addGestureRecognizer(tapGesture)
        
        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressGesture(_:)))
        tapGesture.require(toFail: longPressGesture)
        longPressGesture.delaysTouchesBegan = true
        addGestureRecognizer(longPressGesture)
    }
    
    @objc
    func handleTapGesture(_ gesture: UIGestureRecognizer) {
        guard gesture.state == .ended else { return }
        
        let touchLocation = gesture.location(in: self)
        guard let indexPath = indexPathForItem(at: touchLocation) else { return }
        
        if let cell = cellForItem(at: indexPath) as? MessageContentCell {
            cell.handleTapGesture(gesture)
        } else if let cell = cellForItem(at: indexPath) as? InitialMessageCell {
            cell.handleTapGesture(gesture)
        }
    }
    
    @objc
    func handleLongPressGesture(_ gesture: UIGestureRecognizer) {
        guard gesture.state == .began else { return }
        let touchLocation = gesture.location(in: self)
        guard let indexPath = indexPathForItem(at: touchLocation) else { return }
        
        let cell = cellForItem(at: indexPath) as? MessageContentCell
        cell?.handleLongTapGesture(gesture)
    }

    func scrollToBottom(animated: Bool = false) {
        let collectionViewContentHeight = collectionViewLayout.collectionViewContentSize.height

        performBatchUpdates(nil) { _ in
            self.scrollRectToVisible(CGRect(0.0, collectionViewContentHeight - 1.0, 1.0, 1.0), animated: animated)
        }
    }
    
    func scrollToTop(animated: Bool = false) {
        performBatchUpdates(nil) { _ in
            self.scrollRectToVisible(CGRect(0.0, 0.0, 1.0, 1.0), animated: animated)
        }
    }
    
    func reloadDataAndKeepOffset() {
        // stop scrolling
        setContentOffset(contentOffset, animated: false)
        let offset = contentOffset.y
        // calculate the offset and reloadData
        let beforeContentSize = contentSize
        reloadData()
//        reloadData()
        layoutIfNeeded()
        setNeedsLayout()
        let afterContentSize = contentSize
        
        // reset the contentOffset after data is updated
        let newOffset = CGPoint(
            x: contentOffset.x + (afterContentSize.width - beforeContentSize.width),
            y: contentOffset.y - (beforeContentSize.height - afterContentSize.height))
        setContentOffset(newOffset, animated: false)
    }

    /// Registers a particular cell using its reuse-identifier
    func register<T: UICollectionViewCell>(_ cellClass: T.Type) {
        register(cellClass, forCellWithReuseIdentifier: String(describing: T.self))
    }

    /// Registers a reusable view for a specific SectionKind
    func register<T: UICollectionReusableView>(_ headerFooterClass: T.Type, forSupplementaryViewOfKind kind: String) {
        register(headerFooterClass,
                 forSupplementaryViewOfKind: kind,
                 withReuseIdentifier: String(describing: T.self))
    }

    /// Generically dequeues a cell of the correct type allowing you to avoid scattering your code with guard-let-else-fatal
    func dequeueReusableCell<T: UICollectionViewCell>(_ cellClass: T.Type, for indexPath: IndexPath) -> T {
        guard let cell = dequeueReusableCell(withReuseIdentifier: String(describing: T.self), for: indexPath) as? T else {
            fatalError("Unable to dequeue \(String(describing: cellClass)) with reuseId of \(String(describing: T.self))")
        }
        return cell
    }

    /// Generically dequeues a header of the correct type allowing you to avoid scattering your code with guard-let-else-fatal
    func dequeueReusableHeaderView<T: UICollectionReusableView>(_ viewClass: T.Type, for indexPath: IndexPath) -> T {
        let view = dequeueReusableSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: String(describing: T.self), for: indexPath)
        guard let viewType = view as? T else {
            fatalError("Unable to dequeue \(String(describing: viewClass)) with reuseId of \(String(describing: T.self))")
        }
        return viewType
    }

    /// Generically dequeues a footer of the correct type allowing you to avoid scattering your code with guard-let-else-fatal
    func dequeueReusableFooterView<T: UICollectionReusableView>(_ viewClass: T.Type, for indexPath: IndexPath) -> T {
        let view = dequeueReusableSupplementaryView(ofKind: UICollectionView.elementKindSectionFooter, withReuseIdentifier: String(describing: T.self), for: indexPath)
        guard let viewType = view as? T else {
            fatalError("Unable to dequeue \(String(describing: viewClass)) with reuseId of \(String(describing: T.self))")
        }
        return viewType
    }
    
    

}
