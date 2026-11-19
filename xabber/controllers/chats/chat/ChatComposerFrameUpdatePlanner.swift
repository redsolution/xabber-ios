import CoreGraphics
import Foundation
import UIKit

struct ChatComposerKeyboardLayoutMetrics: Equatable {
    let visualHeight: CGFloat
    let collectionObstructionHeight: CGFloat

    static func make(
        visualHeight: CGFloat,
        visibleKeyboardHeight: CGFloat,
        bottomSafeAreaHeight: CGFloat,
        searchOwnsKeyboard: Bool,
        stickerPanelHeight: CGFloat? = nil
    ) -> ChatComposerKeyboardLayoutMetrics {
        let resolvedVisualHeight = max(0, visualHeight)
        guard !searchOwnsKeyboard else {
            return ChatComposerKeyboardLayoutMetrics(
                visualHeight: resolvedVisualHeight,
                collectionObstructionHeight: resolvedVisualHeight
            )
        }

        if let stickerPanelHeight {
            return ChatComposerKeyboardLayoutMetrics(
                visualHeight: resolvedVisualHeight,
                collectionObstructionHeight: max(0, stickerPanelHeight) + max(0, bottomSafeAreaHeight)
            )
        }

        let resolvedKeyboardHeight = max(0, visibleKeyboardHeight)
        let lowerObstruction = resolvedKeyboardHeight > 0
            ? resolvedKeyboardHeight
            : max(0, bottomSafeAreaHeight)
        return ChatComposerKeyboardLayoutMetrics(
            visualHeight: resolvedVisualHeight,
            collectionObstructionHeight: resolvedVisualHeight + lowerObstruction
        )
    }
}

enum ChatStickerPanelLayout {
    static func contentHeight(
        viewHeight: CGFloat,
        topSafeAreaHeight: CGFloat,
        bottomSafeAreaHeight: CGFloat,
        dockedKeyboardHeight: CGFloat?,
        composerHeight: CGFloat
    ) -> CGFloat {
        let contentSpace = max(0, viewHeight - topSafeAreaHeight - bottomSafeAreaHeight)
        let composerHeight = max(0, composerHeight)
        if let dockedKeyboardHeight, dockedKeyboardHeight > bottomSafeAreaHeight {
            return min(dockedKeyboardHeight - bottomSafeAreaHeight + composerHeight, contentSpace)
        }
        let fallbackHeight = min(contentSpace * 0.42, 360)
        return min(fallbackHeight + composerHeight, contentSpace * 0.55)
    }

    static func dockedKeyboardHeight(in bounds: CGRect, keyboardFrame: CGRect) -> CGFloat? {
        let overlap = bounds.intersection(keyboardFrame)
        guard !overlap.isNull, overlap.height >= 150, overlap.width >= bounds.width * 0.9,
              keyboardFrame.maxY >= bounds.maxY - 1 else {
            return nil
        }
        return overlap.height
    }
}

enum ChatKeyboardMotionPolicy {
    static func isInteractiveUpdate(
        usesInteractiveDismissMode: Bool,
        isTracking: Bool,
        isDragging: Bool
    ) -> Bool {
        usesInteractiveDismissMode && (isTracking || isDragging)
    }
}

struct ChatKeyboardLayoutUpdateSignature: Equatable {
    let visibleHeight: CGFloat
    let viewSize: CGSize
    let searchOwnsKeyboard: Bool
}

struct ChatKeyboardLayoutUpdatePolicy {
    static func shouldApply(
        previous: ChatKeyboardLayoutUpdateSignature?,
        next: ChatKeyboardLayoutUpdateSignature
    ) -> Bool {
        previous != next
    }
}

enum ChatKeyboardViewportOffsetPolicy {
    static func targetContentOffsetY(
        previousContentOffsetY: CGFloat,
        previousBottomInset: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        newContentInsets: UIEdgeInsets
    ) -> CGFloat {
        let minimumOffsetY = -newContentInsets.top
        guard viewportHeight > 0 else {
            return minimumOffsetY
        }

        let maximumOffsetY = max(
            minimumOffsetY,
            max(0, contentHeight) - viewportHeight + newContentInsets.bottom
        )
        let bottomInsetDelta = newContentInsets.bottom - previousBottomInset
        guard abs(bottomInsetDelta) > 0.001 else {
            return previousContentOffsetY
        }
        let requestedOffsetY = previousContentOffsetY + bottomInsetDelta
        return min(max(requestedOffsetY, minimumOffsetY), maximumOffsetY)
    }
}

enum ChatKeyboardFrameViewportPolicy {
    static func shouldCaptureVisibleAnchor(wasNearBottom: Bool) -> Bool {
        false
    }

    static func anchorRestoration(wasNearBottom: Bool) -> ChatComposerFrameAnchorRestoration {
        wasNearBottom ? .bottom : .none
    }
}

enum ChatComposerFrameUpdateSource: Equatable {
    case containerBounds
    case keyboardFrame
    case composerHeight
    case stickerPanel
}

enum ChatComposerFrameAnchorRestoration: Equatable {
    case none
    case bottom
    case visibleAnchor
}

struct ChatComposerFrameUpdateRequest: Equatable {
    let source: ChatComposerFrameUpdateSource
    let hasMessages: Bool
    let previousInputHeight: CGFloat
    let inputHeight: CGFloat
    let anchorRestoration: ChatComposerFrameAnchorRestoration
}

enum ChatComposerFrameUpdateAction: Equatable {
    case updateInsets(CGFloat)
    case updateInitialMessageOverlayFrame
    case invalidateLayoutCache
    case invalidateLayout
    case reloadData
    case layoutIfNeeded
    case preserveViewportForInsetChange
    case scrollToBottom
    case alignBottomToCurrentInsets
    case restoreVisibleAnchor
}

struct ChatComposerFrameUpdatePlanner {
    static func actions(for request: ChatComposerFrameUpdateRequest) -> [ChatComposerFrameUpdateAction] {
        var actions: [ChatComposerFrameUpdateAction] = [
            .updateInsets(request.inputHeight),
            .updateInitialMessageOverlayFrame
        ]
        let shouldUpdateCollection = request.hasMessages || request.source != .containerBounds
        guard shouldUpdateCollection else {
            return actions
        }

        if request.source == .containerBounds {
            actions.append(.invalidateLayoutCache)
            actions.append(.invalidateLayout)
        }

        let usesInsetOnlyAlignment = request.source == .keyboardFrame || request.source == .stickerPanel
        let shouldForceLayout = !usesInsetOnlyAlignment || request.anchorRestoration == .visibleAnchor
        if shouldForceLayout {
            actions.append(.layoutIfNeeded)
            actions.append(.updateInsets(request.inputHeight))
        }

        if request.source == .keyboardFrame,
           request.hasMessages,
           request.anchorRestoration == .none {
            actions.append(.preserveViewportForInsetChange)
        }

        switch request.anchorRestoration {
        case .none:
            break
        case .bottom:
            if usesInsetOnlyAlignment {
                actions.append(.alignBottomToCurrentInsets)
            } else {
                actions.append(.scrollToBottom)
            }
        case .visibleAnchor:
            actions.append(.restoreVisibleAnchor)
        }

        return actions
    }
}
