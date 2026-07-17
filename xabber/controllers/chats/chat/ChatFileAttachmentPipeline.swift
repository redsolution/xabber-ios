import Foundation

struct ChatFileAttachmentRequest: Hashable {
    let containerPrimary: String
    let referencePrimary: String
    let resourceIdentity: String
    let presentationRevision: String
}

enum ChatFileTransferState: Equatable {
    case idle
    case transferring(progress: Double)
    case available
    case failed

    var normalized: ChatFileTransferState {
        guard case .transferring(let progress) = self else { return self }
        return .transferring(progress: min(max(progress, 0), 1))
    }
}

protocol ChatFileTransferSubscription: AnyObject {
    func cancel()
}

protocol ChatFileTransferServing: AnyObject {
    @discardableResult
    func subscribe(
        to request: ChatFileAttachmentRequest,
        consumerID: UUID,
        receive: @escaping (ChatFileTransferState) -> Void
    ) -> ChatFileTransferSubscription

    func publish(_ state: ChatFileTransferState, for request: ChatFileAttachmentRequest)
}

protocol ChatOffscreenWorkManaging: AnyObject {
    func cancelOffscreenWork()
    func resumeOnscreenWork()
}

struct ChatFileAttachmentPipelineMetrics: Equatable {
    let activeSubscriptionCount: Int
    let peakSubscriptionCount: Int
    let publishedStateCount: Int
    let metadataPrefetchCount: Int
    let retainedStateCount: Int
    let fullDocumentDownloadCount: Int
}

/// A state-only file attachment bus. It intentionally owns no URLSession and
/// cannot start a document payload download. Existing transfer owners publish
/// progress/completion while visible views hold cancellable subscriptions.
final class ChatFileAttachmentPipeline: ChatFileTransferServing {
    static let shared = ChatFileAttachmentPipeline()

    private struct Observer {
        let consumerID: UUID
        let receive: (ChatFileTransferState) -> Void
    }

    private struct ConsumerRegistration {
        let request: ChatFileAttachmentRequest
        let subscriptionID: UUID
    }

    private let lock = NSLock()
    private var observersByRequest: [ChatFileAttachmentRequest: [UUID: Observer]] = [:]
    private var registrationByConsumer: [UUID: ConsumerRegistration] = [:]
    private var peakSubscriptionCount = 0
    private var publishedStateCount = 0
    private var metadataPrefetchCount = 0

    var metrics: ChatFileAttachmentPipelineMetrics {
        lock.lock()
        defer { lock.unlock() }
        return ChatFileAttachmentPipelineMetrics(
            activeSubscriptionCount: registrationByConsumer.count,
            peakSubscriptionCount: peakSubscriptionCount,
            publishedStateCount: publishedStateCount,
            metadataPrefetchCount: metadataPrefetchCount,
            retainedStateCount: 0,
            fullDocumentDownloadCount: 0
        )
    }

    @discardableResult
    func subscribe(
        to request: ChatFileAttachmentRequest,
        consumerID: UUID,
        receive: @escaping (ChatFileTransferState) -> Void
    ) -> ChatFileTransferSubscription {
        let subscriptionID = UUID()
        lock.lock()
        if let existing = registrationByConsumer.removeValue(forKey: consumerID) {
            removeObserverLocked(existing)
        }
        observersByRequest[request, default: [:]][subscriptionID] = Observer(
            consumerID: consumerID,
            receive: receive
        )
        registrationByConsumer[consumerID] = ConsumerRegistration(
            request: request,
            subscriptionID: subscriptionID
        )
        peakSubscriptionCount = max(peakSubscriptionCount, registrationByConsumer.count)
        lock.unlock()
        return ChatFileTransferSubscriptionToken { [weak self] in
            self?.cancel(
                request: request,
                consumerID: consumerID,
                subscriptionID: subscriptionID
            )
        }
    }

    func publish(_ state: ChatFileTransferState, for request: ChatFileAttachmentRequest) {
        let state = state.normalized
        let callbacks: [(ChatFileTransferState) -> Void]
        lock.lock()
        publishedStateCount += 1
        callbacks = observersByRequest[request]?.values.map(\.receive) ?? []
        lock.unlock()
        callbacks.forEach { deliver(state, to: $0) }
    }

    /// Warms only immutable in-memory metadata already carried by the model.
    /// There is deliberately no API here that can fetch the document URL.
    func prefetchMetadata(for attachment: FileAttachment) {
        _ = attachment.presentation
        lock.lock()
        metadataPrefetchCount += 1
        lock.unlock()
    }

    private func cancel(
        request: ChatFileAttachmentRequest,
        consumerID: UUID,
        subscriptionID: UUID
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let registration = registrationByConsumer[consumerID],
              registration.request == request,
              registration.subscriptionID == subscriptionID else {
            return
        }
        registrationByConsumer.removeValue(forKey: consumerID)
        removeObserverLocked(registration)
    }

    private func removeObserverLocked(_ registration: ConsumerRegistration) {
        observersByRequest[registration.request]?.removeValue(
            forKey: registration.subscriptionID
        )
        if observersByRequest[registration.request]?.isEmpty == true {
            observersByRequest.removeValue(forKey: registration.request)
        }
    }

    private func deliver(
        _ state: ChatFileTransferState,
        to receive: @escaping (ChatFileTransferState) -> Void
    ) {
        if Thread.isMainThread {
            receive(state)
        } else {
            DispatchQueue.main.async {
                receive(state)
            }
        }
    }
}

private final class ChatFileTransferSubscriptionToken: ChatFileTransferSubscription {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
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
