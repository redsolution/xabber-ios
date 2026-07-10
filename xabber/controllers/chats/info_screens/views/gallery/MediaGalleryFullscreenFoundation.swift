import UIKit
import Kingfisher

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

final class MediaGalleryThreeColumnFlowLayout: UICollectionViewFlowLayout {
    let policy: MediaGalleryGridLayoutPolicy

    init(policy: MediaGalleryGridLayoutPolicy = MediaGalleryGridLayoutPolicy()) {
        self.policy = policy
        super.init()
        minimumInteritemSpacing = policy.interitemSpacing
        minimumLineSpacing = policy.interitemSpacing
        sectionInset = policy.sectionInset
        itemSize = CGSize(width: 1, height: 1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepare() {
        if let collectionView {
            let nextItemSize = policy.squareItemSize(
                containerWidth: collectionView.bounds.width,
                contentInset: collectionView.adjustedContentInset
            )
            if itemSize != nextItemSize {
                itemSize = nextItemSize
            }
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return true }
        return abs(newBounds.width - collectionView.bounds.width) > .ulpOfOne
    }
}

struct MediaGalleryImageRequest: Hashable {
    let url: URL
    let displaySize: CGSize
    let scale: CGFloat

    init(url: URL, displaySize: CGSize, scale: CGFloat) {
        self.url = url
        self.displaySize = CGSize(
            width: max(1, displaySize.width),
            height: max(1, displaySize.height)
        )
        self.scale = max(1, scale)
    }

    var pixelSize: CGSize {
        CGSize(
            width: ceil(displaySize.width * scale),
            height: ceil(displaySize.height * scale)
        )
    }

    var cacheKey: String {
        "\(url.absoluteString)#media-gallery:\(pixelSize.cacheComponent)@\(scale.cacheComponent)"
    }

    var resource: KF.ImageResource {
        KF.ImageResource(downloadURL: url, cacheKey: cacheKey)
    }

    var kingfisherOptions: KingfisherOptionsInfo {
        [
            .alsoPrefetchToMemory,
            .backgroundDecode,
            .memoryCacheExpiration(.seconds(20 * 60)),
            .processor(DownsamplingImageProcessor(size: displaySize)),
            .scaleFactor(scale)
        ]
    }
}

private extension CGSize {
    var cacheComponent: String {
        "\(Int(ceil(width)))x\(Int(ceil(height)))"
    }
}

private extension CGFloat {
    var cacheComponent: String {
        rounded() == self ? "\(Int(self))" : String(format: "%.2f", Double(self))
    }
}

enum MediaGalleryImageRequestPlanner {
    static func request(
        for item: BaseMediaGalleryForChatViewController.Datasource,
        displaySize: CGSize,
        scale: CGFloat
    ) -> MediaGalleryImageRequest? {
        guard item.kind == .image,
              let url = item.previewURL ?? item.url else {
            return nil
        }
        return MediaGalleryImageRequest(
            url: url,
            displaySize: displaySize,
            scale: scale
        )
    }
}

protocol MediaGalleryImagePrefetchTask: AnyObject {
    func start()
    func stop()
}

protocol MediaGalleryImagePrefetchTaskMaking: AnyObject {
    func makeTask(for request: MediaGalleryImageRequest) -> MediaGalleryImagePrefetchTask
}

final class KingfisherMediaGalleryImagePrefetchTaskFactory: MediaGalleryImagePrefetchTaskMaking {
    func makeTask(for request: MediaGalleryImageRequest) -> MediaGalleryImagePrefetchTask {
        KingfisherMediaGalleryImagePrefetchTask(request: request)
    }
}

private final class KingfisherMediaGalleryImagePrefetchTask: MediaGalleryImagePrefetchTask {
    private let prefetcher: ImagePrefetcher

    init(request: MediaGalleryImageRequest) {
        prefetcher = ImagePrefetcher(
            resources: [request.resource],
            options: request.kingfisherOptions
        )
    }

    func start() {
        prefetcher.start()
    }

    func stop() {
        prefetcher.stop()
    }
}

final class MediaGalleryImagePrefetchCoordinator {
    typealias ItemProvider = (IndexPath) -> BaseMediaGalleryForChatViewController.Datasource?
    typealias DisplaySizeProvider = () -> CGSize
    typealias ScaleProvider = () -> CGFloat

    private let itemProvider: ItemProvider
    private let displaySizeProvider: DisplaySizeProvider
    private let scaleProvider: ScaleProvider
    private let taskFactory: MediaGalleryImagePrefetchTaskMaking
    private var requestsByIndexPath: [IndexPath: MediaGalleryImageRequest] = [:]
    private var tasksByRequest: [MediaGalleryImageRequest: MediaGalleryImagePrefetchTask] = [:]

    var activeRequestCount: Int {
        tasksByRequest.count
    }

    init(
        itemProvider: @escaping ItemProvider,
        displaySizeProvider: @escaping DisplaySizeProvider,
        scaleProvider: @escaping ScaleProvider,
        taskFactory: MediaGalleryImagePrefetchTaskMaking = KingfisherMediaGalleryImagePrefetchTaskFactory()
    ) {
        self.itemProvider = itemProvider
        self.displaySizeProvider = displaySizeProvider
        self.scaleProvider = scaleProvider
        self.taskFactory = taskFactory
    }

    func prefetchItems(at indexPaths: [IndexPath]) {
        let displaySize = displaySizeProvider()
        let scale = scaleProvider()

        indexPaths.forEach { indexPath in
            guard let item = itemProvider(indexPath),
                  let request = MediaGalleryImageRequestPlanner.request(
                    for: item,
                    displaySize: displaySize,
                    scale: scale
                  ) else {
                removeRequest(for: indexPath)
                return
            }

            if requestsByIndexPath[indexPath] == request {
                return
            }
            removeRequest(for: indexPath)
            requestsByIndexPath[indexPath] = request

            guard tasksByRequest[request] == nil else { return }
            let task = taskFactory.makeTask(for: request)
            tasksByRequest[request] = task
            task.start()
        }
    }

    func cancelPrefetchingForItems(at indexPaths: [IndexPath]) {
        indexPaths.forEach(removeRequest(for:))
    }

    func cancelAll() {
        requestsByIndexPath.removeAll()
        tasksByRequest.values.forEach { $0.stop() }
        tasksByRequest.removeAll()
    }

    private func removeRequest(for indexPath: IndexPath) {
        guard let request = requestsByIndexPath.removeValue(forKey: indexPath),
              !requestsByIndexPath.values.contains(request),
              let task = tasksByRequest.removeValue(forKey: request) else {
            return
        }
        task.stop()
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
