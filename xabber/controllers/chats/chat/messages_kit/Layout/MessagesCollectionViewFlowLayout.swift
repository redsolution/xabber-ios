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
import AVFoundation

/// The layout object used by `MessagesCollectionView` to determine the size of all
/// framework provided `MessageCollectionViewCell` subclasses.
class MessagesCollectionViewFlowLayout: UICollectionViewFlowLayout {

    internal final let cache: MessageSizeCache = MessageSizeCache()
    
    override class var layoutAttributesClass: AnyClass {
//        let lay = UICollectionViewLayout()
        return MessagesCollectionViewLayoutAttributes.self
    }
    
    public var messagesCollectionView: MessagesCollectionView {
        guard let messagesCollectionView = collectionView as? MessagesCollectionView else {
            fatalError(MessageKitError.layoutUsedOnForeignType)
        }
        return messagesCollectionView
    }
    
    var messagesDataSource: MessagesDataSource {
        guard let messagesDataSource = messagesCollectionView.messagesDataSource else {
            fatalError(MessageKitError.nilMessagesDataSource)
        }
        return messagesDataSource
    }
    
    var messagesLayoutDelegate: MessagesLayoutDelegate {
        guard let messagesLayoutDelegate = messagesCollectionView.messagesLayoutDelegate else {
            fatalError(MessageKitError.nilMessagesLayoutDelegate)
        }
        return messagesLayoutDelegate
    }

    var itemWidth: CGFloat {
        guard let collectionView = collectionView else { return 0 }
        return collectionView.frame.width - sectionInset.horizontal
    }
    
    override init() {
        super.init()
        self.sectionFootersPinToVisibleBounds = true
//        self.sectionHeadersPinToVisibleBounds = true
//        sectionInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        NotificationCenter.default.addObserver(self, selector: #selector(MessagesCollectionViewFlowLayout.handleOrientationChange(_:)), name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cache.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let attributesArray = super.layoutAttributesForElements(in: rect) as? [MessagesCollectionViewLayoutAttributes] else {
            return nil
        }
        for attributes in attributesArray where attributes.representedElementCategory == .cell {
            let cellSizeCalculator = cellSizeCalculatorForItem(at: attributes.indexPath)
            cellSizeCalculator.configure(attributes: attributes)
        }
//        guard let attributes = super.layoutAttributesForElements(in: rect) else {
//            return attributesArray
//        }
//        for attribute in attributes {
//            adjustAttributesIfNeeded(attribute)
//        }
        return attributesArray
    }
    
    func adjustAttributesIfNeeded(_ attributes: UICollectionViewLayoutAttributes) {
        switch attributes.representedElementKind {
            case UICollectionView.elementKindSectionHeader?:
                adjustHeaderAttributesIfNeeded(attributes)
            case UICollectionView.elementKindSectionFooter?:
                adjustFooterAttributesIfNeeded(attributes)
        default:
            break
        }
    }
    
    override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let attributes = super.layoutAttributesForSupplementaryView(ofKind: elementKind, at: indexPath) else { return nil }
        adjustAttributesIfNeeded(attributes)
        return attributes
    }
    
    private func adjustHeaderAttributesIfNeeded(_ attributes: UICollectionViewLayoutAttributes) {
        guard let collectionView = collectionView else { return }
        guard attributes.indexPath.section == 0 else { return }
        
        
        if collectionView.contentOffset.y < 0 {
            attributes.frame.origin.y = collectionView.contentOffset.y
        }
    }

    private func adjustFooterAttributesIfNeeded(_ attributes: UICollectionViewLayoutAttributes) {
        guard let collectionView = collectionView else { return }
        guard attributes.indexPath.section == collectionView.numberOfSections - 1 else { return }
        
        if collectionView.contentOffset.y + collectionView.bounds.size.height > collectionView.contentSize.height {
            attributes.frame.origin.y = collectionView.contentOffset.y + collectionView.bounds.size.height - attributes.frame.size.height
        }
    }
    
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let attributes = super.layoutAttributesForItem(at: indexPath) as? MessagesCollectionViewLayoutAttributes else {
            return nil
        }
        if attributes.representedElementCategory == .cell {
            let cellSizeCalculator = cellSizeCalculatorForItem(at: attributes.indexPath)
            cellSizeCalculator.configure(attributes: attributes)
        }
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        return collectionView?.bounds.width != newBounds.width
    }

    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        guard let flowLayoutContext = context as? UICollectionViewFlowLayoutInvalidationContext else { return context }
        flowLayoutContext.invalidateFlowLayoutDelegateMetrics = shouldInvalidateLayout(forBoundsChange: newBounds)
        return flowLayoutContext
    }

    @objc
    private func handleOrientationChange(_ notification: Notification) {
        invalidateLayout()
        cache.invalidate()
    }

    lazy var commonMessageSizeCalculator = CommonMessageSizeCalculator(layout: self)
    lazy var systemMessageSizeCalculator = SystemMessageSizeCalculator(layout: self)
    lazy var initialMessageSizeCalculator = InitialMessageSizeCalculator(layout: self)
    lazy var callMessageSizeCalculator = CallMessageSizeCalculator(layout: self)

    func cellSizeCalculatorForItem(at indexPath: IndexPath) -> CellSizeCalculator {
        let message = messagesDataSource.messageForItem(at: indexPath, in: messagesCollectionView)
        switch message.kind {
            case .attributedText, .emoji, .skeleton(_):
                return commonMessageSizeCalculator
            case .system, .date, .unread, .call(_):
                return systemMessageSizeCalculator
            case .sticker(_):
                return callMessageSizeCalculator//stickerMessageSizeCalculator
            case .initial(_):
                return initialMessageSizeCalculator
//            case .call(_):
//                return callMessageSizeCalculator
        }
    }

    func sizeForItem(at indexPath: IndexPath) -> CGSize {
        let message = messagesDataSource.messageForItem(at: indexPath, in: messagesCollectionView)
//        if let size = cache.get(for: message.primary) {
//            return size
//        } else {
            let calculator: CellSizeCalculator
            switch message.kind {
                case .attributedText, .emoji, .skeleton(_):
                    calculator = commonMessageSizeCalculator
                case .system, .date, .unread, .call(_):
                    calculator = systemMessageSizeCalculator
                case .sticker(_):
                    calculator = callMessageSizeCalculator
                case .initial(_):
                    calculator = initialMessageSizeCalculator
//                case .call(_):
//                    calculator = systemMessageSizeCalculator
            }
            let size = calculator.sizeForItem(at: indexPath)
//            cache.cache(for: message.primary, size: size)
            return size
//        }
    }
    
