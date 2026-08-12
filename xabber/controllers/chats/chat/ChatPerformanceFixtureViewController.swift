import UIKit
import RealmSwift
import XMPPFramework
import notify

#if DEBUG || CHAT_PERFORMANCE_LAB
internal struct ChatPerformanceP14ReceiptReadinessDiagnostics: Equatable,
    CustomStringConvertible {
    internal enum Blocker: String, Equatable {
        case wrongScenario
        case terminalTeardownCompleted
        case missingInitialUnreadProofToken
        case initialUnreadProofOwnerMismatch
        case initialUnreadProofOwnerIsNotLatest
        case nativeDidShowPending
        case routeHostCompletionPending
        case initialUnreadProofPending
        case receiptAlreadyIssued
        case visualCommitCountMismatch
        case targetMatchCountMismatch
        case latestVisualCommitCountMismatch
        case anchorErrorOutOfTolerance
        case pendingOpenMessageRequest
        case activeAnchorExecution
        case datasourceStructuralTransactionActive
        case presentationSnapshotRejected
        case realizedTargetIdentityMissing
        case initialFrameOwnerChangedAfterGeometrySync
        case proofOwnerChangedAfterGeometrySync
        case latestOwnerChangedAfterGeometrySync
        case receiptIssuedDuringGeometrySync
        case ready
        case issued
    }

    var blocker: Blocker
    let evaluationCount: Int
    let isExpectedScenario: Bool
    let terminalTeardownCompleted: Bool
    let proofEffectToken: ChatInitialFrameEffectToken?
    let initialFrameEffectToken: ChatInitialFrameEffectToken?
    let latestEffectToken: ChatInitialFrameEffectToken?
    let proofOwnerMatchesInitialFrame: Bool
    let proofOwnerIsLatest: Bool
    let nativeDidShowCompleted: Bool
    let routeHostDidComplete: Bool
    let initialUnreadProofCompleted: Bool
    let didIssueReceipt: Bool
    let visualCommitCount: Int
    let targetMatchCount: Int
    let latestVisualCommitCount: Int
    let anchorError: CGFloat?
    let hasPendingOpenMessageRequest: Bool
    let hasActiveAnchorExecution: Bool
    let isDatasourceStructuralTransactionActive: Bool
    let presentationSnapshot: ChatReadVisiblePresentationSnapshot?
    let presentationSnapshotAccepted: Bool?
    let viewHierarchyVisibility:
        ChatReadVisibleViewHierarchyDiagnostics?
    let expectedTargetPrimary: String
    let realizedTargetIdentity: ChatReadVisibleRowPresentationIdentity?
    let realizedMessagePrimaries: Set<String>
    let realizedMessageCount: Int
    let datasourceGeneration: UInt64
    let coordinatorLifecycleState: ChatReadVisiblePresentationLifecycleState
    let coordinatorGeneration: UInt64
    let coordinatorGeometryGeneration: UInt64
    let pendingCandidateCount: Int
    let inFlightFlushCount: Int
    let initialFramePhase: ChatLocalFirstFramePhase
    let isInitialBootstrapInFlight: Bool
    let showsSkeleton: Bool
    let isApplyingBootstrapAnchorWindow: Bool
    let isPreparingStackedNavigationPresentation: Bool
    let isNavigationTransitionActive: Bool
    let hasControllerTransitionCoordinator: Bool
    let hasNavigationTransitionCoordinator: Bool

    var description: String {
        let snapshotDescription = presentationSnapshot.map { snapshot in
            "app=\(snapshot.isApplicationActive),window=\(snapshot.isWindowAttached),scene=\(snapshot.isWindowSceneForegroundActive),key=\(snapshot.isKeyWindow),top=\(snapshot.isTopNavigationDestination),split=\(snapshot.isVisibleSplitSecondary),covered=\(snapshot.hasCoveringPresentation),transition=\(snapshot.isTransitionActive)"
        } ?? "notEvaluated"
        return [
            "blocker=\(blocker.rawValue)",
            "evaluation=\(evaluationCount)",
            "scenario=\(isExpectedScenario)",
            "teardown=\(terminalTeardownCompleted)",
            "proofGeneration=\(proofEffectToken?.presentationGeneration.description ?? "nil")",
            "frameGeneration=\(initialFrameEffectToken?.presentationGeneration.description ?? "nil")",
            "latestGeneration=\(latestEffectToken?.presentationGeneration.description ?? "nil")",
            "proofMatchesFrame=\(proofOwnerMatchesInitialFrame)",
            "proofIsLatest=\(proofOwnerIsLatest)",
            "didShow=\(nativeDidShowCompleted)",
            "hostComplete=\(routeHostDidComplete)",
            "proofComplete=\(initialUnreadProofCompleted)",
            "didIssue=\(didIssueReceipt)",
            "visual=\(visualCommitCount)",
            "targetMatches=\(targetMatchCount)",
            "latestVisual=\(latestVisualCommitCount)",
            "anchorError=\(anchorError.map { String(describing: $0) } ?? "nil")",
            "pendingRequest=\(hasPendingOpenMessageRequest)",
            "activeAnchor=\(hasActiveAnchorExecution)",
            "structural=\(isDatasourceStructuralTransactionActive)",
            "snapshotAccepted=\(String(describing: presentationSnapshotAccepted))",
            "snapshot(\(snapshotDescription))",
            "viewHierarchy=\(String(describing: viewHierarchyVisibility))",
            "expectedTarget=\(expectedTargetPrimary)",
            "realizedTarget=\(String(describing: realizedTargetIdentity))",
            "realizedPrimaries=\(realizedMessagePrimaries.sorted())",
            "realizedCount=\(realizedMessageCount)",
            "datasourceGeneration=\(datasourceGeneration)",
            "coordinatorLifecycle=\(String(describing: coordinatorLifecycleState))",
            "coordinatorGeneration=\(coordinatorGeneration)",
            "geometryGeneration=\(coordinatorGeometryGeneration)",
            "pending=\(pendingCandidateCount)",
            "inFlight=\(inFlightFlushCount)",
            "initialPhase=\(String(describing: initialFramePhase))",
            "bootstrapInFlight=\(isInitialBootstrapInFlight)",
            "skeleton=\(showsSkeleton)",
            "bootstrapAnchor=\(isApplyingBootstrapAnchorWindow)",
            "stackedPreparing=\(isPreparingStackedNavigationPresentation)",
            "navigationActive=\(isNavigationTransitionActive)",
            "controllerTransition=\(hasControllerTransitionCoordinator)",
            "navigationTransition=\(hasNavigationTransitionCoordinator)"
        ].joined(separator: " ")
    }
}

/// One-shot, read-only geometry evidence for the hosted P14 ownership race.
/// The fixture captures this only from explicit XCTest edges; the production
/// receipt/display-link path never constructs it.
internal struct ChatPerformanceP14TargetGeometrySnapshot:
    CustomStringConvertible {
    let uptime: TimeInterval
    let viewFrame: CGRect
    let viewBounds: CGRect
    let viewSafeAreaInsets: UIEdgeInsets
    let collectionFrame: CGRect
    let collectionBounds: CGRect
    let contentOffset: CGPoint
    let contentSize: CGSize
    let contentInset: UIEdgeInsets
    let adjustedContentInset: UIEdgeInsets
    let readViewport: CGRect
    let targetPresentInDatasource: Bool
    let targetSection: Int?
    let visibleIndexPaths: [IndexPath]
    let visibleMessagePrimaries: [String]
    let targetInVisibleIndexPaths: Bool
    let targetCellExists: Bool
    let targetLayoutFrame: CGRect?
    let targetCellFrame: CGRect?
    let originalViewportRelativeMinY: CGFloat?
    let liveLayoutRelativeMinY: CGFloat?
    let liveCellRelativeMinY: CGFloat?
    let liveLayoutAnchorError: CGFloat?
    let liveCellAnchorError: CGFloat?
    let layoutIntersection: CGRect?
    let cellIntersection: CGRect?
    let layoutMeaningfullyVisible: Bool?
    let cellMeaningfullyVisible: Bool?
    let committedDiagnosticGeneration: UInt64?
    let fixtureFrameGeneration: UInt64?
    let latestGeneration: UInt64?
    let proofGeneration: UInt64?
    let datasourceGeneration: UInt64

    var description: String {
        [
            "t=\(Self.seconds(uptime))",
            "viewFrame=\(Self.rect(viewFrame))",
            "viewBounds=\(Self.rect(viewBounds))",
            "safe=\(Self.insets(viewSafeAreaInsets))",
            "collectionFrame=\(Self.rect(collectionFrame))",
            "collectionBounds=\(Self.rect(collectionBounds))",
            "offset=\(Self.point(contentOffset))",
            "size=\(Self.size(contentSize))",
            "inset=\(Self.insets(contentInset))",
            "adjusted=\(Self.insets(adjustedContentInset))",
            "viewport=\(Self.rect(readViewport))",
            "targetInDatasource=\(targetPresentInDatasource)",
            "targetSection=\(targetSection.map { String($0) } ?? "nil")",
            "visibleIndices=\(visibleIndexPaths)",
            "visiblePrimaries=\(visibleMessagePrimaries)",
            "targetInVisible=\(targetInVisibleIndexPaths)",
            "cellExists=\(targetCellExists)",
            "layoutFrame=\(Self.optionalRect(targetLayoutFrame))",
            "cellFrame=\(Self.optionalRect(targetCellFrame))",
            "originalRelativeY=\(Self.optionalNumber(originalViewportRelativeMinY))",
            "liveLayoutRelativeY=\(Self.optionalNumber(liveLayoutRelativeMinY))",
            "liveCellRelativeY=\(Self.optionalNumber(liveCellRelativeMinY))",
            "layoutError=\(Self.optionalNumber(liveLayoutAnchorError))",
            "cellError=\(Self.optionalNumber(liveCellAnchorError))",
            "layoutIntersection=\(Self.optionalRect(layoutIntersection))",
            "cellIntersection=\(Self.optionalRect(cellIntersection))",
            "layoutVisible=\(String(describing: layoutMeaningfullyVisible))",
            "cellVisible=\(String(describing: cellMeaningfullyVisible))",
            "committedGeneration=\(committedDiagnosticGeneration.map { String($0) } ?? "nil")",
            "fixtureFrameGeneration=\(fixtureFrameGeneration.map { String($0) } ?? "nil")",
            "latestGeneration=\(latestGeneration.map { String($0) } ?? "nil")",
            "proofGeneration=\(proofGeneration.map { String($0) } ?? "nil")",
            "datasourceGeneration=\(datasourceGeneration)"
        ].joined(separator: " ")
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.6f", value)
    }

    private static func optionalNumber(_ value: CGFloat?) -> String {
        value.map(number) ?? "nil"
    }

    private static func point(_ value: CGPoint) -> String {
        "(\(number(value.x)),\(number(value.y)))"
    }

    private static func size(_ value: CGSize) -> String {
        "(\(number(value.width)),\(number(value.height)))"
    }

    private static func rect(_ value: CGRect) -> String {
        "(\(number(value.minX)),\(number(value.minY))," +
            "\(number(value.width)),\(number(value.height)))"
    }

    private static func optionalRect(_ value: CGRect?) -> String {
        value.map(rect) ?? "nil"
    }

    private static func insets(_ value: UIEdgeInsets) -> String {
        "(\(number(value.top)),\(number(value.left))," +
            "\(number(value.bottom)),\(number(value.right)))"
    }
}

final class ChatOpenRealPipelineFixtureDarwinAcknowledgementObserver {
    private let notificationName: String
    private let handler: () -> Void
    private let lock = NSLock()
    private var registrationToken: Int32?
    private var gate = ChatOpenRealPipelineFixtureAcknowledgementGate()

    init(notificationName: String, handler: @escaping () -> Void) {
        self.notificationName = notificationName
        self.handler = handler
    }

    @discardableResult
    func start() -> Bool {
        guard ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
            .isAllowlisted(notificationName: notificationName) else {
            return false
        }
        lock.lock()
        let didArm = gate.arm()
        lock.unlock()
        guard didArm else { return false }

        var token: Int32 = 0
        let status = notificationName.withCString { name in
            notify_register_dispatch(name, &token, .main) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.consumeOnMain()
                }
            }
        }
        guard status == NOTIFY_STATUS_OK else {
            lock.lock()
            gate.invalidate()
            lock.unlock()
            return false
        }
        lock.lock()
        registrationToken = token
        lock.unlock()
        return true
    }

    func invalidate() {
        lock.lock()
        gate.invalidate()
        let token = registrationToken
        registrationToken = nil
        lock.unlock()
        if let token {
            notify_cancel(token)
        }
    }

    deinit {
        invalidate()
    }

    private func consumeOnMain() {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        let shouldDeliver = gate.consume()
        let token = shouldDeliver ? registrationToken : nil
        if shouldDeliver {
            registrationToken = nil
        }
        lock.unlock()
        guard shouldDeliver else { return }
        if let token {
            notify_cancel(token)
        }
        handler()
    }
}

final class ChatPerformanceFixtureInteractiveRemoteArchiveDispatcher:
    ChatInteractiveRemoteArchiveRequestDispatching {
    private let handler: (ChatInteractiveRemoteArchiveDispatchRequest) -> Void

    init(
        handler: @escaping (ChatInteractiveRemoteArchiveDispatchRequest) -> Void
    ) {
        self.handler = handler
    }

    func enqueue(_ request: ChatInteractiveRemoteArchiveDispatchRequest) {
        handler(request)
    }
}

/// High-contrast, closed visual alphabet consumed by the offline raw-frame
/// detector. Geometry intentionally mirrors the detector's six-cell contract;
/// the app publishes only the visual code and monotonic boundary timestamp,
/// never a video frame index or PTS.
final class ChatPerformanceVideoMarkerView: UIView {
    private(set) var visualCode: ChatPerformanceVideoMarkerVisualCode?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func publish(_ visualCode: ChatPerformanceVideoMarkerVisualCode) {
        self.visualCode = visualCode
        isHidden = false
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setShouldAntialias(false)
        context.interpolationQuality = .none

        let markerBounds = bounds.integral
        UIColor(red: 1, green: 0, blue: 1, alpha: 1).setFill()
        context.fill(markerBounds)

        let borderWidth = max(4, floor(min(
            markerBounds.width,
            markerBounds.height
        ) / 7))
        let patternBounds = markerBounds.insetBy(
            dx: borderWidth,
            dy: borderWidth
        )
        UIColor.black.setFill()
        context.fill(patternBounds)
        guard let visualCode else { return }

        switch visualCode {
        case .verticalBars:
            drawVerticalBars(in: patternBounds, context: context)
        case .checkerboard:
            drawCheckerboard(in: patternBounds, context: context)
        case .concentricRings:
            drawConcentricRings(in: patternBounds, context: context)
        }
    }

    private func drawVerticalBars(
        in bounds: CGRect,
        context: CGContext
    ) {
        UIColor.white.setFill()
        for column in stride(from: 0, to: 6, by: 2) {
            let lowerX = bounds.minX + bounds.width * CGFloat(column) / 6
            let upperX = bounds.minX + bounds.width * CGFloat(column + 1) / 6
            context.fill(CGRect(
                x: lowerX,
                y: bounds.minY,
                width: upperX - lowerX,
                height: bounds.height
            ))
        }
    }

    private func drawCheckerboard(
        in bounds: CGRect,
        context: CGContext
    ) {
        UIColor.white.setFill()
        for row in 0..<6 {
            for column in 0..<6 where (row + column).isMultiple(of: 2) {
                let lowerX = bounds.minX + bounds.width * CGFloat(column) / 6
                let upperX = bounds.minX + bounds.width * CGFloat(column + 1) / 6
                let lowerY = bounds.minY + bounds.height * CGFloat(row) / 6
                let upperY = bounds.minY + bounds.height * CGFloat(row + 1) / 6
                context.fill(CGRect(
                    x: lowerX,
                    y: lowerY,
                    width: upperX - lowerX,
                    height: upperY - lowerY
                ))
            }
        }
    }

    private func drawConcentricRings(
        in bounds: CGRect,
        context: CGContext
    ) {
        let colors: [(diameterSixths: CGFloat, color: UIColor)] = [
            (5, .white),
            (4, .black),
            (3, .white),
            (2, .black),
            (1, .white)
        ]
        for ring in colors {
            ring.color.setFill()
            let width = bounds.width * ring.diameterSixths / 6
            let height = bounds.height * ring.diameterSixths / 6
            context.fillEllipse(in: CGRect(
                x: bounds.midX - width / 2,
                y: bounds.midY - height / 2,
                width: width,
                height: height
            ))
        }
    }
}

final class ChatPerformanceFixtureViewController: ChatViewController {
    private struct OpenScenarioSkeletonPresentationSnapshot: Equatable {
        let rowPrimaryOrder: [String]
        let rowHeightMilliPoints: [Int]
        let datasourceGeneration: Int
        let contentHeightMilliPoints: Int
        let contentOffsetMilliPoints: Int

        func hasStableIdentity(
            comparedWith other: OpenScenarioSkeletonPresentationSnapshot
        ) -> Bool {
            rowPrimaryOrder == other.rowPrimaryOrder &&
                datasourceGeneration == other.datasourceGeneration
        }

        func hasStableGeometry(
            comparedWith other: OpenScenarioSkeletonPresentationSnapshot
        ) -> Bool {
            rowHeightMilliPoints == other.rowHeightMilliPoints &&
                contentHeightMilliPoints == other.contentHeightMilliPoints &&
                contentOffsetMilliPoints == other.contentOffsetMilliPoints
        }
    }

    private enum OpenScenarioError: Error {
        case storageIsNotEphemeral
        case remoteInjectionPlanUnavailable
        case targetSelectionUnavailable
        case archiveTransportUnavailable
        case archiveDescriptorRejected
        case malformedArchiveFixture
        case artifactExportUnavailable
        case stableFrameTraceRejected
        case videoMarkerPublicationRejected
        case terminalEvidenceMovedAfterStableFrame
        case primaryTraceContextUnavailable
        case traceContextBindingRejected
        case unexpectedLinkedTraceContext
        case traceContextCardinalityRejected
        case p14InitialUnreadProofRejected
        case p13RouteEvidenceInvalidatedAfterStableReceipt
    }

    private enum AccessibilityID {
        static let timeline = "chat.performance.timeline"
        static let ready = "chat.performance.ready"
        static let state = "chat.performance.state"
        static let incoming = "chat.performance.incoming"
        static let edit = "chat.performance.edit"
        static let delete = "chat.performance.delete"
        static let mediaPrefetch = "chat.performance.media_prefetch"
        static let mediaVisible = "chat.performance.media_visible"
        static let skeleton = "chat.performance.skeleton"
        static let reveal = "chat.performance.reveal"
        static let search = "chat.performance.lastchats_search"
        static let openState = "chat.open.fixture.state"
        static let openStable = "chat.open.fixture.stable"
        static let openPostInitialAction =
            "chat.open.fixture.perform_post_initial"
    }

    private let descriptor: ChatPerformanceUITestLaunchDescriptor
    private var scenarioState: ChatPerformanceScenarioState
    private var fixtureMessages: [MessageStorageItem] = []
    private var optimisticPrimary: String?
    private let releaseProbeStartedAt = CACurrentMediaTime()
    private var releaseProbeFirstStableMilliseconds: Double = 0
    private var releaseProbeResidentBytes: [UInt64] = []
    private let readyLabel = UILabel()
    private let stateLabel = UILabel()
    private let controlsScrollView = UIScrollView()
    private let controlsStack = UIStackView()
    private let openStateLabel = UILabel()
    private let openStableLabel = UILabel()
    private lazy var openPostInitialActionButton = makeButton(
        "Continue",
        id: AccessibilityID.openPostInitialAction,
        action: #selector(performOpenScenarioPostInitialAction)
    )
    private let openScenarioVideoMarkerView = ChatPerformanceVideoMarkerView()
    /// Realm erases an in-memory store when its final Realm instance is
    /// released. Scene startup creates this controller before loading its
    /// view, so the fixture must own the seeded store across that boundary.
    private var openScenarioRealmLease: Realm?
    private var openScenarioSetupFailure: String?
    private(set) var openScenarioStorageDiagnostics:
        ChatOpenRealPipelineFixtureStorageDiagnostics = .unavailable
    private var openScenarioInitialSkeletonRowCount = 0
    private var openScenarioViewportDiagnostics: ChatViewportTransactionDiagnostics?
    private var openScenarioProductionVisualCommitCount = 0
    private var openScenarioUnexpectedCommittedFrameCount = 0
    private var openScenarioStalePreTerminalRealFrameCount = 0
    private var openScenarioMixedSkeletonAndRealFrameCount = 0
    private var openScenarioHeldSkeletonDisplayTickCount = 0
    private var openScenarioE04AcknowledgementAwaitingDisplayTick = false
    private(set) var openScenarioCommittedInitialFrameDiagnostics:
        ChatPerformanceInitialFrameCommitDiagnostics?
    private var openScenarioResolvedTargetOrdinal: Int?
    private var openScenarioTargetMatchCount = 0
    private var openScenarioLatestVisualCommitCount = 0
    private var openScenarioArchiveRequestCount = 0
    private var openScenarioGapRequestCount = 0
    private var openScenarioObservedProductionArchiveQueryIds: Set<String> = []
    private var openScenarioObservedProductionGapQueryIds: Set<String> = []
    private var openScenarioInitialFrameArchiveRequestCount: Int?
    private var openScenarioInitialFrameGapRequestCount: Int?
    private var openScenarioInitialFrameRouteStoreDiagnostics:
        ChatTimelineStoreDiagnosticsSnapshot?
    private var openScenarioArchiveCursorKind:
        ChatOpenRealPipelineFixtureArchiveCursorKind = .none
    private var openScenarioQueryId: String?
    private var openScenarioArchiveTransportSession:
        ChatPerformanceFixtureArchiveTransportSession?
    private let openScenarioArchiveTransportQueue = DispatchQueue(
        label: "com.xabber.chat-performance.fixture-archive-transport",
        qos: .userInitiated
    )
    private let openScenarioTransportThreadRecorder =
        ChatOpenRealPipelineFixtureTransportThreadRecorder()
    private var openScenarioArchiveTransportGeneration: Int?
    private let openScenarioArchiveTransportLock = NSLock()
    private var openScenarioAllowedArchiveQueryIds: Set<String> = []
    private var openScenarioArchiveDescriptorsByQueryId:
        [String: ChatPerformanceFixtureArchiveRequestDescriptor] = [:]
    private var openScenarioRouteMeasurementHasStarted = false
    private var openScenarioFixtureRealmQueryCountAfterRouteAdmission = 0
    private var openScenarioPendingRemoteInjectionPlan:
        ChatOpenRealPipelineFixturePlan?
    private var openScenarioRemoteActionLatch =
        ChatOpenRealPipelineFixtureRemoteActionLatch()
    private var openScenarioDarwinAcknowledgementObserver:
        ChatOpenRealPipelineFixtureDarwinAcknowledgementObserver?
    private var openScenarioDeferredInitialBootstrapPlan:
        ChatOpenRealPipelineFixturePlan?
    internal var defersOpenScenarioInitialBootstrapRequestForTesting = false
    private(set) var
        openScenarioInitialBootstrapRequestInvocationCountForTesting = 0
    private var openScenarioStableReceiptGeneration = 0
    private var openScenarioTerminalPublicationGate =
        ChatOpenRealPipelineFixtureTerminalPublicationGate()
    private var openScenarioTerminalStabilityGate =
        ChatOpenRealPipelineFixtureTerminalStabilityGate()
    private var openScenarioTerminalStabilityReceipt:
        ChatOpenRealPipelineFixtureTerminalStabilityReceipt?
    private var openScenarioRouteStoreDiagnosticsBaseline:
        ChatTimelineStoreDiagnosticsSnapshot = .empty
    private var openScenarioUsesReusedTimelineSession = false
    private var openScenarioObservationDeadline: Date?
    private var openScenarioLastSampledOffsetY: CGFloat?
    private var openScenarioOffsetMutationEvidence =
        ChatOpenRealPipelineFixtureOffsetMutationEvidence()
    private var openScenarioAtomicInitialOffsetGate =
        ChatOpenRealPipelineFixtureAtomicInitialOffsetGate()
    private var openScenarioRotationOffsetGate =
        ChatOpenRealPipelineFixtureRotationOffsetGate()
    private var openScenarioLastRotationSourceSample:
        ChatOpenRealPipelineFixtureRotationSourceSample?
    private var openScenarioRotationBarrierDiagnostics =
        ChatOpenRealPipelineFixtureRotationBarrierDiagnostics()
    private var openScenarioHasCommittedViewport = false
    private var openScenarioOffsetSamplerGate =
        ChatOpenRealPipelineFixtureOffsetSamplerGate()
    private var openScenarioOffsetDisplayLink: CADisplayLink?
    private var openScenarioOffsetDisplayLinkGeneration: Int?
    private var openScenarioTerminalObservationPlan:
        ChatOpenRealPipelineFixturePlan?
    private var openScenarioTerminalObservationGeneration: Int?
    private var openScenarioSkeletonObservationPlan:
        ChatOpenRealPipelineFixturePlan?
    private var openScenarioSkeletonObservationDeadline: Date?
    private var openScenarioAutomaticInjectionPlan:
        ChatOpenRealPipelineFixturePlan?
    private var openScenarioAutomaticInjectionDisplayTimestamp: TimeInterval?
    private var openScenarioVideoMarkerGate =
        ChatOpenVideoMarkerPublicationGate()
    private var openScenarioVideoMarkerGeneration: Int?
    private var openScenarioFrozenTerminalEvidence:
        ChatOpenRealPipelineFixtureTerminalEvidenceSnapshot?
    private var openScenarioPendingStablePlan:
        ChatOpenRealPipelineFixturePlan?
    private var openScenarioPendingStableObservationGeneration: Int?
    private var openScenarioArtifactExportSession:
        ChatPerformanceArtifactExportSession?
    private var openScenarioArtifactFinalizationInFlight = false
    private var openScenarioVideoEvidenceFailureCode:
        ChatOpenVideoEvidenceTerminalFailureCode = .none
    private var openScenarioStableFrameSealDiagnostics:
        ChatOpenPerformanceStableFrameSealDiagnostics = .notAttempted
    private var openScenarioArtifactExportFailureCode:
        ChatPerformanceArtifactExportFailureCode = .none
    private var openScenarioArtifactTraceFailure:
        ChatPerformanceArtifactTraceContractFailureDiagnostics = .none
    private var openScenarioBoundPrimaryTraceContext:
        ChatOpenPerformanceTraceContext?
    private var openScenarioBoundLinkedTraceContexts:
        Set<ChatOpenPerformanceTraceContext> = []
    private var openScenarioInteractiveRemoteArchiveDispatcher:
        ChatPerformanceFixtureInteractiveRemoteArchiveDispatcher?
    private var openScenarioSkeletonPresentationBaseline:
        OpenScenarioSkeletonPresentationSnapshot?
    private var openScenarioSkeletonIdentityStable = true
    private var openScenarioSkeletonGeometryStable = true
    private var openScenarioSkeletonDwellMilliseconds = 0
    private var openScenarioActiveDwellPlan: ChatOpenRealPipelineFixturePlan?
    private var openScenarioActiveDwellStartedAt: TimeInterval?
    private var openScenarioPostInitialInteractionReady = false
    private var openScenarioPostInitialInteractionCount = 0
    private var openScenarioPagingRetainedAnchor: ChatHistoryPageAnchor?
    private var openScenarioPagingAnchorErrorMilliPoints: Int?
    private var openScenarioRotationTransitionCount = 0
    private var openScenarioApplicationBackgroundCount = 0
    private var openScenarioApplicationForegroundCount = 0
    private var openScenarioLifecycleObservationTokens: [NSObjectProtocol] = []
    /// Every fixture callback scheduled onto main owns the lifecycle turn in
    /// which it was created. Explicit hosted teardown does not receive
    /// `viewWillDisappear`, so it must synchronously revoke that turn before
    /// the next fixture for the same deterministic conversation is created.
    private var openScenarioLifecycleGeneration = 1
    private var openScenarioTerminalTeardownCompleted = false
    private var openScenarioRouteHostDiagnostics:
        ChatPerformanceRouteHostDiagnostics = .zero
    private var openScenarioRouteHostDidBegin = false
    private var openScenarioRouteHostDidComplete = false
    private(set) var p14MentionReadCommittedCountForTesting = 0
    private var p14RequestAdmissionCount = 0
    private var p14RequestAdmissionBeforeViewLoadCount = 0
    private var p14GroupConversationProofCount = 0
    private var p14ExplicitRequestCount = 0
    private var p14UnreadRequestCount = 0
    private var p14SavedRequestCount = 0
    private var p14LatestRequestCount = 0
    private var p14MentionUnreadFrameCount = 0
    private var p14MentionSavedFrameCount = 0
    private var p14MentionReadEagerMutationCount = 0
    private var p14MentionReadScheduledCount = 0
    private var p14MentionReadTerminalSuccessCount = 0
    private var p14MentionReadTerminalFailureCount = 0
    private var p14MentionUnreadBeforeTap = false
    private var p14MentionUnreadAtAdmission = false
    private var p14MentionUnreadAtInitialCommit = false
    private var p14MentionReadAtTerminal = false
    private var p14MentionFreshRealmMatchCount = 0
    private var p14MentionFreshRealmProofFailureCount = 0
    private var p14DidCapturePreTapProof = false
    private var p14NativeDidShowCompleted = false
    private var p14InitialCommitUnreadProofCompleted = false
    private var p14DidIssuePresentationReceipt = false
    private var p14InitialFrameCommitEffectToken:
        ChatInitialFrameEffectToken?
    private var p14InitialCommitUnreadProofEffectToken:
        ChatInitialFrameEffectToken?
    private var p14PresentationReceiptEffectToken:
        ChatInitialFrameEffectToken?
    /// Cached only when the original admission path already had to sample
    /// UIKit presentation and realized rows. Diagnostics reuse this exact
    /// sample and never perform a second geometry scan.
    private struct P14ReceiptReadinessPresentationSample {
        let snapshot: ChatReadVisiblePresentationSnapshot
        let snapshotAccepted: Bool
        let expectedTargetPrimary: String?
        let realizedIdentities:
            [String: ChatReadVisibleRowPresentationIdentity]?
    }

    private var p14ReceiptReadinessEvaluationCount = 0
    private var p14ReceiptReadinessLastBlocker:
        ChatPerformanceP14ReceiptReadinessDiagnostics.Blocker?
    private var p14ReceiptReadinessLastPresentationSample:
        P14ReceiptReadinessPresentationSample?
    /// The coordinator intentionally keeps its successful-flush counter
    /// across invalidations. P14 evidence, however, belongs to one exact
    /// initial-frame owner, so diagnostics expose only the delta since that
    /// owner was adopted.
    private var p14ReadSuccessfulFlushCountBaseline = 0
    private var p14FreshRealmProofNextIdentifier: UInt64 = 0
    private var p14FreshRealmProofLeases:
        [UInt64: P14FreshRealmProofLease] = [:]
    private var p14HeldFreshRealmProofIdentifiers: Set<UInt64> = []
    private var p14MentionFreshRealmProofInFlightCount: Int {
        p14FreshRealmProofLeases.count
    }
    private(set) var isP13DeletedMentionTapBoundaryPreparedForTesting = false
    private(set) var isP13NoFollowingBranchForTesting = false
    internal var p14InitialCommitFreshRealmProofExecutorForTests:
        ((@escaping () -> Void) -> Void)?
    /// Holds the already-queried immutable result before it returns to main.
    /// Production leaves this nil; the focused test uses it to supersede an
    /// owner at the last asynchronous boundary.
    internal var p14FreshRealmProofResultDeliveryExecutorForTests:
        ((@escaping () -> Void) -> Void)?
    /// Deterministically pauses an admitted worker at the final boundary
    /// before Realm is queried. Production leaves this nil.
    internal var p14FreshRealmProofWorkerBeforeQueryExecutorForTests:
        ((@escaping () -> Void) -> Void)?
    internal var p14FreshRealmProofQueryObserverForTests: (() -> Void)?
    /// Called by the installed production diagnostics handler only after an
    /// accepted P14 commit has been recorded. It lets the hosted regression
    /// request a real second Dataset preparation without manufacturing a
    /// generation or effect token.
    internal var p14InitialFrameCommitRecordedForTests:
        ((ChatPerformanceInitialFrameCommitDiagnostics) -> Void)?
    private let p14MentionFreshRealmProofQueue = DispatchQueue(
        label: "com.xabber.chat-performance.p14-fresh-realm-proof",
        qos: .userInitiated
    )
    private(set) var openScenarioConsumedRemoteHistoryActions:
        [ChatPerformanceFixtureRemoteHistoryAction] = []
    private(set) var openScenarioStableReceipt: ChatOpenRealPipelineFixtureDiagnostics?
    var openScenarioDidStabilize: ((ChatOpenRealPipelineFixtureDiagnostics) -> Void)?

    internal var isOpenScenarioPublishedEvidenceAcceptedForTesting: Bool {
        guard openScenarioStableReceipt?.isStable == true else { return false }
        return openScenarioArtifactExportSession?.didFinalizeSuccessfully ?? true
    }

    internal var openScenarioStableAccessibilitySummaryForTesting: String? {
        openStableLabel.text
    }

