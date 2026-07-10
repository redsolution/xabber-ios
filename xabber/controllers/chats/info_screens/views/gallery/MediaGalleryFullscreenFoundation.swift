import UIKit

struct MediaGalleryGridLayoutPolicy: Equatable {
    let columnCount: Int
    let sectionInset: UIEdgeInsets
    let interitemSpacing: CGFloat

    init(
        columnCount: Int = 3,
        sectionInset: UIEdgeInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8),
        interitemSpacing: CGFloat = 8
    ) {
        self.columnCount = max(1, columnCount)
        self.sectionInset = sectionInset
        self.interitemSpacing = max(0, interitemSpacing)
    }

    func squareItemSize(
        containerWidth: CGFloat,
        contentInset: UIEdgeInsets = .zero
    ) -> CGSize {
        let horizontalInsets = sectionInset.left
            + sectionInset.right
            + contentInset.left
            + contentInset.right
        let totalSpacing = interitemSpacing * CGFloat(max(0, columnCount - 1))
        let availableWidth = max(0, containerWidth - horizontalInsets - totalSpacing)
        let width = availableWidth / CGFloat(columnCount)
        return CGSize(width: width, height: width)
    }
}

enum MediaGalleryDatasourceMapper {
    static func map(
        _ item: MessageMediaAttachmentStorageItem,
        revealedSensitiveMediaPrimaries: Set<String>
    ) -> BaseMediaGalleryForChatViewController.Datasource {
        let metadata = item.metadata ?? [:]
        let durationSeconds = positiveDuration(from: metadata["duration"])
        let previewCacheIdentity = firstNonEmptyString(
            metadata["preview_local_url"],
            metadata["thumbnail"],
            metadata["preview_url"]
        )
        let decodedURL = url(from: firstNonEmptyString(
            metadata["decodedUrl"],
            metadata["decoded_url"]
        ))

        return BaseMediaGalleryForChatViewController.Datasource(
            kind: item.kind,
            primary: item.primary,
            owner: item.owner,
            jid: item.jid,
            conversationType: item.conversationType,
            date: item.date,
            filename: item.filename,
            url: url(from: item.url_),
            messagePrimary: item.messagePrimary,
            archiveId: item.archiveId,
            isDownloaded: item.isDownloaded || decodedURL != nil,
            verySmallThumb: item.verySmallThumb,
            thumb: item.thumb,
            byteSize: item.sizeBytes,
            formattedByteSize: AccountQuotaStorageItem.beautify(size: item.sizeBytes),
            durationSeconds: durationSeconds,
            formattedDuration: durationSeconds.map(formatDuration),
            previewURL: url(from: previewCacheIdentity),
            previewCacheIdentity: previewCacheIdentity,
            mediaType: firstNonEmptyString(metadata["media-type"]),
            decodedURL: decodedURL,
            pcm: waveformLevels(from: metadata["pcm"]),
            isSensitive: item.isSensitive,
            isSensitiveRevealed: revealedSensitiveMediaPrimaries.contains(item.primary)
        )
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func positiveDuration(from value: Any?) -> TimeInterval? {
        let duration: TimeInterval?
        switch value {
        case let value as NSNumber:
            duration = value.doubleValue
        case let value as String:
            duration = TimeInterval(value)
        default:
            duration = nil
        }

        guard let duration, duration.isFinite, duration > 0 else {
            return nil
        }
        return duration
    }

    private static func waveformLevels(from value: Any?) -> [Float] {
        if let value = value as? String {
            return value
                .split(whereSeparator: { $0.isWhitespace })
                .compactMap { Float($0) }
        }
        if let values = value as? [NSNumber] {
            return values.map(\.floatValue)
        }
        if let values = value as? [Double] {
            return values.map(Float.init)
        }
        if let values = value as? [Float] {
            return values
        }
        return []
    }

    private static func firstNonEmptyString(_ values: Any?...) -> String? {
        values
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func url(from value: String?) -> URL? {
        guard let value, !value.isEmpty else {
            return nil
        }
        guard let url = URL(string: value),
              url.scheme?.isEmpty == false else {
            return nil
        }
        return url
    }
}
