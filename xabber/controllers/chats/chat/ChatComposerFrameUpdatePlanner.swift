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
        searchOwnsKeyboard: Bool
    ) -> ChatComposerKeyboardLayoutMetrics {
        let resolvedVisualHeight = max(0, visualHeight)
        guard !searchOwnsKeyboard else {
            return ChatComposerKeyboardLayoutMetrics(
                visualHeight: resolvedVisualHeight,
                collectionObstructionHeight: resolvedVisualHeight
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

        let shouldForceLayout = request.source != .keyboardFrame || request.anchorRestoration == .visibleAnchor
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
            if request.source == .keyboardFrame {
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
