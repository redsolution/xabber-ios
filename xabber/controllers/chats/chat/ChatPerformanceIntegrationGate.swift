import Foundation
import XMPPFramework

#if DEBUG || CHAT_PERFORMANCE_LAB
enum ChatOpenRealPipelineFixtureScenario: String, CaseIterable, Equatable {
    case preloadedLatest = "preloaded-latest"
    case confirmedEmpty = "confirmed-empty"
    case bootstrapEmptyToContent = "bootstrap-empty-to-content"
    case bootstrapStaleLocalToContent = "bootstrap-stale-local-to-content"
    case bootstrapEmptyToTrustedEmpty = "bootstrap-empty-to-trusted-empty"
    case bootstrapHeldOverWatchdog = "bootstrap-held-over-watchdog"
    case bootstrapTerminalFailureRetry = "bootstrap-terminal-failure-retry"
    case notificationExactLocal = "notification-exact-local"
    case notificationExactRemote = "notification-exact-remote"
    case notificationKnownGapTarget = "notification-known-gap-target"
    case searchExactLocal = "search-exact-local"
    case searchExactLocalOutsideWindow = "search-exact-local-outside-window"
    case searchExactRemote = "search-exact-remote"
    case knownGapMissingTarget = "known-gap-missing-target"
    case unreadBoundaryLocal = "unread-boundary-local"
    case savedPositionLocal = "saved-position-local"
    case latestWithUnrelatedOlderGap = "latest-with-unrelated-older-gap"
    case lastChatsAnimatedPush = "last-chats-animated-push"
    case mentionDeletedAdvance = "mention-deleted-advance"
    case lastChatsSeededMentionExact =
        "last-chats-seeded-mention-exact"
    case coldPushExact = "cold-push-exact"
    case olderCrossingGap = "older-crossing-gap"
    case newerCrossingGap = "newer-crossing-gap"
    case rotationRealPipeline = "rotation-real-pipeline"
    case committedContentBackgroundForeground =
        "committed-content-background-foreground"
}

enum ChatOpenRealPipelineFixtureTargetKind: String, Equatable {
    case latest
    case empty
    case anchor
}

enum ChatOpenRealPipelineFixturePhase: String, Equatable {
    case preparing
    case skeleton
    case content
    case empty
    case failed
}

enum ChatOpenRealPipelineNativeDidShowPhasePolicy {
    static func phase(
        hasCommittedContent: Bool,
        hasCommittedBlockingSkeleton: Bool
    ) -> ChatOpenRealPipelineFixturePhase {
        if hasCommittedContent {
            return .content
        }
        if hasCommittedBlockingSkeleton {
            return .skeleton
        }
        return .preparing
    }
}

enum ChatOpenRealPipelineFixtureArchiveCursorKind: String, Equatable {
    case none
    case latest
    case aroundTarget = "around-target"
    case before
    case after
}

enum ChatOpenRealPipelineFixtureSkeletonContinuationAction: Equatable {
    case waitForSkeleton
    case waitForExternalAcknowledgement
    case scheduleAutomaticDwell
    case injectRemotePage
}

enum ChatOpenRealPipelineFixtureAcknowledgedRemoteAction: Equatable {
    case injectContentPage
    case injectTrustedEmptyTerminal
    case holdActiveDwellThenCancel
    case injectTypedTerminalFailure
}

enum ChatOpenRealPipelineFixtureSkeletonContinuationPolicy {
    static func action(
        observedSkeletonRows: Int,
        expectedSkeletonRows: Int,
        requiresExternalAcknowledgement: Bool,
        didReceiveExternalAcknowledgement: Bool
    ) -> ChatOpenRealPipelineFixtureSkeletonContinuationAction {
        guard observedSkeletonRows == expectedSkeletonRows else {
            return .waitForSkeleton
        }
        guard requiresExternalAcknowledgement else {
            return .scheduleAutomaticDwell
        }
        return didReceiveExternalAcknowledgement
            ? .injectRemotePage
            : .waitForExternalAcknowledgement
    }
}

struct ChatOpenRealPipelineFixtureOffsetSamplerGate {
    private enum State: Equatable {
        case stopped
        case running
        case paused
    }

    private var state: State = .stopped
    private var generation = 0
    private var lastDisplayTimestamp: TimeInterval?

    init() {}

    mutating func beginSampling() -> Int {
        generation &+= 1
        state = .running
        lastDisplayTimestamp = nil
        return generation
    }

    mutating func pause() {
        generation &+= 1
        state = .paused
        lastDisplayTimestamp = nil
    }

    mutating func stop() {
        generation &+= 1
        state = .stopped
        lastDisplayTimestamp = nil
    }

    mutating func consumeDisplayTick(
        generation candidate: Int,
        timestamp: TimeInterval
    ) -> Bool {
        guard state == .running,
              candidate == generation,
              timestamp.isFinite,
              timestamp >= 0,
              lastDisplayTimestamp.map({ timestamp > $0 }) ?? true else {
            return false
        }
        lastDisplayTimestamp = timestamp
        return true
    }
}

enum ChatOpenRealPipelineFixtureOffsetMutationClassification: Equatable {
    case noMovement
    case initialPositioning
    case retainedPagingAnchor
    case rotationOwnedSemanticRemap
    case unexpectedPostCommit
}

/// Classifies compositor-facing offset deltas by their semantic effect. A raw
/// `contentOffset.y` delta during a width/height transition is not itself a
/// jump: UIKit must change the absolute offset to keep the same live tail or
/// message anchor under the new viewport. Rotation ownership is accepted only
/// when the semantic viewport is independently proven stable; otherwise the
/// sample remains a post-commit failure.
enum ChatOpenRealPipelineFixtureOffsetMutationPolicy {
    static func classification(
        hasOffsetMovement: Bool,
        hasCommittedViewport: Bool,
        retainedPagingAnchorStayedFixed: Bool,
        hasRotationInteractionOwnership: Bool,
        rotationSemanticViewportStayedFixed: Bool
    ) -> ChatOpenRealPipelineFixtureOffsetMutationClassification {
        guard hasOffsetMovement else { return .noMovement }
        guard hasCommittedViewport else { return .initialPositioning }
        if retainedPagingAnchorStayedFixed {
            return .retainedPagingAnchor
        }
        if hasRotationInteractionOwnership,
           rotationSemanticViewportStayedFixed {
            return .rotationOwnedSemanticRemap
        }
        return .unexpectedPostCommit
    }
}

struct ChatOpenRealPipelineFixtureOffsetMutationEvidence: Equatable {
    private(set) var rawMutationCount = 0
    private(set) var initialPositioningMutationCount = 0
    private(set) var rotationOwnedMutationCount = 0
    private(set) var observableMutationCount = 0
    private(set) var postCommitMutationCount = 0

    mutating func record(
        _ classification:
            ChatOpenRealPipelineFixtureOffsetMutationClassification
    ) {
        guard classification != .noMovement else { return }
        rawMutationCount &+= 1
        switch classification {
        case .noMovement:
            break
        case .initialPositioning:
            initialPositioningMutationCount &+= 1
            observableMutationCount &+= 1
        case .retainedPagingAnchor:
            break
        case .rotationOwnedSemanticRemap:
            rotationOwnedMutationCount &+= 1
        case .unexpectedPostCommit:
            observableMutationCount &+= 1
            postCommitMutationCount &+= 1
        }
    }
}

struct ChatOpenRealPipelineFixtureAtomicInitialOffsetGate {
    struct Receipt: Equatable {
        let hasOffsetMovement: Bool
    }

    private var sourceOffsetY: CGFloat?

    mutating func begin(sourceOffsetY: CGFloat) {
        self.sourceOffsetY = sourceOffsetY
    }

    mutating func complete(
        committedOffsetY: CGFloat,
        tolerance: CGFloat = 0.5
    ) -> Receipt? {
        guard let sourceOffsetY else { return nil }
        self.sourceOffsetY = nil
        return Receipt(
            hasOffsetMovement:
                abs(sourceOffsetY - committedOffsetY) > tolerance
        )
    }
}

struct ChatOpenRealPipelineFixtureRotationSourceSample: Equatable {
    let offsetY: CGFloat
    let viewportSize: CGSize
    let displayTimestamp: TimeInterval
    let samplerGeneration: Int
    let semanticViewportStayedFixed: Bool
}

enum ChatOpenRealPipelineFixtureRotationSourceAdmission: String, Equatable {
    case notAttempted = "not-attempted"
    case accepted
    case missingSample = "missing-sample"
    case missingSamplerGeneration = "missing-sampler-generation"
    case invalidOffset = "invalid-offset"
    case invalidSampleTimestamp = "invalid-sample-timestamp"
    case invalidCurrentTimestamp = "invalid-current-timestamp"
    case samplerGenerationMismatch = "sampler-generation-mismatch"
    case semanticViewportUnstable = "semantic-viewport-unstable"
    case invalidSourceViewport = "invalid-source-viewport"
    case invalidTargetViewport = "invalid-target-viewport"
    case sampleFromFuture = "sample-from-future"
    case staleSample = "stale-sample"
    case unchangedViewport = "unchanged-viewport"
}

enum ChatOpenRealPipelineFixtureRotationProductionCommitAdmission:
    String, Equatable {
    case notAttempted = "not-attempted"
    case accepted
    case missingActiveTransition = "missing-active-transition"
    case duplicateCommit = "duplicate-commit"
    case staleGeneration = "stale-generation"
    case targetSizeMismatch = "target-size-mismatch"
}

struct ChatOpenRealPipelineFixtureRotationBarrierDiagnostics: Equatable {
    private(set) var sourceAdmission:
        ChatOpenRealPipelineFixtureRotationSourceAdmission = .notAttempted
    private(set) var transitionBeginCount = 0
    private(set) var coordinatorCompletionSeenCount = 0
    private(set) var coordinatorCompletionAcceptedCount = 0
    private(set) var productionCommitSeenCount = 0
    private(set) var productionCommitAdmission:
        ChatOpenRealPipelineFixtureRotationProductionCommitAdmission =
            .notAttempted
    private(set) var productionCommitAcceptedCount = 0
    private(set) var endpointCount = 0

    mutating func recordSourceAdmission(
        _ admission: ChatOpenRealPipelineFixtureRotationSourceAdmission,
        didBegin: Bool
    ) {
        sourceAdmission = admission
        if didBegin {
            transitionBeginCount &+= 1
        }
    }

    mutating func recordCoordinatorCompletion(accepted: Bool) {
        coordinatorCompletionSeenCount &+= 1
        if accepted {
            coordinatorCompletionAcceptedCount &+= 1
        }
    }

    mutating func recordProductionCommit(
        _ admission:
            ChatOpenRealPipelineFixtureRotationProductionCommitAdmission
    ) {
        productionCommitSeenCount &+= 1
        productionCommitAdmission = admission
        if admission == .accepted {
            productionCommitAcceptedCount &+= 1
        }
    }

    mutating func recordEndpoint() {
        endpointCount &+= 1
    }

    var accessibilityFields: [String] {
        [
            "rotationSource=\(sourceAdmission.rawValue)",
            "rotationBegins=\(transitionBeginCount)",
            "rotationCoordinatorSeen=\(coordinatorCompletionSeenCount)",
            "rotationCoordinatorAccepted=\(coordinatorCompletionAcceptedCount)",
            "rotationCommitSeen=\(productionCommitSeenCount)",
            "rotationCommit=\(productionCommitAdmission.rawValue)",
            "rotationCommitAccepted=\(productionCommitAcceptedCount)",
            "rotationEndpoints=\(endpointCount)"
        ]
    }
}

/// Rotation begins after UIKit has already started installing target
/// geometry, so `viewWillTransition` cannot reliably read the source offset.
/// Accept only the last compositor-facing sample from the still-active
/// sampler generation. A stale or already-target-sized sample fails closed.
enum ChatOpenRealPipelineFixtureRotationSourceSamplePolicy {
    static let maximumSampleAge: TimeInterval = 0.25
    private static let geometryTolerance: CGFloat = 0.5

    static func accepts(
        _ sample: ChatOpenRealPipelineFixtureRotationSourceSample,
        targetViewSize: CGSize,
        currentTimestamp: TimeInterval,
        samplerGeneration: Int
    ) -> Bool {
        admission(
            sample,
            targetViewSize: targetViewSize,
            currentTimestamp: currentTimestamp,
            samplerGeneration: samplerGeneration
        ) == .accepted
    }

    static func admission(
        _ sample: ChatOpenRealPipelineFixtureRotationSourceSample?,
        targetViewSize: CGSize,
        currentTimestamp: TimeInterval,
        samplerGeneration: Int?
    ) -> ChatOpenRealPipelineFixtureRotationSourceAdmission {
        guard let sample else { return .missingSample }
        guard let samplerGeneration else {
            return .missingSamplerGeneration
        }
        guard sample.offsetY.isFinite else { return .invalidOffset }
        guard sample.displayTimestamp.isFinite else {
            return .invalidSampleTimestamp
        }
        guard currentTimestamp.isFinite else {
            return .invalidCurrentTimestamp
        }
        guard sample.samplerGeneration == samplerGeneration else {
            return .samplerGenerationMismatch
        }
        guard sample.semanticViewportStayedFixed else {
            return .semanticViewportUnstable
        }
        guard isValidViewportSize(sample.viewportSize) else {
            return .invalidSourceViewport
        }
        guard isValidViewportSize(targetViewSize) else {
            return .invalidTargetViewport
        }
        let age = currentTimestamp - sample.displayTimestamp
        guard age >= 0 else { return .sampleFromFuture }
        guard age <= maximumSampleAge else { return .staleSample }
        guard abs(sample.viewportSize.width - targetViewSize.width) >
                geometryTolerance ||
              abs(sample.viewportSize.height - targetViewSize.height) >
                geometryTolerance else {
            return .unchangedViewport
        }
        return .accepted
    }

    private static func isValidViewportSize(_ size: CGSize) -> Bool {
        size.width.isFinite &&
            size.height.isFinite &&
            size.width > 0 &&
            size.height > 0
    }
}

struct ChatOpenRealPipelineFixtureRotationOffsetGate {
    struct EndpointReceipt: Equatable {
        let hasOffsetMovement: Bool
        let semanticViewportStayedFixed: Bool
    }

    private struct ActiveTransition {
        let sourceOffsetY: CGFloat
        let targetViewSize: CGSize
        let minimumLayoutGenerationExclusive: Int
        var semanticViewportStayedFixed: Bool
        var coordinatorCompleted = false
        var productionLayoutCommitGeneration: Int?
    }

