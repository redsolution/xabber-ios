//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//

import Foundation
import UIKit

public struct MessageAttachmentSizes: Equatable {
    let textLabelSize: CGSize
    let imagesContainerSize: CGSize
    let videosContainerSize: CGSize
    let locationsContainerSize: CGSize
    let contactsContainerSize: CGSize
    let filesContainerSize: CGSize
    let audiosContainerSize: CGSize
    let containerSize: CGSize
    let authorSize: CGSize
    let messageContainer: CGSize
    let timeMarker: CGSize
}

enum ChatLocationAttachmentLayoutPolicy {
    static let itemSpacing: CGFloat = 4

    static func inlineSize(
        for locations: [LocationAttachment],
        max maxSize: CGSize
    ) -> CGSize {
        guard locations.isNotEmpty, maxSize.width > 0 else {
            return .zero
        }
        let count = CGFloat(locations.count)
        let spacing = max(0, count - 1) * itemSpacing
        return CGSize(
            width: maxSize.width,
            height: (maxSize.width * count) + spacing
        )
    }
}

/// Shared immutable geometry constants used by the worker layout calculator
/// and cell subviews. The former synchronous calculator implementation was
/// removed; `ChatMessageLayoutCalculator` is the only measurement path.
enum CommonMessageSizeCalculator {
    static let inlineFileViewHeight: CGFloat = 44
    static let inlineFileViewWidth: CGFloat = 180
    static let inlineContactViewWidth: CGFloat = 230
    static let inlineAudioViewHeight: CGFloat = 44
    static let inlineSubviewPadding: CGFloat = 0
    static let tailWidth: CGFloat = 8
    static let attachmentPadding = UIEdgeInsets(
        top: 0,
        left: 0,
        bottom: 2,
        right: 0
    )
}
