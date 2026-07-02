import UIKit

protocol ChatAttachmentPickerViewControllerDelegate: AnyObject {
    func chatAttachmentSheetViewControllerDidDismiss(_ sheet: ChatAttachmentPickerViewController)
    func chatAttachmentSheetViewControllerDidSend(_ sheet: ChatAttachmentPickerViewController)
    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didRequestSend drafts: [AttachmentDraft],
        captionState: ChatAttachmentCaptionState
    )
    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didRequestPremiumFor owner: String
    )
    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didFailWith error: ChatAttachmentFlowError
    )
    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didUpdateSelectionCount count: Int
    )
}

typealias ChatAttachmentSheetViewControllerDelegate = ChatAttachmentPickerViewControllerDelegate

extension ChatAttachmentPickerViewControllerDelegate {
    func chatAttachmentSheetViewController(
        _ sheet: ChatAttachmentPickerViewController,
        didRequestSend drafts: [AttachmentDraft],
        captionState: ChatAttachmentCaptionState
    ) {
        chatAttachmentSheetViewControllerDidSend(sheet)
    }
}

enum ChatAttachmentSheetGlassStyle {
    static let sheetCornerRadius: CGFloat = 18
    static let captionCornerRadius: CGFloat = NativeGlassBarStyle.cornerRadius

    static func makeEffect(
        interactive: Bool = false,
        prefersNativeGlass: Bool = true
    ) -> UIVisualEffect {
        XabberGlassStyle.makeEffect(
            role: .sheet,
            interactive: interactive,
            prefersNativeGlass: prefersNativeGlass
        )
    }

    static func makeEffectView(interactive: Bool = false) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: makeEffect(interactive: interactive))
        view.isUserInteractionEnabled = interactive
        view.contentView.isUserInteractionEnabled = interactive
        view.backgroundColor = .clear
        view.contentView.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    static func applySheetSurface(to view: UIVisualEffectView) {
        applySurface(
            to: view,
            cornerRadius: sheetCornerRadius,
            maskedCorners: [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        )
    }

    static func applyCaptionSurface(to view: UIVisualEffectView) {
        XabberGlassStyle.applySurface(
            to: view,
            role: .clearInputSurface,
            cornerStyle: .fixed(captionCornerRadius),
            interactive: view.isUserInteractionEnabled
        )
        view.contentView.backgroundColor = .clear
        view.layer.maskedCorners = [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMaxYCorner
        ]
    }

    private static func applySurface(
        to view: UIVisualEffectView,
        cornerRadius: CGFloat,
        maskedCorners: CACornerMask
    ) {
        XabberGlassStyle.applySurface(
            to: view,
            role: .sheet,
            cornerStyle: .fixed(cornerRadius),
            interactive: view.isUserInteractionEnabled,
            maskedCorners: maskedCorners
        )
    }
}

enum ChatAttachmentPickerComposerStyle {
    static let placeholderText = "Message".localizeString(id: "message", arguments: [])
    static let textVerticalInset: CGFloat = 4
    static let textHorizontalInset: CGFloat = NativeGlassBarStyle.contentInset
    static let maxTextViewHeight: CGFloat = 130
    static let buttonSize: CGFloat = NativeGlassBarStyle.buttonSize
    static let iconSize: CGFloat = NativeGlassBarStyle.iconSize
    static let sendButtonImage = imageLiteral("xabber.paperplane.fill", dimension: iconSize)
        ?? UIImage(systemName: "paperplane.fill")
    static let resetButtonImage = UIImage(systemName: "xmark")

    static func configureCaptionTextView(_ textView: InputTextView) {
        textView.backgroundColor = .clear
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.adjustsFontForContentSizeCategory = true
        textView.layer.cornerRadius = 0
        textView.layer.borderWidth = 0
        textView.layer.borderColor = UIColor.clear.cgColor
        textView.layer.masksToBounds = false
        textView.placeholder = placeholderText
        textView.placeholderTextColor = .secondaryLabel
        textView.isScrollEnabled = false
    }

    static func applyCaptionSurface(to view: UIVisualEffectView) {
        ChatAttachmentSheetGlassStyle.applyCaptionSurface(to: view)
    }

