import UIKit

enum ChatStickerLayoutPolicy {
    static let maximumSide: CGFloat = 192

    static func renderedSize(
        sourceSize: CGSize,
        availableWidth: CGFloat
    ) -> CGSize {
        let maximum = max(1, min(maximumSide, availableWidth))
        guard sourceSize.width.isFinite,
              sourceSize.height.isFinite,
              sourceSize.width > 0,
              sourceSize.height > 0 else {
            return CGSize(width: maximum, height: maximum)
        }
        let scale = min(maximum / sourceSize.width, maximum / sourceSize.height, 1)
        return CGSize(
            width: max(1, (sourceSize.width * scale).rounded(.toNearestOrAwayFromZero)),
            height: max(1, (sourceSize.height * scale).rounded(.toNearestOrAwayFromZero))
        )
    }
}

enum ChatStickerPlaceholder {
    static let color = UIColor.secondarySystemFill
}
