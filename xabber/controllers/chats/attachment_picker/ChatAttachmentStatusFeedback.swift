import UIKit

enum ChatAttachmentStatusKind: Equatable {
    case hidden
    case pending
    case preparing
    case ready
    case unavailable
    case blocked
    case blocking
    case attentionRequired
    case retryableFailure
}

struct ChatAttachmentStatusBannerViewModel: Equatable {
    let kind: ChatAttachmentStatusKind
    let title: String
    let message: String
    let progress: Float?
    let blockedItemCount: Int
    let showsRetryAction: Bool
    let showsRemoveAction: Bool
    let blocksSend: Bool

    static let hidden = ChatAttachmentStatusBannerViewModel(
        kind: .hidden,
        title: "",
        message: "",
        progress: nil,
        blockedItemCount: 0,
        showsRetryAction: false,
        showsRemoveAction: false,
        blocksSend: false
    )
}

enum ChatAttachmentDraftStatusPolicy {
    static func viewModel(for draft: AttachmentDraft) -> ChatAttachmentStatusBannerViewModel {
        switch draft.preparationState {
        case .pending:
            return ChatAttachmentStatusBannerViewModel(
                kind: .pending,
                title: ChatAttachmentLocalization.string(.statusPreparingAttachmentTitle),
                message: ChatAttachmentLocalization.string(.statusPendingAttachmentMessage),
                progress: nil,
                blockedItemCount: 0,
                showsRetryAction: false,
                showsRemoveAction: false,
                blocksSend: true
            )
        case .preparing:
            return ChatAttachmentStatusBannerViewModel(
                kind: .preparing,
                title: ChatAttachmentLocalization.string(.statusPreparingAttachmentTitle),
                message: ChatAttachmentLocalization.string(.statusPreparingAttachmentMessage),
                progress: nil,
                blockedItemCount: 0,
                showsRetryAction: false,
                showsRemoveAction: false,
                blocksSend: true
            )
        case .prepared:
            return ChatAttachmentStatusBannerViewModel(
                kind: .ready,
                title: "",
                message: "",
                progress: nil,
                blockedItemCount: 0,
                showsRetryAction: false,
                showsRemoveAction: false,
                blocksSend: false
            )
        case .unavailable(let reason):
            return ChatAttachmentStatusBannerViewModel(
                kind: .unavailable,
                title: ChatAttachmentLocalization.string(.statusAttachmentUnavailableTitle),
                message: message(for: reason),
                progress: nil,
                blockedItemCount: 1,
                showsRetryAction: true,
                showsRemoveAction: true,
                blocksSend: true
            )
        }
    }

    private static func message(for reason: AttachmentDraftUnavailableReason) -> String {
        switch reason {
        case .photosAccessLost:
            return ChatAttachmentLocalization.string(.statusPhotosAccessChangedMessage)
        case .assetUnavailable:
            return ChatAttachmentLocalization.string(.statusAssetUnavailableMessage)
        case .iCloudDownloadFailed:
            return ChatAttachmentLocalization.string(.statusICloudDownloadFailedMessage)
        case .unreadableFile:
            return ChatAttachmentLocalization.string(.statusUnreadableFileMessage)
        case .unsupportedMetadata:
            return ChatAttachmentLocalization.string(.statusUnsupportedMetadataMessage)
        case .oversizedFile:
            return ChatAttachmentLocalization.string(.statusOversizedFileMessage)
        case .preparationFailed:
            return ChatAttachmentLocalization.string(.statusPreparationFailedMessage)
        }
    }
}

