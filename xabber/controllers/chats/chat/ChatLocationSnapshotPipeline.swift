import Foundation
import ImageIO
import MapKit
import UIKit

enum ChatLocationSnapshotMapStyle: String, Hashable {
    case standard
    case mutedStandard

    var mapType: MKMapType {
        switch self {
        case .standard: return .standard
        case .mutedStandard: return .mutedStandard
        }
    }
}

struct ChatLocationSnapshotRequest: Hashable {
    let latitude: Double
    let longitude: Double
    let sourceURL: URL?
    let displaySize: ChatCollectionPrefetchSize
    let scale: Double
    let mapStyle: ChatLocationSnapshotMapStyle
    let traitStyle: ChatThumbnailTraitStyle

    init(
        latitude: Double,
        longitude: Double,
        sourceURL: URL? = nil,
        displaySize: ChatCollectionPrefetchSize,
        scale: Double,
        mapStyle: ChatLocationSnapshotMapStyle = .standard,
        traitStyle: ChatThumbnailTraitStyle = .unspecified
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.sourceURL = sourceURL
        self.displaySize = ChatCollectionPrefetchSize(
            width: max(1, displaySize.width),
            height: max(1, displaySize.height)
        )
        self.scale = max(1, scale)
        self.mapStyle = mapStyle
        self.traitStyle = traitStyle
    }

    var pixelSize: ChatCollectionPrefetchSize {
        displaySize.scaled(by: scale)
    }

    var cacheKey: String {
        [
            String(format: "%.7f", latitude),
            String(format: "%.7f", longitude),
            pixelSize.cacheComponent,
            "scale-\(String(format: "%.2f", scale))",
            "map-\(mapStyle.rawValue)",
            "style-\(traitStyle.rawValue)",
            "source-\(sourceURL?.absoluteString ?? "generated")"
        ].joined(separator: ":")
    }
}

struct ChatLocationSnapshotArtifact {
    let image: UIImage
    let pngData: Data
}

struct ChatLocationSnapshotDelivery {
    enum Source: Equatable {
        case loader
        case diskCache
    }

    let image: UIImage
    let source: Source
}

enum ChatLocationSnapshotPipelineError: Error, Equatable {
    case loadFailed
    case imageEncodingFailed
    case diskFailure
    case queueOverflow
}

protocol ChatLocationSnapshotLoadTask: AnyObject {
    func cancel()
}

protocol ChatLocationSnapshotLoading: AnyObject {
    func load(
        _ request: ChatLocationSnapshotRequest,
        completion: @escaping (Result<ChatLocationSnapshotArtifact, ChatLocationSnapshotPipelineError>) -> Void
    ) -> ChatLocationSnapshotLoadTask
}

protocol ChatLocationSnapshotSubscription: AnyObject {
    func cancel()
}

struct ChatLocationSnapshotConsumer: Hashable {
    enum Role: Hashable {
        case prefetch
        case visible(UUID)
    }

    let identity: ChatCollectionPrefetchIdentity
    let role: Role
}

protocol ChatLocationSnapshotServing: AnyObject {
    @discardableResult
    func acquire(
        _ request: ChatLocationSnapshotRequest,
        consumer: ChatLocationSnapshotConsumer,
        completion: ((Result<ChatLocationSnapshotDelivery, ChatLocationSnapshotPipelineError>) -> Void)?
    ) -> ChatLocationSnapshotSubscription
}

struct ChatLocationSnapshotPipelineMetrics {
    let underlyingLoadCount: Int
    let deduplicatedAcquireCount: Int
    let activeWorkCount: Int
    let queuedWorkCount: Int
    let peakConcurrentWorkCount: Int
    let droppedQueuedWorkCount: Int
}

