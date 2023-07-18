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

/// An enum representing the kind of message and its underlying kind.
enum MessageKind {

    /// A standard text message.
    ///
    /// - Note: The font used for this message will be the value of the
    /// `messageLabelFont` property in the `MessagesCollectionViewFlowLayout` object.
    ///
    /// Using `MessageKind.attributedText(NSAttributedString)` doesn't require you
    /// to set this property and results in higher performance.
    case text(String)
    
    /// A message with attributed text.
    case attributedText(NSAttributedString, Bool, NSAttributedString)
    case quote([MessageStorageItem.QuoteBodyItem], NSAttributedString)
    // Message with array of photo.
    case photos([MessageReferenceStorageItem.Model])
    
    // Message contained single file or files
    case files([MessageReferenceStorageItem.Model])
    
    case audio([MessageReferenceStorageItem.Model])

    /// Message with array of video.
    case videos([MessageReferenceStorageItem.Model])
    
    /// A location message.
    case location(LocationItem)

    /// An emoji message.
    case emoji(String)
    case sticker(MessageReferenceStorageItem.Model)
    
    case call([MessageReferenceStorageItem.Model])
    case system(NSAttributedString)
    case initial(NSAttributedString)
    case skeleton(NSAttributedString)

    /// A custom message.
    /// - Note: Using this case requires that you override the following methods and handle this case:
    ///   - `collectionView(_:cellForItemAt indexPath: IndexPath) -> UICollectionViewCell`
    ///   - `cellSizeCalculatorForItem(at indexPath: IndexPath) -> CellSizeCalculator`
    case custom(Any?)

    // MARK: - Not supported yet

//    case audio(Data)
//
//    case system(String)
//    
//    case placeholder

}
