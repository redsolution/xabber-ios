import Foundation
import LetterAvatarKit
import MaterialComponents.MDCPalettes
import UIKit

struct ChatGeneratedAvatarRequest: Hashable {
    let entityIdentity: String
    let displayName: String
    let colorKey: String
    let displaySize: ChatCollectionPrefetchSize
    let scale: Double
    let traitStyle: ChatThumbnailTraitStyle

    var pixelSize: ChatCollectionPrefetchSize {
        displaySize.scaled(by: scale)
    }
}

struct ChatAvatarRequest: Hashable {
    let entityIdentity: String
    let remoteURL: URL?
    let displayName: String
    let colorKey: String
    let displaySize: ChatCollectionPrefetchSize
    let scale: Double
    let traitStyle: ChatThumbnailTraitStyle

    init(
        entityIdentity: String,
        remoteURL: URL?,
        displayName: String,
        colorKey: String,
        displaySize: ChatCollectionPrefetchSize,
        scale: Double,
        traitStyle: ChatThumbnailTraitStyle
    ) {
        self.entityIdentity = entityIdentity
        self.remoteURL = remoteURL
        self.displayName = displayName
        self.colorKey = colorKey
        self.displaySize = ChatCollectionPrefetchSize(
            width: max(1, displaySize.width),
            height: max(1, displaySize.height)
        )
        self.scale = max(1, scale)
        self.traitStyle = traitStyle
    }

    var thumbnailRequest: ChatThumbnailRequest? {
        remoteURL.map {
            ChatThumbnailRequest(
                url: $0,
                displaySize: displaySize,
                scale: scale,
                traitStyle: traitStyle
            )
        }
    }

    var generatedRequest: ChatGeneratedAvatarRequest {
        ChatGeneratedAvatarRequest(
            entityIdentity: entityIdentity,
            displayName: displayName,
            colorKey: colorKey,
            displaySize: displaySize,
            scale: scale,
            traitStyle: traitStyle
        )
    }
}

struct ChatAvatarConsumer: Hashable {
    enum Role: Hashable {
        case prefetch
        case visible(UUID)
    }

    let identity: ChatCollectionPrefetchIdentity
    let role: Role
}

struct ChatAvatarDelivery {
    enum Source: Equatable {
        case remote
        case generated
        case generatedMemoryCache
    }

    let image: UIImage
    let source: Source
}

enum ChatAvatarPipelineError: Error, Equatable {
    case unavailable
}

protocol ChatAvatarSubscription: AnyObject {
    func cancel()
}

protocol ChatAvatarServing: AnyObject {
    @discardableResult
    func acquire(
        _ request: ChatAvatarRequest,
        consumer: ChatAvatarConsumer,
        completion: ((Result<ChatAvatarDelivery, ChatAvatarPipelineError>) -> Void)?
    ) -> ChatAvatarSubscription
}

protocol ChatGeneratedAvatarTask: AnyObject {
    func cancel()
}

protocol ChatGeneratedAvatarRendering: AnyObject {
    func render(
        _ request: ChatGeneratedAvatarRequest,
        completion: @escaping (UIImage?) -> Void
    ) -> ChatGeneratedAvatarTask
}

final class ChatGeneratedAvatarMemoryCache {
    private let capacity: Int
    private let lock = NSLock()
    private var images: [ChatGeneratedAvatarRequest: UIImage] = [:]
    private var order: [ChatGeneratedAvatarRequest] = []

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return images.count
    }

    func image(for request: ChatGeneratedAvatarRequest) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let image = images[request] else { return nil }
        order.removeAll { $0 == request }
        order.append(request)
        return image
    }

    func store(_ image: UIImage, for request: ChatGeneratedAvatarRequest) {
        lock.lock()
        defer { lock.unlock() }
        guard capacity > 0 else { return }
        images[request] = image
        order.removeAll { $0 == request }
        order.append(request)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            images.removeValue(forKey: oldest)
        }
    }

    func removeAll() {
        lock.lock()
        images.removeAll()
        order.removeAll()
        lock.unlock()
    }
}

struct ChatAvatarPipelineMetrics {
    let generatedRenderCount: Int
    let generatedMemoryCacheHitCount: Int
    let deduplicatedGeneratedAcquireCount: Int
    let activeGeneratedWorkCount: Int
}

final class ChatAvatarPipeline: ChatAvatarServing {
    static let shared = ChatAvatarPipeline(
        thumbnailPipeline: ChatMediaThumbnailPipeline.shared,
        renderer: LetterChatGeneratedAvatarRenderer(),
        generatedCache: ChatGeneratedAvatarMemoryCache(
            capacity: ChatPerformanceResourceBudgets.generatedAvatarCount
        )
    )

    private final class DeliveryState {
        private let lock = NSLock()
        private var cancelled = false
        private var completed = false
        private var remote: ChatThumbnailSubscription?
        private var generated: ChatAvatarSubscription?

