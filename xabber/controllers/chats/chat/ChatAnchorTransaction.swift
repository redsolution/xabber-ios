import UIKit

struct ChatAnchorTransactionToken: Hashable {
    let rawValue: String

    init(rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }
}

enum ChatAnchorTransactionFailure: Hashable {
    case targetMissing
    case targetDeleted
    case ambiguous(candidateCount: Int)
    case candidateLimitExceeded(limit: Int)
    case timeout
    case iqError
    case disconnected
    case disappeared
    case superseded
}

enum ChatTimelineSearchMessageResolution {
    case found(MessageStorageItem)
    case failed(ChatAnchorTransactionFailure)

    var message: MessageStorageItem? {
        guard case .found(let message) = self else { return nil }
        return message
    }

    var failure: ChatAnchorTransactionFailure? {
        guard case .failed(let failure) = self else { return nil }
        return failure
    }
}

enum ChatAnchorTransactionTerminalOutcome: Equatable {
    case positioned
    case failed(ChatAnchorTransactionFailure)
}

enum ChatAnchorTransactionBoundary: Hashable {
    case remoteFinal(queryId: String)
    case remoteFailure(queryId: String)
    case persistence(queryId: String)
    case mapping
    case apply
    case scroll
}

enum ChatAnchorTransactionCallbackDisposition: Equatable {
    case accepted
    case duplicate
    case stale
}

enum ChatAnchorTransactionOwnership: Hashable {
    case query(String)
    case loader
    case scrollLock
}

struct ChatAnchorTransactionSnapshot: Equatable {
    let activeToken: ChatAnchorTransactionToken?
    let requestIdentity: String?
    let queryIds: Set<String>
    let ownsLoader: Bool
    let ownsScrollLock: Bool
    let positioningStarted: Bool
    let lastTerminalOutcome: ChatAnchorTransactionTerminalOutcome?
}

final class ChatAnchorTransactionGate {
    private struct ActiveTransaction {
        let token: ChatAnchorTransactionToken
        let requestIdentity: String
        var queryIds: Set<String> = []
        var ownsLoader = false
        var ownsScrollLock = false
        var positioningStarted = false
        var acceptedBoundaries: Set<ChatAnchorTransactionBoundary> = []
    }

    private var active: ActiveTransaction?
    private var lastTerminalOutcome: ChatAnchorTransactionTerminalOutcome?

    var snapshot: ChatAnchorTransactionSnapshot {
        ChatAnchorTransactionSnapshot(
            activeToken: active?.token,
            requestIdentity: active?.requestIdentity,
            queryIds: active?.queryIds ?? [],
            ownsLoader: active?.ownsLoader ?? false,
            ownsScrollLock: active?.ownsScrollLock ?? false,
            positioningStarted: active?.positioningStarted ?? false,
            lastTerminalOutcome: lastTerminalOutcome
        )
    }

    @discardableResult
    func begin(
        token: ChatAnchorTransactionToken,
        requestIdentity: String
    ) -> ChatAnchorTransactionToken? {
        let previousToken = active?.token
        if previousToken != nil {
            lastTerminalOutcome = .failed(.superseded)
        }
        active = ActiveTransaction(token: token, requestIdentity: requestIdentity)
        return previousToken
    }

    @discardableResult
    func acquire(
        _ ownership: ChatAnchorTransactionOwnership,
        token: ChatAnchorTransactionToken
    ) -> Bool {
        guard var transaction = active, transaction.token == token else {
            return false
        }

        switch ownership {
        case .query(let queryId):
            transaction.queryIds.insert(queryId)
        case .loader:
            transaction.ownsLoader = true
        case .scrollLock:
            transaction.ownsScrollLock = true
        }
        active = transaction
        return true
    }

    func accept(
        _ boundary: ChatAnchorTransactionBoundary,
        token: ChatAnchorTransactionToken
    ) -> ChatAnchorTransactionCallbackDisposition {
        guard var transaction = active, transaction.token == token else {
            return .stale
        }
        if let queryId = boundary.queryId, !transaction.queryIds.contains(queryId) {
            return .stale
        }
        guard transaction.acceptedBoundaries.insert(boundary).inserted else {
            return .duplicate
        }
        active = transaction
        return .accepted
    }

    @discardableResult
    func markPositioningStarted(token: ChatAnchorTransactionToken) -> Bool {
        guard var transaction = active,
              transaction.token == token,
              !transaction.positioningStarted else {
            return false
        }
        transaction.positioningStarted = true
        active = transaction
        return true
    }

