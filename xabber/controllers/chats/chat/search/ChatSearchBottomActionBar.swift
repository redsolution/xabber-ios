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

struct ChatSearchBottomActionBarLayout {
    struct Frames: Equatable {
        let leadingCapsule: CGRect
        let trailingCapsule: CGRect
    }

    static let height: CGFloat = 40
    static let minimumControlWidth: CGFloat = 40
    static let minimumSpacing: CGFloat = 8
    static let preferredLeadingWidth: CGFloat = 144
    static let preferredTrailingWidth: CGFloat = 124

    static func frames(
        in bounds: CGRect,
        safeAreaInsets: UIEdgeInsets
    ) -> Frames {
        let minimumX = bounds.minX + max(0, safeAreaInsets.left)
        let maximumX = bounds.maxX - max(0, safeAreaInsets.right)
        let availableWidth = max(0, maximumX - minimumX)
        let controlHeight = min(height, max(0, bounds.height))
        let originY = bounds.minY + max(0, (bounds.height - controlHeight) / 2)

        guard availableWidth >= minimumControlWidth * 2 + minimumSpacing else {
            let width = max(0, (availableWidth - minimumSpacing) / 2)
            return Frames(
                leadingCapsule: CGRect(x: minimumX, y: originY, width: width, height: controlHeight),
                trailingCapsule: CGRect(
                    x: maximumX - width,
                    y: originY,
                    width: width,
                    height: controlHeight
                )
            )
        }

        let trailingWidth = min(
            preferredTrailingWidth,
            availableWidth - minimumSpacing - minimumControlWidth
        )
        let leadingWidth = min(
            preferredLeadingWidth,
            availableWidth - minimumSpacing - trailingWidth
        )
        return Frames(
            leadingCapsule: CGRect(
                x: minimumX,
                y: originY,
                width: leadingWidth,
                height: controlHeight
            ),
            trailingCapsule: CGRect(
                x: maximumX - trailingWidth,
                y: originY,
                width: trailingWidth,
                height: controlHeight
            )
        )
    }
}

struct ChatSearchBottomCountFormatter {
    typealias Localizer = (_ fallback: String, _ key: String, _ arguments: [String]) -> String

    private let localize: Localizer

    init(localize: @escaping Localizer = { fallback, key, arguments in
        fallback.localizeString(id: key, arguments: arguments)
    }) {
        self.localize = localize
    }

    func current(_ zeroBasedIndex: Int, total: Int) -> String {
        localize(
            "%@ of %@",
            "chat_search_current_of_total",
            ["\(max(0, zeroBasedIndex) + 1)", "\(max(0, total))"]
        )
    }

    func messages(total: Int) -> String {
        let nonnegativeTotal = max(0, total)
        switch nonnegativeTotal {
        case 0:
            return localize("No messages", "chat_search_no_messages", [])
        case 1:
            return localize("1 message", "chat_search_one_message", [])
        default:
            return localize(
                "%@ messages",
                "chat_search_messages_count",
                ["\(nonnegativeTotal)"]
            )
        }
    }
}
