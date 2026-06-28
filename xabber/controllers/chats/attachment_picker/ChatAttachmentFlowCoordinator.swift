import UIKit

struct ChatAttachmentFlowContext {
    let owner: String
    let jid: String
    let conversationType: ClientSynchronizationManager.ConversationType
    let forwardedMessageIds: [String]
    let composerTintColor: UIColor

    init(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        forwardedMessageIds: [String],
        composerTintColor: UIColor = .systemBlue
    ) {
        self.owner = owner
        self.jid = jid
        self.conversationType = conversationType
        self.forwardedMessageIds = forwardedMessageIds
        self.composerTintColor = composerTintColor
    }
}

protocol ChatAttachmentFlowCoordinating: AnyObject {
    func start()
    func switchSource(to source: ChatAttachmentSource)
    func dismiss(animated: Bool)
}

protocol ChatAttachmentFlowCoordinatorDelegate: AnyObject {
    func chatAttachmentFlowCoordinatorDidSend(_ coordinator: ChatAttachmentFlowCoordinator)
    func chatAttachmentFlowCoordinatorDidDismiss(_ coordinator: ChatAttachmentFlowCoordinator)
    func chatAttachmentFlowCoordinator(
        _ coordinator: ChatAttachmentFlowCoordinator,
        didRequestPremiumFor owner: String
    )
    func chatAttachmentFlowCoordinator(
        _ coordinator: ChatAttachmentFlowCoordinator,
        didFailWith error: ChatAttachmentFlowError
    )
}

protocol ChatAttachmentSourceControlling: AnyObject {
    var source: ChatAttachmentSource { get }
    var viewController: UIViewController { get }
    var onSelectionCountChanged: ((Int) -> Void)? { get set }
}

protocol ChatAttachmentSourceControllerFactory {
    func makeController(
        for source: ChatAttachmentSource,
        context: ChatAttachmentFlowContext
    ) -> ChatAttachmentSourceControlling
}

protocol ChatAttachmentCloudStorageQuotaAlertPresenting: AnyObject {
    func presentQuotaExceededAlert(
        from presenter: UIViewController,
        owner: String,
        openCloudStorage: @escaping () -> Void
    )
}

final class UIKitChatAttachmentCloudStorageQuotaAlertPresenter: ChatAttachmentCloudStorageQuotaAlertPresenting {
    func presentQuotaExceededAlert(
        from presenter: UIViewController,
        owner: String,
        openCloudStorage: @escaping () -> Void
    ) {
        let alert = UIAlertController(
            title: ChatAttachmentLocalization.string(.cloudStorageQuotaExceededTitle),
            message: ChatAttachmentLocalization.string(.cloudStorageQuotaExceededMessage),
            preferredStyle: .alert
        )
        alert.addAction(
            UIAlertAction(
                title: ChatAttachmentLocalization.string(.actionCancel),
                style: .cancel
            )
        )
        alert.addAction(
            UIAlertAction(
                title: ChatAttachmentLocalization.string(.cloudStorageQuotaExceededOpenAction),
                style: .default
            ) { _ in
                openCloudStorage()
            }
        )
        presenter.present(alert, animated: true)
    }
}

final class ChatAttachmentFlowCoordinator: ChatAttachmentFlowCoordinating {
    typealias PresentationHandler = (
        UIViewController,
        UIViewController,
        Bool,
        (() -> Void)?
    ) -> Void
    typealias DismissalHandler = (
        UIViewController,
        Bool,
        (() -> Void)?
    ) -> Void
    typealias EndEditingHandler = (
        ChatAttachmentPickerViewController,
        UIViewController
    ) -> Void
    typealias CloudStoragePresentationHandler = (
        UIViewController,
        String
    ) -> Void

    weak var delegate: ChatAttachmentFlowCoordinatorDelegate?

    private weak var presentingViewController: UIViewController?
    private let context: ChatAttachmentFlowContext
    private let sourceControllerFactory: ChatAttachmentSourceControllerFactory
    private let presentationHandler: PresentationHandler
    private let dismissalHandler: DismissalHandler
    private let endEditingHandler: EndEditingHandler
    private let sendCoordinator: ChatAttachmentSendCoordinating
    private let mediaPreparationCoordinator: ChatAttachmentMediaPreparing
    private let quotaRefresher: ChatAttachmentQuotaRefreshing
    private let quotaAlertPresenter: ChatAttachmentCloudStorageQuotaAlertPresenting
    private let cloudStoragePresentationHandler: CloudStoragePresentationHandler

