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

class MediaMessageSizeCalculator: MessageSizeCalculator {

    var incomingMediaInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
    var outgoingMediaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
    
    override func messageContainerSize(for message: MessageType) -> CGSize {
        let maxWidth = messageContainerMaxWidth(for: message) > MessagesViewController.maxWidthForMessages ? MessagesViewController.maxWidthForMessages : messageContainerMaxWidth(for: message)
        let maxHeight: CGFloat = UIScreen.main.bounds.height / 2
        let minHeight: CGFloat = 128
        let minWidth: CGFloat = 128
        let fileHeight: CGFloat = message.withAuthor ? 84 : 60
        let audioHeight: CGFloat = message.withAuthor ? 84 : 60
        
        let sizeForMediaItem = { (maxWidth: CGFloat, sizeUnwr: CGSize?) -> CGSize in
            if let size = sizeUnwr {

                var calculatedWidth = size.width
                var calculatedHeight = size.height

                if size.width > maxWidth {
                    calculatedWidth = maxWidth
                    calculatedHeight = maxWidth * size.height / size.width
                    if calculatedHeight > maxHeight {
                        calculatedWidth = maxHeight * calculatedWidth / calculatedHeight
                        calculatedHeight = maxHeight
                    }
                } else if size.height > maxHeight {
                    calculatedHeight = maxHeight
                    calculatedWidth = maxHeight * size.width / size.height
                    if calculatedWidth > maxWidth {
                        calculatedHeight = maxWidth * calculatedHeight / calculatedWidth
                        calculatedWidth = maxWidth
                    }
                }
                return CGSize(width: max(minWidth, calculatedWidth), height: max(minHeight, calculatedHeight))
            } else {
                return CGSize(width: maxWidth, height: maxWidth)
            }
        }
        
        let sizeForMediaItems = { (maxWidth: CGFloat) -> CGSize in
            return CGSize(width: maxWidth, height: maxWidth)
        }
        
        let sizeForFiles = { (maxWidth: CGFloat, count: Int) -> CGSize in
            return CGSize(width: maxWidth, height: fileHeight * CGFloat(count))
        }
    
        let sizeForAudio = { (maxWidth: CGFloat) -> CGSize in
            return CGSize(width: maxWidth, height: audioHeight)
        }
        
        let sizeForCallMessage = { (maxWidth: CGFloat) -> CGSize in
            return CGSize(width: maxWidth, height: 48)
        }
        
        var out: [CGSize] = inlineForwardsSizes
        switch message.kind {
        case .photos(let items):
            if items.count == 1 {
                out.append(sizeForMediaItem(maxWidth, items.first?.sizeInPx))
            } else {
                out.append(sizeForMediaItems(maxWidth))
            }
        case .videos(_):
            out.append(sizeForMediaItems(maxWidth))
        case .files(let items): //Videos go by .files with mimeType == "video"
            let _ = items.map {
                if $0.mimeType == "video" {
//                    if $0.sizeInPxThumb == nil {
//                        out.append(sizeForMediaItem(maxWidth, CGSize(width: 360, height: 480)))
//                    } else {
                        out.append(sizeForMediaItem(maxWidth, $0.sizeInPx))
//                    }
                } else {
                    out.append(sizeForFiles(maxWidth, 1))
                }
            }
//            out.append(sizeForFiles(maxWidth, items.count))
        case .audio(_):
            out.append(sizeForAudio(maxWidth))
        case .call(_):
            out.append(sizeForCallMessage(200))//184
        default:
            return .zero
        }
        return CGSize(width: out.compactMap { return $0.width }.max() ?? maxWidth,
                      height: out.compactMap { return $0.height }.reduce(0, +) )
    }
    
    override internal func messageLabelInsets(for message: MessageType) -> UIEdgeInsets {
        var outInsets = message.isOutgoing ? outgoingMediaInsets : incomingMediaInsets
        
        if message.forwards.isNotEmpty {
            outInsets.top += 8
        }
        
        return outInsets
    }
}