        var isOpen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !cancelled && !completed
        }

        func installRemote(_ subscription: ChatThumbnailSubscription) {
            lock.lock()
            if cancelled || completed {
                lock.unlock()
                subscription.cancel()
                return
            }
            remote = subscription
            lock.unlock()
        }

        func installGenerated(_ subscription: ChatAvatarSubscription) {
            lock.lock()
            if cancelled || completed {
                lock.unlock()
                subscription.cancel()
                return
            }
            generated = subscription
            lock.unlock()
        }

        func complete() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled, !completed else { return false }
            completed = true
            remote = nil
            generated = nil
            return true
        }

        func cancel() {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                return
            }
            cancelled = true
            let remote = self.remote
            let generated = self.generated
            self.remote = nil
            self.generated = nil
            lock.unlock()
            remote?.cancel()
            generated?.cancel()
        }
    }

    private struct GeneratedConsumerEntry {
        let state: DeliveryState
        let completion: ((Result<ChatAvatarDelivery, ChatAvatarPipelineError>) -> Void)?
    }

    private final class GeneratedWork {
        let request: ChatGeneratedAvatarRequest
        var consumers: [UUID: GeneratedConsumerEntry]
        var task: ChatGeneratedAvatarTask?

        init(request: ChatGeneratedAvatarRequest, id: UUID, entry: GeneratedConsumerEntry) {
            self.request = request
            self.consumers = [id: entry]
        }
    }

    private let thumbnailPipeline: ChatThumbnailServing
    private let renderer: ChatGeneratedAvatarRendering
    private let generatedCache: ChatGeneratedAvatarMemoryCache
    private let generationQueue = DispatchQueue(
        label: "com.xabber.chat.generated-avatar",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private let lock = NSRecursiveLock()
    private var generatedWork: [ChatGeneratedAvatarRequest: GeneratedWork] = [:]
    private var generatedRenderCount = 0
    private var generatedMemoryCacheHitCount = 0
    private var deduplicatedGeneratedAcquireCount = 0

    init(
        thumbnailPipeline: ChatThumbnailServing,
        renderer: ChatGeneratedAvatarRendering,
        generatedCache: ChatGeneratedAvatarMemoryCache
    ) {
        self.thumbnailPipeline = thumbnailPipeline
        self.renderer = renderer
        self.generatedCache = generatedCache
    }

    var metrics: ChatAvatarPipelineMetrics {
        lock.lock()
        defer { lock.unlock() }
        return ChatAvatarPipelineMetrics(
            generatedRenderCount: generatedRenderCount,
            generatedMemoryCacheHitCount: generatedMemoryCacheHitCount,
            deduplicatedGeneratedAcquireCount: deduplicatedGeneratedAcquireCount,
            activeGeneratedWorkCount: generatedWork.count
        )
    }

    /// Visible/generated work remains owned by its subscriptions; memory
    /// pressure evicts only recomputable avatar values.
    func handleMemoryWarning() {
        generatedCache.removeAll()
    }

    @discardableResult
    func acquire(
        _ request: ChatAvatarRequest,
        consumer: ChatAvatarConsumer,
        completion: ((Result<ChatAvatarDelivery, ChatAvatarPipelineError>) -> Void)?
    ) -> ChatAvatarSubscription {
        let state = DeliveryState()
        let outer = ChatAvatarSubscriptionToken { state.cancel() }
        guard let thumbnailRequest = request.thumbnailRequest else {
            let generated = acquireGenerated(
                request.generatedRequest,
                state: state,
                completion: completion
            )
            state.installGenerated(generated)
            return outer
        }

        let remote = thumbnailPipeline.acquire(
            thumbnailRequest,
            consumer: ChatThumbnailConsumer(
                identity: consumer.identity,
                role: consumer.role.thumbnailRole
            )
        ) { [weak self, weak state] result in
            guard let self, let state, state.isOpen else { return }
            switch result {
            case .success(let delivery):
                self.complete(
                    state: state,
                    completion: completion,
                    result: .success(ChatAvatarDelivery(image: delivery.image, source: .remote))
                )
            case .failure:
                guard state.isOpen else { return }
                let generated = self.acquireGenerated(
                    request.generatedRequest,
                    state: state,
                    completion: completion
                )
                state.installGenerated(generated)
            }
        }
        state.installRemote(remote)
        return outer
    }

    private func acquireGenerated(
        _ request: ChatGeneratedAvatarRequest,
        state: DeliveryState,
        completion: ((Result<ChatAvatarDelivery, ChatAvatarPipelineError>) -> Void)?
    ) -> ChatAvatarSubscription {
        lock.lock()
        defer { lock.unlock() }
        if let image = generatedCache.image(for: request) {
            generatedMemoryCacheHitCount += 1
            complete(
                state: state,
                completion: completion,
                result: .success(ChatAvatarDelivery(image: image, source: .generatedMemoryCache))
            )
            return ChatAvatarSubscriptionToken(cancel: {})
        }

        let id = UUID()
        let entry = GeneratedConsumerEntry(state: state, completion: completion)
        if let work = generatedWork[request] {
            work.consumers[id] = entry
            deduplicatedGeneratedAcquireCount += 1
            return generatedSubscription(request: request, id: id)
        }

        let work = GeneratedWork(request: request, id: id, entry: entry)
        generatedWork[request] = work
        generatedRenderCount += 1
        generationQueue.async { [weak self, weak work] in
            guard let self, let work else { return }
            self.lock.lock()
            let stillActive = self.generatedWork[request] === work
            self.lock.unlock()
            guard stillActive else { return }
            let task = self.renderer.render(request) { [weak self, weak work] image in
                self?.finishGenerated(request: request, work: work, image: image)
            }
            self.lock.lock()
            if self.generatedWork[request] === work {
                work.task = task
                self.lock.unlock()
            } else {
                self.lock.unlock()
                task.cancel()
            }
        }
        return generatedSubscription(request: request, id: id)
    }

    private func generatedSubscription(
        request: ChatGeneratedAvatarRequest,
        id: UUID
    ) -> ChatAvatarSubscription {
        ChatAvatarSubscriptionToken { [weak self] in
            self?.cancelGenerated(request: request, id: id)
        }
    }

    private func cancelGenerated(request: ChatGeneratedAvatarRequest, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let work = generatedWork[request],
              work.consumers.removeValue(forKey: id) != nil,
              work.consumers.isEmpty else {
            return
        }
        generatedWork.removeValue(forKey: request)
        work.task?.cancel()
    }

    private func finishGenerated(
        request: ChatGeneratedAvatarRequest,
        work: GeneratedWork?,
        image: UIImage?
    ) {
        lock.lock()
        guard let work, generatedWork[request] === work else {
            lock.unlock()
            return
        }
        generatedWork.removeValue(forKey: request)
        let consumers = Array(work.consumers.values)
        if let image {
            generatedCache.store(image, for: request)
        }
        lock.unlock()

        consumers.forEach { entry in
            if let image {
                complete(
                    state: entry.state,
                    completion: entry.completion,
                    result: .success(ChatAvatarDelivery(image: image, source: .generated))
                )
            } else {
                complete(
                    state: entry.state,
                    completion: entry.completion,
                    result: .failure(.unavailable)
                )
            }
        }
    }

    private func complete(
        state: DeliveryState,
        completion: ((Result<ChatAvatarDelivery, ChatAvatarPipelineError>) -> Void)?,
        result: Result<ChatAvatarDelivery, ChatAvatarPipelineError>
    ) {
        guard state.complete(), let completion else { return }
        if Thread.isMainThread {
            completion(result)
        } else {
            DispatchQueue.main.async { completion(result) }
        }
    }
}

