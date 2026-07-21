import AVFoundation
import AVKit
import Photos
import UIKit

protocol ChatAttachmentDraftSelectionProviding: AnyObject {
    var selectedAttachmentDrafts: [AttachmentDraft] { get }
    var onSelectedAttachmentDraftsChanged: (([AttachmentDraft]) -> Void)? { get set }
}

protocol ChatAttachmentDraftSelectionMutating: AnyObject {
    @discardableResult
    func removeSelectedAttachmentDraft(withID draftID: String) -> [AttachmentDraft]
    @discardableResult
    func replaceSelectedAttachmentDraft(withID draftID: String, updatedDraft: AttachmentDraft) -> [AttachmentDraft]
}

protocol ChatAttachmentDraftSelectionSyncing: AnyObject {
    func syncSelectedAttachmentDrafts(_ drafts: [AttachmentDraft])
}

enum ChatAttachmentPreviewMedia {
    case image(UIImage)
    case video(thumbnail: UIImage?, playerItem: AVPlayerItem?)
    case filePlaceholder(filename: String, byteSize: Int)
    case unavailable
}

protocol ChatAttachmentPreviewMediaProviding: AnyObject {
    @discardableResult
    func requestPreviewMedia(
        for draft: AttachmentDraft,
        targetSize: CGSize,
        completion: @escaping (ChatAttachmentPreviewMedia) -> Void
    ) -> Int

    func cancelPreviewMediaRequest(_ requestID: Int)
}

protocol ChatAttachmentPreviewVideoPresenting: AnyObject {
    func presentVideo(playerItem: AVPlayerItem, from viewController: UIViewController)
}

enum ChatAttachmentPreviewNavigationPolicy {
    static func initialIndex(
        in drafts: [AttachmentDraft],
        preferredDraftID: String? = nil
    ) -> Int {
        guard !drafts.isEmpty else {
            return 0
        }

        if let preferredDraftID,
           let index = drafts.firstIndex(where: { $0.id == preferredDraftID }) {
            return index
        }

        return 0
    }

    static func indexAfterRemovingItem(
        at removedIndex: Int,
        remainingCount: Int
    ) -> Int? {
        guard remainingCount > 0 else {
            return nil
        }

        return min(max(removedIndex, 0), remainingCount - 1)
    }

    static func indexPreservingDraft(
        withID draftID: String?,
        in drafts: [AttachmentDraft],
        fallbackIndex: Int
    ) -> Int {
        guard !drafts.isEmpty else {
            return 0
        }

        if let draftID,
           let index = drafts.firstIndex(where: { $0.id == draftID }) {
            return index
        }

        return min(max(fallbackIndex, 0), drafts.count - 1)
    }
}

enum ChatAttachmentPreviewSendScopePolicy {
    static func draftsForSend(
        from selectedDrafts: [AttachmentDraft],
        activeDraftID: String?
    ) -> [AttachmentDraft] {
        selectedDrafts
    }
}

struct ChatAttachmentCaptionState: Equatable {
    var rawText: String = ""

    var isEmpty: Bool {
        rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func reset() {
        rawText = ""
    }
}

struct ChatAttachmentCaptionOutgoingBody: Equatable {
    let body: String
    let legacyBody: String
}

enum ChatAttachmentCaptionOutgoingBodyPolicy {
    static func makeOutgoingBody(
        caption: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        references: [MessageReferenceStorageItem] = []
    ) -> ChatAttachmentCaptionOutgoingBody {
        let normalizedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : caption
        if references.count == 1,
           references.first?.kind == .geoloc,
           let geoURI = references.first?.url ?? references.first?.metadata?["uri"] as? String,
           geoURI.isNotEmpty {
            references.first?.begin = 0
            references.first?.end = geoURI.xmlEscaping(reverse: false).count
            return ChatAttachmentCaptionOutgoingBody(
                body: geoURI,
                legacyBody: geoURI
            )
        }
        let contactReferences = references.filter { $0.kind == .contact }
        if contactReferences.isNotEmpty {
            var body = normalizedCaption
            contactReferences.forEach { reference in
                let fallback = contactFallbackBody(for: reference)
                guard fallback.isNotEmpty else { return }
                let separator = body.isEmpty ? "" : "\n"
                reference.begin = body.xmlEscaping(reverse: false).count
                body += separator + fallback
                reference.end = body.xmlEscaping(reverse: false).count
            }
            return ChatAttachmentCaptionOutgoingBody(
                body: body,
                legacyBody: body
            )
        }
        return ChatAttachmentCaptionOutgoingBody(
            body: normalizedCaption,
            legacyBody: normalizedCaption
        )
    }

    static func makeOutgoingBody(
        captionState: ChatAttachmentCaptionState,
        conversationType: ClientSynchronizationManager.ConversationType,
        references: [MessageReferenceStorageItem] = []
    ) -> ChatAttachmentCaptionOutgoingBody {
        makeOutgoingBody(
            caption: captionState.rawText,
            conversationType: conversationType,
            references: references
        )
    }

