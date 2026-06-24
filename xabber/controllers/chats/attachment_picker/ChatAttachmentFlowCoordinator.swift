import UIKit

struct ChatAttachmentFlowContext {
    let owner: String
    let jid: String
    let conversationType: ClientSynchronizationManager.ConversationType
    let forwardedMessageIds: [String]
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

final class ChatAttachmentFlowCoordinator: ChatAttachmentFlowCoordinating {
    typealias PresentationHandler = (
        UIViewController,
        UIViewController,
        Bool,
        (() -> Void)?
    ) -> Void

    weak var delegate: ChatAttachmentFlowCoordinatorDelegate?

    private weak var presentingViewController: UIViewController?
    private let context: ChatAttachmentFlowContext
    private let sourceControllerFactory: ChatAttachmentSourceControllerFactory
    private weak var sheetAnchorProvider: ChatAttachmentSheetAnchorProviding?
    private let presentationHandler: PresentationHandler
    private let sendCoordinator: ChatAttachmentSendCoordinating
    private let mediaPreparationCoordinator: ChatAttachmentMediaPreparing

    private(set) var sheetViewController: ChatAttachmentSheetViewController?
    private(set) var sheetTransitioningDelegate: ChatAttachmentSheetTransitioningDelegate?
    private(set) var selectedItemCount: Int = 0

    init(
        presentingViewController: UIViewController,
        context: ChatAttachmentFlowContext,
        sourceControllerFactory: ChatAttachmentSourceControllerFactory = DefaultChatAttachmentSourceControllerFactory(),
        sheetAnchorProvider: ChatAttachmentSheetAnchorProviding? = nil,
        sendCoordinator: ChatAttachmentSendCoordinating = ChatAttachmentSendPipeline(),
        mediaPreparationCoordinator: ChatAttachmentMediaPreparing = ChatAttachmentMediaPreparationCoordinator(),
        presentationHandler: @escaping PresentationHandler = { presenter, sheet, animated, completion in
            presenter.present(sheet, animated: animated, completion: completion)
        }
    ) {
        self.presentingViewController = presentingViewController
        self.context = context
        self.sourceControllerFactory = sourceControllerFactory
        self.sheetAnchorProvider = sheetAnchorProvider
        self.sendCoordinator = sendCoordinator
        self.mediaPreparationCoordinator = mediaPreparationCoordinator
        self.presentationHandler = presentationHandler
    }

    func start() {
        guard let presenter = presentingViewController else {
            delegate?.chatAttachmentFlowCoordinator(self, didFailWith: .missingPresenter)
            return
        }

        guard sheetViewController == nil else {
            return
        }

        guard presenter.presentedViewController == nil else {
            delegate?.chatAttachmentFlowCoordinator(self, didFailWith: .presentationFailed)
            return
        }

        let sheet = ChatAttachmentSheetViewController(
            context: context,
            sourceControllerFactory: sourceControllerFactory,
            mediaPreparationCoordinator: mediaPreparationCoordinator
        )
        sheet.delegate = self
        let transitioningDelegate = ChatAttachmentSheetTransitioningDelegate(
            anchorProvider: sheetAnchorProvider ?? presenter as? ChatAttachmentSheetAnchorProviding
        )
        sheet.modalPresentationStyle = .custom
        sheet.transitioningDelegate = transitioningDelegate
        sheetTransitioningDelegate = transitioningDelegate
        sheet.loadViewIfNeeded()
        sheetViewController = sheet
        selectedItemCount = sheet.selectedItemCount

        presentationHandler(presenter, sheet, true, nil)
    }

    func switchSource(to source: ChatAttachmentSource) {
        sheetViewController?.switchSource(to: source)
    }

    func dismiss(animated: Bool) {
        guard let sheet = sheetViewController else {
            return
        }

        let completeDismissal: () -> Void = { [weak self] in
            guard let self else {
                return
            }

            self.finishDismissal(notifyDelegate: true)
        }

        if sheet.presentingViewController != nil {
            sheet.dismiss(animated: animated, completion: completeDismissal)
        } else {
            completeDismissal()
        }
    }

    private func finishDismissal(notifyDelegate: Bool) {
        guard let sheet = sheetViewController else {
            return
        }

        sheet.delegate = nil
        sheet.releaseSourceControllers()
        sheetViewController = nil
        sheetTransitioningDelegate = nil
        selectedItemCount = 0

        if notifyDelegate {
            delegate?.chatAttachmentFlowCoordinatorDidDismiss(self)
        }
    }

