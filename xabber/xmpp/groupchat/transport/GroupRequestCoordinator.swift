import Foundation

struct GroupRequestIQError: Error, Equatable {
    let condition: String
    let text: String?

    init(condition: String, text: String? = nil) {
        self.condition = condition
        self.text = text
    }
}

enum GroupRequestError: Error, Equatable {
    case iq(GroupRequestIQError)
    case timeout
    case disconnected
    case duplicateRequestID(String)
}

enum GroupRequestResponse<Payload> {
    case result(Payload)
    case error(GroupRequestIQError)
}

enum GroupRequestRegistrationDisposition: Equatable {
    case accepted
    case rejectedDuplicateRequestID
}

enum GroupRequestResponseDisposition: Equatable {
    case completed
    case ignored
}

protocol GroupRequestTimeoutCancellation: AnyObject {
    func cancel()
}

protocol GroupRequestTimeoutScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> GroupRequestTimeoutCancellation
}

final class DispatchGroupRequestTimeoutScheduler: GroupRequestTimeoutScheduling {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> GroupRequestTimeoutCancellation {
        let workItem = DispatchWorkItem(block: action)
        queue.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: workItem
        )
        return DispatchGroupRequestTimeoutCancellation(workItem: workItem)
    }
}

private final class DispatchGroupRequestTimeoutCancellation: GroupRequestTimeoutCancellation {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

final class GroupRequestCoordinator<Payload> {
    typealias Completion = (Result<Payload, GroupRequestError>) -> Void

    private final class PendingRequest {
        let generation: UInt64
        let completion: Completion
        var timeoutCancellation: GroupRequestTimeoutCancellation?

        init(generation: UInt64, completion: @escaping Completion) {
            self.generation = generation
            self.completion = completion
        }
    }

    private let defaultTimeout: TimeInterval
    private let scheduler: GroupRequestTimeoutScheduling
    private let stateQueue = DispatchQueue(
        label: "com.xabber.group-request-coordinator.state"
    )
    private var pendingRequests: [String: PendingRequest] = [:]
    private var nextGeneration: UInt64 = 0

    init(
        defaultTimeout: TimeInterval,
        scheduler: GroupRequestTimeoutScheduling = DispatchGroupRequestTimeoutScheduler()
    ) {
        precondition(defaultTimeout >= 0, "Timeout must not be negative")
        self.defaultTimeout = defaultTimeout
        self.scheduler = scheduler
    }

    var pendingRequestCount: Int {
        stateQueue.sync { pendingRequests.count }
    }

    @discardableResult
    func registerAndSend(
        id: String,
        timeout: TimeInterval? = nil,
        send: () -> Void,
        completion: @escaping Completion
    ) -> GroupRequestRegistrationDisposition {
        let request: PendingRequest? = stateQueue.sync {
            guard pendingRequests[id] == nil else {
                return nil
            }

            nextGeneration &+= 1
            let request = PendingRequest(
                generation: nextGeneration,
                completion: completion
            )
            pendingRequests[id] = request
            return request
        }

        guard let request else {
            completion(.failure(.duplicateRequestID(id)))
            return .rejectedDuplicateRequestID
        }

        let requestTimeout = timeout ?? defaultTimeout
        precondition(requestTimeout >= 0, "Timeout must not be negative")
        let requestGeneration = request.generation
        let timeoutCancellation = scheduler.schedule(
            after: requestTimeout,
            action: { [weak self] in
                self?.complete(
                    id: id,
                    expectedGeneration: requestGeneration,
                    result: .failure(.timeout)
                )
            }
        )

        let shouldSend = stateQueue.sync { () -> Bool in
            guard pendingRequests[id] === request else {
                return false
            }
            request.timeoutCancellation = timeoutCancellation
            return true
        }

        guard shouldSend else {
            timeoutCancellation.cancel()
            return .accepted
        }

        send()
        return .accepted
    }

    @discardableResult
    func receive(
        id: String,
        response: GroupRequestResponse<Payload>
    ) -> GroupRequestResponseDisposition {
        let result: Result<Payload, GroupRequestError>
        switch response {
        case let .result(payload):
            result = .success(payload)
        case let .error(error):
            result = .failure(.iq(error))
        }

        return complete(id: id, result: result) ? .completed : .ignored
    }

    @discardableResult
    func cancelPendingRequestsForDisconnect() -> Int {
        let requests: [PendingRequest] = stateQueue.sync {
            let requests = Array(pendingRequests.values)
            pendingRequests.removeAll(keepingCapacity: true)
            return requests
        }

        requests.forEach { request in
            request.timeoutCancellation?.cancel()
            request.completion(.failure(.disconnected))
        }
        return requests.count
    }

    @discardableResult
    private func complete(
        id: String,
        expectedGeneration: UInt64? = nil,
        result: Result<Payload, GroupRequestError>
    ) -> Bool {
        let request: PendingRequest? = stateQueue.sync {
            guard let request = pendingRequests[id] else {
                return nil
            }
            if let expectedGeneration,
               request.generation != expectedGeneration {
                return nil
            }
            pendingRequests.removeValue(forKey: id)
            return request
        }

        guard let request else {
            return false
        }
        request.timeoutCancellation?.cancel()
        request.completion(result)
        return true
    }
}