    private(set) var pickerViewController: ChatAttachmentPickerViewController?
    private(set) var pickerNavigationController: UINavigationController?
    var sheetViewController: ChatAttachmentPickerViewController? {
        pickerViewController
    }
    private(set) var selectedItemCount: Int = 0

    init(
        presentingViewController: UIViewController,
        context: ChatAttachmentFlowContext,
        sourceControllerFactory: ChatAttachmentSourceControllerFactory = DefaultChatAttachmentSourceControllerFactory(),
        sendCoordinator: ChatAttachmentSendCoordinating = ChatAttachmentSendPipeline(),
        mediaPreparationCoordinator: ChatAttachmentMediaPreparing = ChatAttachmentMediaPreparationCoordinator(),
        quotaRefresher: ChatAttachmentQuotaRefreshing = CloudStorageQuotaRefreshCoordinatorAdapter(),
        quotaAlertPresenter: ChatAttachmentCloudStorageQuotaAlertPresenting = UIKitChatAttachmentCloudStorageQuotaAlertPresenter(),
        presentationHandler: @escaping PresentationHandler = { presenter, sheet, animated, completion in
            presenter.present(sheet, animated: animated, completion: completion)
        },
        dismissalHandler: @escaping DismissalHandler = { controller, animated, completion in
            guard controller.presentingViewController != nil else {
                completion?()
                return
            }

            controller.dismiss(animated: animated, completion: completion)
        },
        endEditingHandler: @escaping EndEditingHandler = { picker, presentedController in
            picker.previewViewController?.view.endEditing(true)
            picker.view.endEditing(true)
            presentedController.view.endEditing(true)
        },
        cloudStoragePresentationHandler: @escaping CloudStoragePresentationHandler = { sourceController, owner in
            let cloudStorageViewController = CloudStorageViewController()
            cloudStorageViewController.configure(jid: owner)
            if let navigationController = sourceController as? UINavigationController {
                navigationController.pushViewController(cloudStorageViewController, animated: true)
            } else if let navigationController = sourceController.navigationController {
                navigationController.pushViewController(cloudStorageViewController, animated: true)
            } else {
                showModal(cloudStorageViewController, parent: sourceController)
            }
        }
    ) {
        self.presentingViewController = presentingViewController
        self.context = context
        self.sourceControllerFactory = sourceControllerFactory
        self.sendCoordinator = sendCoordinator
        self.mediaPreparationCoordinator = mediaPreparationCoordinator
        self.quotaRefresher = quotaRefresher
        self.quotaAlertPresenter = quotaAlertPresenter
        self.presentationHandler = presentationHandler
        self.dismissalHandler = dismissalHandler
        self.endEditingHandler = endEditingHandler
        self.cloudStoragePresentationHandler = cloudStoragePresentationHandler
    }

    func start() {
        guard let presenter = presentingViewController else {
            delegate?.chatAttachmentFlowCoordinator(self, didFailWith: .missingPresenter)
            return
        }

        guard pickerViewController == nil else {
            return
        }

        guard presenter.presentedViewController == nil else {
            delegate?.chatAttachmentFlowCoordinator(self, didFailWith: .presentationFailed)
            return
        }

        let picker = ChatAttachmentPickerViewController(
            context: context,
            sourceControllerFactory: sourceControllerFactory,
            mediaPreparationCoordinator: mediaPreparationCoordinator
        )
        picker.delegate = self
        picker.navigationItem.largeTitleDisplayMode = .never
        picker.loadViewIfNeeded()
        let navigationController = UINavigationController(rootViewController: picker)
        navigationController.setNavigationBarHidden(false, animated: false)
        navigationController.navigationBar.prefersLargeTitles = false
        ChatAttachmentPickerPageSheetStyle.apply(to: navigationController)
        pickerViewController = picker
        pickerNavigationController = navigationController
        selectedItemCount = picker.selectedItemCount

        refreshCloudStorageStatsOnOpen()
        presentationHandler(presenter, navigationController, true, nil)
    }

    func switchSource(to source: ChatAttachmentSource) {
        pickerViewController?.switchSource(to: source)
    }

    func dismiss(animated: Bool) {
        guard let picker = pickerViewController else {
            return
        }

        let completeDismissal: () -> Void = { [weak self] in
            guard let self else {
                return
            }

            self.finishDismissal(notifyDelegate: true)
        }

        let presentedController = pickerNavigationController ?? picker
        dismissalHandler(presentedController, animated, completeDismissal)
    }

