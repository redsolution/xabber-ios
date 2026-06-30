import AVFoundation
import Photos
import UniformTypeIdentifiers
import UIKit

enum ChatAttachmentMediaPreparationError: Error, Equatable {
    case cancelled
    case assetUnavailable
    case iCloudDownloadFailed
    case unreadableFile
    case unsupportedMetadata
    case encodingFailed
    case outputWriteFailed
    case oversizedFile
    case lowMemory
}

enum ChatAttachmentMediaPreparationFailurePolicy {
    static func unavailableReason(
        for error: ChatAttachmentMediaPreparationError
    ) -> AttachmentDraftUnavailableReason {
        switch error {
        case .assetUnavailable:
            return .assetUnavailable
        case .iCloudDownloadFailed:
            return .iCloudDownloadFailed
        case .unreadableFile:
            return .unreadableFile
        case .unsupportedMetadata:
            return .unsupportedMetadata
        case .oversizedFile:
            return .oversizedFile
        case .cancelled, .encodingFailed, .outputWriteFailed, .lowMemory:
            return .preparationFailed
        }
    }
}

enum ChatAttachmentLoadedMediaContent {
    case data(Data)
    case file(URL)
}

struct ChatAttachmentLoadedMedia {
    let content: ChatAttachmentLoadedMediaContent
    let referenceURL: URL
    let filename: String
    let mediaType: String
    let mediaKind: AttachmentMediaKind
    let dimensions: CGSize?
    let duration: Int?
    let videoPreviewKey: String?
    let videoOrientation: String?
    let videoPreviewLocalURL: URL?
    let videoPreviewData: Data?

    init(
        content: ChatAttachmentLoadedMediaContent,
        referenceURL: URL,
        filename: String,
        mediaType: String,
        mediaKind: AttachmentMediaKind,
        dimensions: CGSize?,
        duration: Int?,
        videoPreviewKey: String? = nil,
        videoOrientation: String? = nil,
        videoPreviewLocalURL: URL? = nil,
        videoPreviewData: Data? = nil
    ) {
        self.content = content
        self.referenceURL = referenceURL
        self.filename = filename
        self.mediaType = mediaType
        self.mediaKind = mediaKind
        self.dimensions = dimensions
        self.duration = duration
        self.videoPreviewKey = videoPreviewKey
        self.videoOrientation = videoOrientation
        self.videoPreviewLocalURL = videoPreviewLocalURL
        self.videoPreviewData = videoPreviewData
    }
}

protocol ChatAttachmentMediaPreparationCancellable: AnyObject {
    func cancel()
}

protocol ChatAttachmentMediaPreparationLoading: AnyObject {
    @discardableResult
    func loadMedia(
        for draft: AttachmentDraft,
        completion: @escaping (Result<ChatAttachmentLoadedMedia, ChatAttachmentMediaPreparationError>) -> Void
    ) -> ChatAttachmentMediaPreparationCancellable
}

protocol ChatAttachmentMediaPreparationFileWriting: AnyObject {
    func makePreparedFile(
        from loadedMedia: ChatAttachmentLoadedMedia
    ) throws -> AttachmentPreparedFile
}

protocol ChatAttachmentMediaPreparing: AnyObject {
    @discardableResult
    func prepare(
        drafts: [AttachmentDraft],
        completion: @escaping ([AttachmentDraft]) -> Void
    ) -> ChatAttachmentMediaPreparationCancellable
}

final class ChatAttachmentMediaPreparationFileWriter: ChatAttachmentMediaPreparationFileWriting {
    private let outputDirectory: URL
    private let uuidProvider: () -> UUID
    private let fileManager: FileManager

    init(
        outputDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xabber-chat-attachment-prepared-\(UUID().uuidString)", isDirectory: true),
        uuidProvider: @escaping () -> UUID = UUID.init,
        fileManager: FileManager = .default
    ) {
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.uuidProvider = uuidProvider
        self.fileManager = fileManager
    }

    func makePreparedFile(
        from loadedMedia: ChatAttachmentLoadedMedia
    ) throws -> AttachmentPreparedFile {
        try createOutputDirectoryIfNeeded()

        let filename = sanitizedFilename(loadedMedia.filename)
        let destinationURL = outputDirectory
            .appendingPathComponent("\(uuidProvider().uuidString)-\(filename)")
            .standardizedFileURL
        let byteSize: Int

        switch loadedMedia.content {
        case .data(let data):
            guard !data.isEmpty else {
                throw ChatAttachmentMediaPreparationError.unreadableFile
            }
            do {
                try data.write(to: destinationURL, options: .atomic)
                byteSize = data.count
            } catch {
                throw ChatAttachmentMediaPreparationError.outputWriteFailed
            }
        case .file(let sourceURL):
            let sourceURL = sourceURL.standardizedFileURL
            guard fileManager.isReadableFile(atPath: sourceURL.path) else {
                throw ChatAttachmentMediaPreparationError.unreadableFile
            }
            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                byteSize = try fileByteSize(destinationURL)
            } catch let error as ChatAttachmentMediaPreparationError {
                throw error
            } catch {
                throw ChatAttachmentMediaPreparationError.outputWriteFailed
            }
        }