    private static func contactFallbackBody(for reference: MessageReferenceStorageItem) -> String {
        let metadata = reference.metadata
        let urlJID: String?
        if let url = reference.url, url.hasPrefix("xmpp:") {
            urlJID = String(url.dropFirst("xmpp:".count))
        } else {
            urlJID = reference.url
        }
        let contactJID = (metadata?["contact_jid"] as? String ?? urlJID ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard contactJID.isNotEmpty else { return "" }

        let given = (metadata?["given"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let family = (metadata?["family"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let structuredName = [given, family]
            .filter { $0.isNotEmpty }
            .joined(separator: " ")
        let displayTitle = (metadata?["display_title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = (metadata?["nickname"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let display = [structuredName, displayTitle, nickname, contactJID]
            .first(where: { $0.isNotEmpty }) ?? contactJID

        return display == contactJID ? contactJID : "\(display) (\(contactJID))"
    }
}

final class ChatAttachmentCaptionInputView: UIView, UITextViewDelegate {
    let backgroundEffectView = ChatAttachmentSheetGlassStyle.makeEffectView(interactive: true)
    let textView = InputTextView()

    var placeholderLabel: UILabel {
        textView.placeholderLabel
    }

    var onTextChanged: ((String) -> Void)?
    var onPreferredHeightChanged: ((CGFloat) -> Void)?

    var text: String {
        get { textView.text ?? "" }
        set { setText(newValue, notify: true) }
    }

    private(set) var preferredHeight: CGFloat = NativeGlassBarStyle.minimumHeight
    private let minHeight: CGFloat = NativeGlassBarStyle.minimumHeight
    private let maxTextViewHeight: CGFloat = ChatAttachmentPickerComposerStyle.maxTextViewHeight
    private let composerTextVerticalPadding: CGFloat = ChatAttachmentPickerComposerStyle.textVerticalInset * 2
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateHeight()
    }

    func apply(_ state: ChatAttachmentCaptionState) {
        setText(state.rawText, notify: false)
    }

    func textViewDidChange(_ textView: UITextView) {
        updatePlaceholderVisibility()
        updateHeight()
        onTextChanged?(textView.text ?? "")
    }

    private func setText(_ text: String, notify: Bool) {
        textView.text = text
        textView.typingAttributes = [
            .font: textView.font ?? UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label
        ]
        updatePlaceholderVisibility()
        updateHeight()
        if notify {
            onTextChanged?(text)
        }
    }

    private func setupView() {
        backgroundColor = .clear
        isOpaque = false
        layer.cornerRadius = NativeGlassBarStyle.cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "chatAttachmentPreview.captionInput"

        ChatAttachmentPickerComposerStyle.applyCaptionSurface(to: backgroundEffectView)

        ChatAttachmentPickerComposerStyle.configureCaptionTextView(textView)
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.accessibilityIdentifier = "chatAttachmentPreview.captionTextView"
        textView.accessibilityLabel = ChatAttachmentLocalization.string(.captionAccessibilityLabel)
        textView.accessibilityHint = ChatAttachmentPickerComposerStyle.placeholderText
        textView.typingAttributes = [
            .font: textView.font ?? UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label
        ]

        addSubview(backgroundEffectView)
        backgroundEffectView.contentView.addSubview(textView)

        let heightConstraint = heightAnchor.constraint(equalToConstant: minHeight)
        self.heightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            heightConstraint,

            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            textView.leadingAnchor.constraint(
                equalTo: backgroundEffectView.contentView.leadingAnchor,
                constant: ChatAttachmentPickerComposerStyle.textHorizontalInset
            ),
            textView.trailingAnchor.constraint(
                equalTo: backgroundEffectView.contentView.trailingAnchor,
                constant: -ChatAttachmentPickerComposerStyle.textHorizontalInset
            ),
            textView.topAnchor.constraint(
                equalTo: backgroundEffectView.contentView.topAnchor,
                constant: ChatAttachmentPickerComposerStyle.textVerticalInset
            ),
            textView.bottomAnchor.constraint(
                equalTo: backgroundEffectView.contentView.bottomAnchor,
                constant: -ChatAttachmentPickerComposerStyle.textVerticalInset
            )
        ])

        updatePlaceholderVisibility()
    }

    private func updatePlaceholderVisibility() {
        textView.placeholderLabel.isHidden = !(textView.text ?? "").isEmpty
    }

    private func updateHeight() {
        let fallbackContainerWidth = max(0, UIScreen.main.bounds.width - 32)
        let fittingWidth = textView.bounds.width > 0
            ? textView.bounds.width
            : max(
                0,
                (bounds.width > 0 ? bounds.width : fallbackContainerWidth)
                    - ChatAttachmentPickerComposerStyle.textHorizontalInset * 2
            )
        let fittingSize = CGSize(width: fittingWidth, height: .greatestFiniteMagnitude)
        let fittingHeight = textView.sizeThatFits(fittingSize).height.rounded(.down)
        let textViewHeight = min(fittingHeight, maxTextViewHeight)
        let rawHeight = textViewHeight + composerTextVerticalPadding
        let nextHeight = rawHeight <= singleLineComposerHeight + collapsedHeightTolerance
            ? minHeight
            : max(minHeight, rawHeight)
        textView.isScrollEnabled = fittingHeight >= maxTextViewHeight

        guard abs(nextHeight - preferredHeight) > 0.5 else {
            return
        }

        preferredHeight = nextHeight
        heightConstraint?.constant = nextHeight
        onPreferredHeightChanged?(nextHeight)
        invalidateIntrinsicContentSize()
    }

    private var singleLineComposerHeight: CGFloat {
        let font = textView.font ?? UIFont.preferredFont(forTextStyle: .body)
        return font.lineHeight
            + textView.textContainerInset.top
            + textView.textContainerInset.bottom
            + (textView.textContainer.lineFragmentPadding * 2)
            + composerTextVerticalPadding
    }

    private var collapsedHeightTolerance: CGFloat {
        1
    }
}

final class ChatAttachmentSelectionPreviewBarView: UIView {
    let previewButton = UIButton(type: .system)
    private(set) var selectedCount: Int = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    func update(selectedCount: Int) {
        self.selectedCount = selectedCount
        var configuration = previewButton.configuration ?? UIButton.Configuration.filled()
        configuration.title = selectedCount == 1
            ? ChatAttachmentLocalization.string(.previewOneItem)
            : ChatAttachmentLocalization.string(.previewMultipleItems, arguments: ["\(selectedCount)"])
        previewButton.configuration = configuration
        previewButton.accessibilityLabel = configuration.title
    }

    private func setupView() {
        backgroundColor = .clear
        isOpaque = false
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "chatAttachmentSheet.previewBar"

        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "rectangle.stack")
        configuration.imagePadding = 8
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        previewButton.configuration = configuration
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        previewButton.accessibilityIdentifier = "chatAttachmentSheet.previewBar.button"

        let separatorView = UIView()
        separatorView.backgroundColor = .separator
        separatorView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(separatorView)
        addSubview(previewButton)

        NSLayoutConstraint.activate([
            separatorView.topAnchor.constraint(equalTo: topAnchor),
            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            previewButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            previewButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            previewButton.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: 6),
            previewButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])

        update(selectedCount: 0)
    }
}

protocol ChatAttachmentPreviewViewControllerDelegate: AnyObject {
    func chatAttachmentPreviewViewControllerDidClose(_ preview: ChatAttachmentPreviewViewController)
    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didRemoveDraftWithID draftID: String
    )
    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didRetryDraftWithID draftID: String
    )
    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didReplaceDraftWithID draftID: String,
        updatedDraft: AttachmentDraft
    )
    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didRequestSend drafts: [AttachmentDraft]
    )
    func chatAttachmentPreviewViewControllerDidRequestSelectionReset(_ preview: ChatAttachmentPreviewViewController)
}

