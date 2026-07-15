import Foundation
import Kingfisher
import UIKit

enum ChatThumbnailTraitStyle: String, Hashable {
    case unspecified
    case light
    case dark

    init(_ style: UIUserInterfaceStyle) {
        switch style {
        case .light:
            self = .light
        case .dark:
            self = .dark
        default:
            self = .unspecified
        }
    }
}

struct ChatThumbnailRequest: Hashable {
    let url: URL
    let displaySize: ChatCollectionPrefetchSize
    let scale: Double
    let traitStyle: ChatThumbnailTraitStyle

    init(
        url: URL,
        displaySize: ChatCollectionPrefetchSize,
        scale: Double,
        traitStyle: ChatThumbnailTraitStyle = .unspecified
    ) {
        self.url = url
        self.displaySize = ChatCollectionPrefetchSize(
            width: max(1, displaySize.width),
            height: max(1, displaySize.height)
        )
        self.scale = max(1, scale)
        self.traitStyle = traitStyle
    }

    var pixelSize: ChatCollectionPrefetchSize {
        displaySize.scaled(by: scale)
    }

    var processorIdentifier: String {
        [
            "com.xabber.chat.thumbnail.downsample",
            displaySize.cacheComponent,
            "scale-\(scale.chatThumbnailCacheComponent)",
            "style-\(traitStyle.rawValue)"
        ].joined(separator: ":")
    }

    var cacheKey: String {
        "\(url.absoluteString)#chat-thumbnail:\(pixelSize.cacheComponent)@\(scale.chatThumbnailCacheComponent):\(traitStyle.rawValue)"
    }

    func accepts(pixelSize result: ChatCollectionPrefetchSize) -> Bool {
        let requestedMaximum = max(pixelSize.width, pixelSize.height)
        let resultMaximum = max(result.width, result.height)
        return resultMaximum <= requestedMaximum + 1
    }
}

private extension Double {
    var chatThumbnailCacheComponent: String {
        rounded() == self ? "\(Int(self))" : String(format: "%.2f", self)
    }
}

struct ChatThumbnailConsumer: Hashable {
    enum Role: Hashable {
        case prefetch
        case visible(UUID)
    }

    let identity: ChatCollectionPrefetchIdentity
    let role: Role
}

struct ChatThumbnailImage {
    let image: UIImage
    let pixelSize: ChatCollectionPrefetchSize
}

struct ChatThumbnailDelivery {
    enum Source: Equatable {
        case loader
        case processedMemoryCache
    }

    let image: UIImage
    let pixelSize: ChatCollectionPrefetchSize
    let source: Source
}

enum ChatThumbnailPipelineError: Error, Equatable {
    case loadFailed
    case oversizedResult
    case queueOverflow
}

protocol ChatThumbnailLoadTask: AnyObject {
    func cancel()
}

protocol ChatThumbnailLoading: AnyObject {
    func load(
        _ request: ChatThumbnailRequest,
        completion: @escaping (Result<ChatThumbnailImage, ChatThumbnailPipelineError>) -> Void
    ) -> ChatThumbnailLoadTask
}

protocol ChatThumbnailCaching: AnyObject {
    func image(for request: ChatThumbnailRequest) -> ChatThumbnailImage?
    func store(_ image: ChatThumbnailImage, for request: ChatThumbnailRequest)
    func removeAll()
}

protocol ChatThumbnailSubscription: AnyObject {
    func cancel()
}

protocol ChatThumbnailServing: AnyObject {
    @discardableResult
    func acquire(
        _ request: ChatThumbnailRequest,
        consumer: ChatThumbnailConsumer,
        completion: ((Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>) -> Void)?
    ) -> ChatThumbnailSubscription
}

struct ChatThumbnailPipelineMetrics {
    let underlyingLoadCount: Int
    let processedMemoryCacheHitCount: Int
    let deduplicatedAcquireCount: Int
    let rejectedOversizedResultCount: Int
    let droppedQueuedWorkCount: Int
    let activeWorkCount: Int
    let queuedWorkCount: Int
    let peakConcurrentWorkCount: Int
}