    static func applySendButtonStyle(
        to button: UIButton,
        isEnabled: Bool,
        tintColor: UIColor
    ) {
        let resolvedTintColor = isEnabled ? tintColor : .secondaryLabel
        button.isEnabled = isEnabled
        button.setTitle(nil, for: .normal)
        button.setTitle(nil, for: .highlighted)
        button.setTitle(nil, for: .disabled)
        button.tintColor = resolvedTintColor
        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: button,
            tintColor: resolvedTintColor,
            image: sendButtonImage,
            forceConfigurationUpdate: true
        )
        button.accessibilityLabel = ChatAttachmentLocalization.string(.actionSend)
        button.accessibilityValue = isEnabled
            ? nil
            : ChatAttachmentLocalization.string(.accessibilityUnavailable)
    }

    static func applyResetButtonStyle(
        to button: UIButton,
        tintColor: UIColor
    ) {
        button.setTitle(nil, for: .normal)
        button.setTitle(nil, for: .highlighted)
        button.setTitle(nil, for: .disabled)
        button.tintColor = tintColor
        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: button,
            tintColor: tintColor,
            image: resetButtonImage,
            forceConfigurationUpdate: true
        )
        button.accessibilityLabel = ChatAttachmentLocalization.string(.actionResetSelection)
        button.accessibilityValue = nil
    }
}

enum ChatAttachmentSelectionComposerBarMode {
    case caption
    case locationInfo(AttachmentPreparedLocation)
}

final class ChatAttachmentLocationInfoView: UIView {
    let backgroundEffectView = ChatAttachmentSheetGlassStyle.makeEffectView()
    let addressLabel = UILabel()
    let coordinatesLabel = UILabel()

    var onPreferredHeightChanged: ((CGFloat) -> Void)?
    private(set) var preferredHeight: CGFloat = NativeGlassBarStyle.minimumHeight

    private let minHeight: CGFloat = NativeGlassBarStyle.minimumHeight
    private let maxHeight: CGFloat = ChatAttachmentPickerComposerStyle.maxTextViewHeight
        + ChatAttachmentPickerComposerStyle.textVerticalInset * 2
    private let contentVerticalInset: CGFloat = 4
    private let stackSpacing: CGFloat = 1
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    func apply(location: AttachmentPreparedLocation) {
        let address = location.displayAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        addressLabel.text = address.isNotEmpty
            ? address
            : ChatAttachmentLocalization.string(.sourceLocationTitle)
        coordinatesLabel.text = Self.coordinateText(for: location)
        accessibilityLabel = [addressLabel.text, coordinatesLabel.text]
            .compactMap { $0 }
            .filter { $0.isNotEmpty }
            .joined(separator: ", ")
        setNeedsLayout()
        updateHeight()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateHeight()
    }

