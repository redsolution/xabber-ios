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

internal enum MessageKitError {
    internal static let avatarPositionUnresolved = "AvatarPosition Horizontal.natural needs to be resolved."
    internal static let nilMessagesDataSource = "MessagesDataSource has not been set."
    internal static let nilMessagesDisplayDelegate = "MessagesDisplayDelegate has not been set."
    internal static let nilMessagesLayoutDelegate = "MessagesLayoutDelegate has not been set."
    internal static let notMessagesCollectionView = "The collectionView is not a MessagesCollectionView."
    internal static let layoutUsedOnForeignType = "MessagesCollectionViewFlowLayout is being used on a foreign type."
    internal static let unrecognizedSectionKind = "Received unrecognized element kind:"
    internal static let unrecognizedCheckingResult = "Received an unrecognized NSTextCheckingResult.CheckingType"
    internal static let couldNotLoadAssetsBundle = "MessageKit: Could not load the assets bundle"
    internal static let couldNotCreateAssetsPath = "MessageKit: Could not create path to the assets bundle."
    internal static let customDataUnresolvedCell = "Did not return a cell for MessageKind.custom(Any)."
    internal static let customDataUnresolvedSize = "Did not return a size for MessageKind.custom(Any)."
}
