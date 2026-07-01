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
    case location
    case contact
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
    var uploadedRemoteFile: AttachmentUploadedRemoteFile? = nil
}

struct AttachmentUploadedRemoteFile: Equatable {
    let remoteURL: URL
    let fileID: Int
    let hash: String?
    let createdAt: Date?
    let metadata: [String: String]?
}

struct AttachmentLocationCoordinate: Equatable {
    let latitude: Double
    let longitude: Double
}

struct AttachmentPreparedLocation: Equatable {
    let coordinate: AttachmentLocationCoordinate
    let displayAddress: String?
    let accuracy: Double?
    let geoURI: String
    let createdAt: Date
    let localSnapshotURL: URL?
}

struct AttachmentPreparedContact: Equatable {
    let jid: String
    let entity: MessageContactEntityKind
    let nickname: String?
    let given: String?
    let family: String?
    let displayTitle: String
    let avatarURL: String?
    let avatarMetadata: [String: String]

    init(
        jid: String,
        entity: MessageContactEntityKind = .contact,
        nickname: String?,
        given: String?,
        family: String?,
        displayTitle: String,
        avatarURL: String?,
        avatarMetadata: [String: String]
    ) {
        self.jid = jid
        self.entity = entity
        self.nickname = nickname
        self.given = given
        self.family = family
        self.displayTitle = displayTitle
        self.avatarURL = avatarURL
        self.avatarMetadata = avatarMetadata
    }
}

enum AttachmentPreparationState: Equatable {
    case pending
    case preparing
    case prepared(AttachmentPreparedFile)
    case preparedLocation(AttachmentPreparedLocation)
    case preparedContact(AttachmentPreparedContact)
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

extension AttachmentDraft {
    var uploadedRemoteFile: AttachmentUploadedRemoteFile? {
        guard case .prepared(let file) = preparationState else {
            return nil
        }

        return file.uploadedRemoteFile
    }

    var preparedLocation: AttachmentPreparedLocation? {
        guard case .preparedLocation(let location) = preparationState else {
            return nil
        }

        return location
    }

    var preparedContact: AttachmentPreparedContact? {
        guard case .preparedContact(let contact) = preparationState else {
            return nil
        }

        return contact
    }

    var isPreparedForSend: Bool {
        switch preparationState {
        case .prepared:
            return true
        case .preparedLocation:
            return true
        case .preparedContact:
            return true
        case .pending, .preparing, .unavailable:
            return false
        }
    }

    var requiresUpload: Bool {
        if preparedLocation != nil || preparedContact != nil {
            return false
        }

        return uploadedRemoteFile == nil
    }
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
        switch draft.preparationState {
        case .prepared(let file):
            return makeFileReference(from: draft, preparedFile: file, context: context)
        case .preparedLocation(let location):
            return makeLocationReference(from: draft, location: location, context: context)
        case .preparedContact(let contact):
            return makeContactReference(from: draft, contact: contact, context: context)
        case .unavailable(let reason):
            throw ChatAttachmentReferenceBuilderError.draftUnavailable(draft.id, reason)
        case .pending, .preparing:
            throw ChatAttachmentReferenceBuilderError.draftNotPrepared(draft.id)
        }
    }

    private func makeFileReference(
        from draft: AttachmentDraft,
        preparedFile: AttachmentPreparedFile,
        context: ChatAttachmentFlowContext
    ) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.kind = .media
        reference.owner = context.owner
        reference.jid = context.jid
        reference.conversationType = context.conversationType
        reference.mimeType = MimeIcon(preparedFile.mediaType).value.rawValue
        reference.temporaryData = preparedFile.temporaryData

        let uploadedRemoteFile = preparedFile.uploadedRemoteFile
        var metadata: [String: Any] = [
            "filename": preparedFile.filename,
            "size": preparedFile.byteSize,
            "media-type": preparedFile.mediaType,
            "uri": uploadedRemoteFile?.remoteURL.absoluteString ?? preparedFile.referenceURL.absoluteString,
            "name": displayName(for: draft.mediaKind, filename: preparedFile.filename)
        ]

        if let uploadedRemoteFile {
            metadata["fileID"] = uploadedRemoteFile.fileID
            if let hash = uploadedRemoteFile.hash {
                metadata["hash"] = hash
            }
            uploadedRemoteFile.metadata?.forEach { key, value in
                metadata[key] = value
            }
        }

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
        case .image, .animatedImage, .file, .location, .contact:
            break
        }

        reference.metadata = metadata
        if let uploadedRemoteFile {
            reference.downloadUrl = uploadedRemoteFile.remoteURL
            reference.isUploaded = true
        } else {
            reference.localFileUrl = preparedFile.localFileURL
        }
        reference.primary = UUID().uuidString

        return reference
    }

    private func makeLocationReference(
        from draft: AttachmentDraft,
        location: AttachmentPreparedLocation,
        context: ChatAttachmentFlowContext
    ) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.kind = .geoloc
        reference.owner = context.owner
        reference.jid = context.jid
        reference.conversationType = context.conversationType
        reference.mimeType = "location"
        reference.url = location.geoURI
        reference.isUploaded = true
        reference.primary = UUID().uuidString

        var metadata: [String: Any] = [
            "lat": Self.geolocNumberString(location.coordinate.latitude),
            "lon": Self.geolocNumberString(location.coordinate.longitude),
            "uri": location.geoURI,
            "timestamp": Self.geolocTimestampString(from: location.createdAt)
        ]
        if let displayAddress = location.displayAddress, displayAddress.isNotEmpty {
            metadata["text"] = displayAddress
        }
        if let accuracy = location.accuracy, accuracy.isFinite {
            metadata["accuracy"] = Self.geolocNumberString(accuracy)
        }
        if let localSnapshotURL = location.localSnapshotURL {
            metadata["local-snapshot-url"] = localSnapshotURL.absoluteString
        }
        reference.metadata = metadata

        return reference
    }

    private func makeContactReference(
        from draft: AttachmentDraft,
        contact: AttachmentPreparedContact,
        context: ChatAttachmentFlowContext
    ) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.kind = .contact
        reference.owner = context.owner
        reference.jid = context.jid
        reference.conversationType = context.conversationType
        reference.mimeType = "contact"
        reference.url = "xmpp:\(contact.jid)"
        reference.isUploaded = true
        reference.primary = UUID().uuidString

        var metadata: [String: Any] = [
            "contact_jid": contact.jid,
            "entity": contact.entity.rawValue,
            "display_title": contact.displayTitle
        ]
        if let nickname = contact.nickname, nickname.isNotEmpty {
            metadata["nickname"] = nickname
        }
        if let given = contact.given, given.isNotEmpty {
            metadata["given"] = given
        }
        if let family = contact.family, family.isNotEmpty {
            metadata["family"] = family
        }
        if let avatarURL = contact.avatarURL, avatarURL.isNotEmpty {
            metadata["avatar_url"] = avatarURL
        }
        contact.avatarMetadata.forEach { key, value in
            guard value.isNotEmpty else { return }
            metadata[key] = value
        }
        reference.metadata = metadata

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
        case .location:
            return "Location"
        case .contact:
            return filename
        }
    }

    private static func roundedPixelValue(_ value: CGFloat) -> Int {
        Int(value.rounded())
    }

    private static func geolocNumberString(_ value: Double) -> String {
        String(value)
    }

    private static func geolocTimestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