final class ChatLocationSnapshotPipeline: ChatLocationSnapshotServing {
    static let shared: ChatLocationSnapshotPipeline = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xabber-chat-location-snapshots", isDirectory: true)
        let cache = ChatLocationSnapshotDiskCache(
            directoryURL: directory,
            maxEntryCount: 96,
            maxDiskBytes: 64 * 1_024 * 1_024,
            ttl: 7 * 24 * 60 * 60
        )
        cache.cleanup(completion: {})
        return ChatLocationSnapshotPipeline(
            loader: MapKitChatLocationSnapshotLoader(cache: cache),
            maxConcurrentWork: 2,
            maxQueuedWork: 24
        )
    }()

    private struct ConsumerEntry {
        let consumer: ChatLocationSnapshotConsumer
        let completion: ((Result<ChatLocationSnapshotDelivery, ChatLocationSnapshotPipelineError>) -> Void)?
    }

    private enum WorkState {
        case queued
        case running
    }

    private final class Work {
        let request: ChatLocationSnapshotRequest
        var state: WorkState = .queued
        var consumers: [UUID: ConsumerEntry]
        var task: ChatLocationSnapshotLoadTask?

        init(request: ChatLocationSnapshotRequest, id: UUID, entry: ConsumerEntry) {
            self.request = request
            self.consumers = [id: entry]
        }
    }

    private let loader: ChatLocationSnapshotLoading
    private let maxConcurrentWork: Int
    private let maxQueuedWork: Int
    private let lock = NSRecursiveLock()
    private var workByRequest: [ChatLocationSnapshotRequest: Work] = [:]
    private var queuedRequests: [ChatLocationSnapshotRequest] = []
    private var activeWorkCount = 0
    private var underlyingLoadCount = 0
    private var deduplicatedAcquireCount = 0
    private var peakConcurrentWorkCount = 0
    private var droppedQueuedWorkCount = 0

    init(
        loader: ChatLocationSnapshotLoading,
        maxConcurrentWork: Int,
        maxQueuedWork: Int = 24
    ) {
        self.loader = loader
        self.maxConcurrentWork = max(1, maxConcurrentWork)
        self.maxQueuedWork = max(0, maxQueuedWork)
    }

    var metrics: ChatLocationSnapshotPipelineMetrics {
        lock.lock()
        defer { lock.unlock() }
        return ChatLocationSnapshotPipelineMetrics(
            underlyingLoadCount: underlyingLoadCount,
            deduplicatedAcquireCount: deduplicatedAcquireCount,
            activeWorkCount: activeWorkCount,
            queuedWorkCount: queuedRequests.count,
            peakConcurrentWorkCount: peakConcurrentWorkCount,
            droppedQueuedWorkCount: droppedQueuedWorkCount
        )
    }

    @discardableResult
    func acquire(
        _ request: ChatLocationSnapshotRequest,
        consumer: ChatLocationSnapshotConsumer,
        completion: ((Result<ChatLocationSnapshotDelivery, ChatLocationSnapshotPipelineError>) -> Void)?
    ) -> ChatLocationSnapshotSubscription {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        let entry = ConsumerEntry(consumer: consumer, completion: completion)
        if let work = workByRequest[request] {
            work.consumers[id] = entry
            deduplicatedAcquireCount += 1
            if consumer.role.isVisible, work.state == .queued {
                queuedRequests.removeAll { $0 == request }
                queuedRequests.insert(request, at: 0)
            }
            return subscription(request: request, id: id)
        }

        if activeWorkCount >= maxConcurrentWork,
           queuedRequests.count >= maxQueuedWork {
            droppedQueuedWorkCount += 1
            deliver(completion, result: .failure(.queueOverflow))
            return ChatLocationSnapshotSubscriptionToken(cancel: {})
        }

        let work = Work(request: request, id: id, entry: entry)
        workByRequest[request] = work
        if consumer.role.isVisible {
            queuedRequests.insert(request, at: 0)
        } else {
            queuedRequests.append(request)
        }
        drainLocked()
        return subscription(request: request, id: id)
    }

    private func subscription(
        request: ChatLocationSnapshotRequest,
        id: UUID
    ) -> ChatLocationSnapshotSubscription {
        ChatLocationSnapshotSubscriptionToken { [weak self] in
            self?.cancel(request: request, id: id)
        }
    }

    private func cancel(request: ChatLocationSnapshotRequest, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let work = workByRequest[request],
              work.consumers.removeValue(forKey: id) != nil,
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
        drainLocked()
    }

    private func drainLocked() {
        while activeWorkCount < maxConcurrentWork, !queuedRequests.isEmpty {
            let request = queuedRequests.removeFirst()
            guard let work = workByRequest[request], work.state == .queued else { continue }
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

    private func finish(
        request: ChatLocationSnapshotRequest,
        work: Work?,
        result: Result<ChatLocationSnapshotArtifact, ChatLocationSnapshotPipelineError>
    ) {
        lock.lock()
        guard let work,
              workByRequest[request] === work,
              work.state == .running else {
            lock.unlock()
            return
        }
        workByRequest.removeValue(forKey: request)
        activeWorkCount = max(0, activeWorkCount - 1)
        let callbacks = work.consumers.values.compactMap(\.completion)
        drainLocked()
        lock.unlock()

        let delivery = result.map {
            ChatLocationSnapshotDelivery(image: $0.image, source: .loader)
        }
        callbacks.forEach { deliver($0, result: delivery) }
    }

    private func deliver(
        _ completion: ((Result<ChatLocationSnapshotDelivery, ChatLocationSnapshotPipelineError>) -> Void)?,
        result: Result<ChatLocationSnapshotDelivery, ChatLocationSnapshotPipelineError>
    ) {
        guard let completion else { return }
        if Thread.isMainThread {
            completion(result)
        } else {
            DispatchQueue.main.async { completion(result) }
        }
    }
}

private extension ChatLocationSnapshotConsumer.Role {
    var isVisible: Bool {
        if case .visible = self { return true }
        return false
    }
}

private final class ChatLocationSnapshotSubscriptionToken: ChatLocationSnapshotSubscription {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        cancellation = cancel
    }

    func cancel() {
        lock.lock()
        let cancellation = self.cancellation
        self.cancellation = nil
        lock.unlock()
        cancellation?()
    }

    deinit {
        cancel()
    }
}

