import UIKit

enum ChatAttachmentLocalizationKey: String, CaseIterable {
    case sourceGalleryTitle = "chat_attachment_source_gallery"
    case sourceFileTitle = "chat_attachment_source_file"
    case sourceLocationTitle = "chat_attachment_source_location"
    case sourceContactTitle = "chat_attachment_source_contact"
    case sourceGalleryAccessibilityLabel = "chat_attachment_source_gallery_accessibility"
    case sourceFileAccessibilityLabel = "chat_attachment_source_file_accessibility"
    case sourceLocationAccessibilityLabel = "chat_attachment_source_location_accessibility"
    case sourceContactAccessibilityLabel = "chat_attachment_source_contact_accessibility"
    case accessibilitySelected = "chat_attachment_accessibility_selected"
    case accessibilityUnavailable = "chat_attachment_accessibility_unavailable"
    case accessibilityNotSelected = "chat_attachment_accessibility_not_selected"
    case accessibilitySelectedOrder = "chat_attachment_accessibility_selected_order"
    case accessibilitySelectionLimitReached = "chat_attachment_accessibility_selection_limit_reached"
    case actionRetry = "chat_attachment_action_retry"
    case actionRemove = "chat_attachment_action_remove"
    case actionCancel = "chat_attachment_action_cancel"
    case actionDone = "chat_attachment_action_done"
    case actionBack = "chat_attachment_action_back"
    case actionSend = "chat_attachment_action_send"
    case actionResetSelection = "chat_attachment_action_reset_selection"
    case actionSelected = "chat_attachment_action_selected"
    case actionEdit = "chat_attachment_action_edit"
    case actionOK = "chat_attachment_action_ok"
    case editorRotateAction = "chat_attachment_editor_rotate"
    case captionPlaceholder = "chat_attachment_caption_placeholder"
    case captionAccessibilityLabel = "chat_attachment_caption_accessibility_label"
    case previewOneItem = "chat_attachment_preview_one_item"
    case previewMultipleItems = "chat_attachment_preview_multiple_items"
    case previewLoading = "chat_attachment_preview_loading"
    case previewUnavailable = "chat_attachment_preview_unavailable"
    case previewVideoAccessibilityLabel = "chat_attachment_preview_video_accessibility"
    case previewPlayVideo = "chat_attachment_preview_play_video"
    case previewDurationSeconds = "chat_attachment_preview_duration_seconds"
    case editUnavailableTitle = "chat_attachment_edit_unavailable_title"
    case editUnavailableMessage = "chat_attachment_edit_unavailable_message"
    case statusPreparingAttachmentTitle = "chat_attachment_status_preparing_attachment_title"
    case statusPendingAttachmentMessage = "chat_attachment_status_pending_attachment_message"
    case statusPreparingAttachmentMessage = "chat_attachment_status_preparing_attachment_message"
    case statusAttachmentUnavailableTitle = "chat_attachment_status_attachment_unavailable_title"
    case statusPhotosAccessChangedMessage = "chat_attachment_status_photos_access_changed_message"
    case statusAssetUnavailableMessage = "chat_attachment_status_asset_unavailable_message"
    case statusICloudDownloadFailedMessage = "chat_attachment_status_icloud_download_failed_message"
    case statusUnreadableFileMessage = "chat_attachment_status_unreadable_file_message"
    case statusUnsupportedMetadataMessage = "chat_attachment_status_unsupported_metadata_message"
    case statusOversizedFileMessage = "chat_attachment_status_oversized_file_message"
    case statusPreparationFailedMessage = "chat_attachment_status_preparation_failed_message"
    case statusAttentionNeededTitle = "chat_attachment_status_attention_needed_title"
    case statusRemoveOrRetryOneMessage = "chat_attachment_status_remove_or_retry_one_message"
    case statusRemoveOrRetryManyMessage = "chat_attachment_status_remove_or_retry_many_message"
    case statusPreparingAttachmentsTitle = "chat_attachment_status_preparing_attachments_title"
    case statusReadyCountMessage = "chat_attachment_status_ready_count_message"
    case statusNoAttachmentsTitle = "chat_attachment_status_no_attachments_title"
    case statusNoAttachmentsMessage = "chat_attachment_status_no_attachments_message"
    case statusAttachmentsNotReadyTitle = "chat_attachment_status_attachments_not_ready_title"
    case statusAttachmentsNotReadyMessage = "chat_attachment_status_attachments_not_ready_message"
    case statusFileTransferUnavailableTitle = "chat_attachment_status_file_transfer_unavailable_title"
    case statusFileTransferUnavailableMessage = "chat_attachment_status_file_transfer_unavailable_message"
    case statusCannotPrepareTitle = "chat_attachment_status_cannot_prepare_title"
    case statusCannotPrepareMessage = "chat_attachment_status_cannot_prepare_message"
    case statusAccountUnavailableTitle = "chat_attachment_status_account_unavailable_title"
    case statusAccountUnavailableMessage = "chat_attachment_status_account_unavailable_message"
    case statusSendFailedTitle = "chat_attachment_status_send_failed_title"
    case statusSendFailedMessage = "chat_attachment_status_send_failed_message"
    case cloudStorageQuotaExceededTitle = "chat_attachment_cloud_storage_quota_exceeded_title"
    case cloudStorageQuotaExceededMessage = "chat_attachment_cloud_storage_quota_exceeded_message"
    case cloudStorageQuotaExceededOpenAction = "chat_attachment_cloud_storage_quota_exceeded_open_action"
    case galleryCameraAccessibilityLabel = "chat_attachment_gallery_camera_accessibility"
    case galleryCameraUnavailableAccessibilityLabel = "chat_attachment_gallery_camera_unavailable_accessibility"
    case galleryLoadingPhotoAccessibilityLabel = "chat_attachment_gallery_loading_photo_accessibility"
    case galleryPhotoAccessibilityLabel = "chat_attachment_gallery_photo_accessibility"
    case galleryPhotoICloudAccessibilityLabel = "chat_attachment_gallery_photo_icloud_accessibility"
    case galleryPhotoUnavailableAccessibilityLabel = "chat_attachment_gallery_photo_unavailable_accessibility"
    case galleryNoPhotosVideos = "chat_attachment_gallery_no_photos_videos"
    case photosAllowAccessAction = "chat_attachment_photos_allow_access_action"
    case photosManageAction = "chat_attachment_photos_manage_action"
    case photosOpenSettingsAction = "chat_attachment_photos_open_settings_action"
    case photosRequestAccessMessage = "chat_attachment_photos_request_access_message"
    case photosLimitedAccessMessage = "chat_attachment_photos_limited_access_message"
    case photosDeniedMessage = "chat_attachment_photos_denied_message"
    case photosUnavailableMessage = "chat_attachment_photos_unavailable_message"
    case galleryCollapseAction = "chat_attachment_gallery_collapse_action"
    case galleryDismissAction = "chat_attachment_gallery_dismiss_action"
    case galleryManagePhotosAccessibility = "chat_attachment_gallery_manage_photos_accessibility"
    case galleryRecentsTitle = "chat_attachment_gallery_recents_title"
    case fileChooseFilesAction = "chat_attachment_file_choose_files_action"
    case fileNoFilesSelected = "chat_attachment_file_no_files_selected"
    case fileLoadingFiles = "chat_attachment_file_loading_files"
    case geolocationAllowAccessAction = "chat_attachment_geolocation_allow_access_action"
    case geolocationDeniedMessage = "chat_attachment_geolocation_denied_message"
    case geolocationRestrictedMessage = "chat_attachment_geolocation_restricted_message"
    case geolocationUnavailableMessage = "chat_attachment_geolocation_unavailable_message"