extension ChatAttachmentPreviewViewControllerDelegate {
    func chatAttachmentPreviewViewController(
        _ preview: ChatAttachmentPreviewViewController,
        didRetryDraftWithID draftID: String
    ) {}

    func chatAttachmentPreviewViewControllerDidRequestSelectionReset(_ preview: ChatAttachmentPreviewViewController) {}
}

final class ChatAttachmentPreviewViewController: UIViewController {
    typealias ImageEditorPresentationHandler = (
        UIViewController,
        ChatAttachmentImageEditorViewController,
        Bool,
        (() -> Void)?
    ) -> Void
    typealias ImageEditorDismissalHandler = (
        ChatAttachmentImageEditorViewController,
        Bool,
        (() -> Void)?
    ) -> Void

    weak var delegate: ChatAttachmentPreviewViewControllerDelegate?

    let closeButton = UIButton(type: .system)
    let countLabel = UILabel()
    let composerBarView = ChatAttachmentSelectionComposerBarView()
    let removeButton = UIButton(type: .system)
    let editButton = UIButton(type: .system)
    let statusBannerView = ChatAttachmentStatusBannerView()
    let collectionView: UICollectionView

    var sendButton: UIButton {
        composerBarView.sendButton
    }

    var captionInputView: ChatAttachmentCaptionInputView {
        composerBarView.captionInputView
    }

    private let mediaProvider: ChatAttachmentPreviewMediaProviding
    private let videoPresenter: ChatAttachmentPreviewVideoPresenting
    private let imageEditSourceProvider: ChatAttachmentImageEditSourceProviding
    private let imageEditOutputBuilder: ChatAttachmentImageEditOutputBuilding
    private let imageEditorPresentationHandler: ImageEditorPresentationHandler
    private let imageEditorDismissalHandler: ImageEditorDismissalHandler
    private let onCaptionChanged: (ChatAttachmentCaptionState) -> Void
    private let sendAvailabilityProvider: ([AttachmentDraft]) -> Bool
    private let composerTintColor: UIColor
    private var activeImageEditRequestID: Int?
    private var sendFeedbackViewModel: ChatAttachmentStatusBannerViewModel?

    private(set) var drafts: [AttachmentDraft]
    private(set) var currentIndex: Int
    private(set) var captionState: ChatAttachmentCaptionState
    private(set) var lastImageEditSourceError: ChatAttachmentImageEditSourceError?
    private(set) var lastImageEditOutputError: ChatAttachmentImageEditOutputBuilderError?
    private var statusBannerHeightConstraint: NSLayoutConstraint?
    private var composerBarHeightConstraint: NSLayoutConstraint?

    var currentDraft: AttachmentDraft? {
        guard drafts.indices.contains(currentIndex) else {
            return nil
        }

        return drafts[currentIndex]
    }