    internal var isOpenScenarioExternalSkeletonAcknowledgementArmedForTesting: Bool {
        guard let plan = openScenarioPendingRemoteInjectionPlan else {
            return false
        }
        return openScenarioDarwinAcknowledgementObserver != nil &&
            hasCommittedBootstrapSkeletonPresentationInCurrentLifecycle &&
            appliedBootstrapLoadingState?.showsSkeleton == true &&
            openScenarioSkeletonRowCount == plan.expectedInitialSkeletonRowCount
    }

    internal var isOpenScenarioArchiveTransportReadyForRouteAdmissionForTesting:
        Bool {
        openScenarioArchiveTransportGeneration != nil &&
            openScenarioArchiveTransportSession != nil &&
            performanceFixtureArchiveTransportProvider != nil &&
            performanceFixtureArchiveTransportExecutor != nil &&
            performanceFixtureArchiveTransportDidStartHandler != nil &&
            performanceFixtureArchiveTransportCancellationHandler != nil
    }

    internal var isOpenScenarioRemoteActionAcknowledgementPendingForTesting: Bool {
        openScenarioRemoteActionLatch.hasPendingAcknowledgement
    }

    internal var openScenarioRemoteActionDispatchCountForTesting: Int {
        openScenarioRemoteActionLatch.dispatchCount
    }

    init(descriptor: ChatPerformanceUITestLaunchDescriptor) {
        self.descriptor = descriptor
        self.scenarioState = ChatPerformanceScenarioContract.initial(scale: descriptor.scale)
        super.init(nibName: nil, bundle: nil)
        if let scenario = descriptor.openScenario {
            owner = "chat-open-fixture-\(scenario.rawValue)-owner@invalid"
            jid = "chat-open-fixture-\(scenario.rawValue)-peer@invalid"
        } else {
            owner = "chat-performance-owner@invalid"
            jid = "chat-performance-peer@invalid"
        }
        conversationType = descriptor.openScenario ==
            .lastChatsSeededMentionExact ||
            descriptor.openScenario == .mentionDeletedAdvance
            ? .group
            : .regular
        if let scenario = descriptor.openScenario {
            do {
                openScenarioArtifactExportSession = try
                    ChatPerformanceArtifactExportSession.makeIfRequested()
                try prepareOpenScenarioRealm(
                    plan: ChatOpenRealPipelineFixturePlan(scenario: scenario)
                )
                if scenario == .lastChatsSeededMentionExact {
                    installP14ProductionObservers()
                }
            } catch {
                openScenarioSetupFailure = String(describing: type(of: error))
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private struct P14FreshMentionState {
        let matchingPersistedCount: Int
        let isRead: Bool?
    }

    private enum P14FreshRealmProofPurpose: Equatable {
        case initialUnread
        case terminalRead

        var expectedRead: Bool {
            switch self {
            case .initialUnread:
                return false
            case .terminalRead:
                return true
            }
        }
    }

    private struct P14FreshRealmProofLease {
        let identifier: UInt64
        let lifecycleGeneration: Int
        let effectToken: ChatInitialFrameEffectToken
        let purpose: P14FreshRealmProofPurpose
    }

    private func queryP14FreshMentionState() -> P14FreshMentionState {
        guard descriptor.openScenario == .lastChatsSeededMentionExact else {
            return P14FreshMentionState(
                matchingPersistedCount: 0,
                isRead: nil
            )
        }
        do {
            let plan = ChatOpenRealPipelineFixturePlan(
                scenario: .lastChatsSeededMentionExact
            )
            let expectedArchivedId = openArchiveId(
                plan.p14ExplicitMentionOrdinal
            )
            let expectedPrimary = p14MentionNotificationPrimaryForTesting
            let realm = try WRealm.safe()
            let matching = realm.objects(NotificationStorageItem.self)
                .filter(
                    "owner == %@ AND category_ == %@ AND associatedJid == %@",
                    owner,
                    XMPPNotificationsManager.Category.mention.rawValue,
                    jid
                )
                .filter {
                    $0.primary == expectedPrimary &&
                        $0.sourceConversationType == .group &&
                        $0.sourceChatJid == self.jid &&
                        $0.sourceArchivedId == expectedArchivedId
                }
            return P14FreshMentionState(
                matchingPersistedCount: matching.count,
                isRead: matching.count == 1 ? matching.first?.isRead : nil
            )
        } catch {
            return P14FreshMentionState(
                matchingPersistedCount: 0,
                isRead: nil
            )
        }
    }

    private func recordP14FreshMentionState(
        _ state: P14FreshMentionState,
        expectedRead: Bool,
        assign: (Bool) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        p14MentionFreshRealmMatchCount = state.matchingPersistedCount
        let matches = state.matchingPersistedCount == 1 &&
            state.isRead == expectedRead
        if !matches {
            p14MentionFreshRealmProofFailureCount &+= 1
        }
        if !expectedRead, state.isRead == true {
            p14MentionReadEagerMutationCount &+= 1
        }
        // Assignment may synchronously publish terminal accessibility
        // evidence, so every counter must already describe this exact proof.
        assign(matches)
    }

    @discardableResult
    internal func captureP14MentionPreTapProofIfNeeded() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard descriptor.openScenario == .lastChatsSeededMentionExact else {
            return false
        }
        if !p14DidCapturePreTapProof {
            p14DidCapturePreTapProof = true
            recordP14FreshMentionState(
                queryP14FreshMentionState(),
                expectedRead: false
            ) { [weak self] in
                self?.p14MentionUnreadBeforeTap = $0
            }
        }
        return p14MentionUnreadBeforeTap
    }

    internal var p14RequestAdmissionCountForTesting: Int {
        p14RequestAdmissionCount
    }

    internal var p14RequestAdmissionBeforeViewLoadCountForTesting: Int {
        p14RequestAdmissionBeforeViewLoadCount
    }

    internal var p14GroupConversationProofCountForTesting: Int {
        p14GroupConversationProofCount
    }

    internal var p14ExplicitRequestCountForTesting: Int {
        p14ExplicitRequestCount
    }

    internal var p14UnreadRequestCountForTesting: Int {
        p14UnreadRequestCount
    }

    internal var p14SavedRequestCountForTesting: Int {
        p14SavedRequestCount
    }

    internal var p14LatestRequestCountForTesting: Int {
        p14LatestRequestCount
    }

    internal var p14NativeDidShowCompletedForTesting: Bool {
        p14NativeDidShowCompleted
    }

    internal var p14InitialCommitUnreadProofCompletedForTesting: Bool {
        p14InitialCommitUnreadProofCompleted
    }

    internal var p14DidIssuePresentationReceiptForTesting: Bool {
        p14DidIssuePresentationReceipt
    }

    internal var p14InitialFrameCommitEffectTokenForTesting:
        ChatInitialFrameEffectToken? {
        p14InitialFrameCommitEffectToken
    }

    internal var p14InitialCommitUnreadProofEffectTokenForTesting:
        ChatInitialFrameEffectToken? {
        p14InitialCommitUnreadProofEffectToken
    }

    internal var p14PresentationReceiptEffectTokenForTesting:
        ChatInitialFrameEffectToken? {
        p14PresentationReceiptEffectToken
    }

    internal var p14ReceiptReadinessDiagnosticsForTesting:
        ChatPerformanceP14ReceiptReadinessDiagnostics? {
        guard let blocker = p14ReceiptReadinessLastBlocker else { return nil }
        let proofEffectToken = p14InitialCommitUnreadProofEffectToken
        let initialFrameEffectToken = p14InitialFrameCommitEffectToken
        let latestEffectToken = initialLocalFirstFrameLatestEffectToken
        let presentationSample = p14ReceiptReadinessLastPresentationSample
        let expectedTargetPrimary =
            presentationSample?.expectedTargetPrimary ?? openPrimary(
                ChatOpenRealPipelineFixturePlan(
                    scenario: .lastChatsSeededMentionExact
                ).p14ExplicitMentionOrdinal
            )
        let realizedIdentities = presentationSample?.realizedIdentities
        let viewHierarchyVisibility =
            presentationSample?.snapshot.isWindowAttached == false
            ? readVisibleViewHierarchyDiagnosticsForTesting()
            : nil
        return ChatPerformanceP14ReceiptReadinessDiagnostics(
            blocker: blocker,
            evaluationCount: p14ReceiptReadinessEvaluationCount,
            isExpectedScenario:
                descriptor.openScenario == .lastChatsSeededMentionExact,
            terminalTeardownCompleted: openScenarioTerminalTeardownCompleted,
            proofEffectToken: proofEffectToken,
            initialFrameEffectToken: initialFrameEffectToken,
            latestEffectToken: latestEffectToken,
            proofOwnerMatchesInitialFrame: proofEffectToken != nil &&
                proofEffectToken == initialFrameEffectToken,
            proofOwnerIsLatest: proofEffectToken.map {
                isLatestInitialFrameEffectToken($0)
            } ?? false,
            nativeDidShowCompleted: p14NativeDidShowCompleted,
            routeHostDidComplete: openScenarioRouteHostDidComplete,
            initialUnreadProofCompleted:
                p14InitialCommitUnreadProofCompleted,
            didIssueReceipt: p14DidIssuePresentationReceipt,
            visualCommitCount: openScenarioProductionVisualCommitCount,
            targetMatchCount: openScenarioTargetMatchCount,
            latestVisualCommitCount: openScenarioLatestVisualCommitCount,
            anchorError: openScenarioViewportDiagnostics?.anchorError,
            hasPendingOpenMessageRequest: pendingOpenMessageRequest != nil,
            hasActiveAnchorExecution: activeAnchorExecutionState != nil,
            isDatasourceStructuralTransactionActive:
                isChatDatasourceStructuralTransactionActive,
            presentationSnapshot: presentationSample?.snapshot,
            presentationSnapshotAccepted:
                presentationSample?.snapshotAccepted,
            viewHierarchyVisibility: viewHierarchyVisibility,
            expectedTargetPrimary: expectedTargetPrimary,
            realizedTargetIdentity:
                realizedIdentities?[expectedTargetPrimary],
            realizedMessagePrimaries: realizedIdentities.map {
                Set($0.keys)
            } ?? [],
            realizedMessageCount: realizedIdentities?.count ?? 0,
            datasourceGeneration: scrollResidentMetadata.generation,
            coordinatorLifecycleState:
                readVisiblePresentationCoordinator.lifecycleState,
            coordinatorGeneration:
                readVisiblePresentationCoordinator.generation,
            coordinatorGeometryGeneration:
                readVisiblePresentationCoordinator.geometryGeneration,
            pendingCandidateCount:
                readVisiblePresentationCoordinator.pendingCandidateCount,
            inFlightFlushCount:
                readVisiblePresentationCoordinator.inFlightFlushCount,
            initialFramePhase: initialLocalFirstFramePhase,
            isInitialBootstrapInFlight: isInitialBootstrapInFlight,
            showsSkeleton: showSkeletonObserver.value,
            isApplyingBootstrapAnchorWindow:
                isApplyingBootstrapAnchorWindow,
            isPreparingStackedNavigationPresentation:
                isPreparingStackedNavigationPresentation,
            isNavigationTransitionActive: isNavigationTransitionActive,
            hasControllerTransitionCoordinator: transitionCoordinator != nil,
            hasNavigationTransitionCoordinator:
                navigationController?.transitionCoordinator != nil
        )
    }

    internal func p14TargetGeometrySnapshotForTesting()
        -> ChatPerformanceP14TargetGeometrySnapshot {
        dispatchPrecondition(condition: .onQueue(.main))
        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .lastChatsSeededMentionExact
        )
        let expectedTargetPrimary = openPrimary(plan.p14ExplicitMentionOrdinal)
        let targetSection = datasourceSnapshot.primaryIndex[expectedTargetPrimary]
        let targetIndexPath = targetSection.map {
            IndexPath(item: 0, section: $0)
        }
        let visibleIndexPaths = messagesCollectionView.indexPathsForVisibleItems
            .sorted {
                if $0.section != $1.section {
                    return $0.section < $1.section
                }
                return $0.item < $1.item
            }
        let targetLayoutFrame = targetIndexPath.flatMap {
            messagesCollectionView.collectionViewLayout
                .layoutAttributesForItem(at: $0)?.frame
        }
        let targetCellFrame = targetIndexPath.flatMap {
            messagesCollectionView.cellForItem(at: $0)?.frame
        }
        var readViewport = messagesCollectionView.bounds
        let adjustedContentInset = messagesCollectionView.adjustedContentInset
        readViewport.origin.x += adjustedContentInset.left
        readViewport.origin.y += adjustedContentInset.top
        readViewport.size.width = max(
            0,
            readViewport.width - adjustedContentInset.left -
                adjustedContentInset.right
        )
        readViewport.size.height = max(
            0,
            readViewport.height - adjustedContentInset.top -
                adjustedContentInset.bottom
        )
        let originalViewportRelativeMinY: CGFloat? = {
            guard case .message(let anchor) =
                    openScenarioViewportDiagnostics?.anchorStrategy else {
                return nil
            }
            return anchor.viewportRelativeMinY
        }()
        let liveLayoutRelativeMinY = targetLayoutFrame.map {
            $0.minY - messagesCollectionView.contentOffset.y
        }
        let liveCellRelativeMinY = targetCellFrame.map {
            $0.minY - messagesCollectionView.contentOffset.y
        }
        let layoutIntersection = targetLayoutFrame.map {
            $0.intersection(readViewport)
        }
        let cellIntersection = targetCellFrame.map {
            $0.intersection(readViewport)
        }

        return ChatPerformanceP14TargetGeometrySnapshot(
            uptime: ProcessInfo.processInfo.systemUptime,
            viewFrame: view.frame,
            viewBounds: view.bounds,
            viewSafeAreaInsets: view.safeAreaInsets,
            collectionFrame: messagesCollectionView.frame,
            collectionBounds: messagesCollectionView.bounds,
            contentOffset: messagesCollectionView.contentOffset,
            contentSize: messagesCollectionView.contentSize,
            contentInset: messagesCollectionView.contentInset,
            adjustedContentInset: adjustedContentInset,
            readViewport: readViewport,
            targetPresentInDatasource: targetSection.map { section in
                datasource.indices.contains(section) &&
                    datasource[section].primary == expectedTargetPrimary
            } ?? false,
            targetSection: targetSection,
            visibleIndexPaths: visibleIndexPaths,
            visibleMessagePrimaries: visibleIndexPaths.compactMap {
                datasourceItem(at: $0)?.primary
            },
            targetInVisibleIndexPaths: targetIndexPath.map {
                visibleIndexPaths.contains($0)
            } ?? false,
            targetCellExists: targetCellFrame != nil,
            targetLayoutFrame: targetLayoutFrame,
            targetCellFrame: targetCellFrame,
            originalViewportRelativeMinY: originalViewportRelativeMinY,
            liveLayoutRelativeMinY: liveLayoutRelativeMinY,
            liveCellRelativeMinY: liveCellRelativeMinY,
            liveLayoutAnchorError: liveLayoutRelativeMinY.flatMap { liveY in
                originalViewportRelativeMinY.map { abs(liveY - $0) }
            },
            liveCellAnchorError: liveCellRelativeMinY.flatMap { liveY in
                originalViewportRelativeMinY.map { abs(liveY - $0) }
            },
            layoutIntersection: layoutIntersection,
            cellIntersection: cellIntersection,
            layoutMeaningfullyVisible: targetLayoutFrame.map {
                ChatReadVisiblePresentationPolicy.isMeaningfullyVisible(
                    itemFrame: $0,
                    viewport: readViewport
                )
            },
            cellMeaningfullyVisible: targetCellFrame.map {
                ChatReadVisiblePresentationPolicy.isMeaningfullyVisible(
                    itemFrame: $0,
                    viewport: readViewport
                )
            },
            committedDiagnosticGeneration:
                openScenarioCommittedInitialFrameDiagnostics?
                    .initialFrameEffectToken.presentationGeneration,
            fixtureFrameGeneration:
                p14InitialFrameCommitEffectToken?.presentationGeneration,
            latestGeneration:
                initialLocalFirstFrameLatestEffectToken?
                    .presentationGeneration,
            proofGeneration:
                p14InitialCommitUnreadProofEffectToken?
                    .presentationGeneration,
            datasourceGeneration: scrollResidentMetadata.generation
        )
    }

    internal var p14FreshRealmProofInFlightCountForTesting: Int {
        p14MentionFreshRealmProofInFlightCount
    }

    internal var p14ProductionVisualCommitCountForTesting: Int {
        openScenarioProductionVisualCommitCount
    }

    internal var p14ViewportDiagnosticsForTesting:
        ChatViewportTransactionDiagnostics? {
        openScenarioViewportDiagnostics
    }

    internal var p14TargetMatchCountForTesting: Int {
        openScenarioTargetMatchCount
    }

    internal var p14LatestVisualCommitCountForTesting: Int {
        openScenarioLatestVisualCommitCount
    }

    internal var p14MentionDiagnosticsForTesting:
        ChatPerformanceP14MentionDiagnostics {
        captureP14MentionDiagnostics()
    }

    internal var isP14ObserverTeardownCompleteForTesting: Bool {
        descriptor.openScenario == .lastChatsSeededMentionExact &&
            openScenarioTerminalTeardownCompleted &&
            performanceOpenMessageRequestAdmissionObserver == nil &&
            visibleMentionReadScheduledForTests == nil &&
            visibleMentionReadAfterFirstPersistentMutationBarrierForTests == nil &&
            visibleMentionReadTerminalForTests == nil &&
            visibleMentionReadScheduledEffectTokenForTests == nil &&
            visibleMentionReadAfterFirstPersistentMutationEffectTokenForTests == nil &&
            visibleMentionReadTerminalEffectTokenForTests == nil &&
            p14InitialCommitFreshRealmProofExecutorForTests == nil &&
            p14FreshRealmProofResultDeliveryExecutorForTests == nil &&
            p14FreshRealmProofWorkerBeforeQueryExecutorForTests == nil &&
            p14FreshRealmProofQueryObserverForTests == nil &&
            p14InitialFrameCommitRecordedForTests == nil &&
            p14FreshRealmProofLeases.isEmpty &&
            p14HeldFreshRealmProofIdentifiers.isEmpty &&
            !p14InitialCommitUnreadProofCompleted &&
            p14InitialFrameCommitEffectToken == nil &&
            p14InitialCommitUnreadProofEffectToken == nil &&
            p14PresentationReceiptEffectToken == nil &&
            p14ReceiptReadinessEvaluationCount == 0 &&
            p14ReceiptReadinessLastBlocker == nil &&
            p14ReceiptReadinessLastPresentationSample == nil &&
            visibleUnreadMentionReconciliationWorkItem == nil &&
            readVisibleStableLayoutRetryWorkItem == nil &&
            readVisiblePresentationCoordinator.pendingCandidateCount == 0 &&
            readVisiblePresentationCoordinator.inFlightFlushCount == 0 &&
            p14MentionFreshRealmProofInFlightCount == 0
    }

    private func installP14ProductionObservers() {
        performanceOpenMessageRequestAdmissionObserver = {
            [weak self] request, wasViewLoaded in
            self?.recordP14RequestAdmission(
                request,
                wasViewLoaded: wasViewLoaded
            )
        }
        // Generic observers intentionally remain installed for existing
        // read-path diagnostics, but P14 counters are owned exclusively by
        // the exact-token companions below.
        visibleMentionReadScheduledForTests = { _ in }
        visibleMentionReadAfterFirstPersistentMutationBarrierForTests = {}
        visibleMentionReadTerminalForTests = { _ in }
        visibleMentionReadScheduledEffectTokenForTests = {
            [weak self] candidateCount, effectToken in
            guard let self,
                  candidateCount > 0,
                  let effectToken,
                  effectToken == self.p14InitialFrameCommitEffectToken,
                  self.isLatestInitialFrameEffectToken(effectToken) else {
                return
            }
            self.p14MentionReadScheduledCount &+= candidateCount
        }
        visibleMentionReadAfterFirstPersistentMutationEffectTokenForTests = {
            [weak self] effectToken in
            DispatchQueue.main.async {
                guard let self,
                      let effectToken,
                      effectToken == self.p14PresentationReceiptEffectToken,
                      self.isLatestInitialFrameEffectToken(effectToken) else {
                    return
                }
                self.p14MentionReadCommittedCountForTesting &+= 1
            }
        }
        visibleMentionReadTerminalEffectTokenForTests = {
            [weak self] succeeded, effectToken in
            let record = {
                guard let self,
                      let effectToken,
                      effectToken == self.p14PresentationReceiptEffectToken,
                      self.isLatestInitialFrameEffectToken(effectToken) else {
                    return
                }
                if succeeded {
                    self.p14MentionReadTerminalSuccessCount &+= 1
                    self.scheduleP14TerminalFreshRealmProof(
                        effectToken: effectToken
                    )
                } else {
                    self.p14MentionReadTerminalFailureCount &+= 1
                }
            }
            if Thread.isMainThread {
                record()
            } else {
                DispatchQueue.main.async(execute: record)
            }
        }
    }

    private func recordP14RequestAdmission(
        _ request: ChatOpenMessageRequest,
        wasViewLoaded: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard descriptor.openScenario == .lastChatsSeededMentionExact else {
            return
        }
        p14RequestAdmissionCount &+= 1
        if !wasViewLoaded {
            p14RequestAdmissionBeforeViewLoadCount &+= 1
        }
        if request.conversationType == .group && conversationType == .group {
            p14GroupConversationProofCount &+= 1
        }
        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .lastChatsSeededMentionExact
        )
        if request.source == .mentionNotification,
           request.anchor.archivedId == openArchiveId(
            plan.p14ExplicitMentionOrdinal
           ) {
            p14ExplicitRequestCount &+= 1
        } else if request.source == .initialUnreadBoundary ||
                    request.anchor.archivedId == openArchiveId(
                        plan.p14UnreadTargetOrdinal
                    ) {
            p14UnreadRequestCount &+= 1
        } else if request.source == .savedVisiblePosition ||
                    request.anchor.messagePrimary == openPrimary(
                        plan.p14SavedTargetOrdinal
                    ) {
            p14SavedRequestCount &+= 1
        } else {
            p14LatestRequestCount &+= 1
        }
        recordP14FreshMentionState(
            queryP14FreshMentionState(),
            expectedRead: false
        ) { [weak self] in
            self?.p14MentionUnreadAtAdmission = $0
        }
    }

    private func adoptP14InitialFrameCommitEffectToken(
        _ effectToken: ChatInitialFrameEffectToken
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard p14InitialFrameCommitEffectToken != effectToken else { return }
        p14ReceiptReadinessEvaluationCount = 0
        p14ReceiptReadinessLastBlocker = nil
        p14ReceiptReadinessLastPresentationSample = nil

        // Ownership replacement is eager: after B is adopted no queued,
        // admitted or result-held A proof remains represented as in flight.
        // Already-running immutable A closures may drain, but every later
        // boundary fails the missing exact-ID lease and becomes a no-op.
        let retainedLeaseIdentifiers = Set(
            p14FreshRealmProofLeases.compactMap { identifier, lease in
                lease.effectToken == effectToken ? identifier : nil
            }
        )
        p14FreshRealmProofLeases = p14FreshRealmProofLeases.filter {
            $0.value.effectToken == effectToken
        }
        p14HeldFreshRealmProofIdentifiers.formIntersection(
            retainedLeaseIdentifiers
        )

        if p14InitialFrameCommitEffectToken != nil {
            // B replaces every attempt-scoped diagnostic owned by A, while
            // route admission, pre-tap and native didShow evidence remain
            // controller-lifecycle facts. Core will enqueue B's candidate
            // after the exact commit callback returns.
            readVisiblePresentationCoordinator.beginPresentationPreparation()
            p14MentionReadScheduledCount = 0
            p14MentionReadCommittedCountForTesting = 0
            p14MentionReadTerminalSuccessCount = 0
            p14MentionReadTerminalFailureCount = 0
            p14MentionUnreadAtInitialCommit = false
            p14MentionReadAtTerminal = false
            p14MentionFreshRealmProofFailureCount = 0
        }
        p14ReadSuccessfulFlushCountBaseline =
            readVisiblePresentationCoordinator.successfulFlushCount
        p14InitialCommitUnreadProofCompleted = false
        p14DidIssuePresentationReceipt = false
        p14InitialCommitUnreadProofEffectToken = nil
        p14PresentationReceiptEffectToken = nil
        p14InitialFrameCommitEffectToken = effectToken
    }

    internal func scheduleP14ReplacementInitialCommitProofForTesting(
        effectToken: ChatInitialFrameEffectToken
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isLatestInitialFrameEffectToken(effectToken) else { return }
        adoptP14InitialFrameCommitEffectToken(effectToken)
        scheduleP14InitialCommitFreshRealmProof(effectToken: effectToken)
    }

    private func scheduleP14InitialCommitFreshRealmProof(
        effectToken: ChatInitialFrameEffectToken
    ) {
        scheduleP14FreshRealmProof(
            purpose: .initialUnread,
            effectToken: effectToken,
            executor: p14InitialCommitFreshRealmProofExecutorForTests
        ) { [weak self] matches in
            guard let self,
                  effectToken == self.p14InitialFrameCommitEffectToken,
                  self.isLatestInitialFrameEffectToken(effectToken) else {
                return
            }
            self.p14MentionUnreadAtInitialCommit = matches
            guard matches else {
                self.openScenarioSetupFailure = String(
                    describing: OpenScenarioError.p14InitialUnreadProofRejected
                )
                self.publishOpenScenarioFailure(
                    plan: ChatOpenRealPipelineFixturePlan(
                        scenario: .lastChatsSeededMentionExact
                    )
                )
                return
            }
            self.p14InitialCommitUnreadProofCompleted = true
            self.p14InitialCommitUnreadProofEffectToken = effectToken
            self.issueP14ProductionPresentationReceiptIfReady()
        }
    }

    private func scheduleP14TerminalFreshRealmProof(
        effectToken: ChatInitialFrameEffectToken
    ) {
        scheduleP14FreshRealmProof(
            purpose: .terminalRead,
            effectToken: effectToken
        ) { [weak self] matches in
            guard let self,
                  effectToken == self.p14PresentationReceiptEffectToken,
                  self.isLatestInitialFrameEffectToken(effectToken) else {
                return
            }
            self.p14MentionReadAtTerminal = matches
        }
    }

    private func validateP14FreshRealmProofLeaseOnMain(
        identifier: UInt64,
        lifecycleGeneration: Int,
        effectToken: ChatInitialFrameEffectToken,
        purpose: P14FreshRealmProofPurpose
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let currentLease = p14FreshRealmProofLeases[identifier],
              currentLease.identifier == identifier,
              currentLease.lifecycleGeneration == lifecycleGeneration,
              currentLease.effectToken == effectToken,
              currentLease.purpose == purpose else {
            return false
        }
        guard !openScenarioTerminalTeardownCompleted,
              isOpenScenarioLifecycleCurrent(
                generation: lifecycleGeneration
              ),
              isLatestInitialFrameEffectToken(effectToken) else {
            p14FreshRealmProofLeases.removeValue(forKey: identifier)
            p14HeldFreshRealmProofIdentifiers.remove(identifier)
            return false
        }
        return true
    }

    private func validateP14FreshRealmProofLeaseAtQueryBoundary(
        identifier: UInt64,
        lifecycleGeneration: Int,
        effectToken: ChatInitialFrameEffectToken,
        purpose: P14FreshRealmProofPurpose
    ) -> Bool {
        let validate = { [weak self] in
            self?.validateP14FreshRealmProofLeaseOnMain(
                identifier: identifier,
                lifecycleGeneration: lifecycleGeneration,
                effectToken: effectToken,
                purpose: purpose
            ) ?? false
        }
        if Thread.isMainThread {
            return validate()
        }
        return DispatchQueue.main.sync(execute: validate)
    }