    private var activeTransition: ActiveTransition?

    var isActive: Bool {
        activeTransition != nil
    }

    mutating func begin(
        sourceOffsetY: CGFloat,
        targetViewSize: CGSize,
        minimumLayoutGenerationExclusive: Int,
        semanticViewportStayedFixed: Bool
    ) -> Bool {
        guard activeTransition == nil,
              sourceOffsetY.isFinite,
              targetViewSize.width.isFinite,
              targetViewSize.height.isFinite,
              targetViewSize.width > 0,
              targetViewSize.height > 0 else {
            return false
        }
        activeTransition = ActiveTransition(
            sourceOffsetY: sourceOffsetY,
            targetViewSize: targetViewSize,
            minimumLayoutGenerationExclusive:
                minimumLayoutGenerationExclusive,
            semanticViewportStayedFixed: semanticViewportStayedFixed
        )
        return true
    }

    mutating func observeSemanticViewport(stayedFixed: Bool) {
        guard var activeTransition else { return }
        activeTransition.semanticViewportStayedFixed =
            activeTransition.semanticViewportStayedFixed && stayedFixed
        self.activeTransition = activeTransition
    }

    @discardableResult
    mutating func recordCoordinatorCompletion() -> Bool {
        guard var activeTransition,
              !activeTransition.coordinatorCompleted else {
            return false
        }
        activeTransition.coordinatorCompleted = true
        self.activeTransition = activeTransition
        return true
    }

    @discardableResult
    mutating func recordProductionLayoutCommit(
        generation: Int,
        targetViewSize: CGSize,
        geometryTolerance: CGFloat = 0.5
    ) -> Bool {
        admitProductionLayoutCommit(
            generation: generation,
            targetViewSize: targetViewSize,
            geometryTolerance: geometryTolerance
        ) == .accepted
    }

    mutating func admitProductionLayoutCommit(
        generation: Int,
        targetViewSize: CGSize,
        geometryTolerance: CGFloat = 0.5
    ) -> ChatOpenRealPipelineFixtureRotationProductionCommitAdmission {
        guard var activeTransition else {
            return .missingActiveTransition
        }
        guard activeTransition.productionLayoutCommitGeneration == nil else {
            return .duplicateCommit
        }
        guard generation >
                activeTransition.minimumLayoutGenerationExclusive else {
            return .staleGeneration
        }
        guard geometryTolerance.isFinite,
              geometryTolerance >= 0,
              targetViewSize.width.isFinite,
              targetViewSize.height.isFinite,
              abs(
                activeTransition.targetViewSize.width -
                    targetViewSize.width
              ) <= geometryTolerance,
              abs(
                activeTransition.targetViewSize.height -
                    targetViewSize.height
              ) <= geometryTolerance else {
            return .targetSizeMismatch
        }
        activeTransition.productionLayoutCommitGeneration = generation
        self.activeTransition = activeTransition
        return .accepted
    }

    mutating func complete(
        targetOffsetY: CGFloat,
        semanticViewportStayedFixed: Bool,
        tolerance: CGFloat = 0.5
    ) -> EndpointReceipt? {
        observeSemanticViewport(
            stayedFixed: semanticViewportStayedFixed
        )
        guard let activeTransition,
              activeTransition.coordinatorCompleted,
              activeTransition.productionLayoutCommitGeneration != nil else {
            return nil
        }
        self.activeTransition = nil
        return EndpointReceipt(
            hasOffsetMovement:
                abs(activeTransition.sourceOffsetY - targetOffsetY) >
                    tolerance,
            semanticViewportStayedFixed:
                activeTransition.semanticViewportStayedFixed
        )
    }

    mutating func cancel() {
        activeTransition = nil
    }
}

enum ChatOpenVideoMarkerPublicationAction: Equatable {
    case publish(
        ChatPerformanceVideoMarkerID,
        ChatPerformanceVideoMarkerVisualCode
    )
    case complete
    case evidenceInvalidated
}

/// Drives the three video clock markers from the same display-link cadence as
/// visible-offset evidence. M1 and M2 each remain visible for two seconds so
/// their four-second onset span can prove the offline 10,000 ppm clock-rate
/// bound despite one-frame video quantization. XCTest cannot observe completion
/// until M3 has remained visible for both thirty subsequent display ticks and
/// at least 500 milliseconds.
struct ChatOpenVideoMarkerPublicationGate {
    static let m1MinimumDisplayTickCount = 6
    static let m1MinimumVisibleDuration: TimeInterval = 2.0
    static let m2MinimumDisplayTickCount = 6
    static let m2MinimumVisibleDuration: TimeInterval = 2.0
    static let m3MinimumPostPublicationTickCount = 30
    static let m3MinimumPostPublicationDuration: TimeInterval = 0.5

    private enum State: Equatable {
        case stopped
        case awaitingM1
        case showingM1
        case showingM2
        case showingM3
        case complete
        case invalidated
    }

    private var state: State = .stopped
    private var generation = 0
    private var lastDisplayTimestamp: TimeInterval?
    private var m1PublicationTimestamp: TimeInterval?
    private var m1DisplayTickCount = 0
    private var m2PublicationTimestamp: TimeInterval?
    private var m2DisplayTickCount = 0
    private var m3PublicationTimestamp: TimeInterval?
    private var m3PostPublicationTickCount = 0

    init() {}

    mutating func begin() -> Int {
        generation &+= 1
        state = .awaitingM1
        lastDisplayTimestamp = nil
        m1PublicationTimestamp = nil
        m1DisplayTickCount = 0
        m2PublicationTimestamp = nil
        m2DisplayTickCount = 0
        m3PublicationTimestamp = nil
        m3PostPublicationTickCount = 0
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
        state = .stopped
        lastDisplayTimestamp = nil
    }

    mutating func consumeDisplayTick(
        generation candidate: Int,
        timestamp: TimeInterval,
        hasStableTerminalEvidence: Bool,
        terminalEvidenceIsFrozen: Bool
    ) -> ChatOpenVideoMarkerPublicationAction? {
        guard candidate == generation,
              timestamp.isFinite,
              timestamp >= 0,
              lastDisplayTimestamp.map({ timestamp > $0 }) ?? true else {
            return nil
        }
        lastDisplayTimestamp = timestamp

        switch state {
        case .stopped, .complete, .invalidated:
            return nil
        case .awaitingM1:
            guard hasStableTerminalEvidence else { return nil }
            guard terminalEvidenceIsFrozen else {
                state = .invalidated
                return .evidenceInvalidated
            }
            state = .showingM1
            m1PublicationTimestamp = timestamp
            m1DisplayTickCount = 1
            return .publish(.m1, .verticalBars)
        case .showingM1:
            m1DisplayTickCount &+= 1
            guard hasStableTerminalEvidence else { return nil }
            guard terminalEvidenceIsFrozen else {
                state = .invalidated
                return .evidenceInvalidated
            }
            guard let m1PublicationTimestamp,
                  m1DisplayTickCount >= Self.m1MinimumDisplayTickCount,
                  timestamp - m1PublicationTimestamp >=
                    Self.m1MinimumVisibleDuration else {
                return nil
            }
            state = .showingM2
            m2PublicationTimestamp = timestamp
            m2DisplayTickCount = 1
            return .publish(.m2, .checkerboard)
        case .showingM2:
            guard terminalEvidenceIsFrozen,
                  let m2PublicationTimestamp else {
                state = .invalidated
                return .evidenceInvalidated
            }
            m2DisplayTickCount &+= 1
            guard m2DisplayTickCount >= Self.m2MinimumDisplayTickCount,
                  timestamp - m2PublicationTimestamp >=
                    Self.m2MinimumVisibleDuration else {
                return nil
            }
            state = .showingM3
            m3PublicationTimestamp = timestamp
            m3PostPublicationTickCount = 0
            return .publish(.m3, .concentricRings)
        case .showingM3:
            guard terminalEvidenceIsFrozen,
                  let m3PublicationTimestamp else {
                state = .invalidated
                return .evidenceInvalidated
            }
            m3PostPublicationTickCount &+= 1
            guard m3PostPublicationTickCount >=
                    Self.m3MinimumPostPublicationTickCount,
                  timestamp - m3PublicationTimestamp >=
                    Self.m3MinimumPostPublicationDuration else {
                return nil
            }
            state = .complete
            return .complete
        }
    }
}

enum ChatOpenRealPipelineFixtureTransportThreadStage: Equatable {
    case mamStart
    case archiveEnvelope
    case messageIngress
    case finalParser
    case uiBookkeeping
    case uiReceipt

    var requiresMainThread: Bool {
        switch self {
        case .uiBookkeeping, .uiReceipt:
            return true
        case .mamStart, .archiveEnvelope, .messageIngress, .finalParser:
            return false
        }
    }
}

struct ChatOpenRealPipelineFixtureTransportThreadSnapshot: Equatable {
    let generation: Int
    let pendingOperationCount: Int
    let mamStartCount: Int
    let archiveEnvelopeCount: Int
    let messageIngressCount: Int
    let finalParserCount: Int
    let uiBookkeepingCount: Int
    let uiReceiptCount: Int
    let transportMainThreadViolationCount: Int
    let uiOffMainThreadViolationCount: Int

    static let empty = ChatOpenRealPipelineFixtureTransportThreadSnapshot(
        generation: 0,
        pendingOperationCount: 0,
        mamStartCount: 0,
        archiveEnvelopeCount: 0,
        messageIngressCount: 0,
        finalParserCount: 0,
        uiBookkeepingCount: 0,
        uiReceiptCount: 0,
        transportMainThreadViolationCount: 0,
        uiOffMainThreadViolationCount: 0
    )

    var hasValidThreadShape: Bool {
        pendingOperationCount == 0 &&
            transportMainThreadViolationCount == 0 &&
            uiOffMainThreadViolationCount == 0
    }
}

/// Lock-safe evidence that the lab transport follows the same thread shape as
/// the real XMPP stream: parsing and persistence planning stay off-main while
/// controller bookkeeping and the final UI receipt stay on main.
final class ChatOpenRealPipelineFixtureTransportThreadRecorder {
    private let lock = NSLock()
    private var activeGeneration: Int?
    private var nextGeneration = 0
    private var pendingOperationCount = 0
    private var mamStartCount = 0
    private var archiveEnvelopeCount = 0
    private var messageIngressCount = 0
    private var finalParserCount = 0
    private var uiBookkeepingCount = 0
    private var uiReceiptCount = 0
    private var transportMainThreadViolationCount = 0
    private var uiOffMainThreadViolationCount = 0

    func activate() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextGeneration &+= 1
        activeGeneration = nextGeneration
        pendingOperationCount = 0
        mamStartCount = 0
        archiveEnvelopeCount = 0
        messageIngressCount = 0
        finalParserCount = 0
        uiBookkeepingCount = 0
        uiReceiptCount = 0
        transportMainThreadViolationCount = 0
        uiOffMainThreadViolationCount = 0
        return nextGeneration
    }

    func invalidate(generation: Int) {
        lock.lock()
        if activeGeneration == generation {
            activeGeneration = nil
        }
        lock.unlock()
    }

    func isCurrent(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation
    }

    @discardableResult
    func beginOperation(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == generation else { return false }
        pendingOperationCount &+= 1
        return true
    }

    func endOperation(generation: Int) {
        lock.lock()
        if activeGeneration == generation {
            pendingOperationCount = max(0, pendingOperationCount - 1)
        }
        lock.unlock()
    }

    func record(
        _ stage: ChatOpenRealPipelineFixtureTransportThreadStage,
        generation: Int,
        isMainThread: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == generation else { return }
        switch stage {
        case .mamStart:
            mamStartCount &+= 1
        case .archiveEnvelope:
            archiveEnvelopeCount &+= 1
        case .messageIngress:
            messageIngressCount &+= 1
        case .finalParser:
            finalParserCount &+= 1
        case .uiBookkeeping:
            uiBookkeepingCount &+= 1
        case .uiReceipt:
            uiReceiptCount &+= 1
        }
        if stage.requiresMainThread {
            if !isMainThread { uiOffMainThreadViolationCount &+= 1 }
        } else if isMainThread {
            transportMainThreadViolationCount &+= 1
        }
    }

    var snapshot: ChatOpenRealPipelineFixtureTransportThreadSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ChatOpenRealPipelineFixtureTransportThreadSnapshot(
            generation: activeGeneration ?? nextGeneration,
            pendingOperationCount: pendingOperationCount,
            mamStartCount: mamStartCount,
            archiveEnvelopeCount: archiveEnvelopeCount,
            messageIngressCount: messageIngressCount,
            finalParserCount: finalParserCount,
            uiBookkeepingCount: uiBookkeepingCount,
            uiReceiptCount: uiReceiptCount,
            transportMainThreadViolationCount:
                transportMainThreadViolationCount,
            uiOffMainThreadViolationCount: uiOffMainThreadViolationCount
        )
    }
}

enum ChatOpenRealPipelineFixtureDarwinAcknowledgementContract {
    static let tokenLaunchArgument =
        "--xabber-chat-open-skeleton-ack-token"
    static let notificationNamePrefix =
        "com.xabber.codex.chat-open-fixture.skeleton-observed."

    static func notificationName(token: String) -> String? {
        guard let uuid = UUID(uuidString: token) else { return nil }
        return notificationNamePrefix + uuid.uuidString.lowercased()
    }

    static func isAllowlisted(notificationName: String) -> Bool {
        guard notificationName.hasPrefix(notificationNamePrefix) else {
            return false
        }
        let token = String(notificationName.dropFirst(notificationNamePrefix.count))
        return self.notificationName(token: token) == notificationName
    }

    static func shouldInstallObserver(
        requiresRemoteInjection: Bool,
        notificationName: String?
    ) -> Bool {
        requiresRemoteInjection &&
            notificationName.map {
                isAllowlisted(notificationName: $0)
            } == true
    }
}

struct ChatOpenRealPipelineFixtureAcknowledgementGate {
    private enum State: Equatable {
        case idle
        case armed
        case consumed
        case invalidated
    }

    private var state: State = .idle

    init() {}

    mutating func arm() -> Bool {
        guard state == .idle else { return false }
        state = .armed
        return true
    }

    mutating func consume() -> Bool {
        guard state == .armed else { return false }
        state = .consumed
        return true
    }

    mutating func invalidate() {
        state = .invalidated
    }
}