    private func finishSend() {
        guard sheetViewController != nil else {
            delegate?.chatAttachmentFlowCoordinatorDidSend(self)
            return
        }

        finishDismissal(notifyDelegate: false)
        delegate?.chatAttachmentFlowCoordinatorDidSend(self)
    }
}

extension ChatAttachmentFlowCoordinator: ChatAttachmentSheetViewControllerDelegate {
    func chatAttachmentSheetViewControllerDidDismiss(_ sheet: ChatAttachmentSheetViewController) {
        finishDismissal(notifyDelegate: true)
    }

    func chatAttachmentSheetViewControllerDidSend(_ sheet: ChatAttachmentSheetViewController) {
        finishSend()
    }

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentSheetViewController,
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
                case .blocked(let reason):
                    if let sheet = self.sheetViewController {
                        sheet.applySendBlockedReason(reason)
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
        _ sheet: ChatAttachmentSheetViewController,
        didRequestPremiumFor owner: String
    ) {
        delegate?.chatAttachmentFlowCoordinator(self, didRequestPremiumFor: owner)
    }

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentSheetViewController,
        didFailWith error: ChatAttachmentFlowError
    ) {
        finishDismissal(notifyDelegate: false)
        delegate?.chatAttachmentFlowCoordinator(self, didFailWith: error)
    }

    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentSheetViewController,
        didUpdateSelectionCount count: Int
    ) {
        selectedItemCount = count
    }
}

protocol ChatAttachmentSheetViewControllerDelegate: AnyObject {
    func chatAttachmentSheetViewControllerDidDismiss(_ sheet: ChatAttachmentSheetViewController)
    func chatAttachmentSheetViewControllerDidSend(_ sheet: ChatAttachmentSheetViewController)
    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentSheetViewController,
        didRequestSend drafts: [AttachmentDraft],
        captionState: ChatAttachmentCaptionState
    )
    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentSheetViewController,
        didRequestPremiumFor owner: String
    )
    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentSheetViewController,
        didFailWith error: ChatAttachmentFlowError
    )
    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentSheetViewController,
        didUpdateSelectionCount count: Int
    )
}

extension ChatAttachmentSheetViewControllerDelegate {
    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentSheetViewController,
        didRequestSend drafts: [AttachmentDraft],
        captionState: ChatAttachmentCaptionState
    ) {
        chatAttachmentSheetViewControllerDidSend(sheet)
    }
}

final class ChatAttachmentSelectionComposerBarView: UIView {
    let captionInputView = ChatAttachmentCaptionInputView()
    let sendButton = UIButton(type: .system)
    private let sendButtonImage = imageLiteral("xabber.paperplane.fill", dimension: NativeGlassBarStyle.iconSize)
        ?? UIImage(systemName: "paperplane.fill")
    private let separatorView = UIView()
    private let selectedCountLabel = UILabel()