    var defaultValue: String {
        switch self {
        case .sourceGalleryTitle: return "Gallery"
        case .sourceFileTitle: return "File"
        case .sourceLocationTitle: return "Location"
        case .sourceContactTitle: return "Contacts"
        case .sourceGalleryAccessibilityLabel: return "Gallery attachments"
        case .sourceFileAccessibilityLabel: return "File attachments"
        case .sourceLocationAccessibilityLabel: return "Location attachment"
        case .sourceContactAccessibilityLabel: return "Contacts attachments"
        case .accessibilitySelected: return "Selected"
        case .accessibilityUnavailable: return "Unavailable"
        case .accessibilityNotSelected: return "Not selected"
        case .accessibilitySelectedOrder: return "Selected %@"
        case .accessibilitySelectionLimitReached: return "Selection limit reached"
        case .actionRetry: return "Retry"
        case .actionRemove: return "Remove"
        case .actionCancel: return "Cancel"
        case .actionDone: return "Done"
        case .actionBack: return "Back"
        case .actionSend: return "Send"
        case .actionResetSelection: return "Clear selection"
        case .actionSelected: return "Selected"
        case .actionEdit: return "Edit"
        case .actionOK: return "OK"
        case .editorRotateAction: return "Rotate"
        case .captionPlaceholder: return "Add a caption"
        case .captionAccessibilityLabel: return "Caption"
        case .previewOneItem: return "Preview 1 item"
        case .previewMultipleItems: return "Preview %@ items"
        case .previewLoading: return "Loading"
        case .previewUnavailable: return "Unavailable"
        case .previewVideoAccessibilityLabel: return "Video %@"
        case .previewPlayVideo: return "Play video"
        case .previewDurationSeconds: return "%@ seconds"
        case .editUnavailableTitle: return "Cannot Edit Image"
        case .editUnavailableMessage: return "This image is not available for editing."
        case .statusPreparingAttachmentTitle: return "Preparing attachment"
        case .statusPendingAttachmentMessage: return "This item is not ready yet."
        case .statusPreparingAttachmentMessage: return "This item is being prepared."
        case .statusAttachmentUnavailableTitle: return "Attachment unavailable"
        case .statusPhotosAccessChangedMessage: return "Photo access changed. Retry or remove this item."
        case .statusAssetUnavailableMessage: return "This item is no longer available."
        case .statusICloudDownloadFailedMessage: return "iCloud download failed. Retry when the item is available."
        case .statusUnreadableFileMessage: return "The file cannot be read. Choose it again or remove it."
        case .statusUnsupportedMetadataMessage: return "This attachment metadata is unsupported."
        case .statusOversizedFileMessage: return "This attachment is too large."
        case .statusPreparationFailedMessage: return "Preparation failed. Retry or remove this item."
        case .statusAttentionNeededTitle: return "Some attachments need attention"
        case .statusRemoveOrRetryOneMessage: return "Remove or retry the unavailable item before sending."
        case .statusRemoveOrRetryManyMessage: return "Remove or retry unavailable items before sending."
        case .statusPreparingAttachmentsTitle: return "Preparing attachments"
        case .statusReadyCountMessage: return "%@ of %@ ready."
        case .statusNoAttachmentsTitle: return "No attachments selected"
        case .statusNoAttachmentsMessage: return "Select at least one attachment before sending."
        case .statusAttachmentsNotReadyTitle: return "Attachments not ready"
        case .statusAttachmentsNotReadyMessage: return "Some attachments are not ready yet. Remove unavailable items or retry preparation."
        case .statusFileTransferUnavailableTitle: return "File transfer unavailable"
        case .statusFileTransferUnavailableMessage: return "File transfer is unavailable for this account."
        case .statusCannotPrepareTitle: return "Cannot prepare attachments"
        case .statusCannotPrepareMessage: return "Refresh the selection or remove failed items."
        case .statusAccountUnavailableTitle: return "Account unavailable"
        case .statusAccountUnavailableMessage: return "Reconnect the account before sending attachments."
        case .statusSendFailedTitle: return "Send failed"
        case .statusSendFailedMessage: return "The message could not be sent. Try again."
        case .cloudStorageQuotaExceededTitle: return "Cloud Storage is full"
        case .cloudStorageQuotaExceededMessage: return "There is not enough space in Cloud Storage to send these attachments. Open Cloud Storage to free up space."
        case .cloudStorageQuotaExceededOpenAction: return "Open Cloud Storage"
        case .galleryCameraAccessibilityLabel: return "Camera"
        case .galleryCameraUnavailableAccessibilityLabel: return "Camera unavailable"
        case .galleryLoadingPhotoAccessibilityLabel: return "Loading photo"
        case .galleryPhotoAccessibilityLabel: return "Photo"
        case .galleryPhotoICloudAccessibilityLabel: return "Photo in iCloud"
        case .galleryPhotoUnavailableAccessibilityLabel: return "Photo unavailable"
        case .galleryNoPhotosVideos: return "No photos or videos"
        case .photosAllowAccessAction: return "Allow Photo Access"
        case .photosManageAction: return "Manage Photos..."
        case .photosOpenSettingsAction: return "Open Settings"
        case .photosRequestAccessMessage: return "Allow Photos access to choose images and videos."
        case .photosLimitedAccessMessage: return "Limited Photos access is enabled."
        case .photosDeniedMessage: return "Photo Library access is required to select images."
        case .photosUnavailableMessage: return "Photo Library access is unavailable."
        case .galleryCollapseAction: return "Collapse"
        case .galleryDismissAction: return "Dismiss"
        case .galleryManagePhotosAccessibility: return "Manage Photos"
        case .galleryRecentsTitle: return "Recents"
        case .fileChooseFilesAction: return "Choose Files"
        case .fileNoFilesSelected: return "No files selected"
        case .fileLoadingFiles: return "Loading files..."
        case .geolocationAllowAccessAction: return "Allow Location Access"
        case .geolocationDeniedMessage: return "Location access is denied."
        case .geolocationRestrictedMessage: return "Location access is restricted."
        case .geolocationUnavailableMessage: return "Location is unavailable."
        }
    }
}