/// One-shot rendezvous between two independently ordered production-shaped
/// boundaries: the compositor acknowledgement of the committed skeleton and
/// admission of the current MAM query descriptor. The acknowledgement remains
/// valid across a pre-dispatch query replacement, but a stale query can never
/// consume it. Terminal cleanup permanently invalidates the rendezvous.
struct ChatOpenRealPipelineFixtureRemoteActionLatch {
    private var acknowledgedPlan: ChatOpenRealPipelineFixturePlan?
    private var isInvalidated = false
    private(set) var admittedQueryID: String?
    private(set) var dispatchCount = 0

    init() {}

    var hasPendingAcknowledgement: Bool {
        acknowledgedPlan != nil && !isInvalidated && dispatchCount == 0
    }

    @discardableResult
    mutating func acknowledge(
        plan: ChatOpenRealPipelineFixturePlan
    ) -> Bool {
        guard !isInvalidated,
              dispatchCount == 0,
              acknowledgedPlan == nil else {
            return false
        }
        acknowledgedPlan = plan
        return true
    }

    /// A second admission before dispatch is a query replacement. It moves the
    /// rendezvous to the new query instead of allowing the superseded
    /// descriptor to consume an earlier compositor acknowledgement.
    @discardableResult
    mutating func admit(queryID: String) -> Bool {
        guard !isInvalidated,
              dispatchCount == 0,
              !queryID.isEmpty else {
            return false
        }
        admittedQueryID = queryID
        return true
    }

    mutating func takeIfReady(
        transportIsReady: Bool,
        descriptorQueryID: String?
    ) -> ChatOpenRealPipelineFixturePlan? {
        guard !isInvalidated,
              dispatchCount == 0,
              transportIsReady,
              let plan = acknowledgedPlan,
              let admittedQueryID,
              descriptorQueryID == admittedQueryID else {
            return nil
        }
        acknowledgedPlan = nil
        self.admittedQueryID = nil
        dispatchCount = 1
        return plan
    }

    mutating func invalidate() {
        acknowledgedPlan = nil
        admittedQueryID = nil
        isInvalidated = true
    }
}

enum ChatOpenRealPipelineFixtureAcknowledgementAdmissionPolicy {
    static func shouldConsume(
        hasPendingRemoteInjection: Bool,
        hasCommittedBootstrapSkeleton: Bool,
        loadingStateShowsSkeleton: Bool,
        observedSkeletonRows: Int,
        expectedSkeletonRows: Int
    ) -> Bool {
        hasPendingRemoteInjection &&
            hasCommittedBootstrapSkeleton &&
            loadingStateShowsSkeleton &&
            observedSkeletonRows == expectedSkeletonRows
    }
}

struct ChatOpenRealPipelineFixtureStorageDiagnostics: Equatable {
    let hasRetainedRealmLease: Bool
    let isEphemeral: Bool
    let messageCount: Int
    let hasChatRecord: Bool
    let hasArchiveState: Bool
    let hasDurableReadiness: Bool

    static let unavailable = ChatOpenRealPipelineFixtureStorageDiagnostics(
        hasRetainedRealmLease: false,
        isEphemeral: false,
        messageCount: 0,
        hasChatRecord: false,
        hasArchiveState: false,
        hasDurableReadiness: false
    )

    var accessibilityFields: [String] {
        [
            "storageLease=\(hasRetainedRealmLease)",
            "storageEphemeral=\(isEphemeral)",
            "seeded=\(messageCount)",
            "seededChat=\(hasChatRecord)",
            "seededArchive=\(hasArchiveState)",
            "seededDurable=\(hasDurableReadiness)"
        ]
    }
}

struct ChatOpenRealPipelineFixtureTerminalEvidenceSnapshot: Equatable {
    let datasourceGeneration: Int
    let datasourceApplyCount: Int
    let firstContentApplyCount: Int
    let visualCommitCount: Int
    let stalePreTerminalRealFrameCount: Int
    let mixedSkeletonAndRealFrameCount: Int
    let offsetMutationCount: Int
    let postCommitOffsetMutationCount: Int
    let correctionCount: Int
    let archiveRequestCount: Int
    let gapRequestCount: Int
    let retryVisible: Bool
    let skeletonIdentityStable: Bool
    let skeletonGeometryStable: Bool
    let skeletonDwellMilliseconds: Int
    let postInitialInteractionCount: Int
    let pagingAnchorErrorMilliPoints: Int?
    let rotationTransitionCount: Int
    let applicationBackgroundCount: Int
    let applicationForegroundCount: Int
    let productionBootstrapLeaseEventCount: Int
    let productionBootstrapTransportCount: Int
    let fixtureRealmQueryCountAfterRouteAdmission: Int
    let activeProductionWorkCount: Int
    let transportThreadSnapshot:
        ChatOpenRealPipelineFixtureTransportThreadSnapshot
    let routeHost: ChatPerformanceRouteHostDiagnostics
    let p14Mention: ChatPerformanceP14MentionDiagnostics

    /// This initializer is intentionally explicit. Swift omits `let`
    /// properties with declaration-site defaults from its synthesized
    /// memberwise initializer, which previously made the full production
    /// terminal sample impossible to construct. Defaults remain available to
    /// focused stability-gate tests, while the fixture passes every field.
    init(
        datasourceGeneration: Int,
        datasourceApplyCount: Int,
        firstContentApplyCount: Int,
        visualCommitCount: Int,
        stalePreTerminalRealFrameCount: Int = 0,
        mixedSkeletonAndRealFrameCount: Int = 0,
        offsetMutationCount: Int,
        postCommitOffsetMutationCount: Int,
        correctionCount: Int,
        archiveRequestCount: Int,
        gapRequestCount: Int,
        retryVisible: Bool = false,
        skeletonIdentityStable: Bool = true,
        skeletonGeometryStable: Bool = true,
        skeletonDwellMilliseconds: Int = 0,
        postInitialInteractionCount: Int = 0,
        pagingAnchorErrorMilliPoints: Int? = nil,
        rotationTransitionCount: Int = 0,
        applicationBackgroundCount: Int = 0,
        applicationForegroundCount: Int = 0,
        productionBootstrapLeaseEventCount: Int,
        productionBootstrapTransportCount: Int,
        fixtureRealmQueryCountAfterRouteAdmission: Int,
        activeProductionWorkCount: Int,
        transportThreadSnapshot:
            ChatOpenRealPipelineFixtureTransportThreadSnapshot = .empty,
        routeHost: ChatPerformanceRouteHostDiagnostics = .zero,
        p14Mention: ChatPerformanceP14MentionDiagnostics = .zero
    ) {
        self.datasourceGeneration = datasourceGeneration
        self.datasourceApplyCount = datasourceApplyCount
        self.firstContentApplyCount = firstContentApplyCount
        self.visualCommitCount = visualCommitCount
        self.stalePreTerminalRealFrameCount =
            stalePreTerminalRealFrameCount
        self.mixedSkeletonAndRealFrameCount =
            mixedSkeletonAndRealFrameCount
        self.offsetMutationCount = offsetMutationCount
        self.postCommitOffsetMutationCount = postCommitOffsetMutationCount
        self.correctionCount = correctionCount
        self.archiveRequestCount = archiveRequestCount
        self.gapRequestCount = gapRequestCount
        self.retryVisible = retryVisible
        self.skeletonIdentityStable = skeletonIdentityStable
        self.skeletonGeometryStable = skeletonGeometryStable
        self.skeletonDwellMilliseconds = skeletonDwellMilliseconds
        self.postInitialInteractionCount = postInitialInteractionCount
        self.pagingAnchorErrorMilliPoints = pagingAnchorErrorMilliPoints
        self.rotationTransitionCount = rotationTransitionCount
        self.applicationBackgroundCount = applicationBackgroundCount
        self.applicationForegroundCount = applicationForegroundCount
        self.productionBootstrapLeaseEventCount =
            productionBootstrapLeaseEventCount
        self.productionBootstrapTransportCount =
            productionBootstrapTransportCount
        self.fixtureRealmQueryCountAfterRouteAdmission =
            fixtureRealmQueryCountAfterRouteAdmission
        self.activeProductionWorkCount = activeProductionWorkCount
        self.transportThreadSnapshot = transportThreadSnapshot
        self.routeHost = routeHost
        self.p14Mention = p14Mention
    }
}

struct ChatOpenRealPipelineFixtureTerminalStabilityReceipt: Equatable {
    let evidence: ChatOpenRealPipelineFixtureTerminalEvidenceSnapshot
    let quietMilliseconds: Int
    let provisionalResetCount: Int
}

/// A terminal candidate is provisional until the complete production evidence
/// remains unchanged and every tracked lifecycle owner is idle for the bounded
/// quiet window. Any late apply, offset, query or lease invalidates the window.
struct ChatOpenRealPipelineFixtureTerminalStabilityGate {
    private let quietWindow: TimeInterval
    private var candidate: ChatOpenRealPipelineFixtureTerminalEvidenceSnapshot?
    private var candidateStartedAt: TimeInterval?
    private(set) var provisionalResetCount = 0

    init(quietWindow: TimeInterval = 0.5) {
        self.quietWindow = max(0, quietWindow)
    }

    mutating func stableReceiptIfReady(
        evidence: ChatOpenRealPipelineFixtureTerminalEvidenceSnapshot,
        hasExpectedTerminal: Bool,
        now: TimeInterval
    ) -> ChatOpenRealPipelineFixtureTerminalStabilityReceipt? {
        guard hasExpectedTerminal,
              evidence.activeProductionWorkCount == 0 else {
            invalidateProvisionalCandidate()
            return nil
        }

        guard candidate == evidence,
              let candidateStartedAt else {
            if candidate != nil {
                provisionalResetCount &+= 1
            }
            candidate = evidence
            self.candidateStartedAt = now
            return nil
        }

        let quietDuration = max(0, now - candidateStartedAt)
        guard quietDuration >= quietWindow else { return nil }
        return ChatOpenRealPipelineFixtureTerminalStabilityReceipt(
            evidence: evidence,
            quietMilliseconds: max(
                Int((quietWindow * 1_000).rounded(.up)),
                Int((quietDuration * 1_000).rounded(.down))
            ),
            provisionalResetCount: provisionalResetCount
        )
    }

    private mutating func invalidateProvisionalCandidate() {
        if candidate != nil {
            provisionalResetCount &+= 1
        }
        candidate = nil
        candidateStartedAt = nil
    }
}

enum ChatPerformanceRouteHostKind: String, Equatable {
    case none
    case lastChatsNative = "last-chats-native"
    case notificationsDeletedMention = "notifications-deleted-mention"
    case lastChatsSeededMention = "last-chats-seeded-mention"
}

struct ChatPerformanceRouteHostDiagnostics: Equatable {
    let rootInstalled: Bool
    let lastChatsVisibleBeforeRoute: Bool
    let routeAttemptCount: Int
    let nativePushCount: Int
    let destinationOpaqueBeforeFirstRow: Bool
    let lastChatsExposureCount: Int
    let coldPendingBeforeRoot: Int
    let accountMaterializationCount: Int
    let coldConsumeBeforeStableCount: Int
    let coldConsumeAfterStableCount: Int
    let hostKind: ChatPerformanceRouteHostKind
    let p14SourceRowVisibleBeforeTap: Bool
    let p14SourceRowTapCount: Int
    let p14PendingRequestCountBeforeTap: Int
    let p14RequestAdmissionCountBeforeTap: Int
    let p14RequestAdmissionCount: Int
    let p14RequestAdmissionBeforeViewLoadCount: Int
    let p14GroupConversationProofCount: Int
    let p14ExplicitRequestCount: Int
    let p14UnreadRequestCount: Int
    let p14SavedRequestCount: Int
    let p14LatestRequestCount: Int
    let p13SourceRowVisibleBeforeTap: Bool
    let p13SourceRowTapCount: Int
    let p13AttemptCount: Int
    let p13InvalidationCount: Int
    let p13AdvanceCount: Int
    let p13UnavailableCount: Int
    let p13SelectedNextIdentityCount: Int
    let p13UnrelatedGroupPreservedCount: Int

    init(
        rootInstalled: Bool,
        lastChatsVisibleBeforeRoute: Bool,
        routeAttemptCount: Int,
        nativePushCount: Int,
        destinationOpaqueBeforeFirstRow: Bool,
        lastChatsExposureCount: Int,
        coldPendingBeforeRoot: Int,
        accountMaterializationCount: Int,
        coldConsumeBeforeStableCount: Int,
        coldConsumeAfterStableCount: Int,
        hostKind: ChatPerformanceRouteHostKind = .none,
        p14SourceRowVisibleBeforeTap: Bool = false,
        p14SourceRowTapCount: Int = 0,
        p14PendingRequestCountBeforeTap: Int = 0,
        p14RequestAdmissionCountBeforeTap: Int = 0,
        p14RequestAdmissionCount: Int = 0,
        p14RequestAdmissionBeforeViewLoadCount: Int = 0,
        p14GroupConversationProofCount: Int = 0,
        p14ExplicitRequestCount: Int = 0,
        p14UnreadRequestCount: Int = 0,
        p14SavedRequestCount: Int = 0,
        p14LatestRequestCount: Int = 0,
        p13SourceRowVisibleBeforeTap: Bool = false,
        p13SourceRowTapCount: Int = 0,
        p13AttemptCount: Int = 0,
        p13InvalidationCount: Int = 0,
        p13AdvanceCount: Int = 0,
        p13UnavailableCount: Int = 0,
        p13SelectedNextIdentityCount: Int = 0,
        p13UnrelatedGroupPreservedCount: Int = 0
    ) {
        self.rootInstalled = rootInstalled
        self.lastChatsVisibleBeforeRoute = lastChatsVisibleBeforeRoute
        self.routeAttemptCount = routeAttemptCount
        self.nativePushCount = nativePushCount
        self.destinationOpaqueBeforeFirstRow =
            destinationOpaqueBeforeFirstRow
        self.lastChatsExposureCount = lastChatsExposureCount
        self.coldPendingBeforeRoot = coldPendingBeforeRoot
        self.accountMaterializationCount = accountMaterializationCount
        self.coldConsumeBeforeStableCount = coldConsumeBeforeStableCount
        self.coldConsumeAfterStableCount = coldConsumeAfterStableCount
        self.hostKind = hostKind
        self.p14SourceRowVisibleBeforeTap = p14SourceRowVisibleBeforeTap
        self.p14SourceRowTapCount = p14SourceRowTapCount
        self.p14PendingRequestCountBeforeTap =
            p14PendingRequestCountBeforeTap
        self.p14RequestAdmissionCountBeforeTap =
            p14RequestAdmissionCountBeforeTap
        self.p14RequestAdmissionCount = p14RequestAdmissionCount
        self.p14RequestAdmissionBeforeViewLoadCount =
            p14RequestAdmissionBeforeViewLoadCount
        self.p14GroupConversationProofCount = p14GroupConversationProofCount
        self.p14ExplicitRequestCount = p14ExplicitRequestCount
        self.p14UnreadRequestCount = p14UnreadRequestCount
        self.p14SavedRequestCount = p14SavedRequestCount
        self.p14LatestRequestCount = p14LatestRequestCount
        self.p13SourceRowVisibleBeforeTap =
            p13SourceRowVisibleBeforeTap
        self.p13SourceRowTapCount = p13SourceRowTapCount
        self.p13AttemptCount = p13AttemptCount
        self.p13InvalidationCount = p13InvalidationCount
        self.p13AdvanceCount = p13AdvanceCount
        self.p13UnavailableCount = p13UnavailableCount
        self.p13SelectedNextIdentityCount = p13SelectedNextIdentityCount
        self.p13UnrelatedGroupPreservedCount =
            p13UnrelatedGroupPreservedCount
    }