    var onCaptionChanged: ((String) -> Void)?
    private(set) var selectedCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    func update(
        selectedCount: Int,
        isSendEnabled: Bool
    ) {
        self.selectedCount = selectedCount
        selectedCountLabel.text = selectedCount > 0 ? "\(selectedCount)" : nil
        selectedCountLabel.isHidden = selectedCount == 0
        sendButton.isEnabled = isSendEnabled
        sendButton.tintColor = isSendEnabled ? .systemBlue : .secondaryLabel
        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: sendButton,
            tintColor: sendButton.tintColor,
            image: sendButtonImage,
            forceConfigurationUpdate: true
        )
        sendButton.layer.cornerRadius = NativeGlassBarStyle.buttonSize / 2
        sendButton.layer.cornerCurve = .continuous
        sendButton.accessibilityValue = isSendEnabled ? nil : ChatAttachmentLocalization.string(.accessibilityUnavailable)
    }

    func updateCaptionText(_ text: String) {
        guard captionInputView.text != text else {
            return
        }

        captionInputView.apply(ChatAttachmentCaptionState(rawText: text))
    }

    private func setupView() {
        backgroundColor = .systemBackground
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "chatAttachmentSheet.selectionComposerBar"

        separatorView.backgroundColor = .separator
        separatorView.translatesAutoresizingMaskIntoConstraints = false

        captionInputView.translatesAutoresizingMaskIntoConstraints = false
        captionInputView.accessibilityIdentifier = "chatAttachmentSheet.selectionComposerBar.caption"
        captionInputView.onTextChanged = { [weak self] text in
            self?.onCaptionChanged?(text)
        }

        selectedCountLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        selectedCountLabel.textColor = .white
        selectedCountLabel.backgroundColor = .systemBlue
        selectedCountLabel.textAlignment = .center
        selectedCountLabel.layer.cornerRadius = 11
        selectedCountLabel.layer.masksToBounds = true
        selectedCountLabel.translatesAutoresizingMaskIntoConstraints = false
        selectedCountLabel.accessibilityIdentifier = "chatAttachmentSheet.selectionComposerBar.count"

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setTitle(nil, for: .normal)
        sendButton.setImage(sendButtonImage, for: .normal)
        sendButton.tintColor = .secondaryLabel
        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: sendButton,
            tintColor: sendButton.tintColor,
            image: sendButtonImage
        )
        sendButton.layer.cornerRadius = NativeGlassBarStyle.buttonSize / 2
        sendButton.layer.cornerCurve = .continuous
        sendButton.accessibilityIdentifier = "chatAttachmentSheet.selectionComposerBar.sendButton"
        sendButton.accessibilityLabel = ChatAttachmentLocalization.string(.actionSend)

        addSubview(separatorView)
        addSubview(captionInputView)
        addSubview(selectedCountLabel)
        addSubview(sendButton)

        NSLayoutConstraint.activate([
            separatorView.topAnchor.constraint(equalTo: topAnchor),
            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            captionInputView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            captionInputView.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: 6),
            captionInputView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            captionInputView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),

            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: captionInputView.centerYAnchor),
            sendButton.heightAnchor.constraint(equalToConstant: NativeGlassBarStyle.buttonSize),
            sendButton.widthAnchor.constraint(equalToConstant: NativeGlassBarStyle.buttonSize),

            selectedCountLabel.trailingAnchor.constraint(equalTo: sendButton.trailingAnchor, constant: 4),
            selectedCountLabel.topAnchor.constraint(equalTo: sendButton.topAnchor, constant: -6),
            selectedCountLabel.widthAnchor.constraint(equalToConstant: 22),
            selectedCountLabel.heightAnchor.constraint(equalToConstant: 22)
        ])

        update(selectedCount: 0, isSendEnabled: false)
    }
}

final class ChatAttachmentSheetViewController: UIViewController {
    typealias PreviewPresentationHandler = (
        UIViewController,
        UIViewController,
        Bool,
        (() -> Void)?
    ) -> Void
    typealias PreviewDismissalHandler = (
        UIViewController,
        Bool,
        (() -> Void)?
    ) -> Void

    weak var delegate: ChatAttachmentSheetViewControllerDelegate?

    let grabberView = UIView()
    let sourceContainerView = UIView()
    let statusBannerView = ChatAttachmentStatusBannerView()
    let selectionPreviewBarView = ChatAttachmentSelectionPreviewBarView()
    let sourceBarView = ChatAttachmentSourceBarView()
    let selectionComposerBarView = ChatAttachmentSelectionComposerBarView()
    let bottomControlsContainerView = UIView()

    private let context: ChatAttachmentFlowContext
    private let sourceControllerFactory: ChatAttachmentSourceControllerFactory
    private let mediaPreparationCoordinator: ChatAttachmentMediaPreparing
    private let sourceBarConfiguration: ChatAttachmentSourceBarConfiguration
    private let previewPresentationHandler: PreviewPresentationHandler
    private let previewDismissalHandler: PreviewDismissalHandler
    private var sourceControllers: [ChatAttachmentSource: ChatAttachmentSourceControlling] = [:]
    private weak var visibleSourceViewController: UIViewController?
    private var statusBannerHeightConstraint: NSLayoutConstraint?
    private var selectionPreviewBarHeightConstraint: NSLayoutConstraint?
    private var bottomControlsHeightConstraint: NSLayoutConstraint?
    private(set) var bottomControlsBottomConstraint: NSLayoutConstraint?
    private var currentPreparationTask: ChatAttachmentMediaPreparationCancellable?
    private var isReleasingSources = false
    private var sendFeedbackViewModel: ChatAttachmentStatusBannerViewModel?
    private var shouldShowPreparationStatus = false
    private var isPreparingSend = false

    private(set) var activeSource: ChatAttachmentSource = .gallery
    private(set) var selectedItemCount: Int = 0
    private(set) var selectedAttachmentDrafts: [AttachmentDraft] = []
    private(set) var previewViewController: ChatAttachmentPreviewViewController?
    private(set) var presentationState: ChatAttachmentSheetPresentationState = .expanded
    private(set) var captionState = ChatAttachmentCaptionState()