struct ChatLocationSnapshotDiskCacheMetrics {
    let entryCount: Int
    let totalBytes: Int
    let memoryEntryCount: Int
    let memoryBytes: Int
    let mainThreadFileAccessCount: Int
}

final class ChatLocationSnapshotDiskCache {
    private struct MemoryEntry {
        let artifact: ChatLocationSnapshotArtifact
        let timestamp: Date
        let byteCost: Int
    }

    private let directoryURL: URL
    private let maxEntryCount: Int
    private let maxDiskBytes: Int
    private let maxMemoryEntryCount: Int
    private let maxMemoryBytes: Int
    private let ttl: TimeInterval
    private let fileManager: FileManager
    private let now: () -> Date
    private let queue = DispatchQueue(
        label: "com.xabber.chat.location-snapshot-cache",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private var memory: [ChatLocationSnapshotRequest: MemoryEntry] = [:]
    private var memoryOrder: [ChatLocationSnapshotRequest] = []
    private var memoryBytes = 0
    private var mainThreadFileAccessCount = 0

    init(
        directoryURL: URL,
        maxEntryCount: Int,
        maxDiskBytes: Int,
        ttl: TimeInterval,
        maxMemoryEntryCount: Int? = nil,
        maxMemoryBytes: Int = 24 * 1_024 * 1_024,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.directoryURL = directoryURL
        self.maxEntryCount = max(0, maxEntryCount)
        self.maxDiskBytes = max(0, maxDiskBytes)
        self.maxMemoryEntryCount = max(0, min(maxEntryCount, maxMemoryEntryCount ?? 12))
        self.maxMemoryBytes = max(0, maxMemoryBytes)
        self.ttl = max(0, ttl)
        self.fileManager = fileManager
        self.now = now
    }

    func load(
        _ request: ChatLocationSnapshotRequest,
        completion: @escaping (ChatLocationSnapshotArtifact?) -> Void
    ) {
        queue.async {
            if let entry = self.memory[request], self.isFresh(entry.timestamp) {
                self.touchMemory(request)
                completion(entry.artifact)
                return
            }
            self.removeMemory(request)
            self.memoryOrder.removeAll { $0 == request }
            self.recordFileAccess()
            let url = self.fileURL(for: request)
            guard let attributes = try? self.fileManager.attributesOfItem(atPath: url.path),
                  let modificationDate = attributes[.modificationDate] as? Date,
                  self.isFresh(modificationDate),
                  let data = try? Data(contentsOf: url),
                  let encodedImage = UIImage(data: data, scale: CGFloat(request.scale)) else {
                try? self.fileManager.removeItem(at: url)
                completion(nil)
                return
            }
            let image = encodedImage.preparingForDisplay() ?? encodedImage
            let artifact = ChatLocationSnapshotArtifact(image: image, pngData: data)
            self.insertMemory(artifact, request: request, timestamp: modificationDate)
            completion(artifact)
        }
    }

    func store(
        _ artifact: ChatLocationSnapshotArtifact,
        for request: ChatLocationSnapshotRequest,
        completion: @escaping () -> Void
    ) {
        queue.async {
            self.recordFileAccess()
            do {
                try self.fileManager.createDirectory(
                    at: self.directoryURL,
                    withIntermediateDirectories: true
                )
                let timestamp = self.now()
                let url = self.fileURL(for: request)
                try artifact.pngData.write(to: url, options: .atomic)
                try self.fileManager.setAttributes(
                    [.modificationDate: timestamp],
                    ofItemAtPath: url.path
                )
                self.insertMemory(artifact, request: request, timestamp: timestamp)
                self.cleanupLocked()
            } catch {
                // A cache write failure must never block visible delivery.
            }
            completion()
        }
    }

    func cleanup(completion: @escaping () -> Void) {
        queue.async {
            self.recordFileAccess()
            self.cleanupLocked()
            completion()
        }
    }

    func inspect(completion: @escaping (ChatLocationSnapshotDiskCacheMetrics) -> Void) {
        queue.async {
            self.recordFileAccess()
            let files = self.cacheFiles()
            let bytes = files.reduce(0) { result, file in
                result + (self.fileSize(file) ?? 0)
            }
            completion(ChatLocationSnapshotDiskCacheMetrics(
                entryCount: files.count,
                totalBytes: bytes,
                memoryEntryCount: self.memory.count,
                memoryBytes: self.memoryBytes,
                mainThreadFileAccessCount: self.mainThreadFileAccessCount
            ))
        }
    }

    private func insertMemory(
        _ artifact: ChatLocationSnapshotArtifact,
        request: ChatLocationSnapshotRequest,
        timestamp: Date
    ) {
        removeMemory(request)
        let byteCost = Self.memoryByteCost(artifact: artifact, request: request)
        memory[request] = MemoryEntry(
            artifact: artifact,
            timestamp: timestamp,
            byteCost: byteCost
        )
        memoryBytes += byteCost
        touchMemory(request)
        while (memoryOrder.count > maxMemoryEntryCount || memoryBytes > maxMemoryBytes),
              let oldest = memoryOrder.first {
            memoryOrder.removeFirst()
            removeMemory(oldest)
        }
    }

    private func touchMemory(_ request: ChatLocationSnapshotRequest) {
        memoryOrder.removeAll { $0 == request }
        memoryOrder.append(request)
    }

    private func cleanupLocked() {
        let current = now()
        let expiredMemoryRequests = memory.compactMap { request, entry in
            current.timeIntervalSince(entry.timestamp) > ttl ? request : nil
        }
        expiredMemoryRequests.forEach(removeMemory)
        memoryOrder.removeAll { memory[$0] == nil }

        var files = cacheFiles().compactMap { url -> (URL, Date, Int)? in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let modificationDate = attributes[.modificationDate] as? Date else {
                try? fileManager.removeItem(at: url)
                return nil
            }
            return (url, modificationDate, (attributes[.size] as? NSNumber)?.intValue ?? 0)
        }
        files.filter { current.timeIntervalSince($0.1) > ttl }.forEach {
            try? fileManager.removeItem(at: $0.0)
        }
        files.removeAll { current.timeIntervalSince($0.1) > ttl }
        files.sort { $0.1 < $1.1 }
        var totalBytes = files.reduce(0) { $0 + $1.2 }
        while files.count > maxEntryCount || totalBytes > maxDiskBytes {
            let removed = files.removeFirst()
            totalBytes -= removed.2
            try? fileManager.removeItem(at: removed.0)
        }
    }

    private func cacheFiles() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension.lowercased() == "png" } ?? []
    }

    private func fileURL(for request: ChatLocationSnapshotRequest) -> URL {
        directoryURL.appendingPathComponent("loc-\(Self.stableHash(request.cacheKey)).png")
    }

    private func isFresh(_ date: Date) -> Bool {
        now().timeIntervalSince(date) <= ttl
    }

    private func fileSize(_ url: URL) -> Int? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    private func removeMemory(_ request: ChatLocationSnapshotRequest) {
        guard let removed = memory.removeValue(forKey: request) else { return }
        memoryBytes = max(0, memoryBytes - removed.byteCost)
    }

    private static func memoryByteCost(
        artifact: ChatLocationSnapshotArtifact,
        request: ChatLocationSnapshotRequest
    ) -> Int {
        let decodedBytes = Int(ceil(request.pixelSize.width * request.pixelSize.height * 4))
        return max(0, decodedBytes) + artifact.pngData.count
    }

    private func recordFileAccess() {
        if Thread.isMainThread {
            mainThreadFileAccessCount += 1
        }
    }

    private static func stableHash(_ value: String) -> String {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }.description
    }
}