        let previewLocalURL = try writeVideoPreviewIfNeeded(
            loadedMedia.videoPreviewData,
            fallbackURL: loadedMedia.videoPreviewLocalURL
        )

        return AttachmentPreparedFile(
            localFileURL: destinationURL,
            referenceURL: loadedMedia.referenceURL,
            filename: filename,
            byteSize: byteSize,
            mediaType: loadedMedia.mediaType,
            dimensions: loadedMedia.dimensions,
            duration: loadedMedia.duration,
            videoPreviewKey: loadedMedia.videoPreviewKey,
            videoOrientation: loadedMedia.videoOrientation,
            videoDurationLabel: loadedMedia.duration.map(Self.durationLabel(for:)),
            videoPreviewLocalURL: previewLocalURL,
            temporaryData: nil
        )
    }

    private func createOutputDirectoryIfNeeded() throws {
        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            throw ChatAttachmentMediaPreparationError.outputWriteFailed
        }
    }

    private func fileByteSize(_ url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw ChatAttachmentMediaPreparationError.unreadableFile
        }
        return number.intValue
    }

    private func writeVideoPreviewIfNeeded(
        _ data: Data?,
        fallbackURL: URL?
    ) throws -> URL? {
        guard let data else {
            return fallbackURL
        }

        let url = outputDirectory
            .appendingPathComponent("\(uuidProvider().uuidString)-video-preview.jpg")
            .standardizedFileURL
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw ChatAttachmentMediaPreparationError.outputWriteFailed
        }
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let forbiddenCharacters = CharacterSet(charactersIn: "/:")
        let scalars = filename.unicodeScalars.map { scalar in
            forbiddenCharacters.contains(scalar) ? "-" : String(scalar)
        }
        let sanitized = scalars.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "attachment" : sanitized
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

final class ChatAttachmentMediaPreparationCoordinator: ChatAttachmentMediaPreparing {
    private let loader: ChatAttachmentMediaPreparationLoading
    private let fileWriter: ChatAttachmentMediaPreparationFileWriting
    private let processingQueue: DispatchQueue
    private let completionQueue: DispatchQueue

    init(
        loader: ChatAttachmentMediaPreparationLoading = PhotoKitChatAttachmentMediaPreparationLoader(),
        fileWriter: ChatAttachmentMediaPreparationFileWriting = ChatAttachmentMediaPreparationFileWriter(),
        processingQueue: DispatchQueue = DispatchQueue(label: "com.xabber.chatAttachment.mediaPreparation", qos: .userInitiated),
        completionQueue: DispatchQueue = .main
    ) {
        self.loader = loader
        self.fileWriter = fileWriter
        self.processingQueue = processingQueue
        self.completionQueue = completionQueue
    }

    @discardableResult
    func prepare(
        drafts: [AttachmentDraft],
        completion: @escaping ([AttachmentDraft]) -> Void
    ) -> ChatAttachmentMediaPreparationCancellable {
        let task = ChatAttachmentMediaPreparationBatchTask()
        guard !drafts.isEmpty else {
            completionQueue.async {
                guard !task.isCancelled else {
                    return
                }
                completion([])
            }
            return task
        }

        let resultQueue = DispatchQueue(label: "com.xabber.chatAttachment.mediaPreparation.results")
        var results = Array<AttachmentDraft?>(repeating: nil, count: drafts.count)
        var remainingCount = drafts.count

        func finish(index: Int, draft: AttachmentDraft) {
            resultQueue.async { [weak self] in
                guard let self,
                      !task.isCancelled else {
                    return
                }

                results[index] = draft
                remainingCount -= 1

                guard remainingCount == 0 else {
                    return
                }

                let completedDrafts = results.compactMap { $0 }
                self.completionQueue.async {
                    guard !task.isCancelled else {
                        return
                    }
                    completion(completedDrafts)
                }
            }
        }

        for (index, draft) in drafts.enumerated() {
            if case .prepared = draft.preparationState {
                finish(index: index, draft: draft)
                continue
            }

            if case .preparedLocation = draft.preparationState {
                finish(index: index, draft: draft)
                continue
            }

            var preparingDraft = draft
            preparingDraft.preparationState = .preparing

            let token = loader.loadMedia(for: preparingDraft) { [weak self] result in
                guard let self else {
                    return
                }

                self.processingQueue.async {
                    guard !task.isCancelled else {
                        return
                    }

                    let preparedDraft = self.preparedDraft(
                        from: preparingDraft,
                        result: result
                    )
                    finish(index: index, draft: preparedDraft)
                }
            }
            task.add(token)
        }

        return task
    }