    init(
        drafts: [AttachmentDraft],
        preferredDraftID: String? = nil,
        captionState: ChatAttachmentCaptionState = ChatAttachmentCaptionState(),
        mediaProvider: ChatAttachmentPreviewMediaProviding = PhotoKitChatAttachmentPreviewMediaProvider(),
        videoPresenter: ChatAttachmentPreviewVideoPresenting = AVPlayerChatAttachmentPreviewVideoPresenter(),
        imageEditSourceProvider: ChatAttachmentImageEditSourceProviding = DefaultChatAttachmentImageEditSourceProvider(),
        imageEditOutputBuilder: ChatAttachmentImageEditOutputBuilding = ChatAttachmentImageEditOutputBuilder(),
        imageEditorPresentationHandler: @escaping ImageEditorPresentationHandler = { presenter, editor, animated, completion in
            presenter.present(editor, animated: animated, completion: completion)
        },
        imageEditorDismissalHandler: @escaping ImageEditorDismissalHandler = { editor, animated, completion in
            editor.dismiss(animated: animated, completion: completion)
        },
        composerTintColor: UIColor = .systemBlue,
        onCaptionChanged: @escaping (ChatAttachmentCaptionState) -> Void = { _ in },
        sendAvailabilityProvider: @escaping ([AttachmentDraft]) -> Bool = ChatAttachmentSendabilityPolicy.canRequestSend
    ) {
        self.drafts = drafts
        self.currentIndex = ChatAttachmentPreviewNavigationPolicy.initialIndex(
            in: drafts,
            preferredDraftID: preferredDraftID
        )
        self.captionState = captionState
        self.mediaProvider = mediaProvider
        self.videoPresenter = videoPresenter
        self.imageEditSourceProvider = imageEditSourceProvider
        self.imageEditOutputBuilder = imageEditOutputBuilder
        self.imageEditorPresentationHandler = imageEditorPresentationHandler
        self.imageEditorDismissalHandler = imageEditorDismissalHandler
        self.onCaptionChanged = onCaptionChanged
        self.sendAvailabilityProvider = sendAvailabilityProvider
        self.composerTintColor = composerTintColor

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        self.collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .black

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        configureIconButton(
            closeButton,
            systemImageName: "chevron.left",
            accessibilityLabel: ChatAttachmentLocalization.string(.actionBack),
            accessibilityIdentifier: "chatAttachmentPreview.backButton"
        )
        closeButton.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)

        countLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        countLabel.textColor = .white
        countLabel.textAlignment = .center
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.accessibilityIdentifier = "chatAttachmentPreview.countLabel"