private final class MapKitChatLocationSnapshotLoadTask: ChatLocationSnapshotLoadTask {
    private let lock = NSLock()
    private var isCancelled = false
    private weak var snapshotter: MKMapSnapshotter?

    func install(_ snapshotter: MKMapSnapshotter) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        self.snapshotter = snapshotter
        return true
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let snapshotter = self.snapshotter
        lock.unlock()
        snapshotter?.cancel()
    }

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }
}

final class MapKitChatLocationSnapshotLoader: ChatLocationSnapshotLoading {
    private let cache: ChatLocationSnapshotDiskCache
    private let processingQueue = DispatchQueue(
        label: "com.xabber.chat.location-snapshot-processing",
        qos: .userInitiated,
        attributes: [.concurrent],
        autoreleaseFrequency: .workItem
    )

    init(cache: ChatLocationSnapshotDiskCache) {
        self.cache = cache
    }

    func load(
        _ request: ChatLocationSnapshotRequest,
        completion: @escaping (Result<ChatLocationSnapshotArtifact, ChatLocationSnapshotPipelineError>) -> Void
    ) -> ChatLocationSnapshotLoadTask {
        let task = MapKitChatLocationSnapshotLoadTask()
        cache.load(request) { [weak self, weak task] cached in
            guard let self, let task, !task.cancelled else { return }
            if let cached {
                completion(.success(cached))
                return
            }
            if let sourceURL = request.sourceURL {
                self.loadSourceURL(sourceURL, request: request, task: task, completion: completion)
            } else {
                self.startMapSnapshot(request: request, task: task, completion: completion)
            }
        }
        return task
    }