enum ChatAttachmentBatchStatusPolicy {
    static func viewModel(for drafts: [AttachmentDraft]) -> ChatAttachmentStatusBannerViewModel {
        guard !drafts.isEmpty else {
            return .hidden
        }

        let unavailableCount = drafts.filter { draft in
            if case .unavailable = draft.preparationState {
                return true
            }
            return false
        }.count

        if unavailableCount > 0 {
            return ChatAttachmentStatusBannerViewModel(
                kind: .blocked,
                title: ChatAttachmentLocalization.string(.statusAttentionNeededTitle),
                message: unavailableCount == 1
                    ? ChatAttachmentLocalization.string(.statusRemoveOrRetryOneMessage)
                    : ChatAttachmentLocalization.string(.statusRemoveOrRetryManyMessage),
                progress: nil,
                blockedItemCount: unavailableCount,
                showsRetryAction: false,
                showsRemoveAction: false,
                blocksSend: true
            )
        }

        let preparedCount = drafts.filter { draft in
            if case .prepared = draft.preparationState {
                return true
            }
            return false
        }.count

        if preparedCount == drafts.count {
            return ChatAttachmentStatusBannerViewModel(
                kind: .ready,
                title: "",
                message: "",
                progress: nil,
                blockedItemCount: 0,
                showsRetryAction: false,
                showsRemoveAction: false,
                blocksSend: false
            )
        }

        return ChatAttachmentStatusBannerViewModel(
            kind: .preparing,
            title: ChatAttachmentLocalization.string(.statusPreparingAttachmentsTitle),
            message: ChatAttachmentLocalization.string(
                .statusReadyCountMessage,
                arguments: ["\(preparedCount)", "\(drafts.count)"]
            ),
            progress: Float(preparedCount) / Float(drafts.count),
            blockedItemCount: 0,
            showsRetryAction: false,
            showsRemoveAction: false,
            blocksSend: true
        )
    }
}

enum ChatAttachmentSendFeedbackPolicy {
    static func viewModel(for reason: ChatAttachmentSendBlockReason) -> ChatAttachmentStatusBannerViewModel {
        switch reason {
        case .emptySelection:
            return ChatAttachmentStatusBannerViewModel(
                kind: .attentionRequired,
                title: ChatAttachmentLocalization.string(.statusNoAttachmentsTitle),
                message: ChatAttachmentLocalization.string(.statusNoAttachmentsMessage),
                progress: nil,
                blockedItemCount: 0,
                showsRetryAction: false,
                showsRemoveAction: false,
                blocksSend: true
            )
        case .unpreparedDrafts:
            return ChatAttachmentStatusBannerViewModel(
                kind: .attentionRequired,
                title: ChatAttachmentLocalization.string(.statusAttachmentsNotReadyTitle),
                message: ChatAttachmentLocalization.string(.statusAttachmentsNotReadyMessage),
                progress: nil,
                blockedItemCount: 0,
                showsRetryAction: false,
                showsRemoveAction: false,
                blocksSend: true
            )
        case .cloudStorageUnavailable:
            return ChatAttachmentStatusBannerViewModel(
                kind: .blocking,
                title: ChatAttachmentLocalization.string(.statusFileTransferUnavailableTitle),
                message: ChatAttachmentLocalization.string(.statusFileTransferUnavailableMessage),
                progress: nil,
                blockedItemCount: 0,
                showsRetryAction: false,
                showsRemoveAction: false,
                blocksSend: true
            )
        case .referenceBuildFailed:
            return ChatAttachmentStatusBannerViewModel(
                kind: .retryableFailure,
                title: ChatAttachmentLocalization.string(.statusCannotPrepareTitle),
                message: ChatAttachmentLocalization.string(.statusCannotPrepareMessage),
                progress: nil,
                blockedItemCount: 0,
                showsRetryAction: true,
                showsRemoveAction: false,
                blocksSend: true
            )
        case .accountUnavailable:
            return ChatAttachmentStatusBannerViewModel(
                kind: .blocking,
                title: ChatAttachmentLocalization.string(.statusAccountUnavailableTitle),
                message: ChatAttachmentLocalization.string(.statusAccountUnavailableMessage),
                progress: nil,
                blockedItemCount: 0,
                showsRetryAction: false,
                showsRemoveAction: false,
                blocksSend: true
            )
        case .sendFailed:
            return ChatAttachmentStatusBannerViewModel(
                kind: .retryableFailure,
                title: ChatAttachmentLocalization.string(.statusSendFailedTitle),
                message: ChatAttachmentLocalization.string(.statusSendFailedMessage),
                progress: nil,
                blockedItemCount: 0,
                showsRetryAction: true,
                showsRemoveAction: false,
                blocksSend: true
            )
        }
    }
}