        collectionView.backgroundColor = .black
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            ChatAttachmentPreviewCollectionViewCell.self,
            forCellWithReuseIdentifier: ChatAttachmentPreviewCollectionViewCell.reuseIdentifier
        )
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.accessibilityIdentifier = "chatAttachmentPreview.collectionView"

        var removeConfiguration = UIButton.Configuration.plain()
        removeConfiguration.image = UIImage(systemName: "checkmark.circle.fill")
        removeConfiguration.imagePadding = 8
        removeConfiguration.title = ChatAttachmentLocalization.string(.actionSelected)
        removeConfiguration.baseForegroundColor = .white
        removeButton.configuration = removeConfiguration
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.accessibilityIdentifier = "chatAttachmentPreview.removeButton"
        removeButton.accessibilityLabel = ChatAttachmentLocalization.string(.actionSelected)
        removeButton.addTarget(self, action: #selector(removeButtonTapped), for: .touchUpInside)

        var editConfiguration = UIButton.Configuration.plain()
        editConfiguration.image = UIImage(systemName: "crop.rotate")
        editConfiguration.imagePadding = 8
        editConfiguration.title = ChatAttachmentLocalization.string(.actionEdit)
        editConfiguration.baseForegroundColor = .white
        editButton.configuration = editConfiguration
        editButton.translatesAutoresizingMaskIntoConstraints = false
        editButton.accessibilityIdentifier = "chatAttachmentPreview.editButton"
        editButton.accessibilityLabel = ChatAttachmentLocalization.string(.actionEdit)
        editButton.addTarget(self, action: #selector(editButtonTapped), for: .touchUpInside)

        composerBarView.accessibilityIdentifier = "chatAttachmentPreview.composerBar"
        composerBarView.composerTintColor = composerTintColor
        composerBarView.resetButton.accessibilityIdentifier = "chatAttachmentPreview.composer.resetButton"
        composerBarView.captionInputView.accessibilityIdentifier = "chatAttachmentPreview.captionInput"
        composerBarView.sendButton.accessibilityIdentifier = "chatAttachmentPreview.sendButton"
        composerBarView.sendButton.addTarget(self, action: #selector(sendButtonTapped), for: .touchUpInside)
        composerBarView.onResetRequested = { [weak self] in
            self?.resetSelectionButtonTapped()
        }
        composerBarView.onPreferredHeightChanged = { [weak self] height in
            self?.updateComposerBarHeight(height)
        }

        let bottomControlsView = UIView()
        bottomControlsView.translatesAutoresizingMaskIntoConstraints = false
        bottomControlsView.accessibilityIdentifier = "chatAttachmentPreview.bottomControls"

        statusBannerView.onRetryTapped = { [weak self] in
            self?.retryCurrentDraft()
        }
        statusBannerView.onRemoveTapped = { [weak self] in
            self?.removeCurrentDraft()
        }

        captionInputView.apply(captionState)
        composerBarView.onCaptionChanged = { [weak self] text in
            guard let self else {
                return
            }

            self.captionState.rawText = text
            self.onCaptionChanged(self.captionState)
        }

        rootView.addSubview(closeButton)
        rootView.addSubview(countLabel)
        rootView.addSubview(editButton)
        rootView.addSubview(collectionView)
        rootView.addSubview(bottomControlsView)
        bottomControlsView.addSubview(statusBannerView)
        bottomControlsView.addSubview(composerBarView)
        let statusHeightConstraint = statusBannerView.heightAnchor.constraint(equalToConstant: 0)
        statusBannerHeightConstraint = statusHeightConstraint
        let composerBarHeightConstraint = composerBarView.heightAnchor.constraint(
            equalToConstant: composerBarView.preferredBarHeight
        )
        self.composerBarHeightConstraint = composerBarHeightConstraint

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            closeButton.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            countLabel.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            countLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: editButton.leadingAnchor, constant: -8),

            editButton.trailingAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            editButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            editButton.heightAnchor.constraint(equalToConstant: 44),

            collectionView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            collectionView.bottomAnchor.constraint(equalTo: bottomControlsView.topAnchor, constant: -8),

            bottomControlsView.leadingAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.leadingAnchor),
            bottomControlsView.trailingAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.trailingAnchor),
            bottomControlsView.bottomAnchor.constraint(equalTo: rootView.keyboardLayoutGuide.topAnchor, constant: -8),

            statusBannerView.leadingAnchor.constraint(
                equalTo: bottomControlsView.leadingAnchor,
                constant: NativeGlassBarStyle.horizontalInset
            ),
            statusBannerView.trailingAnchor.constraint(
                equalTo: bottomControlsView.trailingAnchor,
                constant: -NativeGlassBarStyle.horizontalInset
            ),
            statusBannerView.topAnchor.constraint(equalTo: bottomControlsView.topAnchor),
            statusHeightConstraint,

            composerBarView.leadingAnchor.constraint(equalTo: bottomControlsView.leadingAnchor),
            composerBarView.trailingAnchor.constraint(equalTo: bottomControlsView.trailingAnchor),
            composerBarView.topAnchor.constraint(equalTo: statusBannerView.bottomAnchor, constant: 8),
            composerBarView.bottomAnchor.constraint(equalTo: bottomControlsView.bottomAnchor),
            composerBarHeightConstraint
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateControls()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            layout.itemSize = collectionView.bounds.size
            layout.invalidateLayout()
        }
        scrollToCurrentIndex(animated: false)
    }

    func updateDrafts(_ drafts: [AttachmentDraft]) {
        let currentDraftID = currentDraft?.id
        let fallbackIndex = currentIndex
        self.drafts = drafts
        currentIndex = ChatAttachmentPreviewNavigationPolicy.indexPreservingDraft(
            withID: currentDraftID,
            in: drafts,
            fallbackIndex: fallbackIndex
        )
        collectionView.reloadData()
        updateControls()
        scrollToCurrentIndex(animated: false)
    }

    func updateCaptionState(_ captionState: ChatAttachmentCaptionState) {
        self.captionState = captionState
        if isViewLoaded {
            captionInputView.apply(captionState)
        }
    }

    func goToNextDraft() {
        guard currentIndex + 1 < drafts.count else {
            return
        }

        setCurrentIndex(currentIndex + 1, animated: false)
    }

    func goToPreviousDraft() {
        guard currentIndex > 0 else {
            return
        }

        setCurrentIndex(currentIndex - 1, animated: false)
    }

    func removeCurrentDraft() {
        guard let currentDraft else {
            return
        }

        delegate?.chatAttachmentPreviewViewController(self, didRemoveDraftWithID: currentDraft.id)
    }

    func applySendFeedback(_ viewModel: ChatAttachmentStatusBannerViewModel) {
        sendFeedbackViewModel = viewModel.kind == .hidden ? nil : viewModel
        updateStatusBanner()
    }

    private func setCurrentIndex(_ index: Int, animated: Bool) {
        guard drafts.indices.contains(index) else {
            return
        }

        currentIndex = index
        updateControls()
        scrollToCurrentIndex(animated: animated)
    }

    private func scrollToCurrentIndex(animated: Bool) {
        guard isViewLoaded,
              drafts.indices.contains(currentIndex),
              collectionView.numberOfItems(inSection: 0) > currentIndex else {
            return
        }

        collectionView.scrollToItem(
            at: IndexPath(item: currentIndex, section: 0),
            at: .centeredHorizontally,
            animated: animated
        )
    }

    private func updateControls() {
        if drafts.isEmpty {
            countLabel.text = "0 / 0"
            removeButton.isEnabled = false
            editButton.isHidden = true
            editButton.isEnabled = false
            composerBarView.update(selectedCount: 0, isSendEnabled: false)
            statusBannerView.apply(.hidden)
            statusBannerHeightConstraint?.constant = 0
            return
        }

        countLabel.text = "\(currentIndex + 1) / \(drafts.count)"
        removeButton.isEnabled = currentDraft != nil
        let canEditCurrentDraft = currentDraft.map(ChatAttachmentImageEditAvailabilityPolicy.isEditable) ?? false
        editButton.isHidden = !canEditCurrentDraft
        editButton.isEnabled = canEditCurrentDraft
        composerBarView.update(
            selectedCount: drafts.count,
            isSendEnabled: sendAvailabilityProvider(drafts)
        )
        updateStatusBanner()
    }

    private func updateStatusBanner() {
        if let sendFeedbackViewModel {
            statusBannerView.apply(sendFeedbackViewModel)
            statusBannerHeightConstraint?.constant = statusBannerView.isHidden ? 0 : 74
            return
        }
        guard let currentDraft else {
            statusBannerView.apply(.hidden)
            statusBannerHeightConstraint?.constant = 0
            return
        }

        let viewModel = ChatAttachmentDraftStatusPolicy.viewModel(for: currentDraft)
        statusBannerView.apply(viewModel.kind == .ready ? .hidden : viewModel)
        statusBannerHeightConstraint?.constant = statusBannerView.isHidden ? 0 : 74
    }

    private func updateComposerBarHeight(_ height: CGFloat) {
        composerBarHeightConstraint?.constant = height
        guard isViewLoaded else {
            return
        }

        view.setNeedsLayout()
    }

    private func configureIconButton(
        _ button: UIButton,
        systemImageName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String
    ) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemImageName)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        configuration.baseForegroundColor = .white
        button.configuration = configuration
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityIdentifier = accessibilityIdentifier
    }

    @objc
    private func closeButtonTapped() {
        delegate?.chatAttachmentPreviewViewControllerDidClose(self)
        dismiss(animated: true, completion: nil)
    }

    @objc
    private func removeButtonTapped() {
        removeCurrentDraft()
    }

    private func resetSelectionButtonTapped() {
        delegate?.chatAttachmentPreviewViewControllerDidRequestSelectionReset(self)
    }

    private func retryCurrentDraft() {
        if sendFeedbackViewModel?.showsRetryAction == true {
            sendFeedbackViewModel = nil
            updateStatusBanner()
            delegate?.chatAttachmentPreviewViewController(
                self,
                didRequestSend: ChatAttachmentPreviewSendScopePolicy.draftsForSend(
                    from: drafts,
                    activeDraftID: currentDraft?.id
                )
            )
            return
        }
        guard let currentDraft else {
            return
        }

        delegate?.chatAttachmentPreviewViewController(self, didRetryDraftWithID: currentDraft.id)
    }

    @objc
    private func editButtonTapped() {
        guard let currentDraft,
              ChatAttachmentImageEditAvailabilityPolicy.isEditable(currentDraft) else {
            return
        }

        activeImageEditRequestID = imageEditSourceProvider.requestEditableImage(
            for: currentDraft,
            targetSize: collectionView.bounds.size == .zero ? UIScreen.main.bounds.size : collectionView.bounds.size
        ) { [weak self] result in
            let applyResult = {
                guard let self,
                      self.currentDraft?.id == currentDraft.id else {
                    return
                }

                switch result {
                case .success(let image):
                    self.presentImageEditor(for: currentDraft, image: image)
                case .failure(let error):
                    self.lastImageEditSourceError = error
                    self.presentEditUnavailableAlert()
                }
            }

            if Thread.isMainThread {
                applyResult()
            } else {
                DispatchQueue.main.async(execute: applyResult)
            }
        }
    }

    @objc
    private func sendButtonTapped() {
        guard sendButton.isEnabled else {
            return
        }

        delegate?.chatAttachmentPreviewViewController(
            self,
            didRequestSend: ChatAttachmentPreviewSendScopePolicy.draftsForSend(
                from: drafts,
                activeDraftID: currentDraft?.id
            )
        )
    }

    private func presentImageEditor(for draft: AttachmentDraft, image: UIImage) {
        let editor = ChatAttachmentImageEditorViewController(
            draft: draft,
            image: image,
            outputBuilder: imageEditOutputBuilder
        )
        editor.delegate = self
        editor.loadViewIfNeeded()
        imageEditorPresentationHandler(self, editor, true, nil)
    }

    private func presentEditUnavailableAlert() {
        guard presentedViewController == nil else {
            return
        }

        let alert = UIAlertController(
            title: ChatAttachmentLocalization.string(.editUnavailableTitle),
            message: ChatAttachmentLocalization.string(.editUnavailableMessage),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: ChatAttachmentLocalization.string(.actionOK), style: .default))
        present(alert, animated: true)
    }
}

