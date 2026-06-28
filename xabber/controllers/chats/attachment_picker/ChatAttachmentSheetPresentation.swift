import UIKit

enum ChatAttachmentSheetPresentationState: Equatable {
    case compact
    case expanded
}

protocol ChatAttachmentSheetPresentationStateObserving: AnyObject {
    func chatAttachmentSheetPresentationStateDidChange(_ state: ChatAttachmentSheetPresentationState)
}

protocol ChatAttachmentSheetPresentationRequesting: AnyObject {
    var onSheetPresentationStateRequested: ((ChatAttachmentSheetPresentationState) -> Void)? { get set }
    var onDismissRequested: (() -> Void)? { get set }
}

enum ChatAttachmentPickerPageSheetStyle {
    static func apply(to viewController: UIViewController) {
        viewController.modalPresentationStyle = .pageSheet
        viewController.transitioningDelegate = nil
        viewController.isModalInPresentation = false

        guard let sheetPresentationController = viewController.sheetPresentationController else {
            return
        }

        sheetPresentationController.detents = [.large()]
        sheetPresentationController.selectedDetentIdentifier = .large
        sheetPresentationController.prefersGrabberVisible = false
        sheetPresentationController.preferredCornerRadius = ChatAttachmentSheetGlassStyle.sheetCornerRadius
    }
}
