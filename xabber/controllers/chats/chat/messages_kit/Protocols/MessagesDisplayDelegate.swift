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

import Foundation
import UIKit
import MapKit
import MaterialComponents.MDCPalettes


protocol MessagesDisplayDelegate: AnyObject {

    func shouldDrawCertIcon() -> Bool
    
    func messageErrorIcon(for message: MessageType, at indexPath: IndexPath, on messagesCollectionView: MessagesCollectionView) -> String?
    
    func messageStyle(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> MessageStyle

    func backgroundColor(for message: MessageType, at  indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> UIColor

    func isSelected(for message: MessageType, at  indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> Bool
    
    func forwardIndicatorPadding(at indexPath: IndexPath) -> CGFloat
    
    func forwardedFillColor(for message: MessageType, at  indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> UIColor?
    
    func forwardedBackgroundColor(for message: MessageType, at  indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> UIColor
    
    func deliveryState(at indexPath: IndexPath) -> MessageStorageItem.MessageSendingState
    
    func mediaSendString(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString?
    
    func shouldShowLoadingIndicator(for message: MessageType, at indexPath: IndexPath) -> Bool
    
    func messageDateLabel(at indexPath: IndexPath) -> NSAttributedString?

    func messageHeaderView(for indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> MessageReusableView

    func messageFooterView(for indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> MessageReusableView

    func urlForAvatarView(at indexPath: IndexPath) -> URL?
    func metadataForAvatarView(at indexPath: IndexPath) -> MessageAvatarMetadata?

    func enabledDetectors(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> [DetectorType]

    func detectorAttributes(for detector: DetectorType, and message: MessageType, at indexPath: IndexPath) -> [NSAttributedString.Key: Any]

    func snapshotOptionsForLocation(message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> LocationMessageSnapshotOptions

    func annotationViewForLocation(message: MessageType, at indexPath: IndexPath, in messageCollectionView: MessagesCollectionView) -> MKAnnotationView?

    func animationBlockForLocation(message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> ((UIImageView) -> Void)?
    
    func inlineAccountColor() -> UIColor
    
    func accountPalette() -> MDCPalette
    
    func pairedAccountPalette() -> MDCPalette
    
    func initialMessageIcon() -> UIImage?
    
    func initialMessageTitle() -> String?
    
    func initialMessageFooter() -> String?
    
    func isBurnedMessage(at indexPath: IndexPath) -> Bool
}

extension MessagesDisplayDelegate {

    // MARK: - All Messages Defaults

    func shouldDrawCertIcon() -> Bool {
        return false
    }
    
    func messageErrorIcon(for message: MessageType, at indexPath: IndexPath, on messagesCollectionView: MessagesCollectionView) -> String? {
        return nil
    }
    
    func messageStyle(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> MessageStyle {
        return .bubble(.bottomRight)
    }

    func isSelected(for message: MessageType, at  indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> Bool {
        return false
    }
    
    func forwardIndicatorPadding(at indexPath: IndexPath) -> CGFloat {
        return 0
    }
    
    func forwardedFillColor(for message: MessageType, at  indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> UIColor? {
        return nil
    }
    
    func forwardedBackgroundColor(for message: MessageType, at  indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> UIColor {
        return UIColor.blue.withAlphaComponent(0.05)
    }
    
    func deliveryState(at indexPath: IndexPath) -> MessageStorageItem.MessageSendingState {
        return .none
    }
    
    func backgroundColor(for message: MessageType, at  indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> UIColor {

        switch message.kind {
        case .emoji:
            return .clear
        default:
            guard let dataSource = messagesCollectionView.messagesDataSource else { return .white }
            return dataSource.isFromCurrentSender(message: message) ? .outgoingGreen : .incomingGray
        }
    }
    
    func messageDateLabel(at indexPath: IndexPath) -> NSAttributedString? {
        return nil
    }
    
    func messageHeaderView(for indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> MessageReusableView {
        return messagesCollectionView.dequeueReusableHeaderView(MessageReusableView.self, for: indexPath)
    }

    func messageFooterView(for indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> MessageReusableView {
        print("FOOOTER")
        return messagesCollectionView.dequeueReusableFooterView(MessageReusableView.self, for: indexPath)
    }
    
    func configureAvatarView(_ avatarView: AvatarView, for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) {
        avatarView.initials = "?"
    }

    func urlForAvatarView(at indexPath: IndexPath) -> URL? {
        return nil
    }
    
    func metadataForAvatarView(at indexPath: IndexPath) -> MessageAvatarMetadata?  {
        return nil
    }

    func mediaSendString(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        return nil
    }
    
    func shouldShowLoadingIndicator(for message: MessageType, at indexPath: IndexPath) -> Bool {
        return false
    }
    
    func enabledDetectors(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> [DetectorType] {
        return []
    }

    func detectorAttributes(for detector: DetectorType, and message: MessageType, at indexPath: IndexPath) -> [NSAttributedString.Key: Any] {
        return MessageLabel.defaultAttributes
    }
    
    func snapshotOptionsForLocation(message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> LocationMessageSnapshotOptions {
        return LocationMessageSnapshotOptions()
    }

    func annotationViewForLocation(message: MessageType, at indexPath: IndexPath, in messageCollectionView: MessagesCollectionView) -> MKAnnotationView? {
        return MKPinAnnotationView(annotation: nil, reuseIdentifier: nil)
    }

    func animationBlockForLocation(message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> ((UIImageView) -> Void)? {
        return nil
    }
    
    func inlineAccountColor() -> UIColor {
        return .gray
    }
    
    func pairedAccountPalette() -> MDCPalette {
        return MDCPalette.cyan
    }
    
    func accountPalette() -> MDCPalette {
        return MDCPalette.blue
    }
    
    func initialMessageIcon() -> UIImage? {
        return nil
    }
    
    func initialMessageTitle() -> String? {
        return nil
    }
    
    func initialMessageSubtitle() -> String? {
        return nil
    }
    
    
    func initialMessageFooter() -> String? {
        return nil
    }
}