    private func loadSourceURL(
        _ url: URL,
        request: ChatLocationSnapshotRequest,
        task: MapKitChatLocationSnapshotLoadTask,
        completion: @escaping (Result<ChatLocationSnapshotArtifact, ChatLocationSnapshotPipelineError>) -> Void
    ) {
        processingQueue.async { [weak self, weak task] in
            guard let self, let task, !task.cancelled,
                  let artifact = Self.downsampledArtifact(url: url, request: request) else {
                if task?.cancelled == false { completion(.failure(.loadFailed)) }
                return
            }
            self.cache.store(artifact, for: request) {
                guard !task.cancelled else { return }
                completion(.success(artifact))
            }
        }
    }

    private func startMapSnapshot(
        request: ChatLocationSnapshotRequest,
        task: MapKitChatLocationSnapshotLoadTask,
        completion: @escaping (Result<ChatLocationSnapshotArtifact, ChatLocationSnapshotPipelineError>) -> Void
    ) {
        DispatchQueue.main.async { [weak self, weak task] in
            guard let self, let task, !task.cancelled else { return }
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: request.latitude, longitude: request.longitude),
                latitudinalMeters: 1_000,
                longitudinalMeters: 1_000
            )
            options.size = request.displaySize.cgSize
            options.scale = CGFloat(request.scale)
            options.mapType = request.mapStyle.mapType
            let snapshotter = MKMapSnapshotter(options: options)
            guard task.install(snapshotter) else { return }
            snapshotter.start { [weak self, weak task] snapshot, _ in
                guard let self, let task, !task.cancelled, let snapshot else {
                    if task?.cancelled == false { completion(.failure(.loadFailed)) }
                    return
                }
                self.processingQueue.async { [weak task] in
                    guard let task, !task.cancelled,
                          let artifact = Self.processedArtifact(
                            image: snapshot.image,
                            request: request,
                            drawsMarker: true
                          ) else {
                        if task?.cancelled == false { completion(.failure(.imageEncodingFailed)) }
                        return
                    }
                    self.cache.store(artifact, for: request) {
                        guard !task.cancelled else { return }
                        completion(.success(artifact))
                    }
                }
            }
        }
    }

    private static func downsampledArtifact(
        url: URL,
        request: ChatLocationSnapshotRequest
    ) -> ChatLocationSnapshotArtifact? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let maximum = max(request.pixelSize.width, request.pixelSize.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(ceil(maximum))
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = UIImage(cgImage: cgImage, scale: CGFloat(request.scale), orientation: .up)
        return processedArtifact(image: image, request: request, drawsMarker: false)
    }

    private static func processedArtifact(
        image: UIImage,
        request: ChatLocationSnapshotRequest,
        drawsMarker: Bool
    ) -> ChatLocationSnapshotArtifact? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = CGFloat(request.scale)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: request.displaySize.cgSize, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: request.displaySize.cgSize))
            guard drawsMarker else { return }
            let size = request.displaySize.cgSize
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = max(6, min(size.width, size.height) * 0.035)
            let markerRect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            UIColor.systemRed.setFill()
            UIBezierPath(ovalIn: markerRect).fill()
            UIColor.white.setStroke()
            let ring = UIBezierPath(ovalIn: markerRect.insetBy(dx: -2, dy: -2))
            ring.lineWidth = 3
            ring.stroke()
        }
        guard let data = rendered.pngData() else { return nil }
        return ChatLocationSnapshotArtifact(image: rendered, pngData: data)
    }
}