    private func setupView() {
        backgroundColor = .clear
        isOpaque = false
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "chatAttachmentSheet.selectionComposerBar.locationInfo"
        isAccessibilityElement = true

        ChatAttachmentPickerComposerStyle.applyCaptionSurface(to: backgroundEffectView)

        addressLabel.translatesAutoresizingMaskIntoConstraints = false
        addressLabel.accessibilityIdentifier = "chatAttachmentSheet.selectionComposerBar.locationAddress"
        addressLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        addressLabel.adjustsFontForContentSizeCategory = true
        addressLabel.textColor = .label
        addressLabel.numberOfLines = 0
        addressLabel.lineBreakMode = .byTruncatingTail
        addressLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        coordinatesLabel.translatesAutoresizingMaskIntoConstraints = false
        coordinatesLabel.accessibilityIdentifier = "chatAttachmentSheet.selectionComposerBar.locationCoordinates"
        coordinatesLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        coordinatesLabel.adjustsFontForContentSizeCategory = true
        coordinatesLabel.textColor = .secondaryLabel
        coordinatesLabel.numberOfLines = 1
        coordinatesLabel.lineBreakMode = .byTruncatingTail
        coordinatesLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let stackView = UIStackView(arrangedSubviews: [addressLabel, coordinatesLabel])
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = stackSpacing
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(backgroundEffectView)
        backgroundEffectView.contentView.addSubview(stackView)

        let heightConstraint = heightAnchor.constraint(equalToConstant: minHeight)
        self.heightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            heightConstraint,

            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(
                equalTo: backgroundEffectView.contentView.leadingAnchor,
                constant: NativeGlassBarStyle.contentInset
            ),
            stackView.trailingAnchor.constraint(
                equalTo: backgroundEffectView.contentView.trailingAnchor,
                constant: -NativeGlassBarStyle.contentInset
            ),
            stackView.centerYAnchor.constraint(equalTo: backgroundEffectView.contentView.centerYAnchor),
            stackView.topAnchor.constraint(
                greaterThanOrEqualTo: backgroundEffectView.contentView.topAnchor,
                constant: contentVerticalInset
            ),
            stackView.bottomAnchor.constraint(
                lessThanOrEqualTo: backgroundEffectView.contentView.bottomAnchor,
                constant: -contentVerticalInset
            )
        ])
    }

    private static func coordinateText(for location: AttachmentPreparedLocation) -> String {
        let trimmedURI = location.geoURI.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURI.hasPrefix("geo:") {
            let coordinates = String(trimmedURI.dropFirst("geo:".count))
            let components = coordinates.split(separator: ",", omittingEmptySubsequences: false)
            if components.count >= 2 {
                let latitude = displayCoordinateComponent(String(components[0]))
                let longitude = displayCoordinateComponent(String(components[1]))
                return "\(latitude):\(longitude)"
            }
        }

        return "\(displayCoordinateComponent(String(location.coordinate.latitude))):\(displayCoordinateComponent(String(location.coordinate.longitude)))"
    }

    private static func displayCoordinateComponent(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutParameters = trimmed
            .split(whereSeparator: { $0 == ";" || $0 == "?" })
            .first
            .map(String.init) ?? trimmed
        guard let separatorIndex = withoutParameters.firstIndex(of: ".") else {
            return withoutParameters
        }

        let fractionStartIndex = withoutParameters.index(after: separatorIndex)
        let fraction = withoutParameters[fractionStartIndex...].prefix(6)
        guard !fraction.isEmpty else {
            return String(withoutParameters[..<separatorIndex])
        }

        return "\(withoutParameters[...separatorIndex])\(fraction)"
    }

    private func updateHeight() {
        let fittingWidth = contentFittingWidth()
        guard fittingWidth > 0 else {
            return
        }

        addressLabel.numberOfLines = 0
        let fittingSize = CGSize(width: fittingWidth, height: .greatestFiniteMagnitude)
        let addressHeight = addressLabel.sizeThatFits(fittingSize).height.rounded(.up)
        let coordinatesHeight = coordinatesLabel.sizeThatFits(fittingSize).height.rounded(.up)
        let maxAddressHeight = max(
            0,
            maxHeight - contentVerticalInset * 2 - stackSpacing - coordinatesHeight
        )
        if addressHeight > maxAddressHeight + 0.5 {
            let lineHeight = max(1, addressLabel.font.lineHeight.rounded(.up))
            addressLabel.numberOfLines = max(1, Int(floor(maxAddressHeight / lineHeight)))
        }

        let rawHeight = contentVerticalInset * 2
            + min(addressHeight, maxAddressHeight)
            + stackSpacing
            + coordinatesHeight
        let nextHeight = min(maxHeight, max(minHeight, rawHeight.rounded(.up)))

        guard abs(nextHeight - preferredHeight) > 0.5 else {
            return
        }

        preferredHeight = nextHeight
        heightConstraint?.constant = nextHeight
        invalidateIntrinsicContentSize()
        onPreferredHeightChanged?(nextHeight)
    }

    private func contentFittingWidth() -> CGFloat {
        if backgroundEffectView.contentView.bounds.width > 0 {
            return max(0, backgroundEffectView.contentView.bounds.width - NativeGlassBarStyle.contentInset * 2)
        }
        if bounds.width > 0 {
            return max(0, bounds.width - NativeGlassBarStyle.contentInset * 2)
        }

        return max(
            0,
            UIScreen.main.bounds.width
                - NativeGlassBarStyle.horizontalInset * 2
                - NativeGlassBarStyle.buttonSize * 2
                - NativeGlassBarStyle.interItemSpacing * 2
                - NativeGlassBarStyle.contentInset * 2
        )
    }
}

