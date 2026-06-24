import AVFoundation
import UniformTypeIdentifiers
import UIKit

enum ChatAttachmentDocumentPickerResult {
    case picked([URL])
    case cancelled
}

protocol ChatAttachmentDocumentPickerPresenting: AnyObject {
    func presentDocumentPicker(
        from viewController: UIViewController,
        contentTypes: [UTType],
        allowsMultipleSelection: Bool,
        completion: @escaping (ChatAttachmentDocumentPickerResult) -> Void
    )
}

final class UIDocumentChatAttachmentDocumentPickerPresenter: NSObject,
    ChatAttachmentDocumentPickerPresenting,
    UIDocumentPickerDelegate {
    private var completion: ((ChatAttachmentDocumentPickerResult) -> Void)?

    func presentDocumentPicker(
        from viewController: UIViewController,
        contentTypes: [UTType],
        allowsMultipleSelection: Bool,
        completion: @escaping (ChatAttachmentDocumentPickerResult) -> Void
    ) {
        self.completion = completion

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = self
        viewController.present(picker, animated: true)
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        complete(.picked(urls))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        complete(.cancelled)
    }

    private func complete(_ result: ChatAttachmentDocumentPickerResult) {
        completion?(result)
        completion = nil
    }
}

protocol ChatAttachmentSecurityScopedResourceAccessing: AnyObject {
    func startAccessingSecurityScopedResource(for url: URL) -> Bool
    func stopAccessingSecurityScopedResource(for url: URL)
}

final class ChatAttachmentSecurityScopedResourceAccessor: ChatAttachmentSecurityScopedResourceAccessing {
    func startAccessingSecurityScopedResource(for url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessingSecurityScopedResource(for url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

enum ChatAttachmentFileDraftBuilderError: Error, Equatable {
    case unreadableFile
    case emptyFile
    case oversizedFile(maximumSize: Int)
    case invalidFilename
    case unableToCreateOutputDirectory
    case unableToCopyFile
}

protocol ChatAttachmentFileDraftBuilding: AnyObject {
    func makeDraft(from url: URL) throws -> AttachmentDraft
    func removeTemporaryFiles(for draft: AttachmentDraft)
}

final class ChatAttachmentFileDraftBuilder: ChatAttachmentFileDraftBuilding {
    private let outputDirectory: URL
    private let maximumFileSize: Int?
    private let uuidProvider: () -> UUID
    private let fileManager: FileManager
    private let securityScopedResourceAccessor: ChatAttachmentSecurityScopedResourceAccessing

    init(
        outputDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xabber-chat-attachment-files-\(UUID().uuidString)", isDirectory: true),
        maximumFileSize: Int? = nil,
        uuidProvider: @escaping () -> UUID = UUID.init,
        fileManager: FileManager = .default,
        securityScopedResourceAccessor: ChatAttachmentSecurityScopedResourceAccessing = ChatAttachmentSecurityScopedResourceAccessor()
    ) {
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.maximumFileSize = maximumFileSize
        self.uuidProvider = uuidProvider
        self.fileManager = fileManager
        self.securityScopedResourceAccessor = securityScopedResourceAccessor
    }

    func makeDraft(from url: URL) throws -> AttachmentDraft {
        let sourceURL = url.standardizedFileURL
        let didStartAccessing = securityScopedResourceAccessor
            .startAccessingSecurityScopedResource(for: sourceURL)
        defer {
            if didStartAccessing {
                securityScopedResourceAccessor.stopAccessingSecurityScopedResource(for: sourceURL)
            }
        }

        guard fileManager.isReadableFile(atPath: sourceURL.path) || didStartAccessing else {
            throw ChatAttachmentFileDraftBuilderError.unreadableFile
        }

        let filename = sourceURL.lastPathComponent
        guard !filename.isEmpty else {
            throw ChatAttachmentFileDraftBuilderError.invalidFilename
        }

        let byteSize = try fileByteSize(sourceURL)
        guard byteSize > 0 else {
            throw ChatAttachmentFileDraftBuilderError.emptyFile
        }

        if let maximumFileSize,
           byteSize > maximumFileSize {
            throw ChatAttachmentFileDraftBuilderError.oversizedFile(maximumSize: maximumFileSize)
        }

        let importedURL = try copyFileToTemporaryDirectory(sourceURL, filename: filename)
        let mediaType = Self.mediaType(for: sourceURL)
        let mediaKind = Self.mediaKind(for: mediaType)
        let dimensions = Self.dimensions(for: importedURL, mediaKind: mediaKind)
        let duration = Self.duration(for: importedURL, mediaKind: mediaKind)

        let preparedFile = AttachmentPreparedFile(
            localFileURL: importedURL,
            referenceURL: sourceURL,
            filename: filename,
            byteSize: byteSize,
            mediaType: mediaType,
            dimensions: dimensions,
            duration: duration,
            videoPreviewKey: nil,
            videoOrientation: nil,
            videoDurationLabel: duration.map(Self.durationLabel),
            videoPreviewLocalURL: nil,
            temporaryData: nil
        )

        return AttachmentDraft(
            id: AttachmentFileDraft(url: sourceURL).id,
            source: .file,
            mediaKind: mediaKind,
            thumbnailState: mediaKind == .image ? .available(key: importedURL.absoluteString) : .none,
            filename: filename,
            byteSize: byteSize,
            duration: duration,
            dimensions: dimensions,
            preparationState: .prepared(preparedFile)
        )
    }

    func removeTemporaryFiles(for draft: AttachmentDraft) {
        guard case .prepared(let file) = draft.preparationState,
              isOwnedTemporaryFile(file.localFileURL) else {
            return
        }

        try? fileManager.removeItem(at: file.localFileURL)
    }

    private func fileByteSize(_ url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let number = attributes[.size] as? NSNumber {
            return number.intValue
        }

        return 0
    }

    private func copyFileToTemporaryDirectory(_ sourceURL: URL, filename: String) throws -> URL {
        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            throw ChatAttachmentFileDraftBuilderError.unableToCreateOutputDirectory
        }

        let destinationURL = outputDirectory
            .appendingPathComponent("\(uuidProvider().uuidString)-\(sanitizedFilename(filename))")
            .standardizedFileURL

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            throw ChatAttachmentFileDraftBuilderError.unableToCopyFile
        }
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let forbiddenCharacters = CharacterSet(charactersIn: "/:")
        let scalars = filename.unicodeScalars.map { scalar in
            forbiddenCharacters.contains(scalar) ? "-" : String(scalar)
        }
        let sanitized = scalars.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "file" : sanitized
    }

    private func isOwnedTemporaryFile(_ url: URL) -> Bool {
        let directoryPath = outputDirectory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        return filePath == directoryPath || filePath.hasPrefix(directoryPath + "/")
    }

    private static func mediaType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }

        return MimeType(url: url).value
    }

    private static func mediaKind(for mediaType: String) -> AttachmentMediaKind {
        if mediaType == "image/gif" {
            return .animatedImage
        }

        switch MimeIcon(mediaType).value {
        case .image:
            return .image
        case .video:
            return .video
        case .audio:
            return .audio
        case .document, .pdf, .table, .presentation, .archive, .file, .avatar:
            return .file
        }
    }

    private static func dimensions(
        for url: URL,
        mediaKind: AttachmentMediaKind
    ) -> CGSize? {
        switch mediaKind {
        case .image, .animatedImage:
            return UIImage(contentsOfFile: url.path)?.size
        case .video:
            let asset = AVAsset(url: url)
            guard let track = asset.tracks(withMediaType: .video).first else {
                return nil
            }
            let size = track.naturalSize.applying(track.preferredTransform)
            return CGSize(width: abs(size.width), height: abs(size.height))
        case .audio, .file:
            return nil
        }
    }

    private static func duration(
        for url: URL,
        mediaKind: AttachmentMediaKind
    ) -> Int? {
        guard mediaKind == .video || mediaKind == .audio else {
            return nil
        }

        let seconds = CMTimeGetSeconds(AVAsset(url: url).duration)
        guard seconds.isFinite, seconds > 0 else {
            return nil
        }

        return Int(seconds.rounded())
    }

    private static func durationLabel(for duration: Int) -> String {
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        let seconds = duration % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum ChatAttachmentFileImportFailure: Equatable {
    case unreadableFile
    case emptyFile
    case oversizedFile(maximumSize: Int)
    case unableToPrepare
    case maximumSelectionCountReached

    init(error: Error) {
        switch error as? ChatAttachmentFileDraftBuilderError {
        case .unreadableFile:
            self = .unreadableFile
        case .emptyFile:
            self = .emptyFile
        case .oversizedFile(let maximumSize):
            self = .oversizedFile(maximumSize: maximumSize)
        case .invalidFilename, .unableToCreateOutputDirectory, .unableToCopyFile, nil:
            self = .unableToPrepare
        }
    }

    var message: String {
        switch self {
        case .unreadableFile:
            return "Selected file is unavailable. Please choose it again.".localizeString(id: "media_picker_error_unavailable", arguments: [])
        case .emptyFile, .unableToPrepare:
            return "Selected file could not be prepared. Please choose it again.".localizeString(id: "media_picker_error_prepare_failed", arguments: [])
        case .oversizedFile(let maximumSize):
            return "File is too large. Maximum size is \(AccountQuotaStorageItem.beautify(size: maximumSize)).".localizeString(id: "media_picker_error_file_too_large", arguments: [])
        case .maximumSelectionCountReached:
            return "You can select up to 10 items.".localizeString(id: "media_picker_error_max_selection_count", arguments: [])
        }
    }
}

final class ChatAttachmentFileSourceViewController: UIViewController,
    ChatAttachmentSourceControlling,
    ChatAttachmentDraftSelectionProviding,
    ChatAttachmentDraftSelectionMutating,
    ChatAttachmentDraftSelectionSyncing,
    UITableViewDataSource,
    UITableViewDelegate {
    let source: ChatAttachmentSource = .file
    var onSelectionCountChanged: ((Int) -> Void)?
    var onSelectedAttachmentDraftsChanged: (([AttachmentDraft]) -> Void)?

    let chooseFilesButton = UIButton(type: .system)
    let filesTableView = UITableView(frame: .zero, style: .plain)
    let emptyStateLabel = UILabel()
    let errorMessageLabel = UILabel()

    private let documentPickerPresenter: ChatAttachmentDocumentPickerPresenting
    private let fileDraftBuilder: ChatAttachmentFileDraftBuilding
    private let maximumSelectedDraftCount: Int
    private(set) var selectedDrafts: [AttachmentDraft] = []
    private(set) var lastImportFailures: [ChatAttachmentFileImportFailure] = []
    private(set) var isImportingDocuments = false

    var viewController: UIViewController {
        self
    }

    var selectedAttachmentDrafts: [AttachmentDraft] {
        selectedDrafts
    }

    private var fileDrafts: [AttachmentDraft] {
        selectedDrafts.filter { $0.source == .file }
    }

    init(
        documentPickerPresenter: ChatAttachmentDocumentPickerPresenting = UIDocumentChatAttachmentDocumentPickerPresenter(),
        fileDraftBuilder: ChatAttachmentFileDraftBuilding = ChatAttachmentFileDraftBuilder(),
        maximumSelectedDraftCount: Int = 10
    ) {
        self.documentPickerPresenter = documentPickerPresenter
        self.fileDraftBuilder = fileDraftBuilder
        self.maximumSelectedDraftCount = maximumSelectedDraftCount
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .systemBackground

        chooseFilesButton.translatesAutoresizingMaskIntoConstraints = false
        chooseFilesButton.accessibilityIdentifier = "chatAttachmentFile.chooseFilesButton"
        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.title = ChatAttachmentLocalization.string(.fileChooseFilesAction)
        buttonConfiguration.image = UIImage(systemName: "doc.badge.plus")
        buttonConfiguration.imagePadding = 8
        buttonConfiguration.cornerStyle = .capsule
        chooseFilesButton.configuration = buttonConfiguration
        chooseFilesButton.accessibilityLabel = ChatAttachmentLocalization.string(.fileChooseFilesAction)
        chooseFilesButton.addTarget(self, action: #selector(chooseFilesButtonTapped), for: .touchUpInside)

        errorMessageLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        errorMessageLabel.textColor = .systemRed
        errorMessageLabel.numberOfLines = 0
        errorMessageLabel.textAlignment = .center
        errorMessageLabel.adjustsFontForContentSizeCategory = true
        errorMessageLabel.translatesAutoresizingMaskIntoConstraints = false
        errorMessageLabel.accessibilityIdentifier = "chatAttachmentFile.errorMessage"
        errorMessageLabel.isHidden = true

        emptyStateLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        emptyStateLabel.textColor = .secondaryLabel
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.text = ChatAttachmentLocalization.string(.fileNoFilesSelected)
        emptyStateLabel.adjustsFontForContentSizeCategory = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.accessibilityIdentifier = "chatAttachmentFile.emptyState"

        filesTableView.dataSource = self
        filesTableView.delegate = self
        filesTableView.tableFooterView = UIView()
        filesTableView.translatesAutoresizingMaskIntoConstraints = false
        filesTableView.accessibilityIdentifier = "chatAttachmentFile.list"

        rootView.addSubview(chooseFilesButton)
        rootView.addSubview(errorMessageLabel)
        rootView.addSubview(emptyStateLabel)
        rootView.addSubview(filesTableView)

        NSLayoutConstraint.activate([
            chooseFilesButton.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 12),
            chooseFilesButton.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 16),
            chooseFilesButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -16),
            chooseFilesButton.heightAnchor.constraint(equalToConstant: 44),

            errorMessageLabel.topAnchor.constraint(equalTo: chooseFilesButton.bottomAnchor, constant: 8),
            errorMessageLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 16),
            errorMessageLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -16),

            filesTableView.topAnchor.constraint(equalTo: errorMessageLabel.bottomAnchor, constant: 8),
            filesTableView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            filesTableView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            filesTableView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: 24),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -24),
            emptyStateLabel.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: rootView.centerYAnchor)
        ])

        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        renderState()
    }

    deinit {
        cleanupFileDrafts(selectedDrafts)
    }

    func syncSelectedAttachmentDrafts(_ drafts: [AttachmentDraft]) {
        guard drafts != selectedDrafts else {
            return
        }

        let previousDrafts = selectedDrafts
        selectedDrafts = drafts
        cleanupFileDrafts(removedFrom: previousDrafts, now: drafts)
        renderState()
    }

    @discardableResult
    func removeSelectedAttachmentDraft(withID draftID: String) -> [AttachmentDraft] {
        let previousDrafts = selectedDrafts
        selectedDrafts.removeAll { $0.id == draftID }

        guard selectedDrafts != previousDrafts else {
            return selectedDrafts
        }

        cleanupFileDrafts(removedFrom: previousDrafts, now: selectedDrafts)
        renderState()
        notifySelectionChanged()
        return selectedDrafts
    }

    @discardableResult
    func replaceSelectedAttachmentDraft(withID draftID: String, updatedDraft: AttachmentDraft) -> [AttachmentDraft] {
        let previousDrafts = selectedDrafts
        guard let index = selectedDrafts.firstIndex(where: { $0.id == draftID }) else {
            return selectedDrafts
        }

        selectedDrafts[index] = updatedDraft
        cleanupFileDrafts(removedFrom: previousDrafts, now: selectedDrafts)
        renderState()
        notifySelectionChanged()
        return selectedDrafts
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        fileDrafts.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ChatAttachmentFileCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "ChatAttachmentFileCell")
        let draft = fileDrafts[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = draft.filename
        content.secondaryText = AccountQuotaStorageItem.beautify(size: draft.byteSize)
        content.image = UIImage(systemName: iconName(for: draft))
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "chatAttachmentFile.cell.\(indexPath.row)"
        cell.accessibilityLabel = [draft.filename, AccountQuotaStorageItem.beautify(size: draft.byteSize)]
            .joined(separator: ", ")
        return cell
    }

    func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete,
              fileDrafts.indices.contains(indexPath.row) else {
            return
        }

        removeSelectedAttachmentDraft(withID: fileDrafts[indexPath.row].id)
    }

    @objc
    private func chooseFilesButtonTapped() {
        isImportingDocuments = true
        lastImportFailures = []
        renderState()
        documentPickerPresenter.presentDocumentPicker(
            from: self,
            contentTypes: [.item],
            allowsMultipleSelection: true
        ) { [weak self] result in
            guard let self else {
                return
            }

            self.isImportingDocuments = false
            self.handleDocumentPickerResult(result)
        }
    }

    private func handleDocumentPickerResult(_ result: ChatAttachmentDocumentPickerResult) {
        switch result {
        case .cancelled:
            renderState()
        case .picked(let urls):
            appendPickedDocuments(urls)
        }
    }

    private func appendPickedDocuments(_ urls: [URL]) {
        guard !urls.isEmpty else {
            return
        }

        var drafts = selectedDrafts
        var failures: [ChatAttachmentFileImportFailure] = []

        for url in urls {
            guard drafts.count < maximumSelectedDraftCount else {
                failures.append(.maximumSelectionCountReached)
                continue
            }

            let draft: AttachmentDraft
            do {
                draft = try fileDraftBuilder.makeDraft(from: url)
            } catch {
                failures.append(ChatAttachmentFileImportFailure(error: error))
                continue
            }

            guard !drafts.contains(where: { $0.id == draft.id }) else {
                fileDraftBuilder.removeTemporaryFiles(for: draft)
                continue
            }

            drafts.append(draft)
        }

        lastImportFailures = failures

        guard drafts != selectedDrafts else {
            renderState()
            return
        }

        selectedDrafts = drafts
        renderState()
        notifySelectionChanged()
    }

    private func notifySelectionChanged() {
        onSelectionCountChanged?(selectedDrafts.count)
        onSelectedAttachmentDraftsChanged?(selectedDrafts)
    }

    private func renderState() {
        guard isViewLoaded else {
            return
        }

        filesTableView.reloadData()
        emptyStateLabel.isHidden = !fileDrafts.isEmpty
        chooseFilesButton.isEnabled = !isImportingDocuments

        if isImportingDocuments {
            errorMessageLabel.textColor = .secondaryLabel
            errorMessageLabel.text = ChatAttachmentLocalization.string(.fileLoadingFiles)
            errorMessageLabel.isHidden = false
            return
        }

        if let failure = lastImportFailures.first {
            errorMessageLabel.textColor = .systemRed
            errorMessageLabel.text = failure.message
            errorMessageLabel.isHidden = false
        } else {
            errorMessageLabel.text = nil
            errorMessageLabel.isHidden = true
        }
    }

    private func cleanupFileDrafts(
        removedFrom previousDrafts: [AttachmentDraft],
        now currentDrafts: [AttachmentDraft]
    ) {
        let currentIDs = Set(currentDrafts.map(\.id))
        previousDrafts
            .filter { draft in
                draft.source == .file && !currentIDs.contains(draft.id)
            }
            .forEach { fileDraftBuilder.removeTemporaryFiles(for: $0) }
    }

    private func cleanupFileDrafts(_ drafts: [AttachmentDraft]) {
        drafts
            .filter { $0.source == .file }
            .forEach { fileDraftBuilder.removeTemporaryFiles(for: $0) }
    }

    private func iconName(for draft: AttachmentDraft) -> String {
        switch draft.mediaKind {
        case .image, .animatedImage:
            return "photo"
        case .video:
            return "film"
        case .audio:
            return "waveform"
        case .file:
            return "doc"
        }
    }
}

enum ChatAttachmentFileUploadLimitProvider {
    static func maxUploadFileSize(owner: String) -> Int? {
        if let manager = AccountManager.shared.find(for: owner)?.cloudStorage {
            _ = manager.isAvailable()
            if let maxFileSize = manager.maxFileSize, maxFileSize > 0 {
                return maxFileSize
            }
        }

        guard let rawValue = SettingManager.shared.getKey(for: owner, scope: .xabberUploadManager, key: "max_file_size"),
              let value = Int(rawValue),
              value > 0 else {
            return nil
        }

        return value
    }
}

extension AttachmentFileDraft {
    static func url(from id: String) -> URL? {
        let prefix = "file:"
        guard id.hasPrefix(prefix) else {
            return nil
        }

        let urlString = String(id.dropFirst(prefix.count))
        return URL(string: urlString)?.standardizedFileURL
    }
}

extension AttachmentDraft {
    var fileOriginalURL: URL? {
        AttachmentFileDraft.url(from: id)
    }
}