    private func finishDismissal(notifyDelegate: Bool) {
        guard let picker = pickerViewController else {
            return
        }

        picker.delegate = nil
        picker.releaseSourceControllers()
        pickerViewController = nil
        pickerNavigationController = nil
        selectedItemCount = 0

        if notifyDelegate {
            delegate?.chatAttachmentFlowCoordinatorDidDismiss(self)
        }
    }

    private func finishSend() {
        guard let picker = pickerViewController else {
            delegate?.chatAttachmentFlowCoordinatorDidSend(self)
            return
        }

        let presentedController = pickerNavigationController ?? picker
        picker.delegate = nil
        endEditingHandler(picker, presentedController)

        dismissalHandler(presentedController, true) { [weak self] in
            guard let self else {
                return
            }

            self.finishDismissal(notifyDelegate: false)
            self.delegate?.chatAttachmentFlowCoordinatorDidSend(self)
        }
    }

    private func refreshCloudStorageStatsOnOpen() {
        quotaRefresher.refreshQuota(
            owner: context.owner,
            reason: .screenOpen,
            force: true
        ) { _ in }
    }

    private func presentCloudStorageQuotaExceededAlert(owner: String) {
        let presenter = pickerNavigationController ?? pickerViewController ?? presentingViewController
        guard let presenter else {
            delegate?.chatAttachmentFlowCoordinator(self, didFailWith: .sendBlocked(.accountUnavailable))
            return
        }

        quotaAlertPresenter.presentQuotaExceededAlert(
            from: presenter,
            owner: owner
        ) { [weak self, weak presenter] in
            guard let self, let presenter else {
                return
            }

            self.cloudStoragePresentationHandler(presenter, owner)
        }
    }
}

extension ChatAttachmentFlowCoordinator: ChatAttachmentPickerViewControllerDelegate {
    func chatAttachmentSheetViewControllerDidDismiss(_ sheet: ChatAttachmentPickerViewController) {
        finishDismissal(notifyDelegate: true)
    }

    func chatAttachmentSheetViewControllerDidSend(_ sheet: ChatAttachmentPickerViewController) {
        finishSend()
    }

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didRequestSend drafts: [AttachmentDraft],
        captionState: ChatAttachmentCaptionState
    ) {
        sendCoordinator.send(
            drafts: drafts,
            captionState: captionState,
            context: context
        ) { [weak self] result in
            let complete = {
                guard let self else {
                    return
                }

                switch result {
                case .sent:
                    self.finishSend()
                case .premiumRequired(let owner):
                    self.delegate?.chatAttachmentFlowCoordinator(self, didRequestPremiumFor: owner)
                case .cloudStorageQuotaExceeded(let owner):
                    self.presentCloudStorageQuotaExceededAlert(owner: owner)
                case .blocked(let reason):
                    if let picker = self.pickerViewController {
                        picker.applySendBlockedReason(reason)
                    } else {
                        self.delegate?.chatAttachmentFlowCoordinator(self, didFailWith: .sendBlocked(reason))
                    }
                }
            }

            if Thread.isMainThread {
                complete()
            } else {
                DispatchQueue.main.async(execute: complete)
            }
        }
    }

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didRequestPremiumFor owner: String
    ) {
        delegate?.chatAttachmentFlowCoordinator(self, didRequestPremiumFor: owner)
    }

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didFailWith error: ChatAttachmentFlowError
    ) {
        finishDismissal(notifyDelegate: false)
        delegate?.chatAttachmentFlowCoordinator(self, didFailWith: error)
    }

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didUpdateSelectionCount count: Int
    ) {
        selectedItemCount = count
    }
}

final class DefaultChatAttachmentSourceControllerFactory: ChatAttachmentSourceControllerFactory {
    func makeController(
        for source: ChatAttachmentSource,
        context: ChatAttachmentFlowContext
    ) -> ChatAttachmentSourceControlling {
        switch source {
        case .gallery:
            return ChatAttachmentGallerySourceViewController()
        case .file:
            return ChatAttachmentFileSourceViewController(
                fileDraftBuilder: ChatAttachmentFileDraftBuilder(
                    maximumFileSize: ChatAttachmentFileUploadLimitProvider.maxUploadFileSize(owner: context.owner)
                )
            )
        case .geolocation:
            return ChatAttachmentGeolocationSourceViewController()
        case .contact:
            return ChatAttachmentPlaceholderSourceViewController(source: .contact)
        }
    }
}

final class ChatAttachmentPlaceholderSourceViewController: UIViewController, ChatAttachmentSourceControlling {
    let source: ChatAttachmentSource
    var onSelectionCountChanged: ((Int) -> Void)?

    var viewController: UIViewController {
        self
    }

    init(source: ChatAttachmentSource) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .clear
        view = rootView
    }
}