final class ChatMediaThumbnailPipeline: ChatThumbnailServing {
    static let shared = ChatMediaThumbnailPipeline(
        loader: KingfisherChatThumbnailLoader(),
        cache: ChatThumbnailMemoryCache(
            countLimit: ChatPerformanceResourceBudgets.thumbnailCount,
            totalCostLimit: ChatPerformanceResourceBudgets.thumbnailMemoryBytes
        ),
        maxConcurrentWork: ChatPerformanceResourceBudgets.thumbnailConcurrentWork,
        maxQueuedWork: ChatPerformanceResourceBudgets.thumbnailQueuedWork
    )

    private struct ConsumerEntry {
        let consumer: ChatThumbnailConsumer
        let completion: ((Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>) -> Void)?
    }

    private enum WorkState: Equatable {
        case queued
        case running
    }

    private final class Work {
        let request: ChatThumbnailRequest
        var state: WorkState = .queued
        var consumers: [UUID: ConsumerEntry]
        var task: ChatThumbnailLoadTask?

        init(request: ChatThumbnailRequest, subscriptionID: UUID, entry: ConsumerEntry) {
            self.request = request
            self.consumers = [subscriptionID: entry]
        }
    }

    private let loader: ChatThumbnailLoading
    private let cache: ChatThumbnailCaching
    private let maxConcurrentWork: Int
    private let maxQueuedWork: Int
    private let lock = NSRecursiveLock()
    private var workByRequest: [ChatThumbnailRequest: Work] = [:]
    private var queuedRequests: [ChatThumbnailRequest] = []
    private var activeWorkCount = 0
    private var underlyingLoadCount = 0
    private var processedMemoryCacheHitCount = 0
    private var deduplicatedAcquireCount = 0
    private var rejectedOversizedResultCount = 0
    private var droppedQueuedWorkCount = 0
    private var peakConcurrentWorkCount = 0

    init(
        loader: ChatThumbnailLoading,
        cache: ChatThumbnailCaching,
        maxConcurrentWork: Int,
        maxQueuedWork: Int = ChatPerformanceResourceBudgets.thumbnailQueuedWork
    ) {
        self.loader = loader
        self.cache = cache
        self.maxConcurrentWork = max(1, maxConcurrentWork)
        self.maxQueuedWork = max(0, maxQueuedWork)
    }

    var metrics: ChatThumbnailPipelineMetrics {
        lock.lock()
        defer { lock.unlock() }
        return ChatThumbnailPipelineMetrics(
            underlyingLoadCount: underlyingLoadCount,
            processedMemoryCacheHitCount: processedMemoryCacheHitCount,
            deduplicatedAcquireCount: deduplicatedAcquireCount,
            rejectedOversizedResultCount: rejectedOversizedResultCount,
            droppedQueuedWorkCount: droppedQueuedWorkCount,
            activeWorkCount: activeWorkCount,
            queuedWorkCount: queuedRequests.count,
            peakConcurrentWorkCount: peakConcurrentWorkCount
        )
    }

    @discardableResult
    func acquire(
        _ request: ChatThumbnailRequest,
        consumer: ChatThumbnailConsumer,
        completion: ((Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>) -> Void)?
    ) -> ChatThumbnailSubscription {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache.image(for: request), request.accepts(pixelSize: cached.pixelSize) {
            processedMemoryCacheHitCount += 1
            completion?(.success(ChatThumbnailDelivery(
                image: cached.image,
                pixelSize: cached.pixelSize,
                source: .processedMemoryCache
            )))
            return ChatThumbnailSubscriptionToken(cancel: {})
        }

        let subscriptionID = UUID()
        let entry = ConsumerEntry(consumer: consumer, completion: completion)
        if let work = workByRequest[request] {
            work.consumers[subscriptionID] = entry
            deduplicatedAcquireCount += 1
            if consumer.role.isVisible, work.state == .queued {
                queuedRequests.removeAll { $0 == request }
                queuedRequests.insert(request, at: 0)
            }
            return subscription(for: request, id: subscriptionID)
        }

        if consumer.role.isVisible, activeWorkCount >= maxConcurrentWork {
            let evictedQueuedPrefetch = queuedRequests.count >= maxQueuedWork &&
                evictOneQueuedPrefetchLocked()
            if !evictedQueuedPrefetch {
                _ = preemptOneRunningPrefetchLocked()
            }
        }

        if activeWorkCount >= maxConcurrentWork, queuedRequests.count >= maxQueuedWork {
            if consumer.role.isVisible, evictOneQueuedPrefetchLocked() {
                // The visible request takes the released bounded queue slot.
            } else {
                droppedQueuedWorkCount += 1
                completion?(.failure(.queueOverflow))
                return ChatThumbnailSubscriptionToken(cancel: {})
            }
        }

        let work = Work(request: request, subscriptionID: subscriptionID, entry: entry)
        workByRequest[request] = work
        if consumer.role.isVisible {
            queuedRequests.insert(request, at: 0)
        } else {
            queuedRequests.append(request)
        }
        drainQueueLocked()
        return subscription(for: request, id: subscriptionID)
    }