    static let zero = ChatPerformanceRouteHostDiagnostics(
        rootInstalled: false,
        lastChatsVisibleBeforeRoute: false,
        routeAttemptCount: 0,
        nativePushCount: 0,
        destinationOpaqueBeforeFirstRow: false,
        lastChatsExposureCount: 0,
        coldPendingBeforeRoot: 0,
        accountMaterializationCount: 0,
        coldConsumeBeforeStableCount: 0,
        coldConsumeAfterStableCount: 0,
        hostKind: .none
    )

    func isAccepted(
        for scenario: ChatOpenRealPipelineFixtureScenario
    ) -> Bool {
        switch scenario {
        case .lastChatsAnimatedPush:
            return rootInstalled &&
                lastChatsVisibleBeforeRoute &&
                routeAttemptCount == 1 &&
                nativePushCount == 1 &&
                destinationOpaqueBeforeFirstRow &&
                lastChatsExposureCount == 0 &&
                accountMaterializationCount == 1 &&
                coldPendingBeforeRoot == 0 &&
                coldConsumeBeforeStableCount == 0 &&
                coldConsumeAfterStableCount == 0
        case .coldPushExact:
            return rootInstalled &&
                lastChatsVisibleBeforeRoute &&
                routeAttemptCount == 1 &&
                nativePushCount == 1 &&
                destinationOpaqueBeforeFirstRow &&
                lastChatsExposureCount == 0 &&
                coldPendingBeforeRoot == 1 &&
                accountMaterializationCount == 1 &&
                coldConsumeBeforeStableCount == 0 &&
                coldConsumeAfterStableCount == 1
        case .lastChatsSeededMentionExact:
            return rootInstalled &&
                lastChatsVisibleBeforeRoute &&
                routeAttemptCount == 1 &&
                nativePushCount == 1 &&
                destinationOpaqueBeforeFirstRow &&
                lastChatsExposureCount == 0 &&
                accountMaterializationCount == 1 &&
                coldPendingBeforeRoot == 0 &&
                coldConsumeBeforeStableCount == 0 &&
                coldConsumeAfterStableCount == 0 &&
                hostKind == .lastChatsSeededMention &&
                p14SourceRowVisibleBeforeTap &&
                p14SourceRowTapCount == 1 &&
                p14PendingRequestCountBeforeTap == 0 &&
                p14RequestAdmissionCountBeforeTap == 0 &&
                p14RequestAdmissionCount == 1 &&
                p14RequestAdmissionBeforeViewLoadCount == 1 &&
                p14GroupConversationProofCount == 1 &&
                p14ExplicitRequestCount == 1 &&
                p14UnreadRequestCount == 0 &&
                p14SavedRequestCount == 0 &&
                p14LatestRequestCount == 0
        case .mentionDeletedAdvance:
            return rootInstalled &&
                routeAttemptCount == 1 &&
                nativePushCount == 1 &&
                destinationOpaqueBeforeFirstRow &&
                lastChatsExposureCount == 0 &&
                accountMaterializationCount == 1 &&
                coldPendingBeforeRoot == 0 &&
                coldConsumeBeforeStableCount == 0 &&
                coldConsumeAfterStableCount == 0 &&
                hostKind == .notificationsDeletedMention &&
                p13SourceRowVisibleBeforeTap &&
                p13SourceRowTapCount == 1 &&
                p13AttemptCount == 1 &&
                p13InvalidationCount == 1 &&
                p13AdvanceCount == 1 &&
                p13UnavailableCount == 0 &&
                p13SelectedNextIdentityCount == 1 &&
                p13UnrelatedGroupPreservedCount == 1
        default:
            return self == .zero
        }
    }

    func isAcceptedBeforeStableVisibilityConsumption(
        for scenario: ChatOpenRealPipelineFixtureScenario
    ) -> Bool {
        guard scenario == .coldPushExact else {
            return isAccepted(for: scenario)
        }
        return rootInstalled &&
            lastChatsVisibleBeforeRoute &&
            routeAttemptCount == 1 &&
            nativePushCount == 1 &&
            destinationOpaqueBeforeFirstRow &&
            lastChatsExposureCount == 0 &&
            coldPendingBeforeRoot == 1 &&
            accountMaterializationCount == 1 &&
            coldConsumeBeforeStableCount == 0 &&
            coldConsumeAfterStableCount == 0
    }

    var accessibilityFields: [String] {
        [
            "hostRoot=\(rootInstalled)",
            "hostLastChatsBefore=\(lastChatsVisibleBeforeRoute)",
            "hostRouteAttempts=\(routeAttemptCount)",
            "hostNativePushes=\(nativePushCount)",
            "hostOpaqueBeforeRow=\(destinationOpaqueBeforeFirstRow)",
            "hostLastChatsExposures=\(lastChatsExposureCount)",
            "hostColdPendingBeforeRoot=\(coldPendingBeforeRoot)",
            "hostAccountMaterializations=\(accountMaterializationCount)",
            "hostColdConsumesBeforeStable=\(coldConsumeBeforeStableCount)",
            "hostColdConsumesAfterStable=\(coldConsumeAfterStableCount)",
            "hostKind=\(hostKind.rawValue)",
            "hostP14RowVisibleBeforeTap=\(p14SourceRowVisibleBeforeTap)",
            "hostP14RowTaps=\(p14SourceRowTapCount)",
            "hostP14PendingBeforeTap=\(p14PendingRequestCountBeforeTap)",
            "hostP14AdmissionsBeforeTap=\(p14RequestAdmissionCountBeforeTap)",
            "hostP14Admissions=\(p14RequestAdmissionCount)",
            "hostP14AdmissionsBeforeViewLoad=\(p14RequestAdmissionBeforeViewLoadCount)",
            "hostP14GroupProofs=\(p14GroupConversationProofCount)",
            "hostP14ExplicitRequests=\(p14ExplicitRequestCount)",
            "hostP14UnreadRequests=\(p14UnreadRequestCount)",
            "hostP14SavedRequests=\(p14SavedRequestCount)",
            "hostP14LatestRequests=\(p14LatestRequestCount)",
            "hostP13RowVisibleBeforeTap=\(p13SourceRowVisibleBeforeTap)",
            "hostP13RowTaps=\(p13SourceRowTapCount)",
            "hostP13Attempts=\(p13AttemptCount)",
            "hostP13Invalidations=\(p13InvalidationCount)",
            "hostP13Advances=\(p13AdvanceCount)",
            "hostP13Unavailable=\(p13UnavailableCount)",
            "hostP13SelectedNext=\(p13SelectedNextIdentityCount)",
            "hostP13UnrelatedPreserved=\(p13UnrelatedGroupPreservedCount)"
        ]
    }
}

struct ChatPerformanceP14MentionDiagnostics: Equatable {
    let unreadFrameCount: Int
    let savedFrameCount: Int
    let readEagerMutationCount: Int
    let readScheduledCount: Int
    let readCommittedCount: Int
    let readSuccessfulFlushCount: Int
    let readTerminalSuccessCount: Int
    let readTerminalFailureCount: Int
    let unreadBeforeTap: Bool
    let unreadAtAdmission: Bool
    let unreadAtInitialCommit: Bool
    let readAtTerminal: Bool
    let freshRealmMatchCount: Int
    let freshRealmProofFailureCount: Int
    let pendingCandidateCount: Int
    let inFlightFlushCount: Int
    let hasReconciliationWorkItem: Bool
    let hasStableLayoutRetryWorkItem: Bool

    static let zero = ChatPerformanceP14MentionDiagnostics(
        unreadFrameCount: 0,
        savedFrameCount: 0,
        readEagerMutationCount: 0,
        readScheduledCount: 0,
        readCommittedCount: 0,
        readSuccessfulFlushCount: 0,
        readTerminalSuccessCount: 0,
        readTerminalFailureCount: 0,
        unreadBeforeTap: false,
        unreadAtAdmission: false,
        unreadAtInitialCommit: false,
        readAtTerminal: false,
        freshRealmMatchCount: 0,
        freshRealmProofFailureCount: 0,
        pendingCandidateCount: 0,
        inFlightFlushCount: 0,
        hasReconciliationWorkItem: false,
        hasStableLayoutRetryWorkItem: false
    )

    var isAccepted: Bool {
        unreadFrameCount == 0 &&
            savedFrameCount == 0 &&
            readEagerMutationCount == 0 &&
            readScheduledCount == 1 &&
            readCommittedCount == 1 &&
            readSuccessfulFlushCount == 1 &&
            readTerminalSuccessCount == 1 &&
            readTerminalFailureCount == 0 &&
            unreadBeforeTap &&
            unreadAtAdmission &&
            unreadAtInitialCommit &&
            readAtTerminal &&
            freshRealmMatchCount == 1 &&
            freshRealmProofFailureCount == 0 &&
            pendingCandidateCount == 0 &&
            inFlightFlushCount == 0 &&
            !hasReconciliationWorkItem &&
            !hasStableLayoutRetryWorkItem
    }

    var accessibilityFields: [String] {
        [
            "mentionUnreadFrames=\(unreadFrameCount)",
            "mentionSavedFrames=\(savedFrameCount)",
            "mentionReadEager=\(readEagerMutationCount)",
            "mentionReadScheduled=\(readScheduledCount)",
            "mentionReadCommitted=\(readCommittedCount)",
            "mentionReadFlushes=\(readSuccessfulFlushCount)",
            "mentionReadTerminalSuccess=\(readTerminalSuccessCount)",
            "mentionReadTerminalFailure=\(readTerminalFailureCount)",
            "mentionUnreadBeforeTap=\(unreadBeforeTap)",
            "mentionUnreadAtAdmission=\(unreadAtAdmission)",
            "mentionUnreadAtInitialCommit=\(unreadAtInitialCommit)",
            "mentionReadAtTerminal=\(readAtTerminal)",
            "mentionFreshRealmMatches=\(freshRealmMatchCount)",
            "mentionFreshRealmFailures=\(freshRealmProofFailureCount)",
            "mentionPending=\(pendingCandidateCount)",
            "mentionInFlight=\(inFlightFlushCount)",
            "mentionWorkItem=\(hasReconciliationWorkItem)",
            "mentionStableRetry=\(hasStableLayoutRetryWorkItem)"
        ]
    }
}

/// Closed, privacy-safe projection of store operation cardinality. Raw
/// diagnostic keys never cross the accessibility boundary: known production
/// operations use fixed codes and every unknown key is reduced to one count.
struct ChatOpenRealPipelineFixtureStoreOperationSummary: Equatable {
    enum Kind: String, CaseIterable, Hashable {
        case latest
        case latestWindow
        case older
        case newer
        case message
        case messageWindow
        case firstIncoming
        case firstIncomingWindow
        case resident
        case unread
        case postBootstrapWindowAndMetadata
        case searchPrimary = "search-primary"
        case searchArchive = "search-archive"
        case searchMessageID = "search-message-id"
        case searchFingerprintDate = "search-fingerprint-date"

        var accessibilityCode: String {
            switch self {
            case .latest: return "latest"
            case .latestWindow: return "latest-window"
            case .older: return "older"
            case .newer: return "newer"
            case .message: return "message"
            case .messageWindow: return "message-window"
            case .firstIncoming: return "first-incoming"
            case .firstIncomingWindow: return "first-incoming-window"
            case .unread: return "unread"
            case .resident: return "resident"
            case .postBootstrapWindowAndMetadata: return "post-bootstrap"
            case .searchPrimary: return "search-primary"
            case .searchArchive: return "search-archive"
            case .searchMessageID: return "search-message-id"
            case .searchFingerprintDate: return "search-fingerprint-date"
            }
        }
    }

    private let counts: [Kind: Int]
    let unknownOperationCount: Int

    init(operationCounts: [String: Int]) {
        var knownCounts: [Kind: Int] = [:]
        var unknownCount = 0
        for (rawOperation, rawCount) in operationCounts {
            let count = max(0, rawCount)
            guard count > 0 else { continue }
            if let kind = Kind(rawValue: rawOperation) {
                knownCounts[kind, default: 0] += count
            } else {
                unknownCount += count
            }
        }
        counts = knownCounts
        unknownOperationCount = unknownCount
    }

    private init(counts: [Kind: Int], unknownOperationCount: Int) {
        self.counts = counts.filter { $0.value > 0 }
        self.unknownOperationCount = max(0, unknownOperationCount)
    }

    var totalCount: Int {
        counts.values.reduce(unknownOperationCount, +)
    }

    var withoutUnknownOperations:
        ChatOpenRealPipelineFixtureStoreOperationSummary {
        ChatOpenRealPipelineFixtureStoreOperationSummary(
            counts: counts,
            unknownOperationCount: 0
        )
    }

    func subtracting(
        _ baseline: ChatOpenRealPipelineFixtureStoreOperationSummary
    ) -> ChatOpenRealPipelineFixtureStoreOperationSummary {
        let delta = Dictionary(uniqueKeysWithValues: Kind.allCases.compactMap {
            kind -> (Kind, Int)? in
            let count = max(0, (counts[kind] ?? 0) -
                (baseline.counts[kind] ?? 0))
            return count > 0 ? (kind, count) : nil
        })
        return ChatOpenRealPipelineFixtureStoreOperationSummary(
            counts: delta,
            unknownOperationCount: max(
                0,
                unknownOperationCount - baseline.unknownOperationCount
            )
        )
    }

