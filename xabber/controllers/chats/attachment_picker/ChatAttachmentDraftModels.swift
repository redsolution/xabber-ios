import CoreGraphics
import Foundation

struct AttachmentAssetDraft: Equatable, Hashable {
    let assetLocalIdentifier: String

    var id: String {
        "asset:\(assetLocalIdentifier)"
    }
}

struct AttachmentFileDraft: Equatable, Hashable {
    let url: URL

    var id: String {
        "file:\(url.absoluteString)"
    }

    init(url: URL) {
        self.url = url.standardizedFileURL
    }
}

enum AttachmentMediaKind: Equatable {
    case image
    case animatedImage
    case video
    case audio
    case file
}

enum AttachmentThumbnailState: Equatable {
    case none
    case loading
    case available(key: String)
    case unavailable
}

enum AttachmentDraftUnavailableReason: Equatable {
    case photosAccessLost
    case assetUnavailable
    case iCloudDownloadFailed
    case unreadableFile
    case unsupportedMetadata
    case oversizedFile
    case preparationFailed
}

struct AttachmentPreparedFile: Equatable {
    let localFileURL: URL
    let referenceURL: URL
    let filename: String
    let byteSize: Int
    let mediaType: String
    let dimensions: CGSize?
    let duration: Int?
    let videoPreviewKey: String?
    let videoOrientation: String?
    let videoDurationLabel: String?
    let videoPreviewLocalURL: URL?
    let temporaryData: Data?
}

enum AttachmentPreparationState: Equatable {
    case pending
    case preparing
    case prepared(AttachmentPreparedFile)
    case unavailable(AttachmentDraftUnavailableReason)
}

struct AttachmentDraft: Equatable, Identifiable {
    let id: String
    let source: ChatAttachmentSource
    let mediaKind: AttachmentMediaKind
    var thumbnailState: AttachmentThumbnailState
    var filename: String
    var byteSize: Int
    var duration: Int?
    var dimensions: CGSize?
    var preparationState: AttachmentPreparationState
    var originalDraftID: String? = nil
}

enum ChatAttachmentReferenceBuilderError: Error, Equatable {
    case draftNotPrepared(String)
    case draftUnavailable(String, AttachmentDraftUnavailableReason)
}

struct ChatAttachmentReferenceBuilder {
    func makeReferences(
        from drafts: [AttachmentDraft],
        context: ChatAttachmentFlowContext
    ) throws -> [MessageReferenceStorageItem] {
        try drafts.map { draft in
            try makeReference(from: draft, context: context)
        }
    }

    private func makeReference(
        from draft: AttachmentDraft,
        context: ChatAttachmentFlowContext
    ) throws -> MessageReferenceStorageItem {
        let preparedFile: AttachmentPreparedFile

        switch draft.preparationState {
        case .prepared(let file):
            preparedFile = file
        case .unavailable(let reason):
            throw ChatAttachmentReferenceBuilderError.draftUnavailable(draft.id, reason)
        case .pending, .preparing:
            throw ChatAttachmentReferenceBuilderError.draftNotPrepared(draft.id)
        }

        let reference = MessageReferenceStorageItem()
        reference.kind = .media
        reference.owner = context.owner
        reference.jid = context.jid
        reference.conversationType = context.conversationType
        reference.mimeType = MimeIcon(preparedFile.mediaType).value.rawValue
        reference.temporaryData = preparedFile.temporaryData

        var metadata: [String: Any] = [
            "filename": preparedFile.filename,
            "size": preparedFile.byteSize,
            "media-type": preparedFile.mediaType,
            "uri": preparedFile.referenceURL.absoluteString,
            "name": displayName(for: draft.mediaKind, filename: preparedFile.filename)
        ]

        if let dimensions = preparedFile.dimensions ?? draft.dimensions {
            metadata["width"] = Self.roundedPixelValue(dimensions.width)
            metadata["height"] = Self.roundedPixelValue(dimensions.height)
        }

        switch draft.mediaKind {
        case .audio:
            if let duration = preparedFile.duration ?? draft.duration {
                metadata["duration"] = duration
            }
        case .video:
            if let previewKey = preparedFile.videoPreviewKey {
                metadata["thumbnail"] = previewKey
            }
            if let orientation = preparedFile.videoOrientation {
                metadata["orientation"] = orientation
            }
            if let durationLabel = preparedFile.videoDurationLabel {
                metadata["video_duration"] = durationLabel
            }
            if let previewLocalURL = preparedFile.videoPreviewLocalURL {
                metadata["preview_local_url"] = previewLocalURL.absoluteString
            }
            if preparedFile.videoPreviewKey != nil || preparedFile.videoPreviewLocalURL != nil {
                reference.isDownloaded = true
            }
        case .image, .animatedImage, .file:
            break
        }

        reference.metadata = metadata
        reference.localFileUrl = preparedFile.localFileURL
        reference.primary = UUID().uuidString

        return reference
    }

    private func displayName(for mediaKind: AttachmentMediaKind, filename: String) -> String {
        switch mediaKind {
        case .image, .animatedImage:
            return "Image"
        case .video:
            return "Video"
        case .audio, .file:
            return filename
        }
    }

    private static func roundedPixelValue(_ value: CGFloat) -> Int {
        Int(value.rounded())
    }
}