enum ChatAttachmentLocalization {
    static let requiredKeys = ChatAttachmentLocalizationKey.allCases.map(\.rawValue)

    static func string(_ key: ChatAttachmentLocalizationKey, arguments: [String] = []) -> String {
        key.defaultValue.localizeString(id: key.rawValue, arguments: arguments)
    }
}

enum ChatAttachmentSourceAvailability: Equatable {
    case available
    case disabled
    case hidden
}

struct ChatAttachmentSourceBarConfiguration: Equatable {
    static let `default` = ChatAttachmentSourceBarConfiguration()

    let sourceAvailability: [ChatAttachmentSource: ChatAttachmentSourceAvailability]
    let orderedSources: [ChatAttachmentSource]

    init(
        sourceAvailability: [ChatAttachmentSource: ChatAttachmentSourceAvailability] = [
            .gallery: .available,
            .file: .available,
            .geolocation: .disabled,
            .contact: .disabled
        ],
        orderedSources: [ChatAttachmentSource] = [.gallery, .file, .geolocation, .contact]
    ) {
        self.sourceAvailability = sourceAvailability
        self.orderedSources = orderedSources
    }

    func availability(for source: ChatAttachmentSource) -> ChatAttachmentSourceAvailability {
        sourceAvailability[source] ?? .hidden
    }