    /// Remote exact opening has one user-visible target-window read and one
    /// user-visible Phase-B mapping lease. Phase A commits the same immutable
    /// target proof before blocking context can run, so its second
    /// post-bootstrap lease belongs to blocking pre-commit work. Everything
    /// else remains in `blocking`: unexpected kinds and unknown keys must stay
    /// observable instead of being hidden behind the visual budget.
    func partitioningRemoteAnchorInitialFrame()
        -> ChatOpenRealPipelineFixtureStoreOperationPhasePartition {
        let visualCounts: [Kind: Int] = [
            .messageWindow: min(1, counts[.messageWindow] ?? 0),
            .postBootstrapWindowAndMetadata: min(
                1,
                counts[.postBootstrapWindowAndMetadata] ?? 0
            )
        ]
        let visualInitial =
            ChatOpenRealPipelineFixtureStoreOperationSummary(
                counts: visualCounts,
                unknownOperationCount: 0
            )
        return ChatOpenRealPipelineFixtureStoreOperationPhasePartition(
            visualInitial: visualInitial,
            blocking: subtracting(visualInitial)
        )
    }

    var accessibilityValue: String {
        var fields = Kind.allCases.compactMap { kind -> String? in
            guard let count = counts[kind], count > 0 else { return nil }
            return "\(kind.accessibilityCode):\(count)"
        }
        if unknownOperationCount > 0 {
            fields.append("unknown:\(unknownOperationCount)")
        }
        return fields.isEmpty ? "none" : fields.joined(separator: ",")
    }
}

struct ChatOpenRealPipelineFixtureStoreOperationPhasePartition: Equatable {
    let visualInitial: ChatOpenRealPipelineFixtureStoreOperationSummary
    let blocking: ChatOpenRealPipelineFixtureStoreOperationSummary
}

/// Closed terminal state for the compositor marker/export tail. The raw value
/// is safe for the fixture accessibility boundary and intentionally cannot
/// contain an Error description, identifier or path.
enum ChatOpenVideoEvidenceTerminalFailureCode: String, CaseIterable {
    case none = "none"
    case stableFrameRejected = "stable-frame-rejected"
    case markerRejected = "marker-rejected"
    case terminalEvidenceInvalidated = "terminal-evidence-invalidated"
    case artifactFinalizationFailed = "artifact-finalization-failed"
}

/// Closed cause for a stable-frame seal that could not advance. These values
/// expose only gate shape, never an opaque trace, conversation or message ID.
enum ChatOpenPerformanceStableFrameSealFailureCode: String, CaseIterable {
    case none = "none"
    case boundPrimaryContextUnavailable =
        "bound-primary-context-unavailable"
    case currentPrimaryContextUnavailable =
        "current-primary-context-unavailable"
    case primaryContextMismatch = "primary-context-mismatch"
    case lifecycleContextMismatch = "lifecycle-context-mismatch"
    case semanticTargetUnavailable = "semantic-target-unavailable"
    case presentationReceiptPending = "presentation-receipt-pending"
    case stableFrameNotScheduled = "stable-frame-not-scheduled"
    case stableFrameConsumeRejected = "stable-frame-consume-rejected"
}

struct ChatOpenPerformanceStableFrameSealDiagnostics: Equatable {
    let failureCode: ChatOpenPerformanceStableFrameSealFailureCode
    let attempted: Bool
    let boundPrimaryContextAvailable: Bool
    let currentPrimaryContextAvailable: Bool
    let primaryContextMatches: Bool
    let lifecycleContextMatches: Bool
    let semanticTargetAvailable: Bool
    let requiredPresentationReceiptRecorded: Bool
    let stableFrameScheduled: Bool
    let stableFrameAlreadyEmitted: Bool
    let stableFrameConsumed: Bool

    static let notAttempted =
        ChatOpenPerformanceStableFrameSealDiagnostics(
            failureCode: .none,
            attempted: false,
            boundPrimaryContextAvailable: false,
            currentPrimaryContextAvailable: false,
            primaryContextMatches: false,
            lifecycleContextMatches: false,
            semanticTargetAvailable: false,
            requiredPresentationReceiptRecorded: false,
            stableFrameScheduled: false,
            stableFrameAlreadyEmitted: false,
            stableFrameConsumed: false
        )

    var accessibilityFields: [String] {
        [
            "stableFrameFailure=\(failureCode.rawValue)",
            "stableFrameAttempted=\(attempted)",
            "stableFrameBoundPrimary=\(boundPrimaryContextAvailable)",
            "stableFrameCurrentPrimary=\(currentPrimaryContextAvailable)",
            "stableFramePrimaryMatch=\(primaryContextMatches)",
            "stableFrameLifecycleCurrent=\(lifecycleContextMatches)",
            "stableFrameSemanticTarget=\(semanticTargetAvailable)",
            "stableFrameReceipt=\(requiredPresentationReceiptRecorded)",
            "stableFrameScheduled=\(stableFrameScheduled)",
            "stableFrameAlreadyEmitted=\(stableFrameAlreadyEmitted)",
            "stableFrameConsumed=\(stableFrameConsumed)"
        ]
    }
}

enum ChatOpenPerformanceStableFrameSealResult: Equatable {
    case sealed(ChatOpenPerformanceStableFrameSealDiagnostics)
    case retry(ChatOpenPerformanceStableFrameSealDiagnostics)
    case rejected(ChatOpenPerformanceStableFrameSealDiagnostics)
}

struct ChatOpenRealPipelineFixtureDiagnostics: Equatable {
    let scenario: ChatOpenRealPipelineFixtureScenario
    let phase: ChatOpenRealPipelineFixturePhase
    let targetKind: ChatOpenRealPipelineFixtureTargetKind
    let initialSkeletonRowCount: Int
    let currentSkeletonRowCount: Int
    let realRowCount: Int
    let datasourceGeneration: Int
    let initialSkeletonDatasourceGeneration: Int?
    let datasourceApplyCount: Int
    let firstContentApplyCount: Int
    let visualCommitCount: Int
    let previousOrBlankRealFrameCount: Int
    let stalePreTerminalRealFrameCount: Int
    let mixedSkeletonAndRealFrameCount: Int
    let rawOffsetMutationCount: Int
    let initialPositioningOffsetMutationCount: Int
    let rotationOwnedOffsetMutationCount: Int
    let offsetMutationCount: Int
    let postCommitOffsetMutationCount: Int
    let correctionCount: Int
    let bottomDistanceMilliPoints: Int?
    let anchorErrorMilliPoints: Int?
    let requestSource: ChatOpenMessageRequestSource?
    let requestHighlight: Bool
    let requestMarkReadOnVisible: Bool?
    let resolvedTargetOrdinal: Int?
    let targetMatchCount: Int
    let latestVisualCommitCount: Int
    let p14Mention: ChatPerformanceP14MentionDiagnostics
    let heldSkeletonDisplayTickCount: Int
    let archiveLeaseCount: Int
    let initialFrameArchiveRequestCount: Int
    let archiveRequestCount: Int
    let postInitialArchiveRequestCount: Int
    let initialFrameGapRequestCount: Int
    let gapRequestCount: Int
    let postInitialGapRequestCount: Int
    let archiveCursorKind: ChatOpenRealPipelineFixtureArchiveCursorKind
    let retryVisible: Bool
    let skeletonIdentityStable: Bool
    let skeletonGeometryStable: Bool
    let skeletonDwellMilliseconds: Int
    let postInitialInteractionCount: Int
    let pagingAnchorErrorMilliPoints: Int?
    let rotationTransitionCount: Int
    let applicationBackgroundCount: Int
    let applicationForegroundCount: Int
    let usesReusedTimelineSession: Bool
    let storeQueryBaselineCount: Int
    let storeLifetimeQueryCount: Int
    let initialFrameStoreQueryCount: Int
    let blockingInitialStoreQueryCount: Int
    let storeQueryCount: Int
    let postInitialStoreQueryCount: Int
    let initialFrameStoreOperationSummary:
        ChatOpenRealPipelineFixtureStoreOperationSummary
    let blockingInitialStoreOperationSummary:
        ChatOpenRealPipelineFixtureStoreOperationSummary
    let terminalRouteStoreOperationSummary:
        ChatOpenRealPipelineFixtureStoreOperationSummary
    let postInitialStoreOperationSummary:
        ChatOpenRealPipelineFixtureStoreOperationSummary
    let mainThreadStoreQueryCount: Int
    let fullScanCount: Int
    let maxCandidateCount: Int
    let observerActivationCount: Int
    let observerRealmQueryCount: Int
    let mainThreadObserverRealmQueryCount: Int
    let observerInitialCallbackCount: Int
    let mainThreadObserverInitialCallbackCount: Int
    let observerMaxInitialCandidateCount: Int
    let observerMetadataQueryCount: Int
    let mainThreadObserverMetadataQueryCount: Int
    let observerMetadataFullScanCount: Int
    let observerMaxMetadataCandidateCount: Int
    let observerCatchUpMutationCount: Int
    let observerPendingWorkCount: Int
    let preparedOnMainThread: Bool
    let mappedOnMainThread: Bool
    let realDatasourceApplyCount: Int
    let atomicLayoutCommitCount: Int
    let committedRouteCount: Int
    let committedTargetKind: ChatOpenRealPipelineFixtureTargetKind?
    let productionBootstrapLeaseStartCount: Int
    let productionBootstrapLeaseJoinCount: Int
    let productionBootstrapActiveLeaseCount: Int
    let productionBootstrapCompletedLeaseCount: Int
    let productionBootstrapFailedLeaseCount: Int
    let productionBootstrapCancelledLeaseCount: Int
    let productionBootstrapTransportStartCount: Int
    let bootstrapRequestCount: Int
    let bootstrapFinalCount: Int
    let bootstrapDeliveredMessageCount: Int
    let bootstrapPersistedMessageCount: Int
    let finalNewerLiveEdgeReached: Bool
    let finalOlderArchiveEndReached: Bool
    let finalFullArchiveLoaded: Bool
    let fixtureRealmQueryCountAfterRouteAdmission: Int
    let terminalQuietMilliseconds: Int
    let terminalProvisionalResetCount: Int
    let activeProductionWorkCount: Int
    let transportThreadSnapshot:
        ChatOpenRealPipelineFixtureTransportThreadSnapshot
    let stableReceiptGeneration: Int
    let isStable: Bool
    let videoEvidenceFailureCode:
        ChatOpenVideoEvidenceTerminalFailureCode
    let stableFrameSealDiagnostics:
        ChatOpenPerformanceStableFrameSealDiagnostics
    let artifactExportFailureCode:
        ChatPerformanceArtifactExportFailureCode
    let artifactTraceFailure:
        ChatPerformanceArtifactTraceContractFailureDiagnostics
    let storage: ChatOpenRealPipelineFixtureStorageDiagnostics
    let routeHost: ChatPerformanceRouteHostDiagnostics