enum ChatAttachmentDraftRetryPolicy {
    static func retryDraft(_ draft: AttachmentDraft) -> AttachmentDraft {
        guard case .unavailable = draft.preparationState else {
            return draft
        }

        var retryDraft = draft
        retryDraft.preparationState = .pending
        return retryDraft
    }
}

final class ChatAttachmentStatusBannerView: UIView {
    let titleLabel = UILabel()
    let messageLabel = UILabel()
    let retryButton = UIButton(type: .system)
    let removeButton = UIButton(type: .system)
    let progressView = UIProgressView(progressViewStyle: .default)

    var onRetryTapped: (() -> Void)?
    var onRemoveTapped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
        apply(.hidden)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ viewModel: ChatAttachmentStatusBannerViewModel) {
        isHidden = viewModel.kind == .hidden || viewModel.kind == .ready
        titleLabel.text = viewModel.title
        messageLabel.text = viewModel.message
        retryButton.isHidden = !viewModel.showsRetryAction
        removeButton.isHidden = !viewModel.showsRemoveAction

        if let progress = viewModel.progress {
            progressView.progress = progress
            progressView.isHidden = false
            progressView.accessibilityValue = viewModel.message
        } else {
            progressView.progress = 0
            progressView.isHidden = true
            progressView.accessibilityValue = nil
        }

        accessibilityLabel = [viewModel.title, viewModel.message]
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    private func setupView() {
        backgroundColor = UIColor.secondarySystemBackground
        layer.cornerRadius = 8
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "chatAttachment.statusBanner"

        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.accessibilityIdentifier = "chatAttachment.statusBanner.title"

        messageLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 2
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.accessibilityIdentifier = "chatAttachment.statusBanner.message"

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.accessibilityIdentifier = "chatAttachment.statusBanner.progress"

        configureActionButton(
            retryButton,
            title: ChatAttachmentLocalization.string(.actionRetry),
            accessibilityIdentifier: "chatAttachment.statusBanner.retryButton"
        )
        configureActionButton(
            removeButton,
            title: ChatAttachmentLocalization.string(.actionRemove),
            accessibilityIdentifier: "chatAttachment.statusBanner.removeButton"
        )
        retryButton.addTarget(self, action: #selector(retryButtonTapped), for: .touchUpInside)
        removeButton.addTarget(self, action: #selector(removeButtonTapped), for: .touchUpInside)

        let actionsStack = UIStackView(arrangedSubviews: [retryButton, removeButton])
        actionsStack.axis = .horizontal
        actionsStack.spacing = 8
        actionsStack.alignment = .center
        actionsStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(messageLabel)
        addSubview(progressView)
        addSubview(actionsStack)

        let progressBottomConstraint = progressView.bottomAnchor.constraint(lessThanOrEqualTo: layoutMarginsGuide.bottomAnchor)
        progressBottomConstraint.priority = .defaultLow
        let messageBottomConstraint = messageLabel.bottomAnchor.constraint(lessThanOrEqualTo: layoutMarginsGuide.bottomAnchor)
        messageBottomConstraint.priority = .defaultLow

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionsStack.leadingAnchor, constant: -8),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            messageLabel.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),

            progressView.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 6),
            progressView.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            progressBottomConstraint,

            actionsStack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            actionsStack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            actionsStack.heightAnchor.constraint(equalToConstant: 30),
            messageBottomConstraint
        ])
    }

    private func configureActionButton(
        _ button: UIButton,
        title: String,
        accessibilityIdentifier: String
    ) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        button.configuration = configuration
        button.accessibilityIdentifier = accessibilityIdentifier
        button.accessibilityLabel = title
    }

    @objc
    private func retryButtonTapped() {
        onRetryTapped?()
    }

    @objc
    private func removeButtonTapped() {
        onRemoveTapped?()
    }
}