    func isSelectable(_ source: ChatAttachmentSource) -> Bool {
        availability(for: source) == .available
    }

    var visibleSources: [ChatAttachmentSource] {
        orderedSources.filter { availability(for: $0) != .hidden }
    }
}

protocol ChatAttachmentSourceBarViewDelegate: AnyObject {
    func chatAttachmentSourceBarView(_ view: ChatAttachmentSourceBarView, didSelect source: ChatAttachmentSource)
    func chatAttachmentSourceBarViewDidRequestDismiss(_ view: ChatAttachmentSourceBarView)
}

extension ChatAttachmentSourceBarViewDelegate {
    func chatAttachmentSourceBarViewDidRequestDismiss(_ view: ChatAttachmentSourceBarView) {}
}

final class ChatAttachmentSourceBarView: UIView {
    weak var delegate: ChatAttachmentSourceBarViewDelegate?

    let sourceSurfaceView = UIVisualEffectView()
    let dismissButton = UIButton(type: .system)
    private let stackView = UIStackView()
    private var buttonsBySource: [ChatAttachmentSource: ChatAttachmentSourceButton] = [:]
    private var configuration: ChatAttachmentSourceBarConfiguration = .default
    private(set) var selectedSource: ChatAttachmentSource = .gallery

    var selectedTintColor: UIColor = .systemBlue {
        didSet {
            buttonsBySource.values.forEach(updateButtonState)
        }
    }