    private func preparedDraft(
        from draft: AttachmentDraft,
        result: Result<ChatAttachmentLoadedMedia, ChatAttachmentMediaPreparationError>
    ) -> AttachmentDraft {
        switch result {
        case .success(let loadedMedia):
            do {
                let preparedFile = try fileWriter.makePreparedFile(from: loadedMedia)
                var preparedDraft = draft
                preparedDraft.thumbnailState = thumbnailState(
                    for: draft,
                    preparedFile: preparedFile
                )
                preparedDraft.filename = preparedFile.filename
                preparedDraft.byteSize = preparedFile.byteSize
                preparedDraft.duration = preparedFile.duration
                preparedDraft.dimensions = preparedFile.dimensions
                preparedDraft.preparationState = .prepared(preparedFile)
                return preparedDraft
            } catch let error as ChatAttachmentMediaPreparationError {
                return unavailableDraft(draft, error: error)
            } catch {
                return unavailableDraft(draft, error: .outputWriteFailed)
            }
        case .failure(let error):
            return unavailableDraft(draft, error: error)
        }
    }

    private func thumbnailState(
        for draft: AttachmentDraft,
        preparedFile: AttachmentPreparedFile
    ) -> AttachmentThumbnailState {
        switch draft.mediaKind {
        case .image, .animatedImage:
            return .available(key: preparedFile.localFileURL.absoluteString)
        case .video:
            if let previewURL = preparedFile.videoPreviewLocalURL {
                return .available(key: previewURL.absoluteString)
            }
            return draft.thumbnailState
        case .audio, .file, .location:
            return draft.thumbnailState
        }
    }

    private func unavailableDraft(
        _ draft: AttachmentDraft,
        error: ChatAttachmentMediaPreparationError
    ) -> AttachmentDraft {
        var failedDraft = draft
        failedDraft.preparationState = .unavailable(
            ChatAttachmentMediaPreparationFailurePolicy.unavailableReason(for: error)
        )
        return failedDraft
    }
}

private final class ChatAttachmentMediaPreparationBatchTask: ChatAttachmentMediaPreparationCancellable {
    private let stateQueue = DispatchQueue(label: "com.xabber.chatAttachment.mediaPreparation.cancel")
    private var tokens: [ChatAttachmentMediaPreparationCancellable] = []
    private var cancelled = false

    var isCancelled: Bool {
        stateQueue.sync { cancelled }
    }

    func add(_ token: ChatAttachmentMediaPreparationCancellable) {
        let shouldCancel = stateQueue.sync { () -> Bool in
            if cancelled {
                return true
            }

            tokens.append(token)
            return false
        }

        if shouldCancel {
            token.cancel()
        }
    }

    func cancel() {
        let tokensToCancel = stateQueue.sync { () -> [ChatAttachmentMediaPreparationCancellable] in
            guard !cancelled else {
                return []
            }

            cancelled = true
            let tokens = self.tokens
            self.tokens.removeAll()
            return tokens
        }

        tokensToCancel.forEach { $0.cancel() }
    }
}

private final class ChatAttachmentMediaPreparationNoopCancellable: ChatAttachmentMediaPreparationCancellable {
    func cancel() {}
}

private final class PhotoKitChatAttachmentMediaPreparationRequest: ChatAttachmentMediaPreparationCancellable {
    private weak var imageManager: PHImageManager?
    private let requestID: PHImageRequestID

    init(imageManager: PHImageManager, requestID: PHImageRequestID) {
        self.imageManager = imageManager
        self.requestID = requestID
    }

    func cancel() {
        guard requestID != PHInvalidImageRequestID else {
            return
        }

        imageManager?.cancelImageRequest(requestID)
    }
}

final class PhotoKitChatAttachmentMediaPreparationLoader: ChatAttachmentMediaPreparationLoading {
    private let imageManager: PHImageManager

    init(imageManager: PHImageManager = PHImageManager.default()) {
        self.imageManager = imageManager
    }