    func handleMemoryWarning() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()

        let prefetchSubscriptions = workByRequest.flatMap { request, work in
            work.consumers.compactMap { id, entry in
                entry.consumer.role == .prefetch ? (request, id) : nil
            }
        }
        prefetchSubscriptions.forEach { request, id in
            cancelLocked(request: request, subscriptionID: id)
        }
    }

    private func subscription(for request: ChatThumbnailRequest, id: UUID) -> ChatThumbnailSubscription {
        ChatThumbnailSubscriptionToken { [weak self] in
            self?.cancel(request: request, subscriptionID: id)
        }
    }

    private func cancel(request: ChatThumbnailRequest, subscriptionID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        cancelLocked(request: request, subscriptionID: subscriptionID)
    }

    private func cancelLocked(request: ChatThumbnailRequest, subscriptionID: UUID) {
        guard let work = workByRequest[request],
              work.consumers.removeValue(forKey: subscriptionID) != nil,
              work.consumers.isEmpty else {
            return
        }

        workByRequest.removeValue(forKey: request)
        switch work.state {
        case .queued:
            queuedRequests.removeAll { $0 == request }
        case .running:
            activeWorkCount = max(0, activeWorkCount - 1)
            work.task?.cancel()
        }
        drainQueueLocked()
    }

    private func drainQueueLocked() {
        while activeWorkCount < maxConcurrentWork, queuedRequests.isNotEmpty {
            let request = queuedRequests.removeFirst()
            guard let work = workByRequest[request], work.state == .queued else {
                continue
            }
            work.state = .running
            activeWorkCount += 1
            underlyingLoadCount += 1
            peakConcurrentWorkCount = max(peakConcurrentWorkCount, activeWorkCount)
            let task = loader.load(request) { [weak self, weak work] result in
                self?.finish(request: request, work: work, result: result)
            }
            if workByRequest[request] === work {
                work.task = task
            }
        }
    }

    private func evictOneQueuedPrefetchLocked() -> Bool {
        guard let queueIndex = queuedRequests.lastIndex(where: { request in
            guard let work = workByRequest[request] else { return false }
            return work.consumers.values.allSatisfy { !$0.consumer.role.isVisible }
        }) else {
            return false
        }
        let request = queuedRequests.remove(at: queueIndex)
        guard let work = workByRequest.removeValue(forKey: request) else {
            return false
        }
        droppedQueuedWorkCount += 1
        work.consumers.values.compactMap(\.completion).forEach {
            $0(.failure(.queueOverflow))
        }
        return true
    }

    private func preemptOneRunningPrefetchLocked() -> Bool {
        guard let (request, work) = workByRequest.first(where: { _, work in
            work.state == .running &&
                work.consumers.values.allSatisfy { !$0.consumer.role.isVisible }
        }) else {
            return false
        }

        workByRequest.removeValue(forKey: request)
        activeWorkCount = max(0, activeWorkCount - 1)
        droppedQueuedWorkCount += 1
        work.task?.cancel()
        work.consumers.values.compactMap(\.completion).forEach {
            $0(.failure(.queueOverflow))
        }
        return true
    }

    private func finish(
        request: ChatThumbnailRequest,
        work: Work?,
        result: Result<ChatThumbnailImage, ChatThumbnailPipelineError>
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let work, workByRequest[request] === work, work.state == .running else {
            return
        }

        workByRequest.removeValue(forKey: request)
        activeWorkCount = max(0, activeWorkCount - 1)
        let callbacks = work.consumers.values.compactMap(\.completion)
        let deliveryResult: Result<ChatThumbnailDelivery, ChatThumbnailPipelineError>
        switch result {
        case .success(let image):
            guard request.accepts(pixelSize: image.pixelSize) else {
                rejectedOversizedResultCount += 1
                deliveryResult = .failure(.oversizedResult)
                callbacks.forEach { $0(deliveryResult) }
                drainQueueLocked()
                return
            }
            cache.store(image, for: request)
            deliveryResult = .success(ChatThumbnailDelivery(
                image: image.image,
                pixelSize: image.pixelSize,
                source: .loader
            ))
        case .failure(let error):
            deliveryResult = .failure(error)
        }
        callbacks.forEach { $0(deliveryResult) }
        drainQueueLocked()
    }
}