    init(
        context: ChatAttachmentFlowContext,
        sourceControllerFactory: ChatAttachmentSourceControllerFactory,
        mediaPreparationCoordinator: ChatAttachmentMediaPreparing = ChatAttachmentMediaPreparationCoordinator(),
        sourceBarConfiguration: ChatAttachmentSourceBarConfiguration = .default,
        previewPresentationHandler: @escaping PreviewPresentationHandler = { presenter, preview, animated, completion in
            presenter.present(preview, animated: animated, completion: completion)
        },
        previewDismissalHandler: @escaping PreviewDismissalHandler = { preview, animated, completion in
            preview.dismiss(animated: animated, completion: completion)
        }
    ) {
        self.context = context
        self.sourceControllerFactory = sourceControllerFactory
        self.mediaPreparationCoordinator = mediaPreparationCoordinator
        self.sourceBarConfiguration = sourceBarConfiguration
        self.previewPresentationHandler = previewPresentationHandler
        self.previewDismissalHandler = previewDismissalHandler
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .systemBackground
        rootView.layer.cornerRadius = 18
        rootView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        rootView.layer.masksToBounds = true

        grabberView.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.36)
        grabberView.layer.cornerRadius = 2.5
        grabberView.translatesAutoresizingMaskIntoConstraints = false
        grabberView.accessibilityIdentifier = "chatAttachmentSheet.grabber"

        sourceContainerView.backgroundColor = .clear
        sourceContainerView.translatesAutoresizingMaskIntoConstraints = false
        sourceContainerView.accessibilityIdentifier = "chatAttachmentSheet.sourceContainer"

        statusBannerView.accessibilityIdentifier = "chatAttachmentSheet.statusBanner"

        sourceBarView.accessibilityIdentifier = "chatAttachmentSheet.sourceBar"
        bottomControlsContainerView.translatesAutoresizingMaskIntoConstraints = false
        bottomControlsContainerView.accessibilityIdentifier = "chatAttachmentSheet.bottomControls"
        selectionPreviewBarView.isHidden = true
        selectionPreviewBarView.previewButton.addTarget(
            self,
            action: #selector(selectionPreviewButtonTapped),
            for: .touchUpInside
        )
        selectionComposerBarView.isHidden = true
        selectionComposerBarView.onCaptionChanged = { [weak self] text in
            self?.captionState = ChatAttachmentCaptionState(rawText: text)
        }
        selectionComposerBarView.sendButton.addTarget(
            self,
            action: #selector(selectionComposerSendButtonTapped),
            for: .touchUpInside
        )
        statusBannerView.onRetryTapped = { [weak self] in
            self?.retryUnavailableDraftsAndSend()
        }
        statusBannerView.onRemoveTapped = { [weak self] in
            self?.removeUnavailableDrafts()
        }

        rootView.addSubview(grabberView)
        rootView.addSubview(sourceContainerView)
        rootView.addSubview(statusBannerView)
        rootView.addSubview(selectionPreviewBarView)
        rootView.addSubview(bottomControlsContainerView)
        bottomControlsContainerView.addSubview(sourceBarView)
        bottomControlsContainerView.addSubview(selectionComposerBarView)
        let statusBannerHeightConstraint = statusBannerView.heightAnchor.constraint(equalToConstant: 0)
        self.statusBannerHeightConstraint = statusBannerHeightConstraint
        let previewBarHeightConstraint = selectionPreviewBarView.heightAnchor.constraint(equalToConstant: 0)
        selectionPreviewBarHeightConstraint = previewBarHeightConstraint
        let bottomControlsHeightConstraint = bottomControlsContainerView.heightAnchor.constraint(equalToConstant: 72)
        self.bottomControlsHeightConstraint = bottomControlsHeightConstraint
        let bottomControlsBottomConstraint = bottomControlsContainerView.bottomAnchor.constraint(
            equalTo: rootView.keyboardLayoutGuide.topAnchor
        )
        self.bottomControlsBottomConstraint = bottomControlsBottomConstraint