//    func setMessageIncomingMessagePadding(_ newPadding: UIEdgeInsets) {
//        messageSizeCalculators().forEach { $0.incomingMessagePadding = newPadding }
//    }
//    
//    func setMessageOutgoingMessagePadding(_ newPadding: UIEdgeInsets) {
//        messageSizeCalculators().forEach { $0.outgoingMessagePadding = newPadding }
//    }
//    
//    func setMessageIncomingMessageTopLabelAlignment(_ newAlignment: LabelAlignment) {
//        messageSizeCalculators().forEach { $0.incomingMessageTopLabelAlignment = newAlignment }
//    }
//    
//    func setMessageOutgoingMessageTopLabelAlignment(_ newAlignment: LabelAlignment) {
//        messageSizeCalculators().forEach { $0.outgoingMessageTopLabelAlignment = newAlignment }
//    }
//    
//    func setMessageIncomingMessageBottomLabelAlignment(_ newAlignment: LabelAlignment) {
//        messageSizeCalculators().forEach { $0.incomingMessageBottomLabelAlignment = newAlignment }
//    }
//    
//    func setMessageOutgoingMessageBottomLabelAlignment(_ newAlignment: LabelAlignment) {
//        messageSizeCalculators().forEach { $0.outgoingMessageBottomLabelAlignment = newAlignment }
//    }
    
    func messageSizeCalculators() -> [CellSizeCalculator] {
//        return [commonMessageSizeCalculator, mediaMessageSizeCalculator, locationMessageSizeCalculator]
        return []
    }
    
    public final func invalidateLastMessageCachedSize(primary: String?) {
        if let primary = primary {
            cache.invalidate(for: primary)
        }
    }
    
}
