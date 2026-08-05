//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//

import Foundation

struct ChatScrollVisibleRow: Equatable {
    let section: Int
    let primary: String
    let position: ChatTimelinePositionKey
    let isOutgoing: Bool
    let isRead: Bool
    let rowKind: ChatVisiblePositionPolicy.RowKind
    let isFakeMessage: Bool
    let sentDate: Date
    let floatingDateDay: Date
    let voiceDescriptors: [VoiceMessageDescriptor]

    init(
        section: Int,
        primary: String,
        position: ChatTimelinePositionKey,
        isOutgoing: Bool,
        isRead: Bool,
        rowKind: ChatVisiblePositionPolicy.RowKind,
        isFakeMessage: Bool,
        sentDate: Date,
        voiceDescriptors: [VoiceMessageDescriptor],
        calendar: Calendar = .current
    ) {
        self.section = section
        self.primary = primary
        self.position = position
        self.isOutgoing = isOutgoing
        self.isRead = isRead
        self.rowKind = rowKind
        self.isFakeMessage = isFakeMessage
        self.sentDate = sentDate
        self.floatingDateDay = calendar.startOfDay(for: sentDate)
        self.voiceDescriptors = voiceDescriptors
    }

    var isUnreadIncomingMessage: Bool {
        rowKind == .message && !isFakeMessage && !isOutgoing && !isRead
    }
}

struct ChatScrollVisibleMetadata: Equatable {
    static let empty = ChatScrollVisibleMetadata(
        generation: 0,
        residentRowCount: 0,
        rows: [],
        boundaryContext: ChatHistoryPagingBoundaryContext(
            firstRealSection: nil,
            lastRealSection: nil,
            visibleRealSections: []
        )
    )

    let generation: UInt64
    let residentRowCount: Int
    let rows: [ChatScrollVisibleRow]
    let boundaryContext: ChatHistoryPagingBoundaryContext
}

struct ChatScrollResidentMetadata: Equatable {
    static let empty = ChatScrollResidentMetadata(
        generation: 0,
        rows: [],
        firstRealSection: nil,
        lastRealSection: nil
    )

    let generation: UInt64
    let residentRowCount: Int
    let firstRealSection: Int?
    let lastRealSection: Int?
    private let rowsBySection: [Int: ChatScrollVisibleRow]
    private let rowsByPrimary: [String: ChatScrollVisibleRow]