    /// Accessibility output is deliberately restricted to closed enums and
    /// numeric rendering metrics. No fixture or production identifiers are
    /// included in the UI-test boundary.
    var accessibilitySummary: String {
        var accessibilityFields: [String] = [
            "scenario=\(scenario.rawValue)",
            "phase=\(phase.rawValue)",
            "target=\(targetKind.rawValue)",
            "initialSkeleton=\(initialSkeletonRowCount)",
            "skeleton=\(currentSkeletonRowCount)",
            "real=\(realRowCount)",
            "generation=\(datasourceGeneration)",
            "skeletonGeneration=\(initialSkeletonDatasourceGeneration.map(String.init) ?? "-")",
            "applies=\(datasourceApplyCount)",
            "firstContent=\(firstContentApplyCount)",
            "visualCommits=\(visualCommitCount)",
            "blankFrames=\(previousOrBlankRealFrameCount)",
            "stalePreTerminalRealFrames=\(stalePreTerminalRealFrameCount)",
            "mixedSkeletonRealFrames=\(mixedSkeletonAndRealFrameCount)",
            "rawOffsetMutations=\(rawOffsetMutationCount)",
            "initialPositioningOffsets=\(initialPositioningOffsetMutationCount)",
            "rotationOwnedOffsets=\(rotationOwnedOffsetMutationCount)",
            "offsetMutations=\(offsetMutationCount)",
            "postCommitOffsets=\(postCommitOffsetMutationCount)",
            "corrections=\(correctionCount)",
            "bottomMilli=\(bottomDistanceMilliPoints.map(String.init) ?? "-")",
            "anchorMilli=\(anchorErrorMilliPoints.map(String.init) ?? "-")",
            "source=\(requestSource?.rawValue ?? "default")",
            "highlight=\(requestHighlight)",
            "markReadOnVisible=\(requestMarkReadOnVisible.map(String.init) ?? "none")",
            "targetOrdinal=\(resolvedTargetOrdinal.map(String.init) ?? "-")",
            "targetMatches=\(targetMatchCount)",
            "latestCommits=\(latestVisualCommitCount)",
            "heldSkeletonTicks=\(heldSkeletonDisplayTickCount)",
            "archiveLeases=\(archiveLeaseCount)",
            "initialArchiveRequests=\(initialFrameArchiveRequestCount)",
            "archiveRequests=\(archiveRequestCount)",
            "postInitialArchiveRequests=\(postInitialArchiveRequestCount)",
            "initialGapRequests=\(initialFrameGapRequestCount)",
            "gapRequests=\(gapRequestCount)",
            "postInitialGapRequests=\(postInitialGapRequestCount)",
            "cursor=\(archiveCursorKind.rawValue)",
            "retry=\(retryVisible)",
            "skeletonIdentityStable=\(skeletonIdentityStable)",
            "skeletonGeometryStable=\(skeletonGeometryStable)",
            "skeletonDwellMillis=\(skeletonDwellMilliseconds)",
            "postInteractions=\(postInitialInteractionCount)",
            "pagingAnchorMilli=\(pagingAnchorErrorMilliPoints.map(String.init) ?? "-")",
            "rotations=\(rotationTransitionCount)",
            "backgrounds=\(applicationBackgroundCount)",
            "foregrounds=\(applicationForegroundCount)",
            "reusedSession=\(usesReusedTimelineSession)",
            "storeQueryBaseline=\(storeQueryBaselineCount)",
            "storeLifetimeQueries=\(storeLifetimeQueryCount)",
            "initialStoreQueries=\(initialFrameStoreQueryCount)",
            "blockingInitialStoreQueries=\(blockingInitialStoreQueryCount)",
            "storeQueries=\(storeQueryCount)",
            "postInitialStoreQueries=\(postInitialStoreQueryCount)",
            "initialStoreOps=\(initialFrameStoreOperationSummary.accessibilityValue)",
            "blockingInitialStoreOps=\(blockingInitialStoreOperationSummary.accessibilityValue)",
            "terminalStoreOps=\(terminalRouteStoreOperationSummary.accessibilityValue)",
            "postInitialStoreOps=\(postInitialStoreOperationSummary.accessibilityValue)",
            "mainThreadStoreQueries=\(mainThreadStoreQueryCount)",
            "fullScans=\(fullScanCount)",
            "maxCandidates=\(maxCandidateCount)",
            "observerActivations=\(observerActivationCount)",
            "observerRealmQueries=\(observerRealmQueryCount)",
            "mainThreadObserverRealmQueries=\(mainThreadObserverRealmQueryCount)",
            "observerInitialCallbacks=\(observerInitialCallbackCount)",
            "mainThreadObserverInitialCallbacks=\(mainThreadObserverInitialCallbackCount)",
            "observerMaxInitialCandidates=\(observerMaxInitialCandidateCount)",
            "observerMetadataQueries=\(observerMetadataQueryCount)",
            "mainThreadObserverMetadataQueries=\(mainThreadObserverMetadataQueryCount)",
            "observerMetadataFullScans=\(observerMetadataFullScanCount)",
            "observerMaxMetadataCandidates=\(observerMaxMetadataCandidateCount)",
            "observerCatchUpMutations=\(observerCatchUpMutationCount)",
            "observerPending=\(observerPendingWorkCount)",
            "preparedOnMain=\(preparedOnMainThread)",
            "mappedOnMain=\(mappedOnMainThread)",
            "realApplies=\(realDatasourceApplyCount)",
            "layoutCommits=\(atomicLayoutCommitCount)",
            "committedRoutes=\(committedRouteCount)",
            "committedTarget=\(committedTargetKind?.rawValue ?? "none")",
            "bootstrapLeaseStarts=\(productionBootstrapLeaseStartCount)",
            "bootstrapLeaseJoins=\(productionBootstrapLeaseJoinCount)",
            "bootstrapActive=\(productionBootstrapActiveLeaseCount)",
            "bootstrapCompleted=\(productionBootstrapCompletedLeaseCount)",
            "bootstrapFailed=\(productionBootstrapFailedLeaseCount)",
            "bootstrapCancelled=\(productionBootstrapCancelledLeaseCount)",
            "bootstrapTransports=\(productionBootstrapTransportStartCount)",
            "bootstrapRequests=\(bootstrapRequestCount)",
            "bootstrapFinals=\(bootstrapFinalCount)",
            "bootstrapDelivered=\(bootstrapDeliveredMessageCount)",
            "bootstrapPersisted=\(bootstrapPersistedMessageCount)",
            "finalNewerEdge=\(finalNewerLiveEdgeReached)",
            "finalOlderEnd=\(finalOlderArchiveEndReached)",
            "finalFullArchive=\(finalFullArchiveLoaded)",
            "fixtureRealmQueriesAfterAdmission=\(fixtureRealmQueryCountAfterRouteAdmission)",
            "terminalQuietMillis=\(terminalQuietMilliseconds)",
            "terminalResets=\(terminalProvisionalResetCount)",
            "activeWork=\(activeProductionWorkCount)",
            "transportPending=\(transportThreadSnapshot.pendingOperationCount)",
            "transportStarts=\(transportThreadSnapshot.mamStartCount)",
            "transportEnvelopes=\(transportThreadSnapshot.archiveEnvelopeCount)",
            "transportIngress=\(transportThreadSnapshot.messageIngressCount)",
            "transportFinals=\(transportThreadSnapshot.finalParserCount)",
            "transportMainViolations=\(transportThreadSnapshot.transportMainThreadViolationCount)",
            "transportUIOffMain=\(transportThreadSnapshot.uiOffMainThreadViolationCount)",
            "transportUIBookkeeping=\(transportThreadSnapshot.uiBookkeepingCount)",
            "transportUIReceipts=\(transportThreadSnapshot.uiReceiptCount)",
            "receipt=\(stableReceiptGeneration)",
            "stable=\(isStable)",
            "videoEvidenceFailure=\(videoEvidenceFailureCode.rawValue)",
            "artifactExportFailure=\(artifactExportFailureCode.rawValue)",
            "artifactTraceFailure=\(artifactTraceFailure.code.rawValue)",
            "artifactTracePhase=\(artifactTraceFailure.phaseCode)",
            "artifactTraceRelatedPhase=\(artifactTraceFailure.relatedPhaseCode)",
            "artifactTraceKind=\(artifactTraceFailure.recordKindCode)",
            "artifactTraceObserved=\(artifactTraceFailure.observedCount)",
            "artifactTraceExpected=\(artifactTraceFailure.expectedCount)",
            "artifactTraceBegins=\(artifactTraceFailure.beginCount)",
            "artifactTraceEnds=\(artifactTraceFailure.endCount)",
            "artifactTraceTerminal=\(artifactTraceFailure.terminalCode)",
            "artifactTraceExpectedTerminal=\(artifactTraceFailure.expectedTerminalCode)"
        ]
        accessibilityFields.append(contentsOf:
            stableFrameSealDiagnostics.accessibilityFields)
        accessibilityFields.append(contentsOf: p14Mention.accessibilityFields)
        accessibilityFields.append(contentsOf: storage.accessibilityFields)
        accessibilityFields.append(contentsOf: routeHost.accessibilityFields)
        return accessibilityFields.joined(separator: " ")
    }
}

enum ChatOpenRealPipelineFixtureDiagnosticsPolicy {
    static func isMeasurementPure(
        fixtureRealmQueryCountAfterRouteAdmission: Int
    ) -> Bool {
        fixtureRealmQueryCountAfterRouteAdmission == 0
    }

    static func isExpectedCommit(
        targetKind: ChatOpenRealPipelineFixtureTargetKind,
        anchorStrategy: ChatViewportAnchorStrategy
    ) -> Bool {
        switch (targetKind, anchorStrategy) {
        case (.latest, .bottom), (.empty, .none), (.anchor, .message):
            return true
        default:
            return false
        }
    }

    static func isSkeletonRow(
        isFakeMessage: Bool,
        hasSkeletonKind: Bool
    ) -> Bool {
        isFakeMessage && hasSkeletonKind
    }

    static func previousOrBlankFrameCount(
        visualCommitCount: Int,
        unexpectedCommittedFrameCount: Int,
        intermediateEmptyFrameCount: Int,
        isConfirmedEmptyTerminal: Bool
    ) -> Int {
        max(
            max(0, visualCommitCount - 1),
            unexpectedCommittedFrameCount
        ) + (isConfirmedEmptyTerminal ? 0 : intermediateEmptyFrameCount)
    }
}

struct ChatOpenRealPipelineFixtureTerminalPublicationGate {
    private enum Phase: Equatable {
        case idle
        case observing(Int)
        case stableTail(Int)
        case published
    }

    private(set) var observationGeneration = 0
    private var phase = Phase.idle

    var hasPublishedTerminal: Bool {
        phase == .published
    }

    init() {}

    mutating func beginObservation() -> Int? {
        guard phase == .idle else { return nil }
        observationGeneration &+= 1
        phase = .observing(observationGeneration)
        return observationGeneration
    }

    func isCurrentObservation(_ candidate: Int) -> Bool {
        phase == .observing(candidate)
    }

    mutating func beginStableTail(
        observationGeneration candidate: Int
    ) -> Bool {
        guard phase == .observing(candidate) else { return false }
        phase = .stableTail(candidate)
        return true
    }

    func isCurrentStableTail(_ candidate: Int) -> Bool {
        phase == .stableTail(candidate)
    }

    mutating func commitTerminal(
        observationGeneration candidate: Int? = nil
    ) -> Bool {
        guard phase != .published else { return false }
        if let candidate {
            guard phase == .observing(candidate) ||
                    phase == .stableTail(candidate) else {
                return false
            }
        }
        phase = .published
        // Invalidate every queued callback even before its receipt guard runs.
        observationGeneration &+= 1
        return true
    }
}

/// Closed, privacy-safe input contract for deterministic chat-open UI tests.
/// It contains counts and target kinds only; fixture identifiers never cross
/// the accessibility diagnostics boundary.
struct ChatOpenRealPipelineFixturePlan: Equatable {
    let scenario: ChatOpenRealPipelineFixtureScenario

    /// Public matrix code written to video evidence. Every binding is unique;
    /// legacy selector names remain outside the closed recording contract.
    var videoMatrixRouteCode: String? {
        switch scenario {
        case .preloadedLatest: return "N01"
        case .unreadBoundaryLocal: return "N04"
        case .savedPositionLocal: return "N08"
        case .confirmedEmpty: return "E01"
        case .bootstrapEmptyToContent: return "E02-content"
        case .bootstrapStaleLocalToContent: return "E04"
        case .bootstrapEmptyToTrustedEmpty: return "E02-empty"
        case .bootstrapHeldOverWatchdog: return "E10"
        case .bootstrapTerminalFailureRetry: return "E11"
        case .searchExactLocal: return "X01"
        case .searchExactLocalOutsideWindow: return "X02"
        case .searchExactRemote: return "X03"
        case .notificationExactLocal: return "P01"
        case .notificationExactRemote: return "P02"
        case .coldPushExact: return "P04"
        case .notificationKnownGapTarget: return "P09"
        case .mentionDeletedAdvance: return "P13"
        case .lastChatsSeededMentionExact: return "P14"
        case .latestWithUnrelatedOlderGap: return "G02"
        case .knownGapMissingTarget: return "G05"
        case .olderCrossingGap: return "G06"
        case .newerCrossingGap: return "G07"
        case .lastChatsAnimatedPush: return "V01"
        case .rotationRealPipeline: return "V08"
        case .committedContentBackgroundForeground: return "V10"
        }
    }

    var initialLocalMessageCount: Int {
        switch scenario {
        case .preloadedLatest, .notificationExactLocal, .searchExactLocal,
             .searchExactLocalOutsideWindow, .unreadBoundaryLocal,
             .savedPositionLocal, .lastChatsAnimatedPush,
             .mentionDeletedAdvance,
             .lastChatsSeededMentionExact,
             .rotationRealPipeline,
             .committedContentBackgroundForeground,
             .bootstrapStaleLocalToContent:
            return 320
        case .knownGapMissingTarget, .notificationKnownGapTarget,
             .latestWithUnrelatedOlderGap, .olderCrossingGap,
             .newerCrossingGap:
            return 160
        case .confirmedEmpty, .bootstrapEmptyToContent,
             .bootstrapEmptyToTrustedEmpty, .bootstrapHeldOverWatchdog,
             .bootstrapTerminalFailureRetry, .notificationExactRemote,
             .searchExactRemote, .coldPushExact:
            return 0
        }
    }

    var expectedInitialSkeletonRowCount: Int {
        switch scenario {
        case .bootstrapEmptyToContent, .bootstrapStaleLocalToContent,
             .bootstrapEmptyToTrustedEmpty,
             .bootstrapHeldOverWatchdog, .bootstrapTerminalFailureRetry,
             .notificationExactRemote, .notificationKnownGapTarget,
             .searchExactRemote, .knownGapMissingTarget, .coldPushExact:
            return 30
        case .preloadedLatest, .confirmedEmpty, .notificationExactLocal,
             .searchExactLocal, .searchExactLocalOutsideWindow,
             .unreadBoundaryLocal, .savedPositionLocal,
             .latestWithUnrelatedOlderGap, .lastChatsAnimatedPush,
             .mentionDeletedAdvance,
             .lastChatsSeededMentionExact,
             .olderCrossingGap, .newerCrossingGap,
             .rotationRealPipeline,
             .committedContentBackgroundForeground:
            return 0
        }
    }

    var expectedFinalSkeletonRowCount: Int {
        expectsSkeletonTerminal ? 30 : 0
    }

    var expectedFinalRealRowCount: Int {
        switch scenario {
        case .confirmedEmpty, .bootstrapEmptyToTrustedEmpty,
             .bootstrapHeldOverWatchdog, .bootstrapTerminalFailureRetry:
            return 0
        case .olderCrossingGap, .newerCrossingGap:
            return 160
        default:
            return 80
        }
    }

    /// Initial blocking archive work. Visible G06/G07 paging also uses the
    /// fixture transport, but starts only after the first local frame and must
    /// not arm the skeleton acknowledgement handshake.
    var requiresRemoteInjection: Bool {
        switch scenario {
        case .bootstrapEmptyToContent, .bootstrapStaleLocalToContent,
             .bootstrapEmptyToTrustedEmpty,
             .bootstrapHeldOverWatchdog, .bootstrapTerminalFailureRetry,
             .notificationExactRemote, .notificationKnownGapTarget,
             .searchExactRemote, .knownGapMissingTarget, .coldPushExact:
            return true
        case .preloadedLatest, .confirmedEmpty, .notificationExactLocal,
             .searchExactLocal, .searchExactLocalOutsideWindow,
             .unreadBoundaryLocal, .savedPositionLocal,
             .latestWithUnrelatedOlderGap, .lastChatsAnimatedPush,
             .mentionDeletedAdvance,
             .lastChatsSeededMentionExact,
             .olderCrossingGap, .newerCrossingGap,
             .rotationRealPipeline,
             .committedContentBackgroundForeground:
            return false
        }
    }

    var usesFixtureArchiveTransport: Bool {
        requiresRemoteInjection ||
            scenario == .olderCrossingGap ||
            scenario == .newerCrossingGap
    }

    /// These exact-anchor routes use a two-stage immutable persistence proof:
    /// Phase A binds the target while skeleton remains visible, blocking
    /// context completes, then Phase B maps the sole real frame.
    var usesRemoteAnchorInitialStorePhasePartition: Bool {
        switch scenario {
        case .notificationExactRemote, .notificationKnownGapTarget,
             .searchExactRemote, .knownGapMissingTarget, .coldPushExact:
            return true
        default:
            return false
        }
    }