    private func scheduleP14FreshRealmProof(
        purpose: P14FreshRealmProofPurpose,
        effectToken: ChatInitialFrameEffectToken,
        executor: ((@escaping () -> Void) -> Void)? = nil,
        assign: @escaping (Bool) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard descriptor.openScenario == .lastChatsSeededMentionExact,
              !openScenarioTerminalTeardownCompleted,
              isLatestInitialFrameEffectToken(effectToken) else {
            return
        }
        let lifecycleGeneration = openScenarioLifecycleGeneration
        p14FreshRealmProofNextIdentifier &+= 1
        let identifier = p14FreshRealmProofNextIdentifier
        let lease = P14FreshRealmProofLease(
            identifier: identifier,
            lifecycleGeneration: lifecycleGeneration,
            effectToken: effectToken,
            purpose: purpose
        )
        p14FreshRealmProofLeases[identifier] = lease
        let resultDeliveryExecutor =
            p14FreshRealmProofResultDeliveryExecutorForTests
        let workerBeforeQueryExecutor =
            p14FreshRealmProofWorkerBeforeQueryExecutorForTests
        let queryObserver = p14FreshRealmProofQueryObserverForTests
        let proofWork = { [weak self] in
            guard let self else { return }
            let validateAndQuery = { [weak self] in
                guard let self,
                      self.validateP14FreshRealmProofLeaseAtQueryBoundary(
                        identifier: identifier,
                        lifecycleGeneration: lifecycleGeneration,
                        effectToken: effectToken,
                        purpose: purpose
                      ) else {
                    return
                }
                queryObserver?()
                let state = self.queryP14FreshMentionState()
                let deliver = { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              let currentLease =
                                self.p14FreshRealmProofLeases.removeValue(
                                    forKey: identifier
                                ),
                              currentLease.identifier == identifier,
                              currentLease.lifecycleGeneration ==
                                lifecycleGeneration,
                              currentLease.effectToken == effectToken,
                              currentLease.purpose == purpose,
                              !self.openScenarioTerminalTeardownCompleted,
                              self.isOpenScenarioLifecycleCurrent(
                                generation: lifecycleGeneration
                              ),
                              self.isLatestInitialFrameEffectToken(
                                effectToken
                              ) else {
                            return
                        }
                        // The final owner check is intentionally adjacent to
                        // every failure counter and assignment. A stale
                        // immutable Realm result cannot become hosted proof.
                        self.recordP14FreshMentionState(
                            state,
                            expectedRead: purpose.expectedRead,
                            assign: assign
                        )
                    }
                }
                if let resultDeliveryExecutor {
                    resultDeliveryExecutor(deliver)
                } else {
                    deliver()
                }
            }
            if let workerBeforeQueryExecutor {
                workerBeforeQueryExecutor(validateAndQuery)
            } else {
                validateAndQuery()
            }
        }
        let waitsForExplicitRelease = executor != nil
        if waitsForExplicitRelease {
            p14HeldFreshRealmProofIdentifiers.insert(identifier)
        }
        let admitProofWork = { [weak self] in
            let admitOnMain = { [weak self] in
                guard let self else { return }
                if waitsForExplicitRelease,
                   self.p14HeldFreshRealmProofIdentifiers.remove(
                    identifier
                   ) == nil {
                    return
                }
                guard let currentLease =
                        self.p14FreshRealmProofLeases[identifier],
                      currentLease.identifier == identifier,
                      currentLease.lifecycleGeneration ==
                        lifecycleGeneration,
                      currentLease.effectToken == effectToken,
                      currentLease.purpose == purpose,
                      !self.openScenarioTerminalTeardownCompleted,
                      self.isOpenScenarioLifecycleCurrent(
                        generation: lifecycleGeneration
                      ),
                      self.isLatestInitialFrameEffectToken(effectToken) else {
                    self.p14FreshRealmProofLeases.removeValue(
                        forKey: identifier
                    )
                    return
                }
                // This is the query-admission owner check. `proofWork` is the
                // immutable work captured for this ID; no mutable global work
                // slot can redirect A's release to B.
                self.p14MentionFreshRealmProofQueue.async(execute: proofWork)
            }
            if Thread.isMainThread {
                admitOnMain()
            } else {
                DispatchQueue.main.async(execute: admitOnMain)
            }
        }
        if let executor {
            executor(admitProofWork)
        } else {
            admitProofWork()
        }
    }

    internal func performanceP14NativeDidShowPresentationReceiptIfReady() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard descriptor.openScenario == .lastChatsSeededMentionExact else {
            return
        }
        p14NativeDidShowCompleted = true
        issueP14ProductionPresentationReceiptIfReady()
    }

    private func captureP14ReceiptReadiness()
        -> ChatInitialFrameEffectToken? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !openScenarioTerminalTeardownCompleted else { return nil }
        guard let effectToken = p14InitialCommitUnreadProofEffectToken else {
            recordP14ReceiptReadinessEvaluation(
                blocker: .missingInitialUnreadProofToken
            )
            return nil
        }
        guard effectToken == p14InitialFrameCommitEffectToken else {
            recordP14ReceiptReadinessEvaluation(
                blocker: .initialUnreadProofOwnerMismatch
            )
            return nil
        }
        guard isLatestInitialFrameEffectToken(effectToken) else {
            recordP14ReceiptReadinessEvaluation(
                blocker: .initialUnreadProofOwnerIsNotLatest
            )
            return nil
        }
        guard p14NativeDidShowCompleted else {
            recordP14ReceiptReadinessEvaluation(blocker: .nativeDidShowPending)
            return nil
        }
        guard openScenarioRouteHostDidComplete else {
            recordP14ReceiptReadinessEvaluation(
                blocker: .routeHostCompletionPending
            )
            return nil
        }
        guard p14InitialCommitUnreadProofCompleted else {
            recordP14ReceiptReadinessEvaluation(
                blocker: .initialUnreadProofPending
            )
            return nil
        }
        guard !p14DidIssuePresentationReceipt else {
            recordP14ReceiptReadinessEvaluation(blocker: .receiptAlreadyIssued)
            return nil
        }
        guard openScenarioProductionVisualCommitCount == 1 else {
            recordP14ReceiptReadinessEvaluation(
                blocker: .visualCommitCountMismatch
            )
            return nil
        }
        guard openScenarioTargetMatchCount == 1 else {
            recordP14ReceiptReadinessEvaluation(
                blocker: .targetMatchCountMismatch
            )
            return nil
        }
        guard openScenarioLatestVisualCommitCount == 0 else {
            recordP14ReceiptReadinessEvaluation(
                blocker: .latestVisualCommitCountMismatch
            )
            return nil
        }
        guard let anchorError = openScenarioViewportDiagnostics?.anchorError,
              abs(anchorError) <= 1 else {
            recordP14ReceiptReadinessEvaluation(
                blocker: .anchorErrorOutOfTolerance
            )
            return nil
        }
        guard pendingOpenMessageRequest == nil else {
            recordP14ReceiptReadinessEvaluation(
                blocker: .pendingOpenMessageRequest
            )
            return nil
        }
        guard activeAnchorExecutionState == nil else {
            recordP14ReceiptReadinessEvaluation(blocker: .activeAnchorExecution)
            return nil
        }
        guard !isChatDatasourceStructuralTransactionActive else {
            recordP14ReceiptReadinessEvaluation(
                blocker: .datasourceStructuralTransactionActive
            )
            return nil
        }

        // These are the same unavoidable samples used by admission. They are
        // captured once, cached by reference/value for failure reporting, and
        // never recomputed by the test-only diagnostics accessor.
        let presentationSnapshot = readVisiblePresentationSnapshot()
        guard ChatReadVisiblePresentationPolicy.canAdvanceReadState(
            hasPresentationReceipt: true,
            snapshot: presentationSnapshot
        ) else {
            recordP14ReceiptReadinessEvaluation(
                blocker: .presentationSnapshotRejected,
                presentationSample: P14ReceiptReadinessPresentationSample(
                    snapshot: presentationSnapshot,
                    snapshotAccepted: false,
                    expectedTargetPrimary: nil,
                    realizedIdentities: nil
                )
            )
            return nil
        }

        let plan = ChatOpenRealPipelineFixturePlan(
            scenario: .lastChatsSeededMentionExact
        )
        let expectedTargetPrimary = openPrimary(
            plan.p14ExplicitMentionOrdinal
        )
        let realizedIdentities =
            meaningfullyVisibleRealMessagePresentationIdentitiesForRead()
        let presentationSample = P14ReceiptReadinessPresentationSample(
            snapshot: presentationSnapshot,
            snapshotAccepted: true,
            expectedTargetPrimary: expectedTargetPrimary,
            realizedIdentities: realizedIdentities
        )
        guard realizedIdentities[expectedTargetPrimary] != nil else {
            recordP14ReceiptReadinessEvaluation(
                blocker: .realizedTargetIdentityMissing,
                presentationSample: presentationSample
            )
            return nil
        }
        recordP14ReceiptReadinessEvaluation(
            blocker: .ready,
            presentationSample: presentationSample
        )
        return effectToken
    }

    private func recordP14ReceiptReadinessEvaluation(
        blocker: ChatPerformanceP14ReceiptReadinessDiagnostics.Blocker,
        presentationSample: P14ReceiptReadinessPresentationSample? = nil
    ) {
        p14ReceiptReadinessEvaluationCount &+= 1
        if p14ReceiptReadinessLastBlocker != blocker {
            p14ReceiptReadinessLastBlocker = blocker
        }
        if let presentationSample {
            p14ReceiptReadinessLastPresentationSample = presentationSample
        }
    }

    private func updateP14ReceiptReadinessBlockerAfterGeometry(
        _ blocker: ChatPerformanceP14ReceiptReadinessDiagnostics.Blocker
    ) {
        guard p14ReceiptReadinessLastBlocker != nil else { return }
        p14ReceiptReadinessLastBlocker = blocker
    }

    private func issueP14ProductionPresentationReceiptIfReady() {
        guard descriptor.openScenario == .lastChatsSeededMentionExact else {
            return
        }
        guard let effectToken = captureP14ReceiptReadiness() else { return }
        synchronizeReadVisibleGeometryEpoch(scheduleStableRetry: false)
        guard effectToken == p14InitialFrameCommitEffectToken else {
            updateP14ReceiptReadinessBlockerAfterGeometry(
                .initialFrameOwnerChangedAfterGeometrySync
            )
            return
        }
        guard effectToken == p14InitialCommitUnreadProofEffectToken else {
            updateP14ReceiptReadinessBlockerAfterGeometry(
                .proofOwnerChangedAfterGeometrySync
            )
            return
        }
        guard isLatestInitialFrameEffectToken(effectToken) else {
            updateP14ReceiptReadinessBlockerAfterGeometry(
                .latestOwnerChangedAfterGeometrySync
            )
            return
        }
        guard !p14DidIssuePresentationReceipt else {
            updateP14ReceiptReadinessBlockerAfterGeometry(
                .receiptIssuedDuringGeometrySync
            )
            return
        }
        let handoff = recordReadVisiblePresentationReceiptHandoff()
        p14PresentationReceiptEffectToken = effectToken
        p14DidIssuePresentationReceipt = true
        updateP14ReceiptReadinessBlockerAfterGeometry(.issued)
        enqueuePendingReadStateRetry(for: handoff)
    }

    /// Installs a previously used production session before `viewDidLoad`.
    /// The absolute diagnostic checkpoint is captured before any request
    /// admission for this controller, so the terminal receipt reports an exact
    /// route delta without resetting or hiding earlier session work.
    func installOpenScenarioReusedTimelineSessionForTesting(
        _ session: ChatTimelineSession
    ) {
        precondition(!isViewLoaded)
        precondition(session.isConfigured(for: ChatTimelineConversationKey(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )))
        timelineSession = session
        openScenarioRouteStoreDiagnosticsBaseline =
            session.routeStoreDiagnosticsSnapshot
        openScenarioUsesReusedTimelineSession = true
    }

    /// A production notification route delivers its exact intent before UIKit
    /// prepares the destination view. Arm the isolated archive seam at that
    /// earlier boundary so the fixture follows the same request ordering
    /// without falling through to an account or UI-action network stream.
    @discardableResult
    internal func prepareOpenScenarioArchiveTransportForRouteAdmission() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !openScenarioTerminalTeardownCompleted,
              let scenario = descriptor.openScenario else {
            return false
        }
        let plan = ChatOpenRealPipelineFixturePlan(scenario: scenario)
        guard plan.usesFixtureArchiveTransport else { return false }
        if openScenarioArchiveTransportGeneration == nil {
            openScenarioArchiveTransportGeneration =
                openScenarioTransportThreadRecorder.activate()
        }
        installOpenScenarioArchiveTransportIfNeeded(plan: plan)
        return isOpenScenarioArchiveTransportReadyForRouteAdmissionForTesting
    }

    internal func performanceRouteHostDidBeginNativePresentation(
        _ diagnostics: ChatPerformanceRouteHostDiagnostics
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !openScenarioTerminalTeardownCompleted,
              let scenario = descriptor.openScenario,
              scenario == .lastChatsAnimatedPush ||
                scenario == .coldPushExact ||
                scenario == .mentionDeletedAdvance ||
                scenario == .lastChatsSeededMentionExact,
              !openScenarioRouteHostDidBegin else {
            openScenarioSetupFailure = String(
                describing: OpenScenarioError.archiveDescriptorRejected
            )
            return
        }
        openScenarioRouteHostDidBegin = true
        openScenarioRouteHostDiagnostics = diagnostics
        renderOpenScenarioPhase(
            .preparing,
            plan: ChatOpenRealPipelineFixturePlan(scenario: scenario)
        )
    }

    internal func performanceRouteHostDidCompleteNativePresentation(
        _ diagnostics: ChatPerformanceRouteHostDiagnostics
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !openScenarioTerminalTeardownCompleted,
              let scenario = descriptor.openScenario,
              scenario == .lastChatsAnimatedPush ||
                scenario == .coldPushExact ||
                scenario == .mentionDeletedAdvance ||
                scenario == .lastChatsSeededMentionExact,
              openScenarioRouteHostDidBegin else {
            openScenarioSetupFailure = String(
                describing: OpenScenarioError.archiveDescriptorRejected
            )
            return
        }
        openScenarioRouteHostDidComplete = true
        openScenarioRouteHostDiagnostics = diagnostics
        let plan = ChatOpenRealPipelineFixturePlan(scenario: scenario)
        if scenario == .mentionDeletedAdvance,
           openScenarioStableReceipt != nil,
           !diagnostics.isAccepted(for: scenario) {
            revokePublishedP13StableReceipt(plan: plan)
            return
        }
        renderOpenScenarioPhase(
            ChatOpenRealPipelineNativeDidShowPhasePolicy.phase(
                hasCommittedContent:
                    openScenarioProductionVisualCommitCount == 1,
                hasCommittedBlockingSkeleton:
                    hasCommittedBootstrapSkeletonPresentationInCurrentLifecycle &&
                    appliedBootstrapLoadingState?.showsSkeleton == true &&
                    openScenarioSkeletonRowCount ==
                        plan.expectedInitialSkeletonRowCount
            ),
            plan: plan
        )
        beginOpenScenarioHostTerminalObservationIfReady()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = descriptor.openScenario.map { "Chat open \($0.rawValue)" }
            ?? "Chat performance \(descriptor.scale.rowCount)"
        view.accessibilityIdentifier = "chat.performance.screen"
        messagesCollectionView.accessibilityIdentifier = AccessibilityID.timeline
        configureFixtureChrome()
        if let scenario = descriptor.openScenario {
            configureOpenScenario(
                plan: ChatOpenRealPipelineFixturePlan(scenario: scenario)
            )
            return
        }
        xabberInputView.isSendButtonEnabled = true
        xabberInputView.updateComposerActionReadiness()
        performanceFixtureSendHandler = { [weak self] text in
            self?.appendOptimisticMessage(body: text)
        }
        DispatchQueue.main.async { [weak self] in
            self?.loadInitialFixture()
        }
    }

    // The fixture owns deterministic, unmanaged rows. It intentionally skips
    // Realm/XMPP subscriptions while still exercising ChatViewController's
    // production mapping, layout, diff, collection and composer code paths.
    override func viewWillAppear(_ animated: Bool) {}
    override func viewDidAppear(_ animated: Bool) {}

    override func viewWillDisappear(_ animated: Bool) {
        // The base controller owns the interactive-navigation contract: a
        // cancelled pop must preserve every chat and fixture resource, while
        // confirmed disappearance reaches the dynamic terminal override.
        super.viewWillDisappear(animated)
    }

    /// A fixture owns resources in addition to ChatViewController's generic
    /// lifecycle (the isolated MAM transport, Realm lease, Darwin latch and
    /// display-link evidence sampler). Hosted tests tear a controller down
    /// without UIKit disappearance, so this explicit seam is also the sole
    /// fixture terminal boundary. The inherited testing seam dynamically
    /// reaches the override below as well.
    internal func performOpenScenarioTerminalResourceTeardown() {
        performTerminalChatResourceTeardown()
    }

    override internal func performTerminalChatResourceTeardown() {
        performOpenScenarioOwnedResourceTeardownIfNeeded()
        super.performTerminalChatResourceTeardown()
    }

    private func performOpenScenarioOwnedResourceTeardownIfNeeded() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !openScenarioTerminalTeardownCompleted else { return }
        openScenarioTerminalTeardownCompleted = true
        openScenarioLifecycleGeneration &+= 1

        // Close DEBUG observation before invalidating coordinator work. A read
        // worker that has already crossed onto its serial queue must not enqueue
        // fixture counters or a fresh-Realm proof after lifecycle revocation.
        performanceOpenMessageRequestAdmissionObserver = nil
        visibleMentionReadScheduledForTests = nil
        visibleMentionReadAfterFirstPersistentMutationBarrierForTests = nil
        visibleMentionReadTerminalForTests = nil
        visibleMentionReadScheduledEffectTokenForTests = nil
        visibleMentionReadAfterFirstPersistentMutationEffectTokenForTests = nil
        visibleMentionReadTerminalEffectTokenForTests = nil
        p14InitialCommitFreshRealmProofExecutorForTests = nil
        p14FreshRealmProofResultDeliveryExecutorForTests = nil
        p14FreshRealmProofWorkerBeforeQueryExecutorForTests = nil
        p14FreshRealmProofQueryObserverForTests = nil
        p14InitialFrameCommitRecordedForTests = nil
        // One controller may own several held/querying proofs during an A→B
        // replacement. Revoke the complete lease registry atomically; late
        // release/result closures then fail their immutable-ID lookup.
        p14HeldFreshRealmProofIdentifiers.removeAll()
        p14FreshRealmProofLeases.removeAll()
        p14InitialCommitUnreadProofCompleted = false
        p14DidIssuePresentationReceipt = false
        p14InitialFrameCommitEffectToken = nil
        p14InitialCommitUnreadProofEffectToken = nil
        p14PresentationReceiptEffectToken = nil
        p14ReceiptReadinessEvaluationCount = 0
        p14ReceiptReadinessLastBlocker = nil
        p14ReceiptReadinessLastPresentationSample = nil
        p14ReadSuccessfulFlushCountBaseline =
            readVisiblePresentationCoordinator.successfulFlushCount
        visibleUnreadMentionReconciliationWorkItem?.cancel()
        visibleUnreadMentionReconciliationWorkItem = nil
        readVisibleStableLayoutRetryWorkItem?.cancel()
        readVisibleStableLayoutRetryWorkItem = nil
        readVisiblePresentationCoordinator.invalidatePresentation()

        performanceFixtureSendHandler = nil
        performanceFixtureInitialFrameCommitDiagnosticsHandler = nil
        performanceFixtureRemoteHistoryActionHandler = nil
        performanceFixtureArchiveTransportProvider = nil
        performanceFixtureArchiveTransportExecutor = nil
        performanceFixtureArchiveTransportDidStartHandler = nil
        performanceFixtureArchiveTransportCancellationHandler = nil
        performanceFixtureLinkedPageTraceContextHandler = nil
        performanceFixtureDetachedPersistenceTerminalHandler = nil
        performanceFixtureWidthTransitionLayoutCommitHandler = nil
        performanceFixtureDetachedPersistenceQueryIds.removeAll()
        performanceFixtureAllowsSkeletonStableFrame = false
        openScenarioLifecycleObservationTokens.forEach {
            NotificationCenter.default.removeObserver($0)
        }
        openScenarioLifecycleObservationTokens.removeAll()
        openScenarioInteractiveRemoteArchiveDispatcher = nil
        interactiveRemoteArchiveRequestDispatcher =
            AccountSchedulerChatInteractiveRemoteArchiveRequestDispatcher()
        openScenarioDarwinAcknowledgementObserver?.invalidate()
        openScenarioDarwinAcknowledgementObserver = nil
        openScenarioPendingRemoteInjectionPlan = nil
        openScenarioE04AcknowledgementAwaitingDisplayTick = false
        openScenarioDeferredInitialBootstrapPlan = nil
        openScenarioRemoteActionLatch.invalidate()
        openScenarioRotationOffsetGate.cancel()
        openScenarioLastRotationSourceSample = nil
        stopOpenScenarioVisibleOffsetSampling(capturingCurrentOffset: false)
        // Revoke the recorder generation before generic teardown can cancel
        // coordinator work. Any fixture transport operation already queued on
        // the serial queue then fails its generation check before MAM starts.
        releaseOpenScenarioArchiveTransport()
        openScenarioArtifactFinalizationInFlight = false
        openScenarioArtifactExportSession = nil
        openScenarioVideoEvidenceFailureCode = .none
        openScenarioArtifactExportFailureCode = .none
        openScenarioArtifactTraceFailure = .none
        openScenarioBoundPrimaryTraceContext = nil
        openScenarioBoundLinkedTraceContexts.removeAll()
        openScenarioActiveDwellPlan = nil
        openScenarioActiveDwellStartedAt = nil
        openScenarioDidStabilize = nil
        openScenarioRealmLease = nil
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        let shouldTrackRotation =
            descriptor.openScenario == .rotationRealPipeline &&
            openScenarioPostInitialInteractionReady
        let didBeginRotationOwnership: Bool
        if shouldTrackRotation {
            let sourceSample = openScenarioLastRotationSourceSample
            openScenarioLastRotationSourceSample = nil
            let sourceAdmission =
                ChatOpenRealPipelineFixtureRotationSourceSamplePolicy
                    .admission(
                        sourceSample,
                        targetViewSize: size,
                        currentTimestamp: CACurrentMediaTime(),
                        samplerGeneration:
                            openScenarioOffsetDisplayLinkGeneration
                    )
            if sourceAdmission == .accepted,
               let sourceSample {
                didBeginRotationOwnership =
                    openScenarioRotationOffsetGate.begin(
                        sourceOffsetY: sourceSample.offsetY,
                        targetViewSize: size,
                        minimumLayoutGenerationExclusive:
                            layoutPreparationGeneration,
                        semanticViewportStayedFixed:
                            sourceSample.semanticViewportStayedFixed
                    )
            } else {
                didBeginRotationOwnership = false
            }
            openScenarioRotationBarrierDiagnostics.recordSourceAdmission(
                sourceAdmission,
                didBegin: didBeginRotationOwnership
            )
            publishOpenScenarioRotationBarrierDiagnostics()
        } else {
            didBeginRotationOwnership = false
        }

        // Production forwarding can synchronously activate a retained target
        // cache and consume natural-bounds offset ownership. The fixture must
        // therefore freeze the source viewport before crossing this boundary.
        super.viewWillTransition(to: size, with: coordinator)

        guard shouldTrackRotation,
              didBeginRotationOwnership else {
            return
        }
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self else { return }
            guard !context.isCancelled else {
                self.openScenarioRotationOffsetGate.cancel()
                self.openScenarioRotationBarrierDiagnostics
                    .recordCoordinatorCompletion(accepted: false)
                self.openScenarioLastRotationSourceSample = nil
                self.openScenarioLastSampledOffsetY =
                    self.messagesCollectionView.contentOffset.y
                self.publishOpenScenarioRotationBarrierDiagnostics()
                return
            }
            let didAcceptCoordinator = self.openScenarioRotationOffsetGate
                .recordCoordinatorCompletion()
            self.openScenarioRotationBarrierDiagnostics
                .recordCoordinatorCompletion(
                    accepted: didAcceptCoordinator
                )
            self.publishOpenScenarioRotationBarrierDiagnostics()
            guard didAcceptCoordinator else {
                return
            }
            self.finalizeOpenScenarioRotationOffsetEndpointIfReady()
        }
    }

    /// Hosted XCTest drives the same fixture-only transition completion that
    /// the real UI route receives from UIKit. Video/XCUITest continues to own
    /// literal device rotation; this seam keeps the all-scenario hosted gate
    /// deterministic without inventing a second receipt path.
    internal func completeOpenScenarioRotationTransitionForTesting() {
        completeOpenScenarioRotationTransition()
    }

    internal var isOpenScenarioPostInitialInteractionReadyForTesting: Bool {
        openScenarioPostInitialInteractionReady
    }

    @discardableResult
    internal func performOpenScenarioPostInitialActionForTesting() -> Bool {
        admitOpenScenarioPostInitialAction()
    }

    internal func performOpenScenarioBackgroundForegroundForTesting() {
        recordOpenScenarioApplicationDidEnterBackground()
        recordOpenScenarioApplicationDidBecomeActive()
    }

    @discardableResult
    internal func acknowledgeOpenScenarioSkeletonForTesting() -> Bool {
        acknowledgeOpenScenarioSkeleton()
    }

    /// Source-side/hosted evidence sampled while E04 is deliberately held at
    /// the external skeleton acknowledgement boundary. This reads the same
    /// production counters used by the final receipt and performs no Realm
    /// query or datasource mutation.
    internal func captureOpenScenarioDiagnosticsForTesting()
        -> ChatOpenRealPipelineFixtureDiagnostics? {
        guard descriptor.openScenario == .bootstrapStaleLocalToContent,
              openScenarioStableReceipt == nil else {
            return nil
        }
        recordOpenScenarioPreTerminalVisualState()
        compareOpenScenarioSkeletonWithBaseline()
        return makeOpenScenarioDiagnostics(
            plan: ChatOpenRealPipelineFixturePlan(
                scenario: .bootstrapStaleLocalToContent
            ),
            phase: .skeleton,
            isStable: false
        )
    }

    @discardableResult
    internal func resumeDeferredOpenScenarioInitialBootstrapRequestForTesting()
        -> Bool {
        guard let plan = openScenarioDeferredInitialBootstrapPlan else {
            return false
        }
        openScenarioDeferredInitialBootstrapPlan = nil
        return startOpenScenarioInitialBootstrapRequestIfNeeded(plan: plan)
    }

    private func completeOpenScenarioRotationTransition() {
        guard descriptor.openScenario == .rotationRealPipeline,
              openScenarioPostInitialInteractionReady,
              openScenarioStableReceipt == nil else {
            return
        }
        openScenarioRotationTransitionCount &+= 1
        if openScenarioRotationTransitionCount == 1 {
            renderOpenScenarioInteractionReady(
                plan: ChatOpenRealPipelineFixturePlan(
                    scenario: .rotationRealPipeline
                )
            )
        } else if openScenarioRotationTransitionCount == 2 {
            openScenarioPostInitialInteractionCount &+= 1
            beginOpenScenarioTerminalObservation(
                plan: ChatOpenRealPipelineFixturePlan(
                    scenario: .rotationRealPipeline
                )
            )
        }
    }

    private func configureFixtureChrome() {
        readyLabel.accessibilityIdentifier = AccessibilityID.ready
        readyLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        readyLabel.textColor = .secondaryLabel
        readyLabel.numberOfLines = 1
        readyLabel.adjustsFontSizeToFitWidth = true
        readyLabel.minimumScaleFactor = 0.4

        stateLabel.accessibilityIdentifier = AccessibilityID.state
        stateLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        stateLabel.textColor = .secondaryLabel
        stateLabel.numberOfLines = 1
        stateLabel.adjustsFontSizeToFitWidth = true
        stateLabel.minimumScaleFactor = 0.4

        openStateLabel.accessibilityIdentifier = AccessibilityID.openState
        openStateLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        openStateLabel.textColor = .secondaryLabel
        openStateLabel.numberOfLines = 1
        openStateLabel.adjustsFontSizeToFitWidth = true
        openStateLabel.minimumScaleFactor = 0.35
        openStateLabel.isHidden = descriptor.openScenario == nil

        openStableLabel.accessibilityIdentifier = AccessibilityID.openStable
        openStableLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        openStableLabel.textColor = .secondaryLabel
        openStableLabel.numberOfLines = 1
        openStableLabel.adjustsFontSizeToFitWidth = true
        openStableLabel.minimumScaleFactor = 0.2
        openStableLabel.isHidden = descriptor.openScenario == nil

        openPostInitialActionButton.isHidden = true

        openScenarioVideoMarkerView.isHidden = true
        openScenarioVideoMarkerView.translatesAutoresizingMaskIntoConstraints = false

        controlsScrollView.showsHorizontalScrollIndicator = false
        controlsScrollView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.94)
        controlsStack.axis = .horizontal
        controlsStack.spacing = 6
        controlsStack.alignment = .center

        [
            makeButton("Incoming", id: AccessibilityID.incoming, action: #selector(addIncoming)),
            makeButton("Edit", id: AccessibilityID.edit, action: #selector(editOptimistic)),
            makeButton("Delete", id: AccessibilityID.delete, action: #selector(deleteOptimistic)),
            makeButton("Prefetch", id: AccessibilityID.mediaPrefetch, action: #selector(prefetchMedia)),
            makeButton("Visible", id: AccessibilityID.mediaVisible, action: #selector(showPrefetchedMedia)),
            makeButton("Skeleton", id: AccessibilityID.skeleton, action: #selector(showFixtureSkeleton)),
            makeButton("Reveal", id: AccessibilityID.reveal, action: #selector(revealFixtureSkeleton)),
            makeButton("Search test", id: AccessibilityID.search, action: #selector(openLastChatsSearch))
        ].forEach(controlsStack.addArrangedSubview)

        [
            readyLabel,
            stateLabel,
            controlsScrollView,
            controlsStack,
            openStateLabel,
            openStableLabel,
            openPostInitialActionButton
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(readyLabel)
        view.addSubview(stateLabel)
        view.addSubview(openStateLabel)
        view.addSubview(openStableLabel)
        view.addSubview(openPostInitialActionButton)
        view.addSubview(controlsScrollView)
        controlsScrollView.addSubview(controlsStack)
        view.addSubview(openScenarioVideoMarkerView)

        NSLayoutConstraint.activate([
            readyLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
            readyLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            readyLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            stateLabel.topAnchor.constraint(equalTo: readyLabel.bottomAnchor, constant: 1),
            stateLabel.leadingAnchor.constraint(equalTo: readyLabel.leadingAnchor),
            stateLabel.trailingAnchor.constraint(equalTo: readyLabel.trailingAnchor),
            controlsScrollView.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 2),
            controlsScrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            controlsScrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            controlsScrollView.heightAnchor.constraint(equalToConstant: 34),
            controlsStack.leadingAnchor.constraint(equalTo: controlsScrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            controlsStack.trailingAnchor.constraint(equalTo: controlsScrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            controlsStack.topAnchor.constraint(equalTo: controlsScrollView.contentLayoutGuide.topAnchor),
            controlsStack.bottomAnchor.constraint(equalTo: controlsScrollView.contentLayoutGuide.bottomAnchor),
            controlsStack.heightAnchor.constraint(equalTo: controlsScrollView.frameLayoutGuide.heightAnchor),
            openStateLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
            openStateLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            openStateLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            openStableLabel.topAnchor.constraint(equalTo: openStateLabel.bottomAnchor, constant: 1),
            openStableLabel.leadingAnchor.constraint(equalTo: openStateLabel.leadingAnchor),
            openStableLabel.trailingAnchor.constraint(equalTo: openStateLabel.trailingAnchor),
            openPostInitialActionButton.topAnchor.constraint(
                equalTo: openStableLabel.bottomAnchor,
                constant: 2
            ),
            openPostInitialActionButton.centerXAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.centerXAnchor
            ),
            openScenarioVideoMarkerView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 8
            ),
            openScenarioVideoMarkerView.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -8
            ),
            openScenarioVideoMarkerView.widthAnchor.constraint(equalToConstant: 96),
            openScenarioVideoMarkerView.heightAnchor.constraint(equalToConstant: 96)
        ])
    }

    private func makeButton(_ title: String, id: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
        button.accessibilityIdentifier = id
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func renderOpenScenarioInteractionReady(
        plan: ChatOpenRealPipelineFixturePlan
    ) {
        guard plan.requiresPostInitialInteraction,
              openScenarioStableReceipt == nil else {
            return
        }
        openScenarioPostInitialInteractionReady = true
        if let direction = plan.expectedInteractivePagingDirection {
            let title = direction == .older ? "Load older" : "Load newer"
            openPostInitialActionButton.setTitle(title, for: .normal)
            openPostInitialActionButton.isEnabled = true
            openPostInitialActionButton.isHidden = false
        } else {
            openPostInitialActionButton.isHidden = true
        }
        renderOpenScenarioPhase(.content, plan: plan)
    }

    @objc private func performOpenScenarioPostInitialAction() {
        _ = admitOpenScenarioPostInitialAction()
    }

    @discardableResult
    private func admitOpenScenarioPostInitialAction() -> Bool {
        guard let scenario = descriptor.openScenario else { return false }
        let plan = ChatOpenRealPipelineFixturePlan(scenario: scenario)
        guard openScenarioPostInitialInteractionReady,
              openScenarioPostInitialInteractionCount == 0,
              let direction = plan.expectedInteractivePagingDirection,
              let retainedAnchor = capturePagingAnchorIfNeeded(
                direction: direction
              ) else {
            publishOpenScenarioFailure(plan: plan)
            return false
        }
        guard performPerformanceFixtureInteractiveHistoryPaging(
            direction: direction
        ) else {
            publishOpenScenarioFailure(plan: plan)
            return false
        }
        openScenarioPostInitialInteractionReady = false
        openScenarioPostInitialInteractionCount = 1
        openScenarioPagingRetainedAnchor = retainedAnchor
        openScenarioPagingAnchorErrorMilliPoints = 0
        openPostInitialActionButton.isEnabled = false
        openPostInitialActionButton.isHidden = true
        renderOpenScenarioPhase(.content, plan: plan)
        return true
    }

    private func installOpenScenarioLifecycleObservation() {
        guard openScenarioLifecycleObservationTokens.isEmpty else { return }
        let center = NotificationCenter.default
        openScenarioLifecycleObservationTokens.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.recordOpenScenarioApplicationDidEnterBackground()
            }
        )
        openScenarioLifecycleObservationTokens.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.recordOpenScenarioApplicationDidBecomeActive()
            }
        )
    }

    private func recordOpenScenarioApplicationDidEnterBackground() {
        guard descriptor.openScenario == .committedContentBackgroundForeground,
              openScenarioPostInitialInteractionReady,
              openScenarioStableReceipt == nil,
              openScenarioApplicationBackgroundCount == 0 else {
            return
        }
        openScenarioApplicationBackgroundCount &+= 1
        renderOpenScenarioInteractionReady(
            plan: ChatOpenRealPipelineFixturePlan(
                scenario: .committedContentBackgroundForeground
            )
        )
    }

    private func recordOpenScenarioApplicationDidBecomeActive() {
        guard descriptor.openScenario == .committedContentBackgroundForeground,
              openScenarioPostInitialInteractionReady,
              openScenarioStableReceipt == nil,
              openScenarioApplicationBackgroundCount == 1,
              openScenarioApplicationForegroundCount == 0 else {
            return
        }
        openScenarioApplicationForegroundCount = 1
        openScenarioPostInitialInteractionCount = 1
        beginOpenScenarioTerminalObservation(
            plan: ChatOpenRealPipelineFixturePlan(
                scenario: .committedContentBackgroundForeground
            )
        )
    }

    private func configureOpenScenario(plan: ChatOpenRealPipelineFixturePlan) {
        guard !openScenarioTerminalTeardownCompleted else { return }
        let lifecycleGeneration = openScenarioLifecycleGeneration
        readyLabel.isHidden = true
        stateLabel.isHidden = true
        controlsScrollView.isHidden = true
        controlsStack.isHidden = true
        xabberInputView.isUserInteractionEnabled = false
        scrollFrameOperationCounter.setEnabled(true)
        scrollFrameOperationCounter.reset()
        if openScenarioArchiveTransportGeneration == nil {
            openScenarioArchiveTransportGeneration =
                openScenarioTransportThreadRecorder.activate()
        }
        openScenarioVideoMarkerGeneration = openScenarioVideoMarkerGate.begin()
        openScenarioLastSampledOffsetY = messagesCollectionView.contentOffset.y
        openScenarioLastRotationSourceSample = nil
        openScenarioRotationBarrierDiagnostics =
            ChatOpenRealPipelineFixtureRotationBarrierDiagnostics()
        if descriptor.openScenario == .rotationRealPipeline {
            openScenarioAtomicInitialOffsetGate.begin(
                sourceOffsetY: messagesCollectionView.contentOffset.y
            )
        }
        startOpenScenarioVisibleOffsetSampling()
        performanceFixtureInitialFrameCommitDiagnosticsHandler = { [weak self] diagnostics in
            self?.recordOpenScenarioInitialFrameCommit(diagnostics, plan: plan)
        }
        performanceFixtureWidthTransitionLayoutCommitHandler = {
            [weak self] generation, targetViewSize in
            self?.recordOpenScenarioWidthTransitionLayoutCommit(
                generation: generation,
                targetViewSize: targetViewSize
            )
        }
        performanceFixtureRemoteHistoryActionHandler = { [weak self] action in
            self?.consumeOpenScenarioRemoteHistoryAction(action)
                ?? .useProductionTransport
        }
        performanceFixtureDetachedPersistenceTerminalHandler = {
            [weak self] _ in
            guard let self,
                  plan.scenario == .newerCrossingGap else {
                return
            }
            self.renderNewerGapInteractionReadyIfPossible(plan: plan)
        }
        performanceFixtureAllowsSkeletonStableFrame =
            plan.allowsSkeletonStableFrame
        performanceFixtureLinkedPageTraceContextHandler = { [weak self] context in
            self?.bindOpenScenarioLinkedTraceContext(context, plan: plan)
        }
        if plan.expectsLinkedPagingTrace {
            let dispatcher =
                ChatPerformanceFixtureInteractiveRemoteArchiveDispatcher {
                    [weak self] request in
                    self?.dispatchOpenScenarioInteractiveRemoteArchiveRequest(
                        request,
                        plan: plan
                    )
                }
            openScenarioInteractiveRemoteArchiveDispatcher = dispatcher
            interactiveRemoteArchiveRequestDispatcher = dispatcher
        }
        if plan.scenario == .committedContentBackgroundForeground {
            installOpenScenarioLifecycleObservation()
        }
        renderOpenScenarioPhase(.preparing, plan: plan)

        guard openScenarioSetupFailure == nil else {
            publishOpenScenarioFailure(plan: plan)
            return
        }

        installOpenScenarioArchiveTransportIfNeeded(plan: plan)

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isOpenScenarioLifecycleCurrent(
                    generation: lifecycleGeneration
                  ) else {
                return
            }
            print(
                "CHAT_OPEN_FIXTURE_STORAGE " +
                "scenario=\(plan.scenario.rawValue) " +
                self.openScenarioStorageDiagnostics.accessibilityFields
                    .joined(separator: " ")
            )
            self.openScenarioRouteMeasurementHasStarted = true
            self.loadInitialDatasource(performPendingOpenMessageRequest: false)
            if plan.requiresRemoteInjection {
                if self.defersOpenScenarioInitialBootstrapRequestForTesting {
                    self.openScenarioDeferredInitialBootstrapPlan = plan
                } else {
                    _ = self.startOpenScenarioInitialBootstrapRequestIfNeeded(
                        plan: plan
                    )
                }
            }
            guard self.bindOpenScenarioPrimaryTraceContext(plan: plan) else {
                self.publishOpenScenarioFailure(plan: plan)
                return
            }
            if plan.requiresRemoteInjection {
                self.openScenarioSkeletonObservationPlan = plan
                self.openScenarioSkeletonObservationDeadline =
                    Date().addingTimeInterval(4)
            } else if !plan.requiresPostInitialInteraction {
                self.beginOpenScenarioTerminalObservation(plan: plan)
            }
        }
    }

    private func isOpenScenarioLifecycleCurrent(generation: Int) -> Bool {
        !openScenarioTerminalTeardownCompleted &&
            generation == openScenarioLifecycleGeneration
    }

    /// The deterministic controller skips `subscribe()`, while production
    /// starts blocking account-scoped archive work there. Only plans whose
    /// first safe frame genuinely depends on remote persistence may enter that
    /// coordinator. Local/durable and post-interaction-only plans must not
    /// force a second loading-state render after their local frame probe.
    @discardableResult
    private func startOpenScenarioInitialBootstrapRequestIfNeeded(
        plan: ChatOpenRealPipelineFixturePlan
    ) -> Bool {
        guard !openScenarioTerminalTeardownCompleted,
              plan.requiresRemoteInjection,
              descriptor.openScenario == plan.scenario,
              openScenarioStableReceipt == nil,
              openScenarioInitialBootstrapRequestInvocationCountForTesting == 0
        else {
            return false
        }
        openScenarioInitialBootstrapRequestInvocationCountForTesting &+= 1
        requestInitialBootstrapArchive()
        return true
    }

    private func beginOpenScenarioHostTerminalObservationIfReady() {
        guard let scenario = descriptor.openScenario,
              scenario == .lastChatsAnimatedPush ||
                scenario == .coldPushExact ||
                scenario == .mentionDeletedAdvance ||
                scenario == .lastChatsSeededMentionExact,
              openScenarioRouteHostDidComplete,
              openScenarioProductionVisualCommitCount == 1,
              openScenarioTerminalObservationPlan == nil,
              openScenarioStableReceipt == nil else {
            return
        }
        guard beginOpenScenarioTerminalObservation(
            plan: ChatOpenRealPipelineFixturePlan(scenario: scenario)
        ) else {
            return
        }
        if scenario == .lastChatsAnimatedPush {
            openScenarioPostInitialInteractionCount &+= 1
        }
    }

    @discardableResult
    private func bindOpenScenarioPrimaryTraceContext(
        plan: ChatOpenRealPipelineFixturePlan
    ) -> Bool {
        guard let exportSession = openScenarioArtifactExportSession else {
            return true
        }
        guard openScenarioBoundPrimaryTraceContext == nil,
              let context = chatOpenPerformanceTraceContext else {
            openScenarioSetupFailure = String(
                describing: OpenScenarioError.primaryTraceContextUnavailable
            )
            return false
        }
        do {
            guard let matrixRouteCode = plan.videoMatrixRouteCode else {
                throw OpenScenarioError.traceContextBindingRejected
            }
            try exportSession.bindVideoRouteEvidence(
                matrixRouteCode: matrixRouteCode,
                fixtureScenario: plan.scenario.rawValue
            )
            try exportSession.bindTraceContext(
                context,
                contract: plan.artifactTraceContract
            )
            openScenarioBoundPrimaryTraceContext = context
            return true
        } catch {
            openScenarioSetupFailure = String(
                describing: OpenScenarioError.traceContextBindingRejected
            )
            return false
        }
    }

    private func bindOpenScenarioLinkedTraceContext(
        _ context: ChatOpenPerformanceTraceContext,
        plan: ChatOpenRealPipelineFixturePlan
    ) {
        guard let exportSession = openScenarioArtifactExportSession else {
            return
        }
        guard plan.expectsLinkedPagingTrace,
              openScenarioBoundPrimaryTraceContext != nil,
              !openScenarioBoundLinkedTraceContexts.contains(context) else {
            failOpenScenarioTraceBinding(
                plan: plan,
                error: .unexpectedLinkedTraceContext
            )
            return
        }
        do {
            try exportSession.bindLinkedTraceContext(
                context,
                contract: .linkedArchivePage
            )
            openScenarioBoundLinkedTraceContexts.insert(context)
        } catch {
            failOpenScenarioTraceBinding(
                plan: plan,
                error: .traceContextBindingRejected
            )
        }
    }

    private func failOpenScenarioTraceBinding(
        plan: ChatOpenRealPipelineFixturePlan,
        error: OpenScenarioError
    ) {
        let publish = { [weak self] in
            guard let self, self.openScenarioStableReceipt == nil else { return }
            self.openScenarioSetupFailure = String(describing: error)
            self.publishOpenScenarioFailure(plan: plan)
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }

    private func recordOpenScenarioInitialFrameCommit(
        _ diagnostics: ChatPerformanceInitialFrameCommitDiagnostics,
        plan: ChatOpenRealPipelineFixturePlan
    ) {
        if plan.scenario == .lastChatsSeededMentionExact {
            recordP14OpenScenarioInitialFrameCommit(
                diagnostics,
                plan: plan
            )
            return
        }
        captureOpenScenarioInitialFrameCausalDiagnostics()
        openScenarioCommittedInitialFrameDiagnostics = diagnostics
        openScenarioViewportDiagnostics = diagnostics.viewportDiagnostics
        openScenarioProductionVisualCommitCount += 1
        switch diagnostics.viewportDiagnostics.anchorStrategy {
        case .bottom:
            openScenarioLatestVisualCommitCount += 1
        case .message(let anchor):
            if plan.scenario == .lastChatsSeededMentionExact {
                if anchor.primary == openPrimary(
                    plan.p14UnreadTargetOrdinal
                ) {
                    p14MentionUnreadFrameCount &+= 1
                }
                if anchor.primary == openPrimary(
                    plan.p14SavedTargetOrdinal
                ) {
                    p14MentionSavedFrameCount &+= 1
                }
            }
            if let targetOrdinal = plan.expectedTargetOrdinal,
               anchor.primary == openPrimary(targetOrdinal) {
                openScenarioResolvedTargetOrdinal = targetOrdinal
                openScenarioTargetMatchCount += 1
            }
        case .none, .preserveContentOffset:
            break
        }
        if !ChatOpenRealPipelineFixtureDiagnosticsPolicy.isExpectedCommit(
            targetKind: plan.targetKind,
            anchorStrategy: diagnostics.viewportDiagnostics.anchorStrategy
        ) {
            openScenarioUnexpectedCommittedFrameCount += 1
        }
        recordOpenScenarioAtomicInitialOffsetIfNeeded()
        // Establish the committed viewport as the baseline. Subsequent
        // sampler changes are user-visible corrections, not the intentional
        // atomic first-frame alignment itself.
        openScenarioLastSampledOffsetY = messagesCollectionView.contentOffset.y
        openScenarioHasCommittedViewport = true
        guard openScenarioProductionVisualCommitCount == 1 else { return }
        if plan.requiresPostInitialInteraction {
            if plan.scenario == .lastChatsAnimatedPush {
                beginOpenScenarioHostTerminalObservationIfReady()
            } else if plan.scenario == .newerCrossingGap {
                renderNewerGapInteractionReadyIfPossible(plan: plan)
            } else {
                renderOpenScenarioInteractionReady(plan: plan)
            }
        } else if plan.scenario == .coldPushExact ||
                    plan.scenario == .mentionDeletedAdvance ||
                    plan.scenario == .lastChatsSeededMentionExact {
            beginOpenScenarioHostTerminalObservationIfReady()
        }
    }

    /// Freezes causal work at the production commit callback. The callback is
    /// emitted before `finishPreparedLocalFirstFrameAnchor` may schedule its
    /// ordinary post-position background context, so these counters cannot be
    /// polluted by later detached transport or observer refreshes.
    private func captureOpenScenarioInitialFrameCausalDiagnostics() {
        recordOpenScenarioProductionRemoteHistoryState()
        let bootstrapDiagnostics =
            captureOpenScenarioProductionBootstrapDiagnostics()
        openScenarioInitialFrameArchiveRequestCount = max(
            max(
                openScenarioArchiveRequestCount,
                openScenarioObservedProductionArchiveQueryIds.count
            ),
            bootstrapDiagnostics.transportStartCount
        )
        openScenarioInitialFrameGapRequestCount = max(
            openScenarioGapRequestCount,
            openScenarioObservedProductionGapQueryIds.count
        )
        openScenarioInitialFrameRouteStoreDiagnostics =
            timelineSession?.routeStoreDiagnosticsSnapshot.routeDelta(
                since: openScenarioRouteStoreDiagnosticsBaseline
            )
    }

    private func recordP14OpenScenarioInitialFrameCommit(
        _ diagnostics: ChatPerformanceInitialFrameCommitDiagnostics,
        plan: ChatOpenRealPipelineFixturePlan
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let effectToken = diagnostics.initialFrameEffectToken
        guard isLatestInitialFrameEffectToken(effectToken) else { return }
        if p14InitialFrameCommitEffectToken == effectToken,
           openScenarioProductionVisualCommitCount == 1 {
            return
        }

        adoptP14InitialFrameCommitEffectToken(effectToken)
        captureOpenScenarioInitialFrameCausalDiagnostics()
        // Initial-frame diagnostics are a replaceable exact-owner snapshot,
        // not an append-only history. If A was logically committed but lost
        // ownership before its receipt, B remains the sole visual commit.
        openScenarioCommittedInitialFrameDiagnostics = diagnostics
        openScenarioViewportDiagnostics = diagnostics.viewportDiagnostics
        openScenarioProductionVisualCommitCount = 1
        openScenarioLatestVisualCommitCount = 0
        openScenarioTargetMatchCount = 0
        openScenarioUnexpectedCommittedFrameCount = 0
        openScenarioResolvedTargetOrdinal = nil
        p14MentionUnreadFrameCount = 0
        p14MentionSavedFrameCount = 0
        switch diagnostics.viewportDiagnostics.anchorStrategy {
        case .bottom:
            openScenarioLatestVisualCommitCount = 1
        case .message(let anchor):
            if anchor.primary == openPrimary(plan.p14UnreadTargetOrdinal) {
                p14MentionUnreadFrameCount = 1
            }
            if anchor.primary == openPrimary(plan.p14SavedTargetOrdinal) {
                p14MentionSavedFrameCount = 1
            }
            if let targetOrdinal = plan.expectedTargetOrdinal,
               anchor.primary == openPrimary(targetOrdinal) {
                openScenarioResolvedTargetOrdinal = targetOrdinal
                openScenarioTargetMatchCount = 1
            }
        case .none, .preserveContentOffset:
            break
        }
        if !ChatOpenRealPipelineFixtureDiagnosticsPolicy.isExpectedCommit(
            targetKind: plan.targetKind,
            anchorStrategy: diagnostics.viewportDiagnostics.anchorStrategy
        ) {
            openScenarioUnexpectedCommittedFrameCount = 1
        }
        openScenarioLastSampledOffsetY = messagesCollectionView.contentOffset.y
        openScenarioHasCommittedViewport = true

        scheduleP14InitialCommitFreshRealmProof(effectToken: effectToken)
        p14InitialFrameCommitRecordedForTests?(diagnostics)
        guard effectToken == p14InitialFrameCommitEffectToken,
              isLatestInitialFrameEffectToken(effectToken) else {
            return
        }
        issueP14ProductionPresentationReceiptIfReady()
        beginOpenScenarioHostTerminalObservationIfReady()
    }

    private func consumeOpenScenarioRemoteHistoryAction(
        _ action: ChatPerformanceFixtureRemoteHistoryAction
    ) -> ChatPerformanceFixtureRemoteHistoryDisposition {
        guard descriptor.openScenario != nil else {
            return .useProductionTransport
        }
        openScenarioConsumedRemoteHistoryActions.append(action)
        let actionName: String
        switch action.kind {
        case .anchorContextPrefetch:
            actionName = "anchor-context-prefetch"
        }
        print(
            "CHAT_OPEN_FIXTURE_REMOTE_HISTORY " +
            "action=\(actionName) " +
            "source=\(action.source.rawValue) " +
            "newer=\(action.newerPageSize ?? 0) " +
            "older=\(action.olderPageSize ?? 0) " +
            "disposition=production-shaped-fixture-transport"
        )
        if let scenario = descriptor.openScenario,
           scenario == .newerCrossingGap {
            renderNewerGapInteractionReadyIfPossible(
                plan: ChatOpenRealPipelineFixturePlan(scenario: scenario)
            )
        }
        return .useProductionTransport
    }

    /// G07's anchored first frame starts production's detached context fetch.
    /// The explicit interactive action must not race that persistence work or
    /// replace its session state, so the fixture exposes the button only after
    /// the observed context action and every production-owned resource finish.
    private func renderNewerGapInteractionReadyIfPossible(
        plan: ChatOpenRealPipelineFixturePlan
    ) {
        guard plan.scenario == .newerCrossingGap,
              openScenarioStableReceipt == nil,
              openScenarioProductionVisualCommitCount == 1,
              !openScenarioPostInitialInteractionReady,
              openScenarioPostInitialInteractionCount == 0,
              openScenarioConsumedRemoteHistoryActions.count == 1,
              openScenarioConsumedRemoteHistoryActions.first?.kind ==
                .anchorContextPrefetch else {
            return
        }
        let bootstrapDiagnostics =
            captureOpenScenarioProductionBootstrapDiagnostics()
        guard captureOpenScenarioActiveProductionWorkCount(
            bootstrapDiagnostics: bootstrapDiagnostics
        ) == 0 else {
            return
        }
        renderOpenScenarioInteractionReady(plan: plan)
    }

    private func dispatchOpenScenarioInteractiveRemoteArchiveRequest(
        _ request: ChatInteractiveRemoteArchiveDispatchRequest,
        plan: ChatOpenRealPipelineFixturePlan
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard plan.expectsLinkedPagingTrace,
              let expectedDirection = plan.expectedInteractivePagingDirection,
              let expectedCursorOrdinal =
                plan.expectedInteractivePagingCursorOrdinal,
              let ordinalRange = plan.interactiveGapInjectionOrdinalRange,
              request.owner == owner,
              request.direction == expectedDirection,
              request.cursorId == openArchiveId(expectedCursorOrdinal),
              request.pageSize == ChatHistoryPagingConfiguration.pageSize,
              request.queryId.isNotEmpty,
              let fixtureSend = request.performanceFixtureSend,
              let session = openScenarioArchiveTransportSession,
              let transportGeneration = openScenarioArchiveTransportGeneration
        else {
            rejectOpenScenarioArchiveDescriptor(plan: plan)
            return
        }

        let gap = RegularChatArchiveGap(
            olderRangeNewestArchiveId: openArchiveId(79),
            newerRangeOldestArchiveId: openArchiveId(240)
        )
        let gapDirection: MessageArchiveManager.RegularArchiveGapRepairDirection =
            expectedDirection == .older ? .older : .newer
        let requestPlan = MessageArchiveManager.regularGapRepairRequestPlan(
            jid: jid,
            gap: gap,
            direction: gapDirection,
            pageSize: request.pageSize
        )
        guard let archiveDescriptor =
                ChatPerformanceFixtureArchiveRequestDescriptor.make(
                    plan: requestPlan,
                    leasePurpose: .interactivePaging,
                    requestSource: nil,
                    semanticRouteClass: .knownGapRepair
                ),
              ChatPerformanceFixtureInteractiveGapDescriptorAdmissionPolicy
                .accepts(
                    descriptor: archiveDescriptor,
                    expectedDirection: expectedDirection,
                    expectedCursorArchiveID: request.cursorId,
                    expectedPageSize: request.pageSize
                ) else {
            rejectOpenScenarioArchiveDescriptor(plan: plan)
            return
        }

        openScenarioArchiveTransportLock.lock()
        openScenarioAllowedArchiveQueryIds.insert(request.queryId)
        openScenarioArchiveDescriptorsByQueryId[request.queryId] =
            archiveDescriptor
        openScenarioArchiveTransportLock.unlock()
        openScenarioArchiveRequestCount &+= 1
        openScenarioGapRequestCount &+= 1
        openScenarioObservedProductionArchiveQueryIds.insert(request.queryId)
        openScenarioObservedProductionGapQueryIds.insert(request.queryId)
        openScenarioArchiveCursorKind = archiveDescriptor.cursorKind
        openScenarioTransportThreadRecorder.record(
            .uiBookkeeping,
            generation: transportGeneration,
            isMainThread: Thread.isMainThread
        )
        request.schedulerLease.attach {}

        enqueueOpenScenarioArchiveTransport(
            generation: transportGeneration,
            plan: plan,
            operation: { [weak self] in
                guard let self,
                      request.shouldDispatch() else {
                    request.schedulerLease.complete()
                    throw OpenScenarioError.archiveDescriptorRejected
                }
                self.openScenarioTransportThreadRecorder.record(
                    .mamStart,
                    generation: transportGeneration,
                    isMainThread: Thread.isMainThread
                )
                guard fixtureSend(
                    session.stream,
                    session.archiveManager,
                    session.messageManager
                ) == request.queryId else {
                    request.schedulerLease.complete()
                    throw OpenScenarioError.archiveDescriptorRejected
                }
            },
            mainCompletion: { [weak self] in
                guard let self else { return }
                request.transportStarted(request.queryId, .primary, nil)
                // `transportStarted` installs production's visible-load state
                // asynchronously on main. FIFO ordering gives that state one
                // causal turn before the real parser receives its first row.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let ordinals = Array(ordinalRange)
                    self.enqueueOpenScenarioArchiveTransport(
                        generation: transportGeneration,
                        plan: plan,
                        operation: { [weak self] in
                            guard let self else {
                                throw OpenScenarioError
                                    .archiveTransportUnavailable
                            }
                            try self.deliverOpenScenarioArchivePage(
                                session: session,
                                queryId: request.queryId,
                                ordinals: ordinals,
                                complete: false,
                                serverResultCount: 320,
                                deliverDuplicateFinalForIdempotencyProof: true,
                                descriptor: archiveDescriptor,
                                expectedSource: nil,
                                expectedSemanticRouteClass: .knownGapRepair,
                                expectedDeliveredArchiveIDs:
                                    ordinals.map(self.openArchiveId),
                                transportGeneration: transportGeneration
                            )
                        },
                        mainCompletion: { [weak self] in
                            self?.beginOpenScenarioTerminalObservation(
                                plan: plan
                            )
                        }
                    )
                }
            }
        )
    }

    private func installOpenScenarioArchiveTransportIfNeeded(
        plan: ChatOpenRealPipelineFixturePlan
    ) {
        guard plan.usesFixtureArchiveTransport,
              openScenarioArchiveTransportSession == nil else {
            return
        }

        let stream = XMPPStream()
        let archiveManager = MessageArchiveManager(withOwner: owner)
        let messageManager = MessageManager(withOwner: owner, activeStream: false)
        messageManager.updateSendingMessagesTimer?.invalidate()
        messageManager.updateSendingMessagesTimer = nil
        messageManager.unsubscribeSender()
        messageManager.unsubscribeReceiver()
        messageManager.archiveQueryIdPersistenceResolver = { [weak self] queryId in
            self?.isOpenScenarioArchiveQueryAllowed(queryId) == true
        }
        let session = ChatPerformanceFixtureArchiveTransportSession(
            stream: stream,
            archiveManager: archiveManager,
            messageManager: messageManager
        )
        openScenarioArchiveTransportSession = session
        guard let transportGeneration = openScenarioArchiveTransportGeneration else {
            openScenarioSetupFailure = String(
                describing: OpenScenarioError.archiveTransportUnavailable
            )
            return
        }
        performanceFixtureArchiveTransportProvider = { [weak self] request in
            self?.provideOpenScenarioArchiveTransport(for: request)
        }
        performanceFixtureArchiveTransportExecutor = { [weak self] operation in
            guard let self,
                  self.openScenarioTransportThreadRecorder.beginOperation(
                    generation: transportGeneration
                  ) else {
                return
            }
            self.openScenarioArchiveTransportQueue.async { [weak self] in
                guard let self else { return }
                defer {
                    self.openScenarioTransportThreadRecorder.endOperation(
                        generation: transportGeneration
                    )
                }
                guard self.openScenarioTransportThreadRecorder.isCurrent(
                    generation: transportGeneration
                ) else {
                    return
                }
                self.openScenarioTransportThreadRecorder.record(
                    .mamStart,
                    generation: transportGeneration,
                    isMainThread: Thread.isMainThread
                )
                autoreleasepool(invoking: operation)
            }
        }
        performanceFixtureArchiveTransportDidStartHandler = { [weak self] request in
            self?.recordOpenScenarioArchiveTransportStart(
                request,
                plan: plan,
                transportGeneration: transportGeneration
            )
        }
        performanceFixtureArchiveTransportCancellationHandler = {
            [weak self, weak archiveManager] queryId in
            guard let self,
                  let archiveManager,
                  self.openScenarioTransportThreadRecorder.beginOperation(
                    generation: transportGeneration
                  ) else {
                return
            }
            self.openScenarioArchiveTransportQueue.async { [weak self] in
                guard let self else { return }
                _ = archiveManager.cancelPendingArchiveRequest(
                    queryId: queryId
                )
                self.openScenarioTransportThreadRecorder.endOperation(
                    generation: transportGeneration
                )
            }
        }
    }

    private func provideOpenScenarioArchiveTransport(
        for request: ChatPerformanceFixtureArchiveTransportRequest
    ) -> ChatPerformanceFixtureArchiveTransportSession? {
        guard request.queryIds.isNotEmpty,
              request.queryIds == Set(request.descriptorsByQueryId.keys),
              let session = openScenarioArchiveTransportSession else {
            return nil
        }
        openScenarioArchiveTransportLock.lock()
        openScenarioAllowedArchiveQueryIds.formUnion(request.queryIds)
        request.descriptorsByQueryId.forEach {
            openScenarioArchiveDescriptorsByQueryId[$0.key] = $0.value
        }
        openScenarioArchiveTransportLock.unlock()
        return session
    }

    private func isOpenScenarioArchiveQueryAllowed(_ queryId: String?) -> Bool {
        guard let queryId, queryId.isNotEmpty else { return false }
        openScenarioArchiveTransportLock.lock()
        let isAllowed = openScenarioAllowedArchiveQueryIds.contains(queryId)
        openScenarioArchiveTransportLock.unlock()
        return isAllowed
    }

    private func openScenarioArchiveDescriptor(
        for queryId: String
    ) -> ChatPerformanceFixtureArchiveRequestDescriptor? {
        openScenarioArchiveTransportLock.lock()
        let descriptor = openScenarioArchiveDescriptorsByQueryId[queryId]
        openScenarioArchiveTransportLock.unlock()
        return descriptor
    }

    private func recordOpenScenarioArchiveTransportStart(
        _ request: ChatPerformanceFixtureArchiveTransportRequest,
        plan: ChatOpenRealPipelineFixturePlan,
        transportGeneration: Int
    ) {
        openScenarioTransportThreadRecorder.record(
            .uiBookkeeping,
            generation: transportGeneration,
            isMainThread: Thread.isMainThread
        )
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.applyOpenScenarioArchiveTransportStart(
                    request,
                    plan: plan,
                    transportGeneration: transportGeneration
                )
            }
            return
        }
        applyOpenScenarioArchiveTransportStart(
            request,
            plan: plan,
            transportGeneration: transportGeneration
        )
    }

    private func applyOpenScenarioArchiveTransportStart(
        _ request: ChatPerformanceFixtureArchiveTransportRequest,
        plan: ChatOpenRealPipelineFixturePlan,
        transportGeneration: Int
    ) {
        guard openScenarioTransportThreadRecorder.isCurrent(
            generation: transportGeneration
        ) else {
            return
        }
        openScenarioArchiveRequestCount &+= request.queryIds.count
        openScenarioObservedProductionArchiveQueryIds.formUnion(request.queryIds)
        guard request.queryIds == Set(request.descriptorsByQueryId.keys) else {
            rejectOpenScenarioArchiveDescriptor(plan: plan)
            return
        }
        for queryId in request.queryIds.sorted() {
            guard let descriptor = request.descriptorsByQueryId[queryId] else {
                rejectOpenScenarioArchiveDescriptor(plan: plan)
                return
            }
            switch descriptor.semanticRouteClass {
            case .latest:
                guard request.kind == .initialBootstrap,
                      request.queryIds.count == 1,
                      descriptor.requestSource == nil,
                      descriptor.maximumResultCount ==
                        ChatInitialFirstFrameHistoryConfiguration.pageSize else {
                    rejectOpenScenarioArchiveDescriptor(plan: plan)
                    return
                }
                openScenarioQueryId = queryId
                guard openScenarioRemoteActionLatch.admit(queryID: queryId)
                else {
                    rejectOpenScenarioArchiveDescriptor(plan: plan)
                    return
                }
                openScenarioArchiveCursorKind = .latest
            case .exactTarget:
                guard request.kind == .detachedPage,
                      request.queryIds.count == 1,
                      descriptor.requestSource == plan.expectedRequestSource,
                      let targetOrdinal = plan.expectedTargetOrdinal,
                      descriptor.targetArchiveID == openArchiveId(targetOrdinal),
                      descriptor.maximumResultCount == 1 else {
                    rejectOpenScenarioArchiveDescriptor(plan: plan)
                    return
                }
                openScenarioQueryId = queryId
                guard openScenarioRemoteActionLatch.admit(queryID: queryId)
                else {
                    rejectOpenScenarioArchiveDescriptor(plan: plan)
                    return
                }
                openScenarioArchiveCursorKind = .aroundTarget
            case .anchorContext:
                guard request.kind == .detachedPage,
                      descriptor.requestSource == plan.expectedRequestSource,
                      let targetOrdinal = plan.expectedTargetOrdinal,
                      ChatPerformanceFixtureTargetWindowDescriptorAdmissionPolicy
                        .accepts(
                            descriptor: descriptor,
                            targetArchiveID: openArchiveId(targetOrdinal),
                            targetOrdinal: targetOrdinal,
                            totalMessageCount: 320
                        ) else {
                    rejectOpenScenarioArchiveDescriptor(plan: plan)
                    return
                }
                openScenarioArchiveCursorKind = .aroundTarget
                if plan.hasKnownGapTopology {
                    openScenarioGapRequestCount &+= 1
                    openScenarioObservedProductionGapQueryIds.insert(queryId)
                }
                if plan.scenario == .newerCrossingGap {
                    deliverOpenScenarioDescriptorTerminalWithoutRows(
                        queryId: queryId,
                        descriptor: descriptor,
                        expectedSemanticRouteClass: .anchorContext,
                        plan: plan,
                        transportGeneration: transportGeneration
                    )
                } else {
                    deliverOpenScenarioAnchorContextPage(
                        queryId: queryId,
                        descriptor: descriptor,
                        plan: plan,
                        transportGeneration: transportGeneration
                    )
                }
            case .backgroundContext:
                // A background context request is allowed to finish its own
                // persistence transaction, but the fixture never supplies
                // extra rows that could mutate the already committed initial
                // resident window or its viewport.
                guard request.kind == .detachedPage else {
                    rejectOpenScenarioArchiveDescriptor(plan: plan)
                    return
                }
                if plan.hasKnownGapTopology {
                    openScenarioGapRequestCount &+= 1
                    openScenarioObservedProductionGapQueryIds.insert(queryId)
                }
                deliverOpenScenarioDescriptorTerminalWithoutRows(
                    queryId: queryId,
                    descriptor: descriptor,
                    expectedSemanticRouteClass: .backgroundContext,
                    plan: plan,
                    transportGeneration: transportGeneration
                )
            case .unreadBoundary, .savedPosition, .knownGapRepair,
                 .interactivePage:
                rejectOpenScenarioArchiveDescriptor(plan: plan)
                return
            }
        }
        performOpenScenarioAcknowledgedRemoteActionIfReady()
    }

    private func rejectOpenScenarioArchiveDescriptor(
        plan: ChatOpenRealPipelineFixturePlan
    ) {
        openScenarioSetupFailure = String(
            describing: OpenScenarioError.archiveDescriptorRejected
        )
        publishOpenScenarioFailure(plan: plan)
    }

    private func deliverOpenScenarioAnchorContextPage(
        queryId: String,
        descriptor: ChatPerformanceFixtureArchiveRequestDescriptor,
        plan: ChatOpenRealPipelineFixturePlan,
        transportGeneration: Int
    ) {
        guard let session = openScenarioArchiveTransportSession,
              let cursorArchiveID = descriptor.cursorArchiveID,
              let targetOrdinal = openScenarioOrdinal(
                forArchiveID: cursorArchiveID
              ),
              descriptor.maximumResultCount > 0 else {
            rejectOpenScenarioArchiveDescriptor(plan: plan)
            return
        }
        let ordinals: [Int]
        switch descriptor.direction {
        case .older:
            let lowerBound = max(
                0,
                targetOrdinal - descriptor.maximumResultCount
            )
            ordinals = Array(lowerBound..<targetOrdinal)
        case .newer:
            let lowerBound = targetOrdinal + 1
            ordinals = Array(
                lowerBound..<(lowerBound + descriptor.maximumResultCount)
            )
        case nil:
            rejectOpenScenarioArchiveDescriptor(plan: plan)
            return
        }
        enqueueOpenScenarioArchiveTransport(
            generation: transportGeneration,
            plan: plan,
            operation: { [weak self] in
                guard let self else {
                    throw OpenScenarioError.archiveTransportUnavailable
                }
                try self.deliverOpenScenarioArchivePage(
                    session: session,
                    queryId: queryId,
                    ordinals: ordinals,
                    complete: false,
                    serverResultCount: 320,
                    deliverDuplicateFinalForIdempotencyProof: true,
                    descriptor: descriptor,
                    expectedSource: plan.expectedRequestSource,
                    expectedSemanticRouteClass: .anchorContext,
                    expectedDeliveredArchiveIDs: ordinals.map(openArchiveId),
                    transportGeneration: transportGeneration
                )
            }
        )
    }

    private func deliverOpenScenarioDescriptorTerminalWithoutRows(
        queryId: String,
        descriptor: ChatPerformanceFixtureArchiveRequestDescriptor,
        expectedSemanticRouteClass:
            ChatPerformanceFixtureArchiveSemanticRouteClass,
        plan: ChatOpenRealPipelineFixturePlan,
        transportGeneration: Int
    ) {
        guard let session = openScenarioArchiveTransportSession else {
            rejectOpenScenarioArchiveDescriptor(plan: plan)
            return
        }
        enqueueOpenScenarioArchiveTransport(
            generation: transportGeneration,
            plan: plan,
            operation: { [weak self] in
                guard let self else {
                    throw OpenScenarioError.archiveTransportUnavailable
                }
                try self.deliverOpenScenarioArchivePage(
                    session: session,
                    queryId: queryId,
                    ordinals: [],
                    complete: true,
                    serverResultCount: 0,
                    deliverDuplicateFinalForIdempotencyProof: true,
                    descriptor: descriptor,
                    expectedSource: descriptor.requestSource,
                    expectedSemanticRouteClass:
                        expectedSemanticRouteClass,
                    expectedDeliveredArchiveIDs:
                        expectedSemanticRouteClass == .anchorContext ? [] : nil,
                    transportGeneration: transportGeneration
                )
            }
        )
    }

    private func releaseOpenScenarioArchiveTransport() {
        performanceFixtureArchiveTransportProvider = nil
        performanceFixtureArchiveTransportExecutor = nil
        performanceFixtureArchiveTransportDidStartHandler = nil
        performanceFixtureArchiveTransportCancellationHandler = nil
        if let generation = openScenarioArchiveTransportGeneration {
            openScenarioTransportThreadRecorder.invalidate(generation: generation)
        }
        openScenarioArchiveTransportGeneration = nil
        openScenarioArchiveTransportLock.lock()
        openScenarioAllowedArchiveQueryIds.removeAll()
        openScenarioArchiveDescriptorsByQueryId.removeAll()
        openScenarioArchiveTransportLock.unlock()
        let releasedSession = openScenarioArchiveTransportSession
        openScenarioArchiveTransportSession = nil
        openScenarioArchiveTransportQueue.async {
            releasedSession?.messageManager.archiveQueryIdPersistenceResolver = nil
            releasedSession?.messageManager.unsubscribeSender()
            releasedSession?.messageManager.unsubscribeReceiver()
        }
    }

    private func waitForOpenScenarioSkeletonBeforeInjection(
        plan: ChatOpenRealPipelineFixturePlan,
        deadline: Date
    ) {
        let skeletonRows = openScenarioSkeletonRowCount
        let continuation =
            ChatOpenRealPipelineFixtureSkeletonContinuationPolicy.action(
                observedSkeletonRows: skeletonRows,
                expectedSkeletonRows: plan.expectedInitialSkeletonRowCount,
                requiresExternalAcknowledgement:
                    descriptor.requiresExternalSkeletonAcknowledgement,
                didReceiveExternalAcknowledgement: false
            )
        switch continuation {
        case .waitForSkeleton:
            break
        case .waitForExternalAcknowledgement:
            openScenarioSkeletonObservationPlan = nil
            openScenarioSkeletonObservationDeadline = nil
            openScenarioInitialSkeletonRowCount = skeletonRows
            captureOpenScenarioSkeletonPresentationBaselineIfNeeded()
            // E04 must retain display-link evidence for the entire held
            // skeleton interval: a stale Realm-observer frame during the
            // external compositor acknowledgement window is part of the bug
            // contract. Other routes keep their established handshake pause.
            if plan.scenario != .bootstrapStaleLocalToContent {
                pauseOpenScenarioVisibleOffsetSampling()
            }
            openScenarioPendingRemoteInjectionPlan = plan
            guard installOpenScenarioDarwinAcknowledgementObserver(plan: plan) else {
                publishOpenScenarioFailure(plan: plan)
                return
            }
            renderOpenScenarioPhase(.skeleton, plan: plan)
            return
        case .scheduleAutomaticDwell:
            openScenarioSkeletonObservationPlan = nil
            openScenarioSkeletonObservationDeadline = nil
            openScenarioInitialSkeletonRowCount = skeletonRows
            captureOpenScenarioSkeletonPresentationBaselineIfNeeded()
            renderOpenScenarioPhase(.skeleton, plan: plan)
            openScenarioAutomaticInjectionPlan = plan
            openScenarioAutomaticInjectionDisplayTimestamp = nil
            return
        case .injectRemotePage:
            openScenarioSkeletonObservationPlan = nil
            openScenarioSkeletonObservationDeadline = nil
            injectOpenScenarioRemotePage(plan: plan)
            return
        }
        guard Date() < deadline else {
            publishOpenScenarioFailure(plan: plan)
            return
        }
    }

    @discardableResult
    private func acknowledgeOpenScenarioSkeleton() -> Bool {
        guard let plan = openScenarioPendingRemoteInjectionPlan,
              ChatOpenRealPipelineFixtureAcknowledgementAdmissionPolicy.shouldConsume(
                hasPendingRemoteInjection: true,
                hasCommittedBootstrapSkeleton:
                    hasCommittedBootstrapSkeletonPresentationInCurrentLifecycle,
                loadingStateShowsSkeleton:
                    appliedBootstrapLoadingState?.showsSkeleton == true,
                observedSkeletonRows: openScenarioSkeletonRowCount,
                expectedSkeletonRows: plan.expectedInitialSkeletonRowCount
              ),
              ChatOpenRealPipelineFixtureSkeletonContinuationPolicy.action(
                observedSkeletonRows: openScenarioSkeletonRowCount,
                expectedSkeletonRows: plan.expectedInitialSkeletonRowCount,
                requiresExternalAcknowledgement:
                    descriptor.requiresExternalSkeletonAcknowledgement,
                didReceiveExternalAcknowledgement: true
              ) == .injectRemotePage else {
            return false
        }
        guard openScenarioRemoteActionLatch.acknowledge(plan: plan) else {
            return false
        }
        if plan.scenario == .bootstrapStaleLocalToContent,
           openScenarioHeldSkeletonDisplayTickCount == 0 {
            openScenarioE04AcknowledgementAwaitingDisplayTick = true
            openScenarioDarwinAcknowledgementObserver?.invalidate()
            openScenarioDarwinAcknowledgementObserver = nil
            return true
        }
        completeOpenScenarioSkeletonAcknowledgement(plan: plan)
        return true
    }

    private func completeOpenScenarioSkeletonAcknowledgement(
        plan: ChatOpenRealPipelineFixturePlan
    ) {
        openScenarioE04AcknowledgementAwaitingDisplayTick = false
        openScenarioDarwinAcknowledgementObserver?.invalidate()
        openScenarioDarwinAcknowledgementObserver = nil
        openScenarioPendingRemoteInjectionPlan = nil
        if plan.scenario != .bootstrapStaleLocalToContent {
            resumeOpenScenarioVisibleOffsetSampling()
        }
        captureOpenScenarioSkeletonPresentationBaselineIfNeeded()
        print(
            "CHAT_OPEN_FIXTURE_SKELETON_ACK " +
            "transport=darwin skeleton=\(plan.expectedInitialSkeletonRowCount) " +
            "disposition=consumed"
        )
        performOpenScenarioAcknowledgedRemoteActionIfReady()
    }

    private func completeOpenScenarioAcknowledgementAfterHeldTickIfReady() {
        guard openScenarioE04AcknowledgementAwaitingDisplayTick,
              openScenarioHeldSkeletonDisplayTickCount > 0,
              let plan = openScenarioPendingRemoteInjectionPlan else {
            return
        }
        completeOpenScenarioSkeletonAcknowledgement(plan: plan)
    }

    /// The compositor acknowledgement and the production archive request are
    /// independent asynchronous boundaries. Keep the accepted acknowledgement
    /// latched until the real request has supplied its query and descriptor;
    /// consuming it earlier would turn a valid skeleton observation into a
    /// fixture-only terminal failure with zero archive work.
    private func performOpenScenarioAcknowledgedRemoteActionIfReady() {
        guard !openScenarioE04AcknowledgementAwaitingDisplayTick else {
            return
        }
        let descriptorQueryID = openScenarioQueryId.flatMap { queryId in
            openScenarioArchiveDescriptor(for: queryId) == nil ? nil : queryId
        }
        guard let plan = openScenarioRemoteActionLatch.takeIfReady(
            transportIsReady:
                openScenarioArchiveTransportSession != nil &&
                openScenarioArchiveTransportGeneration != nil,
            descriptorQueryID: descriptorQueryID
        ) else {
            return
        }
        guard let action = plan.acknowledgedRemoteAction else {
            rejectOpenScenarioArchiveDescriptor(plan: plan)
            return
        }
        switch action {
        case .injectContentPage, .injectTrustedEmptyTerminal:
            injectOpenScenarioRemotePage(plan: plan)
        case .holdActiveDwellThenCancel:
            beginOpenScenarioActiveDwell(plan: plan)
        case .injectTypedTerminalFailure:
            injectOpenScenarioTypedFailure(plan: plan)
        }
    }

    private func installOpenScenarioDarwinAcknowledgementObserver(
        plan: ChatOpenRealPipelineFixturePlan
    ) -> Bool {
        guard ChatOpenRealPipelineFixtureDarwinAcknowledgementContract
            .shouldInstallObserver(
                requiresRemoteInjection: plan.requiresRemoteInjection,
                notificationName:
                    descriptor.externalSkeletonAcknowledgementNotificationName
            ),
              let notificationName =
                descriptor.externalSkeletonAcknowledgementNotificationName else {
            return false
        }
        openScenarioDarwinAcknowledgementObserver?.invalidate()
        let observer = ChatOpenRealPipelineFixtureDarwinAcknowledgementObserver(
            notificationName: notificationName,
            handler: { [weak self] in
                self?.acknowledgeOpenScenarioSkeleton()
            }
        )
        guard observer.start() else { return false }
        openScenarioDarwinAcknowledgementObserver = observer
        return true
    }

    private func prepareOpenScenarioRealm(plan: ChatOpenRealPipelineFixturePlan) throws {
        ChatInitialBootstrapRequestCoordinator.shared.resetForTests()
        let realm = try WRealm.safe()
        guard realm.configuration.inMemoryIdentifier != nil else {
            throw OpenScenarioError.storageIsNotEphemeral
        }
        openScenarioRealmLease = realm

        let existingMessages = realm.objects(MessageStorageItem.self).filter(
            "owner == %@ AND opponent == %@ AND conversationType_ == %@",
            owner,
            jid,
            conversationType.rawValue
        )
        let chatPrimary = LastChatsStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: conversationType
        )
        let archivePrimary = RegularChatArchiveSyncStateStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: conversationType
        )

        let ordinals: [Int]
        if plan.hasKnownGapTopology {
            ordinals = Array(0..<80) + Array(240..<320)
        } else {
            ordinals = Array(0..<plan.initialLocalMessageCount)
        }
        let messages = ordinals.map(makeOpenScenarioMessage)

        try realm.write {
            realm.delete(existingMessages)
            if let existingChat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: chatPrimary
            ) {
                realm.delete(existingChat)
            }
            if let existingArchive = realm.object(
                ofType: RegularChatArchiveSyncStateStorageItem.self,
                forPrimaryKey: archivePrimary
            ) {
                realm.delete(existingArchive)
            }

            if plan.scenario == .coldPushExact ||
                plan.scenario == .lastChatsAnimatedPush ||
                plan.scenario == .mentionDeletedAdvance ||
                plan.scenario == .lastChatsSeededMentionExact {
                let existingAccount = realm.object(
                    ofType: AccountStorageItem.self,
                    forPrimaryKey: owner
                )
                let account = existingAccount ?? AccountStorageItem()
                if existingAccount == nil {
                    // `jid` is Realm's primary key. Reassigning it on an
                    // already-managed object raises RLMException even when the
                    // value is identical, which made repeated fixture routes
                    // crash before their first frame.
                    account.jid = owner
                }
                account.username = ""
                account.enabled = true
                account.savePassword = false
                realm.add(account, update: .modified)
            }

            messages.forEach { realm.add($0, update: .modified) }

            let chat = LastChatsStorageItem()
            chat.primary = chatPrimary
            chat.owner = owner
            chat.jid = jid
            chat.conversationType = conversationType
            chat.messageDate = messages.last?.date ?? Date(timeIntervalSince1970: 0)
            chat.lastMessageId = messages.last?.messageId ?? ""
            chat.isSynced = !plan.startsWithoutDurableReadiness
            chat.isInitialArchiveLoaded = !plan.startsWithoutDurableReadiness
            chat.fullArchiveLoaded = !plan.startsWithoutDurableReadiness &&
                !plan.hasKnownGapTopology
            chat.isAllHistoryLoaded = chat.fullArchiveLoaded

            let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                owner: owner,
                jid: jid,
                conversationType: conversationType,
                in: realm
            )
            archiveState.olderArchiveEndReached = chat.fullArchiveLoaded
            archiveState.newerLiveEdgeReached =
                !plan.startsWithoutDurableReadiness

            if plan.hasKnownGapTopology {
                let snapshot = openArchiveId(319)
                chat.syncSnapshotLastArchiveId = snapshot
                archiveState.lastSnapshotArchiveId = snapshot
                archiveState.mergeLoadedRange(
                    first: openArchiveId(0),
                    last: openArchiveId(79),
                    updateKind: .bootstrapNewest
                )
                archiveState.mergeLoadedRange(
                    first: openArchiveId(240),
                    last: snapshot,
                    updateKind: .disjointWindow
                )
            } else if messages.isNotEmpty {
                let snapshot = openArchiveId(319)
                chat.syncSnapshotLastArchiveId = snapshot
                archiveState.lastSnapshotArchiveId = snapshot
                archiveState.mergeLoadedRange(
                    first: openArchiveId(0),
                    last: snapshot,
                    updateKind: .bootstrapNewest
                )
                if plan.scenario == .unreadBoundaryLocal,
                   let boundaryOrdinal = plan.unreadBoundaryOrdinal {
                    let persistedUnreadIncomingCount = messages.lazy.filter {
                        !$0.outgoing && !$0.isRead
                    }.count
                    chat.syncUnreadCount = persistedUnreadIncomingCount
                    chat.runtimeUnreadCount = 0
                    chat.unread = persistedUnreadIncomingCount
                    chat.syncUnreadAfterId = openArchiveId(boundaryOrdinal)
                    chat.lastReadId = chat.syncUnreadAfterId
                } else if plan.scenario == .savedPositionLocal,
                          let targetOrdinal = plan.expectedTargetOrdinal {
                    chat.unread = 0
                    chat.syncUnreadCount = 0
                    chat.runtimeUnreadCount = 0
                    chat.syncUnreadAfterId = nil
                    chat.lastVisibleMessagePrimary = openPrimary(targetOrdinal)
                    chat.lastVisibleMessageArchivedId = openArchiveId(targetOrdinal)
                    chat.lastVisibleMessageId = openMessageId(targetOrdinal)
                    chat.lastVisibleMessageDate = openDate(targetOrdinal)
                    chat.lastVisiblePositionSavedAtLastMessageId = chat.lastMessageId
                    chat.lastVisiblePositionSavedAtSnapshotLastArchiveId =
                        chat.syncSnapshotLastArchiveId
                    chat.lastVisiblePositionUpdatedAt = openDate(319)
                } else if plan.scenario == .mentionDeletedAdvance {
                    chat.unread = 0
                    chat.syncUnreadCount = 0
                    chat.runtimeUnreadCount = 0
                    chat.syncUnreadAfterId = nil
                    chat.lastReadId = nil
                    chat.groupchatMyId = p13CurrentMemberId
                    chat.mentionId = openArchiveId(
                        plan.p13DeletedMentionOrdinal
                    )
                } else if plan.scenario == .lastChatsSeededMentionExact {
                    let persistedUnreadIncomingCount = messages.lazy.filter {
                        !$0.outgoing && !$0.isRead
                    }.count
                    chat.unread = persistedUnreadIncomingCount
                    chat.syncUnreadCount = persistedUnreadIncomingCount
                    chat.runtimeUnreadCount = 0
                    chat.syncUnreadAfterId = openArchiveId(
                        plan.p14UnreadBoundaryOrdinal
                    )
                    chat.lastReadId = chat.syncUnreadAfterId
                    chat.lastVisibleMessagePrimary = openPrimary(
                        plan.p14SavedTargetOrdinal
                    )
                    chat.lastVisibleMessageArchivedId = openArchiveId(
                        plan.p14SavedTargetOrdinal
                    )
                    chat.lastVisibleMessageId = openMessageId(
                        plan.p14SavedTargetOrdinal
                    )
                    chat.lastVisibleMessageDate = openDate(
                        plan.p14SavedTargetOrdinal
                    )
                    chat.lastVisiblePositionSavedAtLastMessageId =
                        chat.lastMessageId
                    chat.lastVisiblePositionSavedAtSnapshotLastArchiveId =
                        chat.syncSnapshotLastArchiveId
                    chat.lastVisiblePositionUpdatedAt = openDate(
                        plan.p14LatestTargetOrdinal
                    )
                    chat.mentionId = openArchiveId(
                        plan.p14ExplicitMentionOrdinal
                    )
                    chat.groupchatMyId = p14CurrentMemberId
                }
            } else if plan.scenario == .confirmedEmpty {
                archiveState.lastSnapshotArchiveId = nil
            } else {
                archiveState.newerLiveEdgeReached = false
            }
            archiveState.updatedAt = Date()
            realm.add(chat, update: .modified)

            if plan.scenario == .mentionDeletedAdvance {
                let deletedOrdinal = plan.p13DeletedMentionOrdinal
                let nextOrdinal = plan.p13NextValidMentionOrdinal
                let deletedNotification = makeP13MentionNotification(
                    uniqueId: p13DeletedMentionNotificationUniqueId,
                    chatJid: jid,
                    archivedId: openArchiveId(deletedOrdinal),
                    messageId: openMessageId(deletedOrdinal),
                    date: openDate(deletedOrdinal)
                )
                let nextNotification = makeP13MentionNotification(
                    uniqueId: p13NextMentionNotificationUniqueId,
                    chatJid: jid,
                    archivedId: openArchiveId(nextOrdinal),
                    messageId: openMessageId(nextOrdinal),
                    date: openDate(nextOrdinal)
                )
                realm.add(deletedNotification, update: .modified)
                realm.add(nextNotification, update: .modified)

                let unrelatedMessage = makeP13UnrelatedMessage()
                realm.add(unrelatedMessage, update: .modified)
                let unrelatedChat = LastChatsStorageItem()
                unrelatedChat.primary = LastChatsStorageItem.genPrimary(
                    jid: p13UnrelatedGroupJidForTesting,
                    owner: owner,
                    conversationType: .group
                )
                unrelatedChat.owner = owner
                unrelatedChat.jid = p13UnrelatedGroupJidForTesting
                unrelatedChat.conversationType = .group
                unrelatedChat.messageDate = unrelatedMessage.date
                unrelatedChat.lastMessageId = unrelatedMessage.messageId
                unrelatedChat.isSynced = true
                unrelatedChat.isInitialArchiveLoaded = true
                unrelatedChat.fullArchiveLoaded = true
                unrelatedChat.isAllHistoryLoaded = true
                unrelatedChat.syncSnapshotLastArchiveId =
                    unrelatedMessage.archivedId
                unrelatedChat.groupchatMyId = p13CurrentMemberId
                unrelatedChat.mentionId = unrelatedMessage.archivedId
                realm.add(unrelatedChat, update: .modified)

                let unrelatedArchive =
                    RegularChatArchiveSyncStateStorageItem.ensure(
                        owner: owner,
                        jid: p13UnrelatedGroupJidForTesting,
                        conversationType: .group,
                        in: realm
                    )
                unrelatedArchive.olderArchiveEndReached = true
                unrelatedArchive.newerLiveEdgeReached = true
                unrelatedArchive.lastSnapshotArchiveId =
                    unrelatedMessage.archivedId
                unrelatedArchive.mergeLoadedRange(
                    first: unrelatedMessage.archivedId,
                    last: unrelatedMessage.archivedId,
                    updateKind: .bootstrapNewest
                )
                unrelatedArchive.updatedAt = unrelatedMessage.date

                let unrelatedNotification = makeP13MentionNotification(
                    uniqueId: p13UnrelatedMentionNotificationUniqueId,
                    chatJid: p13UnrelatedGroupJidForTesting,
                    archivedId: unrelatedMessage.archivedId,
                    messageId: unrelatedMessage.messageId,
                    date: unrelatedMessage.date
                )
                realm.add(unrelatedNotification, update: .modified)
            }

            if plan.scenario == .lastChatsSeededMentionExact {
                realm.delete(
                    realm.objects(NotificationStorageItem.self).filter(
                        "owner == %@ AND category_ == %@ AND associatedJid == %@",
                        owner,
                        XMPPNotificationsManager.Category.mention.rawValue,
                        jid
                    )
                )
                let targetOrdinal = plan.p14ExplicitMentionOrdinal
                let uniqueId = p14MentionNotificationUniqueId
                let notification = NotificationStorageItem()
                notification.primary = NotificationStorageItem.genPrimary(
                    owner: owner,
                    jid: jid,
                    uniqueId: uniqueId
                )
                notification.owner = owner
                notification.jid = jid
                notification.uniqueId = uniqueId
                notification.messageId = uniqueId
                notification.category = .mention
                notification.isRead = false
                notification.shouldShow = true
                notification.associatedJid = jid
                notification.date = openDate(targetOrdinal)
                notification.sourceConversationType = .group
                notification.sourceChatJid = jid
                notification.sourceArchivedId = openArchiveId(targetOrdinal)
                notification.sourceMessageId = openMessageId(targetOrdinal)
                notification.sourceSenderId = p14OtherMemberId
                notification.mentionTargetUserId = p14CurrentMemberId
                notification.sourceMessageDate = openDate(targetOrdinal)
                notification.sourceBodyFingerprint =
                    MentionNotificationSync.normalizedBodyFingerprint(
                        messages.first(where: {
                            $0.archivedId == openArchiveId(targetOrdinal)
                        })?.body
                    )
                notification.mentionLinkStatus = .resolved
                notification.linkedAt = openDate(targetOrdinal)
                realm.add(notification, update: .modified)
            }
        }

        switch plan.scenario {
        case .notificationExactLocal, .notificationExactRemote,
             .notificationKnownGapTarget, .searchExactLocal,
             .searchExactLocalOutsideWindow, .searchExactRemote,
             .knownGapMissingTarget, .coldPushExact, .newerCrossingGap:
            guard let targetOrdinal = plan.expectedTargetOrdinal,
                  let source = plan.expectedRequestSource,
                  let markReadOnVisible =
                    plan.expectedRequestMarkReadOnVisible else {
                throw OpenScenarioError.targetSelectionUnavailable
            }
            pendingOpenMessageRequest = makeOpenScenarioRequest(
                targetOrdinal: targetOrdinal,
                source: source,
                highlight: plan.expectedRequestHighlight ?? false,
                markReadOnVisible: markReadOnVisible
            )
        case .unreadBoundaryLocal, .savedPositionLocal:
            try selectAutomaticOpenScenarioRequest(realm: realm)
        case .preloadedLatest, .confirmedEmpty, .bootstrapEmptyToContent,
             .bootstrapStaleLocalToContent,
             .bootstrapEmptyToTrustedEmpty, .bootstrapHeldOverWatchdog,
             .bootstrapTerminalFailureRetry,
             .latestWithUnrelatedOlderGap, .lastChatsAnimatedPush,
             .mentionDeletedAdvance,
             .lastChatsSeededMentionExact,
             .olderCrossingGap, .rotationRealPipeline,
             .committedContentBackgroundForeground:
            pendingOpenMessageRequest = nil
        }
        guard plan.scenario == .lastChatsSeededMentionExact ||
                plan.scenario == .mentionDeletedAdvance
                ? pendingOpenMessageRequest == nil
                : pendingOpenMessageRequest?.source == plan.expectedRequestSource else {
            throw OpenScenarioError.targetSelectionUnavailable
        }
        openScenarioStorageDiagnostics =
            captureOpenScenarioStorageDiagnostics(in: realm)
    }

    private func selectAutomaticOpenScenarioRequest(
        realm: Realm
    ) throws {
        guard let chat = realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: conversationType
            )
        ) else {
            throw OpenScenarioError.targetSelectionUnavailable
        }
        let savedPosition: ChatSavedVisiblePosition?
        if chat.lastVisibleMessagePrimary?.isNotEmpty == true ||
            chat.lastVisibleMessageArchivedId?.isNotEmpty == true ||
            chat.lastVisibleMessageId?.isNotEmpty == true {
            savedPosition = ChatSavedVisiblePosition(
                messagePrimary: chat.lastVisibleMessagePrimary,
                archivedId: chat.lastVisibleMessageArchivedId,
                messageId: chat.lastVisibleMessageId,
                sourceDate: chat.lastVisibleMessageDate ?? chat.messageDate
            )
        } else {
            savedPosition = nil
        }
        let state = ChatInitialPositionPolicy.ChatState(
            owner: chat.owner,
            jid: chat.jid,
            conversationType: chat.conversationType,
            unread: chat.unread,
            syncUnreadCount: chat.syncUnreadCount,
            syncUnreadAfterId: chat.syncUnreadAfterId,
            lastReadId: chat.lastReadId,
            lastMessageId: chat.lastMessageId,
            syncSnapshotLastArchiveId: chat.syncSnapshotLastArchiveId,
            messageDate: chat.messageDate,
            savedPosition: savedPosition,
            savedAtLastMessageId: chat.lastVisiblePositionSavedAtLastMessageId,
            savedAtSnapshotLastArchiveId:
                chat.lastVisiblePositionSavedAtSnapshotLastArchiveId
        )
        switch ChatInitialPositionPolicy.decision(for: state, explicitRequest: nil) {
        case .open(let request):
            pendingOpenMessageRequest = request
        case .bottom:
            pendingOpenMessageRequest = nil
        }
    }

    @discardableResult
    internal func captureOpenScenarioStorageDiagnostics() throws
        -> ChatOpenRealPipelineFixtureStorageDiagnostics {
        let realm = try WRealm.safe()
        if openScenarioRouteMeasurementHasStarted {
            openScenarioFixtureRealmQueryCountAfterRouteAdmission &+= 1
        }
        let diagnostics = captureOpenScenarioStorageDiagnostics(in: realm)
        openScenarioStorageDiagnostics = diagnostics
        return diagnostics
    }

    private func captureOpenScenarioStorageDiagnostics(
        in realm: Realm
    ) -> ChatOpenRealPipelineFixtureStorageDiagnostics {
        let inMemoryIdentifier = realm.configuration.inMemoryIdentifier
        let chat = realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: conversationType
            )
        )
        let archiveState = realm.object(
            ofType: RegularChatArchiveSyncStateStorageItem.self,
            forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                jid: jid,
                owner: owner,
                conversationType: conversationType
            )
        )
        let messageCount = realm.objects(MessageStorageItem.self).filter(
            "owner == %@ AND opponent == %@ AND conversationType_ == %@",
            owner,
            jid,
            conversationType.rawValue
        ).count
        return ChatOpenRealPipelineFixtureStorageDiagnostics(
            hasRetainedRealmLease:
                inMemoryIdentifier != nil &&
                openScenarioRealmLease?.configuration.inMemoryIdentifier == inMemoryIdentifier,
            isEphemeral: inMemoryIdentifier != nil,
            messageCount: messageCount,
            hasChatRecord: chat != nil,
            hasArchiveState: archiveState != nil,
            hasDurableReadiness: ConversationArchiveDurableReadinessPolicy.isReady(
                chat: chat,
                archiveState: archiveState,
                conversationType: conversationType,
                localMessageCount: messageCount
            )
        )
    }

    internal func captureOpenScenarioProductionBootstrapDiagnostics() ->
        ChatInitialBootstrapRequestCoordinator.ProductionDiagnosticsSnapshot {
        ChatInitialBootstrapRequestCoordinator.shared
            .productionDiagnosticsSnapshot(for: initialBootstrapRequestKey)
    }

    /// Exposes only the store work admitted after this controller's route
    /// checkpoint. A reused session therefore cannot make prior operation
    /// keys hide extra work in the route currently under test.
    internal func captureOpenScenarioRouteStoreDiagnosticsForTesting() ->
        ChatTimelineStoreDiagnosticsSnapshot? {
        timelineSession?.routeStoreDiagnosticsSnapshot.routeDelta(
            since: openScenarioRouteStoreDiagnosticsBaseline
        )
    }

    private func captureOpenScenarioActiveProductionWorkCount(
        bootstrapDiagnostics:
            ChatInitialBootstrapRequestCoordinator.ProductionDiagnosticsSnapshot
    ) -> Int {
        var count = bootstrapDiagnostics.activeLeaseCount
        func countIf(_ condition: Bool) {
            if condition { count &+= 1 }
        }

        let initialFrameIsCommitted: Bool
        if case .committed = initialLocalFirstFramePhase {
            initialFrameIsCommitted = true
        } else {
            initialFrameIsCommitted = false
        }
        let committedSkeletonIsTerminal =
            performanceFixtureAllowsSkeletonStableFrame &&
            hasCommittedExactBootstrapSkeletonRows &&
            openScenarioActiveDwellPlan == nil &&
            !isInitialBootstrapInFlight
        countIf(!initialFrameIsCommitted && !committedSkeletonIsTerminal)
        count &+= timelineSession?.activePreparationCount ?? 0
        count &+= timelineSession?.activeStoreObservationWorkCount ?? 0
        countIf(initialLocalFirstFrameMappingToken != nil)
        countIf(activePostBootstrapInitialFrameAdmission != nil)
        countIf(initialLocalFirstFrameCompletions.isNotEmpty)
        countIf(pendingBootstrapFirstFrameReadinessCompletions.isNotEmpty)
        countIf(isInitialBootstrapInFlight)
        countIf(initialBootstrapTimeoutWorkItem != nil)
        countIf(initialBootstrapLocalHistoryFallbackWorkItem != nil)
        countIf(isChatDatasourceStructuralTransactionActive)
        countIf(
            timelineInteractionState.isLoading &&
            !committedSkeletonIsTerminal
        )
        countIf(interactiveHistoryPageLoadContext != nil)
        countIf(virtualTimelineState.activeRemoteLoad != nil)
        countIf(activeChatHistoryLoadActivityKeys.isNotEmpty)
        count &+= remoteHistoryQueryCoordinator.activeQueryCount
        countIf(!remoteHistoryRequestStartedAtByQueryId.isEmpty)
        countIf(!remoteHistoryEndPageDispatcherTokens.isEmpty)
        countIf(!remoteHistoryFailureDispatcherTokens.isEmpty)
        countIf(remoteHistoryFinishingQueryId != nil)
        count &+= performanceFixtureDetachedPersistenceQueryIds.count
        countIf(interactiveHistoryCompletionRetryWorkItem != nil)
        countIf(pendingArchiveObserverRefresh)
        countIf(archiveObserverRefreshWorkItem != nil)
        countIf(pendingOpenMessageRequest != nil)
        countIf(activeAnchorExecutionState != nil)
        countIf(isExecutingOpenMessageRequest)
        countIf(isMessageAnchorNavigationInFlight)
        countIf(anchorTransactionGate.snapshot.activeToken != nil)
        count &+= anchorTransactionTokenByQueryId.count
        count &+= anchorTransactionTimeoutWorkItems.count
        count &+= scrollWorkScheduler.pendingRequestCount
        countIf(pendingLocalHistoryPagingIntent != nil)
        countIf(pendingPreparedLocalHistoryPage != nil)
        countIf(pendingDeferredRemoteHistoryDirection != nil)
        countIf(pendingDeferredRemoteHistoryPreparation != nil)
        countIf(openScenarioPendingRemoteInjectionPlan != nil)
        countIf(openScenarioRemoteActionLatch.hasPendingAcknowledgement)
        countIf(openScenarioDeferredInitialBootstrapPlan != nil)
        countIf(openScenarioDarwinAcknowledgementObserver != nil)
        countIf(currentScrollMotionState() != .resting)
        if descriptor.openScenario == .lastChatsSeededMentionExact {
            count &+= readVisiblePresentationCoordinator.pendingCandidateCount
            count &+= readVisiblePresentationCoordinator.inFlightFlushCount
            countIf(visibleUnreadMentionReconciliationWorkItem != nil)
            countIf(readVisibleStableLayoutRetryWorkItem != nil)
            count &+= p14MentionFreshRealmProofInFlightCount
        }
        count &+= openScenarioTransportThreadRecorder.snapshot
            .pendingOperationCount
        return count
    }

    private func captureP14MentionDiagnostics()
        -> ChatPerformanceP14MentionDiagnostics {
        guard descriptor.openScenario == .lastChatsSeededMentionExact else {
            return .zero
        }
        return ChatPerformanceP14MentionDiagnostics(
            unreadFrameCount: p14MentionUnreadFrameCount,
            savedFrameCount: p14MentionSavedFrameCount,
            readEagerMutationCount: p14MentionReadEagerMutationCount,
            readScheduledCount: p14MentionReadScheduledCount,
            readCommittedCount: p14MentionReadCommittedCountForTesting,
            readSuccessfulFlushCount: max(
                0,
                readVisiblePresentationCoordinator.successfulFlushCount -
                    p14ReadSuccessfulFlushCountBaseline
            ),
            readTerminalSuccessCount:
                p14MentionReadTerminalSuccessCount,
            readTerminalFailureCount:
                p14MentionReadTerminalFailureCount,
            unreadBeforeTap: p14MentionUnreadBeforeTap,
            unreadAtAdmission: p14MentionUnreadAtAdmission,
            unreadAtInitialCommit: p14MentionUnreadAtInitialCommit,
            readAtTerminal: p14MentionReadAtTerminal,
            freshRealmMatchCount: p14MentionFreshRealmMatchCount,
            freshRealmProofFailureCount:
                p14MentionFreshRealmProofFailureCount,
            pendingCandidateCount:
                readVisiblePresentationCoordinator.pendingCandidateCount,
            inFlightFlushCount:
                readVisiblePresentationCoordinator.inFlightFlushCount,
            hasReconciliationWorkItem:
                visibleUnreadMentionReconciliationWorkItem != nil,
            hasStableLayoutRetryWorkItem:
                readVisibleStableLayoutRetryWorkItem != nil
        )
    }

    private func injectOpenScenarioRemotePage(plan: ChatOpenRealPipelineFixturePlan) {
        guard let session = openScenarioArchiveTransportSession,
              let queryId = openScenarioQueryId,
              let transportGeneration = openScenarioArchiveTransportGeneration,
              let descriptor = openScenarioArchiveDescriptor(for: queryId) else {
            publishOpenScenarioFailure(plan: plan)
            return
        }
        let ordinalValues: [Int]
        let expectedSemanticRouteClass:
            ChatPerformanceFixtureArchiveSemanticRouteClass
        switch descriptor.semanticRouteClass {
        case .latest:
            guard let ordinals = plan.remoteInjectionOrdinalRange else {
                rejectOpenScenarioArchiveDescriptor(plan: plan)
                return
            }
            ordinalValues = Array(ordinals)
            expectedSemanticRouteClass = .latest
        case .exactTarget:
            guard let targetOrdinal = plan.expectedTargetOrdinal else {
                rejectOpenScenarioArchiveDescriptor(plan: plan)
                return
            }
            ordinalValues = [targetOrdinal]
            expectedSemanticRouteClass = .exactTarget
        default:
            rejectOpenScenarioArchiveDescriptor(plan: plan)
            return
        }
        guard let serverResultCount =
                plan.successfulArchiveServerResultCount,
              serverResultCount >= ordinalValues.count else {
            rejectOpenScenarioArchiveDescriptor(plan: plan)
            return
        }
        enqueueOpenScenarioArchiveTransport(
            generation: transportGeneration,
            plan: plan,
            operation: { [weak self] in
                guard let self else {
                    throw OpenScenarioError.archiveTransportUnavailable
                }
                try self.deliverOpenScenarioArchivePage(
                    session: session,
                    queryId: queryId,
                    ordinals: ordinalValues,
                    complete: plan.successfulArchiveFinalIsComplete ||
                        descriptor.semanticRouteClass == .exactTarget,
                    serverResultCount: serverResultCount,
                    deliverDuplicateFinalForIdempotencyProof: true,
                    descriptor: descriptor,
                    expectedSource: plan.expectedRequestSource,
                    expectedSemanticRouteClass: expectedSemanticRouteClass,
                    transportGeneration: transportGeneration
                )
            },
            mainCompletion: { [weak self] in
                self?.beginOpenScenarioTerminalObservation(plan: plan)
            }
        )
    }

    private func enqueueOpenScenarioArchiveTransport(
        generation: Int,
        plan: ChatOpenRealPipelineFixturePlan,
        operation: @escaping () throws -> Void,
        mainCompletion: (() -> Void)? = nil
    ) {
        guard openScenarioTransportThreadRecorder.beginOperation(
            generation: generation
        ) else {
            publishOpenScenarioFailure(plan: plan)
            return
        }
        openScenarioArchiveTransportQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<Void, Error> = autoreleasepool {
                guard self.openScenarioTransportThreadRecorder.isCurrent(
                    generation: generation
                ) else {
                    return .failure(OpenScenarioError.archiveTransportUnavailable)
                }
                do {
                    try operation()
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            self.openScenarioTransportThreadRecorder.endOperation(
                generation: generation
            )
            self.completeOpenScenarioArchiveTransport(
                generation: generation,
                plan: plan,
                result: result,
                mainCompletion: mainCompletion
            )
        }
    }

    private func completeOpenScenarioArchiveTransport(
        generation: Int,
        plan: ChatOpenRealPipelineFixturePlan,
        result: Result<Void, Error>,
        mainCompletion: (() -> Void)?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.openScenarioTransportThreadRecorder.isCurrent(
                    generation: generation
                  ),
                  self.descriptor.openScenario == plan.scenario,
                  self.openScenarioStableReceipt == nil else {
                return
            }
            switch result {
            case .success:
                mainCompletion?()
            case .failure(let error):
                self.openScenarioSetupFailure = String(
                    describing: type(of: error)
                )
                self.publishOpenScenarioFailure(plan: plan)
            }
        }
    }

    /// Deliberately publishes the real MAM final before the last
    /// MessageManager ingress. The production persistence barrier must hold
    /// the terminal until that last row is accounted for. Replaying the same
    /// final then proves descriptor/commit idempotency without using any
    /// coordinator testing hook.
    private func deliverOpenScenarioArchivePage(
        session: ChatPerformanceFixtureArchiveTransportSession,
        queryId: String,
        ordinals: [Int],
        complete: Bool,
        serverResultCount: Int,
        deliverDuplicateFinalForIdempotencyProof: Bool,
        descriptor: ChatPerformanceFixtureArchiveRequestDescriptor,
        expectedSource: ChatOpenMessageRequestSource?,
        expectedSemanticRouteClass:
            ChatPerformanceFixtureArchiveSemanticRouteClass,
        expectedDeliveredArchiveIDs: [String]? = nil,
        transportGeneration: Int
    ) throws {
        let deliveredArchiveIDs = ordinals.map(openArchiveId)
        guard ChatPerformanceFixtureArchivePayloadAdmissionPolicy.accepts(
            descriptor: descriptor,
            deliveredArchiveIDs: deliveredArchiveIDs,
            firstArchiveID: deliveredArchiveIDs.first,
            lastArchiveID: deliveredArchiveIDs.last,
            expectedSource: expectedSource,
            expectedSemanticRouteClass: expectedSemanticRouteClass,
            expectedDeliveredArchiveIDs: expectedDeliveredArchiveIDs
        ) else {
            throw OpenScenarioError.archiveDescriptorRejected
        }
        let messages = try ordinals.map {
            try makeOpenScenarioArchivedMessage(
                ordinal: $0,
                queryId: queryId
            )
        }
        for message in messages {
            openScenarioTransportThreadRecorder.record(
                .archiveEnvelope,
                generation: transportGeneration,
                isMainThread: Thread.isMainThread
            )
            guard session.archiveManager.recordDeferredArchiveResultDelivery(
                message
            ) else {
                throw OpenScenarioError.archiveDescriptorRejected
            }
        }

        let final = try makeOpenScenarioArchiveFinalIQ(
            queryId: queryId,
            complete: complete,
            count: serverResultCount,
            first: ordinals.first.map(openArchiveId),
            last: ordinals.last.map(openArchiveId)
        )
        let lastMessage = messages.last
        messages.dropLast().forEach {
            openScenarioTransportThreadRecorder.record(
                .messageIngress,
                generation: transportGeneration,
                isMainThread: Thread.isMainThread
            )
            session.messageManager.receiveArchived($0)
        }
        openScenarioTransportThreadRecorder.record(
            .finalParser,
            generation: transportGeneration,
            isMainThread: Thread.isMainThread
        )
        guard session.archiveManager.read(session.stream, withIQ: final) else {
            throw OpenScenarioError.archiveDescriptorRejected
        }
        if deliverDuplicateFinalForIdempotencyProof {
            openScenarioTransportThreadRecorder.record(
                .finalParser,
                generation: transportGeneration,
                isMainThread: Thread.isMainThread
            )
            _ = session.archiveManager.read(session.stream, withIQ: final)
        }
        if let lastMessage {
            openScenarioTransportThreadRecorder.record(
                .messageIngress,
                generation: transportGeneration,
                isMainThread: Thread.isMainThread
            )
            session.messageManager.receiveArchived(lastMessage)
        }
    }

    private func makeOpenScenarioArchivedMessage(
        ordinal: Int,
        queryId: String
    ) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: """
        <message xmlns='jabber:client' from='\(owner)' to='\(owner)'>
          <result xmlns='urn:xmpp:mam:2' queryid='\(queryId)' id='\(openArchiveId(ordinal))'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message xmlns='jabber:client' from='\(jid)' to='\(owner)' type='chat' id='\(openMessageId(ordinal))'>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='\(openArchiveId(ordinal))'/>
                <origin-id xmlns='urn:xmpp:sid:0' id='\(openMessageId(ordinal))'/>
                <body>deterministic chat-open fixture row \(ordinal)</body>
              </message>
              <delay xmlns='urn:xmpp:delay' stamp='\(openDate(ordinal).XMPPFormattedDate)'/>
            </forwarded>
          </result>
        </message>
        """, options: 0)
        guard let root = document.rootElement() else {
            throw OpenScenarioError.malformedArchiveFixture
        }
        return XMPPMessage(from: root)
    }

    private func makeOpenScenarioArchiveFinalIQ(
        queryId: String,
        complete: Bool,
        count: Int,
        first: String?,
        last: String?
    ) throws -> XMPPIQ {
        let firstElement = first.map { "<first>\($0)</first>" } ?? ""
        let lastElement = last.map { "<last>\($0)</last>" } ?? ""
        let document = try DDXMLDocument(xmlString: """
        <iq type='result' id='\(queryId)'>
          <fin xmlns='urn:xmpp:mam:2' complete='\(complete ? "true" : "false")' queryid='\(queryId)'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>\(max(0, count))</count>
              \(firstElement)
              \(lastElement)
            </set>
          </fin>
        </iq>
        """, options: 0)
        guard let root = document.rootElement() else {
            throw OpenScenarioError.malformedArchiveFixture
        }
        return XMPPIQ(from: root)
    }

    private func makeOpenScenarioArchiveFailureIQ(
        queryId: String
    ) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: """
        <iq type='error' id='\(queryId)'>
          <query xmlns='urn:xmpp:mam:2' queryid='\(queryId)'/>
          <error type='cancel'>
            <service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
          </error>
        </iq>
        """, options: 0)
        guard let root = document.rootElement() else {
            throw OpenScenarioError.malformedArchiveFixture
        }
        return XMPPIQ(from: root)
    }

    @discardableResult
    private func beginOpenScenarioTerminalObservation(
        plan: ChatOpenRealPipelineFixturePlan
    ) -> Bool {
        guard !openScenarioTerminalTeardownCompleted,
              let observationGeneration =
                openScenarioTerminalPublicationGate.beginObservation() else {
            return false
        }
        openScenarioObservationDeadline = Date().addingTimeInterval(8)
        openScenarioTerminalObservationPlan = plan
        openScenarioTerminalObservationGeneration = observationGeneration
        return true
    }

    /// Samples at the compositor-facing display cadence. An optional
    /// same-transaction alignment correction cannot reach a display tick and
    /// therefore is intentionally not counted as a user-visible jump.
    private func startOpenScenarioVisibleOffsetSampling() {
        let generation = openScenarioOffsetSamplerGate.beginSampling()
        openScenarioOffsetDisplayLinkGeneration = generation
        openScenarioLastRotationSourceSample = nil
        let displayLink: CADisplayLink
        if let installed = openScenarioOffsetDisplayLink {
            displayLink = installed
        } else {
            let installed = CADisplayLink(
                target: self,
                selector: #selector(sampleOpenScenarioVisibleOffset(_:))
            )
            installed.preferredFramesPerSecond = 60
            installed.add(to: .main, forMode: .common)
            openScenarioOffsetDisplayLink = installed
            displayLink = installed
        }
        displayLink.isPaused = false
    }

    private func pauseOpenScenarioVisibleOffsetSampling() {
        openScenarioOffsetSamplerGate.pause()
        openScenarioOffsetDisplayLinkGeneration = nil
        openScenarioLastRotationSourceSample = nil
        openScenarioOffsetDisplayLink?.isPaused = true
    }

    private func resumeOpenScenarioVisibleOffsetSampling() {
        // The first resumed sample compares against the final pre-pause
        // baseline, so any genuine movement during the handshake is retained.
        startOpenScenarioVisibleOffsetSampling()
    }

    private func stopOpenScenarioVisibleOffsetSampling(
        capturingCurrentOffset: Bool
    ) {
        // `capturingCurrentOffset` is retained at the call boundary to make
        // terminal intent explicit. Evidence itself remains display-tick-only.
        _ = capturingCurrentOffset
        openScenarioOffsetSamplerGate.stop()
        openScenarioOffsetDisplayLinkGeneration = nil
        openScenarioLastRotationSourceSample = nil
        openScenarioOffsetDisplayLink?.invalidate()
        openScenarioOffsetDisplayLink = nil
        openScenarioTerminalObservationPlan = nil
        openScenarioTerminalObservationGeneration = nil
        openScenarioSkeletonObservationPlan = nil
        openScenarioSkeletonObservationDeadline = nil
        openScenarioAutomaticInjectionPlan = nil
        openScenarioAutomaticInjectionDisplayTimestamp = nil
        openScenarioPendingRemoteInjectionPlan = nil
        openScenarioE04AcknowledgementAwaitingDisplayTick = false
        openScenarioDeferredInitialBootstrapPlan = nil
        openScenarioRemoteActionLatch.invalidate()
        openScenarioVideoMarkerGate.invalidate()
        openScenarioVideoMarkerGeneration = nil
        openScenarioFrozenTerminalEvidence = nil
        openScenarioPendingStablePlan = nil
        openScenarioPendingStableObservationGeneration = nil
    }

    private func recordOpenScenarioVisibleOffsetSample(
        displayTimestamp: TimeInterval,
        samplerGeneration: Int
    ) {
        guard descriptor.openScenario != nil,
              openScenarioStableReceipt == nil else {
            return
        }
        recordOpenScenarioProductionRemoteHistoryState()
        let currentOffsetY = messagesCollectionView.contentOffset.y
        openScenarioInitialSkeletonRowCount = max(
            openScenarioInitialSkeletonRowCount,
            openScenarioSkeletonRowCount
        )
        let hasOffsetMovement = openScenarioLastSampledOffsetY.map {
            abs($0 - currentOffsetY) > 0.5
        } ?? false
        let retainedPagingAnchorStayedFixed =
            currentOpenScenarioPagingAnchorErrorMilliPoints().map {
                $0 <= 1_000
            } ?? false
        let rotationSemanticViewportStayedFixed =
            currentOpenScenarioBottomDistanceMilliPoints().map {
                $0 <= 500
            } ?? false
        if openScenarioRotationOffsetGate.isActive {
            openScenarioRotationOffsetGate.observeSemanticViewport(
                stayedFixed: rotationSemanticViewportStayedFixed
            )
            return
        }
        if descriptor.openScenario == .rotationRealPipeline,
           !openScenarioHasCommittedViewport {
            // The atomic initial-frame receipt owns this complete phase. A
            // generic display tick must not race or split one transaction.
            return
        }
        openScenarioOffsetMutationEvidence.record(
            ChatOpenRealPipelineFixtureOffsetMutationPolicy.classification(
                hasOffsetMovement: hasOffsetMovement,
                hasCommittedViewport: openScenarioHasCommittedViewport,
                retainedPagingAnchorStayedFixed:
                    retainedPagingAnchorStayedFixed,
                hasRotationInteractionOwnership: false,
                rotationSemanticViewportStayedFixed: false
            )
        )
        openScenarioLastSampledOffsetY = currentOffsetY
        if descriptor.openScenario == .rotationRealPipeline,
           openScenarioHasCommittedViewport {
            openScenarioLastRotationSourceSample =
                ChatOpenRealPipelineFixtureRotationSourceSample(
                    offsetY: currentOffsetY,
                    viewportSize: view.bounds.size,
                    displayTimestamp: displayTimestamp,
                    samplerGeneration: samplerGeneration,
                    semanticViewportStayedFixed:
                        rotationSemanticViewportStayedFixed
                )
        }
    }

    private func recordOpenScenarioAtomicInitialOffsetIfNeeded() {
        guard descriptor.openScenario == .rotationRealPipeline,
              let receipt = openScenarioAtomicInitialOffsetGate.complete(
                committedOffsetY: messagesCollectionView.contentOffset.y
              ) else {
            return
        }
        openScenarioOffsetMutationEvidence.record(
            ChatOpenRealPipelineFixtureOffsetMutationPolicy.classification(
                hasOffsetMovement: receipt.hasOffsetMovement,
                hasCommittedViewport: false,
                retainedPagingAnchorStayedFixed: false,
                hasRotationInteractionOwnership: false,
                rotationSemanticViewportStayedFixed: false
            )
        )
    }

    @discardableResult
    private func recordOpenScenarioRotationOffsetEndpoint() -> Bool {
        let semanticViewportStayedFixed =
            currentOpenScenarioBottomDistanceMilliPoints().map {
                $0 <= 500
            } ?? false
        guard let receipt = openScenarioRotationOffsetGate.complete(
            targetOffsetY: messagesCollectionView.contentOffset.y,
            semanticViewportStayedFixed: semanticViewportStayedFixed
        ) else {
            return false
        }
        openScenarioOffsetMutationEvidence.record(
            ChatOpenRealPipelineFixtureOffsetMutationPolicy.classification(
                hasOffsetMovement: receipt.hasOffsetMovement,
                hasCommittedViewport: true,
                retainedPagingAnchorStayedFixed: false,
                hasRotationInteractionOwnership: true,
                rotationSemanticViewportStayedFixed:
                    receipt.semanticViewportStayedFixed
            )
        )
        openScenarioLastSampledOffsetY =
            messagesCollectionView.contentOffset.y
        openScenarioLastRotationSourceSample = nil
        return true
    }

    private func recordOpenScenarioWidthTransitionLayoutCommit(
        generation: Int,
        targetViewSize: CGSize
    ) {
        guard descriptor.openScenario == .rotationRealPipeline,
              openScenarioPostInitialInteractionReady,
              openScenarioStableReceipt == nil else {
            return
        }
        let admission = openScenarioRotationOffsetGate
            .admitProductionLayoutCommit(
                generation: generation,
                targetViewSize: targetViewSize
            )
        openScenarioRotationBarrierDiagnostics.recordProductionCommit(
            admission
        )
        publishOpenScenarioRotationBarrierDiagnostics()
        guard admission == .accepted else {
            return
        }
        finalizeOpenScenarioRotationOffsetEndpointIfReady()
    }

    private func finalizeOpenScenarioRotationOffsetEndpointIfReady() {
        guard recordOpenScenarioRotationOffsetEndpoint() else { return }
        openScenarioRotationBarrierDiagnostics.recordEndpoint()
        publishOpenScenarioRotationBarrierDiagnostics()
        completeOpenScenarioRotationTransition()
    }

    private func publishOpenScenarioRotationBarrierDiagnostics() {
        guard descriptor.openScenario == .rotationRealPipeline,
              openScenarioStableReceipt == nil else {
            return
        }
        let fields =
            openScenarioRotationBarrierDiagnostics.accessibilityFields
        print(
            "CHAT_OPEN_FIXTURE_ROTATION_BARRIER " +
                fields.joined(separator: " ")
        )
        renderOpenScenarioPhase(
            .content,
            plan: ChatOpenRealPipelineFixturePlan(
                scenario: .rotationRealPipeline
            )
        )
    }

    private func currentOpenScenarioBottomDistanceMilliPoints() -> Int? {
        guard descriptor.openScenario == .rotationRealPipeline,
              openScenarioHasCommittedViewport else {
            return nil
        }
        let distance = ChatTailAppendBottomPinPolicy.bottomDistance(
            contentHeight: messagesCollectionView.contentSize.height,
            viewportHeight: messagesCollectionView.bounds.height,
            contentInsets: messagesCollectionView.contentInset,
            contentOffsetY: messagesCollectionView.contentOffset.y
        )
        return Int((distance * 1_000).rounded())
    }

    /// A display-link sample is the closest process-local proxy for a frame
    /// that could reach the compositor. E04 keeps this counter separate from
    /// commit diagnostics because a generic Realm-observer apply would not
    /// necessarily enter the atomic initial-frame callback.
    private func recordOpenScenarioPreTerminalVisualState() {
        guard descriptor.openScenario == .bootstrapStaleLocalToContent,
              openScenarioStableReceipt == nil,
              openScenarioProductionVisualCommitCount == 0 else {
            return
        }
        if openScenarioSkeletonPresentationBaseline != nil {
            compareOpenScenarioSkeletonWithBaseline()
        }
        let realRows = datasource.lazy.filter { !$0.isFakeMessage }.count
        guard realRows > 0 else { return }
        openScenarioStalePreTerminalRealFrameCount &+= 1
        if openScenarioSkeletonRowCount > 0 {
            openScenarioMixedSkeletonAndRealFrameCount &+= 1
        }
    }

    private func currentOpenScenarioPagingAnchorErrorMilliPoints() -> Int? {
        guard let anchor = openScenarioPagingRetainedAnchor,
              let section = datasourceSnapshot.primaryIndex[anchor.primary]
        else {
            return nil
        }
        let indexPath = IndexPath(item: 0, section: section)
        let frame = messagesCollectionView.collectionViewLayout
            .layoutAttributesForItem(at: indexPath)?.frame ??
            messagesCollectionView.cellForItem(at: indexPath)?.frame
        guard let frame else { return nil }
        let viewportRelativeMinY =
            frame.minY - messagesCollectionView.contentOffset.y
        return Int((abs(
            viewportRelativeMinY - anchor.viewportRelativeMinY
        ) * 1_000).rounded())
    }

    /// Observes the controller's real generation-scoped history machinery in
    /// addition to the fixture transport seam. Query identifiers stay inside
    /// the process; only closed counters and cursor kinds reach accessibility.
    /// Completed/aborted IDs are intentionally included so a short request
    /// cannot disappear between display-tick samples.
    private func recordOpenScenarioProductionRemoteHistoryState() {
        guard let scenario = descriptor.openScenario else { return }

        var archiveQueryIds = Set(remoteHistoryRequestStartedAtByQueryId.keys)
        archiveQueryIds.formUnion(completedRemoteHistoryEndPageQueryIds)
        archiveQueryIds.formUnion(abortedRemoteHistoryQueryIds)
        if let context = interactiveHistoryPageLoadContext,
           context.remoteFetchStarted {
            archiveQueryIds.insert(context.queryId)
        }
        if let activeRemoteLoad = virtualTimelineState.activeRemoteLoad {
            archiveQueryIds.insert(activeRemoteLoad.queryId)
            switch activeRemoteLoad.decision {
            case .remoteGapRepairOlder, .remoteGapRepairNewer:
                openScenarioObservedProductionGapQueryIds.insert(
                    activeRemoteLoad.queryId
                )
            case .localOnly, .remoteOlderPage, .remoteNewerPage, .endReached:
                break
            }
        }
        if let context = interactiveHistoryPageLoadContext {
            switch context.coverageUpdateKind {
            case .gapRepairOlder, .gapRepairNewer:
                openScenarioObservedProductionGapQueryIds.insert(context.queryId)
            case .bootstrapNewest, .pageOlder, .pageNewer, .disjointWindow, .none:
                break
            }
        }

        openScenarioObservedProductionArchiveQueryIds.formUnion(archiveQueryIds)
        if scenario == .latestWithUnrelatedOlderGap {
            // This route has no permitted remote work. Conservatively classify
            // any observed production archive query as traversal of its sole
            // unresolved topology boundary so both forbidden counters fail.
            openScenarioObservedProductionGapQueryIds.formUnion(archiveQueryIds)
        }
        if openScenarioObservedProductionGapQueryIds.isNotEmpty,
           openScenarioArchiveCursorKind == .none {
            openScenarioArchiveCursorKind = .aroundTarget
        } else if openScenarioObservedProductionArchiveQueryIds.isNotEmpty,
                  openScenarioArchiveCursorKind == .none {
            openScenarioArchiveCursorKind = .latest
        }
    }

    @objc private func sampleOpenScenarioVisibleOffset(
        _ displayLink: CADisplayLink
    ) {
        guard descriptor.openScenario != nil,
              openScenarioStableReceipt == nil,
              let generation = openScenarioOffsetDisplayLinkGeneration,
              openScenarioOffsetSamplerGate.consumeDisplayTick(
                generation: generation,
                timestamp: displayLink.timestamp
              ) else {
            return
        }
        recordOpenScenarioVisibleOffsetSample(
            displayTimestamp: displayLink.timestamp,
            samplerGeneration: generation
        )
        if descriptor.openScenario == .bootstrapStaleLocalToContent,
           openScenarioProductionVisualCommitCount == 0,
           openScenarioSkeletonPresentationBaseline != nil {
            openScenarioHeldSkeletonDisplayTickCount &+= 1
        }
        recordOpenScenarioPreTerminalVisualState()
        issueP14ProductionPresentationReceiptIfReady()
        completeOpenScenarioAcknowledgementAfterHeldTickIfReady()
        if let scenario = descriptor.openScenario,
           scenario == .newerCrossingGap {
            renderNewerGapInteractionReadyIfPossible(
                plan: ChatOpenRealPipelineFixturePlan(scenario: scenario)
            )
        }
        if let plan = openScenarioSkeletonObservationPlan,
           let deadline = openScenarioSkeletonObservationDeadline {
            waitForOpenScenarioSkeletonBeforeInjection(
                plan: plan,
                deadline: deadline
            )
        }
        if let plan = openScenarioAutomaticInjectionPlan {
            if let dwellStartedAt =
                    openScenarioAutomaticInjectionDisplayTimestamp {
                if displayLink.timestamp - dwellStartedAt >= 1.5 {
                    openScenarioAutomaticInjectionPlan = nil
                    openScenarioAutomaticInjectionDisplayTimestamp = nil
                    captureOpenScenarioSkeletonPresentationBaselineIfNeeded()
                    guard openScenarioRemoteActionLatch.acknowledge(plan: plan)
                    else {
                        publishOpenScenarioFailure(plan: plan)
                        return
                    }
                    performOpenScenarioAcknowledgedRemoteActionIfReady()
                }
            } else {
                openScenarioAutomaticInjectionDisplayTimestamp =
                    displayLink.timestamp
            }
        }
        finishOpenScenarioActiveDwellIfReady(displayLink: displayLink)
        if let plan = openScenarioTerminalObservationPlan,
           let observationGeneration =
                openScenarioTerminalObservationGeneration {
            observeOpenScenarioTerminal(
                plan: plan,
                observationGeneration: observationGeneration
            )
        }
        advanceOpenScenarioVideoMarker(on: displayLink)
    }

    private func observeOpenScenarioTerminal(
        plan: ChatOpenRealPipelineFixturePlan,
        observationGeneration: Int
    ) {
        guard openScenarioStableReceipt == nil,
              openScenarioTerminalPublicationGate.isCurrentObservation(
                observationGeneration
              ) else {
            return
        }
        let evaluation = captureOpenScenarioTerminalEvaluation(plan: plan)
        if let stabilityReceipt =
                openScenarioTerminalStabilityGate.stableReceiptIfReady(
                    evidence: evaluation.evidence,
                    hasExpectedTerminal: evaluation.hasExpectedTerminal,
                    now: CACurrentMediaTime()
                ) {
            openScenarioTerminalStabilityReceipt = stabilityReceipt
            if beginOpenScenarioStableVideoTail(
                plan: plan,
                observationGeneration: observationGeneration,
                evidence: stabilityReceipt.evidence
            ) {
                return
            }
        }

        guard (openScenarioObservationDeadline ?? .distantPast) > Date() else {
            if openScenarioStableFrameSealDiagnostics.failureCode != .none {
                openScenarioVideoEvidenceFailureCode = .stableFrameRejected
                openScenarioSetupFailure = String(
                    describing: OpenScenarioError.stableFrameTraceRejected
                )
            }
            publishOpenScenarioFailure(
                plan: plan,
                observationGeneration: observationGeneration
            )
            return
        }
    }

    private func captureOpenScenarioTerminalEvaluation(
        plan: ChatOpenRealPipelineFixturePlan
    ) -> (
        evidence: ChatOpenRealPipelineFixtureTerminalEvidenceSnapshot,
        hasExpectedTerminal: Bool
    ) {
        let realRows = datasource.lazy.filter { !$0.isFakeMessage }.count
        if plan.expectsLinkedPagingTrace {
            openScenarioPagingAnchorErrorMilliPoints =
                currentOpenScenarioPagingAnchorErrorMilliPoints()
        }
        let skeletonRows = openScenarioSkeletonRowCount
        let committedDiagnostics =
            openScenarioCommittedInitialFrameDiagnostics
        let transportThreadSnapshot =
            openScenarioTransportThreadRecorder.snapshot
        let lifetimeRouteDiagnostics =
            timelineSession?.routeStoreDiagnosticsSnapshot
        let terminalRouteDiagnostics =
            lifetimeRouteDiagnostics?.routeDelta(
                since: openScenarioRouteStoreDiagnosticsBaseline
            )
        let hasExpectedHeldSkeletonStability =
            plan.scenario != .bootstrapStaleLocalToContent ||
            (openScenarioHeldSkeletonDisplayTickCount > 0 &&
             openScenarioSkeletonIdentityStable &&
             openScenarioSkeletonGeometryStable)
        let hasExpectedBootstrapPersistenceProof =
            plan.scenario != .bootstrapStaleLocalToContent ||
            (committedDiagnostics?.bootstrapRequestCount == 1 &&
             committedDiagnostics?.bootstrapFinalCount == 1 &&
             committedDiagnostics?.bootstrapDeliveredMessageCount == 80 &&
             transportThreadSnapshot.archiveEnvelopeCount == 80 &&
             transportThreadSnapshot.messageIngressCount == 80 &&
             committedDiagnostics?.bootstrapPersistedMessageCount == 80 &&
             committedDiagnostics?.finalNewerLiveEdgeReached == true &&
             committedDiagnostics?.finalOlderArchiveEndReached == false &&
             committedDiagnostics?.finalFullArchiveLoaded == false)
        let hasExpectedE04StoreBounds =
            plan.scenario != .bootstrapStaleLocalToContent ||
            (openScenarioRouteStoreDiagnosticsBaseline.queryCount == 0 &&
             lifetimeRouteDiagnostics?.queryCount == 4 &&
             terminalRouteDiagnostics?.queryCount == 4 &&
             terminalRouteDiagnostics?.operationCounts ==
                ["latestWindow": 2, "unread": 2] &&
             terminalRouteDiagnostics?.mainThreadQueryCount == 0 &&
             terminalRouteDiagnostics?.fullScanCount == 0 &&
             (terminalRouteDiagnostics?.maxCandidateCount ?? Int.max) <= 80 &&
             terminalRouteDiagnostics?.observation.activationCount == 1 &&
             (terminalRouteDiagnostics?.observation.realmQueryCount ?? 0) >= 1 &&
             (terminalRouteDiagnostics?.observation.realmQueryCount ?? Int.max) <= 2 &&
             terminalRouteDiagnostics?.observation
                .mainThreadRealmQueryCount == 0 &&
             terminalRouteDiagnostics?.observation.initialCallbackCount ==
                terminalRouteDiagnostics?.observation.realmQueryCount &&
             terminalRouteDiagnostics?.observation
                .mainThreadInitialCallbackCount == 0 &&
             (terminalRouteDiagnostics?.observation
                .maxInitialCandidateCount ?? Int.max) <= 80 &&
             terminalRouteDiagnostics?.observation.metadataQueryCount == 0 &&
             terminalRouteDiagnostics?.observation
                .mainThreadMetadataQueryCount == 0 &&
             terminalRouteDiagnostics?.observation
                .metadataFullScanCount == 0 &&
             terminalRouteDiagnostics?.observation.catchUpMutationCount == 0 &&
             terminalRouteDiagnostics?.observation.pendingWorkCount == 0)
        let hasExpectedRequestProvenance =
            plan.expectsSkeletonTerminal ||
            (committedDiagnostics?.requestSource == plan.expectedRequestSource &&
             committedDiagnostics?.requestHighlight ==
                (plan.expectedRequestHighlight ?? false) &&
             committedDiagnostics?.requestMarkReadOnVisible ==
                plan.expectedRequestMarkReadOnVisible)
        let hasExpectedVisualTerminal: Bool
        if plan.expectsSkeletonTerminal {
            compareOpenScenarioSkeletonWithBaseline()
            hasExpectedVisualTerminal = realRows == 0 &&
                skeletonRows == plan.expectedFinalSkeletonRowCount &&
                initialFirstContentApplyCount == 0 &&
                openScenarioProductionVisualCommitCount == 0 &&
                openScenarioUnexpectedCommittedFrameCount == 0 &&
                openScenarioSkeletonIdentityStable &&
                openScenarioSkeletonGeometryStable &&
                (appliedBootstrapLoadingState?.showsRetry == true) ==
                    plan.expectsRetry &&
                (plan.scenario != .bootstrapHeldOverWatchdog ||
                    openScenarioSkeletonDwellMilliseconds >= 5_000)
        } else if plan.expectsConfirmedEmpty {
            hasExpectedVisualTerminal = datasource.isEmpty &&
                skeletonRows == 0 &&
                appliedBootstrapLoadingState?.viewState == .empty &&
                initialFirstContentApplyCount == 1 &&
                openScenarioProductionVisualCommitCount == 1 &&
                openScenarioUnexpectedCommittedFrameCount == 0
        } else {
            hasExpectedVisualTerminal =
                realRows == plan.expectedFinalRealRowCount &&
                skeletonRows == 0 &&
                initialFirstContentApplyCount == 1 &&
                hasCommittedRealContentInCurrentLifecycle &&
                openScenarioProductionVisualCommitCount == 1 &&
                openScenarioUnexpectedCommittedFrameCount == 0 &&
                hasExpectedHeldSkeletonStability &&
                hasExpectedBootstrapPersistenceProof &&
                hasExpectedE04StoreBounds
        }
        let operationSnapshot = scrollFrameOperationCounter.snapshot()
        let bootstrapDiagnostics =
            captureOpenScenarioProductionBootstrapDiagnostics()
        let archiveRequestCount = max(
            max(
                openScenarioArchiveRequestCount,
                openScenarioObservedProductionArchiveQueryIds.count
            ),
            bootstrapDiagnostics.transportStartCount
        )
        let gapRequestCount = max(
            openScenarioGapRequestCount,
            openScenarioObservedProductionGapQueryIds.count
        )
        let activeProductionWorkCount =
            captureOpenScenarioActiveProductionWorkCount(
                bootstrapDiagnostics: bootstrapDiagnostics
            )
        let p14MentionDiagnostics = captureP14MentionDiagnostics()
        let evidence = ChatOpenRealPipelineFixtureTerminalEvidenceSnapshot(
            // Mapping-job generations may advance for work that is cancelled
            // or reduced model-only. Terminal visual stability is owned by the
            // datasource generation that was actually published on main.
            datasourceGeneration: Int(scrollResidentMetadata.generation),
            datasourceApplyCount: operationSnapshot[.datasourceApplies],
            firstContentApplyCount: initialFirstContentApplyCount,
            visualCommitCount: openScenarioProductionVisualCommitCount,
            stalePreTerminalRealFrameCount:
                openScenarioStalePreTerminalRealFrameCount,
            mixedSkeletonAndRealFrameCount:
                openScenarioMixedSkeletonAndRealFrameCount,
            offsetMutationCount:
                openScenarioOffsetMutationEvidence.observableMutationCount,
            postCommitOffsetMutationCount:
                openScenarioOffsetMutationEvidence.postCommitMutationCount,
            correctionCount:
                openScenarioViewportDiagnostics?.nextRunLoopCorrectionCount ?? 0,
            archiveRequestCount: archiveRequestCount,
            gapRequestCount: gapRequestCount,
            retryVisible: appliedBootstrapLoadingState?.showsRetry == true &&
                !bootstrapFailureView.isHidden,
            skeletonIdentityStable: openScenarioSkeletonIdentityStable,
            skeletonGeometryStable: openScenarioSkeletonGeometryStable,
            skeletonDwellMilliseconds: openScenarioSkeletonDwellMilliseconds,
            postInitialInteractionCount:
                openScenarioPostInitialInteractionCount,
            pagingAnchorErrorMilliPoints:
                openScenarioPagingAnchorErrorMilliPoints,
            rotationTransitionCount: openScenarioRotationTransitionCount,
            applicationBackgroundCount:
                openScenarioApplicationBackgroundCount,
            applicationForegroundCount:
                openScenarioApplicationForegroundCount,
            productionBootstrapLeaseEventCount:
                bootstrapDiagnostics.leaseEventCount,
            productionBootstrapTransportCount:
                bootstrapDiagnostics.transportStartCount,
            fixtureRealmQueryCountAfterRouteAdmission:
                openScenarioFixtureRealmQueryCountAfterRouteAdmission,
            activeProductionWorkCount: activeProductionWorkCount,
            transportThreadSnapshot: transportThreadSnapshot,
            routeHost: openScenarioRouteHostDiagnostics,
            p14Mention: p14MentionDiagnostics
        )
        let hasMeasurementPurity =
            ChatOpenRealPipelineFixtureDiagnosticsPolicy.isMeasurementPure(
                fixtureRealmQueryCountAfterRouteAdmission:
                    openScenarioFixtureRealmQueryCountAfterRouteAdmission
            )
        let hasExpectedTransportThreadShape =
            expectedOpenScenarioTransportThreadShape(
                plan: plan,
                snapshot: transportThreadSnapshot
            )
        let hasExpectedPostInitialInteraction: Bool
        switch plan.scenario {
        case .lastChatsAnimatedPush:
            hasExpectedPostInitialInteraction =
                openScenarioPostInitialInteractionCount == 1
        case .olderCrossingGap, .newerCrossingGap:
            hasExpectedPostInitialInteraction =
                openScenarioPostInitialInteractionCount == 1 &&
                openScenarioPagingAnchorErrorMilliPoints.map {
                    $0 <= 1_000
                } == true
        case .rotationRealPipeline:
            hasExpectedPostInitialInteraction =
                openScenarioPostInitialInteractionCount == 1 &&
                openScenarioRotationTransitionCount == 2
        case .committedContentBackgroundForeground:
            hasExpectedPostInitialInteraction =
                openScenarioPostInitialInteractionCount == 1 &&
                openScenarioApplicationBackgroundCount == 1 &&
                openScenarioApplicationForegroundCount == 1
        default:
            hasExpectedPostInitialInteraction =
                openScenarioPostInitialInteractionCount == 0
        }
        let hasExpectedRouteHost =
            openScenarioRouteHostDiagnostics.isAccepted(for: plan.scenario)
        let hasExpectedP14MentionLifecycle =
            plan.scenario != .lastChatsSeededMentionExact ||
            p14MentionDiagnostics.isAccepted
        return (
            evidence,
            hasExpectedVisualTerminal &&
                operationSnapshot[.datasourceApplies] ==
                    plan.expectedDatasourceApplyCount &&
                openScenarioStalePreTerminalRealFrameCount == 0 &&
                openScenarioMixedSkeletonAndRealFrameCount == 0 &&
                hasMeasurementPurity &&
                hasExpectedRequestProvenance &&
                hasExpectedTransportThreadShape &&
                hasExpectedPostInitialInteraction &&
                hasExpectedRouteHost &&
                hasExpectedP14MentionLifecycle
        )
    }

    private func expectedOpenScenarioTransportThreadShape(
        plan: ChatOpenRealPipelineFixturePlan,
        snapshot: ChatOpenRealPipelineFixtureTransportThreadSnapshot
    ) -> Bool {
        guard snapshot.hasValidThreadShape else { return false }
        if plan.expectsLinkedPagingTrace {
            let expectedMessageCount =
                plan.interactiveGapInjectionOrdinalRange?.count ?? -1
            let expectedTransportStartCount =
                plan.scenario == .newerCrossingGap ? 2 : 1
            let expectedMinimumFinalCount =
                plan.scenario == .newerCrossingGap ? 6 : 2
            let expectedMinimumBookkeepingCount =
                plan.scenario == .newerCrossingGap ? 2 : 1
            return snapshot.mamStartCount == expectedTransportStartCount &&
                snapshot.archiveEnvelopeCount == expectedMessageCount &&
                snapshot.messageIngressCount == expectedMessageCount &&
                snapshot.finalParserCount >= expectedMinimumFinalCount &&
                snapshot.uiBookkeepingCount >= expectedMinimumBookkeepingCount &&
                snapshot.uiReceiptCount == 0
        }
        if plan.requiresRemoteInjection {
            let expectedMessageCount = plan.remoteInjectionOrdinalRange?.count ?? -1
            if plan.scenario == .bootstrapHeldOverWatchdog {
                return snapshot.mamStartCount >= 1 &&
                    snapshot.archiveEnvelopeCount == 0 &&
                    snapshot.messageIngressCount == 0 &&
                    snapshot.finalParserCount == 0 &&
                    snapshot.uiBookkeepingCount >= 1 &&
                    snapshot.uiReceiptCount == 0
            }
            if plan.scenario == .bootstrapTerminalFailureRetry {
                return snapshot.mamStartCount >= 1 &&
                    snapshot.archiveEnvelopeCount == 0 &&
                    snapshot.messageIngressCount == 0 &&
                    snapshot.finalParserCount >= 2 &&
                    snapshot.uiBookkeepingCount >= 1 &&
                    snapshot.uiReceiptCount == 0
            }
            return snapshot.mamStartCount >= 1 &&
                snapshot.archiveEnvelopeCount == expectedMessageCount &&
                snapshot.messageIngressCount == expectedMessageCount &&
                snapshot.finalParserCount >= 2 &&
                snapshot.uiBookkeepingCount >= 1 &&
                snapshot.uiReceiptCount == 0
        }
        return snapshot.mamStartCount == 0 &&
            snapshot.archiveEnvelopeCount == 0 &&
            snapshot.messageIngressCount == 0 &&
            snapshot.finalParserCount == 0 &&
            snapshot.uiBookkeepingCount == 0 &&
            snapshot.uiReceiptCount == 0
    }

    @discardableResult
    private func beginOpenScenarioStableVideoTail(
        plan: ChatOpenRealPipelineFixturePlan,
        observationGeneration: Int,
        evidence: ChatOpenRealPipelineFixtureTerminalEvidenceSnapshot
    ) -> Bool {
        guard openScenarioStableReceipt == nil,
              openScenarioPendingStablePlan == nil else {
            return true
        }
        switch sealOpenScenarioStableFrameForArtifactExport(
            requiredReceipt: plan.stableFramePresentationReceipt
        ) {
        case .sealed(let diagnostics):
            openScenarioStableFrameSealDiagnostics = diagnostics
        case .retry(let diagnostics):
            openScenarioStableFrameSealDiagnostics = diagnostics
            return false
        case .rejected(let diagnostics):
            openScenarioStableFrameSealDiagnostics = diagnostics
            openScenarioVideoEvidenceFailureCode = .stableFrameRejected
            openScenarioSetupFailure = String(
                describing: OpenScenarioError.stableFrameTraceRejected
            )
            publishOpenScenarioFailure(
                plan: plan,
                observationGeneration: observationGeneration
            )
            return true
        }
        guard openScenarioTerminalPublicationGate.beginStableTail(
            observationGeneration: observationGeneration
        ) else {
            return false
        }
        openScenarioPendingStablePlan = plan
        openScenarioPendingStableObservationGeneration = observationGeneration
        openScenarioFrozenTerminalEvidence = evidence
        openScenarioTerminalObservationPlan = nil
        openScenarioTerminalObservationGeneration = nil
        return true
    }

    private func sealOpenScenarioStableFrameForArtifactExport(
        requiredReceipt: ChatOpenPerformancePresentationReceipt
    ) -> ChatOpenPerformanceStableFrameSealResult {
        guard openScenarioArtifactExportSession != nil else {
            return .sealed(.notAttempted)
        }
        guard let boundContext = openScenarioBoundPrimaryTraceContext else {
            return .rejected(ChatOpenPerformanceStableFrameSealDiagnostics(
                failureCode: .boundPrimaryContextUnavailable,
                attempted: true,
                boundPrimaryContextAvailable: false,
                currentPrimaryContextAvailable:
                    chatOpenPerformanceTraceContext != nil,
                primaryContextMatches: false,
                lifecycleContextMatches: false,
                semanticTargetAvailable:
                    chatOpenPerformanceTraceTargetFingerprint != nil,
                requiredPresentationReceiptRecorded: false,
                stableFrameScheduled: false,
                stableFrameAlreadyEmitted: false,
                stableFrameConsumed: false
            ))
        }
        guard let currentContext = chatOpenPerformanceTraceContext else {
            return .rejected(ChatOpenPerformanceStableFrameSealDiagnostics(
                failureCode: .currentPrimaryContextUnavailable,
                attempted: true,
                boundPrimaryContextAvailable: true,
                currentPrimaryContextAvailable: false,
                primaryContextMatches: false,
                lifecycleContextMatches: false,
                semanticTargetAvailable:
                    chatOpenPerformanceTraceTargetFingerprint != nil,
                requiredPresentationReceiptRecorded: false,
                stableFrameScheduled: false,
                stableFrameAlreadyEmitted: false,
                stableFrameConsumed: false
            ))
        }
        guard currentContext == boundContext else {
            return .rejected(ChatOpenPerformanceStableFrameSealDiagnostics(
                failureCode: .primaryContextMismatch,
                attempted: true,
                boundPrimaryContextAvailable: true,
                currentPrimaryContextAvailable: true,
                primaryContextMatches: false,
                lifecycleContextMatches: false,
                semanticTargetAvailable:
                    chatOpenPerformanceTraceTargetFingerprint != nil,
                requiredPresentationReceiptRecorded: false,
                stableFrameScheduled: false,
                stableFrameAlreadyEmitted: false,
                stableFrameConsumed: false
            ))
        }
        return sealChatOpenPerformanceStableFrameForArtifactExport(
            context: boundContext,
            requiredReceipt: requiredReceipt
        )
    }

    private func advanceOpenScenarioVideoMarker(on displayLink: CADisplayLink) {
        guard let generation = openScenarioVideoMarkerGeneration else { return }
        let hasStableTerminalEvidence = openScenarioPendingStablePlan != nil
        let terminalEvidenceIsFrozen: Bool
        if let plan = openScenarioPendingStablePlan,
           let frozenEvidence = openScenarioFrozenTerminalEvidence {
            let evaluation = captureOpenScenarioTerminalEvaluation(plan: plan)
            terminalEvidenceIsFrozen = evaluation.hasExpectedTerminal &&
                evaluation.evidence == frozenEvidence
        } else {
            terminalEvidenceIsFrozen = true
        }
        let boundaryTimestamp = displayLink.targetTimestamp > 0
            ? displayLink.targetTimestamp
            : displayLink.timestamp
        guard let action = openScenarioVideoMarkerGate.consumeDisplayTick(
            generation: generation,
            timestamp: boundaryTimestamp,
            hasStableTerminalEvidence: hasStableTerminalEvidence,
            terminalEvidenceIsFrozen: terminalEvidenceIsFrozen
        ) else {
            return
        }
        switch action {
        case .publish(let markerID, let visualCode):
            openScenarioVideoMarkerView.publish(visualCode)
            do {
                try openScenarioArtifactExportSession?.recordMarkerTransition(
                    markerID: markerID,
                    visualCode: visualCode,
                    uptimeNanoseconds: UInt64(
                        (boundaryTimestamp * 1_000_000_000).rounded()
                    )
                )
            } catch {
                openScenarioVideoEvidenceFailureCode = .markerRejected
                openScenarioSetupFailure = String(
                    describing: OpenScenarioError.videoMarkerPublicationRejected
                )
                if let plan = openScenarioPendingStablePlan ??
                    descriptor.openScenario.map({
                        ChatOpenRealPipelineFixturePlan(scenario: $0)
                    }) {
                    publishOpenScenarioFailure(plan: plan)
                }
            }
        case .evidenceInvalidated:
            openScenarioVideoEvidenceFailureCode =
                .terminalEvidenceInvalidated
            openScenarioSetupFailure = String(
                describing: OpenScenarioError
                    .terminalEvidenceMovedAfterStableFrame
            )
            if let plan = openScenarioPendingStablePlan ??
                descriptor.openScenario.map({
                    ChatOpenRealPipelineFixturePlan(scenario: $0)
                }) {
                publishOpenScenarioFailure(plan: plan)
            }
        case .complete:
            completeOpenScenarioStableReceiptAfterVideoTail()
        }
    }

    private func completeOpenScenarioStableReceiptAfterVideoTail() {
        guard let plan = openScenarioPendingStablePlan,
              let observationGeneration =
                openScenarioPendingStableObservationGeneration,
              let frozenEvidence = openScenarioFrozenTerminalEvidence,
              !openScenarioArtifactFinalizationInFlight else {
            return
        }
        let finalEvaluation = captureOpenScenarioTerminalEvaluation(plan: plan)
        guard finalEvaluation.hasExpectedTerminal,
              finalEvaluation.evidence == frozenEvidence else {
            openScenarioVideoEvidenceFailureCode =
                .terminalEvidenceInvalidated
            openScenarioSetupFailure = String(
                describing: OpenScenarioError
                    .terminalEvidenceMovedAfterStableFrame
            )
            publishOpenScenarioFailure(
                plan: plan,
                observationGeneration: observationGeneration
            )
            return
        }
        if openScenarioArtifactExportSession != nil {
            let expectedLinkedTraceCount = plan.expectsLinkedPagingTrace ? 1 : 0
            guard openScenarioBoundPrimaryTraceContext != nil,
                  openScenarioBoundLinkedTraceContexts.count ==
                    expectedLinkedTraceCount else {
                openScenarioSetupFailure = String(
                    describing: OpenScenarioError
                        .traceContextCardinalityRejected
                )
                publishOpenScenarioFailure(
                    plan: plan,
                    observationGeneration: observationGeneration
                )
                return
            }
        }
        guard openScenarioTerminalPublicationGate.commitTerminal(
            observationGeneration: observationGeneration
        ) else {
            return
        }
        if let generation = openScenarioArchiveTransportGeneration {
            openScenarioTransportThreadRecorder.record(
                .uiReceipt,
                generation: generation,
                isMainThread: Thread.isMainThread
            )
        }
        openScenarioDarwinAcknowledgementObserver?.invalidate()
        openScenarioDarwinAcknowledgementObserver = nil
        openScenarioStableReceiptGeneration += 1
        let receipt = makeOpenScenarioDiagnostics(
            plan: plan,
            phase: plan.stableTerminalPhase,
            isStable: true
        )
        let exportSession = openScenarioArtifactExportSession
        openScenarioArtifactFinalizationInFlight = true
        stopOpenScenarioVisibleOffsetSampling(capturingCurrentOffset: true)
        guard let exportSession else {
            finishOpenScenarioArtifactFinalization(
                receipt: receipt,
                plan: plan,
                artifactFailureCode: nil,
                artifactTraceFailure: .none
            )
            return
        }
        openScenarioArchiveTransportQueue.async { [weak self, exportSession] in
            let artifactFailureCode:
                ChatPerformanceArtifactExportFailureCode?
            let artifactTraceFailure:
                ChatPerformanceArtifactTraceContractFailureDiagnostics
            do {
                try exportSession.finalize()
                artifactFailureCode = nil
                artifactTraceFailure = .none
            } catch let error as ChatPerformanceArtifactExportError {
                artifactFailureCode = error.diagnosticFailureCode
                artifactTraceFailure =
                    exportSession.diagnosticTraceContractFailureDetails
            } catch {
                artifactFailureCode = .artifactWriteFailed
                artifactTraceFailure = .none
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishOpenScenarioArtifactFinalization(
                    receipt: receipt,
                    plan: plan,
                    artifactFailureCode: artifactFailureCode,
                    artifactTraceFailure: artifactTraceFailure
                )
            }
        }
    }

    private func finishOpenScenarioArtifactFinalization(
        receipt: ChatOpenRealPipelineFixtureDiagnostics,
        plan: ChatOpenRealPipelineFixturePlan,
        artifactFailureCode:
            ChatPerformanceArtifactExportFailureCode?,
        artifactTraceFailure:
            ChatPerformanceArtifactTraceContractFailureDiagnostics
    ) {
        guard !openScenarioTerminalTeardownCompleted,
              openScenarioArtifactFinalizationInFlight,
              openScenarioStableReceipt == nil else {
            return
        }
        openScenarioArtifactFinalizationInFlight = false
        let publishedReceipt: ChatOpenRealPipelineFixtureDiagnostics
        let succeeded = artifactFailureCode == nil
        let p13RouteEvidenceIsAccepted =
            plan.scenario != .mentionDeletedAdvance ||
            openScenarioRouteHostDiagnostics.isAccepted(for: plan.scenario)
        if succeeded && p13RouteEvidenceIsAccepted {
            publishedReceipt = receipt
        } else {
            if succeeded {
                openScenarioArtifactExportSession?
                    .revokeFinalizedEvidenceAcceptance()
                openScenarioSetupFailure = String(
                    describing: OpenScenarioError
                        .p13RouteEvidenceInvalidatedAfterStableReceipt
                )
            } else {
                openScenarioVideoEvidenceFailureCode =
                    .artifactFinalizationFailed
                openScenarioArtifactExportFailureCode =
                    artifactFailureCode ?? .artifactWriteFailed
                openScenarioArtifactTraceFailure = artifactTraceFailure
                openScenarioSetupFailure = String(
                    describing: OpenScenarioError.artifactExportUnavailable
                )
            }
            publishedReceipt = makeOpenScenarioDiagnostics(
                plan: plan,
                phase: .failed,
                isStable: false
            )
        }
        openScenarioStableReceipt = publishedReceipt
        openStateLabel.text = publishedReceipt.accessibilitySummary
        openStableLabel.text = publishedReceipt.accessibilitySummary
        print(
            "CHAT_OPEN_FIXTURE_RECEIPT \(publishedReceipt.accessibilitySummary)"
        )
        openScenarioDidStabilize?(publishedReceipt)
    }

    private func publishOpenScenarioFailure(
        plan: ChatOpenRealPipelineFixturePlan,
        observationGeneration: Int? = nil
    ) {
        guard !openScenarioTerminalTeardownCompleted,
              openScenarioStableReceipt == nil,
              openScenarioTerminalPublicationGate.commitTerminal(
                observationGeneration: observationGeneration
              ) else {
            return
        }
        if let generation = openScenarioArchiveTransportGeneration {
            openScenarioTransportThreadRecorder.record(
                .uiReceipt,
                generation: generation,
                isMainThread: Thread.isMainThread
            )
        }
        openScenarioDarwinAcknowledgementObserver?.invalidate()
        openScenarioDarwinAcknowledgementObserver = nil
        stopOpenScenarioVisibleOffsetSampling(capturingCurrentOffset: true)
        let receipt = makeOpenScenarioDiagnostics(
            plan: plan,
            phase: .failed,
            isStable: false
        )
        openScenarioStableReceipt = receipt
        openStateLabel.text = receipt.accessibilitySummary
        openStableLabel.text = receipt.accessibilitySummary
        print("CHAT_OPEN_FIXTURE_RECEIPT \(receipt.accessibilitySummary)")
        openScenarioDidStabilize?(receipt)
    }

    private func revokePublishedP13StableReceipt(
        plan: ChatOpenRealPipelineFixturePlan
    ) {
        guard plan.scenario == .mentionDeletedAdvance,
              let publishedReceipt = openScenarioStableReceipt,
              !openScenarioRouteHostDiagnostics.isAccepted(for: plan.scenario)
        else {
            return
        }
        let wasAccepted = publishedReceipt.isStable
        if wasAccepted {
            openScenarioArtifactExportSession?
                .revokeFinalizedEvidenceAcceptance()
            openScenarioSetupFailure = String(
                describing: OpenScenarioError
                    .p13RouteEvidenceInvalidatedAfterStableReceipt
            )
            openScenarioStableReceiptGeneration &+= 1
        }
        let revokedReceipt = makeOpenScenarioDiagnostics(
            plan: plan,
            phase: .failed,
            isStable: false
        )
        openScenarioStableReceipt = revokedReceipt
        openStateLabel.text = revokedReceipt.accessibilitySummary
        openStableLabel.text = revokedReceipt.accessibilitySummary
        guard wasAccepted else { return }
        print(
            "CHAT_OPEN_FIXTURE_RECEIPT \(revokedReceipt.accessibilitySummary)"
        )
        openScenarioDidStabilize?(revokedReceipt)
    }

    private func makeOpenScenarioDiagnostics(
        plan: ChatOpenRealPipelineFixturePlan,
        phase: ChatOpenRealPipelineFixturePhase,
        isStable: Bool
    ) -> ChatOpenRealPipelineFixtureDiagnostics {
        recordOpenScenarioProductionRemoteHistoryState()
        let operationSnapshot = scrollFrameOperationCounter.snapshot()
        let realRows = datasource.lazy.filter { !$0.isFakeMessage }.count
        let skeletonRows = openScenarioSkeletonRowCount
        let bottomDistanceMilliPoints: Int?
        if plan.targetKind == .latest && realRows > 0 {
            let distance = ChatTailAppendBottomPinPolicy.bottomDistance(
                contentHeight: messagesCollectionView.contentSize.height,
                viewportHeight: messagesCollectionView.bounds.height,
                contentInsets: messagesCollectionView.contentInset,
                contentOffsetY: messagesCollectionView.contentOffset.y
            )
            bottomDistanceMilliPoints = Int((distance * 1_000).rounded())
        } else {
            bottomDistanceMilliPoints = nil
        }
        let viewportDiagnostics = openScenarioViewportDiagnostics
        let committedDiagnostics = openScenarioCommittedInitialFrameDiagnostics
        // Sample the same route recorder at terminal publication as well as
        // at commit. A late target lookup, observer refresh or main-thread
        // provider call must invalidate the final proof instead of being
        // hidden behind an earlier good commit snapshot.
        let terminalRouteDiagnostics =
            timelineSession?.routeStoreDiagnosticsSnapshot
        let routeDiagnostics = terminalRouteDiagnostics?.routeDelta(
            since: openScenarioRouteStoreDiagnosticsBaseline
        )
        let bootstrapDiagnostics =
            captureOpenScenarioProductionBootstrapDiagnostics()
        let transportThreadSnapshot = openScenarioTransportThreadRecorder.snapshot
        let activeProductionWorkCount =
            captureOpenScenarioActiveProductionWorkCount(
                bootstrapDiagnostics: bootstrapDiagnostics
            )
        let terminalArchiveRequestCount = max(
            max(
                openScenarioArchiveRequestCount,
                openScenarioObservedProductionArchiveQueryIds.count
            ),
            bootstrapDiagnostics.transportStartCount
        )
        let terminalGapRequestCount = max(
            openScenarioGapRequestCount,
            openScenarioObservedProductionGapQueryIds.count
        )
        let initialArchiveRequestCount =
            openScenarioInitialFrameArchiveRequestCount ?? 0
        let initialGapRequestCount =
            openScenarioInitialFrameGapRequestCount ?? 0
        let capturedInitialRouteDiagnostics =
            openScenarioInitialFrameRouteStoreDiagnostics
        let causalInitialStoreOperationSummary =
            ChatOpenRealPipelineFixtureStoreOperationSummary(
                operationCounts:
                    capturedInitialRouteDiagnostics?.operationCounts ?? [:]
            )
        let initialStorePhasePartition:
            ChatOpenRealPipelineFixtureStoreOperationPhasePartition = {
            guard plan.usesRemoteAnchorInitialStorePhasePartition else {
                return ChatOpenRealPipelineFixtureStoreOperationPhasePartition(
                    visualInitial: causalInitialStoreOperationSummary,
                    blocking:
                        ChatOpenRealPipelineFixtureStoreOperationSummary(
                            operationCounts: [:]
                        )
                )
            }
            return causalInitialStoreOperationSummary
                .partitioningRemoteAnchorInitialFrame()
        }()
        let initialStoreOperationSummary =
            initialStorePhasePartition.visualInitial
        let blockingInitialStoreOperationSummary =
            initialStorePhasePartition.blocking
        // Initial metrics are route-local and frozen at the production visual
        // commit. `committedDiagnostics.storeQueryCount` is a session lifetime
        // value and therefore leaks a prewarmed controller's previous route.
        let initialStoreQueryCount = capturedInitialRouteDiagnostics == nil
            ? -1
            : initialStoreOperationSummary.totalCount
        let terminalStoreOperationSummary =
            ChatOpenRealPipelineFixtureStoreOperationSummary(
                operationCounts: routeDiagnostics?.operationCounts ?? [:]
            )
        let terminalStoreQueryCount =
            routeDiagnostics?.queryCount ?? initialStoreQueryCount
        let postInitialStoreOperationSummary =
            terminalStoreOperationSummary.subtracting(
                causalInitialStoreOperationSummary
            )
        return ChatOpenRealPipelineFixtureDiagnostics(
            scenario: plan.scenario,
            phase: phase,
            targetKind: plan.targetKind,
            initialSkeletonRowCount: openScenarioInitialSkeletonRowCount,
            currentSkeletonRowCount: skeletonRows,
            realRowCount: realRows,
            datasourceGeneration: Int(scrollResidentMetadata.generation),
            initialSkeletonDatasourceGeneration:
                openScenarioSkeletonPresentationBaseline?.datasourceGeneration,
            datasourceApplyCount: operationSnapshot[.datasourceApplies],
            firstContentApplyCount: initialFirstContentApplyCount,
            visualCommitCount: openScenarioProductionVisualCommitCount,
            previousOrBlankRealFrameCount:
                ChatOpenRealPipelineFixtureDiagnosticsPolicy.previousOrBlankFrameCount(
                    visualCommitCount: openScenarioProductionVisualCommitCount,
                    unexpectedCommittedFrameCount: openScenarioUnexpectedCommittedFrameCount,
                    intermediateEmptyFrameCount:
                        lastBootstrapAtomicRevealPlan?.intermediateEmptyFrameCount ?? 0,
                    isConfirmedEmptyTerminal: plan.expectsConfirmedEmpty
                ),
            stalePreTerminalRealFrameCount:
                openScenarioStalePreTerminalRealFrameCount,
            mixedSkeletonAndRealFrameCount:
                openScenarioMixedSkeletonAndRealFrameCount,
            rawOffsetMutationCount:
                openScenarioOffsetMutationEvidence.rawMutationCount,
            initialPositioningOffsetMutationCount:
                openScenarioOffsetMutationEvidence
                    .initialPositioningMutationCount,
            rotationOwnedOffsetMutationCount:
                openScenarioOffsetMutationEvidence.rotationOwnedMutationCount,
            offsetMutationCount:
                openScenarioOffsetMutationEvidence.observableMutationCount,
            postCommitOffsetMutationCount:
                openScenarioOffsetMutationEvidence.postCommitMutationCount,
            correctionCount: viewportDiagnostics?.nextRunLoopCorrectionCount ?? 0,
            bottomDistanceMilliPoints: bottomDistanceMilliPoints,
            anchorErrorMilliPoints: viewportDiagnostics?.anchorError.map {
                Int((abs($0) * 1_000).rounded())
            },
            requestSource: committedDiagnostics?.requestSource,
            requestHighlight: committedDiagnostics?.requestHighlight ?? false,
            requestMarkReadOnVisible:
                committedDiagnostics?.requestMarkReadOnVisible,
            resolvedTargetOrdinal: openScenarioResolvedTargetOrdinal,
            targetMatchCount: openScenarioTargetMatchCount,
            latestVisualCommitCount: openScenarioLatestVisualCommitCount,
            p14Mention: captureP14MentionDiagnostics(),
            heldSkeletonDisplayTickCount:
                openScenarioHeldSkeletonDisplayTickCount,
            archiveLeaseCount: bootstrapDiagnostics.leaseEventCount,
            initialFrameArchiveRequestCount: initialArchiveRequestCount,
            archiveRequestCount: terminalArchiveRequestCount,
            postInitialArchiveRequestCount: max(
                0,
                terminalArchiveRequestCount - initialArchiveRequestCount
            ),
            initialFrameGapRequestCount: initialGapRequestCount,
            gapRequestCount: terminalGapRequestCount,
            postInitialGapRequestCount: max(
                0,
                terminalGapRequestCount - initialGapRequestCount
            ),
            archiveCursorKind: openScenarioArchiveCursorKind,
            retryVisible: appliedBootstrapLoadingState?.showsRetry == true &&
                !bootstrapFailureView.isHidden,
            skeletonIdentityStable: openScenarioSkeletonIdentityStable,
            skeletonGeometryStable: openScenarioSkeletonGeometryStable,
            skeletonDwellMilliseconds: openScenarioSkeletonDwellMilliseconds,
            postInitialInteractionCount:
                openScenarioPostInitialInteractionCount,
            pagingAnchorErrorMilliPoints:
                openScenarioPagingAnchorErrorMilliPoints,
            rotationTransitionCount: openScenarioRotationTransitionCount,
            applicationBackgroundCount:
                openScenarioApplicationBackgroundCount,
            applicationForegroundCount:
                openScenarioApplicationForegroundCount,
            usesReusedTimelineSession:
                openScenarioUsesReusedTimelineSession,
            storeQueryBaselineCount:
                openScenarioRouteStoreDiagnosticsBaseline.queryCount,
            storeLifetimeQueryCount:
                terminalRouteDiagnostics?.queryCount ?? -1,
            initialFrameStoreQueryCount: initialStoreQueryCount,
            blockingInitialStoreQueryCount:
                capturedInitialRouteDiagnostics == nil
                    ? -1
                    : blockingInitialStoreOperationSummary.totalCount,
            storeQueryCount: terminalStoreQueryCount,
            postInitialStoreQueryCount:
                postInitialStoreOperationSummary.totalCount,
            initialFrameStoreOperationSummary:
                initialStoreOperationSummary,
            blockingInitialStoreOperationSummary:
                blockingInitialStoreOperationSummary,
            terminalRouteStoreOperationSummary:
                terminalStoreOperationSummary,
            postInitialStoreOperationSummary:
                postInitialStoreOperationSummary,
            mainThreadStoreQueryCount:
                routeDiagnostics?.mainThreadQueryCount ??
                committedDiagnostics?.mainThreadStoreQueryCount ?? -1,
            fullScanCount:
                routeDiagnostics?.fullScanCount ??
                committedDiagnostics?.fullScanCount ?? -1,
            maxCandidateCount:
                routeDiagnostics?.maxCandidateCount ??
                committedDiagnostics?.maxCandidateCount ?? -1,
            observerActivationCount:
                routeDiagnostics?.observation.activationCount ?? -1,
            observerRealmQueryCount:
                routeDiagnostics?.observation.realmQueryCount ?? -1,
            mainThreadObserverRealmQueryCount:
                routeDiagnostics?.observation.mainThreadRealmQueryCount ?? -1,
            observerInitialCallbackCount:
                routeDiagnostics?.observation.initialCallbackCount ?? -1,
            mainThreadObserverInitialCallbackCount:
                routeDiagnostics?.observation.mainThreadInitialCallbackCount ?? -1,
            observerMaxInitialCandidateCount:
                routeDiagnostics?.observation.maxInitialCandidateCount ?? -1,
            observerMetadataQueryCount:
                routeDiagnostics?.observation.metadataQueryCount ?? -1,
            mainThreadObserverMetadataQueryCount:
                routeDiagnostics?.observation.mainThreadMetadataQueryCount ?? -1,
            observerMetadataFullScanCount:
                routeDiagnostics?.observation.metadataFullScanCount ?? -1,
            observerMaxMetadataCandidateCount:
                routeDiagnostics?.observation.maxMetadataCandidateCount ?? -1,
            observerCatchUpMutationCount:
                routeDiagnostics?.observation.catchUpMutationCount ?? -1,
            observerPendingWorkCount:
                routeDiagnostics?.observation.pendingWorkCount ?? -1,
            preparedOnMainThread:
                committedDiagnostics?.preparedOnMainThread ?? true,
            mappedOnMainThread:
                committedDiagnostics?.mappedOnMainThread ?? true,
            realDatasourceApplyCount:
                committedDiagnostics?.realDatasourceApplyCount ?? 0,
            atomicLayoutCommitCount:
                committedDiagnostics?.atomicLayoutCommitCount ?? 0,
            committedRouteCount: openScenarioProductionVisualCommitCount,
            committedTargetKind: committedDiagnostics?.targetKind,
            productionBootstrapLeaseStartCount:
                bootstrapDiagnostics.leaseStartCount,
            productionBootstrapLeaseJoinCount:
                bootstrapDiagnostics.leaseJoinCount,
            productionBootstrapActiveLeaseCount:
                bootstrapDiagnostics.activeLeaseCount,
            productionBootstrapCompletedLeaseCount:
                bootstrapDiagnostics.completedLeaseCount,
            productionBootstrapFailedLeaseCount:
                bootstrapDiagnostics.failedLeaseCount,
            productionBootstrapCancelledLeaseCount:
                bootstrapDiagnostics.cancelledLeaseCount,
            productionBootstrapTransportStartCount:
                bootstrapDiagnostics.transportStartCount,
            bootstrapRequestCount:
                committedDiagnostics?.bootstrapRequestCount ?? 0,
            bootstrapFinalCount:
                committedDiagnostics?.bootstrapFinalCount ?? 0,
            bootstrapDeliveredMessageCount:
                committedDiagnostics?.bootstrapDeliveredMessageCount ?? 0,
            bootstrapPersistedMessageCount:
                committedDiagnostics?.bootstrapPersistedMessageCount ?? 0,
            finalNewerLiveEdgeReached:
                committedDiagnostics?.finalNewerLiveEdgeReached ?? false,
            finalOlderArchiveEndReached:
                committedDiagnostics?.finalOlderArchiveEndReached ?? false,
            finalFullArchiveLoaded:
                committedDiagnostics?.finalFullArchiveLoaded ?? false,
            fixtureRealmQueryCountAfterRouteAdmission:
                openScenarioFixtureRealmQueryCountAfterRouteAdmission,
            terminalQuietMilliseconds:
                openScenarioTerminalStabilityReceipt?.quietMilliseconds ?? 0,
            terminalProvisionalResetCount:
                openScenarioTerminalStabilityReceipt?.provisionalResetCount ?? 0,
            activeProductionWorkCount: activeProductionWorkCount,
            transportThreadSnapshot: transportThreadSnapshot,
            stableReceiptGeneration: openScenarioStableReceiptGeneration,
            isStable: isStable,
            videoEvidenceFailureCode:
                openScenarioVideoEvidenceFailureCode,
            stableFrameSealDiagnostics:
                openScenarioStableFrameSealDiagnostics,
            artifactExportFailureCode:
                openScenarioArtifactExportFailureCode,
            artifactTraceFailure: openScenarioArtifactTraceFailure,
            storage: openScenarioStorageDiagnostics,
            routeHost: openScenarioRouteHostDiagnostics
        )
    }

    private func renderOpenScenarioPhase(
        _ phase: ChatOpenRealPipelineFixturePhase,
        plan: ChatOpenRealPipelineFixturePlan
    ) {
        let skeletonRows = openScenarioSkeletonRowCount
        let realRows = datasource.lazy.filter { !$0.isFakeMessage }.count
        openStateLabel.text = ([
            "scenario=\(plan.scenario.rawValue)",
            "phase=\(phase.rawValue)",
            "target=\(plan.targetKind.rawValue)",
            "skeleton=\(skeletonRows)",
            "real=\(realRows)",
            "postReady=\(openScenarioPostInitialInteractionReady)",
            "postInteractions=\(openScenarioPostInitialInteractionCount)"
        ] + (plan.scenario == .rotationRealPipeline
            ? openScenarioRotationBarrierDiagnostics.accessibilityFields
            : []) + openScenarioStorageDiagnostics.accessibilityFields +
            openScenarioRouteHostDiagnostics.accessibilityFields)
            .joined(separator: " ")
        openStableLabel.text = "scenario=\(plan.scenario.rawValue) stable=false receipt=0"
    }

    private var openScenarioSkeletonRowCount: Int {
        datasource.lazy.filter { item in
            let hasSkeletonKind: Bool
            if case .skeleton = item.kind {
                hasSkeletonKind = true
            } else {
                hasSkeletonKind = false
            }
            return ChatOpenRealPipelineFixtureDiagnosticsPolicy.isSkeletonRow(
                isFakeMessage: item.isFakeMessage,
                hasSkeletonKind: hasSkeletonKind
            )
        }.count
    }

    private func captureOpenScenarioSkeletonPresentationSnapshot()
        -> OpenScenarioSkeletonPresentationSnapshot? {
        let skeletonSections = datasource.indices.filter { section in
            let item = datasource[section]
            guard item.isFakeMessage else { return false }
            if case .skeleton = item.kind { return true }
            return false
        }
        guard skeletonSections.count == 30 else { return nil }
        let layout = messagesCollectionView.collectionViewLayout
        let rowHeightMilliPoints = skeletonSections.map { section in
            let indexPath = IndexPath(item: 0, section: section)
            let height = layout.layoutAttributesForItem(at: indexPath)?.frame.height
                ?? messagesCollectionView.cellForItem(at: indexPath)?.frame.height
                ?? -1
            return Int((height * 1_000).rounded())
        }
        return OpenScenarioSkeletonPresentationSnapshot(
            rowPrimaryOrder: skeletonSections.map { datasource[$0].primary },
            rowHeightMilliPoints: rowHeightMilliPoints,
            // `datasetMappingGeneration` is a work-cancellation epoch and may
            // advance without touching the visible skeleton. Use the resident
            // datasource epoch so identity changes only on publication.
            datasourceGeneration: Int(scrollResidentMetadata.generation),
            contentHeightMilliPoints: Int(
                (messagesCollectionView.contentSize.height * 1_000).rounded()
            ),
            contentOffsetMilliPoints: Int(
                (messagesCollectionView.contentOffset.y * 1_000).rounded()
            )
        )
    }

    private func captureOpenScenarioSkeletonPresentationBaselineIfNeeded() {
        guard openScenarioSkeletonPresentationBaseline == nil else { return }
        openScenarioSkeletonPresentationBaseline =
            captureOpenScenarioSkeletonPresentationSnapshot()
        if openScenarioSkeletonPresentationBaseline == nil {
            openScenarioSkeletonIdentityStable = false
            openScenarioSkeletonGeometryStable = false
        }
    }

    private func compareOpenScenarioSkeletonWithBaseline() {
        guard let baseline = openScenarioSkeletonPresentationBaseline,
              let current = captureOpenScenarioSkeletonPresentationSnapshot() else {
            openScenarioSkeletonIdentityStable = false
            openScenarioSkeletonGeometryStable = false
            return
        }
        openScenarioSkeletonIdentityStable =
            openScenarioSkeletonIdentityStable &&
            baseline.hasStableIdentity(comparedWith: current)
        openScenarioSkeletonGeometryStable =
            openScenarioSkeletonGeometryStable &&
            baseline.hasStableGeometry(comparedWith: current)
    }

    private func beginOpenScenarioActiveDwell(
        plan: ChatOpenRealPipelineFixturePlan
    ) {
        guard plan.scenario == .bootstrapHeldOverWatchdog,
              openScenarioActiveDwellPlan == nil else {
            rejectOpenScenarioArchiveDescriptor(plan: plan)
            return
        }
        captureOpenScenarioSkeletonPresentationBaselineIfNeeded()
        openScenarioActiveDwellPlan = plan
        openScenarioActiveDwellStartedAt = CACurrentMediaTime()
        renderOpenScenarioPhase(.skeleton, plan: plan)
    }

    private func finishOpenScenarioActiveDwellIfReady(
        displayLink: CADisplayLink
    ) {
        guard let plan = openScenarioActiveDwellPlan,
              let startedAt = openScenarioActiveDwellStartedAt else {
            return
        }
        compareOpenScenarioSkeletonWithBaseline()
        let timestamp = displayLink.targetTimestamp > 0
            ? displayLink.targetTimestamp
            : displayLink.timestamp
        let elapsedNanoseconds = UInt64(
            max(0, timestamp - startedAt) * 1_000_000_000
        )
        guard elapsedNanoseconds >=
                ChatPerformanceArtifactExportSession
                    .minimumActiveDwellNanoseconds else {
            return
        }
        openScenarioActiveDwellPlan = nil
        openScenarioActiveDwellStartedAt = nil
        openScenarioSkeletonDwellMilliseconds = Int(
            elapsedNanoseconds / 1_000_000
        )
        let leaseKey = initialBootstrapLeaseKey ?? initialBootstrapRequestKey
        ChatInitialBootstrapRequestCoordinator.shared.discardConfirmedAttempt(
            key: leaseKey
        )
        resetInitialBootstrapTracking(
            acknowledgeConsumedCommittedReceipt: false
        )
        compareOpenScenarioSkeletonWithBaseline()
        beginOpenScenarioTerminalObservation(plan: plan)
    }

    private func injectOpenScenarioTypedFailure(
        plan: ChatOpenRealPipelineFixturePlan
    ) {
        guard plan.scenario == .bootstrapTerminalFailureRetry,
              let session = openScenarioArchiveTransportSession,
              let queryId = openScenarioQueryId,
              let descriptor = openScenarioArchiveDescriptor(for: queryId),
              descriptor.semanticRouteClass == .latest,
              let transportGeneration = openScenarioArchiveTransportGeneration else {
            rejectOpenScenarioArchiveDescriptor(plan: plan)
            return
        }
        captureOpenScenarioSkeletonPresentationBaselineIfNeeded()
        enqueueOpenScenarioArchiveTransport(
            generation: transportGeneration,
            plan: plan,
            operation: { [weak self] in
                guard let self else {
                    throw OpenScenarioError.archiveTransportUnavailable
                }
                let failureIQ = try self.makeOpenScenarioArchiveFailureIQ(
                    queryId: queryId
                )
                self.openScenarioTransportThreadRecorder.record(
                    .finalParser,
                    generation: transportGeneration,
                    isMainThread: Thread.isMainThread
                )
                guard session.archiveManager.read(
                    session.stream,
                    withIQ: failureIQ
                ) else {
                    throw OpenScenarioError.archiveDescriptorRejected
                }
                self.openScenarioTransportThreadRecorder.record(
                    .finalParser,
                    generation: transportGeneration,
                    isMainThread: Thread.isMainThread
                )
                _ = session.archiveManager.read(
                    session.stream,
                    withIQ: failureIQ
                )
            },
            mainCompletion: { [weak self] in
                self?.compareOpenScenarioSkeletonWithBaseline()
                self?.beginOpenScenarioTerminalObservation(plan: plan)
            }
        )
    }

    private func makeOpenScenarioRequest(
        targetOrdinal: Int,
        source: ChatOpenMessageRequestSource,
        highlight: Bool,
        markReadOnVisible: Bool
    ) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary:
                    descriptor.openScenario == .searchExactRemote &&
                    source == .search
                    ? nil
                    : openPrimary(targetOrdinal),
                archivedId: openArchiveId(targetOrdinal),
                messageId:
                    descriptor.openScenario == .searchExactRemote &&
                    source == .search
                    ? nil
                    : openMessageId(targetOrdinal),
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: openDate(targetOrdinal)
            ),
            highlight: highlight,
            markReadOnVisible: markReadOnVisible,
            source: source
        )
    }

    private func makeOpenScenarioMessage(ordinal: Int) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.primary = openPrimary(ordinal)
        item.owner = owner
        item.opponent = jid
        item.conversationType = conversationType
        item.archivedId = openArchiveId(ordinal)
        item.messageId = openMessageId(ordinal)
        item.date = openDate(ordinal)
        item.sentDate = item.date
        item.body = "deterministic chat-open fixture row \(ordinal)"
        if descriptor.openScenario == .mentionDeletedAdvance {
            let plan = ChatOpenRealPipelineFixturePlan(
                scenario: .mentionDeletedAdvance
            )
            let isMention = ordinal == plan.p13DeletedMentionOrdinal ||
                ordinal == plan.p13NextValidMentionOrdinal
            item.outgoing = !isMention
            item.isRead = !isMention
            // Account materialization performs the production startup mention
            // reconciliation before the Notifications row is visible. Keep
            // both P13 targets valid through that boundary; the source host
            // makes ordinal 120 deleted only after the real row materializes
            // and immediately before it enables the inherited tap path.
            item.isDeleted = false
            item.state = item.outgoing ? .read : .deliver
            if isMention {
                let author = MessageReferenceStorageItem()
                author.primary = "chat-open-p13-author-\(ordinal)"
                author.owner = owner
                author.messageId = item.messageId
                author.kind = .groupchat
                author.metadata = [
                    "id": "p13-other-member",
                    "nickname": "Fixture member"
                ]
                item.references.append(author)

                let mention = MessageReferenceStorageItem()
                mention.primary = "chat-open-p13-mention-\(ordinal)"
                mention.owner = owner
                mention.messageId = item.messageId
                mention.kind = .mention
                mention.metadata = [
                    "uri": "xmpp:\(jid)?members;id=\(p13CurrentMemberId)",
                    "memberId": p13CurrentMemberId,
                    "groupchatJid": jid,
                    "nickname": "@fixture-member"
                ]
                item.references.append(mention)
            }
        } else if descriptor.openScenario == .lastChatsSeededMentionExact {
            item.outgoing = ordinal != 120 && ordinal != 160
            item.isRead = item.outgoing
            item.state = item.outgoing ? .read : .deliver
            let plan = ChatOpenRealPipelineFixturePlan(
                scenario: .lastChatsSeededMentionExact
            )
            if ordinal == plan.p14ExplicitMentionOrdinal {
                // Account construction runs production startup mention
                // reconciliation before Last Chats exposes this row. Seed the
                // exact references a real incoming group mention persists so
                // that reconciliation validates, rather than repairs, the
                // deterministic notification lifecycle.
                let author = MessageReferenceStorageItem()
                author.primary = "chat-open-p14-author-\(ordinal)"
                author.owner = owner
                author.messageId = item.messageId
                author.kind = .groupchat
                author.metadata = [
                    "id": p14OtherMemberId,
                    "nickname": "Fixture member"
                ]
                item.references.append(author)

                let mention = MessageReferenceStorageItem()
                mention.primary = "chat-open-p14-mention-\(ordinal)"
                mention.owner = owner
                mention.messageId = item.messageId
                mention.kind = .mention
                mention.metadata = [
                    "uri": "xmpp:\(jid)?members;id=\(p14CurrentMemberId)",
                    "memberId": p14CurrentMemberId,
                    "groupchatJid": jid,
                    "nickname": "@fixture-member"
                ]
                item.references.append(mention)
            }
        } else if descriptor.openScenario == .unreadBoundaryLocal,
           let boundaryOrdinal = ChatOpenRealPipelineFixturePlan(
               scenario: .unreadBoundaryLocal
           ).unreadBoundaryOrdinal,
           ordinal > boundaryOrdinal {
            item.outgoing = ordinal < 160 || ordinal.isMultiple(of: 3)
            item.isRead = item.outgoing
            item.state = item.outgoing ? .read : .deliver
        } else {
            item.outgoing = ordinal.isMultiple(of: 3)
            item.isRead = true
            item.state = .read
        }
        return item
    }

    private func openPrimary(_ ordinal: Int) -> String {
        MessageStorageItem.genPrimary(
            messageId: openMessageId(ordinal),
            owner: owner
        )
    }

    internal func openScenarioPrimary(_ ordinal: Int) -> String {
        openPrimary(ordinal)
    }

    private func openScenarioOrdinal(forArchiveID archiveID: String) -> Int? {
        (0..<320).first { openArchiveId($0) == archiveID }
    }

    private func openMessageId(_ ordinal: Int) -> String {
        "chat-open-fixture-message-\(descriptor.openScenario?.rawValue ?? "general")-\(ordinal)"
    }

    internal func openScenarioMessageId(_ ordinal: Int) -> String {
        openMessageId(ordinal)
    }

    private func openArchiveId(_ ordinal: Int) -> String {
        let secondsSinceUnixEpoch = 1_700_000_000 + Int64(ordinal * 60)
        return String(secondsSinceUnixEpoch * 1_000_000)
    }

    internal func openScenarioArchiveId(_ ordinal: Int) -> String {
        openArchiveId(ordinal)
    }

    private var p14MentionNotificationUniqueId: String {
        "chat-open-p14-persisted-mention"
    }

    private var p14CurrentMemberId: String {
        "p14-current-member"
    }

    private var p14OtherMemberId: String {
        "p14-other-member"
    }

    internal var p14MentionNotificationPrimaryForTesting: String {
        NotificationStorageItem.genPrimary(
            owner: owner,
            jid: jid,
            uniqueId: p14MentionNotificationUniqueId
        )
    }

    private var p13CurrentMemberId: String {
        "p13-current-member"
    }

    private var p13DeletedMentionNotificationUniqueId: String {
        "chat-open-p13-deleted-mention"
    }

    private var p13NextMentionNotificationUniqueId: String {
        "chat-open-p13-next-mention"
    }

    private var p13UnrelatedMentionNotificationUniqueId: String {
        "chat-open-p13-unrelated-mention"
    }

    internal var p13UnrelatedGroupJidForTesting: String {
        "chat-open-p13-unrelated-group@invalid"
    }

    internal var p13DeletedMentionNotificationPrimaryForTesting: String {
        NotificationStorageItem.genPrimary(
            owner: owner,
            jid: jid,
            uniqueId: p13DeletedMentionNotificationUniqueId
        )
    }

    internal var p13NextMentionNotificationPrimaryForTesting: String {
        NotificationStorageItem.genPrimary(
            owner: owner,
            jid: jid,
            uniqueId: p13NextMentionNotificationUniqueId
        )
    }

    internal var p13UnrelatedMentionNotificationPrimaryForTesting: String {
        NotificationStorageItem.genPrimary(
            owner: owner,
            jid: p13UnrelatedGroupJidForTesting,
            uniqueId: p13UnrelatedMentionNotificationUniqueId
        )
    }

    /// P13 models a notification that became stale while its source row was
    /// already visible. Seeding the linked message as deleted earlier is not
    /// production-faithful: `Account.init` synchronously runs notification
    /// startup reconciliation and would correctly hide that row before a user
    /// could tap it. The real async Notifications datasource calls this only
    /// after materializing the still-resolved row and before exposing its tap
    /// readiness marker.
    @discardableResult
    internal func prepareP13DeletedMentionTapBoundaryForTesting() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard descriptor.openScenario == .mentionDeletedAdvance else {
            return false
        }
        if isP13DeletedMentionTapBoundaryPreparedForTesting {
            return true
        }
        guard AccountManager.shared.find(for: owner) != nil else {
            return false
        }

        do {
            let plan = ChatOpenRealPipelineFixturePlan(
                scenario: .mentionDeletedAdvance
            )
            let realm = try WRealm.safe()
            guard let staleMessage = realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: openPrimary(plan.p13DeletedMentionOrdinal)
            ),
                  let nextMessage = realm.object(
                    ofType: MessageStorageItem.self,
                    forPrimaryKey: openPrimary(
                        plan.p13NextValidMentionOrdinal
                    )
                  ),
                  let staleNotification = realm.object(
                    ofType: NotificationStorageItem.self,
                    forPrimaryKey:
                        p13DeletedMentionNotificationPrimaryForTesting
                  ),
                  let nextNotification = realm.object(
                    ofType: NotificationStorageItem.self,
                    forPrimaryKey:
                        p13NextMentionNotificationPrimaryForTesting
                  ),
                  !staleMessage.isDeleted,
                  !nextMessage.isDeleted,
                  staleNotification.mentionLinkStatus == .resolved,
                  !staleNotification.isRead,
                  staleNotification.shouldShow,
                  p13FollowingNotificationMatchesPreparedBranch(
                    nextNotification
                  ) else {
                return false
            }

            try realm.write {
                staleMessage.markDeleted()
            }

            guard staleMessage.isDeleted,
                  !nextMessage.isDeleted,
                  staleNotification.mentionLinkStatus == .resolved,
                  !staleNotification.isRead,
                  staleNotification.shouldShow,
                  p13FollowingNotificationMatchesPreparedBranch(
                    nextNotification
                  ) else {
                return false
            }
            isP13DeletedMentionTapBoundaryPreparedForTesting = true
            return true
        } catch {
            return false
        }
    }

    private func p13FollowingNotificationMatchesPreparedBranch(
        _ notification: NotificationStorageItem
    ) -> Bool {
        guard notification.mentionLinkStatus == .resolved else {
            return false
        }
        if isP13NoFollowingBranchForTesting {
            return notification.isRead && !notification.shouldShow
        }
        return !notification.isRead && notification.shouldShow
    }

    internal func prepareP13NoFollowingMentionBranchForTesting() throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard descriptor.openScenario == .mentionDeletedAdvance,
              !isP13NoFollowingBranchForTesting else {
            throw OpenScenarioError.targetSelectionUnavailable
        }
        let realm = try WRealm.safe()
        guard let next = realm.object(
            ofType: NotificationStorageItem.self,
            forPrimaryKey: p13NextMentionNotificationPrimaryForTesting
        ) else {
            throw OpenScenarioError.targetSelectionUnavailable
        }
        try realm.write {
            next.isRead = true
            next.shouldShow = false
        }
        isP13NoFollowingBranchForTesting = true
    }

    private func makeP13MentionNotification(
        uniqueId: String,
        chatJid: String,
        archivedId: String,
        messageId: String,
        date: Date
    ) -> NotificationStorageItem {
        let notification = NotificationStorageItem()
        notification.primary = NotificationStorageItem.genPrimary(
            owner: owner,
            jid: chatJid,
            uniqueId: uniqueId
        )
        notification.owner = owner
        notification.jid = chatJid
        notification.uniqueId = uniqueId
        notification.messageId = uniqueId
        notification.category = .mention
        notification.isRead = false
        notification.shouldShow = true
        notification.associatedJid = chatJid
        notification.text = "Mention"
        notification.fallbackText = "Mention"
        notification.date = date
        notification.sourceConversationType = .group
        notification.sourceChatJid = chatJid
        notification.sourceArchivedId = archivedId
        notification.sourceMessageId = messageId
        notification.sourceSenderId = "p13-other-member"
        notification.mentionTargetUserId = p13CurrentMemberId
        notification.sourceMessageDate = date
        notification.sourceBodyFingerprint =
            MentionNotificationSync.normalizedBodyFingerprint(
                "deterministic chat-open fixture mention"
            )
        notification.mentionLinkStatus = .resolved
        notification.linkedAt = date
        return notification
    }

    private func makeP13UnrelatedMessage() -> MessageStorageItem {
        let message = MessageStorageItem()
        message.messageId = "chat-open-p13-unrelated-message"
        message.primary = MessageStorageItem.genPrimary(
            messageId: message.messageId,
            owner: owner
        )
        message.owner = owner
        message.opponent = p13UnrelatedGroupJidForTesting
        message.conversationType = .group
        message.archivedId = "1700020000000000"
        message.date = Date(timeIntervalSince1970: 1_700_020_000)
        message.sentDate = message.date
        message.body = "deterministic unrelated fixture mention"
        message.outgoing = false
        message.isRead = false
        message.state = .deliver

        let mention = MessageReferenceStorageItem()
        mention.primary = "chat-open-p13-unrelated-reference"
        mention.owner = owner
        mention.messageId = message.messageId
        mention.kind = .mention
        mention.metadata = [
            "uri": "xmpp:\(p13UnrelatedGroupJidForTesting)?members;id=\(p13CurrentMemberId)",
            "memberId": p13CurrentMemberId,
            "groupchatJid": p13UnrelatedGroupJidForTesting,
            "nickname": "@fixture-member"
        ]
        message.references.append(mention)
        return message
    }

    private func openDate(_ ordinal: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(ordinal * 60))
    }

    private func loadInitialFixture() {
        fixtureMessages = (0..<ChatPerformanceScenarioContract.firstFrameMessageCount).map(makeMessage)
        fixtureMessages[42].primary = ChatPerformanceScenarioContract.exactTargetPrimary
        fixtureMessages[42].messageId = ChatPerformanceScenarioContract.exactTargetPrimary
        fixtureMessages[42].archivedId = ChatPerformanceScenarioContract.exactTargetPrimary
        fixtureMessages[42].body = "test exact target"
        showSkeletonObserver.accept(false)
        applyFixtureMessages(mode: .fullReload(), ready: true) { [weak self] in
            self?.startReleaseProbeIfRequested()
        }
    }

    private func makeMessage(ordinal: Int) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.primary = "chat-performance-row-\(ordinal)"
        item.owner = owner
        item.opponent = jid
        item.conversationType = .regular
        item.archivedId = "chat-performance-archive-\(ordinal)"
        item.messageId = "chat-performance-message-\(ordinal)"
        item.date = Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(ordinal * 60))
        item.sentDate = item.date
        item.body = ordinal % 11 == 0
            ? String(repeating: "bounded formatted message ", count: 12)
            : "fixture message \(ordinal)"
        item.outgoing = ordinal.isMultiple(of: 3)
        item.isRead = true
        item.state = .read
        return item
    }

    private func applyFixtureMessages(
        mode: ChatDatasourceApplyMode,
        ready: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        scenarioState.residentMessageCount = fixtureMessages.count
        let isReady = ready || readyLabel.text?.hasPrefix("ready") == true
        renderStatus(isReady: isReady)
        let mapped = mapDataset(dataset: fixtureMessages)
        applyChatDatasource(
            mapped,
            mode: mode,
            animated: false,
            invalidateLayout: false,
            suppressDefaultBottomScroll: mode.isTargetedDiff,
            completion: { [weak self] in
                guard let self else { return }
                self.renderStatus(isReady: isReady)
                completion?()
            }
        )
    }

    private func startReleaseProbeIfRequested() {
        guard ProcessInfo.processInfo.environment["XABBER_CHAT_PERFORMANCE_RELEASE_PROBE"] == "1" else {
            return
        }
        scrollFrameOperationCounter.setEnabled(true)
        scrollFrameOperationCounter.reset()
        releaseProbeFirstStableMilliseconds = (CACurrentMediaTime() - releaseProbeStartedAt) * 1_000
        releaseProbeResidentBytes.removeAll(keepingCapacity: true)
        runReleaseProbeCycle(index: 0)
    }

    private func runReleaseProbeCycle(index: Int) {
        guard index < 20 else {
            finishReleaseProbe()
            return
        }

        let item = makeMessage(ordinal: 30_000 + index)
        item.primary = "chat-performance-release-probe-\(index)"
        item.messageId = item.primary
        item.archivedId = item.primary
        fixtureMessages.append(item)
        applyFixtureMessages(mode: .targetedDiff) { [weak self] in
            guard let self,
                  let itemIndex = self.fixtureMessages.firstIndex(where: { $0.primary == item.primary }) else {
                return
            }
            self.fixtureMessages.remove(at: itemIndex)
            self.applyFixtureMessages(mode: .targetedDiff) { [weak self] in
                guard let self else { return }
                self.releaseProbeResidentBytes.append(self.currentResidentMemoryBytes())
                self.runReleaseProbeCycle(index: index + 1)
            }
        }
    }

    private func finishReleaseProbe() {
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .mediaPrefetch)
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .mediaBecameVisible)

        let optimisticStart = CACurrentMediaTime()
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .optimisticSend)
        let item = makeMessage(ordinal: 40_000)
        item.primary = "chat-performance-release-optimistic"
        item.messageId = item.primary
        item.archivedId = item.primary
        item.body = "release optimistic probe"
        item.outgoing = true
        item.state = .sending
        fixtureMessages.append(item)
        applyFixtureMessages(mode: .targetedDiff) { [weak self] in
            guard let self,
                  let index = self.fixtureMessages.firstIndex(where: { $0.primary == item.primary }) else {
                return
            }
            let optimisticMilliseconds = (CACurrentMediaTime() - optimisticStart) * 1_000
            self.fixtureMessages.remove(at: index)
            self.scenarioState = ChatPerformanceScenarioContract.reduce(
                self.scenarioState,
                event: .deleteOptimisticMessage
            )
            self.applyFixtureMessages(mode: .targetedDiff) { [weak self] in
                self?.emitReleaseProbeReport(optimisticMilliseconds: optimisticMilliseconds)
            }
        }
    }

    private func emitReleaseProbeReport(optimisticMilliseconds: Double) {
        let sample = ChatPerformanceReleaseSample(
            scale: descriptor.scale,
            firstStableMilliseconds: releaseProbeFirstStableMilliseconds,
            cycleResidentBytes: releaseProbeResidentBytes,
            optimisticLocalRowMilliseconds: optimisticMilliseconds,
            state: scenarioState,
            releaseOperations: scrollFrameOperationCounter.snapshot()
        )
        guard let line = try? sample.reportLine(),
              let data = (line + "\n").data(using: .utf8) else {
            return
        }
        let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            ChatPerformanceReleaseSample.reportFileName,
            isDirectory: false
        )
        try? data.write(to: reportURL, options: .atomic)
        FileHandle.standardOutput.write(data)
    }

    private func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    private func renderStatus(isReady: Bool) {
        let operation = scenarioState.operationSnapshot
        readyLabel.text = "\(isReady ? "ready" : "loading") scale=\(descriptor.scale.rawValue) logical=\(scenarioState.logicalMessageCount) resident=\(scenarioState.residentMessageCount) applies=\(operation.datasourceApplies) layouts=\(operation.forcedLayouts) offsets=\(operation.programmaticOffsets)"
        stateLabel.text = "anchor=\(scenarioState.anchorDrift) optimistic=\(scenarioState.optimisticMessageCount) edited=\(scenarioState.editedMessageCount) media=\(scenarioState.mediaDownloadCount)/\(scenarioState.mediaDecodeCount)/\(scenarioState.mediaVisibleCacheHitCount) skeleton=\(scenarioState.isSkeletonVisible) target=\(scenarioState.exactTargetPrimary ?? "-") corrections=\(scenarioState.operationSnapshot.delayedCorrections)"
    }

    @objc private func addIncoming() {
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .incomingWhileScrolled)
        let item = makeMessage(ordinal: 10_000 + fixtureMessages.count)
        item.primary = "chat-performance-incoming"
        item.body = "incoming while scrolled"
        item.outgoing = false
        fixtureMessages.append(item)
        applyFixtureMessages(mode: .targetedDiff)
    }

    private func appendOptimisticMessage(body: String) {
        guard body.trimmingCharacters(in: .whitespacesAndNewlines).isNotEmpty else { return }
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .optimisticSend)
        let item = makeMessage(ordinal: 20_000 + fixtureMessages.count)
        item.primary = "chat-performance-optimistic-\(UUID().uuidString)"
        item.messageId = item.primary
        item.archivedId = item.primary
        item.body = body
        item.outgoing = true
        item.state = .sending
        optimisticPrimary = item.primary
        fixtureMessages.append(item)
        applyFixtureMessages(mode: .targetedDiff)
    }

    @objc private func editOptimistic() {
        guard let optimisticPrimary,
              let item = fixtureMessages.first(where: { $0.primary == optimisticPrimary }) else { return }
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .editOptimisticMessage)
        item.body += " edited"
        item.editDate = Date()
        applyFixtureMessages(mode: .targetedDiff)
    }

    @objc private func deleteOptimistic() {
        guard let optimisticPrimary,
              let index = fixtureMessages.firstIndex(where: { $0.primary == optimisticPrimary }) else { return }
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .deleteOptimisticMessage)
        fixtureMessages.remove(at: index)
        self.optimisticPrimary = nil
        applyFixtureMessages(mode: .targetedDiff)
    }

    @objc private func prefetchMedia() {
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .mediaPrefetch)
        renderStatus(isReady: true)
    }

    @objc private func showPrefetchedMedia() {
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .mediaBecameVisible)
        renderStatus(isReady: true)
    }

    @objc private func showFixtureSkeleton() {
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .showSkeleton)
        renderStatus(isReady: true)
        showSkeletonObserver.accept(true)
        let skeleton = mapDataset(
            dataset: [],
            context: captureDatasourceMappingContext(
                purpose: .bootstrapSkeleton
            )
        ).datasource
        applyChatDatasource(
            skeleton,
            mode: .fullReload(keepOffset: true),
            animated: false,
            suppressDefaultBottomScroll: true,
            completion: { [weak self] in self?.renderStatus(isReady: true) }
        )
    }

    @objc private func revealFixtureSkeleton() {
        scenarioState = ChatPerformanceScenarioContract.reduce(scenarioState, event: .revealSkeleton)
        renderStatus(isReady: true)
        showSkeletonObserver.accept(false)
        applyFixtureMessages(mode: .fullReload(keepOffset: true))
    }

    @objc private func openLastChatsSearch() {
        let controller = ChatPerformanceLastChatsSearchViewController { [weak self] query in
            self?.routeFromSearch(query: query)
        }
        navigationController?.pushViewController(controller, animated: false)
    }

    private func routeFromSearch(query: String) {
        scenarioState = ChatPerformanceScenarioContract.reduce(
            scenarioState,
            event: .searchExactTarget(query: query)
        )
        navigationController?.popViewController(animated: false)
        guard let index = datasource.firstIndex(where: {
            $0.primary == ChatPerformanceScenarioContract.exactTargetPrimary
        }) else {
            renderStatus(isReady: true)
            return
        }
        messagesCollectionView.layoutIfNeeded()
        messagesCollectionView.scrollToItem(
            at: IndexPath(item: 0, section: index),
            at: .centeredVertically,
            animated: false
        )
        renderStatus(isReady: true)
    }
}

private extension ChatDatasourceApplyMode {
    var isTargetedDiff: Bool {
        if case .targetedDiff = self { return true }
        return false
    }
}

final class ChatPerformanceLastChatsSearchViewController: UITableViewController, UISearchResultsUpdating {
    private let onSelect: (String) -> Void
    private var query = ""

    init(onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Last Chats Search"
        view.accessibilityIdentifier = "lastchats.performance.screen"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "result")
        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.searchTextField.accessibilityIdentifier = "lastchats.performance.search_input"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        query.compare("test", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame ? 1 : 0
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "result", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = "test exact target"
        content.secondaryText = ChatPerformanceScenarioContract.exactTargetPrimary
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "lastchats.performance.exact_result"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onSelect(query)
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        tableView.reloadData()
    }
}
#endif
