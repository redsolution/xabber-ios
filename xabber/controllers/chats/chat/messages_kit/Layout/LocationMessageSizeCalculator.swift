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

class LocationMessageSizeCalculator: MessageSizeCalculator {

    override func messageContainerSize(for message: MessageType) -> CGSize {
        switch message.kind {
        case .location(let item):
            let maxWidth = messageContainerMaxWidth(for: message)
            if maxWidth < item.size.width {
                // Maintain the ratio if width is too great
                let height = maxWidth * item.size.height / item.size.width
                return CGSize(width: [maxWidth, inlineForwardsSizes.compactMap { return $0.width }.max() ?? maxWidth].max() ?? maxWidth,
                              height: inlineForwardsSizes.compactMap { return $0.height }.reduce(0, +) + height)
            }
            return item.size
        default:
            fatalError("messageContainerSize location received unhandled MessageDataType: \(message.kind)")
        }
    }
}