extension ChatAttachmentPreviewViewController: ChatAttachmentImageEditorViewControllerDelegate {
    func chatAttachmentImageEditorViewControllerDidCancel(_ editor: ChatAttachmentImageEditorViewController) {
        editor.delegate = nil
        imageEditorDismissalHandler(editor, true, nil)
    }

    func chatAttachmentImageEditorViewController(
        _ editor: ChatAttachmentImageEditorViewController,
        didFinishWith editedDraft: AttachmentDraft
    ) {
        editor.delegate = nil
        imageEditorDismissalHandler(editor, true, nil)
        delegate?.chatAttachmentPreviewViewController(
            self,
            didReplaceDraftWithID: editor.draft.id,
            updatedDraft: editedDraft
        )
    }

    func chatAttachmentImageEditorViewController(
        _ editor: ChatAttachmentImageEditorViewController,
        didFailWith error: ChatAttachmentImageEditOutputBuilderError
    ) {
        lastImageEditOutputError = error
        presentEditUnavailableAlert()
    }
}

extension ChatAttachmentPreviewViewController: UICollectionViewDataSource {
    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        drafts.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard drafts.indices.contains(indexPath.item),
              let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatAttachmentPreviewCollectionViewCell.reuseIdentifier,
                for: indexPath
              ) as? ChatAttachmentPreviewCollectionViewCell else {
            return UICollectionViewCell()
        }

        let draft = drafts[indexPath.item]
        cell.configureLoading(for: draft)
        let targetSize = collectionView.bounds.size == .zero
            ? UIScreen.main.bounds.size
            : collectionView.bounds.size
        let requestID = mediaProvider.requestPreviewMedia(
            for: draft,
            targetSize: targetSize
        ) { [weak self, weak cell] media in
            let applyMedia = {
                guard let self,
                      cell?.representedDraftID == draft.id else {
                    return
                }

                cell?.configure(
                    media: media,
                    draft: draft,
                    playHandler: { [weak self] playerItem in
                        guard let self else {
                            return
                        }

                        self.videoPresenter.presentVideo(playerItem: playerItem, from: self)
                    }
                )
            }

            if Thread.isMainThread {
                applyMedia()
            } else {
                DispatchQueue.main.async(execute: applyMedia)
            }
        }

        cell.onPrepareForReuse = { [weak self] in
            self?.mediaProvider.cancelPreviewMediaRequest(requestID)
        }

        return cell
    }
}

extension ChatAttachmentPreviewViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        collectionView.bounds.size
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard collectionView.bounds.width > 0 else {
            return
        }

        let index = Int(round(collectionView.contentOffset.x / collectionView.bounds.width))
        if drafts.indices.contains(index) {
            currentIndex = index
            updateControls()
        }
    }
}

final class ChatAttachmentPreviewCollectionViewCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatAttachmentPreviewCollectionViewCell"

    let imageView = UIImageView()
    let placeholderTitleLabel = UILabel()
    let placeholderSubtitleLabel = UILabel()
    let playButton = UIButton(type: .system)

    var representedDraftID: String?
    var onPrepareForReuse: (() -> Void)?

    private var playerItem: AVPlayerItem?
    private var playHandler: ((AVPlayerItem) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onPrepareForReuse?()
        onPrepareForReuse = nil
        representedDraftID = nil
        imageView.image = nil
        imageView.isHidden = true
        placeholderTitleLabel.text = nil
        placeholderSubtitleLabel.text = nil
        placeholderTitleLabel.isHidden = true
        placeholderSubtitleLabel.isHidden = true
        playButton.isHidden = true
        playerItem = nil
        playHandler = nil
        accessibilityLabel = nil
    }

    func configureLoading(for draft: AttachmentDraft) {
        representedDraftID = draft.id
        imageView.isHidden = true
        placeholderTitleLabel.text = ChatAttachmentLocalization.string(.previewLoading)
        placeholderSubtitleLabel.text = draft.filename
        placeholderTitleLabel.isHidden = false
        placeholderSubtitleLabel.isHidden = false
        playButton.isHidden = true
        accessibilityLabel = [ChatAttachmentLocalization.string(.previewLoading), draft.filename].joined(separator: " ")
    }

    func configure(
        media: ChatAttachmentPreviewMedia,
        draft: AttachmentDraft,
        playHandler: @escaping (AVPlayerItem) -> Void
    ) {
        representedDraftID = draft.id
        self.playHandler = playHandler
        imageView.image = nil
        imageView.isHidden = true
        placeholderTitleLabel.isHidden = true
        placeholderSubtitleLabel.isHidden = true
        playButton.isHidden = true
        playerItem = nil

        switch media {
        case .image(let image):
            imageView.image = image
            imageView.isHidden = false
            accessibilityLabel = draft.filename
        case .video(let thumbnail, let playerItem):
            imageView.image = thumbnail
            imageView.isHidden = thumbnail == nil
            placeholderTitleLabel.text = draft.filename
            placeholderSubtitleLabel.text = draft.duration.map {
                ChatAttachmentLocalization.string(.previewDurationSeconds, arguments: ["\($0)"])
            }
            placeholderTitleLabel.isHidden = thumbnail != nil
            placeholderSubtitleLabel.isHidden = thumbnail != nil || draft.duration == nil
            self.playerItem = playerItem
            playButton.isHidden = playerItem == nil
            accessibilityLabel = ChatAttachmentLocalization.string(.previewVideoAccessibilityLabel, arguments: [draft.filename])
        case .filePlaceholder(let filename, let byteSize):
            placeholderTitleLabel.text = filename
            placeholderSubtitleLabel.text = Self.byteSizeLabel(byteSize)
            placeholderTitleLabel.isHidden = false
            placeholderSubtitleLabel.isHidden = false
            accessibilityLabel = filename
        case .unavailable:
            placeholderTitleLabel.text = ChatAttachmentLocalization.string(.previewUnavailable)
            placeholderSubtitleLabel.text = draft.filename
            placeholderTitleLabel.isHidden = false
            placeholderSubtitleLabel.isHidden = false
            accessibilityLabel = [draft.filename, ChatAttachmentLocalization.string(.accessibilityUnavailable)].joined(separator: " ")
        }
    }

    private func setupView() {
        contentView.backgroundColor = .black

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false

        placeholderTitleLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        placeholderTitleLabel.textColor = .white
        placeholderTitleLabel.textAlignment = .center
        placeholderTitleLabel.numberOfLines = 2
        placeholderTitleLabel.adjustsFontForContentSizeCategory = true
        placeholderTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        placeholderSubtitleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        placeholderSubtitleLabel.textColor = .lightGray
        placeholderSubtitleLabel.textAlignment = .center
        placeholderSubtitleLabel.numberOfLines = 2
        placeholderSubtitleLabel.adjustsFontForContentSizeCategory = true
        placeholderSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        var playConfiguration = UIButton.Configuration.filled()
        playConfiguration.image = UIImage(systemName: "play.fill")
        playConfiguration.cornerStyle = .capsule
        playConfiguration.baseBackgroundColor = UIColor.white.withAlphaComponent(0.24)
        playConfiguration.baseForegroundColor = .white
        playButton.configuration = playConfiguration
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.accessibilityIdentifier = "chatAttachmentPreview.playButton"
        playButton.accessibilityLabel = ChatAttachmentLocalization.string(.previewPlayVideo)
        playButton.addTarget(self, action: #selector(playButtonTapped), for: .touchUpInside)

        contentView.addSubview(imageView)
        contentView.addSubview(placeholderTitleLabel)
        contentView.addSubview(placeholderSubtitleLabel)
        contentView.addSubview(playButton)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            placeholderTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
            placeholderTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
            placeholderTitleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            placeholderTitleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -14),

            placeholderSubtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
            placeholderSubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
            placeholderSubtitleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            placeholderSubtitleLabel.topAnchor.constraint(equalTo: placeholderTitleLabel.bottomAnchor, constant: 6),

            playButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 62),
            playButton.heightAnchor.constraint(equalToConstant: 62)
        ])

        prepareForReuse()
    }

    @objc
    private func playButtonTapped() {
        guard let playerItem else {
            return
        }

        playHandler?(playerItem)
    }

    private static func byteSizeLabel(_ byteSize: Int) -> String {
        byteSize == 1 ? "1 byte" : "\(byteSize) bytes"
    }
}