final class ChatAttachmentSelectionComposerBarView: UIView {
    let resetButton = UIButton(type: .system)
    let captionInputView = ChatAttachmentCaptionInputView()
    let locationInfoView = ChatAttachmentLocationInfoView()
    let sendButton = UIButton(type: .system)

    var locationAddressLabel: UILabel {
        locationInfoView.addressLabel
    }

    var locationCoordinatesLabel: UILabel {
        locationInfoView.coordinatesLabel
    }

    var onResetRequested: (() -> Void)?
    var onCaptionChanged: ((String) -> Void)?
    var onPreferredHeightChanged: ((CGFloat) -> Void)?
    private(set) var selectedCount = 0
    private var isSendEnabled = false

    var preferredBarHeight: CGFloat {
        activeContentPreferredHeight
            + Self.topReserve
            + NativeGlassBarStyle.bottomOffset
    }

    var composerTintColor: UIColor = .systemBlue {
        didSet {
            applyResetButtonStyle()
            applySendButtonStyle()
        }
    }

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
        self.isSendEnabled = isSendEnabled
        applySendButtonStyle()
    }

    func updateMode(_ mode: ChatAttachmentSelectionComposerBarMode) {
        switch mode {
        case .caption:
            captionInputView.isHidden = false
            captionInputView.isUserInteractionEnabled = true
            locationInfoView.isHidden = true
        case .locationInfo(let location):
            captionInputView.isHidden = true
            captionInputView.isUserInteractionEnabled = false
            locationInfoView.isHidden = false
            locationInfoView.apply(location: location)
        }
        notifyPreferredHeightChanged()
    }

    func updateCaptionText(_ text: String) {
        guard captionInputView.text != text else {
            return
        }

        captionInputView.apply(ChatAttachmentCaptionState(rawText: text))
    }

    private func setupView() {
        backgroundColor = .clear
        isOpaque = false
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "chatAttachmentSheet.selectionComposerBar"

        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.accessibilityIdentifier = "chatAttachmentSheet.selectionComposerBar.resetButton"
        resetButton.addTarget(self, action: #selector(resetButtonTapped), for: .touchUpInside)

        captionInputView.translatesAutoresizingMaskIntoConstraints = false
        captionInputView.accessibilityIdentifier = "chatAttachmentSheet.selectionComposerBar.caption"
        captionInputView.onTextChanged = { [weak self] text in
            self?.onCaptionChanged?(text)
        }
        captionInputView.onPreferredHeightChanged = { [weak self] _ in
            guard let self else {
                return
            }

            self.notifyPreferredHeightChanged()
        }
        locationInfoView.onPreferredHeightChanged = { [weak self] _ in
            guard let self else {
                return
            }

            self.notifyPreferredHeightChanged()
        }

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.accessibilityIdentifier = "chatAttachmentSheet.selectionComposerBar.sendButton"
        locationInfoView.isHidden = true

        addSubview(resetButton)
        addSubview(captionInputView)
        addSubview(locationInfoView)
        addSubview(sendButton)

        NSLayoutConstraint.activate([
            resetButton.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: NativeGlassBarStyle.horizontalInset
            ),
            resetButton.bottomAnchor.constraint(equalTo: captionInputView.bottomAnchor),
            resetButton.heightAnchor.constraint(equalToConstant: NativeGlassBarStyle.buttonSize),
            resetButton.widthAnchor.constraint(equalToConstant: NativeGlassBarStyle.buttonSize),

            captionInputView.leadingAnchor.constraint(
                equalTo: resetButton.trailingAnchor,
                constant: NativeGlassBarStyle.interItemSpacing
            ),
            captionInputView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Self.topReserve),
            captionInputView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -NativeGlassBarStyle.bottomOffset
            ),
            captionInputView.trailingAnchor.constraint(
                equalTo: sendButton.leadingAnchor,
                constant: -NativeGlassBarStyle.interItemSpacing
            ),

            locationInfoView.leadingAnchor.constraint(equalTo: captionInputView.leadingAnchor),
            locationInfoView.trailingAnchor.constraint(equalTo: captionInputView.trailingAnchor),
            locationInfoView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Self.topReserve),
            locationInfoView.bottomAnchor.constraint(equalTo: captionInputView.bottomAnchor),

            sendButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -NativeGlassBarStyle.horizontalInset
            ),
            sendButton.bottomAnchor.constraint(equalTo: captionInputView.bottomAnchor),
            sendButton.heightAnchor.constraint(equalToConstant: NativeGlassBarStyle.buttonSize),
            sendButton.widthAnchor.constraint(equalToConstant: NativeGlassBarStyle.buttonSize)
        ])

        applyResetButtonStyle()
        updateMode(.caption)
        update(selectedCount: 0, isSendEnabled: false)
    }

    @objc
    private func resetButtonTapped() {
        onResetRequested?()
    }

    private func applyResetButtonStyle() {
        ChatAttachmentPickerComposerStyle.applyResetButtonStyle(
            to: resetButton,
            tintColor: NativeGlassBarStyle.iconTintColor
        )
    }

    private func applySendButtonStyle() {
        ChatAttachmentPickerComposerStyle.applySendButtonStyle(
            to: sendButton,
            isEnabled: isSendEnabled,
            tintColor: composerTintColor
        )
    }

    private var activeContentPreferredHeight: CGFloat {
        locationInfoView.isHidden
            ? captionInputView.preferredHeight
            : locationInfoView.preferredHeight
    }

    private func notifyPreferredHeightChanged() {
        invalidateIntrinsicContentSize()
        onPreferredHeightChanged?(preferredBarHeight)
        setNeedsLayout()
    }

    private static let topReserve: CGFloat = 8
}

