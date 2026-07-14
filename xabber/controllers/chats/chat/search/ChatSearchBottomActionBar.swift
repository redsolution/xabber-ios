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
        safeAreaInsets: UIEdgeInsets,
        layoutDirection: UIUserInterfaceLayoutDirection = .leftToRight
    ) -> Frames {
        let minimumX = bounds.minX + max(0, safeAreaInsets.left)
        let maximumX = bounds.maxX - max(0, safeAreaInsets.right)
        let availableWidth = max(0, maximumX - minimumX)
        let controlHeight = min(height, max(0, bounds.height))
        let originY = bounds.minY + max(0, (bounds.height - controlHeight) / 2)

        guard availableWidth >= minimumControlWidth * 2 + minimumSpacing else {
            let width = max(0, (availableWidth - minimumSpacing) / 2)
            let leftToRight = Frames(
                leadingCapsule: CGRect(x: minimumX, y: originY, width: width, height: controlHeight),
                trailingCapsule: CGRect(
                    x: maximumX - width,
                    y: originY,
                    width: width,
                    height: controlHeight
                )
            )
            return resolved(leftToRight, in: bounds, layoutDirection: layoutDirection)
        }

        let trailingWidth = min(
            preferredTrailingWidth,
            availableWidth - minimumSpacing - minimumControlWidth
        )
        let leadingWidth = min(
            preferredLeadingWidth,
            availableWidth - minimumSpacing - trailingWidth
        )
        let leftToRight = Frames(
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
        return resolved(leftToRight, in: bounds, layoutDirection: layoutDirection)
    }

    private static func resolved(
        _ leftToRight: Frames,
        in bounds: CGRect,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> Frames {
        guard layoutDirection == .rightToLeft else { return leftToRight }
        func mirrored(_ frame: CGRect) -> CGRect {
            CGRect(
                x: bounds.minX + bounds.maxX - frame.maxX,
                y: frame.minY,
                width: frame.width,
                height: frame.height
            )
        }
        return Frames(
            leadingCapsule: mirrored(leftToRight.leadingCapsule),
            trailingCapsule: mirrored(leftToRight.trailingCapsule)
        )
    }
}

struct ChatSearchBottomCountFormatter {
    private let localization: ChatSearchLocalization

    init(localization: ChatSearchLocalization = .production()) {
        self.localization = localization
    }

    func current(_ zeroBasedIndex: Int, total: Int) -> String {
        localization.currentPosition(
            zeroBasedIndex: zeroBasedIndex,
            total: total
        ) ?? localization.messageCount(total)
    }

    func messages(total: Int) -> String {
        localization.messageCount(total)
    }
}