final class PhotoKitChatAttachmentPreviewMediaProvider: ChatAttachmentPreviewMediaProviding {
    private let imageManager: PHImageManager

    init(imageManager: PHImageManager = PHImageManager.default()) {
        self.imageManager = imageManager
    }

    @discardableResult
    func requestPreviewMedia(
        for draft: AttachmentDraft,
        targetSize: CGSize,
        completion: @escaping (ChatAttachmentPreviewMedia) -> Void
    ) -> Int {
        if case .preparedLocation(let location) = draft.preparationState {
            completion(previewMediaForPreparedLocation(location, draft: draft))
            return Int(PHInvalidImageRequestID)
        }

        if let capturedURL = draft.capturedLocalFileURL {
            completion(previewMediaForCapturedDraft(draft, localFileURL: capturedURL))
            return Int(PHInvalidImageRequestID)
        }

        if draft.source == .file,
           case .prepared(let file) = draft.preparationState {
            if file.uploadedRemoteFile != nil {
                completion(.filePlaceholder(filename: draft.filename, byteSize: draft.byteSize))
                return Int(PHInvalidImageRequestID)
            }

            completion(previewMediaForPreparedFileDraft(draft, localFileURL: file.localFileURL))
            return Int(PHInvalidImageRequestID)
        }

        if let assetLocalIdentifier = draft.galleryAssetLocalIdentifier {
            return requestPhotoKitMedia(
                for: draft,
                assetLocalIdentifier: assetLocalIdentifier,
                targetSize: targetSize,
                completion: completion
            )
        }

        completion(.filePlaceholder(filename: draft.filename, byteSize: draft.byteSize))
        return Int(PHInvalidImageRequestID)
    }

    func cancelPreviewMediaRequest(_ requestID: Int) {
        guard requestID != Int(PHInvalidImageRequestID) else {
            return
        }

        imageManager.cancelImageRequest(PHImageRequestID(requestID))
    }

    private func previewMediaForPreparedLocation(
        _ location: AttachmentPreparedLocation,
        draft: AttachmentDraft
    ) -> ChatAttachmentPreviewMedia {
        guard let snapshotURL = location.localSnapshotURL else {
            return .filePlaceholder(filename: draft.filename, byteSize: draft.byteSize)
        }
        guard let image = UIImage(contentsOfFile: snapshotURL.path) else {
            return .unavailable
        }
        return .image(image)
    }

    private func previewMediaForCapturedDraft(
        _ draft: AttachmentDraft,
        localFileURL: URL
    ) -> ChatAttachmentPreviewMedia {
        switch draft.mediaKind {
        case .image, .animatedImage:
            guard let image = UIImage(contentsOfFile: localFileURL.path) else {
                return .unavailable
            }

            return .image(image)
        case .video:
            let thumbnail = draft.thumbnailFileURL.flatMap { UIImage(contentsOfFile: $0.path) }
            return .video(thumbnail: thumbnail, playerItem: AVPlayerItem(url: localFileURL))
        case .audio, .file, .location, .contact:
            return .filePlaceholder(filename: draft.filename, byteSize: draft.byteSize)
        }
    }

    private func previewMediaForPreparedFileDraft(
        _ draft: AttachmentDraft,
        localFileURL: URL
    ) -> ChatAttachmentPreviewMedia {
        switch draft.mediaKind {
        case .image:
            guard let image = UIImage(contentsOfFile: localFileURL.path) else {
                return .unavailable
            }
            return .image(image)
        case .video:
            return .video(thumbnail: draft.thumbnailFileURL.flatMap { UIImage(contentsOfFile: $0.path) }, playerItem: AVPlayerItem(url: localFileURL))
        case .animatedImage, .audio, .file, .location, .contact:
            return .filePlaceholder(filename: draft.filename, byteSize: draft.byteSize)
        }
    }

    private func requestPhotoKitMedia(
        for draft: AttachmentDraft,
        assetLocalIdentifier: String,
        targetSize: CGSize,
        completion: @escaping (ChatAttachmentPreviewMedia) -> Void
    ) -> Int {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetLocalIdentifier], options: nil).firstObject else {
            completion(.unavailable)
            return Int(PHInvalidImageRequestID)
        }

        switch draft.mediaKind {
        case .image, .animatedImage:
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            return Int(
                imageManager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        return
                    }

                    completion(image.map(ChatAttachmentPreviewMedia.image) ?? .unavailable)
                }
            )
        case .video:
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = false
            return Int(
                imageManager.requestPlayerItem(
                    forVideo: asset,
                    options: options
                ) { playerItem, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        return
                    }

                    completion(.video(thumbnail: nil, playerItem: playerItem))
                }
            )
        case .audio, .file, .location, .contact:
            completion(.filePlaceholder(filename: draft.filename, byteSize: draft.byteSize))
            return Int(PHInvalidImageRequestID)
        }
    }
}

final class AVPlayerChatAttachmentPreviewVideoPresenter: ChatAttachmentPreviewVideoPresenting {
    func presentVideo(playerItem: AVPlayerItem, from viewController: UIViewController) {
        let player = AVPlayer(playerItem: playerItem)
        let controller = AVPlayerViewController()
        controller.player = player

        viewController.present(controller, animated: true) {
            player.play()
        }
    }
}

extension AttachmentDraft {
    var capturedLocalFileURL: URL? {
        AttachmentCapturedDraft.url(from: id)
    }

    var thumbnailFileURL: URL? {
        guard case .available(let key) = thumbnailState,
              let url = URL(string: key),
              url.isFileURL else {
            return nil
        }

        return url
    }
}
