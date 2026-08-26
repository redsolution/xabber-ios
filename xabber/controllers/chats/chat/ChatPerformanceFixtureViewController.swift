import UIKit
import RealmSwift
import XMPPFramework

#if DEBUG || CHAT_PERFORMANCE_LAB
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
        case targetSelectionUnavailable
        case archiveDescriptorRejected
        case artifactExportUnavailable
        case stableFrameTraceRejected
        case videoMarkerPublicationRejected
        case terminalEvidenceMovedAfterStableFrame
        case primaryTraceContextUnavailable
        case traceContextBindingRejected
        case traceContextCardinalityRejected
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
    private var openScenarioResolvedTargetOrdinal: Int?
    private var openScenarioTargetMatchCount = 0
    private var openScenarioLatestVisualCommitCount = 0
    private var openScenarioArchiveRequestCount = 0
    private var openScenarioGapRequestCount = 0
    private var openScenarioRouteMeasurementHasStarted = false
    private var openScenarioFixtureRealmQueryCountAfterRouteAdmission = 0
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
    private var openScenarioSkeletonPresentationBaseline:
        OpenScenarioSkeletonPresentationSnapshot?
    private var openScenarioSkeletonIdentityStable = true
    private var openScenarioSkeletonGeometryStable = true
    private var openScenarioSkeletonDwellMilliseconds = 0
    private var openScenarioPostInitialInteractionReady = false
    private var openScenarioPostInitialInteractionCount = 0
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
    private var p14ReadSuccessfulFlushCountBaseline = 0
    private(set) var isP13DeletedMentionTapBoundaryPreparedForTesting = false
    private(set) var isP13NoFollowingBranchForTesting = false
    private(set) var openScenarioStableReceipt: ChatOpenRealPipelineFixtureDiagnostics?
    var openScenarioDidStabilize: ((ChatOpenRealPipelineFixtureDiagnostics) -> Void)?

    internal var isOpenScenarioPublishedEvidenceAcceptedForTesting: Bool {
        guard openScenarioStableReceipt?.isStable == true else { return false }
        return openScenarioArtifactExportSession?.didFinalizeSuccessfully ?? true
    }

    internal var openScenarioStableAccessibilitySummaryForTesting: String? {
        openStableLabel.text
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
            datasourceGeneration: scrollResidentMetadata.generation
        )
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
                    showSkeletonObserver.value &&
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
    /// lifecycle (the Realm lease, Darwin latch and display-link evidence
    /// sampler). Hosted tests tear a controller down
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

        // Close DEBUG observation before invalidating coordinator work.
        performanceOpenMessageRequestAdmissionObserver = nil
        visibleMentionReadScheduledForTests = nil
        visibleMentionReadAfterFirstPersistentMutationBarrierForTests = nil
        visibleMentionReadTerminalForTests = nil
        p14ReadSuccessfulFlushCountBaseline =
            readVisiblePresentationCoordinator.successfulFlushCount
        visibleUnreadMentionReconciliationWorkItem?.cancel()
        visibleUnreadMentionReconciliationWorkItem = nil
        readVisibleStableLayoutRetryWorkItem?.cancel()
        readVisibleStableLayoutRetryWorkItem = nil
        readVisiblePresentationCoordinator.invalidatePresentation()

        performanceFixtureSendHandler = nil
        performanceFixtureWidthTransitionLayoutCommitHandler = nil
        performanceFixtureWinningArchiveUIKitApplyHandler = nil
        performanceFixtureAllowsSkeletonStableFrame = false
        openScenarioLifecycleObservationTokens.forEach {
            NotificationCenter.default.removeObserver($0)
        }
        openScenarioLifecycleObservationTokens.removeAll()
        openScenarioRotationOffsetGate.cancel()
        openScenarioLastRotationSourceSample = nil
        stopOpenScenarioVisibleOffsetSampling(capturingCurrentOffset: false)
        openScenarioArtifactFinalizationInFlight = false
        openScenarioArtifactExportSession = nil
        openScenarioVideoEvidenceFailureCode = .none
        openScenarioArtifactExportFailureCode = .none
        openScenarioArtifactTraceFailure = .none
        openScenarioBoundPrimaryTraceContext = nil
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
        openPostInitialActionButton.isHidden = true
        renderOpenScenarioPhase(.content, plan: plan)
    }

    @objc private func performOpenScenarioPostInitialAction() {
        _ = admitOpenScenarioPostInitialAction()
    }

    @discardableResult
    private func admitOpenScenarioPostInitialAction() -> Bool {
        false
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
        performanceFixtureWidthTransitionLayoutCommitHandler = {
            [weak self] generation, targetViewSize in
            self?.recordOpenScenarioWidthTransitionLayoutCommit(
                generation: generation,
                targetViewSize: targetViewSize
            )
        }
        performanceFixtureWinningArchiveUIKitApplyHandler = {
            [weak self] receipt in
            self?.recordOpenScenarioWinningArchiveUIKitApply(
                receipt,
                plan: plan,
                lifecycleGeneration: lifecycleGeneration
            )
        }
        performanceFixtureAllowsSkeletonStableFrame =
            plan.allowsSkeletonStableFrame
        if plan.scenario == .committedContentBackgroundForeground {
            installOpenScenarioLifecycleObservation()
        }
        renderOpenScenarioPhase(.preparing, plan: plan)

        guard openScenarioSetupFailure == nil else {
            publishOpenScenarioFailure(plan: plan)
            return
        }

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
                self.startArchiveEnginePresentationIfNeeded()
            }
            guard self.bindOpenScenarioPrimaryTraceContext(plan: plan) else {
                self.publishOpenScenarioFailure(plan: plan)
                return
            }
            if !plan.requiresRemoteInjection,
               !plan.requiresPostInitialInteraction {
                self.beginOpenScenarioTerminalObservation(plan: plan)
            }
        }
    }

    private func isOpenScenarioLifecycleCurrent(generation: Int) -> Bool {
        !openScenarioTerminalTeardownCompleted &&
            generation == openScenarioLifecycleGeneration
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

    private func recordOpenScenarioWinningArchiveUIKitApply(
        _ receipt: ChatPerformanceWinningArchiveUIKitApplyReceipt,
        plan: ChatOpenRealPipelineFixturePlan,
        lifecycleGeneration: Int
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isOpenScenarioLifecycleCurrent(
                generation: lifecycleGeneration
              ),
              openScenarioStableReceipt == nil,
              openScenarioProductionVisualCommitCount == 0,
              receipt.conversationKey == chatTimelineConversationKey,
              receipt.applyGeneration == archiveWindowApplyGeneration,
              timelineSession?.snapshot.generation ==
                receipt.sessionGeneration else {
            return
        }

        // A fixture lifecycle consumes exactly one winning archive frame.
        // Later paging/store applies and late callbacks from replaced sessions
        // cannot mutate the initial-frame receipt.
        performanceFixtureWinningArchiveUIKitApplyHandler = nil
        openScenarioViewportDiagnostics = receipt.viewportDiagnostics
        openScenarioProductionVisualCommitCount = 1
        switch receipt.viewportDiagnostics.anchorStrategy {
        case .bottom:
            openScenarioLatestVisualCommitCount = 1
        case .message(let anchor):
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
            anchorStrategy: receipt.viewportDiagnostics.anchorStrategy
        ) {
            openScenarioUnexpectedCommittedFrameCount = 1
        }
        recordOpenScenarioAtomicInitialOffsetIfNeeded()
        openScenarioLastSampledOffsetY = messagesCollectionView.contentOffset.y
        openScenarioHasCommittedViewport = true

        if plan.requiresPostInitialInteraction {
            if plan.scenario == .lastChatsAnimatedPush {
                beginOpenScenarioHostTerminalObservationIfReady()
            } else {
                renderOpenScenarioInteractionReady(plan: plan)
            }
        } else if plan.scenario == .coldPushExact ||
                    plan.scenario == .mentionDeletedAdvance ||
                    plan.scenario == .lastChatsSeededMentionExact {
            beginOpenScenarioHostTerminalObservationIfReady()
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

    private func prepareOpenScenarioRealm(plan: ChatOpenRealPipelineFixturePlan) throws {
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
        let coveragePrimary = ConversationArchiveCoverageStorageItem.genPrimary(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )

        let ordinals: [Int]
        if plan.hasKnownGapTopology {
            ordinals = Array(0..<80) + Array(240..<320)
        } else {
            ordinals = Array(0..<plan.initialLocalMessageCount)
        }
        let messages = ordinals.map(makeOpenScenarioMessage)
        let coverageFingerprint = "fixture:\(plan.scenario.rawValue)"
        let coverageRanges: [(oldest: Int, newest: Int, start: Bool, live: Bool)]
        if plan.startsWithoutDurableReadiness || messages.isEmpty {
            coverageRanges = []
        } else if plan.hasKnownGapTopology {
            coverageRanges = [
                (0, 79, true, false),
                (240, 319, false, true)
            ]
        } else {
            coverageRanges = [(0, ordinals.last ?? 0, true, true)]
        }
        let coverageSegments: [ArchiveCoverageSegment] = coverageRanges.compactMap { range in
            guard let oldest = ArchiveCursor(rawValue: openArchiveId(range.oldest)),
                  let newest = ArchiveCursor(rawValue: openArchiveId(range.newest)) else {
                return nil
            }
            return ArchiveCoverageSegment(
                oldest: oldest,
                newest: newest,
                reachesArchiveStart: range.start,
                reachesLiveEdge: range.live,
                fingerprint: coverageFingerprint,
                isVerified: true
            )
        }

        try realm.write {
            realm.delete(existingMessages)
            if let existingChat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: chatPrimary
            ) {
                realm.delete(existingChat)
            }
            if let existingCoverage = realm.object(
                ofType: ConversationArchiveCoverageStorageItem.self,
                forPrimaryKey: coveragePrimary
            ) {
                realm.delete(existingCoverage)
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
            let coverage = ConversationArchiveCoverageStorageItem.ensure(
                key: ArchiveConversationKey(
                    owner: owner,
                    jid: jid,
                    conversationType: conversationType
                ),
                in: realm
            )
            coverage.segments = coverageSegments
            coverage.coverageGeneration =
                plan.startsWithoutDurableReadiness ? 0 : 1
            coverage.lastObservedXEPSYNCFingerprint =
                plan.startsWithoutDurableReadiness ? nil : coverageFingerprint
            coverage.updatedAt = Date()

            if plan.hasKnownGapTopology {
                let snapshot = openArchiveId(319)
                chat.syncSnapshotLastArchiveId = snapshot
            } else if messages.isNotEmpty {
                let snapshot = openArchiveId(319)
                chat.syncSnapshotLastArchiveId = snapshot
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
                }
            }
            realm.add(chat, update: .modified)

            let canonicalSelfMemberID: String?
            switch plan.scenario {
            case .mentionDeletedAdvance:
                canonicalSelfMemberID = p13CurrentMemberId
            case .lastChatsSeededMentionExact:
                canonicalSelfMemberID = p14CurrentMemberId
            default:
                canonicalSelfMemberID = nil
            }
            if let canonicalSelfMemberID {
                let membership = GroupSelfMembershipStorageItem()
                membership.primary = GroupStorageKey.groupPrimary(
                    owner: owner,
                    groupJID: jid
                )
                membership.owner = GroupStorageKey.bareJID(owner)
                membership.groupJID = GroupStorageKey.bareJID(jid)
                membership.stateRaw = GroupSelfMembershipState.both.rawValue
                membership.memberID = canonicalSelfMemberID
                realm.add(membership, update: .modified)
            }

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
                unrelatedChat.syncSnapshotLastArchiveId =
                    unrelatedMessage.archivedId
                unrelatedChat.mentionId = unrelatedMessage.archivedId
                realm.add(unrelatedChat, update: .modified)

                let unrelatedMembership = GroupSelfMembershipStorageItem()
                unrelatedMembership.primary = GroupStorageKey.groupPrimary(
                    owner: owner,
                    groupJID: p13UnrelatedGroupJidForTesting
                )
                unrelatedMembership.owner = GroupStorageKey.bareJID(owner)
                unrelatedMembership.groupJID = GroupStorageKey.bareJID(
                    p13UnrelatedGroupJidForTesting
                )
                unrelatedMembership.stateRaw = GroupSelfMembershipState.both.rawValue
                unrelatedMembership.memberID = p13CurrentMemberId
                realm.add(unrelatedMembership, update: .modified)

                let unrelatedCoverage =
                    ConversationArchiveCoverageStorageItem.ensure(
                        key: ArchiveConversationKey(
                            owner: owner,
                            jid: p13UnrelatedGroupJidForTesting,
                            conversationType: .group
                        ),
                        in: realm
                    )
                if let cursor = ArchiveCursor(
                    rawValue: unrelatedMessage.archivedId
                ), let segment = ArchiveCoverageSegment(
                    oldest: cursor,
                    newest: cursor,
                    reachesArchiveStart: true,
                    reachesLiveEdge: true,
                    fingerprint: coverageFingerprint,
                    isVerified: true
                ) {
                    unrelatedCoverage.segments = [segment]
                }
                unrelatedCoverage.coverageGeneration = 1
                unrelatedCoverage.lastObservedXEPSYNCFingerprint =
                    coverageFingerprint
                unrelatedCoverage.updatedAt = unrelatedMessage.date

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
        let coverage = realm.object(
            ofType: ConversationArchiveCoverageStorageItem.self,
            forPrimaryKey: ConversationArchiveCoverageStorageItem.genPrimary(
                owner: owner,
                jid: jid,
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
            hasArchiveState: coverage != nil,
            hasDurableReadiness:
                (coverage?.coverageGeneration ?? 0) > 0 &&
                coverage?.lastObservedXEPSYNCFingerprint != nil &&
                (messageCount == 0 ||
                    coverage?.segments.contains(where: \.isVerified) == true)
        )
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

    private func captureOpenScenarioActiveProductionWorkCount() -> Int {
        var count = archiveWindowActivity.activeBoundaryRequestCount
        func countIf(_ condition: Bool) {
            if condition { count &+= 1 }
        }

        count &+= timelineSession?.activeStoreObservationWorkCount ?? 0
        countIf(isChatDatasourceStructuralTransactionActive)
        countIf(archiveWindowPendingSnapshot != nil)
        countIf(archiveWindowAtomicApplyRetryWorkItem != nil)
        count &+= scrollWorkScheduler.pendingRequestCount
        countIf(currentScrollMotionState() != .resting)
        if descriptor.openScenario == .lastChatsSeededMentionExact {
            count &+= readVisiblePresentationCoordinator.pendingCandidateCount
            count &+= readVisiblePresentationCoordinator.inFlightFlushCount
            countIf(visibleUnreadMentionReconciliationWorkItem != nil)
            countIf(readVisibleStableLayoutRetryWorkItem != nil)
        }
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
        let currentOffsetY = messagesCollectionView.contentOffset.y
        openScenarioInitialSkeletonRowCount = max(
            openScenarioInitialSkeletonRowCount,
            openScenarioSkeletonRowCount
        )
        let hasOffsetMovement = openScenarioLastSampledOffsetY.map {
            abs($0 - currentOffsetY) > 0.5
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
                retainedPagingAnchorStayedFixed: false,
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
        let firstContentApplyCount =
            (realRows > 0 || openScenarioArchiveIsAuthoritativeEmpty) ? 1 : 0
        let skeletonRows = openScenarioSkeletonRowCount
        let transportThreadSnapshot =
            ChatOpenRealPipelineFixtureTransportThreadSnapshot.empty
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
        let hasExpectedVisualTerminal: Bool
        if plan.expectsSkeletonTerminal {
            compareOpenScenarioSkeletonWithBaseline()
            hasExpectedVisualTerminal = realRows == 0 &&
                skeletonRows == plan.expectedFinalSkeletonRowCount &&
                firstContentApplyCount == 0 &&
                openScenarioProductionVisualCommitCount == 0 &&
                openScenarioUnexpectedCommittedFrameCount == 0 &&
                openScenarioSkeletonIdentityStable &&
                openScenarioSkeletonGeometryStable &&
                openScenarioArchiveShowsRetry ==
                    plan.expectsRetry &&
                (plan.scenario != .bootstrapHeldOverWatchdog ||
                    openScenarioSkeletonDwellMilliseconds >= 5_000)
        } else if plan.expectsConfirmedEmpty {
            hasExpectedVisualTerminal = datasource.isEmpty &&
                skeletonRows == 0 &&
                openScenarioArchiveIsAuthoritativeEmpty &&
                firstContentApplyCount == 1 &&
                openScenarioProductionVisualCommitCount == 1 &&
                openScenarioUnexpectedCommittedFrameCount == 0
        } else {
            hasExpectedVisualTerminal =
                realRows == plan.expectedFinalRealRowCount &&
                skeletonRows == 0 &&
                firstContentApplyCount == 1 &&
                openScenarioProductionVisualCommitCount == 1 &&
                openScenarioUnexpectedCommittedFrameCount == 0 &&
                hasExpectedHeldSkeletonStability
        }
        let operationSnapshot = scrollFrameOperationCounter.snapshot()
        let archiveRequestCount = openScenarioArchiveRequestCount
        let gapRequestCount = openScenarioGapRequestCount
        let activeProductionWorkCount =
            captureOpenScenarioActiveProductionWorkCount()
        let p14MentionDiagnostics = captureP14MentionDiagnostics()
        let evidence = ChatOpenRealPipelineFixtureTerminalEvidenceSnapshot(
            // Mapping-job generations may advance for work that is cancelled
            // or reduced model-only. Terminal visual stability is owned by the
            // datasource generation that was actually published on main.
            datasourceGeneration: Int(scrollResidentMetadata.generation),
            datasourceApplyCount: operationSnapshot[.datasourceApplies],
            firstContentApplyCount: firstContentApplyCount,
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
            retryVisible: openScenarioArchiveShowsRetry,
            skeletonIdentityStable: openScenarioSkeletonIdentityStable,
            skeletonGeometryStable: openScenarioSkeletonGeometryStable,
            skeletonDwellMilliseconds: openScenarioSkeletonDwellMilliseconds,
            postInitialInteractionCount:
                openScenarioPostInitialInteractionCount,
            pagingAnchorErrorMilliPoints: nil,
            rotationTransitionCount: openScenarioRotationTransitionCount,
            applicationBackgroundCount:
                openScenarioApplicationBackgroundCount,
            applicationForegroundCount:
                openScenarioApplicationForegroundCount,
            productionBootstrapLeaseEventCount: 0,
            productionBootstrapTransportCount: 0,
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
        let hasExpectedTransportThreadShape = transportThreadSnapshot == .empty
        let hasExpectedPostInitialInteraction: Bool
        switch plan.scenario {
        case .lastChatsAnimatedPush:
            hasExpectedPostInitialInteraction =
                openScenarioPostInitialInteractionCount == 1
        case .olderCrossingGap, .newerCrossingGap:
            hasExpectedPostInitialInteraction =
                openScenarioPostInitialInteractionCount == 0
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
                hasExpectedTransportThreadShape &&
                hasExpectedPostInitialInteraction &&
                hasExpectedRouteHost &&
                hasExpectedP14MentionLifecycle
        )
    }

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
            guard openScenarioBoundPrimaryTraceContext != nil else {
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
        DispatchQueue.global(qos: .utility).async { [weak self, exportSession] in
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
        let operationSnapshot = scrollFrameOperationCounter.snapshot()
        let realRows = datasource.lazy.filter { !$0.isFakeMessage }.count
        let firstContentApplyCount =
            (realRows > 0 || openScenarioArchiveIsAuthoritativeEmpty) ? 1 : 0
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
        // Sample the same route recorder at terminal publication as well as
        // at commit. A late target lookup, observer refresh or main-thread
        // provider call must invalidate the final proof instead of being
        // hidden behind an earlier good commit snapshot.
        let terminalRouteDiagnostics =
            timelineSession?.routeStoreDiagnosticsSnapshot
        let routeDiagnostics = terminalRouteDiagnostics?.routeDelta(
            since: openScenarioRouteStoreDiagnosticsBaseline
        )
        let transportThreadSnapshot =
            ChatOpenRealPipelineFixtureTransportThreadSnapshot.empty
        let activeProductionWorkCount =
            captureOpenScenarioActiveProductionWorkCount()
        let terminalArchiveRequestCount = openScenarioArchiveRequestCount
        let terminalGapRequestCount = openScenarioGapRequestCount
        let initialArchiveRequestCount = 0
        let initialGapRequestCount = 0
        let capturedInitialRouteDiagnostics: ChatTimelineStoreDiagnosticsSnapshot? = nil
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
            firstContentApplyCount: firstContentApplyCount,
            visualCommitCount: openScenarioProductionVisualCommitCount,
            previousOrBlankRealFrameCount:
                ChatOpenRealPipelineFixtureDiagnosticsPolicy.previousOrBlankFrameCount(
                    visualCommitCount: openScenarioProductionVisualCommitCount,
                    unexpectedCommittedFrameCount: openScenarioUnexpectedCommittedFrameCount,
                    intermediateEmptyFrameCount: 0,
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
            requestSource: nil,
            requestHighlight: false,
            requestMarkReadOnVisible: nil,
            resolvedTargetOrdinal: openScenarioResolvedTargetOrdinal,
            targetMatchCount: openScenarioTargetMatchCount,
            latestVisualCommitCount: openScenarioLatestVisualCommitCount,
            p14Mention: captureP14MentionDiagnostics(),
            heldSkeletonDisplayTickCount:
                openScenarioHeldSkeletonDisplayTickCount,
            archiveLeaseCount: 0,
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
            archiveCursorKind: .none,
            retryVisible: openScenarioArchiveShowsRetry,
            skeletonIdentityStable: openScenarioSkeletonIdentityStable,
            skeletonGeometryStable: openScenarioSkeletonGeometryStable,
            skeletonDwellMilliseconds: openScenarioSkeletonDwellMilliseconds,
            postInitialInteractionCount:
                openScenarioPostInitialInteractionCount,
            pagingAnchorErrorMilliPoints: nil,
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
                routeDiagnostics?.mainThreadQueryCount ?? -1,
            fullScanCount:
                routeDiagnostics?.fullScanCount ?? -1,
            maxCandidateCount:
                routeDiagnostics?.maxCandidateCount ?? -1,
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
            preparedOnMainThread: true,
            mappedOnMainThread: true,
            realDatasourceApplyCount: 0,
            atomicLayoutCommitCount: 0,
            committedRouteCount: openScenarioProductionVisualCommitCount,
            committedTargetKind: nil,
            productionBootstrapLeaseStartCount: 0,
            productionBootstrapLeaseJoinCount: 0,
            productionBootstrapActiveLeaseCount: 0,
            productionBootstrapCompletedLeaseCount: 0,
            productionBootstrapFailedLeaseCount: 0,
            productionBootstrapCancelledLeaseCount: 0,
            productionBootstrapTransportStartCount: 0,
            bootstrapRequestCount: 0,
            bootstrapFinalCount: 0,
            bootstrapDeliveredMessageCount: 0,
            bootstrapPersistedMessageCount: 0,
            finalNewerLiveEdgeReached: false,
            finalOlderArchiveEndReached: false,
            finalFullArchiveLoaded: false,
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

    private var openScenarioArchiveShowsRetry: Bool {
        // Legacy performance-artifact field: this records only the injected
        // retryable-failure state. Production no longer owns or presents a
        // Retry view; renaming the persisted fixture schema is a separate
        // compatibility migration.
        if case .retryableFailure? = archiveWindowState {
            return true
        }
        return false
    }

    private var openScenarioArchiveIsAuthoritativeEmpty: Bool {
        if case .authoritativeEmpty? = archiveWindowState {
            return true
        }
        return false
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
            presentationOwner: .archiveEngine,
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
            context: captureDatasourceMappingContext()
        ).datasource
        applyChatDatasource(
            skeleton,
            mode: .fullReload(keepOffset: true),
            animated: false,
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine,
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
