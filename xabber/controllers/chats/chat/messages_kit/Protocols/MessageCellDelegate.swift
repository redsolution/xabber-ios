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

/// A protocol used by `MessageContentCell` subclasses to detect taps in the cell's subviews.
public protocol MessageCellDelegate: MessageLabelDelegate {

    func didTap(in cell: MessageCollectionViewCell)
    
    func didTapMessage(in cell: MessageCollectionViewCell)

    func didTapAvatar(in cell: MessageCollectionViewCell)

    func didTapCellTopLabel(in cell: MessageCollectionViewCell)
    
    func didTapMessageTopLabel(in cell: MessageCollectionViewCell)

    func didTapMessageBottomLabel(in cell: MessageCollectionViewCell)
    
    func onTapAttachment(cell: MessageCollectionViewCell, inlineItem: Bool, messageId: String?, index: Int, isSubforward: Bool)
    
    func onTapVoiceCall(cell: MessageCollectionViewCell)
    
    func onLongTap(cell: MessageCollectionViewCell)
    
    func onSwipe(cell: MessageCollectionViewCell)
    
    func didTapErrorButton(cell: MessageCollectionViewCell)
    
    func didTapOnInitialFooterLabel(in cell: MessageCollectionViewCell)
    
    func isInSelection() -> Bool
}
