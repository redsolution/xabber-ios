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

        sectionInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

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
        return attributesArray
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
    lazy var quoteMessageSizeCalculator = QuoteMessageSizeCalculator(layout: self)
    lazy var systemMessageSizeCalculator = SystemMessageSizeCalculator(layout: self)
    lazy var mediaMessageSizeCalculator = MediaMessageSizeCalculator(layout: self)
    lazy var locationMessageSizeCalculator = LocationMessageSizeCalculator(layout: self)
    lazy var stickerMessageSizeCalculator = StickerMessageSizeCalculator(layout: self)
    lazy var initialMessageSizeCalculator = InitialMessageSizeCalculator(layout: self)

    
    
    func cellSizeCalculatorForItem(at indexPath: IndexPath) -> CellSizeCalculator {
        let message = messagesDataSource.messageForItem(at: indexPath, in: messagesCollectionView)
        switch message.kind {
        case .text, .attributedText, .emoji, .skeleton(_):
            return commonMessageSizeCalculator
        case .quote:
            return quoteMessageSizeCalculator
        case .system:
            return systemMessageSizeCalculator
        case .location:
            return locationMessageSizeCalculator
        case .sticker(_):
            return stickerMessageSizeCalculator
        case .initial(_):
            return initialMessageSizeCalculator
        case .custom:
            fatalError("Must return a CellSizeCalculator for MessageKind.custom(Any?)")
        case .photos(_), .videos(_), .files(_), .audio(_), .call(_):
            return mediaMessageSizeCalculator
        }
    }

    func sizeForItem(at indexPath: IndexPath) -> CGSize {
        let message = messagesDataSource.messageForItem(at: indexPath, in: messagesCollectionView)
        if let size = cache.get(for: message.primary) {
            return size
        } else {
            let calculator: CellSizeCalculator
            switch message.kind {
            case .text, .attributedText, .emoji, .skeleton(_):
                calculator = commonMessageSizeCalculator
            case .quote:
                calculator = quoteMessageSizeCalculator
            case .system:
                calculator = systemMessageSizeCalculator
            case .location:
                calculator = locationMessageSizeCalculator
            case .sticker(_):
                calculator = stickerMessageSizeCalculator
            case .initial(_):
                calculator = initialMessageSizeCalculator
            case .custom:
                fatalError("Must return a CellSizeCalculator for MessageKind.custom(Any?)")
            case .photos(_), .videos(_), .files(_), .audio(_), .call(_):
                calculator = mediaMessageSizeCalculator
            }
            let size = calculator.sizeForItem(at: indexPath)
            cache.cache(for: message.primary, size: size)
            return size
        }
    }
    
    func setMessageIncomingMessagePadding(_ newPadding: UIEdgeInsets) {
        messageSizeCalculators().forEach { $0.incomingMessagePadding = newPadding }
    }
    
    func setMessageOutgoingMessagePadding(_ newPadding: UIEdgeInsets) {
        messageSizeCalculators().forEach { $0.outgoingMessagePadding = newPadding }
    }
    
    func setMessageIncomingMessageTopLabelAlignment(_ newAlignment: LabelAlignment) {
        messageSizeCalculators().forEach { $0.incomingMessageTopLabelAlignment = newAlignment }
    }
    
    func setMessageOutgoingMessageTopLabelAlignment(_ newAlignment: LabelAlignment) {
        messageSizeCalculators().forEach { $0.outgoingMessageTopLabelAlignment = newAlignment }
    }
    
    func setMessageIncomingMessageBottomLabelAlignment(_ newAlignment: LabelAlignment) {
        messageSizeCalculators().forEach { $0.incomingMessageBottomLabelAlignment = newAlignment }
    }
    
    func setMessageOutgoingMessageBottomLabelAlignment(_ newAlignment: LabelAlignment) {
        messageSizeCalculators().forEach { $0.outgoingMessageBottomLabelAlignment = newAlignment }
    }
    
    func messageSizeCalculators() -> [MessageSizeCalculator] {
        return [commonMessageSizeCalculator, mediaMessageSizeCalculator, locationMessageSizeCalculator]
    }
    
    public final func invalidateLastMessageCachedSize(primary: String?) {
        if let primary = primary {
            cache.invalidate(for: primary)
        }
    }
    
}