    var visibleSources: [ChatAttachmentSource] {
        configuration.visibleSources
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    func configure(
        configuration: ChatAttachmentSourceBarConfiguration,
        selectedSource: ChatAttachmentSource
    ) {
        self.configuration = configuration
        self.selectedSource = selectedSource
        rebuildButtons()
    }

    func setSelectedSource(_ source: ChatAttachmentSource) {
        selectedSource = source
        buttonsBySource.values.forEach(updateButtonState)
    }

    func button(for source: ChatAttachmentSource) -> UIButton? {
        buttonsBySource[source]
    }

    private func setupView() {
        backgroundColor = .clear
        isOpaque = false
        translatesAutoresizingMaskIntoConstraints = false

        sourceSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        sourceSurfaceView.isUserInteractionEnabled = true
        sourceSurfaceView.contentView.isUserInteractionEnabled = true
        NativeGlassBarStyle.applySurface(to: sourceSurfaceView, cornerStyle: .capsule, interactive: true)

        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.distribution = .fillEqually
        stackView.spacing = 0
        stackView.layoutMargins = UIEdgeInsets(
            top: 0,
            left: NativeGlassBarStyle.contentInset,
            bottom: 0,
            right: NativeGlassBarStyle.contentInset
        )
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.translatesAutoresizingMaskIntoConstraints = false

        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.accessibilityIdentifier = "chatAttachmentSheet.sourceBar.dismissButton"
        dismissButton.accessibilityLabel = ChatAttachmentLocalization.string(.galleryDismissAction)
        dismissButton.addTarget(self, action: #selector(dismissButtonTapped), for: .touchUpInside)
        NativeGlassBarStyle.applyDetachedIconButtonStyle(
            to: dismissButton,
            tintColor: .label,
            image: UIImage(systemName: "chevron.down")?
                .upscale(dimension: NativeGlassBarStyle.iconSize)
                .withRenderingMode(.alwaysTemplate)
        )

        addSubview(sourceSurfaceView)
        addSubview(dismissButton)
        sourceSurfaceView.contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            dismissButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: NativeGlassBarStyle.buttonSize),
            dismissButton.heightAnchor.constraint(equalToConstant: NativeGlassBarStyle.buttonSize),

            sourceSurfaceView.leadingAnchor.constraint(
                equalTo: dismissButton.trailingAnchor,
                constant: NativeGlassBarStyle.interItemSpacing
            ),
            sourceSurfaceView.topAnchor.constraint(equalTo: topAnchor),
            sourceSurfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),
            sourceSurfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),