final class ChatAttachmentPickerViewController: UIViewController {
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

    weak var delegate: ChatAttachmentPickerViewControllerDelegate?

    let sheetBackgroundEffectView = ChatAttachmentSheetGlassStyle.makeEffectView()
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
        rootView.backgroundColor = .clear
        rootView.isOpaque = false
        rootView.layer.cornerRadius = ChatAttachmentSheetGlassStyle.sheetCornerRadius
        rootView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        rootView.layer.masksToBounds = true

        ChatAttachmentSheetGlassStyle.applySheetSurface(to: sheetBackgroundEffectView)
        sheetBackgroundEffectView.accessibilityIdentifier = "chatAttachmentSheet.backgroundGlass"

        sourceContainerView.backgroundColor = .clear
        sourceContainerView.translatesAutoresizingMaskIntoConstraints = false
        sourceContainerView.accessibilityIdentifier = "chatAttachmentSheet.sourceContainer"

        statusBannerView.accessibilityIdentifier = "chatAttachmentSheet.statusBanner"

        sourceBarView.accessibilityIdentifier = "chatAttachmentSheet.sourceBar"
        sourceBarView.selectedTintColor = context.composerTintColor
        bottomControlsContainerView.translatesAutoresizingMaskIntoConstraints = false
        bottomControlsContainerView.accessibilityIdentifier = "chatAttachmentSheet.bottomControls"
        selectionComposerBarView.composerTintColor = context.composerTintColor
        selectionPreviewBarView.isHidden = true
        selectionPreviewBarView.previewButton.addTarget(
            self,
            action: #selector(selectionPreviewButtonTapped),
            for: .touchUpInside
        )
        selectionComposerBarView.isHidden = true
        selectionComposerBarView.onCaptionChanged = { [weak self] text in
            guard let self else { return }
            self.captionState = ChatAttachmentCaptionState(rawText: text)
        }
        selectionComposerBarView.onPreferredHeightChanged = { [weak self] _ in
            self?.updateBottomControls()
            self?.view.setNeedsLayout()
        }
        selectionComposerBarView.onResetRequested = { [weak self] in
            self?.resetSelectedAttachmentDrafts()
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

        rootView.addSubview(sheetBackgroundEffectView)
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
        let bottomControlsHeightConstraint = bottomControlsContainerView.heightAnchor.constraint(
            equalToConstant: Self.sourceModeBottomControlsHeight
        )
        self.bottomControlsHeightConstraint = bottomControlsHeightConstraint
        let bottomControlsBottomConstraint = bottomControlsContainerView.bottomAnchor.constraint(
            equalTo: rootView.keyboardLayoutGuide.topAnchor
        )
        self.bottomControlsBottomConstraint = bottomControlsBottomConstraint

        NSLayoutConstraint.activate([
            sheetBackgroundEffectView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sheetBackgroundEffectView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            sheetBackgroundEffectView.topAnchor.constraint(equalTo: rootView.topAnchor),
            sheetBackgroundEffectView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            sourceContainerView.topAnchor.constraint(equalTo: rootView.topAnchor),
            sourceContainerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sourceContainerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            sourceContainerView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

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

            sourceBarView.leadingAnchor.constraint(
                equalTo: bottomControlsContainerView.leadingAnchor,
                constant: NativeGlassBarStyle.horizontalInset
            ),
            sourceBarView.trailingAnchor.constraint(
                equalTo: bottomControlsContainerView.trailingAnchor,
                constant: -NativeGlassBarStyle.horizontalInset
            ),
            sourceBarView.topAnchor.constraint(equalTo: bottomControlsContainerView.topAnchor, constant: 8),
            sourceBarView.bottomAnchor.constraint(
                equalTo: bottomControlsContainerView.bottomAnchor,
                constant: -NativeGlassBarStyle.bottomOffset
            ),

            selectionComposerBarView.leadingAnchor.constraint(equalTo: bottomControlsContainerView.leadingAnchor),
            selectionComposerBarView.trailingAnchor.constraint(equalTo: bottomControlsContainerView.trailingAnchor),
            selectionComposerBarView.topAnchor.constraint(equalTo: bottomControlsContainerView.topAnchor),
            selectionComposerBarView.bottomAnchor.constraint(equalTo: bottomControlsContainerView.bottomAnchor)
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
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
        navigationItem.title = source.pickerNavigationTitle
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
        selectionComposerBarView.updateMode(.caption)
        selectionComposerBarView.updateCaptionText("")
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
        _ = state
        _ = animated
        chatAttachmentSheetPresentationStateDidChange(.expanded)
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
        let didChangeDrafts = selectedAttachmentDrafts != drafts
        if didChangeDrafts {
            sendFeedbackViewModel = nil
            shouldShowPreparationStatus = drafts.contains { draft in
                if case .unavailable = draft.preparationState {
                    return true
                }
                return false
            }
            currentPreparationTask?.cancel()
            currentPreparationTask = nil
            isPreparingSend = false
        }
        selectedAttachmentDrafts = drafts
        if didChangeDrafts {
            synchronizeSourceSelections(with: drafts)
        }
        updateSelectionCount(drafts.count)

        if drafts.isEmpty {
            captionState.reset()
            selectionComposerBarView.updateMode(.caption)
            selectionComposerBarView.updateCaptionText("")
            currentPreparationTask?.cancel()
            currentPreparationTask = nil
            isPreparingSend = false
        } else {
            updateSelectionComposerMode(for: drafts)
            prepareSelectedDraftsIfNeeded(showStatus: false)
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

    private func updateSelectionComposerMode(for drafts: [AttachmentDraft]) {
        if drafts.count == 1,
           let location = drafts.first?.preparedLocation {
            captionState.reset()
            selectionComposerBarView.updateCaptionText("")
            selectionComposerBarView.updateMode(.locationInfo(location))
        } else {
            selectionComposerBarView.updateMode(.caption)
            selectionComposerBarView.updateCaptionText(captionState.rawText)
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
        bottomControlsHeightConstraint?.constant = hasSelection
            ? selectionComposerBarView.preferredBarHeight
            : Self.sourceModeBottomControlsHeight
        selectionComposerBarView.update(
            selectedCount: selectedItemCount,
            isSendEnabled: ChatAttachmentSendabilityPolicy.canRequestSend(drafts: selectedAttachmentDrafts)
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
            composerTintColor: context.composerTintColor,
            onCaptionChanged: { [weak self] captionState in
                guard let self else { return }
                self.captionState = captionState
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

    private func resetSelectedAttachmentDrafts() {
        guard !selectedAttachmentDrafts.isEmpty
            || !captionState.isEmpty
            || currentPreparationTask != nil
            || isPreparingSend else {
            return
        }

        updateSelectedAttachmentDrafts([])
        updateStatusBanner()
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
        guard !isPreparingSend else {
            return
        }

        shouldShowPreparationStatus = true
        sendFeedbackViewModel = nil
        let originalDrafts = selectedAttachmentDrafts
        guard ChatAttachmentSendabilityPolicy.canRequestSend(drafts: originalDrafts) else {
            prepareSelectedDraftsIfNeeded(showStatus: true)
            return
        }

        delegate?.chatAttachmentSheetViewController(
            self,
            didRequestSend: originalDrafts,
            captionState: captionState
        )
        updateBottomControls()
        updateStatusBanner()
    }

    private func prepareSelectedDraftsIfNeeded(showStatus: Bool) {
        guard currentPreparationTask == nil,
              !selectedAttachmentDrafts.isEmpty else {
            updateBottomControls()
            updateStatusBanner()
            return
        }

        let originalDrafts = selectedAttachmentDrafts
        guard originalDrafts.contains(where: { draft in
            if case .pending = draft.preparationState {
                return true
            }
            return false
        }) else {
            updateBottomControls()
            updateStatusBanner()
            return
        }

        if showStatus {
            shouldShowPreparationStatus = true
        }
        isPreparingSend = true
        let preparingDrafts = originalDrafts.map { draft -> AttachmentDraft in
            guard case .pending = draft.preparationState else {
                return draft
            }

            var preparingDraft = draft
            preparingDraft.preparationState = .preparing
            return preparingDraft
        }
        applyPreparedOrPreparingDrafts(preparingDrafts)

        let expectedDraftIDs = originalDrafts.map(\.id)
        var didCompleteSynchronously = false
        let task = mediaPreparationCoordinator.prepare(drafts: originalDrafts) { [weak self] preparedDrafts in
            didCompleteSynchronously = true
            guard let self else {
                return
            }

            guard self.selectedAttachmentDrafts.map(\.id) == expectedDraftIDs else {
                return
            }

            self.currentPreparationTask = nil
            self.isPreparingSend = false
            self.applyPreparedOrPreparingDrafts(preparedDrafts)

            self.updateBottomControls()
            self.updateStatusBanner()
        }
        currentPreparationTask = didCompleteSynchronously ? nil : task
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

private extension ChatAttachmentSource {
    var pickerNavigationTitle: String {
        switch self {
        case .gallery:
            return ChatAttachmentLocalization.string(.sourceGalleryTitle)
        case .file:
            return ChatAttachmentLocalization.string(.sourceFileTitle)
        case .geolocation:
            return ChatAttachmentLocalization.string(.sourceLocationTitle)
        case .contact:
            return ChatAttachmentLocalization.string(.sourceContactTitle)
        }
    }
}

typealias ChatAttachmentSheetViewController = ChatAttachmentPickerViewController

extension ChatAttachmentPickerViewController: ChatAttachmentPreviewViewControllerDelegate {
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

    func chatAttachmentPreviewViewControllerDidRequestSelectionReset(_ preview: ChatAttachmentPreviewViewController) {
        resetSelectedAttachmentDrafts()
    }
}

extension ChatAttachmentPickerViewController: ChatAttachmentSheetPresentationStateObserving {
    func chatAttachmentSheetPresentationStateDidChange(_ state: ChatAttachmentSheetPresentationState) {
        presentationState = state
        guard let sourceController = sourceControllers[activeSource] else {
            return
        }

        forwardPresentationState(to: sourceController)
    }
}

extension ChatAttachmentPickerViewController: ChatAttachmentSourceBarViewDelegate {
    func chatAttachmentSourceBarView(
        _ view: ChatAttachmentSourceBarView,
        didSelect source: ChatAttachmentSource
    ) {
        switchSource(to: source)
    }

    func chatAttachmentSourceBarViewDidRequestDismiss(_ view: ChatAttachmentSourceBarView) {
        dismiss(animated: true)
    }
}

private extension ChatAttachmentPickerViewController {
    static let sourceModeBottomControlsHeight = NativeGlassBarStyle.minimumHeight
        + 8
        + NativeGlassBarStyle.bottomOffset
}