        NSLayoutConstraint.activate([
            grabberView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 8),
            grabberView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            grabberView.widthAnchor.constraint(equalToConstant: 36),
            grabberView.heightAnchor.constraint(equalToConstant: 5),

            sourceContainerView.topAnchor.constraint(equalTo: grabberView.bottomAnchor, constant: 8),
            sourceContainerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sourceContainerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            sourceContainerView.bottomAnchor.constraint(equalTo: statusBannerView.topAnchor),

            statusBannerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 12),
            statusBannerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),
            statusBannerView.bottomAnchor.constraint(equalTo: bottomControlsContainerView.topAnchor, constant: -6),
            statusBannerHeightConstraint,

            selectionPreviewBarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            selectionPreviewBarView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            selectionPreviewBarView.bottomAnchor.constraint(equalTo: bottomControlsContainerView.topAnchor),
            previewBarHeightConstraint,

            bottomControlsContainerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            bottomControlsContainerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            bottomControlsBottomConstraint,
            bottomControlsHeightConstraint,

            sourceBarView.leadingAnchor.constraint(equalTo: bottomControlsContainerView.leadingAnchor),
            sourceBarView.trailingAnchor.constraint(equalTo: bottomControlsContainerView.trailingAnchor),
            sourceBarView.topAnchor.constraint(equalTo: bottomControlsContainerView.topAnchor),
            sourceBarView.bottomAnchor.constraint(equalTo: bottomControlsContainerView.bottomAnchor),

            selectionComposerBarView.leadingAnchor.constraint(equalTo: bottomControlsContainerView.leadingAnchor),
            selectionComposerBarView.trailingAnchor.constraint(equalTo: bottomControlsContainerView.trailingAnchor),
            selectionComposerBarView.topAnchor.constraint(equalTo: bottomControlsContainerView.topAnchor),
            selectionComposerBarView.bottomAnchor.constraint(equalTo: bottomControlsContainerView.bottomAnchor)
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sourceBarView.delegate = self
        sourceBarView.configure(
            configuration: sourceBarConfiguration,
            selectedSource: initialSource
        )
        switchSource(to: initialSource)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            delegate?.chatAttachmentSheetViewControllerDidDismiss(self)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        view.endEditing(true)
        super.viewWillDisappear(animated)
    }

    func switchSource(to source: ChatAttachmentSource) {
        guard sourceBarConfiguration.isSelectable(source) else {
            return
        }

        activeSource = source
        sourceBarView.setSelectedSource(source)
        let controller = sourceController(for: source)
        display(controller.viewController)
        forwardPresentationState(to: controller)
    }

    func releaseSourceControllers() {
        guard !isReleasingSources else {
            return
        }

        isReleasingSources = true
        defer {
            isReleasingSources = false
        }

        sourceControllers.values.forEach { sourceController in
            sourceController.onSelectionCountChanged = nil
            if let selectionProvider = sourceController as? ChatAttachmentDraftSelectionProviding {
                selectionProvider.onSelectedAttachmentDraftsChanged = nil
            }
            if let presentationRequesting = sourceController as? ChatAttachmentSheetPresentationRequesting {
                presentationRequesting.onSheetPresentationStateRequested = nil
                presentationRequesting.onDismissRequested = nil
            }
            removeChildIfNeeded(sourceController.viewController)
        }
        sourceControllers.removeAll()
        visibleSourceViewController = nil
        selectedItemCount = 0
        selectedAttachmentDrafts = []
        captionState.reset()
        sendFeedbackViewModel = nil
        shouldShowPreparationStatus = false
        currentPreparationTask?.cancel()
        currentPreparationTask = nil
        isPreparingSend = false
        previewViewController?.delegate = nil
        previewViewController = nil
        updateSelectionPreviewBar()
        updateBottomControls()
        updateStatusBanner()
    }

    private func sourceController(for source: ChatAttachmentSource) -> ChatAttachmentSourceControlling {
        if let controller = sourceControllers[source] {
            return controller
        }

        let controller = sourceControllerFactory.makeController(for: source, context: context)
        controller.onSelectionCountChanged = { [weak self] count in
            self?.updateSelectionCount(count)
        }
        if let selectionProvider = controller as? ChatAttachmentDraftSelectionProviding {
            selectionProvider.onSelectedAttachmentDraftsChanged = { [weak self] drafts in
                self?.updateSelectedAttachmentDrafts(drafts)
            }
            if let selectionSyncing = controller as? ChatAttachmentDraftSelectionSyncing,
               !selectedAttachmentDrafts.isEmpty {
                selectionSyncing.syncSelectedAttachmentDrafts(selectedAttachmentDrafts)
            } else {
                updateSelectedAttachmentDrafts(selectionProvider.selectedAttachmentDrafts)
            }
        }
        if let presentationRequesting = controller as? ChatAttachmentSheetPresentationRequesting {
            presentationRequesting.onSheetPresentationStateRequested = { [weak self] state in
                self?.setPresentationState(state, animated: true)
            }
            presentationRequesting.onDismissRequested = { [weak self] in
                self?.dismiss(animated: true)
            }
        }
        sourceControllers[source] = controller
        return controller
    }

    func setPresentationState(_ state: ChatAttachmentSheetPresentationState, animated: Bool) {
        if let presentationController = presentationController as? ChatAttachmentSheetPresentationController {
            presentationController.setState(state, animated: animated)
        } else {
            chatAttachmentSheetPresentationStateDidChange(.expanded)
        }
    }

    private func display(_ sourceViewController: UIViewController) {
        guard visibleSourceViewController !== sourceViewController else {
            return
        }

        if let visibleSourceViewController {
            removeChildIfNeeded(visibleSourceViewController)
        }

        addChild(sourceViewController)
        sourceContainerView.addSubview(sourceViewController.view)
        sourceViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sourceViewController.view.leadingAnchor.constraint(equalTo: sourceContainerView.leadingAnchor),
            sourceViewController.view.trailingAnchor.constraint(equalTo: sourceContainerView.trailingAnchor),
            sourceViewController.view.topAnchor.constraint(equalTo: sourceContainerView.topAnchor),
            sourceViewController.view.bottomAnchor.constraint(equalTo: sourceContainerView.bottomAnchor)
        ])
        sourceViewController.didMove(toParent: self)
        visibleSourceViewController = sourceViewController
    }

    private func forwardPresentationState(to sourceController: ChatAttachmentSourceControlling) {
        (sourceController as? ChatAttachmentSheetPresentationStateObserving)?
            .chatAttachmentSheetPresentationStateDidChange(presentationState)
    }

    private func removeChildIfNeeded(_ sourceViewController: UIViewController) {
        guard sourceViewController.parent === self else {
            return
        }

        sourceViewController.willMove(toParent: nil)
        sourceViewController.view.removeFromSuperview()
        sourceViewController.removeFromParent()
    }

    private func updateSelectionCount(_ count: Int) {
        selectedItemCount = count
        updateSelectionPreviewBar()
        updateBottomControls()
        updateStatusBanner()
        delegate?.chatAttachmentSheetViewController(self, didUpdateSelectionCount: count)
    }

    private func updateSelectedAttachmentDrafts(_ drafts: [AttachmentDraft]) {
        if selectedAttachmentDrafts != drafts {
            sendFeedbackViewModel = nil
            shouldShowPreparationStatus = drafts.contains { draft in
                if case .unavailable = draft.preparationState {
                    return true
                }
                return false
            }
        }
        selectedAttachmentDrafts = drafts
        synchronizeSourceSelections(with: drafts)
        updateSelectionCount(drafts.count)

        if drafts.isEmpty {
            captionState.reset()
            selectionComposerBarView.updateCaptionText("")
            currentPreparationTask?.cancel()
            currentPreparationTask = nil
            isPreparingSend = false
        } else {
            selectionComposerBarView.updateCaptionText(captionState.rawText)
        }

        guard let previewViewController else {
            return
        }

        if drafts.isEmpty {
            dismissPreview(previewViewController, animated: true)
        } else {
            previewViewController.updateDrafts(drafts)
            previewViewController.updateCaptionState(captionState)
        }
    }

    func applySendBlockedReason(_ reason: ChatAttachmentSendBlockReason) {
        sendFeedbackViewModel = ChatAttachmentSendFeedbackPolicy.viewModel(for: reason)
        updateStatusBanner()
        previewViewController?.applySendFeedback(sendFeedbackViewModel ?? .hidden)
    }

    private func synchronizeSourceSelections(with drafts: [AttachmentDraft]) {
        sourceControllers.values.forEach { sourceController in
            (sourceController as? ChatAttachmentDraftSelectionSyncing)?
                .syncSelectedAttachmentDrafts(drafts)
        }
    }

    private func updateSelectionPreviewBar() {
        selectionPreviewBarView.update(selectedCount: selectedItemCount)
        selectionPreviewBarView.isHidden = true
        selectionPreviewBarHeightConstraint?.constant = 0
    }

    private func updateBottomControls() {
        let hasSelection = selectedItemCount > 0
        sourceBarView.isHidden = hasSelection
        selectionComposerBarView.isHidden = !hasSelection
        bottomControlsHeightConstraint?.constant = hasSelection ? 64 : 72
        selectionComposerBarView.update(
            selectedCount: selectedItemCount,
            isSendEnabled: ChatAttachmentInlineSendabilityPolicy.canRequestSend(drafts: selectedAttachmentDrafts)
                && !isPreparingSend
        )
    }

    @objc
    private func selectionPreviewButtonTapped() {
        guard previewViewController == nil,
              !selectedAttachmentDrafts.isEmpty else {
            return
        }

        let preview = ChatAttachmentPreviewViewController(
            drafts: selectedAttachmentDrafts,
            captionState: captionState,
            onCaptionChanged: { [weak self] captionState in
                self?.captionState = captionState
            }
        )
        preview.delegate = self
        preview.loadViewIfNeeded()
        previewViewController = preview
        previewPresentationHandler(self, preview, true, nil)
    }

    private func removeSelectedAttachmentDraft(withID draftID: String) {
        for sourceController in sourceControllers.values {
            guard let selectionMutator = sourceController as? ChatAttachmentDraftSelectionMutating else {
                continue
            }

            let sourceDrafts = (sourceController as? ChatAttachmentDraftSelectionProviding)?
                .selectedAttachmentDrafts ?? selectedAttachmentDrafts
            guard sourceDrafts.contains(where: { $0.id == draftID }) else {
                continue
            }

            let updatedDrafts = selectionMutator.removeSelectedAttachmentDraft(withID: draftID)
            if updatedDrafts != selectedAttachmentDrafts {
                updateSelectedAttachmentDrafts(updatedDrafts)
            }
            return
        }
    }

    private func replaceSelectedAttachmentDraft(withID draftID: String, updatedDraft: AttachmentDraft) {
        for sourceController in sourceControllers.values {
            guard let selectionMutator = sourceController as? ChatAttachmentDraftSelectionMutating else {
                continue
            }

            let sourceDrafts = (sourceController as? ChatAttachmentDraftSelectionProviding)?
                .selectedAttachmentDrafts ?? selectedAttachmentDrafts
            guard sourceDrafts.contains(where: { $0.id == draftID }) else {
                continue
            }

            let updatedDrafts = selectionMutator.replaceSelectedAttachmentDraft(
                withID: draftID,
                updatedDraft: updatedDraft
            )
            if updatedDrafts != selectedAttachmentDrafts {
                updateSelectedAttachmentDrafts(updatedDrafts)
            }
            return
        }
    }

    private func retrySelectedAttachmentDraft(withID draftID: String) {
        guard let draft = selectedAttachmentDrafts.first(where: { $0.id == draftID }) else {
            return
        }

        replaceSelectedAttachmentDraft(
            withID: draftID,
            updatedDraft: ChatAttachmentDraftRetryPolicy.retryDraft(draft)
        )
    }

    private func updateStatusBanner() {
        let viewModel = sendFeedbackViewModel
            ?? preparationStatusViewModel()
        let shouldShow = viewModel.kind != .hidden && viewModel.kind != .ready
        statusBannerView.apply(shouldShow ? viewModel : .hidden)
        statusBannerHeightConstraint?.constant = statusBannerView.isHidden ? 0 : 74
    }

    private func preparationStatusViewModel() -> ChatAttachmentStatusBannerViewModel {
        let viewModel = ChatAttachmentBatchStatusPolicy.viewModel(for: selectedAttachmentDrafts)
        if viewModel.kind == .blocked {
            return viewModel
        }

        guard shouldShowPreparationStatus else {
            return .hidden
        }

        return viewModel
    }

    @objc
    private func selectionComposerSendButtonTapped() {
        sendSelectedDraftsFromSheet()
    }

    private func sendSelectedDraftsFromSheet() {
        guard ChatAttachmentInlineSendabilityPolicy.canRequestSend(drafts: selectedAttachmentDrafts),
              !isPreparingSend else {
            return
        }

        shouldShowPreparationStatus = true
        sendFeedbackViewModel = nil
        isPreparingSend = true
        let originalDrafts = selectedAttachmentDrafts
        if ChatAttachmentSendabilityPolicy.canRequestSend(drafts: originalDrafts) {
            isPreparingSend = false
            delegate?.chatAttachmentSheetViewController(
                self,
                didRequestSend: originalDrafts,
                captionState: captionState
            )
            updateBottomControls()
            updateStatusBanner()
            return
        }

        let preparingDrafts = originalDrafts.map { draft -> AttachmentDraft in
            guard case .pending = draft.preparationState else {
                return draft
            }

            var preparingDraft = draft
            preparingDraft.preparationState = .preparing
            return preparingDraft
        }
        applyPreparedOrPreparingDrafts(preparingDrafts)

        currentPreparationTask?.cancel()
        currentPreparationTask = mediaPreparationCoordinator.prepare(drafts: originalDrafts) { [weak self] preparedDrafts in
            guard let self else {
                return
            }

            self.currentPreparationTask = nil
            self.isPreparingSend = false
            self.applyPreparedOrPreparingDrafts(preparedDrafts)

            guard ChatAttachmentSendabilityPolicy.canRequestSend(drafts: preparedDrafts) else {
                self.updateBottomControls()
                self.updateStatusBanner()
                return
            }

            self.delegate?.chatAttachmentSheetViewController(
                self,
                didRequestSend: preparedDrafts,
                captionState: self.captionState
            )
            self.updateBottomControls()
            self.updateStatusBanner()
        }
        updateBottomControls()
        updateStatusBanner()
    }

    private func applyPreparedOrPreparingDrafts(_ drafts: [AttachmentDraft]) {
        selectedAttachmentDrafts = drafts
        synchronizeSourceSelections(with: drafts)
        previewViewController?.updateDrafts(drafts)
        updateSelectionCount(drafts.count)
    }

    private func retryUnavailableDraftsAndSend() {
        guard selectedAttachmentDrafts.contains(where: { draft in
            if case .unavailable = draft.preparationState {
                return true
            }
            return false
        }) else {
            return
        }

        let retriedDrafts = selectedAttachmentDrafts.map(ChatAttachmentDraftRetryPolicy.retryDraft)
        shouldShowPreparationStatus = false
        applyPreparedOrPreparingDrafts(retriedDrafts)
        sendSelectedDraftsFromSheet()
    }

    private func removeUnavailableDrafts() {
        let unavailableDraftIDs = selectedAttachmentDrafts.compactMap { draft -> String? in
            if case .unavailable = draft.preparationState {
                return draft.id
            }
            return nil
        }
        unavailableDraftIDs.forEach { removeSelectedAttachmentDraft(withID: $0) }
    }

    private func dismissPreview(
        _ preview: ChatAttachmentPreviewViewController,
        animated: Bool
    ) {
        preview.delegate = nil
        previewDismissalHandler(preview, animated) { [weak self, weak preview] in
            guard let self,
                  self.previewViewController === preview else {
                return
            }

            self.previewViewController = nil
        }
    }

    private var initialSource: ChatAttachmentSource {
        if sourceBarConfiguration.isSelectable(.gallery) {
            return .gallery
        }

        return sourceBarConfiguration.visibleSources.first {
            sourceBarConfiguration.isSelectable($0)
        } ?? .gallery
    }
}

