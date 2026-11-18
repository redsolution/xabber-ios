import AVFoundation
import ImageIO
import QuickLook
import SwiftOGG
import UIKit

struct ScheduledMessageDisplayContent {
    let body: String
    let attachments: [ScheduledMessageAttachmentPresentation]
    private let references: [MessageReferenceStorageItem]

    init(item: ScheduledMessageListItem) {
        let content = ScheduledMessageContent.read(item)
        body = content?.body ?? item.bodyPreview
        attachments = content?.attachments.map { ScheduledMessageAttachmentPresentation(reference: $0.reference) } ?? []
        references = content?.references ?? []
    }

    func attributedBody(font: UIFont, color: UIColor, mentionColor: UIColor) -> NSAttributedString {
        let rendered = ChatAttributedBodyFormatter.format(
            body: body,
            references: references.compactMap { reference in
                guard reference.kind == .markup || reference.kind == .mention else { return nil }
                return ChatAttributedBodyReference(storageReference: reference, mentionColor: mentionColor)
            },
            attributes: [.font: font, .foregroundColor: color]
        )
        let preview = NSMutableAttributedString(attributedString: rendered)
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { destination, range, _ in
            guard destination != nil else { return }
            preview.addAttribute(.foregroundColor, value: mentionColor, range: range)
        }
        return preview
    }
}

struct ScheduledMessageAttachmentPresentation: Equatable {
    enum Kind: Equatable {
        case image, video, audio, voice, file

        var symbol: String {
            switch self {
            case .image: return "photo"
            case .video: return "play.rectangle"
            case .audio, .voice: return "waveform"
            case .file: return "doc"
            }
        }
    }

    let kind: Kind
    let title: String
    let subtitle: String?
    let url: URL?
    private let inlineThumbnail: String?

    init(reference: MessageReferenceStorageItem) {
        let metadata = reference.metadata
        let mediaType = (metadata?["media-type"] as? String ?? reference.mimeType).lowercased()
        let source = reference.downloadUrl ?? MessageReferenceURLPolicy.url(from: reference.fileSharingURI)
        let descriptor = ChatEncryptedAttachmentDescriptor(
            metadata: metadata, url: source, owner: reference.owner, referenceIdentity: reference.primary
        )
        if let source, ["http", "https"].contains(source.scheme?.lowercased() ?? ""),
           source.host?.isEmpty == false, source.user == nil, source.password == nil, source.fragment == nil,
           descriptor.state == .plaintext {
            url = source
        } else {
            url = nil
        }
        switch (reference.kind, mediaType.split(separator: "/").first) {
        case (.voice, _): kind = .voice
        case (_, "image"): kind = .image
        case (_, "video"): kind = .video
        case (_, "audio"): kind = .audio
        default: kind = .file
        }
        let name = [reference.filename, reference.name, url?.lastPathComponent]
            .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if kind == .voice {
            title = L10n.text("chat_list__attachment_preview__voice_message", fallback: "Voice message")
        } else {
            title = name ?? L10n.text("scheduled_message_attachment", fallback: "Attachment")
        }
        if let duration = reference.duration, duration > 0, kind == .voice || kind == .audio {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.minute, .second]
            formatter.unitsStyle = .positional
            formatter.zeroFormattingBehavior = .pad
            subtitle = formatter.string(from: TimeInterval(duration))
        } else {
            subtitle = reference.sizeInBytes
        }

        let inlineURI = metadata?["thumbnail-uri"] as? String
        let data = inlineURI.flatMap { value -> String? in
            guard value.hasPrefix("data:image/"), let separator = value.firstIndex(of: ",") else { return nil }
            return String(value[value.index(after: separator)...])
        }
        inlineThumbnail = descriptor.state == .plaintext ? (reference.pendingMediaAttachment?.verySmallThumb ?? data) : nil
    }

    func previewButton(action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.subtitle = subtitle
        configuration.image = thumbnail() ?? UIImage(systemName: kind.symbol)
        configuration.imagePadding = 9
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0)
        configuration.titleLineBreakMode = .byTruncatingTail
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.contentHorizontalAlignment = .leading
        button.accessibilityLabel = title
        button.accessibilityValue = subtitle
        button.accessibilityIdentifier = "chat.schedule.attachment.preview"
        button.isEnabled = url != nil
        let height = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        height.priority = .defaultHigh
        height.isActive = true
        return button
    }

    private func thumbnail() -> UIImage? {
        guard let inlineThumbnail, inlineThumbnail.utf8.count <= 64 * 1024,
              let data = Data(base64Encoded: inlineThumbnail),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64
              ] as CFDictionary) else { return nil }
        let scale = max(1, CGFloat(max(image.width, image.height)) / 32)
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }
}