    init(
        generation: UInt64,
        rows: [ChatScrollVisibleRow],
        firstRealSection: Int?,
        lastRealSection: Int?
    ) {
        self.generation = generation
        self.residentRowCount = rows.count
        self.firstRealSection = firstRealSection
        self.lastRealSection = lastRealSection
        self.rowsBySection = Dictionary(
            rows.map { ($0.section, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        self.rowsByPrimary = Dictionary(
            rows.map { ($0.primary, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    func capture(indexPaths: [IndexPath]) -> ChatScrollVisibleMetadata {
        let rows = capturedRows(indexPaths: indexPaths)
        return ChatScrollVisibleMetadata(
            generation: generation,
            residentRowCount: residentRowCount,
            rows: rows,
            boundaryContext: boundaryContext(visibleSections: rows.map(\.section))
        )
    }

    func boundaryContext(visibleSections: [Int]) -> ChatHistoryPagingBoundaryContext {
        let visibleRealSections = Array(Set(visibleSections.compactMap { section -> Int? in
            guard let row = rowsBySection[section], !row.isFakeMessage else {
                return nil
            }
            return section
        })).sorted()
        return ChatHistoryPagingBoundaryContext(
            firstRealSection: firstRealSection,
            lastRealSection: lastRealSection,
            visibleRealSections: visibleRealSections
        )
    }

    func position(primary: String) -> ChatTimelinePositionKey? {
        rowsByPrimary[primary]?.position
    }

    private func capturedRows(indexPaths: [IndexPath]) -> [ChatScrollVisibleRow] {
        var seenSections = Set<Int>()
        return indexPaths
            .sorted {
                if $0.section != $1.section {
                    return $0.section < $1.section
                }
                return $0.item < $1.item
            }
            .compactMap { indexPath in
                guard indexPath.item == 0,
                      seenSections.insert(indexPath.section).inserted else {
                    return nil
                }
                return rowsBySection[indexPath.section]
            }
    }
}

struct ChatScrollFloatingDateUpdate: Equatable {
    let section: Int
    let date: Date
    let residentRowCount: Int
}

enum ChatScrollFrameBudgetViolation: Equatable {
    case visibleRows
    case storeQuery
    case textMeasurement
    case layoutMeasurement
}

struct ChatScrollFrameDiagnostics: Equatable {
    let visibleRowVisits: Int
    let storeQueryCount: Int
    let textMeasurementCount: Int
    let layoutMeasurementCount: Int
    let floatingDateUpdateCount: Int
    let voiceDescriptorBuildCount: Int
    let voiceQueueUpdateCount: Int

    func violations(maxVisibleRows: Int) -> [ChatScrollFrameBudgetViolation] {
        var result: [ChatScrollFrameBudgetViolation] = []
        if visibleRowVisits > max(0, maxVisibleRows) {
            result.append(.visibleRows)
        }
        if storeQueryCount > 0 {
            result.append(.storeQuery)
        }
        if textMeasurementCount > 0 {
            result.append(.textMeasurement)
        }
        if layoutMeasurementCount > 0 {
            result.append(.layoutMeasurement)
        }
        return result
    }

    func isWithinBudget(maxVisibleRows: Int) -> Bool {
        violations(maxVisibleRows: maxVisibleRows).isEmpty
    }
}

struct ChatScrollFrameDecision {
    let boundaryContext: ChatHistoryPagingBoundaryContext
    let readTarget: ChatScrollVisibleRow?
    let floatingDate: ChatScrollFloatingDateUpdate?
    let voiceDescriptors: [VoiceMessageDescriptor]?
    let diagnostics: ChatScrollFrameDiagnostics
}

final class ChatScrollFramePlanner {
    private struct FloatingDateIdentity: Equatable {
        let section: Int
        let day: Date
    }

    private struct VoiceDescriptorSignature: Equatable {
        let referencePrimary: String
        let containerMessagePrimary: String
        let remoteURL: URL?
        let decodedURL: URL?
        let duration: TimeInterval
        let downloaded: Bool
        let pcmSampleCount: Int
        let sentDate: Date
        let archivedId: String?

        init(_ descriptor: VoiceMessageDescriptor) {
            self.referencePrimary = descriptor.referencePrimary
            self.containerMessagePrimary = descriptor.containerMessagePrimary
            self.remoteURL = descriptor.remoteURL
            self.decodedURL = descriptor.decodedURL
            self.duration = descriptor.duration
            self.downloaded = descriptor.downloaded
            self.pcmSampleCount = descriptor.pcm.count
            self.sentDate = descriptor.sentDate
            self.archivedId = descriptor.archivedId
        }
    }

    private let operationCounter: ChatRenderOperationCounter?
    private var lastFloatingDateIdentity: FloatingDateIdentity?
    private var lastVoiceDescriptorSignature: [VoiceDescriptorSignature]?

    init(operationCounter: ChatRenderOperationCounter? = nil) {
        self.operationCounter = operationCounter
    }

    func plan(
        request: ChatScrollWorkRequest,
        currentReadPosition: ChatTimelinePositionKey?,
        effectiveWork: ChatScrollWorkOptions? = nil
    ) -> ChatScrollFrameDecision {
        let work = effectiveWork ?? request.work
        let visible = request.visibleMetadata
        let needsVisibleRowVisit = work.contains(.updateFloatingDate)
            || work.contains(.advanceReadBoundary)
            || work.contains(.updateVoiceQueue)
        let visibleRowVisits = needsVisibleRowVisit ? visible.rows.count : 0
        operationCounter?.record(.scrollFrames)
        operationCounter?.record(.visibleRowsVisited, by: visibleRowVisits)

        var readTarget: ChatScrollVisibleRow?
        var topVisibleRow: ChatScrollVisibleRow?
        var preparedVoiceDescriptors: [VoiceMessageDescriptor] = []

        for row in needsVisibleRowVisit ? visible.rows : [] {
            if topVisibleRow == nil,
               !row.isFakeMessage {
                topVisibleRow = row
            }
            if work.contains(.advanceReadBoundary),
               request.meaningfullyVisibleReadPrimaries.contains(row.primary),
               row.isUnreadIncomingMessage,
               currentReadPosition.map({ row.position > $0 }) ?? true,
               readTarget.map({ row.position > $0.position }) ?? true {
                readTarget = row
            }
            if work.contains(.updateVoiceQueue) {
                preparedVoiceDescriptors.append(contentsOf: row.voiceDescriptors)
            }
        }

        let floatingDate: ChatScrollFloatingDateUpdate?
        if work.contains(.updateFloatingDate),
           visible.residentRowCount >= 5,
           let topVisibleRow {
            let identity = FloatingDateIdentity(
                section: topVisibleRow.section,
                day: topVisibleRow.floatingDateDay
            )
            if identity != lastFloatingDateIdentity {
                lastFloatingDateIdentity = identity
                floatingDate = ChatScrollFloatingDateUpdate(
                    section: topVisibleRow.section,
                    date: topVisibleRow.sentDate,
                    residentRowCount: visible.residentRowCount
                )
                operationCounter?.record(.floatingDateUpdates)
            } else {
                floatingDate = nil
            }
        } else {
            floatingDate = nil
        }

        let voiceDescriptors: [VoiceMessageDescriptor]?
        if work.contains(.updateVoiceQueue) {
            voiceDescriptors = voiceDescriptorsIfChanged(preparedVoiceDescriptors)
        } else {
            voiceDescriptors = nil
        }

        let diagnostics = ChatScrollFrameDiagnostics(
            visibleRowVisits: visibleRowVisits,
            storeQueryCount: 0,
            textMeasurementCount: 0,
            layoutMeasurementCount: 0,
            floatingDateUpdateCount: floatingDate == nil ? 0 : 1,
            voiceDescriptorBuildCount: 0,
            voiceQueueUpdateCount: voiceDescriptors == nil ? 0 : 1
        )
        assert(
            diagnostics.isWithinBudget(maxVisibleRows: visible.rows.count),
            "Chat scroll frame exceeded its visible-only operation budget"
        )
        return ChatScrollFrameDecision(
            boundaryContext: visible.boundaryContext,
            readTarget: readTarget,
            floatingDate: floatingDate,
            voiceDescriptors: voiceDescriptors,
            diagnostics: diagnostics
        )
    }

    func voiceDescriptorsIfChanged(
        in visibleMetadata: ChatScrollVisibleMetadata
    ) -> [VoiceMessageDescriptor]? {
        voiceDescriptorsIfChanged(visibleMetadata.rows.flatMap(\.voiceDescriptors))
    }

    func invalidateFloatingDate() {
        lastFloatingDateIdentity = nil
    }

    func invalidateVoiceDescriptors() {
        lastVoiceDescriptorSignature = nil
    }

    private func voiceDescriptorsIfChanged(
        _ descriptors: [VoiceMessageDescriptor]
    ) -> [VoiceMessageDescriptor]? {
        let signature = descriptors.map(VoiceDescriptorSignature.init)
        guard signature != lastVoiceDescriptorSignature else {
            return nil
        }
        lastVoiceDescriptorSignature = signature
        operationCounter?.record(.voiceQueueUpdates)
        return descriptors
    }
}

struct ChatPreparedVoiceTraversalBudget: Equatable {
    let maxDepth: Int
    let maxVisitedNodes: Int

    init(maxDepth: Int, maxVisitedNodes: Int) {
        self.maxDepth = max(0, maxDepth)
        self.maxVisitedNodes = max(0, maxVisitedNodes)
    }
}

struct ChatPreparedVoiceTraversalResult<Descriptor> {
    let descriptors: [Descriptor]
    let visitedNodeCount: Int
    let didReachBudget: Bool
}

enum ChatPreparedVoiceTraversal {
    private struct Pending<Node> {
        let node: Node
        let depth: Int
    }

    static func prepare<Node, Descriptor>(
        roots: [Node],
        budget: ChatPreparedVoiceTraversalBudget,
        children: KeyPath<Node, [Node]>,
        descriptors: (Node) -> [Descriptor]
    ) -> ChatPreparedVoiceTraversalResult<Descriptor> {
        var stack = roots.reversed().map { Pending(node: $0, depth: 0) }
        var result: [Descriptor] = []
        var visitedNodeCount = 0
        var didReachDepthBudget = false

        while visitedNodeCount < budget.maxVisitedNodes,
              let pending = stack.popLast() {
            visitedNodeCount += 1
            result.append(contentsOf: descriptors(pending.node))
            let descendants = pending.node[keyPath: children]
            guard descendants.isNotEmpty else { continue }
            guard pending.depth < budget.maxDepth else {
                didReachDepthBudget = true
                continue
            }
            stack.append(contentsOf: descendants.reversed().map {
                Pending(node: $0, depth: pending.depth + 1)
            })
        }

        return ChatPreparedVoiceTraversalResult(
            descriptors: result,
            visitedNodeCount: visitedNodeCount,
            didReachBudget: didReachDepthBudget || stack.isNotEmpty
        )
    }
}

enum ChatObserverRefreshGenerationDisposition: Equatable {
    case applyImmediately
    case deferred
    case ignored
}

struct ChatObserverRefreshGenerationCoalescer {
    private var pendingGeneration: UInt64?
    private var lastCommittedGeneration: UInt64?
    private(set) var committedGenerationCount = 0

    mutating func receive(
        generation: UInt64,
        motionState: ChatScrollMotionState
    ) -> ChatObserverRefreshGenerationDisposition {
        if let lastCommittedGeneration,
           generation <= lastCommittedGeneration,
           pendingGeneration == nil {
            return .ignored
        }
        guard motionState.isMoving else {
            lastCommittedGeneration = max(lastCommittedGeneration ?? 0, generation)
            committedGenerationCount += 1
            return .applyImmediately
        }
        pendingGeneration = max(pendingGeneration ?? 0, generation)
        return .deferred
    }

    mutating func flush(motionState: ChatScrollMotionState) -> UInt64? {
        guard !motionState.isMoving,
              let pendingGeneration else {
            return nil
        }
        self.pendingGeneration = nil
        if let lastCommittedGeneration,
           pendingGeneration <= lastCommittedGeneration {
            return nil
        }
        lastCommittedGeneration = pendingGeneration
        committedGenerationCount += 1
        return pendingGeneration
    }

    mutating func cancel() {
        pendingGeneration = nil
    }
}

extension ChatViewController {
    internal func rebuildScrollResidentMetadata() {
        scrollResidentMetadataGeneration &+= 1
        let sessionSnapshot = timelineSession?.snapshot
        let rows = datasource.enumerated().map { section, item -> ChatScrollVisibleRow in
            let position = sessionSnapshot?.item(primary: item.primary).map(ChatTimelinePositionKey.init(message:))
                ?? ChatTimelinePositionKey(
                    primary: item.primary,
                    archivedId: item.archivedId,
                    messageId: item.messageId,
                    date: item.sentDate
                )
            return ChatScrollVisibleRow(
                section: section,
                primary: item.primary,
                position: position,
                isOutgoing: item.isOutgoing,
                isRead: item.isRead,
                rowKind: ChatVisiblePositionPolicy.rowKind(for: item.kind),
                isFakeMessage: item.isFakeMessage,
                sentDate: item.sentDate,
                voiceDescriptors: preparedVisibleVoiceDescriptors(in: item)
            )
        }
        scrollResidentMetadata = ChatScrollResidentMetadata(
            generation: scrollResidentMetadataGeneration,
            rows: rows,
            firstRealSection: datasource.firstIndex(where: { !$0.isFakeMessage }),
            lastRealSection: datasource.lastIndex(where: { !$0.isFakeMessage })
        )
    }

    internal func preparedVisibleVoiceDescriptors(
        in item: Datasource,
        budget: ChatPreparedVoiceTraversalBudget = ChatPreparedVoiceTraversalBudget(
            maxDepth: 6,
            maxVisitedNodes: 64
        )
    ) -> [VoiceMessageDescriptor] {
        var descriptors = item.audios.compactMap {
            voiceMessageDescriptor(
                audio: $0,
                containerPrimary: item.primary,
                sentDate: item.sentDate
            )
        }
        let forwarded = ChatPreparedVoiceTraversal.prepare(
            roots: item.forwards,
            budget: budget,
            children: \.subforwards,
            descriptors: { attachment in
                attachment.audios.compactMap {
                    voiceMessageDescriptor(
                        audio: $0,
                        containerPrimary: item.primary,
                        sentDate: item.sentDate
                    )
                }
            }
        )
        descriptors.append(contentsOf: forwarded.descriptors)
        return descriptors
    }

}