private extension ChatThumbnailConsumer.Role {
    var isVisible: Bool {
        if case .visible = self {
            return true
        }
        return false
    }
}

private final class ChatThumbnailSubscriptionToken: ChatThumbnailSubscription {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        cancellation = cancel
    }

    func cancel() {
        lock.lock()
        let cancellation = cancellation
        self.cancellation = nil
        lock.unlock()
        cancellation?()
    }

    deinit {
        cancel()
    }
}

private final class ChatThumbnailMemoryCache: ChatThumbnailCaching {
    private final class Box {
        let value: ChatThumbnailImage

        init(_ value: ChatThumbnailImage) {
            self.value = value
        }
    }

    private let cache = NSCache<NSString, Box>()

    init(
        countLimit: Int = ChatPerformanceResourceBudgets.thumbnailCount,
        totalCostLimit: Int = ChatPerformanceResourceBudgets.thumbnailMemoryBytes
    ) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    func image(for request: ChatThumbnailRequest) -> ChatThumbnailImage? {
        cache.object(forKey: request.cacheKey as NSString)?.value
    }

    func store(_ image: ChatThumbnailImage, for request: ChatThumbnailRequest) {
        let cost = max(1, Int(image.pixelSize.width * image.pixelSize.height * 4))
        cache.setObject(Box(image), forKey: request.cacheKey as NSString, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

private struct ChatThumbnailDownsamplingProcessor: ImageProcessor {
    let request: ChatThumbnailRequest

    var identifier: String {
        request.processorIdentifier
    }

    func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        DownsamplingImageProcessor(size: request.displaySize.cgSize).process(item: item, options: options)
    }
}

private final class KingfisherChatThumbnailLoadTask: ChatThumbnailLoadTask {
    private let lock = NSLock()
    private var task: DownloadTask?
    private var isCancelled = false

    func update(_ task: DownloadTask?) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task?.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

private final class KingfisherChatThumbnailLoader: ChatThumbnailLoading {
    private static let memoryExpiration: StorageExpiration = .seconds(20 * 60)

    func load(
        _ request: ChatThumbnailRequest,
        completion: @escaping (Result<ChatThumbnailImage, ChatThumbnailPipelineError>) -> Void
    ) -> ChatThumbnailLoadTask {
        let token = KingfisherChatThumbnailLoadTask()
        let resource = Kingfisher.ImageResource(downloadURL: request.url, cacheKey: request.cacheKey)
        let task = KingfisherManager.shared.retrieveImage(
            with: resource,
            options: [
                .backgroundDecode,
                .callbackQueue(.mainCurrentOrAsync),
                .memoryCacheExpiration(Self.memoryExpiration),
                .processor(ChatThumbnailDownsamplingProcessor(request: request)),
                .scaleFactor(CGFloat(request.scale)),
                .waitForCache
            ],
            downloadTaskUpdated: { token.update($0) }
        ) { result in
            switch result {
            case .success(let value):
                let image = value.image
                let pixelSize: ChatCollectionPrefetchSize
                if let cgImage = image.cgImage {
                    pixelSize = ChatCollectionPrefetchSize(
                        width: Double(cgImage.width),
                        height: Double(cgImage.height)
                    )
                } else {
                    pixelSize = ChatCollectionPrefetchSize(
                        width: Double(image.size.width * image.scale),
                        height: Double(image.size.height * image.scale)
                    )
                }
                completion(.success(ChatThumbnailImage(image: image, pixelSize: pixelSize)))
            case .failure:
                completion(.failure(.loadFailed))
            }
        }
        token.update(task)
        return token
    }
}
