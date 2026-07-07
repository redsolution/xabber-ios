import CoreGraphics
import Foundation

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
    case scrollToBottom
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

        switch request.anchorRestoration {
        case .none:
            break
        case .bottom:
            if request.source != .keyboardFrame {
                actions.append(.scrollToBottom)
            }
        case .visibleAnchor:
            actions.append(.restoreVisibleAnchor)
        }

        return actions
    }
}