    @discardableResult
    func loadMedia(
        for draft: AttachmentDraft,
        completion: @escaping (Result<ChatAttachmentLoadedMedia, ChatAttachmentMediaPreparationError>) -> Void
    ) -> ChatAttachmentMediaPreparationCancellable {
        if let localURL = draft.editedLocalFileURL ?? draft.capturedLocalFileURL {
            completion(loadLocalPreparedMedia(for: draft, localURL: localURL))
            return ChatAttachmentMediaPreparationNoopCancellable()
        }

        if draft.source == .file,
           case .prepared(let preparedFile) = draft.preparationState {
            completion(.success(loadedMedia(from: preparedFile, mediaKind: draft.mediaKind)))
            return ChatAttachmentMediaPreparationNoopCancellable()
        }

        guard let localIdentifier = draft.galleryAssetLocalIdentifier else {
            completion(.failure(.assetUnavailable))
            return ChatAttachmentMediaPreparationNoopCancellable()
        }

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            completion(.failure(.assetUnavailable))
            return ChatAttachmentMediaPreparationNoopCancellable()
        }

        switch draft.mediaKind {
        case .image, .animatedImage:
            return requestImage(for: asset, draft: draft, completion: completion)
        case .video:
            return requestVideo(for: asset, draft: draft, completion: completion)
        case .audio, .file, .location:
            completion(.failure(.unsupportedMetadata))
            return ChatAttachmentMediaPreparationNoopCancellable()
        }
    }

    private func requestImage(
        for asset: PHAsset,
        draft: AttachmentDraft,
        completion: @escaping (Result<ChatAttachmentLoadedMedia, ChatAttachmentMediaPreparationError>) -> Void
    ) -> ChatAttachmentMediaPreparationCancellable {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true

        let requestID = imageManager.requestImageDataAndOrientation(
            for: asset,
            options: options
        ) { data, dataUTI, _, info in
            if Self.isCancelled(info) {
                completion(.failure(.cancelled))
                return
            }

            if let error = Self.error(from: info) {
                completion(.failure(error))
                return
            }

            guard let data,
                  !data.isEmpty else {
                completion(.failure(.assetUnavailable))
                return
            }

            let preparedData: Data
            let mediaType: String
            let filename: String

            if draft.mediaKind == .image,
               let image = UIImage(data: data),
               let jpegData = image.jpegData(compressionQuality: 0.9) {
                preparedData = jpegData
                mediaType = "image/jpeg"
                filename = Self.filename(from: draft.filename, fallbackExtension: "jpg")
            } else {
                preparedData = data
                mediaType = Self.mediaType(forDataUTI: dataUTI) ?? "image/gif"
                filename = Self.filename(
                    from: draft.filename,
                    fallbackExtension: mediaType == "image/gif" ? "gif" : "dat"
                )
            }

            completion(
                .success(
                    ChatAttachmentLoadedMedia(
                        content: .data(preparedData),
                        referenceURL: Self.referenceURL(for: asset),
                        filename: filename,
                        mediaType: mediaType,
                        mediaKind: draft.mediaKind,
                        dimensions: CGSize(width: CGFloat(asset.pixelWidth), height: CGFloat(asset.pixelHeight)),
                        duration: nil
                    )
                )
            )
        }

        return PhotoKitChatAttachmentMediaPreparationRequest(
            imageManager: imageManager,
            requestID: requestID
        )
    }

    private func requestVideo(
        for asset: PHAsset,
        draft: AttachmentDraft,
        completion: @escaping (Result<ChatAttachmentLoadedMedia, ChatAttachmentMediaPreparationError>) -> Void
    ) -> ChatAttachmentMediaPreparationCancellable {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        let requestID = imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
            if Self.isCancelled(info) {
                completion(.failure(.cancelled))
                return
            }

            if let error = Self.error(from: info) {
                completion(.failure(error))
                return
            }

            guard let urlAsset = avAsset as? AVURLAsset else {
                completion(.failure(.unsupportedMetadata))
                return
            }

            let metadata = Self.videoMetadata(for: urlAsset)
            completion(
                .success(
                    ChatAttachmentLoadedMedia(
                        content: .file(urlAsset.url),
                        referenceURL: Self.referenceURL(for: asset),
                        filename: Self.filename(from: draft.filename, fallbackExtension: "mov"),
                        mediaType: Self.mediaType(for: urlAsset.url),
                        mediaKind: .video,
                        dimensions: metadata.dimensions,
                        duration: metadata.duration,
                        videoPreviewKey: nil,
                        videoOrientation: metadata.orientation,
                        videoPreviewLocalURL: nil,
                        videoPreviewData: metadata.previewData
                    )
                )
            )
        }

        return PhotoKitChatAttachmentMediaPreparationRequest(
            imageManager: imageManager,
            requestID: requestID
        )
    }

    private func loadLocalPreparedMedia(
        for draft: AttachmentDraft,
        localURL: URL
    ) -> Result<ChatAttachmentLoadedMedia, ChatAttachmentMediaPreparationError> {
        guard FileManager.default.isReadableFile(atPath: localURL.path) else {
            return .failure(.unreadableFile)
        }

        return .success(
            ChatAttachmentLoadedMedia(
                content: .file(localURL),
                referenceURL: localURL,
                filename: draft.filename.isEmpty ? localURL.lastPathComponent : draft.filename,
                mediaType: Self.mediaType(for: localURL),
                mediaKind: draft.mediaKind,
                dimensions: draft.dimensions,
                duration: draft.duration,
                videoPreviewKey: nil,
                videoOrientation: nil,
                videoPreviewLocalURL: draft.thumbnailLocalURL,
                videoPreviewData: nil
            )
        )
    }

    private func loadedMedia(
        from preparedFile: AttachmentPreparedFile,
        mediaKind: AttachmentMediaKind
    ) -> ChatAttachmentLoadedMedia {
        ChatAttachmentLoadedMedia(
            content: .file(preparedFile.localFileURL),
            referenceURL: preparedFile.referenceURL,
            filename: preparedFile.filename,
            mediaType: preparedFile.mediaType,
            mediaKind: mediaKind,
            dimensions: preparedFile.dimensions,
            duration: preparedFile.duration,
            videoPreviewKey: preparedFile.videoPreviewKey,
            videoOrientation: preparedFile.videoOrientation,
            videoPreviewLocalURL: preparedFile.videoPreviewLocalURL,
            videoPreviewData: nil
        )
    }

    private static func isCancelled(_ info: [AnyHashable: Any]?) -> Bool {
        (info?[PHImageCancelledKey] as? Bool) == true
    }

    private static func error(from info: [AnyHashable: Any]?) -> ChatAttachmentMediaPreparationError? {
        if info?[PHImageErrorKey] != nil {
            return .iCloudDownloadFailed
        }

        if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
            return .iCloudDownloadFailed
        }

        return nil
    }

    private static func mediaType(forDataUTI dataUTI: String?) -> String? {
        guard let dataUTI,
              let type = UTType(dataUTI) else {
            return nil
        }

        return type.preferredMIMEType
    }

    private static func mediaType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }

        return MimeType(url: url).value
    }

    private static func filename(from draftFilename: String, fallbackExtension: String) -> String {
        let trimmed = draftFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "attachment.\(fallbackExtension)"
        }

        if URL(fileURLWithPath: trimmed).pathExtension.isEmpty {
            return "\(trimmed).\(fallbackExtension)"
        }

        return trimmed
    }

    private static func referenceURL(for asset: PHAsset) -> URL {
        URL(string: "asset://\(asset.localIdentifier)") ?? URL(fileURLWithPath: asset.localIdentifier)
    }

    private static func videoMetadata(for asset: AVURLAsset) -> (
        duration: Int?,
        dimensions: CGSize?,
        orientation: String?,
        previewData: Data?
    ) {
        let duration = duration(from: asset)
        let track = asset.tracks(withMediaType: .video).first
        let dimensions = track.map(dimensions(from:))
        let orientation = track.map(orientation(from:))
        let previewData = previewData(from: asset)
        return (duration, dimensions, orientation, previewData)
    }

    private static func duration(from asset: AVAsset) -> Int? {
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else {
            return nil
        }

        return Int(seconds.rounded())
    }

    private static func dimensions(from track: AVAssetTrack) -> CGSize {
        let size = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    private static func orientation(from track: AVAssetTrack) -> String {
        let transform = track.preferredTransform
        if transform.a == 0,
           transform.b == 1,
           transform.c == -1,
           transform.d == 0 {
            return "portrait"
        }
        if transform.a == 0,
           transform.b == -1,
           transform.c == 1,
           transform.d == 0 {
            return "portraitUpsideDown"
        }
        if transform.a == 1,
           transform.b == 0,
           transform.c == 0,
           transform.d == 1 {
            return "landscapeRight"
        }
        return "landscapeLeft"
    }

    private static func previewData(from asset: AVAsset) -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
            return nil
        }

        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.75)
    }
}

private extension AttachmentDraft {
    var thumbnailLocalURL: URL? {
        guard case .available(let key) = thumbnailState else {
            return nil
        }

        return URL(string: key)
    }
}