    var startsWithoutDurableReadiness: Bool {
        switch scenario {
        case .bootstrapEmptyToContent, .bootstrapStaleLocalToContent,
             .bootstrapEmptyToTrustedEmpty,
             .bootstrapHeldOverWatchdog, .bootstrapTerminalFailureRetry,
             .notificationExactRemote, .searchExactRemote, .coldPushExact:
            return true
        default:
            return false
        }
    }

    var requiresPostInitialInteraction: Bool {
        switch scenario {
        case .lastChatsAnimatedPush, .olderCrossingGap, .newerCrossingGap,
             .rotationRealPipeline,
             .committedContentBackgroundForeground:
            return true
        default:
            return false
        }
    }

    /// Every route is closed over the exact number of visible datasource
    /// transactions it may publish. In particular, E04 cannot hide a stale
    /// observer apply between adjacent display-link samples.
    var expectedDatasourceApplyCount: Int {
        switch scenario {
        case .bootstrapHeldOverWatchdog, .bootstrapTerminalFailureRetry,
             .preloadedLatest, .confirmedEmpty, .notificationExactLocal,
             .searchExactLocal, .searchExactLocalOutsideWindow,
             .unreadBoundaryLocal, .savedPositionLocal,
             .latestWithUnrelatedOlderGap, .lastChatsAnimatedPush,
             .mentionDeletedAdvance,
             .lastChatsSeededMentionExact,
             .rotationRealPipeline,
             .committedContentBackgroundForeground:
            return 1
        case .bootstrapEmptyToContent, .bootstrapStaleLocalToContent,
             .bootstrapEmptyToTrustedEmpty, .notificationExactRemote,
             .notificationKnownGapTarget, .searchExactRemote,
             .knownGapMissingTarget, .coldPushExact,
             .olderCrossingGap, .newerCrossingGap:
            return 2
        }
    }

    /// Persist 40 rows on each side of ordinal 160. The bounded 80-row first
    /// frame contains the target plus 40 older and 39 newer rows. Once that
    /// frame is positioned, production background context policy uses the
    /// ordinary 250-row page size and requests the remaining 85 older and 86
    /// newer rows. The DEBUG transport still lets production allocate those
    /// page descriptors and persistence transactions, then supplies their MAM
    /// terminals without touching an account.
    var remoteInjectionOrdinalRange: Range<Int>? {
        switch scenario {
        case .bootstrapEmptyToContent, .bootstrapHeldOverWatchdog:
            return 0..<80
        case .bootstrapStaleLocalToContent:
            return 240..<320
        case .bootstrapEmptyToTrustedEmpty, .bootstrapTerminalFailureRetry:
            return 0..<0
        case .notificationExactRemote, .notificationKnownGapTarget,
             .searchExactRemote, .knownGapMissingTarget, .coldPushExact:
            return 120..<200
        case .preloadedLatest, .confirmedEmpty, .notificationExactLocal,
             .searchExactLocal, .searchExactLocalOutsideWindow,
             .unreadBoundaryLocal, .savedPositionLocal,
             .latestWithUnrelatedOlderGap, .lastChatsAnimatedPush,
             .mentionDeletedAdvance,
             .lastChatsSeededMentionExact,
             .olderCrossingGap, .newerCrossingGap,
             .rotationRealPipeline,
             .committedContentBackgroundForeground:
            return nil
        }
    }

    var acknowledgedRemoteAction:
        ChatOpenRealPipelineFixtureAcknowledgedRemoteAction? {
        switch scenario {
        case .bootstrapEmptyToTrustedEmpty:
            return .injectTrustedEmptyTerminal
        case .bootstrapHeldOverWatchdog:
            return .holdActiveDwellThenCancel
        case .bootstrapTerminalFailureRetry:
            return .injectTypedTerminalFailure
        case .bootstrapEmptyToContent, .bootstrapStaleLocalToContent,
             .notificationExactRemote,
             .notificationKnownGapTarget, .searchExactRemote,
             .knownGapMissingTarget, .coldPushExact:
            return .injectContentPage
        default:
            return nil
        }
    }

    var successfulArchiveFinalIsComplete: Bool {
        scenario == .bootstrapEmptyToContent ||
            scenario == .bootstrapEmptyToTrustedEmpty
    }

    /// RSM `<count>` is whole-result-set cardinality, not the number of
    /// envelopes delivered by this page. E04 returns the newest 80 rows of a
    /// 320-row server archive; existing content routes retain their previous
    /// cardinality.
    var successfulArchiveServerResultCount: Int? {
        switch scenario {
        case .bootstrapEmptyToContent:
            return 80
        case .bootstrapEmptyToTrustedEmpty:
            return 0
        case .bootstrapStaleLocalToContent:
            return 320
        case .notificationExactRemote, .notificationKnownGapTarget,
             .searchExactRemote, .knownGapMissingTarget, .coldPushExact:
            return 1
        case .preloadedLatest, .confirmedEmpty,
             .bootstrapHeldOverWatchdog,
             .bootstrapTerminalFailureRetry, .notificationExactLocal,
             .searchExactLocal, .searchExactLocalOutsideWindow,
             .unreadBoundaryLocal, .savedPositionLocal,
             .latestWithUnrelatedOlderGap, .lastChatsAnimatedPush,
             .mentionDeletedAdvance,
             .lastChatsSeededMentionExact,
             .olderCrossingGap, .newerCrossingGap,
             .rotationRealPipeline,
             .committedContentBackgroundForeground:
            return nil
        }
    }

    var expectsConfirmedEmpty: Bool {
        scenario == .confirmedEmpty ||
            scenario == .bootstrapEmptyToTrustedEmpty
    }

    var expectsSkeletonTerminal: Bool {
        scenario == .bootstrapHeldOverWatchdog ||
            scenario == .bootstrapTerminalFailureRetry
    }

    var expectsRetry: Bool {
        scenario == .bootstrapTerminalFailureRetry
    }

    /// Mirrors the production request factories. Notification and search
    /// jumps visibly highlight their exact target; automatic/read-position
    /// and direct known-gap routes preserve position without highlighting.
    /// Routes without a message-target request return nil so the fixture
    /// cannot silently invent request semantics.
    var expectedRequestHighlight: Bool? {
        switch scenario {
        case .notificationExactLocal, .notificationExactRemote,
             .notificationKnownGapTarget, .coldPushExact,
             .mentionDeletedAdvance,
             .searchExactLocal, .searchExactLocalOutsideWindow,
             .searchExactRemote:
            return true
        case .knownGapMissingTarget, .newerCrossingGap,
             .unreadBoundaryLocal, .savedPositionLocal,
             .lastChatsSeededMentionExact:
            return false
        case .preloadedLatest, .confirmedEmpty, .bootstrapEmptyToContent,
             .bootstrapStaleLocalToContent,
             .bootstrapEmptyToTrustedEmpty, .bootstrapHeldOverWatchdog,
             .bootstrapTerminalFailureRetry,
             .latestWithUnrelatedOlderGap, .lastChatsAnimatedPush,
             .olderCrossingGap, .rotationRealPipeline,
             .committedContentBackgroundForeground:
            return nil
        }
    }

    /// Mirrors the accepted production request factories rather than a
    /// fixture-wide default. Push opens may mark their visible target read;
    /// search, direct and automatic position requests must not.
    var expectedRequestMarkReadOnVisible: Bool? {
        switch scenario {
        case .notificationExactLocal, .notificationExactRemote,
             .notificationKnownGapTarget, .coldPushExact,
             .mentionDeletedAdvance,
             .lastChatsSeededMentionExact:
            return true
        case .searchExactLocal, .searchExactLocalOutsideWindow,
             .searchExactRemote, .knownGapMissingTarget,
             .newerCrossingGap, .unreadBoundaryLocal,
             .savedPositionLocal:
            return false
        case .preloadedLatest, .confirmedEmpty, .bootstrapEmptyToContent,
             .bootstrapStaleLocalToContent,
             .bootstrapEmptyToTrustedEmpty, .bootstrapHeldOverWatchdog,
             .bootstrapTerminalFailureRetry,
             .latestWithUnrelatedOlderGap, .lastChatsAnimatedPush,
             .olderCrossingGap, .rotationRealPipeline,
             .committedContentBackgroundForeground:
            return nil
        }
    }

    var allowsSkeletonStableFrame: Bool {
        expectsSkeletonTerminal
    }

    var stableFramePresentationReceipt:
        ChatOpenPerformancePresentationReceipt {
        if expectsSkeletonTerminal {
            return .skeleton
        }
        if expectsConfirmedEmpty {
            return .empty
        }
        return .content
    }

    var targetKind: ChatOpenRealPipelineFixtureTargetKind {
        switch scenario {
        case .preloadedLatest, .bootstrapEmptyToContent,
             .bootstrapStaleLocalToContent,
             .bootstrapHeldOverWatchdog, .latestWithUnrelatedOlderGap,
             .lastChatsAnimatedPush, .olderCrossingGap,
             .rotationRealPipeline,
             .committedContentBackgroundForeground:
            return .latest
        case .confirmedEmpty, .bootstrapEmptyToTrustedEmpty,
             .bootstrapTerminalFailureRetry:
            return .empty
        case .notificationExactLocal, .notificationExactRemote,
             .notificationKnownGapTarget, .searchExactLocal,
             .searchExactLocalOutsideWindow, .searchExactRemote,
             .knownGapMissingTarget, .unreadBoundaryLocal,
             .savedPositionLocal, .coldPushExact, .newerCrossingGap,
             .mentionDeletedAdvance,
             .lastChatsSeededMentionExact:
            return .anchor
        }
    }

    var expectedRequestSource: ChatOpenMessageRequestSource? {
        switch scenario {
        case .notificationExactLocal, .notificationExactRemote,
             .notificationKnownGapTarget, .coldPushExact:
            return .pushNotification
        case .searchExactLocal, .searchExactLocalOutsideWindow,
             .searchExactRemote:
            return .search
        case .knownGapMissingTarget, .newerCrossingGap:
            return .directOpenAtMessage
        case .unreadBoundaryLocal:
            return .initialUnreadBoundary
        case .savedPositionLocal:
            return .savedVisiblePosition
        case .mentionDeletedAdvance, .lastChatsSeededMentionExact:
            return .mentionNotification
        case .preloadedLatest, .confirmedEmpty, .bootstrapEmptyToContent,
             .bootstrapStaleLocalToContent,
             .bootstrapEmptyToTrustedEmpty, .bootstrapHeldOverWatchdog,
             .bootstrapTerminalFailureRetry,
             .latestWithUnrelatedOlderGap, .lastChatsAnimatedPush,
             .olderCrossingGap, .rotationRealPipeline,
             .committedContentBackgroundForeground:
            return nil
        }
    }

    var unreadBoundaryOrdinal: Int? {
        scenario == .unreadBoundaryLocal ? 157 : nil
    }

    var p14ExplicitMentionOrdinal: Int { 160 }

    var p14UnreadBoundaryOrdinal: Int { 119 }

    var p14UnreadTargetOrdinal: Int { 120 }

    var p14SavedTargetOrdinal: Int { 80 }

    var p14LatestTargetOrdinal: Int { 319 }

    var p13DeletedMentionOrdinal: Int { 120 }

    var p13NextValidMentionOrdinal: Int { 160 }

    var expectedTargetOrdinal: Int? {
        switch scenario {
        case .notificationExactLocal, .notificationExactRemote,
             .notificationKnownGapTarget, .searchExactLocal,
             .searchExactRemote, .knownGapMissingTarget,
             .unreadBoundaryLocal, .savedPositionLocal, .coldPushExact,
             .mentionDeletedAdvance,
             .lastChatsSeededMentionExact:
            return 160
        case .searchExactLocalOutsideWindow, .newerCrossingGap:
            return 40
        case .preloadedLatest, .confirmedEmpty, .bootstrapEmptyToContent,
             .bootstrapStaleLocalToContent,
             .bootstrapEmptyToTrustedEmpty, .bootstrapHeldOverWatchdog,
             .bootstrapTerminalFailureRetry,
             .latestWithUnrelatedOlderGap, .lastChatsAnimatedPush,
             .olderCrossingGap, .rotationRealPipeline,
             .committedContentBackgroundForeground:
            return nil
        }
    }

    var hasUnrelatedOlderGap: Bool {
        scenario == .latestWithUnrelatedOlderGap
    }

    var hasKnownGapTopology: Bool {
        switch scenario {
        case .notificationKnownGapTarget, .knownGapMissingTarget,
             .latestWithUnrelatedOlderGap, .olderCrossingGap,
             .newerCrossingGap:
            return true
        default:
            return false
        }
    }

    var artifactTraceContract: ChatPerformanceArtifactTraceContract {
        switch scenario {
        case .confirmedEmpty:
            return .initialLocalEmpty
        case .bootstrapEmptyToTrustedEmpty:
            return .initialArchiveEmpty
        case .bootstrapTerminalFailureRetry:
            return .initialArchiveFailure
        case .bootstrapHeldOverWatchdog:
            return .initialArchiveActiveDwellThenCancel
        case .bootstrapEmptyToContent, .bootstrapStaleLocalToContent,
             .notificationExactRemote,
             .notificationKnownGapTarget, .searchExactRemote,
             .knownGapMissingTarget, .coldPushExact:
            return .initialArchiveContent
        default:
            return .initialLocalContent
        }
    }

    var stableTerminalPhase: ChatOpenRealPipelineFixturePhase {
        switch scenario {
        case .confirmedEmpty, .bootstrapEmptyToTrustedEmpty:
            return .empty
        case .bootstrapHeldOverWatchdog:
            return .skeleton
        case .bootstrapTerminalFailureRetry:
            return .failed
        default:
            return .content
        }
    }
}

struct ChatPerformanceUITestLaunchDescriptor: Equatable {
    let scale: ChatPerformanceFixtureScale
    let openScenario: ChatOpenRealPipelineFixtureScenario?
    let externalSkeletonAcknowledgementNotificationName: String?

    var requiresExternalSkeletonAcknowledgement: Bool {
        externalSkeletonAcknowledgementNotificationName != nil
    }

    init(
        scale: ChatPerformanceFixtureScale,
        openScenario: ChatOpenRealPipelineFixtureScenario? = nil,
        externalSkeletonAcknowledgementNotificationName: String? = nil
    ) {
        self.scale = scale
        self.openScenario = openScenario
        self.externalSkeletonAcknowledgementNotificationName =
            externalSkeletonAcknowledgementNotificationName
    }
}