private extension ChatAvatarConsumer.Role {
    var thumbnailRole: ChatThumbnailConsumer.Role {
        switch self {
        case .prefetch: return .prefetch
        case .visible(let id): return .visible(id)
        }
    }
}

private final class ChatAvatarSubscriptionToken: ChatAvatarSubscription {
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

private final class LetterChatGeneratedAvatarTask: ChatGeneratedAvatarTask {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

final class LetterChatGeneratedAvatarRenderer: ChatGeneratedAvatarRendering {
    private static let palettes: [MDCPalette] = [
        .green, .orange, .red, .blue, .indigo, .blueGrey, .cyan,
        .purple, .lime, .pink, .lightBlue, .lightGreen, .deepOrange,
        .brown, .amber
    ]

    func render(
        _ request: ChatGeneratedAvatarRequest,
        completion: @escaping (UIImage?) -> Void
    ) -> ChatGeneratedAvatarTask {
        let task = LetterChatGeneratedAvatarTask()
        let pixelSide = CGFloat(max(request.pixelSize.width, request.pixelSize.height))
        let palette = Self.palettes[Self.paletteIndex(for: request.colorKey)]
        let configuration = LetterAvatarBuilderConfiguration()
        configuration.useSingleLetter = true
        configuration.username = request.displayName.capitalized
        configuration.backgroundColors = [palette.tint100, palette.tint200]
        configuration.lettersColor = palette.tint900
        configuration.size = CGSize(square: pixelSide)
        let rendered = UIImage.makeLetterAvatar(withConfiguration: configuration)
        let scaled: UIImage?
        if let cgImage = rendered?.cgImage {
            scaled = UIImage(
                cgImage: cgImage,
                scale: CGFloat(request.scale),
                orientation: rendered?.imageOrientation ?? .up
            )
        } else {
            scaled = rendered
        }
        if !task.isCancelled {
            completion(scaled)
        }
        return task
    }

    private static func paletteIndex(for value: String) -> Int {
        let hash = value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return Int(hash % UInt64(palettes.count))
    }
}
