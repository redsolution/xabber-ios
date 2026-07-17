//
//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation
import os.signpost

enum ChatPerformanceSignpostPhase: String, CaseIterable {
    case openRequest = "chat.open_request"
    case localSnapshotReady = "chat.local_snapshot_ready"
    case firstContentCommitted = "chat.first_content_committed"
    case firstStableFrame = "chat.first_stable_frame"
    case chatOpenToFirstFrame = "chat.open_to_first_frame"
    case mapDataset = "chat.map_dataset"
    case datasourceDiff = "chat.datasource_diff"
    case datasourceApply = "chat.datasource_apply"
    case layoutApply = "chat.layout_apply"
    case scrollProcessing = "chat.scroll_processing"
    case sendToLocalRow = "chat.send_to_local_row"
    case localHistoryQuery = "chat.local_history_query"
    case displayModelCache = "chat.display_model_cache"
    case observerRefresh = "chat.observer_refresh"
    case referencePrepare = "chat.reference_prepare"
    case mediaPrefetch = "chat.media_prefetch"
    case mediaVisibleHit = "chat.media_visible_hit"
    case pagePlan = "chat.page_plan"
    case pageQuery = "chat.page_query"
    case pagePersist = "chat.page_persist"
    case pageApply = "chat.page_apply"
    case anchorReceived = "chat.anchor_received"
    case anchorResolved = "chat.anchor_resolved"
    case anchorCentered = "chat.anchor_centered"
    case messagePersistence = "chat.message_persistence"

    var signpostName: StaticString {
        switch self {
        case .openRequest:
            return "chat.open_request"
        case .localSnapshotReady:
            return "chat.local_snapshot_ready"
        case .firstContentCommitted:
            return "chat.first_content_committed"
        case .firstStableFrame:
            return "chat.first_stable_frame"
        case .chatOpenToFirstFrame:
            return "chat.open_to_first_frame"
        case .mapDataset:
            return "chat.map_dataset"
        case .datasourceDiff:
            return "chat.datasource_diff"
        case .datasourceApply:
            return "chat.datasource_apply"
        case .layoutApply:
            return "chat.layout_apply"
        case .scrollProcessing:
            return "chat.scroll_processing"
        case .sendToLocalRow:
            return "chat.send_to_local_row"
        case .localHistoryQuery:
            return "chat.local_history_query"
        case .displayModelCache:
            return "chat.display_model_cache"
        case .observerRefresh:
            return "chat.observer_refresh"
        case .referencePrepare:
            return "chat.reference_prepare"
        case .mediaPrefetch:
            return "chat.media_prefetch"
        case .mediaVisibleHit:
            return "chat.media_visible_hit"
        case .pagePlan:
            return "chat.page_plan"
        case .pageQuery:
            return "chat.page_query"
        case .pagePersist:
            return "chat.page_persist"
        case .pageApply:
            return "chat.page_apply"
        case .anchorReceived:
            return "chat.anchor_received"
        case .anchorResolved:
            return "chat.anchor_resolved"
        case .anchorCentered:
            return "chat.anchor_centered"
        case .messagePersistence:
            return "chat.message_persistence"
        }
    }
}

struct ChatPerformanceMetricSnapshot: Equatable {
    static let privateTokenFragments: [String] = [
        "owner",
        "jid",
        "body",
        "account",
        "token",
        "private",
        "text",
        "url",
        "path",
        "xml",
        "stanza",
        "messageid",
        "archiveid",
        "opponent"
    ]

    let phase: ChatPerformanceSignpostPhase
    private let counters: [String: Int]

    init(phase: ChatPerformanceSignpostPhase, counters: [String: Int]) {
        self.phase = phase
        self.counters = counters
    }

    var sortedCounterNames: [String] {
        counters.keys.sorted()
    }

    var unsafeFieldNames: [String] {
        sortedCounterNames.filter { fieldName in
            let normalized = fieldName
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
            return Self.privateTokenFragments.contains { token in
                normalized.contains(token)
            }
        }
    }

    var isPrivacySafe: Bool {
        unsafeFieldNames.isEmpty
    }

    func counter(_ name: String) -> Int {
        counters[name] ?? 0
    }
}

struct ChatReferencePrepareMetrics: Equatable {
    let referenceCount: Int
    let durationMs: Int
    let slowReferenceCount: Int

    var snapshot: ChatPerformanceMetricSnapshot {
        ChatPerformanceMetricSnapshot(
            phase: .referencePrepare,
            counters: [
                "referenceCount": referenceCount,
                "durationMs": durationMs,
                "slowReferenceCount": slowReferenceCount
            ]
        )
    }
}

enum ChatPerformanceSignposts {
    static let subsystem = "com.xabber.ios.chat"
    static let category = "performance"

    private static let log = OSLog(subsystem: subsystem, category: category)

    struct Interval {
        let phase: ChatPerformanceSignpostPhase

        private let signpostID: OSSignpostID
        private var didEnd = false

        fileprivate init(phase: ChatPerformanceSignpostPhase) {
            self.phase = phase
            let signpostID = OSSignpostID(log: ChatPerformanceSignposts.log)
            self.signpostID = signpostID
            os_signpost(
                .begin,
                log: ChatPerformanceSignposts.log,
                name: phase.signpostName,
                signpostID: signpostID
            )
        }

        var isActive: Bool {
            !didEnd
        }

        @discardableResult
        mutating func end() -> Bool {
            guard !didEnd else {
                return false
            }

            didEnd = true
            os_signpost(
                .end,
                log: ChatPerformanceSignposts.log,
                name: phase.signpostName,
                signpostID: signpostID
            )
            return true
        }
    }

    static func begin(_ phase: ChatPerformanceSignpostPhase) -> Interval {
        Interval(phase: phase)
    }

    static func event(_ phase: ChatPerformanceSignpostPhase) {
        os_signpost(
            .event,
            log: log,
            name: phase.signpostName
        )
    }

    @discardableResult
    static func measure<T>(
        _ phase: ChatPerformanceSignpostPhase,
        _ body: () throws -> T
    ) rethrows -> T {
        var interval = begin(phase)
        defer {
            interval.end()
        }
        return try body()
    }
}