enum ChatPerformanceUITestLaunchPolicy {
    static let launchArgument = "--xabber-chat-performance-fixture"
    static let openScenarioLaunchArgument = "--xabber-chat-open-scenario"
    static let uiTestMarkerKey = "XABBER_CHAT_PERFORMANCE_UI_TEST"

    static func descriptor(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ChatPerformanceUITestLaunchDescriptor? {
        guard environment[uiTestMarkerKey] == "1",
              environment[AppLaunchEnvironmentPolicy.disableAccountAutoconnectEnvironmentKey] == nil,
              environment[AppLaunchEnvironmentPolicy.isolatedStorageEnvironmentKey] == nil,
              environment[ChatLiveQASafetyPolicy.modeEnvironmentKey] == nil,
              let flagIndex = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(flagIndex + 1),
              arguments.filter({ $0 == launchArgument }).count == 1,
              let scale = ChatPerformanceFixtureScale(rawValue: arguments[flagIndex + 1]) else {
            return nil
        }

        let scenarioFlagCount = arguments.filter { $0 == openScenarioLaunchArgument }.count
        let openScenario: ChatOpenRealPipelineFixtureScenario?
        if scenarioFlagCount == 0 {
            openScenario = nil
        } else {
            guard scenarioFlagCount == 1,
                  let scenarioFlagIndex = arguments.firstIndex(of: openScenarioLaunchArgument),
                  arguments.indices.contains(scenarioFlagIndex + 1),
                  let scenario = ChatOpenRealPipelineFixtureScenario(
                    rawValue: arguments[scenarioFlagIndex + 1]
                  ) else {
                return nil
            }
            openScenario = scenario
        }

        let acknowledgementFlag =
            ChatOpenRealPipelineFixtureDarwinAcknowledgementContract.tokenLaunchArgument
        let acknowledgementFlagCount = arguments.filter {
            $0 == acknowledgementFlag
        }.count
        let acknowledgementNotificationName: String?
        if acknowledgementFlagCount == 0 {
            acknowledgementNotificationName = nil
        } else {
            guard acknowledgementFlagCount == 1,
                  let acknowledgementFlagIndex = arguments.firstIndex(
                    of: acknowledgementFlag
                  ),
                  arguments.indices.contains(acknowledgementFlagIndex + 1),
                  let name = ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
                    .notificationName(token: arguments[acknowledgementFlagIndex + 1]) else {
                return nil
            }
            acknowledgementNotificationName = name
        }

        let requiresRemoteInjection = openScenario.map {
            ChatOpenRealPipelineFixturePlan(scenario: $0).requiresRemoteInjection
        } ?? false
        guard openScenario != nil || acknowledgementNotificationName == nil,
              !requiresRemoteInjection || acknowledgementNotificationName != nil else {
            return nil
        }

        return ChatPerformanceUITestLaunchDescriptor(
            scale: scale,
            openScenario: openScenario,
            externalSkeletonAcknowledgementNotificationName:
                requiresRemoteInjection ? acknowledgementNotificationName : nil
        )
    }
}

enum ChatPerformanceScenarioScrollDirection: Equatable {
    case older
    case newer
}

struct ChatPerformanceScenarioOperationSnapshot: Equatable {
    var fullHistoryEnumerations: Int
    var datasourceApplies: Int
    var forcedLayouts: Int
    var programmaticOffsets: Int
    var delayedCorrections: Int
}

struct ChatPerformanceScenarioState: Equatable {
    let scale: ChatPerformanceFixtureScale
    let logicalMessageCount: Int
    var residentMessageCount: Int
    var operationSnapshot: ChatPerformanceScenarioOperationSnapshot
    var anchorDrift: Double
    var mediaDownloadCount: Int
    var mediaDecodeCount: Int
    var mediaVisibleCacheHitCount: Int
    var optimisticMessageCount: Int
    var editedMessageCount: Int
    var isSkeletonVisible: Bool
    var exactTargetPrimary: String?
    var intermediateLatestFrameCount: Int
    var activeResourcesAreIdle: Bool
}

enum ChatPerformanceScenarioEvent: Equatable {
    case fastScroll(ChatPerformanceScenarioScrollDirection)
    case incomingWhileScrolled
    case optimisticSend
    case editOptimisticMessage
    case deleteOptimisticMessage
    case mediaPrefetch
    case mediaBecameVisible
    case showSkeleton
    case revealSkeleton
    case searchExactTarget(query: String)
}

enum ChatPerformanceScenarioContract {
    static let residentHardLimit = 360
    static let firstFrameMessageCount = 80
    static let exactTargetPrimary = "chat-performance-exact-target"

    static func initial(scale: ChatPerformanceFixtureScale) -> ChatPerformanceScenarioState {
        ChatPerformanceScenarioState(
            scale: scale,
            logicalMessageCount: scale.rowCount,
            residentMessageCount: min(firstFrameMessageCount, scale.rowCount),
            operationSnapshot: ChatPerformanceScenarioOperationSnapshot(
                fullHistoryEnumerations: 0,
                datasourceApplies: 1,
                forcedLayouts: 1,
                programmaticOffsets: 1,
                delayedCorrections: 0
            ),
            anchorDrift: 0,
            mediaDownloadCount: 0,
            mediaDecodeCount: 0,
            mediaVisibleCacheHitCount: 0,
            optimisticMessageCount: 0,
            editedMessageCount: 0,
            isSkeletonVisible: false,
            exactTargetPrimary: nil,
            intermediateLatestFrameCount: 0,
            activeResourcesAreIdle: true
        )
    }

    static func reduce(
        _ state: ChatPerformanceScenarioState,
        event: ChatPerformanceScenarioEvent
    ) -> ChatPerformanceScenarioState {
        var next = state
        next.activeResourcesAreIdle = false

        switch event {
        case .fastScroll:
            next.residentMessageCount = min(residentHardLimit, max(firstFrameMessageCount, state.residentMessageCount))
            next.anchorDrift = 0
        case .incomingWhileScrolled:
            next.residentMessageCount = min(residentHardLimit, state.residentMessageCount + 1)
            next.anchorDrift = 0
        case .optimisticSend:
            next.optimisticMessageCount += 1
            next.residentMessageCount = min(residentHardLimit, state.residentMessageCount + 1)
        case .editOptimisticMessage:
            if next.optimisticMessageCount > 0 {
                next.editedMessageCount += 1
            }
        case .deleteOptimisticMessage:
            if next.optimisticMessageCount > 0 {
                next.optimisticMessageCount -= 1
                next.residentMessageCount = max(0, state.residentMessageCount - 1)
            }
        case .mediaPrefetch:
            if next.mediaDownloadCount == 0 {
                next.mediaDownloadCount = 1
                next.mediaDecodeCount = 1
            }
        case .mediaBecameVisible:
            if next.mediaDownloadCount == 1, next.mediaDecodeCount == 1 {
                next.mediaVisibleCacheHitCount += 1
            }
        case .showSkeleton:
            next.isSkeletonVisible = true
        case .revealSkeleton:
            next.isSkeletonVisible = false
        case .searchExactTarget(let query):
            if query.compare("test", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                next.exactTargetPrimary = exactTargetPrimary
                next.anchorDrift = 0
            }
        }

        next.activeResourcesAreIdle = true
        return next
    }
}

struct ChatPerformanceReleaseSample: Equatable {
    static let reportPrefix = "CHAT_PERF_RELEASE_REPORT "
    static let reportFileName = "chat-performance-release-report.txt"
    static let expectedDatasourceApplies = 42
    // Each probe mutation changes a message row and its deliberately isolated
    // date-separator row. Twenty paging cycles plus the optimistic-send cycle
    // therefore produce 21 * 2 structural items in each direction.
    static let expectedStructuralInserts = 42
    static let expectedStructuralDeletes = 42

    let scale: ChatPerformanceFixtureScale
    let firstStableMilliseconds: Double
    let cycleResidentBytes: [UInt64]
    let optimisticLocalRowMilliseconds: Double
    let state: ChatPerformanceScenarioState
    let releaseOperations: ChatRenderOperationSnapshot

    var cycleCount: Int { cycleResidentBytes.count }

    var residentGrowthPercent: Double {
        guard cycleResidentBytes.count == 20,
              cycleResidentBytes[4] > 0,
              let maximumAfterWarmup = cycleResidentBytes.dropFirst(5).max() else {
            return .infinity
        }
        let baseline = Double(cycleResidentBytes[4])
        return max(0, (Double(maximumAfterWarmup) - baseline) / baseline * 100)
    }

    var passesMemoryPlateauBudget: Bool {
        residentGrowthPercent <= 10
    }

    var passesOptimisticTrendBudget: Bool {
        optimisticLocalRowMilliseconds <= 100
    }

    var passesActualOperationBudgets: Bool {
        releaseOperations[.datasourceApplies] == Self.expectedDatasourceApplies
            && releaseOperations[.structuralInserts] == Self.expectedStructuralInserts
            && releaseOperations[.structuralDeletes] == Self.expectedStructuralDeletes
            && releaseOperations[.structuralMoves] == 0
            && releaseOperations[.reloads] == 0
    }

    var passesDeterministicBudgets: Bool {
        let operations = state.operationSnapshot
        return cycleCount == 20
            && state.residentMessageCount <= ChatPerformanceScenarioContract.residentHardLimit
            && operations.fullHistoryEnumerations == 0
            && operations.forcedLayouts <= 1
            && operations.programmaticOffsets <= 1
            && operations.delayedCorrections == 0
            && abs(state.anchorDrift) <= 1
            && state.activeResourcesAreIdle
            && passesActualOperationBudgets
    }

    func reportLine() throws -> String {
        let operations = state.operationSnapshot
        let payload: [String: Any] = [
            "version": 1,
            "scale": scale.rawValue,
            "logicalMessageCount": state.logicalMessageCount,
            "residentMessageCount": state.residentMessageCount,
            "firstStableMilliseconds": firstStableMilliseconds,
            "cycleCount": cycleCount,
            "residentCycle5Bytes": cycleResidentBytes.count == 20 ? cycleResidentBytes[4] : 0,
            "residentMaxCycles6To20Bytes": cycleResidentBytes.dropFirst(5).max() ?? 0,
            "residentGrowthPercent": residentGrowthPercent,
            "optimisticLocalRowMilliseconds": optimisticLocalRowMilliseconds,
            "fullHistoryEnumerations": operations.fullHistoryEnumerations,
            "datasourceApplies": operations.datasourceApplies,
            "forcedLayouts": operations.forcedLayouts,
            "programmaticOffsets": operations.programmaticOffsets,
            "delayedCorrections": operations.delayedCorrections,
            "anchorDrift": state.anchorDrift,
            "mediaDownloads": state.mediaDownloadCount,
            "mediaDecodes": state.mediaDecodeCount,
            "mediaVisibleCacheHits": state.mediaVisibleCacheHitCount,
            "editedMessages": state.editedMessageCount,
            "actualDatasourceApplies": releaseOperations[.datasourceApplies],
            "actualStructuralInserts": releaseOperations[.structuralInserts],
            "actualStructuralDeletes": releaseOperations[.structuralDeletes],
            "actualStructuralMoves": releaseOperations[.structuralMoves],
            "actualReloads": releaseOperations[.reloads],
            "actualOperationBudgetsPass": passesActualOperationBudgets,
            "deterministicBudgetsPass": passesDeterministicBudgets,
            "memoryPlateauPass": passesMemoryPlateauBudget,
            "optimisticTrendPass": passesOptimisticTrendBudget
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return Self.reportPrefix + json
    }
}

enum ChatLiveQAMode: String, Equatable {
    case readOnly = "read-only"
    case mutation
}

enum ChatLiveQASafetyError: Error, Equatable {
    case modeMismatch
    case deterministicModeMixedWithLive
    case hostedModeMixedWithLive
    case forbiddenSecretTransport(String)
    case messageNotOwnedByRun(String)
}

enum ChatLiveQASafetyPolicy {
    static let modeEnvironmentKey = "XABBER_CHAT_LIVE_QA_MODE"
    private static let forbiddenSecretFragments = [
        "password", "passwd", "credential", "secret", "private_key", "access_token", "refresh_token"
    ]

    static func validate(
        mode: ChatLiveQAMode,
        environment: [String: String],
        launchArguments: [String]
    ) throws {
        guard environment[modeEnvironmentKey] == mode.rawValue else {
            throw ChatLiveQASafetyError.modeMismatch
        }
        guard environment[ChatPerformanceUITestLaunchPolicy.uiTestMarkerKey] == nil,
              !launchArguments.contains(ChatPerformanceUITestLaunchPolicy.launchArgument) else {
            throw ChatLiveQASafetyError.deterministicModeMixedWithLive
        }
        guard environment[AppLaunchEnvironmentPolicy.disableAccountAutoconnectEnvironmentKey] == nil,
              environment[AppLaunchEnvironmentPolicy.isolatedStorageEnvironmentKey] == nil else {
            throw ChatLiveQASafetyError.hostedModeMixedWithLive
        }

        for key in environment.keys {
            let normalized = key.lowercased()
            if forbiddenSecretFragments.contains(where: normalized.contains) {
                throw ChatLiveQASafetyError.forbiddenSecretTransport(key)
            }
        }
        for argument in launchArguments {
            let normalized = argument.lowercased()
            if forbiddenSecretFragments.contains(where: normalized.contains) {
                throw ChatLiveQASafetyError.forbiddenSecretTransport("launch-argument")
            }
        }
    }
}

struct ChatLiveMutationRegistry: Equatable {
    let runID: String
    let prefix: String
    private(set) var createdMessageIDs: Set<String> = []
    private(set) var deletedMessageIDs: Set<String> = []

    init(runID: String) {
        self.runID = runID
        self.prefix = "chat-perf-qa-\(runID)-"
    }

    mutating func registerCreatedMessage(id: String) {
        guard id.isNotEmpty else { return }
        createdMessageIDs.insert(id)
    }

    func canDelete(messageID: String) -> Bool {
        createdMessageIDs.contains(messageID) && !deletedMessageIDs.contains(messageID)
    }

    mutating func recordDeletion(messageID: String) throws {
        guard canDelete(messageID: messageID) else {
            throw ChatLiveQASafetyError.messageNotOwnedByRun(messageID)
        }
        deletedMessageIDs.insert(messageID)
    }

    var remainingCreatedMessageIDs: [String] {
        createdMessageIDs.subtracting(deletedMessageIDs).sorted()
    }
}
#endif