            stackView.topAnchor.constraint(equalTo: sourceSurfaceView.contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: sourceSurfaceView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: sourceSurfaceView.contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: sourceSurfaceView.contentView.bottomAnchor)
        ])
    }

    private func rebuildButtons() {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        buttonsBySource.removeAll()

        configuration.visibleSources.forEach { source in
            let button = ChatAttachmentSourceButton(source: source)
            button.addTarget(self, action: #selector(sourceButtonTapped(_:)), for: .touchUpInside)
            button.accessibilityIdentifier = "chatAttachmentSheet.sourceBar.\(source.accessibilityIdentifierSuffix)"
            button.accessibilityLabel = source.sourceBarAccessibilityLabel
            button.isEnabled = configuration.isSelectable(source)
            button.isSelected = source == selectedSource
            configureButtonContent(button)
            updateButtonState(button)
            buttonsBySource[source] = button
            stackView.addArrangedSubview(button)
        }
    }

    private func configureButtonContent(_ button: ChatAttachmentSourceButton) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: button.source.sourceBarSystemImageName)?
            .upscale(dimension: NativeGlassBarStyle.iconSize)
            .withRenderingMode(.alwaysTemplate)
        configuration.title = nil
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        button.configuration = configuration
        button.setTitle(nil, for: .normal)
        button.setTitle(nil, for: .highlighted)
        button.setTitle(nil, for: .disabled)
        button.backgroundColor = .clear
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
    }

    private func updateButtonState(_ button: ChatAttachmentSourceButton) {
        button.isSelected = button.source == selectedSource

        var configuration = button.configuration ?? UIButton.Configuration.plain()
        if button.isEnabled {
            configuration.baseForegroundColor = button.isSelected ? selectedTintColor : .secondaryLabel
        } else {
            configuration.baseForegroundColor = .tertiaryLabel
        }
        configuration.background.backgroundColor = .clear
        button.configuration = configuration
        button.tintColor = configuration.baseForegroundColor

        var traits: UIAccessibilityTraits = [.button]
        if button.isSelected {
            traits.insert(.selected)
        }
        if !button.isEnabled {
            traits.insert(.notEnabled)
        }
        button.accessibilityTraits = traits
        if !button.isEnabled {
            button.accessibilityValue = ChatAttachmentLocalization.string(.accessibilityUnavailable)
        } else if button.isSelected {
            button.accessibilityValue = ChatAttachmentLocalization.string(.accessibilitySelected)
        } else {
            button.accessibilityValue = ChatAttachmentLocalization.string(.accessibilityNotSelected)
        }
    }

    @objc
    private func sourceButtonTapped(_ sender: ChatAttachmentSourceButton) {
        guard sender.isEnabled,
              configuration.isSelectable(sender.source) else {
            return
        }

        delegate?.chatAttachmentSourceBarView(self, didSelect: sender.source)
    }

    @objc
    private func dismissButtonTapped() {
        delegate?.chatAttachmentSourceBarViewDidRequestDismiss(self)
    }
}

private final class ChatAttachmentSourceButton: UIButton {
    let source: ChatAttachmentSource

    init(source: ChatAttachmentSource) {
        self.source = source
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private extension ChatAttachmentSource {
    var sourceBarTitle: String {
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

    var sourceBarAccessibilityLabel: String {
        switch self {
        case .gallery:
            return ChatAttachmentLocalization.string(.sourceGalleryAccessibilityLabel)
        case .file:
            return ChatAttachmentLocalization.string(.sourceFileAccessibilityLabel)
        case .geolocation:
            return ChatAttachmentLocalization.string(.sourceLocationAccessibilityLabel)
        case .contact:
            return ChatAttachmentLocalization.string(.sourceContactAccessibilityLabel)
        }
    }

    var sourceBarSystemImageName: String {
        switch self {
        case .gallery:
            return "photo.on.rectangle"
        case .file:
            return "doc"
        case .geolocation:
            return "location"
        case .contact:
            return "person.2"
        }
    }

    var accessibilityIdentifierSuffix: String {
        switch self {
        case .gallery:
            return "gallery"
        case .file:
            return "file"
        case .geolocation:
            return "geolocation"
        case .contact:
            return "contact"
        }
    }
}