struct ScheduledMessageEditDraft {
    struct Attachment: Identifiable, Equatable {
        enum ID: Hashable {
            case retained(Int)
            case added(UUID)
        }

        let id: ID
        let presentation: ScheduledMessageAttachmentPresentation
        let xml: String?
    }

    private let originalBody: String
    private let originalIDs: [Attachment.ID]
    var body: String
    private(set) var attachments: [Attachment]

    init(content: ScheduledMessageContent) {
        originalBody = content.body
        body = content.body
        attachments = content.attachments.map {
            Attachment(id: .retained($0.id), presentation: ScheduledMessageAttachmentPresentation(reference: $0.reference), xml: nil)
        }
        originalIDs = attachments.map(\.id)
    }

    var canSave: Bool {
        let changed = body != originalBody || attachments.map(\.id) != originalIDs
        return changed && (!body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var action: ScheduledMessageAction {
        .editContent(
            body: body,
            retainedAttachmentIDs: attachments.compactMap {
                if case .retained(let id) = $0.id { return id }
                return nil
            },
            addedAttachmentXML: attachments.compactMap(\.xml)
        )
    }

    mutating func remove(_ id: Attachment.ID) {
        attachments.removeAll { $0.id == id }
    }

    mutating func add(_ references: [MessageReferenceStorageItem], replacing id: Attachment.ID?) -> Bool {
        guard !references.isEmpty,
              let xml = ScheduledMessageContent.attachmentXML(references),
              xml.count == references.count else { return false }
        if let id { remove(id) }
        attachments.append(contentsOf: zip(references, xml).map { reference, serialized in
            Attachment(id: .added(UUID()), presentation: ScheduledMessageAttachmentPresentation(reference: reference), xml: serialized)
        })
        return true
    }
}

@MainActor
final class ScheduledAttachmentPreviewCoordinator: NSObject, QLPreviewControllerDataSource {
    private var task: Task<Void, Never>?
    private var previewURL: URL?

    func open(
        _ attachment: ScheduledMessageAttachmentPresentation,
        owner: String,
        from presenter: UIViewController,
        canPresent: @escaping () -> Bool
    ) {
        guard let url = attachment.url, task == nil, canPresent() else { return }
        task = Task { [weak self, weak presenter] in
            guard let self, let presenter else { return }
            let router = PrivacyProxyMediaRouter.shared
            do {
                let file: URL
                if attachment.kind == .image {
                    file = try await router.downloadImage(url, owner: owner)
                } else {
                    file = try await router.download(url, owner: owner)
                }
                let preview: URL
                if attachment.kind == .voice && ["ogg", "opus"].contains(file.pathExtension.lowercased()) {
                    preview = try await Task.detached(priority: .userInitiated) {
                        let audio = file.deletingLastPathComponent().appendingPathComponent("voice.m4a")
                        try OGGConverter.convertOpusOGGToM4aFile(src: file, dest: audio)
                        return audio
                    }.value
                } else {
                    preview = file
                }
                guard !Task.isCancelled else { return }
                task = nil
                guard canPresent(), presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { return }
                present(preview, kind: attachment.kind, from: presenter)
            } catch PrivacyProxyMediaRouter.RoutingError.imageConsentRequired {
                guard !Task.isCancelled else { return }
                task = nil
                guard canPresent(), let view = presenter.viewIfLoaded else { return }
                ExternalImageConsent.present(for: url, owner: owner, from: view, shouldGrant: canPresent) { [weak self, weak presenter] in
                    guard let presenter else { return }
                    self?.open(attachment, owner: owner, from: presenter, canPresent: canPresent)
                }
            } catch {
                guard !Task.isCancelled else { return }
                task = nil
                if canPresent() { presentUnavailable(from: presenter) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func present(_ url: URL, kind: ScheduledMessageAttachmentPresentation.Kind, from presenter: UIViewController) {
        switch kind {
        case .video, .audio, .voice:
            AVPlayerChatAttachmentPreviewVideoPresenter().presentVideo(playerItem: AVPlayerItem(url: url), from: presenter)
        case .image, .file:
            guard QLPreviewController.canPreview(url as NSURL) else {
                presentUnavailable(from: presenter)
                return
            }
            previewURL = url
            let controller = QLPreviewController()
            controller.dataSource = self
            presenter.present(controller, animated: true)
        }
    }

    private func presentUnavailable(from presenter: UIViewController) {
        guard let view = presenter.viewIfLoaded, view.window != nil else { return }
        view.makeToast(L10n.text("chat_attachment_status_file_transfer_unavailable_title", fallback: "File transfer unavailable"))
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        previewURL.map { $0 as NSURL } ?? NSURL()
    }
}


@MainActor
final class ScheduledMessageEditViewController: UIViewController, UITextViewDelegate, @preconcurrency ChatAttachmentFlowCoordinatorDelegate {
    private let input = UITextView()
    private let attachmentList = UIStackView()
    private let statusLabel = UILabel()
    private let addButton = UIButton(type: .system)
    private let preview = ScheduledAttachmentPreviewCoordinator()
    private let item: ScheduledMessageListItem
    private let display: ScheduledMessageDisplayContent
    private let onSave: (ScheduledMessageEditDraft, @escaping (Result<Void, ScheduledMessageActionFailure>) -> Void) -> Void
    private let errorText: (ScheduledMessageActionFailure) -> String
    private var draft: ScheduledMessageEditDraft
    private var attachmentPicker: ChatAttachmentFlowCoordinator?
    private var saving = false

    init(
        item: ScheduledMessageListItem,
        display: ScheduledMessageDisplayContent,
        draft: ScheduledMessageEditDraft,
        errorText: @escaping (ScheduledMessageActionFailure) -> String,
        onSave: @escaping (ScheduledMessageEditDraft, @escaping (Result<Void, ScheduledMessageActionFailure>) -> Void) -> Void
    ) {
        self.item = item
        self.display = display
        self.draft = draft
        self.errorText = errorText
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.text("common__action__edit", fallback: "Edit")
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .save,
            primaryAction: UIAction { [weak self] _ in self?.save() }
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "chat.schedule.edit.save"

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        let stack = UIStackView(arrangedSubviews: [input, attachmentList, addButton, statusLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            input.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            addButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])

        input.font = .preferredFont(forTextStyle: .body)
        input.adjustsFontForContentSizeCategory = true
        input.isScrollEnabled = false
        if draft.body == display.body {
            input.attributedText = display.attributedBody(font: .preferredFont(forTextStyle: .body), color: .label, mentionColor: view.tintColor)
        } else {
            input.text = draft.body
        }
        input.accessibilityLabel = L10n.text("scheduled_message_edit_body", fallback: "Message text")
        input.accessibilityIdentifier = "chat.schedule.edit.body"
        input.delegate = self

        attachmentList.axis = .vertical
        attachmentList.spacing = 3
        var configuration = UIButton.Configuration.gray()
        configuration.image = UIImage(systemName: "plus")
        configuration.imagePadding = 6
        configuration.title = L10n.text("scheduled_message_add_attachments", fallback: "Add Attachments")
        addButton.configuration = configuration
        addButton.accessibilityIdentifier = "chat.schedule.edit.add-attachments"
        addButton.addAction(UIAction { [weak self] _ in self?.pickAttachments() }, for: .touchUpInside)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityIdentifier = "chat.schedule.edit.status"
        statusLabel.isHidden = true
        renderAttachments()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        preview.cancel()
    }

    func textViewDidChange(_ textView: UITextView) {
        draft.body = textView.text ?? ""
        refreshControls()
    }

    private func renderAttachments() {
        attachmentList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for attachment in draft.attachments {
            let file = attachment.presentation.previewButton { [weak self] in
                guard let self else { return }
                preview.open(attachment.presentation, owner: item.owner, from: self) { [weak self] in
                    guard let self else { return false }
                    return !saving && draft.attachments.contains { $0.id == attachment.id }
                }
            }
            let more = UIButton(type: .system)
            more.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
            more.accessibilityIdentifier = "chat.schedule.edit.attachment.actions"
            let replace = L10n.text("scheduled_message_replace_attachment", fallback: "Replace Attachment")
            let remove = L10n.text("chat_attachment_action_remove", fallback: "Remove")
            more.accessibilityLabel = attachment.presentation.title
            more.menu = UIMenu(children: [
                UIAction(title: replace, image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    self?.pickAttachments(replacing: attachment.id)
                },
                UIAction(title: remove, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.remove(attachment.id)
                }
            ])
            more.showsMenuAsPrimaryAction = true
            more.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            let row = UIStackView(arrangedSubviews: [file, more])
            row.spacing = 8
            attachmentList.addArrangedSubview(row)
        }
        attachmentList.isHidden = draft.attachments.isEmpty
        refreshControls()
    }

    private func remove(_ id: ScheduledMessageEditDraft.Attachment.ID) {
        guard !saving else { return }
        draft.remove(id)
        renderAttachments()
    }

    private func pickAttachments(replacing id: ScheduledMessageEditDraft.Attachment.ID? = nil) {
        guard !saving, attachmentPicker == nil else { return }
        view.endEditing(true)
        let context = ChatAttachmentFlowContext(
            owner: item.owner, jid: item.conversation, conversationType: item.conversationType, forwardedMessageIds: []
        )
        let coordinator = ChatAttachmentFlowCoordinator(
            presentingViewController: self,
            context: context,
            scheduledMode: .addToScheduledMessage { [weak self] references in
                guard let self else { return }
                attachmentPicker = nil
                if draft.add(references, replacing: id) {
                    showStatus(nil)
                } else {
                    showStatus(L10n.text("chat_attachment_status_file_transfer_unavailable_title", fallback: "File transfer unavailable"))
                }
                renderAttachments()
            }
        )
        coordinator.delegate = self
        attachmentPicker = coordinator
        refreshControls()
        coordinator.start()
    }

    private func save() {
        guard !saving, draft.canSave else { return }
        saving = true
        view.endEditing(true)
        refreshControls()
        showStatus(L10n.text("scheduled_messages_working", fallback: "Updating scheduled messages…"))
        onSave(draft) { [weak self] result in
            guard let self else { return }
            saving = false
            refreshControls()
            switch result {
            case .success:
                dismiss(animated: true)
            case .failure(let failure) where failure.recovery != nil:
                dismiss(animated: true)
            case .failure(let failure):
                showStatus(errorText(failure))
            }
        }
    }

    private func refreshControls() {
        navigationItem.leftBarButtonItem?.isEnabled = !saving
        navigationItem.rightBarButtonItem?.isEnabled = draft.canSave && !saving && attachmentPicker == nil
        input.isEditable = !saving
        attachmentList.isUserInteractionEnabled = !saving
        addButton.isEnabled = !saving && attachmentPicker == nil
    }

    private func showStatus(_ text: String?) {
        statusLabel.text = text
        statusLabel.isHidden = text == nil
    }

    func chatAttachmentFlowCoordinatorDidSend(_ coordinator: ChatAttachmentFlowCoordinator) {}

    func chatAttachmentFlowCoordinatorDidDismiss(_ coordinator: ChatAttachmentFlowCoordinator) {
        guard attachmentPicker === coordinator else { return }
        attachmentPicker = nil
        refreshControls()
    }

    func chatAttachmentFlowCoordinator(
        _ coordinator: ChatAttachmentFlowCoordinator,
        didRequestPremiumFor owner: String
    ) {}

    func chatAttachmentFlowCoordinator(_ coordinator: ChatAttachmentFlowCoordinator, didFailWith error: ChatAttachmentFlowError) {
        guard attachmentPicker === coordinator, error == .missingPresenter || error == .presentationFailed else { return }
        attachmentPicker = nil
        showStatus(L10n.text("chat_attachment_status_file_transfer_unavailable_title", fallback: "File transfer unavailable"))
        refreshControls()
    }
}