extension ChatAttachmentSheetViewController: ChatAttachmentPreviewViewControllerDelegate {
    func chatAttachmentPreviewViewControllerDidClose(_ preview: ChatAttachmentPreviewViewController) {
        if previewViewController === preview {
            previewViewController = nil
        }
    }

    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didRemoveDraftWithID draftID: String
    ) {
        removeSelectedAttachmentDraft(withID: draftID)
    }

    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didRetryDraftWithID draftID: String
    ) {
        retrySelectedAttachmentDraft(withID: draftID)
    }

    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didReplaceDraftWithID draftID: String,
        updatedDraft: AttachmentDraft
    ) {
        replaceSelectedAttachmentDraft(withID: draftID, updatedDraft: updatedDraft)
    }

    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didRequestSend drafts: [AttachmentDraft]
    ) {
        delegate?.chatAttachmentSheetViewController(
            self,
            didRequestSend: drafts,
            captionState: captionState
        )
    }
}

extension ChatAttachmentSheetViewController: ChatAttachmentSheetPresentationStateObserving {
    func chatAttachmentSheetPresentationStateDidChange(_ state: ChatAttachmentSheetPresentationState) {
        presentationState = state
        guard let sourceController = sourceControllers[activeSource] else {
            return
        }

        forwardPresentationState(to: sourceController)
    }
}

extension ChatAttachmentSheetViewController: ChatAttachmentSourceBarViewDelegate {
    func chatAttachmentSourceBarView(
        _ view: ChatAttachmentSourceBarView,
        didSelect source: ChatAttachmentSource
    ) {
        switchSource(to: source)
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