    @discardableResult
    func finish(token: ChatAnchorTransactionToken) -> Bool {
        guard active?.token == token else {
            return false
        }
        active = nil
        lastTerminalOutcome = .positioned
        return true
    }

    @discardableResult
    func fail(
        token: ChatAnchorTransactionToken,
        failure: ChatAnchorTransactionFailure
    ) -> Bool {
        terminate(token: token, outcome: .failed(failure))
    }

    @discardableResult
    func cancel(
        token: ChatAnchorTransactionToken,
        failure: ChatAnchorTransactionFailure
    ) -> Bool {
        terminate(token: token, outcome: .failed(failure))
    }

    private func terminate(
        token: ChatAnchorTransactionToken,
        outcome: ChatAnchorTransactionTerminalOutcome
    ) -> Bool {
        guard active?.token == token else {
            return false
        }
        active = nil
        lastTerminalOutcome = outcome
        return true
    }
}

private extension ChatAnchorTransactionBoundary {
    var queryId: String? {
        switch self {
        case .remoteFinal(let queryId),
             .remoteFailure(let queryId),
             .persistence(let queryId):
            return queryId
        case .mapping, .apply, .scroll:
            return nil
        }
    }
}

enum ChatAnchorCenteringPolicy {
    static func viewportRelativeMinY(
        viewportHeight: CGFloat,
        targetHeight: CGFloat
    ) -> CGFloat {
        max(0, (viewportHeight - targetHeight) / 2)
    }
}

enum ChatAnchorPositionVerificationPolicy {
    static func isPositioned(
        expectedPrimary: String,
        expectedArchivedId: String?,
        actualPrimary: String?,
        actualArchivedId: String?,
        actualOffsetY: CGFloat,
        targetOffsetY: CGFloat,
        tolerance: CGFloat = 1
    ) -> Bool {
        guard actualPrimary == expectedPrimary,
              normalized(actualArchivedId) == normalized(expectedArchivedId),
              actualOffsetY.isFinite,
              targetOffsetY.isFinite else {
            return false
        }
        return abs(actualOffsetY - targetOffsetY) <= max(0, tolerance)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct ChatRetainedMessageAnchor: Equatable {
    let primary: String
    let archivedId: String?
    let displayRevision: String
    let viewportRelativeMinY: CGFloat
}

enum ChatRetainedMessageAnchorResolution: Equatable {
    case retain(ChatRetainedMessageAnchor)
    case drop
}

enum ChatRetainedMessageAnchorPolicy {
    static func resolve(
        anchor: ChatRetainedMessageAnchor,
        nextPrimary: String,
        nextArchivedId: String?,
        nextDisplayRevision: String,
        isUserInteracting: Bool
    ) -> ChatRetainedMessageAnchorResolution {
        guard !isUserInteracting,
              anchor.primary == nextPrimary,
              normalized(anchor.archivedId) == normalized(nextArchivedId) else {
            return .drop
        }
        return .retain(
            ChatRetainedMessageAnchor(
                primary: nextPrimary,
                archivedId: nextArchivedId,
                displayRevision: nextDisplayRevision,
                viewportRelativeMinY: anchor.viewportRelativeMinY
            )
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum ChatAnchorHighlightOverlay {
    private static let tag = 0xA11D10
    private static let accessibilityPrefix = "chat-anchor-highlight:"

    static func install(
        on cell: MessageContentCell,
        primary: String,
        revision: String? = nil
    ) {
        remove(from: cell)

        let overlay = UIView(frame: cell.contentView.bounds)
        overlay.tag = tag
        overlay.accessibilityIdentifier = accessibilityPrefix + primary
        overlay.accessibilityValue = revision
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.16)
        overlay.isUserInteractionEnabled = false
        cell.contentView.addSubview(overlay)
    }

    static func remove(from cell: MessageContentCell) {
        cell.contentView.viewWithTag(tag)?.removeFromSuperview()
    }

    static func representedPrimary(in cell: MessageContentCell) -> String? {
        guard let identifier = cell.contentView.viewWithTag(tag)?.accessibilityIdentifier,
              identifier.hasPrefix(accessibilityPrefix) else {
            return nil
        }
        return String(identifier.dropFirst(accessibilityPrefix.count))
    }

    static func representedRevision(in cell: MessageContentCell) -> String? {
        cell.contentView.viewWithTag(tag)?.accessibilityValue
    }
}
